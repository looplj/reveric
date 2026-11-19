// 职责: 从书架导入画布包并新建作品，或把书架上的画布作品导出成压缩包，导入和导出时显示进度。
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/desktop/widgets/novel_list.dart
//   lib/desktop/features/production/canvas_package_file.dart
//   lib/shared/services/production/canvas_package.dart
//   lib/desktop/pages/workspace_editor_page.dart
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
import 'canvas_package_file.dart';

final _log = AppLogger.forModule('ProductionCanvasPackageActions');

Future<void> importCanvasFromShelf(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final path = await pickProductionCanvasPackage();
  if (path == null || !context.mounted) {
    return;
  }
  final container = ProviderScope.containerOf(context);
  final fallbackTitle = context.t(LocaleKeys.libraryDefaultCanvasTitle);
  final result = await showRevericDialog<_CanvasImportRun>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CanvasImportProgressDialog(
      run: (report) => const ProductionCanvasPackageOrchestrator().importFile(
        zip: File(path),
        actions: container.read(novelActionsProvider),
        library: container.read(mediaLibraryServiceProvider),
        fallbackTitle: fallbackTitle,
        openContent: NovelContentDatabase.new,
        releaseContent: (database) => database.close(),
        onProgress: report,
      ),
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
          context.t(
            error.code == 'invalid_package' || error.code == 'missing_media'
                ? LocaleKeys.productionImportCanvasInvalid
                : LocaleKeys.productionImportCanvasFailed,
          ),
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
  final result = await showRevericDialog<_CanvasExportOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CanvasExportProgressDialog(
      run: (report) async {
        final service = ProductionCanvasService(
          container.read(
            storyboardServiceProvider(databasePath, novelId: novel.id),
          ),
          container.read(mediaLibraryServiceProvider),
          novel.id,
        );
        final canvas = await service.ensureCanvas('');
        final file = await const ProductionCanvasPackageOrchestrator()
            .exportToFile(
              canvas: service,
              canvasId: canvas.id,
              title: title,
              onProgress: (value) => report(value * 0.85),
            );
        final status = await saveProductionCanvasPackage(
          file.file,
          title: title,
          onProgress: (value) => report(0.85 + value * 0.15),
        );
        return _CanvasExportOutcome(file: file, status: status);
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
        SnackBar(content: Text(context.t(_exportMessage(error.code)))),
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

String _exportMessage(String code) => switch (code) {
  'empty' => LocaleKeys.productionExportCanvasEmpty,
  'canvas_only' => LocaleKeys.productionCanvasPackageCanvasOnly,
  'missing_media' => LocaleKeys.productionExportCanvasMissingMedia,
  _ => LocaleKeys.productionExportCanvasFailed,
};
