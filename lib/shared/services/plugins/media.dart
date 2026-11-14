// 职责: 在 Host 内绑定参考文件字节与提取图片响应，避免大段 base64 进入插件运行时。
// 关联文件:
//   lib/shared/services/plugins/files.dart
//   lib/shared/services/plugins/media_files.dart
//   lib/shared/services/plugins/media_pointer.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'files.dart';
import 'media_files.dart';
import 'media_pointer.dart';
import 'runtime.dart';

class PluginMediaApi {
  PluginMediaApi({
    required this.scope,
    required this.outputs,
    required this.clientFactory,
    required this.remainingBudget,
  });
  final PluginFileScope scope;
  final PluginMediaFiles outputs;
  final HttpClient Function() clientFactory;
  final Duration Function() remainingBudget;
  final _clients = <HttpClient>{};
  bool _cancelled = false;
  final _cancellation = Completer<void>();
  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _cancellation.complete();
    for (final client in _clients) {
      client.close(force: true);
    }
  }

  void _active() {
    if (_cancelled) {
      throw PluginHostError('cancelled', 'Media request cancelled');
    }
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> args) async {
    _active();
    final raw = args['request'];
    final uri = args['url'] is String
        ? Uri.tryParse(args['url'] as String)
        : null;
    if (raw is! Map ||
        uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw PluginHostError('invalid_request', 'Invalid media request');
    }
    final timeout = raw['timeoutMs'] ?? 300000;
    final method = raw['method'];
    final headers = raw['headers'] ?? <String, String>{};
    final body = raw['body'];
    final response = raw['response'];
    bool strings(Object? v) =>
        v is Map &&
        v.entries.every((e) => e.key is String && e.value is String);
    if (timeout is! int ||
        timeout < 1 ||
        timeout > 300000 ||
        !{'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'}.contains(method) ||
        !strings(headers) ||
        body is! Map ||
        response is! Map ||
        !{'json', 'file'}.contains(response['kind'])) {
      throw PluginHostError('invalid_request', 'Invalid media options');
    }
    final remaining = remainingBudget();
    if (remaining <= Duration.zero) {
      throw PluginHostError('timeout', 'Provider method budget exhausted');
    }
    final requested = Duration(milliseconds: timeout);
    final effective = remaining < requested ? remaining : requested;
    final timer = Stopwatch()..start();
    void checkActive() {
      _active();
      if (timer.elapsed >= effective) {
        throw PluginHostError(
          'timeout',
          'Media request exceeded method budget',
        );
      }
    }

    final client = clientFactory();
    client.connectionTimeout = effective < const Duration(seconds: 30)
        ? effective
        : const Duration(seconds: 30);
    _clients.add(client);
    Future<Map<String, dynamic>> send() async {
      Stream<List<int>> stream;
      int length;
      String contentType;
      if (body['kind'] == 'json' && body['value'] is Map) {
        final value = jsonDecode(jsonEncode(body['value']));
        final bindings = body['files'] ?? [];
        if (bindings is! List) {
          throw PluginHostError('invalid_request', 'Expected file bindings');
        }
        for (final binding in bindings) {
          if (binding is! Map ||
              !{'base64', 'data_uri'}.contains(binding['encoding'])) {
            throw PluginHostError('invalid_request', 'Invalid file binding');
          }
          final slot = pluginMediaPointer(value, binding['pointer']);
          final file = scope.resolve(binding['handle']);
          final encoded = base64Encode(await file.file.readAsBytes());
          checkActive();
          slot.replace(
            binding['encoding'] == 'base64'
                ? encoded
                : 'data:${file.mimeType};base64,$encoded',
          );
        }
        final bytes = utf8.encode(jsonEncode(value));
        stream = Stream.value(bytes);
        length = bytes.length;
        contentType = 'application/json';
      } else if (body['kind'] == 'multipart' &&
          strings(body['fields']) &&
          body['files'] is List) {
        final multipart = http.MultipartRequest(method as String, uri)
          ..fields.addAll(Map<String, String>.from(body['fields'] as Map));
        for (final binding in body['files'] as List) {
          if (binding is! Map ||
              binding['field'] is! String ||
              (binding['name'] != null && binding['name'] is! String)) {
            throw PluginHostError(
              'invalid_request',
              'Invalid multipart binding',
            );
          }
          final file = scope.resolve(binding['handle']);
          multipart.files.add(
            http.MultipartFile(
              binding['field'] as String,
              file.file.openRead(),
              file.size,
              filename: binding['name'] as String? ?? file.name,
              contentType: http.MediaType.parse(file.mimeType),
            ),
          );
        }
        stream = multipart.finalize();
        length = multipart.contentLength;
        contentType = multipart.headers[HttpHeaders.contentTypeHeader]!;
      } else {
        throw PluginHostError('invalid_request', 'Invalid media body');
      }
      checkActive();
      final request = await client.openUrl(method as String, uri);
      request.followRedirects = false;
      (headers as Map).forEach(
        (key, value) => request.headers.set(key as String, value as String),
      );
      request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      request.contentLength = length;
      await request.addStream(stream);
      final result = await request.close();
      final success = result.statusCode >= 200 && result.statusCode < 300;
      final bytes = <int>[];
      final limit = success ? 128 * 1024 * 1024 : 5 * 1024 * 1024;
      await for (final chunk in result) {
        if (bytes.length + chunk.length > limit) {
          throw PluginHostError(
            'too_large',
            'Media response exceeds byte limit',
          );
        }
        bytes.addAll(chunk);
      }
      checkActive();
      Object? value;
      if (!success) {
        value = utf8.decode(bytes, allowMalformed: true);
      } else if (response['kind'] == 'file') {
        value = await outputs.stage(bytes, ensureActive: checkActive);
      } else {
        value = jsonDecode(utf8.decode(bytes));
        bytes.clear();
        final selectors = response['images'] ?? [];
        if (selectors is! List) {
          throw PluginHostError('invalid_request', 'Expected image selectors');
        }
        for (final selector in selectors) {
          if (selector is! Map ||
              !{'base64', 'data_uri'}.contains(selector['encoding'])) {
            throw PluginHostError('invalid_request', 'Invalid image selector');
          }
          final slot = pluginMediaPointer(value, selector['pointer']);
          var encoded = slot.value;
          if (encoded is! String) {
            throw PluginHostError(
              'invalid_response',
              'Image selector must contain encoded image',
            );
          }
          if (selector['encoding'] == 'data_uri') {
            final match = RegExp(
              r'^data:image/[a-zA-Z0-9.+-]+;base64,',
            ).firstMatch(encoded);
            if (match == null) {
              throw PluginHostError(
                'invalid_response',
                'Invalid image data URI',
              );
            }
            encoded = encoded.substring(match.end);
          }
          slot.replace(
            await outputs.stage(
              base64Decode(encoded),
              ensureActive: checkActive,
            ),
          );
          checkActive();
        }
      }
      checkActive();
      final outputHeaders = <String, String>{};
      result.headers.forEach(
        (key, values) => outputHeaders[key] = values.join(', '),
      );
      return {
        'status': result.statusCode,
        'headers': outputHeaders,
        'body': value,
      };
    }

    try {
      return await Future.any([
        send(),
        _cancellation.future.then<Map<String, dynamic>>(
          (_) => throw PluginHostError('cancelled', 'Media request cancelled'),
        ),
      ]).timeout(effective);
    } on TimeoutException {
      throw PluginHostError('timeout', 'Media request exceeded method budget');
    } on PluginHostError {
      rethrow;
    } on FormatException catch (error) {
      throw PluginHostError('invalid_response', error.message);
    } catch (error) {
      throw PluginHostError(
        _cancelled ? 'cancelled' : 'network',
        error.toString(),
      );
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }
}
