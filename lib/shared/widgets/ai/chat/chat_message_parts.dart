// 职责: 展示聊天消息的思考卡、可折叠文本、复制操作和会话引用。
// 关联文件:
//   lib/shared/widgets/ai/chat/chat_message_view.dart
//   lib/shared/models/user_message_presentation.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/markdown_text.dart';

import '../../../models/user_message_presentation.dart';

export '../../../models/user_message_presentation.dart';

/// 写入剪贴板并提示「已复制」。供样式不同的复制入口复用同一套反馈。
void copyTextWithToast(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(context.t(LocaleKeys.aiCopied)),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// 复制按钮：点击写入剪贴板并提示。
class CopyIconButton extends StatelessWidget {
  const CopyIconButton({super.key, required this.text, this.tooltip});

  final String text;

  /// 自定义悬浮提示；缺省用通用的「复制」。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Tooltip(
      message: tooltip ?? context.t(LocaleKeys.aiCopy),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          onTap: () => copyTextWithToast(context, text),
          child: Padding(
            padding: const EdgeInsets.all(RevericSpacing.xs),
            child: RevericIcon(
              RevericIcons.copy_outlined,
              size: 14,
              color: colors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// 消息操作栏：复制文本，并在宿主注入时打开反馈上传 / 分叉会话。
class MessageActionBar extends StatelessWidget {
  const MessageActionBar({
    super.key,
    this.copyText,
    this.onFeedback,
    this.onFork,
    this.alignment = Alignment.centerLeft,
  });

  final String? copyText;
  final VoidCallback? onFeedback;

  /// 分叉会话：从此消息切出一条新 chat session（含截止到本条的消息）。
  final VoidCallback? onFork;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final showCopy = copyText != null && copyText!.isNotEmpty;
    if (!showCopy && onFeedback == null && onFork == null) {
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: alignment == Alignment.centerRight
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        if (showCopy) CopyIconButton(text: copyText!),
        if (showCopy && (onFeedback != null || onFork != null))
          const SizedBox(width: RevericSpacing.xxs),
        if (onFeedback != null)
          Tooltip(
            message: context.t(LocaleKeys.aiFeedbackTitle),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(RevericRadius.medium),
                onTap: onFeedback,
                child: Padding(
                  padding: const EdgeInsets.all(RevericSpacing.xs),
                  child: RevericIcon(
                    RevericIcons.bug_beetle_outlined,
                    size: 14,
                    color: colors.textMuted,
                  ),
                ),
              ),
            ),
          ),
        if (onFeedback != null && onFork != null)
          const SizedBox(width: RevericSpacing.xxs),
        if (onFork != null)
          Tooltip(
            message: context.t(LocaleKeys.aiForkTooltip),
            waitDuration: const Duration(milliseconds: 400),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(RevericRadius.medium),
                onTap: onFork,
                child: Padding(
                  padding: const EdgeInsets.all(RevericSpacing.xs),
                  child: RevericIcon(
                    RevericIcons.git_fork,
                    size: 14,
                    color: colors.textMuted,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 简单 hover 状态容器：把当前 hover 状态交给 [builder]（桌面端用于 hover 显隐操作）。
class HoverRegion extends StatefulWidget {
  const HoverRegion({super.key, required this.builder});

  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<HoverRegion> createState() => _HoverRegionState();
}

class _HoverRegionState extends State<HoverRegion> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(context, _hovered),
    );
  }
}

/// 用户消息气泡左侧操作簇：回退常驻显示，复制按钮随 [showCopy]（hover）显隐。
/// 对齐 designs/desktop/ChatPanel.jsx 的 `m-bubble__uactions`（气泡左、垂直居中）。
class UserBubbleActions extends StatelessWidget {
  const UserBubbleActions({
    super.key,
    required this.copyText,
    required this.showCopy,
    this.onRollbackTurn,
  });

  final String copyText;
  final bool showCopy;
  final VoidCallback? onRollbackTurn;

  @override
  Widget build(BuildContext context) {
    final hasCopy = copyText.isNotEmpty;
    final children = <Widget>[];
    if (hasCopy) {
      // 复制：hover 时淡入；非 hover 时占位透明且不可点，避免布局跳动。
      children.add(
        AnimatedOpacity(
          opacity: showCopy ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: IgnorePointer(
            ignoring: !showCopy,
            child: CopyIconButton(text: copyText),
          ),
        ),
      );
    }
    if (onRollbackTurn != null) {
      if (hasCopy) {
        children.add(const SizedBox(width: RevericSpacing.xxs));
      }
      children.add(
        _GhostIconButton(
          icon: RevericIcons.arrow_counter_clockwise,
          tooltip: context.t(LocaleKeys.aiRollbackTurnTooltip),
          onTap: onRollbackTurn!,
        ),
      );
    }
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// 通用 ghost 图标按钮（无背景、muted 色），用于消息操作。
class _GhostIconButton extends StatelessWidget {
  const _GhostIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final String icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(RevericSpacing.xs),
            child: RevericIcon(icon, size: 14, color: colors.textMuted),
          ),
        ),
      ),
    );
  }
}

/// 包裹子组件：hover 时显示复制；反馈/分叉等与 blocks 底部操作栏一样常驻。
class HoverableCopyWrapper extends StatefulWidget {
  const HoverableCopyWrapper({
    super.key,
    required this.text,
    required this.child,
    this.alignment = Alignment.centerRight,
    this.rightPadding = RevericSpacing.x2l,
    this.showCopy = true,
    this.onFeedback,
    this.onFork,
  });

  final String text;
  final Widget child;
  final Alignment alignment;
  final double rightPadding;

  /// 为 false 时仅展示反馈/分叉等操作，不显示整轮复制按钮。
  final bool showCopy;
  final VoidCallback? onFeedback;
  final VoidCallback? onFork;

  @override
  State<HoverableCopyWrapper> createState() => _HoverableCopyWrapperState();
}

class _HoverableCopyWrapperState extends State<HoverableCopyWrapper> {
  bool _hovered = false;

  bool get _hasPersistentActions =>
      widget.onFeedback != null || widget.onFork != null;

  @override
  Widget build(BuildContext context) {
    // 复制：桌面 hover 显示（与 CollapsibleTextBlock 单段复制一致）。
    // 反馈/分叉：与 blocks 消息底部 MessageActionBar 一样常驻，不依赖 hover。
    final showCopy = widget.showCopy && _hovered;
    final showBar = showCopy || _hasPersistentActions;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: RevericSpacing.x2l,
          right: widget.rightPadding,
        ),
        child: Column(
          crossAxisAlignment: widget.alignment == Alignment.centerRight
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            widget.child,
            AnimatedOpacity(
              opacity: showBar ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: IgnorePointer(
                ignoring: !showBar,
                child: Padding(
                  padding: const EdgeInsets.only(top: RevericSpacing.xs),
                  child: MessageActionBar(
                    copyText: showCopy ? widget.text : null,
                    onFeedback: widget.onFeedback,
                    onFork: widget.onFork,
                    alignment: widget.alignment,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 可折叠的文本块（超过阈值或多行时折叠）。
/// 复制按钮由调用方在块外侧按 hover 渲染（见 `_buildTextBubble`）。
class CollapsibleTextBlock extends StatefulWidget {
  const CollapsibleTextBlock({
    super.key,
    required this.content,
    required this.textStyle,
    this.selectable = true,
    this.loadInlineImages = true,
  });

  final String content;
  final TextStyle textStyle;

  /// false 时内容不可选中（内容仍在流式增长的阶段）。
  final bool selectable;
  final bool loadInlineImages;

  @override
  State<CollapsibleTextBlock> createState() => _CollapsibleTextBlockState();
}

class _CollapsibleTextBlockState extends State<CollapsibleTextBlock> {
  static const int _collapseThreshold = 220;

  late bool _expanded = !_isCollapsible;

  bool get _isCollapsible {
    final content = widget.content.trim();
    return content.length > _collapseThreshold || content.contains('\n');
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final content = widget.content.trim();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.lg,
              RevericSpacing.lg,
              RevericSpacing.lg,
              RevericSpacing.md,
            ),
            child: AiMarkdownText(
              content,
              selectable: widget.selectable,
              loadInlineImages: widget.loadInlineImages,
              style: typo.ui
                  .merge(widget.textStyle)
                  .copyWith(color: colors.textPrimary, height: 1.6),
              maxLines: _isCollapsible && !_expanded ? 5 : null,
              overflow: _isCollapsible && !_expanded
                  ? TextOverflow.ellipsis
                  : null,
            ),
          ),
          if (_isCollapsible)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.md,
                0,
                RevericSpacing.md,
                RevericSpacing.sm,
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: InkWell(
                  borderRadius: BorderRadius.circular(RevericRadius.medium),
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: RevericSpacing.xs,
                      vertical: RevericSpacing.xxs,
                    ),
                    child: RevericIcon(
                      _expanded
                          ? RevericIcons.expand_less_rounded
                          : RevericIcons.expand_more_rounded,
                      size: 18,
                      color: colors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 接力（handoff）chip：可点击回到来源会话。
class AgentHandoffChip extends StatelessWidget {
  const AgentHandoffChip({
    super.key,
    required this.handoff,
    this.onOpenSession,
  });

  final AgentHandoffReference handoff;
  final Future<void> Function(String sessionId, AiSessionMode mode)?
  onOpenSession;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final sourceSessionId = handoff.sourceSessionId?.trim();
    final sourceTitle = handoff.sourceTitle?.trim();
    final canOpen =
        sourceSessionId != null &&
        sourceSessionId.isNotEmpty &&
        onOpenSession != null;
    final routeLabel = handoff.fromAgent.isEmpty && handoff.toAgent.isEmpty
        ? sourceSessionId ?? 'Session handoff'
        : '${handoff.fromAgent} → ${handoff.toAgent}';
    final label = sourceTitle == null || sourceTitle.isEmpty
        ? routeLabel
        : sourceTitle;
    final chip = Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: RevericSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.accentWarm.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(RevericRadius.pill),
        border: Border.all(color: colors.accentWarm.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(
            RevericIcons.swap_horiz_rounded,
            size: 14,
            color: colors.accentWarm,
          ),
          const SizedBox(width: RevericSpacing.xs),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiSmall.copyWith(color: colors.accentWarm),
            ),
          ),
        ],
      ),
    );
    if (!canOpen) {
      return chip;
    }
    return Tooltip(
      message: sourceTitle == null || sourceTitle.isEmpty
          ? sourceSessionId
          : sourceTitle,
      child: InkWell(
        borderRadius: BorderRadius.circular(RevericRadius.pill),
        onTap: () => onOpenSession!(sourceSessionId, handoff.fromMode),
        child: chip,
      ),
    );
  }
}

/// composer 上的「延续自某会话」草稿标记，两端 composer 共用。
///
/// 视觉与 handoff 草稿 chip 同为暖色药丸，只用图标区分来源类型。
class SessionContinuationDraftChip extends StatelessWidget {
  const SessionContinuationDraftChip({
    super.key,
    required this.title,
    required this.onRemove,
    this.onOpen,
  });

  final String title;
  final VoidCallback onRemove;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final label = context.t(
      LocaleKeys.aiChatContinuedFrom,
      namedArgs: {'title': title},
    );

    return Tooltip(
      message: label,
      child: Container(
        padding: const EdgeInsets.only(
          left: RevericSpacing.sm,
          right: RevericSpacing.xxs,
          top: RevericSpacing.xxs,
          bottom: RevericSpacing.xxs,
        ),
        decoration: BoxDecoration(
          color: colors.accentWarm.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          border: Border.all(color: colors.accentWarm.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(RevericRadius.pill),
              onTap: onOpen,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RevericIcon(
                    RevericIcons.git_fork,
                    size: 13,
                    color: colors.accentWarm,
                  ),
                  const SizedBox(width: RevericSpacing.xxs),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmall.copyWith(color: colors.accentWarm),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 2),
            InkWell(
              borderRadius: BorderRadius.circular(RevericRadius.pill),
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: RevericIcon(
                  RevericIcons.close,
                  size: 12,
                  color: colors.accentWarm,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 用户消息里的引用 chip（`<user-remind>`）。session 类型可点击回到会话。
class UserRemindChip extends StatelessWidget {
  const UserRemindChip({
    super.key,
    required this.reference,
    this.onOpenSession,
  });

  final UserRemindReference reference;
  final Future<void> Function(String sessionId, AiSessionMode mode)?
  onOpenSession;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final label = reference.label.trim().isEmpty
        ? reference.path
        : reference.label;
    final type = reference.type.trim();
    const sessionPrefix = 'ai-session:';
    final sessionId =
        type == 'session' && reference.path.startsWith(sessionPrefix)
        ? reference.path.substring(sessionPrefix.length).trim()
        : null;
    final canOpenSession =
        sessionId != null && sessionId.isNotEmpty && onOpenSession != null;
    final displayType = switch (type) {
      'file' => context.t(LocaleKeys.aiContextFile),
      'selection' => context.t(LocaleKeys.aiContextSelection),
      _ => type,
    };
    final icon = switch (type) {
      'agent_rule' => RevericIcons.rule_outlined,
      'file' => RevericIcons.description_outlined,
      'selection' => RevericIcons.format_quote,
      _ => RevericIcons.link,
    };
    final chip = Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: RevericSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.pill),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(
            icon,
            size: RevericSizes.iconButtonPadding * 2,
            color: colors.textMuted,
          ),
          const SizedBox(width: RevericSpacing.xs),
          Flexible(
            child: Text(
              type == 'session' && reference.workId != null
                  ? context.t(
                      LocaleKeys.aiChatContinuedFrom,
                      namedArgs: {'title': label},
                    )
                  : displayType.isEmpty
                  ? label
                  : '$displayType · $label',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiSmall.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
    return Tooltip(
      message: reference.path.trim().isEmpty
          ? label
          : '$label\n${reference.path}',
      child: canOpenSession
          ? InkWell(
              borderRadius: BorderRadius.circular(RevericRadius.pill),
              onTap: () => onOpenSession!(
                sessionId,
                reference.mode ?? AiSessionMode.chat,
              ),
              child: chip,
            )
          : chip,
    );
  }
}

/// 用户消息里的「本轮使用的技能」chip（来自消息 metadata，非 `<user-remind>` 标签）。
///
/// 样式与 [UserRemindChip] 对齐，图标沿用输入框 skill chip 的 lightning。
class SkillUsedChip extends StatelessWidget {
  const SkillUsedChip({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) =>
      _SlashUsedChip(name: name, icon: RevericIcons.lightning);
}

/// 用户消息里的「本轮点名的 subagent」chip（来自消息 metadata）。
///
/// 图标沿用输入框 subagent chip 的 smart_toy_outlined。
class SubagentUsedChip extends StatelessWidget {
  const SubagentUsedChip({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) =>
      _SlashUsedChip(name: name, icon: RevericIcons.smart_toy_outlined);
}

/// slash chip（skill / subagent）的共同样式：pill + 图标 + 名称，与 [UserRemindChip] 对齐。
class _SlashUsedChip extends StatelessWidget {
  const _SlashUsedChip({required this.name, required this.icon});

  final String name;
  final String icon;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Tooltip(
      message: name,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.sm,
          vertical: RevericSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              icon,
              size: RevericSizes.iconButtonPadding * 2,
              color: colors.textMuted,
            ),
            const SizedBox(width: RevericSpacing.xs),
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSmall.copyWith(color: colors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
