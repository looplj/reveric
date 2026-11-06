// 职责: 按渠道登记的视频模型卖点渲染渐变徽标，提示渲染为说明图标。
// 关联文件:
//   lib/shared/models/video/channels.dart
//   lib/shared/widgets/settings/provider_video_models.dart
//   lib/desktop/features/production/composer.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md

import 'package:flutter/material.dart';

import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/video/channels.dart';
import '../../theme/theme.dart';

/// 未登记卖点的模型返回 null，调用方无需预留位置。[dense] 用于下拉菜单副标题行，
/// 徽标更矮且不带投影。
Widget? providerVideoHighlights(
  BuildContext context,
  String providerType,
  String modelId, {
  bool dense = false,
}) {
  final channel = lookupVideoChannelModel(providerType, modelId);
  if (channel == null || channel.highlights.isEmpty) {
    return null;
  }
  final colors = RevericTheme.colorsOf(context);
  String? tooltipFor(VideoModelHighlight highlight) {
    final notices = [
      for (final notice in channel.notices)
        if (notice.highlight == highlight) _noticeText(context, notice),
    ];
    return notices.isEmpty ? null : notices.join('\n');
  }

  return Wrap(
    spacing: RevericSpacing.xs,
    runSpacing: RevericSpacing.xxs,
    children: [
      for (final highlight in channel.highlights)
        switch (highlight) {
          VideoModelHighlight.max_duration => _HighlightChip(
            icon: RevericIcons.schedule_outlined,
            label: context.t(
              LocaleKeys.providerVideoHighlightMaxDuration,
              namedArgs: {'seconds': '${channel.maxDurationSeconds}'},
            ),
            tooltip: tooltipFor(highlight),
            dense: dense,
            gradient: [colors.error, colors.warningText],
          ),
          VideoModelHighlight.priority => _HighlightChip(
            icon: RevericIcons.crown,
            label: context.t(LocaleKeys.providerVideoHighlightPriority),
            tooltip: tooltipFor(highlight),
            dense: dense,
            gradient: [
              colors.warningText,
              colors.warningText.withValues(alpha: 0.8),
            ],
          ),
        },
    ],
  );
}

/// 没有提示的模型返回 null；多条提示合并进同一个说明图标的 tooltip。
Widget? providerVideoNotice(
  BuildContext context,
  String providerType,
  String modelId,
) {
  final channel = lookupVideoChannelModel(providerType, modelId);
  if (channel == null || channel.notices.isEmpty) {
    return null;
  }
  final message = [
    for (final notice in channel.notices) _noticeText(context, notice),
  ].join('\n');
  return Tooltip(
    message: message,
    child: RevericIcon(
      RevericIcons.info_outline,
      size: 14,
      color: RevericTheme.colorsOf(context).textMuted,
    ),
  );
}

String _noticeText(BuildContext context, VideoModelNotice notice) =>
    switch (notice) {
      VideoModelNotice.priority_billing => context.t(
        LocaleKeys.providerVideoNoticePriorityBilling,
      ),
    };

class _HighlightChip extends StatelessWidget {
  const _HighlightChip({
    required this.icon,
    required this.label,
    required this.gradient,
    this.tooltip,
    this.dense = false,
  });

  final String icon;
  final String label;
  final List<Color> gradient;

  /// 卖点关联的提示文案；为空时悬停显示完整 [label]。
  final String? tooltip;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Tooltip(
      message: tooltip ?? label,
      excludeFromSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? RevericSpacing.xs : RevericSpacing.sm,
          vertical: dense ? 1 : RevericSpacing.xxs,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: gradient),
          borderRadius: BorderRadius.circular(RevericRadius.capsule),
          boxShadow: [
            if (!dense)
              BoxShadow(
                color: gradient.first.withValues(alpha: 0.3),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(icon, size: dense ? 10 : 11, color: colors.onAccent),
            const SizedBox(width: RevericSpacing.xxs),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiTinySemibold.copyWith(color: colors.onAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
