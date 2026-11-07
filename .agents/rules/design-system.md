# Design System Rules

## 禁止硬编码颜色和样式

- **永远不要**在 widget 中直接写 `Color(0xFF...)` 或 `TextStyle(fontSize: ...)`。
- 所有颜色通过 `RevericTheme.colorsOf(context)` 获取。
- 所有文字样式通过 `RevericTheme.typographyOf(context)` 获取，再用 `.copyWith(color: ...)` 叠加颜色。
- 间距使用 `RevericSpacing.*`，圆角使用 `RevericRadius.*`，尺寸使用 `RevericSizes.*`。

## Theme 引用方式

```dart
final colors = RevericTheme.colorsOf(context);
final typo = RevericTheme.typographyOf(context);

// ✅ 正确
Text('hello', style: typo.ui.copyWith(color: colors.textMuted));
Container(color: colors.surfaceDim);

// ❌ 错误
Text('hello', style: TextStyle(fontSize: 13, color: Color(0xFF8A7D6B)));
Container(color: Color(0xFFF5F0E8));
```

## Token 层级

| 层级 | 文件 | 用途 |
|------|------|------|
| Colors | `lib/shared/theme/reveric_colors.dart` | 语义化颜色 token（surface / text / accent / semantic） |
| Typography | `lib/shared/theme/reveric_typography.dart` | 文字样式（display / body / ui 系列） |
| Spacing | `lib/shared/theme/reveric_spacing.dart` | 间距、圆角、固定尺寸常量 |
| Theme | `lib/shared/theme/reveric_theme.dart` | `RevericThemeData` 组合 + `RevericTheme` InheritedWidget |
| Barrel | `lib/shared/theme/theme.dart` | 统一导出，widget 只需 `import '../../shared/theme/theme.dart'` |

## 图标规范

- 涉及图标时必须先读 `.agents/rules/icons.md`；图标组件、资源来源、新增流程和命名约定以该文件为唯一正文。
- 图标颜色和尺寸仍必须使用本文件定义的 theme token，不得硬编码样式。

## 普通按钮选型

- 普通操作使用 `lib/shared/components/reveric_button.dart` 的 `RevericButton.primary` / `.secondary` / `.text`；破坏性确认使用 `.danger`。
- 组件内部复用 Material 按钮，全局 button theme 仍是颜色、文字和圆角的真源；调用方只传文案、图标、回调、`loading` 与尺寸，不另写 `InkWell + Container` 或覆盖默认样式。
- 尺寸按语义选：默认 `standard` 用于表单提交、弹窗底部、输入框旁和区块头部操作（桌面 36px，与输入框同高；移动端 40px）；`RevericButtonSize.prominent`（40px）只给页面上的主操作，如首页「继续写作」「快速开书」，不要用在表单和弹窗里；`RevericButtonSize.compact`（32px）用于紧凑工具区和行内操作。加载状态由调用方维护，按钮负责在加载时隐藏内容、保留原尺寸并居中显示指示器，同时禁用点击；不要在调用方重新拼进度图标。
- `IconButton`、整行设置项、卡片、选项卡、虚线添加入口和画布控件按各自语义处理，不批量替换成普通按钮。
- 复用已有私有按钮前，核对其是否符合当前组件规范；旧实现本身不是设计依据。

## 图标按钮、筛选项与状态徽标

- 普通纯图标操作使用 `RevericIconButton`（`lib/shared/components/reveric_icon_button.dart`），传图标、已本地化的 `tooltip` 和可空回调。前景、禁用色、圆角继承全局主题，桌面点击区 32px，移动端至少 48px；不要再用私有封装覆盖这些默认值。画布手柄、发送等特殊语义控件保留专门实现。
- 列表筛选使用 `RevericFilterChip`，`count` 可省略，`onTap: null` 表示禁用。选中态为 `accent / onAccent`，由底层 `FilterChip` 提供键盘和选中语义；移动端横向筛选条须为 48px 点击区留足高度。页面导航 tabs 和只读标签不使用它。
- 复选框使用 `RevericCheckbox`（`lib/shared/components/reveric_checkbox.dart`），`onChanged: null` 表示禁用。整行点击和复选框是同一操作时，用 `MergeSemantics` 包住整行，由行内文字提供读屏标签（同 `CheckboxListTile`）；否则传本地化 `semanticLabel`。选中态为 `accent / onAccent`，边框、禁用色、圆角和点击区（桌面 32px、移动端 48px）由组件统一；调用方不再传 `fillColor`、`side`、`activeColor`。整行可点的列表可以把它放进小尺寸 `SizedBox` 只做状态指示，点击区交给整行。
- 只读业务状态使用 `RevericBadge`（`lib/shared/components/reveric_badge.dart`），调用方传本地化文案和主题语义色。业务状态到文案／颜色的映射留在业务组件；不传任意背景、圆角或字号。窄宽度省略显示，tooltip 与辅助功能保留完整文案。

## 分段选择、占位状态与移动弹层

- 互斥选项使用 `RevericSegmentedControl` / `RevericSegment`，不再在 feature 内复制滑块实现。调用方保证选项值唯一且选中值存在；页面导航 tabs 保持独立语义。
- 通用空态与错误态使用 `RevericPlaceholder.empty` / `.error`，接收本地化文案及可选操作区域。组件只管内部排版；居中、滚动、背景、状态判断、创建和重试逻辑由调用方负责。操作区域使用标准 `RevericButton`。
- 移动端通用弹层使用 `showMobileSheet` + `MobileSheetScaffold` / `MobileSheetHeader`（`lib/mobile/widgets/sheet.dart`）。有标题头时关闭 handle，无标题菜单显式开启框架 handle；高度上限 0.78、安全区和键盘 inset 只由外壳处理一次。内部内容自持滚动，关闭限制和返回值留在调用方；沉浸阅读的系统栏恢复外壳保持独立。

## 操作菜单与选择控件

- **先按交互语义选组件**：编辑、删除、上下移、运行快捷指令、应用标题格式等是执行操作；状态、模型等是在选项中选择并展示当前值。不能仅因二者都会展开列表，就混用菜单与 Select。
- **桌面操作菜单**统一使用 `showRevericContextMenu` + `RevericMenuItem` / `RevericMenuDivider`（`lib/shared/components/reveric_context_menu.dart`）；“…”入口使用 `RevericIconButton` + `RevericIcons.more_horiz`，提供本地化 tooltip。保留原有禁用条件、删除确认、菜单展开态与外部触发入口。
- **值选择**使用 `RevericSelect<T>`（`lib/shared/components/reveric_select.dart`），保留当前值、选中标记及状态色点；表单下拉继续按场景使用 `RevericFormDropdown`。`reveric_dropdowns.dart` 中的组件用于值选择，不承载编辑、删除等操作。
- **移动端操作菜单**使用 `showMobileSheet`（`lib/mobile/widgets/sheet.dart`），选择动作后先关闭 sheet，再执行原有回调；删除仍走已有确认流程。保留列表左滑删除，详情页不重复放删除主按钮。
- **业务 UI 不再直接使用 `PopupMenuButton` / `PopupMenuItem`**。修改菜单或选择器时同步检查桌面与移动端，按各自的平台交互落地。

## 输入控件选型

**不要直接写 `TextField` / `TextFormField` + 手搓 `InputDecoration`。** 全局 `inputDecorationTheme`（`lib/shared/theme/reveric_theme.dart`）的 `border` 是 `InputBorder.none`：漏写边框不会报错、不会告警，只会静默渲染成一行没有框的悬空文字，看起来像渲染 bug 而不是像「你忘了用组件」。

按场景选组件：

| 场景 | 用 |
|---|---|
| 搜索框 | `RevericSearchField` + `useDebouncedSearch`（`lib/shared/components/reveric_search_field.dart`） |
| 普通文本输入（label / hint / helper / error / 多行） | `RevericTextField`（`lib/shared/components/reveric_text_field.dart`） |
| `lib/third/form` 表单内的文本字段 | `HookedTextFormField`（`lib/shared/form/hooked_text_form_field.dart`） |
| 表单下拉 | `RevericFormDropdown`（`lib/shared/components/reveric_dropdowns.dart`） |
| 富选项下拉（图标 / 副标题 / 选中态） | `RevericSelect`（`lib/shared/components/reveric_select.dart`） |

- 组件确实套不进去时（如 `initialValue` + key 重置没有 controller、第三方 widget 内部的 `InputDecorator`），用 `revericInputDecoration(context, ...)`，不要自己拼边框和填充色；同时在代码里写清为什么套不进组件。
- **确实要无框**（正文编辑器、聊天输入框、章节标题这类 chrome-less 输入）时，必须显式写 `border: InputBorder.none`，不要靠全局默认兜底。显式的无框和漏写的无框在代码里必须能区分开。
- 传 `prefixIcon` / `suffixIcon` 时必须一起给 `prefixIconConstraints` / `suffixIconConstraints`。Material 给图标槽的默认最小约束是 48×48，而 `RevericIcon` 内部是 `SizedBox`，会被 `BoxConstraints.enforce` 撑到 48 —— 表现为 `size: 16` 完全失效，渲染出一个巨大的图标。

## 新增 / 修改 Token

- 新增语义颜色字段 → 加到 `RevericColors`，并为所有受影响的 light / dark preset 提供值；新增主题时还要同步 `RevericThemeData` 与 `AppTheme` 的持久化映射。
- 新增文字样式 → 加到 `RevericTypography`，同步受影响的 desktop / mobile preset 和 `ThemeData` 映射。
- 新增间距、圆角或组件尺寸 → 分别加到 `RevericSpacing`、`RevericRadius` 或 `RevericSizes`。
- **不要**创建 widget 级别的私有颜色常量（如 `static const _bgColor = ...`），一律走 theme。

## 设计系统资料

- Flutter 运行时真源是 `lib/shared/theme/`；主题选择与持久化映射的真源是 `lib/shared/providers/settings_providers.dart`。
- 跨端设计系统正文唯一真源是 `designs/SYSTEM.md`；desktop / mobile 设计稿镜像分别位于 `designs/desktop/` 与 `designs/mobile/`。UI / theme 任务可以读取和同步这些路径，它们不属于 `docs/` 归档保护范围。
- theme 改动影响共享视觉契约时同步更新 `designs/SYSTEM.md`，再更新受影响的平台设计稿；只影响单个平台的布局不要求改另一端。不要在其他文档复制完整 token 表。

## 移动端 vs 桌面端 UI/UX

桌面端（`lib/desktop/`）与移动端（`lib/mobile/`）**共享 theme token、数据层、业务逻辑与 shared 组件**（如 settings sections、`chat_session_controller`、editor 数据层），**只有外壳（shell）按平台分流**。新增跨平台功能时：把共享内容抽到 `lib/shared/`，外壳分别在 `desktop/` 与 `mobile/` 实现；必要时用「注入 builder」让 shared 组件渲染平台化控件（参考 `settings_page.dart` 向 shared section 注入 `_MobileModelFieldSelector`）。**不要在移动端照搬桌面的就地换区/面板/popover，也不要按平台重写共享业务逻辑。**

### 平台外壳对照

| 维度 | 桌面端 (`lib/desktop/`) | 移动端 (`lib/mobile/`) |
|------|------------------------|------------------------|
| 应用框架 | `DesktopWindowFrame` + 标题栏 + `AppBackgroundLayer` 全局背景 | 无窗口框架、无全局背景；纯 `Scaffold(backgroundColor: colors.canvas)` |
| 导航壳 | Rail + Sidebar + `contentSelection` 就地切换主区域 | 底部 `MobileTabBar`（4 tab）+ `IndexedStack` 保活 |
| 打开页面 | 就地换区 / 内嵌面板 | 全屏 `Navigator.push(MaterialPageRoute)`，drill-down 栈 |
| 弹出选择 | 锚定 `OverlayPortal` / popover、context menu | `showModalBottomSheet`（顶部圆角 + drag handle + SafeArea） |
| 顶部栏 | 窗口标题栏 | 列表/编辑页自绘 header（`SafeArea(bottom:false)`）；仅表单页用 Material `AppBar` |
| 内容布局 | 列表/表格、并排多栏、纵向 section 侧栏 | 2 列封面网格、长文本用分段 `TabBar`、section 用横向 chip strip |
| 破坏性确认 | dialog | 仍用 `AlertDialog`（确认/删除保留 dialog，动作菜单走 sheet） |
| 背景/chrome | chrome 透出全局背景，elevated 保持 opaque（见下节） | 不适用，统一 `colors.canvas` |

### 移动端约定（强制）

1. **导航**：根级用底部 tab + `IndexedStack`；二级页面一律 `Navigator.push` 全屏路由。不要在移动端模拟桌面的就地换区。
2. **弹层**：popover / 下拉 / 右键菜单在移动端一律改 `showModalBottomSheet`，`isScrollControlled: true`，高度上限 `MediaQuery.sizeOf(context).height * 0.7~0.78`，`SafeArea` 包裹，底部留 `RevericSpacing.x5l` 清开 home indicator，统一用框架 `showDragHandle: true`（不要手绘 handle）；**sheet 自带标题头 / 关闭按钮时置 `showDragHandle: false`**（使用 `MobileSheetScaffold` + `MobileSheetHeader`）。列表次要操作（对标桌面 ⋯ / 右键菜单）也走 sheet，见 §11。
   - **引导类模态**（如供应商配置引导）在移动端同样走 sheet，桌面端保持 `Dialog`：内容抽成共享 widget，只让外壳分流。破坏性确认仍是两端 `AlertDialog` 的例外，见上表。判定不明确时先和用户讨论，不要默认照搬桌面 dialog；跨端契约见 `designs/SYSTEM.md` §Modal Surfaces。
3. **顶部栏**：列表/编辑页自绘 header 放进 `SafeArea(bottom:false)`；仅表单页（创建/编辑、设置详情）用 Material `AppBar`（leading 返回 + trailing 文本动作按钮）。
4. **创建入口**：顶部右对齐 accent pill / header 按钮 / 网格占位卡，**不要用 FAB**（当前移动端无 FAB 约定）。
5. **保存 UX**（两类，勿混用）：
   - **实体详情编辑**（角色 / 大纲 / 伏笔 / 地点 / 章节正文等）：debounce 自动保存 + header 被动「Saving/Saved」+ dispose 时 flush。
   - **显式提交表单**（`MobileAgentEditScaffold`：智能体技能 / 规则 / 快捷指令 / 子助手等）：**顶栏显式「保存」**；点保存才写入；返回不自动保存、默认不做未保存拦截（除非产品另开需求）。不要把这类页改成底部大保存按钮，除非全量改共享骨架。
6. **安全区**：底部有自绘 bar（tab bar / 编辑器工具条）时顶部用 `SafeArea(bottom:false)`，自绘 bar 自行用 `MediaQuery.viewPaddingOf(context).bottom` 补底部 inset。
7. **键盘与可滚动编辑区**：
   - `Scaffold` 保持默认 `resizeToAvoidBottomInset: true`。
   - **禁止**在「上半表单 + 下半 `RevericMarkdownEditor`」详情页使用 `Column(Flexible + Expanded)` 平分高度；键盘弹出时会把 `expands: true` 的编辑器压扁。
   - **必须**使用整页 `CustomScrollView` + `SliverLayoutBuilder` 计算编辑区高度（`max(360, 剩余视口 − 分区标题)`），让上半表单可滚出视口；编辑区用固定 `SizedBox(height: editorHeight)` 包裹。
   - Markdown 编辑区获得焦点时，对编辑区 `GlobalKey` 调用 `Scrollable.ensureVisible(alignment: 0)`，把编辑卡片顶到 AppBar 下方。
   - 短表单 / 单字段页：使用 `SingleChildScrollView + Column`，在 `Column` 外壳下由 `Expanded` 提供有界视口；不得用 `ListView` / `SliverList` 回收字段，完整边界见 `.agents/rules/form.md`「表单禁止惰性回收字段」。bottom sheet 用 `MediaQuery.viewInsets.bottom` 顶起内容。
8. **触控目标**：列表项用整行 `InkWell` + `RevericSpacing.lg` padding，命中区 ≥44pt。
9. **背景**：移动端无全局背景，直接用 `colors.canvas`；**不要**套用桌面的 chrome / elevated 透明判断（与下节「Global App Background」§10 一致）。
10. **左滑删除**：可删列表项用 `MobileSectionCard`（或同款 `Slidable` / `RevericSlidableDelete`）；点删除后仍走确认 dialog（`confirmAgentDelete` / `showConfirmDialog`）；**详情编辑页不要再放红色删除主按钮**（避免与列表左滑重复）。新建态无删除。
11. **长按次要操作**：列表项长按 → `showModalBottomSheet` 承载次要动作（如「保存到技能库」「修改调用名」），对标桌面行内 ⋯ / 右键菜单；可与左滑删除并存。**不要**把删除做成仅长按才有的唯一入口（左滑或 sheet 内危险项二选一强化即可，优先保留左滑）。`MobileSectionCard` 已支持 `onLongPress`。

#### 详情页 Markdown 编辑区布局（表单 + 编辑器）

适用：角色 / 大纲 / 伏笔 / 地点 / 通用条目等「metadata 在上、`RevericMarkdownEditor` 在下」的全屏编辑页。

```
Scaffold
└─ SafeArea(bottom: false)
   └─ Column
      ├─ MobileEditorAppBar
      └─ Expanded
         └─ CustomScrollView
            ├─ SliverToBoxAdapter — 标题、slist 字段、照片等 metadata
            └─ SliverLayoutBuilder — 分区标题 + SizedBox(height) + MobileDetailContentCard(编辑器)
```

检查清单：

1. 上半 metadata 放在第一个 `SliverPadding` + `SliverToBoxAdapter`，底部 padding 为 0。
2. 编辑区放在第二个 `SliverPadding` + `SliverLayoutBuilder`，`editorHeight = max(360.0, viewportMainAxisExtent - precedingScrollExtent - bottomPadding - sectionLabelHeight)`。
3. 为编辑区根节点挂 `GlobalKey`，所有 markdown `FocusNode` 聚焦时 `Scrollable.ensureVisible`。
4. 多 tab 正文（小传/状态、铺垫/回收）仍放在 `MobileSegmentedTabSwitcher` 内，外层高度由 `SizedBox` 约束。

**反模式**：`Flexible(SingleChildScrollView) + Expanded(RevericMarkdownEditor)` — 真机键盘会挤压编辑区。


### 移动端聊天 vs 桌面端聊天

| | 桌面端 | 移动端 |
|---|--------|--------|
| 容器 | 编辑器内停靠侧面板，`Positioned` composer + 测高 | 全屏路由，`Column[Expanded(list), banners, composer]` |
| Enter 行为 | Enter 发送 / Shift+Enter 换行 | Enter 换行（`TextInputAction.newline`），发送走按钮 |
| 模型选择 | 锚定 popover | composer 上的 pill → bottom sheet |
| 配件条（引用 / handoff / 排队） | 嵌在 composer 卡片内 | 浮在 composer 上方 |
| 滚动到底 | `userScrolledUp` 守卫 + 回底 FAB | 当前未加守卫（流式输出会打断用户回看，待补） |

> 业务逻辑（发送 / 取消 / 排队 / slash 匹配）必须共用 `lib/shared/services/ai/chat_session_controller.dart`，仅 composer / 弹层 UI 按平台分别实现。

### 参考实现

| 区域 | 文件 |
|------|------|
| 移动端入口 / tab 壳 | `lib/mobile/app.dart`、`lib/mobile/widgets/mobile_tab_bar.dart` |
| 全屏编辑页 + 自绘 header | `lib/mobile/pages/*_editor_page.dart`（见下） |
| 详情页 Markdown 编辑布局 | `lib/mobile/pages/character_editor_page.dart`、`entry_editor_page.dart`、`outline_editor_page.dart`、`foreshadowing_editor_page.dart`、`location_editor_page.dart` |
| 详情页共享组件 | `lib/mobile/widgets/detail_scaffold.dart`、`segmented_tab_switcher.dart` |
| Bottom sheet 选择器 | `lib/mobile/widgets/mobile_chapter_picker_sheet.dart`、`mobile_chapter_toc_sheet.dart` |
| 移动端聊天 | `lib/mobile/pages/mobile_novel_chat_page.dart`、`lib/mobile/widgets/mobile_chat_composer.dart` |
| 共享聊天逻辑 | `lib/shared/services/ai/chat_session_controller.dart` |
| 设置：shared section + 平台壳 | `lib/mobile/pages/settings_page.dart` + `lib/shared/widgets/settings/*` |

## Global App Background (Desktop)

用户可在 **设置 → 外观 → 应用背景** 配置全局背景（纯色主题色或图片，二者互斥）。背景在 `DesktopWindowFrame` 内由 `AppBackgroundLayer` 渲染，位于所有页面内容之下。

实现与设置见 `lib/shared/widgets/app_background.dart`、`lib/shared/providers/settings_providers.dart`（`appBackground*` 字段）。**不要**把 `canvas` / `surface` / `surfaceDim` 等 theme token 在 theme 层整体改成透明；继续用 **chrome 层逐个判断**（当前方案）。

### Chrome vs elevated（必须区分）

| 层级 | 含义 | 启用背景时 | 典型 token |
|------|------|------------|------------|
| **Chrome** | 全屏布局壳：页面底、侧栏、右栏、AI 面板外框等 | 应透出背景 | `canvas`、`surfaceDim`、`surface`、`surfaceContainerHigh`（仅作壳的 fallback） |
| **Elevated** | 卡片、气泡、输入框、Dialog、列表项、工具卡片 | **保持不透明** | 同上 token，但用于「内容块」而非整栏/整页 |

同一名称的 token 在壳和内容块上都会用到，因此**不能**靠改 theme 一劳永逸，必须在**铺底的那一层 Container/Scaffold/Decoration** 上处理。

### 工具函数（`lib/shared/widgets/app_background.dart`）

底层颜色逻辑仍在此文件；**UI 层优先用组件**（`lib/shared/components/reveric_surfaces.dart`），避免在各 widget 手写 `ref.watch(appBackgroundActiveProvider)` 与 `appElevatedBackgroundColor`。

| 组件 | 用途 |
|------|------|
| `RevericChrome` | 布局壳（透明 / fallback） |
| `RevericElevatedCard` | 卡片 / 面板（毛玻璃 + border，支持 `gradientColors`、`image`） |
| `RevericElevatedInkWell` | 可点击 elevated 卡片 |

```dart
// 底层 helper（组件内部已封装，仅在无法套组件时用）
final active = ref.watch(appBackgroundActiveProvider);
color: appChromeBackgroundColor(colors, active, colors.surfaceDim),
color: appElevatedBackgroundColor(colors, active, colors.surface),

// 推荐：直接用组件
RevericElevatedCard(
  fallback: colors.surfaceContainerHigh,
  padding: const EdgeInsets.all(RevericSpacing.x2l),
  child: ...,
)
```

- `appBackgroundActiveProvider`：`appBackgroundTheme != null` 或 `appBackgroundImagePath` 非空。
- 无背景时 helper 返回传入的 `fallback`，行为与改前一致。

### 新增 / 修改桌面 widget 时的检查清单

1. **是否铺满一大块区域、且目的是分区而不是卡片？** → 视为 chrome，启用背景时用 `appChromeBackgroundColor`（或 `appScaffoldBackgroundColor` / `appSidebarBackgroundColor`）。
2. **Scaffold / 页面根**：`backgroundColor: appScaffoldBackgroundColor(colors, active)`，不要写死 `colors.canvas`。
3. **侧栏、右栏、AI 面板根 Container**：对应该区域设计文档里的 fallback 色调用 `appChromeBackgroundColor`。
4. **工作区主面板**（`NovelWorkspacePanel`）：启用背景时根容器、header、status bar 均用 `appChromeBackgroundColor`；内部卡片用 `appElevatedBackgroundColor`。
5. **AI 聊天列表与 composer**：`Chat` 列表在启用背景时须透明；**composer** 外层 chrome 透明 + 顶部分割线，仅输入框区域用 `appElevatedBackgroundColor` 毛玻璃（圆角与无背景时相同）。
6. **Elevated 卡片**（简介、灵感、快捷操作、任务列表等）：优先 `RevericElevatedCard` / `RevericElevatedInkWell`；无全局背景时用原 fallback 色。
7. **卡片、消息气泡、表单、Dialog、设置项容器**：无全局背景时继续使用 `colors.surface` / `surfaceContainerHigh`；**不要**在 theme 层全局透明化。
8. **不要**在 `RevericColors` 或 `currentTheme` 里全局把 surface 类 token 设为透明。
9. 新页面若使用 `DesktopWindowFrame`，无需再画一层背景；勿在子树重复实现 `AppBackgroundLayer`。
10. **移动端**当前无全局背景；`lib/mobile/` 不必套用上述 chrome 规则，除非产品明确要求。

### 参考实现（漏改时可对照）

| 区域 | 文件 |
|------|------|
| 背景层 | `lib/desktop/widgets/desktop_window_frame.dart` |
| 编辑页 Scaffold / 左栏壳 | `lib/desktop/pages/novel_editor.dart` |
| 首页 Scaffold / 左栏 | `lib/desktop/pages/home.dart` |
| AI 聊天壳 / 列表 / composer | `lib/desktop/widgets/ai/chat/panel.dart`、`message_mapping.dart`（`_buildChatTheme`）、`composer.dart`（composer 样式分支，不复用 surface 组件） |
| AI 折叠条 / 封面工作室 / 展开侧栏 | `lib/desktop/pages/novel_editor_widgets.dart`（`_CollapsedAiPanel`）、`lib/desktop/features/cover_studio/studio_page.dart`、`lib/desktop/widgets/ai/chat/chat_side_panel.dart` |
| 工作区壳 | `lib/desktop/widgets/workspace/novel_workspace_panel.dart`（根容器、header、status bar；启用背景时全分区透明） |
| Elevated 卡片（概览 / 空状态 / Todo） | `lib/shared/components/reveric_surfaces.dart` |

漏掉 chrome 的表现：设置了全局背景后，该区域仍是一块纯色/主题色挡在背景图前面。修复方式：在该层 `build` 中 `ref.watch(appBackgroundActiveProvider)` 并改用上述 helper，**不要**扩大透明范围到子卡片。

## 卡片层级：无描边 + 柔和投影

- 卡片、面板、Dialog 浮在 canvas 上：圆角 `RevericRadius.card`，描边取 `revericCardBorder(colors)`（浅色透明、深色 `borderSubtle`），投影取 `revericCardShadows(colors)`（`lib/shared/theme/reveric_elevation.dart`）。不要在 widget 里另写 `BoxShadow` 或手调透明度。
- 优先用 `RevericElevatedCard` / `RevericElevatedInkWell`，它们已按上述默认值出图；只有表达选中、警示等语义时才传 `borderColor`。
- Chrome 保持扁平：侧栏、工具条、页头、输入框、列表行、设置行不加投影，靠底色层次与 hover / selected 区分。
- 普通按钮是胶囊（`RevericRadius.button`），纯图标按钮保持 `RevericRadius.iconButton` 圆角方形。

## 画布例外：毛玻璃、投影与动效

`DESIGN.md` 的「flat by default」和「不用毛玻璃」不适用于**无限画布**（制作画布、构思画布）：画布是空间化的操作台，节点和控件浮在点阵上，靠层次和反馈让人读懂「可拖、可连、可选」。例外从画布开始，列表、表单、侧栏、设置页的 chrome 照旧扁平，卡片按上节「卡片层级」处理。

**画布周边的 chrome 按需跟随。** 有些控件不属于画布，但和画布共用一套外壳。如果它们保持扁平，切到画布或从画布切走时外观会跳变。这类控件可以跟着用画布样式，判定条件如下：

1. **只跟随和画布共用的 chrome**：同一个控件在画布视图里浮在画布上，切到相邻的非画布视图后仍然在原位。典型例子是在画布和列表之间切换视图的顶栏。没有和画布共用的工具条、页头、对话框不跟随。
2. **跟随控件，不跟随内容**：非画布视图里的列表、卡片、表单照旧扁平。内容从跟随控件的下方开始，不从毛玻璃底下滚过。
3. **跟随是按需的，不是默认**：只有不跟随会造成切换跳变时才跟随。新增跟随项时，在下面的「当前跟随」里列出。

当前跟随：

- 制作页顶栏（`lib/desktop/features/production/region.dart` 的 `ScreenplayRegionToolbar(floating: true)`）：由画布、分镜、列表三个视图共用，三个视图都保持毛玻璃胶囊。分镜和列表的内容从 `ScreenplayRegionToolbar.floatingExtent` 下方开始。顶栏的视图切换用 `CanvasFloatingButton`，不再套 `RevericSegmentedControl`，因为胶囊本身已经是轨道。

- **取色只走 helper**：`lib/shared/theme/canvas_colors.dart` 的 `canvasGlassFill` / `canvasGlassBorder` / `canvasGlassShadows` / `canvasGlassNodeShadows` / `canvasNodeWell` / `canvasSoftEdgeColor` / `canvasFineDotColor`。它们从主题 token 派生，深浅两套取法不同：深色靠比画布略亮的半透明底分层（投影看不见，节点不画投影），浅色靠发丝描边 + 很淡的投影分层。不要在 widget 里手写透明度或用 `textPrimary` 做投影（深色主题下会变成一圈亮光）。
- **毛玻璃只给少量悬浮控件**：工具条胶囊、缩放 / 工具簇、添加按钮、选中节点的操作条与输入框用 `CanvasGlass`（`lib/desktop/features/canvas/widgets/glass.dart`），模糊裁在自身形状内。节点卡数量多，只用半透明底，**不要**套 `BackdropFilter`。
- **形状**：节点卡外圆角 `RevericRadius.canvasNode`，内部画面槽按「外圆角 − 内边距」同心收小；悬浮控件用 `RevericRadius.capsule` 胶囊。
- **动效**：节奏统一用 `CanvasMotion`（小元素 120ms、悬停 150ms、浮层进场 180ms，easeOutCubic），一律是一次性的隐式动画或 `CanvasEnter`，结束即停；**不要**做循环、呼吸、流光等常驻动画（见 `performance.md`）。悬停只改底色、描边和轻微位移 / 缩放，不改布局尺寸。
- **缩放补偿**：画布缩小时节点标题按 `productionHeaderScale` 反向放大（上限 1.6），保证远景下仍可读。

## 横向布局必须能用鼠标操作

新增或修改任何横向滚动区域（横向列表、chip strip、timeline、看板列、filmstrip、横向卡片行）时，必须同时交付桌面端的鼠标方案，不能只靠拖拽或触控板横扫。普通鼠标滚轮只产生纵向 delta，而 Flutter 横向 `Scrollable` 只读 `scrollDelta.dx`，默认表现是「滚轮转了没反应」。桌面端用 `lib/shared/components/horizontal_wheel_scroll.dart` 的 `HorizontalWheelScroll` 包住 scroll view，并把回调给出的 controller 交给它。区域内部嵌套的纵向滚动（看板列等）不受影响：`pointerSignalResolver` 先登记者赢，命中更深的纵向 scrollable 会先拿走滚轮；滚到尽头时也会把滚轮让回外层页面。例外：横向滚动不是该区域主要操作时（宽表格、图表、长页面里的只读横排）不要接管，因为鼠标停在上面时外层页面要等这里滚到尽头才继续滚；这类区域改提供横向滚动条、翻页按钮等显式入口。移动端触摸拖拽本就可用，不需要额外处理。
