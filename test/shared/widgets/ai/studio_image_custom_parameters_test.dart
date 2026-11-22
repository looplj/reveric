// 职责: 验证未登记图片模型参数组件 — 地图/封面场景预置、就地自定义校验、外部回填与 IME 组词安全。
// 关联文件:
//   lib/shared/widgets/ai/studio_image_custom_parameters.dart
//   lib/shared/models/image/choices.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md
//   .agents/rules/text-input-ime.md
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/image/choices.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/studio_image_custom_parameters.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(() => rootBundle.clear());

  testWidgets(
    'map presets, incomplete size validation, external restore, and IME composing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final state = ValueNotifier<CustomImageParameters>(
        defaultCustomImageParameters,
      );
      addTearDown(state.dispose);
      final emissions = <CustomImageParameters>[];

      await tester.pumpWidget(
        _wrap(
          ValueListenableBuilder<CustomImageParameters>(
            valueListenable: state,
            builder: (context, value, _) => Padding(
              padding: const EdgeInsets.all(RevericSpacing.md),
              child: StudioImageCustomParameters(
                parameters: value,
                enabled: true,
                scene: StudioImageParameterScene.map,
                onChanged: (next) {
                  emissions.add(next);
                  state.value = next;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 地图场景预置 16:9 宽屏等常用横版尺寸。
      expect(
        find.byKey(const ValueKey('studio_image_size_1792x1024')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('studio_image_size_1792x1024')),
      );
      await tester.pump();
      expect(state.value, (quality: null, size: '1792x1024'));

      // 切回默认后再开自定义，只填宽度时给出缺失高度提示并保留非法尺寸值阻断误提交。
      await tester.tap(find.byKey(const ValueKey('studio_image_size_default')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('studio_image_size_custom')));
      await tester.pumpAndSettle();

      final widthField = find.byKey(
        const ValueKey('studio_image_custom_width_input'),
      );
      final heightField = find.byKey(
        const ValueKey('studio_image_custom_height_input'),
      );
      await tester.enterText(widthField, '1280');
      await tester.pump();
      expect(find.text('Enter both width and height.'), findsOneWidget);
      expect(state.value.size, '1280x');

      await tester.enterText(heightField, '720');
      await tester.pump();
      expect(find.text('Enter both width and height.'), findsNothing);
      expect(state.value.size, '1280x720');

      // IME 组词期间不向外发送半成品质量值，也不丢焦点。
      await tester.tap(
        find.byKey(const ValueKey('studio_image_quality_custom')),
      );
      await tester.pumpAndSettle();
      final qualityField = find.byKey(
        const ValueKey('studio_image_custom_quality_input'),
      );
      final qualityWidget = tester.widget<TextField>(qualityField);
      final beforeComposing = emissions.length;
      qualityWidget.controller!.value = const TextEditingValue(
        text: 'hd',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      qualityWidget.onChanged?.call('hd');
      await tester.pump();
      expect(emissions.length, beforeComposing);
      expect(qualityWidget.focusNode?.hasFocus, isTrue);

      // 外部回填（模拟历史批次恢复与新建重置）不触发 build 期异常，并同步展开/收起态。
      state.value = (quality: 'ultra', size: '900x1200');
      await tester.pumpAndSettle();
      expect(qualityWidget.controller?.text, 'ultra');
      expect(tester.widget<TextField>(widthField).controller?.text, '900');
      expect(tester.widget<TextField>(heightField).controller?.text, '1200');

      state.value = defaultCustomImageParameters;
      await tester.pumpAndSettle();
      expect(qualityField, findsNothing);
      expect(widthField, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
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
        return MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(),
          home: RevericTheme(
            data: RevericThemeData.reveric,
            child: Scaffold(body: SingleChildScrollView(child: child)),
          ),
        );
      },
    ),
  );
}
