// 职责: 验证离屏截图的尺寸、投影像素和无 HUD，以及逐张失败保留、派生放置和备份闭包。
// 关联文件:
//   lib/shared/widgets/production/panorama/capture.dart
//   lib/shared/services/production/panorama_service.dart
//   lib/shared/services/production/backup_media.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/production/panorama.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/panorama_service.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/backup_media.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/widgets/production/panorama/capture.dart';
import 'package:reveric/shared/widgets/production/panorama/texture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('capture size follows output ratio with a 1920 long edge', () {
    expect(panoramaCaptureSize('16:9'), const ui.Size(1920, 1080));
    expect(panoramaCaptureSize('9:16'), const ui.Size(1080, 1920));
    expect(panoramaCaptureSize('1:1'), const ui.Size(1920, 1920));
    expect(panoramaCaptureSize('21:9'), const ui.Size(1920, 823));
  });
  test(
    'shader capture matches projected texture pixels, including thirds and HUD area',
    () async {
      final root = await Directory.systemTemp.createTemp('panorama-pixels-');
      try {
        final source = img.Image(width: 720, height: 360);
        for (var y = 0; y < source.height; y++) {
          for (var x = 0; x < source.width; x++) {
            source.setPixelRgb(
              x,
              y,
              (x * 255 / 719).round(),
              (y * 255 / 359).round(),
              80,
            );
          }
        }
        final file = await File(
          '${root.path}/gradient.png',
        ).writeAsBytes(img.encodePng(source));
        final texture = await PanoramaTextures.acquire(file.path);
        try {
          const view = PanoramaView(yaw: 30, pitch: 20, fov: 75);
          const size = ui.Size(1920, 1080);
          final png = await PanoramaCapture.render(texture.image, view, size);
          final output = img.decodePng(png)!;
          expect((output.width, output.height), (1920, 1080));
          for (final (x, y) in [
            (0, 0),
            (640, 360),
            (1280, 720),
            (960, 540),
            (1800, 1000),
            (1919, 1079),
          ]) {
            final uv = panoramaUv(
              view,
              (x + .5) / 1920,
              (y + .5) / 1080,
              16 / 9,
            );
            final pixel = output.getPixel(x, y);
            expect(pixel.r, closeTo(uv.u * 255, 2), reason: 'red at $x,$y');
            expect(pixel.g, closeTo(uv.v * 255, 2), reason: 'green at $x,$y');
            expect(pixel.b, closeTo(80, 1), reason: 'no overlay at $x,$y');
            expect(pixel.a, 255);
          }
        } finally {
          texture.dispose();
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  for (final failSecond in [false, true]) {
    test(
      'four captures preserve grid and backup files with failSecond=$failSecond',
      () async {
        final root = await Directory.systemTemp.createTemp('panorama-service-');
        final main = app.AppDatabase.forTest(
          NativeDatabase(File('${root.path}/reveric.sqlite')),
        );
        final db = NovelContentDatabase.forTest(
          NativeDatabase(File('${root.path}/content.sqlite')),
        );
        var closed = false;
        try {
          final sourceFile = File(
            '${root.path}/file_workspaces/work/source.png',
          );
          await sourceFile.parent.create(recursive: true);
          final png = Uint8List.fromList(
            img.encodePng(img.Image(width: 64, height: 32)),
          );
          await sourceFile.writeAsBytes(png);
          await main.assetDao.insertAsset(
            app.AssetsCompanion.insert(
              id: 'source',
              type: 'image',
              purpose: 'production.upload',
              content: const Value(
                ImageAssetContent(mimeType: 'image/png', width: 64, height: 32),
              ),
              novelId: const Value('work'),
              path: const Value('file_workspaces/work/source.png'),
            ),
          );
          final canvas = ProductionCanvasService(
            StoryboardService(db),
            MediaLibraryService(main, MediaService(FfmpegRunner()), root),
            'work',
          );
          final episode = (await ScreenplayService(
            db,
          ).createInitialStructure()).episodeId;
          final source = await canvas.addMedia(
            (await canvas.ensureCanvas(episode)).id,
            'source',
          );
          await canvas.setPanoramaView(
            source.id,
            const PanoramaView(pitch: 25, fov: 65),
          );
          var count = 0;
          final views = <PanoramaView>[];
          final service = PanoramaService(
            canvas,
            render: (image, view, size) async {
              views.add(view);
              if (count++ == 1 && failSecond) {
                throw StateError('fake encoding failure');
              }
              return png;
            },
          );
          final result = await service.capture(source.id, [
            for (var i = 0; i < 4; i++)
              (
                view: PanoramaView(yaw: i * 90, pitch: 25, fov: 65),
                name: 'Direction $i',
              ),
          ]);
          expect(result.nodes, hasLength(failSecond ? 3 : 4));
          expect(result.failures.keys, failSecond ? ['Direction 1'] : isEmpty);
          if (failSecond) {
            expect(
              result.failures['Direction 1']!.stage,
              PanoramaCaptureStage.render,
            );
          }
          expect(views.map((v) => v.yaw), [0, 90, 180, 270]);
          expect(views.every((v) => v.pitch == 25 && v.fov == 65), true);
          for (final a in result.nodes) {
            expect(a.title, startsWith('Direction'));
            for (final b in result.nodes.where((b) => b.id != a.id)) {
              expect(
                ui.Rect.fromLTWH(
                  a.x,
                  a.y,
                  300,
                  300,
                ).overlaps(ui.Rect.fromLTWH(b.x, b.y, 300, 300)),
                false,
              );
            }
          }
          final positions = result.nodes.map((n) => (n.x, n.y)).toSet();
          expect(positions.map((p) => p.$1).toSet(), hasLength(2));
          expect(positions.map((p) => p.$2).toSet(), hasLength(2));
          final content = await canvas.content(source.canvasId);
          expect(content.edges, hasLength(result.nodes.length));
          expect(
            content.edges.every(
              (e) =>
                  e.type == canvasEdgeTypeDerivedOutput &&
                  e.sourceNodeId == source.id,
            ),
            true,
          );
          expect(await main.select(main.generationTasks).get(), isEmpty);
          final paths = <String>{};
          for (final node in result.nodes) {
            final asset = await main.assetDao.getAsset(node.mediaAssetId!);
            paths.add(asset!.path!);
            expect(await File(canvas.library.resolve(asset)).exists(), true);
          }
          final current = await service.capture(source.id, [
            (
              view: const PanoramaView(yaw: 33, pitch: -15, fov: 55),
              name: 'Current',
            ),
          ]);
          expect(current.nodes, hasLength(1));
          expect(current.nodes.single.title, 'Current');
          expect(views.last, const PanoramaView(yaw: 33, pitch: -15, fov: 55));
          expect(
            PanoramaView.fromStyle((await canvas.requireNode(source.id)).style),
            const PanoramaView(pitch: 25, fov: 65),
          );
          for (final other in result.nodes) {
            final single = current.nodes.single;
            expect(
              ui.Rect.fromLTWH(
                single.x,
                single.y,
                300,
                300,
              ).overlaps(ui.Rect.fromLTWH(other.x, other.y, 300, 300)),
              false,
            );
          }
          await db.close();
          await main.close();
          closed = true;
          final backup = collectSelectedMedia(backup: root, novelIds: {'work'});
          expect(
            backup.rows['assets']!.map((a) => a['id']),
            containsAll(result.nodes.map((n) => n.mediaAssetId).toSet()),
          );
          // Restore to another controlled root and confirm every registered capture remains decodable.
          final restored = await Directory('${root.path}/restored').create();
          for (final path in paths) {
            final target = File('${restored.path}/$path');
            await target.parent.create(recursive: true);
            await File('${root.path}/$path').copy(target.path);
            expect(img.decodePng(await target.readAsBytes()), isNotNull);
          }
        } finally {
          if (!closed) {
            await db.close();
            await main.close();
          }
          await root.delete(recursive: true);
        }
      },
    );
  }
}
