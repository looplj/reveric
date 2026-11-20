// 职责: 在聊天输入区上方列出本会话发起的工具运行，提供定位审批卡与取消入口。
// 关联文件:
//   lib/shared/services/ai/tool_operations.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/providers/tool_permissions.dart
//   lib/shared/widgets/ai/tool_approval_card.dart
//   lib/shared/widgets/ai/chat/background_agents.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/performance.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../agent/agent_tool_dispatcher.dart';
import '../../../components/reveric_icon_button.dart';
import '../../../components/reveric_surfaces.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../providers/ai_providers.dart';
import '../../../providers/tool_permissions.dart';
import '../../../services/ai/tool_operations.dart';
import '../../../theme/theme.dart';
import '../tool_approval_card.dart';
import 'background_agents.dart';

/// 结束的运行在条上停留的时长；结果本身留在消息流的回执里。
const _receiptRetention = Duration(seconds: 6);
const _maxVisibleRows = 4;
const _dotSize = 20.0;

class ToolOperationStrip extends HookConsumerWidget {
  const ToolOperationStrip({super.key, required this.sessionId});

  final String? sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = useState(true);
    final settled = useState<Set<String>>(const {});
    final seenLive = useRef(<String>{});
    final timers = useRef(<Timer>[]);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final id = sessionId;
    final runs = ref.watch(
      aiChatRuntimeProvider(id).select((value) => value.operations.runs),
    );
    // 审批 id → 审批卡挂靠的工具调用 id（与 ToolOperationActivity 的匹配口径一致）。
    final pending = id == null
        ? const <String, String>{}
        : {
            for (final request
                in ref.watch(pendingToolApprovalsProvider(id)).value ??
                    const [])
              request.approvalId: request.displayCallId ?? request.callId,
          };

    // 只为本次挂载期间见过的运行留回执：历史里恢复的终态运行不上条。
    useEffect(() {
      final live = {
        for (final run in runs)
          if (!run.terminal) run.runId,
      };
      final finished = seenLive.value.difference(live);
      seenLive.value = live;
      if (finished.isEmpty) {
        return null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) {
          return;
        }
        settled.value = {...settled.value, ...finished};
        timers.value.add(
          Timer(_receiptRetention, () {
            if (context.mounted) {
              settled.value = settled.value.difference(finished);
            }
          }),
        );
      });
      return null;
    }, [runs]);
    useEffect(
      () => () {
        for (final timer in timers.value) {
          timer.cancel();
        }
      },
      const [],
    );

    final shown = [
      for (final run in runs)
        if (!run.terminal || settled.value.contains(run.runId)) run,
    ];
    if (id == null || shown.isEmpty) {
      return const SizedBox.shrink();
    }
    final waiting = shown
        .where((run) => run.status == ToolOperationStatus.waiting_approval)
        .length;
    final live = shown.where((run) => !run.terminal).length;
    final multi = shown.length > 1;
    final controlSize = backgroundStripControlSize(context);
    final horizontalMargin = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => RevericSpacing.lg,
      _ => RevericSpacing.x2l,
    };

    void cancel(ToolOperationRecord run) {
      ref
          .read(aiChatRuntimeProvider(run.ownerSessionId).notifier)
          .operations
          .cancel(
            run.runId,
            ToolExecutionContext(
              sessionId: run.ownerSessionId,
              operationOwnerSessionId: run.ownerSessionId,
            ),
          );
    }

    final rows = [
      for (final run in shown)
        _RunRow(
          key: ValueKey(run.runId),
          run: run,
          onLocate: switch (pending[run.runId]) {
            final hostCallId? =>
              () => ref
                  .read(toolApprovalLocatorProvider)
                  .locate(run.runId, hostCallId: hostCallId),
            null => null,
          },
          onCancel: run.terminal || run.status == ToolOperationStatus.cancelling
              ? null
              : () => cancel(run),
        ),
    ];
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
          // 只有一条运行时不出汇总行。
          if (multi)
            Semantics(
              expanded: expanded.value,
              child: InkWell(
                onTap: () => expanded.value = !expanded.value,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: controlSize),
                  child: Padding(
                    padding: backgroundStripRowPadding(context),
                    child: Row(
                      children: [
                        _Dot(
                          icon: waiting > 0
                              ? RevericIcons.shield_check
                              : live > 0
                              ? RevericIcons.circle_notch
                              : RevericIcons.check,
                          color: waiting > 0
                              ? colors.accentWarm
                              : live > 0
                              ? colors.accent
                              : colors.textMuted,
                        ),
                        const SizedBox(width: RevericSpacing.sm),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              text: live > 0
                                  ? context.t(
                                      LocaleKeys.aiOperationStripTitle,
                                      namedArgs: {'count': '$live'},
                                    )
                                  : context.t(
                                      LocaleKeys.aiOperationStripSettled,
                                    ),
                              style: typo.ui.copyWith(
                                color: colors.textSecondary,
                              ),
                              children: [
                                if (waiting > 0)
                                  TextSpan(
                                    text:
                                        ' · ${context.t(LocaleKeys.aiOperationWaitingCount, namedArgs: {'count': '$waiting'})}',
                                    style: typo.uiSmall.copyWith(
                                      color: colors.textMuted,
                                    ),
                                  ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(
                          width: controlSize,
                          child: Center(
                            child: RevericIcon(
                              expanded.value
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
            ),
          if (!multi || expanded.value)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: controlSize * _maxVisibleRows,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({
    super.key,
    required this.run,
    required this.onLocate,
    required this.onCancel,
  });

  final ToolOperationRecord run;
  final VoidCallback? onLocate;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final view = describeToolOperation(context, (
      capability: run.capability,
      kind: run.kind,
      target: run.targetLabel ?? run.targetPath,
      status: run.status.name,
      result: run.result,
    ));
    final controlSize = backgroundStripControlSize(context);
    final waiting = run.status == ToolOperationStatus.waiting_approval;
    final label = view.target.isEmpty
        ? view.title
        : '${view.title} · ${view.target}';
    // 待确认的行整行可点，直接定位到消息流里的审批卡。
    return InkWell(
      onTap: onLocate,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: controlSize),
        child: Padding(
          padding: backgroundStripRowPadding(context),
          child: Row(
            children: [
              _Dot(icon: view.icon, color: view.color),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Tooltip(
                  message: label,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiSmall.copyWith(color: colors.textPrimary),
                  ),
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              Text(
                view.state,
                style: (waiting ? typo.uiSmallSemibold : typo.uiSmall).copyWith(
                  color: waiting ? colors.accentWarm : view.color,
                ),
              ),
              // 定位与取消各占一个固定槽，缺失时留空，不让右侧控件横跳。
              if (onLocate != null)
                RevericIconButton(
                  icon: RevericIcons.arrow_upward_rounded,
                  tooltip: context.t(LocaleKeys.commonView),
                  onPressed: onLocate,
                )
              else
                SizedBox(width: controlSize),
              if (onCancel != null)
                RevericIconButton(
                  icon: RevericIcons.stop_fill,
                  tooltip: context.t(LocaleKeys.commonCancel),
                  onPressed: onCancel,
                )
              else
                SizedBox(width: controlSize),
            ],
          ),
        ),
      ),
    );
  }
}

/// 状态字形；不用无限旋转动画，条上可能同时有多条运行。
class _Dot extends StatelessWidget {
  const _Dot({required this.icon, required this.color});

  final String icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _dotSize,
      height: _dotSize,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: RevericIcon(icon, size: 11, color: color),
    );
  }
}
