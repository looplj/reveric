// 职责: 验证内容库首次建库、角色音色持久化和并发读取章节视图。
// 关联文件:
//   lib/shared/database/novel_content_database.dart
//   lib/shared/database/novel_content_database_indexes.dart
import 'dart:io';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('character voices persist in schema v1 across reopening', () async {
    final directory = await Directory.systemTemp.createTemp(
      'character-voices-',
    );
    final file = File('${directory.path}/content.sqlite');
    addTearDown(() => directory.delete(recursive: true));
    var db = NovelContentDatabase.forTest(NativeDatabase(file));
    try {
      await db
          .into(db.characterProfiles)
          .insert(
            CharacterProfilesCompanion.insert(
              id: 'hero',
              name: 'Hero',
              biography: const Value('Original biography'),
            ),
          );
      expect((await db.characterProfileDao.getById('hero'))!.voices, isNull);
      final columns = await db
          .customSelect('PRAGMA table_info(character_profiles)')
          .get();
      final voicesColumn = columns.singleWhere(
        (row) => row.data['name'] == 'voices',
      );
      expect(voicesColumn.data['type'], 'TEXT');
      expect(voicesColumn.data['notnull'], 0);
      expect(
        columns.singleWhere((row) => row.data['name'] == 'id').data['pk'],
        1,
      );
      const voices = [
        CharacterVoice(assetId: 'normal', name: '日常'),
        CharacterVoice(assetId: 'young', name: '少年'),
      ];
      await (db.update(db.characterProfiles)
            ..where((table) => table.id.equals('hero')))
          .write(const CharacterProfilesCompanion(voices: Value(voices)));
      await db.close();
      db = NovelContentDatabase.forTest(NativeDatabase(file));
      final character = (await db.characterProfileDao.getById('hero'))!;
      expect(character.voices, voices);
      expect(character.name, 'Hero');
      expect(character.biography, 'Original biography');
      expect((await db.select(db.characterProfiles).get()), hasLength(1));
      expect(
        (await db
                .customSelect(
                  'SELECT typeof(voices) AS type FROM character_profiles',
                )
                .getSingle())
            .data['type'],
        'text',
      );
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle())
            .data['user_version'],
        NovelContentDatabase.currentSchemaVersion,
      );
    } finally {
      await db.close();
    }
  });

  for (final journalMode in ['delete', 'wal']) {
    test(
      'reopens chapters while another connection writes ($journalMode)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'content-open-lock-',
        );
        final file = File('${directory.path}/content.sqlite');
        addTearDown(() => directory.delete(recursive: true));
        final initial = NovelContentDatabase.forTest(NativeDatabase(file));
        try {
          for (final (id, type, parent, order) in [
            ('volume', nodeTypeVolume, null, 1),
            ('chapter-b', nodeTypeChapter, 'volume', 2),
            ('chapter-a', nodeTypeChapter, 'volume', 1),
            ('standalone', nodeTypeChapter, null, 2),
          ]) {
            await initial
                .into(initial.chapters)
                .insert(
                  ChaptersCompanion.insert(
                    id: id,
                    type: type,
                    parentId: Value(parent),
                    siblingOrder: order,
                    title: Value(id),
                    content: const Value('Original content'),
                  ),
                );
          }
        } finally {
          await initial.close();
        }

        final writer = sqlite3.open(file.path);
        final reopened = NovelContentDatabase.forTest(
          NativeDatabase.createInBackground(file),
        );
        try {
          expect(
            writer
                .select('PRAGMA journal_mode = $journalMode')
                .single
                .values
                .single,
            journalMode,
          );
          final schemaBefore = writer
              .select('PRAGMA schema_version')
              .single
              .values
              .single;
          writer.execute('BEGIN IMMEDIATE');
          writer.execute(
            "UPDATE chapter_nodes SET title = 'Updated title' WHERE id = 'chapter-a'",
          );
          final chapters = await reopened.chapterDao.getAll();
          expect(chapters.map((chapter) => chapter.id), [
            'volume',
            'chapter-a',
            'chapter-b',
            'standalone',
          ]);
          expect(chapters.first.volumeNum, 1);
          expect(chapters.skip(1).map((chapter) => chapter.chapterNum), [
            1,
            2,
            3,
          ]);
          expect(chapters[1].volumeChapterNum, 1);
          expect(chapters[2].volumeChapterNum, 2);
          expect(chapters[1].title, 'chapter-a');
          expect(chapters[1].content, 'Original content');
          writer.execute('COMMIT');
          expect(
            (await reopened.chapterDao.getById('chapter-a'))!.title,
            'Updated title',
          );
          expect(
            writer.select('PRAGMA schema_version').single.values.single,
            schemaBefore,
          );
        } finally {
          if (!writer.autocommit) {
            writer.execute('ROLLBACK');
          }
          await reopened.close();
          writer.close();
        }
      },
    );
  }

  test('new canvas nodes index parent_id', () async {
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    try {
      expect(
        (await db
                .customSelect('PRAGMA index_info(canvas_nodes_by_parent_id)')
                .get())
            .map((row) => row.data['name']),
        ['parent_id'],
      );
    } finally {
      await db.close();
    }
  });

  test('new canvas has a nullable layout', () async {
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    try {
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle())
            .data['user_version'],
        NovelContentDatabase.currentSchemaVersion,
      );
      await db
          .into(db.canvases)
          .insert(CanvasesCompanion.insert(id: 'new-canvas', name: 'New'));
      expect((await db.canvasDao.getCanvasById('new-canvas'))!.layout, isNull);
    } finally {
      await db.close();
    }
  });

  test('fresh content database excludes retired vector map tables', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'reveric_retired_map_tables_test_',
    );
    final db = NovelContentDatabase.forTest(
      NativeDatabase(File('${tempDir.path}/novel.sqlite')),
    );
    try {
      final retiredTables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name IN ('map_features', 'map_layers', "
            "'location_connections')",
          )
          .get();
      expect(retiredTables, isEmpty);
    } finally {
      await db.close();
      await tempDir.delete(recursive: true);
    }
  });
}
