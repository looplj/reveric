# 参考素材上传与 Seedance Asset 认证

[返回方案总览](README.md) · [视频生成与恢复](video-generation.md) · [用户自配 S3](object-storage.md)

更新日期：2026-11-11。本文记录统一参考准备的目标规则，实施状态统一记录在总览的 E1-04。路径优先级与图片／音频 Base64 输入已接入共享服务；真实渠道调用仍需验收。

## 目标与决定

图片／音频参考按 **OSS → 渠道自带上传 → Base64** 选择准备方式；本地视频参考按 **OSS → 渠道自带上传** 选择准备方式，不使用 Base64。这里的 OSS 指应用现有的用户自配 S3 兼容对象存储，规则适用于所有已接入的视频供应商。

1. 已有当前渠道可用的 Seedance Asset，且目标模型支持这种引用时，继续直接引用。认证引用属于独立能力，不重新上传本地文件；下面的规则用于仍需准备的本地参考文件。
2. 图片／音频／视频：已配置有效 OSS 就使用 OSS，即使已有渠道上传缓存也不优先使用缓存。只有 OSS 未配置时，才判断当前渠道是否有已接入且满足用途的上传协议；有则在该路径内先复用有效记录，再按需上传。
3. 图片／音频：OSS 未配置且渠道没有满足用途的上传能力时，直接使用 Base64 输入，不以模型是否登记 Base64 支持作为额外选路条件；供应商拒绝请求时正常展示错误，不自动改走其他路径。
4. 本地视频文件：优先使用 OSS；OSS 未配置时，使用当前渠道已接入且支持视频的上传协议，并可复用有效视频上传记录。两条路径都不可用才提示配置 OSS，不使用视频 Base64。
5. OSS 配置无效、已选路径鉴权失败、网络失败、上传失败或回执无效时，直接报错，不自动切换到下一条路径。上述顺序是按已配置能力选路，不是失败后的降级链。
6. 普通上传和 Seedance Asset 认证保持独立。渠道上传与认证继续保存在 `ProviderAssets`，通过 `kind` 区分；OSS 保留哈希查重，Base64 只在提交时构造，两者均不新增渠道上传记录。
7. 88API 的素材上传仍是独立渠道扩展，不为所有 New API 兼容渠道默认开启。其他渠道也必须逐一确认上传与 Base64 输入能力。

本次统一调整现有渠道的选路顺序，补充图片／音频 Base64 路径，视频继续支持 OSS 与渠道上传。保留桌面制作流程，共享实现覆盖 Windows、macOS、Android；不新增移动端制片页面、任意 HTTP 上传配置器或远端文件管理页面。

## 当前实现与需要改变的位置

`ReferenceStorageService` 已负责媒体探测、OSS 与渠道上传、上传记录复用和引用校验。88API、秘塔、PureFox Media、AtlasCloud 已有上传适配；当前代码仍在 OSS 选路前检查渠道上传缓存，需要按本文顺序调整。`VideoTaskService` 保留已认证 Asset 的独立引用流程。

`ObjectStorageService.upload` 以内容哈希和 MIME 扩展名构造对象 key，先 HEAD，再按需 PUT。对象存在时直接取得访问地址；私有桶重新签发读取 URL。因此 OSS 已具备跨任务复用能力，无需本地上传记录。现有 S3 客户端把 HEAD 404、403 作为尝试 PUT 的条件，其余异常抛出，本次不改这条既有契约。

`ProviderAssetService` 当前有 `certify` 操作，现有 `ProviderAssetClient` 接受公开 URL、登记素材并查询状态。`ProviderAssets`、节点认证徽标、认证菜单以及 Agent 的 `certifications` 都在使用这些状态。

生成入口、历史重试、任务恢复与 Agent 必须使用同一份按媒体类型和模型能力作出的预检结果。混合参考必须在发送任何文件前确认每个输入都有可用路径；不能先上传图片，随后才发现视频既没有 OSS 也没有可用的渠道上传。认证菜单仍按公开 URL 要求预检。

## 两种独立协议

在代码中的 `AiProviderTypeConfig` 增加可选的 `uploadProtocol`、`assetProtocol`，与现有媒体协议并列。它们属于已接入能力声明，不增加用户持久化设置字段，不让用户手填接口路径。

| 协议 | 操作合同 | 结果与状态 |
| --- | --- | --- |
| `UploadProtocol` | 读取本地文件并上传，必要时完成协议要求的处理等待 | HTTP(S) 访问 URL 或渠道文件 ID；可选素材有效期 |
| `AssetProtocol` | 提交 Seedance 素材登记／认证，查询处理状态 | Asset ID、查询 ID、素材组 ID，以及 processing／active／failed |

上传能力与认证协议的目标登记如下。是否支持图片、音频或视频按具体渠道合同与模型能力判断，媒体选路遵守前述统一规则：

| 渠道类型 | `uploadProtocol` | `assetProtocol` | 凭据 |
| --- | --- | --- | --- |
| `api88` | `api88_media` | 空 | 上传使用现有 API Key |
| `metaso` | `minimax_files` | 空 | 上传使用现有 API Key |
| `volcengine` | 空；图片／音频无 OSS 时使用 Base64 | `volcengine_asset` | 认证使用现有 AK/SK 和项目名 |
| `atlascloud` | `atlascloud_media` | `atlascloud_asset` | 认证使用现有 API Key |
| `purefox_media` | `purefox_uploads` | 空 | 上传使用现有 API Key |
| 其他渠道 | 未登记则保持空 | 本期保持空 | 沿用现有生成和 OSS 配置 |

空值表示本方案没有接入该能力，不代表厂商没有相应接口。MiniMax 官方和其他兼容渠道不因复用视频协议而自动获得秘塔上传能力。

协议支持和配置就绪分开判断：静态协议决定是否支持操作，运行时配置决定凭据是否齐全，模型和调用用途决定能否消费结果。火山缺少 AK/SK 只影响认证，不应使普通视频生成被判为未配置。

`providerSupportsAssetCertification` 保留对 UI 和 Agent 的现有含义，内部改用 `assetProtocol` 与对应凭据要求判断。客户端工厂按枚举穷举分派，删除“非 AtlasCloud 就当成火山”的默认分支。

## 参考结果的表达

沿用现有 `VideoReference` 的角色、MIME、大小、本地探测信息和字符串 `url`，不为本次选路新增整套来源类型。适配器按目标模型能力校验并编码以下引用：

| 来源 | 表达 | 消费规则 |
| --- | --- | --- |
| HTTP 来源 | HTTP(S) URL、可选有效期 | 校验协议、host、无 userInfo 和有效期；认证接口要求可公开读取 |
| 上传文件引用 | 当前渠道返回的原始文件引用或 key | 仅在 OSS 未配置且已选择渠道上传时复用，只能交给支持它的同一渠道实例 |
| Base64 输入 | 接口要求的 Base64 字符串或 data URI | 仅限图片／音频输入；在提交时由本地文件构造，不落上传记录 |
| Asset 引用 | `asset://{remoteId}` | 当前渠道 active 认证记录，且目标模型支持 |

秘塔文件引用保持 `mm_file://{file_id}` 原始字符串，不交给 Dart `Uri` 解析；PureFox key 同样按渠道合同使用。Base64 不能伪装为 HTTP URL 或渠道上传成功结果，也不能传给只接受公开 URL 的认证接口。

Base64 路径在编码前检查原始文件大小、MIME 和目标模型限制，计入编码后的体积增长及所有参考合并后的完整请求体上限；超过限制时明确报错并提示使用 OSS，不截断文件、不丢弃参考。只在发送请求时构造编码内容，控制内存占用，不写入 `ProviderAssets`、任务快照、日志、诊断导出或 Agent 资源结果。任务仍保存本地素材身份，重试时重新构造；已取得生成任务 ID 后只恢复查询与下载。

## 统一记录与处理流程

`kind` 区分操作，`status` 表示进度。两类操作沿用现有三种状态，不新增上传专属状态机。

| kind | processing | active | failed |
| --- | --- | --- | --- |
| `upload` | 正在上传，尚无可复用结果 | 上传完成，结果已保存 | 上传失败、中断或结果失效 |
| `certification` | 正在提交或等待认证 | 已通过认证 | 认证失败或提交中断 |

先确定准备路径。仅选择渠道上传或认证操作后，才执行统一顺序：**查有效记录 → 保存 processing → 执行操作 → 保存远端结果 → 更新状态**。OSS 与 Base64 不进入这套记录流程。

1. 本地校验和凭据检查通过后，按 `assetId + providerId + kind` 查当前记录。有效 active 直接复用，不发起重复操作。
2. 需要执行时，新建记录或复用原行，设为 processing，清空上次远端结果和错误，保存本次配置摘要。写库失败不发请求。
3. 执行对应协议。上传用 UploadClient；认证保留准备公开 URL、提交 Asset 接口的流程。
4. 普通上传确认完成后，在同一次数据库更新中保存文件 ID／URL、有效期并设为 active。认证提交成功后保存 Asset ID 和查询 ID，仍为 processing，轮询通过后再设为 active。
5. 操作失败设为 failed 并保存错误。重试使用原行重新走 processing，不保存上传凭证，也不保留未完成上传的预分配 URL。

上传成功但结果写库失败时，不提交视频生成。进程仍在时可用内存回执重试写库；如果此时退出，下次按中断处理，可能再次上传。统一流程不承诺远端与本地数据库之间的原子性。

### 素材表字段

扩展现有 `ProviderAssets`，同一素材、同一渠道最多有一条未软删除的 upload 记录和一条 certification 记录。

| 新增字段 | 类型与默认值 | 作用 |
| --- | --- | --- |
| `kind` | 枚举文本，默认 `certification` | 区分普通上传和认证，旧行自然保留认证含义 |
| `contextHash` | 可空文本 | 上传协议、规范化端点、凭据摘要和 MIME 的规范序列化摘要，阻止配置变化后误用旧结果 |
| `remoteUrl` | 可空文本 | 上传成功后的 HTTP 读取地址，不能写申请阶段的地址 |
| `expiresAt` | 可空 DateTimeColumn | 当前引用的有效期；空值表示未知，SQLite 存 INTEGER Unix 秒 |

沿用 `remoteId` 保存上传文件 ID 或认证 Asset ID，由 kind 与 providerId 对应的渠道协议解释；`remoteTaskId`、`remoteGroupId` 保留已有用途。记录不保存 API Key、upload_url、上传 token 或 headers。remoteUrl 可能包含访问签名，不进入日志、Agent 资源、诊断导出或生成请求快照；数据库与备份沿用现有保护边界。

不重复保存 protocol 和 contentHash：协议通过 providerId 对应的渠道配置与 kind 推导；素材内容由 assetId 标识，Assets 已有 sha256。现有导入按内容哈希复用同字节资产，不同内容创建新资产；改名或同内容文件路径恢复不改变素材身份。上传接口需要的 SHA-256 仍按其合同计算，不因此新增 ProviderAssets 内容哈希列。

上传缓存命中首先要求 OSS 未配置且已选择支持本次媒体类型的渠道上传路径，再要求 assetId、providerId、kind=upload 匹配，status=active、配置摘要匹配，目标模型或认证用途能消费该引用，且已知有效期尚未到期。失败或过期的记录不能直接引用。已知过期时记 failed／expired，再按需重新上传；未知期限不等于失效，不因此每次上传。上游明确报告文件不存在或失效时使缓存失效；网络错误、鉴权失败不能当成文件失效，更不能为了刷新素材自动重提结果不确定的收费请求。

认证查询、菜单、盾牌、轮询与 Agent certifications 全部显式过滤 kind=certification。旧认证记录继续按既有 providerId、remoteId 和状态语义使用；不把上传配置摘要要求强加给旧认证，也不根据当前凭据猜测历史值。

### DAO 与并发

DAO 的 find、start、processing、watch 必须明确接收 kind 或提供用途明确的方法，取消仅按 assetId／providerId 取单行的假设。重试复用当前行；查询过滤软删除记录。新增普通索引 `provider_assets_by_asset_id_provider_id_kind`、`provider_assets_by_kind_status`，不增加表级约束。

应用级共享服务按 `assetId + providerId + kind` 合并同一操作，并串行处理配置变更后的重试；原请求结束前不重置同一行，避免迟到回执覆盖新结果。事务只覆盖行查找和更新，不跨网络等待。上传与认证可以分别执行，但同一用途不能并行启动两个请求。当前应用单进程管理素材操作，不为本次功能引入跨进程锁。

### 重启与迁移

- upload 的 processing 行启动时标记 failed／interrupted，不查询预分配对象、不恢复 PUT。用户重试重新上传。
- certification 的 processing 行保持现有规则：有 remoteId 继续轮询，没有则标记 failed／interrupted。
- active 上传记录仅在重新选中渠道上传路径后跨任务、跨重启复用；已提交的视频任务只恢复查询与下载，不重新准备素材。

原渠道上传方案以 `v0.8.2` 的 schema 4 为基线，通过 schema 5 增加上述列和索引。此次统一选路沿用已有记录，不因 Base64 或选路调整再新增字段、迁移或删除历史上传记录；后续若确需调整 schema，另按迁移规则核对最新正式发布基线。

旧行保留 ID、远端 ID、状态、错误、时间戳及软删除标记，kind 为 certification；协议继续从渠道配置推导，无法识别渠道时禁止自动调用。contextHash、remoteUrl 和 expiresAt 留空，不删除或重做旧认证。新装库、升级库、备份读取与恢复同步处理新增列。用受支持正式版的旧结构 fixture 验证版本、行数、字段值、索引和 Typed DAO 回读。

## 素材准备与依赖方向

`ReferenceStorageService` 仍是共享素材准备入口，接收当前渠道、目标模型或认证用途。用途至少区分“视频参考”与“认证所需公开 URL”，不能把任意上传成功当作准备完成。

准备分为可重复调用的本地检查和实际执行：检查阶段确定路径、校验凭据与素材限制，不上传文件；执行阶段使用固定的配置快照完成上传。UI 预检只改善提示，任务执行前必须重新检查。

OSS 的三态判断统一放在 `ReferenceStorageService` 的共享预检中，UI、任务服务和 Agent 只消费预检结果，不各自重新判断配置字段。`ObjectStorageService` 的加载接口提供设置是否存在、解码结果或配置格式错误；`ObjectStorageConfig.validate()` 继续提供字段校验依据，预检据此分类：

| 配置状态 | 判定 | 路径处理 |
| --- | --- | --- |
| 未配置 | 设置不存在，或有效解码后是完整的默认空配置；默认 region／keyPrefix 本身不代表已配置 | 所有媒体继续判断渠道上传能力；渠道不支持时，图片／音频直接使用 Base64，视频提示配置 OSS |
| 配置无效 | 非空设置无法解码、字段类型不合法，或已有非默认配置未通过 validate | 返回配置修复错误，不继续渠道上传或 Base64 |
| 配置就绪 | 配置有效且 validate 通过 | 本地文件必须选择 OSS，不先查询渠道上传缓存；这只是本地配置检查，不代表网络、凭据权限或 Bucket 已验证可用 |

加载层不得把损坏设置、缺字段的部分配置或解码异常变成默认空配置；数据库读取失败作为独立错误传播，不归为未配置。除已满足要求的认证 Asset 引用外，预检必须先加载并判断 OSS，再决定是否查询渠道上传缓存。缓存不能掩盖损坏或不完整的 OSS 配置。

`storage_dialog.dart` 根据共享预检结果打开配置窗口或展示修复错误，保存后重新调用预检；任务层在实际执行前调用同一预检重新取当前配置。现有只返回 bool 的 `isConfigured()` 不能继续承担选路判断，设置表单仍可使用配置模型进行字段校验。


```text
生成入口／历史重试／Agent
          ↓
VideoTaskService
          ├─ 当前渠道、模型支持且已有 active Asset → 直接引用
          └─ ReferenceStorageService
                ├─ OSS 配置无效 → 报错并修复配置
                ├─ OSS 配置就绪 → HEAD／PUT → HTTP 来源
                └─ OSS 未配置
                      ├─ 渠道上传支持本次媒体 → 复用有效上传记录或上传并落库
                      └─ 无可用渠道上传
                            ├─ 图片／音频 → 提交时编码
                            └─ 视频 → 要求配置 OSS

认证菜单／Agent assets certify
          ↓
ProviderAssetService.certify → 保存 processing
          ↓
ReferenceStorageService（要求公开 URL）
          ↓
ProviderAssetClient（按 assetProtocol 分派）
          ↓
ProviderAssets 状态记录与轮询 → 认证 UI
```

保留 `ProviderAssetService` 名称，不把通用素材概念限制为图片认证；本期已有的 `certify` 操作继续服务认证流程。底层分别使用 `UploadClient` 和 `ProviderAssetClient`。上传客户端不反向依赖 `ProviderAssetService`，避免与素材准备服务形成依赖环。

新增多步上传实现使用短生命周期 Orchestrator 编排，所有输入通过方法参数传入；已有 Service 保留现有生命周期，不借此次接入重构任务调度器。

### 路径选择

以下按表中顺序判断。已选路径内可以复用结果，但复用不能改变路径优先级。

| 条件 | 行为 |
| --- | --- |
| 无参考输入，或草稿转正式无需重新准备参考 | 不检查上传配置 |
| 当前模型支持当前渠道已认证 Asset | 直接引用，不重新上传本地文件 |
| 仍需准备本地参考，OSS 配置无效 | 提示修复，不查询渠道缓存或构造 Base64 |
| 仍需准备本地参考，OSS 配置就绪 | 图片、音频、视频全部走 OSS，按哈希查重；不优先复用渠道缓存 |
| OSS 未配置，本地视频没有可用的渠道上传能力 | 要求配置 OSS，整次准备在发送前停止 |
| OSS 未配置，渠道上传能力支持本次图片／音频／视频及调用用途 | 先复用有效渠道记录；没有有效记录时按 processing 流程上传 |
| OSS 未配置，图片／音频无渠道上传能力 | 校验编码后体积和整次请求上限，提交时构造 Base64 |
| 已选路径凭据无效、格式不支持、限流或服务失败 | 返回对应错误，不自动切换路径 |

切换为 OSS 后保留原渠道上传记录，但不再据此绕过 OSS；以后清空 OSS 配置时，图片／音频／视频均可重新检查对应记录是否有效，并在渠道支持时复用。已有远端生成任务不重新准备素材。

认证前置准备仍必须得到公开 URL：先 OSS，再判断当前渠道的上传结果能否满足认证接口；Base64 和渠道私有文件 ID 不满足这一要求。没有公开 URL 路径时要求配置 OSS，不借用其他渠道托管文件。现有已认证 Asset 的复用规则保持独立。

## 88API 上传合同

适配器使用 `api88` 的有效 Base URL 和 API Key，拼接相对路径 `media/uploads`，避免重复 `/v1`。

1. 在本地确认 MIME、长度和目标模型限制。接口限制原始文件为 1 至 100,000,000 字节，模型限制更严格时取较小值。
2. 计算 SHA-256 原始摘要。申请字段 `sha256` 使用 Base64URL 编码且去掉 padding；现有十六进制哈希继续可用于 OSS key 和本地去重，不能直接当作申请字段。
3. 统一流程已创建 processing 行后，POST 申请凭证，发送 `size`、`mime_type`、`sha256`，使用渠道 Bearer API Key。HTTP 200 响应返回 `url`、`upload_url`、方法、headers 和凭证期限；这些申请信息全部只保留在内存，此时不写 remoteUrl。
4. 校验申请响应，原样使用 `upload_url` 与返回的 headers 流式 PUT 原始二进制。请求带准确 Content-Length 和 Content-Type，不使用 multipart、Base64 请求体或未知长度的 chunked 上传。上传地址不携带渠道 API Key。
5. 收到 HTTP 201 后，校验完成响应的 URL、大小、MIME 和素材有效期。将成功结果写入 remoteUrl／expiresAt，并在同一次更新中设为 active，随后才允许生成请求使用该结果。

[88API 上传契约](https://88api.ai/zh/docs/api/video/video-api-standard/#36-本地素材上传先申请再-put)中的申请 `url` 是预分配的读取地址，`upload_url` 是写入地址。两者不得相互推导；申请成功不代表文件上传成功。申请响应的 `expires_at` 是上传凭证期限，完成响应中的同名字段才是素材期限。文档说明素材自上传起保存 30 天，读取和引用不续期。

上传适配器可按官方合同，在当前调用内处理 PUT 409 或完成响应丢失：仅当内存中仍有申请 `url` 且网络可用时，匿名 HEAD 一次；返回 200、长度及 MIME 一致、素材到期头有效，才作为确认成功的结果交给统一流程入库。HEAD 不发送 API Key 或上传 token，不能仅凭 409 放行。此核对是适配器内一次请求处理，不增加数据库阶段或重启恢复机制。

申请响应没收到、网络仍不可用、HEAD 失败或信息不足，统一报告上传失败并设为 failed；结果不确定的原因保留在 errorCode 中，不代表远端一定没有收到文件。进程退出也按统一 interrupted 规则处理。用户重试重新执行上传，不复用失去回执的半成品对象，因此中断重试可能留下远端重复对象，这一代价在本方案中接受。上传凭证过期时明确报错，不增加单独的自动重新申请循环。

OSS 未配置时，本应用可按下列厂商能力上传图片、音频或视频。接口支持的类型为 `video/mp4`、`video/webm`、`video/quicktime`、`audio/mpeg`、`audio/wav`、`audio/ogg`、`audio/mp4`、`audio/flac`、`image/png`、`image/jpeg`、`image/webp`、`image/gif`。媒体真实格式与声明 MIME 必须一致，不自动转码。上传 headers、凭证、签名查询参数不写日志，也不跟随会泄露凭据的重定向。

## 秘塔上传合同

使用有效 Base URL `https://metaso.cn/api/minimax`，相对路径 `v1/files/upload`，复用该渠道 API Key 和代理设置。

- POST multipart，请求字段为 `purpose=video_generation_input` 和 `file`，保留文件名，按官方接入实现使用文件 part 的 `application/octet-stream`；本地素材 MIME 仍用于模型限制校验。
- 检查 HTTP 状态；`base_resp.status_code` 存在且非零时按业务失败处理。
- 优先读取非空 `file.file_id`，转换为不丢精度的字符串，返回上传文件引用。
- 缺少文件 ID 时，仅接受有效的 `file.download_url`，这是官方示例明确支持的另一种结果形态。两者都缺少时返回响应错误。
- 完成回执校验后，将文件 ID 或下载 URL 保存到当前上传记录并改为 active，供当前及后续任务复用。秘塔视频适配器负责编码成 `mm_file://…`，不能传给其他渠道或要求公开 URL 的认证接口。
- 公开示例没有提供可依赖的文件有效期，`expiresAt` 保留空值，含义是期限未知。相同渠道配置下复用 active 文件 ID；如上游明确返回文件失效或不存在，设为 failed 并记录 expired 错误，下一次用户重试重新上传。不能因期限未知而每次上传，也不能将普通网络或鉴权错误当作文件失效。

采用流式 multipart，不把大文件整体读入内存。已发送上传后丢失回执时设为 failed，并记录结果不确定的错误，不归为视频任务提交不确定；此接口没有已核实的按内容查找能力，用户明确重试可能再次上传，但只有结果落库成功后才提交生成。上传格式和大小先遵守当前模型限制，服务端额外限制以明确错误呈现，不猜测渠道未公布的上传上限。

## 火山 Files 与 Asset 的边界

方舟确有独立的 `POST /api/v3/files` 接口，使用 API Key，可不配置 TOS 而使用平台托管存储。它与需要 AK/SK 的现有火山 Asset 认证是两种能力。

公开视频生成契约没有列出直接使用 Files `file_id` 的方式。通过 Files 返回的 `download_url` 供 Seedance 拉取，是基于接口合同推导的候选路径，尚未做真实请求验证。保持火山 `uploadProtocol` 为空。图片／音频在没有 OSS 时使用 Base64 直接提交；火山未接入渠道上传时，本地视频经 OSS；其他已支持视频上传的渠道仍可走渠道上传。已有 Asset 认证引用继续独立使用。

本次不接入 `ark_files`，也不通过 Managed Agents 的文件用途绕过普通生成接口边界。未来若新增火山渠道上传，需分别验证图片、音频、视频上传结果可被目标模型消费，再按 OSS 优先、渠道上传次之的统一规则启用。

## 状态、复用和失败处理

参考准备沿用任务 `uploading` 阶段。文件探测、能力校验、所选上传或 Base64 编码准备和引用校验全部成功后，才允许进入生成 `submitting` 窗口。不能复用现有视频客户端“所有 POST 都可能是收费提交”的错误分类来发送普通上传。

渠道操作锁按 assetId／providerId／kind 隔离；只有渠道协议、端点、凭据摘要和 MIME 也一致时，才共享正在执行的请求，不一致的请求等待当前操作结束后重新检查。数据库按这三个身份字段查行，再校验配置摘要。OSS 的并发合并键使用规范化配置身份、文件哈希和 MIME，不记录明文凭据。两个任务共享上传时，一个任务取消不应中断另一个任务依赖的请求；服务销毁才统一终止自身持有的 transport。

OSS 沿用远端哈希检查。仅在输入已选中支持其媒体类型的渠道上传路径后，才查询持久化结果并合并进行中的相同上传；有效结果在同一路径下跨任务复用。Base64 每次从本地文件构造，不建立远端复用记录。上传结果过期时在提交前重新准备；失败、取消和结束后释放客户端，保留已保存的结果与失败记录，不清理用户本地素材或主动删除远端对象。

配置检查与实际发送之间使用同一份配置快照。上传完成后若发现渠道凭据或端点已更换，停止提交并提示重新准备，不能把旧账号的文件 ID 交给新账号。

| 失败阶段 | 行为 |
| --- | --- |
| 参数、文件、格式或大小校验失败 | 发送前拒绝，指出具体素材；不丢弃参考或改成文生视频 |
| 上传鉴权失败、限流、网络失败 | 停在生成提交前，保留本地输入，明确提示上传错误；无静默 OSS／渠道／Base64 切换 |
| 上传成功但结果缺字段、引用不受目标支持 | 拒绝生成提交，不使用占位 URL |
| 上传中退出、取消或进程崩溃 | upload 的 processing 行改为 failed／interrupted，用户重试重新上传；不保存半成品 URL、不产生认证通过记录 |
| 生成提交响应丢失 | 保留现有 submission_unknown／对账逻辑，不自动重新生成 |
| 已有远端生成任务 ID | 恢复查询和结果下载，不重新上传或重提生成 |
| 认证失败 | 保留现有失败记录和认证重试入口，普通上传成功不能覆盖认证失败 |

## UI、Agent 与平台

生成入口与历史重试按渠道、目标模型和输入执行本地预检；只有返回“需要对象存储”时打开现有配置弹窗。认证菜单使用相同预检机制，但要求公开 URL。无效 Key、服务不可用、格式不支持应走各自错误展示，不能全部导向 OSS 设置。

渠道设置仍由用户选择渠道类型、填写已有凭据。火山认证保留 AK/SK 和项目名区域；上传协议使用 API Key 时不要求额外填写认证凭据。不新增上传协议下拉框或“优先 OSS”开关，图片／音频固定为 OSS、渠道上传、Base64；视频固定为 OSS、渠道上传，不使用 Base64。认证引用仍按独立规则使用，渠道缓存只在选中渠道上传后检查。

Seedance 认证菜单只列有 `assetProtocol` 且认证凭据齐全的渠道。节点盾牌和状态必须显式过滤 `kind=certification`，仍只反映认证记录，普通上传不新增“认证中／已认证”标记。现有图片认证入口范围保持不变，不能因为上传支持视频和音频就顺带开放新认证 UI。

Agent 的 `assets certify`、`asset_certification`、`certifications` 保持现有契约；普通生成复用任务层选择规则，无需新增工具参数或动态修改 schema。Agent 错误保留阶段、错误码和脱敏诊断，UI 使用本地化可读消息。文案同步中文和英文资源。

参考文件仍从已有资产库的应用私有副本读取。Windows、macOS 共用桌面入口，Android 共用协议与文件处理层；不直接把 Android `content://` 交给 `File`，不修改平台权限或新增文件选择流程。

## 实施清单

本次沿用已有上传与认证记录，调整共享选路、输入能力校验和提交编码，不新增长期运行服务或数据库迁移。以下为实施位置与要求。按下面顺序完成一个可独立交付的功能变更，所有入口接通后再发布。

| 位置 | 改动 |
| --- | --- |
| `lib/shared/models/ai_provider.dart` | 登记两种独立协议及各渠道支持关系 |
| `lib/shared/models/video/request.dart`、`capabilities.dart` | 沿用字符串参考地址，补充图片／音频 Base64 能力及体积校验，按渠道能力允许视频上传，禁止视频 Base64 |
| `lib/shared/services/ai/uploads/` | 保留已有渠道适配器和回执处理，只在输入选中支持其媒体类型的渠道上传路径后调用 |
| `lib/shared/services/ai/video/reference_storage_service.dart` | 统一实施 OSS 未配置／配置无效／配置就绪三态预检，复用 ObjectStorageConfig.validate，供 UI、任务与 Agent 共用；先 OSS，再按媒体类型和渠道能力选路；缓存服从选路，统一 Base64 准备并隔离并发去重 |
| `lib/shared/services/object_storage/service.dart`、`lib/shared/models/object_storage_config.dart` | 加载接口保留设置存在性及解码失败，必要时补齐字段类型校验；不得将损坏或部分配置归为默认空配置，沿用已有字段校验规则 |
| `lib/shared/providers/video_tasks.dart` | 装配 OSS 与上传客户端，保持共享服务生命周期 |
| `lib/shared/services/ai/video/task_service.dart` | 固定配置快照，混合输入先整体预检，提交前校验全部 Base64 与 JSON 请求体大小，保留恢复边界 |
| `lib/shared/services/ai/video/` 中读取参考 URL 的客户端 | 显式处理允许的来源；秘塔编码文件 ID，其他客户端拒绝不支持的文件引用 |
| `lib/shared/services/ai/assets/client.dart`、`certification.dart` | Asset 协议工厂、认证就绪检查，以及公开 URL 前置要求 |
| `lib/shared/database/app_database.dart`、`app_database_migrations.dart`、`app_database_indexes.dart`、`daos/provider_asset_dao.dart`、`lib/shared/models/provider_asset.dart` | 沿用现有 kind、上传结果与缓存身份，不因本次选路新增 schema；历史记录保留 |
| `lib/desktop/features/production/storage_dialog.dart`、`composer.dart`、`history.dart`、`certification.dart`、`support.dart` | 只消费共享预检结果，配置保存后重新预检，不在 UI 内独立实现 OSS 三态；保留独立认证 UI |
| `lib/shared/services/ai/provider_resources.dart`、`tools_production.dart` | 核对既有认证契约与普通生成错误，不扩大工具操作范围 |
| `assets/translations/zh-CN/production.json`、`assets/translations/en/production.json`、`locale_keys.dart` | 上传阶段和配置错误的文案 |

沿用已有 `ProviderAssets` 和 `ProviderAssetKind`。认证查询与轮询继续限定用途，不能把普通上传的 active 状态误当作认证通过；Base64 路径不新增上传行。

## 验收与验证

新增测试使用固定文件、隔离数据库和模拟 HTTP；不调用真实上传或收费生成。重点覆盖业务行为：

| 场景 | 必须满足 |
| --- | --- |
| 无参考，OSS 未配置 | 正常进入生成，不创建上传请求 |
| 有当前渠道有效上传记录，同时已配置 OSS | 使用 OSS，不查询或消费渠道缓存；原记录保留 |
| 图片／音频／视频的 OSS 和渠道上传同时可用 | 使用 OSS；相同内容再次生成先 HEAD，存在时无 PUT |
| 图片／音频／视频无 OSS，当前渠道上传可用 | 完成上传并以正确引用提交，不弹 OSS 配置窗口 |
| 图片／音频无 OSS、无渠道上传，包括未登记 Base64 能力的模型 | 正确编码后生成，无独立上传请求和上传记录 |
| 供应商拒绝 Base64 请求 | 展示供应商错误，不自动切换路径或重新生成 |
| 本地视频无 OSS，渠道支持视频上传且已有有效记录 | 复用渠道记录，不重复上传 |
| 本地视频无 OSS，渠道不支持视频上传 | 要求配置 OSS，不使用视频 Base64 |
| 混合参考无 OSS，各输入都有渠道上传或允许的 Base64 路径 | 按各自路径完成准备，正常提交 |
| 混合参考中至少一个输入没有可用路径 | 在任何素材发送前阻止整次准备，保留所有输入 |
| Base64 原始文件或编码后的总请求体超过限制 | 提交前报错，提示使用 OSS，不截断或丢弃参考 |
| 渠道上传失败，输入为图片／音频 | 明确报错，不自动转 Base64 |
| Base64 请求失败或重启重试 | 本地输入保留，按最新配置重新选路；不持久化编码内容 |
| OSS 未配置、默认空配置、部分配置、损坏设置、有效配置 | 共享预检返回对应三态，UI、任务和 Agent 使用同一结果；只有独立认证 Asset 直接引用可跳过；渠道上传缓存不能绕过 OSS 检查 |
| OSS 配置就绪但请求失败 | 明确报错，不调用渠道上传或 Base64 兜底；本地就绪不冒充远端鉴权或网络验证通过 |
| 秘塔文件 ID、下载 URL、缺字段、业务错误 | 分别正确编码、采用、拒绝、报错；不转换成认证记录 |
| 88API 摘要、长度、MIME、两个期限 | 请求符合合同；不把申请成功当上传成功 |
| 88API 申请 POST 中断，未收到完整有效回执 | 没有可用 url，不发送 PUT 或 HEAD；报告申请失败，用户重试才重新申请 |
| 88API 申请响应包含不同的 url／upload_url | PUT 发向 upload_url；已取得申请回执但完全未收到 201 时，网络可用才 HEAD 申请 url，且不携带任何上传凭据 |
| 88API PUT 中断且网络持续不可用 | 设为 failed，保留结果不确定的错误；remoteUrl 仍为空，重试重新上传 |
| 88API 申请 url 缺失或无效 | PUT 前拒绝响应，不从 upload_url 推导读取地址 |
| 88API 409、PUT 中断或 201 响应体丢失，HEAD 核对通过 | 使用申请 url 与 HEAD 素材期限恢复成功，不再次 PUT、不重新申请对象 |
| 88API 当前调用内 HEAD 404／410、超时、其他状态或元数据缺失／不匹配 | 统一设为 failed 并记录具体错误，停止生成，不保存申请 URL；HEAD 200 本身不足以放行 |
| 普通上传和认证的状态顺序 | 两者请求前均已有 processing 行；上传成功原子保存结果并设为 active，认证提交后保存 ID 并继续 processing；失败均为 failed |
| 只收到 88API 申请响应即退出 | 数据库 remoteUrl 为空，重启标记 failed／interrupted，不发恢复 HEAD |
| 同一素材再次生成或重启后生成 | 重新选路后，仅渠道上传路径复用有效 active 记录；已配置 OSS 就切换 OSS，过期、配置变化或 assetId 改变时重新准备 |
| 同一素材同一渠道既上传又认证 | 两条不同 kind 的记录共存，重试互不覆盖，认证 UI 和 Agent 字段只读取 certification |
| 旧库升级与新装库 | 只新增 kind、contextHash、remoteUrl、expiresAt 四列；旧行均为 certification，旧远端 ID 和状态保留，列类型、索引与 Typed DAO 回读正确 |
| 并发、换 Key、换端点、取消 | 不串账号；共享请求不因单个任务取消而破坏其他任务 |
| 认证只有 API Key、缺 AK/SK | 火山认证不可用，不影响其原有视频生成配置 |
| 普通上传成功、认证失败、认证处理中 | 盾牌、菜单和 Agent certifications 只显示真实认证状态 |
| 重启发生在 uploading／submitting／已获任务 ID | active 上传结果复用，未完成上传标记 interrupted；生成提交不确定不重发；已有任务仅恢复查询与下载 |

实施时串行执行以下已有测试入口，新增上传适配器测试放在 `test/shared/services/ai/uploads/`，迁移和 DAO 沿用已有回归入口，不为本次选路新增迁移：

```bash
fvm flutter test test/shared/services/object_storage/
fvm flutter test test/shared/services/ai/uploads/
fvm flutter test test/shared/services/ai/video/
fvm flutter test test/shared/services/ai/assets/certification_test.dart
fvm flutter test test/shared/services/video_task_recovery_test.dart
fvm flutter test test/shared/models/video/
fvm flutter test test/shared/database/provider_asset_migration_test.dart
fvm flutter test test/shared/database/provider_asset_dao_test.dart
fvm flutter analyze lib/shared/database lib/shared/models/provider_asset.dart lib/shared/models/ai_provider.dart lib/shared/models/video lib/shared/services/ai/uploads lib/shared/services/ai/video lib/shared/services/ai/assets lib/shared/providers/video_tasks.dart lib/desktop/features/production
```

UI 行为新增有明确隔离依赖的定向 Widget 测试，运行时按仓库规则加超时。认证和上传恢复回归必须断言真实请求次数与 DB 状态，不只验证某个布尔值。按实际生成源改动执行 FVM codegen 并检查 diff。

真实验收需要对应渠道 API Key，OSS 路径需要用户的存储配置，火山认证需要 AK/SK 和项目权限。只有用户明确授权真实上传及收费生成后，才用指定样本验证各渠道的图片／音频上传或 Base64，以及经 OSS 或渠道上传准备的视频参考，并记录请求阶段和远端任务 ID。未执行的平台或渠道验收明确标为未验证，不能用 mock 通过代替。

回滚时在兼容现有 schema 的代码中恢复此前选路，已有渠道生成任务继续查询与下载，上传记录、认证记录、本地素材和结果文件保留。不降级数据库，也不直接运行不认识 kind 的旧二进制；旧代码会把上传行当成认证记录。远端对象按渠道自身期限处理，不新增删除请求。

## 依据与核对范围

- [88API 本地素材上传](https://88api.ai/zh/docs/api/video/video-api-standard/#36-本地素材上传先申请再-put)：凭证申请、PUT、哈希编码、201、409、HEAD 和有效期。
- [秘塔 H3 页面](https://metaso.cn/minimax-h3)：视频 API 示例与官方 ComfyUI 接入链接。
- [秘塔官方接入客户端](https://github.com/meta-sota/ComfyUI-MiniMaxH3-API/blob/0d1c72b1d80a54237b40adb111ae74d7fe38f4b4/api_client.py)：`v1/files/upload`、multipart、业务响应和 `mm_file://` 引用；部署行为仍需联调。
- [秘塔官方节点配置](https://github.com/meta-sota/ComfyUI-MiniMaxH3-API/blob/0d1c72b1d80a54237b40adb111ae74d7fe38f4b4/nodes.py)：默认渠道 Base URL。
- [火山 Files API](https://docs.volcengine.com/docs/ark/file-api?lang=zh)、[上传文件](https://docs.volcengine.com/docs/ark/upload-files-api?lang=zh)、[视频生成输入](https://docs.volcengine.com/docs/ark/create-video-generation-task-api?lang=zh)：上传与视频输入属于不同接口合同，Files 到 Seedance 的候选路径尚未实测。
- [New API 路由](https://github.com/QuantumNous/new-api/blob/main/router/relay-router.go)：核对时 `/v1/files` 仍映射到未实现处理器；源码核对基线 `e449cc7` 中没有 `/v1/media/uploads` 或 `X-Media-Upload-Token` 实现。不能从 New API 兼容性推断 88API 上传能力。

以上命令列出验收入口，实际执行与通过记录以总览 E1-04 为准；未执行真实上传或收费生成。
