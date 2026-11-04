// 职责: 组装微信桥接、跨作品助手与后台写作消息转发。
//       并自动挂载 AssistantCoordinator 把入站消息接入 AI turn runner；
//       提供 start_job / job_status / send_to_job / create_novel / edit_novel /
// 关联文件:
//   lib/shared/services/remote/remote_bridge_service.dart
//   lib/shared/services/remote/run_output_forwarder.dart
//   lib/shared/services/ai/assistant/coordinator.dart
//   lib/shared/services/ai/headless_session_turn.dart
//   lib/shared/database/daos/session_subscriptions_dao.dart
//   lib/shared/models/app_settings_aggregate_data.dart
//   lib/shared/providers/settings_providers.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../agent/message.dart';
import '../database/app_database.dart';
import '../logger/app_logger.dart';
import '../models/ai_chat_models.dart';
import '../models/ai_provider.dart';
import '../models/app_settings_aggregate_data.dart';
import '../models/novel.dart';
import '../providers/ai_providers.dart';
import '../providers/novel_providers.dart';
import '../providers/prompt_template_provider.dart';
import '../providers/settings_providers.dart';
import '../providers/usage_query_providers.dart';
import '../services/ai/ai_http_client_lease.dart';
import '../services/ai/ai_service_config.dart';
import '../services/ai/assistant/coordinator.dart';
import '../services/ai/chat.dart';
import '../services/ai/headless_session_turn.dart';
import '../services/remote/remote_bridge_service.dart';
import '../services/remote/run_output_forwarder.dart';
import '../services/remote/wechat_api.dart';

final _log = AppLogger.forModule('RemoteBridge');

/// Run 标题（来源标签）从 seed 派生的截断长度上限。
const _runTitleMaxChars = 30;

/// 远程 run seed 前缀指示（方案 §5.3 流程 4）。
///
/// 注入到 seed 文本头部，告知 Orchestrator 它在被远程观察：
/// - 关键节点调 Run notify progress（写入收件箱供 Assistant 汇总）
/// - 需要用户输入时调 Run notify question（即时推送到微信），提问后结束本轮等待回复
/// - 出错时调 Run notify error（即时推送到微信）
/// - 完成后调 Run notify complete
/// 仅 prompt 文本，配合 notifyCallback 实现 question/error 即时转发。
const _remoteRunSeedPrefix =
    '【远程观察模式】'
    '你正在被远程观察（用户通过微信，看不到你的中间思考与正文产出）。'
    '关键节点用 Run notify progress 上报进度（写入收件箱供 Assistant 汇总）；'
    '需要用户输入时用 Run notify question 提问（会即时推送到微信），提问后结束本轮等待回复；'
    '出错时用 Run notify error（会即时推送到微信）；'
    '完成后用 Run notify complete。\n\n'
    '任务种子：\n';

/// 读取远程桥接持久化快照（所有渠道的开关 + 凭证 + context_token，同一个
/// app_settings key）。
///
/// 键缺失或 JSON 损坏都回落到 [RemoteBridgeSettingsData.defaults]（开关默认开、未登录）：
/// 损坏时最坏结果是让用户重扫一次码，不值得因此中断启动。
Future<RemoteBridgeSettingsData> _readRemoteBridgeSettings(
  AppDatabase appDb,
) async {
  final raw = await appDb.appSettingsDao.get(
    RemoteBridgeSettingsData.appSettingsKey,
  );
  if (raw == null || raw.isEmpty) {
    return RemoteBridgeSettingsData.defaults;
  }
  try {
    return RemoteBridgeSettingsData.decode(raw);
  } catch (error, stackTrace) {
    _log.error(
      '[DB] table=app_settings operation=SELECT '
      'id=${RemoteBridgeSettingsData.appSettingsKey} malformed aggregate',
      error: error,
      stackTrace: stackTrace,
    );
    return RemoteBridgeSettingsData.defaults;
  }
}

/// 远程桥接持久化写入的串行链。
///
/// 开关、登录确认、-14 清凭证、上下文 token 四条路径都读-改-写同一个 key，
/// 并发交错会丢更新（例如关开关时一条在途的 token 写回把 enabled 改回开启，
/// 下次启动桥接无视用户意图自动运行）。模式同 novel_workspace_state_provider
/// 的 _writeChain。
Future<void> _remoteBridgeWriteChain = Future<void>.value();

/// 读-改-写微信渠道条目。开关与三个凭证回调都改同一个 key，必须先读回其余字段，
/// 否则会互相覆盖（例如持久化上下文 token 时把 credentials 抹掉），
/// 也会连带抹掉其它渠道的条目。所有写入经 [_remoteBridgeWriteChain] 串行执行。
///
/// 失败经返回的 Future 传播给调用方记 [DB] 日志；链自身吞掉错误，
/// 单次失败不阻塞后续排队写入。
Future<void> _updateWechatBridgeChannel(
  AppDatabase appDb,
  RemoteBridgeWechatData Function(RemoteBridgeWechatData current) update,
) {
  final task = _remoteBridgeWriteChain.then((_) async {
    final current = await _readRemoteBridgeSettings(appDb);
    await appDb.appSettingsDao.set(
      key: RemoteBridgeSettingsData.appSettingsKey,
      value: current.copyWith(wechat: update(current.wechat)).encode(),
    );
  });
  _remoteBridgeWriteChain = task.catchError((_) {});
  return task;
}

/// adapter 凭证 → 持久化形态。
RemoteBridgeWechatCredentialsData _toCredentialsData(
  WechatCredentials credentials,
) => RemoteBridgeWechatCredentialsData(
  token: credentials.token,
  baseUrl: credentials.baseUrl,
  accountId: credentials.accountId,
  userId: credentials.userId,
);

/// 持久化形态 → adapter 凭证。
WechatCredentials _toWechatCredentials(
  RemoteBridgeWechatCredentialsData data,
) => WechatCredentials(
  token: data.token,
  baseUrl: data.baseUrl,
  accountId: data.accountId,
  userId: data.userId,
);

/// adapter 的 chatId → token 运行时映射 → 持久化条目列表。
List<RemoteBridgeWechatChatContextData> _toChatContexts(
  Map<String, String> contextTokens,
) => <RemoteBridgeWechatChatContextData>[
  for (final entry in contextTokens.entries)
    RemoteBridgeWechatChatContextData(
      chatId: entry.key,
      contextToken: entry.value,
    ),
];

/// 持久化条目列表 → adapter 的 chatId → token 运行时映射。
Map<String, String> _toContextTokens(
  List<RemoteBridgeWechatChatContextData> chatContexts,
) => <String, String>{
  for (final context in chatContexts) context.chatId: context.contextToken,
};

/// 持久化微信桥接开关。供设置页开关调用 —— 与凭证同 key，走同一条读-改-写。
final remoteBridgeEnabledWriterProvider =
    Provider<Future<void> Function(bool enabled)>((ref) {
      final appDb = ref.watch(appDatabaseProvider);
      return (enabled) async {
        try {
          await _updateWechatBridgeChannel(
            appDb,
            (current) => current.copyWith(enabled: enabled),
          );
          _log.info('[Persist] wechat bridge enabled=$enabled');
        } catch (error, stackTrace) {
          _log.error(
            '[DB] wechat bridge enabled persist failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      };
    });

/// 远程桥接服务单例 provider。
///
/// 服务为有状态长生命周期（持有 adapter、登录订阅、消费循环），需 keepAlive。
/// 凭证与 context_token 经回调持久化到 app_settings 的
/// [RemoteBridgeSettingsData.appSettingsKey]，重启后由
/// [remoteBridgeAutoRestoreProvider] 自动恢复。
final remoteBridgeServiceProvider = Provider<RemoteBridgeService>((ref) {
  final appDb = ref.watch(appDatabaseProvider);
  final service = RemoteBridgeService();

  // 登录成功 → 持久化 credentials，并按用户开关启动 bridge。
  service.onLoginConfirmed = (credentials) async {
    var enabled = true;
    try {
      enabled = (await _readRemoteBridgeSettings(appDb)).wechat.enabled;
      await _updateWechatBridgeChannel(
        appDb,
        (current) =>
            current.copyWith(credentials: _toCredentialsData(credentials)),
      );
      _log.info('[Persist] credentials saved userId=${credentials.userId}');
    } catch (error, stackTrace) {
      _log.error(
        '[DB] credentials persist failed',
        error: error,
        stackTrace: stackTrace,
      );
    }

    // 新扫码成功后也要进入与重启恢复相同的消费状态；否则 UI 虽显示已连接，
    // 但 bridge 实际未运行，入站消息无人消费。
    if (enabled && !service.isRunning) {
      try {
        await service.start();
      } catch (error, stackTrace) {
        _log.error(
          '[RemoteBridge] start after login failed userId=${credentials.userId}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  };

  // -14 session 过期或用户登出 → 清 credentials + 上下文 token，保留 enabled
  //（用户意图与掉线无关，重新扫码后应沿用原来的开关状态）。
  service.onCredentialsCleared = () async {
    try {
      await _updateWechatBridgeChannel(
        appDb,
        (current) => current.copyWith(
          credentials: null,
          chatContexts: const <RemoteBridgeWechatChatContextData>[],
        ),
      );
      _log.info('[Persist] credentials + chat contexts cleared');
    } catch (error, stackTrace) {
      _log.error(
        '[DB] credentials clear failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  };

  // 上下文 token 变更 → 全量写回。
  // 全量写：单 chat 维度增量写需额外读-改-写，且条目量级小（chat 数 ≤ 用户数）。
  service.onContextTokenChanged = (chatId, token) async {
    try {
      final chatContexts = _toChatContexts(service.contextTokens);
      await _updateWechatBridgeChannel(
        appDb,
        (saved) => saved.copyWith(chatContexts: chatContexts),
      );
      if (_log.isDebugEnabled) {
        _log.debug(
          '[Persist] chat contexts saved chatId=$chatId '
          'total=${chatContexts.length}',
        );
      }
    } catch (error, stackTrace) {
      _log.error(
        '[DB] chat contexts persist failed chatId=$chatId',
        error: error,
        stackTrace: stackTrace,
      );
    }
  };

  ref.onDispose(service.dispose);
  return service;
});

/// Run 下行转发器单例 provider。
///
/// 非.autoDispose — forwarder 生命周期 = app 生命周期。订阅关系持久化于
/// `session_subscriptions` 表，跨重启后由 [remoteBridgeAutoRestoreProvider] 重新
/// [RunOutputForwarder.register]。
final runOutputForwarderProvider = Provider<RunOutputForwarder>((ref) {
  final bridge = ref.watch(remoteBridgeServiceProvider);
  final forwarder = RunOutputForwarder(ref: ref, bridge: bridge);
  ref.onDispose(forwarder.dispose);
  return forwarder;
});

/// app 启动时自动恢复远程桥接（免扫码 + forwarder 重挂）。
///
/// 流程（方案 §5.3 流程 1）：
/// 1. 读 app_settings 中该渠道的 enabled + credentials + context_tokens
/// 2. 凭证存在 → bridge.restoreAndStart（恢复消费循环）
/// 3. 凭证不存在 → 停在未登录态等用户扫码
/// 4. bridge 启动后 → 读 session_subscriptions 重挂 forwarder 订阅
///
/// 用户在设置页关掉该渠道开关时，仍恢复凭证让 UI 显示已连接，但不启动消费循环，
/// 也不重挂 forwarder / 不做孤儿 run 对账 —— 桥接是停的，这些动作要么无处可发，
/// 要么会把用户已关闭的通道重新唤醒。
///
/// 返回 true 表示恢复成功（bridge 已启动），false 表示无凭证、开关关闭或恢复失败。
///
/// 调用方应在 app 初始化完成后调 `ref.read(remoteBridgeAutoRestoreProvider)`。
final remoteBridgeAutoRestoreProvider = FutureProvider<bool>((ref) async {
  final appDb = ref.read(appDatabaseProvider);
  final bridge = ref.read(remoteBridgeServiceProvider);
  final forwarder = ref.read(runOutputForwarderProvider);

  // 1. 读微信渠道的持久化条目（开关 + 凭证 + 上下文 token 同一个 key）。
  // 凭证字段不全时 fromJsonOrNull 已判为 null，这里无需再解析、再兜错。
  final saved = await _readRemoteBridgeSettings(appDb);
  final channel = saved.wechat;
  final enabled = channel.enabled;
  final credentials = channel.credentials;
  if (credentials == null) {
    _log.info('[Restore] no persisted credentials — staying logged out');
    return false;
  }

  // 2. 恢复（+ 按开关决定是否启动）
  final ok = await bridge.restoreAndStart(
    credentials: _toWechatCredentials(credentials),
    contextTokens: _toContextTokens(channel.chatContexts),
    autoStart: enabled,
  );
  if (!ok) {
    _log.warning('[Restore] restoreAndStart failed — user should re-scan QR');
    return false;
  }
  if (!enabled) {
    _log.info(
      '[Restore] credentials restored but bridge disabled by user setting',
    );
    return false;
  }

  // 3. 重挂 forwarder 订阅 — 读 session_subscriptions 中所有 remote_chat 订阅。
  try {
    final subs = await appDb.sessionSubscriptionsDao.listBySubscriberType(
      sessionSubscriberRemoteChat,
    );
    for (final sub in subs) {
      // A3: 整个 per-sub 恢复逻辑（getById + getOrCreateByChat + register）
      // 包裹在 try/catch 内，单条失败不中断其余订阅恢复。
      try {
        final session = await appDb.aiChatSessionDao.getById(sub.sessionId);
        final runTitle = session?.title ?? sub.sessionId;
        // 恢复时为每个 (channelType, chatId) 解析 Assistant 会话 id，
        // 供 forwarder 崩溃兜底写 inbox。getOrCreate：跨重启后无 Assistant 会话行
        // 时自动补建，与 startJob 路径行为一致。
        final assistantSession = await appDb.assistantSessionDao
            .getOrCreateByChat(
              channelType: sub.channelType!,
              chatId: sub.targetId,
            );
        await forwarder.register(
          sessionId: sub.sessionId,
          runTitle: runTitle,
          chatId: sub.targetId,
          channelType: sub.channelType!,
          assistantSessionId: assistantSession.id,
        );

        // A6: 重启孤儿 run 兜底 —— 该 session 无 in-flight run（重启后必然），
        // 写一条 run_observer/error inbox + 转发 IM，一次性对账（不引入轮询）。
        // 注意：重启后所有订阅均不 in-flight，包括已正常完成的 run —— 属可接受边界，
        // Assistant 与用户可据上下文判断是否需要续跑。
        final isRunning = ref
            .read(aiChatRuntimeProvider(sub.sessionId))
            .isRequestInFlight;
        if (!isRunning) {
          const orphanText = 'Run 因应用重启中断';
          try {
            await appDb.assistantInboxDao.append(
              assistantSessionId: assistantSession.id,
              source: 'run_observer',
              messageType: 'error',
              content: orphanText,
              sourceRef: sub.sessionId,
            );
          } catch (error, stackTrace) {
            _log.error(
              '[Restore] orphan run inbox write failed '
              'session=${sub.sessionId} '
              'assistantSession=${assistantSession.id}',
              error: error,
              stackTrace: stackTrace,
            );
          }
          final ok = await bridge.sendToUser(
            sub.targetId,
            '【$runTitle】$orphanText',
          );
          if (!ok) {
            _log.warning(
              '[Restore] orphan run IM forward failed '
              'chatId=${sub.targetId} session=${sub.sessionId}',
            );
          }
        }
      } catch (error, stackTrace) {
        _log.error(
          '[Restore] per-sub restore failed session=${sub.sessionId}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    _log.info('[Restore] forwarder re-registered ${subs.length} subscriptions');
  } catch (error, stackTrace) {
    _log.error(
      '[Restore] session_subscriptions query failed',
      error: error,
      stackTrace: stackTrace,
    );
  }

  return true;
});

/// 从 seed 派生 run 标题（来源标签 `【run 标题】`）。截断到 [_runTitleMaxChars]。
String _runTitleFromSeed(String seed) {
  final trimmed = seed.trim();
  if (trimmed.length <= _runTitleMaxChars) return trimmed;
  return '${trimmed.substring(0, _runTitleMaxChars)}…';
}

/// 校验 runSessionId 是否归属该 chatId（session_subscriptions.target_id == chatId）。
///
/// 用于 job_status / send_to_job 的前置归属校验，防跨 chat 越权。
Future<bool> _isRunOwnedByChat(
  AppDatabase appDb,
  String runId,
  String chatId,
) async {
  final subs = await appDb.sessionSubscriptionsDao.listBySession(runId);
  return subs.any(
    (s) =>
        s.subscriberType == sessionSubscriberRemoteChat && s.targetId == chatId,
  );
}

/// 取最近 1-2 条 assistant 非流式消息的 text block 原文（不做 LLM 摘要，Rule 5）。
List<String> _recentAssistantTexts(List<AiMessage> messages) {
  final result = <String>[];
  for (final msg in messages.reversed) {
    if (msg.role != AiMessageRole.assistant || msg.isStreaming) continue;
    final text = msg.effectiveText.trim();
    if (text.isEmpty) continue;
    result.insert(0, text);
    if (result.length >= 2) break;
  }
  return result;
}

/// 为 Assistant 的 `list_novels` 工具提供书架可见作品。
final assistantNovelListCallbackProvider =
    Provider<Future<List<Map<String, dynamic>>> Function()>((ref) {
      final database = ref.watch(appDatabaseProvider);
      return () async {
        try {
          final novels = await database.novelDao.watchAll().first;
          return novels.shelfVisible
              .map(
                (novel) => <String, dynamic>{
                  'id': novel.id,
                  'title': novel.title,
                  'status': novel.status,
                  'word_count': novel.wordCount,
                  'updated_at': novel.updatedAt.toIso8601String(),
                },
              )
              .toList(growable: false);
        } catch (error) {
          throw StateError('listNovels failed: $error');
        }
      };
    });

/// Assistant 协调器单例 provider。
///
/// 把 [RemoteBridgeService.onInboundMessage] 接到 [AssistantTurnRunner]。
/// 启动时机：bridge 自身的 start() 被调用之前或之后均可（handler 是被动回调）。
/// 依赖 [remoteBridgeServiceProvider]，因此本 provider 被 read 时会自动实例化 bridge。
final assistantCoordinatorProvider = Provider<AssistantCoordinator>((ref) {
  final bridge = ref.watch(remoteBridgeServiceProvider);
  final appDb = ref.watch(appDatabaseProvider);
  final promptService = ref.watch(aiPromptServiceProvider);
  final usageService = ref.watch(usageServiceProvider);
  final listNovels = ref.watch(assistantNovelListCallbackProvider);
  final httpClientLeasePool = AiHttpClientLeasePool(
    ref.read(aiHttpClientRegistryProvider),
  );
  ref.onDispose(httpClientLeasePool.dispose);

  // 用闭包封装 ref.read，避免把 ProviderContainer 传给 coordinator。
  // 这样 coordinator 和 turn runner 都是纯 Dart 类，不耦合 Riverpod。
  Future<AiClient> clientFactory({
    required String providerId,
    required String model,
    required String sessionId,
  }) async {
    final config = ref.read(
      currentAiConfigProvider(providerId: providerId, model: model),
    );
    if (config == null || !config.isValid) {
      throw StateError(
        'AI config invalid for provider=$providerId model=$model',
      );
    }
    final httpClient = httpClientLeasePool.clientFor(config);
    final service = AiClient.fromConfig(
      AiServiceConfig(
        provider: config,
        chatModel: model,
        sourceSessionId: sessionId,
      ),
      httpClient: httpClient,
      traceHeadersProvider: () => {
        'x-session-id': sessionId,
        'x-session-parent-id': sessionId,
      },
    );
    await service.initialize();
    return service;
  }

  void onUsageChanged() {
    ref.invalidate(todayUsageProvider);
    ref.invalidate(thisMonthUsageProvider);
  }

  // create_novel / edit_novel 走 NovelActionsService 落地，与小说库其他入口一致。
  Future<Map<String, dynamic>> createNovel(Map<String, dynamic> novel) async {
    try {
      final actions = ref.read(novelActionsProvider);
      final novelId = await actions.createNovel(
        title: novel['title'] as String? ?? '',
        description: novel['description'] as String? ?? '',
        authorName:
            novel['author_name'] as String? ?? novel['authorName'] as String?,
        category: novel['category'] as String? ?? '',
        type: novel['type'] as String?,
        tags: (novel['tags'] as List?)?.map((e) => e.toString()).toList(),
      );
      return {'ok': true, 'novel_id': novelId};
    } catch (error, stackTrace) {
      _log.error(
        '[RemoteBridge] createNovel failed error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      return {'ok': false, 'error': error.toString()};
    }
  }

  Future<Map<String, dynamic>> editNovel(
    String novelId,
    Map<String, dynamic> fields,
  ) async {
    try {
      final db = ref.read(appDatabaseProvider);
      final novel = await db.novelDao.get(novelId);
      if (novel == null) {
        return {'ok': false, 'error': 'novel not found: $novelId'};
      }
      final actions = ref.read(novelActionsProvider);
      await actions.updateNovel(
        novel: novel,
        title: fields['title'] as String? ?? novel.title,
        description: fields['description'] as String? ?? novel.description,
        authorName:
            fields['author_name'] as String? ??
            fields['authorName'] as String? ??
            novel.authorName,
        category: fields['category'] as String? ?? novel.category,
        type: fields['type'] as String? ?? novel.type,
        tags:
            (fields['tags'] as List?)?.map((e) => e.toString()).toList() ??
            novel.tags,
        removeCover: false,
      );
      return {'ok': true, 'novel_id': novelId};
    } catch (error, stackTrace) {
      _log.error(
        '[RemoteBridge] editNovel failed novelId=$novelId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      return {'ok': false, 'error': error.toString()};
    }
  }

  Future<Map<String, dynamic>> listChapters(String novelId) async {
    try {
      final db = ref.read(appDatabaseProvider);
      final novel = await db.novelDao.get(novelId);
      if (novel == null) {
        return {'ok': false, 'error': 'novel not found: $novelId'};
      }
      final path = novel.contentDatabasePath;
      if (path == null || path.isEmpty) {
        return {'ok': false, 'error': 'novel content database is unavailable'};
      }
      final chapters = await ref
          .read(novelContentServiceProvider(path))
          .getChapters();
      return {
        'ok': true,
        'novel_id': novel.id,
        'title': novel.title,
        'chapters': [
          for (final chapter in chapters)
            if (chapter.isChapter)
              <String, dynamic>{
                'id': chapter.id,
                'chapter_num': chapter.chapterNum,
                'title': chapter.numberedTitle,
                'word_count': chapter.wordCount,
                'updated_at': chapter.updatedAt.toIso8601String(),
              },
        ],
      };
    } catch (error, stackTrace) {
      _log.error(
        '[RemoteBridge] listChapters failed novelId=$novelId error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      return {'ok': false, 'error': 'failed to load chapter list'};
    }
  }

  final coordinator = AssistantCoordinator(
    bridge: bridge,
    dao: appDb.assistantSessionDao,
    inboxDao: appDb.assistantInboxDao,
    aiPromptService: promptService,
    usageService: usageService,
    clientFactory: clientFactory,
    readAiSettings: () => ref.read(aiSettingsProvider),
    listNovels: listNovels,
    startJob: (novelId, seed, {required chatId, required channelType}) async {
      // ref.container = root ProviderContainer，供 startHeadlessRun 内部
      // 调 runHeadlessSessionTurn / ChatTurnRunner（二者签名要求 ProviderContainer）。
      final container = ref.container;
      final runTitle = _runTitleFromSeed(seed);
      // 注入远程观察指示（仅 prompt 文本，让 Orchestrator 调 Run notify 上报进度/提问）。
      final seededText = '$_remoteRunSeedPrefix$seed';
      // 解析 Assistant 会话（run agent 的 notify 写入该会话的 inbox）。
      final assistantSession = await appDb.assistantSessionDao
          .getOrCreateByChat(channelType: channelType, chatId: chatId);
      final assistantSessionId = assistantSession.id;
      // notify 回调：run agent 调 `Run notify` 时写入 assistant_inbox，
      // 给 Assistant 下一轮 turn 组装 context 时注入。
      // question/error 额外即时 bridge.sendToUser 推微信，让 run 进行中用户不再全程静默；
      // progress/complete 仅写 inbox，由 Assistant 下一轮汇总，避免刷屏。
      Future<Map<String, dynamic>> notifyCallback(
        Map<String, dynamic> command,
      ) async {
        final action = command['action']?.toString() ?? 'progress';
        final content = command['content']?.toString() ?? '';
        final sourceRef = command['source_ref']?.toString();
        try {
          await appDb.assistantInboxDao.append(
            assistantSessionId: assistantSessionId,
            source: 'run_agent',
            messageType: action,
            content: content,
            sourceRef: sourceRef,
          );
        } catch (error, stackTrace) {
          _log.error(
            '[RemoteBridge] notify inbox write failed '
            'assistantSession=$assistantSessionId action=$action error=$error',
            error: error,
            stackTrace: stackTrace,
          );
          return {'ok': false, 'error': '$error'};
        }
        // question/error 即时推送到微信（run 进行中用户不再全程静默）。
        // 用与 RunOutputForwarder 一致的【run 标题】前缀，让用户区分多个并行 run。
        if (action == 'question' || action == 'error') {
          final labeled = '【$runTitle】$content';
          final ok = await bridge.sendToUser(chatId, labeled);
          if (!ok) {
            _log.warning(
              '[RemoteBridge] notify forward failed chatId=$chatId '
              'action=$action chars=${labeled.length}',
            );
          }
        }
        return {'ok': true};
      }

      final result = await startHeadlessRun(
        container,
        novelId: novelId,
        seed: seededText,
        title: runTitle,
        notifyCallback: notifyCallback,
      );
      switch (result.outcome) {
        case HeadlessRunOutcome.started:
          final sessionId = result.sessionId!;
          // 写订阅行：remote_chat → chatId（兼作 Assistant↔run 归属关联）。
          // try-catch：run 已启动，订阅行写入失败不回滚 run，仅记日志（转发不会生效）。
          try {
            await appDb.sessionSubscriptionsDao.add(
              sessionId: sessionId,
              subscriberType: sessionSubscriberRemoteChat,
              targetId: chatId,
              channelType: channelType,
            );
          } catch (error, stackTrace) {
            _log.error(
              '[RemoteBridge] startJob subscription write failed '
              'session=$sessionId chatId=$chatId',
              error: error,
              stackTrace: stackTrace,
            );
          }
          // 注册 forwarder — 即使订阅行写入失败也尝试注册内存监听
          // （内存监听不依赖 DB 行，转发靠内存订阅即可工作到 app 重启）。
          // assistantSessionId 已在 startJob 顶部解析，崩溃兜底时写其 inbox。
          try {
            await ref
                .read(runOutputForwarderProvider)
                .register(
                  sessionId: sessionId,
                  runTitle: runTitle,
                  chatId: chatId,
                  channelType: channelType,
                  assistantSessionId: assistantSessionId,
                );
          } catch (error, stackTrace) {
            _log.error(
              '[RemoteBridge] startJob forwarder register failed '
              'session=$sessionId chatId=$chatId',
              error: error,
              stackTrace: stackTrace,
            );
          }
          return {
            'ok': true,
            'status': 'started',
            'job_id': sessionId,
            'job_title': runTitle,
          };
        case HeadlessRunOutcome.alreadyRunning:
          // 调用方 Assistant 据此区分「已启动」与「已在跑」，避免误报。
          return {'ok': true, 'status': 'already_running'};
        case HeadlessRunOutcome.novelUnavailable:
          return {
            'ok': false,
            'error': 'novel or its content database is unavailable',
          };
        case HeadlessRunOutcome.noValidModel:
          return {
            'ok': false,
            'error': 'no valid chat model configured for this novel',
          };
        case HeadlessRunOutcome.failed:
          return {'ok': false, 'error': result.error ?? 'start_job failed'};
      }
    },
    jobStatus: (jobId, {required chatId, required channelType}) async {
      // 归属校验：防跨 chat 越权查询其他会话的 Job 状态。
      if (!await _isRunOwnedByChat(appDb, jobId, chatId)) {
        return {
          'ok': false,
          'error': 'job not found or not owned by this chat',
        };
      }
      final container = ref.container;
      final runtime = container.read(aiChatRuntimeProvider(jobId));
      final session = container.read(aiChatSessionProvider(jobId));
      final isRunning = runtime.isRequestInFlight;

      // 若 session 未在内存（app 重启后 forwarder 未重挂），recent_output 为空。
      // forwarder 已注册时 session 因 listen 保活，messages 在场。
      final recent = session.isLoaded
          ? _recentAssistantTexts(session.messages)
          : const <String>[];

      return {
        'ok': true,
        'state': isRunning ? 'running' : 'idle',
        'title': session.title,
        'message_count': session.messages.length,
        'recent_output': recent,
      };
    },
    sendToJob: (jobId, text, {required chatId, required channelType}) async {
      // 归属校验：防跨 chat 越权向其他会话的 Job 注入消息。
      if (!await _isRunOwnedByChat(appDb, jobId, chatId)) {
        return {
          'ok': false,
          'error': 'job not found or not owned by this chat',
        };
      }
      final container = ref.container;
      final isRunning = container
          .read(aiChatRuntimeProvider(jobId))
          .isRequestInFlight;

      if (isRunning) {
        final agent = container
            .read(aiChatRuntimeProvider(jobId).notifier)
            .agent;
        if (agent != null) {
          // a. steer — 注入 agent steering 队列，下一个 LLM round 前 drain 生效。
          agent.steer(
            AgentMessage.user(
              id: 'steer_${DateTime.now().millisecondsSinceEpoch}',
              content: text,
            ),
          );
          // 同时 addUserMessage 进 session transcript（transcript 完整性）。
          // turn 结束时由 headless turn 的 _persistHeadlessCompletedMessages 落库。
          container
              .read(aiChatSessionProvider(jobId).notifier)
              .addUserMessage(text);
          _log.info(
            '[RemoteBridge] sendToJob steered jobId=$jobId chatId=$chatId',
          );
          return {'ok': true, 'status': 'steered'};
        }
        // runtime 说在跑但 agent 为 null — 状态不一致，回退到 idle 续跑路径。
        _log.warning(
          '[RemoteBridge] sendToJob: isRequestInFlight but agent is null, '
          'falling back to idle resume jobId=$jobId',
        );
      }

      // b. idle — 续跑：用户消息作为新 turn 的 seed。
      // 需从 DB 查 session 的 novelId + novel 的 databasePath。
      final sessionRow = await appDb.aiChatSessionDao.getById(jobId);
      if (sessionRow == null) {
        return {'ok': false, 'error': 'job session not found in database'};
      }
      final novelId = sessionRow.novelId;
      final novel = await appDb.novelDao.get(novelId);
      final databasePath = novel?.contentDatabasePath;
      if (novel == null || databasePath == null || databasePath.isEmpty) {
        return {
          'ok': false,
          'error': 'novel or content database unavailable for this job',
        };
      }

      // 后台续跑（不 await — 工具立即返回，Job 在后台继续）。
      // runHeadlessSessionTurn 自持 keepAlive + startRequest/markRequestIdle，
      // seed 落库 + ensureHeadlessSessionLoaded 均在内部完成。
      unawaited(
        runHeadlessSessionTurn(
          container,
          sessionId: jobId,
          databasePath: databasePath,
          novel: novel,
          seed: text,
        ).then((outcome) {
          _log.info(
            '[RemoteBridge] sendToJob idle resume completed '
            'jobId=$jobId status=${outcome.status.name}',
          );
        }),
      );
      return {'ok': true, 'status': 'resumed'};
    },
    createNovel: createNovel,
    editNovel: editNovel,
    listChapters: listChapters,

    onUsageChanged: onUsageChanged,
  );
  coordinator.start();

  ref.onDispose(() {
    coordinator.stop();
  });

  // 触发自动恢复：读 app_settings 中凭证 → 免扫码恢复 bridge + 重挂 forwarder。
  // 非阻塞 — FutureProvider 异步执行，coordinator 不依赖恢复结果即可工作
  // （handler 已注册，bridge 启动后消息自然流入）。
  ref.read(remoteBridgeAutoRestoreProvider);

  return coordinator;
});
