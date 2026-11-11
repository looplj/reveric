# 剪辑工程

用于可继续编辑的时间线、音轨与字幕；导演台的人物和机位时间轴使用当前作品的工具技能（「剧本工具使用规范」或「画布作品工具」）。操作参数与 commands 契约见下文。

editing 负责组织素材并剪辑成片，FFmpeg 负责素材加工。需要先转码、降噪、调色或处理外部字幕时，读取媒体加工附件，取得处理后的文件，再通过 add_media 或 replace_source 显式使用。工程内的顺序、片段区间、音量、字幕与叠加效果保留为可编辑数据，不提前压成单个文件来代替时间线修改。

界面“剪辑／多轨剪辑”中的片段属于时间线；其“分割”操作切开时间线片段，不调用“AI 拆分镜”，也不创建新的场内分镜。主轨、叠加、字幕、对白、音效和音乐按读取到的轨道角色定位。

## 命令参数

调用格式为 `{"command":"editing","subcommand":"操作名","options":{...}}`，需要当前作品会话。

| subcommand | 必填 options | 可选 options 与行为 |
|---|---|---|
| `list` | 无 | `offset=0`、`limit=50`，limit 为 1..200 |
| `create` | `title`、`ratio` | ratio 为 21:9、16:9、4:3、1:1、3:4 或 9:16 |
| `read` | `editing_id` | `track_id` 或 `start_frame` + `end_frame`，两种过滤互斥 |
| `apply` | `editing_id`、`expected_revision`、`commands` | commands 为 1..100 条且不超过 256 KiB |
| `undo` / `redo` | `editing_id`、`expected_revision` | 与当前应用界面共用撤销历史 |
| `frames` | `editing_id`、`expected_revision`、`frames` | 返回合成时间线的画面拼图 |
| `preview` | `editing_id`、`expected_revision` | 返回 480p MP4 |
| `cleanup` | `run_id` | 清理已结束预览任务的会话输出，重复执行安全 |

## 定位与读取

用 `Run editing list` 查当前作品工程，再用 read 取得真实 editing_id、revision、轨道与片段 ID。新工程用 create，提供 title 和 ratio。已有工程局部调整不另建工程。

画布作品的剪辑工程由剪辑节点持有，节点的 `ref_id` 就是 `editing_id`；`Run editing create` 会同时创建剪辑节点。可从节点进入工程，也可用 list 定位；有多个版本时先确认目标，不能凭标题相似覆盖其他工程。

```json
{"command":"editing","subcommand":"read","options":{"editing_id":"{editing_id}"}}
```

read 可选 track_id，或同时给 start_frame / end_frame 查询全局帧区间，两种过滤不能混用。时间轴按返回的 fps 换算帧数，不能把秒直接填入 frame 字段。读取结果统一使用 snake_case。片段层包含 `id/track_id/name/start_frame/duration_frames/origin/content`，按 `content.kind` 区分 video、audio、text。video/audio 的素材位于 `content.source`，字段为 `asset_id/media_type/duration_us/has_audio`，素材入点为 `content.source_in_us`；video 的画面属性位于 `content.transform` 和 `content.opacity`。text 内容仅包含 `text/style/position`。命令参数仍以下方 commands 表为准，比如 `text_style` 修改 `content.style`。

`origin` 可空；`type=production_clip` 时 id 记录制作片段来源，实际素材以 `content.source.asset_id` 为准，不随制作片段后来更换采用结果而变化。使用 production_clip_id 加入或替换时写入 origin，使用 path 替换时清空；分割沿用来源记录。

## 原子修改

每条 command 都包含 `op`，其余参数如下；未知字段使整组失败。表中未标可选的参数必须提供。

| op | 参数 |
|---|---|
| `add_audio_track` | 可选 `id` |
| `update_track` | `track_id`、`fields`，fields 可含 name、locked、hidden、muted；muted 仅用于音轨 |
| `reorder_track` | `track_id`、`order` |
| `remove_track` | `track_id` |
| `add_media` | `track_id`、path 或 production_clip_id 二选一；主轨用 `index`，其他轨道用 `start_frame`；可选 `id` |
| `add_text` | `track_id`、`start_frame`、`text`；可选 `id`；默认 72 帧，遇下一个片段时缩短 |
| `reorder_clip` | `clip_id`、`index` |
| `move_clip` | `clip_id`、`start_frame`；可选 `track_id`，仅用于非主轨 |
| `trim_clip` | `clip_id`、`start_frame`、`end_frame`，使用当前时间线坐标 |
| `split_clip` | `clip_id`、`frame`，切点严格位于片段内部 |
| `duplicate_clip` | `clip_id`；主轨用 `index`，其他轨道用 `start_frame`；可选新 `id` |
| `remove_clip` | `clip_id` |
| `update_clip` | `clip_id`、`fields`，fields 可含 name、scale、opacity、gain_db、fade_in_frames、fade_out_frames、text、text_style、text_position |
| `extract_audio` | `clip_id`；可选 `track_id`，将有原声且未分离的视频片段原声放到音频轨 |
| `replace_source` | `clip_id`、path 或 production_clip_id 二选一 |
| `set_ratio` | `ratio`，取值与 create 相同 |
| `rename` | `title` |

每次修改前读取最新 revision，以 expected_revision 提交。apply 的 commands 一组最多 100 条、256 KiB；整组成功才提交一个 revision 和一个撤销步骤，失败不保留部分时间线修改。

```json
{"command":"editing","subcommand":"apply","options":{"editing_id":"{editing_id}","expected_revision":0,"commands":[{"op":"rename","title":"开场剪辑"}]}}
```

示例中的 revision 必须换成刚读取的值。素材通过 path 或 production_clip_id 二选一加入；后者必须已有采用资产。导入后的时间线来源保存 `content.source.asset_id`，读取到的 ID 用于识别素材。主轨按 index 排列，其余轨道按 start_frame 定位。trim_clip 使用当前时间线坐标，split_clip 的切点必须在片段内部；不把它们当成原文件时间戳。

新对象可提供唯一 ID 供同批后续命令引用；已有对象只使用读到的 ID。锁定轨道先单独解锁，再提交后续修改。遇到 conflict 重新读取用户最新编辑，重新计算本次变更，不复用旧 revision 强行提交。

`update_clip` 的字段按内容类型生效：视频可改 scale、opacity、gain_db 与 fades，音频可改 gain_db 与 fades，文字可改 text、text_style、text_position；三类都可改 name。scale 范围为 0.2 至 1，gain_db 为 -60 至 12。

scale 小于 1 时，缩放后的图层框位于右上方，框的上边缘和右边缘各留 6% 边距；素材在框内保持比例并居中。素材与工程比例不同时，实际画面边缘不一定贴住该边距。scale 等于 1 时居中。transform 的 x/y 表示图层中心的归一化坐标，不能通过 `update_clip` 单独修改。

`extract_audio` 保留原时间位置、时长、源入点、音量、淡入淡出及 origin。省略 track_id 时，优先找整个片段区间空闲且未锁定、未静音、未隐藏的对白轨，其次找普通音频轨，没有则自动新建普通音频轨；不自动使用音效或音乐轨。显式指定轨道时必须为未锁定的音频轨，区间占用则失败，不自动换轨或截短。结果通过 created_clip_ids 和 created_track_ids 返回新对象。

分离后视频的 `content.audio_detached` 为 true，预览和导出不再混入其原声。视频与独立音频之后分别编辑，移动、裁切、删除或重排画面不会自动调整音频。替换为新的有原声视频时继续保持静音，已分离音频仍保留旧素材；替换为图片或无原声视频时该字段为 false。所有 video 内容都保存此布尔值，仅带原声的视频允许为 true。分离及自动建轨可以一次撤销。

undo / redo 同样需要最新 expected_revision，历史与当前运行应用的界面共用；执行前明确要撤销的范围，不能假定只会撤销 Agent 自己的改动。修改后回读轨道、片段、时间范围及引用。

## 把生成片段剪成成片

用户要成片时，按顺序把片段加入主轨只是起点。生成片段的头尾常带起势、停顿、重复交代或偏离设定的画面：逐段用 `Run ffmpeg frames`（见「媒体加工」附件）在原素材的开头、结尾和提示词写明的镜头切点前后取带时间标注的拼图，一次看不清就在变化处加密采样；据此裁掉不承担信息的部分，把切点放在动作完成或镜头转换处。素材时间按 fps 换算成时间线帧号后再 trim_clip，修改后用下文的 editing frames 在合成时间线上验收，并按下文检查接缝。成片时长由保留的内容决定，不为凑满计划时长留下有问题的画面；与目标时长的差距在交付时说明。

检查中发现切点附近的道具、姿态或空间矛盾时，先用 trim_clip、split_clip 与 remove_clip 在现有素材内处理并验收，剪辑解决不了再说明需要返修的片段。用户已交代由你决定时直接修改并报告改了什么；时间线修改可以撤销，不把已经发现的问题只写进交付说明。

## 镜头衔接检查

拼接相邻镜头时主动检查接缝；用户指出衔接不顺时，先定位相关的两个片段。以两侧实际素材和当前时间线为依据，提示词描述不能代替生成结果。

1. **同时检查两侧。** 读取前段末尾和后段开头的一段范围，优先用 ffmpeg frames 获取带时间标注的画面拼图；原素材的读取方式见「媒体加工」附件。先找到动作、姿态或构图变化的位置，再在候选切点附近加密采样，不只比较末帧与首帧。检查人物位置、动作阶段、视线与运动方向、道具和伤痕是否连续，以及两侧是否重复交代同一信息。每个判断注明素材与采样位置。
2. **比较可用切点。** 在现有素材内比较剪前段尾部、剪后段头部、两侧各剪一部分的方案，优先保留关键动作、反应和必要信息，去掉重复或无信息的停顿。不能只因某一帧不匹配就认定必须重生成，也不能因用户提出剪某一侧就未经检查断定可行。剪辑仍无法保持叙事连续时，再说明插入镜头或重生成需要补足什么；转场效果不能自动消除姿态、空间或事件矛盾。
3. **核对时间与关联轨道。** 区分原素材时间、素材入点和时间线帧号；按当前 fps 计算修改，并根据 apply 返回的 changes 和回读结果确认片段起点、素材入点、时长及后续片段位置。素材自带音频随片段裁切，独立对白、音效和字幕不会因此自动完成对齐，需按同一事件的新位置逐项核对。字幕需要整体前移或后移时使用 move_clip，不能用缩短字幕时长代替移动。若素材入点后移 1 秒、片段时间线起点不变，仍保留在片段中的同一事件会提前 1 秒，其对应字幕和独立音轨也应据此核对，而非保留旧位置后宣称同步。
4. **验收修改后的真实接缝。** 回读最新 revision 与片段位置，重新计算切点；用 editing frames 检查合成时间线，或对新预览用 ffmpeg frames 检查切点两侧。若后一段从第 F 帧开始，至少读取 F−1、F 及两侧邻近的有效帧，确认采样确实跨过接缝；不能沿用修改前的时间戳。原素材入点、时间线帧号与预览秒数要分别标明，不能把前段画面当成后段的证据。裁切或移位后还要检查对应字幕的出现与消失位置。
5. **按证据报告结果。** 只对实际读取的画面下结论，注明检查范围和仍未验证的部分。抽帧可用于核对构图、姿态、道具和字幕显示，不能证明动态衔接流畅、台词内容正确或音画同步；嘴部张开也不能证明指定台词已念出。没有连续播放或音频证据时，将这些项目明确留待播放确认，不能因渲染成功就宣称整体衔接已验证。

## 预览检查与清理

检查指定位置的构图、字幕和叠加效果，优先使用 frames：

```json
{"command":"editing","subcommand":"frames","options":{"editing_id":"{editing_id}","expected_revision":0,"frames":[0,23,24,47]}}
```

frames 必须包含 1..12 个整数帧号，范围是 0 到 total_frames - 1，按 read 返回的 fps 换算；空时间线不能检查。示例中的 revision 和帧号必须换成实际值。顺序与重复帧原样保留。命令固定读取该 revision 的时间线，合成主轨、可见叠加和字幕，保留缩放、透明度、淡入淡出效果；不修改工程或创建完整预览视频。

成功结果包含 editing_id、revision、fps、file_path、width、height、cells 和可直接查看的图片 content；cells 记录 label、frame 和 timestamp_ms。拼图最长边不超过 2048 像素，保存为会话 JPEG。拼图随会话文件管理，不使用 cleanup 删除。抽帧不包含音频，也不能证明动作连续、对白正确或音画同步。

需要完整视频预览时使用 preview 检查实际结果是否符合用户预期，提供 editing_id 和最新 expected_revision。它生成 480p MP4；保存时间线和渲染成功都不代表剪辑质量达标。

```json
{"command":"editing","subcommand":"preview","options":{"editing_id":"{editing_id}","expected_revision":0}}
```

按后台任务附件保留 run_id、等待终态，检查 result.files 中实际返回的 file_path。检查前读取文件与媒体加工附件：files read-video-metadata 仅返回视频元数据，要用 ffmpeg frames 在开头、末帧之前的有效位置、切点前后和字幕出现位置提帧，观察返回拼图中的构图、衔接与字幕是否符合预期。按发现的问题重新读取时间线、修改并再次预览；不能凭文件名、时长或渲染成功宣称已经看过视频。抽帧只能验证采样画面，不能证明整段动作流畅、对白正确或音画同步；未能验证的部分如实说明。

每轮检查结束后，主动用该预览任务返回的 run_id 调用 cleanup，并核对清理结果；无需等待用户另行要求。检查失败或放弃后也要清理已生成的预览。正在读取或提帧时先等待使用者完成，再清理；需要继续检查时重新生成预览。

```json
{"command":"editing","subcommand":"cleanup","options":{"run_id":"{preview_run_id}"}}
```

cleanup 只删除该已结束预览任务记录的会话视频及其副本；不接受任意文件路径，不删除原素材、已采用资产、其他任务的输出或时间线。重复清理安全，removed 列出本次删除的文件，missing 列出已不存在的文件；失败时如实说明并重试清理，不声称文件已删除。

正式成片由用户在剪辑界面导出；Agent 用预览完成检查，不调用 editing export。
