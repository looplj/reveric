// 职责: 移动端 AI Tab — 对话入口、AI 模式、模型与智能体管理、最近对话。
// 关联文件:
//   lib/mobile/widgets/assistant_hub.dart
//   lib/mobile/widgets/delete_confirm.dart
//   lib/mobile/widgets/detail_scaffold.dart
//   lib/mobile/pages/agent_model_settings_page.dart
//   lib/mobile/pages/settings_page.dart
//   lib/mobile/pages/subagent_manage_page.dart
//   lib/mobile/features/agent_skills/global_skill_setup_page.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/mobile/features/council/page.dart
//   lib/mobile/pages/chat_session_page.dart
//   lib/mobile/providers/chat_providers.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/subagent_providers.dart
//   lib/shared/providers/agent_skill_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/subagent.json
//   assets/translations/zh-CN/subagent.json
//   assets/translations/en/agent_studio.json
//   assets/translations/zh-CN/agent_studio.json
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/database/app_database.dart' show AiChatSession, Novel;
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/ai_session_mode.dart';
import '../../shared/models/novel_agent_skill.dart';
import '../../shared/models/subagent.dart';
import '../../shared/providers/novel_agent_skill_providers.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/providers/subagent_providers.dart';
import '../../shared/theme/theme.dart';
import '../providers/chat_providers.dart';
import '../widgets/assistant_hub.dart';
import '../widgets/delete_confirm.dart';
import '../widgets/detail_scaffold.dart';
import '../widgets/section_scaffold.dart';
import '../features/agent_skills/global_skill_setup_page.dart';
import 'chat_session_page.dart';
import '../features/council/page.dart';
import '../features/monologue/page.dart';
import 'novel_chat_page.dart';
import 'agent_model_settings_page.dart';
import 'settings_page.dart';
import 'subagent_manage_page.dart';

class MobileChatPage extends ConsumerWidget {
  const MobileChatPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final novels = assistantActiveNovels(ref);
    final primaryNovel = novels.isEmpty ? null : novels.first;

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _HubHeader(onNewChat: () => startAssistantChat(context, ref)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.x4l,
                  RevericSpacing.xs,
                  RevericSpacing.x4l,
                  RevericSpacing.x4l,
                ),
                children: [
                  AssistantPrimaryEntryCard(
                    novelTitle: primaryNovel?.title,
                    onTap: () => startAssistantChat(
                      context,
                      ref,
                      preferred: primaryNovel,
                    ),
                  ),
                  const SizedBox(height: RevericSpacing.x2l),
                  MobileDetailSectionLabel(
                    text: context.t(LocaleKeys.mobileAssistantModesSection),
                  ),
                  const AssistantModeGrid(),
                  const SizedBox(height: RevericSpacing.x2l),
                  MobileDetailSectionLabel(
                    text: context.t(LocaleKeys.homeSectionModel),
                  ),
                  MobileDetailFieldList(
                    children: [
                      MobileDetailNavRow(
                        icon: RevericIcons.hub_outlined,
                        label: context.t(LocaleKeys.providerTitle),
                        onTap: () =>
                            showMobileSettingsPage(context, 'providers'),
                      ),
                      MobileDetailNavRow(
                        key: const ValueKey('mobile_model_settings_entry'),
                        icon: RevericIcons.tune,
                        label: context.t(LocaleKeys.agentStudioModelSettings),
                        onTap: () => openMobileAgentModelSettingsPage(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: RevericSpacing.x2l),
                  MobileDetailSectionLabel(
                    text: context.t(LocaleKeys.homeSectionAgent),
                  ),
                  const _AgentManagementList(),
                  const SizedBox(height: RevericSpacing.x2l),
                  MobileDetailSectionLabel(
                    text: context.t(LocaleKeys.mobileAssistantRecentSection),
                  ),
                  const _RecentSessions(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hub 大标题头部：标题「助手」+ 新建对话。
class _HubHeader extends StatelessWidget {
  const _HubHeader({required this.onNewChat});

  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x4l,
        RevericSpacing.md,
        RevericSpacing.lg,
        RevericSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              context.t(LocaleKeys.mobileTabAssistant),
              style: typo.display.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            onPressed: onNewChat,
            icon: RevericIcon(
              RevericIcons.add,
              size: 22,
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentManagementList extends ConsumerWidget {
  const _AgentManagementList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subagents =
        (ref.watch(globalSubAgentsProvider).asData?.value ?? const <SubAgent>[])
            .where(isUserVisibleSubAgent)
            .length;
    final skills =
        (ref.watch(installedAgentSkillsProvider).asData?.value ??
                const <NovelAgentSkillModel>[])
            .length;

    String count(int n) =>
        context.t(LocaleKeys.mobileAssistantCount, namedArgs: {'count': '$n'});

    void push(Widget page) {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    }

    return MobileDetailFieldList(
      children: [
        MobileDetailNavRow(
          icon: RevericIcons.smart_toy_outlined,
          label: context.t(LocaleKeys.settingsAiAgents),
          onTap: () => showMobileSettingsPage(context, 'ai_agents'),
        ),
        MobileDetailNavRow(
          icon: RevericIcons.auto_awesome_outlined,
          label: context.t(LocaleKeys.agentSkillTitle),
          value: count(skills),
          onTap: () => push(const GlobalSkillSetupPage()),
        ),
        MobileDetailNavRow(
          key: const ValueKey('mobile_expert_team_entry'),
          icon: RevericIcons.groups_outlined,
          label: context.t(LocaleKeys.agentStudioExpertTeam),
          value: count(subagents),
          onTap: () => push(const MobileExpertTeamPage()),
        ),
        MobileDetailNavRow(
          icon: RevericIcons.link,
          label: context.t(LocaleKeys.settingsMcp),
          onTap: () => showMobileSettingsPage(context, 'mcp'),
        ),
      ],
    );
  }
}

/// 最近对话（跨作品 chat 会话），点击进入该作品聊天页继续。
class _RecentSessions extends ConsumerWidget {
  const _RecentSessions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final chatAsync = ref.watch(mobileChatSessionsProvider);
    final novelsById = {
      for (final n
          in ref.watch(novelsProvider).asData?.value ?? const <Novel>[])
        n.id: n,
    };

    // 仅展示 chat 会话；其它模式（圆桌/独白/小剧场/角色扮演）的历史在各自页面 header 的历史入口查看。
    if (chatAsync.isLoading && !chatAsync.hasValue) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: RevericSpacing.x2l),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final sessions = <AiChatSession>[...?chatAsync.asData?.value]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    if (sessions.isEmpty) {
      return _emptyHint(context, colors, typo);
    }
    return Column(
      children: [
        for (final session in sessions)
          Padding(
            padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
            child: _SessionCard(
              session: session,
              novel: novelsById[session.novelId],
            ),
          ),
      ],
    );
  }

  Widget _emptyHint(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.x2l),
      child: Text(
        context.t(LocaleKeys.mobileChatEmptyDesc),
        textAlign: TextAlign.center,
        style: typo.uiSmall.copyWith(color: colors.textSubtle),
      ),
    );
  }
}

class _SessionCard extends ConsumerWidget {
  const _SessionCard({required this.session, this.novel});

  final AiChatSession session;
  final Novel? novel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final title = session.title.trim().isEmpty
        ? context.t(LocaleKeys.aiSessionTitleDefault)
        : session.title;
    final novelName = novel?.title.trim().isNotEmpty == true
        ? novel!.title
        : context.t(LocaleKeys.mobileChatUnknownNovel);
    final subtitle = '$novelName · ${_formatTime(context, session.updatedAt)}';
    final databasePath = novel?.contentDatabasePath;
    final isCouncil = session.mode == AiSessionMode.council.value;
    final isMonologue = session.mode == AiSessionMode.monologue.value;
    final hasDatabase = databasePath != null && databasePath.isNotEmpty;
    final resolvedNovelName = novel?.title.trim().isNotEmpty == true
        ? novel!.title
        : title;

    Future<void> deleteSession() async {
      final confirmed = await showMobileDeleteConfirm(context, title: title);
      if (!confirmed) {
        return;
      }
      final service = ref.read(
        aiSessionPersistenceServiceProvider(
          novelId: session.novelId,
          databasePath: databasePath,
        ),
      );
      await service.deleteSession(session.id);
    }

    return MobileSectionCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          // council 会话进入移动端圆桌会议页恢复讨论历史；chat 会话进入实时聊天页继续
          // （对齐 desktop）。仅当作品内容库路径缺失（理论上不会发生）才回退只读查看页。
          builder: (_) {
            if (!hasDatabase) {
              return MobileChatSessionPage(
                session: session,
                displayTitle: title,
                databasePath: databasePath,
              );
            }
            if (isCouncil) {
              return MobileCouncilPage(
                novelId: session.novelId,
                novelName: resolvedNovelName,
                databasePath: databasePath,
                novelDescription: novel?.description,
                initialSessionId: session.id,
              );
            }
            if (isMonologue) {
              return MobileMonologuePage(
                novelId: session.novelId,
                novelName: resolvedNovelName,
                databasePath: databasePath,
                novelDescription: novel?.description,
                initialSessionId: session.id,
              );
            }
            return MobileNovelChatPage(
              novelId: session.novelId,
              databasePath: databasePath,
              existingSessionId: session.id,
            );
          },
        ),
      ),
      onDelete: deleteSession,
      deleteLabel: context.t(LocaleKeys.commonDelete),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colors.surfaceDim,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: RevericIcon(
              isCouncil
                  ? RevericIcons.groups_rounded
                  : isMonologue
                  ? RevericIcons.person_rounded
                  : RevericIcons.chat_bubble_outline,
              size: 17,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiMedium.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiTiny.copyWith(color: colors.textSubtle),
                ),
              ],
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          RevericIcon(
            RevericIcons.chevron_right,
            size: 18,
            color: colors.textSubtle,
          ),
        ],
      ),
    );
  }

  String _formatTime(BuildContext context, DateTime when) {
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
}
