# 制片画布撤销与重做

> 本文是[短剧制作方案](README.md)的分篇，适用于剧本作品每集的制片画布，以及[画布作品](canvas-work.md)的画布（两者使用同一个画布组件）。进度只在 README 的[实施任务](README.md#实施任务)维护（CU-01、CU-02）。构思画布不在本文范围内。

## 1. 背景

### 现状

以下事实核对自 `unstable` / `44ad472`（2026-11-11）：

- 制片画布（`desktop/features/production/`）和构思画布（`desktop/features/canvas/`）都没有撤销。
- 导演台（`shared/services/director/commands.dart`）和剪辑（`shared/services/editing/session.dart`）有撤销。它们在内存里保存整份文档的快照，最多 100 步，离开页面后清空。
- 制片画布的数据分在三张表：`CanvasNodes`（节点、位置、文本）、`CanvasEdges`（连线）、`ProductionClips`（生成配置与 inputs）。没有一份整体文档可以拍快照。
- 删除节点：`GroupService.remove` → 有 clip 的节点走 `StoryboardService.softDelete`（软删除 clip 及引用它的节点），否则走 `CanvasDao.softDeleteNode`（软删除节点，并按 2026-10-07 确认的例外硬删除相关的 `CanvasEdges` 行）。删除分组时，成员一起删除。
- AI 对画布的修改已经可以在聊天的改动记录里单独回退。

### 问题

- 症状：误删节点、误连线或误拖动之后，只能手动重建；删除剪辑节点时，时间线也跟着软删除，界面上找不回来。
- 根因：制片画布的写操作直接落库，没有记录操作前的状态。
- 影响：画布作品的剪辑节点、长链路的连线一旦误删，代价很高。

### 约束

- 不改表结构。
- 不新增硬删除。撤销「删除」时重新插入被硬删除的连线行，这是插入，不是删除；重做「删除」时沿用已确认的连线硬删除例外。
- 不覆盖 AI 或其他视图在这期间做的修改。

## 2. 目标

### 目标

1. 在制片画布中，Cmd/Ctrl+Z 撤销、Shift+Cmd+Z 或 Ctrl+Y 重做；缩放工具组旁边有撤销、重做按钮，不可用时置灰。
2. 可撤销的范围是画布结构：添加和删除节点、移动和调整大小、连线和断开及调整输入顺序、文本节点的内容和标题、分组与解组及转换分组类型。
3. 撤销记录只保存在内存里，每张画布最多 100 步，离开画布后清空。
4. 如果目标内容在这一步之后被别人改过，撤销或重做不执行，并给出提示。

### 非目标

1. 构思画布的撤销。
2. 节点参数：提示词、模型、时长、比例、清晰度、风格、生成音频开关。
3. 提交生成、切换采用结果、导入文件。
4. AI 在聊天中对画布的修改（继续通过聊天的改动记录回退）。
5. 导演台内部、剪辑时间线内部的修改（它们各自有撤销）。
6. 持久化的撤销记录，以及跨会话恢复。

### 成功信号

| 信号 | 验证方式 |
|------|----------|
| 删除节点（含分组、剪辑节点）后撤销，节点、clip、连线、下游 inputs、剪辑工程全部恢复，id 不变 | 服务测试比对删除前后的行 |
| 撤销后重做，结果与第一次操作相同 | 服务测试 |
| AI 修改了同一节点后再撤销，被拒绝且数据不变 | 服务测试 |
| 修改提示词后按 Cmd/Ctrl+Z，画布不发生变化 | widget 测试 |

## 4. 解决方案

### 方案对比

| 方案 | 做法 | 优点 | 缺点 | 结论 |
|------|------|------|------|------|
| A | 整张画布快照（与导演台、剪辑相同） | 实现简单 | 每步都要读写全部节点、连线和 clip，大画布开销高；恢复时会覆盖期间的 AI 修改 | 放弃 |
| B | 每个操作手写一个反向操作 | 精确 | 每种操作都要写一份反向逻辑，删除的级联（分组成员、连线、inputs）很容易漏 | 放弃 |
| C | 操作前后只抓取受影响的行，撤销时写回操作前的行 | 一套机制覆盖全部操作；级联内容自动包含在内；可以按行检测冲突 | 每个操作都要声明受影响的范围 | **采用** |

### 决策

采用方案 C。服务层在一次写事务里：先抓取受影响的行（before），执行原操作，再抓取同一批行（after）。撤销时把这批行恢复成 before，重做时恢复成 after。

### 核心原则

1. 只记录用户在画布上的直接操作。AI 工具调用和后台任务（生成、派生、登记结果）不入栈。
2. 撤销写回整行，但只写结构相关的列：节点行全部写回；clip 行只写 `inputs` 与 `deletedAt`；剪辑工程只写 `deletedAt`。参数列保持当前值。
3. 撤销前先做冲突检查：受影响行的当前状态必须等于 after（撤销）或 before（重做）。比对 `updatedAt`；连线行没有 `updatedAt`，按行内容比对。
4. 冲突时这一步作废并移出栈，给出提示，其余步骤保留。

### 用户操作

- 拖动节点 → 松手时记一步；一次拖动多个选中节点算一步。
- 文本节点 → 一次编辑（进入编辑到保存）算一步，不按字符记录。
- 选区删除 → 一步。
- 新的操作会清空重做栈。
- 焦点在文本输入框里时，Cmd/Ctrl+Z 交给输入框，不触发画布撤销。

## 5. 方案实施

### 5.3 关键业务流程

**记录**

1. 画布区域调用服务的写方法，并标明要记入撤销栈（例如 `history: canvasHistory`）。
2. 服务在 `write` 锁和事务内，按操作声明的范围抓取 before：涉及的节点（含分组成员、引用同一 clip 的节点）、这些节点相关的连线、clip 行（以及 inputs 引用了这些节点的下游 clip）、剪辑节点指向的 `VideoEditings`。
3. 执行原操作。
4. 抓取 after。范围取 before 与原操作新建行的并集。
5. 把 `(label, before, after)` 压栈；超过 100 步时丢掉最早的一步。

**撤销**

1. 取栈顶一步，在同一把 `write` 锁和事务内比对当前行与 after。
2. 不一致：回滚，丢弃这一步，提示「内容已被修改，无法撤销这一步」。
3. 一致：写回 before。after 中有、before 中没有的行（新建的节点或 clip）改为软删除；before 中有、当前不存在的连线行重新插入（id 不变）。
4. 这一步移到重做栈，刷新画布。

**重做**：与撤销对称，比对 before、写回 after。

**失败路径**：写回时数据库报错，整步回滚，栈不变，按 `.agents/rules/error-handling.md` 提示并记录错误日志。

### 5.4 改动清单

#### NEW: `lib/shared/services/production/canvas_history.dart`

- `CanvasHistory`：每张画布一个实例，包含 undo/redo 栈（上限 100）、`canUndo`、`canRedo` 以及变更通知。
- `CanvasHistoryStep`：`label` 和 before/after 行快照（节点、连线、clip 的结构列、剪辑工程的 `deletedAt`）。
- `capture(scope)`、`restore(snapshot, expect:)`：抓取与写回；写回前做冲突检查。

#### `lib/shared/services/production/canvas_service.dart`、`group_service.dart`

- 可撤销的写方法（`addFree`、`addImage`、`addAudio`、`addMedia`、`addDirector`、`addText`、`addEditing`、`moveNodes`、`removeNode`、`removeNodes`、`ungroup`、分组创建与转换、输入的连接/断开/排序、文本内容与标题）加上可选参数 `CanvasHistory? history`。传入时在同一事务内完成抓取、执行、压栈。AI 工具路径不传这个参数。
- 每个方法声明受影响的范围；删除操作复用 `GroupService.members` 与 clip 引用查询，把级联的行都纳入范围。

#### `lib/shared/database/novel_content_daos/canvas_dao.dart`

- 新增按 id 写回节点整行（包括 `deletedAt` 归零）和按原 id 插入连线行的方法。不新增删除方法。

#### `lib/desktop/features/production/region.dart`、`board.dart`、`canvas_controls.dart`

- 在画布区域用 `useMemoized` 创建 `CanvasHistory`，画布 id 变化或离开页面时丢弃。
- 快捷键：Cmd/Ctrl+Z、Shift+Cmd+Z、Ctrl+Y；焦点在文本输入框时不处理。
- 缩放工具组旁边加撤销、重做按钮，带 tooltip，不可用时置灰。
- 用户直接操作的调用传入 `history`。

#### i18n

按 `.agents/rules/i18n.md` 新增 key 及 en / zh-CN 翻译：撤销、重做按钮的 tooltip，冲突提示，失败提示。

## 6. 验收标准

| 类别 | 标准 | 验证方式 |
|------|------|----------|
| 功能 | 每类可撤销操作（添加、删除、移动、调整大小、连线、断开、排序、文本、分组、解组、转换）撤销后行与操作前一致，重做后与操作后一致 | `test/shared/services/production/canvas_history_test.dart` 逐类比对行 |
| 功能 | 删除分组、删除剪辑节点，撤销后成员、连线、下游 inputs、`VideoEditings.deletedAt` 全部恢复 | 同上 |
| 范围 | 修改提示词、模型等参数，以及 AI 工具的写入，都不会入栈 | 服务测试 + 工具协议测试 |
| 冲突 | 记录之后，同一节点被其他路径修改，撤销被拒且数据不变，这一步被移出栈 | 服务测试 |
| 交互 | 快捷键和按钮都可用；焦点在输入框时 Cmd/Ctrl+Z 不触发画布撤销；栈满 100 步后丢掉最早的一步 | `test/desktop/features/production/` widget 测试 |
| 兼容 | 剧本作品制片画布的现有测试全部通过 | 运行现有 production 测试 |

```bash
fvm flutter test test/shared/services/production --timeout 120s > /tmp/cu_service.log 2>&1
fvm flutter test test/desktop/features/production --timeout 120s > /tmp/cu_desktop.log 2>&1
```

## 9. 风险

| 风险 | 触发条件 | 影响 | 对策 |
|------|----------|------|------|
| 受影响范围声明漏项 | 新增或修改写方法时，没有把级联行纳入范围 | 撤销后数据不完整 | 每个可撤销方法都有一条「撤销后行与操作前完全一致」的测试 |
| 后台任务改了节点 | 生成完成后登记结果、派生节点放置 | 撤销被冲突检查拒绝 | 冲突时只丢弃这一步并提示；这是预期行为 |
| 内存占用 | 大分组反复删除与撤销 | 快照占用内存 | 只保存受影响的行，并有 100 步上限；导演台和剪辑也是同样的上限 |

## 10. 已知妥协

1. 妥协：离开画布后撤销记录清空，之前误删的内容在界面上无法找回（数据仍然是软删除状态）。
   - 原因：与导演台、剪辑保持一致；用户已确认只保存在内存里。
   - 影响：跨会话的误删仍需要手动处理。
   - 升级触发：用户反馈跨会话误删。
   - 后续方向：让回收站支持画布节点。
