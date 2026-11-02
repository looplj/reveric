# Go 自建 Relay 实现与部署

> 返回[总览](README.md)。使用与 [CF DO](cloudflare-relay.md)相同的[线协议](wire-protocol.md)，独立于任何官方账号、发现服务或中转。

## 运行栈与目录

采用 Go `net/http`、`github.com/coder/websocket`、`google.golang.org/protobuf`。初始工具链为 Go 1.27.3，在 go.mod 工具链声明与构建镜像中保持一致，之后补丁升级与测试一同提交。module 为 `reveric/relay`，不使用 Node.js，不通过 gRPC 暴露服务。

```text
server/relay/
  cmd/relay/main.go
  internal/config/
  internal/server/        HTTP、WebSocket 与关闭流程
  internal/router/        route、Host、peer channel 与信用窗口
  internal/registry/      注册表、期限与原子文件保存
  internal/protocol/      只读生成的 relay protobuf
  internal/contracttest/  与 CF 共用的场景执行器适配
  go.mod / go.sum
  Dockerfile
  compose.yaml
  Caddyfile
```

部署基线是 Linux 单实例容器，提供 linux/amd64 和 linux/arm64 镜像。桌面 App 的 Windows、macOS、Android 支持范围不意味着每个系统都要运行自建容器；Go 服务仍可按需编译为其他平台二进制，但不把未验证的平台部署当作首版交付承诺。

## HTTP 与连接模型

HTTP 路由、WebSocket 子协议和首帧合同与 CF 完全一致。Go 路由表按 routeId 获取唯一 route owner，每条 route 的状态修改串行处理；每个 socket 一个读循环和一个写循环，禁止多个 goroutine 同时无序写入。

socket 读上限为线协议帧上限，未认证首帧期限 10 秒。每个 channel 的信用窗口阻止无界发送；写队列另设 4 MiB 上限，达到时停止接收新的可转发数据或关闭违规 channel。不得为每个入站媒体块启动一个无界 goroutine。

新 Host 替换、Client 离线、旧连接迟到 close、邀请过期都在 route owner 中完成。对慢 socket 的实际网络写入不持有全局路由锁；route 状态决定投递，写循环负责有截止时间的发送，失败再以 connectionId 回报 owner。

Host 离线通知当前 Client 关闭 peer channel，不保留待恢复的业务字节队列。重连创建新的 channel 和端到端会话，客户端按命令 ID 与资源版本恢复业务。

## 注册表与进程恢复

注册表为 `/data/routes.json`，顶层包含 `schemaVersion: 1` 和 routes；每条记录保存 routeId、ownerDigest、joinDigests、invitation、expiresAt。摘要存无填充 Base64URL，时间存十进制毫秒整数。连接、channel、窗口、业务载荷与命令回执不持久化。

所有写入经过单个 registry writer：校验内存版本，写同目录临时文件，flush/fsync，再原子替换并同步目录，成功后才确认 Register。持久卷只允许一个 Relay 进程写入，启动时取得独占锁；第二实例拒绝启动，不共享一个文件假装多副本。

首次启动没有文件时创建空表；已有文件损坏、版本不支持或卷不可写时就绪检查失败，不重置为新空表。恢复时先停止进程，保留损坏副本，由部署者恢复最后一次完整注册表；不删除用户设备上的配对或业务数据。有效过期记录由注册表管理器清理并原子保存。

进程重启后不恢复旧 WebSocket。Host 使用原 owner 凭据重新注册，访问端重新加入；已有 route 仍验证原 owner。公开 routeId 无法用于接管恢复中的路由。

## 配置

| 配置 | 默认值与含义 |
| --- | --- |
| `LISTEN_ADDR` | 容器内 `0.0.0.0:8787`，只通过 Compose 内网暴露给 Caddy |
| `PUBLIC_BASE_URL` | 部署者的 HTTPS 地址，缺失或非法时启动失败 |
| `REGISTRY_PATH` | `/data/routes.json`，父目录挂载持久卷 |
| `RELAY_REGISTRATION_KEY` | 可选；配置后新 Host 注册必须提供，不向客户端自动下发 |
| `MAX_CONNECTIONS` | 10,000，进程级上限，达到后拒绝新升级 |
| `MAX_ROUTES` | 10,000，已注册路由上限；清理过期记录后仍满则拒绝新路由 |
| `UPGRADES_PER_IP_PER_MINUTE` | 60，按来源 IP 限制升级频率 |
| `TRUSTED_PROXY_CIDRS` | 仅填写 Caddy 所在私网地址范围；不盲目信任公网 X-Forwarded-For |
| 路由、首帧和媒体限额 | 与线协议相同，1 个 Host、8 个 Client、4 个未认证连接 |

`/healthz` 表示进程可响应；`/readyz` 表示配置与注册表加载成功且未开始退出，返回状态和版本，不导出路由内容。共同 `/v1/info` 用于协议能力查询。容器健康检查调用本机 `/readyz`，命令提供 `relay healthcheck`，不要求镜像额外安装 curl。

## Caddy 与容器

Compose 包含 `relay` 和 `caddy` 两个服务：Relay 挂载 `relay-data:/data`，不发布 8787 到宿主公网；Caddy 发布 80/443，挂载持久化证书目录，将域名请求反向代理到 `relay:8787`。Caddy 的 WebSocket 支持沿用正常 `reverse_proxy`，不添加会把连接变成短请求的代理超时，不缓存 Relay 载荷。

Caddyfile 使用环境变量中的用户域名作为站点名，配置 `reverse_proxy relay:8787`；DNS 指向部署机器，80/443 可达后自动申请证书。已有 TLS 代理的用户只运行 Relay，将相同入口交给自己的代理，不要求再部署一层 Caddy。

Go 多阶段构建输出单个非 root 运行的服务二进制。构建镜像和 Caddy 镜像在正式交付时固定版本及摘要，禁止发布配置使用 `latest`。Compose 的停止宽限期为 30 秒，Relay 内部退出预算 20 秒。

## 构建、上线与退出

实施后的入口命令：

```bash
go -C server/relay vet ./...
go -C server/relay test -race ./...
go -C server/relay build -o ./bin/relay ./cmd/relay
docker compose -f server/relay/compose.yaml --env-file server/relay/.env up -d --build
```

部署包提供 `.env.example`，用户填写域名、PUBLIC_BASE_URL 和可选注册 key。启动后验证证书、readyz、共同协议场景和两台设备的实际连接，不以容器 running 当验收。

收到 SIGTERM/SIGINT 后先切为不就绪，停止新升级，向活动连接发 `1012` 服务重启，再显式关闭 WebSocket 和 route owner；最后等待注册表 writer 完成并退出。`http.Server.Shutdown` 不自动关闭被接管的 WebSocket，因此必须维护连接注册表并主动收尾。

升级前停止旧实例并备份完整注册表，启动兼容 schemaVersion 的新镜像；不要并行运行两个写相同卷的副本。失败时恢复旧镜像与兼容注册表，设备重连即可；不迁移作品，不要求用户重建会话。若未来要多副本，必须另行引入共享路由及一致性存储，不能只调高 Compose replica 数。

普通运行诊断记录连接、错误、字节、耗时和资源占用。Relay 不解密业务消息，不存在业务正文脱敏流程。部署验收重点是连接替换、状态保存、期限、流控、退出和恢复。

依据：[Go net/http](https://pkg.go.dev/net/http)、[coder/websocket](https://github.com/coder/websocket)、[Caddy reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)。具体版本锁文件、容器与测试是实施交付物。
