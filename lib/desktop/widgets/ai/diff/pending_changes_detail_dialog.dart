// 职责: AI 修改的明细 Diff 弹窗 — 左侧资源列表、右侧 diff 详情，支持整体接受/回滚与按行退回
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/widgets/confirm_dialog.dart
//   lib/desktop/widgets/ai/diff/pending_changes_summary_card.dart
//   lib/shared/widgets/ai/diff/change_field_render.dart
//   lib/shared/widgets/ai/diff/diff_view.dart
//   lib/shared/widgets/ai/diff/resource_type_tag.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/utils/line_accept.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/diff.json
//   assets/translations/zh-CN/diff.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../shared/components/dialog_feedback.dart';
import '../../../../shared/database/novel_content_database.dart';
import '../../../../shared/logger/app_logger.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/providers/novel_providers.dart';
import '../../../../shared/services/novel_content.dart';
import '../../../../shared/services/working_change_summary.dart';
import '../../../../shared/services/working_overlay.dart';
import '../../../../shared/theme/theme.dart';
import '../../../../shared/utils/line_accept.dart';
import '../../../../shared/utils/resource_path.dart';
import '../../../../shared/widgets/ai/diff/change_field_render.dart';
import '../../../../shared/widgets/ai/diff/change_labels.dart';
import '../../../../shared/widgets/ai/diff/resource_type_tag.dart';
import 'package:reveric/shared/widgets/ai/diff/diff_view.dart';
import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/components/reveric_dialog.dart';

final _log = AppLogger.forModule('PendingChangesDetailDialog');

/// 单个资源（聚合后的若干 WorkingChange）在弹窗中所需的展示信息。
class PendingChangesDetailItem {
  const PendingChangesDetailItem({
    required this.changes,
    required this.fields,
    required this.title,
    required this.subtitle,
    required this.delta,
    this.resourceType = '',
    this.ordinals = const {},
    this.titleLabelKey,
  });

  final List<WorkingChange> changes;
  final List<WorkingFieldReview> fields;
  final String title;
  final String? titleLabelKey;
  final Map<String, int> ordinals;
  final String subtitle;
  final ({int added, int removed}) delta;

  /// 资源类型（chapters/characters/foreshadowing…），用于在列表里标出改的是什么。
  /// 光看标题分不清「林默」是人物还是章节，类型标签就是为此存在的。
  final String resourceType;
}

class PendingChangesDetailDialog extends HookConsumerWidget {
  const PendingChangesDetailDialog({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.items,
  });

  final String databasePath;
  final String novelId;
  final List<PendingChangesDetailItem> items;

  static Future<void> show(
    BuildContext context, {
    required String databasePath,
    required String novelId,
    required List<PendingChangesDetailItem> items,
  }) {
    return showRevericDialog(
      context: context,
      builder: (_) => DialogFeedback.scope(
        builder: (_) => PendingChangesDetailDialog(
          novelId: novelId,
          databasePath: databasePath,
          items: items,
        ),
      ),
    );
  }

  static Future<void> showFromChanges(
    BuildContext context, {
    required String databasePath,
    required String novelId,
    required List<WorkingChange> changes,
  }) {
    return showRevericDialog(
      context: context,
      builder: (_) => _PendingChangesDetailDialogFromChanges(
        novelId: novelId,
        databasePath: databasePath,
        changes: changes,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final totals = items.fold<(int, int)>((0, 0), (sum, item) {
      return (sum.$1 + item.delta.added, sum.$2 + item.delta.removed);
    });
    // 剧本元素里只存 character_id，渲染成角色行需要这张表；在顶层读一次往下传，
    // 避免每张 diff 卡片各 watch 一遍。
    final characterNames = {
      for (final profile
          in ref.watch(characterProfilesProvider(databasePath)).value ??
              const <CharacterProfile>[])
        profile.id: profile.name,
    };
    final mediaSize = MediaQuery.of(context).size;
    final dialogWidth = mediaSize.width.clamp(0, 1080).toDouble();
    final dialogHeight = (mediaSize.height * 0.8).clamp(360.0, 760.0);

    final selectedIndex = useState<int>(0);
    final isRunning = useState(false);
    final clampedIndex = items.isEmpty
        ? 0
        : selectedIndex.value.clamp(0, items.length - 1);
    final activeChangeIds = items
        .expand((item) => item.changes)
        .where(
          (change) =>
              change.status == workingChangeStatusActive &&
              change.source == workingChangeSourceAi,
        )
        .map((change) => change.id)
        .toSet()
        .toList();
    // 自动接受的 AI 变更仍可回滚；接受操作只处理上面的 active 集合。
    final rollbackChangeIds = items
        .expand((item) => item.changes)
        .where(
          (change) =>
              change.source == workingChangeSourceAi &&
              (change.status == workingChangeStatusActive ||
                  change.status == workingChangeStatusCommitted),
        )
        .map((change) => change.id)
        .toSet()
        .toList();

    // 选择按字段保存，并绑定确切的左右快照与原始记录集合。
    // 切换资源保留选择；任一快照变化后清空该字段的旧行键。
    final pendingReviewKeys = useState<Map<String, Set<String>>>(const {});
    final reviewSnapshots = useRef<Map<String, WorkingFieldReview>>({});
    final fieldsByKey = {
      for (final item in items)
        for (final field in item.fields) field.key: field,
    };
    useEffect(() {
      pendingReviewKeys.value = {
        for (final entry in pendingReviewKeys.value.entries)
          if (reviewSnapshots.value[entry.key] == fieldsByKey[entry.key])
            entry.key: entry.value,
      };
      reviewSnapshots.value = fieldsByKey;
      return null;
    }, [items]);
    final pendingMarkCount = pendingReviewKeys.value.values.fold<int>(
      0,
      (sum, keys) => sum + keys.length,
    );

    /// 审阅切换回调：把一行（可能含删除+新增两个行键）整体标记退回或恢复接受。
    /// 已落库回退体现在刷新的右侧文本中，不复用此前的行键。
    void setLinesRejected(
      String changeId,
      List<String> lineKeys,
      bool rejected,
    ) {
      if (isRunning.value) {
        return;
      }
      final next = Map<String, Set<String>>.from(pendingReviewKeys.value);
      final keys = {...?next[changeId]};
      if (rejected) {
        keys.addAll(lineKeys);
      } else {
        keys.removeAll(lineKeys);
      }
      if (keys.isEmpty) {
        next.remove(changeId);
      } else {
        next[changeId] = keys;
      }
      pendingReviewKeys.value = next;
    }

    /// 应用全部已标记的按行退回，返回成功退回的行数（无标记时为 0）。
    /// 应用失败或弹窗已关闭时
    /// 返回 null，调用方应中止后续提交（已成功的部分保持已应用，未成功的标记保留）。
    Future<int?> applyMarkedLineRollbacks() async {
      final pendingSnapshot = pendingReviewKeys.value;
      final targets = [
        for (final entry in pendingSnapshot.entries)
          if (entry.value.isNotEmpty) entry.key,
      ];
      if (targets.isEmpty) {
        return 0;
      }
      final service = ref.read(
        workOverlayServiceProvider((path: databasePath, novelId: novelId)),
      );
      final nextPending = Map<String, Set<String>>.from(pendingSnapshot);
      var revertedCount = 0;
      var failed = false;

      Future<void> runOne(String fieldKey) async {
        final review = fieldsByKey[fieldKey];
        if (review == null) {
          failed = true;
          nextPending.remove(fieldKey);
          return;
        }
        final keys = pendingSnapshot[fieldKey]!;
        final result = await service.rollbackFieldLines(review, keys);
        if (result == RollbackChangeResult.skipped) {
          failed = true;
          return;
        }
        revertedCount += countRejectedReviewRows(
          review.oldText,
          review.newText,
          keys,
        );
        nextPending.remove(fieldKey);
      }

      try {
        for (final changeId in targets) {
          await runOne(changeId);
        }
      } catch (error, stackTrace) {
        _log.error(
          'Apply line rollbacks failed databasePath=$databasePath',
          error: error,
          stackTrace: stackTrace,
        );
        failed = true;
      }
      if (!context.mounted) {
        return null;
      }
      pendingReviewKeys.value = {
        for (final entry in nextPending.entries)
          if (reviewSnapshots.value[entry.key] == fieldsByKey[entry.key])
            entry.key: entry.value,
      };
      if (failed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: DialogToast(
              variant: DialogToastVariant.error,
              child: Text(context.t(LocaleKeys.historyRollbackFailed)),
            ),
          ),
        );
      }
      return failed ? null : revertedCount;
    }

    Future<void> acceptChanges() async {
      // 无事可做：没有待提交的 active 变更，也没有已标记的按行退回。
      // 变更可能已全部 committed（如 AI 写入后自动提交），此时「接受」只负责
      // 应用行级退回，不再有整体提交。
      if (isRunning.value ||
          (activeChangeIds.isEmpty && pendingMarkCount == 0)) {
        return;
      }

      isRunning.value = true;
      try {
        final service = ref.read(
          workOverlayServiceProvider((path: databasePath, novelId: novelId)),
        );
        // 先按展示快照应用行选择，再接受剩余 active 原始记录。
        // 部分回退提交原始记录并另存反向改动，不改变原轮次快照。
        final revertedCount = await applyMarkedLineRollbacks();
        if (revertedCount == null || !context.mounted) {
          return;
        }
        if (activeChangeIds.isNotEmpty) {
          await service.commitWorkingChanges(
            activeChangeIds,
            source: workingChangeSourceAi,
            message: 'history.commit_message.accept_all_pending_ai_changes',
          );
        }
        if (!context.mounted) {
          return;
        }
        DialogFeedback.hostMessengerOf(context).showSnackBar(
          SnackBar(
            content: Text(
              activeChangeIds.isNotEmpty
                  ? context.t(
                      LocaleKeys.historyCommitMessageAcceptAllPendingAiChanges,
                    )
                  : context.t(
                      LocaleKeys.diffReviewAppliedCount,
                      namedArgs: {'count': '$revertedCount'},
                    ),
            ),
          ),
        );
        Navigator.of(context).pop();
      } catch (error, stackTrace) {
        _log.error(
          'Accept pending AI changes failed databasePath=$databasePath',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: DialogToast(
                variant: DialogToastVariant.error,
                child: Text(context.t(LocaleKeys.workspaceAcceptChangesFailed)),
              ),
            ),
          );
        }
      } finally {
        if (context.mounted) {
          isRunning.value = false;
        }
      }
    }

    Future<void> rollbackChanges() async {
      if (isRunning.value || rollbackChangeIds.isEmpty) {
        return;
      }

      final confirmed = await showConfirmDialog(
        context,
        title: context.t(LocaleKeys.workspaceRollbackAllConfirmTitle),
        message: context.t(LocaleKeys.workspaceRollbackAllConfirmMessage),
        confirmLabel: context.t(LocaleKeys.historyRollbackConfirmAction),
        variant: ConfirmDialogVariant.warning,
      );
      if (confirmed != true || !context.mounted) {
        return;
      }

      isRunning.value = true;
      try {
        final service = ref.read(
          workOverlayServiceProvider((path: databasePath, novelId: novelId)),
        );
        final result = await service.rollbackFields([
          for (final item in items) ...item.fields,
        ]);
        if (!context.mounted) {
          return;
        }
        DialogFeedback.hostMessengerOf(context).showSnackBar(
          SnackBar(
            content: Text(
              result.skippedPaths.isEmpty
                  ? context.t(LocaleKeys.workspaceRollbackDone)
                  : context.t(
                      LocaleKeys.historyRollbackSkipped,
                      namedArgs: {
                        'restored': '${result.rolledBack}',
                        'skipped': '${result.skippedPaths.length}',
                      },
                    ),
            ),
          ),
        );
        Navigator.of(context).pop();
      } catch (error, stackTrace) {
        _log.error(
          'Rollback pending AI changes failed databasePath=$databasePath',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: DialogToast(
                variant: DialogToastVariant.error,
                child: Text(context.t(LocaleKeys.historyRollbackFailed)),
              ),
            ),
          );
        }
      } finally {
        if (context.mounted) {
          isRunning.value = false;
        }
      }
    }

    return AlertDialog(
      backgroundColor: colors.surfaceContainerHigh,
      title: Row(
        children: [
          RevericIcon(
            RevericIcons.description_outlined,
            size: 18,
            color: colors.textMuted,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              context.t(
                LocaleKeys.workspaceFilesChanged,
                namedArgs: {'count': '${items.length}'},
              ),
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (totals.$1 > 0) ...[
            const SizedBox(width: RevericSpacing.sm),
            Text(
              '+${totals.$1}',
              style: typo.uiMedium.copyWith(
                color: colors.additionBorder,
                fontSize: 13,
              ),
            ),
          ],
          if (totals.$2 > 0) ...[
            const SizedBox(width: RevericSpacing.xs),
            Text(
              '-${totals.$2}',
              style: typo.uiMedium.copyWith(
                color: colors.deletionBorder,
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(
        RevericSpacing.lg,
        RevericSpacing.sm,
        RevericSpacing.lg,
        RevericSpacing.sm,
      ),
      content: DialogFeedback.surface(
        builder: (context) => SizedBox(
          width: dialogWidth,
          height: dialogHeight,
          child: items.isEmpty
              ? Center(
                  child: Text(
                    context.t(LocaleKeys.aiNoMessagesYet),
                    style: typo.uiMedium.copyWith(color: colors.textMuted),
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(RevericRadius.large),
                    border: Border.all(color: colors.borderSubtle),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 280,
                        child: _FileList(
                          items: items,
                          selectedIndex: clampedIndex,
                          onSelect: (i) => selectedIndex.value = i,
                        ),
                      ),
                      VerticalDivider(width: 1, color: colors.borderSubtle),
                      Expanded(
                        child: _FileDetail(
                          item: items[clampedIndex],
                          characterNames: characterNames,
                          pendingKeysByChange: pendingReviewKeys.value,
                          appliedKeysByChange: const {},
                          isRunning: isRunning.value,
                          onSetLinesRejected: setLinesRejected,
                          onResetReview: () {
                            final currentIds = items[clampedIndex].fields
                                .map((field) => field.key)
                                .toSet();
                            final next = Map<String, Set<String>>.from(
                              pendingReviewKeys.value,
                            )..removeWhere((id, _) => currentIds.contains(id));
                            pendingReviewKeys.value = next;
                          },
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: isRunning.value ? null : () => Navigator.of(context).pop(),
          child: Text(
            context.t(LocaleKeys.commonClose),
            style: typo.ui.copyWith(color: colors.textMuted),
          ),
        ),
        OutlinedButton.icon(
          onPressed: isRunning.value || rollbackChangeIds.isEmpty
              ? null
              : rollbackChanges,
          icon: isRunning.value
              ? SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.deletionBorder,
                  ),
                )
              : RevericIcon(RevericIcons.undo, size: 16),
          label: Text(context.t(LocaleKeys.workspaceRollbackAllChanges)),
          style: OutlinedButton.styleFrom(
            foregroundColor: colors.deletionBorder,
          ),
        ),
        FilledButton.icon(
          onPressed:
              isRunning.value ||
                  (activeChangeIds.isEmpty && pendingMarkCount == 0)
              ? null
              : acceptChanges,
          icon: isRunning.value
              ? SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.surface,
                  ),
                )
              : RevericIcon(RevericIcons.check, size: 16),
          label: Text(context.t(LocaleKeys.aiAccept)),
        ),
      ],
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<PendingChangesDetailItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        color: colors.borderSubtle,
        indent: RevericSpacing.md,
        endIndent: RevericSpacing.md,
      ),
      itemBuilder: (context, index) {
        return _FileListTile(
          item: items[index],
          selected: index == selectedIndex,
          onTap: () => onSelect(index),
        );
      },
    );
  }
}

class _FileListTile extends StatelessWidget {
  const _FileListTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final PendingChangesDetailItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final resourceTitle = ChangeResourceTitle(
      item.title,
      ordinals: item.ordinals,
      labelKey: item.titleLabelKey,
    ).label(context);
    final headerTitle = resourceTitle.isNotEmpty
        ? resourceTitle
        : (item.subtitle.isNotEmpty
              ? item.subtitle
              : item.changes.first.resourcePath);
    final typeLabelKey = resourceTypeLabelKey(item.resourceType);

    return Material(
      color: selected ? colors.surfaceContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RevericIcon(
                RevericIcons.description_outlined,
                size: 16,
                color: colors.textMuted,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      headerTitle,
                      style: typo.uiMedium.copyWith(
                        color: colors.textPrimary,
                        fontSize: 13,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (resourceTitle.isNotEmpty &&
                        item.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.subtitle,
                        style: typo.uiSmall.copyWith(
                          color: colors.textMuted,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (typeLabelKey != null) ...[
                          ResourceTypeTag(labelKey: typeLabelKey),
                          const SizedBox(width: RevericSpacing.sm),
                        ],
                        if (item.delta.added > 0)
                          Text(
                            '+${item.delta.added}',
                            style: typo.uiTiny.copyWith(
                              color: colors.additionBorder,
                            ),
                          ),
                        if (item.delta.added > 0 && item.delta.removed > 0)
                          const SizedBox(width: 4),
                        if (item.delta.removed > 0)
                          Text(
                            '-${item.delta.removed}',
                            style: typo.uiTiny.copyWith(
                              color: colors.deletionBorder,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileDetail extends StatelessWidget {
  const _FileDetail({
    required this.item,
    required this.characterNames,
    required this.pendingKeysByChange,
    required this.appliedKeysByChange,
    required this.isRunning,
    required this.onSetLinesRejected,
    required this.onResetReview,
  });

  final PendingChangesDetailItem item;

  /// 人物 id → 名字，供剧本元素渲染还原角色行。
  final Map<String, String> characterNames;

  /// 对话级按行审阅状态（按 change.key），见 [PendingChangesDetailDialog]。
  final Map<String, Set<String>> pendingKeysByChange;
  final Map<String, Set<String>> appliedKeysByChange;
  final bool isRunning;
  final void Function(String changeId, List<String> lineKeys, bool rejected)
  onSetLinesRejected;

  /// 重置本文件范围内已标记的按行退回。
  final VoidCallback onResetReview;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final resourceTitle = ChangeResourceTitle(
      item.title,
      ordinals: item.ordinals,
      labelKey: item.titleLabelKey,
    ).label(context);
    final headerTitle = resourceTitle.isNotEmpty
        ? resourceTitle
        : (item.subtitle.isNotEmpty
              ? item.subtitle
              : item.changes.first.resourcePath);
    // 面向用户的计数按审阅行统计：配对的删增修改行算 1 行，与逐行切换按钮一致。
    final pendingCount = item.fields.fold<int>(
      0,
      (sum, change) =>
          sum +
          countRejectedReviewRows(
            change.oldText,
            change.newText,
            pendingKeysByChange[change.key] ?? const {},
          ),
    );
    final appliedCount = item.fields.fold<int>(
      0,
      (sum, change) =>
          sum +
          countRejectedReviewRows(
            change.oldText,
            change.newText,
            appliedKeysByChange[change.key] ?? const {},
          ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.lg,
            vertical: RevericSpacing.md,
          ),
          color: colors.surfaceDim,
          child: Row(
            children: [
              RevericIcon(
                RevericIcons.description_outlined,
                size: 14,
                color: colors.textMuted,
              ),
              const SizedBox(width: RevericSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      headerTitle,
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (resourceTitle.isNotEmpty && item.subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          item.subtitle,
                          style: typo.uiSmall.copyWith(
                            color: colors.textMuted,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              if (item.delta.added > 0)
                Text(
                  '+${item.delta.added}',
                  style: typo.uiTiny.copyWith(color: colors.additionBorder),
                ),
              if (item.delta.added > 0 && item.delta.removed > 0)
                const SizedBox(width: 4),
              if (item.delta.removed > 0)
                Text(
                  '-${item.delta.removed}',
                  style: typo.uiTiny.copyWith(color: colors.deletionBorder),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.borderSubtle),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(RevericSpacing.md),
            itemCount: item.fields.length,
            separatorBuilder: (_, _) =>
                const SizedBox(height: RevericSpacing.md),
            itemBuilder: (context, index) {
              final change = item.fields[index];
              return _ChangeFieldDiff(
                change: change,
                characterNames: characterNames,
                pendingKeys: pendingKeysByChange[change.key] ?? const {},
                appliedKeys: appliedKeysByChange[change.key] ?? const {},
                onSetLinesRejected: onSetLinesRejected,
              );
            },
          ),
        ),
        // 按行审阅粘性底栏：聚合本文件全部卡片的标记，仅在有待退回或已退回时出现。
        if (pendingCount > 0 || appliedCount > 0)
          _LineReviewBar(
            pendingCount: pendingCount,
            appliedCount: appliedCount,
            isRunning: isRunning,
            onReset: onResetReview,
          ),
      ],
    );
  }
}

class _PendingChangesDetailDialogFromChanges extends HookConsumerWidget {
  const _PendingChangesDetailDialogFromChanges({
    required this.databasePath,
    required this.novelId,
    required this.changes,
  });

  final String databasePath;
  final String novelId;
  final List<WorkingChange> changes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = changes.isEmpty ? null : changes.first.sourceSessionId;
    final currentChanges = sessionId == null
        ? changes
        : ref.watch(sessionChangesProvider(databasePath, sessionId)).value ??
              changes;
    final reviews = ref.watch(
      workingFieldReviewsProvider(databasePath, currentChanges),
    );
    // 切换到新记录集合的 provider 时先保留已展示快照；只有真实数据才能清空选择。
    final loadedReviews = useRef<List<WorkingFieldReview>?>(null);
    if (reviews.value != null) {
      loadedReviews.value = reviews.value;
    }
    final localeName = Localizations.localeOf(context).toString();
    final fieldLabels = buildChangeFieldLabels(context, currentChanges);
    final resolvedFuture = useMemoized(
      () => loadedReviews.value == null
          ? null
          : _resolveChanges(
              ref,
              databasePath,
              loadedReviews.value!,
              fieldLabels,
            ),
      [databasePath, loadedReviews.value, localeName],
    );
    final snapshot = useFuture(resolvedFuture);

    final resolvedResult = snapshot.data;

    if (resolvedResult == null) {
      final colors = RevericTheme.colorsOf(context);
      return AlertDialog(
        backgroundColor: colors.surfaceContainerHigh,
        content: SizedBox(
          width: 200,
          height: 100,
          child: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.accent,
            ),
          ),
        ),
      );
    }

    return DialogFeedback.scope(
      builder: (_) => PendingChangesDetailDialog(
        novelId: novelId,
        databasePath: databasePath,
        items: resolvedResult,
      ),
    );
  }
}

Future<List<PendingChangesDetailItem>> _resolveChanges(
  WidgetRef ref,
  String databasePath,
  List<WorkingFieldReview> reviews,
  Map<String, String> fieldLabels,
) async {
  final service = ref.read(novelContentServiceProvider(databasePath));
  final grouped = <String, List<WorkingFieldReview>>{};
  for (final change in reviews) {
    final key =
        '${change.resourceType}:${change.resourceId ?? canonicalResourcePath(change.resourcePath)}';
    grouped.putIfAbsent(key, () => <WorkingFieldReview>[]).add(change);
  }

  final resolved = <PendingChangesDetailItem>[];
  for (final entry in grouped.entries) {
    resolved.add(await _resolveGroup(entry.value, service, fieldLabels));
  }
  return resolved;
}

Future<PendingChangesDetailItem> _resolveGroup(
  List<WorkingFieldReview> reviews,
  NovelContentService service,
  Map<String, String> fieldLabels,
) async {
  final changes = [for (final review in reviews) ...review.changes];
  final change = changes.first;
  var added = 0;
  var removed = 0;
  for (final item in reviews) {
    // 与字段卡片同一口径：结构化字段先渲染再算行数，否则文件头永远是 ±1，
    // 和展开后看到的 diff 对不上。人名不影响行数，这里不查。
    final texts = renderChangeFieldDiff(
      resourceType: item.resourceType,
      field: item.field,
      oldRaw: item.oldText,
      newRaw: item.newText,
    );
    final delta = lineDelta(texts.oldText, texts.newText);
    added += delta.added;
    removed += delta.removed;
  }
  final fields = changes
      .map((item) => item.field)
      .whereType<String>()
      .toSet()
      .toList();
  final subtitle = buildChangesSubtitle(
    fields,
    fieldLabels,
    resourceType: change.resourceType,
  );
  final title = await resolveChangeResourceTitle(changes, service);

  return PendingChangesDetailItem(
    changes: changes,
    fields: reviews,
    title: title.title,
    ordinals: title.ordinals,
    titleLabelKey: title.labelKey,
    subtitle: subtitle,
    delta: (added: added, removed: removed),
    resourceType: change.resourceType,
  );
}

Map<String, String> buildChangeFieldLabels(
  BuildContext context,
  List<WorkingChange> changes,
) {
  return {
    for (final change in changes)
      if (change.field != null)
        '${change.resourceType}:${change.field}':
            changeFieldLabel(context, change.resourceType, change.field!) ??
            change.field!,
  };
}

String buildChangesSubtitle(
  List<String> fields,
  Map<String, String> fieldLabels, {
  required String resourceType,
}) {
  final labels = fields
      .map((field) => fieldLabels['$resourceType:$field'])
      .whereType<String>()
      .toList();
  if (labels.isEmpty) {
    return '';
  }
  return labels.join(' / ');
}

/// 单个字段的 diff 卡片：展示 old→new 差异，按行标记退回。
///
/// 按行审阅状态（待退回 / 已退回）由 [PendingChangesDetailDialog] 按字段 key
/// 持有，为会话内临时状态、不持久化；目标应用在对话级统一处理。
class _ChangeFieldDiff extends StatelessWidget {
  const _ChangeFieldDiff({
    required this.change,
    required this.characterNames,
    required this.pendingKeys,
    required this.appliedKeys,
    required this.onSetLinesRejected,
  });

  final WorkingFieldReview change;

  /// 人物 id → 名字，供剧本元素渲染还原角色行。
  final Map<String, String> characterNames;

  /// 当前字段文本是否已偏离冻结 newText（按行部分退回或外部编辑）；

  /// 本 change 的待退回 / 已退回（已落库、锁定）行键。
  final Set<String> pendingKeys;
  final Set<String> appliedKeys;

  /// 行级退回状态切换回调（change.key 由卡片回填）。
  final void Function(String changeId, List<String> lineKeys, bool rejected)
  onSetLinesRejected;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final field = change.field?.trim();
    final fieldLabel = field == null || field.isEmpty
        ? null
        : changeFieldLabel(context, change.resourceType, field) ?? field;
    final texts = renderChangeFieldDiff(
      resourceType: change.resourceType,
      field: field,
      oldRaw: change.oldText,
      newRaw: change.newText,
      characterNames: characterNames,
    );
    final delta = lineDelta(texts.oldText, texts.newText);

    // 仅 AI 来源且仍处于 active/committed 的 change 可审阅；
    // rejected/conflicted 等终态不再提供退回入口。
    // 纯新增/纯删除只做单栏展示，按行退回仅对删增混合的修改开放。
    // 结构化字段的展示文本渲染自 JSON，行与存储形态对不上，只能整体接受/回滚。
    final reviewLayout = lineReviewLayoutFor(change.oldText, change.newText);
    final reviewableState =
        !texts.structured &&
        !change.isStructuredField &&
        change.reviewable &&
        reviewLayout != LineReviewLayout.none;
    final canReview = reviewableState;
    final lineReviewable = canReview && reviewLayout == LineReviewLayout.mixed;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        border: Border.all(color: colors.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (fieldLabel != null && fieldLabel.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.md,
                vertical: RevericSpacing.xs,
              ),
              color: colors.surface,
              child: Row(
                children: [
                  Text(
                    fieldLabel,
                    style: typo.uiSmall.copyWith(color: colors.textSecondary),
                  ),
                  const Spacer(),
                  if (delta.added > 0)
                    Text(
                      '+${delta.added}',
                      style: typo.uiTiny.copyWith(color: colors.additionBorder),
                    ),
                  if (delta.added > 0 && delta.removed > 0)
                    const SizedBox(width: 4),
                  if (delta.removed > 0)
                    Text(
                      '-${delta.removed}',
                      style: typo.uiTiny.copyWith(color: colors.deletionBorder),
                    ),
                ],
              ),
            ),
          AiDiffView(
            oldText: texts.oldText,
            newText: texts.newText,
            showLabels: false,
            reviewMode: canReview,
            rejectedLineKeys: {...appliedKeys, ...pendingKeys},
            lockedLineKeys: appliedKeys,
            onSetLinesRejected: lineReviewable
                ? (lineKeys, rejected) =>
                      onSetLinesRejected(change.key, lineKeys, rejected)
                : null,
          ),
        ],
      ),
    );
  }
}

/// 按行审阅的粘性底栏（文件级）：左侧聚合已标记/已退回计数，右侧重置按钮。
/// 行级退回随对话框底部「接受」统一应用，不再单独确认。
class _LineReviewBar extends StatelessWidget {
  const _LineReviewBar({
    required this.pendingCount,
    required this.appliedCount,
    required this.isRunning,
    required this.onReset,
  });

  final int pendingCount;
  final int appliedCount;
  final bool isRunning;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        border: Border(top: BorderSide(color: colors.borderSubtle)),
      ),
      child: Row(
        children: [
          if (pendingCount > 0)
            Text(
              context.t(
                LocaleKeys.diffReviewMarkedCount,
                namedArgs: {'count': '$pendingCount'},
              ),
              style: typo.uiTiny.copyWith(color: colors.warningText),
            ),
          if (pendingCount > 0 && appliedCount > 0)
            const SizedBox(width: RevericSpacing.sm),
          if (appliedCount > 0)
            Text(
              context.t(
                LocaleKeys.diffReviewAppliedCount,
                namedArgs: {'count': '$appliedCount'},
              ),
              style: typo.uiTiny.copyWith(color: colors.textMuted),
            ),
          const Spacer(),
          if (pendingCount > 0)
            TextButton(
              onPressed: isRunning ? null : onReset,
              style: TextButton.styleFrom(
                foregroundColor: colors.textMuted,
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.sm,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: typo.uiMedium.copyWith(fontSize: 12),
              ),
              child: Text(context.t(LocaleKeys.commonReset)),
            ),
        ],
      ),
    );
  }
}
