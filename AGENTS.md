# Reveric — Agent 项目指南

本文件适用于整个仓库。用户的明确要求优先；若要求与本文件的安全边界或项目约定冲突，先说明冲突和影响，不要静默折中。

## 本地项目背景

涉及项目来源、上游对照、版本分叉、双向合并、开源范围，或新增、移动、重命名文件及调整目录结构时，若存在 `.agents/local/project-context.md`，先读取该文件。该文件仅供本地参考，不得将其内容复制到提交、PR 或公开文档中。

## 支持平台

当前支持的平台为 **Windows、macOS、Android**。平台适配、构建、测试与验收以这三个平台为范围。

## 工作契约

1. **先读后写**：修改前读取导出、直接调用方、共享工具、现有测试和命中的规则。不了解结构原因时先停下来说明。
2. **目标驱动**：开始前声明关键假设和可验证的成功标准；围绕目标迭代，完成前逐项闭环。
3. **分级处理不确定性**：存在多种合理解释时先列明。局部、可逆的事项声明假设后继续；会改变需求、数据、公共契约或外部状态的歧义必须询问用户。
4. **最小且遵循现状**：采用满足需求的最简单方案；有更简单路径时主动指出。只改必要范围，不顺手重构，不为单次使用提前抽象，并遵循代码库既有约定。
5. **冲突先确认再处理**：遇到 Git merge/rebase 冲突、DB migration 版本冲突、生成文件冲突，或任何存在多种语义取舍的冲突时，先只做只读检查（status、冲突标记、base/feature 两侧 diff），再向用户说明冲突文件、双方意图、拟采用的真源、数据/API/迁移影响和验证方案，并等待用户确认。确认前不得编辑冲突文件、`git add`、`git rebase --continue/--skip/--abort`，也不得改动迁移、公共 API、业务数据；若后续出现与已确认范围实质不同的新冲突，必须再次确认。
6. **冲突只选一个真源**：用户确认方案后，两个模式仍矛盾时，采用更新、被测试或与仓库现状一致的一种，说明依据，并指出另一种需要清理；不要混合两套模式。
7. **失败后回到根因**：同一方向失败后不继续叠 provider override、fallback 或兼容补丁。重新验证假设；若测试价值低于隔离成本，重新评估测试本身。
8. **边界优先**：Page/shell 只组合区域和管理页面生命周期；region 拥有独立可见区域；本地编辑态用 Hooks / `lib/third/form`，跨页面状态用 Riverpod，多步 DB/文件/网络/AI 写入用 Orchestrator。拆分细则见 `.agents/rules/widget-decomposition.md`。
9. **如实完成**：未运行、被跳过、失败或存在不确定性的验证必须明确报告；不能把它们描述成完成或通过。
10. **跨平台影响检查**：用户只针对 desktop/mobile 提出新增功能或修复 bug 时，必须检查另一平台是否也需要同步改动；若无法从代码和需求确定，先向用户确认，不得默认只修改当前平台。
11. **表单禁止惰性回收字段**：桌面与移动端的编辑表单不得使用 `ListView`（含 builder/separated）或 `SliverList` 承载字段、编辑卡片；即使有外部 controller，也不能依赖离屏字段继续参与 `Form.validate()`。固定字段表单统一使用 `SingleChildScrollView + Column`，让编辑态和校验随整个表单存活。与大量只读条目混排时，使用 `CustomScrollView`，将完整编辑区放在不惰性回收的 `SliverToBoxAdapter` 中，只读条目可用 `SliverList`。候选项、搜索结果、历史记录等展示／选择列表不受此限制；富文本编辑器内部的专用虚拟化不按普通表单处理，但必须由编辑器统一持有文档状态。不得用扩大 `cacheExtent` 代替生命周期修复。
12. **窗口按钮避让不得带动页面标题下移**：Windows 右上角窗口按钮只约束与其重叠的操作区；页面标题保持原有顶部基线，不得为了右侧按钮避让或对齐侧面板而给整个页头增加顶部 padding。修改桌面页头（包括嵌入区域）前必读 `.agents/rules/desktop-window-frame.md`，分别验证标题位置、操作区避让和下方内容位置，并显式覆盖 Windows、macOS、Linux 布局分支；只在宿主平台跑过测试不算跨平台验证。

多步骤、长耗时或高风险任务在阶段边界简要汇报已完成、已验证和剩余工作；简单任务不需要制造中间 checkpoint。

## 外部文档查询

- 仅用户明确指定 `find-docs` 时，才使用该技能及 Context7；不自动触发或直接调用 `ctx7` 绕过限制。
- 查询只包含必要的通用技术问题，不发送项目名、内部路径、业务数据或私有实现细节。

## 常驻安全边界

- `docs/` 是方案归档目录。除非用户明确要求查看、修改或同步具体文档，否则不要读取、搜索或修改；常规残留扫描默认排除 `docs/`。
- 用户业务数据默认软删除。新增任何 DAO `hardDelete`、SQL `DELETE` 或业务数据文件删除前，必须获得用户对具体范围的明确确认；已有例外见 `.agents/rules/data-deletion.md`。
- 不得静默修改需求、公共 API 或外部系统状态。修改 entitlement、manifest、plist、sandbox 等平台权限时，同步检查所有目标平台。
- **设计 mockup 前必须确认落点**：每次要产出或修改设计稿时，先向用户确认是新建独立文件，还是在 `designs/desktop/`、`designs/mobile/` 等已有 mockup 上改。不要默认新建一个独立 HTML/JSX 项目——`designs/` 下已有成套的 UI Kit、组件和数据，另起炉灶会分叉设计系统。
- **数据库默认只用列和索引**：新增或修改 schema 时，默认可用的结构只有列（类型、可空、默认值）、索引、Drift 的 `primaryKey` 声明，以及项目既有的时间戳与软删除列写法。其余 SQLite / Drift 特性一律默认不用：CHECK、表级 `customConstraints`、表级 UNIQUE、FOREIGN KEY 及其级联行为、触发器、视图、生成列、虚拟表与 FTS、AUTOINCREMENT、自定义 collation。确有必要时，先说明为什么 Dart 侧校验不够、改动代价与迁移方案，获得用户明确确认后再写。
  - 理由是它们改不动：SQLite 没有 `ALTER TABLE ... DROP/ADD CONSTRAINT`。CHECK 里多一个枚举取值、外键换一种级联行为，都要走「建新表 → 复制数据 → 删旧表 → 改名」重建整表并在迁移里重放；列和索引可以 `ADD COLUMN` / `CREATE INDEX` 原地完成。
  - 取值范围、必填组合、跨字段互斥这类规则写在 Dart 侧：模型校验、service 校验和静态 tool schema。同一条规则不要 SQL 和 Dart 各写一遍。
  - 已有的约束保持原样，不顺手补齐也不顺手删除；要改按上面的确认流程走。
- **发布状态只核对最新正式发布 tag**：判断当前 schema、打包官方技能版本等是否已发布，核对本地最新正式发布 tag 及该 tag 中的相关代码即可，不遍历全部历史 tag。仅在用户明确要求历史追溯，或已有证据表明存在多条发布线、最新 tag 无法代表目标发布线时，才扩大核查范围。
- **代码注释不记录临时发布状态**：禁止在源码注释中写“某版本尚未发布”“当前还没上线”等会随发布过程失效的状态判断。注释只说明稳定的技术行为、约束和兼容原因，迁移版本号及其对应改动可以保留。判断版本是否发布，必须核对本地最新正式发布 tag 及其对应代码；不得仅凭源码注释、当前分支或 `pubspec.yaml` 的版本号决定 migration 策略。
- **未发布版本的 migration 合并**：经本地最新正式发布 tag 及其对应代码核实，确认当前 schema 尚未发布时，新增字段可以合并进现有 migration，保持 `schemaVersion` 不变；不要为本地开发库额外添加运行时幂等补列、fallback 或兼容层。直接用 SQLite skill 的 `ALTER TABLE ... ADD COLUMN` 手动升级开发数据库，并查询验证结果。已发布的 schema 必须新增 schema version 和正式 migration，不能追加到旧 migration 代替用户升级。
- **打包官方技能按发布状态维护版本**：修改技能主文件或 references 附件前，先核对本地最新正式发布 tag 及其对应代码中的技能版本，不能仅凭当前分支、源码注释或版本号判断。当前技能版本已发布时，修改内容必须递增 `version`；经核实尚未发布时，将修改合并到当前版本，保持 `version` 不变。两种情况都同步更新 `contentHash` 和 `updatedAt`；hash 测试只校验内容一致性，不能证明是否需要升版本。保持版本号的开发修改不会触发已安装技能的自动升级，必须使用 SQLite skill 同步更新 Debug 数据库中该技能的官方安装快照、附件及相关内容指纹，并查询验证；没有安装记录时说明无需更新，不为此新增安装。保留安装 ID、启用状态、排序和历史记录，不覆盖已转本地或用户自定义的技能，不改 Release 数据库，也不为开发数据新增运行时兼容层。具体版本的发布状态只记录在本次核查结果中，不写入源码注释。
- Flutter 测试必须串行运行。未运行、无对应测试或环境不可用时，明确说明最接近的验证方式。

## 提示词与 i18n

- **工具结果必须可 JSON 序列化**：成功和失败结果中用于模型返回、会话状态及持久化的 payload（包括嵌套的 `details`、`_metadata`）只能包含 `null`、字符串、布尔值、有限数值、List 和字符串键 Map。内部可用 Set 做去重或差集，但在构造结果时必须转为 List；DateTime、枚举、异常和领域对象必须按明确契约转换，不能直接塞入结果。`Object?` / `dynamic` 不代表可编码，禁止用通用 `.toString()` 兜底掩盖类型错误。新增或调整统一结果校验时，必须放在工具完成回调（如 `_emitToolFinished`）和会话状态写入之前，覆盖模型返回与持久化两条路径；不得只在最终 `jsonEncode` 处处理。不可编码结果应返回可编码的明确工具错误，保留可编码的诊断信息，并记录问题字段路径及实际类型，不能让原始结果污染会话。此类缺陷的回归验证应使用实际工具结果执行 JSON 编码，并检查错误详情保留，不能只断言 `ok: false`。
- **错误信息区分用户与 Agent**：禁止直接暴露底层报错的规则仅针对面向用户的 UI、Toast、SnackBar、Dialog 等展示，不适用于返回给 Agent 的工具结果。底层报错指异常对象、SDK / HTTP 原始报错、堆栈和完整响应体；服务商在响应中返回的可读错误文案（如 `error.message`）不属于底层报错，界面可以直接展示。工具结果应保留实际错误码、底层错误消息及命令诊断日志，供 Agent 判断原因和处理失败；不得仅返回笼统的“操作失败”，或只把详情写入日志而不提供给 Agent。用户界面另行转换为可理解的说明。
- **修改 tool description 前必须获得用户明确确认**：包括工具整体描述和 input schema 中的参数 `description`。先说明拟修改的具体文案及原因，确认后再改；修复工具行为或增加容错不代表获准同步修改描述。
- **任何 AI 提示词都不需要 i18n**，包括 system prompt、用户消息模板、开场提示词、工具提示词及动态拼接的提示词；即使会显示在聊天记录或输入框中，也不例外。
- 提示词直接维护一份共用文本，不新增 locale key 或多语言翻译条目，不因界面语言切换提示词。这条规则优先于用户可见文案的 i18n 要求；仅包含提示词的文件也无需添加 i18n 文件头引用。
- 按钮、标题、说明、占位符等界面文案仍遵循原有 i18n 规则。
- **通用动作复用 common i18n**：上下文已明确操作对象时，新建、重命名、删除、保存、取消等按钮和菜单只使用动作名称，优先复用 `common.*`，不要为每种业务对象新增重复 key（如“重命名集合”“删除集合”）。修改前先检查已有 common key；缺失时补充通用 key 及中英文翻译，并同步桌面端、移动端引用。删除确认、操作后果等包含业务语义的完整说明保留专用 key，不用通用词拼接句子；替换后清理无引用的旧 key 和翻译。

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

## Rule 路由

命中场景时先完整阅读对应文件，再动手。Rule 是项目硬约束，不是可选参考。

| 触发场景 | 必读规则 |
| --- | --- |
| 修改任意 Dart 文件 | `.agents/rules/code-style.md` |
| 新增/移动页面、Widget 或 feature | `.agents/rules/directory-structure.md`、`.agents/rules/widget-decomposition.md` |
| 多字段编辑、校验、提交或重置 | `.agents/rules/form.md`；外部 controller / CJK IME 再读 `.agents/rules/text-input-ime.md` |
| Hooks 或 Riverpod | `.agents/rules/hooks.md`、`.agents/rules/state-management.md` |
| Service / Orchestrator | `.agents/rules/service-naming.md` |
| UI、主题、间距、背景、输入框与下拉控件、操作菜单与 Select、横向滚动、内容刷新或高频重建 | `.agents/rules/design-system.md`、`.agents/rules/performance.md`；桌面页面根、页头或窗口按钮避让再读 `.agents/rules/desktop-window-frame.md` |
| 新增或修改图标 | `.agents/rules/icons.md` |
| 新增、修改或删除用户可见文案 | `.agents/rules/i18n.md` |
| 搜索、过滤或昂贵 query | `.agents/rules/search-debounce.md` |
| 文件选择、目录选择、附件、导入、导出、备份、临时文件或移动端路径 | `.agents/rules/file-access.md` |
| 错误、fallback、必备依赖或 DB 写日志 | `.agents/rules/error-handling.md` |
| 第三方 library / SDK 或本地 dependency override | `.agents/rules/local-dependencies.md` |
| AI 文本生成或 Agent Read field path | `.agents/rules/ai-calling.md`、`.agents/rules/tools_path.md` |
| AI 工具行为、参数兼容、描述或 input schema | `.agents/rules/ai-calling.md` |
| 新增或调整应用内 bundled / official Skill、触发条件、references、注册或加载入口 | `.agents/rules/agent-skills.md` |
| Drift schema / index / timestamp / 聚合 / JSON | 按改动读取 `.agents/rules/db-migration.md`、`.agents/rules/db-index-naming.md`、`.agents/rules/db-timestamps.md`、`.agents/rules/db-query-aggregation.md`、`.agents/rules/json.md` |
| 删除业务数据 | `.agents/rules/data-deletion.md` |
| 枚举值或 form 字段枚举 | `.agents/rules/enum-naming.md` |
| 测试选择、回归测试或 Widget 测试隔离 | `.agents/rules/testing.md` |
| Novel Editor Main / rail | `.agents/rules/novel-editor.md` |
| REST API 或前后端契约 | `.agents/rules/api-contract.md` |

## 生成与验证

- 本地 Flutter 构建、运行、测试、静态分析、依赖与代码生成命令必须使用 `fvm flutter ...`，通过 `.fvmrc` 锁定 SDK；本地禁止使用 PATH 中未确认版本的 `flutter`。仓库 `Makefile` 中的 Flutter targets 保持走 FVM。
- CI 不安装或调用 FVM。GitHub Actions 使用 `subosito/flutter-action` 安装工作流固定的 Flutter SDK，直接调用 `flutter`、`dart` 和 `fastforge`；固定版本必须与 `.fvmrc` 一致。被 CI 调用的共用脚本必须支持该 SDK，不能强制依赖 FVM 或 `.fvm/flutter_sdk`。以下 FVM 代码生成示例适用于本地，CI 使用对应的 `flutter` 命令。
- 修改 `@riverpod`、`@DriftAccessor`、Drift schema、JSON 序列化等生成源后，使用 `make codegen` 或 `fvm flutter pub run build_runner build`，并检查生成 diff；禁止使用 `dart run build_runner ...`。
- **移动或重命名带 `part '*.g.dart'` 的生成源文件时，先删掉旧的 `.g.dart`**。`.g.dart` 顶部的 `part of '<旧文件名>.dart'` 指向一个已经不存在的文件，build_runner 不会报错，而是静默卡死：进程活着但 CPU 归零、无任何输出，看起来像「编译很慢」。用 `git mv` 一起搬 `.g.dart` 也一样会卡，因为文件内容里的 `part of` 不会自动跟着改。
  - 正确顺序：`git mv` 源文件 → **`rm` 旧的 `.g.dart`** → 改源文件里的 `part` 指令 → 跑 codegen。
  - 判断卡死而不是慢：`ps -o etime=,time= -p <pid>` 隔 30 秒看两次，CPU time 不涨就是卡死，重试没有意义。详见 `.agents/rules/testing.md` 中 Flutter 测试挂起的同款判断方法。
  - 排查残留：`grep -rl "part of '<旧文件名>.dart'" lib/`。
- **从生成源里删掉一个类（如某个 `@riverpod` notifier）时，同样先删掉对应的 `.g.dart`**。残留的生成代码还在引用已删除的类，build_runner 解析不了这个 library，症状与上一条完全一样：进程活着、CPU 归零、零输出。
- **`kill` 掉 build_runner 之后必须删锁再重跑**：`rm -f .dart_tool/build/lock/build_runner.lock`。build_runner 用这把锁做单实例互斥，拿不到锁时不报错也不提示，直接静默等待 —— 又是一次「看起来在编译」的假象。锁是被中断的上一次跑留下的，不删就会一直卡。
- 全量 codegen 偏慢或中途失败时，用 `--build-filter` 只生成需要的文件，例如
  `fvm flutter pub run build_runner build --build-filter="lib/shared/providers/canvas_providers.g.dart"`。
  - **`--build-filter` 会删掉过滤范围外的生成文件**：build_runner 把没被选中的 `.g.dart` / `.drift.dart` 当作过期输出直接删除（一次单文件 filter 删掉了 `main.g.dart`、`app_database.drift.dart`、各 DAO 的 `.drift.dart` 等 120+ 个文件），命令本身照常报成功。
  - 跑完必须立刻 `git status --short | grep '^ D'`，把被删的生成文件 `git checkout --` 恢复，再确认 diff 里只剩目标文件。
- 修改文件后运行受影响目录最窄且有意义的测试，具体选择和隔离要求见 `.agents/rules/testing.md`。
- **验证中遇到失败直接修**：测试、静态分析等失败时自行排查根因并修复，不要停下来区分是否本次改动引入，也不要只报告「原有问题」；修复后重跑确认，最终汇报中逐项列出失败现象、根因和修法。
- **本地化 widget 测试必须隔离资源缓存**：使用 `EasyLocalization` + `MergingAssetLoader` 加载真实翻译资源时，在测试文件的 `setUp` 中调用 `rootBundle.clear()`，避免缓存的 Future 跨 `testWidgets` 复用旧的 FakeAsync 队列。遇到「单个用例通过、同文件一起运行失败或子树为空」，先按 `.agents/rules/testing.md` 的「本地化资源的 Future 缓存隔离」做定点对照，不要扩大到全量测试。
- 只报告实际执行的命令与结果；测试被跳过、没有对应测试或环境无法运行时，说明原因和替代验证。

## 运行时日志位置

排查客户端运行问题时，先看 app 容器日志（`logs/latest.log` 为当前运行实例，`logs/startup_*.log` 为各次启动）：

- **macOS Debug**：`~/Library/Application Support/ai.reveric.debug/logs/`
  （Debug 包 bundle id 为 `ai.reveric.debug`）
- **macOS Release**：`~/Library/Application Support/ai.reveric/logs/`
  （Release 包 bundle id 为 `ai.reveric`）

排查外部服务时，只按用户提供的部署信息查找日志；不预设本项目带有配套服务或关联仓库。

## 建模与命名约束

### 文件命名 — 目录即命名空间

- 放入命名目录（如 `assistant/`、`pricing/`、`prompts/`）的 Dart 文件**不要**再在文件名前加目录名前缀。
- 由目录路径承担命名空间职责，文件名保持简洁。
- 正确：`lib/shared/services/ai/assistant/tool_dispatcher.dart`
- 错误：`lib/shared/services/ai/assistant/assistant_tool_dispatcher.dart`
