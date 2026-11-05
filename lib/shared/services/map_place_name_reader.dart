// 职责: 地名回读 — 用用户配置的多模态模型从成图里找地名文字框中心，换算成地点归一化位置
// 关联文件:
//   lib/shared/models/map_studio_models.dart
//   lib/shared/providers/map_studio_providers.dart
//   lib/shared/services/generate_map_orchestrator.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/services/ai/image_reference_compression.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/ai-calling.md
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/ai_chat_models.dart';
import 'ai/chat.dart';
import 'package:flutter/foundation.dart' show compute;

import '../logger/app_logger.dart';
import '../models/ai_provider.dart';
import 'ai/image_reference_compression.dart';
import '../models/map_studio_models.dart';

final _log = AppLogger.forModule('MapPlaceNameReader');

/// base64 会额外膨胀约 1/3；控制在 1 MiB，为 JSON prompt 和 4 MiB 网关限制留余量。
const mapVisionMaxImageBytes = 1024 * 1024;

/// 地名回读服务。
///
/// 使用用户默认聊天模型识别文字位置，并按地名匹配候选地点。
class MapPlaceNameReader {
  MapPlaceNameReader({
    required this._config,
    required this._model,
    this._httpClient,
  });

  final AiProvider _config;
  final String _model;
  final http.Client? _httpClient;

  bool get isConfigured =>
      _config.isValid && _model.isNotEmpty && _baseUrl.isNotEmpty;

  String get _baseUrl {
    var url = _config.effectiveBaseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// 对一张成图做地名回读。
  ///
  /// [imageBytes] 为成图字节；坐标以 [imageWidth] × [imageHeight] 像素为基准
  /// 归一化到 0~1。识别不出或匹配不上的候选出现在结果 [MapPlaceReadResult.unresolved]。
  Future<MapPlaceReadResult> readPlacePositions({
    required Uint8List imageBytes,
    required String mimeSubtype,
    required int imageWidth,
    required int imageHeight,
    required List<MapPlaceNameCandidate> candidates,
  }) async {
    if (!isConfigured) {
      throw const MapVisionNotConfiguredException();
    }
    if (candidates.isEmpty || imageWidth <= 0 || imageHeight <= 0) {
      return const MapPlaceReadResult(matches: [], unresolved: []);
    }

    final prepared = await compute(
      compressImageReference,
      ImageReferenceCompressionRequest(
        bytes: imageBytes,
        extension: mimeSubtype.isEmpty ? 'png' : mimeSubtype,
        hardMaxBytes: mapVisionMaxImageBytes,
      ),
    );
    _log.info('map vision ${prepared.logLine}');
    if (prepared.decodeFailed) {
      throw const MapVisionRequestException('地图图片无法读取，不能识别地名');
    }
    final preparedMime = prepared.extension == 'jpg'
        ? 'jpeg'
        : prepared.extension;
    final dataUrl =
        'data:image/$preparedMime;base64,${base64Encode(prepared.bytes)}';
    final client = AiClient(
      _config.copyWith(temperature: 0),
      chatModel: _model,
      httpClient: _httpClient,
    );
    final String content;
    try {
      content = await client.chatCompletionDetached([
        AiMessage(
          id: 'map-vision-system',
          role: AiMessageRole.system,
          content: _systemPrompt(),
          timestamp: DateTime.now(),
        ),
        AiMessage.user(
          id: 'map-vision-user',
          content: _userPrompt(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            names: candidates.map((candidate) => candidate.name).toList(),
          ),
          blocks: [
            AiImageBlock(
              id: 'map-vision-image',
              prompt: '',
              imageUrl: dataUrl,
              status: AiImageStatus.success,
            ),
          ],
        ),
      ], timeout: const Duration(minutes: 3));
    } catch (error, stackTrace) {
      _log.error(
        'map vision request failed: provider=${_config.id} model=$_model',
        error: error,
        stackTrace: stackTrace,
      );
      throw const MapVisionRequestException('地名识别请求失败，请检查模型配置后重试');
    } finally {
      client.dispose();
    }

    return parseResponse(content, candidates);
  }

  /// 解析模型返回的 JSON 文本并与候选地名匹配（静态以便测试）。
  static MapPlaceReadResult parseResponse(
    String content,
    List<MapPlaceNameCandidate> candidates,
  ) {
    var text = content.trim();
    if (text.startsWith('```')) {
      text = text.replaceFirst(RegExp(r'^```[a-zA-Z]*\n?'), '');
      final end = text.lastIndexOf('```');
      if (end >= 0) text = text.substring(0, end);
      text = text.trim();
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw MapVisionRequestException('地名识别返回格式无法解析');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } on FormatException {
      throw MapVisionRequestException('地名识别返回不是合法 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw MapVisionRequestException('地名识别返回结构不正确');
    }

    final rawMatches = decoded['matches'];
    final detected = <(String, double, double)>[];
    if (rawMatches is List) {
      for (final item in rawMatches) {
        if (item is! Map<String, dynamic>) continue;
        final name = item['name'];
        final x = item['x'];
        final y = item['y'];
        if (name is! String || x is! num || y is! num) continue;
        detected.add((
          name,
          x.toDouble().clamp(0, 1),
          y.toDouble().clamp(0, 1),
        ));
      }
    }

    final matches = <MapPlaceMatch>[];
    final unresolved = <String>[];
    final consumed = <int>{};
    for (final candidate in candidates) {
      var bestIndex = -1;
      var bestDistance = 2;
      for (var i = 0; i < detected.length; i++) {
        if (consumed.contains(i)) continue;
        final distance = mapNameEditDistance(candidate.name, detected[i].$1);
        if (distance < bestDistance) {
          bestDistance = distance;
          bestIndex = i;
        }
      }
      // 精确或错一字以内算命中，其余老实标记为这张图上没有。
      if (bestIndex >= 0 && bestDistance <= 1) {
        consumed.add(bestIndex);
        final detectedName = detected[bestIndex].$1;
        matches.add(
          MapPlaceMatch(
            locationId: candidate.locationId,
            requestedName: candidate.name,
            matchedName: detectedName,
            x: detected[bestIndex].$2,
            y: detected[bestIndex].$3,
          ),
        );
      } else {
        unresolved.add(candidate.name);
      }
    }
    return MapPlaceReadResult(matches: matches, unresolved: unresolved);
  }

  String _systemPrompt() =>
      '你是地图地名识别助手。给定一张手绘风格地图图片和一份地名清单，'
      '你在图中逐个找出清单上的地名文字，返回每个地名文字框中心的坐标。'
      '只输出 JSON，不要输出任何解释。';

  String _userPrompt({
    required int imageWidth,
    required int imageHeight,
    required List<String> names,
  }) =>
      '地图图片尺寸为 $imageWidth × $imageHeight 像素。'
      '请在图中找出下列地名的文字（中文，横排或竖排）：\n'
      '${names.map((name) => '- $name').join('\n')}\n\n'
      '对每个找到的地名，给出它文字框中心的像素坐标 (x, y)，'
      '再除以图宽高换算成 0 到 1 的归一化坐标填入 x、y 字段。'
      '图中没有出现的地名不要编造，把名字放进 unmatched 数组。\n'
      '输出格式：{"matches":[{"name":"地名","x":0.48,"y":0.38}],'
      '"unmatched":["没找到的地名"]}';
}

class MapVisionNotConfiguredException implements Exception {
  const MapVisionNotConfiguredException();

  @override
  String toString() => '地名识别模型不可用，请配置支持图片输入的聊天模型';
}

class MapVisionRequestException implements Exception {
  const MapVisionRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}
