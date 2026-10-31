// 职责: AI Chat 服务 — 纯 LLM 通信层（chat / stream / cancel），不包含高级任务
// 关联文件:
//   lib/shared/agent/client.dart
//   lib/shared/services/ai/provider_initializer.dart
//   lib/shared/services/ai/context_manager.dart

//   lib/shared/models/ai_chat_models.dart

import 'package:flutter/foundation.dart';

import '../../logger/app_logger.dart';
import '../../models/ai_chat_models.dart';
import '../../models/models_catalog.dart' show resolveReasoningBudget;
import '../../agent/agent_config.dart'
    show AgentConfig, resolveAgentMaxTokens, resolveReasoningEffort;
import '../../agent/message.dart'
    show
        AgentMessage,
        AgentMessageRole,
        AgentMessageType,
        MessageBlock,
        ImageBlock,
        TextBlock,
        ThinkingBlock,
        ToolCallBlock;
import 'agent_message_mapping.dart';
import '../../models/ai_provider.dart';
import '../../models/ai_session_mode.dart';
import '../../agent/client.dart';
import 'context_manager.dart';
import 'prompt_template.dart';
import 'prompts/use_cases/chat_prompt_use_case.dart';
import 'tools.dart';

final _log = AppLogger.forModule('AiChatService');

class AiChatService {
  AiChatService({
    required this._client,
    required this._config,
    this._chatModel,
    this._reasoningEffort,
    this._toolManager,
    this._contextManager = const AiContextManager(),
    this._sessionContext,
    this._sessionModeNotifier,
    this._chapterToolNamesResolver,
  });

  final ProviderClient _client;
  final AiProvider _config;
  final String? _chatModel;
  final String? _reasoningEffort;
  final AiToolManager? _toolManager;
  final AiContextManager _contextManager;
  final AiSessionContext? _sessionContext;
  final ValueNotifier<AiSessionMode>? _sessionModeNotifier;
  final List<String>? Function(AiSessionContext? context)?
  _chapterToolNamesResolver;

  /// Cancels the in-flight generation.
  void cancel() {
    _client.cancel();
  }

  // ---------------------------------------------------------------------------
  // AiMessage → ProviderMessage conversion
  // ---------------------------------------------------------------------------

  static AgentMessage _aiMessageToAgentMessage(AiMessage msg) {
    final blocks = <MessageBlock>[];
    for (final block in msg.blocks) {
      switch (block) {
        case AiTextBlock(:final text):
          blocks.add(TextBlock(text));
        case AiThinkingBlock(
          :final text,
          :final signature,
          :final encryptedContents,
        ):
          blocks.add(
            ThinkingBlock(
              text,
              signature: signature,
              encryptedContents: encryptedContents,
            ),
          );
        case AiToolCallBlock(:final callId, :final toolName, :final arguments):
          blocks.add(
            ToolCallBlock(
              callId: callId,
              toolName: toolName,
              arguments: arguments,
            ),
          );
        case AiImageBlock(:final imageUrl, :final imageBase64)
            when imageBase64 != null || imageUrl?.startsWith('data:') == true:
          final source = imageBase64 == null
              ? imageUrl
              : 'data:image/png;base64,$imageBase64';
          final data = source == null ? null : Uri.tryParse(source)?.data;
          if (data == null || !data.isBase64) {
            throw ArgumentError('Inline image content requires a data URI');
          }
          blocks.add(
            ImageBlock(data: data.contentText, mimeType: data.mimeType),
          );
        case AiImageBlock():
        case AiAttachmentBlock():
        case AiAskUserBlock():
        case AiSuggestNextActionBlock():
          break;
      }
    }
    return AgentMessage(
      id: msg.id,
      role: switch (msg.role) {
        AiMessageRole.user => AgentMessageRole.user,
        AiMessageRole.assistant => AgentMessageRole.assistant,
        AiMessageRole.system => AgentMessageRole.system,
      },
      type: switch (msg.type) {
        AiMessageType.text => AgentMessageType.text,
        AiMessageType.tool_result => AgentMessageType.tool_result,
        AiMessageType.compact_summary => AgentMessageType.compact_summary,
        _ => AgentMessageType.text,
      },
      content: msg.content,
      blocks: blocks,
    );
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Single-turn chat. Returns the assistant's text response.
  Future<String> chatCompletion(
    List<AiMessage> messages, {
    AiSessionContext? context,
  }) async {
    final response = await chatCompletionResponse(messages, context: context);
    if (response.text.isEmpty) {
      _log.error(
        'empty response: provider=${_config.id} model=$_chatModel '
        'finishReason=${response.finishReason} '
        'thinkingLen=${response.thinking.length} '
        'toolCalls=${response.toolCalls.length} usage=${response.usage}',
      );
      throw Exception('Empty response from provider');
    }
    return response.text;
  }

  /// Single-turn chat, preserving provider usage metadata for accounting.
  ///
  /// [maxOutputTokens] 原样传给 provider，缺省时取模型的默认输出上限。
  /// 保留空正文响应，由调用方根据 finishReason 判断。
  Future<ChatResponse> chatCompletionResponse(
    List<AiMessage> messages, {
    AiSessionContext? context,
    int? maxOutputTokens,
  }) async {
    if (maxOutputTokens != null && maxOutputTokens < 1) {
      throw ArgumentError.value(
        maxOutputTokens,
        'maxOutputTokens',
        'Must be positive',
      );
    }
    final maxTokens = maxOutputTokens ?? resolveAgentMaxTokens(_chatModel);
    final effectiveContext = _compactContext(context ?? _sessionContext);
    final conversation = _buildConversation(messages, effectiveContext);
    final tools = _resolveTools(context);

    final resolvedEffort = resolveReasoningEffort(
      _reasoningEffort,
      modelId: _chatModel,
    );
    final response = await _client.chat(
      messages: [
        for (final message in conversation.messages)
          if (message.blocks.any((b) => b is AiAttachmentBlock))
            ...await restoreAgentMessages([message])
          else
            _aiMessageToAgentMessage(message),
      ],
      tools: tools,
      options: AgentConfig(
        temperature: _config.temperature,
        maxTokens: maxTokens,
        reasoningEffort: resolvedEffort,
        reasoningBudget: resolveReasoningBudget(_chatModel, resolvedEffort),
      ),
    );

    return response;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  List<ToolDef>? _resolveTools(AiSessionContext? context) {
    final resolver = _chapterToolNamesResolver;
    final toolManager = _toolManager;
    if (resolver == null || toolManager == null) return null;
    final names = resolver(context);
    if (names == null || names.isEmpty) return null;
    return toolManager.toolDefsForNames(names);
  }

  AiManagedConversation _buildConversation(
    List<AiMessage> messages,
    AiSessionContext? context,
  ) {
    final effectiveContext = _compactContext(context ?? _sessionContext);
    final mode = _sessionModeNotifier?.value ?? AiSessionMode.chat;
    const chatPrompt = ChatPromptUseCase();
    final systemPrompt = messages.firstOrNull?.role == AiMessageRole.system
        ? messages.first.content
        : (effectiveContext != null
              ? chatPrompt.system(
                  ChatPanelPromptInput(
                    context: effectiveContext,
                    systemInstruction: PromptTemplateService.instance.rawAsset(
                      'assets/prompts/agent/orchestrator',
                    ),
                    mode: mode,
                  ),
                )
              : '');
    final history = messages
        .where((message) => message.role != AiMessageRole.system)
        .toList();
    return _contextManager.buildConversation(
      history,
      systemPrompt: systemPrompt,
    );
  }

  AiSessionContext? _compactContext(AiSessionContext? context) {
    if (context == null) return null;
    return _contextManager.compactContext(context);
  }
}
