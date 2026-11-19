// 职责: 管理路径绘制与控制点手势，使用统一命令原子提交并支持取消。
// 关联文件:
//   lib/shared/models/director/path.dart
//   lib/shared/services/director/commands.dart
//   lib/shared/services/director/session.dart
//   lib/shared/widgets/director/paths/viewport.dart
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../models/director/document.dart';
import '../../models/director/path.dart';
import '../../models/director/sampling.dart';
import 'commands.dart';

class PathHandle {
  final String field;
  final int index;
  final List<double> position;
  const PathHandle(this.field, this.index, this.position);
  String get id => '$field:$index';
}

class PathEditSession extends ChangeNotifier {
  final CommandHistory history;
  final int Function() currentFrame;
  String? selectedId;
  Json? _draft, _gestureStart;
  int? _generation;
  bool drawing = false, replace = false;
  double height = 0;
  PathHandle? dragging;
  PathEditSession(this.history, this.currentFrame);
  bool get readOnly => history.readOnly;
  Json? get selected =>
      history.document.paths.where((p) => p['id'] == selectedId).firstOrNull;
  Json? get visible => _draft == null ? selected : cloneJson(_draft!);
  bool get active => visible != null;
  bool get creating => _draft != null && selected == null;
  void select(String? id) {
    if (_gestureStart != null) {
      cancelGesture();
    }
    selectedId = id;
    _draft = null;
    _gestureStart = null;
    drawing = false;
    dragging = null;
    replace = false;
    notifyListeners();
  }

  void cancel() {
    cancelGesture();
    select(null);
  }

  void begin(String actorId, String kind, (int, int) range, int frame) {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    cancelGesture();
    choice(kind, 'kind', pathKinds);
    final actor = sampleDocument(
      history.document,
      frame,
    ).objects.firstWhere((o) => o['id'] == actorId);
    if (actor['kind'] != 'actor') {
      invalid('path', 'actor_required');
    }
    final p = (actor['position'] as List)
        .map((n) => (n as num).toDouble())
        .toList();
    height = p[1];
    selectedId = const Uuid().v4();
    final end = [p[0] + (p[0] > 48 ? -2 : 2), p[1], p[2]];
    _draft = {
      'id': selectedId,
      'target_id': actorId,
      'kind': kind,
      'start_frame': range.$1,
      'end_frame': range.$2,
      'easing': 'linear',
      'orient_to_path': false,
      'geometry': switch (kind) {
        'line' => {'start': p, 'end': end},
        'circle' => {
          'center': p,
          'radius': 2.0,
          'plane_rotation': [0, 0, 0, 1],
          'start_angle': 0,
          'clockwise': false,
        },
        'rectangle' => {
          'center': p,
          'width': 4.0,
          'depth': 2.0,
          'plane_rotation': [0, 0, 0, 1],
          'start_corner': 0,
          'clockwise': false,
        },
        'pencil' => {'points': <List<double>>[], 'closed': false},
        _ => {'nodes': <Json>[], 'closed': false},
      },
    };
    drawing = kind == 'pencil' || kind == 'pen';
    replace = false;
    _gestureStart = null;
    dragging = null;
    try {
      _validateDraft(_draft!);
    } catch (_) {
      cancel();
      rethrow;
    }
    notifyListeners();
  }

  void update(void Function(Json) edit) {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    final value = visible;
    if (value == null) {
      return;
    }
    edit(value);
    _validateDraft(value);
    if (creating) {
      _draft = value;
    } else {
      history.upsertPath(value, replace: replace);
      _draft = null;
    }
    notifyListeners();
  }

  void finish() {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    final value = visible;
    if (value == null) {
      return;
    }
    if (value['kind'] == 'pencil') {
      value['geometry']['points'] = simplifyPencil([
        for (final p in value['geometry']['points'])
          (p as List).map((n) => (n as num).toDouble()).toList(),
      ]);
    }
    history.upsertPath(value, replace: replace);
    _draft = null;
    drawing = false;
    dragging = null;
    _gestureStart = null;
    notifyListeners();
  }

  void remove() {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    if (selected != null) {
      history.removePath(selectedId!);
    }
    cancel();
  }

  void bake() {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    history.bake('motion_paths', selectedId!);
    cancel();
  }

  void pointerDown(List<double> point, PathHandle? handle) {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    final value = visible;
    if (value == null) {
      return;
    }
    _generation = history.gestureGeneration;
    _gestureStart = cloneJson(value);
    _draft = cloneJson(value);
    dragging = handle;
    if (drawing) {
      if (value['kind'] == 'pencil') {
        _draft!['geometry']['points'] = [point];
      } else if (value['kind'] == 'pen') {
        final nodes = _draft!['geometry']['nodes'] as List;
        nodes.add({'position': point, 'smooth': false});
        dragging = PathHandle('out_handle', nodes.length - 1, point);
      }
    }
    notifyListeners();
  }

  void pointerMove(List<double> point) {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    vector(point, 'motion_path.point', 50);
    if (_gestureStart == null || _generation != history.gestureGeneration) {
      cancelGesture();
      return;
    }
    if (drawing && _draft!['kind'] == 'pencil') {
      final points = _draft!['geometry']['points'] as List;
      final last = points.last as List;
      final distance = List.generate(
        3,
        (i) => (point[i] - last[i]) * (point[i] - last[i]),
      ).reduce((a, b) => a + b);
      if (distance > .000001) {
        points.add(point);
      }
    } else if (dragging != null) {
      final next = cloneJson(_draft!);
      _moveHandle(next, dragging!, point);
      _validateDraft(next);
      if (!creating && !drawing) {
        history.previewControl('motion_paths', next);
        try {
          sampleDocument(history.visible, currentFrame());
        } catch (_) {
          history.cancelGesture();
          rethrow;
        }
      }
      _draft = next;
    }
    notifyListeners();
  }

  void pointerUp() {
    if (readOnly) {
      throw StateError('Director session is read-only');
    }
    if (_gestureStart == null) {
      return;
    }
    if (_generation != history.gestureGeneration) {
      cancelGesture();
      return;
    }
    if (drawing) {
      _gestureStart = null;
      dragging = null;
      if (_draft!['kind'] == 'pencil') {
        _draft!['geometry']['points'] = simplifyPencil([
          for (final p in _draft!['geometry']['points'])
            (p as List).cast<double>(),
        ]);
      }
    } else {
      try {
        finish();
      } catch (_) {
        cancelGesture();
        rethrow;
      }
    }
    notifyListeners();
  }

  void cancelGesture() {
    if (_gestureStart != null) {
      if (history.preview != null) {
        history.cancelGesture();
      }
      _draft = selected == null ? _gestureStart : null;
    }
    dragging = null;
    _gestureStart = null;
    notifyListeners();
  }

  void _validateDraft(Json path) {
    final start = path['start_frame'] as int, end = path['end_frame'] as int;
    if (start < 0 || start >= end || end > history.document.durationFrames) {
      invalid('motion_path.interval', 'invalid_interval');
    }
    final g = path['geometry'];
    if (path['kind'] == 'pencil' && (g['points'] as List).length < 2 ||
        path['kind'] == 'pen' && (g['nodes'] as List).length < 2) {
      return;
    }
    MotionPath.fromJson(cloneJson(path));
  }

  List<PathHandle> handles([Json? data]) {
    final path = data ?? visible;
    if (path == null) {
      return [];
    }
    final g = path['geometry'];
    List<double> numbers(List p) =>
        p.map((n) => (n as num).toDouble()).toList();
    return switch (path['kind']) {
      'line' => [
        for (final field in ['start', 'end'])
          PathHandle(field, 0, numbers(g[field])),
      ],
      'circle' ||
      'rectangle' => [PathHandle('center', 0, numbers(g['center']))],
      'pencil' => [
        for (final e in (g['points'] as List).indexed)
          PathHandle('point', e.$1, numbers(e.$2)),
      ],
      _ => [
        for (final e in (g['nodes'] as List).indexed)
          for (final field in ['position', 'in_handle', 'out_handle'])
            if (e.$2[field] != null)
              PathHandle(field, e.$1, numbers(e.$2[field])),
      ],
    };
  }

  void moveHandle(PathHandle handle, List<double> point) =>
      update((p) => _moveHandle(p, handle, point));
  void _moveHandle(Json path, PathHandle handle, List<double> point) {
    final g = path['geometry'];
    if (path['kind'] == 'pencil') {
      g['points'][handle.index] = point;
    } else if (path['kind'] == 'pen') {
      final node = g['nodes'][handle.index];
      if (handle.field == 'position') {
        final old = node['position'];
        for (final field in ['in_handle', 'out_handle']) {
          if (node[field] != null) {
            node[field] = [
              for (var i = 0; i < 3; i++) node[field][i] + point[i] - old[i],
            ];
          }
        }
      }
      node[handle.field] = point;
      if (handle.field != 'position' && (drawing || node['smooth'] == true)) {
        node['smooth'] = true;
        node[handle.field == 'in_handle' ? 'out_handle' : 'in_handle'] = [
          for (var i = 0; i < 3; i++) 2 * node['position'][i] - point[i],
        ];
      }
    } else {
      g[handle.field] = point;
    }
  }
}
