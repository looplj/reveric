// 职责: 复用 chat 编排执行一轮聊天 turn（组装 AiClient/Orchestrator Agent、跑事件循环、记录模型 Token 用量并增量落库），供聊天面板与后台会话 共用。
// 关联文件:
//   lib/desktop/widgets/ai/chat/runtime.dart
//   lib/desktop/widgets/ai/chat/agent_factory.dart
//   lib/shared/services/ai/agent_message_mapping.dart
//   lib/shared/services/ai/agent_skills_run_command_handler.dart
//   lib/shared/services/ai/subagents_run_command_handler.dart
//   lib/shared/services/ai/context_message_matcher.dart
//   lib/shared/services/ai/context_summarizer.dart
//   lib/shared/services/ai/usage_hook.dart
//   lib/shared/services/bundled_control_skills.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/providers/spawn_agent_run_providers.dart
//   lib/shared/providers/subagent_providers.dart
//   lib/shared/agent/agent.dart
//   lib/shared/agent/agent_context_manager.dart
//   lib/shared/agent/client/provider_history_preflight.dart
//   lib/shared/models/models_catalog.dart
//   lib/shared/models/queued_chat_message.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'chat_attachments.dart';
import '../../providers/mcp_providers.dart';
import 'mcp/agent_dispatcher.dart';
import 'package:reveric/shared/utils/ai_error.dart';
import 'dart:async';
import '../../providers/plugin_providers.dart';
import '../plugins/agent_dispatcher.dart';
import '../../providers/editing.dart';
import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../providers/async_read.dart';
import '../../agent/agent.dart';
import '../../agent/agent_context_manager.dart';
import '../../agent/agent_event.dart';
import '../../agent/agent_hook.dart';
import '../../agent/client.dart';
import '../../agent/client/provider_history_preflight.dart'
    show ProviderHistoryValidationException;
import '../../agent/client/trace_headers_http_client.dart'
    show buildTraceSessionHeaders;
import '../../agent/hooks/todo_continuation_hook.dart';
import '../../agent/hooks/trace_hook.dart';
import '../../agent/message.dart';
import '../../database/app_database.dart' hide AiChatSession;
import '../../database/novel_content_database.dart';
import '../../localization/ai_run_failure_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../models/map_studio_nav.dart' show mapTopLevelWorldOf;
import '../../models/agent_skill.dart';
import '../../models/agent_skill_reference.dart';
import '../../models/ai_chat_models.dart';
import '../../models/ai_run_failure.dart';
import '../../models/novel_agent_skill.dart';
import '../../models/ai_provider.dart';
import '../../models/ai_session_mode.dart';
import '../../models/models_catalog.dart';
import '../../models/queued_chat_message.dart';
import '../../utils/storage_paths.dart';
import '../../models/subagent.dart';
import '../../heuristic/chat_next_action.dart';
import '../../providers/ai_providers.dart';
import '../../providers/tool_operations.dart';
import '../../providers/codemode_provider.dart';
import '../../providers/ai_mode_processing.dart';
import '../system_notification_service.dart';
import '../../providers/settings_navigation.dart';
import 'pending_ask_user.dart';
import '../../providers/canvas_providers.dart' show canvasAiActivityProvider;
import '../../providers/map_agent_providers.dart';
import '../../providers/maps_providers.dart';
import '../../providers/novel_agent_skill_providers.dart';
import '../../providers/novel_providers.dart';
import '../../providers/settings_providers.dart';
import '../../providers/subagent_providers.dart';
import '../../providers/todo_providers.dart';
import '../../providers/trace_providers.dart';
import '../../providers/usage_query_providers.dart';
import '../../services/bundled_control_skills.dart';
import 'media/production.dart';
import '../production/canvas_service.dart';
import '../storyboard/service.dart';
import '../../providers/production_media.dart';
import '../../providers/production_images.dart';
import '../../providers/production_audio.dart';
import '../../providers/video_tasks.dart';
import 'agent_message_mapping.dart';
import 'agent_skills_run_command_handler.dart';
import 'subagents_run_command_handler.dart';
import 'ai_service_config.dart';
import 'chat.dart';
import 'image.dart';
import 'chat_agent_tool_dispatcher.dart';
import 'codemode/orchestrator.dart';
import 'codemode/tool.dart';
import 'chat_turn_outcome.dart';
import 'context_summarizer.dart';
import 'usage_hook.dart';
import 'prompts/ai_prompt_service.dart';
import 'prompts/use_cases/chat_prompt_use_case.dart';
import 'run_command_parser.dart';
import 'spawn_agent_handler.dart';
import 'tool_result_payloads.dart';
import 'sessions/run_command_handler.dart';
import 'tool_error_normalize.dart';
import '../working_overlay.dart'
    show workingChangeSourceAi, workingChangeStatusActive;
import 'tools.dart';

final _log = AppLogger.forModule('ChatTurnRunner');

/// 等待全局 SubAgent 真源完成加载，再生成本轮可执行列表。
///
/// UI 的同步合并 provider 在首次加载期间会暂时返回空列表；turn 执行边界不能
/// 把该 loading 快照固化进长生命周期 Agent，否则 SpawnAgent 会误报无可用 Agent。
Future<List<SubAgent>> loadRuntimeChatSubAgents(
  ProviderContainer container,
) async {
  final agents = await container.read(globalSubAgentsProvider.future);
  final available = agents
      .where((agent) => agent.enabled && agent.mode == AiSessionMode.chat.value)
      .toList(growable: false);
  return [...available]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
}

void _logRawToolPath({
  required int? requestId,
  required String event,
  required String toolName,
  required String callId,
  required Map<String, dynamic> arguments,
}) {
  final rawPath = arguments['path'];
  if (rawPath is! String) {
    return;
  }
  _log.info(
    'requestId=$requestId $event tool=$toolName callId=$callId rawPath=$rawPath',
  );
}

String? _imageToolNameForToolCall(String toolName, Map<String, dynamic> args) {
  if (toolName != 'Run') {
    return null;
  }
  return imageToolNameForRunArguments(args);
}

String? _imageToolNameForRunResult(Map<String, dynamic>? result) {
  final parsed = ParsedRunCommand.parse(result?['command']?.toString() ?? '');
  return imageToolNameForRunArguments({
    'command': parsed.topLevel,
    'subcommand': parsed.subcommand,
  });
}

String? _storedImageResultPath(Map<String, dynamic>? result, String workId) {
  final path = result?['local_path'] as String?;
  if (path == null ||
      _imageToolNameForRunResult(result) == null ||
      RevericPaths.contextForStoredPath(path).isAbsolute(path)) {
    return path;
  }
  return '${RevericPaths.fileWorkspaceDirectory(workId)}/$path';
}

Map<String, dynamic> _novelToolSnapshot(Novel n) {
  return <String, dynamic>{
    'title': n.title,
    'author_name': n.authorName,
    'description': n.description,
    'category': n.category,
    'status': n.status,
    'word_count': n.wordCount,
    'tags': n.tags,
  };
}

List<String>? _coerceNovelTagsField(Object? raw) {
  if (raw is List) {
    return raw
        .map((e) => e.toString().trim())
        .where((t) => t.isNotEmpty)
        .toList();
  }
  if (raw is String) {
    return raw
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
  }
  return null;
}

/// 工具结果中的 `_metadata`（UI 辅助数据，不会发给模型）。
Map<String, dynamic>? _toolMetadataFromResult(Map<String, dynamic>? result) {
  final meta = result?['_metadata'];
  return meta is Map ? meta.cast<String, dynamic>() : null;
}

/// 图片应用目标对象 id：优先取 `_metadata`，回退到结果顶层字段（直接图片工具）。
({String? characterId, String? itemId}) _imageTargetFromResult(
  Map<String, dynamic>? result,
) {
  final meta = _toolMetadataFromResult(result);
  String? pick(String key) {
    final fromMeta = meta?[key]?.toString().trim();
    if (fromMeta != null && fromMeta.isNotEmpty) {
      return fromMeta;
    }
    final fromResult = result?[key]?.toString().trim();
    if (fromResult != null && fromResult.isNotEmpty) {
      return fromResult;
    }
    return null;
  }

  return (characterId: pick('character_id'), itemId: pick('item_id'));
}

void _syncRunToolCallBlock(
  AiChatSession sessionNotifier, {
  required String callId,
  required String toolName,
  required Map<String, dynamic> args,
  required int? requestId,
  String? thoughtSignature,
  Map<String, dynamic>? metadata,
}) {
  if (toolName != 'Run') {
    sessionNotifier.upsertToolCallBlock(
      AiToolCallBlock(
        id: 'block_$callId',
        callId: callId,
        toolName: toolName,
        arguments: args,
        metadata: metadata,
        requestId: requestId,
        status: AiToolCallStatus.running,
        thoughtSignature: thoughtSignature,
      ),
    );
    return;
  }
  final resolution = resolveRunCommandUi(args);
  if (resolution.imageToolName != null) {
    final prompt = _promptForToolCall(args);
    sessionNotifier.upsertImageBlock(
      AiImageBlock(
        id: 'img_$callId',
        prompt: prompt,
        toolName: resolution.imageToolName!,
        characterId: resolution.parsed?.option('character'),
        itemId: resolution.parsed?.option('item'),
        status: AiImageStatus.generating,
      ),
    );
    // 工具块保留：UI 由图片卡代替它展示，历史回放靠它把 tool_use / tool_result
    // 发回模型，删掉后模型会认为自己从未调用过生图。
  }
  sessionNotifier.upsertToolCallBlock(
    AiToolCallBlock(
      id: 'block_$callId',
      callId: callId,
      toolName: toolName,
      arguments: args,
      metadata: metadata,
      requestId: requestId,
      status: AiToolCallStatus.running,
      thoughtSignature: thoughtSignature,
    ),
  );
}

String _promptForToolCall(Map<String, dynamic> args) {
  final prompt = (args['prompt'] as String? ?? '').trim();
  if (prompt.isNotEmpty) {
    return prompt;
  }
  final options = args['options'];
  if (options is Map) {
    return options['prompt']?.toString().trim() ?? '';
  }
  return '';
}

List<String> _allowedToolNamesForMode(
  AgentToolDispatcher toolManager,
  AiSessionMode mode,
) {
  return toolManager
      .allToolNames()
      .where(mode.canUseTool)
      .toList(growable: false);
}

/// 画布不再有专用工具，也就不再需要按页面门控工具列表：画布走
/// `/canvas/{name}/...` 路径，由常驻的 Read/Create/Write/Edit/Remove 承载。
List<String> _resolveOrchestratorAllowedTools(
  AgentToolDispatcher? toolManager,
  AiSessionMode mode,
) {
  return toolManager != null
      ? _allowedToolNamesForMode(toolManager, mode)
      : defaultAgentToolNames();
}

Future<List<AgentMessage>> _convertToAgentMessages(List<AiMessage> messages) =>
    restoreAgentMessages(messages);

List<AiMessage> _buildAgentHistory(List<AiMessage> messages) {
  final scopedMessages = messagesSinceLatestCompact(messages);
  return scopedMessages
      .where((message) => !message.isStreaming)
      .where((message) => message.role != AiMessageRole.system)
      .map(
        (message) => message.copyWith(
          content: _stripHandoffTags(message.effectiveText),
          isStreaming: false,
        ),
      )
      .toList(growable: false);
}

final _handoffTagPattern = RegExp(r'<(?:agent|session)-handoff\b[^>]*/>\s*');
final _sessionReferenceTagPattern = RegExp(
  r'''<user-remind\b(?=[^>]*\btype\s*=\s*(['"])session\1)[^>]*>.*?</user-remind>\s*''',
  multiLine: true,
  dotAll: true,
);

String _stripHandoffTags(String content) {
  return content
      .replaceFirst(_handoffTagPattern, '')
      .replaceAll(_sessionReferenceTagPattern, '')
      .trim();
}

String _userFriendlyError(
  Object error, {
  required String fallback,
  String? providerId,
}) {
  if (error is AgentProcessException) {
    return localizeAiRunFailure(error.failure.withProviderId(providerId), tr);
  }
  // 本地历史预检失败：请求未发出，当前会话历史已损坏，重试无效，引导新开会话。
  if (error is ProviderHistoryValidationException) {
    return tr(LocaleKeys.aiBadRequest);
  }
  if (isContextLengthExceeded(error)) {
    return localizeAiRunFailure(
      AiRunFailure(
        kind: AiRunFailureKind.contextWindowExhausted,
        providerId: providerId,
        providerMessage: tryReadProviderMessage(error),
        providerCode: tryReadProviderErrorCode(error),
      ),
      tr,
    );
  }
  final statusCode = tryReadStatusCode(error);
  final providerMessage = tryReadProviderMessage(error);
  final providerCode = tryReadProviderErrorCode(error);
  if (statusCode != null) {
    return localizeAiRunFailure(
      AiRunFailure.http(
        statusCode: statusCode,
        providerId: providerId,
        providerMessage: providerMessage,
        providerCode: providerCode,
      ),
      tr,
    );
  }
  final providerFailureMessage = localizeAiRunFailure(
    AiRunFailure.requestFailed(
      providerId: providerId,
      providerMessage: providerMessage,
      providerCode: providerCode,
    ),
    tr,
  );
  if (providerMessage != null || providerCode != null) {
    return providerFailureMessage;
  }
  final raw = error.toString();
  if (raw.contains('API key') ||
      raw.contains('Unauthorized') ||
      raw.contains('401')) {
    return localizeAiRunFailure(
      AiRunFailure.http(statusCode: 401, providerId: providerId),
      tr,
    );
  }
  if (raw.contains('rate limit') || raw.contains('429')) {
    return tr(LocaleKeys.aiRateLimited);
  }
  if (raw.contains('timeout') || raw.contains('Timeout')) {
    return tr(LocaleKeys.aiRequestTimeout);
  }
  if (raw.contains('SocketException') || raw.contains('Connection refused')) {
    return tr(LocaleKeys.aiNetworkError);
  }
  if (raw.contains(' 502 ') || raw.contains(' 503 ')) {
    return tr(LocaleKeys.aiServiceOverloaded);
  }
  if (raw.contains('BadRequestException') || raw.contains(' 400 ')) {
    return tr(LocaleKeys.aiBadRequest);
  }
  if (raw.contains('402') && raw.contains('Payment')) {
    return localizeAiRunFailure(
      AiRunFailure.http(statusCode: 402, providerId: providerId),
      tr,
    );
  }
  // 识别供应商或网关返回的余额、配额不足信息。
  if (raw.contains('credit.insufficient') ||
      raw.contains('insufficient_quota') ||
      raw.contains(' 402 ')) {
    return localizeAiRunFailure(
      AiRunFailure.http(statusCode: 402, providerId: providerId),
      tr,
    );
  }
  if (raw.contains('PermissionDeniedException') ||
      raw.contains('Forbidden') ||
      raw.contains('403')) {
    return tr(LocaleKeys.aiAccessDenied);
  }
  if (raw.contains('NotFoundException') || raw.contains('404')) {
    return tr(LocaleKeys.aiNotFound);
  }
  if (raw.contains('412') && raw.contains('Precondition')) {
    return tr(LocaleKeys.aiBadRequest);
  }
  if (raw.contains('UnprocessableEntityException') || raw.contains('422')) {
    return tr(LocaleKeys.aiBadRequest);
  }
  return fallback;
}

class _ChatSkillContext {
  const _ChatSkillContext({
    required this.summaries,
    required this.content,
    required this.loader,
  });

  static const empty = _ChatSkillContext(
    summaries: <AgentSkillSummary>[],
    content: <String, String>{},
    loader: null,
  );

  final List<AgentSkillSummary> summaries;
  final Map<String, String> content;
  final Future<AgentSkillLoadResult?> Function(String name)? loader;
}

/// 复用 chat 编排跑一轮 turn。面板与后台会话 共用同一份执行逻辑。
///
/// 把面板特有的交互行为以可注入 hook 暴露：
/// - [askUserHandler]：AskUser 工具回调；为 null 时走面板交互式 block，后台 Run 注入即时自动处理。
/// - [onComposerWarning]：供应商余额不足等可恢复提示；面板写入 composer notice，后台日志丢弃。
/// - [takeQueuedMessage]：用户选择「立刻发送」后的队列接力（`AgentNextTurnApplied`）；
///   入参为本轮实际运行的 session id（迁移后与面板 scope 可能不同），读取并清空该
///   session runtime 上 staged 的下一轮完整消息，后台恒 null。
/// - [onAgentContextCompacted]：每次成功压缩后立刻同步上下文快照，避免同一 turn 的多次摘要被最终快照覆盖。
/// - [onAgentContextSettled]：一轮结束后同步压缩上下文到 UI 会话；面板调 `_syncPersistedContextState`。
class ChatTurnRunner {
  ChatTurnRunner({
    required this.container,
    required this.novel,
    required this.databasePath,
    required this.aiPromptService,
    required AiSessionContext promptContext,
    this.onComposerWarning,
    this.takeQueuedMessage,
    this.onAgentContextCompacted,
    this.onAgentContextSettled,
    this.askUserHandler,

    this.nextActionEnvironment = const ChatNextActionEnvironment(),
    this.supportsNextActionSuggestions = false,
    this.notifyCallback,
    this.sourceSessionId,
  }) : promptContext = promptContext
           .copyWith(databasePath: databasePath)
           .withWork(novel);

  final ProviderContainer container;
  final Novel novel;
  final String? databasePath;
  final AiPromptService aiPromptService;
  final AiSessionContext promptContext;
  final void Function(String message)? onComposerWarning;
  final QueuedChatMessage? Function(String? sessionId)? takeQueuedMessage;
  final void Function(Agent agent)? onAgentContextCompacted;
  final void Function(Agent agent)? onAgentContextSettled;
  final Future<AskUserResult> Function(AskUserRequest request)? askUserHandler;

  /// 建议开关等环境事实，由宿主（面板）解析后注入；只用于决定是否下发工具。
  final ChatNextActionEnvironment nextActionEnvironment;

  /// 宿主是否提供跳转能力。false（后台会话 等无 UI 场景）时工具不下发。
  final bool supportsNextActionSuggestions;
  late final Future<List<SubAgent>> _availableSubAgents =
      loadRuntimeChatSubAgents(container);
  final AiRunNotifyCallback? notifyCallback;
  final String? sourceSessionId;

  Future<AiImageGenerationResult> _generateImage(
    String prompt, {
    String? model,
    String? size,
    String? quality,
    String? complexity,
  }) => container.withProvider(imageGenerationCallbackProvider(novel.id), (
    callback,
  ) async {
    if (callback == null) {
      throw AiImageGenerationException(tr(LocaleKeys.aiNoImageModelConfigured));
    }
    return callback(
      prompt,
      model: model,
      size: size,
      quality: quality,
      complexity: complexity,
    );
  });

  Future<AiImageGenerationResult> _editImage(
    String prompt, {
    required String imageData,
    String? model,
  }) => container.withProvider(imageEditCallbackProvider(novel.id), (
    callback,
  ) async {
    if (callback == null) {
      throw AiImageGenerationException(tr(LocaleKeys.aiNoImageModelConfigured));
    }
    return callback(prompt, imageData: imageData, model: model);
  });

  Future<AskUserResult> _askUser(
    String? sessionId,
    AskUserRequest request,
  ) async {
    final handler = askUserHandler;
    if (handler != null) {
      return handler(request);
    }
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    final tracker = container.read(aiModeProcessingTrackerProvider.notifier);
    // Both chat hosts register visibility under the chat surface.
    const mode = AiSessionMode.chat;
    void notify(PendingAskUser pending, {required bool reminder}) {
      unawaited(
        SystemNotificationService.show(
          identifier: 'ask_user_${mode.value}_${sessionId}_${pending.blockId}',
          title: tr(
            reminder
                ? LocaleKeys.aiAskUserReminderTitle
                : LocaleKeys.aiAskUserNotificationTitle,
          ),
          body: tr(
            reminder
                ? LocaleKeys.aiAskUserReminderBody
                : LocaleKeys.aiAskUserNotificationBody,
            namedArgs: {'minutes': PendingAskUser.timeout.inMinutes.toString()},
          ),
          shouldShow: () =>
              identical(
                runtime.pendingAskUserRequests[request.callId],
                pending,
              ) &&
              pending.notificationIsCurrent(reminder: reminder),
        ),
      );
    }

    final pending = runtime.registerAskUser(
      request,
      onReminder: (pending) => notify(pending, reminder: true),
    );
    if (!tracker.isViewingSession(mode: mode, sessionId: sessionId)) {
      notify(pending, reminder: false);
    }
    return pending.future;
  }

  /// 挂载已裁决的下一步建议。
  ///
  /// 与 [_askUser] 平行，但**不建 Completer、不 await** —— 建议必须在 turn 结束
  /// 之后出现，绝不能挂起 turn（方案核心原则 6）。
  void _suggestNextAction(
    String? sessionId,
    String callId,
    List<Map<String, dynamic>> suggestions,
  ) {
    if (suggestions.isEmpty) {
      return;
    }
    container
        .read(aiChatSessionProvider(sessionId).notifier)
        .addSuggestNextActionBlock(
          AiSuggestNextActionBlock(
            id: 'suggest_$callId',
            callId: callId,
            suggestions: suggestions,
          ),
        );
  }

  void _configureChatToolCallbacks({required AiToolManager toolManager}) {
    final operationRuntime = container.read(
      aiChatRuntimeProvider(
        toolManager.sourceSessionId ?? toolManager.sessionId,
      ).notifier,
    );
    final operationDatabasePath = databasePath;
    toolManager.productionStyleServiceBuilder = operationDatabasePath == null
        ? null
        : () async => ProductionCanvasService(
            StoryboardService(
              container
                  .read(novelContentServiceProvider(operationDatabasePath))
                  .database,
              contentKind: novel.contentKind,
            ),
            container.read(mediaLibraryServiceProvider),
            novel.id,
          );
    // 审批类命令在所有平台都经过会话运行管理器；宿主不提供媒体操作时媒体类 Run 命令不注册。
    final media = container.read(mediaOperationsSupportedProvider);
    toolManager.operationHost = ToolOperationHost(
      operationRuntime.operations,
      openSettings: container.read(settingsNavigationProvider).open,
      media: media,
      production: !media || operationDatabasePath == null
          ? null
          : () async => ProductionToolHost(
              canvas: await toolManager.productionStyleServiceBuilder!(),
              images: container.read(imageTaskServiceProvider),
              audio: container.read(audioTaskServiceProvider),
              video: () => container.read(videoTaskServiceProvider.future),
              results: container.read(productionResultServiceProvider),
              editingSessions: container.read(editingSessionsProvider),
              assets: container.read(providerAssetServiceProvider),
            ),
    );
    if (operationDatabasePath != null) {
      operationRuntime.persistOperation = container
          .read(
            aiSessionPersistenceServiceProvider(
              novelId: novel.id,
              databasePath: operationDatabasePath,
            ),
          )
          .saveToolOperation;
    }
    final history = container
        .read(
          aiChatSessionProvider(
            toolManager.sourceSessionId ?? toolManager.sessionId,
          ),
        )
        .messages;
    operationRuntime.operations.restore([
      for (final message in history)
        for (final block in message.blocks.whereType<AiToolCallBlock>())
          for (final snapshot
              in (block.metadata?['operations'] as List? ?? const []))
            Map<String, dynamic>.from(snapshot as Map),
    ]);
    // 子 Agent 的运行记录保存在子会话历史里；父会话重开后按自己发起的子会话索引回来。
    if (operationDatabasePath != null &&
        !operationRuntime.operations.childHistoryRestored) {
      operationRuntime.operations.childHistoryRestored = true;
      unawaited(
        container
            .read(
              aiSessionPersistenceServiceProvider(
                novelId: novel.id,
                databasePath: operationDatabasePath,
              ),
            )
            .loadChildOperationSnapshots(history)
            .then(operationRuntime.operations.restore)
            .catchError((Object error, StackTrace stackTrace) {
              _log.error(
                '[ToolOperation] restoring sub-agent operations failed',
                error: error,
                stackTrace: stackTrace,
              );
            }),
      );
    }
    toolManager.todoWriteCallback = (todos, targetSessionId) async {
      return container
          .read(sessionTodosProvider(targetSessionId).notifier)
          .saveTodos(todos);
    };
    toolManager.mapDraftCommandCallback = (draft) async {
      final path = databasePath;
      if (path == null || path.trim().isEmpty) {
        return <String, dynamic>{
          'ok': false,
          'output': '[error] Map cartographer is unavailable in this session.',
          'error': 'map cartographer unavailable',
          'error_code': ToolErrorCode.unavailable.name,
        };
      }
      // 目标可以是顶层 world，也可以是它的子地点（子地图）；草案按目标地点 id 投递，
      // 两端制图师都按当前地图的所属地点取草案。
      final locations = await container
          .read(locationsServiceProvider(path))
          .getLocations();
      final locationById = {
        for (final location in locations) location.id: location,
      };
      final target = locationById[draft.worldId];
      if (target == null) {
        return <String, dynamic>{
          'ok': false,
          'output': '[error] Location not found: ${draft.worldId}',
          'error': 'location not found',
          'error_code': ToolErrorCode.invalid_argument.name,
        };
      }
      final root = mapTopLevelWorldOf(target.id, locationById);
      if (root == null) {
        return <String, dynamic>{
          'ok': false,
          'output':
              '[error] Map drafts require a top-level world or one of its '
              'descendant locations.',
          'error': 'invalid map target',
          'error_code': ToolErrorCode.invalid_argument.name,
        };
      }
      container
          .read(mapDesignDraftsProvider.notifier)
          .submit(databasePath: path, draft: draft);
      return <String, dynamic>{
        'ok': true,
        'output': 'Map design draft is ready for review in Cartographer.',
        'location_id': target.id,
        'location_name': target.name,
        'world_id': root.id,
        'world_name': root.name,
      };
    };
  }

  @visibleForTesting
  Future<
    ({List<String> names, Future<AgentSkillLoadResult?> Function(String)? load})
  >
  skillContextForTest() async {
    final context = await _loadCurrentSkillContext(promptContext.contentKind);
    return (
      names: context.summaries.map((skill) => skill.name).toList(),
      load: context.loader,
    );
  }

  Future<_ChatSkillContext> _loadCurrentSkillContext(String contentKind) async {
    // 技能应用全局：读取全局可执行 NovelAgentSkill；未命中 name 且该 name ∈
    // bundledControlCallNames 时回落到 Bundled Control Skills。同名
    // NovelAgentSkill（含 disabled/blocked）视为命中，跳过 bundled fallback
    // （方案 §3 决策 D：用户可显式安装同名 NovelAgentSkill 覆盖 bundled 默认行为）。
    final List<NovelAgentSkillModel> skills;
    try {
      skills = await container.read(installedAgentSkillsProvider.future);
    } catch (e) {
      _log.error('Failed to load skills', error: e);
      return _ChatSkillContext.empty;
    }
    final executable = skills.where((skill) => skill.isExecutable).toList();
    final installedNames = <String>{for (final skill in skills) skill.name};

    // 加载未被 NovelAgentSkill 覆盖的 Bundled Control Skills 作为默认 fallback。
    // Fail loud: BundledControlSkillsLoader 在 asset/frontmatter 异常时抛 StateError，
    // 不在此处捕获（遵循 .agents/rules/error-handling.md 不静默降级）。
    final bundledFallback = <BundledControlSkill>[];
    for (final callName in bundledControlCallNames) {
      if (installedNames.contains(callName)) {
        continue;
      }
      final bundled = await const BundledControlSkillsLoader().findByCallName(
        rootBundle,
        callName,
        contentKind: contentKind,
      );
      if (bundled != null) {
        bundledFallback.add(bundled);
      }
    }

    final content = <String, String>{
      for (final skill in executable) skill.name: skill.prompt,
      for (final skill in bundledFallback) skill.callName: skill.prompt,
    };

    Future<AgentSkillLoadResult?> loader(String name) async {
      // NovelAgentSkill 命中（含 disabled/blocked）优先级高于 bundled。
      final current = await container.read(installedAgentSkillsProvider.future);
      for (final skill in current) {
        if (skill.name == name) {
          if (!skill.isExecutable) {
            return null;
          }
          return AgentSkillLoadResult(
            instructions: skill.prompt,
            references: [
              for (final ref in skill.references)
                AgentSkillReferenceDescriptor(path: ref.path),
            ],
          );
        }
      }
      // Bundled Control Skills fallback：仅对 bundledControlCallNames 中的固定
      // call_name 生效。
      // Fail loud: StateError 由 BundledControlSkillsLoader 抛出，不在此处捕获。
      if (bundledControlCallNames.contains(name)) {
        final bundled = await const BundledControlSkillsLoader().findByCallName(
          rootBundle,
          name,
          contentKind: contentKind,
        );
        if (bundled == null) {
          return null;
        }
        return AgentSkillLoadResult(
          instructions: bundled.prompt,
          references: [
            for (final reference in bundled.references)
              AgentSkillReferenceDescriptor(path: reference.path),
          ],
        );
      }
      return null;
    }

    return _ChatSkillContext(
      summaries: <AgentSkillSummary>[
        ...executable.map(
          (skill) => AgentSkillSummary(
            name: skill.name,
            whenToUse: skill.whenToUse,
            description: skill.description,
          ),
        ),
        ...bundledFallback.map(
          (skill) => AgentSkillSummary(
            name: skill.callName,
            whenToUse: skill.whenToUse,
            description: skill.description,
          ),
        ),
      ],
      content: Map<String, String>.unmodifiable(content),
      loader: loader,
    );
  }

  List<AgentHook> _usageHooks({
    required String? sessionId,
    required String source,
  }) {
    final initialSession = container.read(aiChatSessionProvider(sessionId));
    if (initialSession.providerId == null || initialSession.model == null) {
      return const [];
    }
    final service = container.read(usageServiceProvider);
    return [
      UsageHook(
        service: service,
        providerId: () =>
            container.read(aiChatSessionProvider(sessionId)).providerId,
        model: () => container.read(aiChatSessionProvider(sessionId)).model,
        sessionId: () =>
            container.read(aiChatSessionProvider(sessionId)).sessionId ??
            sessionId,
        novelId: () => novel.id,
        source: source,
        onUsageChanged: () {
          container.invalidate(todayUsageProvider);
          container.invalidate(thisMonthUsageProvider);
          container.invalidate(lastNDaysUsageProvider(30));
        },
      ),
    ];
  }

  List<AgentHook> _traceHooks({required String? sessionId}) {
    final initialSession = container.read(aiChatSessionProvider(sessionId));
    if (initialSession.model == null) {
      return const [];
    }
    final reporter = container.read(traceReporterServiceProvider);
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    return buildTraceHooks(
      reporter: reporter,
      sessionId: () =>
          container.read(aiChatSessionProvider(sessionId)).sessionId ??
          sessionId,
      model: () => container.read(aiChatSessionProvider(sessionId)).model,
      providerId: () =>
          container.read(aiChatSessionProvider(sessionId)).providerId,
      sessionMode: initialSession.sessionMode.value,
      cancelSource: () => runtime.lastCancellationSource,
    );
  }

  TodoContinuationHook _todoContinuationHook({required String? sessionId}) {
    final reporter = container.read(traceReporterServiceProvider);
    final sessionMode = container
        .read(aiChatSessionProvider(sessionId))
        .sessionMode
        .value;
    return TodoContinuationHook(
      enabled: false,
      loadTodos: () =>
          container.readFuture(sessionTodosProvider(sessionId).future),
      onUnfinishedAtDone: (snapshot) async {
        final session = container.read(aiChatSessionProvider(sessionId));
        final traceSessionId = session.sessionId ?? sessionId;
        final model = session.model;
        if (traceSessionId == null || model == null) {
          return;
        }
        await reporter.onTodoUnfinishedAtDone(
          traceSessionId,
          model,
          providerId: session.providerId,
          sessionMode: sessionMode,
          snapshot: snapshot,
        );
      },
    );
  }

  Future<void> reportSessionStart(AiChatSessionState session) async {
    final sessionId = session.sessionId;
    final model = session.model;
    if (sessionId == null || sessionId.isEmpty || model == null) {
      return;
    }
    _log.info(
      'trace onSessionStart sessionId=$sessionId '
      'model=$model mode=${session.sessionMode.value}',
    );
    await container
        .read(traceReporterServiceProvider)
        .onSessionStart(
          sessionId,
          model,
          sessionMode: session.sessionMode.value,
        );
  }

  Future<AiClient?> resolveAiService({
    int? requestId,
    required String? sessionId,
  }) async {
    if (sessionId == null || isTemporaryAiChatSessionId(sessionId)) {
      _log.error(
        'resolveAiService rejected non-persisted sessionId=$sessionId',
      );
      return null;
    }
    final session = container.read(aiChatSessionProvider(sessionId));
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    if (session.providerId == null || session.model == null) {
      _log.warning(
        'resolveAiService null: session missing provider/model '
        'sessionId=$sessionId provider=${session.providerId} '
        'model=${session.model}',
      );
      return null;
    }
    final config = container.read(
      currentAiConfigProvider(
        providerId: session.providerId,
        model: session.model,
      ),
    );
    if (config == null || !config.isValid) {
      _log.warning(
        'resolveAiService null: config invalid sessionId=$sessionId '
        'provider=${session.providerId} model=${session.model} '
        'hasConfig=${config != null} isValid=${config?.isValid}',
      );
      return null;
    }
    final availableSubAgents = await _availableSubAgents;

    final path = databasePath;
    final contentService = path == null || path.isEmpty
        ? null
        : container.read(novelContentServiceProvider(path));
    final workingOverlay = path == null || path.isEmpty
        ? null
        : container.read(workingOverlayServiceProvider(path));
    final locationsService = path == null || path.isEmpty
        ? null
        : container.read(locationsServiceProvider(path));
    final crossWorkAccess =
        path == null || path.isEmpty || contentService == null
        ? null
        : CrossWorkResolver(
            appDatabase: container.read(appDatabaseProvider),
            currentDatabasePath: path,
            currentContentService: contentService,
            currentWorkId: novel.id,
          );
    final sessionNotifier = container.read(
      aiChatSessionProvider(sessionId).notifier,
    );

    final currentSessionId = session.sessionId ?? sessionId;
    Map<String, String> traceHeadersProvider() => buildTraceSessionHeaders(
      sessionId: currentSessionId,
      sessionMode: session.sessionMode.value,
    );

    final httpClient = runtime.httpClientFor(config);
    final service = AiClient(
      config,
      chatModel: session.model!,
      novelContentService: contentService,
      workingOverlayService: workingOverlay,
      crossWorkAccess: crossWorkAccess,
      providerReader: () async => (await container.read(
        appSettingsProvider.future,
      )).aiSettings.providers,
      sessionsCommandCallback: crossWorkAccess == null
          ? null
          : SessionsRunCommandHandler(
              database: container.read(appDatabaseProvider),
              access: crossWorkAccess,
              workId: novel.id,
            ).run,
      sessionContext: promptContext,
      sessionId: currentSessionId,
      sourceSessionId: sourceSessionId ?? currentSessionId,

      httpClient: httpClient,
      traceHeadersProvider: traceHeadersProvider,
      createLocationCallback: locationsService == null
          ? null
          : ({
              required String name,
              String? description,
              String? type,
              String? parentId,
            }) {
              return locationsService.createLocation(
                name: name,
                description: description ?? '',
                type: type == null || type.isEmpty ? locationTypeGeneric : type,
                parentId: parentId,
              );
            },
      novelReader: () async {
        final n = await container.read(novelActionsProvider).getNovel(novel.id);
        if (n == null) {
          return null;
        }
        return _novelToolSnapshot(n);
      },
      novelWriter: (fields) async {
        // 封面不在工具字段里（AI 读不到也写不了），封面只由 UI 的
        // 「设为封面」落库。Metadata writes patch only supplied fields,
        // so consecutive tool calls cannot overwrite siblings from a stale snapshot.
        final actions = container.read(novelActionsProvider);
        await actions.updateNovelMetadata(
          novelId: novel.id,
          title: fields['title'] as String?,
          authorName: fields['author_name'] as String?,
          description: fields['description'] as String?,
          category: fields['category'] as String?,
          tags: _coerceNovelTagsField(fields['tags']),
        );
        // status 不属于 metadata patch，novelDao 是分开的 updateStatus；
        // 漏掉它会让 profile/status 报成功却不落库。
        final status = fields['status'] as String?;
        if (status != null) {
          await actions.updateNovelStatus(novelId: novel.id, status: status);
        }
      },
      novelDraftClearer: () =>
          container.read(novelActionsProvider).clearNovelDraft(novel.id),

      shouldExecuteTool: () {
        final currentRequestId = requestId;
        if (currentRequestId == null) {
          return true;
        }
        return !runtime.cancelledRequestIds.contains(currentRequestId);
      },
      interruptReason: () {
        final currentRequestId = requestId;
        if (currentRequestId == null) {
          return null;
        }
        if (runtime.cancelledRequestIds.contains(currentRequestId)) {
          return AiInterruptReason.cancel;
        }
        return null;
      },
      onToolCallRequested: (callId, toolName, args) {
        if (runtime.cancelledRequestIds.contains(requestId)) return;
        _syncRunToolCallBlock(
          sessionNotifier,
          callId: callId,
          toolName: toolName,
          args: args,
          requestId: requestId,
        );
      },
      onToolStarted: (callId, toolName, args, extra, _) {
        if (runtime.cancelledRequestIds.contains(requestId)) return;
        runtime.incrementToolExecutions();
        final imageToolName = _imageToolNameForToolCall(toolName, args);
        if (imageToolName != null) {
          _syncRunToolCallBlock(
            sessionNotifier,
            callId: callId,
            toolName: toolName,
            args: args,
            requestId: requestId,
          );
          return;
        }
        final existing = sessionNotifier.findToolCallByCallId(callId)?.$2;
        sessionNotifier.upsertToolCallBlock(
          AiToolCallBlock(
            id: 'block_$callId',
            callId: callId,
            toolName: toolName,
            arguments: args,
            requestId: requestId,
            status: existing?.status ?? AiToolCallStatus.running,
            targetPath:
                (extra?['targetPath'] as String?) ?? existing?.targetPath,
            diffOldText:
                (extra?['diffOldText'] as String?) ?? existing?.diffOldText,
            diffNewText:
                (extra?['diffNewText'] as String?) ?? existing?.diffNewText,
          ),
        );
      },
      onToolFinished: (callId, toolName, args, result, errorMessage) {
        runtime.decrementToolExecutions();
        if (runtime.cancelledRequestIds.contains(requestId)) return;
        final imageToolName =
            _imageToolNameForToolCall(toolName, args) ??
            _imageToolNameForRunResult(result);
        if (imageToolName != null) {
          final blockId = 'img_$callId';
          if (errorMessage != null) {
            sessionNotifier.patchImageBlock(
              blockId,
              status: AiImageStatus.error,
              errorMessage: errorMessage,
            );
          } else if (result?['success'] == true) {
            final target = _imageTargetFromResult(result);
            sessionNotifier.patchImageBlock(
              blockId,
              status: AiImageStatus.success,
              localFilePath: _storedImageResultPath(result, novel.id),
              assetId: result?['asset_id'] as String?,
              characterId: target.characterId,
              itemId: target.itemId,
            );
          } else {
            sessionNotifier.patchImageBlock(
              blockId,
              status: AiImageStatus.error,
              errorMessage:
                  result?['error'] as String? ?? 'Image generation failed',
            );
          }
        }
        sessionNotifier.patchToolCallByCallId(
          callId,
          status: aiToolResultStatus(result, errorMessage: errorMessage),
          result: result,
          metadata: _toolMetadataFromResult(result),
          errorMessage:
              errorMessage ??
              (result == null ? null : toolResultErrorMessage(result)),
        );
      },
      imageGenerationCallback:
          container.read(imageGenerationCallbackProvider(novel.id)) == null
          ? null
          : _generateImage,
      imageEditCallback:
          container.read(imageEditCallbackProvider(novel.id)) == null
          ? null
          : _editImage,
      subAgentListProvider: () => availableSubAgents,
      skillLoader: (slug) async => null,
      agentSkillsCommandCallback: (command) => AgentSkillsRunCommandHandler(
        container: container,
        contentKind: novel.contentKind,
      ).run(command),
      themesCommandCallback: (command) => container
          .read(appSettingsNotifierProvider.notifier)
          .runThemeCommand(command),
      subagentsCommandCallback: (command) =>
          SubagentsRunCommandHandler(container: container).run(command),

      notifyCallback: notifyCallback,
      askUserCallback: (request) => _askUser(sessionId, request),
      // 宿主不支持跳转，或用户关掉了建议时保持 null：工具既不注册也不下发 schema。
      suggestNextActionCallback:
          (supportsNextActionSuggestions &&
              nextActionEnvironment.suggestionsEnabled)
          ? (callId, suggestions) =>
                _suggestNextAction(sessionId, callId, suggestions)
          : null,
      canvasActivityReporter: (activity) =>
          container.read(canvasAiActivityProvider.notifier).report(activity),
    );
    await service.initialize();
    final toolManager = service.toolManager;
    if (toolManager != null) {
      _configureChatToolCallbacks(toolManager: toolManager);
    }
    return service;
  }

  Future<Agent?> getOrCreateChatAgent({required String? sessionId}) async {
    if (sessionId == null || isTemporaryAiChatSessionId(sessionId)) {
      _log.error(
        'getOrCreateChatAgent rejected non-persisted sessionId=$sessionId',
      );
      return null;
    }
    final session = container.read(aiChatSessionProvider(sessionId));
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    final cachedAgent = runtime.agent;
    if (cachedAgent != null) {
      return cachedAgent;
    }
    if (session.providerId == null || session.model == null) {
      _log.warning(
        'getOrCreateChatAgent null: session missing provider/model '
        'sessionId=$sessionId provider=${session.providerId} '
        'model=${session.model}',
      );
      return null;
    }
    final config = container.read(
      currentAiConfigProvider(
        providerId: session.providerId,
        model: session.model,
      ),
    );
    if (config == null || !config.isValid) {
      _log.warning(
        'getOrCreateChatAgent null: config invalid sessionId=$sessionId '
        'provider=${session.providerId} model=${session.model} '
        'hasConfig=${config != null} isValid=${config?.isValid}',
      );
      return null;
    }
    final availableSubAgents = await _availableSubAgents;

    final path = databasePath;
    final contentService = path == null || path.isEmpty
        ? null
        : container.read(novelContentServiceProvider(path));
    final workingOverlay = path == null || path.isEmpty
        ? null
        : container.read(workingOverlayServiceProvider(path));
    final locationsService = path == null || path.isEmpty
        ? null
        : container.read(locationsServiceProvider(path));
    final crossWorkAccess =
        path == null || path.isEmpty || contentService == null
        ? null
        : CrossWorkResolver(
            appDatabase: container.read(appDatabaseProvider),
            currentDatabasePath: path,
            currentContentService: contentService,
            currentWorkId: novel.id,
          );

    final sessionNotifier = container.read(
      aiChatSessionProvider(sessionId).notifier,
    );

    final currentSessionId = session.sessionId ?? sessionId;
    Map<String, String> traceHeadersProvider() => buildTraceSessionHeaders(
      sessionId: currentSessionId,
      sessionMode: session.sessionMode.value,
    );

    final httpClient = runtime.httpClientFor(config);
    final client = AiClient(
      config,
      chatModel: session.model!,
      reasoningEffort: session.reasoningEffort,
      novelContentService: contentService,
      workingOverlayService: workingOverlay,
      crossWorkAccess: crossWorkAccess,
      providerReader: () async => (await container.read(
        appSettingsProvider.future,
      )).aiSettings.providers,
      sessionsCommandCallback: crossWorkAccess == null
          ? null
          : SessionsRunCommandHandler(
              database: container.read(appDatabaseProvider),
              access: crossWorkAccess,
              workId: novel.id,
            ).run,
      sessionContext: promptContext,
      sessionId: currentSessionId,
      sourceSessionId: sourceSessionId ?? currentSessionId,

      httpClient: httpClient,
      traceHeadersProvider: traceHeadersProvider,
      createLocationCallback: locationsService == null
          ? null
          : ({
              required String name,
              String? description,
              String? type,
              String? parentId,
            }) {
              return locationsService.createLocation(
                name: name,
                description: description ?? '',
                type: type == null || type.isEmpty ? locationTypeGeneric : type,
                parentId: parentId,
              );
            },
      novelReader: () async {
        final n = await container.read(novelActionsProvider).getNovel(novel.id);
        if (n == null) {
          return null;
        }
        return _novelToolSnapshot(n);
      },
      novelWriter: (fields) async {
        final actions = container.read(novelActionsProvider);
        await actions.updateNovelMetadata(
          novelId: novel.id,
          title: fields['title'] as String?,
          authorName: fields['author_name'] as String?,
          description: fields['description'] as String?,
          category: fields['category'] as String?,
          tags: _coerceNovelTagsField(fields['tags']),
        );
        // 同上：status 走 novelDao 的 updateStatus，不在 metadata patch 里。
        final status = fields['status'] as String?;
        if (status != null) {
          await actions.updateNovelStatus(novelId: novel.id, status: status);
        }
      },
      novelDraftClearer: () =>
          container.read(novelActionsProvider).clearNovelDraft(novel.id),
      onToolCallRequested: (callId, toolName, args) {
        _syncRunToolCallBlock(
          sessionNotifier,
          callId: callId,
          toolName: toolName,
          args: args,
          requestId: null,
        );
      },
      onToolStarted: (callId, toolName, args, extra, _) {
        runtime.incrementToolExecutions();
        final imageToolName = _imageToolNameForToolCall(toolName, args);
        if (imageToolName != null) {
          _syncRunToolCallBlock(
            sessionNotifier,
            callId: callId,
            toolName: toolName,
            args: args,
            requestId: null,
          );
          return;
        }
        final existing = sessionNotifier.findToolCallByCallId(callId);
        sessionNotifier.upsertToolCallBlock(
          AiToolCallBlock(
            id: 'block_$callId',
            callId: callId,
            toolName: toolName,
            arguments: args,
            status: existing?.$2.status ?? AiToolCallStatus.running,
            targetPath:
                (extra?['targetPath'] as String?) ?? existing?.$2.targetPath,
            diffOldText:
                (extra?['diffOldText'] as String?) ?? existing?.$2.diffOldText,
            diffNewText:
                (extra?['diffNewText'] as String?) ?? existing?.$2.diffNewText,
          ),
        );
      },
      onToolFinished: (callId, toolName, args, result, errorMessage) {
        runtime.decrementToolExecutions();
        final imageToolName =
            _imageToolNameForToolCall(toolName, args) ??
            _imageToolNameForRunResult(result);
        if (imageToolName != null) {
          final blockId = 'img_$callId';
          if (errorMessage != null) {
            sessionNotifier.patchImageBlock(
              blockId,
              status: AiImageStatus.error,
              errorMessage: errorMessage,
            );
          } else if (result?['success'] == true) {
            final target = _imageTargetFromResult(result);
            sessionNotifier.patchImageBlock(
              blockId,
              status: AiImageStatus.success,
              localFilePath: _storedImageResultPath(result, novel.id),
              assetId: result?['asset_id'] as String?,
              characterId: target.characterId,
              itemId: target.itemId,
            );
          } else {
            sessionNotifier.patchImageBlock(
              blockId,
              status: AiImageStatus.error,
              errorMessage:
                  result?['error'] as String? ?? 'Image generation failed',
            );
          }
        }
        sessionNotifier.patchToolCallByCallId(
          callId,
          status: aiToolResultStatus(result, errorMessage: errorMessage),
          result: result,
          metadata: _toolMetadataFromResult(result),
          errorMessage:
              errorMessage ??
              (result == null ? null : toolResultErrorMessage(result)),
        );
      },
      askUserCallback: (request) => _askUser(sessionId, request),
      // 宿主不支持跳转，或用户关掉了建议时保持 null：工具既不注册也不下发 schema。
      suggestNextActionCallback:
          (supportsNextActionSuggestions &&
              nextActionEnvironment.suggestionsEnabled)
          ? (callId, suggestions) =>
                _suggestNextAction(sessionId, callId, suggestions)
          : null,
      skillLoader: (slug) async => null,
      agentSkillsCommandCallback: (command) => AgentSkillsRunCommandHandler(
        container: container,
        contentKind: novel.contentKind,
      ).run(command),
      themesCommandCallback: (command) => container
          .read(appSettingsNotifierProvider.notifier)
          .runThemeCommand(command),
      subagentsCommandCallback: (command) =>
          SubagentsRunCommandHandler(container: container).run(command),

      notifyCallback: notifyCallback,
      imageGenerationCallback:
          container.read(imageGenerationCallbackProvider(novel.id)) == null
          ? null
          : _generateImage,
      imageEditCallback:
          container.read(imageEditCallbackProvider(novel.id)) == null
          ? null
          : _editImage,
      canvasActivityReporter: (activity) =>
          container.read(canvasAiActivityProvider.notifier).report(activity),
      subAgentListProvider: () => availableSubAgents,
    );

    await client.initialize();

    final tm = client.toolManager;
    if (tm == null) {
      return null;
    }
    _configureChatToolCallbacks(toolManager: tm);

    // Smart context manager with LLM-based compaction.
    // 在模型上下文窗口达到 80% 时压缩，避免请求体先触及网关大小限制。
    final modelName = session.model;
    final catalogLimit = modelName != null
        ? lookupCatalogLimit(modelName)
        : null;
    final contextTokens = catalogLimit?.context ?? defaultContextTokenLimit;
    final outputFloor = catalogLimit?.output != null
        ? min(16000, catalogLimit!.output!)
        : 16000;
    final compactThreshold = compactThresholdForContextLimit(contextTokens);
    // Agent 按会话缓存，本行只在构建时打一次。
    _log.info(
      '[ctx] scope=chat model=$modelName context=$contextTokens '
      'compactAt=$compactThreshold',
    );
    final ctxMgr = SmartAgentContextManager(
      compactThreshold: compactThreshold,
      contextTokens: contextTokens,
      outputFloor: outputFloor,
    );
    Future<List<AgentMessage>> loadTodoContextSupplement() async {
      final todos = await container.readFuture(
        sessionTodosProvider(sessionId).future,
      );
      return [buildTodoContextSupplementMessage(todos)];
    }

    // 设计决策：压缩补充只恢复 Todo，不补日期和工作区提醒；这两类提醒由
    // ChatSessionController 的发送入口检查，本轮内压缩后不保证重新补齐。
    ctxMgr.contextSupplementProvider = loadTodoContextSupplement;
    final mode = session.sessionMode;
    final appSettings = await container.read(appSettingsProvider.future);

    // Load agent skills: progressive disclosure — only summaries in prompt,
    // full instructions loaded via Skill tool.
    final skillContext = await _loadCurrentSkillContext(
      promptContext.contentKind,
    );
    tm.skillLoader = skillContext.loader;
    tm.skillNamesProvider = () =>
        skillContext.summaries.map((skill) => skill.name).toList();

    // Read novel_onboarding eligibility from NovelStates. Only novels created
    // via the normal "new novel" path write this key; imported novels don't.
    final onboardingPath = databasePath;
    final novelOnboardingEligible = onboardingPath == null
        ? false
        : (await container
                      .read(novelContentDatabaseProvider(onboardingPath))
                      .novelStateDao
                      .get('novel_onboarding'))
                  ?.status ==
              'eligible';

    final systemPrompt = aiPromptService.chatPanel.system(
      ChatPanelPromptInput(
        context: promptContext,
        mode: mode,
        codemodeAvailable: mode == AiSessionMode.chat,
        systemInstruction: aiPromptService.chatPanel.orchestratorInstruction(),
        availableSubAgents: availableSubAgents,
        availableSkills: skillContext.summaries,
        skillContent: skillContext.content,
        novel: novel,
        identityPrompt: appSettings.aiAgentIdentity,
        soulPrompt: appSettings.aiAgentSoul,
        novelOnboardingEligible: novelOnboardingEligible,
      ),
    );
    final restoredContext = restorePersistedChatContext(session.messages);
    final initialMessages = await _convertToAgentMessages(
      _buildAgentHistory(restoredContext.retainedMessages),
    );
    ctxMgr.restoreSnapshot(
      AgentContextSnapshot(
        messages: initialMessages,
        summary: restoredContext.summary,
        compactionCount: restoredContext.compactionCount,
        lastCompactionTokensBefore: restoredContext.lastCompactionTokensBefore,
        lastCompactionTokensAfter: restoredContext.lastCompactionTokensAfter,
      ),
    );

    final parentSessionId = session.sessionId ?? sessionId;
    final currentNovelId = novel.id;
    final currentDatabasePath = databasePath;
    final persistence = currentDatabasePath == null
        ? null
        : container.read(
            aiSessionPersistenceServiceProvider(
              novelId: currentNovelId,
              databasePath: currentDatabasePath,
            ),
          );

    // 每次 run 单独借用 HTTP 连接并创建 client / 工具管理器；归还由 run 负责。
    Future<SpawnAgentResources> subAgentResourcesResolver({
      required String providerId,
      required String model,
      required String subSessionId,
      required String sourceSessionId,
    }) async {
      final subConfig = container.read(
        currentAiConfigProvider(providerId: providerId, model: model),
      );
      if (subConfig == null || !subConfig.isValid) {
        throw SpawnAgentInitializationException(
          reason: 'model_configuration_unavailable',
          message:
              '供应商“$providerId”的模型“$model”当前没有可用配置。'
              '请检查登录状态和供应商设置，并重新选择可用模型。',
        );
      }
      final lease = container
          .read(aiHttpClientRegistryProvider)
          .acquire(subConfig);
      return client.createSubAgentResources(
        config: subConfig,
        model: model,
        subSessionId: subSessionId,
        sourceSessionId: sourceSessionId,
        httpLease: lease,
        traceHeadersProvider: () => buildTraceSessionHeaders(
          sessionId: subSessionId,
          parentSessionId: parentSessionId,
          sessionMode: session.sessionMode.value,
        ),
      );
    }

    final chatHooks = [
      ..._usageHooks(sessionId: parentSessionId, source: 'chat'),
      ..._traceHooks(sessionId: parentSessionId),
    ];
    final currentNovelDb = currentDatabasePath == null
        ? null
        : container.read(novelContentDatabaseProvider(currentDatabasePath));
    final mcpService = container.read(mcpSettingsServiceProvider);
    final pluginHost = container.read(pluginHostServiceProvider);
    final spawnAgentHandler = SpawnAgentHandler(
      pluginHost: pluginHost,
      mcpService: mcpService,
      workContext: promptContext,
      availableSubAgents: availableSubAgents,
      availableSkills: skillContext.summaries,
      agentConfig: client.agentConfig,
      defaultProviderId: session.providerId,
      defaultModel: session.model,
      parentSessionId: parentSessionId,
      persistence: persistence,
      novelDatabase: currentNovelDb,
      resourcesResolver: subAgentResourcesResolver,
      codemodeScheduler: container.read(codemodeSchedulerProvider),
      hooks: chatHooks,
      onSessionStarted: (callId, subSessionId) {
        final existing = sessionNotifier.findToolCallByCallId(callId)?.$2;
        // 后台身份已绑定在运行态展示快照，不能改写停止主回复产生的工具结果。
        if (existing?.arguments['background'] != false) {
          return;
        }
        sessionNotifier.patchToolCallByCallId(
          callId,
          result: {...?existing?.result, 'session_id': subSessionId},
        );
      },
      contextSupplementForSession: (subSessionId) async {
        final todos = await container.readFuture(
          sessionTodosProvider(subSessionId).future,
        );
        return [buildTodoContextSupplementMessage(todos)];
      },
    );
    bool codemodeAllowed() =>
        container.read(aiChatSessionProvider(sessionId)).sessionMode ==
        AiSessionMode.chat;
    late final McpAgentToolDispatcher mcpDispatcher;
    final chatToolDispatcher = ChatAgentToolDispatcher(
      inner: tm,
      codemodeAllowed: codemodeAllowed,
      runCodemode: (input, callId, context) => CodemodeOrchestrator().execute(
        input: input,
        context: context,
        parentToolCallId: callId,
        tools: mcpDispatcher,
        catalog: mcpDispatcher.catalog,
        runTool: (call, context) =>
            runtime.agent!.runToolCall(call, context: context),
        onRecord: (record) => container
            .read(aiChatSessionProvider(sessionId).notifier)
            .upsertNestedToolCall(callId, record),
        scheduler: container.read(codemodeSchedulerProvider),
        isAllowed: codemodeAllowed,
        allowedToolNames: () =>
            runtime.agent!.allowedTools ?? tm.allToolNames(),
      ),
      subAgents: runtime.subAgents,
      resumeSubAgent: (sessionId, message, callId, context) =>
          runtime.resumeSubAgent(
            handler: spawnAgentHandler,
            sessionId: sessionId,
            message: message,
            callId: callId,
            context: context,
          ),
      startSubAgent: (input, callId, context, {required background}) =>
          runtime.startSubAgent(
            handler: spawnAgentHandler,
            input: input,
            callId: callId,
            context: context,
            background: background,
          ),
    );
    mcpDispatcher = McpAgentToolDispatcher(
      inner: chatToolDispatcher,
      runTools: tm,
      service: mcpService,
      sourceSessionId: sessionId,
      allowedBuiltins: () => runtime.agent?.allowedTools ?? tm.allToolNames(),
      client: client.providerClient,
      isEnabled: codemodeAllowed,
    );
    final allowedTools = _resolveOrchestratorAllowedTools(
      chatToolDispatcher,
      mode,
    );
    ctxMgr.summarizer = buildDefaultContextSummarizer(
      agentId: 'orchestrator',
      systemPrompt: systemPrompt,
      allowedTools: allowedTools,
      client: client.providerClient,
      providerId: client.providerId,
      config: client.agentConfig,
      toolManager: mcpDispatcher,
      contextSupplement: () async => ctxMgr.contextSupplementMessages,
      hooks: _usageHooks(sessionId: sessionId, source: 'chat'),
    );

    final agent = Agent.custom(
      id: 'orchestrator',
      systemPrompt: systemPrompt,
      client: client.providerClient,
      providerId: client.providerId,
      config: client.agentConfig,
      toolManager: PluginAgentToolDispatcher(
        agentId: 'orchestrator',
        scope: (workId: promptContext.workId, mode: mode.value),
        sessionId: sessionId,
        inner: mcpDispatcher,
        host: pluginHost,
      ),
      contextManager: ctxMgr,
      allowedTools: allowedTools,
      // Todo 续跑 enabled: false：只上报结束时未完成 Todo 的快照，不追加续跑。
      // 子 Agent 复用 chatHooks，不挂此 hook。
      hooks: [
        ...chatHooks,
        _todoContinuationHook(sessionId: sessionId),
      ],
    );
    runtime.attachAgentAiService(client);
    runtime.agent = agent;
    return agent;
  }

  /// 跑一轮 chat turn（原 `_handleChatCompletion`）：组装/复用 orchestrator agent、
  /// 消费 `agent.process` 事件流并增量落库。行为与聊天面板发送一致。
  /// [userMessageId] 标识用户输入；[sourceTurnId] 标识写入归属。
  /// [completionInput] 从运行态消费独立通知，自动执行只合入同归属结果。
  Future<ChatTurnOutcome> runTurn(
    String text, {
    required int requestId,
    required String? sessionId,
    String? streamingMessageId,
    String? userMessageId,
    String? sourceTurnId,
    bool completionInput = false,
  }) async {
    if (completionInput && (sourceTurnId == null || sourceTurnId.isEmpty)) {
      throw ArgumentError('Completion input requires its original user turn.');
    }
    final serviceUnavailableText = tr(LocaleKeys.aiServiceUnavailable);
    final requestFailedText = tr(LocaleKeys.aiRequestFailed);
    final sessionNotifier = container.read(
      aiChatSessionProvider(sessionId).notifier,
    );
    final turnSession = container.read(aiChatSessionProvider(sessionId));
    final runtime = container.read(aiChatRuntimeProvider(sessionId).notifier);
    if (runtime.cancelledRequestIds.contains(requestId)) {
      _log.info('requestId=$requestId was cancelled before agent startup');
      return ChatTurnOutcome.cancelled(
        sessionId: sessionId,
        requestId: requestId,
      );
    }
    final toolExecutionContext = ToolExecutionContext(
      operationOwnerSessionId: runtime.operations.ownerSessionId,
      sessionId: turnSession.sessionId ?? sessionId,
      sourceSessionId: sourceSessionId ?? turnSession.sessionId ?? sessionId,
      sourceTurnId: sourceTurnId ?? userMessageId,
    );
    var processingCompletion = completionInput;
    final completionMessageIds = <String>{};
    Iterable<AgentMessage> takeCompletionMessages() sync* {
      final pending = container
          .read(aiChatRuntimeProvider(sessionId))
          .subAgents
          .pending;
      for (final notice in pending) {
        // 前一条通知落库期间可以取消或回退；每次恢复迭代都重新核对资格。
        if (runtime.cancelledRequestIds.contains(requestId)) {
          return;
        }
        final messages = container
            .read(aiChatSessionProvider(sessionId))
            .messages;
        final originExists = messages.any(
          (message) =>
              message.id == notice.run.sourceTurnId &&
              message.role == AiMessageRole.user &&
              message.type != AiMessageType.system_remind,
        );
        if (!originExists) {
          runtime.subAgents.cancelRun(
            notice.run.runId,
            source: 'origin_removed',
          );
          continue;
        }
        if (processingCompletion &&
            notice.run.sourceTurnId != toolExecutionContext.sourceTurnId) {
          continue;
        }
        final consumed = runtime.subAgents.takeCompletion(notice.run.runId);
        if (consumed != null) {
          completionMessageIds.add(consumed.messageId);
          yield AgentMessage.user(
            id: consumed.messageId,
            content: consumed.reminder,
          );
        }
      }
      final operationNotices = runtime.operations.state.pending;
      for (final notice in operationNotices) {
        if (runtime.cancelledRequestIds.contains(requestId)) {
          return;
        }
        final turnId = notice.record.sourceTurnId;
        final originExists = container
            .read(aiChatSessionProvider(sessionId))
            .messages
            .any(
              (message) =>
                  message.id == turnId &&
                  message.role == AiMessageRole.user &&
                  message.type != AiMessageType.system_remind,
            );
        if (!originExists) {
          runtime.operations.revokeCompletions({turnId});
          continue;
        }
        if (processingCompletion &&
            turnId != toolExecutionContext.sourceTurnId) {
          continue;
        }
        final consumed = runtime.operations.takeCompletion(notice.record.runId);
        if (consumed != null) {
          completionMessageIds.add(consumed.messageId);
          yield AgentMessage(
            id: consumed.messageId,
            role: AgentMessageRole.user,
            content: consumed.reminder,
            blocks: consumed.modelImages,
          );
        }
      }
    }

    _log.info(
      'handleChatCompletion requestId=$requestId textLength=${text.length} sessionId=${turnSession.sessionId}',
    );
    var uiAssistantStreaming = false;
    AiUsage? finalUsage;
    String? nextStreamingMessageId = streamingMessageId;
    String? ownedStreamingMessageId;
    void startUiAssistantMessage() {
      if (uiAssistantStreaming) {
        return;
      }
      sessionNotifier.startStreamingMessage(messageId: nextStreamingMessageId);
      ownedStreamingMessageId = container
          .read(aiChatSessionProvider(sessionId))
          .messages
          .last
          .id;
      nextStreamingMessageId = null;
      uiAssistantStreaming = true;
      _log.info('requestId=$requestId started streaming message');
    }

    void ensureUiAssistantMessage() {
      if (!uiAssistantStreaming) {
        startUiAssistantMessage();
      }
    }

    // Agent 每轮事件顺序（见 lib/shared/agent/agent.dart）：
    //   AgentMessageStart → LLM 流式 → AgentMessageEnd → ToolCallStart/Result → 下一轮
    // UI 的 isStreaming 必须覆盖「本轮 LLM + 本轮工具执行」，不能只在 AgentMessageEnd 结束。
    // 否则 upsertToolCallBlock 会在无 streaming 消息时新建 orphan 流式气泡，工具已 success
    // 却仍 isStreaming，出现「已完成 + 思考中…」和重复的 tool 卡片。

    /// 工具链进行中增量落库：默认只 upsert 已完成消息，不删 session 内其它行。
    /// [syncMessages] 会整表重写当前会话消息，调用方需要全量对齐时再打开。
    Future<bool> persistCompletedMessagesFromAgentEvent(
      String eventName, {
      bool syncMessages = false,
    }) async {
      final sid = sessionId;
      final dbPath = databasePath;
      final nid = novel.id;
      if (sid == null || dbPath == null || dbPath.isEmpty) {
        return false;
      }
      final session = container.read(aiChatSessionProvider(sid));
      if (!session.isLoaded || session.messages.isEmpty) {
        return false;
      }
      try {
        final persistence = container.read(
          aiSessionPersistenceServiceProvider(
            novelId: nid,
            databasePath: dbPath,
          ),
        );
        final novelDb = container.read(novelContentDatabaseProvider(dbPath));
        final contextSnapshot = container
            .read(aiChatRuntimeProvider(sid).notifier)
            .agent
            ?.contextManager
            .snapshot();
        if (syncMessages) {
          await persistence.saveMessages(
            sessionId: sid,
            messages: session.messages,
            novelDatabase: novelDb,
            contextSnapshot: contextSnapshot,
          );
        } else {
          await persistence.upsertCompletedMessages(
            sessionId: sid,
            messages: session.messages,
            novelDatabase: novelDb,
            contextSnapshot: contextSnapshot,
          );
        }
        _log.info(
          'persisted ${syncMessages ? 'synced' : 'completed'} messages from $eventName '
          'sessionId=$sid count=${session.messages.length}',
        );
        return true;
      } catch (error, stackTrace) {
        _log.error(
          'persist completed messages failed event=$eventName '
          'sessionId=$sid error=$error',
          error: error,
          stackTrace: stackTrace,
        );
        return false;
      }
    }

    /// 本轮所有 tool block 进入终态后再 endStreaming 并落库；与 AgentMessageEnd 推迟结束配对。
    Future<void> finishUiAssistantRoundIfSettled(String eventName) async {
      if (!uiAssistantStreaming) {
        return;
      }
      final session = container.read(aiChatSessionProvider(sessionId));
      final messages = session.messages;
      var streamingIndex = -1;
      for (var index = messages.length - 1; index >= 0; index--) {
        final message = messages[index];
        if (message.role == AiMessageRole.assistant && message.isStreaming) {
          streamingIndex = index;
          break;
        }
      }
      if (streamingIndex < 0) {
        return;
      }
      if (!aiAssistantMessageToolCallsSettled(messages[streamingIndex])) {
        return;
      }
      sessionNotifier.endStreamingMessage(usage: finalUsage);
      uiAssistantStreaming = false;
      finalUsage = null;
      await persistCompletedMessagesFromAgentEvent(eventName);
    }

    if (runtime.cancelledRequestIds.contains(requestId)) {
      _log.info('requestId=$requestId cancelled before agent resolution');
      return ChatTurnOutcome.cancelled(
        sessionId: sessionId,
        requestId: requestId,
      );
    }

    // 发送后立即给出「思考中」反馈：先建 streaming 气泡并进入等待态，覆盖
    // agent 冷启动重建 history 与上游首字节前的空窗。空气泡在流正常结束、
    // 异常 catch 与取消路径都会被 removeLastAssistantMessageIfInvisible 清理；agent 不可用时
    // 由 failStreamingMessage 直接转失败消息。
    startUiAssistantMessage();
    sessionNotifier.setWaitingForResponse(true);

    late final Agent agent;
    try {
      final resolvedAgent = await getOrCreateChatAgent(sessionId: sessionId);
      if (resolvedAgent == null) {
        _log.info('requestId=$requestId agent unavailable');
        // 主 try/finally 尚未进入，waiting 兜底不会执行，这里手动收尾。
        sessionNotifier.setWaitingForResponse(false);
        sessionNotifier.failStreamingMessage(
          serviceUnavailableText,
          metadata: const {'retryable': true},
        );
        return ChatTurnOutcome.failed(
          sessionId: sessionId,
          requestId: requestId,
          error: ChatTurnError(
            kind: ChatTurnErrorKind.serviceUnavailable,
            safeMessage: serviceUnavailableText,
            technicalMessage:
                'agent unavailable: provider/model/config missing',
          ),
        );
      }
      agent = resolvedAgent;
      final mode = container.read(aiChatSessionProvider(sessionId)).sessionMode;
      agent.updateAllowedTools(
        _resolveOrchestratorAllowedTools(agent.toolManager, mode),
      );
    } catch (error, stackTrace) {
      final wasUserCancelled = runtime.cancelledRequestIds.contains(requestId);
      sessionNotifier.setWaitingForResponse(false);
      sessionNotifier.endStreamingMessage();
      sessionNotifier.removeLastAssistantMessageIfInvisible();
      if (wasUserCancelled) {
        _log.info(
          'requestId=$requestId request cancelled during agent startup',
        );
        return ChatTurnOutcome.cancelled(
          sessionId: sessionId,
          requestId: requestId,
        );
      }
      _log.error(
        'requestId=$requestId agent startup failed',
        error: error,
        stackTrace: stackTrace,
      );
      final friendlyError = _userFriendlyError(
        error,
        fallback: requestFailedText,
        providerId: turnSession.providerId,
      );
      onComposerWarning?.call(friendlyError);
      return ChatTurnOutcome.failed(
        sessionId: sessionId,
        requestId: requestId,
        error: ChatTurnError(
          kind: ChatTurnErrorKind.runtimeError,
          safeMessage: friendlyError,
          technicalMessage: error.toString(),
          cause: error,
        ),
      );
    }
    // 跨 try/catch 可见，用于末尾统一返回 ChatTurnOutcome。
    var wasCancelled = false;
    var codemodeDispatched = false;
    final requestSourceTurnIds = <String>{};
    ChatTurnError? turnError;
    var doneFinalText = '';
    String? terminalFailureMessage;
    var reportedCompactionCount = agent.contextManager.compactionCount;

    void settleActiveToolCallsForTurn() {
      if (wasCancelled) {
        sessionNotifier.cancelPendingToolCallsForRequest(requestId);
        runtime.cancelRequest(requestId);
        return;
      }
      // 异常中断或 hook abort 遗留的 active tool call 属于失败，避免下一轮
      // 重建 provider history 时出现只有 tool_call、没有 tool_result 的非法历史。
      sessionNotifier.failPendingToolCallsForRequest(
        requestId,
        errorCode: 'turn_ended_before_tool_completion',
        errorMessage:
            turnError?.safeMessage ??
            terminalFailureMessage ??
            requestFailedText,
      );
    }

    try {
      var receivedVisibleText = false;
      var receivedVisibleBlock = false;
      var currentMessageHasVisibleText = false;
      var currentMessageHasVisibleBlock = false;
      var currentMessageHasToolCall = false;
      final turnWatch = Stopwatch()..start();
      var loggedFirstEvent = false;
      final inputMessage = turnSession.messages
          .where((m) => m.id == userMessageId)
          .firstOrNull;
      final inputBlocks =
          inputMessage != null &&
              inputMessage.blocks.any((b) => b is AiAttachmentBlock)
          ? await hydrateChatBlocks(inputMessage.blocks, strict: true)
          : <MessageBlock>[];
      _log.info(
        'turn timing stage=input_hydrated elapsedMs=${turnWatch.elapsedMilliseconds} '
        'blocks=${inputBlocks.length} requestId=$requestId',
      );
      await for (final event in agent.process(
        text,
        inputBlocks: inputBlocks,
        toolExecutionContext: toolExecutionContext,
        userMessageId: userMessageId,
        completionInput: completionInput,
        takeCompletionMessages: takeCompletionMessages,
      )) {
        if (!loggedFirstEvent) {
          loggedFirstEvent = true;
          _log.info(
            'turn timing stage=first_event elapsedMs=${turnWatch.elapsedMilliseconds} '
            'event=${event.runtimeType} requestId=$requestId',
          );
        }
        if (event is AgentToolCallStart) {
          if (event.toolName == codemodeToolName) {
            codemodeDispatched = true;
          }
          final turnId = toolExecutionContext.sourceTurnId;
          if (turnId != null) {
            requestSourceTurnIds.add(turnId);
          }
        }
        if (runtime.cancelledRequestIds.contains(requestId)) {
          wasCancelled = true;
          _log.info(
            'agentLoop requestId=$requestId found in cancelledRequestIds=${runtime.cancelledRequestIds}, cancelling',
          );
          agent.cancel();
          if (!codemodeDispatched) {
            break;
          }
          if (uiAssistantStreaming) {
            sessionNotifier.endStreamingMessage(
              usage: finalUsage,
              messageId: ownedStreamingMessageId,
            );
            uiAssistantStreaming = false;
            finalUsage = null;
          }
          if (event is! AgentCancelled &&
              event is! AgentEnd &&
              !(event is AgentToolCallResult &&
                  event.toolName == codemodeToolName) &&
              !(event is AgentToolSkipped &&
                  event.toolName == codemodeToolName)) {
            continue;
          }
        }
        switch (event) {
          case AgentStart():
            _log.info('requestId=$requestId AgentStart');
            sessionNotifier.setWaitingForResponse(true);
          case AgentMessageStart(:final round):
            _log.info('requestId=$requestId AgentMessageStart round=$round');
            // 截断续写会先发 AgentMessageEnd，正常已收口。若仍挂着上一条
            // streaming（例如半截 tool 卡让 MessageEnd 推迟了），有可见正文则
            // 落库后新开气泡，不要把两轮拼进同一条。thinking-only 没有可见
            // 正文，清掉临时气泡再开下一条。
            if (uiAssistantStreaming && currentMessageHasVisibleText) {
              sessionNotifier.endStreamingMessage(usage: finalUsage);
              uiAssistantStreaming = false;
              finalUsage = null;
              await persistCompletedMessagesFromAgentEvent('AgentMessageStart');
            } else if (uiAssistantStreaming) {
              sessionNotifier.clearActiveStreamingMessage();
              receivedVisibleText = false;
              receivedVisibleBlock = false;
              finalUsage = null;
            }
            startUiAssistantMessage();
            sessionNotifier.setWaitingForResponse(true);
            currentMessageHasVisibleText = false;
            currentMessageHasVisibleBlock = false;
            currentMessageHasToolCall = false;
          case AgentRoundRetry(
            :final attempt,
            :final reason,
            :final retryLimit,
          ):
            _log.info(
              'requestId=$requestId AgentRoundRetry attempt=$attempt reason=$reason',
            );
            sessionNotifier.setWaitingForResponse(
              true,
              retryProgress: '$attempt/$retryLimit',
            );
            // 清空 partial 气泡（文本 / thinking / pending tool blocks），复用同一气泡
            // 承接重试流；uiAssistantStreaming 保持 true。reason 仅日志用，不展示给用户。
            sessionNotifier.clearActiveStreamingMessage();
            receivedVisibleText = false;
            receivedVisibleBlock = false;
            currentMessageHasVisibleText = false;
            currentMessageHasVisibleBlock = false;
            currentMessageHasToolCall = false;
            finalUsage = null;
          case AgentTextDelta(:final text):
            sessionNotifier.setWaitingForResponse(false);
            ensureUiAssistantMessage();
            if (!receivedVisibleText && text.trim().isNotEmpty) {
              receivedVisibleText = true;
              currentMessageHasVisibleText = true;
              _log.info('requestId=$requestId AgentTextDelta firstVisible');
            }
            if (text.trim().isNotEmpty) {
              currentMessageHasVisibleText = true;
            }
            sessionNotifier.appendTextDelta(text);
          case AgentThinkingDelta(:final text):
            sessionNotifier.setWaitingForResponse(false);
            ensureUiAssistantMessage();
            sessionNotifier.appendThinkingDelta(text);
          case AgentTextComplete(:final text):
            _log.info(
              'requestId=$requestId AgentTextComplete chars=${text.length}',
            );
          case AgentThinkingComplete(:final text):
            _log.info(
              'requestId=$requestId AgentThinkingComplete chars=${text.length}',
            );
          case AgentToolCallDelta(
            :final callId,
            :final toolName,
            :final arguments,
            :final thoughtSignature,
          ):
            sessionNotifier.setWaitingForResponse(false);
            receivedVisibleBlock = true;
            currentMessageHasVisibleBlock = true;
            currentMessageHasToolCall = true;
            _syncRunToolCallBlock(
              sessionNotifier,
              callId: callId,
              toolName: toolName,
              args: arguments,
              requestId: requestId,
              thoughtSignature: thoughtSignature != null
                  ? encodeBase64(thoughtSignature)
                  : null,
            );
          case AgentToolCallComplete(
            :final callId,
            :final toolName,
            :final arguments,
            :final thoughtSignature,
          ):
            _log.info(
              'requestId=$requestId AgentToolCallComplete tool=$toolName callId=$callId',
            );
            _logRawToolPath(
              requestId: requestId,
              event: 'AgentToolCallComplete',
              toolName: toolName,
              callId: callId,
              arguments: arguments,
            );
            // 非流式 tool call 无 AgentToolCallDelta，参数就绪即首个可见内容，
            // 不等 AgentToolCallStart 就结束等待态，避免 pending 工具块叠加「思考中」。
            sessionNotifier.setWaitingForResponse(false);
            receivedVisibleBlock = true;
            currentMessageHasVisibleBlock = true;
            currentMessageHasToolCall = true;
            _syncRunToolCallBlock(
              sessionNotifier,
              callId: callId,
              toolName: toolName,
              args: arguments,
              requestId: requestId,
              thoughtSignature: thoughtSignature != null
                  ? encodeBase64(thoughtSignature)
                  : null,
            );
          case AgentToolCallIncomplete(
            :final callId,
            :final toolName,
            :final reason,
          ):
            _log.info(
              'requestId=$requestId AgentToolCallIncomplete tool=$toolName callId=$callId reason=$reason',
            );
            // 参数未完整生成且不会 dispatch。AgentRoundDelta 可能已经把这张卡写进
            // 聊天记录：本轮若仍有其他已完成的 tool call，就不会走 AgentRoundRetry
            // 清场，卡片会残留成一个永远 running 的步骤。标成 incomplete 交给既有
            // 呈现约定（tool_call_card 在非 debug 模式下隐藏它），debug 模式保留可见
            // 以便排查。
            sessionNotifier.patchToolCallByCallId(
              callId,
              status: AiToolCallStatus.error,
              result: {'error_code': reason},
            );
            break;
          case AgentToolCallStart(
            :final callId,
            :final toolName,
            :final arguments,
            :final thoughtSignature,
            :final metadata,
          ):
            _log.info(
              'requestId=$requestId AgentToolCallStart tool=${toolName.startsWith('mcp__') ? 'MCP' : toolName} callId=$callId',
            );
            sessionNotifier.setWaitingForResponse(false);
            receivedVisibleBlock = true;
            currentMessageHasVisibleBlock = true;
            currentMessageHasToolCall = true;
            _syncRunToolCallBlock(
              sessionNotifier,
              callId: callId,
              toolName: toolName,
              args: arguments,
              metadata: metadata,
              requestId: requestId,
              thoughtSignature: thoughtSignature != null
                  ? encodeBase64(thoughtSignature)
                  : null,
            );
          case AgentToolCallProgress(:final callId, :final progress):
            sessionNotifier.patchToolCallByCallId(
              callId,
              result: {'mcp_progress': progress},
            );
          case AgentToolCallResult(
            :final callId,
            :final toolName,
            :final output,
            :final metadata,
            :final errorMessage,
          ):
            receivedVisibleBlock = true;
            currentMessageHasVisibleBlock = true;
            currentMessageHasToolCall = true;
            _log.info(
              'requestId=$requestId AgentToolCallResult tool=${toolName.startsWith('mcp__') ? 'MCP' : toolName} callId=$callId hasOutput=${output != null}',
            );
            if (toolName == codemodeToolName &&
                sessionNotifier.findToolCallByCallId(callId)?.$2.requestId !=
                    requestId) {
              break;
            }
            sessionNotifier.patchToolCallByCallId(
              callId,
              status: toolName == codemodeToolName
                  ? (wasCancelled
                        ? AiToolCallStatus.cancelled
                        : aiToolResultStatus(
                            output is Map<String, dynamic> ? output : null,
                            errorMessage: errorMessage,
                          ))
                  : errorMessage == null
                  ? AiToolCallStatus.success
                  : AiToolCallStatus.error,
              result: output is Map<String, dynamic> ? output : null,
              metadata: metadata,
              errorMessage: errorMessage,
            );
            await finishUiAssistantRoundIfSettled('AgentToolCallResult');
            if (toolName == codemodeToolName && wasCancelled) {
              await persistCompletedMessagesFromAgentEvent('CodemodeSettled');
            }
          case AgentToolSkipped(
            :final callId,
            :final toolName,
            :final reason,
            :final output,
            :final metadata,
          ):
            receivedVisibleBlock = true;
            currentMessageHasVisibleBlock = true;
            _log.info(
              'requestId=$requestId AgentToolSkipped callId=$callId reason=${metadata?['tool_source'] == 'mcp' ? 'mcp_cancelled' : reason}',
            );
            final isCodemode = toolName == codemodeToolName;
            if (isCodemode &&
                sessionNotifier.findToolCallByCallId(callId)?.$2.requestId !=
                    requestId) {
              break;
            }
            // Codemode 取消时仍带着已发生、未撤销的写入摘要，卡片要能看到。
            sessionNotifier.patchToolCallByCallId(
              callId,
              status: AiToolCallStatus.cancelled,
              result: isCodemode || metadata?['tool_source'] == 'mcp'
                  ? output
                  : null,
              metadata: isCodemode || metadata?['tool_source'] == 'mcp'
                  ? metadata
                  : null,
              errorMessage: reason,
            );
            await finishUiAssistantRoundIfSettled('AgentToolSkipped');
            if (isCodemode && wasCancelled) {
              await persistCompletedMessagesFromAgentEvent('CodemodeSettled');
            }
          case AgentRoundText(:final text):
            _log.info(
              'requestId=$requestId AgentRoundText chars=${text.length} fallback=${!receivedVisibleText}',
            );
            if (!receivedVisibleText && text.trim().isNotEmpty) {
              // 非流式 provider 的文本回退也是「首个内容」，需结束等待态，
              // 与 AgentTextDelta 等流式事件的白名单语义一致。
              sessionNotifier.setWaitingForResponse(false);
              ensureUiAssistantMessage();
              receivedVisibleText = true;
              currentMessageHasVisibleText = true;
              sessionNotifier.appendTextDelta(text);
            }
            if (text.trim().isNotEmpty) {
              currentMessageHasVisibleText = true;
            }
          case AgentSteeringApplied():
            _log.info('requestId=$requestId AgentSteeringApplied');
          case AgentFollowUpApplied():
            _log.info('requestId=$requestId AgentFollowUpApplied');
            break;
          case AgentNextTurnApplied():
            _log.info('requestId=$requestId AgentNextTurnApplied');
            final queuedMessage = takeQueuedMessage?.call(sessionId);
            if (queuedMessage != null) {
              if (uiAssistantStreaming) {
                sessionNotifier.endStreamingMessage(usage: finalUsage);
                uiAssistantStreaming = false;
                finalUsage = null;
                sessionNotifier.removeLastAssistantMessageIfInvisible();
                await persistCompletedMessagesFromAgentEvent(
                  'AgentNextTurnApplied',
                );
              }
              // 「立即发送」的排队消息作为新一轮 user turn 被消费：本轮后续工具改动
              // 应归属到这条新消息，而非触发 process 的上一条消息。改写执行上下文的
              // turn id，保证回滚按轮正确归属（见 chat-changes-rework 设计）。
              final queuedUserMessage = sessionNotifier.addUserMessage(
                queuedMessage.agentText,
                blocks: queuedMessage.blocks,
                id: queuedMessage.userMessageId,
                metadata: slashChipsMetadataFromReferences(
                  queuedMessage.references,
                ),
              );
              // Agent slots use a fixed ID while staged. Once consumed, retain
              // the persisted identity so compaction can locate image turns.
              final memory = agent.contextManager.messages.toList();
              final queuedIndex = memory.lastIndexWhere(
                (m) => m.id == 'queued_chat',
              );
              if (queuedIndex >= 0) {
                memory[queuedIndex] = memory[queuedIndex].copyWith(
                  id: queuedUserMessage.id,
                );
                agent.contextManager.setMessages(memory);
              }
              toolExecutionContext.sourceTurnId = queuedUserMessage.id;
              processingCompletion = false;
              startUiAssistantMessage();
              // 排队消息开启的新一轮同样先进入等待态，与 AgentMessageStart 语义一致。
              sessionNotifier.setWaitingForResponse(true);
            }
            break;
          case AgentMessageAdded(:final message):
            _log.info(
              'requestId=$requestId AgentMessageAdded id=${message.id}',
            );
            if (message.role == AgentMessageRole.user &&
                message.content.trim().startsWith('<system-remind')) {
              final isCompletionReminder = completionMessageIds.contains(
                message.id,
              );
              final isPluginContext = message.content.trim().startsWith(
                '<system-remind type="plugin_context"',
              );
              // 完成通知与插件快照在请求前送达；先移除空占位，让落库顺序与模型上下文一致。
              // 已有正文或工具的上一轮必须保留其完整记录。
              if ((isCompletionReminder || isPluginContext) &&
                  uiAssistantStreaming &&
                  !currentMessageHasVisibleText &&
                  !currentMessageHasVisibleBlock &&
                  !currentMessageHasToolCall) {
                sessionNotifier.endStreamingMessage();
                sessionNotifier.removeLastAssistantMessageIfInvisible();
                uiAssistantStreaming = false;
              }
              final alreadyPersisted = container
                  .read(aiChatSessionProvider(sessionId))
                  .messages
                  .any((existing) => existing.id == message.id);
              if (!alreadyPersisted) {
                sessionNotifier.addUserMessage(
                  message.content,
                  id: message.id,
                  type: AiMessageType.system_remind,
                );
                // 已知的低概率 crash-consistency 窗口：截断续写的 continuation
                // remind 会早于 AgentMessageEnd 到达；此时对应的 partial assistant
                // 仍是 streaming，会被持久化层过滤。若进程在此处崩溃，DB 可能暂时
                // 只留下 remind。当前接受该窗口，后续不要把此处视为 assistant 已落库。
                final persisted = await persistCompletedMessagesFromAgentEvent(
                  'AgentSystemRemind',
                );
                if (isCompletionReminder &&
                    databasePath?.isNotEmpty == true &&
                    !persisted) {
                  throw StateError(
                    'Sub-agent completion history could not be saved.',
                  );
                }
              }
            }
            if (message.role == AgentMessageRole.assistant &&
                message.content == thinkingOnlyContinuationMessage) {
              // thinking-only 自述必须落库：重启后 history 少了这句，前缀
              // 和活着的 Agent 对不上，prompt 缓存会断。写成 system_remind
              // 以免出现在聊天列表。先收口并丢掉只有 thinking 的临时气泡，
              // 再按 Agent 消息顺序插入，避免排到 streaming 占位后面。
              if (uiAssistantStreaming) {
                sessionNotifier.clearActiveStreamingMessage();
                sessionNotifier.endStreamingMessage(usage: finalUsage);
                uiAssistantStreaming = false;
                receivedVisibleText = false;
                receivedVisibleBlock = false;
                currentMessageHasVisibleText = false;
                currentMessageHasVisibleBlock = false;
                currentMessageHasToolCall = false;
                finalUsage = null;
                sessionNotifier.removeLastAssistantMessageIfInvisible();
              }
              final alreadyPersisted = container
                  .read(aiChatSessionProvider(sessionId))
                  .messages
                  .any((existing) => existing.id == message.id);
              if (!alreadyPersisted) {
                final persistedMessage = convertAgentMessageToAiMessage(
                  message,
                );
                sessionNotifier.addAssistantMessage(
                  message.content,
                  id: message.id,
                  type: AiMessageType.system_remind,
                  blocks: persistedMessage.blocks,
                );
                await persistCompletedMessagesFromAgentEvent(
                  'AgentThinkingOnlySelfTalk',
                );
              }
            }
            if (message.role == AgentMessageRole.assistant) {
              for (final block in message.blocks) {
                if (block is ThinkingBlock &&
                    block.signature != null &&
                    block.signature!.isNotEmpty) {
                  sessionNotifier.setActiveThinkingSignature(block.signature!);
                  break;
                }
              }
            }
            // 捕获 assistant 消息的 usage
            if (message.role == AgentMessageRole.assistant &&
                message.usage != null) {
              finalUsage = message.usage;
              _log.info(
                'requestId=$requestId captured usage: input=${finalUsage?.inputTokens}, output=${finalUsage?.outputTokens}, total=${finalUsage?.totalTokens}',
              );
            }
          case AgentMessageEnd(:final round):
            _log.info('requestId=$requestId AgentMessageEnd round=$round');
            if (uiAssistantStreaming) {
              if (currentMessageHasToolCall) {
                // 有 tool 时 Agent 在 MessageEnd 之后才发 ToolCallResult；此处不能
                // 无条件 endStreaming。半截 tool 已标成 error 时工具已终态，
                // 这里直接收口，避免截断续写把正文留在 streaming 气泡里。
                await finishUiAssistantRoundIfSettled('AgentMessageEnd');
                break;
              }
              sessionNotifier.endStreamingMessage(usage: finalUsage);
              uiAssistantStreaming = false;
              finalUsage = null;
              if (!currentMessageHasVisibleText &&
                  !currentMessageHasVisibleBlock) {
                sessionNotifier.removeLastAssistantMessageIfInvisible();
              }
              await persistCompletedMessagesFromAgentEvent('AgentMessageEnd');
            }
          case AgentLoopDetected(:final reason, :final details):
            _log.info(
              'requestId=$requestId AgentLoopDetected reason=$reason details=$details',
            );
          case AgentCompactionStart(:final tokensBefore):
            _log.info(
              'requestId=$requestId AgentCompactionStart tokensBefore=$tokensBefore',
            );
            sessionNotifier.setCompactingContext(true);
          case AgentCompactionEnd(
            :final ok,
            :final tokensBefore,
            :final tokensAfter,
            :final reason,
          ):
            _log.info(
              'requestId=$requestId AgentCompactionEnd ok=$ok '
              'tokensBefore=$tokensBefore tokensAfter=$tokensAfter '
              'reason=$reason',
            );
            sessionNotifier.setCompactingContext(false);
            final compactionCount = agent.contextManager.compactionCount;
            if (ok && compactionCount > reportedCompactionCount) {
              reportedCompactionCount = compactionCount;
              onAgentContextCompacted?.call(agent);
            }
          case AgentDone(:final finalText):
            _log.info(
              'requestId=$requestId AgentDone finalTextChars=${finalText.length} fallback=${!receivedVisibleText}',
            );
            if (finalText.trim().isNotEmpty) {
              doneFinalText = finalText;
            }
            if (!receivedVisibleText && finalText.trim().isNotEmpty) {
              // 与 AgentRoundText 同理：finalText 回退补出可见文本时结束等待态。
              sessionNotifier.setWaitingForResponse(false);
              ensureUiAssistantMessage();
              receivedVisibleText = true;
              currentMessageHasVisibleText = true;
              sessionNotifier.appendTextDelta(finalText);
            }
            if (finalText.trim().isNotEmpty) {
              currentMessageHasVisibleText = true;
            }
            break;
          case AgentCancelled():
            _log.info('requestId=$requestId AgentCancelled');
            wasCancelled = true;
            break;
          case AgentError(:final failure, :final technicalMessage):
            final safeMessage = localizeAiRunFailure(failure, tr);
            terminalFailureMessage = safeMessage;
            _log.info(
              'requestId=$requestId AgentError failure=$failure '
              'technicalMessage=$technicalMessage',
            );
            if (failure.isPaymentRequired) {
              onComposerWarning?.call(safeMessage);
              if (uiAssistantStreaming) {
                sessionNotifier.endStreamingMessage(usage: finalUsage);
                uiAssistantStreaming = false;
                finalUsage = null;
                if (currentMessageHasVisibleText ||
                    currentMessageHasVisibleBlock) {
                  await persistCompletedMessagesFromAgentEvent(
                    'AgentProviderPaymentNotice',
                  );
                }
              }
              sessionNotifier.removeLastAssistantMessageIfInvisible();
              break;
            }
            if (failure.kind == AiRunFailureKind.incompleteResponse &&
                uiAssistantStreaming) {
              // 最终仍无完整回复时丢弃 partial text / thinking；错误通过
              // composer warning 展示，不把残缺模型输出留在 transcript。
              sessionNotifier.clearActiveStreamingMessage();
              receivedVisibleText = false;
              receivedVisibleBlock = false;
              currentMessageHasVisibleText = false;
              currentMessageHasVisibleBlock = false;
              currentMessageHasToolCall = false;
            }
            // 统一 catch 块语义：provider 流内错误 → 失败态消息 + 结构化错误，
            // 不再把底层错误当作正常 assistant 内容追加进 transcript。
            turnError ??= ChatTurnError(
              kind: ChatTurnErrorKind.providerError,
              safeMessage: safeMessage,
              technicalMessage: technicalMessage ?? failure.toString(),
            );
            if (uiAssistantStreaming) {
              sessionNotifier.endStreamingMessage(usage: finalUsage);
              uiAssistantStreaming = false;
              finalUsage = null;
              sessionNotifier.removeLastAssistantMessageIfInvisible();
            }
            onComposerWarning?.call(safeMessage);
            break;
          case AgentEnd():
            _log.info('requestId=$requestId AgentEnd');
            break;
        }
      }

      settleActiveToolCallsForTurn();

      if (uiAssistantStreaming) {
        final endedUsage = finalUsage;
        sessionNotifier.endStreamingMessage(usage: finalUsage);
        uiAssistantStreaming = false;
        finalUsage = null;
        if (!currentMessageHasVisibleText && !currentMessageHasVisibleBlock) {
          sessionNotifier.removeLastAssistantMessageIfInvisible();
        }
        await persistCompletedMessagesFromAgentEvent('AgentStreamClosed');
        _log.info(
          'requestId=$requestId stream closed usage=${endedUsage?.totalTokens}',
        );
      }
      _log.info(
        'requestId=$requestId ended streaming visibleText=$receivedVisibleText visibleBlock=$receivedVisibleBlock wasCancelled=$wasCancelled usage=${finalUsage?.totalTokens}',
      );
      if (!receivedVisibleText && !receivedVisibleBlock) {
        _log.info('requestId=$requestId removing empty assistant message');
        sessionNotifier.removeLastAssistantMessageIfInvisible();
      }
      if (!wasCancelled && runtime.agent != null) {
        onAgentContextSettled?.call(runtime.agent!);
      }
    } catch (e, st) {
      final wasUserCancelled = container
          .read(aiChatRuntimeProvider(sessionId).notifier)
          .cancelledRequestIds
          .contains(requestId);
      String? warningMessage;
      if (wasUserCancelled) {
        _log.info('requestId=$requestId request cancelled during error path');
        wasCancelled = true;
      } else {
        _log.error(
          'requestId=$requestId request error',
          error: e,
          stackTrace: st,
        );
        final friendlyError = _userFriendlyError(
          e,
          fallback: requestFailedText,
          providerId: turnSession.providerId,
        );
        turnError ??= ChatTurnError(
          kind: ChatTurnErrorKind.runtimeError,
          safeMessage: friendlyError,
          technicalMessage: e.toString(),
          cause: e,
        );
        warningMessage = friendlyError;
      }
      // catch 是 turn 的独立终止出口，必须与正常出口遵守同一工具调用终态契约。
      // 先收口再调用外部回调，确保回调本身再次抛错也不会污染下一轮历史。
      settleActiveToolCallsForTurn();
      if (warningMessage != null) {
        onComposerWarning?.call(warningMessage);
      }
      if (uiAssistantStreaming) {
        sessionNotifier.endStreamingMessage(usage: finalUsage);
        uiAssistantStreaming = false;
        finalUsage = null;
      }
      sessionNotifier.removeLastAssistantMessageIfInvisible();
    } finally {
      // AgentCompactionEnd / 重试后的下一事件可能因取消或事件流异常未被消费；
      // 无论 turn 如何结束，都不能让瞬态提示泄漏到下一轮。
      if (container.read(aiChatRuntimeProvider(sessionId)).requestSequence ==
          requestId) {
        sessionNotifier.setCompactingContext(false);
        sessionNotifier.setWaitingForResponse(false);
      }
    }

    if (wasCancelled || turnError == null) {
      await _maybeAutoCommitTurn(
        sessionId,
        force: wasCancelled,
        sourceTurnIds: wasCancelled && codemodeDispatched
            ? requestSourceTurnIds
            : null,
      );
    }

    // 统一返回：失败优先，其次取消，否则完成。failed 的 finalText 取 AgentDone（不含错误文案）。
    if (turnError != null) {
      return ChatTurnOutcome.failed(
        sessionId: sessionId,
        requestId: requestId,
        error: turnError,
        finalText: doneFinalText,
      );
    }
    if (wasCancelled) {
      return ChatTurnOutcome.cancelled(
        sessionId: sessionId,
        requestId: requestId,
        finalText: doneFinalText,
      );
    }
    return ChatTurnOutcome.completed(
      sessionId: sessionId,
      requestId: requestId,
      finalText: _resolveFinalAssistantText(sessionId, doneFinalText),
    );
  }

  Future<void> _maybeAutoCommitTurn(
    String? sessionId, {
    bool force = false,
    Set<String>? sourceTurnIds,
  }) async {
    if (!force && !container.read(aiAgentAutoAcceptProvider)) {
      return;
    }
    final dbPath = databasePath;
    final normalizedSessionId = sessionId?.trim();
    if (dbPath == null ||
        dbPath.isEmpty ||
        normalizedSessionId == null ||
        normalizedSessionId.isEmpty) {
      return;
    }
    try {
      final overlay = container.read(workingOverlayServiceProvider(dbPath));
      if (sourceTurnIds != null) {
        final ids = (await overlay.getWorkingChanges())
            .where(
              (change) =>
                  change.sourceSessionId == normalizedSessionId &&
                  sourceTurnIds.contains(change.sourceTurnId) &&
                  change.source == workingChangeSourceAi &&
                  change.status == workingChangeStatusActive,
            )
            .map((change) => change.id)
            .toList();
        await overlay.commitWorkingChanges(
          ids,
          source: workingChangeSourceAi,
          message: 'history.commit_message.auto_commit_ai_changes',
        );
      } else {
        await overlay.commitActiveAiChangesForSession(
          normalizedSessionId,
          message: 'history.commit_message.auto_commit_ai_changes',
        );
      }
    } catch (error, stackTrace) {
      _log.error(
        'autoCommitTurn session=$sessionId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// completed 时的 finalText：优先 AgentDone.finalText，回退最后一条可见 assistant 文本。
  String _resolveFinalAssistantText(String? sessionId, String doneFinalText) {
    if (doneFinalText.trim().isNotEmpty) {
      return doneFinalText;
    }
    final messages = container.read(aiChatSessionProvider(sessionId)).messages;
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message.role == AiMessageRole.assistant) {
        final text = message.effectiveText;
        if (text.trim().isNotEmpty) {
          return text;
        }
      }
    }
    return '';
  }
}
