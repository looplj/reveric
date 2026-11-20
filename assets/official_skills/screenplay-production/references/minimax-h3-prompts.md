# MiniMax H3 提示词

适用于 MiniMax H3 及其系列服务。实际支持的输入模式（T2VA／I2VA／FL2VA／Ref2VA）与参考上限以运行时模型查询结果为准。本附件规定 H3 的结构与标记，取代通用 Shot 格式。正文按用户指定的语言写，未指定时沿用原稿或当前对话的语言。字段名、镜头标记及标签保留原样。台词、歌词和画面中可见的文字保留原语言。

## 先判断输入模式

按当前型号**实际已绑定**的输入选择结构（仅在运行时支持对应模式时启用）：

| 实际输入 | 模式 | 结构 |
|---|---|---|
| 无参考 | T2VA | 三个核心字段 |
| 只有首帧 | I2VA | 首行对齐句 + 三个核心字段 |
| 首帧 + 尾帧 | FL2VA | 首行对齐句 + 三个核心字段 |
| 人物、场景、动作、音频等参考 | Ref2VA | 六个字段 |

选参考时先问：哪一个 Shot 要照着这份素材还原什么？例如远景只需交代街上有人群，写进画面描述即可；切到近景、需要认出同一张脸时，再绑定人物图。若成片里背景人物的脸或衣着串到了主角身上，先检查是哪张图带入了这些特征；返修优先撤掉多余的参考，保留确实需要的主体依据。按最终绑定的输入选择模式。

## 帧模式：对齐句 + 三个核心字段

对齐句是提示词第一行，后接一个空行。按下方示例交代帧与镜头的对应关系，句子沿用正文语言，图片位置填入完整 `<ref input_id="…" label="…" />` 标签：

- I2VA：`For the target video, at 0.00 seconds into the target video, <ref input_id="…" label="首帧" /> (from [Shot 1]) is fully referenced.`
- FL2VA：`How the reference pictures align with the target video — <ref input_id="…" label="首帧" /> (from Shot 1) aligns with the 0.00-second mark of the target video; <ref input_id="…" label="尾帧" /> (from Shot N) aligns with the S.SS-second mark of the target video.`

`N` 是最后一个镜头的序号，`S.SS` 是生成时长，固定两位小数（8 秒写 `8.00`）。改时长或镜头数后同步改这一行。

```text
integrated_multimodal_description: [Shot 1] ...

overall_soundscape: ...

non_diegetic_music: ...
```

- `integrated_multimodal_description`：按时间线写画面、动作、镜头、说话人、台词和同步发生的剧内声音。`[Shot 1]` 开头写起始构图。I2VA 从首帧的主体、构图和场景出发往后写，不重新设计图中外观；FL2VA 写两端之间可见的过程，优先单镜头，最后一个镜头结束时到达尾帧。
- `overall_soundscape`：用 1–4 句概括整段环境底声，以及构成整体听感的动作声和非语言人声。只有要求全程无声时写 `N/A`。
- `non_diegetic_music`：用 1–3 句描述仅观众听得到的配乐，写明配器、速度、节奏与强弱变化。没有配乐写 `N/A`。

## Ref2VA：六个字段

依次写 `subject_definitions`、`summary`、`retention_analysis`、`detailed_description`、`overall_soundscape`、`non_diegetic_music`。直接指向已绑定素材时使用完整 `<ref input_id="…" label="…" />`。

- `subject_definitions`：每行定义一个要沿用的可见主体，如人物、环境、道具或动作。用 `<Subject N>` 标记，写明素材来源和要沿用的特征，如 `<Subject 1> is the young woman in <ref input_id="…" label="林岚" />, with shoulder-length black hair and a grey wool coat.` 同一主体来自多张素材时，合在同一行交代各自提供的特征。独立承担首帧、尾帧、构图锚点、视频结构或音频参考的素材单独一行，写明对应的镜头或声音及其用途。
- `summary`：用一小段文字概括目标视频的主要动作脉络及关键参考素材的用途。段首用方括号标明任务类型，如 `[reference generation]` 或 `[keyframe completion + reference generation]`。沿用已定义的引用标签。
- `retention_analysis`：每条已定义的主体或独立参考写一行。沿用该条目的标签，写清其生效位置，并按下表标明保留、转移或借鉴哪些内容。
- `detailed_description`：按播放顺序逐镜写起始构图、主体位置和可见特征、环境与光线、动作、运镜、对白及与动作同步的声音。参考在起作用的位置写明，主体后续出镜沿用既有标签，交代当下的状态变化。
- 后两个声音字段同帧模式。

### 怎么选参考关系

| 用于 | 关系词 | 怎么选 |
|---|---|---|
| 画面 | `fully_preserved` | 完整保留指定的参考内容。例如同一人物换了动作，但仍保留定妆图里的长相和穿着。 |
| 画面 | `partially_preserved` | 仍是同一人物或物件，只保留一部分特征。例如保留人物长相和发型，把大衣换成雨衣。 |
| 画面 | `attribute_transfer` | 把一项特征用到另一个明确的对象上。写清从哪里取、给谁用，例如把参考围巾的格纹用在主角的雨衣上。 |
| 画面或音频 | `weak_reference` | 只求大致相似，例如借画面的冷色氛围，或借声音的街市氛围。 |
| 音频 | `fully_copy` | 把完整源音轨原样用作成片的完整音轨。 |
| 音频 | `partially_copy` | 直接用原录音的一段或其中一层声音，或保留原声后再叠加其他声音。 |
| 音频 | `reference` | 借音色、节奏或声音质感重新生成。例如用同一音色说新台词。 |

只在一个镜头露面，用镜头编号说明即可。例如 `<Subject 1> (appears in [Shot 3]): fully_preserved - her face and grey coat match the reference.` 这里仍是参考图中的那个人；出镜短并不意味着要用 `attribute_transfer`。

## 内容转换与字段核对

先保证每镜起始构图、动作与状态变化、运镜、声音与末帧终点完整连贯，再放入 H3 字段；帧模式同样保留完整的动作与状态变化。

Ref2VA 先按共用成稿检查核对场内状态、逐镜可见范围与正文落点，再交叉核对 `subject_definitions`、`retention_analysis` 与 `detailed_description`。每个必要主体的来源、出镜镜头和正文中的可见位置应一致；画外或被遮挡的主体按剧情需要交代位置与声音。

## 镜头、运镜与切点

- `[Shot 1]` 不写时间。后续镜头以 `[Shot N]` 起头，写明 `MM:SS.mmm` 格式的切点和切入画面，如 `[Shot 2] 在 00:03.500 切到窗边近景。` 切点严格递增，且落在生成时长内。
- 切镜要带来新的主体、空间、状态、视角或时间信息；只需要稍微改变景别或角度时，用运镜代替切镜。
- 运镜写成句中的自然动作：类型（`push in`、`pull out`、`pan left`、`truck right`、`tilt up`、`pedestal down`、`zoom in`、`arc shot`、`tracking shot`、`static shot`、`shake slightly`、`POV`）加上需要时的幅度（`with small amplitude` / `with large amplitude`）与速度（`at slow speed` / `at fast speed`），如 `The camera pushes in with small amplitude at slow speed toward the key.`

## 说话人与台词

- 说话、唱歌或画外发声的人用稳定编号 `(S1)`、`(S2)`，跨镜头不变；同时开口用 `(S1,S2)`。不发声的人不编号。
- 说话人第一次出现时，在 `<d>` 外写清身份、年龄段、性别、是否在画内、音色、语速或口音。`<d>` 内只放语言标签和原话，逐字保留标点：
  `The man in his thirties with a low, tired voice (S2) says: <d>[Chinese] 你真的要走？</d>`
- 同一角色在画外说话时沿用说话人编号，标明声音来自画外。旁白或内心独白标明声音类型，英文可写 `says in an off-screen voiceover`。对应角色当时也在画面中时，紧跟 `<d>` 标明其嘴唇闭合。
- 同一句话跨切点时，在前后两处用 `<scenetrans>` 并写明声音延续；台词被视频结尾截断时用 `<cutoff>`。
- 画面中真实可见的招牌、字条用英文双引号原样引用，不翻译：`a sign reading "营业中"`。

## 示例

8 秒，只有首帧（I2VA）：

```text
For the target video, at 0.00 seconds into the target video, <ref input_id="…" label="桌前首帧" /> (from [Shot 1]) is fully referenced.

integrated_multimodal_description: [Shot 1] Live-action, cinematic, a medium shot keeps the woman and the man seated across the wooden table exactly as in the first frame, warm lamp light from the left. She slides the brass key across the table with her right index finger. The key scrapes softly across the wood and stops at the edge with a faint tap, her fingertip still pressing it. The man looks at the key without reaching for it, then raises his eyes to her. [Shot 2] At 00:04.000, the camera cuts to a close-up of the man, the same warm light on the left of his face. The man in his thirties with a low, tired voice (S1) says slowly: <d>[Chinese] 你真的要走？</d> [Shot 3] At 00:06.500, the camera cuts to an overhead close-up of the key at the table edge. Her finger lifts and withdraws out of frame left; the key stays where it is.

overall_soundscape: Quiet indoor room tone throughout.

non_diegetic_music: N/A
```
