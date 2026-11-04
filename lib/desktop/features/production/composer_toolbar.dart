// 职责: 排列生成输入栏的顶部工具行与底部参数栏，窄窗口换行，并把展开键和提交按钮固定在右侧。
// 关联文件:
//   lib/desktop/features/production/composer.dart
//   lib/desktop/features/production/image_composer.dart
//   lib/desktop/features/production/audio_composer.dart
//   lib/desktop/features/production/popover.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import 'popover.dart';

/// 输入框顶部常驻的一行：左侧是编辑提示词用的工具，右侧是展开键；
/// 参考素材另起一行放在它下面。
class ProductionComposerTools extends StatelessWidget {
  const ProductionComposerTools({
    super.key,
    required this.children,
    required this.expanded,
    required this.onExpand,
  });

  final List<Widget> children;
  final bool expanded;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Wrap(
          spacing: RevericSpacing.xs,
          runSpacing: RevericSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: children,
        ),
      ),
      const SizedBox(width: RevericSpacing.sm),
      ProductionToolButton(
        icon: expanded ? RevericIcons.arrows_in : RevericIcons.arrows_out,
        tooltip: context.t(
          expanded ? LocaleKeys.commonCollapse : LocaleKeys.commonExpand,
        ),
        onTap: onExpand,
      ),
    ],
  );
}

class ProductionComposerToolbar extends StatelessWidget {
  const ProductionComposerToolbar({
    super.key,
    required this.children,
    required this.submit,
  });

  final List<Widget> children;
  final Widget submit;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: RevericSpacing.sm,
          children: children,
        ),
      ),
      const SizedBox(width: RevericSpacing.sm),
      submit,
    ],
  );
}
