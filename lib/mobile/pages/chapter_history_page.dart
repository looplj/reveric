// 职责: 移动端章节修改历史页 — 单栏 commit 列表 + 来源过滤，点选进入明细 diff 页，复用 shared 历史组件。
// 关联文件:
//   lib/shared/widgets/history/change_history_components.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/theme/theme.dart
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/history/change_history_components.dart';

/// 章节修改历史页（全屏）。展示该章节的 commit 列表，点选进入明细 diff。
class MobileChapterHistoryPage extends HookConsumerWidget {
  const MobileChapterHistoryPage({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.resourceId,
    required this.resourceLabel,
  });

  final String databasePath;
  final String novelId;
  final String resourceId;
  final String resourceLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final filter = useState<HistorySourceFilter>(HistorySourceFilter.all);

    final commitsAsync = ref.watch(
      changeCommitsProvider(path: databasePath, limit: 200),
    );
    final resourceHistoryAsync = ref.watch(
      resourceIdChangeHistoryProvider(
        path: databasePath,
        resourceId: resourceId,
        limit: 200,
      ),
    );

    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.textPrimary,
        title: Text(
          context.t(
            LocaleKeys.historyResourceTitle,
            namedArgs: {'name': resourceLabel},
          ),
          style: typo.uiSemibold,
        ),
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const RevericIcon(RevericIcons.arrow_back, size: 22),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.md,
                vertical: RevericSpacing.sm,
              ),
              child: Row(
                children: [
                  HistoryFilterChip(
                    label: context.t(LocaleKeys.historyFilterAll),
                    selected: filter.value == HistorySourceFilter.all,
                    onTap: () => filter.value = HistorySourceFilter.all,
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  HistoryFilterChip(
                    label: context.t(LocaleKeys.historyFilterSourceAi),
                    selected: filter.value == HistorySourceFilter.ai,
                    onTap: () => filter.value = HistorySourceFilter.ai,
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  HistoryFilterChip(
                    label: context.t(LocaleKeys.historyFilterSourceManual),
                    selected: filter.value == HistorySourceFilter.manual,
                    onTap: () => filter.value = HistorySourceFilter.manual,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.borderSubtle),
            Expanded(
              child: commitsAsync.when(
                data: (commits) {
                  final resourceHistory = resourceHistoryAsync.asData?.value;
                  if (resourceHistory == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final filtered = filterChangeCommits(
                    commits: commits,
                    filter: filter.value,
                    resourceId: resourceId,
                    resourceHistory: resourceHistory,
                  );
                  if (filtered.isEmpty) {
                    return Center(
                      child: Text(
                        context.t(LocaleKeys.historyResourceEmpty),
                        style: typo.uiMedium.copyWith(color: colors.textMuted),
                      ),
                    );
                  }
                  final commitItemMap = groupCommitItemsByCommit(
                    resourceHistory,
                  );
                  return CommitList(
                    commits: filtered,
                    commitItemMap: commitItemMap,
                    selectedId: '',
                    onSelect: (id) {
                      final selected = filtered.firstWhere((c) => c.id == id);
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _ChapterCommitDetailPage(
                            novelId: novelId,
                            databasePath: databasePath,
                            commit: selected,
                            resourceId: resourceId,
                          ),
                        ),
                      );
                    },
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
}

class _ChapterCommitDetailPage extends StatelessWidget {
  const _ChapterCommitDetailPage({
    required this.databasePath,
    required this.novelId,
    required this.commit,
    required this.resourceId,
  });

  final String databasePath;
  final String novelId;
  final ChangeCommit commit;
  final String resourceId;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.textPrimary,
        title: Text(
          localizedCommitMessage(context, commit.message),
          style: typo.uiSemibold,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const RevericIcon(RevericIcons.arrow_back, size: 22),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        top: false,
        child: CommitDetail(
          novelId: novelId,
          databasePath: databasePath,
          commit: commit,
          resourceId: resourceId,
          onClose: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}
