// 职责: 移动端作品编辑器简单分区列表 — 列出世界观/素材/技能/物品/势力/生物条目、新建/导入、左滑删除、点击进入条目编辑页；文档分区走目录下钻，其余读取本地 items 数据。
// 关联文件:
//   lib/mobile/pages/entry_editor_page.dart
//   lib/mobile/widgets/document_folder_browser.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/mobile/widgets/delete_confirm.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../pages/entry_editor_page.dart';
import 'delete_confirm.dart';
import 'document_folder_browser.dart';
import 'section_scaffold.dart';

/// 列表用的精简条目视图模型，抹平 Item 差异。
class _Entry {
  const _Entry({required this.id, required this.title, required this.content});

  final String id;
  final String title;
  final String content;
}

class MobileSectionPanel extends ConsumerWidget {
  const MobileSectionPanel({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.section,
    required this.onCreate,
    this.onRegisterDocumentCreate,
  });

  final String databasePath;
  final String novelId;
  final MobileEditorSection section;

  /// 新建入口由标题栏右上角承载；空状态引导按钮复用同一回调。
  final VoidCallback onCreate;

  /// 文档分区把「在当前文件夹新建」注册给标题栏；物品分区忽略。
  final ValueChanged<Future<void> Function()?>? onRegisterDocumentCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (section.isDocument) {
      return MobileDocumentFolderBrowser(
        novelId: novelId,
        databasePath: databasePath,
        section: section,
        onRegisterCreate: onRegisterDocumentCreate,
      );
    }

    final async = ref.watch(
      itemsProvider(path: databasePath, type: section.typeValue),
    );
    final entries = async.asData?.value
        .map(
          (item) =>
              _Entry(id: item.id, title: item.title, content: item.content),
        )
        .toList();

    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }

    Future<void> openEditor(_Entry entry) async {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileEntryEditorPage(
            novelId: novelId,
            databasePath: databasePath,
            section: section,
            entryId: entry.id,
          ),
        ),
      );
    }

    Future<void> deleteEntry(_Entry entry) async {
      final confirmed = await showMobileDeleteConfirm(
        context,
        title: entry.title,
      );
      if (!confirmed) {
        return;
      }
      final service = ref.read(novelContentServiceProvider(databasePath));
      await service.deleteItem(entry.id);
    }

    return MobileSectionListScaffold(
      createLabel: context.t(section.newLabelKey),
      onCreate: onCreate,
      showCreateBar: false,
      emptyIcon: section.listIcon,
      emptySectionLabel: context.t(section.labelKey),
      emptyHint: context.t(section.hintKey),
      itemCount: entries.length,
      itemBuilder: (_, index) {
        final entry = entries[index];
        return _EntryCard(
          section: section,
          entry: entry,
          onTap: () => openEditor(entry),
          onDelete: () => deleteEntry(entry),
        );
      },
    );
  }
}

/// 单条目卡片：图标 + 标题 + 正文预览。
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.section,
    required this.entry,
    required this.onTap,
    required this.onDelete,
  });

  final MobileEditorSection section;
  final _Entry entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final title = entry.title.trim().isEmpty
        ? context.t(LocaleKeys.commonUntitled)
        : entry.title.trim();
    final preview = _previewOf(entry.content);

    return MobileSectionCard(
      onTap: onTap,
      onDelete: onDelete,
      deleteLabel: context.t(LocaleKeys.commonDelete),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          MobileSectionIconBox(
            icon: section.listIcon,
            tint: section.listTint(colors),
          ),
          const SizedBox(width: RevericSpacing.md),
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
                const SizedBox(height: 3),
                MobileSectionPreviewText(
                  preview: preview,
                  emptyPlaceholder: context.t(
                    LocaleKeys.mobileEditorEntryNoContent,
                  ),
                  maxLines: 2,
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

String _previewOf(String content) {
  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) {
      continue;
    }
    return line.replaceFirst(RegExp(r'^[#>\-\*\s]+'), '').trim();
  }
  return '';
}
