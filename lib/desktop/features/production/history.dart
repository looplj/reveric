// 职责: 工具条「结果」弹层：列出视频每次生成的状态与结果，可切换采用、确认或重试。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/desktop/features/production/node_bar.dart
//   lib/desktop/features/production/image_history.dart
//   lib/desktop/features/production/popover.dart
//   lib/desktop/features/production/storage_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'package:reveric/shared/models/generation/task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/database/app_database.dart'
    show GenerationTask, GenerationTaskRequest;
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/video_tasks.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/ai/video/draft.dart';
import '../../../shared/services/ai/video/task_service.dart';
import '../../../shared/theme/theme.dart';
import 'node_card.dart' show ProductionAssetThumb;
import 'popover.dart';
import 'support.dart';
import 'draft_completion.dart';
import 'storage_dialog.dart';
import 'task_status.dart';

class ProductionHistory extends HookConsumerWidget {
  const ProductionHistory({
    super.key,
    required this.service,
    required this.node,
    required this.onUpload,
    required this.onPick,
    required this.onAdopted,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final VoidCallback onUpload;
  final VoidCallback onPick;
  final VoidCallback onAdopted;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = useStream(
      useMemoized(
        () => service.library.database.generationTaskDao.watchSource(
          novelId: service.novelId,
          sourceType: 'production_clip',
          sourceId: node.clipId!,
        ),
        [service, node.id, node.clipId],
      ),
    );
    final selected = useProductionAdopted(service, node.clipId!);
    final busy = useState(false);
    Future<void> run(Future<void> Function() action) async {
      if (busy.value) {
        return;
      }
      busy.value = true;
      await productionRun(context, action);
      if (context.mounted) {
        busy.value = false;
      }
    }

    /// 提交前需要上传本地参考素材而存储未配置时，先弹窗配置；取消返回 false。
    Future<bool> ensureStorage(
      VideoTaskService taskService,
      GenerationTask task,
    ) async {
      if (task.draftTaskId != null ||
          !await taskService.needsReferenceUpload(
            providerId: task.providerId,
            modelId: task.modelId,
            assetIds: task.videoInputs.map((input) => input.assetId),
          )) {
        return true;
      }
      return context.mounted &&
          await ensureReferenceStorage(
            context,
            ref.read(referenceStorageServiceProvider),
            providerId: task.providerId,
            modelId: task.modelId,
            inputs: task.videoInputs,
          );
    }

    Future<void> retry(GenerationTask task) async {
      if (tasks.data?.firstOrNull?.id == task.id) {
        await service.shots.setErrorDismissed(node.clipId!, false);
      }
      final taskService = await ref.read(videoTaskServiceProvider.future);
      if (task.path != null && task.errorCode == 'asset_registration_failed') {
        await taskService.retryResultRegistration(task.id);
      } else if (task.status == GenerationTaskStatus.saving) {
        await taskService.retryDownload(task.id);
      } else if (task.status == GenerationTaskStatus.reconciliation_required) {
        await taskService.refresh(task.id);
      } else {
        await taskService.resumeAfterConfigurationFixed(task.id);
      }
      await ref.read(productionResultServiceProvider).recover();
    }

    final list = tasks.data ?? const <GenerationTask>[];
    return ProductionResultsShell(
      count: list.length,
      image: false,
      failed: tasks.hasError,
      picked:
          list.any(
            (t) => canAdoptProductionTask(t) && t.resultAssetId == selected,
          )
          ? null
          : selected,
      service: service,
      onUpload: onUpload,
      onPick: onPick,
      rows: [
        for (var i = 0; i < list.length; i++)
          Builder(
            builder: (context) {
              final task = list[i];
              final result = task.resultAssetId;
              final inUse = canAdoptProductionTask(task) && result == selected;
              final status = task.status;
              final sourceDraft = list
                  .where((t) => t.id == task.draftTaskId)
                  .firstOrNull;
              final completion = task.draft
                  ? list
                        .where(
                          (t) =>
                              t.draftTaskId == task.id &&
                              t.status == GenerationTaskStatus.completed,
                        )
                        .firstOrNull
                  : null;
              final failed = {
                GenerationTaskStatus.failed,
                GenerationTaskStatus.expired,
                GenerationTaskStatus.cancelled,
                GenerationTaskStatus.action_required,
                GenerationTaskStatus.reconciliation_required,
              }.contains(status);
              final retryable =
                  status == GenerationTaskStatus.saving ||
                  status == GenerationTaskStatus.action_required ||
                  status == GenerationTaskStatus.reconciliation_required;
              return ProductionResultRow(
                service: service,
                assetId: result,
                failed: failed,
                run: list.length - i,
                status: status.name,
                tone: failed
                    ? ProductionResultTone.error
                    : status == GenerationTaskStatus.completed
                    ? ProductionResultTone.done
                    : ProductionResultTone.running,
                meta: [
                  productionResultTime(task.createdAt),
                  task.modelId,
                  '${task.videoRequest.durationSeconds}s',
                  task.videoRequest.resolution,
                ].join(' · '),
                tag: task.draft
                    ? ProductionResultTag.sample
                    : sourceDraft != null
                    ? ProductionResultTag.finalCut
                    : null,
                note: task.draft
                    ? completion != null
                          ? context.t(
                              LocaleKeys.productionDraftCompleted,
                              namedArgs: {
                                'n':
                                    '${list.length - list.indexOf(completion)}',
                              },
                            )
                          : task.isDraftExpired(DateTime.now())
                          ? context.t(LocaleKeys.productionDraftExpired)
                          : task.draftExpiresAt != null &&
                                status == GenerationTaskStatus.completed
                          ? productionDraftDeadline(context, task)
                          : null
                    : sourceDraft != null
                    ? context.t(
                        LocaleKeys.productionDraftSource,
                        namedArgs: {
                          'n': '${list.length - list.indexOf(sourceDraft)}',
                        },
                      )
                    : status == GenerationTaskStatus.prepared &&
                          task.videoInputs.isNotEmpty
                    ? context.t(LocaleKeys.productionUpload)
                    : null,
                error: failed ? task.errorMessage : null,
                inUse: inUse,
                actions: [
                  if (task.supportsDraftCompletion &&
                      canAdoptProductionTask(task) &&
                      completion == null)
                    ProductionDraftCompletion(
                      service: service,
                      task: task,
                      tasks: list,
                    ),
                  if (sourceDraft?.resultAssetId != null)
                    RevericButton.text(
                      label: context.t(LocaleKeys.productionViewDraft),
                      size: RevericButtonSize.compact,
                      onPressed: () => run(
                        () => previewProductionAsset(
                          context,
                          service,
                          sourceDraft!.resultAssetId!,
                        ),
                      ),
                    ),
                  if (canAdoptProductionTask(task) && !inUse)
                    RevericButton.secondary(
                      label: context.t(LocaleKeys.productionResultsSwitch),
                      size: RevericButtonSize.compact,
                      onPressed: busy.value
                          ? null
                          : () => run(() async {
                              await service.adoptGenerated(node.id, task.id);
                              onAdopted();
                            }),
                    ),
                  if (status == GenerationTaskStatus.prepared)
                    RevericButton.primary(
                      label: context.t(LocaleKeys.productionConfirm),
                      size: RevericButtonSize.compact,
                      onPressed: busy.value
                          ? null
                          : () => run(() async {
                              final taskService = await ref.read(
                                videoTaskServiceProvider.future,
                              );
                              if (!await ensureStorage(taskService, task)) {
                                return;
                              }
                              if (tasks.data?.firstOrNull?.id == task.id) {
                                await service.shots.setErrorDismissed(
                                  node.clipId!,
                                  false,
                                );
                              }
                              await taskService.submit(
                                task.id,
                                acknowledgeReferenceUpload: true,
                              );
                            }),
                    ),
                  if (retryable)
                    RevericButton.secondary(
                      label: context.t(LocaleKeys.commonRetry),
                      size: RevericButtonSize.compact,
                      onPressed: busy.value
                          ? null
                          : () => run(() => retry(task)),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}

/// 节点当前采用的结果资产。
String? useProductionAdopted(ProductionCanvasService service, String clipId) =>
    useStream(
      useMemoized(
        () =>
            (service.db.select(service.db.productionClips)
                  ..where((t) => t.id.equals(clipId)))
                .watchSingleOrNull()
                .map((row) => row?.adoptedAssetId),
        [service, clipId],
      ),
    ).data;

/// 当天只显示时分，跨天带上月日。
String productionResultTime(DateTime at) {
  final local = at.toLocal();
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(local.hour)}:${two(local.minute)}';
  return local.year == now.year &&
          local.month == now.month &&
          local.day == now.day
      ? time
      : '${two(local.month)}-${two(local.day)} $time';
}

enum ProductionResultTone { running, done, error }

/// 结果弹层外壳：标题、可滚动的结果行，以及底部的「导入 / 从资产库选择」。
class ProductionResultsShell extends StatelessWidget {
  const ProductionResultsShell({
    super.key,
    required this.count,
    required this.image,
    required this.failed,
    required this.picked,
    required this.service,
    required this.rows,
    required this.onUpload,
    required this.onPick,
  });
  final int count;
  final bool image;
  final bool failed;

  /// 采用的是上传或资产库选来的文件（不是这个节点生成的），单独列在最上面。
  final String? picked;
  final ProductionCanvasService service;
  final List<Widget> rows;
  final VoidCallback onUpload;
  final VoidCallback onPick;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    Widget hint(String text) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.xs,
        vertical: RevericSpacing.md,
      ),
      child: Text(text, style: typo.uiSmall.copyWith(color: colors.textMuted)),
    );
    return ProductionPopoverPanel(
      width: RevericSizes.productionResultsWidth,
      maxHeight: RevericSizes.productionResultsMaxHeight,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProductionPopoverHead(
            title: context.t(LocaleKeys.productionResultsTitle),
            detail: context.t(
              LocaleKeys.productionResultsSummary,
              namedArgs: {'count': '$count'},
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (picked != null)
                    _PickedRow(service: service, assetId: picked!),
                  if (failed)
                    hint(context.t(LocaleKeys.productionFailed))
                  else if (rows.isEmpty && picked == null)
                    hint(context.t(LocaleKeys.productionResultsEmpty)),
                  ...rows,
                ],
              ),
            ),
          ),
          const ProductionPopoverDivider(),
          ProductionPopoverItem(
            icon: RevericIcons.upload,
            label: context.t(LocaleKeys.commonImport),
            onTap: onUpload,
          ),
          ProductionPopoverItem(
            icon: RevericIcons.folder_outlined,
            label: context.t(
              image
                  ? LocaleKeys.productionResultsPickImage
                  : LocaleKeys.productionResultsPickVideo,
            ),
            onTap: onPick,
          ),
        ],
      ),
    );
  }
}

/// 一次生成：缩略、「第 n 次 + 状态」、时间与模型、错误和动作按钮。
enum ProductionResultTag { sample, finalCut }

class ProductionResultRow extends StatelessWidget {
  const ProductionResultRow({
    super.key,
    required this.service,
    required this.assetId,
    required this.failed,
    required this.run,
    required this.status,
    required this.tone,
    required this.meta,
    required this.inUse,
    required this.actions,
    this.note,
    this.error,
    this.tag,
  });
  final ProductionCanvasService service;
  final String? assetId;
  final bool failed;
  final int run;

  /// 视频的样片 / 成片标签，紧跟在「第 n 次」后面。
  final ProductionResultTag? tag;

  /// 任务状态名，对应 `screenplay.production.task.*`。
  final String status;
  final ProductionResultTone tone;
  final String meta;
  final bool inUse;
  final List<Widget> actions;
  final String? note;
  final String? error;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return _RowFrame(
      inUse: inUse,
      thumb: _ResultThumb(service: service, assetId: assetId, failed: failed),
      lines: [
        Text.rich(
          TextSpan(
            text: context.t(
              LocaleKeys.productionResultsRun,
              namedArgs: {'n': '$run'},
            ),
            children: [
              if (tag != null) ...[
                const TextSpan(text: '  '),
                TextSpan(
                  text: context.t(switch (tag!) {
                    ProductionResultTag.sample =>
                      LocaleKeys.productionSampleTag,
                    ProductionResultTag.finalCut =>
                      LocaleKeys.productionFinalTag,
                  }),
                  style: typo.uiTinySemibold.copyWith(
                    color: switch (tag!) {
                      ProductionResultTag.sample => colors.warningText,
                      ProductionResultTag.finalCut => colors.success,
                    },
                  ),
                ),
              ],
              const TextSpan(text: '  '),
              TextSpan(
                text: context.t(productionTaskLabelKey(status)),
                style: typo.uiTinySemibold.copyWith(
                  color: switch (tone) {
                    ProductionResultTone.error => colors.error,
                    ProductionResultTone.done => colors.success,
                    ProductionResultTone.running => colors.accentWarm,
                  },
                ),
              ),
            ],
          ),
          style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
        ),
        Text(
          meta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: typo.uiTiny.copyWith(color: colors.textMuted),
        ),
        if (note != null)
          Text(note!, style: typo.uiTiny.copyWith(color: colors.textMuted)),
        if (error != null && error!.isNotEmpty)
          Text(
            error!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: typo.uiTiny.copyWith(color: colors.error),
          ),
      ],
      actions: [if (inUse) const _InUseBadge(), ...actions],
    );
  }
}

class _PickedRow extends HookWidget {
  const _PickedRow({required this.service, required this.assetId});
  final ProductionCanvasService service;
  final String assetId;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final asset = useProductionAsset(service, assetId);
    return _RowFrame(
      inUse: true,
      thumb: _ResultThumb(service: service, assetId: assetId, failed: false),
      lines: [
        Text(
          asset?.name ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
        ),
      ],
      actions: const [_InUseBadge()],
    );
  }
}

class _RowFrame extends StatelessWidget {
  const _RowFrame({
    required this.inUse,
    required this.thumb,
    required this.lines,
    required this.actions,
  });
  final bool inUse;
  final Widget thumb;
  final List<Widget> lines;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.xs),
      decoration: BoxDecoration(
        color: inUse ? colors.surfaceContainer : null,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
      child: Row(
        children: [
          thumb,
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: lines,
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: RevericSpacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              spacing: RevericSpacing.xxs,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}

class _InUseBadge extends StatelessWidget {
  const _InUseBadge();
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RevericIcon(RevericIcons.seal_check, size: 11, color: colors.accent),
        const SizedBox(width: 3),
        Text(
          context.t(LocaleKeys.productionResultsInUse),
          style: typo.uiTinySemibold.copyWith(color: colors.accent),
        ),
      ],
    );
  }
}

/// 结果缩略：有结果时可点开预览；没有结果时按失败 / 进行中画占位图标。
class _ResultThumb extends HookWidget {
  const _ResultThumb({
    required this.service,
    required this.assetId,
    required this.failed,
  });
  final ProductionCanvasService service;
  final String? assetId;
  final bool failed;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final radius = BorderRadius.circular(RevericRadius.small);
    final asset = useProductionAsset(service, assetId);
    return SizedBox(
      width: 34,
      height: 60,
      child: asset?.path == null
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceDim,
                borderRadius: radius,
                border: Border.all(color: colors.borderInput),
              ),
              child: Center(
                child: RevericIcon(
                  failed
                      ? RevericIcons.warning_circle
                      : RevericIcons.circle_notch,
                  size: 13,
                  color: colors.textSubtle,
                ),
              ),
            )
          : Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: radius,
                onTap: () => productionRun(
                  context,
                  () => previewProductionAsset(context, service, asset.id),
                ),
                child: ClipRRect(
                  borderRadius: radius,
                  child: ProductionAssetThumb(
                    service: service,
                    filePath: asset!.path,
                  ),
                ),
              ),
            ),
    );
  }
}
