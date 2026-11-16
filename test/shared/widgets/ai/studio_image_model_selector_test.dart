// 职责: 验证跨平台临时模型选择保留供应商身份且不保存全局偏好。
// 关联文件:
//   lib/shared/widgets/ai/studio_image_model_selector.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/hooks.md
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/hooks/use_map_generate_form.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/studio_image_model_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  testWidgets('map drawer retains model selection and refreshes capabilities', (
    tester,
  ) async {
    final first = aiProviderBuiltinById(
      'openai',
    )!.copyWith(enabled: true, apiKey: 'test', imageModels: ['gpt-image-2']);
    final second = first.copyWith(
      id: 'second',
      imageModels: ['gpt-image-2.5-flare'],
    );
    final settings = AiSettings(
      providers: [first, second],
      defaultImageModelId: 'openai::gpt-image-2',
    );
    MapGenerateForm? latest;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [aiSettingsProvider.overrideWithValue(settings)],
        child: Consumer(
          builder: (context, ref, _) => HookBuilder(
            builder: (context) {
              latest = useMapGenerateForm(
                ref: ref,
                locations: const [],
                rootId: 'world',
                mapType: 'world',
                hasImage: false,
                lastStyleWord: null,
                parentMap: null,
                parentMapName: null,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final drawerForm = latest!;
    drawerForm.ratioId.value = 'unsupported';
    drawerForm.resolutionId.value = 'unsupported';
    drawerForm.qualityId.value = 'unsupported';
    drawerForm.modelId.value = 'second::gpt-image-2.5-flare';
    await tester.pumpAndSettle();
    expect(drawerForm.choices!.provider.id, 'second');
    expect(drawerForm.choices!.ratios, contains(drawerForm.ratioId.value));
    expect(
      drawerForm.choices!.resolutions,
      contains(drawerForm.resolutionId.value),
    );
    expect(drawerForm.choices!.qualities, contains(drawerForm.qualityId.value));
    expect(drawerForm.toRequest().modelId, 'second::gpt-image-2.5-flare');
    expect(latest!.modelId.value, drawerForm.modelId.value);
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
      ).read(aiSettingsProvider).defaultImageModelId,
      'openai::gpt-image-2',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets(
      '$platform selects an image model without saving a preference',
      (tester) async {
        String? selected;
        final config = aiProviderBuiltinById(
          'openai',
        )!.copyWith(imageModels: ['gpt-image-2', 'gpt-image-2.5-flare']);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              aiSettingsProvider.overrideWithValue(
                AiSettings(
                  providers: [
                    config.copyWith(enabled: true, apiKey: 'test-key'),
                  ],
                  defaultImageModelId: 'openai::gpt-image-2',
                ),
              ),
            ],
            child: EasyLocalization(
              supportedLocales: const [Locale('en')],
              path: 'assets/translations',
              assetLoader: const MergingAssetLoader(),
              fallbackLocale: const Locale('en'),
              startLocale: const Locale('en'),
              child: Builder(
                builder: (context) => MaterialApp(
                  builder: (context, child) => RevericTheme(
                    data: RevericThemeData.reveric,
                    child: child!,
                  ),
                  locale: context.locale,
                  supportedLocales: context.supportedLocales,
                  localizationsDelegates: context.localizationDelegates,
                  theme: RevericThemeData.reveric.toThemeData().copyWith(
                    platform: platform,
                  ),
                  home: RevericTheme(
                    data: RevericThemeData.reveric,
                    child: Scaffold(
                      body: HookBuilder(
                        builder: (context) {
                          final model = useState<String?>(null);
                          return SizedBox(
                            width: 332,
                            child: StudioImageModelSelector(
                              value: model.value,
                              onChanged: (value) {
                                selected = value;
                                model.value = value;
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('gpt-image-2'), findsOneWidget);
        await tester.tap(find.text('gpt-image-2'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('gpt-image-2.5-flare').last);
        await tester.pumpAndSettle();
        expect(selected, 'openai::gpt-image-2.5-flare');
        expect(find.text('gpt-image-2.5-flare'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
