// 职责: 验证音频和语音转写模型列表在桌面和移动端的添加、删除及配置保留。
// 关联文件:
//   lib/shared/widgets/settings/provider_audio_models.dart
//   lib/shared/widgets/settings/provider_transcription.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/components/reveric_checkbox.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/provider_audio_models.dart';
import 'package:reveric/shared/widgets/settings/provider_transcription.dart';
import 'package:reveric/shared/models/ai_provider.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    for (final type in [
      'minimax',
      'doubao_audio',
      'openrouter',
      'atlascloud',
      'qwen',
      'api88',
    ]) {
      testWidgets('$type audio models can be added and removed on $platform', (
        tester,
      ) async {
        var provider = aiProviderBuiltinById(
          'openai',
        )!.copyWith(type: type, audioModels: ['existing-audio-model']);
        await tester.pumpWidget(
          EasyLocalization(
            supportedLocales: const [Locale('en')],
            path: 'assets/translations',
            assetLoader: const MergingAssetLoader(),
            fallbackLocale: const Locale('en'),
            startLocale: const Locale('en'),
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
                  child: Scaffold(
                    body: SizedBox(
                      width: platform == TargetPlatform.android ? 320 : 400,
                      child: StatefulBuilder(
                        builder: (context, setState) => ProviderAudioModels(
                          config: provider,
                          onChanged: (models) => setState(
                            () => provider = provider.copyWith(
                              audioModels: models,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final model = switch (type) {
          'api88' => 'gemini-3.1-flash-tts',
          'qwen' => 'qwen-audio-3.1-tts-next',
          'atlascloud' => 'bytedance/seed-audio-1.0',
          'minimax' => 'music-3.0',
          'openrouter' => 'bytedance-seed/seed-audio-1-0',
          _ => 'seed-audio-1.0',
        };
        expect(
          find.text(type == 'minimax' ? 'seed-audio-1.0' : 'music-3.0'),
          findsNothing,
        );
        expect(find.byType(RevericCheckbox), findsNothing);
        expect(find.text('existing-audio-model'), findsOneWidget);
        await tester.enterText(find.byType(TextField), model);
        await tester.tap(find.text('Add'));
        await tester.pump();
        expect(provider.audioModels, ['existing-audio-model', model]);
        await tester.tap(find.byTooltip('Delete').last);
        await tester.pump();
        expect(provider.audioModels, ['existing-audio-model']);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.android,
  ]) {
    testWidgets('ASR models can be entered manually on $platform', (
      tester,
    ) async {
      const modelId = 'custom-transcription-model';
      var provider = aiProviderBuiltinById(
        'openai',
      )!.copyWith(type: 'openrouter', asrModels: const []);
      await tester.pumpWidget(
        EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('en'),
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
                child: Scaffold(
                  body: SizedBox(
                    width: 360,
                    child: StatefulBuilder(
                      builder: (context, setState) =>
                          ProviderTranscriptionSettings(
                            provider: provider,
                            fetchButton: const SizedBox.shrink(),
                            onModelsChanged: (models) => setState(
                              () => provider = provider.copyWith(
                                asrModels: models,
                              ),
                            ),
                          ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final input = find.byType(TextField);
      final add = find.text('Add');
      expect(input, findsOneWidget);
      expect(add, findsOneWidget);
      await tester.enterText(input, modelId);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(provider.asrModels, [modelId]);
      expect(find.text(modelId), findsOneWidget);
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(provider.asrModels, isEmpty);
      expect(input, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
