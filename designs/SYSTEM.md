# Reveric Design System

> The cross-platform visual contract for Reveric's desktop and mobile clients — calm, modern, and focused on long-form writing.

---

## 0. Scope and Sources of Truth

This is the single prose source of truth for the shared Design System. Platform
artifacts demonstrate the contract but do not replace it:

| Surface | Owner / entry point |
|---|---|
| Semantic colors and all light/dark presets | `lib/shared/theme/reveric_colors.dart` |
| Desktop and mobile typography | `lib/shared/theme/reveric_typography.dart` |
| Spacing, radii, and component sizes | `lib/shared/theme/reveric_spacing.dart` |
| Flutter `ThemeData`, component defaults, and inherited accessors | `lib/shared/theme/reveric_theme.dart` |
| Theme selection, persistence, and `AppTheme` mapping | `lib/shared/providers/settings_providers.dart` |
| Mockup color themes and switcher | [`designs/themes.css`](themes.css), [`designs/theme.js`](theme.js) |
| Desktop design artifacts | [`designs/desktop/README.md`](desktop/README.md) |
| Mobile design artifacts | [`designs/mobile/index.html`](mobile/index.html) and `designs/mobile/m_*.jsx` |

Flutter runtime files own executable values. This document owns the shared
design intent and synchronization contract. HTML/CSS/JSX files under
`designs/desktop/` and `designs/mobile/` are platform-specific mirrors.

---

## 1. Design Principles

| Principle | Description |
|---|---|
| **Calm, modern surfaces** | Cool mint-white canvas, pure white cards that float on soft shadows, near-black ink-green for primary actions and jade only as a small accent. Literary character lives in the manuscript itself (Georgia prose), not in sepia chrome. |
| **Content-first** | Generous whitespace and readable typography keep the writer's words front and center. Every pixel of chrome must earn its place. |
| **Subtle chrome** | UI elements (toolbars, sidebars, dividers) recede into the background. They are present when needed, invisible when not. |
| **Calm interactions** | Gentle hover states, soft transitions, and no jarring animations. The interface should feel like turning a page, not clicking a button. |

---

## 2. Color Palette

The palette system supports multiple themes, each defining a full set of
semantic color tokens. **Reveric** is the application default. Every theme has
both light and dark runtime presets.

### Available Themes

Reveric ships with **3 color themes**, matching `AppTheme` in
`lib/shared/providers/settings_providers.dart`:

| Theme | Description | Accent (light / dark) |
|---|---|---|
| **Reveric** (default) | 玉白 · 墨玉 — cool mint-white canvas, white cards, ink-green actions | `#1C2623` / `#E4ECE8` |
| **Classic** | Minimal, timeless, high contrast | `#000000` / `#FFFFFF` |
| **Ivory** | Warm and gentle, like aged paper and cream | `#A2AF9B` / `#A2AF9B` |

Reveric's canvas is `#F2F6F4` and cards are pure white. The accent is
near-black ink green, inverted to jade-white in dark. Jade `#2A9C78` / `#4CC49C`
fills the `accentAmber` slot and is reserved for AI, status and small
highlights — never body text. `designs/themes.css` mirrors all three palettes
from `reveric_colors.dart`. Both mockup entry points load `designs/theme.js`,
which switches palette × light / dark / system the same way
`AppTheme × AppThemeMode` does.

### Cartographer Reference Palette

#### Surfaces

| Token | Hex | Usage |
|---|---|---|
| `canvas` | `#FFFBF5` | Main window background, outermost layer |
| `surface` | `#FCFAF6` | Editor background |
| `surfaceDim` | `#F5F0E8` | Sidebar background |
| `surfaceContainer` | `#F5F1EB` | Toolbar / status bar background |
| `surfaceContainerHigh` | `#FAF6F0` | AI chat panel background |

#### Borders & Dividers

| Token | Hex | Usage |
|---|---|---|
| `border` | `#E0D8CC` | Primary dividers between panels |
| `borderSubtle` | `#E8E2D8` | Subtle internal dividers |
| `borderInput` | `#E0D6CC` | Input field borders, card borders |

#### Text

| Token | Hex | Usage |
|---|---|---|
| `textPrimary` | `#2C2418` | Body text, headings |
| `textSecondary` | `#4A3F35` | Sidebar labels, secondary copy |
| `textMuted` | `#8A7D6B` | Breadcrumbs, placeholder text, hints |
| `textSubtle` | `#9E9484` | Metadata, word counts, timestamps |

#### Accent & Brand

| Token | Hex | Usage |
|---|---|---|
| `accent` | `#8B7355` | Brand brown — icons, active indicators, user avatar fallback |
| `accentWarm` | `#C4956A` | User avatar background |
| `accentAmber` | `#F6AD55` | AI avatar background, highlights, emphasis |

#### Selection & States

| Token | Hex | Usage |
|---|---|---|
| `selected` | `#E8E0D4` | Active file-tree item, selected tab |
| `hover` | `#EDE7DD` | Hover state for interactive elements |

#### Semantic / Feedback

| Token | Hex | Usage |
|---|---|---|
| `deletionBg` | `#FDE8E8` | Diff deletion background |
| `deletionBorder` | `#C53030` | Diff deletion border / strikethrough |
| `additionBg` | `#E8FDE8` | Diff addition background |
| `additionBorder` | `#2F855A` | Diff addition border / underline |
| `warningBg` | `#FEF3C7` | Warning banner background |
| `warningText` | `#D97706` | Warning text and icons |

#### Blockquote

| Token | Hex | Usage |
|---|---|---|
| `blockquoteBorder` | `#D4A574` | Left border on blockquote elements |

Semantic roles remain consistent across themes. Their concrete runtime values
may vary by theme and brightness to preserve contrast.

---

## 3. Typography

Reveric desktop uses **Georgia** (serif) for literary content and the **system sans-serif** (`-apple-system` / `Segoe UI` / `Roboto`) for UI chrome. Mobile uses the platform default font for both content and chrome, so iOS/Android system font settings remain visible throughout `lib/mobile/`.

| Token | Family | Size | Weight | Line Height | Usage |
|---|---|---|---|---|---|
| `display` | System sans | 28 px | 700 | 1.3 | Page titles, hero headings (tracking −0.5) |
| `heading2` | System sans | 22 px | 700 | 1.3 | Section headings (tracking −0.3) |
| `body` | Georgia | 16 px | 400 | 1.75 | Editor body text |
| `bodySmall` | Georgia | 14 px | 400 | 1.5 | Secondary body text, summaries |
| `ui` | System sans | 13 px | 400 | 1.4 | Labels, nav items, sidebar entries |
| `uiSmall` | System sans | 12 px | 400 | 1.4 | Metadata, tab labels, badges |
| `uiTiny` | System sans | 11 px | 500 | 1.3 | Workspace label, section headers (often uppercased) |
| `mono` | Menlo / Consolas | 11 px | 400 | 1.75 | Machine text shown verbatim — prompts, ids, sizes, zoom % |

Every title — `display`, `heading2`, card / dialog / cover titles — is system
sans with slight negative tracking (CSS `--font-display`). Georgia stays only for
manuscript prose being read or written (`body`, `bodySmall` excerpts,
blockquotes, script lines).

Mobile keeps UI chrome at the same compact 11–13px scale, but uses a Material-style system-font content scale: `display` 22px, `heading2` 18px, `body` 14px, and `bodySmall` 12px via `RevericTypography.mobile`.

### Flutter mapping

```dart
// Serif — editor content
const editorFontFamily = 'Georgia';

// Sans — UI chrome
// Use the default Flutter sans-serif (Roboto on Android, SF Pro on iOS/macOS)
// Do not set ThemeData.fontFamily globally; only literary tokens pin Georgia.
const mobileTypography = RevericTypography.mobile;
```

---

## 4. Spacing Scale

A constrained spacing scale keeps layouts rhythmic and consistent.

| Token | Value |
|---|---|
| `xxs` | 4 px |
| `xs` | 6 px |
| `sm` | 8 px |
| `md` | 10 px |
| `lg` | 12 px |
| `xl` | 14 px |
| `x2l` | 16 px |
| `x3l` | 20 px |
| `x4l` | 24 px |
| `x5l` | 28 px |
| `x6l` | 40 px |
| `editorPaddingH` | 72 px |

> `editorPaddingH` (72 px) is used specifically for editor horizontal padding, giving the text comfortable margins reminiscent of a printed page.

---

## 5. Radius Scale

| Name | Value | Usage |
|---|---|---|
| `small` | 4 px | Badges, keyboard-shortcut pills |
| `medium` | 6 px | Tabs, input chips, send button |
| `button` | 999 (capsule) | 全部按钮（FilledButton / OutlinedButton / TextButton / ElevatedButton） |
| `iconButton` | 8 px | 纯图标按钮，保持圆角方形 |
| `card` | 18 px | Cards, panels, `RevericDialog`, mobile sheet top corners |
| `large` | 8 px | Cards, dropdown menus |
| `xl` / `x2l` | 10–12 px | Input fields, large surfaces |
| `full` / `pill` | 14–16 px | Chat bubbles, chip buttons, avatars |

**Pending Flutter migration:** the mockups already use the larger scale small 6 ·
medium 8 · large 12 · xl 14 · x2l 18 · full 20 · pill 999. Flutter keeps the
values above for these names and moves call sites to `card` / capsule screen by
screen, instead of redefining tokens whose current users are not all pills.

---

## 6. Component Tokens

Shared semantic defaults apply to both platforms. Fixed pane widths and editor
measurements below describe the desktop shell. The mobile shell uses the same
color and spacing vocabulary with platform-specific composition:

- The primary mobile design entry is `designs/mobile/index.html`, with feature
  views in `designs/mobile/m_*.jsx`.
- Mobile layouts honor safe areas, use the full viewport below the device-frame
  preview breakpoint, and must not inherit desktop sidebar or three-pane widths.
- Mobile content and chrome use `RevericTypography.mobile`; desktop uses
  `RevericTypography.desktop`.
- A shared visual-contract change must update both platform artifact sets when
  both are affected. A platform-only layout change updates only that platform.

### Segmented selection and placeholders

- 互斥选项使用 `RevericSegmentedControl<T>`，选项值必须唯一且包含当前选中值。共享滑块动画为 240 ms，减少动态效果时关闭动画；移动端点击高度至少 48 px，桌面默认内容高度 34 px，轨道留白 3 px。图标和数量可选，长文案省略，tooltip 与辅助功能保留完整名称。页面导航 tabs 保持独立语义。
- 空态／错误态使用 `RevericPlaceholder.empty` / `.error`。内部统一图标、标题、可选说明和操作间距，最大内容宽度 420 px；普通／紧凑图标为 32 / 24 px。外层定位、滚动和背景由调用方决定；创建与重试使用 `RevericButton.primary` / `.secondary`，业务判断和回调留在业务组件。

### Modal Surfaces

模态呈现按平台分流：**内容共享，外壳分流**。桌面端用 `Dialog`，移动端默认用
`showModalBottomSheet`，需要独立返回栈的长流程用全屏路由。同一份内容 widget 应当能被
两种外壳直接包住，不要为某一端重写内容。

| 场景 | 桌面端 | 移动端 |
|---|---|---|
| 引导、短表单（如关系编辑） | `Dialog`（maxWidth 480） | bottom sheet |
| 选择器、动作菜单、popover 的移动端等价物 | 锚定 popover / context menu | bottom sheet |
| 破坏性确认（删除、覆盖） | `AlertDialog` | `AlertDialog`（两端一致） |
| 多步长流程、需要返回栈（如备份恢复） | 设置对话框内的导航项 | 全屏 `Navigator.push` |

通用确认使用 `showConfirmDialog`，外观复用 `RevericDialog`：首选宽度 420 px，窄屏保留 16 px 外边距，标题与正文可滚动，长按钮文案自动换行排列。普通、警告与危险语义通过图标和操作按钮表达；确认回调执行期间禁用重复提交、取消及返回。

业务表单、三选项确认与普通选择器通过 `showRevericDialog<T>` 打开，统一传递页面主题并保留业务返回值和遮罩关闭策略。短内容使用 `RevericDialog`；已有固定高度、列表或独立滚动区的内容使用 `RevericDialog.panel`，避免再套一层滚动。`width` 表示包含内边距的弹窗宽度，宽面板按原内容宽度加两侧内边距设置，容器自动限制到可用视口。差异对比、长文本阅读、颜色选择等特殊界面保留专用容器。

移动端 sheet 参数契约（与 `.agents/rules/design-system.md` §移动端约定 一致）：

| Property | Value |
|---|---|
| `isScrollControlled` | `true` |
| 高度上限 | `MediaQuery.sizeOf(context).height * 0.7~0.78` |
| 顶部圆角 | `RevericRadius.x2l`（12 px） |
| Background | `colors.surface` |
| 安全区 | `SafeArea` 包裹，底部留 `RevericSpacing.x5l` 清开 home indicator |
| Drag handle | 默认 `showDragHandle: true`；sheet 自带标题头 / 关闭按钮时置 `false` |

运行时通用入口为 `lib/mobile/widgets/sheet.dart` 的 `showMobileSheet<T>`，默认按有标题头的弹层关闭 handle，无标题菜单显式开启。外壳统一处理键盘 inset 和安全区，短内容收缩，长内容最多占屏高 0.78，并受键盘上方可用空间限制。内容内部不再重复补安全区或键盘高度。

`MobileSheetScaffold` 组合标题、内容和可选底部操作；`MobileSheetHeader` 提供统一标题布局及可选关闭入口。列表和表单自行决定滚动方式，保存／取消回调、禁止拖动或遮罩关闭等业务约束保持在调用方。沉浸阅读仍保留原有系统栏恢复外壳。

> **判定规则**：移动端看情况优先 sheet；判定不明确时与用户讨论，不要默认照搬桌面 dialog。

参考实现：`lib/shared/widgets/relation_edit_dialog.dart`（同一 `RelationChangeForm`
按平台分流到 sheet / dialog）、`lib/mobile/features/**/sheets/*.dart`；设计稿原型见
`designs/mobile/m_kit.jsx` 的 `Sheet` / `SheetHeader`。

### Sidebar

| Property | Value |
|---|---|
| Width | 280 px |
| Background | `surfaceDim` (`#F5F0E8`) |
| Selected item bg | `selected` (`#E8E0D4`) |
| Hover item bg | `hover` (`#EDE7DD`) |
| Item text | `textSecondary` (`#4A3F35`) |
| Item font | `ui` (system sans, 13 px) |
| Section header font | `uiTiny` (system sans, 11 px, uppercased) |
| Avatar radius (project) | 18 px |
| Avatar radius (user, bottom) | 14 px |
| Divider | `border` (`#E0D8CC`), 1 px |
| Footer (home) | Divider, community row, then profile bar |

**Community row.** The home sidebar footer leads with a QQ group pill: the QQ
mark on a 14 % `accentAmber` circle, the localized "Join QQ Group" label, and a
copy button behind a hairline divider. The group number is not shown; the copy
button copies it. The
GitHub repository follows as a plain icon button. Clicking the pill opens the
invite link, and copying needs its own button. On mobile the same two entries
form the "Community" group above "System" in Settings.

**Default user avatar.** When no image is set, the avatar shows the first
character of the nickname (Latin letters uppercased, "R" when blank). It sits on
a tone from `RevericColors.avatarTones` picked by a stable hash of the
nickname: 20 % tone over `surface` for the fill, 72 % tone over `textPrimary`
for the glyph, and a 1 px ring at 26 % tone. The rule lives in
`lib/shared/widgets/user_avatar.dart`.

### Editor

| Property | Value |
|---|---|
| Background | `surface` (`#FCFAF6`) |
| Content padding (horizontal) | 72 px |
| Content padding (vertical) | 40 px |
| Body font | `body` (Georgia, 16 px, line-height 1.75) |
| Heading font | `display` / `heading2` |
| Text color | `textPrimary` (`#2C2418`) |
| Blockquote border | `blockquoteBorder` (`#D4A574`), width 3 px |
| Blockquote padding-left | 20 px |
| Toolbar bg | `surfaceContainer` (`#F5F1EB`) |

### AI Chat Panel

| Property | Value |
|---|---|
| Width | 360 px |
| Background | `surfaceContainerHigh` (`#FAF6F0`) |
| User avatar size | 24 px |
| AI avatar size | 20 px |
| User avatar bg | `accentWarm` (`#C4956A`) |
| AI avatar bg | `accentAmber` (`#F6AD55`) |
| Bubble max-width | 300 px |
| Bubble border-radius | 14 px (`full`) |
| Bubble text font | `bodySmall` (Georgia, 14 px) |
| Input border | `borderInput` (`#E0D6CC`) |

### Cards

| Property | Value |
|---|---|
| Border-radius | 18 px (`RevericRadius.card`) |
| Border | `revericCardBorder(colors)` — transparent in light, `borderSubtle` in dark |
| Shadow | `revericCardShadows(colors)` — soft diffuse shadow in light, hairline in dark |
| Background | `surface` |
| Padding | 12–14 px |

Cards and panels float on the canvas instead of being outlined. Flutter helpers
live in `lib/shared/theme/reveric_elevation.dart` and back `RevericElevatedCard`,
`RevericElevatedInkWell` and `RevericDialog`. CSS mirrors are `--shadow-card` /
`--card-border` in `designs/themes.css`. Chrome — sidebars, toolbars, inputs,
list rows — stays flat; no ad-hoc shadows beyond these helpers. Hand-rolled
`BoxDecoration` cards still on the old bordered look are migrated screen by
screen.

### Buttons

Flutter 普通操作统一使用 `lib/shared/components/reveric_button.dart` 的 `RevericButton`：
`primary` / `secondary` / `text` 分别组合 Filled / Outlined / TextButton，`danger` 用于破坏性确认。
调用方传入 label、可选 Phosphor icon、onPressed、loading 和 size，不暴露任意 style、颜色或圆角。
组件只负责展示与点击禁用，异步任务和错误处理归调用方；有图标时原位替换为进度指示器，无图标时预留加载宽度，保持文案可见。
`standard` 用于表单与弹窗操作，`prominent` 只给页面上的主操作，`compact` 用于工具区与行内操作；移动端保留 Material padded 触控目标，桌面端不额外扩张命中区。
纯图标操作、设置行、卡片、选项卡和虚线添加入口不属于此组件。

所有按钮统一通过 `RevericThemeData.toThemeData()` 中的 `filledButtonTheme` /
`elevatedButtonTheme` / `outlinedButtonTheme` / `textButtonTheme` 注入默认样式，
调用点不应再重复设置 `backgroundColor` / `foregroundColor` / `shape` / 默认 `padding`。

| Token | Value |
|---|---|
| `RevericRadius.button` | 8 px |
| `RevericSizes.buttonHeightDesktop` | 36 px (桌面 `standard`，与 `fieldHeight` 对齐) |
| `RevericSizes.buttonHeight` | 40 px (移动端 `standard`；各端 `prominent` 页面主操作) |
| `RevericSizes.buttonHeightSm` | 32 px (`compact`：toolbar / chip / 行内操作) |
| `RevericSizes.buttonPaddingH` | 16 px (默认水平内边距) |
| `RevericSizes.buttonPaddingHSm` | 12 px (TextButton 水平内边距) |
| `RevericSizes.buttonIconSize` | 16 px (图标与加载槽位) |
| `RevericSizes.buttonProgressStroke` | 2 px (加载指示器线宽) |

**语义映射**：

| 语义 | Widget | 视觉 |
|---|---|---|
| 主操作（保存 / 创建 / 确认） | `FilledButton` | `accent` 背景，`onAccent` 前景 |
| 次操作（次要 / 选项 / 选择封面） | `OutlinedButton` | `borderInput` 描边，`textSecondary` 前景 |
| 文本操作（取消 / 表单链接） | `TextButton` | 透明背景，`textSecondary` 前景 |
| 危险操作（dialog 中的删除确认） | `FilledButton` + `backgroundColor: deletionBorder` | 红色背景，白色前景 |
| 危险操作（toolbar inline 删除） | `OutlinedButton` + `foregroundColor: warningText` + `side: warningText` | 警告色描边与文字 |

**禁止**：
- 在调用点用 `FilledButton.styleFrom(backgroundColor: colors.accent, foregroundColor: Colors.white)` 重复主题默认值。
- 用 `ElevatedButton + accent` 表达主操作，统一使用 `FilledButton`。
- 自行写 `RoundedRectangleBorder(borderRadius: BorderRadius.circular(RevericRadius.medium))`，统一走 `RevericRadius.button`。

#### 按钮布局规范

**页面级按钮**：
- 位置：放置在页面顶部标题栏（`DesktopWindowFrame.titleBarHeight` 区域）
- 布局：从右到左依次为：主操作按钮（FilledButton）、次操作按钮（TextButton/OutlinedButton）、危险操作按钮（TextButton.icon）
- 示例场景：编辑页面的保存/取消/删除按钮
- 视觉权重：主操作 > 次操作 > 危险操作

**对话框按钮**：
- 位置：放置在对话框底部（`AlertDialog.actions` 区域）
- 布局：从左到右依次为：取消按钮（`RevericButton.secondary` / OutlinedButton）、确认按钮（`RevericButton.primary` / FilledButton）
- 危险操作：删除确认等危险操作使用 `RevericButton.danger`，红色背景搭配主题中对比更高的文字色
- 示例场景：删除确认对话框、设置保存对话框

**表单内按钮**：
- 位置：跟随表单字段，通常在字段右侧或下方
- 布局：根据表单结构灵活安排
- 示例场景：选择封面按钮、添加模型按钮

**工具栏按钮**：
- 位置：工具栏内，使用紧凑尺寸（`buttonHeightSm`）
- 布局：图标按钮优先，必要时配合 tooltip
- 示例场景：编辑器工具栏、Markdown 编辑器工具栏

### Icon Buttons

普通图标操作使用 `lib/shared/components/reveric_icon_button.dart` 的
`RevericIconButton`，内部 `IconButton` 走全局 theme，默认使用 `textSecondary`
前景、`textSubtle` 禁用色与 `RevericRadius.button` 圆角。必须传本地化 tooltip；
回调为 null 时禁用，图标继承状态色。

| Token | Value |
|---|---|
| `RevericSizes.iconButtonSize` | 32 px |
| `RevericSizes.iconButtonPadding` | 6 px |
| 桌面图标 | 20 px |
| 移动端图标 | 22 px |
| 移动端最小点击区 `RevericSizes.touchTargetSize` | 48 × 48 px |

调用点只在确实有语义差异时覆盖，例如发送按钮的 tinted background、危险操作色或更小图标尺寸；不要在普通场景重复写默认 shape / padding / minSize。

### Filter Chips

列表筛选统一使用 `RevericFilterChip`：文案、可选计数、选中态与可空回调。
选中态使用 `accent / onAccent`，未选中使用 `surface / textMuted` 与
`borderSubtle` 描边，圆角 `RevericRadius.pill`。禁用时使用 `surfaceDim / textSubtle`。
底层 `FilterChip` 提供键盘操作和选中语义；移动端点击区至少 48px，水平列表外壳
必须容纳点击区。导航 tabs 与只读徽标保留各自语义。

### Status Badges

只读状态使用 `RevericBadge`：文案和主题语义色由业务组件映射，展示组件不认识
订单、作品或任务状态。字体 `uiTinySemibold`，水平／垂直内边距 8px / 4px，
圆角 `RevericRadius.small`，背景为语义色的 10% 透明度。长文案单行省略，
tooltip 和辅助功能保留完整内容。徽标不承担筛选、点击或删除操作。

### Switch

| Property | Value |
|---|---|
| Scale | 0.8 (wrapped in `Transform.scale`) |
| Active track color | `accent` (via `switchTheme`) |
| Inactive track color | `borderSubtle` (via `switchTheme`) |
| Active thumb color | `onAccent` |
| Inactive thumb color | `textSecondary` |
| Track outline | transparent |
| Splash radius | 0 |

### Dividers

| Property | Value |
|---|---|
| Height | 1 px |
| Color | `border` (`#E0D8CC`) |

---

## 7. Theme Mechanism

Reveric combines semantic tokens with Flutter's `ThemeData`.
`RevericTheme` exposes the semantic colors and typography through the widget
tree, while `RevericThemeData.toThemeData()` maps them to Material component
defaults.

### Architecture

```text
AppTheme + AppThemeMode
  └── AppSettings.themeDataForBrightness(...)
        └── RevericThemeData
              ├── brightness
              ├── RevericColors
              └── RevericTypography
                    ├── RevericTheme (semantic accessors)
                    └── ThemeData (Material component defaults)

RevericSpacing / RevericRadius / RevericSizes remain shared static tokens.
```

### Key classes

`RevericThemeData` stores `brightness`, `colors`, and `typography`. It provides
named light/dark presets and builds Flutter `ThemeData`. Spacing, radius, and
size values are intentionally accessed from `RevericSpacing`,
`RevericRadius`, and `RevericSizes` rather than stored per theme.

### Usage in widgets

```dart
Widget build(BuildContext context) {
  final colors = RevericTheme.colorsOf(context);
  final typography = RevericTheme.typographyOf(context);

  return Container(
    color: colors.surface,
    padding: const EdgeInsets.symmetric(
      horizontal: RevericSpacing.editorPaddingH,
      vertical: RevericSpacing.x6l,
    ),
    child: Text(
      'Chapter One',
      style: typography.display.copyWith(
        color: colors.textPrimary,
      ),
    ),
  );
}
```

### Rules

1. **Never hardcode design values.** Use `RevericTheme.colorsOf(context)`,
   `RevericTheme.typographyOf(context)`, `RevericSpacing`, `RevericRadius`,
   and `RevericSizes`.
2. **Default theme is Reveric.** `AppThemeMode` selects light, dark, or system
   behavior, and every `AppTheme` value maps to both brightness presets.
3. **Use Material defaults.** `RevericThemeData.toThemeData()` configures
   buttons, icon buttons, switches, dividers, inputs, and other shared
   components. Override only for a real semantic difference.
4. **Adding a semantic color** requires values in every affected light/dark
   `RevericColors` preset. Adding a theme also requires `RevericThemeData` and
   `AppTheme` persistence mappings.
5. **Keep platform mirrors synchronized.** Update this file for shared contract
   changes, then update affected desktop/mobile artifacts. Do not copy the full
   runtime token tables into another document.

### Theme source

Classic and Ivory come from an external CSS theme set; Reveric is a Reveric-specific palette. The oklch color values from the original CSS were converted to sRGB hex using the oklch → linear sRGB → sRGB conversion pipeline. Each theme's light variant was mapped to RevericColors semantic tokens:

| CSS Variable | RevericColors Token | Role |
|---|---|---|
| `--background` | `canvas` | Page background |
| `--card` | `surface` | Card/panel background |
| `--muted` | `surfaceDim` | Dimmed surface (sidebar) |
| `--secondary` | `surfaceContainer` / `hover` | Elevated surface / interactive hover |
| `--accent` | `surfaceContainerHigh` | Highlighted surface |
| `--border` | `border` / `borderInput` | Primary border |
| `--secondary` | `borderSubtle` | Subtle border |
| `--foreground` | `textPrimary` | Primary text |
| `--muted-foreground` | `textMuted` / `textSecondary` | Muted/secondary text |
| `--primary` | `accent` | Brand accent color |
| `--sidebar-accent` | `hover` | Hover state |
| `--accent` | `selected` | Selected state |

---

## 8. Dark Themes

Dark mode is implemented for all 3 themes. `AppThemeMode.dark` selects it
explicitly; `AppThemeMode.system` follows platform brightness.

- Dark surfaces use light text while preserving each palette's identity.
- Accent and semantic colors are tuned per dark preset for contrast rather than
  mechanically inverted.
- Both desktop and mobile consume the same selected color preset. Platform
  differences belong in composition and typography, not duplicate palettes.
- New or changed palettes require focused theme tests covering both brightness
  variants and the `AppTheme` mapping.

---

*Last updated: August 2026*
