// 职责: 移动端技能广场 tab —— 按平台技能同款类别条与卡片列表展示广场链接,导入走移动端导入 sheet。
// 关联文件:
//   lib/shared/widgets/agent_skill/marketplace_browser.dart
//   lib/mobile/features/agent_skills/import_flow.dart
//   lib/mobile/features/agent_skills/category_filter_bar.dart
//   lib/mobile/features/agent_skills/tab_states.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_search_field.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/marketplace_agent_skill.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/agent_skill/marketplace_browser.dart';
import '../../widgets/section_scaffold.dart';
import 'category_filter_bar.dart';
import 'import_flow.dart';
import 'tab_states.dart';

class MarketplaceAgentSkillTab extends HookConsumerWidget {
  const MarketplaceAgentSkillTab({super.key, this.onImport});
  final ValueChanged<String>? onImport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = useMarketplaceCatalog(context, ref);
    final skills = view.list.skills;
    final filtered = view.filtered;
    final importUrl =
        onImport ??
        (url) => importMobileAgentSkills(context, ref, initialUrl: url);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x4l,
            RevericSpacing.md,
            RevericSpacing.x4l,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: RevericSearchField(
                  controller: view.searchController,
                  hint: context.t(LocaleKeys.agentSkillSearchPlaceholder),
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              MarketplaceRefreshButton(view: view),
            ],
          ),
        ),
        if (view.categories.isNotEmpty)
          SkillCategoryFilterBar(
            categories: view.categories,
            selected: view.selectedCategory,
            onSelect: view.onCategory,
          ),
        Expanded(
          child: skills == null || filtered == null
              ? view.list.error != null
                    ? SkillTabErrorRetry(
                        message: context.t(
                          LocaleKeys.agentSkillMarketLoadFailed,
                        ),
                        onRetry: view.refresh,
                      )
                    : const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
              ? SkillTabEmptyState(
                  icon: RevericIcons.storefront,
                  message: context.t(
                    skills.isEmpty
                        ? LocaleKeys.agentSkillMarketEmpty
                        : LocaleKeys.agentSkillMarketNoResults,
                  ),
                )
              : ListView.separated(
                  key: const PageStorageKey('skill-marketplace-list'),
                  padding: const EdgeInsets.fromLTRB(
                    RevericSpacing.x4l,
                    RevericSpacing.md,
                    RevericSpacing.x4l,
                    RevericSpacing.x5l,
                  ),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: RevericSpacing.sm),
                  itemBuilder: (context, index) {
                    final skill = filtered[index];
                    return _MarketplaceSkillCard(
                      key: ValueKey(skill.url),
                      skill: skill,
                      onOpen: () => view.open(skill.url),
                      onImport: skill.canImport
                          ? () => importUrl(skill.url)
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 广场链接卡片 — 与官方技能卡片同构:head / desc / meta / foot(来源域名 + 打开 / 导入)。
class _MarketplaceSkillCard extends StatelessWidget {
  const _MarketplaceSkillCard({
    super.key,
    required this.skill,
    required this.onOpen,
    this.onImport,
  });

  final MarketplaceAgentSkill skill;
  final VoidCallback onOpen;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Material(
      color: colors.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.large),
        side: BorderSide(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(RevericSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.accent.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(RevericRadius.large),
                    ),
                    child: RevericIcon(
                      RevericIcons.storefront,
                      size: 17,
                      color: colors.accent,
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.md),
                  Expanded(
                    child: Text(
                      skill.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: RevericSpacing.sm),
              MobileSectionPreviewText(
                preview: skill.description,
                emptyPlaceholder: context.t(LocaleKeys.agentSkillDescription),
              ),
              if (skill.category.isNotEmpty || skill.tags.isNotEmpty) ...[
                const SizedBox(height: RevericSpacing.xs),
                Wrap(
                  spacing: RevericSpacing.xs,
                  runSpacing: RevericSpacing.xxs,
                  children: [
                    if (skill.category.isNotEmpty)
                      MobileSectionTagChip(label: skill.category),
                    for (final t in skill.tags) MobileSectionTagChip(label: t),
                  ],
                ),
              ],
              const SizedBox(height: RevericSpacing.md),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.borderSubtle)),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(top: RevericSpacing.md),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          Uri.parse(skill.url).host,
                          style: typo.uiTiny.copyWith(color: colors.textSubtle),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: onOpen,
                        icon: const RevericIcon(
                          RevericIcons.arrow_square_out,
                          size: 14,
                        ),
                        label: Text(context.t(LocaleKeys.commonOpen)),
                      ),
                      if (onImport != null) ...[
                        const SizedBox(width: RevericSpacing.xs),
                        OutlinedButton.icon(
                          onPressed: onImport,
                          icon: const RevericIcon(
                            RevericIcons.download,
                            size: 14,
                          ),
                          label: Text(context.t(LocaleKeys.commonImport)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
