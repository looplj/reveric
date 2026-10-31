// 职责: OpenAI Responses API provider client — reasoning encrypted_content + image + tool_result + trace headers
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
import 'package:open_responses/open_responses.dart' as or;

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
import 'provider_history_preflight.dart'
    show ProviderHistoryPolicy, preflightProviderHistory;
import 'trace_headers_http_client.dart'
    show TraceHeadersHttpClient, TraceHeadersProvider;

final _log = AppLogger.forModule('OpenAIResponsesClient');

class OpenAIResponsesClient implements ProviderClient {
  OpenAIResponsesClient({
    required String apiKey,
    required String baseUrl,
    this.model,
    http.Client? httpClient,
    http.Client Function()? streamHttpClientFactory,
    TraceHeadersProvider? traceHeadersProvider,
    Map<String, String>? defaultHeaders,
    this.prepareStreamRequest,
    this.requireTerminalEvent = false,
  }) : _client = or.OpenResponsesClient.withApiKey(
         apiKey,
         baseUrl: baseUrl,
         defaultHeaders: defaultHeaders,
         httpClient: traceHeadersProvider != null
             ? TraceHeadersHttpClient(
                 inner: httpClient ?? http.Client(),
                 headersProvider: traceHeadersProvider,
               )
             : httpClient,
         // 流式取消要能单独关闭本次请求的 client，故每次流用一份专用 client。
         // 但它必须复刻共享 client 的代理配置（[streamHttpClientFactory] 由调用方
         // 用 config.createProxyClient 提供），否则配了代理的用户流式请求会直连。
         streamClientFactory: () {
           final base = streamHttpClientFactory?.call() ?? http.Client();
           return traceHeadersProvider != null
               ? TraceHeadersHttpClient(
                   inner: base,
                   headersProvider: traceHeadersProvider,
                 )
               : base;
         },
       );

  final or.OpenResponsesClient _client;
  final String? model;
  final or.CreateResponseRequest Function(or.CreateResponseRequest)?
  prepareStreamRequest;

  /// 严格上游必须发送终态；不能将提前关闭的连接视为成功。
  final bool requireTerminalEvent;
  bool _cancelled = false;
  Completer<void>? _abortCompleter;
  int _streamSequence = 0;

  ProviderStreamException _streamException(
    int streamId,
    String eventType,
    or.ErrorPayload? error,
  ) {
    _log.warning(
      'responses stream error id=$streamId type=$eventType '
      'errorType=${error?.type} code=${error?.code}',
    );
    return ProviderStreamException(
      type: error?.type,
      code: error?.code,
      message: error?.message ?? '',
    );
  }

  @override
  void cancel() {
    _cancelled = true;
    final abortCompleter = _abortCompleter;
    if (abortCompleter != null && !abortCompleter.isCompleted) {
      abortCompleter.complete();
    }
  }

  or.InputContent _imageToInput(ImageBlock block) {
    return or.InputImageContent.url(
      'data:${block.mimeType};base64,${block.data}',
    );
  }

  List<or.Item> _userItems(AgentMessage msg) {
    final out = <or.Item>[];

    final toolResults = msg.blocks.whereType<ToolResultBlock>().toList();
    if (toolResults.isNotEmpty) {
      for (final tr in toolResults) {
        final textBuf = StringBuffer();
        final imgs = <ImageBlock>[];
        for (final c in tr.content) {
          switch (c) {
            case TextBlock(:final text):
              if (textBuf.isNotEmpty) textBuf.write('\n');
              textBuf.write(text);
            case ImageBlock():
              imgs.add(c);
            default:
              break;
          }
        }
        if (imgs.isEmpty) {
          out.add(
            or.FunctionCallOutputItem.string(
              callId: tr.toolCallId,
              output: textBuf.isNotEmpty
                  ? sanitizeSurrogates(textBuf.toString())
                  : '',
            ),
          );
        } else {
          final parts = <or.InputContent>[];
          if (textBuf.isNotEmpty) {
            parts.add(
              or.InputContent.text(sanitizeSurrogates(textBuf.toString())),
            );
          }
          for (final img in imgs) {
            parts.add(_imageToInput(img));
          }
          out.add(
            or.FunctionCallOutputItem(
              callId: tr.toolCallId,
              output: or.FunctionCallOutputContent(parts),
            ),
          );
        }
      }
      return out;
    }

    final parts = <or.InputContent>[];
    if (msg.content.isNotEmpty) {
      parts.add(or.InputContent.text(sanitizeSurrogates(msg.content)));
    }
    for (final block in msg.blocks) {
      switch (block) {
        case TextBlock(:final text):
          if (text.isNotEmpty) {
            parts.add(or.InputContent.text(sanitizeSurrogates(text)));
          }
        case ImageBlock():
          parts.add(_imageToInput(block));
        default:
          break;
      }
    }
    if (parts.isEmpty) return out;
    out.add(or.MessageItem.user(parts));
    return out;
  }

  List<or.Item> _assistantItems(AgentMessage msg) {
    final out = <or.Item>[];
    if (msg.content.isNotEmpty) {
      out.add(
        or.MessageItem.assistant([
          or.OutputContent.text(sanitizeSurrogates(msg.content)),
        ]),
      );
    }
    for (final block in msg.blocks) {
      switch (block) {
        case TextBlock(:final text):
          if (text.isNotEmpty) {
            out.add(
              or.MessageItem.assistant([
                or.OutputContent.text(sanitizeSurrogates(text)),
              ]),
            );
          }
        case ThinkingBlock(:final encryptedContents):
          for (final encryptedContent in encryptedContents) {
            if (encryptedContent.isEmpty) {
              continue;
            }
            out.add(
              or.ReasoningInputItem(
                summary: const [],
                encryptedContent: encryptedContent,
              ),
            );
          }
        case ToolCallBlock(:final callId, :final toolName, :final arguments):
          out.add(
            or.FunctionCallItem(
              callId: callId,
              name: toolName,
              arguments: jsonEncode(arguments),
            ),
          );
        default:
          break;
      }
    }
    return out;
  }

  @visibleForTesting
  List<or.Item> buildInputItems(List<AgentMessage> messages) {
    preflightProviderHistory(messages, ProviderHistoryPolicy.openAiResponses);
    final items = <or.Item>[];
    for (final msg in messages.where(
      (m) => m.role != AgentMessageRole.system,
    )) {
      switch (msg.role) {
        case AgentMessageRole.user:
          items.addAll(_userItems(msg));
        case AgentMessageRole.assistant:
          items.addAll(_assistantItems(msg));
        case AgentMessageRole.system:
          break;
      }
    }
    return items;
  }

  or.Tool _toTool(ToolDef tool) {
    return or.Tool.function_(
      name: tool.name,
      description: tool.description,
      parameters: tool.inputSchema,
    );
  }

  static const _include = [or.Include.reasoningEncryptedContent];

  or.ReasoningConfig _reasoningConfig(String? effort) {
    // Responses API has no `thinking` toggle. `on` is a UI-only toggle value,
    // so omit it instead of letting the SDK serialize it as `unknown`.
    final responseEffort = effort == 'on' ? null : effort;
    return or.ReasoningConfig(
      effort: responseEffort != null
          ? or.ReasoningEffort.fromJson(responseEffort)
          : null,
      summary: or.ReasoningSummary.auto,
    );
  }

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async {
    _cancelled = false;
    final opts = options ?? const AgentConfig();
    try {
      final systemMsgs = messages.where(
        (m) => m.role == AgentMessageRole.system,
      );
      final instructions = systemMsgs.map((m) => m.content).join('\n');

      final response = await _client.responses.create(
        or.CreateResponseRequest(
          model: model ?? '',
          input: or.ResponseInput.items(buildInputItems(messages)),
          instructions: instructions.isNotEmpty
              ? sanitizeSurrogates(instructions)
              : null,
          tools: tools?.map(_toTool).toList(),
          parallelToolCalls: true,
          store: false,
          temperature: opts.temperature,
          maxOutputTokens: opts.maxTokens,
          reasoning: _reasoningConfig(opts.reasoningEffort),
          include: _include,
        ),
      );
      return _parseResponse(response);
    } finally {
      _cancelled = false;
    }
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    _cancelled = false;
    _abortCompleter = Completer<void>();
    final streamId = ++_streamSequence;
    final opts = options ?? const AgentConfig();
    AiUsage? finalUsage;
    StreamFinishReason? finalFinishReason;
    var eventCount = 0;
    var unknownEventCount = 0;
    var textDeltaEvents = 0;
    var textChars = 0;
    var thinkingDeltaEvents = 0;
    var thinkingChars = 0;
    var outputItemAddedEvents = 0;
    var functionArgumentsDeltaEvents = 0;
    var functionArgumentsDoneEvents = 0;
    var terminalEventCount = 0;
    var terminalOutputItems = 0;
    var terminalFunctionCalls = 0;
    var sawTerminalEvent = false;
    var lastEventType = 'none';
    var openToolCallsAtEof = 0;
    final inputItems = buildInputItems(messages);
    try {
      final systemMsgs = messages.where(
        (m) => m.role == AgentMessageRole.system,
      );
      final instructions = systemMsgs.map((m) => m.content).join('\n');

      _log.info(
        'responses stream start id=$streamId model=${model ?? 'none'} '
        'messages=${messages.length} inputItems=${inputItems.length} '
        'tools=${tools?.length ?? 0} temperature=${opts.temperature} '
        'maxOutputTokens=${opts.maxTokens} '
        'reasoningEffort=${opts.reasoningEffort ?? 'none'}',
      );

      final request = or.CreateResponseRequest(
        model: model ?? '',
        input: or.ResponseInput.items(inputItems),
        instructions: instructions.isNotEmpty
            ? sanitizeSurrogates(instructions)
            : null,
        tools: tools?.map(_toTool).toList(),
        parallelToolCalls: true,
        store: false,
        temperature: opts.temperature,
        maxOutputTokens: opts.maxTokens,
        reasoning: _reasoningConfig(opts.reasoningEffort),
        include: _include,
      );
      final stream = _client.responses.createStream(
        prepareStreamRequest?.call(request) ?? request,
        abortTrigger: _abortCompleter?.future,
      );

      final partialToolCalls = <String, _OpenResponsesPartialToolCall>{};

      List<ToolCallDelta> terminalToolCallDeltas({
        required bool keepIncomplete,
        required String terminal,
      }) {
        final events = <ToolCallDelta>[];
        final completedIds = <String>[];
        for (final entry in partialToolCalls.entries) {
          final itemId = entry.key;
          final call = entry.value;
          final rawArguments = call.arguments.toString();
          final completeArguments = tryDecodeJsonObject(rawArguments);
          final callId = call.callId ?? itemId;
          final toolName = call.name;
          if (toolName == null || toolName.isEmpty) {
            continue;
          }
          events.add(
            ToolCallDelta(
              callId: callId,
              toolName: toolName,
              arguments: completeArguments ?? parseStreamingJson(rawArguments),
              isPartial: completeArguments == null,
            ),
          );
          if (completeArguments != null || !keepIncomplete) {
            completedIds.add(itemId);
          }
        }
        for (final itemId in completedIds) {
          partialToolCalls.remove(itemId);
        }
        _log.info(
          'responses tool stream terminal=$terminal '
          'openToolCalls=${partialToolCalls.length}',
        );
        return events;
      }

      await for (final event in stream) {
        eventCount += 1;
        final eventType = event.runtimeType.toString();
        lastEventType = eventType;
        if (_cancelled) break;

        switch (event) {
          case or.OutputTextDeltaEvent(:final delta):
            textDeltaEvents += 1;
            textChars += delta.length;
            if (delta.isNotEmpty) yield TextDelta(delta);
          case or.ReasoningDeltaEvent(:final delta):
            thinkingDeltaEvents += 1;
            thinkingChars += delta.length;
            if (delta.isNotEmpty) yield ThinkingDelta(delta);
          case or.ReasoningSummaryDeltaEvent(:final delta):
            thinkingDeltaEvents += 1;
            thinkingChars += delta.length;
            if (delta.isNotEmpty) yield ThinkingDelta(delta);
          case or.OutputItemAddedEvent(:final item):
            outputItemAddedEvents += 1;
            if (item case or.FunctionCallOutputItemResponse(
              :final id,
              :final callId,
              :final name,
              :final arguments,
            )) {
              final call = partialToolCalls.putIfAbsent(
                id,
                _OpenResponsesPartialToolCall.new,
              );
              call.callId = callId;
              call.name = name;
              if (arguments.isNotEmpty && call.arguments.isEmpty) {
                call.arguments.write(arguments);
              }
            }
          case or.FunctionCallArgumentsDeltaEvent(:final delta, :final itemId):
            functionArgumentsDeltaEvents += 1;
            final call = partialToolCalls.putIfAbsent(
              itemId,
              _OpenResponsesPartialToolCall.new,
            );
            call.arguments.write(delta);
            yield ToolCallDelta(
              callId: call.callId ?? itemId,
              toolName: call.name ?? '',
              arguments: parseStreamingJson(call.arguments.toString()),
              isPartial: true,
            );
          case or.FunctionCallArgumentsDoneEvent(
            :final itemId,
            :final arguments,
          ):
            functionArgumentsDoneEvents += 1;
            final call = partialToolCalls.putIfAbsent(
              itemId,
              _OpenResponsesPartialToolCall.new,
            );
            call.arguments
              ..clear()
              ..write(arguments);
            final completeArguments = tryDecodeJsonObject(arguments);
            if (call.name != null && call.name!.isNotEmpty) {
              yield ToolCallDelta(
                callId: call.callId ?? itemId,
                toolName: call.name!,
                arguments: completeArguments ?? parseStreamingJson(arguments),
                isPartial: completeArguments == null,
              );
              if (completeArguments != null) {
                partialToolCalls.remove(itemId);
              }
            }
          case or.ResponseCompletedEvent(:final response):
            terminalEventCount += 1;
            sawTerminalEvent = true;
            terminalOutputItems += response.output?.length ?? 0;
            terminalFunctionCalls += response.functionCalls.length;
            finalUsage = _convertUsage(response.usage);
            finalFinishReason = response.functionCalls.isNotEmpty
                ? StreamFinishReason.toolCalls
                : StreamFinishReason.stop;
            if (requireTerminalEvent) {
              final complete = _parseResponse(response);
              if (textDeltaEvents == 0 && complete.text.isNotEmpty) {
                yield TextDelta(complete.text);
              }
              if (thinkingDeltaEvents == 0 && complete.thinking.isNotEmpty) {
                yield ThinkingDelta(complete.thinking);
              }
            }
            for (final event in completedResponseEvents(response)) {
              yield event;
            }
            partialToolCalls.clear();
          case or.ResponseIncompleteEvent(:final response):
            terminalEventCount += 1;
            sawTerminalEvent = true;
            terminalOutputItems += response.output?.length ?? 0;
            terminalFunctionCalls += response.functionCalls.length;
            finalUsage = _convertUsage(response.usage);
            finalFinishReason = switch (response.incompleteDetails?.reason) {
              'max_output_tokens' => StreamFinishReason.length,
              'content_filter' => StreamFinishReason.contentFilter,
              _ => StreamFinishReason.unknown,
            };
            for (final event in completedResponseEvents(response)) {
              yield event;
            }
            partialToolCalls.clear();
          // 宽松模式只容忍终态之后的多余错误事件；终态前的失败不能当作空回复。
          case or.ResponseFailedEvent(:final error):
            if (requireTerminalEvent || !sawTerminalEvent) {
              throw _streamException(streamId, eventType, error);
            }
          case or.ErrorEvent(:final error):
            if (requireTerminalEvent || !sawTerminalEvent) {
              throw _streamException(streamId, eventType, error);
            }
          default:
            unknownEventCount += 1;
        }
        // Event names are intentionally logged without payloads; response
        // content and tool arguments may contain user data or novel content.
        if (eventCount <= 3 || sawTerminalEvent) {
          if (_log.isDebugEnabled) {
            _log.debug(
              'responses stream event id=$streamId index=$eventCount '
              'type=$eventType terminal=$sawTerminalEvent',
            );
          }
        }
        if (requireTerminalEvent && sawTerminalEvent) {
          break;
        }
      }
      if (partialToolCalls.isNotEmpty && !requireTerminalEvent) {
        openToolCallsAtEof = partialToolCalls.length;
        // A relay may close the stream before response.completed/incomplete.
        // Recover only calls whose name and arguments are already complete;
        // unresolved JSON remains in the assembler and is rejected safely.
        for (final delta in terminalToolCallDeltas(
          keepIncomplete: true,
          terminal: 'eof',
        )) {
          yield delta;
        }
      }
      final terminalReason = finalFinishReason?.name ?? 'none';
      final diagnostic =
          'responses stream end id=$streamId model=${model ?? 'none'} '
          'events=$eventCount unknownEvents=$unknownEventCount '
          'lastEvent=$lastEventType '
          'textDeltaEvents=$textDeltaEvents textChars=$textChars '
          'thinkingDeltaEvents=$thinkingDeltaEvents thinkingChars=$thinkingChars '
          'outputItemAddedEvents=$outputItemAddedEvents '
          'functionArgumentsDeltaEvents=$functionArgumentsDeltaEvents '
          'functionArgumentsDoneEvents=$functionArgumentsDoneEvents '
          'terminalEvents=$terminalEventCount '
          'terminalOutputItems=$terminalOutputItems '
          'terminalFunctionCalls=$terminalFunctionCalls '
          'openToolCallsAtEof=$openToolCallsAtEof '
          'finishReason=$terminalReason usage=${finalUsage?.totalTokens ?? 'none'} '
          'cancelled=$_cancelled';
      if (!sawTerminalEvent && !_cancelled) {
        _log.warning('$diagnostic missingTerminalEvent=true');
        if (requireTerminalEvent) {
          throw StateError('Responses stream ended without a terminal event');
        }
      } else {
        _log.info('$diagnostic missingTerminalEvent=${!sawTerminalEvent}');
      }
      // 流式完成，发送 completion 事件
      if (_cancelled && requireTerminalEvent) {
        yield StreamCancelled();
      } else {
        yield StreamComplete(
          usage: finalUsage,
          finishReason: finalFinishReason,
        );
      }
    } catch (error, stackTrace) {
      _log.error(
        'responses stream error id=$streamId model=${model ?? 'none'} '
        'events=$eventCount unknownEvents=$unknownEventCount '
        'lastEvent=$lastEventType textChars=$textChars '
        'thinkingChars=$thinkingChars terminalEvents=$terminalEventCount '
        'openToolCallsAtEof=$openToolCallsAtEof '
        'finishReason=${finalFinishReason?.name ?? 'none'} '
        'usage=${finalUsage?.totalTokens ?? 'none'} cancelled=$_cancelled',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      _cancelled = false;
      _abortCompleter = null;
    }
  }

  /// `response.completed` 事件需要补发的 StreamEvent。
  ///
  /// store=false 模式下服务端不保存响应，每个 reasoning item 的 encrypted_content
  /// 必须随事件流上抛、由上层拼回 ThinkingBlock，下一轮才能回传给服务端，否则推理链断裂。
  /// 同时补发完整的 tool call。usage 由调用方单独处理。
  @visibleForTesting
  List<StreamEvent> completedResponseEvents(or.ResponseResource response) {
    final events = <StreamEvent>[];
    for (final item in response.reasoningItems) {
      final encrypted = item.encryptedContent;
      if (encrypted != null && encrypted.isNotEmpty) {
        events.add(EncryptedContentDelta(encrypted));
      }
    }
    for (final fc in response.functionCalls) {
      final completeArguments = tryDecodeJsonObject(fc.arguments);
      events.add(
        ToolCallDelta(
          callId: fc.callId,
          toolName: fc.name,
          arguments: completeArguments ?? parseStreamingJson(fc.arguments),
          isPartial: completeArguments == null,
        ),
      );
    }
    return events;
  }

  /// 从 OpenAI Responses Usage 转换为通用 AiUsage
  AiUsage? _convertUsage(or.Usage? usage) {
    if (usage == null) return null;
    return AiUsage(
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      cacheReadTokens: usage.inputTokensDetails?.cachedTokens ?? 0,
      reasoningTokens: usage.outputTokensDetails?.reasoningTokens ?? 0,
    );
  }

  ChatResponse _parseResponse(or.ResponseResource response) {
    switch (response.status) {
      case or.ResponseStatus.failed:
      case or.ResponseStatus.cancelled:
      case or.ResponseStatus.queued:
      case or.ResponseStatus.inProgress:
        throw StateError('Responses request status: ${response.status!.value}');
      default:
        break;
    }
    final textBuf = StringBuffer();
    final thinkBuf = StringBuffer();
    final toolCalls = <ToolCall>[];

    for (final item in response.output ?? []) {
      if (item is or.MessageOutputItem) {
        for (final content in item.content) {
          if (content is or.OutputTextContent) {
            textBuf.write(content.text);
          } else if (content is or.ReasoningTextContent) {
            thinkBuf.write(content.text);
          }
        }
      } else if (item is or.ReasoningItem) {
        for (final summary in item.summary) {
          thinkBuf.write(summary.text);
        }
      } else if (item is or.FunctionCallOutputItemResponse) {
        toolCalls.add(
          ToolCall(
            callId: item.callId,
            toolName: item.name,
            arguments: parseStreamingJson(item.arguments),
          ),
        );
      }
    }

    final encryptedContents = <String>[];
    for (final item in response.output ?? []) {
      if (item is or.ReasoningItem &&
          item.encryptedContent != null &&
          item.encryptedContent!.isNotEmpty) {
        encryptedContents.add(item.encryptedContent!);
      }
    }

    return ChatResponse(
      text: textBuf.toString(),
      thinking: thinkBuf.toString(),
      encryptedContents: encryptedContents,
      toolCalls: toolCalls,
      usage: _convertUsage(response.usage),
      finishReason: switch (response.incompleteDetails?.reason) {
        'max_output_tokens' => StreamFinishReason.length,
        'content_filter' => StreamFinishReason.contentFilter,
        null when response.status == or.ResponseStatus.completed =>
          toolCalls.isNotEmpty
              ? StreamFinishReason.toolCalls
              : StreamFinishReason.stop,
        _ => StreamFinishReason.unknown,
      },
    );
  }

  @override
  Future<List<double>> embed(String text, {String? model}) async {
    throw UnsupportedError('Responses API does not support text embedding');
  }
}

class _OpenResponsesPartialToolCall {
  String? callId;
  String? name;
  final StringBuffer arguments = StringBuffer();
}
