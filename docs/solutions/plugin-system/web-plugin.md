# 联网检索插件与内置插件构建

> 本篇定义 M1 的内置联网检索插件，以及内置插件的源码位置、构建和打包方式。任务进度只在[实施任务](README.md#实施任务)维护。

## 行为

联网检索是第一个验证插件机制的功能，包含 `WebSearch`、`WebFetch`，不需要专用 View。它是随应用打包的 JS 插件，和第三方插件走同一套加载、注册和启停流程。

- 应用级开关，在“设置 / 插件”中切换，影响主聊天和子 Agent，默认开启。
- 启用后注册两个工具；关闭后两者一起从可用工具中移除，实际执行入口也检查插件状态。
- 显式关闭状态持久化，重启或升级不能重新按默认值打开。
- 关闭后拒绝新调用，已经开始的请求允许完成，不宣称能够撤回已发送的数据。
- 重新启用时重新激活，无需重启应用。
- 已有聊天记录和搜索结果保持可查看，关闭插件不删除历史。
- 第三方搜索插件有自己的启停状态；此开关只控制内置联网检索，不是全应用断网开关。
- 不要求用户配置 API Key。

## 插件清单

```json
{
  "id": "reveric.web",
  "name": { "zh-CN": "联网检索", "en": "Web Search" },
  "description": {
    "zh-CN": "使用百度提供网页搜索，并支持网页读取；搜索可能因安全验证或反爬限制而不稳定。",
    "en": "Searches the web with Baidu and reads web pages. Search may be unreliable because of security checks or anti-scraping limits."
  },
  "version": "1.0.0",
  "author": "Reveric",
  "pluginApiVersion": "^1",
  "main": "dist/index.js",
  "defaultEnabled": true
}
```

`name`、`description` 为 `PluginText`，同时提供中英文。不声明 `permissions`、`settings` 和 `platforms`，因此默认开启时无需授权确认，三个平台都可用。

## 工具实现

两个工具的名称、description、参数 Schema 和结果字段结构不变，description 和 Schema 原文从 `tools_web.dart` 搬到插件中。需要改工具描述时，先列出具体文案并获得确认。

```ts
export function apply(setup: PluginSetup): void {
  setup.tools.register({
    ...definitions.WebSearch,
    display: { summaryArg: "query", result: "items", resultPath: "results" },
    handler: (input, context) => webSearch(context, input),
  });
  setup.tools.register({
    ...definitions.WebFetch,
    display: { summaryArg: "url", result: "text", resultPath: "content" },
    handler: (input, context) => webFetch(context, input),
  });
}
```

`definitions.json` 保存两个工具的 `name`、`description` 和 `inputSchema` 原文。处理函数从第二个参数 `ToolContext` 取得 `http`、`log` 等 Host API；`apply` 收到的 `setup` 只用于注册。
两个工具不设 `display.title`，卡片标题显示工具名。除标题不再是本地化动作词外，卡片的参数标签和预览与现有卡片一致，见[工具卡片](tools.md#工具卡片)。

| 现有 Dart 逻辑 | JS 实现 |
| --- | --- |
| `_handleWebSearch`：请求百度搜索结果页，识别验证页，解析结果块并跳过广告，区分“无结果”与“解析失败” | 同样流程；用 node-html-parser 解析结果页，替代现有正则 |
| `_resolveBaiduRedirectUrl`：百度跳转链接先请求跳转页，从 `location.replace` 等脚本中取出目标地址 | 同样流程，用 `ToolContext.http.fetch` 请求跳转页 |
| `_handleWebFetch`：抓取页面、识别验证页和空内容、HTML 转 Markdown、按 10240 字符截断 | 同样流程；HTML 转 Markdown 用 node-html-markdown，不要求输出与现有实现一致 |
| 5 MB 响应上限、20 秒超时、桌面浏览器 UA、charset 解码 | 由 `http.fetch` 的默认值提供，见[网络请求](architecture.md#网络请求) |
| `_logWebToolFailure` | `log.warn`，保留地址、状态码和响应开头片段 |

node-html-parser 是 node-html-markdown 的依赖，结果页解析和 Markdown 转换共用这一个解析器，不再引入其他 HTML 库。

错误结果沿用现有字段：`ok`、`error`、`error_code`（`invalid_argument`、`unavailable`、`resource_exhausted` 等）、`status_code`、`failure_kind`、`failure_stage`。`http.fetch` 抛出的 `PluginHostError` 由插件捕获并按 `code` 映射到 `failure_kind`（`timeout`、`network` 等）。

## 构建与打包

内置插件源码放在仓库根目录 `plugins/`，本地构建，产物提交到 `assets/plugins/`。CI 和 Flutter 构建只使用已提交的产物，不安装 Node。

```text
plugins/
  package.json          内置插件共用的依赖与脚本
  package-lock.json
  .nvmrc                Node.js 22
  tsconfig.json
  build.mjs             类型检查、打包、复制清单、运行测试
  sdk/index.d.ts        插件 API 合同：类型声明与注释，接口以此为准
  sdk/index.js          运行时导出（PluginError）
  sdk/ui.d.ts           TSX 页面 SDK 类型（PageContext 等）
  web/
    plugin.json
    src/index.ts        apply，注册两个工具
    src/search.ts       WebSearch
    src/fetch.ts        WebFetch 与跳转解析
    src/page.ts         验证页识别、标题提取、失败结果
    test/*.test.ts      在 Node 中用假 context 测试插件逻辑
  deepseek/             内置 DeepSeek 搜索 / 读取插件，结构相同
  memory/               内置记忆插件，另含 migrations 与 TSX 页面
assets/plugins/reveric.web/
  plugin.json           由构建复制
  dist/index.js         构建产物
```

- 依赖：开发依赖 `esbuild`、`typescript`，运行依赖 `node-html-markdown`，版本由 `package-lock.json` 锁定。所有内置插件共用这一份依赖和锁文件。
- `node build.mjs` 对每个含 `plugin.json` 的子目录执行：
  1. `tsc --noEmit` 类型检查。
  2. esbuild 打包：`bundle`、`format: "iife"`、`globalName: "__revericPlugin"`、`platform: "neutral"`、`mainFields: ["module", "main"]`、`target: "es2020"`、`charset: "utf8"`、`legalComments: "eof"`，不压缩，便于从错误堆栈定位源码。
  3. 检查产物不超过 2 MB。
  4. 把 `plugin.json` 和产物写到 `assets/plugins/<id>/`。
- `node build.mjs --test` 用 esbuild 把测试打包到临时目录，再用 `node --test` 运行。
- Makefile 新增 `plugins`（`npm ci` 后构建）和 `plugins-test` 两个 target。
- `pubspec.yaml` 的 assets 声明 `assets/plugins/reveric.web/` 和 `assets/plugins/reveric.web/dist/`（Flutter 不递归扫描子目录）。
- Host 通过 `AssetManifest` 查找 `assets/plugins/*/plugin.json`，发现内置插件。
- 修改插件源码后，必须本地运行 `make plugins` 并提交 `assets/plugins/` 下的产物；修改行为时同时递增 `plugin.json` 的 `version`。

第三方插件作者可以使用 `plugins/sdk` 中的类型和同样的打包参数；入口约定见[入口约定](architecture.md#入口约定)。

## 测试

| 层级 | 内容 | 命令 |
| --- | --- | --- |
| 插件逻辑 | 由 `tools_web_test.dart` 现有 15 个用例迁移：搜索结果解析、广告过滤、无结果与解析失败、验证页、跳转解析、截断、空内容、大小与超时错误。依赖原 Markdown 格式的断言按新库调整 | `make plugins-test` |
| Host 接入 | 清单解析、激活、工具注册与覆盖、启停、可用性检查、错误映射，使用假运行时 | `fvm flutter test test/shared/services/plugins/` |
| 产物一致 | `assets/plugins/reveric.web/plugin.json` 与 `plugins/web/plugin.json` 内容一致 | 同上 |
| 真实运行时 | 产物在 fjs 中激活并执行两个工具 | `FJS_PROBE_LIBRARY=<已构建的 libfjs> fvm flutter test test/shared/services/plugins --concurrency=1`，见[测试入口](verification.md#测试入口)；三个平台另行手动验收 |

## 改动清单（M1）

#### NEW: `plugins/`
- 按上文目录新增 SDK 类型、联网检索插件源码、测试和构建脚本。

#### NEW: `assets/plugins/reveric.web/`
- 提交构建产物 `plugin.json`、`dist/index.js`。

#### `pubspec.yaml`
- assets 增加上述两个目录。

#### `Makefile`
- 增加 `plugins`、`plugins-test` target。

#### `lib/shared/services/ai/tools_web.dart`
- 删除。

#### `lib/third/html2md/`
- 删除；只有 Web 工具使用。

#### `test/shared/services/ai/tools_web_test.dart`
- 用例迁移到 `plugins/web/test/` 后删除。
