# 业务协议与执行语义

> 返回[方案总览](README.md)。任务状态只在总览的[实施任务](README.md#实施任务)维护。

业务消息用[线协议](wire-protocol.md)定义的 Protobuf 生成。下表的点分方法名（如 `session.send`）是语义名称，线上各自对应一组类型化的请求、响应和事件消息，不按字符串方法名分发 JSON。

本协议对应 [T0 的来源无关业务契约](application-decoupling.md)，只开放其中一部分，不直接暴露 Provider、DAO 或全部本机命令。会话命令入口和运行状态在 T0 就已脱离页面；远程阶段在其上增加设备授权、命令去重与租约、传输映射和快照同步。本机契约里有某个编辑方法，不代表它会进入远程白名单。

## 地址、请求与能力

远程对象用 `deviceId + workId + resourceKind + resourceId` 定位，会话用 `deviceId + workId + sessionId` 定位。访问端不能提交本机路径来访问文件；Host 把业务标识解析为本地路径，并再次核对对象归属和配对权限。

一条业务请求包含：

- `requestId`，以及一个类型化的请求 `oneof`（Protobuf 的多选一字段，每个方法对应其中一个 case，参数由该 case 的具体 message 定义）；
- 写操作另带 `commandId`（命令唯一 ID）、`hostEpoch`（被访问端本次进程的代次，进程每次启动都会变）和 `commandLeaseId`（命令租约 ID，见下文）。

响应带同一个请求 ID，以及类型化结果或 `code/message/retryable` 错误。事件带 `subscriptionId`、`generation`（订阅代次，每次重新订阅都会递增）、`sequence`（同一代次内的帧序号）和内容版本。二进制资源另带流 ID、资源版本、偏移和长度。

Protobuf 生成的类型只在远程模块内部使用。业务快照可以包含 Drift 数据类，由各模块的[编解码器](application-decoupling.md#远程在哪里转换)在 Host 编码、在 Client 解码回同一类型，编码时按字段白名单取值。Flutter Widget、Provider、Completer、文件句柄、审批回调等运行态对象都不进入协议；网络上也没有任意 SQL、反射调用或原始 Service 方法。

| 方法组 | v1 方法与关键参数 | 结果与权限范围 |
| --- | --- | --- |
| 握手后初始化 | `host.describe` | 返回设备信息、`hostEpoch`、能力、限制和命令租约，不返回密钥 |
| 设备级读取 | `model.list`、`agent.list` | 被访问端已配置且可用的模型（供应商标识、模型 ID、展示名、推理强度选项）和 Agent（`mode`、`agentSlug`、展示名），只读；不含密钥、端点或供应商配置 |
| 命令租约 | `lease.renew(hostEpoch, commandLeaseId)` | 在同一 `hostEpoch` 内换发新租约，返回新 ID 与截止时间。旧租约下未确认的命令仍按原租约核对。`hostEpoch` 已变化时返回 `host_restarted` |
| 作品 | `work.list(cursor, limit)`、`work.get(workId)` | 展示投影，按需分页；活动列表不含软删除数据 |
| 内容 | `resource.list/get/watch(workId, kind, id, cursor)` | 类型限定为章节、人物、设定、纲要、节拍、场次、地图、关系、进展、画布、制片、剪辑、导演视图及媒体元数据；没有通用的 `resource.write` |
| 会话读取 | `session.list/get/watch(workId, sessionId, cursor)` | 历史、活动状态、共享待发送位置、待审批和提问的快照与增量 |
| 会话控制 | `session.create(workId, mode, agentSlug?, model?, reasoningEffort?)`、`session.send`、`session.cancel`、`session.queue.clear` | 都经过会话命令入口。模型与 Agent 只能从 `model.list`、`agent.list` 的结果中选，不填时沿用被访问端本机新建会话的默认值。发送时固定上下文，不接受新的供应商秘密 |
| 人工决策 | `approval.resolve(sessionId, approvalId, decision, scope)`、`question.answer(sessionId, runId, instanceId, callId, answers)` | 重新读取当前请求，核对身份、可选项、权限范围和截止时间 |
| 命令核对 | `command.get(commandId, hostEpoch, commandLeaseId)` | 返回命令状态：`received`、`rejected`、`running`、`finished`、`not_received`（可证明未接收）或 `outcome_unknown`（结果不确定） |
| 插件展示 | `plugin.page.list/open/watch/event/close`、`plugin.card.get` | 页面实例绑定设备、页面 ID 和 generation。事件带目标节点和经过校验的输入，只在只读的 Host 上下文中处理。卡片只返回 A2UI 模板与结果 |
| 资源与媒体 | `media.open(resourceRef)`、`media.read(handle, version, offset, length)`、`media.close(handle)` | 图片、音频、视频和其他文件共用。返回 MIME、尺寸、总长度和绑定版本的只读句柄，支持从任意偏移读取，也可中止 |
| 输入附件 | `input.open`、`input.write`、`input.commit`、`input.cancel` | 暂存聊天输入附件，返回会话可引用的附件 ID；不能写入任意路径 |
| 订阅管理 | `subscription.close(subscriptionId)` | 离开对应区域时立即释放服务端订阅和客户端镜像 |

每类内容投影的字段白名单由对应业务模块定义。图片、音频、视频以及插件模板里的资源链接，一律转换为远程资源引用。含秘密的配置、原始环境变量和凭据不进入通用投影；业务工具结果照旧按既有规则返回诊断信息。

错误码至少包括 `unauthorized`、`peer_revoked`、`identity_changed`、`protocol_incompatible`、`capability_missing`、`host_offline`、`queue_full`、`context_changed`、`already_resolved`、`question_expired`、`resource_changed`、`lease_expired`、`host_restarted`、`outcome_unknown` 和 `limit_exceeded`。界面把错误码转成本地化说明，内部保留诊断。错误标记为可重试，并不意味着写命令可以重放。

## 命令确认、去重与单槽队列

会话控制统一由应用级的 `SessionCommandOrchestrator` 串行处理并给出接收结果。桌面、手机的本机入口和远程入口都走它；UI store 里的队列只是镜像，待发送位置以被访问端会话运行态里的那一份为准。

处理一条命令的步骤：

1. 校验设备授权、`hostEpoch`、命令租约、上下文和静态参数。
2. 按 `(peerDeviceId, commandId)` 查内存中的回执：同一 ID、参数摘要相同，返回原结果；同一 ID、参数不同，拒绝。
3. 在会话的串行接收区里判定 `started`、`queued`、`queue_full` 或 `rejected`，先记下回执，再交给正常的交互式运行器。
4. 只对真正接收的指令回复确认。`started` 只表示执行链已接收，不表示模型或工具已经成功。
5. 确认之前连接断了，访问端先用原 ID 查询这条命令，不生成新 ID 重发。只有原命令明确未接收、租约也还有效时，才用原 ID 重试。

被访问端进程每次启动都生成新的 `hostEpoch`。命令租约由 Host 签发，默认 10 分钟，规定了这段时间内可以接收哪些新命令；租约到期后不再接收新命令，但已在执行的命令不受影响。访问端在租约剩余不足一半时调用 `lease.renew` 换发新租约，之后的新命令用新租约。续期不改变未确认旧命令的身份；单纯查询回执不需要有效租约。

回执只存在 Host 进程内存里，用来应对断线重试：保留到命令租约到期后 5 分钟。容量有上限，满了就拒收新命令，而不是淘汰租约内的记录。查询时：

- 同一 `hostEpoch`、租约仍有效、查不到回执：返回 `not_received`，访问端可以用原 ID 重试；
- 其他查不到的情况：返回 `outcome_unknown`，因为内存里没有记录并不能证明从未接收。

进程重启后不恢复旧租约和回执，也不重放写入。访问端发现 `hostEpoch` 变了，就把未确认的命令显示为“结果不确定，请查看会话”，并重新获取会话快照供用户核对。这套机制保证同一进程代次内去重、重启后不自动重放，但不保证全链路严格只执行一次。

队列满时，输入留在发送端的输入框里。`session.cancel` 和 `session.queue.clear` 都会原子地清空普通待发送位置，并在结果和事件中带回被移除输入的 `inputId`、`originDeviceId` 和原文。只有原输入设备把原文恢复到输入框，其他端只显示“队列已取消”。这项恢复由服务生命周期的 Host 负责，不依赖可能已经关闭的页面回调。

发送端收到 `started` 或 `queued` 后清空输入框；收到 `queue_full`、`rejected`，或在确认前断线，则保留原文。结果为 `outcome_unknown` 时也保留原文，并提示用户先查看会话，再决定是否重发。未发送的内容只在内存里，不持久化。

停止操作先返回 `cancelling`，执行链真正结束后再发布终态；已经写入文件、数据库或发给供应商的操作不会撤回。

## 不依赖页面的交互式执行

新增服务生命周期的 `ChatHost` 与 `ChatComposerStore` 适配，复用 `ChatSessionController` 和正常的 `ChatTurnRunner`。活动会话靠现有的 retain/keepAlive 机制存活，关闭聊天页、切换作品或断开远程订阅都不会销毁执行体。只是暂停显示时，不应把状态设为“执行宿主已销毁”。

`send()` 的核心接收逻辑要返回类型化结果，本机调用方也要处理拒收。远程层不能先检查队列再调用 `send()`，因为两端可能同时通过检查。模型无效、上下文失效、附件准备失败都要给出明确的拒收结果。

远程发送和本机发送使用相同的模型、规则、技能和工具权限。手机不另建一个 Agent，也不把输入先发给远程助手再转发。IM 助手仍沿用原来的独立会话模型。

## 审批与 AskUser

工具审批由被访问端的 `AiToolApprovalController` 持有。手机只提交审批 ID、决策和允许保存的规则范围；Host 从 broker 取出当前的请求对象执行，不采用客户端重新构造的工具参数。两端同时处理时只有一次生效，后到的一端收到“已处理”并刷新。

工具审批和 Agent 提问（AskUser）是两回事。现有 `PendingAskUser` 在 10 分钟时提醒、30 分钟超时，这个规则不变，手机断线也不会暂停计时。远程回答要核对 `runId + instanceId + callId` 并重新检查时间；已经超时的，展示既有的超时结果，迟到的回答不会被当作新一轮回答。工具审批目前没有这个定时器，但会随会话取消或被访问端退出而失效。

审批期间断线不会触发自动批准。重连后先加载当前的请求快照，断线前在卡片上做的操作不会重放。

## 快照、事件与浏览上下文

内容订阅推送替换快照：Host 转发本机一致查询流的每一帧，首帧就是初始快照，每帧带订阅的 generation 和递增的 sequence。Client 丢弃旧代次、重复或倒序的帧，用新帧整体替换内存中的状态。替换快照不需要快照水位和变化缓冲，原因见[应用架构解耦](application-decoupling.md#为什么内容查询不需要快照水位)。

会话的消息追加、token 流和运行状态是相对于某个基准的增量，需要快照水位（快照所对应的版本号，只有版本更新的事件才会被应用）。会话订阅建立时，Host 先挂上监听并缓冲变化，再读取一致快照并发布它的水位，之后只发送水位之后的事件。出现缺号、缓冲溢出或 Host 代次变化时，重新获取快照。MVP 的断线恢复以完整快照校准为准，不建设持久化的全局事件日志。

Host 把 token 增量合并后再发送：默认每 100 ms 或攒满 8 KiB 发一次，以先到者为准。运行状态变化、审批、提问和回合终态立即发送，发送前先把已缓存的增量发出去，保证顺序。合并能减少 Noise 分片数，以及经 Relay 时的计费消息数；访问端界面仍按自己的节奏批量刷新。

客户端把视图快照放在内存里，业务缓存按设备和对象身份隔离。远程 Provider 不覆盖全局的本地 `appDatabaseProvider`，不同设备上同名的作品或相同 ID 的对象各自独立。刷新时按数据版本只更新受影响的区域，保留本端仍然有效的选中和缩放。

用户消息带着发送时选定的 Work、Season、Episode 等稳定 ID。Host 核对层级归属和对象是否存在；目标已被删除时拒收，让用户重新选择，不会改用电脑当前正在看的对象。只读视图显示的是已保存的数据，电脑上还没保存的表单草稿不会同步到手机。Agent 与本机编辑并发时，沿用既有的写入校验和编辑器外部变更处理，远程功能不承诺自动合并未保存的草稿；验收要覆盖这个场景。
