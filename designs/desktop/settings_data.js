// Mock data for the faithfully-reproduced AI providers + usage settings pages.
// Mirrors lib/shared/widgets/settings/{ai_providers_section,provider_config_panel,usage_view}.dart.

// ── AI providers ────────────────────────────────────────────────────────────
// isValid = enabled && hasApiKey && hasBaseUrl && hasModels (drives the dot/badge).
// 全部是自带 key 的外部供应商。
const PROVIDERS = [
  {
    id: "openai", name: "OpenAI", type: "OpenAI", enabled: true, valid: true,
    apiKey: "sk-proj-••••••••••••••••••••3a7F", baseUrl: "https://api.openai.com/v1", fixedBaseUrl: false,
    models: ["gpt-4.1", "gpt-4o", "o3", "gpt-4o-mini"],
    temperature: 0.7, maxTokens: "64k", reasoning: "默认",
  },
  {
    id: "anthropic", name: "Anthropic", type: "Anthropic", enabled: true, valid: true,
    apiKey: "sk-ant-••••••••••••••••••••9b2C", baseUrl: "https://api.anthropic.com", fixedBaseUrl: true,
    models: ["claude-opus-4-1", "claude-sonnet-4-5", "claude-haiku-4-5"],
    temperature: 1.0, maxTokens: "64k", reasoning: "高",
  },
  {
    id: "google", name: "Google Gemini", type: "Gemini", enabled: false, valid: false,
    apiKey: "", baseUrl: "https://generativelanguage.googleapis.com/v1beta", fixedBaseUrl: false,
    models: [], temperature: 0.7, maxTokens: "32k", reasoning: "默认",
  },
  {
    id: "ollama", name: "本地 · Ollama", type: "OpenAI 兼容", custom: true, enabled: true, valid: true,
    apiKey: "", baseUrl: "http://localhost:11434/v1", fixedBaseUrl: false,
    models: ["qwen2.5:32b", "llama3.1:70b"],
    temperature: 0.8, maxTokens: "32k", reasoning: "默认",
  },
];

// ── 自定义提供商可选类型 ────────────────────────────────────────────────────
// 对齐 lib/shared/models/ai_provider.dart 的 aiProviderTypeConfigs：
// kinds = supportedModelKinds（embedding 不在选择器里展示），fixed = fixedBaseUrl。
// baseUrl 是新建草稿时预填的地址（固定地址类型即该地址，只读）。
const PROVIDER_KIND_LABELS = { chat: "对话", image: "图片", video: "视频", audio: "音频" };
const PROVIDER_TYPES = [
  { key: "openai_compatible", name: "OpenAI 兼容", kinds: ["chat", "image"], baseUrl: "", note: "大多数中转站与自部署服务" },
  { key: "anthropic", name: "Anthropic", kinds: ["chat"], baseUrl: "" },
  { key: "gemini", name: "Gemini", kinds: ["chat", "image"], baseUrl: "" },
  { key: "openai", name: "OpenAI", kinds: ["chat", "image"], baseUrl: "" },
  { key: "minimax", name: "MiniMax", kinds: ["video", "audio"], baseUrl: "", note: "兼容 MiniMax 格式的视频接口（如 H3）" },
  { key: "doubao", name: "Doubao", kinds: ["chat", "image", "video"], baseUrl: "", note: "兼容方舟格式的视频接口（如 Seedance）" },
  { key: "qwen", name: "Qwen", kinds: ["chat", "image", "video", "audio"], baseUrl: "https://maas.qianwenaiapi.com/compatible-mode/v1" },
  { key: "agnes", name: "Agnes", kinds: ["image", "video"], baseUrl: "https://apihub.agnes-ai.com/v1" },
  { key: "xai", name: "xAI", kinds: ["chat", "image"], baseUrl: "" },
  { key: "deepseek", name: "DeepSeek", kinds: ["chat"], baseUrl: "" },
  { key: "moonshot", name: "Moonshot", kinds: ["chat"], baseUrl: "" },
  { key: "zhipu", name: "Zhipu", kinds: ["chat"], baseUrl: "" },
  { key: "openrouter", name: "OpenRouter", kinds: ["chat", "image", "video", "audio"], fixed: true, baseUrl: "https://openrouter.ai/api/v1" },
  { key: "api88", name: "88API", kinds: ["chat", "image", "video", "audio"], fixed: true, baseUrl: "https://api.88api.ai/v1" },
  { key: "atlascloud", name: "AtlasCloud", kinds: ["chat", "image", "video", "audio"], fixed: true, baseUrl: "https://api.atlascloud.ai/v1" },
  { key: "volcengine", name: "火山引擎", kinds: ["chat", "image", "video", "audio"], fixed: true, baseUrl: "https://ark.cn-beijing.volces.com/api/v3" },
  { key: "metaso", name: "秘塔科技", kinds: ["video"], fixed: true, baseUrl: "https://metaso.cn/api/minimax" },
  { key: "codex", name: "Codex", kinds: ["chat", "image"], fixed: true, desktopOnly: true, baseUrl: "https://chatgpt.com/backend-api/codex" },
];

// ── Usage ───────────────────────────────────────────────────────────────────
// 口径全部是词元（token）。
const USAGE = {
  // Token consumption summaries. b = {input, cacheRead, cacheWrite, output, reasoning}.
  today: { total: "128K", requests: 37, b: { input: "42K", cacheRead: "61K", cacheWrite: "8K", output: "17K", reasoning: "0" } },
  month: { total: "2.4M", trend: "+18.0%", trendUp: true, avgPerDay: "82K", b: { input: "820K", cacheRead: "1.1M", cacheWrite: "180K", output: "310K", reasoning: "12K" } },
  // 按功能分布（本月）。k = 千词元，合计 ≈ 2.4M。
  // 分类只按「用户发起的功能」切。子代理、上下文压缩、斜杠命令都不是用户发起
  // 的动作，各自并回触发它们的功能（子代理 795K、压缩 305K、斜杠 43K 已并入
  // 下列各项）；主线与子代理怎么分，是「会话」tab 的事。
  sources: [
    { key: "chat", name: "聊天", icon: "chat-circle-text", k: 2250 },
    { key: "roleplay", name: "角色扮演", icon: "mask-happy", k: 110 },
    { key: "monologue", name: "独白", icon: "quotes", k: 23 },
    { key: "theater", name: "剧场", icon: "users-three", k: 9 },
    { key: "council", name: "议会", icon: "users", k: 4 },
  ],
  // 「会话」tab 的列表（本月，按用量降序）。点击下钻到 SESSION_USAGE[id]。
  topSessions: [
    { id: "s1", title: "第 03 章 · 三舱客", mode: "聊天", model: "claude-opus-4-1", tokens: "428.6K", lastUsed: "06-28 11:42" },
    { id: "s2", title: "凤瑶 · 角色对话", mode: "角色扮演", model: "claude-sonnet-4-5", tokens: "312.8K", lastUsed: "06-28 09:47" },
    { id: "s3", title: "全书大纲重构", mode: "聊天", model: "claude-opus-4-1", tokens: "268.0K", lastUsed: "06-28 09:12" },
    { id: "s4", title: "卷二 · 伏笔回收核对", mode: "聊天", model: "gpt-4.1", tokens: "241.0K", lastUsed: "06-27 22:03" },
    { id: "s5", title: "世界观设定校对", mode: "聊天", model: "claude-opus-4-1", tokens: "187.0K", lastUsed: "06-27 21:36" },
  ],
  // 全局明细只回答「什么时候、用哪个模型、花了多少」；归到哪个会话、哪个
  // 子代理是「会话」tab 的事，不在这张表里重复一遍。
  records: [
    { time: "2026-06-28 11:42", provider: "Anthropic", model: "claude-opus-4-1", input: "8.2K", output: "1.4K" },
    { time: "2026-06-28 11:18", provider: "OpenAI", model: "gpt-4.1", input: "3.1K", output: "920" },
    { time: "2026-06-28 10:55", provider: "Anthropic", model: "claude-sonnet-4", input: "12.4K", output: "2.1K" },
    { time: "2026-06-28 10:31", provider: "Anthropic", model: "claude-sonnet-4-5", input: "5.6K", output: "1.1K" },
    { time: "2026-06-28 09:47", provider: "本地 · Ollama", model: "qwen2.5:32b", input: "7.0K", output: "1.8K" },
    { time: "2026-06-28 09:12", provider: "OpenAI", model: "o3", input: "2.2K", output: "3.4K" },
    { time: "2026-06-27 22:03", provider: "OpenAI", model: "gpt-4.1", input: "9.8K", output: "1.6K" },
    { time: "2026-06-27 21:36", provider: "Anthropic", model: "claude-opus-4-1", input: "6.4K", output: "1.2K" },
  ],
  page: { current: 1, total: 4 },
};

// 30 days of stacked token bars (deterministic, no RNG so screenshots are stable).
// 两套着色口径共用同一天的总量：type = 词元类型，source = 功能归属。
const USAGE_DAILY = Array.from({ length: 30 }, (_, i) => {
  const w = (i * 37) % 100 / 100;       // stable pseudo-wave
  const s = ((i * 53) % 100) / 100;
  const base = 20 + w * 120;
  const input = Math.round(base * (0.30 + s * 0.10));
  const cacheRead = Math.round(base * (0.38 - s * 0.08));
  const cacheWrite = Math.round(base * 0.10);
  const output = Math.round(base * (0.18 + s * 0.05));
  const total = input + cacheRead + cacheWrite + output;
  const chat = Math.round(total * (0.90 + s * 0.03));
  const roleplay = Math.round(total * 0.046);
  return {
    input, cacheRead, cacheWrite, output,
    // 功能归属拆分（比例贴合上面的 USAGE.sources；子代理与压缩已并入各自来源）。
    chat, roleplay,
    other: Math.max(0, total - chat - roleplay),
  };
});

// ── 活动热力图 ──────────────────────────────────────────────────────────────
// 对齐 usage_view.dart 的 _UsageHeatmap / _ActivityGrid：
//   · 桌面 26 周 × 7 天（窄屏 13 周），行 = 星期（周日在第一行），列 = 周
//   · 网格右端对齐「今天所在这一周的周六」，本周之后的格子是 future
//   · 4 档着色：ceil(tokens / max * 4) → accent 混入 25 / 50 / 75 / 100%
// 固定 today 以保证截图稳定（与其余 mock 数据同一天）。
const ACTIVITY_WEEKS = 26;
const USAGE_ACTIVITY = (() => {
  const today = new Date(2026, 5, 28);                       // 2026-06-28
  const gridEnd = new Date(today);
  gridEnd.setDate(gridEnd.getDate() + (6 - today.getDay())); // 本周周六
  const cells = [];
  for (let i = ACTIVITY_WEEKS * 7 - 1; i >= 0; i--) {
    const date = new Date(gridEnd);
    date.setDate(date.getDate() - i);
    const n = ACTIVITY_WEEKS * 7 - 1 - i;                    // 0 = 最早一天
    const dow = date.getDay();
    // 稳定伪随机：周末走低，每 11 天一个休息日。
    const wave = ((n * 41) % 100) / 100;
    const lull = n % 11 === 3 ? 0 : 1;
    const weekend = dow === 0 || dow === 6 ? 0.35 : 1;
    const tokens = Math.round(18000 + wave * 140000) * lull * weekend;
    cells.push({
      date: `${date.getMonth() + 1} 月 ${date.getDate()} 日`,
      tokens: Math.round(tokens),
      requests: Math.round(tokens / 3600),
      future: date > today,
    });
  }
  return cells;                                              // index = week * 7 + dow
})();

// ── 会话用量（设置 → 用量 →「会话」tab 的下钻详情）───────────────────────
// 一条 JOIN 即可得到：ai_usages.session_id = 本会话 或
// ai_chat_sessions.parent_id = 本会话（两张表同库）。
// 自动压缩的开销静默计入触发它的主线或子代理，UI 上不作为条目出现——它不是
// 用户发起的动作，单列只会制造一个需要解释的名词。
const SESSION_USAGE = {
  s1: {
    id: "s1", title: "第 03 章 · 三舱客", mode: "聊天",
    model: "claude-opus-4-1", lastUsed: "06-28 11:42",
    total: "428.6K", requests: 47,
    types: { input: 44.5, cacheRead: 289.4, cacheWrite: 78.3, output: 16.4 },  // 单位 K
    context: { used: "87.3K", limit: "200K", pct: 44 },
    tree: [
      {
        key: "main", name: "主线对话", sub: "claude-opus-4-1 · 8 次请求",
        tokens: "258.8K", pct: "60%", color: "var(--accent)",
      },
      {
        key: "subagent", name: "子代理", sub: "3 个 · 5 次运行",
        tokens: "169.8K", pct: "40%", color: "var(--accent-amber)",
        kids: [
          {
            name: "世界观考据", sub: "claude-sonnet-4-5 · 3 次运行", tokens: "106.2K", pct: "25%",
            runs: [
              { time: "11:42", label: "核对雨港旧制", tokens: "45.8K", ok: true },
              { time: "11:07", label: "核对三舱客船制", tokens: "37.0K", ok: true },
              { time: "10:51", label: "核对吴县地理", tokens: "23.4K", ok: true },
            ],
          },
          {
            name: "伏笔检查", sub: "claude-sonnet-4-5 · 1 次运行", tokens: "43.1K", pct: "10%",
            runs: [{ time: "10:31", label: "木匣银线一致性", tokens: "43.1K", ok: true }],
          },
          {
            name: "人物声音", sub: "qwen2.5:32b · 1 次运行", tokens: "20.5K", pct: "5%",
            runs: [{ time: "10:04", label: "老沈口音校验（超时）", tokens: "20.5K", ok: false }],
          },
        ],
      },
    ],
    records: [
      { time: "2026-06-28 11:42", provider: "Anthropic", model: "claude-sonnet-4-5", input: "8.2K", output: "1.4K" },
      { time: "2026-06-28 11:18", provider: "Anthropic", model: "claude-opus-4-1", input: "3.1K", output: "920" },
      { time: "2026-06-28 10:55", provider: "Anthropic", model: "claude-opus-4-1", input: "12.4K", output: "2.1K" },
      { time: "2026-06-28 10:31", provider: "Anthropic", model: "claude-sonnet-4-5", input: "5.6K", output: "1.1K" },
      { time: "2026-06-28 10:04", provider: "本地 · Ollama", model: "qwen2.5:32b", input: "6.8K", output: "1.3K" },
    ],
  },
  s2: {
    id: "s2", title: "凤瑶 · 角色对话", mode: "角色扮演",
    model: "claude-sonnet-4-5", lastUsed: "06-28 09:47",
    total: "312.8K", requests: 63,
    types: { input: 38.2, cacheRead: 214.6, cacheWrite: 46.7, output: 13.3 },
    context: { used: "62.4K", limit: "128K", pct: 49 },
    tree: [
      {
        key: "roleplay", name: "角色扮演主线", sub: "claude-sonnet-4-5 · 63 次请求",
        tokens: "312.8K", pct: "100%", color: "var(--warning-text)",
      },
    ],
    records: [
      { time: "2026-06-28 09:47", provider: "本地 · Ollama", model: "qwen2.5:32b", input: "7.0K", output: "1.8K" },
      { time: "2026-06-28 09:31", provider: "Anthropic", model: "claude-sonnet-4-5", input: "5.2K", output: "1.4K" },
      { time: "2026-06-28 09:08", provider: "Anthropic", model: "claude-sonnet-4-5", input: "4.9K", output: "1.1K" },
    ],
  },
  s3: {
    id: "s3", title: "全书大纲重构", mode: "聊天",
    model: "claude-opus-4-1", lastUsed: "06-28 09:12",
    total: "268.0K", requests: 31,
    types: { input: 31.4, cacheRead: 178.2, cacheWrite: 47.6, output: 10.8 },
    context: { used: "96.2K", limit: "200K", pct: 48 },
    tree: [
      {
        key: "subagent", name: "子代理", sub: "2 个 · 7 次运行",
        tokens: "136.8K", pct: "51%", color: "var(--accent-amber)",
        kids: [
          {
            name: "情节顾问", sub: "claude-opus-4-1 · 5 次运行", tokens: "89.3K", pct: "33%",
            runs: [
              { time: "09:12", label: "卷二节奏评估", tokens: "24.1K", ok: true },
              { time: "08:56", label: "卷一悬念分布", tokens: "21.7K", ok: true },
              { time: "08:40", label: "主线支线配比", tokens: "18.2K", ok: true },
              { time: "08:22", label: "章节切分建议", tokens: "14.6K", ok: true },
              { time: "08:05", label: "开篇钩子核对", tokens: "10.7K", ok: true },
            ],
          },
          {
            name: "伏笔检查", sub: "claude-sonnet-4-5 · 2 次运行", tokens: "47.5K", pct: "18%",
            runs: [
              { time: "08:48", label: "全书伏笔清单", tokens: "29.3K", ok: true },
              { time: "08:14", label: "回收时机核对", tokens: "18.2K", ok: true },
            ],
          },
        ],
      },
      {
        key: "main", name: "主线对话", sub: "claude-opus-4-1 · 12 次请求",
        tokens: "131.2K", pct: "49%", color: "var(--accent)",
      },
    ],
    records: [
      { time: "2026-06-28 09:12", provider: "OpenAI", model: "o3", input: "2.2K", output: "3.4K" },
      { time: "2026-06-28 08:56", provider: "Anthropic", model: "claude-opus-4-1", input: "9.4K", output: "1.7K" },
      { time: "2026-06-28 08:40", provider: "Anthropic", model: "claude-opus-4-1", input: "7.8K", output: "1.2K" },
    ],
  },
  s4: {
    id: "s4", title: "卷二 · 伏笔回收核对", mode: "聊天",
    model: "gpt-4.1", lastUsed: "06-27 22:03",
    total: "241.0K", requests: 26,
    types: { input: 28.9, cacheRead: 160.4, cacheWrite: 41.2, output: 10.5 },
    context: { used: "74.5K", limit: "128K", pct: 58 },
    tree: [
      {
        key: "main", name: "主线对话", sub: "gpt-4.1 · 26 次请求",
        tokens: "241.0K", pct: "100%", color: "var(--accent)",
      },
    ],
    records: [
      { time: "2026-06-27 22:03", provider: "OpenAI", model: "gpt-4.1", input: "9.8K", output: "1.6K" },
      { time: "2026-06-27 21:51", provider: "OpenAI", model: "gpt-4.1", input: "11.2K", output: "2.0K" },
    ],
  },
  s5: {
    id: "s5", title: "世界观设定校对", mode: "聊天",
    model: "claude-opus-4-1", lastUsed: "06-27 21:36",
    total: "187.0K", requests: 18,
    types: { input: 22.4, cacheRead: 124.1, cacheWrite: 32.8, output: 7.7 },
    context: { used: "51.8K", limit: "200K", pct: 26 },
    tree: [
      {
        key: "main", name: "主线对话", sub: "claude-opus-4-1 · 9 次请求",
        tokens: "158.5K", pct: "85%", color: "var(--accent)",
      },
      {
        key: "subagent", name: "子代理", sub: "1 个 · 2 次运行",
        tokens: "28.5K", pct: "15%", color: "var(--accent-amber)",
        kids: [
          {
            name: "世界观考据", sub: "claude-sonnet-4-5 · 2 次运行", tokens: "28.5K", pct: "15%",
            runs: [
              { time: "21:36", label: "潮汐与航期一致性", tokens: "16.4K", ok: true },
              { time: "21:12", label: "官制称谓核对", tokens: "12.1K", ok: true },
            ],
          },
        ],
      },
    ],
    records: [
      { time: "2026-06-27 21:36", provider: "Anthropic", model: "claude-opus-4-1", input: "6.4K", output: "1.2K" },
      { time: "2026-06-27 21:12", provider: "Anthropic", model: "claude-sonnet-4-5", input: "4.1K", output: "830" },
    ],
  },
};

// 聊天面板 header chip 指向的当前会话。
const CURRENT_SESSION_ID = "s1";

Object.assign(window, {
  PROVIDERS, PROVIDER_TYPES, PROVIDER_KIND_LABELS, USAGE, USAGE_DAILY, USAGE_ACTIVITY, ACTIVITY_WEEKS,
  SESSION_USAGE, CURRENT_SESSION_ID,
});
