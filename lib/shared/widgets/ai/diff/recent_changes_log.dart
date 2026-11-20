// 职责: 最近 AI 变更日志（两端共用）— resolve 标题、改动类型标签、逐条/全部回退（恢复历史目标）。
// 关联文件:
//   lib/shared/services/working_overlay.dart
//   lib/shared/services/working_change_summary.dart
//   lib/shared/widgets/ai/diff/change_labels.dart
//   lib/desktop/widgets/ai/diff/pending_changes_summary_card.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../database/novel_content_database.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/novel_workspace.dart';
import '../../../providers/novel_providers.dart';
import '../../../providers/workspace_navigation_provider.dart';
import '../../../services/novel_content.dart';
import '../../../services/working_change_summary.dart';
import '../../../services/working_overlay.dart';
import '../../../theme/theme.dart';
import 'change_labels.dart';
import '../../../utils/resource_path.dart';
import '../../../logger/app_logger.dart';
import 'resource_type_tag.dart';

/// 同步统计变更分组数（按 resourceType + resourceId/path 归并），供头部计数使用，
/// 无需异步 resolve 标题。
int countChangeGroups(List<WorkingChange> changes) {
  final keys = <String>{};
  for (final change in changes) {
    keys.add(
      '${change.resourceType}:${change.resourceId ?? canonicalResourcePath(change.resourcePath)}',
    );
  }
  return keys.length;
}

/// 最近 AI 变更列表 + 逐条/全部回退（恢复历史目标）。
/// 桌面内嵌于摘要卡展开区（[bounded] = true，固定高度滚动）；
/// 移动端内嵌于 review sheet（[bounded] = false，随父滚动）。
class RecentChangesLog extends ConsumerStatefulWidget {
  const RecentChangesLog({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.changes,
    this.showRollbackAll = true,
    this.bounded = true,
    this.enableNavigation = false,
  });

  final String databasePath;
  final String novelId;
  final List<WorkingChange> changes;
  final bool showRollbackAll;
  final bool bounded;

  /// 仅桌面 host 开启：开启后点击条目跳转到工作区对应资源（写 [workspaceNavigationProvider]）。
  final bool enableNavigation;

  @override
  ConsumerState<RecentChangesLog> createState() => _RecentChangesLogState();
}

class _RecentChangesLogState extends ConsumerState<RecentChangesLog> {
  static const int _maxVisibleChangeRows = 3;
  static const double _summaryChangeRowExtent = 58;
  static const double _partialChangeRowExtent = 24;

  String? _busyActionKey;
  late final ScrollController _changesScrollController;
  late Future<List<_ResolvedWorkingChange>> _resolvedChangesFuture;
  List<WorkingFieldReview>? _loadedReviews;

  bool get _isBusy => _busyActionKey != null;
  bool _isBusyAction(String key) => _busyActionKey == key;

  @override
  void initState() {
    super.initState();
    _changesScrollController = ScrollController();
    _resolvedChangesFuture = Future.value(const []);
  }

  @override
  void dispose() {
    _changesScrollController.dispose();
    super.dispose();
  }

  Future<List<_ResolvedWorkingChange>> _loadResolvedChanges(
    List<WorkingFieldReview> reviews,
  ) async {
    final service = ref.read(novelContentServiceProvider(widget.databasePath));
    final grouped = <String, List<WorkingFieldReview>>{};
    for (final change in reviews) {
      final key =
          '${change.resourceType}:${change.resourceId ?? canonicalResourcePath(change.resourcePath)}';
      grouped.putIfAbsent(key, () => <WorkingFieldReview>[]).add(change);
    }

    final resolved = <_ResolvedWorkingChange>[];
    for (final entry in grouped.entries) {
      resolved.add(await _resolveChanges(entry.value, service));
    }
    return resolved;
  }

  Future<_ResolvedWorkingChange> _resolveChanges(
    List<WorkingFieldReview> reviews,
    NovelContentService service,
  ) async {
    final changes = [for (final review in reviews) ...review.changes];
    final change = reviews.first;
    final changeType = resolveChangeTypeLabel(
      change.changeType,
      change.oldText,
      change.newText,
    );
    final fields = changes
        .map((item) => item.field)
        .whereType<String>()
        .toSet()
        .toList();
    return _ResolvedWorkingChange(
      changes: changes,
      reviews: reviews,
      title: await resolveChangeResourceTitle(changes, service),
      fields: fields,
      changeType: changeType,
      resourceType: change.resourceType,
    );
  }

  String _groupActionKey(String action, List<String> changeIds) {
    return '$action:${changeIds.join('|')}';
  }

  Future<void> _runChangeAction(
    String actionKey,
    Future<void> Function() action,
  ) async {
    if (_isBusy) {
      return;
    }
    setState(() => _busyActionKey = actionKey);
    try {
      await action();
    } catch (error, stackTrace) {
      AppLogger.forModule('RecentChangesLog').error(
        'Historical rollback failed databasePath=${widget.databasePath}',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.historyRollbackFailed))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busyActionKey = null);
      }
    }
  }

  /// 将选中改动恢复到各自的历史目标。
  Future<void> _rollback(List<WorkingFieldReview> reviews) async {
    final service = ref.read(
      workOverlayServiceProvider((
        path: widget.databasePath,
        novelId: widget.novelId,
      )),
    );
    final result = await service.rollbackFields(reviews);
    if (mounted) {
      if (result.skippedPaths.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.t(
                LocaleKeys.historyRollbackSkipped,
                namedArgs: {
                  'restored': '${result.rolledBack}',
                  'skipped': '${result.skippedPaths.length}',
                },
              ),
            ),
          ),
        );
      }
      setState(() {});
    }
  }

  double _changeListHeight(int itemCount) {
    if (itemCount <= 0) {
      return 0;
    }
    if (itemCount <= _maxVisibleChangeRows) {
      return (itemCount * _summaryChangeRowExtent) + (itemCount - 1);
    }
    return (_maxVisibleChangeRows * _summaryChangeRowExtent) +
        _partialChangeRowExtent;
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final reviews = ref.watch(
      workingFieldReviewsProvider(widget.databasePath, widget.changes),
    );
    if (reviews.value != null && !listEquals(_loadedReviews, reviews.value)) {
      _loadedReviews = reviews.value;
      _resolvedChangesFuture = _loadResolvedChanges(reviews.value!);
    }

    return FutureBuilder<List<_ResolvedWorkingChange>>(
      future: _resolvedChangesFuture,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <_ResolvedWorkingChange>[];

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (items.isNotEmpty) _buildList(items, colors),
            if (widget.showRollbackAll) ...[
              const SizedBox(height: RevericSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: _isBusy ? null : () => _rollbackAll(items),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.deletionBorder,
                    ),
                    child: _LoadingButtonLabel(
                      label: context.t(LocaleKeys.workspaceRollbackAllChanges),
                      isLoading: _isBusyAction('rollback_all'),
                      progressColor: colors.deletionBorder,
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildList(List<_ResolvedWorkingChange> items, RevericColors colors) {
    final list = ListView.separated(
      controller: widget.bounded ? _changesScrollController : null,
      shrinkWrap: !widget.bounded,
      physics: widget.bounded ? null : const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: items.length,
      separatorBuilder: (context, index) => Divider(
        height: 1,
        color: colors.borderSubtle,
        indent: RevericSpacing.x5l,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        final changeIds = item.changes.map((change) => change.id).toList();
        final rollbackKey = _groupActionKey('rollback_many', changeIds);
        return _RecentChangeRow(
          item: item,
          enabled: !_isBusy,
          isRollbacking: _isBusyAction(rollbackKey),
          onRollback: () =>
              _runChangeAction(rollbackKey, () => _rollback(item.reviews)),
          onTap: _navigationTap(item),
        );
      },
    );

    if (!widget.bounded) {
      return list;
    }
    return SizedBox(
      height: _changeListHeight(items.length),
      child: Scrollbar(
        controller: _changesScrollController,
        thumbVisibility: items.length > _maxVisibleChangeRows,
        child: list,
      ),
    );
  }

  /// 计算条目点击跳转回调。仅在 [enableNavigation]、resourceType 可映射、且能定位到目标时返回非空。
  bool get _isMobilePlatform =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  VoidCallback? _navigationTap(_ResolvedWorkingChange item) {
    if (!widget.enableNavigation) {
      return null;
    }
    final change = item.changes.first;
    final section = novelWorkspaceSectionFromAiResourceType(
      change.resourceType,
    );
    if (section == null) {
      return null;
    }
    // 移动端无对应编辑页的类型不可点：作品简介(novel)/地图(maps)/技能(skills)。
    if (_isMobilePlatform &&
        (change.resourceType == 'novel' ||
            change.resourceType == 'maps' ||
            change.resourceType == 'skills')) {
      return null;
    }
    final itemId = change.resourceId;
    // novel_description 无独立条目；其余类型需 resourceId 才能精确选中。
    if (change.resourceType != 'novel' && (itemId == null || itemId.isEmpty)) {
      return null;
    }
    return () {
      ref
          .read(workspaceNavigationProvider.notifier)
          .request(
            WorkspaceNavigationRequest(section: section, itemId: itemId),
          );
    };
  }

  Future<void> _rollbackAll(List<_ResolvedWorkingChange> items) {
    final reviews = [for (final item in items) ...item.reviews];
    return _runChangeAction('rollback_all', () => _rollback(reviews));
  }
}

class _LoadingButtonLabel extends StatelessWidget {
  const _LoadingButtonLabel({
    required this.label,
    required this.isLoading,
    required this.progressColor,
  });

  final String label;
  final bool isLoading;
  final Color progressColor;

  @override
  Widget build(BuildContext context) {
    if (!isLoading) {
      return Text(label);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: progressColor,
          ),
        ),
        const SizedBox(width: RevericSpacing.sm),
        Text(label),
      ],
    );
  }
}

class _RecentChangeRow extends StatelessWidget {
  const _RecentChangeRow({
    required this.item,
    required this.enabled,
    required this.isRollbacking,
    required this.onRollback,
    this.onTap,
  });

  final _ResolvedWorkingChange item;
  final bool enabled;
  final bool isRollbacking;
  final VoidCallback onRollback;

  /// 点击条目跳转回调（仅桌面、可定位时非空）；为空时文本区域不可点。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final subtitle = _buildSubtitle(context, item.resourceType, item.fields);
    final resourceTitle = item.title.label(context);
    final title = resourceTitle.isNotEmpty ? resourceTitle : subtitle;
    final detailSubtitle = resourceTitle.isNotEmpty ? subtitle : '';
    final isCreate = item.changeType == changeTypeCreate;
    final typeLabelKey = resourceTypeLabelKey(item.resourceType);
    final isRollbacked = item.changes.every(
      (change) =>
          change.status != workingChangeStatusActive &&
          change.status != workingChangeStatusCommitted,
    );

    final infoArea = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        RevericIcon(
          isCreate
              ? RevericIcons.add_box_outlined
              : RevericIcons.edit_note_outlined,
          size: 18,
          color: isCreate ? colors.accentWarm : colors.textMuted,
        ),
        const SizedBox(width: RevericSpacing.md),
        if (typeLabelKey != null) ...[
          ResourceTypeTag(labelKey: typeLabelKey),
          const SizedBox(width: RevericSpacing.md),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: typo.uiMedium.copyWith(
                  color: colors.textPrimary,
                  fontSize: 13,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              if (detailSubtitle.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  detailSubtitle,
                  style: typo.uiSmall.copyWith(
                    color: colors.textSubtle,
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ],
    );

    final row = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(child: infoArea),
          const SizedBox(width: RevericSpacing.md),
          _ChangeTypeTag(changeType: item.changeType),
          const SizedBox(width: RevericSpacing.sm),
          if (isRollbacked)
            Text(
              context.t(LocaleKeys.workspaceRollbackDone),
              style: typo.uiSmall.copyWith(
                color: colors.textMuted,
                fontSize: 11,
              ),
            )
          else
            _RowIconButton(
              icon: RevericIcons.undo,
              onPressed: enabled ? onRollback : null,
              tooltip: context.t(LocaleKeys.workspaceRollbackChange),
              color: colors.textMuted,
              isLoading: isRollbacking,
            ),
        ],
      ),
    );

    if (onTap == null) {
      return row;
    }
    // 整行可点：hover/splash 覆盖整行（含右侧标签与撤销按钮）。撤销按钮自带 InkWell，
    // 其点击区域优先于整行 onTap。
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.small),
        child: row,
      ),
    );
  }
}

class _ChangeTypeTag extends StatelessWidget {
  const _ChangeTypeTag({required this.changeType});

  final String changeType;

  static const _labels = {
    changeTypeCreate: LocaleKeys.commonChangeCreate,
    changeTypeRewrite: LocaleKeys.commonChangeRewrite,
    changeTypeExpand: LocaleKeys.commonChangeExpand,
    changeTypeTrim: LocaleKeys.commonChangeTrim,
  };

  static const _colors = {
    changeTypeCreate: 'accentWarm',
    changeTypeRewrite: 'accent',
    changeTypeExpand: 'additionBorder',
    changeTypeTrim: 'deletionBorder',
  };

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final labelKey = _labels[changeType] ?? LocaleKeys.commonChangeRewrite;
    final colorKey = _colors[changeType] ?? 'accent';

    Color tagColor;
    switch (colorKey) {
      case 'accentWarm':
        tagColor = colors.accentWarm;
      case 'accent':
        tagColor = colors.accent;
      case 'additionBorder':
        tagColor = colors.additionBorder;
      case 'deletionBorder':
        tagColor = colors.deletionBorder;
      default:
        tagColor = colors.accent;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(RevericRadius.small),
        color: tagColor.withValues(alpha: 0.12),
      ),
      child: Text(
        context.t(labelKey),
        style: typo.uiSmall.copyWith(color: tagColor, fontSize: 11),
      ),
    );
  }
}

String _buildSubtitle(
  BuildContext context,
  String resourceType,
  List<String> fields,
) {
  final labels = fields
      .map((field) => changeFieldLabel(context, resourceType, field))
      .whereType<String>()
      .toList();
  if (labels.isEmpty) {
    return '';
  }
  return labels.join(' / ');
}

class _RowIconButton extends StatelessWidget {
  const _RowIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    required this.color,
    required this.isLoading,
  });

  final String icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final Color color;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(RevericRadius.small),
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            child: isLoading
                ? SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: color,
                    ),
                  )
                : RevericIcon(
                    icon,
                    size: 18,
                    color: onPressed == null
                        ? color.withValues(alpha: 0.45)
                        : color,
                  ),
          ),
        ),
      ),
    );
  }
}

class _ResolvedWorkingChange {
  const _ResolvedWorkingChange({
    required this.changes,
    required this.reviews,
    required this.title,
    required this.fields,
    required this.changeType,
    required this.resourceType,
  });

  final List<WorkingChange> changes;
  final List<WorkingFieldReview> reviews;
  final ChangeResourceTitle title;
  final List<String> fields;
  final String changeType;
  final String resourceType;
}
