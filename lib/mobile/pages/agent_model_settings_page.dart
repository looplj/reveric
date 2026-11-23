// 职责: 移动端模型设置 — 配置全局模型及内置流程专家的模型与推理强度。
// 关联文件:
//   lib/mobile/pages/subagent_prompt_edit_page.dart
//   lib/mobile/widgets/agent_edit_scaffold.dart
//   lib/mobile/widgets/model_effort_sheet.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/providers/subagent_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_studio.json
//   assets/translations/zh-CN/agent_studio.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/subagent.json
//   assets/translations/zh-CN/subagent.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/state-management.md
//   .agents/rules/i18n.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/models/ai_provider.dart';
import '../../shared/models/subagent.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/providers/subagent_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/agent_avatar.dart';
import 'subagent_prompt_edit_page.dart';
import '../widgets/agent_edit_scaffold.dart';
import '../widgets/model_effort_sheet.dart';
import '../widgets/section_scaffold.dart';

final _log = AppLogger.forModule('MobileAgentModelSettings');

const _builtinAgentSlugs = <String>[
  'writer',
  'review',
  'style_polish',
  'explorer',
  'chronicler',
];

const _builtinCopyKeys = <String, ({String titleKey, String descriptionKey})>{
  'writer': (
    titleKey: LocaleKeys.agentStudioWriter,
    descriptionKey: LocaleKeys.agentStudioWriterDescription,
  ),
  'review': (
    titleKey: LocaleKeys.agentStudioReview,
    descriptionKey: LocaleKeys.agentStudioReviewDescription,
  ),
  'style_polish': (
    titleKey: LocaleKeys.agentStudioStylePolish,
    descriptionKey: LocaleKeys.agentStudioStylePolishDescription,
  ),
  'explorer': (
    titleKey: LocaleKeys.agentStudioExplorer,
    descriptionKey: LocaleKeys.agentStudioExplorerDescription,
  ),
  'chronicler': (
    titleKey: LocaleKeys.agentStudioChronicler,
    descriptionKey: LocaleKeys.agentStudioChroniclerDescription,
  ),
};

Future<void> _showPromptActions(BuildContext context, SubAgent agent) async {
  final colors = RevericTheme.colorsOf(context);
  final typo = RevericTheme.typographyOf(context);
  final shouldEdit = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: colors.surface,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    builder: (sheetContext) {
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x4l,
              RevericSpacing.md,
              RevericSpacing.x4l,
              RevericSpacing.x5l,
            ),
            child: ListTile(
              key: ValueKey('mobile_model_prompt_edit_${agent.id}'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.lg,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(RevericRadius.large),
              ),
              leading: RevericIcon(
                RevericIcons.edit_note_outlined,
                size: 20,
                color: colors.accent,
              ),
              title: Text(
                sheetContext.t(LocaleKeys.agentStudioEditPrompt),
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
              trailing: RevericIcon(
                RevericIcons.chevron_right,
                size: 16,
                color: colors.textSubtle,
              ),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
          ),
        ),
      );
    },
  );
  if (!context.mounted || shouldEdit != true) {
    return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => MobileSubAgentPromptEditPage(agent: agent),
    ),
  );
}

Future<void> openMobileAgentModelSettingsPage(BuildContext context) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => const MobileAgentModelSettingsPage()),
  );
}

class MobileAgentModelSettingsPage extends ConsumerWidget {
  const MobileAgentModelSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final agentsAsync = ref.watch(globalSubAgentsProvider);

    return MobileManageScaffold(
      title: context.t(LocaleKeys.agentStudioModelSettings),
      child: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            _LoadError(message: context.t(LocaleKeys.commonLoadFailed)),
        data: (settings) => agentsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) =>
              _LoadError(message: context.t(LocaleKeys.commonLoadFailed)),
          data: (agents) => _MobileAgentModelSettingsContent(
            settings: settings,
            agents: agents,
            onDefaultChanged: (kind, optionId) =>
                _updateDefaultModel(context, ref, kind, optionId),
            onChatEffortChanged: (option, effort) =>
                _updateChatEffort(context, ref, option, effort),
            onAgentModelChanged: (agent, optionId) => _updateAgentModel(
              context,
              ref,
              settings.aiSettings,
              agent,
              optionId,
            ),
            onAgentEffortChanged: (agent, option, effort) =>
                _updateAgentEffort(context, ref, agent, option, effort),
          ),
        ),
      ),
    );
  }

  Future<void> _updateDefaultModel(
    BuildContext context,
    WidgetRef ref,
    AiModelKind kind,
    String? optionId,
  ) async {
    try {
      await ref
          .read(appSettingsProvider.notifier)
          .setDefaultAiModelForKind(kind, optionId);
    } catch (error, stackTrace) {
      _log.error(
        'update default $kind model failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
        );
      }
    }
  }

  Future<void> _updateAgentModel(
    BuildContext context,
    WidgetRef ref,
    AiSettings settings,
    SubAgent agent,
    String? optionId,
  ) async {
    AiModelOption? selected;
    for (final option in settings.availableModelOptions) {
      if (option.id == optionId) {
        selected = option;
        break;
      }
    }

    try {
      await ref
          .read(globalSubAgentsProvider.notifier)
          .updateSubAgent(
            agent.copyWith(
              providerId: selected?.providerId,
              model: selected?.model,
              reasoningEffort: reasoningEffortForOption(
                selected,
                agent.reasoningEffort,
              ),
            ),
          );
    } catch (error, stackTrace) {
      _log.error(
        'update built-in agent model failed id=${agent.id}',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
        );
      }
    }
  }

  Future<void> _updateChatEffort(
    BuildContext context,
    WidgetRef ref,
    AiModelOption option,
    String effort,
  ) async {
    try {
      await ref
          .read(appSettingsProvider.notifier)
          .setDefaultChatModelWithEffort(option, effort);
    } catch (error, stackTrace) {
      _log.error(
        'update default chat reasoning effort failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
        );
      }
    }
  }

  Future<void> _updateAgentEffort(
    BuildContext context,
    WidgetRef ref,
    SubAgent agent,
    AiModelOption option,
    String effort,
  ) async {
    try {
      await ref
          .read(globalSubAgentsProvider.notifier)
          .updateSubAgent(
            agent.copyWith(
              providerId: option.providerId,
              model: option.model,
              reasoningEffort: effort,
            ),
          );
    } catch (error, stackTrace) {
      _log.error(
        'update built-in agent reasoning effort failed id=${agent.id}',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
        );
      }
    }
  }
}

class _MobileAgentModelSettingsContent extends StatelessWidget {
  const _MobileAgentModelSettingsContent({
    required this.settings,
    required this.agents,
    required this.onDefaultChanged,
    required this.onChatEffortChanged,
    required this.onAgentModelChanged,
    required this.onAgentEffortChanged,
  });

  final AppSettings settings;
  final List<SubAgent> agents;
  final Future<void> Function(AiModelKind kind, String? optionId)
  onDefaultChanged;
  final Future<void> Function(AiModelOption option, String effort)
  onChatEffortChanged;
  final Future<void> Function(SubAgent agent, String? optionId)
  onAgentModelChanged;
  final Future<void> Function(
    SubAgent agent,
    AiModelOption option,
    String effort,
  )
  onAgentEffortChanged;

  @override
  Widget build(BuildContext context) {
    final agentsBySlug = {for (final agent in agents) agent.slug: agent};
    final builtinAgents = _builtinAgentSlugs
        .map((slug) => agentsBySlug[slug])
        .whereType<SubAgent>()
        .toList(growable: false);
    final items = [
      _MobileModelSettingItem(
        key: const ValueKey('mobile_model_setting_chat'),
        title: context.t(LocaleKeys.agentStudioChat),
        description: context.t(LocaleKeys.agentStudioChatDescription),
        icon: RevericIcons.chat_bubble_outline,
        modelKind: AiModelKind.chat,
        selectedId: settings.aiSettings.defaultChatModelId,
        selectedEffort: settings.aiSettings.defaultChatReasoningEffort,
        onChanged: (optionId) => onDefaultChanged(AiModelKind.chat, optionId),
        onEffortChanged: onChatEffortChanged,
      ),
      _MobileModelSettingItem(
        key: const ValueKey('mobile_model_setting_image'),
        title: context.t(LocaleKeys.agentStudioImage),
        description: context.t(LocaleKeys.agentStudioImageDescription),
        icon: RevericIcons.image_outlined,
        modelKind: AiModelKind.image,
        selectedId: settings.aiSettings.defaultImageModelId,
        onChanged: (optionId) => onDefaultChanged(AiModelKind.image, optionId),
      ),
      for (final agent in builtinAgents)
        () {
          final copy = _builtinCopyKeys[agent.slug]!;
          return _MobileModelSettingItem(
            key: ValueKey('mobile_model_setting_${agent.slug}'),
            title: context.t(copy.titleKey),
            description: context.t(copy.descriptionKey),
            icon: RevericIcons.smart_toy_outlined,
            modelKind: AiModelKind.chat,
            selectedId: _optionIdFor(agent),
            selectedEffort: agent.reasoningEffort,
            agent: agent,
            onChanged: (optionId) => onAgentModelChanged(agent, optionId),
            onEffortChanged: (option, effort) =>
                onAgentEffortChanged(agent, option, effort),
          );
        }(),
    ];

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x4l,
        RevericSpacing.x2l,
        RevericSpacing.x4l,
        RevericSpacing.x5l,
      ),
      itemCount: items.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: RevericSpacing.lg),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Text(
            context.t(LocaleKeys.agentStudioModelSettingsDescription),
            style: RevericTheme.typographyOf(context).ui.copyWith(
              color: RevericTheme.colorsOf(context).textMuted,
              height: 1.5,
            ),
          );
        }
        final itemIndex = index - 1;
        return _MobileModelSettingCard(
          item: items[itemIndex],
          aiSettings: settings.aiSettings,
        );
      },
    );
  }

  String? _optionIdFor(SubAgent agent) {
    if (agent.providerId == null || agent.model == null) {
      return null;
    }
    return '${agent.providerId}::${agent.model}';
  }
}

class _MobileModelSettingItem {
  const _MobileModelSettingItem({
    required this.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.modelKind,
    required this.selectedId,
    required this.onChanged,
    this.selectedEffort,
    this.agent,
    this.onEffortChanged,
  });

  final Key key;
  final String title;
  final String description;
  final String icon;
  final AiModelKind modelKind;
  final String? selectedId;
  final String? selectedEffort;
  final Future<void> Function(String? optionId) onChanged;
  final SubAgent? agent;
  final Future<void> Function(AiModelOption option, String effort)?
  onEffortChanged;
}

class _MobileModelSettingCard extends ConsumerWidget {
  const _MobileModelSettingCard({required this.item, required this.aiSettings});

  final _MobileModelSettingItem item;
  final AiSettings aiSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final options = aiSettings.availableModelOptionsForKind(item.modelKind);
    final selected = options
        .where((option) => option.id == item.selectedId)
        .firstOrNull;

    const disabledModelIds = <String>{};

    Future<void> selectModel() async {
      if (item.onEffortChanged != null) {
        await showAiModelEffortSheet(
          context,
          title: context.t(LocaleKeys.subagentModel),
          subtitle: item.title,
          models: options,
          selectedId: item.selectedId,
          selectedEffort: reasoningEffortForOption(
            selected,
            item.selectedEffort,
          ),
          disabledModelIds: disabledModelIds,

          unsetLabel: context.t(LocaleKeys.subagentModelNotSelected),
          onUnset: () => unawaited(item.onChanged(null)),
          onSelectModel: (option) => unawaited(item.onChanged(option.id)),
          onSelectEffort: (option, effort) =>
              unawaited(item.onEffortChanged!(option, effort)),
        );
        return;
      }
      final picked = await showMobileModelPicker(
        context,
        ref,
        selectedId: item.selectedId,
        modelOptions: options,

        disabledModelIds: disabledModelIds,
      );
      if (picked == null) {
        return;
      }
      await item.onChanged(picked.isEmpty ? null : picked);
    }

    Widget leading() {
      final agent = item.agent;
      if (agent != null) {
        return AgentAvatar(
          avatarPath: agent.avatarPath,
          slug: agent.slug,
          avatarEmoji: agent.avatarEmoji,
          size: 42,
        );
      }
      return MobileSectionIconBox(icon: item.icon);
    }

    return MobileSectionCard(
      cardKey: item.key,
      onTap: selectModel,
      onLongPress: item.agent == null
          ? null
          : () => _showPromptActions(context, item.agent!),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              leading(),
              const SizedBox(width: RevericSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: RevericSpacing.xxs),
                    Text(
                      item.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmall.copyWith(
                        color: colors.textMuted,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          Divider(height: 1, thickness: 1, color: colors.borderSubtle),
          const SizedBox(height: RevericSpacing.md),
          Row(
            children: [
              Text(
                context.t(LocaleKeys.agentStudioModelLabel),
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
              const SizedBox(width: RevericSpacing.md),
              Expanded(
                child: Text(
                  selected?.displayModelName ??
                      context.t(LocaleKeys.subagentModelNotSelected),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: RevericSpacing.xxs),
              RevericIcon(
                RevericIcons.chevron_right,
                size: 16,
                color: colors.textSubtle,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        style: RevericTheme.typographyOf(
          context,
        ).uiSmall.copyWith(color: RevericTheme.colorsOf(context).textMuted),
      ),
    );
  }
}
