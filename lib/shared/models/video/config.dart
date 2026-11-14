// 职责: 定义视频模型与渠道共用的能力、参考限制和请求默认值及逐字段覆盖规则。
// 关联文件:
//   lib/shared/models/video/catalog.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/model_config.dart

import '../model_config.dart';
import 'request.dart';
export '../model_config.dart' show ConfigValue;

const videoRatios = {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16', 'adaptive'};

class VideoReferenceLimits {
  const VideoReferenceLimits({
    this._maxCount,
    this._mimeTypes,
    this._maxSizeMb,
    this._minDimension,
    this._maxDimension,
    this._minRatio,
    this._maxRatio,
    this._minDurationMs,
    this._maxDurationMs,
    this._maxTotalDurationMs,
    this._minTotalDurationMs,
    this._maxTotalSizeMb,
    this._minFrameRate,
    this._maxFrameRate,
    this._minPixels,
    this._maxPixels,
    this._exclusiveMaxSize,
  });

  final int? _maxCount;
  int get maxCount => _maxCount ?? 0;
  final ConfigValue<Set<String>>? _mimeTypes;
  Set<String>? get mimeTypes => _mimeTypes?.value;
  final ConfigValue<num>? _maxSizeMb;
  num? get maxSizeMb => _maxSizeMb?.value;
  final ConfigValue<int>? _minDimension;
  int? get minDimension => _minDimension?.value;
  final ConfigValue<int>? _maxDimension;
  int? get maxDimension => _maxDimension?.value;
  final ConfigValue<double>? _minRatio;
  double? get minRatio => _minRatio?.value;
  final ConfigValue<double>? _maxRatio;
  double? get maxRatio => _maxRatio?.value;
  final ConfigValue<int>? _minDurationMs;
  int? get minDurationMs => _minDurationMs?.value;
  final ConfigValue<int>? _maxDurationMs;
  int? get maxDurationMs => _maxDurationMs?.value;
  final ConfigValue<int>? _maxTotalDurationMs;
  int? get maxTotalDurationMs => _maxTotalDurationMs?.value;
  final ConfigValue<int>? _minTotalDurationMs;
  int? get minTotalDurationMs => _minTotalDurationMs?.value;
  final ConfigValue<num>? _maxTotalSizeMb;
  num? get maxTotalSizeMb => _maxTotalSizeMb?.value;
  final ConfigValue<double>? _minFrameRate;
  double? get minFrameRate => _minFrameRate?.value;
  final ConfigValue<double>? _maxFrameRate;
  double? get maxFrameRate => _maxFrameRate?.value;
  final ConfigValue<int>? _minPixels;
  int? get minPixels => _minPixels?.value;
  final ConfigValue<int>? _maxPixels;
  int? get maxPixels => _maxPixels?.value;
  final bool? _exclusiveMaxSize;
  bool get exclusiveMaxSize => _exclusiveMaxSize ?? false;

  VideoReferenceLimits merge(
    VideoReferenceLimits overrides,
  ) => VideoReferenceLimits(
    maxCount: overrides._maxCount ?? _maxCount,
    mimeTypes: overrides._mimeTypes ?? _mimeTypes,
    maxSizeMb: overrides._maxSizeMb ?? _maxSizeMb,
    minDimension: overrides._minDimension ?? _minDimension,
    maxDimension: overrides._maxDimension ?? _maxDimension,
    minRatio: overrides._minRatio ?? _minRatio,
    maxRatio: overrides._maxRatio ?? _maxRatio,
    minDurationMs: overrides._minDurationMs ?? _minDurationMs,
    maxDurationMs: overrides._maxDurationMs ?? _maxDurationMs,
    maxTotalDurationMs: overrides._maxTotalDurationMs ?? _maxTotalDurationMs,
    minTotalDurationMs: overrides._minTotalDurationMs ?? _minTotalDurationMs,
    maxTotalSizeMb: overrides._maxTotalSizeMb ?? _maxTotalSizeMb,
    minFrameRate: overrides._minFrameRate ?? _minFrameRate,
    maxFrameRate: overrides._maxFrameRate ?? _maxFrameRate,
    minPixels: overrides._minPixels ?? _minPixels,
    maxPixels: overrides._maxPixels ?? _maxPixels,
    exclusiveMaxSize: overrides._exclusiveMaxSize ?? _exclusiveMaxSize,
  );
  Map<String, dynamic> toJson() => {
    'maxCount': maxCount,
    'mimeTypes': mimeTypes?.toList(),
    'maxSizeMb': maxSizeMb,
    'minDimension': minDimension,
    'maxDimension': maxDimension,
    'minRatio': minRatio,
    'maxRatio': maxRatio,
    'minDurationMs': minDurationMs,
    'maxDurationMs': maxDurationMs,
    'maxTotalDurationMs': maxTotalDurationMs,
    'minTotalDurationMs': minTotalDurationMs,
    'maxTotalSizeMb': maxTotalSizeMb,
    'minFrameRate': minFrameRate,
    'maxFrameRate': maxFrameRate,
    'minPixels': minPixels,
    'maxPixels': maxPixels,
    'exclusiveMaxSize': exclusiveMaxSize,
  };
  factory VideoReferenceLimits.fromJson(Map<String, dynamic> json) =>
      VideoReferenceLimits(
        maxCount: json['maxCount'] as int?,
        mimeTypes: ConfigValue(
          (json['mimeTypes'] as List?)?.cast<String>().toSet(),
        ),
        maxSizeMb: ConfigValue(json['maxSizeMb'] as num?),
        minDimension: ConfigValue(json['minDimension'] as int?),
        maxDimension: ConfigValue(json['maxDimension'] as int?),
        minRatio: ConfigValue((json['minRatio'] as num?)?.toDouble()),
        maxRatio: ConfigValue((json['maxRatio'] as num?)?.toDouble()),
        minDurationMs: ConfigValue(json['minDurationMs'] as int?),
        maxDurationMs: ConfigValue(json['maxDurationMs'] as int?),
        maxTotalDurationMs: ConfigValue(json['maxTotalDurationMs'] as int?),
        minTotalDurationMs: ConfigValue(json['minTotalDurationMs'] as int?),
        maxTotalSizeMb: ConfigValue(json['maxTotalSizeMb'] as num?),
        minFrameRate: ConfigValue((json['minFrameRate'] as num?)?.toDouble()),
        maxFrameRate: ConfigValue((json['maxFrameRate'] as num?)?.toDouble()),
        minPixels: ConfigValue(json['minPixels'] as int?),
        maxPixels: ConfigValue(json['maxPixels'] as int?),
        exclusiveMaxSize: json['exclusiveMaxSize'] as bool?,
      );
}

class VideoDraftCapabilities {
  const VideoDraftCapabilities({
    required this.resolution,
    required this.completionResolution,
    required this.ttlHours,
  });
  final String resolution;
  final String completionResolution;
  final int ttlHours;
  Map<String, dynamic> toJson() => {
    'resolution': resolution,
    'completionResolution': completionResolution,
    'ttlHours': ttlHours,
  };
  factory VideoDraftCapabilities.fromJson(Map<String, dynamic> json) =>
      VideoDraftCapabilities(
        resolution: json['resolution'] as String,
        completionResolution: json['completionResolution'] as String,
        ttlHours: json['ttlHours'] as int,
      );
}

class VideoModelCapabilities {
  const VideoModelCapabilities({
    this._resolutions,
    this._ratios,
    this._durations,
    this._frameRoles,
    this._maxMiddleFrames,
    this._maxPromptCharacters,
    this._maxReferences,
    this._references,
    this._supportsAudioOnlyReference,
    this._supportsAdaptiveTextRatio,
    this._supportsLastFrameOnly,
    this._maxInputOutputDurationMs,
    this._modes,
    this._draft,
    this._maxDurationByResolution,
    this._framesRequireAdaptiveRatio,
    this._supportsCertifiedAssets,
  });

  final Set<String>? _resolutions;
  Set<String> get resolutions => _resolutions ?? const {};
  final Set<String>? _ratios;
  Set<String> get ratios => _ratios ?? videoRatios;
  final Set<int>? _durations;
  Set<int> get durations => _durations ?? const {};
  final Set<VideoInputRole>? _frameRoles;
  Set<VideoInputRole> get frameRoles =>
      _frameRoles ??
      const {VideoInputRole.first_frame, VideoInputRole.last_frame};
  final int? _maxMiddleFrames;
  int get maxMiddleFrames => _maxMiddleFrames ?? 0;
  final ConfigValue<int>? _maxPromptCharacters;
  int? get maxPromptCharacters => _maxPromptCharacters?.value;
  final int? _maxReferences;
  int get maxReferences => _maxReferences ?? 0;

  /// 覆盖层中值为 null 的类型表示该渠道不接受这种参考素材。
  final Map<VideoMediaKind, VideoReferenceLimits?>? _references;
  Map<VideoMediaKind, VideoReferenceLimits> get references => {
    for (final MapEntry(:key, :value) in (_references ?? const {}).entries)
      key: ?value,
  };
  final bool? _supportsAudioOnlyReference;
  bool get supportsAudioOnlyReference => _supportsAudioOnlyReference ?? true;
  final bool? _supportsAdaptiveTextRatio;
  bool get supportsAdaptiveTextRatio => _supportsAdaptiveTextRatio ?? false;
  final bool? _supportsLastFrameOnly;
  bool get supportsLastFrameOnly => _supportsLastFrameOnly ?? false;
  final ConfigValue<int>? _maxInputOutputDurationMs;
  int? get maxInputOutputDurationMs => _maxInputOutputDurationMs?.value;
  final ConfigValue<VideoDraftCapabilities>? _draft;
  VideoDraftCapabilities? get draft => _draft?.value;
  final List<VideoMode>? _modes;
  List<VideoMode> get modes => _modes ?? VideoMode.values;
  final Map<String, int>? _maxDurationByResolution;
  Map<String, int> get maxDurationByResolution =>
      _maxDurationByResolution ?? const {};
  final bool? _framesRequireAdaptiveRatio;
  bool get framesRequireAdaptiveRatio => _framesRequireAdaptiveRatio ?? false;
  final bool? _supportsCertifiedAssets;
  bool get supportsCertifiedAssets => _supportsCertifiedAssets ?? false;

  VideoModelCapabilities merge(
    VideoModelCapabilities overrides,
  ) => VideoModelCapabilities(
    resolutions: overrides._resolutions ?? _resolutions,
    ratios: overrides._ratios ?? _ratios,
    durations: overrides._durations ?? _durations,
    frameRoles: overrides._frameRoles ?? _frameRoles,
    maxMiddleFrames: overrides._maxMiddleFrames ?? _maxMiddleFrames,
    maxPromptCharacters: overrides._maxPromptCharacters ?? _maxPromptCharacters,
    maxReferences: overrides._maxReferences ?? _maxReferences,
    references: mergeModelReferences(
      _references,
      overrides._references,
      (base, override) => base.merge(override),
    ),
    supportsAudioOnlyReference:
        overrides._supportsAudioOnlyReference ?? _supportsAudioOnlyReference,
    supportsAdaptiveTextRatio:
        overrides._supportsAdaptiveTextRatio ?? _supportsAdaptiveTextRatio,
    supportsLastFrameOnly:
        overrides._supportsLastFrameOnly ?? _supportsLastFrameOnly,
    maxInputOutputDurationMs:
        overrides._maxInputOutputDurationMs ?? _maxInputOutputDurationMs,
    modes: overrides._modes ?? _modes,
    draft: overrides._draft ?? _draft,
    maxDurationByResolution:
        overrides._maxDurationByResolution ?? _maxDurationByResolution,
    framesRequireAdaptiveRatio:
        overrides._framesRequireAdaptiveRatio ?? _framesRequireAdaptiveRatio,
    supportsCertifiedAssets:
        overrides._supportsCertifiedAssets ?? _supportsCertifiedAssets,
  );
  Map<String, dynamic> toJson() => {
    'resolutions': resolutions.toList(),
    'ratios': ratios.toList(),
    'durations': durations.toList(),
    'frameRoles': frameRoles.map((value) => value.name).toList(),
    'maxMiddleFrames': maxMiddleFrames,
    'maxPromptCharacters': maxPromptCharacters,
    'maxReferences': maxReferences,
    'references': references.map(
      (key, value) => MapEntry(key.name, value.toJson()),
    ),
    'supportsAudioOnlyReference': supportsAudioOnlyReference,
    'supportsAdaptiveTextRatio': supportsAdaptiveTextRatio,
    'supportsLastFrameOnly': supportsLastFrameOnly,
    'maxInputOutputDurationMs': maxInputOutputDurationMs,
    'draft': draft?.toJson(),
    'modes': modes.map((value) => value.name).toList(),
    'maxDurationByResolution': maxDurationByResolution,
    'framesRequireAdaptiveRatio': framesRequireAdaptiveRatio,
    'supportsCertifiedAssets': supportsCertifiedAssets,
  };
  factory VideoModelCapabilities.fromJson(Map<String, dynamic> json) =>
      VideoModelCapabilities(
        resolutions: (json['resolutions'] as List?)?.cast<String>().toSet(),
        ratios: (json['ratios'] as List?)?.cast<String>().toSet(),
        durations: (json['durations'] as List?)?.cast<int>().toSet(),
        frameRoles: (json['frameRoles'] as List?)
            ?.map((value) => VideoInputRole.values.byName(value as String))
            .toSet(),
        maxMiddleFrames: json['maxMiddleFrames'] as int?,
        maxPromptCharacters: ConfigValue(json['maxPromptCharacters'] as int?),
        maxReferences: json['maxReferences'] as int?,
        references: (json['references'] as Map<String, dynamic>?)?.map(
          (key, value) => MapEntry(
            VideoMediaKind.values.byName(key),
            VideoReferenceLimits.fromJson(value as Map<String, dynamic>),
          ),
        ),
        supportsAudioOnlyReference: json['supportsAudioOnlyReference'] as bool?,
        supportsAdaptiveTextRatio: json['supportsAdaptiveTextRatio'] as bool?,
        supportsLastFrameOnly: json['supportsLastFrameOnly'] as bool?,
        maxInputOutputDurationMs: ConfigValue(
          json['maxInputOutputDurationMs'] as int?,
        ),
        draft: ConfigValue(
          json['draft'] == null
              ? null
              : VideoDraftCapabilities.fromJson(
                  json['draft'] as Map<String, dynamic>,
                ),
        ),
        modes: (json['modes'] as List?)
            ?.map((value) => VideoMode.values.byName(value as String))
            .toList(),
        maxDurationByResolution:
            (json['maxDurationByResolution'] as Map<String, dynamic>?)
                ?.cast<String, int>(),
        framesRequireAdaptiveRatio: json['framesRequireAdaptiveRatio'] as bool?,
        supportsCertifiedAssets: json['supportsCertifiedAssets'] as bool?,
      );
}

class VideoRequestDefaults {
  const VideoRequestDefaults({this._audio, this._promptExtend});

  final ConfigValue<bool>? _audio;
  bool? get audio => _audio?.value;
  final ConfigValue<bool>? _promptExtend;
  bool? get promptExtend => _promptExtend?.value;

  VideoRequestDefaults merge(VideoRequestDefaults overrides) =>
      VideoRequestDefaults(
        audio: overrides._audio ?? _audio,
        promptExtend: overrides._promptExtend ?? _promptExtend,
      );
  Map<String, dynamic> toJson() => {
    'audio': audio,
    'promptExtend': promptExtend,
  };
  factory VideoRequestDefaults.fromJson(Map<String, dynamic> json) =>
      VideoRequestDefaults(
        audio: ConfigValue(json['audio'] as bool?),
        promptExtend: ConfigValue(json['promptExtend'] as bool?),
      );
}
