# 实施落点

> 返回[方案总览](README.md)。任务状态只在总览的[实施任务](README.md#实施任务)维护。

本方案跨访问端、被访问端、两种 Relay 和多个业务视图，涉及 8 个以上文件和多个独立服务。下面列出新增路径；现有文件保持原路径，不为移植功能顺手重组目录。

实施前先完成 [P0 业务切片 PoC](application-decoupling.md#p0业务切片-poc) 与独立的[应用架构解耦](application-decoupling.md)。P0 的保留与丢弃范围，以及 T0 的目标结构、分批方式、画布示例和完成标准都在该文档。本篇只记录远程实现的具体落点：下文涉及从本机代码抽取契约的工作归 T0，后续远程任务直接在这些契约上接入，不另建一套接口或运行态。

## 新增 `lib/shared/services/remote_access/`

- `protocol.dart`：协议版本、静态 DTO、错误与能力；不含 Provider 或数据库类型。
- `identity.dart`、`pairing_orchestrator.dart`：系统密钥、固定信任、邀请与本地确认、撤销。
- `transport.dart`：两条路径共用的 channel 层，负责 `RelayFrame` 分帧、发送窗口、累计 Ack 和有序写入器。
- `lan.dart`、`relay.dart`、`secure_channel.dart`：局域网监听、发现与 PeerOpen 建链，Relay 注册与加入，Noise 握手与加密分片。
- `host.dart`、`client.dart`：Host 方法分发与 Client 请求关联；只做协议到业务契约的转接，不放业务逻辑。
- `descriptors.dart`、`codecs/`：查询、命令和事件的类型化描述注册，以及按业务模块划分的编解码器（如 `codecs/canvas.dart`），负责业务快照与 Protobuf 的双向转换和字段白名单；P0 期间提供 JSON 实现，正式实现换为 Protobuf，接口不变。
- `subscriptions.dart`：Client 订阅表与 Host 订阅分发，按描述通用处理替换快照订阅；会话增量的水位逻辑放在 `session_commands.dart` 侧。业务快照由业务模块维护，远程模块不另造模型。
- `session_commands.dart`：命令回执、租约及共享会话接收编排，调用既有执行链。
- `resources.dart`、`media_proxy.dart`：资源与视频的版本化范围读取、loopback 标准 HTTP 播放适配与缓存释放。
- `input_upload.dart`：输入附件的暂存、块校验、提交与会话归属，复用正常会话文件落盘流程。

## 主库表与 DAO

`lib/shared/database/app_database.dart` 新增 `remote_access_clients`、`remote_access_hosts` 两张表，索引写入 `app_database_indexes.dart`，字段与迁移要求见[本地存储](settings-and-deployment.md#本地存储与升级)。DAO 按现有 `lib/shared/database/daos/` 约定新增，由远程访问 Service 与 Orchestrator 调用，界面不直接访问。

## 新增 `lib/shared/providers/remote_access_providers.dart`

组合依赖、根生命周期、设备状态和远程投影。网络连接的生命周期不绑定到单个聊天页面，也不覆盖全局本地数据库；当前选中的设备与各视图的订阅相互独立。

## `lib/shared/services/ai/chat_session_controller.dart` 与 `lib/shared/providers/ai_providers.dart`

T0 提取原子接收结果，统一单槽队列权威状态，增加服务生命周期的 host/store 适配。T05 接入远程命令身份、租约与回执；本机与远程入口共用 T0 的会话命令入口，保持既有的停止、上下文和模型规则。`ChatTurnRunner` 的正常 AskUser 继续生效。

## `lib/shared/agent/tool_approval.dart` 与 `lib/shared/services/ai/pending_ask_user.dart`

主要复用现有语义。远程分发器通过当前对象查找与实例身份完成决策，必要时补只读投影和结构化结果，不修改工具 description 或自动放宽权限。

## 现有移动视图与共享聊天

`lib/mobile/pages/library_page.dart` 增加设备入口；`novel_editor_page.dart`、`lib/mobile/features/screenplay/editor_page.dart` 承载远程只读工作区；`novel_chat_page.dart` 复用展示并接远程会话命令；`lib/shared/widgets/ai/chat/` 的资源、AskUser 和审批操作通过来源明确的接口分发。入口 shell 只组合 region，新状态不再堆进已有的大 build。

`lib/shared/widgets/plugin_view/` 的渲染接收来自被访问端的页面树；插件 Host 增加受限的远程页面上下文，手机回调不能直接执行本机插件。A2UI 工具卡和 TSX 页面的生命周期不同，分别验证。

## 普通画布、制作、剪辑与导演视图

T0 将 `lib/desktop/features/canvas/widgets/canvas_board.dart` 的展示输入与本机查询分开，保留桌面外壳；T09 新增 `lib/mobile/features/canvas/region.dart` 提供触摸查看。具体前后对照见[画布示例](application-decoupling.md#具体示例画布订阅与节点位置保存)。

`lib/desktop/features/production/board.dart`、`region.dart` 提取数据驱动的查看区域；新增 `lib/mobile/features/production/region.dart`。`lib/desktop/features/editing/region.dart` 的时间线展示与写动作分离；新增 `lib/mobile/features/editing/region.dart`。`lib/shared/widgets/screenplay/director_shell.dart` 增加只读能力开关，由移动制作宿主接入。可复用的业务视图放 `lib/shared/widgets/`，不让移动端直接依赖桌面 page。

## 设置、启动和本地化

`lib/main.dart` 在数据库准备后恢复本机身份和接入服务，退出时停止监听与释放资源；不修改 IM 自动恢复路径。`lib/desktop/widgets/settings/settings_remote_section.dart` 与 `lib/mobile/pages/settings_page.dart` 分开呈现 Remote Access 和 IM Channels。新共享设置区放 `lib/shared/widgets/settings/remote_access_settings_section.dart`，包含已配对设备列表与当前活动连接。桌面端另在窗口内显示活动远程连接的状态标识，点击可查看并断开；具体位置按桌面页头与窗口按钮规则确定。

文案同步修改 `lib/shared/localization/locale_keys.dart`、`assets/translations/en/remote.json`、`assets/translations/zh-CN/remote.json`，通用动作复用 `common.*`。本方案不新增 AI 提示词语言分支。

## Relay、配置和平台

新增 `protocols/remote_access/` 保存唯一 `.proto` 真源、Buf 配置、本地生成器锁定与跨语言夹具。Dart 产物位于 `lib/shared/services/remote_access/generated/`，Go 产物位于 `server/relay/internal/protocol/`，TypeScript 产物位于 `server/cf/workers/relay/src/generated/`。

新增 `server/relay/` 作为独立 Go module，包含 `cmd/relay/`、路由、文件注册表、WebSocket 处理、Dockerfile、Compose 与 Caddyfile；新增 `server/cf/workers/relay/` 保存 Worker、DO、Wrangler 配置。两种实现运行相同的协议场景，代码各自独立。生成、测试、部署命令分别见[线协议](wire-protocol.md)、[自建](self-hosted-relay.md)和 [CF](cloudflare-relay.md)。

`pubspec.yaml` 及锁文件添加[依赖与边界](architecture.md#依赖与边界)所列依赖。

Android 播放：

- `third/video_player/pubspec.yaml` 只为 Android 恢复 `video_player_android` 的平台声明与依赖，iOS、Web 等不恢复；`third/fvp` 继续只注册 Windows、macOS。
- 同步更新 `third/video_player_UPSTREAM.md` 与 `third/fvp_UPSTREAM.md` 中“播放仅由桌面 FVP 提供、不恢复移动端注册”的说明，改为 Android 由 ExoPlayer 实现提供。
- `lib/shared/services/production/runtime.dart` 的 FFmpegKit 初始化保持桌面专用，Android 播放不依赖它。

平台配置检查：`macos/Runner/DebugProfile.entitlements`、`Release.entitlements`、`Info.plist`；`android/app/src/main/AndroidManifest.xml` 与新增的 `res/xml/network_security_config.xml`（只对 `127.0.0.1` 允许明文，供 loopback（本机回环地址）播放适配器使用）；Windows 打包和防火墙行为。任何平台权限修改都同时复核三个目标平台。
