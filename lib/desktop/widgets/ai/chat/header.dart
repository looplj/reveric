// 职责: AI 聊天面板头部组件 — 显示会话标题、模型信息、会话切换入口、新建会话和关闭按钮，点击头像打开助手权限
// 关联文件:
//   lib/desktop/widgets/ai/chat/panel.dart
//   lib/desktop/widgets/ai/chat/state.dart
//   lib/desktop/widgets/ai/chat/session_switcher.dart
//   lib/shared/widgets/ai/ai_avatar.dart
//   lib/desktop/widgets/desktop_window_frame.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/models/ai_provider.dart';
import '../../../../shared/providers/ai_providers.dart'
    show AiChatRuntimeState, AiChatSessionState;
import '../../../../shared/providers/settings_providers.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/widgets/ai/ai_avatar.dart';
import '../../../../shared/widgets/app_background.dart';
import '../../desktop_window_frame.dart';
import 'session_switcher.dart';

class ChatHeader extends ConsumerWidget {
  const ChatHeader({
    super.key,
    required this.sessionState,
    required this.runtimeState,
    this.onRequestNewSession,
    this.onContinueSession,
    this.onClose,
    this.onExpand,
    this.onOpenPermissions,
    this.onSelectSession,
    this.novelId,
    this.databasePath,
    this.activeSessionId,
    this.avoidWindowCaption = true,
    this.floating = false,
    this.readOnly = false,
    this.readOnlySessions,
  });

  final AiChatSessionState sessionState;
  final AiChatRuntimeState runtimeState;
  final VoidCallback? onRequestNewSession;
  final ValueChanged<String>? onContinueSession;
  final VoidCallback? onClose;
  final VoidCallback? onExpand;

  /// 点击头像打开「助手权限」；审批关闭或无作品上下文时为空，头像不可点击。
  final VoidCallback? onOpenPermissions;

  /// 切换会话回调（来自面板的 onActiveSessionIdChanged）；为空则不显示
  /// 会话切换入口（用于没有会话列表的嵌入式聊天面板）。
  final Future<void> Function(String?)? onSelectSession;

  /// 会话列表查询上下文；任一为空则不显示会话切换入口。
  final String? novelId;
  final String? databasePath;

  /// 当前正在查看的会话 id，用于切换浮层的高亮与删除回退。
  final String? activeSessionId;

  /// When true, this header is the rightmost chrome under Windows caption
  /// buttons: push content below [DesktopWindowFrame.captionSafeTopInset]
  /// so system buttons and panel actions stay on separate rows.
  /// When false, a sibling (side panel) owns that space.
  final bool avoidWindowCaption;

  /// 浮窗外壳：关闭按钮语义变成「收起为悬浮球」，面板仍保持挂载。
  final bool floating;

  /// 只读模式（画布画廊）：隐藏新建/展开/权限入口，直接展示会话模型名并使用静态会话切换。
  final bool readOnly;

  /// 只读模式下的静态会话列表；数量大于 1 时在标题旁展示切换下拉。
  final List<ReadOnlyChatSessionItem>? readOnlySessions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final appBackgroundActive = ref.watch(appBackgroundActiveProvider);
    String? providerName;
    String? modelName = sessionState.model;
    if (!readOnly) {
      final aiSettings = ref.watch(aiSettingsProvider);
      providerName = sessionState.providerId != null
          ? aiSettings.findConfigById(sessionState.providerId!)?.displayName
          : null;
      // 会话存的是 model id：优先解析为模型目录的展示名（Reveric 渠道），
      // 解析不到（provider 未配置或模型已下线）时回退原始 id。
      final availableModels = ref.watch(availableAiModelsProvider);
      final sessionProviderId = sessionState.providerId;
      final sessionModel = sessionState.model;
      if (sessionProviderId != null && sessionModel != null) {
        final optionId = '$sessionProviderId::$sessionModel';
        for (final option in availableModels) {
          if (option.id == optionId) {
            modelName = option.displayModelName;
            break;
          }
        }
      }
    }

    // Windows: stack under caption (top inset). Elsewhere / immersive: same
    // title-bar row; only the rightmost header needs trailingInset.
    final topInset = avoidWindowCaption
        ? DesktopWindowFrame.captionSafeTopInset
        : 0.0;
    final trailingInset = avoidWindowCaption && topInset == 0
        ? DesktopWindowFrame.trailingInset
        : 0.0;

    // Same chrome as AiChatPanel so the Windows caption strip and the
    // session title row read as one continuous band.
    final headerChrome = appChromeBackgroundColor(
      colors,
      appBackgroundActive,
      colors.surfaceContainerHigh,
    );

    // 标题为空时，把 agent / 模型信息提升为主标题，不再显示副标题。
    final rawTitle = sessionState.title.trim();
    final metaSubtitle = _subtitleText(providerName, modelName);
    final String titleText;
    final String? subtitleText;
    if (rawTitle.isNotEmpty) {
      titleText = rawTitle;
      subtitleText = metaSubtitle;
    } else {
      titleText = metaSubtitle ?? '';
      subtitleText = null;
    }
    final hasSubtitle = subtitleText != null;

    final title = ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        colors: [colors.textPrimary, colors.accentWarm],
      ).createShader(bounds),
      child: Text(
        titleText,
        style: typo.uiSemibold.copyWith(color: Colors.white),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
    );

    final titleColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        title,
        if (hasSubtitle) ...[
          const SizedBox(height: 2),
          Text(
            subtitleText,
            style: typo.uiSmall.copyWith(color: colors.textMuted),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ],
      ],
    );
    // 有会话列表上下文时，标题区变为会话切换触发器（caret + 下拉浮层）。
    final canSwitchReadOnlySessions =
        readOnly &&
        onSelectSession != null &&
        readOnlySessions != null &&
        readOnlySessions!.length > 1;
    final canSwitchSessions =
        !readOnly &&
        onSelectSession != null &&
        novelId != null &&
        novelId!.isNotEmpty &&
        databasePath != null &&
        databasePath!.isNotEmpty;

    return ColoredBox(
      color: headerChrome,
      child: SizedBox(
        height: DesktopWindowFrame.titleBarHeight + topInset,
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: SizedBox(
            height: DesktopWindowFrame.titleBarHeight,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                RevericSpacing.x2l,
                0,
                RevericSpacing.lg + trailingInset,
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  AiAvatar(
                    size: RevericSizes.aiAvatarSm,
                    tooltip: readOnly
                        ? null
                        : context.t(LocaleKeys.aiPermissionsTitle),
                    onTap: readOnly ? null : onOpenPermissions,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: canSwitchReadOnlySessions
                        ? ChatSessionSwitcher.readOnly(
                            sessions: readOnlySessions!,
                            activeSessionId: activeSessionId,
                            onSelectSession: onSelectSession,
                            child: titleColumn,
                          )
                        : canSwitchSessions
                        ? ChatSessionSwitcher(
                            novelId: novelId!,
                            databasePath: databasePath!,
                            activeSessionId: activeSessionId,
                            onSelectSession: onSelectSession,
                            onContinueSession: onContinueSession,
                            child: titleColumn,
                          )
                        : titleColumn,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  _HeaderActions(
                    colors: colors,
                    // 直接新建，不再先弹「新对话 / 延续」二选一：延续降级成新
                    // 会话里的一次性提议条（ContinueSessionOfferBar）。
                    onRequestNewSession: readOnly ? null : onRequestNewSession,
                    onExpand: readOnly ? null : onExpand,
                    onClose: onClose,
                    isRequestInFlight:
                        !readOnly &&
                        (runtimeState.isRequestInFlight ||
                            runtimeState.isSessionMutationInFlight),
                    newTooltip: runtimeState.isRequestInFlight
                        ? context.t(LocaleKeys.aiCancelFirst)
                        : context.t(LocaleKeys.aiChatNewConversation),
                    expandTooltip: context.t(LocaleKeys.aiChatExpand),
                    closeTooltip: context.t(
                      floating
                          ? LocaleKeys.aiChatFloatCollapse
                          : LocaleKeys.commonClose,
                    ),
                    closeIcon: RevericIcons.remove,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? _subtitleText(String? providerName, String? modelName) {
    final cleanProvider = providerName?.trim();
    final cleanModel = modelName?.trim();
    if (cleanProvider != null &&
        cleanProvider.isNotEmpty &&
        cleanModel != null &&
        cleanModel.isNotEmpty) {
      return '$cleanProvider · $cleanModel';
    }
    if (cleanModel != null && cleanModel.isNotEmpty) {
      return cleanModel;
    }
    return null;
  }
}

class _HeaderActions extends StatelessWidget {
  const _HeaderActions({
    required this.colors,
    required this.onExpand,
    required this.onRequestNewSession,
    required this.onClose,
    required this.isRequestInFlight,
    required this.newTooltip,
    required this.expandTooltip,
    required this.closeTooltip,
    required this.closeIcon,
  });

  final RevericColors colors;
  final VoidCallback? onExpand;
  final VoidCallback? onRequestNewSession;
  final VoidCallback? onClose;
  final bool isRequestInFlight;
  final String newTooltip;
  final String expandTooltip;
  final String closeTooltip;
  final String closeIcon;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (onExpand != null) {
      children.add(
        _HeaderIconButton(
          tooltip: expandTooltip,
          icon: RevericIcons.open_in_full_rounded,
          iconSize: 18,
          color: colors.textSecondary,
          onPressed: onExpand,
        ),
      );
    }
    if (onRequestNewSession != null) {
      children.add(
        _HeaderIconButton(
          tooltip: newTooltip,
          icon: RevericIcons.add,
          color: isRequestInFlight ? colors.textSubtle : colors.textMuted,
          onPressed: isRequestInFlight ? null : onRequestNewSession,
        ),
      );
    }
    if (onClose != null) {
      children.add(
        _HeaderIconButton(
          tooltip: closeTooltip,
          icon: closeIcon,
          color: colors.textMuted,
          onPressed: onClose,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: RevericSpacing.xxs),
          children[i],
        ],
      ],
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.iconSize = 16,
  });

  final String tooltip;
  final String icon;
  final Color color;
  final VoidCallback? onPressed;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: RevericSizes.iconButtonSize,
      height: RevericSizes.iconButtonSize,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        iconSize: iconSize,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(
          width: RevericSizes.iconButtonSize,
          height: RevericSizes.iconButtonSize,
        ),
        visualDensity: VisualDensity.compact,
        icon: RevericIcon(icon, size: iconSize, color: color),
      ),
    );
  }
}
