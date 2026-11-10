# 画布作品：不依赖小说或剧本的独立制作

> 本文是[短剧制作方案](README.md)的分篇，定义第三种作品类型「画布」的功能合同。进度只在 README 的[实施任务](README.md#实施任务)维护（CW-01 至 CW-09）。
> 平台范围：桌面（Windows / macOS）提供完整功能；Android 不提供入口，只过滤数据。

## 1. 背景

### 现状

以下事实核对自 `unstable` / `44ad472`（2026-11-11）：

- 制作功能只能从剧本作品的「当前集」进入。`ProductionClips.episodeId` 为必填（`novel_content_database.dart:1481`），画布与剪辑都挂在集记录上：`ScreenplayEpisodes.canvasId`、`ScreenplayEpisodes.editingId`（:1186-1187）。
- 服务层到处校验集：`StoryboardService.requireEpisode` 有 24 处调用，`getEpisode` 有 28 处；`ProductionCanvasService.requireCanvas` 通过集反查画布；`EpisodeEditingOrchestrator.ensureEpisodeEditing` 首次打开剪辑时懒建 `VideoEditings` 并写回 `editingId`。
- 作品类型只有 `novel` 与 `screenplay`（`lib/shared/models/content_kind.dart`），各处多为「非剧本即小说」的二元判断。`novels.content_kind` 没有 SQL 约束。
- AI 资源定义集中在 `_resourceDefinitions`（`tools.dart:1087`），按顶层名字登记，`supports(kind)` 只认 `shared` 或与作品类型相同的 `group`（`tools_support.dart:720`）。顶层 `canvas` 已被构思画布占用，`clips` 已被剧本占用；`production` 只作为 `episodes/<id>` 的子路径出现，没有被当作顶层名字使用。
- 剪辑页左栏「已采用片段」读取本集分镜（`desktop/features/editing/assets.dart`）。普通生成结果不入素材库（`Assets.inLibrary` 默认 `false`），只有这一段能把它们带进剪辑页。

### 问题

- 症状：已经有现成剧本、只想做视频的用户，必须先建剧本作品，并在季、集、场次结构里录入内容，才能使用制作画布。
- 根因：制作数据的归属、画布与剪辑的定位、AI 路径，全部以集为锚点。
- 影响：直接做视频的用户被剧本结构挡住；AI 也会拿季、集、场次这些无关路径去操作。

### 约束

- 不改表结构，不升内容库 schema（当前 v2 已在 v0.8.2 发布）。
- 剧本作品的制作、剪辑、AI 行为保持不变；唯一新增是文本节点，两种作品共用。
- 本仓库会与上游双向合并：不移动、不重命名已有文件，新文件放在既有 feature 目录内。
- 移动端没有数据同步，不提供画布作品入口。
- 用户数据默认软删除。

## 2. 目标

### 目标

1. 首页新增「画布」书库，点新建直接进入一张全窗口制作画布，不需要先填写任何信息。
2. 画布上可以使用视频、图片、音频、上传素材、3D 导演台、宫格拆分与拼图、文本、剪辑节点。生成、采用、重做行为与剧本作品一致。
3. 文本节点不连线时是便签；连到视频、图片、音频节点时作为提示词输入。剧本作品每集的制片画布也提供文本节点。
4. 剪辑节点双击进入剪辑页，左栏能看到画布上视频节点当前采用的结果。
5. 聊天以右下角悬浮球和浮动面板提供，可以附加剧本文件。AI 只看到画布作品的路径，可以完成拆剧本、建节点、生成和剪辑。

### 非目标

1. 移动端的画布作品入口、浏览或编辑。
2. 季、集、场次、分镜编号、主体（角色、场景、道具）管理，以及原文视图和列表视图。
3. 新建作品弹窗的改版。
4. 画布作品与剧本作品互相转换。
5. 剪辑节点的回收站恢复界面。画布内误删通过[制片画布撤销](canvas-undo.md)恢复，离开画布后的情况见[已知妥协](#10-已知妥协)。

### 成功信号

| 信号 | 验证方式 |
|------|----------|
| 书库点新建后进入空画布，库里只有 `Screenplays` 根记录和一张 `kind = production` 的画布 | 服务测试 + 桌面手动检查 |
| `episodeId = ''` 的 clip 可以生成、采用、导入剪辑，剧本作品回归不变 | 服务测试 + 现有 production 测试 |
| 文本节点内容出现在实际提交的提示词中：被引用标签引用的在标签位置展开，未被引用的按顺序放在开头 | 生成编排单测（检查请求快照） |
| 画布作品的 AI 访问 `episodes`、`scenes` 等路径时被拒绝，`production/...` 可读写 | 工具协议测试 |
| Android 书库和继续写作不显示画布作品 | 移动端 widget 测试 |

## 3. User Stories

1. 作为已有剧本的用户，我希望新建画布后直接上传剧本给 AI，让它把剧本拆成节点，以便不用先在应用里重建剧本结构。
2. 作为直接做视频的用户，我希望写一段文本连到多个视频节点，以便共用人物和风格描述，而不必在每个节点里重复。
3. 作为用户，我希望在画布上放多个剪辑节点做不同版本，在剪辑页里直接拖入画布上采用的视频。
4. 作为用户，我误删剪辑节点后，剪辑数据不会被物理删除。
5. 作为维护者，我希望剧本作品的制作链路保持原样，画布作品只在定位画布、剪辑和 AI 路径时分支。

## 4. 解决方案

### 方案对比

| 方案 | 做法 | 优点 | 缺点 | 结论 |
|------|------|------|------|------|
| A | `ProductionClips.episodeId` 改为可空 | 语义准确 | 需要 schema v3、`TableMigration` 重建表和全版本升级测试 | 放弃 |
| B | 画布作品建一条隐藏集，id = novelId | 现有集校验、`canvasId`、`editingId` 全部可用 | 库里存在用户看不到的季和集；剧本相关查询需要防止误读 | 放弃（用户选择 C） |
| C | `episodeId` 写空字符串，不建集；画布按 `kind` 定位，剪辑作为画布节点 | 不改表、不建虚假结构；剪辑可以有多个 | 服务层需要在空字符串时分支 | **采用** |

### 决策

采用方案 C。理由：

1. 不改表结构，不增加迁移风险。
2. 不制造用户看不到的剧本结构，作品类型的边界清楚。
3. 剪辑作为节点放在画布上，既解决了「没有集，剪辑挂在哪」的问题，又自然支持多个版本。

### 用户操作与信息归属

**新建**：首页「画布」书库 → 新建 → 直接创建作品并进入画布。标题使用不重复的默认值（「未命名画布」「未命名画布 2」……，因为书架要求标题唯一），可在顶栏修改。

**画布页**：整窗画布，没有侧栏。顶栏：返回书库、可编辑标题、默认风格、比例和清晰度（新建节点的默认值）。没有剪辑入口。

**空画布**：显示三个起点。

- 上传剧本：打开聊天面板，并弹出文件选择；选中的文件作为聊天附件。
- 写提示词：新建一个视频节点并聚焦它的提示词。
- 导入素材：沿用素材导入，生成素材节点。

**剪辑**：从添加菜单加剪辑节点，双击整窗进入剪辑页，剪辑页里有返回画布的按钮。

| 内容 / 状态 | 保存该内容的业务对象 | 可编辑入口 | 其他视图如何使用 | 修改后的影响 |
|-------------|--------------------|------------|------------------|--------------|
| 默认风格、比例、清晰度 | `Screenplays` 根记录 | 顶栏；AI `production/settings` | 新建节点时取默认值；风格为 null 的节点继承 | 只影响之后新建的节点和继承风格的节点 |
| 生成节点的提示词、模型、输入 | `ProductionClips`（`episodeId = ''`） | 节点编辑区；AI `production/clips/<id>` | 画布连线由 inputs 推导 | 已提交任务使用快照，不受影响 |
| 文本内容 | `CanvasNodes.content`（`type = text`） | 节点内编辑；AI `production/canvas/nodes/<id>` | 下游节点生成时读取 | 下次生成生效，已有结果不变 |
| 剪辑时间线 | `VideoEditings`，由 `CanvasNodes`（`type = editing`）的 `refId` 指向 | 剪辑页；AI Run `editing` | 节点卡片显示标题、时长和首帧 | 删除节点时一起软删除 |
| 采用结果 | `ProductionClips.adoptedAssetId` | 节点生成历史 | 剪辑页左栏「已采用片段」 | 替换采用后，左栏随之更新 |

### 核心原则

1. 剧本作品的数据与行为不变（文本节点除外，两种作品共用）；画布作品只在「怎么找画布、怎么找剪辑、AI 能看到什么」这三处分支。
2. `ProductionClips.inputs` 仍然是输入关系的唯一真源，文本连线也遵守这一点。
3. 画布作品只有一张 production 画布，剪辑工程由剪辑节点持有，不再另存关联。
4. 不新增列，不新增 SQL 约束。

### 关键假设

| 假设 | 如果不成立 | 应对 |
|------|------------|------|
| 画布作品库里只有一张 `kind = production` 的画布 | 出现多张时定位歧义 | 创建时在同一事务内检查；读取时按 `createdAt` 取最早的一张并记录 error 日志 |
| 剧本作品的 clip 不会出现 `episodeId = ''` | 空字符串分支被误触发 | 空字符串分支同时校验作品类型为 `canvas` |
| 现有聊天附件可以读取 txt/md 剧本 | 上传剧本这一起点不可用 | 已核实现有附件链路可读，本次不改 |

## 5. 方案实施

### 5.1 模型设计

不改表，只新增约定值：

```text
novels.content_kind        新增 'canvas'
ShortEntityIdType.canvas   ID 前缀 'cnv'
CanvasNodes.type           新增 'text'、'editing'
  text:    content = 文本正文；refType/refId 为空；剧本作品与画布作品都可用
  editing: refType = 'editing'，refId = VideoEditings.id；只在画布作品中使用
ProductionClips.episodeId  画布作品写 ''，sceneId = null，sortOrder = null
ProductionInput.role       新增 'prompt'，只能引用 text 节点（ref_type = node）
```

画布作品的内容库只包含：一条 `Screenplays` 根记录（存默认风格、比例、清晰度）、一张 `Canvases(kind = production)`，以及其下的节点、clip、剪辑和导演工程。不创建季、集、场次。

### 5.3 关键业务流程

**新建画布作品**

1. `NovelActions.create(contentKind: canvas)` 生成 `cnv` 前缀 ID 和不重复的默认标题。
2. `_initializeContentDatabase` 的 canvas 分支：写入 `Screenplays` 根记录（`initialProductionStyle` 给默认风格）和一张 production 画布。不写小说默认工作区，也不打开 onboarding。
3. 注册作品；任一步失败时沿用 `_discardUnregisteredContentDatabase` 清理。
4. 打开 `WorkspaceEditorPage`，按作品类型进入画布作品页。

**定位画布与校验 clip**

1. `ProductionCanvasService` 新增按作品定位：画布作品取唯一一张 production 画布（不存在时在事务内创建）。
2. `requireEpisode('')`：作品类型为 canvas 时直接通过，否则抛 `episode_not_found`。
3. `requireCanvas` / `requireNode` / `addFree` / `addImage` / `addAudio` 在 `episodeId = ''` 时跳过 `episode.canvasId` 比对，改为确认画布属于本作品。
4. `ensureCanvas` 的场次派生在画布作品中不执行（没有场次）。

**文本作为提示词**

1. 用户从文本节点的输出口拖到视频、图片或音频节点，或由 AI 写 inputs。
2. 服务校验：来源必须是 text 节点，目标必须是生成节点，用途固定为 `prompt`；文本连文本拒绝。
3. 文本输入和媒体输入一样，可以在提示词里用 `<ref input_id label />` 标签引用，标签显示文本节点标题。
4. 生成时：被标签引用的文本输入，在标签位置展开为文本内容（同一输入可多次引用）；没有被引用的文本输入，按 inputs 顺序放在提示词开头，用换行连接；空文本展开为空。构建服务商请求前移除 `prompt` 输入（它不是媒体文件）。
5. 任务快照保存展开后的提示词。之后修改文本不影响已有任务和结果。

**剪辑节点**

1. 新建：同一事务内创建 `VideoEditings`（比例取作品默认值）和 `type = editing` 的节点。
2. 打开：双击节点 → 整窗进入剪辑页。剪辑页的身份由 `editingId` 决定，不依赖集。
3. 左栏「已采用片段」：列出本画布视频节点当前采用的结果，标题用节点标题，按节点创建时间排序；未采用的显示「未采用」。下方其他视频、图片、音频和导入按钮保持不变。
4. 删除：同一事务内软删除节点和对应的 `VideoEditings`。

**失败路径**

- 画布或剪辑记录缺失：节点显示失效状态，并提供删除操作；不自动重建同 id 的剪辑。
- 文本节点被删除：同一事务内从引用它的 clip 的 inputs 中移除对应的 `prompt` 输入，并删除提示词中引用该输入的标签，下游节点不保留失效引用。
- AI 访问不支持的路径：返回资源不存在的错误，说明画布作品可用的路径。

### 5.4 改动清单

#### 作品类型与创建

- `lib/shared/models/content_kind.dart`：新增 `contentKindCanvas = 'canvas'`，加入 `contentKinds`。
- `lib/shared/utils/short_entity_id.dart`：新增 `ShortEntityIdType.canvas` → `'cnv'`。
- `lib/shared/services/novel_actions.dart`：ID 前缀分支；`_initializeContentDatabase` 新增 canvas 分支；生成默认标题时避开书架已有标题。
- `lib/desktop/widgets/novel_create_submitter.dart`、`novel_form_dialog.dart`：只核对 canvas 不会走进这两个文件里剧本或小说的专属分支，不改弹窗本身。

#### 首页与书库

- `lib/desktop/pages/home.dart`：书库 `IndexedStack` 从二元改为三项，新增「画布」书库；新建按钮直接调用创建并打开。
- `novel_list.dart`、`resume_section.dart`、`resume_point.dart`、`collections/cover.dart`、`trash_settings_section.dart`：补 canvas 分支。继续写作直接打开画布；封面使用默认封面。
- `lib/shared/services/canvas_export/validate.dart:48`：canvas 作品走制作画布导出校验，不按构思画布处理。

#### 画布作品页（桌面）

- `lib/desktop/pages/workspace_editor_page.dart:50`：canvas 作品打开画布作品页。
- NEW `lib/desktop/features/production/canvas_work.dart`：画布作品页。由顶栏、画布区域和悬浮聊天组成，不经过 `NovelEditorPage`。聊天沿用剧本作品制片页的做法：`productionChatProvider`、region 的 `chat` 插槽（`region.dart:92-213`、`:250-273`）和悬浮外壳 `floating.dart`；「上传剧本」选好文件后，通过 region 已有的 `ask(prompt, files:)`（`:153-156`）带进聊天。
- `lib/desktop/features/production/region.dart`：抽出画布主体，使它能接收「作品级画布」而不是 `workspace.episodeId`。片段节点、场次色带、分镜编号和跳剧本入口只在剧本作品中显示。
- 添加菜单（`region.dart` / `canvas_controls.dart`）：加入「文本」（两种作品都有）和「剪辑」（只在画布作品中显示）。
- `node_card.dart`：新增文本卡片和剪辑卡片，沿用 `canvasGlassFill` / `canvasGlassBorder`、选中环和浮动操作条。
- `board.dart:774-797`：连线校验加入 text → video/image/audio。
- `input_preview.dart`：`prompt` 输入显示两行文字摘要，角标为「文本」；菜单只有调整顺序和断开。
- `prompt_field.dart`、`prompt_controller.dart`、`composer.dart`：引用插入菜单包含文本输入，标签显示文本节点标题。
- `desktop/features/editing/{shell,region,assets}.dart`：身份从 `({path, episodeId})` 改为可以只有 `editingId`；`EditingAssets` 在画布作品中从画布视频节点取「已采用片段」。

#### 服务层

- `lib/shared/services/storyboard/service.dart`：`requireEpisode` 接受画布作品的空字符串；新增/创建 clip 时 canvas 作品写 `episodeId = ''`。
- `lib/shared/services/production/canvas_service.dart`：作品级画布定位；`requireCanvas` / `requireNode` / `addFree` / `addImage` / `addAudio` 的空 episode 分支；新增 `addText`、`addEditing`，删除剪辑节点时一起软删除 `VideoEditings`。
- `node_source.dart`、`derived_placement.dart`、`result_service.dart:73,179`、`effectiveStyle`、`setClipStyle`：读取设置统一走 `Screenplays` 根记录，不再经过集。
- `subject_references.dart:20-34`：内连接改为不丢弃 `episodeId = ''` 的 clip（画布作品没有主体，结果为空即可）。
- `generate_orchestrator.dart:167`、预览（:303-383）、`image_generate_orchestrator.dart:91`、`audio_generate_orchestrator.dart:335`：三处都已用 `StoryboardPrompt.parse` 逐段处理标签，在这里把引用 `prompt` 输入的标签展开为文本，未被引用的文本放到开头；构建请求前过滤掉 `prompt` 输入。
- `canvas_service.dart:1465` 的引用校验：`prompt` 输入可以被标签引用。
- `lib/shared/models/production` 的 inputs 模型：新增 `prompt` 用途。`VideoInputRole`（`models/video/request.dart:19`）不加，避免进入服务商请求。

#### AI

路径统一放在顶层 `production` 下，结构与剧本作品的 `episodes/<id>/production/canvas` 相同，只是去掉了集前缀。`production` 不与现有顶层名字重名，所以 `_resourceDefinitions` 的查找方式不变，只新增 `group = canvas` 的定义。执行仍走现有函数（`tools_screenplay.dart:86-107` 按定义分发）。

- `tools_production_schema.dart`：新增画布作品定义，复用现有字段表（把 clips 等内联字段提成常量供两边共用）。
  - `production`：单例，只读，子资源 `settings`、`canvas`、`clips`。
  - `production/settings`：`style_id`、`ratio`、`resolution`，可读写。
  - `production/canvas`：单例，可写 `positions`、`remove_types`；子资源 `nodes`、`edges`。`remove_types` 增加 `text`、`editing`：移除文本节点时同时清理下游的 `prompt` 输入和标签，移除剪辑节点时同时软删除剪辑工程。
  - `production/canvas/nodes/<node_id>`：type 增加 `text`、`editing`；text 可读写 `content`；创建 editing 节点时同时创建剪辑工程，`ref_id` 即 `editing_id`。
  - `production/canvas/edges/<edge_id>`：只读。
  - `production/clips`：Create 新建分镜，与剧本作品一样由系统在画布上放置对应节点，只是不需要 `scene_id`、`episode_id`（系统写入 `episodeId = ''`）。
  - `production/clips/<clip_id>` 和 `generations`：去掉 `scene_id`、`episode_id`、`sort_order`、`is_storyboard`、`character_id`、`location_id`、`item_id`；inputs 用途增加 `prompt`。
- 剧本作品现有定义（`episodes/<id>/production/canvas/nodes`、`clips`）：nodes 的 type 增加 `text`、可读写 `content`；inputs 用途增加 `prompt`。其余字段与路径不变。
- `tools_screenplay.dart _executeScreenplay`：把画布作品的定义加入分发：nodes／edges／canvas 交给 `_executeProduction`，clips 交给 `_executeStoryboard`，settings 交给 `_executeScreenplayStyle`，generations 交给 `_executeProductionMetadata`。
- `tools_production.dart`：`_executeProduction` 开头的画布定位改为「有 `episode_id` 按集，否则取本作品唯一的 production 画布」，路径前缀相应换成 `production/canvas`；其余读、写、建、删逻辑不变。`_executeStoryboard` 在画布作品中写 `episodeId = ''` 并跳过场次与集校验。
- `tools_screenplay.dart _contentKindGate`、`tools_production.dart:529`、`stagings_run_command_handler.dart:64`、`tools_cross_work.dart:24`、`chat_turn_runner.dart:785`、`chat_session_controller.dart:2023,2066`、`spawn_agent_handler.dart:765`、`agent_council_orchestrator.dart:379`：补 canvas 分支。
- Run `production`：对画布作品开放。Run `editing`：仍以 `editing_id` 为参数；在画布作品中 `create` 同时创建剪辑节点；`production_clip_id` 导入时接受 `episodeId = ''`（`media/editing.dart:252`）。
- `media/nodes.dart:104,276`、`image_nodes.dart:216`、`panorama_nodes.dart:130`：画布作品返回 `production/canvas/nodes/<id>` 路径。
- `prompt_fragments.dart:118`：新增画布作品的作品描述。

#### Skill

按 `.agents/rules/agent-skills.md`：操作契约放在内置技能，制作方法放在官方技能，同一条契约只维护一处。两个工具技能共用的操作说明通过附件引用加载，不复制，见下文「附件引用」。

**内置技能按作品类型过滤**

- `lib/shared/services/bundled_control_skills.dart`：`_BundledControlSkillSpec` 新增 `contentKinds`（空表示全部作品类型），提供 `availableFor(kind)`；`BundledControlSkill` 带出该字段。`bundledControlCallNames` 加入「画布作品工具」。Run 命令到技能的映射改为按作品类型解析：画布作品中 `production`、`styles`、`stagings` 指向「画布作品工具」，其他作品不变。
- `lib/shared/services/ai/chat_turn_runner.dart:784-790`：去掉写死的两个 `if`，改用 `availableFor`；`:828` 按名称加载的回落路径同样检查作品类型（当前缺少这项检查）。
- `lib/shared/services/ai/tools_run.dart:550,2032,2070-2104`：Run help 和缺少子命令时的指引，按当前作品类型给出技能名。

| 技能 | 小说 | 剧本 | 画布 |
|---|---|---|---|
| 创作向导 | ✓ | | |
| 系统管理 | ✓ | ✓ | ✓ |
| 画布构图指南（构思画布） | ✓ | ✓ | |
| 剧本工具使用规范 | | ✓ | |
| 故事连续性维护 | ✓ | ✓ | |
| 媒体处理与剪辑 | ✓ | ✓ | ✓ |
| 画布作品工具（新增） | | | ✓ |

**NEW 内置技能「画布作品工具」：`assets/bundled_skills/canvas-work-tools/`**

- `SKILL.md`：
  - 界面名称对照：画布作品就是整窗的制作画布；画布上的视频节点就是「分镜」（一条可含多个 Shot），没有场次，也没有 `is_storyboard`；另说明文本节点、剪辑节点、素材节点、导演台、宫格组。「导出成片」指某个剪辑节点的剪辑工程，有多个剪辑节点时先确认是哪一个。
  - `production/...` 路径总览。画布作品没有 `/episodes`、`/scenes`、`/characters`、`/locations`、`/screenplay`、`/clips`，不访问这些路径；人物和场景的外观依据来自上传的剧本或文本节点。
  - 上传剧本：读取聊天附件（文件读取交给「媒体处理与剪辑」），按剧本顺序创建分镜并排版；共用描述写进文本节点的方法由「剧本制片」提供。
  - 定位：画布作品没有排序字段，成片顺序只由剪辑时间线决定。用户说「第 N 个分镜」时结合标题和对话上下文定位，无法确定就问用户，不按坐标或创建时间猜。
  - AI 的修改不进入用户的撤销记录，批量删除或批量移动前先确认范围。
  - 按任务读取附件的路由表。
- 附件的文件名和标题与「剧本工具使用规范」的同类附件一致，「剧本制片」用中性写法引用附件时，在两种作品中都能找到同名附件：
  - `references/production-canvas.md`（制作画布）
    - 画布作品自有：`production/settings` 与 `production/canvas` 的读写；节点的创建、移动、删除；剪辑节点与 `editing_id`；排版约定（分镜按剧本顺序逐行排列，文本节点放在下游节点左侧）；`remove_types` 可包含 `text`、`editing`（剪辑工程一起软删除），只在用户明确要求清理时使用；删除文本节点时，下游的 `prompt` 输入和对应引用标签一起移除。
    - 用 `<inline-ref>` 引用剧本版：「文本节点」「视频节点操作」「图片派生、预设与宫格」「全景取景」四节。
  - `references/clips.md`（分镜与媒体节点）
    - 画布作品自有：`production/clips` 的读取与创建（Create 不带 `scene_id`、`episode_id`，系统自动放置节点）。
    - 用 `<inline-ref>` 引用剧本版：「素材与输入关系」「文本输入」「提示词中的引用」「Seedance 合规校验」「生成与结果采用」五节。不引用「人物与地点图集名称」。
  - `references/styles.md`（视觉风格）
    - 画布作品自有：应用风格的路径表，`production/settings/style_id` 与 `production/clips/{clip_id}/style_selection`，以及写后回读。
    - 用 `<inline-ref>` 引用剧本版的「查询与自定义」一节。
  - `references/stagings.md`（导演文档）：直接登记剧本版文件。内容只用 `Run stagings`，与作品路径无关；加载器按 `/references/` 之后的部分命名附件（`bundled_control_skills.dart:262-269`），可以跨目录登记。剧本版第 19 行「导演命令需要剧本作品」改为「需要剧本或画布作品」。

**附件引用 `<inline-ref type="reference">`**

两个工具技能共用的操作说明不复制，在加载时把另一个内置技能附件中的小节展开进来。Mirroric 曾有 `<inline-ref type="skill">技能名</inline-ref>`（`PromptTemplateService.resolveInlineRefs`，整技能内联、找不到时保留原标签），技能改为按需加载附件后已删除；这里沿用标签名，按附件小节重新实现：

```markdown
<inline-ref type="reference" skill="剧本工具使用规范" section="视频节点操作">references/production-canvas.md</inline-ref>
```

- `lib/shared/services/bundled_control_skills.dart`：`_loadReferences` 读取附件后展开标签。`skill` 按 callName 找到内置技能的 spec，正文是该技能已登记的附件路径；`section` 取同名二级标题到下一个同级或更高级标题之前的内容，省略时取整个文件。只用于内置技能，官方技能和用户技能不处理。
- 找不到技能、附件或小节，或被引用的内容里又有 `<inline-ref>` 时抛 `StateError`。这与加载器现有的「缺失即失败、不返回部分结果」一致；上游改了标题时测试会直接失败，不会悄悄漏掉内容。
- 被引用内容中的相对链接（如 `[分镜与媒体节点](clips.md)`）在画布作品工具中指向同名附件，这也是两边附件同名的原因之一。
- `test/shared/services/bundled_control_skills_test.dart`：全部内置技能加载成功，展开结果中没有残留的 `<inline-ref`；小节截取的边界；缺失和嵌套时报错。
- `.agents/rules/agent-skills.md`「附件与内容归属」补一条：内置技能之间共用操作说明时用 `<inline-ref type="reference">` 按小节引用，不复制；被引用小节保持作品类型中性。

**「剧本工具使用规范」被引用小节改为中性写法**

被引用的小节要在两种作品中都成立，所以把其中写死剧本作品路径的地方改为中性写法；文本节点两种作品共用，说明写在剧本版，画布作品工具引用。只改这几处，不移动已有段落：

- `production-canvas.md`：新增「## 文本节点」：创建、`content` 读写、删除时下游的 `prompt` 输入和引用标签一起移除；`remove_types` 可包含 `text`。
- `clips.md`：在「素材与输入关系」之后新增「## 文本输入」：只能来自文本节点、只能连到生成节点；可以用 `<ref>` 标签放到提示词的指定位置，没有被引用的按 inputs 顺序放在提示词前；不占参考图数量；修改文本只影响下一次生成。

- `production-canvas.md:51`：「从当前作品目标集的画布读取」改为「从当前制作画布读取」。
- `production-canvas.md:66`：`node_path` 的示例路径改为「与画布读取结果中的节点路径一致」。
- `production-canvas.md:91`：`Read /clips/{clip_id}/generations/{task_id}` 改为读取该片段 generations 下的对应记录。
- `clips.md:25`：「以 `/_schema/clips` 为准」改为「以片段的 schema 为准」。
- `clips.md:29`：「读取当前集节点」改为「读取当前画布节点」。
- `clips.md:87`：`Read /clips/{clip_id}/generations` 改为读取该片段的 generations。
- `styles.md`：第 3 行前加「## 查询与自定义」，第 30 行前加「## 应用到作品」，内容不变。

**「媒体处理与剪辑」「系统管理」**

- `assets/bundled_skills/media-editing/references/editing.md`：补充剪辑节点的说明。剪辑工程由剪辑节点持有，`editing_id` 从节点的 `ref_id` 取得；`Run editing create` 在画布作品中会同时创建剪辑节点。
- 这两个技能在三种作品中都可用，其中写死「剧本工具使用规范」的地方改为「当前作品的工具技能（「剧本工具使用规范」或「画布作品工具」）」：`media-editing/SKILL.md:3`、`media-editing/references/editing.md:3`、`management/references/providers.md:23,25`。

**官方技能「剧本制片」改为中性描述并升到 v5**

不新增画布作品专属附件，也不逐处加「仅剧本作品」的标注。分镜、场次、人物与场景图等概念对画布作品同样适用（画布上的视频节点就是分镜，上传的剧本也有场次），只改写死了某个工具技能或剧本作品数据结构的措辞。技能名称保留「剧本制片」：官方技能同步按名称识别，改名会让已安装用户的删除、停用和自定义状态失效，而保留旧名在画布作品中语义仍然成立。

具体改动：

- `SKILL.md`：
  - `when_to_use` 从「适用于剧本的“视频 / 制片”工作区任务」改为不限定工作区的「把剧本做成视频」任务描述，「将场次拆成分镜」改为「将剧本拆成分镜」。
  - 第 14 行「已编入场次的图片或视频制作条目」去掉「已编入场次」。
  - 第 18 行定义一次：路径、字段、素材引用和执行契约由当前作品的工具技能维护（剧本作品为「剧本工具使用规范」，画布作品为「画布作品工具」），下文简称「工具技能」。
- 主文件与附件中其余「剧本工具使用规范」（约 14 处，见 `SKILL.md:26,56`、`production.md:7,33,63`、`storyboard.md:45,50,67`、`video-prompts.md:46,77`、`image-references.md:58,75,83`、`model-capabilities.md:12,52,69`、`troubleshooting.md:3`）统一替换为「工具技能」。附件名（分镜与媒体节点、导演文档等）不变，两个工具技能都提供同名附件。
- `production.md`：
  - 第 7、16 行的「场次归属」改为「归属」。
  - 第 15 行「写入 `/clips`」改为按工具技能的分镜与媒体节点附件写入。
  - 第 71 行「按当前集与场次归属读取视频分镜……每集时长」改为按本次范围读取视频分镜，与用户说明或作品智能体规则中的目标时长对照。
  - 新增一段共用描述的写法：多个分镜共用的人物、场景或风格描述可以写进文本节点并连到这些节点，只影响单个分镜的内容直接写进它的提示词。
- `image-references.md:75`：「回读所属人物或地点图集」改为「有所属人物或地点图集时回读」，画布作品没有图集，按节点标题核对即可。
- `lib/shared/services/bundled_official_skills.dart`：v0.8.2 中该技能已是 version 4（已发布），因此升为 5，并更新 `contentHash`、`updatedAt`；附件清单不变。按规则用 SQLite 技能同步 Debug 库的官方安装快照（没有安装记录则不处理）。

#### 移动端

- `mobile/pages/workspace_editor_page.dart:39`、`mobile/features/library/resume.dart`、`collection_filter.dart:87`：过滤掉 canvas 作品。

#### i18n

按 `.agents/rules/i18n.md` 新增 key 及 en / zh-CN 翻译：内容类型名、画布书库标签、默认标题、文本节点、剪辑节点、空画布三个起点及其说明、失效剪辑提示。

### 5.5 Migration

无。不改表结构，内容库与应用库的 schema 版本都不变。`content_kind = 'canvas'` 只是新的取值，旧版本应用不会创建它。

### 5.7 业务监控与数据分析

本次不新增埋点，通过本地业务记录判断使用情况。

| 业务问题 | 指标及统计口径 | 数据来源 | 基线 / 判断依据 | 查看时机与后续行动 |
|----------|----------------|----------|-----------------|--------------------|
| 画布作品是否被使用 | 未删除的 `content_kind = 'canvas'` 作品数 / 全部作品数 | 应用库 `novels` | 新功能，没有基线，首次查看即为基线 | 发布后用自用及测试库抽查；占比过低时复查书库入口 |
| 是否走到成片 | 有采用结果的画布作品中，存在非空剪辑工程的比例 | 内容库 `ProductionClips`、`VideoEditings` | 同上 | 同上；比例低时检查剪辑节点是否容易被发现 |

## 6. 验收标准

| 类别 | 标准 | 验证方式 |
|------|------|----------|
| 功能 | 新建画布作品后直接进入空画布；库里有 `Screenplays` 根记录和一张 production 画布，没有季、集 | 服务测试；桌面手动 |
| 功能 | 画布作品的视频、图片、音频节点可以生成、采用、重做；clip 的 `episodeId = ''` | `test/shared/services/production/` 新增用例 |
| 功能 | 文本连到三类生成节点后：被标签引用的文本在标签位置展开，未引用的按顺序放在开头；服务商请求中没有 `prompt` 输入；删除文本节点后下游的输入和标签都被清理 | 编排单测检查请求快照 + 服务测试 |
| 功能 | 剧本作品每集的制片画布可以添加文本节点并作为提示词输入；剪辑节点只在画布作品的添加菜单中出现 | widget 测试 + 编排单测 |
| 功能 | 剪辑节点可以有多个；双击进入对应的剪辑；左栏列出视频节点的采用结果 | 服务测试 + `test/desktop/features/editing/` |
| 功能 | 删除剪辑节点后，节点与 `VideoEditings` 都被软删除（`deletedAt` 非 0） | 服务测试 |
| AI | 画布作品的 `production/settings`、`production/canvas`、`production/canvas/nodes`、`production/clips` 可用；`episodes`、`scenes`、`seasons` 被拒；剧本作品的路径不变，只是节点 type 增加 `text`、inputs 用途增加 `prompt` | `test/shared/services/ai/` 协议测试 |
| Skill | 各作品类型的技能列表、按名称加载、Run help 指向的技能都符合技能过滤表；画布作品无法按名称加载「剧本工具使用规范」等被过滤的技能 | `test/shared/services/bundled_control_skills_test.dart` + 聊天技能上下文测试 |
| Skill | 「画布作品工具」能加载三份自有附件和共用的 `stagings.md`，`<inline-ref>` 全部展开且内容来自剧本版对应小节；缺失或嵌套引用时加载失败；「剧本工具使用规范」的附件清单不变 | `bundled_control_skills_test.dart` |
| Skill | 「剧本制片」version 为 5，`contentHash` 与内容一致；主文件和附件中不再写死「剧本工具使用规范」，引用的附件名在两个工具技能中都存在 | `test/shared/services/bundled_official_skills_test.dart` + 附件名检索 |
| Skill | 用典型请求核对路由：剧本作品仍加载「剧本工具使用规范」及原附件；画布作品加载「画布作品工具」，不调用 `/clips`、`/episodes` 等剧本作品路径 | 按 `.agents/rules/agent-skills.md` 做静态路由核对，不声称模型触发准确率 |
| 兼容 | 剧本作品的制作、剪辑、AI 现有测试全部通过 | 运行相关目录现有测试 |
| 移动端 | 画布作品不出现在书库、继续写作和收藏筛选中 | 移动端 widget 测试 |
| 错误 | 剪辑记录缺失时节点显示失效状态，可以删除 | 服务测试 + widget 测试 |

测试命令按 `.agents/rules/testing.md` 串行执行，完整日志先写入文件再查看，例如：

```bash
fvm flutter test test/shared/services/production --timeout 120s
fvm flutter test test/shared/services/ai --timeout 120s
fvm flutter test test/desktop/features/production test/desktop/features/editing --timeout 120s
fvm flutter analyze lib/shared lib/desktop lib/mobile
```

## 7. 评测

- 被测能力：在画布作品中，AI 根据附件剧本拆出节点，并正确使用 `production/...` 路径。
- 不测内容：生成画面的质量。
- 输入来源：两份固定剧本样例（短篇单场、多场次）。
- 判定方式：确定性检查。节点数量与剧本段落是否对应，是否没有调用剧本专属路径，文本 inputs 是否合法。真实模型运行需要用户单独开启，不阻断交付。

## 8. AI 与运行成本

不新增自动调用。拆剧本、生成都由用户发起或在已授权的 Agent 会话中执行，计费口径与剧本作品的制作相同。文本输入会增加提示词长度，但单个请求增量受文本内容约束，不额外引入模型调用。

## 9. 风险

| 风险 | 触发条件 | 影响 | 对策 |
|------|----------|------|------|
| 空 episode 分支漏改 | 某个调用点仍调 `getEpisode(clip.episodeId)!` | 画布作品操作报错 | 全量检索 `requireEpisode`、`getEpisode`、`.episodeId` 的调用点逐一分类；画布作品的端到端服务测试覆盖生成、采用、导出、剪辑导入 |
| 二元作品类型判断遗漏 | 某处仍写「非剧本即小说」 | 画布作品被当作小说处理（例如打开 onboarding） | 检索 `contentKindScreenplay` 的全部比较点，并为 `canvas` 补测试 |
| 被引用小节的改动影响画布作品 | 上游修改或改名「剧本工具使用规范」中被引用的小节 | 改名时画布作品工具加载失败；改内容时画布作品的说明随之变化，可能重新写死剧本作品路径 | 加载器缺失即失败，测试能发现改名；被引用小节保持中性写法，合并上游时检查这些小节是否新增了剧本作品专属路径 |
| 「剧本制片」等技能改为中性描述后与上游冲突 | 上游同时修改这些附件 | 双向合并时 SKILL.md 和约 8 份附件出现冲突 | 只替换技能名和少数写死结构的句子，不调整段落和顺序；合并时按「上游内容 + 本地中性替换」处理 |
| 画布作品定义与剧本定义共用字段常量 | 提取 clips 等字段常量时改动了剧本作品的字段表 | 剧本作品 AI 契约变化 | 提取只做搬移；用现有协议测试和 `_schema` 输出比对作回归 |
| 多张 production 画布 | 并发创建 | 节点被分到两张画布上 | 创建放在事务内并做存在性检查 |

## 10. 已知妥协

1. 妥协：剪辑节点删除后，只能在离开画布前通过[撤销](canvas-undo.md)恢复。
   - 原因：撤销记录只保存在内存里；回收站目前只处理作品级数据，不处理画布节点或剪辑工程。
   - 影响：离开画布后，数据仍是软删除状态，但用户无法自行恢复。
   - 升级触发：用户反馈跨会话误删。
   - 后续方向：让回收站支持画布节点。
2. 妥协：画布作品不能转换成剧本作品，反过来也不行。
   - 原因：两者的数据锚点不同（集 vs 作品）。
   - 影响：用户需要重新建作品。
   - 升级触发：用户有转换需求。
   - 后续方向：提供单向导入，把剧本作品某一集的节点复制到画布作品。
3. 妥协：移动端完全看不到画布作品。
   - 原因：移动端没有制作功能，也没有数据同步。
   - 影响：备份恢复到移动端后，画布作品被隐藏。
   - 升级触发：移动端加入制作功能。
