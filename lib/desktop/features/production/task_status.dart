// 职责: 在画布、列表与分镜表展示采用情况和当前任务反馈，失败时给出一个解决动作并持久化关闭提醒的选择。
// 关联文件:
//   lib/shared/services/storyboard/service.dart
//   lib/shared/services/production/image_service.dart
//   lib/shared/database/daos/generation_task_dao.dart
//   lib/desktop/features/production/region.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/database/app_database.dart' as app;
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/services/storyboard/service.dart';
import '../../../shared/theme/canvas_colors.dart';
import '../../../shared/theme/theme.dart';
import 'support.dart';

typedef _TaskFeedback = ({
  String id,
  String status,
  String? errorCode,
  String? error,
  bool resultReady,
  bool pendingAudioPrediction,
  bool adoptedDraft,
  bool completingDraft,
});

/// 任务状态的文案 key。上传、提交、生成、保存结果对用户都是同一件事，统一显示「生成中」。
String productionTaskLabelKey(String status) =>
    'screenplay.production.task.${switch (status) {
      'uploading' || 'submitting' || 'saving' => 'running',
      _ => status,
    }}';

/// 结果已生成、只差保存的任务；重试不会再次提交生成。
typedef ProductionSaveRetry = ({String taskId, String status, bool image});

/// 失败提醒上的动作，由持有画布选中状态的制作区域提供。
class ProductionTaskActions {
  const ProductionTaskActions({
    required this.openResults,
    required this.retrySave,
  });

  /// 在画布上选中这个片段的节点并展开「结果」。
  final Future<void> Function(String clipId) openResults;
  final Future<void> Function(ProductionSaveRetry task) retrySave;
}

class ProductionTaskStatus extends HookWidget {
  const ProductionTaskStatus({
    super.key,
    required this.shots,
    required this.database,
    required this.novelId,
    required this.clipId,
    this.actions,
    this.compact = false,
    this.floating = false,
  });
  final StoryboardService shots;
  final app.AppDatabase database;
  final String novelId;
  final String clipId;

  /// 为 null 时失败提醒只能关闭，不给解决动作。
  final ProductionTaskActions? actions;
  final bool compact;

  /// 画布节点用：铺满画面，不写「已采用 / 未采用」。生成中盖住整个画面，
  /// 其余任务反馈在左下角显示成一枚浮签。
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final clipState = useStream(
      useMemoized(
        () => (shots.database.select(
          shots.database.productionClips,
        )..where((t) => t.id.equals(clipId))).watchSingleOrNull(),
        [shots.database, clipId],
      ),
      preserveState: false,
    );
    final clip = clipState.data;
    final tasks = useStream<_TaskFeedback?>(
      useMemoized(
        () {
          if (clip == null) {
            return const Stream<_TaskFeedback?>.empty();
          }
          return database.generationTaskDao
              .watchSource(
                novelId: novelId,
                sourceType: 'production_clip',
                sourceId: clipId,
              )
              .map((rows) {
                final task = rows.firstOrNull;
                return task == null
                    ? null
                    : (
                        id: task.id,
                        status: task.status.name,
                        errorCode: task.errorCode,
                        error: task.errorMessage,
                        resultReady: task.resultAssetId != null,
                        pendingAudioPrediction:
                            task.kind == app.GenerationKind.audio &&
                            task.providerTaskId != null &&
                            task.outputUrl == null &&
                            task.outputHash == null,
                        adoptedDraft: rows.any(
                          (row) =>
                              row.draft &&
                              row.resultAssetId != null &&
                              row.resultAssetId == clip.adoptedAssetId,
                        ),
                        completingDraft: task.draftTaskId != null,
                      );
              });
        },
        [
          shots.database,
          database,
          novelId,
          clipId,
          clip?.kind,
          clip?.adoptedAssetId,
        ],
      ),
      preserveState: false,
    );
    final busy = useState(false);
    if (clipState.hasError || tasks.hasError) {
      return Text(context.t(LocaleKeys.productionFailed));
    }
    if (clip == null || clip.deletedAt != notDeletedSentinel) {
      return const SizedBox.shrink();
    }
    final task = tasks.data;
    final image = clip.kind != 'video';
    // 结果已生成、只是没存下来：重新保存即可，不再计费。
    final saveFailure =
        task != null &&
        (image
            ? task.status == 'action_required' && !task.pendingAudioPrediction
            : (task.status == 'saving' && task.errorCode != null) ||
                  (task.status == 'action_required' &&
                      task.errorCode == 'asset_registration_failed'));
    final refetch = saveFailure && image
        ? productionImageRefetch(task.errorCode)
        : null;
    final failure =
        task != null &&
        (saveFailure ||
            const {
              'failed',
              'expired',
              'action_required',
              'reconciliation_required',
              'submission_unknown',
            }.contains(task.status));
    final pendingResult =
        task?.status == 'completed' &&
        task!.resultReady &&
        clip.lastAppliedGenerationTaskId != task.id;
    final showTask =
        task != null &&
        task.status != 'cancelled' &&
        !(task.status == 'completed' && task.resultReady && !pendingResult) &&
        !(failure && clip.errorDismissed);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final textStyle = compact ? typo.uiTinySemibold : typo.uiSmall;
    final tone = saveFailure
        ? colors.warningText
        : failure
        ? colors.error
        : colors.accent;
    final label = task == null
        ? ''
        : context.t(
            pendingResult
                ? LocaleKeys.productionResultPending
                : refetch != null
                ? 'screenplay.production.task.${task.errorCode}'
                : saveFailure
                ? LocaleKeys.productionResultSaveFailed
                : task.completingDraft && !failure && task.status != 'completed'
                ? LocaleKeys.productionDraftCompletionPending
                : productionTaskLabelKey(
                    task.status == 'completed' ? 'running' : task.status,
                  ),
          );
    Future<void> act(Future<void> Function() action) async {
      if (busy.value) {
        return;
      }
      busy.value = true;
      try {
        await action();
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    final error =
        image &&
            {
              'interrupted',
              'audio_submission_unknown',
            }.contains(task?.errorCode)
        ? context.t(
            clip.kind == 'audio'
                ? LocaleKeys.productionAudioInterrupted
                : LocaleKeys.productionImageInterrupted,
          )
        : task?.errorCode == 'audio_output_unavailable'
        ? context.t(LocaleKeys.productionAudioOutputUnavailable)
        : refetch != null
        ? context.t(refetch.error)
        : task?.error;
    final adoptedDraft = task?.adoptedDraft ?? false;
    if (floating && !showTask && !adoptedDraft) {
      return const SizedBox.shrink();
    }
    if (floating &&
        showTask &&
        !failure &&
        !pendingResult &&
        task.status != 'prepared') {
      return _GeneratingCover(
        label: label,
        note: adoptedDraft ? context.t(LocaleKeys.productionDraftLabel) : null,
      );
    }
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!floating)
          Text(
            context.t(
              clip.adoptedAssetId == null
                  ? LocaleKeys.productionUnselected
                  : LocaleKeys.productionSelected,
            ),
            style: textStyle.copyWith(color: colors.textMuted),
          ),
        if (adoptedDraft) ...[
          if (!floating) const SizedBox(width: RevericSpacing.xs),
          Text(
            context.t(LocaleKeys.productionDraftLabel),
            style: textStyle.copyWith(color: colors.textMuted),
          ),
        ],
        if (showTask) ...[
          if (!floating || adoptedDraft)
            const SizedBox(width: RevericSpacing.xs),
          Flexible(
            child: Tooltip(
              message: failure
                  ? [
                      if (error != null && error.isNotEmpty) error,
                      context.t(
                        clip.adoptedAssetId == null
                            ? LocaleKeys.productionFailureNoResult
                            : LocaleKeys.productionFailureKeepsResult,
                      ),
                    ].join('\n')
                  : label,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (failure) ...[
                    RevericIcon(
                      RevericIcons.warning_circle,
                      size: 12,
                      color: tone,
                    ),
                    const SizedBox(width: RevericSpacing.xxs),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle.copyWith(color: tone),
                    ),
                  ),
                  if (failure && actions != null) ...[
                    Text(
                      ' · ',
                      style: textStyle.copyWith(
                        color: tone.withValues(alpha: .5),
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    _AlertAction(
                      label: context.t(
                        refetch != null
                            ? refetch.action
                            : saveFailure
                            ? LocaleKeys.productionRetrySave
                            : LocaleKeys.productionViewReason,
                      ),
                      style: textStyle.copyWith(color: tone),
                      onTap: busy.value
                          ? null
                          : () => act(
                              () => saveFailure
                                  ? actions!.retrySave((
                                      taskId: task.id,
                                      status: task.status,
                                      image: image,
                                    ))
                                  : actions!.openResults(clipId),
                            ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (failure)
            RevericIconButton(
              icon: RevericIcons.close,
              tooltip: context.t(LocaleKeys.productionDismissFailure),
              onPressed: busy.value
                  ? null
                  : () => act(
                      () => productionRun(
                        context,
                        () => shots.setErrorDismissed(clipId, true),
                      ),
                    ),
            ),
        ],
      ],
    );
    if (!floating) {
      return row;
    }
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.sm),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh.withValues(alpha: .94),
            borderRadius: BorderRadius.circular(RevericRadius.medium),
            border: Border.all(color: colors.borderSubtle),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.sm,
              vertical: RevericSpacing.xxs,
            ),
            child: row,
          ),
        ),
      ),
    );
  }
}

/// 生成中盖住整个画面：比角落浮签醒目，也挡住生成期间不该点的上传入口。
/// 画布上可能同时有很多节点在生成，用静态图标，不给每个节点挂循环动画。
class _GeneratingCover extends StatelessWidget {
  const _GeneratingCover({required this.label, this.note});
  final String label;

  /// 画面当前仍是已采用的样片时，在下方注明。
  final String? note;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: canvasGlassFill(colors, raised: true)),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.auto_awesome,
              size: 20,
              color: colors.accent,
            ),
            const SizedBox(height: RevericSpacing.xs),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiSmallSemibold.copyWith(color: colors.accent),
            ),
            if (note != null)
              Text(
                note!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiTiny.copyWith(color: colors.textMuted),
              ),
          ],
        ),
      ),
    );
  }
}

/// 失败提醒里的行内文字动作：沿用提醒的语义色，下划线在悬停时加深。
class _AlertAction extends HookWidget {
  const _AlertAction({
    required this.label,
    required this.style,
    required this.onTap,
  });
  final String label;
  final TextStyle style;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final hovered = useState(false);
    final color = style.color!;
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: MouseRegion(
        cursor: onTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onEnter: (_) => hovered.value = true,
        onExit: (_) => hovered.value = false,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Text(
            label,
            maxLines: 1,
            style: style.copyWith(
              decoration: TextDecoration.underline,
              decorationColor: hovered.value && onTap != null
                  ? color
                  : color.withValues(alpha: .4),
            ),
          ),
        ),
      ),
    );
  }
}
