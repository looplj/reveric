// 职责: Provider client 抽象 — 统一 AI SDK 调用接口、共享模型、Stream 事件类型与重试装饰器
// 关联文件:
//   lib/shared/agent/client/anthropic_client.dart
//   lib/shared/agent/client/gemini_client.dart
//   lib/shared/agent/client/openai_client.dart
//   lib/shared/agent/client/openai_responses_client.dart
//   lib/shared/services/ai/provider_initializer.dart
//   lib/shared/services/ai/ai_chat_service.dart
//
// ┌─────────────────────────────────────────────────────────────────────────────
// │ 架构说明 (IoC / Dependency Inversion)
// │
// │   agent/ 模块（upper layer） ←──  client.dart（abstraction） ──→  client/ 实现
// │
// │   依赖方向:  agent/ → client.dart ← client/
// │   - agent/ 只依赖 client.dart 中定义的接口与类型
// │   - client/ 下面的具体客户端实现依赖 client.dart
// │   - client.dart 不依赖 client/ 下的任何实现
// │   - 禁止 agent/ 模块直接 import client/ 目录下的实现文件
// └─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' show ClientException;

import '../logger/app_logger.dart';
import '../utils/ai_error.dart';

import 'agent_tool_dispatcher.dart' show ToolDef;
import 'message.dart' show AgentMessage, ToolCall;
import 'agent_config.dart' show AgentConfig;

// ---------------------------------------------------------------------------
// 通用 Token Usage 模型
// ---------------------------------------------------------------------------

/// 通用 Token Usage 统计
///
/// 统一 OpenAI、Anthropic、Gemini 等 Provider 的用量数据结构。
///
/// inputTokens 包含 cached tokens。
/// 净输入 (uncached) = inputTokens - cacheReadTokens - cacheWriteTokens。
/// 无值即 0，所有字段均为非空。
@immutable
class AiUsage {
  /// 输入（prompt）token 总数，含 cached tokens。
  /// 对应 OpenAI: usage.prompt_tokens / Gemini: usage_metadata.prompt_token_count
  /// 对应 Anthropic: input_tokens + cache_creation_input_tokens + cache_read_input_tokens
  ///   (Anthropic 的 input_tokens 不含 cached tokens，需手工求和)
  final int inputTokens;

  /// 输出（completion）token 总数，含 reasoning tokens。
  /// 对应 OpenAI: usage.completion_tokens / Anthropic: usage.output_tokens / Gemini: usage_metadata.candidates_token_count
  final int outputTokens;

  /// Prompt cache 命中（读取）token 数，对应折扣定价。
  /// OpenAI: prompt_tokens_details.cached_tokens
  /// Anthropic: cache_read_input_tokens
  /// Gemini: usage_metadata.cached_content_token_count
  final int cacheReadTokens;

  /// Prompt cache 写入 token 数，全价 + 附加费。
  /// Anthropic: cache_creation_input_tokens
  /// OpenAI: 无此字段
  /// Gemini: 无此字段（cache write 通过独立 CachedContent API 完成，不出现在 generation response 中）
  final int cacheWriteTokens;

  /// 推理/思考 token 数（从 output 中单独统计）。
  /// OpenAI: completion_tokens_details.reasoning_tokens
  /// Anthropic: thinking tokens (output tokens 中拆分)
  /// Gemini: usage_metadata.thoughts_token_count
  /// DeepSeek: reasoning_tokens
  final int reasoningTokens;

  const AiUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
  });

  /// 总 tokens（input + output）
  int get totalTokens => inputTokens + outputTokens;

  /// 净输入 token（不含任何 cache）
  int get netInputTokens => inputTokens - cacheReadTokens - cacheWriteTokens;

  factory AiUsage.fromJson(Map<String, dynamic> json) {
    return AiUsage(
      inputTokens: (json['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (json['output_tokens'] as num?)?.toInt() ?? 0,
      cacheReadTokens: (json['cache_read_tokens'] as num?)?.toInt() ?? 0,
      cacheWriteTokens: (json['cache_write_tokens'] as num?)?.toInt() ?? 0,
      reasoningTokens: (json['reasoning_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
    if (cacheReadTokens != 0) 'cache_read_tokens': cacheReadTokens,
    if (cacheWriteTokens != 0) 'cache_write_tokens': cacheWriteTokens,
    if (reasoningTokens != 0) 'reasoning_tokens': reasoningTokens,
  };

  /// 是否包含任何实际用量数据
  bool get hasData =>
      inputTokens > 0 ||
      outputTokens > 0 ||
      cacheReadTokens > 0 ||
      cacheWriteTokens > 0 ||
      reasoningTokens > 0;

  const AiUsage.empty()
    : inputTokens = 0,
      outputTokens = 0,
      cacheReadTokens = 0,
      cacheWriteTokens = 0,
      reasoningTokens = 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiUsage &&
          runtimeType == other.runtimeType &&
          inputTokens == other.inputTokens &&
          outputTokens == other.outputTokens &&
          cacheReadTokens == other.cacheReadTokens &&
          cacheWriteTokens == other.cacheWriteTokens &&
          reasoningTokens == other.reasoningTokens;

  @override
  int get hashCode => Object.hash(
    inputTokens,
    outputTokens,
    cacheReadTokens,
    cacheWriteTokens,
    reasoningTokens,
  );

  @override
  String toString() =>
      'AiUsage(inputTokens: $inputTokens, outputTokens: $outputTokens, '
      'cacheReadTokens: $cacheReadTokens, cacheWriteTokens: $cacheWriteTokens, '
      'reasoningTokens: $reasoningTokens)';
}

// ---------------------------------------------------------------------------
// Provider-agnostic response / stream types
// ---------------------------------------------------------------------------

class ChatResponse {
  final String text;
  final String thinking;
  final String? signature;
  final List<String> encryptedContents;
  final List<ToolCall> toolCalls;
  final AiUsage? usage;

  /// Provider 报告的结束原因；未报告时为 null。
  final StreamFinishReason? finishReason;

  const ChatResponse({
    this.text = '',
    this.thinking = '',
    this.signature,
    this.encryptedContents = const [],
    this.toolCalls = const [],
    this.usage,
    this.finishReason,
  });
}

sealed class StreamEvent {}

class TextDelta extends StreamEvent {
  final String text;
  TextDelta(this.text);
}

class ThinkingDelta extends StreamEvent {
  final String text;
  ThinkingDelta(this.text);
}

class SignatureDelta extends StreamEvent {
  final String signature;
  SignatureDelta(this.signature);
}

class EncryptedContentDelta extends StreamEvent {
  final String encryptedContent;
  EncryptedContentDelta(this.encryptedContent);
}

class ToolCallDelta extends StreamEvent {
  final String callId;
  final String toolName;
  final Map<String, dynamic> arguments;
  final bool isPartial;
  final List<int>? thoughtSignature;
  ToolCallDelta({
    required this.callId,
    required this.toolName,
    required this.arguments,
    this.isPartial = false,
    this.thoughtSignature,
  });
}

class StreamError extends StreamEvent {
  final String message;
  StreamError(this.message);
}

class StreamCancelled extends StreamEvent {
  StreamCancelled();
}

enum StreamFinishReason { stop, length, toolCalls, contentFilter, unknown }

class StreamComplete extends StreamEvent {
  final AiUsage? usage;
  final StreamFinishReason? finishReason;
  StreamComplete({this.usage, this.finishReason});
}

enum IncompleteResponseReason {
  outputLimit,
  contentFiltered,
  missingFinalAnswer,
  emptyResponse,

  /// 本轮没有任何完整 tool call，只留下参数未传完的半截调用。
  ///
  /// 与 [outputLimit] 分开：正文不一定被截断（可能只是一句前置说明），
  /// finishReason 也不一定是 length —— 断在工具参数中途的流经常报 stop。
  incompleteToolCall,
}

/// Provider 结束了响应，但没有产生可作为成功结果使用的最终输出。
///
/// 只携带分类与长度，不携带模型正文或 thinking，确保日志和匿名上报安全。
class IncompleteModelResponseException implements Exception {
  const IncompleteModelResponseException({
    required this.reason,
    required this.textChars,
    required this.thinkingChars,
    this.finishReason,
    this.thinkingOnlyRounds,
    this.hadIncompleteToolCall = false,
  });

  final IncompleteResponseReason reason;
  final StreamFinishReason? finishReason;
  final int textChars;
  final int thinkingChars;

  /// 本轮流结束时是否残留了参数未完整的 tool call。
  ///
  /// 「流断在 tool call 参数中途」与「真正的全空响应」重试行为相同（都按
  /// emptyResponse 原样重发），但排查方向不同：前者指向 provider 流式稳定性，
  /// 后者指向模型本身。匿名上报靠该标记区分两者。
  final bool hadIncompleteToolCall;

  /// 本次终态前连续经历了多少个「只思考、不产出」的轮次。
  ///
  /// 仅在 thinking-only 自动续跑耗尽时设置。匿名上报靠它区分「第一轮就失败」
  /// 与「续跑多轮仍未产出」——两者的排查方向完全不同。
  final int? thinkingOnlyRounds;

  @override
  String toString() =>
      'IncompleteModelResponseException('
      'reason=${reason.name}, finishReason=${finishReason?.name ?? 'none'}, '
      'textChars=$textChars, thinkingChars=$thinkingChars'
      '${hadIncompleteToolCall ? ', hadIncompleteToolCall=true' : ''}'
      '${thinkingOnlyRounds == null ? '' : ', thinkingOnlyRounds=$thinkingOnlyRounds'})';
}

const String toolCallIncompleteErrorCode = 'tool_call_incomplete';

// ---------------------------------------------------------------------------
// ProviderClient interface
// ---------------------------------------------------------------------------

abstract class ProviderClient {
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  });

  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  });

  Future<List<double>> embed(String text, {String? model});

  void cancel();
}

// ---------------------------------------------------------------------------
// 共享重试策略 — RetryDecorator（非流式 chat/embed）与 Agent（流式 round retry）共用
// ---------------------------------------------------------------------------

/// [DEBUG] 模拟流式中途断连的装饰器，用于 UI 测试 stream retry 效果。
///
/// 使用方法：在 [provider_initializer.dart:54] 把 `FlakyDecorator` 包在
/// `RetryDecorator` 内层即可激活。删除`FlakyDecorator`类和注入行即恢复。
class FlakyDecorator implements ProviderClient {
  FlakyDecorator({required this._inner});
  final ProviderClient _inner;
  int _callCount = 0;

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    _callCount++;
    if (_callCount == 1) {
      await Future.delayed(const Duration(milliseconds: 800));
      yield TextDelta('正在');
      await Future.delayed(const Duration(milliseconds: 300));
      yield TextDelta('查询章');
      await Future.delayed(const Duration(milliseconds: 300));
      yield TextDelta('节列表');
      await Future.delayed(const Duration(milliseconds: 500));
      yield ToolCallDelta(
        callId: 'test_call_1',
        toolName: 'Read',
        arguments: const {'path': '/chapters'},
      );
      await Future.delayed(const Duration(milliseconds: 400));
      yield TextDelta('…');
      await Future.delayed(const Duration(milliseconds: 200));
      // 模拟断连
      throw ClientException('Simulated mid-stream disconnection for UI test');
    }
    await Future.delayed(const Duration(milliseconds: 300));
    yield TextDelta('重试');
    await Future.delayed(const Duration(milliseconds: 200));
    yield TextDelta('成功！');
    await Future.delayed(const Duration(milliseconds: 400));
    yield TextDelta('这是第二次调用');
    await Future.delayed(const Duration(milliseconds: 300));
    yield TextDelta('的完整回复。');
    await Future.delayed(const Duration(milliseconds: 200));
    yield StreamComplete();
  }

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) {
    return _inner.chat(messages: messages, tools: tools, options: options);
  }

  @override
  Future<List<double>> embed(String text, {String? model}) async {
    return _inner.embed(text, model: model);
  }

  @override
  void cancel() => _inner.cancel();
}

/// 判定错误是否为短暂网络错误（可重试）。
///
/// RetryDecorator 的非流式重试与 Agent 的流式 round 重试共用此分类，
/// 避免两处各写一份导致判定漂移（Rule 7）。
bool isTransientNetworkError(Object error) {
  final statusCode = tryReadStatusCode(error);
  if (statusCode != null && statusCode >= 500 && statusCode < 600) {
    return true;
  }
  if (error is HandshakeException ||
      error is SocketException ||
      error is HttpException ||
      error is TimeoutException ||
      error is ClientException) {
    return true;
  }
  final message = error.toString();
  return message.contains('HandshakeException') ||
      message.contains('Connection terminated during handshake') ||
      message.contains('Connection closed before full header was received') ||
      message.contains('Connection reset by peer') ||
      message.contains('Connection refused') ||
      message.contains('Failed host lookup') ||
      _containsTransientHttpStatus(message) ||
      message.contains('SocketException') ||
      message.contains('TimeoutException');
}

/// 流式重试的指数退避延迟：`baseDelay * 2^(attempt-1)`，上限 [maxDelay]。
///
/// 与 RetryDecorator 的非流式重试共用同一退避曲线。[attempt] 从 1 开始。
Duration streamRetryDelay(
  int attempt, {
  Duration baseDelay = const Duration(milliseconds: 600),
  Duration maxDelay = const Duration(seconds: 5),
}) {
  final multiplier = pow(2, attempt - 1).toInt();
  final milliseconds = min(
    baseDelay.inMilliseconds * multiplier,
    maxDelay.inMilliseconds,
  );
  return Duration(milliseconds: milliseconds);
}

/// 流式响应已返回 HTTP 200 后，上游在流内用 error / failed 事件报告的失败。
class ProviderStreamException implements Exception {
  const ProviderStreamException({this.type, this.code, required this.message});

  final String? type;
  final String? code;
  final String message;

  @override
  String toString() =>
      'ProviderStreamException(type: $type, code: $code): $message';
}

/// 识别 HTTP 400 或流内错误中明确的上下文超限码，不从自由文本推断失败原因。
/// SDK 可能把错误码放在属性、响应体或 JSON message 中。
bool isContextLengthExceeded(Object error) {
  if (error is! ProviderStreamException && tryReadStatusCode(error) != 400) {
    return false;
  }
  const code = 'context_length_exceeded';
  bool containsCode(Object? value, int depth) {
    if (depth > 5) {
      return false;
    }
    if (value is Map) {
      return value['code'] == code ||
          value['type'] == code ||
          value['error_type'] == code ||
          containsCode(value['error'], depth + 1) ||
          containsCode(value['message'], depth + 1);
    }
    if (value is String && value.trimLeft().startsWith('{')) {
      try {
        return containsCode(jsonDecode(value), depth + 1);
      } on FormatException {
        return false;
      }
    }
    return false;
  }

  final dynamic providerError = error;
  for (final read in <Object? Function()>[
    () => {'code': providerError.code},
    () => {'type': providerError.type},
    () => providerError.body,
    () => providerError.message,
  ]) {
    try {
      if (containsCode(read(), 0)) {
        return true;
      }
    } on NoSuchMethodError {
      // 与 statusCode 的读取方式一致，SDK 未提供的属性不参与判定。
    }
  }
  return false;
}

bool _containsTransientHttpStatus(String message) {
  return RegExp(
    r'(?:status(?:Code)?|HTTP|ApiException)\D*5\d\d',
    caseSensitive: false,
  ).hasMatch(message);
}

/// 非流式 chat/embed 单次请求的总时长上限。
///
/// 非流式响应在服务端完成前不回任何字节，HTTP 层也没有读超时；移动端切后台
/// 后连接可能变成半开状态，服务端已返回而客户端永远等不到。超时抛出
/// [TimeoutException]，进入既有的短暂网络错误重试。
const Duration defaultNonStreamingRequestTimeout = Duration(minutes: 10);

class RetryDecorator implements ProviderClient {
  RetryDecorator({
    required this._inner,
    this.maxRetries = 2,
    this.retryRateLimits = false,
    this.baseDelay = const Duration(milliseconds: 600),
    this.maxDelay = const Duration(seconds: 5),
    this.requestTimeout = defaultNonStreamingRequestTimeout,
  });

  final ProviderClient _inner;
  final int maxRetries;
  final bool retryRateLimits;
  final Duration baseDelay;
  final Duration maxDelay;
  final Duration requestTimeout;
  final _log = AppLogger.forModule('RetryDecorator');

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) {
    return _runWithRetry(
      operation: 'chat',
      run: () =>
          _inner.chat(messages: messages, tools: tools, options: options),
    );
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) {
    // 流式重试由 Agent 层统一负责（round 局部语义，见 agent.dart 的 stream retry 循环）：
    // emit 前后的短暂网络错误都由 Agent 处理，RetryDecorator 不再持有 emitted 守卫或
    // 重试循环，这里纯转发 inner 流。非流式 chat/embed 的重试仍由本类承担。
    return _inner.chatStream(
      messages: messages,
      tools: tools,
      options: options,
    );
  }

  @override
  Future<List<double>> embed(String text, {String? model}) {
    return _runWithRetry(
      operation: 'embed',
      run: () => _inner.embed(text, model: model),
    );
  }

  @override
  void cancel() {
    _inner.cancel();
  }

  Future<T> _runWithRetry<T>({
    required String operation,
    required Future<T> Function() run,
  }) async {
    var attempt = 1;
    while (true) {
      try {
        // 超时只放弃本次 future，不调用 _inner.cancel()：同一 client 上可能还有
        // 其他并发请求，cancel 会误伤它们。
        return await run().timeout(requestTimeout);
      } catch (error) {
        if (!_shouldRetry(error, attempt)) {
          rethrow;
        }
        await _delayBeforeRetry(operation, error, attempt);
        attempt += 1;
      }
    }
  }

  bool _shouldRetry(Object error, int attempt) {
    return attempt <= maxRetries && _isTransientNetworkError(error);
  }

  Future<void> _delayBeforeRetry(
    String operation,
    Object error,
    int attempt,
  ) async {
    final delay = _retryDelay(attempt);
    _log.info(
      'operation=$operation retry=$attempt/$maxRetries '
      'delay=${delay.inMilliseconds}ms error=$error',
    );
    await Future.delayed(delay);
  }

  Duration _retryDelay(int attempt) {
    return streamRetryDelay(attempt, baseDelay: baseDelay, maxDelay: maxDelay);
  }

  bool _isTransientNetworkError(Object error) {
    if (isTransientNetworkError(error)) {
      return true;
    }
    return retryRateLimits && tryReadStatusCode(error) == 429;
  }
}
