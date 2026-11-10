// 职责: 验证等分裁图的像素覆盖、格位顺序与登记失败的事务边界。
// 关联文件:
//   lib/shared/services/production/grid_split.dart
//   lib/shared/services/production/grid_orchestrator.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/canvas_history.dart';
import 'package:reveric/shared/services/production/grid_split.dart';
import 'package:reveric/shared/services/production/grid_orchestrator.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('non-divisible grid covers each source pixel exactly once', () async {
    final root = await Directory.systemTemp.createTemp('grid-pixels-');
    try {
      final source = _gradient();
      final file = await File(
        '${root.path}/source.png',
      ).writeAsBytes(img.encodePng(source));
      final crops = await splitProductionGrid(
        sourcePath: file.path,
        directory: root.path,
        rows: 3,
        cols: 5,
      );
      final rects = gridCellRects(source.width, source.height, 3, 5);
      final visits = List.filled(source.width * source.height, 0);
      for (final crop in crops) {
        final result = img.decodePng(await File(crop.path).readAsBytes())!;
        final rect = rects[crop.index];
        for (var y = 0; y < result.height; y++) {
          for (var x = 0; x < result.width; x++) {
            final expected = source.getPixel(rect.x + x, rect.y + y);
            final actual = result.getPixel(x, y);
            expect(
              [actual.r, actual.g, actual.b],
              [expected.r, expected.g, expected.b],
            );
            visits[(rect.y + y) * source.width + rect.x + x]++;
          }
        }
      }
      expect(visits.every((count) => count == 1), isTrue);
      expect(() => gridCellRects(2, 2, 3, 3), throwsFormatException);
      expect(() => gridCellRects(20, 20, 1, 1), throwsFormatException);
    } finally {
      await root.delete(recursive: true);
    }
  });

  for (final fail in [false, true]) {
    test(
      'partial selection registers ordered members and failure is atomic: $fail',
      () async {
        final root = await Directory.systemTemp.createTemp('grid-service-');
        final main = app.AppDatabase.forTest(NativeDatabase.memory());
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        try {
          final library = _Library(main, MediaService(FfmpegRunner()), root);
          final sourceFile = await File(
            '${root.path}/source.png',
          ).writeAsBytes(img.encodePng(_gradient()));
          final asset = await library.importFile(
            sourceFile,
            name: 'Source.png',
            novelId: 'work',
            purpose: AssetPurpose.production_output,
            cancellation: MediaCancellation(),
          );
          final canvas = ProductionCanvasService(
            StoryboardService(db),
            library,
            'work',
          );
          final episode = (await ScreenplayService(
            db,
          ).createInitialStructure()).episodeId;
          final board = await canvas.ensureCanvas(episode);
          final source = await canvas.addMedia(board.id, asset.id);
          library.fail = fail;
          final history = CanvasHistory(canvas.shots, board.id);
          addTearDown(history.dispose);
          final operation = GridOrchestrator().split(
            history: history,
            canvas: canvas,
            sourceNodeId: source.id,
            rows: 3,
            cols: 5,
            selected: {14, 1, 7},
            place: (_) => (at: (x: 500, y: 100), moves: {}),
          );
          if (fail) {
            await expectLater(operation, throwsStateError);
            expect((await canvas.content(board.id)).nodes.map((n) => n.id), [
              source.id,
            ]);
            expect(
              (await main.assetDao.watchAssets(novelId: 'work').first).length,
              2,
            );
          } else {
            final group = await operation;
            final layout =
                ProductionGroupLayout.fromStyle(group.style)
                    as StoryboardGroupLayout;
            expect((layout.rows, layout.cols), (2, 2));
            final members = await canvas.groups.members(group.id);
            expect(members.map((n) => n.sortOrder), [0, 1, 2]);
            expect(members.map((n) => n.title), [
              'Source.png 1-2',
              'Source.png 2-3',
              'Source.png 3-5',
            ]);
            for (final member in members) {
              expect(
                Offset(member.x, member.y),
                const Offset(500, 100) + layout.cellOffset(member.sortOrder),
              );
            }
            final edges = (await canvas.content(board.id)).edges;
            expect(edges.single.sourceNodeId, source.id);
            expect(edges.single.targetNodeId, group.id);
            expect(edges.single.type, canvasEdgeTypeDerivedOutput);
            expect((await canvas.requireNode(source.id)).parentId, isNull);
            expect(history.undoCount, 1);
            await history.undo();
            expect(await canvas.db.canvasDao.getNodeById(group.id), isNull);
            for (final member in members) {
              expect(await canvas.db.canvasDao.getNodeById(member.id), isNull);
              expect(
                await canvas.requireAsset(member.mediaAssetId!),
                isNotNull,
              );
            }
            await history.redo();
            expect(
              (await canvas.groups.members(group.id)).map((n) => n.id),
              members.map((n) => n.id),
            );
            await canvas.groups.setStoryboardLayout(
              group.id,
              layout.copyWith(numbered: true, ratio: '9:16'),
            );
            final beforeClear = await canvas.requireNode(group.id);
            await canvas.groups.clear(group.id);
            expect(await canvas.groups.members(group.id), isEmpty);
            expect(
              (await canvas.requireNode(group.id)).style,
              beforeClear.style,
            );
            final filled = await canvas.fillStoryboardSlot(
              group.id,
              3,
              asset.id,
            );
            final filledLayout =
                ProductionGroupLayout.fromStyle(beforeClear.style)
                    as StoryboardGroupLayout;
            expect(filled.sortOrder, 3);
            expect(filled.parentId, group.id);
            expect(
              Offset(filled.x, filled.y),
              Offset(group.x, group.y) + filledLayout.cellOffset(3),
            );
            await expectLater(
              canvas.fillStoryboardSlot(group.id, 3, asset.id),
              throwsA(isA<StoryboardException>()),
            );
            expect((await canvas.content(board.id)).nodes, hasLength(3));
            final stitched = await GridOrchestrator().stitch(
              canvas: canvas,
              groupId: group.id,
              title: 'Composite',
              background: 0xff102030,
              foreground: 0xffeeeeee,
              place: (_) => (at: (x: 1200, y: 100), moves: {}),
            );
            expect(stitched.parentId, isNull);
            expect(stitched.title, 'Composite');
            expect((stitched.x, stitched.y), (1200, 100));
            final composed = await canvas.requireAsset(
              stitched.mediaAssetId!,
              type: 'image',
            );
            final pixels = img.decodePng(
              await File(canvas.library.resolve(composed)).readAsBytes(),
            )!;
            expect((pixels.width, pixels.height), (1152, 2048));
            final derived = (await canvas.content(
              board.id,
            )).edges.singleWhere((e) => e.sourceNodeId == group.id);
            expect(derived.targetNodeId, stitched.id);
            expect(derived.type, canvasEdgeTypeDerivedOutput);
            expect(await canvas.groups.members(group.id), hasLength(1));
            // An occupied image node without an adopted result is a visible error, not an empty slot.
            final unavailable = await canvas.addImage(board.id);
            await canvas.groups.attachToSlot(group.id, unavailable.id, 0);
            final countBefore = (await canvas.content(board.id)).nodes.length;
            await expectLater(
              GridOrchestrator().stitch(
                canvas: canvas,
                groupId: group.id,
                title: 'Unavailable',
                background: 0xff102030,
                foreground: 0xffeeeeee,
                place: (_) => (at: (x: 1600, y: 100), moves: {}),
              ),
              throwsA(isA<StoryboardException>()),
            );
            expect(
              (await canvas.content(board.id)).nodes,
              hasLength(countBefore),
            );
          }
        } finally {
          await db.close();
          await main.close();
          await root.delete(recursive: true);
        }
      },
    );
  }
}

img.Image _gradient() {
  final result = img.Image(width: 17, height: 11);
  for (var y = 0; y < result.height; y++) {
    for (var x = 0; x < result.width; x++) {
      result.setPixelRgb(x, y, x * 12, y * 20, 80);
    }
  }
  return result;
}

class _Library extends MediaLibraryService {
  _Library(super.database, super.media, super.root);
  bool fail = false;
  int crops = 0;
  @override
  Future<app.AssetRow> importFile(
    File file, {
    required String name,
    required String novelId,
    required AssetPurpose purpose,
    required MediaCancellation cancellation,
    bool addToLibrary = false,
    String source = 'uploaded',
    String? batchId,
    String? prompt,
    String? model,
  }) {
    if (source == 'grid_split' && ++crops == 2 && fail) {
      throw StateError('registration failed');
    }
    return super.importFile(
      file,
      name: name,
      novelId: novelId,
      purpose: purpose,
      cancellation: cancellation,
      addToLibrary: addToLibrary,
      source: source,
      batchId: batchId,
      prompt: prompt,
      model: model,
    );
  }
}
