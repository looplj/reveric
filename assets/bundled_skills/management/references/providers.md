# 供应商与模型查询

用于确认当前配置了哪些聊天、图像、视频、音频模型，或核对模型能力。`Run providers` 只读，不创建供应商、不修改凭据；完整查询选项见 `Run help providers`。

先列出供应商，按返回 ID 查询全部模型，或筛选所需类型：

```json
{"command":"providers","subcommand":"list","options":{"enabled":true}}
{"command":"providers","subcommand":"read","options":{"provider_id":"{provider_id}"}}
{"command":"providers","subcommand":"models","options":{"provider_id":"{provider_id}"}}
{"command":"providers","subcommand":"models","options":{"provider_id":"{provider_id}","kind":"chat"}}
{"command":"providers","subcommand":"models","options":{"provider_id":"{provider_id}","kind":"video"}}
```

`provider_id` 必填。`kind` 是可选筛选条件，可取 `chat`、`image`、`video`、`audio`；省略时返回全部四种类型，每条结果都带有 `kind`。显式传空值或非法类型会报错。列表一次返回全部条目，不传 offset 或 limit。`provider_id` 原样复制，不做 URI 编码；从模型条目复制真实模型 ID，不按展示名自行拼接。

选择时核对 `available`、`capabilities_known`、`unavailable_reason`、能力和默认配置。保留用户指定型号或片段已有配置；需要更换时说明与当前任务相关的限制。没有已启用渠道时可不带 enabled 筛选检查实际配置，不虚构可用模型。

能力未知就保留未知，不用相似型号的参数补齐。聊天模型也会列出，但没有已验证的能力信息时，`capabilities_known=false`，能力和默认值为 null；这不等于模型不可用，应另看 `available`。可用性只反映本地配置，不证明远程权限、额度或网络可用。返回不包含凭据，不要求用户在对话中粘贴密钥。

视频模型另返回 `catalog_model_id`：同一型号在不同渠道的 `id` 写法不同，该字段给出应用识别出的统一型号，未识别时为 null。片段配置仍写入渠道 `id`。

视频草稿能力看 `capabilities.supports_draft`。为 true 时，`capabilities.draft` 返回 `resolution`、`completion_resolution`、`validity_days` 和 `output_formats`；为 false 或能力未知时，不请求草稿。草稿生成与转高清的调用方式见当前作品的工具技能（「剧本工具使用规范」或「画布作品工具」）的分镜与媒体节点附件。

查询完成后回到原业务：制作片段的配置与生成使用当前作品的工具技能（「剧本工具使用规范」或「画布作品工具」），角色／物品出图按 `Run help character` / `Run help item` 的说明调用。模型参数以此次查询与提交校验为准，不在其他技能中另维护一张固定型号限制表。
