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

class PluginPageNavigation extends ConsumerWidget {
  const PluginPageNavigation({super.key, required this.builder});

  /// 只在至少有一个插件页面时调用；宿主负责分组标题与入口样式。
  final Widget Function(BuildContext context, List<PluginView> views) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(pluginStatusesProvider);
    final views = ref.read(pluginHostServiceProvider).views;
    if (views.isEmpty) {
      return const SizedBox.shrink();
    }
    return builder(context, views);
  }
}
