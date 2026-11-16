// 职责: Agent 运行时配置 — temperature / maxTokens / reasoning / thinking / trace
// 关联文件:
//   lib/shared/agent/agent.dart
//   lib/shared/agent/agent_context_manager.dart
//   lib/shared/services/ai/chat.dart
//   lib/shared/agent/client.dart
//   lib/shared/models/models_catalog.dart

import 'dart:math';

import '../models/models_catalog.dart'
    show lookupCatalogLimit, resolveRequestTemperature, useThinkingField;
import 'agent_context_manager.dart' show compactThresholdForContextLimit;

/// 单轮输出预算的统一上限。模型自身上限或上下文余量更小时以更小者为准。
const int agentMaxTokensCeiling = 48000;

/// catalog 未收录该模型时的保守输出预算。
///
/// 取 32000 而非 32768：目录里最低的一档主流输出上限就是 32000
///（Kimi K2.x / 豆包 Seed 2.0 / MiniMax / Mimo / deepseek-v3.2），
/// 32768 对这些模型已经越界。
const int unknownModelMaxTokens = 32000;

/// 按模型解析单轮输出预算，取以下三者最小值：
///
/// 1. [agentMaxTokensCeiling]；
/// 2. catalog 记录的该模型输出上限，缺失时用 [unknownModelMaxTokens]；
/// 3. 上下文余量 `context - compactThreshold`，即压缩线之上留给输出的空间。
///
/// 第 3 项不能省：`input + max_tokens` 超出模型窗口时，Anthropic 不报错而是
/// 生成到一半停（`model_context_window_exceeded`），DeepSeek 则直接 400。
/// 压缩阈值是输入侧的最坏情况，按它预留才能保证两种协议都不越界。
int resolveAgentMaxTokens(String? modelId) {
  final limit = modelId == null || modelId.isEmpty
      ? null
      : lookupCatalogLimit(modelId);
  var budget = min(
    agentMaxTokensCeiling,
    limit?.output ?? unknownModelMaxTokens,
  );
  final contextTokens = limit?.context;
  if (contextTokens != null) {
    budget = min(
      budget,
      contextTokens - compactThresholdForContextLimit(contextTokens),
    );
  }
  return budget;
}

class AgentConfig {
  final double temperature;

  /// 为 false 时请求省略 temperature。供应商 config 默认关闭。
  final bool enableTemperature;

  /// Provider 设置 UI 已废弃；请求构造时由 [resolveAgentMaxTokens] 按模型解析。
  /// 默认值只覆盖「调用方没解析过」的兜底路径，与未知模型同档。
  final int maxTokens;

  /// 推理档位；`on` 是只提供 thinking 开关的模型的 UI 值。
  ///
  /// `normalizeReasoningEfforts(['none'])` 会补出 `on`，使用户能显式开启
  /// 推理而不虚构 low/medium/high 档位。构造请求前必须经
  /// [resolveReasoningEffort] 归一化：仅 `useThinkingField` 模型保留 `on`，
  /// 再由 Chat Completions 客户端转换为 `thinking:{type:"enabled"}`；其他
  /// 协议将它视为未指定并省略对应推理字段。
  final String? reasoningEffort;
  final int? reasoningBudget;

  final String? sessionId;
  final String? sessionParentId;

  const AgentConfig({
    this.temperature = 0.7,
    this.enableTemperature = false,
    this.maxTokens = unknownModelMaxTokens,
    this.reasoningEffort,
    this.reasoningBudget,
    this.sessionId,
    this.sessionParentId,
  });

  /// 统一合并供应商开关与模型能力；null 表示请求省略温度。
  double? requestTemperature(String? modelId) => enableTemperature
      ? resolveRequestTemperature(
          modelId: modelId,
          temperature: temperature,
          reasoningEffort: reasoningEffort,
          reasoningBudget: reasoningBudget,
        )
      : null;

  AgentConfig copyWith({
    double? temperature,
    bool? enableTemperature,
    int? maxTokens,
    String? reasoningEffort,
    int? reasoningBudget,
    String? sessionId,
    String? sessionParentId,
  }) {
    return AgentConfig(
      temperature: temperature ?? this.temperature,
      enableTemperature: enableTemperature ?? this.enableTemperature,
      maxTokens: maxTokens ?? this.maxTokens,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      reasoningBudget: reasoningBudget ?? this.reasoningBudget,
      sessionId: sessionId ?? this.sessionId,
      sessionParentId: sessionParentId ?? this.sessionParentId,
    );
  }
}

/// 把会话选中的 reasoning effort wire 值规整为 [AgentConfig.reasoningEffort]。
///
/// `none` / `on` 是思考开关值（无 effort 分级）：
/// - 使用 `thinking` 字段的模型（如 Kimi）原样保留，由 client 转成
///   `thinking:{type:"disabled"|"enabled"}`；
/// - 其余模型映射为 null（不发送 reasoning_effort，走 provider 默认）。
String? resolveReasoningEffort(String? effort, {String? modelId}) {
  if (effort == null) {
    return null;
  }
  if (effort == 'none' || effort == 'on') {
    return useThinkingField(modelId) ? effort : null;
  }
  return effort;
}
