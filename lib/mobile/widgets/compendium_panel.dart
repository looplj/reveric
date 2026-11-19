// 职责: 展示移动端图鉴的搜索、分类计数和折叠条目，并提供类型选择入口。
// 关联文件:
//   lib/mobile/pages/novel_editor_page.dart
//   lib/mobile/pages/entry_editor_page.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/components/reveric_search_field.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/search-debounce.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/components/reveric_search_field.dart';
import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../pages/entry_editor_page.dart';
import 'compendium_entry_row.dart';
import 'section_scaffold.dart';

const _sections = [
  MobileEditorSection.factions,
  MobileEditorSection.creatures,
  MobileEditorSection.items,
  MobileEditorSection.skills,
];

Future<MobileEditorSection?> showMobileCompendiumCreateSheet(
  BuildContext context,
) {
  final colors = RevericTheme.colorsOf(context);
  return showModalBottomSheet<MobileEditorSection>(
    context: context,
    backgroundColor: colors.surface,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .9,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final section in _sections)
              ListTile(
                leading: RevericIcon(section.listIcon, color: colors.accent),
                title: Text(context.t(section.newLabelKey)),
                onTap: () => Navigator.of(context).pop(section),
              ),
          ],
        ),
      ),
    ),
  );
}

class MobileCompendiumPanel extends HookConsumerWidget {
  const MobileCompendiumPanel({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.onCreate,
  });

  final String databasePath;
  final String novelId;
  final ValueChanged<MobileEditorSection> onCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useAutomaticKeepAlive();
    final filter = useState<MobileEditorSection?>(null);
    final expanded = useState(<MobileEditorSection>{});
    final search = useDebouncedSearch();
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final states = {
      for (final section in _sections)
        section: ref.watch(
          itemsProvider(path: databasePath, type: section.typeValue),
        ),
    };
    final entries = {
      for (final section in _sections)
        section: states[section]!.value ?? const <Item>[],
    };
    final rows = <({MobileEditorSection section, Item? item, int count})>[];
    for (final section in _sections) {
      if (filter.value != null && filter.value != section) {
        continue;
      }
      final matches = entries[section]!.where((entry) {
        return !search.active ||
            '${entry.title} ${entry.content} ${entry.category}'
                .toLowerCase()
                .contains(search.query);
      }).toList();
      if (search.active && matches.isEmpty) {
        continue;
      }
      rows.add((section: section, item: null, count: matches.length));
      if (expanded.value.contains(section) || search.active) {
        for (final entry in matches) {
          rows.add((section: section, item: entry, count: 0));
        }
      }
    }

    Future<void> create() async {
      final section =
          filter.value ?? await showMobileCompendiumCreateSheet(context);
      if (section != null && context.mounted) {
        onCreate(section);
      }
    }

    final total = entries.values.fold(0, (sum, list) => sum + list.length);
    final unavailable = states.values.any((state) => !state.hasValue);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x3l),
      child: Column(
        children: [
          const SizedBox(height: RevericSpacing.lg),
          RevericSearchField(
            controller: search.controller,
            hint: context.t(LocaleKeys.commonSearch),
            height: kMinInteractiveDimension,
            radius: RevericRadius.x2l,
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xxs),
            child: Row(
              children: [
                for (final section in [null, ..._sections])
                  Padding(
                    padding: const EdgeInsets.only(right: RevericSpacing.xs),
                    child: Semantics(
                      selected: filter.value == section,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(RevericRadius.pill),
                        onTap: () {
                          filter.value = section;
                          if (section != null) {
                            expanded.value = {...expanded.value, section};
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: RevericSpacing.sm,
                          ),
                          child: Container(
                            constraints: const BoxConstraints(
                              minHeight: RevericSizes.buttonHeightSm,
                            ),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(
                              horizontal: RevericSpacing.sm,
                            ),
                            decoration: BoxDecoration(
                              color: filter.value == section
                                  ? colors.accent
                                  : colors.surface,
                              borderRadius: BorderRadius.circular(
                                RevericRadius.pill,
                              ),
                              border: Border.all(
                                color: filter.value == section
                                    ? colors.accent
                                    : colors.borderSubtle,
                              ),
                            ),
                            child: Text(
                              '${context.t(section?.labelKey ?? LocaleKeys.commonFilterAll)} ${section == null ? total : entries[section]!.length}',
                              style: typo.uiTiny.copyWith(
                                color: filter.value == section
                                    ? colors.onAccent
                                    : colors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: unavailable
                ? Center(
                    child: states.values.any((state) => state.hasError)
                        ? TextButton(
                            onPressed: () {
                              for (final section in _sections) {
                                ref.invalidate(
                                  itemsProvider(
                                    path: databasePath,
                                    type: section.typeValue,
                                  ),
                                );
                              }
                            },
                            child: Text(
                              '${context.t(LocaleKeys.commonLoadFailed)} · ${context.t(LocaleKeys.commonRetry)}',
                            ),
                          )
                        : const CircularProgressIndicator(),
                  )
                : rows.isEmpty
                ? Center(
                    child: Text(
                      context.t(LocaleKeys.commonNoResults),
                      style: typo.ui.copyWith(color: colors.textMuted),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.only(
                      bottom:
                          MediaQuery.viewPaddingOf(context).bottom +
                          RevericSpacing.x5l,
                    ),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final entry = row.item;
                      if (entry != null) {
                        return CompendiumEntryRow(
                          novelId: novelId,
                          key: ValueKey(entry.id),
                          databasePath: databasePath,
                          section: row.section,
                          entry: entry,
                        );
                      }
                      final open =
                          expanded.value.contains(row.section) || search.active;
                      return Material(
                        color: colors.surface,
                        child: ListTile(
                          leading: MobileSectionIconBox(
                            icon: row.section.listIcon,
                            tint: row.section.listTint(colors),
                          ),
                          title: Text(
                            context.t(row.section.labelKey),
                            style: typo.uiSemibold.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${row.count}',
                                style: typo.uiSmall.copyWith(
                                  color: colors.textMuted,
                                ),
                              ),
                              const SizedBox(width: RevericSpacing.sm),
                              RevericIcon(
                                open
                                    ? RevericIcons.expand_more
                                    : RevericIcons.chevron_right,
                                color: colors.textSubtle,
                              ),
                            ],
                          ),
                          onTap: () {
                            final next = {...expanded.value};
                            if (!next.remove(row.section)) {
                              next.add(row.section);
                            }
                            expanded.value = next;
                          },
                        ),
                      );
                    },
                  ),
          ),
          if (!unavailable && total == 0 && !search.active)
            TextButton(
              onPressed: create,
              child: Text(context.t(LocaleKeys.workspaceNewCompendiumEntry)),
            ),
        ],
      ),
    );
  }
}
