# F：用户自配 S3 兼容参考存储

[返回方案总览](README.md) · [统一参考上传](video-generation.md#e1-参考准备素材复用与上传)

本文按当前客户端实现说明配置与上传边界；第三方存储互通需另行实测。

## 用途与接入方式

用户在设置中提供 S3 兼容连接。`ReferenceStorageService` 准备参考文件，`ObjectStorageService` 上传并提供外部可读地址；视频生成结果保存在本地。

应用不提供自有参考托管服务。统一准备规则见[参考素材上传与 Seedance Asset 认证](reference-upload.md)：图片／音频按 OSS、渠道自带上传、Base64 的顺序选路；本地视频文件按 OSS、渠道上传的顺序选路，不使用 Base64。配置了有效 OSS 就使用 OSS，普通渠道上传缓存不能抢先命中。OSS 未配置时，所有媒体才判断渠道上传能力；渠道上传不支持时，图片／音频直接使用 Base64，视频则要求配置 OSS。已认证 Asset 继续按模型能力直接引用。

这是 2026-11-11 更新并接入共享服务的规则。OSS 配置无效或上传失败时明确报错，不降级到渠道上传或 Base64；纯文本生成不依赖存储。

## 配置与凭据

配置模型为 `ObjectStorageConfig`，以版本化 JSON 保存在 `app_settings` 的 `object_storage_settings` 项中。字段包括 provider、endpoint、region、bucket、accessKeyId、secretAccessKey、keyPrefix、pathStyle 和可选 publicBaseUrl。

现有实现将连接参数和凭据一起保存在本地设置中；不把它描述成已经接入独立 Keychain 凭据引用或临时 sessionToken。凭据不得出现在日志、任务请求快照或对外返回的诊断文本中。

`pathStyle` 决定使用 endpoint/bucket/key 还是 bucket.endpoint/key。配置校验要求有效 HTTP(S) 地址、必填凭据与 Bucket，拒绝路径中的 `.` 和 `..`。默认 region、前缀及规范化规则以配置模型为准。

## 上传与读取流程

1. 在本机探测媒体规格并计算 SHA-256，按前缀、哈希和 MIME 对应扩展名构造对象 key。
2. S3 客户端发送签名 HEAD。当前实现将 404 和 403 作为需要尝试上传处理；PUT 的实际结果决定上传是否成功，其余异常明确抛出。
3. 需要上传时流式发送 PUT，并带真实内容长度、类型与哈希签名。
4. 配置了 publicBaseUrl 时返回公开地址；否则生成有效期 24 小时的预签名 GET URL，返回的 expiresAt 预留 5 分钟余量。
5. `ReferenceStorageService` 验证 URL 和有效期，并把本机探测的 mediaInfo 合并到参考信息。同一 MIME 与哈希的并发准备在进程内合并。

验收口径调整（2026-11-10）：原视频生成验收要求“403／断网不当成不存在”，本次将 HEAD 403 单独改为允许尝试 PUT。原因是缺少 ListBucket 权限时，S3 对不存在的对象也可能返回 403，直接拒绝会阻断具有写入权限的上传。403 本身不能证明对象不存在；这里只允许继续尝试写入，最终由 PUT 的实际结果决定成功或失败。断网及其他请求异常仍直接报错，不按对象不存在处理。这是对既有验收条件的明确修订，对应 `s3.dart` 的既有实现，本次没有修改 S3 代码。

以上 HEAD／PUT 已能跨任务复用相同内容，因此 OSS 路径不额外写渠道素材记录。渠道普通上传与认证则按[参考素材上传与 Seedance Asset 认证：统一记录与处理流程](reference-upload.md#统一记录与处理流程)入库，各类媒体只有选中对应渠道上传路径时才跨任务复用成功记录。Base64 提交不产生渠道上传记录；历史视频上传记录保留，在无 OSS 且渠道仍支持时可复用。

对象生命周期由用户 Bucket 控制。应用不部署对象续期或清理服务，不承诺远端对象会长期存在。连接测试写入固定探测对象，并通过实际访问地址读回验证；测试不会删除远端对象。

## 实施位置与验收

- `lib/shared/models/object_storage_config.dart`：配置、校验与编解码。
- `lib/shared/services/object_storage/s3.dart`：签名请求、对象存在检查和预签名 URL。
- `lib/shared/services/object_storage/service.dart`：保存配置、测试连接和上传。
- `lib/shared/providers/object_storage.dart`、`video_tasks.dart`：配置与参考上传的装配。
- `lib/shared/widgets/settings/object_storage_settings_section.dart`、`object_storage_form.dart`：设置入口。

回归入口是 `test/shared/services/object_storage/`、`test/shared/services/ai/video/reference_storage_service_test.dart` 与 `test/shared/widgets/settings/object_storage_form_test.dart`。这些测试验证本地逻辑和模拟请求；真实 Bucket、访问域名及模型拉取结果需使用用户指定的存储验证。本次文档清理未连接远端存储。
