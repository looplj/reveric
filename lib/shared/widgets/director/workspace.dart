// 职责: 组合可嵌入的导演编辑区，接受调用方提供的工具栏与输出状态。
// 关联文件:
//   lib/shared/services/director/session.dart
//   lib/shared/widgets/director/viewport.dart
//   lib/shared/widgets/director/inspector.dart
//   lib/shared/widgets/director/timeline.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules: .agents/rules/hooks.md
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:vector_math/vector_math.dart' as v;
import '../../models/director/actor_catalog.dart';
import '../../services/director/actor_catalog.dart';
import '../../../shared/models/director/document.dart';
import '../../../shared/models/director/sampling.dart';
import '../../../shared/services/director/session.dart';
import '../../../shared/services/director/scene_builder.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/components/reveric_segmented_control.dart';
import 'viewport.dart';
import 'inspector.dart';
import 'timeline.dart';
import 'sidebar.dart';
import 'stage.dart';
import 'strings.dart';

class DirectorWorkspace extends HookWidget {
  final DirectorSession session;
  const DirectorWorkspace({
    super.key,
    required this.session,
    this.viewportBuilder,
    this.header,
    this.footer,
    this.actorCatalog,
    this.onRecognizeImage,
  });
  final DirectorActorCatalog? actorCatalog;

  /// 左栏「AI 识图」入口，由宿主提供图片来源与聊天交接。
  final VoidCallback? onRecognizeImage;

  /// 顶栏；参数是视角下拉，由顶栏决定摆放位置。不传时视角下拉悬浮在视口顶部。
  final Widget Function(Widget viewMode)? header;
  final Widget? footer;
  @visibleForTesting
  final Widget Function(DirectorSession, ViewState)? viewportBuilder;
  @override
  Widget build(BuildContext context) {
    useListenable(session);
    final male = tr(context, 'default_actor_male');
    final female = tr(context, 'default_actor_female');
    final catalog = useMemoized(
      () => DirectorActorCatalogController(
        actorCatalog?.initialActors != null || actorCatalog?.load != null
            ? actorCatalog!
            : DirectorActorCatalog(
                initialActors: [
                  DirectorActor(
                    id: 'male',
                    name: male,
                    body: DirectorActorBody.male,
                  ),
                  DirectorActor(
                    id: 'female',
                    name: female,
                    body: DirectorActorBody.female,
                  ),
                ],
              ),
      ),
      [actorCatalog, male, female],
    );
    useEffect(() {
      unawaited(catalog.load());
      return catalog.dispose;
    }, [catalog]);
    final view = useMemoized(ViewState.new);
    final compactTab = useState(0);
    final inspectorKey = useMemoized(GlobalKey.new);
    useListenable(view);
    useOnListenableChange(session.pathEditor, () {
      if (session.pathEditor.active && view.output) {
        view.update(() => view.output = false);
      }
    });
    // 播放时主视口切到切镜成片，停止后回到播放前的视角。
    final beforePlay = useRef<(bool, String?)?>(null);
    useOnListenableChange(session, () {
      final saved = beforePlay.value;
      if (session.playing && saved == null) {
        beforePlay.value = (
          view.output,
          session.cameraMode == 'sequence' ? null : session.viewCameraId,
        );
        session.viewCamera(null);
        view.update(() => view.output = true);
      } else if (!session.playing && saved != null) {
        beforePlay.value = null;
        session.viewCamera(saved.$2);
        view.update(() => view.output = saved.$1);
      }
    });
    final focus = useFocusNode();

    useEffect(
      () => () {
        view.dispose();
        session.suspendForUnmount();
      },
      [session, view],
    );
    void focusSelection() {
      final selected = sampleDocument(
        session.history.document,
        session.frame.value,
      ).objects.where((o) => o['id'] == session.selected).firstOrNull;
      if (selected != null) {
        final target = vec(selected['position']);
        target.y = 1;
        view.update(() {
          final offset = view.eye - view.target;
          view.target = target;
          view.eye = target + offset;
          view.output = false;
        });
      }
    }

    List<double> xyz(v.Vector3 p) => [p.x, p.y, p.z];
    void addCameraFromView(String name) {
      final camera = DirectorDocument.newCamera(
        name,
        xyz(view.eye),
        xyz(view.target),
        35,
      );
      session.history.execute((j) => (j['cameras'] as List).add(camera));
      session.select(camera['id']);
    }

    void alignToView(String id) => session.attempt(
      () => session.history.placeCamera(
        id,
        xyz(view.eye),
        xyz(view.target),
        session.frame.value,
      ),
    );

    Widget viewport({required bool compact}) => DirectorStage(
      session: session,
      view: view,
      viewportBuilder: viewportBuilder,
      showPreview: !compact,
      showViewMode: header == null,
    );
    final sidebar = DirectorSidebar(
      session: session,
      actorCatalog: catalog,
      onAddCameraFromView: (name) =>
          session.attempt(() => addCameraFromView(name)),
      onRecognizeImage: session.readOnly ? null : onRecognizeImage,
    );
    final inspector = Inspector(
      key: inspectorKey,
      session: session,
      onAlignToView: alignToView,
    );
    return Focus(
      focusNode: focus,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey,
            modifier =
                HardwareKeyboard.instance.isMetaPressed ||
                HardwareKeyboard.instance.isControlPressed;
        // 保存由当前编辑器处理；文本字段中的未提交输入也不能穿透到宿主保存。
        if (modifier && key == LogicalKeyboardKey.keyS) {
          if (!session.readOnly && session.onSave != null) {
            session.attempt(session.save);
          }
          return KeyEventResult.handled;
        }
        if (FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<EditableText>() !=
            null) {
          return KeyEventResult.ignored;
        }
        if (session.hasPendingInput) {
          return KeyEventResult.ignored;
        }
        if (key == LogicalKeyboardKey.keyF) {
          session.attempt(focusSelection);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.escape) {
          session.pathEditor.cancelGesture();
          if (session.pathEditor.creating) {
            session.pathEditor.cancel();
          }
          session.history.cancelGesture();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.space) {
          session.attempt(session.play);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight) {
          session.seek(
            session.frame.value +
                (key == LogicalKeyboardKey.arrowLeft ? -1 : 1),
          );
          return KeyEventResult.handled;
        }
        if (session.readOnly) {
          return KeyEventResult.ignored;
        }
        if (key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace) {
          if (session.selected != null) {
            session.attempt(() => session.history.remove(session.selected!));
          }
          return KeyEventResult.handled;
        }
        if (modifier && key == LogicalKeyboardKey.keyZ) {
          if (HardwareKeyboard.instance.isShiftPressed) {
            session.history.redo();
          } else {
            session.history.undo();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(
        builder: (context, bounds) {
          final compact = bounds.maxWidth < 900;
          final content = Column(
            children: [
              ?header?.call(
                DirectorViewModeSelect(session: session, view: view),
              ),
              if (compact)
                RevericSegmentedControl<int>(
                  segments: [
                    for (final entry in [
                      'edit_view',
                      'objects',
                      'properties',
                    ].indexed)
                      RevericSegment(
                        value: entry.$1,
                        label: tr(context, entry.$2),
                      ),
                  ],
                  selected: compactTab.value,
                  onChanged: (value) => compactTab.value = value,
                ),
              Expanded(
                child: compact
                    ? IndexedStack(
                        index: compactTab.value,
                        children: [viewport(compact: true), sidebar, inspector],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: bounds.maxWidth < 1200
                                ? RevericSizes.directorPanelWidth
                                : RevericSizes.directorSidebarWidth,
                            child: sidebar,
                          ),
                          VerticalDivider(
                            width: 1,
                            color: RevericTheme.colorsOf(context).border,
                          ),
                          Expanded(child: viewport(compact: false)),
                          VerticalDivider(
                            width: 1,
                            color: RevericTheme.colorsOf(context).border,
                          ),
                          SizedBox(
                            width: RevericSizes.directorInspectorWidth,
                            child: ColoredBox(
                              color: RevericTheme.colorsOf(context).surfaceDim,
                              child: inspector,
                            ),
                          ),
                        ],
                      ),
              ),
              DirectorTimeline(session: session),
              ?footer,
            ],
          );
          return SingleChildScrollView(
            child: SizedBox(
              height: math.max(620, bounds.maxHeight),
              child: content,
            ),
          );
        },
      ),
    );
  }
}
