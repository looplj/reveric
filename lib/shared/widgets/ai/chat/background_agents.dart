// 职责: 在聊天输入区上方以单行摘要呈现后台子任务，并提供详情、单项停止和全部停止。
// 关联文件:
//   lib/shared/providers/ai_providers.dart
//   lib/shared/providers/spawn_agent_run_providers.dart
//   lib/shared/widgets/ai/tools/spawn_agent_identity.dart
//   lib/shared/widgets/ai/tools/spawn_agent_tool_card_body.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/zh-CN/tool.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/performance.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../components/reveric_button.dart';
import '../../../components/reveric_icon_button.dart';
import '../../../components/reveric_surfaces.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../models/ai_chat_models.dart';
import '../../../providers/ai_providers.dart';
import '../../../providers/spawn_agent_run_providers.dart';
import '../../../services/ai/spawn_agent_handler.dart';
import '../../../theme/theme.dart';
import '../tools/spawn_agent_identity.dart';
import '../tools/spawn_agent_tool_card_body.dart';

final _log = AppLogger.forModule('BackgroundAgents');

/// 结束回执停留时长。它只回答「跑完了吗」，结果本身留在消息流的卡片里。
const _receiptRetention = Duration(seconds: 6);

/// 名字列上限。子 agent 名字通常两三个字，超长截断把宽度让给 agent 名。
const _nameMaxWidth = 96.0;

/// 列表最多常显 4 行，再多内部滚动；不按屏高比例吃聊天区。
const _maxVisibleRows = 4;

/// 结束后短暂留在条上的回执。不含结果负载，点详情回到子会话。
class _BackgroundReceipt {
  const _BackgroundReceipt({
    required this.runId,
    required this.block,
    required this.name,
    required this.agentName,
    required this.cancelled,
    required this.failed,
  });

  final String runId;
  final AiToolCallBlock block;
  final String name;
  final String agentName;
  final bool cancelled;
  final bool failed;
}

/// 列表和卡片共用一份 run 身份，这样头像和详情入口都能复用工具卡组件。
AiToolCallBlock _blockForRun(SpawnAgentRunRecord run) {
  return AiToolCallBlock(
    id: run.runId,
    callId: run.callId!,
    toolName: 'SpawnAgent',
    arguments: {'agent': run.agentName, 'name': run.name, 'task': run.task},
    status: AiToolCallStatus.running,
    result: {'session_id': run.subSessionId, 'run_id': run.runId},
    metadata: {
      'background_run': {'status': run.status.name},
    },
  );
}

String _formatElapsed(Duration elapsed) {
  final total = elapsed.isNegative ? Duration.zero : elapsed;
  final minutes = total.inMinutes;
  final seconds = total.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// 行内方形控件的边长：桌面 32、移动端 48，与 RevericIconButton 的点击区一致。
/// 同时也是每行的最小高度和回执行里停止键空槽的宽度 —— 汇总行的折叠箭头、任务行
/// 的停止键共用它，右侧控件才会落在同一条竖线上。
double backgroundStripControlSize(BuildContext context) {
  return switch (Theme.of(context).platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS => RevericSizes.touchTargetSize,
    _ => RevericSizes.iconButtonSize,
  };
}

/// 汇总、任务和回执行共用右侧轴线，并与各平台 Composer 的发送图标对齐。
EdgeInsets backgroundStripRowPadding(BuildContext context) {
  final right = switch (Theme.of(context).platform) {
    // 移动端控件槽比 Composer 的 40px 发送按钮宽 8px，右留白相应少 4px。
    TargetPlatform.android || TargetPlatform.iOS => RevericSpacing.xs,
    // 卡片边框占 1px；桌面 Composer 的 DecoratedBox 不占布局空间。
    _ => RevericSpacing.sm - RevericSizes.dividerThickness,
  };
  return EdgeInsets.only(left: RevericSpacing.lg, right: right);
}

class BackgroundAgents extends HookConsumerWidget {
  const BackgroundAgents({
    super.key,
    required this.sessionId,
    this.novelId,
    this.databasePath,
  });

  final String? sessionId;
  final String? novelId;
  final String? databasePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = useState(true);
    final stoppingAll = useState(false);
    final error = useState<String?>(null);
    final receipts = useState<List<_BackgroundReceipt>>(const []);
    final tracked = useRef(<String, SpawnAgentRunRecord>{});
    final timers = useRef(<Timer>[]);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final stopFailure = context.t(LocaleKeys.aiBackgroundStopFailed);
    final subAgents = ref.watch(
      aiChatRuntimeProvider(sessionId).select((value) => value.subAgents),
    );
    final runs = subAgents.runs.where((run) => run.background).toList();

    // run 一结束就从 runtime 列表消失，所以回执按「消失」判定；结果读已落库的
    // 卡片 metadata，因此自然完成、失败和 stopAll 取消能区分开。
    useEffect(() {
      final current = {for (final run in runs) run.runId: run};
      final settled = tracked.value.entries
          .where((entry) => !current.containsKey(entry.key))
          .map((entry) => entry.value)
          .toList();
      tracked.value = current;
      if (settled.isEmpty) {
        return null;
      }
      // effect 在 build 生命周期内同步执行，状态改动推迟到本帧结束后。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) {
          return;
        }
        final added = settled.map((run) => _receiptFor(ref, run)).toList();
        receipts.value = [...receipts.value, ...added];
        for (final receipt in added) {
          timers.value.add(
            Timer(_receiptRetention, () {
              if (!context.mounted) {
                return;
              }
              receipts.value = receipts.value
                  .where((item) => item.runId != receipt.runId)
                  .toList();
            }),
          );
        }
      });
      return null;
    }, [subAgents]);

    useEffect(() {
      return () {
        for (final timer in timers.value) {
          timer.cancel();
        }
        timers.value = <Timer>[];
      };
    }, const []);

    // 时长每秒一跳。只有那一小段文字订阅它，列表和消息区不跟着重建。
    final clock = useValueNotifier(DateTime.now());
    final hasRuns = runs.isNotEmpty;
    useEffect(() {
      if (!hasRuns) {
        return null;
      }
      final timer = Timer.periodic(const Duration(seconds: 1), (_) {
        clock.value = DateTime.now();
      });
      return timer.cancel;
    }, [hasRuns, clock]);

    if (runs.isEmpty && receipts.value.isEmpty) {
      return error.value == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.all(RevericSpacing.lg),
              child: Text(
                error.value!,
                style: typo.uiSmall.copyWith(color: colors.warningText),
              ),
            );
    }

    Future<void> stopAll() async {
      stoppingAll.value = true;
      error.value = null;
      try {
        await ref
            .read(aiChatRuntimeProvider(sessionId).notifier)
            .subAgents
            .stopBackground(source: AiChatCancelSource.stopButton.code);
      } catch (exception, stackTrace) {
        _log.error(
          'Stop all failed sessionId=$sessionId',
          error: exception,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          error.value = stopFailure;
        }
      } finally {
        if (context.mounted) {
          stoppingAll.value = false;
        }
      }
    }

    final rows = <Widget>[
      for (final run in runs)
        _RunRow(
          key: ValueKey(run.runId),
          run: run,
          sessionId: sessionId,
          novelId: novelId,
          databasePath: databasePath,
          clock: clock,
        ),
      for (final receipt in receipts.value)
        _ReceiptRow(
          key: ValueKey('receipt_${receipt.runId}'),
          receipt: receipt,
          novelId: novelId,
          databasePath: databasePath,
        ),
    ];
    // 一个任务也出汇总行：折叠入口不随任务数出现或消失，交互只有一种。
    final showRows = expanded.value;
    final rowHeight = backgroundStripControlSize(context);
    final horizontalMargin = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => RevericSpacing.lg,
      _ => RevericSpacing.x2l,
    };

    return RevericElevatedCard(
      fallback: colors.surface,
      margin: EdgeInsets.fromLTRB(
        horizontalMargin,
        0,
        horizontalMargin,
        RevericSpacing.sm,
      ),
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SummaryRow(
            liveCount: runs.length,
            expanded: expanded.value,
            names: [
              for (final run in runs) run.name,
              for (final receipt in receipts.value) receipt.name,
            ],
            stoppingAll: stoppingAll.value,
            onToggle: () => expanded.value = !expanded.value,
            onStopAll: stoppingAll.value ? null : stopAll,
          ),
          if (error.value != null)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.lg,
                vertical: RevericSpacing.xxs,
              ),
              child: Text(
                error.value!,
                style: typo.uiSmall.copyWith(color: colors.warningText),
              ),
            ),
          if (showRows)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: rowHeight * _maxVisibleRows,
              ),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: rows,
              ),
            ),
        ],
      ),
    );
  }

  _BackgroundReceipt _receiptFor(WidgetRef ref, SpawnAgentRunRecord run) {
    final result = _settledResult(ref, run);
    // 读不到结果时按最后已知状态兜底：停止中收尾的按已取消，其余按已完成。
    final cancelled = result == null
        ? run.status == SpawnAgentRunStatus.stopping
        : result['cancelled'] == true;
    return _BackgroundReceipt(
      runId: run.runId,
      block: _blockForRun(run),
      name: run.name,
      agentName: run.agentName,
      cancelled: cancelled,
      failed: !cancelled && result != null && result['ok'] != true,
    );
  }

  Map<String, dynamic>? _settledResult(WidgetRef ref, SpawnAgentRunRecord run) {
    final callId = run.callId;
    if (callId == null) {
      return null;
    }
    final block = ref
        .read(aiChatSessionProvider(sessionId).notifier)
        .findToolCallByCallId(callId)
        ?.$2;
    final display = block?.metadata?['background_run'];
    if (display is! Map || display['run_id'] != run.runId) {
      return null;
    }
    final result = display['result'];
    return result is Map ? Map<String, dynamic>.from(result) : null;
  }
}

/// 汇总行：数量、收起时的名字列表、全部停止和折叠开关。
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.liveCount,
    required this.expanded,
    required this.names,
    required this.stoppingAll,
    required this.onToggle,
    required this.onStopAll,
  });

  final int liveCount;
  final bool expanded;
  final List<String> names;
  final bool stoppingAll;
  final VoidCallback onToggle;
  final Future<void> Function()? onStopAll;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final title = liveCount == 0
        ? context.t(LocaleKeys.aiBackgroundAllSettled)
        : context
              .t(LocaleKeys.aiBackgroundAgents)
              .replaceAll('{count}', '$liveCount');
    final controlSize = backgroundStripControlSize(context);
    return Semantics(
      expanded: expanded,
      child: InkWell(
        key: const ValueKey('background_agents_toggle'),
        onTap: onToggle,
        child: ConstrainedBox(
          // 收起后这一行只剩文字，不撑最小高度会比展开时矮一截，条也跟着变形。
          constraints: BoxConstraints(minHeight: controlSize),
          child: Padding(
            padding: backgroundStripRowPadding(context),
            child: Row(
              children: [
                _LiveIndicator(live: liveCount > 0),
                const SizedBox(width: RevericSpacing.sm),
                // 标题和名字合占唯一一个 Expanded：行内只留一个弹性槽，剩余宽度
                // 才会全部落在这里，行尾控件贴住右边与任务行的停止键对齐。
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.ui.copyWith(color: colors.textSecondary),
                        ),
                      ),
                      if (!expanded) ...[
                        const SizedBox(width: RevericSpacing.sm),
                        Flexible(
                          child: Text(
                            '· ${names.join('、')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: typo.uiSmall.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // 停止不可逆，「全部停止」只在展开后、且真有多个在跑时出现。
                if (expanded && liveCount > 1)
                  Tooltip(
                    message: context.t(LocaleKeys.aiBackgroundStopAllHint),
                    child: RevericButton.text(
                      key: const ValueKey('background_agents_stop_all'),
                      label: context.t(LocaleKeys.aiBackgroundStopAll),
                      size: RevericButtonSize.compact,
                      onPressed: stoppingAll ? null : onStopAll,
                    ),
                  ),
                // 折叠箭头本身不是按钮（整行可点），但占满一个控件槽，
                // 才能和任务行最后那颗停止键对齐。
                SizedBox(
                  width: controlSize,
                  child: Center(
                    child: RevericIcon(
                      expanded
                          ? RevericIcons.expand_less_rounded
                          : RevericIcons.expand_more_rounded,
                      size: RevericSizes.iconButtonIconSize,
                      color: colors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 汇总行的状态指示。用静态字形而不是 CircularProgressIndicator：无限动画会让
/// 挂载这条 bar 的所有 pumpAndSettle 永不收敛，条内也不为每个任务配循环动画。
class _LiveIndicator extends StatelessWidget {
  const _LiveIndicator({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      width: RevericSizes.agentDotSize,
      height: RevericSizes.agentDotSize,
      decoration: BoxDecoration(
        color: live ? colors.accent.withValues(alpha: 0.14) : colors.additionBg,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: RevericIcon(
        live ? RevericIcons.circle_notch : RevericIcons.check,
        size: 11,
        color: live ? colors.accent : colors.additionBorder,
      ),
    );
  }
}

/// 在跑的任务：头像 + 名字 + agent + 时长 + 详情 + 停止，单行。
class _RunRow extends ConsumerWidget {
  const _RunRow({
    super.key,
    required this.run,
    required this.sessionId,
    required this.novelId,
    required this.databasePath,
    required this.clock,
  });

  final SpawnAgentRunRecord run;
  final String? sessionId;
  final String? novelId;
  final String? databasePath;
  final ValueNotifier<DateTime> clock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final stopping = run.status == SpawnAgentRunStatus.stopping;
    final block = _blockForRun(run);
    return Padding(
      padding: backgroundStripRowPadding(context),
      child: Row(
        children: [
          // 头像用静态字形，不为每个任务新增无限旋转动画。
          SpawnAgentAvatar(
            block: block,
            status: AiToolCallStatus.pending,
            novelId: novelId,
          ),
          const SizedBox(width: RevericSpacing.sm),
          // 名字和 agent 合占唯一一个 Expanded：行内只留一个弹性槽，剩余宽度才会
          // 全部落在这里 —— 两列各自可弹时，名字用不掉的份额会变成行尾死白，
          // 长短名的行停止键因此落在不同横坐标上。窄屏下两列一起让位，不撑爆行。
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: _nameMaxWidth),
                    child: Tooltip(
                      message: '${run.name} · ${run.agentName}',
                      child: Text(
                        run.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.ui.copyWith(color: colors.textPrimary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: RevericSpacing.sm),
                // 条上只交代「谁在跑」：实时动态在消息流的活动卡里已经完整呈现，
                // 这里重复一遍只会让每秒刷新的半句话抢走注意力。停止中是状态，留下。
                Flexible(
                  child: Text(
                    stopping
                        ? context.t(LocaleKeys.aiBackgroundStopping)
                        : run.agentName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiSmall.copyWith(
                      color: stopping ? colors.textSubtle : colors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          _ElapsedText(clock: clock, since: run.createdAt),
          SpawnAgentDetailButton(
            block: block,
            novelId: novelId,
            databasePath: databasePath,
            iconOnly: true,
          ),
          // 停止而非暂停：cancelRun 不可恢复，图标和文案都不该说「暂停」。
          // 实心方块（mockup 的 stopmark）：空心方框在这个尺寸下会被读成复选框。
          RevericIconButton(
            key: ValueKey('background_agent_stop_${run.runId}'),
            icon: RevericIcons.stop_fill,
            tooltip: stopping
                ? context.t(LocaleKeys.aiBackgroundStopping)
                : context.t(LocaleKeys.commonStop),
            onPressed: stopping
                ? null
                : () => ref
                      .read(aiChatRuntimeProvider(sessionId).notifier)
                      .subAgents
                      .cancelRun(run.runId),
          ),
        ],
      ),
    );
  }
}

/// 结束回执：不再有时长和停止入口，只留结果去向。
class _ReceiptRow extends StatelessWidget {
  const _ReceiptRow({
    super.key,
    required this.receipt,
    required this.novelId,
    required this.databasePath,
  });

  final _BackgroundReceipt receipt;
  final String? novelId;
  final String? databasePath;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final (label, color) = switch (receipt) {
      _BackgroundReceipt(cancelled: true) => (
        context.t(LocaleKeys.toolCancelled),
        colors.textMuted,
      ),
      _BackgroundReceipt(failed: true) => (
        context.t(LocaleKeys.aiBackgroundFailed),
        colors.warningText,
      ),
      _ => (context.t(LocaleKeys.aiBackgroundDone), colors.additionBorder),
    };
    return Padding(
      padding: backgroundStripRowPadding(context),
      child: Row(
        children: [
          SpawnAgentAvatar(
            block: receipt.block,
            status: receipt.failed
                ? AiToolCallStatus.error
                : AiToolCallStatus.success,
            novelId: novelId,
          ),
          const SizedBox(width: RevericSpacing.sm),
          // 与任务行同构：名字只封顶不弹性，右侧控件在两种行里落在同一竖线上。
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _nameMaxWidth),
            child: Tooltip(
              message: '${receipt.name} · ${receipt.agentName}',
              child: Text(
                receipt.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.ui.copyWith(color: colors.textPrimary),
              ),
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiSmall.copyWith(color: color),
            ),
          ),
          SpawnAgentDetailButton(
            block: receipt.block,
            novelId: novelId,
            databasePath: databasePath,
            iconOnly: true,
          ),
          // 停止键撤掉后留等宽空槽，详情键不横向跳位；移动端按 48 的点击区留。
          SizedBox(width: backgroundStripControlSize(context)),
        ],
      ),
    );
  }
}

/// 只有这一小段文字订阅秒级时钟。
class _ElapsedText extends StatelessWidget {
  const _ElapsedText({required this.clock, required this.since});

  final ValueNotifier<DateTime> clock;
  final DateTime since;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return ValueListenableBuilder<DateTime>(
      valueListenable: clock,
      builder: (context, now, _) => Text(
        _formatElapsed(now.difference(since)),
        style: typo.mono.copyWith(
          color: colors.textSubtle,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
