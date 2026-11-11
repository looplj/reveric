// 职责: 回收站设置区 — 列出已删除的作品及剩余保留天数，并提供恢复入口。
// 关联文件:
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/services/storage_cleanup/deleted_works.dart
//   lib/shared/widgets/settings/settings_section_widgets.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/data-deletion.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_button.dart';
import '../../database/app_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/content_kind.dart';
import '../../providers/novel_providers.dart';
import '../../providers/settings_providers.dart';
import '../../services/novel_actions.dart' show NovelTitleConflictException;
import '../../theme/theme.dart';
import '../novel/screenplay_kind_mark.dart';
import 'settings_section_widgets.dart';

class TrashSettingsSection extends ConsumerWidget {
  const TrashSettingsSection({super.key, this.compact = false});

  /// 移动端子页使用更紧凑的留白。
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final deleted = ref.watch(deletedNovelsProvider);
    // 与历史、会话清理共用「数据保留时间」设置。
    final retentionDays = ref.watch(changeRecordRetentionDaysProvider);
    final muted = typo.uiSmall.copyWith(color: colors.textMuted);

    Widget placeholder(String text) => SettingsCard(
      padding: const EdgeInsets.all(RevericSpacing.x3l),
      children: [Center(child: Text(text, style: muted))],
    );

    // 提示在区块层发出：恢复成功后列表行会立刻消失，行自己的 context 来不及用。
    Future<void> restore(Novel work) async {
      final messenger = ScaffoldMessenger.of(context);
      String messageKey;
      Map<String, String> args;
      try {
        await ref.read(novelActionsProvider).restoreNovel(work.id);
        messageKey = LocaleKeys.settingsTrashRestoreSuccess;
        args = {'title': work.title};
      } on NovelTitleConflictException catch (error) {
        messageKey = LocaleKeys.libraryDuplicateName;
        args = {'name': error.title};
      } catch (_) {
        messageKey = LocaleKeys.settingsTrashRestoreFailed;
        args = const {};
      }
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t(messageKey, namedArgs: args))),
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.all(
        compact ? RevericSpacing.x3l : RevericSpacing.x4l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t(LocaleKeys.settingsTrash), style: typo.heading2),
          SizedBox(height: compact ? RevericSpacing.xs : RevericSpacing.sm),
          Text(
            context.t(
              LocaleKeys.settingsTrashDescription,
              namedArgs: {'days': '$retentionDays'},
            ),
            style: muted,
          ),
          SizedBox(height: compact ? RevericSpacing.xl : RevericSpacing.x2l),
          deleted.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) =>
                placeholder(context.t(LocaleKeys.settingsTrashLoadFailed)),
            data: (works) => works.isEmpty
                ? placeholder(context.t(LocaleKeys.settingsTrashEmpty))
                : SettingsCard(
                    padding: EdgeInsets.zero,
                    children: [
                      for (var i = 0; i < works.length; i++) ...[
                        if (i > 0) const SettingsRowDivider(),
                        _TrashRow(
                          key: ValueKey(works[i].id),
                          work: works[i],
                          retentionDays: retentionDays,
                          onRestore: restore,
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _TrashRow extends HookWidget {
  const _TrashRow({
    super.key,
    required this.work,
    required this.retentionDays,
    required this.onRestore,
  });

  final Novel work;
  final int retentionDays;
  final Future<void> Function(Novel work) onRestore;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final restoring = useState(false);

    final deletedAt = work.deletedAt.toLocal();
    final remaining = deletedAt
        .add(Duration(days: retentionDays))
        .difference(DateTime.now());
    final daysLeft = (remaining.inHours / 24).ceil();
    final subtitle = [
      context.t(
        LocaleKeys.settingsTrashDeletedAt,
        namedArgs: {'date': DateFormat.yMd().add_Hm().format(deletedAt)},
      ),
      daysLeft > 1
          ? context.t(
              LocaleKeys.settingsTrashDaysLeft,
              namedArgs: {'days': '$daysLeft'},
            )
          : context.t(LocaleKeys.settingsTrashPurgeSoon),
    ].join(' · ');

    Future<void> restore() async {
      restoring.value = true;
      try {
        await onRestore(work);
      } finally {
        if (context.mounted) {
          restoring.value = false;
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.lg,
        vertical: RevericSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (work.contentKind != contentKindNovel) ...[
                      ScreenplayKindMark(contentKind: work.contentKind),
                      const SizedBox(width: RevericSpacing.xs),
                    ],
                    Flexible(
                      child: Text(
                        work.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSemibold.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: RevericSpacing.xxs),
                Text(
                  subtitle,
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: RevericSpacing.lg),
          RevericButton.secondary(
            label: context.t(LocaleKeys.commonRestore),
            icon: RevericIcons.undo,
            size: RevericButtonSize.compact,
            loading: restoring.value,
            onPressed: restoring.value ? null : restore,
          ),
        ],
      ),
    );
  }
}
