# 验收

> 按里程碑列出验收标准和测试入口。任务进度只在[实施任务](README.md#实施任务)维护。

实现时使用 FVM，Flutter 测试串行运行。三个里程碑都要在 Windows、macOS、Android 上验收；只在宿主平台跑过测试不算跨平台验收。

## M1 插件基础与内置联网检索

| 类别 | 标准 | 验证方式 |
| --- | --- | --- |
| 运行时 | 打包为单文件的插件在三个平台激活并执行；Promise 与 Future 互通；取消、超时、内存超限后运行时关闭，后续调用正常 | T-01 实测记录，三平台手动验收 |
| 性能 | 记录运行时创建耗时、单次执行内存峰值、`reveric.web` 产物体积，以及 node-html-markdown 转换真实大网页（接近 5 MB）的耗时与内存；结果经确认可接受，必要时调整[资源限制](architecture.md#资源限制) | T-01 基准记录 |
| 清单 | 缺字段、类型错误、未知平台、`main` 越界、入口超限、API 版本不兼容时插件不加载并显示原因 | `test/shared/services/plugins/` |
| 注册 | 重复工具名、非法 Schema、`apply` 结束后注册、执行时注册结果与激活快照不一致（`plugin_registration_mismatch`）、设置页操作与清单 `settings.actions` 不一致，均按约定报错；`setup` 不提供 Host API；激活失败时本次注册全部不生效 | 同上 |
| 启停 | 联网检索插件首次启动默认开启；显式关闭后重启和升级不会重新打开；两个 Web 工具同时启停，重新开启无需重启应用 | 服务测试、手动重启 |
| 调用边界 | 会话进行中开关插件，下一次模型请求的工具列表随之变化；关闭后主聊天、子 Agent 和各会话模式的工具列表都不含两个工具，用旧工具名直接调用返回 `plugin_unavailable`；关闭时正在执行的调用正常返回 | 工具调度测试 |
| 工具行为 | 工具名、description、参数 Schema、结果字段与原实现一致；搜索结果解析、广告过滤、无结果与解析失败、验证页、跳转解析、截断、空内容、大小与超时错误均有用例；WebFetch 返回可读正文 | `make plugins-test` |
| 错误 | `PluginError` / `PluginHostError` 的合法 code 原样作为 `error_code` 返回（带 `plugin_id`）；其他异常为 `plugin_error` 并带堆栈；超时、内存超限分别得到对应 `error_code`；非严格 JSON 结果为 `plugin_invalid_result` 并指出路径；`error` 保留实际信息 | `test/shared/services/plugins/` |
| 网络请求 | 重定向、非 2xx、超时、超过大小上限、charset 解码、取消（关闭运行时）、请求数上限按[网络请求](architecture.md#网络请求)执行；`init` 不能覆盖 `url` | 同上，使用注入的请求函数 |
| 工具限制 | 各会话模式和 Agent 可用的 Host 工具与改动前一致；受限模式仍不能使用 Host 写入工具，但可以使用已启用的插件工具；不再读写 `allowedToolNames` | 对照改动前名单的单测 |
| 卡片 | 新调用按插件声明渲染标题、参数标签和 `items` / `text` 预览，与现有 Web 工具卡片布局一致；插件化之前的 WebSearch、WebFetch 历史记录正常显示；插件关闭后已有记录仍可查看 | Widget 测试、手动检查 |
| 存储 | 正式发布 schema 1 的 app 库升级到当前 schema 3 后插件表结构正确、已有表记录不变；DAO 按 `plugin_id` 隔离 | migration 测试、DAO 测试 |
| 设置 | 桌面端和移动端“设置 / 插件”都能查看插件、切换开关、看到状态和失败原因 | Widget 测试、两端手动检查 |
| 产物 | `assets/plugins/reveric.web/plugin.json` 与 `plugins/web/plugin.json` 一致 | `test/shared/services/plugins/` |

### 清单重构回归

- `settings.fields` 生成配置表单，`settings.actions` 解析操作及字段依赖；拒绝旧版平铺 `settings`、顶层 `actions`、`views` 和 `uiProtocols`。
- `pages`、`tasks` 使用对象 key 作为 ID，拒绝重复写条目 `id`；校验页面位置、协议、包内路径、任务标题和周期。
- 任务、设置操作和 A2UI 事件声明与 handler 一一对应；缺失、额外或重复绑定均拒绝。每次 `apply` 都由 Host 核对完整注册批次和激活快照。
- TSX 页面打开时直接调用 `mount`；A2UI 静态内容直接加载，`onMount` 和用户事件仍按次调用 `apply` 后执行 handler。
- 自定义卡片使用 `display.view: {protocol, source}`，只接受 `reveric-ui-v1` 和包内 JSON 路径，并要求通用 `display.result`；普通预览无需协议字段。
- 内置源清单与 `assets/plugins/` 产物一致，记忆插件的页面和任务可加载，DeepSeek 设置操作仍能读取表单草稿。

对应测试为 `host_test.dart`、`runtime_test.dart`、`task_runtime_test.dart`、`pages_test.dart`、内置插件测试及页面、设置、工具卡片 Widget 测试；代码位于既有 `test/shared/services/plugins/`、`test/shared/widgets/` 和 `test/desktop/widgets/ai/tools/`。本地执行结果在 README 的 T-29 记录；这些回归不替代三平台原生验收。

## M2 第三方工具与配置

| 类别 | 标准 | 验证方式 |
| --- | --- | --- |
| 配置 | 按清单 `settings.fields` 生成配置表单，插件未启用时也可填写；必填项缺失时显示待配置，能力不可调用；保存失败时明确提示；插件文案按界面语言显示 | Widget 测试 |
| 设置页操作 | `requires` 字段齐全前按钮不可用；处理函数读到未保存的表单值；`ActionResult.code` 与抛出的 code 按[设置页操作](settings-and-storage.md#设置页操作)显示，`message` 只写日志 | 服务测试、Widget 测试 |
| 凭据 | Key 不回显，可替换和清除，替换后下一次调用读取新值；凭据不进入日志、工具参数或结果；插件不能读取其他插件的凭据或配置 | 服务测试、日志检查 |
| 存储 | `storage` 读写、大小上限、跨插件隔离 | 服务测试 |
| 权限 | 安装时展示业务数据权限，未授权的 Host API 调用返回 `permission_denied`；撤销授权立即生效 | 权限测试 |
| 业务数据 | `list` 只返回摘要并按显示顺序分页；`update` 按 `patch` 修改后，宿主界面和变更记录一致；版本冲突返回 `version_conflict`，有未提交草稿返回 `draft_conflict`，无当前作品返回 `invalid_scope`，不覆盖用户的新编辑 | 服务测试、手动检查 |
| 安装与更新 | 包路径穿越、符号链接、超限、API 不兼容、版本不升高被拒；`platforms` 不含当前平台时显示不支持且不运行；新增权限需要重新确认；任一步失败时原版本继续可用；更新成功后旧版本目录被删除，删除失败不影响更新并在下次启动时清理；卸载只做软删除，重新安装恢复配置 | 安装流程测试 |
| 工具覆盖 | 第三方插件覆盖内置 `WebSearch`，停用后内置工具恢复；两个第三方插件同名时后启用者激活失败并显示原因；Host 工具名不能被注册 | 注册表测试 |
| 备份 | 备份恢复后本地插件包、登记记录、配置一致，启停选择不变 | 备份测试 |
| 端到端 | 示例第三方搜索插件可安装、配置 Key、覆盖 `WebSearch` 并被 Agent 调用 | 三平台手动验收 |

## M3 自定义 View

| 类别 | 标准 | 验证方式 |
| --- | --- | --- |
| 构建 | TSX 转换保留动态 props、children、条件与 keyed 列表；source map 指向原 TSX；产物不依赖 DOM、Node 或 JS 版响应式框架；应用不运行编译器 | 编译器夹具与产物检查 |
| 挂载 | 从清单 `pages` 发现页面，`location` 必填且为 `home.plugin`；路径越界、未知协议、超限产物拒绝加载；激活不执行页面代码，TSX 打开时直接 `mount`，不调用 `apply` | Host 测试、Widget 测试 |
| 响应式 | TSX 组件只挂载一次；相等写入不重复通知；只更新依赖节点；batch 合并写入；条件移除释放 owner，列表重排保留节点，重复 key 报错 | 原生运行时测试、Widget 测试 |
| 桥接 | 一轮更新批量发送；顺序、代次、所有权、结构合法性与全部配额在 Host 校验；坏批次不部分提交；慢消费时内存有界，关闭后的批次被丢弃 | 协议测试、压力测试 |
| 组件 | 首批组件按 Reveric 主题和 token 渲染；支持自定义组合与插槽；主题/尺寸变化自动更新；Windows/macOS 的鼠标键盘与 Android 触摸、返回键符合宿主行为 | 组件测试、三平台手动验收 |
| 异步 | 慢请求等待时其他按钮可操作；搜索过期响应不覆盖新结果；owner 释放取消资源，未捕获拒绝可诊断；不开放额外业务 Event / Hook | 可控 Promise/Host 请求的运行时测试 |
| 输入与表单 | 中文组词、光标、选择区稳定；旧 JS 响应不覆盖新输入；列表重排保留焦点；多字段编辑区不回收，离屏字段仍校验；dirty 关闭确认取消后页面保留 | Widget 测试，三平台真实输入法验收 |
| 生命周期 | 同插件多页面和工具相互隔离；停用/卸载/更新先确认编辑，取消不改变状态；确认后清理；隐藏/后台暂停周期任务，恢复不积压 tick | Host 测试、三平台手动验收 |
| 防护 | JS 无限循环由原生中断（SQLite 等待超时不等同 SQL 中断）；内存、节点、定时器、待完成调用与页面数超限不会拖垮其他页面；异常和强制关闭不依赖插件 cleanup | 真实 fjs 运行时测试 |
| 双后端 | 同一插件声明两种协议，分别打开 A2UI 和 TSX 页面；A2UI onMount/action 更新数据与组件结构、过期结果被拒，页面不常驻 JS；TSX 状态保持不受影响；未声明协议拒绝注册 | Host/Widget 测试、三平台验收 |
| 卡片与配置 | A2UI 配置表单不运行插件；只读卡片不创建 JS 引擎、不触发 action；历史卡片不兼容或插件停用时退回通用卡片 | 既有 A2UI、配置表单及工具卡片回归测试 |
| 端到端 | 以记忆插件通过下方完整验收；人物整理仅保留为宿主业务 API 样例 | Windows、macOS、Android 验收 |

### 性能与释放验收

T-21 建立预览基准，T-16 在真实三平台 release 构建复测。记录设备、构建模式、样本量、p50/p95/max，并分别记录 JS/原生响应式、桥接、Flutter build/raster、首帧和进程峰值内存；不能拿 nsh 的数字替代本项目结果。

- 固定场景：计数器；200 个控件中单值更新；1000 行只读列表滚动与重排；40 个值以 30 Hz 更新；异步搜索并交错返回；4 个页面打开并同时执行工具。
- 更新后的 Flutter 帧耗时 p95 不超过目标设备一个刷新周期，事件到可见结果 p95 不超过两个刷新周期，网络等待另计；首帧单列记录，不混入稳定帧。未达标时定位耗时阶段并修复后复测。
- 空闲页面不产生周期 UI 批次；隐藏页面无周期 tick 积压；操作次数随实际变化增长，单值更新不发送整树。
- 连续打开/关闭 100 次后，页面引擎、节点、订阅、定时器和待完成请求计数回到基线；进程内存按固定间隔采样，检查是否持续增长，不要求分配器立即归还全部内存。
- 强制超时、OOM、慢 Dart 消费与网络迟到分别重跑关闭用例，确认资源释放与其他页面可用。Flutter 测试串行运行，不能并行基准争抢资源。

## 记忆插件端到端验收

以下均在 Windows、macOS、Android 验证。新接口的测试是交付要求，当前文档检查不代表已经实现或通过。

| 场景 | 成功标准 |
| --- | --- |
| 安装与重启 | 创建私有库并执行迁移；关闭并重开应用后记忆仍在，schema 和迁移指纹一致 |
| Tool → UI | 调用创建/修改工具后，打开或刷新管理页能看到已提交值；不需要 Host 的 Memory 专属 DAO |
| UI → Prompt | UI 修改并保存记忆后，下一次实际发给模型的请求包含新内容；以捕获请求验证，不能只看模型是否“记得” |
| scope | 两个作品和全局各有独立样本；请求只含全局及当前作品数据，作品使用稳定 ID；子 Agent 与主 Agent scope 一致 |
| 禁用与删除 | 禁用、软删除条目后下一次请求不再注入；编辑冲突不覆盖新版本；删除仍可从库中找到软删除记录 |
| Prompt 失败 | 空结果、超时、异常和超额不会阻塞聊天或复用旧块；正常 MCP 提示保留；重试不重复追加 |
| 定时整理 | 不打开管理 UI，Host 到期仍能运行；一次模型生成产生待确认的精炼建议，原记忆不自动改写；应用旧版本建议时报冲突 |
| 调度边界 | 同任务不重入；手动运行与定时触发合并；暂停跨重启保留；崩溃标中断；恢复最多补跑一次；取消不继续重试 |
| AI 权限与取消 | 未授权或无默认模型时不发请求；正常请求记入模型用量；任务取消/超时传递到模型，迟到结果不写入 |
| SQL | 参数绑定与 64 位整数/BLOB 往返正确；第二条语句失败时第一条回滚；单条零行更新返回 changes=0；多语句、错误语句类型和运行时 DDL 拒绝；不承诺恶意 SQL 沙箱 |
| 配额与恢复 | 行数/字节/等待时间/队列超限可诊断；超时 SQL 仍在 worker 完成，不能误报为已回滚；迁移失败与切换中断恢复原包原库；不能以空库代替恢复；备份包含未丢失的已提交数据 |
| 插件启停 | 停用后工具、Prompt、页面、任务全停止；重新启用保持数据；卸载不删除私有库；旧主库 Memory 不再参与任何注入 |
| 旧功能清理 | 新库没有宿主 memories 表；已有库升级移除旧表；旧组件/设置/provider/注入无残留引用；聊天历史与会话缓存不受影响 |

最小演示使用全局及两个作品各两条记忆，覆盖一次工具创建、一次 UI 更新、一次请求捕获、一次冲突、一次手动整理、一次可控时钟触发与一次重启。调度测试使用可控时间；三平台手动检查前后台及模型取消，不能靠等待真实 60 分钟替代确定性测试。

### 底层实施规格验收

- TSX 编译夹具覆盖别名导入、嵌套作用域、getter props、条件分支、keyed 重排、中文文本、非法标签和 source map；`make plugins-test` 增加编译器用例，Node 测试不替代真实 QuickJS 测试。
- 提取的 reactive 测试在 fjs 依赖下原样运行；新增 GC 闭包循环、effect 重入、owner 重复释放、多页面隔离、关闭时未完成 Promise 和无限微任务用例。Rust 命令为 `cargo test --manifest-path third/fjs/libfjs/Cargo.toml`，实施后按实际新增测试模块定点运行，再执行该 crate 回归；串行运行，不与 Flutter 构建争用。
- UiBatch 测试覆盖缺序号、重复 ack、移动、释放顺序、错误 slot、坏批次不部分提交、旧 handler、中文 composing 和旧编辑序号；Flutter 侧使用 FVM 串行测试。
- SQLite 测试只要求既定可信插件契约：多语句与错误 AST 类型拒绝、读取限额、事务回滚、数据类型与安装恢复。刻意慢 SQL 超时后 worker 仍需收尾，断言不会并行重开同库或将未知提交自动重试；不要求 authorizer、progress handler 或驱动 fork。
- 发布前在 Windows、macOS、Android 构建并实测 UI 会话线程退出、fjs 原生库加载、SQLite 文件关闭后更新/备份；本次只有源码与文档核查，以上测试均未执行。

## 测试入口

| 范围 | 命令 |
| --- | --- |
| 内置插件逻辑（Node 22） | `cd plugins && node build.mjs --test`，或 `make plugins-test`（先 `npm ci`） |
| Host、注册表、运行时桥接、网络请求、Prompt、任务、内置插件真实运行 | `FJS_PROBE_LIBRARY=<已构建的 libfjs> fvm flutter test test/shared/services/plugins --concurrency=1` |
| 工具接入与工具限制 | `fvm flutter test test/shared/services/ai/` 中受影响的文件 |
| 数据库 migration 与 DAO | `fvm flutter test test/shared/database/` 中插件相关文件 |
| 设置页与工具卡片 | 对应 Widget 测试文件 |

`FJS_PROBE_LIBRARY` 指向本机构建的 fjs 动态库，未设置时依赖真实 QuickJS 的用例无法执行。macOS 上先运行 `bash third/fjs/tool/build_runtime.sh`，产物位于 `third/fjs/build/darwin-xcframework/rust/aarch64-apple-darwin/release/libfjs.dylib`。Flutter 测试串行运行。

具体测试文件随实现落点确定，不把不存在的目录列为已完成检查。
