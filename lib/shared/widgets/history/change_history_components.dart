// 职责: 修改历史的可复用展示组件 — commit 列表、commit 明细 diff、过滤 chip、回滚/恢复按钮，供 desktop 面板与 mobile 页面共用。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/services/working_change_summary.dart
//   lib/shared/widgets/ai/diff/change_field_render.dart
//   lib/shared/widgets/ai/diff/diff_view.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

import '../../components/dialog_feedback.dart';
import '../../database/novel_content_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../providers/novel_providers.dart';
import '../../services/working_change_summary.dart';
import '../../services/working_overlay.dart';
import '../../theme/theme.dart';
import '../ai/diff/change_field_render.dart';
import '../ai/diff/change_labels.dart';
import '../ai/diff/diff_view.dart';
import '../confirm_dialog.dart';
import '../../components/reveric_dialog.dart';

/// 修改历史来源过滤。
enum HistorySourceFilter { all, ai, manual }

/// 按来源过滤 commit；当提供 [resourceId] 时，仅保留触及该资源的 commit。
List<ChangeCommit> filterChangeCommits({
  required List<ChangeCommit> commits,
  required HistorySourceFilter filter,
  String? resourceId,
  List<ChangeCommitItem>? resourceHistory,
}) {
  bool passesFilter(ChangeCommit commit) {
    switch (filter) {
      case HistorySourceFilter.all:
        return true;
      case HistorySourceFilter.ai:
        return commit.source == workingChangeSourceAi;
      case HistorySourceFilter.manual:
        return commit.source == workingChangeSourceManual;
    }
  }

  final filtered = commits.where(passesFilter).toList();
  if (resourceId == null) {
    return filtered;
  }
  final commitIds = <String>{
    for (final item in resourceHistory ?? const <ChangeCommitItem>[])
      item.commitId,
  };
  return filtered.where((commit) => commitIds.contains(commit.id)).toList();
}

/// 把资源级历史条目按 commitId 分组。
Map<String, List<ChangeCommitItem>> groupCommitItemsByCommit(
  List<ChangeCommitItem>? items,
) {
  final map = <String, List<ChangeCommitItem>>{};
  for (final item in items ?? const <ChangeCommitItem>[]) {
    map.putIfAbsent(item.commitId, () => <ChangeCommitItem>[]).add(item);
  }
  return map;
}

class HistoryFilterChip extends StatelessWidget {
  const HistoryFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.surfaceContainerHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(RevericRadius.medium),
            border: Border.all(
              color: selected ? colors.border : colors.borderSubtle,
            ),
          ),
          child: Text(
            label,
            style: typo.uiSmall.copyWith(
              color: selected ? colors.textPrimary : colors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class CommitList extends StatelessWidget {
  const CommitList({
    super.key,
    required this.commits,
    required this.commitItemMap,
    required this.selectedId,
    required this.onSelect,
  });

  final List<ChangeCommit> commits;
  final Map<String, List<ChangeCommitItem>> commitItemMap;
  final String selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return ListView.separated(
      itemCount: commits.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        color: colors.borderSubtle,
        indent: RevericSpacing.md,
        endIndent: RevericSpacing.md,
      ),
      itemBuilder: (context, index) {
        final commit = commits[index];
        return CommitListTile(
          commit: commit,
          items: commitItemMap[commit.id] ?? const <ChangeCommitItem>[],
          selected: commit.id == selectedId,
          onTap: () => onSelect(commit.id),
        );
      },
    );
  }
}

class CommitListTile extends StatelessWidget {
  const CommitListTile({
    super.key,
    required this.commit,
    required this.items,
    required this.selected,
    required this.onTap,
  });

  final ChangeCommit commit;
  final List<ChangeCommitItem> items;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final isAi = commit.source == workingChangeSourceAi;
    final message = commit.message.trim().isNotEmpty
        ? commit.message.trim()
        : context.t(LocaleKeys.historyCommitDefaultMessage);
    final resourceSummary = summarizeCommitFields(context, items);
    final time = DateFormat.yMd().add_Hm().format(commit.createdAt.toLocal());

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
                isAi ? RevericIcons.auto_awesome : RevericIcons.edit_outlined,
                size: 16,
                color: isAi ? colors.accentWarm : colors.textMuted,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      localizedCommitMessage(context, message),
                      style: typo.uiMedium.copyWith(color: colors.textPrimary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (resourceSummary != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        resourceSummary,
                        style: typo.uiSmall.copyWith(
                          color: colors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      '$time · ${context.t(LocaleKeys.historyCommitCount, namedArgs: {'count': '${commit.changeCount}'})}',
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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

String localizedCommitMessage(BuildContext context, String rawMessage) {
  final trimmed = rawMessage.trim();
  if (trimmed.isEmpty) {
    return context.t(LocaleKeys.historyCommitDefaultMessage);
  }
  switch (trimmed) {
    case LocaleKeys.historyCommitMessageRollbackTurn:
    case LocaleKeys.historyCommitMessageRollbackChangeLines:
    case LocaleKeys.historyCommitMessageRollbackSelectedCommit:
    case LocaleKeys.historyCommitMessageRestoreToHistoricalVersion:
      return context.t(trimmed);
    case 'history.commit_message.accept_all_pending_ai_changes':
    case 'Accept all pending AI changes':
      return context.t(
        LocaleKeys.historyCommitMessageAcceptAllPendingAiChanges,
      );
    case 'history.commit_message.manual_chapter_save':
    case 'Manual chapter save':
      return context.t(LocaleKeys.historyCommitMessageManualChapterSave);
    case LocaleKeys.historyCommitMessageManualSceneSave:
      return context.t(LocaleKeys.historyCommitMessageManualSceneSave);
    case LocaleKeys.historyCommitMessageManualEpisodeOutlineSave:
      return context.t(LocaleKeys.historyCommitMessageManualEpisodeOutlineSave);
    case 'history.commit_message.manual_novel_description_save':
    case 'Manual novel description save':
      return context.t(
        LocaleKeys.historyCommitMessageManualNovelDescriptionSave,
      );
    case 'history.commit_message.manual_entry_save':
    case 'Manual entry save':
      return context.t(LocaleKeys.historyCommitMessageManualEntrySave);
    case 'history.commit_message.manual_character_save':
    case 'Manual character save':
      return context.t(LocaleKeys.historyCommitMessageManualCharacterSave);
    case 'history.commit_message.manual_foreshadowing_save':
    case 'Manual foreshadowing save':
      return context.t(LocaleKeys.historyCommitMessageManualForeshadowingSave);
    case 'history.commit_message.accept_ai_change_group':
    case 'Accept AI change group':
      return context.t(LocaleKeys.historyCommitMessageAcceptAiChangeGroup);
    case 'history.commit_message.auto_commit_ai_changes':
    case 'Auto-commit AI changes':
    case 'history.commit_message.auto_commit_pending_ai_changes_before_new_session':
    case 'Auto-commit pending AI changes before new session':
    case 'history.commit_message.auto_commit_pending_ai_on_manual_save':
    case 'Auto-commit pending AI changes on manual save':
      return context.t(LocaleKeys.historyCommitMessageAutoCommitAiChanges);
    default:
      return trimmed;
  }
}

String? summarizeCommitFields(
  BuildContext context,
  List<ChangeCommitItem> items,
) {
  if (items.isEmpty) {
    return null;
  }
  final segments = <String>[];
  final seen = <String>{};
  for (final item in items) {
    final fieldKey = _fieldKeyForItem(item);
    if (!seen.add(fieldKey)) {
      continue;
    }
    // 结构化字段的存储形态是单行 JSON，按存储文本算永远是 ±1；这里与明细卡片
    // 一样先渲染再算，列表副标题和展开后的 diff 才是同一个口径。
    final texts = renderChangeFieldDiff(
      resourceType: item.resourceType,
      field: item.field,
      oldRaw: item.oldText,
      newRaw: item.newText,
    );
    final delta = lineDelta(texts.oldText, texts.newText);
    final parts = <String>[];
    if (delta.added > 0) {
      parts.add('+${delta.added}');
    }
    if (delta.removed > 0) {
      parts.add('-${delta.removed}');
    }
    final deltaLabel = parts.isEmpty ? '0' : parts.join('/');
    segments.add(
      context.t(
        LocaleKeys.historyFieldDelta,
        namedArgs: {
          'field': _localizedFieldLabel(context, fieldKey),
          'delta': deltaLabel,
        },
      ),
    );
  }
  if (segments.isEmpty) {
    return null;
  }
  if (segments.length <= 3) {
    return segments.join(', ');
  }
  return context.t(
    LocaleKeys.historyFieldSummaryOverflow,
    namedArgs: {
      'summary': segments.take(3).join(', '),
      'count': '${segments.length - 3}',
    },
  );
}

String _fieldKeyForItem(ChangeCommitItem item) {
  final field = item.field?.trim();
  if (field != null && field.isNotEmpty) {
    return field;
  }
  return item.resourceType;
}

String _localizedFieldLabel(BuildContext context, String fieldKey) {
  switch (fieldKey) {
    case 'title':
      return context.t(LocaleKeys.historyFieldTitle);
    case 'summary':
      return context.t(LocaleKeys.historyFieldSummary);
    case 'content':
      return context.t(LocaleKeys.historyFieldContent);
    case 'name':
      return context.t(LocaleKeys.historyFieldName);
    case 'role':
      return context.t(LocaleKeys.historyFieldRole);
    case 'gender':
      return context.t(LocaleKeys.historyFieldGender);
    case 'setup':
      return context.t(LocaleKeys.historyFieldSetup);
    case 'payoff':
      return context.t(LocaleKeys.historyFieldPayoff);
    case 'status':
      return context.t(LocaleKeys.historyFieldStatus);
    default:
      return context.t(LocaleKeys.historyFieldResource);
  }
}

/// 选中 commit 的明细：元信息 + 资源级 diff 列表 + 回滚/恢复操作。
class CommitDetail extends ConsumerWidget {
  const CommitDetail({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.commit,
    this.resourceId,
    this.onClose,
  });

  final String databasePath;
  final String novelId;
  final ChangeCommit commit;
  final String? resourceId;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final scopedResourceId = resourceId;
    // 剧本元素里只存 character_id，渲染成角色行需要这张表；未加载时先按空表
    // 渲染（退化成显示 id），加载完成后自然重建。
    final characterNames = {
      for (final profile
          in ref.watch(characterProfilesProvider(databasePath)).value ??
              const <CharacterProfile>[])
        profile.id: profile.name,
    };
    final itemsAsync = ref.watch(
      scopedResourceId == null
          ? changeCommitItemsProvider(path: databasePath, commitId: commit.id)
          : changeCommitResourceItemsProvider(
              path: databasePath,
              commitId: commit.id,
              resourceId: scopedResourceId,
            ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.lg,
            RevericSpacing.lg,
            RevericSpacing.lg,
            RevericSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      localizedCommitMessage(context, commit.message),
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      '${commit.source == workingChangeSourceAi ? context.t(LocaleKeys.historySourceAi) : context.t(LocaleKeys.historySourceManual)} · '
                      '${DateFormat.yMd().add_Hm().format(commit.createdAt.toLocal())}',
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              if (scopedResourceId != null) ...[
                const SizedBox(width: RevericSpacing.md),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HistoryCommitActionButton(
                      novelId: novelId,
                      databasePath: databasePath,
                      resourceId: scopedResourceId,
                      commitId: commit.id,
                      action: HistoryCommitAction.rollback,
                      onClose: onClose,
                    ),
                    const SizedBox(width: RevericSpacing.xs),
                    HistoryCommitActionButton(
                      novelId: novelId,
                      databasePath: databasePath,
                      resourceId: scopedResourceId,
                      commitId: commit.id,
                      action: HistoryCommitAction.restore,
                      onClose: onClose,
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(width: RevericSpacing.md),
                Flexible(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: HistoryCommitActionButton(
                      novelId: novelId,
                      databasePath: databasePath,
                      commitId: commit.id,
                      action: HistoryCommitAction.rollback,
                      onClose: onClose,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        Divider(height: 1, color: colors.borderSubtle),
        Expanded(
          child: itemsAsync.when(
            data: (items) {
              if (items.isEmpty) {
                return Center(
                  child: Text(
                    context.t(LocaleKeys.historyEmpty),
                    style: typo.uiMedium.copyWith(color: colors.textMuted),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(RevericSpacing.lg),
                itemCount: items.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: RevericSpacing.md),
                itemBuilder: (context, index) => CommitItemTile(
                  item: items[index],
                  characterNames: characterNames,
                ),
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
    );
  }
}

enum HistoryCommitAction { rollback, restore }

class HistoryCommitActionButton extends ConsumerStatefulWidget {
  const HistoryCommitActionButton({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.commitId,
    required this.action,
    this.resourceId,
    this.onClose,
  });

  final String databasePath;
  final String novelId;
  final String? resourceId;
  final String commitId;
  final HistoryCommitAction action;
  final VoidCallback? onClose;

  @override
  ConsumerState<HistoryCommitActionButton> createState() =>
      _HistoryCommitActionButtonState();
}

class _HistoryCommitActionButtonState
    extends ConsumerState<HistoryCommitActionButton> {
  bool _running = false;

  Future<void> _confirmAndRun() async {
    final confirmed = await showRevericDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final titleKey = switch (widget.action) {
          HistoryCommitAction.rollback =>
            LocaleKeys.historyRollbackConfirmTitle,
          HistoryCommitAction.restore => LocaleKeys.historyRevertConfirmTitle,
        };
        final messageKey = switch (widget.action) {
          HistoryCommitAction.rollback =>
            widget.resourceId == null
                ? LocaleKeys.historyRollbackCommitConfirmMessage
                : LocaleKeys.historyRollbackConfirmMessage,
          HistoryCommitAction.restore => LocaleKeys.historyRevertConfirmMessage,
        };
        final actionKey = switch (widget.action) {
          HistoryCommitAction.rollback =>
            LocaleKeys.historyRollbackConfirmAction,
          HistoryCommitAction.restore => LocaleKeys.historyRevertConfirmAction,
        };
        return ConfirmDialog(
          title: context.t(titleKey),
          message: context.t(messageKey),
          confirmLabel: context.t(actionKey),
          cancelLabel: context.t(LocaleKeys.commonCancel),
          variant: ConfirmDialogVariant.warning,
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _running = true);
    try {
      final service = ref
          .read(workingOverlayServiceProvider(widget.databasePath))
          .forNovel(widget.novelId);
      final result = switch (widget.action) {
        HistoryCommitAction.rollback => await service.rollbackCommit(
          commitId: widget.commitId,
          resourceId: widget.resourceId,
        ),
        HistoryCommitAction.restore => await service.restoreResourceToCommit(
          resourceId: widget.resourceId!,
          commitId: widget.commitId,
        ),
      };
      if (!mounted) {
        return;
      }

      final message = _messageForResult(context, result);
      final messenger =
          result == RestoreResourceResult.restored && widget.onClose != null
          ? DialogFeedback.hostMessengerOf(context)
          : ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(content: Text(message)));
      if (result == RestoreResourceResult.restored) {
        widget.onClose?.call();
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  String _messageForResult(BuildContext context, RestoreResourceResult result) {
    return switch (widget.action) {
      HistoryCommitAction.rollback => switch (result) {
        RestoreResourceResult.restored => context.t(
          LocaleKeys.historyRollbackSuccess,
        ),
        RestoreResourceResult.partiallyRestored => context.t(
          LocaleKeys.historyRestorePartial,
        ),
        RestoreResourceResult.skipped => context.t(
          LocaleKeys.historyRestoreSkipped,
        ),
        RestoreResourceResult.alreadyAtVersion => context.t(
          LocaleKeys.historyRollbackAlreadyApplied,
        ),
        RestoreResourceResult.commitNotFound || RestoreResourceResult.failed =>
          context.t(LocaleKeys.historyRollbackFailed),
      },
      HistoryCommitAction.restore => switch (result) {
        RestoreResourceResult.restored => context.t(
          LocaleKeys.historyRevertSuccess,
        ),
        RestoreResourceResult.partiallyRestored => context.t(
          LocaleKeys.historyRestorePartial,
        ),
        RestoreResourceResult.skipped => context.t(
          LocaleKeys.historyRestoreSkipped,
        ),
        RestoreResourceResult.alreadyAtVersion => context.t(
          LocaleKeys.historyRevertAlreadyAtVersion,
        ),
        RestoreResourceResult.commitNotFound || RestoreResourceResult.failed =>
          context.t(LocaleKeys.historyRevertFailed),
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final icon = switch (widget.action) {
      HistoryCommitAction.rollback => RevericIcons.undo,
      HistoryCommitAction.restore => RevericIcons.history_rounded,
    };
    final labelKey = switch (widget.action) {
      HistoryCommitAction.rollback => LocaleKeys.historyRollbackConfirmAction,
      HistoryCommitAction.restore => LocaleKeys.historyRevertConfirmAction,
    };
    final tooltipKey = switch (widget.action) {
      HistoryCommitAction.rollback =>
        widget.resourceId == null
            ? LocaleKeys.historyRollbackCommitConfirmMessage
            : LocaleKeys.historyRollbackConfirmMessage,
      HistoryCommitAction.restore => LocaleKeys.historyRevertConfirmMessage,
    };

    return Tooltip(
      message: context.t(tooltipKey),
      waitDuration: const Duration(milliseconds: 400),
      child: TextButton.icon(
        onPressed: _running ? null : _confirmAndRun,
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.sm,
            vertical: RevericSpacing.xs,
          ),
          foregroundColor: colors.accentWarm,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: _running
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.textSecondary,
                ),
              )
            : RevericIcon(icon, size: 14),
        label: Text(
          context.t(labelKey),
          style: typo.uiSmall.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class CommitItemTile extends StatelessWidget {
  const CommitItemTile({
    super.key,
    required this.item,
    this.characterNames = const <String, String>{},
  });

  final ChangeCommitItem item;

  /// 人物 id → 名字，供剧本元素渲染还原角色行；未加载时传空表即可。
  final Map<String, String> characterNames;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final texts = renderChangeFieldDiff(
      resourceType: item.resourceType,
      field: item.field,
      oldRaw: item.oldText,
      newRaw: item.newText,
      characterNames: characterNames,
    );
    final delta = lineDelta(texts.oldText, texts.newText);
    final field = item.field?.trim();
    final fieldLabel = field != null && field.isNotEmpty
        ? changeFieldLabel(context, item.resourceType, field) ?? field
        : item.resourceType;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.md,
              vertical: RevericSpacing.sm,
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
                  child: SelectableText(
                    item.resourcePath,
                    style: typo.uiSmall.copyWith(color: colors.textSecondary),
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: RevericSpacing.sm),
                SelectableText(
                  fieldLabel,
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
                ),
                const SizedBox(width: RevericSpacing.sm),
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
          ),
        ],
      ),
    );
  }
}
