// 职责: 测试 OfficialAgentSkillTab — data 状态显示卡片、empty 状态显示
//   `LocaleKeys.agentSkillOfficialEmpty` 文案。loading/error 状态因
//   loading 包含无限动画且 provider autoDispose 隔离成本高,跳过。
// 关联文件:
//   lib/mobile/features/agent_skills/official_tab.dart
//   lib/shared/providers/agent_skill_catalog_providers.dart
//   lib/shared/providers/agent_skill_providers.dart
//   lib/shared/services/agent_skill_catalog_service.dart
//   lib/shared/models/official_agent_skill.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/en/common.json
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
import 'package:reveric/mobile/features/agent_skills/official_tab.dart';
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

  // 两个验证阶段合并到一个 testWidgets 中,遵循 .agents/rules/testing.md
  // 的模式:阶段间用 pumpWidget(SizedBox.shrink()) 清理 widget 树。
  // 原因:autoDispose.family provider 跨 testWidgets 时缓存未清理,导致第二阶段
  // 拿到第一阶段的 fake 服务返回值(详见 AGENTS.md Widget 测试隔离规则)。
  testWidgets('OfficialAgentSkillTab renders data card and empty state', (
    tester,
  ) async {
    final database = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(database.close);
    final syncReady = Completer<OfficialSkillSyncResult>();
    // ── 阶段 1:data 状态显示技能卡片 + 安装按钮 ──
    const dto = OfficialAgentSkill(
      listingId: 'official-1',
      name: 'Weather Skill',
      whenToUse: 'when weather',
      description: 'desc',
      prompt: 'prompt',
      category: 'utils',
      tags: ['weather'],
      badge: '推荐',
      version: 3,
      sortOrder: 0,
      updatedAt: '2026-01-01T00:00:00Z',
    );
    final fakeWithData = _FakeCatalogService(
      officialList: const OfficialAgentSkillCatalog(agentSkills: [dto]),
    );

    await tester.pumpWidget(
      _wrap(
        ProviderScope(
          overrides: [
            officialSkillSyncProvider.overrideWith((ref) => syncReady.future),
            appDatabaseProvider.overrideWithValue(database),
            agentSkillAppDatabaseProvider.overrideWithValue(database),
            installedAgentSkillsProvider.overrideWith(
              _EmptyInstalledSkills.new,
            ),
            agentSkillCatalogServiceProvider.overrideWithValue(fakeWithData),
          ],
          child: const Scaffold(
            body: SizedBox(height: 600, child: OfficialAgentSkillTab()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 卡片必须显示技能名 —— 这是用户区分多个 official 技能的唯一标识。
    expect(find.text('Weather Skill'), findsOneWidget);
    // 版本 chip 必须显示，方便对照本地包版本。
    expect(find.text('v3'), findsOneWidget);
    // spec 表里配了 badge 的技能必须渲染出角标 —— 数据进入目录模型不等于画到了屏幕，
    // 卡片对 badge 有非空判断，漏掉会静默不显示。
    expect(find.text('推荐'), findsOneWidget);
    // 安装按钮文案存在,确保安装入口可达。
    expect(find.text(tr(LocaleKeys.agentSkillInstall)), findsOneWidget);
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

    final installButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, tr(LocaleKeys.agentSkillInstall)),
    );
    // 全局技能库不依赖 novelId；目录加载完成后下载按钮必须可点。
    expect(installButton.onPressed, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    // ── 阶段 2:empty 状态显示空状态文案 ──
    final fakeEmpty = _FakeCatalogService(
      officialList: const OfficialAgentSkillCatalog(agentSkills: []),
    );

    await tester.pumpWidget(
      _wrap(
        ProviderScope(
          overrides: [
            officialSkillSyncProvider.overrideWith(
              (ref) => const OfficialSkillSyncResult(),
            ),
            appDatabaseProvider.overrideWithValue(database),
            agentSkillAppDatabaseProvider.overrideWithValue(database),
            installedAgentSkillsProvider.overrideWith(
              _EmptyInstalledSkills.new,
            ),
            agentSkillCatalogServiceProvider.overrideWithValue(fakeEmpty),
          ],
          child: const Scaffold(
            body: SizedBox(height: 600, child: OfficialAgentSkillTab()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 空状态文案必须出现,避免用户误以为页面没加载完。
    expect(find.text(tr(LocaleKeys.agentSkillOfficialEmpty)), findsOneWidget);
    // 空状态不应渲染任何卡片。
    expect(find.text(tr(LocaleKeys.agentSkillInstall)), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

// ── 测试夹具 ─────────────────────────────────────────────────────────────────

class _FakeCatalogService extends AgentSkillCatalogService {
  @override
  Future<OfficialAgentSkill> getOfficial({required String listingId}) =>
      throw UnimplementedError('getOfficial is not used in this test.');

  _FakeCatalogService({OfficialAgentSkillCatalog? officialList})
    : _officialList =
          officialList ?? const OfficialAgentSkillCatalog(agentSkills: []);

  final OfficialAgentSkillCatalog _officialList;

  @override
  Future<OfficialAgentSkillCatalog> listOfficial() async => _officialList;
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

class _EmptyInstalledSkills extends InstalledAgentSkillsNotifier {
  @override
  Future<List<NovelAgentSkillModel>> build() async => const [];
}
