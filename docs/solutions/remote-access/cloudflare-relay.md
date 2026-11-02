# Cloudflare Workers 与 Durable Objects 实现

> 返回[总览](README.md)。字段、认证、状态机和窗口以[线协议](wire-protocol.md)为准，本篇只定义 CF 的实现与部署。

## 入口与 DO 定位

采用一个 Worker 加一个 SQLite-backed DO（Durable Object：全局唯一、单线程执行、自带存储的有状态对象）类 `RelayRoute`，绑定名 `RELAY_ROUTES`。不用 D1、KV、R2、Queues、Cloudflare Tunnel 或 TURN。每个 routeId 对应一个 DO，配对邀请是另一条独立 routeId。

Worker 处理 `GET /healthz`、`GET /v1/info`、`GET /v1/connect?route=...`。升级前校验路由格式、WebSocket 子协议与入口限流，再获取 DO stub 并把升级请求交给它。不能等接受 WebSocket 后才决定它属于哪个 DO。

未配置 `LOCATION_HINT` 时使用 `env.RELAY_ROUTES.idFromName(routeId)`，DO 建在首个请求附近，通常靠近被访问端。配置后使用 `idFromName(`${hint}:${routeId}`)` 并传入 `{ locationHint: hint }`；hint 写入对象名，保证同一配置下 Host 与 Client 总是定位到同一个 DO。被访问端经远端代理出网、而访问端在另一区域时，DO 会建在代理出口附近，部署者可用 hint 把路由固定在访问端所在区域。

修改 hint 相当于把路由迁到新的 DO：Host 下次重连时用原 owner 凭据和完整 join 集合在新 DO 重新注册，Host 重连前 Client 收到 `HOST_OFFLINE`；旧 DO 的路由元数据由 alarm（DO 的定时唤醒）按期限清理，不做迁移。

`/v1/info` 返回实现标识、Relay 主版本和共同限额；不返回业务能力。`/healthz` 只证明 Worker 可响应，正式就绪由黑盒注册、加入和双向转发测试判断。

## 状态划分

| 位置 | 内容 | 生命周期 |
| --- | --- | --- |
| DO storage 的 `route` key | schemaVersion、ownerDigest、joinDigests、invitation、expiresAt | 注册成功后保存；按路由期限清理 |
| WebSocket attachment | schemaVersion、role、connectionId、hostConnectionId、channelId、Client 加入所用 digest、认证阶段、首帧截止时间 | 随 WebSocket 存活，休眠（Hibernation：空闲时 DO 卸出内存而连接保持）后可恢复 |
| Client attachment 内的流控状态 | 两个方向的 sentBytes、consumedBytes | 随 channel 存活，保存十进制字符串以精确恢复 uint64 |
| 内存索引 | Host socket、channelId 到 Client socket | constructor 从 `getWebSockets()` 与附件重建 |

附件不保存发送队列或业务明文。Host 连接不持有每个 Client 的大列表，流控计数放在对应 Client 附件中，保持单附件体积有界。恢复时校验附件版本；不兼容的连接以 `1012` 关闭重连，不猜测旧字段。

首次合法 Register 在 DO 内核对 routeId、凭据摘要与期限，完成持久化后回复 Registered。存储失败则失败返回。重复 Register 和新 Host 替换遵守线协议，旧 socket 的 close 事件必须比对 connectionId 后再清理。

## 休眠与转发

使用 `ctx.acceptWebSocket()`，通过 `webSocketMessage`、`webSocketClose` 和 `webSocketError` 处理事件，不使用 `ws.accept()` 加常驻 listener。constructor 不连接外部服务，不启动周期性定时器。

收到 Data 时只解码 RelayFrame，核对角色、channel、方向 offset 和窗口，更新 Client attachment 后把 payload 原字节转发。Client 只能给其 channel 的 Host 发消息；Host 只能引用当前代次仍存在的 channel，不提供 Client 之间互发。

接收方 Ack 推进窗口，DO 不缓存超出窗口的载荷。平台 `send()` 返回不代表对端已消费，背压只看 Ack。CF 没有 Node 发送队列的同一套观测方式，协议级窗口是两种实现共用的背压依据。

网络心跳优先使用 WebSocket 协议 Ping/Pong；业务 Host 探测仍是端到端消息，仅在访问端活跃时发生。休眠只降低空闲费用，持续业务传输仍会产生请求和活跃计算费用。

## 截止时间与清理

每个 DO 用同一 alarm 调度最早的未认证首帧期限或路由过期时间。到期后检查 socket 附件与 route 记录，关闭过期连接，必要时删除该路由元数据，再设置下一个最早时间。没有待处理期限时删除 alarm，不维持每秒扫描。

长期路由由在线 Host 每 24 小时续期；邀请最多 5 分钟。过期后清理的是 Relay 自己的路由元数据，不涉及设备业务数据。普通路由被清理后，同一 owner 凭据仍可按散列规则重新注册；授权仍由设备公钥核对。

## 配置与限额

Wrangler 的 Worker 名称为 `reveric-remote-relay`，入口 `src/index.ts`，DO 导出类 `RelayRoute`，初次迁移标签 `v1` 的 `new_sqlite_classes` 包含该类。初始兼容日期固定为 `2026-11-02`；修改日期或生成器版本必须重跑 workerd 和互通测试。

| 配置 | 初值 |
| --- | --- |
| `PUBLIC_BASE_URL` | 部署后的 HTTPS 自定义域名或 workers.dev 地址，必须与用户配对地址一致 |
| `RELAY_REGISTRATION_KEY` | 自建 CF 部署可选，使用 Wrangler secret；官方匿名服务不在 App 内置共享 key |
| `LOCATION_HINT` | 可选，Cloudflare 支持的区域提示如 `apac`、`enam`、`weur`；默认不设置。官方部署按实网矩阵结果决定是否设置 |
| `BLOCKED_ROUTES` | 可选，逗号分隔的 routeId；Worker 在升级前拒绝，命中的活动连接在下次消息时以 `4429` 关闭。更新需重新部署 |
| `ROUTE_DAILY_BYTES` | 可选，每路由每个 UTC 日的转发字节软上限，默认不设置；超出后拒绝新 Data 并以 `4429` 关闭 channel，次日自动恢复。是否启用按用量观察决定 |
| Worker 入口限流 | 每来源 IP 每 60 秒最多 60 次升级尝试，使用 Rate Limiting binding |
| 每 DO 未认证 socket | 4 个，10 秒首帧期限 |
| 每 DO 活动连接 | 1 个 Host、8 个 Client |
| 帧与窗口 | 完全使用线协议默认值，不另设 CF 专用消息格式 |

Worker 入口限流是平台支持的局部限流，不宣称全世界严格共享一个计数器；每路由连接限额由 DO 强制执行。CF 版本没有与单机 Go 对应的全局 `MAX_CONNECTIONS` 开关。

### 用量监控与成本控制

官方 Relay 匿名开放，协议层无法区分正常使用和把它当作通用加密隧道的滥用，本方案接受这一风险，靠监控和成本控制兜底：

- DO 按路由累计当日转发字节、活跃连接数和连接时长，只记录 routeId 与数值，写入 Workers 日志；按日汇总，找出用量异常的路由。
- Cloudflare 账户配置用量与账单通知，阈值按首个账期的实际用量设定。
- 发现异常时，按需把路由加入 `BLOCKED_ROUTES`、启用 `ROUTE_DAILY_BYTES`，或调低入口限流。被封禁的正常用户仍可走局域网或自建 Relay。

这些手段只控制费用，不保证服务不被滥用；自建 Relay 由部署者自行承担同类风险。

## 文件与部署步骤

目录为 `server/cf/workers/relay/`，包含 `src/index.ts`、`src/route.ts`、`src/generated/`、`wrangler.jsonc`、`package.json`、锁文件和测试。仅生成 relay schema，Worker 不打包 app 业务 protobuf。

实施时交付 `check`、`test`、`build`、`deploy` 四个 npm scripts：类型检查、workerd 测试、Wrangler dry-run 打包、真实发布。命令入口：

```bash
npm --prefix server/cf/workers/relay ci
npm --prefix server/cf/workers/relay run check
npm --prefix server/cf/workers/relay test
npm --prefix server/cf/workers/relay run build
npm --prefix server/cf/workers/relay run deploy
```

前三项检查与打包在发布前完成。部署者设置 Cloudflare 账户、部署 token，以及可选的自定义域名、注册 key 和 `LOCATION_HINT`；这些是环境输入，不需要用户为协议重新做决策。发布后用共同黑盒客户端完成注册、双向数据、两 Client 隔离、join 集合替换与撤销、Host 替换、休眠恢复和期限清理；设置了 hint 时另验证修改 hint 后 Host 重连即可恢复，再填写发行配置中的中转地址。

升级保留 DO 类名和绑定，更新程序不清空命名空间。协议主版本不变时允许连接重新建立；先让 Host 和 Client 能兼容新增字段，再使用新能力。回退兼容代码版本，保留 route 存储；遇到存储版本不兼容则明确停止对应路由，不能删除存储后假装首次启动。

参考：[DO WebSocket 与 Hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)、[DO State](https://developers.cloudflare.com/durable-objects/api/state/)、[Worker Rate Limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)。
