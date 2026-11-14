// 职责: 生成地图 Orchestrator — 地图生成、全量地名坐标回读与校验
// 关联文件:
//   lib/shared/models/map_studio_models.dart
//   lib/shared/services/map_prompt_builder.dart
//   lib/shared/services/map_place_name_reader.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/ai-calling.md
//   .agents/rules/error-handling.md
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:easy_localization/easy_localization.dart';
import '../localization/locale_keys.dart';

import '../models/map_place_recognition.dart';
import '../models/image/choices.dart';

import '../database/novel_content_database.dart';
import '../logger/app_logger.dart';
import 'ai/image.dart';
import 'ai/tools.dart' show AiImageGenerationCallback, AiMultiImageEditCallback;
import 'maps_service.dart';
import 'map_place_name_reader.dart';
import 'map_prompt_builder.dart';
import '../models/map_studio_models.dart';

final _log = AppLogger.forModule('GenerateMapOrchestrator');

/// 生成阶段索引，与 UI 的步骤列表一一对应。
enum MapGenerationStage {
  read, // 读地点
  image, // 画地图
  locate, // 认出画面上的地名
  verify, // 核对
}

/// 一次生成的产物，停留在内存等待作者「采用」或「重画」。
class MapGenerationDraft {
  const MapGenerationDraft({
    required this.places,
    required this.prompt,
    required this.styleWord,
    required this.imageBytes,
    required this.imageMimeSubtype,
    required this.imageWidth,
    required this.imageHeight,
    required this.readResult,
    required this.imageCallsSpent,
    this.assetId,
    this.assetPath,
    this.recognition,
  });

  /// 待定位的全部地点候选，包含疆域与普通地点。
  final List<MapPlaceNameCandidate> places;
  final String prompt;
  final String? styleWord;
  final Uint8List imageBytes;
  final String imageMimeSubtype;
  final int imageWidth;
  final int imageHeight;

  final MapPlaceReadResult readResult;
  final int imageCallsSpent;
  final String? assetId;
  final String? assetPath;

  /// 仅模型成功返回时存在；失败和跳过不作为可复用结果。
  final MapPlaceRecognition? recognition;

  MapGenerationDraft copyWith({
    MapPlaceReadResult? readResult,
    String? assetId,
    String? assetPath,
    MapPlaceRecognition? recognition,
  }) {
    return MapGenerationDraft(
      places: places,
      prompt: prompt,
      styleWord: styleWord,
      imageBytes: imageBytes,
      imageMimeSubtype: imageMimeSubtype,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      readResult: readResult ?? this.readResult,
      imageCallsSpent: imageCallsSpent,
      assetId: assetId ?? this.assetId,
      assetPath: assetPath ?? this.assetPath,
      recognition: recognition ?? this.recognition,
    );
  }
}

/// 生成过程的进度回调。
typedef MapGenerationProgressListener =
    void Function(MapGenerationStage stage, String note);

/// 取消探针：每个阶段边界询问一次。
typedef MapGenerationCancelledProbe = bool Function();

/// 图片模型一返回就交付字节；调用方可在地名识别前先把昂贵产物写入图片资产。
typedef MapGenerationImageReady =
    Future<MapGenerationDraft> Function(MapGenerationDraft draft);

/// 生成请求参数。
class MapGenerationRequest {
  const MapGenerationRequest({
    required this.styleId,
    this.customStyleWord,
    required this.resolutionId,
    this.ratioId,
    this.complexity,
    this.customPrompt,
    required this.includeLocations,
    this.quality = mapDefaultQualityId,
    this.referenceCurrentImage = false,
    this.parentReferenceMapId,
  });

  final String? styleId;
  final String? customStyleWord;
  final String resolutionId;
  final String? ratioId;
  final String? complexity;

  /// 当前模型声明的质量值；空字符串表示未指定。
  final String quality;

  /// 制图师面板的可编辑地图内容。为空时由管线按疆域/地点清单自行拼装；
  /// 当前画风在调用图片模型前统一追加，不写回编辑框。
  final String? customPrompt;
  final bool includeLocations;

  /// 「参考当前地图重画」：把上一版画面作为参考图交给编辑模型。
  final bool referenceCurrentImage;

  /// 作为画风参考一并交给编辑模型的上层地图 id；null 表示不参考。
  final String? parentReferenceMapId;

  MapStyleOption? get style =>
      mapStyleOptions.where((option) => option.id == styleId).firstOrNull;

  String? get styleWord =>
      mapStyleWordOf(styleId: styleId, customStyleWord: customStyleWord);
}

/// 地图生成管线编排。短生命周期对象：参数注入数据库与 AI 依赖，一次生成一个实例。
class GenerateMapOrchestrator {
  GenerateMapOrchestrator({
    required this.database,
    this.imageChoices,
    required this.imageGenerateCallback,
    required this.imageEditCallback,
    required this.placeNameReader,
    required this.onProgress,
    required this.isCancelled,
    this.onImageReady,
  });

  final NovelContentDatabase database;
  final ImageModelChoices? imageChoices;

  /// null 表示 Reveric 图片模型不可用。首次画图走文生图。
  final AiImageGenerationCallback? imageGenerateCallback;

  /// null 表示 Reveric 图片模型不可用；仅参考上一版重画时走改图。
  final AiMultiImageEditCallback? imageEditCallback;

  /// null 表示地名回读模型未配置。
  final MapPlaceNameReader? placeNameReader;
  final MapGenerationProgressListener onProgress;
  final MapGenerationCancelledProbe isCancelled;
  final MapGenerationImageReady? onImageReady;

  Future<List<Location>> _locations() async {
    final service = LocationsService(database);
    return service.getLocations();
  }

  /// 跑完整管线。抛出 [MapGenerationException] 时 UI 展示失败原因。
  Future<MapGenerationDraft> generate({
    required String mapId,
    required MapGenerationRequest request,
    Uint8List? referenceImageBytes,
    Uint8List? parentReferenceBytes,
    String? parentReferenceName,
  }) async {
    // 1. 读地点。疆域与全量识别候选从地点树推导，不经过 LLM。
    onProgress(MapGenerationStage.read, '收集地点');
    final locations = await _locations();
    final map = await MapsService(database).getMapById(mapId);
    final (regions, allCandidates) = deriveMapRegionsAndPlaces(
      locations: locations,
      rootId: map?.locationId,
    );
    final regionIds = regions.map((region) => region.locationId).toSet();
    // 地点开关只影响普通地点；疆域地名始终参与生成和坐标识别。
    final places = request.includeLocations
        ? allCandidates
        : allCandidates
              .where((candidate) => regionIds.contains(candidate.locationId))
              .toList(growable: false);
    if (isCancelled()) throw const MapGenerationCancelledException();

    // 2. 地图。带了参考图（上一版 / 上层地图）时走改图，否则文生图。
    // 参考图顺序与 prompt 里的 image 编号一致：先上一版，再上层地图。
    final referenceCurrent =
        request.referenceCurrentImage && referenceImageBytes != null;
    final referenceParent = parentReferenceBytes != null;
    final referenceImages = [
      if (referenceCurrent) referenceImageBytes,
      if (referenceParent) parentReferenceBytes,
    ];
    final useEdit = referenceImages.isNotEmpty;
    if ((useEdit && imageEditCallback == null) ||
        (!useEdit && imageGenerateCallback == null)) {
      throw const MapGenerationException('图片模型不可用，请检查 AI 设置');
    }
    onProgress(
      MapGenerationStage.image,
      '生成 ${request.resolutionId} 地图，地名直接写进画面',
    );
    final userPrompt = request.customPrompt?.trim() ?? '';
    final basePrompt = userPrompt.isNotEmpty
        ? userPrompt
        : buildMapImagePrompt(
            regions: regions,
            places: places,
            referenceCurrentImage: referenceCurrent,
            mapType: map?.type ?? mapTypeWorld,
            parentReferenceName: referenceParent ? parentReferenceName : null,
          );
    final imagePrompt = buildMapSubmissionPrompt(
      prompt: basePrompt,
      styleWord: request.styleWord,
    );
    final choices = imageChoices;
    if (choices == null) {
      throw MapGenerationException(tr(LocaleKeys.aiImageParametersUnavailable));
    }
    final ratio = request.ratioId ?? choices.defaultRatio('16:9');
    final resolution = choices.resolution(request.resolutionId);
    final quality = request.quality.isEmpty
        ? choices.defaults.quality
        : request.quality;
    final complexity = request.complexity ?? choices.defaults.complexity;
    try {
      choices.validate(
        ratio: ratio,
        resolution: resolution,
        references: referenceImages.length,
        quality: quality,
        complexity: complexity,
      );
    } on FormatException {
      throw MapGenerationException(tr(LocaleKeys.aiImageParametersUnavailable));
    }
    final options = ImageInvocationOptions(
      aspectRatio: ratio,
      resolution: resolution,
      capabilities: choices.capabilities,
      defaults: choices.rawDefaults,
    );
    final size = choices.size(ratio, resolution);
    final imageResult = useEdit
        ? await imageEditCallback!(
            imagePrompt,
            imageData: [
              for (final bytes in referenceImages) base64Encode(bytes),
            ],
            size: size,
            quality: quality,
            complexity: complexity,
            options: options,
          )
        : await imageGenerateCallback!(
            imagePrompt,
            size: size,
            quality: quality,
            complexity: complexity,
            options: options,
          );
    final imageBytes = await _bytesOf(imageResult);
    final imageDims = await _decodeDimensions(imageBytes);

    var draft = MapGenerationDraft(
      places: places,
      prompt: imagePrompt,
      styleWord: request.styleWord,
      imageBytes: imageBytes,
      imageMimeSubtype: imageResult.mimeSubtype,
      imageWidth: imageDims.$1,
      imageHeight: imageDims.$2,
      readResult: const MapPlaceReadResult(matches: [], unresolved: []),
      imageCallsSpent: 1,
    );
    final imageReady = onImageReady;
    if (imageReady != null) {
      draft = await imageReady(draft);
    }
    if (isCancelled()) throw const MapGenerationCancelledException();

    // 3. 地名回读。
    draft = await _locatePlaces(draft: draft, locations: locations);

    // 4. 核对在 controller 层汇总；这里只报阶段完成。
    onProgress(MapGenerationStage.verify, '核对地点坐标');
    return draft;
  }

  /// 对历史图片核对当前地点树；输入一致时复用已保存的坐标。
  Future<MapGenerationDraft> locateExisting({
    required String mapId,
    required MapGenerationDraft draft,
    required bool includeLocations,
  }) async {
    final current = await prepareExisting(
      mapId: mapId,
      draft: draft,
      includeLocations: includeLocations,
    );
    return _locatePlaces(draft: current, locations: await _locations());
  }

  /// 预览只核对缓存，不发起 AI 调用；采用时再次核对，防止预览期间地点变化。
  Future<MapGenerationDraft> prepareExisting({
    required String mapId,
    required MapGenerationDraft draft,
    required bool includeLocations,
  }) async {
    final locations = await _locations();
    final map = await MapsService(database).getMapById(mapId);
    final (regions, allCandidates) = deriveMapRegionsAndPlaces(
      locations: locations,
      rootId: map?.locationId,
    );
    final regionIds = regions.map((region) => region.locationId).toSet();
    final places = includeLocations
        ? allCandidates
        : allCandidates
              .where((candidate) => regionIds.contains(candidate.locationId))
              .toList(growable: false);
    final recognition = draft.recognition;
    final reusable = recognition != null && recognition.matchesInput(places);
    return MapGenerationDraft(
      places: places,
      prompt: draft.prompt,
      styleWord: draft.styleWord,
      imageBytes: draft.imageBytes,
      imageMimeSubtype: draft.imageMimeSubtype,
      imageWidth: draft.imageWidth,
      imageHeight: draft.imageHeight,
      readResult: reusable
          ? recognition.result
          : const MapPlaceReadResult(matches: [], unresolved: []),
      recognition: reusable ? recognition : null,
      imageCallsSpent: draft.imageCallsSpent,
      assetId: draft.assetId,
      assetPath: draft.assetPath,
    );
  }

  Future<MapGenerationDraft> _locatePlaces({
    required MapGenerationDraft draft,
    required List<Location> locations,
  }) async {
    final reader = placeNameReader;
    final locationIds = locations.map((location) => location.id).toSet();
    final candidates = [
      for (final place in draft.places)
        if (locationIds.contains(place.locationId)) place,
    ];
    final recognition = draft.recognition;
    if (recognition != null && recognition.matchesInput(candidates)) {
      return draft.copyWith(readResult: recognition.result);
    }
    if (reader == null || !reader.isConfigured || candidates.isEmpty) {
      onProgress(
        MapGenerationStage.locate,
        reader == null ? '地名识别模型未配置，跳过定位' : '没有需要定位的地点',
      );
      return draft.copyWith(
        readResult: MapPlaceReadResult(
          matches: const [],
          unresolved: [for (final candidate in candidates) candidate.name],
        ),
      );
    }
    onProgress(MapGenerationStage.locate, '认出画面上的 ${candidates.length} 个地名');
    try {
      final result = await reader.readPlacePositions(
        imageBytes: draft.imageBytes,
        mimeSubtype: draft.imageMimeSubtype,
        imageWidth: draft.imageWidth,
        imageHeight: draft.imageHeight,
        candidates: candidates,
      );
      onProgress(
        MapGenerationStage.locate,
        '认出 ${result.matches.length}/${candidates.length} 个地点',
      );
      return draft.copyWith(
        readResult: result,
        recognition: MapPlaceRecognition(places: candidates, result: result),
      );
    } on MapVisionRequestException catch (error) {
      _log.warning('place name read-back failed: $error');
      onProgress(MapGenerationStage.locate, '地名识别失败：$error');
      return draft.copyWith(
        readResult: MapPlaceReadResult(
          matches: const [],
          unresolved: [for (final candidate in candidates) candidate.name],
        ),
      );
    }
  }

  Future<(int, int)> _decodeDimensions(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      final result = (frame.image.width, frame.image.height);
      frame.image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      return result;
    } catch (error, stackTrace) {
      _log.error(
        'failed to decode map image',
        error: error,
        stackTrace: stackTrace,
      );
      return (3072, 1728);
    }
  }

  Future<Uint8List> _bytesOf(AiImageGenerationResult result) async {
    if (result.localFilePath != null) {
      final file = File(result.localFilePath!);
      if (await file.exists()) {
        try {
          return await file.readAsBytes();
        } finally {
          await result.disposeTemporary();
        }
      }
    }
    final base64Data = result.imageBase64;
    if (base64Data != null && base64Data.isNotEmpty) {
      return base64Decode(base64Data);
    }
    throw const MapGenerationException('图像生成结果为空');
  }
}

class MapGenerationException implements Exception {
  const MapGenerationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class MapGenerationCancelledException implements Exception {
  const MapGenerationCancelledException();

  @override
  String toString() => '生成已停止';
}
