// 职责: 封面/头像生成风格枚举
// 关联文件:
//   lib/desktop/features/cover_studio/studio_page.dart
//   lib/desktop/widgets/workspace/character_profile_editor.dart

enum CoverStyle { cinematic, illustration, eastern, minimal, cg3d }

/// 3D 半写实 CG 的完整风格文本。
///
/// 风格预设的文字会原样进入生图提示词的「风格要求」，四个字的标签压不住画风，
/// 所以这一项单独给一段完整描述；其余预设仍沿用本地化标签。
const String coverStyleCg3dPrompt =
    '3D 半写实 CG 三维动画风格，非真人实拍。影视级三维渲染：皮肤有克制的次表面散射与统一色调，'
    '头发分束建模、边缘干净，布料与金属有真实高光但整体收得住；柔和三点布光，浅景深，明暗层次干净；'
    '介于写实与风格化之间，保留人物辨识度，不追求真人照片质感。'
    '避免真人照片、真实毛孔与皮肤瑕疵、摄影棚人像写真、2D 平涂插画、Q 版卡通。';

/// 取某个预设要写进提示词的风格文本。
String coverStylePromptText(CoverStyle style, String label) =>
    style == CoverStyle.cg3d ? coverStyleCg3dPrompt : label;
