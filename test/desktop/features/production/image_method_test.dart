// 职责: 验证切换和移除预设始终保留用户输入。
// 关联文件:
//   lib/desktop/features/production/view/method.dart
//   lib/desktop/features/production/prompt_field.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/production/popover.dart';
import 'package:reveric/desktop/features/production/view/method.dart';
import 'package:reveric/desktop/features/production/prompt_field.dart';
import 'package:reveric/desktop/features/production/prompt_controller.dart';
import 'package:reveric/desktop/features/storyboard/edit_form.dart';
import 'package:reveric/shared/form/form.dart';
import 'package:reveric/shared/models/production/view_presets.dart';
import '../../director/harness.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(initializeDirectorTest);

  testWidgets('switching and removing presets never replaces custom text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prompt = ProductionPromptController('保留我的描述');
    addTearDown(prompt.dispose);
    late FormFieldsController<ShotField> form;
    await tester.pumpWidget(
      directorTestApp(
        HookBuilder(
          builder: (context) {
            form = useForm<ShotField>(
              listen: false,
              initialValues: {
                ShotField.imagePreset: const ImageGenerationPreset(
                  complexity: 'low',
                ),
                ShotField.ratio: '1:1',
              },
            );
            return Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 800,
                child: HookedForm(
                  form: form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const ProductionImageMethodButton(),
                      ProductionPromptField(
                        controller: prompt,
                        onReference: () {},
                        footer: false,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 未选预设时只显示「预设」按钮，没有预设名称和展开箭头。
    expect(find.byType(ProductionCaret), findsNothing);
    ImageGenerationMethod method() =>
        form.getValue<ImageGenerationPreset>(ShotField.imagePreset)!.method;
    String? complexity() =>
        form.getValue<ImageGenerationPreset>(ShotField.imagePreset)!.complexity;
    Future<void> select(String label) async {
      final button = find.byTooltip('Presets');
      await tester.tap(
        button.evaluate().isEmpty ? find.byType(ProductionCaret) : button,
      );
      await tester.pumpAndSettle();
      // 分组标题与两列预设同时可见。
      expect(find.text('Design sheets'), findsOneWidget);
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(prompt.source, '保留我的描述');
      expect(tester.takeException(), isNull);
    }

    await select('720° panorama');
    expect(method(), ImageGenerationMethod.panorama);
    expect(form.getValue<String>(ShotField.ratio), '2:1');
    expect(complexity(), 'low');
    await select('Character turnaround');
    expect(method(), ImageGenerationMethod.character_turnaround);
    expect(find.text('Character turnaround'), findsOneWidget);
    expect(complexity(), 'low');
    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(method(), ImageGenerationMethod.free);
    expect(complexity(), 'low');
    expect(prompt.source, '保留我的描述');
    expect(find.byType(ProductionCaret), findsNothing);
    expect(find.byTooltip('Presets'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
