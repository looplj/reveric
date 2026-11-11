# 风格查询、自定义与设置

<inline-ref type="reference" skill="剧本工具使用规范" section="查询与自定义">references/styles.md</inline-ref>

## 应用到作品

通过 Write 保存选择；字段契约见 `/_schema/production`。

| 用户意图 | 字段路径 | 写入值 |
|---|---|---|
| 设置作品默认风格 | `production/settings/style_id` | 查询返回的 ID |
| 清除作品默认风格 | `production/settings/style_id` | `null` |
| 单独设置图片或视频节点 | `production/clips/{clip_id}/style_selection` | 查询返回的 ID |
| 节点跟随作品 | `production/clips/{clip_id}/style_selection` | `null` |
| 节点明确不使用风格 | `production/clips/{clip_id}/style_selection` | `"none"` |

先读节点关联片段，沿用真实 ID。写后回读字段；节点值为 `null` 时，再读作品的默认风格确认继承结果。报告实际名称、范围与是否跟随，不把清除默认值说成清除了所有独立设置。无效或无权限的 ID 应重新查询，不能当作无风格。
