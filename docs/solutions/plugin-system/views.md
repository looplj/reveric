# 自定义 View

> M3 交付。本篇定义 TSX 与 A2UI 两种并列的插件页面后端、各自的状态与生命周期，以及共用的 Flutter 组件和样式边界。任务进度只在[实施任务](README.md#实施任务)维护。

## 技术选择

插件按页面选择 TSX 或 A2UI，同一个插件可以同时提供两种页面。TSX 适合函数组件组合、持续局部状态和异步交互；A2UI 适合声明式界面、数据绑定、模板列表与 action 驱动的更新，不是只能静态渲染，也不作为淘汰或兼容后端。

TSX 页面构建时编译成 JS，在 fjs 的 QuickJS 中执行。参考 nsh/nsgo 的组件组合、细粒度响应式、节点操作与 owner 生命周期；响应式图和节点运行时位于紧邻 QuickJS 的 Rust 侧，Flutter 负责布局、绘制、输入、动画和宿主组件。第一版不使用 `solid-js/universal`，不引入 nsh/nsgo 的整套渲染引擎、Go 运行时或平台控件层。

nsh 的 `docs/dev/performance.md` 性能记录中，原生化后同一计数器的 bundle 执行约从 390 μs 降到 95 μs，点击的 JS 阶段约从 14 μs 降到 5 μs。这是其旧 JS/Solid 运行时与原生实现的对照，不能作为 Reveric 的性能承诺。实现必须测量 QuickJS、Rust 到 Dart 的桥接和 Flutter 帧耗时，不能把每次 signal 读写改成异步 Dart 调用。

A2UI 作者维护组件 ID、数据路径和消息；TSX 作者维护组件函数与状态。选择由插件需求决定，两者都复用宿主主题、组件和权限边界；记忆管理验收选择 TSX，用来验证新增的持续交互能力。

### 为什么响应式图放在 Rust

TSX 本身不要求 Solid 或 Rust。依赖追踪、节点管理、更新协调和组件生命周期都可以用 Dart 实现；选型取决于这些工作与 JS 计算函数之间的调用边界。

现有 fjs 的 `bridge_call` 返回 Promise，Dart 调用 JS 的接口返回 Future，见 `third/fjs/libfjs/src/api/engine.rs` 的 `new_bridge_call` 和 `third/fjs/lib/src/frb/api/engine.dart` 的 `call`。它们不能直接承担同步的 signal 读取。若依赖图在 Dart、计算函数在 JS，一次更新可能经过“JS 修改状态 → Dart 找到 computed → JS 计算 → Dart 查找后续依赖 → JS 更新绑定 → Flutter 显示”。批量传输可以合并同一轮的工作，但不能消除依赖链中等待前一次计算结果的往返。

| 方案 | 调用方式与成本 | 决定 |
| --- | --- | --- |
| Dart 依赖图，沿用异步桥 | 计算函数仍在 JS，依赖链需要跨桥调度；逐次 signal 读写还会增加细粒度往返 | 不采用。限制来自现有调用边界，不是 Dart 无法实现响应式算法 |
| Dart 依赖图，新增同步绑定 | 需要改造 QuickJS 与 Dart 的底层接口，处理线程约束、重入和 JS 引用生命周期；不能直接复用现有异步桥 | 不采用。增加底层绑定复杂度，且尚无本项目性能证据 |
| JS 依赖图与计算函数，批量更新 Flutter | 响应式计算在同一个 JS 上下文完成，最终把节点变化批量交给 Dart；可用 Solid，也可自行实现 | 可行备选，维护成本较低，但框架调度仍由 QuickJS 执行 |
| Rust 依赖图与节点运行时，批量更新 Flutter | QuickJS 同线程同步调用原生函数，Rust 在同一运行时内执行 JS 计算函数，完成一轮更新后批量通知 Dart | 当前选择。减少解释器内框架工作与跨 Dart 桥的依赖调度，代价是自行维护 Rust 原生扩展 |

当前选择包含新增 Rust 实现工作，不能理解为仅调用现有 fjs 的 Dart API。Dart 继续管理渲染节点与 Flutter 生命周期，Flutter 负责布局、输入和绘制；依赖图、计算调度和 JS 引用管理留在 QuickJS 所在执行边界内。上述桥接成本是架构判断，尚未在 Reveric 中对这些备选做 A/B 基准，不能承诺具体加速倍数。

## 注册与显示

页面元数据写入 `plugin.json`，不在 `apply` 中注册：

```json
{
  "pages": {
    "character-organizer": {
      "title": { "zh-CN": "人物整理", "en": "Character organizer" },
      "location": "home.plugin",
      "protocol": "reveric-tsx-v1",
      "source": "dist/views/character-organizer.js"
    }
  }
}
```

- `pages` 的对象 key 是插件内唯一的页面 ID；`location` 必填，当前只接受 `home.plugin`，入口显示在宿主插件导航。
- 每个页面必填 `protocol`，Host 直接校验是否支持 `reveric-tsx-v1` 或 `reveric-ui-v1`。TSX 的 `source` 指向插件包内预编译的单文件 JS，最多 2 MB；Host 校验路径、文件类型、大小和协议。页面模块与工具入口分开，激活插件不执行页面模块。
- 页面 `title` 是 `PluginText`，按界面语言选择显示。
- TSX 页面产物是 IIFE，导出到 `__revericView`，包含 `mount(context)`，`context` 为 `plugins/sdk/ui.d.ts` 的 `PageContext`（`ViewContext` 加 `root`、`environment`）。Host 提供只属于当前页面的根节点，`mount` 创建根组件；不再次执行工具入口的 `apply`。
- `ViewContext` 提供 `page`（`viewId`、`instanceId`、`workId`）、`PluginServices`（含私有 `sqlite`）、所在作品的 `chapters` / `characters`、`ui` 和 `view.setDirty`，不提供注册接口，也没有 Agent 请求信息（`request`）。页面只能通过 Host API 访问业务数据，权限逐次检查。字段以 [`plugins/sdk/index.d.ts`](../../../plugins/sdk/index.d.ts) 为准。
- Host 分配页面实例 ID 和会话代次；同一页面可有多个实例，状态互不共享。插件 ID、版本、页面 ID、实例 ID 和代次共同约束消息归属。

```text
TSX 源码 → 构建期转换与打包 → 页面 JS
                                ↓
                  QuickJS 执行组件与事件函数
                                ↕ 同线程原生函数
                  Rust 响应式图、节点与操作队列
                                ↕ 批量更新 / 事件
                  Dart 页面会话、校验与节点树
                                ↕
                  Flutter 宿主组件、输入与绘制
```

## 页面状态

以下状态表和响应式机制适用于 TSX：每个打开的 TSX 页面实例持有一个运行时，直到关闭；工具调用仍按次创建运行时，见[运行时模型](architecture.md#运行时模型)。

| 状态 | 所有者 | 生命周期 |
| --- | --- | --- |
| 草稿、选中项、筛选、加载状态 | 插件组件的 signal；Rust 图持有相应 JS 值与依赖 | 所属组件或页面释放时结束 |
| controller、选区、IME composing、焦点、滚动 | Flutter 组件，沿用 Hooks 与既有控件 | 稳定节点身份对应的 Widget 生命周期 |
| 节点树、事件映射、消息代次、资源计数 | Host 页面会话 | 页面关闭时释放 |
| 作品等业务数据 | Host Service / Orchestrator 与数据库 | 沿用业务规则；宿主 Riverpod 观察业务变化 |
| 跨重开保留的插件数据 | 上下文的 `storage` / `sqlite` | 由插件显式保存，不自动持久化整棵 UI 树 |

插件内部 JS 状态使用 signal，这是插件执行边界内的状态机制；宿主 Dart 的本地编辑态仍使用 Hooks / `lib/third/form`，不新增全局 Riverpod 镜像。A2UI 的页面状态仍由 Host DataModel 持有，见[A2UI 页面](#a2ui-页面与声明式界面)。

### 响应式与异步交互

- SDK 提供 `signal`、`computed`、`effect`、`batch`、`untracked`、`cleanup`。组件函数在挂载时运行一次，动态属性与子区域建立细粒度绑定；相等写入不重复通知。
- TSX 支持函数组件、响应式 props、children / 命名内容插槽、条件区域和按稳定 key 协调的列表。列表移动保留节点与局部状态，移除区域会释放其 owner。重复 key 作为页面错误报告。
- 同一运行时串行执行 JS 片段；事件处理函数等待 Promise 时允许处理其他事件，不等待整个异步任务完成才派发下一个事件。
- SDK 的异步资源绑定跟随 owner：依赖变化时使旧请求失效，只接受最新代次结果；已开始的请求按各 Host API 的取消语义处理；手工 Promise 的拒绝和过期结果也必须受页面生命周期约束。
- 定时器、effect 和订阅归属创建它们的 owner，重跑或销毁时清理。M3 不额外开放全局业务 Event / Hook；异步 Host 返回值、页面交互和宿主环境变化可驱动状态更新。
- 页面通过 `context.view.setDirty(boolean)` 把未保存标记同步到 Host。关闭前由 Host 确认，判断不依赖临时执行 JS。正常关闭运行 cleanup，超时或崩溃时强制释放，不依赖插件合作。

### 输入与并发结果

Flutter 立即显示输入，维护 composing、光标和选择区；JS 事件回传不阻塞本地输入。文本变更携带编辑序号，Host 不用旧序号的响应覆盖新输入；组词期间不应用外部文本替换，组词结束再同步。每次输入不重建 controller。

多字段编辑区使用 `SingleChildScrollView + Column`，混排时放入 `SliverToBoxAdapter`，遵循项目表单生命周期规则。大量只读或选择列表可以虚拟化，不能把编辑字段放入可回收的列表后依赖离屏校验。

## 渲染器与组件目录

### 编译与原生运行时

- 插件作者本地构建 TSX，应用不运行 TSX 编译器。构建工具执行自定义 JSX 转换，再打包为页面 JS；普通 JSX 转成静态对象不足以保留响应式表达式。
- 静态属性只设置一次；动态属性转换为访问器绑定，组件 props 保留 getter，条件和列表创建独立 owner。保留 source map，使编译错误和运行异常能定位 TSX 源码。
- 框架的 signal、owner、节点和事件表由宿主原生模块提供，不随每个页面打包；页面只能引用白名单 SDK 模块，不开放文件、进程、任意外部模块或原生库加载。
- Rust 在 QuickJS 所在线程管理依赖、保留与释放 JS 函数和值；GC 必须能看到节点事件闭包与响应式图引用。所有原生入口校验运行时身份、节点归属和资源上限。
- 首版批量操作包括创建节点、更新属性/文本、插入/移动子节点、移除节点、释放节点和声明事件。节点 ID 在同一会话内不复用；移除与释放分开，列表移动不销毁状态。
- 一轮响应式更新合并为一个有序批次，包含会话代次与递增序号。Dart 先校验整批，再提交节点树；非法节点、循环、未知属性或超限时拒绝整批并停止该页面，不能留下半应用状态。
- Rust 到 Dart 采用类型化批量操作；业务 Host API 继续使用已有 JSON 桥接。JS 不拼整树 JSON，也不逐属性跨 Dart 桥。桥接保留至多一个未确认批次，后续同节点属性写合并；结构变更保持顺序，待发送队列也受上限约束。
- Flutter 按变更节点重建，使用稳定 Key。布局、命中测试、文本测量、滚动和动画由 Flutter 完成，不移植 Taffy、CSS 布局或 nsh 平台绘制层。

### 组件与样式边界

对插件开放布局基础和有宿主外观的控件，允许作者组合自己的业务组件，不提供固定页面模板作为唯一入口。

| 层次 | 首批能力 | 边界 |
| --- | --- | --- |
| 布局 | Column、Row、Wrap、Scroll、Box、Gap、只读 List | 对齐、间距、伸缩、尺寸约束与按可用宽度响应式布局；横向滚动提供桌面鼠标入口 |
| 内容 | Text、Markdown、Icon、Card、Divider、Badge、Loading、EmptyState | 沿用 Reveric 字体、图标、主题、背景与语义色 |
| 输入 | TextField、SearchField、Select、Checkbox、Switch | 沿用宿主输入、键盘、焦点、校验和无障碍行为 |
| 操作与区域 | Button、IconButton、Tabs、Collapsible、Menu、Dialog、Popover | 自定义内容区域和事件；桌面菜单与移动 sheet 按平台适配，不允许越出宿主提供的区域 |
| 作者组合 | 函数组件、children、命名插槽、条件显示、动态列表 | 可实现人物卡片、异步搜索、批量编辑器，不直接传 Flutter Widget |

样式属性使用宿主 token：语义颜色、文字层级、间距、圆角和组件 variant。布局可声明逻辑像素尺寸及最小/最大约束，但不暴露任意内部 Widget 样式覆盖。宿主向页面提供可订阅的可用尺寸、平台、主题和 locale；颜色 token 在 Flutter 解析，深浅色与背景切换自动生效。

不承诺 shadcn React 组件、浏览器 DOM、完整 CSS/Tailwind 或任意 npm UI 库兼容。复杂交互依靠组合与状态实现；新增组件按实际插件需求扩充。动画提供宿主语义能力，避免 JS 每帧驱动样式。

组件名称、属性类型、事件载荷、插槽和样式 token 属于 SDK 契约。类型声明与运行时校验来自同一份组件定义，避免 TypeScript 与 Dart 各手写一套后漂移。

## 生命周期与资源限制

- 打开页面后可保留后台标签页状态；不可见时暂停宿主动画和页面周期定时器，不积压 tick，恢复时按当前环境继续。Android 进入后台时同样暂停；不承诺进程被系统回收后恢复未保存草稿。
- 正常关闭先处理未保存确认；停用、卸载和更新也先处理受影响页面的确认，取消则中止该操作。确认后关闭页面、取消请求、清理订阅并释放运行时。更新期间不混用新 JS 与旧节点树。
- Host 先使会话失效，再释放资源，迟到的事件、批次和请求结果按代次丢弃。已提交业务写入不因页面关闭自动回滚。
- 同步异常可由组件错误边界处理；未捕获异常、资源超限和桥接协议错误显示页面局部错误，保留日志和 TSX 堆栈，不影响其他页面或工具调用。

| 限制 | 初始预算 | 超出行为 |
| --- | --- | --- |
| 单页面 QuickJS 堆 / 栈 | 64 MB / 1 MB | 终止页面，报告 `plugin_memory_limit` |
| 页面首次挂载 | 5 秒 | 终止页面，报告 `plugin_timeout` |
| 每次进入 JS 的连续执行 | 2 秒，不含正常异步等待 | 原生中断执行并终止页面；不能仅靠 Dart Future 超时 |
| 活节点 / 嵌套深度 | 2000 / 32，含列表展开后的节点 | 拒绝批次，报告 `plugin_ui_limit` |
| 单批与待发送队列 | 各最多 1 MB 编码等价大小、4096 条操作 | 拒绝更新并终止页面 |
| 活定时器 / 待完成 Host 调用 | 64 / 32 | 拒绝新建，返回可诊断错误 |
| 页面并发网络请求 | 4，排队占待完成调用预算 | 超过待完成预算拒绝，不无限排队 |
| 打开页面实例 | 同插件最多 2，全应用最多 4 | 拒绝新开，不自动关闭已有编辑页面 |

页面预算与工具的 4 个并发执行槽位分别计算，不能让常驻页面占满工具槽位；进程总内存还包括 Rust 节点、Dart 树和 Flutter 资源。以上是首版防护预算，不是已验证的性能指标，T-21 和 T-16 在三平台记录实际峰值；限额不能替代泄漏检查。常驻页面的网络请求不沿用工具单次执行的累计 50 次限制，以并发和待完成调用预算限制。

## A2UI 页面与声明式界面

现有 `lib/shared/widgets/a2ui/`、`a2ui_core: 0.4.0`、A2UI v1.0 消息与 `reveric-ui-v1` 组件目录用于 A2UI 插件页面、Host 配置表单和只读工具结果卡片。未来 AI 生成界面可以复用这一层，但不作为 M3 交付要求。

- 复用现有 session、组件 builder、预览入口和测试；不把 A2UI DataModel 接到 TSX 页面的状态链中。
- TSX 与 A2UI 复用底层 Reveric Widget、主题和平台交互。A2UI builder 依赖自己的节点和绑定上下文，不能直接充当 TSX builder。
- 配置表单无需运行插件，见[配置与凭据](settings-and-storage.md#配置与凭据)。其校验与凭据规则保持不变。
- A2UI 保留 500 个组件 ID、32 层、单次消息 1 MB 的既有预算。编辑表单遵循不回收字段规则；只读卡片按内容高度布局。

### A2UI 页面注册与事件

在 `plugin.json` 声明页面及事件名称：

```json
{
  "pages": {
    "memory-report": {
      "title": { "zh-CN": "记忆概览", "en": "Memory overview" },
      "location": "home.plugin",
      "protocol": "reveric-ui-v1",
      "source": "views/memory-report.json",
      "onMount": "load",
      "actions": ["load", "refresh"]
    }
  }
}
```

在 `apply` 中按页面 ID 和事件名绑定 handler：

```ts
export function apply(setup: PluginSetup) {
  setup.pages.registerAction("memory-report", "load",
    async (data, event, context) => loadReport(context, data));
  setup.pages.registerAction("memory-report", "refresh",
    async (data, event, context) => loadReport(context, data));
}
```

声明与绑定必须一一对应。缺失、多注册或重复绑定均拒绝；`onMount` 必须引用该页面已声明的 action。

- source 是 A2UI v1.0 消息数组，首条 createSurface，随后 updateComponents/updateDataModel；Host 分配并替换 surfaceId。A2UI 页面不用编译 TSX，打开时不创建常驻 JS 运行时。
- 输入绑定写入 Host DataModel；可选 onMount 在挂载完成后触发一次已注册 action，用于读取初始业务数据。用户事件按页面排队，每次执行创建短生命周期运行时，重新 apply 并核对注册项后调用 action；每个 action 总时长最多 20 秒。
- action 签名为 `(data, event, context)`：派发时的数据快照、事件和该页面的 `ViewContext`（与 TSX 页面相同，没有 `request`）；Host API 从 `context` 取得，不能捕获 `apply` 的 `setup`。返回 A2UI 消息数组，只接受 updateComponents/updateDataModel。允许更新内容和组件结构，不允许创建其他 surface 或替换事件归属；Host 统一补 surfaceId，按页面预算校验后应用。
- action 的输入快照及返回消息各最多 1 MB，堆/栈沿用短运行时的 128 MB/1 MB；不占用 TSX 常驻引擎，但与插件工具共用短任务执行限流。运行时结束不会清空 DataModel。
- 输入变更在 Host 即时显示，不等待 action。action 执行期间页面如果发生新编辑，Host 根据捕获的数据版本拒绝应用过期结果并通知刷新；已提交业务写入不会自动回滚，也不自动重试写动作。关闭后的结果直接丢弃。
- 编辑、dirty 确认、关闭、停用和更新沿用共用页面生命周期；action 的页面上下文可更新 dirty 标记。两种页面可访问同一个插件私有库，但不共享内存状态；A2UI 的连续后台计算交由 Host 定时任务，不借 action 保持无限运行。

## 自定义工具卡片

`display.view` 是包含 `protocol` 和 `source` 的对象，指向包内 A2UI JSON，以工具结果作为只读数据，不启动页面 JS、不触发 action。避免聊天历史每张卡片都持有一个常驻运行时。动态 TSX 交互只在独立插件页面提供。

- 历史卡片使用当前安装版本的界面描述；插件负责兼容旧结果字段。
- 插件卸载、停用、新版本不再提供该描述或渲染失败时，退回[通用卡片](tools.md#工具卡片)。声明 `display.view` 时同时提供通用展示字段，保证退回后仍可读。

## UI 协议与版本

- 页面在 `pages[id].protocol` 声明协议，自定义工具卡片在 `display.view.protocol` 声明协议。Host 分别校验支持范围，缺失或未知协议拒绝；不维护全局协议列表，也不根据文件后缀猜测后端。
- `reveric-ui-v1` 表示 A2UI v1.0 消息和 Reveric 组件目录；`reveric-tsx-v1` 表示 TSX 编译产物、原生 SDK 和节点更新契约。它们是并列协议，各自独立演进，没有新旧替代关系，也不隐含包含对方。
- `display.view` 是只读 A2UI 卡片入口，必须写成 `{ "protocol": "reveric-ui-v1", "source": "views/result.json" }`，并同时声明通用 `display.result`。独立页面可任选后端；卡片暂不执行 TSX 是生命周期和资源范围选择，不是 A2UI 的能力限制。
- 每个页面实例固定一种后端，不混合两种节点树；不同页面共用插件身份、业务能力、数据库与宿主 Widget。UI 协议与业务 API 分别版本化，兼容新增能力不升主版本，破坏性变化使用对应后端的新协议版本。
- 协议声明由具体页面和卡片持有，不改变 A2UI 协议内容，也不兼容旧的插件级协议字段。既有 ADR 的适用关系以 [README](README.md#既有-adr-的适用关系) 为准，历史记录保持原样。

## 实现范围与交付

实现涉及 SDK 构建工具、QuickJS 原生扩展、Host 会话、Flutter 渲染、组件适配和三平台验证，预计超过 8 个文件。沿用 `plugins/sdk`、现有插件构建脚本、`third/fjs` 的原生接入边界、`lib/shared/services/plugins/` 与 `lib/shared/widgets/` 的职责划分；原生扩展落点按下文 fjs 接入规格和本地依赖规则执行，不引入第二套 JS 引擎。

T-21 交付可独立运行的 TSX 动态预览与回归测试，覆盖编译、响应式、桥接、组件和清理；T-13 按协议将两种页面会话挂入导航；T-15 接入 A2UI action、临时 UI 与只读卡片；T-24 交付记忆插件的 Tools、Prompt、TSX UI 和定时整理，T-16 验收该闭环。人物整理仅作为宿主业务 API 的独立样例。工具与配置功能不依赖 TSX 完成。新增运行时不会迁移业务数据；关闭动态页面能力可停止加载 TSX，保留配置表单、工具调用与通用卡片。

## TSX SDK 与编译契约

模块名固定为 `reveric/ui`，类型声明放在 `plugins/sdk/ui.d.ts`；编译器内部调用 `reveric:ui-runtime`，该模块只有 Host 提供的原生实现。SDK 不包含浏览器 DOM 或 React/Solid 运行时。

```ts
type Dispose = () => void;
type Accessor<T> = () => T;
interface Signal<T> {
  (): T;
  set(value: T): void;
  update(updater: (previous: T) => T): void;
}
interface Resource<T> {
  value: Accessor<T | undefined>;
  loading: Accessor<boolean>;
  error: Accessor<unknown | undefined>;
  refetch(): void;
  dispose(): void;
}
declare function signal<T>(initial: T): Signal<T>;
declare function computed<T>(read: () => T): Accessor<T>;
declare function effect(run: () => void): Dispose;
declare function batch<T>(run: () => T): T;
declare function untracked<T>(run: () => T): T;
declare function cleanup(run: Dispose): void;
declare function resource<K, T>(source: Accessor<K>, load: (key: K) => Promise<T>): Resource<T>;
declare function mount(view: () => UiNode, root: UiRoot): Dispose;
```

UiNode/UiRoot 是 SDK 的不透明句柄，不能由插件拼 JSON 构造；只有 Host 提供页面根。Signal 默认使用 JS 严格相等判断，直接修改对象内部字段不会触发更新，需要 set 新值。computed 延迟求值并缓存；effect 首次挂载后及依赖变更后运行；cleanup 在 effect 重跑前或 owner 销毁时运行，dispose 可重复调用。async effect 不作为响应式入口，异步加载使用 resource 或显式事件函数。

resource 保留最近成功值，loading/error 分别更新；每次 source 变化或 refetch 递增代次，只接收最新结果，dispose 后不写 signal。失效会丢弃结果，不承诺取消已经开始的 SQLite 或网络操作；页面关闭按 Host 调用的取消语义处理。禁止在 Rust 借用图期间 await JS Promise。

### 控制流与组件

- `If`：`when: boolean`、可选 `fallback: UiNode`、`children: UiNode`，切换时创建/销毁分支 owner。
- `Each<T>`：`items: readonly T[]`、`key: (item: T) => string`、`children: (item: Accessor<T>, index: Accessor<number>) => UiNode`。同 key 保留节点，item/index 改为新值；重复 key 报错，禁止以数组下标冒充会重排列表的稳定身份。
- 函数组件接收只读 props，动态 prop 和 children 保留 getter。组件运行一次，不支持通过解构 props 自动保留响应式；动态读取在绑定/computed 中访问 props。
- 事件签名为 `(event) => void | Promise<void>`；拒绝 Promise 时交给页面错误处理，不重试用户写入。原生事件不包含 BuildContext、controller 或任意平台对象。

### 首批属性表

所有节点支持 `key?: string`、`testId?: string`、`accessibleLabel?: string`；key 用于协调，testId 只用于定位。未知属性拒绝。缺省值由 schema 生成，不靠各端猜测。

| 组件 | 属性与默认值 | 事件/内容 |
| --- | --- | --- |
| Column / Row | gap=md；align=start（start/center/end/stretch）；justify=start（start/center/end/spaceBetween）；子节点 flex=0 | children |
| Wrap | gap=md、runGap=md、align=start | children |
| Box | padding=none、surface=transparent、radius=none；width/height/minWidth/maxWidth/minHeight/maxHeight 可选非负逻辑像素 | 单一 child |
| Scroll | direction=vertical（vertical/horizontal）、maxHeight 可选 | 单一 child；controller 由 Host 持有 |
| Gap | size=md | 无 |
| List<T> | items、key、itemExtent 必填正数，height 必填正数 | `renderItem(item, index)`；可见区与 overscan 索引由 Flutter 推送，按 key 创建/回收 owner；仅只读条目，不承载编辑字段 |
| Text / Markdown | text 必填；Text 的 variant=body（body/caption/heading）、tone=default、maxLines 可选正整数 | 无；Markdown 链接沿用 Host 打开规则 |
| Icon | name 必填，size=standard（small/standard/large）、tone=default | 无 |
| Card | padding=lg | child；外观继承宿主卡片 |
| Divider | direction=horizontal | 无 |
| Badge | text 必填、tone=default | 无 |
| Loading / EmptyState | label 可选；EmptyState 的 message 必填 | EmptyState 可选 actions 插槽 |
| Button | label 必填、variant=secondary（primary/secondary/text/danger）、size=standard（standard/prominent/compact）、disabled=false、loading=false、icon 可选 | onPress；不允许任意覆盖内部样式 |
| IconButton | icon、tooltip 必填；disabled=false | onPress |
| TextField / SearchField | value 必填字符串、label/placeholder/error 可选、disabled=false；TextField multiline=false；SearchField debounceMs=300 | `onChange({value, editRevision})`；`onSubmit({value, editRevision})`；本地输入立即显示，SearchField 只对回调防抖 |
| Select | options: `{value: string, label: string, disabled?: boolean}[]`；value: string 或 null；disabled=false | onChange({value}) |
| Checkbox / Switch | value 必填布尔、label 可选、disabled=false | onChange({value}) |
| Tabs | items: `{id, label}[]`、value 必填 | onChange({value})；content: (id:string)=>UiNode，只挂载当前项；业务草稿放在 Tabs 外的 owner |
| Collapsible | title、open 必填 | onOpenChange({open})、children |
| Menu | items: `{id, label, disabled?: boolean, danger?: boolean}[]` | trigger 插槽、onSelect({id})；桌面菜单与移动 sheet 由 Host 适配 |
| Dialog | open、title 必填 | onOpenChange({open})、body/actions 插槽；同页最多一个 modal |
| Popover | open 必填 | onOpenChange({open})、trigger/body 插槽；关闭事件由 Host 发出 |

间距枚举为 none/xxs/xs/sm/md/lg/xl/x2l/x3l/x4l，映射现有 RevericSpacing；tone 为 default/muted/accent/success/warning/danger，映射语义颜色；surface 为 transparent/base/elevated，radius 为 none/small/medium/large/card。文字层级和图标尺寸在 Flutter 中映射宿主 token，不在 JS 写颜色数值。theme/platform/locale/viewport 作为只读环境 accessor，由 Host 推送；viewport 为当前页面可用区域，不是屏幕分辨率。

组件定义的唯一源为计划文件 `plugins/sdk/ui.schema.json`，生成 ui.d.ts、Dart 属性解码定义与 Rust 事件/属性枚举；Flutter builder 单独手写。生成产物提交仓库，CI 不安装 Node。布局与组件表是 TSX 契约，A2UI 继续使用自己的 Catalog Schema，两者不强行统一属性名称。

### 编译实现

使用现有 TypeScript 5.9.3 Compiler API 与 esbuild 0.25.12，不增加 Oxc、Babel 或 Solid 依赖。计划文件 `plugins/sdk/tsx_transform.mjs` 对 TSX AST 转换，接入现有 `plugins/build.mjs` 的 esbuild onLoad；TypeScript 检查 JSX 类型后，转换器生成普通 JS，再由 esbuild 打包 IIFE 与 source map。

只接受 PascalCase 导入或局部组件标签；通过 TypeScript symbol 解析别名和作用域，不能按变量名字符串替换。字面量属性静态设置，其他值生成访问器绑定；onX 回调保存为函数引用，不能作为计算执行。组件调用包在 untracked 中，动态 props 使用 getter；children/插槽延迟构造以归属实际挂载 owner。If/Each/List 转成专用运行时调用。单纯配置 jsxFactory 不满足这些语义。

`plugins/<name>/src/views/*.tsx` 每个入口导出 `mount(context)`，构建为 `dist/views/<name>.js` 与同名 map；在构建配置中显式列出入口，不执行插件 apply 来发现页面。A2UI 文件与 migration 原样打包。开发工具只在作者本地运行，应用只加载 JS/JSON/SQL 产物。

## 节点批次与事件协议

这是 reveric-tsx-v1 内部传输契约，通过 flutter_rust_bridge 的类型化 DTO 编解码，不对 JS 开放直接发送操作的入口。

```ts
type NodeId = number; // 正整数，不超过 JS 安全整数范围；同会话不复用
type UiValue = null | boolean | number | string | UiValue[] | { [key: string]: UiValue };
type UiOp =
  | { kind: "create"; id: NodeId; component: string }
  | { kind: "set"; id: NodeId; props: Record<string, UiValue>; unset: string[]; editRevision?: number }
  | { kind: "insert"; parent: NodeId; child: NodeId; slot: string; before: NodeId | null }
  | { kind: "remove"; parent: NodeId; child: NodeId; slot: string }
  | { kind: "listen"; id: NodeId; event: string; handler: number | null }
  | { kind: "release"; id: NodeId };
interface UiBatch { surface: string; generation: number; seq: number; ops: UiOp[] }
interface UiEvent {
  surface: string;
  generation: number;
  seq: number;
  node: NodeId;
  handler: number;
  event: string;
  payload: UiValue;
}
```

- 文本是 Text 节点的 text 属性，不另设 Flutter 文本句柄。函数、signal 和原生资源不能进入 UiValue；非有限数字、超深对象和超额载荷拒绝。
- 根节点由 Host 分配，永不 release。create 先创建脱离树的节点；insert 可在同父或跨父移动已有节点，before 必须属于目标 slot，null 表示追加；remove 只脱离，release 只允许无父且无子节点的叶节点，销毁子树按后序发送。
- slot 只能为组件 schema 声明的 children/child/body/actions/trigger 等；每个 slot 的基数同时校验。set 只替换给出的属性，unset 恢复缺省值；不能修改组件类型。修改类型要创建新节点。
- Dart 按操作顺序在暂存结构中验证归属、循环、节点计数与 schema，整批成功后一次通知 Flutter，再返回 ack(seq)。seq 从 1 连续递增；重复批次只回相同 ack，不重复应用；缺号或非法批次终止该页面，禁止继续尝试修补树。
- Rust 同时最多一个未 ack 批次；后续属性更新可合并，结构变更保持顺序。ack 前已经可见的节点仍可发事件。UiEvent.seq 表示事件基于哪个已提交批次；handler ID 在会话内单调递增，替换后旧 handler 的迟到事件丢弃，不能误投给新函数。
- TextField 回传 editRevision，Rust 在对应 onChange 调用开始更新该节点已观察的编辑序号，后续 value 更新携带该序号；Dart 拒绝小于本地编辑序号的回写。异步搜索/校验使用 resource 代次防止旧结果写 signal，不能仅靠输入序号解决业务请求竞态。
- List 使用内部 viewport 事件 `{first,count}`，Host 按 itemExtent 计算可见区并加前后各两行 overscan；变化只刷新受影响区间。初次布局前不创建全量行，滚动位置保留在 Flutter，编辑表单不用 List。

## nsh 复用与 fjs 接入规格

复用基线固定为 nsh commit `201d780a9339b886ac87c741d3d4fd8fb64e1d30`，实施时从该 commit 读取文件，不跟随本地工作区或浮动 main。保留其 Apache-2.0 许可、文件来源与修改记录；不直接依赖整个 nsh-core/nsh-js crate。

| 上游部分 | 本项目落点 | 处理 |
| --- | --- | --- |
| nsh-core/src/reactive.rs 及 reactive/tests.rs | third/fjs/libfjs/src/ui/reactive.rs 与对应 tests | 提取通用 Graph/Host 算法和测试，保留 owner、调度、重入与释放语义 |
| nsh-js/src/reactive.rs | third/fjs/libfjs/src/ui/bindings.rs | 适配现有 fjs rquickjs API、JS 引用标记、异常与 cleanup；去掉 nsh resource/state 依赖 |
| nsh-js/src/dom.rs 的 reconcile、cond、each | third/fjs/libfjs/src/ui/nodes.rs | 提取节点身份和 keyed 协调，改为本方案 UiOp 输出；不复制平台、样式、Canvas 或布局代码 |
| nsh 的 JSX 转换语义及测试场景 | plugins/sdk/tsx_transform.mjs 与其测试 | 用现有 TypeScript AST 实现，复用语义测试用例，不移植 Oxc/rolldown 编译链 |

nsh 基线使用 quickjs-jit 0.14.1；fjs 使用 rquickjs revision `3d5ecfc94e3f9ea3a9769422ca718a7dd063e00f`。保持 fjs 的依赖与 Cargo.lock，不同时链接两套 QuickJS，也不认为两个包的底层 JSValue ABI 可互换。

### 执行与生命周期

现有 fjs `runtime/executor.rs` 是两条 Tokio worker 线程，不能直接挂入 nsh 的线程局部图。新增 `api/ui.rs` 的 UiSession API 和 `ui/session.rs`：每个 TSX surface 用一条专属 OS 线程，在线程内创建、使用和销毁同步 rquickjs Runtime/Context。它仍使用 fjs 已锁定的同一 QuickJS 引擎库；工具、A2UI action、Prompt 和任务继续使用现有 JsEngine 路径。

Dart 可调用的 UiSession 方法固定为 start（source、scope、初始 environment）、dispatch（UiEvent）、replyHost（callId、结果/错误）、ackBatch、setEnvironment、close；输出流只有 batch、hostCall、error、closed 四类。原生句柄只留在线程内，Dart 只持 session ID 和可发送命令的句柄；通道断开也进入关闭流程。

- UiSession 在该线程维护 SDK 定时器与 Promise job 泵，不安装 Node 定时器或文件/网络 builtins；空闲时等待命令或最近到期定时器，隐藏时暂停周期任务。
- UiSession 的命令队列有界（最多 256 条命令或 1 MB 载荷）；输入更新可按节点合并，点击/提交不丢弃，队列满时报告页面繁忙并停止接收新事件。单轮执行、Promise jobs 和输出 flush 均在专属线程，线程不等待 Dart 执行业务调用。
- Host API 在 JS 返回 Promise，Rust 保存该 callId 的 resolver 并发送 hostCall；replyHost 在同线程 resolve/reject，然后执行 Promise jobs。队列等待期间不持图借用；循环以时间片处理 jobs，原生 interrupt handler 同时检查关闭标记与该轮 2 秒截止时间，避免无限微任务绕过截止。
- 状态通过 context userdata 与原生类对象所持状态句柄定位，不覆盖 rquickjs 已用的 opaque 内部指针，不复制 nsh 的全局线程映射。GC mark 遍历事件闭包和 signal/memo 值，finalizer 只访问仍活着的会话状态；禁止为了跨线程把 Rc 图标成 unsafe Send。
- close 先由 Dart 使 surface generation 失效并拒绝新 Host 请求，再设置原生关闭标记；正常清理最多使用一次执行预算，失败强制 teardown。取消未完成 Host 调用，释放 resolver、事件、owner 和节点，最后销毁 Context/Runtime 并结束线程。Dart 不同步阻塞 UI 等待线程 join。
- UI 原生扩展在 third/fjs 的本地补丁记录中单列，工具引擎行为不变。专属线程、GC 和 API 兼容属于 T-21 的实际编译与测试验收，不把源码核查当成已经验证。
