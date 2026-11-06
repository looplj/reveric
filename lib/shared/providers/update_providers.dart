// 职责: 管理 GitHub Releases 版本检查、下载进度、更新状态和提醒。
// 关联文件:
//   lib/shared/services/update/update_service.dart
//   lib/shared/services/update/sources/github_releases_source.dart
//   lib/shared/widgets/settings/about_settings_section.dart
//   lib/shared/app_config.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'dart:async';

import 'package:http/io_client.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_config.dart' show appVersion;
import '../logger/app_logger.dart';
import '../localization/locale_keys.dart';
import '../services/update.dart';
import '../services/proxy_client.dart';
import 'settings_providers.dart';

part 'update_providers.g.dart';

final _log = AppLogger.forModule('UpdateProvider');

/// UpdateSource 单例
@Riverpod(keepAlive: true)
UpdateSource updateSource(Ref ref) {
  return GitHubReleasesSource(
    owner: 'looplj',
    repo: 'reveric',
    createClient: () async => IOClient(
      await createProxyHttpClient(
        (await ref.read(appSettingsProvider.future)).networkProxy,
      ),
    ),
  );
}

/// UpdateService 单例
@Riverpod(keepAlive: true)
UpdateService updateService(Ref ref) {
  final source = ref.read(updateSourceProvider);
  final service = UpdateService(
    source: source,
    createClient: () async {
      final settings = await ref.read(appSettingsProvider.future);
      if (!ref.mounted) {
        throw StateError('Update service provider disposed');
      }
      return createProxyDioClient(settings.networkProxy);
    },
  );
  return service;
}

/// 初始化 UpdateService（注入版本号）
@Riverpod(keepAlive: true)
Future<void> updateServiceInit(Ref ref) async {
  final service = ref.read(updateServiceProvider);
  try {
    final version = appVersion;
    await service.init(version);
    _log.info('UpdateService init complete version=$version');
  } catch (e) {
    _log.warning('UpdateService init failed error=$e');
  }
}

/// 跨页面保留一份轻量检查结果，供关于页、更新入口与提醒共同消费。
@Riverpod(keepAlive: true)
class LatestRelease extends _$LatestRelease {
  static const checkInterval = Duration(hours: 6);
  static const notifiedVersionsKey = 'update.notified_versions';
  DateTime? _lastCheckedAt;
  Future<UpdateCheckResult>? _request;
  final _notifiedThisSession = <String>{};

  @override
  Future<UpdateCheckResult?> build() => _check();

  Future<UpdateCheckResult> _check() {
    return _request ??= _fetch().whenComplete(() => _request = null);
  }

  Future<UpdateCheckResult> _fetch() async {
    _lastCheckedAt = DateTime.now();
    try {
      await ref.read(updateServiceInitProvider.future);
      return await ref.read(updateServiceProvider).checkForUpdate();
    } catch (error, stack) {
      _log.error('Update check failed', error: error, stackTrace: stack);
      return const UpdateCheckFailed(LocaleKeys.settingsAboutCheckFailed);
    }
  }

  /// 回到前台按间隔检查；手动检查可强制刷新，共用同一个在途请求。
  Future<void> refresh({bool force = false, DateTime? now}) async {
    if (_request != null && !force) {
      await _request;
      return;
    }
    final checkedAt = _lastCheckedAt;
    if (!force &&
        checkedAt != null &&
        (now ?? DateTime.now()).difference(checkedAt) < checkInterval) {
      return;
    }
    final previous = state.value;
    final result = await _check();
    if (!ref.mounted) {
      return;
    }
    // 后台失败不抹掉已知版本，也不让已有内容切回 loading。
    if (!force &&
        result is UpdateCheckFailed &&
        (previous is UpdateAvailable || previous is UpdateUpToDate)) {
      return;
    }
    state = AsyncData(result);
  }

  Future<bool> shouldNotify(String version) async {
    if (_notifiedThisSession.contains(version)) {
      return false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      return !(prefs.getStringList(notifiedVersionsKey) ?? []).contains(
        version,
      );
    } catch (error, stack) {
      _log.error(
        'Read update reminder history failed',
        error: error,
        stackTrace: stack,
      );
      return false;
    }
  }

  Future<void> markNotified(String version) async {
    _notifiedThisSession.add(version);
    try {
      final prefs = await SharedPreferences.getInstance();
      final versions = {...?prefs.getStringList(notifiedVersionsKey), version};
      if (!await prefs.setStringList(notifiedVersionsKey, versions.toList())) {
        throw StateError('Could not save update reminder history');
      }
    } catch (error, stack) {
      _log.error(
        'Save update reminder history failed',
        error: error,
        stackTrace: stack,
      );
    }
  }
}

/// 小型入口只订阅版本变化，检查失败与刷新不会影响布局。
@riverpod
UpdateInfo? availableUpdate(Ref ref) {
  final result = ref.watch(latestReleaseProvider).value;
  return result is UpdateAvailable ? result.info : null;
}

/// 调试页向全局轻提示发送验证请求，不修改真实版本或提醒历史。
@riverpod
class UpdateReminderPreview extends _$UpdateReminderPreview {
  @override
  int build() => 0;

  void show() => state++;
}

/// 更新下载状态
@riverpod
class UpdateDownloadNotifier extends _$UpdateDownloadNotifier {
  @override
  UpdateProgress build() {
    final service = ref.read(updateServiceProvider);
    // 注册进度回调，下载/应用过程中实时同步到 state，驱动 UI 进度条
    service.onProgressChanged = (p) {
      state = p;
    };
    ref.onDispose(() {
      service.onProgressChanged = null;
    });
    return service.progress;
  }

  Future<bool> startDownload() async {
    final service = ref.read(updateServiceProvider);
    final info = service.pendingUpdate;
    _log.info(
      'UpdateDownload startDownload version=${info?.version} url=${info?.downloadUrl} pendingUpdate=${info != null}',
    );
    if (info == null) {
      _log.warning('UpdateDownload: pendingUpdate is null, download aborted');
      return false;
    }

    // 立即切到 downloading 状态，避免点击后无 UI 反馈的等待间隙
    state = const UpdateProgress.downloading(0);

    final success = await service.downloadUpdate(info);
    // provider 可能在下载期间被 dispose（卸载锁屏/设置页）。dispose 后读写
    // state 都会抛 UnmountedRefException；下载结果由 service 记录，日志也
    // 读 service.progress，避免卸载后碰 Notifier.state。
    final progress = service.progress;
    if (ref.mounted) {
      state = progress;
    }
    _log.info(
      'UpdateDownload completed success=$success state=${progress.state.name} error=${progress.error}',
    );
    return success;
  }

  /// 安装和重启共用提前取得的服务，页面卸载不会中断已确认的更新。
  Future<bool> applyUpdateAndRestart() async {
    final service = ref.read(updateServiceProvider);
    final info = service.pendingUpdate;
    _log.info('UpdateDownload applyUpdate version=${info?.version}');
    final success = await service.applyUpdate();
    final progress = service.progress;
    if (ref.mounted) {
      state = progress;
    }
    _log.info(
      'UpdateDownload applyUpdate result success=$success state=${progress.state.name} error=${progress.error}',
    );
    if (success) {
      _log.info('UpdateDownload restartApp');
      await service.restartApp();
    }
    return success;
  }

  void cancelDownload() {
    final service = ref.read(updateServiceProvider);
    service.cancelDownload();
    state = service.progress;
  }

  void clear() {
    state = const UpdateProgress.idle();
  }
}
