# Protobuf 线协议与多端一致性

> 返回[总览](README.md)。业务语义见[业务协议](protocol.md)，部署分别见 [CF DO](cloudflare-relay.md) 与 [Go 自建](self-hosted-relay.md)。本篇为实现合同。

## 选择 Protobuf，通过 WebSocket 承载

采用 proto3，一份 `.proto` 生成 Dart、Go 和 TypeScript 类型；不使用 gRPC、Connect RPC 或 HTTP/2 服务端推送。WebSocket 已满足双向、流式和长连接需求，Protobuf 负责消息形状、二进制编码和演进。

| 方案 | 判断 |
| --- | --- |
| JSON 加三端手写 DTO | 开始简单，但字段、整数、空值、枚举和错误容易漂移；不采用 |
| JSON Schema 加多端生成 | 可以保持结构一致，但还需要约定二进制媒体与编码包装；本需求没有必须保留 JSON 传输的条件 |
| Protobuf 加 WebSocket | 采用。三端生成类型，原生 bytes，控制消息和媒体资源块共用传输 |
| Protobuf 加 gRPC | 不采用。增加一套传输及流生命周期，不能代替已有的配对、中转和端到端加密 |

Protobuf 不负责鉴权、加密、重试、流控或业务正确性；这些语义由本篇和业务协议定义。不会因为三端都能解码，就跳过跨实现行为测试。

## 两层协议与代码生成

```text
protocols/remote_access/
  relay/v1/relay.proto          Relay 可见的控制、路由、密文载荷和流控
  peer/v1/secure.proto          两端握手包与加密片结构
  app/v1/session.proto         会话、命令、审批、提问和订阅
  app/v1/resources.proto       内容投影、资源、媒体和输入附件
  app/v1/plugin.proto          插件页面实例、UI 更新和工具卡
  buf.yaml
  buf.gen.yaml
  tools.lock                   固定 Buf、生成器及运行时版本
  fixtures/                    跨语言和双 Relay 行为夹具
```

命名空间按目录声明为 `reveric.remote.relay.v1`、`reveric.remote.peer.v1` 和 `reveric.remote.app.v1`。初版选择 proto3 的共同特性集合，暂不使用 Editions。relay 与 peer 层不依赖业务模型，随 T01 落地；`app/v1` 按业务模块随 T05、T06 增加，每个模块的 schema 与其 Dart 编解码器、往返夹具一起提交。

| 消费方 | 生成器 | 运行时 | 生成范围 |
| --- | --- | --- | --- |
| Flutter/Dart | `protoc_plugin` 提供的 `protoc-gen-dart` | `protobuf`、`fixnum` | 全部 schema |
| Go Relay | `protoc-gen-go` | `google.golang.org/protobuf` | 只生成 relay schema |
| CF Worker/DO | `@bufbuild/protoc-gen-es` | `@bufbuild/protobuf` | 只生成 relay schema |

生成目录分别为 `lib/shared/services/remote_access/generated/`、`server/relay/internal/protocol/`、`server/cf/workers/relay/src/generated/`。这些是实施时新增的生成输出，不能手工维护字段副本。生成代码提交到仓库，普通 Flutter 构建不要求安装 Go 或 Node。

自建 Go module 定为 `reveric/relay`，relay schema 的 `go_package` 为 `reveric/relay/internal/protocol/relay/v1;relayv1`，生成使用 `paths=source_relative`。Dart 与 TS 保留同样的 `relay/v1` 相对层级；TS 使用 `target=ts`。Go、TS 的生成输入只选 `relay/v1`，不因全部 proto 在同一目录就把业务协议打包到中转。

使用 Buf 的本地插件生成，不要求 BSR 账号或远程生成服务。实施提交同时锁定工具和运行时版本，并提供 `scripts/generate_remote_protocol.sh` 调用本地工具；Dart 插件用 FVM 锁定的 Dart SDK 安装和运行。CI 的协议检查任务使用与 `.fvmrc` 一致的 SDK，遵循现有规则直接使用 CI 安装的 Dart，不要求 FVM。

执行入口为 `buf lint protocols/remote_access`、`buf generate protocols/remote_access --template protocols/remote_access/buf.gen.yaml`，以及脚本封装的版本检查。`buf breaking` 使用 `FILE` 级规则比较最新已发布协议基线；首次发布前以主分支为基线，不能每次把当前改动自身当比较对象。生成后 `git diff --exit-code` 检查对应生成目录。

图片、音频、视频等资源与输入附件都使用本篇的分片与加密协议，视频按播放位置做范围读取，见[视频经加密通道按范围读取](views-and-media.md#视频经加密通道按范围读取)。

## E2E 加密发生在哪里

```text
设备 A：业务 Protobuf → SecureFragment → Noise 加密 → PeerPacket
                    ↓ 放入 RelayFrame.data.payload
          CF DO / Go Relay：只路由 payload 原始字节
                    ↓
设备 B：PeerPacket → Noise 解密 → 重组 → 业务 Protobuf
```

两端各自持有 Noise 身份私钥；扫码固定被访问端公钥，并由本地确认固定访问端公钥。使用 `Noise_IK_25519_ChaChaPoly_SHA256`，会话密钥由握手派生，不发送给中转。每次新连接重新握手，单个 Host 同时连接多个访问端时，每个 peer channel 独立握手与计数。

外层 WSS 在 CF 或自建代理终止，得到的仍是内层密文。局域网也使用同一 `RelayFrame` 分帧、PeerPacket 与 Noise，不依赖“同网所以可信”，见[局域网链路](#局域网链路)。Relay 只能看到连接、路由、长度和时序，无法读取命令、经其传输的媒体资源、作品或审批内容。

`PeerPacket.body` 的 oneof（多选一字段，一条消息只设置其中一项）为 `handshake=1` 和 `ciphertext=2`。Handshake 字段为 `context: bytes=1`、`step: uint32=2`、`noise_message: bytes=3`；Ciphertext 字段为 `sequence: uint64=1`、`sealed: bytes=2`。只允许 Noise IK 的两个握手步骤，完成前不接收 Ciphertext。

设备 ID 固定为 UUID。context 的原始字节按顺序拼接：ASCII `reveric.remote/1`、用途 1 字节（配对为 1，正常访问为 2）、客户端随机 nonce 32 字节、访问端 UUID 16 字节、被访问端 UUID 16 字节。该 context 原样作为 prologue；不能重新编码 Protobuf 来生成它。接收端核对用途、自己的设备 ID 及已配对对端身份，不接受连接中的身份替换；step 2 必须带回完全相同的 context。Ciphertext.sequence 必须等于该方向下一个 Noise nonce，首次为 0。

业务消息先完整编码，再拆成最多 48 KiB 的明文片。每片封装 `SecureFragment(messageId, index, count, data)` 后加密；该封装的总明文也不得超过 48 KiB。接收方逐片校验、解密，重组最多 4 MiB 的业务消息后解码；大资源与视频由多个业务块按范围读取，不把整文件装成一个消息。发送顺序与 Noise 计数一致，不能并发写同一 CipherState（Noise 单方向的密钥与计数状态）。

每连接最多同时重组 8 MiB，超限或 10 秒没有后续片则终止相应连接并重新同步。新连接不恢复旧密文帧，只恢复业务请求核对与资源偏移。篡改、重放或计数不符都失败，不降级明文。

## 外层帧合同

公网入口为 `GET /v1/connect?route=<routeId>`，WebSocket 子协议为 `reveric.relay.v1`。`routeId` 是 32 字节随机注册凭据的 SHA-256，以无填充 Base64URL 表示。它用于在升级连接前确定路由，不承担访问授权。凭据只在升级后的第一条控制帧中传递，不放 URL。

每个二进制 WebSocket message 恰好编码一个 `RelayFrame`，不再加 varint-delimited 外包，不接受文本 JSON。健康和能力 HTTP 接口可以返回小型 JSON，不承载业务数据。

`RelayFrame.body` 使用 oneof，固定编号：`register=1`、`registered=2`、`join=3`、`joined=4`、`peer_open=5`、`data=6`、`ack=7`、`close=8`、`error=9`。字段类型和含义如下，生成 schema 时按此合同落地。

| 消息 | 字段及编号 | 语义 |
| --- | --- | --- |
| Register | `owner_token: bytes=1`、`join_digests: repeated bytes=2`、`invitation: bool=3`、`ttl_seconds: uint32=4`、`registration_key: optional string=5` | owner_token 与每个 join digest（join_token 的 SHA-256 摘要）都是 32 字节；join_digests 是该路由当前允许加入的完整集合，每台已配对访问端一项，最多 32 项且不得重复；首次注册验证 SHA-256(owner_token) 等于 URL routeId；部署密钥仅在配置了注册限制时使用 |
| Registered | `host_connection_id: string=1`、`expires_at_ms: uint64=2` | 接收 Host 的唯一连接代次及路由期限 |
| Join | `join_token: bytes=1` | SHA-256(join_token) 必须属于已存 join_digests；Host 离线时拒绝 |
| Joined / PeerOpen | `channel_id: string=1`、`host_connection_id: string=2`、`window_bytes: uint32=3` | Relay 为本次 Client 分配随机 channelId，向两侧通知；之后开始端到端握手 |
| Data | `channel_id: string=1`、`offset: uint64=2`、`payload: bytes=3` | payload 是原样转发的 PeerPacket；offset 按当前方向已发送的 payload 字节累计 |
| Ack | `channel_id: string=1`、`consumed_bytes: uint64=2` | 接收方累计消费到的 payload 字节数，不是增量信用 |
| Close | `channel_id: string=1`、`code: uint32=2` | 关闭单个 peer channel；Host 控制连接仍可服务其他 peer |
| Error | `code: RelayErrorCode=1`、`channel_id: string=2` | 机器可判断的固定枚举，不包含业务错误或业务正文 |

ID 使用 UUID 字符串，枚举 0 统一为 `UNSPECIFIED`，未设置 oneof 拒绝。控制帧上限 4 KiB，Data 帧上限 64 KiB；它们与业务消息 4 MiB 重组上限是不同层次的限制。

`RelayErrorCode` 固定为 `UNSPECIFIED=0`、`INVALID_FRAME=1`、`UNAUTHORIZED=2`、`HOST_OFFLINE=3`、`HOST_REPLACED=4`、`VERSION_UNSUPPORTED=5`、`LIMIT_EXCEEDED=6`、`ROUTE_EXPIRED=7`、`STORAGE_UNAVAILABLE=8`。`SecureFragment` 字段编号为 `message_id: string=1`、`index: uint32=2`、`count: uint32=3`、`data: bytes=4`；index 从 0 开始，同一个消息的 count 固定，不能跨不同 channel 重组。

## 注册、重连与关闭

新 WebSocket 为 `unbound`，最多 10 秒内提交 Register 或 Join。首帧之前不接收 Data。首次 Register 由 owner_token 的散列绑定 routeId，保存 join_digests 后才回复 Registered；已存在路由必须验证原 owner 摘要，不能由 Join 凭据接管。

一个路由只有一个活动 Host 控制连接，可同时承载最多 8 个 Client。合法新 Host 替换旧 Host 时生成新 hostConnectionId，关闭旧 Host 和所有旧 peer channel，客户端重新加入并重新握手，不将旧密文转给新 Host。旧连接的迟到 close 事件只能清理自己的 ID，不能删除新连接。

同一个已注册 Host 在原连接再次发送 Register 时，以新的 join_digests 整体替换旧集合，不替换自身；其他连接发 Register 才触发替换。集合替换持久化成功后才回复 Registered；不再属于集合的 digest 所加入的活动 channel 立即以 Close 和 `4401` 关闭，因此 Client 附件需记录本次加入使用的 digest。配对邀请使用独立 routeId，期限最多 300 秒，到期关闭并删除邀请路由元数据。普通路由最长保留至最后一次 owner 注册后 30 天；在线 Host 每 24 小时在原连接续期一次。期限由 Relay 时钟计算，不接受客户端任意远期时间。

撤销设备由 Host 的固定公钥信任记录决定，Relay 不理解设备身份，只按 digest 集合准入。每台访问端持有独立的 join_token，撤销时 Host 从集合中移除对应 digest，其余访问端不受影响；即使 Relay 更新失败，Host 仍在 Noise 握手后拒绝已撤销设备。变更中转或轮换 owner 凭据按重新配对处理。Relay 注册凭据和 Noise 私钥各自负责不同边界，不混用。

应用关闭码：`4400` 非法帧，`4401` 凭据错误，`4404` Host 离线，`4409` Host 被替换，`4410` 版本不支持，`4429` 资源限额；正常断开使用 `1000`，服务重启使用 `1012`。单 peer 错误优先通过 Close 通知双方，不关闭其他正常 peer。

## 局域网链路

局域网复用同一套 `RelayFrame` 分帧和 channel 流控，只省去路由注册与加入。两条路径的差别仅在于 channel 怎样建立，分片、有序写入器、发送窗口和累计 Ack 在 Dart 端只实现一份。

| 项目 | 规则 |
| --- | --- |
| 入口 | 被访问端监听器的 `GET /v1/peer`，WebSocket 子协议 `reveric.peer.v1`；每个二进制 message 恰好编码一个 `RelayFrame` |
| 建立 channel | 接受升级后，Host 立即发送 `PeerOpen(channel_id, host_connection_id, window_bytes)`。`channel_id` 由 Host 随机生成，`host_connection_id` 取本次监听器进程的随机代次 |
| 允许的帧 | 只允许 Data、Ack、Close、Error；Register、Registered、Join、Joined 一律以 `INVALID_FRAME` 和 `4400` 关闭 |
| 准入 | 局域网没有 join token，准入完全由随后的 Noise 握手决定，即固定公钥和配对状态；其余规则与 Relay 路径一致 |
| 流控 | Data 的 offset、Ack 的累计语义、窗口检查和违规处理与 Relay 路径相同，Ack 由接收设备发出；窗口初值同为 1 MiB |
| 连接与 channel | 每个局域网 WebSocket 只承载一个 channel；断开后重连即新连接、新 channel，并重新握手 |
| 未认证限额 | 同时最多 4 个未完成握手的连接，10 秒内未完成 Noise 握手即关闭；握手失败或对端不是已配对公钥时立即关闭；同一来源地址连续失败按指数退避拒绝新连接 |

不依赖 TCP 背压：`dart:io` 的 `WebSocket.add` 既不阻塞，也不暴露发送缓冲量，只靠 TCP 会让 Dart 侧的发送队列无界增长。信用窗口是两条路径共同可观测的背压信号。局域网往返时延通常只有几毫秒，1 MiB 窗口不会成为吞吐瓶颈。

## 流控与存活

每个 channel、每个方向初始发送窗口为 1 MiB。吞吐上限约为窗口除以往返时延，按 200 ms 估算约 40 Mbps，满足常见视频码率；该值是工程初值，按实网测量调整。发送下一帧前必须满足 `sentBytes + nextPayloadBytes - consumedBytes <= windowBytes`，不能只检查已有未确认字节。接收方接受每个片并释放传输占用后，按累计值发送 Ack；重复 Ack 无效，倒退值忽略，超过已转发字节数的 Ack 拒绝。不要等整个 4 MiB 消息组完才 Ack，否则会与窗口形成死锁。

Relay 也核对窗口，违规关闭该 channel。DO 不缓存等待发送的媒体队列：只在有信用时转发，信用不足由源端暂停生产。源端最多保留 4 MiB 待发送内容；控制和取消操作优先于新的媒体读取。此机制不依赖 Cloudflare 未提供的 Node `bufferedAmount` 行为。

优先调度发生在明文分片进入 CipherState 之前，所有加密及发送经过同一个有序写入器。已加密的帧不得插队或重排；收到停止请求后，只能停止生成尚未进入写入器的媒体片，不能通过重排密文破坏 Noise 计数顺序。

普通网络存活使用 RFC WebSocket Ping/Pong，避免应用层定时器持续唤醒空闲 DO；访问端正在使用远程工作区时，再通过加密的 Host 探测核对执行进程是否响应。每 30 秒检查、连续 3 次无回应失联，恢复前台立即探测。Ping 成功只表示当前网络连接可用，不等于 Agent 任务成功。

## 业务消息与版本一致性

核心请求、响应、事件、对象引用、审批身份和媒体偏移采用具体消息类型及 oneof，不采用任意 `method + Struct` 绕过字段合同。[业务协议](protocol.md)的点分方法名是语义目录，对应 `app/v1` 中的类型化 case。真正动态的插件与工具输出使用带 `format`、`schema_version` 的 UTF-8 JSON bytes；作品数据不放进无约束 JSON。

需要区分缺失与零值的标量使用 proto3 `optional`。序号、偏移和时间的 uint64 在 Go 用 uint64、TS 用 bigint、Dart 用 Int64；不得经过 JavaScript number。未知 oneof case 返回不支持；删除字段后 reserved 原编号和名称，不能复用 tag。

Protobuf 不保证跨语言重新序列化字节完全一致。普通互通测试比较语义；命令重试保存并复用最初编码的请求字节，摘要基于该原始字节，不对三端各自重编码的消息求摘要后比较。Relay 不解码或重编码 payload。主版本与能力协商仍然存在，未知字段兼容不等于业务能力已经实现。

三端共享的最小夹具覆盖：optional 缺失与零、bytes、超过 2^53 的整数、未知字段、未知枚举和 oneof、错误帧、最大分片、累计 Ack、Host 替换、断线重连。两种 Relay 各运行同一套黑盒状态机场景；Dart 局域网监听器另跑 PeerOpen 建链、禁用帧拒绝、窗口违规和未认证限额场景。

依据：[proto3](https://protobuf.dev/programming-guides/proto3/)、[非规范化序列化](https://protobuf.dev/programming-guides/serialization-not-canonical/)、[Dart 生成器](https://pub.dev/packages/protoc_plugin)、[Go 生成代码](https://protobuf.dev/reference/go/go-generated/)、[Protobuf-ES](https://protobufes.com/reference/generated-code/)、[Buf 生成](https://buf.build/docs/generate/)与[兼容检查](https://buf.build/docs/breaking/)。
