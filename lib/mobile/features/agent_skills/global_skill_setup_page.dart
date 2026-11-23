// 职责: 展示移动端全局技能与平台技能目录。
// 关联文件:
//   lib/mobile/features/agent_skills/novel_agent_skill_manage_page.dart
//   lib/mobile/features/agent_skills/official_tab.dart
//   lib/mobile/features/agent_skills/marketplace_tab.dart
//   lib/shared/widgets/guide/trigger.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/onboarding.json
//   assets/translations/zh-CN/onboarding.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/error-handling.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/guide/tour.dart';
import '../../../shared/widgets/guide/trigger.dart';
import 'novel_agent_skill_manage_page.dart';
import 'official_tab.dart';
import 'marketplace_tab.dart';

/// 移动端 AgentSkill Setup 全局页(无小说上下文)。
///
class GlobalSkillSetupPage extends HookConsumerWidget {
  const GlobalSkillSetupPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabController = useTabController(initialLength: 3);
    final listGuideKey = useMemoized(GlobalKey.new);
    final marketGuideKey = useMemoized(GlobalKey.new);
    final colors = RevericTheme.colorsOf(context);
    useAutoGuideTour(
      ref: ref,
      tourId: GuideTourId.skills,
      buildSteps: (ctx) => [
        GuideStep(
          id: 'skills_list',
          targetKey: listGuideKey,
          icon: RevericIcons.layers_outlined,
          title: ctx.t(LocaleKeys.onboardingGuideSkillsListTitle),
          description: ctx.t(LocaleKeys.onboardingGuideSkillsListBody),
          onBeforeEnter: () {
            if (tabController.index != 0) {
              tabController.index = 0;
            }
          },
        ),
        GuideStep(
          id: 'skills_market',
          targetKey: marketGuideKey,
          icon: RevericIcons.storefront,
          title: ctx.t(LocaleKeys.onboardingGuideSkillsMarketTitle),
          description: ctx.t(LocaleKeys.onboardingGuideSkillsMarketBody),
          onBeforeEnter: () {
            if (tabController.index != 2) {
              tabController.index = 2;
            }
          },
        ),
      ],
    );

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              title: context.t(LocaleKeys.agentSkillSetupHomeTitle),
              onClose: () => Navigator.of(context).maybePop(),
            ),
            Divider(height: 1, thickness: 1, color: colors.borderSubtle),
            _TabBar(controller: tabController),
            Divider(height: 1, thickness: 1, color: colors.borderSubtle),
            Expanded(
              child: TabBarView(
                controller: tabController,
                children: [
                  KeyedSubtree(
                    key: listGuideKey,
                    child: const NovelInstalledSkillsView(),
                  ),
                  const OfficialAgentSkillTab(),
                  KeyedSubtree(
                    key: marketGuideKey,
                    child: const MarketplaceAgentSkillTab(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 内部组件 ─────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.xs,
        RevericSpacing.sm,
        RevericSpacing.xs,
        RevericSpacing.sm,
      ),
      child: Row(
        children: [
          InkWell(
            onTap: onClose,
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(RevericSpacing.sm),
              child: RevericIcon(
                RevericIcons.arrow_back,
                size: 22,
                color: colors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.heading2.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: RevericSpacing.xl),
        ],
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.controller});

  final TabController controller;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return TabBar(
      controller: controller,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      labelColor: colors.accent,
      unselectedLabelColor: colors.textSecondary,
      indicatorColor: colors.accent,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: typo.uiSmallSemibold,
      unselectedLabelStyle: typo.uiSmall,
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.sm),
      tabs: [
        Tab(text: context.t(LocaleKeys.agentSkillTabInstalled)),
        Tab(text: context.t(LocaleKeys.agentSkillTabOfficial)),
        Tab(text: context.t(LocaleKeys.agentSkillTabMarket)),
      ],
    );
  }
}
