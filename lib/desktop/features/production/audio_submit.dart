// 职责: 保存音频草稿后直接提交生成，并管理圆形生成 / 取消键的状态。
// 关联文件:
//   lib/shared/providers/production_audio.dart
//   lib/shared/services/production/audio_generate_orchestrator.dart
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
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/database/daos/generation_task_dao.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/production_audio.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/audio_generate_orchestrator.dart';
import '../../../shared/theme/theme.dart';
import 'popover.dart';
import 'support.dart';
import 'task_status.dart';

class ProductionAudioSubmit extends HookConsumerWidget {
  const ProductionAudioSubmit({
    super.key,
    required this.service,
    required this.node,
    required this.path,
    required this.save,
    required this.blockedReason,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final String path;
  final Future<bool> Function() save;
  final String? blockedReason;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(audioTaskServiceProvider);
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
    final active = runs.data?.where(GenerationTaskDao.blocksSource).firstOrNull;
    final preparing = useState(false);
    if (active != null) {
      final canCancel = GenerationTaskDao.canRequestCancellation(active);
      return ProductionSendButton(
        icon: canCancel ? RevericIcons.stop_rounded : RevericIcons.download,
        tooltip: context.t(
          canCancel
              ? LocaleKeys.commonCancel
              : productionTaskLabelKey('saving'),
        ),
        onPressed: canCancel
            ? () => productionRun(context, () => jobs.cancel(active.id))
            : null,
      );
    }
    final blocked = preparing.value
        ? context.t(LocaleKeys.productionGenerateBusy)
        : !runs.hasData
        ? context.t(
            runs.hasError
                ? LocaleKeys.productionFailed
                : LocaleKeys.productionGenerateChecking,
          )
        : blockedReason;
    return ProductionSendButton(
      icon: runs.data?.isNotEmpty ?? false
          ? RevericIcons.arrow_clockwise
          : RevericIcons.arrow_upward_rounded,
      tooltip: blocked ?? context.t(LocaleKeys.productionGenerate),
      onPressed: blocked != null
          ? null
          : () => productionRun(context, () async {
              preparing.value = true;
              try {
                if (!await save() || !context.mounted) {
                  return;
                }
                final preview = await ProductionAudioGenerateOrchestrator()
                    .preview(service, node.id);
                if (!context.mounted) {
                  return;
                }
                await jobs.submit(
                  novelId: preview.novelId,
                  sourceType: preview.sourceType,
                  sourceId: preview.sourceId,
                  request: preview.request,
                );
              } finally {
                if (context.mounted) {
                  preparing.value = false;
                }
              }
            }),
    );
  }
}
