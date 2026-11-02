// 职责: 验证视频模型列表的添加、去重与删除，以及供应商模型类型隔离。
// 关联文件:
//   lib/shared/widgets/settings/provider_video_models.dart
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
import 'package:reveric/shared/widgets/settings/provider_video_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());
  for (final sample in [
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.android,
    ])
      for (final type in ['api88'])
        (type, platform, ['seedance-2.0官方版', 'veo-3.1']),
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.android,
    ])
      (
        'atlascloud',
        platform,
        ['bytedance/seedance-2.5', 'bytedance/seedance-2.0'],
      ),
    ('qwen', TargetPlatform.macOS, ['wan3.0-video', 'wan3.0-video-prime']),
    (
      'volcengine',
      TargetPlatform.windows,
      ['doubao-seedance-2-5-260628', 'doubao-seedance-2-0-260128'],
    ),
    (
      'agnes',
      TargetPlatform.windows,
      ['agnes-video-2.5', 'agnes-video-2.5-flash'],
    ),
    (
      'agnes',
      TargetPlatform.macOS,
      ['agnes-video-2.5', 'agnes-video-2.5-flash'],
    ),
  ]) {
    testWidgets(
      '${sample.$1} video models can be added and removed on ${sample.$2}',
      (tester) async {
        var provider = aiProviderBuiltinById(
          'openai',
        )!.copyWith(type: sample.$1, videoModels: []);
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
                  platform: sample.$2,
                ),
                home: RevericTheme(
                  data: RevericThemeData.reveric,
                  child: Scaffold(
                    body: SizedBox(
                      width: 400,
                      child: StatefulBuilder(
                        builder: (context, setState) => ProviderVideoModels(
                          config: provider,
                          onChanged: (models) => setState(
                            () => provider = provider.copyWith(
                              videoModels: models,
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
        expect(find.byType(RevericCheckbox), findsNothing);
        expect(find.text(sample.$3.first), findsNothing);
        final originalChatModels = provider.models;
        await tester.enterText(find.byType(TextField), '   ');
        await tester.tap(find.text('Add'));
        await tester.pump();
        expect(provider.videoModels, isEmpty);
        await tester.enterText(
          find.byType(TextField),
          '  ${sample.$3.first}  ',
        );
        await tester.tap(find.text('Add'));
        await tester.pump();
        expect(provider.videoModels, [sample.$3.first]);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        await tester.enterText(find.byType(TextField), sample.$3.first);
        await tester.tap(find.text('Add'));
        await tester.pump();
        expect(provider.videoModels, [sample.$3.first]);
        await tester.enterText(find.byType(TextField), sample.$3.last);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(provider.videoModels, sample.$3);
        await tester.tap(find.byTooltip('Delete').first);
        await tester.pump();
        expect(provider.videoModels, [sample.$3.last]);
        await tester.tap(find.byTooltip('Delete'));
        await tester.pump();
        expect(provider.videoModels, isEmpty);
        expect(provider.models, originalChatModels);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets('METASO video models show catalog highlights on $platform', (
      tester,
    ) async {
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
                    width: 400,
                    child: ProviderVideoModels(
                      config: aiProviderBuiltinById('metaso')!,
                      onChanged: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Up to 30s'), findsNWidgets(2));
      expect(find.text('Priority'), findsOneWidget);
      // 说明图标与「优先通道」徽标共用同一条计费提示。
      expect(
        find.byTooltip(
          'Generation is scheduled first; video is billed at 2× the current price.',
        ),
        findsNWidgets(2),
      );
      expect(find.byTooltip('Up to 30s'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  }
  test('MiniMax exposes only explicitly configured chat and video models', () {
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      type: 'minimax',
      baseUrl: '',
      apiKey: 'key',
      enabled: true,
      models: const [],
      videoModels: ['MiniMax-H3'],
    );
    expect(provider.effectiveBaseUrl, 'https://api.minimax.cn');
    expect(provider.availableModels, isEmpty);
    expect(provider.availableImageModels, isEmpty);
    expect(provider.availableVideoModels, ['MiniMax-H3']);
    expect(provider.isValid, true);
    expect(AiSettings(providers: [provider]).availableModelOptions, isEmpty);

    final withChat = provider.copyWith(models: ['MiniMax-M3']);
    expect(withChat.availableModels, ['MiniMax-M3']);
    expect(
      AiSettings(
        providers: [withChat],
      ).availableModelOptions.map((option) => option.model),
      ['MiniMax-M3'],
    );
  });
  test(
    'Qwen and Doubao expose video configuration without built-in video fallback',
    () {
      final qwen = aiProviderBuiltinById(
        'openai',
      )!.copyWith(type: 'qwen', baseUrl: '');
      expect(qwen.supportsModelKind(AiModelKind.video), true);
      expect(qwen.availableVideoModels, isEmpty);
      expect(qwen.effectiveBaseUrl, qwenDefaultBaseUrl);
      expect(aiProviderBuiltinById('doubao')!.availableVideoModels, isEmpty);
    },
  );
}
