// 职责: 执行转录提交、查询和结果下载，并保留上游诊断。
// 关联文件:
//   lib/shared/models/transcription/catalog.dart
//   lib/shared/services/ai/transcription/decoders.dart
//   lib/shared/services/production/transcription_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../logger/app_logger.dart';
import '../../../models/ai_provider.dart';
import '../../../models/transcription/catalog.dart';
import '../../../models/transcription/result.dart';
import '../../../utils/ai_error.dart';
import '../video/wan.dart';
import 'decoders.dart';

final _log = AppLogger.forModule('TranscriptionClient');

typedef TranscriptionSubmission = ({String? remoteId, Transcript? transcript});

class TranscriptionClient {
  TranscriptionClient(this.transport, this.provider, this.model, {this.abort});
  final http.Client transport;
  final AiProvider provider;
  final TranscriptionModel model;
  final Future<void>? abort;

  Uri get _atlas => Uri.parse('https://api.atlascloud.ai/api/v1/model/');
  Uri get _qwen => wanVideoEndpoint(provider.effectiveBaseUrl);
  Uri get _volc => Uri.parse(
    'https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash',
  );

  Map<String, String> get _auth => {
    'Authorization': 'Bearer ${provider.effectiveApiKey}',
  };

  Uri _append(Uri base, String path) {
    if (!{'https', 'http'}.contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasFragment ||
        base.hasQuery) {
      throw const TranscriptionException('invalid_config');
    }
    return base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}/$path',
    );
  }

  Future<TranscriptionSubmission> submit(
    File file,
    String format, {
    Uri? sourceUrl,
  }) async {
    switch (model.protocol) {
      case TranscriptionProtocol.openai_multipart:
        final uri = _append(
          Uri.parse(provider.effectiveBaseUrl),
          'audio/transcriptions',
        );
        final request =
            http.AbortableMultipartRequest('POST', uri, abortTrigger: abort)
              ..headers.addAll(_auth)
              ..fields.addAll({
                'model': model.id,
                'response_format': 'verbose_json',
              });
        request.files.add(
          http.MultipartFile.fromString('timestamp_granularities[]', 'segment'),
        );
        request.files.add(
          await http.MultipartFile.fromPath(
            'file',
            file.path,
            filename: p.basename(file.path),
          ),
        );
        return (
          remoteId: null,
          transcript: decodeOpenAiTranscript(await _send(request)),
        );
      case TranscriptionProtocol.dashscope_file:
        if (sourceUrl == null) {
          throw const TranscriptionException('object_storage_required');
        }
        final response = await _request(
          'POST',
          _append(_qwen, 'api/v1/services/audio/asr/transcription'),
          headers: {..._auth, 'X-DashScope-Async': 'enable'},
          body: {
            'model': model.id,
            'input': {'file_url': sourceUrl.toString()},
            'parameters': {'enable_words': true},
          },
        );
        return (
          remoteId: _receipt(response['output'], 'task_id'),
          transcript: null,
        );
      case TranscriptionProtocol.volcengine_flash:
        final response = await _request(
          'POST',
          _volc,
          headers: {
            'X-Api-Key': provider.effectiveApiKey,
            'X-Api-Resource-Id': model.id,
            'X-Api-Request-Id': const Uuid().v4(),
            'X-Api-Sequence': '-1',
          },
          body: {
            'user': {'uid': 'reveric'},
            'audio': {
              'data': base64Encode(await file.readAsBytes()),
              'format': format,
            },
            'request': {
              'model_name': 'bigmodel',
              'show_utterances': true,
              'enable_punc': true,
            },
          },
          volcengine: true,
        );
        return (
          remoteId: null,
          transcript: decodeVolcengineTranscript(response),
        );
      case TranscriptionProtocol.atlascloud:
        final response = await _request(
          'POST',
          _atlas.resolve('generateAudio'),
          headers: _auth,
          body: {
            'model': model.id,
            'audio_url':
                'data:audio/${format == 'mp3' ? 'mpeg' : format};base64,${base64Encode(await file.readAsBytes())}',
            'format': format,
            'enable_punc': true,
            'show_utterances': true,
          },
        );
        return (
          remoteId: _receipt(_atlasData(response), 'id'),
          transcript: null,
        );
    }
  }

  Future<Transcript?> query(String remoteId) async {
    final id = Uri.encodeComponent(remoteId);
    switch (model.protocol) {
      case TranscriptionProtocol.dashscope_file:
        final data = await _request(
          'GET',
          _append(_qwen, 'api/v1/tasks/$id'),
          headers: _auth,
        );
        final output = data['output'] as JsonObject;
        if (output['task_id'] != remoteId) {
          throw const FormatException('Transcription task receipt mismatch');
        }
        final status = output['task_status'];
        if (status == 'PENDING' || status == 'RUNNING') {
          return null;
        }
        if (status != 'SUCCEEDED') {
          throw TranscriptionException(
            'rejected',
            tryReadProviderMessage(output),
          );
        }
        final result = output['result'] as JsonObject;
        final uri = Uri.parse(result['transcription_url'] as String);
        // The signed result URL owns its authentication.
        if (!{'https', 'http'}.contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment) {
          throw const FormatException('Invalid transcription result URL');
        }
        return decodeDashScopeTranscript(await _request('GET', uri));
      case TranscriptionProtocol.atlascloud:
        final data = _atlasData(
          await _request(
            'GET',
            _atlas.resolve('prediction/$id'),
            headers: _auth,
          ),
        );
        if (data['id'] != remoteId) {
          throw const FormatException('Transcription task receipt mismatch');
        }
        return switch (data['status']) {
          'created' || 'processing' || 'queued' || 'running' => null,
          'completed' || 'succeeded' => decodeAtlasTranscript(data),
          _ => throw TranscriptionException(
            'rejected',
            tryReadProviderMessage(data),
          ),
        };
      case TranscriptionProtocol.openai_multipart ||
          TranscriptionProtocol.volcengine_flash:
        throw const TranscriptionException('invalid_config');
    }
  }

  static String _receipt(Object? output, String key) {
    final id = (output as JsonObject?)?[key];
    if (id is! String || id.isEmpty) {
      throw const TranscriptionException('submission_unknown');
    }
    return id;
  }

  static JsonObject _atlasData(JsonObject response) {
    if (response['error'] != null ||
        (response['code'] != null && response['code'] != 200)) {
      throw TranscriptionException(
        'rejected',
        tryReadProviderMessage(response),
      );
    }
    return response['data'] as JsonObject? ?? response;
  }

  Future<JsonObject> _request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    JsonObject? body,
    bool volcengine = false,
  }) {
    final request = http.AbortableRequest(method, uri, abortTrigger: abort)
      ..headers.addAll(headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return _send(request, volcengine: volcengine);
  }

  Future<JsonObject> _send(
    http.BaseRequest request, {
    bool volcengine = false,
  }) async {
    request.followRedirects = false;
    final target = '${request.url.origin}${request.url.path}';
    final response =
        await (() async => http.Response.fromStream(
          await transport.send(request),
        ))().timeout(
          const Duration(minutes: 5),
          onTimeout: () {
            transport.close();
            throw TranscriptionException(
              request.method == 'POST' ? 'submission_unknown' : 'unavailable',
            );
          },
        );
    if (_log.isDebugEnabled) {
      _log.debug(
        '${request.method} $target status=${response.statusCode} body=${response.body}',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = switch (response.statusCode) {
        401 || 403 => 'authentication',
        429 => 'rate_limited',
        >= 500 =>
          request.method == 'POST' ? 'submission_unknown' : 'unavailable',
        _ => 'rejected',
      };
      throw TranscriptionException(
        code,
        tryReadProviderMessage((message: response.body)),
      );
    }
    if (volcengine) {
      final status = response.headers['x-api-status-code'];
      if (status == '20000003') {
        throw const TranscriptionException('no_speech');
      }
      if (status != '20000000') {
        throw TranscriptionException(
          'rejected',
          response.headers['x-api-message'],
        );
      }
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as JsonObject;
  }
}
