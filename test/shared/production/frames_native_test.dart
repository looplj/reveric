// 职责: 使用显式 FFmpeg 验证图片序列交付，以及采样与完整剪辑画面的一致性。
// 关联文件:
//   lib/shared/services/editing/render_service.dart
//   lib/shared/services/ai/ffmpeg/command.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:reveric/shared/services/editing/commands.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/editing/document.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/services/ai/ffmpeg/command.dart';
import 'package:reveric/shared/services/ai/ffmpeg/arguments.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';
import 'package:reveric/shared/services/editing/render_service.dart';
import 'package:reveric/shared/services/editing/service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';

const _binary = String.fromEnvironment('FFMPEG_TEST_BIN');

class _NativeRunner extends FfmpegRunner {
  @override
  Future<FfmpegExecutionResult> executeCommand(
    List<String> args, {
    required MediaCancellation cancellation,
  }) => _run(args, false, cancellation);

  @override
  Future<String> execute(
    List<String> args, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    final result = await _run(args, probe, cancellation);
    if (result.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    if (result.exitCode != 0) {
      throw StateError('FFmpeg exited ${result.exitCode}: ${result.output}');
    }
    return result.output;
  }

  Future<FfmpegExecutionResult> _run(
    List<String> args,
    bool probe,
    MediaCancellation cancellation,
  ) async {
    if (cancellation.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    final process = await Process.start(
      probe ? p.join(p.dirname(_binary), 'ffprobe') : _binary,
      args,
    );
    await cancellation.bind(() async {
      process.kill();
    });
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    try {
      final code = await process.exitCode;
      final out = await stdout, err = await stderr;
      return FfmpegExecutionResult(
        exitCode: code,
        output: probe && code == 0 ? out : '$out$err',
        cancelled: cancellation.cancelled,
      );
    } finally {
      cancellation.unbind();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'inspect_audio measures a one-frame cut over music without writing session files',
    () async {
      final root = await Directory.systemTemp.createTemp('audio-inspect-');
      final app = AppDatabase.forTest(NativeDatabase.memory());
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final runner = _NativeRunner();
      final library = MediaLibraryService(app, MediaService(runner), root);
      final service = EditingService(db, library);
      final renderer = EditingRenderService(service, runner);
      addTearDown(() async {
        await renderer.dispose();
        await db.close();
        await app.close();
        await root.delete(recursive: true);
      });
      final dir = await Directory(
        '${root.path}/file_workspaces/work/audio',
      ).create(recursive: true);
      final path = '${dir.path}/tone.wav';
      await runner.execute(
        [
          '-f',
          'lavfi',
          '-i',
          "aevalsrc=if(lt(t\\,0.5)\\,0\\,0.3):s=48000:d=1",
          '-ac',
          '2',
          path,
        ],
        probe: false,
        cancellation: MediaCancellation(),
      );
      await app.assetDao.insertAsset(
        AssetsCompanion.insert(
          id: 'tone',
          type: 'audio',
          purpose: 'general',
          path: const Value('file_workspaces/work/audio/tone.wav'),
          content: const Value(AudioAssetContent(mimeType: 'audio/wav')),
        ),
      );
      final files = SessionFiles(root: root.path, novelId: 'work');
      final command = FfmpegCommand(files, runner);
      final source = await command.inspectAudio('audio/tone.wav', {
        'start_ms': 400,
        'end_ms': 700,
        'window_ms': 100,
      }, MediaCancellation());
      expect(source['silence_ranges'], [
        {'start_ms': 400, 'end_ms': 500},
      ]);
      expect(source['windows'][1]['peak_dbfs'], isA<double>());
      expect(source.containsKey('files'), isFalse);
      expect(
        await Directory('${root.path}/${files.sessionsPath}').exists(),
        isFalse,
      );
      expect(jsonEncode(source), isNotEmpty);
      await expectLater(
        command.inspectAudio('audio/tone.wav', {
          'start_ms': 999,
          'end_ms': 1100,
        }, MediaCancellation()),
        throwsFormatException,
      );
      final asset = await service.source('tone');
      final doc = EditingDocument.empty('16:9').copyWith(
        clips: [
          EditingClip(
            id: 'music',
            trackId: 'A3',
            startFrame: 0,
            durationFrames: 8,
            content: EditingAudioContent(
              source: asset,
              sourceInUs: 500000,
              gainDb: -20,
            ),
          ),
          EditingClip(
            id: 'burst',
            trackId: 'A2',
            startFrame: 4,
            durationFrames: 1,
            content: EditingAudioContent(source: asset, sourceInUs: 500000),
          ),
        ],
      );
      final audio = await renderer.inspectAudio(
        doc,
        2,
        7,
        clipId: 'burst',
        cancellation: MediaCancellation(),
      );
      expect(audio.mix.samples, 5 * editingSamplesPerFrame);
      expect(audio.clips.single['clip_id'], 'burst');
      final mix = audio.mix.levels(
        origin: 2,
        samplesPerUnit: editingSamplesPerFrame,
        window: 1,
        unit: 'frame',
      )['windows'];
      expect(
        mix[2]['rms_dbfs'] as double,
        greaterThan((mix[1]['rms_dbfs'] as double) + 15),
      );
      expect(
        audio.clips.singleWhere(
          (clip) => clip['clip_id'] == 'burst',
        )['windows'],
        hasLength(1),
      );
      await expectLater(
        renderer.inspectAudio(doc, 2, 9, cancellation: MediaCancellation()),
        throwsFormatException,
      );
    },
    skip: _binary.isEmpty
        ? 'Set FFMPEG_TEST_BIN for native audio checks.'
        : false,
  );

  test(
    'native frames preserves single-frame detail and fits 16 samples in four rows',
    () async {
      final root = await Directory.systemTemp.createTemp('reveric-frames-');
      addTearDown(() => root.delete(recursive: true));
      final runner = _NativeRunner();
      final files = SessionFiles(root: root.path, novelId: 'work');
      final source = '${root.path}/detail.mp4';
      await runner.execute(
        [
          '-f',
          'lavfi',
          '-i',
          'testsrc2=s=1280x720:r=16:d=1',
          '-c:v',
          'libx264',
          source,
        ],
        probe: false,
        cancellation: MediaCancellation(),
      );
      final command = FfmpegCommand(files, runner);
      Future<img.Image> inspect(List<int> times) async {
        final result = await command.frames(
          'session',
          source,
          times,
          MediaCancellation(),
        );
        expect((result['cells'] as List).map((c) => c['timestamp_ms']), times);
        final file = await files.resolve(result['file_path'] as String);
        return img.decodeJpg(await file.readAsBytes())!;
      }

      final single = await inspect([0]);
      expect([single.width, single.height], [1280, 720]);
      final grid = await inspect(List.generate(16, (i) => i * 60));
      // Four 509×286 cells per row with 4-pixel gutters.
      expect([grid.width, grid.height], [2048, 1156]);
    },
    skip: _binary.isEmpty
        ? 'Set FFMPEG_TEST_BIN for native frame checks.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'native execute expands JPEG and PNG sequences alongside a single image',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'reveric-sequence-native-',
      );
      final runner = _NativeRunner();
      final files = SessionFiles(root: root.path, novelId: 'work');
      try {
        final source = '${root.path}/100%complete.mp4';
        await runner.execute(
          [
            '-y',
            '-f',
            'lavfi',
            '-i',
            'testsrc2=s=64x48:r=8:d=1',
            '-c:v',
            'libx264',
            source,
          ],
          probe: false,
          cancellation: MediaCancellation(),
        );
        final command = FfmpegCommand(files, runner);
        final capabilities = await command.capabilities(MediaCancellation());
        expect(
          capabilities['allowed_filters'],
          containsAll(['select', 'tile']),
        );
        expect(
          capabilities['allowed_value_options'],
          containsAll(['-q:v', '-fps_mode', '-start_number']),
        );
        expect(capabilities['image_sequences']['output'], true);
        final result = await command.run(
          'session',
          await command.inspect(
            FfmpegArguments.parse([
              '-i',
              source,
              '-vf',
              "select='not(mod(n,2))'",
              '-fps_mode',
              'passthrough',
              '-q:v',
              '2',
              '-frames:v',
              '6',
              '-start_number',
              '99',
              'media/镜头-%03d.jpg',
              '-frames:v',
              '2',
              '-start_number',
              '0',
              'media/png-%d.png',
              '-frames:v',
              '1',
              'media/webp-%02d.webp',
              '-vf',
              'tile=2x2',
              '-frames:v',
              '1',
              'contact.png',
            ], probe: false),
          ),
          MediaCancellation(),
        );
        expect(result['ok'], true, reason: '$result');
        expect(result['exit_code'], 0);
        final paths = [
          for (var n = 99; n <= 102; n++)
            'media/镜头-${'$n'.padLeft(3, '0')}.jpg',
          'media/png-0.png',
          'media/png-1.png',
          'media/webp-01.webp',
          'contact.png',
        ];
        expect(result.containsKey('files'), isFalse);
        expect(result.containsKey('content'), isFalse);
        for (final path in paths) {
          final image = img.decodeImage(
            await (await files.resolve(
              'file_workspaces/work/$path',
            )).readAsBytes(),
          );
          expect(image, isNotNull, reason: path);
        }
        final contact = img.decodePng(
          await (await files.resolve(
            'file_workspaces/work/${paths.last}',
          )).readAsBytes(),
        )!;
        expect([contact.width, contact.height], [128, 96]);
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: _binary.isEmpty
        ? 'Set FFMPEG_TEST_BIN for native sequence checks.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'native frames agree with complete composition and survive preview disposal',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'reveric-frames-native-',
      );
      final app = AppDatabase.forTest(NativeDatabase.memory());
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final runner = _NativeRunner();
      final library = MediaLibraryService(app, MediaService(runner), root);
      final service = EditingService(db, library);
      final renderer = EditingRenderService(service, runner);
      Future<String> run(List<String> args) =>
          runner.execute(args, probe: false, cancellation: MediaCancellation());
      try {
        await Directory(
          '${root.path}/file_workspaces/work/videos',
        ).create(recursive: true);
        for (final color in ['red', 'blue']) {
          final path = '${root.path}/file_workspaces/work/videos/$color.mp4';
          await run([
            '-y',
            '-f',
            'lavfi',
            '-i',
            'color=c=$color:s=160x90:r=24:d=2',
            '-c:v',
            'libx264',
            '-pix_fmt',
            'yuv420p',
            path,
          ]);
          await app.assetDao.insertAsset(
            AssetsCompanion.insert(
              id: color,
              type: 'video',
              purpose: 'general',
              path: Value('file_workspaces/work/videos/$color.mp4'),
              content: const Value(VideoAssetContent(mimeType: 'video/mp4')),
            ),
          );
        }
        final red = await service.source('red'),
            blue = await service.source('blue');
        final doc = EditingDocument.empty('16:9').copyWith(
          clips: [
            EditingClip(
              id: 'red',
              trackId: 'V1',
              startFrame: 0,
              durationFrames: 24,
              content: EditingVideoContent(source: red),
            ),
            EditingClip(
              id: 'blue',
              trackId: 'V1',
              startFrame: 24,
              durationFrames: 24,
              content: EditingVideoContent(source: blue),
            ),
            EditingClip(
              id: 'overlay',
              trackId: 'V2',
              startFrame: 0,
              durationFrames: 24,
              content: EditingVideoContent(
                source: blue,
                opacity: .7,
                fadeInFrames: 8,
                fadeOutFrames: 8,
                transform: EditingTransform(
                  scale: .4,
                  x: 1 - .06 - .4 / 2,
                  y: .06 + .4 / 2,
                ),
              ),
            ),
            EditingClip(
              id: 'text',
              trackId: 'T1',
              startFrame: 23,
              durationFrames: 2,
              content: EditingTextContent(text: '字幕 Caption'),
            ),
          ],
        );
        const positions = [0, 7, 22, 23, 24, 25, 47];
        final sheet = await renderer.frames(
          doc,
          positions,
          cancellation: MediaCancellation(),
          progress: (_, _) {},
        );
        final image = img.decodeJpg(sheet.jpeg)!;
        expect(sheet.cells.map((c) => c['frame']), positions);
        final complete = await renderer.render(
          doc,
          preview: true,
          cancellation: MediaCancellation(),
          progress: (_, _) {},
        );
        // 预览块落在 App 目录的共享缓存里，另一个实例直接复用、释放后保留。
        final cache = Directory('${root.path}/cache/editing_preview');
        Future<List<String>> blocks() =>
            cache.list().map((e) => e.path).toList();
        final stored = await blocks();
        expect(stored, isNotEmpty);
        expect(stored.where((path) => path.contains('.block-')), isEmpty);
        final second = EditingRenderService(service, runner);
        final reused = await second.render(
          doc,
          preview: true,
          cancellation: MediaCancellation(),
          progress: (_, _) {},
        );
        await reused.dispose();
        await second.dispose();
        expect((await blocks())..sort(), stored..sort());
        try {
          for (var i = 0; i < positions.length; i++) {
            final output = '${root.path}/reference-$i.png';
            await run([
              '-y',
              '-i',
              complete.file.path,
              '-vf',
              "select='eq(n,${positions[i]})',scale=640:640:force_original_aspect_ratio=decrease,setsar=1",
              '-frames:v',
              '1',
              output,
            ]);
            final expected = img.decodePng(await File(output).readAsBytes())!;
            final cellWidth = (image.width - 8) ~/ 3;
            final cellHeight = (image.height - 8) ~/ 3;
            final reference = img.copyResize(
              expected,
              width: cellWidth,
              height: cellHeight,
            );
            var difference = 0.0, samples = 0;
            for (var y = 40; y < cellHeight; y += 3) {
              for (var x = 0; x < cellWidth; x += 3) {
                final a = image.getPixel(
                  (i % 3) * (cellWidth + 4) + x,
                  (i ~/ 3) * (cellHeight + 4) + y,
                );
                final b = reference.getPixel(x, y);
                difference +=
                    (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();
                samples += 3;
              }
            }
            expect(
              difference / samples,
              lessThan(6),
              reason: 'frame ${positions[i]} differs from complete render',
            );
          }
          final vfr = '${root.path}/variable.mp4';
          await run([
            '-y',
            '-i',
            complete.file.path,
            '-vf',
            "select='lt(n,24)+not(mod(n,3))'",
            '-fps_mode',
            'vfr',
            '-an',
            vfr,
          ]);
          final files = SessionFiles(root: root.path, novelId: 'work');
          final result = await FfmpegCommand(files, runner).frames(
            'session',
            complete.file.path,
            [0, 1000, 1500],
            MediaCancellation(),
          );
          final contact = img.decodeJpg(
            await (await files.resolve(
              result['file_path'] as String,
            )).readAsBytes(),
          )!;
          final w = (contact.width - 4) ~/ 2, h = (contact.height - 4) ~/ 2;
          expect(contact.getPixel(w ~/ 2, h ~/ 2).r, greaterThan(230));
          expect(contact.getPixel(w + 4 + w ~/ 2, h ~/ 2).b, greaterThan(230));
          await complete.dispose();
          expect(
            await (await files.resolve(result['file_path'] as String)).exists(),
            true,
          );
        } finally {
          if (await complete.file.exists()) {
            await complete.dispose();
          }
        }
        final cancelled = MediaCancellation();
        await cancelled.cancel();
        await expectLater(
          renderer.frames(
            doc,
            [0],
            cancellation: cancelled,
            progress: (_, _) {},
          ),
          throwsA(isA<MediaException>()),
        );
      } finally {
        await renderer.dispose();
        await db.close();
        await app.close();
        await root.delete(recursive: true);
      }
    },
    skip: _binary.isEmpty
        ? 'Set FFMPEG_TEST_BIN to an FFmpeg executable to run native media checks.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'transform centers fitted media and detached audio is mixed exactly once',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'reveric-editing-native-',
      );
      final app = AppDatabase.forTest(NativeDatabase.memory());
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final runner = _NativeRunner();
      final service = EditingService(
        db,
        MediaLibraryService(app, MediaService(runner), root),
      );
      final renderer = EditingRenderService(service, runner);
      Future<String> run(List<String> args) =>
          runner.execute(args, probe: false, cancellation: MediaCancellation());
      final outputs = <EncodedMedia>[];
      try {
        await Directory(
          '${root.path}/file_workspaces/work',
        ).create(recursive: true);
        for (final (id, size, tone) in [
          ('red', '320x180', false),
          ('blue', '180x180', true),
        ]) {
          final relative = 'file_workspaces/work/$id.mp4';
          await run([
            '-y',
            '-f',
            'lavfi',
            '-i',
            'color=c=$id:s=$size:r=24:d=1',
            if (tone) ...[
              '-f',
              'lavfi',
              '-i',
              'sine=frequency=440:sample_rate=48000:duration=1',
              '-c:a',
              'aac',
            ],
            '-c:v',
            'libx264',
            '-pix_fmt',
            'yuv420p',
            '${root.path}/$relative',
          ]);
          await app.assetDao.insertAsset(
            AssetsCompanion.insert(
              id: id,
              type: 'video',
              purpose: 'general',
              path: Value(relative),
              content: const Value(VideoAssetContent(mimeType: 'video/mp4')),
            ),
          );
        }
        final blue = await service.source('blue');
        expect(blue.hasAudio, true);
        final document = EditingDocument.empty('16:9').copyWith(
          clips: [
            EditingClip(
              id: 'main',
              trackId: 'V1',
              startFrame: 0,
              durationFrames: 24,
              content: EditingVideoContent(source: await service.source('red')),
            ),
            EditingClip(
              id: 'overlay',
              trackId: 'V2',
              startFrame: 0,
              durationFrames: 24,
              content: EditingVideoContent(
                source: blue,
                gainDb: -6,
                fadeInFrames: 2,
                fadeOutFrames: 2,
                transform: const EditingTransform(scale: .5, x: .25, y: .7),
              ),
            ),
          ],
        );
        final detached = EditingCommands.extractAudio(document, 'overlay');
        final muted = EditingCommands.updateTrack(
          detached,
          detached.track('A1').copyWith(muted: true),
        );
        final levels = <double>[];
        for (final (index, doc) in [document, detached, muted].indexed) {
          final output = await renderer.render(
            doc,
            resolution: '480p',
            preview: index != 0,
            cancellation: MediaCancellation(),
            progress: (_, _) {},
          );
          outputs.add(output);
          final pcm = '${root.path}/audio-$index.f32';
          await run([
            '-y',
            '-i',
            output.file.path,
            '-vn',
            '-ac',
            '1',
            '-ar',
            '48000',
            '-f',
            'f32le',
            pcm,
          ]);
          final bytes = await File(pcm).readAsBytes();
          final data = ByteData.sublistView(bytes);
          var energy = 0.0;
          for (var offset = 0; offset + 4 <= data.lengthInBytes; offset += 4) {
            final value = data.getFloat32(offset, Endian.little);
            energy += value * value;
          }
          levels.add(math.sqrt(energy / (data.lengthInBytes ~/ 4)));
        }
        expect(levels[0], greaterThan(.02));
        expect(
          levels[1],
          closeTo(levels[0], .002),
          reason: 'detaching must not double or remove the original audio',
        );
        expect(
          levels[2],
          lessThan(.00001),
          reason: 'muting the detached audio must leave the video silent',
        );
        final frame = '${root.path}/transform.png';
        await run([
          '-y',
          '-ss',
          '0.5',
          '-i',
          outputs[1].file.path,
          '-frames:v',
          '1',
          frame,
        ]);
        final image = img.decodePng(await File(frame).readAsBytes())!;
        final center = image.getPixel(
          (image.width * .25).round(),
          (image.height * .7).round(),
        );
        final right = image.getPixel(
          (image.width * .8).round(),
          (image.height * .15).round(),
        );
        final boxEdge = image.getPixel(
          (image.width * .4).round(),
          (image.height * .7).round(),
        );
        expect(center.b, greaterThan(220));
        expect(center.r, lessThan(30));
        expect(right.r, greaterThan(220));
        expect(
          boxEdge.r,
          greaterThan(220),
          reason: 'square video must fit, not stretch to the layer box',
        );
        const artifactDir = String.fromEnvironment('EDITING_TEST_ARTIFACT_DIR');
        if (artifactDir.isNotEmpty) {
          await Directory(artifactDir).create(recursive: true);
          await outputs[1].file.copy('$artifactDir/detached-preview.mp4');
          await outputs[0].file.copy('$artifactDir/original-export.mp4');
          await outputs[2].file.copy('$artifactDir/detached-muted.mp4');
          await File(frame).copy('$artifactDir/transform.png');
          await File('$artifactDir/audio-levels.json').writeAsString(
            jsonEncode({
              'original': levels[0],
              'detached': levels[1],
              'muted': levels[2],
            }),
          );
        }
      } finally {
        for (final output in outputs) {
          await output.dispose();
        }
        await renderer.dispose();
        await db.close();
        await app.close();
        await root.delete(recursive: true);
      }
    },
    skip: _binary.isEmpty
        ? 'Set FFMPEG_TEST_BIN for native editing checks.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'a clip cut in mid-chunk shows its first frame over the black base',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'reveric-editing-cut-',
      );
      final app = AppDatabase.forTest(NativeDatabase.memory());
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final runner = _NativeRunner();
      final service = EditingService(
        db,
        MediaLibraryService(app, MediaService(runner), root),
      );
      final renderer = EditingRenderService(service, runner);
      Future<String> run(List<String> args) =>
          runner.execute(args, probe: false, cancellation: MediaCancellation());
      EncodedMedia? output;
      try {
        await Directory(
          '${root.path}/file_workspaces/work',
        ).create(recursive: true);
        for (final color in ['red', 'blue']) {
          final relative = 'file_workspaces/work/$color.mp4';
          await run([
            '-y',
            '-f',
            'lavfi',
            '-i',
            'color=c=$color:s=160x90:r=24:d=3',
            '-c:v',
            'libx264',
            '-pix_fmt',
            'yuv420p',
            '${root.path}/$relative',
          ]);
          await app.assetDao.insertAsset(
            AssetsCompanion.insert(
              id: color,
              type: 'video',
              purpose: 'general',
              path: Value(relative),
              content: const Value(VideoAssetContent(mimeType: 'video/mp4')),
            ),
          );
        }
        // 56 / 24 as a double is slightly above the time FFmpeg derives from
        // the frame's timestamp, which used to drop the first frame of the cut.
        const cut = 56;
        final doc = EditingDocument.empty('16:9').copyWith(
          clips: [
            EditingClip(
              id: 'red',
              trackId: 'V1',
              startFrame: 0,
              durationFrames: cut,
              content: EditingVideoContent(source: await service.source('red')),
            ),
            EditingClip(
              id: 'blue',
              trackId: 'V1',
              startFrame: cut,
              durationFrames: 24,
              content: EditingVideoContent(
                source: await service.source('blue'),
              ),
            ),
          ],
        );
        output = await renderer.render(
          doc,
          resolution: '480p',
          cancellation: MediaCancellation(),
          progress: (_, _) {},
        );
        for (final (frame, red, blue) in [
          (cut - 1, true, false),
          (cut, false, true),
          (cut + 1, false, true),
        ]) {
          final still = '${root.path}/frame-$frame.png';
          await run([
            '-y',
            '-i',
            output.file.path,
            '-vf',
            "select='eq(n,$frame)'",
            '-frames:v',
            '1',
            still,
          ]);
          final image = img.decodePng(await File(still).readAsBytes())!;
          final pixel = image.getPixel(image.width ~/ 2, image.height ~/ 2);
          expect(pixel.r > 200, red, reason: 'frame $frame red');
          expect(pixel.b > 200, blue, reason: 'frame $frame blue');
        }
      } finally {
        await output?.dispose();
        await renderer.dispose();
        await db.close();
        await app.close();
        await root.delete(recursive: true);
      }
    },
    skip: _binary.isEmpty
        ? 'Set FFMPEG_TEST_BIN for native editing checks.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'speed changes picture and sound timing without shifting pitch',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'reveric-editing-speed-',
      );
      final app = AppDatabase.forTest(NativeDatabase.memory());
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final runner = _NativeRunner();
      final service = EditingService(
        db,
        MediaLibraryService(app, MediaService(runner), root),
      );
      final renderer = EditingRenderService(service, runner);
      Future<String> run(List<String> args) =>
          runner.execute(args, probe: false, cancellation: MediaCancellation());
      EncodedMedia? output;
      try {
        await Directory(
          '${root.path}/file_workspaces/work',
        ).create(recursive: true);
        // 前 2 秒红色无声，后 2 秒蓝色带 440 Hz 正弦。
        const relative = 'file_workspaces/work/source.mp4';
        await run([
          '-y',
          '-f',
          'lavfi',
          '-i',
          'color=c=red:s=160x90:r=24:d=2',
          '-f',
          'lavfi',
          '-i',
          'color=c=blue:s=160x90:r=24:d=2',
          '-f',
          'lavfi',
          '-i',
          r'aevalsrc=if(lt(t\,2)\,0\,0.3*sin(2*PI*440*t)):s=48000:d=4',
          '-filter_complex',
          '[0:v][1:v]concat=n=2:v=1:a=0[v]',
          '-map',
          '[v]',
          '-map',
          '2:a',
          '-c:v',
          'libx264',
          '-pix_fmt',
          'yuv420p',
          '-c:a',
          'aac',
          '${root.path}/$relative',
        ]);
        await app.assetDao.insertAsset(
          AssetsCompanion.insert(
            id: 'source',
            type: 'video',
            purpose: 'general',
            path: const Value(relative),
            content: const Value(VideoAssetContent(mimeType: 'video/mp4')),
          ),
        );
        final source = await service.source('source');
        // 2 倍速 0–4 秒铺满时间线 0–2 秒；0.5 倍速 1.5–2.5 秒铺满 2–4 秒。
        final doc = EditingDocument.empty('16:9').copyWith(
          clips: [
            EditingClip(
              id: 'fast',
              trackId: 'V1',
              startFrame: 0,
              durationFrames: 48,
              content: EditingVideoContent(source: source, speed: 2),
            ),
            EditingClip(
              id: 'slow',
              trackId: 'V1',
              startFrame: 48,
              durationFrames: 48,
              content: EditingVideoContent(
                source: source,
                sourceInUs: 1500000,
                speed: .5,
              ),
            ),
          ],
        );
        doc.validate();
        output = await renderer.render(
          doc,
          resolution: '480p',
          cancellation: MediaCancellation(),
          progress: (_, _) {},
        );
        for (final (frame, blue) in [
          (22, false),
          (25, true),
          (70, false),
          (73, true),
        ]) {
          final still = '${root.path}/frame-$frame.png';
          await run([
            '-y',
            '-i',
            output.file.path,
            '-vf',
            "select='eq(n,$frame)'",
            '-frames:v',
            '1',
            still,
          ]);
          final image = img.decodePng(await File(still).readAsBytes())!;
          final pixel = image.getPixel(image.width ~/ 2, image.height ~/ 2);
          expect(pixel.b > 200, blue, reason: 'frame $frame blue');
          expect(pixel.r > 200, !blue, reason: 'frame $frame red');
        }
        final pcm = '${root.path}/audio.f32';
        await run([
          '-y',
          '-i',
          output.file.path,
          '-vn',
          '-ac',
          '1',
          '-ar',
          '48000',
          '-f',
          'f32le',
          pcm,
        ]);
        final data = ByteData.sublistView(await File(pcm).readAsBytes());
        ({double rms, double hz}) window(double from, double to) {
          final first = (from * 48000).round(), last = (to * 48000).round();
          var energy = 0.0;
          var crossings = 0;
          var previous = 0.0;
          for (var i = first; i < last; i++) {
            final value = data.getFloat32(i * 4, Endian.little);
            energy += value * value;
            if (i > first && (previous < 0) != (value < 0)) {
              crossings++;
            }
            previous = value;
          }
          return (
            rms: math.sqrt(energy / (last - first)),
            hz: crossings / 2 / (to - from),
          );
        }

        expect(window(.1, .9).rms, lessThan(.01));
        final fast = window(1.1, 1.9);
        expect(fast.rms, greaterThan(.1));
        expect(fast.hz, closeTo(440, 15), reason: 'pitch must not double');
        expect(window(2.1, 2.9).rms, lessThan(.01));
        final slow = window(3.1, 3.9);
        expect(slow.rms, greaterThan(.1));
        expect(slow.hz, closeTo(440, 15), reason: 'pitch must not halve');
      } finally {
        await output?.dispose();
        await renderer.dispose();
        await db.close();
        await app.close();
        await root.delete(recursive: true);
      }
    },
    skip: _binary.isEmpty
        ? 'Set FFMPEG_TEST_BIN for native editing checks.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
