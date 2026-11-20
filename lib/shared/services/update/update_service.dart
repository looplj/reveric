// 职责: 自动升级核心服务 — 下载、应用更新、重启
// 关联文件:
//   lib/shared/services/update/models.dart
//   lib/shared/services/update/update_source.dart
//   lib/shared/services/update/macos_restart_script.dart
//   lib/shared/services/crash_reporting/crash_sentinel.dart
//   lib/shared/services/single_instance_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../logger/app_logger.dart';
import '../../logger/startup_failure_reporter.dart';
import '../../localization/locale_keys.dart';
import '../crash_reporting/crash_sentinel.dart';
import '../single_instance_service.dart';
import 'macos_restart_script.dart';
import 'models.dart';
import 'restart_exit.dart';
import 'update_source.dart';

final _log = AppLogger.forModule('UpdateService');
const _updateChannel = MethodChannel('reveric/update');

enum _DownloadOutcome { downloaded, cancelled, failed }

/// 自动升级核心服务
class UpdateService {
  final UpdateSource source;
  final FutureOr<Dio> Function() createClient;

  UpdateService({required this.source, this.createClient = Dio.new});

  String? _currentVersion;
  UpdateInfo? _pendingUpdate;
  String? _downloadedPath;
  CancelToken? _cancelToken;
  UpdateProgress _progress = const UpdateProgress.idle();

  UpdateProgress get progress => _progress;
  UpdateInfo? get pendingUpdate => _pendingUpdate;

  set onProgressChanged(void Function(UpdateProgress)? callback) {
    _onProgressChanged = callback;
  }

  void Function(UpdateProgress)? _onProgressChanged;

  void _setProgress(UpdateProgress p) {
    _progress = p;
    _onProgressChanged?.call(p);
  }

  /// 初始化当前版本号（应在启动后尽快调用）
  Future<void> init(String currentVersion) async {
    _currentVersion = currentVersion;
    _log.info('initialized version=$currentVersion');

    // 启动时清理上次更新残留的旧 exe（Windows helper 替换遗留）
    if (Platform.isWindows) {
      final executable = Platform.resolvedExecutable;
      for (final suffix in const ['.old', '.bak']) {
        try {
          final oldPath = '$executable$suffix';
          final oldFile = File(oldPath);
          if (await oldFile.exists()) {
            await oldFile.delete();
            _log.info('Cleaned up old exe from previous update path=$oldPath');
          }
        } catch (e) {
          _log.warning('Failed to clean up old exe suffix=$suffix error=$e');
        }
      }
    }
  }

  /// 检查更新
  Future<UpdateCheckResult> checkForUpdate() async {
    if (_currentVersion == null) {
      return const UpdateCheckFailed(LocaleKeys.settingsAboutCheckFailed);
    }
    final result = await source.checkForUpdate(_currentVersion!);
    if (result is UpdateAvailable) {
      _pendingUpdate = result.info;
      _log.info(
        'checkForUpdate: update available version=${result.info.version} url=${result.info.downloadUrl}',
      );
    }
    return result;
  }

  /// 下载更新。GitHub 资源下载失败时，改用同一文件在 R2 上的地址再试一次。
  Future<bool> downloadUpdate(UpdateInfo info) async {
    final urls = <String>[info.downloadUrl];
    final fallback = info.fallbackDownloadUrl;
    if (fallback != null &&
        fallback.isNotEmpty &&
        fallback != info.downloadUrl) {
      urls.add(fallback);
    }
    for (var index = 0; index < urls.length; index++) {
      final outcome = await _downloadOnce(
        info,
        urls[index],
        reportFailure: index == urls.length - 1,
      );
      if (outcome != _DownloadOutcome.failed) {
        return outcome == _DownloadOutcome.downloaded;
      }
      if (index + 1 < urls.length) {
        _log.warning(
          'Download failed, trying mirror url=${urls[index + 1]} version=${info.version}',
        );
      }
    }
    return false;
  }

  Future<_DownloadOutcome> _downloadOnce(
    UpdateInfo info,
    String url, {
    required bool reportFailure,
  }) async {
    Dio? client;
    try {
      _cancelToken?.cancel();
      final cancelToken = CancelToken();
      _cancelToken = cancelToken;

      _setProgress(const UpdateProgress.downloading(0));
      _pendingUpdate = info;

      final tempDir = await getTemporaryDirectory();
      var ext = p.extension(Uri.parse(url).path);
      if (Platform.isAndroid) {
        ext = '.apk';
      }
      final destPath = p.join(
        tempDir.path,
        'reveric_update_${info.version}$ext',
      );
      await _deletePartialDownload(destPath);

      _log.info(
        'downloadUpdate start url=$url destPath=$destPath version=${info.version}',
      );

      // 每次下载独占客户端，读取最新代理配置并在结束时释放连接。
      client = await createClient();
      await client.download(
        url,
        destPath,
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: const Duration(seconds: 60),
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            _setProgress(UpdateProgress.downloading(received / total));
          }
        },
        cancelToken: cancelToken,
      );

      _log.info(
        'downloadUpdate success destPath=$destPath exists=${File(destPath).existsSync()}',
      );

      _downloadedPath = destPath;
      _setProgress(const UpdateProgress.downloaded());
      _log.info('Update downloaded path=$destPath version=${info.version}');
      return _DownloadOutcome.downloaded;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        _log.info('Download cancelled');
        _cleanupDownload();
        return _DownloadOutcome.cancelled;
      }
      _log.warning(
        'Download failed (Dio) error=$e type=${e.type.name} url=$url responseCode=${e.response?.statusCode}',
      );
      if (reportFailure) {
        _setProgress(
          const UpdateProgress.error(
            LocaleKeys.settingsAboutUpdateDownloadFailed,
          ),
        );
      }
      return _DownloadOutcome.failed;
    } catch (e) {
      _log.warning('Download failed (generic) error=$e url=$url');
      if (reportFailure) {
        _setProgress(
          const UpdateProgress.error(
            LocaleKeys.settingsAboutUpdateDownloadFailed,
          ),
        );
      }
      return _DownloadOutcome.failed;
    } finally {
      client?.close(force: true);
    }
  }

  Future<void> _deletePartialDownload(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      return;
    }
    try {
      await file.delete();
    } catch (e) {
      _log.warning('Failed to remove partial update error=$e path=$path');
    }
  }

  /// 取消进行中的下载
  void cancelDownload() {
    _cancelToken?.cancel();
    _cancelToken = null;
    _cleanupDownload();
  }

  void _cleanupDownload() {
    if (_downloadedPath != null) {
      try {
        File(_downloadedPath!).delete();
      } catch (_) {}
      _downloadedPath = null;
    }
    _pendingUpdate = null;
    _setProgress(const UpdateProgress.idle());
  }

  /// 应用更新
  Future<bool> applyUpdate() async {
    if (_pendingUpdate == null || _downloadedPath == null) {
      return false;
    }

    _setProgress(const UpdateProgress.applying());

    try {
      final file = File(_downloadedPath!);
      if (!await file.exists()) {
        _setProgress(
          const UpdateProgress.error(
            LocaleKeys.settingsAboutUpdateDownloadedFileMissing,
          ),
        );
        return false;
      }

      final appDir = await _getAppDirectory();
      _log.info(
        'Applying update source=$_downloadedPath target=$appDir platform=${Platform.operatingSystem}',
      );

      if (Platform.isMacOS) {
        return await _applyMacOS(file, appDir);
      } else if (Platform.isWindows) {
        return await _applyWindows(file, appDir);
      } else if (Platform.isLinux) {
        return await _applyLinux(file, appDir);
      } else if (Platform.isAndroid) {
        return await _applyAndroid(file);
      }

      _setProgress(
        const UpdateProgress.error(
          LocaleKeys.settingsAboutUpdateUnsupportedPlatform,
        ),
      );
      return false;
    } catch (e) {
      _log.warning('Apply update failed error=$e');
      _setProgress(
        const UpdateProgress.error(LocaleKeys.settingsAboutUpdateApplyFailed),
      );
      return false;
    }
  }

  Future<String> _getAppDirectory() async {
    if (Platform.isMacOS) {
      final appPath = Platform.resolvedExecutable;
      return Directory(appPath).parent.parent.parent.path;
    } else if (Platform.isWindows) {
      return Platform.resolvedExecutable;
    } else {
      return Platform.resolvedExecutable;
    }
  }

  Future<bool> _applyMacOS(File zipFile, String appDir) async {
    final tempExtract = '${zipFile.path}_extracted';
    final extractDir = Directory(tempExtract);
    if (await extractDir.exists()) {
      await extractDir.delete(recursive: true);
    }

    final result = await Process.run('unzip', [
      '-o',
      zipFile.path,
      '-d',
      tempExtract,
    ]);
    if (result.exitCode != 0) {
      _log.warning(
        'macOS update extraction failed stderr=${result.stderr} zipPath=${zipFile.path}',
      );
      _setProgress(
        const UpdateProgress.error(
          LocaleKeys.settingsAboutUpdateExtractionFailed,
        ),
      );
      return false;
    }

    final contents = await extractDir.list().toList();
    FileSystemEntity? appBundle;
    for (final entity in contents) {
      if (entity.path.endsWith('.app')) {
        appBundle = entity;
        break;
      }
    }

    if (appBundle == null) {
      _setProgress(
        const UpdateProgress.error(
          LocaleKeys.settingsAboutUpdateAppBundleMissing,
        ),
      );
      return false;
    }

    final currentApp = Directory(appDir);
    var backupPath = '${currentApp.path}_backup';
    var backupDir = Directory(backupPath);

    if (await backupDir.exists()) {
      try {
        await backupDir.delete(recursive: true);
      } catch (e) {
        _log.warning(
          'macOS update backup cleanup failed error=$e backupPath=$backupPath',
        );
      }
      if (await backupDir.exists()) {
        final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
          RegExp(r'[:.]'),
          '',
        );
        backupPath = '${currentApp.path}_backup_$stamp';
        backupDir = Directory(backupPath);
      }
    }

    try {
      await currentApp.rename(backupPath);
      await (appBundle as Directory).rename(currentApp.path);
      await backupDir.delete(recursive: true);
    } catch (e) {
      try {
        if (await backupDir.exists()) {
          if (await currentApp.exists()) {
            await currentApp.delete(recursive: true);
          }
          await backupDir.rename(currentApp.path);
        }
      } catch (_) {}

      _log.warning(
        'macOS update replace failed error=$e target=${currentApp.path}',
      );
      _setProgress(
        const UpdateProgress.error(LocaleKeys.settingsAboutUpdateReplaceFailed),
      );
      return false;
    }

    try {
      await extractDir.delete(recursive: true);
    } catch (_) {}

    _setProgress(const UpdateProgress.applying());
    return true;
  }

  Future<bool> _applyWindows(File installerFile, String exePath) async {
    // Windows 会锁住正在运行的 exe/dll，且当前安装器保留 VC++ redistributable
    // 和 admin 安装权限；因此更新必须交给 Inno Setup 安装器处理，不能在
    // Reveric 进程内解压 zip 后覆盖安装目录。
    final ext = p.extension(installerFile.path).toLowerCase();
    if (ext != '.exe') {
      _log.warning(
        'Windows update package is not an installer path=${installerFile.path} target=$exePath',
      );
      _setProgress(
        const UpdateProgress.error(
          LocaleKeys.settingsAboutUpdateInvalidPackage,
        ),
      );
      return false;
    }

    try {
      final installerPath = _powerShellSingleQuotedString(installerFile.path);
      final arguments = _powerShellSingleQuotedString(
        '/CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /LOGCLOSEAPPLICATIONS',
      );
      final command =
          'Start-Process -FilePath $installerPath -ArgumentList $arguments -Verb RunAs';
      _log.checkpoint('windows update pid=$pid stage=launch_installer');
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        command,
      ]);

      if (result.exitCode != 0) {
        _log.warning(
          'Windows update installer start failed exitCode=${result.exitCode} stderr=${result.stderr} installerPath=${installerFile.path}',
        );
        _setProgress(
          const UpdateProgress.error(
            LocaleKeys.settingsAboutUpdatePrepareFailed,
          ),
        );
        await StartupFailureReporter().reportLifecycleFailure(
          phase: 'update_installer_launch',
          reason: 'launcher_nonzero_exit',
          error: ProcessException('powershell', const [], '', result.exitCode),
          stackTrace: StackTrace.current,
        );
        return false;
      }

      _log.info(
        'Windows update installer started installerPath=${installerFile.path} target=$exePath',
      );
    } catch (e, stack) {
      _log.warning(
        'Windows update installer start failed error=$e installerPath=${installerFile.path}',
      );
      _setProgress(
        const UpdateProgress.error(LocaleKeys.settingsAboutUpdatePrepareFailed),
      );
      await StartupFailureReporter().reportLifecycleFailure(
        phase: 'update_installer_launch',
        reason: 'launcher_failed',
        error: e,
        stackTrace: stack,
      );
      return false;
    }

    _setProgress(const UpdateProgress.applying());
    return true;
  }

  String _powerShellSingleQuotedString(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  Future<bool> _applyLinux(File zipFile, String binaryPath) async {
    final tempExtract = '${zipFile.path}_extracted';
    final extractDir = Directory(tempExtract);
    if (await extractDir.exists()) {
      await extractDir.delete(recursive: true);
    }

    final result = await Process.run('unzip', [
      '-o',
      zipFile.path,
      '-d',
      tempExtract,
    ]);
    if (result.exitCode != 0) {
      _log.warning(
        'Linux update extraction failed stderr=${result.stderr} zipPath=${zipFile.path}',
      );
      _setProgress(
        const UpdateProgress.error(
          LocaleKeys.settingsAboutUpdateExtractionFailed,
        ),
      );
      return false;
    }

    final backupPath = '$binaryPath.bak';
    final backupFile = File(backupPath);
    if (await backupFile.exists()) {
      await backupFile.delete();
    }

    try {
      await File(binaryPath).rename(backupPath);
      final contents = await extractDir.list().toList();
      File? newBinary;
      for (final entity in contents) {
        if (entity is File || entity.path.endsWith('.AppImage')) {
          newBinary = File(entity.path);
          break;
        }
      }
      if (newBinary == null) {
        _setProgress(
          const UpdateProgress.error(
            LocaleKeys.settingsAboutUpdateInvalidPackage,
          ),
        );
        return false;
      }
      await newBinary.copy(binaryPath);
      await Process.run('chmod', ['+x', binaryPath]);
    } catch (e) {
      try {
        if (await backupFile.exists()) {
          await backupFile.rename(binaryPath);
        }
      } catch (_) {}
      _log.warning('Linux update replace failed error=$e target=$binaryPath');
      _setProgress(
        const UpdateProgress.error(LocaleKeys.settingsAboutUpdateReplaceFailed),
      );
      return false;
    }

    _setProgress(const UpdateProgress.applying());
    return true;
  }

  Future<bool> _applyAndroid(File apkFile) async {
    final ext = p.extension(apkFile.path).toLowerCase();
    if (ext != '.apk') {
      _log.warning('Android update package is not an APK path=${apkFile.path}');
      _setProgress(
        const UpdateProgress.error(
          LocaleKeys.settingsAboutUpdateInvalidPackage,
        ),
      );
      return false;
    }

    try {
      final started = await _updateChannel.invokeMethod<bool>('installApk', {
        'path': apkFile.path,
      });
      if (started != true) {
        _setProgress(
          const UpdateProgress.error(
            LocaleKeys.settingsAboutUpdatePrepareFailed,
          ),
        );
        return false;
      }
    } on PlatformException catch (e) {
      _log.warning(
        'Android APK installer start failed code=${e.code} message=${e.message} path=${apkFile.path}',
      );
      _setProgress(
        const UpdateProgress.error(LocaleKeys.settingsAboutUpdatePrepareFailed),
      );
      return false;
    }

    _log.info('Android APK installer started path=${apkFile.path}');
    _setProgress(const UpdateProgress.idle());
    return true;
  }

  /// 重启应用
  Future<void> restartApp() async {
    try {
      if (Platform.isAndroid) {
        _log.info(
          'Android update is handled by system installer; skip restart',
        );
        return;
      }
      if (Platform.isMacOS) {
        await _restartMacOSAfterExit();
        await _exitForRestart();
        return;
      }
      if (Platform.isWindows) {
        await _exitForRestart();
        return;
      }

      if (Platform.isLinux) {
        await _restartLinuxAfterExit();
      } else {
        final executable = Platform.resolvedExecutable;
        await Process.start(executable, const <String>[]);
      }
      await _exitForRestart();
    } catch (e, stack) {
      _log.warning('Restart failed error=$e');
      _setProgress(
        const UpdateProgress.error(LocaleKeys.settingsAboutUpdatePrepareFailed),
      );
      await StartupFailureReporter().reportLifecycleFailure(
        phase: 'update_restart',
        reason: 'restart_failed',
        error: e,
        stackTrace: stack,
      );
    }
  }

  Future<void> _exitForRestart() async {
    await exitForUpdate(
      releaseInstance: SingleInstanceService.unlock,
      markCleanExit: CrashSentinel.markActiveSessionCleanExitSync,
      terminate: exit,
    );
  }

  Future<void> _restartLinuxAfterExit() async {
    final executable = shellSingleQuotedString(Platform.resolvedExecutable);
    final tempDir = await getTemporaryDirectory();
    final scriptPath = p.join(
      tempDir.path,
      'reveric_restart_${DateTime.now().millisecondsSinceEpoch}.sh',
    );
    final scriptFile = File(scriptPath);
    await scriptFile.writeAsString('''
#!/bin/sh
set -u

process_id=$pid
executable=$executable
script_path=${shellSingleQuotedString(scriptPath)}

while kill -0 "\$process_id" 2>/dev/null; do
  sleep 0.2
done

rm -f "\$script_path"
exec "\$executable"
''');
    await Process.run('chmod', ['+x', scriptPath]);
    final process = await Process.start('/bin/sh', [
      scriptPath,
    ], mode: ProcessStartMode.detached);
    _log.info(
      'Linux restart helper started pid=${process.pid} scriptPath=$scriptPath',
    );
  }

  Future<void> _restartMacOSAfterExit() async {
    final appPath = Directory(
      Platform.resolvedExecutable,
    ).parent.parent.parent.path;
    final tempDir = await getTemporaryDirectory();
    final scriptPath = p.join(
      tempDir.path,
      'reveric_restart_${DateTime.now().millisecondsSinceEpoch}.sh',
    );
    final scriptFile = File(scriptPath);
    await scriptFile.writeAsString(
      buildMacOSRestartScript(
        processId: pid,
        appPath: appPath,
        scriptPath: scriptPath,
      ),
    );
    await Process.run('chmod', ['+x', scriptPath]);
    final process = await Process.start('/bin/sh', [
      scriptPath,
    ], mode: ProcessStartMode.detached);
    _log.info(
      'macOS restart helper started pid=${process.pid} scriptPath=$scriptPath appPath=$appPath',
    );
  }

  /// 清理下载文件
  Future<void> cleanup() async {
    _cancelToken?.cancel();
    _cancelToken = null;
    _cleanupDownload();
  }
}
