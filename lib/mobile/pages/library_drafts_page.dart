// 职责: 移动端草稿箱 — 列出本类型尚未加入书架的作品，支持打开、入库与删除。
// 关联文件:
//   lib/mobile/pages/library_page.dart
//   lib/mobile/pages/workspace_editor_page.dart
//   lib/mobile/widgets/novel_cover.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/novel.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/services/novel_actions.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../widgets/novel_cover.dart';
import 'workspace_editor_page.dart';

class MobileLibraryDraftsPage extends ConsumerWidget {
  const MobileLibraryDraftsPage({super.key, required this.contentKind});

  /// 只列这一类作品的草稿，跟随打开它的小说 / 剧本 Tab。
  final String contentKind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final novelsAsync = ref.watch(novelsProvider);

    Future<void> deleteNovel(Novel novel) async {
      final shouldDelete = await showConfirmDialog(
        context,
        title: context.t(LocaleKeys.commonDelete),
        message: context.t(
          LocaleKeys.libraryDeleteNovelConfirm,
          namedArgs: {'title': novel.title},
        ),
        confirmLabel: context.t(LocaleKeys.commonDelete),
        variant: ConfirmDialogVariant.error,
      );
      if (!context.mounted || !shouldDelete) {
        return;
      }
      final actions = ref.read(novelActionsProvider);
      final messenger = ScaffoldMessenger.of(context);
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
      }
    }

    Future<void> addToLibrary(Novel novel) async {
      final actions = ref.read(novelActionsProvider);
      final messenger = ScaffoldMessenger.of(context);
      try {
        await actions.clearNovelDraft(novel.id);
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.libraryAddedToLibrary))),
        );
      } on NovelTitleConflictException catch (error) {
        if (!context.mounted) {
          return;
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              context.t(
                LocaleKeys.libraryDuplicateName,
                namedArgs: {'name': error.title},
              ),
            ),
          ),
        );
      }
    }

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: novelsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Text(context.t(LocaleKeys.libraryDatabaseLoadFailed)),
          ),
          data: (allNovels) {
            final drafts =
                allNovels
                    .where((n) => n.contentKind == contentKind)
                    .toList()
                    .drafts
                  ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
            const horizontalPadding = RevericSpacing.x3l * 2;
            const crossAxisSpacing = RevericSpacing.x2l;
            const infoZone = 78.0;
            final cellWidth =
                (MediaQuery.sizeOf(context).width -
                    horizontalPadding -
                    crossAxisSpacing) /
                2;
            final gridItemExtent = cellWidth * 4 / 3 + infoZone;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    RevericSpacing.xs,
                    RevericSpacing.sm,
                    RevericSpacing.x3l,
                    RevericSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: RevericIcon(
                          RevericIcons.arrow_back,
                          size: 22,
                          color: colors.textSecondary,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          context.t(LocaleKeys.libraryDrafts),
                          style: typo.heading2.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: drafts.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(RevericSpacing.x6l),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                RevericIcon(
                                  RevericIcons.inbox_outlined,
                                  size: 40,
                                  color: colors.textSubtle,
                                ),
                                const SizedBox(height: RevericSpacing.lg),
                                Text(
                                  context.t(LocaleKeys.libraryNoDrafts),
                                  style: typo.uiSemibold.copyWith(
                                    color: colors.textSecondary,
                                  ),
                                ),
                                const SizedBox(height: RevericSpacing.xs),
                                Text(
                                  context.t(LocaleKeys.libraryNoDraftsHint),
                                  textAlign: TextAlign.center,
                                  style: typo.uiSmall.copyWith(
                                    color: colors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.fromLTRB(
                            RevericSpacing.x3l,
                            RevericSpacing.x2l,
                            RevericSpacing.x3l,
                            RevericSpacing.x4l,
                          ),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: RevericSpacing.x2l,
                                crossAxisSpacing: crossAxisSpacing,
                                mainAxisExtent: gridItemExtent,
                              ),
                          itemCount: drafts.length,
                          itemBuilder: (context, index) {
                            final novel = drafts[index];
                            return _DraftGridItem(
                              novel: novel,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        MobileWorkspaceEditorPage(novel: novel),
                                  ),
                                );
                              },
                              onAddToLibrary: () => addToLibrary(novel),
                              onDelete: () => deleteNovel(novel),
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

class _DraftGridItem extends StatelessWidget {
  const _DraftGridItem({
    required this.novel,
    required this.onTap,
    required this.onAddToLibrary,
    required this.onDelete,
  });

  final Novel novel;
  final VoidCallback onTap;
  final VoidCallback onAddToLibrary;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return GestureDetector(
      onTap: onTap,
      onLongPress: () => _showDraftActionsSheet(
        context: context,
        novel: novel,
        onAddToLibrary: onAddToLibrary,
        onDelete: onDelete,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          Text(
            formatHomeWordCountLabel(context, novel.wordCount),
            style: typo.uiTiny.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: RevericSpacing.xxs),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.sm,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: colors.textMuted.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(RevericRadius.pill),
            ),
            child: Text(
              context.t(LocaleKeys.homeFilterDraft),
              style: typo.uiTinySemibold.copyWith(color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

void _showDraftActionsSheet({
  required BuildContext context,
  required Novel novel,
  required VoidCallback onAddToLibrary,
  required VoidCallback onDelete,
}) {
  final colors = RevericTheme.colorsOf(context);
  final typo = RevericTheme.typographyOf(context);

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: colors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: RevericSpacing.x5l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.x3l,
                ),
                child: Text(
                  novel.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
              ),
              const SizedBox(height: RevericSpacing.sm),
              ListTile(
                leading: RevericIcon(
                  RevericIcons.menu_book_outlined,
                  color: colors.accent,
                ),
                title: Text(sheetContext.t(LocaleKeys.libraryAddToLibrary)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onAddToLibrary();
                },
              ),
              ListTile(
                leading: RevericIcon(
                  RevericIcons.delete_outline,
                  color: colors.deletionBorder,
                ),
                title: Text(
                  sheetContext.t(LocaleKeys.commonDelete),
                  style: typo.ui.copyWith(color: colors.deletionBorder),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onDelete();
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}
