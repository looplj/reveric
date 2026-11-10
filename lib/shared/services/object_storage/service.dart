// 职责: 读写对象存储配置，按配置测试连接并上传文件、返回可供外部服务读取的地址。
// 关联文件:
//   lib/shared/models/object_storage_config.dart
//   lib/shared/services/object_storage/s3.dart
//   lib/shared/providers/object_storage.dart
//   lib/shared/database/daos/app_settings_dao.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';

import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/object_storage_config.dart';
import 's3.dart';

enum ObjectStorageFailure {
  invalid_configuration,
  connection_failed,
  unauthorized,
  bucket_not_found,
  upload_failed,
  read_failed,
}

typedef StoredObject = ({Uri url, DateTime? expiresAt});

final _log = AppLogger.forModule('ObjectStorage');

class ObjectStorageService {
  ObjectStorageService({
    required this.database,
    http.Client Function()? client,
    DateTime Function()? now,
  }) : _client = client ?? http.Client.new,
       _now = now ?? DateTime.now;

  /// 预签名链接的有效期；视频服务商通常在提交后很快拉取参考素材。
  static const presignedLifetime = Duration(hours: 24);
  static const _probeKey = '.reveric-connection-check';
  static const _probeBody = 'reveric';

  final AppDatabase database;
  final http.Client Function() _client;
  final DateTime Function() _now;

  Stream<ObjectStorageConfig> watch() => database.appSettingsDao
      .watch(ObjectStorageConfig.appSettingsKey)
      .map(ObjectStorageConfig.decode);

  Future<ObjectStorageConfig> load() async => ObjectStorageConfig.decode(
    await database.appSettingsDao.get(ObjectStorageConfig.appSettingsKey),
  );

  Future<void> save(ObjectStorageConfig config) async {
    final normalized = config.normalized();
    final issue = normalized.validate();
    if (issue != null) {
      throw ArgumentError.value(issue.name, 'config');
    }
    await _write(normalized);
  }

  /// 移除连接信息与凭据；保留默认空配置，不访问或删除远端对象。
  Future<void> clear() => _write(const ObjectStorageConfig());

  Future<void> _write(ObjectStorageConfig config) async {
    try {
      await database.appSettingsDao.set(
        key: ObjectStorageConfig.appSettingsKey,
        value: config.encode(),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=app_settings operation=UPSERT '
        'id=${ObjectStorageConfig.appSettingsKey} failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 写入一个固定探测对象，再通过实际会交给外部服务的地址读回；成功返回 null。
  Future<ObjectStorageFailure?> test(ObjectStorageConfig config) async {
    final normalized = config.normalized();
    if (normalized.validate() != null) {
      return ObjectStorageFailure.invalid_configuration;
    }
    final client = _client();
    final s3 = _s3(normalized, client);
    final key = _key(normalized, _probeKey);
    try {
      try {
        await s3
            .putBytes(key, utf8.encode(_probeBody), contentType: 'text/plain')
            .timeout(const Duration(seconds: 30));
      } catch (error, stackTrace) {
        _logFailure('test put', normalized, error, stackTrace);
        return _mapFailure(error);
      }
      try {
        final response = await client
            .get(_accessUrl(normalized, s3, key).url)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != HttpStatus.ok ||
            response.body != _probeBody) {
          throw S3Exception(response.statusCode, body: response.body);
        }
        return null;
      } catch (error, stackTrace) {
        _logFailure('test read', normalized, error, stackTrace);
        return ObjectStorageFailure.read_failed;
      }
    } finally {
      client.close();
    }
  }

  /// 按内容哈希命名对象；同一内容已存在时不重复上传。
  Future<StoredObject> upload(
    ObjectStorageConfig config, {
    required File file,
    required String sha256,
    required String mimeType,
    required int fileSize,
  }) async {
    final normalized = config.normalized();
    final extension = extensionFromMime(mimeType);
    final key = _key(
      normalized,
      extension == null ? sha256 : '$sha256.$extension',
    );
    final client = _client();
    final s3 = _s3(normalized, client);
    try {
      if (!await s3.exists(key)) {
        await s3.putFile(
          key,
          file,
          sha256: sha256,
          contentType: mimeType,
          length: fileSize,
        );
      }
      return _accessUrl(normalized, s3, key);
    } catch (error, stackTrace) {
      _logFailure('upload key=$key', normalized, error, stackTrace);
      rethrow;
    } finally {
      client.close();
    }
  }

  /// 新增服务类型时在这里接入对应客户端。
  S3Client _s3(ObjectStorageConfig config, http.Client client) =>
      switch (config.provider) {
        ObjectStorageProvider.s3 => S3Client(config, client, now: _now),
      };

  StoredObject _accessUrl(ObjectStorageConfig config, S3Client s3, String key) {
    if (config.publicBaseUrl.isNotEmpty) {
      return (
        url: Uri.parse('${config.publicBaseUrl}/${encodeS3Key(key)}'),
        expiresAt: null,
      );
    }
    return (
      url: s3.presignGet(key, presignedLifetime),
      // 留出余量，避免交给外部服务时恰好过期。
      expiresAt: _now().toUtc().add(
        presignedLifetime - const Duration(minutes: 5),
      ),
    );
  }

  String _key(ObjectStorageConfig config, String name) =>
      config.keyPrefix.isEmpty ? name : '${config.keyPrefix}/$name';

  ObjectStorageFailure _mapFailure(Object error) {
    if (error is S3Exception) {
      if (error.code == 'NoSuchBucket') {
        return ObjectStorageFailure.bucket_not_found;
      }
      if (error.statusCode == HttpStatus.unauthorized ||
          error.statusCode == HttpStatus.forbidden) {
        return ObjectStorageFailure.unauthorized;
      }
      return ObjectStorageFailure.upload_failed;
    }
    if (error is SocketException ||
        error is HttpException ||
        error is http.ClientException ||
        error is TimeoutException) {
      return ObjectStorageFailure.connection_failed;
    }
    return ObjectStorageFailure.upload_failed;
  }

  void _logFailure(
    String operation,
    ObjectStorageConfig config,
    Object error,
    StackTrace stackTrace,
  ) {
    _log.error(
      'object storage $operation failed, '
      'endpoint=${config.endpoint} bucket=${config.bucket}',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
