// 职责: 样片转成片 — 结果行和节点工具条上的「生成成片」入口、提交前确认，以及节点在用样片时的标记。
// 关联文件:
//   lib/desktop/features/production/history.dart
//   lib/desktop/features/production/node_bar.dart
//   lib/shared/services/production/generate_orchestrator.dart
//   lib/shared/services/ai/video/draft.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'dart:async';
import 'package:collection/collection.dart';
import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../shared/components/reveric_badge.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/database/daos/generation_task_dao.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/video_tasks.dart';
import '../../../shared/services/ai/video/draft.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/generate_orchestrator.dart';
import '../../../shared/theme/theme.dart';
import 'history.dart' show productionResultTime;
import 'spec_panel.dart' show productionResolutionLabel;
import 'support.dart';

String productionDraftDeadline(BuildContext context, GenerationTask task) =>
    context.t(
      LocaleKeys.productionDraftDeadline,
      namedArgs: {
        'date': DateFormat.yMd().add_Hm().format(
          task.draftExpiresAt!.toLocal(),
        ),
      },
    );

/// 先确认再按样片提交成片；取消或提交失败都不改动任务。
Future<void> completeProductionDraft(
  BuildContext context,
  WidgetRef ref, {
  required ProductionCanvasService service,
  required GenerationTask task,
  required int run,
}) async {
  final confirmed = await showRevericDialog<bool>(
    context: context,
    builder: (_) =>
        _CompleteDraftDialog(service: service, task: task, run: run),
  );
  if (confirmed != true || !context.mounted) {
    return;
  }
  await productionRun(context, () async {
    final taskService = await ref.read(videoTaskServiceProvider.future);
    await ProductionGenerateOrchestrator().completeDraft(
      service,
      taskService,
      task.id,
    );
  });
}

/// 成片沿用样片当时的快照；出样片后片段的提示词、输入或规格改过时提示一句。
class _CompleteDraftDialog extends HookWidget {
  const _CompleteDraftDialog({
    required this.service,
    required this.task,
    required this.run,
  });
  final ProductionCanvasService service;
  final GenerationTask task;
  final int run;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final changed = useFuture(
      useMemoized(() => _changedSinceDraft(service, task), [task.id]),
    ).data;
    final request = task.videoRequest;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ),
          Text(
            value,
            style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
          ),
        ],
      ),
    );
    return RevericDialog(
      title: context.t(LocaleKeys.productionCompleteDraft),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.t(
              LocaleKeys.productionCompleteSource,
              namedArgs: {
                'n': '$run',
                'time': productionResultTime(task.createdAt),
              },
            ),
            style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
          ),
          if (task.draftExpiresAt != null)
            Text(
              productionDraftDeadline(context, task),
              style: typo.uiTiny.copyWith(color: colors.textMuted),
            ),
          const SizedBox(height: RevericSpacing.md),
          row(
            context.t(LocaleKeys.productionCompleteInputs),
            context.t(LocaleKeys.productionCompleteInputsValue),
          ),
          row(
            context.t(LocaleKeys.storyboardDuration),
            '${request.durationSeconds}',
          ),
          row(context.t(LocaleKeys.storyboardRatio), request.ratio),
          row(
            context.t(LocaleKeys.storyboardResolution),
            productionResolutionLabel(
              task.draftCapabilities!.completionResolution,
            ),
          ),
          if (changed == true) ...[
            const SizedBox(height: RevericSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: RevericIcon(
                    RevericIcons.warning_circle,
                    size: 12,
                    color: colors.warningText,
                  ),
                ),
                const SizedBox(width: RevericSpacing.xs),
                Expanded(
                  child: Text(
                    context.t(LocaleKeys.productionCompleteChanged),
                    style: typo.uiTiny.copyWith(color: colors.warningText),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        RevericButton.text(
          label: context.t(LocaleKeys.commonCancel),
          onPressed: () => Navigator.of(context).pop(false),
        ),
        RevericButton.primary(
          label: context.t(LocaleKeys.productionCompleteDraft),
          icon: RevericIcons.auto_awesome,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}

/// 用片段当前配置按样片规格重新组装一次请求，与样片提交的快照比较。
/// 组装失败（如输入已失效）也算改过。
Future<bool> _changedSinceDraft(
  ProductionCanvasService service,
  GenerationTask task,
) async {
  final db = service.db;
  final node =
      await (db.select(db.canvasNodes)..where(
            (t) =>
                t.refType.equals(canvasNodeRefTypeProductionClip) &
                t.refId.equals(task.sourceId) &
                t.deletedAt.equals(notDeletedSentinel),
          ))
          .getSingleOrNull();
  if (node == null) {
    return false;
  }
  try {
    final current = await ProductionGenerateOrchestrator().preview(
      service,
      node.id,
      draft: true,
    );
    final sample = task.videoRequest;
    final now = current.request;
    return now.modelId != sample.modelId ||
        now.prompt != sample.prompt ||
        now.ratio != sample.ratio ||
        now.durationSeconds != sample.durationSeconds ||
        !const ListEquality<String>().equals(
          [for (final input in current.inputs) input.assetId],
          [for (final input in task.videoInputs) input.assetId],
        );
  } catch (_) {
    return true;
  }
}

/// 结果行和节点工具条上的「生成成片」：过期、已有成片在生成、片段忙时禁用并说明原因。
class ProductionDraftCompletion extends HookConsumerWidget {
  const ProductionDraftCompletion({
    super.key,
    required this.service,
    required this.task,
    required this.tasks,
    this.bar = false,
  });
  final ProductionCanvasService service;
  final GenerationTask task;

  /// 同一片段的生成记录，新的在前。
  final List<GenerationTask> tasks;

  /// 节点工具条里用文字按钮，结果行里用次要按钮。
  final bool bar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = useState(false);
    final clock = useState(DateTime.now());
    final lifecycle = useAppLifecycleState();
    final deadline = task.draftExpiresAt;
    useEffect(() {
      final remaining = deadline?.difference(DateTime.now());
      if (remaining == null || remaining.isNegative) {
        return null;
      }
      final timer = Timer(remaining, () => clock.value = DateTime.now());
      return timer.cancel;
    }, [deadline, lifecycle]);
    final expired =
        task.isDraftExpired(clock.value) || task.isDraftExpired(DateTime.now());
    final active = tasks
        .where((t) => t.draftTaskId == task.id && !t.status.isTerminal)
        .firstOrNull;
    final blocked = busy.value || tasks.any(GenerationTaskDao.blocksSource);
    final unavailable =
        task.providerTaskId?.trim().isNotEmpty != true || deadline == null;
    final label = context.t(
      expired
          ? LocaleKeys.productionDraftExpired
          : active != null
          ? LocaleKeys.productionDraftCompletionPending
          : LocaleKeys.productionCompleteDraft,
    );
    final onPressed = expired || unavailable || active != null || blocked
        ? null
        : () async {
            if (busy.value) {
              return;
            }
            busy.value = true;
            await completeProductionDraft(
              context,
              ref,
              service: service,
              task: task,
              run: tasks.length - tasks.indexOf(task),
            );
            if (context.mounted) {
              busy.value = false;
            }
          };
    return Tooltip(
      message: context.t(
        expired
            ? LocaleKeys.productionDraftExpiredHint
            : active != null
            ? LocaleKeys.productionDraftPendingHint
            : unavailable
            ? LocaleKeys.productionDraftUnavailable
            : blocked
            ? LocaleKeys.productionGenerateBusy
            : LocaleKeys.productionDraftCompletionHint,
      ),
      child: bar
          ? RevericButton.text(
              label: label,
              icon: expired || active != null
                  ? null
                  : RevericIcons.auto_awesome,
              size: RevericButtonSize.compact,
              loading: busy.value,
              onPressed: onPressed,
            )
          : RevericButton.secondary(
              label: label,
              size: RevericButtonSize.compact,
              loading: busy.value,
              onPressed: onPressed,
            ),
    );
  }
}

/// 节点工具条：标记当前采用的样片，并就地提供「生成成片」。
class ProductionDraftBadge extends HookWidget {
  const ProductionDraftBadge({
    super.key,
    required this.service,
    required this.clip,
  });
  final ProductionCanvasService service;
  final ProductionClipRow clip;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final tasks =
        useStream(
          useMemoized(
            () => service.library.database.generationTaskDao.watchSource(
              novelId: service.novelId,
              sourceType: 'production_clip',
              sourceId: clip.id,
            ),
            [service, clip.id],
          ),
        ).data ??
        const <GenerationTask>[];
    final draft = adoptedVideoDraft(tasks, clip.adoptedAssetId);
    if (draft == null) {
      return const SizedBox.shrink();
    }
    final completed =
        draft.completion?.status == GenerationTaskStatus.completed;
    return Padding(
      padding: const EdgeInsets.only(left: RevericSpacing.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: draft.task.draftCapabilities == null
                ? context.t(LocaleKeys.productionDraftSnapshotMissing)
                : context.t(LocaleKeys.productionDraftLabel),
            child: RevericBadge(
              label: context.t(LocaleKeys.productionDraftLabel),
              color: colors.warningText,
            ),
          ),
          if (!completed && draft.task.supportsDraftCompletion)
            ProductionDraftCompletion(
              service: service,
              task: draft.task,
              tasks: tasks,
              bar: true,
            ),
        ],
      ),
    );
  }
}

/// 分镜导出前的提醒：列出仍在用样片的分镜和成片期限，可逐条生成成片；返回 true 时照样导出。
Future<bool> confirmProductionDraftExport(
  BuildContext context, {
  required ProductionCanvasService service,
  required List<({ProductionClipRow clip, String label})> clips,
}) async =>
    await showRevericDialog<bool>(
      context: context,
      builder: (context) => RevericDialog(
        title: context.t(
          LocaleKeys.productionExportSamplesTitle,
          namedArgs: {'count': '${clips.length}'},
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in clips)
              _DraftExportRow(
                service: service,
                clip: item.clip,
                label: item.label,
              ),
          ],
        ),
        actions: [
          RevericButton.text(
            label: context.t(LocaleKeys.commonCancel),
            onPressed: () => Navigator.of(context).pop(false),
          ),
          RevericButton.primary(
            label: context.t(LocaleKeys.productionExportAnyway),
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    ) ==
    true;

class _DraftExportRow extends HookWidget {
  const _DraftExportRow({
    required this.service,
    required this.clip,
    required this.label,
  });
  final ProductionCanvasService service;
  final ProductionClipRow clip;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final tasks =
        useStream(
          useMemoized(
            () => service.library.database.generationTaskDao.watchSource(
              novelId: service.novelId,
              sourceType: 'production_clip',
              sourceId: clip.id,
            ),
            [service, clip.id],
          ),
        ).data ??
        const <GenerationTask>[];
    final draft = adoptedVideoDraft(tasks, clip.adoptedAssetId);
    final completion = draft?.completion;
    final status = draft == null
        ? null
        : completion?.status == GenerationTaskStatus.completed
        ? context.t(
            LocaleKeys.productionDraftCompleted,
            namedArgs: {'n': '${tasks.length - tasks.indexOf(completion!)}'},
          )
        : draft.task.isDraftExpired(DateTime.now())
        ? context.t(LocaleKeys.productionDraftExpired)
        : draft.task.draftExpiresAt == null
        ? null
        : productionDraftDeadline(context, draft.task);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$label · ${clip.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (status != null)
                  Text(
                    status,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
              ],
            ),
          ),
          if (draft != null &&
              completion?.status != GenerationTaskStatus.completed &&
              draft.task.supportsDraftCompletion)
            ProductionDraftCompletion(
              service: service,
              task: draft.task,
              tasks: tasks,
            ),
        ],
      ),
    );
  }
}
