# 请求级 Prompt、定时任务与记忆插件

> M3 提供 Prompt、Host 定时任务与记忆插件验收；通用 Event 与 Hook 属于后续迭代。插件可见的接口以 [`plugins/sdk/index.d.ts`](../../../plugins/sdk/index.d.ts) 的声明与注释为准，本篇只记录 Host 侧的调度、预算与验收语义；章节与人物的业务数据 API 见[架构](architecture.md#业务数据-api)。任务进度只在[实施任务](README.md#实施任务)维护。

## Event 与 Hook

后续迭代。以下是已确定的语义边界，接口在出现具体插件需求时设计。

| 回调 | 示例 | 语义 |
| --- | --- | --- |
| Event | `document.saved`、`character.updated` | 操作已经成功，通知订阅者；订阅处理失败不撤销业务提交 |
| Hook | `document.beforeSave` | 提交前调用，允许的返回结果由该节点规定 |

- 每个 Hook 必须明确调用顺序、可修改字段、允许或拒绝的结果、等待和超时策略、异常处理及取消行为，不对所有节点套用同一种失败后继续策略。
- Host 在 Service / Orchestrator 的明确业务节点调用回调，使内置界面、插件和其他调用方经过相同边界。只实现真实需求使用的节点。
- 事件只携带资源 ID、版本和必要元数据，读取正文仍经过权限检查。
- 插件写入后可能再次触发事件，事件须携带来源插件、操作 ID 和因果关系，Host 限制循环深度。前置 Hook 对当前操作的变更通过返回结果表达，避免递归调用同一保存操作。
- 回调与工具调用一样，每次派发新建运行时执行。

## 请求级 Prompt 提供方

M3 增加专用的 `setup.prompts.register`，用于记忆等请求上下文。不开放任意消息修改 Hook，插件不能替换宿主 system prompt、修改历史消息或改变 tool schema。注册项 `PromptRegistration` 与只读上下文 `PromptContext` 的定义见 [`plugins/sdk/index.d.ts`](../../../plugins/sdk/index.d.ts)。

- 只在 `apply` 注册，按插件 ID 和 provider ID 固定排序。Host 在每次模型请求尝试前捕获启用插件与请求作用域快照，启动短生命周期运行时，调用 handler；不依赖插件管理页面打开。
- `workId` 是 Host 解析的稳定作品 ID，不是数据库路径，也不接受模型伪造的范围。工具通过 `ToolContext.request` 取得同样的请求作用域，页面通过 `ViewContext.page.workId` 取得所在作品。子 Agent 由 Host 继承父请求作用域；无作品时为 null。插件只能获得必要的请求元数据，不默认获得聊天正文。
- 提供方只能读取自己的 sqlite/storage/settings 数据和写诊断日志，`PromptContext` 不提供写库、网络、AI 调用、注册新能力和显示 UI。按每次提供方 500 ms、全部提供方 1500 ms 总等待预算执行；超时结束等待并关闭运行时；已进入 SQLite 的读取按数据库等待语义处理。
- Host 将文本按插件来源单独包裹为参考上下文，追加到请求级提示区域，保留内层 MCP 提示。记忆内容是数据，不能提升为高于宿主规则的指令。按现有 token 估算器限制单插件 1000 tokens、合计 2000 tokens；超额块省略并报告诊断，不静默切断结构化内容。
- 返回 null/空串时不加入；异常、超时和超限时继续模型请求，显示可追踪的插件诊断并记录原因，不使用上次请求的陈旧块。成功生成的块只存在于本次请求快照，不反复追加到会话历史。
- 构建前复查插件是否仍启用和请求作用域是否有效；停用后下一次请求没有该插件块。正在流式生成的请求不追溯修改；工具写入成功后的下一次模型请求重新读取，因此同一轮工具循环可使用新记忆。请求重试也重新准备，handler 必须无副作用。
- 主聊天、无界面聊天与子 Agent 共用这条入口；特殊会话模式按其 Host scope 调用，不能继承其他作品快照。上下文压缩的摘要请求不重复执行插件提供方。

现有 `AgentRequestToolDispatcher.prepareRequest/requestSystemPrompt` 可作为接入点，但必须补齐稳定请求身份和作用域传递。它目前只透传插件调度器的内层提示，不能把接口存在写成 Prompt 扩展已实现。

## Host 定时任务

清单 `tasks` 按任务 ID 声明 `title` 和 `intervalMinutes`；标题每种语言最多 200 字符，周期为 15 至 10080 的整数分钟。`apply` 通过 `setup.tasks.register(id, handler)` 绑定函数，类型见 SDK 的 `TaskHandler` 和 `TaskContext`。周期调度由 Host 持有，当前实现仍在每次任务执行时创建短生命周期 JS 运行时，结束后释放；不以页面里的 `setInterval` 实现后台任务。

```json
{
  "tasks": {
    "organize": {
      "title": { "zh-CN": "整理记忆", "en": "Organize memories" },
      "intervalMinutes": 60
    }
  }
}
```

```ts
export function apply(setup: PluginSetup) {
  setup.tasks.register("organize", organize);
}
```

- 绑定只在 `apply` 执行，ID 来自清单 `tasks` 的对象 key。每个声明必须有且只有一个 handler，缺失、多注册或重复绑定均拒绝。元数据只在清单维护，Host 每次核对声明、绑定和激活快照；不引入 cron、系统服务或精确闹钟。
- 默认随插件启用，首次注册从当前时间加周期开始；设置页允许逐任务暂停、恢复、立即运行、取消当前运行，展示最近成功/失败、下次到期和摘要。逐任务暂停状态跨重启保存，插件更新不能重置用户选择。
- Host 持久化 `(plugin_id, task_id)`、启停、nextDueAt、最近开始/结束/结果及运行身份。开始执行前记录租约，崩溃恢复标为中断；每个任务不重入，同插件最多一个后台任务，全应用最多两个。立即运行也遵循该队列，重复触发合并成一次，不积压无限队列。
- 仅应用运行且前台可调度时执行。退出不运行；Android 后台不保证执行，进入后台取消正在执行的任务，已提交事务不回滚。回到前台或重启时，过期任务最多补跑一次，加 0 至 30 秒抖动，成功后从完成时间重新计周期，不回放所有漏掉的 tick。
- 每次执行的总时长和单段 JS 连续执行时长见 SDK 的 `TaskContext`，由原生中断保护。后台任务单独限流，不能占用工具的全部执行槽位。失败以 1、5、15 分钟退避，最多重试三次，再失败则等下个正常周期；取消不作为失败重试。
- 停用、卸载或更新时停止派发并取消运行（直接关闭运行时，handler 不轮询取消状态），等待数据库事务结束再关闭连接或迁移；旧版本迟到结果不能覆盖新任务状态。注册项被移除后停调，保留历史状态供诊断。
- 投递按至少一次处理，插件以 runId/输入版本做幂等设计，不承诺恰好执行一次。长任务分段保存检查点，不能跨模型等待保持 SQL 事务；取消会在任意 await 处结束执行，同一阶段的写入放进一个 `sqlite.transaction`。

### 任务中的 AI 请求

记忆整理需要一次轻量模型生成，M3 只提供任务上下文中的 `ai.generateText`，不开放通用 Agent、工具递归或流式会话接口。接口签名、`maxOutputTokens` 范围和每次运行的调用次数上限见 SDK 的 `TaskContext.ai`。

Host 使用用户配置的默认聊天模型，通过现有 `chatCompletion` 路径执行，不向插件暴露供应商凭据或底层客户端。每次 AI 调用最长 120 秒，调用次数与输出上限见 SDK，输入纳入模型上下文与宿主用量限制；失败保留实际错误，取消传递到模型请求。无可用模型时返回配置错误，不能偷偷换用供应商。

清单声明 `ai.generateText` 权限，安装/启用时说明后台任务会使用模型并产生用量，未经授权不可调用；任务 UI 展示用量与失败原因。Prompt 提供方不能调用此接口。泛化的 `ai.invoke` 与长生命周期 Agent 仍留在后续迭代。

## 记忆插件验收闭环

记忆插件是 M3 的主要成功标准，包含插件私有库、Tools、请求级 Prompt、TSX 管理 UI 和 Host 定时整理。宿主只提供通用能力，不把记忆 CRUD、筛选或 Prompt 内容硬编码进插件 Host。内置与第三方包使用相同接口。

### 首版内容

- 数据由插件 migration 定义：`memories` 保存 id、可空 work_id、content、category、priority、enabled、revision、created_at、updated_at、deleted_at；索引覆盖作用域与展示顺序。`suggestions` 保存整理候选、来源记忆 ID/版本、运行 ID、状态和时间戳，不依赖外键或触发器。
- Tools 提供搜索、创建、修改与软删除。工具名称和静态 Schema 随插件 SDK 实现确定，具体 description 文案按项目规则另行确认；本方案不修改现有工具描述。作用域由 Host 请求上下文提供，创建默认当前作品；写全局记忆必须显式选择全局，不能任意传入另一个作品 ID。
- 搜索首版使用 SQL 文本匹配、分类筛选、排序和分页，不引入 FTS 或向量检索。修改携带 revision，零行更新返回冲突或不存在，不覆盖新值。Tool、UI 和 Prompt 使用同一份已提交数据。
- Prompt 首版注入启用且未删除的“全局 + 当前作品”记忆，按核心优先、更新时间及 ID 稳定排序，在预算内选取完整条目；没有作品只取全局。禁用或软删除的记忆在下一次请求消失。
- TSX 管理页支持 scope/分类筛选、搜索、分页、新建、编辑、启停、软删除、查看本作用域将注入的内容与预算；未保存关闭确认、中文输入和异步竞态按 View 契约验收。保存后重查；工具从外部修改后可手动刷新或页面恢复时重查，带 revision 的编辑不会被刷新覆盖，不为首版增加通用数据库订阅接口。
- 在清单声明 `organize` 任务并在 `apply` 中绑定 handler，默认每 60 分钟运行，也可立即运行。按 scope 分批读取记忆，调用默认模型生成单条精炼建议，把建议及源 revision 保存到 `suggestions`；同一源版本不重复生成。不自动修改或删除原记忆，管理页可逐条应用或忽略。应用用单条条件 UPDATE 检查源 revision；成功后标记建议，若标记前崩溃，因旧 revision 已失效而不能重复应用。首版不做多条自动合并或自动提取整段聊天历史。
- 关闭插件后工具、Prompt、页面和任务一起失效；重新开启或重启后私有库数据仍在。第一次验收不要求插件市场、聊天记录读取权限、向量库或通用 AI Agent API。

### 旧功能删除范围

用户已确认删除原未开放记忆功能及主库 `memories` 表中的历史数据。删除旧记忆 Service、DAO、Provider、模型、调度/提取/整理、管理组件、工作区枚举分支、设置、翻译和旧 Prompt 注入；不迁移、不复制到新插件私有库，也不保留双轨注入。普通聊天历史、Agent 上下文压缩、移动端最近会话缓存和进程内存诊断不属于删除范围。

2026-10-31 核对本地最新正式 tag `v0.5.0`：主库 schema 为 1 且有 `Memories` 定义。删除通过正式 schema 升级覆盖已有安装，新的 schema 不建旧表；不根据 UI 未开放推断数据库定义未发布。当前 app 库 schema 为 3：schema 2 新建插件表，schema 3 移除旧表；本次不直接操作本机 Debug/Release 库。旧记忆相关设置停止读写，旧设置残值不再生效，不扩大清理到其他用户配置。

验收以全新插件数据开始，不要求恢复已确认删除的旧记忆。代码清理是独立可合并任务，不依赖新插件先实现。

### 记忆工具契约

首版工具固定为以下四个，不增加 Host 工具同名覆盖。下表定义行为和参数，不是面向模型的 description 文案；正式描述按项目要求单独确认后编写。

| 工具 | 参数 | 结果与约束 |
| --- | --- | --- |
| `MemorySearch` | 可选 query（最多 200 字符）、category、scope（all/current/global，默认 all）、limit（默认 20，最多 50）、offset（默认 0） | 返回 items 和 hasMore；all 为全局加当前作品；按 priority、更新时间倒序及 ID 排序；无作品时 current 报 `invalid_argument` |
| `MemoryCreate` | content、category；可选 scope（current/global，默认 current）、priority（0 普通/1 核心，默认 0）、enabled（默认 true） | 创建独立 ID，revision=1，返回条目；类别为 fact/preference/instruction；无作品时必须显式选 global |
| `MemoryUpdate` | id、revision；可选 content/category/priority/enabled、scope | 只改当前可见范围内的未删除记忆，成功递增 revision；不存在或越界返回 `not_found`，版本不符返回 `conflict`。省略 scope 表示记忆自身的范围，显式给出且不一致时返回 `invalid_scope` |
| `MemoryRemove` | id、revision；可选 scope（规则同 MemoryUpdate） | 设置 deleted_at 并递增 revision，返回 `{id, deleted: true}`；不物理删除，不允许跨作品范围 |

content 去除首尾空白后必填，最多 4000 个字符；预期内的失败以 `PluginError` 抛出，error_code 原样返回给 Agent；所有工具输入 Schema 固定，不随记忆条目、作品或 UI 状态变化。UI 调用插件共用的数据逻辑与校验，不经模型伪造 Tool 调用。Prompt 使用同样的作用域与 enabled/deleted_at 过滤。

### 调度持久化与公平性

Host 使用主库 `plugin_tasks` 表持久化任务状态，复合主键为 plugin_id/task_id，列包含 enabled、next_due_at、run_id、lease_expires_at、attempt、last_started_at、last_finished_at、last_status、last_summary、last_error_code、last_usage、created_at、updated_at、deleted_at；到期扫描使用 enabled/next_due_at 索引。无外键、触发器或 SQL 枚举约束。详细执行日志沿用日志系统，不额外创建无限增长的任务历史表。

Task 注册属于插件能力，状态属于 Host；插件自己的 SQL 看不到这张表。任务行只在首次注册或被移除后重新注册（恢复）时从当前时间安排 next_due_at；同一任务 ID 的定义变化（如周期）不触发重新安排，新旧定义的兼容由插件负责；用户的 enabled 始终保留。每次逻辑运行（含重试）复用 runId，attempt 递增，下一周期使用新 runId。租约与 handler 总超时配套，进程启动时没有存活执行者的租约标记中断，避免永久锁死。

全应用到期任务按 next_due_at、plugin_id、task_id 排序，在同插件不重入条件下依次分配执行槽。Prompt 准备使用独立的短时队列，同插件最多一个、全应用最多两个，排队也计入其 1500 ms 总预算；页面、工具、任务和 Prompt 的峰值内存须在三平台联合压测，不以独立槽位掩盖总量增长。

任务模型请求的权限撤销也会取消当前调用。已确认返回且已经提交的阶段结果不会自动撤销；取消直接关闭运行时，未提交的阶段不再继续；新阶段在写入前复查源版本。记忆整理每轮最多处理一个 scope、最多 20 条记忆，在插件库保存处理水位，后续运行轮转到下一个 scope，避免两次模型调用预算只服务第一个作品。生成建议的内容同样做长度、类别与来源版本校验，模型输出不能直接拼成 SQL。
