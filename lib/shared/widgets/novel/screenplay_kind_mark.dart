// 职责: 在作品库中标出剧本或画布类型，小说保持无标记。
// 关联文件:
//   lib/shared/models/content_kind.dart
//   lib/desktop/widgets/novel_list.dart
//   lib/desktop/widgets/home/resume_section.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json

import 'package:flutter/material.dart';

import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../theme/theme.dart';
import '../../models/content_kind.dart';

class ScreenplayKindMark extends StatelessWidget {
  const ScreenplayKindMark({
    super.key,
    this.contentKind = contentKindScreenplay,
  });
  final String contentKind;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.small),
      ),
      // 单行富文本而不是 Row：宽度受限时整体省略，不会溢出。
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 2),
                child: RevericIcon(
                  contentKind == contentKindCanvas
                      ? RevericIcons.flow_arrow
                      : RevericIcons.movie_outlined,
                  size: 11,
                  color: colors.textMuted,
                ),
              ),
            ),
            TextSpan(
              text: context.t(
                contentKind == contentKindCanvas
                    ? LocaleKeys.libraryContentKindCanvas
                    : LocaleKeys.libraryContentKindScreenplay,
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: typo.uiTinySemibold.copyWith(color: colors.textMuted),
      ),
    );
  }
}
