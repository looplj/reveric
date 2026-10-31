// 职责: 共享用量统计视图 — Token 用量统计与可视化，桌面/移动端响应式自适应。
// 关联文件:
//   lib/shared/providers/settings_providers.dart
//   lib/shared/services/ai/usage_service.dart
//   lib/shared/providers/usage_query_providers.dart
//   lib/shared/database/app_database.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/hooks.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_segmented_control.dart';
import '../../components/reveric_select.dart';
import '../../database/app_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import '../../providers/settings_providers.dart';
import '../../providers/usage_query_providers.dart';
import '../../services/ai/usage_service.dart';
import '../../theme/theme.dart';
import 'usage_sessions_view.dart';

/// 窄屏阈值：低于此宽度切换为移动端单列布局。
const double _narrowBreakpoint = 600;

enum _UsageTab { overview, sessions }

/// Usage 统计视图（无 Scaffold）：承载平台特定的滚动内容，桌面/移动端响应式自适应。
class UsageView extends HookWidget {
  const UsageView({super.key, this.showHeader = true, this.initialSessionId});

  /// 是否渲染页内大标题与说明。桌面端为 true；移动端由 AppBar 承载标题，传 false。
  final bool showHeader;

  /// 非空时直接打开 Sessions tab 并下钻该会话。
  final String? initialSessionId;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final selectedTab = useState(
      initialSessionId == null ? _UsageTab.overview : _UsageTab.sessions,
    );
    useEffect(() {
      if (initialSessionId != null) {
        selectedTab.value = _UsageTab.sessions;
      }
      return null;
    }, [initialSessionId]);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < _narrowBreakpoint;
        return SingleChildScrollView(
          padding: EdgeInsets.all(
            isNarrow ? RevericSpacing.x3l : RevericSpacing.x4l,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showHeader) ...[
                Text(
                  context.t(LocaleKeys.settingsUsage),
                  style: typo.heading2.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: RevericSpacing.sm),
                Text(
                  context.t(LocaleKeys.settingsUsageDescription),
                  style: typo.ui.copyWith(color: colors.textMuted),
                ),
                const SizedBox(height: RevericSpacing.x4l),
              ],
              RevericSegmentedControl<_UsageTab>(
                height: isNarrow ? 38 : 34,
                selected: selectedTab.value,
                onChanged: (tab) => selectedTab.value = tab,
                segments: [
                  RevericSegment(
                    value: _UsageTab.overview,
                    icon: RevericIcons.bar_chart_outlined,
                    label: context.t(LocaleKeys.settingsUsageTabOverview),
                  ),
                  RevericSegment(
                    value: _UsageTab.sessions,
                    icon: RevericIcons.chat_outlined,
                    label: context.t(LocaleKeys.settingsUsageTabSessions),
                  ),
                ],
              ),
              const SizedBox(height: RevericSpacing.x4l),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: selectedTab.value == _UsageTab.overview
                    ? const _UsageOverviewView(
                        key: ValueKey(_UsageTab.overview),
                      )
                    : UsageSessionsView(
                        key: const ValueKey(_UsageTab.sessions),
                        isNarrow: isNarrow,
                        initialSessionId: initialSessionId,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UsageOverviewView extends HookConsumerWidget {
  const _UsageOverviewView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final aiSettings = ref.watch(aiSettingsProvider);
    final selectedProviderId = useState<String?>(null);
    final selectedModel = useState<String?>(null);
    final selectedSource = useState<String?>(null);
    final providerOptions = _usageProviderOptions(aiSettings);
    final effectiveProviderId =
        providerOptions.any((option) => option.id == selectedProviderId.value)
        ? selectedProviderId.value
        : null;
    final modelOptions = _usageModelOptions(
      aiSettings,
      providerId: effectiveProviderId,
    );
    final effectiveModel = modelOptions.contains(selectedModel.value)
        ? selectedModel.value
        : null;

    final now = useMemoized(DateTime.now, [
      effectiveProviderId,
      effectiveModel,
      selectedSource.value,
    ]);
    final todayStart = DateTime(now.year, now.month, now.day);
    final thisMonthStart = DateTime(now.year, now.month, 1);
    final startOfLastMonth = DateTime(now.year, now.month - 1, 1);
    final endOfLastMonth = thisMonthStart.subtract(const Duration(seconds: 1));
    final last30StartRaw = now.subtract(const Duration(days: 29));
    final last30Start = DateTime(
      last30StartRaw.year,
      last30StartRaw.month,
      last30StartRaw.day,
    );
    final activityStart = _activityStartDate(now);
    final todayAsync = ref.watch(
      usageSummaryProvider(
        UsageFilter(
          startDate: todayStart,
          endDate: now,
          providerId: effectiveProviderId,
          model: effectiveModel,
          source: selectedSource.value,
        ),
      ),
    );
    final monthAsync = ref.watch(
      usageSummaryProvider(
        UsageFilter(
          startDate: thisMonthStart,
          endDate: now,
          providerId: effectiveProviderId,
          model: effectiveModel,
          source: selectedSource.value,
        ),
      ),
    );
    final lastMonthAsync = ref.watch(
      usageSummaryProvider(
        UsageFilter(
          startDate: startOfLastMonth,
          endDate: endOfLastMonth,
          providerId: effectiveProviderId,
          model: effectiveModel,
          source: selectedSource.value,
        ),
      ),
    );
    final last30DaysAsync = ref.watch(
      dailyUsageProvider(
        UsageFilter(
          startDate: last30Start,
          endDate: now,
          providerId: effectiveProviderId,
          model: effectiveModel,
          source: selectedSource.value,
        ),
      ),
    );
    final activityAsync = ref.watch(
      dailyUsageProvider(
        UsageFilter(
          startDate: activityStart,
          endDate: now,
          providerId: effectiveProviderId,
          model: effectiveModel,
          source: selectedSource.value,
        ),
      ),
    );
    final sourceUsageAsync = ref.watch(
      usageBySourceProvider(
        UsageFilter(
          startDate: thisMonthStart,
          endDate: now,
          providerId: effectiveProviderId,
          model: effectiveModel,
        ),
      ),
    );
    final last30DaysBySourceAsync = ref.watch(
      dailyUsageBySourceProvider(
        UsageFilter(
          startDate: last30Start,
          endDate: now,
          providerId: effectiveProviderId,
          model: effectiveModel,
          source: selectedSource.value,
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < _narrowBreakpoint;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Activity heatmap
            _UsageHeatmap(
              activityAsync: activityAsync,
              colors: colors,
              typo: typo,
              isNarrow: isNarrow,
            ),
            const SizedBox(height: RevericSpacing.x4l),

            // Tokens section
            _TokenSectionHeader(
              controls: _UsageFilterControls(
                providerOptions: providerOptions,
                selectedProviderId: effectiveProviderId,
                modelOptions: modelOptions,
                selectedModel: effectiveModel,
                selectedSource: selectedSource.value,
                onProviderChanged: (providerId) {
                  selectedProviderId.value = providerId;
                  final nextModels = _usageModelOptions(
                    aiSettings,
                    providerId: providerId,
                  );
                  if (!nextModels.contains(selectedModel.value)) {
                    selectedModel.value = null;
                  }
                },
                onModelChanged: (model) => selectedModel.value = model,
                onSourceChanged: (source) => selectedSource.value = source,
              ),
              isNarrow: isNarrow,
            ),
            const SizedBox(height: RevericSpacing.lg),
            _buildTokenCards(
              context,
              todayAsync: todayAsync,
              monthAsync: monthAsync,
              lastMonthAsync: lastMonthAsync,
              colors: colors,
              typo: typo,
              isNarrow: isNarrow,
            ),
            const SizedBox(height: RevericSpacing.x4l),

            _SourceDistribution(
              sourceUsageAsync: sourceUsageAsync,
              selectedSource: selectedSource.value,
            ),
            const SizedBox(height: RevericSpacing.x4l),

            // Daily chart
            _UsageChartSection(
              last30DaysAsync: last30DaysAsync,
              last30DaysBySourceAsync: last30DaysBySourceAsync,
              colors: colors,
              typo: typo,
            ),
            const SizedBox(height: RevericSpacing.x4l),

            // Usage records list
            _UsageRecordList(
              filter: UsageFilter(
                providerId: effectiveProviderId,
                model: effectiveModel,
                source: selectedSource.value,
              ),
              isNarrow: isNarrow,
            ),
          ],
        );
      },
    );
  }

  Widget _buildTokenCards(
    BuildContext context, {
    required AsyncValue<UsageSummary> todayAsync,
    required AsyncValue<UsageSummary> monthAsync,
    required AsyncValue<UsageSummary> lastMonthAsync,
    required RevericColors colors,
    required RevericTypography typo,
    required bool isNarrow,
  }) {
    final todayCard = _StatCard(
      label: context.t(LocaleKeys.settingsUsageToday),
      valueAsync: todayAsync,
      formatValue: (summary) => _formatTokens(summary.totalTokens),
      subtitle: context.t(LocaleKeys.settingsUsageTokens),
      breakdownBuilder: (summary) =>
          _buildTokenBreakdown(context, summary, colors, typo),
      colors: colors,
      typo: typo,
    );
    final monthCard = _StatCard(
      label: context.t(LocaleKeys.settingsUsageThisMonth),
      valueAsync: monthAsync,
      formatValue: (summary) => _formatTokens(summary.totalTokens),
      subtitle: context.t(LocaleKeys.settingsUsageTokens),
      trend: _MonthTrend(
        monthAsync: monthAsync,
        lastMonthAsync: lastMonthAsync,
      ),
      breakdownBuilder: (summary) =>
          _buildTokenBreakdown(context, summary, colors, typo),
      colors: colors,
      typo: typo,
    );
    final requestsCard = _StatCard(
      label: context.t(LocaleKeys.settingsUsageRequestsToday),
      valueAsync: todayAsync,
      formatValue: (summary) => summary.requestCount.toString(),
      subtitle: context.t(LocaleKeys.settingsUsageApiCalls),
      compact: true,
      colors: colors,
      typo: typo,
    );
    final avgCard = _StatCard(
      label: context.t(LocaleKeys.settingsUsageAvgPerDay),
      valueAsync: monthAsync,
      formatValue: (summary) => _formatTokens(summary.averagePerDay.round()),
      subtitle: context.t(LocaleKeys.settingsUsageTokens),
      compact: true,
      colors: colors,
      typo: typo,
    );

    if (isNarrow) {
      // 单列：两张大卡纵向堆叠，两张紧凑卡并排。
      return Column(
        children: [
          todayCard,
          const SizedBox(height: RevericSpacing.lg),
          monthCard,
          const SizedBox(height: RevericSpacing.lg),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: requestsCard),
                const SizedBox(width: RevericSpacing.lg),
                Expanded(child: avgCard),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: todayCard),
              const SizedBox(width: RevericSpacing.lg),
              Expanded(child: monthCard),
            ],
          ),
        ),
        const SizedBox(height: RevericSpacing.lg),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: requestsCard),
              const SizedBox(width: RevericSpacing.lg),
              Expanded(child: avgCard),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTokenBreakdown(
    BuildContext context,
    UsageSummary summary,
    RevericColors colors,
    RevericTypography typo,
  ) {
    final lines = <Widget>[
      _BreakdownLine(
        color: colors.accent,
        label: context.t(LocaleKeys.settingsUsageInput),
        value: _formatTokens(summary.totalInputTokens),
        colors: colors,
        typo: typo,
      ),
      _BreakdownLine(
        color: colors.additionBorder,
        label: context.t(LocaleKeys.settingsUsageCacheRead),
        value: _formatTokens(summary.totalCacheReadTokens),
        colors: colors,
        typo: typo,
      ),
      _BreakdownLine(
        color: colors.accentWarm,
        label: context.t(LocaleKeys.settingsUsageCacheWrite),
        value: _formatTokens(summary.totalCacheWriteTokens),
        colors: colors,
        typo: typo,
      ),
      _BreakdownLine(
        color: colors.textMuted,
        label: context.t(LocaleKeys.settingsUsageOutput),
        value: _formatTokens(summary.totalOutputTokens),
        colors: colors,
        typo: typo,
      ),
      if (summary.totalReasoningTokens > 0)
        _BreakdownLine(
          color: colors.warningText,
          label: context.t(LocaleKeys.settingsUsageReasoning),
          value: _formatTokens(summary.totalReasoningTokens),
          colors: colors,
          typo: typo,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < lines.length; i++) ...[
          if (i > 0) const SizedBox(height: RevericSpacing.xxs),
          lines[i],
        ],
      ],
    );
  }
}

DateTime _activityStartDate(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final daysSinceSunday = today.weekday % DateTime.daysPerWeek;
  final currentWeekStart = today.subtract(Duration(days: daysSinceSunday));
  return currentWeekStart.subtract(
    const Duration(
      days: (_UsageHeatmap.desktopWeeks - 1) * DateTime.daysPerWeek,
    ),
  );
}

// ───────────────────────────────────────────────────────────── helpers ─────

String _formatTokens(int tokens) {
  if (tokens >= 1000000) {
    return '${(tokens / 1000000).toStringAsFixed(1)}M';
  }
  if (tokens >= 1000) {
    return '${(tokens / 1000).toStringAsFixed(0)}K';
  }
  return tokens.toString();
}

String _usageSourceLabel(BuildContext context, String rawSource) {
  return context.t(switch (UsageSources.canonicalize(rawSource)) {
    UsageSources.chat => LocaleKeys.settingsUsageSourceChat,
    UsageSources.assistant => LocaleKeys.settingsUsageSourceAssistant,
    UsageSources.roleplay => LocaleKeys.settingsUsageSourceRoleplay,
    UsageSources.monologue => LocaleKeys.settingsUsageSourceMonologue,
    UsageSources.theater => LocaleKeys.settingsUsageSourceTheater,
    UsageSources.council => LocaleKeys.settingsUsageSourceCouncil,
    UsageSources.plugin => LocaleKeys.settingsUsageSourcePlugin,
    _ => LocaleKeys.settingsUsageSourceOther,
  });
}

Color _usageSourceColor(RevericColors colors, String rawSource) {
  return switch (UsageSources.canonicalize(rawSource)) {
    UsageSources.chat => colors.accent,
    UsageSources.assistant => colors.accentWarm,
    UsageSources.roleplay => colors.warningText,
    _ => colors.textSubtle,
  };
}

List<AiProvider> _usageProviderOptions(AiSettings settings) {
  final allModels = _usageModelOptions(settings, providerId: null);
  return settings.allConfigs
      .where((provider) => provider.availableModels.any(allModels.contains))
      .toList(growable: false);
}

List<String> _usageModelOptions(AiSettings settings, {String? providerId}) {
  final models = <String>{};
  for (final provider in settings.allConfigs) {
    if (providerId != null && provider.id != providerId) {
      continue;
    }
    models.addAll(provider.availableModels);
  }
  final sorted = models.toList();
  sorted.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return sorted;
}

// ───────────────────────────────────────────────────────── components ─────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.colors,
    required this.typo,
  });

  final String label;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: typo.uiSemibold.copyWith(color: colors.textPrimary),
    );
  }
}

class _TokenSectionHeader extends StatelessWidget {
  const _TokenSectionHeader({required this.controls, required this.isNarrow});

  final _UsageFilterControls controls;
  final bool isNarrow;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final providerDropdown = RevericSelect<String?>(
      label: context.t(LocaleKeys.settingsUsageFilterProvider),
      value: controls.selectedProviderId,
      items: [
        RevericSelectItem<String?>(
          value: null,
          label: context.t(LocaleKeys.settingsUsageFilterAllProviders),
        ),
        for (final provider in controls.providerOptions)
          RevericSelectItem<String?>(
            value: provider.id,
            label: provider.displayName,
          ),
      ],
      onChanged: controls.onProviderChanged,
    );
    final modelDropdown = RevericSelect<String?>(
      label: context.t(LocaleKeys.settingsUsageFilterModel),
      value: controls.selectedModel,
      items: [
        RevericSelectItem<String?>(
          value: null,
          label: context.t(LocaleKeys.settingsUsageFilterAllModels),
        ),
        for (final model in controls.modelOptions)
          RevericSelectItem<String?>(value: model, label: model),
      ],
      onChanged: controls.onModelChanged,
    );
    final sourceDropdown = RevericSelect<String?>(
      label: context.t(LocaleKeys.settingsUsageFilterSource),
      value: controls.selectedSource,
      items: [
        RevericSelectItem<String?>(
          value: null,
          label: context.t(LocaleKeys.settingsUsageFilterAllSources),
        ),
        for (final source in UsageSources.values)
          RevericSelectItem<String?>(
            value: source,
            label: _usageSourceLabel(context, source),
          ),
      ],
      onChanged: controls.onSourceChanged,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          label: context.t(LocaleKeys.settingsUsageSectionTokens),
          colors: colors,
          typo: typo,
        ),
        const SizedBox(height: RevericSpacing.md),
        if (isNarrow) ...[
          providerDropdown,
          const SizedBox(height: RevericSpacing.md),
          modelDropdown,
          const SizedBox(height: RevericSpacing.md),
          sourceDropdown,
        ] else
          Wrap(
            spacing: RevericSpacing.lg,
            runSpacing: RevericSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              SizedBox(width: 220, child: providerDropdown),
              SizedBox(width: 280, child: modelDropdown),
              SizedBox(width: 180, child: sourceDropdown),
            ],
          ),
      ],
    );
  }
}

class _UsageFilterControls {
  const _UsageFilterControls({
    required this.providerOptions,
    required this.selectedProviderId,
    required this.modelOptions,
    required this.selectedModel,
    required this.selectedSource,
    required this.onProviderChanged,
    required this.onModelChanged,
    required this.onSourceChanged,
  });

  final List<AiProvider> providerOptions;
  final String? selectedProviderId;
  final List<String> modelOptions;
  final String? selectedModel;
  final String? selectedSource;
  final ValueChanged<String?> onProviderChanged;
  final ValueChanged<String?> onModelChanged;
  final ValueChanged<String?> onSourceChanged;
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({
    required this.colors,
    required this.child,
    this.padding = const EdgeInsets.all(RevericSpacing.x4l),
  });

  final RevericColors colors;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: child,
    );
  }
}

/// 加载占位骨架
class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.colors, required this.height, this.width});

  final RevericColors colors;
  final double height;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
      ),
    );
  }
}

/// 通用统计卡片
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.valueAsync,
    required this.formatValue,
    required this.subtitle,
    required this.colors,
    required this.typo,
    this.trend,
    this.breakdownBuilder,
    this.compact = false,
  });

  final String label;
  final AsyncValue<UsageSummary> valueAsync;
  final String Function(UsageSummary) formatValue;
  final String subtitle;
  final Widget? trend;
  final Widget Function(UsageSummary)? breakdownBuilder;
  final bool compact;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    final padding = compact
        ? const EdgeInsets.all(RevericSpacing.x3l)
        : const EdgeInsets.all(RevericSpacing.x4l);

    return _SurfaceCard(
      colors: colors,
      padding: padding,
      child: valueAsync.when(
        data: (summary) => _buildContent(summary),
        loading: _buildLoading,
        error: (_, _) => _buildError(),
      ),
    );
  }

  Widget _buildContent(UsageSummary summary) {
    final breakdown = breakdownBuilder?.call(summary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: typo.uiSmall.copyWith(color: colors.textMuted)),
        const SizedBox(height: RevericSpacing.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              formatValue(summary),
              style: typo.heading2.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(width: RevericSpacing.sm),
            Flexible(
              child: Text(
                subtitle,
                style: typo.uiSmall.copyWith(color: colors.textSubtle),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (trend != null) ...[
          const SizedBox(height: RevericSpacing.sm),
          trend!,
        ],
        if (breakdown != null) ...[
          const SizedBox(height: RevericSpacing.lg),
          Divider(height: 1, color: colors.borderSubtle),
          const SizedBox(height: RevericSpacing.md),
          breakdown,
        ],
      ],
    );
  }

  Widget _buildLoading() {
    final hasBreakdown = breakdownBuilder != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Skeleton(colors: colors, height: 12, width: 80),
        const SizedBox(height: RevericSpacing.sm),
        _Skeleton(colors: colors, height: 26, width: 100),
        if (trend != null) ...[
          const SizedBox(height: RevericSpacing.sm),
          _Skeleton(colors: colors, height: 12, width: 120),
        ],
        if (hasBreakdown) ...[
          const SizedBox(height: RevericSpacing.lg),
          _Skeleton(colors: colors, height: 12),
          const SizedBox(height: RevericSpacing.xs),
          _Skeleton(colors: colors, height: 12),
          const SizedBox(height: RevericSpacing.xs),
          _Skeleton(colors: colors, height: 12, width: 140),
        ],
      ],
    );
  }

  Widget _buildError() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: typo.uiSmall.copyWith(color: colors.textMuted)),
        const SizedBox(height: RevericSpacing.sm),
        Text('-', style: typo.heading2.copyWith(color: colors.textMuted)),
      ],
    );
  }
}

/// 「较上月 ±X%」环比趋势
class _MonthTrend extends StatelessWidget {
  const _MonthTrend({required this.monthAsync, required this.lastMonthAsync});

  final AsyncValue<UsageSummary> monthAsync;
  final AsyncValue<UsageSummary> lastMonthAsync;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final current = monthAsync.asData?.value.totalTokens;
    final previous = lastMonthAsync.asData?.value.totalTokens;

    // 任一未就绪 → 占位（仍占位避免布局抖动）
    if (current == null || previous == null) {
      return SizedBox(
        height: 16,
        child: _Skeleton(colors: colors, height: 12, width: 120),
      );
    }

    final ({String icon, Color color, String text}) display;
    if (previous == 0 && current == 0) {
      display = (
        icon: '',
        color: colors.textSubtle,
        text: context.t(LocaleKeys.settingsUsageVsLastMonthNoData),
      );
    } else if (previous == 0) {
      // 上月为零，无法计算百分比，但本月有量 → 显示「new」语义
      display = (
        icon: RevericIcons.trending_up,
        color: colors.additionBorder,
        text: context.t(LocaleKeys.settingsUsageVsLastMonthNoData),
      );
    } else {
      final delta = (current - previous) / previous * 100;
      if (delta.abs() < 0.5) {
        display = (
          icon: '',
          color: colors.textMuted,
          text: context.t(LocaleKeys.settingsUsageVsLastMonthFlat),
        );
      } else {
        final isUp = delta > 0;
        final sign = isUp ? '+' : '−';
        final formatted = '$sign${delta.abs().toStringAsFixed(1)}%';
        display = (
          icon: isUp ? RevericIcons.trending_up : RevericIcons.trending_down,
          color: isUp ? colors.warningText : colors.additionBorder,
          text: context.t(
            LocaleKeys.settingsUsageVsLastMonth,
            namedArgs: {'delta': formatted},
          ),
        );
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (display.icon.isNotEmpty) ...[
          RevericIcon(display.icon, size: 12, color: display.color),
          const SizedBox(width: RevericSpacing.xxs),
        ],
        Flexible(
          child: Text(
            display.text,
            style: typo.uiTiny.copyWith(color: display.color),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// 统一的 breakdown 行（dot · label · value 右对齐）
class _BreakdownLine extends StatelessWidget {
  const _BreakdownLine({
    required this.color,
    required this.label,
    required this.value,
    required this.colors,
    required this.typo,
  });

  final Color color;
  final String label;
  final String value;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: RevericSpacing.xs),
        Expanded(
          child: Text(
            label,
            style: typo.uiSmall.copyWith(color: colors.textMuted),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          value,
          style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

// ───────────────────────────────────────────── activity heatmap ───────────

class _UsageHeatmap extends StatelessWidget {
  const _UsageHeatmap({
    required this.activityAsync,
    required this.colors,
    required this.typo,
    required this.isNarrow,
  });

  static const desktopWeeks = 26;
  static const _narrowWeeks = 13;

  final AsyncValue<List<DailyUsage>> activityAsync;
  final RevericColors colors;
  final RevericTypography typo;
  final bool isNarrow;

  @override
  Widget build(BuildContext context) {
    final weeks = isNarrow ? _narrowWeeks : desktopWeeks;

    return SizedBox(
      width: double.infinity,
      child: _SurfaceCard(
        colors: colors,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.t(LocaleKeys.settingsUsageActivity),
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.x2l),
            activityAsync.when(
              data: (data) =>
                  _ActivityGrid(data: data, weeks: weeks, colors: colors),
              loading: () =>
                  _ActivityGridSkeleton(weeks: weeks, colors: colors),
              error: (_, _) => Text(
                context.t(LocaleKeys.settingsUsageFailedToLoad),
                style: typo.ui.copyWith(color: colors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityGrid extends StatelessWidget {
  const _ActivityGrid({
    required this.data,
    required this.weeks,
    required this.colors,
  });

  final List<DailyUsage> data;
  final int weeks;
  final RevericColors colors;

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final gridEnd = today.add(
      Duration(
        days: DateTime.daysPerWeek - 1 - today.weekday % DateTime.daysPerWeek,
      ),
    );
    final gridStart = gridEnd.subtract(
      Duration(days: weeks * DateTime.daysPerWeek - 1),
    );
    final usageByDate = {for (final usage in data) _dateKey(usage.date): usage};
    final maxTokens = data.fold<int>(0, (max, usage) {
      return usage.totalTokens > max ? usage.totalTokens : max;
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var dayOfWeek = 0; dayOfWeek < DateTime.daysPerWeek; dayOfWeek++)
          Padding(
            padding: EdgeInsets.only(
              bottom: dayOfWeek == DateTime.daysPerWeek - 1
                  ? 0
                  : RevericSpacing.xs,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var week = 0; week < weeks; week++)
                  _ActivityCell(
                    date: gridStart.add(
                      Duration(days: week * DateTime.daysPerWeek + dayOfWeek),
                    ),
                    usage:
                        usageByDate[_dateKey(
                          gridStart.add(
                            Duration(
                              days: week * DateTime.daysPerWeek + dayOfWeek,
                            ),
                          ),
                        )],
                    maxTokens: maxTokens,
                    isFuture: gridStart
                        .add(
                          Duration(
                            days: week * DateTime.daysPerWeek + dayOfWeek,
                          ),
                        )
                        .isAfter(today),
                    colors: colors,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ActivityCell extends StatelessWidget {
  const _ActivityCell({
    required this.date,
    required this.usage,
    required this.maxTokens,
    required this.isFuture,
    required this.colors,
  });

  final DateTime date;
  final DailyUsage? usage;
  final int maxTokens;
  final bool isFuture;
  final RevericColors colors;

  @override
  Widget build(BuildContext context) {
    final totalTokens = usage?.totalTokens ?? 0;
    final color = _activityColor(totalTokens);
    final message = [
      MaterialLocalizations.of(context).formatMediumDate(date),
      '${_formatTokens(totalTokens)} ${context.t(LocaleKeys.settingsUsageTokens)}',
      '${usage?.requestCount ?? 0} ${context.t(LocaleKeys.settingsUsageApiCalls)}',
    ].join('\n');

    return Tooltip(
      message: message,
      child: Container(
        width: RevericSpacing.lg,
        height: RevericSpacing.lg,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(RevericRadius.small),
        ),
      ),
    );
  }

  Color _activityColor(int totalTokens) {
    if (isFuture || totalTokens == 0 || maxTokens == 0) {
      return colors.surfaceContainer;
    }

    final level = ((totalTokens / maxTokens) * 4).ceil();
    return Color.lerp(colors.surfaceContainer, colors.accent, switch (level) {
      1 => 0.25,
      2 => 0.5,
      3 => 0.75,
      _ => 1,
    })!;
  }
}

class _ActivityGridSkeleton extends StatelessWidget {
  const _ActivityGridSkeleton({required this.weeks, required this.colors});

  final int weeks;
  final RevericColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var dayOfWeek = 0; dayOfWeek < DateTime.daysPerWeek; dayOfWeek++)
          Padding(
            padding: EdgeInsets.only(
              bottom: dayOfWeek == DateTime.daysPerWeek - 1
                  ? 0
                  : RevericSpacing.xs,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var week = 0; week < weeks; week++)
                  Container(
                    width: RevericSpacing.lg,
                    height: RevericSpacing.lg,
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      borderRadius: BorderRadius.circular(RevericRadius.small),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

int _dateKey(DateTime date) => date.year * 10000 + date.month * 100 + date.day;

// ───────────────────────────────────────── source distribution components ─

class _SourceDistribution extends StatelessWidget {
  const _SourceDistribution({
    required this.sourceUsageAsync,
    required this.selectedSource,
  });

  final AsyncValue<List<UsageSourceSummary>> sourceUsageAsync;
  final String? selectedSource;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _SectionHeader(
                label: context.t(LocaleKeys.settingsUsageSourceDistribution),
                colors: colors,
                typo: typo,
              ),
            ),
            sourceUsageAsync.when(
              data: (sources) => Text(
                context.t(
                  LocaleKeys.settingsUsageSourceDistributionPeriod,
                  namedArgs: {
                    'tokens': _formatTokens(
                      sources.fold<int>(
                        0,
                        (sum, item) => sum + item.totalTokens,
                      ),
                    ),
                  },
                ),
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.md),
        _SurfaceCard(
          colors: colors,
          child: sourceUsageAsync.when(
            data: (sources) => _SourceDistributionContent(
              sources: sources,
              selectedSource: selectedSource,
            ),
            loading: () => _ChartSkeleton(colors: colors),
            error: (_, _) => _UsageInlineMessage(
              label: context.t(LocaleKeys.settingsUsageFailedToLoad),
            ),
          ),
        ),
      ],
    );
  }
}

class _SourceDistributionContent extends StatelessWidget {
  const _SourceDistributionContent({
    required this.sources,
    required this.selectedSource,
  });

  final List<UsageSourceSummary> sources;
  final String? selectedSource;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final total = sources.fold<int>(0, (sum, item) => sum + item.totalTokens);
    if (sources.isEmpty || total == 0) {
      return _UsageInlineMessage(
        label: context.t(LocaleKeys.settingsUsageNoData),
      );
    }
    final maxTokens = sources.fold<int>(
      0,
      (max, item) => item.totalTokens > max ? item.totalTokens : max,
    );
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(RevericRadius.full),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                for (final item in sources)
                  Expanded(
                    flex: item.totalTokens,
                    child: ColoredBox(
                      color: _usageSourceColor(colors, item.source).withValues(
                        alpha:
                            selectedSource == null ||
                                selectedSource == item.source
                            ? 1
                            : 0.25,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: RevericSpacing.x2l),
        for (var i = 0; i < sources.length; i++) ...[
          Opacity(
            opacity:
                selectedSource == null || selectedSource == sources[i].source
                ? 1
                : 0.35,
            child: _SourceDistributionRow(
              source: sources[i],
              total: total,
              maxTokens: maxTokens,
              colors: colors,
              typo: typo,
            ),
          ),
          if (i < sources.length - 1) const SizedBox(height: RevericSpacing.md),
        ],
      ],
    );
  }
}

class _SourceDistributionRow extends StatelessWidget {
  const _SourceDistributionRow({
    required this.source,
    required this.total,
    required this.maxTokens,
    required this.colors,
    required this.typo,
  });

  final UsageSourceSummary source;
  final int total;
  final int maxTokens;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    final color = _usageSourceColor(colors, source.source);
    return Row(
      children: [
        SizedBox(
          width: 112,
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Text(
                  _usageSourceLabel(context, source.source),
                  style: typo.uiSmall.copyWith(color: colors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: RevericSpacing.md),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(RevericRadius.full),
            child: LinearProgressIndicator(
              minHeight: 5,
              value: maxTokens == 0 ? 0 : source.totalTokens / maxTokens,
              color: color,
              backgroundColor: colors.surfaceContainer,
            ),
          ),
        ),
        const SizedBox(width: RevericSpacing.md),
        SizedBox(
          width: 52,
          child: Text(
            _formatTokens(source.totalTokens),
            style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
            textAlign: TextAlign.right,
          ),
        ),
        SizedBox(
          width: 50,
          child: Text(
            '${(source.totalTokens / total * 100).toStringAsFixed(1)}%',
            style: typo.uiSmall.copyWith(color: colors.textMuted),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class _UsageInlineMessage extends StatelessWidget {
  const _UsageInlineMessage({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return SizedBox(
      height: 96,
      child: Center(
        child: Text(label, style: typo.ui.copyWith(color: colors.textMuted)),
      ),
    );
  }
}

// ───────────────────────────────────────────── daily chart components ─────

enum _UsageChartMode { tokenType, feature }

class _UsageChartSection extends HookWidget {
  const _UsageChartSection({
    required this.last30DaysAsync,
    required this.last30DaysBySourceAsync,
    required this.colors,
    required this.typo,
  });

  final AsyncValue<List<DailyUsage>> last30DaysAsync;
  final AsyncValue<List<DailySourceUsage>> last30DaysBySourceAsync;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    final mode = useState(_UsageChartMode.tokenType);
    return _SurfaceCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row
          Wrap(
            spacing: RevericSpacing.lg,
            runSpacing: RevericSpacing.md,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 180,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t(LocaleKeys.settingsUsageDailyTokenTitle),
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.t(LocaleKeys.settingsUsageLast30Days),
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 260,
                child: RevericSegmentedControl<_UsageChartMode>(
                  height: 38,
                  selected: mode.value,
                  onChanged: (value) => mode.value = value,
                  segments: [
                    RevericSegment(
                      value: _UsageChartMode.tokenType,
                      label: context.t(
                        LocaleKeys.settingsUsageChartByTokenType,
                      ),
                    ),
                    RevericSegment(
                      value: _UsageChartMode.feature,
                      label: context.t(LocaleKeys.settingsUsageChartByFeature),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.md),
          // Legend (wraps on narrow widths)
          Wrap(
            spacing: RevericSpacing.lg,
            runSpacing: RevericSpacing.xs,
            children: mode.value == _UsageChartMode.tokenType
                ? [
                    _LegendItem(
                      color: colors.accent,
                      label: context.t(LocaleKeys.settingsUsageInput),
                    ),
                    _LegendItem(
                      color: colors.additionBorder,
                      label: context.t(LocaleKeys.settingsUsageCacheRead),
                    ),
                    _LegendItem(
                      color: colors.accentWarm,
                      label: context.t(LocaleKeys.settingsUsageCacheWrite),
                    ),
                    _LegendItem(
                      color: colors.textMuted,
                      label: context.t(LocaleKeys.settingsUsageOutput),
                    ),
                  ]
                : [
                    for (final source in UsageSources.values)
                      _LegendItem(
                        color: _usageSourceColor(colors, source),
                        label: _usageSourceLabel(context, source),
                      ),
                  ],
          ),
          const SizedBox(height: RevericSpacing.x2l),
          SizedBox(
            height: 200,
            child: mode.value == _UsageChartMode.tokenType
                ? last30DaysAsync.when(
                    data: (dailyUsage) => _DailyBarChart(
                      data: _fillMissingDates(dailyUsage),
                      colors: colors,
                      typo: typo,
                    ),
                    loading: () => _ChartSkeleton(colors: colors),
                    error: (_, _) => _chartError(context),
                  )
                : last30DaysBySourceAsync.when(
                    data: (dailyUsage) => _DailySourceBarChart(
                      data: _fillMissingSourceDates(dailyUsage),
                      colors: colors,
                      typo: typo,
                    ),
                    loading: () => _ChartSkeleton(colors: colors),
                    error: (_, _) => _chartError(context),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _chartError(BuildContext context) => Center(
    child: Text(
      context.t(LocaleKeys.settingsUsageFailedToLoad),
      style: typo.ui.copyWith(color: colors.textMuted),
    ),
  );

  List<DailyUsage> _fillMissingDates(List<DailyUsage> data) {
    final result = <DailyUsage>[];
    final now = DateTime.now();

    for (var i = 29; i >= 0; i--) {
      final date = now.subtract(Duration(days: i));
      final existing = data.where(
        (d) =>
            d.year == date.year && d.month == date.month && d.day == date.day,
      );

      if (existing.isNotEmpty) {
        result.add(existing.first);
      } else {
        result.add(
          DailyUsage(
            date: date,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            totalTokens: 0,
            requestCount: 0,
          ),
        );
      }
    }

    return result;
  }

  List<DailySourceUsage> _fillMissingSourceDates(List<DailySourceUsage> data) {
    final byDate = {for (final item in data) _dateKey(item.date): item};
    final now = DateTime.now();
    return [
      for (var i = 29; i >= 0; i--)
        byDate[_dateKey(now.subtract(Duration(days: i)))] ??
            DailySourceUsage(
              date: now.subtract(Duration(days: i)),
              tokensBySource: const {},
            ),
    ];
  }
}

class _DailySourceBarChart extends StatelessWidget {
  const _DailySourceBarChart({
    required this.data,
    required this.colors,
    required this.typo,
  });

  final List<DailySourceUsage> data;
  final RevericColors colors;
  final RevericTypography typo;

  static const double _chartHeight = 180;

  @override
  Widget build(BuildContext context) {
    final maxTokens = data.fold<int>(0, (max, item) {
      final total = item.tokensBySource.values.fold<int>(
        0,
        (sum, value) => sum + value,
      );
      return total > max ? total : max;
    });
    if (maxTokens == 0) {
      return Center(
        child: Text(
          context.t(LocaleKeys.settingsUsageNoData),
          style: typo.ui.copyWith(color: colors.textMuted),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(painter: _GridPainter(color: colors.borderSubtle)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final item in data)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: _SourceStackedBar(
                      data: item,
                      maxTokens: maxTokens,
                      chartHeight: _chartHeight,
                      colors: colors,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SourceStackedBar extends StatelessWidget {
  const _SourceStackedBar({
    required this.data,
    required this.maxTokens,
    required this.chartHeight,
    required this.colors,
  });

  final DailySourceUsage data;
  final int maxTokens;
  final double chartHeight;
  final RevericColors colors;

  @override
  Widget build(BuildContext context) {
    final segments = <({String source, int value})>[
      for (final source in [...UsageSources.values, 'other'])
        (source: source, value: data.tokensFor(source)),
    ].where((item) => item.value > 0).toList(growable: false);
    if (segments.isEmpty) return const SizedBox.shrink();
    final total = segments.fold<int>(0, (sum, item) => sum + item.value);
    final tooltip = [
      '${data.date.month}/${data.date.day}: ${_formatTokens(total)} ${context.t(LocaleKeys.settingsUsageTokens)}',
      for (final item in segments)
        '${_usageSourceLabel(context, item.source)}: ${_formatTokens(item.value)}',
    ].join('\n');
    return Tooltip(
      message: tooltip,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < segments.length; i++)
            Container(
              width: double.infinity,
              height: segments[i].value / maxTokens * chartHeight,
              decoration: BoxDecoration(
                color: _usageSourceColor(colors, segments[i].source),
                borderRadius: BorderRadius.vertical(
                  top: i == 0 ? const Radius.circular(2) : Radius.zero,
                  bottom: i == segments.length - 1
                      ? const Radius.circular(2)
                      : Radius.zero,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChartSkeleton extends StatelessWidget {
  const _ChartSkeleton({required this.colors});

  final RevericColors colors;

  @override
  Widget build(BuildContext context) {
    // 30 个高度递变的占位柱，给出图表节奏感
    final heights = List<double>.generate(30, (i) {
      final v = ((i * 37) % 100) / 100; // 伪随机、稳定
      return 30 + v * 140;
    });
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: heights
          .map(
            (h) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Container(
                  height: h,
                  decoration: BoxDecoration(
                    color: colors.surfaceContainer,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final typo = RevericTheme.typographyOf(context);
    final colors = RevericTheme.colorsOf(context);

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
      ],
    );
  }
}

/// 每日用量柱状图（带网格线）
class _DailyBarChart extends StatelessWidget {
  const _DailyBarChart({
    required this.data,
    required this.colors,
    required this.typo,
  });

  final List<DailyUsage> data;
  final RevericColors colors;
  final RevericTypography typo;

  static const double _chartHeight = 180;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty || data.every((d) => d.totalTokens == 0)) {
      return Center(
        child: Text(
          context.t(LocaleKeys.settingsUsageNoData),
          style: typo.ui.copyWith(color: colors.textMuted),
        ),
      );
    }

    final maxTokens = data.fold<int>(0, (max, d) {
      final stackedTokens = _stackedTokens(d);
      return stackedTokens > max ? stackedTokens : max;
    });
    final tokensLabel = context.t(LocaleKeys.settingsUsageTokens);

    return Stack(
      children: [
        // Gridlines
        Positioned.fill(
          child: CustomPaint(painter: _GridPainter(color: colors.borderSubtle)),
        ),
        // Bars
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: data
                .map(
                  (d) => Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1.5),
                      child: _StackedBar(
                        data: d,
                        maxTokens: maxTokens,
                        chartHeight: _chartHeight,
                        colors: colors,
                        tooltip: _tooltipMessage(context, d, tokensLabel),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  String _tooltipMessage(
    BuildContext context,
    DailyUsage data,
    String tokensLabel,
  ) {
    return [
      '${data.month}/${data.day}: ${_formatNumber(data.totalTokens)} $tokensLabel',
      '${context.t(LocaleKeys.settingsUsageInput)}: ${_formatNumber(data.inputTokens)}',
      '${context.t(LocaleKeys.settingsUsageCacheRead)}: ${_formatNumber(data.cacheReadTokens)}',
      '${context.t(LocaleKeys.settingsUsageCacheWrite)}: ${_formatNumber(data.cacheWriteTokens)}',
      '${context.t(LocaleKeys.settingsUsageOutput)}: ${_formatNumber(data.outputTokens)}',
      '${context.t(LocaleKeys.settingsUsageReasoning)}: ${_formatNumber(data.reasoningTokens)}',
    ].join('\n');
  }

  int _stackedTokens(DailyUsage data) {
    return data.inputTokens +
        data.cacheReadTokens +
        data.cacheWriteTokens +
        data.outputTokens;
  }

  String _formatNumber(int num) {
    if (num >= 1000000) {
      return '${(num / 1000000).toStringAsFixed(1)}M';
    }
    if (num >= 1000) {
      return '${(num / 1000).toStringAsFixed(1)}K';
    }
    return num.toString();
  }
}

class _StackedBar extends StatelessWidget {
  const _StackedBar({
    required this.data,
    required this.maxTokens,
    required this.chartHeight,
    required this.colors,
    required this.tooltip,
  });

  final DailyUsage data;
  final int maxTokens;
  final double chartHeight;
  final RevericColors colors;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final scaled = <({int value, Color color})>[
      (value: data.inputTokens, color: colors.accent),
      (value: data.cacheReadTokens, color: colors.additionBorder),
      (value: data.cacheWriteTokens, color: colors.accentWarm),
      (value: data.outputTokens, color: colors.textMuted),
    ].where((s) => s.value > 0).toList();

    if (scaled.isEmpty || maxTokens <= 0) {
      return const SizedBox.shrink();
    }

    return Tooltip(
      message: tooltip,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < scaled.length; i++)
            Container(
              width: double.infinity,
              height: (scaled[i].value / maxTokens) * chartHeight,
              decoration: BoxDecoration(
                color: scaled[i].color,
                borderRadius: BorderRadius.vertical(
                  top: i == 0 ? const Radius.circular(2) : Radius.zero,
                  bottom: i == scaled.length - 1
                      ? const Radius.circular(2)
                      : Radius.zero,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────── usage records list ──────

class _UsageRecordList extends HookConsumerWidget {
  const _UsageRecordList({required this.filter, required this.isNarrow});

  final UsageFilter filter;
  final bool isNarrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final currentPage = useState(0);

    // Reset page when filter changes
    useEffect(() {
      currentPage.value = 0;
      return null;
    }, [filter]);

    final countAsync = ref.watch(usageRecordCountProvider(filter));
    final recordsAsync = ref.watch(
      usageRecordsPageProvider(filter, currentPage.value),
    );

    final totalCount = countAsync.asData?.value ?? 0;
    const pageSize = 10;
    final totalPages = totalCount > 0 ? (totalCount / pageSize).ceil() : 1;
    final aiSettings = ref.watch(aiSettingsProvider);

    String providerNameOf(String providerId) =>
        aiSettings.findConfigById(providerId)?.displayName ?? providerId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          label: context.t(LocaleKeys.settingsUsageListTitle),
          colors: colors,
          typo: typo,
        ),
        const SizedBox(height: RevericSpacing.lg),
        _SurfaceCard(
          colors: colors,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              // Table header (wide only — narrow cards are self-describing)
              if (!isNarrow) ...[
                _RecordTableHeader(colors: colors, typo: typo),
                Divider(height: 1, color: colors.borderSubtle),
              ],
              // Table / card body
              recordsAsync.when(
                data: (records) => records.isEmpty
                    ? _RecordEmpty(colors: colors, typo: typo)
                    : Column(
                        children: [
                          for (final record in records) ...[
                            if (isNarrow)
                              _RecordCard(
                                record: record,
                                providerName: providerNameOf(record.providerId),
                                colors: colors,
                                typo: typo,
                              )
                            else
                              _RecordTableRow(
                                record: record,
                                providerName: providerNameOf(record.providerId),
                                colors: colors,
                                typo: typo,
                              ),
                            Divider(height: 1, color: colors.borderSubtle),
                          ],
                        ],
                      ),
                loading: () => _RecordLoading(colors: colors),
                error: (_, _) => _RecordError(colors: colors, typo: typo),
              ),
              // Pagination footer
              if (totalCount > 0) ...[
                Divider(height: 1, color: colors.borderSubtle),
                _RecordPagination(
                  currentPage: currentPage.value,
                  totalPages: totalPages,
                  onPageChanged: (page) => currentPage.value = page,
                  colors: colors,
                  typo: typo,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _RecordTableHeader extends StatelessWidget {
  const _RecordTableHeader({required this.colors, required this.typo});

  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
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
              style: typo.uiSmallSemibold.copyWith(color: colors.textMuted),
            ),
          ),
          SizedBox(
            width: 120,
            child: Text(
              context.t(LocaleKeys.settingsUsageListColumnProvider),
              style: typo.uiSmallSemibold.copyWith(color: colors.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              context.t(LocaleKeys.settingsUsageListColumnModel),
              style: typo.uiSmallSemibold.copyWith(color: colors.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 70,
            child: Text(
              context.t(LocaleKeys.settingsUsageListColumnInput),
              style: typo.uiSmallSemibold.copyWith(color: colors.textMuted),
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              context.t(LocaleKeys.accountUsageCached),
              style: typo.uiSmallSemibold.copyWith(color: colors.textMuted),
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 70,
            child: Text(
              context.t(LocaleKeys.settingsUsageListColumnOutput),
              style: typo.uiSmallSemibold.copyWith(color: colors.textMuted),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordTableRow extends StatelessWidget {
  const _RecordTableRow({
    required this.record,
    required this.providerName,
    required this.colors,
    required this.typo,
  });

  final AiUsageRecord record;
  final String providerName;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x3l,
        vertical: RevericSpacing.sm,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              _formatDateTime(record.createdAt),
              style: typo.uiSmall.copyWith(color: colors.textSecondary),
            ),
          ),
          SizedBox(
            width: 120,
            child: Text(
              providerName,
              style: typo.uiSmall.copyWith(color: colors.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              record.model,
              style: typo.uiSmall.copyWith(color: colors.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 70,
            child: Text(
              _formatTokens(record.inputTokens),
              style: typo.uiSmall.copyWith(color: colors.textSecondary),
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              _formatTokens(record.cacheReadTokens),
              style: typo.uiSmall.copyWith(color: colors.textSecondary),
              textAlign: TextAlign.right,
            ),
          ),
          SizedBox(
            width: 70,
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

/// 移动端单条用量记录卡：model + provider·time 在上，input/cache/output 在下。
class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.record,
    required this.providerName,
    required this.colors,
    required this.typo,
  });

  final AiUsageRecord record;
  final String providerName;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x3l,
        vertical: RevericSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            record.model,
            style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: RevericSpacing.xxs),
          Text(
            '$providerName · ${_formatDateTime(record.createdAt)}',
            style: typo.uiTiny.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _RecordCardInputStat(
                  record: record,
                  colors: colors,
                  typo: typo,
                ),
              ),
              Expanded(
                child: _RecordCardStat(
                  label: context.t(LocaleKeys.accountUsageCached),
                  value: _formatTokens(record.cacheReadTokens),
                  colors: colors,
                  typo: typo,
                ),
              ),
              Expanded(
                child: _RecordCardStat(
                  label: context.t(LocaleKeys.settingsUsageListColumnOutput),
                  value: _formatTokens(record.outputTokens),
                  colors: colors,
                  typo: typo,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecordCardInputStat extends StatelessWidget {
  const _RecordCardInputStat({
    required this.record,
    required this.colors,
    required this.typo,
  });

  final AiUsageRecord record;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.settingsUsageListColumnInput),
          style: typo.uiTiny.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: 2),
        Text(
          _formatTokens(record.inputTokens),
          style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _RecordCardStat extends StatelessWidget {
  const _RecordCardStat({
    required this.label,
    required this.value,
    required this.colors,
    required this.typo,
  });

  final String label;
  final String value;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: typo.uiTiny.copyWith(color: colors.textMuted)),
        const SizedBox(height: 2),
        Text(
          value,
          style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _RecordEmpty extends StatelessWidget {
  const _RecordEmpty({required this.colors, required this.typo});

  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: Center(
        child: Text(
          context.t(LocaleKeys.settingsUsageListEmpty),
          style: typo.ui.copyWith(color: colors.textMuted),
        ),
      ),
    );
  }
}

class _RecordLoading extends StatelessWidget {
  const _RecordLoading({required this.colors});

  final RevericColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.x3l),
      child: Column(
        children: List.generate(
          5,
          (i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xs),
            child: _Skeleton(colors: colors, height: 16),
          ),
        ),
      ),
    );
  }
}

class _RecordError extends StatelessWidget {
  const _RecordError({required this.colors, required this.typo});

  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: Center(
        child: Text(
          context.t(LocaleKeys.settingsUsageFailedToLoad),
          style: typo.ui.copyWith(color: colors.textMuted),
        ),
      ),
    );
  }
}

class _RecordPagination extends StatelessWidget {
  const _RecordPagination({
    required this.currentPage,
    required this.totalPages,
    required this.onPageChanged,
    required this.colors,
    required this.typo,
  });

  final int currentPage;
  final int totalPages;
  final ValueChanged<int> onPageChanged;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x3l,
        vertical: RevericSpacing.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton.icon(
            onPressed: currentPage > 0
                ? () => onPageChanged(currentPage - 1)
                : null,
            icon: RevericIcon(
              RevericIcons.chevron_left,
              size: 14,
              color: currentPage > 0 ? colors.textSecondary : colors.textSubtle,
            ),
            label: Text(
              context.t(LocaleKeys.settingsUsageListPrev),
              style: typo.uiSmall.copyWith(
                color: currentPage > 0
                    ? colors.textSecondary
                    : colors.textSubtle,
              ),
            ),
          ),
          Text(
            context.t(
              LocaleKeys.settingsUsageListPageOf,
              namedArgs: {
                'current': (currentPage + 1).toString(),
                'total': totalPages.toString(),
              },
            ),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
          TextButton.icon(
            onPressed: currentPage < totalPages - 1
                ? () => onPageChanged(currentPage + 1)
                : null,
            icon: RevericIcon(
              RevericIcons.chevron_right,
              size: 14,
              color: currentPage < totalPages - 1
                  ? colors.textSecondary
                  : colors.textSubtle,
            ),
            label: Text(
              context.t(LocaleKeys.settingsUsageListNext),
              style: typo.uiSmall.copyWith(
                color: currentPage < totalPages - 1
                    ? colors.textSecondary
                    : colors.textSubtle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDateTime(DateTime dt) {
  final y = dt.year.toString();
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final h = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $h:$min';
}

/// 水平网格线
class _GridPainter extends CustomPainter {
  const _GridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const lines = 4; // 0% / 25% / 50% / 75% / 100% → 4 horizontal lines
    for (var i = 0; i <= lines; i++) {
      final y = (size.height / lines) * i;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.color != color;
}
