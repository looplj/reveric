// 职责: Anthropic provider client — 支持 extended thinking + signature + image + tool_result + trace headers + cache key
// 关联文件:
//   lib/shared/agent/client.dart
//   lib/shared/agent/message.dart
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/agent/client/_sanitize.dart
//   lib/shared/agent/client/_partial_json.dart
//   lib/shared/agent/client/trace_headers_http_client.dart
//   lib/shared/agent/client/provider_history_preflight.dart
//   lib/shared/agent/agent_config.dart

import 'dart:async';

import 'package:anthropic_sdk_dart/anthropic_sdk_dart.dart' as anthropic;
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

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
import 'provider_history_preflight.dart'
    show ProviderHistoryPolicy, preflightProviderHistory;
import 'trace_headers_http_client.dart'
    show TraceHeadersHttpClient, TraceHeadersProvider;

class AnthropicClient implements ProviderClient {
  AnthropicClient({
    required String apiKey,
    String? baseUrl,
    this.model,
    http.Client? httpClient,
    http.Client Function()? streamHttpClientFactory,
    TraceHeadersProvider? traceHeadersProvider,
    this._cacheKeyUserId,
    Map<String, String>? defaultHeaders,
  }) : _client = anthropic.AnthropicClient(
         config: anthropic.AnthropicConfig(
           authProvider: anthropic.ApiKeyProvider(apiKey),
           baseUrl: _normalizeBaseUrl(baseUrl),
           defaultHeaders: defaultHeaders ?? const {},
         ),
         httpClient: traceHeadersProvider != null
             ? TraceHeadersHttpClient(
                 inner: httpClient ?? http.Client(),
                 headersProvider: traceHeadersProvider,
               )
             : httpClient,
         streamClientFactory: streamHttpClientFactory == null
             ? null
             : () {
                 final base = streamHttpClientFactory();
                 return traceHeadersProvider != null
                     ? TraceHeadersHttpClient(
                         inner: base,
                         headersProvider: traceHeadersProvider,
                       )
                     : base;
               },
       );

  static String _normalizeBaseUrl(String? baseUrl) {
    final url = baseUrl ?? 'https://api.anthropic.com';
    if (url.endsWith('/v1')) {
      return url.substring(0, url.length - 3);
    }
    return url;
  }

  final anthropic.AnthropicClient _client;
  final String? model;
  final String? _cacheKeyUserId;

  /// 顶层自动缓存：服务端把断点放在最后一个可缓存块上，随对话增长前移。
  static const _automaticCache = anthropic.CacheControlEphemeral();
  bool _cancelled = false;
  Completer<void>? _abortCompleter;

  @override
  void cancel() {
    _cancelled = true;
    final abortCompleter = _abortCompleter;
    if (abortCompleter != null && !abortCompleter.isCompleted) {
      abortCompleter.complete();
    }
  }

  anthropic.ImageMediaType _mapImageMediaType(String mimeType) {
    return switch (mimeType.toLowerCase()) {
      'image/jpeg' || 'image/jpg' => anthropic.ImageMediaType.jpeg,
      'image/png' => anthropic.ImageMediaType.png,
      'image/gif' => anthropic.ImageMediaType.gif,
      'image/webp' => anthropic.ImageMediaType.webp,
      _ => anthropic.ImageMediaType.png,
    };
  }

  anthropic.InputContentBlock _imageToInput(ImageBlock block) {
    return anthropic.InputContentBlock.image(
      anthropic.Base64ImageSource(
        data: block.data,
        mediaType: _mapImageMediaType(block.mimeType),
      ),
    );
  }

  List<anthropic.ToolResultContent> _toolResultContents(ToolResultBlock block) {
    final out = <anthropic.ToolResultContent>[];
    for (final c in block.content) {
      switch (c) {
        case TextBlock(:final text):
          if (text.isNotEmpty) {
            out.add(anthropic.ToolResultContent.text(sanitizeSurrogates(text)));
          }
        case ImageBlock(:final data, :final mimeType):
          out.add(
            anthropic.ToolResultContent.image(
              anthropic.Base64ImageSource(
                data: data,
                mediaType: _mapImageMediaType(mimeType),
              ),
            ),
          );
        default:
          break;
      }
    }
    if (out.isEmpty) {
      out.add(const anthropic.ToolResultTextContent(''));
    }
    return out;
  }

  List<anthropic.InputContentBlock> _userBlocks(AgentMessage msg) {
    final out = <anthropic.InputContentBlock>[];
    if (msg.content.isNotEmpty) {
      out.add(
        anthropic.InputContentBlock.text(sanitizeSurrogates(msg.content)),
      );
    }
    for (final block in msg.blocks) {
      switch (block) {
        case TextBlock(:final text):
          if (text.isNotEmpty) {
            out.add(anthropic.InputContentBlock.text(sanitizeSurrogates(text)));
          }
        case ImageBlock():
          out.add(_imageToInput(block));
        case ToolResultBlock():
          out.add(
            anthropic.InputContentBlock.toolResult(
              toolUseId: block.toolCallId,
              content: _toolResultContents(block),
              isError: block.isError ? true : null,
            ),
          );
        default:
          break;
      }
    }
    return out;
  }

  List<anthropic.InputContentBlock> _assistantBlocks(AgentMessage msg) {
    final out = <anthropic.InputContentBlock>[];

    // Anthropic requires signed thinking blocks to be replayed as part of the
    // assistant turn. Keep thinking ahead of visible text/tool blocks: the
    // runtime stores visible text separately from blocks, so a single pass
    // would otherwise move text before the provider-private thinking block.
    for (final block in msg.blocks) {
      if (block case ThinkingBlock(:final text, :final signature)) {
        if (signature != null && signature.isNotEmpty) {
          out.add(
            anthropic.UnknownInputContentBlock(
              raw: {
                'type': 'thinking',
                'thinking': text,
                'signature': signature,
              },
            ),
          );
        } else if (text.isNotEmpty) {
          out.add(anthropic.InputContentBlock.text(sanitizeSurrogates(text)));
        }
      }
    }

    if (msg.content.isNotEmpty) {
      out.add(
        anthropic.InputContentBlock.text(sanitizeSurrogates(msg.content)),
      );
    }
    for (final block in msg.blocks) {
      switch (block) {
        case TextBlock(:final text):
          if (text.isNotEmpty) {
            out.add(anthropic.InputContentBlock.text(sanitizeSurrogates(text)));
          }
        case ThinkingBlock():
          break;
        case ToolCallBlock(:final callId, :final toolName, :final arguments):
          out.add(
            anthropic.InputContentBlock.toolUse(
              id: callId,
              name: toolName,
              input: arguments,
            ),
          );
        default:
          break;
      }
    }
    return out;
  }

  @visibleForTesting
  List<anthropic.InputMessage> convertMessages(List<AgentMessage> messages) {
    preflightProviderHistory(messages, ProviderHistoryPolicy.anthropic);
    final nonSystem = messages
        .where((m) => m.role != AgentMessageRole.system)
        .toList();
    final out = <anthropic.InputMessage>[];

    for (var i = 0; i < nonSystem.length; i++) {
      final msg = nonSystem[i];

      if (msg.role == AgentMessageRole.user) {
        final aggregated = <anthropic.InputContentBlock>[];
        aggregated.addAll(_userBlocks(msg));
        var j = i + 1;
        while (j < nonSystem.length &&
            nonSystem[j].role == AgentMessageRole.user &&
            _hasToolResult(nonSystem[j])) {
          aggregated.addAll(_userBlocks(nonSystem[j]));
          j++;
        }
        if (aggregated.isNotEmpty) {
          out.add(
            anthropic.InputMessage(
              role: anthropic.MessageRole.user,
              content: anthropic.MessageContent.blocks(aggregated),
            ),
          );
        }
        i = j - 1;
      } else if (msg.role == AgentMessageRole.assistant) {
        final blocks = _assistantBlocks(msg);
        if (blocks.isEmpty) continue;
        out.add(
          anthropic.InputMessage(
            role: anthropic.MessageRole.assistant,
            content: anthropic.MessageContent.blocks(blocks),
          ),
        );
      }
    }

    return out;
  }

  bool _hasToolResult(AgentMessage msg) {
    for (final b in msg.blocks) {
      if (b is ToolResultBlock) return true;
    }
    return false;
  }

  anthropic.ToolDefinition _toAnthropicTool(ToolDef tool) {
    return anthropic.ToolDefinition.custom(
      anthropic.Tool(
        name: tool.name,
        description: tool.description,
        inputSchema: anthropic.InputSchema.fromJson(toolDefToJsonSchema(tool)),
      ),
    );
  }

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async {
    _cancelled = false;
    final systemMsgs = messages.where((m) => m.role == AgentMessageRole.system);
    final systemText = systemMsgs.map((m) => m.content).join('\n');
    final opts = options ?? const AgentConfig();

    final request = anthropic.MessageCreateRequest(
      model: model ?? '',
      maxTokens: opts.maxTokens,
      messages: convertMessages(messages),
      system: systemText.isNotEmpty
          ? anthropic.SystemPrompt.text(sanitizeSurrogates(systemText))
          : null,
      tools: tools?.map(_toAnthropicTool).toList(),
      temperature: opts.temperature,
      thinking: _resolveThinking(opts),
      metadata: _cacheKeyUserId != null
          ? anthropic.Metadata(userId: _cacheKeyUserId)
          : null,
      cacheControl: _automaticCache,
    );

    final response = await _client.messages.create(request);
    return _parseAnthropicResponse(response);
  }

  /// 从 Anthropic Usage 转换为通用 AiUsage
  ///
  /// inputTokens = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
  ///      因为 Anthropic 的 input_tokens 不包含 cached tokens
  AiUsage? _convertUsage(anthropic.Usage? usage) {
    if (usage == null) return null;
    final cacheRead = usage.cacheReadInputTokens ?? 0;
    final cacheWrite = usage.cacheCreationInputTokens ?? 0;
    return AiUsage(
      inputTokens: usage.inputTokens + cacheRead + cacheWrite,
      outputTokens: usage.outputTokens,
      cacheReadTokens: cacheRead,
      cacheWriteTokens: cacheWrite,
      reasoningTokens: 0,
    );
  }

  /// 从 Anthropic MessageDeltaUsage 转换为通用 AiUsage
  AiUsage? _convertDeltaUsage(anthropic.MessageDeltaUsage? usage) {
    if (usage == null) return null;
    final cacheRead = usage.cacheReadInputTokens ?? 0;
    final cacheWrite = usage.cacheCreationInputTokens ?? 0;
    return AiUsage(
      inputTokens: (usage.inputTokens ?? 0) + cacheRead + cacheWrite,
      outputTokens: usage.outputTokens,
      cacheReadTokens: cacheRead,
      cacheWriteTokens: cacheWrite,
      reasoningTokens: 0,
    );
  }

  /// 解析 thinking 配置：
  /// - none → `thinking:{type:"disabled"}`（关闭推理）
  /// - low/medium/high → `thinking:{type:"enabled", budget_tokens}`（5000/15000/30000）
  /// - 默认（无 effort）且无 reasoningBudget → 不设 thinking
  anthropic.ThinkingConfig? _resolveThinking(AgentConfig opts) {
    final effort = opts.reasoningEffort;
    if (effort == null) {
      if (opts.reasoningBudget == null) return null;
      return _enabledThinking(opts.reasoningBudget!, opts.maxTokens);
    }
    if (effort == 'none') {
      return anthropic.ThinkingConfig.disabled();
    }
    final budget = switch (effort) {
      'low' => 5000,
      'medium' => 15000,
      'high' => 30000,
      _ => 15000,
    };
    return _enabledThinking(budget, opts.maxTokens);
  }

  /// anthropic 要求 budget_tokens >= 1024 且 < max_tokens；不满足则不启用。
  anthropic.ThinkingConfig? _enabledThinking(int budget, int maxTokens) {
    final clamped = budget < 1024 ? 1024 : budget;
    if (clamped >= maxTokens) return null;
    return anthropic.ThinkingConfig.enabled(
      budgetTokens: clamped,
      display: anthropic.ThinkingDisplayMode.summarized,
    );
  }

  StreamFinishReason _mapStopReason(anthropic.StopReason reason) {
    return switch (reason) {
      anthropic.StopReason.endTurn ||
      anthropic.StopReason.stopSequence => StreamFinishReason.stop,
      anthropic.StopReason.toolUse => StreamFinishReason.toolCalls,
      anthropic.StopReason.maxTokens ||
      anthropic.StopReason.pauseTurn ||
      anthropic.StopReason.compaction ||
      anthropic.StopReason.modelContextWindowExceeded =>
        StreamFinishReason.length,
      anthropic.StopReason.refusal => StreamFinishReason.contentFilter,
    };
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    _cancelled = false;
    _abortCompleter = Completer<void>();
    final systemMsgs = messages.where((m) => m.role == AgentMessageRole.system);
    final systemText = systemMsgs.map((m) => m.content).join('\n');
    final opts = options ?? const AgentConfig();

    final request = anthropic.MessageCreateRequest(
      model: model ?? '',
      maxTokens: opts.maxTokens,
      messages: convertMessages(messages),
      system: systemText.isNotEmpty
          ? anthropic.SystemPrompt.text(sanitizeSurrogates(systemText))
          : null,
      tools: tools?.map(_toAnthropicTool).toList(),
      temperature: opts.temperature,
      thinking: _resolveThinking(opts),
      metadata: _cacheKeyUserId != null
          ? anthropic.Metadata(userId: _cacheKeyUserId)
          : null,
      cacheControl: _automaticCache,
    );

    final stream = _client.messages.createStream(
      request,
      abortTrigger: _abortCompleter?.future,
    );
    String? currentToolId;
    String? currentToolName;
    final currentArgs = StringBuffer();
    AiUsage? finalUsage;
    StreamFinishReason? finalFinishReason;

    try {
      await for (final event in stream) {
        if (_cancelled) {
          yield StreamCancelled();
          return;
        }

        // 解析 usage (message_delta 事件)
        if (event is anthropic.MessageDeltaEvent) {
          final usage = event.usage;
          finalUsage = _convertDeltaUsage(usage);
          final stopReason = event.delta.stopReason;
          if (stopReason != null) {
            finalFinishReason = _mapStopReason(stopReason);
          }
        }

        if (event is anthropic.ContentBlockStartEvent) {
          final block = event.contentBlock;
          if (block is anthropic.ToolUseBlock) {
            // Some Anthropic-compatible providers start the next tool without
            // stopping the previous one. If the previous args are already a
            // complete JSON object, finalize it before switching buffers.
            if (currentToolId != null && currentToolName != null) {
              final completedArgs = tryDecodeJsonObject(currentArgs.toString());
              if (completedArgs != null) {
                yield ToolCallDelta(
                  callId: currentToolId,
                  toolName: currentToolName,
                  arguments: completedArgs,
                  isPartial: false,
                );
              }
            }
            currentToolId = block.id;
            currentToolName = block.name;
            currentArgs.clear();
          }
        } else if (event is anthropic.ContentBlockDeltaEvent) {
          final delta = event.delta;
          if (delta is anthropic.TextDelta) {
            yield TextDelta(delta.text);
          } else if (delta is anthropic.ThinkingDelta) {
            yield ThinkingDelta(delta.thinking);
          } else if (delta is anthropic.SignatureDelta) {
            yield SignatureDelta(delta.signature);
          } else if (delta is anthropic.InputJsonDelta) {
            currentArgs.write(delta.partialJson);
            if (currentToolId != null && currentToolName != null) {
              yield ToolCallDelta(
                callId: currentToolId,
                toolName: currentToolName,
                arguments: parseStreamingJson(currentArgs.toString()),
                isPartial: true,
              );
            }
          }
        } else if (event is anthropic.ContentBlockStopEvent) {
          if (currentToolId != null && currentToolName != null) {
            final rawArguments = currentArgs.toString();
            final completedArgs = tryDecodeJsonObject(rawArguments);
            yield ToolCallDelta(
              callId: currentToolId,
              toolName: currentToolName,
              arguments: completedArgs ?? parseStreamingJson(rawArguments),
              isPartial: completedArgs == null,
            );
            currentToolId = null;
            currentToolName = null;
            currentArgs.clear();
          }
        } else if (event is anthropic.MessageStopEvent) {
          // Some Anthropic-compatible providers emit complete tool JSON but
          // omit the matching content_block_stop. Treat it as final only when
          // the raw argument buffer is a complete JSON object; incomplete
          // buffers still surface as partial tool calls for diagnosis.
          final completedArgs = tryDecodeJsonObject(currentArgs.toString());
          if (currentToolId != null &&
              currentToolName != null &&
              completedArgs != null) {
            yield ToolCallDelta(
              callId: currentToolId,
              toolName: currentToolName,
              arguments: completedArgs,
              isPartial: false,
            );
            currentToolId = null;
            currentToolName = null;
            currentArgs.clear();
          }
        }
      }
      if (_cancelled) {
        yield StreamCancelled();
        return;
      }
      // Same compatibility guard for streams that end without message_stop.
      // This handles non-standard relays while preserving the incomplete-tool
      // error when the provider actually cuts off malformed JSON.
      final completedArgs = tryDecodeJsonObject(currentArgs.toString());
      if (currentToolId != null &&
          currentToolName != null &&
          completedArgs != null) {
        yield ToolCallDelta(
          callId: currentToolId,
          toolName: currentToolName,
          arguments: completedArgs,
          isPartial: false,
        );
        currentToolId = null;
        currentToolName = null;
        currentArgs.clear();
      }
      // 流式完成，发送 completion 事件
      yield StreamComplete(usage: finalUsage, finishReason: finalFinishReason);
    } finally {
      _abortCompleter = null;
    }
  }

  ChatResponse _parseAnthropicResponse(anthropic.Message response) {
    final textBuf = StringBuffer();
    final thinkBuf = StringBuffer();
    String? signature;
    final toolCalls = <ToolCall>[];

    for (final block in response.content) {
      if (block is anthropic.TextBlock) {
        textBuf.write(block.text);
      } else if (block is anthropic.ThinkingBlock) {
        thinkBuf.write(block.thinking);
        signature = block.signature;
      } else if (block is anthropic.RedactedThinkingBlock) {
        thinkBuf.write('[redacted thinking]');
      } else if (block is anthropic.ToolUseBlock) {
        toolCalls.add(
          ToolCall(
            callId: block.id,
            toolName: block.name,
            arguments: Map<String, dynamic>.from(block.input),
          ),
        );
      }
    }

    return ChatResponse(
      text: textBuf.toString(),
      thinking: thinkBuf.toString(),
      signature: signature,
      toolCalls: toolCalls,
      usage: _convertUsage(response.usage),
      finishReason: response.stopReason == null
          ? null
          : _mapStopReason(response.stopReason!),
    );
  }

  @override
  Future<List<double>> embed(String text, {String? model}) async {
    throw UnsupportedError('Anthropic does not support text embedding');
  }
}
