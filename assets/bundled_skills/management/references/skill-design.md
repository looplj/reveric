# 技能创作向导

把模糊想法沉淀为高质量、全局可复用的 AgentSkill Bundle。Bundle 由 Skill 元数据、完整 prompt 和可按需读取的 `references/**` 文件组成。

## 先判定正确载体

- 小说角色的功法、天赋、能力是故事资料，不是 AgentSkill。
- 只会自动注入当前小说的长期偏好、禁忌或固定约束，应使用 AgentRule。
- 需要独立角色、任务委派或并行协作时，应使用智能体。
- 只有可被多次按需加载的 AI 工作流程、审查方法、写作方法或工具编排才创建 AgentSkill。

若用户只要求创建、改名、启停、删除、安装，或明确给出了完整字段，读取「系统管理」的 `references/agent-skills.md`。本文用于需求尚不完整、需要设计或验收高质量 Skill 的场景。

## 工作流程

### 1. 先查重

先调用：

```text
Run {"command":"agent-skills","subcommand":"list","options":{}}
```

发现同名或高度重叠的 Skill 时，说明职责重合点，用 AskUser 让用户选择更新、合并、保留为独立能力或取消。不得静默创建重复 Skill。

### 2. 收集最小规格

若已有信息足够，不要机械追问；否则每轮 AskUser 最多问 2–3 个相关问题：

1. 任务目标与成功结果。
2. 2–3 个应触发的真实用户说法。
3. 1–2 个不应触发的相邻场景。
4. 必要输入、需要先读取的小说资料、允许调用的工具、产物与禁区。
5. 哪些内容应作为按需读取的 Reference，而非塞进 prompt。

Reference 只放篇幅较长、仅部分任务需要、可独立维护的材料。核心目标、不可违反边界和每次都必须执行的步骤必须留在 prompt。

### 3. 输出 Bundle 蓝图

保存前先展示完整草案：

- `name`：简短、中文、单一职责、全局唯一。
- `when_to_use`：具体任务语境与触发表达，不写空泛口号。
- `description`：交付物、范围和边界。
- `prompt`：前置读取、步骤、条件分支、输出格式、失败处理与自检。
- `references` 清单：每个文件的 `references/**` 路径、用途和内容概要。
- 验收样例：至少 2 条应触发、2 条不应触发、1 条信息不足时的预期行为。

若 prompt 要使用附件，在正文给出准确路径并允许 Agent 直接 `reference-get`；未知路径时才从 `<skill_resources>` 的 `reference-list` 返回目录中选择；禁止臆造路径或预读全部附件。

### 4. 显式确认后写入

创建新 Skill 时，用户确认后一次性写入完整 Bundle：

```text
Run {"command":"agent-skills","subcommand":"create","options":{"name":"<名称>","when-to-use":"<触发条件>","description":"<描述>","prompt":"<完整指令>","references":[{"path":"references/<文件>.md","content":"<正文>"}]}}
```

修改既有 Skill 时：

- prompt、名称、触发条件等字段沿用 `agent-skills update`，先用 `list` 返回的 `id`。
- Reference 用 `reference-list`、`reference-get`、`reference-create`、`reference-update`、`reference-move`、`reference-delete`，统一以全局唯一 `name` 定位 Skill。
- 删除 Reference、移动路径或覆盖内容前必须 AskUser 确认。

Reference 路径必须以 `references/` 开头。可嵌套目录；不得包含 `..`、隐藏路径或不支持的文件类型。

### 5. 创建后验收

创建成功后简短核对：

- Skill 的触发条件能否排除相邻任务。
- prompt 是否依赖本轮聊天的隐含上下文。
- 每个 Reference 是否确实按需读取，而非应进入 prompt 的核心规则。
- 选择一条真实任务，说明会加载哪个 Skill、先读取什么、输出什么。

Run 失败时直接报告失败原因与已成功写入的部分；不得声称 Bundle 已完整保存。
