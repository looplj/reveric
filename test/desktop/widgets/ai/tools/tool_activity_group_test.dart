// 职责: 测试 AI 工具执行过程时间线 — 聚合行、就地展开的工具详情与 Run 准备态交互。
// 关联文件:
//   lib/shared/widgets/ai/tool_activity_group.dart
//   lib/shared/widgets/ai/tools/tool_detail_body.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/tool_activity_group.dart';
import 'package:reveric/shared/widgets/ai/tools/tool_card_common.dart';
import 'package:reveric/shared/widgets/ai/tools/tool_detail_body.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('failed edits show a check while details retain the error', (
    tester,
  ) async {
    await _pumpWrapped(
      tester,
      const AiToolActivityGroup(
        blocks: [
          AiToolCallBlock(
            id: 'failed-edit',
            callId: 'failed-edit',
            toolName: 'Edit',
            arguments: {'path': '/chapters/1/content'},
            status: AiToolCallStatus.error,
            result: {
              'error': 'old_text not found',
              'error_code': 'old_text_not_found',
            },
            errorMessage: 'old_text not found',
          ),
          AiThinkingBlock(id: 'thinking', text: 'Try another edit'),
        ],
      ),
    );
    expect(
      tester
          .widgetList<AiToolStatusDot>(find.byType(AiToolStatusDot))
          .map((dot) => dot.status),
      [AiToolCallStatus.success, AiToolCallStatus.success],
    );
    await tester.tap(find.byType(AiToolStatusDot).first);
    await _pumpAnimation(tester);
    expect(find.byType(AiToolDetailBody), findsOneWidget);
    expect(
      tester
          .widget<AiToolDetailBody>(find.byType(AiToolDetailBody))
          .block
          .status,
      AiToolCallStatus.error,
    );
    expect(
      tester.widget<AiToolStatusBadge>(find.byType(AiToolStatusBadge)).status,
      AiToolCallStatus.error,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('renders process group and expands tool detail inline', (
    tester,
  ) async {
    await _pumpWrapped(
      tester,
      const AiToolActivityGroup(
        blocks: [
          AiToolCallBlock(
            id: 'read',
            callId: 'call_read',
            toolName: 'Read',
            arguments: {'path': '/chapters/1'},
            status: AiToolCallStatus.success,
          ),
          AiToolCallBlock(
            id: 'search',
            callId: 'call_search',
            toolName: 'Search',
            arguments: {'query': 'alpha'},
            status: AiToolCallStatus.success,
            result: {
              'results': ['alpha hit'],
            },
          ),
          AiToolCallBlock(
            id: 'run',
            callId: 'call_run',
            toolName: 'Run',
            arguments: {'command': 'agent-skills'},
            status: AiToolCallStatus.running,
          ),
        ],
      ),
    );

    expect(find.text('Process'), findsOneWidget);
    expect(find.text('Running…'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);

    // 初始不展开任何工具详情。
    expect(find.byType(AiToolDetailBody), findsNothing);

    // 点击工具行 → 就地展开详情，不再弹窗 / 底部弹层。
    await tester.tap(find.byType(AiToolStatusDot).first);
    await _pumpAnimation(tester);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(AiToolDetailBody), findsOneWidget);
    expect(find.text('Done'), findsWidgets); // 内联状态徽章

    // 再次点击 → 收起。
    await tester.tap(find.byType(AiToolStatusDot).first);
    await _pumpAnimation(tester);
    expect(find.byType(AiToolDetailBody), findsNothing);

    // Run 仍在等待子命令 → 不可展开。
    await tester.tap(find.byType(AiToolStatusDot).at(2));
    await _pumpAnimation(tester);
    expect(find.byType(AiToolDetailBody), findsNothing);

    // ---- 尾部 thinking 的选区开关 ----

    const thinkingBlock = AiThinkingBlock(id: 'think', text: 'still growing');

    // 尾部 thinking 仍在增长：展开后不得注册选区。
    await _pumpWrapped(
      tester,
      const AiToolActivityGroup(blocks: [thinkingBlock], isStreamingTail: true),
    );
    await tester.tap(find.text('Thinking...'));
    await _pumpAnimation(tester);
    expect(find.text('still growing'), findsOneWidget);
    expect(find.byType(SelectionArea), findsNothing);

    // 内容定稿后恢复可选。
    await _pumpWrapped(
      tester,
      const AiToolActivityGroup(blocks: [thinkingBlock]),
    );
    await tester.tap(find.text('Deep Thinking'));
    await _pumpAnimation(tester);
    expect(find.text('still growing'), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('failed tools show a check outside debug mode', (tester) async {
    const failedGroup = AiToolActivityGroup(
      blocks: [
        AiToolCallBlock(
          id: 'create_failed',
          callId: 'call_create_failed',
          toolName: 'Create',
          arguments: {'path': '/characters'},
          status: AiToolCallStatus.error,
          errorMessage: 'failed',
        ),
      ],
    );

    await _pumpWrapped(tester, failedGroup);
    expect(
      tester.widget<AiToolStatusDot>(find.byType(AiToolStatusDot)).status,
      AiToolCallStatus.success,
    );
  });

  testWidgets(
    'background export changes from queued to failed in the same row',
    (tester) async {
      AiToolActivityGroup group(String status) => AiToolActivityGroup(
        blocks: [
          AiToolCallBlock(
            id: 'export',
            callId: 'export',
            toolName: 'Run',
            arguments: const {'command': 'editing', 'subcommand': 'export'},
            status: AiToolCallStatus.success,
            result: const {
              'ok': true,
              'run_id': 'run-export',
              'status': 'queued',
            },
            metadata: {
              'operations': [
                {
                  'run_id': 'run-export',
                  'call_id': 'export',
                  'status': status,
                  if (status == 'failed')
                    'result': {
                      'ok': false,
                      'error_code': 'encoding_failed',
                      'error': 'Media encoding failed.',
                    },
                },
              ],
            },
          ),
        ],
      );
      await _pumpWrapped(tester, group('queued'));
      expect(
        tester.widget<AiToolStatusDot>(find.byType(AiToolStatusDot)).status,
        AiToolCallStatus.pending,
      );
      expect(find.text('Running…'), findsOneWidget);
      await _pumpWrapped(tester, group('failed'));
      expect(
        tester.widget<AiToolStatusDot>(find.byType(AiToolStatusDot)).status,
        AiToolCallStatus.success,
      );
      expect(find.text('Running…'), findsNothing);
      await tester.tap(find.byType(AiToolStatusDot));
      await _pumpAnimation(tester);
      expect(find.text('Media encoding failed.'), findsWidgets);
    },
  );
}

Future<void> _pumpWrapped(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(_wrap(child));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

Future<void> _pumpAnimation(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Widget _wrap(Widget child) {
  return EasyLocalization(
    key: UniqueKey(),
    supportedLocales: const [Locale('en')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) {
        return ProviderScope(
          overrides: [appDebugModeProvider.overrideWithValue(false)],
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(body: Center(child: child)),
            ),
          ),
        );
      },
    ),
  );
}
