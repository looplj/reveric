// 职责: 用打包的 FFmpeg 验证多轨合成、锚点定位、字幕与文字轨烧录、分块复用、帧数、混音和取消。
// 关联文件:
//   lib/shared/services/editing/render_service.dart
//   lib/shared/services/editing/service.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/editing/document.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/services/editing/commands.dart';
import 'package:reveric/shared/services/editing/service.dart';
import 'package:reveric/shared/services/editing/render_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';

class CountingRunner extends FfmpegRunner {
  int encodes = 0;
  int videoEncodes = 0;
  @override
  Future<String> execute(
    List<String> args, {
    required bool probe,
    required MediaCancellation cancellation,
  }) {
    if (!probe) {
      encodes++;
      if (args.contains('libx264')) {
        videoEncodes++;
      }
    }
    return super.execute(args, probe: probe, cancellation: cancellation);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'packaged FFmpeg composes layered video and float audio across a 120-frame boundary',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp(
          'reveric_editing_native_',
        );
        final app = AppDatabase.forTest(NativeDatabase.memory());
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        final runner = CountingRunner();
        final media = MediaService(runner);
        final library = MediaLibraryService(app, media, dir);
        final projects = EditingService(db, library);
        final renderer = EditingRenderService(projects, runner);
        Future<void> run(List<String> args) => runner.execute(
          args,
          probe: false,
          cancellation: MediaCancellation(),
        );
        // 取指定帧、指定区域内绿色通道的峰值：白字约 255，红底和黑描边都很低。
        Future<int> greenPeak(String file, String crop, int frame) async {
          final band = '${dir.path}/band.rgb';
          await run([
            '-y',
            '-i',
            file,
            '-vf',
            "select='eq(n,$frame)',crop=$crop,format=rgb24",
            '-frames:v',
            '1',
            '-f',
            'rawvideo',
            band,
          ]);
          final bytes = await File(band).readAsBytes();
          var peak = 0;
          for (var i = 1; i < bytes.length; i += 3) {
            peak = bytes[i] > peak ? bytes[i] : peak;
          }
          return peak;
        }

        const folder = 'file_workspaces/work/videos';
        // 剪辑素材按资产 ID 引用，生成的文件先登记成资产再解析。
        Future<EditingSource> register(String id, String type) async {
          final extension = type == 'audio' ? 'wav' : 'mp4';
          await app.assetDao.insertAsset(
            AssetsCompanion.insert(
              id: id,
              type: type,
              purpose: 'general',
              path: Value('$folder/$id.$extension'),
              content: Value(
                type == 'audio'
                    ? const AudioAssetContent(mimeType: 'audio/wav')
                    : const VideoAssetContent(mimeType: 'video/mp4'),
              ),
            ),
          );
          return projects.source(id);
        }

        try {
          await Directory('${dir.path}/$folder').create(recursive: true);
          final path = '${dir.path}/$folder/source.mp4';
          await run([
            '-y',
            '-f',
            'lavfi',
            '-i',
            'color=c=red:s=128x72:r=30:d=6',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:duration=6',
            '-c:v',
            'libx264',
            '-pix_fmt',
            'yuv420p',
            '-c:a',
            'aac',
            '-shortest',
            path,
          ]);
          final source = await register('source', 'video');
          await run([
            '-y',
            '-f',
            'lavfi',
            '-i',
            'color=c=blue:s=72x128:r=25:d=2',
            '-c:v',
            'libx264',
            '-pix_fmt',
            'yuv420p',
            '${dir.path}/$folder/blue.mp4',
          ]);
          final blue = await register('blue', 'video');
          await run([
            '-y',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:duration=6',
            '-c:a',
            'pcm_s16le',
            '${dir.path}/$folder/tone.wav',
          ]);
          final tone = await register('tone', 'audio');
          final screenplay = ScreenplayService(db);
          final initial = await screenplay.createInitialStructure();
          final scene = await screenplay.createScene(
            screenplayId: (await db.screenplayDao.getRoot())!.id,
            episodeId: initial.episodeId,
            title: 'Scene',
          );
          final shots = StoryboardService(db);
          final first = await shots.create(scene, values: {'title': 'First'});
          final second = await shots.create(scene, values: {'title': 'Second'});
          await shots.create(
            scene,
            values: {'kind': 'image', 'title': 'Not a film segment'},
          );
          await (db.update(
            db.productionClips,
          )..where((t) => t.id.equals(first.id))).write(
            ProductionClipsCompanion(adoptedAssetId: Value(blue.assetId)),
          );
          await (db.update(
            db.productionClips,
          )..where((t) => t.id.equals(second.id))).write(
            ProductionClipsCompanion(adoptedAssetId: Value(source.assetId)),
          );
          final (direct, skipped) = await projects.fromAdopted(
            initial.episodeId,
            '16:9',
          );
          expect(skipped, isEmpty);
          expect(direct.totalFrames, 192);
          expect(
            direct.clips
                .where((c) => direct.track(c.trackId).kind == 'video')
                .map((c) => c.name),
            ['First', 'Second'],
          );
          final film = await renderer.render(
            direct,
            cancellation: MediaCancellation(),
            progress: (_, _) {},
          );
          try {
            expect(film.info.frameCount, 192);
            expect(film.info.width, 1280);
            expect(film.info.height, 720);
            for (final frame in [24, 72]) {
              final pixel = '${dir.path}/direct-$frame.rgb';
              await run([
                '-y',
                '-i',
                film.file.path,
                '-vf',
                "select='eq(n,$frame)',crop=2:2:640:360,format=rgb24",
                '-frames:v',
                '1',
                '-f',
                'rawvideo',
                pixel,
              ]);
              final bytes = await File(pixel).readAsBytes();
              expect(frame == 24 ? bytes[2] : bytes[0], greaterThan(220));
            }
          } finally {
            await film.dispose();
          }
          // 主轨原声压到几乎无声，音量和淡入淡出看 A1 的正弦音频。
          final doc = EditingDocument.empty('16:9').copyWith(
            clips: [
              EditingClip(
                id: 'v',
                trackId: 'V1',
                content: EditingVideoContent(source: source, gainDb: -60),
                startFrame: 0,
                durationFrames: 144,
              ),
              EditingClip(
                id: 'o',
                trackId: 'V2',
                content: EditingVideoContent(
                  source: blue,
                  transform: const EditingTransform(
                    scale: .5,
                    x: .94,
                    y: .06,
                    anchorX: 1,
                    anchorY: 0,
                  ),
                ),
                startFrame: 110,
                durationFrames: 34,
              ),
              EditingClip(
                id: 'a',
                trackId: 'A1',
                content: EditingAudioContent(
                  source: tone,
                  gainDb: 3,
                  fadeInFrames: 24,
                  fadeOutFrames: 48,
                ),
                startFrame: 0,
                durationFrames: 144,
              ),
              const EditingClip(
                id: 't',
                trackId: 'T1',
                startFrame: 0,
                durationFrames: 48,
                content: EditingTextContent(text: 'Hello 字幕'),
              ),
            ],
          );
          final output = await renderer.render(
            doc,
            cancellation: MediaCancellation(),
            preview: true,
            progress: (_, _) {},
          );
          try {
            expect(output.info.frameCount, 144);
            expect(output.info.frameRate, 24);
            expect(output.info.width, 854);
            expect(output.info.height, 480);
            expect(output.info.audioCodec, 'aac');
            expect(output.info.duration.inMilliseconds, closeTo(6000, 42));
            // 图层框右上角锚在 (.94, .06)：框为 x 376–803、y 29–269，竖版 72×128 缩到 240 高后在框内居中，落在 x 522–657。
            for (final frame in [100, 115, 125]) {
              final pixel = '${dir.path}/pixel-$frame.rgb';
              await run([
                '-y',
                '-i',
                output.file.path,
                '-vf',
                "select='eq(n,$frame)',crop=2:2:588:148,format=rgb24",
                '-frames:v',
                '1',
                '-f',
                'rawvideo',
                pixel,
              ]);
              final bytes = await File(pixel).readAsBytes();
              expect(bytes.length, 12);
              expect(frame == 100 ? bytes[0] : bytes[2], greaterThan(220));
              expect(frame == 100 ? bytes[2] : bytes[0], lessThan(30));
            }
            // 字幕在底部烧录：白字只在 0–48 帧出现。
            const subtitleBand = '400:40:227:400';
            expect(
              await greenPeak(output.file.path, subtitleBand, 10),
              greaterThan(200),
            );
            expect(
              await greenPeak(output.file.path, subtitleBand, 100),
              lessThan(80),
            );
            final pcm = '${dir.path}/decoded.f32';
            await run([
              '-y',
              '-i',
              output.file.path,
              '-vn',
              '-ar',
              '48000',
              '-ac',
              '2',
              '-f',
              'f32le',
              pcm,
            ]);
            final samples = ByteData.sublistView(await File(pcm).readAsBytes());
            double sample(int index) =>
                samples.getFloat32(index * 8, Endian.little);
            // Fade is calculated against the entire clip, including the chunk join at 5s.
            expect((sample(240000) - sample(239999)).abs(), lessThan(.03));
            double energy(int frame) {
              var total = 0.0;
              for (var n = frame * 2000; n < (frame + 1) * 2000; n++) {
                total += sample(n).abs();
              }
              return total / 2000;
            }

            expect(energy(119), greaterThan(energy(140) * 4));
            final before = runner.encodes;
            final cached = await renderer.render(
              doc,
              cancellation: MediaCancellation(),
              preview: true,
              progress: (_, _) {},
            );
            await cached.dispose();
            // 分块全部命中缓存时只剩最终封装与限幅一次编码，校验走 probe。
            expect(runner.encodes - before, 1);
            final music = doc.clips.singleWhere((c) => c.id == 'a');
            final quieter = EditingCommands.update(
              doc,
              music.copyWith(content: music.media!.copyWith(gainDb: -7)),
            );
            final videoEncodes = runner.videoEncodes;
            final clock = Stopwatch()..start();
            final remixed = await renderer.render(
              quieter,
              preview: true,
              cancellation: MediaCancellation(),
              progress: (_, _) {},
            );
            try {
              final encodedVideo = runner.videoEncodes - videoEncodes;
              debugPrint(
                'Music gain edit: ${clock.elapsedMilliseconds} ms, '
                '$encodedVideo video encodes',
              );
              expect(encodedVideo, 0);
              expect(remixed.info.frameCount, 144);
              final quieterPcm = '${dir.path}/quieter.f32';
              await run([
                '-y',
                '-i',
                remixed.file.path,
                '-vn',
                '-ar',
                '48000',
                '-ac',
                '2',
                '-f',
                'f32le',
                quieterPcm,
              ]);
              final decoded = ByteData.sublistView(
                await File(quieterPcm).readAsBytes(),
              );
              // 主轨原声为 -60 dB，音乐降低 10 dB 后两个块的振幅都应约为原先的 0.316 倍。
              for (final frame in [60, 125]) {
                var total = 0.0;
                for (var n = frame * 2000; n < (frame + 1) * 2000; n++) {
                  total += decoded.getFloat32(n * 8, Endian.little).abs();
                }
                expect(total / 2000 / energy(frame), closeTo(.316, .02));
              }
            } finally {
              await remixed.dispose();
            }
            final token = MediaCancellation();
            await token.cancel();
            await expectLater(
              renderer.render(doc, cancellation: token, progress: (_, _) {}),
              throwsA(isA<MediaException>()),
            );
            expect(await File(path).exists(), isTrue);
          } finally {
            await output.dispose();
          }
          // 文字轨不随字幕选项关闭：字幕不烧录时，右上锚点的文字仍烧进画面，右边缘落在 x=.94·854≈803。
          final withText = EditingCommands.addTextTrack(
            EditingDocument.empty('16:9'),
          );
          final textTrack = withText.tracks.firstWhere(
            (t) => t.role == EditingRole.text,
          );
          final watermark = withText.copyWith(
            clips: [
              EditingClip(
                id: 'v',
                trackId: 'V1',
                startFrame: 0,
                durationFrames: 48,
                content: EditingVideoContent(source: source, gainDb: -60),
              ),
              const EditingClip(
                id: 's',
                trackId: 'T1',
                startFrame: 0,
                durationFrames: 48,
                content: EditingTextContent(text: 'Hello 字幕'),
              ),
              EditingClip(
                id: 'w',
                trackId: textTrack.id,
                startFrame: 0,
                durationFrames: 48,
                content: const EditingTextContent(
                  text: 'LOGO',
                  transform: EditingTransform(
                    x: .94,
                    y: .06,
                    anchorX: 1,
                    anchorY: 0,
                  ),
                ),
              ),
            ],
          );
          final marked = await renderer.render(
            watermark,
            cancellation: MediaCancellation(),
            subtitles: EditingSubtitles.none,
            preview: true,
            progress: (_, _) {},
          );
          try {
            final file = marked.file.path;
            expect(await greenPeak(file, '60:40:740:24', 10), greaterThan(200));
            expect(await greenPeak(file, '44:40:810:24', 10), lessThan(80));
            expect(await greenPeak(file, '600:40:0:24', 10), lessThan(80));
            expect(await greenPeak(file, '400:40:227:400', 10), lessThan(80));
          } finally {
            await marked.dispose();
          }

          final logoTimeline = EditingDocument.empty(
            '16:9',
          ).copyWith(clips: [watermark.mainClips.single]);
          const cornerRegions = {
            EditingWatermarkCorner.top_left: '480:160:0:0',
            EditingWatermarkCorner.top_right: '480:160:800:0',
            EditingWatermarkCorner.bottom_left: '480:160:0:560',
            EditingWatermarkCorner.bottom_right: '480:160:800:560',
          };
          for (final corner in [null, ...EditingWatermarkCorner.values]) {
            final film = await renderer.render(
              logoTimeline,
              watermark: corner,
              cancellation: MediaCancellation(),
              progress: (_, _) {},
            );
            try {
              for (final region in cornerRegions.entries) {
                for (final frame in [0, logoTimeline.totalFrames - 1]) {
                  expect(
                    await greenPeak(film.file.path, region.value, frame),
                    region.key == corner ? greaterThan(200) : lessThan(80),
                    reason: '$corner export at ${region.key}, frame $frame',
                  );
                }
              }
              if (corner == EditingWatermarkCorner.top_left) {
                expect(
                  await greenPeak(film.file.path, '105:110:335:0', 0),
                  greaterThan(200),
                  reason: 'The credit text extends beyond the logo',
                );
              }
            } finally {
              await film.dispose();
            }
          }
        } finally {
          await renderer.dispose();
          await db.close();
          await app.close();
          await dir.delete(recursive: true);
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
