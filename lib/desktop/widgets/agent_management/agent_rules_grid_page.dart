// 职责: 小说编辑器内智能体规则卡片网格 — 列表浏览、搜索过滤、新建与跨作品复制入口。
// 关联文件:
//   lib/desktop/widgets/agent_management/home_management_cards.dart
//   lib/desktop/widgets/agent_management/agent_rule_edit_panel.dart
//   lib/desktop/widgets/agent_management/agent_rule_copy_dialog.dart
//   lib/shared/components/reveric_context_menu.dart
//   lib/shared/components/reveric_switch.dart
//   lib/shared/models/novel_workspace.dart
//   lib/shared/providers/agent_rule_providers.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_rule.json
//   assets/translations/zh-CN/agent_rule.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/hooks.md
//   .agents/rules/search-debounce.md

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/components/reveric_more_menu_button.dart';
import '../../../shared/components/reveric_search_field.dart';
import '../../../shared/components/reveric_switch.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/providers/agent_rule_providers.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import 'agent_rule_copy_dialog.dart';
import 'home_management_cards.dart';

final _log = AppLogger.forModule('AgentRulesGrid');

bool _matchesAgentRule(String query, AgentRule rule) {
  if (query.isEmpty) {
    return true;
  }
  final q = query.toLowerCase();
  return rule.name.toLowerCase().contains(q) ||
      rule.content.toLowerCase().contains(q);
}

class AgentRulesGridPage extends HookConsumerWidget {
  const AgentRulesGridPage({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.headerGestureExclusionKey,
    required this.onOpen,
    required this.onCreate,
    this.onBack,
  });

  final String databasePath;
  final String novelId;
  final GlobalKey headerGestureExclusionKey;
  final ValueChanged<AgentRule> onOpen;
  final VoidCallback onCreate;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rulesAsync = ref.watch(agentRulesStreamProvider(databasePath));
    final search = useDebouncedSearch();

    Future<void> copyFromOtherNovel() async {
      final copied = await showAgentRuleCopyDialog(
        context: context,
        databasePath: databasePath,
        novelId: novelId,
      );
      if (copied == null || copied == 0 || !context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.t(
              LocaleKeys.agentRuleCopySuccess,
              namedArgs: {'count': '$copied'},
            ),
          ),
        ),
      );
    }

    return HomeManagementScaffold(
      headerGestureExclusionKey: headerGestureExclusionKey,
      icon: RevericIcons.rule_outlined,
      titleKey: LocaleKeys.agentRuleTitle,
      createLabelKey: LocaleKeys.commonCreate,
      onCreate: onCreate,
      onBack: onBack,
      secondaryAction: TextButton.icon(
        onPressed: () => unawaited(copyFromOtherNovel()),
        icon: const RevericIcon(RevericIcons.copy, size: 16),
        label: Text(context.t(LocaleKeys.agentRuleCopyFromNovel)),
      ),
      child: rulesAsync.when(
        loading: () => const HomeManagementLoadingState(),
        error: (_, _) => HomeManagementErrorState(
          message: context.t(LocaleKeys.commonLoadFailed),
        ),
        data: (rules) {
          // 空列表也走 Grid：保留 hint / ·0 / 虚线新建卡，避免 rail-only
          // 宽主区下居中 EmptyState 显得空洞。
          final filtered = rules
              .where((rule) => _matchesAgentRule(search.query, rule))
              .toList(growable: false);
          return HomeManagementGrid(
            subtitleKey: LocaleKeys.agentRuleOverviewHint,
            sectionTitleKey: LocaleKeys.agentRuleTitle,
            itemCount: filtered.length,
            searchController: search.controller,
            searchHintKey: LocaleKeys.commonSearch,
            searchActive: search.active,
            createLabelKey: LocaleKeys.commonCreate,
            onCreate: onCreate,
            mainAxisExtent: 250,
            cards: [
              for (final rule in filtered)
                _AgentRuleCard(
                  key: ValueKey('novel_agent_rule_card_${rule.id}'),
                  databasePath: databasePath,
                  rule: rule,
                  onOpen: () => onOpen(rule),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _AgentRuleCard extends ConsumerWidget {
  const _AgentRuleCard({
    super.key,
    required this.databasePath,
    required this.rule,
    required this.onOpen,
  });

  final String databasePath;
  final AgentRule rule;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final reference = AiContextReference(
      kind: AiContextReferenceKind.agent_rule,
      section: NovelWorkspaceSection.overview,
      itemId: rule.id,
      label: rule.name,
    );

    Future<void> onToggleEnabled(bool enabled) async {
      try {
        await ref
            .read(novelContentServiceProvider(databasePath))
            .upsertAgentRule(
              rule.copyWith(enabled: enabled, updatedAt: DateTime.now()),
            );
      } catch (error, stackTrace) {
        _log.error(
          'toggle agent rule enabled failed id=${rule.id} enabled=$enabled',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      }
    }

    Future<void> onDelete() async {
      final confirmed = await showConfirmDialog(
        context,
        title: context.t(LocaleKeys.commonDelete),
        message: context.t(
          LocaleKeys.agentRuleDeleteConfirm,
          namedArgs: {'name': rule.name},
        ),
        confirmLabel: context.t(LocaleKeys.commonDelete),
        variant: ConfirmDialogVariant.error,
      );
      if (!confirmed || !context.mounted) {
        return;
      }
      try {
        await ref
            .read(novelContentServiceProvider(databasePath))
            .deleteAgentRule(rule.id);
      } catch (error, stackTrace) {
        _log.error(
          'delete agent rule failed id=${rule.id}',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonDeleteFailed))),
          );
        }
      }
    }

    final card = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(RevericRadius.xl),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        hoverColor: colors.hover,
        child: Container(
          padding: const EdgeInsets.all(RevericSpacing.x2l),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(RevericRadius.xl),
            border: Border.all(color: colors.borderInput),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const HomeManagementIconBadge(
                    icon: RevericIcons.rule_outlined,
                  ),
                  const SizedBox(width: RevericSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rule.name,
                          style: typo.uiSemibold.copyWith(
                            color: colors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: RevericSpacing.xs),
                        _AgentRuleStatusTag(enabled: rule.enabled),
                      ],
                    ),
                  ),
                  _AgentRuleMenu(onOpen: onOpen, onDelete: onDelete),
                ],
              ),
              const SizedBox(height: RevericSpacing.lg),
              Expanded(
                child: Text(
                  rule.content,
                  style: typo.uiSmall.copyWith(
                    color: colors.textMuted,
                    height: 1.45,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: RevericSpacing.lg),
              Divider(height: RevericSizes.dividerThickness),
              const SizedBox(height: RevericSpacing.md),
              Row(
                children: [
                  const Spacer(),
                  RevericSwitch(
                    value: rule.enabled,
                    onChanged: (enabled) => unawaited(onToggleEnabled(enabled)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    return Draggable<AiContextReference>(
      data: reference,
      feedback: _AgentRuleDragFeedback(rule: rule),
      childWhenDragging: Opacity(opacity: 0.55, child: card),
      child: card,
    );
  }
}

class _AgentRuleStatusTag extends StatelessWidget {
  const _AgentRuleStatusTag({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return HomeManagementMetaTag(
      icon: enabled ? RevericIcons.check_circle : RevericIcons.error_outline,
      label: context.t(
        enabled ? LocaleKeys.agentRuleEnabled : LocaleKeys.agentRuleDisabled,
      ),
      tone: enabled
          ? HomeManagementTagTone.success
          : HomeManagementTagTone.muted,
    );
  }
}

class _AgentRuleMenu extends StatelessWidget {
  const _AgentRuleMenu({required this.onOpen, required this.onDelete});

  final VoidCallback onOpen;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return RevericMoreMenuButton(
      entries: () => [
        RevericMenuItem(
          icon: RevericIcons.edit_outlined,
          iconColor: colors.textSecondary,
          label: context.t(LocaleKeys.commonEdit),
          onTap: onOpen,
        ),
        const RevericMenuDivider(),
        RevericMenuItem(
          icon: RevericIcons.delete_outline,
          iconColor: colors.warningText,
          labelColor: colors.warningText,
          label: context.t(LocaleKeys.commonDelete),
          onTap: () => unawaited(onDelete()),
        ),
      ],
    );
  }
}

class _AgentRuleDragFeedback extends StatelessWidget {
  const _AgentRuleDragFeedback({required this.rule});

  final AgentRule rule;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.lg,
          vertical: RevericSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          border: Border.all(color: colors.accent),
          boxShadow: [
            BoxShadow(
              color: colors.textPrimary.withValues(alpha: 0.12),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.rule_outlined,
              size: 14,
              color: colors.accent,
            ),
            const SizedBox(width: RevericSpacing.xs),
            Text(
              rule.name,
              style: typo.uiSmall.copyWith(color: colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 供外部创建「新建规则」草稿，与旧空态 / 中栏 + 行为一致。
AgentRule newAgentRuleDraft() {
  final now = DateTime.now();
  return AgentRule(
    id: '__new__${now.microsecondsSinceEpoch}',
    name: '',
    content: '',
    enabled: true,
    sortOrder: 0,
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}
