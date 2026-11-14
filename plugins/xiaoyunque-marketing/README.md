# 小云雀-营销

根据[小云雀 API 体验指南](https://bytedance.larkoffice.com/docx/CQOYdJNLioLz6fxRzKXcCsKLnJh)，围绕商品信息和参考素材生成营销视频。

启用「小云雀-营销」，新增对应供应商实例，填写 Access Key。新建时可检查连接、查询积分，最后统一保存，保存后获取并选择模型。密钥与「小云雀-短片」独立配置，也可手动使用同一个账号的 Key。

- 模型：`seedance2.0_fast_vision`、`seedance2.0_vision`、`Seedance_2.0_mini`、`Seedance_2.0_mini_lite`。
- 支持文生视频和素材参考；不声明首尾帧模式。
- 「营销视频字幕」控制 `show_subtitle`，默认开启，仅存在于本插件。
- 营销成片时长预设 10/15/30/60 秒；参考数量按对应模型 catalog，与短片插件共用。当前 Seedance 2.0 系列为最多 9 张图片、3 个视频、3 个音频，合计 15 个；服务端仍校验模型和账号限制。
- 1080p 仅对 `seedance2.0_vision` 开放。
- 支持上传、连接检查、积分查询、双 ID 任务恢复。多视频结果只取第一条并记录日志。

构建时复用 `../xiaoyunque/src/provider.ts`，打包后的 ZIP 自包含，不依赖安装短片插件。在 `plugins/` 中运行 `npm test` 和 `npm run build`。真实生成需要配置有效 Access Key 后联调。
