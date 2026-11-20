// 职责: 为一次 Provider 调用发放文件句柄并流式上传已授权文件。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/runtime.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'runtime.dart';
import '../../logger/app_logger.dart';

final _log = AppLogger.forModule('PluginFiles');

/// Host 创建并绑定一次调用；插件只能使用随机句柄。
class PluginFileScope {
  PluginFileScope({
    required this.pluginId,
    required this.providerId,
    required this.taskId,
  });
  final String pluginId, providerId, taskId;
  final _files =
      <String, ({File file, String name, String mimeType, int size})>{};
  bool _revoked = false;
  bool _claimed = false;

  Future<Map<String, dynamic>> register(
    File file, {
    required String name,
    required String mimeType,
    Map<String, dynamic>? mediaInfo,
  }) async {
    if (_revoked || _claimed) {
      throw PluginHostError(
        'permission_denied',
        'File scope is no longer accepting inputs',
      );
    }
    final size = await file.length();
    final digest = await sha256.bind(file.openRead()).first;
    if (_revoked || _claimed) {
      throw PluginHostError(
        'permission_denied',
        'File scope is no longer accepting inputs',
      );
    }
    final handle = const Uuid().v4();
    _files[handle] = (file: file, name: name, mimeType: mimeType, size: size);
    return {
      'handle': handle,
      'name': name,
      'mimeType': mimeType,
      'size': size,
      'sha256': digest.toString(),
      // 有些平台的票据接口要求客户端自己带宽高和时长，缺了会拒收。
      // 只在调用方探测到时带上，测不到就不给这个字段。
      'mediaInfo': ?mediaInfo,
    };
  }

  void claim({
    required String pluginId,
    required String providerId,
    required String? taskId,
  }) {
    if (_claimed ||
        _revoked ||
        this.pluginId != pluginId ||
        this.providerId != providerId ||
        this.taskId != taskId) {
      throw PluginHostError(
        'permission_denied',
        'File scope belongs to another invocation',
      );
    }
    _claimed = true;
  }

  ({File file, String name, String mimeType, int size}) resolve(
    Object? handle,
  ) {
    final file = _files[handle];
    if (_revoked || !_claimed || file == null) {
      throw PluginHostError(
        'permission_denied',
        'Unknown or expired file handle',
      );
    }
    return file;
  }

  void revoke() {
    _revoked = true;
    _files.clear();
  }
}

class PluginFilesApi {
  PluginFilesApi({
    required this.scope,
    required this.clientFactory,
    required this.remainingBudget,
  });
  final PluginFileScope scope;
  final HttpClient Function() clientFactory;
  final Duration Function() remainingBudget;
  final _clients = <HttpClient>{};
  final _cancelledSignal = Completer<void>();
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    scope.revoke();
    _cancelledSignal.complete();
    for (final client in _clients) {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> upload(Map<String, dynamic> args) async {
    if (_cancelled) {
      throw PluginHostError('cancelled', 'File upload cancelled');
    }
    final file = scope.resolve(args['handle']);
    final value = args['request'];
    if (value is! Map) {
      throw PluginHostError('invalid_request', 'Expected upload request');
    }
    final uri = value['url'] is String
        ? Uri.tryParse(value['url'] as String)
        : null;
    final kind = value['kind'];
    final timeout = value['timeoutMs'] ?? 600000;
    final method = kind == 'multipart' ? 'POST' : value['method'];
    final headers = value['headers'] ?? <String, String>{};
    final fields = value['fields'];
    bool strings(Object? value) =>
        value is Map &&
        value.entries.every((e) => e.key is String && e.value is String);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        !{'raw', 'multipart'}.contains(kind) ||
        !{'POST', 'PUT'}.contains(method) ||
        timeout is! int ||
        timeout < 1 ||
        timeout > 600000 ||
        !strings(headers) ||
        (kind == 'multipart' &&
            (!strings(fields) ||
                value['fileField'] is! String ||
                (value['fileField'] as String).isEmpty))) {
      throw PluginHostError('invalid_request', 'Invalid file upload options');
    }
    final remaining = remainingBudget();
    if (remaining <= Duration.zero) {
      throw PluginHostError('timeout', 'Provider method budget exhausted');
    }
    final requested = Duration(milliseconds: timeout);
    final effective = remaining < requested ? remaining : requested;
    final client = clientFactory();
    client.connectionTimeout = effective < const Duration(seconds: 30)
        ? effective
        : const Duration(seconds: 30);
    _clients.add(client);
    Future<Map<String, dynamic>> send() async {
      final request = await client.openUrl(method as String, uri);
      // Upload redirects are returned to the protocol implementation; never replay a file implicitly.
      request.followRedirects = false;
      (headers as Map).forEach(
        (key, value) => request.headers.set(key as String, value as String),
      );
      if (kind == 'multipart') {
        final multipart = http.MultipartRequest('POST', uri)
          ..fields.addAll(Map<String, String>.from(fields as Map))
          ..files.add(
            http.MultipartFile(
              value['fileField'] as String,
              file.file.openRead(),
              file.size,
              filename: file.name,
              contentType: http.MediaType.parse(file.mimeType),
            ),
          );
        final stream = multipart.finalize();
        request.headers.set(
          HttpHeaders.contentTypeHeader,
          multipart.headers[HttpHeaders.contentTypeHeader]!,
        );
        request.contentLength = multipart.contentLength;
        await request.addStream(stream);
      } else {
        request.contentLength = file.size;
        await request.addStream(file.file.openRead());
      }
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 5 * 1024 * 1024) {
          throw PluginHostError('too_large', 'Upload response exceeds 5 MB');
        }
        bytes.addAll(chunk);
      }
      if (_log.isDebugEnabled) {
        _log.debug(
          'HTTP $uri status=${response.statusCode} body=${utf8.decode(bytes, allowMalformed: true)}',
        );
      }
      final outputHeaders = <String, String>{};
      response.headers.forEach(
        (key, values) => outputHeaders[key] = values.join(', '),
      );
      return {
        'status': response.statusCode,
        'url': uri.toString(),
        'headers': outputHeaders,
        'body': utf8.decode(bytes, allowMalformed: true),
      };
    }

    try {
      return await Future.any([
        send(),
        _cancelledSignal.future.then<Map<String, dynamic>>(
          (_) => throw PluginHostError('cancelled', 'File upload cancelled'),
        ),
      ]).timeout(effective);
    } on TimeoutException {
      throw PluginHostError('timeout', 'File upload exceeded method budget');
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
    }
  }
}
