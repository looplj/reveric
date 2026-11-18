# 分镜与媒体节点、输入与生成

通过 `production/clips` 读取当前作品的制作片段，可按 `kind` 筛选图片、视频或音频。定位或选择片段时使用 `production/clips?view=summary`，省去提示词正文；批量读取片段的提示词全文时，使用 `view=full`。省略 view 保留完整列表，分页参数仍适用。详情路径由返回的 `path` 定位，字段契约见 `/_schema/production/clips`。

<inline-ref type="reference" skill="剧本工具使用规范" section="定位和配置">references/clips.md</inline-ref>

Create `production/clips` 时填写本次标题、提示词和已确定的媒体配置。系统同时放置对应画布节点，后续沿用返回身份，不重复建立内容。节点 ID 与片段 ID 不同，按节点 `ref_type/ref_id` 确认关联。

```json
{"path":"production/clips","fields":{"kind":"video","title":"门口对话","prompt":"<ref input_id=\"lead\" label=\"主角定妆\" /> 中的主角走到门口，敲门问：“有人吗？”","duration_ms":6000,"inputs":[{"id":"lead","ref_type":"node","ref_id":"{已读取的主角图片节点 ID}","role":"reference_image"}]}}
```

Write 更新媒体配置；Edit 可局部替换标题或提示词。生成片段的采用结果和剪辑时间线分别维护，采用视频不会自动加入时间线。仅修改文字时不发起生成。

## 角色图片节点

先读 `characters` 取得角色 ID，再在 `production/clips` 中查找 `kind=image` 且 `character_id` 相同的片段。已有对应角色图时复用；需要新建时，Create `production/clips`，在创建图片片段时绑定角色：

```json
{"path":"production/clips","fields":{"kind":"image","title":"主角定妆","character_id":"{角色档案 ID}"}}
```

系统同时创建图片节点。在 `production/canvas/nodes` 中用片段 ID 匹配节点的 `ref_id`，取得节点 ID。若要沿用已有定妆图，把确认的图片素材 ID 写入该图片片段的 `adopted_asset_id`。视频分镜需要引用角色图时，在目标片段的 `inputs` 中设置 `role=reference_image`、`ref_type=node`、`ref_id=角色图片节点 ID`；更换来源时保留原输入 ID 和其余输入。

<inline-ref type="reference" skill="剧本工具使用规范" section="素材与输入关系">references/clips.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="文本输入">references/clips.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="提示词中的引用">references/clips.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="Seedance 合规校验">references/clips.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="生成与结果采用">references/clips.md</inline-ref>
