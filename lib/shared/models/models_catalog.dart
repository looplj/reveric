// 职责: 从本地模型目录查询上下文限制、推理参数与输入模态。
// 关联文件:
//   lib/shared/models/ai_provider.dart

/// 模型上下文与输出长度限制。
class ModelCatalogLimit {
  /// 上下文窗口 token 总数（输入 + 输出）。
  final int? context;

  /// 最大输出 token 数。
  final int? output;

  const ModelCatalogLimit({this.context, this.output});
}

/// 模型支持的输入模态。
class ModelCatalogModalities {
  /// null 表示未配置；空列表表示不支持任何输入模态。
  final List<String>? input;

  const ModelCatalogModalities({this.input});
}

/// 本地模型目录条目，记录该模型已知的推理参数与输入模态。
class ModelCatalogEntry {
  /// 基础 ID 之外的匹配项：精确别名或含一个 `*` 的通配模式。
  final List<String> matches;

  /// 支持的 reasoning effort 级别（low→high 顺序）；null 表示非推理模型。
  /// `['none']` 表示仅支持 toggle 开关（on/off），无 effort 分级。
  final List<String>? reasoningEfforts;

  /// 仅支持 budget_tokens 的模型，将 effort 级别映射到 token 预算值。
  /// key 为 effort 级别，value 为 budget_tokens 整数。
  /// 非 null 时表示该模型用 budget_tokens 模式而非原生 effort 模式。
  final Map<String, int>? budgetTokenMap;

  /// 该模型使用 `thinking: {type: "enabled"|"disabled"}` 参数来控制推理
  ///（如 Kimi/Moonshot），而非 OpenAI 的 `reasoning_effort` 或
  /// Anthropic 的 `budget_tokens`。
  final bool useThinkingField;

  /// 上下文/输出长度限制；null 表示未知（调用方自行取保守默认）。
  /// 数值按各 provider 官方文档的家族沿袭值维护。
  final ModelCatalogLimit? limit;

  final ModelCatalogModalities? modalities;

  const ModelCatalogEntry({
    this.matches = const [],
    this.reasoningEfforts,
    this.budgetTokenMap,
    this.useThinkingField = false,
    this.limit,
    this.modalities,
  });
}

/// 编译本地模型规则：精确匹配优先，通配规则按固定前缀、后缀长度降序。
class ModelCatalogMatcher {
  ModelCatalogMatcher(Map<String, ModelCatalogEntry> catalog) {
    final registered = <String>{};
    for (final MapEntry(key: id, value: entry) in catalog.entries) {
      for (final pattern in [id, ...entry.matches]) {
        if (!registered.add(pattern)) {
          throw ArgumentError('Duplicate catalog match: $pattern');
        }
        final star = pattern.indexOf('*');
        if (star < 0) {
          _exact[pattern] = entry;
          continue;
        }
        if (pattern.indexOf('*', star + 1) >= 0) {
          throw ArgumentError('Only one wildcard is allowed: $pattern');
        }
        _patterns.add((
          prefix: pattern.substring(0, star),
          suffix: pattern.substring(star + 1),
          entry: entry,
        ));
      }
    }
    _patterns.sort((a, b) {
      final prefixOrder = b.prefix.length.compareTo(a.prefix.length);
      return prefixOrder != 0
          ? prefixOrder
          : b.suffix.length.compareTo(a.suffix.length);
    });
  }

  final _exact = <String, ModelCatalogEntry>{};
  final _patterns =
      <({String prefix, String suffix, ModelCatalogEntry entry})>[];

  /// 目录 key 一律小写；渠道返回的 ID 大小写不一（如 `MiniMax-M3`），按小写匹配。
  ModelCatalogEntry? lookup(String modelId) {
    final full = modelId.toLowerCase();
    final id = full.split('/').last.split(':').first;
    final exact = _exact[full] ?? _exact[id];
    if (exact != null) {
      return exact;
    }
    for (final pattern in _patterns) {
      if (id.length >= pattern.prefix.length + pattern.suffix.length &&
          id.startsWith(pattern.prefix) &&
          id.endsWith(pattern.suffix)) {
        return pattern.entry;
      }
    }
    return null;
  }
}

// ── 长度常量：新增模型按整齐的 K/M 取值，统一引用常量 ──────────────
// 官方 1,048,576 按 1M、131,072 按 128K 记录。
const _8k = 8192;
const _32k = 32000;
const _64k = 64000;
const _100k = 100000;
const _128k = 128000;
const _192k = 192000;
const _200k = 200000;
const _256k = 256000;
const _384k = 384000;
const _500k = 500000;
const _560k = 560000;
const _1m = 1000000;

const _gptLargeContextLimit = ModelCatalogLimit(context: _560k, output: _128k);

/// 本地常见 AI 模型参数目录。
///
/// 数据来源：
///   - ThinkInAIXYZ/PublicProviderConf（github-copilot / anthropic / openai / gemini 等 provider）
///   - 各 provider 官方文档
///
/// 推理参数、长度限制和输入模态共用这份目录。
const Map<String, ModelCatalogEntry> modelsCatalog = {
  // ── OpenAI / GPT ──────────────────────────────────────────────────────────
  // GPT-5.6 与 GPT-6 及以上使用 560K 上下文；旧 GPT-5 使用 256K。
  // https://developers.openai.com/api/docs/models/gpt-6-astra
  // https://developers.openai.com/api/docs/guides/latest-model
  'gpt-6-astra': ModelCatalogEntry(
    matches: ['gpt-6-astra-*', 'gpt-6.1-sol', 'gpt-6.1-sol-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh', 'max'],
    limit: _gptLargeContextLimit,
  ),
  'gpt-5.4': ModelCatalogEntry(
    matches: ['gpt-5.4-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['none', 'low', 'medium', 'high', 'xhigh'],
    limit: ModelCatalogLimit(context: _256k, output: _128k),
  ),
  'gpt-5': ModelCatalogEntry(
    matches: ['gpt-5-*', 'gpt-5.*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh'],
    limit: ModelCatalogLimit(context: _256k, output: _128k),
  ),
  'o3': ModelCatalogEntry(
    matches: ['o3-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh'],
    limit: ModelCatalogLimit(context: _200k, output: _100k),
  ),
  'o4-mini': ModelCatalogEntry(
    matches: ['o4-mini-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh'],
    limit: ModelCatalogLimit(context: _200k, output: _100k),
  ),
  // Alias "gpt-5.6" → gpt-5.6-sol, https://platform.openai.com/docs/models
  'gpt-5.6': ModelCatalogEntry(
    matches: [
      'gpt-5.6-*',
      'gpt-6-sol',
      'gpt-6-sol-*',
      'gpt-6-luna',
      'gpt-6-luna-*',
    ],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
    limit: _gptLargeContextLimit,
  ),
  // ── Anthropic / Claude ────────────────────────────────────────────────────
  // https://platform.claude.com/docs/en/models/overview
  // https://platform.claude.com/docs/en/build-with-claude/effort
  'claude-opus-5': ModelCatalogEntry(
    matches: ['claude-opus-5-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh', 'max'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'claude-sonnet-5': ModelCatalogEntry(
    matches: ['claude-sonnet-5-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh', 'max'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'claude-fable-5': ModelCatalogEntry(
    matches: ['claude-fable-5-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh', 'max'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'claude-opus-4-8': ModelCatalogEntry(
    matches: ['claude-opus-4-8-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh', 'max'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'claude-opus-4-7': ModelCatalogEntry(
    matches: ['claude-opus-4-7-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh', 'max'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'claude-opus-4-6': ModelCatalogEntry(
    matches: ['claude-opus-4-6-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'max'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'claude-sonnet-4-6': ModelCatalogEntry(
    matches: ['claude-sonnet-4-6-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'max'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'claude-haiku-4-6': ModelCatalogEntry(
    matches: ['claude-haiku-4-6-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high'],
    budgetTokenMap: {'low': 2048, 'medium': 8192, 'high': 32000},
    limit: ModelCatalogLimit(context: _200k, output: _64k),
  ),
  'claude-sonnet-4-5': ModelCatalogEntry(
    matches: ['claude-sonnet-4-5-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high'],
    budgetTokenMap: {'low': 2048, 'medium': 8192, 'high': 32000},
    limit: ModelCatalogLimit(context: _200k, output: _64k),
  ),
  'claude-haiku-4-5': ModelCatalogEntry(
    matches: ['claude-haiku-4-5-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high'],
    budgetTokenMap: {'low': 2048, 'medium': 8192, 'high': 32000},
    limit: ModelCatalogLimit(context: _200k, output: _64k),
  ),
  'claude-opus-4-5': ModelCatalogEntry(
    matches: ['claude-opus-4-5-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _200k, output: _64k),
  ),

  // ── Gemini ────────────────────────────────────────────────────────────────
  // https://ai.google.dev/gemini-api/docs/models
  // https://aistudio.google.com/learn/gemini-4-carbon-developer-guide
  // 默认输出上限 64K；输入、思考和输出共用 1M 窗口。
  'gemini-4-carbon': ModelCatalogEntry(
    matches: ['gemini-4-carbon-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'gemini-4-argon': ModelCatalogEntry(
    matches: ['gemini-4-argon-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  // https://ai.google.dev/gemini-api/docs/thinking
  'gemini-3.8-flash': ModelCatalogEntry(
    matches: ['gemini-3.8-flash-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'gemini-3.5-flash': ModelCatalogEntry(
    matches: ['gemini-3.5-flash-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['minimal', 'low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'gemini-3.5-flash-lite': ModelCatalogEntry(
    matches: ['gemini-3.5-flash-lite-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['minimal', 'low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'gemini-3.1-pro-preview': ModelCatalogEntry(
    matches: ['gemini-3.1-pro-preview-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['low', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'gemini-3.1-pro': ModelCatalogEntry(
    matches: ['gemini-3.1-pro-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['low', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'gemini-3.1-flash-lite-preview': ModelCatalogEntry(
    matches: ['gemini-3.1-flash-lite-preview-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['minimal', 'low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'gemini-3-flash-preview': ModelCatalogEntry(
    matches: ['gemini-3-flash-preview-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['minimal', 'low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'gemini-flash-latest': ModelCatalogEntry(
    matches: ['gemini-flash-latest-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['minimal', 'low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'gemini-2.5-pro': ModelCatalogEntry(
    matches: ['gemini-2.5-pro-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'gemini-2.5-flash': ModelCatalogEntry(
    matches: ['gemini-2.5-flash-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'gemini-2.5-flash-lite': ModelCatalogEntry(
    matches: ['gemini-2.5-flash-lite-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['minimal', 'low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),

  // ── DeepSeek ──────────────────────────────────────────────────────────────
  // 型号能力按版本维护；渠道对旧 ID 的路由映射不改变 V4 的目录能力。
  // https://api-docs.deepseek.com/quick_start/pricing
  // https://api-docs.deepseek.com/guides/thinking_mode
  // https://api-docs.deepseek.com/guides/vision/
  'deepseek-flash': ModelCatalogEntry(
    matches: [
      'deepseek-flash-*',
      'deepseek-v4.1-flash',
      'deepseek-v4.1-flash-*',
    ],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['none', 'low', 'high', 'max'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _1m, output: _384k),
  ),
  'deepseek-v4-flash': ModelCatalogEntry(
    matches: ['deepseek-v4-flash-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['none', 'low', 'high', 'max'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _1m, output: _384k),
  ),
  'deepseek-v4-pro': ModelCatalogEntry(
    matches: ['deepseek-v4-pro-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['none', 'high', 'max'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _1m, output: _384k),
  ),
  'deepseek-v3-2': ModelCatalogEntry(
    matches: ['deepseek-v3-2-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['none'],
    limit: ModelCatalogLimit(context: _128k, output: _32k),
  ),
  'deepseek-reasoner': ModelCatalogEntry(
    matches: ['deepseek-reasoner-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: [],
    limit: ModelCatalogLimit(context: _128k, output: _64k),
  ),
  'deepseek-chat': ModelCatalogEntry(
    matches: ['deepseek-chat-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: [],
    limit: ModelCatalogLimit(context: _128k, output: _8k),
  ),

  // ── Qwen ──────────────────────────────────────────────────────────────────
  // https://help.aliyun.com/zh/model-studio/qwen3-8-max
  // https://help.aliyun.com/zh/model-studio/qwen3-8-flash
  // https://help.aliyun.com/zh/model-studio/anthropic-api-messages
  'qwen3.8-max': ModelCatalogEntry(
    matches: ['qwen3.8-max-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['low', 'medium', 'xhigh'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'qwen3.8-flash': ModelCatalogEntry(
    matches: ['qwen3.8-flash-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['low', 'medium', 'xhigh'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  // https://help.aliyun.com/zh/model-studio/qwen3-7-flash
  'qwen3.7-flash': ModelCatalogEntry(
    matches: ['qwen3.7-flash-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  // Qwen3.7+ (current gen): 1M context
  // Qwen3.6/3.5 (previous gen): plus/flash = 1M, max = 256K
  //   https://help.aliyun.com/zh/model-studio/text-generation-model/
  'qwen3.7-max': ModelCatalogEntry(
    matches: ['qwen3.7-max-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'qwen3.7-plus': ModelCatalogEntry(
    matches: ['qwen3.7-plus-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'qwen3.6-max': ModelCatalogEntry(
    matches: ['qwen3.6-max-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _256k, output: _64k),
  ),
  'qwen3.6-plus': ModelCatalogEntry(
    matches: ['qwen3.6-plus-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'qwen3.6-flash': ModelCatalogEntry(
    matches: ['qwen3.6-flash-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'qwen3.5-max': ModelCatalogEntry(
    matches: ['qwen3.5-max-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _256k, output: _64k),
  ),
  'qwen3.5-plus': ModelCatalogEntry(
    matches: ['qwen3.5-plus-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'qwen3.5-flash': ModelCatalogEntry(
    matches: ['qwen3.5-flash-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _64k),
  ),
  'qwen3.1-max': ModelCatalogEntry(
    matches: ['qwen3.1-max-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _256k, output: _64k),
  ),

  // ── Kimi / Moonshot ───────────────────────────────────────────────────────
  // K2 使用 thinking field toggle；K3 始终推理，使用标准 reasoning_effort。
  // https://www.kimi.ai/help/kimi-api/api-troubleshooting
  'kimi-k3': ModelCatalogEntry(
    matches: ['kimi-k3-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'high', 'max'],
    limit: ModelCatalogLimit(context: _1m, output: _1m),
  ),
  'kimi-k2.6': ModelCatalogEntry(
    matches: ['kimi-k2.6-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['none'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _256k, output: _32k),
  ),
  'kimi-k2.5': ModelCatalogEntry(
    matches: ['kimi-k2.5-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['none'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _256k, output: _32k),
  ),
  'kimi-k2.7-code': ModelCatalogEntry(
    matches: ['kimi-k2.7-code-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['none'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _256k, output: _32k),
  ),
  'kimi-k2-thinking': ModelCatalogEntry(
    matches: ['kimi-k2-thinking-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['none'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _256k, output: _32k),
  ),

  // ── Zhipu / GLM ──────────────────────────────────────────────────────────
  // https://docs.bigmodel.cn/cn/guide/models/text/glm-5.3
  // https://docs.bigmodel.cn/cn/guide/models/vlm/glm-5.3-flash
  // 5.3 系列始终思考，不提供关闭档位。
  'glm-5.3': ModelCatalogEntry(
    matches: ['glm-5.3-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['low', 'high', 'max'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'glm-5.3-flash': ModelCatalogEntry(
    matches: ['glm-5.3-flash-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['low', 'high', 'max'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'glm-5v-turbo': ModelCatalogEntry(
    matches: ['glm-5v-turbo-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['none'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'glm-5.1': ModelCatalogEntry(
    matches: ['glm-5.1-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['none'],
    limit: ModelCatalogLimit(context: _200k, output: _128k),
  ),
  'glm-5.2': ModelCatalogEntry(
    matches: ['glm-5.2-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['none', 'high', 'max'],
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'glm-4.7-flash': ModelCatalogEntry(
    matches: ['glm-4.7-flash-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _200k, output: _128k),
  ),
  'glm-4.7': ModelCatalogEntry(
    matches: ['glm-4.7-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _200k, output: _128k),
  ),

  // ── xAI / Grok ───────────────────────────────────────────────────────────
  // grok-4.20/4.3: 1M context; grok-4.5/4.6/4.7: 500K
  // https://docs.x.ai/docs/models
  'grok-4.7': ModelCatalogEntry(
    matches: ['grok-4.7-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh'],
    limit: ModelCatalogLimit(context: _500k, output: _64k),
  ),
  // https://docs.x.ai/developers/models/grok-4.6
  'grok-4.6': ModelCatalogEntry(
    matches: ['grok-4.6-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high', 'xhigh'],
    limit: ModelCatalogLimit(context: _500k),
  ),
  'grok-4.20-reasoning': ModelCatalogEntry(
    matches: ['grok-4.20-reasoning-*', 'grok-4.20-*-reasoning'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m),
  ),
  'grok-4.20-non-reasoning': ModelCatalogEntry(
    matches: ['grok-4.20-non-reasoning-*', 'grok-4.20-*-non-reasoning'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    limit: ModelCatalogLimit(context: _1m),
  ),
  'grok-4.3': ModelCatalogEntry(
    matches: ['grok-4.3-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m),
  ),
  'grok-4.5': ModelCatalogEntry(
    matches: ['grok-4.5-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _500k),
  ),

  // ── Doubao / Volcengine ───────────────────────────────────────────────────
  // https://docs.volcengine.com/docs/ark/model-list?lang=en
  // https://docs.volcengine.com/docs/ark/deep-thinking?lang=en
  // minimal 与 none 均关闭思考；统一提供 none，由 thinking.type 控制开关。
  // 目录只暴露模型支持的原生推理档位。
  'doubao-seed-evolving': ModelCatalogEntry(
    matches: ['doubao-seed-evolving-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['none', 'low', 'medium', 'high'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _1m, output: _256k),
  ),
  'doubao-seed-2-1-pro': ModelCatalogEntry(
    matches: [
      'doubao-seed-2-1-pro-*',
      'doubao-seed-2.1-pro',
      'doubao-seed-2.1-pro-*',
    ],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['none', 'low', 'medium', 'high'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _1m, output: _256k),
  ),
  'doubao-seed-2-1-lite': ModelCatalogEntry(
    matches: [
      'doubao-seed-2-1-lite-*',
      'doubao-seed-2.1-lite',
      'doubao-seed-2.1-lite-*',
    ],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['none', 'low', 'medium', 'high'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _1m, output: _256k),
  ),
  'doubao-seed-2-1-turbo': ModelCatalogEntry(
    matches: [
      'doubao-seed-2-1-turbo-*',
      'doubao-seed-2.1-turbo',
      'doubao-seed-2.1-turbo-*',
    ],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['none', 'low', 'medium', 'high'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _256k, output: _256k),
  ),
  'doubao-seed-2-0-pro': ModelCatalogEntry(
    matches: [
      'doubao-seed-2-0-pro-*',
      'doubao-seed-2.0-pro',
      'doubao-seed-2.0-pro-*',
    ],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['none', 'low', 'medium', 'high'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _256k, output: _128k),
  ),
  'doubao-seed-2-0-lite': ModelCatalogEntry(
    matches: [
      'doubao-seed-2-0-lite-*',
      'doubao-seed-2.0-lite',
      'doubao-seed-2.0-lite-*',
    ],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['none', 'low', 'medium', 'high'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _256k, output: _128k),
  ),
  'doubao-seed-2-0-mini': ModelCatalogEntry(
    matches: [
      'doubao-seed-2-0-mini-*',
      'doubao-seed-2.0-mini',
      'doubao-seed-2.0-mini-*',
    ],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['none', 'low', 'medium', 'high'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _256k, output: _128k),
  ),
  'doubao-seed-2-0-code': ModelCatalogEntry(
    matches: [
      'doubao-seed-2-0-code-*',
      'doubao-seed-2.0-code',
      'doubao-seed-2.0-code-*',
    ],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['none', 'low', 'medium', 'high'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _256k, output: _128k),
  ),

  // ── MiniMax ──────────────────────────────────────────────────────────────
  // MiniMax-M3/M2.7/M2.5: 192K context; M2.1: 200K
  // https://help.aliyun.com/zh/model-studio/text-generation-model/
  'minimax-m3': ModelCatalogEntry(
    matches: ['minimax-m3-*'],
    modalities: ModelCatalogModalities(input: ['text', 'image', 'video']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _192k, output: _32k),
  ),
  'minimax-m2.7': ModelCatalogEntry(
    matches: ['minimax-m2.7-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _192k, output: _32k),
  ),
  'minimax-m2.5': ModelCatalogEntry(
    matches: ['minimax-m2.5-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _192k, output: _32k),
  ),
  'minimax-m2.1': ModelCatalogEntry(
    matches: ['minimax-m2.1-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _200k, output: _32k),
  ),

  // ── Mimo ──────────────────────────────────────────────────────────────────
  // https://mimo.mi.com/models/en-US/mimo-v2.6-pro
  // https://mimo.mi.com/models/en-US/mimo-v2.6-flash
  // https://mimo.mi.com/docs/en-US/api/chat/openai-api
  // V2.6 仅支持 thinking.type 开关，不提供 reasoning_effort 分级。
  'mimo-v2.6-pro': ModelCatalogEntry(
    matches: ['mimo-v2.6-pro-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['none'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  'mimo-v2.6-flash': ModelCatalogEntry(
    matches: ['mimo-v2.6-flash-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['none'],
    useThinkingField: true,
    limit: ModelCatalogLimit(context: _1m, output: _128k),
  ),
  // V2.5: 1M context (per Alibaba Cloud Model Studio doc), output 保守取 32K
  'mimo-v2.5': ModelCatalogEntry(
    matches: ['mimo-v2.5-*'],
    modalities: ModelCatalogModalities(
      input: ['text', 'image', 'audio', 'video'],
    ),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _32k),
  ),
  'mimo-v2.5-pro': ModelCatalogEntry(
    matches: ['mimo-v2.5-pro-*'],
    modalities: ModelCatalogModalities(input: ['text']),
    reasoningEfforts: ['low', 'medium', 'high'],
    limit: ModelCatalogLimit(context: _1m, output: _32k),
  ),
  // 免费模型别名的共用限制，精确别名优先于系列通配规则。
  'deepseek-v4-flash-free': ModelCatalogEntry(
    matches: [
      'deepseek-v4-flash-free-*',
      'glm-5.3-flash-free',
      'glm-5.3-flash-free-*',
      'mimo-v2.5-free',
      'mimo-v2.5-free-*',
      'deepseek-v4.1-flash-free',
      'deepseek-v4.1-flash-free-*',
    ],
    modalities: ModelCatalogModalities(input: ['text']),
    limit: ModelCatalogLimit(context: _200k),
  ),
};

/// 从 [modelsCatalog] 中查找模型 [modelId] 的 reasoningEfforts。
/// 本地精确匹配优先，再匹配条目显式声明的通配规则。
List<String>? lookupCatalogReasoningEfforts(String modelId) {
  final entry = _catalogEntry(modelId);
  return entry?.reasoningEfforts;
}

/// 从本地目录解析上下文/输出限制，未知模型返回 null。
ModelCatalogLimit? lookupCatalogLimit(String modelId) =>
    _catalogEntry(modelId)?.limit ?? _futureGptLimit(modelId);

final _gptMajorVersion = RegExp(r'^gpt-(\d+)(?:[.-]|$)');

/// 未收录的 GPT-6 及后续主版本沿用统一长度默认值，不推断推理档位。
ModelCatalogLimit? _futureGptLimit(String modelId) {
  final id = modelId.split('/').last.split(':').first;
  final match = _gptMajorVersion.firstMatch(id);
  final major = match == null ? null : int.tryParse(match.group(1)!);
  return major != null && major >= 6 ? _gptLargeContextLimit : null;
}

/// 会话/UI 层使用的 effort 档位归一化。
///
/// `['none']`（本地目录 声明「仅支持开关，无 effort 分级」）
/// 归一化为 `['none', 'on']`，让用户可以开启推理；`'on'` 表示「开启推理但
/// 不指定级别」，wire 层不会作为 reasoning_effort 级别发送。
///
/// 无论来源（本地目录），最终都按强度升序排列，避免
/// 目录声明顺序导致 UI 出现「低」排在「高」后面。
List<String>? normalizeReasoningEfforts(List<String>? efforts) {
  if (efforts == null) {
    return null;
  }
  if (efforts.length == 1 && efforts.single == 'none') {
    return const ['none', 'on'];
  }
  if (efforts.length <= 1) {
    return efforts;
  }
  return List<String>.of(
    efforts,
  )..sort((a, b) => _reasoningEffortRank(a).compareTo(_reasoningEffortRank(b)));
}

/// 已知 effort wire 值的强度序（越小越弱）。未知值排在末尾。
int _reasoningEffortRank(String effort) {
  return switch (effort) {
    'none' => 0,
    'on' => 1,
    'minimal' => 2,
    'low' => 3,
    'medium' => 4,
    'high' => 5,
    'xhigh' => 6,
    'max' => 7,
    _ => 100,
  };
}

final _localCatalog = ModelCatalogMatcher(modelsCatalog);

/// 本地精确匹配优先于通配规则。
ModelCatalogEntry? _catalogEntry(String modelId) =>
    _localCatalog.lookup(modelId);

/// 若模型使用 budget_tokens 模式，将 effort 级别映射到 token 预算值。
/// 返回 null 表示该模型无需 budget_tokens 映射（直接用原生 effort 模式）。
int? resolveReasoningBudget(String? modelId, String? effort) {
  if (modelId == null || effort == null || effort == 'none') return null;
  final entry = _catalogEntry(modelId);
  return entry?.budgetTokenMap?[effort];
}

/// 判断模型是否使用 `thinking` field toggle（如 Kimi/Moonshot）。
/// 返回 true 表示 API 调用应发送 `thinking: {type: "enabled"|"disabled"}`。
bool useThinkingField(String? modelId) {
  if (modelId == null) return false;
  final entry = _catalogEntry(modelId);
  return entry?.useThinkingField ?? false;
}

final _imageInputSeriesPattern = RegExp(
  r'^(?:(?:claude-)?(sonnet|opus|fable)-|(gpt|gemini)-|(kimi)-k?)(\d+)(?:[.-]|$)',
);

/// 明确配置优先；缺省时仅指定系列按主版本兜底，其余模型不支持图片输入。
bool lookupCatalogImageInput(String modelId) {
  final normalized = modelId.split('/').last.split(':').first;
  final input = _localCatalog.lookup(modelId)?.modalities?.input;
  if (input != null) {
    return input.contains('image');
  }

  final match = _imageInputSeriesPattern.firstMatch(normalized.toLowerCase());
  if (match == null) {
    return false;
  }
  final minimumVersion = match.group(1) != null || match.group(2) == 'gpt'
      ? 5
      : 3;
  final majorVersion = int.tryParse(match.group(4)!);
  return majorVersion != null && majorVersion >= minimumVersion;
}
