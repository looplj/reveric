// 职责: AI 聊天浮窗外壳 — 把同一个聊天面板浮在画布上，收起时缩成右下角 Agent 头像悬浮球并保持挂载。
// 关联文件:
//   lib/desktop/widgets/ai/chat/panel.dart
//   lib/desktop/features/production/region.dart
//   lib/shared/widgets/agent_avatar.dart
//   lib/shared/providers/todo_providers.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/zh-CN/tool.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
//   .agents/rules/i18n.md
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../shared/components/reveric_spinner.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/models/agent_profile.dart';
import '../../../../shared/models/todo.dart';
import '../../../../shared/providers/ai_providers.dart';
import '../../../../shared/providers/settings_providers.dart';
import '../../../../shared/providers/todo_providers.dart';
import '../../../../shared/providers/tool_permissions.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/widgets/agent_avatar.dart';
import '../../../../shared/widgets/app_background.dart';

/// 铺满画布区域的浮窗层：右侧浮动面板 + 右下角悬浮球；空白处不拦截画布手势。
class FloatingAiChat extends HookConsumerWidget {
  const FloatingAiChat({
    super.key,
    required this.open,
    required this.onOpenChanged,
    required this.sessionId,
    required this.panel,
  });

  final bool open;
  final ValueChanged<bool> onOpenChanged;

  /// 悬浮球据此显示执行中、任务进度和新回复。
  final String? sessionId;

  /// 收起时只隐藏不卸载，流式输出、滚动位置和输入草稿都保留。
  final Widget panel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final appBackgroundActive = ref.watch(appBackgroundActiveProvider);
    final busy = ref.watch(
      aiChatRuntimeProvider(sessionId).select((s) => s.isEditing),
    );
    final todos =
        ref.watch(sessionTodosProvider(sessionId)).value ?? const <Todo>[];
    final id = sessionId;
    final waiting = id == null
        ? 0
        : ref.watch(pendingToolApprovalsProvider(id)).value?.length ?? 0;

    // 收起期间跑完一轮才算有新回复；展开即视为已读。
    final wasBusy = useRef(busy);
    final unread = useRef(false);
    if (wasBusy.value && !busy && !open) {
      unread.value = true;
    }
    if (open) {
      unread.value = false;
    }
    wasBusy.value = busy;

    final shadow = _floatingShadow(colors);
    final progress = todos.isEmpty
        ? null
        : '${todos.where((t) => t.isCompleted).length} / ${todos.length}';

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(
          0.0,
          math.min(
            RevericSizes.chatPanelWidth,
            constraints.maxWidth - RevericSpacing.x2l * 2,
          ),
        );
        return Stack(
          children: [
            Positioned(
              top: RevericSpacing.x2l,
              right: RevericSpacing.x2l,
              bottom: RevericSpacing.x2l * 2 + RevericSizes.aiChatBallSize,
              width: width,
              child: Visibility(
                visible: open,
                maintainState: true,
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: appElevatedBackgroundColor(
                      colors,
                      appBackgroundActive,
                      colors.surfaceContainerHigh,
                    ),
                    borderRadius: BorderRadius.circular(RevericRadius.x2l),
                    boxShadow: shadow,
                  ),
                  // 面板自身铺底色，边框放前景层才不会被盖住。
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(RevericRadius.x2l),
                    border: Border.all(color: colors.border),
                  ),
                  child: panel,
                ),
              ),
            ),
            Positioned(
              right: RevericSpacing.x2l,
              bottom: RevericSpacing.x2l,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 有待确认的请求时胶囊换成「N 项待确认」，点开直接看到审批卡。
                  if (!open && (busy || waiting > 0)) ...[
                    _BusyPill(
                      progress: progress,
                      waiting: waiting,
                      onTap: () => onOpenChanged(true),
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                  ],
                  _AgentBall(
                    open: open,
                    busy: busy,
                    unread: (waiting > 0 || unread.value) && !open && !busy,
                    onTap: () => onOpenChanged(!open),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 与画布浮动控制簇同一档投影。
List<BoxShadow> _floatingShadow(RevericColors colors) => [
  BoxShadow(
    color: colors.textPrimary.withValues(alpha: 0.08),
    blurRadius: 12,
    offset: const Offset(0, 4),
  ),
];

class _AgentBall extends HookConsumerWidget {
  const _AgentBall({
    required this.open,
    required this.busy,
    required this.unread,
    required this.onTap,
  });

  final bool open;
  final bool busy;
  final bool unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final avatarPath = ref.watch(aiAgentAvatarPathProvider);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final hovered = useState(false);
    const size = RevericSizes.aiChatBallSize;

    return Tooltip(
      message: context.t(
        open ? LocaleKeys.aiChatFloatCollapse : LocaleKeys.aiChatFloatOpen,
      ),
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  if (open)
                    BoxShadow(
                      color: colors.accent.withValues(alpha: 0.28),
                      spreadRadius: 2,
                    ),
                  ..._floatingShadow(colors),
                ],
              ),
              child: AgentAvatar(
                avatarPath: avatarPath.isNotEmpty ? avatarPath : null,
                slug: builtinAgentSlugOrchestrator,
                size: size,
                backgroundColor: colors.surfaceContainer,
                border: Border.all(
                  color: open || hovered.value ? colors.accent : colors.border,
                ),
              ),
            ),
            if (busy)
              Positioned.fill(
                left: -4,
                top: -4,
                right: -4,
                bottom: -4,
                child: IgnorePointer(
                  child: RevericSpinner(
                    strokeWidth: 2,
                    value: reduceMotion ? 0.5 : null,
                    color: colors.accent,
                  ),
                ),
              ),
            if (unread)
              Positioned(
                top: 1,
                right: 1,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.accent,
                    border: Border.all(color: colors.surface, width: 2),
                  ),
                ),
              ),
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  onHover: (value) => hovered.value = value,
                  hoverColor: colors.textPrimary.withValues(alpha: 0.04),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 收起且助手在干活时，球左侧的「执行中 · 进度」胶囊，点了展开面板；
/// 有待确认的审批时改为「N 项待确认」。
class _BusyPill extends ConsumerWidget {
  const _BusyPill({
    required this.progress,
    required this.waiting,
    required this.onTap,
  });

  final String? progress;
  final int waiting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final appBackgroundActive = ref.watch(appBackgroundActiveProvider);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final shape = StadiumBorder(
      side: BorderSide(
        color: waiting > 0
            ? Color.lerp(colors.accentWarm, colors.border, 0.5)!
            : colors.border,
      ),
    );

    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: _floatingShadow(colors),
      ),
      child: Material(
        color: appElevatedBackgroundColor(
          colors,
          appBackgroundActive,
          colors.surface,
        ),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: colors.hover,
          child: Container(
            height: RevericSizes.buttonHeightSm,
            padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.lg),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (waiting > 0) ...[
                  RevericIcon(
                    RevericIcons.shield_check,
                    size: 13,
                    color: colors.accentWarm,
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  Text(
                    context.t(
                      LocaleKeys.aiOperationWaitingCount,
                      namedArgs: {'count': '$waiting'},
                    ),
                    style: typo.uiSmallSemibold.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ] else ...[
                  SizedBox.square(
                    dimension: 10,
                    child: RevericSpinner(
                      strokeWidth: 2,
                      value: reduceMotion ? 0.25 : null,
                      color: colors.accent,
                      backgroundColor: colors.accent.withValues(alpha: 0.25),
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  Text(
                    context.t(LocaleKeys.toolRunning),
                    style: typo.uiSmallSemibold.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
                if (waiting == 0 && progress != null) ...[
                  const SizedBox(width: RevericSpacing.xs),
                  Text(
                    progress!,
                    style: typo.uiSmall.copyWith(
                      color: colors.textMuted,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
