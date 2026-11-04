// 职责: 验证普通章节保存的原表读取及批量排版保留字数、不更新小说记录。
// 关联文件:
//   lib/shared/services/novel_content.dart
//   lib/shared/services/chapter_format_all.dart
//   lib/shared/database/novel_content_daos/chapter_dao.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/chapter_format_all.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';

void main() {
  late NovelContentDatabase database;
  late NovelContentService service;
  late _ReadRecorder reads;

  setUp(() async {
    reads = _ReadRecorder();
    database = NovelContentDatabase.forTest(
      NativeDatabase.memory().interceptWith(reads),
    );
    service = NovelContentService(database);
    await database.chapterDao.insert(
      ChaptersCompanion.insert(
        id: 'chapter',
        type: nodeTypeChapter,
        siblingOrder: 1,
        title: const Value('标题'),
        outline: const Value('大纲'),
        brief: const Value('摘要'),
        content: const Value('旧正文'),
        wordCount: const Value(3),
        updatedAt: Value(DateTime.utc(2020)),
        embeddingSyncStatus: const Value('synced'),
        embeddingSyncModelId: const Value('model'),
      ),
    );
    reads.statements.clear();
  });

  tearDown(() => database.close());

  test(
    'deleting among 566 chapters publishes one complete reordered tree',
    () async {
      await database.batch((batch) {
        for (var i = 1; i < 566; i++) {
          batch.insert(
            database.chapters,
            ChaptersCompanion.insert(
              id: 'chapter_$i',
              type: nodeTypeChapter,
              siblingOrder: i + 1,
              content: Value('正文' * 1000),
            ),
          );
        }
      });
      final snapshots = <List<Chapter>>[];
      final initial = Completer<void>();
      final afterDeletion = Completer<List<Chapter>>();
      final subscription = database.chapterDao.watchTree().listen((nodes) {
        snapshots.add(nodes);
        if (!initial.isCompleted) {
          initial.complete();
        } else if (!afterDeletion.isCompleted) {
          afterDeletion.complete(nodes);
        }
      });
      addTearDown(subscription.cancel);
      await initial.future;
      reads.statements.clear();
      reads.maxBodyRows = 0;
      final watch = Stopwatch()..start();
      await service.deleteChapter('chapter_10');
      final deletedSnapshot = await afterDeletion.future;
      watch.stop();
      final ordered = deletedSnapshot.toList()
        ..sort((a, b) => a.siblingOrder.compareTo(b.siblingOrder));
      expect(ordered.length, 565);
      expect(ordered.any((c) => c.id == 'chapter_10'), isFalse);
      expect(
        ordered.map((c) => c.siblingOrder),
        List.generate(565, (i) => i + 1),
      );
      // 已收到删除后的快照；短窗口仅检查是否还有多余发射。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      debugPrint(
        'delete among 566: ${watch.elapsedMilliseconds} ms; tree emissions=${snapshots.length - 1}; max body rows=${reads.maxBodyRows}',
      );
      expect(snapshots, hasLength(2));
      expect(reads.maxBodyRows, lessThanOrEqualTo(1));
    },
  );

  test('sorting failure rolls back the chapter deletion', () async {
    await database.chapterDao.insert(
      ChaptersCompanion.insert(
        id: 'next',
        type: nodeTypeChapter,
        siblingOrder: 2,
      ),
    );
    reads.failSorting = true;
    await expectLater(service.deleteChapter('chapter'), throwsStateError);
    reads.failSorting = false;
    expect(await service.getChapterById('chapter'), isNotNull);
    expect((await service.getChapterById('next'))!.siblingOrder, 2);
  });

  test('editing chapters preserves stored legacy vectors', () async {
    await database
        .into(database.aiEmbeddingDocuments)
        .insert(
          AiEmbeddingDocumentsCompanion.insert(
            id: 'legacy-chunk',
            sourceId: 'chapter:content',
            sourceType: 'chapter_content',
            path: '/chapters/chapter/content',
            chunkIndex: 0,
            content: '旧正文',
            embeddingModel: 'legacy-model',
            vector: [0.1, 0.2],
          ),
        );
    await service.updateChapterContentPartial(
      chapterId: 'chapter',
      content: '新正文',
    );
    await service.updateFormattedChapterContent(
      chapterId: 'chapter',
      content: '　　新正文',
    );
    final stored = await database
        .select(database.aiEmbeddingDocuments)
        .getSingle();
    expect(stored.id, 'legacy-chunk');
    expect(stored.content, '旧正文');
    expect(stored.embeddingModel, 'legacy-model');
    expect(stored.vector, [0.1, 0.2]);
  });

  test('partial save reads once without computing chapter numbers', () async {
    await service.updateChapterContentPartial(
      chapterId: 'chapter',
      content: '新正文\n\n',
    );
    expect(reads.statements, hasLength(1));
    expect(reads.statements.single, contains('FROM chapter_nodes'));
    final saved = (await service.getChapterById('chapter'))!;
    expect(saved.content, '新正文\n\n');
    expect(saved.title, '标题');
    expect(saved.outline, '大纲');
    expect(saved.brief, '摘要');
    expect(saved.wordCount, 3);
    expect(saved.embeddingSyncStatus, 'synced');
    expect(saved.embeddingSyncModelId, 'model');
    expect(saved.chapterNum, 1);
  });

  test(
    'full save reads the raw baseline and preserves legacy index metadata',
    () async {
      await service.updateChapterContent(
        chapterId: 'chapter',
        title: '标题',
        outline: '大纲',
        content: '旧正文',
      );
      expect(reads.statements, hasLength(1));
      expect(reads.statements.single, contains('FROM chapter_nodes'));
      final saved = (await service.getChapterById('chapter'))!;
      expect(saved.embeddingSyncStatus, 'synced');
      expect(saved.embeddingSyncModelId, 'model');
      expect(saved.brief, '摘要');
    },
  );

  test(
    'partial metadata save keeps content and legacy index metadata',
    () async {
      await service.updateChapterContentPartial(
        chapterId: 'chapter',
        brief: '新摘要',
      );
      final saved = (await service.getChapterById('chapter'))!;
      expect(saved.content, '旧正文');
      expect(saved.brief, '新摘要');
      expect(saved.embeddingSyncStatus, 'synced');
    },
  );

  test(
    'batch formatting keeps counts and never accesses novel metadata',
    () async {
      final formattingService = NovelContentService(
        database,
        novelActionsService: _UnusedNovelActions(),
      );
      final chapterIds = await formattingService.getChapterIdsWithContent();
      expect(
        await formatAllChapterContents(
          contentService: formattingService,
          chapterIds: chapterIds,
        ),
        1,
      );
      final saved = (await service.getChapterById('chapter'))!;
      expect(saved.content, '\u3000\u3000旧正文');
      expect(saved.wordCount, 3);
      expect(saved.title, '标题');
      expect(saved.outline, '大纲');
      expect(saved.brief, '摘要');
      expect(saved.updatedAt.isAfter(DateTime.utc(2020)), isTrue);
      expect(saved.embeddingSyncStatus, 'synced');
      expect(saved.embeddingSyncModelId, 'model');
      expect(
        await formatAllChapterContents(
          contentService: formattingService,
          chapterIds: chapterIds,
        ),
        0,
      );
    },
  );

  test('missing and soft-deleted chapters cannot be saved', () async {
    await database.chapterDao.softDelete('chapter');
    for (final id in ['chapter', 'missing']) {
      await expectLater(
        service.updateFormattedChapterContent(
          chapterId: id,
          content: 'changed',
        ),
        throwsStateError,
      );
      await expectLater(
        service.updateChapterContentPartial(chapterId: id, content: 'changed'),
        throwsException,
      );
      await expectLater(
        service.updateChapterContent(
          chapterId: id,
          title: '',
          outline: '',
          content: 'changed',
        ),
        throwsException,
      );
    }
    final row = await (database.select(
      database.chapters,
    )..where((t) => t.id.equals('chapter'))).getSingle();
    expect(row.content, '旧正文');
  });

  test('563 chapter formatting avoids per-chapter view scans', () async {
    for (var i = 1; i < 563; i++) {
      await database.chapterDao.insert(
        ChaptersCompanion.insert(
          id: 'chapter_$i',
          type: nodeTypeChapter,
          siblingOrder: i + 1,
          content: Value('测试正文。' * 200),
        ),
      );
    }
    reads.statements.clear();
    reads.elapsedMicros = 0;
    reads.maxBodyRows = 0;
    final stopwatch = Stopwatch()..start();
    final chapterIds = await service.getChapterIdsWithContent();
    final changed = await formatAllChapterContents(
      contentService: service,
      chapterIds: chapterIds,
    );
    stopwatch.stop();
    final viewReads = reads.statements
        .where((sql) => sql.contains('FROM chapters '))
        .length;
    debugPrint(
      'format 563: ${stopwatch.elapsedMilliseconds} ms; '
      'selects=${reads.statements.length}; viewReads=$viewReads; '
      'maxBodyRows=${reads.maxBodyRows}; '
      'selectTime=${reads.elapsedMicros ~/ 1000} ms',
    );
    expect(changed, 563);
    expect(reads.maxBodyRows, 1);
    expect(viewReads, 0);
    expect(
      await formatAllChapterContents(
        contentService: service,
        chapterIds: chapterIds,
      ),
      0,
    );
  });
}

class _UnusedNovelActions implements NovelActionsService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Formatting must not access novel metadata');
}

class _ReadRecorder extends QueryInterceptor {
  final statements = <String>[];
  var elapsedMicros = 0;
  var maxBodyRows = 0;
  bool failSorting = false;

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    if (failSorting) {
      throw StateError('injected sorting failure');
    }
    return executor.runBatched(statements);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (failSorting && statement.contains('sibling_order')) {
      throw StateError('injected sorting failure');
    }
    return executor.runUpdate(statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    statements.add(statement);
    final stopwatch = Stopwatch()..start();
    try {
      final rows = await executor.runSelect(statement, args);
      final bodyRows = rows.where((row) => row['content'] is String).length;
      if (bodyRows > maxBodyRows) {
        maxBodyRows = bodyRows;
      }
      return rows;
    } finally {
      elapsedMicros += stopwatch.elapsedMicroseconds;
    }
  }
}
