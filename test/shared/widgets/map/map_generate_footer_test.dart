// 职责: 验证地图生成按钮在缺图片模型时改为打开模型设置，其余门禁保持禁用。
// 关联文件:
//   lib/shared/widgets/map/map_generate_footer.dart
//   lib/shared/providers/map_studio_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/en/map_editor.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/map_studio_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/map/map_generate_footer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(() {
    rootBundle.clear();
  });

  testWidgets('opens image model settings when no image model is set', (
    tester,
  ) async {
    var configureCount = 0;
    var generateCount = 0;
    await tester.pumpWidget(
      _wrap(
        selection: null,
        hasChildLocations: false,
        onConfigure: () => configureCount++,
        onGenerate: () => generateCount++,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Configure Image Model'), findsOneWidget);
    await tester.tap(find.text('Configure Image Model'));
    expect(configureCount, 1);
    expect(generateCount, 0);
  });

  testWidgets('keeps the generate button disabled without locations', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        selection: MapStudioImageModelSelection(
          config: _imageProvider,
          model: 'image-model',
        ),
        hasChildLocations: false,
        onConfigure: () {},
        onGenerate: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Configure Image Model'), findsNothing);
    final button = tester.widget<ButtonStyleButton>(
      find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('pending agent draft blocks even without an image model', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        selection: null,
        hasChildLocations: true,
        hasPendingAgentDraft: true,
        onConfigure: () {},
        onGenerate: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Configure Image Model'), findsNothing);
    final button = tester.widget<ButtonStyleButton>(
      find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    );
    expect(button.onPressed, isNull);
  });
}

Widget _wrap({
  required MapStudioImageModelSelection? selection,
  required bool hasChildLocations,
  required VoidCallback onConfigure,
  required VoidCallback onGenerate,
  bool hasPendingAgentDraft = false,
}) {
  return ProviderScope(
    overrides: [
      mapStudioImageModelSelectionProvider.overrideWithValue(selection),
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
                body: MapGenerateFooter(
                  databasePath: 'test.db',
                  mapId: 'map',
                  hasChildLocations: hasChildLocations,
                  hasPendingAgentDraft: hasPendingAgentDraft,
                  showGateTooltip: false,
                  onConfigureImageModel: onConfigure,
                  onGenerate: onGenerate,
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

final _imageProvider = AiProvider(
  asrModels: const [],
  audioModels: const [],
  videoModels: const [],
  id: 'external',
  name: 'External image provider',
  builtin: false,
  type: 'openai',
  enabled: true,
  apiKey: 'test-api-key',
  baseUrl: 'https://example.invalid/v1',
  models: const [],
  imageModels: const ['image-model'],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);
