// 职责: 展示图鉴条目的名称、分类与正文预览，承接全屏编辑和左滑删除。
// 关联文件:
//   lib/mobile/widgets/compendium_panel.dart
//   lib/mobile/pages/entry_editor_page.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../pages/entry_editor_page.dart';
import 'delete_confirm.dart';
import 'section_scaffold.dart';

class CompendiumEntryRow extends ConsumerWidget {
  const CompendiumEntryRow({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.section,
    required this.entry,
  });

  final String databasePath;
  final String novelId;
  final MobileEditorSection section;
  final Item entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final title = entry.title.trim().isEmpty
        ? context.t(LocaleKeys.commonUntitled)
        : entry.title;
    return MobileSectionCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileEntryEditorPage(
            novelId: novelId,
            databasePath: databasePath,
            section: section,
            entryId: entry.id,
          ),
        ),
      ),
      deleteLabel: context.t(LocaleKeys.commonDelete),
      onDelete: () async {
        final confirmed = await showMobileDeleteConfirm(context, title: title);
        if (!confirmed || !context.mounted) {
          return;
        }
        await ref
            .read(novelContentServiceProvider(databasePath))
            .deleteItem(entry.id);
      },
      child: Row(
        children: [
          Container(
            width: RevericSizes.blockquoteBorderWidth,
            height: RevericSizes.iconButtonSize,
            color: section.listTint(colors).withValues(alpha: .65),
          ),
          const SizedBox(width: RevericSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
                if (entry.category.isNotEmpty)
                  Text(
                    entry.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
                if (entry.content.trim().isNotEmpty)
                  Text(
                    entry.content.replaceAll(RegExp(r'\s+'), ' ').trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
              ],
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          const MobileSectionTrailingChevron(),
        ],
      ),
    );
  }
}
