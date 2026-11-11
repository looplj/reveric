# 分镜与媒体节点、输入与生成

通过 `production/clips` 读取当前作品的制作片段，可按 `kind` 筛选图片、视频或音频。详情路径由返回的 `path` 定位，字段契约见 `/_schema/production`。

Create `production/clips` 时填写本次标题、提示词和已确定的媒体配置，不带 `scene_id` 或 `episode_id`。系统同时放置对应画布节点，后续沿用返回身份，不重复建立内容。节点 ID 与片段 ID 不同，按节点 `ref_type/ref_id` 确认关联。

```json
{"path":"production/clips","fields":{"kind":"video","title":"门口对话","prompt":"已确认的镜头与逐字对白","duration_ms":6000}}
```

Write 更新媒体配置；Edit 可局部替换标题或提示词。视频 `duration_ms` 单位是毫秒，生成要求整秒：4 秒写 4000，不写 4。没有场次归属、分镜排序或主体字段。生成片段的采用结果和剪辑时间线分别维护，采用视频不会自动加入时间线。仅修改文字时不发起生成。

<inline-ref type="reference" skill="剧本工具使用规范" section="素材与输入关系">references/clips.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="文本输入">references/clips.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="提示词中的引用">references/clips.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="Seedance 合规校验">references/clips.md</inline-ref>

<inline-ref type="reference" skill="剧本工具使用规范" section="生成与结果采用">references/clips.md</inline-ref>
