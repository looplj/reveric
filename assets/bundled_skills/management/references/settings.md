# 打开应用设置

打开指定设置分区，让用户在界面中配置：

```json
{"command":"settings","subcommand":"open","options":{"section":"storage"}}
```

| section | 设置分区 |
| --- | --- |
| `general` | 通用 |
| `appearance` | 外观 |
| `editor` | 字体与编辑 |
| `reading` | 阅读 |
| `ai_agents` | AI 助手 |
| `providers` | AI 供应商 |
| `usage` | 用量 |
| `mcp` | MCP |
| `plugins` | 插件 |
| `backup` | 备份 |
| `about` | 关于 |
| `remote` | 远程 |
| `storage` | 存储 |

调用后即可继续对话，无需等待页面关闭。
