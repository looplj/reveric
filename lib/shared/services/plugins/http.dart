// 职责: 为单次插件执行提供有界、可取消的直接 HTTP 请求。
// 关联文件:
//   lib/shared/services/plugins/host.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'runtime.dart';

class PluginHttpApi {
  PluginHttpApi({HttpClient Function()? clientFactory, this.requestLimit = 50})
    : _clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() _clientFactory;
  final int? requestLimit;
  final Set<HttpClient> _clients = {};
  final List<Completer<void>> _waiting = [];
  var _active = 0;
  var _count = 0;
  var _cancelled = false;
  void cancel() {
    _cancelled = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    for (final waiter in _waiting) {
      waiter.complete();
    }
    _waiting.clear();
  }

  Future<Map<String, dynamic>> fetch(Map<String, dynamic> args) async {
    _count++;
    if (requestLimit != null && _count > requestLimit!) {
      throw PluginHostError(
        'rate_limited',
        'More than $requestLimit requests in one execution',
      );
    }
    if (_active >= 4) {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    if (_cancelled) {
      throw PluginHostError('cancelled', 'HTTP execution cancelled');
    }
    final client = _clientFactory()..findProxy = ((_) => 'DIRECT');
    _clients.add(client);
    try {
      final raw = args['url'];
      final uri = raw is String ? Uri.tryParse(raw) : null;
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw PluginHostError(
          'invalid_url',
          'Expected an absolute http or https URL: $raw',
        );
      }
      final timeout = args['timeoutMs'] ?? 20000;
      final max = args['maxBytes'] ?? 5 * 1024 * 1024;
      final method = args['method'] ?? 'GET';
      final responseType = args['responseType'] ?? 'text';
      if (timeout is! int ||
          timeout <= 0 ||
          timeout > 60000 ||
          max is! int ||
          max <= 0 ||
          max > 5 * 1024 * 1024 ||
          !['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'].contains(method) ||
          !['text', 'base64'].contains(responseType) ||
          (args['body'] != null && args['body'] is! String)) {
        throw PluginHostError(
          'invalid_argument',
          'Invalid HTTP request options',
        );
      }
      Future<Map<String, dynamic>> request() async {
        final req = await client.openUrl(method as String, uri);
        final headers = args['headers'];
        if (headers != null &&
            (headers is! Map ||
                headers.entries.any(
                  (e) => e.key is! String || e.value is! String,
                ))) {
          throw PluginHostError(
            'invalid_argument',
            'Headers must contain strings',
          );
        }
        (headers as Map? ?? {}).forEach(
          (key, value) => req.headers.set(key as String, value as String),
        );
        if (req.headers.value('user-agent') == null) {
          req.headers.set(
            'user-agent',
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
          );
        }
        if (args['body'] != null) {
          // 直接写 UTF-8 字节，避免 write 在未声明 charset 时按 Latin-1 编码。
          req.add(utf8.encode(args['body'] as String));
        }
        final response = await req.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > max) {
            throw PluginHostError('too_large', 'Response exceeds $max bytes');
          }
          bytes.addAll(chunk);
        }
        final outputHeaders = <String, String>{};
        response.headers.forEach(
          (key, values) => outputHeaders[key.toLowerCase()] = values.join(', '),
        );
        final wrapped = http.Response.bytes(
          bytes,
          response.statusCode,
          headers: outputHeaders,
        );
        String body;
        if (responseType == 'base64') {
          body = base64Encode(bytes);
        } else if (RegExp(
          r'charset\s*=',
          caseSensitive: false,
        ).hasMatch(outputHeaders['content-type'] ?? '')) {
          body = wrapped.body;
        } else {
          try {
            body = utf8.decode(bytes);
          } on FormatException {
            body = latin1.decode(bytes);
          }
        }
        return {
          'status': response.statusCode,
          'url': response.redirects
              .fold(uri, (url, redirect) => url.resolveUri(redirect.location))
              .toString(),
          'headers': outputHeaders,
          'body': body,
        };
      }

      return await request().timeout(Duration(milliseconds: timeout));
    } on TimeoutException catch (error) {
      throw PluginHostError('timeout', error.toString());
    } on PluginHostError {
      rethrow;
    } catch (error) {
      throw PluginHostError(
        _cancelled ? 'cancelled' : 'network',
        error.toString(),
      );
    } finally {
      client.close(force: true);
      _clients.remove(client);
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }
}
