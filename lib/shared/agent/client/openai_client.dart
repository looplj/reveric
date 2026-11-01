// 职责: OpenAI-compatible provider client — 支持 reasoning + image + tool_result + trace headers
// 关联文件:
//   lib/shared/agent/client.dart
//   lib/shared/agent/message.dart
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/agent/client/_sanitize.dart
//   lib/shared/agent/client/_partial_json.dart
//   lib/shared/agent/client/trace_headers_http_client.dart
//   lib/shared/agent/client/provider_history_preflight.dart

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:openai_dart/openai_dart.dart' as openai;

import '../../logger/app_logger.dart';
import '../client.dart';
import '../message.dart'
    show
        AgentMessage,
        AgentMessageRole,
        ImageBlock,
        TextBlock,
        ThinkingBlock,
        ToolCall,
        ToolCallBlock,
        ToolResultBlock;
import '../../agent/agent_tool_dispatcher.dart' show ToolDef;
import '../agent_config.dart' show AgentConfig;
import '_partial_json.dart' show parseStreamingJson, tryDecodeJsonObject;
import '_sanitize.dart' show sanitizeSurrogates;
import 'json_schema.dart' show toolDefToJsonSchema;
import 'openrouter_reasoning.dart';
import 'provider_history_preflight.dart'
    show ProviderHistoryPolicy, preflightProviderHistory;
import 'trace_headers_http_client.dart'
    show TraceHeadersHttpClient, TraceHeadersProvider;

final _log = AppLogger.forModule('OpenAiClient');

({int objectDepth, int arrayDepth, bool inString}) _jsonShape(String raw) {
  var objectDepth = 0;
  var arrayDepth = 0;
  var inString = false;
  var escaped = false;

  for (final codeUnit in raw.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (codeUnit == 0x5c) {
        escaped = true;
      } else if (codeUnit == 0x22) {
        inString = false;
      }
      continue;
    }
    switch (codeUnit) {
      case 0x22:
        inString = true;
      case 0x7b:
        objectDepth += 1;
      case 0x7d:
        objectDepth -= 1;
      case 0x5b:
        arrayDepth += 1;
      case 0x5d:
        arrayDepth -= 1;
    }
  }

  return (objectDepth: objectDepth, arrayDepth: arrayDepth, inString: inString);
}

String _lastNonWhitespace(String raw) {
  for (var index = raw.length - 1; index >= 0; index -= 1) {
    final char = raw[index];
    if (char.trim().isNotEmpty) {
      return char;
    }
  }
  return '<empty>';
}

class OpenAiClient implements ProviderClient {
  OpenAiClient({
    required String apiKey,
    required String baseUrl,
    this.model,
    http.Client? httpClient,
    http.Client Function()? streamClientFactory,
    TraceHeadersProvider? traceHeadersProvider,
    this.useThinkingField = false,
    this.useEnableThinkingField = false,
    this.useOpenRouter = false,
    Map<String, String>? defaultHeaders,
  }) : _client = openai.OpenAIClient.withApiKey(
         apiKey,
         baseUrl: baseUrl,
         defaultHeaders: defaultHeaders,
         httpClient: traceHeadersProvider != null
             ? TraceHeadersHttpClient(
                 inner: httpClient ?? http.Client(),
                 headersProvider: traceHeadersProvider,
               )
             : httpClient,
         streamClientFactory: traceHeadersProvider != null
             ? () => TraceHeadersHttpClient(
                 inner: streamClientFactory?.call() ?? http.Client(),
                 headersProvider: traceHeadersProvider,
               )
             : streamClientFactory,
       );

  final openai.OpenAIClient _client;
  final String? model;
  final bool useThinkingField;
  final bool useEnableThinkingField;
  final bool useOpenRouter;
  Completer<void>? _abortCompleter;
  int _streamSequence = 0;

  @override
  void cancel() {
    _abortCompleter?.complete();
    _abortCompleter = null;
  }

  /// 构建 chat completion 请求。
  ///
  /// [useThinkingField] 为 true 时用私有 `thinking` 字段控制推理开关：
  /// - none → `thinking:{type:"disabled"}`，并省略 `reasoning_effort`
  /// - on → `thinking:{type:"enabled"}`，并省略 `reasoning_effort`（仅开关模型）
  /// - low/medium/high → `thinking:{type:"enabled"}` + `reasoning_effort`
  /// 其余 provider 走标准 `reasoning_effort`。
  ///
  /// openai_dart 的 [openai.ReasoningEffort] 未收录的级别（如 `max`）经
  /// [_ExtraFieldsChatRequest] 以原始字符串注入，避免被序列化成 "unknown"。
  openai.ChatCompletionCreateRequest _buildCompletionRequest(
    AgentConfig opts,
    List<AgentMessage> messages,
    List<ToolDef>? tools, {
    bool stream = false,
  }) {
    final effort = opts.reasoningEffort;
    // none/on 是思考开关值，不作为 reasoning_effort 级别发送。
    final isToggle = effort == 'none' || effort == 'on';
    final levelEffort = isToggle ? null : effort;
    final parsedEffort = levelEffort != null
        ? openai.ReasoningEffort.fromJson(levelEffort)
        : null;
    final isUnknownLevel = parsedEffort == openai.ReasoningEffort.unknown;
    final streamOptions = stream
        ? openai.StreamOptions(includeUsage: true)
        : null;

    final needsThinking = useThinkingField && effort != null;
    final needsEnableThinking = useEnableThinkingField && effort != null;
    if (useOpenRouter) {
      return _ExtraFieldsChatRequest(
        model: model ?? '',
        messages: convertMessages(messages),
        tools: tools?.map(_toOpenAiTool).toList(),
        parallelToolCalls: true,
        temperature: opts.temperature,
        maxTokens: opts.maxTokens,
        streamOptions: streamOptions,
        openRouterReasoning: switch (effort) {
          null => null,
          'none' => const {'enabled': false},
          'on' => const {'enabled': true},
          _ => {'effort': effort},
        },
      );
    }
    if (!needsThinking && !needsEnableThinking && !isUnknownLevel) {
      return openai.ChatCompletionCreateRequest(
        model: model ?? '',
        messages: convertMessages(messages),
        tools: tools?.map(_toOpenAiTool).toList(),
        parallelToolCalls: true,
        temperature: opts.temperature,
        maxTokens: opts.maxTokens,
        reasoningEffort: parsedEffort,
        streamOptions: streamOptions,
      );
    }

    return _ExtraFieldsChatRequest(
      model: model ?? '',
      messages: convertMessages(messages),
      tools: tools?.map(_toOpenAiTool).toList(),
      parallelToolCalls: true,
      temperature: opts.temperature,
      maxTokens: opts.maxTokens,
      streamOptions: streamOptions,
      reasoningEffortWire: levelEffort,
      thinkingType: needsThinking
          ? (effort == 'none' ? 'disabled' : 'enabled')
          : null,
      enableThinking: needsEnableThinking ? effort != 'none' : null,
    );
  }

  openai.ContentPart _imageToPart(ImageBlock block) {
    return openai.ContentPart.imageBase64(
      data: block.data,
      mediaType: block.mimeType,
    );
  }

  List<openai.ChatMessage> _convertOne(AgentMessage msg) {
    switch (msg.role) {
      case AgentMessageRole.system:
        return [openai.ChatMessage.system(sanitizeSurrogates(msg.content))];

      case AgentMessageRole.user:
        // Tool result message: emit ChatMessage.tool + optional follow-up user image turn
        final toolResults = msg.blocks.whereType<ToolResultBlock>().toList();
        if (toolResults.isNotEmpty) {
          final out = <openai.ChatMessage>[];
          final imageBlocks = <ImageBlock>[];
          for (final tr in toolResults) {
            final textBuf = StringBuffer();
            for (final c in tr.content) {
              switch (c) {
                case TextBlock(:final text):
                  if (textBuf.isNotEmpty) textBuf.write('\n');
                  textBuf.write(text);
                case ImageBlock():
                  imageBlocks.add(c);
                default:
                  break;
              }
            }
            final content = textBuf.isNotEmpty
                ? sanitizeSurrogates(textBuf.toString())
                : '(see attached image)';
            out.add(
              openai.ChatMessage.tool(
                toolCallId: tr.toolCallId,
                content: content,
              ),
            );
          }
          if (imageBlocks.isNotEmpty) {
            out.add(
              openai.ChatMessage.user([
                openai.ContentPart.text('Tool result image(s):'),
                ...imageBlocks.map(_imageToPart),
              ]),
            );
          }
          return out;
        }

        // Regular user message: text + image parts
        final imgs = msg.blocks.whereType<ImageBlock>().toList();
        final texts = msg.blocks.whereType<TextBlock>().toList();
        if (imgs.isEmpty && texts.isEmpty) {
          if (msg.content.isEmpty) return const [];
          return [openai.ChatMessage.user(sanitizeSurrogates(msg.content))];
        }
        final parts = <openai.ContentPart>[];
        if (msg.content.isNotEmpty) {
          parts.add(openai.ContentPart.text(sanitizeSurrogates(msg.content)));
        }
        for (final block in msg.blocks) {
          switch (block) {
            case TextBlock(:final text):
              if (text.isNotEmpty) {
                parts.add(openai.ContentPart.text(sanitizeSurrogates(text)));
              }
            case ImageBlock():
              parts.add(_imageToPart(block));
            default:
              break;
          }
        }
        if (parts.isEmpty) return const [];
        return [openai.ChatMessage.user(parts)];

      case AgentMessageRole.assistant:
        final toolCalls = <openai.ToolCall>[];
        final contentBuf = StringBuffer(msg.content);
        String? thinking;
        List<openai.ReasoningDetail>? reasoningDetails;
        for (final block in msg.blocks) {
          switch (block) {
            case TextBlock(:final text):
              contentBuf.write(text);
            case ThinkingBlock(
              :final text,
              :final signature,
              :final encryptedContents,
            ):
              thinking = text;
              if (useOpenRouter) {
                final details = decodeOpenRouterReasoning(signature);
                if (details != null) {
                  (reasoningDetails ??= []).addAll(details);
                }
                break;
              }
              if (signature != null) {
                reasoningDetails ??= [];
                reasoningDetails.add(
                  openai.ReasoningDetail(
                    type: 'reasoning.encrypted',
                    data: signature,
                  ),
                );
              }
              for (final encryptedContent in encryptedContents) {
                reasoningDetails ??= [];
                reasoningDetails.add(
                  openai.ReasoningDetail(
                    type: 'reasoning.encrypted',
                    data: encryptedContent,
                  ),
                );
              }
            case ToolCallBlock(
              :final callId,
              :final toolName,
              :final arguments,
            ):
              toolCalls.add(
                openai.ToolCall.functionCall(
                  id: callId,
                  call: openai.FunctionCall(
                    name: toolName,
                    arguments: jsonEncode(arguments),
                  ),
                ),
              );
            default:
              break;
          }
        }
        final contentStr = contentBuf.toString();
        if (contentStr.isEmpty && toolCalls.isEmpty) {
          return const [];
        }
        return [
          openai.AssistantMessage(
            content: contentStr.isNotEmpty
                ? sanitizeSurrogates(contentStr)
                : null,
            toolCalls: toolCalls.isNotEmpty ? toolCalls : null,
            reasoningContent: useOpenRouter ? null : thinking,
            reasoning: useOpenRouter && reasoningDetails == null
                ? thinking
                : null,
            reasoningDetails: reasoningDetails,
          ),
        ];
    }
  }

  @visibleForTesting
  List<openai.ChatMessage> convertMessages(List<AgentMessage> messages) {
    preflightProviderHistory(messages, ProviderHistoryPolicy.openAiChat);
    final out = <openai.ChatMessage>[];
    final deferredImages = <openai.ChatMessage>[];
    var pendingResults = 0;
    for (final msg in messages) {
      pendingResults += msg.blocks.whereType<ToolCallBlock>().length;
      final resultCount = msg.blocks.whereType<ToolResultBlock>().length;
      for (final converted in _convertOne(msg)) {
        if (resultCount > 0 && converted.role == 'user') {
          // Text-only tool endpoints receive images after every result in the
          // assistant's batch, so image turns cannot interrupt call/result pairs.
          deferredImages.add(converted);
        } else {
          out.add(converted);
        }
      }
      pendingResults -= resultCount;
      if (pendingResults == 0) {
        out.addAll(deferredImages);
        deferredImages.clear();
      }
    }
    return out;
  }

  openai.Tool _toOpenAiTool(ToolDef tool) {
    return openai.Tool.function(
      name: tool.name,
      description: tool.description,
      parameters: toolDefToJsonSchema(tool),
    );
  }

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async {
    final opts = options ?? const AgentConfig();
    _abortCompleter = Completer<void>();
    try {
      final response = await _client.chat.completions.create(
        _buildCompletionRequest(opts, messages, tools),
        abortTrigger: _abortCompleter?.future,
      );
      final choice = response.choices.firstOrNull;
      if (choice == null) {
        return const ChatResponse();
      }
      final msg = choice.message;
      final toolCalls =
          msg.toolCalls?.map((tc) {
            final args = tc.function.argumentsMap;
            return ToolCall(
              callId: tc.id,
              toolName: tc.function.name,
              arguments: args,
            );
          }).toList() ??
          [];

      String? signature;
      for (final detail in msg.reasoningDetails ?? []) {
        if (detail.isEncrypted && detail.data != null) {
          signature = detail.data;
        }
      }

      // 解析 usage
      AiUsage? usage;
      if (response.usage != null) {
        final u = response.usage!;
        usage = AiUsage(
          inputTokens: u.promptTokens,
          outputTokens: u.completionTokens ?? 0,
          cacheReadTokens: u.promptTokensDetails?.cachedTokens ?? 0,
          reasoningTokens: u.completionTokensDetails?.reasoningTokens ?? 0,
        );
      }

      return ChatResponse(
        text: msg.content ?? '',
        thinking:
            msg.reasoningContent ??
            msg.reasoning ??
            (useOpenRouter
                ? openRouterReasoningText(msg.reasoningDetails)
                : ''),
        signature: useOpenRouter
            ? encodeOpenRouterReasoning(msg.reasoningDetails)
            : signature,
        toolCalls: toolCalls,
        usage: usage,
        finishReason: choice.finishReason == null
            ? null
            : _mapFinishReason(choice.finishReason!.toJson()),
      );
    } finally {
      _abortCompleter = null;
    }
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    final opts = options ?? const AgentConfig();
    final abortCompleter = Completer<void>();
    _abortCompleter = abortCompleter;
    final streamId = ++_streamSequence;
    AiUsage? finalUsage;
    final openRouterReasoning = OpenRouterReasoningAccumulator();
    StreamFinishReason? finalFinishReason;
    var eventCount = 0;
    var eventWithChoicesCount = 0;
    var textDeltaEvents = 0;
    var textChars = 0;
    var thinkingDeltaEvents = 0;
    var thinkingChars = 0;
    var toolDeltaEvents = 0;
    var toolArgumentChars = 0;
    var finishReasonEvents = 0;
    var usageEvents = 0;
    var lastEventType = 'none';
    var openToolCallsAtEof = 0;
    final request = _buildCompletionRequest(
      opts,
      messages,
      tools,
      stream: true,
    );
    final partialToolCalls = <int, _OpenAiPartialToolCall>{};
    try {
      _log.info(
        'chat completions stream start id=$streamId model=${model ?? 'none'} '
        'messages=${messages.length} tools=${tools?.length ?? 0} '
        'temperature=${opts.temperature} maxTokens=${opts.maxTokens} '
        'reasoningEffort=${opts.reasoningEffort ?? 'none'} '
        'useThinkingField=$useThinkingField',
      );
      final stream = _client.chat.completions.createStream(
        request,
        abortTrigger: abortCompleter.future,
      );

      List<ToolCallDelta> terminalToolCallDeltas({
        required bool keepIncomplete,
        required String terminal,
      }) {
        final events = <ToolCallDelta>[];
        final completedIndexes = <int>[];
        for (final entry in partialToolCalls.entries) {
          final tc = entry.value;
          if (tc.id == null || tc.name == null) {
            continue;
          }
          final rawArguments = tc.args.toString();
          final completeArguments = tryDecodeJsonObject(rawArguments);
          final shouldWarn =
              completeArguments == null && !abortCompleter.isCompleted;
          if (shouldWarn || _log.isDebugEnabled) {
            final shape = _jsonShape(rawArguments);
            final diagnostic =
                'tool args terminal=$terminal index=${entry.key} '
                'tool=${tc.name} callId=${tc.id} chars=${rawArguments.length} '
                'jsonComplete=${completeArguments != null} '
                'objectDepth=${shape.objectDepth} arrayDepth=${shape.arrayDepth} '
                'inString=${shape.inString} '
                'parsedKeys=${parseStreamingJson(rawArguments).keys.join(',')} '
                'lastChar=${_lastNonWhitespace(rawArguments)} '
                'cancelled=${abortCompleter.isCompleted}';
            if (shouldWarn) {
              _log.warning(diagnostic);
            } else {
              _log.debug(diagnostic);
            }
          }
          events.add(
            ToolCallDelta(
              callId: tc.id!,
              toolName: tc.name!,
              arguments: completeArguments ?? parseStreamingJson(rawArguments),
              isPartial: completeArguments == null,
            ),
          );
          if (completeArguments != null || !keepIncomplete) {
            completedIndexes.add(entry.key);
          }
        }
        for (final index in completedIndexes) {
          partialToolCalls.remove(index);
        }
        return events;
      }

      await for (final event in stream) {
        eventCount += 1;
        lastEventType = event.runtimeType.toString();
        // 解析 usage (通常在最后一个 chunk)
        if (event.usage != null) {
          usageEvents += 1;
          final u = event.usage!;
          finalUsage = AiUsage(
            inputTokens: u.promptTokens,
            outputTokens: u.completionTokens ?? 0,
            cacheReadTokens: u.promptTokensDetails?.cachedTokens ?? 0,
            reasoningTokens: u.completionTokensDetails?.reasoningTokens ?? 0,
          );
        }

        final choices = event.choices;
        if (choices == null || choices.isEmpty) continue;
        eventWithChoicesCount += 1;

        for (final choice in choices) {
          final delta = choice.delta;

          // 同一 chunk 可能同时带思考尾巴与正文开头；先发思考，避免正文
          // 首字后插入 thinking block，把一句话拆成两个文本气泡。
          if (delta.reasoningContent case final rc? when rc.isNotEmpty) {
            thinkingDeltaEvents += 1;
            thinkingChars += rc.length;
            yield ThinkingDelta(rc);
          } else if (delta.reasoning case final r? when r.isNotEmpty) {
            thinkingDeltaEvents += 1;
            thinkingChars += r.length;
            yield ThinkingDelta(r);
          } else if (useOpenRouter) {
            final text = openRouterReasoningText(delta.reasoningDetails);
            if (text.isNotEmpty) {
              thinkingDeltaEvents += 1;
              thinkingChars += text.length;
              yield ThinkingDelta(text);
            }
          }

          if (delta.content case final text? when text.isNotEmpty) {
            textDeltaEvents += 1;
            textChars += text.length;
            yield TextDelta(text);
          }

          if (useOpenRouter) {
            openRouterReasoning.add(delta.reasoningDetails);
          } else {
            for (final detail in delta.reasoningDetails ?? []) {
              if (detail.isEncrypted && detail.data != null) {
                yield EncryptedContentDelta(detail.data!);
              }
            }
          }

          if (delta.toolCalls case final toolCallDeltas?) {
            for (final tcd in toolCallDeltas) {
              toolDeltaEvents += 1;
              final toolCall = partialToolCalls.putIfAbsent(
                tcd.index,
                () => _OpenAiPartialToolCall(),
              );
              // Some providers send empty identity fields in continuation chunks.
              // Keep the identity received with the initial tool-call chunk.
              if (tcd.id case final id? when id.isNotEmpty) {
                toolCall.id = id;
              }
              if (tcd.function case final fn?) {
                if (fn.name case final name? when name.isNotEmpty) {
                  toolCall.name = name;
                }
                if (fn.arguments case final args?) {
                  toolArgumentChars += args.length;
                  toolCall.args.write(args);
                }
              }
              yield ToolCallDelta(
                callId: toolCall.id ?? '',
                toolName: toolCall.name ?? '',
                arguments: parseStreamingJson(toolCall.args.toString()),
                isPartial: true,
              );
            }
          }

          if (choice.finishReason != null) {
            finishReasonEvents += 1;
            finalFinishReason = _mapFinishReason(choice.finishReason!.toJson());
            if (partialToolCalls.isNotEmpty) {
              if (_log.isDebugEnabled) {
                _log.debug(
                  'tool stream finish reason=${finalFinishReason.name} '
                  'openToolCalls=${partialToolCalls.length}',
                );
              }
            }
            for (final delta in terminalToolCallDeltas(
              keepIncomplete: false,
              terminal: finalFinishReason.name,
            )) {
              yield delta;
            }
            partialToolCalls.clear();
          }
        }
      }
      if (partialToolCalls.isNotEmpty) {
        openToolCallsAtEof = partialToolCalls.length;
        if (!abortCompleter.isCompleted || _log.isDebugEnabled) {
          final diagnostic =
              'tool stream EOF before finish reason '
              'openToolCalls=${partialToolCalls.length} '
              'cancelled=${abortCompleter.isCompleted}';
          if (abortCompleter.isCompleted) {
            _log.debug(diagnostic);
          } else {
            _log.warning(diagnostic);
          }
        }
        // Some OpenAI-compatible relays close the SSE stream after the full
        // JSON arguments but omit the terminal finish_reason chunk. Recover
        // only complete JSON; genuinely truncated arguments stay partial and
        // are rejected by assembleRound before tool dispatch.
        for (final delta in terminalToolCallDeltas(
          keepIncomplete: true,
          terminal: 'eof',
        )) {
          yield delta;
        }
      }
      final diagnostic =
          'chat completions stream end id=$streamId model=${model ?? 'none'} '
          'events=$eventCount eventsWithChoices=$eventWithChoicesCount '
          'lastEvent=$lastEventType '
          'textDeltaEvents=$textDeltaEvents textChars=$textChars '
          'thinkingDeltaEvents=$thinkingDeltaEvents thinkingChars=$thinkingChars '
          'toolDeltaEvents=$toolDeltaEvents toolArgumentChars=$toolArgumentChars '
          'finishReasonEvents=$finishReasonEvents '
          'openToolCallsAtEof=$openToolCallsAtEof '
          'finishReason=${finalFinishReason?.name ?? 'none'} '
          'usageEvents=$usageEvents usage=${finalUsage?.totalTokens ?? 'none'} '
          'cancelled=${abortCompleter.isCompleted}';
      if (finishReasonEvents == 0 && !abortCompleter.isCompleted) {
        _log.warning('$diagnostic missingFinishReason=true');
      } else {
        _log.info('$diagnostic missingFinishReason=${finishReasonEvents == 0}');
      }
      // 流式完成，发送 completion 事件
      if (useOpenRouter) {
        if (openRouterReasoning.signature case final signature?) {
          yield SignatureDelta(signature);
        }
      }
      yield StreamComplete(usage: finalUsage, finishReason: finalFinishReason);
    } catch (error, stackTrace) {
      _log.error(
        'chat completions stream error id=$streamId model=${model ?? 'none'} '
        'events=$eventCount lastEvent=$lastEventType '
        'textChars=$textChars thinkingChars=$thinkingChars '
        'toolDeltaEvents=$toolDeltaEvents toolArgumentChars=$toolArgumentChars '
        'finishReasonEvents=$finishReasonEvents '
        'finishReason=${finalFinishReason?.name ?? 'none'} '
        'usage=${finalUsage?.totalTokens ?? 'none'}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      _abortCompleter = null;
    }
  }

  StreamFinishReason _mapFinishReason(String reason) => switch (reason) {
    'stop' => StreamFinishReason.stop,
    'length' => StreamFinishReason.length,
    'tool_calls' || 'function_call' => StreamFinishReason.toolCalls,
    'content_filter' => StreamFinishReason.contentFilter,
    _ => StreamFinishReason.unknown,
  };

  @override
  Future<List<double>> embed(String text, {String? model}) async {
    final response = await _client.embeddings.create(
      openai.EmbeddingRequest(
        model: model ?? 'text-embedding-3-small',
        input: openai.EmbeddingInput.text(text),
      ),
    );
    return response.data.first.embedding;
  }
}

/// 需要注入额外/原始字段的 chat completion 请求。
///
/// openai_dart 的 [openai.ChatCompletionCreateRequest] 没有 extra body 机制，
/// 这里通过子类覆写 `toJson()` 注入：
/// - [thinkingType] 非空时注入 `thinking:{type:"enabled"|"disabled"}`；
/// - `reasoning_effort` 一律以 [reasoningEffortWire] 原始字符串写入
///  （enum 未收录的级别如 `max` 不会被序列化成 "unknown"），null 时省略。
/// `create`/`createStream` 均经 `request.toJson()` 序列化，故覆写对两条路径都生效。
class _ExtraFieldsChatRequest extends openai.ChatCompletionCreateRequest {
  const _ExtraFieldsChatRequest({
    required super.model,
    required super.messages,
    super.tools,
    super.parallelToolCalls,
    super.temperature,
    super.maxTokens,
    super.streamOptions,
    this.reasoningEffortWire,
    this.thinkingType,
    this.enableThinking,
    this.openRouterReasoning,
  });

  /// reasoning_effort 的原始 wire 值；null 表示不发送该字段。
  final String? reasoningEffortWire;

  /// 'enabled' | 'disabled'；null 表示不发送 thinking 字段。
  final String? thinkingType;
  final bool? enableThinking;
  final Map<String, dynamic>? openRouterReasoning;

  @override
  Map<String, dynamic> toJson() {
    final json = super.toJson();
    json.remove('reasoning_effort');
    if (reasoningEffortWire != null) {
      json['reasoning_effort'] = reasoningEffortWire;
    }
    if (thinkingType != null) {
      json['thinking'] = {'type': thinkingType};
    }
    if (enableThinking != null) {
      json['enable_thinking'] = enableThinking;
    }
    if (openRouterReasoning != null) {
      json['reasoning'] = openRouterReasoning;
    }
    return json;
  }
}

class _OpenAiPartialToolCall {
  String? id;
  String? name;
  final StringBuffer args = StringBuffer();
}
