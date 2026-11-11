# 分镜与媒体节点、输入与生成

界面“分镜”对应已编入场次的图片或视频制作条目；“视频”“图片”“音频”对应制作画布的媒体节点。下文片段与 `/clips` 是同一制作资源的操作名称，不是剪辑时间线中的片段。

## 定位和配置

通过 Read `/screenplay` 获取制作设置，用 Write 修改 `ratio`、`resolution`；派生的 `width`、`height` 只读。默认规格不覆盖已有片段；已有图片或视频条目的画幅、分辨率可通过 Write `/clips/{clip_id}` 修改 `ratio`、`resolution`，无需重建。图片条目未指定规格时使用 1:1、1K，不继承剧本的视频默认规格。剧本制作设置没有 `fps`。

用 Read `/clips?episode_id=…` 读取本集全部制作条目；只看分镜加 `is_storyboard=true`，只看独立媒体加 `is_storyboard=false`。`kind` 可进一步筛选 `video`、`image` 或 `audio`；如 `/clips?episode_id=…&is_storyboard=true&kind=video` 只返回本集视频分镜。单场使用 `/clips?scene_id=…`，需要时再加 `kind`。筛选先于分页，按返回的 `has_more` 读齐目标范围。

`is_storyboard` 是只读归属标记，随 `scene_id` 自动变化。空白、未生成或未采用结果的场内条目仍属于分镜，应说明待完善状态，不静默排除。分镜排序沿用场次及场内顺序；图片分镜不按视频默认时长计时，视频 `duration_ms` 合计仅表示计划时长，不能当作实测片长。

再读 `/clips/{clip_id}` 获取完整配置与 `inputs`。字段契约按需 Read `/_schema/clips`。

- Create `/clips`：场内片段指定 `scene_id`；独立制作内容指定 `episode_id`。`kind` 为 `video`、`image` 或 `audio`，创建后固定，默认 `video`。使用返回的 ID 和已创建的节点，不重复建立同内容片段。
- 片段可在同集调整场次与顺序，不能把原 ID 移到另一集。场次归属和 `sort_order` 决定场内视频排序，画布坐标不代表成片顺序。
- Write 更新字段，Edit 局部替换标题或提示词。修改提示词不自动修改剧本正文，正文变更也不自动刷新片段。片段内镜头只写在提示词中，不创建镜头资源。
- `provider_id` 与 `model_id` 成对设置或清空；从「系统管理」的模型查询结果复制真实 ID。按返回能力核对时长、分辨率、画幅和参考模式，不根据品牌名猜配置。视频 `duration_ms` 单位是毫秒，生成要求整秒：4 秒写 4000，不写 4。
- `/clips` 不支持直接 Remove；需要移除制作内容时按制作画布附件处理节点，先明确删除范围。

## 素材与输入关系

`Run assets list` 查询当前作品可用的素材（含全局共享素材），options 可按 `type`、`search` 筛选；`Run assets read` 传 `id` 读取真实 ID、文件路径与规格。完整参数通过 `Run help assets` 查询。名称不是内容证据；需要观察图片时用 `Run assets view-image` 传 `id` 直接查看内容，仅接受图片素材，需在 Codemode 外调用。音视频规格通过 `assets read` 查询。素材引用使用返回的 `id`，文件处理直接使用返回的 `file_path`，不要根据 ID 拼接文件名。外部文件先读取到会话副本，或按制作画布附件导入素材节点。

`inputs` 是完整有序数组。修改前先读齐旧数组，只改获准调整的输入，保留其他项的 ID、顺序和用途。输入结构以片段的 schema 为准：`ref_type=asset` 指向素材 ID，`ref_type=node` 指向当前制作画布的来源节点 ID，不能用片段 ID 代替节点 ID。节点输入取来源当前采用的文件，来源换结果会影响后续生成。

### 优先连接已有画布节点

新增或获准重新绑定参考时，人物图、场景图等图片已经在当前制作画布的节点上，就优先使用 `ref_type=node`，让来源节点与目标节点形成输入连线。按 [制作画布](production-canvas.md) 读取当前画布节点；已有源节点 ID 时直接定位，只有资产 ID 时比对媒体节点的资产引用或图片片段的 `adopted_asset_id`，找到当前采用该图的来源节点。这一步比较 ID 与配置，不需要为了建立连线再读取图片像素；仅标题相同不能证明是同一来源。

使用来源的画布节点 ID 作为 `ref_id`，保留已有输入的 `id`、顺序和用途。节点必须属于同一画布，不能引用目标自身或形成循环；有多个匹配节点时，优先使用本次流程已明确的来源，仍无法区分就向用户确认，不任取第一个。

没有对应的可用画布节点，或用户明确要固定某张历史图片、不跟随节点换图时，才使用 `ref_type=asset`。不为制造连线重复创建已有图片节点，也不把节点引用声称为固定图片。只读取、解释或修改提示词文字时，不自动把已有资产引用转成节点引用。

已有输入沿用 `id`，新增输入分配新的唯一身份；`ref_id` 必须来自实际读取。界面用途与实际发送角色分别核对：首尾帧组只发送 first_frame/last_frame，其余普通参考保留但不发送；全参考组可以保留 first_frame/last_frame 用途，提交时转为 reference_image，再追加起止画面的文字指令，不能将其宣称为原生边界帧约束。切换模式后核对实际发送的输入，不静默丢弃用户期待保留的参考，不建立循环依赖。需要从现有视频获取正式帧、派生图片或切分宫格素材时，读取 [制作画布](production-canvas.md)；取得派生素材后仍须按本附件绑定 inputs。Write 片段的 `inputs` 更新输入关系；连线是这些关系的展示，不向只读 edges 集合写入。

保存后回读目标片段与当前画布连线，核对来源和目标节点；有参考缩略图不等于已有节点连线，不单独写 edges 来补线。

## 文本输入

文本输入使用 `role=prompt`，只能通过 `ref_type=node` 引用当前画布的文本节点，目标必须是视频、图片或音频生成节点。它不占参考图数量，也不作为媒体文件发送。

在提示词中用 `<ref input_id="…" label="…" />` 可以把文本放到指定位置，同一输入可引用多次。未被标签引用的文本按 `inputs` 顺序放在提示词开头，空文本展开为空；标签的显示名取文本节点标题。先读取文本正文，再连线或更新输入，避免把未核对的说明加入生成。

修改文本只影响下一次生成，已提交任务继续使用原提示词快照。

## 人物与地点图集名称

图片条目的 `title`、素材名称与人物／地点图集的 `photos.name` 分别维护。生成或采用图片后先回读关联主体的图集，以真实 `asset_id` 定位本次图片，不假定改节点标题会同步改名。

用 Read `/characters/{id}/photos` 或 `/locations/{id}/photos` 读取完整图集，再通过同一路径的 Write `value` 提交完整数组。按 `/_schema/characters`、`/_schema/locations` 的 photos 契约保留各项 `asset_id`，只改目标项的 `name`；保留未改项和原顺序，不为重命名移除图片、重建资产或改变节点采用结果。写入后回读核对。尚未取得真实图片资产时只命名节点草稿，不伪造图集条目。命名内容按「剧本制片」的图片资产与参考附件选择。

## 提示词中的引用

`<ref input_id="…" label="…" />` 指向 `inputs` 中的输入身份。`input_id` 负责关联，`label` 仅用于显示，不能据此推断素材内容。

提示词中的引用可以增删、重复、改名或替换；标签语法必须正确，`input_id` 必须对应有效输入，素材来源必须存在。新增或更换素材输入时，先核对真实来源，再把完整 `inputs` 与一致的 `prompt` 放在同一次 Write 中提交。标签只能引用提交后的有效输入；不能只写标签或 `@名称` 假装已绑定素材，也不能改成供应商槽位编号。

引用校验失败时回读输入和正文，修正本次变更，不删标签绕过错误。写入后回读两者，确认没有误改无关引用。提示词的创作格式由「剧本制片」提供。

## Seedance 合规校验

「Seedance 合规校验」即 `Run assets certify`：把图片素材认证进渠道私域素材库。Seedance 会拦截有风险的人像参考图，认证通过后该渠道的视频生成直接引用已认证素材。

- 只在用户要求，或参考图因人像被拦截后征得用户同意时执行：认证会把图片交给渠道并占用其素材库配额。
- 渠道从 `Run providers list` 中 `asset_certification=true` 的项里选，优先用将要生成该视频的分镜所配置的渠道；有多个且无法确定时先问用户。
- 提交后状态为 processing，用 `Run assets read` 查看 certifications，直到 active 或 failed。failed 时如实报告 error_code，不自动重试。
- 认证在素材与渠道上生效，不需要改分镜输入或提示词；提示词仍用「图片1」等序号引用素材。

## 生成与结果采用

用户要求生成后，先保存并回读片段配置与输入，再调用与 `kind` 对应的 `Run production generate-image`、`generate-video` 或 `generate-audio`。options 必填 `clip_id`。视频生成还支持下述草稿参数；图片和音频不接收这些参数。例如：

```json
{"command":"production","subcommand":"generate-video","options":{"clip_id":"{clip_id}"}}
```

视频先预览再出高清时：

- 先用 `Run providers models` 查询片段所选渠道与型号，要求 `available=true` 且 `capabilities.supports_draft=true`；草稿与高清规格、有效期见 `capabilities.draft`。能力未知或不支持时，不尝试草稿参数。
- 生成草稿：`generate-video` 的 options 增加布尔 `draft: true`（默认 false）。这是本次生成的选项，不修改片段保存的清晰度；草稿也是付费生成。
- 草稿转高清：同一命令传 `draft_task_id`，复制当前片段生成记录中的本地 `id`，不能传 `run_id` 或供应商任务 ID。`draft: true` 与 `draft_task_id` 互斥。只接受当前片段已完成且仍可生成高清的草稿，使用原草稿的服务商、提示词、输入、时长和画幅，不使用片段后来修改的配置；高清另行计费。

```json
{"command":"production","subcommand":"generate-video","options":{"clip_id":"{clip_id}","draft":true}}
{"command":"production","subcommand":"generate-video","options":{"clip_id":"{clip_id}","draft_task_id":"{draft_task_id}"}}
```

生成记录和完成回执包含 `draft`、`draft_task_id`；视频另有 `draft_expires_at`、`can_complete_draft`、`draft_completion_blocked_reason`。到期时间按提交时间估算，最终以上游响应为准。生成高清前重新读取记录；不可生成时按返回原因处理，不重复提交绕过限制。提交结果不明或已有未结束的高清任务时，先处理原任务。草稿过期后本地视频仍能播放、采用和导出。

草稿和高清成功后均按最新结果规则自动采用；高清生成期间保留当前采用的草稿，完成后可手动切回历史草稿。

普通生成和草稿生成使用已保存配置，不在 options 中临时塞入 prompt、模型或输入。每次调用都会发起新的生成尝试；查询已有任务使用返回的 `run_id` 或生成记录，不重复调用生成命令。同一片段有准备、提交或运行中的生成任务时，会拒绝再次生成。

返回后台回执后，用「媒体处理与剪辑」的后台任务附件读取、等待或取消对应 `run_id`。读取该片段的 `generations` 及其返回的记录路径可核对持久生成状态、结果文件与 `result_applied`；生成记录的 ID 不能当作运行 ID。

需要采用已有结果时，Write 片段的 `adopted_asset_id`，使用 `Run assets list/read` 或生成记录返回的真实 asset id；设为 null 会清除当前采用结果。外部文件先导入成资产，再采用返回的 id。生成完成后仍须核对实际采用状态，不能把任务完成当成已采用；遇到 `action_required` 或 `submission_unknown` 先查记录并说明状态，不重复提交生成命令。

交付区分配置已保存、任务已提交、结果已生成、结果已采用。仅写提示词时不发起生成，失败或取消不宣称成片完成。

参考素材上传因 `reference_storage` 失败时，按「系统管理」的 `references/settings.md` 打开存储设置，由用户完成配置后再继续；不要据此更换渠道或删除参考输入。
