// 职责: 插件详情与安装预览的页面外壳 — 桌面嵌在设置内容区并带返回路径，移动端为全屏页。
// 关联文件:
//   lib/shared/widgets/settings/plugins/detail_page.dart
//   lib/shared/widgets/settings/plugins/preview_page.dart
//   lib/shared/widgets/settings/mcp/server_editor.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import '../../../components/reveric_icon_button.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../theme/theme.dart';

class PluginSubpage extends StatelessWidget {
  const PluginSubpage({
    super.key,
    required this.title,
    required this.mobile,
    required this.onBack,
    required this.children,
    this.footer,
  });

  final String title;
  final bool mobile;

  /// 返回列表；为 null 时禁用返回（如安装进行中）。
  final VoidCallback? onBack;

  /// 页面正文分区，按顺序纵向排列。
  final List<Widget> children;

  /// 固定在滚动区下方的操作栏。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final horizontal = mobile ? RevericSpacing.x3l : RevericSpacing.x4l;
    // 详情内含配置表单，整页不惰性回收，保证离屏字段仍随表单存活。
    final content = SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        mobile ? RevericSpacing.lg : RevericSpacing.x2l,
        horizontal,
        RevericSpacing.x4l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, child) in children.indexed) ...[
            if (index > 0) const SizedBox(height: RevericSpacing.x2l),
            child,
          ],
        ],
      ),
    );
    final bar = footer == null
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Divider(
                height: RevericSizes.dividerThickness,
                thickness: RevericSizes.dividerThickness,
                color: colors.borderSubtle,
              ),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: horizontal,
                  vertical: RevericSpacing.md,
                ),
                child: footer,
              ),
            ],
          );
    if (mobile) {
      return Scaffold(
        backgroundColor: colors.canvas,
        appBar: AppBar(
          backgroundColor: colors.surfaceDim,
          elevation: 0,
          leading: RevericIconButton(
            icon: RevericIcons.arrow_back,
            tooltip: context.t(LocaleKeys.commonBack),
            onPressed: onBack,
          ),
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: typo.heading2.copyWith(color: colors.textPrimary),
          ),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(child: content),
              ?bar,
            ],
          ),
        ),
      );
    }
    final page = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.lg,
            RevericSpacing.md,
            RevericSpacing.x4l,
            RevericSpacing.md,
          ),
          child: Row(
            children: [
              RevericIconButton(
                icon: RevericIcons.arrow_back,
                tooltip: context.t(LocaleKeys.commonBack),
                onPressed: onBack,
              ),
              const SizedBox(width: RevericSpacing.xs),
              Text(
                context.t(LocaleKeys.settingsPlugins),
                style: typo.ui.copyWith(color: colors.textMuted),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.xs,
                ),
                child: RevericIcon(
                  RevericIcons.keyboard_arrow_right,
                  size: RevericSizes.buttonIconSize,
                  color: colors.textSubtle,
                ),
              ),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
        ),
        Divider(
          height: RevericSizes.dividerThickness,
          thickness: RevericSizes.dividerThickness,
          color: colors.borderSubtle,
        ),
        Expanded(child: content),
        ?bar,
      ],
    );
    // 嵌在设置弹窗里：Esc 和点遮罩先回到列表，不直接关掉整个设置。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          onBack?.call();
        }
      },
      child: page,
    );
  }
}
