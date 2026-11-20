// 职责: 移动端小说 / 剧本作品页 — 问候与新建入口固定在顶，本类型的继续写、最近和作品库同屏滚动。
// 关联文件:
//   lib/shared/widgets/confirm_dialog.dart
//   lib/mobile/features/library/filters.dart
//   lib/mobile/features/library/shelf_options_sheet.dart
//   lib/mobile/features/library/resume.dart
//   lib/mobile/features/screenplay/library_meta.dart
//   lib/mobile/widgets/novel_cover.dart
//   lib/mobile/pages/novel_create_page.dart
//   lib/mobile/pages/library_drafts_page.dart
//   lib/mobile/pages/novel_import_page.dart
//   lib/mobile/features/reading/reading_page.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/reading.json
//   assets/translations/zh-CN/reading.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import '../widgets/plugin_pages.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/components/reveric_button.dart';
import '../../shared/components/reveric_icon_button.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/widgets/quick_start_idea.dart';
import '../../shared/services/screenplay_import.dart';
import '../../shared/widgets/screenplay/import_dialog.dart';
import '../../shared/models/content_status.dart';
import '../../shared/models/content_kind.dart';
import '../features/library/filters.dart';
import '../features/library/resume.dart';
import '../features/library/shelf_options_sheet.dart';
import '../features/screenplay/library_meta.dart';
import '../../shared/models/novel.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/widgets/novel/screenplay_kind_mark.dart';
import '../../shared/services/novel_import.dart';
import '../../shared/theme/theme.dart';
import '../services/document_import_orchestrator.dart'
    show mobileTextDocumentImportTypeGroup;
import '../../shared/widgets/confirm_dialog.dart';
import '../widgets/novel_export_sheet.dart';
import '../features/reading/reading_page.dart';
import '../widgets/novel_cover.dart';
import 'novel_import_page.dart';
import 'novel_create_page.dart';
import 'chapter_editor_page.dart';
import 'workspace_editor_page.dart';
import 'library_drafts_page.dart';
import '../widgets/sheet.dart';
import '../../shared/widgets/collections/location.dart';
import '../../shared/widgets/collections/empty.dart';
import '../../shared/widgets/collections/work_menu.dart';
import '../../shared/components/reveric_search_field.dart';
import '../../shared/logger/app_logger.dart';

final _log = AppLogger.forModule('Library');

void _openCreate(BuildContext context, String contentKind) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MobileNovelCreatePage(contentKind: contentKind),
    ),
  );
}

void _openEditor(BuildContext context, Novel novel) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MobileWorkspaceEditorPage(novel: novel),
    ),
  );
}

void _openReader(BuildContext context, Novel novel) {
  if (!novel.hasContentDatabase) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.t(LocaleKeys.readingNoChaptersDescription)),
      ),
    );
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MobileReadingPage(
        novelId: novel.id,
        novelTitle: novel.title,
        databasePath: novel.contentDatabasePath!,
      ),
    ),
  );
}

class MobileLibraryPage extends HookConsumerWidget {
  const MobileLibraryPage({
    super.key,
    required this.contentKind,
    this.collectionId,
  });

  /// 本页呈现的作品类型（[contentKindNovel] / [contentKindScreenplay]），小说和剧本各占一个底部 Tab。
  final String contentKind;

  /// 旧的集合路由落到书架并选中该集合。
  final String? collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final novelsAsync = ref.watch(novelsProvider);

    final searchController = useTextEditingController();
    final searchValue = useValueListenable(searchController);
    final rawQuery = searchValue.text;
    final debounced = useDebounced(rawQuery, const Duration(milliseconds: 250));
    final effectiveQuery = rawQuery.trim().isEmpty
        ? ''
        : (debounced ?? '').trim().toLowerCase();
    final selectedCategory = useState<String?>(null);
    final sortOrder = useState(LibrarySortOrder.updated);
    final isScreenplay = contentKind == contentKindScreenplay;
    final isDeleting = useState(false);

    Future<void> deleteNovel(Novel novel) async {
      if (isDeleting.value) {
        return;
      }
      final shouldDelete = await _showDeleteConfirm(context, novel);
      if (!context.mounted || !shouldDelete) {
        return;
      }
      final actions = ref.read(novelActionsProvider);
      final messenger = ScaffoldMessenger.of(context);
      isDeleting.value = true;
      try {
        await actions.deleteNovel(novel);
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              context.t(
                LocaleKeys.libraryDeleteNovelSuccess,
                namedArgs: {'title': novel.title},
              ),
            ),
          ),
        );
      } catch (_) {
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.libraryDeleteNovelFailed)),
          ),
        );
      } finally {
        isDeleting.value = false;
      }
    }

    void openEditNovel(Novel novel) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileNovelCreatePage(existingNovel: novel),
        ),
      );
    }

    Future<void> openImportNovel() async {
      final file = await openFile(
        acceptedTypeGroups: [mobileTextDocumentImportTypeGroup],
      );
      if (!context.mounted || file == null) {
        return;
      }
      final filePath = file.path;

      final actions = ref.read(novelActionsProvider);
      final importService = NovelImportService(actions: actions);
      final messenger = ScaffoldMessenger.of(context);
      late final ParsedNovelImport parsed;
      try {
        parsed = await importService.parseTxtFile(filePath);
        if (parsed.chapters.isEmpty) {
          if (!context.mounted) {
            return;
          }
          // 提示里带了章节标题的格式要求，多留些时间读完。
          messenger.showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.libraryImportTxtEmpty)),
              duration: const Duration(seconds: 8),
            ),
          );
          return;
        }
      } catch (_) {
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.libraryImportTxtFailed))),
        );
        return;
      }

      if (!context.mounted) {
        return;
      }
      final importResult = await Navigator.of(context).push<NovelImportResult>(
        MaterialPageRoute(
          builder: (_) => MobileNovelImportPage(
            filePath: filePath,
            parsed: parsed,
            onSubmit:
                ({
                  required title,
                  required description,
                  required category,
                  required type,
                  required tags,
                }) {
                  return importService.importTxt(
                    filePath: filePath,
                    title: title,
                    description: description,
                    category: category,
                    type: type,
                    tags: tags,
                  );
                },
          ),
        ),
      );
      if (!context.mounted || importResult == null) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            context.t(
              LocaleKeys.libraryImportTxtSuccess,
              namedArgs: {
                'chapters': '${importResult.chapterCount}',
                'volumes': '${importResult.volumeCount}',
              },
            ),
          ),
        ),
      );

      final novel = await actions.getNovel(importResult.novelId);
      if (!context.mounted || novel == null) {
        return;
      }

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              MobileWorkspaceEditorPage(novel: novel, openChatOnEntry: true),
        ),
      );
    }

    Future<void> quickStart() async {
      final idea = await showQuickStartIdea(context, mobile: true);
      if (!context.mounted || idea == null) {
        return;
      }
      final kickoffPrompt = buildQuickStartKickoffPrompt(idea);
      final actions = ref.read(novelActionsProvider);
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      try {
        final id = await actions.createQuickStartNovel(
          untitledTitle: context.t(LocaleKeys.libraryUntitledNovel),
        );
        final created = await actions.getNovel(id);
        if (!context.mounted) {
          return;
        }
        if (created == null) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.libraryCreateNovelFailed)),
            ),
          );
          return;
        }
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => MobileWorkspaceEditorPage(
              novel: created,
              initialChatKickoffPrompt: kickoffPrompt,
            ),
          ),
        );
      } catch (_) {
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.libraryCreateNovelFailed)),
          ),
        );
      }
    }

    // 导入剧本：以文件名建剧本并把原文存为资料，进编辑器后由 AI 按提示词分段读取改编。
    Future<void> importScreenplay() async {
      final request = await showScreenplayImport(context, mobile: true);
      if (!context.mounted || request == null) {
        return;
      }
      final actions = ref.read(novelActionsProvider);
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      final kickoffTitle = context.t(LocaleKeys.libraryImportScreenplay);
      final untitled = context.t(LocaleKeys.libraryUntitledNovel);
      try {
        final title = request.source.title.isEmpty
            ? untitled
            : request.source.title;
        final id = await actions.createImportedScreenplay(
          title: title,
          sourceContent: request.source.content,
        );
        final created = await actions.getNovel(id);
        if (!context.mounted) {
          return;
        }
        if (created == null) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.libraryCreateNovelFailed)),
            ),
          );
          return;
        }
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => MobileWorkspaceEditorPage(
              novel: created,
              initialChatKickoffPrompt: buildScreenplayImportKickoffPrompt(
                prompt: request.prompt,
                materialTitle: title,
                lineCount: request.source.lineCount,
              ),
              initialChatKickoffTitle: kickoffTitle,
            ),
          ),
        );
      } catch (error, stackTrace) {
        _log.error(
          'importScreenplay failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.libraryCreateNovelFailed)),
          ),
        );
      }
    }

    Future<void> updateStatus(Novel novel, String status) async {
      final actions = ref.read(novelActionsProvider);
      final messenger = ScaffoldMessenger.of(context);
      try {
        await actions.updateNovelStatus(novelId: novel.id, status: status);
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonSaved))),
        );
      } catch (_) {
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.homeUpdateStatusFailed))),
        );
      }
    }

    void showActions(BuildContext actionContext, Novel novel) {
      _showNovelActionsSheet(
        context: actionContext,
        novel: novel,
        onRead: () => _openReader(context, novel),
        onEdit: () => openEditNovel(novel),
        onAdapt: () => openNovelAdaptation(context, novel),
        onUpdateStatus: (status) => updateStatus(novel, status),
        onDelete: () => deleteNovel(novel),
      );
    }

    // 继续写：小说直接进上次那一章；剧本进工作台，季 / 集 / 场由工作台自己恢复。
    void continueWriting(Novel work, String? chapterId) {
      final path = work.contentDatabasePath;
      if (chapterId == null || path == null) {
        _openEditor(context, work);
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileChapterEditorPage(
            novel: work,
            databasePath: path,
            initialChapterId: chapterId,
          ),
        ),
      );
    }

    // 快速开书只落在小说库；剧本库导入走 AI 改编。
    void showCreateSheet() => _showCreateSheet(
      context: context,
      createLabelKey: isScreenplay
          ? LocaleKeys.libraryCreateScreenplay
          : LocaleKeys.libraryCreateNovel,
      onCreate: () => _openCreate(context, contentKind),
      onQuickStart: isScreenplay ? null : quickStart,
      importLabelKey: isScreenplay
          ? LocaleKeys.libraryImportScreenplay
          : LocaleKeys.libraryImportTxt,
      onImport: isScreenplay ? importScreenplay : openImportNovel,
    );

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: novelsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Text(context.t(LocaleKeys.libraryDatabaseLoadFailed)),
          ),
          data: (everything) {
            final allNovels = everything
                .where(
                  (n) =>
                      n.contentKind != contentKindCanvas &&
                      n.contentKind == contentKind,
                )
                .toList();
            // 搜索时收起继续写和最近，结果直接顶到搜索框下面。
            final recent = allNovels.shelfVisible.sortedForShelf(
              LibrarySortOrder.updated,
            );
            final showTop = rawQuery.trim().isEmpty && recent.isNotEmpty;
            return Column(
              children: [
                _Header(
                  hasDrafts: allNovels.drafts.isNotEmpty,
                  onOpenDrafts: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            MobileLibraryDraftsPage(contentKind: contentKind),
                      ),
                    );
                  },
                  onCreate: showCreateSheet,
                ),
                Expanded(
                  child: LibraryCollectionRegion(
                    contentKind: contentKind,
                    mobile: true,
                    initialCollectionId: collectionId,
                    // 切集合清掉分类筛选，搜索和排序沿用。
                    onChange: () => selectedCategory.value = null,
                    builder: (context, location) {
                      // 首批作品就绪后再挂载滚动区，避免空列表把已保存的位置夹到 0。
                      if (!location.works.hasValue &&
                          !location.works.hasError) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final novels = location.works.value ?? <Novel>[];
                      final category = selectedCategory.value;
                      final filtered = novels
                          .whereCategory(category)
                          .where(
                            (n) =>
                                effectiveQuery.isEmpty ||
                                n.title.toLowerCase().contains(effectiveQuery),
                          )
                          .toList()
                          .sortedForShelf(sortOrder.value);

                      // 封面参考设计稿 3:4（竖版）。按实际格子宽度算出格子总高 =
                      // 封面高(宽×4/3) + 文字区，避免随屏宽变化导致封面比例漂移。
                      const horizontalPadding = RevericSpacing.x3l * 2;
                      const crossAxisSpacing = RevericSpacing.x2l;
                      const infoZone = 78.0; // 标题 + 字数 + 状态 chip + 间距 预留高度
                      const columnCount = 2;
                      final cellWidth =
                          (MediaQuery.sizeOf(context).width -
                              horizontalPadding -
                              crossAxisSpacing * (columnCount - 1)) /
                          columnCount;
                      final gridItemExtent = cellWidth * 4 / 3 + infoZone;

                      return CurrentCollectionScope(
                        collection: location.current,
                        child: CustomScrollView(
                          key: PageStorageKey('mobile-library-$contentKind'),
                          primary: false,
                          slivers: [
                            // 收起顶部时靠 key 对齐，搜索框不会被重建而丢焦点。
                            if (showTop)
                              SliverToBoxAdapter(
                                key: const ValueKey('library-top'),
                                child: _LibraryTop(
                                  recent: recent,
                                  onContinue: continueWriting,
                                ),
                              ),
                            const SliverToBoxAdapter(
                              child: MobilePluginPageShelf(),
                            ),
                            if (showTop)
                              SliverToBoxAdapter(
                                child: _SectionLabel(
                                  text: context.t(LocaleKeys.homeNavWorks),
                                ),
                              ),
                            SliverToBoxAdapter(
                              key: const ValueKey('library-filters'),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  RevericSpacing.x3l,
                                  RevericSpacing.xs,
                                  RevericSpacing.x3l,
                                  RevericSpacing.xs,
                                ),
                                child: RevericSearchField(
                                  controller: searchController,
                                  hint: context.t(
                                    LocaleKeys.librarySearchPlaceholder,
                                  ),
                                  // 触摸目标保持原高度，组件默认的 36 在手机上偏小。
                                  height: RevericSizes.buttonHeight,
                                  radius: RevericRadius.pill,
                                  fillColor: colors.surface,
                                  highlightWhenFilled: true,
                                ),
                              ),
                            ),
                            SliverPersistentHeader(
                              pinned: true,
                              delegate: MobileCollectionRowDelegate(
                                location: location,
                                filterActive:
                                    category != null ||
                                    sortOrder.value != LibrarySortOrder.updated,
                                onOpenFilter: () => showMobileShelfOptionsSheet(
                                  context,
                                  novels: novels,
                                  contentKind: contentKind,
                                  sortOrder: sortOrder.value,
                                  onSortChanged: (value) =>
                                      sortOrder.value = value,
                                  category: category,
                                  onCategoryChanged: (value) =>
                                      selectedCategory.value = value,
                                ),
                              ),
                            ),
                            if (location.works.hasError ||
                                location.current?.builtin != true &&
                                    novels.isEmpty)
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: CollectionEmpty(location: location),
                              )
                            else if (filtered.isEmpty && novels.isNotEmpty)
                              // 书架有作品只是被筛空了，别显示「还没有作品」误导用户。
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: _NoMatchState(
                                  onClear: () {
                                    searchController.clear();
                                    selectedCategory.value = null;
                                  },
                                ),
                              )
                            else if (filtered.isEmpty)
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: isScreenplay
                                    ? Center(
                                        child: Text(
                                          context.t(
                                            LocaleKeys.libraryNoScreenplays,
                                          ),
                                        ),
                                      )
                                    : _EmptyState(),
                              )
                            else
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(
                                  RevericSpacing.x3l,
                                  RevericSpacing.x2l,
                                  RevericSpacing.x3l,
                                  RevericSpacing.x4l,
                                ),
                                sliver: SliverGrid(
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: columnCount,
                                        mainAxisSpacing: RevericSpacing.x2l,
                                        crossAxisSpacing: crossAxisSpacing,
                                        mainAxisExtent: gridItemExtent,
                                      ),
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) => _NovelGridItem(
                                      novel: filtered[index],
                                      onLongPress: () =>
                                          showActions(context, filtered[index]),
                                    ),
                                    childCount: filtered.length,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 作品页顶部：继续写一部，再横滑列出另外几部最近的。
class _LibraryTop extends StatelessWidget {
  const _LibraryTop({required this.recent, required this.onContinue});

  /// 书架可见的作品，按最近编辑排好。
  final List<Novel> recent;
  final void Function(Novel work, String? chapterId) onContinue;

  @override
  Widget build(BuildContext context) {
    final others = recent.skip(1).take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x3l,
            RevericSpacing.xs,
            RevericSpacing.x3l,
            RevericSpacing.x3l,
          ),
          child: MobileResumeCard(
            work: recent.first,
            onContinue: (chapterId) => onContinue(recent.first, chapterId),
          ),
        ),
        // 作品太少时横滑只剩一两张，单独成栏显得空，直接收起。
        if (recent.length >= 3) ...[
          _SectionLabel(text: context.t(LocaleKeys.homeResumeRecent)),
          MobileRecentStrip(
            works: others,
            onOpen: (work) => _openEditor(context, work),
          ),
          const SizedBox(height: RevericSpacing.x3l),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x3l,
        0,
        RevericSpacing.x3l,
        RevericSpacing.md,
      ),
      child: Text(
        text,
        style: typo.uiSmallSemibold.copyWith(color: colors.textMuted),
      ),
    );
  }
}

void _showCreateSheet({
  required BuildContext context,
  required String createLabelKey,
  required VoidCallback onCreate,
  required VoidCallback? onQuickStart,
  required String importLabelKey,
  required VoidCallback onImport,
}) {
  final colors = RevericTheme.colorsOf(context);
  showMobileSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      Widget item(String icon, String labelKey, VoidCallback action) =>
          _SheetItem(
            icon: icon,
            iconColor: colors.textSecondary,
            label: sheetContext.t(labelKey),
            onTap: () {
              Navigator.of(sheetContext).pop();
              action();
            },
          );
      return Padding(
        padding: const EdgeInsets.only(bottom: RevericSpacing.x5l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            item(RevericIcons.add, createLabelKey, onCreate),
            if (onQuickStart != null)
              item(
                RevericIcons.auto_awesome,
                LocaleKeys.libraryQuickStart,
                onQuickStart,
              ),
            item(RevericIcons.upload, importLabelKey, onImport),
          ],
        ),
      );
    },
  );
}

String _greetingShortKey(int hour) {
  if (hour >= 5 && hour < 12) return LocaleKeys.homeGreetingMorningShort;
  if (hour >= 12 && hour < 18) return LocaleKeys.homeGreetingAfternoonShort;
  if (hour >= 18 && hour < 23) return LocaleKeys.homeGreetingEveningShort;
  return LocaleKeys.homeGreetingNightShort;
}

String _dateLabel(BuildContext context, DateTime now) {
  if (context.locale.languageCode.toLowerCase().startsWith('zh')) {
    return '${now.month}月${now.day}日';
  }
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[now.month - 1]} ${now.day}';
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.hasDrafts,
    required this.onOpenDrafts,
    required this.onCreate,
  });

  final bool hasDrafts;
  final VoidCallback onOpenDrafts;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final now = DateTime.now();
    final username = ref.watch(
      appSettingsProvider.select((s) => s.asData?.value.username ?? ''),
    );
    final greeting = context.t(_greetingShortKey(now.hour));

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x3l,
        RevericSpacing.md,
        RevericSpacing.x3l,
        RevericSpacing.lg,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _dateLabel(context, now),
                  style: typo.uiTinySemibold.copyWith(color: colors.textSubtle),
                ),
                const SizedBox(height: RevericSpacing.xxs),
                Text(
                  username.isEmpty
                      ? greeting
                      : context.t(
                          LocaleKeys.homeGreetingPersonalizedSimple,
                          namedArgs: {'greeting': greeting, 'name': username},
                        ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.heading2.copyWith(color: colors.textPrimary),
                ),
              ],
            ),
          ),
          if (hasDrafts)
            RevericIconButton(
              icon: RevericIcons.inbox_outlined,
              tooltip: context.t(LocaleKeys.libraryDrafts),
              onPressed: onOpenDrafts,
            ),
          const SizedBox(width: RevericSpacing.xs),
          // 新建、快速开书和导入都从这里进，弹出底部面板再选。
          IconButton.filled(
            tooltip: context.t(LocaleKeys.commonCreate),
            style: IconButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.onAccent,
            ),
            onPressed: onCreate,
            icon: RevericIcon(
              RevericIcons.add,
              size: 22,
              color: colors.onAccent,
            ),
          ),
        ],
      ),
    );
  }
}

class _NovelGridItem extends StatelessWidget {
  const _NovelGridItem({required this.novel, required this.onLongPress});

  final Novel novel;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return InkWell(
      onTap: () => _openEditor(context, novel),
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // width 撑满，避免无封面降级时 Stack 收缩成文字宽度的窄条。
          Expanded(
            child: SizedBox(
              width: double.infinity,
              child: MobileNovelCover(novel: novel, fontSize: 16),
            ),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            novel.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: RevericSpacing.xxs),
          // 小说记字数，剧本记季 / 集 / 场；混排时剧本前多一个标记。
          if (novel.contentKind == contentKindScreenplay)
            Row(
              children: [
                const Flexible(child: ScreenplayKindMark()),
                const SizedBox(width: RevericSpacing.xs),
                Expanded(child: MobileScreenplayMetaLabel(novel: novel)),
              ],
            )
          else
            Text(
              formatHomeWordCountLabel(context, novel.wordCount),
              style: typo.uiTiny.copyWith(color: colors.textMuted),
            ),
          const SizedBox(height: RevericSpacing.xxs),
          _StatusChip(status: novel.status),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final (color, key) = switch (status) {
      contentStatusFinished => (
        colors.success,
        LocaleKeys.libraryStatusFinished,
      ),
      contentStatusAbandoned => (
        colors.textMuted,
        LocaleKeys.libraryStatusAbandoned,
      ),
      contentStatusArchived => (
        colors.accentAmber,
        LocaleKeys.libraryStatusArchived,
      ),
      _ => (colors.accentWarm, LocaleKeys.libraryStatusInProgress),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(RevericRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: RevericSpacing.xxs),
          Flexible(
            child: Text(
              context.t(key),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiTinySemibold.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
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
              RevericIcons.menu_book_rounded,
              size: 40,
              color: colors.textSubtle,
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              context.t(LocaleKeys.libraryNoNovels),
              style: typo.uiSemibold.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: RevericSpacing.xs),
            Text(
              context.t(LocaleKeys.libraryNoNovelsHint),
              textAlign: TextAlign.center,
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoMatchState extends StatelessWidget {
  const _NoMatchState({required this.onClear});

  final VoidCallback onClear;

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
              RevericIcons.search,
              size: 40,
              color: colors.textSubtle,
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              context.t(LocaleKeys.libraryNoMatchingWorks),
              style: typo.uiSemibold.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: RevericSpacing.md),
            RevericButton.secondary(
              label: context.t(LocaleKeys.libraryClearFilters),
              onPressed: onClear,
            ),
          ],
        ),
      ),
    );
  }
}

/// 长按作品弹出底部操作面板，对齐桌面端 context menu 的操作集。
void _showNovelActionsSheet({
  required BuildContext context,
  required Novel novel,
  required VoidCallback onRead,
  required VoidCallback onEdit,
  required VoidCallback onAdapt,
  required ValueSetter<String> onUpdateStatus,
  required VoidCallback onDelete,
}) {
  final colors = RevericTheme.colorsOf(context);
  final typo = RevericTheme.typographyOf(context);

  final isCanvas = novel.contentKind == contentKindCanvas;
  final isFinished = novel.status == contentStatusFinished;
  final isAbandoned = novel.status == contentStatusAbandoned;
  final isArchived = novel.status == contentStatusArchived;
  final isActive = !isFinished && !isAbandoned && !isArchived;

  showMobileSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x3l),
            child: Text(
              novel.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: RevericSpacing.x5l),
              children: [
                _SheetItem(
                  icon: RevericIcons.edit_outlined,
                  iconColor: colors.textSecondary,
                  label: sheetContext.t(LocaleKeys.commonEdit),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    onEdit();
                  },
                ),
                if (novel.contentKind == contentKindNovel)
                  _SheetItem(
                    icon: RevericIcons.menu_book_outlined,
                    iconColor: colors.textSecondary,
                    label: sheetContext.t(LocaleKeys.libraryActionRead),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onRead();
                    },
                  ),
                // 改编只从书架上的小说出发 —— 草稿不在来源小说下拉里，选不回来。
                if (novel.contentKind == contentKindNovel && !novel.draft)
                  _SheetItem(
                    icon: RevericIcons.movie_outlined,
                    iconColor: colors.textSecondary,
                    label: sheetContext.t(LocaleKeys.libraryActionAdapt),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onAdapt();
                    },
                  ),
                _SheetItem(
                  icon: RevericIcons.download,
                  iconColor: colors.textSecondary,
                  label: sheetContext.t(LocaleKeys.libraryExportNovel),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    showNovelExportSheet(context, novel);
                  },
                ),
                ...collectionWorkMenuItems(context, novel, mobile: true).map(
                  (item) => _SheetItem(
                    icon: item.icon!,
                    iconColor: colors.textSecondary,
                    label: item.label,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      item.onTap!();
                    },
                  ),
                ),
                Divider(height: 1, color: colors.borderSubtle),
                if (isActive) ...[
                  if (!isCanvas)
                    _SheetItem(
                      icon: RevericIcons.check_circle_outline,
                      iconColor: colors.accent,
                      label: sheetContext.t(LocaleKeys.libraryActionFinish),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        onUpdateStatus(contentStatusFinished);
                      },
                    ),
                  _SheetItem(
                    icon: RevericIcons.archive_outlined,
                    iconColor: colors.accentAmber,
                    label: sheetContext.t(LocaleKeys.libraryActionArchive),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onUpdateStatus(contentStatusArchived);
                    },
                  ),
                  _SheetItem(
                    icon: RevericIcons.block_outlined,
                    iconColor: colors.textMuted,
                    label: sheetContext.t(LocaleKeys.libraryActionAbandon),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onUpdateStatus(contentStatusAbandoned);
                    },
                  ),
                ] else
                  _SheetItem(
                    icon: RevericIcons.play_circle_outline,
                    iconColor: colors.accent,
                    label: sheetContext.t(LocaleKeys.libraryActionResume),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onUpdateStatus(contentStatusInProgress);
                    },
                  ),
                Divider(height: 1, color: colors.borderSubtle),
                _SheetItem(
                  icon: RevericIcons.delete_outline,
                  iconColor: colors.deletionBorder,
                  label: sheetContext.t(LocaleKeys.commonDelete),
                  isDestructive: true,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    onDelete();
                  },
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class _SheetItem extends StatelessWidget {
  const _SheetItem({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  final String icon;
  final Color iconColor;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return ListTile(
      leading: RevericIcon(icon, size: 20, color: iconColor),
      title: Text(
        label,
        style: typo.ui.copyWith(
          color: isDestructive ? colors.deletionBorder : colors.textPrimary,
        ),
      ),
      onTap: onTap,
    );
  }
}

Future<bool> _showDeleteConfirm(BuildContext context, Novel novel) {
  return showConfirmDialog(
    context,
    title: context.t(LocaleKeys.commonDelete),
    message: context.t(
      LocaleKeys.libraryDeleteNovelConfirm,
      namedArgs: {'title': novel.title},
    ),
    confirmLabel: context.t(LocaleKeys.commonDelete),
    variant: ConfirmDialogVariant.error,
  );
}
