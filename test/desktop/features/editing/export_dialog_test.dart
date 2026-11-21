// 职责: 验证剪辑导出命名、关闭按钮对齐及经系统确认后的文件覆盖与取消。
// 关联文件:
//   lib/desktop/features/editing/export_dialog.dart
//   lib/desktop/features/editing/support.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'dart:io';
import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
// Use the platform test interface from file_selector's locked dependency.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/editing/export_dialog.dart';
import 'package:reveric/desktop/features/editing/support.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/components/reveric_select.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/editing/document.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/services/editing/render_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/confirm_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../shared/production/editing/commands_test.dart' show fixture;

class _SavePanel extends FileSelectorPlatform {
  String? path;
  String? suggestedName;
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    suggestedName = options.suggestedName;
    return path == null ? null : FileSaveLocation(path!);
  }
}

class _Renderer implements EditingRenderService {
  _Renderer(this.output);
  final EncodedMedia output;
  final watermarks = <EditingWatermarkCorner?>[];
  @override
  Future<EncodedMedia> render(
    EditingDocument document, {
    required MediaCancellation cancellation,
    required EditingProgress progress,
    String resolution = '720p',
    String subtitles = EditingSubtitles.burn,
    EditingWatermarkCorner? watermark,
    bool preview = false,
  }) async {
    watermarks.add(watermark);
    return output;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(finder, findsWidgets);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  late FileSelectorPlatform original;
  late _SavePanel panel;
  late Directory directory;
  late _Renderer renderer;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() {
    rootBundle.clear();
    original = FileSelectorPlatform.instance;
    panel = _SavePanel();
    FileSelectorPlatform.instance = panel;
    directory = Directory.systemTemp.createTempSync(
      'reveric_export_dialog_test_',
    );
    final encoded = Directory('${directory.path}/encoded')..createSync();
    final source = File('${encoded.path}/video.mp4')
      ..writeAsStringSync('new video');
    renderer = _Renderer(
      EncodedMedia(
        source,
        const MediaInfo(
          duration: Duration(seconds: 14),
          hasAudio: true,
          hasVideo: true,
        ),
        encoded,
      ),
    );
  });
  tearDown(() {
    FileSelectorPlatform.instance = original;
    debugDefaultTargetPlatformOverride = null;
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    for (final locale in [const Locale('zh', 'CN'), const Locale('en')]) {
      testWidgets('$platform $locale episode filename and close alignment', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final zh = locale.languageCode == 'zh';
        await tester.pumpWidget(
          _wrap(
            locale,
            Builder(
              builder: (context) {
                expect(
                  editingEpisodeExportName(context, 1, '一脚踹飞'),
                  zh ? '第一集 一脚踹飞' : 'Episode 1 一脚踹飞',
                );
                expect(
                  editingEpisodeExportName(context, 21, ''),
                  zh ? '第二十一集' : 'Episode 21',
                );
                expect(
                  editingEpisodeExportName(context, 1, '雨/夜:风'),
                  zh ? '第一集 雨 夜 风' : 'Episode 1 雨 夜 风',
                );
                return EditingExportDialog(
                  renderer: renderer,
                  document: fixture(),
                  title: editingEpisodeExportName(context, 1, '一脚踹飞'),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final close = find.byTooltip(zh ? '关闭' : 'Close');
        final export = find.widgetWithText(RevericButton, zh ? '导出' : 'Export');
        for (final width in [1200.0, 650.0, 440.0]) {
          tester.view.physicalSize = Size(width, 1000);
          await tester.pumpAndSettle();
          expect(
            tester.getRect(close).right,
            closeTo(tester.getRect(export).right, 1),
          );
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  }

  testWidgets(
    'node export delivers rendered file directly and retries import without rendering again',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var attempts = 0;
      final pending = Completer<void>();
      await tester.pumpWidget(
        _wrap(
          const Locale('en'),
          EditingExportDialog(
            renderer: renderer,
            document: fixture(),
            title: '剪辑成片',
            onExportNode: (file, name) async {
              attempts++;
              expect(file.readAsStringSync(), 'new video');
              expect(name, '剪辑成片.mp4');
              if (attempts == 1) {
                throw StateError('node write failed');
              }
              await pending.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Save SRT'), findsNothing);
      final watermarkPicker = find.byType(
        RevericSelect<EditingWatermarkCorner?>,
      );
      expect(
        find.descendant(of: watermarkPicker, matching: find.text('None')),
        findsOneWidget,
      );
      await tester.tap(watermarkPicker);
      await tester.pumpAndSettle();
      for (final label in [
        'Top left',
        'Top right',
        'Bottom left',
        'Bottom right',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.text('Bottom right'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(RevericButton, 'Export as video node'),
      );
      await _until(tester, find.widgetWithText(RevericButton, 'Retry'));
      expect(attempts, 1);
      expect(panel.suggestedName, isNull);
      await tester.tap(find.widgetWithText(RevericButton, 'Retry'));
      await tester.pump();
      expect(attempts, 2);
      expect(renderer.output.file.existsSync(), isTrue);
      pending.complete();
      await _until(tester, find.text('Video node added to the canvas.'));
      expect(renderer.watermarks, [EditingWatermarkCorner.bottom_right]);
      expect(find.widgetWithText(RevericButton, 'Retry'), findsNothing);
      expect(panel.suggestedName, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'native MP4 overwrite is honored and sidecar overwrite is confirmed separately',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final target = File('${directory.path}/第一集 一脚踹飞.mp4')
        ..writeAsStringSync('old video');
      final srt = File('${directory.path}/第一集 一脚踹飞.srt')
        ..writeAsStringSync('old subtitles');
      await tester.pumpWidget(
        _wrap(
          const Locale('en'),
          EditingExportDialog(
            renderer: renderer,
            document: fixture(),
            title: '第一集 一脚踹飞',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save SRT'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(RevericButton, 'Export'));
      await _until(tester, find.widgetWithText(RevericButton, 'Save'));
      expect(renderer.watermarks, [null]);

      // A cancelled system panel must not write either file.
      await tester.tap(find.widgetWithText(RevericButton, 'Save'));
      await tester.pumpAndSettle();
      expect(panel.suggestedName, '第一集 一脚踹飞.mp4');
      expect(target.readAsStringSync(), 'old video');
      expect(srt.readAsStringSync(), 'old subtitles');

      panel.path = target.path;
      await tester.tap(find.widgetWithText(RevericButton, 'Save'));
      await _until(tester, find.byType(ConfirmDialog));
      await tester.tap(find.widgetWithText(RevericButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(target.readAsStringSync(), 'old video');
      expect(srt.readAsStringSync(), 'old subtitles');

      await tester.tap(find.widgetWithText(RevericButton, 'Save'));
      await _until(tester, find.byType(ConfirmDialog));
      await tester.tap(find.widgetWithText(RevericButton, 'Confirm'));
      await _until(tester, find.widgetWithText(RevericButton, 'Done'));
      expect(target.readAsStringSync(), 'new video');
      expect(srt.readAsStringSync(), EditingRenderService.srt(fixture()));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Widget _wrap(Locale locale, Widget child) => EasyLocalization(
  supportedLocales: [locale],
  path: 'assets/translations',
  assetLoader: const MergingAssetLoader(),
  startLocale: locale,
  fallbackLocale: locale,
  child: Builder(
    builder: (context) => MaterialApp(
      locale: context.locale,
      supportedLocales: context.supportedLocales,
      localizationsDelegates: context.localizationDelegates,
      theme: RevericThemeData.reveric.toThemeData(),
      home: RevericTheme(
        data: RevericThemeData.reveric,
        child: Scaffold(body: child),
      ),
    ),
  ),
);
