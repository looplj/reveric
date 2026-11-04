// 职责: 适配本机 Codex 登录态，复用 Responses 流解析并聚合非流式调用。
// 关联文件:
//   lib/shared/agent/client/openai_responses_client.dart
//   lib/shared/services/ai/codex/credentials.dart
//   lib/shared/services/ai/codex/request.dart
//   lib/shared/services/ai/provider_initializer.dart
//   lib/shared/agent/client.dart

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:open_responses/open_responses.dart' as or;
import 'package:uuid/uuid.dart';

import '../../services/ai/codex/credentials.dart';
import '../../services/ai/codex/request.dart';
import '../agent_config.dart';
import '../agent_tool_dispatcher.dart';
import '../client.dart';
import '../message.dart';
import 'openai_responses_client.dart';

export '../../services/ai/codex/request.dart' show codexBaseUrl;

class CodexHttpException implements Exception {
  const CodexHttpException(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'Codex HTTP $statusCode';
}

class CodexClient implements ProviderClient {
  CodexClient({
    required this.model,
    Future<CodexCredentials> Function()? credentials,
    this._sessionIdProvider,
    http.Client? httpClient,
    this._streamHttpClientFactory,
  }) : _credentials =
           credentials ?? (() => CodexCredentials.load(client: httpClient)),
       _httpClient = httpClient;

  final String model;
  final Future<CodexCredentials> Function() _credentials;
  final String? Function()? _sessionIdProvider;
  final http.Client? _httpClient;
  final http.Client Function()? _streamHttpClientFactory;
  final String _standaloneSessionId = const Uuid().v4();
  OpenAIResponsesClient? _active;
  bool _running = false;
  bool _cancelled = false;

  String _sessionId(AgentConfig? options) {
    // 会话工厂按请求提供当前身份，子会话 client 的身份优先于继承的配置。
    final id = _sessionIdProvider?.call() ?? options?.sessionId;
    return id == null || id.isEmpty ? _standaloneSessionId : id;
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    if (_running) {
      throw StateError('Each active Codex request must use its own client');
    }
    final sessionId = _sessionId(options);
    _running = true;
    _cancelled = false;
    final httpClient = _httpClient ?? http.Client();
    try {
      final credentials = await _credentials();
      if (_cancelled) {
        yield StreamCancelled();
        return;
      }
      final delegate = OpenAIResponsesClient(
        apiKey: credentials.accessToken,
        baseUrl: codexBaseUrl,
        model: model,
        httpClient: httpClient,
        streamHttpClientFactory: _streamHttpClientFactory,
        defaultHeaders: {
          ...codexHeaders(credentials),
          'Accept': 'text/event-stream',
          'session_id': sessionId,
          'conversation_id': sessionId,
        },
        prepareStreamRequest: (request) => request.copyWith(
          instructions: request.instructions ?? '',
          temperature: null,
          maxOutputTokens: null,
          metadata: null,
          store: false,
          stream: true,
          promptCacheKey: sessionId,
        ),
        requireTerminalEvent: true,
      );
      _active = delegate;
      yield* delegate.chatStream(
        messages: messages,
        tools: tools,
        options: options,
      );
    } finally {
      _active?.cancel();
      _active = null;
      _running = false;
      if (_httpClient == null) {
        httpClient.close();
      }
    }
  }

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async {
    final sessionId = _sessionId(options);
    final text = StringBuffer();
    final thinking = StringBuffer();
    final encryptedContents = <String>[];
    final calls = <String, ToolCall>{};
    final partialCalls = <String>{};
    AiUsage? usage;
    StreamFinishReason? finishReason;
    var completed = false;
    await for (final event in chatStream(
      messages: messages,
      tools: tools,
      options: options,
    )) {
      switch (event) {
        case TextDelta():
          text.write(event.text);
        case ThinkingDelta():
          thinking.write(event.text);
        case EncryptedContentDelta():
          encryptedContents.add(event.encryptedContent);
        case ToolCallDelta():
          if (event.isPartial) {
            partialCalls.add(event.callId);
          } else {
            partialCalls.remove(event.callId);
            calls[event.callId] = ToolCall(
              callId: event.callId,
              toolName: event.toolName,
              arguments: event.arguments,
            );
          }
        case StreamCancelled():
          throw or.AbortedException(
            message: 'Codex request cancelled',
            correlationId: sessionId,
            timestamp: DateTime.now(),
            stage: or.AbortionStage.duringResponse,
          );
        case StreamError():
          throw StateError('Codex generation failed');
        case StreamComplete():
          usage = event.usage;
          if (event.finishReason != StreamFinishReason.stop &&
              event.finishReason != StreamFinishReason.toolCalls) {
            throw IncompleteModelResponseException(
              reason: event.finishReason == StreamFinishReason.length
                  ? IncompleteResponseReason.outputLimit
                  : event.finishReason == StreamFinishReason.contentFilter
                  ? IncompleteResponseReason.contentFiltered
                  : IncompleteResponseReason.missingFinalAnswer,
              finishReason: event.finishReason,
              textChars: text.length,
              thinkingChars: thinking.length,
            );
          }
          finishReason = event.finishReason;
          completed = true;
        case SignatureDelta():
          break;
      }
    }
    if (!completed ||
        partialCalls.isNotEmpty ||
        (text.isEmpty && calls.isEmpty)) {
      throw IncompleteModelResponseException(
        reason: partialCalls.isNotEmpty
            ? IncompleteResponseReason.incompleteToolCall
            : IncompleteResponseReason.missingFinalAnswer,
        textChars: text.length,
        thinkingChars: thinking.length,
        hadIncompleteToolCall: partialCalls.isNotEmpty,
      );
    }
    return ChatResponse(
      text: text.toString(),
      thinking: thinking.toString(),
      encryptedContents: encryptedContents,
      toolCalls: calls.values.toList(),
      usage: usage,
      finishReason: finishReason,
    );
  }

  /// 模型目录和生成共用登录态，不能按通用 OpenAI 的 data[].id 解析。
  static Future<List<String>> fetchModels({
    required http.Client client,
    Future<CodexCredentials> Function()? credentials,
  }) async {
    final auth =
        await (credentials ?? () => CodexCredentials.load(client: client))();
    final response = await client.get(
      Uri.parse('$codexBaseUrl/models?client_version=$codexClientVersion'),
      headers: {...codexHeaders(auth), 'Accept': 'application/json'},
    );
    if (response.statusCode != 200) {
      throw CodexHttpException(response.statusCode);
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final models = (json['models'] as List).cast<Map<String, dynamic>>()
      ..sort(
        (a, b) => ((a['priority'] as num?) ?? 0).compareTo(
          (b['priority'] as num?) ?? 0,
        ),
      );
    final result = [
      for (final item in models)
        if (item['visibility'] == 'list' &&
            (item['slug'] as String).trim().isNotEmpty)
          item['slug'] as String,
    ];
    if (result.isEmpty) {
      throw StateError('Codex catalog has no visible models');
    }
    return result;
  }

  @override
  void cancel() {
    _cancelled = true;
    _active?.cancel();
  }
}
