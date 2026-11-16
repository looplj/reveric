// 职责: 系统托盘服务 — 管理托盘图标、菜单与关闭到托盘行为
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/main.dart
//   lib/shared/services/window_state_service.dart
//   lib/desktop/widgets/novel_form_dialog.dart
//   lib/desktop/pages/workspace_editor_page.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/models/novel_type.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart' as tray;

import '../components/dialog_feedback.dart';
import '../database/app_database.dart';
import '../database/novel_content_database.dart';
import '../logger/app_logger.dart';
import '../logger/startup_failure_reporter.dart';
import 'crash_reporting/crash_sentinel.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'single_instance_service.dart';
import '../../desktop/widgets/novel_form_dialog.dart';
import '../providers/novel_providers.dart';
import '../../desktop/pages/workspace_editor_page.dart';
import '../components/reveric_dialog.dart';
import '../components/reveric_button.dart';

final _log = AppLogger.forModule('SystemTray');

class SystemTrayService {
  static const _exitChannel = MethodChannel('reveric/process_exit');
  // Dart 各阶段合计 4.5 秒，为原生 5 秒强退留出余量。
  static const _exitTimeout = Duration(milliseconds: 4500);
  Future<void>? _activation;
  Future<void>? _exiting;

  final List<Future<bool> Function()> _exitGuards = [];

  /// 尽力保存和停止任务；点击托盘“退出”即发出最终指令，false 或异常不否决退出。
  VoidCallback registerExitGuard(Future<bool> Function() guard) {
    _exitGuards.add(guard);
    return () => _exitGuards.remove(guard);
  }

  static String get _iconPath {
    if (Platform.isWindows) {
      return 'assets/logo/reveric_mark_32.ico';
    }
    return 'assets/logo/reveric_mark_32.png';
  }

  static final SystemTrayService _instance = SystemTrayService._internal();
  factory SystemTrayService() => _instance;
  SystemTrayService._internal();

  @visibleForTesting
  SystemTrayService.forTesting(this._trayIcon);

  tray.TrayIcon? _trayIcon;
  tray.Image? _icon;
  tray.Menu? _menu;
  tray.ListenerId? _trayListener;
  final _menuItems = <(tray.MenuItem, tray.ListenerId)>[];

  GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) {
      return;
    }

    try {
      final icon = tray.ImageAsset.fromAsset(_iconPath);
      if (icon == null) {
        throw StateError('Unable to load tray icon: $_iconPath');
      }
      _icon = icon;
      final trayIcon = tray.TrayIcon.create();
      if (trayIcon == null) {
        throw StateError('Unable to create tray icon');
      }
      _trayIcon = trayIcon;
      trayIcon
        ..isIconTemplate = true
        ..icon = icon
        ..setTooltip('Reveric');
      _trayListener = trayIcon.addListener((event) async {
        if (event is tray.TrayIconClickedEvent) {
          _runTrayAction(showMainWindow);
        }
      });
      _updateMenu(trayIcon);
      if (!trayIcon.setVisible(true)) {
        throw StateError('Unable to show tray icon');
      }

      await windowManager.setPreventClose(true);
      windowManager.addListener(_WindowCloseListener());

      _initialized = true;
      _log.info('System tray initialized');
    } catch (error, stackTrace) {
      _disposeTray();
      _log.warning('Failed to initialize system tray: $error\n$stackTrace');
    }
  }

  void _updateMenu(tray.TrayIcon trayIcon) {
    final menu = tray.Menu.create();
    if (menu == null) {
      throw StateError('Unable to create tray menu');
    }
    _menu = menu;

    void addItem(String label, Future<void> Function() action) {
      final item = tray.MenuItem.createWithLabelAndType(
        label,
        tray.MenuItemType.normal,
      );
      if (item == null) {
        throw StateError('Unable to create tray menu item: $label');
      }
      final listener = item.addListener((event) async {
        if (event is tray.MenuItemClickedEvent) {
          _runTrayAction(action);
        }
      });
      _menuItems.add((item, listener));
      menu.addItem(item);
    }

    addItem('新建小说', _newNovel);
    addItem('关于 Reveric', _about);
    menu.addSeparator();
    addItem('隐藏', _hideWindow);
    addItem('显示', showMainWindow);
    menu.addSeparator();
    addItem('退出', _quit);
    trayIcon
      ..setContextMenu(menu)
      ..setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
  }

  void _disposeTray() {
    final trayIcon = _trayIcon;
    final listener = _trayListener;
    if (trayIcon != null && listener != null) {
      trayIcon.removeListener(listener);
    }
    _trayListener = null;
    for (final (item, listener) in _menuItems) {
      item.removeListener(listener);
      item.dispose();
    }
    _menuItems.clear();
    trayIcon?.dispose();
    _trayIcon = null;
    _menu?.dispose();
    _menu = null;
    _icon?.dispose();
    _icon = null;
  }

  /// 唤起主窗口：托盘点击、托盘菜单与第二实例激活请求共用。
  Future<void> showMainWindow() {
    if (_exiting != null) {
      return Future.error(StateError('Application is exiting'));
    }
    return _activation ??= _activateWindow().whenComplete(() {
      _activation = null;
    });
  }

  Future<void> _activateWindow() async {
    final stopwatch = Stopwatch()..start();
    const timeout = Duration(milliseconds: 1500);
    bool? visible;
    bool? minimized;
    Future<T> bounded<T>(Future<T> Function() operation) {
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero || _exiting != null) {
        throw StateError(
          'Window activation deadline expired or app is exiting',
        );
      }
      return operation().timeout(remaining);
    }

    try {
      await bounded(windowManager.show);
      await bounded(windowManager.focus);
      while (true) {
        visible = await bounded(windowManager.isVisible);
        minimized = await bounded(windowManager.isMinimized);
        if (visible == true && minimized == false) {
          _log.info(
            'Window activated elapsedMs=${stopwatch.elapsedMilliseconds}',
          );
          return;
        }
        await bounded(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
    } catch (error, stack) {
      _log.error(
        'Window activation failed visible=$visible minimized=$minimized '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stack,
      );
      throw StateError('Window did not become visible after activation');
    }
  }

  Future<void> _hideWindow() async {
    _log.checkpoint('hiding main window (native)');
    await windowManager.hide();
  }

  Future<void> _newNovel() async {
    await showMainWindow();
    final context = navigatorKey.currentState?.context;
    if (context == null || !context.mounted) {
      return;
    }
    showRevericDialog(
      context: context,
      builder: (ctx) => DialogFeedback.scope(
        builder: (ctx) => NovelFormDialog.create(
          onSubmit:
              ({
                required String title,
                required String authorName,
                required String description,
                required String category,
                required String type,
                required String contentKind,
                required int? plannedEpisodeCount,
                required String? sourceNovelId,
                required String? coverSourcePath,
                required bool removeCover,
                required List<String> tags,
              }) async {
                final container = ProviderScope.containerOf(ctx);
                final actions = container.read(novelActionsProvider);
                try {
                  final novelId = await actions.createNovel(
                    title: title,
                    authorName: authorName,
                    description: description,
                    category: category,
                    type: type,
                    contentKind: contentKind,
                    plannedEpisodeCount: plannedEpisodeCount,
                    sourceNovelId: sourceNovelId,
                    coverSourcePath: coverSourcePath,
                    tags: tags,
                  );
                  if (!ctx.mounted) return false;
                  final navigator = Navigator.of(ctx);
                  Navigator.of(ctx, rootNavigator: true).pop();
                  navigator.push(
                    MaterialPageRoute(
                      builder: (_) => WorkspaceEditorPage(novelId: novelId),
                    ),
                  );
                  return true;
                } catch (e) {
                  if (!ctx.mounted) return false;
                  ScaffoldMessenger.of(
                    ctx,
                  ).showSnackBar(const SnackBar(content: Text('创建小说失败')));
                  return false;
                }
              },
        ),
      ),
    );
  }

  Future<void> _about() async {
    await showMainWindow();
    final context = navigatorKey.currentState?.context;
    if (context == null || !context.mounted) {
      return;
    }
    showRevericDialog(
      context: context,
      builder: (ctx) {
        return RevericDialog(
          title: 'Reveric',
          content: Text('版本 1.0.0\nAI 辅助写作工具'),
          actions: [
            RevericButton.secondary(
              label: '关闭',
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ],
        );
      },
    );
  }

  Future<void> _quit({
    void Function(int)? terminate,
    FutureOr<void> Function()? unlock,
    Future<void> Function()? cleanExit,
    Future<void> Function()? closeContentDatabases,
    Future<void> Function()? closeAppDatabase,
    StartupFailureReporter? failureReporter,
    Duration timeout = _exitTimeout,
  }) => _exiting ??= _exitApplication(
    terminate: terminate,
    unlock: unlock,
    cleanExit: cleanExit,
    closeContentDatabases: closeContentDatabases,
    closeAppDatabase: closeAppDatabase,
    failureReporter: failureReporter,
    timeout: timeout,
  );

  Future<void> _exitApplication({
    void Function(int)? terminate,
    FutureOr<void> Function()? unlock,
    Future<void> Function()? cleanExit,
    Future<void> Function()? closeContentDatabases,
    Future<void> Function()? closeAppDatabase,
    StartupFailureReporter? failureReporter,
    required Duration timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    var failed = false;
    // 独立阶段预算合计 4500ms；测试可等比例缩短，总耗时不会被单个任务占满。
    Future<(Object, StackTrace)?> stage(
      String phase,
      int milliseconds,
      Future<void> Function() operation, {
      String? errorMessage,
    }) async {
      try {
        await Future<void>.sync(
          operation,
        ).timeout(timeout * (milliseconds / _exitTimeout.inMilliseconds));
        return null;
      } catch (error, stack) {
        failed = true;
        _log.error(
          errorMessage ?? '[EXIT] phase=$phase failed; continuing shutdown',
          error: error,
          stackTrace: stack,
        );
        return (error, stack);
      }
    }

    try {
      // 计时器启动失败或平台线程不回包，也要给保存和关库留出执行机会。
      final armError = await stage(
        'arm',
        100,
        () => _exitChannel.invokeMethod<void>('arm'),
      );
      _log.info(
        '[EXIT] requested nativeDeadlineAcknowledged=${armError == null}',
      );
      CrashSentinel.markActiveExitProgressSync(
        source: 'tray',
        phase: 'requested',
      );

      var cleanupFailed = false;
      final cleanupError = await stage(
        'cleanup',
        2800,
        () => Future.wait<void>(
          List<Future<bool> Function()>.of(_exitGuards.reversed).map((
            guard,
          ) async {
            try {
              if (!await guard()) {
                cleanupFailed = true;
                failed = true;
                _log.warning('[EXIT] cleanup declined; continuing exit');
              }
            } catch (error, stack) {
              cleanupFailed = true;
              failed = true;
              _log.error(
                '[EXIT] cleanup failed',
                error: error,
                stackTrace: stack,
              );
            }
          }),
        ),
      );

      CrashSentinel.markActiveExitProgressSync(
        source: 'tray',
        phase: 'closing_content_databases',
      );
      final contentError = await stage(
        'close_content_databases',
        400,
        closeContentDatabases ??
            NovelContentDatabase.closeAllCachedForProcessExit,
        errorMessage: '[DB] table=novel_content_databases operation=CLOSE_ALL',
      );
      CrashSentinel.markActiveExitProgressSync(
        source: 'tray',
        phase: 'closing_app_database',
      );
      final appError = await stage(
        'close_app_database',
        400,
        closeAppDatabase ?? AppDatabase.closeCachedForProcessExit,
        errorMessage:
            '[DB] table=app_database operation=CLOSE_FOR_PROCESS_EXIT',
      );

      // 保存或关库不完整时保留诊断 marker，但仍释放单实例锁。
      // watchdog 失败并不表示数据保存失败；数据清理成功仍可以正常清 marker。
      if (cleanupError == null &&
          !cleanupFailed &&
          contentError == null &&
          appError == null) {
        await stage('clean_marker', 50, () async {
          if (cleanExit != null) {
            await cleanExit();
          } else {
            CrashSentinel.markActiveSessionCleanExitSync();
          }
        });
      }
      final unlockError = await stage(
        'unlock',
        400,
        () => Future<void>.sync(unlock ?? SingleInstanceService.unlock),
      );
      if (unlockError != null) {
        final (error, stack) = unlockError;
        // 等待实际异步上报完成；上报也有独立期限，不会拖住最终退出。
        await stage(
          'report',
          300,
          () => (failureReporter ?? StartupFailureReporter())
              .reportLifecycleFailure(
                phase: 'tray_exit',
                reason: error is TimeoutException
                    ? 'release_instance_timeout'
                    : 'release_instance_failed',
                error: error,
                stackTrace: stack,
              ),
        );
      }
      await stage(
        'allow_window_close',
        50,
        () => windowManager.setPreventClose(false),
      );
    } catch (error, stack) {
      failed = true;
      _log.error(
        '[EXIT] shutdown interrupted; terminating',
        error: error,
        stackTrace: stack,
      );
    } finally {
      try {
        _disposeTray();
      } catch (error, stackTrace) {
        _log.warning('tray dispose failed error=$error\n$stackTrace');
      }
      unawaited(
        windowManager.close().catchError((Object error) {
          _log.warning('window close request failed error=$error');
        }),
      );
      _log.info(
        '[EXIT] terminating elapsedMs=${stopwatch.elapsedMilliseconds} failed=$failed',
      );
      (terminate ?? exit)(failed ? 1 : 0);
    }
  }

  @visibleForTesting
  Future<void> exitApplicationForTesting(
    void Function(int) terminate, {
    FutureOr<void> Function()? unlock,
    Future<void> Function()? cleanExit,
    Future<void> Function()? closeContentDatabases,
    Future<void> Function()? closeAppDatabase,
    StartupFailureReporter? failureReporter,
    Duration timeout = _exitTimeout,
  }) {
    return _quit(
      terminate: terminate,
      unlock: unlock,
      cleanExit: cleanExit,
      closeContentDatabases: closeContentDatabases,
      closeAppDatabase: closeAppDatabase,
      failureReporter: failureReporter,
      timeout: timeout,
    ).whenComplete(() {
      _exiting = null;
    });
  }

  void _runTrayAction(Future<void> Function() action) {
    unawaited(
      Future<void>.sync(action).catchError((Object error, StackTrace stack) {
        _log.error('Tray action failed', error: error, stackTrace: stack);
      }),
    );
  }
}

class _WindowCloseListener extends WindowListener {
  @override
  void onWindowClose() {
    // 区分"关窗最小化到托盘"与真正退出：关窗不退出进程，不应清除崩溃哨兵。
    _log.checkpoint('main window close intercepted; hiding to tray');
    Future.microtask(() async {
      await windowManager.hide();
    });
  }
}
