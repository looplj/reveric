// 职责: 桌面端技能广场 tab —— 按平台技能同款过滤栏与卡片网格展示广场链接,导入委托宿主。
// 关联文件:
//   lib/shared/widgets/agent_skill/marketplace_browser.dart
//   lib/desktop/features/agent_skills/catalog_filter_bar.dart
//   lib/desktop/features/agent_skills/source_card.dart
//   lib/desktop/features/agent_skills/catalog_states.dart
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

import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/agent_skill/marketplace_browser.dart';
import 'catalog_filter_bar.dart';
import 'catalog_states.dart';
import 'source_card.dart';

class MarketplaceCatalogTab extends HookConsumerWidget {
  const MarketplaceCatalogTab({super.key, this.onImport});
  final ValueChanged<String>? onImport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = useMarketplaceCatalog(context, ref);
    final skills = view.list.skills;
    final filtered = view.filtered;

    return Column(
      children: [
        CatalogFilterBar(
          categories: view.categories,
          selectedCategory: view.selectedCategory,
          onCategory: view.onCategory,
          searchController: view.searchController,
          trailing: MarketplaceRefreshButton(view: view),
        ),
        Divider(
          height: RevericSizes.dividerThickness,
          color: RevericTheme.colorsOf(context).borderSubtle,
        ),
        Expanded(
          child: skills == null || filtered == null
              ? view.list.error != null
                    ? CatalogErrorState(
                        message: context.t(
                          LocaleKeys.agentSkillMarketLoadFailed,
                        ),
                        onRetry: view.refresh,
                      )
                    : const CatalogLoadingState()
              : filtered.isEmpty
              ? CatalogEmptyState(
                  message: context.t(
                    skills.isEmpty
                        ? LocaleKeys.agentSkillMarketEmpty
                        : LocaleKeys.agentSkillMarketNoResults,
                  ),
                )
              : AgentSkillSourceCardGrid(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final skill = filtered[index];
                    return AgentSkillSourceCard(
                      key: ValueKey(skill.url),
                      badgeIcon: RevericIcons.storefront,
                      name: skill.name,
                      description: skill.description,
                      category: skill.category,
                      tags: skill.tags,
                      footerLeading: Uri.parse(skill.url).host,
                      onTap: () => view.open(skill.url),
                      secondary: AgentSkillSourceCardSecondaryAction(
                        icon: RevericIcons.arrow_square_out,
                        label: context.t(LocaleKeys.commonOpen),
                        onPressed: () => view.open(skill.url),
                      ),
                      primary: onImport != null && skill.canImport
                          ? AgentSkillSourceCardPrimaryAction(
                              labelKey: LocaleKeys.commonImport,
                              onPressed: () => onImport!(skill.url),
                            )
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}
