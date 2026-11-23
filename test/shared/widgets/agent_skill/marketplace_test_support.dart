// 职责: 提供广场跨平台交互测试的目录替身与本地化宿主。
// 关联文件:
//   lib/shared/widgets/agent_skill/marketplace_browser.dart
//   lib/desktop/features/agent_skills/marketplace_catalog_tab.dart
//   lib/mobile/features/agent_skills/marketplace_tab.dart
//   lib/shared/services/agent_skill_catalog_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/marketplace_agent_skill.dart';
import 'package:reveric/shared/providers/agent_skill_catalog_providers.dart';
import 'package:reveric/shared/services/agent_skill_catalog_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/agent_skill/marketplace_browser.dart';
import 'package:reveric/shared/widgets/guide/trigger.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestMarketplaceService extends AgentSkillCatalogService {
  int calls = 0;
  bool fail = false;
  @override
  Future<List<MarketplaceAgentSkill>?> readMarketplaceCache() async => null;
  @override
  Future<List<MarketplaceAgentSkill>> listMarketplace() async {
    calls++;
    if (fail) {
      throw StateError('private server diagnostic');
    }
    return const [
      MarketplaceAgentSkill(
        name: 'Dialogue',
        description: 'Revise a scene',
        whenToUse: 'After drafting',
        category: 'Writing',
        url: 'https://github.com/example/dialogue',
      ),
      MarketplaceAgentSkill(
        name: 'Reference guide',
        description: 'Browse examples',
        category: 'Guide',
        url: 'https://example.com/guide',
      ),
    ];
  }
}

Widget marketplaceTestHost(Widget child, TargetPlatform platform) =>
    EasyLocalization(
      supportedLocales: const [Locale('en')],
      startLocale: const Locale('en'),
      fallbackLocale: const Locale('en'),
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      child: Builder(
        builder: (context) => MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData().copyWith(
            platform: platform,
          ),
          home: RevericTheme(
            data: RevericThemeData.reveric,
            child: Scaffold(body: child),
          ),
        ),
      ),
    );

void marketplaceInteractionTests(
  List<TargetPlatform> platforms,
  Widget Function(ValueChanged<String> onImport) build,
) {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  for (final platform in platforms) {
    testWidgets(
      '$platform searches locally, opens source and delegates import',
      (tester) async {
        await tester.binding.setSurfaceSize(
          platform == TargetPlatform.android
              ? const Size(390, 800)
              : const Size(1000, 800),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final service = TestMarketplaceService();
        String? imported;
        Uri? opened;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              agentSkillCatalogServiceProvider.overrideWithValue(service),
              guideTourAutoTriggerProvider.overrideWithValue(false),
              marketplaceLinkLauncherProvider.overrideWithValue((uri) async {
                opened = uri;
                return true;
              }),
            ],
            child: marketplaceTestHost(
              build((url) => imported = url),
              platform,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Dialogue'), findsOneWidget);
        expect(find.text('Import'), findsOneWidget);
        await tester.tap(find.text('Open').first);
        await tester.pumpAndSettle();
        expect(opened.toString(), 'https://github.com/example/dialogue');
        await tester.tap(find.text('Import'));
        expect(imported, 'https://github.com/example/dialogue');
        await tester.enterText(find.byType(TextField), 'after');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Reference guide'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text('Reference guide'), findsNothing);
        expect(find.text('Dialogue'), findsOneWidget);
        await tester.enterText(find.byType(TextField), '');
        await tester.pump();
        expect(find.text('Reference guide'), findsOneWidget);
        expect(service.calls, 1);
        await tester.tap(find.text('Guide').first);
        await tester.pumpAndSettle();
        expect(find.text('Dialogue'), findsNothing);
        expect(find.text('Import'), findsNothing);
        await tester.tap(find.text('All'));
        await tester.pumpAndSettle();
        final location = tester.getTopLeft(find.text('Dialogue'));
        service.fail = true;
        await tester.tap(find.widgetWithText(RevericButton, 'Refresh'));
        await tester.pumpAndSettle();
        expect(find.text('Dialogue'), findsOneWidget);
        expect(tester.getTopLeft(find.text('Dialogue')), location);
        expect(
          find.byTooltip('Refresh failed. Showing the saved directory.'),
          findsOneWidget,
        );
        expect(find.textContaining('private server'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
  testWidgets('failed initial load can retry; browser failure is visible', (
    tester,
  ) async {
    final service = TestMarketplaceService()..fail = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          agentSkillCatalogServiceProvider.overrideWithValue(service),
          guideTourAutoTriggerProvider.overrideWithValue(false),
          marketplaceLinkLauncherProvider.overrideWithValue(
            (uri) async => false,
          ),
        ],
        child: marketplaceTestHost(build((_) {}), platforms.first),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Unable to load the skill directory. Check your connection and try again.',
      ),
      findsOneWidget,
    );
    service.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Dialogue'), findsOneWidget);
    expect(service.calls, 2);
    await tester.tap(find.text('Open').first);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('private server'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
