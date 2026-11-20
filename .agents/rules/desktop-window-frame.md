# 桌面端窗口标题栏布局

修改桌面页面根、页头（包括嵌入区域）或窗口按钮避让前，必须完整阅读本文件。

## 规则

- 任何拥有桌面页面根 `Scaffold.body` 的页面都必须使用 `DesktopWindowFrame` 包裹，包括 `lib/desktop/pages/` 和 `lib/desktop/features/*` 中的页面。region、dialog 和嵌入式 panel 不重复包裹。它统一处理：
  - macOS 红绿灯（traffic lights）区域避让
  - Windows / Linux 窗口标题按钮（关闭 / 最小化 / 最大化）
  - 全平台顶部拖拽移动区域（`DragToMoveArea` / `WindowCaption`）
- `DesktopWindowFrame` 在所有桌面平台都将 `child` 铺到窗口顶部，**不会自动添加顶部内边距**；自绘标题栏覆盖在内容上方。页面 / 区域根据实际位置消费框架提供的避让尺寸，不要在框架和子区域重复避让。`showCustomTitleBar: false` 时不绘制这层覆盖，使用原生标题栏的窗口不要再为自绘标题栏预留空间。
- **禁止**在 widget 中自行判断平台并硬编码标题栏偏移量。如需获取标题栏相关尺寸，使用 `DesktopWindowFrame` 提供的常量 / getter（以下数值为 Flutter 逻辑像素）：
  - `DesktopWindowFrame.titleBarHeight` — 标题栏高度（48px）
  - `DesktopWindowFrame.macosTrafficLightWidth` — macOS 红绿灯水平宽度（76px）
  - `DesktopWindowFrame.sidebarTopInset` — 侧边栏顶部避让（所有桌面平台均为 `titleBarHeight`）
  - `DesktopWindowFrame.sidebarLeadingInset` — 侧边栏首行左侧偏移（macOS: 76px 避让红绿灯, 其他: 0）
  - `DesktopWindowFrame.captionSafeTopInset` — 顶部交互区域避让（Windows: `titleBarHeight`, macOS / Linux: 0）
  - `DesktopWindowFrame.trailingInset` — 同行最右侧区域避让系统窗口按钮（Windows / Linux: 138px, macOS: 0）
- **先看谁占着窗口右上角**，再决定同一行还是整行下移。两种布局都合法，不能互相套用。
  - **页面标题行上的短操作**：风格、规格、复制、保存这类少量按钮，和页面标题放在同一条 `titleBarHeight` 里垂直居中，排在系统窗口按钮左侧。Windows / Linux 用 `trailingInset` 让出右侧 138px，macOS 为 0。不要用 `captionSafeTopInset` 把这簇按钮挪到最小化、最大化和关闭下面。窄窗口优先缩短标题或风格名，仍然留在这一行。按钮落在自绘标题栏覆盖范围内时，放进页面根的 `titleBarGestureExclusionKeys`。
  - **右上角整列自己的标题栏要整行下移**：停靠在最右侧的 AI 聊天（`ChatHeader`，`avoidWindowCaption: true`）以及同样贴住窗口右上角的窄列（封面设计师）。这一行同时含有列内标题和操作，整行都压在系统按钮下面，Windows 上整行使用 `captionSafeTopInset`，不再叠加 `trailingInset`。不能把其中几个按钮拆出来贴到窗口按钮左侧，而把会话标题留在系统按钮下面。macOS / Linux 的 `captionSafeTopInset` 为 0，这时才用 `trailingInset`，标题栏与系统按钮同行。
  - **右上角已经由旁边的列占用时，不要再下移**：展开聊天里右侧 `ChatSidePanel` 占着系统按钮，聊天头设 `avoidWindowCaption: false`，停在顶部 `titleBarHeight`，也不加 `trailingInset`。占着右上角的那一列留在 `titleBarHeight` 内，只用 `trailingInset`。悬浮聊天不避让窗口按钮。
- **下移的是占住右上角的那一整行，不是页面标题**。页面图标、标题和面包屑始终留在顶部 `titleBarHeight` 内垂直居中。不得给整个页头加顶部 padding，也不得用负偏移把标题补移回去。页头可以保留 `titleBarHeight + topInset` 的总高度，让下方筛选和正文正常排在下移区域之后。已下移的区域不再叠加 `trailingInset`。
- **导航与筛选对齐不等于标题与操作必须同高**：同一工具行的左侧导航与右侧筛选仍共享布局，宽窗口居中对齐，窄窗口按断点整体换行。此约束不能用于把上方的页面标题一起下移，也不能用来把标题行上放得下的短操作挪到下一行。
- **验证意图而非复述实现**：测试按右上角的归属分别断言。页面标题仍在原顶部基线；标题行短操作与标题同一行，且不与窗口按钮矩形重叠（Windows / Linux 右缘不超过 `trailingInset` 左边界）。占住右上角的整列在 Windows 上整行位于窗口按钮下方，且不再叠加 `trailingInset`；旁边那一列不再下移。覆盖宽 / 窄窗口和按钮点击。使用可覆盖的 Flutter 目标平台显式运行 Windows、macOS、Linux 三种桌面布局分支；只在宿主平台跑过测试不算跨平台验证。测试不能按宿主 `Platform.isWindows` 选择唯一预期，也不能把标题中心写成 `topInset + titleBarHeight / 2` 来认可整行下移。UI 测试不能替代 Windows 原生窗口拖拽、最大化和关闭按钮的实机验证。

## 示例

```dart
// 页面根承载框架；sidebar 和 content 自行处理各自顶部区域的避让。
Scaffold(
  body: DesktopWindowFrame(
    child: Row(children: [sidebar, content]),
  ),
);

// 页面标题行的短操作与窗口按钮同一行。
SizedBox(
  height: DesktopWindowFrame.titleBarHeight,
  child: Row(
    children: [
      Expanded(child: title),
      Padding(
        padding: EdgeInsets.only(right: DesktopWindowFrame.trailingInset),
        child: actions,
      ),
    ],
  ),
);

// 占住窗口右上角的整列：Windows 整行下移，不再加 trailingInset。
// macOS / Linux 的 captionSafeTopInset 为 0，改为 trailingInset。
final topInset = DesktopWindowFrame.captionSafeTopInset;
final trailingInset = topInset == 0 ? DesktopWindowFrame.trailingInset : 0.0;
SizedBox(
  height: DesktopWindowFrame.titleBarHeight + topInset,
  child: Padding(
    padding: EdgeInsets.only(top: topInset, right: trailingInset),
    child: columnHeader,
  ),
);

// ❌ 错误：页面标题行上的少量按钮，为躲开窗口按钮整行下移
Padding(
  padding: EdgeInsets.only(top: DesktopWindowFrame.captionSafeTopInset),
  child: actions,
);

// ❌ 错误：手动判断平台并硬编码偏移
final topInset = Platform.isMacOS ? 22.0 : 0.0;
Padding(padding: EdgeInsets.only(top: topInset), child: ...);
```
