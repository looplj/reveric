// 职责: 显示原生三维视口并处理选择、等高平移、水平旋转和独立观察机位。
// 关联文件:
//   lib/shared/services/director/session.dart
//   lib/shared/services/director/scene_builder.dart
//   lib/shared/widgets/director/paths/viewport.dart
//   lib/shared/widgets/director/frame_content.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules: .agents/rules/hooks.md
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/theme/theme.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as v;

import 'package:reveric/shared/services/director/camera.dart';
import 'package:reveric/shared/models/director/sampling.dart';
import 'package:reveric/shared/models/director/presets.dart';
import 'package:reveric/shared/services/director/scene_builder.dart';
import 'package:reveric/shared/services/director/session.dart';
import 'package:reveric/shared/widgets/director/gizmo.dart';
import 'package:reveric/shared/widgets/director/pointer_gesture.dart';
import 'grid.dart';
import 'frame_content.dart';
import 'strings.dart';
import '../../services/director/prop_models.dart';
import 'overlay.dart';
import 'paths/viewport.dart';

class ViewState extends ChangeNotifier {
  bool output = false;
  v.Vector3 eye = v.Vector3(4, 3, 6), target = v.Vector3(0, 1, 0);
  void home() {
    eye = v.Vector3(4, 3, 6);
    target = v.Vector3(0, 1, 0);
    notifyListeners();
  }

  void pan(double dx, double dy) {
    final forward = (target - eye)..normalize(),
        right = forward.cross(v.Vector3(0, 1, 0))..normalize(),
        up = right.cross(forward)..normalize();
    final k = (eye - target).length * 0.0015;
    final shift = right * (-dx * k) + up * (dy * k);
    eye += shift;
    target += shift;
    notifyListeners();
  }

  void update(void Function() fn) {
    fn();
    notifyListeners();
  }

  DirectorCamera camera() => DirectorCamera(position: eye, target: target);
  void orbit(double dx, double dy) {
    final offset = eye - target, r = offset.length;
    final yaw = math.atan2(offset.x, offset.z) - dx * 0.008,
        pitch = (math.asin(offset.y / r) + dy * 0.008).clamp(-1.4, 1.4);
    eye =
        target +
        v.Vector3(
          math.sin(yaw) * math.cos(pitch) * r,
          math.sin(pitch) * r,
          math.cos(yaw) * math.cos(pitch) * r,
        );
    notifyListeners();
  }

  void zoom(double delta) {
    eye = target + (eye - target) * math.exp(delta * 0.001);
    notifyListeners();
  }
}

class DirectorViewport extends HookWidget {
  const DirectorViewport({
    super.key,
    required this.session,
    required this.view,
    this.preview = false,
  });
  final DirectorSession session;
  final ViewState view;
  final bool preview;
  @override
  Widget build(BuildContext context) {
    useListenable(session.history);
    final paths = session.history.document.objects
        .where((o) => propModelAssets.containsKey(o['geometry_key']))
        .map((o) => o['geometry_key'])
        .join('|');
    final future = useMemoized(
      () => paths.isEmpty ? null : PropModels.load(session.history.document),
      [paths],
    );
    final loaded = useFuture(future);
    if (future != null && loaded.connectionState != ConnectionState.done) {
      return Center(child: Text(tr(context, 'loading')));
    }
    if (loaded.hasError) {
      return Center(child: Text(tr(context, 'operation_failed')));
    }
    return DirectorFrameContent(
      session: session,
      builder: (context) => _LoadedDirectorViewport(
        props: loaded.data ?? const {},
        session: session,
        view: view,
        preview: preview,
      ),
    );
  }
}

class _LoadedDirectorViewport extends HookWidget {
  final DirectorSession session;
  final ViewState view;
  final bool preview;
  final Map<String, Node> props;
  const _LoadedDirectorViewport({
    required this.session,
    required this.view,
    this.preview = false,
    this.props = const {},
  });
  @override
  Widget build(BuildContext context) {
    useListenable(session.history);
    useListenableSelector(
      session,
      () => (session.selected, session.history.timelineVisible),
    );
    useListenableSelector(session.pathEditor, () => session.pathEditor.active);
    useListenable(session.frame);
    useListenable(view);
    final document = session.history.visible;
    // Geometry rebuilds for document or view-mode changes; gesture previews
    // and frame changes only update node transforms.
    final builder = useMemoized(
      () => SceneBuilder(
        session.history.document,
        showGround: view.output,
        props: props,
      ),
      [session.history.document, view.output, props],
    );
    useEffect(() => builder.dispose, [builder]);
    final selectionColor = RevericTheme.colorsOf(context).accent;
    for (final entry in builder.roots.entries) {
      entry.value.highlightColor = !preview && entry.key == session.selected
          ? v.Vector4(selectionColor.r, selectionColor.g, selectionColor.b, 1)
          : null;
    }
    final cameraId = session.viewCameraId;
    final camera = view.output
        ? builder.apply(document, session.frame.value, cameraId)
        : view.camera();
    if (!view.output) {
      builder.apply(document, session.frame.value, cameraId);
      builder.scene.depthOfField.enabled = false;
    }
    final mode = session.tool == 'rotate' ? 'rotate' : 'move';
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final gesture = useMemoized(ViewportGesture.new);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.biggest,
            ratio = document.width / document.height;
        final width = math.min(available.width, available.height * ratio),
            size = view.output ? Size(width, width / ratio) : available;
        if (size.isEmpty) {
          return const SizedBox.shrink();
        }
        final sample = sampleDocument(document, session.frame.value);
        final selected = sample.objects
            .where((o) => o['id'] == session.selected)
            .firstOrNull;
        final overlay = view.output || preview
            ? null
            : StageOverlay(
                document: document,
                sample: sample,
                camera: camera,
                size: size,
                selected: session.selected,
                frame: session.frame.value,
              );
        final gizmo =
            selected == null ||
                preview ||
                session.readOnly ||
                session.pathEditor.active
            ? null
            : GizmoProjection(
                camera: camera,
                size: size,
                position: vec(selected['position']),
                mode: mode,
              );
        return Center(
          child: SizedBox.fromSize(
            size: size,
            child: Listener(
              onPointerSignal: (e) {
                if (e is PointerScrollEvent && !view.output) {
                  view.zoom(e.scrollDelta.dy);
                }
              },
              onPointerDown: (e) {
                if (session.pathEditor.active &&
                    !view.output &&
                    !preview &&
                    e.buttons == kPrimaryMouseButton) {
                  return;
                }
                gesture.pointers.add(e.pointer);
                if (gesture.pointers.length > 1) {
                  gesture.clearDrag();
                  session.cancelEditGesture();
                  return;
                }
                if (session.hasPendingInput) {
                  session.select(null);
                  return;
                }
                session.pause();
                gesture.clearDrag();
                gesture.down = e.position;
                gesture.originGlobal = e.position - e.localPosition;
                gesture.camera = camera;
                gesture.viewportSize = size;
                gesture.generation = session.history.gestureGeneration;
                gesture.buttons = e.buttons;
                if (e.buttons == kPrimaryMouseButton) {
                  if (session.readOnly) {
                    final cameraHit = overlay?.hitCamera(e.localPosition);
                    final hit = builder.scene.raycast(
                      camera.screenPointToRay(e.localPosition, size),
                    );
                    final id =
                        cameraHit ??
                        (hit == null ? null : builder.owners[hit.node]);
                    // 只读模式：点中对象选中它，点空白松手回当前机位，任意拖动均只环绕视角。
                    gesture.orbit = id == null && !view.output;
                    if (id != null) {
                      session.select(id);
                    } else if (view.output) {
                      session.select(cameraId);
                    }
                  } else {
                    if (!session.claimEditGesture(gesture, e.pointer)) {
                      gesture.clearDrag();
                      return;
                    }
                    gesture.handle = gizmo?.hitTest(
                      e.localPosition,
                      tolerance: e.kind == PointerDeviceKind.touch ? 22 : 12,
                    );
                    String? id = session.selected;
                    if (gesture.handle == null) {
                      final cameraHit = overlay?.hitCamera(e.localPosition);
                      final hit = builder.scene.raycast(
                        camera.screenPointToRay(e.localPosition, size),
                      );
                      id =
                          cameraHit ??
                          (hit == null ? null : builder.owners[hit.node]);
                      // 空白处按下：拖动即环绕视角，未拖动的单击回到当前机位。
                      gesture.orbit = id == null && !view.output;
                      if (id != null) {
                        session.select(id);
                      } else if (view.output) {
                        session.select(cameraId);
                      }
                    }
                    gesture.original = sampleDocument(
                      document,
                      session.frame.value,
                    ).objects.where((o) => o['id'] == id).firstOrNull;
                    if (gesture.original != null) {
                      gesture.ground = gesture.planePoint(e.position);
                    }
                    if (gesture.handle == GizmoHandle.y_ring &&
                        gesture.original != null) {
                      final p = gesture.planePoint(e.position, ring: true);
                      if (p != null) {
                        final center = vec(gesture.original!['position']);
                        gesture.lastRingAngle = math.atan2(
                          p.x - center.x,
                          p.z - center.z,
                        );
                      }
                    }
                  }
                }
              },
              onPointerMove: (e) {
                if (gesture.pointers.length > 1) {
                  return;
                }
                if (gesture.generation != session.history.gestureGeneration) {
                  gesture.down = null;
                }
                if (gesture.down == null) {
                  return;
                }
                final pan =
                    gesture.buttons == kMiddleMouseButton ||
                    ((gesture.orbit ||
                            session.readOnly ||
                            gesture.buttons == kSecondaryMouseButton) &&
                        HardwareKeyboard.instance.isShiftPressed);
                if (!view.output && pan) {
                  gesture.moved = true;
                  session.cancelEditGesture();
                  view.pan(e.delta.dx, e.delta.dy);
                  return;
                }
                if (!view.output &&
                    (gesture.buttons == kSecondaryMouseButton ||
                        gesture.orbit ||
                        session.readOnly)) {
                  gesture.moved = true;
                  view.orbit(e.delta.dx, e.delta.dy);
                  return;
                }
                if (session.readOnly) {
                  return;
                }
                if ((e.position - gesture.down!).distance < 4 &&
                    !gesture.dragging) {
                  return;
                }
                final o = gesture.original;
                if (o == null) {
                  return;
                }
                gesture.dragging = true;
                gesture.valid = false;
                session.attempt(() {
                  if (mode == 'move') {
                    final next = gesture.positionAt(e.position);
                    if (next == null) {
                      return;
                    }
                    session.history.previewEdit(
                      (j) => session.history.editPropertyIn(
                        j,
                        o['id'],
                        'position',
                        next,
                        session.frame.value,
                      ),
                    );
                  }
                  if (mode == 'rotate') {
                    final next = gesture.rotationAt(
                      e.position,
                      snap: HardwareKeyboard.instance.isShiftPressed,
                    );
                    session.history.previewEdit(
                      (j) => session.history.editPropertyIn(
                        j,
                        o['id'],
                        'rotation',
                        next,
                        session.frame.value,
                      ),
                    );
                  }
                  gesture.valid = true;
                });
              },
              onPointerUp: (e) {
                session.releaseEditGesture(gesture, e.pointer);
                gesture.pointers.remove(e.pointer);
                if (gesture.dragging &&
                    gesture.generation == session.history.gestureGeneration) {
                  if (gesture.valid) {
                    session.attempt(session.history.commitGesture);
                  } else {
                    session.history.cancelGesture();
                  }
                }
                if (gesture.orbit && !gesture.moved && gesture.down != null) {
                  session.select(cameraId);
                }
                gesture.clearDrag();
              },
              onPointerCancel: (e) {
                gesture.pointers.remove(e.pointer);
                gesture.clearDrag();
                session.cancelEditGesture();
              },
              child: GestureDetector(
                onScaleStart: (d) {
                  gesture.scale = 1;
                },
                onScaleUpdate: (d) {
                  if (d.pointerCount >= 2 && !view.output) {
                    session.history.cancelGesture();
                    view.zoom(-math.log(d.scale / gesture.scale) * 1000);
                    gesture.scale = d.scale;
                    final shift = v.Vector3(
                      -d.focalPointDelta.dx * 0.01,
                      d.focalPointDelta.dy * 0.01,
                      0,
                    );
                    view.update(() {
                      view.eye += shift;
                      view.target += shift;
                    });
                  }
                },
                child: ColoredBox(
                  color: view.output
                      ? Color(
                          0xFF000000 |
                              int.parse(
                                document.background.substring(1),
                                radix: 16,
                              ),
                        )
                      : colors.canvas,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!view.output)
                        IgnorePointer(
                          child: CustomPaint(
                            painter: DirectorGridPainter(camera, colors.border),
                          ),
                        ),
                      SceneView(
                        builder.scene,
                        camera: camera,
                        autoTick: false,
                        pixelRatio: MediaQuery.devicePixelRatioOf(context),
                      ),
                      // 投影的视锥可能画到视口外，裁掉以免压到两侧面板。
                      if (overlay != null)
                        IgnorePointer(
                          child: ClipRect(
                            child: CustomPaint(
                              key: const ValueKey('director-overlay'),
                              painter: StageOverlayPainter(
                                overlay,
                                colors,
                                typo.uiTiny,
                                document.fps,
                              ),
                            ),
                          ),
                        ),
                      if (!view.output &&
                          !preview &&
                          session.history.timelineVisible)
                        PathViewport(session: session, camera: camera),
                      if (gizmo != null)
                        IgnorePointer(
                          child: CustomPaint(
                            key: const ValueKey('director-gizmo'),
                            painter: GizmoPainter(
                              gizmo,
                              colors,
                              gesture.handle,
                              typo.uiTiny,
                              quaternionYaw(selected!['rotation']),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
