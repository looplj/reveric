---
name: 剧本制片
when_to_use: 把剧本做成视频或按创意直接制作短片时使用：图像、视频、音频生成，将内容拆成分镜，在制作画布中组织制片素材与参考关系，准备参考图与首尾帧，编写或修改生成提示词，审查或检查视频提示词（如“看下这段提示词有什么问题”），调整导演台机位，检查与返修生成结果。
description: 将剧本或创意转成可制作的分镜，提供人物与场景图片配方、分模型图像与视频提示词写法、镜头案例、整场制作流程及结果诊断对照。
metadata:
  category: 剧本
  tags: ["视频", "制片", "分镜", "图片参考", "视频提示词", "模型能力"]
---

# 剧本制片

剧本作品的“视频”工作区与画布作品的制作画布均适用本技能（导航“视频”亦可能是界面操作入口，需结合当前对象与任务区分）。界面一条“分镜”对应一条图片或视频条目，可包含提示词中的多个 Shot 镜头（“AI 拆分镜”直接创建/修订这些条目，不建独立镜头资源）。

按「工具技能」（剧本作品用「剧本工具使用规范」，画布作品用「画布作品工具」）读取实际生效风格、文本输入与字段契约；自动注入的风格不重复抄写，保留用户指定风格。独立文件加工与多轨拼剪使用「媒体处理与剪辑」。

## 进入任务与工作边界

- **工具与方法分工**：路径、字段、资源读写、画布节点连线、导演台操控与提交生成契约均由「工具技能」维护；本技能负责制片编排、视觉资产规范、镜头设计与模型提示词适配。
- **依据与授权边界**：以实际原文、逐字对白、已确认人物/道具依据和已有片段为准，不把梗概或旧草稿当正文；局部任务只改目标范围。仅有原文且要文字草案时可直接编排并标明缺口；没有剧本且用户授权发挥时，先按 [制片流程](references/production.md) 锚定观看重点再推进。

## 按任务读取附件

先确认本次涉及环节，按需加载对应入口附件（已在上下文中且未修改的不重读）；图像/视频模型专属附件及镜头案例从各自入口按需单选，模型未定时走通用写法。

| 用户任务 | 首先读取 | 条件追加与后续路线 |
|---|---|---|
| 设计或调整人物外貌、服装与气质 | [人物选角与造型](references/character-design.md) | 写图像成稿时进入下方人物场景图或定妆图路线 |
| 已有造型，制作人物与环境同框的图片 | [人物场景图、复杂姿态与镜面构图](references/image-scene-portrait.md) | 用已有素材时追加 [图片资产与参考](references/image-references.md)；成稿按 [图像模型提示词适配](references/image-prompts.md) 选模型附件 |
| 制作或修改定妆板、转面图或状态变体 | [图片资产与参考](references/image-references.md) → [人物定妆、转面与状态变体](references/image-character-sheets.md) | 需重新定造型先走人物设计路线；成稿按 [图像模型提示词适配](references/image-prompts.md) |
| 制作场景图、道具图、站位图、首尾帧或分镜拼图 | [图片资产与参考](references/image-references.md) → [图片提示词配方](references/image-recipes.md) | 站位/起点未定时读 [分镜指南](references/storyboard.md)；成稿按 [图像模型提示词适配](references/image-prompts.md) |
| 拆分镜，调整站位、动作、景别或切点 | [分镜指南](references/storyboard.md) | 涉及跨段接缝、依赖或总时长读 [制片流程](references/production.md)；写正文时入视频路线 |
| 编写、实质改写或审查视频提示词 | [视频提示词](references/video-prompts.md) → [镜头任务配方](references/shot-recipes.md) | 涉及空间与镜头设计变化先读 [分镜指南](references/storyboard.md)；具体案例按配方表取用，模型格式查 `video-prompts.md` 对照表 |
| 仅更换模型、画幅、时长或输入方式 | [模型能力与配置](references/model-capabilities.md) | 图片入 [图像模型提示词适配](references/image-prompts.md)，视频入 [视频提示词](references/video-prompts.md) 按新模型重排 |
| 使用导演台布景、摆姿态、排机位或预演 | [分镜指南](references/storyboard.md) 占位与导演台节 | 操作前必读「工具技能」导演文档附件；成片参考绑定入上方图片/参考路线 |
| 提交生成、绑定参考、采用结果 | [制片流程](references/production.md) 依赖与核对节 | 操作前必读「工具技能」分镜与媒体节点附件；模型未核查时读 [模型能力与配置](references/model-capabilities.md) |
| 检查、补拍或返修生成结果 | [结果诊断与改写对照](references/troubleshooting.md) → [制片流程](references/production.md) 验收与替换节 | 读帧/音轨/接缝对比用「媒体处理与剪辑」；纯提交故障先按「工具技能」查配置与输入 |
| 从剧本或创意制作整段短片 | [制片流程](references/production.md) | 按阶段依上述各行按需加载；全流程参考读 [整场制作案例](references/examples/scene-example.md) |

调用 `<skill_resources>` 时 `name` 使用「剧本制片」，按上表精确路径直接 `reference-get`；未知附件路径时再 `reference-list`。

## 写入与交付底线

- 资产命名见 [图片资产与参考](references/image-references.md)，占位图命名见 [分镜指南](references/storyboard.md)；资源读写、节点/资产参考优先级及 `<ref>` 标签语法严格遵循「工具技能」。
- 写入后必须回读实际保存内容，核对范围覆盖、相邻衔接、配置时长一致性及 `<ref>` 保留完整；缺失的设定、素材与未核查配置留在交付说明，不伪造引用。
- 严格区分**“草稿完成 / 片段已保存 / 参考待绑定 / 待生成 / 仅静帧已查 / 连续视频与音轨已核对”**，不以文字写入代替实际生成与看片验收。
