// 职责: 为特殊模式的一次执行装配客户端与工具依赖，并统一管理客户端和 HTTP 租约。
// 关联文件:
//   lib/shared/providers/agent_council_providers.dart
//   lib/shared/providers/theater_providers.dart
//   lib/shared/services/ai/ai_http_client_lease.dart
//   lib/shared/services/ai/chat.dart
//   lib/shared/services/ai/tools_cross_work.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../agent/client/trace_headers_http_client.dart';
import '../../models/ai_chat_models.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_provider.dart';
import '../../models/ai_session_mode.dart';
import '../../providers/ai_providers.dart' show aiHttpClientRegistryProvider;
import '../../providers/novel_providers.dart';
import '../../providers/settings_providers.dart';
import 'chat.dart';
import 'tools.dart';

/// UI 提交的模型选择快照，不含页面状态或延迟读取 UI 的函数。
class AiModeRunSelection {
  AiModeRunSelection({
    required this.model,
    this.reasoningEffort,
    Iterable<AiModelOption> memberModels = const [],
    Iterable<String> disabledModelIds = const [],
  }) : memberModels = List.unmodifiable(memberModels),
       disabledModelIds = Set.unmodifiable(disabledModelIds);

  final AiModelOption model;
  final String? reasoningEffort;
  final List<AiModelOption> memberModels;
  final Set<String> disabledModelIds;
}

class AiModeClientRequest {
  const AiModeClientRequest({
    required this.model,
    required this.context,
    required this.sessionId,
    required this.mode,
    this.reasoningEffort,
  });
  final AiModelOption model;
  final AiSessionContext context;
  final String sessionId;
  final AiSessionMode mode;
  final String? reasoningEffort;
}

class AiModeRunCancelled implements Exception {
  const AiModeRunCancelled();
}

class AiModeClientUnavailable implements Exception {
  const AiModeClientUnavailable();
}

/// 工厂返回已初始化客户端；只有运行资源所有者可以释放它。
class AiModeOwnedClient {
  AiModeOwnedClient(this.client, this._release);
  final AiClient client;
  final VoidCallback _release;
  bool _closed = false;
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      client.dispose();
    } finally {
      _release();
    }
  }
}

typedef AiModeClientFactory =
    Future<AiModeOwnedClient> Function(AiModeClientRequest);

final aiModeClientFactoryProvider = Provider<AiModeClientFactory>((ref) {
  final container = ref.container;
  final liveClients = <AiModeOwnedClient>{};
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    // 包括正文已结束但标题仍在运行的独立客户端。
    for (final client in liveClients.toList()) {
      client.close();
    }
  });
  return (request) async {
    if (disposed) {
      throw const AiModeRunCancelled();
    }
    final config = container.read(
      currentAiConfigProvider(
        providerId: request.model.providerId,
        model: request.model.model,
      ),
    );
    if (config == null || !config.isValid) {
      throw const AiModeClientUnavailable();
    }
    final context = request.context;
    final path = context.databasePath;
    final workId = context.workId;
    final content = path == null
        ? null
        : container.read(novelContentServiceProvider(path));
    final overlay = path == null
        ? null
        : container.read(workingOverlayServiceProvider(path));
    final mode = ValueNotifier(request.mode);
    final lease = container.read(aiHttpClientRegistryProvider).acquire(config);
    final client = AiClient(
      config,
      chatModel: request.model.model,
      reasoningEffort: request.reasoningEffort,
      novelContentService: content,
      providerReader: () async => (await container.read(
        appSettingsProvider.future,
      )).aiSettings.providers,
      workingOverlayService: overlay,
      sessionContext: context,
      sessionModeNotifier: mode,
      sessionId: request.sessionId,
      workId: workId,
      contentKind: context.contentKind,

      httpClient: lease.client,
      traceHeadersProvider: () => buildTraceSessionHeaders(
        sessionId: request.sessionId,
        sessionMode: request.mode.value,
      ),
      subSessionTraceHeaders: (id) => buildTraceSessionHeaders(
        sessionId: id,
        parentSessionId: request.sessionId,
        sessionMode: request.mode.value,
      ),
      crossWorkAccess:
          request.mode == AiSessionMode.council &&
              content != null &&
              workId != null
          ? CrossWorkResolver(
              appDatabase: container.read(appDatabaseProvider),
              currentDatabasePath: path!,
              currentContentService: content,
              currentWorkId: workId,
            )
          : null,
      novelReader: workId == null
          ? null
          : () async {
              final novel = await container
                  .read(novelActionsProvider)
                  .getNovel(workId);
              if (novel == null) {
                return null;
              }
              return <String, dynamic>{
                'title': novel.title,
                'description': novel.description,
                'category': novel.category,
                'status': novel.status,
                'source_novel_id': ?novel.sourceNovelId,
                'draft': novel.draft,
                'word_count': novel.wordCount,
                'tags': novel.tags,
              };
            },
    );
    late final AiModeOwnedClient owned;
    owned = AiModeOwnedClient(client, () {
      liveClients.remove(owned);
      lease.release();
      mode.dispose();
    });
    liveClients.add(owned);
    try {
      await client.initialize();
      if (disposed) {
        throw const AiModeRunCancelled();
      }
      return owned;
    } on AiModeRunCancelled {
      owned.close();
      rethrow;
    } catch (error, stackTrace) {
      owned.close();
      AppLogger.forModule('AiModeClient').error(
        'Client initialization failed',
        error: error,
        stackTrace: stackTrace,
      );
      throw const AiModeClientUnavailable();
    }
  };
});

/// 一次开始/续跑/总结的资源。客户端只在本次操作内复用，历史由 orchestrator 保存。
class AiModeRunResources {
  AiModeRunResources({
    required this.factory,
    required this.selection,
    required this.context,
    required this.sessionId,
    required this.mode,
  });
  final AiModeClientFactory factory;
  final AiModeRunSelection selection;
  final AiSessionContext context;
  final String sessionId;
  final AiSessionMode mode;
  final Map<(String, String?), Future<AiModeOwnedClient>> _clients = {};
  bool _closed = false;
  bool get isClosed => _closed;
  bool _cancelled = false;
  final Set<AiModeOwnedClient> _detached = {};

  /// 标题旁路拥有独立租约；主操作正常结束不会提前关闭它。
  Future<String> withDetachedClient(
    Future<String> Function(AiClient) action,
  ) async {
    final owned = await factory(
      AiModeClientRequest(
        model: selection.model,
        context: context,
        sessionId: sessionId,
        mode: mode,
        reasoningEffort: selection.reasoningEffort,
      ),
    );
    _detached.add(owned);
    try {
      if (_cancelled) {
        throw const AiModeRunCancelled();
      }
      return await action(owned.client);
    } finally {
      _detached.remove(owned);
      owned.close();
    }
  }

  void cancelMain() {
    unawaited(close());
  }

  /// provider 被销毁时也取消独立标题；普通用户暂停仍允许标题按原逻辑完成。
  void cancelAll() {
    _cancelled = true;
    for (final owned in _detached.toList()) {
      owned.close();
    }
    cancelMain();
  }

  Future<AiClient> mainClient() =>
      _acquire(selection.model, selection.reasoningEffort);

  Future<AiClient?> memberClient(String? modelId) async {
    if (modelId == null || selection.disabledModelIds.contains(modelId)) {
      return null;
    }
    final model = selection.memberModels
        .where((m) => m.id == modelId)
        .firstOrNull;
    if (model == null) {
      return null;
    }
    try {
      return await _acquire(model, null);
    } on AiModeClientUnavailable {
      // 沿用已有的成员模型缺失策略：由编排器使用本次会话模型。
      return null;
    }
  }

  Future<AiClient> _acquire(AiModelOption model, String? effort) async {
    if (_closed) {
      throw const AiModeRunCancelled();
    }
    final owned = await _clients.putIfAbsent(
      (model.id, effort),
      () => factory(
        AiModeClientRequest(
          model: model,
          context: context,
          sessionId: sessionId,
          mode: mode,
          reasoningEffort: effort,
        ),
      ),
    );
    if (_closed) {
      owned.close();
      throw const AiModeRunCancelled();
    }
    return owned.client;
  }

  Future<void>? _closeFuture;
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final pending in _clients.values) {
      // 初始化失败由启动调用方处理；关闭时仍须继续释放其他客户端。
      AiModeOwnedClient owned;
      try {
        owned = await pending;
      } catch (_) {
        // 工厂负责释放初始化失败的客户端；调用方已收到同一个失败。
        continue;
      }
      owned.close();
    }
    _clients.clear();
  }
}
