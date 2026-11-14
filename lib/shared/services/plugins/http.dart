// 职责: 为单次插件执行提供有界、可取消的直接 HTTP 请求。
// 关联文件:
//   lib/shared/services/plugins/host.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'runtime.dart';
import '../../logger/app_logger.dart';

final _log = AppLogger.forModule('PluginHttp');

class PluginHttpApi {
  PluginHttpApi({
    HttpClient Function()? clientFactory,
    this.requestLimit = 50,
    this.direct = true,
    this.logResponses = false,
    this.remainingBudget,
  }) : _clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() _clientFactory;
  final int? requestLimit;
  final bool direct;
  final bool logResponses;
  final Duration Function()? remainingBudget;
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
    final client = _clientFactory();
    if (direct) {
      client.findProxy = (_) => 'DIRECT';
    }
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
      final remaining = remainingBudget?.call();
      if (remaining != null && remaining <= Duration.zero) {
        throw PluginHostError('timeout', 'Provider method budget exhausted');
      }
      final requested = Duration(milliseconds: timeout);
      final effective = remaining != null && remaining < requested
          ? remaining
          : requested;
      if (remaining != null) {
        client.connectionTimeout = effective < const Duration(seconds: 30)
            ? effective
            : const Duration(seconds: 30);
      }
      Future<Map<String, dynamic>> request() async {
        final suppliedHeaders = args['headers'];
        if (suppliedHeaders != null &&
            (suppliedHeaders is! Map ||
                suppliedHeaders.entries.any(
                  (entry) => entry.key is! String || entry.value is! String,
                ))) {
          throw PluginHostError(
            'invalid_argument',
            'Headers must contain strings',
          );
        }
        var headers = Map<String, String>.from(suppliedHeaders as Map? ?? {});
        var target = uri;
        var verb = method as String;
        var requestBody = args['body'] as String?;
        late HttpClientResponse response;
        for (var redirect = 0; ; redirect++) {
          final req = await client.openUrl(verb, target);
          req.followRedirects = direct;
          headers.forEach(req.headers.set);
          if (req.headers.value('user-agent') == null) {
            req.headers.set(
              'user-agent',
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
            );
          }
          if (requestBody != null) {
            req.add(utf8.encode(requestBody));
          }
          response = await req.close();
          if (direct ||
              !const {301, 302, 303, 307, 308}.contains(response.statusCode) ||
              response.headers.value('location') == null) {
            break;
          }
          if (redirect >= 5) {
            throw PluginHostError('network', 'Too many redirects');
          }
          final next = target.resolve(response.headers.value('location')!);
          if (!{'http', 'https'}.contains(next.scheme) ||
              next.host.isEmpty ||
              next.userInfo.isNotEmpty) {
            throw PluginHostError('invalid_url', 'Invalid redirect URL');
          }
          if (next.origin != target.origin) {
            // Provider-defined headers may carry credentials under arbitrary names.
            headers = {};
          }
          if (response.statusCode == 303 ||
              ((response.statusCode == 301 || response.statusCode == 302) &&
                  verb == 'POST')) {
            verb = 'GET';
            requestBody = null;
            headers.removeWhere(
              (key, _) => {
                'content-type',
                'content-length',
              }.contains(key.toLowerCase()),
            );
          }
          await response.drain<void>();
          target = next;
        }
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
        if (logResponses && _log.isDebugEnabled) {
          _log.debug('HTTP $target status=${response.statusCode} body=$body');
        }
        return {
          'status': response.statusCode,
          'url': response.redirects
              .fold(
                target,
                (url, redirect) => url.resolveUri(redirect.location),
              )
              .toString(),
          'headers': outputHeaders,
          'body': body,
        };
      }

      return await request().timeout(effective);
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
