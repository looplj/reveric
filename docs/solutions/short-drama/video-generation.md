# E1：视频模型接入、参考上传与任务恢复

> 本文定义视频渠道、参考上传、持久任务与恢复合同。实现覆盖及验收状态只在[实施任务](README.md#实施任务) E1-01 至 E1-04 维护；模型与表结构名称按当前源码核对，不把历史版本号当作迁移依据。

[返回方案总览](README.md) · [用户自配 S3](object-storage.md) · [依赖与核验记录](references.md)

## E1 的独立交付边界

Agent 通过 clip generations 资源接入同一任务服务，模型能力从 providers 查询；工具和授权合同见 [Agent 全流程](agent.md)，不新增制片专用 Run 生成命令。

E1 提供调用方使用自定义 Provider 配置提交视频请求的能力，任务及回执落库，由桌面应用自动轮询并下载到本地；退出重启后继续原任务，无需打开作品。统一接口保留模型能力差异；不支持的输入明确拒绝，未知提交状态不得自动重提。三类模型分别验证，不能用一个 adapter 成功代替其余模型。

E1 使用 AppDatabase 中的统一 GenerationTasks，视频行以 kind=video 区分，结果登记复用 Assets，输入存类型化 JSON，图片／音频参考按 OSS、渠道上传、Base64 选路，本地视频参考按 OSS、渠道上传选路，已认证 Asset 保留独立引用，不提供独立任务管理页。创建任务必须携带 novel_id、source_type、source_id，但恢复不要求打开作品库或制作页面。调用方校验业务来源，任务层保持独立生命周期；E1 交付按来源查询历史、登记结果资产及失败恢复，B 只消费这些服务能力。

E1 不等待 A 的片段表或 B 的制作页面。通用来源合同由任务层保存，来源对象存在性由实际调用方校验；服务集成验收使用现有作品与画布节点作为真实来源，片段来源（ProductionClips 行）由 A 接入后补充业务验证，不提供无来源或伪造来源的生产调用。

## E1：单表任务合同

E1 复用统一 GenerationTasks 与 Assets，不重复执行旧图片表扩展；复用 AiProviders 和默认空列表的 videoModels；不建独立的输入表、上传记录表或上传配置表；渠道素材扩展现有 ProviderAssets，以 kind 区分上传和认证。以下字段为调整后的单表合同，包含 E1 必须完成的来源与结果指针，数据库仍只使用普通列、索引和 Drift 主键。

| 字段 | 类型/空值 | 含义 |
|---|---|---|
| kind | GenerationKind 枚举 | image/video/audio；本文件只定义 video 分支 |
| id | 字符串主键 | 本地任务身份，同一次操作复用同一个 ID；明确重新生成才创建新 ID |
| novel_id / source_type / source_id | 全部必填 | 所属作品、来源类型和来源对象身份；片段与视频节点同属 ProductionClips 一种来源，source_id 为该行 ID；片段选用视频节点的结果时不改写该结果的任务来源；不固定为 CanvasNode |
| result_asset_id | 可空资产 ID | 成功视频登记为 Assets 后写入；失败无结果，历次重做各有独立任务与资产 |
| providerId / providerType / modelId | 非空字符串/枚举 | 用户配置身份、创建时的供应商类型与具体模型；providerType 选择响应解析器，providerId 读取凭据 |
| providerTaskId | 可空字符串 | 上游受理后返回的任务 ID |
| pollingUrl | 可空字符串 | adapter 用当时的服务地址与上游 ID 拼出的完整查询 URL，与 providerTaskId 同次落库；不是结果下载地址 |
| status | 非空枚举 | 任务执行状态；按下文“自定义渠道持久任务与恢复”状态表更新 |
| cancel_requested_at | 可空时间，计划新增 | 持久化显式取消意图；未提交则停止，已接受则继续必要对账但不自动采用迟到结果，不替代上游状态 |
| requestJson | GenerationRequestConverter | 视频分支为 `{version:1, kind:video, request:VideoRequest, inputs:VideoInput[]}`，原稿、最终请求和本地输入在同一类型化快照中 |
| nextPollAt | 可空时间 | 下次查询时间；完成或等待人工处理时为空 |
| errorCode / errorMessage | 可空字符串 | 最近可操作错误，消息去除凭据和签名 URL |
| localFilePath | 可空字符串 | 完整结果相对应用数据根的路径；视频内容在磁盘，不在数据库 |
| submittedAt / completedAt | 可空时间 | 上游受理与本地输出登记完成时间；另沿用 createdAt/updatedAt/deletedAt |

requestJson 使用 GenerationRequestConverter 转成明确 Dart 值对象，读取时校验 version 与 kind；inputs 是视频请求快照内部成员，不是独立数据库列。快照承载单次请求，来源关联另用 novelId/sourceType/sourceId 列。每次任务整体读取输入，目前没有跨任务反查某张参考图的要求，因此不拆子表。

轮询失败计数仅在调度器内存中维护，重启后重置；nextPollAt 仍保留以尊重已收到的限流等待。文件大小需要时读取磁盘。完成判定使用完整下载、可用的 HTTP 长度校验、媒体探测及同卷原子改名；恢复时不计算或比较输出 SHA，不用 outputHash 判断文件能否登记。最终文件可读且探测通过就补登记；不可用时查询原任务并重新下载已有结果，不重新生成。

现有输出相关列包括 outputUrl、localFilePath、outputHash、resultAssetId；恢复合同依赖路径、文件可用性与资产登记状态，不依赖 outputHash。资产去重所需的 sha256 由资产登记流程维护，与任务恢复的内容比对分开。completedAt 在资产登记成功的事务中写入。来源、kind 和 requestJson 创建后不可改。本次仅调整方案，不修改既有数据库列。

## 媒体保存与跨库关系

Agent 操作的 background、run_id、查询／等待／取消见 [工具实施合同](agent-tools.md#后台执行与取消)。本地运行取消与上游任务状态分开；cancel_requested_at 在重启后仍阻止自动采用，已有资产和已提交采用不回滚。不能把停止等待说成供应商取消。

E1 的 GenerationTasks 在 AppDatabase；输入 JSON 与任务在同一行，输入文件和结果保存在应用私有持久目录 `video/tasks/{taskId}/`，路径相对应用数据根，不放在可能被系统清理的 temporary 目录。输入固定为任务自有副本，生成结果始终保存在本地。

结果登记复用 Assets 与类型化 VideoAssetContent。文件落盘后由 probeResult 读取实际视频流、宽高与正时长，再通过 GenerationTaskDao.completeResult 在同一应用库事务登记资产、写 resultAssetId/localFilePath 并转 completed，不增加输出哈希比对。资产登记失败保留文件，任务转 action_required；没有“completed 但尚未登记资产”的成功合同。作品内容库中的采用结果随后由 ProductionResultService 应用，失败只补应用。

文件操作按“临时副本→探测格式/校验→原子移动→登记索引”执行；数据库失败保留可识别的恢复记录，不能把有文件无索引报成已完成。下载采用流式与大小限制，不把整段视频 base64 塞进 UI 状态或数据库。

删除节点、片段、集和制作记录默认软删除；已有文件不随之物理删除。运行中的任务继续保存结果到应用任务目录；通过必填通用来源关联片段或视频节点所在的 ProductionClips 行，结果登记为 Assets；登记失败只重试本地保存/登记。作品未打开或已软删除不阻塞结果下载。垃圾清理只能复用经确认的删除范围，不能借本方案增加自动删除用户原始素材的行为。

应用备份需包含 AppDatabase、任务输入/结果文件；作品备份需包含内容库、被引用的 Assets 记录及所有文件。恢复检查备份读取／解压结果、引用路径和缺件，保留备份格式已有的完整性检查，不逐个媒体复算或比较 SHA；该规则同时覆盖任务输入、任务输出与 Assets 文件。Assets.sha256 等去重数据随记录保留，但不作为备份能否恢复的条件。同步 `backup_service.dart` 与恢复路径，移除其对应媒体内容比对。旧 `reveric.canvas` v1 导出保持原合同，不能用它导出制作画布却静默漏掉视频。

复用 `generation_tasks_by_novel_id_source_type_source_id_deleted_at`（novel_id、source_type、source_id、deleted_at）及 `generation_tasks_by_kind_status_next_poll_at`（kind、status、next_poll_at）索引，不增加旧 video_tasks 索引。来源字段、索引、结果资产登记及失败恢复必须在 E1 一起验收；不能只完成协议调用就标记 E1 完成。

## 从编辑引用到模型输入

片段和视频节点使用独立的 `<ref file_path="…" label="…" />` 或 `<ref clip_id="…" label="…" />` 标签表达资源引用，完整合同见 [提示词引用](production.md#提示词内的资源引用)。E1 协议 client 不读取作品或执行 Read；B 的请求编译入口先解析、校验引用与输入边，把视频节点来源解析为其当前采用的文件（没有采用结果或形成环时拒绝提交），再按有序文件/用途映射替换标签，并冻结请求与文件副本。

各 adapter 只处理所选模型真正支持的引用形式和媒体槽。不能直接透传内部 `<ref>` 标签或执行提示词中的工具指令，不能把资源名字当作真实文件；没有可验证的引用支持时明确拒绝对应输入，而不是静默剥离。资源重命名不改变身份，输入重排重新生成本次映射；来源视频节点之后换了采用结果只影响下一次生成，已提交任务始终使用原快照。

requestJson 的 request/inputs 中增加的原稿和映射属于不可变请求证据，不承担业务关联查询；当前输入真源仍为 CanvasEdges，任务来源仍为必填列。结构变动按实施时的实际发布基线迁移，不能由历史文档判断未发布。

## 选定模型与渠道合同

以下均通过用户自定义视频渠道调用，本方案不提供内置视频模型。未配置时引导用户添加服务与模型；桌面复用现有 Provider 配置面板及校验。

| 项目 | Seedance 2.5 | MiniMax H3 |
|---|---|---|
| 协议与模型 ID | `ark_video`；`doubao-seedance-2-5-260628` | `minimax_video_v2`；`MiniMax-H3` |
| 提交 | `POST /api/v3/contents/generations/tasks` | `POST /v2/video_generation` |
| 查询 | `GET /api/v3/contents/generations/tasks/{id}` | `GET /v2/query/video_generation/{task_id}` |
| 结果字段 | `content.video_url` | `task.content.url` |
| 本方案生成规格 | 480p/720p/1080p，4 至 30 整数秒；首帧、首尾帧、普通全模态参考 | 768P/2K，4 至 15 整数秒；首帧、首尾帧、普通参考 |
| 参考数量校验 | 图≤30、视频≤10、音频≤10，总数≤50 | 图≤9、视频≤3、音频≤3，总数≤12 |
| 默认 | 720p、5 秒、参考生成模式 | 768P、5 秒、参考生成模式 |

本方案明确使用普通参考生成，不自动触发 Seedance 编辑/延长或 Draft 二段生成，也不自动调用 H3 Context-IR/Regenerate；这些会改变调用次数、时长合同和费用。前者设置 `omni_reference_task_type=reference`；首帧/首尾帧走各自模式，不能与普通参考角色混用。画幅根据模型模式验证：纯文本明确指定，首帧模式按输入自适应，生成结果记录实际探测值；成片画幅适配由 X/C 完成，不改写供应商返回规格。按用户明确选择传参，不把请求规格写成供应商一定返回的文件尺寸。

H3 的视频参考每段 2 至 15 秒、总计≤15 秒，音频同样检查总时长；请求提示词最多 7000 字符。H3 普通生成没有与 Seedance `generate_audio` 对等的开关，不能编造同名参数；本方案预览保留其原声，需要静音的交付由 [多轨剪辑 C](editing.md)处理，不伪造供应商生成参数。Seedance 参考图宽高为 300 至 6000、宽高比 0.4 至 2.5；参考视频每段 2 至 30 秒、24 至 60 fps，音频每段 2 至 30 秒。应用把参考视频总长和音频总长分别限制为 30 秒，界面标明这是本产品提交预算。应用单文件上限为图片 30 MB、视频 50 MB、音频 15 MB，供应商更严格时按供应商要求，超限素材明确拒绝并提示先用外部工具压缩/裁切。Seedance 2.5 含真人人脸素材需遵循供应商素材路径；被拒绝后显示准确原因和替换入口，不能宣称任意角色照片都能直接使用。

来源：[Seedance 2.5 模型说明](https://docs.volcengine.com/docs/ark/seedance-2-5)、[创建任务参数](https://docs.volcengine.com/docs/ark/create-video-generation-task-api?lang=zh)、[H3 生成指南](https://platform.minimax.io/docs/guides/video-generation)、[H3 创建任务](https://platform.minimax.io/docs/api-reference/video-generation-v2-create)、[H3 查询任务](https://platform.minimax.io/docs/api-reference/video-generation-v2-query)。核对日期为 2026-10-05，合同测试保存本次固定样例；上游新增能力不会自动扩大现有请求。

Wan 接入仅覆盖 **3.0**，具体模型为 `wan3.0-video` 与 `wan3.0-video-prime`，不实现 2.x 适配。使用用户填写的同地域 workspace Endpoint 与 API Key；POST `/api/v1/services/aigc/video-generation/video-synthesis`，请求带 `X-DashScope-Async: enable`，GET `/api/v1/tasks/{task_id}` 查询。输入使用 `input.prompt` 与有序 `input.media[{type,url}]`，结果读取 `output.task_status` 与 `output.video_url`。

E1 覆盖文生、首帧、首尾帧和图片/视频/音频参考四种模式；不开放文档、网页、编辑或延长的独立模式。应用默认 720P、5 秒、明确画幅，默认 audio=true、prompt_extend=true，均作为明确参数传入；不使用智能时长。模型支持 480P/720P/1080P、2 至 30 整数秒；有参考视频时输入总时长加输出时长不得超过 30 秒。参考最多 10 图、5 视频、5 音频，视频和音频总时长各不超过 15 秒，首尾帧与 reference 类型互斥。Wan 图片上限 20MB，视频继续沿用本产品 50MB 预算，音频 15MB。超过限制提交前拒绝，不截断提示词或丢弃参考。

创建返回 `output.task_id`，查询为 `PENDING/RUNNING/SUCCEEDED/FAILED/CANCELED/UNKNOWN`；只有 SUCCEEDED 且有可下载地址才进入本地 saving。查询和结果地址有 24 小时窗口；UNKNOWN 保留为待确认/过期判断，不自动重生。核对日期 2026-10-07，以上依据 [Wan 3.0 官方 API](https://help.aliyun.com/zh/model-studio/wan3-video-generation-api-reference) 与 [使用指南](https://help.aliyun.com/zh/model-studio/wan3-video-generation-guide)；标准版与 prime 各有独立合同样例，不因同属 3.0 跳过校验。

自定义渠道新增协议选项 `ark_video`、`minimax_video_v2`、`wan_video`，复用现有 Provider 的 baseUrl、密钥和模型选择。Ark 默认 `https://ark.cn-beijing.volces.com/api/v3`；MiniMax 国内默认 `https://api.minimax.cn`，国际为 `https://api.minimax.io`，账户与密钥不混用；按配置的地址发送，不遇到失败就自动切区。Dart adapter 直接调用用户配置的上游；本方案不实现 Reveric 视频生成 adapter。客户端模型密钥沿现有 AiProviders 配置读取，不上传网关、不写素材导出或任务快照；全量应用备份继续遵循原有策略。文本/图片旧渠道行为保持原契约。

## E1 参考准备：素材复用与上传

参考准备由共享 `ReferenceStorageService` 提供。目标合同见 [参考素材上传与 Seedance Asset 认证](reference-upload.md)，OSS 与部分渠道上传已有实现；本次统一 OSS 优先级和图片／音频 Base64 路径实现与验收记录见 E1-04。

已有当前渠道可用的认证 Asset 且模型支持时直接引用。仍需准备的本地图片／音频按 OSS、渠道上传、Base64 选路：已配置有效 OSS 就走 OSS，不优先复用渠道缓存；只有 OSS 未配置时才选择渠道上传，并在该路径内复用有效记录。无渠道上传能力时，图片／音频直接使用 Base64，不再检查模型的 Base64 能力登记；供应商拒绝时正常报错。

本地视频文件优先使用 OSS；未配置 OSS 时，使用支持视频的渠道上传，并可复用有效上传缓存。两者都不可用才要求配置 OSS，视频不使用 Base64。混合输入在发送任何文件前统一预检，只有存在无可用路径的输入时才阻止整次准备。损坏的 OSS 配置提示修复；已选路径失败直接报错，不自动切换路径，不丢弃参考后改发纯文本生成。

渠道普通上传使用 `uploadProtocol`，Seedance 认证使用独立的 `assetProtocol`，二者可同时存在。协议登记在渠道类型配置中，用户沿用已有凭据，不增加自定义 HTTP 上传端点或协议选择表单。88API 上传是渠道扩展，不由 New API 兼容性自动推断。

参考结果区分 HTTP 来源、渠道文件引用、图片／音频 Base64 和 Asset 引用，模型 client 负责校验与编码。`mediaInfo` 来自本机探测。渠道普通上传和认证统一写入 ProviderAssets，通过 kind 区分；先保存 processing，上传成功后保存结果并设为 active，认证提交后则继续轮询。渠道上传结果只在重新选中该路径后跨任务复用，未完成上传不保存预分配 URL。OSS 保留文件 hash 先查后写。Base64 只在提交时由本地文件构造，不落上传记录、任务快照、日志或诊断导出；发送前校验编码后体积和完整请求体上限。

存储配置与凭据不进入任务快照或日志。模型必须能消费返回的引用，客户端可访问不能代替模型读取验证。已提交任务沿已保存的供应商任务身份恢复，生成结果保存在本地。S3 的具体约定见[对象存储](object-storage.md)。

## 对象存储生命周期

参考对象的生命周期由用户 Bucket 管理，应用不部署定时清理、续期服务或容量管理。对象仍存在时可重新签发读取地址，缺失时重新上传；使用公开访问地址时不产生预签名有效期。

已认证的供应商素材可按相应协议使用 `asset://` 引用，普通 HTTP(S) 参考仍需验证模型可读取。支持情况按具体模型和协议测试记录。

## 自定义渠道持久任务与恢复

本节由 E1 完整交付：协议 client、任务落库、自动轮询、结果保存及应用重启恢复。底层 client 处理单次网络动作，应用级 VideoTaskService 持有任务队列和调度；页面只订阅状态或发起明确操作，页面销毁不停止任务。E1 的作品/来源关联使用任务显式列，调度器不读取画布状态；关联不混入请求 JSON。

视频任务由客户端调度与恢复。任务落在 AppDatabase 的 `GenerationTasks`，先生成本地 id、固定输入副本并计算文件 hash，再将 novel_id/source_type/source_id、providerId/providerType/modelId、类型化 requestJson 一起落库，随后准备云端参考并提交。任务 status 以数据库为真源；提交前条件更新为 submitting，网络请求在事务外执行。取得 providerTaskId 后，adapter 用当时的服务地址拼出 pollingUrl，与任务 ID 在同次写入中持久化；不得先依赖下一次轮询才保存回执。恢复按已保存的 pollingUrl 查询、按 providerType 解析，凭据仍从原 providerId 读取；凭据缺失/失效或账户配置变化时暂停，不改用当前默认渠道。仅修改默认模型不改变已有任务。

| 上游事实 | 客户端状态与动作 |
|---|---|
| 输入已固定、未提交 | prepared / uploading；提交前校验来源并清除旧错误关闭标记，不写独立制作状态。重启可恢复素材准备，收费提交需用户明确继续 |
| 正在提交 | submitting，不并发重复提交 |
| queued / running | running，按原 providerTaskId 轮询，不重新提交 |
| 提交超时且未知上游 ID | submission_unknown，保留原请求，显示“提交结果待确认” |
| succeeded，文件尚未本地保存/校验 | saving，只重新下载保存 |
| 本地文件校验与资产登记均完成 | completed；resultAssetId/localFilePath 与终态同事务写入。内容库随后更新 selectedFilePath 和应用标记；应用失败显示结果待应用并恢复补写 |
| failed / 确认的 cancelled | 对应终态，重做需要新的明确动作 |
| 未知状态、响应缺字段 | reconciliation_required，显示错误并对账，不映射为成功 |
| 凭据失效、配置缺失或本地保存受阻 | action_required，保留原任务与阶段；修复后查询原任务或继续保存 |
| 上游结果过期且本地无完整文件 | expired，明确无法取回；不自动生成替代结果 |

上游未提供幂等或按客户端 ID 查询能力时，丢失提交响应后不能自动重提。按供应商任务记录核对；不支持取消时明确提示并继续取回结果。应用退出后本地轮询停止，重启沿原任务恢复；不承诺服务端代为下载。各供应商的任务与结果有效期分别记录，到期且本地无文件时显示结果过期，不自动收费重生成。

## 各 client 的任务回执与查询地址

| 提供商 | 创建返回的关键字段 | 查询路径 | 查询成功时的状态与视频地址 |
|---|---|---|---|
| Seedance/Ark | id | `/api/v3/contents/generations/tasks/{id}` | status；content.video_url |
| MiniMax H3 | task_id | `/v2/query/video_generation/{task_id}` | task.status；task.content.url |
| Wan 3.0（标准版/prime） | output.task_id、output.task_status | `/api/v1/tasks/{task_id}` | output.task_status；output.video_url |

创建回执主要提供任务 ID，并不直接返回 pollingUrl；由 adapter 使用实际账户区域/baseUrl 拼完整 URL 后落库。仅实现 Wan 3.0 的上述合同，不实现旧版 Wan 的兼容分支。providerType 是创建时的供应商类型，用于选择解析规则；无需再并列持久化 protocol。[Ark 流程](https://docs.volcengine.com/docs/ark/video-generation-tutorial?lang=zh&redirect=1)、[H3 创建](https://platform.minimax.io/docs/api-reference/video-generation-v2-create)与[查询](https://platform.minimax.io/docs/api-reference/video-generation-v2-query)、[Wan 3.0 接口](https://help.aliyun.com/zh/model-studio/wan3-video-generation-api-reference)。

## E1 轮询与启动恢复

应用启动并打开 AppDatabase、加载 Provider 配置后，只启动一个应用级调度器；进入前台或网络恢复时唤醒同一调度器。任务页打开、画布切换和多个状态订阅不会各自启动轮询。状态更新使用带预期状态的条件写入；同任务最多一个在途网络动作，全局最多两个查询/下载动作，新生成提交仍默认串行。

每次查询结束并落库后再安排下一次，不使用会重叠的固定 Timer。正常前台间隔 10 秒，后台仍被系统允许运行时 60 秒；网络/暂时上游错误按 10、20、40、60 秒退避并加入少量抖动，限流遵守更长的 Retry-After。nextPollAt 和最近错误落库；连续失败次数仅在内存计数，成功查询或应用重启后重置；单次查询设置超时，离线暂停网络操作，恢复联网后查询原任务。平台挂起/杀进程期间不保证后台执行。

启动恢复逐条按持久状态处理：

| 落库状态 | 重启动作 |
|---|---|
| prepared / uploading | 校验输入文件，按 hash 检查对象并恢复准备；不自动执行尚未提交的收费生成 |
| submitting 且没有 providerTaskId | 转 submission_unknown；只有上游明确支持幂等或按已提交的客户端任务标识查询时才能自动对账，否则等待用户核对，不重发生成 |
| 有 providerTaskId 的 submitting / running | 查询原任务；上游仍执行则继续轮询，已成功则转 saving |
| saving | 检查任务目录最终文件；最终文件已原子落盘则补登记，否则查询原任务取得可用结果地址并重新下载 |
| action_required / reconciliation_required / submission_unknown | 保留明确原因及原身份；有确定可查询 ID 时仅恢复查询，需要人工修复时保持暂停 |
| completed / failed / cancelled / expired | 不重新生成；completed 文件缺失需显式恢复下载，无法取回时标记缺件 |

下载先流式写入任务目录的 result.part，确认响应成功、流正常结束，并在服务给出 Content-Length 时核对长度；随后同卷原子改名为 result.mp4，写 localFilePath，并在媒体探测及资产登记事务成功后写 completed。最终文件名只用于完整下载成功的文件；若进程在“已改名、DB 未完成”之间退出，重启检查最终文件可用性后补登记，不与历史 outputHash 比对。E1 下载中断时从头重下同一结果，不增加断点续传记录或独立结果字节数列；临时 URL 过期时通过 pollingUrl 查询原任务获取仍可用的地址，上游已过期则明确失败，不重新生成。外部导出是本地完成后的单独操作，不让外部目录权限决定任务能否保存成果。

本方案不新增独立生成任务管理页、全局任务列表页或任务详情路由。E1 提供 create/submit/watchTask/refresh/retryDownload/resumeAfterConfigurationFixed 等服务能力，桌面应用启动时恢复调度；页面销毁不停止调度。B 按 novel_id/source_type/source_id 展示片段或视频节点的历次任务，状态由原任务提供；不另存节点任务关系。E1 通过隔离集成测试调用服务创建任务、关闭并重新启动容器来验收，不为测试另建产品页面。当前只修改桌面现有 Provider 设置，停止本地等待、上游取消、重新生成保持不同操作。

## 费用归属与提交限制

本方案视频费用由用户直接向所配置供应商支付。本方案不做成本预估，不接入或维护供应商价格表，不新增费率版本、币种和计价快照字段，也不提供预计费用或费用上限控制界面；不建设视频额度冻结、报价结算或管理端视频价格系统。实际收费由供应商账户和账单确认。

B 的批次最多 20 个不同节点、默认串行，每个节点只提交一次生成，不提供同一片段或视频节点的多候选批量生成。结果不满意时须另行显式重做，失败恢复不自动重提。人工提交审阅请求数量、生成秒数与参考输入；Agent 按 [分层权限](agent.md#通用权限规则与审批)执行，ask 展示冻结请求并等待批准，allow 在用户任务范围内连续执行，deny 不提交。用户可设置本地请求次数/生成秒数上限，不按金额估算或拦截。关闭客户端不能撤销已被供应商接受的收费任务。轮询、下载重试、再次播放与已有结果采用不创建新的生成任务。

## 参考素材上传与生成结果下载

只上传本次明确选中的参考文件，提示词发送给用户配置的视频模型，并在首次使用时明确说明参考会上传。素材按 [参考素材上传与 Seedance Asset 认证](reference-upload.md)准备；没有可用路径或上传失败时阻止提交，纯文本且无参考的任务仍可直接调用。渠道 API Key 仅发送到对应 API，不转发到返回的媒体上传地址。S3 配置见 [F：用户自配参考存储](object-storage.md)。

生成视频在所有阶段都直接从供应商下载到本地；E1 存入应用私有任务目录，校验下载完整性并登记后标记完成。E1 把结果登记为统一资产，其登记状态不改变任务已完整下载的事实，但登记成功前不显示可采用结果。下载失败恢复原任务，不上传生成结果到用户 S3，不建设 Reveric 的云端结果副本、结果归档或云端交付。

参考副本生命周期由用户 Bucket 或渠道托管服务决定，应用不部署清理、续期或刷新修改时间的服务。上传同时遵守接口和模型的文件限制。88API 素材的保存期限与上传凭证期限分别处理，详见[参考素材上传与 Seedance Asset 认证：88API 上传合同](reference-upload.md#88api-上传合同)。本地输入与生成结果不受远端生命周期规则影响。

## 实施范围

### E1 完整交付范围：视频 client、来源、结果资产与恢复

- 完成共享视频请求/结果类型与 Seedance、H3、Wan 3.0 adapter；复用自定义 Provider 地址、密钥，新增 videoModels 配置字段。只扩展桌面现有 Provider 设置；不增加生成任务管理页。
- client 负责单次网络动作；VideoTaskService 与 DAO 负责 AppDatabase 单表任务、类型化输入 JSON、轮询及启动恢复，ReferenceStorageService 统一准备目标可消费的参考来源。输入和结果存应用受控目录；任务创建必须携带作品与通用来源，协议 client 与恢复不依赖打开作品库或画布。
- 参考文件统一计算 SHA-256；OSS 路径按对象 key 检查远端存在性，命中时不重传，渠道上传按独立协议执行。E1 必须补齐 GenerationTasks 的必填来源与结果资产列、来源索引及资产登记恢复，不新增关联表或独立上传记录表；扩展 ProviderAssets 并执行正式迁移，见 E1-04。
- 用固定媒体与模拟 HTTP 覆盖各协议的成功、鉴权失败、参数拒绝、提交不确定、查询和下载中断。真实调用使用用户自配账户且显式开启；通过服务集成测试独立提交、重启恢复并下载结果；不新增独立任务页或临时制作页面。

以下为 E1 的文件职责清单；生成文件由工具产生，不手改。目录承担命名空间，Provider 设置复用现有桌面表单。

### E1 共享视频 client 与任务层

- `lib/shared/services/ai/video/{client,ark,minimax,wan,reference_storage_service}.dart`：统一调用入口与各协议适配；单次请求接受注入配置，方便模拟上游测试。
- `lib/shared/models/video/{request,task_result,capabilities}.dart`：请求、输入值对象、回执、能力和统一错误；不引用作品/画布类型。专用 JSON converter 按项目规则放入 type_converters.dart。
- `lib/shared/services/ai/video/task_service.dart`：VideoTaskService 为应用级单例，依赖 AppDatabase DAO、client 工厂与文件访问能力；实现 create/submit/query/resume/save，并在应用生命周期中启动/停止唯一调度器。
- `lib/shared/database/daos/generation_task_dao.dart` 与 AppDatabase：复用 GenerationTasks；按 kind/status/nextPollAt 恢复任务。以 novel_id/source_type/source_id 查询来源历史并防止同来源重复提交；同一本地任务复用主键 id，以预期 status 条件更新防止重复提交，不增加重复的 operationId 列，也不假称本地主键能保证供应商幂等。
- `lib/shared/providers/video_tasks.dart`：按任务 ID 投影持久状态；应用级调度生命周期独立于页面订阅。不提供独立任务列表或详情页面；调用方按任务 ID 订阅，E1 通过服务集成测试验收。
- 自定义 Provider 增加 videoModels；OSS 沿用全局设置，渠道类型增加代码级 uploadProtocol／assetProtocol，不新增 Provider 持久化上传配置字段或上传配置表。密钥不进入任务 JSON 或日志。
- ReferenceStorageService 为共享单例，统一 hash、用途预检和路径选择；所有模型 client 复用。OSS 适配器负责对象检查与 URL 签发，渠道上传适配器负责文件上传和引用返回。

### `lib/shared/models/ai_provider.dart`、`lib/shared/models/models_catalog.dart`、`lib/shared/widgets/settings/provider_config_panel.dart`

- 新增 video 模型种类及 MiniMax/Wan 3.0 视频协议适配，已有 Doubao 接 Ark 视频协议；只允许选择用户已配置的自定义视频模型，目录中的配置模板不提供可直接调用的内置模型。
- 自定义协议的 baseUrl/密钥复用现有 Provider 持久化；当前模型密钥位于 AiProviders.apiKey，不把它描述成已经由系统安全存储托管。自配 S3 凭据由对象存储设置独立维护，不写入 Provider 或任务 JSON。只接桌面现有设置入口，共享配置模型不新增移动端功能。

## 结构调整与回滚

使用现有 GenerationTasks、Assets、GenerationRequestConverter、GenerationTaskDao 和已提交迁移。不得根据旧方案的 schema 数字或未发布判断重建旧 VideoTasks，也不重新增加已经存在的来源/结果字段。

需要新字段时核对实际发布记录、发布标签对应定义和受支持旧库，再按仓库规则决定正式升级或开发期合并；同时检查历史表重建、新装库、TypeConverter 和 Typed DAO 回读。既有图片、音频、视频任务及来源身份全部保留，不回填假身份或增加运行时兼容层。本次只修正文档，不改开发库或 Release 库。

回滚停用新入口和新提交，保留已接受任务的查询/下载、结果登记和输入文件，不降级数据库、不删除业务数据、不重提提交不确定的请求。

## E1：视频 client、持久任务与恢复回归验收

- 三类模型各自完成协议合同测试：配置与能力校验、参考输入、提交回执、运行/成功/失败状态、原 task ID 查询和本地下载；不把未验证版本标成支持。
- 鉴权失败、参数拒绝、限流、未知提交结果、响应缺字段和下载中断均有明确结果；查询/下载重试不创建新生成请求。
- 协议 client 可独立测试；持久任务创建必须提供作品与来源，缺任一字段直接拒绝。E1 以既有画布节点验证真实来源，A 接入后补充 ProductionClips 来源（片段与视频节点为同一来源类型）的业务验证；恢复无需打开作品库或制作页面；移动端不新增入口。
- 未配置视频模型时没有内置模型兜底；密钥不写入请求快照或日志。无参考输入时不依赖 S3；输入快照和生成结果写入应用私有持久目录。
- OSS 相同参考再次生成时按 hash 命中不上传，文件内容改变后 key 改变；HEAD 404／403 允许尝试 PUT，其中 403 不证明对象不存在，最终由 PUT 结果决定，其余网络错误抛出；验收口径调整原因见[对象存储上传与读取流程](object-storage.md#上传与读取流程)。对象仍存在时签名到期只刷新地址。渠道上传按 E1-04 验证缓存服从 OSS 优先级、同路径复用、过期重传和 kind 隔离；视频验证 OSS 与渠道上传选路且禁止 Base64；图片／音频 Base64 验证编码后体积限制及不落库。
- 任务在准备参考、提交响应丢失、已有上游 ID、上游成功未下载、下载中断、文件已改名但 DB 未完成各阶段强制退出；重启按 [轮询与启动恢复](#e1-轮询与启动恢复) 处理，已有任务不产生第二次生成。
- 多页面订阅/前后台切换只保留一个调度器，同任务无重叠请求；网络恢复、限流退避、凭据失效、配置更换、磁盘满与结果过期均有可见状态。
- AppDatabase 升级保留原 Provider 配置，videoModels 默认为空；已有任务与输入在未打开作品时可恢复，服务接口可查询、重试下载并返回本地路径；无独立任务页也能完成验收。
- 同来源 T1 成功、T2 失败、T3 重做成功：两份资产与文件保留，失败无 result_asset_id；同来源历史完整且不混入其他来源。资产登记中断可重试，不能重复登记或收费生成；B 另验收自动采用与任务反馈。
- E1 验证输入快照和结果资产不受后续编辑影响。B 的引用编译验收另覆盖正文位置、同名/改名、重复引用、用途与顺序变化、失效引用、缺少输入、视频节点来源无采用结果或成环和模型不支持，并断言最终文本与媒体槽一致。
- 固定媒体与模拟上游测试无费用；真实模型调用另行显式启用并记录结果。E1 独立验收协议、持久化、必填来源及索引、结果资产登记、重启恢复和参考上传复用；B 验收生成结果在画布中的展示、自动采用及任务反馈。
- 参考存储测试覆盖未配置、上传失败、无效 URL、过期 URL 和并发复用；供应商协议分别验证请求与响应。

E1 的最窄验收文件固定为 `test/shared/services/ai/video/`（协议与调度）、`test/shared/database/video_task_migration_test.dart`、`test/shared/services/video_task_recovery_test.dart`、`integration_test/video_generation_service_test.dart`；后者在桌面宿主使用隔离 AppDatabase 和固定媒体，覆盖两次容器启动，不依赖任务页面。参考存储使用 `test/shared/services/ai/video/reference_storage_service_test.dart` 与对象存储测试验收。这些是回归入口，本次文档调整未执行，不据此新增通过记录。

发布前分别验证用户自配 S3 和已接入渠道的参考上传与模型消费；无可用路径时明确提示。回滚停用新提交，保留已有任务查询和本地结果，不删除用户原始文件。
