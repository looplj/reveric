// 职责: 对象存储连接配置建模 — 服务类型、服务商预设推导、S3 兼容连接参数的规范化、校验与 JSON 编解码。
// 关联文件:
//   lib/shared/services/object_storage/service.dart
//   lib/shared/providers/object_storage.dart
//   lib/shared/widgets/settings/object_storage_form.dart
// 遵循的 Rules:
//   .agents/rules/json.md
//   .agents/rules/enum-naming.md

import 'dart:convert';

/// 对象存储服务类型；新增服务时在这里加值，并在 service 中接入对应客户端。
enum ObjectStorageProvider { s3 }

/// 设置界面的服务商预设：只决定 Endpoint、Region 与路径风格如何推导，
/// 持久化仍是通用 S3 配置，加载时按 Endpoint 反推。
enum ObjectStorageVendor {
  aliyun,
  tencent,
  cloudflare,
  aws,
  custom;

  static const cloudflareRegion = 'auto';

  /// 预设服务按此格式校验 Region / Account ID，避免拼出非法 Endpoint。
  static final _identifier = RegExp(r'^[a-z0-9][a-z0-9-]*$');
  static final _cloudflareEndpoint = RegExp(
    r'^https://([a-z0-9]+)\.r2\.cloudflarestorage\.com$',
  );

  /// 预设服务的寻址方式由服务商决定：阿里云、腾讯云要求虚拟主机风格。
  bool get pathStyle => this == cloudflare;

  /// [identifier] 对 Cloudflare 是 Account ID，其余预设是 Region；
  /// 自定义服务或格式非法时返回 null。
  String? endpointFor(String identifier) {
    if (!_identifier.hasMatch(identifier)) {
      return null;
    }
    return switch (this) {
      aliyun => 'https://s3.oss-$identifier.aliyuncs.com',
      tencent => 'https://cos.$identifier.myqcloud.com',
      cloudflare => 'https://$identifier.r2.cloudflarestorage.com',
      aws => 'https://s3.$identifier.amazonaws.com',
      custom => null,
    };
  }

  /// 按已保存配置反推预设及其 Region / Account ID；未配置时默认阿里云。
  static (ObjectStorageVendor, String) detect(ObjectStorageConfig config) {
    if (config.endpoint.isEmpty) {
      return (aliyun, '');
    }
    final account = _cloudflareEndpoint.firstMatch(config.endpoint)?.group(1);
    if (account != null &&
        config.region == cloudflareRegion &&
        config.pathStyle) {
      return (cloudflare, account);
    }
    for (final vendor in [aliyun, tencent, aws]) {
      if (!config.pathStyle &&
          vendor.endpointFor(config.region) == config.endpoint) {
        return (vendor, config.region);
      }
    }
    return (custom, '');
  }
}

enum ObjectStorageConfigIssue {
  invalid_endpoint,
  missing_region,
  missing_bucket,
  missing_access_key_id,
  missing_secret_access_key,
  invalid_key_prefix,
  invalid_public_base_url,
}

class ObjectStorageConfig {
  const ObjectStorageConfig({
    this.provider = ObjectStorageProvider.s3,
    this.endpoint = '',
    this.region = defaultRegion,
    this.bucket = '',
    this.accessKeyId = '',
    this.secretAccessKey = '',
    this.keyPrefix = defaultKeyPrefix,
    this.pathStyle = false,
    this.publicBaseUrl = '',
  });

  static const appSettingsKey = 'object_storage_settings';
  static const currentVersion = 1;
  static const defaultRegion = 'us-east-1';
  static const defaultKeyPrefix = 'reveric/references';

  final ObjectStorageProvider provider;
  final String endpoint;
  final String region;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;

  /// 对象 key 前缀，不含首尾 `/`。
  final String keyPrefix;

  /// true 时使用 `endpoint/bucket/key`，否则使用 `bucket.endpoint/key`。
  final bool pathStyle;

  /// 可选的公开访问地址（如 CDN 域名）；为空时返回预签名链接。
  final String publicBaseUrl;

  ObjectStorageConfig normalized() {
    return ObjectStorageConfig(
      provider: provider,
      endpoint: _trimTrailingSlash(endpoint.trim()),
      region: region.trim(),
      bucket: bucket.trim(),
      accessKeyId: accessKeyId.trim(),
      secretAccessKey: secretAccessKey.trim(),
      keyPrefix: keyPrefix
          .trim()
          .replaceAll('\\', '/')
          .split('/')
          .where((segment) => segment.isNotEmpty)
          .join('/'),
      pathStyle: pathStyle,
      publicBaseUrl: _trimTrailingSlash(publicBaseUrl.trim()),
    );
  }

  ObjectStorageConfigIssue? validate() {
    final config = normalized();
    if (!_isHttpUrl(config.endpoint)) {
      return ObjectStorageConfigIssue.invalid_endpoint;
    }
    if (config.region.isEmpty) {
      return ObjectStorageConfigIssue.missing_region;
    }
    if (config.bucket.isEmpty) {
      return ObjectStorageConfigIssue.missing_bucket;
    }
    if (config.accessKeyId.isEmpty) {
      return ObjectStorageConfigIssue.missing_access_key_id;
    }
    if (config.secretAccessKey.isEmpty) {
      return ObjectStorageConfigIssue.missing_secret_access_key;
    }
    if (config.keyPrefix
        .split('/')
        .any((segment) => segment == '.' || segment == '..')) {
      return ObjectStorageConfigIssue.invalid_key_prefix;
    }
    if (config.publicBaseUrl.isNotEmpty && !_isHttpUrl(config.publicBaseUrl)) {
      return ObjectStorageConfigIssue.invalid_public_base_url;
    }
    return null;
  }

  bool get isConfigured => validate() == null;

  bool get isEmpty =>
      normalized().encode() == const ObjectStorageConfig().encode();

  factory ObjectStorageConfig.decode(String? raw) {
    if (raw == null) {
      return const ObjectStorageConfig();
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw FormatException('$appSettingsKey must be a JSON object');
    }
    if (decoded['provider'] != 's3' ||
        decoded['version'] != currentVersion ||
        decoded['pathStyle'] is! bool) {
      throw const FormatException('Invalid object storage configuration');
    }
    String string(String key) {
      final value = decoded[key];
      if (value is! String) {
        throw FormatException('Invalid object storage field: $key');
      }
      return value;
    }

    return ObjectStorageConfig(
      provider: ObjectStorageProvider.s3,
      endpoint: string('endpoint'),
      region: string('region'),
      bucket: string('bucket'),
      accessKeyId: string('accessKeyId'),
      secretAccessKey: string('secretAccessKey'),
      keyPrefix: string('keyPrefix'),
      pathStyle: decoded['pathStyle'] as bool,
      publicBaseUrl: string('publicBaseUrl'),
    );
  }

  String encode() => jsonEncode(<String, dynamic>{
    'version': currentVersion,
    'provider': provider.name,
    'endpoint': endpoint,
    'region': region,
    'bucket': bucket,
    'accessKeyId': accessKeyId,
    'secretAccessKey': secretAccessKey,
    'keyPrefix': keyPrefix,
    'pathStyle': pathStyle,
    'publicBaseUrl': publicBaseUrl,
  });
}

String _trimTrailingSlash(String value) {
  var result = value;
  while (result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

bool _isHttpUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment;
}
