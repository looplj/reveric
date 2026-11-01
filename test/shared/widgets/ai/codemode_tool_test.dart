// 职责: 验证批量任务卡片、详情按需解析与释放、完整结果和旧记录在窄屏下的展示。
// 关联文件:
//   lib/shared/widgets/ai/tool_activity_group.dart
//   lib/shared/widgets/ai/tools/tool_detail_body.dart
//   lib/shared/widgets/ai/tools/codemode_detail_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/agent_round_detail_dialog.dart';
import 'package:reveric/shared/widgets/ai/tool_activity_group.dart';
import 'package:reveric/shared/widgets/ai/chat/typing_indicator.dart';
import 'package:reveric/shared/widgets/ai/tools/codemode_detail_dialog.dart';
import 'package:reveric/shared/widgets/ai/tools/tool_detail_body.dart';
import 'package:reveric/shared/widgets/ai/tools/tool_card_descriptor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  for (final width in [390.0, 1000.0]) {
    testWidgets(
      'lazy batch continuation follows task and last call status at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final (status, childStatus, count, visible) in [
          (AiToolCallStatus.pending, AiNestedToolStatus.success, 1, true),
          (AiToolCallStatus.running, AiNestedToolStatus.success, 1, true),
          (AiToolCallStatus.success, AiNestedToolStatus.success, 1, false),
          (AiToolCallStatus.error, AiNestedToolStatus.success, 1, false),
          (AiToolCallStatus.cancelled, AiNestedToolStatus.success, 1, false),
          (AiToolCallStatus.running, AiNestedToolStatus.running, 1, false),
          (AiToolCallStatus.running, AiNestedToolStatus.error, 1, false),
          (AiToolCallStatus.running, AiNestedToolStatus.success, 0, false),
        ]) {
          final block = _block(status: status, count: count);
          final fixture = block.copyWith(
            nestedCalls: [
              for (final call in block.nestedCalls)
                call.copyWith(status: childStatus),
            ],
          );
          await tester.pumpWidget(
            _wrap(
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => showCodemodeDetail(context, block: fixture),
                  child: const Text('Open batch'),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Open batch'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          final indicator = _inDialog(find.byType(AiTypingIndicator));
          expect(indicator, visible ? findsOneWidget : findsNothing);
          expect(
            _inDialog(find.text('Thinking...')),
            visible ? findsOneWidget : findsNothing,
          );
          if (visible) {
            expect(
              tester.getBottomLeft(indicator).dy,
              lessThan(tester.getTopLeft(_inDialog(find.text('Script'))).dy),
            );
          }
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  for (final count in [0, 1]) {
    testWidgets('short batch dialog stays compact with $count calls', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(AiToolActivityGroup(blocks: [_block(count: count)])),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Batch task'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(_inDialog(find.byType(AiToolStepList))).height,
        lessThan(150),
      );
      expect(_inDialog(find.text('Script')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [390.0, 1000.0]) {
    testWidgets(
      '566 calls are lazy and restore expanded rows at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          _wrap(AiToolActivityGroup(blocks: [_block(count: 566)])),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Batch task'));
        await tester.pumpAndSettle();
        expect(
          _inDialog(find.text('Read')).evaluate().length,
          inExclusiveRange(0, 60),
        );
        await tester.tap(_inDialog(find.text('Read')).first);
        await tester.pumpAndSettle();
        expect(find.byType(AiToolDetailBody), findsOneWidget);
        final scrollable = tester.state<ScrollableState>(
          _inDialog(find.byType(Scrollable)).first,
        );
        scrollable.position.jumpTo(5000);
        await tester.pumpAndSettle();
        expect(find.byType(AiToolDetailBody), findsNothing);
        expect(_inDialog(find.text('Read')).evaluate().length, lessThan(60));
        scrollable.position.jumpTo(0);
        await tester.pumpAndSettle();
        expect(find.byType(AiToolDetailBody), findsOneWidget);
        expect(
          tester
              .widget<AiToolDetailBody>(find.byType(AiToolDetailBody))
              .block
              .callId,
          'read-0',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [390.0, 1000.0]) {
    testWidgets('child header remains stable while toggling at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final call = AiNestedToolCall(
        callId: 'replace',
        toolName: 'Replace',
        status: AiNestedToolStatus.success,
        argumentsPreview: jsonEncode({'pattern': '林晚', 'replacement': '林迟'}),
        resultPreview: jsonEncode({'matched_fields': 7, 'applied_fields': 7}),
      );
      await tester.pumpWidget(
        _wrap(
          AiToolActivityGroup(
            blocks: [
              _block(count: 0).copyWith(nestedCalls: [call]),
            ],
          ),
        ),
      );
      // 原生 binding 的资源读取可能尚未完成，pumpAndSettle 不等待文件 I/O。
      for (
        var i = 0;
        i < 100 && find.text('Batch task').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Batch task'));
      await tester.pumpAndSettle();
      final header = find
          .descendant(
            of: _inDialog(find.byType(AiToolStepList)),
            matching: find.byType(InkWell),
          )
          .first;
      final label = find.descendant(
        of: header,
        matching: find.text('林晚 → 林迟 (7)'),
      );
      expect(label, findsOneWidget);
      Offset labelOffset() =>
          tester.getTopLeft(label) - tester.getTopLeft(header);
      final position = labelOffset();
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(label, findsOneWidget);
      expect(labelOffset(), position);
      expect(find.byType(AiToolDetailBody), findsOneWidget);
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(label, findsOneWidget);
      expect(labelOffset(), position);
      expect(find.byType(AiToolDetailBody), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  test('row projection skips large bodies and nested lookalike keys', () {
    final body = ('正文' * (512 * 1024)) + r'\"pattern\"\\}';
    final parent = _block(count: 0).copyWith(
      nestedCalls: [
        AiNestedToolCall(
          callId: 'create',
          toolName: 'Create',
          targetPath: 'materials',
          argumentsPreview: jsonEncode({
            'ignored': [
              {
                'fields': {'title': 'wrong'},
                'body': body,
              },
            ],
            'path': 'materials',
            'fields': {'content': body, 'title': '林"晚\\😀'},
          }),
          resultPreview: jsonEncode({'content': body}),
        ),
        AiNestedToolCall(
          callId: 'replace',
          toolName: 'Replace',
          argumentsPreview: jsonEncode({
            'ignored': body,
            'pattern': '甲',
            'replacement': '乙',
          }),
          resultPreview: jsonEncode({
            'rows': [
              {'matched_fields': 999, 'content': body},
            ],
            'matched_fields': 2,
          }),
        ),
      ],
    );
    final blocks = codemodeNestedBlocks(parent);
    expect(blocks.first.arguments, {
      'path': 'materials',
      'fields': {'title': '林"晚\\😀'},
    });
    expect(blocks.first.result, isNull);
    expect(blocks.last.arguments, {'pattern': '甲', 'replacement': '乙'});
    expect(blocks.last.result, {'matched_fields': 2});
    expect(
      jsonEncode(blocks.map((b) => b.arguments).toList()).length,
      lessThan(200),
    );
  });

  test(
    'Read summaries retain query scope and pagination without result bodies',
    () {
      const path = 'clips?episode_id=epi_1&is_storyboard=true&kind=video';
      final call = AiNestedToolCall(
        callId: 'read',
        toolName: 'Read',
        targetPath: 'clips',
        argumentsPreview: jsonEncode({
          'path': path,
          'offset': 2,
          'limit': 10,
          'sort': '-title',
        }),
        resultPreview: jsonEncode({
          'entries': [
            {'prompt': 'large body'},
          ],
        }),
      );
      final summary = codemodeNestedBlocks(
        _block(count: 0).copyWith(nestedCalls: [call]),
      ).single;
      expect(toolPrimaryPath(summary), path);
      expect(summary.arguments, {
        'path': path,
        'offset': 2,
        'limit': 10,
        'sort': '-title',
      });
      expect(summary.result, isNull);
      expect(codemodeNestedDetails(summary, call).arguments, summary.arguments);
      const legacy = AiNestedToolCall(
        callId: 'legacy',
        toolName: 'Read',
        targetPath: 'clips',
        argumentsPreview: '{"path":"clips',
      );
      expect(
        codemodeNestedBlocks(
          _block(count: 0).copyWith(nestedCalls: [legacy]),
        ).single.arguments,
        {'path': 'clips'},
      );
    },
  );

  test('truncated summaries preserve the existing raw-detail fallback', () {
    const call = AiNestedToolCall(
      callId: 'replace',
      toolName: 'Replace',
      argumentsPreview: '{"pattern":"林晚","extra":[',
      resultPreview: '{"matched_fields":2,"extra":"cut',
    );
    final summary = codemodeNestedBlocks(
      _block(count: 0).copyWith(nestedCalls: [call]),
    ).single;
    expect(summary.arguments, isEmpty);
    expect(summary.result, isEmpty);
    expect(codemodeNestedDetails(summary, call).result, {
      'output': call.resultPreview,
    });
  });

  testWidgets('collapsed child targets retain the full-block labels', (
    tester,
  ) async {
    final fixtures = <(String, Map<String, dynamic>, Map<String, dynamic>)>[
      ('Grep', {'pattern': '林晚'}, {'text': 'full body'}),
      ('Glob', {'pattern': 'chapters/*'}, {}),
      (
        'Replace',
        {'pattern': '林晚', 'replacement': '林迟'},
        {'matched_fields': 7},
      ),
      ('Replace', {'pattern': '旧名', 'replacement': ''}, {'applied_fields': 3}),
      ('Search', {'query': '旧版搜索'}, {}),
      ('WebSearch', {'query': '林晚'}, {}),
      ('WebFetch', {'url': 'https://example.com/page'}, {}),
      ('GraphSearch', {'type': 'character', 'id': 'person-1', 'depth': 2}, {}),
      (
        'GraphSearch',
        {'entity_type': 'character', 'entity_id': 'person-2'},
        {},
      ),
      (
        'Create',
        {
          'path': 'materials',
          'fields': {'content': 'full body', 'title': '资料标题'},
        },
        {},
      ),
      (
        'Create',
        {
          'path': 'characters',
          'fields': {'name': '林晚'},
        },
        {},
      ),
      (
        'Create',
        {
          'path': 'relations',
          'fields': {
            'source_type': 'character',
            'source_id': 'person-1',
            'target_type': 'character',
            'target_id': 'person-2',
          },
        },
        {},
      ),
    ];
    late BuildContext context;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final (tool, arguments, result) in fixtures) {
      final call = AiNestedToolCall(
        callId: 'fixture',
        toolName: tool,
        targetPath: arguments['path'] as String?,
        status: AiNestedToolStatus.success,
        argumentsPreview: jsonEncode(arguments),
        resultPreview: jsonEncode(result),
      );
      final summary = codemodeNestedBlocks(
        _block(count: 0).copyWith(nestedCalls: [call]),
      ).single;
      final full = codemodeNestedDetails(summary, call);
      final expected = toolRowTarget(context, full, null);
      expect(expected, isNot(isEmpty), reason: tool);
      expect(toolRowTarget(context, summary, null), expected, reason: tool);
      expect(summary.arguments.toString(), isNot(contains('full body')));
    }
  });

  testWidgets('20 reads stay one row; details open in a dialog of tool cards', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(AiToolActivityGroup(blocks: [_block()])));
    await tester.pumpAndSettle();
    expect(find.text('Batch task'), findsOneWidget);
    expect(find.text('Completed · 20 calls'), findsOneWidget);
    expect(find.byType(AiToolDetailBody), findsNothing);
    expect(find.byType(AgentRoundDetailDialog), findsNothing);
    await tester.tap(find.text('Batch task'));
    await tester.pumpAndSettle();
    expect(_inDialog(find.byType(AiToolStepList)), findsOneWidget);
    expect(
      _inDialog(find.text('Read')).evaluate().length,
      inInclusiveRange(1, 20),
    );
    expect(find.text('return "fixture source";'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Script'),
      200,
      scrollable: find.descendant(
        of: find.byType(AgentRoundDetailDialog),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text('Script'));
    await tester.pumpAndSettle();
    expect(find.text('return "fixture source";'), findsOneWidget);
    expect(find.text('fixture output'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full results are decoded only while their row is expanded', (
    tester,
  ) async {
    final first = _ObservedCall('first', 'first full result');
    final second = _ObservedCall('second', 'second full result');
    final parent = _block(count: 0).copyWith(nestedCalls: [first, second]);
    await tester.pumpWidget(_wrap(AiToolActivityGroup(blocks: [parent])));
    await tester.pumpAndSettle();
    expect(first.resultReads + second.resultReads, 0);
    await tester.tap(find.text('Batch task'));
    await tester.pumpAndSettle();
    expect(first.resultReads + second.resultReads, 0);
    expect(find.byType(AiToolDetailBody), findsNothing);

    await tester.tap(_inDialog(find.text('Read')).first);
    await tester.pumpAndSettle();
    expect(first.resultReads, greaterThan(0));
    expect(second.resultReads, 0);
    final decoded = tester
        .widget<AiToolDetailBody>(find.byType(AiToolDetailBody))
        .block;
    expect(decoded.arguments['path'], 'chapters/first');
    expect(decoded.result!['content'], 'first full result');
    final readsWhileOpen = first.resultReads;
    await tester.pump();
    expect(first.resultReads, readsWhileOpen);

    await tester.tap(_inDialog(find.text('Read')).first);
    await tester.pumpAndSettle();
    expect(find.byType(AiToolDetailBody), findsNothing);
    await tester.tap(_inDialog(find.text('Read')).first);
    await tester.pumpAndSettle();
    final reopened = tester
        .widget<AiToolDetailBody>(find.byType(AiToolDetailBody))
        .block;
    expect(reopened.result, decoded.result);
    expect(identical(reopened.result, decoded.result), isFalse);
    expect(first.resultReads, greaterThan(readsWhileOpen));
    expect(second.resultReads, 0);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AiToolDetailBody), findsNothing);
    expect(find.text('Completed · 2 calls'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('400 full child results stay unparsed when the dialog opens', (
    tester,
  ) async {
    final calls = [
      for (var i = 0; i < 400; i++) _ObservedCall('$i', 'x' * (64 * 1024)),
    ];
    final block = _block(count: 0).copyWith(nestedCalls: calls);
    await tester.pumpWidget(_wrap(AiToolActivityGroup(blocks: [block])));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Batch task'));
    await tester.pumpAndSettle();
    expect(calls.fold<int>(0, (sum, call) => sum + call.resultReads), 0);
    expect(find.byType(AiToolDetailBody), findsNothing);
    await tester.tap(_inDialog(find.text('Read')).first);
    await tester.pumpAndSettle();
    final detail = tester.widget<AiToolDetailBody>(
      find.byType(AiToolDetailBody),
    );
    expect((detail.block.result!['content'] as String).length, 64 * 1024);
    expect(calls.skip(1).every((call) => call.resultReads == 0), isTrue);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final debugMode in [true, false]) {
    testWidgets('run again appears only in debug mode, debugMode=$debugMode', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          AiToolActivityGroup(
            blocks: [_block()],
            databasePath: '/tmp/novel.db',
          ),
          debugMode: debugMode,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Batch task'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Script'),
        200,
        scrollable: find.descendant(
          of: find.byType(AgentRoundDetailDialog),
          matching: find.byType(Scrollable),
        ),
      );

      // 只在调试模式给重放入口；正式用户看不到，也不会误触重跑一整批写入。
      expect(find.text('Run again'), debugMode ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'live count updates without guessing a total; stopped row opens the dialog',
    (tester) async {
      final child = ValueNotifier<Widget>(
        AiToolActivityGroup(
          blocks: [_block(status: AiToolCallStatus.running, count: 2)],
        ),
      );
      addTearDown(child.dispose);
      await tester.pumpWidget(
        _wrap(
          ValueListenableBuilder<Widget>(
            valueListenable: child,
            builder: (_, value, _) => value,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Running · 2 completed'), findsOneWidget);
      child.value = AiToolActivityGroup(
        blocks: [_block(status: AiToolCallStatus.running, count: 3)],
      );
      await tester.pump();
      expect(find.text('Running · 3 completed'), findsOneWidget);
      expect(find.textContaining('3/'), findsNothing);
      child.value = AiToolActivityGroup(
        blocks: [_block(status: AiToolCallStatus.cancelled, count: 3)],
      );
      await tester.pumpAndSettle();
      expect(find.text('Stopped · 3 completed'), findsOneWidget);
      expect(find.byType(AiToolDetailBody), findsNothing);
      await tester.tap(find.text('Batch task'));
      await tester.pumpAndSettle();
      expect(_inDialog(find.text('Read')), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in [const Locale('en'), const Locale('zh', 'CN')]) {
    for (final (errorCode, width) in [
      ('codemode_timeout', 320.0),
      ('codemode_memory_limit', 1000.0),
      ('codemode_resource_limit', 320.0),
    ]) {
      for (final debugMode in [false, true]) {
        testWidgets(
          '${locale.languageCode} $errorCode hides reason and opens details debug=$debugMode',
          (tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final block = _block(status: AiToolCallStatus.error, count: 1)
                .copyWith(
                  arguments: {'code': 'long_source_' * 80},
                  result: {
                    'error_code': errorCode,
                    'output': ['long_output_' * 80],
                  },
                );
            await tester.pumpWidget(
              _wrap(
                AiToolActivityGroup(blocks: [block]),
                locale: locale,
                debugMode: debugMode,
              ),
            );
            await tester.pumpAndSettle();
            final context = tester.element(find.byType(AiToolActivityGroup));
            final failure = codemodeFailureSummary(context, block);
            expect(failure, isNotNull);
            expect(find.text(failure!), findsNothing);
            expect(
              find.text(
                locale.languageCode == 'en'
                    ? 'Failed · 1 completed'
                    : '执行失败 · 已完成 1 次',
              ),
              findsOneWidget,
            );
            await tester.tap(
              find
                  .text(locale.languageCode == 'en' ? 'Batch task' : '批量处理')
                  .first,
            );
            await tester.pumpAndSettle();
            expect(
              _inDialog(find.text(failure)),
              debugMode ? findsOneWidget : findsNothing,
            );
            await tester.tap(
              find.text(locale.languageCode == 'en' ? 'Script' : '脚本'),
            );
            await tester.pumpAndSettle();
            expect(find.text('long_source_' * 80), findsOneWidget);
            expect(find.text('long_output_' * 80), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final debugMode in [false, true]) {
    testWidgets(
      'codemode error message is debug detail only debug=$debugMode',
      (tester) async {
        const message = 'Script execution exceeded its memory limit.';
        final block = _block(status: AiToolCallStatus.error, count: 0).copyWith(
          errorMessage: message,
          result: {'error_code': 'codemode_memory_limit'},
        );
        await tester.pumpWidget(
          _wrap(AiToolActivityGroup(blocks: [block]), debugMode: debugMode),
        );
        await tester.pumpAndSettle();
        expect(find.text('Batch task'), findsOneWidget);
        expect(find.text(message), findsNothing);
        await tester.tap(find.text('Batch task'));
        await tester.pumpAndSettle();
        expect(_inDialog(find.text('Script')), findsOneWidget);
        expect(
          _inDialog(find.text(message)),
          debugMode ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('The task exceeded its processing limit.'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('nested summaries keep full and legacy details available on demand', () {
    final parent = _block(count: 1).copyWith(
      nestedCalls: [
        ..._block(count: 1).nestedCalls,
        const AiNestedToolCall(
          callId: 'write',
          toolName: 'Write',
          targetPath: 'chapters/1',
          status: AiNestedToolStatus.error,
          argumentsPreview: '{"path":"chapters/1","value":"cut in ha',
          resultPreview: '{"error":"cut',
        ),
      ],
    );
    final summaries = codemodeNestedBlocks(parent);
    expect(summaries.every((block) => block.result == null), isTrue);
    final blocks = [
      for (var i = 0; i < summaries.length; i++)
        codemodeNestedDetails(summaries[i], parent.nestedCalls[i]),
    ];
    expect(blocks.first.toolName, 'Read');
    expect(blocks.first.status, AiToolCallStatus.success);
    expect(blocks.first.arguments, {'path': 'chapters/0'});
    expect(blocks.first.result, {'content': 'result 0'});
    expect(blocks.last.status, AiToolCallStatus.error);
    expect(blocks.last.targetPath, 'chapters/1');
    expect(blocks.last.arguments, isEmpty);
    expect(blocks.last.result, {'output': '{"error":"cut'});
  });
}

Finder _inDialog(Finder finder) =>
    find.descendant(of: find.byType(AgentRoundDetailDialog), matching: finder);

AiToolCallBlock _block({
  AiToolCallStatus status = AiToolCallStatus.success,
  int count = 20,
}) => AiToolCallBlock(
  id: 'parent',
  callId: 'parent-call',
  toolName: 'Codemode',
  arguments: const {'code': 'return "fixture source";'},
  status: status,
  result: const {
    'output': ['fixture output'],
  },
  nestedCalls: List.generate(
    count,
    (i) => AiNestedToolCall(
      callId: 'read-$i',
      toolName: 'Read',
      status: AiNestedToolStatus.success,
      durationMs: 12,
      targetPath: 'chapters/$i',
      argumentsPreview: jsonEncode({'path': 'chapters/$i'}),
      resultPreview: jsonEncode({'content': 'result $i'}),
    ),
  ),
);

Widget _wrap(
  Widget child, {
  Locale locale = const Locale('en'),
  bool useScope = true,
  bool debugMode = false,
}) {
  final localized = EasyLocalization(
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: locale,
    saveLocale: false,
    child: Builder(
      builder: (context) => MaterialApp(
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        theme: RevericThemeData.reveric.toThemeData(),
        // 弹窗是 Navigator 的兄弟路由，主题要挂在 builder 上才读得到。
        builder: (_, navigator) =>
            RevericTheme(data: RevericThemeData.reveric, child: navigator!),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  return useScope
      ? ProviderScope(
          overrides: [appDebugModeProvider.overrideWithValue(debugMode)],
          child: localized,
        )
      : localized;
}

class _ObservedCall extends AiNestedToolCall {
  _ObservedCall(String id, String body)
    : super(
        callId: id,
        toolName: 'Read',
        status: AiNestedToolStatus.success,
        targetPath: 'chapters/$id',
        argumentsPreview: jsonEncode({'path': 'chapters/$id'}),
        resultPreview: jsonEncode({'content': body}),
      );
  int resultReads = 0;
  @override
  String get resultPreview {
    resultReads++;
    return super.resultPreview;
  }
}
