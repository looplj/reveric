// 职责: 移动端封面画布动作行 — 缩放、重出这一张与设为封面。
// 关联文件:
//   lib/shared/providers/cover_studio_providers.dart
//   lib/mobile/features/cover_studio/studio_page.dart
//   lib/shared/services/cover_prompt_builder.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
//   .agents/rules/icons.md

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/cover_studio_providers.dart';
import '../../../shared/theme/theme.dart';

class MobileCoverCanvasActions extends ConsumerWidget {
  const MobileCoverCanvasActions({
    super.key,
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
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final current = selected;
    final canRework = current != null && !state.busy;
    final canUseImage = current != null && current.asset != null && !state.busy;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x2l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MetaBar(novelId: novelId),
          const SizedBox(height: RevericSpacing.sm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: canRework ? () => onRework(current.ordinal) : null,
                  icon: const RevericIcon(
                    RevericIcons.arrow_counter_clockwise,
                    size: 15,
                  ),
                  label: Text(context.t(LocaleKeys.editorCoverRework)),
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: canUseImage && !applied
                      ? () => onApply(current)
                      : null,
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
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 缩放一条带；分辨率跟着缩放一起居中，不用 Spacer 把两端顶开 —— 主图本身是
/// 居中的，这一行贴着它就要对齐同一条中轴。
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
    final resolutionLabel =
        ref.watch(coverImageChoicesProvider)?.resolution(state.resolutionId) ??
        (RegExp(r'^[124]k$').hasMatch(state.resolutionId)
            ? state.resolutionId.toUpperCase()
            : state.resolutionId);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          resolutionLabel,
          style: typo.mono.copyWith(color: colors.textSubtle),
        ),
        const SizedBox(width: RevericSpacing.sm),
        IconButton(
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
          onPressed: state.zoom >= coverZoomMax
              ? null
              : () => controller.zoomBy(coverZoomStep),
          icon: const RevericIcon(RevericIcons.arrows_out, size: 14),
        ),
        TextButton(
          onPressed: state.followFit ? null : controller.fitToStage,
          child: Text(context.t(LocaleKeys.editorCoverZoomFit)),
        ),
      ],
    );
  }
}
