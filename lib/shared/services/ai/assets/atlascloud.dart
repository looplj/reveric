// 职责: 用 API Key 调用 AtlasCloud Seedance 素材库（console 域名下的 /sd/assets）登记素材并查询状态。
// 关联文件:
//   lib/shared/services/ai/assets/client.dart
//   lib/shared/services/ai/assets/certification.dart
//   lib/shared/models/provider_asset.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../logger/app_logger.dart';
import '../../../models/provider_asset.dart';
import 'client.dart';

final _log = AppLogger.forModule('AtlasCloudAssets');

/// 素材名上限 64 个 UTF-8 字节。
const _maxNameBytes = 64;

class AtlasCloudAssetClient implements ProviderAssetClient {
  AtlasCloudAssetClient({
    required this.httpClient,
    required this.referenceUrl,
    required this.apiKey,
  });

  final http.Client httpClient;
  final ProviderAssetUrl referenceUrl;
  final String apiKey;

  /// 素材库在 console 域名下，生成接口所在的 api 域名对它返回 404。
  static final endpoint = Uri.parse(
    'https://console.atlascloud.ai/api/v1/sd/assets',
  );

  /// 创建返回整数 `id` 与 `atlas_asset_id`：前者只用于查询，后者才是 `asset://` 引用的 id。
  @override
  Future<ProviderAssetSubmission> submit({
    required ProviderAssetFile file,
    required String name,
  }) async {
    final url = await referenceUrl(file);
    final data = await _send(
      'POST',
      endpoint,
      body: {
        'url': url.toString(),
        'name': _truncate(name),
        'asset_type': 'Image',
      },
    );
    return (
      remoteId: data['atlas_asset_id'] as String,
      remoteTaskId: '${data['id'] as int}',
      remoteGroupId: null,
    );
  }

  @override
  Future<ProviderAssetState> state(String id) async {
    final data = await _send(
      'GET',
      endpoint.replace(path: '${endpoint.path}/$id'),
    );
    final status = switch (data['status']) {
      'Active' => ProviderAssetStatus.active,
      'Failed' => ProviderAssetStatus.failed,
      _ => ProviderAssetStatus.processing,
    };
    if (status != ProviderAssetStatus.failed) {
      return (status: status, errorCode: null, errorMessage: null);
    }
    _log.warning('asset failed id=$id data=${jsonEncode(data)}');
    return (
      status: status,
      errorCode: switch (data['error_code']) {
        final Object code when '$code'.isNotEmpty => '$code',
        _ => 'failed',
      },
      errorMessage: data['error_message'] as String?,
    );
  }

  @override
  void close() => httpClient.close();

  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri, {
    Map<String, dynamic>? body,
  }) async {
    final request = http.Request(method, uri)
      ..headers['Authorization'] = 'Bearer $apiKey';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await httpClient.send(request),
    );
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (_log.isDebugEnabled) {
      _log.debug("$method $uri status=${response.statusCode} body=$text");
    }
    Map<String, dynamic>? json;
    try {
      json = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {}
    // 成功时 code 是字符串 "200"，失败时是数字（如 40404）。
    final code = json?['code'];
    final data = json?['data'];
    if (response.statusCode != 200 || '$code' != '200' || data is! Map) {
      _log.error('$method $uri status=${response.statusCode} body=$text');
      throw ProviderAssetException(
        code == null ? 'http_${response.statusCode}' : '$code',
        json?['message'] as String? ?? text,
      );
    }
    return data.cast<String, dynamic>();
  }

  static String _truncate(String name) {
    final buffer = StringBuffer();
    var bytes = 0;
    for (final rune in name.runes) {
      final char = String.fromCharCode(rune);
      bytes += utf8.encode(char).length;
      if (bytes > _maxNameBytes) {
        break;
      }
      buffer.write(char);
    }
    return buffer.toString();
  }
}
