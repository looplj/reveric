// 职责: 左右双栏发布弹窗：左侧填写画布信息并选择封面，右侧选择对话，左下角提示公开范围后直接发布，并支持断点续传。
// 关联文件:
//   lib/desktop/features/canvas_gallery/conversation_selection.dart
//   lib/desktop/features/canvas_gallery/gallery_frame.dart
//   lib/desktop/features/production/package_actions.dart
//   lib/shared/services/production/canvas_package.dart
//   lib/shared/services/canvas_gallery/orchestrator.dart
//   lib/desktop/widgets/novel_list.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/form.md
//   .agents/rules/hooks.md
//   .agents/rules/icons.md
//   .agents/rules/widget-decomposition.md

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/form/hooked_text_form_field.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/novel.dart';
import '../../../shared/providers/canvas_gallery_providers.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/production_media.dart';
import '../../../shared/providers/storyboard.dart';
import '../../../shared/services/ai/session_persistence.dart';
import '../../../shared/services/canvas_gallery/orchestrator.dart';
import '../../../shared/services/canvas_gallery/service.dart';
import '../../../shared/services/production/canvas_package.dart';
import '../../../shared/services/production/canvas_preview.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import '../../../third/form/flutter_hook_form.dart';
import '../../widgets/home/novel_home_helpers.dart';
import '../production/package_actions.dart' show canvasPackageExportMessage;
import 'conversation_selection.dart';
import 'gallery_frame.dart';

final _log = AppLogger.forModule('CanvasGalleryPublish');

Future<void> publishCanvasFromShelf(BuildContext context, Novel novel) async {
  final path = novel.contentDatabasePath;
  if (path == null || path.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.t(LocaleKeys.productionExportCanvasFailed)),
      ),
    );
    return;
  }
  final container = ProviderScope.containerOf(context);
  final title = novel.title.trim().isEmpty
      ? context.t(LocaleKeys.libraryDefaultCanvasTitle)
      : novel.title.trim();
  final published = await showRevericDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PublishDialog(
      title: title,
      canvas: ProductionCanvasService(
        container.read(storyboardServiceProvider(path, novelId: novel.id)),
        container.read(mediaLibraryServiceProvider),
        novel.id,
      ),
      sessions: container.read(
        aiSessionPersistenceServiceProvider(
          novelId: novel.id,
          databasePath: path,
        ),
      ),
      service: container.read(canvasGalleryServiceProvider),
    ),
  );
  if (context.mounted && published == true) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t(LocaleKeys.productionGalleryPublished))),
    );
  }
}

enum _Field implements FieldSchema {
  title,
  description;

  @override
  List<Validator<dynamic>>? get validators => null;
}

enum _PublishStep { edit, prepare, upload }

class _PublishSession {
  Future<void>? pending;
  CanvasGalleryPublishOrchestrator uploader =
      CanvasGalleryPublishOrchestrator();
  ProductionCanvasPackageFile? package;
  String title = '';
  String description = '';
  Set<String> conversationIds = {};
  String? coverAssetId;
  bool attempted = false;
  bool expiredOrRejected = false;

  Future<void> reset() async {
    uploader.cancel();
    uploader = CanvasGalleryPublishOrchestrator();
    attempted = false;
    expiredOrRejected = false;
    conversationIds = {};
    coverAssetId = null;
    final previous = package;
    package = null;
    await previous?.delete();
  }

  Future<void> dispose() async {
    uploader.cancel();
    try {
      await pending;
    } finally {
      await package?.delete();
    }
  }
}

class _PublishDialog extends HookWidget {
  const _PublishDialog({
    required this.title,
    required this.canvas,
    required this.sessions,
    required this.service,
  });

  final String title;
  final ProductionCanvasService canvas;
  final AiSessionPersistenceService sessions;
  final CanvasGalleryService service;

  @override
  Widget build(BuildContext context) {
    final state = useMemoized(_PublishSession.new);
    final form = useForm<_Field>(
      initialValues: {_Field.title: title, _Field.description: ''},
    );
    final chosen = useState<Set<String>?>(null);
    final coverAssetId = useState<String?>(null);
    final step = useState(_PublishStep.edit);
    final progress = useState(0.0);
    final failure = useState<String?>(null);
    final retrySessions = useState(0);
    final canvasId = useMemoized(
      () async => (await canvas.ensureCanvas('')).id,
    );
    final sessionRequest = useMemoized(() async {
      try {
        return await listProductionCanvasPackageConversations(
          sessionPersistence: sessions,
          novelDatabase: canvas.shots.database,
        );
      } catch (error, stackTrace) {
        _log.error(
          'Saved conversations unavailable',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    }, [retrySessions.value]);
    final available = useFuture(sessionRequest, preserveState: false);
    final loaded = available.data;
    final selectedIds = loaded == null
        ? const <String>{}
        : chosen.value ?? {for (final item in loaded) item.summary.id};

    useEffect(() {
      return () => unawaited(
        state.dispose().catchError((Object error, StackTrace stack) {
          _log.error(
            'Publication cleanup failed',
            error: error,
            stackTrace: stack,
          );
        }),
      );
    }, [state]);

    void report(double value) {
      if (context.mounted && (value >= 1 || value - progress.value >= 0.01)) {
        progress.value = value;
      }
    }

    void setFailure(Object error, StackTrace stackTrace) {
      if (!context.mounted) {
        return;
      }
      if (error is ProductionCanvasPackageException) {
        final key = error.code == 'missing_media' && error.subject != null
            ? LocaleKeys.productionGalleryMissingMedia
            : canvasPackageExportMessage(error.code);
        failure.value = error.subject == null
            ? context.t(key)
            : context.t(key, namedArgs: {'subject': error.subject!});
      } else if (error is CanvasGalleryFailure) {
        state.expiredOrRejected = error.status == 410 || error.status == 422;
        failure.value = context.t(switch (error) {
          CanvasGalleryFailure(status: 410) =>
            LocaleKeys.productionGalleryUploadExpired,
          CanvasGalleryFailure(status: 413) =>
            LocaleKeys.productionGalleryPackageTooLarge,
          CanvasGalleryFailure(code: 'package_too_large') =>
            LocaleKeys.productionGalleryPackageTooLarge,
          CanvasGalleryFailure(status: 422) =>
            LocaleKeys.productionGalleryUploadRejected,
          CanvasGalleryFailure(status: 429) =>
            LocaleKeys.productionGalleryUploadBusy,
          CanvasGalleryFailure(code: 'uploads_paused') =>
            LocaleKeys.productionGalleryUploadPaused,
          _ => LocaleKeys.productionGalleryPublishFailed,
        });
      } else {
        _log.error(
          'Publication failed step=${step.value.name}',
          error: error,
          stackTrace: stackTrace,
        );
        failure.value = context.t(
          step.value == _PublishStep.upload
              ? LocaleKeys.productionGalleryPublishFailed
              : LocaleKeys.productionExportCanvasFailed,
        );
      }
    }

    Future<void> publish() async {
      if (step.value != _PublishStep.edit || !form.validate()) {
        return;
      }
      final nextTitle = (form.getValue<String>(_Field.title) ?? '').trim();
      final description = (form.getValue<String>(_Field.description) ?? '')
          .trim();
      if (nextTitle.isEmpty || nextTitle.runes.length > 80) {
        form.setError(
          _Field.title,
          context.t(LocaleKeys.productionGalleryTitleInvalid),
        );
        return;
      }
      if (description.isEmpty || description.runes.length > 500) {
        form.setError(
          _Field.description,
          context.t(LocaleKeys.productionGalleryDescriptionInvalid),
        );
        return;
      }
      final ids = selectedIds;
      final resume =
          state.package != null &&
          !state.expiredOrRejected &&
          state.title == nextTitle &&
          state.description == description &&
          state.coverAssetId == coverAssetId.value &&
          _sameConversationIds(state.conversationIds, ids);
      FocusManager.instance.primaryFocus?.unfocus();
      failure.value = null;
      progress.value = 0;
      try {
        if (!resume) {
          step.value = _PublishStep.prepare;
          await state.reset();
          final package = await const ProductionCanvasPackageOrchestrator()
              .exportToFile(
                canvas: canvas,
                canvasId: await canvasId,
                title: nextTitle,
                publicGallery: true,
                sessionPersistence: sessions,
                conversationIds: ids.toList(),
                onProgress: report,
              );
          try {
            final bytes = await package.file.length();
            if (bytes > canvasGalleryPackageLimit) {
              throw const ProductionCanvasPackageException('package_too_large');
            }
            final chosenCover = coverAssetId.value;
            if (chosenCover != null) {
              await _replacePackageCover(canvas, package, chosenCover);
            }
            state.package = package;
            state.title = nextTitle;
            state.description = description;
            state.conversationIds = ids;
            state.coverAssetId = chosenCover;
          } catch (error) {
            await package.delete();
            rethrow;
          }
        }
        final package = state.package;
        if (!context.mounted || package == null) {
          return;
        }
        state.attempted = true;
        step.value = _PublishStep.upload;
        progress.value = 0;
        await state.uploader.publish(
          service: service,
          cover: package.cover!,
          archive: package.file,
          title: state.title,
          description: state.description,
          onProgress: report,
        );
        if (context.mounted) {
          Navigator.of(context).pop(true);
        }
      } catch (error, stackTrace) {
        if (error is CanvasGalleryFailure && error.code == 'cancelled') {
          return;
        }
        setFailure(error, stackTrace);
        if (context.mounted) {
          step.value = _PublishStep.edit;
        }
      }
    }

    void run(Future<void> Function() operation) {
      if (state.pending != null) {
        return;
      }
      final work = operation();
      state.pending = work;
      unawaited(work.whenComplete(() => state.pending = null));
    }

    final editing = step.value == _PublishStep.edit;
    final preparing = step.value == _PublishStep.prepare;
    final uploading = step.value == _PublishStep.upload;
    final loading = uploading || preparing;
    final draftTitle = (form.getValue<String>(_Field.title) ?? '').trim();
    final draftDescription = (form.getValue<String>(_Field.description) ?? '')
        .trim();
    final canResume =
        state.package != null &&
        state.attempted &&
        !state.expiredOrRejected &&
        state.title == draftTitle &&
        state.description == draftDescription &&
        state.coverAssetId == coverAssetId.value &&
        _sameConversationIds(state.conversationIds, selectedIds);

    final bodyHeight = math.min(
      520.0,
      math.max(320.0, MediaQuery.sizeOf(context).height - 200),
    );

    final statusBar = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (loading) ...[
          const SizedBox(height: RevericSpacing.md),
          GalleryProgressBar(
            label: context.t(
              uploading
                  ? progress.value >= 1
                        ? LocaleKeys.productionGalleryFinalizing
                        : LocaleKeys.productionGalleryUploading
                  : LocaleKeys.productionGalleryPreparing,
            ),
            progress: progress.value >= 1 ? null : progress.value,
          ),
        ],
        if (failure.value case final message?) ...[
          const SizedBox(height: RevericSpacing.md),
          GalleryNoticeBanner(message: message),
        ],
      ],
    );

    return PopScope(
      canPop: !loading,
      child: RevericDialog.panel(
        title: Text(context.t(LocaleKeys.productionGalleryPublish)),
        width: RevericSizes.mediaPreviewMaxWidth,
        content: SizedBox(
          height: bodyHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final sideBySide = constraints.maxWidth >= 640;
              final left = _EditInfoPane(
                form: form,
                enabled: editing,
                statusBar: statusBar,
                preview: _CanvasOverview(
                  canvas: canvas,
                  canvasId: canvasId,
                  enabled: editing,
                  selectedAssetId: coverAssetId.value,
                  onSelected: (id) => coverAssetId.value = id,
                ),
              );
              final right = _EditConversationsPane(
                available: available,
                selected: selectedIds,
                enabled: editing,
                onChanged: (id, checked) {
                  chosen.value = toggleCanvasConversation(
                    chosen.value ?? selectedIds,
                    id,
                    checked,
                  );
                },
                onReplace: (next) => chosen.value = next,
                onRetry: () => retrySessions.value++,
              );

              if (!sideBySide) {
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      left,
                      const SizedBox(height: RevericSpacing.xl),
                      Divider(
                        height: RevericSizes.dividerThickness,
                        color: RevericTheme.colorsOf(context).borderSubtle,
                      ),
                      const SizedBox(height: RevericSpacing.xl),
                      SizedBox(height: 280, child: right),
                    ],
                  ),
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 348, child: left),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: RevericSpacing.x2l,
                    ),
                    child: VerticalDivider(
                      width: RevericSizes.dividerThickness,
                      thickness: RevericSizes.dividerThickness,
                      color: RevericTheme.colorsOf(context).borderSubtle,
                    ),
                  ),
                  Expanded(child: right),
                ],
              );
            },
          ),
        ),
        actions: [
          RevericButton.secondary(
            label: context.t(LocaleKeys.commonCancel),
            onPressed: loading ? null : () => Navigator.of(context).pop(),
          ),
          RevericButton.primary(
            label: context.t(
              canResume
                  ? LocaleKeys.commonRetry
                  : LocaleKeys.productionGalleryPublishNow,
            ),
            loading: loading,
            onPressed: editing && available.hasData ? () => run(publish) : null,
          ),
        ],
      ),
    );
  }
}

class _EditInfoPane extends StatelessWidget {
  const _EditInfoPane({
    required this.form,
    required this.enabled,
    required this.statusBar,
    required this.preview,
  });

  final FormFieldsController<_Field> form;
  final bool enabled;
  final Widget statusBar;
  final Widget preview;

  @override
  Widget build(BuildContext context) {
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        preview,
        const SizedBox(height: RevericSpacing.xl),
        AbsorbPointer(
          absorbing: !enabled,
          child: Opacity(
            opacity: enabled ? 1 : 0.65,
            child: HookedForm<_Field>(
              form: form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HookedTextFormField<_Field>(
                    fieldHook: _Field.title,
                    label: context.t(LocaleKeys.commonTitle),
                  ),
                  const SizedBox(height: RevericSpacing.lg),
                  HookedTextFormField<_Field>(
                    fieldHook: _Field.description,
                    label: context.t(LocaleKeys.commonSummary),
                    multiline: true,
                    minLines: 3,
                    maxLines: 5,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    final footer = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        statusBar,
        const SizedBox(height: RevericSpacing.lg),
        GalleryNoticeBanner(
          tone: GalleryNoticeTone.warning,
          message: context.t(LocaleKeys.productionGalleryConfirmation),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxHeight.isFinite) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [details, footer],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: SingleChildScrollView(child: details)),
            footer,
          ],
        );
      },
    );
  }
}

class _EditConversationsPane extends StatelessWidget {
  const _EditConversationsPane({
    required this.available,
    required this.selected,
    required this.enabled,
    required this.onChanged,
    required this.onReplace,
    required this.onRetry,
  });

  final AsyncSnapshot<List<ProductionCanvasPackageConversation>> available;
  final Set<String> selected;
  final bool enabled;
  final void Function(String id, bool checked) onChanged;
  final ValueChanged<Set<String>> onReplace;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (available.data case final data?) {
      return AbsorbPointer(
        absorbing: !enabled,
        child: Opacity(
          opacity: enabled ? 1 : 0.65,
          child: CanvasConversationSelection(
            sessions: data,
            selected: selected,
            scrollable: true,
            onChanged: onChanged,
            onReplace: onReplace,
          ),
        ),
      );
    }
    if (available.hasError) {
      return Center(
        child: GalleryNoticeBanner(
          message: context.t(LocaleKeys.productionGallerySessionsFailed),
          action: RevericButton.secondary(
            size: RevericButtonSize.compact,
            label: context.t(LocaleKeys.commonRetry),
            onPressed: onRetry,
          ),
        ),
      );
    }
    return const Center(
      child: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class _CanvasOverview extends HookWidget {
  const _CanvasOverview({
    required this.canvas,
    required this.canvasId,
    required this.enabled,
    required this.selectedAssetId,
    required this.onSelected,
  });

  final ProductionCanvasService canvas;
  final Future<String> canvasId;
  final bool enabled;
  final String? selectedAssetId;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final pending = useMemoized(() async {
      try {
        return await inspectProductionCanvasPublication(
          canvas: canvas,
          canvasId: await canvasId,
        );
      } catch (error, stackTrace) {
        _log.error(
          'Initial canvas thumbnail unavailable',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      }
    }, [canvasId]);
    final imagesRequest = useMemoized(() async {
      try {
        return await listProductionCanvasCoverImages(
          canvas: canvas,
          canvasId: await canvasId,
        );
      } catch (error, stackTrace) {
        _log.error(
          'Cover choices unavailable',
          error: error,
          stackTrace: stackTrace,
        );
        return const <({String id, String name, File file})>[];
      }
    }, [canvasId]);
    final snapshot = useFuture(pending).data;
    final images = useFuture(imagesRequest).data ?? const [];
    ({String id, String name, File file})? selected;
    for (final image in images) {
      if (image.id == selectedAssetId) {
        selected = image;
        break;
      }
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (selected != null)
                    Image.file(
                      selected.file,
                      fit: BoxFit.cover,
                      cacheWidth: 720,
                      errorBuilder: (_, _, _) =>
                          const HomeCanvasPlaceholder(iconSize: 28),
                    )
                  else if (snapshot != null)
                    Image.memory(
                      snapshot.preview.jpeg,
                      fit: BoxFit.cover,
                      cacheWidth: 720,
                    )
                  else
                    const HomeCanvasPlaceholder(iconSize: 28),
                  if (images.isNotEmpty)
                    Positioned(
                      right: RevericSpacing.sm,
                      bottom: RevericSpacing.sm,
                      child: RevericButton.secondary(
                        size: RevericButtonSize.compact,
                        label: context.t(LocaleKeys.librarySelectCover),
                        onPressed: enabled
                            ? () async {
                                final picked = await _pickCover(
                                  context,
                                  preview: snapshot?.preview.jpeg,
                                  images: images,
                                  selectedAssetId: selected?.id,
                                );
                                if (picked != null) {
                                  onSelected(picked.assetId);
                                }
                              }
                            : null,
                      ),
                    ),
                ],
              ),
            ),
            if (snapshot != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.md,
                  vertical: RevericSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border(top: BorderSide(color: colors.borderSubtle)),
                ),
                child: Text(
                  context.t(
                    LocaleKeys.productionGalleryPreviewEstimate,
                    namedArgs: {
                      'nodes': '${snapshot.nodeCount}',
                      'assets': '${snapshot.assetCount}',
                      'size': gallerySize(context, snapshot.sourceBytes),
                    },
                  ),
                  style: typo.uiTiny.copyWith(
                    color: colors.textMuted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CoverPick {
  const _CoverPick(this.assetId);

  final String? assetId;
}

Future<_CoverPick?> _pickCover(
  BuildContext context, {
  required Uint8List? preview,
  required List<({String id, String name, File file})> images,
  required String? selectedAssetId,
}) {
  return showRevericDialog<_CoverPick>(
    context: context,
    builder: (context) => RevericDialog(
      title: context.t(LocaleKeys.librarySelectCover),
      content: SizedBox(
        height: 320,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: RevericSpacing.sm,
            crossAxisSpacing: RevericSpacing.sm,
            childAspectRatio: 16 / 9,
          ),
          itemCount: images.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return _CoverTile(
                label: context.t(LocaleKeys.productionGalleryCoverCanvas),
                selected: selectedAssetId == null,
                onTap: () => Navigator.of(context).pop(const _CoverPick(null)),
                child: preview == null
                    ? const HomeCanvasPlaceholder(iconSize: 20)
                    : Image.memory(preview, fit: BoxFit.cover, cacheWidth: 360),
              );
            }
            final image = images[index - 1];
            return _CoverTile(
              label: image.name,
              selected: image.id == selectedAssetId,
              onTap: () => Navigator.of(context).pop(_CoverPick(image.id)),
              child: Image.file(
                image.file,
                fit: BoxFit.cover,
                cacheWidth: 360,
                errorBuilder: (_, _, _) =>
                    const HomeCanvasPlaceholder(iconSize: 20),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class _CoverTile extends StatelessWidget {
  const _CoverTile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Tooltip(
      message: label,
      child: Material(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? colors.accent : colors.borderSubtle,
                width: selected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(RevericRadius.large),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

Future<void> _replacePackageCover(
  ProductionCanvasService canvas,
  ProductionCanvasPackageFile package,
  String assetId,
) async {
  final asset = await canvas.library.database.assetDao.getAsset(assetId);
  final stored = asset?.path;
  if (asset?.type != 'image' || stored == null) {
    throw ProductionCanvasPackageException(
      'missing_media',
      subject: asset?.name,
    );
  }
  final source = File(canvas.library.resolve(asset!));
  if (!await source.exists() || await source.length() == 0) {
    throw ProductionCanvasPackageException(
      'missing_media',
      subject: asset.name,
    );
  }
  final cover = package.cover;
  if (cover == null) {
    throw const ProductionCanvasPackageException('cover_failed');
  }
  try {
    final jpeg = await encodeProductionGalleryCover(await source.readAsBytes());
    await cover.writeAsBytes(jpeg);
  } on StateError {
    throw const ProductionCanvasPackageException('cover_failed');
  }
}

bool _sameConversationIds(Set<String> left, Set<String> right) {
  return left.length == right.length && left.containsAll(right);
}
