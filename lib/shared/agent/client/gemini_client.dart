// 职责: Gemini provider client — 使用 googleai_dart SDK，支持 image + tool_result + trace headers
// 关联文件:
//   lib/shared/agent/client.dart
//   lib/shared/agent/message.dart
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/agent/client/_sanitize.dart
//   lib/shared/agent/client/trace_headers_http_client.dart
//   lib/shared/agent/client/provider_history_preflight.dart

import 'dart:async';

import 'package:googleai_dart/googleai_dart.dart' as gai;
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
import '_sanitize.dart' show sanitizeSurrogates;
import 'json_schema.dart' show toolDefToJsonSchema;
import 'provider_history_preflight.dart'
    show ProviderHistoryPolicy, preflightProviderHistory;
import 'trace_headers_http_client.dart'
    show TraceHeadersHttpClient, TraceHeadersProvider;

/// Gemini 原生接口根地址。SDK 与直连请求都会自行拼接 /v1beta，
/// 这里去掉用户填写的版本后缀，保留中转服务的路径前缀和查询参数。
Uri geminiApiRoot(String? baseUrl) {
  final trimmed = baseUrl?.trim() ?? '';
  if (trimmed.isEmpty) {
    return Uri.parse('https://generativelanguage.googleapis.com');
  }
  final uri = Uri.parse(trimmed);
  final path = uri.path
      .replaceFirst(RegExp(r'/+$'), '')
      .replaceFirst(RegExp(r'/v1beta$'), '');
  return uri.replace(path: path);
}

/// 不经 SDK 直接请求 `models/{model}:{method}` 时使用的完整地址。
Uri geminiModelEndpoint(String? baseUrl, String model, String method) {
  final root = geminiApiRoot(baseUrl);
  return root.replace(
    path: '${root.path}/v1beta/models/${Uri.encodeComponent(model)}:$method',
  );
}

class GeminiClient implements ProviderClient {
  GeminiClient({
    required String apiKey,
    this.model,
    String? baseUrl,
    http.Client? httpClient,
    http.Client Function()? streamHttpClientFactory,
    TraceHeadersProvider? traceHeadersProvider,
    Map<String, String>? defaultHeaders,
    bool authAsHeader = false,
  }) : _client = gai.GoogleAIClient(
         config: gai.GoogleAIConfig(
           authProvider: gai.ApiKeyProvider(
             apiKey,
             placement: authAsHeader
                 ? gai.AuthPlacement.header
                 : gai.AuthPlacement.queryParam,
           ),
           baseUrl: geminiApiRoot(baseUrl).toString(),
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

  final gai.GoogleAIClient _client;
  final String? model;
  bool _cancelled = false;
  Completer<void>? _abortCompleter;
  int _toolCallCounter = 0;

  @override
  void cancel() {
    _cancelled = true;
    final abortCompleter = _abortCompleter;
    if (abortCompleter != null && !abortCompleter.isCompleted) {
      abortCompleter.complete();
    }
  }

  gai.Part _imageToPart(ImageBlock block) {
    return gai.InlineDataPart(
      gai.Blob(mimeType: block.mimeType, data: block.data),
    );
  }

  String _ensureToolCallId(String? id, String name) {
    if (id != null && id.isNotEmpty) return id;
    return '${name}_${DateTime.now().millisecondsSinceEpoch}_${++_toolCallCounter}';
  }

  /// 追加一个 Content；Gemini 多轮请求要求 user/model 角色交替，而域层
  /// 历史可能含连续同角色消息（incomplete 恢复留下的 partial + 续跑结果、
  /// 空响应续跑时的连续 user），发送前并入上一个同角色 Content。
  void _appendContent(
    List<gai.Content> contents,
    String role,
    List<gai.Part> parts,
  ) {
    final last = contents.isNotEmpty ? contents.last : null;
    if (last != null && last.role == role) {
      last.parts.addAll(parts);
      return;
    }
    contents.add(gai.Content(role: role, parts: parts));
  }

  @visibleForTesting
  List<gai.Content> convertMessages(List<AgentMessage> messages) {
    preflightProviderHistory(messages, ProviderHistoryPolicy.gemini);
    final contents = <gai.Content>[];

    for (final msg in messages.where(
      (m) => m.role != AgentMessageRole.system,
    )) {
      if (msg.role == AgentMessageRole.user) {
        // tool_result messages are merged into a single user turn with functionResponse parts
        final toolResults = msg.blocks.whereType<ToolResultBlock>().toList();
        if (toolResults.isNotEmpty) {
          final parts = <gai.Part>[];
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
            final responseValue = textBuf.isNotEmpty
                ? sanitizeSurrogates(textBuf.toString())
                : (imgs.isNotEmpty ? '(see attached image)' : '');
            parts.add(
              gai.FunctionResponsePart(
                gai.FunctionResponse(
                  name: tr.toolName,
                  response: tr.isError
                      ? {'error': responseValue}
                      : {'output': responseValue},
                  id: tr.toolCallId,
                ),
              ),
            );
            for (final img in imgs) {
              parts.add(_imageToPart(img));
            }
          }
          // 连续 tool_result / user 消息并入同一个 user turn（角色交替约束）
          _appendContent(contents, 'user', parts);
          continue;
        }

        // Regular user message
        final parts = <gai.Part>[];
        if (msg.content.isNotEmpty) {
          parts.add(gai.TextPart(sanitizeSurrogates(msg.content)));
        }
        for (final block in msg.blocks) {
          switch (block) {
            case TextBlock(:final text):
              if (text.isNotEmpty) {
                parts.add(gai.TextPart(sanitizeSurrogates(text)));
              }
            case ImageBlock():
              parts.add(_imageToPart(block));
            default:
              break;
          }
        }
        if (parts.isEmpty) continue;
        _appendContent(contents, 'user', parts);
      } else if (msg.role == AgentMessageRole.assistant) {
        final parts = <gai.Part>[];
        if (msg.content.isNotEmpty) {
          parts.add(gai.TextPart(sanitizeSurrogates(msg.content)));
        }
        for (final block in msg.blocks) {
          switch (block) {
            case TextBlock(:final text):
              if (text.isNotEmpty) {
                parts.add(gai.TextPart(sanitizeSurrogates(text)));
              }
            case ThinkingBlock(
              :final text,
              :final signature,
              :final encryptedContents,
            ):
              if (encryptedContents.isNotEmpty) break;
              if (text.isEmpty) break;
              if (signature != null) {
                parts.add(
                  gai.TextPart(
                    sanitizeSurrogates(text),
                    thought: true,
                    thoughtSignature: signature.codeUnits,
                  ),
                );
              } else {
                parts.add(
                  gai.TextPart(sanitizeSurrogates(text), thought: true),
                );
              }
            case ToolCallBlock(
              :final callId,
              :final toolName,
              :final arguments,
              :final thoughtSignature,
            ):
              parts.add(
                gai.FunctionCallPart(
                  gai.FunctionCall(name: toolName, args: arguments, id: callId),
                  thoughtSignature: thoughtSignature,
                ),
              );
            default:
              break;
          }
        }
        if (parts.isEmpty) continue;
        _appendContent(contents, 'model', parts);
      }
    }

    return contents;
  }

  gai.FunctionDeclaration _toGeminiTool(ToolDef tool) {
    return gai.FunctionDeclaration(
      name: tool.name,
      description: tool.description,
      parameters: gai.Schema.fromJson(toolDefToJsonSchema(tool)),
    );
  }

  gai.GenerateContentRequest _buildRequest(
    List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig opts,
  ) {
    final systemMsgs = messages.where((m) => m.role == AgentMessageRole.system);
    final systemText = systemMsgs.map((m) => m.content).join('\n');

    gai.ThinkingConfig? thinkingConfig;
    final effort = opts.reasoningEffort;
    if (effort != null || opts.reasoningBudget != null) {
      thinkingConfig = gai.ThinkingConfig(
        // 'none' = 关闭推理：不回传 thoughts
        includeThoughts: effort != null && effort != 'none',
        thinkingBudget: opts.reasoningBudget,
      );
    }

    final toolList = (tools != null && tools.isNotEmpty)
        ? [gai.Tool(functionDeclarations: tools.map(_toGeminiTool).toList())]
        : null;

    return gai.GenerateContentRequest(
      contents: convertMessages(messages),
      generationConfig: gai.GenerationConfig(
        temperature: opts.temperature,
        maxOutputTokens: opts.maxTokens,
        thinkingConfig: thinkingConfig,
      ),
      systemInstruction: systemText.isNotEmpty
          ? gai.Content(
              parts: [gai.TextPart(sanitizeSurrogates(systemText))],
              role: 'user',
            )
          : null,
      tools: toolList,
    );
  }

  /// 从 Gemini UsageMetadata 转换为通用 AiUsage
  AiUsage? _convertUsage(gai.UsageMetadata? usage) {
    if (usage == null) return null;
    // outputTokens = candidatesTokenCount + thoughtsTokenCount
    final thoughts = usage.thoughtsTokenCount ?? 0;
    return AiUsage(
      inputTokens: usage.promptTokenCount ?? 0,
      outputTokens: (usage.candidatesTokenCount ?? 0) + thoughts,
      cacheReadTokens: usage.cachedContentTokenCount ?? 0,
      reasoningTokens: thoughts,
    );
  }

  StreamFinishReason _mapFinishReason(gai.FinishReason reason) {
    return switch (reason) {
      gai.FinishReason.stop => StreamFinishReason.stop,
      gai.FinishReason.maxTokens => StreamFinishReason.length,
      gai.FinishReason.safety ||
      gai.FinishReason.recitation ||
      gai.FinishReason.blocklist ||
      gai.FinishReason.prohibitedContent ||
      gai.FinishReason.spii ||
      gai.FinishReason.language ||
      gai.FinishReason.imageSafety ||
      gai.FinishReason.imageProhibitedContent ||
      gai.FinishReason.imageRecitation ||
      gai.FinishReason.escalation => StreamFinishReason.contentFilter,
      gai.FinishReason.unspecified ||
      gai.FinishReason.other ||
      gai.FinishReason.malformedFunctionCall ||
      gai.FinishReason.imageOther ||
      gai.FinishReason.noImage ||
      gai.FinishReason.unexpectedToolCall ||
      gai.FinishReason.tooManyToolCalls ||
      gai.FinishReason.missingThoughtSignature ||
      gai.FinishReason.malformedResponse => StreamFinishReason.unknown,
    };
  }

  ChatResponse _parseGeminiResponse(gai.GenerateContentResponse response) {
    final textBuf = StringBuffer();
    final thinkBuf = StringBuffer();
    final toolCalls = <ToolCall>[];
    final blockReason = response.promptFeedback?.blockReason;
    StreamFinishReason? finishReason = blockReason == null
        ? null
        : _mapFinishReason(blockReason);

    for (final candidate in response.candidates ?? []) {
      final candidateFinishReason = candidate.finishReason;
      if (candidateFinishReason != null) {
        finishReason = _mapFinishReason(candidateFinishReason);
      }
      for (final part in candidate.content?.parts ?? []) {
        switch (part) {
          case gai.TextPart(
            :final text,
            :final thought,
            :final thoughtSignature,
          ):
            if (thought == true) {
              if (thoughtSignature != null) {
                thinkBuf.write(
                  '[signature: ${String.fromCharCodes(thoughtSignature)}] ',
                );
              }
              thinkBuf.write(text);
            } else {
              textBuf.write(text);
            }
          case gai.ThoughtPart(:final thoughtSignature):
            if (thoughtSignature != null) {
              thinkBuf.write(
                '[signature: ${String.fromCharCodes(thoughtSignature)}] ',
              );
            }
          case gai.FunctionCallPart(
            :final functionCall,
            :final thoughtSignature,
          ):
            toolCalls.add(
              ToolCall(
                callId: _ensureToolCallId(functionCall.id, functionCall.name),
                toolName: functionCall.name,
                arguments: functionCall.args is Map
                    ? Map<String, dynamic>.from(functionCall.args as Map)
                    : {},
                thoughtSignature: thoughtSignature,
              ),
            );
        }
      }
    }

    return ChatResponse(
      text: textBuf.toString(),
      thinking: thinkBuf.toString(),
      toolCalls: toolCalls,
      usage: _convertUsage(response.usageMetadata),
      finishReason: finishReason,
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
    final request = _buildRequest(messages, tools, opts);
    final response = await _client.models.generateContent(
      model: model ?? 'gemini-2.0-flash',
      request: request,
    );
    return _parseGeminiResponse(response);
  }

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) async* {
    _cancelled = false;
    _abortCompleter = Completer<void>();
    final opts = options ?? const AgentConfig();
    final request = _buildRequest(messages, tools, opts);

    final stream = _client.models.streamGenerateContent(
      model: model ?? 'gemini-2.0-flash',
      request: request,
      abortTrigger: _abortCompleter?.future,
    );

    AiUsage? finalUsage;
    StreamFinishReason? finalFinishReason;

    try {
      await for (final chunk in stream) {
        if (_cancelled) break;

        // 解析 usage (通常在最后一个 chunk)
        if (chunk.usageMetadata != null) {
          finalUsage = _convertUsage(chunk.usageMetadata);
        }

        final promptBlockReason = chunk.promptFeedback?.blockReason;
        if (promptBlockReason != null) {
          finalFinishReason = _mapFinishReason(promptBlockReason);
        }

        for (final candidate in chunk.candidates ?? []) {
          final candidateFinishReason = candidate.finishReason;
          if (candidateFinishReason != null) {
            finalFinishReason = _mapFinishReason(candidateFinishReason);
          }
          for (final part in candidate.content?.parts ?? []) {
            switch (part) {
              case gai.TextPart(
                :final text,
                :final thought,
                :final thoughtSignature,
              ):
                if (thought == true) {
                  if (text.isNotEmpty) yield ThinkingDelta(text);
                  if (thoughtSignature != null) {
                    yield SignatureDelta(
                      String.fromCharCodes(thoughtSignature),
                    );
                  }
                } else {
                  if (text.isNotEmpty) yield TextDelta(text);
                }
              case gai.ThoughtPart(:final thoughtSignature):
                if (thoughtSignature != null) {
                  yield SignatureDelta(String.fromCharCodes(thoughtSignature));
                }
              case gai.FunctionCallPart(
                :final functionCall,
                :final thoughtSignature,
              ):
                yield ToolCallDelta(
                  callId: _ensureToolCallId(functionCall.id, functionCall.name),
                  toolName: functionCall.name,
                  arguments: functionCall.args is Map
                      ? Map<String, dynamic>.from(functionCall.args as Map)
                      : {},
                  isPartial: false,
                  thoughtSignature: thoughtSignature,
                );
              default:
                break;
            }
          }
        }
      }
      // 流式完成，发送 completion 事件
      yield StreamComplete(usage: finalUsage, finishReason: finalFinishReason);
    } catch (_) {
      // Some SSE relays append an inline error after Gemini has already sent
      // a terminal finish reason. The model response is complete at that
      // point; do not turn the valid response into a client-side failure.
      if (finalFinishReason != null) {
        yield StreamComplete(
          usage: finalUsage,
          finishReason: finalFinishReason,
        );
        return;
      }
      rethrow;
    } finally {
      _abortCompleter = null;
    }
  }

  @override
  Future<List<double>> embed(String text, {String? model}) async {
    final response = await _client.models.embedContent(
      model: model ?? 'text-embedding-004',
      request: gai.EmbedContentRequest(
        content: gai.Content(parts: [gai.TextPart(text)]),
      ),
    );
    return response.embedding.values;
  }
}
