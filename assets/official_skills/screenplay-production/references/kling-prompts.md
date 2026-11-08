# Kling 提示词

适用于 Kling 3.0 与 O1，具体型号按 `catalog_model_id` 查 [视频提示词](video-prompts.md) 的模型对照。内容原则见 [视频提示词](video-prompts.md) 与 [分镜指南](storyboard.md)；本附件只规定 Kling 的结构与标记，取代通用 Shot 格式。

## 公式

- 文本生成：`主体（外观）+ 运动 + 场景（环境）+ 镜头语言、光线与氛围`。
- 参考生成（`kling-video-o1` 及 3.0 的参考输入）：`各主体的描述 + 主体之间的互动 + 环境 + 光线与风格`。主体第一次出现时放对应 ref 标签，之后在其动作和台词处继续用同一个标签指代，不另起称呼。
- 首尾帧：写“以首帧开始、以尾帧结束”，正文只写两端之间的变化；只有尾帧而没有首帧的方式不受支持。

## 多镜头

Kling 3.0 一次生成可含多个镜头，可用总时长以运行时查询为准。逐镜写出镜号和该镜秒数：

```text
Shot 1 (4s): Medium shot, warm lamp light from the left. <ref …/> slides a brass key across the table toward <ref …/> and stops at the edge, fingertip still on it. The man looks at the key, then up at her.
Shot 2 (2s): Close-up on <ref …/>. He says (low, slow): "你真的要走？"
Shot 3 (2s): Overhead close-up of the key. Her finger lifts away and exits frame left; the key stays.
```

- 各镜秒数为整数，相加等于生成时长；一镜一个主要运镜。
- 需要镜头内的节点时可以写相对时刻，如 “At the 3rd second”“In the final 2 seconds”。
- 让模型自行规划镜头时，按事件顺序写连贯段落，不写镜号。

## 台词与声音

- 台词按“说话人（语气）: 原话”写，例如 `The man (softly, hesitant): "你真的要走？"`；有主体参考时说话人用其 ref 标签。原话逐字保留，每句对应到一个说话人。
- 原生对白支持中、英、日、韩、西五种语言，其他语言会被转成英文；口音可以写明，如 “speaks Mandarin with a northern accent”。
- 环境声与背景音乐直接用句子描述，如 “a faint hum of the air conditioner in the background”“soft piano BGM”。
- 主体已绑定音色时，提示词里不必再描述音色。

## 其他

- 不写负面清单；需要排除的内容在正文里正面描述成想要的画面。
- 英文或中文均可，整条保持一种语言，台词保留剧本原文。
