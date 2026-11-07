# 代码风格规则

## 控制流

- **所有控制流语句（`if`、`else`、`for`、`while`、`do-while`）必须使用大括号 `{}`**，即使只有单条语句。
- 禁止省略大括号的单行写法，例如 `if (condition) doSomething();` 一律改为 `if (condition) { doSomething(); }`。
- 该规则通过 `curly_braces_in_flow_control_structures` lint 强制生效。

## 日志入口与模块

- 业务日志统一通过 `AppLogger.forModule('ModuleName')` 创建的模块日志器输出，包括启动、生命周期和全局错误桥接。静态 `AppLogger` 输出方法仅供日志封装内部使用；级别配置仍通过 `AppLogger` 管理。
- 文件顶部声明 `final _log = AppLogger.forModule('ModuleName');`，或在实例中持有一次创建的日志器；不要在打印时、getter 或 `build()` 中反复创建。已有模块日志器直接复用。
- 模块名使用稳定的业务名称。供应商类型、插件 ID、会话 ID 等动态值放进消息字段，不拼入模块名；移除消息里重复的模块前缀，但保留 `[DB]`、操作名称、记录 ID、错误对象和堆栈等诊断信息。

## Debug / Trace 日志

- 动态 debug / trace 日志必须先在调用处判断模块日志器的 `isDebugEnabled` / `isTraceEnabled`，再构造消息。这些 getter 与实际输出共享运行时级别判断，保留 Release 动态开启诊断日志的能力。
- 字符串插值、JSON 编码、堆栈获取、集合遍历及仅用于日志的中间计算，全部放进判断分支；不要先计算再判断。
- 不使用消息回调或闭包式延迟日志接口：关闭时也应避免创建消息闭包。仅在 `debug(String message)` 内过滤无法省掉调用前的参数求值。
- 固定字符串可以直接调用 `debug` / `trace`，日志入口负责提前过滤。不要统一用 `kDebugMode` 或 `assert` 禁用 Release 诊断日志。
- 临时排查结束后清理逐步打点、重建日志、无条件堆栈及只为这些日志存在的变量、Hook 和注释代码；保留有排障价值的诊断信息。

```dart
final _log = AppLogger.forModule('Example');

if (_log.isDebugEnabled) {
  final payload = jsonEncode(result);
  _log.debug('result=$payload');
}

if (_log.isTraceEnabled) {
  _log.trace('stack=${StackTrace.current}');
}
```

## Dart 文件头

- 每个新增 Dart 源文件顶部必须包含：
  - `// 职责:`：用一句话描述文件唯一职责，说明“做什么”而非“是什么”。
  - `// 关联文件:`：列出 1–5 个直接依赖或协同的业务文件，每行一个。
  - `// 遵循的 Rules:`：可选但鼓励填写；使用 flutter_hooks 的文件必须列出 `.agents/rules/hooks.md`。
- 修改已有 Dart 文件时，仅当职责偏离原注释或规则依赖变化时更新文件头；不要为无关修改重写文件头。
- 包含用户可见文案的文件还必须在 `// 关联文件:` 中列出 `lib/shared/localization/locale_keys.dart`，以及实际使用 namespace 对应的 en / zh-CN 翻译文件。这些强制 i18n 引用不计入 1–5 个业务关联文件上限。
- 格式示例：

  ```dart
  // 职责: AI 聊天面板 — 展示消息并编排发送、取消和 stream 渲染
  // 关联文件:
  //   lib/shared/services/ai/chat.dart
  //   lib/shared/providers/ai_providers.dart
  //   lib/shared/localization/locale_keys.dart
  //   assets/translations/en/ai.json
  //   assets/translations/zh-CN/ai.json
  // 遵循的 Rules:
  //   .agents/rules/state-management.md
  //   .agents/rules/hooks.md
  ```
- `.md` 文件（包括 `assets/prompts/` 中的 prompt 模板）不适用 Dart 文件头规则。

## 代码注释

- **代码注释不记录临时发布状态**：禁止在源码注释中写“某版本尚未发布”“当前还没上线”等会随发布过程失效的状态判断。注释只说明稳定的技术行为、约束和兼容原因，迁移版本号及其对应改动可以保留。判断版本是否发布，必须核对本地最新正式发布 tag 及其对应代码；不得仅凭源码注释、当前分支或 `pubspec.yaml` 的版本号决定 migration 策略。
