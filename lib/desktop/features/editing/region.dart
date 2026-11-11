// 职责: 组合剪辑页（顶栏、预览、属性／素材、可拖高度的时间线），管理当前集工程的加载、首次导入与离开保护。
// 关联文件:
//   lib/desktop/features/editing/controller.dart
//   lib/desktop/features/editing/session.dart
//   lib/desktop/features/editing/preview.dart
//   lib/desktop/features/editing/timeline.dart
//   lib/desktop/features/editing/export_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/desktop-window-frame.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/components/reveric_segmented_control.dart';
import '../../../shared/components/reveric_surfaces.dart';
import '../../../shared/hooks/use_production_subpage.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/editing/document.dart';
import '../../../shared/providers/editing.dart';
import '../../../shared/providers/production_media.dart';
import '../../../shared/providers/storyboard.dart';
import '../../../shared/services/editing/service.dart';
import '../../../shared/theme/theme.dart';
import '../screenplay/chrome.dart';
import 'assets.dart';
import 'controller.dart';
import 'export_dialog.dart';
import 'inspector.dart';
import 'preview.dart';
import 'session.dart';
import 'support.dart';
import 'timeline.dart';

class EditingRegion extends HookConsumerWidget {
  const EditingRegion({
    super.key,
    required this.novelId,
    required this.identity,
    required this.editingId,
    required this.onClose,
    required this.registerFlush,
  });
  final String novelId;
  final ({String path, String? episodeId}) identity;
  final String editingId;
  final VoidCallback onClose;
  final ValueChanged<Future<void> Function()?> registerFlush;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(editingServiceProvider(identity.path));
    final renderer = ref.watch(editingRenderServiceProvider(identity.path));
    final settings = ref
        .watch(
          episodeProductionProvider(identity.path, identity.episodeId ?? ''),
        )
        .value;
    final sessions = ref.watch(editingSessionsProvider);
    final session = useMemoized(() => sessions.get(projects, editingId), [
      sessions,
      projects,
      editingId,
    ]);
    final controller = useMemoized(() => EditingController(session), [session]);
    final sources = ref.watch(mediaAssetsProvider).value ?? const [];
    controller.sources = {for (final asset in sources) asset.id: asset};
    useListenable(session);
    useListenable(controller);
    final ratio = settings?.ratio;
    final load = useFuture(
      useMemoized(() async {
        if (identity.episodeId == null) {
          await projects.canvasForEditing(editingId);
        }
        await session.ensureLoaded();
      }, [session, identity]),
    );
    final timelineHeight = useState(368.0);
    final register = useRef(registerFlush)..value = registerFlush;
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          register.value(session.flush);
        }
      });
      return () {
        register.value(null);
        controller.dispose();
        sessions.prune();
      };
    }, [session, sessions]);
    final doc = session.document;
    // 空时间线没有可看的属性，打开时直接落在素材页。
    useEffect(() {
      if (doc != null && doc.clips.isEmpty) {
        controller.showAssets(true);
      }
      return null;
    }, [controller, doc != null]);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final title = session.title;
    useProductionSubpage(
      ref,
      identity.path,
      '${context.t(LocaleKeys.editingTitle)} · $title',
    );
    final spec = [
      ?(doc?.ratio ?? ratio),
      ?settings?.resolution.toUpperCase(),
      '$editingFps fps',
    ].join(' · ');

    Future<void> close() async {
      await session.flush();
      if (context.mounted) {
        onClose();
      }
    }

    Future<void> export() async {
      await session.flush();
      final episodeId = identity.episodeId;
      final episode = episodeId == null
          ? null
          : await projects.database.screenplayDao.getEpisode(episodeId);
      if (episodeId != null && episode == null) {
        throw StateError('The episode no longer exists.');
      }
      if (!context.mounted) {
        return;
      }
      await showEditingExport(
        context,
        renderer: renderer,
        document: session.document!,
        title: episode == null
            ? session.title
            : editingEpisodeExportName(
                context,
                episode.episodeNumber,
                episode.title,
              ),
      );
    }

    KeyEventResult onKey(FocusNode _, KeyEvent event) {
      if (doc == null || event is KeyUpEvent) {
        return KeyEventResult.ignored;
      }
      // 焦点在输入框里时不拦截。
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null &&
          (focused.widget is EditableText ||
              focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
        return KeyEventResult.ignored;
      }
      final key = event.logicalKey;
      final keyboard = HardwareKeyboard.instance;
      final command = keyboard.isMetaPressed || keyboard.isControlPressed;
      final step = key == LogicalKeyboardKey.arrowLeft
          ? -1
          : key == LogicalKeyboardKey.arrowRight
          ? 1
          : 0;
      if (event is KeyRepeatEvent && step == 0) {
        return KeyEventResult.ignored;
      }
      if (command && key == LogicalKeyboardKey.keyZ) {
        keyboard.isShiftPressed ? session.redo() : session.undo();
      } else if (key == LogicalKeyboardKey.space) {
        controller.togglePlay?.call();
      } else if (key == LogicalKeyboardKey.keyS && !command) {
        controller.split(context);
      } else if (key == LogicalKeyboardKey.backspace ||
          key == LogicalKeyboardKey.delete) {
        controller.remove(context);
      } else if (step != 0) {
        controller.seek(controller.playhead.value + step);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }

    final saveLabel = context.t(
      session.error != null
          ? LocaleKeys.editingSaveBlocked
          : session.saving
          ? LocaleKeys.commonSaving
          : LocaleKeys.editingSaved,
    );
    return RevericChrome(
      fallback: colors.surface,
      child: Focus(
        autofocus: true,
        onKeyEvent: onKey,
        child: Column(
          children: [
            ScreenplayRegionToolbar(
              leading: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RevericIconButton(
                    icon: identity.episodeId == null
                        ? RevericIcons.arrow_back
                        : RevericIcons.close,
                    tooltip: context.t(
                      identity.episodeId == null
                          ? LocaleKeys.productionBackToCanvas
                          : LocaleKeys.commonClose,
                    ),
                    onPressed: () => editingRun(context, close),
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  RevericIcon(
                    session.error != null
                        ? RevericIcons.warning_circle
                        : RevericIcons.check,
                    size: 12,
                    color: session.error != null
                        ? colors.warningText
                        : colors.textSubtle,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    saveLabel,
                    style: typo.uiTiny.copyWith(
                      color: session.error != null
                          ? colors.warningText
                          : colors.textSubtle,
                    ),
                  ),
                ],
              ),
              trailing: [
                if (doc != null && doc.clips.isEmpty)
                  RevericButton.text(
                    label: context.t(LocaleKeys.editingImportAdopted),
                    size: RevericButtonSize.compact,
                    onPressed: controller.importing
                        ? null
                        : () => editingRun(
                            context,
                            () => controller.importAdopted(
                              context,
                              identity.episodeId,
                            ),
                          ),
                  ),
                Flexible(
                  child: Tooltip(
                    message: context.t(LocaleKeys.editingSpecHint),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RevericIcon(
                          RevericIcons.frame_corners,
                          size: 13,
                          color: colors.textMuted,
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            spec,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: typo.uiSmall.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(width: 1, height: 18, color: colors.borderSubtle),
                RevericButton.primary(
                  icon: RevericIcons.download_simple,
                  label: context.t(LocaleKeys.commonExport),
                  size: RevericButtonSize.compact,
                  onPressed: doc == null || doc.totalFrames == 0
                      ? null
                      : () => editingRun(context, export),
                ),
              ],
            ),
            if (session.sourceProblem != null || session.error != null)
              _Banner(session: session, controller: controller),
            Expanded(
              child: load.hasError
                  ? Center(
                      child: Text(
                        context.t(
                          load.error is EditingSourceProblem
                              ? LocaleKeys.editingSourceMissing
                              : LocaleKeys.commonLoadFailed,
                        ),
                      ),
                    )
                  : doc == null
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final height = timelineHeight.value.clamp(
                          220.0,
                          (constraints.maxHeight - 240).clamp(
                            220.0,
                            double.infinity,
                          ),
                        );
                        return Column(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Expanded(
                                    child: EditingPreview(
                                      controller: controller,
                                      renderer: renderer,
                                    ),
                                  ),
                                  _Side(
                                    controller: controller,
                                    novelId: novelId,
                                    path: identity.path,
                                    episodeId: identity.episodeId,
                                    title: title,
                                    spec: spec,
                                  ),
                                ],
                              ),
                            ),
                            MouseRegion(
                              cursor: SystemMouseCursors.resizeUpDown,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragUpdate: (d) =>
                                    timelineHeight.value = (height - d.delta.dy)
                                        .clamp(
                                          220.0,
                                          (constraints.maxHeight - 240).clamp(
                                            220.0,
                                            double.infinity,
                                          ),
                                        ),
                                child: Tooltip(
                                  message: context.t(
                                    LocaleKeys.editingResizeTimeline,
                                  ),
                                  waitDuration: const Duration(seconds: 1),
                                  child: Container(
                                    height: 5,
                                    decoration: BoxDecoration(
                                      color: colors.surfaceContainer,
                                      border: Border(
                                        top: BorderSide(color: colors.border),
                                        bottom: BorderSide(
                                          color: colors.borderSubtle,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              height: height,
                              child: EditingTimeline(controller: controller),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 右栏：「属性 / 素材」切换。
class _Side extends StatelessWidget {
  const _Side({
    required this.controller,
    required this.novelId,
    required this.path,
    required this.episodeId,
    required this.title,
    required this.spec,
  });
  final EditingController controller;
  final String novelId, path, title, spec;
  final String? episodeId;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      width: 288,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.lg,
              RevericSpacing.md,
              RevericSpacing.lg,
              RevericSpacing.sm,
            ),
            child: RevericSegmentedControl<bool>(
              selected: controller.assets,
              segments: [
                RevericSegment(
                  value: false,
                  label: context.t(LocaleKeys.editingProperties),
                ),
                RevericSegment(
                  value: true,
                  label: context.t(LocaleKeys.editingAssets),
                ),
              ],
              onChanged: controller.showAssets,
            ),
          ),
          Expanded(
            child: controller.assets
                ? EditingAssets(
                    controller: controller,
                    novelId: novelId,
                    path: path,
                    episodeId: episodeId,
                  )
                : EditingInspector(
                    controller: controller,
                    title: title,
                    spec: spec,
                  ),
          ),
        ],
      ),
    );
  }
}

/// 素材失效或保存失败时的提示条。
class _Banner extends StatelessWidget {
  const _Banner({required this.session, required this.controller});
  final EditingSession session;
  final EditingController controller;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final problem = session.sourceProblem;
    final broken = problem == null
        ? const <EditingClip>[]
        : session.document?.clips
                  .where((c) => problem.ids.contains(c.id))
                  .toList() ??
              const <EditingClip>[];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.lg,
        vertical: RevericSpacing.xs,
      ),
      color: colors.warningBg,
      child: Wrap(
        spacing: RevericSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          RevericIcon(
            RevericIcons.warning_circle,
            size: 14,
            color: colors.warningText,
          ),
          Text(
            context.t(
              session.error is EditingConflict
                  ? LocaleKeys.editingConflict
                  : session.error != null
                  ? LocaleKeys.editingSaveBlocked
                  : LocaleKeys.editingSourceMissing,
            ),
            style: typo.uiSmall.copyWith(color: colors.warningText),
          ),
          if (session.error != null) ...[
            RevericButton.text(
              label: context.t(LocaleKeys.commonRetry),
              size: RevericButtonSize.compact,
              onPressed: () => editingRun(context, session.flush),
            ),
            RevericButton.text(
              label: context.t(LocaleKeys.editingReload),
              size: RevericButtonSize.compact,
              onPressed: () => editingRun(context, session.reload),
            ),
          ] else
            for (final c in broken)
              RevericButton.text(
                label: editingClipLabel(controller, c),
                size: RevericButtonSize.compact,
                onPressed: () => session.select(c.id),
              ),
        ],
      ),
    );
  }
}
