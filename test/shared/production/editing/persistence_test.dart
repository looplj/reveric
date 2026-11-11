// 职责: 验证剪辑持久化、修订竞争、保存失败保留修改及历史素材备份。
// 关联文件:
//   lib/shared/services/editing/service.dart
//   lib/desktop/features/editing/session.dart
//   lib/shared/services/production/backup_media.dart
//   test/helpers/backup_fixture.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:reveric/shared/services/production/editing_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/database/type_converters.dart';
import 'package:reveric/shared/services/editing/service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/backup_media.dart';
import 'package:reveric/desktop/features/editing/session.dart';
import '../../../helpers/backup_fixture.dart';
import 'commands_test.dart' show fixture;

void main() {
  test(
    'episode edits survive reopening and revision compare rejects stale writes',
    () async {
      final dir = await Directory.systemTemp.createTemp('editing-persistence-');
      final file = File('${dir.path}/content.sqlite');
      var db = NovelContentDatabase.forTest(NativeDatabase(file));
      await db.customStatement(
        "INSERT INTO screenplays(id,created_at,updated_at) VALUES('script',100,200)",
      );
      await db.customStatement(
        "INSERT INTO screenplay_episodes(id,screenplay_id,season_id,episode_number,title,created_at,updated_at) VALUES('episode','script','season',1,'Original',100,200)",
      );
      final app = AppDatabase.forTest(NativeDatabase.memory());
      final library = MediaLibraryService(
        app,
        MediaService(FfmpegRunner()),
        dir,
      );
      try {
        final service = EditingService(db, library);
        final initial = await EpisodeEditingOrchestrator().ensureEpisodeEditing(
          db,
          'episode',
        );
        final editingId = initial.editing.id;
        expect(initial.editing.document.clips, isEmpty);
        expect(initial.editing.revision, 0);
        expect(
          (await db.screenplayDao.getEpisode('episode'))!.title,
          'Original',
        );
        expect(await service.save(editingId, fixture(), 0), 1);
        await expectLater(
          service.save(editingId, fixture(), 0),
          throwsA(isA<EditingConflict>()),
        );
        await db.close();
        db = NovelContentDatabase.forTest(NativeDatabase(file));
        final reopened = await EditingService(db, library).load(editingId);
        expect(reopened.$1.toJson(), fixture().toJson());
        expect(reopened.$2, 1);
        final cols = await db
            .customSelect(
              "SELECT typeof(document) AS doc, typeof(revision) AS revision FROM video_editings",
            )
            .getSingle();
        expect(cols.read<String>('doc'), 'text');
        expect(cols.read<String>('revision'), 'integer');
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          db.schemaVersion,
        );
      } finally {
        await db.close();
        await app.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'autosave is serialized, failed revision preserves local edits, undo is saved',
    () async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final app = AppDatabase.forTest(NativeDatabase.memory());
      final dir = await Directory.systemTemp.createTemp('editing-session-');
      final service = EditingService(
        db,
        MediaLibraryService(app, MediaService(FfmpegRunner()), dir),
      );
      final session = EditingSession(service, 'episode');
      try {
        await db.customStatement(
          "INSERT INTO screenplay_episodes(id,screenplay_id,season_id,episode_number,created_at,updated_at) VALUES('episode','script','season',1,100,200)",
        );
        await db.editingDao.create('episode', 'Independent', fixture());
        await session.load();
        session.commit(fixture());
        await session.flush();
        final saved = session.document;
        session.commit(fixture().copyWith(ratio: '9:16'));
        await session.flush();
        session.undo();
        await session.flush();
        expect((await service.load('episode')).$1.ratio, '16:9');
        expect(session.document, same(saved));
        await service.save(
          'episode',
          fixture().copyWith(ratio: '1:1'),
          session.revision,
        );
        session.commit(fixture().copyWith(ratio: '4:3'));
        await expectLater(session.flush(), throwsA(isA<EditingConflict>()));
        expect(session.dirty, isTrue);
        expect(session.document!.ratio, '4:3');
        expect((await service.load('episode')).$1.ratio, '1:1');
        await session.reload();
        expect(session.document!.ratio, '1:1');
        expect(session.dirty, isFalse);
      } finally {
        session.dispose();
        await db.close();
        await app.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'backup includes fixed historical file from its asset even without current adoption',
    () async {
      final dir = await Directory.systemTemp.createTemp('editing-backup-');
      final schemas = await BackupDatabases.create();
      final main = schemas.writeMain('${dir.path}/reveric.sqlite');
      insertBackupRow(main, 'assets', {
        'id': 'media/video.mp4',
        'type': 'video',
        'purpose': 'reference',
        'path': 'file_workspaces/shared/videos/video.mp4',
      });
      main.close();
      final content = schemas.writeContent('${dir.path}/content.sqlite');
      insertBackupRow(content, 'video_editings', {
        'id': 'editing',
        'title': 'Editing',
        'deleted_at': 123,
        'document': const EditingDocumentConverter().toSql(fixture()),
      });
      content.close();
      try {
        final backup = collectSelectedMedia(
          backup: dir,
          novelIds: {'novel'},
          contentPaths: ['${dir.path}/content.sqlite'],
        );
        expect(
          backup.rows['assets']!.map((row) => row['id']),
          contains('media/video.mp4'),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
