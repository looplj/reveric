// 职责: 从其他作品复制智能体规则 — 左栏选来源作品，右栏勾选规则并写入当前作品。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/shared/widgets/confirm_dialog.dart
//   lib/desktop/widgets/agent_management/agent_rules_grid_page.dart
//   lib/shared/providers/agent_rule_providers.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/services/agent_rule_copy_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_rule.json
//   assets/translations/zh-CN/agent_rule.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/hooks.md
//   .agents/rules/i18n.md
//   .agents/rules/search-debounce.md
//   .agents/rules/error-handling.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/dialog_feedback.dart';
import '../../../shared/components/reveric_search_field.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/novel.dart';
import '../../../shared/providers/agent_rule_providers.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/services/agent_rule_copy_service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/components/reveric_dialog.dart';

final _log = AppLogger.forModule('AgentRuleCopy');

/// 打开「从其他作品复制规则」对话框；返回实际复制的条数，取消时返回 null。
Future<int?> showAgentRuleCopyDialog({
  required BuildContext context,
  required String databasePath,
  required String novelId,
}) {
  return showRevericDialog<int>(
    context: context,
    builder: (_) => DialogFeedback.scope(
      builder: (_) =>
          _AgentRuleCopyDialog(databasePath: databasePath, novelId: novelId),
    ),
  );
}

class _AgentRuleCopyDialog extends HookConsumerWidget {
  const _AgentRuleCopyDialog({
    required this.databasePath,
    required this.novelId,
  });

  /// 当前作品的内容库路径，即复制的目标。
  final String databasePath;
  final String novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);

    final novelsAsync = ref.watch(novelsProvider);
    final currentRules =
        ref.watch(agentRulesStreamProvider(databasePath)).asData?.value ??
        const <AgentRule>[];
    final existingNames = {for (final rule in currentRules) rule.name};

    final search = useDebouncedSearch();
    final selectedNovelId = useState<String?>(null);
    final selectedRuleIds = useState<Set<String>>(const {});
    final copying = useState(false);

    // 只有建过内容库的其他作品才可能有规则可复制。
    final sourceNovels = (novelsAsync.asData?.value ?? const <Novel>[])
        .shelfVisible
        .where((novel) => novel.hasContentDatabase && novel.id != novelId)
        .toList(growable: false);
    final filteredNovels = sourceNovels
        .where(
          (novel) =>
              search.query.isEmpty ||
              novel.title.toLowerCase().contains(search.query) ||
              novel.category.toLowerCase().contains(search.query),
        )
        .toList(growable: false);

    final selectedNovel = sourceNovels
        .where((novel) => novel.id == selectedNovelId.value)
        .firstOrNull;
    final sourcePath = selectedNovel?.contentDatabasePath;

    final sourceRulesFuture = useMemoized(
      () => sourcePath == null
          ? Future.value(const <AgentRule>[])
          : ref.read(novelContentServiceProvider(sourcePath)).getAgentRules(),
      [sourcePath],
    );
    final sourceRulesSnapshot = useFuture(sourceRulesFuture);
    final sourceRules = sourceRulesSnapshot.data ?? const <AgentRule>[];
    final loadingSourceRules =
        sourcePath != null &&
        sourceRulesSnapshot.connectionState != ConnectionState.done;

    // 切换来源作品后旧勾选已失效，直接清空。
    useEffect(() {
      selectedRuleIds.value = const {};
      return null;
    }, [sourcePath]);

    final copyableRules = sourceRules
        .where((rule) => !existingNames.contains(rule.name))
        .toList(growable: false);
    final selectedCount = selectedRuleIds.value.length;

    void toggleRule(String id) {
      final next = Set<String>.from(selectedRuleIds.value);
      if (!next.remove(id)) {
        next.add(id);
      }
      selectedRuleIds.value = next;
    }

    Future<void> copy() async {
      final rules = copyableRules
          .where((rule) => selectedRuleIds.value.contains(rule.id))
          .toList(growable: false);
      if (rules.isEmpty) {
        return;
      }
      copying.value = true;
      try {
        final copied = await copyAgentRulesToNovel(
          targetService: ref.read(novelContentServiceProvider(databasePath)),
          currentRules: currentRules,
          sourceRules: rules,
          sourcePath: sourcePath ?? '',
          targetPath: databasePath,
        );
        if (context.mounted) {
          copying.value = false;
          Navigator.of(context).pop(copied);
        }
      } catch (error, stackTrace) {
        _log.error(
          'copy command failed source=$sourcePath target=$databasePath',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          copying.value = false;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: DialogToast(
                variant: DialogToastVariant.error,
                child: Text(context.t(LocaleKeys.agentRuleCopyFailed)),
              ),
            ),
          );
        }
        return;
      }
    }

    return RevericDialog.panel(
      title: Row(
        children: [
          RevericIcon(RevericIcons.copy, size: 18, color: colors.accent),
          const SizedBox(width: RevericSpacing.sm),
          Text(context.t(LocaleKeys.agentRuleCopyFromNovel)),
        ],
      ),
      content: DialogFeedback.surface(
        builder: (context) => SizedBox(
          width: 760,
          height: 480,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 240,
                child: _CopySourceNovelColumn(
                  novels: filteredNovels,
                  hasAnySource: sourceNovels.isNotEmpty,
                  searchController: search.controller,
                  searching: search.active,
                  selectedNovelId: selectedNovelId.value,
                  onSelect: (id) => selectedNovelId.value = id,
                ),
              ),
              Container(
                width: RevericSizes.dividerThickness,
                margin: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.x2l,
                ),
                color: colors.border,
              ),
              Expanded(
                child: _CopySourceRuleColumn(
                  hasSourceNovel: selectedNovel != null,
                  loading: loadingSourceRules,
                  rules: sourceRules,
                  existingNames: existingNames,
                  selectedRuleIds: selectedRuleIds.value,
                  onToggleRule: toggleRule,
                  onSelectAll: () => selectedRuleIds.value = {
                    for (final rule in copyableRules) rule.id,
                  },
                  onClear: () => selectedRuleIds.value = const {},
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        RevericButton.secondary(
          label: context.t(LocaleKeys.commonCancel),
          onPressed: copying.value ? null : () => Navigator.of(context).pop(),
        ),
        RevericButton.primary(
          label: context.t(
            LocaleKeys.agentRuleCopyConfirm,
            namedArgs: {'count': '$selectedCount'},
          ),
          icon: RevericIcons.copy,
          loading: copying.value,
          onPressed: selectedCount == 0 ? null : copy,
        ),
      ],
      width: 760 + RevericSpacing.x4l * 2,
    );
  }
}

/// 左栏：来源作品搜索 + 列表。
class _CopySourceNovelColumn extends StatelessWidget {
  const _CopySourceNovelColumn({
    required this.novels,
    required this.hasAnySource,
    required this.searchController,
    required this.searching,
    required this.selectedNovelId,
    required this.onSelect,
  });

  final List<Novel> novels;
  final bool hasAnySource;
  final TextEditingController searchController;
  final bool searching;
  final String? selectedNovelId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.t(LocaleKeys.agentRuleCopySourceNovel),
          style: typo.uiTinySemibold.copyWith(color: colors.textSubtle),
        ),
        const SizedBox(height: RevericSpacing.sm),
        RevericSearchField(
          controller: searchController,
          hint: context.t(LocaleKeys.agentRuleCopySearchNovelHint),
          height: 34,
        ),
        const SizedBox(height: RevericSpacing.sm),
        Expanded(
          child: novels.isEmpty
              ? Center(
                  child: Text(
                    context.t(
                      hasAnySource && searching
                          ? LocaleKeys.commonNoResults
                          : LocaleKeys.agentRuleCopyNoOtherNovels,
                    ),
                    textAlign: TextAlign.center,
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
                )
              : ListView.builder(
                  itemCount: novels.length,
                  itemBuilder: (context, index) {
                    final novel = novels[index];
                    return _CopySourceNovelItem(
                      novel: novel,
                      active: novel.id == selectedNovelId,
                      onTap: () => onSelect(novel.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _CopySourceNovelItem extends StatelessWidget {
  const _CopySourceNovelItem({
    required this.novel,
    required this.active,
    required this.onTap,
  });

  final Novel novel;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.xs),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.md,
          ),
          decoration: BoxDecoration(
            color: active ? colors.surfaceContainerHigh : Colors.transparent,
            border: Border.all(
              color: active ? colors.accent : Colors.transparent,
            ),
            borderRadius: BorderRadius.circular(RevericRadius.medium),
          ),
          child: Row(
            children: [
              RevericIcon(
                RevericIcons.menu_book_outlined,
                size: 14,
                color: active ? colors.accent : colors.textMuted,
              ),
              const SizedBox(width: RevericSpacing.xs),
              Expanded(
                child: Text(
                  novel.title,
                  style: typo.uiSmall.copyWith(
                    color: active ? colors.textPrimary : colors.textSecondary,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 右栏：来源作品的规则勾选列表。
class _CopySourceRuleColumn extends StatelessWidget {
  const _CopySourceRuleColumn({
    required this.hasSourceNovel,
    required this.loading,
    required this.rules,
    required this.existingNames,
    required this.selectedRuleIds,
    required this.onToggleRule,
    required this.onSelectAll,
    required this.onClear,
  });

  final bool hasSourceNovel;
  final bool loading;
  final List<AgentRule> rules;
  final Set<String> existingNames;
  final Set<String> selectedRuleIds;
  final ValueChanged<String> onToggleRule;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    if (!hasSourceNovel) {
      return Center(
        child: Text(
          context.t(LocaleKeys.agentRuleCopySelectNovelHint),
          style: typo.uiSmall.copyWith(color: colors.textMuted),
        ),
      );
    }
    if (loading) {
      return Center(child: CircularProgressIndicator(color: colors.accent));
    }
    if (rules.isEmpty) {
      return Center(
        child: Text(
          context.t(LocaleKeys.agentRuleCopySourceEmpty),
          style: typo.uiSmall.copyWith(color: colors.textMuted),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              context.t(
                LocaleKeys.commonSelectedCountFmt,
                namedArgs: {'count': '${selectedRuleIds.length}'},
              ),
              style: typo.uiTinySemibold.copyWith(color: colors.textSubtle),
            ),
            const Spacer(),
            RevericButton.secondary(
              size: RevericButtonSize.compact,
              label: context.t(LocaleKeys.commonSelectAll),
              onPressed: onSelectAll,
            ),
            const SizedBox(width: RevericSpacing.sm),
            RevericButton.secondary(
              size: RevericButtonSize.compact,
              label: context.t(LocaleKeys.commonClearSelection),
              onPressed: onClear,
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.sm),
        Expanded(
          child: ListView.builder(
            itemCount: rules.length,
            itemBuilder: (context, index) {
              final rule = rules[index];
              final exists = existingNames.contains(rule.name);
              return _CopyRuleRow(
                rule: rule,
                exists: exists,
                selected: selectedRuleIds.contains(rule.id),
                onTap: exists ? null : () => onToggleRule(rule.id),
              );
            },
          ),
        ),
        if (rules.any((rule) => existingNames.contains(rule.name))) ...[
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.agentRuleCopyExistsHint),
            style: typo.uiTiny.copyWith(color: colors.textSubtle),
          ),
        ],
      ],
    );
  }
}

class _CopyRuleRow extends StatelessWidget {
  const _CopyRuleRow({
    required this.rule,
    required this.exists,
    required this.selected,
    required this.onTap,
  });

  final AgentRule rule;
  final bool exists;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.xs),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Opacity(
          opacity: exists ? 0.55 : 1,
          child: Container(
            padding: const EdgeInsets.all(RevericSpacing.md),
            decoration: BoxDecoration(
              color: selected ? colors.surfaceContainerHigh : colors.surface,
              border: Border.all(
                color: selected ? colors.accent : colors.borderInput,
              ),
              borderRadius: BorderRadius.circular(RevericRadius.medium),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CopyCheckBox(checked: selected, disabled: exists),
                const SizedBox(width: RevericSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              rule.name,
                              style: typo.uiSmallSemibold.copyWith(
                                color: colors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (exists) ...[
                            const SizedBox(width: RevericSpacing.sm),
                            const _CopyExistsTag(),
                          ],
                        ],
                      ),
                      const SizedBox(height: RevericSpacing.xxs),
                      Text(
                        rule.content.trim(),
                        style: typo.uiTiny.copyWith(
                          color: colors.textMuted,
                          height: 1.45,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CopyExistsTag extends StatelessWidget {
  const _CopyExistsTag();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: RevericSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.textSubtle.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(RevericRadius.small),
      ),
      child: Text(
        context.t(LocaleKeys.agentRuleCopyExists),
        style: typo.uiTiny.copyWith(color: colors.textSubtle),
      ),
    );
  }
}

class _CopyCheckBox extends StatelessWidget {
  const _CopyCheckBox({required this.checked, required this.disabled});

  final bool checked;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final borderColor = disabled ? colors.borderSubtle : colors.borderInput;

    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: checked ? colors.accent : Colors.transparent,
        border: Border.all(
          color: checked ? colors.accent : borderColor,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(RevericRadius.small),
      ),
      child: checked
          ? RevericIcon(RevericIcons.check, size: 12, color: colors.onAccent)
          : null,
    );
  }
}
