// 职责: 验证 MCP 原始 schema、取消和大结果保留真实执行状态。
// 关联文件:
//   lib/shared/services/mcp/tool_dispatcher.dart
//   lib/shared/services/mcp/result_adapter.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mcp_dart/mcp_dart.dart' as sdk;
import 'package:reveric/shared/models/mcp/config.dart';
import 'package:reveric/shared/models/mcp/call_result.dart';
import 'package:reveric/shared/services/mcp/runtime.dart';
import 'package:reveric/shared/services/mcp/client_adapter.dart';
import 'package:reveric/shared/services/mcp/tool_dispatcher.dart';
import 'package:reveric/shared/services/mcp/result_adapter.dart';

class ExecutionConnection implements McpConnection {
  int calls = 0;
  bool closed = false;
  @override
  Future<void> Function()? onToolsChanged;
  @override
  void Function()? onClosed;
  @override
  String? get description => null;
  @override
  String? get instructions => null;
  @override
  Future<void> close() async {
    closed = true;
    onClosed?.call();
  }

  @override
  Future<List<Map<String, dynamic>>> listTools() async => [
    {
      'name': 'write',
      'inputSchema': {
        'type': 'object',
        r'$defs': {
          'positive': {'type': 'integer', 'minimum': 1},
        },
        'properties': {
          'number': {r'$ref': '#/\$defs/positive'},
        },
        'required': ['number'],
        'allOf': [
          {
            'properties': {
              'number': {'maximum': 10},
            },
          },
        ],
      },
    },
  ];
  @override
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments, {
    sdk.AbortSignal? signal,
    void Function(sdk.Progress)? onProgress,
  }) async {
    calls++;
    if (arguments['number'] == 4) {
      const text = 'production 12 application/json fake-secret';
      onProgress?.call(sdk.Progress(progress: 1, message: text));
      return {
        'content': [
          {'type': 'text', 'text': text},
        ],
        'structuredContent': {
          'text': text,
          'nested': [text, 12],
        },
      };
    }
    if (arguments['number'] == 5) {
      throw StateError('production 12 application/json fake-secret');
    }
    if (arguments['number'] == 3) {
      return {
        'isError': true,
        'content': [
          {'type': 'text', 'text': 'credential=fake-secret'},
        ],
        'structuredContent': {'detail': 'fake-secret'},
      };
    }
    if (arguments['number'] == 2 && signal != null) {
      await signal.onAbort.first;
      throw StateError('Request interrupted after sending');
    }
    return {
      'content': [
        {'type': 'text', 'text': 'saved'},
      ],
    };
  }
}

void main() {
  late McpRuntime runtime;
  late ExecutionConnection connection;
  late McpToolDispatcher dispatcher;
  setUp(() async {
    connection = ExecutionConnection();
    runtime = McpRuntime(connect: (_) async => connection);
    await runtime.configure(
      McpSettings([
        McpServerConfig(
          name: 'notes',
          enabled: true,
          connection: McpHttpConfig(
            url: 'https://example.test',
            bearerToken: 'fake-secret',
          ),
        ),
      ]),
    );
    await runtime.ensureReady('notes');
    dispatcher = McpToolDispatcher(runtime);
  });
  tearDown(() => runtime.close());
  test('remote errors preserve server text and structured content', () async {
    final result = await dispatcher.call('mcp__notes__write', {'number': 3});
    expect(result.executionState, McpExecutionState.failed);
    expect(result.text, ['credential=fake-secret']);
    expect(result.structuredContent, {'detail': 'fake-secret'});
    expect(result.error, 'credential=fake-secret');
  });
  for (final transport in [
    McpStdioConfig(
      command: 'fixture',
      env: {'DEBUG': '1', 'NODE_ENV': 'production'},
    ),
    McpHttpConfig(
      url: 'https://example.test',
      headers: {'Accept': 'application/json'},
      bearerToken: 'fake-secret',
    ),
  ]) {
    test(
      'configuration values do not rewrite ${transport.runtimeType} output',
      () async {
        final local = McpRuntime(connect: (_) async => ExecutionConnection());
        addTearDown(local.close);
        await local.configure(
          McpSettings([
            McpServerConfig(
              name: 'notes',
              enabled: true,
              connection: transport,
            ),
          ]),
        );
        await local.ensureReady('notes');
        final caller = McpToolDispatcher(local);
        const text = 'production 12 application/json fake-secret';
        final progress = <Map<String, dynamic>>[];
        final result = await caller.call('mcp__notes__write', {
          'number': 4,
        }, onProgress: progress.add);
        expect(result.text, [text]);
        expect(result.structuredContent, {
          'text': text,
          'nested': [text, 12],
        });
        expect(progress.single['message'], text);
        final failure = await caller.call('mcp__notes__write', {'number': 5});
        expect(failure.error, 'Bad state: $text');
      },
    );
  }
  test(
    'cancellation while reconnecting releases only the caller wait',
    () async {
      final gate = Completer<McpConnection>();
      final started = Completer<void>();
      var attempts = 0;
      final shared = McpRuntime(
        connect: (_) {
          if (attempts++ == 0) {
            return Future.value(ExecutionConnection());
          }
          started.complete();
          return gate.future;
        },
      );
      addTearDown(shared.close);
      await shared.configure(
        McpSettings([
          McpServerConfig(
            name: 'notes',
            enabled: true,
            connection: McpHttpConfig(url: 'https://example.test'),
          ),
        ]),
      );
      await shared.ensureReady('notes');
      await shared.suspend();
      await shared.resume();
      final cancel = sdk.BasicAbortController();
      final call = McpToolDispatcher(
        shared,
      ).call('mcp__notes__write', {'number': 1}, signal: cancel.signal);
      await started.future;
      cancel.abort();
      expect(
        (await call.timeout(const Duration(milliseconds: 200))).executionState,
        McpExecutionState.not_started,
      );
      final connection = ExecutionConnection();
      gate.complete(connection);
      expect(await shared.ensureReady('notes'), same(connection));
      expect(connection.closed, false);
    },
  );
  test('local ref and combination constraints reject before sending', () async {
    for (final number in [0, 11, 'wrong']) {
      final result = await dispatcher.call('mcp__notes__write', {
        'number': number,
      });
      expect(result.executionState, McpExecutionState.not_started);
    }
    expect(connection.calls, 0);
    expect(
      (await dispatcher.call('mcp__notes__write', {'number': 1})).ok,
      true,
    );
    expect(connection.calls, 1);
  });
  test(
    'cancelled session becomes unknown without closing another session connection',
    () async {
      final controller = sdk.BasicAbortController();
      final first = dispatcher.call('mcp__notes__write', {
        'number': 2,
      }, signal: controller.signal);
      await Future<void>.delayed(Duration.zero);
      controller.abort();
      expect((await first).executionState, McpExecutionState.unknown);
      expect(connection.closed, false);
      expect(
        (await dispatcher.call('mcp__notes__write', {'number': 1})).ok,
        true,
      );
      expect(connection.calls, 2);
    },
  );
  test('model preview retains a small structured result beside long text', () {
    final result = McpResultAdapter.normalize({
      'content': [
        {'type': 'text', 'text': 'start ${'x' * 50000} end'},
      ],
      'structuredContent': {'id': '123'},
    });
    final preview = McpResultAdapter.limit(
      result,
      McpResultAdapter.modelBudget,
    );
    expect(preview.structuredContent, {'id': '123'});
    expect(preview.text.single, startsWith('start '));
    expect(preview.text.single, endsWith(' end'));
    expect(preview.text.join('\n'), contains('[truncated]'));
    expect(preview.jsonBytes, lessThanOrEqualTo(McpResultAdapter.modelBudget));
  });
  test(
    'large structured data remains complete for scripts and has a model preview',
    () {
      final data = {'first': 'begin', 'large': 'x' * 600000, 'last': 'end'};
      final result = McpResultAdapter.normalize({
        'content': [],
        'structuredContent': data,
      });
      expect(result.structuredContent, data);
      final preview = McpResultAdapter.limit(
        result,
        McpResultAdapter.modelBudget,
      );
      expect(preview.text.single, contains('begin'));
      expect(preview.text.single, contains('end'));
      expect(preview.text.single, contains('[truncated]'));
      expect(preview.text.join('\n'), contains('[truncated]'));
      expect(
        preview.jsonBytes,
        lessThanOrEqualTo(McpResultAdapter.modelBudget),
      );
      expect(result.structuredContent, data);
    },
  );
  test('unsupported and oversized success stays successful and valid JSON', () {
    final result = McpResultAdapter.normalize({
      'content': [
        {'type': 'audio', 'data': 'private'},
        {'type': 'text', 'text': '界😀' * 300000},
      ],
      'structuredContent': {
        'ok': false,
        'error': 'business',
        'large': 'x' * 600000,
      },
    });
    expect(result.ok, true);
    expect((result.structuredContent!['large'] as String).length, 600000);
    expect(result.text.first, '界😀' * 300000);
    expect(result.text.last, '[Unsupported MCP content omitted: audio]');
    final model = McpResultAdapter.limit(result, McpResultAdapter.modelBudget);
    expect(model.ok, true);
    expect(model.jsonBytes, lessThanOrEqualTo(McpResultAdapter.modelBudget));
  });

  test(
    'image data survives the separate model text budget and JSON round trip',
    () {
      final pixels = img.Image(width: 128, height: 128);
      for (final pixel in pixels) {
        pixel.setRgb(pixel.x, pixel.y, pixel.x ^ pixel.y);
      }
      final image = {
        'type': 'image',
        'mimeType': 'image/png',
        'data': base64Encode(img.encodePng(pixels, level: 0)),
      };
      final result = McpResultAdapter.normalize({
        'content': [
          {'type': 'text', 'text': 'start ${'x' * 50000} end'},
          image,
        ],
        'structuredContent': {'id': '123'},
      });
      final preview = McpResultAdapter.limit(
        result,
        McpResultAdapter.modelBudget,
      );
      final persisted = jsonDecode(jsonEncode(preview)) as Map<String, dynamic>;
      expect(McpCallResult.fromJson(persisted).toJson(), persisted);
      expect((persisted['content'] as List).last, image);
      expect(preview.text.single, contains('[truncated]'));
      expect(preview.structuredContent, {'id': '123'});
      expect(preview.jsonBytes, greaterThan(McpResultAdapter.modelBudget));
      expect(
        preview.textJsonBytes,
        lessThanOrEqualTo(McpResultAdapter.modelBudget),
      );
    },
  );

  test('unusable MCP images preserve text and tool execution state', () {
    final result = McpResultAdapter.normalize({
      'content': [
        {'type': 'text', 'text': 'screenshot attempt'},
        {'type': 'image', 'mimeType': 'image/png', 'data': '%%%%'},
        {'type': 'image', 'mimeType': 'image/svg+xml', 'data': 'eA=='},
        {'type': 'image', 'mimeType': 'image/jpeg', 'data': 'eA=='},
      ],
    });
    expect(result.ok, true);
    expect(result.content.whereType<sdk.ImageContent>(), isEmpty);
    expect(result.text.first, 'screenshot attempt');
    expect(result.text.last, contains('invalid base64'));
    expect(result.text.last, contains('unsupported image MIME type'));
    expect(result.text.last, contains('unreadable image'));
  });
}
