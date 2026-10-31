// 职责: Usage 会话视图 — 展示会话排行并下钻主对话、子代理和每次运行的词元构成。
// 关联文件:
//   lib/shared/providers/usage_query_providers.dart
//   lib/shared/services/ai/usage_service.dart
//   lib/shared/components/reveric_select.dart
//   lib/shared/models/models_catalog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_select.dart';
import '../../database/app_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import '../../models/models_catalog.dart';
import '../../providers/settings_providers.dart';
import '../../providers/usage_query_providers.dart';
import '../../services/ai/usage_service.dart';
import '../../theme/theme.dart';

class UsageSessionsView extends HookConsumerWidget {
  const UsageSessionsView({
    super.key,
    required this.isNarrow,
    this.initialSessionId,
  });

  final bool isNarrow;
  final String? initialSessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final openSessionId = useState<String?>(initialSessionId);
    final sessionSort = useState(UsageSessionSort.last_used_descending);
    useEffect(() {
      if (initialSessionId != null) {
        openSessionId.value = initialSessionId;
      }
      return null;
    }, [initialSessionId]);

    final selected = openSessionId.value;
    if (selected != null) {
      return _UsageSessionDetail(
        sessionId: selected,
        isNarrow: isNarrow,
        onBack: () => openSessionId.value = null,
      );
    }
    return _UsageSessionList(
      isNarrow: isNarrow,
      sessionSort: sessionSort.value,
      onSortChanged: (value) => sessionSort.value = value,
      onOpen: (id) => openSessionId.value = id,
    );
  }
}

class _UsageSessionList extends ConsumerWidget {
  const _UsageSessionList({
    required this.isNarrow,
    required this.sessionSort,
    required this.onSortChanged,
    required this.onOpen,
  });

  final bool isNarrow;
  final UsageSessionSort sessionSort;
  final ValueChanged<UsageSessionSort> onSortChanged;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final sessionsAsync = ref.watch(
      topUsageSessionsProvider(UsageFilter(sessionSort: sessionSort)),
    );
    final aiSettings = ref.watch(aiSettingsProvider);

    String providerName(String? id) {
      if (id == null || id.isEmpty) return '';
      return aiSettings.findConfigById(id)?.displayName ?? id;
    }

    final sortControl = SizedBox(
      width: isNarrow ? 176 : 190,
      child: RevericSelect<UsageSessionSort>(
        value: sessionSort,
        height: isNarrow ? 38 : 32,
        items: [
          RevericSelectItem<UsageSessionSort>(
            value: UsageSessionSort.last_used_descending,
            label: context.t(
              LocaleKeys.settingsUsageSessionsSortConversationTime,
            ),
          ),
          RevericSelectItem<UsageSessionSort>(
            value: UsageSessionSort.total_tokens_descending,
            label: context.t(LocaleKeys.settingsUsageSessionsSortUsage),
          ),
        ],
        onChanged: onSortChanged,
      ),
    );

    final scopeLabel = context.t(LocaleKeys.settingsUsageTabSessions);
    final header = Row(
      children: [
        Expanded(
          child: Text(
            scopeLabel,
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
        ),
        sortControl,
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: RevericSpacing.md),
        _UsageSurface(
          padding: EdgeInsets.zero,
          child: sessionsAsync.when(
            data: (sessions) {
              if (sessions.isEmpty) {
                return _UsageMessage(
                  label: context.t(LocaleKeys.settingsUsageNoSessions),
                );
              }
              if (isNarrow) {
                return Column(
                  children: [
                    for (var i = 0; i < sessions.length; i++) ...[
                      _SessionCard(
                        session: sessions[i],
                        providerName: providerName(sessions[i].provider),
                        onTap: () => onOpen(sessions[i].id),
                      ),
                      if (i < sessions.length - 1)
                        Divider(height: 1, color: colors.borderSubtle),
                    ],
                  ],
                );
              }
              return Column(
                children: [
                  const _SessionTableHeader(),
                  Divider(height: 1, color: colors.borderSubtle),
                  for (var i = 0; i < sessions.length; i++) ...[
                    _SessionTableRow(
                      session: sessions[i],
                      providerName: providerName(sessions[i].provider),
                      onTap: () => onOpen(sessions[i].id),
                    ),
                    if (i < sessions.length - 1)
                      Divider(height: 1, color: colors.borderSubtle),
                  ],
                ],
              );
            },
            loading: () => const _UsageLoadingRows(),
            error: (_, _) => _UsageMessage(
              label: context.t(LocaleKeys.settingsUsageFailedToLoad),
            ),
          ),
        ),
      ],
    );
  }
}

class _SessionTableHeader extends StatelessWidget {
  const _SessionTableHeader();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final style = typo.uiSmallSemibold.copyWith(color: colors.textMuted);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x3l,
        vertical: RevericSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              context.t(LocaleKeys.settingsUsageSessionColumnSession),
              style: style,
            ),
          ),
          SizedBox(
            width: 100,
            child: Text(
              context.t(LocaleKeys.settingsUsageSessionColumnMode),
              style: style,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              context.t(LocaleKeys.settingsUsageListColumnModel),
              style: style,
            ),
          ),
          SizedBox(
            width: 82,
            child: Text(
              context.t(LocaleKeys.settingsUsageSessionColumnTokens),
              style: style,
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 140,
            child: Text(
              context.t(LocaleKeys.settingsUsageSessionColumnLastUsed),
              style: style,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionTableRow extends StatelessWidget {
  const _SessionTableRow({
    required this.session,
    required this.providerName,
    required this.onTap,
  });

  final UsageSessionSummary session;
  final String providerName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.x3l,
              vertical: RevericSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.title,
                        style: typo.uiSmallSemibold.copyWith(
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (providerName.isNotEmpty)
                        Text(
                          providerName,
                          style: typo.uiTiny.copyWith(color: colors.textMuted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                SizedBox(width: 100, child: _ModePill(mode: session.mode)),
                Expanded(
                  flex: 3,
                  child: Text(
                    session.model ?? '—',
                    style: typo.uiSmall.copyWith(color: colors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: 82,
                  child: Text(
                    _formatTokens(session.totalTokens),
                    style: typo.uiSmallSemibold.copyWith(
                      color: colors.textPrimary,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Text(
                          _formatDateTime(session.lastUsed),
                          style: typo.uiSmall.copyWith(color: colors.textMuted),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: RevericSpacing.sm),
                      RevericIcon(
                        RevericIcons.chevron_right,
                        size: 12,
                        color: colors.textSubtle,
                      ),
                    ],
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

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.providerName,
    required this.onTap,
  });

  final UsageSessionSummary session;
  final String providerName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.all(RevericSpacing.x3l),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              session.title,
                              style: typo.uiSemibold.copyWith(
                                color: colors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: RevericSpacing.sm),
                          _ModePill(mode: session.mode),
                        ],
                      ),
                      const SizedBox(height: RevericSpacing.xs),
                      Text(
                        [
                          if (providerName.isNotEmpty) providerName,
                          if ((session.model ?? '').isNotEmpty) session.model!,
                          _formatDateTime(session.lastUsed),
                        ].join(' · '),
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: RevericSpacing.lg),
                Text(
                  _formatTokens(session.totalTokens),
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(width: RevericSpacing.sm),
                RevericIcon(
                  RevericIcons.chevron_right,
                  size: 14,
                  color: colors.textSubtle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UsageSessionDetail extends ConsumerWidget {
  const _UsageSessionDetail({
    required this.sessionId,
    required this.isNarrow,
    required this.onBack,
  });

  final String sessionId;
  final bool isNarrow;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(usageSessionDetailProvider(sessionId));
    return detailAsync.when(
      data: (detail) {
        if (detail == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DetailBackHeader(onBack: onBack),
              const SizedBox(height: RevericSpacing.x3l),
              _UsageMessage(
                label: context.t(LocaleKeys.settingsUsageSessionNotFound),
              ),
            ],
          );
        }
        return _SessionDetailContent(
          detail: detail,
          isNarrow: isNarrow,
          onBack: onBack,
        );
      },
      loading: () => const _UsageLoadingRows(),
      error: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailBackHeader(onBack: onBack),
          const SizedBox(height: RevericSpacing.x3l),
          _UsageMessage(label: context.t(LocaleKeys.settingsUsageFailedToLoad)),
        ],
      ),
    );
  }
}

class _SessionDetailContent extends ConsumerWidget {
  const _SessionDetailContent({
    required this.detail,
    required this.isNarrow,
    required this.onBack,
  });

  final UsageSessionDetail detail;
  final bool isNarrow;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final session = detail.session;
    final aiSettings = ref.watch(aiSettingsProvider);
    final provider = session.provider == null
        ? null
        : aiSettings.findConfigById(session.provider!)?.displayName ??
              session.provider;
    final subtitle = [
      if ((session.model ?? '').isNotEmpty) session.model!,
      if ((provider ?? '').isNotEmpty) provider!,
      context.t(
        LocaleKeys.settingsUsageRequests,
        namedArgs: {'count': '${session.requestCount}'},
      ),
      _formatDateTime(session.lastUsed),
    ].join(' · ');
    final usageCard = _SessionUsageCard(detail: detail);
    final contextCard = _ContextWindowCard(session: session);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BackButton(onPressed: onBack),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: RevericSpacing.sm,
                    runSpacing: RevericSpacing.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        session.title,
                        style: typo.uiSemibold.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      _ModePill(mode: session.mode),
                    ],
                  ),
                  const SizedBox(height: RevericSpacing.xs),
                  Text(
                    subtitle,
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.x3l),
        if (isNarrow) ...[
          usageCard,
          const SizedBox(height: RevericSpacing.lg),
          contextCard,
        ] else
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: usageCard),
                const SizedBox(width: RevericSpacing.lg),
                Expanded(child: contextCard),
              ],
            ),
          ),
        const SizedBox(height: RevericSpacing.x4l),
        Text(
          context.t(LocaleKeys.settingsUsageComposition),
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: RevericSpacing.md),
        _UsageComposition(detail: detail),
        const SizedBox(height: RevericSpacing.x4l),
        Text(
          context.t(LocaleKeys.settingsUsageListTitle),
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: RevericSpacing.lg),
        _SessionRecords(
          records: detail.records,
          rootSource: session.mode,
          subagentNames: {
            for (final agent in detail.subagents)
              agent.sessionId: agent.displayName,
          },
          isNarrow: isNarrow,
        ),
      ],
    );
  }
}

class _DetailBackHeader extends StatelessWidget {
  const _DetailBackHeader({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => _BackButton(onPressed: onBack);
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        onPressed: onPressed,
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        icon: RevericIcon(
          RevericIcons.arrow_back,
          size: 16,
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

class _SessionUsageCard extends StatelessWidget {
  const _SessionUsageCard({required this.detail});

  final UsageSessionDetail detail;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final tokens = detail.tokens;
    final parts = <({String label, int value, Color color})>[
      (
        label: context.t(LocaleKeys.settingsUsageInput),
        value: tokens.totalInputTokens,
        color: colors.accent,
      ),
      (
        label: context.t(LocaleKeys.settingsUsageCacheRead),
        value: tokens.totalCacheReadTokens,
        color: colors.additionBorder,
      ),
      (
        label: context.t(LocaleKeys.settingsUsageCacheWrite),
        value: tokens.totalCacheWriteTokens,
        color: colors.accentWarm,
      ),
      (
        label: context.t(LocaleKeys.settingsUsageOutput),
        value: tokens.totalOutputTokens,
        color: colors.textMuted,
      ),
    ];
    final total = tokens.totalTokens;
    return _UsageSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.t(LocaleKeys.settingsUsageSessionUsage),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                _formatTokens(total),
                style: typo.heading2.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(width: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.settingsUsageTokens),
                style: typo.uiSmall.copyWith(color: colors.textSubtle),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.x2l),
          _StackedBar(
            segments: [
              for (final part in parts) (value: part.value, color: part.color),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          Wrap(
            spacing: RevericSpacing.lg,
            runSpacing: RevericSpacing.xs,
            children: [
              for (final part in parts)
                _LegendValue(
                  color: part.color,
                  label: part.label,
                  value: _formatTokens(part.value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ContextWindowCard extends StatelessWidget {
  const _ContextWindowCard({required this.session});

  final UsageSessionSummary session;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final limit = session.model == null
        ? null
        : lookupCatalogLimit(session.model!)?.context;
    final fraction = limit == null || limit == 0
        ? 0.0
        : (session.contextInputTokens / limit).clamp(0.0, 1.0);
    return _UsageSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.t(LocaleKeys.settingsUsageContextWindow),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                _formatTokens(session.contextInputTokens),
                style: typo.heading2.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(width: RevericSpacing.sm),
              Flexible(
                child: Text(
                  limit == null
                      ? '/ —'
                      : '/ ${_formatTokens(limit)} · ${(fraction * 100).round()}%',
                  style: typo.uiSmall.copyWith(color: colors.textSubtle),
                ),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.x2l),
          ClipRRect(
            borderRadius: BorderRadius.circular(RevericRadius.full),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: fraction,
              color: colors.accent,
              backgroundColor: colors.surfaceContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _StackedBar extends StatelessWidget {
  const _StackedBar({required this.segments});

  final List<({int value, Color color})> segments;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final total = segments.fold<int>(0, (sum, segment) => sum + segment.value);
    if (total == 0) {
      return Container(height: 8, color: colors.surfaceContainer);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(RevericRadius.full),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            for (final segment in segments)
              if (segment.value > 0)
                Expanded(
                  flex: segment.value,
                  child: ColoredBox(color: segment.color),
                ),
          ],
        ),
      ),
    );
  }
}

class _LegendValue extends StatelessWidget {
  const _LegendValue({
    required this.color,
    required this.label,
    required this.value,
  });

  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: typo.uiSmall.copyWith(color: colors.textMuted)),
        const SizedBox(width: 4),
        Text(
          value,
          style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _UsageComposition extends StatelessWidget {
  const _UsageComposition({required this.detail});

  final UsageSessionDetail detail;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final subagentTokens = detail.subagents.fold<int>(
      0,
      (sum, agent) => sum + agent.totalTokens,
    );
    return _UsageSurface(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
      child: Column(
        children: [
          _CompositionRow(
            item: _CompositionItem(
              label: context.t(LocaleKeys.settingsUsageMainConversation),
              subtitle: context.t(
                LocaleKeys.settingsUsageRequests,
                namedArgs: {'count': '${detail.mainRequestCount}'},
              ),
              tokens: detail.mainTokens,
              total: detail.session.totalTokens,
              color: colors.accent,
            ),
          ),
          if (detail.subagents.isNotEmpty) ...[
            Divider(height: 1, color: colors.borderSubtle),
            _SubagentGroup(
              agents: detail.subagents,
              tokens: subagentTokens,
              total: detail.session.totalTokens,
            ),
          ],
        ],
      ),
    );
  }
}

class _SubagentGroup extends HookWidget {
  const _SubagentGroup({
    required this.agents,
    required this.tokens,
    required this.total,
  });

  final List<UsageSubagentSummary> agents;
  final int tokens;
  final int total;

  @override
  Widget build(BuildContext context) {
    final open = useState(true);
    return Column(
      children: [
        _CompositionRow(
          item: _CompositionItem(
            label: context.t(LocaleKeys.settingsUsageSubagents),
            subtitle: context.t(
              LocaleKeys.settingsUsageRuns,
              namedArgs: {
                'count':
                    '${agents.fold<int>(0, (sum, a) => sum + a.runs.length)}',
              },
            ),
            tokens: tokens,
            total: total,
            color: RevericTheme.colorsOf(context).accentAmber,
          ),
          expandable: true,
          expanded: open.value,
          onTap: () => open.value = !open.value,
        ),
        if (open.value)
          Padding(
            padding: const EdgeInsets.only(left: RevericSpacing.x3l),
            child: Column(
              children: [
                for (final agent in agents) _SubagentNode(agent: agent),
              ],
            ),
          ),
      ],
    );
  }
}

class _SubagentNode extends HookWidget {
  const _SubagentNode({required this.agent});

  final UsageSubagentSummary agent;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final open = useState(false);
    return Column(
      children: [
        _CompositionRow(
          item: _CompositionItem(
            label: agent.displayName,
            subtitle: [
              if ((agent.model ?? '').isNotEmpty) agent.model!,
              context.t(
                LocaleKeys.settingsUsageRuns,
                namedArgs: {'count': '${agent.runs.length}'},
              ),
            ].join(' · '),
            tokens: agent.totalTokens,
            total: agent.totalTokens,
            color: colors.accentAmber,
          ),
          expandable: agent.runs.isNotEmpty,
          expanded: open.value,
          onTap: agent.runs.isEmpty ? null : () => open.value = !open.value,
        ),
        if (open.value)
          Padding(
            padding: const EdgeInsets.only(
              left: RevericSpacing.x3l,
              right: RevericSpacing.x3l,
              bottom: RevericSpacing.sm,
            ),
            child: Column(
              children: [
                for (final run in agent.runs)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: RevericSpacing.xs,
                    ),
                    child: Row(
                      children: [
                        Text(
                          _formatRunTime(run.lastUsed),
                          style: typo.uiTiny.copyWith(color: colors.textMuted),
                        ),
                        const SizedBox(width: RevericSpacing.sm),
                        Expanded(
                          child: Text(
                            agent.displayName,
                            style: typo.uiSmall.copyWith(
                              color: colors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: RevericSpacing.sm),
                        Text(
                          _formatTokens(run.totalTokens),
                          style: typo.uiSmallSemibold.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CompositionRow extends StatelessWidget {
  const _CompositionRow({
    required this.item,
    this.expandable = false,
    this.expanded = false,
    this.onTap,
  });

  final _CompositionItem item;
  final bool expandable;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final fraction = item.total == 0
        ? 0.0
        : (item.tokens / item.total).clamp(0.0, 1.0);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.x3l,
            vertical: RevericSpacing.sm,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: expandable
                    ? RevericIcon(
                        expanded
                            ? RevericIcons.keyboard_arrow_down
                            : RevericIcons.chevron_right,
                        size: 12,
                        color: colors.textMuted,
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: RevericSpacing.xs),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: item.color,
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.label,
                      style: typo.uiSmallSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      item.subtitle,
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: RevericSpacing.md),
              Expanded(
                flex: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(RevericRadius.full),
                  child: LinearProgressIndicator(
                    minHeight: 5,
                    value: fraction,
                    color: item.color,
                    backgroundColor: colors.surfaceContainer,
                  ),
                ),
              ),
              const SizedBox(width: RevericSpacing.md),
              SizedBox(
                width: 56,
                child: Text(
                  _formatTokens(item.tokens),
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textPrimary,
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  '${(fraction * 100).toStringAsFixed(1)}%',
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompositionItem {
  const _CompositionItem({
    required this.label,
    required this.subtitle,
    required this.tokens,
    required this.total,
    required this.color,
  });

  final String label;
  final String subtitle;
  final int tokens;
  final int total;
  final Color color;
}

class _SessionRecords extends StatelessWidget {
  const _SessionRecords({
    required this.records,
    required this.rootSource,
    required this.subagentNames,
    required this.isNarrow,
  });

  final List<AiUsageRecord> records;
  final String rootSource;
  final Map<String, String> subagentNames;
  final bool isNarrow;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    if (records.isEmpty) {
      return _UsageSurface(
        child: _UsageMessage(
          label: context.t(LocaleKeys.settingsUsageListEmpty),
        ),
      );
    }
    return _UsageSurface(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          if (!isNarrow) ...[
            const _SessionRecordTableHeader(),
            Divider(height: 1, color: colors.borderSubtle),
          ],
          for (var i = 0; i < records.length; i++) ...[
            _SessionRecordRow(
              record: records[i],
              callerLabel:
                  subagentNames[records[i].sessionId] ??
                  _sourceLabel(context, rootSource),
              isNarrow: isNarrow,
            ),
            if (i < records.length - 1)
              Divider(height: 1, color: colors.borderSubtle),
          ],
        ],
      ),
    );
  }
}

class _SessionRecordTableHeader extends StatelessWidget {
  const _SessionRecordTableHeader();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final style = typo.uiSmallSemibold.copyWith(color: colors.textMuted);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x3l,
        vertical: RevericSpacing.md,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              context.t(LocaleKeys.settingsUsageListColumnTime),
              style: style,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              context.t(LocaleKeys.settingsUsageSessionColumnCaller),
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              context.t(LocaleKeys.settingsUsageListColumnModel),
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 84,
            child: Text(
              context.t(LocaleKeys.settingsUsageListColumnInput),
              style: style,
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 84,
            child: Text(
              context.t(LocaleKeys.accountUsageCached),
              style: style,
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 84,
            child: Text(
              context.t(LocaleKeys.settingsUsageListColumnOutput),
              style: style,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionRecordRow extends StatelessWidget {
  const _SessionRecordRow({
    required this.record,
    required this.callerLabel,
    required this.isNarrow,
  });

  final AiUsageRecord record;
  final String callerLabel;
  final bool isNarrow;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x3l,
        vertical: RevericSpacing.md,
      ),
      child: isNarrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  callerLabel,
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: RevericSpacing.xxs),
                Text(
                  '${record.model} · ${_formatDateTime(record.createdAt)}',
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
                ),
                const SizedBox(height: RevericSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: _SessionRecordCardStat(
                        label: context.t(
                          LocaleKeys.settingsUsageListColumnInput,
                        ),
                        value: _formatTokens(record.inputTokens),
                      ),
                    ),
                    Expanded(
                      child: _SessionRecordCardStat(
                        label: context.t(LocaleKeys.accountUsageCached),
                        value: _formatTokens(record.cacheReadTokens),
                      ),
                    ),
                    Expanded(
                      child: _SessionRecordCardStat(
                        label: context.t(
                          LocaleKeys.settingsUsageListColumnOutput,
                        ),
                        value: _formatTokens(record.outputTokens),
                      ),
                    ),
                  ],
                ),
              ],
            )
          : Row(
              children: [
                SizedBox(
                  width: 130,
                  child: Text(
                    _formatDateTime(record.createdAt),
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    callerLabel,
                    style: typo.uiSmallSemibold.copyWith(
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    record.model,
                    style: typo.uiSmall.copyWith(color: colors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: 84,
                  child: Text(
                    _formatTokens(record.inputTokens),
                    style: typo.uiSmall.copyWith(color: colors.textSecondary),
                    textAlign: TextAlign.right,
                  ),
                ),
                SizedBox(
                  width: 84,
                  child: Text(
                    _formatTokens(record.cacheReadTokens),
                    style: typo.uiSmall.copyWith(color: colors.textSecondary),
                    textAlign: TextAlign.right,
                  ),
                ),
                SizedBox(
                  width: 84,
                  child: Text(
                    _formatTokens(record.outputTokens),
                    style: typo.uiSmall.copyWith(color: colors.textSecondary),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
    );
  }
}

class _SessionRecordCardStat extends StatelessWidget {
  const _SessionRecordCardStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: typo.uiTiny.copyWith(color: colors.textMuted)),
        const SizedBox(height: RevericSpacing.xxs),
        Text(
          value,
          style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.sm,
          vertical: RevericSpacing.xxs,
        ),
        decoration: BoxDecoration(
          color: _sourceColor(colors, mode).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(RevericRadius.full),
        ),
        child: Text(
          _sourceLabel(context, mode),
          style: typo.uiTinySemibold.copyWith(
            color: _sourceColor(colors, mode),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _UsageSurface extends StatelessWidget {
  const _UsageSurface({
    required this.child,
    this.padding = const EdgeInsets.all(RevericSpacing.x4l),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.borderSubtle),
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
      ),
      child: child,
    );
  }
}

class _UsageLoadingRows extends StatelessWidget {
  const _UsageLoadingRows();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: Column(
        children: List.generate(
          4,
          (index) => Padding(
            padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
            child: LinearProgressIndicator(
              minHeight: 8,
              color: colors.surfaceContainer,
              backgroundColor: colors.surfaceContainer,
            ),
          ),
        ),
      ),
    );
  }
}

class _UsageMessage extends StatelessWidget {
  const _UsageMessage({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: Center(
        child: Text(label, style: typo.ui.copyWith(color: colors.textMuted)),
      ),
    );
  }
}

String _sourceLabel(BuildContext context, String rawSource) {
  return context.t(switch (UsageSources.canonicalize(rawSource)) {
    UsageSources.chat => LocaleKeys.settingsUsageSourceChat,
    UsageSources.assistant => LocaleKeys.settingsUsageSourceAssistant,
    UsageSources.roleplay => LocaleKeys.settingsUsageSourceRoleplay,
    UsageSources.monologue => LocaleKeys.settingsUsageSourceMonologue,
    UsageSources.theater => LocaleKeys.settingsUsageSourceTheater,
    UsageSources.council => LocaleKeys.settingsUsageSourceCouncil,
    UsageSources.pluginTask => LocaleKeys.settingsUsageSourcePluginTask,
    _ => LocaleKeys.settingsUsageSourceOther,
  });
}

Color _sourceColor(RevericColors colors, String rawSource) {
  return switch (UsageSources.canonicalize(rawSource)) {
    UsageSources.chat => colors.accent,
    UsageSources.assistant => colors.accentWarm,
    UsageSources.roleplay => colors.warningText,
    _ => colors.textSubtle,
  };
}

String _formatTokens(int tokens) {
  if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
  if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(0)}K';
  return '$tokens';
}

String _formatDateTime(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '${value.year}-$month-$day $hour:$minute';
}

String _formatRunTime(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$month-$day $hour:$minute';
}
