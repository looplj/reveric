// 职责: 上下文压缩状态展示 — 渲染进行中提示与可展开的历史摘要事件行
// 关联文件:
//   lib/shared/models/ai_chat_models.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/theme/theme.dart
//   lib/shared/widgets/ai/markdown_text.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'package:flutter/material.dart';

import 'package:reveric/shared/components/reveric_spinner.dart';
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/markdown_text.dart';

/// 当前 AI 回合内的上下文整理状态。
///
/// 不使用打字三点，避免与 AI 回复等待态竞争层级。
class CompactingContextIndicator extends StatelessWidget {
  const CompactingContextIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final label = context.t(LocaleKeys.aiCompactingContext);

    return Semantics(
      liveRegion: true,
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: RevericSpinner(strokeWidth: 1.5, color: colors.textMuted),
          ),
          const SizedBox(width: RevericSpacing.xs),
          Text(label, style: typo.uiSmall.copyWith(color: colors.textMuted)),
        ],
      ),
    );
  }
}

/// 渲染 compact_summary 类型消息的可折叠事件行。
///
/// 收起态：压缩图标 + 标题 + token 前后对比（如 `180k → 60k`）。
/// 展开态：额外以 Markdown 渲染摘要全文。
/// metadata 缺失（旧数据）时只显示标题，不崩。
class CompactionCard extends StatefulWidget {
  final String summary;
  final Map<String, dynamic>? metadata;
  final bool initiallyExpanded;
  final bool loadInlineImages;

  const CompactionCard({
    super.key,
    required this.summary,
    this.metadata,
    this.initiallyExpanded = false,
    this.loadInlineImages = true,
  });

  @override
  State<CompactionCard> createState() => _CompactionCardState();
}

class _CompactionCardState extends State<CompactionCard> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.summary.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final tokensBefore = widget.metadata?['tokens_before'] as int?;
    final tokensAfter = widget.metadata?['tokens_after'] as int?;

    return Container(
      margin: EdgeInsets.only(
        top: RevericSpacing.sm,
        bottom: _expanded ? RevericSpacing.sm : RevericSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Container(height: 1, color: colors.borderSubtle)),
              Semantics(
                button: true,
                toggled: _expanded,
                label: context.t(LocaleKeys.aiContextCompacted),
                child: InkWell(
                  borderRadius: BorderRadius.circular(RevericRadius.medium),
                  onTap: _toggle,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: RevericSpacing.sm,
                      vertical: RevericSpacing.xs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RevericIcon(
                          RevericIcons.archive_outlined,
                          size: 14,
                          color: colors.textMuted,
                        ),
                        const SizedBox(width: RevericSpacing.xs),
                        Text(
                          context.t(LocaleKeys.aiContextCompacted),
                          style: typo.uiTinySemibold.copyWith(
                            color: colors.textMuted,
                          ),
                        ),
                        if (tokensBefore != null && tokensAfter != null) ...[
                          const SizedBox(width: RevericSpacing.xs),
                          Text(
                            '${_formatTokens(tokensBefore)} → ${_formatTokens(tokensAfter)}',
                            style: typo.uiTiny.copyWith(
                              color: colors.textSubtle,
                            ),
                          ),
                        ],
                        const SizedBox(width: RevericSpacing.xs),
                        RevericIcon(
                          _expanded
                              ? RevericIcons.expand_less_rounded
                              : RevericIcons.expand_more_rounded,
                          size: 14,
                          color: colors.textMuted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(child: Container(height: 1, color: colors.borderSubtle)),
            ],
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.x3l,
                RevericSpacing.xs,
                RevericSpacing.x3l,
                0,
              ),
              child: AiMarkdownText(
                widget.summary,
                loadInlineImages: widget.loadInlineImages,
                style: typo.uiSmall.copyWith(
                  color: colors.textSecondary,
                  height: 1.55,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 将 token 数格式化为 k 单位（如 180000 → `180k`）。
  String _formatTokens(int tokens) {
    if (tokens >= 1000) {
      final k = (tokens / 1000).round();
      return '${k}k';
    }
    return tokens.toString();
  }
}
