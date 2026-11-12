// 职责: 节点工具条「结果」弹层的图片版：列出每次生成的状态与结果，可切换采用、重试或取消。
// 关联文件:
//   lib/shared/providers/production_images.dart
//   lib/desktop/features/production/history.dart
//   lib/desktop/features/production/node_bar.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/database/app_database.dart'
    show GenerationTask, GenerationTaskRequest;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/production_images.dart';
import '../../../shared/services/production/canvas_service.dart';
import 'history.dart';
import 'image_candidates.dart';
import 'support.dart';

class ProductionImageHistory extends HookConsumerWidget {
  const ProductionImageHistory({
    super.key,
    required this.service,
    required this.node,
    required this.path,
    required this.onUpload,
    required this.onPick,
    required this.onAdopted,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final String path;
  final VoidCallback onUpload;
  final VoidCallback onPick;
  final VoidCallback onAdopted;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(imageTaskServiceProvider);
    final runs = useStream(
      useMemoized(
        () => jobs.watchSource(
          novelId: service.novelId,
          sourceType: 'production_clip',
          sourceId: node.clipId!,
        ),
        [jobs, node.clipId],
      ),
    );
    final selected = useProductionAdopted(service, node.clipId!);
    final list = runs.data ?? const <GenerationTask>[];
    return ProductionResultsShell(
      count: list.length,
      image: true,
      failed: runs.hasError,
      picked:
          list.any(
            (r) =>
                canAdoptProductionTask(r) &&
                r.resultAssetIds.contains(selected),
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
              final run = list[i];
              final result = run.resultAssetId;
              final inUse =
                  canAdoptProductionTask(run) &&
                  run.resultAssetIds.contains(selected);
              final failed = [
                'failed',
                'cancelled',
                'action_required',
              ].contains(run.status.name);
              final refetch = run.status.name == 'action_required'
                  ? productionImageRefetch(run.errorCode)
                  : null;
              final row = ProductionResultRow(
                service: service,
                assetId: result,
                failed: failed,
                run: list.length - i,
                status: refetch != null ? run.errorCode! : run.status.name,
                tone: failed
                    ? ProductionResultTone.error
                    : run.status.name == 'completed'
                    ? ProductionResultTone.done
                    : ProductionResultTone.running,
                meta: [
                  productionResultTime(run.createdAt),
                  run.modelId,
                ].join(' · '),
                error: run.errorCode == 'interrupted'
                    ? context.t(LocaleKeys.productionImageInterrupted)
                    : refetch != null
                    ? context.t(refetch.error)
                    : run.errorMessage,
                inUse: inUse,
                actions: [
                  if (canAdoptProductionTask(run) &&
                      !inUse &&
                      run.resultAssetIds.length == 1)
                    RevericButton.secondary(
                      label: context.t(LocaleKeys.productionResultsSwitch),
                      size: RevericButtonSize.compact,
                      onPressed: () => productionRun(context, () async {
                        await service.adoptGenerated(node.id, run.id);
                        onAdopted();
                      }),
                    ),
                  if (run.status.name == 'action_required')
                    RevericButton.secondary(
                      label: context.t(
                        refetch?.action ?? LocaleKeys.commonRetry,
                      ),
                      size: RevericButtonSize.compact,
                      onPressed: () => productionRun(
                        context,
                        () => jobs.retrySaveOutput(run.id),
                      ),
                    ),
                  if ([
                    'prepared',
                    'running',
                    'saving',
                    'action_required',
                  ].contains(run.status.name))
                    RevericButton.text(
                      label: context.t(LocaleKeys.commonCancel),
                      size: RevericButtonSize.compact,
                      onPressed: () =>
                          productionRun(context, () => jobs.cancel(run.id)),
                    ),
                ],
              );
              if (run.resultAssetIds.length <= 1) {
                return row;
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  row,
                  ProductionImageCandidates(
                    service: service,
                    task: run,
                    selected: selected,
                    onAdopt: (assetId) async {
                      await service.adoptGenerated(
                        node.id,
                        run.id,
                        assetId: assetId,
                      );
                      onAdopted();
                    },
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}
