// 职责: 桌面封面工作台第三列 — 画面舞台、竖排胶片条、缩放工具带与底部动作。
// 关联文件:
//   lib/shared/providers/cover_studio_providers.dart
//   lib/shared/widgets/cover_studio/slot_view.dart
//   lib/desktop/widgets/desktop_window_frame.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/desktop-window-frame.md
//   .agents/rules/i18n.md
//   .agents/rules/icons.md

import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/cover_studio_providers.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/services/cover_prompt_builder.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/cover_studio/slot_view.dart';
import '../../widgets/desktop_window_frame.dart';

class CoverStudioCanvas extends ConsumerWidget {
  const CoverStudioCanvas({
    super.key,
    required this.novelId,
    required this.novelTitle,
    required this.slots,
    required this.appliedAssetId,
    required this.onRework,
    required this.onApply,
  });

  final String novelId;

  /// 空态标题要指名作品，所以书名一路传到 [_EmptyStage]。
  final String novelTitle;
  final List<CoverSlotView> slots;
  final String? appliedAssetId;
  final void Function(int ordinal) onRework;
  final void Function(CoverSlotView slot) onApply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final ratio = coverRatioOf(state.ratioId);
    final selected = _selectedSlot(state.selectedOrdinal);

    return Column(
      children: [
        _Toolbar(novelId: novelId, selected: selected),
        Divider(height: 1, color: colors.border),
        Expanded(
          child: _Stage(
            novelId: novelId,
            novelTitle: novelTitle,
            slots: slots,
            selected: selected,
            appliedAssetId: appliedAssetId,
            ratio: ratio,
            onRework: onRework,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
          child: _Actions(
            novelId: novelId,
            selected: selected,
            applied:
                selected?.asset != null &&
                selected!.asset!.id == appliedAssetId,
            onRework: onRework,
            onApply: onApply,
          ),
        ),
      ],
    );
  }

  CoverSlotView? _selectedSlot(int ordinal) {
    if (slots.isEmpty) return null;
    for (final slot in slots) {
      if (slot.ordinal == ordinal) return slot;
    }
    return slots.first;
  }
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.novelId, required this.selected});

  final String novelId;
  final CoverSlotView? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.read(imageLibraryServiceProvider);
    final selectedPath = library.resolve(selected?.asset?.path);
    final topInset = DesktopWindowFrame.captionSafeTopInset;

    return SizedBox(
      height: DesktopWindowFrame.titleBarHeight + topInset,
      child: Padding(
        padding: EdgeInsets.only(top: topInset),
        child: SizedBox(
          height: DesktopWindowFrame.titleBarHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x2l),
            child: Row(
              children: [
                const Spacer(),
                TextButton.icon(
                  onPressed: selectedPath == null
                      ? null
                      : () => _export(context, selectedPath),
                  icon: const RevericIcon(
                    RevericIcons.download_outlined,
                    size: 15,
                  ),
                  label: Text(context.t(LocaleKeys.editorCoverExport)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _export(BuildContext context, String sourcePath) async {
    final source = File(sourcePath);
    final location = await getSaveLocation(
      suggestedName: source.uri.pathSegments.last,
    );
    if (!context.mounted || location == null) return;
    try {
      final saved = await source.copy(location.path);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.t(
              LocaleKeys.workspaceCoverSaveSuccess,
              namedArgs: {'file': saved.path},
            ),
          ),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t(LocaleKeys.workspaceCoverSaveFailed))),
      );
    }
  }
}

class _Stage extends ConsumerWidget {
  const _Stage({
    required this.novelId,
    required this.novelTitle,
    required this.slots,
    required this.selected,
    required this.appliedAssetId,
    required this.ratio,
    required this.onRework,
  });

  final String novelId;
  final String novelTitle;
  final List<CoverSlotView> slots;
  final CoverSlotView? selected;
  final String? appliedAssetId;
  final CoverRatioOption ratio;
  final void Function(int ordinal) onRework;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final state = ref.watch(coverStudioControllerProvider(novelId));

    if (slots.isEmpty && !state.generating) {
      return _EmptyStage(novelTitle: novelTitle);
    }

    // 缩放改画面宽度而不是 transform：transform 不占布局，放大后会盖住下面的
    // 说明与工具带。
    final paperWidth = coverPaperWidth * (state.zoom / 100);
    // 主列宽度不低于基准画面宽：缩小时缩略图列不跟着往里挪。
    final mainWidth = math.max(coverPaperWidth, paperWidth);

    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = coverFitZoom(
          stageWidth: constraints.maxWidth,
          stageHeight: constraints.maxHeight,
          aspectRatio: ratio.aspectRatio,
        );
        if (state.followFit && (state.zoom - fitted).abs() >= 0.5) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) {
              return;
            }
            ref
                .read(coverStudioControllerProvider(novelId).notifier)
                .applyFitZoom(fitted);
          });
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 16, 28, 16),
          // 放大到画面比舞台还宽时横向可拖；没超出时 minWidth 让这一行仍然居中。
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: math.max(0, constraints.maxWidth - coverStagePadH),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: mainWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          key: const ValueKey('cover-stage-paper'),
                          width: paperWidth,
                          child: AspectRatio(
                            aspectRatio: ratio.aspectRatio,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.surfaceContainer,
                                border: Border.all(color: colors.borderInput),
                                borderRadius: BorderRadius.circular(
                                  RevericRadius.medium,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  RevericRadius.medium,
                                ),
                                child: CoverSlotCanvas(
                                  novelId: novelId,
                                  slot: selected,
                                  reworking:
                                      selected != null &&
                                      state.reworkingOrdinal ==
                                          selected!.ordinal,
                                  onRework: onRework,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: RevericSpacing.lg),
                        CoverSlotCaption(novelId: novelId, slot: selected),
                        const SizedBox(height: RevericSpacing.md),
                        _MetaBar(novelId: novelId),
                      ],
                    ),
                  ),
                  const SizedBox(width: coverFilmstripGap),
                  _Filmstrip(
                    key: const ValueKey('cover-filmstrip'),
                    novelId: novelId,
                    slots: slots,
                    appliedAssetId: appliedAssetId,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 缩放做成画面底下的一条带；原本浮在画布上，会压住画面本身。
class _MetaBar extends ConsumerWidget {
  const _MetaBar({required this.novelId});

  final String novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.borderInput),
        borderRadius: BorderRadius.circular(RevericRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: context.t(LocaleKeys.editorCoverZoomOut),
            onPressed: state.zoom <= coverZoomMin
                ? null
                : () => controller.zoomBy(-coverZoomStep),
            icon: const RevericIcon(RevericIcons.arrows_in, size: 14),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '${state.zoom.round()}%',
              textAlign: TextAlign.center,
              style: typo.mono.copyWith(color: colors.textSecondary),
            ),
          ),
          IconButton(
            tooltip: context.t(LocaleKeys.editorCoverZoomIn),
            onPressed: state.zoom >= coverZoomMax
                ? null
                : () => controller.zoomBy(coverZoomStep),
            icon: const RevericIcon(RevericIcons.arrows_out, size: 14),
          ),
          _Divider(color: colors.borderSubtle),
          TextButton(
            onPressed: state.followFit ? null : controller.fitToStage,
            child: Text(context.t(LocaleKeys.editorCoverZoomFit)),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 14,
      margin: const EdgeInsets.symmetric(horizontal: RevericSpacing.xxs),
      color: color,
    );
  }
}

/// 竖排贴着大图放，不另开一列 —— 竖版封面的瓶颈是高度，大图两侧的宽度本来富余。
class _Filmstrip extends ConsumerWidget {
  const _Filmstrip({
    super.key,
    required this.novelId,
    required this.slots,
    required this.appliedAssetId,
  });

  final String novelId;
  final List<CoverSlotView> slots;
  final String? appliedAssetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );
    final library = ref.read(imageLibraryServiceProvider);

    return SizedBox(
      width: coverFilmstripWidth,
      child: Column(
        children: [
          for (final slot in slots)
            Padding(
              padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
              child: GestureDetector(
                onTap: () => controller.selectOrdinal(slot.ordinal),
                child: Stack(
                  children: [
                    Container(
                      height: 82,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: colors.surfaceContainer,
                        border: Border.all(
                          color: slot.ordinal == state.selectedOrdinal
                              ? colors.accent
                              : colors.border,
                          width: slot.ordinal == state.selectedOrdinal ? 2 : 1,
                        ),
                        borderRadius: BorderRadius.circular(
                          RevericRadius.small,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _thumbnail(context, slot, library, colors),
                    ),
                    Positioned(
                      left: 3,
                      top: 3,
                      child: _Badge(
                        label: '${slot.ordinal + 1}',
                        background: slot.ordinal == state.selectedOrdinal
                            ? colors.accent
                            : colors.surface.withValues(alpha: 0.85),
                        foreground: slot.ordinal == state.selectedOrdinal
                            ? colors.onAccent
                            : colors.textSecondary,
                        typo: typo,
                      ),
                    ),
                    // 重出过的一张，右下角一点标记。
                    if (slot.previousAsset != null)
                      Positioned(
                        right: 5,
                        bottom: 5,
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colors.accent,
                          ),
                        ),
                      ),
                    if (slot.asset != null && slot.asset!.id == appliedAssetId)
                      Positioned(
                        right: 3,
                        top: 3,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colors.accent,
                          ),
                          child: RevericIcon(
                            RevericIcons.check,
                            size: 10,
                            color: colors.onAccent,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _thumbnail(
    BuildContext context,
    CoverSlotView slot,
    dynamic library,
    RevericColors colors,
  ) {
    if (slot.failed) {
      return Center(
        child: RevericIcon(
          RevericIcons.warning,
          size: 14,
          color: slot.canceled ? colors.textSubtle : colors.error,
        ),
      );
    }
    final path = library.resolve(slot.asset?.path) as String?;
    if (path == null) {
      return Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.textSubtle,
          ),
        ),
      );
    }
    return Image.file(File(path), fit: BoxFit.cover);
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.background,
    required this.foreground,
    required this.typo,
  });

  final String label;
  final Color background;
  final Color foreground;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: typo.mono.copyWith(color: foreground, height: 1.2),
      ),
    );
  }
}

class _EmptyStage extends StatelessWidget {
  const _EmptyStage({required this.novelTitle});

  final String novelTitle;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    // 生成入口在右侧设计师。这里只说明预览区怎么用。
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.palette_outlined,
              size: 34,
              color: colors.textMuted,
            ),
            const SizedBox(height: RevericSpacing.md),
            Text(
              context.t(
                LocaleKeys.editorCoverEmptyTitle,
                namedArgs: {'title': novelTitle},
              ),
              textAlign: TextAlign.center,
              style: typo.heading2.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.sm),
            Text(
              context.t(LocaleKeys.editorCoverEmptyBody),
              textAlign: TextAlign.center,
              style: typo.uiSmall.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({
    required this.novelId,
    required this.selected,
    required this.applied,
    required this.onRework,
    required this.onApply,
  });

  final String novelId;
  final CoverSlotView? selected;
  final bool applied;
  final void Function(int ordinal) onRework;
  final void Function(CoverSlotView slot) onApply;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final current = selected;
    final canRework = current != null && !state.busy;
    final canUseImage = current?.asset != null && !state.busy;
    final resolutionLabel =
        ref
            .watch(coverDraftImageChoicesProvider(novelId))
            ?.resolution(state.resolutionId) ??
        (RegExp(r'^[124]k$').hasMatch(state.resolutionId)
            ? state.resolutionId.toUpperCase()
            : state.resolutionId);

    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: canRework ? () => onRework(current.ordinal) : null,
          icon: const RevericIcon(
            RevericIcons.arrow_counter_clockwise,
            size: 15,
          ),
          label: Text(context.t(LocaleKeys.editorCoverRework)),
        ),
        const Spacer(),
        Text(
          resolutionLabel,
          style: typo.mono.copyWith(color: colors.textSubtle),
        ),
        const SizedBox(width: RevericSpacing.md),
        FilledButton.icon(
          onPressed: canUseImage && !applied ? () => onApply(current!) : null,
          icon: RevericIcon(
            applied ? RevericIcons.check_circle : RevericIcons.check,
            size: 15,
          ),
          label: Text(
            context.t(
              applied
                  ? LocaleKeys.editorCoverApplied
                  : LocaleKeys.editorCoverApply,
            ),
          ),
        ),
      ],
    );
  }
}
