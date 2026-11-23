// 职责: 移动端实体详情/编辑页共享布局 — slist 字段行与行内选择器、分区标题、左对齐标题输入（对齐 designs/mobile CharacterDetail / WorldDetail 紧凑版）。
// 关联文件:
//   lib/mobile/widgets/editor_app_bar.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/shared/components/reveric_select.dart
//   lib/shared/theme/theme.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
import 'package:flutter/material.dart';

import '../../shared/components/reveric_select.dart';
import '../../shared/theme/theme.dart';

/// 详情页正文区内边距（对齐 mock viewport padding 8–20 / 28）。
const EdgeInsets mobileDetailBodyPadding = EdgeInsets.fromLTRB(
  RevericSpacing.x4l,
  RevericSpacing.sm,
  RevericSpacing.x4l,
  RevericSpacing.x5l,
);

/// slist 容器：surface 底 + 圆角 + 行间分隔线（对齐 mock `.slist`）。
class MobileDetailFieldList extends StatelessWidget {
  const MobileDetailFieldList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(height: 1, thickness: 1, color: colors.borderSubtle),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 设置与 AI 管理页共用的导航行。
class MobileDetailNavRow extends StatelessWidget {
  const MobileDetailNavRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
    this.trailing,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;
  final String? value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: RevericSizes.touchTargetSize,
          ),
          child: Padding(
            padding: const EdgeInsets.all(RevericSpacing.lg),
            child: Row(
              children: [
                RevericIcon(
                  icon,
                  size: RevericSizes.iconButtonIconSize,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: RevericSpacing.lg),
                Expanded(
                  flex: 3,
                  child: Text(
                    label,
                    style: typo.ui.copyWith(color: colors.textPrimary),
                  ),
                ),
                if (value case final value? when value.isNotEmpty) ...[
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    flex: 2,
                    child: Text(
                      value,
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  ),
                ],
                const SizedBox(width: RevericSpacing.xs),
                trailing ??
                    RevericIcon(
                      RevericIcons.chevron_right,
                      size: RevericSizes.iconButtonIconSize,
                      color: colors.textSubtle,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// slist 单行：左侧标签 + 右侧值（对齐 mock `.srow`）。
class MobileDetailFieldRow extends StatelessWidget {
  const MobileDetailFieldRow({
    super.key,
    required this.label,
    required this.child,
    this.onTap,
  });

  final String label;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.lg,
        vertical: RevericSpacing.lg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
    if (onTap == null) {
      return row;
    }
    return InkWell(onTap: onTap, child: row);
  }
}

/// slist 行内选择器：无边框、值靠右 + 下拉箭头，与 [MobileDetailLinkRow] 的值同字重。
class MobileDetailSelect<T> extends StatelessWidget {
  const MobileDetailSelect({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T? value;
  final List<RevericSelectItem<T>> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final typo = RevericTheme.typographyOf(context);
    return RevericSelect<T>(
      value: value,
      items: items,
      onChanged: onChanged,
      compact: true,
      alignEnd: true,
      // 行本身已有上下内边距，触发器只占一行文字高度。
      height: 24,
      textStyle: typo.uiSmallSemibold,
    );
  }
}

/// 详情页分区小标题（对齐 mock `SectionLabel`）。
class MobileDetailSectionLabel extends StatelessWidget {
  const MobileDetailSectionLabel({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
      child: Text(
        text,
        style: typo.uiSemibold.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

/// 大标题输入（serif / display，无边框；用于详情页内编辑名称/标题）。
class MobileDetailTitleField extends StatelessWidget {
  const MobileDetailTitleField({
    super.key,
    required this.controller,
    required this.hintText,
    this.onChanged,
    this.errorText,
    this.textAlign = TextAlign.start,
    this.undoController,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final String? errorText;
  final TextAlign textAlign;
  final UndoHistoryController? undoController;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return TextField(
      controller: controller,
      undoController: undoController,
      onChanged: onChanged,
      maxLines: 1,
      textInputAction: TextInputAction.next,
      textAlign: textAlign,
      style: typo.display.copyWith(color: colors.textPrimary),
      decoration: InputDecoration(
        isCollapsed: errorText == null,
        errorText: errorText,
        // 主题 inputDecorationTheme 带 14px 水平内边距，不清零标题会比下方卡片多缩进一截。
        contentPadding: EdgeInsets.zero,
        border: InputBorder.none,
        hintText: hintText,
        hintStyle: typo.display.copyWith(color: colors.textSubtle),
      ),
    );
  }
}

/// 章节/链接型字段行（值右对齐 + chevron），用于 slist 内。
class MobileDetailLinkRow extends StatelessWidget {
  const MobileDetailLinkRow({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return MobileDetailFieldRow(
      label: label,
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: RevericSpacing.xxs),
          RevericIcon(
            RevericIcons.chevron_right,
            size: 16,
            color: colors.textSubtle,
          ),
        ],
      ),
    );
  }
}
