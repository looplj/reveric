# 风格查询、自定义与设置

## 查询与自定义

通过 `Run styles` 查询、新建和编辑风格，options 参数如下；参数值均为字符串。

| subcommand | 必填 options | 可选 options |
|---|---|---|
| `list` | 无 | `search` 按名称子串匹配；`category` 为 live_action、two_d、three_d 或 custom |
| `read` | `style_id` | 无 |
| `create` | `name`，`before` 与 `after` 至少一项非空 | 无 |
| `update` | `style_id`，以及 `name`、`before`、`after` 至少一项 | 未传的字段保持原值 |

```json
{"command":"styles","subcommand":"list","options":{}}
{"command":"styles","subcommand":"read","options":{"style_id":"<查询返回的 id>"}}
{"command":"styles","subcommand":"create","options":{"name":"巨兽灾难写实CG","before":"写实三维电影画面，……","after":"避免水墨晕染、卡通比例。"}}
{"command":"styles","subcommand":"update","options":{"style_id":"<自定义风格 id>","before":"……"}}
```

列表返回 `entries`，每项包含 `id/name/category/source`，不含提示词正文。详情额外返回 `before`、`after`，分别为放在场景提示词前、后的风格文本；需要比较具体视觉约束时再读取详情。内置风格和当前作品可用的自定义风格共用同一套 ID，不自行拼接或转换。

风格只是提示词前后缀，名称不代表调用对应的渲染引擎。用户问有哪些风格时，先 `list` 再回答，不凭印象列举。

自定义风格：
- `before` 写全局通用的画面类型、材质、光影和表演基调，`after` 写需要统一追加的约束；单场的色调、道具和情绪留在各分镜提示词里，不写进风格。
- 内置风格只读，`update` 内置 ID 会失败；需要基于内置风格调整时，先 `read` 再用 `create` 另存。
- 新建和编辑前先把名称与前后缀文本给用户确认；`update` 会影响所有引用该风格的作品和节点。
- `create`、`update` 返回保存后的完整风格。重名时名称会自动追加序号，以返回的 `name` 为准报告。
- 新建只是加入风格库，不会自动应用；需要使用时按“应用到作品”写入返回的 `id`。

## 应用到作品

使用通用资源工具保存选择，字段契约以 `Read /_schema/screenplay` 和 `Read /_schema/clips` 为准。

| 用户意图 | 字段路径 | 写入值 |
| --- | --- | --- |
| 设置整个剧本的默认风格 | `/screenplay/style_id` | 查询返回的 ID |
| 清除剧本默认风格 | `/screenplay/style_id` | `null` |
| 单独设置图片或视频节点 | `/clips/{clip_id}/style_selection` | 查询返回的 ID |
| 节点跟随剧本 | `/clips/{clip_id}/style_selection` | `null` |
| 节点明确不使用风格 | `/clips/{clip_id}/style_selection` | `"none"` |

```json
{"path":"/screenplay/style_id","value":"<查询返回的 id>"}
{"path":"/clips/<真实 clip_id>/style_selection","value":null}
```

以上是 Write 输入。节点 id 与 clip_id 不同，先读取节点关联的片段身份。仅改一集时，查询该集片段并按类型筛选图片和视频后逐项写入，不修改全剧默认设置；批量调用可使用 Codemode。

写后回读字段；节点值为 null 时，再读剧本 style_id 确认实际继承值。报告保存的名称、范围及是否跟随，不把清除全局风格说成清除了所有独立设置。不存在、被删除或无权限的 ID 必须报告失败并重新查询，不默认为无风格。
