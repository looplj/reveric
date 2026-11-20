---
name: 画布构图指南
when_to_use: 操作构思画布，用于梳理剧情、分支、因果、关系、伏笔或灵感。按集制作画布、人物参考图与媒体节点、导演台操作使用「剧本工具使用规范」。
description: 按任务组织构思画布的节点、资源引用、连线与布局，表达剧情结构、分支、关系和灵感。
agent_scopes: [chat]
---

# 画布构图指南

先明确这张图要帮助用户看清什么，再选择节点、连线和布局。已有内容优先引用，尚未落地的构想与补充说明使用便签。

## 适用范围

本技能操作 `/canvas/{name}` 构思画布。按集制作节点、素材输入、导演台人物与机位属于剧本制片任务，加载「剧本工具使用规范」对应附件，不另建构思画布代替。

## 按场景读取 reference

| 任务 | Reference | 关注点 |
|---|---|---|
| 梳理主线、时间线、节拍，分析事件因果 | `references/story-structure.md` | 事件粒度、先后与因果、主支线 |
| 设计或修改选择分支、多结局、汇合与循环 | `references/branching-story.md` | 决策与选项命名、后果、路线连续性 |
| 展示人物势力关系、追踪伏笔与兑现 | `references/relationships.md` | 真实资源、关系语义、铺垫与回收 |
| 整理灵感、收集资料、比较创作方案 | `references/idea-board.md` | 分组、候选方案、待核实内容 |

正文已有准确附件路径时直接用 `reference-get` 读取选中文件，未知路径时再用 `<skill_resources>` 中的 `reference-list` 列目录；`name` 使用「画布构图指南」，`path` 使用正文或目录中的准确路径。只读取本次任务涉及的附件，已经读过且仍在上下文中的不重复读取。单纯打开、改名、改一句便签或执行指定布局时，使用下方共同契约即可，不必加载场景附件。混合任务按需追加附件，不把某个场景的规则套到整张图。

## 共同原则

- 梳理已有内容时以原文为依据，不为凑图添加未经要求的事实；创作构想与待核实内容明确标注。
- 只要求画图时，不顺带重写正文、创建场次或修改实体关系。引用节点保留原资源标题，需要说明时添加便签。
- 局部修改保留无关节点、连线与坐标，不清空重建整图。需要新增或删除哪些内容，以本次用户要求为准。

## 构思画布的文字与配色

- **标题直接说明内容。** 事件写发生了什么，决策写要决定什么，资料写主题；具体命名按场景附件执行。
- **便签正文 1 至 3 行。** 一张表达一个事件、想法或说明；长内容保留在原资源中，画布使用引用节点，不把整段正文抄成便签。
- **连线标签简短且有辨识度。** 写清不看标签就会误解的关系；长解释放到对应便签，不为缩短标签删掉关键信息。各场景中哪些边必须标注、标签应写什么，见对应附件。
- **颜色是分组，不是装饰。** 同一张图中保持同色同义，一张画布不超过三种色；标题与标签仍须独立可读，不能只靠颜色表达含义。
- **便签和引用节点都能设色。** 便签总有颜色，不传时为 `sand`；引用节点默认不着色，左侧图标按资源类型区分，只在需要分组或强调时才给它设色，不要为了好看给所有引用都上色。

低饱和纸色适合大面积分组：

| 纸色 | 默认用途 |
|---|---|
| `sand` | 主干事件、节拍或主要内容 |
| `sage` | 设定、世界规则、背景资料 |
| `rose` | 冲突、风险、代价，代表「要出事」 |
| `stone` | 幕标题、备注、待办与元信息 |

鲜艳色 `red` / `orange` / `yellow` / `green` / `teal` / `blue` / `purple` / `pink` 醒目，适合少量强调：标出关键转折、区分两三条路线或阵营、标记用户点名要关注的节点。不用鲜艳色铺满整张图，也不和纸色混出同义的两种颜色（例如「风险」既用 `rose` 又用 `red`）。

用户点名要某种具体颜色（如品牌色、「跟封面一样的墨绿」）而预设没有时，用自定义色 `#RRGGBB`；其余情况优先用预设。用户已经手动设的颜色（包括自定义色）视为用户的分组意图，局部修改时保留，不擅自改色。场景特有的分组方式见对应附件；同一张图内不要让同一种颜色承担互相矛盾的含义。

## 构思画布路径

本节只描述构思画布的调用。构思画布没有专用工具，全部走通用的 Read / Create / Write / Edit / Remove。完整字段和操作契约按需 `Read {"path": "/_schema/canvas"}` 获取，不向普通画布调用添加制作画布的类型或媒体输入字段。画布名唯一，它本身就是路径键：

| 目标 | 调用 |
|---|---|
| 有哪些画布 | `Read {"path": "/canvas"}`；`?search=` 匹配 name / description |
| 一张画布的概况 | `Read {"path": "/canvas/{name}"}` |
| 现有节点 | `Read {"path": "/canvas/{name}/nodes"}`；`?search=` 匹配 title |
| 现有连线 | `Read {"path": "/canvas/{name}/edges"}`；`?search=` 匹配 label |
| 摆位摘要 | `Read {"path": "/canvas/{name}/layout"}` |
| 新建画布 | `Create {"path": "/canvas", "fields": {"name": "主线时间线"}}` |
| 放一个节点 | `Create {"path": "/canvas/{name}/nodes", "fields": {...}}` |
| 连一条线 | `Create {"path": "/canvas/{name}/edges", "fields": {...}}` |
| 挪节点 / 改标题 / 改颜色 | `Write {"path": "/canvas/{name}/nodes/{node_id}", "fields": {...}}` |
| 整体覆盖便签正文 | `Write {"path": "/canvas/{name}/nodes/{node_id}/content", "value": "新的正文"}` |
| 局部替换便签正文 | `Edit {"path": "/canvas/{name}/nodes/{node_id}/content", "old_text": "原片段", "new_text": "新片段"}` |
| 删节点 / 删线 / 删画布 | `Remove {"path": ...}` |
| 打开给用户看 | `Write {"path": "/canvas/{name}/open", "value": true}` |
| 按当前布局整理 | `Write {"path": "/canvas/{name}/layout", "value": "tidy"}` |
| 自动布局（按行摆放，按连线调列） | `Write {"path": "/canvas/{name}/layout", "value": "auto"}` |
| 层级排列，从左到右 | `Write {"path": "/canvas/{name}/layout", "value": "tree_lr"}` |
| 层级排列，从上到下 | `Write {"path": "/canvas/{name}/layout", "value": "tree_tb"}` |
| 网格排列 | `Write {"path": "/canvas/{name}/layout", "value": "grid"}` |

画布名唯一，可以从 `current_workspace_context` 或 `/canvas` listing 拿到后直接拼 `/canvas/{name}`。`/canvas/{name}` 本身可写 `name` 与 `description`；边支持 Read / Create / Remove，不支持 Write / Edit；更改连线须先 Remove，再 Create。画布改名后，后续调用使用 Write 返回的新 `path`。

**先打开再动手。** 要在某张已有画布上作业时，先 `Write /canvas/{name}/open` = `true` 把它打开到用户面前，用户才看得见你在画什么。

连边时使用节点 listing 或 Create 返回的 `id`，分别填入 `source_node_id`、`target_node_id`。

## 字段

**节点**（`Create /canvas/{name}/nodes`）：`type` 必填，取 `reference` 或 `sticky`；两种类型的必填项不同。

| type | 必填 | 说明 |
|---|---|---|
| `reference` | `ref_type` + `ref_id` | 指向已有资源。`title` 是资源标题的缓存，传了会被忽略 |
| `sticky` | `content` | 便签正文。允许空串，但字段不能省；`title` 可选，作便签抬头 |

`ref_type` 取值：`character`、`faction`、`skill`、`item`、`location`、`chapter`、`foreshadowing`、`creature`、`outline`、`document`、`screenplay_scene`。场次 ID 从 `/scenes` 读取；`document` 可来自 `/lore` 或 `/materials`。`ref_id` 从对应集合的 listing 原样复制；指向不存在的资源返回 `invalid_reference`，节点不会建出来。

创建时推荐用 `col` + `row`，或 `near`（同画布已有节点 id）+ `direction`（`right` / `left` / `above` / `below`）摆位。构图优先用 `col`/`row`，工具仍支持 `x`/`y` 像素坐标以及小数。`color` 取值为「文字与配色」中的 4 个纸色、8 个鲜艳色，或自定义 `#RRGGBB`；便签不传时为 `sand`，引用节点不传则不着色。`width` / `height` 是可选的创建参数，支持小数，创建后只读。

创建和移动响应返回实际 `x` / `y`、`col` / `row` 和 `adjusted`，后续以返回的位置为准，不把请求中的坐标当成最终落点。

**节点更新**（`Write /canvas/{name}/nodes/{node_id}`）：可更新 `type`、`ref_type`、`ref_id`、`col`、`row`、`x`、`y`、`title`、`content`、`color`（写 `null` 清除颜色，便签随之回到 `sand`）；除 `type` / `ref_type` 外也可使用单字段路径。`title` / `content` 仅转换后的类型为便签时可改；引用标题来自原资源，不能用 Write 覆盖。Write 的 `near` / `direction` 在同时写 `col` / `row` 时用于相对摆位；同时给 `x` / `y` 则优先像素坐标，单独 `near` / `direction` 不会触发移动。`width` / `height` 创建后不可写。`Edit` 只用于便签的显式 `/content` 路径。整体覆盖正文也可在节点 Write 的 `fields.content` 中提交。

**原地转换与更换引用**：便签转引用时，在同一次 Write 的 `fields` 中提交 `type=reference`、`ref_type`、`ref_id`；已有引用只换目标时可单写 `ref_id`，换资源类型时同时提交 `ref_type` 与 `ref_id`。转回便签写 `type=sticky`，引用字段自动清空，可同时写 `title` / `content`。转换保留节点 ID、位置和连线；原便签正文保留，引用状态下不展示，转回便签后复用；标题转引用时改用资源标题，转回时可显式重命名。引用不存在或转换使已有连线语义不合法时，整次 Write 失败，不必先删再建。

**读取边界**：节点详情返回自身 `id`、类型、引用信息、标题、位置和尺寸；所有节点都有 `color`，未着色的引用节点读到 null；便签详情另有 `content`，节点 listing 不带正文。`near` / `direction` 是操作参数，不是可读字段。画布自身只承载名称、描述与节点／边数量，节点和边字段应从各自子路径读取。

**边**（`Create /canvas/{name}/edges`）：`source_node_id`、`target_node_id`、`type` 必填，`label` 可选。`type` 取值见下表。

| 边类型 | 用途 | 方向与线型 |
|---|---|---|
| `timeline` | 剧情或时间推进 | 实线带箭头 |
| `causal` | 事件导致后果 | 实线带箭头 |
| `relationship` | 人物、势力等关系 | 无箭头 |
| `foreshadow_payoff` | 伏笔引用指向兑现章节引用 | 长虚线带箭头，端点有类型限制 |
| `association` | 资料、设定等补充关联 | 无箭头 |

边的方向由 source → target 决定，不由节点坐标决定；标签是作者说明，不执行条件或状态。

## 便签与连线调用示例

在已有画布上依次执行；把 `{name}` 换成画布名，把两个节点 Create 返回的 `id` 分别填到 `{first_node_id}` / `{second_node_id}`：

```text
Create {"path": "/canvas/{name}/nodes", "fields": {"type": "sticky", "title": "起点", "content": "发现线索", "color": "sand", "col": 0, "row": 0, "width": 280.5, "height": 168.5}}
Create {"path": "/canvas/{name}/nodes", "fields": {"type": "sticky", "content": "追查线索", "col": 1, "row": 0}}
Write {"path": "/canvas/{name}/nodes/{first_node_id}/content", "value": "发现新的线索"}
Edit {"path": "/canvas/{name}/nodes/{first_node_id}/content", "old_text": "新的", "new_text": "关键"}
Create {"path": "/canvas/{name}/edges", "fields": {"source_node_id": "{first_node_id}", "target_node_id": "{second_node_id}", "type": "causal", "label": "触发追查"}}
Read {"path": "/canvas/{name}/layout"}
Write {"path": "/canvas/{name}/layout", "value": "auto"}
Write {"path": "/canvas/{name}/open", "value": true}
```

边的 `label` 也不能用 Write 修改；先读取边、保留两端节点 ID，再删除并重建。

## 先看清场地

动手前先 `Read /canvas/{name}/nodes` 读取现有节点；增删分支或调整关系时，同时读取 `/canvas/{name}/edges`。需要全图判断时按 `offset`/`limit` 翻页取全，不能把第一页当成整张图。局部文字修改只读取目标节点及相关资源，不重建整图。空画布可从 `col=0, row=0` 起步；已有图先识别本次要接入的节点与连线，避免重复创建。

`Read /canvas/{name}/layout` 的 `value.off_grid` 是不在原追加网格点上的节点数，仅 `auto` 保持这些节点不动。`tree_lr`、`tree_tb` 和 `grid` 会重新排列整张画布，包括手动摆放的节点。`tidy` 按 `value.mode` 重跑一次，`value.mode` 为 null 时按 `auto` 整理。`value.mode` 是上次成功使用的布局，null 表示尚未选择；`tidy` 不会改变它。

## 通用摆位与连线规则

几何事实（手动摆位时按这些数算，不凭感觉）：

| 项 | 数值 |
|---|---|
| 网格步长 | 列距 400、行距 248 |
| 便签默认尺寸 | 280 × 168 |
| 引用节点默认尺寸 | 256 × 62 |
| 相邻两列默认便签的净空 | 120px，需给连线与标签留出空间 |

- **手动摆位时，有边的两个节点尽量同行相邻或同列上下。** 斜连时把中间位置留空，避免曲线穿过卡片；长标签放到说明便签中。使用层级布局时交给布局处理，不再逐节点精修坐标。
- **控制阅读宽度。** 手动分行时，一行约六个节点可作为起点；内容多时按当前场景的主题、幕或阶段组织，不为满足数量限制删减内容。层级布局按图结构排列，不人为限制每层节点数。
- **使用 `auto` 时，作为骨架的主干必须是节点最多的那一行。** 数量打平时取最上面一行，其余行围绕它重排。只有严格落在网格点上的节点才参与；网格外节点保留原位，其余节点绕开它们。各场景如何组织主干与支线，见对应附件。
- **`auto` 分行时尽量让同类节点同行。** 引用与便签高度不同，混排容易让行内基线参差。`tree_lr`、`tree_tb` 和 `grid` 支持不同尺寸混排，不必为了对齐把资源引用抄成便签。
- **连线表达关系，位置不能代替关系。** 需要保留的结构用合适的边显式连接；没有关系的说明、标题和资料可以不连线，不为消除孤点或填满画面补线。

## 布局与收尾

| 布局 | 何时使用 |
|---|---|
| `tree_tb` | 分支剧情、影游与纵向因果：从上到下展开，选项在决策点下方并排；允许不同尺寸节点混排 |
| `tree_lr` | 线性推进链等横向阅读的有向结构，用户明确要求横向时也用它 |
| `grid` | 资料清单、灵感便签等以浏览为主的内容 |
| `auto` | 按上方通用规则和场景模板先摆好各行，再整理既有行布局；保留网格外节点 |

布局由图的用途决定，人物关系和灵感板无需满足剧情树的入口、分支标签或结局要求。有至少两个节点时，层级排列要求有效有向边；不要为通过排列校验给无向关系虚构方向。

新建图在节点和连线全部写入成功后，读取核对并执行一次所选布局。用户只要求整理已有图、或在已有图上增删节点连线之后，写 `tidy`，不要换成别的布局。局部文字修改不触发整图排列，执行层级或网格排列后不再追加 `auto`：`auto` 会把画布切回自动布局。

layout 接受 `tidy / auto / tree_lr / tree_tb / grid`。成功响应返回 `ok / path / updated`；节点位置或保存的布局模式发生变化时 `updated=true`，都未变化时为 false。Read layout 将 `node_count`、`edge_count`、`off_grid`、`grid_pitch` 及实际保存的 `mode` 放在 `value` 中。缺少有效有向边时返回 `failed_precondition`，先检查图的用途与连线，不要自行换算法掩盖问题；计算期间图有变化时返回 `conflict`，重读后再重试，不用逐节点坐标写入绕过冲突。未知布局返回 `invalid_argument`。

open 只接受 `true`，成功响应仅为 `{"ok": true}`；它只用于打开画布，不支持 Read，也不能放进画布 Write 的 `fields`。layout 同样需要自己的字段路径。

## 交付前自检

- 本次写入是否实际成功？引用是否有效，资源 ID 和节点 ID 是否区分清楚？
- 连线是否有明确含义，两端与方向是否正确？有没有只靠位置表达关系？
- 标签是否读得清，长说明是否已放入对应正文？便签是否只表达一件事，长内容是否使用引用？
- 颜色是否不超过三种，同色是否同义？鲜艳色是否只用于少量强调？具体场景要求的主干或分组配色是否一致？
- 使用 `auto` 时，骨架行是否节点最多？是否有不打算保留的网格外节点？
- 新建图是否在所有写入成功后执行了一次合适布局？局部修改是否保留无关坐标，没有额外重排？

再按已读附件核对对应场景的问题，报告实际完成范围与待核实项；工具失败时不能声称完成。

## 通用反模式

- 满屏无明确含义的 `association`，或为了消除孤点给所有说明都连线。
- 在连线上堆长段文字，遮住曲线或卡片；把已有资源的长正文抄成便签。
- 对层级布局套用 `auto` 的分行、同类节点同行规则，排列后又追加 `auto`。
- 用 `x` / `y` 精修 `auto` 的网格节点，导致偏离网格后不参与重排。
- 凭印象拼资源或节点地址：节点路径从 listing 的 `entries[].path` 或 Create 响应的 `path` 复制，资源 ID 从响应的 `id` 复制。
