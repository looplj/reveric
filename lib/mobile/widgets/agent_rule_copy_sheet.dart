// 职责: 移动端跨作品复制智能体规则 — 在底部弹窗中选择来源作品、勾选规则并提交复制。
// 关联文件:
//   lib/mobile/pages/novel_agent_rule_manage_page.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/shared/components/reveric_search_field.dart
//   lib/shared/services/agent_rule_copy_service.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_rule.json
//   assets/translations/zh-CN/agent_rule.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/search-debounce.md
//   .agents/rules/error-handling.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/components/reveric_search_field.dart';
import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/agent_rule.dart';
import '../../shared/models/novel.dart';
import '../../shared/providers/agent_rule_providers.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/services/agent_rule_copy_service.dart';
import '../../shared/theme/theme.dart';
import 'section_scaffold.dart';

/// 打开移动端「从其他作品复制规则」底部弹窗，返回实际复制数。
Future<int?> showMobileAgentRuleCopySheet(
  BuildContext context, {
  required String databasePath,
  required String novelId,
}) {
  final theme = RevericTheme.of(context);
  final colors = RevericTheme.colorsOf(context);
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: colors.canvas,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    builder: (_) => RevericTheme(
      data: theme,
      child: _MobileAgentRuleCopySheet(
        databasePath: databasePath,
        novelId: novelId,
      ),
    ),
  );
}

class _MobileAgentRuleCopySheet extends HookConsumerWidget {
  const _MobileAgentRuleCopySheet({
    required this.databasePath,
    required this.novelId,
  });

  final String databasePath;
  final String novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final novelsAsync = ref.watch(novelsProvider);
    final currentRules =
        ref.watch(agentRulesStreamProvider(databasePath)).asData?.value ??
        const <AgentRule>[];
    final existingNames = {for (final rule in currentRules) rule.name};
    final search = useDebouncedSearch();
    final selectedNovelId = useState<String?>(null);
    final selectedRuleIds = useState<Set<String>>(const {});
    final copying = useState(false);

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

    useEffect(() {
      selectedRuleIds.value = const {};
      return null;
    }, [sourcePath]);

    final copyableRules = sourceRules
        .where((rule) => !existingNames.contains(rule.name))
        .toList(growable: false);
    final selectedCount = selectedRuleIds.value.length;

    void selectNovel(String id) {
      selectedNovelId.value = id;
    }

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
      if (rules.isEmpty || sourcePath == null) {
        return;
      }
      copying.value = true;
      try {
        final copied = await copyAgentRulesToNovel(
          targetService: ref.read(novelContentServiceProvider(databasePath)),
          currentRules: currentRules,
          sourceRules: rules,
          sourcePath: sourcePath,
          targetPath: databasePath,
        );
        if (context.mounted) {
          Navigator.of(context).pop(copied);
        }
      } catch (_) {
        if (context.mounted) {
          copying.value = false;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.agentRuleCopyFailed))),
          );
        }
      }
    }

    final sheetHeight = MediaQuery.sizeOf(context).height * 0.78;
    return SafeArea(
      child: SizedBox(
        height: sheetHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x4l,
            0,
            RevericSpacing.x4l,
            RevericSpacing.x5l,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (selectedNovel != null)
                    Semantics(
                      button: true,
                      label: context.t(LocaleKeys.agentRuleCopySourceNovel),
                      child: InkWell(
                        key: const ValueKey(
                          'mobile_agent_rule_copy_back_to_sources',
                        ),
                        onTap: copying.value
                            ? null
                            : () => selectedNovelId.value = null,
                        customBorder: const CircleBorder(),
                        child: Padding(
                          padding: const EdgeInsets.all(RevericSpacing.sm),
                          child: RevericIcon(
                            RevericIcons.arrow_back,
                            size: 20,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.all(RevericSpacing.sm),
                      child: RevericIcon(
                        RevericIcons.copy,
                        size: 20,
                        color: colors.accent,
                      ),
                    ),
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: Text(
                      context.t(LocaleKeys.agentRuleCopyFromNovel),
                      style: typo.heading2.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: context.t(LocaleKeys.commonCancel),
                    child: InkWell(
                      key: const ValueKey('mobile_agent_rule_copy_close'),
                      onTap: copying.value
                          ? null
                          : () => Navigator.of(context).pop(),
                      customBorder: const CircleBorder(),
                      child: Padding(
                        padding: const EdgeInsets.all(RevericSpacing.sm),
                        child: RevericIcon(
                          RevericIcons.close,
                          size: 20,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: RevericSpacing.md),
              Expanded(
                child: selectedNovel == null
                    ? _SourceNovelPicker(
                        novels: filteredNovels,
                        hasAnySource: sourceNovels.isNotEmpty,
                        searching: search.active,
                        searchController: search.controller,
                        selectedNovelId: selectedNovelId.value,
                        onSelect: selectNovel,
                      )
                    : _SourceRulePicker(
                        novel: selectedNovel,
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
              if (selectedNovel != null && !loadingSourceRules) ...[
                const SizedBox(height: RevericSpacing.md),
                FilledButton.icon(
                  onPressed: copying.value || selectedCount == 0 ? null : copy,
                  icon: copying.value
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const RevericIcon(RevericIcons.copy, size: 16),
                  label: Text(
                    context.t(
                      LocaleKeys.agentRuleCopyConfirm,
                      namedArgs: {'count': '$selectedCount'},
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceNovelPicker extends StatelessWidget {
  const _SourceNovelPicker({
    required this.novels,
    required this.hasAnySource,
    required this.searching,
    required this.searchController,
    required this.selectedNovelId,
    required this.onSelect,
  });

  final List<Novel> novels;
  final bool hasAnySource;
  final bool searching;
  final TextEditingController searchController;
  final String? selectedNovelId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RevericSearchField(
          controller: searchController,
          hint: context.t(LocaleKeys.agentRuleCopySearchNovelHint),
        ),
        const SizedBox(height: RevericSpacing.md),
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
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
                  itemCount: novels.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: RevericSpacing.sm),
                  itemBuilder: (context, index) {
                    final novel = novels[index];
                    final active = novel.id == selectedNovelId;
                    return _NovelPickerRow(
                      novel: novel,
                      active: active,
                      onTap: () => onSelect(novel.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _NovelPickerRow extends StatelessWidget {
  const _NovelPickerRow({
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.lg,
          vertical: RevericSpacing.lg,
        ),
        decoration: BoxDecoration(
          color: active ? colors.surfaceContainerHigh : colors.surface,
          border: Border.all(color: active ? colors.accent : colors.border),
          borderRadius: BorderRadius.circular(RevericRadius.large),
        ),
        child: Row(
          children: [
            RevericIcon(
              RevericIcons.menu_book_outlined,
              size: 18,
              color: active ? colors.accent : colors.textMuted,
            ),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Text(
                novel.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSmallSemibold.copyWith(
                  color: active ? colors.textPrimary : colors.textSecondary,
                ),
              ),
            ),
            RevericIcon(
              RevericIcons.chevron_right,
              size: 16,
              color: colors.textSubtle,
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceRulePicker extends StatelessWidget {
  const _SourceRulePicker({
    required this.novel,
    required this.loading,
    required this.rules,
    required this.existingNames,
    required this.selectedRuleIds,
    required this.onToggleRule,
    required this.onSelectAll,
    required this.onClear,
  });

  final Novel novel;
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
            Expanded(
              child: Text(
                novel.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
            ),
            Text(
              context.t(
                LocaleKeys.commonSelectedCountFmt,
                namedArgs: {'count': '${selectedRuleIds.length}'},
              ),
              style: typo.uiTinySemibold.copyWith(color: colors.textSubtle),
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.xs),
        Row(
          children: [
            TextButton(
              onPressed: onSelectAll,
              child: Text(context.t(LocaleKeys.commonSelectAll)),
            ),
            TextButton(
              onPressed: onClear,
              child: Text(context.t(LocaleKeys.commonClearSelection)),
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.xs),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
            itemCount: rules.length,
            separatorBuilder: (_, _) =>
                const SizedBox(height: RevericSpacing.sm),
            itemBuilder: (context, index) {
              final rule = rules[index];
              final exists = existingNames.contains(rule.name);
              return _RulePickerRow(
                rule: rule,
                exists: exists,
                selected: selectedRuleIds.contains(rule.id),
                onTap: exists ? null : () => onToggleRule(rule.id),
              );
            },
          ),
        ),
        if (rules.any((rule) => existingNames.contains(rule.name)))
          Padding(
            padding: const EdgeInsets.only(top: RevericSpacing.sm),
            child: Text(
              context.t(LocaleKeys.agentRuleCopyExistsHint),
              style: typo.uiTiny.copyWith(color: colors.textSubtle),
            ),
          ),
      ],
    );
  }
}

class _RulePickerRow extends StatelessWidget {
  const _RulePickerRow({
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: Opacity(
        opacity: exists ? 0.55 : 1,
        child: Container(
          padding: const EdgeInsets.all(RevericSpacing.lg),
          decoration: BoxDecoration(
            color: selected ? colors.surfaceContainerHigh : colors.surface,
            border: Border.all(
              color: selected ? colors.accent : colors.borderInput,
            ),
            borderRadius: BorderRadius.circular(RevericRadius.large),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CopyCheckMark(checked: selected, disabled: exists),
              const SizedBox(width: RevericSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            rule.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: typo.uiSmallSemibold.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        if (exists) ...[
                          const SizedBox(width: RevericSpacing.sm),
                          MobileSectionTagChip(
                            label: context.t(LocaleKeys.agentRuleCopyExists),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: RevericSpacing.xs),
                    Text(
                      rule.content.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmall.copyWith(
                        color: colors.textMuted,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CopyCheckMark extends StatelessWidget {
  const _CopyCheckMark({required this.checked, required this.disabled});

  final bool checked;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final borderColor = disabled ? colors.borderSubtle : colors.borderInput;
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: checked ? colors.accent : colors.surface.withValues(alpha: 0),
        border: Border.all(
          color: checked ? colors.accent : borderColor,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(RevericRadius.small),
      ),
      child: checked
          ? RevericIcon(RevericIcons.check, size: 14, color: colors.onAccent)
          : null,
    );
  }
}
