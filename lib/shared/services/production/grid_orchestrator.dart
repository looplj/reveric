// 职责: 编排宫格裁切、高清任务和本地拼接，登记资产并事务维护分组与来源连线。
// 关联文件:
//   lib/shared/services/production/grid_split.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/desktop/features/production/grid/split_bar.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/file-access.md
import 'dart:io';
import 'dart:async';
import 'dart:ui';
import 'package:drift/drift.dart' show Value;
import '../../database/novel_content_database.dart';
import '../../models/asset_purpose.dart';
import '../../models/ai_provider.dart';
import '../../models/production/image_request.dart';
import '../../models/production/view_presets.dart';
import '../../logger/app_logger.dart';
import '../../utils/short_entity_id.dart';
import '../storyboard/service.dart';
import 'image_service.dart';
import 'image_generate_orchestrator.dart';
import 'view_derive_orchestrator.dart';
import '../../models/video/request.dart';
import 'canvas_service.dart';
import 'canvas_history.dart';
import 'ffmpeg_runner.dart';
import 'grid_split.dart';
import 'grid_stitch.dart';
import 'node_source.dart';
import 'derived_placement.dart';
import '../../models/production/media.dart';
import '../../database/app_database.dart' show AssetRow;

final _log = AppLogger.forModule('Grid');

/// 支持的倍率必须同时满足分辨率与单张参考图能力，不能静默降级。
Set<int> gridUpscaleMultipliers(ProductionImageCapabilities capabilities) => {
  for (final factor in [2, 4])
    if (capabilities.resolutions.contains('${factor}K') &&
        capabilities.ratios.any((ratio) {
          try {
            capabilities.validate(
              prompt: 'upscale',
              ratio: ratio,
              resolution: '${factor}K',
              references: 1,
            );
            return true;
          } on FormatException {
            return false;
          }
        }))
      factor,
};

enum GridUpscaleStage { preparation, submission }

class GridUpscaleFailure {
  const GridUpscaleFailure({
    required this.title,
    required this.stage,
    required this.recorded,
    this.errorCode,
    this.message,
    this.taskId,
  });
  final String title;
  final GridUpscaleStage stage;
  final bool recorded;
  final String? errorCode, message, taskId;
}

class GridUpscaleResult {
  const GridUpscaleResult(this.group, this.failures, [this.results = const {}]);
  final CanvasNode group;
  final Map<String, GridUpscaleFailure> failures;
  final Map<String, Map<String, dynamic>> results;
}

typedef _GridSeed = ({ProductionImagePreview preview, String title});

class GridOrchestrator {
  Future<CanvasNode> split({
    required ProductionCanvasService canvas,
    required String sourceNodeId,
    required int rows,
    required int cols,
    Set<int> selected = const {},
    ProductionNodePlacement Function(Size size)? place,
    ProductionNodeSource? inputSource,
    MediaCancellation? cancellation,
    void Function(int cell, AssetRow asset)? onImported,
    void Function(CanvasNode group, Map<int, String> members)? onCreated,
    CanvasHistory? history,
  }) => _create(
    canvas: canvas,
    sourceNodeId: sourceNodeId,
    rows: rows,
    cols: cols,
    selected: selected,
    place: place,
    inputSource: inputSource,
    cancellation: cancellation,
    onImported: onImported,
    onCreated: onCreated,
    history: history,
  );

  Future<GridUpscaleResult> upscale({
    required ProductionCanvasService canvas,
    required ImageTaskService jobs,
    required String sourceNodeId,
    required int rows,
    required int cols,
    required Set<int> selected,
    required AiModelOption model,
    required int multiplier,
    Future<Map<String, dynamic>> Function(
      ProductionImagePreview preview,
      String nodeId,
    )?
    generate,
    ProductionNodePlacement Function(Size size)? place,
    ProductionNodeSource? inputSource,
    MediaCancellation? cancellation,
    void Function(int cell, AssetRow asset)? onImported,
    void Function(CanvasNode group, Map<int, String> members)? onCreated,
  }) async {
    final provider = await canvas.library.database.aiProviderDao.getById(
      model.providerId,
    );
    if (selected.isEmpty ||
        provider == null ||
        model.kind != AiModelKind.image) {
      throw const StoryboardException('invalid_config');
    }
    final capabilities = ProductionImageCapabilities(provider, model.model);
    if (!gridUpscaleMultipliers(capabilities).contains(multiplier)) {
      throw const StoryboardException('invalid_config');
    }
    final seeds = <String, _GridSeed>{};
    final group = await _create(
      canvas: canvas,
      sourceNodeId: sourceNodeId,
      rows: rows,
      cols: cols,
      selected: selected,
      place: place,
      upscale: (capabilities: capabilities, multiplier: multiplier),
      seeds: seeds,
      inputSource: inputSource,
      cancellation: cancellation,
      onImported: onImported,
      onCreated: onCreated,
    );
    final results = <String, Map<String, dynamic>>{};
    final failures = <String, GridUpscaleFailure>{};
    for (final entry in seeds.entries) {
      final taskId = buildShortEntityId(ShortEntityIdType.generationTask);
      final preview = entry.value.preview;
      var stage = GridUpscaleStage.preparation;
      String? preparedTaskId;
      try {
        if (cancellation?.cancelled == true) {
          throw const MediaException(MediaFailure.cancelled);
        }
        stage = GridUpscaleStage.submission;
        if (generate != null) {
          results[entry.key] = await generate(preview, entry.key);
          continue;
        }
        final prepared = Completer<void>();
        final job = jobs.submit(
          novelId: preview.novelId,
          sourceType: preview.sourceType,
          sourceId: preview.sourceId,
          request: preview.request,
          taskId: taskId,
          onPrepared: (id) async {
            preparedTaskId = id;
            if (cancellation?.cancelled == true) {
              await jobs.cancel(id);
              throw const MediaException(MediaFailure.cancelled);
            }
            prepared.complete();
          },
        );
        // 后台失败由本次已建行的任务处理；建行前失败交由下面的独立边界处理。
        final observed = job.then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            if (!prepared.isCompleted) {
              Error.throwWithStackTrace(error, stack);
            }
          },
        );
        await Future.any([prepared.future, observed]);
        results[entry.key] = {'ok': true, 'submitted': true, 'task_id': taskId};
      } catch (error, stack) {
        _log.error(
          'image preparation/submission failed node=${entry.key}',
          error: error,
          stackTrace: stack,
        );
        var recorded = false;
        try {
          if (generate == null && cancellation?.cancelled != true) {
            await jobs.recordSubmissionFailure(
              preview,
              provider.type,
              error,
              stack,
              taskId: taskId,
            );
            recorded = true;
          }
        } catch (recordError, recordStack) {
          _log.error(
            'failed to record rejected task node=${entry.key}',
            error: recordError,
            stackTrace: recordStack,
          );
        }
        failures[entry.key] = GridUpscaleFailure(
          title: entry.value.title,
          stage: stage,
          recorded: recorded,
          errorCode: error is MediaException
              ? error.reason.name
              : error is StoryboardException
              ? error.code
              : 'internal',
          message: error is StoryboardException
              ? 'StoryboardException(${error.code})'
              : error.toString(),
          taskId: preparedTaskId ?? (recorded ? taskId : null),
        );
      }
    }
    return GridUpscaleResult(
      group,
      Map.unmodifiable(failures),
      Map.unmodifiable(results),
    );
  }

  Future<CanvasNode> stitch({
    required ProductionCanvasService canvas,
    required String groupId,
    required String title,
    required int background,
    required int foreground,
    required ProductionNodePlacement Function(Size) place,
  }) async {
    final group = await canvas.groups.requireGroup(groupId);
    final layout = ProductionGroupLayout.fromStyle(group.style);
    if (layout is! StoryboardGroupLayout) {
      throw const StoryboardException('invalid_config');
    }
    final files = <int, String>{};
    for (final member in await canvas.groups.members(groupId)) {
      final asset = await canvas.inputAsset(
        ProductionInput.node(member.id, VideoInputRole.reference_image),
      );
      files[member.sortOrder] = canvas.library.resolve(asset);
    }
    final temporary = await Directory.systemTemp.createTemp(
      'reveric_grid_stitch_',
    );
    try {
      final file = File('${temporary.path}/stitch.png');
      await stitchProductionGrid(
        layout: layout,
        files: files,
        outputPath: file.path,
        background: background,
        foreground: foreground,
      );
      final asset = await canvas.library.importFile(
        file,
        name: '$title.png',
        novelId: canvas.novelId,
        purpose: AssetPurpose.production_output,
        cancellation: MediaCancellation(),
        source: 'grid_stitch',
      );
      final size = storyboardStitchSize(layout);
      return await canvas.addDerivedOutput(
        groupId,
        asset.id,
        title: title,
        placement: place(productionCardSize(size.width / size.height)),
      );
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<CanvasNode> _create({
    required ProductionCanvasService canvas,
    required String sourceNodeId,
    required int rows,
    required int cols,
    Set<int> selected = const {},
    ProductionNodePlacement Function(Size size)? place,
    ProductionNodeSource? inputSource,
    MediaCancellation? cancellation,
    void Function(int cell, AssetRow asset)? onImported,
    void Function(CanvasNode group, Map<int, String> members)? onCreated,
    ({ProductionImageCapabilities capabilities, int multiplier})? upscale,
    Map<String, _GridSeed>? seeds,
    CanvasHistory? history,
  }) async {
    final token = cancellation ?? MediaCancellation();
    if (token.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    final source = inputSource?.node ?? await canvas.requireNode(sourceNodeId);
    final input =
        inputSource?.asset ??
        await canvas.inputAsset(
          ProductionInput.node(sourceNodeId, VideoInputRole.reference_image),
        );
    final temporary = await Directory.systemTemp.createTemp(
      'reveric_grid_split_',
    );
    try {
      final crops = await splitProductionGrid(
        sourcePath: inputSource?.path ?? canvas.library.resolve(input),
        directory: temporary.path,
        rows: rows,
        cols: cols,
        selected: selected,
        cancellation: token,
      );
      final assets = <String>[];
      for (final crop in crops) {
        if (token.cancelled) {
          throw const MediaException(MediaFailure.cancelled);
        }
        final asset = await canvas.library.importFile(
          File(crop.path),
          name: '${source.title} ${crop.row + 1}-${crop.col + 1}.png',
          novelId: canvas.novelId,
          purpose: AssetPurpose.production_output,
          cancellation: token,
          source: 'grid_split',
        );
        assets.add(asset.id);
        onImported?.call(crop.index, asset);
      }
      final ratio = productionNearestRatio(
        crops.first.width / crops.first.height,
      );
      final layout = selected.isEmpty
          ? StoryboardGroupLayout(rows: rows, cols: cols, ratio: ratio)
          : StoryboardGroupLayout.fitting(crops.length, ratio: ratio);
      final placement =
          place?.call(layout.frameSize) ??
          await defaultProductionDerivedPlacement(
            canvas,
            sourceNodeId,
            layout.frameSize,
          );
      final memberMap = <int, String>{};
      final group = await withCanvasHistory(
        history,
        canvas.shots,
        'splitGroup',
        placement.moves.keys,
        () => canvas.write(sourceNodeId, () async {
          await canvas.moveNodes(source.canvasId, placement.moves);
          final members = <String>[];
          for (final (index, asset) in assets.indexed) {
            if (token.cancelled) {
              throw const MediaException(MediaFailure.cancelled);
            }
            final crop = crops[index];
            final CanvasNode member;
            if (upscale == null) {
              member = await canvas.addMedia(source.canvasId, asset);
            } else {
              final config = upscale;
              final ratio = nearestImageRatio(
                crop.width,
                crop.height,
                config.capabilities.ratios,
              );
              final input = ProductionInput.asset(
                asset,
                VideoInputRole.reference_image,
              );
              const preset = ImageGenerationPreset(
                method: ImageGenerationMethod.upscale,
              );
              config.capabilities.validate(
                prompt: preset.assemble('', input.id),
                ratio: ratio,
                resolution: '${config.multiplier}K',
                references: 1,
              );
              member = await canvas.addImage(source.canvasId);
              final clip = (await canvas.shots.getShot(member.clipId!))!;
              await canvas.shots.apply(clip.id, {
                ...canvas.shots.snapshot(clip),
                'title': '${source.title} ${crop.row + 1}-${crop.col + 1}',
                'prompt': '',
                'provider_id': config.capabilities.provider.id,
                'model_id': config.capabilities.model,
                'ratio': ratio,
                'resolution': '${config.multiplier}K',
              });
              await canvas.shots.restoreInputs(clip.id, [input.toJson()]);
              await canvas.db.canvasDao.updateActiveNodeFields(
                member.id,
                CanvasNodesCompanion(
                  style: Value({
                    ...?member.style,
                    'imageGeneration': preset.toJson(),
                  }),
                ),
              );
            }
            await canvas.db.canvasDao.updateActiveNodeFields(
              member.id,
              CanvasNodesCompanion(
                title: Value('${source.title} ${crop.row + 1}-${crop.col + 1}'),
              ),
            );
            if (seeds != null) {
              // 建组时组装本次执行的各格请求；后续编辑不改写请求，也不再逐格比较旧快照。
              // 保留请求内容，供提交失败时记录该格的失败历史。
              seeds[member.id] = (
                preview: await ProductionImageGenerateOrchestrator().preview(
                  canvas,
                  member.id,
                ),
                title: '${source.title} ${crop.row + 1}-${crop.col + 1}',
              );
            }
            members.add(member.id);
            memberMap[crop.index] = member.id;
          }
          return canvas.createStoryboardGroup(
            source.canvasId,
            layout: layout,
            origin: Offset(placement.at.x, placement.at.y),
            memberIds: members,
            sourceNodeId: sourceNodeId,
          );
        }),
      );
      onCreated?.call(group, Map.unmodifiable(memberMap));
      return group;
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}
