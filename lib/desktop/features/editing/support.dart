// 职责: 提供剪辑页的失败提示、导出命名、时间码与轨道和片段展示信息。
// 关联文件:
//   lib/shared/services/editing/service.dart
//   lib/shared/models/editing/document.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
import 'dart:async';
import 'package:flutter/material.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/editing/document.dart';
import '../../../shared/services/editing/service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/utils/number_format.dart';
import 'controller.dart';

final _log = AppLogger.forModule('Editing');

String editingEpisodeExportName(
  BuildContext context,
  int number,
  String title,
) {
  final label = context.t(
    LocaleKeys.editingEpisodeFileName,
    namedArgs: {
      'number': Localizations.localeOf(context).languageCode == 'zh'
          ? formatChineseNumber(number)
          : '$number',
      'title': title.trim(),
    },
  );
  return label.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').trim();
}

Future<void> editingRun(
  BuildContext context,
  FutureOr<void> Function() action,
) async {
  try {
    await action();
  } catch (error, stack) {
    _log.error('operation failed', error: error, stackTrace: stack);
    if (context.mounted) {
      editingSay(
        context,
        context.t(
          error is EditingSourceProblem
              ? LocaleKeys.editingSourceMissing
              : error is EditingConflict
              ? LocaleKeys.editingConflict
              : LocaleKeys.editingInvalidEdit,
        ),
      );
    }
  }
}

void editingSay(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));

/// 00:23.12（分:秒.帧）
String editingTimecode(int frame) =>
    '${(frame ~/ (editingFps * 60)).toString().padLeft(2, '0')}:${(frame ~/ editingFps % 60).toString().padLeft(2, '0')}.${(frame % editingFps).toString().padLeft(2, '0')}';

/// 12.5s
String editingDurationLabel(int frames) =>
    '${editingSeconds(frames).toStringAsFixed(1)}s';

/// 1.5x、0.25x
String editingSpeedLabel(double speed) =>
    '${speed.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}x';

/// 轨道编号：T1 / V1 / V2 / A1…，按同类轨道的层级。
String editingTrackCode(EditingTrack track) =>
    '${switch (track.kind) {
      'text' => 'T',
      'video' => 'V',
      _ => 'A',
    }}${track.order + 1}';

String editingTrackName(BuildContext context, EditingTrack track) =>
    track.name.isNotEmpty
    ? track.name
    : context.t(switch (track.role) {
        EditingRole.main => LocaleKeys.editingRoleMain,
        EditingRole.overlay => LocaleKeys.editingRoleOverlay,
        EditingRole.subtitle => LocaleKeys.editingRoleSubtitle,
        EditingRole.dialogue => LocaleKeys.editingRoleDialogue,
        EditingRole.sfx => LocaleKeys.editingRoleSfx,
        EditingRole.music => LocaleKeys.editingRoleMusic,
        EditingRole.text => LocaleKeys.editingRoleText,
        _ => LocaleKeys.editingRoleAudio,
      });

String editingTrackIcon(EditingTrack track) => switch (track.role) {
  EditingRole.main => RevericIcons.movie_outlined,
  EditingRole.overlay => RevericIcons.stack,
  EditingRole.subtitle => RevericIcons.subtitles,
  EditingRole.dialogue => RevericIcons.microphone,
  EditingRole.music => RevericIcons.music_notes,
  EditingRole.text => RevericIcons.text_fields_outlined,
  _ => RevericIcons.waveform,
};

/// 片段配色跟随轨道角色，取主题里的强调色族。
Color editingRoleColor(RevericColors colors, String role) => switch (role) {
  EditingRole.dialogue => colors.accentWarm,
  EditingRole.sfx => colors.success,
  EditingRole.music || EditingRole.audio => colors.accentAmber,
  _ => colors.accent,
};

String editingClipLabel(EditingController controller, EditingClip clip) =>
    switch (clip.content) {
      EditingTextContent(:final text) => text,
      EditingSourceContent(:final source) =>
        clip.name.isNotEmpty ? clip.name : controller.sourceName(source),
    };
