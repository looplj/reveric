// 职责: 桌面端全局修改历史面板 — 双栏组装 commit 列表与选中提交明细 diff，复用 shared 组件。
// 关联文件:
//   lib/shared/widgets/history/change_history_components.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/services/working_change_summary.dart
//   lib/shared/widgets/ai/diff/diff_view.dart
//   lib/shared/localization/locale_keys.dart
//   lib/desktop/widgets/history/resource_history_button.dart
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/history/change_history_components.dart';

class ChangeHistoryPanel extends ConsumerStatefulWidget {
  const ChangeHistoryPanel({
    super.key,
    required this.databasePath,
    required this.novelId,
    this.resourceId,
    this.resourceLabel,
    this.onClose,
  });

  final String databasePath;
  final String novelId;
  final String? resourceId;
  final String? resourceLabel;
  final VoidCallback? onClose;

  @override
  ConsumerState<ChangeHistoryPanel> createState() => _ChangeHistoryPanelState();
}

class _ChangeHistoryPanelState extends ConsumerState<ChangeHistoryPanel> {
  String? _selectedCommitId;
  HistorySourceFilter _filter = HistorySourceFilter.all;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final scopedResourceId = widget.resourceId;
    final commitsAsync = ref.watch(
      changeCommitsProvider(path: widget.databasePath, limit: 200),
    );
    final resourceHistoryAsync = scopedResourceId == null
        ? const AsyncValue<List<ChangeCommitItem>>.data(<ChangeCommitItem>[])
        : ref.watch(
            resourceIdChangeHistoryProvider(
              path: widget.databasePath,
              resourceId: scopedResourceId,
              limit: 200,
            ),
          );

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: SelectionArea(
        child: Column(
          children: [
            _buildHeader(context, typo, colors),
            Divider(height: 1, color: colors.borderSubtle),
            Expanded(
              child: commitsAsync.when(
                data: (commits) {
                  final resourceHistory = resourceHistoryAsync.asData?.value;
                  if (scopedResourceId != null && resourceHistory == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final filtered = filterChangeCommits(
                    commits: commits,
                    filter: _filter,
                    resourceId: scopedResourceId,
                    resourceHistory: resourceHistory,
                  );
                  if (filtered.isEmpty) {
                    return _buildEmpty(context, typo, colors);
                  }
                  final commitItemMap = groupCommitItemsByCommit(
                    resourceHistory,
                  );
                  final selectedId =
                      _selectedCommitId != null &&
                          filtered.any((c) => c.id == _selectedCommitId)
                      ? _selectedCommitId!
                      : filtered.first.id;
                  final selected = filtered.firstWhere(
                    (c) => c.id == selectedId,
                  );
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 320,
                        child: CommitList(
                          commits: filtered,
                          commitItemMap: commitItemMap,
                          selectedId: selectedId,
                          onSelect: (id) =>
                              setState(() => _selectedCommitId = id),
                        ),
                      ),
                      VerticalDivider(width: 1, color: colors.borderSubtle),
                      Expanded(
                        child: CommitDetail(
                          novelId: widget.novelId,
                          databasePath: widget.databasePath,
                          commit: selected,
                          resourceId: widget.resourceId,
                          onClose: widget.onClose,
                        ),
                      ),
                    ],
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => Center(
                  child: Text(
                    context.t(LocaleKeys.historyLoadingFailed),
                    style: typo.uiMedium.copyWith(color: colors.textMuted),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    RevericTypography typo,
    RevericColors colors,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.lg,
        vertical: RevericSpacing.md,
      ),
      color: colors.surfaceDim,
      child: Row(
        children: [
          RevericIcon(
            RevericIcons.history_rounded,
            size: 18,
            color: colors.textSecondary,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Text(
            widget.resourceLabel == null
                ? context.t(LocaleKeys.historyTitle)
                : context.t(
                    LocaleKeys.historyResourceTitle,
                    namedArgs: {'name': widget.resourceLabel!},
                  ),
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(width: RevericSpacing.x3l),
          HistoryFilterChip(
            label: context.t(LocaleKeys.historyFilterAll),
            selected: _filter == HistorySourceFilter.all,
            onTap: () => setState(() => _filter = HistorySourceFilter.all),
          ),
          const SizedBox(width: RevericSpacing.xs),
          HistoryFilterChip(
            label: context.t(LocaleKeys.historyFilterSourceAi),
            selected: _filter == HistorySourceFilter.ai,
            onTap: () => setState(() => _filter = HistorySourceFilter.ai),
          ),
          const SizedBox(width: RevericSpacing.xs),
          HistoryFilterChip(
            label: context.t(LocaleKeys.historyFilterSourceManual),
            selected: _filter == HistorySourceFilter.manual,
            onTap: () => setState(() => _filter = HistorySourceFilter.manual),
          ),
          const Spacer(),
          if (widget.onClose != null)
            IconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonLabel,
              icon: const RevericIcon(RevericIcons.close_rounded, size: 18),
              onPressed: widget.onClose,
              color: colors.textMuted,
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty(
    BuildContext context,
    RevericTypography typo,
    RevericColors colors,
  ) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RevericIcon(
            RevericIcons.inbox_outlined,
            size: 32,
            color: colors.textMuted,
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            widget.resourceId == null
                ? context.t(LocaleKeys.historyEmpty)
                : context.t(LocaleKeys.historyResourceEmpty),
            style: typo.uiMedium.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}
