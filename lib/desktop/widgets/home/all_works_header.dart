// 职责: 桌面端书库作品区的一行工具栏 — 左侧集合标签，右侧搜索、分类筛选、作品排序与草稿箱。
// 关联文件:
//   lib/desktop/widgets/home/library_home_panel.dart
//   lib/desktop/widgets/home/novel_home_helpers.dart
//   lib/shared/widgets/collections/shelf.dart
//   lib/shared/widgets/collections/location.dart
//   lib/shared/widgets/novel/library_shelf_labels.dart
//   lib/shared/components/reveric_context_menu.dart
//   lib/shared/components/reveric_search_field.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/search-debounce.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/components/reveric_search_field.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/novel.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/collections/location.dart';
import '../../../shared/widgets/collections/shelf.dart';
import '../../../shared/widgets/novel/library_shelf_labels.dart';

/// 工具区宽度低于此值时，搜索收成图标，点开或有内容时再展开。
const double _compactSearchBelow = 1080;

class AllWorksHeader extends StatelessWidget {
  const AllWorksHeader({
    super.key,
    required this.location,
    required this.searchController,
    required this.searchHint,
    required this.contentKind,
    required this.hasDrafts,
    required this.showDrafts,
    required this.onToggleDrafts,
    required this.categoryCounts,
    required this.selectedCategory,
    required this.onSelectCategory,
    required this.sortOrder,
    required this.onSortChanged,
  });

  final CollectionLocation location;

  /// 只搜当前作品类型、当前集合。
  final TextEditingController searchController;
  final String searchHint;

  /// 当前库的作品类型，决定可用的排序方式。
  final String contentKind;
  final bool hasDrafts;
  final bool showDrafts;
  final VoidCallback onToggleDrafts;

  /// 当前范围（集合或草稿箱）的分类计数（见 [NovelListX.categoryCounts]），不足两类时不显示分类筛选。
  final Map<String, int> categoryCounts;
  final String? selectedCategory;
  final ValueSetter<String?> onSelectCategory;
  final LibrarySortOrder sortOrder;
  final ValueSetter<LibrarySortOrder> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) => DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.borderSubtle)),
        ),
        child: Row(
          children: [
            Expanded(child: CollectionTabs(location: location)),
            const SizedBox(width: RevericSpacing.x3l),
            _WorksSearch(
              controller: searchController,
              hint: searchHint,
              compact: constraints.maxWidth < _compactSearchBelow,
            ),
            if (categoryCounts.length > 1 || selectedCategory != null) ...[
              const SizedBox(width: RevericSpacing.sm),
              _MenuPill(
                label: libraryCategoryText(context, selectedCategory),
                isActive: selectedCategory != null,
                entries: [
                  _choice(
                    context,
                    label: libraryCategoryText(context, null),
                    count: categoryCounts.values.fold<int>(0, (a, b) => a + b),
                    selected: selectedCategory == null,
                    onTap: () => onSelectCategory(null),
                  ),
                  const RevericMenuDivider(),
                  for (final MapEntry(key: category, value: count)
                      in categoryCounts.entries)
                    _choice(
                      context,
                      label: libraryCategoryText(context, category),
                      count: count,
                      selected: selectedCategory == category,
                      onTap: () => onSelectCategory(category),
                    ),
                ],
              ),
            ],
            const SizedBox(width: RevericSpacing.sm),
            _MenuPill(
              label: librarySortText(context, sortOrder),
              tooltip: context.t(LocaleKeys.homeSort),
              entries: [
                for (final order in librarySortOrdersFor(contentKind))
                  _choice(
                    context,
                    label: librarySortText(context, order),
                    selected: sortOrder == order,
                    onTap: () => onSortChanged(order),
                  ),
              ],
            ),
            // 始终挂树：条件拆除会连 Tooltip overlay 一起拆，和书架重建抢同一帧。
            Offstage(
              offstage: !hasDrafts,
              child: Padding(
                padding: const EdgeInsets.only(left: RevericSpacing.sm),
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(RevericRadius.medium),
                    border: Border.all(
                      color: showDrafts ? colors.accent : colors.borderSubtle,
                    ),
                  ),
                  child: _DraftsButton(
                    icon: RevericIcons.inbox_outlined,
                    isActive: showDrafts,
                    onTap: onToggleDrafts,
                    tooltip: context.t(LocaleKeys.homeFilterDraft),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 宽的时候常驻输入框；窄了收成图标，点开或有内容时展开，失焦且为空时收回。
class _WorksSearch extends HookWidget {
  const _WorksSearch({
    required this.controller,
    required this.hint,
    required this.compact,
  });

  final TextEditingController controller;
  final String hint;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final open = useState(false);
    final text = useValueListenable(controller).text;
    if (compact && !open.value && text.isEmpty) {
      return Tooltip(
        message: hint,
        child: Material(
          color: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RevericRadius.medium),
            side: BorderSide(color: colors.borderSubtle),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(RevericRadius.medium),
            onTap: () => open.value = true,
            child: SizedBox.square(
              dimension: 28,
              child: Center(
                child: RevericIcon(
                  RevericIcons.search,
                  size: 16,
                  color: colors.textSubtle,
                  semanticLabel: hint,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Focus(
      onFocusChange: (focused) {
        if (!focused) {
          open.value = false;
        }
      },
      child: SizedBox(
        width: 200,
        child: RevericSearchField(
          controller: controller,
          hint: hint,
          height: 28,
          radius: RevericRadius.medium,
          fillColor: colors.surface,
          autofocus: compact && open.value,
          highlightWhenFilled: true,
        ),
      ),
    );
  }
}

RevericMenuItem _choice(
  BuildContext context, {
  required String label,
  required bool selected,
  required VoidCallback onTap,
  int? count,
}) {
  final colors = RevericTheme.colorsOf(context);
  final typo = RevericTheme.typographyOf(context);
  return RevericMenuItem(
    label: label,
    labelColor: selected ? colors.accent : null,
    onTap: onTap,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (count != null)
          Text(
            '$count',
            style: typo.uiSmall.copyWith(color: colors.textSubtle),
          ),
        const SizedBox(width: RevericSpacing.sm),
        SizedBox(
          width: 14,
          child: selected
              ? RevericIcon(RevericIcons.check, size: 14, color: colors.accent)
              : null,
        ),
      ],
    ),
  );
}

/// 工具栏上的下拉胶囊，点开在胶囊下方弹出菜单。
class _MenuPill extends StatelessWidget {
  const _MenuPill({
    required this.label,
    required this.entries,
    this.isActive = false,
    this.tooltip,
  });

  final String label;
  final List<RevericMenuEntry> entries;
  final bool isActive;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final pill = Material(
      color: isActive ? colors.accent.withValues(alpha: 0.12) : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        side: BorderSide(color: colors.borderSubtle),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        onTap: () {
          final box = context.findRenderObject()! as RenderBox;
          showRevericContextMenu(
            context: context,
            position: box.localToGlobal(
              Offset(0, box.size.height + RevericSpacing.xs),
            ),
            entries: entries,
            minWidth: 160,
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.lg,
            vertical: RevericSpacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSmall.copyWith(
                    color: isActive ? colors.accent : colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: RevericSpacing.xs),
              RevericIcon(
                RevericIcons.expand_more,
                size: 14,
                color: isActive ? colors.accent : colors.textSubtle,
              ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip, child: pill);
  }
}

class _DraftsButton extends StatelessWidget {
  const _DraftsButton({
    required this.icon,
    required this.isActive,
    required this.onTap,
    required this.tooltip,
  });

  final String icon;
  final bool isActive;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Container(
          decoration: BoxDecoration(
            color: isActive
                ? colors.accent.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(RevericRadius.medium),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.sm,
            vertical: RevericSpacing.xs,
          ),
          child: RevericIcon(
            icon,
            size: 16,
            color: isActive ? colors.accent : colors.textSubtle,
          ),
        ),
      ),
    );
  }
}
