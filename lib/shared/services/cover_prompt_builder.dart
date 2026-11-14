// 职责: 封面生成配方目录与提示词碎片 — 默认提示词、点击追加的灵感句、参考图说明。
// 关联文件:
//   lib/shared/models/cover_brief.dart
//   lib/shared/services/cover_studio_orchestrator.dart
//   lib/desktop/features/cover_studio/studio_page.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md

import '../models/cover_brief.dart';

/// 目录项只存 id 和送给模型的中文措辞；界面上显示的标签走 LocaleKeys，
/// 不在这里做 i18n —— 提示词正文本身始终是中文，与界面语言无关。

class CoverStyleOption {
  const CoverStyleOption(this.id);

  /// 同时是送进提示词的措辞。
  final String id;
}

const coverStyleCustomId = '自定义';

const coverStyles = <CoverStyleOption>[
  CoverStyleOption('水墨写意'),
  CoverStyleOption('版画质感'),
  CoverStyleOption('极简文字'),
  CoverStyleOption('摄影写实'),
  CoverStyleOption('手绘插画'),
];

class CoverPaletteOption {
  const CoverPaletteOption({
    required this.id,
    required this.word,
    required this.startArgb,
    required this.endArgb,
  });

  final String id;

  /// 提示词里「色调X」的 X。
  final String word;

  /// 色卡渐变的两端，UI 直接拿去画 swatch。
  final int startArgb;
  final int endArgb;
}

const coverPalettes = <CoverPaletteOption>[
  CoverPaletteOption(
    id: 'ink',
    word: '墨与宣',
    startArgb: 0xfff3efe7,
    endArgb: 0xff2c2418,
  ),
  CoverPaletteOption(
    id: 'brass',
    word: '黄铜',
    startArgb: 0xffe6cda8,
    endArgb: 0xff8b7355,
  ),
  CoverPaletteOption(
    id: 'night',
    word: '夜航',
    startArgb: 0xff4a5568,
    endArgb: 0xff1a1714,
  ),
  CoverPaletteOption(
    id: 'cinnabar',
    word: '朱砂',
    startArgb: 0xffd9a48f,
    endArgb: 0xffa63f35,
  ),
  CoverPaletteOption(
    id: 'grey',
    word: '素灰',
    startArgb: 0xfffaf8f4,
    endArgb: 0xff8a7d6b,
  ),
];

class CoverCompositionOption {
  const CoverCompositionOption(this.id, this.word);

  final String id;

  /// 跟在构图名后面的一句展开，告诉模型「这个构图具体长什么样」。
  final String word;
}

const coverCompositions = <CoverCompositionOption>[
  CoverCompositionOption('中心构图', '主体居中，四周向内收拢'),
  CoverCompositionOption('三分构图', '主体压在三分线上，另一侧留白'),
  CoverCompositionOption('留白构图', '主体偏一侧，留出大片可放文字的暗部'),
  CoverCompositionOption('对称构图', '左右对称，重心落在中轴'),
];

/// 画面比例。只描述形状，实际像素由它和 [CoverResolutionOption] 一起算出来。
class CoverRatioOption {
  const CoverRatioOption({
    required this.id,
    required this.hint,
    required this.w,
    required this.h,
  });

  final String id;

  /// 「3:4」这种给人看的比例文本，也会写进提示词的输出行。
  final String hint;
  final int w;
  final int h;

  double get aspectRatio => w / h;
}

/// 只留 3:4 一档：番茄、起点这些平台的封面位就是这个比例，出别的比例上架还得裁。
/// 旧批次存的其他比例 id 由 [coverRatioOf] 兜底回落到这一档。
const coverRatios = <CoverRatioOption>[
  CoverRatioOption(id: '3_4', hint: '3:4', w: 3, h: 4),
];

const coverDefaultRatioId = '3_4';

/// 输出分辨率档位。[longEdge] 是长边像素，短边按比例算。
class CoverResolutionOption {
  const CoverResolutionOption({required this.id, required this.longEdge});

  final String id;
  final int longEdge;
}

/// 最高档长边取 3072 而不是 4096：上游 gpt-image-2 限制单边 ≤3840、总像素
/// ≤8,294,400，3:4 下的 3072x4096 两项都超，请求会被直接拒。
const coverResolutions = <CoverResolutionOption>[
  CoverResolutionOption(id: '1k', longEdge: 1024),
  CoverResolutionOption(id: '2k', longEdge: 2048),
  CoverResolutionOption(id: '4k', longEdge: 3072),
];

const coverDefaultResolutionId = '2k';

/// 出图质量。[apiValue] 一定随请求发出。
class CoverQualityOption {
  const CoverQualityOption({required this.id, required this.apiValue});

  final String id;
  final String apiValue;
}

/// 显式发送质量档位，让输出质量保持可控。
const coverQualities = <CoverQualityOption>[
  CoverQualityOption(id: 'low', apiValue: 'low'),
  CoverQualityOption(id: 'medium', apiValue: 'medium'),
  CoverQualityOption(id: 'high', apiValue: 'high'),
];

const coverDefaultQualityId = 'medium';

/// 比例 × 分辨率 → 下发给模型的 `WxH`。
///
/// 长边取档位值，短边按比例推，并都收敛到 32 的倍数 —— 多数图像模型要求边长是
/// 8/16/32 的倍数，直接送 683 这种数会被拒。
String coverImageSize(
  CoverRatioOption ratio,
  CoverResolutionOption resolution,
) {
  final long = resolution.longEdge;
  final landscape = ratio.w >= ratio.h;
  final shortEdge = landscape
      ? long * ratio.h / ratio.w
      : long * ratio.w / ratio.h;
  final rounded = _roundTo32(shortEdge);
  return landscape ? '${long}x$rounded' : '${rounded}x$long';
}

int _roundTo32(double value) {
  final snapped = (value / 32).round() * 32;
  return snapped < 32 ? 32 : snapped;
}

/// 参考图张数上限。入口（[addReference]）就卡住，超出的图加不进来，
/// 所以下游不需要再做一次裁剪。
const coverReferenceLimit = 4;

/// 一批默认出几张，以及作者可调的上下限。
const coverBatchCount = 1;
const coverBatchCountMin = 1;
const coverBatchCountMax = 8;

CoverPaletteOption coverPaletteOf(String id) => coverPalettes.firstWhere(
  (item) => item.id == id,
  orElse: () => coverPalettes.first,
);

CoverCompositionOption coverCompositionOf(String id) => coverCompositions
    .firstWhere((item) => item.id == id, orElse: () => coverCompositions.first);

CoverRatioOption coverRatioOf(String id) {
  final match = RegExp(r'^([1-9][0-9]*)[:_]([1-9][0-9]*)$').firstMatch(id);
  if (match != null) {
    return CoverRatioOption(
      id: id,
      hint: id.replaceAll('_', ':'),
      w: int.parse(match[1]!),
      h: int.parse(match[2]!),
    );
  }
  // 自动或非数字比例仅在尚无成图的预览中使用封面画框。
  return coverRatios.first;
}

CoverResolutionOption coverResolutionOf(String id) =>
    coverResolutions.firstWhere(
      (item) => item.id == id,
      orElse: () => coverResolutions.firstWhere(
        (item) => item.id == coverDefaultResolutionId,
      ),
    );

/// 旧批次存的 `auto` 由这里回落到默认档。
CoverQualityOption coverQualityOf(String id) => coverQualities.firstWhere(
  (item) => item.id == id,
  orElse: () =>
      coverQualities.firstWhere((item) => item.id == coverDefaultQualityId),
);

/// 一张随请求发出的参考图。怎么用它由作者写在提示词里，这里不再挂用途。
class CoverReferenceSpec {
  const CoverReferenceSpec({required this.assetId, this.name = ''});

  final String assetId;

  /// 用于溯源展示的文件名，不进提示词。
  final String name;
}

/// 打开设计师时的默认提示词。定义权在用户：风格 / 色调 / 构图 / 档案 / 灵感
/// 都只是可点的追加碎片，不会再自动拼进这段话。作品简介同样不预填，
/// 由提示词标题旁的「加入简介」追加。
String defaultCoverPrompt({
  required String novelTitle,
  required String authorName,
}) {
  final title = novelTitle.trim().isEmpty ? '（未填）' : novelTitle.trim();
  final author = authorName.trim().isEmpty ? '（未填）' : authorName.trim();
  return [
    '你是一个专业的网文封面设计师，请设计一个有吸引力的封面，适合于番茄等平台。',
    '作品名：$title',
    '作者名：$author',
  ].join('\n');
}

/// 把作品简介收成可追加进提示词的一行。
String coverSynopsisSnippet(String description) =>
    coverBriefFieldSnippet('作品简介', description);

/// 点选风格 / 色调 / 构图时追加进提示词的句子。
String coverStyleSnippet(String styleId) => '风格：$styleId。';

String coverPaletteSnippet(String paletteId) =>
    '色调：${coverPaletteOf(paletteId).word}。';

String coverCompositionSnippet(String compositionId) {
  final composition = coverCompositionOf(compositionId);
  return '构图：${composition.id}，${composition.word}。';
}

String coverBriefFieldSnippet(String label, String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  // 档案字段本身常已带句号；再包一层标签，方便作者回看来源。
  final body = trimmed.endsWith('。') || trimmed.endsWith('.')
      ? trimmed
      : '$trimmed。';
  return '$label：$body';
}

String coverMotifSnippet(CoverBriefMotif motif) {
  final text = motif.text.trim();
  if (text.isEmpty) {
    return '';
  }
  return '意象：「$text」。';
}

/// 下发的正文就是作者写的提示词本身。参考图不再自动拼「参考：image N ...」——
/// 怎么用参考图由作者自己在提示词里描述，界面上以 help text 提示这一点。
String finalizeCoverPrompt({required String userPrompt}) => userPrompt.trim();

/// 把一句灵感追加进可编辑提示词；已有同样句子则跳过，避免连点叠两遍。
String appendCoverPromptFragment(String current, String fragment) {
  final addition = fragment.trim();
  if (addition.isEmpty) {
    return current;
  }
  if (current.contains(addition)) {
    return current;
  }
  final trimmed = current.trimRight();
  if (trimmed.isEmpty) {
    return addition;
  }
  return '$trimmed\n$addition';
}
