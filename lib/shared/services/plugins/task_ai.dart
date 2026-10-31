// 职责: 使用明确配置的默认聊天模型执行任务单次文本生成，并记录带运行身份的用量。
// 关联文件:
//   lib/shared/services/ai/chat.dart
//   lib/shared/services/ai/usage_hook.dart
//   lib/shared/providers/plugin_providers.dart
//   lib/shared/services/plugins/host.dart
import '../../agent/agent_config.dart';
import '../../agent/agent_context_manager.dart' show defaultContextTokenLimit;
import '../../agent/agent_event.dart';
import '../../agent/agent_hook.dart';
import '../../agent/agent_tool_dispatcher.dart';
import '../../agent/client.dart' show AiUsage;
import '../../agent/token_estimator.dart';
import '../../models/ai_chat_models.dart';
import '../../models/ai_provider.dart';
import '../../models/models_catalog.dart';
import '../ai/chat.dart';
import '../ai/usage_hook.dart';
import '../ai/usage_service.dart';
import 'runtime.dart';

class PluginTaskAiRequest {
  const PluginTaskAiRequest({
    required this.pluginId,
    required this.taskId,
    required this.runId,
    required this.system,
    required this.prompt,
    required this.maxOutputTokens,
  });
  final String pluginId, taskId, runId, system, prompt;
  final int maxOutputTokens;
}

typedef PluginTaskAiResult = ({String text, Map<String, dynamic> usage});
typedef PluginTaskAiExecutor =
    Future<PluginTaskAiResult> Function(
      PluginTaskAiRequest request,
      AgentCancellationToken cancellation,
    );

class PluginTaskAiService {
  PluginTaskAiService({
    required this.settings,
    required this.usageService,
    this.requestTimeout = const Duration(seconds: 120),
    AiClient Function(AiProvider, String, String?)? clientFactory,
  }) : clientFactory =
           clientFactory ??
           ((provider, model, effort) =>
               AiClient(provider, chatModel: model, reasoningEffort: effort));
  final AiSettings Function() settings;
  final UsageService usageService;
  final Duration requestTimeout;
  final AiClient Function(AiProvider, String, String?) clientFactory;
  Future<PluginTaskAiResult> generate(
    PluginTaskAiRequest request,
    AgentCancellationToken cancellation,
  ) async {
    if (cancellation.isCancellationRequested) {
      throw PluginHostError('cancelled', 'Task AI request cancelled');
    }
    final current = settings();
    final option = current.findModelOptionById(
      kind: AiModelKind.chat,
      optionId: current.defaultOptionIdForKind(AiModelKind.chat),
    );
    if (option == null) {
      throw PluginHostError(
        'model_not_configured',
        'Configure a default chat model before running task AI',
      );
    }
    final config = current.findConfigForSelection(
      providerId: option.providerId,
      model: option.model,
    );
    if (config == null || !config.enabled || !config.isValid) {
      throw PluginHostError(
        'model_not_configured',
        'Default chat model is unavailable',
      );
    }
    final maxTokens = request.maxOutputTokens.clamp(
      1,
      resolveAgentMaxTokens(option.model),
    );
    final inputTokens =
        estimateTextTokens(request.system) + estimateTextTokens(request.prompt);
    final contextLimit =
        lookupCatalogLimit(option.model)?.context ?? defaultContextTokenLimit;
    if (inputTokens + maxTokens > contextLimit) {
      throw PluginHostError(
        'context_limit',
        'Task input and output budget exceed the model context window',
      );
    }
    final capture = _TaskUsageCapture();
    final client = clientFactory(
      config,
      option.model,
      resolveSessionReasoningEffort(
        providerId: option.providerId,
        model: option.model,
        settings: current,
      ),
    );
    try {
      final text = await client.chatCompletionDetached(
        [
          AiMessage.system(id: 'plugin-task-system', content: request.system),
          AiMessage.user(id: 'plugin-task-prompt', content: request.prompt),
        ],
        timeout: requestTimeout,
        maxOutputTokens: maxTokens,
        cancellation: cancellation,
        hooks: [
          capture,
          UsageHook(
            service: usageService,
            providerId: () => option.providerId,
            model: () => option.model,
            sessionId: () => null,
            novelId: () => null,
            source: UsageSources.pluginTask,
            runId: () => request.runId,
            runLabel: () => '${request.pluginId}/${request.taskId}',
          ),
        ],
      );
      return (
        text: text,
        usage: {
          'providerId': option.providerId,
          'model': option.model,
          ...?capture.usage?.toJson(),
        },
      );
    } finally {
      client.dispose();
    }
  }
}

class _TaskUsageCapture extends AgentHook {
  AiUsage? usage;
  @override
  HookAction<AgentRoundResult> afterLLM(AgentRoundResult round) {
    usage = round.usage;
    return const HookAction.proceed();
  }
}
