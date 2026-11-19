# 文件访问与移动端存储

适用于文件选择、目录选择、附件、导入、导出、备份、临时文件、`File` / `Directory`、`XFile`、`getDirectoryPath`、Android 原生文件桥接等改动。

## 核心模型

- 用户从系统选择器选中的资源不是普通路径。Android SAF 返回 `content://` URI，iOS 可能返回 security-scoped URL；不能因为 API 类型是 `String` 或 `XFile.path` 就直接交给 `dart:io`。
- `dart:io File/Directory` 只直接用于：App 自己的 `applicationSupport` / `documents` / `cache` / `temporary` 目录，以及桌面端明确可访问的普通文件系统路径。移动端用户目录必须经过平台适配层。
- 文件选择与目录选择不是同一份契约：某些插件会把单文件复制到缓存后返回可读路径，但目录选择可能只返回不可直接遍历的 URI 或转换后的裸路径。必须分别验证，不能用单文件导入成功推断目录导入可用。
- 先区分资源的三种身份：系统 URI（访问授权）、App 临时副本路径（`dart:io` 读取）和展示名称（数据库标题/UI）。展示名称不能从临时副本路径推导。

## 作品登记与内容库路径

- 查询作品归属、比较作品身份、校验作品类型及读写作品元数据时，只能使用作品 ID。需要归属的入口由上游显式传入作品 ID，禁止按内容库路径反查、比较或从文件名推断作品身份。
- `contentDatabasePath`、解析后的绝对路径及 Windows 8.3 短路径只用于打开、缓存、备份和访问内容库文件。读取已有登记时兼容 `/` 和 `\` 两种相对路径。
- 修改作品归属判断时，回归测试应覆盖两个作品共享路径或同一文件有不同路径表示的情况，并验证读写落在指定作品 ID。

## 移动端导入

- Android 目录导入必须使用 SAF `ACTION_OPEN_DOCUMENT_TREE` 的 URI 读取能力；不要把 `file_selector.getDirectoryPath()` 的结果直接用于递归 `Directory.listSync()`。
- 需要递归导入时，在系统授权仍有效的阶段通过原生 `ContentResolver` / `DocumentsContract` 遍历并复制到 App cache，再调用共享 Dart 导入服务。复制失败必须返回明确错误并清理已创建的部分临时目录。
- 原生桥接应在后台线程执行 IO，在主线程回调 Dart；取消返回 `null`，成功返回固定、静态的结构化契约，失败返回错误 code/message。回调必须恰好一次，并处理重复调用/进行中的请求。
- Android 原生层和 Dart 层的可导入扩展名、隐藏文件/目录规则、递归语义必须保持一致。新增或修改扩展名时同步修改两端和测试；不支持的文件不要复制，也不要把“没有可导入文件”伪装成异常。
- 单文件或多文件导入仍可使用 `openFile/openFiles`，但读取前必须确认插件是否已经把 URI 内容复制到可读路径；不要复用目录导入的假设。
- iOS 没有可用的目录选择器时，必须提供多文件选择、ZIP 导入或其他用户可理解的替代路径；不能显示一个点击后必然失败的目录入口。

## 移动端导出与备份

- 不能把 Android/iOS 选择器返回的目录路径当作可写目录，直接用 `File.writeAsString`、`rename` 或 `Directory.create` 写入。
- 导出优先写入 App 临时目录后交给系统 Share / Save 面板；若产品要求写入用户选择的目录，必须使用对应平台的 URI 写入 API，并覆盖权限拒绝、取消和部分写入失败。
- 备份自动任务只能使用 App 私有目录。用户选择的外部目录、系统 URI 授权和自动备份配置不能混用。

## 临时文件与数据安全

- 临时副本必须放在 App cache/temporary 下，用唯一前缀或随机 ID 隔离；导入成功、失败、取消和页面销毁都要走 `finally` 清理。
- 只允许删除本次操作创建且位于 App 临时目录的副本；禁止根据用户选择的路径递归删除源目录。业务数据删除仍遵循 `.agents/rules/data-deletion.md`。
- 原生复制必须防止文件名路径穿越，拒绝空名、`.`、`..`、隐藏项和非法分隔符；不要把系统提供的显示名直接拼接成未校验的目标路径。
- 目录导入只复制需要的文件类型，避免把整棵用户目录无界复制进 cache；大目录需要有数量/大小边界或至少记录统计。

## 错误处理与日志

- 禁止 `catch (_) {}` 或把 `existsSync() == false` 静默转换为 `(0, 0)`。取消、目录不可读、枚举失败、文件读取失败、解析失败和数据库写入失败必须可区分。
- UI 可以展示统一的本地化失败文案，但技术细节必须写日志并保留异常和 stack trace。日志至少包含：操作、平台、阶段、资源类型、成功/失败、文件/目录数量和错误类型。
- 日志默认不记录文件正文、完整用户路径、URI 授权 token 或凭据；需要判断路径边界时记录 `content/file/absolute/relative` 等路径类型和经过脱敏的文件名信息。
- 导入服务必须在开始、选择结果、复制/枚举、单文件读取、汇总和清理阶段记录可判定日志，确保下一次能区分“选择器没返回”“返回后不可读”和“全部被过滤”。

## 跨平台与验证

- 修改任何文件选择/导入/导出代码后，必须逐一检查 Windows、macOS、Linux、Android 的调用方和平台实现；不能只改当前看到的页面。
- 用 `rg` 全仓扫描同类 API：`getDirectoryPath`、`openFile(s)`、`File(`、`Directory(`、`XFile.path`、`ACTION_OPEN_DOCUMENT_TREE`。每个命中点要明确是普通路径、URI、App 私有路径还是临时副本。
- 至少覆盖：取消选择、单文件、嵌套目录、中文名、`.txt/.md/.csv`、不支持扩展名、隐藏项、空文件、权限/Provider 失败、部分文件读取失败和临时目录清理。
- Flutter 测试必须串行并使用 FVM；涉及原生桥接时，除了 Dart MethodChannel 单测，还必须运行 Android Debug/Release 编译，并在真实 Android 设备或等价 SAF 环境手工验证 `Downloads`、主存储、外部存储/云盘等 Provider。
- 真机验证记录选择器返回形态、复制文件数、导入/跳过数和最终数据库结果；“APK 能编译”不能替代文件访问运行时验证。

## 当前已知使用点

- `lib/mobile/services/android_saf_directory_import.dart` 是文档目录导入的 Android SAF 适配入口；新的移动端目录导入优先复用它，除非文件布局或写入语义不同。
- `lib/mobile/features/agent_skills/novel_agent_skill_manage_page.dart` 的 Agent Skill 目录导入/导出必须复用 Android SAF 适配入口；导出不得把选择器返回值当作普通目录路径写入。
- `lib/shared/widgets/settings/backup_settings_section.dart` 的移动端自定义备份目录必须保持禁用；备份通过临时文件和系统导出面板完成。
