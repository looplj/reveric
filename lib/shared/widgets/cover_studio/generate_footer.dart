// 职责: 展示封面生成张数、生成与停止操作，以及当前进度。
// 关联文件:
//   lib/shared/providers/cover_studio_providers.dart
//   lib/desktop/features/cover_studio/designer.dart
//   lib/mobile/features/cover_studio/bottom_bar.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/state-management.md
//   .agents/rules/i18n.md
//   .agents/rules/icons.md

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../providers/ai_providers.dart';
import '../../providers/cover_studio_providers.dart';
import '../../services/cover_prompt_builder.dart';
import '../../theme/theme.dart';

///
/// 桌面挂在设计师面板底部，移动挂在页面底部常驻条里；判定逻辑只有这一份。
class CoverGenerateFooter extends ConsumerWidget {
  const CoverGenerateFooter({
    super.key,
    required this.novelId,
    required this.onGenerate,
  });

  final String novelId;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );
    final imageSelection = ref.watch(
      studioImageModelSelectionProvider(state.modelId),
    );
    if (state.generating) {
      return Column(
        children: [
          LinearProgressIndicator(
            value: state.totalCount == 0
                ? null
                : state.completedCount / state.totalCount,
            color: colors.accent,
            backgroundColor: colors.borderSubtle,
          ),
          const SizedBox(height: RevericSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: state.stopping ? null : controller.stop,
              icon: const RevericIcon(RevericIcons.stop_rounded, size: 15),
              label: Text(
                context.t(
                  state.stopping
                      ? LocaleKeys.editorCoverStoppingProgress
                      : LocaleKeys.editorCoverStopProgress,
                  namedArgs: {
                    'done': '${state.completedCount}',
                    'total': '${state.totalCount}',
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: RevericSpacing.xs),
          Text(
            context.t(
              state.stopping
                  ? LocaleKeys.editorCoverStoppingNote
                  : LocaleKeys.editorCoverStopNote,
            ),
            textAlign: TextAlign.center,
            style: typo.uiTiny.copyWith(color: colors.textSubtle),
          ),
        ],
      );
    }

    return Column(
      children: [
        CoverGenerateCountButton(
          novelId: novelId,
          enabled: !state.busy && imageSelection != null,

          onPressed: onGenerate,
        ),
        const SizedBox(height: RevericSpacing.xs),
        Text(
          context.t(LocaleKeys.editorCoverAiGeneratedNotice),
          textAlign: TextAlign.center,
          style: typo.uiTiny.copyWith(color: colors.textSubtle),
        ),
      ],
    );
  }
}

/// 出图张数与主操作合并成一条。
class CoverGenerateCountButton extends ConsumerWidget {
  const CoverGenerateCountButton({
    super.key,
    required this.novelId,
    required this.enabled,
    required this.onPressed,
    this.tooltip,
  });

  final String novelId;
  final bool enabled;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );
    final count = state.batchCount;
    final canDecrease = !state.busy && count > coverBatchCountMin;
    final canIncrease = !state.busy && count < coverBatchCountMax;
    final bg = enabled ? colors.accent : colors.accent.withValues(alpha: 0.4);
    final fg = enabled
        ? colors.onAccent
        : colors.onAccent.withValues(alpha: 0.7);
    final stepFg = colors.onAccent.withValues(alpha: enabled ? 0.9 : 0.55);

    final control = Material(
      color: bg,
      borderRadius: BorderRadius.circular(RevericRadius.button),
      child: SizedBox(
        height: RevericSizes.buttonHeight,
        width: double.infinity,
        child: Row(
          children: [
            IconButton(
              onPressed: canDecrease
                  ? () => controller.setBatchCount(count - 1)
                  : null,
              tooltip: null,
              style: IconButton.styleFrom(
                foregroundColor: stepFg,
                disabledForegroundColor: colors.onAccent.withValues(
                  alpha: 0.35,
                ),
                minimumSize: const Size(RevericSizes.buttonHeight, 0),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              icon: const RevericIcon(RevericIcons.remove, size: 16),
            ),
            Expanded(
              child: InkWell(
                onTap: enabled ? onPressed : null,
                borderRadius: BorderRadius.circular(RevericRadius.small),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RevericIcon(
                        RevericIcons.auto_awesome,
                        size: 16,
                        color: fg,
                      ),
                      const SizedBox(width: RevericSpacing.sm),
                      Flexible(
                        child: Text(
                          context.t(
                            LocaleKeys.editorCoverGenerateCount,
                            namedArgs: {'count': '$count'},
                          ),
                          style: typo.uiSemibold.copyWith(color: fg),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: canIncrease
                  ? () => controller.setBatchCount(count + 1)
                  : null,
              tooltip: null,
              style: IconButton.styleFrom(
                foregroundColor: stepFg,
                disabledForegroundColor: colors.onAccent.withValues(
                  alpha: 0.35,
                ),
                minimumSize: const Size(RevericSizes.buttonHeight, 0),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              icon: const RevericIcon(RevericIcons.add, size: 16),
            ),
          ],
        ),
      ),
    );

    if (tooltip == null || tooltip!.isEmpty) {
      return control;
    }
    return Tooltip(
      message: tooltip!,
      waitDuration: const Duration(milliseconds: 300),
      child: Listener(behavior: HitTestBehavior.opaque, child: control),
    );
  }
}
