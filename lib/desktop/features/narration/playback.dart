// 职责: 展示当前朗读文本、段落进度和播放控制，并管理播放界面的资源生命周期。
// 关联文件:
//   lib/desktop/features/narration/player.dart
//   lib/desktop/features/narration/setup.dart
//   lib/shared/services/screenplay/narration_orchestrator.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/reading.json
//   assets/translations/zh-CN/reading.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/performance.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/components/reveric_select.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/narration.dart';
import '../../../shared/providers/narration.dart';
import '../../../shared/services/screenplay/narration_orchestrator.dart';
import '../../../shared/theme/theme.dart';
import 'errors.dart';
import 'player.dart';
import 'setup.dart';

class NarrationPlayback extends HookConsumerWidget {
  const NarrationPlayback({
    super.key,
    required this.source,
    required this.plan,
    required this.onBack,
  });
  final NarrationInput source;
  final NarrationPlan plan;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(narrationServiceProvider);
    final createPlayer = ref.watch(narrationPlayerFactoryProvider);
    final controller = useMemoized(
      () => NarrationOrchestrator()
        ..configure(
          segments: plan.segments,
          generate: (segment, abort) =>
              service.generate(plan.settings, segment, abort),
          createPlayer: createPlayer,
        ),
      [plan, service, createPlayer],
    );
    useEffect(() {
      Future<void>(controller.play);
      return controller.dispose;
    }, [controller]);
    useOnAppLifecycleStateChange((previous, next) {
      if (next == AppLifecycleState.hidden ||
          next == AppLifecycleState.paused ||
          next == AppLifecycleState.detached) {
        controller.pause();
      }
    });
    useListenable(controller);
    final segment = controller.segments[controller.index];
    final typo = RevericTheme.typographyOf(context);
    final colors = RevericTheme.colorsOf(context);
    final role =
        source.characterNames[segment.characterId] ??
        context.t(LocaleKeys.narrationNarrator);
    final completedLabel = source is NovelNarrationSource
        ? LocaleKeys.readingNarrationComplete
        : LocaleKeys.narrationComplete;
    final status = controller.error != null
        ? narrationErrorText(context, controller.error!)
        : context.t(
            controller.loading
                ? LocaleKeys.narrationGenerating
                : controller.completed
                ? completedLabel
                : controller.playing
                ? LocaleKeys.narrationPlaying
                : LocaleKeys.narrationPaused,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                role,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSemibold.copyWith(color: colors.accent),
              ),
            ),
            Text(
              context.t(
                LocaleKeys.narrationProgress,
                namedArgs: {
                  'current': '${controller.index + 1}',
                  'total': '${controller.segments.length}',
                },
              ),
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.md),
        ClipRRect(
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          child: LinearProgressIndicator(
            minHeight: 3,
            value: controller.completed
                ? 1
                : controller.index / controller.segments.length,
            backgroundColor: colors.surfaceDim,
            color: colors.accent,
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            // 短台词在区域内居中，长段落从顶部开始滚动。
            builder: (context, constraints) => SingleChildScrollView(
              key: ValueKey(controller.index),
              padding: const EdgeInsets.symmetric(vertical: RevericSpacing.x4l),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - RevericSpacing.x4l * 2,
                ),
                child: Center(
                  child: SelectableText(
                    segment.text,
                    textAlign: TextAlign.center,
                    style: typo.heading2.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Text(
          status,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: typo.uiSmall.copyWith(
            color: controller.error != null
                ? colors.warningText
                : colors.textMuted,
          ),
        ),
        const SizedBox(height: RevericSpacing.lg),
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: RevericButton.text(
                  label: context.t(LocaleKeys.narrationChangeVoices),
                  onPressed: onBack,
                ),
              ),
            ),
            RevericIconButton(
              icon: RevericIcons.skip_back,
              tooltip: context.t(LocaleKeys.narrationPrevious),
              onPressed: controller.index == 0
                  ? null
                  : () => controller.jump(controller.index - 1),
            ),
            const SizedBox(width: RevericSpacing.lg),
            RevericButton.primary(
              label: context.t(
                controller.playing
                    ? LocaleKeys.commonPause
                    : controller.error != null
                    ? LocaleKeys.commonRetry
                    : LocaleKeys.commonPlay,
              ),
              icon: controller.playing
                  ? RevericIcons.pause
                  : RevericIcons.play_arrow,
              onPressed: controller.playing
                  ? controller.pause
                  : () => controller.play(retry: controller.error != null),
            ),
            const SizedBox(width: RevericSpacing.lg),
            RevericIconButton(
              icon: RevericIcons.skip_forward,
              tooltip: context.t(LocaleKeys.narrationNext),
              onPressed: controller.index + 1 >= controller.segments.length
                  ? null
                  : () => controller.jump(controller.index + 1),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Tooltip(
                  message: context.t(LocaleKeys.narrationSpeed),
                  child: SizedBox(
                    width: RevericSizes.fieldHeight * 2.5,
                    child: RevericSelect<double>(
                      value: controller.speed,
                      dropUp: true,
                      items: [
                        for (final speed in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                          RevericSelectItem(value: speed, label: '$speed×'),
                      ],
                      onChanged: controller.setSpeed,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
