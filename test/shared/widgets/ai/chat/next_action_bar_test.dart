// 职责: 测试下一步建议条 — 无建议时不渲染不占高度，有建议时渲染 chip 并回传点击，会话消息能选出建议渲染成 chip。
// 关联文件:
//   lib/shared/widgets/ai/chat/next_action_bar.dart
//   lib/shared/heuristic/chat_next_action.dart
//   lib/shared/models/ai_chat_models.dart
//   assets/translations/en/heuristic.json
//   assets/translations/zh-CN/heuristic.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/widgets/ai/chat/session_next_action_bar.dart';
import 'package:reveric/shared/heuristic/chat_next_action.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/feature_id.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/chat/next_action_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets(
    'session bar respects visibility and preserves the selected action',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final picked = <ChatNextAction>[];
      Widget bar(bool enabled) => _wrap(
        ProviderScope(
          overrides: [
            aiChatSessionProvider('draft-signal').overrideWithValue(
              AiChatSessionState(
                sessionId: 'real-session',
                messages: _persistedTurnMessages,
              ),
            ),
          ],
          child: SessionNextActionBar(
            sessionId: 'draft-signal',
            enabled: enabled,
            onPick: picked.add,
          ),
        ),
        tickersEnabled: true,
      );
      await tester.pumpWidget(bar(false));
      await tester.pumpAndSettle();
      expect(find.byType(NextActionBar), findsNothing);
      await tester.pumpWidget(bar(true));
      await tester.pumpAndSettle();
      expect(find.text('排黄金三章大纲'), findsOneWidget);
      expect(find.text('确认剧情推演方向'), findsOneWidget);
      await tester.pumpWidget(bar(true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('排黄金三章大纲'));
      await tester.pump();
      await tester.tap(find.text('确认剧情推演方向'));
      await tester.pump();
      await tester.tap(find.text('在新作品中继续'));
      await tester.pump();
      expect(picked, hasLength(3));
      expect((picked.first.target as PromptActionTarget).prompt, '把黄金三章的大纲排出来');
      expect(
        (picked[1].target as PromptActionTarget).intent,
        ChatNextActionIntent.agent_rule,
      );
      final work = picked.last.target as WorkActionTarget;
      expect(work.workId, 'new_work');
      expect(work.prompt, '根据原作写第一集');
    },
  );

  testWidgets('无建议不占高度；有建议渲染 chip 并回传点击', (tester) async {
    final picked = <String>[];

    // ── 负例（核心）：模型没挂建议 → 不渲染、不占高度 ──
    await tester.pumpWidget(
      _wrap(
        NextActionBar(
          actions: const [],
          onPick: (action) => picked.add(action.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NextActionBar), findsOneWidget);
    expect(
      tester.getSize(find.byType(NextActionBar)).height,
      0,
      reason: '无建议时必须完全不占高度，不能留下残余间距',
    );
    expect(find.byType(InkWell), findsNothing);

    // ── 正例：三条建议渲染成 chip ──
    await tester.pumpWidget(
      _wrap(
        NextActionBar(
          actions: _sampleActions,
          onPick: (action) => picked.add(action.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(NextActionBar)).height, greaterThan(0));
    expect(find.text('核对第 03 章的时间线'), findsOneWidget);
    expect(find.text('木匣的交代时机去圆桌听几个视角'), findsOneWidget);
    expect(find.text('先把三舱对峙演一遍'), findsOneWidget);

    // ── 点击回传对应 action ──
    await tester.tap(find.text('木匣的交代时机去圆桌听几个视角'));
    await tester.pump();

    expect(picked, ['goto_council']);

    // ── 回归：线上真实消息形态（工具轮一条 + 收尾正文另一条）必须能选出并渲染 ──
    // 曾经的读取端只看最后一条 assistant 消息，模型「调完工具再说一句」时整条
    // 建议条静默消失（日志与落库都正常，界面什么都没有）。
    final block = latestSuggestNextActionBlock(_persistedTurnMessages);
    await tester.pumpWidget(
      _wrap(
        NextActionBar(
          actions: [
            for (final raw in block?.suggestions ?? const [])
              ?deserializeChatNextAction(raw),
          ],
          onPick: (action) => picked.add(action.id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(NextActionBar)).height, greaterThan(0));
    expect(find.text('排黄金三章大纲'), findsOneWidget);
    expect(find.text('确认剧情推演方向'), findsOneWidget);
    expect(find.text('在新作品中继续'), findsOneWidget);

    // ── 回归：放进默认居中的 Column 里必须仍然左对齐撑满 ──
    // desktop panel 的根 Column 就是默认 CrossAxisAlignment.center，本条若只按
    // 内容宽度就会被居中，与 mockup 的左对齐不符。
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      _wrapInCenteringColumn(
        NextActionBar(actions: _sampleActions, onPick: (_) {}),
      ),
    );
    await tester.pumpAndSettle();

    final wideRect = tester.getRect(find.byType(NextActionBar));
    expect(wideRect.left, 0, reason: '必须贴左，不能被父级 Column 居中');
    expect(wideRect.width, 900, reason: '必须撑满可用宽度');

    // ── 回归：面板窄时 chip 换行，不横向滚动藏到视野外 ──
    tester.view.physicalSize = const Size(320, 400);
    await tester.pumpWidget(
      _wrapInCenteringColumn(
        NextActionBar(actions: _sampleActions, onPick: (_) {}),
      ),
    );
    await tester.pumpAndSettle();

    final rows = {
      for (final action in _sampleActions)
        tester.getRect(find.text(action.label)).top,
    };
    expect(
      rows.length,
      greaterThan(1),
      reason: '320 宽放不下三个 chip，必须换行而不是横向滚出视野',
    );
    for (final action in _sampleActions) {
      final chip = tester.getRect(find.text(action.label));
      expect(
        chip.right,
        lessThanOrEqualTo(320),
        reason: '换行后每个 chip 都应完整落在可视区内：${action.label}',
      );
    }
  });
}

/// 落库消息的真实形态：user → assistant(挂建议的工具轮) → assistant(收尾正文)。
final _persistedTurnMessages = [
  AiMessage.user(id: 'u1', content: '直接下 suggest next action，我在测试'),
  AiMessage.assistant(
    id: 'a1',
    content: '收到，直接挂建议：',
    blocks: const [
      AiSuggestNextActionBlock(
        id: 'suggest_call_00',
        callId: 'call_00',
        suggestions: [
          {
            'id': 'suggest_prompt_0',
            'kind': 'prompt',
            'label': '排黄金三章大纲',
            'prompt': '把黄金三章的大纲排出来',
          },
          {
            'id': 'suggest_prompt_1',
            'intent': 'agent_rule',
            'kind': 'prompt',
            'label': '确认剧情推演方向',
            'prompt': '确认弹簧结构的剧情推演',
          },
          {
            'id': 'suggest_work_2',
            'kind': 'work',
            'label': '在新作品中继续',
            'work_id': 'new_work',
            'prompt': '根据原作写第一集',
          },
        ],
      ),
    ],
  ),
  AiMessage.assistant(id: 'a2', content: '挂好了，三条建议在输入框上方，点一下就能走对应流程。'),
];

const _sampleActions = [
  ChatNextAction(
    id: 'check_timeline',
    label: '核对第 03 章的时间线',
    target: PromptActionTarget('请核对第 03 章的时间线与老沈行踪'),
  ),
  ChatNextAction(
    id: 'goto_council',
    feature: FeatureId.ai_council,
    label: '木匣的交代时机去圆桌听几个视角',
    target: FeatureActionTarget(
      FeatureId.ai_council,
      seedText: '木匣该在第 3 章还是第 5 章交代',
    ),
  ),
  ChatNextAction(
    id: 'goto_theater',
    feature: FeatureId.ai_theater,
    label: '先把三舱对峙演一遍',
    target: FeatureActionTarget(FeatureId.ai_theater),
  ),
];

/// 复刻 desktop panel 根布局：默认 `CrossAxisAlignment.center` 的 Column。
Widget _wrapInCenteringColumn(Widget child) {
  return _wrap(
    Column(mainAxisAlignment: MainAxisAlignment.end, children: [child]),
  );
}

Widget _wrap(Widget child, {bool tickersEnabled = false}) {
  return EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) {
        return MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(),
          home: RevericTheme(
            data: RevericThemeData.reveric,
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: TickerMode(enabled: tickersEnabled, child: child),
              ),
            ),
          ),
        );
      },
    ),
  );
}
