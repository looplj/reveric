// 职责: 验证派生面板跨桌面布局、参数提交、重置和模型筛选。
// 关联文件:
//   lib/desktop/features/production/view/panel.dart
//   lib/desktop/features/production/view/models.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/production/view/panel.dart';
import 'package:reveric/desktop/features/production/view/models.dart';
import 'package:reveric/shared/models/production/view_presets.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import '../../director/harness.dart';

void main() {
  test('custom image models remain selectable for reference-based views', () {
    const option = AiModelOption(
      providerId: 'router',
      providerDisplayName: 'Router',
      model: 'custom-image',
      kind: AiModelKind.image,
    );
    final provider = aiProviderBuiltinDefaults.first.copyWith(
      id: 'router',
      type: 'openrouter',
      enabled: true,
      imageModels: [option.model],
    );
    for (final panorama in [false, true]) {
      expect(
        viewModelOptions(
          options: [option],
          providers: [provider],
          panorama: panorama,
        ),
        [option],
      );
      expect(
        viewModelOptions(
          options: [option],
          providers: [provider.copyWith(enabled: false)],
          panorama: panorama,
        ),
        isEmpty,
      );
    }
  });

  setUp(() => rootBundle.clear());
  setUpAll(initializeDirectorTest);
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    for (final width in [360.0, 900.0]) {
      testWidgets(
        'camera and lighting fit $platform at $width',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          for (final preset in [ViewPreset.camera, ViewPreset.light]) {
            await tester.pumpWidget(
              directorTestApp(
                Align(
                  alignment: Alignment.topCenter,
                  child: ViewPresetForm(
                    key: ValueKey(preset),
                    preset: preset,
                    imagePath: null,
                    onSubmit: (_) async {},
                    onClose: () {},
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(find.text('Generate'), findsOneWidget);
          }
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }
  testWidgets('camera choices and optional text submit and reset as one form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ViewPresetArgs? result;
    await tester.pumpWidget(
      directorTestApp(
        Align(
          alignment: Alignment.topCenter,
          child: ViewPresetForm(
            preset: ViewPreset.camera,
            imagePath: null,
            onSubmit: (args) async {
              result = args;
            },
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'Keep the red coat');
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();
    expect(result!.framing, CameraFraming.close);
    expect(result!.description, 'Keep the red coat');
    await tester.tap(find.text('Reset to default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();
    expect(result!.framing, CameraFraming.medium);
    expect(result!.description, isEmpty);
  });
  testWidgets('lighting choices reach submission and reset defaults', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ViewPresetArgs? result;
    await tester.pumpWidget(
      directorTestApp(
        Align(
          alignment: Alignment.topCenter,
          child: ViewPresetForm(
            preset: ViewPreset.light,
            imagePath: null,
            onSubmit: (args) async {
              result = args;
            },
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hard'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cool'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();
    expect(result!.texture, LightTexture.hard);
    expect(result!.temperature, LightTemperature.cool);
    await tester.tap(find.text('Reset to default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();
    expect(result!.texture, LightTexture.soft);
    expect(result!.temperature, LightTemperature.neutral);
  });
  test(
    'panorama filters before resolving default or first available model',
    () {
      const regular = AiModelOption(
        providerId: 'openai',
        providerDisplayName: 'OpenAI',
        model: 'gpt-image-2',
        kind: AiModelKind.image,
      );
      const panoramic = AiModelOption(
        providerId: 'router',
        providerDisplayName: 'Router',
        model: 'tencent/hy-image-v3.5-preview',
        kind: AiModelKind.image,
      );
      final providers = [
        aiProviderBuiltinDefaults.first.copyWith(
          id: 'openai',
          name: 'OpenAI',
          type: 'openai',
          enabled: true,
          imageModels: [regular.model],
        ),
        aiProviderBuiltinDefaults.first.copyWith(
          id: 'router',
          name: 'Router',
          type: 'openrouter',
          enabled: true,
          imageModels: [panoramic.model],
        ),
      ];
      AiModelOption? resolve(
        List<AiModelOption> options, {
        bool panorama = false,
      }) => resolveViewModel(
        options: options,
        providers: providers,
        preferredOptionId: regular.id,

        panorama: panorama,
      );
      expect(resolve([regular, panoramic]), regular);
      expect(resolve([regular, panoramic], panorama: true), panoramic);
      expect(resolve([regular], panorama: true), isNull);
      expect(resolve([]), isNull);
    },
  );
}
