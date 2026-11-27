// 职责: 读写章节数据，正文直查原表，章号与树结构按需读取 VIEW。
// 关联文件:
//   lib/shared/database/novel_content_database.dart
// 遵循的 Rules:
//   .agents/rules/db-query-aggregation.md

import 'package:drift/drift.dart';

import '../../logger/app_logger.dart';
import '../../utils/chapter_highlight_anchor.dart';
import '../../utils/random_id.dart';
import '../novel_content_database.dart';

final _log = AppLogger.forModule('DB');

class ChapterListStats {
  const ChapterListStats({
    required this.chapterCount,
    required this.totalWordCount,
  });

  final int chapterCount;
  final int totalWordCount;
}

class ChapterDao {
  ChapterDao(this._db);
  final NovelContentDatabase _db;

  SimpleSelectStatement<$ChapterHighlightsTable, ChapterHighlight>
  _activeHighlights(String chapterId) =>
      _db.select(_db.chapterHighlights)..where(
        (table) =>
            table.chapterId.equals(chapterId) &
            table.deletedAt.equals(notDeletedSentinel),
      );

  Stream<List<ChapterHighlight>> watchHighlights(String chapterId) =>
      _activeHighlights(chapterId).watch();

  UpdateStatement<$ChapterHighlightsTable, ChapterHighlight> _updateHighlight(
    String chapterId,
    String id,
  ) => _db.update(_db.chapterHighlights)
    ..where(
      (table) =>
          table.id.equals(id) &
          table.chapterId.equals(chapterId) &
          table.deletedAt.equals(notDeletedSentinel),
    );

  Future<void> setHighlightColor({
    required String chapterId,
    required String id,
    required int? colorArgb,
  }) async {
    if (colorArgb != null && (colorArgb < 0 || colorArgb > 0xffffffff)) {
      throw ArgumentError.value(colorArgb, 'colorArgb');
    }
    try {
      final updated = await _updateHighlight(
        chapterId,
        id,
      ).write(ChapterHighlightsCompanion(colorArgb: Value(colorArgb)));
      if (updated == 0) {
        throw StateError('Chapter highlight is no longer available');
      }
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=chapter_highlights operation=UPDATE id=$id chapterId=$chapterId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> writeHighlight({
    required String chapterId,
    required String expectedContent,
    required ChapterHighlightRange selection,
    bool clear = false,
  }) async {
    final operation = clear ? 'UPDATE' : 'INSERT';
    final affectedIds = <String>[];
    try {
      await _db.transaction(() async {
        final body = await getBodyById(chapterId);
        if (body != expectedContent) {
          throw StateError('Chapter content changed before saving highlight');
        }
        final text = ChapterHighlightText(expectedContent);
        if (!text.isValidRange(selection) ||
            (!clear &&
                expectedContent
                    .substring(selection.start, selection.end)
                    .trim()
                    .isEmpty)) {
          throw ArgumentError('Invalid chapter highlight selection');
        }
        final existing = await _activeHighlights(chapterId).get();
        var alreadyPainted = false;
        await _db.batch((batch) {
          for (final mark in existing) {
            final range = text.resolve(mark);
            if (range == null ||
                range.end <= selection.start ||
                range.start >= selection.end) {
              continue;
            }
            if (!clear &&
                !alreadyPainted &&
                range == selection &&
                mark.colorArgb == null) {
              alreadyPainted = true;
              continue;
            }
            affectedIds.add(mark.id);
            _subtractHighlight(batch, mark, text, range, selection);
          }
        });
        if (clear || alreadyPainted) {
          return;
        }
        final sortOrder = await _nextHighlightSortOrder(chapterId);
        final id = buildRandomId('highlight');
        affectedIds.add(id);
        await _db
            .into(_db.chapterHighlights)
            .insert(
              _highlightValues(text, selection).copyWith(
                id: Value(id),
                chapterId: Value(chapterId),
                sortOrder: Value(sortOrder),
              ),
            );
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=chapter_highlights operation=$operation chapterId=$chapterId ids=$affectedIds '
        'selection=${selection.start}:${selection.end} error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  void _subtractHighlight(
    Batch batch,
    ChapterHighlight mark,
    ChapterHighlightText text,
    ChapterHighlightRange range,
    ChapterHighlightRange selection,
  ) {
    final remaining = [
      if (range.start < selection.start)
        (start: range.start, end: selection.start),
      if (range.end > selection.end) (start: selection.end, end: range.end),
    ];
    batch.update(
      _db.chapterHighlights,
      remaining.isEmpty
          ? ChapterHighlightsCompanion(deletedAt: Value(DateTime.now()))
          : _highlightValues(text, remaining.first),
      where: (table) => table.id.equals(mark.id),
    );
    if (remaining.length == 2) {
      batch.insert(
        _db.chapterHighlights,
        _highlightValues(text, remaining.last).copyWith(
          id: Value(buildRandomId('highlight')),
          chapterId: Value(mark.chapterId),
          sortOrder: Value(mark.sortOrder),
          colorArgb: Value(mark.colorArgb),
        ),
      );
    }
  }

  Future<int> _nextHighlightSortOrder(String chapterId) async {
    final table = _db.chapterHighlights;
    final latest = table.sortOrder.max();
    final row =
        await (_db.selectOnly(table)
              ..addColumns([latest])
              ..where(table.chapterId.equals(chapterId)))
            .getSingle();
    return (row.read(latest) ?? 0) + 1;
  }

  /// 与正文写入同事务执行，位置无法确认时保留原锚点。
  Future<void> rebaseHighlights({
    required String chapterId,
    required String before,
    required String after,
    required bool preserveSelection,
  }) async {
    if (before == after) {
      return;
    }
    final marks = await _activeHighlights(chapterId).get();
    if (marks.isEmpty) {
      return;
    }
    final oldText = ChapterHighlightText(before);
    final newText = ChapterHighlightText(after);
    final edit = preserveSelection ? ChapterHighlightEdit(before, after) : null;
    try {
      await _db.batch((batch) {
        for (final mark in marks) {
          final oldRange = edit == null ? null : oldText.resolve(mark);
          final moved = oldRange == null ? null : edit!.move(oldRange);
          final range = moved ?? newText.resolve(mark);
          if (range == null || !newText.isValidRange(range)) {
            continue;
          }
          batch.update(
            _db.chapterHighlights,
            _highlightValues(newText, range),
            where: (table) => table.id.equals(mark.id),
          );
        }
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=chapter_highlights operation=UPDATE chapterId=$chapterId '
        'ids=${marks.map((mark) => mark.id).join(",")} error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  ChapterHighlightsCompanion _highlightValues(
    ChapterHighlightText text,
    ChapterHighlightRange range,
  ) => ChapterHighlightsCompanion(
    startOffset: Value(range.start),
    endOffset: Value(range.end),
    quote: Value(text.value.substring(range.start, range.end)),
    prefix: Value(text.prefixAt(range.start)),
    suffix: Value(text.suffixAt(range.end)),
    contentHash: Value(text.hash),
  );

  String get _viewQuery => 'SELECT * FROM chapters WHERE 1=1';

  String get _treeQuery =>
      'SELECT id, type, parent_id, sibling_order, title, word_count, stat, '
      'tension, emotion, '
      'embedding_sync_status, embedding_synced_at, embedding_sync_model_id, '
      'created_at, updated_at, deleted_at, '
      'volume_num, chapter_num, volume_chapter_num '
      'FROM chapters WHERE 1=1';

  Future<List<Chapter>> getAll() async {
    final result = await _db.customSelect(_viewQuery).get();
    return result.map((row) => Chapter.fromViewRow(row.data)).toList();
  }

  /// 批量正文处理只取候选 ID，避免加载全书正文及 VIEW 计算列。
  Future<List<String>> getIdsWithContent() async {
    final rows = await _db
        .customSelect(
          'SELECT id FROM chapter_nodes '
          'WHERE deleted_at = 0 AND type IN (?, ?) AND content <> ? ORDER BY id',
          variables: [
            Variable.withString(nodeTypeChapter),
            Variable.withString(nodeTypeExtra),
            Variable.withString(''),
          ],
        )
        .get();
    return rows.map((row) => row.read<String>('id')).toList();
  }

  /// 单章正文处理不加载大纲、批注等无关字段。
  Future<String?> getBodyById(String id) async {
    final row = await _getActiveChapterRow(id, 'content');
    return row?.read<String>('content');
  }

  static const _hasHighlights =
      'EXISTS (SELECT 1 FROM chapter_highlights '
      'WHERE chapter_id = chapter_nodes.id AND deleted_at = 0) AS has_highlights';

  Future<({String content, bool hasHighlights})?> getBodyForWrite(
    String id,
  ) async {
    final row = await _getActiveChapterRow(id, 'content, $_hasHighlights');
    return row == null
        ? null
        : (
            content: row.read<String>('content'),
            hasHighlights: row.read<int>('has_highlights') != 0,
          );
  }

  Future<QueryRow?> _getActiveChapterRow(String id, String columns) => _db
      .customSelect(
        'SELECT $columns FROM chapter_nodes WHERE id = ? AND deleted_at = 0',
        variables: [Variable.withString(id)],
      )
      .getSingleOrNull();

  Stream<List<Chapter>> watchAll() {
    return _db
        .customSelect(_viewQuery, readsFrom: {_db.chapters})
        .watch()
        .map(
          (result) =>
              result.map((row) => Chapter.fromViewRow(row.data)).toList(),
        );
  }

  Stream<List<Chapter>> watchTree() {
    return _db
        .customSelect(_treeQuery, readsFrom: {_db.chapters})
        .watch()
        .map(
          (result) =>
              result.map((row) => Chapter.fromViewRow(row.data)).toList(),
        );
  }

  Future<List<Chapter>> getTree() async {
    final result = await _db.customSelect(_treeQuery).get();
    return result.map((row) => Chapter.fromViewRow(row.data)).toList();
  }

  String get _chapterColumns =>
      'id, type, parent_id, sibling_order, title, outline, brief, content, '
      'word_count, stat, tension, emotion, events, comments, '
      'embedding_sync_status, embedding_synced_at, embedding_sync_model_id, '
      'created_at, updated_at, deleted_at';

  /// 保存正文的基线直查原表，不计算章号；与 [getById] 一样排除软删除项。
  /// 需要展示章号时使用 [getById]；正文保存优先使用本方法，避免每次保存
  /// 都执行章节 VIEW 的窗口计算（详见 [watchContentById]）。
  Future<Chapter?> getContentById(String id) async {
    final row = await _getActiveChapterRow(id, _chapterColumns);
    return row == null ? null : Chapter.fromViewRow(row.data);
  }

  Future<({Chapter chapter, bool hasHighlights})?> getContentForWrite(
    String id,
  ) async {
    final row = await _getActiveChapterRow(
      id,
      '$_chapterColumns, $_hasHighlights',
    );
    return row == null
        ? null
        : (
            chapter: Chapter.fromViewRow(row.data),
            hasHighlights: row.read<int>('has_highlights') != 0,
          );
  }

  Stream<Chapter?> watchById(String id) {
    return _db
        .customSelect(
          '$_viewQuery AND id = ?',
          variables: [Variable.withString(id)],
          readsFrom: {_db.chapters},
        )
        .watchSingleOrNull()
        .map((row) => row == null ? null : Chapter.fromViewRow(row.data));
  }

  /// 只读单章正文相关列，直查 chapter_nodes 原表；不含 VIEW 计算章号。
  ///
  /// 性能：[watchById] 走 `chapters` VIEW，该 VIEW 为算出 volume_num /
  /// chapter_num / volume_chapter_num，内部有 3 个 ROW_NUMBER() 窗口 CTE +
  /// 自连接，SQLite 取单行也要先物化整张视图，章节多时明显变慢。编辑器加载
  /// 正文只需原表列、不需要这些计算章号，故直查原表避开视图开销；章号改由
  /// 章节树（[watchTree]）的 meta 提供。
  Stream<Chapter?> watchContentById(String id) {
    return _db
        .customSelect(
          'SELECT $_chapterColumns FROM chapter_nodes WHERE id = ?',
          variables: [Variable.withString(id)],
          readsFrom: {_db.chapters},
        )
        .watchSingleOrNull()
        .map((row) => row == null ? null : Chapter.fromViewRow(row.data));
  }

  Stream<Chapter?> watchLastWritten() {
    return _db
        .customSelect(
          '$_viewQuery AND type = ? AND word_count > 0 '
          'ORDER BY chapter_num DESC LIMIT 1',
          variables: [Variable.withString('chapter')],
          readsFrom: {_db.chapters},
        )
        .watchSingleOrNull()
        .map((row) => row == null ? null : Chapter.fromViewRow(row.data));
  }

  /// 最近改过且已有正文的章节，首页「继续写」用它回答「上次停在哪」。
  Stream<Chapter?> watchLastEdited() {
    return _db
        .customSelect(
          '$_viewQuery AND type = ? AND word_count > 0 '
          'ORDER BY updated_at DESC, chapter_num DESC LIMIT 1',
          variables: [Variable.withString('chapter')],
          readsFrom: {_db.chapters},
        )
        .watchSingleOrNull()
        .map((row) => row == null ? null : Chapter.fromViewRow(row.data));
  }

  Future<int> countActiveChapters() async {
    final result = await _db
        .customSelect(
          'SELECT COUNT(*) AS chapter_count '
          'FROM chapter_nodes '
          'WHERE type = ? AND deleted_at = 0',
          variables: [Variable.withString('chapter')],
        )
        .getSingle();
    return (result.data['chapter_count'] as num).toInt();
  }

  Future<ChapterListStats> getListStats() async {
    final result = await _db
        .customSelect(
          'SELECT '
          'COUNT(CASE WHEN type IN (?, ?) THEN 1 END) AS chapter_count, '
          'COALESCE(SUM(word_count), 0) AS total_word_count '
          'FROM chapter_nodes '
          'WHERE deleted_at = 0',
          variables: [
            Variable.withString(nodeTypeChapter),
            Variable.withString(nodeTypeExtra),
          ],
        )
        .getSingle();
    return ChapterListStats(
      chapterCount: (result.data['chapter_count'] as num).toInt(),
      totalWordCount: (result.data['total_word_count'] as num).toInt(),
    );
  }

  Future<Chapter?> getById(String id, {Set<String>? types}) async {
    if (types != null && types.isEmpty) {
      return null;
    }
    final typeCondition = types == null
        ? ''
        : ' AND type IN (${types.map((_) => '?').join(', ')})';
    final result = await _db
        .customSelect(
          '$_viewQuery AND id = ?$typeCondition',
          variables: [
            Variable.withString(id),
            if (types != null)
              for (final type in types) Variable.withString(type),
          ],
        )
        .get();
    if (result.isEmpty) {
      return null;
    }
    return Chapter.fromViewRow(result.first.data);
  }

  Future<List<Chapter>> getByIds(Set<String> ids) async {
    if (ids.isEmpty) {
      return const [];
    }
    final results = await _db
        .customSelect(
          '$_viewQuery AND id IN (${ids.map((_) => '?').join(',')})',
          variables: [for (final id in ids) Variable.withString(id)],
        )
        .get();
    return results.map((r) => Chapter.fromViewRow(r.data)).toList();
  }

  Future<Chapter?> getPrevious(String chapterId) async {
    final chapter = await getById(chapterId);
    if (chapter == null) {
      return null;
    }
    final chapterNum = chapter.chapterNum;
    if (chapterNum == null) {
      return null;
    }
    final result = await _db
        .customSelect(
          '$_viewQuery AND type = \'chapter\' '
          'AND chapter_num < ? '
          'ORDER BY chapter_num DESC LIMIT 1',
          variables: [Variable.withInt(chapterNum)],
        )
        .get();
    if (result.isEmpty) {
      return null;
    }
    return Chapter.fromViewRow(result.first.data);
  }

  Future<void> upsert(ChapterData data) async {
    await _db.into(_db.chapters).insertOnConflictUpdate(data);
  }

  Future<int> softDelete(String id) {
    return (_db.update(_db.chapters)..where((t) => t.id.equals(id))).write(
      ChaptersCompanion(
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<int> restore(String id) {
    return (_db.update(_db.chapters)..where((t) => t.id.equals(id))).write(
      ChaptersCompanion(deletedAt: Value(notDeletedSentinel)),
    );
  }

  Future<int> hardDelete(String id) {
    return (_db.delete(_db.chapters)..where((t) => t.id.equals(id))).go();
  }

  Future<int> nextSiblingOrderAtRoot() async {
    final result = await _db
        .customSelect(
          'SELECT COALESCE(MAX(sibling_order), 0) + 1 AS next_order '
          'FROM chapter_nodes WHERE parent_id IS NULL AND deleted_at = 0',
        )
        .get();
    return (result.first.data['next_order'] as num).toInt();
  }

  Future<int> nextSiblingOrderInVolume(String volumeId) async {
    final result = await _db
        .customSelect(
          'SELECT COALESCE(MAX(sibling_order), 0) + 1 AS next_order '
          'FROM chapter_nodes WHERE parent_id = ? AND deleted_at = 0',
          variables: [Variable.withString(volumeId)],
        )
        .get();
    return (result.first.data['next_order'] as num).toInt();
  }

  /// 将章节移入指定卷的末尾位置：
  /// 被移动的章节 sibling_order = 卷内 MAX+1，卷内已有章节不受影响。
  Future<void> moveToVolume(String chapterId, String volumeId) async {
    try {
      final order = await nextSiblingOrderInVolume(volumeId);
      await _db.transaction(() async {
        await (_db.update(
          _db.chapters,
        )..where((t) => t.id.equals(chapterId))).write(
          ChaptersCompanion(
            parentId: Value(volumeId),
            siblingOrder: Value(order),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });
    } catch (e, st) {
      _log.error(
        'UPDATE chapter_nodes (moveToVolume) failed: '
        'chapterId=$chapterId volumeId=$volumeId error=$e',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  Future<void> moveOutOfVolume(String chapterId) async {
    try {
      final order = await nextSiblingOrderAtRoot();
      await (_db.update(
        _db.chapters,
      )..where((t) => t.id.equals(chapterId))).write(
        ChaptersCompanion(
          parentId: const Value(null),
          siblingOrder: Value(order),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (e, st) {
      _log.error(
        'UPDATE chapter_nodes (moveOutOfVolume) failed: '
        'chapterId=$chapterId error=$e',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  /// 正文 ⇄ 番外互转。chapter_num 是视图里 ROW_NUMBER() 现算的、不落列，
  /// 所以转换后全书编号自动重排，这里不需要维护序号。
  Future<void> updateNodeType(String chapterId, String type) async {
    try {
      await (_db.update(
        _db.chapters,
      )..where((t) => t.id.equals(chapterId))).write(
        ChaptersCompanion(type: Value(type), updatedAt: Value(DateTime.now())),
      );
    } catch (e, st) {
      _log.error(
        'UPDATE chapter_nodes (updateNodeType) failed: '
        'chapterId=$chapterId type=$type error=$e',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  Future<void> insert(ChaptersCompanion companion) async {
    await _db.into(_db.chapters).insert(companion);
  }

  /// 获取同一父级下的所有节点（root 节点的 parentId 为 null），按 sibling_order 排序。
  Future<List<Chapter>> getSiblings(String? parentId) async {
    final result = await _db
        .customSelect(
          parentId != null
              ? '$_viewQuery AND parent_id = ? ORDER BY sibling_order ASC'
              : '$_viewQuery AND parent_id IS NULL ORDER BY sibling_order ASC',
          variables: parentId != null ? [Variable.withString(parentId)] : [],
        )
        .get();
    return result.map((row) => Chapter.fromViewRow(row.data)).toList();
  }

  Future<void> updateSiblingOrder(String id, int order) async {
    await (_db.update(_db.chapters)..where((t) => t.id.equals(id))).write(
      ChaptersCompanion(
        siblingOrder: Value(order),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// 将同一父级下所有节点的 sibling_order 重新编号为 1, 2, 3, ...
  Future<void> compactSiblingOrders(String? parentId) async {
    final siblings = await _db
        .customSelect(
          'SELECT id, sibling_order FROM chapter_nodes '
          'WHERE deleted_at = 0 AND '
          '${parentId == null ? 'parent_id IS NULL' : 'parent_id = ?'} '
          'ORDER BY sibling_order ASC',
          variables: parentId == null ? [] : [Variable.withString(parentId)],
        )
        .get();
    final now = DateTime.now();
    await _db.batch((batch) {
      for (var i = 0; i < siblings.length; i++) {
        final row = siblings[i];
        final newOrder = i + 1;
        if (row.read<int>('sibling_order') != newOrder) {
          batch.update(
            _db.chapters,
            ChaptersCompanion(
              siblingOrder: Value(newOrder),
              updatedAt: Value(now),
            ),
            where: (table) => table.id.equals(row.read<String>('id')),
          );
        }
      }
    });
  }

  /// 将 parent_id 指向无效卷（已删或不存在）的章节/番外移回根级。
  Future<void> repairOrphanChapterParents() async {
    try {
      final volumeRows = await _db
          .customSelect(
            'SELECT id FROM chapter_nodes WHERE type = ? AND deleted_at = 0',
            variables: [Variable.withString(nodeTypeVolume)],
          )
          .get();
      final liveVolumeIds = volumeRows
          .map((row) => row.read<String>('id'))
          .toSet();

      final orphanCandidates = await _db
          .customSelect(
            'SELECT id, parent_id FROM chapter_nodes '
            'WHERE deleted_at = 0 '
            'AND type IN (?, ?) '
            'AND parent_id IS NOT NULL',
            variables: [
              Variable.withString(nodeTypeChapter),
              Variable.withString(nodeTypeExtra),
            ],
          )
          .get();

      for (final row in orphanCandidates) {
        final parentId = row.read<String>('parent_id');
        if (liveVolumeIds.contains(parentId)) {
          continue;
        }
        final chapterId = row.read<String>('id');
        await moveOutOfVolume(chapterId);
      }
    } catch (e, st) {
      _log.error(
        'UPDATE chapter_nodes (repairOrphanChapterParents) failed: error=$e',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }
}
