---
name: 系统管理
when_to_use: 用户要保存长期写作偏好、管理 AI 规则，智能体规则、设计、安装或维护 AgentSkill、配置智能体或专家，查询已配置的供应商以及聊天、图像、视频、音频模型能力，打开应用设置分区，或自定义、修改、切换应用界面主题配色时
description: 按任务读取对应操作指南，管理创作规则、AI 技能、智能体、界面主题，查询供应商与模型能力，打开应用设置分区。
agent_scopes: [chat]
---

# 系统管理

先按任务选择附件，只读取本次需要的操作指南：

| 任务 | Reference |
| --- | --- |
| 保存长期写作偏好、禁忌，管理当前小说的 AgentRules | `references/agent-rules.md` |
| AgentSkill 的查找、安装与日常管理，包括附件 | `references/agent-skills.md` |
| 从模糊需求设计新 AgentSkill，优化触发边界、提示词或附件结构 | `references/skill-design.md` |
| 管理智能体，配置职责与 system prompt | `references/subagents.md` |
| 创建、修改、应用或删除应用界面主题配色 | `references/themes.md` |
| 打开应用设置分区，让用户配置供应商、外观、备份、存储等 | `references/settings.md` |
| 查询供应商、聊天与媒体模型的真实 ID、能力与默认配置 | `references/providers.md` |

复制 `<skill_resources>` 中的 `reference-list` 调用列出附件，再用 `reference-get` 读取选中文件；`name` 使用「系统管理」，`path` 使用目录返回值。已读取且仍在上下文中的附件无需重读，不预读全部附件。

小说主题、立意、角色、功法、世界观规则和故事流程属于故事资料，不按 AI 工具配置处理。规则作用于当前小说，AgentSkill 可跨小说复用；载体或作用范围不明确时先确认。

界面主题作用于整个应用，跨小说使用；不要把界面主题修改写成 AgentRule。
