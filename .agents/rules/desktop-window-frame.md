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
- **页面标题与操作区分别布局**：页面图标、标题和面包屑保持在顶部 `titleBarHeight` 内垂直居中。右侧操作需要下移时，只对操作区使用 `captionSafeTopInset`，不得给整个页头加顶部 padding，也不得用负偏移把标题补移回去。页头可以保留 `titleBarHeight + topInset` 的总高度，让下方筛选和正文正常排在操作区之后。
- 仍与系统按钮同行、且占据窗口最右侧的区域，按需使用 `trailingInset`；已下移的操作区不再叠加右侧避让。页面仅在 Windows 下移右侧状态和操作，标题位置不变；macOS / Linux 保留原布局。
- **导航与筛选对齐不等于标题与操作必须同高**：同一工具行的左侧导航与右侧筛选仍共享布局，宽窗口居中对齐，窄窗口按断点整体换行。此约束不能用于把上方的页面标题一起下移。
- **按实际位置判断侧面板**：最右侧的窄面板（如聊天会话切换区、封面设计师）自身位于系统按钮下方时，可以整体避让；纯操作工具条也可以下移。不能把侧面板的处理复制到左侧页面标题，或仅为左右面板对齐而移动页面标题。
- 业务按钮仍位于自绘标题栏覆盖范围内时，通过页面根的 `titleBarGestureExclusionKeys` 排除该交互区域，避免拖拽 / 双击窗口手势抢占业务操作。
- **验证意图而非复述实现**：测试分别断言页面标题仍在原顶部基线、Windows 操作区位于窗口按钮下方、下方内容不重叠，并覆盖宽 / 窄窗口和按钮点击。使用可覆盖的 Flutter 目标平台显式运行 Windows、macOS、Linux 三种桌面布局分支；只在宿主平台跑过测试不算跨平台验证。测试不能按宿主 `Platform.isWindows` 选择唯一预期，也不能把标题中心写成 `topInset + titleBarHeight / 2` 来认可整行下移。UI 测试不能替代 Windows 原生窗口拖拽、最大化和关闭按钮的实机验证。

## 示例

```dart
// 页面根承载框架；sidebar 和 content 自行处理各自顶部区域的避让。
Scaffold(
  body: DesktopWindowFrame(
    child: Row(children: [sidebar, content]),
  ),
);

// 页面标题留在顶部；Windows 只下移右侧操作。
final topInset = DesktopWindowFrame.captionSafeTopInset;
SizedBox(
  height: DesktopWindowFrame.titleBarHeight + topInset,
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: SizedBox(height: DesktopWindowFrame.titleBarHeight, child: title),
      ),
      Padding(
        padding: EdgeInsets.only(top: topInset),
        child: SizedBox(height: DesktopWindowFrame.titleBarHeight, child: actions),
      ),
    ],
  ),
);

// ❌ 错误：手动判断平台并硬编码偏移
final topInset = Platform.isMacOS ? 22.0 : 0.0;
Padding(padding: EdgeInsets.only(top: topInset), child: ...);
```
