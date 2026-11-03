// 职责: 将图片请求编码为 AtlasCloud 预测任务，轮询到完成并解析输出图片。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;

import '../../../models/ai_provider.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/image/channels.dart';
import '../image.dart';
import 'client.dart';

class AtlasCloudImageClient extends ImageClient {
  AtlasCloudImageClient(super.config);

  static const _attempts = 3;

  @override
  Future<AiImageGenerationResult> generate(
    ImageGenerationRequest request,
  ) async {
    final channel = validatedChannel(request);
    final caps = channel?.capabilities;
    final options = channel?.protocolOptions as AtlasCloudImageOptions?;
    final size = request.size;
    final aspectRatio = request.aspectRatio;
    final resolution = request.resolution;
    if (caps != null &&
        ((aspectRatio != null && !caps.ratios.contains(aspectRatio)) ||
            (resolution != null && !caps.resolutions.contains(resolution)))) {
      throw invalidImageParameter();
    }
    final editing = request.images.isNotEmpty;
    // Registered models declare their edit route; custom IDs are sent verbatim.
    if (editing && channel != null && options?.editModel == null) {
      throw invalidImageParameter();
    }
    final body = <String, dynamic>{
      'model': editing ? (options?.editModel ?? request.model) : request.model,
      'prompt': request.prompt,
      'output_format': ?channel?.requestDefaults.outputFormat,
    };
    if (options?.usesResolution ?? false) {
      // This endpoint has ratio/tier controls, not a pixel-size parameter.
      if (size != null && !caps!.resolutions.contains(size)) {
        throw invalidImageParameter();
      }
      body['aspect_ratio'] = aspectRatio ?? '1:1';
      body['resolution'] = (resolution ?? size ?? '1K').toLowerCase();
    } else {
      final dimensions = caps == null
          ? size
          : caps.resolutions.contains(size)
          ? caps.size(aspectRatio ?? '1:1', size!)
          : size ??
                (aspectRatio != null || resolution != null
                    ? caps.size(
                        aspectRatio ?? '1:1',
                        resolution ?? caps.resolutions.first,
                      )
                    : channel!.requestDefaults.size);
      if (dimensions != null) {
        if (caps != null &&
            !caps.sizes.values.any(
              (sizes) => sizes.containsValue(dimensions),
            )) {
          throw invalidImageParameter();
        }
        body['size'] = dimensions.replaceAll(
          'x',
          options?.sizeSeparator ?? 'x',
        );
      }
      final qualityLevels = options?.qualityLevels ?? const <String>{};
      if (qualityLevels.isNotEmpty && request.quality != null) {
        if (!qualityLevels.contains(request.quality)) {
          throw invalidImageParameter();
        }
        body['quality'] = request.quality;
      }
    }
    if (editing) {
      body['images'] = [
        for (final input in request.images)
          await imageInputAsUrlOrDataUri(input),
      ];
    }
    final client = config.createProxyClient() ?? http.Client();
    final elapsed = Stopwatch()..start();
    try {
      final prediction = await _send(
        client,
        elapsed,
        _uri('generateImage'),
        data: body,
      );
      final id = prediction['id'];
      if (id is String && id.trim().isNotEmpty) {
        try {
          await request.onSubmitted?.call(id);
        } catch (error) {
          throw AiImageFetchException(
            '图片结果获取失败，请稍后重试。',
            providerTaskId: id,
            debugMessage: 'AtlasCloud prediction $id record failed: $error',
          );
        }
      }
      return await _settle(client, elapsed, prediction);
    } finally {
      client.close();
    }
  }

  @override
  Future<AiImageGenerationResult> resumeResult(String providerTaskId) async {
    final client = config.createProxyClient() ?? http.Client();
    final elapsed = Stopwatch()..start();
    try {
      return await _settle(client, elapsed, {
        'id': providerTaskId,
        'status': 'processing',
      }, resumed: true);
    } finally {
      client.close();
    }
  }

  Uri _uri(String path) {
    final base = Uri.parse(config.effectiveBaseUrl);
    final root = base.path.replaceFirst(RegExp(r'/v1/?$'), '');
    return base.replace(path: '$root/api/v1/model/$path');
  }

  /// 轮询到终态并取回图片。任务已受理后，查询失败带上任务 ID 抛出，
  /// 供调用方稍后继续查询而不是重新出图。
  Future<AiImageGenerationResult> _settle(
    http.Client client,
    Stopwatch elapsed,
    Map<String, dynamic> prediction, {
    bool resumed = false,
  }) async {
    final id = prediction['id'];
    var poll = resumed;
    while (true) {
      if (poll) {
        if (!resumed) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        resumed = false;
        final uri = _uri('prediction/${Uri.encodeComponent(id as String)}');
        try {
          prediction = await _send(client, elapsed, uri);
        } catch (error) {
          throw AiImageFetchException(
            '图片结果获取失败，请稍后重试。',
            providerTaskId: id,
            debugMessage:
                'AtlasCloud prediction $id poll failed at $uri: '
                '${error is AiImageGenerationException ? error.debugMessage ?? error.userMessage : error}',
          );
        }
      }
      poll = true;
      final status = prediction['status'];
      if (status == 'completed' || status == 'succeeded') {
        final outputs = prediction['outputs'];
        if (outputs is! List || outputs.isEmpty || outputs.first is! String) {
          throw _predictionError(prediction, _uri('generateImage'));
        }
        return parseImageResponse({
          'data': [
            {'url': outputs.first},
          ],
        }, emptyMessage: tr(LocaleKeys.aiImageNoResult));
      }
      if (!{
            'created',
            'starting',
            'queued',
            'pending',
            'processing',
            'running',
          }.contains(status) ||
          id is! String ||
          id.trim().isEmpty) {
        throw _predictionError(prediction, _uri('generateImage'));
      }
    }
  }

  Future<Map<String, dynamic>> _send(
    http.Client client,
    Stopwatch elapsed,
    Uri uri, {
    Map<String, dynamic>? data,
  }) async {
    final apiKey = requireApiKey();
    final remaining = imageHttpDataTimeout - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('AtlasCloud image prediction timed out');
    }
    http.Request build() {
      final request = http.Request(data == null ? 'GET' : 'POST', uri)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        });
      if (data != null) {
        request.body = jsonEncode(data);
      }
      return request;
    }

    var request = build();
    http.Response? response;
    // 握手未完成时请求体尚未发出，提交也可安全重试；轮询是幂等 GET，
    // 连接层错误都可重试。
    for (var attempt = 1; response == null; attempt++) {
      try {
        response = await (() async => http.Response.fromStream(
          await client.send(request),
        ))().timeout(remaining);
      } catch (error) {
        final retryable =
            error is HandshakeException ||
            (data == null &&
                (error is SocketException || error is http.ClientException));
        if (attempt >= _attempts || !retryable) {
          rethrow;
        }
        writeImageLog(
          '[IMGDBG] atlascloud_retry method=${request.method} '
          'uri=${safeImageUriForLog(uri)} attempt=$attempt error=$error',
        );
        await Future<void>.delayed(Duration(seconds: attempt));
        request = build();
      }
    }
    writeImageLog(
      '[IMGDBG] atlascloud_response method=${request.method} uri=${safeImageUriForLog(uri)} status=${response.statusCode}',
    );
    throwForImageHttpFailure(
      uri: uri,
      statusCode: response.statusCode,
      data: response.body,
      providerId: config.id,
    );
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    if (json['error'] != null ||
        (json['code'] != null && json['code'] != 200)) {
      throw _predictionError(json, uri);
    }
    return json['data'] == null ? json : json['data'] as Map<String, dynamic>;
  }

  AiImageGenerationException _predictionError(
    Map<String, dynamic> data,
    Uri uri,
  ) {
    final message = extractImageServerMessage(data);
    return AiImageGenerationException(
      imageUserMessageFromServerMessage(message) ??
          tr(LocaleKeys.aiImageGenerationFailed),
      debugMessage:
          'AtlasCloud prediction error at $uri response=${safeImageSerializeForLog(data)}',
      code: classifyAiImageError(message),
    );
  }
}
