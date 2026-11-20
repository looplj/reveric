// 职责: 移动端文档分区目录浏览 — 在当前面板内按父文件夹下钻，面包屑返回，导入与新建落在当前层
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/mobile/widgets/delete_confirm.dart
//   lib/mobile/pages/entry_editor_page.dart
//   lib/mobile/services/document_import_orchestrator.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/file-access.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/models/document.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../pages/entry_editor_page.dart';
import '../services/document_import_orchestrator.dart';
import 'delete_confirm.dart';
import 'section_scaffold.dart';
import '../../shared/components/reveric_dialog.dart';
import '../../shared/components/reveric_button.dart';

final _log = AppLogger.forModule('MobileDocumentFolderBrowser');

int _compareDocumentsInFolder(Document a, Document b) {
  final sortOrder = a.sortOrder.compareTo(b.sortOrder);
  if (sortOrder != 0) {
    return sortOrder;
  }
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// 当前文件夹的直接子项。根目录额外展示父节点已丢失的孤儿文档，避免无法访问。
@visibleForTesting
List<Document> documentsInFolder({
  required List<Document> documents,
  required String? folderId,
}) {
  final ids = <String>{for (final document in documents) document.id};
  final children = folderId == null
      ? documents.where(
          (document) =>
              document.parentId == null || !ids.contains(document.parentId),
        )
      : documents.where((document) => document.parentId == folderId);
  return children.toList()..sort(_compareDocumentsInFolder);
}

/// 从根到当前文件夹的面包屑（不含虚拟根）。当前文件夹不存在时返回空。
@visibleForTesting
List<Document> documentFolderBreadcrumb({
  required List<Document> documents,
  required String? folderId,
}) {
  if (folderId == null) {
    return const [];
  }
  final byId = <String, Document>{
    for (final document in documents) document.id: document,
  };
  final crumbs = <Document>[];
  final visited = <String>{};
  var current = byId[folderId];
  while (current != null && visited.add(current.id)) {
    crumbs.add(current);
    final parentId = current.parentId;
    current = parentId == null ? null : byId[parentId];
  }
  return crumbs.reversed.toList();
}

/// 若当前文件夹已被删除，回到根目录。
@visibleForTesting
String? resolvedDocumentFolderId({
  required List<Document> documents,
  required String? folderId,
}) {
  if (folderId == null) {
    return null;
  }
  for (final document in documents) {
    if (document.id == folderId && document.isFolder) {
      return folderId;
    }
  }
  return null;
}

class MobileDocumentFolderBrowser extends HookConsumerWidget {
  const MobileDocumentFolderBrowser({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.section,
    this.onRegisterCreate,
  });

  final String databasePath;
  final String novelId;
  final MobileEditorSection section;
  final ValueChanged<Future<void> Function()?>? onRegisterCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentFolderId = useState<String?>(null);
    final currentFolderIdRef = useRef<String?>(null);
    currentFolderIdRef.value = currentFolderId.value;

    final onRegisterCreateRef = useRef(onRegisterCreate);
    onRegisterCreateRef.value = onRegisterCreate;

    final defaultTitle = context.t(section.newLabelKey);
    final defaultTitleRef = useRef(defaultTitle);
    defaultTitleRef.value = defaultTitle;

    final documentsAsync = ref.watch(
      documentsProvider(path: databasePath, type: section.typeValue),
    );
    final documents = documentsAsync.asData?.value;

    final showCreateChoiceRef = useRef<Future<void> Function()>(() async {});

    useEffect(() {
      Future<void> createFromHeader() async {
        await showCreateChoiceRef.value();
      }

      onRegisterCreateRef.value?.call(createFromHeader);
      return () => onRegisterCreateRef.value?.call(null);
    }, const []);

    final resolvedFolderId = documents == null
        ? currentFolderId.value
        : resolvedDocumentFolderId(
            documents: documents,
            folderId: currentFolderId.value,
          );
    useEffect(() {
      if (resolvedFolderId != currentFolderId.value) {
        currentFolderId.value = resolvedFolderId;
        currentFolderIdRef.value = resolvedFolderId;
      }
      return null;
    }, [resolvedFolderId, currentFolderId.value]);

    Future<void> createDocumentInFolder() async {
      final service = ref.read(novelContentServiceProvider(databasePath));
      final id = await service.documentsService.createDocument(
        type: section.typeValue,
        parentId: currentFolderIdRef.value,
        defaultTitle: defaultTitleRef.value,
      );
      if (!context.mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileEntryEditorPage(
            novelId: novelId,
            databasePath: databasePath,
            section: section,
            entryId: id,
          ),
        ),
      );
    }

    Future<void> createFolderInCurrent() async {
      final folderName = await _promptNewFolderName(context);
      if (!context.mounted || folderName == null || folderName.isEmpty) {
        return;
      }
      try {
        await ref
            .read(novelContentServiceProvider(databasePath))
            .documentsService
            .createFolder(
              type: section.typeValue,
              parentId: currentFolderIdRef.value,
              title: folderName,
            );
      } on ArgumentError catch (error) {
        _log.warning('create folder rejected: $error');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                error.message?.toString() ??
                    context.t(LocaleKeys.workspaceCreateFolderFailed),
              ),
            ),
          );
        }
      } catch (error, stackTrace) {
        _log.error(
          'create folder failed type=${section.typeValue}',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.workspaceCreateFolderFailed)),
            ),
          );
        }
      }
    }

    Future<void> showCreateChoice() async {
      final kind = await _showCreateDocumentOrFolderSheet(
        context,
        documentLabel: defaultTitleRef.value,
      );
      if (!context.mounted || kind == null) {
        return;
      }
      switch (kind) {
        case _DocumentCreateKind.document:
          await createDocumentInFolder();
        case _DocumentCreateKind.folder:
          await createFolderInCurrent();
      }
    }

    showCreateChoiceRef.value = showCreateChoice;

    if (documents == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final folderId = resolvedFolderId;
    final entries = documentsInFolder(documents: documents, folderId: folderId);
    final crumbs = documentFolderBreadcrumb(
      documents: documents,
      folderId: folderId,
    );

    Future<void> openDocument(Document document) async {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileEntryEditorPage(
            novelId: novelId,
            databasePath: databasePath,
            section: section,
            entryId: document.id,
          ),
        ),
      );
    }

    void openFolder(String id) {
      currentFolderId.value = id;
      currentFolderIdRef.value = id;
    }

    void selectFolder(String? id) {
      currentFolderId.value = id;
      currentFolderIdRef.value = id;
    }

    Future<void> deleteEntry(Document document) async {
      final confirmed = document.isFolder
          ? await showMobileDeleteFolderConfirm(context, title: document.title)
          : await showMobileDeleteConfirm(context, title: document.title);
      if (!confirmed || !context.mounted) {
        return;
      }
      final service = ref.read(novelContentServiceProvider(databasePath));
      if (document.isFolder) {
        await service.documentsService.deleteDocumentRecursive(document.id);
      } else {
        await service.documentsService.deleteDocument(document.id);
      }
    }

    Future<void> importInFolder() async {
      final source = mobileDocumentImportSupportsDirectory()
          ? await _showDocumentImportSourceSheet(context)
          : MobileDocumentImportSource.file;
      if (!context.mounted || source == null) {
        return;
      }

      const orchestrator = MobileDocumentImportOrchestrator();
      final MobileDocumentImportSelection selection;
      try {
        final picked = await orchestrator.pick(source);
        if (!context.mounted) {
          if (picked != null) {
            await orchestrator.cleanup(picked);
          }
          return;
        }
        if (picked == null) {
          return;
        }
        selection = picked;
      } catch (error, stackTrace) {
        _log.error(
          'document import picker failed source=${source.name}',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.workspaceImportFailed)),
            ),
          );
        }
        return;
      }

      if (selection.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.workspaceImportEmpty))),
        );
        return;
      }

      showRevericDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      try {
        _log.info(
          'document import started source=${source.name} type=${section.typeValue}',
        );
        final importResult = await orchestrator.importPicked(
          documentsService: ref
              .read(novelContentServiceProvider(databasePath))
              .documentsService,
          type: section.typeValue,
          parentId: currentFolderIdRef.value,
          selection: selection,
        );
        if (!context.mounted) {
          return;
        }
        final message = importResult.isEmpty
            ? context.t(LocaleKeys.workspaceImportEmpty)
            : importResult.skipped > 0
            ? context.t(
                LocaleKeys.workspaceImportResultWithSkipped,
                namedArgs: {
                  'count': '${importResult.imported}',
                  'skipped': '${importResult.skipped}',
                },
              )
            : context.t(
                LocaleKeys.workspaceImportResult,
                namedArgs: {'count': '${importResult.imported}'},
              );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        _log.info(
          'document import completed source=${source.name} '
          'imported=${importResult.imported} skipped=${importResult.skipped}',
        );
      } catch (error, stackTrace) {
        _log.error(
          'document import failed source=${source.name}',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.workspaceImportFailed)),
            ),
          );
        }
      } finally {
        await orchestrator.cleanup(selection);
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      }
    }

    return MobileSectionListScaffold(
      createLabel: defaultTitle,
      onCreate: showCreateChoice,
      showCreateBar: false,
      header: crumbs.isEmpty
          ? null
          : _FolderBreadcrumb(crumbs: crumbs, onSelect: selectFolder),
      bottomAction: MobileSectionBottomAction(
        label: context.t(_importLabelKeyFor(section)),
        onTap: importInFolder,
      ),
      emptyIcon: section.listIcon,
      emptySectionLabel: context.t(section.labelKey),
      emptyHint: context.t(section.hintKey),
      itemCount: entries.length,
      itemBuilder: (_, index) {
        final entry = entries[index];
        if (entry.isFolder) {
          return _FolderCard(
            document: entry,
            onTap: () => openFolder(entry.id),
            onDelete: () => deleteEntry(entry),
          );
        }
        return _DocumentCard(
          section: section,
          document: entry,
          onTap: () => openDocument(entry),
          onDelete: () => deleteEntry(entry),
        );
      },
    );
  }
}

String _importLabelKeyFor(MobileEditorSection section) => switch (section) {
  MobileEditorSection.lore => LocaleKeys.workspaceImportWorldbuilding,
  MobileEditorSection.materials => LocaleKeys.workspaceImportMaterial,
  _ => LocaleKeys.workspaceImportFile,
};

enum _DocumentCreateKind { document, folder }

Future<_DocumentCreateKind?> _showCreateDocumentOrFolderSheet(
  BuildContext context, {
  required String documentLabel,
}) {
  final colors = RevericTheme.colorsOf(context);
  return showModalBottomSheet<_DocumentCreateKind>(
    context: context,
    backgroundColor: colors.surface,
    isScrollControlled: true,
    showDragHandle: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    builder: (sheetContext) {
      final sheetColors = RevericTheme.colorsOf(sheetContext);
      final typo = RevericTheme.typographyOf(sheetContext);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: RevericSpacing.x5l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.x2l,
                  0,
                  RevericSpacing.x2l,
                  RevericSpacing.sm,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.t(LocaleKeys.workspaceAddDocumentOrFolder),
                    style: typo.uiSemibold.copyWith(
                      color: sheetColors.textPrimary,
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: RevericIcon(
                  RevericIcons.description_outlined,
                  size: 20,
                  color: sheetColors.accent,
                ),
                title: Text(
                  documentLabel,
                  style: typo.ui.copyWith(color: sheetColors.textPrimary),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop(_DocumentCreateKind.document);
                },
              ),
              ListTile(
                leading: RevericIcon(
                  RevericIcons.create_new_folder,
                  size: 20,
                  color: sheetColors.accent,
                ),
                title: Text(
                  context.t(LocaleKeys.workspaceNewFolder),
                  style: typo.ui.copyWith(color: sheetColors.textPrimary),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop(_DocumentCreateKind.folder);
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<String?> _promptNewFolderName(BuildContext context) {
  final colors = RevericTheme.colorsOf(context);
  final typo = RevericTheme.typographyOf(context);
  return showRevericDialog<String>(
    context: context,
    builder: (dialogContext) {
      return HookBuilder(
        builder: (hookContext) {
          final controller = useTextEditingController();
          return RevericDialog(
            title: context.t(LocaleKeys.workspaceNewFolder),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: context.t(LocaleKeys.workspaceNewFolderHint),
                hintStyle: typo.ui.copyWith(color: colors.textMuted),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                  borderSide: BorderSide(color: colors.accent),
                ),
              ),
              style: typo.ui.copyWith(color: colors.textPrimary),
            ),
            actions: [
              RevericButton.secondary(
                label: context.t(LocaleKeys.commonCancel),
                onPressed: () => Navigator.of(dialogContext).pop(null),
              ),
              RevericButton.primary(
                label: context.t(LocaleKeys.commonCreate),
                onPressed: () {
                  final name = controller.text.trim();
                  Navigator.of(
                    dialogContext,
                  ).pop(name.isNotEmpty ? name : null);
                },
              ),
            ],
          );
        },
      );
    },
  );
}

Future<MobileDocumentImportSource?> _showDocumentImportSourceSheet(
  BuildContext context,
) {
  final colors = RevericTheme.colorsOf(context);
  return showModalBottomSheet<MobileDocumentImportSource>(
    context: context,
    backgroundColor: colors.surface,
    isScrollControlled: true,
    showDragHandle: true,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    builder: (sheetContext) {
      final sheetColors = RevericTheme.colorsOf(sheetContext);
      final typo = RevericTheme.typographyOf(sheetContext);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: RevericSpacing.x5l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.x2l,
                  0,
                  RevericSpacing.x2l,
                  RevericSpacing.sm,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.t(LocaleKeys.workspaceImportFile),
                    style: typo.uiSemibold.copyWith(
                      color: sheetColors.textPrimary,
                    ),
                  ),
                ),
              ),
              ListTile(
                leading: RevericIcon(
                  RevericIcons.description_outlined,
                  size: 20,
                  color: sheetColors.accent,
                ),
                title: Text(
                  context.t(LocaleKeys.workspaceChooseFile),
                  style: typo.ui.copyWith(color: sheetColors.textPrimary),
                ),
                onTap: () {
                  Navigator.of(
                    sheetContext,
                  ).pop(MobileDocumentImportSource.file);
                },
              ),
              ListTile(
                leading: RevericIcon(
                  RevericIcons.folder_outlined,
                  size: 20,
                  color: sheetColors.accent,
                ),
                title: Text(
                  context.t(LocaleKeys.workspaceChooseDirectory),
                  style: typo.ui.copyWith(color: sheetColors.textPrimary),
                ),
                onTap: () {
                  Navigator.of(
                    sheetContext,
                  ).pop(MobileDocumentImportSource.directory);
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _FolderBreadcrumb extends StatelessWidget {
  const _FolderBreadcrumb({required this.crumbs, required this.onSelect});

  final List<Document> crumbs;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final items = <Widget>[
      _BreadcrumbLabel(
        label: context.t(LocaleKeys.commonRootDirectory),
        emphasized: false,
        onTap: () => onSelect(null),
      ),
    ];
    for (var index = 0; index < crumbs.length; index++) {
      final crumb = crumbs[index];
      final isCurrent = index == crumbs.length - 1;
      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.xs),
          child: RevericIcon(
            RevericIcons.chevron_right,
            size: 12,
            color: colors.textSubtle,
          ),
        ),
      );
      items.add(
        _BreadcrumbLabel(
          label: crumb.title.trim().isEmpty
              ? context.t(LocaleKeys.workspaceUntitledFolder)
              : crumb.title.trim(),
          emphasized: isCurrent,
          onTap: isCurrent ? null : () => onSelect(crumb.id),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x4l,
        0,
        RevericSpacing.x4l,
        RevericSpacing.sm,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: items),
        ),
      ),
    );
  }
}

class _BreadcrumbLabel extends StatelessWidget {
  const _BreadcrumbLabel({
    required this.label,
    required this.emphasized,
    this.onTap,
  });

  final String label;
  final bool emphasized;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final style = (emphasized ? typo.uiSmallSemibold : typo.uiSmall).copyWith(
      color: emphasized ? colors.textPrimary : colors.accent,
    );
    final text = Text(label, style: style);
    if (onTap == null) {
      return text;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.small),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.xxs,
          vertical: RevericSpacing.xxs,
        ),
        child: text,
      ),
    );
  }
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.document,
    required this.onTap,
    required this.onDelete,
  });

  final Document document;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final title = document.title.trim().isEmpty
        ? context.t(LocaleKeys.workspaceUntitledFolder)
        : document.title.trim();

    return MobileSectionCard(
      onTap: onTap,
      onDelete: onDelete,
      deleteLabel: context.t(LocaleKeys.commonDelete),
      child: Row(
        children: [
          RevericIcon(
            RevericIcons.folder_outlined,
            size: 22,
            color: colors.accentWarm,
          ),
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          const MobileSectionTrailingChevron(),
        ],
      ),
    );
  }
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({
    required this.section,
    required this.document,
    required this.onTap,
    required this.onDelete,
  });

  final MobileEditorSection section;
  final Document document;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final title = document.title.trim().isEmpty
        ? context.t(LocaleKeys.commonUntitled)
        : document.title.trim();
    final preview = _previewOf(document.content);

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
