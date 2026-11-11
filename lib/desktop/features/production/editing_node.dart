// 职责: 展示剪辑工程的首帧、时长和失效状态，从节点打开所属工程或渲染后弹窗预览。
// 关联文件:
//   lib/desktop/features/production/node_card.dart
//   lib/desktop/features/production/node_bar.dart
//   lib/desktop/features/asset/media_preview.dart
//   lib/desktop/features/editing/canvas_shell.dart
//   lib/shared/services/editing/render_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/file-access.md
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/services/editing/service.dart';
import '../../../shared/services/editing/render_service.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/ffmpeg_runner.dart';
import '../../../shared/services/production/media_service.dart';
import '../../../shared/models/production/media.dart';
import '../../../shared/theme/theme.dart';
import '../asset/media_preview.dart';
import '../editing/canvas_shell.dart';
import '../editing/support.dart' show editingTimecode;
import 'support.dart';

final _posterRenderer = Provider.autoDispose
    .family<EditingRenderService, ProductionCanvasService>((ref, service) {
      final renderer = EditingRenderService(
        EditingService(service.db, service.library),
        FfmpegRunner(),
      );
      ref.onDispose(() => unawaited(renderer.dispose()));
      return renderer;
    });

class ProductionEditingNode extends HookConsumerWidget {
  const ProductionEditingNode({
    super.key,
    required this.service,
    required this.node,
    required this.editing,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final AsyncSnapshot<VideoEditingRow?> editing;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = editing.data;
    final enabled = TickerMode.valuesOf(context).enabled;
    final renderer = ref.watch(_posterRenderer(service));
    final cached = useMemoized(() => <(String, int), Uint8List>{}, [service]);
    final token = useMemoized(MediaCancellation.new, [
      row?.id,
      row?.revision,
      enabled,
    ]);
    useEffect(
      () => () {
        unawaited(token.cancel());
      },
      [token],
    );
    final frame = useFuture(
      useMemoized(() async {
        if (!enabled || row == null || row.document.totalFrames == 0) {
          return null;
        }
        final key = (row.id, row.revision);
        if (cached[key] case final bytes?) {
          return bytes;
        }
        final bytes = await renderer.firstFrame(
          row.document,
          cancellation: token,
        );
        if (!token.cancelled) {
          cached
            ..clear()
            ..[key] = bytes;
        }
        return bytes;
      }, [renderer, row?.id, row?.revision, enabled]),
      preserveState: false,
    );
    final colors = RevericTheme.colorsOf(context),
        typo = RevericTheme.typographyOf(context);
    final missing =
        node.editingId == null ||
        editing.hasError ||
        editing.connectionState == ConnectionState.active && row == null;
    final open = CanvasEditingScope.maybeOf(context)?.open;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: missing || row == null || open == null
          ? null
          : () => productionRun(context, () => open(node.id)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (frame.data case final bytes?)
            Image.memory(bytes, fit: BoxFit.cover, cacheWidth: 640)
          else
            Center(
              child: missing
                  ? const SizedBox.shrink()
                  : Tooltip(
                      message: context.t(
                        frame.hasError
                            ? LocaleKeys.commonLoadFailed
                            : LocaleKeys.editingTitle,
                      ),
                      child: RevericIcon(
                        frame.hasError
                            ? RevericIcons.broken_image_outlined
                            : RevericIcons.movie_outlined,
                        color: frame.hasError ? colors.error : colors.textMuted,
                      ),
                    ),
            ),
          if (missing)
            Center(
              child: Text(
                context.t(LocaleKeys.productionEditingMissing),
                style: typo.uiSmall.copyWith(color: colors.error),
              ),
            )
          else if (row != null)
            Positioned(
              right: RevericSpacing.sm,
              bottom: RevericSpacing.sm,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.xs,
                    vertical: RevericSpacing.xxs,
                  ),
                  child: Text(
                    editingTimecode(row.document.totalFrames),
                    style: typo.uiTiny.copyWith(color: colors.textPrimary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 把剪辑工程渲染成预览视频，渲染期间显示进度，完成后弹窗播放；关闭即删除临时文件。
Future<void> previewProductionEditing(
  BuildContext context,
  ProductionCanvasService service,
  CanvasNode node,
) async {
  final editingId = node.editingId;
  if (editingId == null) {
    return;
  }
  final projects = EditingService(service.db, service.library);
  final row = await projects.read(editingId);
  if (row.document.totalFrames == 0 || !context.mounted) {
    return;
  }
  final renderer = EditingRenderService(projects, FfmpegRunner());
  final cancellation = MediaCancellation();
  final progress = ValueNotifier(0.0);
  EncodedMedia? result;
  try {
    final rendering = renderer.render(
      row.document,
      cancellation: cancellation,
      preview: true,
      progress: (_, value) => progress.value = value,
    );
    // 关掉进度弹窗即取消渲染。
    final dialog = showDialog<void>(
      context: context,
      builder: (_) => _EditingRenderDialog(
        rendering: rendering,
        progress: progress,
        title: row.title,
      ),
    );
    unawaited(dialog.then((_) => cancellation.cancel()));
    result = await rendering;
    await dialog;
    if (!context.mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => MediaPreviewDialog.file(
        path: result!.file.path,
        type: 'video',
        name: row.title,
        autoplay: true,
        temporary: true,
      ),
    );
  } on MediaException catch (error) {
    if (error.reason != MediaFailure.cancelled) {
      rethrow;
    }
  } finally {
    await result?.dispose();
    progress.dispose();
    await renderer.dispose();
  }
}

class _EditingRenderDialog extends HookWidget {
  const _EditingRenderDialog({
    required this.rendering,
    required this.progress,
    required this.title,
  });
  final Future<EncodedMedia> rendering;
  final ValueNotifier<double> progress;
  final String title;
  @override
  Widget build(BuildContext context) {
    useEffect(() {
      void close() {
        if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.pop(context);
        }
      }

      rendering.then((_) => close(), onError: (Object _) => close());
      return null;
    }, [rendering]);
    final value = useValueListenable(progress);
    final colors = RevericTheme.colorsOf(context),
        typo = RevericTheme.typographyOf(context);
    return Dialog(
      child: SizedBox(
        width: RevericSizes.dialogWidth,
        child: Padding(
          padding: const EdgeInsets.all(RevericSpacing.x2l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: typo.uiSemibold,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: RevericSpacing.md),
              Text(
                context.t(
                  LocaleKeys.editingPreparing,
                  namedArgs: {'percent': '${(value * 100).floor()}'},
                ),
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
              const SizedBox(height: RevericSpacing.sm),
              LinearProgressIndicator(value: value),
              const SizedBox(height: RevericSpacing.lg),
              Align(
                alignment: Alignment.centerRight,
                child: RevericButton.secondary(
                  label: context.t(LocaleKeys.commonCancel),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
