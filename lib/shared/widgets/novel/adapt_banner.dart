// 职责: 新建剧本表单顶部的「从小说改编」横幅 — 内嵌原著选择，选中后按原著预填表单，两端共用。
// 关联文件:
//   lib/shared/models/novel_form_prefill.dart
//   lib/shared/widgets/novel/start_banner.dart
//   lib/desktop/widgets/novel_form_dialog.dart
//   lib/mobile/pages/novel_create_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/form.md

import 'package:flutter/material.dart';

import '../../../third/form/flutter_hook_form.dart';
import '../../database/app_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/novel_form_fields.dart';
import '../../models/novel_form_prefill.dart';
import '../../models/novel_type.dart';
import '../../theme/theme.dart';

/// 宽度够时选择器放在说明右侧，与小说的快速开书横幅同高；窄屏换到说明下方。
const double _inlinePickerMinWidth = 480;
const double _inlinePickerWidth = 240;

class NovelAdaptBanner extends StatelessWidget {
  const NovelAdaptBanner({super.key, required this.picker});

  /// 原著选择器，由平台外壳提供（桌面下拉、移动端底部弹层）。
  final Widget picker;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final header = Row(
      children: [
        RevericIcon(
          RevericIcons.movie_outlined,
          size: 20,
          color: colors.accent,
        ),
        const SizedBox(width: RevericSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.t(LocaleKeys.libraryAdaptBannerTitle),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.xxs),
              Text(
                context.t(LocaleKeys.libraryAdaptBannerHint),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );

    return Material(
      color: colors.selected,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.lg),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= _inlinePickerMinWidth) {
              return Row(
                children: [
                  Expanded(child: header),
                  const SizedBox(width: RevericSpacing.lg),
                  SizedBox(width: _inlinePickerWidth, child: picker),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                const SizedBox(height: RevericSpacing.md),
                picker,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 横幅里换原著：选中一本按它预填（只替换空字段和上一本原著带入的值），
/// 清空则退回原创，已带入的信息留给用户自己决定去留。
void selectAdaptationSource(
  BuildContext context, {
  required FormFieldsController<NovelFormField> form,
  required List<Novel> sourceNovels,
  required String? sourceId,
}) {
  Novel? find(String? id) =>
      id == null ? null : sourceNovels.where((n) => n.id == id).firstOrNull;
  NovelFormPrefill prefillOf(Novel source) => NovelFormPrefill.adaptationOf(
    source,
    title: context.t(
      LocaleKeys.libraryAdaptationTitle,
      namedArgs: {'title': source.title},
    ),
  );

  final next = find(sourceId);
  if (next == null) {
    if (form.getValue<String>(NovelFormField.type) == novelTypeAdaptation) {
      form.updateValue(NovelFormField.type, novelTypeOriginal, notify: false);
    }
    form.updateValue<String?>(NovelFormField.sourceNovelId, null);
    return;
  }
  final previous = find(form.getValue<String?>(NovelFormField.sourceNovelId));
  prefillOf(
    next,
  ).applyTo(form, replacing: previous == null ? null : prefillOf(previous));
}
