// 职责: 提供页面自动触发分步引导的 Hook、调试强制触发接入、防重叠锁与统一重播按钮。
// 关联文件:
//   lib/shared/widgets/guide/tour.dart
//   lib/shared/widgets/guide/overlay.dart
//   lib/shared/services/debug/guide_force_show.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/components/reveric_icon_button.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/onboarding.json
//   assets/translations/zh-CN/onboarding.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/code-style.md
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_icon_button.dart';
import '../../database/app_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../providers/novel_providers.dart';
import '../../services/debug/guide_force_show.dart';
import '../../theme/theme.dart';
import 'overlay.dart';
import 'tour.dart';

final _log = AppLogger.forModule('GuideTour');

/// 全局自动触发开关（默认开启；仅供与引导无关的隔离 widget 测试按需覆盖关闭）。
final guideTourAutoTriggerProvider = Provider<bool>((ref) => true);

/// 全局并发锁，避免相邻页面或子组件同时弹出两套引导遮罩。
bool _isGuideTourActive = false;

/// 测试辅助：在异常中断场景下复位全局锁。
@visibleForTesting
void resetGuideTourLockForTest() {
  _isGuideTourActive = false;
}

/// 供页面手动重播当前引导的句柄。
class GuideTourHandle {
  const GuideTourHandle({required this.replay});

  final Future<void> Function() replay;
}

/// 在页面挂载后按需自动运行引导，并返回 [GuideTourHandle] 供 `?` 按钮随时重播。
///
/// - [ready] 表示页面核心数据与锚点已完成渲染，为 false 时不会触发（即使开启调试开关）。
/// - [eligible] 表示业务前置条件（如供应商尚未配置）；开启调试开关 [guideDebugForceShowNotifier]
///   时会忽略 [eligible] 与已看过记录，且调试期间不写入 `guide_tour_seen.*`。
GuideTourHandle useAutoGuideTour({
  required WidgetRef ref,
  required GuideTourId tourId,
  required List<GuideStep> Function(BuildContext context) buildSteps,
  bool ready = true,
  bool eligible = true,
  List<Object?> keys = const [],
}) {
  final context = useContext();
  final autoTriggerAllowed = ref.watch(guideTourAutoTriggerProvider);
  final forceShow = useValueListenable(guideDebugForceShowNotifier);
  final buildStepsRef = useRef(buildSteps);
  buildStepsRef.value = buildSteps;
  final attemptedKey = useRef<(GuideTourId, bool)?>(null);

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

  Future<void> runTour({required bool persist}) async {
    if (_isGuideTourActive || !context.mounted) {
      return;
    }
    final steps = buildStepsRef.value(context);
    if (steps.isEmpty || !context.mounted) {
      return;
    }
    _isGuideTourActive = true;
    try {
      await showGuideTour(context, steps: steps);
    } finally {
      _isGuideTourActive = false;
      if (persist) {
        final db = tryReadDatabase();
        if (db != null) {
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
      }
    }
  }

  final runRef = useRef(runTour);
  runRef.value = runTour;

  final shouldAttempt =
      ready && (forceShow || (autoTriggerAllowed && eligible));

  useEffect(() {
    if (!shouldAttempt) {
      return null;
    }
    final currentKey = (tourId, forceShow);
    if (attemptedKey.value == currentKey) {
      return null;
    }
    attemptedKey.value = currentKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        if (!context.mounted || _isGuideTourActive) {
          return;
        }
        if (forceShow) {
          await runRef.value(persist: false);
          return;
        }
        final db = tryReadDatabase();
        if (db == null || !context.mounted) {
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
        if (seen || !context.mounted) {
          return;
        }
        await runRef.value(persist: true);
      }());
    });
    return null;
  }, [tourId, shouldAttempt, forceShow, ...keys]);

  return GuideTourHandle(replay: () => runRef.value(persist: !forceShow));
}

/// 统一的引导重播图标按钮（Phosphor `question` 图标）。
class GuideReplayButton extends StatelessWidget {
  const GuideReplayButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return RevericIconButton(
      icon: RevericIcons.help_outline,
      tooltip: context.t(LocaleKeys.onboardingGuideReplayTooltip),
      onPressed: onPressed,
    );
  }
}
