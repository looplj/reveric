# 内置联网检索插件

正式源码位于 `src/`，类型契约位于 `../sdk/`，构建产物提交到 `assets/plugins/reveric.web/`。使用 Node.js 22 或更高版本（`.nvmrc` 推荐 22），在仓库根目录运行 `make plugins` 和 `make plugins-test`。Flutter 构建只读取已提交产物，不需要 Node。

`probe_test.dart` 现在验证正式产物的清单一致性、激活及两个工具的真实 fjs 调用。设置 `FJS_PROBE_LIBRARY` 后运行 `fvm flutter test plugins/web/probe_test.dart --concurrency=1`。Windows、Android 的原生验证仍待对应设备完成。

以下保留早期可行性测量记录，反映当时的探针实现。旧构建与压力测试命令仅用于理解历史证据；探针源码可从 Git 历史查看，`results/` 中的本地测量文件继续保留。正式迁移不增加正文提取或相对链接优化。

---

# WebFetch / WebSearch 可行性验证

2026-10-30，依据本轮开始时读取的未提交插件方案（当时路径为 `docs/solutions/wip-plugin-system.md`）。本目录是隔离探针，不是已接入应用的插件 SDK 或完整 Web 工具迁移；没有改动生产代码、数据库或方案文档。

## 结论

**JS 插件运行路径可行；WebFetch 的正文质量需要补齐；百度无 Key 搜索的稳定性尚未验证通过。**

- macOS arm64 上，真实 fjs 可在 `JsBuiltinOptions.none()` 下加载约 269.2 KiB 的单文件包，执行 `apply(context)`，注册两个工具，并通过 Dart HTTP → JSON → JS Promise 返回结果。没有开放 `process`、`require`、原生 `fetch` 或 DOMParser。
- 四个真实网页全部抓取和转换成功。真实页面性能比人工密集样本更适合作为主要判断依据，当前证据支持继续实现，不建议因为压力样本直接否定方案或把默认堆上限提高到 256 MiB。
- 直接把整页转 Markdown 再截取前 10,240 字符，可能只返回导航。英文 Wikipedia 样本截断在语言菜单中；Dart 文档的主标题到约第 9,812 字符才出现。转换成功不等于正文可用，需要在截断前确定正文提取策略。这也是现有整页转换路径需要关注的问题，不能把它全部归因于插件化。
- 百度中英文两次查询均返回 HTTP 200、1,488 字节的“百度安全验证”页面，插件明确返回 `blocked`。只能证明请求和失败识别链路可用，不能声称搜索成功，更不能据此断言所有网络下都不可用。没有绕过验证码，也没有更换搜索服务。

## 真实页面结果

一次 macOS 本地实测，非多轮统计；HTTP 耗时受网络影响。纯转换耗时是在抓取后，将同一 HTML 在同一 QuickJS runtime 中再次转换测得，不含网络。

| 页面 | HTTP 响应字节 | 请求与插件处理总耗时 | 再次纯转换耗时 | 工具调用后 QuickJS live heap |
| --- | ---: | ---: | ---: | ---: |
| `https://example.com` | 577 | 511 ms | < 1 ms | 1,758,512 B |
| `https://dart.dev/language/async` | 114,702 | 793 ms | 102 ms | 18,574,071 B |
| `https://en.wikipedia.org/wiki/JavaScript` | 707,198 | 2,455 ms | 1,267 ms | 10,991,319 B |
| `https://zh.wikipedia.org/wiki/苏轼` | 432,038 | 2,872 ms | 857 ms | 9,515,745 B |

这些页面共用一个 runtime，heap 包含前面调用留下、尚未 GC 的对象；不是每次请求的增量、峰值，也不是进程总内存。全部在 64 MiB allocator 限制、1 MiB 栈下完成。加载单文件包约 30–43 ms；包大小为 275,702 字节，未 gzip。

## 已验证与发现

1. **打包兼容性**：`node-html-markdown 2.0.0` 的 `dist/utilities.js` 两处直接读取 `process.env.LOG_PERF`。最初运行报 `ReferenceError: process is not defined`。构建时用 `--define:process.env.LOG_PERF=false` 消除此调试分支后通过；不需要补整个 Node 环境。版本与依赖已锁定。
2. **结果结构与文本**：两个工具名、description、参数 schema 从现有 Dart 原文复制。成功路径验证了中文、实体、标题、粗体、表格和代码块；脚本正文不会进入结果。探针未声称完成所有错误字段和输入容错的兼容。
3. **相对链接**：转换库保留 `/relative`，不会自动变成绝对 URL。正式实现需要明确基于最终响应 URL / HTML base 的链接与图片地址处理。
4. **失败识别**：HTTP 503、百度验证页、未知搜索 HTML 返回明确失败；未知搜索 HTML 不伪装成空搜索结果。普通正文包含 `captcha` 仍可转换。探针最初按全文关键词识别验证码，误判了 Wikipedia 的站点配置脚本，已改为现有工具的标题和结构特征判断，并补回归样本。
5. **中断**：真实 fjs `close()` 能结束等待 Host bridge 的执行和死循环；关闭后再完成 Host Future 没有让已取消调用恢复。这里只证明 JS 生命周期收口，**没有证明取消 JS 会自动取消 Dart HTTP 请求**；正式 Host 需要自行管理请求取消和超时。
6. **容量边界（次要证据）**：人工重复 HTML，不是真实网页。13,000 字符约 24 ms，130,000 字符约 427 ms。1,300,000 字符在 64 MiB 下失败，报 `Runtime error: null`，不能声称拿到了准确的 OOM 错误码；同内容在 256 MiB 下完成约 23 秒、结束时 live heap 约 78.9 MB。内存预算对照支持资源限制假设，但该高节点密度样本不能代表普通大网页。压力用例默认关闭，单独用 `WEB_PROBE_STRESS=true` 启用。
7. **静态分析**：探针起初因 `print` 命中 `avoid_print`，已改为 `stdout.writeln` 输出基准记录，并重新分析。

## 复现

从仓库根目录运行；Node 仅用于构建，应用运行插件不需要 Node。当前锁定 `node-html-markdown 2.0.0`、`node-html-parser 6.1.13`、`esbuild 0.25.12`。原生层使用仓库本地覆盖的 fjs 3.3.1；本次 `build_runtime.sh --verify` 验证了本地打包归档。

```sh
npm ci --prefix plugins/web --ignore-scripts
npm run build --prefix plugins/web
mkdir -p plugins/web/results
bash third/fjs/tool/build_runtime.sh --verify
unzip -oq third/fjs/darwin/fjs/Binaries/fjs.xcframework.zip 'fjs.xcframework/macos-arm64/*' -d plugins/web/results
export FJS_PROBE_LIBRARY="$PWD/plugins/web/results/fjs.xcframework/macos-arm64/fjs.framework/Versions/A/fjs"
timeout 120 fvm flutter test plugins/web/probe_test.dart --reporter expanded
timeout 240 fvm flutter test plugins/web/probe_test.dart --dart-define=WEB_PROBE_LIVE=true --reporter expanded
fvm flutter analyze plugins/web/probe_test.dart
```

Flutter 测试串行运行。`timeout` 需要本机已有对应命令。上面的 native library 解包路径仅适用 macOS arm64；Windows/Android 需要对应平台实际构建的库与执行环境，未验收。

本次实际运行了 build、native archive verify、带 LIVE 的测试及 analyze。LIVE 轮为 **5 个通过、1 个跳过**（压力用例）；最后离线轮为 **4 个通过、2 个跳过**（LIVE、压力）。此前压力对照已实际执行通过。LIVE 用例中的断言验证返回协议，不将网络供应商返回失败视为测试框架失败，故“测试通过”不代表百度可用。

`results/representative.log` 保存真实页面测量，`results/call-*.json` 保存工具返回内容供人工复核，`results/offline.log` / `results/analyze.log` 保存最终离线测试与分析；这些以及下载 HTML、native 解包产物、`node_modules`、`dist` 都已忽略，不应提交。需要复核网页变化时重新运行 LIVE；本目录不将抓取的第三方网页作为永久 fixture。

## 正式接入前仍需完成

- 正文提取、相对 URL、HTTP 重定向后的最终 URL、百度 JS/meta 跳转、字符编码、输入校验、错误字段、截断 warning 等，按原工具回归测试逐项迁移。当前探针仅有简化 HTTP 与解析实现，不能直接替换 `tools_web.dart`。
- Host 的请求总时限、流式大小限制、取消资源释放，以及内存耗尽错误分类。不要把当前单次 Codemode 的 64 KiB 源码预算直接套到约 269 KiB 的插件包上。
- 插件宿主的停用/撤销、重复注册、激活回滚、第三方覆盖、工具发现与 Agent 调度边界；本目录注册表只是内存探针，未验证正式 M1 宿主。
- Windows、Android 的实际加载、性能、取消与错误路径。本次是 macOS native library + Flutter test，不是三平台 UI/发布包验收。
- 换不同网络/地区验证百度成功搜索及搜索→抓取链路。若需要稳定搜索 API，再评估带 Key 的第三方插件；本次没有证明现有默认无 Key 方案达到发布可靠性。

参考：[node-html-markdown 官方仓库](https://github.com/crosstype/node-html-markdown)。实际兼容结论以本目录锁定依赖及真实 fjs 测量为准。
