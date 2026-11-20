# Veo 提示词

适用于 Veo 3.1 系列提示词写作。实际支持的输入模式（纯文本、单首帧、首尾帧或图参考）、参考上限与可用时长一律以运行时模型查询结果为准。整条提示词写英文，台词保留剧本原文。

## 单镜头与多镜头公式

单镜头按 `镜头与构图 → 主体 → 动作 → 环境 → 风格与光线` 写成连续段落：

```text
Medium shot, a woman in her thirties with a grey wool coat slides a brass key across a wooden table toward the man opposite her, in a dim apartment at night. Warm lamp light from the left, soft shadows, naturalistic film look.
```

需要多镜头切镜时，用首尾相接的整数时间段（末段终点等于总时长），每段后紧跟本段声音：

```text
[00:00-00:04] Medium shot, ... SFX: the key scrapes softly across the wood.
[00:04-00:06] Close-up on the man, ... He says in Mandarin, quietly, "你真的要走？"
[00:06-00:08] Overhead close-up of the key, ...
```

## 台词、声音与参考

- **对白与语言**：在引号前指明说话人与口语语种（如 `The man says in Mandarin in a low, slow voice, "你真的要走？"`），原话逐字保留。
- **音效与环境音**：音效写 `SFX: ...`，环境底声写 `Ambient noise: ...`；配乐没有独立字段，用句子或 `SFX:` 说明配器与进入时机。声音驱动人物反应或动作时，按因果顺序写进动作句。
- **多图参考（仅当运行时支持 `reference` 模式）**：用身份称呼衔接完整 `<ref input_id="…" label="…" />`（如 `Using the provided images for the woman <ref input_id="…" label="林岚" /> and the apartment <ref input_id="…" label="客厅" />, create a medium shot of ...`），每张图对应单个明确主体且不超过运行时上限。
- **首帧／首尾帧**：直接写镜头运动、主体变化与两端过渡，不重复外观与负面清单（需要安静空境就正面写 `an empty street`，不堆砌“no ...”）。
