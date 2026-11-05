// 职责: AI 聊天会话持久化服务 — 管理会话读写、激活状态与消息落库。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/desktop/widgets/ai/chat/panel.dart
import 'dart:convert';
import 'files/session_files.dart';
import 'tool_operations.dart';
import 'tools.dart' show spawnAgentToolName;

import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../database/novel_content_database.dart';
import '../../models/ai_chat_models.dart';
import '../../models/ai_session_mode.dart';
import '../../agent/agent_context_manager.dart';
import '../../agent/message.dart';
import '../../agent/client.dart' show AiUsage;
import '../../providers/ai_providers.dart' show resolveAiChatNewSessionId;
import '../../logger/app_logger.dart';
import '../../utils/random_id.dart';
import 'context_message_matcher.dart';
import 'tool_error_normalize.dart';
import 'tool_result_payloads.dart';

final _log = AppLogger.forModule('Session');

/// 从持久化会话行读取 reasoning effort（可能为 null）。
String? reasoningEffortFromSession(AiChatSession session) =>
    session.reasoningEffort;

/// 从会话列表中选择首选会话（最近更新的 chat mode 会话）
/// 注意：active 状态现在保存在 novel_states 表中，不在 session 中
AiChatSession? pickPreferredAiChatSession(Iterable<AiChatSession> sessions) {
  final chatSessions =
      sessions.where((s) => s.mode == AiSessionMode.chat.value).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return chatSessions.firstOrNull;
}

/// 解析侧栏/沉浸 chat panel 应绑定的 session id。
///
/// [activeId] 为 null 时保持未绑定；`__new__` / `__handoff_draft__`
/// 信号在尚未映射到真实 session 时原样返回，供 [AiChatPanel] 创建或切换会话。
String? effectiveAiChatSessionId({
  required String novelId,
  required String? activeId,
}) {
  final fromNewSignal = resolveAiChatNewSessionId(
    novelId: novelId,
    activeId: activeId,
  );
  if (fromNewSignal != null) {
    return fromNewSignal;
  }
  if (activeId != null) {
    return activeId;
  }
  return null;
}

class PersistedAiChatSessionData {
  const PersistedAiChatSessionData({required this.messages});

  final List<AiMessage> messages;
}

/// 将独立的 `tool_result` 消息合并进 assistant 的 [AiToolCallBlock] 终态。
///
/// SubAgent 落库走一次性 [saveMessages]；转换时 tool block 默认为 `running`，
/// 若不做合并，[_messageHasNoActiveToolCalls]（831dd78）会整段丢掉含工具的 assistant
/// 轮次，详情里只剩最终结论。
List<AiMessage> finalizeAiMessagesToolCallsForPersistence(
  List<AiMessage> messages,
) {
  final resultsByCallId = <String, Map<String, dynamic>>{};
  final errorsByCallId = <String, String>{};
  for (final message in messages) {
    if (message.type != AiMessageType.tool_result) {
      continue;
    }
    final metadata = message.metadata ?? const <String, dynamic>{};
    final callId = metadata['tool_call_id'] as String?;
    if (callId == null || callId.isEmpty) {
      continue;
    }
    final decoded = _decodeToolResultPayload(message.content);
    final payload = decoded == null
        ? null
        : normalizeToolFailureResult({
            ...decoded,
            if (metadata['is_error'] == true) 'ok': false,
          });
    if (payload != null) {
      resultsByCallId[callId] = payload;
    }
    if (metadata['is_error'] == true ||
        (payload != null && !toolResultIsSuccess(payload))) {
      errorsByCallId[callId] = payload?['error']?.toString() ?? message.content;
    } else {
      resultsByCallId[callId] = payload ?? <String, dynamic>{};
    }
  }

  final finalized = <AiMessage>[];
  for (final message in messages) {
    if (message.type == AiMessageType.tool_result) {
      continue;
    }
    if (message.role != AiMessageRole.assistant || message.blocks.isEmpty) {
      finalized.add(message);
      continue;
    }
    var changed = false;
    final blocks = <AiMessageBlock>[];
    for (final block in message.blocks) {
      if (block is! AiToolCallBlock) {
        blocks.add(block);
        continue;
      }
      final payload = resultsByCallId[block.callId];
      final errorMessage = errorsByCallId[block.callId];
      if (payload == null && errorMessage == null) {
        blocks.add(block);
        continue;
      }
      changed = true;
      blocks.add(
        block.copyWith(
          status: aiToolResultStatus(payload, errorMessage: errorMessage),
          nestedCalls: settleNestedCalls(
            block.nestedCalls,
            cancelled:
                aiToolResultStatus(payload, errorMessage: errorMessage) ==
                AiToolCallStatus.cancelled,
          ),
          result: payload,
          errorMessage: errorMessage,
        ),
      );
    }
    finalized.add(changed ? message.copyWith(blocks: blocks) : message);
  }
  return finalized;
}

Map<String, dynamic>? _decodeToolResultPayload(String content) {
  final trimmed = content.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// Persists AI chat sessions into the app database.
/// Messages are stored in novel content database and require explicit database parameter.
class AiSessionPersistenceService {
  AiSessionPersistenceService(
    this._appDatabase,
    this._novelId, {
    this._novelContentDatabase,
    this.operationRecords,
  });

  final Iterable<ToolOperationRecord> Function(String sessionId)?
  operationRecords;
  final AppDatabase _appDatabase;
  final String _novelId;
  final NovelContentDatabase? _novelContentDatabase;

  Stream<List<AiChatSession>> watchSessions({int? limit}) =>
      _appDatabase.aiChatSessionDao.watchByNovel(_novelId, limit: limit);

  Stream<List<AiChatSession>> watchSessionsExcludingModes(
    List<String> excludedModes, {
    int? limit,
  }) => _appDatabase.aiChatSessionDao.watchByNovelExcludingModes(
    _novelId,
    excludedModes,
    limit: limit,
  );

  /// 当前小说的 chat 会话数量（不含 [excludedModes] 中的特殊 mode），SQL COUNT。
  Stream<int> watchChatSessionCountExcludingModes(List<String> excludedModes) =>
      _appDatabase.aiChatSessionDao.watchCountByNovelExcludingModes(
        _novelId,
        excludedModes,
      );

  Future<int> chatSessionCountExcludingModes(List<String> excludedModes) =>
      _appDatabase.aiChatSessionDao.countByNovelExcludingModes(
        _novelId,
        excludedModes,
      );

  Stream<List<AiChatSession>> watchSessionsByMode(String mode, {int? limit}) =>
      _appDatabase.aiChatSessionDao.watchByMode(_novelId, mode, limit: limit);

  Future<List<AiChatSession>> listSessions({int? limit}) =>
      _appDatabase.aiChatSessionDao.getByNovel(_novelId, limit: limit);

  /// 获取当前激活的 chat session id（从 novel_states 表中读取）
  Future<String?> getActiveSessionId() async {
    final db = _novelContentDatabase;
    if (db == null) return null;
    return db.novelStateDao.getActiveChatSessionId();
  }

  /// 监听当前激活的 chat session id 变化
  Stream<String?> watchActiveSessionId() {
    final db = _novelContentDatabase;
    if (db == null) return Stream.value(null);
    return db.novelStateDao.watchActiveChatSessionId().asyncMap((id) async {
      if (id == null) {
        return null;
      }
      final session = await getSession(id);
      return session?.mode == AiSessionMode.chat.value &&
              session?.parentId == null
          ? session?.id
          : null;
    });
  }

  /// 获取首选会话（先从 novel_states 获取 active session id，再查询 session）
  Future<AiChatSession?> getPreferredSession() async {
    final activeId = await getActiveSessionId();
    if (activeId == null) return null;
    final session = await getSession(activeId);
    return session?.mode == AiSessionMode.chat.value &&
            session?.parentId == null
        ? session
        : null;
  }

  Future<AiChatSession?> getSession(String id) =>
      _appDatabase.aiChatSessionDao.getById(id, novelId: _novelId);

  Future<void> upsertSession({
    required String id,
    required String title,
    String? provider,
    String? model,
    String? mode,
    String? agentSlug,
    String? parentId,
    Map<String, dynamic>? metadata,
    String? reasoningEffort,
    DateTime? createdAt,
  }) {
    return _appDatabase.aiChatSessionDao.upsert(
      id: id,
      novelId: _novelId,
      title: title,
      provider: provider,
      model: model,
      mode: mode,
      agentSlug: agentSlug,
      parentId: parentId,
      reasoningEffort: reasoningEffort,
      metadata: metadata,
      createdAt: createdAt,
    );
  }

  /// 创建并激活会话（只针对 chat mode）
  Future<void> createActiveSession({
    required String id,
    required String title,
    String? provider,
    String? model,
    String? mode,
    String? agentSlug,
    String? parentId,
    Map<String, dynamic>? metadata,
    String? reasoningEffort,
    DateTime? createdAt,
  }) async {
    await upsertSession(
      id: id,
      title: title,
      provider: provider,
      model: model,
      mode: mode,
      agentSlug: agentSlug,
      parentId: parentId,
      metadata: metadata,
      reasoningEffort: reasoningEffort,
      createdAt: createdAt ?? DateTime.now(),
    );
    // 只有 chat mode 才设置 active
    if (parentId == null &&
        (mode == null || mode == AiSessionMode.chat.value)) {
      await _setActiveSessionId(id);
    }
  }

  /// 激活指定会话（只针对 chat mode）
  Future<void> activateSession(String id, {bool Function()? isCurrent}) async {
    final session = await getSession(id);
    if (session == null || isCurrent?.call() == false) return;
    // 只有 chat mode 才有 active 概念
    if (session.mode != AiSessionMode.chat.value || session.parentId != null) {
      return;
    }
    await _setActiveSessionId(id);
  }

  /// Fork [sourceSessionId] into a new top-level chat session: 复制源会话中
  /// 截止到（含）[cutAtSourceId] 这条消息为止的全部已持久化消息。
  ///
  /// 消息 id 全部重新生成 —— ai_chat_messages 的主键是全局 id 而非 (sessionId,id)，
  /// 直接复用源消息 id 会与源会话行冲突。新会话继承源的 provider/model/mode/agentSlug，
  /// 作为顶层 chat 会话自动激活。返回新会话 id，由调用方负责切换/导航过去。
  Future<String> forkSession({
    required String sourceSessionId,
    required String cutAtSourceId,
    required String titleSuffix,
    required NovelContentDatabase novelDatabase,
  }) async {
    final source = await getSession(sourceSessionId);
    if (source == null) {
      throw StateError('fork source session not found: $sourceSessionId');
    }
    final data = await loadSessionMessages(
      sessionId: sourceSessionId,
      novelDatabase: novelDatabase,
    );
    final messages = data.messages;
    final cutIndex = messages.lastIndexWhere((m) => m.id == cutAtSourceId);
    if (cutIndex < 0) {
      throw StateError('fork cut point not found: $cutAtSourceId');
    }
    final forkedId = buildRandomId('ai_session');
    final sourceMessages = messages.sublist(0, cutIndex + 1);
    final forkedMessageIds = {
      for (final message in sourceMessages)
        message.id: buildRandomId('ai_message'),
    };
    final forkedMessages = <AiMessage>[];
    for (final message in sourceMessages) {
      var metadata = message.metadata;
      if (message.type == AiMessageType.compact_summary) {
        final replayFromId = compactReplayFromMessageId(metadata);
        final forkedReplayFromId = forkedMessageIds[replayFromId];
        if (forkedReplayFromId != null) {
          // 摘要可能位于保留消息之后，回放起点必须随消息 ID 一起映射。
          metadata = {
            ...?metadata,
            compactReplayFromMessageIdKey: forkedReplayFromId,
          };
        }
      }
      final copiedBlocks = <AiMessageBlock>[];
      final files = SessionFiles(novelId: _novelId);
      for (final block in message.blocks) {
        if (block is AiAttachmentBlock) {
          try {
            final copy = await files.copy(
              forkedId,
              await files.resolve(block.path),
            );
            copiedBlocks.add(block.withPath(files.reference(copy)));
          } catch (error) {
            // Keep the original reference; hydration reports it as unavailable.
            _log.warning(
              'fork attachment copy skipped id=${block.id} '
              'type=${error.runtimeType}',
            );
            copiedBlocks.add(block);
          }
        } else {
          copiedBlocks.add(block);
        }
      }
      forkedMessages.add(
        message.copyWith(
          id: forkedMessageIds[message.id]!,
          metadata: metadata,
          blocks: copiedBlocks,
        ),
      );
    }
    final baseTitle = source.title.trim().isEmpty
        ? sourceSessionId
        : source.title.trim();
    await createActiveSession(
      id: forkedId,
      title: '$baseTitle ($titleSuffix)',
      provider: source.provider,
      model: source.model,
      mode: source.mode,
      agentSlug: source.agentSlug,
      reasoningEffort: reasoningEffortFromSession(source),
    );
    await saveMessages(
      sessionId: forkedId,
      messages: forkedMessages,
      novelDatabase: novelDatabase,
    );
    return forkedId;
  }

  Future<void> _setActiveSessionId(String? sessionId) async {
    final db = _novelContentDatabase;
    if (db == null) return;
    await db.novelStateDao.setActiveChatSessionId(sessionId);
  }

  Future<void> updateModelSelection({
    required String id,
    required String? provider,
    required String? model,
    String? reasoningEffort,
  }) {
    return _appDatabase.aiChatSessionDao.updateModelSelection(
      id: id,
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort,
      novelId: _novelId,
    );
  }

  Future<void> updateTitle({required String id, required String title}) {
    return _appDatabase.aiChatSessionDao.updateTitle(
      id: id,
      title: title,
      novelId: _novelId,
    );
  }

  Future<void> updateMode({required String id, required AiSessionMode mode}) {
    return _appDatabase.aiChatSessionDao.updateMode(
      id: id,
      mode: mode.value,
      novelId: _novelId,
    );
  }

  Future<void> updateAgentSlug({
    required String id,
    required String? agentSlug,
  }) {
    return _appDatabase.aiChatSessionDao.updateAgentSlug(
      id: id,
      agentSlug: agentSlug,
      novelId: _novelId,
    );
  }

  Future<void> touch(String id) =>
      _appDatabase.aiChatSessionDao.touch(id, novelId: _novelId);

  Future<void> deleteSession(String id) async {
    // 如果删除的是当前 active session，需要清除 active 状态
    final activeId = await getActiveSessionId();
    if (activeId == id) {
      await _setActiveSessionId(null);
    }
    await _appDatabase.aiChatSessionDao.hardDelete(id, novelId: _novelId);
  }

  Future<PersistedAiChatSessionData> loadSessionMessages({
    required String sessionId,
    required NovelContentDatabase novelDatabase,
  }) async {
    final rows = await novelDatabase.aiChatMessageDao.getBySession(sessionId);
    return PersistedAiChatSessionData(
      messages: rows.map(_decodeMessage).toList(),
    );
  }

  /// 收集当前会话及其未删除后代的已保存诊断记录，不受主对话压缩影响。
  /// 子运行结束时才保存消息；运行中或持久化失败的会话单独标记。
  Future<Map<String, dynamic>> loadFeedbackContext({
    required String sessionId,
    required NovelContentDatabase novelDatabase,
  }) async {
    final root = await getSession(sessionId);
    if (root == null) {
      throw StateError('Feedback session is missing: $sessionId');
    }
    final queue = <AiChatSession>[root];
    final visited = <String>{sessionId};
    final snapshots = <Map<String, dynamic>>[];
    final incompleteSessionIds = <String>[];
    const pageSize = 20;
    for (var index = 0; index < queue.length; index++) {
      final session = queue[index];
      final data = await loadSessionMessages(
        sessionId: session.id,
        novelDatabase: novelDatabase,
      );
      snapshots.add({
        'session_id': session.id,
        'parent_session_id': session.parentId,
        'title': session.title,
        'provider': session.provider,
        'model': session.model,
        'mode': session.mode,
        'agent_slug': session.agentSlug,
        'reasoning_effort': session.reasoningEffort,
        'metadata': session.metadata,
        'created_at': session.createdAt.toUtc().toIso8601String(),
        'updated_at': session.updatedAt.toUtc().toIso8601String(),
        'message_count': data.messages.length,
        'messages': data.messages.map((message) => message.toJson()).toList(),
      });
      if (session.metadata?['spawn_run_status'] == 'running' ||
          session.metadata?['spawn_persistence_error_code'] != null) {
        incompleteSessionIds.add(session.id);
      }
      AiChatSession? after;
      while (true) {
        final children = await _appDatabase.aiChatSessionDao.listForTools(
          workId: _novelId,
          parentId: session.id,
          after: after,
          limit: pageSize,
        );
        for (final child in children) {
          if (visited.add(child.id)) {
            queue.add(child);
          }
        }
        if (children.length < pageSize) {
          break;
        }
        after = children.last;
      }
    }
    return {
      'format_version': 2,
      'captured_at': DateTime.now().toUtc().toIso8601String(),
      'message_source': 'persisted',
      ...snapshots.first,
      'sub_sessions': snapshots.skip(1).toList(),
      'session_count': snapshots.length,
      'total_message_count': snapshots.fold<int>(
        0,
        (total, session) => total + (session['message_count'] as int),
      ),
      'incomplete_session_ids': incompleteSessionIds,
    };
  }

  Stream<PersistedAiChatSessionData> watchSessionMessages({
    required String sessionId,
    required NovelContentDatabase novelDatabase,
  }) {
    return novelDatabase.aiChatMessageDao
        .watchBySession(sessionId)
        .map(
          (rows) => PersistedAiChatSessionData(
            messages: rows.map(_decodeMessage).toList(),
          ),
        );
  }

  /// Operation snapshots kept in sub-agent sessions started by [parentMessages].
  /// The child history stays the single source; the parent only indexes it.
  Future<List<Map<String, dynamic>>> loadChildOperationSnapshots(
    List<AiMessage> parentMessages,
  ) async {
    final database = _novelContentDatabase;
    if (database == null) {
      return const [];
    }
    final childSessionIds = {
      for (final message in parentMessages)
        for (final block in message.blocks.whereType<AiToolCallBlock>())
          if (block.toolName == spawnAgentToolName &&
              block.result?['session_id'] is String)
            block.result!['session_id'] as String,
    };
    return [
      for (final childId in childSessionIds)
        for (final row in await database.aiChatMessageDao.getBySession(childId))
          for (final block
              in (row.blocks ?? const []).whereType<AiToolCallBlock>())
            for (final snapshot
                in (block.metadata?['operations'] as List? ?? const []))
              Map<String, dynamic>.from(snapshot as Map),
    ];
  }

  Future<void> saveToolOperation(ToolOperationRecord record) async {
    final database = _novelContentDatabase;
    if (database == null) {
      throw StateError('Operation history requires a content database.');
    }
    try {
      await database.transaction(() async {
        final rows = await database.aiChatMessageDao.getBySession(
          record.sourceSessionId,
        );
        for (final row in rows) {
          if (!(row.blocks ?? []).whereType<AiToolCallBlock>().any(
            (block) => block.callId == (record.historyCallId ?? record.callId),
          )) {
            continue;
          }
          final updated = mergeToolOperationHistory(
            _decodeMessage(row),
            operationRecords?.call(record.sourceSessionId) ?? [record],
          );
          await database.aiChatMessageDao.upsertSessionMessages(
            messages: [
              row.toCompanion(false).copyWith(blocks: Value(updated.blocks)),
            ],
          );
        }
      });
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=ai_chat_messages operation=UPDATE sessionId=${record.sourceSessionId} callId=${record.callId}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Syncs persisted messages for [sessionId]: upserts rows and deletes orphans.
  /// Messages that are still streaming should be filtered out before calling.
  Future<void> saveMessages({
    required String sessionId,
    required List<AiMessage> messages,
    required NovelContentDatabase novelDatabase,
    AgentContextSnapshot? contextSnapshot,
  }) async {
    final companions = _buildMessageCompanions(
      sessionId: sessionId,
      messages: messages,
      contextSnapshot: contextSnapshot,
    );
    try {
      await novelDatabase.aiChatMessageDao.syncSession(
        sessionId: sessionId,
        messages: companions,
      );
    } catch (error, stackTrace) {
      _log.error(
        'table=ai_chat_messages operation=SYNC '
        'sessionId=$sessionId error=$error',
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Upserts completed messages without deleting other rows in the session.
  Future<void> upsertCompletedMessages({
    required String sessionId,
    required List<AiMessage> messages,
    required NovelContentDatabase novelDatabase,
    AgentContextSnapshot? contextSnapshot,
  }) async {
    final companions = _buildMessageCompanions(
      sessionId: sessionId,
      messages: messages,
      contextSnapshot: contextSnapshot,
    );
    try {
      await novelDatabase.aiChatMessageDao.upsertSessionMessages(
        messages: companions,
      );
    } catch (error, stackTrace) {
      _log.error(
        'table=ai_chat_messages operation=UPSERT '
        'sessionId=$sessionId error=$error',
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  List<AiChatMessagesCompanion> _buildMessageCompanions({
    required String sessionId,
    required List<AiMessage> messages,
    AgentContextSnapshot? contextSnapshot,
  }) {
    final persistedMessages = _buildPersistedMessages(
      sessionId: sessionId,
      messages: messages,
      contextSnapshot: contextSnapshot,
    );
    final companions = <AiChatMessagesCompanion>[];
    for (var i = 0; i < persistedMessages.length; i++) {
      final msg = mergeToolOperationHistory(
        persistedMessages[i],
        operationRecords?.call(sessionId) ?? const [],
      );
      if (msg.isStreaming) {
        continue;
      }
      if (msg.role == AiMessageRole.system) {
        continue;
      }
      companions.add(
        AiChatMessagesCompanion.insert(
          id: msg.id,
          sessionId: sessionId,
          role: msg.role.name,
          type: Value(msg.type.name),
          content: Value(msg.content),
          blocks: Value(msg.blocks.isEmpty ? null : msg.blocks),
          metadata: Value(msg.metadata),
          inputTokens: Value(msg.usage?.inputTokens ?? 0),
          outputTokens: Value(msg.usage?.outputTokens ?? 0),
          cacheReadTokens: Value(msg.usage?.cacheReadTokens ?? 0),
          cacheWriteTokens: Value(msg.usage?.cacheWriteTokens ?? 0),
          reasoningTokens: Value(msg.usage?.reasoningTokens ?? 0),
          sequence: Value(i),
          createdAt: Value(msg.timestamp),
        ),
      );
    }
    return companions;
  }

  List<AiMessage> _buildPersistedMessages({
    required String sessionId,
    required List<AiMessage> messages,
    AgentContextSnapshot? contextSnapshot,
  }) {
    final summary = contextSnapshot?.summary?.trim();
    // 历史 compact_summary 永久留存（append-only），不再插入前过滤掉。
    final persisted = messages
        .where((msg) => !msg.isStreaming)
        .where((msg) => msg.role != AiMessageRole.system)
        .where(_messageHasNoActiveToolCalls)
        .toList(growable: true);
    if (summary != null && summary.isNotEmpty) {
      final compactionCount = contextSnapshot?.compactionCount ?? 0;
      final summaryId = compactSummaryMessageId(sessionId, compactionCount);
      final alreadyExists = persisted.any((message) => message.id == summaryId);
      // UI 路径可能已按同一 summaryId 插入；再插会让 companions 出现重复主键，
      // 靠 DAO insertOrReplace 覆盖并打乱 sequence。
      if (!alreadyExists) {
        final retainedMessages =
            contextSnapshot?.messages ?? const <AgentMessage>[];
        final placement = resolveCompactSummaryPlacement(
          uiMessages: persisted,
          retainedMessages: retainedMessages,
          sessionId: sessionId,
          compactedMessageCount: contextSnapshot?.lastCompactionMessageCount,
        );
        if (placement == null) {
          // 未命中时不再把摘要追加到末尾——那样会让后续 messagesSinceLatestCompact
          // 截断到错位置。这里跳过插入，contextSnapshot.summary 仍在内存中生效。
          _log.warning(
            'table=ai_chat_messages operation=COMPACT_SUMMARY_SKIP '
            'sessionId=$sessionId compactionCount=$compactionCount '
            'reason=no_retained_match',
          );
        } else {
          persisted.insert(
            placement.insertIndex,
            AiMessage.user(
              id: summaryId,
              content: summary,
              type: AiMessageType.compact_summary,
              metadata: _buildCompactionMetadata(
                contextSnapshot,
                replayFromMessageId: placement.replayFromMessageId,
              ),
            ),
          );
        }
      }
    }
    return persisted;
  }

  Map<String, dynamic> _buildCompactionMetadata(
    AgentContextSnapshot? snapshot, {
    required String replayFromMessageId,
  }) {
    return buildCompactSummaryMetadata(
      compactionCount: snapshot?.compactionCount ?? 0,
      replayFromMessageId: replayFromMessageId,
      tokensBefore: snapshot?.lastCompactionTokensBefore,
      tokensAfter: snapshot?.lastCompactionTokensAfter,
    );
  }

  bool _messageHasNoActiveToolCalls(AiMessage message) {
    for (final block in message.blocks) {
      if (block is! AiToolCallBlock) {
        continue;
      }
      if (block.status == AiToolCallStatus.pending ||
          block.status == AiToolCallStatus.running) {
        return false;
      }
    }
    return true;
  }

  AiMessage _decodeMessage(AiChatMessage row) {
    return recoverToolOperationHistory(
      AiMessage(
        id: row.id,
        role: AiMessageRole.values.firstWhere(
          (e) => e.name == row.role,
          orElse: () => AiMessageRole.user,
        ),
        type: AiMessageType.values.firstWhere(
          (e) => e.name == row.type,
          orElse: () => AiMessageType.text,
        ),
        content: row.content,
        timestamp: row.createdAt,
        metadata: row.metadata,
        blocks: row.blocks ?? const <AiMessageBlock>[],
        usage: AiUsage(
          inputTokens: row.inputTokens,
          outputTokens: row.outputTokens,
          cacheReadTokens: row.cacheReadTokens,
          cacheWriteTokens: row.cacheWriteTokens,
          reasoningTokens: row.reasoningTokens,
        ),
      ),
      operationRecords?.call(row.sessionId) ?? const [],
    );
  }
}
