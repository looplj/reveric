// 职责: 观察当前可用的插件页面，交由宿主导航按自身样式渲染入口。
// 关联文件:
//   lib/shared/widgets/plugin_view/page.dart
//   lib/shared/providers/plugin_providers.dart
//   lib/desktop/pages/home.dart
//   lib/desktop/widgets/sidebar/rail.dart
//   lib/mobile/widgets/plugin_pages.dart
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../models/plugin/view.dart';
import '../../providers/plugin_providers.dart';
import '../../theme/theme.dart';

class PluginPageNavigation extends ConsumerWidget {
  const PluginPageNavigation({super.key, required this.builder});

  /// 只在至少有一个插件页面时调用；宿主负责分组标题与入口样式。
  final Widget Function(
    BuildContext context,
    List<PluginView> views,
    PluginPageBadge? Function(PluginView view) badgeOf,
  )
  builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(pluginStatusesProvider);
    final host = ref.read(pluginHostServiceProvider);
    final views = host.views;
    if (views.isEmpty) {
      return const SizedBox.shrink();
    }
    return builder(
      context,
      views,
      (view) => host.pageBadge(view.pluginId, view.id),
    );
  }
}

/// 插件页面导航入口上的计数胶囊或状态圆点，桌面侧栏与移动端入口共用。
class PluginPageBadgeIndicator extends StatelessWidget {
  const PluginPageBadgeIndicator({
    super.key,
    required this.badge,
    this.mobile = false,
  });

  final PluginPageBadge badge;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    if (!badge.isVisible) {
      return const SizedBox.shrink();
    }
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final background = switch (badge.tone) {
      PluginPageBadgeTone.danger => colors.error,
      PluginPageBadgeTone.warning => colors.warningText,
      PluginPageBadgeTone.accent => colors.accent,
    };
    final count = badge.count;
    if (count != null && count > 0) {
      final label = count > 99 ? '99+' : '$count';
      return Container(
        constraints: const BoxConstraints(
          minWidth: RevericSizes.badgeHeightSm,
          minHeight: RevericSizes.badgeHeightSm,
        ),
        padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.xxs),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(RevericRadius.capsule),
        ),
        child: Text(
          label,
          style: typo.uiTinySemibold.copyWith(
            color: colors.onAccent,
            height: 1,
          ),
        ),
      );
    }
    final dotSize = mobile
        ? RevericSizes.statusDotSizeMobile
        : RevericSizes.statusDotSize;
    return Container(
      width: dotSize,
      height: dotSize,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
    );
  }
}
