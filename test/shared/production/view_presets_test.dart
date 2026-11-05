// 职责: 验证图片预设与派生模板的每个档位、引用与最近画幅选择。
// 关联文件:
//   lib/shared/models/production/view_presets.dart
//   lib/shared/services/production/view_derive_orchestrator.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/production/view_presets.dart';
import 'package:reveric/shared/models/storyboard/prompt.dart';
import 'package:reveric/shared/services/production/view_derive_orchestrator.dart';

void main() {
  test(
    'preset and user direction remain independent across method changes',
    () {
      const user = '保留木质屏风，不要改变暖色灯光。';
      for (final method in ImageGenerationMethod.values) {
        final preset = ImageGenerationPreset(method: method);
        final restored = ImageGenerationPreset.fromStyle({
          'imageGeneration': preset.toJson(),
        });
        final combined = restored.assemble(user, 'source');
        expect(combined, endsWith(user));
        expect(user, '保留木质屏风，不要改变暖色灯光。');
        if (method == ImageGenerationMethod.free) {
          expect(combined, user);
        } else {
          expect(
            StoryboardPrompt.parse(combined).references.single.inputId,
            'source',
          );
        }
      }
      expect(
        const ImageGenerationPreset(
          method: ImageGenerationMethod.panorama,
        ).assemble(user, null),
        allOf(contains('360°×180°'), endsWith(user), isNot(contains('<ref'))),
      );
      expect(
        () => const ImageGenerationPreset(
          method: ImageGenerationMethod.after_3s,
        ).assemble(user, null),
        throwsFormatException,
      );
      // 不依赖参考画面的预设在没有参考图时改按用户描述生成。
      expect(
        const ImageGenerationPreset(
          method: ImageGenerationMethod.character_turnaround,
        ).assemble(user, null),
        allOf(contains('用户描述'), endsWith(user), isNot(contains('<ref'))),
      );
    },
  );

  test('image preset keeps a complexity level through style json', () {
    const preset = ImageGenerationPreset(
      method: ImageGenerationMethod.free,
      complexity: 'low',
    );
    final restored = ImageGenerationPreset.fromStyle({
      'imageGeneration': preset.toJson(),
    });
    expect(restored.complexity, 'low');
    expect(
      ImageGenerationPreset.fromStyle({
        'imageGeneration': const ImageGenerationPreset().toJson(),
      }).complexity,
      isNull,
    );
  });

  test('all camera positions and framing expand with a live reference', () {
    for (final yaw in cameraYawFragments.entries) {
      for (final pitch in cameraPitchFragments.entries) {
        for (final framing in CameraFraming.values) {
          final text = expandViewPreset(
            ViewPreset.camera,
            ViewPresetArgs(yaw: yaw.key, pitch: pitch.key, framing: framing),
            'input',
          );
          expect(text, contains(yaw.value));
          expect(text, contains(pitch.value));
          expect(text, contains(cameraFramingFragments[framing.index]));
          expect(
            StoryboardPrompt.parse(text).references.single.inputId,
            'input',
          );
          expect(text, endsWith('保持原画面的光线与色调。'));
        }
      }
    }
    expect(
      () => expandViewPreset(
        ViewPreset.camera,
        const ViewPresetArgs(pitch: 90),
        'input',
      ),
      throwsFormatException,
    );
  });
  test('all lighting combinations preserve optional description', () {
    for (final direction in LightDirection.values) {
      for (final brightness in LightBrightness.values) {
        for (final texture in LightTexture.values) {
          for (final temperature in LightTemperature.values) {
            final text = expandViewPreset(
              ViewPreset.light,
              ViewPresetArgs(
                direction: direction,
                brightness: brightness,
                texture: texture,
                temperature: temperature,
                description: '  补充。 ',
              ),
              'input',
            );
            expect(text, contains(lightDirectionFragments[direction.index]));
            expect(text, contains(lightBrightnessFragments[brightness.index]));
            expect(text, contains(lightTextureFragments[texture.index]));
            expect(
              text,
              contains(lightTemperatureFragments[temperature.index]),
            );
            expect(text, endsWith('补充。'));
          }
        }
      }
    }
    expect(
      expandViewPreset(
        ViewPreset.panorama,
        const ViewPresetArgs(description: 'ignored'),
        'input',
      ),
      allOf(contains('2:1'), isNot(contains('ignored'))),
    );
  });
  test('media sources choose the closest supported concrete aspect ratio', () {
    expect(nearestImageRatio(1900, 1000, ['1:1', '16:9', '9:16']), '16:9');
    expect(nearestImageRatio(1000, 1900, ['1:1', '16:9', '9:16']), '9:16');
    expect(nearestImageRatio(1000, 1900, ['auto']), 'auto');
    expect(() => nearestImageRatio(0, 1000, ['1:1']), throwsFormatException);
  });
}
