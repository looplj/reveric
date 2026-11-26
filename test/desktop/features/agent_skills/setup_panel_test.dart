// 职责: AgentSkill Setup 面板回归测试 — 验证已安装技能的删除入口在溢出菜单里，
//   且删除需要确认后才生效。
// 关联文件:
//   lib/desktop/features/agent_skills/setup_panel.dart
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/database/app_database.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/agent_skills/setup_panel.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/agent_skill_catalog_providers.dart';
import 'package:reveric/shared/services/agent_skill_catalog_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/models/marketplace_agent_skill.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/providers/novel_agent_skill_providers.dart';
import 'package:reveric/shared/widgets/agent_skill_import_source_form.dart';
import 'package:reveric/shared/widgets/guide/trigger.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTest(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  for (final home in [true, false]) {
    testWidgets(
      'marketplace is reachable from ${home ? 'home' : 'novel'} skill library',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1000, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final service = _EmptyCatalogService();
        await _pumpPanel(tester, db, catalog: service, home: home);
        expect(service.marketplaceCalls, 0);
        final tab = find.text(tr(LocaleKeys.agentSkillTabMarket));
        expect(tab, findsOneWidget);
        await tester.tap(tab);
        await tester.pumpAndSettle();
        expect(find.text('Marketplace entry'), findsOneWidget);
        expect(service.marketplaceCalls, 1);
        await tester.tap(find.text(tr(LocaleKeys.commonImport)));
        await tester.pumpAndSettle();
        final input = find.descendant(
          of: find.byType(AgentSkillImportSourceForm),
          matching: find.byType(TextField),
        );
        expect(
          tester.widget<TextField>(input).controller!.text,
          'https://github.com/example/skill',
        );
        Navigator.of(
          tester.element(find.byType(AgentSkillImportSourceForm)),
        ).pop();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant({
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }),
    );
  }

  testWidgets('removing an unreadable installed skill requires confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final installed = _InstalledSkills(const [
      NovelAgentSkillModel(
        id: 'skill_remove_guard',
        sourceKind: AgentSkillSourceKind.novelLocal,
        name: 'Remove guard',
        description: '',
        prompt: '',
        packageReadFailed: true,
      ),
    ]);
    await _pumpPanel(tester, db, installed: installed);

    expect(find.text(tr(LocaleKeys.agentSkillTabInstalled)), findsOneWidget);
    expect(find.text(tr(LocaleKeys.agentSkillTabOfficial)), findsOneWidget);
    expect(find.text(tr(LocaleKeys.agentSkillTabMarket)), findsOneWidget);
    expect(find.text(tr(LocaleKeys.agentSkillLoadFailed)), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);

    // 删除与上传都收在卡片右上的溢出菜单里，不再是常驻按钮。
    await _openRowMenu(tester);
    expect(find.text('Upload'), findsNothing);
    expect(find.text(tr(LocaleKeys.agentSkillRemove)), findsOneWidget);

    await tester.tap(find.text(tr(LocaleKeys.agentSkillRemove)));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.text('Delete'),
                )
                .first,
          )
          .data,
      'Delete',
    );

    // 取消不删除。
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(installed.removedIds, isEmpty);

    await _openRowMenu(tester);
    await tester.tap(find.text(tr(LocaleKeys.agentSkillRemove)));
    await tester.pumpAndSettle();
    // 确认按钮与菜单项同名，取对话框内那个。
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text(tr(LocaleKeys.agentSkillRemove)),
      ),
    );
    await tester.pumpAndSettle();
    expect(installed.removedIds, ['skill_remove_guard']);
    expect(find.text('Remove guard'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// 打开已安装技能卡片右上的溢出菜单。
Future<void> _openRowMenu(WidgetTester tester) async {
  await tester.tap(
    find.byWidgetPredicate(
      (widget) =>
          widget is RevericIcon && widget.assetPath == RevericIcons.more_horiz,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpPanel(
  WidgetTester tester,
  AppDatabase db, {
  AgentSkillCatalogService? catalog,
  _InstalledSkills? installed,
  bool home = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        agentSkillAppDatabaseProvider.overrideWithValue(db),
        installedAgentSkillsProvider.overrideWith(
          () => installed ?? _InstalledSkills(const []),
        ),
        // Tab 角标会 watch 目录 provider,测试里用空目录隔离技能资源加载。
        agentSkillCatalogServiceProvider.overrideWithValue(
          catalog ?? _EmptyCatalogService(),
        ),
        guideTourAutoTriggerProvider.overrideWithValue(false),
      ],
      child: EasyLocalization(
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
                  body: SkillSetupPanel(
                    novelId: home ? null : 'novel_remove_guard',
                    novelTitle: 'Remove guard novel',
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
}

class _InstalledSkills extends InstalledAgentSkillsNotifier {
  _InstalledSkills(this.skills);

  final List<NovelAgentSkillModel> skills;
  final removedIds = <String>[];

  @override
  Future<List<NovelAgentSkillModel>> build() async => skills;

  @override
  Future<void> remove(String id) async {
    removedIds.add(id);
    state = AsyncValue.data(skills.where((skill) => skill.id != id).toList());
  }
}

class _EmptyCatalogService extends AgentSkillCatalogService {
  int marketplaceCalls = 0;
  @override
  Future<List<MarketplaceAgentSkill>?> readMarketplaceCache() async => null;
  @override
  Future<List<MarketplaceAgentSkill>> listMarketplace() async {
    marketplaceCalls++;
    return const [
      MarketplaceAgentSkill(
        name: 'Marketplace entry',
        description: 'A listed skill',
        url: 'https://github.com/example/skill',
      ),
    ];
  }

  @override
  Future<OfficialAgentSkill> getOfficial({required String listingId}) =>
      throw UnimplementedError('getOfficial is not used in this test.');

  @override
  Future<OfficialAgentSkillCatalog> listOfficial() async =>
      const OfficialAgentSkillCatalog();
}
