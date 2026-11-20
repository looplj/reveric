// 职责: 移动端作品页顶部 — 「继续写」卡片（停在哪、最后一句）与「最近」横滑封面。
// 关联文件:
//   lib/mobile/pages/library_page.dart
//   lib/shared/widgets/novel/resume_point.dart
//   lib/shared/widgets/novel/screenplay_kind_mark.dart
//   lib/mobile/widgets/novel_cover.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/content_kind.dart';
import '../../../shared/models/novel.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/novel/library_shelf_labels.dart';
import '../../../shared/widgets/novel/resume_point.dart';
import '../../../shared/widgets/novel/screenplay_kind_mark.dart';
import '../../widgets/novel_cover.dart';

/// 「继续写」：最近编辑的一部作品，不分类型。
class MobileResumeCard extends ConsumerWidget {
  const MobileResumeCard({
    super.key,
    required this.work,
    required this.onContinue,
  });

  final Novel work;

  /// 参数是小说的落点章节；剧本由工作台自己恢复季 / 集 / 场，传 null。
  final ValueSetter<String?> onContinue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    if (work.contentKind == contentKindCanvas) {
      return const SizedBox.shrink();
    }
    final resume = watchWorkResumePoint(context, ref, work);
    final where = resume.where;
    final excerpt = resume.excerpt;
    void open() => onContinue(resume.chapterId);

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(RevericRadius.x2l),
      child: InkWell(
        onTap: open,
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        child: Container(
          padding: const EdgeInsets.all(RevericSpacing.xl),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(RevericRadius.x2l),
            border: Border.all(color: colors.borderSubtle),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: 72,
                    height: 98,
                    child: MobileNovelCover(novel: work, fontSize: 13),
                  ),
                ),
                const SizedBox(width: RevericSpacing.xl),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          RevericIcon(
                            RevericIcons.schedule_outlined,
                            size: 13,
                            color: colors.accentWarm,
                          ),
                          const SizedBox(width: RevericSpacing.xs),
                          Flexible(
                            child: Text(
                              context.t(
                                LocaleKeys.homeResumeLastWritten,
                                namedArgs: {
                                  'time': formatHomeNovelUpdatedAt(
                                    context,
                                    work.updatedAt,
                                  ),
                                },
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: typo.uiTinySemibold.copyWith(
                                color: colors.accentWarm,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: RevericSpacing.xs),
                      Text(
                        work.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.heading2.copyWith(
                          color: colors.textPrimary,
                          fontSize: 18,
                        ),
                      ),
                      if (work.contentKind == contentKindScreenplay ||
                          (where != null && where.isNotEmpty)) ...[
                        const SizedBox(height: RevericSpacing.xs),
                        Row(
                          children: [
                            if (work.contentKind == contentKindScreenplay) ...[
                              const ScreenplayKindMark(),
                              const SizedBox(width: RevericSpacing.xs),
                            ],
                            if (where != null && where.isNotEmpty)
                              Flexible(
                                child: Text(
                                  where,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: typo.uiSmall.copyWith(
                                    color: colors.textMuted,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (excerpt != null) ...[
                        const SizedBox(height: RevericSpacing.xs),
                        Text(
                          excerpt,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: typo.bodyItalic.copyWith(
                            color: colors.textSecondary,
                            fontSize: 12.5,
                            height: 1.65,
                          ),
                        ),
                      ],
                      const Spacer(),
                      const SizedBox(height: RevericSpacing.md),
                      RevericButton.primary(
                        label: context.t(
                          LocaleKeys.homeFeaturedContinueWriting,
                        ),
                        icon: RevericIcons.pencil_simple,
                        size: RevericButtonSize.compact,
                        onPressed: open,
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

/// 「最近」：继续写之外的几部，横滑小封面。
class MobileRecentStrip extends StatelessWidget {
  const MobileRecentStrip({
    super.key,
    required this.works,
    required this.onOpen,
  });

  final List<Novel> works;
  final ValueSetter<Novel> onOpen;

  @override
  Widget build(BuildContext context) {
    final visible = works
        .where((work) => work.contentKind != contentKindCanvas)
        .toList();
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return SizedBox(
      height: 146,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x3l),
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(width: RevericSpacing.lg),
        itemBuilder: (context, index) {
          final work = visible[index];
          return InkWell(
            onTap: () => onOpen(work),
            borderRadius: BorderRadius.circular(RevericRadius.large),
            child: SizedBox(
              width: 76,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 76,
                    height: 102,
                    child: MobileNovelCover(novel: work, fontSize: 11),
                  ),
                  const SizedBox(height: RevericSpacing.xs),
                  Text(
                    work.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiSmallSemibold.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  Row(
                    children: [
                      if (work.contentKind == contentKindScreenplay) ...[
                        RevericIcon(
                          RevericIcons.movie_outlined,
                          size: 10,
                          color: colors.textSubtle,
                        ),
                        const SizedBox(width: 3),
                      ],
                      Expanded(
                        child: Text(
                          formatHomeNovelUpdatedAt(context, work.updatedAt),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.uiTiny.copyWith(color: colors.textSubtle),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
