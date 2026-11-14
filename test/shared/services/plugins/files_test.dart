// 职责: 验证 Provider 文件上传的句柄隔离、字节传输与阶段预算。
// 关联文件:
//   lib/shared/services/plugins/files.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/plugins/files.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late PluginFileScope scope;
  late PluginFilesApi api;
  late String handle;
  late String url;
  var budget = const Duration(seconds: 2);
  final bytes = utf8.encode('中文参考图片\u0000\u0001');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plugin-files-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}/upload';
    scope = PluginFileScope(
      pluginId: 'plugin',
      providerId: 'instance',
      taskId: 'task',
    );
    final file = await File('${directory.path}/input').writeAsBytes(bytes);
    final info = await scope.register(
      file,
      name: 'reference.png',
      mimeType: 'image/png',
    );
    handle = info['handle'] as String;
    expect(info['size'], bytes.length);
    expect(info['sha256'], hasLength(64));
    scope.claim(pluginId: 'plugin', providerId: 'instance', taskId: 'task');
    budget = const Duration(seconds: 2);
    api = PluginFilesApi(
      scope: scope,
      clientFactory: HttpClient.new,
      remainingBudget: () => budget,
    );
  });
  tearDown(() async {
    api.cancel();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  Matcher code(String value) =>
      throwsA(isA<PluginHostError>().having((e) => e.code, 'code', value));
  test(
    'raw streams exact bytes and preserves non-success diagnostic response',
    () async {
      server.listen((request) async {
        expect(request.method, 'PUT');
        expect(
          await request.fold<List<int>>([], (a, b) => a..addAll(b)),
          bytes,
        );
        request.response.statusCode = 422;
        request.response.write('invalid media');
        await request.response.close();
      });
      final result = await api.upload({
        'handle': handle,
        'request': {'kind': 'raw', 'url': url, 'method': 'PUT'},
      });
      expect(result['status'], 422);
      expect(result['body'], 'invalid media');
    },
  );
  test('multipart encodes fields and owns its boundary', () async {
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final boundary = request.headers.contentType!.parameters['boundary']!;
      expect(body, contains('--$boundary'));
      expect(body, contains('name="project"'));
      expect(body, contains('my-project'));
      expect(body, contains('name="image"; filename="reference.png"'));
      expect(body, contains(utf8.decode(bytes)));
      await request.response.close();
    });
    expect(
      (await api.upload({
        'handle': handle,
        'request': {
          'kind': 'multipart',
          'url': url,
          'fields': {'project': 'my-project'},
          'fileField': 'image',
        },
      }))['status'],
      200,
    );
  });
  test('foreign, reused and expired scopes reject access', () async {
    expect(
      () =>
          scope.claim(pluginId: 'plugin', providerId: 'other', taskId: 'task'),
      code('permission_denied'),
    );
    await expectLater(
      api.upload({'handle': 'forged', 'request': {}}),
      code('permission_denied'),
    );
    scope.revoke();
    await expectLater(
      api.upload({'handle': handle, 'request': {}}),
      code('permission_denied'),
    );
  });
  test('timeout options and spent budgets fail before sending', () async {
    var requests = 0;
    server.listen((_) => requests++);
    await expectLater(
      api.upload({
        'handle': handle,
        'request': {
          'kind': 'raw',
          'url': url,
          'method': 'POST',
          'timeoutMs': 600001,
        },
      }),
      code('invalid_request'),
    );
    budget = Duration.zero;
    await expectLater(
      api.upload({
        'handle': handle,
        'request': {'kind': 'raw', 'url': url, 'method': 'POST'},
      }),
      code('timeout'),
    );
    expect(requests, 0);
  });
  test(
    'total deadline includes stalled response and cancellation is immediate',
    () async {
      final received = Completer<void>();
      server.listen((request) async {
        await request.drain<void>();
        if (!received.isCompleted) {
          received.complete();
        }
      });
      budget = const Duration(milliseconds: 50);
      await expectLater(
        api.upload({
          'handle': handle,
          'request': {'kind': 'raw', 'url': url, 'method': 'POST'},
        }),
        code('timeout'),
      );
      await received.future;
      budget = const Duration(seconds: 2);
      final pending = api.upload({
        'handle': handle,
        'request': {'kind': 'raw', 'url': url, 'method': 'POST'},
      });
      final assertion = expectLater(pending, code('cancelled'));
      api.cancel();
      await assertion;
    },
  );
  test('uses instance proxy and does not replay redirected upload', () async {
    api = PluginFilesApi(
      scope: scope,
      clientFactory: () =>
          HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:${server.port}',
      remainingBudget: () => budget,
    );
    server.listen((request) async {
      expect(request.uri.toString(), 'http://provider.invalid/upload');
      await request.drain<void>();
      request.response.statusCode = 307;
      request.response.headers.set('location', '/replay');
      await request.response.close();
    });
    final result = await api.upload({
      'handle': handle,
      'request': {
        'kind': 'raw',
        'url': 'http://provider.invalid/upload',
        'method': 'PUT',
      },
    });
    expect(result['status'], 307);
  });
}
