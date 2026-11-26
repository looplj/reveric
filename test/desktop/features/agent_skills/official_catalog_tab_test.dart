// 职责: OfficialCatalogTab 回归测试 — 验证 data 状态下 2 个技能卡片渲染、
//   进入页面时复用已预热的官方目录，以及 empty 状态下
//   LocaleKeys.agentSkillOfficialEmpty 文案展示。
// 关联文件:
//   lib/desktop/features/agent_skills/official_catalog_tab.dart
//   lib/shared/providers/agent_skill_catalog_providers.dart
//   lib/shared/services/agent_skill_catalog_service.dart
//   lib/shared/models/official_agent_skill.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/i18n.md
//   .agents/rules/code-style.md
import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart';
import 'package:reveric/desktop/features/agent_skills/official_catalog_tab.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/agent_skill_catalog_providers.dart';
import 'package:reveric/shared/providers/official_skill_sync_providers.dart';
import 'package:reveric/shared/providers/novel_agent_skill_providers.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/services/official_skill_sync.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/agent_skill_catalog_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  // 用单个 testWidgets 串联 data + empty 两个阶段,规避 EasyLocalization 的多
  // testWidgets 状态泄漏(_EasyLocalizationDelegate.load 第二次起 notifyListeners
  // 触发的 setState 不产生 Build 帧)。同一 testWidgets 内多次 pumpWidget 完整
  // widget tree(含 ProviderScope + EasyLocalization)即可触发重建。
  // AGENTS.md「Widget 测试隔离规则」明确指出:隔离成本过高时优先调整测试结构。
  testWidgets('OfficialCatalogTab data and empty states', (tester) async {
    final database = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(database.close);
    final syncReady = Completer<OfficialSkillSyncResult>();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // ── 阶段 1: data — 先预热 fresh 内存缓存，再进入 tab。
    // tab 必须复用 fresh 缓存，且渲染 2 个技能卡片。
    final dataFake = _FakeCatalogService(mode: 'data');
    final dataContainer = ProviderContainer(
      overrides: [
        officialSkillSyncProvider.overrideWith((ref) => syncReady.future),
        appDatabaseProvider.overrideWithValue(database),
        agentSkillAppDatabaseProvider.overrideWithValue(database),
        installedAgentSkillsProvider.overrideWith(_EmptyInstalledSkills.new),
        agentSkillCatalogServiceProvider.overrideWithValue(dataFake),
      ],
    );
    await dataContainer.read(
      officialAgentSkillsProvider(agentSkillCatalogFilter()).future,
    );
    expect(dataFake.officialCalls, 1);

    await _pumpHarness(
      tester,
      container: dataContainer,
      child: OfficialCatalogTab(flash: _noopFlash, onOpenDetail: (_) {}),
    );
    await tester.pumpAndSettle();

    expect(find.text('Weather Skill'), findsOneWidget);
    expect(find.text('Translate Skill'), findsOneWidget);
    // 版本 tag 在 head 右上;category 在 meta + 过滤栏 chip 各出现。
    expect(find.text('v1'), findsNWidgets(2));
    expect(find.text('productivity'), findsWidgets);
    expect(dataFake.officialCalls, 1);

    final installButtons = find.widgetWithText(
      OutlinedButton,
      tr(LocaleKeys.agentSkillInstall),
    );
    expect(
      tester.widgetList<OutlinedButton>(installButtons).map((b) => b.onPressed),
      everyElement(isNull),
    );
    syncReady.complete(const OfficialSkillSyncResult());
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<OutlinedButton>(installButtons).map((b) => b.onPressed),
      everyElement(isNotNull),
    );

    // 技能全局安装，Home 入口同样必须提供安装按钮。
    expect(find.text(tr(LocaleKeys.agentSkillInstall)), findsNWidgets(2));

    // ── 清理 widget 树,准备第二阶段。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    dataContainer.dispose();

    // ── 阶段 2: empty — fake service 返回空 list,
    //   验证显示 LocaleKeys.agentSkillOfficialEmpty 文案。
    await _pumpHarness(
      tester,
      overrides: [
        officialSkillSyncProvider.overrideWith(
          (ref) => const OfficialSkillSyncResult(),
        ),
        appDatabaseProvider.overrideWithValue(database),
        agentSkillAppDatabaseProvider.overrideWithValue(database),
        installedAgentSkillsProvider.overrideWith(_EmptyInstalledSkills.new),
        agentSkillCatalogServiceProvider.overrideWithValue(
          _FakeCatalogService(mode: 'empty'),
        ),
      ],
      child: OfficialCatalogTab(flash: _noopFlash, onOpenDetail: (_) {}),
    );
    await tester.pumpAndSettle();

    expect(find.text(tr(LocaleKeys.agentSkillOfficialEmpty)), findsOneWidget);
    expect(find.text('Weather Skill'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

void _noopFlash(String _) {}

Future<void> _pumpHarness(
  WidgetTester tester, {
  List<Override> overrides = const [],
  ProviderContainer? container,
  required Widget child,
}) async {
  final app = EasyLocalization(
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
          builder: (materialCtx, c) {
            return RevericTheme(
              data: RevericThemeData.reveric,
              child: MediaQuery(
                data: MediaQuery.of(
                  materialCtx,
                ).copyWith(textScaler: const TextScaler.linear(0.85)),
                child: c!,
              ),
            );
          },
          home: Scaffold(body: child),
        );
      },
    ),
  );
  await tester.pumpWidget(
    container == null
        ? ProviderScope(overrides: overrides, child: app)
        : UncontrolledProviderScope(container: container, child: app),
  );
}

/// 通过 mode 控制返回结果的 AgentSkillCatalogService mock。
///
/// mode='data':返回 2 个 OfficialAgentSkill(name/version/category 可见)。
/// mode='empty':返回空 list,触发 _CatalogEmpty 渲染。
/// 其他接口对本测试无用,直接返回空常量或抛 StateError 防止误调用。
class _FakeCatalogService extends AgentSkillCatalogService {
  @override
  Future<OfficialAgentSkill> getOfficial({required String listingId}) =>
      throw UnimplementedError('getOfficial is not used in this test.');

  _FakeCatalogService({required this.mode});

  String mode;
  int officialCalls = 0;

  @override
  Future<OfficialAgentSkillCatalog> listOfficial() async {
    officialCalls++;
    if (mode == 'empty') {
      return const OfficialAgentSkillCatalog();
    }
    return const OfficialAgentSkillCatalog(
      agentSkills: [
        OfficialAgentSkill(
          listingId: 'official_1',
          name: 'Weather Skill',
          whenToUse: 'When user asks weather',
          description: 'Fetches current weather for a location.',
          prompt: 'You are a weather bot.',
          category: 'productivity',
          tags: ['weather'],
          version: 1,
          sortOrder: 0,
          updatedAt: '2024-01-01',
        ),
        OfficialAgentSkill(
          listingId: 'official_2',
          name: 'Translate Skill',
          whenToUse: 'When user asks translation',
          description: 'Translates text between languages.',
          prompt: 'You are a translator.',
          category: 'productivity',
          tags: ['language'],
          version: 1,
          sortOrder: 1,
          updatedAt: '2024-01-02',
        ),
      ],
    );
  }
}

class _EmptyInstalledSkills extends InstalledAgentSkillsNotifier {
  @override
  Future<List<NovelAgentSkillModel>> build() async => const [];
}
