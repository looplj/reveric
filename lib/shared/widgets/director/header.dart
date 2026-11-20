// 职责: 导演台顶栏 — 展示保存状态或只读标题徽标、提供关闭/返回入口，居中承载视角下拉与画幅，右侧放宿主操作。
// 关联文件:
//   lib/shared/services/director/session.dart
//   lib/shared/widgets/director/workspace.dart
//   lib/shared/widgets/director/aspect.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json

import 'package:flutter/material.dart';

import '../../components/reveric_badge.dart';
import '../../components/reveric_icon_button.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../services/director/session.dart';
import '../../theme/theme.dart';
import 'aspect.dart';
import 'strings.dart';

class DirectorHeader extends StatelessWidget {
  const DirectorHeader({
    super.key,
    required this.session,
    required this.onBack,
    this.title,
    this.center,
    this.trailing,
  });
  final DirectorSession session;
  final VoidCallback onBack;

  /// 只读模式在顶栏左侧展示的调度标题（可写模式由宿主面包屑承载）。
  final String? title;

  /// 顶栏居中的控件（工作区传入视角下拉）。
  final Widget? center;

  /// 顶栏右侧的宿主操作（导出）；[compact] 时只放图标。
  final Widget? Function(bool compact)? trailing;

  /// 低于这个宽度时画幅和右侧操作只显示图标，给视角下拉和保存状态让位。
  static const double _compactWidth = 720;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          _build(context, compact: constraints.maxWidth < _compactWidth),
    );
  }

  Widget _build(BuildContext context, {required bool compact}) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final readOnly = session.readOnly;
    final resolvedTitle = (title ?? session.history.document.title).trim();
    return Container(
      constraints: const BoxConstraints(
        minHeight: RevericSizes.directorHeaderHeight,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.sm,
          vertical: RevericSpacing.xxs,
        ),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  RevericIconButton(
                    icon: readOnly
                        ? RevericIcons.arrow_back
                        : RevericIcons.close,
                    tooltip: readOnly
                        ? context.t(LocaleKeys.productionBackToCanvas)
                        : tr(context, 'back'),
                    onPressed: onBack,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  if (readOnly) ...[
                    Flexible(
                      child: Text(
                        resolvedTitle.isEmpty
                            ? tr(context, 'title')
                            : resolvedTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSmallSemibold.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    RevericBadge(
                      label: context.t(LocaleKeys.commonReadOnly),
                      color: colors.textMuted,
                    ),
                  ] else
                    Flexible(
                      child: Text(
                        tr(
                          context,
                          session.history.dirty || session.hasPendingInput
                              ? 'unsaved'
                              : 'saved',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                      ),
                    ),
                ],
              ),
            ),
            ?center,
            const SizedBox(width: RevericSpacing.sm),
            DirectorAspectButton(session: session, compact: compact),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: readOnly ? null : trailing?.call(compact),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
