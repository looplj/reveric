# 制作画布

读取 `production/settings` 获取默认设置，通过 Write 修改 `style_id`、`ratio`、`resolution`。默认值不会覆盖已有节点的独立配置；视觉风格的继承规则见 [视觉风格](styles.md)。

## 节点与布局

读取 `production/canvas` 或其 `nodes` 获取节点身份与连线。用 Create 在 `production/canvas/nodes` 创建节点，节点 `type` 与可写字段以 `/_schema/production/canvas/nodes` 为准（片段输入与生成配置由「画布作品工具」的节点片段入口负责）。

```json
{"path":"production/canvas/nodes","fields":{"type":"video","title":"门口对话","x":420,"y":0}}
{"path":"production/canvas/nodes","fields":{"type":"text","title":"人物与风格","content":"本次已确认的共用描述","x":0,"y":0}}
{"path":"production/canvas/nodes","fields":{"type":"editing","title":"剪辑版本 A"}}
```

创建剪辑节点会同时创建剪辑工程；节点的 `ref_id` 就是 `editing_id`。双击节点进入剪辑，时间线操作使用「媒体处理与剪辑」。删除剪辑节点会同时移除该工程，不自动重建失效工程；失效卡片仍可删除。

分镜按剧本顺序逐行排列，文本节点放在其下游节点左侧，保留已有用户布局。移动单个节点用它的返回路径写入 `x`、`y`；多节点联动使用一次 Write 提交 `production/canvas` 的 `positions`。空间位置不决定时间线顺序。

```json
{"path":"production/canvas","fields":{"positions":[{"id":"{node_a}","x":0,"y":0},{"id":"{node_b}","x":420,"y":0}]}}
```

新建节点只会避开已有节点向下找空位，不按连线摆放，一轮新增后容易挤成一列。完成一批创建、连线、派生或用户要求整理画布时，调用 `Run` 的 `production` `canvas-preview` 查看画布渲染预览图（坐标网格、卡片尺寸与缩略图、实/虚线连线及红色重叠高亮），确认：

- 文本与参考图从左到右按生产阶段分列（常见列步距 ≥ 420、行步距 ≥ 300），下游片段在右侧，音轨与剪辑成片在下游收尾；
- 无卡片或标题栏重叠（无红框），孤立节点与主区之间保持清晰分区；
- 需要局部核对时可传 `node_ids` 或 `bounds`，需要包含主区外较远节点时传 `scope: "all"`（默认 `main` 聚焦主集群）；上述筛选参数每次最多传一个。

```json
{"command":"production","subcommand":"canvas-preview","options":{}}
```

需要调整时用一次 `positions` 提交，只移动本次新增或相关节点，保留用户已摆好的位置，调整后可再次 `canvas-preview` 核对画面。

只有用户明确要求清理相应范围时才使用 `remove_types`，可清理媒体、导演台、文本与剪辑节点，合法类型以 schema 为准。移除媒体生成节点会同时移除对应片段；移除素材节点保留素材文件，移除导演台节点保留导演文档。

<inline-ref type="reference" skill="剧本工具使用规范" section="把已有文件加入画布">references/production-canvas.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="文本节点">references/production-canvas.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="音视频转录">references/production-canvas.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="视频节点操作">references/production-canvas.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="图片派生、预设与宫格">references/production-canvas.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="全景取景">references/production-canvas.md</inline-ref>
