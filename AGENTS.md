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

多步骤、长耗时或高风险任务在阶段边界简要汇报已完成、已验证和剩余工作；简单任务不需要制造中间 checkpoint。

## 外部文档查询

- 仅用户明确指定 `find-docs` 时，才使用该技能及 Context7；不自动触发或直接调用 `ctx7` 绕过限制。
- 查询只包含必要的通用技术问题，不发送项目名、内部路径、业务数据或私有实现细节。

## 常驻安全边界

- `docs/` 是方案归档目录。除非用户明确要求查看、修改或同步具体文档，否则不要读取、搜索或修改；常规残留扫描默认排除 `docs/`。
- 用户业务数据默认软删除。新增任何 DAO `hardDelete`、SQL `DELETE` 或业务数据文件删除前，必须获得用户对具体范围的明确确认；已有例外见 `.agents/rules/data-deletion.md`。
- 不得静默修改需求、公共 API 或外部系统状态。修改 entitlement、manifest、plist、sandbox 等平台权限时，同步检查所有目标平台。
- **设计 mockup 前必须确认落点**：每次要产出或修改设计稿时，先向用户确认是新建独立文件，还是在 `designs/desktop/`、`designs/mobile/` 等已有 mockup 上改。不要默认新建一个独立 HTML/JSX 项目——`designs/` 下已有成套的 UI Kit、组件和数据，另起炉灶会分叉设计系统。
- **发布状态只核对最新正式发布 tag**：判断当前 schema、打包官方技能版本等是否已发布，核对本地最新正式发布 tag 及该 tag 中的相关代码即可，不遍历全部历史 tag。仅在用户明确要求历史追溯，或已有证据表明存在多条发布线、最新 tag 无法代表目标发布线时，才扩大核查范围。

## Rule 路由

命中场景时先完整阅读对应文件，再动手。Rule 是项目硬约束，不是可选参考。

| 触发场景 | 必读规则 |
| --- | --- |
| 新增或修改 Dart 文件、源码注释与文件头 | `.agents/rules/code-style.md` |
| 新增、移动、重命名文件或调整目录结构 | `.agents/rules/directory-structure.md` |
| 新增/移动页面、Widget 或 feature | `.agents/rules/directory-structure.md`、`.agents/rules/widget-decomposition.md` |
| 编辑表单、字段滚动与生命周期、多字段校验、提交或重置 | `.agents/rules/form.md`；外部 controller / CJK IME 再读 `.agents/rules/text-input-ime.md` |
| Hooks 或 Riverpod | `.agents/rules/hooks.md`、`.agents/rules/state-management.md` |
| Service / Orchestrator | `.agents/rules/service-naming.md` |
| UI、主题、间距、背景、输入框与下拉控件、操作菜单与 Select、横向滚动、内容刷新或高频重建 | `.agents/rules/design-system.md`、`.agents/rules/performance.md`；桌面页面根、页头（包括嵌入区域）或窗口按钮避让再读 `.agents/rules/desktop-window-frame.md` |
| 新增或修改图标 | `.agents/rules/icons.md` |
| 新增、修改或删除用户可见文案、AI 提示词 | `.agents/rules/i18n.md` |
| 搜索、过滤或昂贵 query | `.agents/rules/search-debounce.md` |
| 文件选择、目录选择、附件、导入、导出、备份、临时文件或移动端路径 | `.agents/rules/file-access.md` |
| 错误、fallback、必备依赖或 DB 写日志 | `.agents/rules/error-handling.md` |
| 第三方 library / SDK 或本地 dependency override | `.agents/rules/local-dependencies.md` |
| AI 文本生成或 Agent Read field path | `.agents/rules/ai-calling.md`、`.agents/rules/tools_path.md` |
| AI 工具行为、参数兼容、描述、input schema 或结果序列化 | `.agents/rules/ai-calling.md`；错误结果再读 `.agents/rules/error-handling.md` |
| 新增或调整应用内 bundled / official Skill、触发条件、references、注册或加载入口 | `.agents/rules/agent-skills.md` |
| Drift schema 结构、约束或 migration | `.agents/rules/db-migration.md` |
| Drift index / timestamp / 聚合 / JSON | 按改动读取 `.agents/rules/db-index-naming.md`、`.agents/rules/db-timestamps.md`、`.agents/rules/db-query-aggregation.md`、`.agents/rules/json.md` |
| 删除业务数据 | `.agents/rules/data-deletion.md` |
| 枚举值或 form 字段枚举 | `.agents/rules/enum-naming.md` |
| 运行测试、测试选择、回归测试、Widget 测试隔离或测试挂起排查 | `.agents/rules/testing.md` |
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
- 只报告实际执行的命令与结果；测试被跳过、没有对应测试或环境无法运行时，说明原因和替代验证。

## 运行时日志位置

排查客户端运行问题时，先看 app 容器日志（`logs/latest.log` 为当前运行实例，`logs/startup_*.log` 为各次启动）：

- **macOS Debug**：`~/Library/Application Support/ai.reveric.debug/logs/`
  （Debug 包 bundle id 为 `ai.reveric.debug`）
- **macOS Release**：`~/Library/Application Support/ai.reveric/logs/`
  （Release 包 bundle id 为 `ai.reveric`）

排查外部服务时，只按用户提供的部署信息查找日志；不预设本项目带有配套服务或关联仓库。
