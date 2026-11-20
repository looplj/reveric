// 职责: Home 模型设置页 — 配置全局模型及内置智能体的模型与推理强度。
// 关联文件:
//   lib/shared/providers/settings_providers.dart
//   lib/shared/providers/subagent_providers.dart
//   lib/desktop/widgets/ai/model/model_selector.dart
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
//   .agents/rules/hooks.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/dialog_feedback.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/ai_provider.dart';
import '../../../shared/models/subagent.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../../shared/providers/subagent_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/agent_avatar.dart';
import '../../../shared/widgets/guide/tour.dart';
import '../../../shared/widgets/guide/trigger.dart';
import '../ai/model/model_selector.dart';
import 'home_management_cards.dart';

final _log = AppLogger.forModule('AgentModelSettings');

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

Future<void> showAgentModelSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 880,
        height: 640,
        child: DialogFeedback(
          builder: (context) =>
              AgentModelSettingsPage(headerGestureExclusionKey: GlobalKey()),
        ),
      ),
    ),
  );
}

class AgentModelSettingsPage extends HookConsumerWidget {
  const AgentModelSettingsPage({
    super.key,
    required this.headerGestureExclusionKey,
    this.headerTrailingInset = 0,
    this.onEditPrompt,
  });

  final GlobalKey headerGestureExclusionKey;
  final double headerTrailingInset;
  final ValueChanged<SubAgent>? onEditPrompt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final agentsAsync = ref.watch(globalSubAgentsProvider);
    final chatRowKey = useMemoized(GlobalKey.new);
    final imageRowKey = useMemoized(GlobalKey.new);
    final agentsRowKey = useMemoized(GlobalKey.new);
    final ready = settingsAsync.hasValue && agentsAsync.hasValue;
    final guide = useAutoGuideTour(
      ref: ref,
      tourId: GuideTourId.modelSettings,
      ready: ready,
      keys: [ready],
      buildSteps: (ctx) => [
        GuideStep(
          id: 'model_settings_chat',
          targetKey: chatRowKey,
          icon: RevericIcons.chat_bubble_outline,
          title: ctx.t(LocaleKeys.onboardingGuideModelSettingsChatTitle),
          description: ctx.t(LocaleKeys.onboardingGuideModelSettingsChatBody),
        ),
        GuideStep(
          id: 'model_settings_image',
          targetKey: imageRowKey,
          icon: RevericIcons.image_outlined,
          title: ctx.t(LocaleKeys.onboardingGuideModelSettingsImageTitle),
          description: ctx.t(LocaleKeys.onboardingGuideModelSettingsImageBody),
        ),
        GuideStep(
          id: 'model_settings_agents',
          targetKey: agentsRowKey,
          icon: RevericIcons.smart_toy_outlined,
          title: ctx.t(LocaleKeys.onboardingGuideModelSettingsAgentsTitle),
          description: ctx.t(LocaleKeys.onboardingGuideModelSettingsAgentsBody),
        ),
      ],
    );

    return HomeManagementScaffold(
      headerGestureExclusionKey: headerGestureExclusionKey,
      headerTrailingInset: headerTrailingInset,
      secondaryAction: GuideReplayButton(
        onPressed: () => unawaited(guide.replay()),
      ),
      icon: RevericIcons.tune,
      titleKey: LocaleKeys.agentStudioModelSettings,
      child: settingsAsync.when(
        loading: () => const HomeManagementLoadingState(),
        error: (_, _) => HomeManagementErrorState(
          message: context.t(LocaleKeys.commonLoadFailed),
        ),
        data: (settings) => agentsAsync.when(
          loading: () => const HomeManagementLoadingState(),
          error: (_, _) => HomeManagementErrorState(
            message: context.t(LocaleKeys.commonLoadFailed),
          ),
          data: (agents) => _AgentModelSettingsContent(
            settings: settings,
            agents: agents,
            chatRowKey: chatRowKey,
            imageRowKey: imageRowKey,
            agentsRowKey: agentsRowKey,

            onEditPrompt: onEditPrompt,
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
        'update agent model failed id=${agent.id}',
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
        'update agent reasoning effort failed id=${agent.id}',
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

class _AgentModelSettingsContent extends StatelessWidget {
  const _AgentModelSettingsContent({
    required this.settings,
    required this.agents,
    this.chatRowKey,
    this.imageRowKey,
    this.agentsRowKey,

    required this.onEditPrompt,
    required this.onDefaultChanged,
    required this.onChatEffortChanged,
    required this.onAgentModelChanged,
    required this.onAgentEffortChanged,
  });

  final AppSettings settings;
  final List<SubAgent> agents;
  final GlobalKey? chatRowKey;
  final GlobalKey? imageRowKey;
  final GlobalKey? agentsRowKey;
  final ValueChanged<SubAgent>? onEditPrompt;
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
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final agentsBySlug = {for (final agent in agents) agent.slug: agent};
    final builtinAgents = _builtinAgentSlugs
        .map((slug) => agentsBySlug[slug])
        .whereType<SubAgent>()
        .toList(growable: false);
    final items = [
      _AgentModelSettingItem(
        title: context.t(LocaleKeys.agentStudioChat),
        description: context.t(LocaleKeys.agentStudioChatDescription),
        icon: RevericIcons.chat_bubble_outline,
        modelKind: AiModelKind.chat,
        selectedId: settings.aiSettings.defaultChatModelId,
        selectedEffort: settings.aiSettings.defaultChatReasoningEffort,
        onChanged: (optionId) => onDefaultChanged(AiModelKind.chat, optionId),
        onEffortChanged: onChatEffortChanged,
      ),
      _AgentModelSettingItem(
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
          return _AgentModelSettingItem(
            title: context.t(copy.titleKey),
            description: context.t(copy.descriptionKey),
            icon: RevericIcons.smart_toy_outlined,
            modelKind: AiModelKind.chat,
            selectedId: _optionIdFor(agent),
            selectedEffort: agent.reasoningEffort,
            agent: agent,
            onEditPrompt: onEditPrompt == null
                ? null
                : () => onEditPrompt!(agent),
            onChanged: (optionId) => onAgentModelChanged(agent, optionId),
            onEffortChanged: (option, effort) =>
                onAgentEffortChanged(agent, option, effort),
          );
        }(),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.t(LocaleKeys.agentStudioModelSettingsDescription),
              style: typo.ui.copyWith(color: colors.textMuted, height: 1.5),
            ),
            const SizedBox(height: RevericSpacing.x3l),
            for (var index = 0; index < items.length; index++) ...[
              _AgentModelSettingRow(
                key: switch (index) {
                  0 => chatRowKey,
                  1 => imageRowKey,
                  2 => agentsRowKey,
                  _ => null,
                },
                item: items[index],
                aiSettings: settings.aiSettings,
              ),
              if (index < items.length - 1)
                const SizedBox(height: RevericSpacing.lg),
            ],
          ],
        ),
      ),
    );
  }

  String? _optionIdFor(SubAgent agent) {
    if (agent.providerId == null || agent.model == null) {
      return null;
    }
    return '${agent.providerId}::${agent.model}';
  }
}

class _AgentModelSettingItem {
  const _AgentModelSettingItem({
    required this.title,
    required this.description,
    required this.icon,
    required this.modelKind,
    required this.selectedId,
    required this.onChanged,
    this.selectedEffort,
    this.onEditPrompt,
    this.onEffortChanged,
    this.agent,
  });

  final String title;
  final String description;
  final String icon;
  final AiModelKind modelKind;
  final String? selectedId;
  final String? selectedEffort;
  final Future<void> Function(String? optionId) onChanged;
  final VoidCallback? onEditPrompt;
  final Future<void> Function(AiModelOption option, String effort)?
  onEffortChanged;
  final SubAgent? agent;
}

class _AgentModelSettingRow extends StatelessWidget {
  const _AgentModelSettingRow({
    super.key,
    required this.item,
    required this.aiSettings,
  });

  final _AgentModelSettingItem item;
  final AiSettings aiSettings;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final options = aiSettings.availableModelOptionsForKind(item.modelKind);
    final selectedOption = options
        .where((option) => option.id == item.selectedId)
        .firstOrNull;

    const disabledModelIds = <String>{};

    Widget leading() {
      final agent = item.agent;
      if (agent != null) {
        return AgentAvatar(
          avatarPath: agent.avatarPath,
          slug: agent.slug,
          avatarEmoji: agent.avatarEmoji,
          size: 36,
        );
      }
      return HomeManagementIconBadge(icon: item.icon);
    }

    final details = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title,
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: RevericSpacing.xxs),
          Text(
            item.description,
            style: typo.uiSmall.copyWith(color: colors.textMuted, height: 1.45),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
    Widget selector(double width) {
      return SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.t(LocaleKeys.agentStudioModelLabel),
              style: typo.uiTiny.copyWith(color: colors.textSubtle),
            ),
            const SizedBox(height: RevericSpacing.xs),
            ModelSelector.field(
              key: ValueKey(
                item.agent == null
                    ? 'default_model_selector_${item.modelKind.name}'
                    : 'agent_model_selector_${item.agent!.id}',
              ),
              availableModels: options,
              selectedId: item.selectedId,
              onChanged: item.onChanged,
              selectedEffort: reasoningEffortForOption(
                selectedOption,
                item.selectedEffort,
              ),
              onSelectWithEffort: item.onEffortChanged,
              disabledModelIds: disabledModelIds,

              unsetLabel: context.t(LocaleKeys.subagentModelNotSelected),
              emptyMessage: context.t(LocaleKeys.subagentNoModelsAvailable),
              dense: true,
            ),
          ],
        ),
      );
    }

    final editPromptButton = item.onEditPrompt == null
        ? null
        : Tooltip(
            message: context.t(LocaleKeys.agentStudioEditPrompt),
            child: InkWell(
              key: ValueKey('agent_model_prompt_edit_${item.agent!.id}'),
              onTap: item.onEditPrompt,
              borderRadius: BorderRadius.circular(RevericRadius.small),
              child: Padding(
                padding: const EdgeInsets.all(RevericSpacing.xs),
                child: RevericIcon(
                  RevericIcons.more_horiz,
                  size: 18,
                  color: colors.textMuted,
                ),
              ),
            ),
          );

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderInput),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 640) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    leading(),
                    const SizedBox(width: RevericSpacing.lg),
                    details,
                    if (editPromptButton != null) ...[
                      const SizedBox(width: RevericSpacing.sm),
                      editPromptButton,
                    ],
                  ],
                ),
                const SizedBox(height: RevericSpacing.lg),
                selector(double.infinity),
              ],
            );
          }
          return Row(
            children: [
              leading(),
              const SizedBox(width: RevericSpacing.lg),
              details,
              const SizedBox(width: RevericSpacing.x2l),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (editPromptButton != null) ...[
                    SizedBox(
                      height: RevericSizes.fieldHeightSm,
                      child: Center(child: editPromptButton),
                    ),
                    const SizedBox(width: RevericSpacing.lg),
                  ],
                  selector(320),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
