// 职责: 从书架导入画布包并新建作品，或把书架上的画布作品导出成压缩包，导入和导出时显示进度。
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/desktop/widgets/novel_list.dart
//   lib/desktop/features/production/canvas_package_file.dart
//   lib/shared/services/production/canvas_package.dart
//   lib/desktop/features/canvas_gallery/conversation_selection.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/i18n.md
//   .agents/rules/error-handling.md
//   .agents/rules/file-access.md

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/novel.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/production_media.dart';
import '../../../shared/providers/storyboard.dart';
import '../../../shared/services/production/canvas_package.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import '../../pages/workspace_editor_page.dart';
import '../canvas_gallery/conversation_selection.dart';
import 'canvas_package_file.dart';

final _log = AppLogger.forModule('ProductionCanvasPackageActions');

Future<void> importCanvasFromShelf(BuildContext context) async {
  final path = await pickProductionCanvasPackage();
  if (path == null || !context.mounted) {
    return;
  }
  await importObtainedCanvasZip(context, File(path));
}

Future<void> importObtainedCanvasZip(BuildContext context, File zip) =>
    _runCanvasImport(
      context,
      run: (container, fallbackTitle, report) =>
          const ProductionCanvasPackageOrchestrator().importFile(
            zip: zip,
            actions: container.read(novelActionsProvider),
            library: container.read(mediaLibraryServiceProvider),
            fallbackTitle: fallbackTitle,
            openContent: NovelContentDatabase.new,
            releaseContent: (database) => database.close(),
            onProgress: report,
          ),
    );

Future<void> importObtainedCanvasCache(
  BuildContext context,
  Directory cacheDirectory,
) => _runCanvasImport(
  context,
  run: (container, fallbackTitle, report) =>
      const ProductionCanvasPackageOrchestrator().importFromCacheDirectory(
        cacheDirectory: cacheDirectory,
        actions: container.read(novelActionsProvider),
        library: container.read(mediaLibraryServiceProvider),
        fallbackTitle: fallbackTitle,
        openContent: NovelContentDatabase.new,
        releaseContent: (database) => database.close(),
        onProgress: report,
      ),
);

Future<void> _runCanvasImport(
  BuildContext context, {
  required Future<ProductionCanvasPackageImport> Function(
    ProviderContainer container,
    String fallbackTitle,
    void Function(double progress) report,
  )
  run,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final container = ProviderScope.containerOf(context);
  final fallbackTitle = context.t(LocaleKeys.libraryDefaultCanvasTitle);
  final result = await showRevericDialog<_CanvasImportRun>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CanvasImportProgressDialog(
      run: (report) => run(container, fallbackTitle, report),
    ),
  );
  if (!context.mounted || result == null) {
    return;
  }
  final error = result.error;
  if (error is ProductionCanvasPackageException) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          context.t(switch (error.code) {
            'unsupported' => LocaleKeys.productionGalleryImportUpgrade,
            'invalid_package' ||
            'missing_media' => LocaleKeys.productionImportCanvasInvalid,
            _ => LocaleKeys.productionImportCanvasFailed,
          }),
        ),
      ),
    );
    return;
  }
  if (error != null) {
    _log.error(
      'import stage=action result=failed',
      error: error,
      stackTrace: result.stackTrace,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(context.t(LocaleKeys.productionImportCanvasFailed)),
      ),
    );
    return;
  }
  final imported = result.imported;
  if (imported == null) {
    return;
  }
  final message = imported.droppedStyles == 0
      ? context.t(LocaleKeys.productionImportCanvasCreated)
      : context.t(
          LocaleKeys.productionImportCanvasStyles,
          namedArgs: {'count': '${imported.droppedStyles}'},
        );
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => WorkspaceEditorPage(novelId: imported.novelId),
    ),
  );
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

Future<void> exportCanvasFromShelf(BuildContext context, Novel novel) async {
  final messenger = ScaffoldMessenger.of(context);
  final databasePath = novel.contentDatabasePath;
  if (databasePath == null || databasePath.isEmpty) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(context.t(LocaleKeys.productionExportCanvasFailed)),
      ),
    );
    return;
  }
  final title = novel.title.trim().isEmpty
      ? context.t(LocaleKeys.libraryDefaultCanvasTitle)
      : novel.title.trim();
  final container = ProviderScope.containerOf(context);
  final service = ProductionCanvasService(
    container.read(storyboardServiceProvider(databasePath, novelId: novel.id)),
    container.read(mediaLibraryServiceProvider),
    novel.id,
  );
  final persistence = container.read(
    aiSessionPersistenceServiceProvider(
      novelId: novel.id,
      databasePath: databasePath,
    ),
  );
  final selected = await showCanvasConversationSelection(
    context,
    load: () => listProductionCanvasPackageConversations(
      sessionPersistence: persistence,
      novelDatabase: service.shots.database,
    ),
  );
  if (!context.mounted || selected == null) {
    return;
  }
  final result = await showRevericDialog<_CanvasExportOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CanvasExportProgressDialog(
      run: (report) async {
        final canvas = await service.ensureCanvas('');
        final file = await const ProductionCanvasPackageOrchestrator()
            .exportToFile(
              canvas: service,
              canvasId: canvas.id,
              title: title,
              sessionPersistence: persistence,
              conversationIds: selected.toList(),
              onProgress: (value) => report(value * 0.85),
            );
        try {
          final status = await saveProductionCanvasPackage(
            file.file,
            title: title,
            onProgress: (value) => report(0.85 + value * 0.15),
          );
          return _CanvasExportOutcome(file: file, status: status);
        } catch (error, stackTrace) {
          return _CanvasExportOutcome(
            file: file,
            error: error,
            stackTrace: stackTrace,
          );
        }
      },
    ),
  );
  if (!context.mounted || result == null) {
    await result?.file?.delete();
    return;
  }
  try {
    final error = result.error;
    if (error is ProductionCanvasPackageException) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            context.t(
              canvasPackageExportMessage(error.code),
              namedArgs: error.subject != null
                  ? {'subject': error.subject!}
                  : null,
            ),
          ),
        ),
      );
      return;
    }
    if (error != null) {
      _log.error(
        'export stage=action result=failed',
        error: error,
        stackTrace: result.stackTrace,
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(context.t(LocaleKeys.productionExportCanvasFailed)),
        ),
      );
      return;
    }
    if (result.status == ProductionCanvasPackageSaveStatus.cancelled ||
        result.status == null) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          context.t(
            result.status == ProductionCanvasPackageSaveStatus.saved
                ? LocaleKeys.productionExportCanvasSaved
                : LocaleKeys.productionExportCanvasFailed,
          ),
        ),
      ),
    );
  } finally {
    await result.file?.delete();
  }
}

class _CanvasExportOutcome {
  const _CanvasExportOutcome({
    this.file,
    this.status,
    this.error,
    this.stackTrace,
  });

  final ProductionCanvasPackageFile? file;
  final ProductionCanvasPackageSaveStatus? status;
  final Object? error;
  final StackTrace? stackTrace;
}

class _CanvasExportProgressDialog extends StatefulWidget {
  const _CanvasExportProgressDialog({required this.run});

  final Future<_CanvasExportOutcome> Function(
    void Function(double progress) onProgress,
  )
  run;

  @override
  State<_CanvasExportProgressDialog> createState() =>
      _CanvasExportProgressDialogState();
}

class _CanvasExportProgressDialogState
    extends State<_CanvasExportProgressDialog> {
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_execute());
  }

  Future<void> _execute() async {
    final _CanvasExportOutcome outcome;
    try {
      outcome = await widget.run((value) {
        if (!mounted) {
          return;
        }
        final next = value.clamp(0.0, 1.0);
        if (next < 1 && next - _progress < 0.01) {
          return;
        }
        setState(() => _progress = next);
      });
    } catch (error, stackTrace) {
      if (!mounted) {
        return;
      }
      Navigator.of(
        context,
      ).pop(_CanvasExportOutcome(error: error, stackTrace: stackTrace));
      return;
    }
    if (!mounted) {
      await outcome.file?.delete();
      return;
    }
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    return _canvasProgressDialog(
      context,
      title: context.t(LocaleKeys.commonExport),
      status: context.t(LocaleKeys.editingExporting),
      progress: _progress,
    );
  }
}

class _CanvasImportRun {
  const _CanvasImportRun({this.imported, this.error, this.stackTrace});

  final ProductionCanvasPackageImport? imported;
  final Object? error;
  final StackTrace? stackTrace;
}

class _CanvasImportProgressDialog extends StatefulWidget {
  const _CanvasImportProgressDialog({required this.run});

  final Future<ProductionCanvasPackageImport> Function(
    void Function(double progress) onProgress,
  )
  run;

  @override
  State<_CanvasImportProgressDialog> createState() =>
      _CanvasImportProgressDialogState();
}

class _CanvasImportProgressDialogState
    extends State<_CanvasImportProgressDialog> {
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_execute());
  }

  Future<void> _execute() async {
    try {
      final imported = await widget.run((value) {
        if (!mounted) {
          return;
        }
        final next = value.clamp(0.0, 1.0);
        if (next < 1 && next - _progress < 0.01) {
          return;
        }
        setState(() => _progress = next);
      });
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(_CanvasImportRun(imported: imported));
    } catch (error, stackTrace) {
      if (!mounted) {
        return;
      }
      Navigator.of(
        context,
      ).pop(_CanvasImportRun(error: error, stackTrace: stackTrace));
    }
  }

  @override
  Widget build(BuildContext context) {
    return _canvasProgressDialog(
      context,
      title: context.t(LocaleKeys.commonImport),
      status: context.t(LocaleKeys.libraryImportingTxt),
      progress: _progress,
    );
  }
}

Widget _canvasProgressDialog(
  BuildContext context, {
  required String title,
  required String status,
  required double progress,
}) {
  final colors = RevericTheme.colorsOf(context);
  final typo = RevericTheme.typographyOf(context);
  final percent = (progress * 100).floor();
  return PopScope(
    canPop: false,
    child: RevericDialog(
      title: title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  status,
                  style: typo.uiMedium.copyWith(color: colors.textPrimary),
                ),
              ),
              Text(
                '$percent%',
                style: typo.mono.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.sm),
          LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            borderRadius: BorderRadius.circular(RevericRadius.small),
            color: colors.accent,
            backgroundColor: colors.surfaceDim,
          ),
        ],
      ),
    ),
  );
}

String canvasPackageExportMessage(String code) => switch (code) {
  'empty' => LocaleKeys.productionExportCanvasEmpty,
  'canvas_only' => LocaleKeys.productionCanvasPackageCanvasOnly,
  'missing_media' => LocaleKeys.productionExportCanvasMissingMedia,
  'missing_conversation_file' =>
    LocaleKeys.productionGalleryMissingConversationFile,
  'invalid_conversation' => LocaleKeys.productionGalleryInvalidConversation,
  'missing_style' => LocaleKeys.productionGalleryMissingStyle,
  'cover_failed' => LocaleKeys.productionGalleryCoverFailed,
  'package_too_large' => LocaleKeys.productionGalleryPackageTooLarge,
  _ => LocaleKeys.productionExportCanvasFailed,
};
