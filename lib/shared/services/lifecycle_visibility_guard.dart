// 职责: 纠正 macOS 引擎「窗口可见却上报 hidden」导致的 UI 永久停帧，并记录停帧诊断
// 关联文件:
//   lib/main.dart
//   lib/shared/services/window_lifecycle_channel.dart
//   macos/Runner/MainFlutterWindow.swift
//   lib/shared/logger/app_logger.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../logger/app_logger.dart';
import 'window_lifecycle_channel.dart';

final _log = AppLogger.forModule('Lifecycle');

/// 「窗口可见但引擎报 hidden」的纠正与停帧诊断。仅 macOS 使用。
///
/// ## 引擎侧的病根
///
/// `FlutterEngine` 把 `_active` / `_visible` 初始化为 NO，`_visible` 此后**只有**
/// `handleDidChangeOcclusionState:` 会置位（FlutterEngine.mm）。本 app 启动时窗口先
/// 隐藏、等 window_manager 恢复几何后才 show()；若这期间 macOS 没有投递应用级
/// occlusion **变化**通知，`_visible` 就永远停在 NO。之后每次 will-become-active /
/// will-resign-active 都会因 `if (!_visible)` 再发一次 hidden。hidden 会把
/// `SchedulerBinding.framesEnabled` 置为 false，`scheduleFrame()` 直接 no-op，UI 永久
/// 冻结在最后一帧。指针事件不看 framesEnabled 仍会派发，所以表现为「界面出来了但点了
/// 没反应」；冻结发生在首帧前则表现为「卡在 loading 页」。
///
/// ## 为什么不能靠「收到非 hidden 状态就解除守卫」
///
/// 早期实现（`f0e050143`）在强改 resumed 之后，把任何非 hidden 状态当作引擎已经健康
/// 的证据而解除守卫。这条件不可能成立：
///
/// - Dart 侧一旦处于 resumed，`ServicesBinding._generateStateTransitions` 会把引擎的
///   下一个 hidden 补成 `[inactive, hidden]` 两次派发，守卫正好被那个**合成的**
///   inactive 在它要拦截的 hidden 前一步解除，停帧从此无人纠正。
/// - 反过来，引擎真发 resumed 时因 `previousState == state` 返回空列表，一次派发都
///   没有 —— 「引擎自证健康」压根不是可观测事件。
///
/// ## 为什么这个 bug 修了四轮还在复发
///
/// 前几轮（`f0e050143`、`935fdb6e4`）每次都在升级「怎么证明窗口是可见的」，守卫的
/// 形状却一直没变：**先拿到可见性的正面证据，才允许出帧**。这个形状有两个结构性
/// 缺陷，换证据源治不了：
///
/// - **向失灵的系统索要「你没失灵」的证明。** 故障的定义就是 macOS 没把可见性交给
///   引擎。round 1 拿 Dart 状态流当证据，被框架合成的 inactive 骗了；round 4 换成
///   `NSApp.occlusionState`，而它在窗口 order in 之后是异步更新的，滞后期内即使应用
///   已经 active + key 也仍报 false。换一个证据源就换一种失效方式。
/// - **补救是一次性的，过期即永久死亡。** 启动轮询 30 × 300ms 后停表，原生重试 2 秒
///   后 `sync gave up`，此后唯一的重新触发点是 [didChangeAppLifecycleState] —— 而
///   Dart 侧已经停在 hidden，引擎再发 hidden 时 `previousState == state` 让
///   `_generateStateTransitions` 返回空列表，回调**再也不会来**。于是「启动那几秒里
///   猜错」直接等于「这个进程的余生都是冻的」。
///
/// ## 现在的做法：反转这两条
///
/// - **举证责任反转**（[WindowVisibilitySnapshot.shouldBeRendering]）：应用 active 且
///   窗口是 key window 时，occlusion 的 false 一律不采信 —— 前台且持有键盘焦点的窗口
///   不可能被盖住。只有「没 order in / 已最小化」这类确凿证据才判定该停帧。
/// - **补救常驻化**（[_recoverStalledFrames]）：看门狗不再是 debug 专属的一次性日志，
///   而是全构建模式常驻、真正执行纠正。守卫因此不再依赖「在正确的时刻拿到正确的
///   证据」，只需要「迟早拿到」；任何一次判断失误都退化成恢复延迟，而不是永久冻结。
///
/// 纠正路径本身沿用 round 4：收到 hidden / paused 时先请求原生把 NSApp 的真实
/// occlusion 回灌给引擎（[WindowLifecycleChannel]），引擎内部据实分支，真被遮挡就照旧
/// 停帧、不会空转；只有回灌之后仍然停在 hidden，才退回强改 resumed 兜底。
class LifecycleVisibilityGuard with WidgetsBindingObserver {
  LifecycleVisibilityGuard({
    required this._channel,
    this._startupPollInterval = const Duration(milliseconds: 300),
    this._startupPolls = 30,
    this._reseedGracePeriod = const Duration(milliseconds: 400),
    this._watchdogInterval = const Duration(seconds: 5),
  });

  final WindowLifecycleChannel _channel;
  final Duration _startupPollInterval;
  final int _startupPolls;
  final Duration _reseedGracePeriod;
  final Duration _watchdogInterval;

  bool _installed = false;
  bool _correcting = false;
  bool _correctionInFlight = false;
  Timer? _watchdog;
  Timer? _startupPoll;
  int _startupPollsLeft = 0;
  bool _stallReported = false;

  /// 注册守卫、启动期快速轮询，以及常驻停帧看门狗。
  ///
  /// 两个 timer 分工：启动期轮询只负责**快**（300ms 一次，避免冷启动时用户盯着冻住的
  /// loading 页等看门狗的 5 秒），看门狗负责**兜底**（常驻不停表，所有构建模式都跑）。
  /// 看门狗不能再像 round 4 那样只在 debug 下开 —— release 包的引擎是同一个引擎，
  /// 冻结照样发生，而那时没有任何东西还会重试。
  ///
  /// 两个后台动作都用可取消的 [Timer] 而不是 `Future.delayed` 循环 —— 后者留下的
  /// 挂起 timer 无法取消，[dispose] 之后仍会让 widget 测试的 `!timersPending` 失败。
  void install() {
    if (_installed) {
      return;
    }
    _installed = true;
    WidgetsBinding.instance.addObserver(this);

    _startupPollsLeft = _startupPolls;
    _startupPoll = Timer.periodic(_startupPollInterval, (_) {
      unawaited(_pollOnce());
    });

    _watchdog = Timer.periodic(_watchdogInterval, (_) {
      unawaited(_recoverStalledFrames());
    });
  }

  void dispose() {
    if (!_installed) {
      return;
    }
    _installed = false;
    _stopStartupPoll();
    _watchdog?.cancel();
    _watchdog = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kDebugMode) {
      final binding = WidgetsBinding.instance;
      _log.info(
        'state=${state.name} source=${_correcting ? 'guard-forced' : 'engine'} '
        'framesEnabled=${binding.framesEnabled} '
        'hasScheduledFrame=${binding.hasScheduledFrame}',
      );
    }
    if (_correcting || !_stopsFrames(state)) {
      return;
    }
    unawaited(correctIfEngineIsWrong());
  }

  /// 启动期窗口还没 show()，引擎的 hidden 可能早于本 observer 注册就已到达，
  /// 拿不到状态变化回调；这里轮询到状态不再停帧为止，之后交给 observer。
  Future<void> _pollOnce() async {
    if (!_installed) {
      return;
    }
    if (_startupPollsLeft <= 0 ||
        !_stopsFrames(WidgetsBinding.instance.lifecycleState)) {
      _stopStartupPoll();
      return;
    }
    _startupPollsLeft -= 1;
    await correctIfEngineIsWrong();
  }

  void _stopStartupPoll() {
    _startupPoll?.cancel();
    _startupPoll = null;
    _startupPollsLeft = 0;
  }

  /// 引擎报了停帧状态时核对原生实况，必要时纠正。返回是否强改过 Dart 侧状态。
  Future<bool> correctIfEngineIsWrong() async {
    if (_correctionInFlight) {
      return false;
    }
    _correctionInFlight = true;
    try {
      final binding = WidgetsBinding.instance;
      if (!_installed || !_stopsFrames(binding.lifecycleState)) {
        return false;
      }

      // 回灌本身就可能治好：引擎读到真实 occlusion 后会自己发出 resumed。
      final WindowVisibilitySnapshot snapshot;
      try {
        snapshot = await _channel.reseedEngineVisibility();
      } on PlatformException catch (error, stackTrace) {
        _log.error(
          'Failed to read native window visibility; '
          'leaving engine lifecycle untouched',
          error: error,
          stackTrace: stackTrace,
        );
        return false;
      } on MissingPluginException catch (error, stackTrace) {
        _log.error(
          'reveric/window_lifecycle is not implemented on this platform; '
          'the guard should not have been installed',
          error: error,
          stackTrace: stackTrace,
        );
        return false;
      }

      if (!snapshot.shouldBeRendering) {
        // 真遮挡 / 最小化 —— 这个 hidden 是对的，让帧照常停下。
        if (kDebugMode) {
          _log.info('hidden is genuine, no correction ($snapshot)');
        }
        return false;
      }

      await Future<void>.delayed(_reseedGracePeriod);
      if (!_installed || !_stopsFrames(binding.lifecycleState)) {
        if (kDebugMode) {
          _log.info('engine recovered after reseed, no forcing needed');
        }
        return false;
      }

      _log.warning(
        'Window is on screen but engine lifecycle is still '
        '${binding.lifecycleState?.name}; forcing AppLifecycleState.resumed '
        'after native reseed did not take effect ($snapshot).',
      );
      _correcting = true;
      try {
        // 直接通知 binding 不会经过 ServicesBinding 的状态补齐；必须逐步恢复，
        // 否则 AppLifecycleListener 会拒绝 hidden / paused → resumed。
        if (binding.lifecycleState == AppLifecycleState.paused) {
          // ignore: invalid_use_of_protected_member
          binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        }
        // ignore: invalid_use_of_protected_member
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        // ignore: invalid_use_of_protected_member
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      } finally {
        _correcting = false;
      }
      return true;
    } finally {
      _correctionInFlight = false;
    }
  }

  /// 常驻停帧看门狗 —— 帧死了定时器照跑，所以它是冻结现场唯一还能说话、也是唯一还能
  /// 动手的东西。
  ///
  /// 它存在的理由不是诊断，是打破死局：引擎一旦停在 hidden，就不会再有任何生命周期
  /// 回调把守卫叫醒（同状态被 `_generateStateTransitions` 去重）。没有这个 timer，
  /// 启动期那几秒是守卫**仅有**的一次机会。
  ///
  /// 先用便宜的 [WindowLifecycleChannel.getVisibilityState] 采样，确认该出帧了才升级到
  /// [correctIfEngineIsWrong]（要回灌 + 等宽限期）。真被遮挡的稳态下每 tick 只有一次
  /// channel 往返。
  Future<void> _recoverStalledFrames() async {
    final binding = WidgetsBinding.instance;
    if (!_installed) {
      return;
    }
    if (binding.framesEnabled) {
      _stallReported = false;
      return;
    }
    if (!_stopsFrames(binding.lifecycleState)) {
      // 停帧但不是生命周期造成的（例如还没挂上可出帧的树），不归守卫管。
      return;
    }

    final WindowVisibilitySnapshot snapshot;
    try {
      snapshot = await _channel.getVisibilityState();
    } on PlatformException catch (error, stackTrace) {
      _log.error(
        'Frame watchdog could not read native window visibility',
        error: error,
        stackTrace: stackTrace,
      );
      return;
    } on MissingPluginException catch (error, stackTrace) {
      _log.error(
        'reveric/window_lifecycle is not implemented on this platform; '
        'the guard should not have been installed',
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }

    if (!snapshot.shouldBeRendering) {
      return;
    }

    if (!_stallReported) {
      // 每次停帧只报一次，恢复出帧后才重新武装 —— 纠正失败时不至于每 tick 刷屏。
      _stallReported = true;
      _log.warning(
        'STALLED: frames disabled while the window is on screen; recovering. '
        'lifecycle=${binding.lifecycleState?.name} '
        'hasScheduledFrame=${binding.hasScheduledFrame} native($snapshot)',
      );
    }
    await correctIfEngineIsWrong();
  }

  /// 不含 `detached`：那是引擎尚未附着视图的状态，把它改成 resumed 只会掩盖别的问题。
  /// macOS 引擎本身也只会发出 resumed / inactive / hidden 三种。
  static bool _stopsFrames(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
}
