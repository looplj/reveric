// 职责: 验证交互式分步引导的供应商配置判定、app_states 持久化/重置，以及桌面与移动端自动触发。
// 关联文件:
//   lib/shared/widgets/guide/tour.dart
//   lib/shared/widgets/guide/overlay.dart
//   lib/shared/widgets/guide/trigger.dart
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/shared/services/app_initialization.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/database/app_database.dart' show AppDatabase;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/app_initialization.dart';
import 'package:reveric/shared/services/debug/guide_force_show.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/guide/overlay.dart';
import 'package:reveric/shared/widgets/guide/tour.dart';
import 'package:reveric/shared/widgets/guide/trigger.dart';
import 'package:reveric/shared/widgets/settings/ai_providers_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestSettingsNotifier extends AppSettingsNotifier {
  _TestSettingsNotifier(this._providers);

  final List<AiProvider> _providers;

  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'zh-CN',
    aiSettings: AiSettings(providers: _providers),
  );
}

Widget _wrap({
  required Widget child,
  required AppDatabase db,
  required List<AiProvider> providers,
}) {
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      appSettingsDatabaseProvider.overrideWithValue(db),
      appSettingsProvider.overrideWith(() => _TestSettingsNotifier(providers)),
    ],
    child: EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      fallbackLocale: const Locale('en'),
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
              child: Scaffold(body: child),
            ),
          );
        },
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(() {
    rootBundle.clear();
    resetGuideTourLockForTest();
    setGuideDebugForceShow(false);
  });

  group('hasConfiguredAiProvider', () {
    test('returns false for default unconfigured builtin providers', () {
      final settings = AiSettings(
        providers: [
          aiProviderBuiltinById('deepseek')!,
          aiProviderBuiltinById('openai')!,
        ],
      );
      expect(hasConfiguredAiProvider(settings), isFalse);
    });

    test('returns true once user fills an apiKey even before enabling', () {
      final settings = AiSettings(
        providers: [
          aiProviderBuiltinById('deepseek')!.copyWith(apiKey: 'sk-test'),
        ],
      );
      expect(hasConfiguredAiProvider(settings), isTrue);
    });
  });

  group('guide tour persistence', () {
    test('persists seen state in app_states and clears on reset', () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);

      expect(await hasSeenGuideTour(db, GuideTourId.aiProviders), isFalse);
      await markGuideTourSeen(db, GuideTourId.aiProviders);
      await markGuideTourSeen(db, GuideTourId.home);
      expect(await hasSeenGuideTour(db, GuideTourId.aiProviders), isTrue);
      expect(await hasSeenGuideTour(db, GuideTourId.home), isTrue);

      await clearOnboardingAndFeatureUsageRecords(db);
      expect(await hasSeenGuideTour(db, GuideTourId.aiProviders), isFalse);
      expect(await hasSeenGuideTour(db, GuideTourId.home), isFalse);
    });
  });

  testWidgets(
    'desktop AiProvidersSection auto-triggers guide when unconfigured and allows stepping without API key',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      var openedModelSettings = false;

      await tester.pumpWidget(
        _wrap(
          db: db,
          providers: [
            aiProviderBuiltinById('deepseek')!,
            aiProviderBuiltinById('openai')!,
          ],
          child: AiProvidersSection(
            onOpenModelSettings: () => openedModelSettings = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Step 1: 供应商列表
      expect(
        find.byKey(const ValueKey('guide-step-providers_list')),
        findsOneWidget,
      );

      // Next -> Step 2: 添加自定义供应商
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('guide-step-providers_add')),
        findsOneWidget,
      );

      // Back -> Step 1
      await tester.tap(find.text('上一步'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('guide-step-providers_list')),
        findsOneWidget,
      );

      // Walk through all remaining steps without entering any API key or enabling
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
      }
      expect(
        find.byKey(const ValueKey('guide-step-providers_enable')),
        findsOneWidget,
      );

      // Click CTA to jump to model settings
      await tester.tap(find.text('去看看模型设置'));
      await tester.pumpAndSettle();
      expect(openedModelSettings, isTrue);
      expect(await hasSeenGuideTour(db, GuideTourId.aiProviders), isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'AiProvidersSection does not auto-trigger guide when user already configured a provider',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        _wrap(
          db: db,
          providers: [
            aiProviderBuiltinById(
              'deepseek',
            )!.copyWith(apiKey: 'sk-configured'),
          ],
          child: const AiProvidersSection(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('guide-step-providers_list')),
        findsNothing,
      );
      expect(await hasSeenGuideTour(db, GuideTourId.aiProviders), isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'mobile AiProvidersSection auto-triggers mobile guide and invokes model settings CTA',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      var openedModelSettings = false;

      await tester.pumpWidget(
        _wrap(
          db: db,
          providers: [aiProviderBuiltinById('deepseek')!],
          child: AiProvidersSection(
            onOpenModelSettings: () => openedModelSettings = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('guide-step-mobile_providers_list')),
        findsOneWidget,
      );
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
      }
      expect(
        find.byKey(const ValueKey('guide-step-mobile_providers_models')),
        findsOneWidget,
      );
      await tester.tap(find.text('去看看模型设置'));
      await tester.pumpAndSettle();
      expect(openedModelSettings, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'debug force-show switch bypasses configured provider & seen checks without polluting saved records',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      setGuideDebugForceShow(true);
      addTearDown(() => setGuideDebugForceShow(false));

      await tester.pumpWidget(
        _wrap(
          db: db,
          providers: [
            aiProviderBuiltinById(
              'deepseek',
            )!.copyWith(apiKey: 'sk-configured'),
          ],
          child: const AiProvidersSection(),
        ),
      );
      await tester.pumpAndSettle();

      // Forced visible even though provider already has an API key
      expect(
        find.byKey(const ValueKey('guide-step-providers_list')),
        findsOneWidget,
      );
      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('guide-step-providers_list')),
        findsNothing,
      );

      // Debug force-show should not pollute real persisted guide_tour_seen.* records
      expect(await hasSeenGuideTour(db, GuideTourId.aiProviders), isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('guide onBeforeEnter switches the page after the overlay frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      _wrap(db: db, providers: const [], child: const _TabSwitchHost()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('open-guide'));
    await tester.pumpAndSettle();
    expect(find.text('list-visible'), findsOneWidget);
    expect(find.byKey(const ValueKey('guide-step-list')), findsOneWidget);

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('plaza-body'), findsOneWidget);
    expect(find.byKey(const ValueKey('guide-step-plaza')), findsOneWidget);

    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(find.text('list-visible'), findsOneWidget);
    expect(find.text('plaza-body'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'stepping past a home nav item with childTours runs subpage tours in order and resumes home',
    (tester) async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        _wrap(db: db, providers: const [], child: const _ChainHost()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Home models nav'), findsOneWidget);

      // Click Next on models nav -> enters AI providers subpage tour first
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('providers-page'), findsOneWidget);
      expect(find.text('Providers step'), findsOneWidget);
      // Since home tour resumes afterwards, last step of child tour shows 下一步
      expect(find.text('下一步'), findsOneWidget);

      // Finish providers subpage tour -> resumes home at skills nav
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('Home skills nav'), findsOneWidget);

      // Click Next on skills nav -> enters skills subpage tour
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('skills-page'), findsOneWidget);
      expect(find.text('Skills step'), findsOneWidget);

      // Finish skills subpage tour -> resumes home at final usage nav
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('Home usage nav'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('Home usage nav'), findsNothing);
      expect(await hasSeenGuideTour(db, GuideTourId.home), isTrue);
      expect(await hasSeenGuideTour(db, GuideTourId.aiProviders), isTrue);
      expect(await hasSeenGuideTour(db, GuideTourId.skills), isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'skipping inside a child subpage tour cancels remaining parent steps',
    (tester) async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        _wrap(db: db, providers: const [], child: const _ChainHost()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Home models nav'), findsOneWidget);

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('Providers step'), findsOneWidget);

      // Dismiss inside providers subpage -> stays on providers page, does not resume home
      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();
      expect(find.text('providers-page'), findsOneWidget);
      expect(find.text('Home skills nav'), findsNothing);
      expect(find.text('Home usage nav'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'onPrimaryAction navigation still auto-triggers destination tour without lock race',
    (tester) async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        _wrap(db: db, providers: const [], child: const _PrimaryActionHost()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Home jump step'), findsOneWidget);

      await tester.tap(find.text('跳去供应商'));
      await tester.pumpAndSettle();
      expect(find.text('providers-page'), findsOneWidget);
      expect(find.text('Providers step'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'debug force-show chained flow never stacks duplicate overlays when child tours finish',
    (tester) async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      setGuideDebugForceShow(true);
      addTearDown(() => setGuideDebugForceShow(false));

      await tester.pumpWidget(
        _wrap(db: db, providers: const [], child: const _ChainHost()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-close-button')), findsOneWidget);
      expect(find.text('Home models nav'), findsOneWidget);

      // Home models -> Providers subpage
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-close-button')), findsOneWidget);
      expect(find.text('Providers step'), findsOneWidget);

      // Finish providers -> Home skills (providers must NOT re-trigger underneath)
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-close-button')), findsOneWidget);
      expect(find.text('Home skills nav'), findsOneWidget);
      expect(find.text('Providers step'), findsNothing);

      // Home skills -> Skills subpage
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-close-button')), findsOneWidget);
      expect(find.text('Skills step'), findsOneWidget);

      // Finish skills -> Home usage (skills must NOT re-trigger underneath)
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-close-button')), findsOneWidget);
      expect(find.text('Home usage nav'), findsOneWidget);
      expect(find.text('Skills step'), findsNothing);

      // Finish home -> returns to novel page and no overlays left
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-close-button')), findsNothing);
      expect(find.text('home-page'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

class _ChainHost extends HookConsumerWidget {
  const _ChainHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePage = useState('home');
    useAutoGuideTour(
      ref: ref,
      tourId: GuideTourId.home,
      buildSteps: (_) => [
        GuideStep(
          id: 'home-models',
          title: 'Home models nav',
          description: 'Models',
          onBeforeEnter: () => activePage.value = 'providers',
          childTours: const [GuideTourId.aiProviders],
        ),
        GuideStep(
          id: 'home-skills',
          title: 'Home skills nav',
          description: 'Skills',
          onBeforeEnter: () => activePage.value = 'skills',
          childTours: const [GuideTourId.skills],
        ),
        GuideStep(
          id: 'home-usage',
          title: 'Home usage nav',
          description: 'Usage',
          onBeforeEnter: () => activePage.value = 'usage',
        ),
      ],
      onClosed: (completed) {
        if (completed) {
          activePage.value = 'home';
        }
      },
    );
    useOnListenableChange(guideTourChain.current, () {
      switch (guideTourChain.current.value) {
        case GuideTourId.aiProviders:
          activePage.value = 'providers';
        case GuideTourId.skills:
          activePage.value = 'skills';
        case GuideTourId.home || null:
          break;
      }
    });
    return switch (activePage.value) {
      'providers' => const _ProvidersFollowUp(),
      'skills' => const _SkillsFollowUp(),
      'usage' => const Text('usage-page'),
      _ => const Text('home-page'),
    };
  }
}

class _PrimaryActionHost extends HookConsumerWidget {
  const _PrimaryActionHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showProviders = useState(false);
    useAutoGuideTour(
      ref: ref,
      tourId: GuideTourId.home,
      buildSteps: (_) => [
        GuideStep(
          id: 'home-jump',
          title: 'Home jump step',
          description: 'Jump',
          primaryActionLabel: '跳去供应商',
          onPrimaryAction: () => showProviders.value = true,
        ),
      ],
    );
    return showProviders.value
        ? const _ProvidersFollowUp()
        : const Text('home-page');
  }
}

class _ProvidersFollowUp extends HookConsumerWidget {
  const _ProvidersFollowUp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useAutoGuideTour(
      ref: ref,
      tourId: GuideTourId.aiProviders,
      buildSteps: (_) => const [
        GuideStep(
          id: 'providers-end',
          title: 'Providers step',
          description: 'Providers',
        ),
      ],
    );
    return const Text('providers-page');
  }
}

class _SkillsFollowUp extends HookConsumerWidget {
  const _SkillsFollowUp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useAutoGuideTour(
      ref: ref,
      tourId: GuideTourId.skills,
      buildSteps: (_) => const [
        GuideStep(
          id: 'skills-end',
          title: 'Skills step',
          description: 'Skills',
        ),
      ],
    );
    return const Text('skills-page');
  }
}

class _TabSwitchHost extends StatefulWidget {
  const _TabSwitchHost();

  @override
  State<_TabSwitchHost> createState() => _TabSwitchHostState();
}

class _TabSwitchHostState extends State<_TabSwitchHost> {
  var showPlaza = false;
  final plazaKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(showPlaza ? 'plaza-visible' : 'list-visible'),
        TextButton(
          onPressed: () {
            showGuideTour(
              context,
              steps: [
                GuideStep(
                  id: 'list',
                  title: 'List step',
                  description: 'Installed list',
                  onBeforeEnter: () {
                    if (showPlaza) {
                      setState(() => showPlaza = false);
                    }
                  },
                ),
                GuideStep(
                  id: 'plaza',
                  title: 'Plaza step',
                  description: 'Skill plaza',
                  targetKey: plazaKey,
                  onBeforeEnter: () {
                    if (!showPlaza) {
                      setState(() => showPlaza = true);
                    }
                  },
                ),
              ],
            );
          },
          child: const Text('open-guide'),
        ),
        if (showPlaza)
          SizedBox(
            key: plazaKey,
            width: 120,
            height: 48,
            child: const Text('plaza-body'),
          ),
      ],
    );
  }
}
