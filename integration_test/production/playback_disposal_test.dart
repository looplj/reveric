// 职责: 用真实音视频验证 MDK 播放结束后的定位，以及停止完成后的纹理释放。
// 关联文件:
//   third/fvp/lib/src/player.dart
//   lib/shared/services/production/runtime.dart
//   lib/shared/services/production/ffmpeg_runner.dart
//   lib/shared/services/production/playback_service.dart

import 'dart:ffi';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fvp/mdk.dart';
import 'package:fvp/src/generated_bindings.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/playback_service.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => binding.platformDispatcher.semanticsEnabledTestValue = false);
  tearDown(binding.platformDispatcher.clearSemanticsEnabledTestValue);

  for (final hasAudio in [true, false]) {
    testWidgets(
      'seeks to a paused frame after completion (audio: $hasAudio)',
      (tester) async {
        final directory = await Directory.systemTemp.createTemp(
          'reveric_playback_seek_',
        );
        final playback = PlaybackService();
        try {
          final path = '${directory.path}/seek.mp4';
          await FfmpegRunner().execute(
            [
              '-y',
              '-f',
              'lavfi',
              '-i',
              'testsrc2=size=160x90:rate=24',
              if (hasAudio) ...[
                '-f',
                'lavfi',
                '-i',
                'sine=frequency=440:sample_rate=48000',
              ],
              '-t',
              '2',
              '-c:v',
              'libx264',
              '-pix_fmt',
              'yuv420p',
              if (hasAudio) ...['-c:a', 'aac', '-af', 'volume=0.01'],
              path,
            ],
            probe: false,
            cancellation: MediaCancellation(),
          );
          await playback.open(owner: 'seek', path: path, play: true);
          final player = playback.player;
          await _waitFor(
            () async =>
                player.value.position >= const Duration(milliseconds: 250),
          );
          await player.pause();
          expect(player.value.isCompleted, isFalse);
          expect(player.value.isPlaying, isFalse);
          await player.play();
          await _waitFor(() async => player.value.isCompleted);
          expect(player.value.isCompleted, isTrue);
          const target = Duration(milliseconds: 500);
          bool atTarget(Duration? position) =>
              position != null &&
              (position - target).abs().inMilliseconds <= 100;
          await player.seekTo(target);
          await _waitFor(() async => atTarget(await player.position));
          expect(
            atTarget(await player.position),
            isTrue,
            reason: 'Native decoder position: ${await player.position}',
          );
          expect(player.value.isCompleted, isFalse);
          expect(player.value.isPlaying, isFalse);
          await player.play();
          await _waitFor(
            () async =>
                player.value.position > target && player.value.isPlaying,
          );
          expect(player.value.isPlaying, isTrue);
          expect(player.value.position, greaterThan(target));
          expect(player.value.position, lessThan(const Duration(seconds: 1)));
          expect(tester.takeException(), isNull);
        } finally {
          await playback.dispose();
          await directory.delete(recursive: true);
        }
      },
      semanticsEnabled: false,
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }

  testWidgets(
    'stops native audio before detaching the video renderer',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'reveric_playback_disposal_',
      );
      final path = '${directory.path}/audio-video.mp4';
      try {
        await FfmpegRunner().execute(
          [
            '-y',
            '-f',
            'lavfi',
            '-i',
            'testsrc2=size=160x90:rate=24',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:sample_rate=48000',
            '-t',
            '4',
            '-c:v',
            'libx264',
            '-pix_fmt',
            'yuv420p',
            '-c:a',
            'aac',
            '-af',
            'volume=0.01',
            path,
          ],
          probe: false,
          cancellation: MediaCancellation(),
        );
        const cycles = 120;
        for (var cycle = 0; cycle < cycles; cycle++) {
          final player = _ObservedPlayer();
          try {
            player.media = path;
            expect(await player.prepare(), greaterThanOrEqualTo(0));
            final texture = await player.updateTexture();
            expect(texture, greaterThanOrEqualTo(0));
            expect(player.mediaInfo.audio, isNotEmpty);
            // Native rendering and audio disposal must also work while the host
            // window is occluded. Keep the native texture without pumping UI frames.
            player.state = PlaybackState.playing;
            final deadline = DateTime.now().add(const Duration(seconds: 5));
            while (player.position < 150 && DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 25));
            }
            expect(player.position, greaterThanOrEqualTo(150));
            if (cycle % 3 != 0) {
              player.state = PlaybackState.paused;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            if (cycle % 3 == 2) {
              await player.seek(position: 1000);
              player.state = PlaybackState.playing;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
            if (cycle == cycles - 1) {
              // Already-stopped players must not wait for another state event.
              await player.onStateChanged.firstWhere(
                (event) => event.newValue == PlaybackState.stopped,
              );
            }
            debugPrint('DISPOSE_BEGIN cycle=$cycle state=${player.state}');
          } finally {
            await Future.wait([player.dispose(), player.dispose()]);
            await player.dispose();
          }
          debugPrint(
            'DISPOSE_END cycle=$cycle stoppedBeforeRelease='
            '${player.stoppedBeforeRelease}',
          );
          expect(
            player.stoppedBeforeRelease,
            isTrue,
            reason: 'The audio backend must stop while its renderer is alive',
          );
          expect(player.textureId.value, isNull);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(tester.takeException(), isNull);
        }
        // Allow deferred native texture unregistrations to run before exit.
        await Future<void>.delayed(const Duration(milliseconds: 600));
      } finally {
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _waitFor(Future<bool> Function() check) async {
  final elapsed = Stopwatch()..start();
  while (!await check() && elapsed.elapsed < const Duration(seconds: 6)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

class _ObservedPlayer extends Player {
  bool? stoppedBeforeRelease;

  @override
  Future<int> updateTexture({
    int? width,
    int? height,
    bool? tunnel,
    bool? fit,
  }) {
    if (width == -1) {
      // Query MDK itself, not Player.state, which caches the requested state.
      final api = Pointer<mdkPlayerAPI>.fromAddress(nativeHandle).ref;
      final nativeState = api.state
          .asFunction<int Function(Pointer<mdkPlayer>)>()(api.object);
      stoppedBeforeRelease = nativeState == MDK_State.MDK_State_Stopped;
    }
    return super.updateTexture(
      width: width,
      height: height,
      tunnel: tunnel,
      fit: fit,
    );
  }
}
