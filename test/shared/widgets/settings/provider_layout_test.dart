// 职责: 验证供应商搜索、跨平台详情导航、渠道链接、配置编辑布局与新建草稿流程。
// 关联文件:
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/components/reveric_search_field.dart';
import 'package:reveric/shared/components/reveric_text_field.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/provider_brand.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/ai_providers_section.dart';
import 'package:reveric/shared/widgets/settings/provider_config_panel.dart';
import 'package:reveric/shared/widgets/settings/provider_draft.dart';
import 'package:reveric/shared/widgets/settings/provider_logo.dart';
import 'package:reveric/shared/widgets/settings/provider_overview.dart';
import 'package:reveric/shared/widgets/settings/provider_type_picker.dart';
import 'package:reveric/shared/widgets/settings/mobile_provider_list.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/components/reveric_filter_chip.dart';

final _metaso = aiProviderBuiltinById('metaso')!;
final _configs = [_metaso, aiProviderBuiltinById('deepseek')!];

class _Settings extends AppSettingsNotifier {
  final saved = <AiProvider>[];
  final added = <AiProvider>[];
  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'en',
    aiSettings: AiSettings(providers: _configs),
  );
  @override
  Future<void> setAiProviderConfig(AiProvider config) async {
    saved.add(config);
  }

  @override
  Future<String> addCustomProvider(AiProvider config) async {
    added.add(config);
    return config.id;
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());
  for (final (type, baseUrl) in [
    ('apikey', 'https://api.apikey.fan/v1'),
    ('infistar', 'https://infistar.cc/v1'),
  ]) {
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.android,
    ]) {
      for (final locale in [const Locale('en'), const Locale('zh', 'CN')]) {
        testWidgets(
          '$type sponsor overview and links on $platform in $locale',
          (tester) async {
            final mobile = platform == TargetPlatform.android;
            await tester.binding.setSurfaceSize(Size(mobile ? 360 : 900, 900));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final launched = <String>[];
            const channel = MethodChannel('plugins.flutter.io/url_launcher');
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              channel,
              (call) async {
                if (call.method == 'launch') {
                  launched.add((call.arguments as Map)['url'] as String);
                }
                return true;
              },
            );
            addTearDown(
              () => tester.binding.defaultBinaryMessenger
                  .setMockMethodCallHandler(channel, null),
            );
            late AiProvider draft;
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  appSettingsProvider.overrideWith(() => _Settings()),
                ],
                child: _wrap(
                  SingleChildScrollView(
                    child: Builder(
                      builder: (context) {
                        draft = newProviderDraft(
                          context,
                          AiProviderType.values.byName(type),
                        );
                        return ProviderOverview(config: draft);
                      },
                    ),
                  ),
                  locale.languageCode == 'zh',
                  locale: locale,
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              draft.name,
              type == 'apikey'
                  ? 'APIKEY.FAN'
                  : locale.languageCode == 'zh'
                  ? '无限星河'
                  : 'Infistar',
            );
            expect(draft.effectiveBaseUrl, baseUrl);
            expect(draft.supportedModelKinds, {AiModelKind.chat});
            final types = providerTypePickerTypes();
            expect(
              types.indexOf(AiProviderType.values.byName(type)),
              types.indexOf(
                    type == 'apikey'
                        ? AiProviderType.api88
                        : AiProviderType.apikey,
                  ) +
                  1,
            );
            expect(find.text('Claude · GPT · Gemini'), findsOneWidget);
            final buttons = find.byType(RevericButton);
            expect(buttons, findsNWidgets(2));
            for (var i = 0; i < 2; i++) {
              await tester.ensureVisible(buttons.at(i));
              await tester.tap(buttons.at(i));
              await tester.pumpAndSettle();
            }
            expect(launched, [
              providerChannelUrls[type],
              type == 'apikey'
                  ? 'https://apikey.fun/pricing?aff=axonhub'
                  : 'https://infistar.cc/pricing?aff=FQHYXMMS&ref_source=link',
            ]);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          },
          variant: TargetPlatformVariant.only(platform),
          timeout: const Timeout(Duration(minutes: 1)),
        );
      }
    }
  }
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets(
      'Qwen Token Plan draft and referral link on $platform',
      (tester) async {
        expect(
          providerTypePickerTypes(),
          contains(AiProviderType.qwen_token_plan),
        );
        final launched = <String>[];
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'launch') {
              launched.add((call.arguments as Map)['url'] as String);
            }
            return true;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        late AiProvider draft;
        await tester.pumpWidget(
          _wrap(
            Builder(
              builder: (context) {
                draft = newProviderDraft(
                  context,
                  AiProviderType.qwen_token_plan,
                );
                return ProviderOverview(config: draft);
              },
            ),
            false,
          ),
        );
        await tester.pumpAndSettle();
        expect(draft.type, 'qwen_token_plan');
        expect(draft.name, 'Qwen Token Plan');
        expect(
          draft.baseUrl,
          'https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1',
        );
        expect(
          find.text(
            'Access Qwen Token Plan for chat, image, video, and speech generation using your plan API key.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byType(RevericButton));
        await tester.pumpAndSettle();
        expect(launched, [providerChannelUrls['qwen_token_plan']]);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }
  testWidgets(
    'all bundled provider logos and an unknown channel render offline',
    (tester) async {
      expect(
        providerLogoAsset('openai_compatible'),
        providerLogoAsset('openai'),
      );
      await tester.pumpWidget(
        _wrap(
          Wrap(
            children: [
              for (final type in [
                ...providerLogoAssets.keys,
                'codex',
                'custom',
              ])
                ProviderLogo(type: type),
            ],
          ),
          false,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('C'), findsOneWidget);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.android,
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
        '$platform dark=$dark searches, opens details and saves the key',
        (tester) async {
          final mobile = platform == TargetPlatform.android;
          await tester.binding.setSurfaceSize(Size(mobile ? 360 : 900, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final settings = _Settings();
          final launched = <String>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
              if (call.method == 'launch') {
                launched.add((call.arguments as Map)['url'] as String);
              }
              return true;
            },
          );
          addTearDown(
            () =>
                tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                  const MethodChannel('plugins.flutter.io/url_launcher'),
                  null,
                ),
          );
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                appSettingsProvider.overrideWith(() => settings),
                aiSettingsProvider.overrideWithValue(
                  AiSettings(providers: _configs),
                ),
              ],
              child: _wrap(const AiProvidersSection(), dark),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final search = find.descendant(
            of: find.byType(RevericSearchField),
            matching: find.byType(EditableText),
          );
          await tester.enterText(search, 'seedance');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('DeepSeek'), findsNothing);
          await tester.enterText(search, 'no-such-provider');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('No matches'), findsOneWidget);
          await tester.enterText(search, '');
          await tester.pump();
          expect(find.text('DeepSeek'), findsOneWidget);
          if (mobile) {
            await tester.tap(find.text('METASO'));
            await tester.pumpAndSettle();
          }
          expect(find.byType(ProviderConfigPanel), findsOneWidget);
          expect(find.byType(ProviderLogo), findsWidgets);
          expect(
            find.descendant(
              of: find.byType(ProviderConfigPanel),
              matching: find.text('Chat models'),
            ),
            findsNothing,
          );
          expect(find.text('seedance-2.0'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text('Go to METASO · Get API key'));
          await tester.tap(find.text('Go to METASO · Get API key'));
          await tester.pumpAndSettle();
          expect(launched, ['https://metaso.cn/minimax-h3/?s=Reveric']);
          final keyField = find.descendant(
            of: find.widgetWithText(RevericTextField, 'API Key'),
            matching: find.byType(EditableText),
          );
          await tester.ensureVisible(keyField);
          await tester.enterText(keyField, 'test-key');
          await tester.pumpAndSettle();
          expect(settings.saved.last.apiKey, 'test-key');
          expect(settings.saved.last.videoModels, _metaso.videoModels);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        variant: TargetPlatformVariant.only(platform),
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }

  _draftFlowTests();
}

Future<_Settings> _pumpSection(
  WidgetTester tester, {
  required bool mobile,
}) async {
  await tester.binding.setSurfaceSize(Size(mobile ? 360 : 900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final settings = _Settings();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWith(() => settings),
        aiSettingsProvider.overrideWithValue(AiSettings(providers: _configs)),
      ],
      child: _wrap(const AiProvidersSection(), false),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

void _draftFlowTests() {
  testWidgets(
    'desktop draft: pick a type, guard leaving, save creates the provider',
    (tester) async {
      final settings = await _pumpSection(tester, mobile: false);
      await tester.tap(find.text('Add Custom'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderTypePickerPanel), findsOneWidget);
      expect(find.text('88API'), findsOneWidget);
      expect(find.text('OpenAI Compatible'), findsNothing);
      await tester.tap(find.text('API formats'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(RevericFilterChip),
          matching: find.text('Video'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('OpenAI Compatible'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('MiniMax'),
        100,
        scrollable: find.descendant(
          of: find.byType(ProviderTypePickerPanel),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.text('MiniMax'));
      await tester.pumpAndSettle();

      // 草稿在列表顶部与面板头部都标注未保存，未落库。
      expect(find.text('Unsaved'), findsNWidgets(2));
      expect(find.byType(ProviderConfigForm), findsOneWidget);
      expect(find.byType(ProviderConfigPanel), findsNothing);
      expect(find.text('Chat Models'), findsWidgets);
      expect(settings.added, isEmpty);
      expect(settings.saved, isEmpty);

      await tester.tap(find.text('DeepSeek'));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved'), findsNWidgets(2));

      await tester.tap(find.widgetWithText(RevericButton, 'Save'));
      await tester.pumpAndSettle();
      expect(settings.added, hasLength(1));
      expect(settings.added.single.type, AiProviderType.minimax.name);
      expect(settings.added.single.name, 'MiniMax');
      expect(settings.added.single.builtin, isFalse);
      // 未填密钥和模型，不满足启用条件。
      expect(settings.added.single.enabled, isFalse);
      expect(find.text('Unsaved'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'desktop draft: discard returns to the previous provider',
    (tester) async {
      final settings = await _pumpSection(tester, mobile: false);
      await tester.tap(find.text('DeepSeek'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Custom'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('API formats'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenAI Compatible'));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved'), findsNWidgets(2));

      await tester.tap(find.widgetWithText(RevericButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved'), findsNothing);
      final panel = tester.widget<ProviderConfigPanel>(
        find.byType(ProviderConfigPanel),
      );
      expect(panel.providerId, 'deepseek');
      expect(settings.added, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'mobile draft: sheet picks the type, back asks before discarding',
    (tester) async {
      final settings = await _pumpSection(tester, mobile: true);
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Add provider'), findsOneWidget);
      expect(find.text('88API'), findsOneWidget);
      expect(find.text('OpenAI Compatible'), findsNothing);
      await tester.tap(find.text('API formats'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(RevericFilterChip),
          matching: find.text('Video'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Doubao'));
      await tester.pumpAndSettle();
      expect(find.text('New provider'), findsOneWidget);
      expect(find.text('Unsaved'), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('New provider'), findsNothing);
      expect(find.byType(MobileProviderList), findsOneWidget);
      expect(settings.added, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Widget _wrap(Widget child, bool dark, {Locale locale = const Locale('en')}) {
  final theme = dark ? RevericThemeData.revericDark : RevericThemeData.reveric;
  return EasyLocalization(
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    startLocale: locale,
    fallbackLocale: const Locale('en'),
    child: Builder(
      builder: (context) => MaterialApp(
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        theme: theme.toThemeData(),
        builder: (_, child) => RevericTheme(data: theme, child: child!),
        home: Scaffold(body: child),
      ),
    ),
  );
}
