# Provider 扩展

> 本篇同步 Provider 的已实现合同与后续设计。公共注册、实例与模型、图片和视频接口已进入 SDK；聊天及 OAuth 仍为后续设计。实施与验收状态只在 [实施任务](README.md#实施任务) 的 T-31a 至 T-34 维护，已交付接口以 `plugins/sdk/index.d.ts` 为准。

## 目标与范围

第三方插件可以提供供应商定义、实例配置、模型发现，以及聊天、图片和视频能力。聊天进入现有 Agent 循环（首版不实施）；图片复用现有图片生成和结果采用流程。用户安装插件、创建供应商实例并填写凭据后，在现有图片、视频模型选择器中选择模型，生成结果进入现有素材库，继续用于分段表、质检和剪辑。同一段换供应商重跑时创建新的生成任务，保留原任务归属。

首版支持 Windows、macOS、Android，共用 HTTP 和宿主文件传输能力。首版交付公共注册、实例与模型发现（T-31a），视频业务接口（T-31b）和图片业务接口（T-34）。聊天能力首版不实施，标准协议聊天（T-32）和自定义聊天（T-33，平台响应协议不兼容标准协议、由插件解析流的聊天）保留设计。音频 Provider 方法、OAuth 登录与自动刷新、账号轮换、本地 CLI 执行、价格表和余额管理不在本轮范围；OAuth 方向见 [OAuth 登录](#oauth-登录后续迭代)。具体平台适配由独立插件承载，宿主不新增平台专属枚举或端点。

成功标准：图片、视频能力均无需修改平台枚举即可配置和选模型；图片同步结果和异步任务、视频任务都能进入现有结果流程。存在远端任务 ID 或已保存结果时可恢复查询或登记，提交结果不明时不会自动再次收费提交。

## 接口分工

图片和视频通过 `submit`、`query` 等业务方法接收参数并返回统一结果。插件声明模型能力与默认值，负责把业务输入映射为平台请求并解析响应；Host 按声明展示参数、校验输入，管理任务持久化、恢复和素材登记。ComfyUI 等工作流的节点映射由插件作者定义，Host 不识别 App Mode、不猜测节点含义，也不内置工作流映射编辑器。

聊天优先声明标准协议并复用宿主 client，插件只调整请求；平台响应协议不兼容时使用 `chat.generate` 返回统一事件。聊天整体首版不实施。各能力共用供应商实例、配置、凭据与模型发现，插件运行在现有 QuickJS 中，通过阶段上下文访问 Host API。

## 身份、配置与注册

```text
pluginId：安装包身份，同时是供应商定义身份
  └─ providerId：用户创建的供应商实例
       └─ modelId：该实例上的模型
```

一个插件最多提供一个供应商定义，以 `pluginId` 唯一定位，不另设定义 ID；需要接入多个平台时拆成多个插件。一个定义可创建多个实例，实例沿用现有 `AiProvider.id`，各自拥有凭据、接口根、项目参数、代理及启停设置。首版一个实例表示一个连接，不另建账号池。模型 ID 只在实例内解释，不能用模型名推断能力。

清单新增可选的 `provider` 对象，包含 `name: PluginText` 和可选 `settings.fields`。字段类型、默认值、必填与 secret 校验复用现有配置字段模型；这里的字段属于供应商实例，顶层 `settings.fields` 仍属于插件本身。供应商接口根和项目 ID 是否可配置由插件决定，不要求每个平台都有固定 base URL。

`apply` 中使用 `setup.provider.register(handlers)` 绑定方法。清单声明了 `provider` 时必须且只能注册一次，未声明时不得注册；缺失、未声明、重复或结构不合法的注册使整个激活失败。Host 不认识的能力分组和方法忽略并记录日志，不因此拒绝激活；已知能力仍校验必需方法及方法配对。同一插件可同时注册 Tool、View 和 Provider。注册只描述能力，不发请求或读取凭据。

定义必须提供 `listModels`，可选 `checkConnection`，并至少注册一项业务能力，首版只计 `video`、`image`；不再要求所有定义都实现视频方法。方法集合按能力校验：

- 素材（实例级，可选）：`uploadReference` 对应内置平台上传；`assets.submit` 与 `assets.state` 对应内置素材认证，必须同时注册。见[参考素材上传与认证](#参考素材上传与认证)。
- `video`：必须有 `submit/query`。
- `chat`（首版不实施，Host 忽略注册的 chat 方法，不因此拒绝激活）：标准协议模型需要 `prepareRequest`；自定义模型需要 `generate`。同一模型只选择一种模式。
- `image`：必须有 `submit`；平台有异步任务时注册 `query`。

模型声明的调用模式缺少对应方法时，调用该模型才报明确错误，刷新模型列表不做此项检查。每次执行仍核对激活快照中的 Provider 方法集合；`listModels` 的动态结果不属于注册快照。Provider 不支持覆盖其他插件或内置供应商的身份。

实例配置在现有供应商设置入口创建和编辑；插件详情显示其是否提供供应商及可用状态。安装、启用插件不会自动创建实例。插件可用与实例配置完整分别判断，一个实例缺少凭据不影响同插件其他实例。配置保存只做本地校验，不发生成请求；连接检查由用户主动触发。

## 调用形式与上下文

有业务参数的方法使用 `handler(input, context)`；无业务参数的 `checkConnection`、`listModels` 只收 `handler(context)`，与现有 Task、Prompt 一致。以后需要参数时放进 context，不在前面插入 input。业务输入、事件、最终返回值及持久化数据必须是严格 JSON；HTTP 异步字节流由 SDK 包装 Host 通道，不作为业务返回值或持久化数据；运行时身份由 Host 绑定，不接受插件在输入中自报身份。下面是已实现的方法合同：

| 方法 | input | 返回值 |
| --- | --- | --- |
| `checkConnection`，可选 | 无，只收 context | `{ accountLabel?: string }`；失败抛错误，不用生成视频验证连接 |
| `listModels` | 无，只收 context | `ProviderModel[]` |
| `uploadReference`，可选 | `{ file: FileInfo }` | `{ ref: string; expiresAt?: string }` |
| `assets.submit`，可选 | `{ file: FileInfo; name: string }` | `{ remoteId: string; remoteTaskId?: string; remoteGroupId?: string }` |
| `assets.state`，可选 | `{ id: string }` | `{ status: "processing" \| "active" \| "failed"; errorCode?: string; errorMessage?: string }` |
| `video.submit` | `SubmitVideoInput` | `SubmitResult`，视频只返回 submitted |
| `video.query` | `QueryInput` | `QueryResult` |

`SubmitResult`、`QueryInput`、`QueryResult` 由图片和视频共用，见[提交、查询与任务状态](#提交查询与任务状态)。聊天方法的输入输出见[聊天能力](#聊天能力)，图片方法见[图片能力](#图片能力)。

### ProviderContext

| 成员 | 含义与约束 |
| --- | --- |
| `plugin` | 当前插件身份及版本 |
| `provider` | 只读的 `id`；由 Host 绑定 |
| `callId` | 本次调用身份，用于取消、日志和迟到结果识别 |
| `settings.get(key)` | 当前实例已声明的普通配置，应用默认值；不读取顶层插件配置 |
| `secrets.get(key)` | 当前实例已声明的凭据，不接受其他实例 ID |
| `http.fetch(url, init)` | 普通 HTTP 请求；允许 POST 查询、自定义 headers/body，非 2xx 由插件解析 |
| `storage` | 插件自己的 `data.*` 命名空间，与其他阶段共用同一份 KV 及大小上限；读不到 `settings.*` 和 `provider.*`。任务恢复所需数据通过返回值中的 `state` 交给 Host 保存，不写 `storage` |
| `log` | 沿用插件日志 |

图片和视频方法额外收到只读 `taskId`，表示宿主任务身份。`uploadReference` 与 `assets.submit` 开放 `files.upload`；视频提交/查询开放 `video.request`，图片提交/查询开放 `image.request`，具体授权见各能力章节。其他阶段不开放本地文件。ProviderContext 不继承完整 `PluginServices`，首版没有章节、人物、UI、递归 AI 或私有 SQL 能力。任务状态、远端任务 ID、任务 `state` 和任务内上传缓存由 Host 管理，插件不为恢复任务写 `storage`。

普通调用读取已保存的实例配置快照；用户主动检查连接时可绑定当前表单草稿，不能用草稿启动生成任务。HTTP 和文件传输使用该供应商实例的代理设置，区别于现有普通插件 HTTP 的直连行为。凭据不自动加到任意 URL，插件按平台要求构造请求头；跨源重定向不得转发 Authorization、Cookie 等敏感头。

Provider 查询类方法（`checkConnection`、`listModels`、`assets.state`、`image.query`、`video.query`）复用专用的常驻 `PluginBusinessRuntime`，同插件不同实例共享模块内存，配置和凭据仍按调用绑定。提交与上传（`image.submit`、`video.submit`、`uploadReference`、`assets.submit`）每次使用独立运行时，结束后释放，避免其他查询重置运行时而中断收费提交。查询的共享引擎重置可能中断其他在途查询，后续调用会重建；恢复所需状态仍必须通过 `state` 持久化，不能依赖 JS 内存。

Host 按插件分别限制普通业务调用、Provider 查询、Provider 提交与上传，当前并发上限依次为 4、8、4，共用同一插件的多个实例共同计数。三组队列互不占用名额，四个长时间提交不会阻塞查询或普通插件操作。查询运行时与普通业务运行时分开；文件流由 Host 传输。上述并发值尚未经过三平台性能基准验证。

### 超时预算

以下为首版固定的 Host 总等待上限，从 Host 派发方法、开始创建运行时起计时，包含激活、桥接排队、网络、文件传输和结果序列化。任务等待宿主调度的时间不占方法预算。插件不能延长总预算，多次 HTTP 请求也不重新计时。

| 方法或阶段 | 总等待上限 | 超时后的处理 |
| --- | --- | --- |
| checkConnection | 30 秒 | 显示连接检查超时，不改变实例启停状态 |
| listModels | 60 秒 | 本次刷新失败，保留旧模型列表及能力声明 |
| uploadReference、assets.submit | 每个素材 10 分钟 | 上传或认证提交失败；上传失败不进入生成提交；包括取票据、传文件和完成确认 |
| assets.state | 每次 30 秒 | 记录保持 processing，按认证轮询间隔再查 |
| video.submit | 60 秒 | 未获得有效远端任务 ID 时进入提交不确定状态，不自动重提 |
| image.submit | 5 分钟 | 允许同步生图等待；无已确认结果或有效远端任务 ID 时进入提交不确定状态，不自动重提 |
| image.query、video.query | 每次 30 秒 | 保留远端任务 ID，不判为远端生成失败；视频按任务查询策略退避，图片按[图片异步任务](#图片异步任务)处理 |
| 图片运行内异步等待 | 10 分钟，从 submit 返回 submitted 起 | 转 action_required，等待用户重新获取 |
| Host 图片下载 | 每次 5 分钟 | 保留远端 URL，只恢复下载或登记 |
| Host 视频下载 | 每次 10 分钟 | 保持 saving，下次刷新重新 query 取得下载地址 |

普通 `http.fetch` 保持当前默认 20000 毫秒，`timeoutMs` 可填 1 至 60000 的整数。`image.request` 的 `timeoutMs` 默认 300000 毫秒，可填 1 至 300000 的整数；`video.request` 默认与上限均为 60000 毫秒；`files.upload` 新增可选 `timeoutMs`，默认 600000 毫秒，可填 1 至 600000 的整数。越界值在发请求前报 invalid_request。实际请求期限取请求超时和所属方法剩余预算的较小值；例如 image.query 中的 image.request 最多使用该次查询剩余的 30 秒。连接建立最多等待 30 秒，同样受剩余预算约束。Host 下载在插件方法返回后独立计时，预算覆盖响应体完整接收，传输有进度也不重置总期限。

Provider 派发必须把表中预算传到运行时及媒体桥接，不能先被普通工具调用的 60 秒上限截断；同步图片请求使用 image.request，不通过普通 http.fetch 延长等待。激活仍受现有 5 秒上限约束，并计入方法总预算。到期立即撤销本次调用的 Host API 权限并取消其网络和文件操作，沿用运行时收尾机制；共享查询引擎若被重置，其他在途查询也会失败，但不影响独立的提交与上传运行时。超时前已取得并校验的远端任务 ID 或已确认结果必须保存；未知提交不因超时重发。

异步任务的远端排队、执行时间不属于某一次 submit 或 query 的预算。每次 query 只检查一次，沿用 Host 的查询调度和退避；不能把 30 秒查询超时理解成整个生成任务只能运行 30 秒。聊天方法暂缓，不套用本表定义其最终合同。

## 模型发现与校验

`ProviderModel` 包含 `kind`（`chat`、`image`、`video`；首版 Host 只采用 `image`、`video`，`chat` 条目忽略）、`id`、可选 `name: PluginText`、必填 `capabilities` 和可选 `requestDefaults`。能力和默认值按 kind 使用对应的 JSON 结构，不能跨类型混用。聊天模型另含 `chat` 绑定，图片模型另含 `image` 执行方式，见下文。同一实例内以 `(kind, id)` 定位，允许同一个平台型号用于不同能力；跨实例查找必须带上 `providerId`。

插件返回的声明是该实例模型能力与默认值的唯一来源，不提供 `catalogId`，也不按模型 ID 或别名查询宿主 catalog。插件可以声明任意工作流 ID，无需宿主登记型号。同名插件模型和内置模型互不覆盖；内置供应商继续使用现有 catalog。插件可返回固定定义，也可从上游读取后转换成统一声明。

### 能力声明

插件声明与宿主 Dart 能力模型是同一套结构：capabilities 就是 [ImageModelCapabilities](../../../lib/shared/models/image/config.dart) 或 [VideoModelCapabilities](../../../lib/shared/models/video/config.dart) 的 JSON 编码，requestDefaults 就是同文件 ImageRequestDefaults 或 VideoRequestDefaults 的 JSON 编码，不另设插件专用字段。SDK 按 Dart 类生成对应 JSON 类型；Set 编码为数组，枚举编码为字符串，Map 编码为对象，`ConfigValue` 编码为其内部值或 null，不暴露 Dart 包装类型。内置 catalog 与渠道条目使用同样的字段，只是来源不同。

| kind | capabilities | requestDefaults |
| --- | --- | --- |
| image | ImageModelCapabilities：比例、分辨率、尺寸映射、参考图数量、像素与宽高比限制、复杂度与质量选项、参考图传输方式 | ImageRequestDefaults |
| video | VideoModelCapabilities：比例、分辨率、时长及按分辨率的时长上限、生成模式、首尾帧角色、帧模式比例要求及素材限制，见[视频能力模型调整](#视频能力模型调整) | VideoRequestDefaults；audio、promptExtend 为 null 或缺省表示不开放该选项 |
| chat（暂缓） | 由插件声明上下文与输出 token 上限、图片输入、工具调用及推理选项；随 T-32、T-33 定义 SDK 字段，不依赖宿主型号识别 | 随聊天接口实施，首版忽略 chat 条目 |

图片必须声明非空 `ratios`、`resolutions`，以及 `minReferences`、`maxReferences`、`unlimitedReferences`、`referenceTransport`。视频必须声明非空 `ratios`、`resolutions`、`durations`、`modes`，并显式声明 `frameRoles`、`maxMiddleFrames`、`maxReferences`、`references`、`supportsAudioOnlyReference`、`supportsAdaptiveTextRatio`、`supportsLastFrameOnly`、`framesRequireAdaptiveRatio`、`supportsCertifiedAssets`，以及可为 null 的 `draft`；`maxDurationByResolution` 可选，缺省表示各分辨率共用 `durations`。不接受的参考类型不放入 `references`，不接受首尾帧时 `frameRoles` 为空。可选媒体限制缺省或 null 表示不增加该项模型限制，宿主自身的文件传输和资源上限仍然生效。插件声明不与 catalog 合并，Dart 类 getter 的缺省回退不适用于插件模型，必填项必须显式给出。

`name: PluginText` 按当前界面语言解析，切换语言后模型选项名称重新计算；缺少对应语言时沿用 `PluginText.resolve` 的回退规则，不直接退回模型 ID。

图片可选声明 `qualityLevels: string[]`。非空时作为质量选项，`requestDefaults.quality` 必须在其中，显式请求的 quality 也按该集合校验；未声明或为空时，插件模型只提供默认 quality（若有），不借用内置协议的档位。内置渠道优先使用声明的 qualityLevels，未声明者仍沿用原协议选项。

`requestDefaults` 缺省按空对象处理，不补 catalog 默认值。Host 只解释自身识别的字段（图片的 size、quality、complexity，视频的 audio、promptExtend）用于界面初值和校验；整个对象（含未识别字段）冻结进任务快照，提交时原样作为 `request.defaults` 交给插件，用于 watermark、输出格式或工作流固定参数等平台专属值。用户可编辑的参数以 request 中的同名字段为准。

### 视频能力模型调整

当前内置视频把以下约束放在能力对象之外：`VideoProtocolOptions.requiredMode` 与 `VideoModelCapabilities.allowsReferenceMode` 表示可用模式，`VideoChannelModel.maxDurationByResolution` 表示按分辨率的时长上限，`VideoProtocolOptions.framesRequireAdaptiveRatio` 表示帧模式只接受 adaptive 比例，`supportsProviderAssets` 表示生成请求可引用已认证素材，`supportsDraft` 与 [draft.dart](../../../lib/shared/services/ai/video/draft.dart) 中的常量表示样片能力。为使插件与 Dart 同构，T-31a 先调整 Dart 模型：

| 原字段 | 调整后 | 内置条目迁移 |
| --- | --- | --- |
| `requiredMode`、`allowsReferenceMode` | `VideoModelCapabilities.modes`：有序的 `VideoMode` 列表，override 层整体替换 | `requiredMode: X` 改为 `modes: [X]`；`allowsReferenceMode: false` 改为不含 reference 的列表；均未设置时为全部四种 |
| `VideoChannelModel.maxDurationByResolution` | `VideoModelCapabilities.maxDurationByResolution`，override 层整体替换 | 原值移入渠道的能力覆盖 |
| `VideoProtocolOptions.framesRequireAdaptiveRatio` | `VideoModelCapabilities.framesRequireAdaptiveRatio` | 原值移入渠道的能力覆盖；AtlasCloud 路由参数仍留在协议选项 |
| `VideoProtocolOptions.supportsProviderAssets` | `VideoModelCapabilities.supportsCertifiedAssets` | 原值移入渠道的能力覆盖 |
| `VideoProtocolOptions.supportsDraft`，常量 `videoDraftResolution`、`videoDraftFinalResolution` 与 7 天期限 | `VideoModelCapabilities.draft: { resolution, completionResolution, ttlHours } \| null`，null 表示不支持样片 | Seedance 条目写入 `{ "480p", "1080p", 168 }`，`supportsDraftCompletion`、`isDraftExpired` 改读能力快照 |

`VideoProtocolOptions` 只保留请求编码相关的协议差异（omni 参考任务类型、AtlasCloud 路由等），不再承载校验规则和 Host 行为开关。`capabilities.dart`、桌面 composer、`provider_resources.dart` 与 `wan.dart` 改为读取能力对象；Agent 可见的模型资源输出保持原字段语义。能力字段迁移只改内置常量与读取位置，不回填已有任务的能力快照；新建任务的回归以现有视频能力与渠道测试覆盖迁移前后结果一致。旧样片不提供生成成片兼容，处理见下文样片规则。

Host 将声明转换为统一能力对象，模型选择器、参数表单和提交前校验使用同一份数据。比例、分辨率和尺寸不得再被内置 catalog 的固定选项截断；角色和生成模式仍限定为宿主已支持的业务语义。只有一个可选值时显示固定值，没有开放的素材角色或参数不显示可编辑入口；选项初值与内置模型同一规则：用户可选参数（比例、分辨率、复杂度等）当前值合法则保留，否则复杂度等在 requestDefaults 有合法值时用该值，没有时比例、分辨率取声明中的首个合法选项、复杂度留空不传；quality 按 qualityLevels 提供选项；未开放选项的 quality 和 size 在发送时以 requestDefaults 补齐。已提交任务按冻结快照执行，不随声明变化替换。工作流固定参数应声明实际支持值，插件不能把界面允许修改的参数静默丢弃。

Host 校验字段类型、必填项、重复选项、有限数值、正数时长和尺寸、非负数量、上下限关系、默认值是否合法，以及尺寸映射、素材角色和媒体限制是否一致。声明无效时整次刷新失败并指出模型与字段，不能退回 catalog 或按未知型号放行。平台提交仍可返回远端限制错误，能力声明不代表远端一定接受。

### 视频生成模式

`capabilities.modes` 是有序、非空、无重复的数组，只接受 `text`、`first_frame`、`first_last_frame`、`reference`。Host 按声明顺序显示模式，上传素材前检查 `request.mode` 属于该数组，再按所选模式检查角色和数量；`frameRoles` 只描述可接收的帧角色，不能据此推断某种生成模式可用。

| mode | 输入规则 |
| --- | --- |
| text | 不接受参考素材 |
| first_frame | 恰好一张 first_frame 图片 |
| first_last_frame | 默认恰好一张 first_frame 和一张 last_frame；中间帧及仅尾帧的可选行为沿用现有 VideoCapabilities 规则，分别由 maxMiddleFrames 和 supportsLastFrameOnly 显式开放 |
| reference | 至少一个 reference_image、reference_video 或 reference_audio；不得混入帧角色，按 references 中的媒体限制和 supportsAudioOnlyReference 校验 |

刷新时检查模式、角色和数量是否能组成合法输入：first_frame 需要开放 first_frame 角色及至少一张图片；first_last_frame 默认需要开放首尾帧及至少两张图片，启用中间帧或仅尾帧时也必须有对应角色和数量容量；reference 需要至少一种可接收的参考媒体。只有 text 时要求 frameRoles 为空、maxMiddleFrames 和 maxReferences 为零、references 为空，supportsAudioOnlyReference、supportsLastFrameOnly 和 framesRequireAdaptiveRatio 均为 false。maxDurationByResolution 的键必须属于 resolutions，值须使该分辨率至少保留一个 durations 中的时长；framesRequireAdaptiveRatio 为 true 且声明了帧模式时，ratios 必须包含 adaptive。空模式、未知模式、重复模式或相互矛盾的声明使整次刷新失败。

内置与插件模型使用同一个校验入口，按能力对象中的 modes、maxDurationByResolution、framesRequireAdaptiveRatio 校验，不区分来源；插件模型直接传入冻结的能力对象，不伪造 catalog 或渠道条目。

例如只支持首尾帧的 ComfyUI 工作流声明 `modes: ["first_last_frame"]`、`frameRoles: ["first_frame", "last_frame"]`、`maxReferences: 2`、`maxMiddleFrames: 0`、`supportsLastFrameOnly: false`，并在 references.image 中声明 maxCount 为 2。界面只显示首尾帧模式；缺任意一帧、改成 text 或 reference 都在上传和提交前被拒，节点 ID 与字段映射由插件内部处理。

### 刷新与持久化

模型 ID 按 kind 写入实例现有的 `models`、`imageModels`、`videoModels` 列；完整声明由 Host 写入 `plugin_storage` 的保留 key `provider.<providerId>.__models`，内容为 `{ version: 1, models: ProviderModel[] }`。`__` 开头的字段名保留给 Host（当前有 `__models` 与 OAuth 的 `__oauth`），清单中的实例字段名以 `__` 开头时激活失败；插件的 settings、secrets 和 storage API 均不能读写 Host 保留项。该记录与 ID 列在同一事务中更新；备份包含声明，删除实例时按既有实例前缀范围一并清理模型缓存，不扩大到任务或历史结果，不新增表或列。

`listModels` 只在以下时机调用，不在启动时联网，也不定期刷新：

| 时机 | 行为 |
| --- | --- |
| 用户在实例设置中点“获取模型” | 沿用现有获取模型对话框，按 kind 列出 listModels 结果供用户勾选；保存时写入勾选的 ID 及其声明，已添加模型的声明同步更新 |
| 插件更新到新版本并激活成功 | 后台刷新该插件各实例已添加模型的声明，不改变用户勾选的 ID；新版本不再返回的已添加模型按下架处理 |

新建实例在用户获取并勾选模型前没有可用模型。Host 校验重复的 `(kind, id)`。刷新失败保留原列表及声明并显示失败原因。同一实例并发刷新只采用最后一次发起的结果；实例配置变更使旧配置下的刷新结果失效。

启动时 Host 从各实例的 `__models` 加载声明到内存注册表，以 `(providerId, kind, modelId)` 为键，刷新成功后同步更新；与现有 PureFox 动态型号同样走内存登记，但声明已持久化，冷启动不需要联网。现有按 `(providerType, modelId)` 同步查找能力的入口改为接收 `AiProvider`：插件实例查注册表，内置供应商继续查 catalog 与渠道表；模型选择器、参数校验、生成链路和 Agent 可见的模型资源（`provider_resources.dart`）都经同一解析入口，插件模型对 Agent 与内置模型同样可见。声明缺失、损坏或版本不支持时，显示需要重新获取模型，不能根据残留 ID 猜能力。

新任务将实际采用的能力、默认值与最终请求一起冻结到现有任务 `requestJson`，实施时扩展其序列化结构，不新增列。刷新或更新插件不改写已有任务快照；模型下架保留用户原选择及历史任务身份，阻止新提交，但不阻止已提交任务继续查询和下载。恢复查询所需的工作流输出标识等信息放在任务 state 中，见[提交、查询与任务状态](#提交查询与任务状态)。

`capabilities` 中 Host 未识别的字段忽略并记日志，不拒绝刷新：新插件在旧宿主上只是本地校验较宽，多出的限制由远端报错，与“能力声明不代表远端一定接受”一致。`requestDefaults` 的未识别字段按上文原样透传给插件。已识别字段中的未知枚举值（模式、素材角色、媒体类型等）仍使整次刷新失败，不能忽略后改变业务语义。不以退回 catalog 作为兼容方式。此接口尚未交付，无需兼容此前文档中的 catalogId 草案。

## 参考素材上传与认证

内置供应商有两种平台侧素材流程，插件以同样的合同接入，结果写入同一张 `provider_assets` 表：

| 流程 | 内置实现 | 插件方法 | 记录 |
| --- | --- | --- | --- |
| 平台上传 | `UploadProtocol`（atlascloud_media、purefox_uploads、api88_media）经 `ReferenceUploader` 返回 `{ url, expiresAt }` | `uploadReference` | `provider_assets`，kind = upload |
| 素材认证 | `ProviderAssetClient.submit/state`（火山、AtlasCloud），生成请求以 `asset://` 引用 | `assets.submit`、`assets.state` | `provider_assets`，kind = certification |

内置 client 与插件 client 实现同一组接口，[参考存储服务](../../../lib/shared/services/ai/video/reference_storage_service.dart)与[认证服务](../../../lib/shared/services/ai/assets/certification.dart)不区分来源。平台上传用于视频和图片；素材认证当前只用于视频。

```ts
type ReferenceRole = "first_frame" | "last_frame" | "middle_frame"
  | "reference_image" | "reference_video" | "reference_audio";

interface FileInfo {
  handle: string;
  name: string;
  mimeType: string;
  size: number;
  sha256: string;
}
```

`JsonObject` 沿用 SDK。时间均为 UTC ISO 8601 字符串。文件大小单位是字节，摘要由 Host 计算；Host 在上传前探测媒体并按模型能力校验，不能以插件接受上传替代业务校验。handle 只允许当前插件在本次调用中访问指定文件，过期、跨任务或跨实例使用均拒绝。

### 平台上传

`uploadReference({ file })` 返回 `{ ref, expiresAt? }`，与内置 `ReferenceUploader({ file, sha256, mimeType, fileSize })` 的输入输出一致，不按模型或角色区分。`ref` 是平台给出的素材引用（URL 或 token），由插件解释，不含账号凭据；Host 存入 `provider_assets.remoteUrl`。

- 缓存与内置相同：按 `(assetId, providerId, kind = upload)` 跨任务复用，`expiresAt` 到期失效。`contextHash` 对内置为上传协议、接口根、API Key 摘要和 MIME；对插件为插件 ID、插件版本、实例配置与凭据摘要和 MIME，任一变化即失效。
- 中断沿用内置规则：启动时 processing 的上传记录转 failed，下次重新上传。
- 上传不自动重试，插件可以按平台幂等约定在单次调用内处理，不能通过此方法发起生成。

`context.files.upload(handle, request)` 的 request 为以下两种之一，两种均可携带 `timeoutMs`，默认值、范围和总预算见[超时预算](#超时预算)：

- `kind: "raw"`：`url`、`method: "PUT" | "POST"`、可选 `headers`，以原始文件流作为请求体。
- `kind: "multipart"`：`url`、可选 `headers`、`fields: Record<string, string>`、`fileField`，使用 POST，Host 编码 multipart boundary 并附加该文件。

返回值沿用 `HttpResponse`，响应体按普通 HTTP 大小限制读取；非 2xx 正常返回，网络失败或超时抛错。只接受 HTTP(S) 目标，不开放本地路径、任意文件读取或目标文件写入；请求未完成时 Host 必须持有并最终关闭文件资源。以票据式上传为例：插件通过 `http.fetch` 申请票据，通过 `files.upload` 传文件，再通过 `http.fetch` 完成确认，返回 `{ ref: "..." }`。

### 素材认证

`assets.submit({ file, name })` 返回 `{ remoteId, remoteTaskId?, remoteGroupId? }`，`assets.state({ id })` 返回 `{ status, errorCode?, errorMessage? }`，与内置 `ProviderAssetClient` 的提交与查询结构一致；`id` 取 `remoteTaskId ?? remoteId`。

- 输入统一为文件：内置 client 改为在适配层内先经参考存储取得公网 URL 再提交，插件可用 `files.upload` 自行上传。
- Host 沿用认证服务的本地校验（图片类型、30 MB 上限）、后台轮询间隔与启动恢复，记录写 `provider_assets`（kind = certification）。
- 实例是否支持认证由是否注册 `assets` 决定，替代按供应商类型判断；认证入口沿用桌面制片认证界面与 Agent 认证工具。
- 生成时，模型能力 `supportsCertifiedAssets` 为 true 且素材已在该实例认证为 active，就以 `certified` 引用代替上传。

### 视频参考准备顺序

内置与插件视频任务使用同一顺序，逐个素材选择：

1. 模型 `supportsCertifiedAssets` 且素材已认证：`{ kind: "certified", remoteId }`，内置 client 编码为 `asset://<remoteId>`。
2. 实例提供平台上传：`{ kind: "uploaded", ref, expiresAt? }`，优先于用户配置的对象存储。
3. 实例未提供平台上传且用户配置了对象存储：`{ kind: "url", url, expiresAt? }`。
4. 否则图片与音频可内联：`{ kind: "file", handle }`，整组按 base64 估算不超过现有 `videoInlineRequestMaxBytes`（64 MB）；内置 client 编码为 data URI，插件经 `video.request` 绑定文件。视频素材不能内联，此时报需要配置存储。

已选定的方式执行失败时明确报错，不静默切换其他方式。用户上传确认沿用现有流程。

## 提交、查询与任务状态

图片和视频共用以下结果类型：

```ts
interface QueryInput {
  remoteTaskId: string;
  state?: JsonObject; // 上次 submit/query 返回、由 Host 保存的值
}

type SubmitResult =
  | { status: "submitted"; remoteTaskId: string; state?: JsonObject }
  | { status: "succeeded"; outputs: Output[] };

type QueryResult =
  | { status: "queued" | "running"; state?: JsonObject }
  | { status: "succeeded"; outputs: Output[] }
  | { status: "failed"; error: ProviderFailure }
  | { status: "cancelled" | "expired" }
  | { status: "unknown"; reason: string };

type Output =
  | { kind: "url"; url: string; headers?: Record<string, string> }
  | { kind: "file"; handle: string; mimeType: string; byteLength: number };

interface ProviderFailure {
  code: string;
  message: string;
  detail?: string;
}
```

- `QueryResult` 的状态与现有 [VideoRemoteStatus](../../../lib/shared/models/video/task_result.dart) 一一对应。submit 没有失败分支，平台明确拒绝且证明未受理时抛 `rejected`。
- `remoteTaskId` 存入现有 `generation_tasks.providerTaskId`，之后每次 query 原样传回。
- `state` 保存查询所需的平台数据，例如远端项目 ID、提交区域、工作流输出节点；必须是严格 JSON，单个不超过 64 KB，不得包含凭据，查询需要凭据时从 `secrets` 读取当前实例的值。Host 在保存远端任务 ID 的同一事务中把它写入 `generation_tasks.provider_state`，之后每次 query 原样传回；query 返回新值时整体替换，不返回时保持不变。`state` 是任务记录的一部分，随任务保留和软删除，不进入插件 `storage`。
- `outputs`：视频成功时恰好 1 个 url 型输出；图片至少 1 个，可混合 url 与 file，多张候选对应现有 `imageOutputs`。url 只接受 HTTP(S)；headers 仅在本次调用结果和下载过程中保留于内存，不写入任务数据库、图片暂存回执或备份，只发送到该 URL 的首次请求，任何重定向均不再携带这些 headers。file 的 handle 只能来自本次调用中 `image.request` 生成的文件，插件不能伪造。
- 不设单独的下载解析方法。下载地址失效时，有远端任务 ID 的任务重新 query 取得新地址，不调用 submit。

下载引用由 Host 管理，与任务绑定，不能把 headers 塞进插件 state 或默认附加实例凭据。视频只持久化 outputUrl，图片只持久化候选 URL 或本地文件、素材信息；不保存 output_headers，也不在 ImageTaskOutput 中保存 headers。下载使用本次 submit/query 返回的 headers，新输出未带 headers 时按空头处理，不沿用旧值。日志、Agent 工具结果和普通任务展示不得包含下载头的值。视频重试重新 query 获取 URL 与 headers；图片恢复先尝试已有文件或 URL，失败且有远端 ID 时重新 query，没有远端 ID 时明确提示无法刷新，不自动重新生成。同步图片没有远端 ID，进程退出会丢失尚未完成下载所需的内存鉴权头，这是本方案接受的恢复限制。

Host 按以下规则处理 submit 返回：

| 插件返回 | Host 处理 |
| --- | --- |
| submitted，`remoteTaskId` 非空 | 保存远端 ID 与 state，进入查询 |
| submitted，但该 kind 未注册 query | 合同错误：保留远端 ID，转人工核对，不再提交 |
| submitted，`remoteTaskId` 为空或不合法 | 提交不确定，不再提交 |
| succeeded，outputs 数量与类型合法 | 进入保存 |
| succeeded，outputs 为空、数量或类型不符 | 平台可能已受理，转人工核对，不再提交 |
| 抛 `rejected` | 明确失败 |
| 抛其他错误、超时或执行被中断 | 提交不确定，不再提交 |

query 抛错表示查询请求本身失败，不判为远端生成失败。两类任务的状态对应如下，均沿用现有任务服务：

| 语义 | 视频 | 图片 |
| --- | --- | --- |
| 查询中 | running，由 Host 调度查询 | running，本次运行内循环查询 |
| 提交不确定 | submission_unknown | failed，错误码 submission_unknown，由用户决定是否重新生成 |
| 人工核对（含 query 返回 unknown） | reconciliation_required；内置渠道超出已知查询窗口转 expired，插件不套用内置期限 | action_required |
| query 抛错 | 按现有退避下次再查 | 结束本次运行，转 action_required |

### Host 与插件同一合同

上述类型同时是 Dart 侧 `VideoClient`、`ImageClient` 的提交与查询合同，内置 client 与插件 client 实现同一接口，任务服务不区分来源：

- 现有视频的 `VideoSubmission{taskId, modelId, pollingUrl}` 与 `VideoTaskResult` 改为 `SubmitResult`、`QueryResult`。`pollingUrl` 原本可由远端 ID、模型 ID 与当前配置算出，持久化它只为在用户改了接口根后拒绝把新凭据发到旧地址；内置 client 改为把它放进 state（`{ "queryUrl": "..." }`），查询前用当前配置重算并与 state 比对，保留这道检查；升级前已提交的旧任务没有 state，从 `polling_url` 兼容读取。
- 现有图片 client 的一次生成、提交回调（远端 ID、远端 URL）与 `resumeResult(远端ID)` 改为同一组结果类型；`resumeResult` 即不带 state 的 query。图片多候选仍对应 `imageOutputs`。
- 下载统一用 url 型输出的 `headers` 携带鉴权，删除内置 `VideoClient.download` 的覆盖（openrouter、new_api），由 Host 按 headers 下载。当前这两个内置视频 client 对任务 content 地址的首次 GET 附加 `Authorization: Bearer <apiKey>`，重定向后的请求不附加；迁移后在生成 Output 时保留任务 content 地址的校验，再返回对应 headers。其他内置视频 client 走默认无鉴权下载；内置图片结果 URL 的共用下载路径不主动附加鉴权 headers，生成和查询接口的鉴权不得误加到结果 URL。
- 远端生成失败统一为 `ProviderFailure`。插件的可读 `message` 原样展示，不作为翻译 key；内置 client 在构造结果时翻译自身的 messageKey，上游可读原文仍直接保留。
- 插件 client 只把调用转给插件，并负责校验 outputs、处理 `image.request`、`video.request` 生成或绑定的文件。
- 远端 ID 存 `providerTaskId`，state 存新增的 `provider_state` 列，内置与插件、图片与视频都相同。

两类任务仍只在谁负责轮询上不同：视频沿用 Host 调度，图片沿用本次运行内循环；统一轮询需要重写图片任务服务，不在本轮范围。

## 视频提交与查询

```ts
type PreparedReference = {
  assetId: string;
  role: ReferenceRole;
  mimeType: string;
  fileSize: number;
  mediaInfo: {
    width?: number;
    height?: number;
    durationMs?: number;
    frameRate?: number;
  };
  source:
    | { kind: "certified"; remoteId: string }
    | { kind: "url"; url: string; expiresAt?: string }
    | { kind: "uploaded"; ref: string; expiresAt?: string }
    | { kind: "file"; handle: string };
};

interface SubmitVideoInput {
  request: {
    modelId: string;
    prompt: string;
    mode: "text" | "first_frame" | "first_last_frame" | "reference";
    resolution: string;
    ratio: string;
    durationSeconds: number;
    audio?: boolean;
    promptExtend?: boolean;
    draft?: boolean; // 提交样片，仅 capabilities.draft 非空的模型
    defaults: JsonObject; // 冻结的 requestDefaults，含 Host 未识别字段
    referenceSlots: Array<{
      assetId: string;
      role: ReferenceRole;
      slot: string;
      clipId?: string;
      inputId?: string;
    }>;
  };
  references: PreparedReference[];
  /** 由样片生成成片时提供；此时 references 为空，平台复用样片输入 */
  draftOf?: { remoteTaskId: string; state?: JsonObject };
}
```

素材顺序及 `referenceSlots` 的语义沿用 [VideoRequest](../../../lib/shared/models/video/request.dart)，Host 不在转换时重排。内置 `submit(VideoRequest, List<VideoReference>, {draft, draftId})` 改为接收同一结构，`draftId` 对应 `draftOf.remoteTaskId`。

样片沿用现有流程：模型 `capabilities.draft` 非空时可提交样片，样片分辨率取 `draft.resolution`；用户从已完成的样片生成成片时，Host 新建任务，分辨率取 `draft.completionResolution`，以 `draftOf` 传入样片的远端 ID 与 state，不重传参考素材；样片超过 `ttlHours` 后不能生成成片。同一样片同时只允许一个进行中的成片任务。旧样片不做能力快照兼容：缺少冻结的 draft 能力时，不从当前 catalog 或旧常量补齐，不允许从该样片继续生成成片，并显示需要重新生成样片。历史记录与已生成的媒体保留，不迁移或删除旧样片数据。

`video.request(url, request)` 与 `image.request` 的请求结构相同，用于把 `file` 型参考按 JSON Pointer 内联或以 multipart 发送；响应只支持 `kind: "json"`，不提取媒体。视频成片只支持 url 型输出，与内置一致。

`submit` 只负责一次生成提交，取得远端任务 ID 立即返回 submitted，不在里面轮询或下载；视频返回 succeeded 按合同错误处理。Host 提交前完成参数与素材校验，并先把任务状态持久化为 `submitting`。进入 submitting 后拒绝用户取消。超时、进程退出、返回无效远端任务 ID 等不能证明未受理的情况，保持或恢复为 `submission_unknown`，禁止自动重提。本地 taskId 可以作为平台支持的幂等键，但不能仅凭本地 ID 声称远端幂等。

一个媒体任务固定绑定 kind、pluginId、providerId、modelId 和创建时能力快照，不迁移到其他实例。查询使用实例当前保存的配置；任何恢复路径都不得把不确定提交变成自动重提。本轮仅支持用户配置凭据，不实现自动刷新。

`query` 每次只查询一次。请求方法、URL、body、响应路径和状态判据由插件控制；POST 查询与收费提交是不同操作，不能像现有基础 client 一样通过 HTTP 方法判断提交不确定性。平台仅表示会话结束、等待人工确认或没有视频资源时返回 `unknown` 及原因，Host 停止自动轮询，等待用户核对。内置 wan 在提交 24 小时后、minimax_video_v2 在提交 7 天后返回 unknown 或 not_found 时转 expired；插件不套用这些期限，可明确返回 expired。

Host 收到 succeeded 后在同一事务内把任务置为 `saving`，保存 outputUrl，再用返回的 URL 和内存 headers 流式下载，完成文件校验、媒体探测和素材登记，不把视频字节放进 JS 或 JSON。下载失败时任务保持 `saving`，下次刷新重新调用 query 取得当前下载地址与 headers；只更新持久化 URL，headers 用于当次下载（沿用现有视频任务服务对 `saving` 的处理），不调用 submit。同一任务使用既有结果登记去重逻辑，不能因查询或下载重试产生多条素材。

### 错误与取消

方法抛错沿用 SDK 的 `PluginError`，预期分类使用 `invalid_request`、`configuration_required`、`authentication`、`rejected`、`rate_limited`、`unavailable`、`submission_unknown`、`invalid_response`、`not_found`。`rejected` 只能用于已知未受理的提交。Host 根据当前业务阶段决定重试；未知异常在 submit 阶段按提交不确定处理，其他阶段保留诊断并按任务策略处理。

上游生成失败的 `ProviderFailure` 保留实际错误码和可读 message，detail 保存诊断。面向 Agent 的结果保留实际错误和命令诊断；面向用户的 UI 不直接展示异常对象、堆栈和完整 HTTP 响应体，平台可读错误 message 可展示。

取消按任务阶段处理。视频准备和上传阶段可以取消，进入 `submitting` 后数据库拒绝取消请求，取消监听也不再中断提交；这以开始提交为边界，未实现精确到请求体发送完成的判断。取得远端任务 ID 后可停止本地轮询，已进入 saving 或已有输出时继续下载保存。内置音频同步提交使用 `running`：`submittedAt` 非空且尚无 `providerTaskId` 时同样拒绝取消；取得远端 ID 后可停止轮询。图片保持现有取消语义，本轮未增加图片提交阶段的禁止取消。

允许取消的阶段由 Host 中止本次网络和文件操作，撤销迟到 handler 的调用权限；超时与应用关闭仍可中断请求。停止本地等待不代表平台已取消生成，首版不提供远端取消方法。已取得的合法远端任务 ID 必须保留，之后可显式恢复查询；没有回执的中断不能保证远端未受理，也不自动重新提交。

## 聊天能力

> 暂缓：聊天能力首版不实施，本节保留标准协议（T-32）和自定义（T-33）两种模式的设计。

聊天接入现有 [ProviderClient](../../../lib/shared/agent/client.dart)，插件执行一次模型请求，宿主继续编排提示词、上下文压缩、工具审批与执行、下一轮请求、聊天持久化及用量。不把整个 Agent 循环交给插件。

### 模型

```ts
type ChatBinding =
  | {
      mode: "protocol";
      protocol: "openai_chat" | "openai_responses" | "anthropic" | "gemini";
      apiModelId?: string;
    }
  | { mode: "custom" };
```

聊天模型的 `chat` 使用该联合类型。`apiModelId` 默认为模型 ID；同一实例可以提供多个协议的模型，不从供应商名称推断协议。上下文与输出 token 上限、图片输入、工具调用和推理选项由插件在模型 capabilities 中声明，Host 按声明校验，不查询聊天 catalog。不支持的参数在发送前明确报错，不静默删除。模型不能同时走 protocol/custom，任一路径失败都不自动切换另一条。

### 标准协议模式

| 方法 | input | 返回值 |
| --- | --- | --- |
| `chat.prepareRequest` | `{ modelId, protocol, request: { path, method, headers, body } }` | `{ url, headers, body }`，完整替换值 |

Host 按协议选择 `OpenAiClient`、`OpenAIResponsesClient`、`AnthropicClient` 或 `GeminiClient`，用 `apiModelId` 编码消息、工具和生成参数，得到相对路径（如 `/chat/completions`）、method、协议头和 JSON body，但不附加接口根和鉴权。插件读取实例配置和凭据，返回完整 URL、headers（含鉴权）和 body，可以补平台参数或改字段；Gemini 的 query 鉴权由插件写进 URL。该方法只调整请求，不自行发送。

返回后 Host 重新编码 JSON、计算传输头，通过实例代理发送，仍由原 client 解析响应与流。prepareRequest 不改变 HTTP method 和协议；需要不同响应协议的模型使用 custom。URL 只接受 HTTP(S)，重定向不跨源带出凭据。

每次发送（包括宿主重试）都调用一次 prepareRequest，不在插件中缓存 token。普通与流式请求都要注入同一套准备逻辑，不能只包装共享 http.Client 而遗漏 streamClientFactory。取消要覆盖请求准备及上游请求，每次流使用独立可关闭的 transport，不能误杀同实例其他请求。

```text
Agent → 现有 client 编码 → prepareRequest → Host HTTP → 现有 client 解析 → Agent
```

### 自定义业务模式

`chat.generate(input, context)` 的 input 包含 `modelId`、`messages`、`tools` 和 `options`。messages 是 [AgentMessage / MessageBlock](../../../lib/shared/agent/message.dart) 的严格 JSON 映射，保留角色、消息类型、文本、图片、工具调用 ID、工具结果、推理签名和加密推理内容。不能压成简单的 role/content 文本。消息中的图片如何交给插件发送尚未确定，可选方向是让 `http.stream` 支持与 `image.request` 相同的文件绑定；不能传任意本地路径。

tools 包含工具名称、description 和 JSON Schema，使用本轮宿主批准的完整定义；options 只包含模型支持的温度、输出上限及推理设置，不暴露完整 AgentConfig 或工具执行权。协议附加数据由 Host 绑定来源实例、模型及协议，换供应商时经过现有历史预检，不盲目转发其他平台的签名。

context 增加 `emit(event): Promise<void>` 和 `http.stream(url, init)`。emit 的事件对应现有 StreamEvent 的语义：

| type | 字段与语义 |
| --- | --- |
| `text_delta` | `text`，追加正文 |
| `thinking_delta` | `text`，追加可展示推理 |
| `signature` | `signature`，当前完整签名；多次发送以最后值为准 |
| `encrypted_content` | `content`，追加一条加密推理数据 |
| `tool_call` | `callId`、`toolName`、`arguments`、`isPartial`、可选 `thoughtSignature`；arguments 为当前对象快照，按 callId 更新，不拼接对象 |

generate 正常返回 `{ finishReason, usage? }`，结束原因使用 stop、length、toolCalls、contentFilter、unknown；用量映射现有 AiUsage，输入包含缓存 token，输出包含推理 token，不重复累计。缺少 usage 表示未报告。Host 将返回值转换成唯一的完成事件，随后关闭运行时；插件不能自行 emit 完成或取消事件。方法抛错保留诊断并结束失败，不能把流中断伪装成正常返回。

半截工具参数只用于展示，只有完整且通过 schema 校验的调用进入现有宿主工具执行流程；工具结果加入下一轮 messages。插件不能在 generate 中执行工具或调用递归 AI。非流式上游可以只 emit 一次，宿主非流式调用方也可聚合同一事件流，不要求插件再实现一份 chat 方法。

`http.stream` 返回 status、headers 和可逐块读取的异步字节流，非 2xx 也返回供插件解析。协议帧、UTF-8 字符和工具参数可能跨块，解析由插件处理，通过消费确认继续读取。它使用相同的实例代理和调用取消，不受普通 fetch 完整响应上限约束。emit 必须 await，Host 校验事件和调用代次后才确认。

单次生成区分首个网络响应、流读取空闲和整体超时；收到上游字节重置流空闲计时，emit 不能重置网络空闲计时。取消时中止请求、流读取、emit 等待和插件运行时；已关闭调用的事件全部丢弃，不能关闭其他调用。部分输出、工具调用完成与取消必须传递给现有轮次处理；新增适配需要专门覆盖断流与半截工具参数，不将 StreamError 当成正常 finish。

### 重试与鉴权

重试由宿主现有策略管理，插件不重放生成；不能把已执行的工具随网络重试再执行一次。

本轮只使用用户配置的 Key、Cookie 或 token，不提供 OAuth 登录或自动续期；后续方向见 [OAuth 登录](#oauth-登录后续迭代)。

## 图片能力

图片沿用现有 [图片任务服务](../../../lib/shared/services/production/image_service.dart) 的流程：任务从 prepared 进入 running，异步结果在本次运行内轮询，远端任务 ID 与远端图片 URL 先落库，查询失败、应用退出或崩溃后转 action_required，由用户“重新获取”恢复。插件只替换 [ImageClient](../../../lib/shared/services/ai/image/client.dart) 这一层，Host 复用现有的提交记录、远端 URL 记录、候选暂存、素材登记与采用流程，不为图片新增 Host 调度。

### 模型与方法

能力与默认值由插件在 capabilities、requestDefaults 中声明，映射到 [图片配置模型](../../../lib/shared/models/image/config.dart)，详见[能力声明](#能力声明)。Host 先校验并冻结最终请求。一次任务可返回多张候选图，对应现有 `imageOutputs`；本轮不增加 mask、局部重绘或任意参数透传。

| 方法 | input | 返回值 |
| --- | --- | --- |
| `image.submit` | `SubmitImageInput` | `SubmitResult` |
| `image.query`，可选 | `QueryInput` | `QueryResult` |

```ts
interface SubmitImageInput {
  request: {
    modelId: string;
    prompt: string;
    ratio: string;
    resolution: string;
    size?: string;
    quality?: string;
    complexity?: string;
    defaults: JsonObject; // 冻结的 requestDefaults，含 Host 未识别字段
  };
  references: Array<{
    assetId: string;
    clipId?: string;
    inputId?: string;
    mimeType: string;
    source:
      | { kind: "file"; handle: string }
      | { kind: "url"; url: string; expiresAt?: string }
      | { kind: "uploaded"; ref: string; expiresAt?: string };
  }>;
}
```

内置 `generate(ImageGenerationRequest)` 改为接收同一结构：`prompt/model/size/quality/complexity/aspectRatio/resolution` 对应 request 字段，`images: List<String>`（data URI）改为上述 references，内置 client 按 source 类型编码；内置也收到 `defaults`，不再自行查渠道默认值。references 的顺序、assetId/clipId/inputId 关联来自冻结的 ProductionImageRequest；原始提示词继续保留在 Host，插件收到最终生成提示词。图片初版不开放视频的首尾帧角色。

### 图片异步任务

submit 等待一次上游响应：上游直接给出结果时返回 succeeded，不伪造远端任务 ID；上游返回任务时返回 submitted。

- submitted：Host 立即记录远端任务 ID 与 state（对应现有提交记录），在本次运行内每 2 秒调用一次 query，与内置异步图片 client 一致；运行内总等待上限见[超时预算](#超时预算)。
- succeeded（submit 或 query）：url 型输出只将 URL 逐项写入 `imageOutputs`，再由 Host 使用内存中的 headers 下载；file 型输出直接暂存；随后按现有流程暂存候选、登记素材。
- query 抛错、运行内总等待超时、应用退出或崩溃：有远端任务 ID 或已记录 URL 的任务转 action_required。用户“重新获取”时，有未下载的 URL 就先不带额外 headers 尝试下载，否则用远端任务 ID 调用一次 query；均不调用 submit。URL 或 headers 失效且有远端任务 ID 时重新 query，保存新 URL，并用本次查询返回的内存 headers 重试；没有远端任务 ID 时明确提示该下载引用无法刷新，不自动重新生成。
- query 返回 failed、cancelled、expired 时转为对应终态；返回 unknown 时转 action_required。
- 没有远端任务 ID 也没有结果时中断，沿用现有图片行为转 failed，不自动重新生成；同步接口无法断点续跑的限制在界面说明。

每次 query 只查询一次，POST body 和状态解析由插件决定。内置异步 client（atlascloud、midjourney）同样拆为 submit 与 query，原来在 `generate` 内的循环和 `onSubmitted`、`onOutputs` 回调移到 Host；同步 client 直接返回 succeeded。

### 参考图传输

`ImageModelCapabilities` 新增 `referenceTransport: "file" | "url" | "uploaded"`，内置与插件模型都按它准备参考图：

| 取值 | Host 准备 | 适用平台 |
| --- | --- | --- |
| `file` | 发放本地图片句柄，内置 client 编码为 data URI，插件经 `image.request` 内联或以 multipart 发送 | 生成接口直接接收图片内容，如 OpenAI Images |
| `url` | 经现有对象存储上传，交给 client 公网 URL；未配置存储时报需要配置存储 | 只接收图片 URL 的平台 |
| `uploaded` | 调用实例的 `uploadReference`（内置为 `UploadProtocol`），结果写入 `provider_assets`（kind = upload）并跨任务复用 | 要求先上传的平台，如 ComfyUI 先调 `/upload/image` 再在 LoadImage 中引用文件名 |

内置 catalog 与渠道条目缺省为 `file`，现有内置图片行为不变；内置渠道需要时可改为 `url` 或 `uploaded`，由对应 client 处理该 source 类型。插件模型必须显式声明。声明 `uploaded` 但实例未注册 `uploadReference` 时，调用该模型才报明确错误。选定方式执行失败时明确报错，不切换其他方式；三种方式均遵循用户素材上传确认。

图片 submit/query 上下文新增 `image.request(url, request)`，由 Host 处理文件字节，插件继续负责平台协议。请求结构如下：

- `method`、`headers`、`timeoutMs`：普通 HTTP 语义，使用当前实例代理。
- body 为 `kind: "json"` 时，提供 `value: JsonObject` 和可选 `files: [{ pointer, handle, encoding: "base64" | "data_uri" }]`。pointer 是指向已存在占位字段的 JSON Pointer，Host 把该字段替换为对应文件内容；无通配符，不支持执行表达式。
- body 为 `kind: "multipart"` 时，提供字符串 fields 和 `files: [{ field, handle, name? }]`；保留数组顺序和重复字段名以支持多张 `image[]`。Host 构造 boundary 和流，不接受任意文件路径。
- `response` 为 `{ kind: "json", images?: [{ pointer, encoding: "base64" | "data_uri" }] }` 或 `{ kind: "file" }`。json 模式的 image pointer 指向平台已知的字段，例如 `/data/0/b64_json`，不是宿主写死的平台解析规则。

2xx JSON 响应在 Host 解析指定图片字段并保存临时文件，把该字段替换成 file 型 Output 后，将剩余 JSON 连同 HTTP status/headers 返回插件。file 模式仅对 2xx 的图片响应保存文件并返回 file 型 Output；非 2xx 返回有界诊断正文，不能把错误 HTML 当图片。非 2xx JSON 不执行图片字段提取，返回有界错误正文供插件诊断。JSON/file 模式返回 `{ status, headers, body }`，body 分别为替换后的 JSON 或 file 型 Output，错误正文按字符串返回。普通 URL 响应无需 images 选择器，由插件解析后返回 url 型 Output。上游返回内联图片时必须使用 image.request，不能经普通 http.fetch 将大段 base64 搬入 JS；Output 没有 base64 类型，base64 只能经 image.request 转成 file 型输出，也不能放进 state。内置图片 client 返回的 `imageBase64` 同样由 Host 转为 file 型输出，二者结果处理一致。

Host 在接收和解码时逐项释放缓冲，不把整个响应和图片复制到 JS。JSON 指针缺失、编码非法和非图片数据均明确报错，不截断后保存。

输入句柄只能用于本次任务，输出句柄必须由本次 image.request 创建。Host 在返回句柄前将文件及其任务归属记录到暂存清单；收到 succeeded 后按现有候选暂存流程转为可跨重启恢复的文件，原始 handle 不作为重启后授权依据。若崩溃发生在暂存完成但业务结果尚未确认之间，保留文件供核对，不推断成功或自动重提。临时输出只在媒体校验和结果登记成功后成为正式素材。

### 结果登记

Host 使用现有图片结果服务完成 MIME/尺寸验证、素材登记和节点采用，任务 ID 保证登记去重；多张候选按 `imageOutputs` 逐项暂存，不覆盖其他候选。提交已成功而下载、暂存或入库失败时，只恢复失败阶段。插件不修改素材库或画布。

所有能选择图片模型的入口都可以使用插件图片模型，包括制片节点、封面、地图和聊天中的 Agent 生图；它们都经现有 `AiImageGenerationService` 选择 client。只有制片任务有任务记录和恢复；地图、聊天等直接生图入口与内置模型一样，运行中断即结束，不提供恢复。

图片复用视频的任务绑定、插件停用/升级及错误处理规则。

## 生命周期与持久化

```text
入口 → Host 校验与任务落盘 → 认证素材 / uploadReference / 对象存储 / 本地句柄
                                   ↓
                                submit ── succeeded ──→ Host 下载或暂存、素材登记
                                   │ submitted
                                   ↓
                     Host 保存远端任务 ID 与 state
                                   ↓
                     query（视频由 Host 调度；图片在本次运行内循环）
                                   ↓ succeeded
                     Host 下载或暂存、素材登记（视频下载失败时重新 query）
```

Host 拥有实例配置、凭据、模型列表、任务状态、远端任务 ID、任务 state、上传与认证记录和结果登记；插件只解释平台协议，不为恢复任务写 `storage`。

实例存储不新增列或表（任务 state 的新增列见下文）：

| 内容 | 存放位置 |
| --- | --- |
| 类型 | `ai_providers.type` 本就是 text 列，插件实例存 `plugin:<pluginId>`；插件 ID 格式不含 `:`，按插件查找实例使用精确匹配 |
| 名称、启停、代理、软删除 | 复用现有 `name`、`enabled`、`proxyUrl`/`proxyUsername`/`proxyPassword`、`deletedAt` |
| `apiKey`、`baseUrl` | 插件实例不使用，保持空值；接口根和凭据都按插件声明的字段保存 |
| 普通配置 | `plugin_storage`，key 为 `provider.<providerId>.<字段名>`，与 `settings.*`、`data.*` 互不可见；ProviderContext 的 `storage` 只能访问 `data.*` |
| 凭据 | `plugin_secrets`，key 同样使用 `provider.<providerId>.` 前缀 |
| 模型列表与声明 | ID 存现有 `models`、`imageModels`、`videoModels` 列；完整声明存 `plugin_storage` 的 Host 保留 key `provider.<providerId>.__models`，见[刷新与持久化](#刷新与持久化) |
| 任务 state | 新增的 `generation_tasks.provider_state`，见[提交、查询与任务状态](#提交查询与任务状态)；远端 ID 存现有 `providerTaskId` |
| 下载引用 | 视频 URL 存 outputUrl；图片候选 URL、本地文件及素材引用存 imageOutputs；headers 仅在内存中使用，不持久化 |

删除实例时软删除 `ai_providers` 记录，并在同一事务内物理删除 `plugin_storage`、`plugin_secrets` 中该实例前缀的记录（2026-11-06 用户确认，只限该前缀，实施时登记到 `.agents/rules/data-deletion.md`）；任务记录、历史结果和任务 state 保留，不随实例删除；`provider_assets` 中该实例的上传与认证记录沿用内置供应商删除时的处理，保持不动。代码中的类型身份统一为字符串，由类型注册表作为唯一来源：内置类型以现有枚举名注册，插件激活时注册 `plugin:<pluginId>`，停用或卸载时移除；内置专用的协议分支可继续使用枚举。插件异步激活前及停用后，实例显示插件未启用或已卸载，不自动停用、不清理数据，仍允许编辑名称和启停；注册完成后重新计算可用状态。

新增持久化内容使用列、索引与项目既有软删除写法，不引入外键、CHECK 或触发器。已核对最新正式发布 tag `v0.9.0` 的主库 schema 为 6，当前实现为 7；v7 migration 仅为 `generation_tasks` 增加可空文本列 `provider_state`，旧行值为空。此前拟增加的 `output_headers` 未进入正式发布，已从表定义和 v7 migration 移除，不增加新版本或开发库兼容层。新任务不再写 `polling_url`；内置视频 client 查询时，`provider_state` 为空且 `polling_url` 非空的旧任务按 `{ "queryUrl": <polling_url> }` 读取，兼容升级前已提交的任务。迁移测试覆盖 schema 1 至 6 fixture 升至 v7，并通过 Typed DAO 核对旧记录与新增列。

现有 `providerTaskId` 保存远端 ID，任务 state 存 `provider_state`；图片远端 URL 沿用 `imageOutputs`，视频结果 URL 保留在 `outputUrl`，二者均不保存下载头。视频查询前置条件使用远端 ID，不要求 `pollingUrl != null`，插件任务不受固定 API Key 字段的前置条件限制。

停用或卸载插件后拒绝新调用，停止自动查询，保留任务记录和历史结果。停用保留实例与凭据；卸载按[卸载](settings-and-storage.md#卸载)软删除实例并删除其配置与凭据；任务记录和历史结果仍可查看，重新安装后需新建实例。正在执行的 Provider 调用在有界预算内收尾，保存已获得的有效远端任务 ID；不再派发下一个阶段。已开始的 Host 下载可完成登记，因为不需要继续执行插件。重新启用同一身份后，按远端任务 ID 恢复查询或下载，不能重放 submit。

更新时先停止派发并等待当前调用收尾，再按现有插件更新流程切换版本。新版本无法解析旧版本返回的任务 state 时返回明确的兼容错误，暂停对应任务，不丢弃状态、不重新提交。插件更新后按[刷新与持久化](#刷新与持久化)后台刷新已添加模型的声明，本身不等同于账号变更。旧模型下架、插件启动失败或包缺失时，历史任务仍可见并显示具体原因。

Android 退出或后台不承诺持续执行；恢复时复用 Host 的任务恢复流程。视频任务有远端任务 ID 只查询，没有的 `submitting` 进入提交不确定状态；图片任务按[图片异步任务](#图片异步任务)转 action_required 或 failed。备份包含实例、配置、凭据、任务记录及插件 `storage`，沿用当前备份的凭据处理约定。回滚实现时暂停插件供应商并保留这些数据，内置供应商继续工作；不通过删业务数据回滚。

## OAuth 登录（后续迭代）

本节只是设计，不排入 T-31a 至 T-34，出现需要 OAuth 的平台插件时再立任务。首版仍只使用用户填写的凭据。

### 分工

支持授权码 + PKCE 和设备码（RFC 8628）两种授权方式。OAuth 流程全部由 Host 执行，插件只在清单中声明参数，调用时向 Host 取当前有效的 access token。插件拿不到 refresh token，也不实现登录、刷新或 token 交换，ProviderContext 不因此获得凭据写入能力。授权码方式复用 MCP 已有的授权事务、PKCE、回调、刷新去重和代次提交；设备码方式不需要回调，共用同一套存储、刷新和代次提交，见 [MCP OAuth](../../../lib/shared/services/mcp/oauth/)。

### 清单声明

`provider` 新增可选的 `auth`：

```jsonc
"auth": {
  "type": "oauth2",
  "grant": "authorization_code",        // 或 "device_code"
  "authorizationUrl": "https://…",      // authorization_code 必填
  "deviceAuthorizationUrl": "https://…",// device_code 必填
  "tokenUrl": "https://…",
  "revocationUrl": "https://…",         // 可选
  "clientId": "…",                      // 公开客户端
  "scopes": ["…"],
  "extraAuthParams": { "prompt": "consent" }  // 可选，不能覆盖 PKCE、state、redirect_uri 等标准参数
}
```

一个插件只声明一种 `grant`，缺少对应端点时激活失败；另一种方式的端点出现时同样拒绝，不由 Host 自动选择。URL 只接受 HTTPS，不支持按实例配置拼接模板。清单不含 `client_secret`，写在包里等于公开；平台强制要求时，插件声明 secret 实例字段由用户填写，Host 换取和刷新 token 时附带。`auth` 与普通 `settings.fields` 可以共存。

### 授权码回调

| 平台 | redirect URI |
| --- | --- |
| Windows、macOS | `http://127.0.0.1:<随机端口>/plugin/oauth/callback`，按 RFC 8252 loopback 处理 |
| Android | `ai.reveric://plugin/oauth/callback`，manifest 新增对应 intent-filter |

所有插件共用同一回调地址，按 `state` 匹配事务。MCP 的回调实现提取为 `lib/shared/services/oauth/` 下的通用组件，MCP 与插件 Provider 共用，各自只传入回调路径。平台 OAuth 应用由插件作者登记这两类 redirect；不接受 loopback 或自定义 scheme 的平台无法接入，插件需在说明中写明。

### 设备码流程

适用于不允许登记 loopback 或自定义 scheme 的平台，三个平台走同一流程，不需要回调地址和 manifest 改动。

1. Host 向 `deviceAuthorizationUrl` 提交 `client_id` 和 `scope`，取得 `device_code`、`user_code`、`verification_uri`、可选的 `verification_uri_complete`、`expires_in` 和 `interval`。缺少必填字段或 URI 不是 HTTPS 时直接失败。
2. 登录对话框显示 `user_code`（可复制）和剩余有效期，提供打开验证页的按钮，有 `verification_uri_complete` 时优先打开它。Host 不自动把 `user_code` 填进任何页面。
3. Host 按 `interval`（未返回时 5 秒）向 `tokenUrl` 轮询 `grant_type=urn:ietf:params:oauth:grant-type:device_code`：
   - `authorization_pending`：继续等待。
   - `slow_down`：间隔加 5 秒后继续，之后不再缩短。
   - `access_denied`、`expired_token`：结束并显示原因，需要重新发起。
   - 其他错误或非预期响应：结束并保留平台返回的 `error` 与 `error_description`。
   - 成功：与授权码方式相同地校验并写入 token。
4. 轮询绑定登录对话框：关闭对话框、取消或超过 `expires_in` 即停止。同一实例同时只有一个登录事务，重新发起会作废上一个，迟到的成功结果不写入。

Android 切到浏览器后应用进入后台，不承诺后台继续轮询；回到前台时若事务未过期，立即补一次轮询再按间隔继续。桌面端不受影响。设备码不使用 PKCE，`client_secret` 规则与授权码方式相同。

### 存储

token 存在 `plugin_secrets`，key 为 Host 保留的 `provider.<providerId>.__oauth`，value 为 JSON：`accessToken`、`refreshToken`、`expiresAt`、`scope`、`tokenType`。这个 key 不对 `secrets.get` 开放，也不在配置表单中回显。

退出登录时物理删除该行，不保留记录（2026-11-06 用户确认）。范围只限这一个 key，不扩展到该实例的其他凭据、配置或任务数据；实施时把此例外登记到 `.agents/rules/data-deletion.md`。删除实例时与其他凭据一起处理。

### 上下文接口

| 成员 | 语义 |
| --- | --- |
| `auth.accessToken({ forceRefresh? })` | 返回当前有效 token。距过期不足 60 秒时 Host 先刷新，同一实例的并发刷新合并为一次；无有效 token 或刷新失败时抛 `auth_required` |

未声明 `auth` 的插件调用时报错。插件收到 401 后可以带 `forceRefresh: true` 取一次新 token 并重试，不能循环重试。`prepareRequest` 每次发送都调用 `auth.accessToken()`，与插件不缓存 token 的约定一致。

### 刷新与状态

- 声明 `auth` 的实例未登录时视为配置不完整，不能选择模型。登录绑定已保存的实例，表单草稿不能登录。
- 刷新轮换的 refresh token 原子写回。退出登录或重新登录使进行中的刷新失效，迟到结果不得写回旧 token。
- 刷新被拒（如 `invalid_grant`）时，实例标记为需要重新登录。已有远端任务 ID 的媒体任务暂停查询，不判失败，重新登录后恢复；没有远端任务 ID 的任务不提交。聊天请求直接报 `auth_required`。
- 备份沿用现有凭据约定。恢复到另一台设备后，两端共用同一 refresh token，一端轮换会让另一端失效，失效端按上一条重新登录。

### 界面

实例编辑页显示登录、重新登录、退出登录，点击登录后按清单的 `grant` 打开浏览器或设备码对话框；登录后用 `checkConnection` 返回的 `accountLabel` 显示账号。退出时有 `revocationUrl` 就先撤销，撤销失败仍删除本地 token，并提示用户远端授权可能仍有效。

### 不做与妥协

- 不做插件自定义 token 交换、多账号轮换，也不支持同一插件同时提供两种授权方式。
- 插件拿到 access token 后可以发往任意地址，Host 无法像 MCP 那样把 token 限定在资源范围内。这与 [README 已知妥协](README.md#已知妥协)中插件可访问任意网络地址一致。

## 实施落点与验证

首版实施三项，T-32 标准协议聊天和 T-33 自定义聊天暂缓。查询已复用专用常驻运行时，提交与上传保持隔离。各项包含自己的模拟插件、错误路径和三平台验收。实施顺序为 T-31a → T-34 → T-31b；T-31a 是基础设施子任务，首个可用交付包含 T-31a 与 T-34，必须用测试插件跑通图片生成，不能把仅能选模型视为功能交付。T-31b 随后交付视频闭环。

| 任务 | 范围 | 完成标志 |
| --- | --- | --- |
| T-31a 公共注册、实例与模型 | 清单 `provider` 与 SDK 类型；`setup.provider.register` 及激活校验；字符串类型注册表；ProviderContext 的实例绑定配置、凭据、`storage`、实例代理 HTTP；桌面与移动端插件实例的创建、编辑、启停与删除；`checkConnection`、`listModels`、内置视频能力模型调整、插件能力声明的解析与持久化、Provider 分阶段预算派发；`provider_state` 列与 schema 迁移；下载头仅内存使用 | 内置视频模型迁移前后校验结果一致；安装模拟插件后能创建多个实例、检查连接，在图片和视频模型选择器中看到并选中插件模型；尚不能生成 |
| T-31b 视频链路 | 复用 `files.upload` 与 `uploadReference`；`assets.submit/state` 及内置认证 client 迁移；`video.request`；样片；内置 `VideoClient` 迁移到统一合同；submit、query、任务 state；Host 状态落盘、下载登记、崩溃恢复与插件停用/更新/卸载处理 | 模拟平台跑通上传、提交、POST 查询、下载入库，并覆盖提交不明、下载失败和重启恢复 |
| T-34 图片链路 | 见[图片能力](#图片能力)；内置 `ImageClient` 迁移到统一合同；`files.upload`、`uploadReference` 及内置平台上传 client 迁移；`referenceTransport` | 同步结果与异步任务都能进入现有结果流程；内置图片回归通过 |

T-31b、T-34 均依赖 T-31a，业务上彼此不依赖；`files.upload` 与 `uploadReference` 视频和图片共用，按实施顺序由 T-34 提供，T-31b 复用并增加素材认证。T-32、T-33 依赖 T-31a。实际改动预计超过 8 个文件，主要落点如下：

| 范围 | 现有入口与所需改动 |
| --- | --- |
| SDK 与清单 | `plugins/sdk/index.d.ts`、`lib/shared/models/plugin/manifest.dart`：定义 providers、方法与 JSON 合同，校验注册完整性 |
| 插件执行 | `lib/shared/services/plugins/host.dart`、`runtime.dart`、`prelude.dart`：注册快照、按阶段上下文、实例绑定、分阶段超时和取消；`http.dart` 增加 Provider 代理作用域，普通插件语义保持原样 |
| 实例设置 | `lib/shared/models/ai_provider.dart` 与现有供应商设置入口：字符串类型注册表、`plugin:<pluginId>` 类型、插件字段表单、多实例与启停，桌面和移动端共用合同 |
| 模型与校验 | `lib/shared/models/image/config.dart`、`lib/shared/models/video/config.dart`、`catalog.dart`、`channels.dart`、`capabilities.dart`、`lib/shared/services/ai/provider_resources.dart`、`video/wan.dart`、`lib/desktop/features/production/composer.dart` 及模型选择入口：按[视频能力模型调整](#视频能力模型调整)迁移内置字段；解析插件声明，以实例和模型身份解析能力，内置与插件共用同一校验入口 |
| 生成链路 | `lib/shared/services/ai/video/task_service.dart`、`client.dart`、`draft.dart`、`reference_storage_service.dart`、`lib/shared/services/ai/assets/`：`VideoClient` 改为 SubmitResult/QueryResult 合同，内置 client 的 queryUrl 移入 state，新增插件视频 client；平台上传与素材认证改为内置/插件共用接口、参考准备顺序、样片改读能力快照、恢复查询和错误阶段判断 |
| 聊天链路（暂缓） | `lib/shared/services/ai/provider_initializer.dart`、`lib/shared/agent/client.dart` 与 `client/`：标准 client 选择、普通与流式 HTTP 注入 prepareRequest；沿用 Agent 循环 |
| 图片链路 | `lib/shared/services/ai/image.dart`、`image/client.dart`、`lib/shared/services/production/image_service.dart`、`image_generate_orchestrator.dart`：`ImageClient` 改为 SubmitResult/QueryResult 合同并新增插件图片 client，复用现有提交记录、远端 URL 记录、候选暂存与采用；制片、封面、地图、聊天生图入口同步检查 |
| 数据 | `lib/shared/database/app_database.dart`、`plugin_dao.dart`、`generation_task_dao.dart`：实例配置与模型声明的 key 前缀隔离、模型 ID 与声明原子更新、任务 requestJson 能力快照、删除实例时清理前缀记录；`generation_tasks` 新增 `provider_state` 列，imageOutputs 不序列化 headers，`schemaVersion` 6 → 7，不迁移已有数据，旧任务的 `polling_url` 由代码兼容读取 |

验收矩阵见 [Provider 验收](verification.md#provider-扩展)。先以模拟平台和测试插件验证完整合同，覆盖 POST 查询、三步上传、异常响应、双账号隔离、崩溃恢复、更新与下载失败。已有回归入口为 `test/shared/services/plugins/`、`test/shared/services/ai/video/reference_storage_service_test.dart` 和 `test/shared/services/video_task_recovery_test.dart`；用 FVM 串行执行受影响用例，真实 fjs 用例按验收文档设置动态库。

通用合同通过只代表插件接口可用，不代表任何具体平台插件可用；平台插件的真实验收由插件自身负责。文档、示例和测试中不放真实凭据。

聊天实施时回归覆盖现有 `test/shared/agent/` 和客户端测试，图片回归覆盖 `test/shared/services/ai/atlascloud_image_test.dart`、`image_url_response_test.dart`、`image_reference_compression_test.dart` 及 `test/shared/production/image_generation_test.dart`；实施时选实际受影响的文件，以 FVM 串行运行。本轮本地回归与未完成验收见 [Provider 验证记录](verification.md#本轮本地验证记录2026-11-13)。
