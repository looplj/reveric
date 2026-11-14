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
import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;
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
  Future<ProviderSubmitResult> submit(
    SubmitImageInput request,
    ImageOutputContext outputs,
  ) async {
    final channel = validatedChannel(request)!;
    if (request.references.isNotEmpty ||
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
      return _imagesResponse(response, outputs);
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
      throw const ProviderFailure(
        code: 'submission_unknown',
        message: 'Midjourney returned no task identity',
      );
    }
    return ProviderSubmitted(id);
  }

  @override
  Future<ProviderQueryResult> query(
    ProviderQueryInput input,
    ImageOutputContext outputs,
  ) async {
    final response = await _send(
      _uri(
        protocol == MidjourneyProtocol.proxy
            ? 'mj/task/${Uri.encodeComponent(input.remoteTaskId)}/fetch'
            : 'api/v1/model/prediction/${Uri.encodeComponent(input.remoteTaskId)}',
      ),
      null,
      const Duration(seconds: 30),
    );
    final status = response['status'];
    if (status == 'SUCCESS' || status == 'completed' || status == 'succeeded') {
      if (protocol == MidjourneyProtocol.proxy) {
        // Host owns download/crop/staging; this does not issue paid upscale calls.
        return outputs.grid(response['imageUrl'] as String);
      }
      final urls = (response['outputs'] as List).cast<String>();
      if (urls.length != 4 || urls.any((url) => url.isEmpty)) {
        throw const FormatException(
          'Midjourney must return four candidate URLs',
        );
      }
      return outputs.nativeImages([
        for (final url in urls) {'url': url},
      ]);
    }
    if ({
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
      return ProviderPending();
    }
    if (status == 'cancelled') {
      return const ProviderStopped(cancelled: true);
    }
    if (status == 'expired') {
      return const ProviderStopped();
    }
    final error = _failure(response);
    return ProviderFailed(
      ProviderFailure(
        code: error.code?.name ?? 'failed',
        message: error.userMessage,
        detail: error.debugMessage,
      ),
    );
  }

  Future<ProviderSucceeded> _imagesResponse(
    Map<String, dynamic> response,
    ImageOutputContext outputs,
  ) async {
    final data = response['data'];
    if (data is! List || data.isEmpty) {
      throw invalidImageOutputs('Midjourney must return four candidates');
    }
    final result = <ProviderOutput>[];
    for (var index = 0; index < data.length; index++) {
      final item = data[index];
      if (item is! Map<String, dynamic> ||
          (item['error'] == null &&
              !((item['url'] is String && (item['url'] as String).isNotEmpty) ||
                  (item['b64_json'] is String &&
                      (item['b64_json'] as String).isNotEmpty)))) {
        throw invalidImageOutputs('Invalid Midjourney data[$index]');
      }
      result.addAll(
        (await parseImageResponse(
          {
            'data': [item],
          },
          outputs,
          emptyMessage: tr(LocaleKeys.aiImageNoResult),
        )).outputs,
      );
    }
    if (data.length != 4) {
      throw invalidImageOutputs('Midjourney must return four candidates');
    }
    return ProviderSucceeded(result);
  }

  Future<Map<String, dynamic>> _send(
    Uri uri, [
    Map<String, dynamic>? body,
    Duration timeout = imageHttpDataTimeout,
  ]) async {
    final client = newImageHttpClient();
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
      ))().timeout(timeout);
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

/// MJ 参数按渠道编码；界面的明确比例覆盖提示词中的同类旗标。
Map<String, dynamic> midjourneyBody(
  SubmitImageInput request,
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
