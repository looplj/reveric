// 职责: 定义图像模型与渠道共用的能力、请求默认值及字段覆盖规则。
// 关联文件:
//   lib/shared/models/image/catalog.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/models/model_config.dart

import '../model_config.dart';
export '../model_config.dart' show ConfigValue;

enum ImageReferenceTransport { file, url, uploaded }

class ImageModelCapabilities {
  const ImageModelCapabilities({
    this._referenceTransport,
    this._ratios,
    this._resolutions,
    this._sizes,
    this._minReferences,
    this._maxReferences,
    this._unlimitedReferences,
    this._minPixels,
    this._maxPixels,
    this._maxEditPixels,
    this._maxAspectRatio,
    this._complexityLevels,
    this._qualityLevels,
  });

  final ImageReferenceTransport? _referenceTransport;
  ImageReferenceTransport get referenceTransport =>
      _referenceTransport ?? ImageReferenceTransport.file;
  final Set<String>? _ratios;
  Set<String> get ratios => _ratios ?? const {'auto'};
  final Set<String>? _resolutions;
  Set<String> get resolutions => _resolutions ?? const {'auto'};
  final Map<String, Map<String, String>>? _sizes;
  Map<String, Map<String, String>> get sizes => _sizes ?? const {};
  final int? _minReferences;
  int get minReferences => _minReferences ?? 0;
  final int? _maxReferences;
  int get maxReferences => _maxReferences ?? 0;
  final bool? _unlimitedReferences;

  /// 未登记模型不设本地数量上限，由服务端验证。
  bool get unlimitedReferences => _unlimitedReferences ?? false;
  final ConfigValue<int>? _minPixels;
  int? get minPixels => _minPixels?.value;
  final ConfigValue<int>? _maxPixels;
  int? get maxPixels => _maxPixels?.value;
  final ConfigValue<int>? _maxEditPixels;
  int? get maxEditPixels => _maxEditPixels?.value;
  final ConfigValue<double>? _maxAspectRatio;
  double? get maxAspectRatio => _maxAspectRatio?.value;
  final Set<String>? _complexityLevels;

  /// 空集表示该型号没有复杂度档位。
  Set<String> get complexityLevels => _complexityLevels ?? const {};
  final Set<String>? _qualityLevels;

  /// 空集表示未声明质量档位，只使用请求默认值。
  Set<String> get qualityLevels => _qualityLevels ?? const {};

  ImageModelCapabilities merge(
    ImageModelCapabilities overrides,
  ) => ImageModelCapabilities(
    referenceTransport: overrides._referenceTransport ?? _referenceTransport,
    ratios: overrides._ratios ?? _ratios,
    resolutions: overrides._resolutions ?? _resolutions,
    sizes: overrides._sizes ?? _sizes,
    minReferences: overrides._minReferences ?? _minReferences,
    maxReferences: overrides._maxReferences ?? _maxReferences,
    unlimitedReferences: overrides._unlimitedReferences ?? _unlimitedReferences,
    minPixels: overrides._minPixels ?? _minPixels,
    maxPixels: overrides._maxPixels ?? _maxPixels,
    maxEditPixels: overrides._maxEditPixels ?? _maxEditPixels,
    maxAspectRatio: overrides._maxAspectRatio ?? _maxAspectRatio,
    complexityLevels: overrides._complexityLevels ?? _complexityLevels,
    qualityLevels: overrides._qualityLevels ?? _qualityLevels,
  );

  String? size(String ratio, String resolution) {
    if (!ratios.contains(ratio) || !resolutions.contains(resolution)) {
      throw const FormatException('Unsupported image specification');
    }
    return sizes[resolution]?[ratio];
  }

  bool allowsReferenceCount(int count) =>
      count >= minReferences && (unlimitedReferences || count <= maxReferences);

  void validateReferences(int count) {
    if (!allowsReferenceCount(count)) {
      throw const FormatException('Unsupported image reference count');
    }
  }

  void validateSize(String? size, {int references = 0}) {
    if (size == null || size == 'auto') {
      return;
    }
    if (resolutions.contains(size)) {
      // Check a tier's pixel budget as well as explicit dimensions.
      final dimensions = sizes[size]?['1:1'];
      if (dimensions == null) {
        return;
      }
      size = dimensions;
    }
    final match = RegExp(r'^([1-9][0-9]*)x([1-9][0-9]*)$').firstMatch(size);
    if (match == null) {
      throw const FormatException('Unsupported image size');
    }
    final width = int.parse(match[1]!);
    final height = int.parse(match[2]!);
    final pixels = width * height;
    if ((minPixels != null && pixels < minPixels!) ||
        (maxPixels != null && pixels > maxPixels!) ||
        (references > 0 && maxEditPixels != null && pixels > maxEditPixels!) ||
        (maxAspectRatio != null &&
            (width / height > maxAspectRatio! ||
                height / width > maxAspectRatio!))) {
      throw const FormatException('Unsupported image dimensions');
    }
  }

  Map<String, dynamic> toJson() => {
    'referenceTransport': referenceTransport.name,
    'ratios': ratios.toList(),
    'resolutions': resolutions.toList(),
    'sizes': sizes,
    'minReferences': minReferences,
    'maxReferences': maxReferences,
    'unlimitedReferences': unlimitedReferences,
    'minPixels': minPixels,
    'maxPixels': maxPixels,
    'maxEditPixels': maxEditPixels,
    'maxAspectRatio': maxAspectRatio,
    'complexityLevels': complexityLevels.toList(),
    'qualityLevels': qualityLevels.toList(),
  };
  factory ImageModelCapabilities.fromJson(
    Map<String, dynamic> json,
  ) => ImageModelCapabilities(
    referenceTransport: json['referenceTransport'] == null
        ? null
        : ImageReferenceTransport.values.byName(
            json['referenceTransport'] as String,
          ),
    ratios: (json['ratios'] as List?)?.cast<String>().toSet(),
    resolutions: (json['resolutions'] as List?)?.cast<String>().toSet(),
    sizes: (json['sizes'] as Map<String, dynamic>?)?.map(
      (key, value) =>
          MapEntry(key, (value as Map<String, dynamic>).cast<String, String>()),
    ),
    minReferences: json['minReferences'] as int?,
    maxReferences: json['maxReferences'] as int?,
    unlimitedReferences: json['unlimitedReferences'] as bool?,
    minPixels: ConfigValue(json['minPixels'] as int?),
    maxPixels: ConfigValue(json['maxPixels'] as int?),
    maxEditPixels: ConfigValue(json['maxEditPixels'] as int?),
    maxAspectRatio: ConfigValue((json['maxAspectRatio'] as num?)?.toDouble()),
    complexityLevels: (json['complexityLevels'] as List?)
        ?.cast<String>()
        .toSet(),
    qualityLevels: (json['qualityLevels'] as List?)?.cast<String>().toSet(),
  );
}

class ImageRequestDefaults {
  const ImageRequestDefaults({
    this._size,
    this._responseFormat,
    this._outputFormat,
    this._quality,
    this._watermark,
    this._promptExtend,
    this._promptOptimization,
    this._complexity,
  });

  final ConfigValue<String>? _size;
  String? get size => _size?.value;
  final ConfigValue<String>? _responseFormat;
  String? get responseFormat => _responseFormat?.value;
  final ConfigValue<String>? _outputFormat;
  String? get outputFormat => _outputFormat?.value;
  final ConfigValue<String>? _quality;
  String? get quality => _quality?.value;
  final ConfigValue<bool>? _watermark;
  bool? get watermark => _watermark?.value;
  final ConfigValue<bool>? _promptExtend;
  bool? get promptExtend => _promptExtend?.value;
  final ConfigValue<String>? _promptOptimization;
  String? get promptOptimization => _promptOptimization?.value;
  final ConfigValue<String>? _complexity;
  String? get complexity => _complexity?.value;

  ImageRequestDefaults merge(ImageRequestDefaults overrides) =>
      ImageRequestDefaults(
        size: overrides._size ?? _size,
        responseFormat: overrides._responseFormat ?? _responseFormat,
        outputFormat: overrides._outputFormat ?? _outputFormat,
        quality: overrides._quality ?? _quality,
        watermark: overrides._watermark ?? _watermark,
        promptExtend: overrides._promptExtend ?? _promptExtend,
        promptOptimization:
            overrides._promptOptimization ?? _promptOptimization,
        complexity: overrides._complexity ?? _complexity,
      );
  Map<String, dynamic> toJson() => {
    'size': size,
    'responseFormat': responseFormat,
    'outputFormat': outputFormat,
    'quality': quality,
    'watermark': watermark,
    'promptExtend': promptExtend,
    'promptOptimization': promptOptimization,
    'complexity': complexity,
  };
  factory ImageRequestDefaults.fromJson(Map<String, dynamic> json) =>
      ImageRequestDefaults(
        size: ConfigValue(json['size'] as String?),
        responseFormat: ConfigValue(json['responseFormat'] as String?),
        outputFormat: ConfigValue(json['outputFormat'] as String?),
        quality: ConfigValue(json['quality'] as String?),
        watermark: ConfigValue(json['watermark'] as bool?),
        promptExtend: ConfigValue(json['promptExtend'] as bool?),
        promptOptimization: ConfigValue(json['promptOptimization'] as String?),
        complexity: ConfigValue(json['complexity'] as String?),
      );
}
