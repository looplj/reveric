// 职责: 推理强度指示条（小竖条）+ effort wire → 本地化标签/提示映射
// 关联文件:
//   lib/desktop/widgets/ai/model/model_selector.dart
//   lib/mobile/widgets/chat_composer.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json

import 'package:flutter/material.dart';

import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';

/// 推理强度指示小竖条组 — 共 total 根，前 level+1 根点亮。
///
/// 高度从第 1 根到第 total 根逐步递增，模拟 mockup 的阶梯效果。
/// level = efforts.indexOf(currentEffort)。
class ReasoningEffortBars extends StatelessWidget {
  const ReasoningEffortBars({
    super.key,
    required this.total,
    required this.level,
    this.activeColor,
    this.inactiveColor,
  });

  final int total;
  final int level;
  final Color? activeColor;
  final Color? inactiveColor;

  @override
  Widget build(BuildContext context) {
    const barWidth = 3.0;
    const gap = 2.0;
    final maxHeight = 4.0 + (total - 1) * 2.4;
    return SizedBox(
      height: maxHeight,
      width: total * barWidth + (total - 1) * gap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < total; i++) ...[
            if (i > 0) const SizedBox(width: gap),
            Container(
              width: barWidth,
              height: 4 + i * 2.4,
              decoration: BoxDecoration(
                color: i <= level
                    ? (activeColor ?? _activeOf(context))
                    : (inactiveColor ?? _inactiveOf(context)),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _activeOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFC4956A)
      : const Color(0xFF8B6B4A);
  Color _inactiveOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF555555)
      : const Color(0xFFCDD3D8);
}

/// 把 effort wire 值映射到本地化标签（context.t 调用）。
String reasoningEffortLabelOf(BuildContext context, String? effort) {
  return switch (effort) {
    'none' => context.t(LocaleKeys.aiReasoningEffortNone),
    'on' => context.t(LocaleKeys.aiReasoningEffortOn),
    'minimal' => context.t(LocaleKeys.aiReasoningEffortMinimal),
    'low' => context.t(LocaleKeys.aiReasoningEffortLow),
    'medium' => context.t(LocaleKeys.aiReasoningEffortMedium),
    'high' => context.t(LocaleKeys.aiReasoningEffortHigh),
    'xhigh' => context.t(LocaleKeys.aiReasoningEffortXhigh),
    'max' => context.t(LocaleKeys.aiReasoningEffortMax),
    _ => effort ?? '',
  };
}

/// 把 effort wire 值映射到一行提示。
String reasoningEffortHintOf(BuildContext context, String? effort) {
  return switch (effort) {
    'none' => context.t(LocaleKeys.aiReasoningEffortHintNone),
    'on' => context.t(LocaleKeys.aiReasoningEffortHintOn),
    'minimal' => context.t(LocaleKeys.aiReasoningEffortHintMinimal),
    'low' => context.t(LocaleKeys.aiReasoningEffortHintLow),
    'medium' => context.t(LocaleKeys.aiReasoningEffortHintMedium),
    'high' => context.t(LocaleKeys.aiReasoningEffortHintHigh),
    'xhigh' => context.t(LocaleKeys.aiReasoningEffortHintXhigh),
    'max' => context.t(LocaleKeys.aiReasoningEffortHintMax),
    _ => '',
  };
}

/// 模型选项的默认 effort。
String? defaultEffortFor(AiModelOption? option) =>
    option?.defaultReasoningEffort;
