// 职责: 应用入口 — 初始化基础设施，显示启动 loading，数据初始化结束后挂载桌面/移动端业务界面。
// 关联文件:
//   lib/desktop/pages/home.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/services/app_initialization.dart
//   lib/shared/widgets/app_startup_gate.dart
//   lib/shared/services/single_instance_service.dart
//   lib/shared/services/system_tray_service.dart
//   lib/shared/services/crash_reporting/crash_sentinel.dart
//   lib/shared/services/crash_reporting/native_crash_reporting.dart
//   lib/shared/logger/log_manager.dart
//   lib/shared/logger/app_logger.dart
//   lib/shared/logger/flutter_error_logger.dart
//   lib/shared/logger/startup_failure_reporter.dart
import 'dart:async';
import 'shared/providers/depth.dart';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:drift/drift.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop/pages/home.dart';
import 'shared/widgets/app_startup_gate.dart';
import 'shared/widgets/file_workspace_startup_gate.dart';
import 'desktop/widgets/activation_failure_app.dart';
import 'shared/widgets/brand_loader.dart';
import 'desktop/widgets/settings/settings_dialog.dart';
import 'desktop/pages/onboarding.dart';
import 'mobile/app.dart';
import 'mobile/pages/settings_page.dart';
import 'shared/widgets/update/reminder.dart';
import 'mobile/pages/onboarding_page.dart';
import 'shared/database/app_database.dart' hide AppSettings;
import 'shared/localization/i18n_form_messages.dart';
import 'shared/localization/merging_asset_loader.dart';
import 'shared/providers/tool_operations.dart';
import 'shared/providers/video_tasks.dart';
import 'shared/providers/production_images.dart';
import 'shared/providers/production_audio.dart';
import 'shared/providers/agent_skill_catalog_providers.dart';
import 'shared/providers/official_skill_sync_providers.dart';
import 'shared/providers/anonymous_reporting_providers.dart';
import 'shared/providers/remote_bridge_providers.dart';
import 'shared/providers/settings_providers.dart';
import 'shared/services/ai/prompt_template.dart';
import 'shared/services/app_initialization.dart';
import 'shared/services/crash_reporting/crash_sentinel.dart';
import 'shared/services/lifecycle_visibility_guard.dart';
import 'shared/services/window_lifecycle_channel.dart';
import 'shared/services/crash_reporting/native_crash_reporting.dart';
import 'shared/logger/log_manager.dart';
import 'shared/logger/flutter_error_logger.dart';
import 'shared/logger/startup_failure_reporter.dart';
import 'shared/services/single_instance_service.dart';
import 'shared/services/system_notification_service.dart';
import 'shared/providers/ai_mode_processing.dart';
import 'shared/services/system_tray_service.dart';
import 'shared/services/window_state_service.dart';
import 'shared/theme/theme.dart';
import 'shared/utils/storage_paths.dart';
import 'shared/widgets/global_floating_chat.dart';
import 'shared/logger/app_logger.dart';
import 'third/form/flutter_hook_form.dart';

part 'main.g.dart';

final _log = AppLogger.forModule('Startup');

bool get _isMobilePlatform => Platform.isAndroid || Platform.isIOS;

/// 从进程启动开始计时：启动占位在各阶段反复挂载，隐藏期按总启动时长算，不按单次挂载算。
final _launchStopwatch = Stopwatch();

/// 启动这么久还在加载才淡入 logo；更快的启动全程只有背景色（与原生启动屏一致）。
const _kStartupShowDelay = Duration(milliseconds: 800);
bool get _isDesktopPlatform =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

Future<void> main() async {
  _launchStopwatch.start();
  WidgetsFlutterBinding.ensureInitialized();

  // 首先初始化日志服务，确保能捕获所有启动日志
  await LogManager.instance.initialize();
  installFlutterErrorLogger(
    reportErrorOverride: (error, stackTrace) {
      return StartupFailureReporter().report(
        phase: 'flutter_framework',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    _log.error(
      'Uncaught asynchronous error',
      error: error,
      stackTrace: stackTrace,
    );
    unawaited(
      StartupFailureReporter().report(
        phase: 'uncaught_async',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    return true;
  };

  try {
    await _startApplication();
  } catch (error, stackTrace) {
    _log.error(
      'Application startup failed',
      error: error,
      stackTrace: stackTrace,
    );
    try {
      await StartupFailureReporter().report(
        phase: 'application_startup',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      // 启动阶段已拿到单实例锁但尚未进入托盘退出流程时，也必须清理
      // activation server 与 sidecar 文件，避免下一次启动误读旧端口。
      await SingleInstanceService.unlock();
    }
    rethrow;
  }
}

Future<void> _startApplication() async {
  // 启动里程碑用 checkpoint（立即落盘）：启动期原生崩溃会丢缓冲日志，
  // 崩溃后据此判断死在哪个初始化阶段。
  _log.checkpoint('MAIN START');
  WidgetsFlutterBinding.ensureInitialized();
  _log.checkpoint('WidgetsFlutterBinding initialized');

  if (Platform.isMacOS) {
    _initMacOSAboutMenuHandler();
  }

  if (kDebugMode || _isMobilePlatform) {
    _log.debug('Debug mode or mobile platform: single instance lock skipped.');
  } else {
    if (!SingleInstanceService.tryLock()) {
      _log.info(
        'Another instance is already running. Activating it and exiting.',
      );
      // 关窗到托盘后用户只能通过应用图标再入：通知已运行实例唤起窗口再退出，
      // 否则第二实例静默退出，用户看到的就是"点了没反应"。
      final activation = await SingleInstanceService.notifyRunningInstance();
      switch (activation) {
        case InstanceActivationResult.activated:
        case InstanceActivationResult.starting:
          // 第一实例冷启动时会自行显示窗口，第二实例不弹错误也不初始化业务状态。
          exit(0);
        case InstanceActivationResult.failed:
          // 只显示独立故障窗口，不挂载 ProviderScope、不打开数据库，也不释放旧实例的锁。
          await showActivationFailureApp();
          return;
      }
    }
    await SingleInstanceService.startActivationServer();
  }

  // 崩溃哨兵与原生崩溃转储上报。必须放在单实例锁之后：
  // 第二实例会直接 exit(0)，不能误报崩溃，也不能误删运行中实例的 marker。
  await _initializeCrashReporting();
  _log.checkpoint('crash reporting initialized');

  // 缓存 Application Support 根目录，供 widget build() 同步解析存储路径使用。
  await RevericPaths.initialize();
  _log.checkpoint('RevericPaths initialized');

  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  _log.checkpoint('Drift configured');

  await EasyLocalization.ensureInitialized();
  _log.checkpoint('EasyLocalization initialized');

  // bundled AgentSkill 不再在启动时加载为可执行技能。运行时只读取当前小说的
  // NovelAgentSkill 快照;bundled 资产文件与解析器保留,供 Skill Import 预填表单。
  // 详见 docs/solutions/agent-skill-library-and-novel-installations.md。

  await _configureDesktopWindow();
  _log.checkpoint('Window configured');

  if (_isDesktopPlatform) {
    _log.checkpoint('initializing system tray (native)');
    final trayService = SystemTrayService();
    await trayService.init();
    // 第二实例启动时通过该回调唤起主窗口；此刻窗口已就绪。
    SingleInstanceService.onActivate = trayService.showMainWindow;
    _log.checkpoint('System tray initialized');
  }

  final cache = PaintingBinding.instance.imageCache;
  cache.maximumSizeBytes = 32 << 20;
  _log.info('ImageCache configured');

  _log.checkpoint('Running app...');
  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      fallbackLocale: const Locale('zh', 'CN'),
      startLocale: const Locale('zh', 'CN'),
      child: Builder(
        builder: (context) {
          final localization = EasyLocalization.of(context)!;
          return FileWorkspaceStartupGate(
            loading: const _StartupLoadingApp(),
            child: AppStartupGate(
              initialize: () async {
                // 初始化任务需要当前语言的名称；启动占位尚未挂载本地化 delegate。
                await localization.delegate.load(localization.locale);
                await _initializeAppData();
              },
              loading: const _StartupLoadingApp(),
              child: ProviderScope(
                overrides: [
                  if (_isDesktopPlatform)
                    mediaOperationsSupportedProvider.overrideWithValue(true),
                ],
                observers: [if (kDebugMode) _AsyncProviderTransitionObserver()],
                child: const _EagerInitialization(child: MyApp()),
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// 执行一次性种子与迁移任务，并在挂载业务 Provider 前释放数据库。
///
/// `AppStartupGate` 记录失败后继续启动，不做用户提示。只有成功的任务写完成
/// 标记，失败点及其之后的任务下次启动会重新执行。
Future<void> _initializeAppData() async {
  // 以下两项不影响启动占位的绘制，放在首帧之后执行；都在业务 ProviderScope
  // 挂载之前完成，业务侧看到的初始化顺序不变。
  // 各自兜底，任何一项失败都不能跳过后面的数据库初始化任务。
  await _runStartupStep('Prompt templates', PromptTemplateService.loadAll);
  await _runStartupStep(
    'Notifications',
    () => SystemNotificationService.initialize(),
  );

  _log.checkpoint('App initialization tasks START');
  final database = AppDatabase();
  try {
    await ensureAppInitializationTasks(
      database: database,
      tasks: defaultAppInitializationTasks(),
    );
    _log.checkpoint('App initialization tasks COMPLETE');
  } finally {
    await database.close();
  }
}

Future<void> _runStartupStep(String name, Future<void> Function() step) async {
  try {
    await step();
    _log.checkpoint('$name initialized');
  } catch (error, stackTrace) {
    _log.error(
      '$name initialization failed, continuing startup',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// 初始化 Windows 崩溃诊断：保存上次异常终止、写入本次会话 marker，
/// 配置原生崩溃转储（minidump），再后台上报历史 marker 与崩溃摘要。
/// 原生崩溃会绕过所有 Dart 错误处理，这里不试图捕获崩溃本身，
/// 而是保证"下次启动能看到上次死过、死前走到哪一步"。
Future<void> _initializeCrashReporting() async {
  // 目前只有非 Debug Windows 同时具备原生 minidump 与 runner 正常退出兜底；
  // 移动端/其它桌面端无法可靠区分系统终止与崩溃，Debug 还允许多实例，
  // 这些路径均不写会话 marker。
  if (!Platform.isWindows || kDebugMode) {
    return;
  }

  final logDirectory = LogManager.instance.logDirectory;
  if (logDirectory == null) {
    _log.warning('Log directory unavailable; crash reporting disabled.');
    return;
  }
  final sentinel = CrashSentinel(logDirectory: logDirectory);
  final previousSessionPreserved = await sentinel
      .preservePreviousSessionCrash();
  if (!previousSessionPreserved) {
    _log.error(
      'Previous session marker could not be preserved; '
      'crash reporting disabled for this launch to avoid evidence loss.',
    );
    return;
  }
  if (!await sentinel.markSessionStart()) {
    _log.error('Current session marker could not be written.');
    return;
  }

  final crashReporting = NativeCrashReporting();
  final dumpDir = await crashReporting.configure(
    sessionMarkerPath: sentinel.markerPath,
  );
  if (dumpDir != null && !await sentinel.markNativeHandlerConfigured()) {
    _log.warning(
      'Native crash handler is configured, but marker status update failed.',
    );
  }

  // 历史 marker 可能积压上百条，每条网络超时上限为 3 秒；必须在 active
  // marker 与原生 handler 初始化完成后后台串行补报，不能阻塞 runApp。
  unawaited(_reportPendingSessionCrashes(sentinel));
  if (dumpDir != null) {
    unawaited(crashReporting.reportPendingCrashes(dumpDir));
  }
}

Future<void> _reportPendingSessionCrashes(CrashSentinel sentinel) async {
  final allDelivered = await sentinel.reportPendingSessionCrashes();
  if (!allDelivered) {
    _log.warning(
      'Some previous session crash reports were not delivered; '
      'pending markers were retained for the next launch.',
    );
  }
}

/// 调试诊断:记录所有 Future/Stream provider 的值转换(名称 + 方向)。
///
/// 「Tried to modify a provider while the widget tree was building」的栈被
/// 日志截断在 5 帧,看不出是哪个 provider 在 build 期间转换;下次复现时按
/// 时间戳对照这里的记录即可定位。仅 debug 生效,定位完成后应移除。
final class _AsyncProviderTransitionObserver extends ProviderObserver {
  static final _observerLog = AppLogger.forModule('ProviderTransition');

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    final value = newValue;
    if (value is! AsyncValue) {
      return;
    }
    final kind = switch (value) {
      AsyncData() => 'data',
      AsyncError() => 'error',
      _ => 'loading',
    };
    _observerLog.info(
      '${context.provider.name ?? context.provider.runtimeType} -> $kind',
    );
  }
}

Future<void> _configureDesktopWindow() async {
  if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
    return;
  }

  _log.checkpoint('windowManager.ensureInitialized (native)');
  await windowManager.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final windowService = WindowStateService(prefs);
  final savedState = await windowService.loadWindowState();

  final windowOptions = WindowOptions(
    size: savedState.isMaximized || savedState.isFullScreen
        ? const Size(1280, 720)
        : Size(savedState.width, savedState.height),
    center: savedState.x == 0 && savedState.y == 0,
    titleBarStyle: TitleBarStyle.hidden,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowService.applyWindowState(savedState);
    _log.checkpoint('showing main window (native)');
    await windowManager.show();
    await windowManager.focus();

    windowService.startListening();
  });
  _log.checkpoint('main window shown');

  // 只有 macOS 需要 —— 病根是 macOS 引擎的 `_visible` 从不回读 NSApp 实况
  // （见 LifecycleVisibilityGuard 文档）。其他桌面平台的 hidden 都是真的，
  // 强改 resumed 反而会在真遮挡时空转出帧，且它们也没有实现该 channel。
  if (Platform.isMacOS) {
    LifecycleVisibilityGuard(channel: WindowLifecycleChannel()).install();
  }
}

void _initMacOSAboutMenuHandler() {
  const channel = MethodChannel('reveric/menu');
  channel.setMethodCallHandler((call) async {
    if (call.method != 'about') return;
    final context = SystemTrayService().navigatorKey.currentState?.context;
    if (context == null) return;
    showDialog(
      context: context,
      builder: (_) => const SettingsDialog(initialNavId: 'about'),
    );
  });
}

@riverpod
Future<bool> onboardingCompleted(Ref ref) async {
  _log.info('onboardingCompletedProvider START');
  final database = AppDatabase();
  ref.onDispose(database.close);
  _log.info('onboardingCompletedProvider: database created');
  final result = await hasCompletedOnboarding(database);
  _log.info('onboardingCompletedProvider: completed result=$result');
  return result;
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _log.info('MyApp build START');
    final themeMode = ref.watch(currentThemeModeProvider);
    final settingsAsync = ref.watch(appSettingsNotifierProvider);
    final onboardingAsync = ref.watch(onboardingCompletedProvider);
    final uiTextScale = settingsAsync.value?.uiTextScale ?? 1.0;

    // Keep cleanup scheduler alive for the app lifetime.
    ref.watch(storageCleanupSchedulerProvider);
    // Keep automatic backups scheduled for the app lifetime.
    ref.watch(autoBackupSchedulerProvider);

    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      ref.watch(videoTaskServiceProvider);
      ref.watch(providerAssetServiceProvider);
      ref.watch(imageTaskRecoveryProvider);
      ref.watch(audioTaskRecoveryProvider);
      if (Platform.isMacOS || Platform.isWindows) {
        ref.watch(depthTaskProvider);
      }
    }

    _log.info(
      'MyApp providers loaded '
      'settingsState=${settingsAsync.runtimeType} '
      'onboardingState=${onboardingAsync.runtimeType}',
    );

    return _buildSettingsFlow(
      context: context,
      ref: ref,
      themeMode: themeMode,
      settingsAsync: settingsAsync,
      onboardingAsync: onboardingAsync,
      uiTextScale: uiTextScale,
    );
  }

  Widget _buildSettingsFlow({
    required BuildContext context,
    required WidgetRef ref,
    required AppThemeMode themeMode,
    required AsyncValue<AppSettings> settingsAsync,
    required AsyncValue<bool> onboardingAsync,
    required double uiTextScale,
  }) {
    return settingsAsync.when(
      loading: () {
        _log.info('MyApp: settings loading');
        return _buildApp(
          context: context,
          themeMode: themeMode,
          themeData: RevericThemeData.classic,
          darkThemeData: RevericThemeData.classicDark,
          home: const _LoadingScreen(),
          uiTextScale: uiTextScale,
        );
      },
      error: (error, stack) {
        _log.error('MyApp: settings error', error: error, stackTrace: stack);
        return _buildApp(
          context: context,
          themeMode: themeMode,
          themeData: RevericThemeData.classic,
          darkThemeData: RevericThemeData.classicDark,
          home: const _LoadingScreen(),
          uiTextScale: uiTextScale,
        );
      },
      data: (settings) {
        _log.info('MyApp: settings loaded');
        final lightTheme = settings.themeDataForBrightness(Brightness.light);
        final darkTheme = settings.themeDataForBrightness(Brightness.dark);

        final Widget home;
        if (_isMobilePlatform) {
          // 移动端：走移动端 onboarding（仅填写用户名，无视频），完成后进入移动壳。
          home = onboardingAsync.when(
            loading: () {
              _log.info('MyApp: onboarding loading (mobile)');
              return const _LoadingScreen();
            },
            error: (error, stack) {
              _log.error(
                'MyApp: onboarding error (mobile)',
                error: error,
                stackTrace: stack,
              );
              return const MobileApp();
            },
            data: (completed) {
              _log.info(
                'MyApp: onboarding loaded completed=$completed (mobile)',
              );
              return completed
                  ? const MobileApp()
                  : const MobileOnboardingPage();
            },
          );
        } else {
          home = onboardingAsync.when(
            loading: () {
              _log.info('MyApp: onboarding loading');
              return const _LoadingScreen();
            },
            error: (error, stack) {
              _log.error(
                'MyApp: onboarding error',
                error: error,
                stackTrace: stack,
              );
              return const NovelHomePage();
            },
            data: (completed) {
              _log.info('MyApp: onboarding loaded completed=$completed');
              return completed ? const NovelHomePage() : const OnboardingPage();
            },
          );
        }

        return _buildApp(
          context: context,
          themeMode: themeMode,
          themeData: lightTheme,
          darkThemeData: darkTheme,
          home: home,
          uiTextScale: uiTextScale,
        );
      },
    );
  }

  Widget _buildApp({
    required BuildContext context,
    required AppThemeMode themeMode,
    required RevericThemeData themeData,
    required RevericThemeData darkThemeData,
    required Widget home,
    required double uiTextScale,
  }) {
    final flutterThemeMode = switch (themeMode) {
      AppThemeMode.light => ThemeMode.light,
      AppThemeMode.dark => ThemeMode.dark,
      AppThemeMode.system => ThemeMode.system,
    };
    final effectiveThemeData = _isMobilePlatform
        ? themeData.copyWith(typography: RevericTypography.mobile)
        : themeData;
    final effectiveDarkThemeData = _isMobilePlatform
        ? darkThemeData.copyWith(typography: RevericTypography.mobile)
        : darkThemeData;

    return MaterialApp(
      title: 'Reveric',
      debugShowCheckedModeBanner: false,
      navigatorKey: SystemTrayService().navigatorKey,
      theme: effectiveThemeData.toThemeData(),
      darkTheme: effectiveDarkThemeData.toThemeData(),
      themeMode: flutterThemeMode,
      locale: context.locale,
      supportedLocales: context.supportedLocales,
      localizationsDelegates: context.localizationDelegates,
      builder: (context, child) {
        final brightness = Theme.of(context).brightness;
        final activeData = brightness == Brightness.dark
            ? effectiveDarkThemeData
            : effectiveThemeData;
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(textScaler: TextScaler.linear(uiTextScale)),
          child: RevericTheme(
            data: activeData,
            child: AnnotatedRegion<SystemUiOverlayStyle>(
              value: activeData.systemUiOverlayStyle,
              child: HookFormScope(
                messages: const I18nFormErrorMessages(),
                child: Actions(
                  actions: <Type, Action<Intent>>{
                    DismissIntent: CallbackAction<DismissIntent>(
                      onInvoke: (_) => null,
                    ),
                  },
                  child: Stack(
                    children: [
                      ?child,
                      const AppLifecycleWatcher(),
                      if (_isDesktopPlatform) const GlobalFloatingChat(),
                      if (home is MobileApp || home is NovelHomePage)
                        UpdateReminder(
                          mobile: _isMobilePlatform,
                          onViewUpdate: () {
                            final navigatorContext = SystemTrayService()
                                .navigatorKey
                                .currentState!
                                .context;
                            if (_isMobilePlatform) {
                              showMobileAboutPage(navigatorContext);
                            } else {
                              showDialog<void>(
                                context: navigatorContext,
                                builder: (_) =>
                                    const SettingsDialog(initialNavId: 'about'),
                              );
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      home: home,
    );
  }
}

class _EagerInitialization extends ConsumerWidget {
  const _EagerInitialization({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 同步本地官方目录：安装新增技能，升级已有官方安装，保留用户删除选择。
    ref.watch(officialAgentSkillsProvider(agentSkillCatalogFilter()));
    ref.watch(officialSkillSyncProvider);
    // 预热远程桥接：coordinator 会级联实例化 bridge/forwarder 并触发
    // remoteBridgeAutoRestoreProvider（免扫码恢复 + 重挂 run 订阅 + 孤儿 run 对账 +
    // 仅桌面端：headless run 宿主与 bridge 都只存在于桌面端。
    if (_isDesktopPlatform) {
      ref.watch(assistantCoordinatorProvider);
    }
    return child;
  }
}

class AppLifecycleWatcher extends ConsumerStatefulWidget {
  const AppLifecycleWatcher({super.key});

  @override
  ConsumerState<AppLifecycleWatcher> createState() =>
      _AppLifecycleWatcherState();
}

class _AppLifecycleWatcherState extends ConsumerState<AppLifecycleWatcher>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 异步投递待发送的匿名诊断事件，不阻塞 UI。
    _flushPendingReports();
  }

  void _flushPendingReports() {
    // 等用户同意状态加载完成后再按上报条件投递；
    // 不阻塞 UI —— 仅异步 then，失败静默。
    ref.read(anonymousReportingConsentProvider.future).then((_) {
      if (!mounted) return;
      unawaited(ref.read(anonymousOutboxServiceProvider).flush());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (Platform.isMacOS || Platform.isWindows) {
      await ref.read(depthTaskProvider).stop();
    }
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached &&
        (Platform.isMacOS || Platform.isWindows)) {
      unawaited(ref.read(depthTaskProvider).stop());
    }
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      ref
          .read(videoTaskServiceProvider)
          .asData
          ?.value
          .setForeground(state == AppLifecycleState.resumed);
    }
    ref
        .read(aiModeProcessingTrackerProvider.notifier)
        .setAppForeground(
          // 仅在 AppLifecycleState.resumed 时视为"前台"，
          // paused（不可见）/ hidden（macOS 最小化）等均视为"后台"
          state == AppLifecycleState.resumed,
        );
    if (state != AppLifecycleState.resumed) {
      // 最小化/隐藏/退出等生命周期切换经过引擎原生路径，崩溃高发；
      // checkpoint 立即落盘，崩溃后可据此定位最后状态。resumed 不打（高频）。
      AppLogger.checkpoint('[Lifecycle] $state');
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(anonymousOutboxServiceProvider).flush());
      unawaited(ref.read(autoBackupSchedulerProvider).checkNow());
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 启动占位不读取用户设置，也不挂载任何业务 Provider。
class _StartupLoadingApp extends StatelessWidget {
  const _StartupLoadingApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: RevericThemeData.classic.toThemeData(),
      darkTheme: RevericThemeData.classicDark.toThemeData(),
      builder: (context, child) => RevericTheme(
        data: Theme.of(context).brightness == Brightness.dark
            ? RevericThemeData.classicDark
            : RevericThemeData.classic,
        child: child!,
      ),
      home: const _LoadingScreen(),
    );
  }
}

/// 启动各阶段（初始化、版本检查、设置、onboarding 状态）都会重新挂载这个占位，
/// 所以跳过入场直接从循环态开始，避免每个阶段重播一次 logo 描线。
class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final remaining = _kStartupShowDelay - _launchStopwatch.elapsed;

    return Scaffold(
      backgroundColor: colors.canvas,
      body: BrandLoader(
        skipIntro: true,
        showDelay: remaining.isNegative ? Duration.zero : remaining,
      ),
    );
  }
}
