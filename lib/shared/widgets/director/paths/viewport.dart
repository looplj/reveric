// 职责: 在三维观察视口中绘制路径并处理铅笔、钢笔和控制点手势。
// 关联文件:
//   lib/shared/services/director/path_edit.dart
//   lib/shared/services/director/camera.dart
//   lib/shared/widgets/director/viewport.dart
// 遵循的 Rules: .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:vector_math/vector_math.dart' as v;
import '../../../models/director/document.dart';
import '../../../models/director/path.dart';
import '../../../services/director/camera.dart';
import '../../../services/director/path_edit.dart';
import '../../../services/director/session.dart';
import '../../../theme/theme.dart';

class PathViewport extends HookWidget {
  final DirectorSession session;
  final DirectorCamera camera;
  const PathViewport({super.key, required this.session, required this.camera});
  @override
  Widget build(BuildContext context) {
    final editor = session.pathEditor;
    useListenable(editor);
    useListenable(session.history);
    final pointer = useRef<int?>(null), plane = useRef(0.0);
    final focus = useFocusNode();
    final colors = RevericTheme.colorsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        List<double>? point(Offset offset) {
          final ray = camera.screenPointToRay(offset, size);
          if (ray.direction.y.abs() < 1e-6) {
            return null;
          }
          final t = (plane.value - ray.origin.y) / ray.direction.y;
          if (t < 0) {
            return null;
          }
          final p = ray.origin + ray.direction * t;
          return [p.x.toDouble(), p.y.toDouble(), p.z.toDouble()];
        }

        PathHandle? hit(Offset offset) {
          for (final handle in editor.handles().reversed) {
            final screen = camera.worldToScreen(
              v.Vector3.array(handle.position),
              size,
            );
            if (screen != null && (screen - offset).distance <= 12) {
              return handle;
            }
          }
          return null;
        }

        return Focus(
          focusNode: focus,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              pointer.value = null;
              editor.cancelGesture();
              if (editor.creating) {
                editor.cancel();
              }
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Listener(
            key: const ValueKey('director-path-viewport'),
            behavior: !session.readOnly && editor.active
                ? HitTestBehavior.opaque
                : HitTestBehavior.translucent,
            onPointerDown: (event) {
              if (session.readOnly ||
                  !editor.active ||
                  event.buttons != kPrimaryMouseButton ||
                  session.hasPendingInput) {
                return;
              }
              if (pointer.value != null) {
                pointer.value = null;
                editor.cancelGesture();
                return;
              }
              final handle = hit(event.localPosition);
              if (!editor.drawing && handle == null) {
                return;
              }
              plane.value = handle?.position[1] ?? editor.height;
              final position = point(event.localPosition);
              if (position == null) {
                return;
              }
              focus.requestFocus();
              session.pause();
              pointer.value = event.pointer;
              session.attempt(() => editor.pointerDown(position, handle));
            },
            onPointerMove: (event) {
              if (pointer.value != event.pointer) {
                return;
              }
              final position = point(event.localPosition);
              if (position != null) {
                session.attempt(() => editor.pointerMove(position));
              }
            },
            onPointerUp: (event) {
              if (pointer.value != event.pointer) {
                return;
              }
              pointer.value = null;
              session.attempt(editor.pointerUp);
            },
            onPointerCancel: (_) {
              pointer.value = null;
              editor.cancelGesture();
            },
            child: CustomPaint(
              size: size,
              painter: _PathPainter(
                camera,
                session.history.document.paths,
                editor,
                colors.accent,
                colors.textMuted,
                showHandles: !session.readOnly,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PathPainter extends CustomPainter {
  final DirectorCamera camera;
  final List<Json> paths;
  final PathEditSession editor;
  final Color selectedColor, color;
  final bool showHandles;
  _PathPainter(
    this.camera,
    this.paths,
    this.editor,
    this.selectedColor,
    this.color, {
    required this.showHandles,
  });
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    Offset? project(List p) => camera.worldToScreen(
      v.Vector3(
        (p[0] as num).toDouble(),
        (p[1] as num).toDouble(),
        (p[2] as num).toDouble(),
      ),
      size,
    );
    final active = editor.visible;
    for (final path in [
      for (final p in paths)
        if (p['id'] != active?['id']) p,
      ?active,
    ]) {
      final selected = path['id'] == editor.selectedId;
      final pen = Paint()
        ..color = selected ? selectedColor : color
        ..strokeWidth = selected ? 2 : 1;
      List<List<double>> points;
      final geometry = path['geometry'];
      if (editor.drawing && selected) {
        points = path['kind'] == 'pencil'
            ? [
                for (final p in geometry['points'])
                  (p as List).map((n) => (n as num).toDouble()).toList(),
              ]
            : [
                for (final node in geometry['nodes'])
                  (node['position'] as List)
                      .map((n) => (n as num).toDouble())
                      .toList(),
              ];
      } else {
        final curve = MotionPath.fromJson({
          ...cloneJson(path),
          'easing': 'linear',
        });
        points = [
          for (var i = 0; i <= 128; i++)
            curve
                .sample(curve.start + (curve.end - curve.start) * i / 128, 0)
                .position,
        ];
      }
      for (var i = 1; i < points.length; i++) {
        final a = project(points[i - 1]), b = project(points[i]);
        if (a != null && b != null) {
          canvas.drawLine(a, b, pen);
        }
      }
      if (selected && showHandles) {
        for (final handle in editor.handles(path)) {
          final p = project(handle.position);
          if (p == null) {
            continue;
          }
          final isHandle = handle.field.endsWith('_handle');
          if (isHandle) {
            final anchor = project(geometry['nodes'][handle.index]['position']);
            if (anchor != null) {
              canvas.drawLine(
                anchor,
                p,
                Paint()
                  ..color = color
                  ..strokeWidth = 1,
              );
            }
          }
          canvas.drawCircle(
            p,
            isHandle ? 4 : 6,
            Paint()..color = selectedColor,
          );
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PathPainter oldDelegate) => true;
}
