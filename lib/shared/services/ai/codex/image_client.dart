// 职责: 将生图和参考图编辑转换为 Codex Responses 请求并提取完整图片结果。
// 关联文件:
//   lib/shared/services/ai/codex/credentials.dart
//   lib/shared/services/ai/codex/request.dart
//   lib/shared/services/ai/image.dart

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../../logger/app_logger.dart';
import '../../../utils/ai_error.dart';
import 'credentials.dart';
import 'request.dart';

final _log = AppLogger.forModule('CodexImage');

class CodexImageException implements Exception {
  const CodexImageException(
    this.reason, {
    this.statusCode,
    this.code,
    this.providerMessage,
  });
  final String reason;
  final int? statusCode;
  final String? code;
  final String? providerMessage;

  @override
  String toString() => 'CodexImageException($reason, HTTP $statusCode, $code)';
}

/// 每次图片任务独占 client，完成、失败或超时后关闭连接。
class CodexImageClient {
  CodexImageClient({
    required http.Client client,
    Future<CodexCredentials> Function()? credentials,
    Random? random,
    this.timeout = const Duration(minutes: 5),
  }) : _client = client,
       _credentials =
           credentials ?? (() => CodexCredentials.load(client: client)),
       _random = random ?? Random();

  final http.Client _client;
  final Future<CodexCredentials> Function() _credentials;
  final Random _random;
  final Duration timeout;
  static const _maxEventChars = 128 * 1024 * 1024;

  Future<Map<String, dynamic>> generate({
    required String prompt,
    required String imageModel,
    required List<String> chatModels,
    List<String> referenceImages = const [],
    String? size,
    String? quality,
    String? complexity,
  }) async {
    try {
      final models = chatModels
          .where((m) => m.trim().isNotEmpty)
          .toSet()
          .toList();
      if (models.isEmpty) {
        throw const CodexImageException('no_chat_models');
      }
      final model = models.contains('gpt-6-luna')
          ? 'gpt-6-luna'
          : models[_random.nextInt(models.length)];
      return await _generate(
        prompt: prompt,
        imageModel: imageModel,
        mainModel: model,
        referenceImages: referenceImages,
        size: size,
        quality: quality,
        complexity: complexity,
      ).timeout(timeout);
    } on CodexAuthException {
      rethrow;
    } on CodexImageException {
      rethrow;
    } on TimeoutException {
      throw const CodexImageException('timeout');
    } catch (error, stack) {
      // JSON/HTTP 异常可能带图片正文或凭据，只记录异常类型。
      _log.error('request failed type=${error.runtimeType}', stackTrace: stack);
      throw const CodexImageException('invalid_response');
    } finally {
      _client.close();
    }
  }

  Future<Map<String, dynamic>> _generate({
    required String prompt,
    required String imageModel,
    required String mainModel,
    required List<String> referenceImages,
    String? size,
    String? quality,
    String? complexity,
  }) async {
    final auth = await _credentials();
    final sessionId = const Uuid().v4();
    final request = http.Request('POST', Uri.parse('$codexBaseUrl/responses'))
      ..headers.addAll({
        ...codexHeaders(auth),
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
        'session_id': sessionId,
        'conversation_id': sessionId,
      })
      ..body = jsonEncode({
        'model': mainModel,
        'instructions':
            'Generate or edit the requested image using the image generation tool.',
        'stream': true,
        'store': false,
        'prompt_cache_key': sessionId,
        'input': [
          {
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': prompt},
              for (final image in referenceImages)
                {'type': 'input_image', 'image_url': image},
            ],
          },
        ],
        'tools': [
          {
            'type': 'image_generation',
            'model': imageModel,
            'action': referenceImages.isEmpty ? 'generate' : 'edit',
            'output_format': 'png',
            if (size != null && size.isNotEmpty) 'size': size,
            if (quality != null && quality.isNotEmpty) 'quality': quality,
            if (complexity != null && complexity.isNotEmpty)
              'complexity': complexity,
          },
        ],
        'tool_choice': 'required',
      });
    _log.info(
      'POST $codexBaseUrl/responses main=$mainModel image=$imageModel references=${referenceImages.length}',
    );
    final response = await _client.send(request);
    _log.info('response HTTP ${response.statusCode}');
    if (response.statusCode != 200) {
      // 不记录响应正文，错误码仅保留已知分类。
      final body = await _readBody(response.stream, limit: 64 * 1024);
      Map<String, dynamic>? error;
      try {
        final decoded = jsonDecode(body);
        error = decoded is Map<String, dynamic> ? decoded : null;
      } on FormatException {
        throw CodexImageException(
          'http_error',
          statusCode: response.statusCode,
          providerMessage: tryReadProviderMessage(body),
        );
      }
      throw _failure(error, statusCode: response.statusCode);
    }
    if (response.headers['content-type']?.contains('application/json') ==
        true) {
      return _images(
        jsonDecode(await _readBody(response.stream)) as Map<String, dynamic>,
      );
    }
    final completedItems = <Map<String, dynamic>>[];
    await for (final event in _events(response.stream)) {
      final type = event['type'];
      if (type == 'error' ||
          type == 'response.failed' ||
          type == 'response.incomplete') {
        throw _failure(
          event['response'] is Map<String, dynamic>
              ? event['response'] as Map<String, dynamic>
              : event,
        );
      }
      if (type == 'response.output_item.done') {
        final item = event['item'];
        if (item is Map<String, dynamic> &&
            item['type'] == 'image_generation_call') {
          completedItems.add(item);
        }
      }
      if (type == 'response.completed') {
        return _images(
          event['response'] as Map<String, dynamic>,
          completedItems,
        );
      }
    }
    throw const CodexImageException('incomplete');
  }

  static CodexImageException _failure(
    Map<String, dynamic>? body, {
    int? statusCode,
  }) {
    final error = body?['error'];
    final code = error is Map ? error['code'] : body?['code'];
    const known = {
      'content_policy_violation',
      'moderation_blocked',
      'rate_limit_exceeded',
      'insufficient_quota',
      'invalid_api_key',
      'invalid_model',
      'model_not_found',
    };
    final safeCode = known.contains(code) ? code as String : null;
    _log.warning('generation failed HTTP $statusCode code=$safeCode');
    return CodexImageException(
      'upstream_error',
      statusCode: statusCode,
      code: safeCode,
      providerMessage: body == null ? null : tryReadProviderMessage(body),
    );
  }

  static Map<String, dynamic> _images(
    Map<String, dynamic> response, [
    List<Map<String, dynamic>> completedItems = const [],
  ]) {
    if (response['error'] != null) {
      throw _failure(response);
    }
    if (response['status'] != 'completed') {
      throw const CodexImageException('incomplete');
    }
    final output = (response['output'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((item) => item['type'] == 'image_generation_call')
        .toList();
    final candidates = output.isEmpty ? completedItems : output;
    for (final item in candidates) {
      if (item['status'] != 'completed') {
        throw const CodexImageException('incomplete');
      }
      final result = item['result'];
      if (result is! String || result.isEmpty) {
        continue;
      }
      final bytes = result.startsWith('data:')
          ? UriData.parse(result).contentAsBytes()
          : base64Decode(result);
      final png =
          bytes.length >= 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47;
      final jpeg =
          bytes.length >= 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff;
      final webp =
          bytes.length >= 12 &&
          ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
          ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP';
      if (!png && !jpeg && !webp) {
        throw const CodexImageException('no_image');
      }
      return {
        'data': [
          {
            'b64_json': base64Encode(bytes),
            if (item['revised_prompt'] is String)
              'revised_prompt': item['revised_prompt'],
          },
        ],
      };
    }
    throw const CodexImageException('no_image');
  }

  static Future<String> _readBody(
    Stream<List<int>> stream, {
    int limit = _maxEventChars,
  }) async {
    final chunks = <int>[];
    await for (final chunk in stream) {
      if (chunks.length + chunk.length > limit) {
        throw const CodexImageException('response_too_large');
      }
      chunks.addAll(chunk);
    }
    return utf8.decode(chunks);
  }

  static Stream<Map<String, dynamic>> _events(Stream<List<int>> stream) async* {
    final data = <String>[];
    String? eventType;
    var length = 0;
    Map<String, dynamic> decode() {
      final Map<String, dynamic> event;
      try {
        event = jsonDecode(data.join('\n')) as Map<String, dynamic>;
      } on FormatException {
        if (eventType == 'error') {
          throw const CodexImageException('upstream_error');
        }
        rethrow;
      }
      if (event['type'] == null && eventType != null) {
        event['type'] = eventType;
      }
      return event;
    }

    await for (final line
        in stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        final value = line.substring(5).trimLeft();
        if (value == '[DONE]') {
          if (data.isNotEmpty) {
            yield decode();
          }
          return;
        }
        length += value.length;
        if (length > _maxEventChars) {
          throw const CodexImageException('response_too_large');
        }
        data.add(value);
      } else if (line.isEmpty) {
        if (data.isNotEmpty) {
          yield decode();
        }
        data.clear();
        length = 0;
        eventType = null;
      }
    }
    if (data.isNotEmpty) {
      yield decode();
    }
  }
}
