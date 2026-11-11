// 职责: 桌面端书库作品网格、卡片与上下文操作菜单
// 关联文件:
//   lib/desktop/widgets/home/library_home_panel.dart
//   lib/desktop/widgets/home/novel_home_helpers.dart
//   lib/shared/components/dotted_border_box.dart
//   lib/desktop/widgets/novel_export_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
// 遵循的 Rules:
//   .agents/rules/hooks.md

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../shared/components/reveric_context_menu.dart';
import '../../shared/database/app_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/content_kind.dart';
import '../../shared/models/content_status.dart';
import '../../shared/theme/theme.dart';
import '../../shared/utils/utf16_safe_text.dart';
import '../../shared/widgets/novel/library_shelf_labels.dart';
import '../../shared/widgets/novel/screenplay_kind_mark.dart';
import 'novel_export_dialog.dart';
import '../../shared/components/dotted_border_box.dart';
import 'home/novel_home_helpers.dart';
import '../../shared/components/reveric_icon_button.dart';
import '../../shared/widgets/collections/work_menu.dart';
import '../../shared/widgets/media_asset_image.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const int _novelGridCoverCacheWidth = 480;

String _truncateTag(String tag, int maxChars) {
  return truncateUtf16Safe(tag, maxChars, ellipsis: '…');
}

class NovelLibrarySliver extends StatelessWidget {
  const NovelLibrarySliver({
    super.key,
    required this.novels,
    required this.contentKind,
    this.showCreateCard = true,
    required this.onCreateNovel,
    required this.onDeleteNovel,
    required this.onAdaptNovel,
    required this.onEditNovel,
    required this.onOpenNovel,
    required this.onReadNovel,
    required this.onUpdateStatus,
  });

  final List<Novel> novels;

  /// 当前库的作品类型 — 只用于新建卡片的文案，条目自己按 `novel.contentKind` 渲染。
  final String contentKind;
  final bool showCreateCard;
  final VoidCallback onCreateNovel;
  final ValueSetter<Novel> onDeleteNovel;
  final ValueSetter<Novel> onAdaptNovel;
  final ValueSetter<Novel> onEditNovel;
  final ValueSetter<Novel> onOpenNovel;
  final ValueSetter<Novel> onReadNovel;
  final void Function(Novel novel, String status) onUpdateStatus;

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x6l,
        RevericSpacing.sm,
        RevericSpacing.x6l,
        RevericSpacing.x4l,
      ),
      sliver: SliverGrid(
        // 画布库是横向画面，不沿用竖版书封的格子。
        gridDelegate: contentKind == contentKindCanvas
            ? const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: RevericSizes.canvasShelfCardWidth,
                mainAxisSpacing: RevericSpacing.x2l,
                crossAxisSpacing: RevericSpacing.x2l,
                mainAxisExtent: RevericSizes.canvasShelfCardHeight,
              )
            : const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: RevericSpacing.x2l,
                crossAxisSpacing: RevericSpacing.x2l,
                childAspectRatio: 0.51,
              ),
        delegate: SliverChildBuilderDelegate((context, index) {
          if (showCreateCard && index == novels.length) {
            return _CreateNovelCard(
              onTap: onCreateNovel,
              contentKind: contentKind,
            );
          }
          final novel = novels[index];
          return _NovelCard(
            novel: novel,
            onTap: () => onOpenNovel(novel),
            onRead: () => onReadNovel(novel),
            onDelete: () => onDeleteNovel(novel),
            onEdit: () => onEditNovel(novel),
            onAdapt: () => onAdaptNovel(novel),
            onUpdateStatus: (status) => onUpdateStatus(novel, status),
          );
        }, childCount: novels.length + (showCreateCard ? 1 : 0)),
      ),
    );
  }
}

class _CreateNovelCard extends StatelessWidget {
  const _CreateNovelCard({required this.onTap, required this.contentKind});
  final VoidCallback onTap;
  final String contentKind;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Material(
      color: colors.surfaceDim.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        hoverColor: colors.hover,
        child: DottedBorderBox(
          color: colors.borderSubtle,
          borderRadius: RevericRadius.large,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(RevericSpacing.x3l),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colors.accent.withValues(alpha: 0.12),
                    ),
                    child: Center(
                      child: RevericIcon(
                        RevericIcons.add,
                        size: 22,
                        color: colors.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: RevericSpacing.lg),
                  Text(
                    context.t(
                      contentKind == contentKindCanvas
                          ? LocaleKeys.homeCreateCanvasCardTitle
                          : contentKind == contentKindScreenplay
                          ? LocaleKeys.homeCreateScreenplayCardTitle
                          : LocaleKeys.homeCreateCardTitle,
                    ),
                    style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: RevericSpacing.xs),
                  Text(
                    context.t(
                      contentKind == contentKindCanvas
                          ? LocaleKeys.homeCreateCanvasCardSubtitle
                          : contentKind == contentKindScreenplay
                          ? LocaleKeys.homeCreateScreenplayCardSubtitle
                          : LocaleKeys.homeCreateCardSubtitle,
                    ),
                    textAlign: TextAlign.center,
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _showNovelActionsMenu({
  required BuildContext context,
  required Novel novel,
  required Offset position,
  required VoidCallback onRead,
  required VoidCallback onEdit,
  required VoidCallback onAdapt,
  required VoidCallback onDelete,
  required ValueSetter<String> onUpdateStatus,
}) {
  final colors = RevericTheme.colorsOf(context);

  final isCanvas = novel.contentKind == contentKindCanvas;
  final isFinished = novel.status == contentStatusFinished;
  final isAbandoned = novel.status == contentStatusAbandoned;
  final isArchived = novel.status == contentStatusArchived;
  final isActive = !isFinished && !isAbandoned && !isArchived;

  showRevericContextMenu(
    context: context,
    position: position,
    entries: [
      RevericMenuItem(
        icon: RevericIcons.edit_outlined,
        iconColor: colors.textSecondary,
        labelColor: colors.textSecondary,
        label: context.t(LocaleKeys.commonEdit),
        onTap: onEdit,
      ),
      if (novel.contentKind == contentKindNovel)
        RevericMenuItem(
          icon: RevericIcons.menu_book_outlined,
          iconColor: colors.textSecondary,
          labelColor: colors.textSecondary,
          label: context.t(LocaleKeys.libraryActionRead),
          onTap: onRead,
        ),
      // 改编只从书架上的小说出发 —— 草稿不在来源小说下拉里，选不回来。
      if (novel.contentKind == contentKindNovel && !novel.draft)
        RevericMenuItem(
          icon: RevericIcons.movie_outlined,
          iconColor: colors.textSecondary,
          labelColor: colors.textSecondary,
          label: context.t(LocaleKeys.libraryActionAdapt),
          onTap: onAdapt,
        ),
      RevericMenuItem(
        icon: RevericIcons.download,
        iconColor: colors.textSecondary,
        labelColor: colors.textSecondary,
        label: context.t(LocaleKeys.libraryExportNovel),
        onTap: () => showNovelExportDialog(context, novel),
      ),
      ...collectionWorkMenuItems(context, novel, position: position),
      const RevericMenuDivider(),
      if (isActive) ...[
        if (!isCanvas)
          RevericMenuItem(
            icon: RevericIcons.check_circle_outline,
            iconColor: colors.accent,
            labelColor: colors.textSecondary,
            label: context.t(LocaleKeys.libraryActionFinish),
            onTap: () => onUpdateStatus(contentStatusFinished),
          ),
        RevericMenuItem(
          icon: RevericIcons.archive_outlined,
          iconColor: colors.accentAmber,
          labelColor: colors.textSecondary,
          label: context.t(LocaleKeys.libraryActionArchive),
          onTap: () => onUpdateStatus(contentStatusArchived),
        ),
        RevericMenuItem(
          icon: RevericIcons.block_outlined,
          iconColor: colors.textMuted,
          labelColor: colors.textSecondary,
          label: context.t(LocaleKeys.libraryActionAbandon),
          onTap: () => onUpdateStatus(contentStatusAbandoned),
        ),
      ] else ...[
        RevericMenuItem(
          icon: RevericIcons.play_circle_outline,
          iconColor: colors.accent,
          labelColor: colors.textSecondary,
          label: context.t(LocaleKeys.libraryActionResume),
          onTap: () => onUpdateStatus(contentStatusInProgress),
        ),
      ],
      const RevericMenuDivider(),
      RevericMenuItem(
        icon: RevericIcons.delete_outline,
        iconColor: colors.deletionBorder,
        labelColor: colors.deletionBorder,
        label: context.t(LocaleKeys.commonDelete),
        onTap: onDelete,
      ),
    ],
  );
}

class _NovelCard extends HookConsumerWidget {
  const _NovelCard({
    required this.novel,
    required this.onTap,
    required this.onRead,
    required this.onDelete,
    required this.onEdit,
    required this.onAdapt,
    required this.onUpdateStatus,
  });

  final Novel novel;
  final VoidCallback onTap;
  final VoidCallback onRead;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback onAdapt;
  final ValueSetter<String> onUpdateStatus;

  Widget _buildTagsRow(
    BuildContext context,
    List<String> tags,
    RevericColors colors,
    RevericTypography typo,
  ) {
    Widget tagsContent;
    if (tags.isEmpty) {
      tagsContent = Text(
        ' ',
        style: typo.uiTiny.copyWith(color: colors.textSubtle),
      );
    } else {
      final displayTags = tags.take(2).map((t) => _truncateTag(t, 4)).toList();
      tagsContent = Row(
        children: [
          for (int i = 0; i < displayTags.length; i++) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.sm,
                vertical: RevericSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(RevericRadius.small),
              ),
              child: Text(
                displayTags[i],
                style: typo.uiTiny.copyWith(color: colors.accent),
              ),
            ),
            if (i < displayTags.length - 1)
              const SizedBox(width: RevericSpacing.xs),
          ],
        ],
      );
    }

    final tooltipMessage = tags.isEmpty ? null : tags.join(' · ');

    return Tooltip(
      message: tooltipMessage ?? '',
      waitDuration: const Duration(milliseconds: 300),
      child: Container(
        height: 22,
        alignment: Alignment.centerLeft,
        child: tagsContent,
      ),
    );
  }

  void _showMoreActionsMenu(BuildContext context, Offset position) {
    _showNovelActionsMenu(
      context: context,
      novel: novel,
      position: position,
      onRead: onRead,
      onEdit: onEdit,
      onAdapt: onAdapt,
      onDelete: onDelete,
      onUpdateStatus: onUpdateStatus,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final resolvedCoverPath = watchWorkCoverFile(ref, novel);
    final coverFile = resolvedCoverPath == null
        ? null
        : File(resolvedCoverPath);
    final coverImageProvider = coverFile != null
        ? ResizeImage(FileImage(coverFile), width: _novelGridCoverCacheWidth)
        : null;
    final hasCover = coverImageProvider != null;
    final tags = novel.tags;
    final isHovering = useState(false);
    // 剧本不显示字数：季 / 集 / 场才是它的计量单位，而那些数在作品自己的 content DB 里。
    final isScreenplay = novel.contentKind == contentKindScreenplay;
    final isCanvas = novel.contentKind == contentKindCanvas;

    return MouseRegion(
      onEnter: (_) => isHovering.value = true,
      onExit: (_) => isHovering.value = false,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(RevericRadius.large),
          hoverColor: colors.hover,
          child: Container(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(RevericRadius.large),
              border: Border.all(color: colors.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: colors.surfaceDim,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(RevericRadius.large),
                          ),
                          image: hasCover
                              ? DecorationImage(
                                  image: coverImageProvider,
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        clipBehavior: isCanvas ? Clip.antiAlias : Clip.none,
                        child: hasCover
                            ? null
                            : isCanvas
                            ? const HomeCanvasPlaceholder()
                            : Center(
                                child: RevericIcon(
                                  isScreenplay
                                      ? RevericIcons.movie_outlined
                                      : RevericIcons.menu_book_rounded,
                                  color: colors.textSubtle.withValues(
                                    alpha: 0.5,
                                  ),
                                  size: 40,
                                ),
                              ),
                      ),
                      Positioned(
                        top: RevericSpacing.sm,
                        left: RevericSpacing.sm,
                        child: HomeNovelStatusBadge(novel: novel),
                      ),
                      Positioned(
                        top: RevericSpacing.sm,
                        right: RevericSpacing.sm,
                        child: AnimatedOpacity(
                          opacity: isHovering.value ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 150),
                          child: Material(
                            color: colors.canvas.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(
                              RevericRadius.small,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 改编直接露在悬停操作里，不用先找右键菜单；
                                // 条件与菜单项一致，草稿选不回原著。
                                if (novel.contentKind == contentKindNovel &&
                                    !novel.draft)
                                  RevericIconButton(
                                    icon: RevericIcons.movie_outlined,
                                    tooltip: context.t(
                                      LocaleKeys.libraryActionAdapt,
                                    ),
                                    onPressed: onAdapt,
                                  ),
                                RevericIconButton(
                                  icon: RevericIcons.more_horiz,
                                  tooltip: context.t(
                                    LocaleKeys.commonMoreActions,
                                  ),
                                  onPressed: () {
                                    final renderBox =
                                        context.findRenderObject() as RenderBox;
                                    final position = renderBox.localToGlobal(
                                      Offset.zero,
                                    );
                                    _showMoreActionsMenu(
                                      context,
                                      Offset(
                                        position.dx + renderBox.size.width - 16,
                                        position.dy + 48,
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(RevericSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        novel.title,
                        style: typo.uiSemibold.copyWith(
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: RevericSpacing.xs),
                      // 小说和剧本混在一个网格里，剧本在类型前多一个标记。
                      Row(
                        children: [
                          if (novel.contentKind != contentKindNovel) ...[
                            ScreenplayKindMark(contentKind: novel.contentKind),
                            const SizedBox(width: RevericSpacing.xs),
                          ],
                          // 画布没有原创 / 改编之分，只留类型标记。
                          if (!isCanvas)
                            Flexible(
                              child: Text(
                                homeNovelTypeText(context, novel.type),
                                style: typo.uiTiny.copyWith(
                                  color: colors.textSubtle,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                      if ((novel.contentKind == contentKindNovel &&
                              novel.wordCount > 0) ||
                          novel.description.isNotEmpty) ...[
                        const SizedBox(height: RevericSpacing.xs),
                        Text(
                          novel.contentKind == contentKindNovel &&
                                  novel.wordCount > 0
                              ? homeNovelWordCountLabel(
                                  context,
                                  novel.wordCount,
                                )
                              : novel.description,
                          style: typo.uiSmall.copyWith(color: colors.textMuted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: RevericSpacing.xs),
                      Text(
                        formatHomeNovelUpdatedAt(context, novel.updatedAt),
                        style: typo.uiTiny.copyWith(color: colors.textSubtle),
                      ),
                      // 书封卡片留空行保持等高；画布卡片高度固定，没有标签就把空间让给画面。
                      if (!isCanvas || tags.isNotEmpty) ...[
                        const SizedBox(height: RevericSpacing.sm),
                        _buildTagsRow(context, tags, colors, typo),
                      ],
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
