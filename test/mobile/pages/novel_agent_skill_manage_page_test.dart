// 职责: 验证移动端技能库的可见标签与已安装技能的导入、导出入口。
// 关联文件:
//   lib/mobile/features/agent_skills/global_skill_setup_page.dart
//   lib/mobile/features/agent_skills/novel_agent_skill_manage_page.dart
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/providers/agent_skill_catalog_providers.dart
//   lib/shared/providers/dictionary_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/i18n.md
//   .agents/rules/code-style.md
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/mobile/features/agent_skills/global_skill_setup_page.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/providers/dictionary_providers.dart';
import 'package:reveric/shared/providers/novel_agent_skill_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/agent_skill_import_source_form.dart';
import 'package:reveric/shared/widgets/guide/trigger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/providers/agent_skill_catalog_providers.dart';
import '../../shared/widgets/agent_skill/marketplace_test_support.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  testWidgets(
    'installed skills retain transfer actions without account uploads',
    (tester) async {
      const skill = NovelAgentSkillModel(
        id: 'upload_skill',
        sourceKind: AgentSkillSourceKind.novelLocal,
        name: 'Share Skill',
        whenToUse: 'When sharing a draft',
        description: 'Pre-filled description',
        prompt: 'Pre-filled prompt',
        category: 'writing',
        tags: ['draft'],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            agentSkillCatalogServiceProvider.overrideWithValue(
              TestMarketplaceService(),
            ),
            installedAgentSkillsProvider.overrideWith(
              () => _FakeInstalledAgentSkillsNotifier([skill]),
            ),

            skillCategoriesProvider.overrideWith((ref) async => const []),
            skillTagsProvider.overrideWith((ref) async => const []),
            guideTourAutoTriggerProvider.overrideWithValue(false),
          ],
          child: _wrap(const GlobalSkillSetupPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.widget<TabBar>(find.byType(TabBar)).tabs, hasLength(3));
      expect(find.text(tr(LocaleKeys.agentSkillTabInstalled)), findsOneWidget);
      expect(find.text(tr(LocaleKeys.agentSkillTabOfficial)), findsOneWidget);
      expect(find.text(tr(LocaleKeys.agentSkillTabMarket)), findsOneWidget);

      await tester.tap(find.text(tr(LocaleKeys.agentSkillTabMarket)));
      await tester.pumpAndSettle();
      expect(find.text('Dialogue'), findsOneWidget);
      await tester.tap(find.text(tr(LocaleKeys.commonImport)));
      await tester.pumpAndSettle();
      expect(find.byType(AgentSkillImportSourceForm), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byType(AgentSkillImportSourceForm),
                matching: find.byType(TextField),
              ),
            )
            .controller!
            .text,
        'https://github.com/example/dialogue',
      );
      Navigator.of(
        tester.element(find.byType(AgentSkillImportSourceForm)),
      ).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr(LocaleKeys.agentSkillTabInstalled)));
      await tester.pumpAndSettle();

      // 导入、导出是技能库迁移后仍需保留的入口，不能因全局化丢失。
      expect(find.text(tr(LocaleKeys.agentSkillImportAction)), findsOneWidget);
      expect(find.text(tr(LocaleKeys.agentSkillExportAction)), findsOneWidget);

      expect(find.text('Upload'), findsNothing);

      await tester.tap(find.text(tr(LocaleKeys.agentSkillImportAction)));
      await tester.pumpAndSettle();
      expect(find.byType(AgentSkillImportSourceForm), findsOneWidget);
      expect(find.text(tr(LocaleKeys.agentSkillImportRemote)), findsOneWidget);
      expect(
        find.text(tr(LocaleKeys.agentSkillImportSelectFolder)),
        findsOneWidget,
      );
      expect(
        find.text(tr(LocaleKeys.agentSkillImportSelectFile)),
        findsOneWidget,
      );
    },
  );
}

class _FakeInstalledAgentSkillsNotifier extends InstalledAgentSkillsNotifier {
  _FakeInstalledAgentSkillsNotifier(this._skills);

  final List<NovelAgentSkillModel> _skills;

  @override
  Future<List<NovelAgentSkillModel>> build() async => _skills;
}

Widget _wrap(Widget child) {
  return EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) {
        return RevericTheme(
          data: RevericThemeData.reveric,
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: child,
          ),
        );
      },
    ),
  );
}
