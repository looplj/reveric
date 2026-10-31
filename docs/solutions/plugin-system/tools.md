# 工具扩展点

> 本篇定义插件工具的注册、命名、可用性、卡片展示，以及 Agent 工具限制的改造。插件上下文接口见[架构](architecture.md#插件上下文-api)。任务进度只在[实施任务](README.md#实施任务)维护。

## 注册

插件在 `apply` 中调用 `setup.tools.register` 注册工具，字段见 [`plugins/sdk/index.d.ts`](../../../plugins/sdk/index.d.ts) 的 `ToolRegistration`。处理函数签名为 `handler(input, context: ToolContext)`，上下文内容见[插件上下文 API](architecture.md#插件上下文-api)。Host 在激活时校验：

- 工具名匹配 `^[A-Za-z][A-Za-z0-9_]{0,63}$`。
- `description` 非空。
- `inputSchema` 是 `type` 为 `object` 的 JSON Schema。
- `display.result` 取值合法；`display.summaryArg` 是 `inputSchema.properties` 中的字段。
- 同一插件内工具名不重复。

任一项不通过，激活失败，失败原因显示在设置页。

## 工具名与覆盖

模型看到的工具名就是插件注册的名字，不加插件前缀。冲突按以下规则处理：

- 插件不能注册 Host 自身的工具名，如 Read、Write、Run、SpawnAgent、Codemode，也不能使用 MCP 工具的 `mcp__` 前缀。
- 第三方插件可以覆盖内置插件的同名工具，例如第三方搜索插件注册 `WebSearch` 替换内置实现。覆盖期间内置工具不向模型提供；第三方插件停用后，内置工具恢复可用。
- 两个第三方插件注册同名工具时，后启用的插件激活失败并显示冲突原因，不静默覆盖已有工具。应用启动时各插件可以并行激活，但冲突按 `plugin_registry.created_at` 的先后裁决，与激活完成的先后无关。
- 设置页显示每个工具当前由哪个插件提供。

## 可用性

模型可调用的工具是插件可用状态与宿主支持范围的交集：

- 每次模型请求时，Host 从注册表读取当前生效的插件工具，与 Host 工具一起组成工具列表；工具定义随注册表缓存，状态变化时失效。
- 实际执行入口再次检查插件状态，避免旧工具名或已发出的旧请求绕过关闭状态；不可用时返回 `plugin_unavailable`。
- 插件工具对主聊天、子 Agent 和各会话模式都可用，作为直接工具出现在工具列表中。现有工具目录（`tool_catalog.dart`）只服务 MCP 与 codemode 的发现，不加入插件工具。
- codemode 的工具集合不变，不包含插件工具。
- 用户开启插件时立即激活；应用启动时立即激活所有已开启的插件。模型请求只使用已激活成功的插件工具，不等待正在激活的插件。

### Agent 接入

Agent 的 `allowedTools` 在创建 Agent 时计算一次，之后不随插件开关变化，所以插件工具不进入 `allowedTools`，改用与 MCP 相同的请求级调度器接入：

- 新增 `PluginAgentToolDispatcher`，实现 `AgentToolDispatcher` 和 `AgentRequestToolDispatcher`，包在现有调度器（包括 `McpAgentToolDispatcher`）外层。
- `prepareRequest`：先调用内层的 `prepareRequest`（内层也是请求级调度器时），再从注册表取当前生效的插件工具快照；M3 同时准备当前请求 scope 下的 Prompt 片段。Agent 每次模型请求尝试前调用它，准备期间停用的插件必须在提交请求前被排除。
- `allToolNames`：内层工具名加插件工具快照中的名称。`Agent.fork` 等在没有 `allowedTools` 时会用到它。
- `toolDefsForNames`：先从传入名称中去掉插件工具名，交给内层筛出 Host 工具，再追加一次插件工具快照，避免重复。`allowedTools` 因此只约束 Host 工具，与禁用名单的语义一致。
- `executeTool`：插件工具名交给 `tool_bridge` 执行，先检查可用性；其他工具名交给内层。
- `callMetadata`：插件工具返回 `tool_source = plugin`、插件 ID、名称和 `display`；其他工具交给内层。`isExternalCall` 对插件工具返回 false，取消等行为按 Host 工具处理。
- M1 的 `requestSystemPrompt` 透传内层；M3 在保留内层提示的基础上加入请求级插件 Prompt 快照，见[请求级 Prompt 提供方](prompts-and-tasks.md#请求级-prompt-提供方)。不改变工具的静态 description 或 Schema。

所有创建对话 Agent 的位置都用它包装调度器：主聊天（`chat_turn_runner.dart`）、无界面会话（`headless_session_turn.dart`）、子 Agent（`spawn_agent_handler.dart`）、council（`agent_council_orchestrator.dart`）、monologue、theater、roleplay 三个 orchestrator。上下文压缩用的摘要 Agent 不需要插件工具，不包装。

开关切换会改变下一次模型请求的工具列表，导致该会话的提示词缓存失效，下一轮请求的耗时和费用会上升。这是预期代价，不视为性能退化，也不为保住缓存而在关闭后继续向模型提供工具定义。

现有工具审批按动作控制（图片、视频、音频生成和 `files.read`、`files.remove`），不按工具名控制。插件工具不新增按工具审批；插件调用的 Host API 若对应上述已有动作，沿用同一审批。

## 工具卡片

插件工具调用在聊天中同样显示为工具卡片。卡片分两个阶段：

| 阶段 | 卡片内容 |
| --- | --- |
| M1 | 通用插件卡片：按插件注册时声明的 `display` 渲染标题、参数摘要和结果 |
| M3 | `display.view: {protocol: "reveric-ui-v1", source: "views/result.json"}` 指向只读 A2UI 描述，复用既有 A2UI 组件目录；不为卡片创建 TSX 运行时，见[自定义工具卡片](views.md#自定义工具卡片)；未提供时仍用通用卡片 |

M1 的通用卡片沿用现有 Web 工具卡片的布局，不借插件化改变 UI：

- 标题行：`display.title`（`PluginText`，按界面语言选择），省略时显示工具名；`display.summaryArg` 对应的参数值跟在标题后。
- 参数标签：显示 `display.summaryArg` 对应的参数值，与现有卡片显示查询词或 URL 的方式一致。
- 预览块：由 `display.result` 决定，取结果对象顶层中名为 `display.resultPath` 的字段（只是字段名，不是嵌套路径），最多 8 行：
  - `items`：数组，取前 4 项，每项显示 `title`（缺失时用 `url`）和可选的 `snippet`，与现有 WebSearch 预览一致。
  - `text`：字符串，显示开头部分，与现有 WebFetch 预览一致。
  - `json`：格式化后的整个结果，默认值。
- 结果含 `ok: false` 时按现有失败样式显示 `error`。
- 卡片显示来源插件名称。
- 卡片详情（`tool_detail_body.dart` 中的展开内容）使用同一套渲染。

调用发生时，Host 把 `display`、插件 ID 和名称写入工具块的元数据（`tool_source` 为 `plugin`），聊天记录据此渲染。插件之后被停用、更新或卸载，已有记录仍按调用时的展示方式显示。

插件化之前的聊天记录中，`WebSearch`、`WebFetch` 工具块没有这些元数据，`tool_source` 为 `builtin`。卡片对这两个工具名使用固定的兼容展示（与内置联网检索插件声明的 `display` 相同），只用于显示历史记录。

## 工具限制改为代码中的禁用名单

现有工具限制有两个来源：代码中硬编码的工具名白名单，以及 Agent 记录上的 `allowedToolNames` 字段。字段没有开放给用户配置，实际值也来自代码。M1 改为只用代码配置，并把白名单改为禁用名单：

- 受限的会话模式和 Agent 在代码中声明禁止使用的 Host 工具，如 Write、Edit、Create、Replace、Remove、Run。
- 插件注册的工具不出现在任何名单中，可用性只由插件状态决定；新增插件或内置 Web 工具改为插件后，都不需要修改 Agent 名单。
- 改写时逐个对照现有白名单，保证每个模式和 Agent 能用的 Host 工具与改动前一致。council、monologue、theater、roleplay 模式以及 explorer 等子 Agent 仍然不能使用 Host 写入工具。
- 受限模式和 Agent 可以使用已启用的插件工具。插件工具若通过 Host API 写入业务数据，仍受插件权限检查约束。

## 改动清单（M1）

#### `lib/shared/services/ai/builtin_agent_tools.dart`
- 各 `builtin*ToolNames` 白名单改为对应 Agent 禁止使用的 Host 工具名单；名单中不出现 `WebSearch`、`WebFetch`。
- `builtinPrimaryAgentToolNames`、`builtinSubAgentToolNames` 改为返回禁用名单。

#### `lib/shared/models/ai_session_mode.dart`
- `_specialModeTools` 改为特殊模式禁用的 Host 工具名单，`canUseTool` 按禁用名单判断。
- 删除没有调用方的 `allowedToolsDescription`。

#### `lib/shared/services/ai/tools.dart`
- 从 `aiToolCatalog`、工具定义列表和 `_dispatchHandlers` 中移除 `WebSearch`、`WebFetch`，删除 `part 'tools_web.dart'`。
- `mode.canUseTool` 检查保留，名单语义改为禁用。
- `defaultAgentToolNames`、`defaultSubAgentToolNames` 只返回 Host 工具。

#### `lib/shared/providers/agent_profile_providers.dart`、`lib/shared/providers/subagent_providers.dart`
- 停止读写 `allowedToolNames`，改读代码中的禁用名单；数据库列保留不动。

#### NEW: `lib/shared/services/plugins/agent_dispatcher.dart`
- `PluginAgentToolDispatcher`，按上文[Agent 接入](#agent-接入)实现。

#### `chat_turn_runner.dart`、`headless_session_turn.dart`、`spawn_agent_handler.dart`、`agent_council_orchestrator.dart`、`monologue_orchestrator.dart`、`theater_orchestrator.dart`、`roleplay_orchestrator.dart`（均在 `lib/shared/services/ai/`）
- 创建 Agent 时用 `PluginAgentToolDispatcher` 包装调度器；`allowedTools` 继续只列 Host 工具，由禁用名单计算。

#### NEW: `lib/shared/services/plugins/tool_bridge.dart`
- 把一次插件工具调用转换为 `PluginRuntime` 执行：传入输入和 `ToolContext` 所需的请求信息，取消时关闭运行时，按[结果与错误](architecture.md#结果与错误)约定生成工具结果。卡片元数据由 `PluginAgentToolDispatcher.callMetadata` 提供，这里不重复写。

#### `lib/shared/widgets/ai/tools/tool_card_descriptor.dart`
- 删除 `WebSearch`、`WebFetch` 的专属分支，改为按 `tool_source = plugin` 的元数据渲染标题和摘要；保留这两个工具名的历史记录兼容展示。

#### NEW: `lib/shared/widgets/ai/tools/plugin_tool_card_body.dart`
- 通用插件卡片体，实现参数标签、`items`、`text`、`json` 三种预览及来源插件显示。

#### `lib/shared/widgets/ai/tools/web_tool_card_body.dart`
- 删除，预览逻辑并入 `plugin_tool_card_body.dart`。

#### `lib/shared/widgets/ai/tools/tool_detail_body.dart`
- 删除按 `WebSearch`、`WebFetch` 工具名选择 `WebToolCardBody` 的分支，改为按 `tool_source = plugin` 使用 `plugin_tool_card_body.dart`；历史记录的这两个工具名走兼容展示。

#### i18n
- 插件卡片的来源标签使用新 key，加到 `assets/translations/en/ai.json`、`assets/translations/zh-CN/ai.json` 及 `lib/shared/localization/locale_keys.dart`。`aiToolNameWebSearch` 等现有 key 仍用于历史记录兼容展示，保留。
