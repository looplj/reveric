// 职责: 在桌面宿主验证无音轨视频首次预览、播放、定位和重新打开。
// 关联文件:
//   lib/desktop/features/asset/media_preview.dart
//   lib/desktop/features/asset/playback_controls.dart
//   lib/shared/services/production/playback_service.dart
//   test/fixtures/video_media.dart
//   test/desktop/director/harness.dart

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';
import 'package:window_manager/window_manager.dart';
import 'package:reveric/desktop/features/asset/media_preview.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/providers/production_media.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/playback_service.dart';

import '../../test/desktop/director/harness.dart';
import '../../test/fixtures/video_media.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    await initializeDirectorTest();
    // The test bypasses app startup, which normally shows the native window.
    await windowManager.ensureInitialized();
    await windowManager.show();
    await windowManager.focus();
  });

  testWidgets('silent video previews on first open and can be reopened', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('media_preview_');
    final db = AppDatabase.forTest(NativeDatabase.memory());
    final playback = PlaybackService();
    final media = MediaService(FfmpegRunner());
    await Directory('${directory.path}/media').create();
    final file = await File(
      '${directory.path}/media/silent.mp4',
    ).writeAsBytes(base64Decode(videoResultMp4Base64));
    final info = await media.probe(file.path);
    expect(
      info.hasAudio,
      false,
      reason: 'Exercise a video-only director output',
    );
    final now = DateTime.now();
    final asset = AssetRow(
      id: 'silent-video',
      type: 'video',
      name: '双人对话 · 机位 A · MP4',
      purpose: 'general',
      source: 'director',
      path: 'media/silent.mp4',
      favorite: false,
      inLibrary: false,

      createdAt: now,
      updatedAt: now,
      deletedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackServiceProvider.overrideWithValue(playback),
            mediaLibraryServiceProvider.overrideWithValue(
              MediaLibraryService(db, media, directory),
            ),
          ],
          child: directorTestApp(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => MediaPreviewDialog(
                    asset: asset,
                    pathResolver: MediaLibraryService(db, media, directory),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      debugPrint('Preview harness mounted');
      await tester.pumpAndSettle();
      for (var opening = 0; opening < 2; opening++) {
        debugPrint('Opening preview $opening');
        await tester.tap(find.text('open'));
        await _waitFor(
          tester,
          () => find.byType(VideoPlayer).evaluate().isNotEmpty,
        );
        debugPrint('Preview $opening ready');
        expect(playback.player.value.size.width, info.width);
        expect(playback.player.value.size.height, info.height);
        expect(find.byType(VideoPlayer), findsOneWidget);
        expect(find.byType(Texture), findsOneWidget);
        expect(playback.player.value.isPlaying, false);
        expect(find.text('Delete'), findsNothing);
        expect(find.text('Export'), findsNothing);
        await tester.tap(find.byTooltip('Play'));
        debugPrint('Preview $opening playing');
        await _waitFor(
          tester,
          () => playback.player.value.position.inMilliseconds >= 250,
        );
        await tester.tap(find.byTooltip('Pause'));
        debugPrint('Preview $opening paused');
        await tester.pumpAndSettle();
        expect(playback.player.value.isPlaying, false);
        final slider = tester.widget<Slider>(find.byType(Slider));
        slider.onChanged!(1000);
        await _waitFor(
          tester,
          () => playback.player.value.position.inMilliseconds >= 900,
        );
        await tester.tap(find.byTooltip('Close'));
        debugPrint('Preview $opening closed');
        await tester.pumpAndSettle();
        expect(find.byType(MediaPreviewDialog), findsNothing);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await playback.dispose();
      await db.close();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}

Future<void> _waitFor(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    condition(),
    true,
    reason: 'Native playback did not reach expected state',
  );
  await tester.pump();
}
