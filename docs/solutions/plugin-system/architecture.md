# 插件组成、运行时与上下文 API

> 本篇定义插件包、清单、运行时模型和插件可调用的 Host API。工具相关规则见[工具扩展点](tools.md)，存储与设置见[设置与存储](settings-and-storage.md)。任务进度只在[实施任务](README.md#实施任务)维护。

## 插件由什么组成

| 内容 | 职责 |
| --- | --- |
| 插件清单 | 声明稳定 ID、名称、版本、宿主 API 版本要求、入口、默认启用状态、支持平台、权限、配置字段、设置操作、页面与任务元数据 |
| 入口实现 | 打包为单文件的 JS，导出 `apply(setup)`，向 Host 注册能力和处理函数 |
| 可选资源 | 预编译 TSX 页面 JS、A2UI 页面/卡片描述、图标及其他插件资源 |

清单中的配置和权限可以在执行插件前读取，用户因此可以先查看权限、填写 API Key，再启用插件。工具和动态 Prompt 继续在 `apply` 中完整注册；页面、任务与设置操作的元数据由清单提供，入口只绑定需要执行的 handler。TSX 页面通过独立的 `mount` 入口加载，不在 `apply` 中注册。

内置插件和第三方插件使用同一种包格式。内置插件包随应用资源打包，第三方插件包由用户以 zip 安装；两者共用插件身份、注册归属、配置、权限、启停规则和存储，Host 不为内置插件另设代码路径。聊天页面和业务代码只通过注册表访问插件能力，不直接依赖某个内置插件。

### 清单结构

清单是插件包根目录下的 `plugin.json`：

```json
{
  "id": "example.search",
  "name": "Example 搜索",
  "description": "通过 Example API 搜索网页",
  "version": "1.2.0",
  "author": "someone",
  "pluginApiVersion": "^1",
  "main": "dist/index.js",
  "defaultEnabled": false,
  "platforms": [
    "windows",
    "macos",
    "android"
  ],
  "permissions": [
    "characters.read",
    "characters.write"
  ],
  "settings": {
    "fields": {
      "apiKey": {
        "type": "secret",
        "title": "API Key",
        "required": true
      },
      "maxResults": {
        "type": "integer",
        "title": "默认结果数量",
        "default": 5,
        "min": 1,
        "max": 20
      }
    },
    "actions": {
      "verifyApiKey": {
        "title": "验证 API Key",
        "requires": [
          "apiKey"
        ]
      }
    }
  },
  "pages": {
    "manage": {
      "title": "管理",
      "location": "home.plugin",
      "protocol": "reveric-tsx-v1",
      "source": "dist/views/manage.js"
    },
    "report": {
      "title": "报告",
      "location": "home.plugin",
      "protocol": "reveric-ui-v1",
      "source": "views/report.json",
      "actions": [
        "load",
        "refresh"
      ],
      "onMount": "load"
    }
  },
  "tasks": {
    "refresh": {
      "title": "刷新缓存",
      "intervalMinutes": 60
    }
  }
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `id` | 是 | 稳定标识，反向域名格式，匹配 `^[a-z0-9]+(\.[a-z0-9-]+)+$`；更新时据此识别同一插件 |
| `name` | 是 | 设置页展示名称，`PluginText`（字符串或按语言提供的对象） |
| `description`、`author` | 否 | 设置页展示信息；`description` 为 `PluginText` |
| `version` | 是 | semver，更新时比较新旧版本 |
| `pluginApiVersion` | 是 | 依赖的 Host API 主版本范围，规则见 [ADR-0009](../../adr/0009-plugin-capability-api-versioning.md)；不在支持范围内拒绝加载 |
| `main` | 是 | JS 入口，相对插件目录，单文件，不超过 2 MB |
| `defaultEnabled` | 否 | 首次登记时是否开启，默认 false |
| `platforms` | 否 | 支持的平台，取值 `windows`、`macos`、`android`；省略表示全部支持 |
| `permissions` | 否 | 业务数据读写及 `ai.generateText` 模型调用权限，安装时展示给用户确认 |
| `database` | 否 | 私有 SQLite 的版本与迁移文件序列，见[插件私有 SQLite](settings-and-storage.md#插件私有-sqlite) |
| `settings.fields` | 否 | 配置字段，Host 据此生成表单，见[配置与凭据](settings-and-storage.md#配置与凭据) |
| `settings.actions` | 否 | 设置页操作（如验证 API Key），处理函数在 `apply` 中用 `setup.settings.registerAction` 注册，见[设置页操作](settings-and-storage.md#设置页操作) |
| `pages` | 否 | 按页面 ID 索引的声明；`title`、`location`、`protocol`、`source` 必填，当前位置为 `home.plugin`；A2UI 可声明 `actions` 和 `onMount`，见[页面声明与显示](views.md#注册与显示) |
| `tasks` | 否 | 按任务 ID 索引的元数据，包含 `title` 和整数 `intervalMinutes`（15 至 10080）；代码通过 `setup.tasks.register(id, handler)` 绑定处理函数 |

约定：

- 未使用的 `settings`、`pages`、`tasks`、`database` 可省略。页面和任务的对象 key 就是 ID，不在条目中重复写 `id`。
- `settings.actions`、`tasks` 和 A2UI 页面的 `actions` 与 handler 必须一一对应；缺失、多注册或重复绑定均拒绝。TSX 页面不声明 `actions` 或 `onMount`。
- 页面和自定义工具卡片各自声明协议；普通工具预览无需声明协议。清单不再接受顶层 `uiProtocols`、`uiProtocol`、`actions` 或 `views`，旧版平铺 `settings` 也不兼容。
- 网络请求不属于权限，不需要声明。
- 权限名采用 `资源.read`、`资源.write` 形式，业务数据权限为 `chapters.read`、`chapters.write`、`characters.read`、`characters.write`，只作用于当前作品，见[业务数据 API](#业务数据-api)；M3 增加 `ai.generateText`，用于会产生模型用量的后台生成。
- `name`、`description`、设置字段的 `title` / `description` / 选项 `label`、操作 `title`，以及清单中的页面标题、任务标题（每种语言最多 200 字符）和 `ToolDisplay.title` 都是 `PluginText`：字符串对所有语言显示，对象按语言标签提供多份，Host 依次取当前界面语言、zh-CN、en、第一项。插件页面内部的文案由插件自行处理。
- 当前平台不在 `platforms` 中时，插件可以安装和登记，但不运行 `apply`，设置页显示“当前平台不支持”，不改变用户的启停选择。
- 普通未知顶层字段忽略；上述已移除字段明确拒绝。`settings` 只接受 `fields` 和 `actions`。已知字段类型错误、未知平台或页面协议、页面位置缺失或非 `home.plugin`、入口越界时，清单无效，插件不加载。
- 内置联网检索插件的清单见[联网检索插件](web-plugin.md#插件清单)。

## Host 与插件如何交互

插件上下文提供三个方面的能力：

| 方面 | 插件做什么 | Host 做什么 |
| --- | --- | --- |
| 业务 API | 读取或修改章节、人物，发起网络请求 | 校验权限和业务规则，执行并返回结果 |
| 能力注册 | 注册 Tool、Prompt，绑定清单声明的任务与操作 | 保存注册信息，在相应位置展示或调用 |
| 回调订阅 | 订阅事件，注册明确的业务 Hook | 在已实现的业务节点派发回调（后续迭代） |

```text
Host 激活插件
  → 读取并校验清单中的配置、页面和任务声明
  → 新建运行时，执行插件代码
  → 调用 apply(setup)，注册项先在 JS 内登记
  → apply 结束后一次性把全部注册项上报 Host
  → Host 核对声明与 handler，校验注册项并保存激活快照
  → 从清单发布页面并登记任务调度
  → 关闭运行时

用户或 Agent 发起工具调用
  → Host 在注册表中找到注册项
  → 检查插件状态及调用权限
  → 新建运行时，重新执行 apply 取得处理函数
  → 上报完整注册项，Host 核对清单及激活快照；不一致则拒绝执行
  → 以该阶段的上下文调用处理函数，插件按需调用 Host API
  → 返回结果，关闭运行时

用户打开插件页面
  → 读取清单 pages，检查插件可用性与页面协议，创建页面会话
  → TSX 直接加载页面 JS 并调用 mount，不调用 apply
  → A2UI 加载消息；onMount 或事件执行时新建运行时，调用 apply 绑定 action
  → 页面关闭后清理资源，关闭运行时
```

`apply(setup)` 只负责注册当前插件的能力：`setup` 只有 `tools`、`prompts`、`tasks`、`pages.registerAction`、`settings.registerAction` 和 `log`，没有网络、存储、数据库或业务数据 API，因此 `apply` 中不能发起搜索、生成内容或读写数据。各处理函数收到自己阶段的上下文，Host API 只从该上下文取得，见[插件上下文 API](#插件上下文-api)。业务 Event / Hook 留待后续扩展。
注册只能在 `apply` 执行期间完成；`apply` 结束后再调用注册接口直接报错。插件能力变化通过停用、重新启用或更新版本生效，不支持运行中动态增删注册。

插件通过桥接调用业务 Host API，输入输出都是 JSON；SQLite 的 bigint/BLOB 由 SDK 编为带类型标签的 JSON，不改变其他 API 的 JSON 契约。TSX 的响应式图与节点操作在原生侧执行，以类型化批次交给 Dart，见[渲染器](views.md#渲染器与组件目录)。Host 从运行时绑定的插件身份判断归属和权限，不信任插件在参数里自行声明的身份或权限。插件不持有 Drift、Riverpod、BuildContext 等宿主内部对象。

## 扩展点

下面列的是扩展能力，而不是互斥的插件类型。Host 只接受已实现的扩展点和挂载位置，调用未实现的注册接口时 `apply` 报错。

| 扩展点 | 插件提供 | Host 的调用时机 | 交付 |
| --- | --- | --- | --- |
| Tool | 静态工具定义、展示方式与处理函数 | Agent 发起工具调用时 | M1，见[工具扩展点](tools.md) |
| View | 清单 `pages` 声明页面；A2UI 通过 `setup.pages.registerAction(pageId, name, handler)` 绑定事件 | 用户打开对应页面时 | M3，见[自定义 View](views.md) |
| Prompt | 提供方 ID 与只读处理函数 | 每次模型请求准备时 | M3，见[请求级 Prompt](prompts-and-tasks.md#请求级-prompt-提供方) |
| Task | 清单 `tasks` 声明标题与周期；`setup.tasks.register(id, handler)` 绑定函数 | Host 到期或用户立即运行 | M3，见[Host 定时任务](prompts-and-tasks.md#host-定时任务) |
| 设置页操作 | 清单 `settings.actions` 中声明的操作的处理函数 | 用户在设置页执行操作时 | 见[设置页操作](settings-and-storage.md#设置页操作) |
| Command | 命令 ID 与处理函数 | 用户动作或插件界面触发时 | 后续迭代 |
| Provider | 模型、认证及请求处理能力 | 获取模型、登录、发起 AI 请求等节点 | 后续迭代 |
| 菜单入口 | 显示位置、标题和目标命令 | 用户打开菜单及点击入口时 | 后续迭代 |
| Event、Hook | 指定业务节点的处理函数 | 业务操作前后 | 后续迭代，见[Event 与 Hook](prompts-and-tasks.md#event-与-hook) |

配置表单来自清单，Host 的插件设置页在插件未启用时也可展示，不依赖 `apply` 或页面加载。

### 注册归属与释放

每项注册归属一个插件。Host 校验重复 ID、名称格式、工具名冲突和挂载位置，校验失败时整个 `apply` 视为失败，本次注册全部不生效，其他插件继续运行。工具名冲突规则见[工具名与覆盖](tools.md#工具名与覆盖)。

停用前先按[页面生命周期](views.md#生命周期与资源限制)确认未保存编辑；用户取消则不改变启用状态。确认后 Host 拒绝新调用，移除注册项并关闭页面及其请求。已开始的独立工具调用允许完成，结果照常返回，其运行时在调用结束时关闭；停止新任务派发，取消正在运行的定时任务与未完成的 Prompt 提供方。数据库连接在全部已接手操作结束后释放，不删除数据。

短生命周期工具调用不提供跨调用清理回调。TSX 页面有独立 owner 与 `cleanup`，A2UI 页面由 Host 管理 DataModel 与 action 队列，关闭时释放绑定、定时器、订阅和请求；超时或异常时 Host 可强制关闭，不依赖 cleanup 成功。插件停用后不能继续注册能力，旧页面消息按会话代次丢弃。

## 运行时模型

### 工具按次执行，页面按实例存活

本节描述当前实现。业务插件共用常驻 fjs 引擎属于 T-30，尚未实施，见[后续迭代](README.md#后续迭代)。

插件代码运行在 fjs（QuickJS）中。激活和工具调用按次创建运行时，TSX 页面按打开的实例创建运行时，A2UI 按 action 创建运行时；两者不共享 JS 内存或执行队列：

| 执行 | 时机 | 内容 |
| --- | --- | --- |
| 激活 | 插件启用、应用启动、插件更新后 | 执行入口文件，调用 `apply` 收集注册项 |
| 工具调用 | Agent 每次调用插件工具 | 执行入口文件，调用 `apply` 取得处理函数，再调用对应处理函数 |
| 设置页操作 | 用户执行清单声明的操作 | 新建运行时，执行 apply 后调用 `registerAction` 注册的处理函数，执行结束关闭 |
| Prompt 提供方 | 每次模型请求准备 | 新建运行时，执行 apply 后调用只读 handler，完成或超时关闭 |
| 定时任务 | 到期或手动触发 | 新建运行时，执行 apply 后调用任务 handler，完成、超时或取消时关闭 |
| A2UI action | 挂载或用户交互 | 按次执行并关闭，数据和组件状态由 Host 页面会话保存 |
| TSX 页面 | M3 中用户打开页面 | 执行页面模块并挂载，保留至页面关闭；交互与异步任务复用该实例 |

工具处理函数不能跨运行时保存，每次工具调用重新执行 `apply`；TSX 页面模块独立挂载，不重新执行工具入口；A2UI action 按次重新 apply 取得处理函数。由此要求：

- `apply` 必须是确定的：同一版本插件每次注册的名称和定义相同。每次 `apply` 后都把完整注册项交给 Host；Host 核对清单声明和激活快照，不一致时拒绝执行，快照不一致返回 `plugin_registration_mismatch`。
- 工具不能依赖调用之间的内存状态；少量持久化数据写入上下文的 `storage`，结构化数据使用 `sqlite`。TSX 页面局部状态由组件 signal 持有，A2UI 使用 Host DataModel；Host 管理节点树与输入状态；TSX 更新不传整页快照，A2UI action 接收数据快照，见[页面状态](views.md#页面状态)。
- 一次调用内可以并发发起多个 Host API 请求，例如同时抓取多个网页。

运行时沿用 codemode 的接入方式（见 [codemode/runtime.dart](../../../lib/shared/services/ai/codemode/runtime.dart)）：

- `JsBuiltinOptions.none()`，不开放 fjs 的文件、网络、进程等内置模块或任意外部模块；工具和页面入口各自打包为单文件。页面只额外开放宿主实现的 UI 原生 SDK。
- 业务 Host API 通过一个桥接函数传递 JSON 字符串；Host 校验请求类型、字段和大小。页面 UI 使用独立的类型化批量通道，不能在 JS signal 读写时往返 Dart。
- 短生命周期执行先加载前置脚本与插件入口，再调用 `apply`；TSX 页面执行先安装 UI 原生 SDK 和页面上下文（`PageContext`），再调用独立页面模块的 `mount`；A2UI action 复用按次执行入口。

短生命周期执行的业务桥接消息为带 `kind` 的 JSON 对象，Host 只接受下表中的类型。TSX 页面只开放业务 `call`，UI 更新与事件走[页面协议](views.md#渲染器与组件目录)，不使用 `result` 结束每次点击：

| kind | 方向 | 内容 |
| --- | --- | --- |
| `register` | 插件 → Host | 每次 `apply` 结束后上报工具、Prompt 定义（不含函数）、任务 ID、页面事件名称和设置操作名；Host 核对清单，再与激活快照比较 |
| `mismatch` | 插件 → Host | 调用时 JS 找不到对应 handler，Host 以 `plugin_registration_mismatch` 结束本次执行 |
| `call` | 插件 → Host | 一次 Host API 调用：方法名（如 `http.fetch`）和参数；Host 返回结果或 `PluginHostError` |
| `log` | 插件 → Host | 一条日志，不等待 Host 回应 |
| `result` | 插件 → Host | 处理函数的返回值或未捕获异常，结束本次执行 |

处理函数本身留在 JS 中，前置脚本按注册名保存，Host 通过执行脚本传入名称和输入来调用。
### 入口约定

工具入口文件打包为 IIFE，把导出对象挂在全局变量 `__revericPlugin` 上，至少包含 `apply` 函数。页面使用独立的 `__revericView.mount(context)` 入口，见[注册与显示](views.md#注册与显示)。内置插件的打包方式见[构建与打包](web-plugin.md#构建与打包)，第三方插件用相同约定。

### 资源限制

下表约束激活和工具执行；Prompt 与定时任务分别使用[请求预算和任务预算](prompts-and-tasks.md#请求级-prompt-提供方)，常驻页面使用独立的[页面预算](views.md#生命周期与资源限制)，不占用工具执行槽位。

| 限制 | 取值 | 超出时 |
| --- | --- | --- |
| 入口文件大小 | 2 MB | 清单无效 |
| 堆内存 | 128 MB | `plugin_memory_limit` |
| 栈 | 1 MB | `plugin_memory_limit` |
| 激活执行总时长 | 5 秒 | 激活失败 |
| 工具调用总时长（含等待 Host API） | 60 秒 | `plugin_timeout` |
| 单个工具输入 | 256 KB | `invalid_argument` |
| 单个工具结果 | 256 KB | `plugin_invalid_result` |
| 单次执行中同时进行的网络请求 | 4 个，多余的排队 | 不报错 |
| 同一插件同时进行的执行 | 4 个，多余的排队 | 不报错 |

短运行时的执行数限制用于控制 Android 上的内存峰值：每个短运行时最多 128 MB，四个并发即 512 MB；常驻 TSX 页面仍使用独立的 64 MB 堆预算。M1 的 T-01 会实测运行时创建耗时和内存，数据不达标时调整取值并更新本表。

### 取消

取消和超时都直接关闭运行时：未完成的 Host 调用不再返回，插件代码不再继续执行，处理函数不需要也无法轮询取消状态。Agent 取消工具调用时，Host 中止该次执行发起的网络请求，并按现有约定返回取消结果；已经发出的请求不保证对方未收到。相关写入应放在同一个 `sqlite.transaction` 中，中断后数据仍保持一致。

## 插件上下文 API

插件可见的 TypeScript 类型随 `plugins/sdk` 提供。[`plugins/sdk/index.d.ts`](../../../plugins/sdk/index.d.ts) 的声明与注释是插件与 Host 之间唯一的接口合同，字段、取值范围、时间限制和错误码以它为准，本文不重复字段列表；`plugins/sdk/index.js` 提供运行时的 `PluginError`，`plugins/sdk/ui.d.ts` 提供 TSX 页面的 `PageContext`（`ViewContext` 加 `root`、`environment`）。

上下文按阶段划分，每个处理函数只拿到本阶段可用的能力：

| 阶段 | 类型 | 主要内容 |
| --- | --- | --- |
| 注册 | `PluginSetup`（传给 `apply`） | `tools.register`、`prompts.register`、`tasks.register(id, handler)`、`pages.registerAction`、`settings.registerAction`、`log`；没有 Host API |
| 工具调用 | `ToolContext` | `callId`、`request: AgentRequest`（`requestId`、`sessionId`、`workId`、`agentId`、`mode`）、`PluginServices`、作品范围内的 `chapters` / `characters` |
| Prompt 提供方 | `PromptContext` | 只读：`sqlite.query`、`storage.get`、`settings.get`、`request`、`log` |
| 定时任务 | `TaskContext` | `runId`、`trigger`、`scheduledAt`、`ai.generateText`、`PluginServices` |
| 设置页操作 | `ActionContext` | `callId`、`PluginServices`；`settings` / `secrets` 返回表单中尚未保存的值，见[设置页操作](settings-and-storage.md#设置页操作) |
| 页面 | `ViewContext` | `page`（`viewId`、`instanceId`、`workId`）、`ui`、`view.setDirty`、`PluginServices`、作品范围内的 `chapters` / `characters`；TSX 页面与 reveric-ui-v1 action 共用，页面不提供 `request` |

`PluginServices` 是除 Prompt 外各阶段共用的 Host API：`plugin`、`log`、`http`、`storage`、`settings`、`secrets`、`sqlite`。

`ToolDisplay.title`、任务和页面标题等展示文案使用 `PluginText`：字符串对所有语言显示，对象按语言标签提供多份，Host 依次取当前界面语言、zh-CN、en、第一项。

### 业务数据 API

章节与人物通过 `chapters`、`characters`（`DataApi`）读写，只在工具和页面上下文中提供，签名与说明见 SDK。

- 权限为 `chapters.read`、`chapters.write`、`characters.read`、`characters.write`；读需要 `.read`，`update` 还需要 `.write`。不提供跨作品读取。
- 范围固定为当前请求或页面所在作品；没有当前作品时返回 `invalid_scope`。
- `list` 只返回摘要（章节：`id`、`version`、`title`、`order`；人物：`id`、`version`、`name`、`order`），章节按阅读顺序、人物按列表顺序；`limit` 为 1 至 100、默认 20，`offset` 默认 0，返回 `{items, hasMore}`。完整记录用 `get` 读取。
- `update` 接收 `{id, expectedVersion, patch}`，只修改 `patch` 中给出的字段。记录版本已变化返回 `version_conflict`，记录有未提交的草稿时返回 `draft_conflict`，不覆盖用户的新编辑；修改经业务入口进入作品变更记录。
- 未授权返回 `permission_denied`。宿主业务数据库不开放任意 SQL，插件自己的数据使用私有 `sqlite`。

调用 AI 的通用接口（`ai.invoke`）不在当前范围，见[后续迭代](README.md#后续迭代)；任务专用的 `ai.generateText` 见[任务中的 AI 请求](prompts-and-tasks.md#任务中的-ai-请求)。
### 网络请求

- 只允许 `http`、`https` 地址，不限制目标域名。
- 自动跟随重定向，最多 5 次。
- 非 2xx 状态码正常返回，由插件判断；只有请求本身失败才抛错。
- `text` 响应的解码沿用现有 Web 工具的规则：响应头声明了 charset 时按声明解码，否则优先按 UTF-8 解码，失败时按 Latin-1。
- 响应体超过 `maxBytes` 时中止读取并抛错，不返回截断内容。
- 与现有 Web 工具一致，直接连接，不使用 AI 供应商上的代理配置。
- 未设置 `User-Agent` 时，Host 使用现有 Web 工具的桌面浏览器 UA。
- `timeoutMs` 默认 20000、最大 60000；`maxBytes` 默认且最大 5 MB；`responseType` 默认 `text`；响应头名称统一为小写。
- `http.fetch(url, init)` 以 `{...init, url}` 发给 Host，`init` 中的字段不能覆盖 `url`。

请求失败时 Promise 以 `PluginHostError` 拒绝，`code` 取值：

| code | 含义 |
| --- | --- |
| `invalid_url` | 地址无效或不是 http、https |
| `network` | 连接失败、DNS 失败等，`message` 保留底层错误信息 |
| `timeout` | 超过 `timeoutMs` |
| `too_large` | 响应体超过 `maxBytes` |
| `rate_limited` | 本次执行的请求总数超过 50 个 |

### 日志

`log.info` / `warn` / `error` 写入应用日志，自动带上插件 ID 并保留级别（`warn` 记为 warning）。调用返回 void，不抛错，也不等待 Host，`apply` 中也可使用。插件不得把凭据写入日志；Host 在写日志前把当前插件 `plugin_secrets` 中的值替换为 `***`。

## 结果与错误

处理函数的返回值必须是严格 JSON：null、布尔、有限数字、字符串、数组或普通对象；值为 `undefined` 的对象属性被省略。其他值（bigint、Uint8Array、NaN、函数、Date 等类实例）使本次调用以 `plugin_invalid_result` 失败，错误信息指出位置，如 `$.items[0].big is bigint`。SQLite 行中的 bigint 和 BLOB 需要先转换再返回。工具处理函数返回 JSON 对象，Host 原样作为工具结果交给 Agent；插件也可以沿用 Host 工具的约定直接返回 `{ "ok": false, "error": "...", "error_code": "..." }`。

预期内的失败抛出 SDK 的 `PluginError(code, message)`。Host API 拒绝时抛出的 `PluginHostError` 同样带 `code`，不捕获即按同样方式上报。`code` 匹配 `^[a-z][a-z0-9_]{0,63}$` 的错误原样上报：工具调用返回 `{ok: false, plugin_id, error_code: code, error: message}`，任务记录该 code，设置页操作按 `ActionResult.code` 处理。其他未捕获异常按 `plugin_error` 上报并附带堆栈。

Host 生成的错误结果使用以下 `error_code`，`error` 字段保留实际错误信息，供 Agent 判断原因：

| error_code | 情形 |
| --- | --- |
| `plugin_unavailable` | 插件已停用、待配置、激活失败或当前平台不支持 |
| `plugin_error` | 处理函数抛出不带合法 code 的未捕获异常；附带 `plugin_id` 和 JS 错误信息与堆栈 |
| `plugin_timeout` | 超过执行总时长 |
| `plugin_memory_limit` | 超过堆或栈限制 |
| `plugin_invalid_result` | 返回值不是严格 JSON（工具还要求是对象），或超过大小限制；错误信息指出路径 |
| `plugin_registration_mismatch` | 执行时的注册结果与激活时不一致 |

面向用户的界面不直接显示这些原始信息，工具卡片按现有失败样式展示。

## 运行时与权限边界

- 插件逻辑只获取 Host 提供的能力，运行时不开放文件系统和进程能力。
- 网络请求经 Host 接口完成，不限制目标地址，也不作为需要授权的权限。
- 业务数据读写和后台 `ai.generateText` 在安装/启用时确认，每次调用复查。私有数据库只限定当前插件，不授予宿主数据库访问权。
- JS 运行时隔离、超时和资源限制可以防止插件意外耗尽资源，但不等于操作系统级安全沙箱，见 [ADR-0008](../../adr/0008-plugin-security-capability-allowlist.md)。
- 宿主 API 只新增兼容能力时保持主版本；破坏签名或语义时升主版本，见 [ADR-0009](../../adr/0009-plugin-capability-api-versioning.md)。

## 改动清单（M1）

#### NEW: `lib/shared/models/plugin/manifest.dart`
- `PluginManifest`：解析并校验 `plugin.json`，按上文规则产出字段或无效原因。

#### NEW: `lib/shared/services/plugins/runtime.dart`
- `PluginRuntime`：单次执行，参照 `FjsRuntime` 创建引擎、执行前置脚本和入口、处理桥接请求、执行资源限制与取消；提供激活和调用处理函数两种入口。

#### NEW: `lib/shared/services/plugins/prelude.dart`
- 生成前置脚本：定义 `setup`、各阶段上下文、注册接口、`PluginHostError` 及桥接封装；`apply` 结束后关闭注册接口，向 Host 上报完整注册项供其核对清单和快照，并在 JS 内检查结果是否为严格 JSON。

#### NEW: `lib/shared/services/plugins/http.dart`
- `PluginHttpApi`：执行网络请求，处理重定向、超时、大小限制、解码、代理和取消；可注入请求函数供测试使用，取代现有 `webToolHttpGet`。

#### NEW: `lib/shared/services/plugins/registry.dart`
- `PluginRegistry`：保存每个插件的注册项，执行工具名冲突与覆盖规则，计算当前生效的工具集合。

#### NEW: `lib/shared/services/plugins/host.dart`
- `PluginHostService`：扫描内置插件、读取登记记录、按启停和平台决定激活、维护运行状态与失败原因、处理启停切换。

#### NEW: `lib/shared/providers/plugin_providers.dart`
- 暴露 `PluginHostService`、插件列表与运行状态，供设置页和工具接入使用。

#### `lib/main.dart`
- `_AppLifecycleWatcherState.initState` 中与 MCP 初始化并列，调用 `PluginHostService.start()`：登记内置插件并激活所有已开启的插件，不等待完成；失败写日志，不影响启动。
