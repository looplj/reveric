# 制作画布

先从 `/episodes` 定位目标集，再用 `/episodes/{episode_id}/production/canvas` 操作该集画布。`/canvas/{name}` 保留给构思画布。制片目录不在默认发现结果中展开，明确路径可以直接读取；需要契约时读取 `/_schema/episodes`。

## 设置与节点

制作设置、片段配置及输入关系使用本技能的 [分镜与媒体节点](clips.md) 附件；本附件负责画布节点、布局与节点素材处理。

| 任务 | 调用 |
|---|---|
| 读取整个画布 | `Read {"path":"/episodes/{episode_id}/production/canvas"}`，返回画布 ID、节点、连线及引用 |
| 建立本集画布 | `Create {"path":"/episodes/{episode_id}/production/canvas"}`，已有画布则复用 |
| 查找节点 | `Read {"path":"/episodes/{episode_id}/production/canvas/nodes"}`，按 `id` 或 `ref_type/ref_id` 找到目标 |
| 创建导演台 | `Create {"path":"/episodes/{episode_id}/production/canvas/nodes","fields":{"type":"staging","title":"门口对话","x":0,"y":0}}` |
| 创建独立视频节点 | `Create {"path":"/episodes/{episode_id}/production/canvas/nodes","fields":{"type":"video","title":"构图试验","x":420,"y":0}}` |
| 移动节点 | `Write {"path":"/episodes/{episode_id}/production/canvas/nodes/{node_id}","fields":{"x":420,"y":260}}` |
| 读取连线 | `Read {"path":"/episodes/{episode_id}/production/canvas/edges"}` |
| 删除一个节点 | `Remove {"path":"/episodes/{episode_id}/production/canvas/nodes/{node_id}"}` |

节点始终使用 `id`、`type`、`ref_type`、`ref_id`。导演节点的 `ref_type` 为 `staging`，`ref_id` 是 `Run stagings` 的 `staging_id`；视频、图片和音频节点的 `ref_type` 为 `production_clip`，内容在 `/clips/{clip_id}`。不要添加 `staging_id` 节点字段。

创建节点时可以传已有 `ref_id`，并让 `ref_type` 与类型匹配。引用片段必须属于当前集；片段已有节点时会复用。省略 `ref_id` 时会新建导演文档或对应媒体内容。媒体生成节点 type 可为 video、image 或 audio。普通片段仍通过 `Create /clips` 指定 `scene_id` 创建，系统会放置对应节点。

媒体标题、提示词和生成配置写入 `/clips`。画布位置只表达空间组织，不改变场内排序或成片顺序。创建 `media` 节点时在 fields 中提供 `asset_id` 或 `path` 二选一，来源从素材或文件读取结果复制；媒体节点导入不等于已连接为生成输入，输入关系按分镜与媒体节点附件写入。

## 批量调整

先读整张画布，保留无关节点坐标。使用一次 Write 提交互相依赖的位置变化：

```json
{"path":"/episodes/{episode_id}/production/canvas","fields":{"positions":[{"id":"{node_a}","x":0,"y":0},{"id":"{node_b}","x":420,"y":0}]}}
```

画布按场把片段节点排成一列：同场片段按场内顺序自上而下排列。每个场次另有一个 `type=scene` 节点（`ref_type=screenplay_scene`，`ref_id` 为场次 ID），记录整列左上角，还没有片段的场次也有；移动它会带动整场片段，只移动片段时它会跟到这些片段最左、最上的坐标。场次节点不能删除，也不能用 Create 新建。整理片段节点时每场占一列，同场节点用相同 `x`，不同场的列横向错开至少 360；不要把同场片段横向排成一行，否则竖排后的长场会压到下方场次，画布只能把它整场顺延下移。

新建节点只会避开已有节点向下找空位，不按连线摆放，一轮新增后容易挤成一列。完成一批创建、连线或派生后回读画布，检查本次新增与相关节点：参考和文本在下游节点左侧，派生结果贴近来源节点，卡片不重叠，横向间距不小于 420、纵向不小于 300。需要调整时用一次 `positions` 提交，只移动本次新增或相关节点，保留用户已摆好的位置。

按类型移除使用 `remove_types`，取值为 `video`、`image`、`audio`、`staging`、`media`、`text`。只有用户明确要清理相应范围时才执行，比如：

```json
{"path":"/episodes/{episode_id}/production/canvas","fields":{"remove_types":["staging"]}}
```

同一次调用中的位置调整和移除一起成功或一起失败。节点 ID 不存在、跨画布引用或坐标无效时，整次调用不留下部分改动。

移除视频、图片或音频节点会同时移除对应制作内容；移除导演节点保留其调度文档，移除媒体节点保留素材。需要保留片段时只移动节点，不用删除节点整理版面。导演文档仍被节点引用时不能单独 Remove。

完成布局后回读画布，核对节点身份、引用、坐标和实际移除范围。素材输入、生成、任务记录与结果采用按分镜与媒体节点附件执行，不把保存布局说成已生成视频。


## 文本节点

文本节点保存 `title` 与 `content`，不引用媒体资产或其他业务实体。在当前制作画布的 `nodes` 集合中 Create `type=text`，用返回的节点路径读写正文。文本可以作为独立便签，也可连接到视频、图片或音频生成节点，用法见 [分镜与媒体节点](clips.md) 的文本输入。

修改正文只影响后续生成，已经提交的任务保留当时的提示词快照。编辑前读取现有内容，保留无关说明；更新文字不会自动提交生成。

删除文本节点会在同一事务移除下游的 `role=prompt` 输入及提示词中对应的引用标签，保留其余输入、标签和文字；批量 `remove_types=["text"]` 遵循相同规则。界面发起的删除可在当前画布会话内撤销，恢复文本、输入连线和被此次删除清理的标签，重做再次移除；若提示词随后被用户或 AI 改动，该步撤销或重做会拒绝执行，不覆盖新内容。普通提示词和模型设置编辑不进入画布结构撤销。

## 视频节点操作

需要可继续引用的独立资产时，使用 `Run production`，options 的 `node_id` 从当前制作画布读取，不使用 clip_id、asset_id 或标题替代。每次调用处理源节点当前采用的视频，创建同画布的派生媒体节点和 `derived_output` 来源边，保留原视频与采用结果。

| UI 操作 / subcommand | options |
|---|---|
| 首帧／尾帧／指定时刻截帧 `capture-frame` | `node_id`、`position=first/last/at` 必填；只有 at 必须提供整数 `at_ms`，范围为 `0 ≤ at_ms < 实测时长`；其余 position 禁止 at_ms |
| 音视频分离 `separate-audio` | `node_id`；必须有音轨，生成 M4A，源视频保留原声 |
| 静音 `mute-video` | `node_id`；必须有音轨，生成无声视频副本 |
| 裁剪 `trim-video` | `node_id`、整数 `start_ms` 和 `end_ms`；`0 ≤ start_ms < end_ms ≤ 实测时长`，左闭右开，不改剪辑时间线 |

除此表外不接收其他参数。Windows/macOS 支持视频处理，Android 返回 unsupported。这些命令只处理当前作品内的节点素材，无需 files.read 审批。执行时解析当前采用的视频并检查素材有效性；处理开始后的节点编辑不触发快照冲突或二次确认。

```json
{"command":"production","subcommand":"capture-frame","options":{"node_id":"{node_id}","position":"last"}}
```

后台返回 run_id 后，使用 `Run operations read/wait/cancel` 跟踪同一次操作，不重复提交来查询。最终 result 含 source_node_id、source_asset_id、outputs；每项含 node_id、node_path、type、asset_id、file_path 及可用的 width/height/duration_ms，node_path 与画布读取结果中的节点路径一致。以最终 ok 和状态判断成功；取消等待媒体执行退出，已完成输出仍保留并返回。若资产登记后节点挂接失败，registered_assets 保留已登记的资产身份，不能把它当作已完成节点或盲目重试。

只检查少量画面时优先 `Run ffmpeg frames`，检查拼图不是正式首尾帧。需要让实际尾帧继续作为下一段输入时：读取并确认源视频的实际采用结果 → capture-frame position=last → 等待最终图片节点与资产 → 按 [分镜与媒体节点](clips.md) 的 inputs 契约绑定到下一段。派生来源边本身不等于下一段的生成输入。首尾帧读取与输入绑定不会自动提交生成。


## 图片派生、预设与宫格

以下命令沿用 `Run production`，options 必填真实 `node_id`，来源必须是当前作品的图片生成节点或图片媒体节点，并已有可用图片。本地操作执行时读取当前素材；需要模型生成时，在生成审批通过后读取当前来源与配置。等待审批期间可以换图、改配置，不因与发起时不同而拒绝，也不为批准到提交的短时间窗重复确认；缺失或不支持的素材与配置仍会失败。新节点留在来源画布，不替换源采用结果。

| subcommand | 参数与结果 |
|---|---|
| `derive-view` | 必填 `preset=camera/light`、`provider_id`、`model_id`；可选 `args`、`title`。创建派生图片节点并等待本次生成结果，返回真实 task_id；草稿已创建不等于生成完成 |
| `image-preset` | 必填 `method`，可选 `title`。只创建带预设及来源输入的可编辑草稿，返回 clip_id 和 generated=false，不返回虚构资产或文件；后续按 clips 附件配置及 generate-image |
| `split-grid` | 必填整数 `rows`、`cols`，各 1..5 且乘积大于 1；可选 `cells`、`upscale`、`provider_id`、`model_id`。不传 upscale 只做本地裁切；传 upscale 必须是2或4且提供模型与非空 cells，实际型号必须支持该倍率。高清逐格提交任务后返回，各格在后台并行生成，不等待生成结束 |

camera 的 args 只允许 yaw、pitch、framing：yaw 为 −180/−135/−90/−45/0/45/90/135/180，pitch 为 −60/−30/0/30/60，framing 为 extreme_wide/wide/medium/close/detail，默认 0/0/medium。light 只允许 direction=left/right/top/bottom/front/back、brightness=dim/moderate/bright/intense、texture=soft/hard、temperature=warm/neutral/cool、字符串 description，默认 front/moderate/soft/neutral/空字符串。两类字段互斥；比例与分辨率沿来源配置和所选模型校验，不在 args 中传规格或另拼预设提示词。

image-preset 的 method 为现有非 free 枚举：upscale、blocking_storyboard、storyboard、continuous_grid、plot_grid、after_3s、before_5s、portrait_texture、cinematic_light、panorama、multi_camera_grid、expression_grid、face_turnaround、character_sheet、character_turnaround、scene_sheet、product_sheet。九宫格预设是待生成草稿，split-grid 是对已有图进行本地裁切；全景预设建立2:1草稿，不证明已得到可信全景素材。

cells 是从0开始按行优先的原图格号，禁止重复或越界；省略或空数组表示全部。返回按原格号排序，不按传入 cells 的先后重新编号。高清必须显式选择格子，不能在纯裁切失败后自动转收费生成。除各行列出的字段外不接收其他参数。

作品内节点的本地图片处理无需 files.read 审批。只有派生生成和宫格高清申请 generation.image，审批展示节点、动作及调用参数中的模型；生成批准前不裁切、上传或生成。image-preset 只写元数据草稿。每次执行组装好请求后使用该请求，后续编辑不会改写已经开始的任务。图片处理使用共享离屏服务，不因界面位于桌面端而禁止 Android；实际平台能力失败会返回诊断，不把源码可调用当作三端实机验收。

最终 result 沿用 source_node_id、source_asset_id、outputs。生成项带 clip_id、generated、真实 task_id、result_applied；成功时另有资产及可用规格。宫格另含 group_node_id、members 的 cell→node_id 映射，每个 output 的 cell 保留原格号。资产已登记但建组失败时 registered_assets 保留已登记身份，不把它说成已完成节点。

宫格高清的 ok=true 和 operation completed 只表示提交成功，不表示图片已生成。每格 submitted 表示任务是否已提交，task_id 是真实任务 ID，task_status 和 generated 是返回时的状态快照。读取该片段 `generations` 下的对应记录查询后续结果，用 `Run operations cancel` 的 `options={"task_id":"…"}` 取消某格，不重复提交来查询。提交部分失败时 ok=false，保留已提交项及逐项 failures；模型在提交后失败则以该格任务查询为准。

取消宫格高清的批量 operation 只停止尚未接受的提交；已提交任务继续运行并可自动采用结果，需要停止时分别按 task_id 取消。未提交格保留草稿，submitted=false；尚未开始提交的格子没有生成任务，取消时正在建任务的格子可能在 failures 中保留已取消的 task_id。取消已提交的单格任务后，远端可能继续，但迟到结果不自动采用。derive-view 仍等待本次生成结果，取消时保留草稿与已完成结果，并在远端可能继续时标明 upstream_may_continue。

后台回执用 Run operations 查询同一次 run_id；不要重发整组来查询或重试。重试失败项时用该项已有 clip_id 配置后 generate-image，保留成功项，先确认原任务已结束。派生图片的 reference_image 输入边、宫格分组与来源边都由共享编排建立，不向 edges 直接写入；连接到下一段仍按 clips 的完整 inputs 契约执行。


## 全景取景

`Run production capture-panorama` 从已采用的全景图片或已启用全景视图的图片媒体节点提取持久截图。不能仅因普通图片宽高比为2:1就把它当作可信全景；缺素材时先按上节建立 panorama 图片预设草稿，配置并生成、核对后再取景。已有全景图片预设即使关闭查看器，仍可从实际采用图片取景。

options 只接受 `node_id`、`views`。views 必填1..4项，每项只接受必填数值 yaw、pitch、fov 和可选字符串 title。角度必须有限，pitch为−85..85，fov为30..100，yaw按既有球面模型归一化到[−180,180)。四项请求必须使用同一pitch/fov，四个yaw方向相隔90°；顺序以输入数组为准。

```json
{"command":"production","subcommand":"capture-panorama","options":{"node_id":"{node_id}","views":[{"yaw":0,"pitch":0,"fov":75,"title":"正面"},{"yaw":90,"pitch":0,"fov":75,"title":"右侧"},{"yaw":180,"pitch":0,"fov":75,"title":"背面"},{"yaw":270,"pitch":0,"fov":75,"title":"左侧"}]}}
```

显式参数决定截图方向，不读取鼠标拖动或查看器临时状态；读取节点的panorama可查看持久视角，但不会自动代入缺失字段。输出沿已有投影与作品画幅，长边1920，保存不含辅助线/HUD的PNG资产与derived_output节点。

全景取景是作品内节点的本地处理，无需 files.read 审批。执行开始时检查当前素材及全景资格，载入图片后按本次请求完成各视角；不逐视角比较来源快照。节点后续编辑、持久视角变化不会替代已经开始的取景参数。

最终result沿用source_node_id/source_asset_id/outputs；每个输出带view_index及归一化view、node_id/node_path、asset_id/file_path与规格，views数组保存所有请求视角与已完成节点的对应。title可重复，身份与失败始终按从0开始的view_index区分。部分失败返回ok=false、已完成outputs和逐视角failures（阶段、错误码、实际诊断）；资产已登记但挂接失败时保留registered_assets。取消等待当前离屏渲染释放资源后返回，保留已完成截图，不继续渲染剩余视角。

通过Run operations查询已有run_id，不重发整组来查询或重试；只重试未完成视角。查看全景和打开结果面板属于界面导航，本命令只生成业务资产。Windows/macOS/Android共用离屏处理路径，具体运行能力失败会返回诊断；离屏测试通过不代表三端实机已经验收。
