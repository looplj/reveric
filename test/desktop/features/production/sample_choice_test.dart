// 职责: 验证样片在「比例 · 分辨率」里与分辨率互斥选择，pill 和发送按钮如实反映这次提交。
// 关联文件:
//   lib/desktop/features/production/spec_panel.dart
//   lib/desktop/features/production/generate_button.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/production/generate_button.dart';
import 'package:reveric/desktop/features/production/spec_panel.dart';
import '../../director/harness.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(initializeDirectorTest);

  testWidgets('audio switch reflects changes while the specs remain open', (
    tester,
  ) async {
    final audio = ValueNotifier(true);
    addTearDown(audio.dispose);
    await tester.pumpWidget(
      directorTestApp(
        Center(
          child: ValueListenableBuilder<bool>(
            valueListenable: audio,
            builder: (context, value, _) => ProductionSpecPill(
              ratios: const ['9:16'],
              resolutions: const ['720p'],
              ratio: '9:16',
              resolution: '720p',
              audio: value,
              onAudio: (value) => audio.value = value,
              onChanged: ({ratio, resolution}) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Audio on'), findsOneWidget);
    await tester.tap(find.text('9:16 · 720P · '));
    await tester.pumpAndSettle();
    expect(find.text('Generate audio'), findsOneWidget);
    expect(find.text('Turn off to generate a silent video'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(audio.value, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.byTooltip('Audio off'), findsOneWidget);
    await tester.tap(find.text('Generate audio'));
    await tester.pumpAndSettle();
    expect(audio.value, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'sample is picked beside resolutions and a resolution cancels it',
    (tester) async {
      final sample = ValueNotifier(false);
      addTearDown(sample.dispose);
      final picked = <String?>[];
      Future<void> show({required bool supportsDraft}) async {
        await tester.pumpWidget(
          directorTestApp(
            Center(
              child: ProductionSpecPill(
                ratios: const ['9:16', '16:9'],
                resolutions: const ['480p', '720p', '1080p'],
                ratio: '9:16',
                resolution: '1080p',
                sample: supportsDraft ? sample : null,
                onChanged: ({ratio, resolution}) => picked.add(resolution),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(supportsDraft: false);
      await tester.tap(find.text('9:16 · 1080P'));
      await tester.pumpAndSettle();
      expect(find.text('Sample'), findsNothing);

      await show(supportsDraft: true);
      await tester.tap(find.text('9:16 · 1080P'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sample'));
      await tester.pumpAndSettle();
      expect(sample.value, isTrue);
      expect(find.text('9:16 · 480P sample'), findsOneWidget);
      await tester.tap(find.text('720P'));
      await tester.pumpAndSettle();
      expect(sample.value, isFalse);
      expect(picked, ['720p']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('send button names the sample and explains blocked reasons', (
    tester,
  ) async {
    var calls = 0;
    Future<void> show({required bool draft, String? blocked}) async {
      await tester.pumpWidget(
        directorTestApp(
          Center(
            child: ProductionGenerateButton(
              onGenerate: () => calls++,
              blocked: blocked,
              draft: draft,
              repeat: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show(draft: true);
    await tester.tap(find.byTooltip('Generate sample'));
    await show(draft: false);
    await tester.tap(find.byTooltip('Generate'));
    await show(draft: true, blocked: 'Busy');
    await tester.tap(find.byTooltip('Busy'));
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
