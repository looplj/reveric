class RevericSpacing {
  static const double xxs = 4;
  static const double xs = 6;
  static const double sm = 8;
  static const double md = 10;
  static const double lg = 12;
  static const double xl = 14;
  static const double x2l = 16;
  static const double x3l = 20;
  static const double x4l = 24;
  static const double x5l = 28;
  static const double x6l = 40;
  static const double editorPaddingH = 72;
}

class RevericRadius {
  static const double small = 4;
  static const double medium = 6;
  static const double large = 8;
  static const double xl = 10;
  static const double x2l = 12;
  static const double full = 14;
  static const double pill = 16;

  /// 画布节点卡外圆角；卡内画面槽用 [x2l]，二者相差 [RevericSpacing.xs] 的内边距，弧线同心。
  static const double canvasNode = 18;

  /// 胶囊形浮层（画布悬浮工具条）：半径远大于高度的一半，两端总是半圆。
  static const double capsule = 999;

  /// 按钮统一胶囊形（FilledButton / OutlinedButton / TextButton / ElevatedButton）。
  static const double button = capsule;

  /// 纯图标按钮保持圆角方形，不随普通按钮变胶囊。
  static const double iconButton = 8;

  /// 卡片、面板、Dialog 与移动端 sheet 顶部：无描边卡片配柔和投影时的大圆角。
  static const double card = 18;
}

class RevericSizes {
  /// 导演台的分类栏、侧面板和固定预览区。
  static const double directorRailWidth = 56;
  static const double directorRailTab = 46;
  static const double directorPanelWidth = 256;
  static const double directorSidebarWidth = 312;
  static const double directorInspectorWidth = 288;
  static const double directorOrientationSize = 64;
  static const double directorHeaderHeight = 46;
  static const double directorTimelineLabelWidth = 300;
  static const double directorTimelineCompactLabelWidth = 136;
  static const double directorTimelineBarHeight = 40;
  static const double directorTimelineRulerHeight = 28;
  static const double directorTimelineRowHeight = 26;
  static const double directorTimelineHeadHeight = 28;
  static const double directorTimelineMaxHeight = 236;
  static const double directorModeSwitchWidth = 148;
  static const double directorPreviewWidth = 280;
  static const double directorDockHeight = 46;
  static const double directorHistoryWidth = 300;
  static const double directorHistoryMaxHeight = 320;
  static const double directorSmallIcon = 12;
  static const double directorSwatch = 9;
  static const double directorKeyButton = 22;
  static const double directorPoseLabelWidth = 64;
  static const double directorPoseValueWidth = 68;
  static const double directorRowHeight = 28;
  static const double directorActionHeight = 32;
  static const double directorAspectCard = 72;

  /// 通用确认与简短表单弹窗的首选宽度；窄屏保留安全留白。
  static const double dialogWidth = 420;

  /// MCP 编辑表单中分段选择的最大宽度；两三个短选项铺满整行会显得过宽。
  static const double mcpEditorSegmentWidth = 320;

  /// 媒体预览弹窗中画面的最大宽高；画面按素材比例缩放，不加黑边。
  static const double mediaPreviewMaxWidth = 880;
  static const double mediaPreviewMaxHeight = 560;

  /// 音频预览没有画面，只保留一块固定高度的占位舞台。
  static const double mediaPreviewAudioHeight = 160;

  /// 视频节点「裁剪时长」弹窗宽度：画面要看得清切点，比通用弹窗宽。
  static const double productionTrimDialogWidth = 600;

  /// 画布书架卡片：横向画面，宽度上限与固定高度。
  static const double canvasShelfCardWidth = 280;
  static const double canvasShelfCardHeight = 250;

  /// 画布书架「继续」区的横向封面宽度。
  static const double canvasResumeCoverWidth = 224;

  /// 画布作品页头重命名输入框的宽度上限。
  static const double productionTitleFieldWidth = 320;

  /// 空画布起点卡片的宽度。
  static const double productionStartTileWidth = 200;

  /// 制作画布上贴着图片节点的生成输入框宽度。
  static const double productionComposerWidth = 620;

  /// 视频节点底栏多了运镜、时长和生成方式，输入框更宽；窄画布时由锚定布局夹回。
  static const double productionVideoComposerWidth = 800;

  /// 制作画布浮层：结果弹层、比例 · 分辨率弹层。
  static const double productionInputTileSize = 56;
  static const double productionTextInputWidth = 160;

  static const double productionResultsWidth = 400;
  static const double productionResultsMaxHeight = 360;
  static const double productionSpecWidth = 380;

  /// 风格库弹层：左侧分类栏 + 4 列风格卡片。
  static const double productionStylePickerWidth = 640;
  static const double productionStylePickerHeight = 480;
  static const double productionStyleCategoryWidth = 104;

  /// 分段控件的桌面内容高度与滑块轨道留白。
  static const double segmentHeight = 34;
  static const double segmentTrackPadding = 3;

  /// 空态与错误占位的阅读宽度和图标规格。
  static const double placeholderMaxWidth = 420;
  static const double placeholderIconSize = 32;
  static const double placeholderIconSizeCompact = 24;

  /// 移动弹层的屏幕高度上限。
  static const double mobileSheetMaxHeightFactor = 0.78;

  /// 首页侧边栏宽度（单列导航）。
  static const double sidebarWidth = 280;

  /// 小说编辑页左侧栏总宽度（rail + panel）。
  static const double editorSidebarWidth = 340;
  static const double chatPanelWidth = 360;
  static const double editorMinimapWidth = 112;
  static const double editorMinimapMinimumViewportHeight = 28;
  static const double dividerThickness = 1;
  static const double blockquoteBorderWidth = 3;
  static const double blockquotePaddingLeft = 20;
  static const double chatBubbleRadius = 14;
  static const double avatarRadiusLg = 18;
  static const double avatarRadiusMd = 14;
  static const double aiAvatarSm = 20;
  static const double aiAvatarMd = 24;

  /// 制片画布右下角的 Agent 悬浮球直径。
  static const double aiChatBallSize = 48;
  static const double chatSessionSwitcherCaretSize = 13;

  /// 标准按钮高度（FilledButton / OutlinedButton / TextButton / ElevatedButton）。
  static const double buttonHeight = 40;

  /// 桌面普通按钮高度；与 [fieldHeight] 一致，放在输入框旁时上下对齐。
  static const double buttonHeightDesktop = 36;

  /// 紧凑按钮高度（toolbar / chip-like inline 按钮）。
  static const double buttonHeightSm = 32;

  /// 普通按钮内图标及加载指示器的固定槽位。
  static const double buttonIconSize = 16;
  static const double buttonProgressStroke = 2;

  /// 按钮内边距（水平 / 垂直）。
  static const double buttonPaddingH = 16; // == RevericSpacing.x2l
  static const double buttonPaddingV = 8; // == RevericSpacing.sm
  static const double buttonPaddingHSm = 12; // == RevericSpacing.lg

  /// IconButton 统一尺寸。
  static const double iconButtonSize = 32;
  static const double iconButtonPadding = 6;
  static const double iconButtonIconSize = 20;
  static const double iconButtonIconSizeMobile = 22;

  /// 缩略图角上的圆形移除按钮（悬停时露出的小 ×）。
  static const double thumbRemoveSize = 22;
  static const double thumbRemoveIconSize = 12;

  /// 移动端图标按钮和筛选项的最小触控区域。
  static const double touchTargetSize = 48;

  /// 行内子 Agent 头像与同位状态指示的直径（工具卡步骤点、后台任务条）。
  static const double agentDotSize = 18;

  /// 浮层提示（toast / snack message）最大宽度。
  static const double toastMaxWidth = 420;

  /// 表单控件统一高度（文本框 / 下拉选择触发器）。
  static const double fieldHeight = 36;

  /// 紧凑表单控件高度。
  static const double fieldHeightSm = 32;

  /// 行内状态 badge 高度（贴在文字旁的小色块，如剧本的「已超出规划」）。
  static const double badgeHeightSm = 18;

  /// 列表项前的状态圆点（如 AI 供应商是否可用）；移动端行高更大，用大一号。
  static const double statusDotSize = 7;
  static const double statusDotSizeMobile = 9;

  /// 设置页 AI 供应商列表栏宽。
  static const double settingsProviderListWidth = 280;

  /// 添加自定义供应商的类型选择弹层宽度与最大高度（桌面）。
  static const double providerTypePickerWidth = 320;
  static const double providerTypePickerMaxHeight = 440;

  /// 季管理桌面弹窗宽度。
  static const double screenplaySeasonManagerWidth = 640;

  /// 剧本正文栏宽 —— 一页 ≈ 一分钟，别再宽了。
  static const double screenplayPageMaxWidth = 720;

  /// 分镜列表里提示词正文的最大宽度，宽窗口下也保持可读行长。
  static const double storyboardPromptMaxWidth = 720;

  /// 剧本对话与括号提示的缩进。
  static const double screenplayDialogIndent = 42;

  /// 剧本动作行的 △ 悬挂缩进。
  static const double screenplayActionIndent = 22;

  /// 剧本分区顶栏高度。
  static const double screenplayTopBarHeight = 46;

  /// 浮动工具条低于此宽度时收起右侧工具。
  static const double screenplayToolbarCompactWidth = 640;

  /// 收起后的工具面板宽度，仍受窗口可用宽度约束。
  static const double screenplayToolbarPanelWidth = 600;

  /// 场次组头低于此宽度时使用带提示的图标操作。
  static const double storyboardHeaderCompactWidth = 640;

  /// 场次卡 / 镜头卡宽度。
  static const double screenplaySceneCardWidth = 340;

  /// 场次卡顶部的正文缩略高度。
  static const double screenplayScenePeekHeight = 190;

  /// 场次卡高度。
  ///
  /// 场次板是 flow 画布，`flow.Node` 的 size 是必填的，卡片不能再由内容撑高。
  /// 取值覆盖固定部分（缩略 190 + 标题 + 标签两行 + 两枚按钮）后仍给梗概留
  /// 三行；梗概超出即截断。
  static const double screenplaySceneCardHeight = 500;

  /// 场次板上相邻两张卡的水平间距。
  static const double screenplaySceneCardGap = 44;

  /// 大纲正文栏宽度。
  static const double screenplayOutlineMaxWidth = 780;

  /// 概览内容栏宽度。
  static const double screenplayOverviewMaxWidth = 900;

  /// 人物关系左栏（角色名单）宽度。
  static const double screenplayCharacterColumnWidth = 300;
}
