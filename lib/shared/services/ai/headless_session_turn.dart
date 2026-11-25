// 职责: 复用 ChatTurnRunner 在后台执行一轮会话并管理会话生命周期
// 关联文件:
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/shared/services/ai/chat_turn_outcome.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/providers/subagent_providers.dart

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/agent_profile.dart';
import '../../models/ai_chat_models.dart';
import '../../models/agent_rule.dart';
import '../../models/ai_provider.dart';
import '../../models/ai_session_mode.dart';
import '../../providers/ai_providers.dart';
import '../../providers/novel_providers.dart';
import '../../providers/prompt_template_provider.dart';
import '../../providers/settings_providers.dart';
import '../../utils/random_id.dart';
import 'chat.dart';
import 'chat_turn_outcome.dart';
import 'tools.dart';
import 'chat_turn_runner.dart';

final _log = AppLogger.forModule('HeadlessSessionTurn');

String _headlessSeedMessageId(String sessionId) => 'headless_seed_$sessionId';

/// 从已持久化 session 恢复 headless 执行所需的内存状态。
///
/// 后台入口可以直接创建 `ai_chat_sessions` 行，不经过聊天面板的 `loadSession`。
/// 后台执行前必须补齐 provider/model/mode，否则 `resolveAiService`
/// 会在 seed 落库前直接返回 null。
Future<bool> ensureHeadlessSessionLoaded(
  ProviderContainer container, {
  required String sessionId,
  required String novelId,
  required String databasePath,
}) async {
  final current = container.read(aiChatSessionProvider(sessionId));
  if (current.isLoaded && current.providerId != null && current.model != null) {
    return true;
  }
  if (databasePath.isEmpty) {
    return false;
  }
  final persistence = container.read(
    aiSessionPersistenceServiceProvider(
      novelId: novelId,
      databasePath: databasePath,
    ),
  );
  final session = await persistence.getSession(sessionId);
  if (session == null) {
    _log.error('headless session not found session=$sessionId');
    return false;
  }
  final novelDb = container.read(novelContentDatabaseProvider(databasePath));
  final persisted = await persistence.loadSessionMessages(
    sessionId: sessionId,
    novelDatabase: novelDb,
  );
  container
      .read(aiChatSessionProvider(sessionId).notifier)
      .loadSession(
        sessionId: session.id,
        title: session.title,
        messages: persisted.messages,
        providerId: session.provider,
        model: session.model,
        persistedReasoningEffort: session.reasoningEffort,
        sessionMode: AiSessionMode.fromString(session.mode),
        agentSlug: session.agentSlug,
      );
  if (_log.isDebugEnabled) {
    _log.debug(
      'headless session loaded session=$sessionId '
      'messages=${persisted.messages.length}',
    );
  }
  return true;
}

/// Headless session 的 provider 已被回收时，不能复用缓存的 agent：它的工具
/// 回调仍捕获上一轮 session notifier，会在下一轮访问已释放的 Ref。
@visibleForTesting
void invalidateStaleHeadlessAgent(
  ProviderContainer container, {
  required String sessionId,
}) {
  final session = container.read(aiChatSessionProvider(sessionId));
  if (!session.isLoaded) {
    container.read(aiChatRuntimeProvider(sessionId).notifier).invalidateAgent();
  }
}

/// Headless turn 的 seed 消息必须先落库，再允许 UI 通过 DB restore 读取该 session。
/// 否则打开 chat 时 `loadSession(persisted.messages)` 会覆盖后台内存 transcript。
///
/// 注意：这里仅写 DB，不写入当前 provider transcript。后台真正执行时会先创建
/// agent（旧历史），再把同一个 deterministic id 的 seed 放回内存并 process(seed)，
/// 与 chat 面板发送顺序一致，避免 seed 同时作为历史和本轮输入进模型。
Future<void> prepareHeadlessSessionSeed(
  ProviderContainer container, {
  required String sessionId,
  required String novelId,
  required String databasePath,
  required String seed,
}) async {
  final seedMessage = AiMessage.user(
    id: _headlessSeedMessageId(sessionId),
    content: seed,
  );
  await _persistHeadlessCompletedMessages(
    container,
    sessionId: sessionId,
    novelId: novelId,
    databasePath: databasePath,
    eventName: 'HeadlessSeed',
    rethrowOnError: true,
    messagesOverride: [seedMessage],
  );
}

Future<void> _persistHeadlessCompletedMessages(
  ProviderContainer container, {
  required String sessionId,
  required String novelId,
  required String databasePath,
  required String eventName,
  bool rethrowOnError = false,
  List<AiMessage>? messagesOverride,
}) async {
  if (databasePath.isEmpty) {
    return;
  }
  final session = container.read(aiChatSessionProvider(sessionId));
  final messages = messagesOverride ?? session.messages;
  if (messagesOverride == null && !session.isLoaded) {
    return;
  }
  if (messages.isEmpty) {
    return;
  }
  try {
    final persistence = container.read(
      aiSessionPersistenceServiceProvider(
        novelId: novelId,
        databasePath: databasePath,
      ),
    );
    final novelDb = container.read(novelContentDatabaseProvider(databasePath));
    final contextSnapshot = messagesOverride == null
        ? container
              .read(aiChatRuntimeProvider(sessionId).notifier)
              .agent
              ?.contextManager
              .snapshot()
        : null;
    await persistence.upsertCompletedMessages(
      sessionId: sessionId,
      messages: messages,
      novelDatabase: novelDb,
      contextSnapshot: contextSnapshot,
    );
    _log.info(
      'persisted headless completed messages from $eventName '
      'sessionId=$sessionId count=${messages.length}',
    );
  } catch (error, stackTrace) {
    _log.error(
      'persist headless completed messages failed event=$eventName '
      'sessionId=$sessionId error=$error',
      error: error,
      stackTrace: stackTrace,
    );
    if (rethrowOnError) {
      rethrow;
    }
  }
}

void _excludePrePersistedSeedFromAgentHistory(
  ProviderContainer container, {
  required String sessionId,
}) {
  final seedMessageId = _headlessSeedMessageId(sessionId);
  final session = container.read(aiChatSessionProvider(sessionId));
  if (!session.messages.any((message) => message.id == seedMessageId)) {
    return;
  }
  container
      .read(aiChatSessionProvider(sessionId).notifier)
      .loadSession(
        sessionId: session.sessionId ?? sessionId,
        title: session.title,
        messages: session.messages
            .where((message) => message.id != seedMessageId)
            .toList(growable: false),
        providerId: session.providerId,
        model: session.model,
        persistedReasoningEffort: session.reasoningEffort,
        sessionMode: session.sessionMode,
        agentSlug: session.agentSlug,
      );
}

void _addHeadlessSeedToMemory(
  ProviderContainer container, {
  required String sessionId,
  required String seed,
}) {
  final seedMessageId = _headlessSeedMessageId(sessionId);
  final session = container.read(aiChatSessionProvider(sessionId));
  if (session.messages.any((message) => message.id == seedMessageId)) {
    return;
  }
  container
      .read(aiChatSessionProvider(sessionId).notifier)
      .addUserMessage(seed, id: seedMessageId);
}

/// 在已存在的持久化 session 上以 headless 方式跑一轮 orchestrator turn：
/// 无 composer / 队列交互，AskUser 立即按推荐项自动处理。先写入 [seed] 用户消息再执行。
///
/// 前置：调用方已初始化/持久化该 session 且其含 provider/model。
/// 本函数自持 keepAlive + startRequest/markRequestIdle，避免后台 autoDispose 中途丢状态。
/// 失败不抛出，统一以 [ChatTurnOutcome] 返回，由调用方决定 fail-loud 策略。
Future<ChatTurnOutcome> runHeadlessSessionTurn(
  ProviderContainer container, {
  required String sessionId,
  required String databasePath,
  required Novel novel,
  required String seed,
  bool seedAlreadyAdded = false,
  AiRunNotifyCallback? notifyCallback,
}) async {
  final novelId = novel.id;
  if (_log.isDebugEnabled) {
    _log.debug('headless turn START session=$sessionId');
  }
  // 后台 turn 期间持有会话 provider，避免 autoDispose 中途回收。
  final sessionKeepAlive = container.listen(
    aiChatSessionProvider(sessionId),
    (_, _) {},
  );
  final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
  invalidateStaleHeadlessAgent(container, sessionId: sessionId);
  final requestId = runtime.startRequest();

  AiClient? aiService;
  try {
    final rules = await container
        .read(novelContentDatabaseProvider(databasePath))
        .agentRuleDao
        .getAll();
    final runner = ChatTurnRunner(
      container: container,
      novel: novel,
      databasePath: databasePath,
      aiPromptService: container.read(aiPromptServiceProvider),
      promptContext: AiSessionContext(userRules: rules.formatForPrompt()),
      // Headless：无 composer / 队列交互。
      onComposerWarning: (message) =>
          _log.warning('headless notice session=$sessionId: $message'),
      // 无人值守时不启动人工等待或提醒，立即复用交互式超时的推荐选择与未回答结果。
      // resolution=timeout 表示自动处理，不冒充用户确认，也不把后台任务标为用户取消。
      askUserHandler: (request) async =>
          AskUserResult.timeout(request.questions),
      notifyCallback: notifyCallback,
    );

    final sessionLoaded = await ensureHeadlessSessionLoaded(
      container,
      sessionId: sessionId,
      novelId: novelId,
      databasePath: databasePath,
    );
    if (!sessionLoaded) {
      return ChatTurnOutcome.failed(
        sessionId: sessionId,
        requestId: requestId,
        error: const ChatTurnError(
          kind: ChatTurnErrorKind.serviceUnavailable,
          safeMessage: '',
          technicalMessage: 'headless session metadata unavailable',
        ),
      );
    }
    if (seedAlreadyAdded) {
      _excludePrePersistedSeedFromAgentHistory(container, sessionId: sessionId);
    }

    final resolution = await runner.resolveAiService(
      requestId: requestId,
      sessionId: sessionId,
    );
    aiService = resolution.client;
    if (aiService == null) {
      _log.error('headless AI service unavailable session=$sessionId');
      return ChatTurnOutcome.failed(
        sessionId: sessionId,
        requestId: requestId,
        error: ChatTurnError(
          kind: ChatTurnErrorKind.serviceUnavailable,
          safeMessage: '',
          technicalMessage:
              'resolveAiService blocked: ${resolution.block!.name}',
        ),
      );
    }
    runtime.attachAiService(aiService);

    // 先建 agent（空历史），再写入种子用户消息，最后跑 turn —— 与聊天面板顺序一致，
    // 避免种子既进 initialMessages 又被 process(seed) 重复加入。
    final agent = await runner.getOrCreateChatAgent(sessionId: sessionId);
    if (agent == null) {
      _log.error('headless agent unavailable session=$sessionId');
      return ChatTurnOutcome.failed(
        sessionId: sessionId,
        requestId: requestId,
        error: const ChatTurnError(
          kind: ChatTurnErrorKind.serviceUnavailable,
          safeMessage: '',
          technicalMessage: 'getOrCreateChatAgent returned null',
        ),
      );
    }
    _addHeadlessSeedToMemory(container, sessionId: sessionId, seed: seed);
    if (!seedAlreadyAdded) {
      await _persistHeadlessCompletedMessages(
        container,
        sessionId: sessionId,
        novelId: novelId,
        databasePath: databasePath,
        eventName: 'HeadlessSeed',
        rethrowOnError: true,
      );
    }

    final outcome = await runner.runTurn(
      seed,
      requestId: requestId,
      sessionId: sessionId,
      userMessageId: seedAlreadyAdded
          ? null
          : _headlessSeedMessageId(sessionId),
      // 预先落库的 seed 不再作为 userMessageId 传入，但写入仍归属这一轮；
      // 缺少 turn id 时 Codemode 嵌套写入会在暂存后抛错。
      sourceTurnId: _headlessSeedMessageId(sessionId),
    );
    await _persistHeadlessCompletedMessages(
      container,
      sessionId: sessionId,
      novelId: novelId,
      databasePath: databasePath,
      eventName: 'HeadlessTurnDone',
    );
    return outcome;
  } catch (error, stackTrace) {
    _log.error(
      'headless turn failed session=$sessionId',
      error: error,
      stackTrace: stackTrace,
    );
    await _persistHeadlessCompletedMessages(
      container,
      sessionId: sessionId,
      novelId: novelId,
      databasePath: databasePath,
      eventName: 'HeadlessTurnCatch',
    );
    return ChatTurnOutcome.failed(
      sessionId: sessionId,
      requestId: requestId,
      error: ChatTurnError(
        kind: ChatTurnErrorKind.runtimeError,
        safeMessage: '',
        technicalMessage: error.toString(),
        cause: error,
      ),
    );
  } finally {
    runtime.markRequestIdle(requestId);
    if (aiService != null) {
      runtime.clearAiService(aiService);
    }
    sessionKeepAlive.close();
    if (_log.isDebugEnabled) {
      _log.debug('headless turn END session=$sessionId');
    }
  }
}

// ==================== Shared startHeadlessRun helper ====================

/// 启动 headless Run 的结果信号。
///
/// 调用方据此映射为各自的业务结果。
enum HeadlessRunOutcome {
  /// 已成功预建会话并在后台启动一轮 Run。
  started,

  /// 该 session 已有 Run 正在后台进行（runtime 仍 in-flight），本次忽略。
  alreadyRunning,

  /// 小说或内容库不可用。
  novelUnavailable,

  /// 无可用聊天模型。
  noValidModel,

  /// 其他启动失败（建会话 / 落 seed 等）。
  failed,
}

class HeadlessRunResult {
  const HeadlessRunResult._(this.outcome, this.sessionId, this.error);

  final HeadlessRunOutcome outcome;

  /// 仅 [HeadlessRunOutcome.started] 时非空：本次 Run 的 chat 会话 id。
  final String? sessionId;

  /// 失败时的错误描述（用于日志，不直接面向用户）。
  final String? error;

  factory HeadlessRunResult.started(String sessionId) =>
      HeadlessRunResult._(HeadlessRunOutcome.started, sessionId, null);
  factory HeadlessRunResult.alreadyRunning() =>
      HeadlessRunResult._(HeadlessRunOutcome.alreadyRunning, null, null);
  factory HeadlessRunResult.novelUnavailable(String detail) =>
      HeadlessRunResult._(HeadlessRunOutcome.novelUnavailable, null, detail);
  factory HeadlessRunResult.noValidModel() =>
      HeadlessRunResult._(HeadlessRunOutcome.noValidModel, null, null);
  factory HeadlessRunResult.failed(String error) =>
      HeadlessRunResult._(HeadlessRunOutcome.failed, null, error);
}

/// 共享 helper：为指定小说启动后台 headless Run。
///
/// 1. 防重入：若 [existingSessionId] 的 runtime 仍 in-flight，返回 alreadyRunning。
/// 2. 校验 novel + content database 可用。
/// 3. 校验有可用聊天模型。
/// 4. 预建会话（chat mode、orchestrator、可选 metadata）。
/// 5. keepAlive + 初始化内存会话 notifier。
/// 6. 落 seed 消息到 DB。
/// 7. 调 [onSessionReady]（可选）：调用方在此写回业务关联。
///    抛异常则中止派发，返回 failed（释放 keepAlive，无孤儿 turn）。
/// 8. 后台跑一轮（不 await），turn 结束后释放 keepAlive。
///
Future<HeadlessRunResult> startHeadlessRun(
  ProviderContainer container, {
  required String novelId,
  required String seed,
  required String title,
  String? existingSessionId,
  Map<String, dynamic>? metadata,

  /// Session 已建好、seed 已落库、即将派发后台 turn 前调用。
  /// 抛异常则中止派发，返回 failed（keepAlive 释放，无孤儿 turn）。
  Future<void> Function(String sessionId)? onSessionReady,

  /// Run notify 回调：远程 Assistant 启动的 run 挂载，写 assistant_inbox。
  /// 桌面本地 run 不传（notify 不可用）。
  AiRunNotifyCallback? notifyCallback,
}) async {
  // 1. 防重入
  if (existingSessionId != null && existingSessionId.isNotEmpty) {
    if (container
        .read(aiChatRuntimeProvider(existingSessionId))
        .isRequestInFlight) {
      _log.info('startHeadlessRun already running session=$existingSessionId');
      return HeadlessRunResult.alreadyRunning();
    }
  }

  // 2. 校验 novel + content database
  final appDb = container.read(appDatabaseProvider);
  final novel = await appDb.novelDao.get(novelId);
  final databasePath = novel?.contentDatabasePath;
  if (novel == null || databasePath == null || databasePath.isEmpty) {
    _log.error(
      'startHeadlessRun novel/content database unavailable novelId=$novelId',
    );
    return HeadlessRunResult.novelUnavailable('novelId=$novelId');
  }

  // 3. 校验有可用聊天模型
  final modelOption = container.read(
    resolvedAiModelOptionForKindProvider(
      kind: AiModelKind.chat,
      databasePath: databasePath,
    ),
  );
  final config = modelOption == null
      ? null
      : container.read(
          currentAiConfigProvider(
            providerId: modelOption.providerId,
            model: modelOption.model,
          ),
        );
  if (modelOption == null || config == null || !config.isValid) {
    _log.error('startHeadlessRun no valid chat model novelId=$novelId');
    return HeadlessRunResult.noValidModel();
  }

  // 4. 预建会话
  final sessionId = buildRandomId('ai_session');
  try {
    await container
        .read(
          aiSessionPersistenceServiceProvider(
            novelId: novelId,
            databasePath: databasePath,
          ),
        )
        .createActiveSession(
          id: sessionId,
          title: title,
          provider: modelOption.providerId,
          model: modelOption.model,
          mode: AiSessionMode.chat.value,
          agentSlug: builtinAgentSlugOrchestrator,
          metadata: metadata,
        );
  } catch (error, stackTrace) {
    _log.error(
      'startHeadlessRun create session failed novelId=$novelId '
      'sessionId=$sessionId',
      error: error,
      stackTrace: stackTrace,
    );
    return HeadlessRunResult.failed('create session failed: $error');
  }

  // 5. 先持有会话 provider，再写入内存状态：aiChatSessionProvider 是 autoDispose，
  // 若在 startNewSession 后、后台 turn 读取前没有任何 listener，会在 await 间隙被
  // 回收并把 providerId/model 重置为 null，导致 resolveAiService 直接返回 null。
  final sessionKeepAlive = container.listen(
    aiChatSessionProvider(sessionId),
    (_, _) {},
  );

  // 6. 初始化内存会话 notifier（供 ChatTurnRunner 驱动）。
  container
      .read(aiChatSessionProvider(sessionId).notifier)
      .startNewSession(
        sessionId: sessionId,
        title: title,
        providerId: modelOption.providerId,
        model: modelOption.model,
        sessionMode: AiSessionMode.chat,
        agentSlug: builtinAgentSlugOrchestrator,
      );
  if (_log.isDebugEnabled) {
    _log.debug(
      'startHeadlessRun session initialized novelId=$novelId sessionId=$sessionId '
      'provider=${modelOption.providerId} model=${modelOption.model}',
    );
  }

  // 7. 准备 seed（落库）
  try {
    await prepareHeadlessSessionSeed(
      container,
      sessionId: sessionId,
      novelId: novelId,
      databasePath: databasePath,
      seed: seed,
    );
  } catch (error, stackTrace) {
    sessionKeepAlive.close();
    _log.error(
      'startHeadlessRun persist seed failed novelId=$novelId sessionId=$sessionId',
      error: error,
      stackTrace: stackTrace,
    );
    return HeadlessRunResult.failed('persist seed failed: $error');
  }

  // 7.5. 调用方 hook：写回业务关联。
  // 失败则不派发 turn，释放 keepAlive，返回 failed（避免孤儿 turn / double-run）。
  if (onSessionReady != null) {
    try {
      await onSessionReady(sessionId);
    } catch (error, stackTrace) {
      sessionKeepAlive.close();
      _log.error(
        'startHeadlessRun onSessionReady failed novelId=$novelId '
        'sessionId=$sessionId',
        error: error,
        stackTrace: stackTrace,
      );
      return HeadlessRunResult.failed('onSessionReady failed: $error');
    }
  }

  // 8. 后台跑一轮，不 await（调用方立即得到 sessionId）。turn 结束后释放 keepAlive。
  if (_log.isDebugEnabled) {
    _log.debug(
      'startHeadlessRun dispatching background turn novelId=$novelId '
      'sessionId=$sessionId',
    );
  }
  unawaited(
    _runHeadlessTurnInBackground(
      container,
      sessionId: sessionId,
      databasePath: databasePath,
      novel: novel,
      seed: seed,
      seedAlreadyAdded: true,
      notifyCallback: notifyCallback,
    ).whenComplete(sessionKeepAlive.close),
  );

  return HeadlessRunResult.started(sessionId);
}

Future<void> _runHeadlessTurnInBackground(
  ProviderContainer container, {
  required String sessionId,
  required String databasePath,
  required Novel novel,
  required String seed,
  required bool seedAlreadyAdded,
  AiRunNotifyCallback? notifyCallback,
}) async {
  if (_log.isDebugEnabled) {
    _log.debug('headless background turn START session=$sessionId');
  }
  final outcome = await runHeadlessSessionTurn(
    container,
    sessionId: sessionId,
    databasePath: databasePath,
    novel: novel,
    seed: seed,
    seedAlreadyAdded: seedAlreadyAdded,
    notifyCallback: notifyCallback,
  );
  if (_log.isDebugEnabled) {
    _log.debug(
      'headless background turn END session=$sessionId '
      'status=${outcome.status.name}',
    );
  }
}
