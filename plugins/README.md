# 插件工作区维护说明

本文写给维护 Reveric 插件系统的开发者：说明 `plugins/` 工作区和 SDK 的结构、契约改动要同步哪些地方、怎么构建、验证和发布。插件开发者的文档是 [sdk/README.md](sdk/README.md)，它也是 npm 包 `reveric-plugin-sdk` 的说明页。

## 工作区

`plugins/` 是一个 npm workspace：

| 目录 | 内容 |
| --- | --- |
| `sdk/` | npm 包 `reveric-plugin-sdk`，MIT 许可（主仓库是 AGPL-3.0） |
| `memory/`、`web/`、`deepseek/`、`keenable/`、`zhuque/` | 内置插件 |
| `build.mjs` | 构建内置插件到 `../assets/plugins/`，或运行全部测试 |

`npm ci` 会把 `node_modules/reveric-plugin-sdk` 链接到 `sdk/`。内置插件和第三方插件一样，通过包名 `reveric-plugin-sdk` / `reveric-plugin-sdk/ui` 引用 SDK，所以始终使用仓库里的源码，不依赖 npm 上的发布版本。

内置插件的目录结构和第三方插件相同（`src/index.ts`、`src/views/<name>.tsx`、`migrations/`），由同一个 `buildPlugin` 构建，区别只有两点：

- 输出目录是 `assets/plugins/<id>/`。
- 类型检查由 `build.mjs` 对整个工作区统一执行（`plugins/tsconfig.json`），所以每个内置插件不需要自己的 `tsconfig.json`。

## SDK 目录

| 路径 | 内容 | 是否发布 |
| --- | --- | --- |
| `index.d.ts` | 入口、各阶段上下文、宿主 API 的类型与行为说明，是插件契约的权威文本 | 是 |
| `index.js` | `PluginError`、`isHostError` | 是 |
| `ui.schema.json` | TSX 页面组件、属性、事件、插槽的唯一定义 | 是 |
| `ui.d.ts` | `reveric-plugin-sdk/ui` 的类型，由 `generate_ui.mjs` 生成 | 是 |
| `tsx_transform.mjs` | TSX 编译器、esbuild 插件 `tsxPlugin()`、页面入口 `pageEntry()` | 是 |
| `builder.mjs` | `buildPlugin()` / `packPlugin()`，导出为 `reveric-plugin-sdk/build` | 是 |
| `cli.mjs` | 命令行工具 `reveric-plugin build` / `pack` | 是 |
| `tsconfig.base.json` | 第三方项目 extends 的 TS 配置（`lib` 只有 ES2020，没有 DOM） | 是 |
| `generate_ui.mjs` | 从 schema 生成 TS、Dart、Rust、JS 四处定义 | 否 |
| `sqlite_runtime.js` / `generate_sqlite.mjs` | SQLite JSON 桥接编解码，复制到 Dart 和 Rust | 否 |
| `fixtures/`、`build_fixture.mjs`、`build_performance.mjs` | 原生测试和预览用的示例页面 | 否 |
| `*.test.mjs` | SDK 测试 | 否 |

发布哪些文件由 `sdk/package.json` 的 `files` 决定；新增需要发布的文件时记得加进去，可以用 `npm pack --dry-run` 检查。

## 架构

### 插件入口（工具、提示词、任务、设置动作、ui-v1 页面 action）

入口打包成 IIFE，导出到全局 `__revericPlugin`，宿主调用其中的 `apply`。所有业务插件共用一个 JS 运行时，每个插件有独立的 context。

- JS 侧上下文：`lib/shared/services/plugins/prelude.dart`
- 宿主 API 分发与权限检查：`lib/shared/services/plugins/host.dart`
- 调用与时限：`lib/shared/services/plugins/runtime.dart`
- ZIP 导入校验：`lib/shared/services/plugins/package_archive.dart`
- `reveric-ui-v1` 渲染：`lib/shared/widgets/a2ui/`

### TSX 页面（reveric-tsx-v1）

每个页面在独立的原生线程和 QuickJS 运行时中运行：

```
TSX ──tsx_transform──▶ JS（属性编译成 getter）
    ──pageEntry + esbuild──▶ IIFE：__revericView.mount(context)
                                 │
third/fjs/libfjs/src/ui/sdk.js   │ signal / effect / element / Each / List …
    reactive.rs                  │ 响应式图（Solid 语义）
    nodes.rs + schema.rs         │ 节点树、属性与插槽校验
    session.rs                   │ 线程、批次提交与 ack、事件派发
                                 ▼
lib/shared/models/plugin/ui_tree.dart        按 ui_schema.dart 再次校验并应用批次
lib/shared/widgets/plugin_view/              tree_view / input / overlay / viewport_list 渲染
```

事件反向传递：Dart widget 调用 `emit(event, payload)`，经 `ui_session.dart` 的 `dispatch` 交给 Rust `bindings.rs::dispatch`，最后由 `sdk.js` 的事件转发函数调用插件的处理函数。

几个需要知道的约定：

- **宿主协议固定为 `__revericView.mount(context)`**。插件作者写的是 `export default function Page(ctx)`，由 `pageEntry()` 生成 `mount` 包装。Rust 和 Dart 的许多测试直接按这个协议手写页面；已发布的插件包也依赖它，不能随意修改。
- **`reveric-plugin-sdk/ui` 在运行时没有对应的 JS 文件**。`tsxPlugin()` 拦截这个模块名，换成读取宿主全局 `__revericUi` 的代码；`ui.d.ts` 只提供类型。
- **`sdk.js`、`components.js`、`sqlite.js` 通过 `include_str!` 编进原生库**。改了这些文件，要重新编译 fjs 才会在应用和 Dart 测试中生效。macOS / iOS 的 App 链接的是预编译包 `third/fjs/darwin/fjs/Binaries/fjs.xcframework.zip`，需要运行 `bash third/fjs/tool/build_runtime.sh` 重新生成（`make build-macos` 等目标会自动执行），然后完整重启 App。直接 `fvm flutter run` 或热重启不会更新原生库，此时新的页面代码会跑在旧运行时上。
- **schema 会被校验两次**：Rust（`schema.rs`）在 JS 侧创建节点时校验，Dart（`ui_tree.dart`）在应用批次时校验。两者都由同一份 schema 生成。
- **wrapper 组件**：schema 中标记 `wrapper: true` 的组件（`List`、`Tabs`）由 `sdk.js` 中的 JS 函数实现，再生成宿主元素。它们的 TS 签名写在 `generate_ui.mjs` 的头部，transform 也会把它们当作函数组件调用，而不是直接创建宿主元素。

## 兼容性

第三方插件通过 npm 依赖 SDK，构建出的插件包会在之后各个版本的宿主上运行。因此：

- 已发布的插件包必须能在新版宿主上继续运行：宿主 API、事件 payload、组件属性只能做兼容的扩展。
- `reveric-plugin-sdk` 的导出（包括 `reveric-plugin-sdk/build`）、CLI 参数和项目结构约定都属于公开接口。
- 宿主协议的不兼容改动需要提升 `pluginApiVersion` 的主版本（当前为 1）。
- SDK 包的版本按语义化版本独立管理，不和 `pluginApiVersion` 绑定。目前处于 0.x 阶段，SDK 接口（导出、CLI、项目结构约定）的不兼容改动提升次版本号。

## 修改契约

### 生成链

`ui.schema.json` 改动后，在 `plugins/` 目录运行：

```sh
node sdk/generate_ui.mjs
rustfmt --edition 2021 ../third/fjs/libfjs/src/ui/schema.rs
fvm dart format ../lib/shared/models/plugin/ui_schema.dart
```

| 生成物 | 用途 |
| --- | --- |
| `sdk/ui.d.ts` | 插件作者的类型 |
| `lib/shared/models/plugin/ui_schema.dart` | Dart 侧校验 |
| `third/fjs/libfjs/src/ui/schema.rs` | Rust 侧校验：组件、事件枚举、属性类型、插槽数量 |
| `third/fjs/libfjs/src/ui/components.js` | `sdk.js` 用到的插槽列表和 `children` 映射 |

生成器不会自动格式化，所以上面两条格式化命令不能省，否则 diff 会混入格式变化。

### schema 字段

| 字段 | 含义 |
| --- | --- |
| `props.<name>` | `type`（见 `generate_ui.mjs` 中的 `kinds`）、`enum`、`default`、`required`，以及 `internal`（不出现在公开类型中） |
| `events` | 事件名 → payload 类型：`press`、`text`、`boolean`、`select`、`tab`、`id`、`open`、`viewport` |
| `slots` | 插槽名 → `one` / `many` |
| `children` | 没有 `children` 插槽的组件，JSX 子节点要放进哪个插槽 |
| `wrapper` | 由 `sdk.js` 中的 JS 函数实现 |
| `internal` | 只在运行时内部使用的组件（`Fragment`） |

### 新增或修改组件

1. 修改 `ui.schema.json`，运行生成链。
2. 在 `lib/shared/widgets/plugin_view/tree_view.dart`（输入类组件在 `input.dart`，浮层在 `overlay.dart`）实现渲染，使用设计系统组件和 token。
3. 有事件时，Dart 侧发出的 payload 要和 schema 中的事件类型一致；新增 payload 类型时，同步修改 `generate_ui.mjs` 中的 `events` 映射。
4. 需要 JS 侧逻辑时，在 `sdk.js` 中实现 wrapper，并在 schema 中标记 `wrapper: true`。
5. 补测试：
   - transform 和类型：`sdk/tsx_transform.test.mjs`
   - 运行时：`third/fjs/libfjs/src/ui/` 下的 Rust 测试
   - 渲染与事件：`test/shared/widgets/plugin_view/`
6. 更新 [sdk/README.md](sdk/README.md) 中的组件或事件表。

### 修改宿主 API

1. 在 `index.d.ts` 中修改类型和注释。注释是插件作者看到的权威说明，行为、时限、错误码都要写清楚。
2. 实现位置：
   - 插件入口：`prelude.dart` 和 `host.dart`
   - 页面：`sdk.js` 的 `__revericPageContext`，宿主侧经 `host.dart` 或 `plugin_view/host_ui.dart`
3. 两个运行时都要能用，或者在类型里写明只有哪个阶段可用。
4. 同步更新 [sdk/README.md](sdk/README.md)。

### 修改构建工具

`builder.mjs` 和 `cli.mjs` 同时服务内置插件和第三方。改动后：

- 运行 `sdk/builder.test.mjs`（包含在 `npm test` 中）。
- 运行 `npm run build`，确认 `assets/plugins/` 的产物只有预期的变化。
- 用 `npm pack` 打出 tarball，在仓库外的新项目里安装并执行 `npx reveric-plugin pack`，确认发布包能独立工作。

## 构建与验证

Node 版本必须是 22（`build.mjs` 会检查）。本机默认 Node 不是 22 时，用 `fnm exec --using=22 <command>`。

```sh
cd plugins
npm ci
npm run build     # 生成 SQLite 桥接、类型检查、构建内置插件到 assets/plugins/
npm test          # 类型检查，运行插件测试和 SDK 测试
npm run format    # Prettier；生成的 ui.d.ts 和构建产物已在 .prettierignore 中排除
node sdk/build_fixture.mjs && node sdk/build_performance.mjs   # 改了 transform 或 fixture 后运行
```

构建产物需要提交：`assets/plugins/`、`assets/plugin_preview/`、`third/fjs/libfjs/src/ui/fixtures/counter.js`。Flutter 构建只读取这些已提交的产物。

原生运行时：

```sh
cd third/fjs/libfjs
cargo test --lib     # 全部 Rust 测试
cargo build --lib    # 产出 libfjs 动态库，供 Dart 测试使用
```

部分 Rust 测试断言进程级的资源计数。启动 worker 的测试要持有 `telemetry::TEST_COUNTS` 的读锁，断言精确计数的测试持有写锁，否则并行运行时会互相干扰。

Dart 测试需要通过 `FJS_PROBE_LIBRARY` 指向上一步编译出的动态库（位置取决于 Cargo 的 target 目录），并且必须串行运行：

```sh
FJS_PROBE_LIBRARY=<target>/debug/libfjs.dylib fvm flutter test -j 1 \
  test/shared/models/plugin test/shared/widgets/plugin_view test/shared/services/plugins
```

`source_map_test` 会把 `manage.tsx` 的源码行号和已提交的 `manage.js.map` 对照，所以改了 `manage.tsx` 之后要先重新构建，再跑这个测试。

## 发布 SDK

1. 确认上面的验证全部通过。
2. 按语义化版本修改 `sdk/package.json` 的 `version`；不兼容的改动见"兼容性"一节。
3. 在 `plugins/sdk/` 下运行 `npm pack --dry-run`，确认文件列表只包含 `files` 中列出的文件，以及 README 和 LICENSE。
4. 在 `plugins/sdk/` 下运行 `npm publish`。

## 内置插件

| 目录 | id | 说明 |
| --- | --- | --- |
| `memory/` | `reveric.memory` | 示例：记忆系统，演示工具、提示词、定时任务、私有数据库、TSX 管理页 |
| `web/` | `reveric.web` | 联网检索与网页读取 |
| `deepseek/` | `reveric.deepseek` | DeepSeek 搜索与读取，带设置动作 |
| `keenable/` | `reveric.keenable` | Keenable 搜索与读取，API Key 可选（不填时使用公共接口），带设置动作 |
| `zhuque/` | `reveric.zhuque` | 朱雀文本 AI 检测，需配置 EdgeOne Makers API Key，带设置动作 |

内置插件的首次启用策略由 `lib/shared/services/plugins/host.dart` 中的 `_defaultEnabledBundledPlugins` 管理；新增默认启用项时，将插件 ID 加入该集合。已有用户选择保持不变。

`memory/` 覆盖了大部分 SDK 能力，改 SDK 时优先用它做端到端验证（`test/shared/services/plugins/memory_test.dart`）。
