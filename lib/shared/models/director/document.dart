// 职责: 校验导演工程、归一化旋转并持有独立的版本化快照。
// 关联文件:
//   lib/shared/models/director/sampling.dart
//   lib/shared/models/director/presets.dart
//   lib/shared/services/director/commands.dart
import 'dart:convert';
import 'aspect_ratio.dart';
import 'pose.dart';
import 'properties.dart';
import 'path.dart';
import 'entities.dart';
import '../production/settings.dart';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import 'package:reveric/shared/models/director/presets.dart';

typedef Json = Map<String, dynamic>;
Json cloneJson(Json value) => jsonDecode(jsonEncode(value)) as Json;

class DocumentError implements Exception {
  final String path;
  final String reason;
  const DocumentError(this.path, this.reason);
  @override
  String toString() => '$path: $reason';
}

Never invalid(String path, String reason) => throw DocumentError(path, reason);

class DirectorDocument {
  static const requiredFields =
      'format version id revision title units up_axis fps duration_frames output objects cameras lighting tracks motion_paths camera_moves camera_cuts default_camera_id';
  static const maxBytes = 5 * 1024 * 1024;
  static const maxTracks = 128, maxPaths = 128, maxMoves = 256, maxUnits = 2048;
  static const maxActors = 6, maxProps = 20, maxCameras = 8;
  static const minFrames = 24, maxFrames = 720, frameRate = 24;
  final Json _value;
  final Object animationIdentity;
  DirectorDocument._(this._value, [Object? animationIdentity])
    : animationIdentity = animationIdentity ?? Object();
  factory DirectorDocument.parse(String text) {
    if (utf8.encode(text).length > DirectorDocument.maxBytes) {
      invalid(r'$', 'file_too_large');
    }
    final decoded = StrictJson(text).read();
    if (decoded is! Json) {
      invalid(r'$', 'expected_object');
    }
    return DirectorDocument.fromJson(decoded);
  }
  factory DirectorDocument.fromJson(Json value) {
    late String encoded;
    try {
      encoded = jsonEncode(value);
    } catch (_) {
      invalid(r'$', 'invalid_json_value');
    }
    if (utf8.encode(encoded).length > DirectorDocument.maxBytes) {
      invalid(r'$', 'file_too_large');
    }
    final copy = jsonDecode(encoded) as Json;
    // 校验同时归一化旋转，只修改副本；保存、插值和渲染共用规范化后的值。
    validateDocument(copy);
    return DirectorDocument._(copy);
  }
  Json toJson() => cloneJson(_value);
  String encode() => const JsonEncoder.withIndent('  ').convert(_value);
  String get id => _value['id'];
  int get revision => _value['revision'];
  String get title => _value['title'];
  int get durationFrames => _value['duration_frames'];
  int get fps => _value['fps'];
  int get width => _value['output']['width'];
  int get height => _value['output']['height'];
  DirectorAspectRatio get aspectRatio =>
      _value['output']['aspect_mode'] == 'auto'
      ? DirectorAspectRatio.adaptive
      : DirectorAspectRatio.values.singleWhere(
          (aspect) =>
              aspect != DirectorAspectRatio.adaptive &&
              (aspect.ratio - width / height).abs() < 0.003,
        );
  // 对象、相机、切镜只以 JSON 暴露；属性轨、运镜、路径在采样时读预解析的类型版，
  // 编辑一律改 JSON。
  List<Json> get objects =>
      (_value['objects'] as List).map((v) => cloneJson(v)).toList();
  late final List<MotionPath> samplingPaths = List.unmodifiable(
    (_value['motion_paths'] as List).map(
      (v) => MotionPath.fromJson(cloneJson(v)),
    ),
  );
  List<Json> get tracks =>
      (_value['tracks'] as List).map((v) => cloneJson(v)).toList();
  List<Json> get paths =>
      (_value['motion_paths'] as List).map((v) => cloneJson(v)).toList();
  List<Json> get cuts =>
      (_value['camera_cuts'] as List).map((v) => cloneJson(v)).toList();
  late final List<PropertyTrack> propertyTracks = List.unmodifiable(
    tracks.map(PropertyTrack.fromJson),
  );
  late final List<CameraMove> cameraMoves = List.unmodifiable(
    moves.map(CameraMove.fromJson),
  );
  String get defaultCameraId => _value['default_camera_id'];
  String cameraAt(num frame) {
    var result = defaultCameraId;
    for (final cut in _value['camera_cuts'] as List) {
      if (cut['frame'] > frame) {
        break;
      }
      result = cut['camera_id'];
    }
    return result;
  }

  List<Json> get moves =>
      (_value['camera_moves'] as List).map((v) => cloneJson(v)).toList();
  List<Json> get cameras =>
      (_value['cameras'] as List).map((v) => cloneJson(v)).toList();
  List<Json> get activeCameras => cameras;
  Json? camera(String? id) => cameras.where((c) => c['id'] == id).firstOrNull;
  bool isCamera(String? id) => cameras.any((c) => c['id'] == id);
  Json get lighting => cloneJson(_value['lighting']);
  String get background => _value['output']['background'];
  String get businessContent {
    final j = toJson()..remove('revision');
    return jsonEncode(j);
  }

  DirectorDocument mutate(void Function(Json) update) {
    final j = toJson();
    update(j);
    final next = DirectorDocument.fromJson(j);
    const animationFields = [
      'id',
      'fps',
      'duration_frames',
      'objects',
      'cameras',
      'tracks',
      'motion_paths',
      'camera_moves',
      'camera_cuts',
      'default_camera_id',
      'lighting',
    ];
    final unchanged = animationFields.every(
      (key) => jsonEncode(_value[key]) == jsonEncode(next._value[key]),
    );
    return unchanged
        ? DirectorDocument._(next._value, animationIdentity)
        : next;
  }

  static DirectorDocument blank(String title, {String camera = 'A'}) {
    final initialCamera = newCamera(camera, [0, 1.6, 5], [0, 1, 0], 35);
    return DirectorDocument.fromJson({
      'format': 'reveric.director',
      'version': 1,
      'id': const Uuid().v4(),
      'revision': 0,
      'title': title,
      'units': 'meters',
      'up_axis': 'Y',
      'fps': 24,
      'duration_frames': 120,
      'output': {
        'aspect_mode': 'auto',
        'width': 720,
        'height': 1280,
        'background': '#E8E8E8',
      },
      'objects': <Json>[],
      'cameras': [initialCamera],
      'lighting': {
        'ambient_intensity': 0.6,
        'key_intensity': 1,
        'key_direction': [-1, -2, -1],
      },
      'tracks': <Json>[],
      'motion_paths': <Json>[],
      'camera_cuts': <Json>[],
      'default_camera_id': initialCamera['id'],
      'camera_moves': <Json>[],
    });
  }

  static Json newCamera(String name, List position, List target, num focal) => {
    'id': const Uuid().v4(),
    'name': name,
    'position': position,
    'orientation_mode': 'look_at',
    'camera_target': {'type': 'point', 'position': target},
    'reference_up': [0, 1, 0],
    'roll': 0,
    'focal_length_mm': focal,
    'sensor_height_mm': 24,
    'near': 0.05,
    'far': 200,
  };
  DirectorDocument instantiate() {
    final j = toJson();
    final ids = <String, String>{};
    for (final old in [
      id,
      ...cameras.map((c) => c['id']),
      ...moves.map((m) => m['id']),
      ...objects.map((o) => o['id']),
      ...tracks.map((t) => t['id']),
      ...paths.map((c) => c['id']),
      ...cuts.map((c) => c['id']),
    ]) {
      ids[old] = const Uuid().v4();
    }
    j['id'] = ids[id];
    j['revision'] = 0;
    void target(Json? value) {
      if (value == null) {
        return;
      }
      for (final key in ['object_id', 'actor_id']) {
        if (value.containsKey(key)) {
          value[key] = ids[value[key]];
        }
      }
    }

    j['default_camera_id'] = ids[j['default_camera_id']];
    for (final c in j['cameras']) {
      c['id'] = ids[c['id']];
      target(c['camera_target']);
    }
    for (final m in j['camera_moves']) {
      m['id'] = ids[m['id']];
      m['camera_id'] = ids[m['camera_id']];
    }
    for (final o in j['objects']) {
      o['id'] = ids[o['id']];
    }
    for (final t in j['tracks']) {
      t['id'] = ids[t['id']];
      t['target_id'] = ids[t['target_id']];
      if (t['property'] == 'camera_target') {
        for (final k in t['keys']) {
          target(k['value']);
        }
      }
    }
    for (final c in j['motion_paths']) {
      c['id'] = ids[c['id']];
      c['target_id'] = ids[c['target_id']];
    }
    for (final c in j['camera_cuts']) {
      c['id'] = ids[c['id']];
      c['camera_id'] = ids[c['camera_id']];
    }
    return DirectorDocument.fromJson(j);
  }
}

void fields(dynamic v, String p, String names) {
  if (v is! Map<String, dynamic>) {
    invalid(p, 'expected_object');
  }
  final expected = names.split(' ').toSet();
  for (final k in expected) {
    if (!v.containsKey(k)) {
      invalid('$p.$k', 'missing_field');
    }
  }
}

num number(dynamic v, String p, num min, num max, {bool integer = false}) {
  if (v is! num ||
      !v.isFinite ||
      v < min ||
      v > max ||
      (integer && v is! int)) {
    invalid(p, 'out_of_range');
  }
  return v;
}

void choice(dynamic v, String p, List<dynamic> choices) {
  if (!choices.contains(v)) {
    invalid(p, 'unknown_value');
  }
}

void label(dynamic v, String p, int max) {
  if (v is! String || v.trim() != v || v.isEmpty || v.runes.length > max) {
    invalid(p, 'invalid_text');
  }
}

void vector(dynamic v, String p, num limit) {
  if (v is! List || v.length != 3) {
    invalid(p, 'expected_vector3');
  }
  for (var i = 0; i < 3; i++) {
    number(v[i], '$p[$i]', -limit, limit);
  }
}

/// 接受有限、非零的四元数，返回表示同一旋转的单位四元数。
/// AI / JSON 输入的小数舍入不应让整份文档失败：四个分量同除以长度，
/// 保留方向和符号。全零没有旋转方向，不能用单位旋转静默替代。
List<num> normalizeQuaternion(dynamic v, String p) {
  if (v is! List || v.length != 4) {
    invalid(p, 'expected_quaternion');
  }
  final values = [
    for (var i = 0; i < 4; i++)
      number(v[i], '$p[$i]', -double.maxFinite, double.maxFinite),
  ];
  final maxComponent = values.map((v) => v.abs().toDouble()).reduce(math.max);
  if (maxComponent == 0) {
    invalid(p, 'zero_quaternion');
  }
  // 先除以最大绝对分量，再求长度，避免极大 / 极小输入在平方时溢出或下溢。
  // (q / max) / |q / max| 等价于 q / |q|，无需直接计算可能溢出的 |q|。
  final scaled = values.map((v) => v / maxComponent).toList();
  final length = math.sqrt(scaled.fold<double>(0, (sum, v) => sum + v * v));
  // 已在双精度舍入误差内的单位值保持原样，防止反复读取造成快照漂移、假修改。
  if (maxComponent <= 1 && (maxComponent * length - 1).abs() <= 1e-15) {
    return values;
  }
  return scaled.map((v) => v / length).toList();
}

void exactFields(
  dynamic value,
  String path,
  String required, {
  String optional = '',
}) {
  fields(value, path, required);
  final allowed = {...required.split(' '), ...optional.split(' ')};
  for (final key in (value as Json).keys) {
    if (!allowed.contains(key)) {
      invalid('$path.$key', 'unknown_field');
    }
  }
}

void validateCamera(Json c, String p) {
  vector(c['position'], '$p.position', cameraPositionLimit);
  final focal = directorProperties['focal_length_mm']!;
  number(c['focal_length_mm'], '$p.focal_length_mm', focal.min!, focal.max!);
  for (final key in ['focus_distance_m', 'aperture_fstop']) {
    validatePropertyValue(key, c[key], '$p.$key');
  }
  for (final entry in cameraOpticsRanges.entries) {
    number(c[entry.key], '$p.${entry.key}', entry.value.$1, entry.value.$2);
  }
  if (c['far'] <= c['near']) {
    invalid(p, 'invalid_clip_planes');
  }
}

void validateDocument(Json d) {
  exactFields(d, r'$', DirectorDocument.requiredFields);
  final allIds = <String>{};
  void id(dynamic v, String p) {
    if (v is! String ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(v) ||
        !allIds.add(v.toLowerCase())) {
      invalid(p, 'invalid_or_duplicate_id');
    }
  }

  List list(dynamic v, String p, int max) {
    if (v is! List || v.length > max) {
      invalid(p, 'capacity_or_type');
    }
    return v;
  }

  void color(dynamic v, String p) {
    if (v is! String || !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(v)) {
      invalid(p, 'invalid_color');
    }
  }

  choice(d['format'], 'format', ['reveric.director']);
  choice(d['version'], 'version', [1]);
  if (d['version'] is! int) {
    invalid('version', 'expected_integer');
  }
  id(d['id'], 'id');
  number(d['revision'], 'revision', 0, 9007199254740991, integer: true);
  label(d['title'], 'title', 80);
  choice(d['units'], 'units', ['meters']);
  choice(d['up_axis'], 'up_axis', ['Y']);
  choice(d['fps'], 'fps', [DirectorDocument.frameRate]);
  if (d['fps'] is! int) {
    invalid('fps', 'expected_integer');
  }
  final duration = number(
    d['duration_frames'],
    'duration_frames',
    DirectorDocument.minFrames,
    DirectorDocument.maxFrames,
    integer: true,
  ).toInt();
  exactFields(
    d['output'],
    'output',
    'width height background',
    optional: 'aspect_mode',
  );
  final out = d['output'];
  if (out.containsKey('aspect_mode')) {
    choice(out['aspect_mode'], 'output.aspect_mode', ['auto']);
  }
  if (out['aspect_mode'] == 'auto') {
    for (final axis in ['width', 'height']) {
      final size = number(
        out[axis],
        'output.$axis',
        2,
        1920,
        integer: true,
      ).toInt();
      if (size.isOdd) {
        invalid('output.$axis', 'unsupported_size');
      }
    }
  } else if (out['width'] is! int ||
      out['height'] is! int ||
      !ProductionSettings.ratios.any(
        (ratio) => ProductionSettings.resolutions.any((resolution) {
          final size = ProductionSettings.dimensions(ratio, resolution);
          return size.$1 == out['width'] && size.$2 == out['height'];
        }),
      )) {
    invalid('output', 'unsupported_size');
  }
  color(out['background'], 'output.background');
  final cameras = <String, Json>{};
  for (final entry in list(
    d['cameras'],
    'cameras',
    DirectorDocument.maxCameras,
  ).indexed) {
    final p = 'cameras[${entry.$1}]', camera = entry.$2;
    fields(camera, p, 'orientation_mode');
    choice(
      camera['orientation_mode'],
      '$p.orientation_mode',
      sceneCameraRequiredFields.keys.toList(),
    );
    exactFields(
      camera,
      p,
      sceneCameraRequiredFields[camera['orientation_mode']]!,
      optional: sceneCameraOptionalFields,
    );
    // Optional optical settings preserve the pinhole rendering of older documents.
    if (!camera.containsKey('focus_distance_m')) {
      camera['focus_distance_m'] = 10.0;
    }
    if (!camera.containsKey('aperture_fstop')) {
      camera['aperture_fstop'] = 0.0;
    }
    id(camera['id'], '$p.id');
    label(camera['name'], '$p.name', 40);
    if (camera['orientation_mode'] == 'free') {
      camera['rotation'] = normalizeQuaternion(
        camera['rotation'],
        '$p.rotation',
      );
    } else {
      camera['reference_up'] = unitDirection(
        camera['reference_up'],
        '$p.reference_up',
      );
      validatePropertyValue('roll', camera['roll'], '$p.roll');
    }
    validateCamera(camera, p);
    cameras[camera['id']] = camera;
  }
  if (cameras.isEmpty) {
    invalid('cameras', 'camera_required');
  }
  exactFields(
    d['lighting'],
    'lighting',
    'ambient_intensity key_intensity key_direction',
  );
  final light = d['lighting'];
  for (final key in ['ambient_intensity', 'key_intensity']) {
    validatePropertyValue('lighting.$key', light[key], 'lighting.$key');
  }
  light['key_direction'] = unitDirection(
    light['key_direction'],
    'lighting.key_direction',
  );
  final objects = <String, Json>{};
  final catalogIds = <String>{};
  var actors = 0, props = 0;
  for (final entry in list(d['objects'], 'objects', 256).indexed) {
    final p = 'objects[${entry.$1}]', o = entry.$2;
    exactFields(
      o,
      p,
      sceneObjectRequiredFields,
      optional: sceneObjectOptionalFields,
    );
    id(o['id'], '$p.id');
    label(o['name'], '$p.name', 40);
    choice(o['kind'], '$p.kind', ['actor', 'prop']);

    final actor = o['kind'] == 'actor';
    // 手工对象可以不绑定目录；绑定后的身份独立于名称及实例 UUID。
    if (o['catalog_id'] != null) {
      label(o['catalog_id'], '$p.catalog_id', 256);
      if (!actor || !catalogIds.add(o['catalog_id'])) {
        invalid('$p.catalog_id', 'invalid_or_duplicate_actor');
      }
    }
    choice(
      o['geometry_key'],
      '$p.geometry_key',
      actor ? actorGeometries : propGeometries,
    );
    if (actor) {
      o['pose'] = ActorPose.fromJson(o['pose'], '$p.pose').toJson();
    } else {
      choice(o['pose'], '$p.pose', ['none']);
    }
    if (o['visible'] is! bool) {
      invalid('$p.visible', 'expected_boolean');
    }
    vector(o['position'], '$p.position', objectPositionLimit);
    o['rotation'] = normalizeQuaternion(o['rotation'], '$p.rotation');
    validatePropertyValue('scale', o['scale'], '$p.scale', object: o);
    color(o['color'], '$p.color');
    objects[o['id']] = o;
    if (actor) {
      actors++;
    } else {
      props++;
    }
  }
  if (actors > DirectorDocument.maxActors ||
      props > DirectorDocument.maxProps) {
    invalid('objects', 'capacity');
  }
  if (!cameras.containsKey(d['default_camera_id'])) {
    invalid('default_camera_id', 'camera_required');
  }
  for (final entry in cameras.values.indexed) {
    if (entry.$2['orientation_mode'] == 'look_at') {
      validateTarget(
        entry.$2['camera_target'],
        'cameras[${entry.$1}].camera_target',
        objects,
      );
    }
  }
  final activeProperties = <String>{};
  var keys = 0;
  for (final entry in list(
    d['tracks'],
    'tracks',
    DirectorDocument.maxTracks,
  ).indexed) {
    final p = 'tracks[${entry.$1}]', t = entry.$2;
    exactFields(t, p, PropertyTrack.requiredFields);
    id(t['id'], '$p.id');

    final camera = cameras[t['target_id']], isCamera = camera != null;
    final target = objects[t['target_id']];
    final lighting = t['target_id'] == d['id'];
    if (!isCamera && target == null && !lighting) {
      invalid('$p.target_id', 'missing_target');
    }
    choice(
      t['property'],
      '$p.property',
      propertiesFor(object: target, camera: camera, lighting: lighting),
    );
    if (!activeProperties.add('${t['target_id']}/${t['property']}')) {
      invalid(p, 'duplicate_active_track');
    }
    final trackKeys = list(t['keys'], '$p.keys', DirectorDocument.maxUnits);
    if (trackKeys.isEmpty) {
      invalid('$p.keys', 'key_required');
    }
    var previous = -1;
    for (final e in trackKeys.indexed) {
      final k = e.$2, kp = '$p.keys[${e.$1}]';
      exactFields(k, kp, PropertyKey.requiredFields);
      final f = number(
        k['frame'],
        '$kp.frame',
        0,
        duration,
        integer: true,
      ).toInt();
      if (f <= previous) {
        invalid('$kp.frame', 'key_order');
      }
      previous = f;
      choice(k['easing'], '$kp.easing', ['linear', 'smoothstep', 'hold']);
      k['value'] = validatePropertyValue(
        t['property'],
        k['value'],
        '$kp.value',
        object: target,
        camera: camera,
        objects: objects,
      );
      if (t['property'] == 'visible' && k['easing'] != 'hold') {
        invalid('$kp.easing', 'hold_required');
      }
      if (t['property'] == 'lighting.key_direction' && e.$1 > 0) {
        final prior = trackKeys[e.$1 - 1];
        final dot = List.generate(
          3,
          (i) => (prior['value'][i] as num) * (k['value'][i] as num),
        ).reduce((a, b) => a + b);
        if (prior['easing'] != 'hold' && dot <= -0.999999) {
          invalid(p, 'opposite_directions:${prior['frame']}-$f');
        }
      }
    }
    keys += trackKeys.length;
  }
  final controls = <String, List<Json>>{};
  void control(
    String target,
    Set<String> properties,
    Json segment,
    String path,
  ) {
    for (final property in properties) {
      final start = segment['start_frame'] as int,
          end = segment['end_frame'] as int;
      final intervals = controls.putIfAbsent('$target/$property', () => []);
      if (intervals.any(
        (s) => start < s['end_frame'] && end > s['start_frame'],
      )) {
        invalid(path, 'overlapping_control:$property');
      }
      intervals.add(segment);
      for (final track in (d['tracks'] as List).where(
        (t) => t['target_id'] == target && t['property'] == property,
      )) {
        final ks = track['keys'] as List;
        for (var i = 0; i < ks.length; i++) {
          final f = ks[i]['frame'] as int;
          if (f > start && f < end) {
            invalid(path, 'controlled_key:$property:$f');
          }
          if (i + 1 < ks.length &&
              f < end &&
              ks[i + 1]['frame'] > start &&
              ks[i]['easing'] != 'hold') {
            invalid(path, 'controlled_interpolation:$property');
          }
        }
      }
    }
  }

  void interval(Json segment, String path) {
    number(
      segment['start_frame'],
      '$path.start_frame',
      0,
      duration,
      integer: true,
    );
    number(segment['end_frame'], '$path.end_frame', 0, duration, integer: true);
    if (segment['start_frame'] >= segment['end_frame']) {
      invalid(path, 'empty_interval');
    }
  }

  for (final entry in list(
    d['motion_paths'],
    'motion_paths',
    DirectorDocument.maxPaths,
  ).indexed) {
    final p = 'motion_paths[${entry.$1}]', raw = entry.$2 as Json;
    id(raw['id'], '$p.id');
    interval(raw, p);
    if (objects[raw['target_id']]?['kind'] != 'actor') {
      invalid('$p.target_id', 'actor_required');
    }
    final path = MotionPath.fromJson(raw, p);
    keys += path.units;
    control(path.targetId, {'position', if (path.orient) 'rotation'}, raw, p);
  }
  final activeMoves = <String, List<Json>>{};
  for (final entry in list(
    d['camera_moves'],
    'camera_moves',
    DirectorDocument.maxMoves,
  ).indexed) {
    final p = 'camera_moves[${entry.$1}]', m = entry.$2;
    exactFields(m, p, CameraMove.requiredFields);
    id(m['id'], '$p.id');

    choice(m['kind'], '$p.kind', moveKinds);
    final camera = cameras[m['camera_id']];
    if (camera == null) {
      invalid('$p.camera_id', 'camera_required');
    }
    interval(m, p);
    final start = m['start_frame'] as int, end = m['end_frame'] as int;
    if (movePreset(m['kind']).subject &&
        (camera['orientation_mode'] != 'look_at' ||
            camera['camera_target']['type'] == 'point')) {
      invalid(p, 'subject_target_required');
    }
    control(
      m['camera_id'],
      moveChannels(m['kind'], camera['orientation_mode']),
      m,
      p,
    );
    final previous = activeMoves.putIfAbsent(m['camera_id'], () => []);
    if (previous.any((o) => start < o['end_frame'] && end > o['start_frame'])) {
      invalid(p, 'overlapping_move');
    }
    previous.add(m);
  }
  var previousCut = -1;
  for (final entry in list(
    d['camera_cuts'],
    'camera_cuts',
    DirectorDocument.maxUnits,
  ).indexed) {
    final p = 'camera_cuts[${entry.$1}]', cut = entry.$2;
    exactFields(cut, p, cameraCutRequiredFields);
    id(cut['id'], '$p.id');
    final frame = number(
      cut['frame'],
      '$p.frame',
      0,
      duration,
      integer: true,
    ).toInt();
    if (frame <= previousCut) {
      invalid('$p.frame', 'key_order');
    }
    previousCut = frame;
    if (!cameras.containsKey(cut['camera_id'])) {
      invalid('$p.camera_id', 'camera_required');
    }
    keys++;
  }
  if (keys > DirectorDocument.maxUnits) {
    invalid('animation', 'key_capacity');
  }
}

// The standard decoder overwrites duplicate keys. Parse containers explicitly
// so even nested duplicates fail before a document can replace valid state.
class StrictJson {
  final String source;
  int index = 0;
  StrictJson(this.source);
  void space() {
    while (index < source.length && ' \r\n\t'.contains(source[index])) {
      index++;
    }
  }

  dynamic read() {
    final value = parse(r'$');
    space();
    if (index != source.length) {
      invalid(r'$', 'trailing_data');
    }
    return value;
  }

  String string(String p) {
    final start = index++;
    var escaped = false;
    while (index < source.length) {
      final c = source[index++];
      if (c == '"' && !escaped) {
        try {
          return jsonDecode(source.substring(start, index));
        } catch (_) {
          invalid(p, 'invalid_string');
        }
      }
      if (c == '\\' && !escaped) {
        escaped = true;
      } else {
        escaped = false;
      }
    }
    invalid(p, 'unterminated_string');
  }

  dynamic parse(String p) {
    if (p.length > 2048) {
      invalid(p, 'nesting_limit');
    }
    space();
    if (index >= source.length) {
      invalid(p, 'unexpected_end');
    }
    final c = source[index];
    if (c == '"') {
      return string(p);
    }
    if (c == '{' || c == '[') {
      index++;
      final object = c == '{', end = object ? '}' : ']';
      final map = <String, dynamic>{}, values = <dynamic>[];
      space();
      if (index < source.length && source[index] == end) {
        index++;
        return object ? map : values;
      }
      while (true) {
        space();
        if (object) {
          if (index >= source.length || source[index] != '"') {
            invalid(p, 'expected_key');
          }
          final key = string(p);
          if (map.containsKey(key)) {
            invalid('$p.$key', 'duplicate_key');
          }
          space();
          if (index >= source.length || source[index++] != ':') {
            invalid(p, 'expected_colon');
          }
          map[key] = parse('$p.$key');
        } else {
          values.add(parse('$p[${values.length}]'));
        }
        space();
        if (index >= source.length) {
          invalid(p, 'unexpected_end');
        }
        final next = source[index++];
        if (next == end) {
          return object ? map : values;
        }
        if (next != ',') {
          invalid(p, 'expected_comma');
        }
      }
    }
    final start = index;
    while (index < source.length && !' \r\n\t,]}'.contains(source[index])) {
      index++;
    }
    try {
      return jsonDecode(source.substring(start, index));
    } catch (_) {
      invalid(p, 'invalid_literal');
    }
  }
}
