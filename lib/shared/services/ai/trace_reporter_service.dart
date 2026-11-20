// 职责: 构造匿名 trace 事件并委托持久化 Outbox 异步投递。
// 关联文件:
//   lib/shared/services/device_id_service.dart
//   lib/shared/services/anonymous_outbox_service.dart
//   lib/shared/agent/hooks/trace_hook.dart
//   lib/shared/services/ai/tool_error_normalize.dart
//   lib/shared/agent/client/provider_history_preflight.dart
//

import 'package:reveric/shared/utils/ai_error.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';

import '../../agent/client.dart'
    show
        AiUsage,
        IncompleteModelResponseException,
        IncompleteResponseReason,
        isContextLengthExceeded,
        isTransientNetworkError,
        toolCallIncompleteErrorCode;
import '../../agent/client/provider_history_preflight.dart'
    show ProviderHistoryValidationException;
import '../../agent/hooks/todo_continuation_hook.dart'
    show UnfinishedTodoSnapshot;
import '../../app_config.dart' show appVersion;
import '../../database/app_database.dart' show GenerationTask;
import '../../logger/app_logger.dart';
import '../anonymous_outbox_service.dart';
import '../device_id_service.dart';
import 'tool_error_normalize.dart'
    show
        codemodeAnonymousFailure,
        sanitizeExceptionMessage,
        sanitizeToolInput,
        sanitizeToolTraceToken;

final _log = AppLogger.forModule('TraceReporter');

/// 将 trace 事件写入持久化 Outbox，由共享调度器负责批量上报与重试。
class TraceReporterService {
  final DeviceIdService _deviceIdService;
  final AnonymousOutboxService _outbox;
  final String _platform;

  // session 级别累计（用于 session_end 上报）
  //
  // ⚠️ 并发不安全：这是单例上的一组共享裸字段，onSessionStart 重置、
  // onTurnEnd 累加。当前并发 session 下会被互相清零/混算。
  // 现在不出错只因为唯一消费方 onSessionEnd 是 dead code（从未调用），
  // 启用匿名诊断时，turn_end 按 turn 投递，可按 session_id 聚合。
  // 接入 onSessionEnd 前必须先修复：按 sessionId 分桶
  // （Map<String, 累计器>），否则并发 session 的 session_end 累计值会错乱。
  int _sessionRequestCount = 0;
  int _sessionToolCallCount = 0;
  int _sessionInputTokens = 0;
  int _sessionOutputTokens = 0;
  int _sessionCacheReadTokens = 0;
  int _sessionCacheWriteTokens = 0;
  int _sessionReasoningTokens = 0;

  TraceReporterService({required this._deviceIdService, required this._outbox})
    : _platform = _detectPlatform() {
    _log.info('init version=$appVersion platform=$_platform');
  }

  /// Session 开始：重置 session 级累计 + 入队 session_start。
  Future<void> onSessionStart(
    String sessionId,
    String model, {
    String sessionMode = 'chat',
  }) async {
    _log.info(
      'onSessionStart sessionId=$sessionId model=$model mode=$sessionMode',
    );
    _sessionRequestCount = 0;
    _sessionToolCallCount = 0;
    _sessionInputTokens = 0;
    _sessionOutputTokens = 0;
    _sessionCacheReadTokens = 0;
    _sessionCacheWriteTokens = 0;
    _sessionReasoningTokens = 0;
    await _enqueue(
      sessionId: sessionId,
      model: model,
      sessionMode: sessionMode,
      eventType: 'session_start',
    );
  }

  /// Turn 开始：入队 turn_start。
  Future<void> onTurnStart(
    String sessionId,
    String model, {
    String sessionMode = 'chat',
  }) async {
    if (_log.isDebugEnabled) {
      _log.debug(
        'onTurnStart sessionId=$sessionId model=$model mode=$sessionMode',
      );
    }
    await _enqueue(
      sessionId: sessionId,
      model: model,
      sessionMode: sessionMode,
      eventType: 'turn_start',
    );
  }

  /// Turn 结束：累加 session 级 + 入队 turn_end。
  Future<void> onTurnEnd(
    String sessionId,
    String model,
    int requestCount,
    int toolCallCount,
    AiUsage usage, {
    String sessionMode = 'chat',
  }) async {
    if (_log.isDebugEnabled) {
      _log.debug(
        'onTurnEnd sessionId=$sessionId model=$model mode=$sessionMode '
        'req=$requestCount tools=$toolCallCount '
        'in=${usage.inputTokens} out=${usage.outputTokens}',
      );
    }
    _sessionRequestCount += requestCount;
    _sessionToolCallCount += toolCallCount;
    _sessionInputTokens += usage.inputTokens;
    _sessionOutputTokens += usage.outputTokens;
    _sessionCacheReadTokens += usage.cacheReadTokens;
    _sessionCacheWriteTokens += usage.cacheWriteTokens;
    _sessionReasoningTokens += usage.reasoningTokens;

    await _enqueue(
      sessionId: sessionId,
      model: model,
      sessionMode: sessionMode,
      eventType: 'turn_end',
      requestCount: requestCount,
      toolCallCount: toolCallCount,
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      cacheReadTokens: usage.cacheReadTokens,
      cacheWriteTokens: usage.cacheWriteTokens,
      reasoningTokens: usage.reasoningTokens,
    );
    // Flush is best-effort telemetry. Do not hold the Agent finalizer on a
    // network timeout or a database isolate that is already being torn down.
    unawaited(flush());
  }

  /// Session 结束：入队 session_end（含全 session 累计）+ flush。
  ///
  /// TODO: 当前未被调用。代码中没有明确的 session 关闭事件
  /// （panel dispose 可能是切换 novel 导致，非真正 session 结束；
  /// activeSessionId 变化也无"旧 session 结束"回调）。
  /// turn_end 已逐 turn 上报用量，session_end 累计数据可在分析侧聚合，
  /// 因此暂不阻塞。待有明确 session 生命周期事件后接入。
  Future<void> onSessionEnd(
    String sessionId,
    String model, {
    String sessionMode = 'chat',
  }) async {
    await _enqueue(
      sessionId: sessionId,
      model: model,
      sessionMode: sessionMode,
      eventType: 'session_end',
      requestCount: _sessionRequestCount,
      toolCallCount: _sessionToolCallCount,
      inputTokens: _sessionInputTokens,
      outputTokens: _sessionOutputTokens,
      cacheReadTokens: _sessionCacheReadTokens,
      cacheWriteTokens: _sessionCacheWriteTokens,
      reasoningTokens: _sessionReasoningTokens,
    );
    await flush();
  }

  Future<void> _enqueue({
    required String sessionId,
    required String model,
    String? providerId,
    required String sessionMode,
    required String eventType,
    int requestCount = 0,
    int toolCallCount = 0,
    int inputTokens = 0,
    int outputTokens = 0,
    int cacheReadTokens = 0,
    int cacheWriteTokens = 0,
    int reasoningTokens = 0,
    String message = '',
    String? eventId,
  }) async {
    final occurredAt = DateTime.now().toUtc();
    final deviceId = await _deviceIdService.getOrCreate();
    await _outbox.enqueue(
      AnonymousOutboxEventInput(
        channel: AnonymousOutboxChannel.trace,
        endpoint: AnonymousOutboxEndpoint.trace,
        deviceId: deviceId,
        occurredAt: occurredAt,
        eventId: eventId,
        payload: {
          'device_id': deviceId,
          'session_id': sessionId,
          'session_mode': sessionMode,
          'model': model,
          'provider_kind': anonymousProviderKind(providerId),
          'event_type': eventType,
          'app_version': appVersion,
          'platform': _platform,
          'request_count': requestCount,
          'tool_call_count': toolCallCount,
          'input_tokens': inputTokens,
          'output_tokens': outputTokens,
          'cache_read_tokens': cacheReadTokens,
          'cache_write_tokens': cacheWriteTokens,
          'reasoning_tokens': reasoningTokens,
          'message': message,
          'occurred_at': occurredAt.toIso8601String(),
        },
      ),
    );
    if (_log.isDebugEnabled) {
      _log.debug('enqueue type=$eventType');
    }
  }

  /// 记录用户发起的图像或视频生成，任务结果不影响这条使用记录。
  Future<void> onMediaGenerationAttempt(GenerationTask task) async {
    try {
      if (!_outbox.canEnqueue) {
        return;
      }
      final identity = sha256.convert(
        utf8.encode('${task.id}:${task.createdAt.millisecondsSinceEpoch}'),
      );
      final eventId = 'media-generation:$identity';
      await _enqueue(
        sessionId: eventId,
        eventId: eventId,
        model: task.modelId,
        providerId: task.providerId,
        sessionMode: 'production',
        eventType: 'media_generation_attempted',
        message: jsonEncode({
          'media_kind': task.kind.name,
          'provider_type': task.providerType,
        }),
      );
    } catch (error, stack) {
      _log.warning(
        'Failed to queue media generation trace error=$error\n$stack',
      );
    }
  }

  /// LLM 请求失败：入队 request_error 诊断事件，走独立的 requestError
  /// outbox channel 投递到配置的匿名诊断地址。
  ///
  /// [error] 是 agent 抛出的原始异常对象，会经 [classifyRequestError]
  /// 转为分类化 error_code，同时附带 exception_type / exception_message
  /// 诊断字段。
  Future<void> onRequestError(
    String sessionId,
    String model,
    Object error, {
    String sessionMode = 'chat',
    String? providerId,
  }) async {
    final category = classifyRequestError(error);
    if (!shouldReportRequestError(category)) {
      if (_log.isDebugEnabled) {
        _log.debug(
          'onRequestError skipped noise sid=$sessionId category=$category',
        );
      }
      return;
    }
    _log.info(
      'onRequestError sid=$sessionId model=$model mode=$sessionMode '
      'category=$category',
    );
    await _enqueueRequestError(
      sessionId: sessionId,
      model: model,
      providerId: providerId,
      sessionMode: sessionMode,
      errorType: 'request_error',
      errorCode: category,
      error: error,
    );
  }

  /// 将同一 turn 的流式问题合并成一条 trace，不进入 request error 表。
  Future<void> onStreamRetrySummary(
    String sessionId,
    String model, {
    required Map<String, int> counts,
    required String outcome,
    String sessionMode = 'chat',
    String? providerId,
  }) async {
    await _enqueue(
      sessionId: sessionId,
      model: model,
      providerId: providerId,
      sessionMode: sessionMode,
      eventType: 'stream_retry_summary',
      message: jsonEncode({'outcome': outcome, 'codes': counts}),
    );
  }

  /// 正常结束时仍有未完成 Todo：记录本次 process 的请求/工具次数与 Todo
  /// 分布，用于评估模型早停。只上报计数，不含 Todo 正文。
  Future<void> onTodoUnfinishedAtDone(
    String sessionId,
    String model, {
    String? providerId,
    required String sessionMode,
    required UnfinishedTodoSnapshot snapshot,
  }) {
    return _enqueue(
      sessionId: sessionId,
      model: model,
      providerId: providerId,
      sessionMode: sessionMode,
      eventType: 'todo_unfinished_at_done',
      requestCount: snapshot.requestCount,
      toolCallCount: snapshot.toolCallCount,
      message: jsonEncode(snapshot.toTraceJson()),
    );
  }

  /// 用户/父运行取消属于正常控制流，写 trace 供定位来源，不进入错误表。
  Future<void> onTurnCancelled(
    String sessionId,
    String model, {
    required String source,
    String sessionMode = 'chat',
  }) {
    return _enqueue(
      sessionId: sessionId,
      model: model,
      sessionMode: sessionMode,
      eventType: 'turn_cancelled',
      message: source,
    );
  }

  /// 构造 request/stream error 诊断事件并写入 requestError outbox channel。
  Future<void> _enqueueRequestError({
    required String sessionId,
    required String model,
    String? providerId,
    required String sessionMode,
    required String errorType,
    required String errorCode,
    required Object error,
  }) async {
    final occurredAt = DateTime.now().toUtc();
    final deviceId = await _deviceIdService.getOrCreate();
    await _outbox.enqueue(
      AnonymousOutboxEventInput(
        channel: AnonymousOutboxChannel.requestError,
        endpoint: AnonymousOutboxEndpoint.requestError,
        deviceId: deviceId,
        occurredAt: occurredAt,
        payload: {
          'device_id': deviceId,
          'session_id': sessionId,
          'session_mode': sessionMode,
          'model': model,
          'provider_kind': anonymousProviderKind(providerId),
          'error_type': errorType,
          'error_code': errorCode,
          'exception_type': safeErrorTypeName(error),
          'exception_message': sanitizeExceptionMessage(error),
          'app_version': appVersion,
          'platform': _platform,
          'occurred_at': occurredAt.toIso8601String(),
        },
      ),
    );
    unawaited(_outbox.flush());
  }

  /// Tool 执行失败：入队 tool_call_error 事件。
  ///
  /// [result] 为工具返回 map（含 `error_code` / `collection` / `enum_field`）。
  /// Tool 执行失败：入队 tool_call_error 诊断事件，走独立的 toolError
  /// outbox channel 投递到配置的匿名诊断地址。
  ///
  /// [result] 为工具返回 map。Path A（工具抛异常被 agent.dart catch）
  /// 的 result 含 `exception_type` / `exception_message` / `stack_top` /
  /// `tool_input` 诊断字段；Path B（工具返回 failure result）的 result
  /// 经 `normalizeToolFailureResult` 归一化后含 `error_code` /
  /// `collection` / `enum_field`。Path B 的 `error` 也必须上报：其中包含
  /// 枚举实际值、允许值、缺失字段等排错所需原因。
  Future<void> onToolCallError(
    String sessionId,
    String model,
    String toolName, {
    String sessionMode = 'chat',
    String? providerId,
    Map<String, dynamic>? result,
    Map<String, dynamic>? toolInput,
    String errorKind = 'execution_error',
  }) async {
    if (toolName == 'Codemode') {
      result = codemodeAnonymousFailure(result, toolInput);
    }
    final errorCode = (result?['error_code'] as String?) ?? errorKind;
    if (toolName == 'SpawnAgent' &&
        result?['failure_kind'] == 'contextWindowExhausted') {
      return;
    }
    final structuredError = result?['error'];
    final exceptionType =
        result?['exception_type'] as String? ??
        (structuredError == null ? '' : 'ToolFailure');
    final exceptionMessage = _enrichToolErrorMessage(
      result: result,
      structuredError: structuredError,
    );
    final stackTop = result?['stack_top'] as String? ?? '';
    final sanitizedToolInput =
        result?['tool_input'] as String? ??
        sanitizeToolInput(
          toolName,
          toolInput ?? const <String, dynamic>{},
          result: result,
        );

    if (_log.isDebugEnabled) {
      _log.debug(
        'onToolCallError sid=$sessionId model=$model tool=$toolName '
        'errorCode=$errorCode exceptionType=$exceptionType',
      );
    }

    final occurredAt = DateTime.now().toUtc();
    final deviceId = await _deviceIdService.getOrCreate();
    await _outbox.enqueue(
      AnonymousOutboxEventInput(
        channel: AnonymousOutboxChannel.toolError,
        endpoint: AnonymousOutboxEndpoint.toolError,
        deviceId: deviceId,
        occurredAt: occurredAt,
        payload: {
          'device_id': deviceId,
          'session_id': sessionId,
          'session_mode': sessionMode,
          'tool_name': toolName,
          'model': model,
          'provider_kind': toolName == 'SpawnAgent'
              ? normalizeAnonymousProviderKind(result?['provider_kind'])
              : anonymousProviderKind(providerId),
          'error_code': errorCode,
          'exception_type': exceptionType,
          'exception_message': exceptionMessage,
          'stack_top': stackTop,
          'tool_input': sanitizedToolInput,
          'app_version': appVersion,
          'platform': _platform,
          'occurred_at': occurredAt.toIso8601String(),
        },
      ),
    );
    unawaited(_outbox.flush());
  }

  /// 请求 Outbox 立即投递当前已到期事件。
  Future<void> flush() => _outbox.flush();

  /// 应用退出时 flush 残留事件。
  void dispose() {
    unawaited(_outbox.flush());
  }

  static String _detectPlatform() {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }
}

/// 在工具失败消息上附加结构化诊断字段，使匿名错误库能区分失败原因。
///
/// 例如 SpawnAgent 的 failure result 携带 `failure_kind`（provider/network/…）与
/// `status_code`，但此前只上报了一句 "sub-agent failed"；拼接后下一批记录即可
/// 判断子 agent 失败归属。消息仍经 [sanitizeExceptionMessage] 截断到 500 字符。
String _enrichToolErrorMessage({
  required Map<String, dynamic>? result,
  required Object? structuredError,
}) {
  var message =
      result?['exception_message'] as String? ??
      (structuredError == null ? '' : structuredError.toString());
  final failureKind = result?['failure_kind'] as String?;
  final statusCode = result?['status_code'];
  final failureStage = sanitizeToolTraceToken(
    result?['failure_stage'] as String?,
  );
  final failureType = sanitizeToolTraceToken(
    result?['failure_type'] as String?,
  );
  if (failureKind != null ||
      statusCode != null ||
      failureStage.isNotEmpty ||
      failureType.isNotEmpty) {
    final extra = <String>[
      if (failureKind != null && failureKind.isNotEmpty)
        'failure_kind=$failureKind',
      if (statusCode != null) 'status_code=$statusCode',
      if (failureStage.isNotEmpty) 'failure_stage=$failureStage',
      if (failureType.isNotEmpty) 'failure_type=$failureType',
    ].join(' ');
    message = message.isEmpty ? extra : '$message | $extra';
  }
  return sanitizeExceptionMessage(message);
}

// ---------------------------------------------------------------------------
// 错误分类 — 将原始异常对象转为匿名化的分类标签
// ---------------------------------------------------------------------------

/// 是否应将 [classifyRequestError] 结果写入 trace。
///
/// `http_401` / `http_402` / `http_403` / `http_404` / `http_429` 与
/// `network_connection` / `context_length_exceeded` 是凭证、余额、权限、资源缺失、限流、短暂断连或上下文超限等
/// 已知拒绝，不上报，把配额留给可行动的客户端、服务端与工具失败。
bool shouldReportRequestError(String category) {
  return category != 'http_401' &&
      category != 'http_402' &&
      category != 'http_403' &&
      category != 'http_429' &&
      category != 'http_404' &&
      category != 'network_connection' &&
      category != 'context_length_exceeded';
}

/// 将 LLM 请求异常分类为匿名化标签。
///
/// 复用共享状态码解析 [tryReadStatusCode] 与 [isTransientNetworkError]，
/// 不在此重复实现错误判定逻辑。返回值写入 trace event 的 message 字段，
/// 分析侧按前缀做 GROUP BY。
///
/// 匿名安全：不透出原始 exception 文本、API key、response body。
/// 无法归入预定义类别时，附带清洗后的 [runtimeType]（如
/// `unknown:StateError`），便于分析侧区分真实失败模式。
String classifyRequestError(Object error) {
  if (error is ProviderHistoryValidationException) {
    return error.errorCode;
  }
  if (error is IncompleteModelResponseException) {
    // thinking-only 自动续跑耗尽是独立故障模式：模型连续多轮只思考不产出，
    // 与「单轮就没产出」的排查方向不同，用独立 code 以免在统计里混在一起。
    if (error.thinkingOnlyRounds != null) {
      return 'response_incomplete_thinking_loop';
    }
    // 流断在 tool call 参数中途与真正的全空响应重试行为相同，但排查方向
    // 不同（provider 流式稳定性 vs 模型本身），用独立 code 以免统计里混在一起。
    if (error.hadIncompleteToolCall) {
      return toolCallIncompleteErrorCode;
    }
    return switch (error.reason) {
      IncompleteResponseReason.outputLimit => 'response_incomplete_length',
      IncompleteResponseReason.contentFiltered =>
        'response_incomplete_content_filter',
      IncompleteResponseReason.missingFinalAnswer =>
        'response_incomplete_no_final_answer',
      IncompleteResponseReason.emptyResponse => 'response_incomplete_empty',
      IncompleteResponseReason.incompleteToolCall =>
        toolCallIncompleteErrorCode,
    };
  }
  if (isContextLengthExceeded(error)) {
    return 'context_length_exceeded';
  }
  final statusCode = tryReadStatusCode(error);
  if (statusCode != null) {
    return switch (statusCode) {
      400 => 'http_400',
      401 => 'http_401',
      403 => 'http_403',
      408 => 'http_408',
      429 => 'http_429',
      >= 500 && < 600 => 'http_5xx',
      _ => 'http_$statusCode',
    };
  }
  if (error is TimeoutException) {
    return 'network_timeout';
  }
  if (isTransientNetworkError(error)) {
    return 'network_connection';
  }
  if (error is FormatException || _isResponsesSseSchemaTypeError(error)) {
    return 'schema_parse';
  }
  // openai_dart SSE 中途 error 事件：HTTP 200 后抛 StreamException，无 statusCode。
  // 用类型名匹配，避免本文件 import openai_dart（与 TraceReporter 解耦）。
  if (safeErrorTypeName(error) == 'StreamException') {
    return 'stream_inline_error';
  }
  return 'unknown:${safeErrorTypeName(error)}';
}

/// 将 stream retry 异常分类为匿名化标签。
///
/// 返回值用于 turn 末尾的 `stream_retry_summary`，前缀 `stream_retry_`
/// 以区别于最终失败的 request_error。
String classifyStreamError(Object error) {
  if (error is IncompleteModelResponseException) {
    return 'stream_retry_${classifyRequestError(error)}';
  }
  final statusCode = tryReadStatusCode(error);
  if (statusCode != null && statusCode >= 500 && statusCode < 600) {
    return 'stream_retry_http_5xx';
  }
  if (isTransientNetworkError(error)) {
    return 'stream_retry_network';
  }
  if (safeErrorTypeName(error) == 'StreamException') {
    return 'stream_retry_inline_error';
  }
  return 'stream_retry_unknown:${safeErrorTypeName(error)}';
}

/// 清洗 [runtimeType] 为可 GROUP BY 的安全标签（去掉泛型尖括号等）。
String safeErrorTypeName(Object error) {
  final cleaned = error.runtimeType.toString().replaceAll(
    RegExp(r'[^A-Za-z0-9_]'),
    '',
  );
  return cleaned.isEmpty ? 'Object' : cleaned;
}

/// open_responses 对缺失的必填 String 字段会抛出裸 TypeError。
///
/// 只根据稳定的 Dart cast 片段分类，不改写异常，也不影响 Agent 的重试逻辑。
bool _isResponsesSseSchemaTypeError(Object error) {
  if (!safeErrorTypeName(error).endsWith('TypeError')) {
    return false;
  }
  final message = error.toString();
  return message.contains("type 'Null' is not a subtype of type 'String'") ||
      message.contains('Null is not a subtype of String');
}

/// 只上报渠道类别，不上报用户自定义供应商 ID、地址或凭据。
String anonymousProviderKind(String? providerId) => switch (providerId) {
  null || '' => 'unknown',
  final id when id.startsWith('debug_') => 'unknown',
  _ => 'custom',
};

String normalizeAnonymousProviderKind(Object? value) => switch (value) {
  'custom' => 'custom',
  _ => 'unknown',
};
