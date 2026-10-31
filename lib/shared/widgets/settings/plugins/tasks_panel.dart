// 职责: 展示插件任务的持久化状态和用量，并控制暂停、恢复、运行与取消。
// 关联文件:
//   lib/shared/widgets/settings/plugins/row.dart
//   lib/shared/services/plugins/tasks.dart
//   lib/shared/database/daos/plugin_task_dao.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:intl/intl.dart';
import '../../../components/reveric_button.dart';
import '../../../database/app_database.dart';
import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../services/plugins/host.dart';
import '../../../theme/theme.dart';

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
    if (rows == null || rows.isEmpty) {
      return snapshot.hasError
          ? Text(context.t(LocaleKeys.settingsPluginsSaveFailed))
          : const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: RevericSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.t(LocaleKeys.settingsPluginsTasks),
            style: RevericTheme.typographyOf(context).uiSemibold,
          ),
          for (final row in rows)
            _TaskRow(key: ValueKey('task-${row.taskId}'), host: host, row: row),
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
            SnackBar(
              content: Text(context.t(LocaleKeys.settingsPluginsSaveFailed)),
            ),
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
    final stateKey = switch (state) {
      'running' => LocaleKeys.settingsPluginsTaskRunning,
      'success' => LocaleKeys.settingsPluginsTaskSuccess,
      'failed' => LocaleKeys.settingsPluginsTaskFailed,
      'retrying' => LocaleKeys.settingsPluginsTaskRetrying,
      'cancelled' => LocaleKeys.settingsPluginsTaskCancelled,
      'interrupted' => LocaleKeys.settingsPluginsTaskInterrupted,
      'removed' => LocaleKeys.settingsPluginsTaskRemoved,
      _ => LocaleKeys.settingsPluginsTaskReady,
    };
    final errorKey = switch (row.lastErrorCode) {
      'model_not_configured' => LocaleKeys.settingsPluginsTaskModelMissing,
      'permission_denied' => LocaleKeys.settingsPluginsNeedsPermission,
      'task_timeout' ||
      'plugin_timeout' => LocaleKeys.settingsPluginsResourceLimit,
      null || 'cancelled' || 'interrupted' => null,
      _ => LocaleKeys.settingsPluginsTaskFailed,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            definition?.title.resolve(Localizations.localeOf(context)) ??
                row.taskId,
            style: typo.uiSemibold,
          ),
          Text(
            context.t(stateKey),
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          if (!row.enabled && !removed)
            Text(
              context.t(LocaleKeys.settingsPluginsTaskPaused),
              style: typo.uiSmall,
            ),
          if (!removed && row.enabled)
            Text(
              context.t(
                LocaleKeys.settingsPluginsTaskNext,
                namedArgs: {'date': date(row.nextDueAt)},
              ),
              style: typo.uiSmall,
            ),
          if (row.lastFinishedAt != null)
            Text(
              context.t(
                LocaleKeys.settingsPluginsTaskFinished,
                namedArgs: {'date': date(row.lastFinishedAt!)},
              ),
              style: typo.uiSmall,
            ),
          if (row.lastSummary?.isNotEmpty == true)
            Text(row.lastSummary!, style: typo.ui),
          if (errorKey != null)
            Text(
              context.t(errorKey),
              style: typo.uiSmall.copyWith(color: colors.warningText),
            ),
          if (row.lastUsage != null)
            Text(
              context.t(
                LocaleKeys.settingsPluginsTaskUsage,
                namedArgs: {
                  'calls': '${row.lastUsage!['calls'] ?? 0}',
                  'input': '${row.lastUsage!['input_tokens'] ?? 0}',
                  'output': '${row.lastUsage!['output_tokens'] ?? 0}',
                },
              ),
              style: typo.uiSmall,
            ),
          if (!removed)
            Wrap(
              spacing: RevericSpacing.sm,
              children: [
                RevericButton.text(
                  key: ValueKey('task-toggle-${row.taskId}'),
                  label: context.t(
                    row.enabled
                        ? LocaleKeys.commonPause
                        : LocaleKeys.commonResume,
                  ),
                  onPressed: busy.value
                      ? null
                      : () => act(
                          () => host.tasks.setEnabled(
                            row.pluginId,
                            row.taskId,
                            !row.enabled,
                          ),
                        ),
                ),
                RevericButton.text(
                  key: ValueKey('task-run-${row.taskId}'),
                  label: context.t(LocaleKeys.commonRunNow),
                  onPressed: busy.value || pending || !available
                      ? null
                      : () => act(
                          () => host.tasks.runNow(row.pluginId, row.taskId),
                        ),
                ),
                if (pending)
                  RevericButton.text(
                    key: ValueKey('task-cancel-${row.taskId}'),
                    label: context.t(LocaleKeys.commonCancel),
                    onPressed: busy.value
                        ? null
                        : () => act(
                            () => host.tasks.cancel(row.pluginId, row.taskId),
                          ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
