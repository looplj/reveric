// 职责: 桌面端首页「继续写」区 — 左边是上次停下的作品（停在哪、最后一句），右边是另外几部最近编辑的作品。
// 关联文件:
//   lib/desktop/widgets/home/library_home_panel.dart
//   lib/shared/widgets/novel/resume_point.dart
//   lib/shared/widgets/novel/screenplay_kind_mark.dart
//   lib/desktop/widgets/home/novel_home_helpers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/content_kind.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/media_asset_image.dart';
import '../../../shared/widgets/novel/library_shelf_labels.dart';
import '../../../shared/widgets/novel/resume_point.dart';
import '../../../shared/widgets/novel/screenplay_kind_mark.dart';
import 'novel_home_helpers.dart';

/// 右侧「最近」最多列几部；再多就成了第二个作品列表。
const _recentLimit = 3;

class ResumeSection extends StatelessWidget {
  const ResumeSection({
    super.key,
    required this.works,
    required this.onOpenNovel,
    required this.onMore,
  });

  /// 书架可见的作品，按最近编辑排好；第一部是「继续写」的主角。
  final List<Novel> works;
  final ValueSetter<Novel> onOpenNovel;
  final ValueSetter<Novel> onMore;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final current = works.first;
    final others = works.skip(1).take(_recentLimit).toList();
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _ResumeMain(
                work: current,
                onOpen: () => onOpenNovel(current),
                onMore: () => onMore(current),
              ),
            ),
            if (others.isNotEmpty)
              _RecentList(works: others, onOpenNovel: onOpenNovel),
          ],
        ),
      ),
    );
  }
}

class _ResumeMain extends ConsumerWidget {
  const _ResumeMain({
    required this.work,
    required this.onOpen,
    required this.onMore,
  });

  final Novel work;
  final VoidCallback onOpen;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final resume = watchWorkResumePoint(context, ref, work);
    final where = resume.where;
    final excerpt = resume.excerpt;
    // 画布是制作而不是写作，措辞和入口图标跟着换。
    final isCanvas = work.contentKind == contentKindCanvas;

    Future<void> resumeWriting() async {
      final chapterId = resume.chapterId;
      if (chapterId != null) {
        await selectResumeChapter(ref, work.id, chapterId);
      }
      onOpen();
    }

    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ResumeCover(work: work),
          const SizedBox(width: RevericSpacing.x4l),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      context.t(
                        isCanvas
                            ? LocaleKeys.homeResumeEyebrowCanvas
                            : LocaleKeys.homeResumeEyebrow,
                      ),
                      style: typo.uiTinySemibold.copyWith(color: colors.accent),
                    ),
                    if (work.contentKind != contentKindNovel) ...[
                      const SizedBox(width: RevericSpacing.sm),
                      ScreenplayKindMark(contentKind: work.contentKind),
                    ],
                  ],
                ),
                const SizedBox(height: RevericSpacing.md),
                Text(
                  work.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.heading2.copyWith(
                    color: colors.textPrimary,
                    fontSize: 26,
                  ),
                ),
                if (where != null && where.isNotEmpty) ...[
                  const SizedBox(height: RevericSpacing.md),
                  Row(
                    children: [
                      RevericIcon(
                        RevericIcons.place_outlined,
                        size: 14,
                        color: colors.textMuted,
                      ),
                      const SizedBox(width: RevericSpacing.xs),
                      Flexible(
                        child: Text(
                          where,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.ui.copyWith(color: colors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ],
                if (excerpt != null) ...[
                  const SizedBox(height: RevericSpacing.x2l),
                  _Excerpt(text: excerpt),
                ],
                const Spacer(),
                const SizedBox(height: RevericSpacing.x2l),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        [
                          if (work.contentKind == contentKindNovel &&
                              work.wordCount > 0)
                            homeNovelWordCountLabel(context, work.wordCount),
                          context.t(
                            isCanvas
                                ? LocaleKeys.homeResumeLastEdited
                                : LocaleKeys.homeResumeLastWritten,
                            namedArgs: {
                              'time': formatHomeNovelUpdatedAt(
                                context,
                                work.updatedAt,
                              ),
                            },
                          ),
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    RevericIconButton(
                      icon: RevericIcons.more_horiz,
                      tooltip: context.t(LocaleKeys.homeFeaturedMore),
                      onPressed: onMore,
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    RevericButton.primary(
                      label: context.t(
                        isCanvas
                            ? LocaleKeys.homeResumeOpenCanvas
                            : LocaleKeys.homeFeaturedContinueWriting,
                      ),
                      icon: isCanvas
                          ? RevericIcons.flow_arrow
                          : RevericIcons.pencil_simple,
                      size: RevericButtonSize.prominent,
                      onPressed: resumeWriting,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Excerpt extends StatelessWidget {
  const _Excerpt({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x3l,
        vertical: RevericSpacing.md,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        border: Border(
          left: BorderSide(color: colors.blockquoteBorder, width: 3),
        ),
        borderRadius: const BorderRadius.horizontal(
          right: Radius.circular(RevericRadius.large),
        ),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: typo.bodySmall.copyWith(
          color: colors.textSecondary,
          height: 1.7,
        ),
      ),
    );
  }
}

/// 有封面用封面；没有就用主色底加书名 —— 这是第一屏的主角，不能是一块空灰。
class _ResumeCover extends ConsumerWidget {
  const _ResumeCover({required this.work});

  final Novel work;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final coverPath = watchWorkCoverFile(ref, work);
    final isCanvas = work.contentKind == contentKindCanvas;
    return ClipRRect(
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: SizedBox(
        width: isCanvas ? RevericSizes.canvasResumeCoverWidth : 140,
        child: AspectRatio(
          aspectRatio: isCanvas ? 16 / 10 : 3 / 4,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (coverPath != null)
                Image.file(
                  File(coverPath),
                  fit: BoxFit.cover,
                  cacheWidth: isCanvas ? 448 : 280,
                )
              else if (isCanvas)
                const HomeCanvasPlaceholder(iconSize: 40)
              else
                ColoredBox(
                  color: colors.accent,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(RevericSpacing.lg),
                      child: Text(
                        work.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: typo.heading2.copyWith(
                          color: colors.onAccent,
                          fontSize: 18,
                          height: 1.25,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: RevericSpacing.sm,
                left: RevericSpacing.sm,
                child: HomeNovelStatusBadge(novel: work),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentList extends StatelessWidget {
  const _RecentList({required this.works, required this.onOpenNovel});

  final List<Novel> works;
  final ValueSetter<Novel> onOpenNovel;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      width: 300,
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.lg,
        vertical: RevericSpacing.x2l,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(left: BorderSide(color: colors.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.sm,
              0,
              RevericSpacing.sm,
              RevericSpacing.sm,
            ),
            child: Text(
              context.t(LocaleKeys.homeResumeRecent),
              style: typo.uiTinySemibold.copyWith(color: colors.textMuted),
            ),
          ),
          for (final work in works)
            _RecentItem(work: work, onTap: () => onOpenNovel(work)),
        ],
      ),
    );
  }
}

class _RecentItem extends ConsumerWidget {
  const _RecentItem({required this.work, required this.onTap});

  final Novel work;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final coverPath = watchWorkCoverFile(ref, work);
    final updated = formatHomeNovelUpdatedAt(context, work.updatedAt);
    final where = watchWorkResumePoint(context, ref, work).where;
    return InkWell(
      onTap: onTap,
      hoverColor: colors.hover,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.sm),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(RevericRadius.small),
              child: SizedBox(
                width: 34,
                height: 46,
                child: coverPath == null
                    ? work.contentKind == contentKindCanvas
                          ? const HomeCanvasPlaceholder(iconSize: 14)
                          : ColoredBox(
                              color: colors.accent.withValues(alpha: 0.7),
                            )
                    : Image.file(
                        File(coverPath),
                        fit: BoxFit.cover,
                        cacheWidth: 68,
                      ),
              ),
            ),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          work.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.uiSemibold.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      if (work.contentKind != contentKindNovel) ...[
                        const SizedBox(width: RevericSpacing.xs),
                        ScreenplayKindMark(contentKind: work.contentKind),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (where != null && where.isNotEmpty) where,
                      updated,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
