// 职责: 导出成片：先选文件名、分辨率与字幕方式，再展示合成进度与取消，校验完成后交付成片文件或画布视频节点。
// 关联文件:
//   lib/shared/services/editing/render_service.dart
//   lib/desktop/features/production/region.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/file-access.md
import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:path/path.dart' as p;
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/components/reveric_segmented_control.dart';
import '../../../shared/components/reveric_select.dart';
import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/editing/document.dart';
import '../../../shared/models/production/media.dart';
import '../../../shared/models/production/settings.dart';
import '../../../shared/services/editing/service.dart';
import '../../../shared/services/editing/render_service.dart';
import '../../../shared/services/production/ffmpeg_runner.dart';
import '../../../shared/services/production/media_service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import 'support.dart';

final _log = AppLogger.forModule('EditingExport');

enum _Phase { form, running, ready, saved, added }

const _steps = ['verify', 'render', 'assemble', 'validate'];

class EditingExportDialog extends HookWidget {
  const EditingExportDialog({
    super.key,
    required this.renderer,
    required this.document,
    required this.title,
    this.onExportNode,
  });
  final EditingRenderService renderer;
  final EditingDocument document;

  /// 剧集名，用在标题和默认文件名。
  final String title;
  final Future<void> Function(File file, String name)? onExportNode;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final token = useRef(MediaCancellation());
    final phase = useState(_Phase.form);
    final res = useState('720p');
    final subtitles = useState(EditingSubtitles.burn);
    final watermark = useState<EditingWatermarkCorner?>(null);
    final name = useTextEditingController(
      text: title.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim(),
    );
    final progress = useState(0.0);
    final stage = useState('verify');
    final failed = useState<Object?>(null);
    final saving = useState(false);
    final output = useRef<EncodedMedia?>(null);
    final savedPath = useState<String?>(null);
    final operation = useRef<Future<void>?>(null);
    final size = ProductionSettings.dimensions(document.ratio, res.value);
    final textCount = document.clips
        .where((c) => document.track(c.trackId).role == EditingRole.subtitle)
        .length;

    Future<void> render() async {
      failed.value = null;
      progress.value = 0;
      stage.value = 'verify';
      token.value = MediaCancellation();
      phase.value = _Phase.running;
      try {
        final result = await renderer.render(
          document,
          cancellation: token.value,
          resolution: res.value,
          subtitles: subtitles.value,
          watermark: watermark.value,
          progress: (step, value) {
            if (context.mounted) {
              stage.value = step;
              progress.value = value;
            }
          },
        );
        if (!context.mounted) {
          await result.dispose();
          return;
        }
        await output.value?.dispose();
        output.value = result;
        phase.value = _Phase.ready;
      } catch (error, stack) {
        _log.error('failed', error: error, stackTrace: stack);
        if (context.mounted) {
          failed.value = error;
          phase.value = _Phase.ready;
        }
      }
    }

    useEffect(() {
      return () {
        unawaited(() async {
          await token.value.cancel();
          await operation.value;
          await output.value?.dispose();
        }());
      };
    }, const []);

    Future<void> save() async {
      saving.value = true;
      failed.value = null;
      final fileName = name.text.trim().isEmpty ? 'film' : name.text.trim();
      try {
        if (onExportNode != null) {
          await onExportNode!(output.value!.file, '$fileName.mp4');
          if (context.mounted) {
            phase.value = _Phase.added;
          }
          return;
        }
        final location = await getSaveLocation(
          suggestedName: '$fileName.mp4',
          acceptedTypeGroups: [
            const XTypeGroup(label: 'MP4', extensions: ['mp4']),
          ],
        );
        if (location == null) {
          return;
        }
        final srt = subtitles.value == EditingSubtitles.srt
            ? File(p.setExtension(location.path, '.srt'))
            : null;
        // The native save panel has already confirmed replacement of the MP4.
        // Its confirmation does not cover the companion subtitle file.
        if (srt != null && await srt.exists()) {
          if (!context.mounted) {
            return;
          }
          final replaceSubtitles = await showConfirmDialog(
            context,
            title: context.t(LocaleKeys.editingOverwriteSubtitles),
            message: context.t(
              LocaleKeys.editingOverwriteSubtitlesDetail,
              namedArgs: {'name': p.basename(srt.path)},
            ),
            variant: ConfirmDialogVariant.warning,
          );
          if (!replaceSubtitles) {
            return;
          }
        }
        await XFile(
          output.value!.file.path,
          mimeType: 'video/mp4',
        ).saveTo(location.path);
        if (srt != null) {
          await srt.writeAsString(EditingRenderService.srt(document));
        }
        if (context.mounted) {
          savedPath.value = location.path;
          phase.value = _Phase.saved;
        }
      } catch (error, stack) {
        _log.error('save failed', error: error, stackTrace: stack);
        if (context.mounted) {
          failed.value = error;
        }
      } finally {
        if (context.mounted) {
          saving.value = false;
        }
      }
    }

    void start() {
      operation.value = () async {
        await render();
        if (context.mounted && output.value != null && onExportNode != null) {
          await save();
        }
      }();
    }

    String? failure() {
      final error = failed.value;
      if (error == null) {
        return null;
      }
      return context.t(
        error is MediaException && error.reason == MediaFailure.cancelled
            ? LocaleKeys.editingCancelled
            : error is EditingInsufficientSpace
            ? LocaleKeys.editingDiskFull
            : error is EditingSourceProblem
            ? LocaleKeys.editingSourceMissing
            : error is MediaException &&
                  error.reason == MediaFailure.invalid_media
            ? LocaleKeys.editingInvalidMedia
            : output.value == null
            ? LocaleKeys.editingRenderFailed
            : LocaleKeys.commonSaveFailed,
      );
    }

    final hidden = document.tracks.where((t) => t.hidden).toList();
    final muted = document.tracks
        .where((t) => t.kind == 'audio' && t.muted)
        .toList();
    final audioTracks = document.tracks
        .where((t) => t.kind == 'audio' && !t.muted)
        .length;
    final spec =
        'MP4 · ${size.$1}×${size.$2} · $editingFps fps · ${editingTimecode(document.totalFrames)}';

    Widget notice(String icon, String text, {Color? color}) => Container(
      margin: const EdgeInsets.only(top: RevericSpacing.sm),
      padding: const EdgeInsets.all(RevericSpacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.large),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RevericIcon(icon, size: 14, color: color ?? colors.textMuted),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: typo.uiSmall.copyWith(color: color ?? colors.textMuted),
            ),
          ),
        ],
      ),
    );

    final body = switch (phase.value) {
      _Phase.form => [
        _ExportRow(
          icon: RevericIcons.file_text,
          title: context.t(LocaleKeys.editingExportFile),
          detail: '',
          trailing: SizedBox(
            width: 220,
            child: Row(
              children: [
                Expanded(
                  child: RevericTextField(controller: name, autocorrect: false),
                ),
                const SizedBox(width: RevericSpacing.xs),
                Text(
                  '.mp4',
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
        ),
        _ExportRow(
          icon: RevericIcons.frame_corners,
          title: context.t(LocaleKeys.editingPicture),
          detail: context.t(
            LocaleKeys.editingExportPictureDetail,
            namedArgs: {
              'ratio': document.ratio,
              'size': '${size.$1}×${size.$2}',
            },
          ),
          trailing: SizedBox(
            width: 160,
            child: RevericSegmentedControl<String>(
              selected: res.value,
              height: 28,
              segments: const [
                RevericSegment(value: '720p', label: '720P'),
                RevericSegment(value: '1080p', label: '1080P'),
              ],
              onChanged: (v) => res.value = v,
            ),
          ),
        ),
        _ExportRow(
          icon: RevericIcons.subtitles,
          title: context.t(LocaleKeys.editingRoleSubtitle),
          detail: context.t(
            subtitles.value == EditingSubtitles.srt
                ? LocaleKeys.editingExportSubtitlesSrt
                : LocaleKeys.editingExportSubtitles,
            namedArgs: {'count': '$textCount'},
          ),
          trailing: SizedBox(
            width: 220,
            child: RevericSegmentedControl<String>(
              selected: subtitles.value,
              height: 28,
              segments: [
                RevericSegment(
                  value: EditingSubtitles.burn,
                  label: context.t(LocaleKeys.editingSubtitlesBurn),
                ),
                if (onExportNode == null)
                  RevericSegment(
                    value: EditingSubtitles.srt,
                    label: context.t(LocaleKeys.editingSubtitlesSrt),
                  ),
                RevericSegment(
                  value: EditingSubtitles.none,
                  label: context.t(LocaleKeys.editingSubtitlesNone),
                ),
              ],
              onChanged: (v) => subtitles.value = v,
            ),
          ),
        ),
        _ExportRow(
          icon: RevericIcons.image,
          title: context.t(LocaleKeys.editingExportWatermark),
          detail: context.t(LocaleKeys.editingExportWatermarkDetail),
          trailing: SizedBox(
            width: 160,
            child: RevericSelect<EditingWatermarkCorner?>(
              value: watermark.value,
              items: [
                for (final corner in [null, ...EditingWatermarkCorner.values])
                  RevericSelectItem(
                    value: corner,
                    label: context.t(switch (corner) {
                      null => LocaleKeys.commonNone,
                      EditingWatermarkCorner.top_left =>
                        LocaleKeys.editingPositionTopLeft,
                      EditingWatermarkCorner.top_right =>
                        LocaleKeys.editingPositionTopRight,
                      EditingWatermarkCorner.bottom_left =>
                        LocaleKeys.editingPositionBottomLeft,
                      EditingWatermarkCorner.bottom_right =>
                        LocaleKeys.editingPositionBottomRight,
                    }),
                  ),
              ],
              onChanged: (corner) => watermark.value = corner,
            ),
          ),
        ),
        _ExportRow(
          icon: RevericIcons.waveform,
          title: context.t(LocaleKeys.editingSound),
          detail: [
            context.t(
              LocaleKeys.editingExportSound,
              namedArgs: {'count': '$audioTracks'},
            ),
            if (muted.isNotEmpty)
              context.t(
                LocaleKeys.editingExportMuted,
                namedArgs: {
                  'tracks': muted
                      .map((t) => editingTrackName(context, t))
                      .join('、'),
                },
              ),
          ].join(' · '),
        ),
        if (hidden.isNotEmpty)
          notice(
            RevericIcons.visibility_off,
            context.t(
              LocaleKeys.editingExportHidden,
              namedArgs: {
                'tracks': hidden
                    .map(
                      (t) =>
                          '${editingTrackName(context, t)} ${editingTrackCode(t)}',
                    )
                    .join('、'),
              },
            ),
          ),
      ],
      _Phase.running => [
        Row(
          children: [
            Expanded(
              child: Text(
                context.t(switch (stage.value) {
                  'verify' => LocaleKeys.editingVerifying,
                  'assemble' => LocaleKeys.editingAssembling,
                  'validate' || 'done' => LocaleKeys.editingValidating,
                  _ => LocaleKeys.editingRendering,
                }),
                style: typo.uiMedium.copyWith(color: colors.textPrimary),
              ),
            ),
            Text(
              '${(progress.value * 100).floor()}%',
              style: typo.mono.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.sm),
        LinearProgressIndicator(value: progress.value),
        const SizedBox(height: RevericSpacing.md),
        for (final (i, step) in _steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: RevericSpacing.xs),
            child: Builder(
              builder: (context) {
                final current = _steps.indexOf(
                  stage.value == 'done' ? 'validate' : stage.value,
                );
                final done = i < current;
                final on = i == current;
                return Row(
                  children: [
                    RevericIcon(
                      done
                          ? RevericIcons.check_circle
                          : on
                          ? RevericIcons.circle_notch
                          : RevericIcons.circle_outlined,
                      size: 13,
                      color: done
                          ? colors.success
                          : on
                          ? colors.accent
                          : colors.textSubtle,
                    ),
                    const SizedBox(width: RevericSpacing.xs),
                    Text(
                      context.t(switch (step) {
                        'verify' => LocaleKeys.editingStepVerify,
                        'render' => LocaleKeys.editingStepRender,
                        'assemble' => LocaleKeys.editingStepAssemble,
                        _ => LocaleKeys.editingStepValidate,
                      }),
                      style: typo.uiSmall.copyWith(
                        color: on ? colors.textPrimary : colors.textMuted,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        const SizedBox(height: RevericSpacing.sm),
        Text(
          context.t(LocaleKeys.editingExportLocal),
          style: typo.uiSmall.copyWith(color: colors.textMuted),
        ),
      ],
      _Phase.ready => [
        if (failure() case final message?)
          notice(
            RevericIcons.warning_circle,
            message,
            color: colors.warningText,
          )
        else
          notice(
            RevericIcons.check_circle,
            context.t(LocaleKeys.editingReady),
            color: colors.success,
          ),
      ],
      _Phase.added => [
        notice(
          RevericIcons.check_circle,
          context.t(LocaleKeys.editingNodeExported),
          color: colors.success,
        ),
      ],
      _Phase.saved => [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RevericIcon(
              RevericIcons.check_circle,
              size: 18,
              color: colors.success,
            ),
            const SizedBox(width: RevericSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.t(
                      LocaleKeys.editingExported,
                      namedArgs: {'name': p.basename(savedPath.value ?? '')},
                    ),
                    style: typo.uiMedium.copyWith(color: colors.textPrimary),
                  ),
                  Text(
                    '${savedPath.value} · ${size.$1}×${size.$2} · $editingFps fps · ${editingTimecode(document.totalFrames)}',
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
                  if (subtitles.value == EditingSubtitles.srt)
                    Text(
                      context.t(
                        LocaleKeys.editingExportedSrt,
                        namedArgs: {
                          'name': p.basename(
                            p.setExtension(savedPath.value ?? '', '.srt'),
                          ),
                        },
                      ),
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    };

    final running = phase.value == _Phase.running;
    return PopScope(
      canPop: !running && !saving.value,
      child: RevericDialog.panel(
        width: 560,
        title: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      context.t(
                        LocaleKeys.editingExportTitle,
                        namedArgs: {'episode': title},
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSemibold.copyWith(
                        fontSize: typo.body.fontSize,
                      ),
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  Flexible(
                    child: Text(
                      context.t(LocaleKeys.editingExportByTimeline),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            RevericIconButton(
              icon: RevericIcons.close,
              tooltip: context.t(LocaleKeys.commonClose),
              onPressed: running || saving.value
                  ? null
                  : () => Navigator.pop(context),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...body,
            const SizedBox(height: RevericSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: Text(
                    phase.value == _Phase.form
                        ? spec
                        : running
                        ? context.t(LocaleKeys.editingExporting)
                        : '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
                ),
                ...switch (phase.value) {
                  _Phase.form => [
                    RevericButton.text(
                      label: context.t(LocaleKeys.commonCancel),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    RevericButton.primary(
                      icon: RevericIcons.download_simple,
                      label: context.t(
                        onExportNode == null
                            ? LocaleKeys.commonExport
                            : LocaleKeys.editingExportNode,
                      ),
                      onPressed: document.totalFrames == 0 ? null : start,
                    ),
                  ],
                  _Phase.running => [
                    RevericButton.text(
                      label: context.t(LocaleKeys.editingCancelExport),
                      onPressed: () => token.value.cancel(),
                    ),
                  ],
                  _Phase.ready => [
                    RevericButton.text(
                      label: context.t(LocaleKeys.commonClose),
                      onPressed: saving.value
                          ? null
                          : () => Navigator.pop(context),
                    ),
                    if (output.value != null) ...[
                      const SizedBox(width: RevericSpacing.sm),
                      RevericButton.primary(
                        icon: RevericIcons.download_simple,
                        label: context.t(
                          onExportNode == null
                              ? LocaleKeys.commonSave
                              : LocaleKeys.commonRetry,
                        ),
                        loading: saving.value,
                        onPressed: saving.value
                            ? null
                            : () => operation.value = save(),
                      ),
                    ] else ...[
                      const SizedBox(width: RevericSpacing.sm),
                      RevericButton.primary(
                        label: context.t(LocaleKeys.commonRetry),
                        onPressed: () => phase.value = _Phase.form,
                      ),
                    ],
                  ],
                  _Phase.saved || _Phase.added => [
                    RevericButton.primary(
                      label: context.t(LocaleKeys.commonDone),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                },
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 打开导出弹窗。
Future<void> showEditingExport(
  BuildContext context, {
  required EditingRenderService renderer,
  required EditingDocument document,
  required String title,
  Future<void> Function(File file, String name)? onExportNode,
}) => showRevericDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => EditingExportDialog(
    renderer: renderer,
    document: document,
    title: title,
    onExportNode: onExportNode,
  ),
);

/// 弹窗里的一行：图标、标题、说明，右侧放选择控件。
class _ExportRow extends StatelessWidget {
  const _ExportRow({
    required this.icon,
    required this.title,
    required this.detail,
    this.trailing,
  });
  final String icon;
  final String title;
  final String detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.md),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    RevericIcon(icon, size: 13, color: colors.textMuted),
                    const SizedBox(width: RevericSpacing.xs),
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiMedium.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: RevericSpacing.lg),
            trailing!,
          ],
        ],
      ),
    );
  }
}
