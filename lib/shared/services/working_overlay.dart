// 职责: 可回滚变更 patch 与 commit 流程，负责真实写入后的接受、回滚与提交记录。
// 关联文件:
//   lib/shared/services/novel_content.dart
//   lib/shared/services/documents_service.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/screenplay_service.dart
//   lib/shared/services/rollback_repair_orchestrator.dart
//   lib/shared/models/screenplay_element_render.dart
import 'dart:convert';

import 'package:drift/drift.dart';

import '../database/novel_content_database.dart';
import '../database/type_converters.dart';
import '../models/outline.dart';
import '../models/screenplay_element.dart';
import '../models/screenplay_element_render.dart';
import '../utils/line_accept.dart';
import 'working_change_summary.dart';
import 'rollback_repair_orchestrator.dart';
import '../utils/random_id.dart';
import '../utils/resource_path.dart';
import 'novel_actions.dart';
import 'novel_content.dart';
import 'screenplay_service.dart';
import 'storyboard/service.dart';
import '../logger/app_logger.dart';

final _log = AppLogger.forModule('WorkingOverlay');

List<String> _decodeCharacterAliases(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! List || decoded.any((item) => item is! String)) {
    throw const FormatException('aliases patch must contain a string array.');
  }
  return decoded.cast<String>();
}

List<CharacterBehaviorTag> _decodeCharacterBehaviorTags(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! List) {
    throw const FormatException(
      'behavior_tags patch must contain an object array.',
    );
  }
  return decoded
      .map((item) {
        if (item is! Map) {
          throw const FormatException(
            'behavior_tags patch must contain an object array.',
          );
        }
        return CharacterBehaviorTag.fromJson(Map<String, dynamic>.from(item));
      })
      .toList(growable: false);
}

List<ScreenplayElement> _decodeScreenplayElements(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! List) {
    throw const FormatException(
      'screenplay elements patch must contain an array.',
    );
  }
  return decoded
      .map((raw) {
        if (raw is! Map) {
          throw const FormatException('screenplay element must be an object.');
        }
        final item = Map<String, dynamic>.from(raw);
        final type = screenplayElementTypeFromName(
          item['type']?.toString() ?? '',
        );
        final element = ScreenplayElement(
          id: item['id']?.toString(),
          type: type,
          text: item['text']?.toString() ?? '',
          characterId: item['character_id']?.toString(),
          extension: item['extension']?.toString() ?? '',
        );
        element.validateShape();
        return element;
      })
      .toList(growable: false);
}

const String workingChangeSourceAi = 'ai';
const String workingChangeSourceManual = 'manual_edit';

const String workingChangeStatusActive = 'active';
const String workingChangeStatusRejected = 'rejected';
const String workingChangeStatusCommitted = 'committed';
const String workingChangeStatusConflicted = 'conflicted';

// working_changes.resource_type 是自由文本列，没有枚举兜底：写错一个字不会报错，
// 只会静默落到 _applyTextPatch / _readCommittedFieldText 的 default 分支
// （分别抛 StateError 和静默 skipped）。剧本这两种统一从这里取。
const String workingChangeResourceTypeScreenplayScenes = 'screenplay_scenes';
const String workingChangeResourceTypeScreenplayEpisodes =
    'screenplay_episodes';

const String historyCommitMessageRestoreToHistoricalVersion =
    'history.commit_message.restore_to_historical_version';
const String historyCommitMessageRollbackSelectedCommit =
    'history.commit_message.rollback_selected_commit';

enum RestoreResourceResult {
  restored,
  partiallyRestored,
  skipped,
  alreadyAtVersion,
  commitNotFound,
  failed,
}

class WorkingTextChangeRequest {
  const WorkingTextChangeRequest({
    required this.resourcePath,
    required this.resourceType,
    required this.resourceId,
    required this.field,
    required this.oldText,
    required this.newText,
    required this.summary,
    this.expectedCurrentText,
  });

  final String resourcePath;
  final String resourceType;
  final String? resourceId;
  final String? field;
  final String? oldText;
  final String newText;
  final String summary;
  final String? expectedCurrentText;
}

/// 写入 working patch 前发现资源内容已偏离调用方快照。
///
/// 调用方应重新读取资源并让用户审阅，不能继续覆盖较新的内容。
class WorkingOverlayConflictException implements Exception {
  const WorkingOverlayConflictException({
    required this.resourcePath,
    required this.resourceId,
  });

  final String resourcePath;
  final String? resourceId;

  @override
  String toString() => 'WorkingOverlayConflictException($resourcePath)';
}

class TurnRollbackResult {
  final int rolledBack;
  final int skipped;
  final List<String> skippedPaths;

  const TurnRollbackResult({
    required this.rolledBack,
    required this.skipped,
    this.skippedPaths = const [],
  });
}

/// 用户主动恢复历史目标的结果；缺失目标和不适用状态返回 skipped。
enum RollbackChangeResult { rolledBack, skipped, noop }

class WorkingOverlayService {
  WorkingOverlayService(
    this._contentDatabase,
    this._contentService, {
    required this._novelActionsService,
  });

  final NovelContentDatabase _contentDatabase;
  final NovelContentService _contentService;
  final NovelActionsService _novelActionsService;

  StoryboardService get _storyboardService => StoryboardService(
    _contentDatabase,
    resolveContentKind: () async {
      final novel = await _novelActionsService.getNovelByContentDatabasePath(
        _contentDatabase.filePath,
      );
      if (novel == null) {
        throw StateError('Production work registration is unavailable');
      }
      return novel.contentKind;
    },
  );

  Stream<List<WorkingChange>> watchWorkingChanges() {
    return _contentDatabase.workingChangeDao.watchAll();
  }

  Stream<List<WorkingChange>> watchSessionChanges(String? sessionId) {
    return _contentDatabase.workingChangeDao.watchSessionChanges(sessionId);
  }

  Future<List<WorkingChange>> getWorkingChanges() {
    return _contentDatabase.workingChangeDao.getAll();
  }

  Future<List<WorkingChange>> getWorkingChangesForResource(
    String resourcePath,
  ) {
    return _contentDatabase.workingChangeDao.getByResource(resourcePath);
  }

  Future<WorkingChange?> getWorkingChangeById(String id) {
    return _contentDatabase.workingChangeDao.getById(id);
  }

  Stream<List<ChangeCommit>> watchChangeCommits({int? limit}) {
    return _contentDatabase.changeCommitDao.watchAll(limit: limit);
  }

  Future<List<ChangeCommit>> getChangeCommits({int? limit}) {
    return _contentDatabase.changeCommitDao.getAll(limit: limit);
  }

  Future<List<ChangeCommitItem>> getChangeCommitItemsForCommit(
    String commitId,
  ) {
    return _contentDatabase.changeCommitDao.getItemsByCommit(commitId);
  }

  Future<List<ChangeCommitItem>> getChangeCommitItemsForCommitAndResourceId(
    String commitId,
    String resourceId,
  ) {
    return _contentDatabase.changeCommitDao.getItemsByCommitAndResourceId(
      commitId,
      resourceId,
    );
  }

  Future<List<ChangeCommitItem>> getChangeCommitItemsForResource(
    String resourcePath, {
    int? limit,
  }) {
    return _contentDatabase.changeCommitDao.getItemsByResource(
      resourcePath,
      limit: limit,
    );
  }

  Future<List<ChangeCommitItem>> getChangeCommitItemsForResourceId(
    String resourceId, {
    int? limit,
  }) {
    return _contentDatabase.changeCommitDao.getItemsByResourceId(
      resourceId,
      limit: limit,
    );
  }

  Future<String?> readWorkingText({
    required String resourcePath,
    required Future<String?> Function() committedReader,
  }) async {
    // Patches are applied on stage; committed data is the source of truth.
    return committedReader();
  }

  Future<T> _writeWorkingChanges<T>(
    String operation,
    Future<T> Function() action,
  ) async {
    try {
      return await _contentDatabase.transaction(action);
    } catch (error, stackTrace) {
      _log.error(
        '[DB] INSERT/UPDATE working_changes $operation error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<WorkingChange> stageTextChange({
    required String resourcePath,
    required String resourceType,
    required String? resourceId,
    required String? field,
    required String? oldText,
    required String newText,
    required String source,
    String? sourceSessionId,
    String? sourceTurnId,
    String? toolName,
    String? summary,
    String? expectedCurrentText,
    bool restoreHistory = false,
  }) => _writeWorkingChanges(
    'stage resource=$resourcePath session=$sourceSessionId turn=$sourceTurnId',
    () => _stageTextChangeInTransaction(
      resourcePath: resourcePath,
      resourceType: resourceType,
      resourceId: resourceId,
      field: field,
      oldText: oldText,
      newText: newText,
      source: source,
      sourceSessionId: sourceSessionId,
      sourceTurnId: sourceTurnId,
      toolName: toolName,
      summary: summary,
      expectedCurrentText: expectedCurrentText,
      restoreHistory: restoreHistory,
    ),
  );

  Future<WorkingChange> _stageTextChangeInTransaction({
    required String resourcePath,
    required String resourceType,
    required String? resourceId,
    required String? field,
    required String? oldText,
    required String newText,
    required String source,
    String? sourceSessionId,
    String? sourceTurnId,
    String? toolName,
    String? summary,
    String? expectedCurrentText,
    bool restoreHistory = false,
    bool allowCoalescing = true,
  }) async {
    if (restoreHistory && resourceId != null && field != null) {
      newText = await RollbackRepairOrchestrator().prepare(
        database: _contentDatabase,
        resourceType: resourceType,
        id: resourceId,
        field: field,
        value: newText,
      );
    }
    resourcePath = canonicalResourcePath(resourcePath);
    final now = DateTime.now();
    final prior = !allowCoalescing
        ? null
        : await _getActiveWorkingChange(
            resourcePath,
            source: source,
            sourceSessionId: sourceSessionId,
            sourceTurnId: sourceTurnId,
          );
    if (prior != null) {
      final nextPatch = prior.copyWith(
        oldText: Value(prior.oldText),
        newText: Value(newText),
        sourceSessionId: sourceSessionId == null
            ? const Value.absent()
            : Value(prior.sourceSessionId ?? sourceSessionId),
        sourceTurnId: sourceTurnId == null
            ? const Value.absent()
            : Value(prior.sourceTurnId ?? sourceTurnId),
        toolName: Value(toolName ?? prior.toolName),
        summary: summary ?? prior.summary,
        updatedAt: now,
      );
      try {
        await _contentDatabase.transaction(() async {
          if (!restoreHistory) {
            await _assertScreenplaySessionAvailable(
              nextPatch,
              sourceSessionId: sourceSessionId,
            );
            await _verifyExpectedCurrentText(
              nextPatch,
              expectedCurrentText: expectedCurrentText,
            );
          }
          await (_contentDatabase.update(
            _contentDatabase.workingChanges,
          )..where((table) => table.id.equals(prior.id))).write(
            WorkingChangesCompanion(
              oldText: Value(prior.oldText),
              newText: Value(newText),
              sourceSessionId: sourceSessionId == null
                  ? const Value.absent()
                  : Value(prior.sourceSessionId ?? sourceSessionId),
              sourceTurnId: sourceTurnId == null
                  ? const Value.absent()
                  : Value(prior.sourceTurnId ?? sourceTurnId),
              toolName: Value(toolName ?? prior.toolName),
              summary: Value(summary ?? prior.summary),
              updatedAt: Value(now),
            ),
          );
          final applied = await _applyTextPatch(
            nextPatch,
            newText,
            restoreHistory: restoreHistory,
          );
          if (!applied) {
            throw StateError('Failed to apply working patch: $resourcePath');
          }
        });
      } catch (error, stackTrace) {
        _log.error(
          'UPDATE working_changes id=${prior.id} error=$error',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
      final updated = await _contentDatabase.workingChangeDao.getById(prior.id);
      if (updated == null) {
        throw StateError('Updated working change not found: ${prior.id}');
      }
      return updated;
    }

    final patchId = buildRandomId('work');
    final patch = WorkingChange(
      id: patchId,
      resourcePath: resourcePath,
      resourceType: resourceType,
      resourceId: resourceId,
      field: field,
      changeType: 'write',
      source: source,
      sourceSessionId: sourceSessionId,
      sourceTurnId: sourceTurnId,
      toolName: toolName,
      summary: summary ?? '',
      oldText: oldText,
      newText: newText,
      baseVersion: 0,
      status: workingChangeStatusActive,
      createdAt: now,
      updatedAt: now,
    );
    await _contentDatabase.transaction(() async {
      if (!restoreHistory) {
        await _assertScreenplaySessionAvailable(
          patch,
          sourceSessionId: sourceSessionId,
        );
        await _verifyExpectedCurrentText(
          patch,
          expectedCurrentText: expectedCurrentText,
        );
      }
      await _contentDatabase
          .into(_contentDatabase.workingChanges)
          .insert(
            WorkingChangesCompanion.insert(
              id: patchId,
              resourcePath: resourcePath,
              resourceType: resourceType,
              resourceId: Value(resourceId),
              field: Value(field),
              changeType: 'write',
              source: source,
              sourceSessionId: Value(sourceSessionId),
              sourceTurnId: Value(sourceTurnId),
              toolName: Value(toolName),
              summary: Value(summary ?? ''),
              oldText: Value(oldText),
              newText: Value(newText),
              baseVersion: const Value(0),
              status: const Value(workingChangeStatusActive),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      final applied = await _applyTextPatch(
        patch,
        newText,
        restoreHistory: restoreHistory,
      );
      if (!applied) {
        throw StateError('Failed to apply working patch: $resourcePath');
      }
    });

    final active = await _contentDatabase.workingChangeDao.getById(patchId);
    if (active == null) {
      throw StateError('Active working change not found: $resourcePath');
    }
    return active;
  }

  Future<List<WorkingChange>> stageTextChangesAtomically({
    required List<WorkingTextChangeRequest> changes,
    required String source,
    String? sourceSessionId,
    String? sourceTurnId,
    String? toolName,
  }) async {
    if (changes.isEmpty) {
      return const [];
    }
    try {
      return await _contentDatabase.transaction(() async {
        final staged = <WorkingChange>[];
        for (final change in changes) {
          staged.add(
            await stageTextChange(
              resourcePath: change.resourcePath,
              resourceType: change.resourceType,
              resourceId: change.resourceId,
              field: change.field,
              oldText: change.oldText,
              newText: change.newText,
              source: source,
              sourceSessionId: sourceSessionId,
              sourceTurnId: sourceTurnId,
              toolName: toolName,
              summary: change.summary,
              expectedCurrentText: change.expectedCurrentText,
            ),
          );
        }
        return staged;
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=working_changes operation=BATCH_STAGE '
        'resourcePaths=${changes.map((change) => change.resourcePath).join(',')} '
        'error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> _verifyExpectedCurrentText(
    WorkingChange patch, {
    required String? expectedCurrentText,
  }) async {
    if (expectedCurrentText == null) {
      return;
    }
    final id = patch.resourceId;
    String? currentText;
    if (patch.resourceType == 'chapters' &&
        patch.field == 'content' &&
        id != null) {
      currentText = (await _contentService.getChapterById(id))?.content;
    } else if (patch.resourceType ==
            workingChangeResourceTypeScreenplayScenes &&
        id != null) {
      final scene = await _contentDatabase.screenplayDao.getScene(id);
      currentText = switch (patch.field) {
        'synopsis' => scene?.synopsis,
        'title' => scene?.title,
        'emotion' => jsonEncode(scene?.emotion),
        'events' => jsonEncode(scene?.events),
        'interior_exterior' => jsonEncode(scene?.interiorExterior),
        'elements' => serializeScreenplayElements(
          (await _contentDatabase.screenplayDao.getElementRows(id)).map(
            (row) => ScreenplayElement(
              id: row.id,
              type: screenplayElementTypeFromName(row.type),
              text: row.textContent,
              characterId: row.characterId,
              extension: row.extension,
            ),
          ),
        ),
        _ => null,
      };
    } else if (patch.resourceType ==
            workingChangeResourceTypeScreenplayEpisodes &&
        id != null) {
      final episode = await _contentDatabase.screenplayDao.getEpisode(id);
      currentText = switch (patch.field) {
        'outline' => episode?.outline,
        _ => null,
      };
    } else if (patch.resourceType == 'screenplays' &&
        patch.field == 'style_id' &&
        id != null) {
      final root = await _contentDatabase.screenplayDao.getRoot();
      currentText = root?.id == id ? jsonEncode(root?.styleId) : null;
    } else {
      throw ArgumentError(
        'expectedCurrentText does not support this resource field',
      );
    }
    if (currentText != expectedCurrentText) {
      throw WorkingOverlayConflictException(
        resourcePath: patch.resourcePath,
        resourceId: id,
      );
    }
  }

  Future<WorkingChange> stageCreateChange({
    required String resourcePath,
    required String resourceType,
    required String resourceId,
    required String previewText,
    required String source,
    String? sourceSessionId,
    String? sourceTurnId,
    String? toolName,
    String? summary,
  }) async {
    resourcePath = canonicalResourcePath(resourcePath);
    final now = DateTime.now();
    await _contentDatabase
        .into(_contentDatabase.workingChanges)
        .insert(
          WorkingChangesCompanion.insert(
            id: buildRandomId('work'),
            resourcePath: resourcePath,
            resourceType: resourceType,
            resourceId: Value(resourceId),
            field: const Value(null),
            changeType: 'create',
            source: source,
            sourceSessionId: Value(sourceSessionId),
            sourceTurnId: Value(sourceTurnId),
            toolName: Value(toolName),
            summary: Value(summary ?? ''),
            oldText: const Value(null),
            newText: Value(previewText),
            baseVersion: const Value(0),
            status: const Value(workingChangeStatusActive),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    final active = (await _contentDatabase.workingChangeDao.getByResource(
      resourcePath,
    )).firstWhere((change) => change.status == workingChangeStatusActive);
    if (resourceType == 'production_clips') {
      await _novelActionsService.markContentEdited(_contentDatabase.filePath);
    }
    return active;
  }

  Future<RollbackChangeResult> rejectWorkingChange(String changeId) =>
      _writeWorkingChanges('reject id=$changeId', () async {
        final row = await getWorkingChangeById(changeId);
        if (row == null) {
          return RollbackChangeResult.skipped;
        }
        if (row.status != workingChangeStatusActive &&
            row.status != workingChangeStatusConflicted) {
          return RollbackChangeResult.noop;
        }
        return _rollbackChangeInTransaction(changeId);
      });

  Future<String?> commitWorkingChanges(
    List<String> changeIds, {
    required String source,
    required String message,
  }) async {
    return _commitWorkingChanges(
      changeIds,
      source: source,
      message: message,
      allowAmend: false,
    );
  }

  /// 实时读取并提交指定会话仍处于 active 状态的 AI 变更。
  Future<String?> commitActiveAiChangesForSession(
    String sessionId, {
    required String message,
  }) async {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) {
      return null;
    }
    final changeIds = (await getWorkingChanges())
        .where(
          (change) =>
              change.status == workingChangeStatusActive &&
              change.source == workingChangeSourceAi &&
              change.sourceSessionId == normalizedSessionId,
        )
        .map((change) => change.id)
        .toList();
    return commitWorkingChanges(
      changeIds,
      source: workingChangeSourceAi,
      message: message,
    );
  }

  /// 自动保存专用：如果最后一个 commit 同 source+同 message+1 小时内，则追加 items 到已有 commit。
  Future<String?> autoSaveCommit(
    List<String> changeIds, {
    required String source,
    required String message,
  }) async {
    return _commitWorkingChanges(
      changeIds,
      source: source,
      message: message,
      allowAmend: true,
    );
  }

  /// 人工剧本文档保存接管实际修改场次的 AI 提议；可参加调用方的内容库事务。
  /// 不制造人工 change，也不改变小说 commitManualSave 的空 ID 语义。
  Future<String?> takeOverScreenplayScenes(Set<String> sceneIds) async {
    if (sceneIds.isEmpty) {
      return null;
    }
    try {
      return await _contentDatabase.transaction(() async {
        final changes =
            await (_contentDatabase.select(_contentDatabase.workingChanges)
                  ..where(
                    (table) =>
                        table.status.equals(workingChangeStatusActive) &
                        table.source.equals(workingChangeSourceAi) &
                        table.resourceType.equals(
                          workingChangeResourceTypeScreenplayScenes,
                        ) &
                        table.resourceId.isIn(sceneIds) &
                        (table.changeType.equals('create') |
                            table.field.isIn([
                              'elements',
                              'synopsis',
                              'title',
                              'emotion',
                              'events',
                              'interior_exterior',
                            ])),
                  ))
                .get();
        final ids = changes.map((change) => change.id).toList();
        return commitWorkingChanges(
          ids,
          source: workingChangeSourceAi,
          message: 'history.commit_message.auto_commit_ai_changes',
        );
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=working_changes operation=TAKE_OVER_SCREENPLAY '
        'id=${sceneIds.join(',')}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 手动保存：先 commit 同 scope 内仍 active 的 AI patch，再 commit 手动 patch。
  Future<String?> commitManualSave({
    required List<String> manualChangeIds,
    required Iterable<String> resourceScopes,
    required String manualMessage,
    String aiMessage = 'history.commit_message.auto_commit_ai_changes',
  }) async {
    if (manualChangeIds.isEmpty) {
      return null;
    }
    final aiChangeIds = await _getActiveAiChangeIdsInScopes(resourceScopes);
    if (aiChangeIds.isNotEmpty) {
      await commitWorkingChanges(
        aiChangeIds,
        source: workingChangeSourceAi,
        message: aiMessage,
      );
    }
    return autoSaveCommit(
      manualChangeIds,
      source: workingChangeSourceManual,
      message: manualMessage,
    );
  }

  Future<String?> _commitWorkingChanges(
    List<String> changeIds, {
    required String source,
    required String message,
    required bool allowAmend,
  }) async {
    if (changeIds.isEmpty) {
      return null;
    }
    final rows = <WorkingChange>[];
    for (final id in changeIds) {
      final row = await _contentDatabase.workingChangeDao.getById(id);
      if (row != null &&
          row.status == workingChangeStatusActive &&
          row.source == source) {
        rows.add(row);
      }
    }
    if (rows.isEmpty) {
      return null;
    }

    final now = DateTime.now();

    String commitId;
    int baseChangeCount;
    if (allowAmend) {
      final last = await _contentDatabase.changeCommitDao.getLatestCommit();
      if (last != null &&
          last.source == source &&
          last.message == message &&
          now.difference(last.createdAt).inHours < 1) {
        commitId = last.id;
        baseChangeCount = last.changeCount;
      } else {
        commitId = buildRandomId('commit');
        baseChangeCount = 0;
      }
    } else {
      commitId = buildRandomId('commit');
      baseChangeCount = 0;
    }

    await _contentDatabase.transaction(() async {
      if (baseChangeCount == 0) {
        await _contentDatabase
            .into(_contentDatabase.changeCommits)
            .insert(
              ChangeCommitsCompanion.insert(
                id: commitId,
                message: Value(message),
                source: Value(source),
                changeCount: Value(rows.length),
                createdAt: Value(now),
              ),
            );
      }
      for (final row in rows) {
        await _contentDatabase
            .into(_contentDatabase.changeCommitItems)
            .insert(
              ChangeCommitItemsCompanion.insert(
                id: buildRandomId('commit_item'),
                commitId: commitId,
                workingChangeId: row.id,
                resourcePath: row.resourcePath,
                resourceType: row.resourceType,
                resourceId: Value(row.resourceId),
                field: Value(row.field),
                oldText: Value(row.oldText),
                newText: Value(row.newText),
                createdAt: Value(now),
              ),
            );
        await (_contentDatabase.update(
          _contentDatabase.workingChanges,
        )..where((table) => table.id.equals(row.id))).write(
          WorkingChangesCompanion(
            status: const Value(workingChangeStatusCommitted),
            updatedAt: Value(now),
          ),
        );
      }
      if (baseChangeCount > 0) {
        await (_contentDatabase.update(
          _contentDatabase.changeCommits,
        )..where((table) => table.id.equals(commitId))).write(
          ChangeCommitsCompanion(
            changeCount: Value(baseChangeCount + rows.length),
            createdAt: Value(now),
          ),
        );
      }
    });
    return commitId;
  }

  Future<List<String>> _getActiveAiChangeIdsInScopes(
    Iterable<String> resourceScopes,
  ) async {
    final scopes = resourceScopes
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();
    if (scopes.isEmpty) {
      return const [];
    }
    final changes = await getWorkingChanges();
    return changes
        .where(
          (change) =>
              change.status == workingChangeStatusActive &&
              change.source == workingChangeSourceAi &&
              _resourcePathInScopes(change.resourcePath, scopes),
        )
        .map((change) => change.id)
        .toList();
  }

  bool _resourcePathInScopes(String patchPath, Set<String> scopes) {
    for (final scope in scopes) {
      if (resourcePathIsWithin(patchPath, scope)) {
        return true;
      }
    }
    return false;
  }

  Future<WorkingChange?> _getActiveWorkingChange(
    String resourcePath, {
    String? source,
    String? sourceSessionId,
    String? sourceTurnId,
  }) async {
    // 先找该字段最后一段，再判断归属；不能跨过其他来源或轮次寻找旧段。
    final latest =
        await (_contentDatabase.select(_contentDatabase.workingChanges)
              ..where(
                (table) => table.resourcePath.equals(
                  canonicalResourcePath(resourcePath),
                ),
              )
              ..orderBy([(table) => OrderingTerm.desc(table.rowId)])
              ..limit(1))
            .getSingleOrNull();
    if (latest == null ||
        latest.status != workingChangeStatusActive ||
        latest.changeType != 'write' ||
        latest.source != source ||
        latest.sourceSessionId != sourceSessionId ||
        latest.sourceTurnId != sourceTurnId) {
      return null;
    }
    final current = await _readResourceFieldText(
      resourceType: latest.resourceType,
      resourceId: latest.resourceId,
      resourceField: latest.field,
    );
    if (current == null) {
      return null;
    }
    final matches = latest.resourceType == 'outlines' && latest.field == 'beats'
        ? outlineBeatsHaveSameContent(
            decodeTimelineJson(current),
            decodeTimelineJson(latest.newText ?? ''),
          )
        : current == latest.newText;
    return matches ? latest : null;
  }

  /// 整篇覆盖的剧本字段：同一路径同时只允许一个 AI 会话有 active 改动。
  ///
  /// `expectedCurrentText` 拦不住这种叠加 —— patch 是 apply-on-stage，会话 A
  /// stage 完 DB 已经是 A 的内容，会话 B 读到的就是 A，校验反而会通过，于是 B 以
  /// A 为 oldText 叠上去；此时驳回 A 会写回原文，把 B 一起抹掉。
  ///
  /// `screenplay_scenes` + `synopsis` 故意不在表里：短字段的叠加是合并，不是结构
  /// 性覆盖，多会话同时改是允许的。
  static const _wholeDocumentScreenplayFields = {
    'production_clips': 'document',
    workingChangeResourceTypeScreenplayScenes: 'elements',
    workingChangeResourceTypeScreenplayEpisodes: 'outline',
  };

  Future<void> _assertScreenplaySessionAvailable(
    WorkingChange patch, {
    required String? sourceSessionId,
  }) async {
    final lockedField = _wholeDocumentScreenplayFields[patch.resourceType];
    // lockedField 为 null 时不能直接与 patch.field 比较：create 改动的 field
    // 也是 null，会让无关资源类型意外落进这个锁。
    final sceneList =
        patch.resourceType == workingChangeResourceTypeScreenplayScenes &&
        {'emotion', 'events'}.contains(patch.field);
    if (!sceneList && (lockedField == null || lockedField != patch.field)) {
      return;
    }
    final active =
        await (_contentDatabase.select(_contentDatabase.workingChanges)..where(
              (table) =>
                  table.resourcePath.equals(
                    canonicalResourcePath(patch.resourcePath),
                  ) &
                  table.status.equals(workingChangeStatusActive) &
                  table.source.equals(workingChangeSourceAi),
            ))
            .get();
    final conflict = active.any(
      (change) => change.sourceSessionId != sourceSessionId,
    );
    if (conflict) {
      throw WorkingOverlayConflictException(
        resourcePath: patch.resourcePath,
        resourceId: patch.resourceId,
      );
    }
  }

  Future<bool> _applyTextPatch(
    WorkingChange row,
    String value, {
    bool restoreHistory = false,
  }) async {
    if (row.changeType == 'create') {
      return true;
    }
    switch (row.resourceType) {
      case 'novel':
        final novel = await _novelActionsService.getNovelByContentDatabasePath(
          _contentDatabase.filePath,
        );
        if (novel == null) return false;
        await _novelActionsService.updateNovel(
          novel: novel,
          title: row.field == 'title' ? value : novel.title,
          description: row.field == 'description' ? value : novel.description,
          removeCover: false,
          category: row.field == 'category' ? value : novel.category,
          tags: row.field == 'tags'
              ? value
                    .split(',')
                    .map((t) => t.trim())
                    .where((t) => t.isNotEmpty)
                    .toList()
              : novel.tags,
        );
        return true;
      case 'chapters':
        final id = row.resourceId;
        if (id == null || row.field == null) {
          return false;
        }
        await _contentService.updateChapterContentPartial(
          chapterId: id,
          title: row.field == 'title' ? value : null,
          outline: row.field == 'outline' ? value : null,
          content: row.field == 'content' ? value : null,
          brief: row.field == 'brief' ? value : null,
        );
        return true;
      case 'screenplays':
        if (row.resourceId == null || row.field != 'style_id') {
          return false;
        }
        final root = await _contentDatabase.screenplayDao.getRoot();
        if (root == null || root.id != row.resourceId) {
          return false;
        }
        await _storyboardService.write('UPDATE_STYLE', root.id, () async {
          await (_contentDatabase.update(
            _contentDatabase.screenplays,
          )..where((table) => table.id.equals(root.id))).write(
            ScreenplaysCompanion(
              styleId: Value(jsonDecode(value) as String?),
              updatedAt: Value(DateTime.now()),
            ),
          );
        });
        return true;
      case 'production_clips':
        if (row.resourceId != null && row.field == 'inputs') {
          await _storyboardService.restoreInputs(
            row.resourceId!,
            (jsonDecode(value) as List)
                .map((item) => Map<String, dynamic>.from(item as Map))
                .toList(),
          );
          await _novelActionsService.markContentEdited(
            _contentDatabase.filePath,
          );
          return true;
        }
        if (row.resourceId == null || row.field != 'document') {
          return false;
        }
        await _storyboardService.apply(
          row.resourceId!,
          jsonDecode(value) as Map<String, dynamic>,
          restoring: restoreHistory,
        );
        await _novelActionsService.markContentEdited(_contentDatabase.filePath);
        return true;
      case workingChangeResourceTypeScreenplayScenes:
        final id = row.resourceId;
        if (id == null || row.field == null) return false;
        final service = ScreenplayService(
          _contentDatabase,
          novelActionsService: _novelActionsService,
        );
        switch (row.field) {
          case 'title':
            await service.updateScene(
              restoreHistory: restoreHistory,
              sceneId: id,
              title: value,
            );
            return true;
          case 'emotion':
            final decoded = jsonDecode(value) as List?;
            await service.updateScene(
              restoreHistory: restoreHistory,
              sceneId: id,
              emotion: Value(decoded?.cast<String>()),
            );
            return true;
          case 'events':
            final decoded = jsonDecode(value) as List?;
            await service.updateScene(
              restoreHistory: restoreHistory,
              sceneId: id,
              events: Value(
                decoded
                    ?.map((e) => Map<String, dynamic>.from(e as Map))
                    .toList(),
              ),
            );
            return true;
          case 'interior_exterior':
            await service.updateScene(
              restoreHistory: restoreHistory,
              sceneId: id,
              interiorExterior: Value(jsonDecode(value) as String?),
            );
            return true;
          case 'synopsis':
            await service.updateScene(
              restoreHistory: restoreHistory,
              sceneId: id,
              synopsis: value,
            );
            return true;
          case 'elements':
            final result = await service.writeElements(
              restoreHistory: restoreHistory,
              sceneId: id,
              elements: _decodeScreenplayElements(value),
            );
            if (!restoreHistory) {
              await (_contentDatabase.update(
                _contentDatabase.workingChanges,
              )..where((table) => table.id.equals(row.id))).write(
                WorkingChangesCompanion(
                  newText: Value(serializeScreenplayElements(result.elements)),
                ),
              );
            }
            return true;
          default:
            return false;
        }
      // 普通写入与历史恢复共用同一字段落库路径。
      case workingChangeResourceTypeScreenplayEpisodes:
        final id = row.resourceId;
        if (id == null || row.field != 'outline') return false;
        await ScreenplayService(
          _contentDatabase,
          novelActionsService: _novelActionsService,
        ).updateEpisodeOutline(episodeId: id, outline: value);
        return true;
      case 'volumes':
        final id = row.resourceId;
        if (id == null || row.field == null) {
          return false;
        }
        if (row.field != 'title' && row.field != 'outline') {
          return false;
        }
        await _contentService.updateChapterContentPartial(
          chapterId: id,
          title: row.field == 'title' ? value : null,
          outline: row.field == 'outline' ? value : null,
        );
        return true;
      case 'characters':
        final id = row.resourceId;
        if (id == null || row.field == null) return false;
        final existing = await _contentService.getCharacterProfileById(id);
        if (existing == null) return false;
        if (row.field == 'first_appear_chapter_id') {
          await _contentService.updateCharacterFirstAppearChapter(
            characterId: id,
            firstAppearChapterId: value.isEmpty ? null : value,
          );
          return true;
        }
        if (row.field == 'photos') {
          await _contentService.updateCharacterAvatarAndPhotos(
            entryId: id,
            photos: const SubjectPhotoListConverter().fromSql(value),
          );
          return true;
        }
        await _contentService.updateCharacterProfile(
          entryId: id,
          name: row.field == 'name' ? value : existing.name,
          role: row.field == 'role' ? value : existing.role,
          gender: row.field == 'gender' ? value : existing.gender,
          aliases: row.field == 'aliases'
              ? _decodeCharacterAliases(value)
              : existing.aliases,
          biography: row.field == 'biography' ? value : existing.biography,
          appearance: row.field == 'appearance' ? value : existing.appearance,
          personality: row.field == 'personality'
              ? value
              : existing.personality,
          description: row.field == 'description'
              ? value
              : existing.description,
          behaviorTags: row.field == 'behavior_tags'
              ? _decodeCharacterBehaviorTags(value)
              : existing.behaviorTags,
          currentState: row.field == 'current_state'
              ? value
              : existing.currentState,
          identity: row.field == 'identity' ? value : existing.identity,
          age: row.field == 'age' ? value : existing.age,
          motivation: row.field == 'motivation' ? value : existing.motivation,
          arc: row.field == 'arc' ? value : existing.arc,
        );
        return true;
      case 'foreshadowing':
        final id = row.resourceId;
        if (id == null || row.field == null) return false;
        final existing = await _contentService.getForeshadowingById(id);
        if (existing == null) return false;
        if (const [
          'setup_chapter_id',
          'payoff_chapter_id',
          'setup_scene_id',
          'payoff_scene_id',
        ].contains(row.field)) {
          await _contentService.updateForeshadowingPositions(
            entryId: id,
            fields: {row.field!: value.isEmpty ? null : value},
          );
          return true;
        }
        if (!const ['title', 'setup', 'payoff', 'status'].contains(row.field)) {
          return false;
        }
        if (!restoreHistory && row.field == 'title') {
          for (final entry in await _contentService.getForeshadowings()) {
            if (entry.id == id) {
              continue;
            }
            if (entry.title == value) {
              return false;
            }
          }
        }
        await _contentService.updateForeshadowing(
          entryId: id,
          title: row.field == 'title' ? value : existing.title,
          setup: row.field == 'setup' ? value : existing.setup,
          payoff: row.field == 'payoff' ? value : existing.payoff,
          status: row.field == 'status' ? value : existing.status,
        );
        return true;
      case 'locations':
        final id = row.resourceId;
        if (id == null || row.field == null) return false;
        final existing = await _contentService.locationsService.getLocationById(
          id,
        );
        if (existing == null) return false;
        switch (row.field) {
          case 'photos':
            await _contentService.locationsService.updateLocation(
              id: id,
              photos: const SubjectPhotoListConverter().fromSql(value),
            );
            return true;
          case 'name':
            await _contentService.locationsService.updateLocation(
              id: id,
              name: value,
            );
            return true;
          case 'description':
            await _contentService.locationsService.updateLocation(
              id: id,
              description: value,
            );
            return true;
          case 'type':
            if (!restoreHistory && !locationTypes.contains(value)) {
              return false;
            }
            final parentId = existing.parentId;
            if (!restoreHistory &&
                value != locationTypeWorld &&
                parentId == null) {
              return false;
            }
            await _contentService.locationsService.updateLocation(
              id: id,
              type: value,
            );
            return true;
          case 'parent_id':
            final parentId = value.trim().isEmpty ? null : value.trim();
            if (!restoreHistory &&
                existing.type != locationTypeWorld &&
                parentId == null) {
              return false;
            }
            await _contentService.locationsService.updateLocation(
              id: id,
              parentId: parentId,
              clearParentId: parentId == null,
            );
            return true;
          case 'tags':
            await _contentService.locationsService.updateLocation(
              id: id,
              tags: value
                  .split(',')
                  .map((tag) => tag.trim())
                  .where((tag) => tag.isNotEmpty)
                  .toList(),
            );
            return true;
          case 'status':
            if (!restoreHistory && !locationStatuses.contains(value)) {
              return false;
            }
            await _contentService.locationsService.updateLocation(
              id: id,
              status: value,
            );
            return true;
          default:
            return false;
        }
      case 'outlines':
        final id = row.resourceId;
        if (id == null || row.field == null) return false;
        final existing = await _contentService.outlineService.getByDocumentId(
          id,
        );
        if (existing == null) return false;
        switch (row.field) {
          case 'title':
            if (restoreHistory) {
              await _contentService.outlineService.restoreOutline(
                existing.copyWith(title: value),
              );
            } else {
              await _contentService.outlineService.saveOutline(
                existing.copyWith(title: value),
              );
            }
            return true;
          case 'content':
            if (restoreHistory) {
              await _contentService.outlineService.restoreOutline(
                existing.copyWith(content: value),
              );
            } else {
              await _contentService.outlineService.saveOutline(
                existing.copyWith(content: value),
              );
            }
            return true;
          case 'status':
            if (!restoreHistory && !outlineStatuses.contains(value)) {
              return false;
            }
            if (restoreHistory) {
              await _contentService.outlineService.restoreOutline(
                existing.copyWith(status: value),
              );
            } else {
              await _contentService.outlineService.saveOutline(
                existing.copyWith(status: value),
              );
            }
            return true;
          case 'start_chapter_num':
            final startChapterNum = int.tryParse(value);
            if (startChapterNum == null ||
                (!restoreHistory && startChapterNum < 1)) {
              return false;
            }
            if (restoreHistory) {
              await _contentService.outlineService.restoreOutline(
                existing.copyWith(startChapterNum: startChapterNum),
              );
            } else {
              await _contentService.outlineService.saveOutline(
                existing.copyWith(startChapterNum: startChapterNum),
              );
            }
            return true;
          case 'beats':
            final decodedBeats = decodeTimelineJson(value);
            final draft = existing.copyWith(beats: decodedBeats);
            if (restoreHistory &&
                outlineBeatsHaveSameContent(existing.beats, draft.beats)) {
              return true;
            }
            if (restoreHistory) {
              await _contentService.outlineService.restoreOutline(draft);
            } else {
              await _contentService.outlineService.saveOutline(draft);
            }
            // New draft IDs may have collided. Keep review/rollback snapshots
            // on the same final identities as the rows just written.
            if (!restoreHistory) {
              await (_contentDatabase.update(
                _contentDatabase.workingChanges,
              )..where((table) => table.id.equals(row.id))).write(
                WorkingChangesCompanion(
                  newText: Value(draft.encodeTimelineJson()),
                ),
              );
            }
            return true;
          default:
            return false;
        }
      // 'worldbuilding' 是 /lore 改名前留下的存量 working change。
      case 'lore':
      case 'worldbuilding':
      case 'materials':
        final id = row.resourceId;
        if (id == null || row.field == null) return false;
        final existing = await _contentService.documentsService.getDocumentById(
          id,
        );
        if (existing == null) return false;
        if (!restoreHistory && row.field == 'title') {
          final available = await _contentService.documentsService
              .isTitleAvailable(
                type: existing.type,
                title: value,
                parentId: existing.parentId,
                excludeId: id,
              );
          if (!available) {
            return false;
          }
        }
        await _contentService.documentsService.updateDocument(
          id: id,
          title: row.field == 'title' ? value : existing.title,
          content: row.field == 'content' ? value : existing.content,
          category: row.field == 'category' ? value : existing.category,
        );
        return true;
      default:
        final id = row.resourceId;
        if (id == null || row.field == null) return false;
        final existing = await _contentService.getItemById(id);
        if (existing == null) return false;
        if (!restoreHistory && row.field == 'title') {
          for (final entry in await _contentService.getItemsByType(
            existing.type,
          )) {
            if (entry.id == id) {
              continue;
            }
            if (entry.title == value) {
              return false;
            }
          }
        }
        if (row.field == 'status') {
          await _contentService.updateItemStatus(entryId: id, status: value);
        } else {
          await _contentService.updateItem(
            entryId: id,
            title: row.field == 'title' ? value : existing.title,
            content: row.field == 'content' ? value : existing.content,
            category: row.field == 'category' ? value : existing.category,
          );
        }
        return true;
    }
  }

  /// 将 [resourceId] 对应资源恢复到 [commitId] 提交时的字段快照，并记录一次手动提交。
  Future<RestoreResourceResult> restoreResourceToCommit({
    required String resourceId,
    required String commitId,
  }) => _writeWorkingChanges(
    'restore resource=$resourceId commit=$commitId',
    () => _restoreResourceToCommitInTransaction(
      resourceId: resourceId,
      commitId: commitId,
    ),
  );

  Future<RestoreResourceResult> _restoreResourceToCommitInTransaction({
    required String resourceId,
    required String commitId,
  }) async {
    final commit = await _contentDatabase.changeCommitDao.getById(commitId);
    if (commit == null) {
      return RestoreResourceResult.commitNotFound;
    }

    final historyItems = await getChangeCommitItemsForResourceId(resourceId);
    final orderedItems =
        historyItems
            .where(
              (item) => item.field != null && item.field!.trim().isNotEmpty,
            )
            .toList()
          ..sort((a, b) {
            final byTime = a.createdAt.compareTo(b.createdAt);
            if (byTime != 0) {
              return byTime;
            }
            return a.id.compareTo(b.id);
          });
    final lastSelectedItemIndex = orderedItems.lastIndexWhere(
      (item) => item.commitId == commitId,
    );
    if (lastSelectedItemIndex < 0) {
      return RestoreResourceResult.failed;
    }

    final targetByPath = <String, ChangeCommitItem>{};
    for (final item in orderedItems.take(lastSelectedItemIndex + 1)) {
      targetByPath[canonicalResourcePath(item.resourcePath)] = item;
    }
    if (targetByPath.isEmpty) {
      return RestoreResourceResult.failed;
    }

    var skipped = false;

    final manualChangeIds = <String>[];
    for (final item in targetByPath.values) {
      final targetText = item.newText ?? '';
      final currentText = await _readCommittedFieldText(item);
      if (currentText == null ||
          !await _historicalTargetAvailable(
            resourceType: item.resourceType,
            resourceId: item.resourceId,
            field: item.field,
            text: item.newText,
          )) {
        skipped = true;
        _log.warning(
          'Restore skipped missing target/history path=${item.resourcePath}',
        );
        continue;
      }
      await _supersedeActiveFieldChanges(item);
      if (currentText == targetText) {
        continue;
      }
      final change = await stageTextChange(
        restoreHistory: true,
        resourcePath: item.resourcePath,
        resourceType: item.resourceType,
        resourceId: item.resourceId,
        field: item.field,
        oldText: currentText,
        newText: targetText,
        source: workingChangeSourceManual,
        summary: 'Restore to historical version',
      );
      manualChangeIds.add(change.id);
    }

    if (manualChangeIds.isEmpty) {
      return skipped
          ? RestoreResourceResult.skipped
          : RestoreResourceResult.alreadyAtVersion;
    }

    final resourceScopes = targetByPath.values
        .map((item) => _resourceScopeForItem(item))
        .where((scope) => scope.isNotEmpty)
        .toSet();
    final savedCommitId = await commitManualSave(
      manualChangeIds: manualChangeIds,
      resourceScopes: resourceScopes,
      manualMessage: historyCommitMessageRestoreToHistoricalVersion,
    );
    return savedCommitId == null
        ? RestoreResourceResult.failed
        : skipped
        ? RestoreResourceResult.partiallyRestored
        : RestoreResourceResult.restored;
  }

  /// 将 [commitId] 造成的资源和字段改动反向写回，并记录一次手动提交。
  ///
  /// 传入 [resourceId] 时只回滚该资源在本次提交中的改动；不传时回滚整次提交。
  Future<RestoreResourceResult> rollbackCommit({
    required String commitId,
    String? resourceId,
  }) => _writeWorkingChanges(
    'rollback commit=$commitId resource=$resourceId',
    () => _rollbackCommitInTransaction(
      commitId: commitId,
      resourceId: resourceId,
    ),
  );

  Future<RestoreResourceResult> _rollbackCommitInTransaction({
    required String commitId,
    String? resourceId,
  }) async {
    final commit = await _contentDatabase.changeCommitDao.getById(commitId);
    if (commit == null) {
      return RestoreResourceResult.commitNotFound;
    }

    final scopedResourceId = resourceId?.trim();
    final allItems = scopedResourceId == null || scopedResourceId.isEmpty
        ? await getChangeCommitItemsForCommit(commitId)
        : await getChangeCommitItemsForCommitAndResourceId(
            commitId,
            scopedResourceId,
          );
    if (allItems.isEmpty) {
      return RestoreResourceResult.skipped;
    }
    var skipped = false;
    final pendingItems = <ChangeCommitItem>[];
    for (final item in allItems) {
      final original = await getWorkingChangeById(item.workingChangeId);
      if (original == null) {
        skipped = true;
        _log.warning(
          'Rollback skipped missing history path=${item.resourcePath}',
        );
      }
      if (original?.status == workingChangeStatusCommitted) {
        pendingItems.add(item);
      }
    }
    if (pendingItems.isEmpty) {
      return skipped
          ? RestoreResourceResult.skipped
          : RestoreResourceResult.alreadyAtVersion;
    }
    final createChanges = <String, WorkingChange>{};
    for (final item in pendingItems) {
      final change = await getWorkingChangeById(item.workingChangeId);
      if (change?.changeType == 'create') {
        createChanges[change!.id] = change;
      }
    }
    final unavailableResourceKeys = <String>{};
    for (final change in createChanges.values.toList()) {
      if (!await _createdResourceExists(change)) {
        skipped = true;
        unavailableResourceKeys.add(_resourceKeyForChange(change)!);
        createChanges.remove(change.id);
        _log.warning(
          'Rollback skipped missing created resource path=${change.resourcePath}',
        );
      }
    }
    pendingItems.removeWhere(
      (item) => unavailableResourceKeys.contains(_resourceKeyForItem(item)),
    );
    final createdResourceKeys = <String>{};
    for (final change in createChanges.values) {
      final key = _resourceKeyForChange(change);
      if (key != null) {
        createdResourceKeys.add(key);
      }
    }
    final insertionOrder = await _contentDatabase.workingChangeDao
        .getInsertionOrder(pendingItems.map((item) => item.workingChangeId));
    final orderedItems =
        pendingItems
            .where(
              (item) =>
                  item.field != null &&
                  item.field!.trim().isNotEmpty &&
                  !createdResourceKeys.contains(_resourceKeyForItem(item)),
            )
            .toList()
          ..sort(
            (a, b) => insertionOrder[a.workingChangeId]!.compareTo(
              insertionOrder[b.workingChangeId]!,
            ),
          );
    if (orderedItems.isEmpty && createChanges.isEmpty) {
      return RestoreResourceResult.skipped;
    }

    final rollbackByPath = <String, ChangeCommitItem>{};
    for (final item in orderedItems) {
      rollbackByPath.putIfAbsent(
        canonicalResourcePath(item.resourcePath),
        () => item,
      );
    }

    // 缺失目标只跳过对应字段，保留它的历史状态供后续处理。
    for (final item in rollbackByPath.values.toList()) {
      if (await _readCommittedFieldText(item) == null ||
          !await _historicalTargetAvailable(
            resourceType: item.resourceType,
            resourceId: item.resourceId,
            field: item.field,
            text: item.oldText,
          )) {
        skipped = true;
        rollbackByPath.remove(canonicalResourcePath(item.resourcePath));
        _log.warning(
          'Rollback skipped missing target/history path=${item.resourcePath}',
        );
      }
    }
    for (final change in await getWorkingChanges()) {
      if (change.status != workingChangeStatusActive) {
        continue;
      }
      final isCreatedResource = createdResourceKeys.contains(
        _resourceKeyForChange(change),
      );
      if (isCreatedResource) {
        await _markChangeRejected(change.id);
      }
    }

    for (final item in rollbackByPath.values) {
      await _supersedeActiveFieldChanges(item);
    }

    for (final item in pendingItems) {
      if (item.field == null ||
          item.field!.trim().isEmpty ||
          !createdResourceKeys.contains(_resourceKeyForItem(item))) {
        continue;
      }
      final change = await getWorkingChangeById(item.workingChangeId);
      if (change?.status == workingChangeStatusCommitted) {
        await _markChangeRejected(change!.id);
      }
    }

    var rolledBackCreateCount = 0;
    final orderedCreateChanges = createChanges.values.toList()
      ..sort((a, b) {
        final byTime = b.createdAt.compareTo(a.createdAt);
        if (byTime != 0) {
          return byTime;
        }
        return b.id.compareTo(a.id);
      });
    for (final change in orderedCreateChanges) {
      if (change.status != workingChangeStatusCommitted) {
        continue;
      }
      await _rollbackCommittedCreateChange(change);
      rolledBackCreateCount++;
    }

    final manualChangeIds = <String>[];
    // 与按轮次回退保持一致：后写字段先恢复，释放前序改名需要的名称。
    for (final item in rollbackByPath.values.toList().reversed) {
      final targetText = item.oldText ?? '';
      final currentText = await _readCommittedFieldText(item);
      if (currentText == null) {
        throw StateError('Rollback target disappeared: ${item.resourcePath}');
      }
      if (_historicalFieldMatches(item, currentText, targetText)) {
        continue;
      }
      final change = await stageTextChange(
        restoreHistory: true,
        resourcePath: item.resourcePath,
        resourceType: item.resourceType,
        resourceId: item.resourceId,
        field: item.field,
        oldText: currentText,
        newText: targetText,
        source: workingChangeSourceManual,
        summary: 'Rollback selected change',
      );
      manualChangeIds.add(change.id);
    }

    for (final item in orderedItems) {
      if (rollbackByPath.containsKey(
        canonicalResourcePath(item.resourcePath),
      )) {
        await _markChangeRejected(item.workingChangeId);
      }
    }

    if (manualChangeIds.isEmpty) {
      if (skipped) {
        return rolledBackCreateCount > 0 || rollbackByPath.isNotEmpty
            ? RestoreResourceResult.partiallyRestored
            : RestoreResourceResult.skipped;
      }
      return rolledBackCreateCount > 0
          ? RestoreResourceResult.restored
          : RestoreResourceResult.alreadyAtVersion;
    }

    final savedCommitId = await autoSaveCommit(
      manualChangeIds,
      source: workingChangeSourceManual,
      message: historyCommitMessageRollbackSelectedCommit,
    );
    return savedCommitId == null
        ? RestoreResourceResult.failed
        : skipped
        ? RestoreResourceResult.partiallyRestored
        : RestoreResourceResult.restored;
  }

  Future<TurnRollbackResult> rollbackTurn({required String turnId}) =>
      rollbackTurns(turnIds: [turnId]);

  /// 一次确定整个截断范围的字段基线，避免按消息重放交错写入。
  Future<TurnRollbackResult> rollbackTurns({
    required Iterable<String> turnIds,
  }) => _writeWorkingChanges('rollback turns=${turnIds.join(',')}', () async {
    final changes = await _contentDatabase.workingChangeDao.getBySourceTurnIds(
      turnIds,
    );
    return _rollbackChangesInTransaction(changes);
  });

  Future<TurnRollbackResult> _rollbackChangesInTransaction(
    List<WorkingChange> changes,
  ) async {
    final eligible = changes
        .where(
          (row) =>
              row.status == workingChangeStatusActive ||
              row.status == workingChangeStatusCommitted ||
              row.status == workingChangeStatusConflicted,
        )
        .toList();
    final skippedIds = <String>{};
    final skippedPaths = <String>[];
    void skip(Iterable<WorkingChange> rows) {
      for (final row in rows) {
        if (skippedIds.add(row.id)) {
          skippedPaths.add(row.resourcePath);
          _log.warning(
            'Rollback skipped missing target/history id=${row.id} path=${row.resourcePath}',
          );
        }
      }
    }

    final creates = eligible
        .where((row) => row.changeType == 'create')
        .toList();
    // 已单独回退的创建记录仍说明该资源已被撤销；只结束剩余记录，
    // 不再读取或重建已删除的资源。
    final createdResources = changes
        .where(
          (row) =>
              row.changeType == 'create' &&
              (row.status == workingChangeStatusActive ||
                  row.status == workingChangeStatusCommitted ||
                  row.status == workingChangeStatusConflicted ||
                  row.status == workingChangeStatusRejected),
        )
        .map(_resourceKeyForChange)
        .whereType<String>()
        .toSet();
    final order = await _contentDatabase.workingChangeDao.getInsertionOrder(
      eligible.map((row) => row.id),
    );
    final groups = groupWorkingChangesByField(eligible, order);
    // 每个字段仍恢复最早基线；字段之间按逆序撤销，先释放后续改名占用的名称。
    for (final group in groups.reversed) {
      final first = group.first;
      if (first.changeType == 'create' ||
          createdResources.contains(_resourceKeyForChange(first))) {
        continue;
      }
      final current = await _readResourceFieldText(
        resourceType: first.resourceType,
        resourceId: first.resourceId,
        resourceField: first.field,
      );
      if (current == null ||
          !await _historicalTargetAvailable(
            resourceType: first.resourceType,
            resourceId: first.resourceId,
            field: first.field,
            text: first.oldText,
          )) {
        skip(group);
        continue;
      }
      // 回退后较早轮次仍可审阅；只读取需要保留的 ID，不加载其正文历史。
      final table = _contentDatabase.workingChanges;
      final earlierQuery = _contentDatabase.selectOnly(table)
        ..addColumns([table.id])
        ..where(
          table.resourcePath.equals(canonicalResourcePath(first.resourcePath)) &
              table.status.equals(workingChangeStatusActive) &
              table.rowId.isSmallerThanValue(order[first.id]!),
        );
      final earlierRows = await earlierQuery.get();
      // 任一段已提交都需要反向历史，不能因最早段仍 active 而只做拒绝。
      final historyChange = group.firstWhere(
        (row) => row.status == workingChangeStatusCommitted,
        orElse: () => first,
      );
      final result = await _rollbackChangeInTransaction(
        historyChange.id,
        targetText: first.oldText ?? '',
        preserveChangeIds: {for (final row in earlierRows) row.read(table.id)!},
      );
      if (result == RollbackChangeResult.skipped) {
        skip(group);
        continue;
      }
      for (final row in group) {
        await _markChangeRejected(row.id);
      }
    }
    creates.sort((a, b) => order[b.id]!.compareTo(order[a.id]!));
    for (final change in creates) {
      final result = await _rollbackChangeInTransaction(change.id);
      if (result == RollbackChangeResult.skipped) {
        skip(
          eligible.where(
            (row) =>
                _resourceKeyForChange(row) == _resourceKeyForChange(change),
          ),
        );
      }
    }
    for (final change in eligible) {
      if (!skippedIds.contains(change.id) &&
          createdResources.contains(_resourceKeyForChange(change))) {
        await _markChangeRejected(change.id);
      }
    }
    return TurnRollbackResult(
      rolledBack: eligible.length - skippedIds.length,
      skipped: changes.length - eligible.length + skippedIds.length,
      skippedPaths: skippedPaths,
    );
  }

  /// 字段快照只用于展示与校验，原始记录保持独立归属。
  Future<List<WorkingFieldReview>> resolveFieldReviews(
    List<WorkingChange> changes,
  ) => _contentDatabase.transaction(() async {
    final order = await _contentDatabase.workingChangeDao.getInsertionOrder(
      changes.map((row) => row.id),
    );
    final reviews = <WorkingFieldReview>[];
    for (final group in groupWorkingChangesByField(changes, order)) {
      final first = group.first;
      final current = first.changeType == 'create'
          ? first.newText
          : await _readResourceFieldText(
              resourceType: first.resourceType,
              resourceId: first.resourceId,
              resourceField: first.field,
            );
      reviews.add(WorkingFieldReview(changes: group, currentText: current));
    }
    return reviews;
  });

  Future<TurnRollbackResult> rollbackFields(
    List<WorkingFieldReview> reviews,
  ) => _writeWorkingChanges(
    'rollback ids=${reviews.expand((review) => review.changes).map((row) => row.id).join(',')}',
    () async {
      final changes = <WorkingChange>[];
      final missing = <String>[];
      final seen = <String>{};
      for (final review in reviews) {
        for (final snapshot in review.changes) {
          if (!seen.add(snapshot.id)) {
            continue;
          }
          final saved = await getWorkingChangeById(snapshot.id);
          if (saved == null) {
            missing.add(snapshot.resourcePath);
          } else {
            changes.add(saved);
          }
        }
      }
      final result = await _rollbackChangesInTransaction(changes);
      return TurnRollbackResult(
        rolledBack: result.rolledBack,
        skipped: result.skipped + missing.length,
        skippedPaths: [...missing, ...result.skippedPaths],
      );
    },
  );

  Future<RollbackChangeResult> rollbackFieldLines(
    WorkingFieldReview review,
    Set<String> rejectedLineKeys,
  ) => _writeWorkingChanges(
    'rollback lines ids=${review.changes.map((row) => row.id).join(',')}',
    () async {
      if (rejectedLineKeys.isEmpty) {
        return RollbackChangeResult.noop;
      }
      if (review.changeType == 'create' || review.isStructuredField) {
        final result = await rollbackFields([review]);
        return result.skippedPaths.isNotEmpty
            ? RollbackChangeResult.skipped
            : result.rolledBack > 0
            ? RollbackChangeResult.rolledBack
            : RollbackChangeResult.noop;
      }
      if (review.field == null) {
        return RollbackChangeResult.skipped;
      }
      final savedRows = <WorkingChange>[];
      for (final snapshot in review.changes) {
        final saved = await getWorkingChangeById(snapshot.id);
        if (saved == null) {
          return RollbackChangeResult.skipped;
        }
        savedRows.add(saved);
      }
      if (savedRows.every((row) => row.status == workingChangeStatusRejected)) {
        return RollbackChangeResult.noop;
      }
      final current = await _readResourceFieldText(
        resourceType: review.resourceType,
        resourceId: review.resourceId,
        resourceField: review.field,
      );
      if (current == null) {
        return RollbackChangeResult.skipped;
      }
      final target = computeLineAcceptResult(
        review.oldText,
        review.newText,
        rejectedLineKeys,
      );
      if (target == review.newText) {
        return RollbackChangeResult.noop;
      }
      if (target == (review.oldText ?? '')) {
        final result = await rollbackFields([review]);
        return result.skippedPaths.isNotEmpty
            ? RollbackChangeResult.skipped
            : RollbackChangeResult.rolledBack;
      }
      final activeIds = savedRows
          .where((row) => row.status == workingChangeStatusActive)
          .map((row) => row.id)
          .toList();
      if (activeIds.isNotEmpty) {
        await commitWorkingChanges(
          activeIds,
          source: workingChangeSourceAi,
          message: 'history.commit_message.auto_commit_ai_changes',
        );
      }
      final reverse = await _stageTextChangeInTransaction(
        allowCoalescing: false,
        restoreHistory: true,
        resourcePath: review.resourcePath,
        resourceType: review.resourceType,
        resourceId: review.resourceId,
        field: review.field,
        oldText: current,
        newText: target,
        source: workingChangeSourceManual,
        summary: 'Partial rollback change',
      );
      await autoSaveCommit(
        [reverse.id],
        source: workingChangeSourceManual,
        message: 'history.commit_message.rollback_change_lines',
      );
      return RollbackChangeResult.rolledBack;
    },
  );

  /// 回退单条改动到其历史 oldText，覆盖该字段后续编辑，并记录反向改动。
  Future<RollbackChangeResult> rollbackChange(String changeId) =>
      _writeWorkingChanges(
        'rollback id=$changeId',
        () => _rollbackChangeInTransaction(changeId),
      );

  Future<RollbackChangeResult> _rollbackChangeInTransaction(
    String changeId, {
    Set<String> preserveChangeIds = const {},
    String? targetText,
  }) async {
    final change = await _contentDatabase.workingChangeDao.getById(changeId);
    if (change == null) {
      return RollbackChangeResult.skipped;
    }
    if (change.status == workingChangeStatusRejected) {
      return RollbackChangeResult.noop;
    }
    if (change.changeType != 'create' &&
        !await _historicalTargetAvailable(
          resourceType: change.resourceType,
          resourceId: change.resourceId,
          field: change.field,
          text: targetText ?? change.oldText,
        )) {
      return RollbackChangeResult.skipped;
    }
    if (change.changeType == 'create' &&
        !await _createdResourceExists(change)) {
      return RollbackChangeResult.skipped;
    }
    if (change.status == workingChangeStatusActive ||
        change.status == workingChangeStatusConflicted) {
      if (change.changeType != 'create') {
        if (await _readResourceFieldText(
                  resourceType: change.resourceType,
                  resourceId: change.resourceId,
                  resourceField: change.field,
                ) ==
                null ||
            change.oldText == null) {
          return RollbackChangeResult.skipped;
        }
        final repaired = await RollbackRepairOrchestrator().prepare(
          database: _contentDatabase,
          resourceType: change.resourceType,
          id: change.resourceId!,
          field: change.field!,
          value: targetText ?? change.oldText!,
        );
        final applied = await _applyTextPatch(
          change,
          repaired,
          restoreHistory: true,
        );
        if (!applied) {
          return RollbackChangeResult.skipped;
        }
        await _markChangeRejected(change.id);
      } else {
        await _deleteCreatedResource(change);
        await _markChangeRejected(change.id);
      }
      return RollbackChangeResult.rolledBack;
    }
    if (change.status != workingChangeStatusCommitted) {
      return RollbackChangeResult.skipped;
    }
    if (change.changeType == 'create') {
      await _rollbackCommittedCreateChange(change);
      return RollbackChangeResult.rolledBack;
    }
    final item = await _contentDatabase.changeCommitDao
        .getItemByWorkingChangeId(changeId);
    if (item == null ||
        (targetText == null && item.oldText == null) ||
        item.field == null ||
        item.field!.trim().isEmpty) {
      return RollbackChangeResult.skipped;
    }
    final currentText = await _readCommittedFieldText(item);
    if (currentText == null) {
      return RollbackChangeResult.skipped;
    }
    await _supersedeActiveFieldChanges(
      item,
      preserveChangeIds: preserveChangeIds,
    );
    targetText ??= item.oldText ?? '';
    if (_historicalFieldMatches(item, currentText, targetText)) {
      await _markChangeRejected(changeId);
      return RollbackChangeResult.rolledBack;
    }
    final reverseChange = await stageTextChange(
      restoreHistory: true,
      resourcePath: item.resourcePath,
      resourceType: item.resourceType,
      resourceId: item.resourceId,
      field: item.field,
      oldText: currentText,
      newText: targetText,
      source: workingChangeSourceManual,
      summary: 'Rollback change',
    );
    await autoSaveCommit(
      [reverseChange.id],
      source: workingChangeSourceManual,
      message: 'history.commit_message.rollback_turn',
    );
    await _markChangeRejected(changeId);
    return RollbackChangeResult.rolledBack;
  }

  /// 按行回退：把 [changeId] 中被退回的行恢复为原文，其余 AI 行保留。
  ///
  /// 目标文本由冻结在 change 行上的 old/new 与 [rejectedLineKeys] 合成
  /// （见 [computeLineAcceptResult]）；[rejectedLineKeys] 必须传入全量退回集合
  /// （含此前已退回的行），否则目标文本会把已退回行恢复为 AI 文本。
  /// 语义与 [rollbackChange] 对齐：
  /// - 无有效退回行 → noop；全部退回 → 委托 [rollbackChange]，状态簿记一致；
  /// - active 的 change 先按常规提交规范化，之后统一走 committed 分支；
  /// - 部分退回写成 manual_edit 反向 change 并提交，原 change 保持 committed，
  ///   历史里「AI 写了什么」与「人退回了什么」各自可查。
  Future<RollbackChangeResult> rollbackChangeLines(
    String changeId,
    Set<String> rejectedLineKeys,
  ) => _writeWorkingChanges(
    'rollback lines id=$changeId',
    () => _rollbackChangeLinesInTransaction(changeId, rejectedLineKeys),
  );

  Future<RollbackChangeResult> _rollbackChangeLinesInTransaction(
    String changeId,
    Set<String> rejectedLineKeys,
  ) async {
    if (rejectedLineKeys.isEmpty) {
      return RollbackChangeResult.noop;
    }
    final change = await _contentDatabase.workingChangeDao.getById(changeId);
    if (change == null) {
      return RollbackChangeResult.skipped;
    }
    if (change.changeType == 'create' ||
        WorkingFieldReview(
          changes: [change],
          currentText: change.newText,
        ).isStructuredField) {
      return _rollbackChangeInTransaction(changeId);
    }
    if (change.status != workingChangeStatusActive &&
        change.status != workingChangeStatusCommitted) {
      return RollbackChangeResult.skipped;
    }
    final field = change.field?.trim();
    if (field == null || field.isEmpty) {
      return RollbackChangeResult.skipped;
    }
    final oldText = change.oldText ?? '';
    final newText = change.newText ?? '';
    final targetText = computeLineAcceptResult(
      oldText,
      newText,
      rejectedLineKeys,
    );
    if (targetText == newText) {
      return RollbackChangeResult.noop;
    }
    // 无历史部分退回时保持原委托行为（active 走拒绝路径，不产生提交噪音）。
    if (targetText == oldText) {
      return rollbackChange(changeId);
    }
    if (change.status == workingChangeStatusActive) {
      final currentText = await _readResourceFieldText(
        resourceType: change.resourceType,
        resourceId: change.resourceId,
        resourceField: change.field,
      );
      if (currentText == null) {
        return RollbackChangeResult.skipped;
      }
      await commitWorkingChanges(
        [changeId],
        source: change.source,
        message: 'history.commit_message.auto_commit_ai_changes',
      );
    }
    final item = await _contentDatabase.changeCommitDao
        .getItemByWorkingChangeId(changeId);
    if (item == null) {
      if (change.status == workingChangeStatusActive) {
        throw StateError(
          'Accepted rollback change has no history item: $changeId',
        );
      }
      return RollbackChangeResult.skipped;
    }
    final currentText = await _readCommittedFieldText(item);
    if (currentText == null) {
      if (change.status == workingChangeStatusActive) {
        throw StateError('Rollback target disappeared: ${item.resourcePath}');
      }
      return RollbackChangeResult.skipped;
    }
    await _supersedeActiveFieldChanges(item);
    if (_historicalFieldMatches(item, currentText, targetText)) {
      return RollbackChangeResult.noop;
    }
    final reverseChange = await stageTextChange(
      restoreHistory: true,
      resourcePath: item.resourcePath,
      resourceType: item.resourceType,
      resourceId: item.resourceId,
      field: item.field,
      oldText: currentText,
      newText: targetText,
      source: workingChangeSourceManual,
      summary: 'Partial rollback change',
    );
    await autoSaveCommit(
      [reverseChange.id],
      source: workingChangeSourceManual,
      message: 'history.commit_message.rollback_change_lines',
    );
    return RollbackChangeResult.rolledBack;
  }

  /// 历史目标覆盖同字段的后续 active 改动；只结束记录，不重放其旧文本。
  /// 调用方先验证目标，并将本操作和恢复写入放在同一事务内。
  /// 同次回退已产生的反向记录保留，以便后续字段历史合并为净变化。
  Future<void> _supersedeActiveFieldChanges(
    ChangeCommitItem item, {
    Set<String> preserveChangeIds = const {},
  }) async {
    final active =
        await (_contentDatabase.select(_contentDatabase.workingChanges)..where(
              (row) =>
                  row.status.equals(workingChangeStatusActive) &
                  row.resourceType.equals(item.resourceType) &
                  row.resourceId.equals(item.resourceId!) &
                  row.field.equals(item.field!),
            ))
            .get();
    for (final change in active) {
      if (!preserveChangeIds.contains(change.id)) {
        await _markChangeRejected(change.id);
      }
    }
  }

  /// 历史快照保留时间戳，业务状态相同不产生额外反向改动。
  bool _historicalFieldMatches(
    ChangeCommitItem item,
    String currentText,
    String targetText,
  ) {
    if (item.resourceType == 'outlines' && item.field == 'beats') {
      return outlineBeatsHaveSameContent(
        decodeTimelineJson(currentText),
        decodeTimelineJson(targetText),
      );
    }
    return currentText == targetText;
  }

  /// 把原改动行标记为已回退（rejected），使其从变更日志「待回退」态退出，
  /// 并让 [rollbackTurn] / [rollbackChange] 的二次调用幂等。
  Future<void> _markChangeRejected(String changeId) async {
    await (_contentDatabase.update(
      _contentDatabase.workingChanges,
    )..where((table) => table.id.equals(changeId))).write(
      WorkingChangesCompanion(
        status: const Value(workingChangeStatusRejected),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> _rollbackCommittedCreateChange(WorkingChange change) async {
    await _deleteCreatedResource(change);
    await _markChangeRejected(change.id);
  }

  String _resourceScopeForItem(ChangeCommitItem item) {
    final resourcePath = item.resourcePath.trim();
    if (resourcePath.isNotEmpty) {
      return resourcePath;
    }
    final resourceId = item.resourceId?.trim();
    if (resourceId == null || resourceId.isEmpty) {
      return item.resourcePath;
    }
    return '/${item.resourceType}/$resourceId';
  }

  String? _resourceKeyForItem(ChangeCommitItem item) {
    final resourceId = item.resourceId?.trim();
    final resourceType = item.resourceType.trim();
    if (resourceId == null || resourceId.isEmpty || resourceType.isEmpty) {
      return null;
    }
    return '$resourceType:$resourceId';
  }

  String? _resourceKeyForChange(WorkingChange change) {
    final resourceId = change.resourceId?.trim();
    final resourceType = change.resourceType.trim();
    if (resourceId == null || resourceId.isEmpty || resourceType.isEmpty) {
      return null;
    }
    return '$resourceType:$resourceId';
  }

  Future<String?> _readCommittedFieldText(ChangeCommitItem item) =>
      _readResourceFieldText(
        resourceType: item.resourceType,
        resourceId: item.resourceId,
        resourceField: item.field,
      );

  Future<String?> _readResourceFieldText({
    required String resourceType,
    required String? resourceId,
    required String? resourceField,
  }) async {
    final field = resourceField?.trim();
    final id = resourceId?.trim();
    if (field == null || field.isEmpty || id == null || id.isEmpty) {
      return null;
    }

    switch (resourceType) {
      case 'novel':
        final novel = await _novelActionsService.getNovelByContentDatabasePath(
          _contentDatabase.filePath,
        );
        if (novel == null) {
          return null;
        }
        return switch (field) {
          'title' => novel.title,
          'description' => novel.description,
          'category' => novel.category,
          'tags' => novel.tags.join(','),
          _ => null,
        };
      case 'chapters':
      case 'volumes':
        final chapter = await _contentService.getChapterById(id);
        if (chapter == null) {
          return null;
        }
        return switch (field) {
          'title' => chapter.title ?? '',
          'outline' => chapter.outline,
          'brief' => chapter.brief,
          'content' => chapter.content,
          _ => null,
        };
      case 'screenplays':
        final root = await _contentDatabase.screenplayDao.getRoot();
        if (root == null || root.id != id || field != 'style_id') {
          return null;
        }
        return jsonEncode(root.styleId);
      case 'production_clips':
        final service = _storyboardService;
        if (field == 'inputs') {
          return jsonEncode(await service.inputSnapshot(id));
        }
        final shot = await service.getShot(id);
        return shot == null ? null : jsonEncode(service.snapshot(shot));
      case workingChangeResourceTypeScreenplayScenes:
        final scene = await _contentDatabase.screenplayDao.getScene(id);
        if (scene == null) return null;
        return switch (field) {
          'synopsis' => scene.synopsis,
          'title' => scene.title,
          'emotion' => jsonEncode(scene.emotion),
          'events' => jsonEncode(scene.events),
          'interior_exterior' => jsonEncode(scene.interiorExterior),
          'elements' => serializeScreenplayElements(
            (await _contentDatabase.screenplayDao.getElementRows(id)).map(
              (row) => ScreenplayElement(
                id: row.id,
                type: screenplayElementTypeFromName(row.type),
                text: row.textContent,
                characterId: row.characterId,
                extension: row.extension,
              ),
            ),
          ),
          _ => null,
        };
      case workingChangeResourceTypeScreenplayEpisodes:
        final episode = await _contentDatabase.screenplayDao.getEpisode(id);
        if (episode == null) return null;
        return switch (field) {
          'outline' => episode.outline,
          _ => null,
        };
      case 'characters':
        final character = await _contentService.getCharacterProfileById(id);
        if (character == null) {
          return null;
        }
        return switch (field) {
          'name' => character.name,
          'role' => character.role,
          'gender' => character.gender,
          'aliases' => jsonEncode(character.aliases),
          'photos' => const SubjectPhotoListConverter().toSql(
            character.photos ?? const [],
          ),
          'identity' => character.identity,
          'age' => character.age,
          'motivation' => character.motivation,
          'arc' => character.arc,
          'biography' => character.biography,
          'personality' => character.personality,
          'description' => character.description,
          'appearance' => character.appearance,
          'behavior_tags' => jsonEncode(
            character.behaviorTags.map((tag) => tag.toJson()).toList(),
          ),
          'current_state' => character.currentState,
          'first_appear_chapter_id' => character.firstAppearChapterId ?? '',
          _ => null,
        };
      case 'foreshadowing':
        final foreshadowing = await _contentService.getForeshadowingById(id);
        if (foreshadowing == null) {
          return null;
        }
        return switch (field) {
          'title' => foreshadowing.title,
          'setup' => foreshadowing.setup,
          'payoff' => foreshadowing.payoff,
          'status' => foreshadowing.status,
          'setup_chapter_id' => foreshadowing.setupChapterId ?? '',
          'payoff_chapter_id' => foreshadowing.payoffChapterId ?? '',
          'setup_scene_id' => foreshadowing.setupSceneId ?? '',
          'payoff_scene_id' => foreshadowing.payoffSceneId ?? '',
          _ => null,
        };
      case 'locations':
        final location = await _contentService.locationsService.getLocationById(
          id,
        );
        if (location == null) {
          return null;
        }
        return switch (field) {
          'photos' => const SubjectPhotoListConverter().toSql(
            location.photos ?? const [],
          ),
          'name' => location.name,
          'description' => location.description,
          'type' => location.type,
          'parent_id' => location.parentId ?? '',
          'tags' => location.tags,
          'status' => location.status,
          _ => null,
        };
      case 'outlines':
        final outline = await _contentService.outlineService.getByDocumentId(
          id,
        );
        if (outline == null) {
          return null;
        }
        return switch (field) {
          'title' => outline.title,
          'content' => outline.content,
          'status' => outline.status,
          'start_chapter_num' => outline.startChapterNum.toString(),
          'beats' => outline.encodeTimelineJson(),
          _ => null,
        };
      case 'lore':
      case 'worldbuilding':
      case 'materials':
        final document = await _contentService.documentsService.getDocumentById(
          id,
        );
        if (document == null) {
          return null;
        }
        return switch (field) {
          'title' => document.title,
          'content' => document.content,
          'category' => document.category,
          _ => null,
        };
      default:
        final entry = await _contentService.getItemById(id);
        if (entry == null) {
          return null;
        }
        return switch (field) {
          'title' => entry.title,
          'content' => entry.content,
          'category' => entry.category,
          'status' => entry.status,
          _ => null,
        };
    }
  }

  /// 清理超过 [retentionDays] 天的变更记录。
  /// 先清理 commit + commit items，再清理 working changes。
  Future<void> cleanUpOldRecords(int retentionDays) async {
    final cutoff = DateTime.now().subtract(Duration(days: retentionDays));
    await _contentDatabase.changeCommitDao.deleteOlderThan(cutoff);
    await _contentDatabase.workingChangeDao.deleteOlderThan(cutoff);
  }

  /// 历史值可绕过业务校验，但无法恢复已经缺失的字段或节拍身份。
  Future<bool> _historicalTargetAvailable({
    required String resourceType,
    required String? resourceId,
    required String? field,
    required String? text,
  }) async {
    if (text == null || field == null || resourceId == null) {
      return false;
    }
    if (resourceType == 'outlines' && field == 'beats') {
      final existing = await _contentDatabase.outlineDao.getBeatRows(
        resourceId,
      );
      final ids = existing.map((row) => row.id).toSet();
      return decodeTimelineJson(
        text,
      ).every((beat) => beat.isNew || ids.contains(beat.id));
    }
    return true;
  }

  Future<bool> _createdResourceExists(WorkingChange row) async {
    final id = row.resourceId;
    if (id == null) {
      return false;
    }
    return switch (row.resourceType) {
      'chapters' ||
      'volumes' => await _contentService.getChapterById(id) != null,
      'characters' => await _contentService.getCharacterProfileById(id) != null,
      'locations' =>
        await _contentService.locationsService.getLocationById(id) != null,
      'foreshadowing' => await _contentService.getForeshadowingById(id) != null,
      'outlines' =>
        await _contentService.outlineService.getByDocumentId(id) != null,
      'lore' || 'worldbuilding' || 'materials' =>
        await _contentService.documentsService.getDocumentById(id) != null,
      'relations' =>
        await _contentService.entityRelationsService.getRelationById(id) !=
            null,
      'production_clips' => await _storyboardService.getShot(id) != null,
      workingChangeResourceTypeScreenplayScenes =>
        await _contentDatabase.screenplayDao.getScene(id) != null,
      _ => await _contentService.getItemById(id) != null,
    };
  }

  Future<void> _deleteCreatedResource(WorkingChange row) async {
    final id = row.resourceId;
    if (id == null) return;
    switch (row.resourceType) {
      case 'chapters':
      case 'volumes':
        await _contentService.deleteChapter(id);
        return;
      case 'characters':
        await _contentService.deleteCharacterProfile(id, restoreHistory: true);
        return;
      case 'locations':
        await _contentService.locationsService.deleteLocation(
          id,
          restoreHistory: true,
        );
        return;
      case 'foreshadowing':
        await _contentService.deleteForeshadowing(id);
        return;
      case 'outlines':
        await _contentService.outlineService.deleteOutline(id);
        return;
      case 'lore':
      case 'worldbuilding':
      case 'materials':
        final document = await _contentService.documentsService.getDocumentById(
          id,
        );
        // 目录可能已收纳后续内容，回滚只撤销文档本身，保留目录。
        if (document == null || document.isFolder) return;
        await _contentService.documentsService.deleteDocument(id);
        return;
      case 'relations':
        await _contentService.entityRelationsService.deleteRelation(id);
        return;
      case 'production_clips':
        await _storyboardService.softDelete(id);
        await _novelActionsService.markContentEdited(_contentDatabase.filePath);
        return;
      case workingChangeResourceTypeScreenplayScenes:
        await ScreenplayService(
          _contentDatabase,
          novelActionsService: _novelActionsService,
        ).deleteScene(id);
        return;
      default:
        await _contentService.deleteItem(id);
        return;
    }
  }
}
