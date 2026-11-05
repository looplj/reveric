// 职责: 编排本地备份创建及可选的 WebDAV 同步上传。
// 关联文件:
//   lib/shared/services/backup_service.dart
//   lib/shared/services/webdav_backup_service.dart
//   lib/shared/models/webdav_backup_config.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md

import '../models/webdav_backup_config.dart';
import 'backup_service.dart';
import 'webdav_backup_service.dart';

class BackupOrchestrator {
  const BackupOrchestrator({
    required this._backupService,
    required this._webDavBackupService,
  });

  final BackupService _backupService;
  final WebDavBackupService _webDavBackupService;

  Future<BackupResult> createBackup({
    required String outputDirectory,
    required WebDavBackupConfig webDavConfig,
  }) async {
    final localResult = await _backupService.backupToZip(
      outputDirectory: outputDirectory,
    );
    return _uploadToWebDavIfNeeded(localResult, webDavConfig);
  }

  /// 移动端入口：备份写入临时目录，由调用方通过系统另存面板导出。
  Future<BackupResult> createTemporaryBackup({
    required WebDavBackupConfig webDavConfig,
  }) async {
    final localResult = await _backupService.backupToTemporaryZip();
    return _uploadToWebDavIfNeeded(localResult, webDavConfig);
  }

  Future<BackupResult> _uploadToWebDavIfNeeded(
    BackupResult localResult,
    WebDavBackupConfig webDavConfig,
  ) async {
    final backupPath = localResult.backupPath;
    if (!localResult.success || !webDavConfig.enabled || backupPath == null) {
      return localResult;
    }

    final remoteResult = await _webDavBackupService.uploadBackup(
      config: webDavConfig,
      localPath: backupPath,
    );
    if (remoteResult.success) {
      return localResult;
    }
    return BackupResult(
      success: false,
      failureReason: BackupFailureReason.webDavUploadFailed,
      warnings: localResult.warnings,
      backupPath: backupPath,
      errorMessage: remoteResult.failureReason?.name,
    );
  }
}
