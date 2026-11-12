// 职责: 按渠道编码 Midjourney 请求，查询异步任务并完整取回四张候选图。
// 关联文件:
//   lib/shared/services/ai/image.dart
//   lib/shared/services/ai/image/client.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import '../../../localization/locale_keys.dart';
import '../../../models/image/channels.dart';
import '../../../models/ai_provider.dart';
import '../../../logger/app_logger.dart';
import '../image.dart';
import 'client.dart';

final _log = AppLogger.forModule('MidjourneyImage');

class MidjourneyImageClient extends ImageClient {
  MidjourneyImageClient(super.config, this.protocol);
  final MidjourneyProtocol protocol;
  @override
  bool get supportsEdit => false;

  Uri _uri(String path) {
    final base = Uri.parse(config.effectiveBaseUrl);
    return base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/v1/?$'), '')}/$path',
    );
  }

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    final channel = validatedChannel(request)!;
    if (request.images.isNotEmpty ||
        request.prompt.trim().isEmpty ||
        (request.aspectRatio != null &&
            !channel.capabilities.ratios.contains(request.aspectRatio)) ||
        (request.resolution != null &&
            !channel.capabilities.resolutions.contains(request.resolution))) {
      throw invalidImageParameter();
    }
    final body = midjourneyBody(request, protocol);
    if (protocol == MidjourneyProtocol.images) {
      final response = await _send(_uri('v1/images/generations'), body);
      return _imagesResponse(response, request.onOutputs);
    }
    final response = await _send(
      _uri(
        protocol == MidjourneyProtocol.proxy
            ? 'mj/submit/imagine'
            : 'api/v1/model/generateImage',
      ),
      body,
    );
    final String? id;
    if (protocol == MidjourneyProtocol.proxy) {
      if (!{1, 21, 22}.contains(response['code'])) {
        throw _failure(response);
      }
      id = response['result'] as String?;
    } else {
      id = response['id'] as String?;
    }
    if (id == null || id.isEmpty) {
      throw _failure(response);
    }
    try {
      await request.onSubmitted?.call(id);
    } catch (error) {
      throw AiImageFetchException(
        tr(LocaleKeys.aiImageCandidatesFetchFailed),
        providerTaskId: id,
        debugMessage: '$error',
      );
    }
    return _settle(id, request.onOutputs);
  }

  @override
  Future<AiImageGenerationResult> resumeResult(String providerTaskId) =>
      _settle(providerTaskId, null);

  Future<AiImageGenerationResult> _settle(
    String id,
    ImageOutputsReceived? onOutputs,
  ) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      Map<String, dynamic> response;
      try {
        if (elapsed.elapsed >= imageHttpDataTimeout) {
          throw TimeoutException('Midjourney task timed out');
        }
        response = await _send(
          _uri(
            protocol == MidjourneyProtocol.proxy
                ? 'mj/task/${Uri.encodeComponent(id)}/fetch'
                : 'api/v1/model/prediction/${Uri.encodeComponent(id)}',
          ),
        );
      } catch (error) {
        throw AiImageFetchException(
          tr(LocaleKeys.aiImageCandidatesFetchFailed),
          providerTaskId: id,
          debugMessage: '$error',
        );
      }
      final status = response['status'];
      if (status == 'SUCCESS' ||
          status == 'completed' ||
          status == 'succeeded') {
        try {
          if (protocol == MidjourneyProtocol.proxy) {
            return await _grid(response['imageUrl'] as String);
          }
          return await _download(
            (response['outputs'] as List).cast<String>(),
            onOutputs,
          );
        } catch (error) {
          throw AiImageFetchException(
            tr(LocaleKeys.aiImageCandidatesFetchFailed),
            providerTaskId: id,
            debugMessage: '$error',
          );
        }
      }
      if (!{
        'NOT_START',
        'SUBMITTED',
        'IN_PROGRESS',
        'MODAL',
        'created',
        'starting',
        'queued',
        'pending',
        'processing',
        'running',
      }.contains(status)) {
        throw _failure(response);
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  /// Images 协议允许 URL 或 b64_json；逐项错误先交给共用解析器解释。
  Future<AiImageGenerationResult> _imagesResponse(
    Map<String, dynamic> response,
    ImageOutputsReceived? onOutputs,
  ) async {
    AiImageGenerationException malformed(String reason) =>
        AiImageGenerationException(
          tr(LocaleKeys.aiImageGenerationFailed),
          debugMessage: 'Invalid Midjourney images response: $reason',
        );
    final data = response['data'];
    if (data is! List || data.isEmpty) {
      throw malformed('data must be a nonempty array');
    }
    final items = <Map<String, dynamic>>[];
    for (var index = 0; index < data.length; index++) {
      final item = data[index];
      if (item is! Map<String, dynamic>) {
        throw malformed('data[$index] must be an object');
      }
      if (item['error'] != null) {
        await parseImageResponse({
          'data': [item],
        }, emptyMessage: tr(LocaleKeys.aiImageGenerationFailed));
      }
      final url = item['url'];
      final b64 = item['b64_json'];
      if ((url != null && url is! String) ||
          (b64 != null && b64 is! String) ||
          (!(url is String && url.isNotEmpty) &&
              !(b64 is String && b64.isNotEmpty))) {
        throw malformed('data[$index] requires a nonempty url or b64_json');
      }
      items.add(item);
    }
    if (items.length != 4) {
      throw malformed('expected four candidates, received ${items.length}');
    }
    if (items.every(
      (item) => (item['b64_json'] as String?)?.isNotEmpty != true,
    )) {
      return _download(
        items.map((item) => item['url'] as String).toList(),
        onOutputs,
      );
    }
    final results = <AiImageGenerationResult>[];
    try {
      for (final item in items) {
        results.add(
          await parseImageResponse({
            'data': [item],
          }, emptyMessage: tr(LocaleKeys.aiImageNoResult)),
        );
      }
      return AiImageGenerationResult.group(results);
    } catch (error) {
      for (final result in results) {
        await result.disposeTemporary();
      }
      if (error is AiImageFetchException) {
        // 一张 URL 的重试回执不能代表包含内嵌图片的整组结果。
        throw AiImageGenerationException(
          error.userMessage,
          debugMessage: error.debugMessage,
          code: error.code,
        );
      }
      rethrow;
    }
  }

  Future<AiImageGenerationResult> _download(
    List<String>? urls,
    ImageOutputsReceived? callback,
  ) async {
    if (urls == null || urls.length != 4 || urls.any((url) => url.isEmpty)) {
      throw const FormatException('Midjourney must return four candidate URLs');
    }
    try {
      await callback?.call(urls);
    } catch (error) {
      throw AiImageFetchException(
        tr(LocaleKeys.aiImageCandidatesFetchFailed),
        urls: urls,
        debugMessage: '$error',
      );
    }
    return downloadResults(urls);
  }

  /// 原生 MJ Proxy 的 imagine 结果是一张 2×2 拼图；裁切不发起额外收费的 upscale 请求。
  Future<AiImageGenerationResult> _grid(String url) async {
    final grid = await downloadResult(url);
    final results = <AiImageGenerationResult>[];
    try {
      final parts = await compute(
        _splitGrid,
        await File(grid.localFilePath!).readAsBytes(),
      );
      for (final part in parts) {
        results.add(
          AiImageGenerationResult(
            localFilePath: await saveImageBase64(base64Encode(part)),
          ),
        );
      }
      return AiImageGenerationResult.group(results);
    } catch (_) {
      for (final result in results) {
        await result.disposeTemporary();
      }
      rethrow;
    } finally {
      await grid.disposeTemporary();
    }
  }

  Future<Map<String, dynamic>> _send(
    Uri uri, [
    Map<String, dynamic>? body,
  ]) async {
    final client = config.createProxyClient() ?? http.Client();
    try {
      final request = http.Request(body == null ? 'GET' : 'POST', uri)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer ${requireApiKey()}',
          'Content-Type': 'application/json',
        });
      if (body != null) {
        request.body = jsonEncode(body);
      }
      final response = await (() async => http.Response.fromStream(
        await client.send(request),
      ))().timeout(imageHttpDataTimeout);
      if (_log.isDebugEnabled) {
        _log.debug(
          'HTTP ${request.method} $uri status=${response.statusCode} response_body=${response.body}',
        );
      }
      throwForImageHttpFailure(
        uri: uri,
        statusCode: response.statusCode,
        data: response.body,
        providerId: config.id,
      );
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['error'] != null ||
          (protocol == MidjourneyProtocol.atlascloud &&
              json['code'] != null &&
              json['code'] != 200)) {
        throw _failure(json);
      }
      return protocol == MidjourneyProtocol.atlascloud && json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : json;
    } finally {
      client.close();
    }
  }

  AiImageGenerationException _failure(
    Map<String, dynamic> data,
  ) => AiImageGenerationException(
    tr(LocaleKeys.aiImageGenerationFailed),
    debugMessage: 'Midjourney rejected task: ${safeImageSerializeForLog(data)}',
    code: classifyAiImageError(
      (data['description'] ?? data['failReason'] ?? data['error'])?.toString(),
    ),
  );
}

List<Uint8List> _splitGrid(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null ||
      image.width < 2 ||
      image.height < 2 ||
      image.width.isOdd ||
      image.height.isOdd) {
    throw const FormatException('Invalid Midjourney grid');
  }
  final w = image.width ~/ 2;
  final h = image.height ~/ 2;
  return [
    for (var i = 0; i < 4; i++)
      img.encodePng(
        img.copyCrop(
          image,
          x: (i % 2) * w,
          y: (i ~/ 2) * h,
          width: w,
          height: h,
        ),
      ),
  ];
}

/// MJ 参数按渠道编码；界面的明确比例覆盖提示词中的同类旗标。
Map<String, dynamic> midjourneyBody(
  ImageGenerationRequest request,
  MidjourneyProtocol protocol,
) {
  var prompt = request.prompt.trim();
  final ratio = request.aspectRatio;
  if (ratio != null && ratio != 'auto') {
    prompt = prompt.replaceAll(RegExp(r'\s+--(?:ar|aspect)\s+\S+'), '').trim();
    prompt = '$prompt --ar $ratio';
  }
  if (request.quality != null) {
    prompt = prompt.replaceAll(RegExp(r'\s+--(?:q|quality)\s+\S+'), '').trim();
    prompt = '$prompt --q ${request.quality}';
  }
  if (protocol != MidjourneyProtocol.atlascloud) {
    return {
      if (protocol == MidjourneyProtocol.images) 'model': request.model,
      if (protocol == MidjourneyProtocol.proxy) 'botType': 'MID_JOURNEY',
      'prompt': prompt,
    };
  }
  final body = <String, dynamic>{'model': request.model};
  final flags = RegExp(
    r'\s+--(aspect|ar|stylize|s|chaos|c|weird|w|quality|q|seed|hd)(?=\s|$)(?:\s+((?!--)\S+))?',
  );
  prompt = prompt.replaceAllMapped(flags, (match) {
    final flag = match[1]!;
    final value = match[2];
    if (flag == 'hd') {
      body['hd'] = true;
      return value == null ? '' : ' $value';
    }
    final key = switch (flag) {
      'ar' || 'aspect' => 'aspect_ratio',
      's' || 'stylize' => 'stylize',
      'c' || 'chaos' => 'chaos',
      'w' || 'weird' => 'weird',
      'q' || 'quality' => 'quality',
      _ => 'seed',
    };
    if (value == null) {
      throw invalidImageParameter();
    }
    if (key == 'aspect_ratio') {
      body[key] = value;
    } else {
      final number = int.tryParse(value);
      if (number == null ||
          (key == 'quality' && !{1, 4}.contains(number)) ||
          (key == 'stylize' && (number < 0 || number > 1000)) ||
          (key == 'chaos' && (number < 0 || number > 100)) ||
          (key == 'weird' && (number < 0 || number > 3000))) {
        throw invalidImageParameter();
      }
      body[key] = number;
    }
    return '';
  }).trim();
  if (request.resolution == '2K') {
    body['hd'] = true;
  }
  body['prompt'] = prompt;
  return body;
}
