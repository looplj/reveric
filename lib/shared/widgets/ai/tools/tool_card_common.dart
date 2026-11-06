// 职责: AI 工具详情公共 UI — 提供状态点、徽章、预览块与信息标签。
// 关联文件:
//   lib/shared/widgets/ai/tool_activity_group.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart
//   lib/shared/theme/theme.dart
import 'package:flutter/material.dart';

import 'package:reveric/shared/components/reveric_spinner.dart';
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/theme/theme.dart';

class AiToolInfoChips extends StatelessWidget {
  const AiToolInfoChips({super.key, required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final visibleItems = items.where((item) => item.trim().isNotEmpty).toList();
    if (visibleItems.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: RevericSpacing.xs,
      runSpacing: RevericSpacing.xs,
      children: visibleItems
          .map(
            (item) => Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.xs,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: colors.surfaceDim,
                borderRadius: BorderRadius.circular(RevericRadius.pill),
              ),
              child: Text(
                item,
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
            ),
          )
          .toList(),
    );
  }
}

class AiToolStatusDot extends StatelessWidget {
  const AiToolStatusDot({super.key, required this.status, this.size = 18});

  final AiToolCallStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final color = _statusColor(colors, status);
    final background = switch (status) {
      AiToolCallStatus.success => colors.additionBg,
      AiToolCallStatus.error => colors.deletionBg,
      AiToolCallStatus.running => colors.accent.withValues(alpha: 0.16),
      AiToolCallStatus.pending => colors.surfaceDim,
      AiToolCallStatus.rejected ||
      AiToolCallStatus.cancelled => colors.surfaceDim,
    };

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Center(
        child: status == AiToolCallStatus.running
            ? SizedBox(
                width: size * 0.62,
                height: size * 0.62,
                child: RevericSpinner(strokeWidth: 1.6, color: color),
              )
            : RevericIcon(
                _statusIconAsset(status),
                size: size * 0.62,
                color: color,
              ),
      ),
    );
  }
}

class AiToolStatusBadge extends StatelessWidget {
  const AiToolStatusBadge({super.key, required this.status});

  final AiToolCallStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return _statusBadge(context, colors, typo, status);
  }
}

class AiToolPathList extends StatelessWidget {
  const AiToolPathList({
    super.key,
    required this.paths,
    required this.label,
    this.totalCount,
    this.maxItems = 8,
    this.truncated = false,
    this.formatPath,
  });

  final List<String> paths;
  final String label;
  final int? totalCount;
  final int maxItems;
  final bool truncated;
  final String Function(BuildContext context, String path)? formatPath;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final visiblePaths = paths.take(maxItems).toList();
    if (visiblePaths.isEmpty) {
      return const SizedBox.shrink();
    }

    final total = totalCount ?? paths.length;
    final shown = visiblePaths.length;
    final hiddenCount = total > shown
        ? total - shown
        : paths.length > shown
        ? paths.length - shown
        : 0;

    return Container(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.sm,
        RevericSpacing.xs,
        RevericSpacing.sm,
        RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: typo.uiSmall.copyWith(color: colors.textMuted, fontSize: 10),
          ),
          const SizedBox(height: RevericSpacing.xxs),
          ...visiblePaths.map((path) {
            final display = formatPath?.call(context, path) ?? path;
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Tooltip(
                message: path,
                waitDuration: const Duration(milliseconds: 400),
                child: Text(
                  display,
                  style: typo.uiSmall.copyWith(
                    color: colors.textPrimary,
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
          }),
          if (hiddenCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: RevericSpacing.xxs),
              child: Text(
                context.t(
                  LocaleKeys.toolMoreResultsFmt,
                  namedArgs: {'count': '$hiddenCount'},
                ),
                style: typo.uiSmall.copyWith(
                  color: colors.textMuted,
                  fontSize: 10,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class AiToolPreviewBlock extends StatelessWidget {
  const AiToolPreviewBlock({
    super.key,
    required this.label,
    required this.text,
    this.monospace = false,
    this.maxLines = 6,
  });

  final String label;
  final String text;
  final bool monospace;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    if (text.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.sm,
        RevericSpacing.xs,
        RevericSpacing.sm,
        RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: typo.uiSmall.copyWith(color: colors.textMuted, fontSize: 10),
          ),
          const SizedBox(height: 2),
          Text(
            text,
            style: typo.uiSmall.copyWith(
              color: colors.textPrimary,
              fontFamily: monospace ? 'monospace' : null,
            ),
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class AiToolKeyValueList extends StatelessWidget {
  const AiToolKeyValueList({super.key, required this.entries});

  final List<(String, String)> entries;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final visibleEntries = entries
        .where((entry) => entry.$2.trim().isNotEmpty)
        .toList();
    if (visibleEntries.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: visibleEntries
          .map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: RevericSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      entry.$1,
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  Expanded(
                    child: Text(
                      entry.$2,
                      style: typo.uiSmall.copyWith(color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}

String _statusIconAsset(AiToolCallStatus status) {
  return switch (status) {
    AiToolCallStatus.pending => RevericIcons.pending_rounded,
    AiToolCallStatus.running => RevericIcons.pending_rounded,
    AiToolCallStatus.success => RevericIcons.check_rounded,
    AiToolCallStatus.error => RevericIcons.error_outline_rounded,
    AiToolCallStatus.rejected => RevericIcons.block_rounded,
    AiToolCallStatus.cancelled => RevericIcons.close_rounded,
  };
}

Color _statusColor(RevericColors colors, AiToolCallStatus status) {
  return switch (status) {
    AiToolCallStatus.pending => colors.textMuted,
    AiToolCallStatus.running => colors.accent,
    AiToolCallStatus.success => colors.additionBorder,
    AiToolCallStatus.error => colors.deletionBorder,
    AiToolCallStatus.rejected => colors.textMuted,
    AiToolCallStatus.cancelled => colors.textMuted,
  };
}

Widget _statusBadge(
  BuildContext context,
  RevericColors colors,
  RevericTypography typo,
  AiToolCallStatus status,
) {
  final (label, color) = switch (status) {
    AiToolCallStatus.pending => (
      context.t(LocaleKeys.toolPending),
      colors.accent,
    ),
    AiToolCallStatus.running => (
      context.t(LocaleKeys.toolRunning),
      colors.accent,
    ),
    AiToolCallStatus.success => (
      context.t(LocaleKeys.toolSuccess),
      colors.additionBorder,
    ),
    AiToolCallStatus.error => (
      context.t(LocaleKeys.toolError),
      colors.deletionBorder,
    ),
    AiToolCallStatus.rejected => (
      context.t(LocaleKeys.toolRejected),
      colors.textMuted,
    ),
    AiToolCallStatus.cancelled => (
      context.t(LocaleKeys.toolCancelled),
      colors.textMuted,
    ),
  };

  return Container(
    padding: const EdgeInsets.symmetric(
      horizontal: RevericSpacing.xs,
      vertical: 1,
    ),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(RevericRadius.pill),
    ),
    child: Text(
      label,
      style: typo.uiSmall.copyWith(color: color, fontSize: 10),
    ),
  );
}
