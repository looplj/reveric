// 职责: 桌面端书库主面板编排问候、继续写与作品区；小说库和剧本库各用一个实例，切换集合只替换作品网格。
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/desktop/widgets/home/greeting_header.dart
//   lib/desktop/widgets/home/resume_section.dart
//   lib/desktop/widgets/home/all_works_header.dart
//   lib/desktop/widgets/novel_list.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
// 遵循的 Rules:
//   .agents/rules/hooks.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/models/content_kind.dart';
import '../../../shared/models/novel.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../../shared/theme/theme.dart';
import '../novel_list.dart';
import 'all_works_header.dart';
import 'greeting_header.dart';
import 'resume_section.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_placeholder.dart';
import '../../../shared/widgets/collections/location.dart';
import '../../../shared/widgets/collections/empty.dart';
import '../../../shared/widgets/collections/work_menu.dart';

class HomeLibraryPanel extends HookConsumerWidget {
  const HomeLibraryPanel({
    super.key,
    required this.contentKind,
    required this.novelsAsync,
    required this.headerGestureExclusionKey,
    required this.onQuickStart,
    required this.onCreateNovel,
    required this.onImportNovel,
    required this.onImportScreenplay,
    required this.onCreateDemoNovel,
    required this.onDeleteNovel,
    required this.onAdaptNovel,
    required this.onEditNovel,
    required this.onOpenNovel,
    required this.onReadNovel,
    required this.onUpdateStatus,
  });

  /// 本库呈现的作品类型（[contentKindNovel] / [contentKindScreenplay]），继续写、草稿和作品区都只看这一类。
  final String contentKind;
  final AsyncValue<List<Novel>> novelsAsync;
  final GlobalKey headerGestureExclusionKey;
  final VoidCallback onQuickStart;

  /// 新建本库类型的作品。
  final VoidCallback onCreateNovel;
  final VoidCallback onImportNovel;
  final VoidCallback onImportScreenplay;
  final VoidCallback onCreateDemoNovel;
  final ValueSetter<Novel> onDeleteNovel;
  final ValueSetter<Novel> onAdaptNovel;
  final ValueSetter<Novel> onEditNovel;
  final ValueSetter<Novel> onOpenNovel;
  final ValueSetter<Novel> onReadNovel;
  final void Function(Novel novel, String status) onUpdateStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final showDrafts = useState(false);
    final selectedCategory = useState<String?>(null);
    final sortOrder = useState(LibrarySortOrder.updated);
    final searchController = useTextEditingController();
    final rawQuery = useValueListenable(searchController).text;
    final debouncedQuery = useDebounced(
      rawQuery,
      const Duration(milliseconds: 250),
    );
    final isScreenplay = contentKind == contentKindScreenplay;
    final isCanvas = contentKind == contentKindCanvas;
    final settingsAsync = ref.watch(appSettingsProvider);
    final username = settingsAsync.maybeWhen(
      data: (s) => s.username.isNotEmpty ? s.username : null,
      orElse: () => null,
    );

    return novelsAsync.when(
      data: (everything) => LibraryCollectionRegion(
        contentKind: contentKind,
        // 切集合清掉临时分类筛选，搜索保留、继续在新集合里搜。
        onChange: () {
          selectedCategory.value = null;
          showDrafts.value = false;
        },
        builder: (context, location) {
          final allNovels = everything
              .where((n) => n.contentKind == contentKind)
              .toList();
          final recent = allNovels.shelfVisible.sortedForShelf(
            LibrarySortOrder.updated,
          );
          final novels = allNovels.shelfVisible;
          final drafts = allNovels.drafts;
          // 草稿箱只挂在全部下；最后一份草稿加入书架后入口会隐藏，此时自动回到书架。
          final isDraftFilter =
              location.current?.builtin == true &&
              showDrafts.value &&
              drafts.isNotEmpty;
          final scope = (isDraftFilter
              ? drafts
              : location.works.value ?? <Novel>[]);
          final categoryCounts = scope.categoryCounts;
          final category = selectedCategory.value;
          final categoryNovels = scope.whereCategory(category);
          final query = rawQuery.trim().isEmpty
              ? ''
              : (debouncedQuery ?? '').trim().toLowerCase();
          final filtered = query.isEmpty
              ? categoryNovels
              : categoryNovels.where((n) {
                  return n.title.toLowerCase().contains(query) ||
                      n.description.toLowerCase().contains(query) ||
                      n.tags.any((tag) => tag.toLowerCase().contains(query));
                }).toList();

          final visible = filtered.sortedForShelf(sortOrder.value);

          return CurrentCollectionScope(
            collection: location.current,
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    RevericSpacing.x6l,
                    RevericSpacing.x4l,
                    RevericSpacing.x6l,
                    RevericSpacing.x4l,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: GreetingHeader(
                      // 快速开书只落在小说库；剧本库导入走 AI 改编。
                      onQuickStart: contentKind == contentKindNovel
                          ? onQuickStart
                          : null,
                      onCreateNovel: onCreateNovel,
                      createLabel: context.t(
                        isCanvas
                            ? LocaleKeys.libraryCreateCanvas
                            : isScreenplay
                            ? LocaleKeys.libraryCreateScreenplay
                            : LocaleKeys.libraryCreateNovel,
                      ),
                      onImport: isCanvas
                          ? null
                          : isScreenplay
                          ? onImportScreenplay
                          : onImportNovel,
                      importLabel: context.t(
                        isScreenplay
                            ? LocaleKeys.libraryImportScreenplay
                            : LocaleKeys.libraryImportTxt,
                      ),
                      username: username,
                      featuredTitle: recent.firstOrNull?.title,
                      headerGestureExclusionKey: headerGestureExclusionKey,
                    ),
                  ),
                ),
                if (recent.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.x6l,
                      0,
                      RevericSpacing.x6l,
                      RevericSpacing.x6l,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: ResumeSection(
                        works: recent,
                        onOpenNovel: onOpenNovel,
                        onMore: onEditNovel,
                      ),
                    ),
                  ),
                // 整个库都空时连工具栏一起省掉，只留空状态。
                if (novels.isNotEmpty || drafts.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.x6l,
                      0,
                      RevericSpacing.x6l,
                      RevericSpacing.x2l,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: AllWorksHeader(
                        location: location,
                        searchController: searchController,
                        searchHint: context.t(
                          LocaleKeys.librarySearchPlaceholder,
                        ),
                        contentKind: contentKind,
                        hasDrafts:
                            location.current?.builtin == true &&
                            drafts.isNotEmpty,
                        showDrafts: isDraftFilter,
                        onToggleDrafts: () => showDrafts.value = !isDraftFilter,
                        categoryCounts: categoryCounts,
                        selectedCategory: category,
                        onSelectCategory: (value) =>
                            selectedCategory.value = value,
                        sortOrder: sortOrder.value,
                        onSortChanged: (value) => sortOrder.value = value,
                      ),
                    ),
                  ),
                if (!isDraftFilter &&
                    !location.works.hasValue &&
                    !location.works.hasError)
                  const SliverFillRemaining(
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (!isDraftFilter &&
                    (location.works.hasError ||
                        location.current?.builtin != true && scope.isEmpty))
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: CollectionEmpty(location: location),
                  )
                else if (!isDraftFilter && novels.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: isCanvas
                        ? RevericPlaceholder.empty(
                            icon: RevericIcons.flow_arrow,
                            title: context.t(LocaleKeys.libraryCreateCanvas),
                            description: context.t(
                              LocaleKeys.homeCreateCanvasCardSubtitle,
                            ),
                            action: RevericButton.primary(
                              label: context.t(LocaleKeys.libraryCreateCanvas),
                              onPressed: onCreateNovel,
                            ),
                          )
                        : isScreenplay
                        ? EmptyScreenplayState(
                            onCreate: onCreateNovel,
                            onImport: onImportScreenplay,
                          )
                        : EmptyLibraryState(
                            onCreate: onCreateNovel,
                            onImport: onImportNovel,
                            onCreateDemo: onCreateDemoNovel,
                          ),
                  )
                else if (!isDraftFilter && visible.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: RevericPlaceholder.empty(
                        icon: RevericIcons.search,
                        title: context.t(LocaleKeys.libraryNoMatchingWorks),
                        action: RevericButton.secondary(
                          label: context.t(LocaleKeys.libraryClearFilters),
                          onPressed: () {
                            searchController.clear();
                            selectedCategory.value = null;
                          },
                        ),
                      ),
                    ),
                  )
                else if (isDraftFilter && visible.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyDraftsState(),
                  )
                else
                  NovelLibrarySliver(
                    novels: visible,
                    contentKind: contentKind,
                    showCreateCard:
                        !isDraftFilter && location.current?.builtin == true,
                    onCreateNovel: onCreateNovel,
                    onDeleteNovel: onDeleteNovel,
                    onAdaptNovel: onAdaptNovel,
                    onEditNovel: onEditNovel,
                    onOpenNovel: onOpenNovel,
                    onReadNovel: onReadNovel,
                    onUpdateStatus: onUpdateStatus,
                  ),
              ],
            ),
          );
        },
      ),
      loading: () =>
          Center(child: CircularProgressIndicator(color: colors.accent)),
      error: (error, _) => LibraryErrorState(
        message: context.t(LocaleKeys.libraryDatabaseLoadFailed),
      ),
    );
  }
}

class EmptyDraftsState extends StatelessWidget {
  const EmptyDraftsState({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x6l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.inbox_outlined,
              size: 32,
              color: colors.textSubtle,
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              context.t(LocaleKeys.libraryNoDrafts),
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.sm),
            Text(
              context.t(LocaleKeys.libraryNoDraftsHint),
              style: typo.ui.copyWith(color: colors.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class EmptyLibraryState extends StatelessWidget {
  const EmptyLibraryState({
    super.key,
    required this.onCreate,
    required this.onImport,
    required this.onCreateDemo,
  });

  final VoidCallback onCreate;
  final VoidCallback onImport;
  final VoidCallback onCreateDemo;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x6l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.menu_book_outlined,
              size: 32,
              color: colors.textSubtle,
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              context.t(LocaleKeys.libraryNoNovels),
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.sm),
            Text(
              context.t(LocaleKeys.libraryNoNovelsHint),
              style: typo.ui.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: RevericSpacing.x2l),
            FilledButton(
              onPressed: onCreate,
              child: Text(context.t(LocaleKeys.libraryCreateNovel)),
            ),
            const SizedBox(height: RevericSpacing.sm),
            OutlinedButton.icon(
              onPressed: onImport,
              icon: const RevericIcon(RevericIcons.upload, size: 16),
              label: Text(context.t(LocaleKeys.libraryImportTxt)),
            ),
            const SizedBox(height: RevericSpacing.lg),
            OutlinedButton.icon(
              onPressed: onCreateDemo,
              icon: const RevericIcon(RevericIcons.auto_awesome, size: 16),
              label: Text(context.t(LocaleKeys.libraryCreateDemoNovel)),
            ),
            const SizedBox(height: RevericSpacing.sm),
            Text(
              context.t(LocaleKeys.libraryCreateDemoNovelDesc),
              style: typo.uiSmall.copyWith(color: colors.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class EmptyScreenplayState extends StatelessWidget {
  const EmptyScreenplayState({
    super.key,
    required this.onCreate,
    required this.onImport,
  });

  final VoidCallback onCreate;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x6l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.movie_outlined,
              size: 32,
              color: colors.textSubtle,
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              context.t(LocaleKeys.libraryNoScreenplays),
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.x2l),
            FilledButton(
              onPressed: onCreate,
              child: Text(context.t(LocaleKeys.libraryCreateScreenplay)),
            ),
            const SizedBox(height: RevericSpacing.lg),
            OutlinedButton.icon(
              onPressed: onImport,
              icon: const RevericIcon(RevericIcons.upload, size: 16),
              label: Text(context.t(LocaleKeys.libraryImportScreenplay)),
            ),
          ],
        ),
      ),
    );
  }
}

class LibraryErrorState extends StatelessWidget {
  const LibraryErrorState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x6l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.error_outline,
              color: colors.warningText,
              size: 28,
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              message,
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
