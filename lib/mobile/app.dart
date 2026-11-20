// 职责: 移动端应用壳 — 底部 Tab 导航（小说/剧本/助手/设置），PageView 切换动效 + KeepAlive 保活各 Tab。
// 关联文件:
//   lib/mobile/widgets/tab_bar.dart
//   lib/mobile/providers/tab_providers.dart
//   lib/mobile/pages/library_page.dart
//   lib/mobile/pages/chat_page.dart
//   lib/mobile/pages/settings_page.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../shared/localization/app_localization.dart';
import '../shared/localization/locale_keys.dart';
import '../shared/models/content_kind.dart';
import '../shared/theme/theme.dart';
import '../shared/widgets/guide/tour.dart';
import '../shared/widgets/guide/trigger.dart';
import 'pages/ai_providers_settings_page.dart';
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
    final tabKeys = useMemoized(() => List.generate(4, (_) => GlobalKey()));
    useAutoGuideTour(
      ref: ref,
      tourId: GuideTourId.home,
      buildSteps: (ctx) => [
        GuideStep(
          id: 'mobile_home_novel',
          targetKey: tabKeys[0],
          icon: RevericIcons.menu_book_rounded,
          title: ctx.t(LocaleKeys.onboardingGuideHomeNovelTitle),
          description: ctx.t(LocaleKeys.onboardingGuideHomeNovelBody),
        ),
        GuideStep(
          id: 'mobile_home_screenplay',
          targetKey: tabKeys[1],
          icon: RevericIcons.movie_outlined,
          title: ctx.t(LocaleKeys.onboardingGuideHomeScreenplayTitle),
          description: ctx.t(
            LocaleKeys.onboardingGuideHomeMobileScreenplayBody,
          ),
        ),
        GuideStep(
          id: 'mobile_home_assistant',
          targetKey: tabKeys[2],
          icon: RevericIcons.auto_awesome,
          title: ctx.t(LocaleKeys.onboardingGuideHomeMobileAssistantTitle),
          description: ctx.t(LocaleKeys.onboardingGuideHomeMobileAssistantBody),
        ),
        GuideStep(
          id: 'mobile_home_settings',
          targetKey: tabKeys[3],
          icon: RevericIcons.settings_outlined,
          title: ctx.t(LocaleKeys.onboardingGuideHomeMobileSettingsTitle),
          description: ctx.t(LocaleKeys.onboardingGuideHomeMobileSettingsBody),
          primaryActionLabel: ctx.t(LocaleKeys.onboardingGuideGoProviders),
          onPrimaryAction: () =>
              unawaited(openMobileAiProvidersSettingsPage(context)),
        ),
      ],
    );

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
        tabKeys: tabKeys,
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
