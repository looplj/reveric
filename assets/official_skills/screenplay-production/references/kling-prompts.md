# Kling 提示词

适用于 Kling 3.0 与 O1 系列（`kwaivgi-kling-v4.0` 等未单列型号走通用格式）。实际支持的输入模式（纯文本、单首帧、首尾帧或参考模式）、音频参考能力与可用时长一律以运行时模型查询结果为准。

## 公式与输入对应

- **文本生成**：`主体（外观）+ 运动 + 场景（环境）+ 镜头语言、光线与氛围`。
- **首帧／首尾帧**：图已锁定外观与开场（或两端）构图，正文专写中间发生的运动、交互、运镜与光声变化，不重述图中已有外观；只有尾帧没有首帧不受支持。（若当前型号在运行时支持 `reference` 模式，在主体首次出现处使用完整 `<ref input_id="…" label="…" />` 绑定并稳定沿用）。

## 多镜头（整数秒）

逐镜写出镜号与整数秒数（相加等于生成总时长，一镜一个主要运镜）；镜内节奏可补充相对时间（如 `At the 3rd second`）。仅需单个镜头时按事件顺序写连贯段落，不加镜号。

以下为 8 秒纯文本三镜头示例（若有首帧图则略去首帧已呈现的人物外观重复描述）：

```text
Shot 1 (4s): Medium shot in a dim apartment at night, warm lamp light from the left. A woman in a grey wool coat sits across a wooden table from a man in a dark shirt. She slides a brass key across the table toward him and stops at the edge, fingertip still on it. The man looks at the key, then up at her.
Shot 2 (2s): Close-up on the man. He asks (Mandarin, low and slow): "你真的要走？"
Shot 3 (2s): Overhead close-up of the key. Her finger lifts away and exits frame left; the key stays on the table edge.
```

## 台词、声音与语言

- 对白写为 `说话人（语种、语气与语速）: "原话"`（如 `The man (Mandarin, softly and hesitant): "你真的要走？"`），原话逐字保留不翻译；每句明确对应说话人，并按角色设计描述音色与情绪（若运行时不支持音频参考，需在正文写明声音特征）。
- 环境声与配乐用自然句直接描述（如 `faint indoor room tone`, `soft piano BGM`）。
- 提示词正文中英文均可，单条保持同一语言（对白保留剧本原文），不写负面清单。
