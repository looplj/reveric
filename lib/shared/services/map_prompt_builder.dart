// 职责: 地图制图提示词 — 拼装地图生成 prompt
// 关联文件:
//   lib/shared/models/map_studio_models.dart
//   lib/shared/services/generate_map_orchestrator.dart
//   lib/shared/models/map_agent.dart
// 遵循的 Rules:
//   .agents/rules/ai-calling.md
import '../database/novel_content_database.dart'
    show mapTypeRegion, mapTypeWorld;
import '../models/map_agent.dart' show mapCustomStyleId;
import '../models/map_studio_models.dart';

/// 画风选项。word 在提交时以独立指令追加到出图 prompt。
class MapStyleOption {
  const MapStyleOption({required this.id, required this.word});

  final String id;
  final String word;
}

const mapStyleOptions = <MapStyleOption>[
  MapStyleOption(id: 'parchment', word: '手绘羊皮纸'),
  MapStyleOption(id: 'inkmap', word: '水墨舆图'),
  MapStyleOption(id: 'engraving', word: '版画线描'),
  MapStyleOption(id: 'realistic', word: '写实地形'),
  MapStyleOption(id: 'woodcut', word: '古籍插图'),
  MapStyleOption(id: 'watercolor', word: '柔和水彩绘本'),
  MapStyleOption(id: 'atlas', word: '清晰现代图册'),
];

String? mapStyleWordOf({
  required String? styleId,
  required String? customStyleWord,
}) {
  if (styleId == mapCustomStyleId) {
    final normalizedCustomStyle = customStyleWord?.trim();
    return normalizedCustomStyle == null || normalizedCustomStyle.isEmpty
        ? null
        : normalizedCustomStyle;
  }
  return mapStyleOptions
      .where((option) => option.id == styleId)
      .map((option) => option.word)
      .firstOrNull;
}

/// 由成图记录的画风词反查面板选项：预设词对应预设 id，其余视为自定义画风。
({String styleId, String? customStyleWord})? mapStyleSelectionOf(
  String? styleWord,
) {
  final word = styleWord?.trim();
  if (word == null || word.isEmpty) {
    return null;
  }
  final preset = mapStyleOptions
      .where((option) => option.word == word)
      .firstOrNull;
  return preset != null
      ? (styleId: preset.id, customStyleWord: null)
      : (styleId: mapCustomStyleId, customStyleWord: word);
}

/// 输出分辨率档位。[longEdge] 是长边像素，短边按 16:9 横版比例算。
class MapResolutionOption {
  const MapResolutionOption({required this.id, required this.longEdge});

  final String id;
  final int longEdge;
}

/// 与封面工作台同一档位：gpt-image-2 限制单边 ≤3840、总像素 ≤8,294,400。
///
/// 1K 档取 1280 而不是 1024：16:9 下 1024x576 被上游渠道拒绝（2026-08-31 实测），
/// 1280x720 是实测可用的最小 16:9。
const mapResolutions = <MapResolutionOption>[
  MapResolutionOption(id: '1k', longEdge: 1280),
  MapResolutionOption(id: '2k', longEdge: 2048),
  MapResolutionOption(id: '4k', longEdge: 3072),
];

const mapDefaultResolutionId = '2k';

/// 分辨率 × 16:9 横版 → 下发给模型的 `WxH`，短边收敛到 16 的倍数（上游要求
/// 边长为 16 的倍数；1280x720 / 2048x1152 / 3072x1728 均已实测可用）。
String mapImageSize(MapResolutionOption resolution) {
  final long = resolution.longEdge;
  final short = _roundTo16(long * 9 / 16);
  return '${long}x$short';
}

int _roundTo16(double value) {
  final snapped = (value / 16).round() * 16;
  return snapped < 16 ? 16 : snapped;
}

MapResolutionOption mapResolutionOf(String id) => mapResolutions.firstWhere(
  (item) => item.id == id,
  orElse: () =>
      mapResolutions.firstWhere((item) => item.id == mapDefaultResolutionId),
);

/// 出图质量档位。[apiValue] 一定随请求发出。
class MapQualityOption {
  const MapQualityOption({required this.id, required this.apiValue});

  final String id;
  final String apiValue;
}

/// 显式发送质量档位，让输出质量保持可控。
const mapQualities = <MapQualityOption>[
  MapQualityOption(id: 'low', apiValue: 'low'),
  MapQualityOption(id: 'medium', apiValue: 'medium'),
  MapQualityOption(id: 'high', apiValue: 'high'),
];

const mapDefaultQualityId = 'medium';

/// 旧批次存的 `auto` 由这里回落到默认档。
MapQualityOption mapQualityOf(String id) => mapQualities.firstWhere(
  (item) => item.id == id,
  orElse: () =>
      mapQualities.firstWhere((item) => item.id == mapDefaultQualityId),
);

/// 地图生成的 prompt。有参考图时走编辑，否则走文生图。
///
/// [mapType] 决定画面尺度：世界图画大陆疆域，区域图画一片地域，
/// 城镇及以下画街区与建筑平面。
String buildMapImagePrompt({
  required List<MapRegionSpec> regions,
  required List<MapPlaceNameCandidate> places,
  required bool referenceCurrentImage,
  String mapType = mapTypeWorld,
  String? parentReferenceName,
}) {
  final regionText = regions.map((region) => region.name).join('、');
  final regionIds = regions.map((region) => region.locationId).toSet();
  final placeText = places
      .where((place) => !regionIds.contains(place.locationId))
      .map((place) => place.name)
      .join('、');
  final lines = <String>[
    ...switch (mapType) {
      mapTypeWorld => [
        '绘制一张地图。',
        if (regionText.isNotEmpty)
          '大陆上划分出这些势力疆域：$regionText，疆域之间以山脉、河流或海岸自然分界。',
        if (placeText.isNotEmpty) '在合理的位置标出这些城市与地标：$placeText。',
      ],
      mapTypeRegion => [
        '绘制一张区域地图。',
        if (regionText.isNotEmpty) '区域内划分出这些势力范围：$regionText，以山脉、河流或道路自然分界。',
        if (placeText.isNotEmpty) '在合理的位置标出这些城镇与地标：$placeText。',
      ],
      _ => [
        '绘制一张城镇平面地图，俯视视角。',
        if (regionText.isNotEmpty) '划分出这些片区：$regionText。',
        if (placeText.isNotEmpty) '在合理的位置标出这些街区、建筑与地标：$placeText。',
      ],
    },
  ];
  if (referenceCurrentImage) {
    lines.add('参考：image 1 是这张地图的上一版画面，保持它的整体构图与地貌走向，在此基础上重画。');
  }
  if (parentReferenceName != null) {
    final index = referenceCurrentImage ? 2 : 1;
    lines.add(
      '参考：image $index 是上层地图「$parentReferenceName」，只沿用它的画风、配色、线条质感与地名字体，'
      '不要沿用它的构图、地形和地名。',
    );
  }
  return lines.join('\n');
}

/// 在真正调用图片模型前追加当前画风，避免画风选择与可编辑 prompt 相互覆盖。
String buildMapSubmissionPrompt({
  required String prompt,
  required String? styleWord,
}) {
  final normalizedPrompt = prompt.trim();
  final normalizedStyle = styleWord?.trim();
  if (normalizedStyle == null || normalizedStyle.isEmpty) {
    return normalizedPrompt;
  }
  final styleLine = '风格：$normalizedStyle';
  if (normalizedPrompt.split('\n').last.trim() == styleLine) {
    return normalizedPrompt;
  }
  if (normalizedPrompt.isEmpty) {
    return styleLine;
  }
  return '$normalizedPrompt\n$styleLine';
}
