# 智能体技能管理

用于把用户确认过的 AI 工作流程、写作方法、审稿规则和工具使用步骤沉淀为应用内全局可复用的 AgentSkill。AgentSkill 是给 AI 看的操作指令，会出现在后续所有小说聊天的“可用 AgentSkills”列表中，并可通过 AgentSkill 工具按需加载。

若用户的重点是从模糊想法设计高质量 Skill、优化触发边界、拆分 prompt 与 references、或验收 Skill 是否可靠，先读取「系统管理」的 `references/skill-design.md`；本文负责明确的全局 CRUD 与安装操作。

必须先区分两类“skill”：

- **AgentSkill / agent skill / AI 技能**：约束 AI 怎么工作，例如“章节扩写流程”“爽文节奏审稿”“图像提示词设计”。这类内容用 Run 的 `agent-skills` 命令管理。
- **小说内技能 / 能力 / 功法 / 招式 / 天赋 / 职业技能**：属于故事世界观或角色设定，例如“御剑术”“火球术”“潜行技能”。这类内容不是 AgentSkill，禁止用 `agent-skills` 创建；应按用户意图写入正文、设定、角色资料或世界观资料。

如果用户只说“创建一个 skill”，但上下文无法判断是哪一类，先用 AskUser 问清楚：这是给 AI 后续调用的 AgentSkill，还是小说角色/世界观里的技能？

## 范围

Run 的 `agent-skills` 命令始终操作**应用内全局技能列表**：创建、更新、启用、停用、删除和安装都会影响后续所有小说聊天。不要传 `scope` 或 `novel`。这里的“全局”仅指本应用内跨小说可用，不代表公开发布或云端同步。

内置 Bundled Control Skill（如「创作向导」「系统管理」）不属于这个列表，不能通过 `Run agent-skills` 创建、更新、删除或安装。需要使用内置 Skill 时，从可用 AgentSkills 列表中通过 `AgentSkill` 工具按名称加载；若该 Skill 带有附件，可用 `reference-list` 和 `reference-get` 只读查询，不能创建、覆盖、移动或删除附件。

## 创建、更新与删除

### 1. 先列出现有 AgentSkills

创建或更新前，先查询全局已有技能，避免全局重名或重复沉淀。

```text
Run {"command":"agent-skills","subcommand":"list","options":{}}
```

列表返回摘要：`id`、`call_name`、`name`、`description`、`source_kind`、`enabled`，以及可能的 `execution_blocked_reason`；不返回完整 `prompt` 或 `when_to_use`。更新和删除必须使用返回的 `id`，不要凭名称猜 id。

### 2. 判断创建还是更新

- 已存在同名或高度同责的全局 AgentSkill：更新已有条目。
- 现有技能职责相近但不完全相同：先用 AskUser 让用户确认是合并、改名还是新建。
- 没有同类技能：创建新条目。

不要把多个不相关流程塞进一个 AgentSkill。一个 AgentSkill 只负责一种可明确触发的任务。

### 3. 写好 AgentSkill 字段

每个 AgentSkill 至少包含：

- `name`：短、可调用、全局唯一。优先中文名，例如“爽文节奏审稿”。
- `when-to-use`：触发条件，说明什么时候该用。写具体语境，不写空泛口号。
- `description`：一句话说明它做什么、覆盖哪些任务。
- `prompt`：完整操作指令。必须可执行，包含步骤、边界、输出要求和必要的自检。
- `references`：可选的 `references/**` 按需读取附件。只放长篇、条件性或可独立维护的材料；每次都必须遵守的核心规则留在 `prompt`。

`prompt` 应说明目标、步骤、必要的查询或 AskUser、输出格式、自检和冲突处理。若任务依赖小说内容，prompt 必须要求先读取或询问当前小说资料，不得把某一本书的故事事实硬编码为全局规则。

### 4. 用 Run 创建或更新

```text
Run {"command":"agent-skills","subcommand":"create","options":{"name":"章节节奏审稿","when-to-use":"用户要求检查章节节奏、爽点密度、钩子、断章或阅读推进感时","description":"检查章节节奏与读者拉力，指出空转、爽点过稀、断章无力等问题，并给出修改建议。","prompt":"# 章节节奏审稿\n\n先判断章节目标和读者预期，再检查场景推进、爽点密度、钩子、断章和信息释放..."}}
```

更新前必须先 `list` 找到目标 `id`。只传需要修改的字段，未传字段会保留原值。若 `source_kind` 是 `official` 或 `marketplace`，更新的是本地全局安装快照，后续升级可能覆盖这些修改；执行前应向用户说明这一影响。

```text
Run {"command":"agent-skills","subcommand":"update","options":{"id":"skill_xxx","when-to-use":"用户要求检查章节节奏、章末钩子、爽点密度或正文空转时","prompt":"# 章节节奏审稿\n\n更新后的完整指令...","enabled":"true"}}
```

停用可用 `enabled: "false"`。停用或删除会影响后续所有小说聊天；删除只在用户明确要求删除时执行：

```text
Run {"command":"agent-skills","subcommand":"delete","options":{"id":"skill_xxx"}}
```

## Reference CRUD

Reference 是某个 AgentSkill 的可选附件，不是小说工作区资料。运行时加载 Skill 后，Agent 会在 `<skill_resources>` 中看到一次 `Run agent-skills reference-list` 目录发现调用；正文已给出准确附件路径时直接使用 `reference-get`，未知路径时先列目录再选择，不要用 Read 虚拟路径，也不要预读全部文件。

Reference 操作以 Skill 全局唯一 `name` 定位，路径相对 Skill root，必须以 `references/` 开头：

```text
Run {"command":"agent-skills","subcommand":"reference-list","options":{"name":"章节节奏审稿"}}
Run {"command":"agent-skills","subcommand":"reference-get","options":{"name":"章节节奏审稿","path":"references/rubric.md"}}
Run {"command":"agent-skills","subcommand":"reference-create","options":{"name":"章节节奏审稿","path":"references/rubric.md","content":"# 审稿量表\n..."}}
Run {"command":"agent-skills","subcommand":"reference-update","options":{"name":"章节节奏审稿","path":"references/rubric.md","content":"# 更新后的量表\n..."}}
Run {"command":"agent-skills","subcommand":"reference-move","options":{"name":"章节节奏审稿","path":"references/rubric.md","new_path":"references/review/rubric.md"}}
Run {"command":"agent-skills","subcommand":"reference-delete","options":{"name":"章节节奏审稿","path":"references/review/rubric.md"}}
```

- 创建前先 `reference-list`；覆盖正文、移动或删除前必须用 AskUser 明确确认。
- `reference-update` 只改内容；改文件名或目录必须使用 `reference-move`。
- 路径可嵌套，但不得使用 `..`、隐藏路径或不支持的文件类型。写入失败时直接报告失败，不得丢弃非法附件后假装成功。
- official / marketplace 的本地安装快照也可编辑 Reference，但后续升级会以来源版本覆盖本地附件；修改前必须说明。

## 搜索与安装

### 1. 搜索并查看完整内容

先搜索候选技能，再对用户可能安装的候选使用 `get` 查看完整 prompt。`official` 是本地打包目录，默认显式查询该来源。`marketplace` 尚未接入；未指定来源的搜索会返回可用的官方目录，并在 `unavailable_sources` 中标明市场不可用。

`source_id` 必须来自搜索结果：官方技能用 `name`，市场技能用 `listing_id`。不要编造 id。

```text
Run {"command":"agent-skills","subcommand":"search","options":{"query":"章节审稿","source":"official"}}
Run {"command":"agent-skills","subcommand":"get","options":{"source":"official","source_id":"章节规划"}}
```

显式指定 `marketplace` 的 `search`、`get` 或 `install` 返回 `error_code: "unavailable"` 时，说明市场尚未接入并停止市场操作。可继续使用本地官方目录或已安装技能。

若返回 `not_found`、`unavailable` 或 `invalid_argument`，根据 `error` 说明操作失败的具体原因。不要把失败伪装成“没有搜索结果”。

### 2. 安装前必须先 AskUser 确认

在调用 `install` 前，必须先用 AskUser 明确确认。AskUser 需要说明：技能名称、来源、用途、将安装为应用内全局 AgentSkill、会在后续所有小说聊天中可用，以及用户可以取消。未得到明确确认时，不得安装。

确认后再调用：

```text
Run {"command":"agent-skills","subcommand":"install","options":{"source":"official","source_id":"章节规划"}}
```

不要在 Run 调用后等待它自动向用户确认；确认是本层 agent 的职责。

### 3. call_name 冲突

安装返回 `error_code: "already_exists"` 时，结果会给出全局冲突的 `conflicting_call_name`、可能的 `existing_id`，以及可选方案。不得自行覆盖、改名或重试。

先用 AskUser 让用户在以下选项中选择：

- 覆盖现有技能：重新调用同一条 `install`，并加入 `"conflict_resolution":"overwrite"`。
- 使用新调用名安装：用 AskUser 获取新的 `call_name`，然后重新调用同一条 `install` 并加入 `"call_name":"用户提供的新名称"`。
- 取消：说明未安装，不再调用 Run。

示例：

```text
Run {"command":"agent-skills","subcommand":"install","options":{"source":"official","source_id":"章节规划","conflict_resolution":"overwrite"}}
Run {"command":"agent-skills","subcommand":"install","options":{"source":"official","source_id":"章节规划","call_name":"章节规划_自定义"}}
```

如果新调用名再次冲突，重复以上 AskUser 流程；不要自动拼接后缀。

## 保存后回报结果

Run 成功后，简短告诉用户创建、更新、删除或安装了哪个全局 AgentSkill，并说明触发条件和对后续所有小说聊天的影响。安装时说明来源和实际 `call_name`。

Run 失败时，直接报告失败原因。不要假装已保存，也不要改用普通回复手动“记住”。

## 质量标准

一个好的 AgentSkill 应满足：

- 能被 `when-to-use` 准确触发。
- `description` 能让 AI 在列表里快速判断是否该加载。
- `prompt` 足够完整，即使隔天重新加载也能独立执行。
- 不依赖当前这轮聊天里的隐含上下文；必要上下文必须写进 prompt 或要求先查询/询问。
- 需要小说上下文时先读取当前小说资料，不能把某一本书的设定固化为所有小说都适用的内容。
- 不把小说设定内容当成 AI 操作指令保存。

## 常见误判

- “帮我给主角设计一个潜行技能”不是 AgentSkill，是小说内容。
- “以后审稿时都检查主角有没有降智”可以是 AgentSkill，也可以是用户规则；如果只是长期偏好，用规则更合适；如果是一套审稿流程，用 AgentSkill。
- “把刚才的扩写步骤做成 skill”通常是 AgentSkill。
- “新增一个技能：火焰冲击”通常是小说内技能，禁止调用 `agent-skills`。
