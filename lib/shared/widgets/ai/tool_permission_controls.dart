// 职责: 本地化工具权限标签并按平台提供作用域与规则选择控件。
// 关联文件:
//   lib/shared/models/tool_permission.dart
//   lib/shared/components/reveric_select.dart
//   lib/mobile/widgets/sheet.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'package:flutter/material.dart';
import '../../../mobile/widgets/sheet.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_select.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/tool_permission.dart';
import '../../theme/theme.dart';

String toolPermissionScopeLabel(
  BuildContext context,
  ToolPermissionScopeType scope,
) => context.t(switch (scope) {
  ToolPermissionScopeType.global => LocaleKeys.aiPermissionGlobal,
  ToolPermissionScopeType.work => LocaleKeys.aiPermissionWork,
  ToolPermissionScopeType.episode => LocaleKeys.aiPermissionEpisode,
  ToolPermissionScopeType.session => LocaleKeys.aiPermissionSession,
});
String toolPermissionDecisionLabel(
  BuildContext context,
  ToolPermissionDecision? value,
) => context.t(switch (value) {
  ToolPermissionDecision.allow => LocaleKeys.aiPermissionAllow,
  ToolPermissionDecision.ask => LocaleKeys.aiPermissionAsk,
  ToolPermissionDecision.deny => LocaleKeys.aiPermissionDeny,
  null => LocaleKeys.aiPermissionInherit,
});
String toolPermissionActionIcon(String? action) => switch (action) {
  'generation.image' => RevericIcons.image,
  'generation.video' => RevericIcons.movie_outlined,
  'generation.audio' => RevericIcons.waveform,
  'media.transcribe' => RevericIcons.subtitles,
  'files.read' => RevericIcons.file_text,
  'files.remove' => RevericIcons.delete,
  shellExecutePermission => RevericIcons.terminal_rounded,
  _ => RevericIcons.shield_check,
};

String toolPermissionActionLabel(BuildContext context, String action) =>
    context.t(switch (action) {
      'generation.image' => LocaleKeys.aiPermissionGenerationImage,
      'generation.video' => LocaleKeys.aiPermissionGenerationVideo,
      'generation.audio' => LocaleKeys.aiPermissionGenerationAudio,
      'media.transcribe' => LocaleKeys.aiPermissionMediaTranscribe,
      'files.read' => LocaleKeys.aiPermissionFilesRead,
      'files.remove' => LocaleKeys.aiPermissionFilesRemove,
      shellExecutePermission => LocaleKeys.aiPermissionShellExecute,
      _ => action,
    });

class ToolPermissionSelector<T> extends StatelessWidget {
  const ToolPermissionSelector({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.label,
    this.compact = false,
    this.menuWidth,
  });
  final T value;
  final List<RevericSelectItem<T>> items;
  final ValueChanged<T>? onChanged;
  final String? label;

  /// Borderless inline trigger for cards and table cells.
  final bool compact;
  final double? menuWidth;
  @override
  Widget build(BuildContext context) {
    final mobile =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    if (!mobile) {
      return RevericSelect<T>(
        value: value,
        items: items,
        label: label,
        compact: compact,
        menuWidth: menuWidth,
        height: compact
            ? RevericSizes.buttonHeightSm
            : RevericSizes.fieldHeight,
        enabled: onChanged != null,
        onChanged: (value) => onChanged?.call(value),
      );
    }
    final textStyle = RevericTheme.typographyOf(context).ui;
    final selected = items.firstWhere((item) => item.value == value);
    final buttonLabel = label == null
        ? selected.label
        : '$label: ${selected.label}';
    return (compact ? RevericButton.text : RevericButton.secondary)(
      label: buttonLabel,
      onPressed: onChanged == null
          ? null
          : () async {
              final chosen = await showMobileSheet<T>(
                context: context,
                showDragHandle: true,
                builder: (sheetContext) => SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final item in items)
                        ListTile(
                          title: Text(item.label, style: textStyle),
                          selected: item.value == value,
                          onTap: () =>
                              Navigator.of(sheetContext).pop(item.value),
                        ),
                    ],
                  ),
                ),
              );
              if (chosen != null && context.mounted) {
                onChanged?.call(chosen);
              }
            },
    );
  }
}
