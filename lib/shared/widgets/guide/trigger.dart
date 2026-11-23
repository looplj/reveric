// 职责: 提供页面自动触发分步引导的 Hook、调试强制触发接入与防重叠锁。
// 关联文件:
//   lib/shared/widgets/guide/tour.dart
//   lib/shared/widgets/guide/overlay.dart
//   lib/shared/services/debug/guide_force_show.dart
//   lib/shared/providers/novel_providers.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/code-style.md
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../providers/novel_providers.dart';
import '../../services/debug/guide_force_show.dart';
import 'overlay.dart';
import 'tour.dart';

final _log = AppLogger.forModule('GuideTour');

/// 全局自动触发开关（默认开启；仅供与引导无关的隔离 widget 测试按需覆盖关闭）。
final guideTourAutoTriggerProvider = Provider<bool>((ref) => true);

/// 全局并发锁，避免相邻页面或子组件同时弹出两套引导遮罩。
bool _isGuideTourActive = false;

/// 父引导在子引导结束、等待下一帧恢复前的占位标识，避免交接空窗期被其他页面抢占。
GuideTourId? _pendingResumeTourId;

/// 测试辅助：在异常中断场景下复位全局锁和首页后续引导队列。
@visibleForTesting
void resetGuideTourLockForTest() {
  _isGuideTourActive = false;
  _pendingResumeTourId = null;
  guideTourChain.reset();
}

/// 等到下一帧渲染完成后继续（用于子页面切回后再打开父引导）。
Future<void> _afterNextFrame() {
  final done = Completer<void>();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!done.isCompleted) {
      done.complete();
    }
  });
  WidgetsBinding.instance.ensureVisualUpdate();
  return done.future;
}

/// 当前正在依次展示的子页面引导队列。
///
/// 当前项挂在 [current] 上。对应页面的引导完成时前进，跳过或关闭时清空并通知父引导中止。
final class GuideTourChain {
  GuideTourChain._();

  final List<GuideTourId> _queue = [];
  final ValueNotifier<GuideTourId?> current = ValueNotifier(null);
  Completer<bool>? _completion;
  bool _hasParentResume = false;
  bool _lastEndedByCancel = false;

  /// 最近一次状态变更是否由跳过/取消触发，供移动端判断是否应自动关闭子页路由。
  bool get lastEndedByCancel => _lastEndedByCancel;

  /// [id] 作为当前链中项时，完成后后面是否还有其他子引导或父引导剩余步骤。
  bool hasNextAfter(GuideTourId id) {
    return current.value == id && (_queue.length > 1 || _hasParentResume);
  }

  /// 启动一串子页面引导；全部完成返回 true，中途跳过或取消返回 false。
  Future<bool> run(List<GuideTourId> ids, {bool hasParentResume = false}) {
    cancel();
    if (ids.isEmpty) {
      _lastEndedByCancel = false;
      return Future.value(true);
    }
    _lastEndedByCancel = false;
    _hasParentResume = hasParentResume;
    final completer = Completer<bool>();
    _completion = completer;
    _queue.addAll(ids);
    current.value = _queue.first;
    return completer.future;
  }

  void advance() {
    _lastEndedByCancel = false;
    if (_queue.isNotEmpty) {
      _queue.removeAt(0);
    }
    if (_queue.isEmpty) {
      _hasParentResume = false;
      current.value = null;
      final completer = _completion;
      _completion = null;
      if (completer != null && !completer.isCompleted) {
        completer.complete(true);
      }
      return;
    }
    current.value = _queue.first;
  }

  void cancel() {
    final completer = _completion;
    _completion = null;
    _hasParentResume = false;
    _lastEndedByCancel = true;
    if (_queue.isNotEmpty || current.value != null) {
      _queue.clear();
      current.value = null;
    }
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
  }

  void reset() {
    cancel();
    _lastEndedByCancel = false;
  }
}

final guideTourChain = GuideTourChain._();

/// 在页面挂载后按需自动运行引导。
///
/// - [ready] 表示页面核心数据与锚点已完成渲染，为 false 时不会触发（即使开启调试开关）。
/// - [eligible] 表示业务前置条件（如供应商尚未配置）；开启调试开关 [guideDebugForceShowNotifier]
///   时会忽略 [eligible] 与已看过记录，且调试期间不写入 `guide_tour_seen.*`。
void useAutoGuideTour({
  required WidgetRef ref,
  required GuideTourId tourId,
  required List<GuideStep> Function(BuildContext context) buildSteps,
  bool ready = true,
  bool eligible = true,
  List<Object?> keys = const [],
  void Function(bool completed)? onClosed,
}) {
  final context = useContext();
  final autoTriggerAllowed = ref.watch(guideTourAutoTriggerProvider);
  final forceShow = useValueListenable(guideDebugForceShowNotifier);
  final chainId = useValueListenable(guideTourChain.current);
  final inChain = chainId == tourId;
  final buildStepsRef = useRef(buildSteps);
  buildStepsRef.value = buildSteps;
  final onClosedRef = useRef(onClosed);
  onClosedRef.value = onClosed;
  final attemptedKey = useRef<(GuideTourId, bool)?>(null);
  final prevInChain = useRef(false);
  final enteredChain = inChain && !prevInChain.value;
  prevInChain.value = inChain;

  AppDatabase? tryReadDatabase() {
    try {
      return ref.read(appDatabaseProvider);
    } catch (error) {
      if (_log.isDebugEnabled) {
        _log.debug('Skip guide tour=$tourId: database unavailable ($error)');
      }
      return null;
    }
  }

  Future<List<GuideTourId>> filterPendingChildren(
    List<GuideTourId> childTours, {
    required bool includeSeen,
  }) async {
    if (includeSeen || childTours.isEmpty) {
      return childTours;
    }
    final db = tryReadDatabase();
    if (db == null) {
      return const [];
    }
    final pending = <GuideTourId>[];
    for (final childId in childTours) {
      try {
        if (!await hasSeenGuideTour(db, childId)) {
          pending.add(childId);
        }
      } catch (error) {
        if (_log.isDebugEnabled) {
          _log.debug(
            'Skip child guide tour=$childId: state read failed ($error)',
          );
        }
      }
    }
    return pending;
  }

  Future<void> runTour({required bool persist}) async {
    if (_isGuideTourActive || !context.mounted) {
      return;
    }
    var stepIndex = 0;
    var completed = false;
    var markedSeen = false;

    Future<void> persistSeenIfNeeded() async {
      if (!persist || markedSeen) {
        return;
      }
      markedSeen = true;
      final db = tryReadDatabase();
      if (db == null) {
        return;
      }
      try {
        await markGuideTourSeen(db, tourId);
      } catch (error, stackTrace) {
        _log.error(
          'Failed to mark guide tour seen tour=$tourId',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    while (true) {
      if (!context.mounted) {
        break;
      }
      if (_isGuideTourActive) {
        completed = false;
        break;
      }
      final steps = buildStepsRef.value(context);
      if (steps.isEmpty || stepIndex >= steps.length) {
        completed = stepIndex >= steps.length;
        break;
      }
      final hasFollowingTour = guideTourChain.hasNextAfter(tourId);
      if (_pendingResumeTourId == tourId) {
        _pendingResumeTourId = null;
      }
      _isGuideTourActive = true;
      late final GuideTourResult result;
      try {
        if (!context.mounted) {
          break;
        }
        result = await showGuideTour(
          context,
          steps: steps,
          initialStepIndex: stepIndex,
          hasFollowingTour: hasFollowingTour,
        );
      } finally {
        // 必须在任何异步写库或后续跳转之前同步释放锁，避免目标页首帧撞锁被吞掉。
        _isGuideTourActive = false;
      }

      switch (result) {
        case GuideTourCompleted():
          completed = true;
          await persistSeenIfNeeded();
        case GuideTourDismissed():
          completed = false;
          await persistSeenIfNeeded();
        case GuideTourPausedForChildren(
          :final childTours,
          :final resumeStepIndex,
        ):
          await persistSeenIfNeeded();
          final pendingChildren = await filterPendingChildren(
            childTours,
            includeSeen: !persist,
          );
          if (!context.mounted) {
            completed = false;
            break;
          }
          if (pendingChildren.isNotEmpty) {
            final childrenCompleted = await guideTourChain.run(
              pendingChildren,
              hasParentResume: resumeStepIndex < steps.length,
            );
            if (!childrenCompleted || !context.mounted) {
              completed = false;
              break;
            }
            if (resumeStepIndex >= steps.length) {
              completed = true;
              break;
            }
            _pendingResumeTourId = tourId;
            try {
              await _afterNextFrame();
            } finally {
              if (_pendingResumeTourId == tourId) {
                _pendingResumeTourId = null;
              }
            }
            if (!context.mounted) {
              completed = false;
              break;
            }
          }
          stepIndex = resumeStepIndex;
          if (stepIndex >= steps.length) {
            completed = true;
            break;
          }
          continue;
      }
      break;
    }

    if (_pendingResumeTourId == tourId) {
      _pendingResumeTourId = null;
    }

    if (context.mounted) {
      onClosedRef.value?.call(completed);
    }
    if (guideTourChain.current.value == tourId) {
      if (completed) {
        guideTourChain.advance();
      } else {
        guideTourChain.cancel();
      }
    }
  }

  final runRef = useRef(runTour);
  runRef.value = runTour;

  final shouldAttempt =
      ready && (forceShow || inChain || (autoTriggerAllowed && eligible));

  useEffect(() {
    if (!shouldAttempt) {
      return null;
    }
    final currentKey = (tourId, forceShow);
    if (!enteredChain && attemptedKey.value == currentKey) {
      return null;
    }
    attemptedKey.value = currentKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        if (!context.mounted) {
          return;
        }
        final blockedByOther =
            _isGuideTourActive ||
            (_pendingResumeTourId != null && _pendingResumeTourId != tourId);
        if (blockedByOther) {
          if (attemptedKey.value == currentKey) {
            attemptedKey.value = null;
          }
          return;
        }
        if (forceShow) {
          await runRef.value(persist: false);
          return;
        }
        final db = tryReadDatabase();
        if (db == null || !context.mounted) {
          if (guideTourChain.current.value == tourId) {
            guideTourChain.advance();
          }
          return;
        }
        bool seen;
        try {
          seen = await hasSeenGuideTour(db, tourId);
        } catch (error) {
          if (_log.isDebugEnabled) {
            _log.debug('Skip guide tour=$tourId: state read failed ($error)');
          }
          return;
        }
        if (!context.mounted) {
          return;
        }
        if (seen) {
          if (guideTourChain.current.value == tourId && !forceShow) {
            guideTourChain.advance();
          }
          return;
        }
        await runRef.value(persist: true);
      }());
    });
    return null;
  }, [tourId, shouldAttempt, forceShow, inChain, ...keys]);
}
