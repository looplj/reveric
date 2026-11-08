# MiniMax H3 提示词

适用于 MiniMax H3 系列，具体型号按 `catalog_model_id` 查 [视频提示词](video-prompts.md) 的模型对照。内容原则见 [视频提示词](video-prompts.md) 与 [分镜指南](storyboard.md)；本附件只规定 H3 的结构与标记，取代通用 Shot 格式。正文、字段名和镜头标记全部写英文；台词、歌词和画面中可见的文字保留原语言。

## 先判断输入模式

| 实际输入 | 模式 | 结构 |
|---|---|---|
| 无参考 | T2VA | 三个核心字段 |
| 只有首帧 | I2VA | 首行对齐句 + 三个核心字段 |
| 首帧 + 尾帧 | FL2VA | 首行对齐句 + 三个核心字段 |
| 人物、场景、动作、音频等参考 | Ref2VA | 六个字段 |

模式按实际绑定的输入判断，不按计划判断。

## 帧模式：对齐句 + 三个核心字段

对齐句是提示词第一行，后接一个空行。句式固定，句中图片位置放对应输入的 ref 标签：

- I2VA：`For the target video, at 0.00 seconds into the target video, <ref 首帧/> (from [Shot 1]) is fully referenced.`
- FL2VA：`How the reference pictures align with the target video — <ref 首帧/> (from Shot 1) aligns with the 0.00-second mark of the target video; <ref 尾帧/> (from Shot N) aligns with the S.SS-second mark of the target video.`

`N` 是最后一个镜头的序号，`S.SS` 是生成时长，固定两位小数（8 秒写 `8.00`）。改时长或镜头数后同步改这一行。

```text
integrated_multimodal_description: [Shot 1] ...

overall_soundscape: ...

non_diegetic_music: ...
```

- `integrated_multimodal_description`：按时间线写画面、动作、镜头、说话人、台词和同步发生的剧内声音。`[Shot 1]` 开头先写整体风格（如 `Live-action, cinematic,`）和起始构图。I2VA 从首帧的主体、构图和场景出发往后写，不重新设计图中外观；FL2VA 写两端之间可见的过程，优先单镜头，最后一个镜头结束时到达尾帧。
- `overall_soundscape`：1–4 句，环境声、动作声和非语言人声（脚步、呼吸、关门），不重复台词。只有要求全程无声时写 `N/A`。
- `non_diegetic_music`：1–3 句，写配器、速度与强弱变化，不写情绪词。剧中人物听得见的音乐写进第一个字段。没有配乐写 `N/A`。

## Ref2VA：六个字段

依次写 `subject_definitions`、`summary`、`retention_analysis`、`detailed_description`、`overall_soundscape`、`non_diegetic_music`。

- `subject_definitions`：每行定义一个要追踪的内容，用 `<Subject N>` 标记，并写明来源参考、用途和主要特征，如 `<Subject 1> is the young woman in <ref …/>, with shoulder-length black hair and a grey wool coat.` 参考图本身作为首帧或构图锚点时，单独写一行说明它对应哪个镜头。
- `summary`：一段英文，用方括号前缀写任务类型，如 `[reference generation]`、`[keyframe completion + reference generation]`，再概括目标视频和各参考的作用。不在这里引入新标签。
- `retention_analysis`：每个标签一行，写出现在哪些镜头，以及 `fully_preserved`、`partially_preserved`、`attribute_transfer` 或 `weak_reference`；音频用 `fully_copy`、`partially_copy`、`reference` 或 `weak_reference`。
- `detailed_description`：先用一两句英文写整体风格，再逐镜写。每个镜头写清当前构图、主体外观与位置、环境与光线、动作与状态变化、运镜和声音，以及参考内容在哪里起作用。生成任务通常 350–500 个英文词；对白多时以装下完整台词为准。
- 后两个声音字段同帧模式。

## 镜头、运镜与切点

- `[Shot 1]` 不写时间；之后每个镜头写 `[Shot N] At MM:SS.mmm, the camera cuts to ...`，切点严格递增，且落在生成时长内。
- 切镜要带来新的主体、空间、状态、视角或时间信息；只需要稍微改变景别或角度时，用运镜代替切镜。
- 运镜写成句中的自然动作：类型（`push in`、`pull out`、`pan left`、`truck right`、`tilt up`、`pedestal down`、`zoom in`、`arc shot`、`tracking shot`、`static shot`、`shake slightly`、`POV`）加上需要时的幅度（`with small amplitude` / `with large amplitude`）与速度（`at slow speed` / `at fast speed`），如 `The camera pushes in with small amplitude at slow speed toward the key.`

## 说话人与台词

- 说话、唱歌或画外发声的人用稳定编号 `(S1)`、`(S2)`，跨镜头不变；同时开口用 `(S1,S2)`。不发声的人不编号。
- 说话人第一次出现时，在 `<d>` 外写清身份、年龄段、性别、是否在画内、音色、语速或口音。`<d>` 内只放语言标签和原话，逐字保留标点：
  `The man in his thirties with a low, tired voice (S2) says: <d>[Chinese] 你真的要走？</d>`
- 画外音用固定说法，并紧跟口型说明：`(S1) says in an off-screen voiceover: <d>[Chinese] ……</d> while his lips remain completely closed.`
- 同一句话跨切点时，在前后两处用 `<scenetrans>` 并写明声音延续；台词被视频结尾截断时用 `<cutoff>`。
- 画面中真实可见的招牌、字条用英文双引号原样引用，不翻译：`a sign reading "营业中"`。

## 示例

8 秒，只有首帧（I2VA）：

```text
For the target video, at 0.00 seconds into the target video, <ref input_id="…" label="桌前首帧" /> (from [Shot 1]) is fully referenced.

integrated_multimodal_description: [Shot 1] Live-action, cinematic, a medium shot keeps the woman and the man seated across the wooden table exactly as in the first frame, warm lamp light from the left. She slides the brass key across the table with her right index finger and stops at the edge, fingertip still pressing it. The man looks at the key without reaching for it, then raises his eyes to her. [Shot 2] At 00:04.000, the camera cuts to a close-up of the man, the same warm light on the left of his face. The man in his thirties with a low, tired voice (S1) says slowly: <d>[Chinese] 你真的要走？</d> [Shot 3] At 00:06.500, the camera cuts to an overhead close-up of the key at the table edge. Her finger lifts and withdraws out of frame left; the key stays where it is.

overall_soundscape: Quiet indoor room tone. The key scrapes softly across the wood and stops with a faint tap.

non_diegetic_music: N/A
```
