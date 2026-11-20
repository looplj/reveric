// 职责: 严格解析插件返回的图片与视频模型能力，并保留任务所需的完整请求默认值。
// 关联文件:
//   lib/shared/models/image/config.dart
//   lib/shared/models/video/config.dart
//   lib/shared/models/plugin/text.dart
//   lib/shared/services/plugins/host.dart
import 'dart:convert';
import '../../logger/app_logger.dart';
import '../ai_provider.dart' show AiModelKind;
import '../image/config.dart';
import '../video/config.dart';
import '../video/request.dart';
import 'text.dart';

final _log = AppLogger.forModule('PluginProviderModels');

class PluginProviderModel {
  const PluginProviderModel._({
    required this.kind,
    required this.id,
    this.name,
    this.image,
    this.video,
    required this.requestDefaults,
  });
  final AiModelKind kind;
  final String id;
  final PluginText? name;
  final ImageModelCapabilities? image;
  final VideoModelCapabilities? video;
  final Map<String, dynamic> requestDefaults;
  ImageRequestDefaults get imageDefaults =>
      ImageRequestDefaults.fromJson(requestDefaults);
  VideoRequestDefaults get videoDefaults =>
      VideoRequestDefaults.fromJson(requestDefaults);
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'id': id,
    if (name != null) 'name': name!.toJson(),
    'capabilities': image?.toJson() ?? video!.toJson(),
    'requestDefaults': requestDefaults,
  };

  factory PluginProviderModel.fromJson(Map<String, dynamic> json) {
    final id = _text(json['id'], 'model.id');
    final path = 'model[$id]';
    if (id != id.trim()) {
      throw FormatException('$path.id must not have surrounding whitespace');
    }
    final kind = switch (json['kind']) {
      'image' => AiModelKind.image,
      'video' => AiModelKind.video,
      _ => throw FormatException('$path.kind must be image or video'),
    };
    final defaults = _object(
      json['requestDefaults'] ?? <String, dynamic>{},
      '$path.requestDefaults',
    );
    _json(defaults, '$path.requestDefaults', <Object>{});
    for (final field
        in kind == AiModelKind.image
            ? [
                'size',
                'responseFormat',
                'outputFormat',
                'quality',
                'promptOptimization',
                'complexity',
              ]
            : <String>[]) {
      if (defaults[field] != null && defaults[field] is! String) {
        throw FormatException('$path.requestDefaults.$field must be a string');
      }
    }
    for (final field
        in kind == AiModelKind.image
            ? ['watermark', 'promptExtend']
            : ['audio', 'promptExtend']) {
      if (defaults[field] != null && defaults[field] is! bool) {
        throw FormatException('$path.requestDefaults.$field must be a boolean');
      }
    }
    final caps = _Reader(
      _object(json['capabilities'], '$path.capabilities'),
      '$path.capabilities',
    );
    final image = kind == AiModelKind.image ? _image(caps) : null;
    final video = kind == AiModelKind.video ? _video(caps) : null;
    if (image != null) {
      final complexity = defaults['complexity'];
      if (complexity != null && !image.complexityLevels.contains(complexity)) {
        throw FormatException(
          '$path.requestDefaults.complexity is unsupported',
        );
      }
      final quality = defaults['quality'];
      if (quality != null &&
          image.qualityLevels.isNotEmpty &&
          !image.qualityLevels.contains(quality)) {
        throw FormatException('$path.requestDefaults.quality is unsupported');
      }
      if (defaults['size'] case final String size) {
        try {
          image.validateSize(size);
        } on FormatException catch (error) {
          throw FormatException('$path.requestDefaults.size: ${error.message}');
        }
      }
    }
    return PluginProviderModel._(
      kind: kind,
      id: id,
      name: parseOptionalPluginText(json['name'], '$path.name'),
      image: image,
      video: video,
      requestDefaults: Map.unmodifiable(
        jsonDecode(jsonEncode(defaults)) as Map<String, dynamic>,
      ),
    );
  }
}

List<PluginProviderModel> parsePluginProviderModels(Object? value) {
  if (value is! List) {
    throw const FormatException('listModels must return an array');
  }
  final seen = <(AiModelKind, String)>{};
  final models = <PluginProviderModel>[];
  for (final item in value) {
    final json = _object(item, 'model');
    if (json['kind'] == 'chat') {
      continue;
    }
    final model = PluginProviderModel.fromJson(json);
    if (!seen.add((model.kind, model.id))) {
      throw FormatException('Duplicate ${model.kind.name} model: ${model.id}');
    }
    models.add(model);
  }
  return List.unmodifiable(models);
}

ImageModelCapabilities _image(_Reader r) {
  r.unknown(const ImageModelCapabilities().toJson().keys.toSet());
  final ratios = r.strings('ratios', required: true, nonempty: true);
  final resolutions = r.strings('resolutions', required: true, nonempty: true);
  final minimum = r.number(
    'minReferences',
    required: true,
    integer: true,
    min: 0,
  )!;
  final maximum = r.number(
    'maxReferences',
    required: true,
    integer: true,
    min: 0,
  )!;
  final unlimited = r.boolean('unlimitedReferences', required: true)!;
  r.check(
    unlimited || minimum <= maximum,
    'minReferences exceeds maxReferences',
  );
  final transport = r.value['referenceTransport'];
  r.check(
    transport is String &&
        ImageReferenceTransport.values.any((value) => value.name == transport),
    'referenceTransport is invalid',
  );
  for (final name in ['minPixels', 'maxPixels', 'maxEditPixels']) {
    r.number(name, integer: true, min: 1);
  }
  r.number('maxAspectRatio', min: 1);
  r.bounds('minPixels', 'maxPixels');
  r.bounds('minPixels', 'maxEditPixels');
  r.strings('complexityLevels');
  r.strings('qualityLevels');
  final sizes = r.value['sizes'];
  if (sizes != null) {
    for (final resolution in _object(sizes, '${r.path}.sizes').entries) {
      r.check(
        resolutions.contains(resolution.key),
        'sizes has an unknown resolution',
      );
      for (final size in _object(
        resolution.value,
        '${r.path}.sizes.${resolution.key}',
      ).entries) {
        r.check(ratios.contains(size.key), 'sizes has an unknown ratio');
        r.check(
          size.value is String &&
              RegExp(
                r'^[1-9][0-9]*x[1-9][0-9]*$',
              ).hasMatch(size.value as String),
          'sizes contains invalid dimensions',
        );
      }
    }
  }
  final model = ImageModelCapabilities.fromJson(
    r.known(const ImageModelCapabilities().toJson().keys.toSet()),
  );
  for (final sizes in model.sizes.values) {
    for (final size in sizes.values) {
      try {
        model.validateSize(size);
      } on FormatException catch (error) {
        throw FormatException('${r.path}.sizes: ${error.message}');
      }
    }
  }
  return model;
}

VideoModelCapabilities _video(_Reader r) {
  final keys = const VideoModelCapabilities().toJson().keys.toSet();
  r.unknown(keys);
  final ratios = r.strings('ratios', required: true, nonempty: true);
  final resolutions = r.strings('resolutions', required: true, nonempty: true);
  final durations = r.value['durations'];
  r.check(
    durations is List &&
        durations.isNotEmpty &&
        durations.every((value) => value is int && value > 0) &&
        durations.toSet().length == durations.length,
    'durations must be unique positive integers',
  );
  final modes = r.strings('modes', required: true, nonempty: true);
  r.check(
    modes.every(VideoMode.values.asNameMap().containsKey),
    'modes contains an unknown value',
  );
  final roles = r.strings('frameRoles', required: true);
  r.check(
    roles.every({'first_frame', 'last_frame', 'middle_frame'}.contains),
    'frameRoles contains an unknown frame role',
  );
  final middle = r.number(
    'maxMiddleFrames',
    required: true,
    integer: true,
    min: 0,
  )!;
  final maximum = r.number(
    'maxReferences',
    required: true,
    integer: true,
    min: 0,
  )!;
  for (final key in [
    'supportsAudioOnlyReference',
    'supportsAdaptiveTextRatio',
    'supportsLastFrameOnly',
    'framesRequireAdaptiveRatio',
    'supportsCertifiedAssets',
  ]) {
    r.boolean(key, required: true);
  }
  r.number('maxPromptCharacters', integer: true, min: 1);
  r.number('maxInputOutputDurationMs', integer: true, min: 1);
  final references = _object(r.value['references'], '${r.path}.references');
  for (final entry in references.entries) {
    r.check(
      VideoMediaKind.values.asNameMap().containsKey(entry.key),
      'references contains an unknown media kind',
    );
    final limits = _Reader(
      _object(entry.value, '${r.path}.references.${entry.key}'),
      '${r.path}.references.${entry.key}',
    );
    _limits(limits);
  }
  final durationLimits = r.value['maxDurationByResolution'];
  if (durationLimits != null) {
    for (final entry in _object(
      durationLimits,
      '${r.path}.maxDurationByResolution',
    ).entries) {
      r.check(
        resolutions.contains(entry.key) &&
            entry.value is int &&
            entry.value > 0 &&
            (durations as List).any(
              (duration) => (duration as int) <= entry.value,
            ),
        'maxDurationByResolution contains an invalid bound',
      );
    }
  }
  r.check(r.value.containsKey('draft'), 'draft must be declared (or null)');
  if (r.value['draft'] != null) {
    final draft = _Reader(
      _object(r.value['draft'], '${r.path}.draft'),
      '${r.path}.draft',
    );
    _text(draft.value['resolution'], '${draft.path}.resolution');
    _text(
      draft.value['completionResolution'],
      '${draft.path}.completionResolution',
    );
    draft.number('ttlHours', required: true, integer: true, min: 1);
  }
  final imageCount = references['image'] == null
      ? 0
      : (references['image'] as Map)['maxCount'] as int;
  bool fits(int count) => maximum >= count && imageCount >= count;
  if (modes.contains('first_frame')) {
    r.check(
      roles.contains('first_frame') && fits(1),
      'first_frame needs a first frame and image capacity',
    );
  }
  if (modes.contains('first_last_frame')) {
    r.check(
      (roles.contains('first_frame') &&
              roles.contains('last_frame') &&
              fits(2)) ||
          (r.value['supportsLastFrameOnly'] == true &&
              roles.contains('last_frame') &&
              fits(1)),
      'first_last_frame needs compatible roles and image capacity',
    );
  }
  if (middle > 0) {
    r.check(
      modes.contains('first_last_frame') &&
          roles.contains('first_frame') &&
          roles.contains('middle_frame') &&
          fits(middle.toInt() + 1),
      'maxMiddleFrames exceeds frame capacity',
    );
  }
  if (r.value['supportsLastFrameOnly'] == true) {
    r.check(
      modes.contains('first_last_frame') &&
          roles.contains('last_frame') &&
          fits(1),
      'supportsLastFrameOnly needs a last frame',
    );
  }
  if (modes.contains('reference')) {
    r.check(
      maximum >= 1 &&
          references.values.any((value) => (value as Map)['maxCount'] > 0),
      'reference mode needs media capacity',
    );
    if (r.value['supportsAudioOnlyReference'] == false) {
      r.check(
        ['image', 'video'].any(
          (kind) =>
              references[kind] != null &&
              (references[kind] as Map)['maxCount'] > 0,
        ),
        'reference mode has no non-audio input',
      );
    }
  }
  if (r.value['framesRequireAdaptiveRatio'] == true &&
      modes.any(
        (mode) => mode == 'first_frame' || mode == 'first_last_frame',
      )) {
    r.check(
      ratios.contains('adaptive'),
      'framesRequireAdaptiveRatio needs adaptive ratio',
    );
  }
  if (modes.length == 1 && modes.single == 'text') {
    r.check(
      roles.isEmpty &&
          middle == 0 &&
          maximum == 0 &&
          references.isEmpty &&
          r.value['supportsAudioOnlyReference'] == false &&
          r.value['supportsLastFrameOnly'] == false &&
          r.value['framesRequireAdaptiveRatio'] == false,
      'text-only model must not declare reference inputs',
    );
  }
  return VideoModelCapabilities.fromJson(r.known(keys));
}

void _limits(_Reader r) {
  r.unknown(const VideoReferenceLimits().toJson().keys.toSet());
  r.number('maxCount', required: true, integer: true, min: 0);
  r.strings('mimeTypes', nonempty: true);
  for (final field in [
    'minDimension',
    'maxDimension',
    'minDurationMs',
    'maxDurationMs',
    'minTotalDurationMs',
    'maxTotalDurationMs',
    'minPixels',
    'maxPixels',
  ]) {
    r.number(field, integer: true, min: 1);
  }
  for (final field in [
    'maxSizeMb',
    'maxTotalSizeMb',
    'minRatio',
    'maxRatio',
    'minFrameRate',
    'maxFrameRate',
  ]) {
    r.number(field, min: 0, exclusive: true);
  }
  r.boolean('exclusiveMaxSize');
  for (final pair in [
    ('minDimension', 'maxDimension'),
    ('minDurationMs', 'maxDurationMs'),
    ('minTotalDurationMs', 'maxTotalDurationMs'),
    ('minPixels', 'maxPixels'),
    ('minRatio', 'maxRatio'),
    ('minFrameRate', 'maxFrameRate'),
  ]) {
    r.bounds(pair.$1, pair.$2);
  }
}

Map<String, dynamic> _object(Object? value, String path) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$path must be an object with string keys');
  }
  return Map<String, dynamic>.from(value);
}

String _text(Object? value, String path) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$path must be non-empty text');
  }
  return value;
}

void _json(Object? value, String path, Set<Object> seen) {
  if (value == null ||
      value is String ||
      value is bool ||
      (value is num && value.isFinite)) {
    return;
  }
  if (value is! List &&
      (value is! Map || value.keys.any((key) => key is! String))) {
    throw FormatException('$path must contain JSON values');
  }
  if (!seen.add(value)) {
    throw FormatException('$path must not contain cycles');
  }
  for (final item in value is List ? value : (value as Map).values) {
    _json(item, path, seen);
  }
  seen.remove(value);
}

class _Reader {
  const _Reader(this.value, this.path);
  final Map<String, dynamic> value;
  final String path;
  void check(bool valid, String message) {
    if (!valid) {
      throw FormatException('$path: $message');
    }
  }

  num? number(
    String key, {
    bool required = false,
    bool integer = false,
    num min = 0,
    bool exclusive = false,
  }) {
    final item = value[key];
    if (item == null && !required) {
      return null;
    }
    check(
      item is num &&
          item.isFinite &&
          (!integer || item is int) &&
          (exclusive ? item > min : item >= min),
      '$key must be a valid ${integer ? 'integer' : 'number'}',
    );
    return item as num;
  }

  bool? boolean(String key, {bool required = false}) {
    final item = value[key];
    if (item == null && !required) {
      return null;
    }
    check(item is bool, '$key must be a boolean');
    return item as bool;
  }

  List<String> strings(
    String key, {
    bool required = false,
    bool nonempty = false,
  }) {
    final item = value[key];
    if (item == null && !required) {
      return const [];
    }
    check(
      item is List &&
          item.every((entry) => entry is String && entry.trim().isNotEmpty) &&
          item.toSet().length == item.length &&
          (!nonempty || item.isNotEmpty),
      '$key must be an array of unique strings',
    );
    return (item as List).cast<String>();
  }

  void bounds(String min, String max) {
    if (value[min] != null && value[max] != null) {
      check((value[min] as num) <= (value[max] as num), '$min exceeds $max');
    }
  }

  void unknown(Set<String> known) {
    for (final key in value.keys.where((key) => !known.contains(key))) {
      _log.warning('Ignoring unknown capability $path.$key');
    }
  }

  Map<String, dynamic> known(Set<String> keys) =>
      jsonDecode(
            jsonEncode({
              for (final entry in value.entries)
                if (keys.contains(entry.key)) entry.key: entry.value,
            }),
          )
          as Map<String, dynamic>;
}
