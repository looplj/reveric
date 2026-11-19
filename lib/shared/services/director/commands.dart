// 职责: 执行可撤销工程命令并隔离临时手势与已提交内容。
// 关联文件:
//   lib/shared/models/director/document.dart
//   lib/shared/models/director/actor_catalog.dart
//   lib/shared/models/director/sampling.dart
//   lib/shared/models/director/presets.dart
import 'dart:convert';
import 'dart:math' as math;
import 'bake.dart';
import 'control_edit.dart';
import '../../models/director/pose.dart';
import '../../models/director/properties.dart';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:reveric/shared/models/director/document.dart';
import 'package:reveric/shared/models/director/aspect_ratio.dart';
import 'package:reveric/shared/models/director/actor_catalog.dart';
import 'package:reveric/shared/models/director/presets.dart';
import 'package:reveric/shared/models/director/sampling.dart';

class CommandHistory extends ChangeNotifier {
  DirectorDocument document;
  final bool readOnly;
  String _saved;
  final List<DirectorDocument> _undo = [], _redo = [];
  DirectorDocument? preview;
  (int, int)? _viewportOutputSize;
  int gestureGeneration = 0;
  void Function()? beforeEdit;

  /// Interactive sessions validate the current frame before publishing edits.
  void Function(DirectorDocument)? validateEdit;
  CommandHistory(this.document, {this.readOnly = false})
    : _saved = document.businessContent;
  bool get dirty => !readOnly && document.businessContent != _saved;
  bool get canUndo => !readOnly && _undo.isNotEmpty;
  bool get canRedo => !readOnly && _redo.isNotEmpty;
  int get undoCount => _undo.length;
  DirectorDocument get visible => preview ?? document;
  void markSaved(DirectorDocument saved) {
    _saved = saved.businessContent;
    notifyListeners();
  }

  void replace(DirectorDocument value, {bool saved = true}) {
    document = value;
    _resizeAdaptiveDocument();
    gestureGeneration++;
    preview = null;
    _undo.clear();
    _redo.clear();
    if (saved) {
      _saved = value.businessContent;
    }
    notifyListeners();
  }

  /// 同步已保存内容；外部编辑作为完整的一步撤销，不受输入草稿阻塞。
  void synchronize(DirectorDocument value, {bool external = false}) {
    if (external) {
      if (document.businessContent != value.businessContent) {
        _undo.add(document);
        _trimUndo();
        _redo.clear();
      }
      gestureGeneration++;
      preview = null;
    }
    document = value;
    _saved = value.businessContent;
    notifyListeners();
  }

  void execute(void Function(Json) edit, {bool validate = true}) {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    beforeEdit?.call();
    final next = document.mutate((j) {
      edit(j);
      _applyViewportSize(j);
      j['revision'] = document.revision + 1;
    });
    if (validate) {
      validateEdit?.call(next);
    }
    if (next.businessContent == document.businessContent) {
      preview = null;
      notifyListeners();
      return;
    }
    _undo.add(document);
    gestureGeneration++;
    _redo.clear();
    document = next;
    preview = null;
    _trimUndo();
    notifyListeners();
  }

  void _trimUndo() {
    while (_undo.length > 1 &&
        (_undo.length > 100 ||
            _undo.fold<int>(0, (n, d) => n + utf8.encode(d.encode()).length) >
                20 * 1024 * 1024)) {
      _undo.removeAt(0);
    }
  }

  void undo() {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    beforeEdit?.call();
    if (!canUndo) {
      return;
    }
    _redo.add(document);
    gestureGeneration++;
    document = _undo.removeLast().mutate((j) {
      j['revision'] = document.revision + 1;
      _applyViewportSize(j);
    });
    preview = null;
    notifyListeners();
  }

  void setAspectRatio(DirectorAspectRatio aspect) => execute((j) {
    if (aspect == DirectorAspectRatio.adaptive) {
      j['output']['aspect_mode'] = 'auto';
    } else {
      (j['output'] as Map).remove('aspect_mode');
      j['output']['width'] = aspect.width;
      j['output']['height'] = aspect.height;
    }
  });

  /// 视口缩放更新输出快照，但不占用撤销栈或中断当前播放与字段编辑。
  /// 只读预览保持文档里已保存的输出尺寸，不跟当前窗口重算画幅。
  void updateViewportSize(double width, double height) {
    if (readOnly) {
      return;
    }
    _viewportOutputSize = adaptiveOutputSize(width, height);
    if (_resizeAdaptiveDocument()) {
      notifyListeners();
    }
  }

  void _applyViewportSize(Json json) {
    final size = _viewportOutputSize;
    if (size != null && json['output']['aspect_mode'] == 'auto') {
      json['output']['width'] = size.$1;
      json['output']['height'] = size.$2;
    }
  }

  bool _resizeAdaptiveDocument() {
    if (readOnly) {
      return false;
    }
    final size = _viewportOutputSize;
    if (size == null ||
        document.aspectRatio != DirectorAspectRatio.adaptive ||
        (document.width == size.$1 && document.height == size.$2)) {
      return false;
    }
    document = document.mutate((j) {
      _applyViewportSize(j);
      j['revision'] = document.revision + 1;
    });
    // A live transform preview must keep the same output geometry.
    preview = preview?.mutate(_applyViewportSize);
    return true;
  }

  void redo() {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    beforeEdit?.call();
    if (!canRedo) {
      return;
    }
    _undo.add(document);
    gestureGeneration++;
    document = _redo.removeLast().mutate((j) {
      j['revision'] = document.revision + 1;
      _applyViewportSize(j);
    });
    preview = null;
    notifyListeners();
  }

  void previewEdit(void Function(Json) edit) {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    final next = document.mutate(edit);
    validateEdit?.call(next);
    preview = next;
    notifyListeners();
  }

  void cancelGesture() {
    gestureGeneration++;
    preview = null;
    notifyListeners();
  }

  void commitGesture() {
    final next = preview;
    if (next != null) {
      execute((j) {
        j.clear();
        j.addAll(next.toJson());
      });
    }
  }

  /// 每个目录角色在工程中只有一个实例；再次选择复用现有身份，删除后添加新实例。
  String addActor(DirectorActor actor) {
    final existing = document.objects
        .where((o) => o['catalog_id'] == actor.id)
        .firstOrNull;
    if (existing != null) {
      return existing['id'];
    }
    addObject(actor.body.geometryKey, actor.name, catalogId: actor.id);
    return document.objects.last['id'];
  }

  void addObject(String geometry, String name, {String? catalogId}) {
    execute((j) {
      final actor = actorGeometries.contains(geometry);
      final prop = propPresets.where((p) => p.geometry == geometry).firstOrNull;
      (j['objects'] as List).add({
        'id': const Uuid().v4(),
        'kind': actor ? 'actor' : 'prop',
        'name': name,
        'catalog_id': ?catalogId,
        'geometry_key': geometry,
        'position': prop?.defaultPosition ?? [0, 0, 0],
        'rotation': [0, 0, 0, 1],
        'scale': [1, 1, 1],
        'color': actor
            ? '#4477AA'
            : propModelAssets.containsKey(geometry)
            ? '#FFFFFF'
            : '#999999',
        'pose': actor ? ActorPose.standing().toJson() : 'none',
        'visible': true,
      });
    });
  }

  void remove(String id) => execute((json) => removeObject(json, id));

  /// 删除对象及其专属控制；外部目标、默认机位和切镜引用必须在同批显式处理。
  static void removeObject(Json json, String id) {
    (json['objects'] as List).removeWhere((o) => o['id'] == id);
    (json['cameras'] as List).removeWhere((c) => c['id'] == id);
    (json['tracks'] as List).removeWhere((t) => t['target_id'] == id);
    (json['motion_paths'] as List).removeWhere((c) => c['target_id'] == id);
    (json['camera_moves'] as List).removeWhere((m) => m['camera_id'] == id);
  }

  void setValue(String id, String property, dynamic value, int frame) =>
      editProperty(id, property, value, frame);

  static Json _owner(Json j, String id) => id == j['id']
      ? j['lighting'] as Json
      : [...j['objects'], ...j['cameras']].firstWhere((o) => o['id'] == id)
            as Json;
  static String _field(String property) =>
      property.startsWith('lighting.') ? property.substring(9) : property;
  static Json? _track(Json j, String id, String property) =>
      (j['tracks'] as List)
              .where((t) => t['target_id'] == id && t['property'] == property)
              .firstOrNull
          as Json?;

  static void _writeKey(
    Json track,
    int frame,
    dynamic value, {
    String? easing,
  }) {
    final keys = track['keys'] as List;
    final old = keys.where((k) => k['frame'] == frame).firstOrNull;
    keys.removeWhere((k) => k['frame'] == frame);
    keys.add({
      'frame': frame,
      'value': value,
      'easing':
          easing ??
          old?['easing'] ??
          (track['property'] == 'visible' ? 'hold' : 'linear'),
    });
    keys.sort((a, b) => (a['frame'] as int).compareTo(b['frame']));
  }

  /// UI 自动帧和 AI 都按目标、属性、帧查建同一条轨道。
  static String upsertKeyIn(
    Json json,
    String id,
    String property,
    int frame,
    dynamic value, {
    String? easing,
  }) {
    var track = _track(json, id, property);
    if (track == null) {
      track = {
        'id': const Uuid().v4(),
        'target_id': id,
        'property': property,
        'keys': <Json>[],
      };
      (json['tracks'] as List).add(track);
    }
    _writeKey(track, frame, value, easing: easing);
    return track['id'];
  }

  void upsertKey(
    String id,
    String property,
    int frame,
    dynamic value, {
    String? easing,
  }) {
    if (controlled(id, property, frame)) {
      invalid(property, 'controlled_channel');
    }
    execute((j) => upsertKeyIn(j, id, property, frame, value, easing: easing));
  }

  void removeKey(String id, String property, int frame) => execute((j) {
    final track = _track(j, id, property);
    final keys = track?['keys'] as List?;
    if (keys == null || !keys.any((k) => k['frame'] == frame)) {
      invalid('frame', 'not_found');
    }
    keys.removeWhere((k) => k['frame'] == frame);
    if (keys.isEmpty) {
      (j['tracks'] as List).remove(track);
    }
  });

  /// 逐项关键帧开关：当前帧没有关键帧就按采样值补一帧（没有轨道时新建），
  /// 有就删掉。
  void toggleKey(String id, String property, int frame) {
    if (controlled(id, property, frame)) {
      invalid(property, 'controlled_channel');
    }
    final sample = sampleDocument(document, frame);
    final owner = id == document.id
        ? sample.lighting
        : sample.cameras[id] ?? sample.objects.firstWhere((o) => o['id'] == id);
    final value = property == 'camera_target'
        ? cameraTargetValue(id, frame)
        : owner[_field(property)];
    execute((j) {
      var track = _track(j, id, property);
      final keys = track?['keys'] as List?;
      if (keys != null && keys.any((k) => k['frame'] == frame)) {
        keys.removeWhere((k) => k['frame'] == frame);
        if (keys.isEmpty) {
          (j['tracks'] as List).remove(track);
        }
        return;
      }
      upsertKeyIn(j, id, property, frame, value);
    });
  }

  /// 保留基础、精确键及 hold 段的动态引用；混合目标或运镜结果才记录世界点。
  Json cameraTargetValue(String id, int frame, {bool resolve = true}) {
    final track = _track(document.toJson(), id, 'camera_target');
    final keys = (track?['keys'] as List? ?? const []);
    final before = keys.where((k) => k['frame'] <= frame).lastOrNull;
    final after = keys.where((k) => k['frame'] > frame).firstOrNull;
    if (!resolve) {
      return cloneJson(
        before?['value'] ?? document.camera(id)!['camera_target'],
      );
    }
    final moves = document.moves.where(
      (m) =>
          m['camera_id'] == id &&
          m['start_frame'] <= frame &&
          moveChannels(m['kind'], 'look_at').contains('camera_target'),
    );
    final controlledUntil = moves.fold<int>(
      -1,
      (end, m) => math.max(end, m['end_frame'] as int),
    );
    if (controlledUntil < 0 ||
        before != null && before['frame'] >= controlledUntil) {
      if (before == null) {
        return cloneJson(document.camera(id)!['camera_target']);
      }
      if (before['frame'] == frame ||
          after == null ||
          before['easing'] == 'hold' ||
          jsonEncode(before['value']) == jsonEncode(after['value'])) {
        return cloneJson(before['value']);
      }
    }
    return {
      'type': 'point',
      'position': sampleDocument(document, frame).cameras[id]!['target'],
    };
  }

  void setKeyEasing(String id, String property, int frame, String easing) =>
      execute((j) {
        final key = (_track(j, id, property)?['keys'] as List?)
            ?.where((k) => k['frame'] == frame)
            .firstOrNull;
        if (key == null) {
          invalid(property, 'add_key_first');
        }
        key['easing'] = easing;
      });

  void move(
    String cameraId,
    String kind,
    int start,
    int end, {
    bool replace = false,
  }) => upsertMove(newMove(cameraId, kind, start, end), replace: replace);

  void upsertMove(Json move, {bool replace = false}) {
    final next = upsertControl(
      document,
      'camera_moves',
      move,
      replace: replace,
    );
    execute((j) {
      j.clear();
      j.addAll(next);
    });
  }

  /// 按预设在主体（无主体时为原点）周围新建机位，返回新机位 id。
  String addCamera(String name, String preset, String? subjectId, int frame) {
    final subject = sampleDocument(
      document,
      frame,
    ).objects.where((o) => o['id'] == subjectId).firstOrNull;
    final p = subject == null ? [0, 0, 0] : subject['position'] as List;
    final pose = cameraPresetPose(
      preset,
      (p[0] as num).toDouble(),
      (p[2] as num).toDouble(),
      subject == null ? 0 : quaternionYaw(subject['rotation']),
    );
    final camera = DirectorDocument.newCamera(
      name,
      [pose.position[0], pose.position[1] + p[1], pose.position[2]],
      subject == null
          ? pose.target
          : objectWorldPoint(subject, [0, pose.target[1], 0]),
      pose.focal,
    );
    if (subjectId != null) {
      camera['camera_target'] = {
        'type': 'bone',
        'actor_id': subjectId,
        'bone': preset.contains('close') ? 'head' : 'chest',
        'offset': [0, 0, 0],
      };
    }
    if (preset == 'dutch') {
      camera['roll'] = 15;
    }
    execute((j) => (j['cameras'] as List).add(camera));
    return camera['id'];
  }

  /// 视口对齐机位遵循与检查器相同的自动帧和受控通道规则。
  void placeCamera(String id, List position, List target, int frame) {
    final camera = document.camera(id)!;
    final current = sampleCamera(document, id, frame);
    execute((j) {
      editPropertyIn(j, id, 'position', position, frame);
      if (camera['orientation_mode'] == 'free') {
        editPropertyIn(
          j,
          id,
          'rotation',
          lookQuaternion([
            for (var i = 0; i < 3; i++) target[i] - position[i],
          ], current['up']),
          frame,
        );
      } else {
        editPropertyIn(j, id, 'camera_target', {
          'type': 'point',
          'position': target,
        }, frame);
      }
    });
  }

  /// 模式不是动画属性；已有方向控制必须先由用户处理。
  void setCameraMode(String id, String mode, int frame) {
    choice(mode, 'orientation_mode', ['free', 'look_at']);
    final camera = document.camera(id)!;
    if (camera['orientation_mode'] == mode) {
      return;
    }
    const orientation = {'rotation', 'camera_target', 'roll'};
    if (document.tracks.any(
          (t) => t['target_id'] == id && orientation.contains(t['property']),
        ) ||
        document.moves.any(
          (m) =>
              m['camera_id'] == id &&
              moveChannels(
                m['kind'],
                camera['orientation_mode'],
              ).any(orientation.contains),
        )) {
      invalid('orientation_mode', 'orientation_controls_require_removal');
    }
    final sampled = sampleCamera(document, id, frame);
    final next = document.toJson();
    final edited = _owner(next, id);
    edited['orientation_mode'] = mode;
    if (mode == 'free') {
      edited.remove('camera_target');
      edited.remove('reference_up');
      edited.remove('roll');
      edited['rotation'] = sampled['rotation'];
    } else {
      edited.remove('rotation');
      edited['camera_target'] = {
        'type': 'point',
        'position': sampled['target'],
      };
      final startPosition = sampleCamera(document, id, 0)['position'] as List;
      final forward = unitDirection([
        for (var i = 0; i < 3; i++) sampled['target'][i] - startPosition[i],
      ], 'camera.forward');
      final desiredUp = (sampled['up'] as List).cast<num>();
      final dot = List.generate(
        3,
        (i) => forward[i] * desiredUp[i],
      ).reduce((a, b) => a + b);
      edited['reference_up'] = dot.abs() > .999999
          ? rotateVector(sampled['rotation'], [1, 0, 0])
          : sampled['up'];
      edited['roll'] = 0;
      final candidate = sampleCamera(
        DirectorDocument.fromJson(next),
        id,
        frame,
      );
      final up = candidate['up'] as List;
      final direction = rotateVector(sampled['rotation'], [0, 0, -1]);
      final cross = [
        up[1] * desiredUp[2] - up[2] * desiredUp[1],
        up[2] * desiredUp[0] - up[0] * desiredUp[2],
        up[0] * desiredUp[1] - up[1] * desiredUp[0],
      ];
      final sine = List.generate(
        3,
        (i) => cross[i] * direction[i],
      ).reduce((a, b) => a + b);
      final cosine = List.generate(
        3,
        (i) => up[i] * desiredUp[i],
      ).reduce((a, b) => a + b);
      edited['roll'] = math.atan2(sine, cosine) * 180 / math.pi;
    }
    final result = DirectorDocument.fromJson(next);
    if (quaternionAngle(
          sampleCamera(result, id, frame)['rotation'],
          sampled['rotation'],
        ) >
        bakeAngleTolerance) {
      invalid('orientation_mode', 'framing_changed');
    }
    execute((j) {
      j.clear();
      j.addAll(result.toJson());
    });
  }

  void setLookAt(String cameraId, String? actorId) {
    final current = sampleCamera(document, cameraId, 0);
    execute(
      (j) => _owner(j, cameraId)['camera_target'] = actorId == null
          ? {'type': 'point', 'position': current['target']}
          : {
              'type': 'bone',
              'actor_id': actorId,
              'bone': 'chest',
              'offset': [0, 0, 0],
            },
    );
  }

  void intervalKeys(
    String id,
    String property,
    int start,
    int end,
    dynamic finish, {
    String easing = 'smoothstep',
  }) {
    if (start < 0 || start >= end || end > document.durationFrames) {
      invalid('interval', 'invalid_interval');
    }
    final sample = sampleDocument(document, start);
    final target =
        sample.cameras[id] ?? sample.objects.firstWhere((o) => o['id'] == id);
    final begin = property == 'camera_target'
        ? {'type': 'point', 'position': target['target']}
        : target[_field(property)];
    execute((j) {
      final old = _track(j, id, property);
      if (old != null) {
        (old['keys'] as List).removeWhere(
          (k) => k['frame'] >= start && k['frame'] <= end,
        );
      }
      upsertKeyIn(j, id, property, start, begin, easing: easing);
      upsertKeyIn(j, id, property, end, finish);
    });
  }

  void facePath(String id) {
    final path = document.tracks
        .where((t) => t['target_id'] == id && t['property'] == 'position')
        .firstOrNull;
    if (path == null) {
      invalid('position', 'path_required');
    }
    final keys = path['keys'] as List;
    final headings = <dynamic>[];
    final baseRotation =
        document.objects.firstWhere((o) => o['id'] == id)['rotation'] as List;
    final rotationTrack = document.tracks
        .where((t) => t['target_id'] == id && t['property'] == 'rotation')
        .firstOrNull;
    var heading = quaternionYaw(baseRotation);
    for (var i = 0; i < keys.length; i++) {
      for (var k = i; k < keys.length - 1; k++) {
        final a = keys[k]['value'], b = keys[k + 1]['value'];
        final dx = b[0] - a[0], dz = b[2] - a[2];
        if (dx * dx + dz * dz > 1e-12) {
          heading = math.atan2(dx, dz);
          break;
        }
      }
      final rotation = rotationTrack == null
          ? baseRotation
          : sampleTrack(rotationTrack, keys[i]['frame']) as List;
      headings.add({
        'frame': keys[i]['frame'],
        'value': rotateQuaternionYaw(
          rotation,
          heading - quaternionYaw(rotation),
        ),
        'easing': 'hold',
      });
    }
    execute((j) {
      (j['tracks'] as List).removeWhere(
        (t) => t['target_id'] == id && t['property'] == 'rotation',
      );
      (j['tracks'] as List).add({
        'id': const Uuid().v4(),
        'target_id': id,
        'property': 'rotation',
        'keys': headings,
      });
    });
  }

  bool timelineVisible = true;
  bool autoKey = false;

  Iterable<Json> _controlsFor(String id, String property) sync* {
    yield* document.paths.where(
      (p) =>
          p['target_id'] == id &&
          (property == 'position' ||
              property == 'rotation' && p['orient_to_path'] == true),
    );
    final camera = document.camera(id);
    if (camera != null) {
      yield* document.moves.where(
        (m) =>
            m['camera_id'] == id &&
            moveChannels(
              m['kind'],
              camera['orientation_mode'],
            ).contains(property),
      );
    }
  }

  static bool _activeAt(Json control, int frame) =>
      frame >= control['start_frame'] && frame < control['end_frame'];

  bool controlled(String id, String property, int frame) =>
      _controlsFor(id, property).any((c) => _activeAt(c, frame));

  String? editBlock(String id, String property, int frame) {
    final controls = _controlsFor(id, property).toList();
    if (controls.any((c) => _activeAt(c, frame))) {
      return 'controlled_channel';
    }
    final track = _track(document.toJson(), id, property);
    final animated = track != null || controls.isNotEmpty;
    final heldControl = controls.any((c) => c['end_frame'] <= frame);
    if (timelineVisible && !autoKey && track == null && heldControl) {
      return 'add_key_first';
    }
    if (!timelineVisible && animated) {
      return 'open_timeline';
    }
    if (timelineVisible &&
        !autoKey &&
        track != null &&
        !(track['keys'] as List).any((k) => k['frame'] == frame)) {
      return 'add_key_first';
    }
    return null;
  }

  void editProperty(String id, String property, dynamic value, int frame) =>
      execute((j) => editPropertyIn(j, id, property, value, frame));
  void previewProperty(String id, String property, dynamic value, int frame) =>
      previewEdit((j) => editPropertyIn(j, id, property, value, frame));
  void editPropertyIn(
    Json j,
    String id,
    String property,
    dynamic value,
    int frame,
  ) {
    final blocked = editBlock(id, property, frame);
    if (blocked != null) {
      invalid(property, blocked);
    }
    var track = _track(j, id, property);
    if (timelineVisible && autoKey) {
      upsertKeyIn(j, id, property, frame, value);
    } else if (track == null) {
      _owner(j, id)[_field(property)] = value;
    } else {
      _writeKey(track, frame, value);
    }
  }

  void applyPose(String id, String preset, int frame) {
    final actor = document.objects.firstWhere((o) => o['id'] == id);
    editProperty(
      id,
      'pose',
      posePreset(preset, actor['geometry_key']).toJson(),
      frame,
    );
  }

  void bake(String collection, String id) {
    final baked = bakeControl(document, collection, id);
    execute((j) {
      j.clear();
      j.addAll(baked);
    });
  }

  void upsertPath(Json path, {bool replace = false}) {
    final next = upsertControl(
      document,
      'motion_paths',
      path,
      replace: replace,
    );
    execute((j) {
      j.clear();
      j.addAll(next);
    });
  }

  void previewControl(String collection, Json control) {
    final next = upsertControl(document, collection, control);
    previewEdit((j) {
      j.clear();
      j.addAll(next);
    });
  }

  void removePath(String id) => execute(
    (j) => (j['motion_paths'] as List).removeWhere((p) => p['id'] == id),
  );
  void setCut(int frame, String cameraId) => execute((j) {
    final cuts = j['camera_cuts'] as List;
    final prior = cuts.where((c) => c['frame'] == frame).firstOrNull;
    cuts.removeWhere((c) => c['frame'] == frame);
    cuts.add({
      'id': prior?['id'] ?? const Uuid().v4(),
      'frame': frame,
      'camera_id': cameraId,
    });
    cuts.sort((a, b) => (a['frame'] as int).compareTo(b['frame']));
  });

  void setDefaultCamera(String id) =>
      execute((j) => j['default_camera_id'] = id);

  void editCut(String id, int frame, String cameraId) => execute((j) {
    final cuts = j['camera_cuts'] as List;
    final cut = cuts.firstWhere((c) => c['id'] == id);
    cut['frame'] = frame;
    cut['camera_id'] = cameraId;
    cuts.sort((a, b) => (a['frame'] as int).compareTo(b['frame']));
  });

  void removeCut(String id) => execute(
    (j) => (j['camera_cuts'] as List).removeWhere((c) => c['id'] == id),
  );
}
