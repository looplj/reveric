// 职责: 移动端应用壳 — 底部 Tab 导航（小说/剧本/助手/设置），PageView 切换动效 + KeepAlive 保活各 Tab。
// 关联文件:
//   lib/mobile/widgets/tab_bar.dart
//   lib/mobile/providers/tab_providers.dart
//   lib/mobile/pages/library_page.dart
//   lib/mobile/pages/chat_page.dart
//   lib/mobile/pages/settings_page.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../shared/models/content_kind.dart';
import '../shared/theme/theme.dart';
import 'pages/library_page.dart';
import 'pages/chat_page.dart';
import 'pages/settings_page.dart';
import 'providers/tab_providers.dart';
import 'widgets/tab_bar.dart';

class MobileApp extends HookConsumerWidget {
  const MobileApp({super.key});

  static const _tabSwitchDuration = Duration(milliseconds: 280);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final index = ref.watch(mobileTabIndexProvider);
    final pageController = usePageController(initialPage: index);

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!pageController.hasClients) {
          return;
        }
        final current = pageController.page?.round() ?? index;
        if (current == index) {
          return;
        }
        pageController.animateToPage(
          index,
          duration: _tabSwitchDuration,
          curve: Curves.easeInOutCubic,
        );
      });
      return null;
    }, [index]);

    return Scaffold(
      backgroundColor: colors.canvas,
      body: PageView(
        controller: pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: const [
          _KeepAliveTab(
            child: MobileLibraryPage(contentKind: contentKindNovel),
          ),
          _KeepAliveTab(
            child: MobileLibraryPage(contentKind: contentKindScreenplay),
          ),
          _KeepAliveTab(child: MobileChatPage()),
          _KeepAliveTab(child: SettingsPage()),
        ],
      ),
      bottomNavigationBar: MobileTabBar(
        currentIndex: index,
        onTap: (i) => ref.read(mobileTabIndexProvider.notifier).set(i),
      ),
    );
  }
}

/// 保活 Tab 子页，对齐原 IndexedStack 的页面状态保留行为。
class _KeepAliveTab extends StatefulWidget {
  const _KeepAliveTab({required this.child});

  final Widget child;

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
