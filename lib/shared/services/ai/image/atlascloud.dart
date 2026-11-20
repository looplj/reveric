// 职责: 将图片请求编码为 AtlasCloud 预测任务，单次提交与查询并返回统一图片任务回执。
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
  Future<ProviderSubmitResult> submit(
    SubmitImageInput request,
    ImageOutputContext outputs,
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
    final editing = request.references.isNotEmpty;
    // Registered models declare their edit route; custom IDs are sent verbatim.
    if (editing && channel != null && options?.editModel == null) {
      throw invalidImageParameter();
    }
    final body = <String, dynamic>{
      'model': editing ? (options?.editModel ?? request.model) : request.model,
      'prompt': request.prompt,
      'output_format': ?request.nativeDefaults.outputFormat,
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
                    : request.nativeDefaults.size);
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
        for (final input in request.references)
          await imageInputAsUrlOrDataUri(input, outputs),
      ];
    }
    final client = newImageHttpClient();
    final elapsed = Stopwatch()..start();
    try {
      final prediction = await _send(
        client,
        elapsed,
        _uri('generateImage'),
        data: body,
      );
      final status = prediction['status'];
      if (status == 'completed' || status == 'succeeded') {
        return await _outputs(prediction, outputs);
      }
      final id = prediction['id'];
      if (id is! String || id.trim().isEmpty) {
        throw const ProviderFailure(
          code: 'submission_unknown',
          message: 'AtlasCloud returned no task identity',
        );
      }
      return ProviderSubmitted(
        id,
        state:
            {
              'created',
              'starting',
              'queued',
              'pending',
              'processing',
              'running',
            }.contains(status)
            ? null
            : {
                'terminalStatus': status,
                'message': extractImageServerMessage(prediction),
              },
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<ProviderQueryResult> query(
    ProviderQueryInput input,
    ImageOutputContext outputs,
  ) async {
    final terminal = input.state?['terminalStatus'];
    if (terminal != null) {
      if (terminal == 'unknown') {
        return const ProviderUnknown('Unknown initial prediction status');
      }
      final error = _predictionError({
        'status': terminal,
        'error': input.state?['message'],
      }, _uri('generateImage'));
      return ProviderFailed(
        ProviderFailure(
          code: error.code?.name ?? 'failed',
          message: error.userMessage,
          detail: error.debugMessage,
        ),
      );
    }
    final client = newImageHttpClient();
    try {
      final prediction = await _send(
        client,
        Stopwatch()..start(),
        _uri('prediction/${Uri.encodeComponent(input.remoteTaskId)}'),
        timeout: const Duration(seconds: 30),
      );
      final status = prediction['status'];
      if (status == 'completed' || status == 'succeeded') {
        return await _outputs(prediction, outputs);
      }
      if ({
        'created',
        'starting',
        'queued',
        'pending',
        'processing',
        'running',
      }.contains(status)) {
        return ProviderPending(
          queued: status == 'queued' || status == 'pending',
        );
      }
      if (status == 'cancelled') {
        return const ProviderStopped(cancelled: true);
      }
      if (status == 'expired') {
        return const ProviderStopped();
      }
      final error = _predictionError(prediction, _uri('generateImage'));
      return ProviderFailed(
        ProviderFailure(
          code: error.code?.name ?? 'failed',
          message: error.userMessage,
          detail: error.debugMessage,
        ),
      );
    } finally {
      client.close();
    }
  }

  Future<ProviderSucceeded> _outputs(
    Map<String, dynamic> prediction,
    ImageOutputContext outputs,
  ) {
    final values = prediction['outputs'];
    if (values is! List ||
        values.isEmpty ||
        values.any((value) => value is! String || value.isEmpty)) {
      throw invalidImageOutputs(
        'AtlasCloud succeeded without valid image outputs',
      );
    }
    return outputs.nativeImages([
      for (final value in values) {'url': value},
    ]);
  }

  Uri _uri(String path) {
    final base = Uri.parse(config.effectiveBaseUrl);
    final root = base.path.replaceFirst(RegExp(r'/v1/?$'), '');
    return base.replace(path: '$root/api/v1/model/$path');
  }

  Future<Map<String, dynamic>> _send(
    http.Client client,
    Stopwatch elapsed,
    Uri uri, {
    Map<String, dynamic>? data,
    Duration timeout = imageHttpDataTimeout,
  }) async {
    final apiKey = requireApiKey();
    final remaining = timeout - elapsed.elapsed;
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
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('AtlasCloud image request timed out');
      }
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
