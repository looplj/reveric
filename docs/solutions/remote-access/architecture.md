# 架构与技术选择

> 返回[方案总览](README.md)。任务状态只在总览的[实施任务](README.md#实施任务)维护。

## 组件关系

本篇描述 T0 完成后的远程接入结构。全应用的查询、命令、运行状态和资源契约，以及 Riverpod、业务执行和存储各自的职责，见[应用架构解耦](application-decoupling.md)。本机来源和远程来源通过同一套业务契约进入展示层；Host 直接调用被访问端本机的查询、命令和资源接口。

```text
Android 作品/会话/媒体视图
          |
  业务展示 Provider / 来源无关契约
          |
     RemoteAccessClient
          |
   设备认证 + 加密会话
          |
     Transport 选择
      /          \
局域网 WebSocket   WSS Relay
      \          /       ├─ Cloudflare Worker + Durable Object
       \        /        └─ 自建 Go WebSocket 服务
      RemoteAccessHost
          |
  查询与订阅 / 会话命令 / 资源读取
          |
  现有 Service、Orchestrator、会话 Runtime
          |
     本机数据库、文件、模型供应商
```

两端 App 都用 Dart 实现，局域网服务与连接使用 `dart:io` 的 `HttpServer`、`WebSocket`。CF Relay 使用 TypeScript 与 Durable Objects（DO，Cloudflare 按 ID 定位的有状态单实例对象），自建 Relay 使用 Go。三者共享 Protobuf schema、协议语义与互通夹具，不共享运行时代码：App 生成 Dart 类型，自建 Relay 生成 Go 类型，CF 生成 TypeScript 类型。Protobuf 通过 WebSocket 承载，不引入 gRPC。Relay 是独立服务，不复用诊断服务的业务入口和凭据。

视频与其他资源一样，经端到端加密通道按范围读取：同网直连，跨网经 Relay 转发密文，不使用对象存储。详见[视频](views-and-media.md#视频经加密通道按范围读取)。

应用层协议不感知 Cloudflare。Relay 只识别路由和传输帧，不实现作品 API，不调用模型，也不持有设备解密密钥。两种部署运行同一套契约测试。局域网只是少了一跳中转，身份认证和业务权限校验照常进行。

## 依赖与边界

| 项目 | 方案选择 | 集成要求 |
| --- | --- | --- |
| 加密 | `Noise_IK_25519_ChaChaPoly_SHA256`，使用 `cryptography` 原语 | 配对二维码固定对端公钥<br>对照 Noise 规范和测试向量验证，不自行设计加密算法 |
| 密钥存储 | `flutter_secure_storage` | 核对 Windows、macOS、Android 的实际后端、备份与重装行为 |
| 局域网发现 | `nsd` 的 DNS-SD，服务类型 `_reveric._tcp` | 广播只带设备标识、协议版本与服务端口，不带作品名或凭据 |
| 扫码 | `mobile_scanner`；已有二维码展示组件优先复用 | Android 在使用时请求相机权限，拒绝后可粘贴配对内容 |
| 媒体播放 | 桌面沿用本地 `third/fvp`；Android 新增官方 `video_player_android`（ExoPlayer/Media3），由本地 `third/video_player` 只为 Android 声明该实现 | 原“移动端不带播放器”的依赖约定随远程访问调整<br>桌面不改用公开包版本；Android 不注册 fvp、不打包 FFmpeg<br>验证 loopback（仅本机 `127.0.0.1` 可访问）Range 源与三平台解码 |
| 官方 Relay | Workers、SQLite-backed Durable Objects、WebSocket Hibernation | 使用可休眠连接，不用普通常驻 WebSocket API 代替 |
| 自建 Relay | Go、`coder/websocket`、Docker Compose 与 Caddy | 与 CF 共用 proto3 合同及行为测试，不要求官方账号或 Cloudflare API |
| 多端协议 | proto3、Buf、本地生成器 | 三端由同一份 schema 生成类型，详见[线协议](wire-protocol.md) |

依赖版本以实施时的锁文件为准，本文查询时的包版本不是永久要求。公开资料确认了加密、密钥存储与 NSD 支持目标平台；本项目的插件组合、原生权限和性能仍要按[验收方案](verification.md)验证。

## 展示策略

优先复用已有 Flutter 组件。复杂 UI 用业务投影加真实组件展示，不让 Agent 临时生成 HTML。插件卡沿用 A2UI，只传递可验证的展示模板和数据；手机缺插件时也不安装或执行远端插件代码。未知模板版本显示明确的通用工具结果。

## 风险与处理

| 触发条件 | 影响 | 处理与验收 |
| --- | --- | --- |
| 把 headless 入口当作远程交互入口 | 提问被自动按超时处理 | 复用正常 runner；无人打开聊天页时仍生成可回答的 PendingAskUser |
| 两端同时发送或重连重试 | 队列覆盖、重复生成与付费副作用 | 原子接收、同代次去重、租约截止与未知结果核对 |
| 只替换页面入口，保留本机数据库和路径 | 串设备内容或资源打不开 | 设备命名空间、只读投影、媒体资源引用和来源明确的动作接口 |
| 复用可编辑组件，只隐藏顶层按钮 | 子菜单、快捷键或插件仍可写入 | 组件能力约束与 Host 方法白名单同时生效，执行越权测试 |
| 移动端或被访问端休眠 | 连接失效、状态陈旧 | 回到前台重连并用完整快照校准；明确以被访问端进程在线为前提 |
| 局域网隔离、组播禁用、CF 网络质量差 | 无法直连或媒体缓慢 | 已知地址与所选 Relay；独立自建部署；实网矩阵记录哪些环境可用 |
| 长视频和慢接收方 | 解码或网络缓冲增长、控制操作延迟 | Range、资源版本、有限缓存和背压；测量媒体与控制同时负载时的表现 |
| 云 Relay 被控制 | 路由阻断、流量分析或伪造连接 | 对端固定身份、应用层端到端加密、每次命令复查授权<br>不承诺隐藏通信元数据或防止服务拒绝 |
| 官方 Relay 被当作免费加密隧道 | 流量和 DO 活跃费用上升 | 接受风险，靠按路由用量监控、账户用量通知、封禁名单和可选日配额控制成本，见 [CF 用量监控](cloudflare-relay.md#用量监控与成本控制) |
| 原生插件的平台声明与项目组合不符 | 某平台构建或运行失败 | 以实际 FVM SDK、本地播放器依赖和三平台 Release 验收为准，包的平台标签不能作为放行依据 |

已接受的取舍见总览范围：依赖被访问端在线、无离线作品副本、首版单槽输入、无公网穿透、不承诺锁屏通知。复杂视图的只读移植仍属于完整 MVP，不因工作量大而降级。

## 技术资料与证据边界

- [Noise 官方规范](https://noiseprotocol.org/noise.html)：握手、身份绑定、计数与密钥生命周期的依据。
- [Dart WebSocket](https://api.dart.dev/dart-io/WebSocket-class.html)：App 内客户端和局域网传输的基础。
- [cryptography](https://pub.dev/packages/cryptography)、[flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage)、[nsd](https://pub.dev/packages/nsd)、[mobile_scanner](https://pub.dev/packages/mobile_scanner)：新增依赖的能力与平台资料。扫码只是 Android MVP 的入口，扫码包不支持 Windows 不影响远程协议支持 Windows。

技术资料不能替代实机验证。引入第三方源码或测试向量前，核对具体文件的许可证、版权与修改要求并保留归属。
