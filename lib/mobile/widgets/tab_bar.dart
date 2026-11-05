// 职责: 移动端底部 Tab 栏 — 小说/剧本/AI/设置 四个根 Tab 的图标+文字与选中态。
// 关联文件:
//   lib/mobile/app.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
import 'package:flutter/material.dart';

import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/update/badge.dart';

class MobileTabItem {
  const MobileTabItem({required this.icon, required this.labelKey});

  final String icon;
  final String labelKey;
}

const List<MobileTabItem> mobileTabItems = [
  MobileTabItem(
    icon: RevericIcons.menu_book_rounded,
    labelKey: LocaleKeys.mobileTabNovels,
  ),
  MobileTabItem(
    icon: RevericIcons.movie_outlined,
    labelKey: LocaleKeys.mobileTabScreenplays,
  ),
  MobileTabItem(
    icon: RevericIcons.auto_awesome,
    labelKey: LocaleKeys.mobileTabAssistant,
  ),
  MobileTabItem(
    icon: RevericIcons.settings_outlined,
    labelKey: LocaleKeys.mobileTabSettings,
  ),
];

class MobileTabBar extends StatelessWidget {
  const MobileTabBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.borderSubtle)),
      ),
      padding: EdgeInsets.only(
        left: RevericSpacing.sm,
        right: RevericSpacing.sm,
        top: RevericSpacing.sm,
        bottom: bottomInset + RevericSpacing.xs,
      ),
      child: Row(
        children: [
          for (var i = 0; i < mobileTabItems.length; i++)
            Expanded(
              child: _buildTab(
                context,
                colors,
                typo,
                item: mobileTabItems[i],
                isActive: i == currentIndex,
                onTap: () => onTap(i),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTab(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo, {
    required MobileTabItem item,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    final targetColor = isActive ? colors.accent : colors.textSubtle;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xxs),
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: targetColor),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOutCubic,
          builder: (context, color, _) {
            final resolved = color ?? targetColor;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.labelKey == LocaleKeys.mobileTabSettings)
                  UpdateBadge(
                    child: RevericIcon(item.icon, size: 24, color: resolved),
                  )
                else
                  RevericIcon(item.icon, size: 24, color: resolved),
                const SizedBox(height: 3),
                Text(
                  context.t(item.labelKey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: typo.uiTinySemibold.copyWith(color: resolved),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
