// 职责: 小说内容库读写服务，负责章节/条目持久化、字数同步。
// 关联文件:
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/services/novel_import.dart
//   lib/shared/services/ai/chat.dart
//   lib/shared/utils/storage_paths.dart
// 遵循的 Rules:
//   .agents/rules/json.md
import 'screenplay/staging_edit.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/novel_content_database.dart';
import '../database/novel_content_daos/chapter_dao.dart';
import '../models/chapter_comment.dart';
import '../models/content_status.dart';
import '../models/screenplay.dart';
import '../utils/ai_path_name_check.dart';
import '../utils/short_entity_id.dart';
import '../utils/short_entity_id_allocator.dart';
import '../utils/unique_display_name.dart';
import '../logger/app_logger.dart';
import '../utils/text_unit_count.dart';
import 'novel_actions.dart';
import 'image_library_service.dart';
import 'canvas_service.dart';
import 'documents_service.dart';
import 'entity_relations_service.dart';
import 'maps_service.dart';
import 'production/subject_references.dart';
import 'outline_service.dart';

class ImportedChapterNode {
  const ImportedChapterNode({
    required this.title,
    required this.content,
    this.volumeTitle,
  });

  final String title;
  final String content;
  final String? volumeTitle;
}

final _log = AppLogger.forModule('NovelContent');

/// 归一化角色别名：去空白、丢弃与本名相同的别名、去重。
///
/// 别名等于本名不算错误——AI 生成角色档案时经常把本名同时写进 aliases，
/// 用户手动输入时也会重复。这里与去空、去重一样静默丢弃，避免整份角色档案
/// 因为一个冗余别名而写入失败。
List<String> _normalizeCharacterAliases({
  required String name,
  required List<String> aliases,
}) {
  final normalizedName = name.trim();
  final result = <String>[];
  final seen = <String>{};
  for (final alias in aliases) {
    final normalized = alias.trim();
    if (normalized.isEmpty) {
      continue;
    }
    if (normalized == normalizedName) {
      continue;
    }
    if (seen.add(normalized)) {
      result.add(normalized);
    }
  }
  return result;
}

List<String> _normalizeCharacterTags(List<String> tags) {
  final result = <String>[];
  final seen = <String>{};
  for (final rawTag in tags) {
    final tag = rawTag.trim();
    final normalized = tag.toLowerCase();
    if (tag.isEmpty || !seen.add(normalized)) {
      continue;
    }
    result.add(tag);
  }
  return result;
}

List<CharacterBehaviorTag> _normalizeCharacterBehaviorTags(
  List<CharacterBehaviorTag> behaviorTags,
) {
  final result = <CharacterBehaviorTag>[];
  final seen = <String>{};
  for (final behaviorTag in behaviorTags) {
    final normalized = behaviorTag.normalized();
    if (normalized.tag.isEmpty || normalized.context.isEmpty) {
      throw ArgumentError.value(
        behaviorTag.toJson(),
        'behaviorTags',
        'Behavior tag and context are required.',
      );
    }
    final key = '${normalized.tag}\u0000${normalized.context}';
    if (seen.add(key)) {
      result.add(normalized);
    }
  }
  return result;
}

class NovelContentService {
  NovelContentService(
    this._database, {
    this.novelActionsService,
    this.imageLibraryService,
    ShortEntityIdBuilder idBuilder = buildShortEntityId,
  }) : _buildEntityId = idBuilder;

  final NovelContentDatabase _database;
  final NovelActionsService? novelActionsService;
  final ImageLibraryService? imageLibraryService;
  final ShortEntityIdBuilder _buildEntityId;

  Future<void> _assertCharacterFirstAppearChapter(
    String? firstAppearChapterId,
  ) async {
    if (firstAppearChapterId == null) {
      return;
    }
    final chapter = await getChapterById(firstAppearChapterId);
    if (chapter == null || !chapter.isChapter) {
      throw ArgumentError.value(
        firstAppearChapterId,
        'firstAppearChapterId',
        'First appearance must reference an existing chapter or extra.',
      );
    }
  }

  /// 只读数据库引用（供 tool 层检索 AI 聊天历史等）。
  NovelContentDatabase get database => _database;

  late final DocumentsService documentsService = DocumentsService(
    _database,
    idBuilder: _buildEntityId,
  );

  late final LocationsService locationsService = LocationsService(
    _database,
    idBuilder: _buildEntityId,
  );

  late final OutlineService outlineService = OutlineService(
    _database,
    idBuilder: _buildEntityId,
  );

  late final EntityRelationsService entityRelationsService =
      EntityRelationsService(_database, idBuilder: _buildEntityId);

  late final StagingEditService stagingEditService = StagingEditService(
    _database,
  );

  late final CanvasService canvasService = CanvasService(
    _database,
    idBuilder: _buildEntityId,
  );

  Future<bool> _idExists(String tableName, String id) async {
    final row = await _database
        .customSelect(
          'SELECT 1 FROM $tableName WHERE id = ? LIMIT 1',
          variables: [Variable.withString(id)],
        )
        .getSingleOrNull();
    return row != null;
  }

  ShortEntityIdType _itemIdType(String type) {
    return switch (type) {
      entityTypeSkill => ShortEntityIdType.skill,
      entityTypeItem => ShortEntityIdType.item,
      entityTypeFaction => ShortEntityIdType.faction,
      entityTypeCreature => ShortEntityIdType.creature,
      _ => throw ArgumentError.value(
        type,
        'type',
        'Unsupported model-visible item type.',
      ),
    };
  }

  Stream<List<Chapter>> watchChapters() => _database.chapterDao.watchAll();

  Stream<List<Chapter>> watchChapterTree() => _database.chapterDao.watchTree();

  Future<List<Chapter>> getChapters() => _database.chapterDao.getAll();

  Future<List<String>> getChapterIdsWithContent() =>
      _database.chapterDao.getIdsWithContent();

  /// 章节不存在或已软删除时返回 null，由批量处理调用方跳过。
  Future<String?> getChapterBodyById(String chapterId) =>
      _database.chapterDao.getBodyById(chapterId);

  Future<ChapterListStats> getChapterListStats() =>
      _database.chapterDao.getListStats();

  Stream<Chapter?> watchChapterById(String chapterId) {
    return _database.chapterDao.watchById(chapterId);
  }

  /// 编辑器正文加载专用：只订阅原表正文列，避开 `chapters` VIEW 的窗口函数
  /// 开销（详见 [ChapterDao.watchContentById]）。章号由章节树提供。
  Stream<Chapter?> watchChapterContentById(String chapterId) {
    return _database.chapterDao.watchContentById(chapterId);
  }

  Stream<Chapter?> watchLastWrittenChapter() {
    return _database.chapterDao.watchLastWritten();
  }

  Stream<Chapter?> watchLastEditedChapter() {
    return _database.chapterDao.watchLastEdited();
  }

  Future<Chapter?> getChapterById(String chapterId, {Set<String>? types}) {
    return _database.chapterDao.getById(chapterId, types: types);
  }

  Future<Chapter?> getPreviousChapter(String chapterId) {
    return _database.chapterDao.getPrevious(chapterId);
  }

  Stream<List<Item>> watchItemsByType(String type) {
    return _database.itemDao.watchByType(type);
  }

  Future<List<Item>> getItemsByType(String type) {
    return _database.itemDao.getByType(type);
  }

  Future<Item?> getItemById(String entryId) {
    return _database.itemDao.getById(entryId);
  }

  Future<List<Item>> getItemsByIds(Set<String> ids) {
    return _database.itemDao.getByIds(ids);
  }

  Future<Item?> getItemByTypeAndTitle(String type, String title) {
    return _database.itemDao.getByTypeAndTitle(type, title);
  }

  Future<String> createItem({
    required String type,
    String? defaultTitle,
    String? title,
    String content = '',
    String status = itemEntryStatusActive,
    String category = '',
  }) async {
    final now = DateTime.now();
    final nextSortOrder = await _nextSortOrder(_database.items);
    final resolvedTitle =
        title ??
        (defaultTitle == null
            ? ''
            : buildUniqueDisplayName(
                baseName: defaultTitle,
                existingNames: (await getItemsByType(type)).map((item) {
                  return item.title;
                }),
              ));
    if (status != itemEntryStatusActive) {
      _assertAllowedStatus(status, itemEntryStatuses, fieldName: 'status');
    }
    if (nameHasAiPathStructuralChars(resolvedTitle)) {
      throw ArgumentError.value(
        resolvedTitle,
        'title',
        'Item title must not contain "?" or "/" (AI path separators)',
      );
    }
    try {
      return await insertWithShortEntityId(
        type: _itemIdType(type),
        tableName: 'items',
        idExists: (id) => _idExists('items', id),
        buildId: _buildEntityId,
        insert: (id) => _database
            .into(_database.items)
            .insert(
              ItemsCompanion.insert(
                id: id,
                type: type,
                title: resolvedTitle,
                content: Value(content),
                status: Value(status),
                category: Value(category),
                sortOrder: Value(nextSortOrder),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=items operation=INSERT type=$type error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> updateItem({
    required String entryId,
    required String title,
    required String content,
    String? category,
  }) async {
    if (nameHasAiPathStructuralChars(title)) {
      throw ArgumentError.value(
        title,
        'title',
        'Item title must not contain "?" or "/" (AI path separators)',
      );
    }
    await (_database.update(
      _database.items,
    )..where((table) => table.id.equals(entryId))).write(
      ItemsCompanion(
        title: Value(title),
        content: Value(content.trimRight()),
        category: category == null ? const Value.absent() : Value(category),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> updateItemStatus({
    required String entryId,
    required String status,
  }) {
    _assertAllowedStatus(status, itemEntryStatuses, fieldName: 'status');
    return (_database.update(
      _database.items,
    )..where((table) => table.id.equals(entryId))).write(
      ItemsCompanion(status: Value(status), updatedAt: Value(DateTime.now())),
    );
  }

  /// [assetIds] 是界面上的照片顺序；已有照片的名称按资产保留。
  Future<void> updateItemPhotos({
    required String entryId,
    required List<String> assetIds,
  }) => _editItemPhotos(entryId, (photos) {
    final names = {for (final photo in photos) photo.assetId: photo.name};
    return [
      for (final id in assetIds)
        SubjectPhoto(assetId: id, name: names[id] ?? ''),
    ];
  });

  Future<void> addItemPhotos(String id, List<String> assetIds) =>
      _editItemPhotos(id, (photos) {
        final existing = photos.map((photo) => photo.assetId).toSet();
        return [
          ...photos,
          for (final assetId in assetIds)
            if (existing.add(assetId)) SubjectPhoto(assetId: assetId),
        ];
      });

  Future<void> removeItemPhoto(String id, String assetId) => _editItemPhotos(
    id,
    (photos) => [
      for (final photo in photos)
        if (photo.assetId != assetId) photo,
    ],
  );

  Future<void> renameItemPhoto(String id, String assetId, String name) =>
      _editItemPhotos(id, (photos) {
        if (!photos.any((photo) => photo.assetId == assetId)) {
          throw StateError('Photo no longer exists');
        }
        return [
          for (final photo in photos)
            photo.assetId == assetId
                ? photo.copyWith(name: name.trim())
                : photo,
        ];
      });

  Future<void> _editItemPhotos(
    String id,
    List<SubjectPhoto> Function(List<SubjectPhoto>) edit,
  ) async {
    try {
      await _database.transaction(() async {
        final item = await getItemById(id);
        if (item == null) {
          throw StateError('Compendium entry no longer exists');
        }
        await _database.itemDao.updatePhotos(id, edit(item.photos ?? const []));
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=items operation=UPDATE_PHOTOS id=$id',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> deleteItem(String entryId) async {
    final item = await getItemById(entryId);
    if (item == null) {
      return;
    }
    await deleteEntityWithRelations(
      entityType: item.type,
      entityId: entryId,
      validateBeforeDelete: () =>
          requireUnusedProductionSubject(_database, itemId: entryId),
      deleteEntityRow: () async {
        await (_database.delete(
          _database.items,
        )..where((table) => table.id.equals(entryId))).go();
      },
    );
  }

  Future<void> deleteEntityWithRelations({
    required String entityType,
    required String entityId,
    required Future<void> Function() deleteEntityRow,
    Future<void> Function()? validateBeforeDelete,
  }) async {
    try {
      await _database.transaction(() async {
        await validateBeforeDelete?.call();
        await entityRelationsService.deleteRelationsForEntity(
          entityType: entityType,
          entityId: entityId,
        );
        await deleteEntityRow();
      });
    } catch (error, stackTrace) {
      _log.error(
        'DELETE entity type=$entityType id=$entityId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Stream<List<CharacterProfile>> watchCharacterProfiles() {
    return _database.characterProfileDao.watchAll();
  }

  Future<List<CharacterProfile>> getCharacterProfiles() {
    return _database.characterProfileDao.getAll();
  }

  Future<CharacterProfile?> getCharacterProfileById(String entryId) {
    return _database.characterProfileDao.getById(entryId);
  }

  Stream<List<Foreshadowing>> watchForeshadowings() {
    return _database.foreshadowingDao.watchAll();
  }

  Future<List<Foreshadowing>> getForeshadowings() {
    return _database.foreshadowingDao.getAll();
  }

  Future<Foreshadowing?> getForeshadowingById(String entryId) {
    return _database.foreshadowingDao.getById(entryId);
  }

  Future<String> createChapter({
    required int siblingOrder,
    required String title,
    String type = nodeTypeChapter,
    String? parentId,
  }) async {
    final now = DateTime.now();
    final idType = switch (type) {
      nodeTypeChapter => ShortEntityIdType.chapter,
      nodeTypeExtra => ShortEntityIdType.extra,
      _ => throw ArgumentError.value(type, 'type', 'Unsupported chapter type.'),
    };
    final id = await insertWithShortEntityId(
      type: idType,
      tableName: 'chapter_nodes',
      idExists: (candidate) => _idExists('chapter_nodes', candidate),
      buildId: _buildEntityId,
      insert: (candidate) => _database.chapterDao.insert(
        ChaptersCompanion.insert(
          id: candidate,
          type: type,
          parentId: Value(parentId),
          siblingOrder: siblingOrder,
          title: Value(title),
          outline: const Value(''),
          content: const Value(''),
          wordCount: const Value(0),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      ),
    );
    await _syncNovelWordCount();
    return id;
  }

  Future<String> createVolume({
    required String title,
    String? description,
  }) async {
    final now = DateTime.now();
    final siblingOrder = await _database.chapterDao.nextSiblingOrderAtRoot();
    return insertWithShortEntityId(
      type: ShortEntityIdType.volume,
      tableName: 'chapter_nodes',
      idExists: (candidate) => _idExists('chapter_nodes', candidate),
      buildId: _buildEntityId,
      insert: (candidate) => _database.chapterDao.insert(
        ChaptersCompanion.insert(
          id: candidate,
          type: nodeTypeVolume,
          parentId: const Value(null),
          siblingOrder: siblingOrder,
          title: Value(title),
          outline: Value(description ?? ''),
          content: const Value(''),
          wordCount: const Value(0),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      ),
    );
  }

  /// 重命名卷（仅更新 title，不动 content/wordCount）。
  /// 列表由 watchChapterTree stream 自动刷新。
  Future<void> renameVolume(String volumeId, String title) {
    return (_database.update(
      _database.chapters,
    )..where((table) => table.id.equals(volumeId))).write(
      ChaptersCompanion(title: Value(title), updatedAt: Value(DateTime.now())),
    );
  }

  Future<void> replaceChaptersForImport(List<ImportedChapterNode> chapters) {
    return _database.transaction(() async {
      try {
        await _database.delete(_database.chapters).go();
        final now = DateTime.now();
        var rootOrder = 1;
        final volumeIds = <String, String>{};
        final volumeChildOrders = <String, int>{};
        final reservedIds = <String>{};

        for (final chapter in chapters) {
          final volumeTitle = chapter.volumeTitle?.trim();
          String? parentId;
          var siblingOrder = rootOrder;
          if (volumeTitle != null && volumeTitle.isNotEmpty) {
            parentId = volumeIds[volumeTitle];
            if (parentId == null) {
              parentId = await insertWithShortEntityId(
                type: ShortEntityIdType.volume,
                tableName: 'chapter_nodes',
                idExists: (id) => _idExists('chapter_nodes', id),
                reservedIds: reservedIds,
                buildId: _buildEntityId,
                insert: (id) => _database.chapterDao.insert(
                  ChaptersCompanion.insert(
                    id: id,
                    type: nodeTypeVolume,
                    parentId: const Value(null),
                    siblingOrder: rootOrder,
                    title: Value(volumeTitle),
                    outline: const Value(''),
                    content: const Value(''),
                    wordCount: const Value(0),
                    createdAt: Value(now),
                    updatedAt: Value(now),
                  ),
                ),
              );
              volumeIds[volumeTitle] = parentId;
              volumeChildOrders[parentId] = 0;
              rootOrder += 1;
            }
            siblingOrder = (volumeChildOrders[parentId] ?? 0) + 1;
            volumeChildOrders[parentId] = siblingOrder;
          } else {
            rootOrder += 1;
          }

          final content = chapter.content.trimRight();
          await insertWithShortEntityId(
            type: ShortEntityIdType.chapter,
            tableName: 'chapter_nodes',
            idExists: (id) => _idExists('chapter_nodes', id),
            reservedIds: reservedIds,
            buildId: _buildEntityId,
            insert: (id) => _database.chapterDao.insert(
              ChaptersCompanion.insert(
                id: id,
                type: nodeTypeChapter,
                parentId: Value(parentId),
                siblingOrder: siblingOrder,
                title: Value(chapter.title.trim()),
                outline: const Value(''),
                content: Value(content),
                wordCount: Value(_countWords(content)),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            ),
          );
        }
        await _syncNovelWordCount();
      } catch (error, stackTrace) {
        _log.error(
          'REPLACE_IMPORT chapters error=$error',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    });
  }

  Future<void> moveToVolume(String chapterId, String volumeId) {
    return _database.chapterDao.moveToVolume(chapterId, volumeId);
  }

  Future<void> moveOutOfVolume(String chapterId) {
    return _database.chapterDao.moveOutOfVolume(chapterId);
  }

  /// 正文 ⇄ 番外互转；[type] 取 [nodeTypeChapter] 或 [nodeTypeExtra]。
  Future<void> updateChapterNodeType(String chapterId, String type) {
    return _database.chapterDao.updateNodeType(chapterId, type);
  }

  Future<int> getNextSiblingOrderAtRoot() =>
      _database.chapterDao.nextSiblingOrderAtRoot();

  Future<int> getNextSiblingOrderInVolume(String volumeId) =>
      _database.chapterDao.nextSiblingOrderInVolume(volumeId);

  Future<void> updateChapterContent({
    required String chapterId,
    required String title,
    required String outline,
    required String content,
    String? brief,
  }) async {
    final existing = await _database.chapterDao.getContentById(chapterId);
    if (existing == null) {
      throw Exception('Chapter not found: $chapterId');
    }
    await _writeChapterContent(
      existing: existing,
      title: title,
      outline: outline,
      content: content,
      brief: brief ?? existing.brief,
    );
  }

  /// 完整保存与部分保存共用已读取的原表基线，避免部分保存二次查库。
  Future<void> _writeChapterContent({
    required Chapter existing,
    required String title,
    required String outline,
    required String content,
    required String brief,
  }) async {
    // 不对 outline/content 做 trim：编辑器把落盘值当作回流基线，任何写入侧的
    // 归一化都会让「自己刚存的内容」在回流时被误判成外部改写并回灌，吃掉用户
    // 正在输入的段末空行。空白的展示与导出由各消费方自行 trim。
    final wordCount = _countWords(content);
    try {
      await (_database.update(
        _database.chapters,
      )..where((table) => table.id.equals(existing.id))).write(
        ChaptersCompanion(
          title: Value(title),
          outline: Value(outline),
          content: Value(content),
          brief: Value(brief),
          wordCount: Value(wordCount),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] chapter_nodes UPDATE failed, id=${existing.id}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    await _syncNovelWordCount();
  }

  Future<void> updateChapterContentPartial({
    required String chapterId,
    String? title,
    String? outline,
    String? content,
    String? brief,
  }) async {
    final existing = await _database.chapterDao.getContentById(chapterId);
    if (existing == null) {
      throw Exception('Chapter not found: $chapterId');
    }
    await _writeChapterContent(
      existing: existing,
      title: title ?? (existing.title ?? ''),
      outline: outline ?? existing.outline,
      content: content ?? existing.content,
      brief: brief ?? existing.brief,
    );
  }

  /// 批量排版专用写入：保留已有字数，不同步小说记录。
  Future<void> updateFormattedChapterContent({
    required String chapterId,
    required String content,
  }) async {
    try {
      final updated =
          await (_database.update(_database.chapters)..where(
                (table) =>
                    table.id.equals(chapterId) &
                    table.deletedAt.equals(notDeletedSentinel),
              ))
              .write(
                ChaptersCompanion(
                  content: Value(content),
                  updatedAt: Value(DateTime.now()),
                ),
              );
      if (updated == 0) {
        throw StateError('Chapter not found: $chapterId');
      }
    } catch (error, stackTrace) {
      _log.error(
        '[DB] chapter_nodes UPDATE formatting failed, id=$chapterId',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> deleteChapter(String chapterId) async {
    final existing = await getChapterById(chapterId);
    if (existing == null) {
      return;
    }
    try {
      await _database.transaction(() async {
        final chapterIdsToPurge = <String>[chapterId];
        if (existing.isVolume) {
          final childIds =
              await (_database.select(_database.chapters)
                    ..where((table) => table.parentId.equals(chapterId)))
                  .map((row) => row.id)
                  .get();
          chapterIdsToPurge.addAll(childIds);
        }
        for (final id in chapterIdsToPurge) {
          await entityRelationsService.deleteRelationsForEntity(
            entityType: entityTypeChapter,
            entityId: id,
          );
          await entityRelationsService.clearChapterReferences(id);
        }
        if (existing.isVolume) {
          await (_database.delete(
            _database.chapters,
          )..where((table) => table.parentId.equals(chapterId))).go();
        }
        await (_database.delete(
          _database.chapters,
        )..where((table) => table.id.equals(chapterId))).go();
        // 删除与顺序修复一起提交，订阅者只观察完整的新树。
        await _database.chapterDao.repairOrphanChapterParents();
        await _database.chapterDao.compactSiblingOrders(existing.parentId);
      });
      await _syncNovelWordCount();
    } catch (e, st) {
      _log.error(
        'DELETE chapter_nodes id=$chapterId type=${existing.type} error=$e',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  Future<void> moveSiblingToPosition(String nodeId, int newPosition) async {
    final node = await getChapterById(nodeId);
    if (node == null) return;
    final siblings = await _database.chapterDao.getSiblings(node.parentId);
    if (newPosition < 1 || newPosition > siblings.length) return;

    final reordered = siblings.where((s) => s.id != nodeId).toList();
    reordered.insert(newPosition - 1, node);

    await _database.transaction(() async {
      for (var i = 0; i < reordered.length; i++) {
        await _database.chapterDao.updateSiblingOrder(reordered[i].id, i + 1);
      }
    });
  }

  /// 更新 chronicler 的写后分析字段（紧张度 / 情绪标签 / 章内事件）。
  ///
  /// 直写 DB，不走 working change：这些是结构化分析结果，不是用户会逐字审阅的正文，
  /// 做成可回滚文本 diff 既无意义也读不懂（与 volume_id 同类直写）。
  /// 省略值表示本次不动；clearTension 显式清除紧张度评分。
  Future<void> updateChapterAnalysis({
    required String chapterId,
    int? tension,
    bool clearTension = false,
    List<String>? emotion,
    List<Map<String, dynamic>>? events,
  }) async {
    try {
      await (_database.update(
        _database.chapters,
      )..where((table) => table.id.equals(chapterId))).write(
        ChaptersCompanion(
          tension: clearTension
              ? const Value(null)
              : tension == null
              ? const Value.absent()
              : Value(tension),
          emotion: emotion == null ? const Value.absent() : Value(emotion),
          events: events == null ? const Value.absent() : Value(events),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=chapters operation=UPDATE id=$chapterId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 覆写一章的批注列表。
  ///
  /// 直写 DB，不走 working change：批注是作者写在正文之外的笔记，不是正文，
  /// 做成可回滚文本 diff 既无意义也读不懂（与 tension/emotion/events 同类直写）。
  /// 删除批注请传入带 `deletedAt` 的条目（软删除），不要从列表里剔除。
  Future<void> updateChapterComments({
    required String chapterId,
    required List<ChapterComment> comments,
  }) {
    return (_database.update(
      _database.chapters,
    )..where((table) => table.id.equals(chapterId))).write(
      ChaptersCompanion(
        comments: Value(comments),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> updateChapterStat({
    required String chapterId,
    required String stat,
  }) {
    return (_database.update(
      _database.chapters,
    )..where((table) => table.id.equals(chapterId))).write(
      ChaptersCompanion(stat: Value(stat), updatedAt: Value(DateTime.now())),
    );
  }

  Future<String> createCharacterProfile({
    String? defaultName,
    String? name,
    String role = characterRoleSupporting,
    String gender = characterGenderUnknown,
    List<String> aliases = const [],
    List<String> tags = const [],
    String identity = '',
    String age = '未知',
    String motivation = '',
    String arc = '',
    String biography = '',
    String appearance = '',
    String personality = '',
    String description = '',
    List<CharacterBehaviorTag> behaviorTags = const [],
    String currentState = '',
    String? firstAppearChapterId,
  }) async {
    final now = DateTime.now();
    final nextSortOrder = await _nextSortOrder(_database.characterProfiles);
    final resolvedName =
        name ??
        (defaultName == null
            ? 'New Character'
            : buildUniqueDisplayName(
                baseName: defaultName,
                existingNames: (await getCharacterProfiles()).map((character) {
                  return character.name;
                }),
              ));
    _assertAllowedStatus(role, characterRoles, fieldName: 'role');
    _assertAllowedStatus(gender, characterGenders, fieldName: 'gender');
    final normalizedAliases = _normalizeCharacterAliases(
      name: resolvedName,
      aliases: aliases,
    );
    final normalizedTags = _normalizeCharacterTags(tags);
    final normalizedBehaviorTags = _normalizeCharacterBehaviorTags(
      behaviorTags,
    );
    await _assertCharacterFirstAppearChapter(firstAppearChapterId);
    try {
      return await insertWithShortEntityId(
        type: ShortEntityIdType.character,
        tableName: 'character_profiles',
        idExists: (id) => _idExists('character_profiles', id),
        buildId: _buildEntityId,
        insert: (id) => _database
            .into(_database.characterProfiles)
            .insert(
              CharacterProfilesCompanion.insert(
                id: id,
                name: resolvedName,
                role: Value(role),
                gender: Value(gender),
                aliases: Value(normalizedAliases),
                tags: Value(normalizedTags),
                identity: Value(identity),
                age: Value(age),
                motivation: Value(motivation),
                arc: Value(arc),
                biography: Value(biography),
                appearance: Value(appearance),
                personality: Value(personality),
                description: Value(description),
                behaviorTags: Value(normalizedBehaviorTags),
                currentState: Value(currentState),
                firstAppearChapterId: Value(firstAppearChapterId),
                sortOrder: Value(nextSortOrder),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=character_profiles operation=INSERT error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> updateCharacterProfile({
    required String entryId,
    required String name,
    required String role,
    required String gender,
    required String biography,
    required String description,
    String? appearance,
    List<String>? aliases,
    List<String>? tags,
    String? identity,
    String? age,
    String? motivation,
    String? arc,
    String? personality,
    List<CharacterBehaviorTag>? behaviorTags,
    String? currentState,
    String? avatarAssetId,
    List<SubjectPhoto>? photos,
  }) async {
    _assertAllowedStatus(role, characterRoles, fieldName: 'role');
    _assertAllowedStatus(gender, characterGenders, fieldName: 'gender');
    final normalizedAliases = aliases == null
        ? null
        : _normalizeCharacterAliases(name: name, aliases: aliases);
    final normalizedTags = tags == null ? null : _normalizeCharacterTags(tags);
    final normalizedBehaviorTags = behaviorTags == null
        ? null
        : _normalizeCharacterBehaviorTags(behaviorTags);
    try {
      await (_database.update(
        _database.characterProfiles,
      )..where((table) => table.id.equals(entryId))).write(
        CharacterProfilesCompanion(
          name: Value(name),
          role: Value(role.trimRight()),
          gender: Value(gender),
          aliases: normalizedAliases == null
              ? const Value.absent()
              : Value(normalizedAliases),
          tags: normalizedTags == null
              ? const Value.absent()
              : Value(normalizedTags),
          biography: Value(biography.trimRight()),
          appearance: appearance == null
              ? const Value.absent()
              : Value(appearance.trimRight()),
          description: Value(description.trimRight()),
          currentState: currentState == null
              ? const Value.absent()
              : Value(currentState.trimRight()),
          identity: identity == null ? const Value.absent() : Value(identity),
          age: age == null ? const Value.absent() : Value(age),
          motivation: motivation == null
              ? const Value.absent()
              : Value(motivation),
          arc: arc == null ? const Value.absent() : Value(arc),
          personality: personality == null
              ? const Value.absent()
              : Value(personality),
          behaviorTags: normalizedBehaviorTags == null
              ? const Value.absent()
              : Value(normalizedBehaviorTags),
          // 空字符串表示清除头像。
          avatarAssetId: avatarAssetId == null
              ? const Value.absent()
              : Value(avatarAssetId.isEmpty ? null : avatarAssetId),
          photos: photos == null ? const Value.absent() : Value(photos),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=character_profiles operation=UPDATE id=$entryId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 更新仅用于列表筛选与分组的角色标签，不创建可回滚的正文变更。
  Future<void> updateCharacterTags({
    required String entryId,
    required List<String> tags,
  }) async {
    final normalizedTags = _normalizeCharacterTags(tags);
    try {
      await (_database.update(
        _database.characterProfiles,
      )..where((table) => table.id.equals(entryId))).write(
        CharacterProfilesCompanion(
          tags: Value(normalizedTags),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=character_profiles operation=UPDATE_TAGS id=$entryId '
        'error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> updateCharacterFirstAppearChapter({
    required String characterId,
    String? firstAppearChapterId,
  }) async {
    await _assertCharacterFirstAppearChapter(firstAppearChapterId);
    try {
      await (_database.update(
        _database.characterProfiles,
      )..where((table) => table.id.equals(characterId))).write(
        CharacterProfilesCompanion(
          firstAppearChapterId: Value(firstAppearChapterId),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=character_profiles operation=UPDATE_FIRST_APPEAR '
        'id=$characterId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<List<SubjectPhoto>> renameCharacterPhoto({
    required String id,
    required String assetId,
    required String name,
  }) async {
    try {
      return await _database.transaction(() async {
        final entry = await _database.characterProfileDao.getById(id);
        final photos = entry?.photos ?? const <SubjectPhoto>[];
        bool matches(SubjectPhoto photo) => photo.assetId == assetId;
        if (!photos.any(matches)) {
          throw StateError('Photo no longer exists');
        }
        final next = photos
            .map(
              (photo) =>
                  matches(photo) ? photo.copyWith(name: name.trim()) : photo,
            )
            .toList();
        await updateCharacterAvatarAndPhotos(entryId: id, photos: next);
        return next;
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=character_profiles operation=RENAME_PHOTO id=$id',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> addCharacterPhotos(String id, List<String> assetIds) async {
    try {
      await _database.transaction(() async {
        final character = await getCharacterProfileById(id);
        if (character == null) {
          throw StateError('Character no longer exists');
        }
        final photos = character.photos ?? const <SubjectPhoto>[];
        final existing = photos.map((photo) => photo.assetId).toSet();
        final added = [
          for (final assetId in assetIds)
            if (existing.add(assetId)) SubjectPhoto(assetId: assetId),
        ];
        if (added.isEmpty) {
          return;
        }
        await updateCharacterAvatarAndPhotos(
          entryId: id,
          photos: [...photos, ...added],
        );
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=character_profiles operation=ADD_PHOTOS id=$id',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> updateCharacterAvatarAndPhotos({
    required String entryId,
    String? avatarAssetId,
    List<SubjectPhoto>? photos,
  }) async {
    try {
      await (_database.update(
        _database.characterProfiles,
      )..where((table) => table.id.equals(entryId))).write(
        CharacterProfilesCompanion(
          // 空字符串表示清除头像。
          avatarAssetId: avatarAssetId == null
              ? const Value.absent()
              : Value(avatarAssetId.isEmpty ? null : avatarAssetId),
          photos: photos == null ? const Value.absent() : Value(photos),
          updatedAt: Value(DateTime.now()),
        ),
      );
    } catch (e, s) {
      _log.error('DB write FAILED: $e', error: e, stackTrace: s);
      rethrow;
    }
  }

  /// 图片资产的相对路径；资产缺失或未注入图片库时为 null。
  Future<String?> imagePath(String? assetId) async =>
      assetId == null ? null : imageLibraryService?.assetPath(assetId);

  /// 将图片导入统一图片库，返回资产 id。
  Future<String> saveCharacterImage({
    required String sourcePath,
    required String kind,
  }) async {
    final library = imageLibraryService;
    if (library == null) {
      throw StateError('Character images require the image library.');
    }
    final asset = await library.importFile(
      sourcePath,
      novelId: await requireNovelId(),
      purpose: kind == 'avatar' ? AssetPurpose.avatar : AssetPurpose.photo,
    );
    return asset.id;
  }

  /// 本内容库所属作品的 id；图片入库按作品隔离，找不到作品时不能入库。
  Future<String> requireNovelId() async {
    final actions = novelActionsService;
    if (actions == null) {
      throw StateError('Resolving the work requires novel actions.');
    }
    final novel = await actions.getNovelByContentDatabasePath(
      _database.filePath,
    );
    if (novel == null) {
      throw StateError('Content database has no work: ${_database.filePath}');
    }
    return novel.id;
  }

  Future<List<ScreenplaySceneReference>> getCharacterScreenplayScenes(
    String entryId,
  ) => _database.screenplayDao.getCharacterSceneReferences(entryId);

  Future<void> deleteCharacterProfile(
    String entryId, {
    bool restoreHistory = false,
  }) async {
    await deleteEntityWithRelations(
      entityType: entityTypeCharacter,
      entityId: entryId,
      validateBeforeDelete: () async {
        await requireUnusedProductionSubject(_database, characterId: entryId);
        if (restoreHistory) {
          return;
        }
        final scenes = await getCharacterScreenplayScenes(entryId);
        if (scenes.isNotEmpty) {
          throw ScreenplayServiceException(
            'entity_in_use',
            'Character is still referenced by screenplay scenes.',
            details: [
              for (final scene in scenes)
                for (final source in scene.sources)
                  <String, String>{'scene_id': scene.sceneId, 'source': source},
            ],
          );
        }
      },
      deleteEntityRow: () async {
        await (_database.delete(
          _database.characterProfiles,
        )..where((table) => table.id.equals(entryId))).go();
      },
    );
  }

  Future<String> createForeshadowing({
    String? defaultTitle,
    String? title,
    String setup = '',
    String payoff = '',
    String status = foreshadowingStatusPlanted,
    String? setupChapterId,
    String? payoffChapterId,
    String? setupSceneId,
    String? payoffSceneId,
  }) async {
    final now = DateTime.now();
    final nextSortOrder = await _nextSortOrder(_database.foreshadowings);
    final resolvedTitle =
        title ??
        (defaultTitle == null
            ? ''
            : buildUniqueDisplayName(
                baseName: defaultTitle,
                existingNames: (await getForeshadowings()).map((foreshadowing) {
                  return foreshadowing.title;
                }),
              ));
    _assertAllowedStatus(status, foreshadowingStatuses, fieldName: 'status');
    try {
      return await _database.transaction(() async {
        await _validateForeshadowingPositions({
          'setup_chapter_id': setupChapterId,
          'payoff_chapter_id': payoffChapterId,
          'setup_scene_id': setupSceneId,
          'payoff_scene_id': payoffSceneId,
        });
        return insertWithShortEntityId(
          type: ShortEntityIdType.foreshadowing,
          tableName: 'foreshadowings',
          idExists: (id) => _idExists('foreshadowings', id),
          buildId: _buildEntityId,
          insert: (id) => _database
              .into(_database.foreshadowings)
              .insert(
                ForeshadowingsCompanion.insert(
                  id: id,
                  title: resolvedTitle,
                  setup: Value(setup),
                  payoff: Value(payoff),
                  status: Value(status),
                  setupChapterId: Value(setupChapterId),
                  payoffChapterId: Value(payoffChapterId),
                  setupSceneId: Value(setupSceneId),
                  payoffSceneId: Value(payoffSceneId),
                  sortOrder: Value(nextSortOrder),
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
              ),
        );
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] Foreshadowings INSERT failed error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> updateForeshadowing({
    required String entryId,
    required String title,
    required String setup,
    required String payoff,
    required String status,
  }) {
    _assertAllowedStatus(status, foreshadowingStatuses, fieldName: 'status');
    return (_database.update(
      _database.foreshadowings,
    )..where((table) => table.id.equals(entryId))).write(
      ForeshadowingsCompanion(
        title: Value(title),
        setup: Value(setup.trimRight()),
        payoff: Value(payoff.trimRight()),
        status: Value(status),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> updateForeshadowingPositions({
    required String entryId,
    required Map<String, String?> fields,
  }) async {
    try {
      await _database.transaction(() async {
        final current = await getForeshadowingById(entryId);
        if (current == null) {
          throw const FormatException('Foreshadowing was not found.');
        }
        final positions = <String, String?>{
          'setup_chapter_id': current.setupChapterId,
          'payoff_chapter_id': current.payoffChapterId,
          'setup_scene_id': current.setupSceneId,
          'payoff_scene_id': current.payoffSceneId,
        };
        if (fields.keys.any((key) => !positions.containsKey(key))) {
          throw const FormatException('Unknown foreshadowing position field.');
        }
        final changed = {
          for (final entry in fields.entries)
            if (entry.value != positions[entry.key]) entry.key,
        };
        positions.addAll(fields);
        await _validateForeshadowingPositions(positions, changed: changed);
        await (_database.update(
          _database.foreshadowings,
        )..where((row) => row.id.equals(entryId))).write(
          ForeshadowingsCompanion(
            setupChapterId: Value(positions['setup_chapter_id']),
            payoffChapterId: Value(positions['payoff_chapter_id']),
            setupSceneId: Value(positions['setup_scene_id']),
            payoffSceneId: Value(positions['payoff_scene_id']),
            updatedAt: Value(DateTime.now()),
          ),
        );
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=foreshadowings operation=UPDATE id=$entryId',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> _validateForeshadowingPositions(
    Map<String, String?> positions, {
    Set<String>? changed,
  }) async {
    final screenplay = await _database.screenplayDao.getRoot();
    for (final position in ['setup', 'payoff']) {
      final chapter = positions['${position}_chapter_id'];
      final scene = positions['${position}_scene_id'];
      if (chapter != null && scene != null) {
        throw const FormatException(
          'A position can reference either a chapter or a scene.',
        );
      }
      if ((screenplay != null && chapter != null) ||
          (screenplay == null && scene != null)) {
        throw const FormatException(
          'Position reference does not match the work type.',
        );
      }
      if (chapter != null &&
          (changed == null || changed.contains('${position}_chapter_id'))) {
        final target = await _database.chapterDao.getById(chapter);
        if (target == null || target.type == nodeTypeVolume) {
          throw const FormatException(
            'Position chapter was not found or is a volume.',
          );
        }
      }
      if (scene != null &&
          (changed == null || changed.contains('${position}_scene_id'))) {
        final target = await _database.screenplayDao.getScene(scene);
        if (target == null || target.screenplayId != screenplay!.id) {
          throw const FormatException('Position scene was not found.');
        }
      }
    }
  }

  Future<void> deleteForeshadowing(String entryId) async {
    await deleteEntityWithRelations(
      entityType: entityTypeForeshadowing,
      entityId: entryId,
      deleteEntityRow: () async {
        await (_database.delete(
          _database.foreshadowings,
        )..where((table) => table.id.equals(entryId))).go();
      },
    );
  }

  Future<NovelState?> getNovelState(String key) {
    return _database.novelStateDao.get(key);
  }

  Future<void> upsertNovelState({required String key, required String status}) {
    return _database.novelStateDao.upsert(key: key, status: status);
  }

  /// 当前故事状态快照，没有时返回 null。
  Future<NovelStateSnapshot?> getCurrentStateSnapshot() {
    return _database.novelStateSnapshotDao.getLatestActive();
  }

  Stream<NovelStateSnapshot?> watchCurrentStateSnapshot() {
    return _database.novelStateSnapshotDao.watchLatestActive();
  }

  /// 写入当前故事状态并保留上一版本；覆盖范围由正文表达。
  Future<void> writeCurrentStateSnapshot({
    required String content,
    String createdBy = novelStateSnapshotCreatedByChronicler,
  }) async {
    await _database.novelStateSnapshotDao.createSnapshot(
      content: content,
      createdBy: createdBy,
    );
  }

  void _assertAllowedStatus(
    String value,
    List<String> allowedValues, {
    required String fieldName,
  }) {
    if (!allowedValues.contains(value)) {
      throw ArgumentError.value(
        value,
        fieldName,
        'Allowed values: ${allowedValues.join(', ')}',
      );
    }
  }

  int _countWords(String content) {
    return countTextUnits(content);
  }

  Future<void> _syncNovelWordCount() async {
    final actions = novelActionsService;
    if (actions == null) {
      return;
    }
    final novel = await actions.getNovelByContentDatabasePath(
      _database.filePath,
    );
    if (novel == null) {
      return;
    }
    final stats = await _database.chapterDao.getListStats();
    await actions.updateNovelWordCount(
      novelId: novel.id,
      wordCount: stats.totalWordCount,
    );
  }

  Future<int> _nextSortOrder<T extends Table, D>(TableInfo<T, D> table) async {
    final row = await _database
        .customSelect(
          'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM ${table.actualTableName}',
        )
        .getSingle();
    return row.read<int>('max_order') + 1;
  }

  Future<List<AgentRule>> getAgentRules() => _database.agentRuleDao.getAll();

  Stream<List<AgentRule>> watchAgentRules() =>
      _database.agentRuleDao.watchAll();

  Future<void> upsertAgentRule(AgentRule rule) =>
      _database.agentRuleDao.upsert(rule);

  Future<void> deleteAgentRule(String id) async {
    try {
      await _database.agentRuleDao.hardDelete(id);
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=agent_rules operation=DELETE id=$id error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> reorderAgentRules(List<String> ids) =>
      _database.agentRuleDao.reorder(ids);
}

Future<String> buildNovelContentDatabasePath(String novelId) async {
  final appSupportDir = await getApplicationSupportDirectory();
  final novelsDir = Directory(p.join(appSupportDir.path, 'novel_workspaces'));
  if (!await novelsDir.exists()) {
    await novelsDir.create(recursive: true);
  }
  // 存相对路径（相对 Application Support 根），避免沙盒容器变化（重装 / 备份恢复 /
  // 换机）后绝对路径失效；打开时由 NovelContentDatabase 工厂 resolve 为绝对并做
  // Windows 8.3 短路径归一化。
  return p.join('novel_workspaces', '$novelId.sqlite');
}
