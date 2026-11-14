// 职责: 用 AK/SK 签名调用火山方舟私域素材库 OpenAPI（素材组查找/创建、素材上传与状态查询）。
// 关联文件:
//   lib/shared/services/ai/assets/client.dart
//   lib/shared/services/ai/assets/certification.dart
//   lib/shared/models/provider_asset.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../../logger/app_logger.dart';
import '../../../models/provider_asset.dart';
import 'client.dart';

final _log = AppLogger.forModule('VolcengineAssets');

typedef VolcengineAsset = ({
  String id,
  String groupId,
  ProviderAssetStatus status,
});

/// 所有素材进同一个组：同一次生成请求引用的私域素材必须属于同一素材组。
const providerAssetGroupName = 'reveric';

class VolcengineAssetClient implements ProviderAssetClient {
  VolcengineAssetClient({
    required this.httpClient,
    required this.referenceUrl,
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.projectName,
    DateTime Function()? now,
  }) : now = now ?? (() => DateTime.now().toUtc());

  final http.Client httpClient;
  final ProviderAssetUrl referenceUrl;
  final String accessKeyId;
  final String secretAccessKey;
  final String projectName;
  final DateTime Function() now;

  static const host = 'open.volcengineapi.com';
  static const region = 'cn-beijing';
  static const service = 'ark';
  static const version = '2024-01-01';

  /// 按名字精确找素材组，没有就创建；ListAssetGroups 的 Name 是模糊匹配，需要自己再比一次。
  Future<String> ensureGroup(String name) async {
    final result = await _call('ListAssetGroups', {
      'Filter': {'Name': name, 'GroupType': 'AIGC'},
      'MaxResults': 100,
      'ProjectName': projectName,
    });
    for (final item in (result['Items'] as List? ?? const [])) {
      final group = (item as Map).cast<String, dynamic>();
      if (group['Name'] == name) {
        return group['Id'] as String;
      }
    }
    final created = await _call('CreateAssetGroup', {
      'Name': name,
      'GroupType': 'AIGC',
      'ProjectName': projectName,
    });
    return created['Id'] as String;
  }

  Future<String> createAsset({
    required String groupId,
    required Uri url,
    required String assetType,
    required String name,
  }) async {
    final result = await _call('CreateAsset', {
      'GroupId': groupId,
      'URL': url.toString(),
      'AssetType': assetType,
      'Name': name,
      'ProjectName': projectName,
    });
    return result['Id'] as String;
  }

  @override
  Future<ProviderAssetSubmission> submit({
    required ProviderAssetFile file,
    required String name,
  }) async {
    final url = await referenceUrl(file);
    final groupId = await ensureGroup(providerAssetGroupName);
    final remoteId = await createAsset(
      groupId: groupId,
      url: url,
      assetType: 'Image',
      name: name,
    );
    return (remoteId: remoteId, remoteTaskId: null, remoteGroupId: groupId);
  }

  @override
  Future<ProviderAssetState> state(String id) async {
    final asset = await getAsset(id);
    return (
      status: asset.status,
      errorCode: asset.status == ProviderAssetStatus.failed ? 'failed' : null,
      errorMessage: null,
    );
  }

  @override
  void close() => httpClient.close();

  Future<VolcengineAsset> getAsset(String id) async {
    final result = await _call('GetAsset', {
      'Id': id,
      'ProjectName': projectName,
    });
    final status = switch (result['Status']) {
      'Active' => ProviderAssetStatus.active,
      'Failed' => ProviderAssetStatus.failed,
      _ => ProviderAssetStatus.processing,
    };
    if (status == ProviderAssetStatus.failed) {
      _log.warning('GetAsset failed id=$id result=${jsonEncode(result)}');
    }
    return (
      id: result['Id'] as String,
      groupId: result['GroupId'] as String,
      status: status,
    );
  }

  Future<Map<String, dynamic>> _call(
    String action,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.https(host, '/', {'Action': action, 'Version': version});
    final payload = utf8.encode(jsonEncode(body));
    final response = await httpClient.post(
      uri,
      headers: signedHeaders(uri, payload),
      body: payload,
    );
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (_log.isDebugEnabled) {
      _log.debug("$uri status=${response.statusCode} body=$text");
    }
    Map<String, dynamic>? json;
    try {
      json = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {}
    final error = ((json?['ResponseMetadata'] as Map?)?['Error'] as Map?)
        ?.cast<String, dynamic>();
    if (response.statusCode != 200 || error != null || json == null) {
      _log.error('action=$action status=${response.statusCode} body=$text');
      throw ProviderAssetException(
        error?['Code'] as String? ?? 'http_${response.statusCode}',
        error?['Message'] as String? ?? text,
      );
    }
    return (json['Result'] as Map? ?? const {}).cast<String, dynamic>();
  }

  /// 火山 OpenAPI V4 签名（HMAC-SHA256），签名头固定为 content-type、host、x-content-sha256、x-date。
  Map<String, String> signedHeaders(Uri uri, List<int> payload) {
    final time = now();
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${time.year}${two(time.month)}${two(time.day)}';
    final xDate =
        '${date}T${two(time.hour)}${two(time.minute)}${two(time.second)}Z';
    final payloadHash = sha256.convert(payload).toString();
    const contentType = 'application/json';
    final query =
        (uri.queryParameters.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key)))
            .map(
              (e) =>
                  '${Uri.encodeQueryComponent(e.key)}='
                  '${Uri.encodeQueryComponent(e.value)}',
            )
            .join('&');
    const signed = 'content-type;host;x-content-sha256;x-date';
    final canonical = [
      'POST',
      '/',
      query,
      'content-type:$contentType\n'
          'host:${uri.host}\n'
          'x-content-sha256:$payloadHash\n'
          'x-date:$xDate\n',
      signed,
      payloadHash,
    ].join('\n');
    final scope = '$date/$region/$service/request';
    final toSign = [
      'HMAC-SHA256',
      xDate,
      scope,
      sha256.convert(utf8.encode(canonical)).toString(),
    ].join('\n');
    List<int> hmac(List<int> key, String data) =>
        Hmac(sha256, key).convert(utf8.encode(data)).bytes;
    var key = hmac(utf8.encode(secretAccessKey), date);
    for (final part in [region, service, 'request']) {
      key = hmac(key, part);
    }
    final signature = Hmac(sha256, key).convert(utf8.encode(toSign));
    return {
      'Content-Type': contentType,
      'X-Date': xDate,
      'X-Content-Sha256': payloadHash,
      'Authorization':
          'HMAC-SHA256 Credential=$accessKeyId/$scope, '
          'SignedHeaders=$signed, Signature=$signature',
    };
  }
}
