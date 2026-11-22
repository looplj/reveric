// 职责: 地图图片资产展示元数据 — 读取和保存历史列表所需的展示字段。
// 关联文件:
//   lib/shared/widgets/map/map_history_tab.dart
//   lib/shared/providers/map_studio_controller.dart
//   lib/shared/services/image_library_service.dart
// 遵循的 Rules:
//   .agents/rules/json.md

class MapAssetMetadata {
  const MapAssetMetadata({
    this.schemaVersion = 1,
    this.source = 'cartographer',
    this.sourceMapName,
    this.styleId,
    this.styleWord,
    this.resolutionId,
    this.qualityId,
    this.customQuality,
    this.customSize,
    this.includeLocations = true,
    this.referenceCurrentImage = false,
  });

  final int schemaVersion;
  final String source;
  final String? sourceMapName;
  final String? styleId;
  final String? styleWord;
  final String? resolutionId;
  final String? qualityId;
  final String? customQuality;
  final String? customSize;
  final bool includeLocations;
  final bool referenceCurrentImage;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema_version': schemaVersion,
    'source': source,
    if (sourceMapName != null) 'source_map_name': sourceMapName,
    if (styleId != null) 'style_id': styleId,
    if (styleWord != null) 'style_word': styleWord,
    if (resolutionId != null) 'resolution_id': resolutionId,
    if (qualityId != null) 'quality_id': qualityId,
    if (customQuality != null) 'custom_quality': customQuality,
    if (customSize != null) 'custom_size': customSize,
    'include_locations': includeLocations,
    'reference_current_image': referenceCurrentImage,
  };

  factory MapAssetMetadata.fromJson(Map<String, dynamic>? value) {
    final decoded = value ?? <String, dynamic>{};
    String? text(String key) {
      final raw = decoded[key];
      return raw is String && raw.trim().isNotEmpty ? raw.trim() : null;
    }

    return MapAssetMetadata(
      schemaVersion: decoded['schema_version'] is num
          ? (decoded['schema_version'] as num).toInt()
          : 1,
      source: text('source') ?? 'cartographer',
      sourceMapName: text('source_map_name'),
      styleId: text('style_id'),
      styleWord: text('style_word'),
      resolutionId: text('resolution_id'),
      qualityId: text('quality_id'),
      customQuality: text('custom_quality'),
      customSize: text('custom_size'),
      includeLocations: decoded['include_locations'] is bool
          ? decoded['include_locations'] as bool
          : true,
      referenceCurrentImage: decoded['reference_current_image'] is bool
          ? decoded['reference_current_image'] as bool
          : false,
    );
  }
}
