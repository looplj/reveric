// 职责: 验证制作画布局部历史的事务、级联、冲突和连续撤销重做。
// 关联文件:
//   lib/shared/services/production/canvas_history.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/group_service.dart
import 'dart:io';
import 'dart:ui';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/services/production/canvas_history.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';

void main() {
  late NovelContentDatabase db;
  late app.AppDatabase appDb;
  late Directory root;
  late ProductionCanvasService service;
  late CanvasHistory history;
  late String canvas;

  Future<Map<String, Object?>> rows() async => {
    'nodes': [
      for (final r in await db.select(db.canvasNodes).get()) r.toJson(),
    ],
    'clips': [
      for (final r in await db.select(db.productionClips).get())
        {
          ...r.toJson(),
          'inputs': r.inputs.map((input) => input.toJson()).toList(),
        },
    ],
    'edges': [
      for (final r in await db.select(db.canvasEdges).get()) r.toJson(),
    ],
  };
  Future<CanvasNode> node(String id) async =>
      (await db.canvasDao.getNodeById(id))!;
  Future<void> cycle(Future<void> Function() action) async {
    final before = await rows();
    await action();
    final after = await rows();
    await history.undo();
    expect(await rows(), before);
    await history.redo();
    expect(await rows(), after);
  }

  setUp(() async {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = app.AppDatabase.forTest(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('canvas-history-');
    final initial = await ScreenplayService(db).createInitialStructure();
    final shots = StoryboardService(db);
    service = ProductionCanvasService(
      shots,
      MediaLibraryService(appDb, MediaService(FfmpegRunner()), root),
      'work',
    );
    canvas = (await service.ensureCanvas(initial.episodeId)).id;
    history = CanvasHistory(shots, canvas);
  });
  tearDown(() async {
    history.dispose();
    await db.close();
    await appDb.close();
    await root.delete(recursive: true);
  });

  test(
    'new image and audio undo to tombstones and redo with identical IDs',
    () async {
      for (final create in [service.addImage, service.addAudio]) {
        final created = await create(canvas, history: history);
        final original = await node(created.id);
        await history.undo();
        expect(await db.canvasDao.getNodeById(created.id), isNull);
        expect(await service.shots.getShot(created.clipId!), isNull);
        await history.redo();
        expect((await node(created.id)).toJson(), original.toJson());
        expect(await service.shots.getShot(created.clipId!), isNotNull);
      }
    },
  );

  test(
    'video, director and existing media additions retain identity on redo',
    () async {
      final overlay = WorkingOverlayService(
        db,
        NovelContentService(db),
        novelActionsService: NovelActionsService(appDb),
      );
      final file = File('${root.path}/file_workspaces/work/image.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
      await appDb.assetDao.insertAsset(
        app.AssetsCompanion.insert(
          id: 'image',
          type: 'image',
          name: const Value('image'),
          path: const Value('file_workspaces/work/image.png'),
          purpose: 'upload',
          content: const Value(ImageAssetContent(mimeType: 'image/png')),
        ),
      );
      for (final create in <Future<CanvasNode> Function()>[
        () => service.addFree(canvas, overlay: overlay, history: history),
        () => service.addDirector(canvas, 'director', history: history),
        () => service.addMedia(canvas, 'image', history: history),
      ]) {
        final created = await create();
        final original = (await node(created.id)).toJson();
        await history.undo();
        expect(await db.canvasDao.getNodeById(created.id), isNull);
        await history.redo();
        expect((await node(created.id)).toJson(), original);
      }
      expect(await appDb.assetDao.getAsset('image'), isNotNull);
      expect(await file.exists(), isTrue);
    },
  );

  test('unrelated node changes do not block a local step', () async {
    final a = await service.addImage(canvas);
    final b = await service.addImage(canvas);
    await service.move(a.id, 100, 200, history: history);
    await service.move(b.id, 300, 400);
    await history.undo();
    expect((await node(a.id)).x, a.x);
    expect((await node(b.id)).x, 300);
  });

  test('stored edge changes reject undo without changing the graph', () async {
    final a = await service.addImage(canvas, history: history);
    final b = await service.addImage(canvas);
    await db
        .into(db.canvasEdges)
        .insert(
          CanvasEdgesCompanion.insert(
            id: 'external',
            canvasId: canvas,
            sourceNodeId: a.id,
            targetNodeId: b.id,
          ),
        );
    final current = await rows();
    await expectLater(history.undo(), throwsA(isA<CanvasHistoryConflict>()));
    expect(await rows(), current);
  });

  test(
    'clip parameter columns are never restored by structural history',
    () async {
      final a = await service.addImage(canvas);
      await history.record<void>(
        'structure',
        nodeIds: [a.id],
        action: () async {
          await service.move(a.id, 100, 200);
          await (db.update(
            db.productionClips,
          )..where((t) => t.id.equals(a.clipId!))).write(
            const ProductionClipsCompanion(
              prompt: Value('keep current parameter'),
            ),
          );
        },
      );
      await history.undo();
      expect(
        (await service.shots.getShot(a.clipId!))!.prompt,
        'keep current parameter',
      );
      expect((await node(a.id)).x, a.x);
      await history.redo();
      expect((await node(a.id)).x, 100);
      expect(
        (await service.shots.getShot(a.clipId!))!.prompt,
        'keep current parameter',
      );
    },
  );

  test('consecutive moves undo and redo without self conflicts', () async {
    final created = await service.addImage(canvas);
    final before = await rows();
    await service.move(created.id, 50, 60, history: history);
    final middle = await rows();
    await service.move(created.id, 100, 120, history: history);
    final after = await rows();
    await history.undo();
    expect(await rows(), middle);
    await history.undo();
    expect(await rows(), before);
    await history.redo();
    expect(await rows(), middle);
    await history.redo();
    expect(await rows(), after);
  });

  test(
    'group creation restores membership and soft deletes only new group',
    () async {
      final a = await service.addImage(canvas);
      final b = await service.addImage(canvas);
      final group = await service.createStoryboardGroup(
        canvas,
        layout: const StoryboardGroupLayout(cols: 2, rows: 2),
        origin: Offset.zero,
        memberIds: [a.id, b.id],
        history: history,
      );
      final after = await rows();
      await history.undo();
      expect(await db.canvasDao.getNodeById(group.id), isNull);
      expect((await node(a.id)).parentId, isNull);
      expect((await node(b.id)).parentId, isNull);
      await history.redo();
      expect(await rows(), after);
    },
  );

  test(
    'move then fill undo and redo retain both group history steps',
    () async {
      Future<List<Map<String, dynamic>>> activeNodes() async => [
        for (final row in await db.canvasDao.getNodesByCanvas(canvas))
          row.toJson(),
      ];
      final file = File('${root.path}/file_workspaces/work/fill.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
      await appDb.assetDao.insertAsset(
        app.AssetsCompanion.insert(
          id: 'fill-image',
          type: 'image',
          name: const Value('fill'),
          path: const Value('file_workspaces/work/fill.png'),
          purpose: 'upload',
          content: const Value(ImageAssetContent(mimeType: 'image/png')),
        ),
      );
      final group = await service.createStoryboardGroup(
        canvas,
        layout: const StoryboardGroupLayout(cols: 2, rows: 2),
        origin: Offset.zero,
        memberIds: [],
      );
      final before = await activeNodes();
      await service.move(group.id, 300, 400, history: history);
      final moved = await activeNodes();
      final member = await service.fillStoryboardSlot(
        group.id,
        0,
        'fill-image',
        history: history,
      );
      final filled = await activeNodes();
      for (var i = 0; i < 2; i++) {
        await history.undo();
        expect(await db.canvasDao.getNodeById(member.id), isNull);
        expect(
          (await (db.select(
            db.canvasNodes,
          )..where((t) => t.id.equals(member.id))).getSingle()).parentId,
          group.id,
        );
        expect(await activeNodes(), moved);
        await history.undo();
        expect(await activeNodes(), before);
        expect(history.undoCount, 0);
        await history.redo();
        expect(await activeNodes(), moved);
        await history.redo();
        expect(await activeNodes(), filled);
        expect(
          (await (db.select(
            db.canvasNodes,
          )..where((t) => t.id.equals(member.id))).getSingle()).parentId,
          group.id,
        );
      }
    },
  );

  test(
    'external active group member still rejects an earlier group undo',
    () async {
      final group = await service.createStoryboardGroup(
        canvas,
        layout: const StoryboardGroupLayout(cols: 2, rows: 2),
        origin: Offset.zero,
        memberIds: [],
      );
      await service.move(group.id, 300, 400, history: history);
      final member = await service.addImage(canvas);
      await service.groups.attachToSlot(group.id, member.id, 0);
      final external = await rows();
      await expectLater(history.undo(), throwsA(isA<CanvasHistoryConflict>()));
      expect(await rows(), external);
    },
  );

  test(
    'external mutation of an explicit tombstone still blocks redo',
    () async {
      final created = await service.addImage(canvas, history: history);
      await history.undo();
      final deleted = await (db.select(
        db.canvasNodes,
      )..where((t) => t.id.equals(created.id))).getSingle();
      await db.canvasDao.restoreHistoryNode(
        deleted.copyWith(title: 'External edit'),
      );
      await expectLater(history.redo(), throwsA(isA<CanvasHistoryConflict>()));
      expect(await db.canvasDao.getNodeById(created.id), isNull);
      expect(
        (await (db.select(
          db.canvasNodes,
        )..where((t) => t.id.equals(created.id))).getSingle()).title,
        'External edit',
      );
    },
  );

  test('group structural operations restore exact rows', () async {
    final a = await service.addImage(canvas);
    final b = await service.addImage(canvas);
    final group = await service.createStoryboardGroup(
      canvas,
      layout: const StoryboardGroupLayout(cols: 2, rows: 2),
      origin: Offset.zero,
      memberIds: [a.id, b.id],
    );
    await cycle(
      () => service.groups.swapSlot(group.id, a.id, 1, history: history),
    );
    await cycle(
      () => service.groups.setStoryboardLayout(
        group.id,
        const StoryboardGroupLayout(cols: 3, rows: 2),
        history: history,
      ),
    );
    await cycle(
      () => service.moveNodes(canvas, {
        group.id: (x: 400, y: 500),
      }, history: history),
    );
    await cycle(() => service.groups.rename(group.id, 'new', history: history));
    final sizes = {a.id: const Size(300, 220), b.id: const Size(300, 220)};
    await cycle(() => service.groups.toFree(group.id, sizes, history: history));
    await cycle(
      () => service.groups.resizeFree(
        group.id,
        const Rect.fromLTWH(100, 150, 800, 900),
        history: history,
      ),
    );
    final rects = {
      for (final id in [a.id, b.id])
        id: Offset((await node(id)).x, (await node(id)).y) & sizes[id]!,
    };
    await cycle(
      () => service.groups.toStoryboard(group.id, rects, history: history),
    );
    await cycle(
      () => service.groups.ungroup(group.id, sizes: sizes, history: history),
    );
  });

  test(
    'group deletion restores clips, members and original stored edges',
    () async {
      final a = await service.addImage(canvas);
      final b = await service.addImage(canvas);
      final group = await service.createStoryboardGroup(
        canvas,
        layout: const StoryboardGroupLayout(cols: 2, rows: 2),
        origin: Offset.zero,
        memberIds: [a.id, b.id],
      );
      await db
          .into(db.canvasEdges)
          .insert(
            CanvasEdgesCompanion.insert(
              id: 'edge',
              canvasId: canvas,
              sourceNodeId: a.id,
              targetNodeId: b.id,
            ),
          );
      await cycle(() => service.removeNode(group.id, history: history));
    },
  );

  test('selection deletion includes every node sharing a clip', () async {
    final a = await service.addImage(canvas);
    await db.canvasDao.insertNode(a.copyWith(id: 'shared'));
    await cycle(() => service.removeNodes(canvas, {a.id}, history: history));
    expect(await db.canvasDao.getNodeById('shared'), isNull);
  });

  test(
    'input connection, reorder and disconnect restore only structure',
    () async {
      final a = await service.addImage(canvas);
      final b = await service.addImage(canvas);
      final c = await service.addImage(canvas);
      final first = ProductionInput.node(a.id, VideoInputRole.reference_image);
      final second = ProductionInput.node(b.id, VideoInputRole.reference_image);
      Future<void> inputs(List<ProductionInput> values) => history.record(
        'inputs',
        nodeIds: [c.id],
        action: () => service.shots.restoreInputs(
          c.clipId!,
          values.map((value) => value.toJson()).toList(),
        ),
      );
      await cycle(() => inputs([first, second]));
      await cycle(() => inputs([second, first]));
      await cycle(() => inputs([]));
    },
  );

  test(
    'same-second external modification rejects step and keeps data',
    () async {
      final a = await service.addImage(canvas);
      final b = await service.addImage(canvas);
      await service.move(b.id, 10, 20, history: history);
      await service.move(a.id, 30, 40, history: history);
      final saved = await node(a.id);
      await db.canvasDao.restoreHistoryNode(
        saved.copyWith(title: 'AI changed'),
      );
      final current = await rows();
      await expectLater(history.undo(), throwsA(isA<CanvasHistoryConflict>()));
      expect(await rows(), current);
      expect(history.undoCount, 1);
      await history.undo();
      expect((await node(b.id)).x, b.x);
    },
  );

  test(
    'new external edge and downstream input block destructive undo',
    () async {
      final a = await service.addImage(canvas, history: history);
      final b = await service.addImage(canvas);
      await service.shots.restoreInputs(b.clipId!, [
        ProductionInput.node(a.id, VideoInputRole.reference_image).toJson(),
      ]);
      final current = await rows();
      await expectLater(history.undo(), throwsA(isA<CanvasHistoryConflict>()));
      expect(await rows(), current);
    },
  );

  test('rollback never creates a history step', () async {
    final a = await service.addImage(canvas);
    final before = await rows();
    await expectLater(
      history.record<void>(
        'failed',
        nodeIds: [a.id],
        action: () async {
          await service.move(a.id, 50, 60);
          throw StateError('rollback');
        },
      ),
      throwsStateError,
    );
    expect(await rows(), before);
    expect(history.canUndo, isFalse);
    await expectLater(
      db.transaction(() => service.move(a.id, 50, 60, history: history)),
      throwsStateError,
    );
    expect(await rows(), before);
  });

  test(
    'failed restore keeps stack and rolls back partial restoration',
    () async {
      final a = await service.addImage(canvas);
      final b = await service.addImage(canvas);
      await service.moveNodes(canvas, {
        a.id: (x: 50, y: 60),
        b.id: (x: 70, y: 80),
      }, history: history);
      final current = await rows();
      await expectLater(
        db.runWithInterceptor(history.undo, interceptor: _RejectRestore(b.id)),
        throwsStateError,
      );
      expect(await rows(), current);
      expect(history.undoCount, 1);
      await history.undo();
      expect((await node(a.id)).x, a.x);
    },
  );

  test('history limit, redo invalidation and non-history changes', () async {
    final a = await service.addImage(canvas);
    for (var i = 1; i <= 101; i++) {
      await service.move(a.id, i.toDouble(), 0, history: history);
    }
    expect(history.undoCount, 100);
    await history.undo();
    expect(history.canRedo, isTrue);
    await service.move(a.id, 500, 0, history: history);
    expect(history.canRedo, isFalse);
    final count = history.undoCount;
    await service.move(a.id, 600, 0);
    expect(history.undoCount, count);
  });
}

class _RejectRestore extends QueryInterceptor {
  _RejectRestore(this.id);
  final String id;
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('canvas_nodes') && args.contains(id)) {
      throw StateError('test rollback');
    }
    return executor.runInsert(statement, args);
  }
}
