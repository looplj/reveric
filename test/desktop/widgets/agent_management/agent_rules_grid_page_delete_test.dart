// 职责: 回归智能体规则网格卡片可附加到聊天且右键确认后会删除持久化记录。
// 关联文件:
//   lib/desktop/widgets/agent_management/agent_rules_grid_page.dart
//   lib/shared/models/novel_workspace.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_rule.json
//   assets/translations/zh-CN/agent_rule.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/widgets/agent_management/agent_rules_grid_page.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/novel_workspace.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _databasePath = 'agent-rules-grid-delete-test';

AgentRule _rule() {
  final now = DateTime.now();
  return AgentRule(
    id: 'rule-1',
    name: '写作风格',
    content: '保持轻松幽默的叙事风格。',
    enabled: true,
    sortOrder: 0,
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('rule card can be attached to the next chat and deleted', (
    tester,
  ) async {
    final database = NovelContentDatabase.forTest(NativeDatabase.memory());
    final service = NovelContentService(database);
    var didOpenRule = false;
    addTearDown(database.close);
    await service.upsertAgentRule(_rule());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelContentServiceProvider(_databasePath).overrideWithValue(service),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('zh', 'CN')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          fallbackLocale: const Locale('zh', 'CN'),
          startLocale: const Locale('zh', 'CN'),
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
                    body: AgentRulesGridPage(
                      novelId: 'target',
                      databasePath: _databasePath,
                      headerGestureExclusionKey: GlobalKey(),
                      onOpen: (_) => didOpenRule = true,
                      onCreate: () {},
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('novel_agent_rule_card_rule-1'));
    expect(card, findsOneWidget);
    final draggable = tester.widget<Draggable<AiContextReference>>(
      find.descendant(
        of: card,
        matching: find.byType(Draggable<AiContextReference>),
      ),
    );
    expect(
      draggable.data,
      const AiContextReference(
        kind: AiContextReferenceKind.agent_rule,
        section: NovelWorkspaceSection.overview,
        itemId: 'rule-1',
        label: '写作风格',
      ),
    );

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.text('删除'),
                )
                .first,
          )
          .data,
      '删除',
    );
    expect(didOpenRule, isFalse);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, '删除'),
      ),
    );
    await tester.pumpAndSettle();

    expect(await service.getAgentRules(), isEmpty);
    expect(card, findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
