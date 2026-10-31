// 职责: 流式备份与恢复数据库和媒体文件，并保持作品选择恢复的资产及任务关联。
// 关联文件:
//   lib/shared/widgets/settings/backup_settings_section.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/utils/windows_safe_path.dart
//   lib/shared/services/production/backup_media.dart

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import '../database/app_database.dart' show AppDatabase;
import '../database/novel_content_database.dart' show NovelContentDatabase;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'production/backup_media.dart';
import 'plugins/host.dart';
import 'plugins/runtime.dart';
import '../logger/app_logger.dart';
import '../models/mcp/config.dart';
import '../utils/storage_paths.dart';
import '../utils/windows_safe_path.dart';

final _log = AppLogger.forModule('Backup');

/// 是否支持把备份写入用户自选目录，同时决定是否支持自动备份。
///
/// 移动端 scoped storage 只允许应用写自己的私有目录：系统目录选择器返回的裸路径
/// 不携带 SAF 授权，直接用 `dart:io` 写会被拒绝，因此备份改为生成到临时目录后交
/// 给系统另存面板，自动备份也随之不可用。
bool backupSupportsCustomDirectory() {
  if (kIsWeb) {
    return false;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
  };
}

class BackupResult {
  final bool success;
  final BackupFailureReason? failureReason;
  final List<BackupWarning> warnings;
  final String? errorMessage;
  final String? backupPath;

  const BackupResult({
    required this.success,
    this.failureReason,
    this.warnings = const [],
    this.errorMessage,
    this.backupPath,
  });

  bool get hasWarnings => warnings.isNotEmpty;
}

class RestoreResult {
  final bool success;
  final bool cancelled;
  final RestoreFailureReason? failureReason;
  final bool needsRestart;
  final String? safetyBackupPath;
  final int restoredNovelCount;

  const RestoreResult({
    required this.success,
    this.cancelled = false,
    this.failureReason,
    this.needsRestart = false,
    this.safetyBackupPath,
    this.restoredNovelCount = 0,
  });
}

enum RestoreMode { fullReplacement, selectedNovels }

enum RestoreFailureReason {
  fileNotFound,
  invalidBackup,
  unsupportedBackup,
  noNovelsSelected,
  novelTitleConflict,
  safetyBackupFailed,
  applyFailed,
  rollbackFailed,
}

class BackupNovelSummary {
  const BackupNovelSummary({
    required this.id,
    required this.title,
    required this.existsInCurrentLibrary,
    required this.hasTitleConflict,
    required this.hasContentDatabase,
  });

  final String id;
  final String title;
  final bool existsInCurrentLibrary;
  final bool hasTitleConflict;
  final bool hasContentDatabase;

  bool get canRestore => !hasTitleConflict && hasContentDatabase;
}

class BackupRestorePreview {
  const BackupRestorePreview({
    required this.zipPath,
    required this.createdAt,
    required this.novels,
    required this.warningCount,
  });

  final String zipPath;
  final DateTime createdAt;
  final List<BackupNovelSummary> novels;
  final int warningCount;
}

class BackupInspectionResult {
  const BackupInspectionResult({
    required this.success,
    this.failureReason,
    this.preview,
  });

  final bool success;
  final RestoreFailureReason? failureReason;
  final BackupRestorePreview? preview;
}

enum BackupFailureReason {
  outputDirectoryUnavailable,
  sqlitePathUnsupportedOnWindows,
  sqliteUnreadable,
  webDavUploadFailed,
  unknown,
}

class BackupWarning {
  final String path;
  final String reason;

  const BackupWarning({required this.path, required this.reason});

  Map<String, dynamic> toJson() => {'path': path, 'reason': reason};
}

const _backupEntries = [
  'reveric.sqlite',
  'novel_workspaces',
  'avatars',
  'agent_avatars',
  'file_workspaces',
  'plugins',
  'plugin_data',
];

class BackupService {
  BackupService({this.pluginHost});
  final PluginHostService? pluginHost;
  static const _backupVersion = 1;

  /// 备份所有数据到 zip 包
  ///
  /// 使用 SQLite backup API 生成数据库快照，并打包小说封面、AI 图片、Agent 头像。
  Future<BackupResult> backupToZip({String? outputDirectory}) async {
    final host = pluginHost;
    if (host == null) {
      return _backupToZip(outputDirectory: outputDirectory);
    }
    return host.withPackageSnapshot(
      () => _backupToZip(outputDirectory: outputDirectory),
    );
  }

  Future<BackupResult> _backupToZip({String? outputDirectory}) async {
    _log.info('backupToZip started, outputDirectory=$outputDirectory');
    final warnings = <BackupWarning>[];
    try {
      final appSupportDir = await getApplicationSupportDirectory();
      _log.info('appSupportDir=${appSupportDir.path}');
      final outputDir = outputDirectory ?? appSupportDir.path;
      _log.info('outputDir=$outputDir');
      await _ensureOutputDirectoryWritable(outputDir);
      _log.info('output directory writable check passed');
      await _preflightSqliteSnapshots(appSupportDir);
      _ensurePluginInstallSettled(appSupportDir);
      _log.info('preflight SQLite snapshots passed');

      // 创建临时目录用于组装备份内容
      final tempDir = Directory(
        p.join(
          (await getTemporaryDirectory()).path,
          'reveric_backup_${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
      await tempDir.create(recursive: true);
      _log.info('tempDir created: ${tempDir.path}');

      try {
        // 1. 复制主数据库快照
        _log.info('Step 1/8: copying main SQLite snapshot');
        await _copySqliteSnapshotIfExists(
          p.join(appSupportDir.path, 'reveric.sqlite'),
          p.join(tempDir.path, 'reveric.sqlite'),
        );
        _log.info('Step 1/8: done');

        // 2. 复制小说工作区数据库快照
        _log.info('Step 2/8: copying novel workspace DBs');
        await _copyNovelWorkspaceDatabasesIfExists(
          p.join(appSupportDir.path, 'novel_workspaces'),
          p.join(tempDir.path, 'novel_workspaces'),
        );
        _log.info('Step 2/8: done');

        await _copyPluginDatabaseSnapshots(
          appSupportDir,
          Directory(p.join(tempDir.path, 'plugin_data')),
          pluginHost,
        );

        // 媒体文件集合只取决于目录，不查询资产或业务引用。
        for (final directory in _backupEntries.where(
          (entry) =>
              entry != 'reveric.sqlite' &&
              entry != 'novel_workspaces' &&
              entry != 'plugin_data',
        )) {
          await _copyDirIfExists(
            RevericPaths.resolveRelative(
              directory,
              support: appSupportDir.path,
            ),
            p.join(tempDir.path, directory),
            warnings: warnings,
          );
        }

        // 7. 写入备份版本、创建时间和告警。
        final manifest = {
          'version': _backupVersion,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          if (warnings.isNotEmpty)
            'warnings': warnings.map((w) => w.toJson()).toList(),
        };
        await File(
          p.join(tempDir.path, 'manifest.json'),
        ).writeAsString(jsonEncode(manifest));

        // 8. 打包为 zip（在 isolate 中执行，避免阻塞 UI）
        final ts = DateTime.now();
        final zipName =
            'reveric_backup_${ts.year}${_pad(ts.month)}${_pad(ts.day)}_${_pad(ts.hour)}${_pad(ts.minute)}${_pad(ts.second)}.zip';

        _log.info('Starting zip in isolate');
        final zipPath = await Isolate.run(
          () => _createZipFromDir(
            tempDirPath: tempDir.path,
            outputDirPath: outputDir,
            zipName: zipName,
          ),
        );
        _log.info('zip created: $zipPath');

        return BackupResult(
          success: true,
          backupPath: zipPath,
          warnings: List.unmodifiable(warnings),
        );
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    } on _BackupFailure catch (e) {
      _log.error('Backup failed: ${e.message}', error: e);
      return BackupResult(
        success: false,
        failureReason: e.reason,
        errorMessage: e.message,
        warnings: List.unmodifiable(warnings),
      );
    } catch (e) {
      _log.error('Backup failed', error: e);
      return BackupResult(
        success: false,
        failureReason: BackupFailureReason.unknown,
        errorMessage: 'Backup failed',
        warnings: List.unmodifiable(warnings),
      );
    }
  }

  /// 备份到系统临时目录，供移动端交给系统另存面板导出。
  ///
  /// 临时文件由系统回收；调用方必须在另存成功后才认为备份已落地。
  Future<BackupResult> backupToTemporaryZip() async {
    final outputDir = Directory(
      p.join(
        (await getTemporaryDirectory()).path,
        'reveric_backup_share_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await outputDir.create(recursive: true);
    return backupToZip(outputDirectory: outputDir.path);
  }

  /// 校验备份包并读取可恢复小说，不修改当前数据。
  Future<BackupInspectionResult> inspectBackup(String zipPath) async {
    final zipFile = File(zipPath);
    if (!await zipFile.exists()) {
      return const BackupInspectionResult(
        success: false,
        failureReason: RestoreFailureReason.fileNotFound,
      );
    }

    final extractDir = await _createRestoreExtractDirectory();
    try {
      await Isolate.run(
        () => _extractZipSafely(
          zipPath: zipPath,
          extractDirPath: extractDir.path,
        ),
      );
      final appSupportDir = await getApplicationSupportDirectory();
      final backup = _readExtractedBackup(
        sourceDir: extractDir,
        zipPath: zipPath,
        appSupportDir: appSupportDir,
        expectedVersion: _backupVersion,
      );
      return BackupInspectionResult(success: true, preview: backup.preview);
    } on _RestoreValidationFailure catch (error) {
      return BackupInspectionResult(
        success: false,
        failureReason: error.reason,
      );
    } catch (error, stackTrace) {
      _log.error(
        'Restore inspection failed path=$zipPath',
        error: error,
        stackTrace: stackTrace,
      );
      return const BackupInspectionResult(
        success: false,
        failureReason: RestoreFailureReason.invalidBackup,
      );
    } finally {
      await _deleteDirectoryIfExists(extractDir);
    }
  }

  /// 从 zip 包完整覆盖或按小说覆盖当前数据。
  ///
  /// [onBeforeFileRestore] 在安全备份创建并通过校验后执行。调用方应释放
  /// 即将被替换的数据库文件；选择小说恢复时主库可保持连接。
  Future<RestoreResult> restoreFromZip(
    String zipPath, {
    required RestoreMode mode,
    Set<String> novelIds = const <String>{},
    Future<void> Function()? onBeforeFileRestore,
  }) async {
    var needsRestart = false;
    String? safetyBackupPath;
    Directory? extractDir;
    try {
      final zipFile = File(zipPath);
      if (!await zipFile.exists()) {
        return const RestoreResult(
          success: false,
          failureReason: RestoreFailureReason.fileNotFound,
        );
      }

      _log.info('Restore: extracting zip in isolate');
      extractDir = await _createRestoreExtractDirectory();
      await Isolate.run(
        () => _extractZipSafely(
          zipPath: zipPath,
          extractDirPath: extractDir!.path,
        ),
      );
      _log.info('Restore: zip extracted');

      final appSupportDir = await getApplicationSupportDirectory();
      final backup = _readExtractedBackup(
        sourceDir: extractDir,
        zipPath: zipPath,
        appSupportDir: appSupportDir,
        expectedVersion: _backupVersion,
      );
      final selectedIds = mode == RestoreMode.selectedNovels
          ? Set<String>.unmodifiable(novelIds)
          : backup.novelRows.keys.toSet();
      if (mode == RestoreMode.selectedNovels && selectedIds.isEmpty) {
        return const RestoreResult(
          success: false,
          failureReason: RestoreFailureReason.noNovelsSelected,
        );
      }
      for (final novelId in selectedIds) {
        final summary = backup.preview.novels
            .where((novel) => novel.id == novelId)
            .firstOrNull;
        if (summary == null) {
          throw const _RestoreValidationFailure(
            RestoreFailureReason.invalidBackup,
          );
        }
        if (mode == RestoreMode.selectedNovels && summary.hasTitleConflict) {
          return const RestoreResult(
            success: false,
            failureReason: RestoreFailureReason.novelTitleConflict,
          );
        }
        if (mode == RestoreMode.selectedNovels && !summary.hasContentDatabase) {
          return const RestoreResult(
            success: false,
            failureReason: RestoreFailureReason.invalidBackup,
          );
        }
      }

      safetyBackupPath = await _createRestoreSafetyBackup(appSupportDir);
      if (safetyBackupPath == null) {
        return const RestoreResult(
          success: false,
          failureReason: RestoreFailureReason.safetyBackupFailed,
        );
      }

      await pluginHost?.shutdownForRestore();
      needsRestart = true;
      if (onBeforeFileRestore != null) {
        _log.info('Restore: running pre-file-restore hook mode=${mode.name}');
        await onBeforeFileRestore();
        _log.info('Restore: pre-file-restore hook completed');
      }

      if (mode == RestoreMode.fullReplacement) {
        await _replaceAllBackupEntries(
          sourceDir: extractDir,
          appSupportDir: appSupportDir,
        );
      } else {
        await _replaceSelectedNovels(
          sourceDir: extractDir,
          appSupportDir: appSupportDir,
          novelRows: backup.novelRows,
          selectedIds: selectedIds,
        );
      }

      _log.info(
        'Restore completed mode=${mode.name} novelCount=${selectedIds.length}',
      );
      return RestoreResult(
        success: true,
        needsRestart: true,
        safetyBackupPath: safetyBackupPath,
        restoredNovelCount: selectedIds.length,
      );
    } on _RestoreValidationFailure catch (error) {
      return RestoreResult(
        success: false,
        failureReason: error.reason,
        needsRestart: needsRestart,
        safetyBackupPath: safetyBackupPath,
      );
    } on _RestoreApplyFailure catch (error, stackTrace) {
      _log.error(
        'Restore apply failed rollbackFailed=${error.rollbackFailed}',
        error: error.cause,
        stackTrace: stackTrace,
      );
      return RestoreResult(
        success: false,
        failureReason: error.rollbackFailed
            ? RestoreFailureReason.rollbackFailed
            : RestoreFailureReason.applyFailed,
        needsRestart: needsRestart,
        safetyBackupPath: safetyBackupPath,
      );
    } catch (error, stackTrace) {
      if (error is PluginHostError && error.code == 'cancelled') {
        return RestoreResult(
          success: false,
          cancelled: true,
          safetyBackupPath: safetyBackupPath,
        );
      }
      _log.error('Restore failed', error: error, stackTrace: stackTrace);
      return RestoreResult(
        success: false,
        failureReason: RestoreFailureReason.applyFailed,
        needsRestart: needsRestart,
        safetyBackupPath: safetyBackupPath,
      );
    } finally {
      if (extractDir != null) {
        await _deleteDirectoryIfExists(extractDir);
      }
    }
  }

  Future<String?> _createRestoreSafetyBackup(Directory appSupportDir) async {
    final safetyDirectory = Directory(
      p.join(appSupportDir.path, 'restore_backups'),
    );
    await safetyDirectory.create(recursive: true);
    final result = await backupToZip(outputDirectory: safetyDirectory.path);
    final sourcePath = result.backupPath;
    if (!result.success || result.hasWarnings || sourcePath == null) {
      _log.error(
        'Restore safety backup failed success=${result.success} warnings=${result.warnings.length}',
      );
      return null;
    }

    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final safetyPath = p.join(
      safetyDirectory.path,
      'reveric_before_restore_$timestamp.zip',
    );
    await File(sourcePath).rename(safetyPath);
    _log.info('Restore safety backup created path=$safetyPath');
    return safetyPath;
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}

Future<Directory> _createRestoreExtractDirectory() async {
  final directory = Directory(
    p.join(
      (await getTemporaryDirectory()).path,
      'reveric_restore_${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  await directory.create(recursive: true);
  return directory;
}

/// 在读取业务表和 JSON 前检查所有快照，只接受当前数据库版本。
void _validateBackupSchemas(Directory sourceDir) {
  void check(File file, int supported) {
    final database = sqlite3.open(
      toWindowsSafePath(file.path),
      mode: OpenMode.readOnly,
    );
    try {
      final version =
          database.select('PRAGMA user_version').single['user_version'] as int;
      if (version != supported) {
        throw const _RestoreValidationFailure(
          RestoreFailureReason.unsupportedBackup,
        );
      }
    } finally {
      database.close();
    }
  }

  check(
    File(p.join(sourceDir.path, 'reveric.sqlite')),
    AppDatabase.currentSchemaVersion,
  );
  final workspaces = Directory(p.join(sourceDir.path, 'novel_workspaces'));
  if (workspaces.existsSync()) {
    for (final file in workspaces.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (file is File && p.extension(file.path) == '.sqlite') {
        check(file, NovelContentDatabase.currentSchemaVersion);
      }
    }
  }
}

_ExtractedBackup _readExtractedBackup({
  required Directory sourceDir,
  required Directory appSupportDir,
  required String zipPath,
  required int expectedVersion,
}) {
  final manifestFile = File(p.join(sourceDir.path, 'manifest.json'));
  final backupDatabaseFile = File(p.join(sourceDir.path, 'reveric.sqlite'));
  if (!manifestFile.existsSync() || !backupDatabaseFile.existsSync()) {
    throw const _RestoreValidationFailure(RestoreFailureReason.invalidBackup);
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(manifestFile.readAsStringSync());
  } catch (_) {
    throw const _RestoreValidationFailure(RestoreFailureReason.invalidBackup);
  }
  if (decoded is! Map<String, dynamic>) {
    throw const _RestoreValidationFailure(RestoreFailureReason.invalidBackup);
  }
  if (decoded['version'] != expectedVersion) {
    throw const _RestoreValidationFailure(
      RestoreFailureReason.unsupportedBackup,
    );
  }
  _validateBackupSchemas(sourceDir);
  final createdAt = DateTime.tryParse(decoded['createdAt'] as String? ?? '');
  if (createdAt == null) {
    throw const _RestoreValidationFailure(RestoreFailureReason.invalidBackup);
  }
  final warnings = decoded['warnings'];
  final warningCount = warnings is List<Object?> ? warnings.length : 0;

  final backupDb = sqlite3.open(
    toWindowsSafePath(backupDatabaseFile.path),
    mode: OpenMode.readOnly,
  );
  final novelRows = <String, Map<String, Object?>>{};
  try {
    final rows = backupDb.select(
      'SELECT * FROM novels WHERE deleted_at = 0 AND draft = 0',
    );
    for (final row in rows) {
      final id = row['id'] as String?;
      final title = row['title'] as String?;
      if (id == null || title == null) {
        throw const _RestoreValidationFailure(
          RestoreFailureReason.invalidBackup,
        );
      }
      novelRows[id] = Map<String, Object?>.from(row);
    }
  } finally {
    backupDb.close();
  }

  final currentById = <String, String>{};
  final currentIdByTitle = <String, String>{};
  final currentDatabasePath = p.join(appSupportDir.path, 'reveric.sqlite');
  if (File(currentDatabasePath).existsSync()) {
    final currentDb = sqlite3.open(
      toWindowsSafePath(currentDatabasePath),
      mode: OpenMode.readOnly,
    );
    try {
      for (final row in currentDb.select(
        'SELECT id, title, draft FROM novels WHERE deleted_at = 0',
      )) {
        final id = row['id'] as String;
        final title = row['title'] as String;
        currentById[id] = title;
        if (row['draft'] != 1) {
          currentIdByTitle[title] = id;
        }
      }
    } finally {
      currentDb.close();
    }
  }

  final novels = novelRows.values.map((row) {
    final id = row['id'] as String;
    final title = row['title'] as String;
    final contentPath = row['content_database_path'] as String?;
    final contentRelativePath = _backupRelativePath(contentPath);
    final hasContentDatabase =
        contentRelativePath != null &&
        File(p.join(sourceDir.path, contentRelativePath)).existsSync();
    final currentIdWithTitle = currentIdByTitle[title];
    return BackupNovelSummary(
      id: id,
      title: title,
      existsInCurrentLibrary: currentById.containsKey(id),
      hasTitleConflict: currentIdWithTitle != null && currentIdWithTitle != id,
      hasContentDatabase: hasContentDatabase,
    );
  }).toList()..sort((a, b) => a.title.compareTo(b.title));

  return _ExtractedBackup(
    novelRows: Map<String, Map<String, Object?>>.unmodifiable(novelRows),
    preview: BackupRestorePreview(
      zipPath: zipPath,
      createdAt: createdAt,
      novels: List<BackupNovelSummary>.unmodifiable(novels),
      warningCount: warningCount,
    ),
  );
}

Future<void> _replaceAllBackupEntries({
  required Directory sourceDir,
  required Directory appSupportDir,
}) async {
  final ledger = _RollbackLedger();
  try {
    for (final entryName in _backupEntries) {
      final targetPath = RevericPaths.resolveRelative(
        entryName,
        support: appSupportDir.path,
      );
      await ledger.moveAside(targetPath);
      if (entryName == 'reveric.sqlite') {
        await ledger.moveAside('$targetPath-wal');
        await ledger.moveAside('$targetPath-shm');
      }
    }

    for (final entryName in _backupEntries) {
      final source = _entityForPath(p.join(sourceDir.path, entryName));
      if (await source.exists()) {
        await _copyBackupEntry(
          source,
          RevericPaths.resolveRelative(entryName, support: appSupportDir.path),
        );
      }
    }
    _disableRestoredMcpServers(p.join(appSupportDir.path, 'reveric.sqlite'));
    await ledger.discard();
  } catch (error, stackTrace) {
    _log.error(
      'Full restore failed, rolling back',
      error: error,
      stackTrace: stackTrace,
    );
    try {
      await ledger.rollback();
    } catch (rollbackError, rollbackStackTrace) {
      _log.error(
        'Full restore rollback failed',
        error: rollbackError,
        stackTrace: rollbackStackTrace,
      );
      throw _RestoreApplyFailure(error, rollbackFailed: true);
    }
    throw _RestoreApplyFailure(error);
  }
}

void _disableRestoredMcpServers(String databasePath) {
  final database = sqlite3.open(databasePath);
  String? rawConfiguration;
  try {
    final table = database.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='app_settings'",
    );
    if (table.isEmpty) {
      return;
    }
    final rows = database.select(
      'SELECT value FROM app_settings WHERE key = ?',
      [McpSettings.key],
    );
    if (rows.isEmpty) {
      return;
    }
    rawConfiguration = rows.single['value'] as String;
    final restored = McpSettings.decode(rawConfiguration).disabledForRestore();
    database.execute('UPDATE app_settings SET value = ? WHERE key = ?', [
      restored.encode(),
      McpSettings.key,
    ]);
  } catch (error, stackTrace) {
    _log.error(
      '[DB] app_settings UPDATE id=mcp_servers during restore failed',
      error: rawConfiguration == null
          ? error.toString()
          : error.toString().replaceAll(
              rawConfiguration,
              '[MCP configuration]',
            ),
      stackTrace: stackTrace,
    );
    rethrow;
  } finally {
    database.close();
  }
}

Future<void> _replaceSelectedNovels({
  required Directory sourceDir,
  required Directory appSupportDir,
  required Map<String, Map<String, Object?>> novelRows,
  required Set<String> selectedIds,
}) async {
  final currentDatabasePath = p.join(appSupportDir.path, 'reveric.sqlite');
  if (!await File(currentDatabasePath).exists()) {
    throw const _RestoreValidationFailure(RestoreFailureReason.invalidBackup);
  }

  final plans = _buildSelectedNovelPlans(
    sourceDir: sourceDir,
    appSupportDir: appSupportDir,
    currentDatabasePath: currentDatabasePath,
    novelRows: novelRows,
    selectedIds: selectedIds,
  );
  final ledger = _RollbackLedger();
  try {
    for (final plan in plans) {
      final sourceContentPath = plan.sourceContentPath;
      final targetContentPath = plan.targetContentPath;
      await _moveSqliteAside(ledger, plan.currentContentPath);
      await _moveSqliteAside(ledger, targetContentPath);
      await Directory(p.dirname(targetContentPath)).create(recursive: true);
      await _copySqliteSnapshotIfExists(sourceContentPath, targetContentPath);
    }

    await _restoreSelectedMediaDirectories(
      sourceDir,
      appSupportDir,
      selectedIds,
      ledger,
    );

    final media = collectSelectedMedia(
      backup: sourceDir,
      novelIds: selectedIds,
      contentPaths: plans.map((plan) => plan.sourceContentPath),
      coverAssetIds: plans
          .map((plan) => plan.row['cover_asset_id'])
          .whereType<String>(),
    );
    _upsertSelectedNovelRows(
      currentDatabasePath: currentDatabasePath,
      plans: plans,
      mediaRows: media.rows,
    );
    await ledger.discard();
  } catch (error, stackTrace) {
    _log.error(
      'Selected novel restore failed, rolling back',
      error: error,
      stackTrace: stackTrace,
    );
    try {
      await ledger.rollback();
    } catch (rollbackError, rollbackStackTrace) {
      _log.error(
        'Selected novel restore rollback failed',
        error: rollbackError,
        stackTrace: rollbackStackTrace,
      );
      throw _RestoreApplyFailure(error, rollbackFailed: true);
    }
    throw _RestoreApplyFailure(error);
  }
}

List<_SelectedNovelPlan> _buildSelectedNovelPlans({
  required Directory sourceDir,
  required Directory appSupportDir,
  required String currentDatabasePath,
  required Map<String, Map<String, Object?>> novelRows,
  required Set<String> selectedIds,
}) {
  final currentDb = sqlite3.open(
    toWindowsSafePath(currentDatabasePath),
    mode: OpenMode.readOnly,
  );
  try {
    final plans = <_SelectedNovelPlan>[];
    for (final novelId in selectedIds) {
      final backupRow = novelRows[novelId];
      if (backupRow == null) {
        throw const _RestoreValidationFailure(
          RestoreFailureReason.invalidBackup,
        );
      }
      final title = backupRow['title'] as String;
      final titleRows = currentDb.select(
        'SELECT id FROM novels WHERE title = ?'
        ' AND deleted_at = 0 AND draft = 0 LIMIT 1',
        <Object?>[title],
      );
      if (titleRows.isNotEmpty && titleRows.first['id'] != novelId) {
        throw const _RestoreValidationFailure(
          RestoreFailureReason.novelTitleConflict,
        );
      }

      final currentRows = currentDb.select(
        'SELECT * FROM novels WHERE id = ? LIMIT 1',
        <Object?>[novelId],
      );
      final currentRow = currentRows.isEmpty
          ? null
          : Map<String, Object?>.from(currentRows.first);
      final contentRelativePath = _backupRelativePath(
        backupRow['content_database_path'] as String?,
      );
      if (contentRelativePath == null) {
        throw const _RestoreValidationFailure(
          RestoreFailureReason.invalidBackup,
        );
      }
      final sourceContentPath = p.join(sourceDir.path, contentRelativePath);
      plans.add(
        _SelectedNovelPlan(
          row: backupRow,
          contentRelativePath: contentRelativePath,
          sourceContentPath: sourceContentPath,
          targetContentPath: p.join(appSupportDir.path, contentRelativePath),
          currentContentPath: _currentStoredPath(
            currentRow?['content_database_path'] as String?,
            appSupportDir.path,
          ),
        ),
      );
    }
    return plans;
  } finally {
    currentDb.close();
  }
}

void _upsertSelectedNovelRows({
  required String currentDatabasePath,
  required List<_SelectedNovelPlan> plans,
  required Map<String, List<Map<String, Object?>>> mediaRows,
}) {
  final currentDb = sqlite3.open(toWindowsSafePath(currentDatabasePath));
  var transactionStarted = false;
  try {
    currentDb.execute('BEGIN IMMEDIATE');
    transactionStarted = true;
    for (final plan in plans) {
      final valuesByColumn = {
        ...plan.row,
        'content_database_path': plan.contentRelativePath,
      };
      final columns = valuesByColumn.keys.toList(growable: false);
      final updateColumns = columns.where((column) => column != 'id').toList();
      final quotedColumns = columns.map(_quoteIdentifier).join(', ');
      final placeholders = List.filled(columns.length, '?').join(', ');
      final updates = updateColumns
          .map(
            (column) =>
                '${_quoteIdentifier(column)} = excluded.${_quoteIdentifier(column)}',
          )
          .join(', ');
      currentDb.execute(
        'INSERT INTO novels ($quotedColumns) VALUES ($placeholders) '
        'ON CONFLICT(id) DO UPDATE SET $updates',
        columns.map((column) => valuesByColumn[column]).toList(),
      );
    }
    for (final table in [
      'assets',
      'image_batches',
      'image_batch_slots',
      'image_asset_references',
      'generation_tasks',
    ]) {
      final incoming = mediaRows[table] ?? const <Map<String, Object?>>[];
      if (incoming.isEmpty) {
        continue;
      }
      for (final values in incoming) {
        final names = values.keys.toList();
        final updates = names
            .where((name) => name != 'id')
            .map((name) => '"$name"=excluded."$name"')
            .join(',');
        currentDb.execute(
          'INSERT INTO "$table" (${names.map(_quoteIdentifier).join(',')}) VALUES (${List.filled(names.length, '?').join(',')}) ON CONFLICT(id) DO UPDATE SET $updates',
          values.values.toList(),
        );
      }
      _log.info('[DB][$table][UPSERT] restored count=${incoming.length}');
    }
    currentDb.execute('COMMIT');
    transactionStarted = false;
    _log.info(
      '[DB][novels][UPSERT] restore succeeded ids=${plans.map((plan) => plan.id).join(',')}',
    );
  } catch (error, stackTrace) {
    if (transactionStarted) {
      currentDb.execute('ROLLBACK');
    }
    _log.error(
      '[DB][novels][UPSERT] restore failed ids=${plans.map((plan) => plan.id).join(',')}',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  } finally {
    currentDb.close();
  }
}

String? _backupRelativePath(String? storedPath) {
  if (storedPath == null || storedPath.isEmpty) {
    return null;
  }
  final syntax = RevericPaths.contextForStoredPath(storedPath);
  final segments = syntax.split(storedPath);
  if (syntax.isAbsolute(storedPath) ||
      segments.length != 2 ||
      segments.first != 'novel_workspaces' ||
      segments.contains('..') ||
      segments.contains('.') ||
      !segments.last.endsWith('.sqlite') ||
      segments.last.contains(':')) {
    return null;
  }
  return p.joinAll(segments);
}

String? _currentStoredPath(String? storedPath, String appSupportDir) {
  if (storedPath == null) {
    return null;
  }
  final relative = _backupRelativePath(storedPath);
  if (relative == null) {
    throw const _RestoreValidationFailure(RestoreFailureReason.invalidBackup);
  }
  return p.join(appSupportDir, relative);
}

String _quoteIdentifier(String value) {
  return '"${value.replaceAll('"', '""')}"';
}

Future<void> _moveSqliteAside(
  _RollbackLedger ledger,
  String? sqlitePath,
) async {
  await ledger.moveAside(sqlitePath);
  if (sqlitePath != null) {
    await ledger.moveAside('$sqlitePath-wal');
    await ledger.moveAside('$sqlitePath-shm');
  }
}

FileSystemEntity _entityForPath(String path) {
  return switch (FileSystemEntity.typeSync(path)) {
    FileSystemEntityType.directory => Directory(path),
    _ => File(path),
  };
}

Future<void> _copyBackupEntry(
  FileSystemEntity source,
  String destinationPath,
) async {
  if (source is File && p.extension(source.path) == '.sqlite') {
    await _copySqliteSnapshotIfExists(source.path, destinationPath);
  } else if (source is Directory &&
      p.basename(source.path) == 'novel_workspaces') {
    await _copyNovelWorkspaceDatabasesIfExists(source.path, destinationPath);
  } else if (source is Directory) {
    await _copyDirContents(source, Directory(destinationPath));
  } else if (source is File) {
    await Directory(p.dirname(destinationPath)).create(recursive: true);
    await source.copy(destinationPath);
  }
}

Future<void> _deleteDirectoryIfExists(Directory directory) async {
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
}

class _ExtractedBackup {
  const _ExtractedBackup({required this.novelRows, required this.preview});

  final Map<String, Map<String, Object?>> novelRows;
  final BackupRestorePreview preview;
}

class _SelectedNovelPlan {
  const _SelectedNovelPlan({
    required this.row,
    required this.contentRelativePath,
    required this.sourceContentPath,
    required this.targetContentPath,
    required this.currentContentPath,
  });

  final Map<String, Object?> row;
  final String contentRelativePath;
  final String sourceContentPath;
  final String targetContentPath;
  final String? currentContentPath;

  String get id => row['id'] as String;
}

class _RestoreValidationFailure implements Exception {
  const _RestoreValidationFailure(this.reason);

  final RestoreFailureReason reason;
}

class _RestoreApplyFailure implements Exception {
  const _RestoreApplyFailure(this.cause, {this.rollbackFailed = false});

  final Object cause;
  final bool rollbackFailed;
}

class _RollbackLedger {
  final Map<String, _RollbackEntry> _entries = <String, _RollbackEntry>{};

  Future<void> moveAside(String? targetPath) async {
    if (targetPath == null || targetPath.isEmpty) {
      return;
    }
    final normalizedTarget = p.normalize(targetPath);
    if (_entries.containsKey(normalizedTarget)) {
      return;
    }
    final type = await FileSystemEntity.type(normalizedTarget);
    if (type == FileSystemEntityType.notFound) {
      _entries[normalizedTarget] = const _RollbackEntry();
      return;
    }
    final rollbackDirectory = await Directory(
      p.dirname(normalizedTarget),
    ).createTemp('.reveric_restore_rollback_');
    final rollbackPath = p.join(rollbackDirectory.path, 'original');
    await _renameEntity(normalizedTarget, rollbackPath, type);
    _entries[normalizedTarget] = _RollbackEntry(
      rollbackPath: rollbackPath,
      type: type,
    );
  }

  Future<void> rollback() async {
    for (final entry in _entries.entries.toList().reversed) {
      await _deleteEntityIfExists(entry.key);
      final rollbackPath = entry.value.rollbackPath;
      if (rollbackPath != null) {
        await Directory(p.dirname(entry.key)).create(recursive: true);
        await _renameEntity(rollbackPath, entry.key, entry.value.type!);
        await Directory(p.dirname(rollbackPath)).delete();
      }
    }
  }

  Future<void> discard() async {
    try {
      for (final entry in _entries.values) {
        if (entry.rollbackPath case final path?) {
          await _deleteDirectoryIfExists(Directory(p.dirname(path)));
        }
      }
    } catch (error, stackTrace) {
      _log.error(
        'Could not remove restore rollback files',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

class _RollbackEntry {
  const _RollbackEntry({this.rollbackPath, this.type});

  final String? rollbackPath;
  final FileSystemEntityType? type;
}

Future<void> _renameEntity(
  String sourcePath,
  String targetPath,
  FileSystemEntityType type,
) async {
  if (type == FileSystemEntityType.directory) {
    await Directory(sourcePath).rename(targetPath);
  } else {
    await File(sourcePath).rename(targetPath);
  }
}

Future<void> _deleteEntityIfExists(String path) async {
  final type = await FileSystemEntity.type(path);
  if (type == FileSystemEntityType.directory) {
    await Directory(path).delete(recursive: true);
  } else if (type == FileSystemEntityType.file ||
      type == FileSystemEntityType.link) {
    await File(path).delete();
  }
}

class _BackupFailure implements Exception {
  _BackupFailure(this.reason, this.message);

  final BackupFailureReason reason;
  final String message;

  @override
  String toString() => message;
}

Future<void> _ensureOutputDirectoryWritable(String outputDir) async {
  final directory = Directory(outputDir);
  if (!await directory.exists()) {
    throw _BackupFailure(
      BackupFailureReason.outputDirectoryUnavailable,
      'Backup directory does not exist',
    );
  }

  final probe = File(
    p.join(
      outputDir,
      '.reveric_backup_probe_${DateTime.now().millisecondsSinceEpoch}',
    ),
  );
  try {
    await probe.writeAsString('ok');
  } catch (e) {
    throw _BackupFailure(
      BackupFailureReason.outputDirectoryUnavailable,
      'Backup directory is not writable',
    );
  } finally {
    if (await probe.exists()) {
      await probe.delete();
    }
  }
}

void _ensurePluginInstallSettled(Directory support) {
  final file = File(p.join(support.path, 'reveric.sqlite'));
  if (!file.existsSync()) {
    return;
  }
  final database = sqlite3.open(
    toWindowsSafePath(file.path),
    mode: OpenMode.readOnly,
  );
  try {
    if (database
        .select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='app_states'",
        )
        .isEmpty) {
      return;
    }
    for (final row in database.select(
      "SELECT key,value FROM app_states WHERE key LIKE 'plugin_install.%'",
    )) {
      if (!(row['key'] as String).startsWith('plugin_install.')) {
        continue;
      }
      final record = jsonDecode(row['value'] as String);
      if (record is! Map || record['phase'] != 'done') {
        throw _BackupFailure(
          BackupFailureReason.sqliteUnreadable,
          'Plugin installation recovery must complete before backup',
        );
      }
    }
  } finally {
    database.close();
  }
}

Future<void> _copyPluginDatabaseSnapshots(
  Directory support,
  Directory destination,
  PluginHostService? host,
) async {
  final source = Directory(p.join(support.path, 'plugin_data'));
  if (!await source.exists()) {
    return;
  }
  await for (final entry in source.list(followLinks: false)) {
    if (entry is! Directory ||
        !RegExp(
          r'^[a-z0-9]+(\.[a-z0-9-]+)+$',
        ).hasMatch(p.basename(entry.path))) {
      throw const FormatException('Invalid plugin data directory in backup');
    }
    final file = File(p.join(entry.path, 'data.sqlite'));
    if (await FileSystemEntity.isLink(file.path)) {
      throw const FormatException('Plugin database cannot be a symbolic link');
    }
    if (!await file.exists()) {
      continue;
    }
    final target = File(
      p.join(destination.path, p.basename(entry.path), 'data.sqlite'),
    );
    await target.parent.create(recursive: true);
    if (host != null) {
      await (await host.privateDatabases()).backup(
        p.basename(entry.path),
        target.path,
      );
    } else {
      await _copySqliteSnapshotIfExists(file.path, target.path);
    }
  }
}

Future<void> _preflightSqliteSnapshots(Directory appSupportDir) async {
  await _ensureSqliteReadableIfExists(
    p.join(appSupportDir.path, 'reveric.sqlite'),
  );

  final novelsDir = Directory(p.join(appSupportDir.path, 'novel_workspaces'));
  if (!await novelsDir.exists()) {
    return;
  }

  final entities = await novelsDir.list().toList();
  for (final entity in entities) {
    if (entity is Link) {
      throw const FormatException('Symbolic links are not allowed in backups');
    }
    if (_uncommittedBackupPath(entity.path, root: novelsDir)) {
      continue;
    }
    if (entity is File && p.extension(entity.path) == '.sqlite') {
      await _ensureSqliteReadableIfExists(entity.path);
    }
  }
}

Future<void> _ensureSqliteReadableIfExists(String path) async {
  final file = File(path);
  if (!await file.exists()) {
    return;
  }

  Database? db;
  final safePath = toWindowsSafePath(path);
  final windowsShortPathUnavailable =
      Platform.isWindows && !_isAscii(path) && safePath == path;
  try {
    db = sqlite3.open(safePath, mode: OpenMode.readOnly);
  } catch (e) {
    throw _BackupFailure(
      windowsShortPathUnavailable
          ? BackupFailureReason.sqlitePathUnsupportedOnWindows
          : BackupFailureReason.sqliteUnreadable,
      windowsShortPathUnavailable
          ? 'Windows cannot open this SQLite path because short paths are unavailable'
          : 'SQLite database is not readable',
    );
  } finally {
    db?.close();
  }
}

bool _isAscii(String value) {
  for (final code in value.codeUnits) {
    if (code > 127) {
      return false;
    }
  }
  return true;
}

Future<void> _copySqliteSnapshotIfExists(String source, String dest) async {
  final file = File(source);
  if (!await file.exists()) {
    _log.info('SQLite snapshot source does not exist, skipping: $source');
    return;
  }

  _log.info('Starting SQLite backup: $source -> $dest');
  Database? lastSourceDb;
  Database? lastDestDb;
  for (var attempt = 0; attempt < 3; attempt += 1) {
    try {
      final sourceDb = sqlite3.open(
        toWindowsSafePath(source),
        mode: OpenMode.readOnly,
      );
      lastSourceDb = sourceDb;
      final destDb = sqlite3.open(toWindowsSafePath(dest));
      lastDestDb = destDb;
      _log.info('Source and dest DBs opened, starting backup (nPage=-1)');
      int pageCount = 0;
      await for (final _ in sourceDb.backup(destDb, nPage: -1)) {
        pageCount++;
      }
      _log.info('SQLite backup completed, total pages: $pageCount');
      destDb.close();
      sourceDb.close();
      lastDestDb = null;
      lastSourceDb = null;
      return;
    } on Object catch (e, stack) {
      _log.error(
        'SQLite backup attempt $attempt failed',
        error: e,
        stackTrace: stack,
      );
      lastDestDb?.close();
      lastSourceDb?.close();
      lastDestDb = null;
      lastSourceDb = null;
      if (attempt == 2) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
    }
  }
}

Future<void> _copyNovelWorkspaceDatabasesIfExists(
  String source,
  String dest,
) async {
  final sourceDir = Directory(source);
  if (await FileSystemEntity.type(source, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FormatException('Symbolic links are not allowed in backups');
  }
  if (!await sourceDir.exists()) {
    return;
  }

  final targetDir = Directory(dest);
  if (!await targetDir.exists()) {
    await targetDir.create(recursive: true);
  }

  final entities = await sourceDir.list(followLinks: false).toList();
  for (final entity in entities) {
    if (entity is Link) {
      throw const FormatException('Symbolic links are not allowed in backups');
    }
    if (_uncommittedBackupPath(entity.path, root: sourceDir)) {
      continue;
    }
    if (entity is File && p.extension(entity.path) == '.sqlite') {
      await _copySqliteSnapshotIfExists(
        entity.path,
        p.join(targetDir.path, p.basename(entity.path)),
      );
    }
  }
}

Future<void> _copyDirIfExists(
  String source,
  String dest, {
  List<BackupWarning>? warnings,
}) async {
  final sourceDir = Directory(source);
  if (await FileSystemEntity.type(source, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FormatException('Symbolic links are not allowed in backups');
  }
  if (!await sourceDir.exists()) {
    return;
  }
  await _copyDirContents(sourceDir, Directory(dest), warnings: warnings);
}

Future<void> _copyDirContents(
  Directory source,
  Directory target, {
  List<BackupWarning>? warnings,
}) async {
  if (!await target.exists()) {
    await target.create(recursive: true);
  }
  final List<FileSystemEntity> entities;
  try {
    entities = await source.list(followLinks: false).toList();
  } catch (e) {
    if (warnings == null) {
      rethrow;
    }
    warnings.add(BackupWarning(path: source.path, reason: e.toString()));
    return;
  }
  for (final entity in entities) {
    if (entity is Link) {
      throw const FormatException('Symbolic links are not allowed in backups');
    }
    if (_uncommittedBackupPath(entity.path, root: source)) {
      continue;
    }
    if (entity is File) {
      final destPath = p.join(target.path, p.basename(entity.path));
      await _copyFileWithOptionalWarning(entity, destPath, warnings);
    } else if (entity is Directory) {
      final destDir = Directory(p.join(target.path, p.basename(entity.path)));
      await _copyDirContents(entity, destDir, warnings: warnings);
    }
  }
}

Future<void> _copyFileWithOptionalWarning(
  File source,
  String destPath,
  List<BackupWarning>? warnings,
) async {
  for (var attempt = 0; attempt < 3; attempt += 1) {
    try {
      await Directory(p.dirname(destPath)).create(recursive: true);
      await source.copy(destPath);
      return;
    } catch (e) {
      if (warnings == null || attempt == 2) {
        if (warnings == null) {
          rethrow;
        }
        warnings.add(BackupWarning(path: source.path, reason: e.toString()));
        return;
      }
      await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
    }
  }
}

/// 在 isolate 中从临时目录创建 zip 文件。
/// 所有参数均为 Sendable（String），可安全传给 [Isolate.run]。
String _createZipFromDir({
  required String tempDirPath,
  required String outputDirPath,
  required String zipName,
}) {
  final zipPath = p.join(outputDirPath, zipName);
  final encoder = ZipFileEncoder();
  encoder.create(zipPath);

  final dir = Directory(tempDirPath);
  final files = dir.listSync(recursive: true);
  for (final entity in files) {
    if (entity is File) {
      final relativePath = p.relative(entity.path, from: tempDirPath);
      encoder.addFileSync(entity, relativePath);
    }
  }
  encoder.closeSync();
  return zipPath;
}

/// 在 isolate 中解压 zip 文件到目标目录。
/// 所有参数均为 sendable，不依赖类上下文。
void _extractZipSafely({
  required String zipPath,
  required String extractDirPath,
}) {
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeStream(input);

    final extractRoot = p.normalize(extractDirPath);
    for (final entry in archive) {
      final portableName = entry.name.replaceAll('\\', '/');
      if (p.posix.isAbsolute(portableName) ||
          p.windows.isAbsolute(entry.name) ||
          p.posix.split(portableName).contains('..') ||
          entry.isSymbolicLink) {
        throw const FormatException('Unsafe zip entry path');
      }
      final normalizedName = p.normalize(portableName);
      final segments = p.split(normalizedName);
      if (p.isAbsolute(normalizedName) ||
          segments.isEmpty ||
          segments.contains('..')) {
        throw const FormatException('Unsafe zip entry path');
      }

      final topLevel = segments.first;
      if (topLevel != 'manifest.json' && !_backupEntries.contains(topLevel)) {
        throw const FormatException('Unexpected backup entry');
      }

      if (entry.isFile) {
        final outputPath = p.normalize(p.join(extractRoot, normalizedName));
        if (!p.isWithin(extractRoot, outputPath)) {
          throw const FormatException('Unsafe zip entry path');
        }
        Directory(p.dirname(outputPath)).createSync(recursive: true);
        final output = OutputFileStream(outputPath);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
      }
    }
  } finally {
    input.closeSync();
  }
}

// Only entries inside the enumerated root identify temporary output. User
// storage paths and the system temporary directory can contain these names too.
bool _uncommittedBackupPath(String path, {required Directory root}) => p
    .split(p.relative(path, from: root.path))
    .any(
      (part) =>
          part.endsWith('.part') ||
          part.endsWith('.pending') ||
          part.endsWith('.staging') ||
          part.startsWith('.reveric_copy_') ||
          part.startsWith('.reveric_restore_rollback_'),
    );

Future<void> _restoreSelectedMediaDirectories(
  Directory source,
  Directory target,
  Set<String> novelIds,
  _RollbackLedger ledger,
) async {
  final exclusive = <String>[for (final id in novelIds) 'file_workspaces/$id'];
  for (final id in novelIds) {
    RevericPaths.mediaDirectory(id, 'file');
  }
  const merged = ['file_workspaces/shared'];
  for (final relative in exclusive) {
    final input = Directory(p.join(source.path, relative));
    if (!await input.exists()) {
      continue;
    }
    final output = Directory(
      RevericPaths.resolveRelative(relative, support: target.path),
    );
    await RevericPaths.requireNoLinks(source, input.path);
    await RevericPaths.requireNoLinks(
      Directory(
        RevericPaths.resolveRelative('file_workspaces', support: target.path),
      ),
      output.path,
    );
    await ledger.moveAside(output.path);
    await _copyDirContents(input, output);
  }
  for (final relative in merged) {
    final input = Directory(p.join(source.path, relative));
    if (!await input.exists()) {
      continue;
    }
    await RevericPaths.requireNoLinks(source, input.path);
    await for (final entity in input.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) {
        throw const FormatException('Symbolic link in shared media');
      }
      if (entity is! File || _uncommittedBackupPath(entity.path, root: input)) {
        continue;
      }
      final output = File(
        RevericPaths.resolveRelative(
          p.relative(entity.path, from: source.path),
          support: target.path,
        ),
      );
      await RevericPaths.requireNoLinks(
        Directory(
          RevericPaths.resolveRelative('file_workspaces', support: target.path),
        ),
        output.path,
      );
      await ledger.moveAside(output.path);
      await output.parent.create(recursive: true);
      await entity.copy(output.path);
    }
  }
}
