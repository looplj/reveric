// 职责: 组合 AI 聊天与工具配置，为主执行和独立子运行分别创建与释放资源。
// 关联文件:
//   lib/shared/services/ai/ai_chat_service.dart
//   lib/shared/services/ai/provider_initializer.dart
//   lib/shared/services/ai/spawn_agent_handler.dart
//   lib/shared/agent/client.dart
//   lib/shared/agent/client/trace_headers_http_client.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/models_catalog.dart' show resolveReasoningBudget;
import '../../agent/agent_config.dart'
    show AgentConfig, resolveAgentMaxTokens, resolveReasoningEffort;
import '../../agent/agent_event.dart' show AgentRoundResult;
import '../../agent/agent_hook.dart' show AgentHook;
import '../../models/ai_chat_models.dart';
import '../../agent/client.dart' show ProviderClient;
import '../../models/agent_skill.dart';
import '../../models/ai_provider.dart';
import '../../models/ai_session_mode.dart';
import '../../models/content_kind.dart';
import '../../models/subagent.dart';
import '../../agent/client.dart';
import '../../agent/client/trace_headers_http_client.dart'
    show TraceHeadersProvider, SubSessionTraceHeadersProvider;
import '../../logger/app_logger.dart';
import '../novel_content.dart';
import '../working_overlay.dart';
import 'ai_chat_service.dart';
import 'ai_service_config.dart';
import 'provider_initializer.dart';
import 'ai_http_client_lease.dart';
import 'spawn_agent_handler.dart' show SpawnAgentResources;

import 'tools.dart';

typedef SubAgentListProvider = List<SubAgent> Function();

final _aiClientLog = AppLogger.forModule('AiClient');

class AiClient {
  factory AiClient.fromConfig(
    AiServiceConfig c, {
    http.Client? httpClient,
    TraceHeadersProvider? traceHeadersProvider,
    SubSessionTraceHeadersProvider? subSessionTraceHeaders,
    String? cacheKeyUserId,
  }) {
    return AiClient(
      c.provider,
      chatModel: c.chatModel,
      segmenterModel: c.segmenterModel,
      novelContentService: c.novelContentService,
      workingOverlayService: c.workingOverlayService,
      sessionContext: c.sessionContext,
      novelReader: c.novelReader,
      novelWriter: c.novelWriter,
      novelDraftClearer: c.novelDraftClearer,
      crossWorkAccess: c.crossWorkAccess,
      providerReader: c.providerReader,
      onToolCallRequested: c.onToolCallRequested,
      onToolStarted: c.onToolStarted,
      onToolFinished: c.onToolFinished,
      shouldExecuteTool: c.shouldExecuteTool,
      interruptReason: c.interruptReason,
      imageGenerationCallback: c.imageGenerationCallback,
      imageEditCallback: c.imageEditCallback,
      createLocationCallback: c.createLocationCallback,
      subAgentListProvider: c.subAgentListProvider,
      sessionModeNotifier: c.sessionModeNotifier,
      askUserCallback: c.askUserCallback,
      suggestNextActionCallback: c.suggestNextActionCallback,

      themesCommandCallback: c.themesCommandCallback,
      subagentsCommandCallback: c.subagentsCommandCallback,
      sessionsCommandCallback: c.sessionsCommandCallback,
      sessionId: c.sessionId,
      sourceSessionId: c.sourceSessionId,
      contentKind: c.contentKind,
      workId: c.workId,
      currentSeasonId: c.currentSeasonId,
      currentEpisodeId: c.currentEpisodeId,
      skillLoader: c.skillLoader,
      canvasActivityReporter: c.canvasActivityReporter,

      httpClient: httpClient,
      traceHeadersProvider: traceHeadersProvider,
      subSessionTraceHeaders: subSessionTraceHeaders,
      cacheKeyUserId: cacheKeyUserId,
    );
  }

  @Deprecated('Use AiClient.fromConfig(AiServiceConfig(...)) instead')
  AiClient(
    this._config, {
    required this._chatModel,
    this._reasoningEffort,
    String? segmenterModel,
    this._novelContentService,
    this._workingOverlayService,
    this._sessionContext,
    this._novelReader,
    this._novelWriter,
    this._novelDraftClearer,
    this._crossWorkAccess,
    this._providerReader,
    this._onToolCallRequested,
    this._onToolStarted,
    this._onToolFinished,
    this._shouldExecuteTool,
    AiInterruptReason? Function()? interruptReason,
    this._imageGenerationCallback,
    this._imageEditCallback,
    this._createLocationCallback,
    this._subAgentListProvider,
    this._sessionModeNotifier,
    this._askUserCallback,
    this._suggestNextActionCallback,

    this._sessionId,
    this._sourceSessionId,
    this._contentKind = contentKindNovel,
    this._workId,
    this._currentSeasonId,
    this._currentEpisodeId,
    this._skillLoader,
    this._agentSkillsCommandCallback,
    this._themesCommandCallback,
    this._subagentsCommandCallback,
    this._sessionsCommandCallback,
    this._notifyCallback,
    this._canvasActivityReporter,
    this._httpClient,
    this._traceHeadersProvider,
    this._subSessionTraceHeaders,
    this._cacheKeyUserId,
  });

  final AiProvider _config;
  final String _chatModel;
  final String? _reasoningEffort;
  final NovelContentService? _novelContentService;
  final WorkingOverlayService? _workingOverlayService;
  final AiSessionContext? _sessionContext;
  final AiNovelReader? _novelReader;
  final AiNovelWriter? _novelWriter;
  final AiNovelDraftClearer? _novelDraftClearer;
  final CrossWorkAccess? _crossWorkAccess;
  final Future<List<AiProvider>> Function()? _providerReader;
  final AiToolCallRequestedCallback? _onToolCallRequested;
  final AiToolEventCallback? _onToolStarted;
  final AiToolEventCallback? _onToolFinished;
  final AiToolShouldExecuteCallback? _shouldExecuteTool;
  final AiImageGenerationCallback? _imageGenerationCallback;
  final AiImageEditCallback? _imageEditCallback;
  final AiCreateLocationCallback? _createLocationCallback;
  final SubAgentListProvider? _subAgentListProvider;
  final ValueNotifier<AiSessionMode>? _sessionModeNotifier;
  final AiAskUserCallback? _askUserCallback;
  final SuggestNextActionCallback? _suggestNextActionCallback;

  final String? _sessionId;
  final String? _sourceSessionId;
  final String _contentKind;
  final String? _workId;
  final String? _currentSeasonId;
  final String? _currentEpisodeId;
  final Future<AgentSkillLoadResult?> Function(String slug)? _skillLoader;
  final AiAgentSkillsCommandCallback? _agentSkillsCommandCallback;
  final AiThemesCommandCallback? _themesCommandCallback;
  final AiSubagentsCommandCallback? _subagentsCommandCallback;
  final AiSessionsCommandCallback? _sessionsCommandCallback;
  final AiRunNotifyCallback? _notifyCallback;
  final AiCanvasActivityReporter? _canvasActivityReporter;
  final http.Client? _httpClient;
  final TraceHeadersProvider? _traceHeadersProvider;
  final SubSessionTraceHeadersProvider? _subSessionTraceHeaders;
  final String? _cacheKeyUserId;

  /// 子会话 id → 只换了 trace 头的 initializer；随本 AiClient 一起 dispose。
  final Map<String, AiProviderInitializer> _subSessionInitializers = {};

  late final AiProviderInitializer _initializer = AiProviderInitializer(
    config: _config,
    chatModel: _chatModel,
    httpClient: _httpClient,
    traceHeadersProvider: _traceHeadersProvider,
    cacheKeyUserId: _cacheKeyUserId,
  );

  ProviderClient? _client;

  // TODO: embedding 功能暂时屏蔽
  // late final AiEmbeddingService embedding = AiEmbeddingService(
  //   providerClient: _client,
  //   config: _config,
  //   novelContentService: _novelContentService,
  //   embeddingModel: _embeddingModel,
  //   segmenterModel: _segmenterModel,
  // );

  List<String>? _chapterToolNames;
  AiToolManager? _toolManager;

  AiToolManager? get toolManager => _toolManager;

  String get providerId => _config.id;

  String get chatModel => _chatModel;

  // ---------------------------------------------------------------------------
  // Sub-services (lazy)
  // ---------------------------------------------------------------------------

  AiChatService? _chatService;
  bool _disposed = false;

  AiChatService get _ensureChatService => _chatService ??= AiChatService(
    client: _client!,
    config: _config,
    chatModel: _chatModel,
    reasoningEffort: _reasoningEffort,
    toolManager: _toolManager,
    sessionContext: _sessionContext,
    sessionModeNotifier: _sessionModeNotifier,
    chapterToolNamesResolver: _chapterToolNamesResolver,
  );

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  bool get isInitialized => _client != null;

  Future<void> initialize() async {
    if (_client != null) {
      return;
    }
    if (_disposed) {
      throw StateError('AiClient has been disposed.');
    }
    _client = await _initializer.initialize();

    if (_novelContentService != null &&
        _workingOverlayService != null &&
        _toolManager == null) {
      _aiClientLog.info('creating AiToolManager');
      _toolManager = _createToolManager(
        sessionId: _sessionId,
        sourceSessionId: _sourceSessionId,
        bindParentCallbacks: true,
      );
      _chapterToolNames = _toolManager!.allToolNames();
    }
  }

  AiToolManager _createToolManager({
    required String? sessionId,
    required String? sourceSessionId,
    required bool bindParentCallbacks,
  }) {
    final manager = AiToolManager(
      _novelContentService!,
      workingOverlayService: _workingOverlayService!,
      // TODO: embedding 功能暂时屏蔽
      // embeddingSearch: embedding.searchEmbeddings,
      novelReader: _novelReader,
      novelWriter: _novelWriter,
      novelDraftClearer: _novelDraftClearer,
      crossWorkAccess: _crossWorkAccess,
      providerReader: _providerReader,

      onToolCallRequested: bindParentCallbacks ? _onToolCallRequested : null,
      onToolStarted: bindParentCallbacks ? _onToolStarted : null,
      onToolFinished: bindParentCallbacks ? _onToolFinished : null,
      shouldExecuteTool: bindParentCallbacks ? _shouldExecuteTool : null,
      imageGenerationCallback: _imageGenerationCallback,
      imageEditCallback: _imageEditCallback,
      createLocationCallback: _createLocationCallback,
      subAgentListProvider: _subAgentListProvider,
      sessionModeNotifier: _sessionModeNotifier,
      askUserCallback: _askUserCallback,
      suggestNextActionCallback: _suggestNextActionCallback,

      skillLoader: _skillLoader,
      agentSkillsCommandCallback: _agentSkillsCommandCallback,
      themesCommandCallback: _themesCommandCallback,
      subagentsCommandCallback: _subagentsCommandCallback,
      sessionsCommandCallback: _sessionsCommandCallback,
      sessionId: sessionId,
      notifyCallback: _notifyCallback,
      canvasActivityReporter: _canvasActivityReporter,
      sourceSessionId: sourceSessionId,
      contentKind: _sessionContext?.contentKind ?? _contentKind,
      workId: _sessionContext?.workId ?? _workId,
      currentSeasonId: _sessionContext?.currentSeasonId ?? _currentSeasonId,
      currentEpisodeId: _sessionContext?.currentEpisodeId ?? _currentEpisodeId,
    );
    manager.registerAllTools();
    return manager;
  }

  /// 子运行接管独立 initializer、工具管理器和 HTTP 租约，父 dispose 不触及它们。
  Future<SpawnAgentResources> createSubAgentResources({
    required AiProvider config,
    required String model,
    required String subSessionId,
    required String sourceSessionId,
    required AiHttpClientLease httpLease,
    required TraceHeadersProvider traceHeadersProvider,
  }) async {
    final initializer = AiProviderInitializer(
      config: config,
      chatModel: model,
      httpClient: httpLease.client,
      traceHeadersProvider: traceHeadersProvider,
      cacheKeyUserId: _cacheKeyUserId,
    );
    AiToolManager? manager;
    try {
      if (_disposed ||
          _novelContentService == null ||
          _workingOverlayService == null) {
        throw StateError('SpawnAgent requires an active tool configuration.');
      }
      manager = _createToolManager(
        sessionId: subSessionId,
        sourceSessionId: sourceSessionId,
        bindParentCallbacks: false,
      );
      // 这些回调由 chat 组装后安装；每个管理器独立存储其引用。
      manager.operationHost = _toolManager!.operationHost;
      manager.productionStyleServiceBuilder =
          _toolManager!.productionStyleServiceBuilder;
      manager.skillLoader = _toolManager!.skillLoader;
      manager.skillNamesProvider = _toolManager!.skillNamesProvider;
      manager.todoWriteCallback = _toolManager!.todoWriteCallback;
      manager.mapDraftCommandCallback = _toolManager!.mapDraftCommandCallback;
      final client = await initializer.initialize();
      final ownedManager = manager;
      return SpawnAgentResources(
        client: client,
        toolManager: ownedManager,
        release: () {
          try {
            ownedManager.dispose();
          } finally {
            initializer.dispose();
            httpLease.release();
          }
        },
      );
    } catch (_) {
      try {
        manager?.dispose();
      } finally {
        initializer.dispose();
        httpLease.release();
      }
      rethrow;
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _client?.cancel();
    _initializer.dispose();
    for (final initializer in _subSessionInitializers.values) {
      initializer.dispose();
    }
    _subSessionInitializers.clear();
    _client = null;
    _chatService = null;
    _toolManager?.dispose();
    _toolManager = null;
    _chapterToolNames = null;
    _disposed = true;
  }

  List<String>? _chapterToolNamesResolver(AiSessionContext? context) {
    final databasePath = context?.databasePath?.trim();
    if (_chapterToolNames == null ||
        _chapterToolNames!.isEmpty ||
        _novelContentService == null ||
        databasePath == null ||
        databasePath.isEmpty) {
      return null;
    }
    return _chapterToolNames;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  ProviderClient get providerClient => _client!;

  /// 为子会话派生一个只换 trace 头的 ProviderClient。
  ///
  /// 共享同一份 provider 配置、模型与 http.Client，只把 x-session-id 换成
  /// [subSessionId]、父会话进 x-session-parent-id。多角色场景（剧场、议事）用它
  /// 让每个角色的请求独立归属，而不必为每个角色重建整套 AiClient 与工具栈。
  ///
  /// 未传 subSessionTraceHeaders、[subSessionId] 为空或初始化失败时返回 null，
  /// 调用方回退到 [providerClient]（请求归到父会话名下）。
  Future<ProviderClient?> providerClientForSubSession(
    String subSessionId,
  ) async {
    final headers = _subSessionTraceHeaders;
    if (headers == null || subSessionId.isEmpty || _disposed) {
      return null;
    }
    final initializer = _subSessionInitializers.putIfAbsent(
      subSessionId,
      () => AiProviderInitializer(
        config: _config,
        chatModel: _chatModel,
        httpClient: _httpClient,
        traceHeadersProvider: () => headers(subSessionId),
        cacheKeyUserId: _cacheKeyUserId,
      ),
    );
    try {
      return await initializer.initialize();
    } catch (error, stackTrace) {
      _subSessionInitializers.remove(subSessionId)?.dispose();
      _aiClientLog.error(
        'sub session client init failed subSessionId=$subSessionId',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  AgentConfig get agentConfig {
    final resolvedEffort = resolveReasoningEffort(
      _reasoningEffort,
      modelId: _chatModel,
    );
    return AgentConfig(
      temperature: _config.temperature,
      maxTokens: resolveAgentMaxTokens(_chatModel),
      reasoningEffort: resolvedEffort,
      reasoningBudget: resolveReasoningBudget(_chatModel, resolvedEffort),
    );
  }

  void cancel() => _client?.cancel();

  Future<String> chatCompletion(
    List<AiMessage> messages, {
    AiSessionContext? context,
  }) => _ensureChatService.chatCompletion(messages, context: context);

  /// 一次性旁路补全（会话标题生成等），跑在**独占** [ProviderClient] 上。
  ///
  /// 不能复用 [_client]：ProviderClient 的取消状态是实例级而非请求级的
  /// （OpenAiClient 的 `_abortCompleter`、AnthropicClient/GeminiClient 的
  /// `_cancelled`），与 Agent 流式生成并发时两者会互相踩掉 abort 句柄，
  /// 导致用户点「停止」静默失效、流式请求继续跑。独占 client 的做法与
  /// 共享 HTTP client lease 的生命周期一致。
  ///
  /// [timeout] 到点后主动 abort 底层请求并抛 [TimeoutException]，避免
  /// provider 无响应时把整个编排流程永久挂住。
  Future<String> chatCompletionDetached(
    List<AiMessage> messages, {
    required Duration timeout,
    AiSessionContext? context,
    List<AgentHook> hooks = const [],
    int? maxOutputTokens,
    AgentCancellationToken? cancellation,
  }) async {
    if (_disposed) {
      throw StateError('AiClient has been disposed.');
    }
    final initializer = AiProviderInitializer(
      config: _config,

      chatModel: _chatModel,
      httpClient: _httpClient,
      traceHeadersProvider: _traceHeadersProvider,
      cacheKeyUserId: _cacheKeyUserId,
    );
    void Function()? unlink;
    try {
      final client = await initializer.initialize();
      unlink = cancellation?.onCancel(client.cancel);
      if (cancellation?.isCancellationRequested == true) {
        throw StateError('Completion cancelled before request');
      }
      final service = AiChatService(
        client: client,
        config: _config,
        chatModel: _chatModel,
        reasoningEffort: _reasoningEffort,
        toolManager: _toolManager,
        sessionContext: _sessionContext,
        sessionModeNotifier: _sessionModeNotifier,
        chapterToolNamesResolver: _chapterToolNamesResolver,
      );
      final response = await service
          .chatCompletionResponse(
            messages,
            context: context,
            maxOutputTokens: maxOutputTokens,
          )
          .timeout(
            timeout,
            onTimeout: () {
              client.cancel();
              throw TimeoutException('chatCompletionDetached', timeout);
            },
          );
      if (hooks.isNotEmpty) {
        final round = AgentRoundResult(
          text: response.text,
          thinking: response.thinking,
          thinkingSignature: response.signature,
          encryptedContents: response.encryptedContents,
          toolCalls: response.toolCalls,
          usage: response.usage,
        );
        for (final hook in hooks) {
          await hook.afterLLM(round);
        }
      }
      return response.text;
    } finally {
      // _httpClient 非空时为共享实例，dispose 不会关闭它（见 AiProviderInitializer）。
      unlink?.call();
      initializer.dispose();
    }
  }
}
