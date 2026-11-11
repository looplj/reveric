// 职责: 验证画布剪辑节点的事务归属、软删除、撤销与采用素材查询。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/canvas_history.dart
//   lib/shared/services/editing/service.dart
import 'dart:io';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/editing/document.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/canvas_history.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/editing/service.dart';

void main() {
  late NovelContentDatabase db;
  late app.AppDatabase main;
  late ProductionCanvasService canvas;
  late CanvasHistory history;
  late EditingService projects;
  late String canvasId;
  setUp(() async {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    main = app.AppDatabase.forTest(NativeDatabase.memory());
    await ScreenplayService(db).createCanvasStructure();
    await main.novelDao.create(
      id: 'work',
      title: 'Canvas',
      description: '',
      contentKind: contentKindCanvas,
      contentDatabasePath: db.filePath,
    );
    canvas = ProductionCanvasService(
      StoryboardService(db, contentKind: contentKindCanvas),
      MediaLibraryService(
        main,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      ),
      'work',
    );
    canvasId = (await canvas.ensureCanvas('')).id;
    history = CanvasHistory(canvas.shots, canvasId);
    projects = EditingService(db, canvas.library);
  });
  tearDown(() async {
    history.dispose();
    await db.close();
    await main.close();
  });

  test(
    'node and project create atomically, keep identities and use work ratio',
    () async {
      await db
          .update(db.screenplays)
          .write(const ScreenplaysCompanion(ratio: Value('9:16')));
      final first = await canvas.addEditing(
        canvasId,
        title: 'Version A',
        history: history,
      );
      final second = await canvas.addEditing(canvasId, title: 'Version B');
      expect(first.editingId, isNot(second.editingId));
      expect(
        (await canvas.requireEditingNode(first.id)).document.ratio,
        '9:16',
      );
      expect(await projects.canvasForEditing(first.editingId!), canvasId);
      await history.undo();
      expect(await db.canvasDao.getNodeById(first.id), isNull);
      expect(await db.editingDao.get(first.editingId!), isNull);
      expect(await db.editingDao.get(second.editingId!), isNotNull);
      await history.redo();
      expect((await canvas.requireEditingNode(first.id)).id, first.editingId);
    },
  );

  test('failure between project and node creation rolls back both', () async {
    await expectLater(
      db.runWithInterceptor(
        () => canvas.addEditing(canvasId, title: 'Failed'),
        interceptor: _RejectNodeWrite(insert: true),
      ),
      throwsStateError,
    );
    expect(await db.select(db.videoEditings).get(), isEmpty);
    expect(await db.canvasDao.getNodesByCanvas(canvasId), isEmpty);
  });

  test(
    'delete undo and redo preserve timeline revision and document',
    () async {
      final node = await canvas.addEditing(canvasId, title: 'Version');
      final document = EditingDocument.empty('1:1');
      await db.editingDao.save(
        node.editingId!,
        expectedRevision: 0,
        document: document,
        title: 'Edited title',
      );
      await canvas.removeNode(node.id, history: history);
      expect(await db.editingDao.get(node.editingId!), isNull);
      await history.undo();
      final restored = await canvas.requireEditingNode(node.id);
      expect(restored.title, 'Edited title');
      expect(restored.revision, 1);
      expect(restored.document.toJson(), document.toJson());
      await history.redo();
      expect(await db.canvasDao.getNodeById(node.id), isNull);
      expect(await db.editingDao.get(node.editingId!), isNull);
    },
  );

  test(
    'delete failure rolls back project flag and node; history stays empty',
    () async {
      final node = await canvas.addEditing(canvasId, title: 'Version');
      await expectLater(
        db.runWithInterceptor(
          () => canvas.removeNode(node.id, history: history),
          interceptor: _RejectNodeWrite(insert: false),
        ),
        throwsStateError,
      );
      expect(await db.editingDao.get(node.editingId!), isNotNull);
      expect(await db.canvasDao.getNodeById(node.id), isNotNull);
      expect(history.canUndo, isFalse);
    },
  );

  test(
    'missing/deleted project remains removable and is never recreated',
    () async {
      final node = await canvas.addEditing(canvasId, title: 'Deleted');
      await db.editingDao.softDelete(node.editingId!);
      await expectLater(
        canvas.requireEditingNode(node.id),
        throwsA(isA<StoryboardException>()),
      );
      await canvas.removeNode(node.id, history: history);
      await history.undo();
      expect(await db.canvasDao.getNodeById(node.id), isNotNull);
      expect(await db.editingDao.get(node.editingId!), isNull);
      final orphan = await canvas.addEditing(canvasId, title: 'Missing');
      await db.canvasDao.updateActiveNodeFields(
        orphan.id,
        const CanvasNodesCompanion(refId: Value('missing')),
      );
      await expectLater(
        canvas.requireEditingNode(orphan.id),
        throwsA(isA<StoryboardException>()),
      );
      await canvas.removeNode(orphan.id);
      expect(await db.canvasDao.getNodeById(orphan.id), isNull);
      expect(await db.editingDao.get('missing'), isNull);
    },
  );

  test(
    'external timeline edit rejects structural undo without overwriting it',
    () async {
      final node = await canvas.addEditing(canvasId, title: 'Version');
      await canvas.move(node.id, 900, 600, history: history);
      await db.editingDao.save(
        node.editingId!,
        expectedRevision: 0,
        document: EditingDocument.empty('1:1'),
      );
      await expectLater(history.undo(), throwsA(isA<CanvasHistoryConflict>()));
      expect((await canvas.requireNode(node.id)).x, 900);
      expect((await canvas.requireEditingNode(node.id)).document.ratio, '1:1');
    },
  );

  test(
    'adopted list follows canvas video creation order, visible titles and current result',
    () async {
      final editing = await canvas.addEditing(canvasId, title: 'Version');
      final clips = [
        for (var i = 0; i < 2; i++)
          await canvas.shots.createVideo('', values: {'title': 'Video $i'}),
      ];
      final nodes = [
        for (final clip in clips) await canvas.shots.ensureClipNode(clip.id),
      ];
      for (final (i, node) in nodes.indexed) {
        await db.canvasDao.restoreHistoryNode(
          node.copyWith(createdAt: DateTime(2026, 1, 2 - i)),
        );
      }
      await canvas.addImage(canvasId);
      await canvas.shots.apply(clips[1].id, {
        ...canvas.shots.snapshot(clips[1]),
        'title': 'Renamed video',
      });
      await (db.update(
        db.productionClips,
      )..where((t) => t.id.equals(clips[1].id))).write(
        const ProductionClipsCompanion(adoptedAssetId: Value('first-result')),
      );
      var rows = await projects.canvasAdopted(editing.editingId!);
      expect(rows.map((r) => r.id), [clips[1].id, clips[0].id]);
      expect(rows.first.title, 'Renamed video');
      expect(rows.first.assetId, 'first-result');
      expect(rows.last.assetId, isNull);
      await (db.update(
        db.productionClips,
      )..where((t) => t.id.equals(clips[1].id))).write(
        const ProductionClipsCompanion(adoptedAssetId: Value('replacement')),
      );
      rows = await projects.canvasAdopted(editing.editingId!);
      expect(rows.first.assetId, 'replacement');
      await expectLater(
        projects.canvasForEditing('other-work-project'),
        throwsStateError,
      );
      await main.novelDao.softDelete('work');
      await expectLater(
        projects.canvasForEditing(editing.editingId!),
        throwsStateError,
      );
    },
  );
}

class _RejectNodeWrite extends QueryInterceptor {
  _RejectNodeWrite({required this.insert});
  final bool insert;
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (insert && statement.contains('INTO "canvas_nodes"')) {
      throw StateError('node insert failed');
    }
    return executor.runInsert(statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (!insert && statement.contains('UPDATE "canvas_nodes"')) {
      throw StateError('node delete failed');
    }
    return executor.runUpdate(statement, args);
  }
}
