// 职责: AI 聊天面板会话切换器 — 包裹标题触发器，弹出下拉浮层切换或删除 chat 会话
// 关联文件:
//   lib/desktop/widgets/ai/chat/header.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/ai/session_persistence.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
//   .agents/rules/error-handling.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../shared/components/reveric_spinner.dart';
import '../../../../shared/database/app_database.dart' show AiChatSession;
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/logger/app_logger.dart';
import '../../../../shared/models/ai_session_mode.dart';
import '../../../../shared/providers/ai_mode_processing.dart';
import '../../../../shared/providers/novel_providers.dart';
import '../../../../shared/services/ai/session_persistence.dart'
    show pickPreferredAiChatSession;
import '../../../../shared/theme/theme.dart';
import 'session_context_menu.dart';

final _log = AppLogger.forModule('ChatSessionSwitcher');

/// 下拉浮层最多展示的最近会话数；更早的会话走侧边栏「聊天记录」分页加载。
const _sessionSwitcherLimit = 50;

/// 只读会话切换项（供画布画廊等不访问真实会话库的场景复用切换浮层）。
class ReadOnlyChatSessionItem {
  const ReadOnlyChatSessionItem({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.subtitle,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final String? subtitle;
}

/// 会话切换触发器 + 下拉浮层。
///
/// 包裹 header 的标题区（[child]），在标题旁渲染 caret；点击弹出最近
/// chat 会话列表，点行切换会话，点行内 close 图标删除会话（与侧边栏
/// 「聊天记录」行行为一致）。删除当前会话时回调后备会话 id（或 null）。
class ChatSessionSwitcher extends HookConsumerWidget {
  const ChatSessionSwitcher({
    super.key,
    required this.novelId,
    required this.databasePath,
    required this.activeSessionId,
    required this.onSelectSession,
    this.onContinueSession,
    required this.child,
  }) : readOnlySessions = null;

  /// 只读静态会话列表入口：不查询数据库，隐藏删除与右键菜单。
  const ChatSessionSwitcher.readOnly({
    super.key,
    required List<ReadOnlyChatSessionItem> sessions,
    required this.activeSessionId,
    required this.onSelectSession,
    required this.child,
  }) : novelId = '',
       databasePath = '',
       onContinueSession = null,
       readOnlySessions = sessions;

  final String novelId;
  final String databasePath;

  /// 只读模式下直接传入的静态会话列表；非空时不订阅数据库 provider。
  final List<ReadOnlyChatSessionItem>? readOnlySessions;

  /// 当前正在查看的会话 id，用于高亮与删除后的回退切换。
  final String? activeSessionId;

  /// 切换会话回调；删除当前会话后以后备会话 id（或 null）回调。
  final Future<void> Function(String?)? onSelectSession;
  final ValueChanged<String>? onContinueSession;

  /// 触发器内容（header 标题区）。
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final overlayController = useOverlayPortalController();
    final link = useMemoized(() => LayerLink(), []);
    final isOpen = useState(false);
    final staticSessions = readOnlySessions;
    final isReadOnly = staticSessions != null;
    final sessionsAsync = isReadOnly
        ? null
        : ref.watch(
            aiChatSessionsPageProvider(
              novelId: novelId,
              databasePath: databasePath,
              limit: _sessionSwitcherLimit,
            ),
          );
    final sessions =
        sessionsAsync?.asData?.value.sessions ?? const <AiChatSession>[];

    void closeMenu() {
      if (!isOpen.value) {
        return;
      }
      isOpen.value = false;
      overlayController.hide();
    }

    void toggleMenu() {
      if (isOpen.value) {
        closeMenu();
        return;
      }
      isOpen.value = true;
      overlayController.show();
    }

    Future<void> deleteSession(AiChatSession session) async {
      try {
        await ref
            .read(
              aiSessionPersistenceServiceProvider(
                novelId: novelId,
                databasePath: databasePath,
              ),
            )
            .deleteSession(session.id);
      } catch (error, stackTrace) {
        _log.error(
          '[DB] table=ai_chat_sessions operation=DELETE id=${session.id} '
          'error=$error',
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }
      if (session.id != activeSessionId) {
        return;
      }
      final fallback = pickPreferredAiChatSession(
        sessions.where((item) => item.id != session.id),
      );
      await onSelectSession?.call(fallback?.id);
    }

    return OverlayPortal(
      controller: overlayController,
      overlayChildBuilder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: closeMenu,
              ),
            ),
            CompositedTransformFollower(
              link: link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(0, RevericSpacing.xs),
              child: Align(
                alignment: Alignment.topLeft,
                child: isReadOnly
                    ? _ReadOnlySessionSwitcherMenu(
                        sessions: staticSessions,
                        activeSessionId: activeSessionId,
                        onSelect: (session) {
                          closeMenu();
                          if (session.id != activeSessionId) {
                            unawaited(onSelectSession?.call(session.id));
                          }
                        },
                      )
                    : _SessionSwitcherMenu(
                        sessions: sessions,
                        databasePath: databasePath,
                        onContinue: onContinueSession == null
                            ? null
                            : (session) {
                                closeMenu();
                                onContinueSession!(session.id);
                              },
                        isLoading: sessionsAsync!.isLoading,
                        activeSessionId: activeSessionId,
                        onSelect: (session) {
                          closeMenu();
                          if (session.id != activeSessionId) {
                            unawaited(onSelectSession?.call(session.id));
                          }
                        },
                        onDelete: (session) {
                          unawaited(deleteSession(session));
                        },
                      ),
              ),
            ),
          ],
        );
      },
      child: CompositedTransformTarget(
        link: link,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: toggleMenu,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(child: child),
                Padding(
                  padding: const EdgeInsets.only(left: RevericSpacing.xxs),
                  child: AnimatedRotation(
                    turns: isOpen.value ? 0.5 : 0,
                    duration: const Duration(milliseconds: 140),
                    child: RevericIcon(
                      RevericIcons.expand_more,
                      size: RevericSizes.chatSessionSwitcherCaretSize,
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

class _SessionSwitcherMenu extends StatelessWidget {
  const _SessionSwitcherMenu({
    required this.sessions,
    required this.isLoading,
    required this.activeSessionId,
    required this.onSelect,
    required this.onDelete,
    required this.databasePath,
    this.onContinue,
  });

  final List<AiChatSession> sessions;
  final bool isLoading;
  final String? activeSessionId;
  final ValueChanged<AiChatSession> onSelect;
  final ValueChanged<AiChatSession> onDelete;
  final String databasePath;
  final ValueChanged<AiChatSession>? onContinue;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    // 与侧边栏「聊天记录」一致，只展示 chat mode 会话。
    final chatSessions = sessions
        .where((session) => AiSessionMode.fromString(session.mode).isChat)
        .toList(growable: false);

    return Material(
      type: MaterialType.transparency,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        builder: (context, t, child) {
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 4),
              child: child,
            ),
          );
        },
        child: Container(
          width: 300,
          constraints: const BoxConstraints(maxHeight: 360),
          padding: const EdgeInsets.all(RevericSpacing.xs),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(RevericRadius.large),
            border: Border.all(color: colors.border),
            boxShadow: [
              BoxShadow(
                color: colors.textPrimary.withValues(alpha: 0.16),
                blurRadius: 40,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.sm,
                  RevericSpacing.xxs,
                  RevericSpacing.sm,
                  RevericSpacing.xs,
                ),
                child: Text(
                  context.t(LocaleKeys.aiChatHistory),
                  style: typo.uiTinySemibold.copyWith(
                    color: colors.textSubtle,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              if (isLoading && chatSessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(RevericSpacing.x2l),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (chatSessions.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(RevericSpacing.x2l),
                  child: Text(
                    context.t(LocaleKeys.aiSessionListEmpty),
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    itemCount: chatSessions.length,
                    itemBuilder: (context, index) {
                      final session = chatSessions[index];
                      return _SessionSwitcherRow(
                        key: ValueKey(session.id),
                        session: session,
                        isActive: session.id == activeSessionId,
                        onSelect: onSelect,
                        onDelete: onDelete,
                        databasePath: databasePath,
                        onContinue: onContinue,
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionSwitcherRow extends ConsumerWidget {
  const _SessionSwitcherRow({
    super.key,
    required this.session,
    required this.isActive,
    required this.onSelect,
    required this.onDelete,
    required this.databasePath,
    this.onContinue,
  });

  final AiChatSession session;
  final bool isActive;
  final ValueChanged<AiChatSession> onSelect;
  final ValueChanged<AiChatSession> onDelete;
  final String databasePath;
  final ValueChanged<AiChatSession>? onContinue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final isProcessing = ref.watch(
      aiSessionProcessingProvider(
        mode: AiSessionMode.chat,
        sessionId: session.id,
      ),
    );
    final title = session.title.trim().isEmpty
        ? context.t(LocaleKeys.aiSessionTitleDefault)
        : session.title;
    final processingLabel = isActive
        ? context.t(LocaleKeys.aiSessionProcessingCurrent)
        : context.t(LocaleKeys.aiSessionProcessingBackground);
    final subtitle = isProcessing
        ? processingLabel
        : _formatSessionTime(context, session.updatedAt);

    return GestureDetector(
      onSecondaryTapDown: (details) => unawaited(
        showChatSessionContextMenu(
          context: context,
          ref: ref,
          position: details.globalPosition,
          sessionId: session.id,
          databasePath: databasePath,
          onContinue: onContinue == null ? null : () => onContinue!(session),
          onDelete: () => onDelete(session),
        ),
      ),
      child: Material(
        color: isActive ? colors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: InkWell(
          onTap: () => onSelect(session),
          hoverColor: colors.hover,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.sm,
              vertical: RevericSpacing.sm,
            ),
            child: Row(
              children: [
                RevericIcon(
                  RevericIcons.chat_bubble_outline,
                  size: 14,
                  color: isActive ? colors.accent : colors.textSubtle,
                ),
                const SizedBox(width: RevericSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: (isActive ? typo.uiSmallSemibold : typo.uiSmall)
                            .copyWith(
                              color: isActive
                                  ? colors.textPrimary
                                  : colors.textSecondary,
                            ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      Text(
                        subtitle,
                        style: typo.uiTiny.copyWith(
                          color: isProcessing
                              ? (isActive ? colors.accent : colors.textMuted)
                              : colors.textSubtle,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ],
                  ),
                ),
                if (isProcessing) ...[
                  const SizedBox(width: RevericSpacing.sm),
                  SizedBox(
                    width: 8,
                    height: 8,
                    child: RevericSpinner(
                      strokeWidth: 1.5,
                      color: isActive ? colors.accent : colors.textMuted,
                    ),
                  ),
                ],
                if (isActive) ...[
                  const SizedBox(width: RevericSpacing.sm),
                  RevericIcon(
                    RevericIcons.check,
                    size: 14,
                    color: colors.accent,
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

class _ReadOnlySessionSwitcherMenu extends StatelessWidget {
  const _ReadOnlySessionSwitcherMenu({
    required this.sessions,
    required this.activeSessionId,
    required this.onSelect,
  });

  final List<ReadOnlyChatSessionItem> sessions;
  final String? activeSessionId;
  final ValueChanged<ReadOnlyChatSessionItem> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Material(
      type: MaterialType.transparency,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        builder: (context, t, child) {
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, (1 - t) * 4),
              child: child,
            ),
          );
        },
        child: Container(
          width: 300,
          constraints: const BoxConstraints(maxHeight: 360),
          padding: const EdgeInsets.all(RevericSpacing.xs),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(RevericRadius.large),
            border: Border.all(color: colors.border),
            boxShadow: [
              BoxShadow(
                color: colors.textPrimary.withValues(alpha: 0.16),
                blurRadius: 40,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.sm,
                  RevericSpacing.xxs,
                  RevericSpacing.sm,
                  RevericSpacing.xs,
                ),
                child: Text(
                  context.t(LocaleKeys.aiChatHistory),
                  style: typo.uiTinySemibold.copyWith(
                    color: colors.textSubtle,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              if (sessions.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(RevericSpacing.x2l),
                  child: Text(
                    context.t(LocaleKeys.aiSessionListEmpty),
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    itemCount: sessions.length,
                    itemBuilder: (context, index) {
                      final session = sessions[index];
                      final isActive = session.id == activeSessionId;
                      final title = session.title.trim().isEmpty
                          ? context.t(LocaleKeys.aiSessionTitleDefault)
                          : session.title;
                      final subtitle =
                          session.subtitle ??
                          _formatSessionTime(context, session.updatedAt);
                      return Material(
                        key: ValueKey(session.id),
                        color: isActive ? colors.selected : Colors.transparent,
                        borderRadius: BorderRadius.circular(
                          RevericRadius.medium,
                        ),
                        child: InkWell(
                          onTap: () => onSelect(session),
                          hoverColor: colors.hover,
                          borderRadius: BorderRadius.circular(
                            RevericRadius.medium,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: RevericSpacing.sm,
                              vertical: RevericSpacing.sm,
                            ),
                            child: Row(
                              children: [
                                RevericIcon(
                                  RevericIcons.chat_bubble_outline,
                                  size: 14,
                                  color: isActive
                                      ? colors.accent
                                      : colors.textSubtle,
                                ),
                                const SizedBox(width: RevericSpacing.sm),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        style:
                                            (isActive
                                                    ? typo.uiSmallSemibold
                                                    : typo.uiSmall)
                                                .copyWith(
                                                  color: isActive
                                                      ? colors.textPrimary
                                                      : colors.textSecondary,
                                                ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                      Text(
                                        subtitle,
                                        style: typo.uiTiny.copyWith(
                                          color: colors.textSubtle,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ],
                                  ),
                                ),
                                if (isActive) ...[
                                  const SizedBox(width: RevericSpacing.sm),
                                  RevericIcon(
                                    RevericIcons.check,
                                    size: 14,
                                    color: colors.accent,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatSessionTime(BuildContext context, DateTime when) {
  final now = DateTime.now();
  final date = DateTime(when.year, when.month, when.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(date).inDays;
  if (diff == 0) {
    final hh = when.hour.toString().padLeft(2, '0');
    final mm = when.minute.toString().padLeft(2, '0');
    return context.t(LocaleKeys.homeToday, namedArgs: {'time': '$hh:$mm'});
  }
  if (diff == 1) {
    return context.t(LocaleKeys.homeYesterday);
  }
  if (diff < 7) {
    return context.t(LocaleKeys.homeDaysAgo, namedArgs: {'count': '$diff'});
  }
  final mm = when.month.toString().padLeft(2, '0');
  final dd = when.day.toString().padLeft(2, '0');
  return '${when.year}-$mm-$dd';
}
