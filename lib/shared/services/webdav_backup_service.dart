// 职责: 使用 WebDAV 配置中的凭据提供备份上传、远程枚举和临时下载能力。
// 关联文件:
//   lib/shared/models/webdav_backup_config.dart
//   lib/shared/services/webdav_transport.dart
//   lib/shared/services/backup_orchestrator.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../logger/app_logger.dart';
import '../models/webdav_backup_config.dart';
import 'webdav_transport.dart';

enum WebDavFailureReason {
  invalidConfiguration,
  credentialUnavailable,
  unauthorized,
  connectionFailed,
  remoteDirectoryUnavailable,
  uploadFailed,
  listFailed,
  downloadFailed,
}

class WebDavOperationResult {
  const WebDavOperationResult.success() : success = true, failureReason = null;

  const WebDavOperationResult.failure(this.failureReason) : success = false;

  final bool success;
  final WebDavFailureReason? failureReason;
}

class WebDavListResult extends WebDavOperationResult {
  const WebDavListResult.success(this.files) : super.success();

  const WebDavListResult.failure(super.reason)
    : files = const <WebDavBackupFile>[],
      super.failure();

  final List<WebDavBackupFile> files;
}

class WebDavDownloadResult extends WebDavOperationResult {
  const WebDavDownloadResult.success(this.localPath) : super.success();

  const WebDavDownloadResult.failure(super.reason)
    : localPath = null,
      super.failure();

  final String? localPath;
}

final _log = AppLogger.forModule('WebDavBackup');

class WebDavBackupService {
  const WebDavBackupService({required this._transport});

  final WebDavTransport _transport;

  Future<WebDavOperationResult> test(WebDavBackupConfig config) async {
    final normalized = config.normalized();
    if (normalized.validate() != null) {
      return const WebDavOperationResult.failure(
        WebDavFailureReason.invalidConfiguration,
      );
    }
    final credentials = _credentials(normalized);
    if (credentials == null) {
      return const WebDavOperationResult.failure(
        WebDavFailureReason.credentialUnavailable,
      );
    }
    return _ensureDirectory(normalized, credentials);
  }

  Future<WebDavOperationResult> uploadBackup({
    required WebDavBackupConfig config,
    required String localPath,
  }) async {
    final normalized = config.normalized();
    if (normalized.validate() != null) {
      return const WebDavOperationResult.failure(
        WebDavFailureReason.invalidConfiguration,
      );
    }
    final credentials = _credentials(normalized);
    if (credentials == null) {
      return const WebDavOperationResult.failure(
        WebDavFailureReason.credentialUnavailable,
      );
    }
    try {
      await _transport.ensureDirectory(
        config: normalized,
        credentials: credentials,
      );
      await _transport.upload(
        config: normalized,
        credentials: credentials,
        localFile: File(localPath),
      );
      return const WebDavOperationResult.success();
    } catch (error, stackTrace) {
      _logTransportFailure('upload', normalized, error, stackTrace);
      return WebDavOperationResult.failure(_mapFailure(error, upload: true));
    }
  }

  Future<WebDavListResult> listBackups(WebDavBackupConfig config) async {
    final normalized = config.normalized();
    if (normalized.validate() != null) {
      return const WebDavListResult.failure(
        WebDavFailureReason.invalidConfiguration,
      );
    }
    final credentials = _credentials(normalized);
    if (credentials == null) {
      return const WebDavListResult.failure(
        WebDavFailureReason.credentialUnavailable,
      );
    }
    try {
      final files = await _transport.listBackups(
        config: normalized,
        credentials: credentials,
      );
      return WebDavListResult.success(files);
    } catch (error, stackTrace) {
      _logTransportFailure('list', normalized, error, stackTrace);
      return WebDavListResult.failure(_mapFailure(error, list: true));
    }
  }

  Future<WebDavDownloadResult> downloadBackup({
    required WebDavBackupConfig config,
    required WebDavBackupFile remoteFile,
  }) async {
    final normalized = config.normalized();
    if (normalized.validate() != null) {
      return const WebDavDownloadResult.failure(
        WebDavFailureReason.invalidConfiguration,
      );
    }
    final credentials = _credentials(normalized);
    if (credentials == null) {
      return const WebDavDownloadResult.failure(
        WebDavFailureReason.credentialUnavailable,
      );
    }
    File? destination;
    try {
      final tempDirectory = await getTemporaryDirectory();
      final restoreDirectory = Directory(
        p.join(tempDirectory.path, 'reveric_webdav_restore'),
      );
      await restoreDirectory.create(recursive: true);
      destination = File(
        p.join(
          restoreDirectory.path,
          '${DateTime.now().microsecondsSinceEpoch}_${remoteFile.name}',
        ),
      );
      await _transport.download(
        config: normalized,
        credentials: credentials,
        remotePath: remoteFile.remotePath,
        destination: destination,
      );
      return WebDavDownloadResult.success(destination.path);
    } catch (error, stackTrace) {
      if (destination != null && await destination.exists()) {
        await destination.delete();
      }
      _logTransportFailure('download', normalized, error, stackTrace);
      return WebDavDownloadResult.failure(_mapFailure(error, download: true));
    }
  }

  Future<void> deleteDownloadedBackup(String localPath) async {
    try {
      final file = File(localPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error, stackTrace) {
      _log.error(
        'failed to delete temporary WebDAV backup',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<WebDavOperationResult> _ensureDirectory(
    WebDavBackupConfig config,
    WebDavCredentials credentials,
  ) async {
    try {
      await _transport.ensureDirectory(
        config: config,
        credentials: credentials,
      );
      await _transport.listBackups(config: config, credentials: credentials);
      return const WebDavOperationResult.success();
    } catch (error, stackTrace) {
      _logTransportFailure('test', config, error, stackTrace);
      return WebDavOperationResult.failure(_mapFailure(error));
    }
  }

  WebDavCredentials? _credentials(WebDavBackupConfig config) {
    if (config.password.isEmpty) {
      return null;
    }
    return WebDavCredentials(
      username: config.username,
      password: config.password,
    );
  }

  WebDavFailureReason _mapFailure(
    Object error, {
    bool upload = false,
    bool list = false,
    bool download = false,
  }) {
    if (error is WebDavTransportException) {
      if (error.statusCode == HttpStatus.unauthorized ||
          error.statusCode == HttpStatus.forbidden) {
        return WebDavFailureReason.unauthorized;
      }
      if (error.statusCode == HttpStatus.notFound ||
          error.statusCode == HttpStatus.methodNotAllowed) {
        return WebDavFailureReason.remoteDirectoryUnavailable;
      }
    }
    if (error is SocketException || error is HttpException) {
      return WebDavFailureReason.connectionFailed;
    }
    if (upload) return WebDavFailureReason.uploadFailed;
    if (list) return WebDavFailureReason.listFailed;
    if (download) return WebDavFailureReason.downloadFailed;
    return WebDavFailureReason.remoteDirectoryUnavailable;
  }

  void _logTransportFailure(
    String operation,
    WebDavBackupConfig config,
    Object error,
    StackTrace stackTrace,
  ) {
    final uri = Uri.tryParse(config.serverUrl);
    _log.error(
      'WebDAV $operation failed, origin=${uri?.origin ?? 'invalid'}',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
