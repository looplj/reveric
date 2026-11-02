# 应用架构解耦

本文设计整个应用的业务访问方式：保留 Riverpod，逐步拆开界面、业务执行和本机存储之间的直接依赖，让同一个业务界面可以接不同的数据来源。远程访问是第一个用上它的场景，但本机功能、无界面任务和测试同样受益。

远程访问把这项工程记为 T0，任务状态统一在[远程访问实施任务](README.md#实施任务)维护。T0 之前先做 [P0 业务切片 PoC](#p0业务切片-poc)，用最小的传输验证这套设计。T0 分批交付，每批本机功能都可用，全部验收后才开始依赖业务契约的远程任务；连接、加密和 Relay 不依赖业务模型，可以与 T0 并行开发。本文不逐个列举全仓入口，也不要求一次重写全部代码。

## 目标与范围

成功标准有三条：业务界面只依赖业务身份、数据和动作契约，换数据来源时不用重写界面和业务规则；业务执行不需要打开对应页面；每份已提交内容和运行状态只有一个权威持有者。

改造范围是远程 MVP 会展示或控制的全部业务模块，即[平台展示差距](views-and-media.md#平台展示差距)和[业务协议](protocol.md)涉及的作品、内容、画布、会话、制片、剪辑、导演、插件与资源，包括这些模块在桌面、移动端、Agent、后台任务和 IM 中的读写路径。远程 MVP 一次性交付，范围内的模块不拆成部分交付。

不在范围内的：

- 远程不展示的本机功能（如设置、封面工作室）保持现状。
- 主题、语言、窗口、输入法、导航等属于当前设备的能力，继续留在当前设备，不包装成远程能力。
- 模块内部没有替换需求的实现，不为了形式增加接口。

本工程不实现远程传输、离线作品副本、多主同步、自动合并编辑、通用 RPC 框架或新的状态管理框架，也不调整已有的业务权限、数据删除方式、工具描述和平台功能范围。现有本机编辑能力全部保留，远程的只读限制由能力集合表达。

核心前提是作品和任务仍有明确的归属设备，远程访问中即被访问端。将来如果要支持多设备离线同时编辑，需要另行设计同步与冲突规则，本方案不靠藏一份可写的数据库副本来预留这种能力。

## 目标结构

```text
桌面 / 移动 Page 与 shell
          |
业务 region：展示 Provider、局部编辑态、用户动作
          |
按业务模块定义的访问契约
  查询与订阅 | 命令 | 运行状态 | 资源
          |
按来源装配实现
  ├─ 本机实现 ─→ 业务 Service / Orchestrator / Runtime
  |                         |
  |                      DAO / 文件 / 模型与工具
  ├─ 测试装配：本机实现 + 内存数据库 + 延迟/故障装饰器
  └─ 后续远程实现 ─→ Client / 编解码器 / 传输 / Host
                                      |
                               同一套本机业务边界
```

依赖方向指向业务契约。契约里不出现 Widget、Riverpod Ref、DAO、数据库实例、companion（Drift 生成的写入参数类）、数据库路径或网络生成类型；Drift 生成的数据类可以作为读模型出现，规则见[模型](#模型不为分层而分层)。其余技术对象由实现负责转换。业务规则只在被访问端执行，远程实现只负责转送和映射，不另抄一套规则。

Page/shell 继续只组合区域、管理页面生命周期。Region 可以用 Riverpod，但读的是不区分来源的业务 Provider。绘制、排版这类叶子组件接收数据和回调；不要求把所有 Widget 改成纯组件，也不把一大串参数从页面逐层传到底。

### 四类契约

按作品、内容、画布、会话、制片等业务模块定义小而明确的契约。下面四类是按职责分的，不要求每个模块都写出四个类。

| 契约 | 对外表达 | 不承担 |
| --- | --- | --- |
| 查询与订阅 | 查询条件、分页、业务快照、变化后的状态 | SQL、表结构、调用方手动刷新数据库缓存 |
| 命令 | 保存内容、提交布局、发送输入、停止、处理审批等有业务含义的操作及结果 | 按任意方法名分发、通用表 CRUD、页面回调 |
| 运行状态 | 任务身份、阶段、进度、等待决策、结果和失败 | 暴露 Agent 实例、Completer 或取消令牌 |
| 资源 | 业务资源身份、版本、读取或播放句柄及释放 | 把被访问端的文件路径交给调用方直接打开 |

命令由拥有该业务的模块定义，跨模块流程由 Orchestrator 编排。Service 仍由 Provider 注入依赖，Orchestrator 仍按项目约定按操作创建。不增加全局 `AppRepository`，也不把所有 Provider 方法搬进一个万能接口。

已有 Service 能直接实现契约的就直接实现；只有确实要做存储或传输映射时才加适配器。不给每个 Service 配一层纯转发的类，也不用 `ServiceImpl` 命名。

### 模型不为分层而分层

要解耦的是数据的访问方式，不是数据类型。Drift 生成的数据类是不可变值对象，不持有数据库引用，构造函数公开，手机端不打开数据库也能创建。所以它们可以直接作为契约的读模型，比如画布快照直接包含 `CanvasNode`、`CanvasEdge`。

| 界面与契约中 | 规则 |
| --- | --- |
| DAO、数据库实例与 Provider、companion、数据库路径 | 禁止，只出现在本机实现和装配内部 |
| Drift 数据类、已有业务模型 | 允许，作为读模型和快照内容 |
| Protobuf message | 禁止，只出现在远程模块内部 |
| 专门的展示模型 | 只在行中含有不能离开被访问端的字段时才建，见下文 |

要不要另建模型看字段，不看层级：行里有非空的本机绝对路径、秘密，或其他在访问端无法合法赋值的字段时，才为该实体建展示模型，路径改成资源引用。可空的持久化字段（如 `deletedAt`）不算理由，活动查询不返回软删除数据就行。命令参数仍由业务模块定义为强类型记录，不直接接收 companion。

查询按用例返回需要的数据。关系图可以直接读聚合投影，不必让手机模拟多次本机表查询。

### 远程在哪里转换

转换只发生在远程模块里，业务模块、Provider 和界面都不知道远程的存在：

```text
Host：本机 Queries → 快照（含 Drift 数据类）→ 模块编解码器 encode → Protobuf → 安全通道
Client：安全通道 → Protobuf → 模块编解码器 decode → 同一快照类型 → 远程 Queries 的 Stream
```

每个可远程的查询、命令或事件注册一个类型化描述，写明请求类型、结果或快照类型，以及它们的编解码器。Client 订阅表和 Host 分发器按描述统一处理，不用每个模块手写一套远程实现；线上仍是 `app/v1` 里的类型化 oneof（Protobuf 的多选一字段），不传任意方法名或动态参数。

```dart
// 设计摘录：一个模块注册一次，Client 与 Host 共用
final class QueryDescriptor<Req, Snapshot> {
  const QueryDescriptor({required this.kind, required this.request, required this.snapshot});
  final String kind;
  final Codec<Req, List<int>> request;
  final Codec<Snapshot, List<int>> snapshot;
}
```

编解码器同时负责字段白名单：Host encode 时只写入允许出网的字段，Client decode 时用协议里的值构造回原类型。每对编解码器都用往返夹具验证，Protobuf 生成的类型不出远程模块。注册了描述不等于进入远程白名单，Host 授权另外判断。

模块之间通过稳定 ID、公开查询或资源引用协作，不直接读其他模块的 DAO。只有必须同时一致的数据才放进同一个快照；用 `combineLatest` 拼起来的两路流不算同一事务读取。

## 身份、来源与能力

业务对象用“来源 + 作品 + 对象”定位。来源是稳定的逻辑身份，不是连接、URL 或数据库路径，重连不会产生新的来源。T0 只用一个明确的本机来源身份，远端来源以后由设备配对层映射，现在不提前引入密钥或设备注册表。

身份分两级，分别对应全局应用库和每部作品的内容库：

```dart
typedef SourceRef = ({String sourceId});               // 设备级：作品列表、可选模型、技能、Agent 配置
typedef WorkRef = ({SourceRef source, String workId}); // 作品级：作品内容库中的对象
```

设备级查询按 `SourceRef` 装配，作品级查询按 `WorkRef` 装配。本机装配把 `WorkRef` 解析成现有的作品内容库路径。现在以 `databasePath` 作为 family key（Riverpod provider family 的参数）的 Provider，迁移时改用完整业务身份作 key，路径只留在装配处。

Provider family、页面状态、草稿和资源缓存都按完整业务身份隔离。只用 `canvasId` 或 `sessionId` 作缓存键会在不同来源之间串数据；请求执行中也不能靠全局的“当前设备”重新解析目标。动作在提交时固定来源和上下文，切页之后返回的结果仍归原目标。

来源只在装配处选择。业务 Provider 里不写 `if (remote)`，Widget 不判断电脑路径存不存在。可选能力用类型化的能力集合表达，比如内容编辑、会话控制、资源读取；“暂时断线”和“永久没有这个能力”分开表达。

界面按能力关闭不支持的动作，执行时仍重新校验。远程只读来源不提供内容编辑命令，但提供发送指令、停止、审批等控制命令；Agent 在被访问端按原有权限完成业务写入。抽出了本机命令接口，不代表要把全部方法开放到网络上。

## 状态与生命周期

| 状态 | 权威持有者 | 页面关闭后 |
| --- | --- | --- |
| 已保存的作品内容 | 被访问端的数据库和文件 | 保留，查询快照按需释放 |
| 活动任务、共享队列、待审批与提问 | 被访问端 Runtime | 按任务生命周期运行，不随观察页面释放 |
| 查询与运行态的镜像 | Riverpod 展示 Provider | 没人用时释放订阅，但不取消任务 |
| 未提交编辑、选中项、缩放、输入法状态 | 本端 region、Hooks 或现有 form/edit session | 按原编辑规则保存、提示或释放，不冒充已提交的业务状态 |
| 连接、读取句柄与临时资源 | 对应的来源或资源实现 | 最后一个使用者释放；任务持有的资源单独保活 |

Riverpod 继续负责装配、共享查询缓存和展示状态，但缓存不能变成第二份业务权威状态。命令成功后由权威查询流带来新内容，页面不用自己同时改数据库、列表缓存和运行态三份数据。

迁移后有多个写入方的模块，优先用项目已有的“Stream 读 + Service 写”。仍用单一 Notifier 读写的模块，完整迁移前保持原来唯一的写入口，避免中途变成“新 Stream 读 + 另一个缓存 Notifier 写”两套模式。

短命令持有操作级的资源租约；长任务由 Runtime 持有任务级租约，到终态释放。只用 `ref.read(...).action()` 发起的任务也必须能正常完成，不能要求页面额外 watch 才能维持执行。订阅取消、用户取消任务、进程退出是三种不同的事件。

### 查询与命令的共同语义

- 查询要区分五种状态：未加载、最新数据、刷新中（保留旧数据）、不可用、失败。旧数据可以看，但不能当作最新状态继续提交编辑；收到外部变更时也不覆盖未保存的草稿。
- 每次观察先给初始状态，再给后续变化，两者之间不丢更新。跨表的一致性由本机的同一事务读取保证；顺序和重连校准交给后续的远程实现，界面只拿校准后的业务状态。
- 命令要区分拒收、已接收和完成。短保存“完成”指已持久化；长任务接收成功后返回任务身份，结果通过运行状态观察。排队失败必须有明确结果，不能用正常返回的 `Future<void>` 表示。
- 超时或断线可能意味着结果未知，不能一律当失败去重试。T0 的契约保留“结果未知”这一状态，具体的远程命令租约和去重由后续业务协议实现。
- 错误带稳定的业务码和诊断，UI 负责本地化展示，Agent 工具拿到实际诊断。调用失败时不退回空列表、默认对象或本机来源来假装成功。
- 订阅按对象或可见范围建立，大列表分页，变化合并和缓存都有上限。不做覆盖整部作品全部数据的常驻广播。

### 展示反馈与业务执行

动画完成、自动滚动、焦点和镜头移动是展示反馈，不代表业务已完成。现有的本机动画节拍可以保留为可选反馈，但等待要有上限，页面退出或没人观察时可以释放；远程观看者不参与被访问端的动画节奏控制。

编辑提交屏障则有业务意义：排版、导出、布局之前，要先处理未提交的编辑、拖拽和 CJK 组词。屏障可以由编辑区注册，但要通过专门的编辑协调器调用，底层存储服务不持有 Widget 或 controller。没有编辑页面时命令照样执行；有未完成的编辑时，沿用现有的阻止、提交或冲突处理，不靠忽略草稿来实现“无界面运行”。

## 具体示例：画布订阅与节点位置保存

下面以当前画布为例，演示一条读写链怎么迁移。代码块是设计中的接口和调用摘录，不是已提交的实现，也不代表完整画布只需要这些字段或方法。

### 当前代码的耦合

实际参考文件：

- [canvas_board.dart](../../../lib/desktop/features/canvas/widgets/canvas_board.dart)：同时读取内容、元数据和本机 Service；部分拖拽路径直接保存坐标；注册 AI 动画节拍器。
- [canvas_region.dart](../../../lib/desktop/features/canvas/widgets/canvas_region.dart)：创建 `CanvasEditSession`，注册布局前的编辑屏障，并装配 Board。
- [canvas_providers.dart](../../../lib/shared/providers/canvas_providers.dart)：以 `databasePath` 装配 Service，内容查询返回 Drift 的 `CanvasNode` / `CanvasEdge`。
- [canvas_service.dart](../../../lib/shared/services/canvas_service.dart)：校验和写库、合并内容流，并持有按数据库实例关联的布局屏障。
- [canvas_flow_adapter.dart](../../../lib/desktop/features/canvas/widgets/canvas_flow_adapter.dart)：将 Drift 节点转换为 flow 节点，flow 数据中仍保留原始数据库节点。

当前 Board 的相关调用可以缩写为：

```dart
final contentAsync = ref.watch(
  canvasContentStreamProvider((
    canvasId: canvasId,
    databasePath: databasePath,
  )),
);
final service = ref.read(canvasServiceProvider(databasePath));

// 当前无 editSession 的拖拽结束分支；正常编辑会话另有提交路径。
service.updateNodePosition(
  nodeId: node.id,
  x: node.position.value.dx,
  y: node.position.value.dy,
);
```

所以只把内容 Provider 换成远程查询是不够的：写动作仍然落到本机 Service，节点类型和引用详情仍然依赖数据库，AI 动画还通过页面回调影响执行节奏。`editable: false` 也去不掉读取链上的本机依赖。

### 改造后的契约

画布模块拥有 `CanvasRef`、`CanvasSnapshot`、`CanvasQueries`、`CanvasCommands`。来源由作品引用携带；几何位置用普通数值表达，不把 Flutter `Offset` 或 flow controller 放进契约。

```dart
// WorkRef 见“身份、来源与能力”
typedef CanvasRef = ({WorkRef work, String canvasId});
typedef MoveCanvasNode = ({String nodeId, double x, double y});

abstract interface class CanvasQueries {
  Stream<CanvasSnapshot> watchCanvas(CanvasRef target);
}

abstract interface class CanvasCommands {
  Future<void> moveNode(CanvasRef target, MoveCanvasNode change);
}
```

`CanvasSnapshot` 是画布的不可变快照，包含画布条目，以及同一次事务读取得到的 `List<CanvasNode>`、`List<CanvasEdge>`。现有节点和边的列里没有本机路径或秘密，所以直接复用 Drift 数据类，不另建画布节点模型；活动快照不含软删除的行。以后如果某类节点引用图片等文件，该字段用资源引用表达。快照不暴露 companion 或数据库实例，远程模块也不另造一套画布模型。

`moveNode` 只是一个短命令的例子：成功表示坐标已提交，失败抛结构化错误。本机执行时要核对来源、作品、画布和节点的归属，不能只凭客户端传来的 nodeId 就调用底层更新。其他编辑命令按同样原则定义，但不会因此进入远程写白名单。

### Riverpod 和界面怎么接

来源装配为每部作品提供 `canvasQueriesProvider(workRef)`，以及按能力提供的命令入口。查询 Provider 只做业务契约的桥接：

```dart
@riverpod
Stream<CanvasSnapshot> canvasSnapshot(Ref ref, CanvasRef target) {
  return ref.watch(canvasQueriesProvider(target.work)).watchCanvas(target);
}
```

Region 用 `ref.watch(canvasSnapshotProvider(target))` 处理加载、错误和最新快照，再把数据交给 Board。Board 的目标输入形状是：

```dart
CanvasBoard(
  snapshot: snapshot,
  controller: controller,
  editable: canEdit && !editSession.editingLocked,
  onMoveNode: canEdit ? handleMoveNode : null,
)
```

这里只列了和本次改造有关的参数，详情、焦点等其他交互按现有分工保留。Board 不再接收 `databasePath`，也不再自己读本机 Service。flow adapter 接收业务节点；子节点、详情层、引用预览也要通过同一个业务引用取数据，否则耦合只是被藏进了子树。

`handleMoveNode` 把用户意图交给命令入口，同时保留现有编辑队列的顺序和错误处理：

```dart
Future<void> handleMoveNode(MoveCanvasNode change) {
  return editSession.write(
    'move:${change.nodeId}',
    () => commands.moveNode(target, change),
  );
}
```

`commands` 是装配到当前作品的命令能力，异步执行期间的资源存活由它自己保证；`editSession` 只负责协调当前界面的编辑。正常拖拽仍然先更新本地交互，再按现有的保存时机提交，这个例子不意味着要把拖动改成逐帧持久化。保存失败时保留草稿和错误供处理；权威快照回流时，保留仍然有效的选择、缩放和正在编辑的内容。

### 本机实现与状态回流

```text
读取：Region → 展示 Provider → CanvasQueries
     → 本机查询实现 → CanvasService / DAO → CanvasSnapshot

拖拽：Board → region / edit session → CanvasCommands
     → 被访问端的归属校验与业务写入 → DAO
     → 查询流的新快照 → Region → Board / flow controller

Agent：画布工具 → 同一业务命令边界 → 同一查询流
```

本机装配内部把 WorkRef 解析成数据库路径，再复用现有的 Service 和 DAO，路径不出装配处。可以让现有 Service 直接实现合适的契约，也可以加一层薄的本机适配来解析身份。不新增第二份画布状态仓库，查询回流时也不再触发保存。

当前的 `watchCanvasContent` 分别监听节点和边再拼起来，无法保证两者来自同一次事务。迁移时改为由 `tableUpdates(TableUpdateQuery.onAllTables([canvasNodes, canvasEdges]))`（Drift 的表变更通知）统一触发，在同一个事务里读节点和边，再产出一帧快照。测试要覆盖节点和边并发修改，不能只测单个节点移动。

布局前的编辑屏障从“底层 Service 登记页面回调”改到编辑协调器里，继续遵守 `CanvasEditSession` 的组词、写入等待和失败阻断规则。AI 活动通过带完整画布身份的观察接口传到显示层；保留本机有上限的节拍反馈，但动画播完不等于画布已保存。

后续的远程实现通过画布的类型化描述和编解码器，提供读取用的 `CanvasQueries` 和资源能力，返回同一种快照；它没有人工编辑能力，Board 的写入口关闭。Host 的查询复用本机查询实现，Agent 操作仍由被访问端的业务命令执行。普通画布的 Android 宿主和触摸适配属于后续远程任务，不算在 T0 里。

### 这条迁移怎么验收

1. 同一个 Region 分别接本机装配和测试装配（内存数据库加延迟/故障装饰器），不改 Board 就能显示内容、响应更新、展示失败；替换只发生在契约 Provider 的装配处。
2. 两个来源用相同的作品、画布和节点 ID 时，查询、动作、草稿、AI 活动和引用资源互不串用；切换来源后，迟到的结果不会落到新画布上。
3. 移动节点只提交一次，提交后查询回流；flow 同步不产生循环写入。写入失败时不显示已保存，也不清掉待处理的编辑。
4. 节点和边在同一次业务操作中变化时，不出现违反关联关系的中间快照；外部更新不覆盖未提交的编辑。
5. 没打开画布也能执行 Agent 操作；关闭页面会释放观察和动画等待，已接收的任务继续。编辑区打开时，组词期间仍然阻止布局和导出。
6. 只读能力下，按钮、拖拽、快捷键、详情层都提交不了命令；绕过 UI 直接调用，也会在执行时被拒绝。

现有回归基础包括 [CanvasService 测试](../../../test/shared/services/canvas_service_test.dart)、[Board 内容变化测试](../../../test/desktop/features/canvas/canvas_board_signature_test.dart)、[AI 活动测试](../../../test/shared/providers/canvas_ai_activity_notifier_test.dart) 和 [Agent 画布工具测试](../../../test/shared/services/ai/tools_canvas_test.dart)。迁移时补上述行为用例，断言的是行为，而不只是某个 Provider 或类被调用了。

## 远程如何实现 watch

`ref.watch` 始终发生在本设备内。网络上传的是订阅请求和数据消息，远程查询实现把消息转成本机的 Dart `Stream`，Riverpod 再把流里的状态交给界面。Provider、Ref 和 Dart Stream 对象本身不会上网。

以画布为例，两种实现向上提供同一个 `watchCanvas(target)`：

```text
本机：界面 ref.watch
        → canvasSnapshotProvider
        → 本机 CanvasQueries.watchCanvas
        → 本机数据库变化 → CanvasSnapshot

远程：界面 ref.watch
        → canvasSnapshotProvider
        → 远程 CanvasQueries.watchCanvas
        → Client 订阅表 / WebSocket
        → 电脑 Host
        → 电脑本机 CanvasQueries.watchCanvas
        → 电脑数据库变化
        → Host 编码推送 → Client 解码 → CanvasSnapshot
```

手机和电脑各自持有自己的订阅对象，由 WebSocket 关联起来。Host 不需要打开画布页面，直接用本机的业务查询契约建立观察。

### 一次订阅的生命周期

1. 手机进入画布，展示 Provider 第一次监听远程 `watchCanvas`。Client 先登记请求关联，再发出画布的类型化 watch 请求，参数里固定了设备、作品和画布身份。
2. Host 核对权限和对象归属，创建 `subscriptionId` 和订阅代次 `generation`，开始监听本机 `watchCanvas`。本机查询流的第一帧就是初始快照，之后每帧都是完整的最新快照。Host 给每帧分配递增的 `sequence`（同一订阅内的帧序号），编码后推送。不要另外先 get 再 listen，否则两步之间会漏掉更新。
3. 手机收到订阅确认和初始快照，Client 按订阅身份路由，解码成 `CanvasSnapshot` 发进本地流。确认和首帧按顺序交付；关联完成前到达的数据先缓冲，首帧不能丢。
4. 电脑上人工或 Agent 提交修改，本机查询产生新一帧。Host 编码推送，Client 用这一帧替换内存快照，再向流发出新状态，Provider 通知相关界面更新。
5. 同一作用域、同一查询的多个组件共享一个展示 Provider 的观察，不因每次 rebuild 重新发 watch。不同查询用不同的订阅 ID，复用同一条已认证连接，不为每个 Provider 新建 WebSocket。
6. 最后一个使用者离开时，Provider 释放流观察，Client 取消订阅并发送 `subscription.close`，Host 释放对应的本机监听。如果连接已经断了，Host 在连接失效时释放这条连接上的所有观察；关闭过程中迟到的数据按已关闭订阅丢弃。取消观察不会取消电脑上正在跑的任务。

### 为什么内容查询不需要快照水位

快照水位解决的是“先取状态、再听变化”中间那条缝：先查后听，会漏掉中间的写入；先听后查，同一次变化可能被应用两次。水位的做法是给初始快照标版本 N，之后只接受版本大于 N 的变化。只有推送相对某个基准的增量时，才需要它。

内容查询推送的是替换快照，每帧都是完整状态，不用和基准合并。Drift 的 watch 查询在注册表变化监听之后才执行，查询期间有写入会重新执行，所以本机流本身不丢更新。Host 只需转发每一帧并标上 `generation + sequence`，用来丢掉旧代次和重复帧。因此 T0 和内容订阅都不做水位和变化缓冲。

有两件事仍要守住：跨表一致性靠本机的同一事务读取保证，网络上的 sequence 修不好底层拼出来的半新半旧快照；会话的消息追加和 token 流属于增量，水位只保留在[会话协议](protocol.md#快照事件与浏览上下文)里。

### 推送哪些数据

网络推送和页面状态的粒度不同：页面拿到的始终是可用的业务状态，线上传的可以是替换快照，也可以是增量。

| 形式 | Host 推送什么 | Client 做什么 |
| --- | --- | --- |
| 替换快照 | 当前订阅范围的完整最新投影 | 替换该订阅的内存状态，再发出业务快照 |
| 类型化增量 | 相对明确基准版本的节点变更、消息追加等 | 校验基准版本，应用增量，再发出业务快照；对不上就重新获取快照 |

内容查询先用替换快照，再按实际数据量决定个别模块要不要加类型化增量；加增量的模块同时引入基准版本和水位。T0 不实现网络差分算法。历史消息和大列表按范围或分页查询，不每次把整部作品发一遍；媒体只传引用和元信息，视频字节不混进状态推送。高频状态可以合并，但审批、任务结果这类消息不能像动画事件那样随意丢弃。

### 断线与重连

Client 检查每个订阅的 `generation` 和 `sequence`：旧代次或已关闭订阅的数据丢弃，同代次的重复帧或倒序帧也丢弃。替换快照模式下缺号不用补发，下一帧就是完整状态。连接重建或 Host 重启后重新订阅，用新的首帧校准。

断线期间界面显示不可用或状态陈旧，内存里的上次快照可以继续看，但它不再实时更新，也不构成可离线使用的作品副本。Client 只为仍有观察者的查询重建订阅，用新的初始快照校准，不要求电脑保留断线期间的全部事件。授权被撤销时终止访问、释放数据，不再自动重试。

所以业务 Widget 不管重连、排序、拼接和恢复，这些都由远程查询实现负责。具体的消息身份和恢复规则以[业务协议](protocol.md#快照事件与浏览上下文)为准。

## 渐进迁移与完成门槛

### 分批方式

| 批次 | 交付内容 | 独立合入条件 |
| --- | --- | --- |
| 1：首个完整业务切片 | 画布的业务身份、查询、命令、编辑协调和资源访问，提供本机装配和测试装配；由 [P0](#p0业务切片-poc) 先行完成并保留 | 本机完整读写照常可用，测试可以替换来源；不依赖正式的网络代码 |
| 2：其余内容模块 | 作品、正文、人物、设定、剧本、地图、关系图等按模块迁移 | 每个模块的桌面、移动入口和 Agent 写路径一起迁移，读写保持同一权威来源 |
| 3：会话与后台执行 | 会话接收结果、队列、任务状态、审批、提问和后台资源租约脱离页面 | 不打开页面也能执行，原有本机交互和 IM 行为保留，不新建远程助手 |
| 4：复杂工作区与资源收口 | 制片、剪辑、导演、插件、导入导出和剩余的资源访问按同样方式收口 | 实际支持的本机入口保持可用，调用方不绕过所属模块直接访问技术实现 |
| 5：全局验收 | 对[改造范围](#目标与范围)内全部业务模块核对残留依赖、来源隔离、任务生命周期和三平台回归 | 范围内模块全部满足下表，T0 才算完成，依赖业务契约的远程任务才能开始 |

这不是五次全量重写。每批还可以按完整业务模块拆成更小的提交，每次合入都能独立运行和发布本机功能。没迁移的模块保持原样；一个模块切换时，它的读、写和刷新路径一起切，不长期并存两套权威状态。平台专属功能不用为 T0 新建另一个平台的入口，但已经在两端都有的入口要一起核对。

迁移保持现有文件路径，优先原位抽取职责。确实要移动或重命名时，按项目规则单独说明并确认，本文不授权批量调整目录。T0 不预设 schema 变更，确有必要时按发布状态和 migration 规则另行处理。

### T0 完成标准

| 维度 | 通过条件 |
| --- | --- |
| 依赖 | 范围内的业务 region、展示 Provider 和展示组件不直接读 DAO、数据库 Provider、companion、被访问端的本机路径或远程 DTO。Drift 数据类作为读模型不算残留。技术访问集中在实现和装配处 |
| 可替换 | 每个模块都用本机装配和测试装配验证过同一份契约。换来源不改业务 UI，也不需要一长串底层 Provider override |
| 可远程 | 每个要远程的查询、命令和事件都有类型化描述和编解码器，往返夹具通过。含本机路径或秘密的字段已改为资源引用或排除 |
| 写入 | UI、Agent、后台任务用同一套业务校验和提交语义，没有平行的缓存写入口，也没有因为抽接口而扩大权限 |
| 生命周期 | 无页面、只用 read 发起命令、关闭观察、切换作品、进程退出，这几种情况都有明确的结果和资源释放规则 |
| 状态 | 来源隔离、外部更新、未保存草稿、失败、不可用和结果未知都有可验证的行为，不用假的默认值覆盖真实状态 |
| 资源 | 资源引用、版本、读取和释放都走资源契约；展示组件不拿远端路径调用 File；本机导入导出仍按平台文件访问规则 |
| 平台 | Windows、macOS、Android 现有能力完成相关测试和实机回归。没覆盖到的项明确记录，只在宿主平台跑过不算通过 |

静态残留检查看调用链：`ref.watch` 本身不算违规，本机适配器导入数据库也是合法的。检查覆盖 `lib/desktop`、`lib/mobile` 和 `lib/shared` 的业务入口，排除生成代码后人工核对命中的位置。

实施时用 `fvm flutter analyze` 检查受影响的目录，按模块串行跑最窄的测试；Widget 测试加外部超时，生成源有变化时执行 `make codegen` 并检查生成差异。画布首批可以从下面这些现有回归入口开始，再加入新契约的用例：

```bash
timeout 180s fvm flutter test test/shared/services/canvas_service_test.dart test/shared/services/ai/tools_canvas_test.dart test/shared/providers/canvas_ai_activity_notifier_test.dart test/desktop/features/canvas/canvas_board_signature_test.dart --concurrency=1
```

T0 不需要 Relay、S3 账号、真实模型调用或部署凭据。测试装配用内存数据库跑真实的本机实现，再用装饰器模拟延迟、重复状态和失败，不为每个模块手写内存版的契约实现。真实的远程传输和网络故障由后续任务验证，测试里替换来源证明不了网络协议可用。

每个迁移提交只要保持存储格式和业务语义不变，就能靠代码回退恢复旧路径，不需要迁移用户数据。生产运行中不自动 fallback 到旧写链；某个模块迁移失败，就修这个模块或回退这一批代码，不再加第三套兼容状态。

## P0：业务切片 PoC

P0 在 T0 之前用最小的传输验证这套设计是否成立，回答两个问题：

1. Drift watch 转发成远程订阅后，实时更新是否正确，性能是否可以接受？
2. 会话发送和审批能否不依赖页面，经现有 runtime 远程执行？

配对、加密、Relay 和 Protobuf 不影响这两个答案，P0 不实现它们。

P0 也不移植 Android 画布。“换来源后不改 UI”由第 1 批的测试装配验收证明（同一个 Region 分别接本机装配和测试装配）。Android 只做一个 Debug 诊断页，显示订阅到的快照摘要，并提供发送指令和处理审批的最小操作。

```text
macOS（Host）                                   Android（Client）
本机 CanvasQueries / 会话命令                     远程 CanvasQueries / 会话命令 + Debug 诊断页
        ↑                                                 ↓
   Host 分发 ←  局域网 ws:// 明文 + JSON 编解码器  → Client 订阅表
                （手工地址与共享开发密钥，无配对与加密）
```

| 产出 | 去向 |
| --- | --- |
| 画布按本文第 1 批改造：`SourceRef`/`WorkRef`、契约、同一事务读取、编辑屏障与 AI 节拍迁移、测试装配 | 保留，即 T0 第 1 批 |
| 会话 `send()` 返回类型化的接收结果，审批与提问走不依赖页面的会话命令入口 | 保留，归入 T0 第 3 批 |
| 类型化描述、编解码器接口、Transport 接口、Client 订阅表与 Host 分发骨架 | 保留，后续 T05/T06 在其上实现 |
| 明文 WebSocket Transport、JSON 编解码器实现、手工连接配置 | 丢弃，换成 Noise 安全通道、Protobuf 编解码器和正式配对 |

要丢弃的部分只能放在 Transport 和编解码器接口后面，业务契约、Provider 和界面都不引用它们。P0 代码不进入发布构建的用户入口：开发入口只在 Debug 构建显示，Release 构建不监听端口。

完成标准：

1. Android 诊断页订阅 macOS 上的画布，显示节点与边数量、最近 sequence 和刷新耗时；macOS 上人工或 Agent 修改后，手机在局域网内 1 秒内收到新快照。
2. 节点与边并发修改时手机不出现半新半旧快照；离开画布后 Host 释放对应监听。
3. 手机向 macOS 既有会话发送指令，被访问端返回已启动、已排队或拒收；关闭 macOS 聊天页后任务继续。
4. 手机处理一次工具审批，桌面同时可见并只生效一次。
5. 记录一个大画布在替换快照模式下的单帧字节数与刷新耗时，作为是否需要增量的依据。

网络风险可以和 P0 并行单独验证：两端经 Noise IK 互发加密 echo，分别走局域网和最小 Relay，在大陆和海外网络各测一次。这是 T01～T04 的前期验证，不依赖业务契约。

## 与远程访问的关系

T0 完成后，远程访问要增加的是：业务契约的网络实现、Host 授权与方法白名单、连接和媒体传输。具体分工如下：

- T01 建立 relay 与 peer 层的线协议和工具链，可以与 T0 并行。
- 各业务模块的 `app/v1` schema 与编解码器随 T05、T06 落地。
- T05 在 T0 的会话命令入口上增加远程命令身份、去重和租约。
- T06 增加远程订阅同步。
- T08、T09 接入远程来源，补齐移动端的展示差距。

这样 T06 不用再负责第一次把全部 UI 从数据库里拆出来，T08、T09 也不用各自发明数据源接口。具体协议由[业务协议](protocol.md)和[线协议](wire-protocol.md)维护；应用契约不直接等同于网络上开放的权限。

Riverpod 的装配替换和隔离测试用现有机制，参见[官方 Provider 测试文档](https://riverpod.dev/docs/how_to/testing)；不另建依赖注入容器或自定义响应式框架。
