# Veo 提示词

适用于 Veo 3.1 系列，具体型号按 `catalog_model_id` 查 [视频提示词](video-prompts.md) 的模型对照。内容原则见 [视频提示词](video-prompts.md) 与 [分镜指南](storyboard.md)；本附件只规定 Veo 的结构与标记，取代通用 Shot 格式。

## 语言与公式

Veo 官方只对英文做了完整支持，其他语言未经评估。整条提示词写英文；台词保留剧本原文，中文台词的发音与口型需看实际结果核对。

单镜头按 `镜头与构图 → 主体 → 动作 → 环境 → 风格、氛围与光线` 组织成连续段落：

```text
Medium shot, a woman in her thirties with a grey wool coat, slides a brass key across a wooden table toward the man opposite her, in a dim apartment at night. Warm lamp light from the left, soft shadows, naturalistic film look.
```

## 多镜头用时间段

一次生成需要切镜时，按时间段逐镜写，每段先写镜头与构图，再写主体和动作，声音紧跟在该段后：

```text
[00:00-00:04] Medium shot, ... SFX: the key scrapes softly across the wood.
[00:04-00:06] Close-up on the man, ... He says quietly, "你真的要走？"
[00:06-00:08] Overhead close-up of the key, ...
```

时间段首尾相接，最后一段结束于生成时长。首尾帧生成的时长受渠道限制，以运行时查询为准。

## 台词与声音

- 台词用双引号：`The man says in a low, slow voice, "你真的要走？"`；多人时每句写出说话人身份，原话逐字保留。
- 音效写 `SFX: ...`，环境声写 `Ambient noise: ...`；配乐没有独立标记，用 `SFX:` 或句子写明配器与进入时机。
- 声音也会驱动画面：写了撞击声就容易演出撞击，改动作时同步改声音。

## 参考图与首尾帧

- 人物、物件、场景参考：用身份称呼把参考接进句子，如 `Using the provided images for the woman <ref …/> and the apartment <ref …/>, create a medium shot of ...`。每张参考只放一个主体，数量不超过运行时查询的上限。
- 首帧或首尾帧：不复述图中已有的外观，写镜头运动、主体动作和环境变化；首尾帧写清两端之间怎样过渡。

## 排除内容

在正文里正面描述想要的画面（`an empty street with no cars`），不写一串“no ...”。渠道提供独立负面字段时，只列名词，如 `subtitles, watermark, extra people`。
