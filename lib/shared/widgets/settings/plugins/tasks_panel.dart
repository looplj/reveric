// 职责: 展示插件任务的持久化状态和用量，并控制暂停、恢复、运行与取消。
// 关联文件:
//   lib/shared/widgets/settings/plugins/detail_page.dart
//   lib/shared/services/plugins/tasks.dart
//   lib/shared/database/daos/plugin_task_dao.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/plugin.json
//   assets/translations/zh-CN/plugin.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:intl/intl.dart';
import '../../../components/reveric_badge.dart';
import '../../../components/reveric_button.dart';
import '../../../database/app_database.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../services/plugins/host.dart';
import '../../../theme/theme.dart';
import '../settings_section_widgets.dart';
import 'overview.dart';

final _log = AppLogger.forModule('PluginTaskSettings');

class PluginTasksPanel extends HookWidget {
  const PluginTasksPanel({
    super.key,
    required this.host,
    required this.pluginId,
  });
  final PluginHostService host;
  final String pluginId;
  @override
  Widget build(BuildContext context) {
    final stream = useMemoized(
      () => host.dao.attachedDatabase.pluginTaskDao.watchPlugin(pluginId),
      [host, pluginId],
    );
    final snapshot = useStream(stream);
    final rows = snapshot.data;
    final typo = RevericTheme.typographyOf(context);
    final colors = RevericTheme.colorsOf(context);
    return SettingsSection(
      titleKey: LocaleKeys.pluginTasks,
      child: snapshot.hasError
          ? Text(
              context.t(LocaleKeys.pluginLoadFailed),
              style: typo.uiSmall.copyWith(color: colors.warningText),
            )
          : rows == null
          ? const LinearProgressIndicator()
          : SettingsCard(
              padding: EdgeInsets.zero,
              children: [
                for (final (index, row) in rows.indexed) ...[
                  if (index > 0) const SettingsRowDivider(),
                  _TaskRow(
                    key: ValueKey('task-${row.taskId}'),
                    host: host,
                    row: row,
                  ),
                ],
              ],
            ),
    );
  }
}

class _TaskRow extends HookWidget {
  const _TaskRow({super.key, required this.host, required this.row});
  final PluginHostService host;
  final PluginTask row;
  @override
  Widget build(BuildContext context) {
    final busy = useState(false);
    final definition = host.tasks.definition(row.pluginId, row.taskId);
    final removed = row.deletedAt != notDeletedSentinel;
    final pending = host.tasks.pending(row.pluginId, row.taskId);
    final available = definition != null && !removed;
    final typo = RevericTheme.typographyOf(context);
    final colors = RevericTheme.colorsOf(context);
    String date(DateTime value) => DateFormat.yMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).add_Hm().format(value.toLocal());
    Future<void> act(Future<void> Function() callback) async {
      busy.value = true;
      try {
        await callback();
      } catch (error, stack) {
        _log.error(
          'Task action failed: ${row.pluginId}/${row.taskId}',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.pluginSaveFailed))),
          );
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    final state = removed
        ? 'removed'
        : pending
        ? 'running'
        : row.lastStatus;
    final (stateKey, stateColor) = switch (state) {
      'running' => (LocaleKeys.pluginTaskRunning, colors.accent),
      'success' => (LocaleKeys.pluginTaskSuccess, colors.success),
      'failed' => (LocaleKeys.pluginFailed, colors.warningText),
      'retrying' => (LocaleKeys.pluginTaskRetrying, colors.accentAmber),
      'cancelled' => (LocaleKeys.pluginTaskCancelled, colors.textMuted),
      'interrupted' => (LocaleKeys.pluginTaskInterrupted, colors.textMuted),
      'removed' => (LocaleKeys.pluginTaskRemoved, colors.textSubtle),
      _ => (LocaleKeys.pluginTaskReady, colors.textMuted),
    };
    final errorKey = switch (row.lastErrorCode) {
      'model_not_configured' => LocaleKeys.pluginTaskModelMissing,
      'model_not_found' => LocaleKeys.pluginTaskModelNotFound,
      'permission_denied' => LocaleKeys.pluginTaskPermissionMissing,
      'task_timeout' || 'plugin_timeout' => LocaleKeys.pluginResourceLimit,
      null || 'cancelled' || 'interrupted' => null,
      _ => LocaleKeys.pluginTaskFailed,
    };
    final schedule = [
      // 插件关闭时调度器已移除任务定义，持久化的下次时间不会触发，不再显示。
      if (available && row.enabled)
        context.t(
          LocaleKeys.pluginTaskNext,
          namedArgs: {'date': date(row.nextDueAt)},
        ),
      if (row.lastFinishedAt != null)
        context.t(
          LocaleKeys.pluginTaskFinished,
          namedArgs: {'date': date(row.lastFinishedAt!)},
        ),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.lg,
        vertical: RevericSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: RevericSpacing.sm,
            runSpacing: RevericSpacing.xxs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                definition?.title.resolve(Localizations.localeOf(context)) ??
                    row.taskId,
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
              RevericBadge(label: context.t(stateKey), color: stateColor),
              if (!row.enabled && !removed)
                RevericBadge(
                  label: context.t(LocaleKeys.pluginTaskPaused),
                  color: colors.textMuted,
                ),
            ],
          ),
          if (schedule.isNotEmpty) ...[
            const SizedBox(height: RevericSpacing.xxs),
            Text(
              schedule,
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ],
          if (row.lastSummary?.isNotEmpty == true) ...[
            const SizedBox(height: RevericSpacing.xs),
            Text(
              row.lastSummary!,
              style: typo.ui.copyWith(color: colors.textSecondary),
            ),
          ],
          if (errorKey != null) ...[
            const SizedBox(height: RevericSpacing.xs),
            PluginNotice(message: context.t(errorKey)),
          ],
          if (row.lastUsage != null) ...[
            const SizedBox(height: RevericSpacing.xxs),
            Text(
              context.t(
                LocaleKeys.pluginTaskUsage,
                namedArgs: {
                  'calls': '${row.lastUsage!['calls'] ?? 0}',
                  'input': '${row.lastUsage!['input_tokens'] ?? 0}',
                  'output': '${row.lastUsage!['output_tokens'] ?? 0}',
                },
              ),
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
          ],
          if (!removed) ...[
            const SizedBox(height: RevericSpacing.sm),
            Wrap(
              spacing: RevericSpacing.sm,
              runSpacing: RevericSpacing.xs,
              children: [
                RevericButton.secondary(
                  key: ValueKey('task-run-${row.taskId}'),
                  icon: RevericIcons.play_arrow,
                  label: context.t(LocaleKeys.commonRunNow),
                  size: RevericButtonSize.compact,
                  onPressed: busy.value || pending || !available
                      ? null
                      : () => act(
                          () => host.tasks.runNow(row.pluginId, row.taskId),
                        ),
                ),
                RevericButton.text(
                  key: ValueKey('task-toggle-${row.taskId}'),
                  label: context.t(
                    row.enabled
                        ? LocaleKeys.commonPause
                        : LocaleKeys.commonResume,
                  ),
                  size: RevericButtonSize.compact,
                  onPressed: busy.value || !available
                      ? null
                      : () => act(
                          () => host.tasks.setEnabled(
                            row.pluginId,
                            row.taskId,
                            !row.enabled,
                          ),
                        ),
                ),
                if (pending)
                  RevericButton.text(
                    key: ValueKey('task-cancel-${row.taskId}'),
                    label: context.t(LocaleKeys.commonCancel),
                    size: RevericButtonSize.compact,
                    onPressed: busy.value
                        ? null
                        : () => act(
                            () => host.tasks.cancel(row.pluginId, row.taskId),
                          ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
