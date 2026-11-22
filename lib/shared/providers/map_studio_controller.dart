// 职责: 地图工作台状态控制 — 生成状态机、采用/重画与地点位置回写
// 关联文件:
//   lib/shared/services/generate_map_orchestrator.dart
//   lib/shared/providers/map_studio_providers.dart
//   lib/shared/providers/maps_providers.dart
//   lib/shared/models/map_agent.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/error-handling.md
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../database/app_database.dart';
import '../database/novel_content_database.dart';
import '../logger/app_logger.dart';
import '../localization/locale_keys.dart';
import '../models/map_agent.dart' show mapCustomStyleId;
import 'maps_providers.dart';
import 'novel_providers.dart';
import '../services/generate_map_orchestrator.dart';
import '../models/map_asset_metadata.dart';
import '../services/map_image_store.dart';
import '../services/map_prompt_builder.dart';
import '../models/map_studio_models.dart';
import 'map_studio_providers.dart';

part 'map_studio_controller.g.dart';

final _log = AppLogger.forModule('MapStudio');

/// 全局地图生成活动计数：>0 表示有地图正在生成。由 [MapStudioController] 在
/// 生成开始/结束时增减；工作区导航（novel_editor）切换页面/world 前读取它，
/// 拦截会销毁 autoDispose controller 的切换。用普通 ValueNotifier 而非
/// Provider：计数不能随 controller 被 dispose 而失效，否则释放时已无法读 ref。
final mapGenerationActivityCounter = ValueNotifier<int>(0);

enum MapStudioPhase {
  /// 正常浏览（含「这张地图还没画」的空态，由 settings 推导）。
  viewing,

  generating,

  /// 出图并完成地点识别，等待采用或重画。
  review,
}

class MapStudioState {
  const MapStudioState({
    this.phase = MapStudioPhase.viewing,
    this.stageIndex = 0,
    this.stageNote = '',
    this.imageCallsSpent = 0,
    this.totalImageCalls = 0,
    this.draft,
    this.errorMessage,
    this.requiresPlaceRecognition = false,
  });

  final MapStudioPhase phase;
  final int stageIndex;
  final String stageNote;
  final int imageCallsSpent;

  /// 本次生成计划发出的图片调用总数（固定一张地图）。
  final int totalImageCalls;

  final MapGenerationDraft? draft;
  final String? errorMessage;
  final bool requiresPlaceRecognition;

  bool get isBusy => phase == MapStudioPhase.generating;

  MapStudioState copyWith({
    MapStudioPhase? phase,
    int? stageIndex,
    String? stageNote,
    int? imageCallsSpent,
    int? totalImageCalls,
    MapGenerationDraft? draft,
    bool clearDraft = false,
    String? errorMessage,
    bool clearError = false,
    bool? requiresPlaceRecognition,
  }) {
    return MapStudioState(
      phase: phase ?? this.phase,
      stageIndex: stageIndex ?? this.stageIndex,
      stageNote: stageNote ?? this.stageNote,
      imageCallsSpent: imageCallsSpent ?? this.imageCallsSpent,
      totalImageCalls: totalImageCalls ?? this.totalImageCalls,
      draft: clearDraft ? null : (draft ?? this.draft),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      requiresPlaceRecognition:
          requiresPlaceRecognition ?? this.requiresPlaceRecognition,
    );
  }
}

@riverpod
class MapStudioController extends _$MapStudioController {
  bool _cancelled = false;

  /// 本实例是否已计入 [mapGenerationActivityCounter]；保证增减各至多一次。
  bool _generationCounted = false;

  /// 生成期间持有全局活动计数，工作区据此拦截会销毁本 controller 的切换。
  void _holdGenerationActivity() {
    if (_generationCounted) {
      return;
    }
    _generationCounted = true;
    mapGenerationActivityCounter.value++;
  }

  void _releaseGenerationActivity() {
    if (!_generationCounted) {
      return;
    }
    _generationCounted = false;
    mapGenerationActivityCounter.value--;
  }

  @override
  MapStudioState build(String databasePath, String mapId) {
    ref.onDispose(() => _cancelled = true);
    return const MapStudioState();
  }

  NovelContentDatabase get _database =>
      ref.watch(novelContentDatabaseProvider(databasePath));

  MapImageStore get _imageStore => MapImageStore();

  GenerateMapOrchestrator _orchestrator({
    MapGenerationImageReady? onImageReady,
  }) {
    final generate = ref.read(
      mapImageGenerateCallbackProvider(modelId: _generationOptionId),
    );
    final edit = ref.read(
      mapImageEditCallbackProvider(modelId: _generationOptionId),
    );
    final selectedModel = _generationModelId;
    return GenerateMapOrchestrator(
      database: _database,
      imageChoices: ref.read(mapImageChoicesProvider(_generationOptionId)),
      imageGenerateCallback: generate == null
          ? null
          : (prompt, {model, size, quality, complexity, options}) => generate(
              prompt,
              model: model ?? selectedModel,
              size: size,
              quality: quality,
              complexity: complexity,
              options: options,
            ),
      imageEditCallback: edit == null
          ? null
          : (
              prompt, {
              required imageData,
              model,
              size,
              quality,
              complexity,
              options,
            }) => edit(
              prompt,
              imageData: imageData,
              model: model ?? selectedModel,
              size: size,
              quality: quality,
              complexity: complexity,
              options: options,
            ),
      placeNameReader: ref.read(mapPlaceNameReaderProvider),
      onProgress: (stage, note) {
        state = state.copyWith(stageIndex: stage.index, stageNote: note);
      },
      isCancelled: () => _cancelled,
      onImageReady: onImageReady,
    );
  }

  /// 生成一张地图并自动采用；历史图片仍可预览后恢复。
  Future<void> generate(
    MapGenerationRequest request, {
    required String novelId,
    required String sourceMapName,
  }) async {
    if (state.isBusy) {
      return;
    }
    final selection = ref.read(
      mapDraftImageModelSelectionProvider(request.modelId),
    );
    if (selection == null) {
      state = state.copyWith(
        errorMessage: tr(LocaleKeys.aiModelUnavailableReselect),
      );
      return;
    }
    _generationOptionId =
        request.modelId ?? '${selection.config.id}::${selection.model}';
    _generationModelId = selection.model;
    final keepAlive = ref.keepAlive();
    _lastRequest = request;
    _lastNovelId = novelId;
    _lastSourceMapName = sourceMapName;
    _cancelled = false;
    _holdGenerationActivity();
    state = state.copyWith(
      phase: MapStudioPhase.generating,
      stageIndex: 0,
      stageNote: '',
      imageCallsSpent: 0,
      totalImageCalls: 1,
      clearDraft: true,
      clearError: true,
      requiresPlaceRecognition: false,
    );
    try {
      final map = await ref
          .read(mapsServiceProvider(databasePath))
          .getMapById(mapId);
      final locations = await ref
          .read(locationsServiceProvider(databasePath))
          .getLocations();
      if (map?.locationId == null ||
          !locations.any((location) => location.parentId == map!.locationId)) {
        throw MapGenerationException(
          tr(LocaleKeys.mapEditorStudioNeedsLocations),
        );
      }
      final referenceBytes = await _currentImageBytes();
      final parentReference = await _parentReference(
        request.parentReferenceMapId,
        locations,
      );
      String? persistenceError;
      final draft =
          await _orchestrator(
            onImageReady: (draft) async {
              try {
                return await _persistDraftAsset(
                  draft: draft,
                  request: request,
                  novelId: novelId,
                  sourceMapName: sourceMapName,
                );
              } catch (error, stackTrace) {
                _log.error(
                  '[DB] map asset persistence failed: '
                  'table=Assets mapId=$mapId',
                  error: error,
                  stackTrace: stackTrace,
                );
                persistenceError = tr(
                  LocaleKeys.mapEditorStudioAssetSaveFailed,
                );
                return draft;
              }
            },
          ).generate(
            mapId: mapId,
            request: request,
            referenceImageBytes: referenceBytes,
            parentReferenceBytes: parentReference?.bytes,
            parentReferenceName: parentReference?.name,
          );
      state = state.copyWith(
        phase: MapStudioPhase.review,
        draft: draft,
        imageCallsSpent: draft.imageCallsSpent,
        errorMessage: persistenceError,
        clearError: persistenceError == null,
      );
      await adopt();
    } on MapGenerationCancelledException {
      state = const MapStudioState(
        phase: MapStudioPhase.viewing,
        errorMessage: '已停止。已经画出来的那张仍会计费',
      );
    } on MapGenerationException catch (error) {
      state = state.copyWith(
        phase: MapStudioPhase.viewing,
        errorMessage: error.message,
      );
    } catch (error, stackTrace) {
      _log.error('map generation failed', error: error, stackTrace: stackTrace);
      state = state.copyWith(
        phase: MapStudioPhase.viewing,
        errorMessage: '生成失败：$error',
      );
    } finally {
      _releaseGenerationActivity();
      keepAlive.close();
    }
  }

  /// 采用当前草稿：落盘图像、更新 settings、回写地点位置。位置只增改，不删。
  Future<void> adopt() async {
    var draft = state.draft;
    if (draft == null || state.isBusy) {
      return;
    }
    final keepAlive = ref.keepAlive();
    _cancelled = false;
    _holdGenerationActivity();
    state = state.copyWith(phase: MapStudioPhase.generating, clearError: true);
    try {
      if (draft.imageCallsSpent == 0) {
        final saved = await ref
            .read(imageLibraryServiceProvider)
            .mapRecognition(draft.assetId!);
        draft = draft.copyWith(recognition: draft.recognition ?? saved);
        draft = await _orchestrator().locateExisting(
          mapId: mapId,
          draft: draft,
          includeLocations: true,
        );
      }
      if (draft.assetPath == null) {
        final request = _lastRequest;
        final novelId = _lastNovelId;
        final sourceMapName = _lastSourceMapName;
        if (request == null || novelId == null || sourceMapName == null) {
          throw StateError('Map asset context is unavailable');
        }
        draft = await _persistDraftAsset(
          draft: draft,
          request: request,
          novelId: novelId,
          sourceMapName: sourceMapName,
        );
      }
      final recognition = draft.recognition;
      if (recognition != null) {
        await ref
            .read(imageLibraryServiceProvider)
            .saveMapRecognition(draft.assetId!, recognition);
      }
      final mapsService = ref.read(mapsServiceProvider(databasePath));
      final current = await mapsService.getMapById(mapId);
      if (current == null) {
        throw StateError('Map no longer exists');
      }
      final settings = MapStudioSettings.fromMap(current.settings);
      final version = settings.version + 1;
      final imagePath = draft.assetPath!;
      final matchedIds = draft.readResult.matches
          .map((match) => match.locationId)
          .toSet();
      final unmatched = [
        for (final place in draft.places)
          if (!matchedIds.contains(place.locationId)) place.locationId,
      ];
      final model = _generationModelId;
      final newSettings = MapStudioSettings(
        version: version,
        image: imagePath,
        canvasWidth: draft.imageWidth,
        canvasHeight: draft.imageHeight,
        style: draft.styleWord,
        model: model,
        generatedAt: DateTime.now().toIso8601String(),
        unmatchedLocationIds: unmatched,
      );
      await mapsService.updateMap(
        id: mapId,
        width: draft.imageWidth.toDouble(),
        height: draft.imageHeight.toDouble(),
        settings: newSettings.toJson(),
      );
      await _writePlaceLocations(draft: draft);
      state = const MapStudioState(phase: MapStudioPhase.viewing);
    } catch (error, stackTrace) {
      _log.error(
        '[DB] map adopt failed: table=NovelMaps/MapLocations mapId=$mapId',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(
        phase: MapStudioPhase.review,
        draft: draft,
        errorMessage: '保存地图失败：$error',
      );
    } finally {
      _releaseGenerationActivity();
      keepAlive.close();
    }
  }

  Future<MapGenerationDraft> _persistDraftAsset({
    required MapGenerationDraft draft,
    required MapGenerationRequest request,
    required String novelId,
    required String sourceMapName,
  }) async {
    final model = _generationModelId;
    final customParameters = request.customImageParameters;
    final asset = await ref
        .read(imageLibraryServiceProvider)
        .importMapImage(
          draft.imageBytes,
          novelId: novelId,
          prompt: draft.prompt,
          model: model,
          mimeSubtype: draft.imageMimeSubtype,
          metadata: MapAssetMetadata(
            sourceMapName: sourceMapName,
            styleId: request.styleId,
            styleWord: draft.styleWord,
            resolutionId: customParameters == null
                ? request.resolutionId
                : null,
            qualityId: customParameters == null ? request.quality : null,
            customQuality: customParameters?.quality,
            customSize: customParameters?.size,
            includeLocations: request.includeLocations,
            referenceCurrentImage: request.referenceCurrentImage,
          ).toJson(),
        );
    return draft.copyWith(assetId: asset.id, assetPath: asset.path);
  }

  /// 预览历史地图并核对已保存的识别结果；需要重新识别时留到采用执行。
  Future<void> previewAsset(
    AssetRow asset, {
    required String novelId,
    required String sourceMapName,
  }) async {
    if (state.isBusy) return;
    try {
      final absolutePath = ref
          .read(imageLibraryServiceProvider)
          .resolve(asset.path);
      if (absolutePath == null) {
        throw StateError('Image asset path is unavailable');
      }
      final file = File(absolutePath);
      if (!await file.exists()) {
        throw StateError('Image asset file does not exist');
      }
      final bytes = await file.readAsBytes();
      final metadata = MapAssetMetadata.fromJson(asset.metadataJson);
      _generationModelId = asset.model;
      _lastNovelId = novelId;
      _lastSourceMapName = sourceMapName;
      _lastRequest ??= MapGenerationRequest(
        styleId: metadata.styleId,
        customStyleWord: metadata.styleId == mapCustomStyleId
            ? metadata.styleWord
            : null,
        resolutionId: mapDefaultResolutionId,
        customPrompt: asset.prompt,
        includeLocations: true,
      );
      var draft = MapGenerationDraft(
        recognition: await ref
            .read(imageLibraryServiceProvider)
            .mapRecognition(asset.id),
        places: const [],
        prompt: asset.prompt ?? '',
        styleWord: metadata.styleWord,
        imageBytes: bytes,
        imageMimeSubtype: asset.mimeType!.replaceFirst('image/', ''),
        imageWidth: asset.width ?? 3072,
        imageHeight: asset.height ?? 1728,
        readResult: const MapPlaceReadResult(matches: [], unresolved: []),
        imageCallsSpent: 0,
        assetId: asset.id,
        assetPath: asset.path,
      );
      draft = await _orchestrator().prepareExisting(
        mapId: mapId,
        draft: draft,
        includeLocations: true,
      );
      state = state.copyWith(
        phase: MapStudioPhase.review,
        draft: draft,
        imageCallsSpent: 0,
        totalImageCalls: 0,
        requiresPlaceRecognition: draft.recognition == null,
        clearError: true,
      );
    } catch (error, stackTrace) {
      _log.error(
        'map asset preview failed: assetId=${asset.id}',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(
        errorMessage: tr(LocaleKeys.mapEditorStudioHistoryReadFailed),
      );
    }
  }

  /// 回写地点位置：匹配到的地点建/改 MapLocations 行，坐标换算到画布像素。
  Future<void> _writePlaceLocations({required MapGenerationDraft draft}) async {
    final service = ref.read(mapLocationsServiceProvider(databasePath));
    final existing = await service.getMapLocations(mapId);
    final rowByLocationId = <String, MapLocation>{
      for (final row in existing) row.locationId: row,
    };
    for (final match in draft.readResult.matches) {
      final x = match.x * draft.imageWidth;
      final y = match.y * draft.imageHeight;
      final row = rowByLocationId[match.locationId];
      try {
        if (row == null) {
          await service.addLocationToMap(
            mapId: mapId,
            locationId: match.locationId,
            x: x,
            y: y,
          );
        } else {
          await service.updateMapLocation(id: row.id, x: x, y: y);
        }
      } catch (error, stackTrace) {
        _log.error(
          '[DB] map location write failed: table=MapLocations '
          'locationId=${match.locationId}',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    }
  }

  /// 读取当前地图字节（供「参考上一版重画」使用）。
  Future<Uint8List?> _currentImageBytes() async {
    final mapsService = ref.read(mapsServiceProvider(databasePath));
    final current = await mapsService.getMapById(mapId);
    if (current == null) return null;
    final settings = MapStudioSettings.fromMap(current.settings);
    if (!settings.hasImage) return null;
    return _imageStore.read(settings.image!);
  }

  /// 读取作为画风参考的上层地图；名字取它所属地点的当前名称。
  Future<({Uint8List bytes, String name})?> _parentReference(
    String? parentMapId,
    List<Location> locations,
  ) async {
    if (parentMapId == null) return null;
    final parent = await ref
        .read(mapsServiceProvider(databasePath))
        .getMapById(parentMapId);
    if (parent == null) return null;
    final settings = MapStudioSettings.fromMap(parent.settings);
    if (!settings.hasImage) return null;
    final bytes = await _imageStore.read(settings.image!);
    if (bytes == null) return null;
    final name =
        locations
            .where((location) => location.id == parent.locationId)
            .firstOrNull
            ?.name ??
        parent.name;
    return (bytes: bytes, name: name);
  }

  /// 清除一次性错误提示。
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  String? _generationOptionId;
  String? _generationModelId;
  MapGenerationRequest? _lastRequest;
  String? _lastNovelId;
  String? _lastSourceMapName;

  /// 用上一次的参数重画一张。
  Future<void> regenerate() async {
    final request = _lastRequest;
    final novelId = _lastNovelId;
    final sourceMapName = _lastSourceMapName;
    if (request == null || novelId == null || sourceMapName == null) return;
    await generate(request, novelId: novelId, sourceMapName: sourceMapName);
  }
}
