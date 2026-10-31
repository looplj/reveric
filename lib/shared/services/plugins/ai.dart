// 职责: 为插件列出已配置的聊天模型，并用指定或默认模型执行单次文本生成、记录用量。
// 关联文件:
//   lib/shared/services/ai/chat.dart
//   lib/shared/services/ai/usage_hook.dart
//   lib/shared/providers/plugin_providers.dart
//   lib/shared/services/plugins/host.dart
//   plugins/sdk/index.d.ts
import 'dart:async';

import '../../agent/agent_tool_dispatcher.dart';
import '../../agent/client.dart'
    show IncompleteModelResponseException, StreamFinishReason;
import '../../models/ai_chat_models.dart';
import '../../models/ai_provider.dart';
import '../ai/chat.dart';
import '../ai/usage_hook.dart';
import '../ai/usage_service.dart';
import 'runtime.dart';

/// 插件单次请求可申请的最大输出 token。
const pluginAiMaxOutputTokens = 65536;

/// 宿主调用的插件 AI 能力；测试可替换实现。
abstract interface class PluginAiApi {
  List<Map<String, dynamic>> listModels();

  Future<PluginAiResult> generate(
    PluginAiRequest request,
    AgentCancellationToken cancellation,
  );
}

class PluginAiRequest {
  const PluginAiRequest({
    required this.pluginId,
    required this.label,
    required this.system,
    required this.prompt,
    this.runId,
    this.providerId,
    this.model,
    this.maxOutputTokens,
    this.reasoningEffort,
  });

  /// 校验插件传入的 `ai.generateText` 参数。
  factory PluginAiRequest.fromArgs(
    Map<String, dynamic> args, {
    required String pluginId,
    required String label,
    String? runId,
  }) {
    final system = args['system'],
        prompt = args['prompt'],
        providerId = args['providerId'],
        model = args['model'],
        maxTokens = args['maxOutputTokens'],
        effort = args['reasoningEffort'];
    if (system is! String || prompt is! String || prompt.trim().isEmpty) {
      throw PluginHostError(
        'invalid_argument',
        'system must be a string and prompt a non-empty string',
      );
    }
    if ((providerId == null) != (model == null) ||
        (providerId != null && (providerId is! String || model is! String))) {
      throw PluginHostError(
        'invalid_argument',
        'providerId and model must be strings given together',
      );
    }
    if (maxTokens != null &&
        (maxTokens is! int ||
            maxTokens < 1 ||
            maxTokens > pluginAiMaxOutputTokens)) {
      throw PluginHostError(
        'invalid_argument',
        'maxOutputTokens must be an integer from 1 to $pluginAiMaxOutputTokens',
      );
    }
    if (effort != null && effort is! String) {
      throw PluginHostError(
        'invalid_argument',
        'reasoningEffort must be a string',
      );
    }
    return PluginAiRequest(
      pluginId: pluginId,
      label: label,
      runId: runId,
      system: system,
      prompt: prompt,
      providerId: providerId as String?,
      model: model as String?,
      maxOutputTokens: maxTokens as int?,
      reasoningEffort: effort as String?,
    );
  }

  final String pluginId, system, prompt;

  /// 调用来源，如 `task:organize`、`tool:MemorySearch`，写入用量记录。
  final String label;
  final String? runId, providerId, model, reasoningEffort;
  final int? maxOutputTokens;
}

/// [usage] 为 provider 报告的 token 用量（snake_case 键），供任务汇总。
typedef PluginAiResult = ({
  String text,
  String finishReason,
  String providerId,
  String model,
  Map<String, dynamic> usage,
});

class PluginAiService implements PluginAiApi {
  PluginAiService({
    required this.settings,
    required this.usageService,
    this.requestTimeout = const Duration(minutes: 5),
    AiClient Function(AiProvider, String, String?)? clientFactory,
  }) : clientFactory =
           clientFactory ??
           ((provider, model, effort) =>
               AiClient(provider, chatModel: model, reasoningEffort: effort));
  final AiSettings Function() settings;
  final UsageService usageService;
  final Duration requestTimeout;
  final AiClient Function(AiProvider, String, String?) clientFactory;

  @override
  List<Map<String, dynamic>> listModels() => [
    for (final option in settings().availableModelOptions)
      {
        'providerId': option.providerId,
        'providerName': option.providerDisplayName,
        'model': option.model,
        'modelName': option.displayModelName,
        'isDefault': option.isDefault,
        'reasoningEfforts': option.reasoningEfforts,
      },
  ];

  @override
  Future<PluginAiResult> generate(
    PluginAiRequest request,
    AgentCancellationToken cancellation,
  ) async {
    if (cancellation.isCancellationRequested) {
      throw PluginHostError('cancelled', 'AI request cancelled');
    }
    final current = settings();
    final explicit = request.providerId != null;
    final option = current.findModelOptionById(
      kind: AiModelKind.chat,
      optionId: explicit
          ? '${request.providerId}::${request.model}'
          : current.defaultOptionIdForKind(AiModelKind.chat),
    );
    if (option == null) {
      throw explicit
          ? PluginHostError(
              'model_not_found',
              'Chat model ${request.providerId}/${request.model} is not '
                  'configured or enabled; use ai.listModels()',
            )
          : PluginHostError(
              'model_not_configured',
              'No default chat model is configured',
            );
    }
    final config = current.findConfigForSelection(
      providerId: option.providerId,
      model: option.model,
    );
    if (config == null || !config.enabled || !config.isValid) {
      throw PluginHostError(
        'model_not_configured',
        'Chat model ${option.providerId}/${option.model} is unavailable',
      );
    }
    final efforts = option.reasoningEfforts;
    final requestedEffort = request.reasoningEffort;
    if (requestedEffort != null &&
        !(efforts?.contains(requestedEffort) ?? false)) {
      throw PluginHostError(
        'invalid_argument',
        efforts == null || efforts.isEmpty
            ? 'Model ${option.model} does not support reasoningEffort'
            : 'reasoningEffort for ${option.model} must be one of '
                  '${efforts.join(', ')}',
      );
    }
    final client = clientFactory(
      config,
      option.model,
      requestedEffort ??
          resolveSessionReasoningEffort(
            providerId: option.providerId,
            model: option.model,
            settings: current,
          ),
    );
    try {
      final response = await client.chatCompletionDetachedResponse(
        [
          AiMessage.system(id: 'plugin-ai-system', content: request.system),
          AiMessage.user(id: 'plugin-ai-prompt', content: request.prompt),
        ],
        timeout: requestTimeout,
        maxOutputTokens: request.maxOutputTokens,
        cancellation: cancellation,
        hooks: [
          UsageHook(
            service: usageService,
            providerId: () => option.providerId,
            model: () => option.model,
            sessionId: () => null,
            novelId: () => null,
            source: UsageSources.plugin,
            runId: () => request.runId,
            runLabel: () => '${request.pluginId}/${request.label}',
          ),
        ],
      );
      return (
        text: response.text,
        finishReason: switch (response.finishReason) {
          StreamFinishReason.stop => 'stop',
          StreamFinishReason.length => 'length',
          StreamFinishReason.toolCalls => 'tool_calls',
          StreamFinishReason.contentFilter => 'content_filter',
          StreamFinishReason.unknown || null => 'unknown',
        },
        providerId: option.providerId,
        model: option.model,
        usage: response.usage?.toJson() ?? <String, dynamic>{},
      );
    } on PluginHostError {
      rethrow;
    } catch (error) {
      if (cancellation.isCancellationRequested) {
        throw PluginHostError('cancelled', 'AI request cancelled');
      }
      throw switch (error) {
        TimeoutException() => PluginHostError(
          'timeout',
          'AI request exceeded ${requestTimeout.inSeconds} seconds',
        ),
        IncompleteModelResponseException() => PluginHostError(
          'incomplete_response',
          error.toString(),
        ),
        _ => PluginHostError('ai_error', error.toString()),
      };
    } finally {
      client.dispose();
    }
  }
}
