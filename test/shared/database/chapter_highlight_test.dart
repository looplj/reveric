// 职责: 验证章节高亮升级、重开、软删除和改稿后的定位。
// 关联文件:
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/utils/chapter_highlight_anchor.dart

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/utils/chapter_highlight_anchor.dart';

void main() {
  test(
    'v2 chapters survive upgrading and their highlights survive reopening',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'chapter-highlights-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/content.sqlite');
      var database = NovelContentDatabase.forTest(
        NativeDatabase(
          file,
          setup: (db) {
            // chapter_nodes 结构与正式发布 v0.10.6 相同。
            db.execute(_releasedChapters);
            db.execute('PRAGMA user_version = 2');
          },
        ),
      );
      try {
        final version = await database
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(
          version.read<int>('user_version'),
          NovelContentDatabase.currentSchemaVersion,
        );
        final chapter = (await database.chapterDao.getContentById('chapter'))!;
        expect(chapter.title, '原标题');
        expect(chapter.content, '她说，门外传来脚步声。');
        expect((await database.select(database.chapters).get()), hasLength(1));

        var service = NovelContentService(database);
        const selection = (start: 3, end: 11);
        await service.writeChapterHighlight(
          chapterId: chapter.id,
          expectedContent: chapter.content,
          selection: selection,
        );
        await service.writeChapterHighlight(
          chapterId: chapter.id,
          expectedContent: chapter.content,
          selection: selection,
        );
        final saved =
            (await service.watchChapterHighlights(chapter.id).first).single;
        expect(saved.colorArgb, isNull);
        const colorArgb = 0xcc2255aa;
        await service.setChapterHighlightColor(
          chapterId: chapter.id,
          highlightId: saved.id,
          colorArgb: colorArgb,
        );
        final indexes = await database
            .customSelect('PRAGMA index_list(chapter_highlights)')
            .get();
        expect(
          indexes.map((row) => row.read<String>('name')),
          contains('chapter_highlights_by_chapter_id_deleted_at'),
        );
        final column =
            (await database
                    .customSelect('PRAGMA table_info(chapter_highlights)')
                    .get())
                .singleWhere((row) => row.read<String>('name') == 'id');
        expect(column.read<int>('pk'), 1);
        final types = await database
            .customSelect(
              'SELECT typeof(start_offset) AS offset_type, typeof(deleted_at) AS deleted_type, typeof(color_argb) AS color_type FROM chapter_highlights',
            )
            .getSingle();
        expect(types.read<String>('offset_type'), 'integer');
        expect(types.read<String>('deleted_type'), 'integer');
        expect(types.read<String>('color_type'), 'integer');

        const edited = '先等一下。她说，门外又传来脚步声。';
        const prefixed = '先等一下。她说，门外传来脚步声。';
        for (final body in [prefixed, edited]) {
          await service.updateChapterContentPartial(
            chapterId: chapter.id,
            content: body,
            preserveHighlightSelection: true,
          );
        }
        await database.close();
        database = NovelContentDatabase.forTest(NativeDatabase(file));
        service = NovelContentService(database);
        final mark =
            (await service.watchChapterHighlights(chapter.id).first).single;
        expect(mark.quote, '门外又传来脚步声。');
        expect(mark.colorArgb, colorArgb);
        expect(mark.sortOrder, saved.sortOrder);
        final resolved = ChapterHighlightText(edited).resolve(mark)!;
        expect(edited.substring(resolved.start, resolved.end), mark.quote);

        await expectLater(
          service.writeChapterHighlight(
            chapterId: chapter.id,
            expectedContent: chapter.content,
            selection: selection,
          ),
          throwsStateError,
        );
        await service.writeChapterHighlight(
          chapterId: chapter.id,
          expectedContent: edited,
          selection: resolved,
          clear: true,
        );
        expect(await service.watchChapterHighlights(chapter.id).first, isEmpty);
        expect(
          (await database.select(database.chapterHighlights).get())
              .single
              .deletedAt,
          isNot(notDeletedSentinel),
        );
        await service.writeChapterHighlight(
          chapterId: chapter.id,
          expectedContent: edited,
          selection: (start: 0, end: 1),
        );
        final laterMark =
            (await service.watchChapterHighlights(chapter.id).first).single;
        expect(laterMark.sortOrder, greaterThan(mark.sortOrder));
      } finally {
        await database.close();
      }
    },
  );

  test('painting and clearing subtract only the selected range', () async {
    final database = NovelContentDatabase.forTest(NativeDatabase.memory());
    addTearDown(database.close);
    final service = NovelContentService(database);
    final chapterId = await service.createChapter(siblingOrder: 1, title: '正文');
    const body = '甲乙丙丁戊己庚辛壬';
    await service.updateChapterContentPartial(
      chapterId: chapterId,
      content: body,
    );

    Future<void> write(int start, int end, {bool clear = false}) =>
        service.writeChapterHighlight(
          chapterId: chapterId,
          expectedContent: body,
          selection: (start: start, end: end),
          clear: clear,
        );
    Future<List<(int, int, int?)>> activeRanges() async {
      final marks = await service.watchChapterHighlights(chapterId).first;
      return marks
          .map((mark) => (mark.startOffset, mark.endOffset, mark.colorArgb))
          .toList();
    }

    await write(0, body.length);
    final original =
        (await service.watchChapterHighlights(chapterId).first).single;
    const customColor = 0x55224488;
    await service.setChapterHighlightColor(
      chapterId: chapterId,
      highlightId: original.id,
      colorArgb: customColor,
    );

    await write(2, 7);
    expect(
      await activeRanges(),
      unorderedEquals([(0, 2, customColor), (2, 7, null), (7, 9, customColor)]),
    );

    final painted = (await service.watchChapterHighlights(chapterId).first)
        .singleWhere((mark) => mark.startOffset == 2);
    await database
        .into(database.chapterHighlights)
        .insert(
          painted.copyWith(
            id: 'overlapping-highlight',
            sortOrder: original.sortOrder,
          ),
        );

    await write(1, 8, clear: true);
    expect(
      await activeRanges(),
      unorderedEquals([(0, 1, customColor), (8, 9, customColor)]),
    );

    final afterClearing = await database
        .select(database.chapterHighlights)
        .get();
    await write(1, 8, clear: true);
    expect(
      await database.select(database.chapterHighlights).get(),
      afterClearing,
    );
  });

  test(
    'external rewrite leaves equally matching occurrences unmarked',
    () async {
      final database = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(database.close);
      final service = NovelContentService(database);
      final chapterId = await service.createChapter(
        siblingOrder: 1,
        title: '正文',
      );
      const prefix = 'abcdefghijklmnop';
      const suffix = 'ABCDEFGHIJKLMNOP';
      const block = '$prefix对白$suffix';
      await service.updateChapterContentPartial(
        chapterId: chapterId,
        content: block,
      );
      await service.writeChapterHighlight(
        chapterId: chapterId,
        expectedContent: block,
        selection: (start: prefix.length, end: prefix.length + 2),
      );
      const rewritten = '$block\n$block';
      await service.updateChapterContentPartial(
        chapterId: chapterId,
        content: rewritten,
      );
      final mark =
          (await service.watchChapterHighlights(chapterId).first).single;
      expect(ChapterHighlightText(rewritten).resolve(mark), isNull);
      expect(ChapterHighlightText(block).resolve(mark), (
        start: prefix.length,
        end: prefix.length + 2,
      ));
    },
  );
}

const _releasedChapters = '''
CREATE TABLE chapter_nodes (
  id TEXT NOT NULL PRIMARY KEY, type TEXT NOT NULL, parent_id TEXT,
  sibling_order INTEGER NOT NULL, title TEXT, outline TEXT NOT NULL DEFAULT '',
  brief TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '',
  word_count INTEGER NOT NULL DEFAULT 0, stat TEXT NOT NULL DEFAULT 'draft',
  tension INTEGER, emotion TEXT, events TEXT, comments TEXT,
  embedding_sync_status TEXT NOT NULL DEFAULT 'pending',
  embedding_synced_at INTEGER, embedding_sync_model_id TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  deleted_at INTEGER NOT NULL DEFAULT 0
);
INSERT INTO chapter_nodes (id, type, sibling_order, title, content, created_at, updated_at)
VALUES ('chapter', 'chapter', 1, '原标题', '她说，门外传来脚步声。', 123, 456);
''';
