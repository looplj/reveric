# 业务数据删除规则

- 用户业务数据默认软删除：保留记录并通过 `deleted_at` 隐藏，不能直接执行 SQL `DELETE` 或调用 `hardDelete`。
- 关系数据硬删除例外（2026-09-24 用户确认）：`entity_relations` 保留 `deleteRelation`、`deleteRelationsForEntity` 的硬删除语义，删除关系行时连同行内 `change_logs` 一并移除；删除误录历史项时从该关系的 JSON 数组中实际移除，不保留软删除标记或纠错事件。最新变化删除须在同一事务恢复前态，较早变化删除不改变当前状态。关系终止仍使用 `status=ended`，不能用 DELETE 代替。此授权不扩展到端点实体、其他表、文件或后台批量清理，也不是立即清理现有关系数据的指令。
- 其他已批准的硬删除范围如下（包含 `StorageCleanupService` 的 retention 清理），不得类推到相邻表、附件或业务数据文件：
  - `Run files remove`（2026-10-19 用户确认作品文件工作区契约）：允许按明确相对路径或 glob 永久删除当前作品 `file_workspaces/<work_id>/` 内的匹配文件；相对路径从该作品目录解析，删除目录须显式指定 `recursive=true`。禁止 `..`、绝对路径、符号链接、其他作品、共享目录及作品根目录本身。执行时使用独立的 `files.remove` 权限，删除范围须在审批前确定并在执行前复核；不扩展到数据库记录、外部文件或自动清理任务，会话 GC 仍按原会话归属处理。
  - MCP 服务器配置（2026-10-29 用户确认）：删除 MCP 服务器时，从主库 `app_settings` 中 `mcp_servers` 配置的 `servers` 列表直接移除该条目，连同其凭据一起删除，不保留软删除记录，名称可立即被新建或导入复用。不扩展到其他 `app_settings` 键、AI Provider 或 Agent 等其他配置。
  - 回收站作品（2026-11-05 用户确认）：删除作品只做软删除并进入回收站，界面只提供恢复，不提供手动彻底删除。`deleted_at` 超过「数据保留时间」设置（`changeRecordRetentionDays`，与历史、会话清理共用，7–365 天，默认 30）后，由 `storage_cleanup/deleted_works.dart` 在作品未打开、无运行中会话时彻底删除该作品的全部数据：主库 `novels` 行、`novel_collection_members`、`ai_chat_sessions` 及其 `todos`、`session_subscriptions`、作品级 `agents`、`tool_permission_rules`、`reading_progress`、`generation_tasks`、`image_batches` 及其 slots / references、只属于该作品的 `assets`（含已软删除的）及其 `provider_assets` 记录和本地文件；内容库文件（含 `-wal` / `-shm` / `-journal`）和 `file_workspaces/<作品ID>/`。先删主库记录（作品行带 `deleted_at` 条件，期间被恢复则不动），再删文件。保留：未软删除且已收进素材库（`in_library`）或被其他作品用作封面的图片（改为不归属任何作品，文件保留）、仍被其他记录共用路径的文件、`ai_usages` 用量统计，以及渠道端远程素材。不扩展到其他实体的回收站或手动彻底删除。
  - 创建作品失败的收尾（2026-11-05 用户确认）：`createNovel`、demo 剧本种子和 TXT 导入都先建内容库再登记 `novels` 行；登记前任一步失败，只删除刚为该作品新建、尚未登记的内容库文件（含伴随文件），不涉及任何已登记作品的数据。
  - 主库：`ai_chat_sessions`
  - 主库 `todos`：仅随作品未打开、无后台 Agent、无保留引用且整棵过期的会话树，按同一 session ID 集合清理（2026-09-08 用户确认）。同时包含可唯一确定作品归属、整组过期且通过相同保护检查的孤儿子树及缺失 session ID 的残留消息/Todo/active 指针组（2026-09-08 用户确认实施）。仅剩 Todo 无法归属、跨作品冲突、循环及内容库扫描不完整时保留；不扩展到订阅或附件。
  - 内容库：`ai_chat_messages`、`working_changes`、`change_commits`、`change_commit_items`、`novel_state_snapshots`（仅 `superseded`）
  - 软删除记录（2026-09-17 用户确认）：按 `deleted_at > 0 AND deleted_at < cutoff` 清理 `storage_cleanup/soft_deleted.dart` 中的固定名单。主库为 `memories`、`agents`、`ai_shortcut_actions`、`ai_providers`；内容库为章节、人物、物品、伏笔、Agent 规则、文档、大纲及节拍、画布及节点、剧本及子表、地点、地图及地图地点。保留在用作品保护，但**不因仍有引用而保留已过期软删除记录**。不扩展到作品登记、图片记录、关联边或业务文件。
  - 派生缓存文件，仅限 `<ApplicationSupport>/network_image_cache/` 下由 `NetworkImageDiskCache` 自己写入的条目及其 `.tmp` 残留（2026-09-16 用户确认）。只删该目录第一层，不递归子目录，不按用户选择的路径删除任何内容。判据是「删掉之后能按原 URL 原样重新下载」，因此这些文件不算用户业务数据、不适用软删除；带鉴权、由用户导入或本地生成的图片（`images/`、`novel_covers/`、`ai_images/` 等）一律不在范围内，也不得据此类推到其他缓存目录。
- 新增任何硬删除路径，包括 DAO `hardDelete`、直接 SQL `DELETE` 和删除业务数据文件，必须先获得用户明确确认。
- 用户授权的是具体删除范围，不得把一次确认扩张为后续实体或通用硬删除权限。
