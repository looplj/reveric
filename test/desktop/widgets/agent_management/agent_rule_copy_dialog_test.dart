// 职责: 回归跨作品复制智能体规则 — 同名规则不可勾选，勾选项写入当前作品内容库。
// 关联文件:
//   lib/desktop/widgets/agent_management/agent_rule_copy_dialog.dart
//   lib/desktop/widgets/agent_management/agent_rules_grid_page.dart
//   lib/shared/providers/novel_providers.dart
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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/widgets/agent_management/agent_rules_grid_page.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _targetPath = 'agent-rule-copy-target';
const _sourcePath = 'agent-rule-copy-source';

AgentRule _rule(String id, String name, String content, {int sortOrder = 0}) {
  final now = DateTime.now();
  return AgentRule(
    id: id,
    name: name,
    content: content,
    enabled: true,
    sortOrder: sortOrder,
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

Novel _novel(String id, String title, String? databasePath) {
  final now = DateTime.now();
  return Novel(
    id: id,
    title: title,
    authorName: '作者',
    description: '',
    status: 'ongoing',
    type: 'original',
    contentKind: contentKindNovel,
    contentDatabasePath: databasePath,
    wordCount: 0,
    draft: false,
    category: '玄幻',
    tags: const [],
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('copies non-conflicting rules from another novel', (
    tester,
  ) async {
    final targetDatabase = NovelContentDatabase.forTest(
      NativeDatabase.memory(),
    );
    final sourceDatabase = NovelContentDatabase.forTest(
      NativeDatabase.memory(),
    );
    final targetService = NovelContentService(targetDatabase);
    final sourceService = NovelContentService(sourceDatabase);
    addTearDown(targetDatabase.close);
    addTearDown(sourceDatabase.close);

    await targetService.upsertAgentRule(
      _rule('target-1', '写作风格', '保持轻松幽默的叙事风格。'),
    );
    await sourceService.upsertAgentRule(
      _rule('source-1', '写作风格', '来源作品的同名规则。'),
    );
    await sourceService.upsertAgentRule(
      _rule('source-2', '视角约束', '全程第三人称限知视角。', sortOrder: 1),
    );
    await sourceService.upsertAgentRule(
      _rule('source-3', '禁用词', '不要出现现代网络流行语。', sortOrder: 2),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelContentServiceProvider(
            _targetPath,
          ).overrideWithValue(targetService),
          novelContentServiceProvider(
            _sourcePath,
          ).overrideWithValue(sourceService),
          novelsProvider.overrideWith(
            (ref) => Stream.value([
              _novel('novel-target', '当前作品', _targetPath),
              _novel('novel-source', '参考作品', _sourcePath),
              _novel('novel-empty', '无内容库作品', null),
            ]),
          ),
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
                      novelId: 'novel-target',
                      databasePath: _targetPath,
                      headerGestureExclusionKey: GlobalKey(),
                      onOpen: (_) {},
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

    await tester.tap(find.text('从其他作品复制'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    // 当前作品与无内容库作品都不是可选来源。
    expect(
      find.descendant(of: dialog, matching: find.text('当前作品')),
      findsNothing,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('无内容库作品')),
      findsNothing,
    );

    await tester.tap(find.descendant(of: dialog, matching: find.text('参考作品')));
    await tester.pumpAndSettle();

    // 同名规则标记「已存在」，全选只会选中另外两条。
    expect(
      find.descendant(of: dialog, matching: find.text('已存在')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: dialog, matching: find.text('全选')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: dialog, matching: find.text('复制 2 条')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    final copied = await targetService.getAgentRules();
    expect(copied.map((rule) => rule.name).toList(), ['写作风格', '视角约束', '禁用词']);
    expect(copied.map((rule) => rule.id), isNot(contains('source-2')));
    expect(
      copied.firstWhere((rule) => rule.name == '写作风格').content,
      '保持轻松幽默的叙事风格。',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
