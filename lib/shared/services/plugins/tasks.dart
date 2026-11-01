// 职责: 在前台按持久计划调度插件任务，限制并发、合并手动触发并管理取消与重试。
// 关联文件:
//   lib/shared/database/daos/plugin_task_dao.dart
//   lib/shared/models/plugin/task.dart
//   lib/shared/services/plugins/host.dart
import 'dart:async';
import 'dart:math';
import 'package:uuid/uuid.dart';
import '../../agent/agent_tool_dispatcher.dart';
import '../../database/app_database.dart';
import '../../database/daos/plugin_task_dao.dart';
import '../../logger/app_logger.dart';
import '../../models/plugin/task.dart';
import 'runtime.dart';

final _log = AppLogger.forModule('PluginTasks');

/// Host API 错误码中，只有用户改配置或授权后才会恢复的失败；重试只会得到同样结果。
const pluginTaskNonRetryableCodes = {
  'model_not_configured',
  'model_not_found',
  'permission_denied',
  'database_not_declared',
};

typedef PluginTaskResult = ({String? summary, Map<String, dynamic>? usage});

class PluginTaskExecutionError extends PluginHostError {
  PluginTaskExecutionError(super.code, super.message, {this.usage});
  final Map<String, dynamic>? usage;
}

class PluginTaskRun {
  const PluginTaskRun({
    required this.runId,
    required this.trigger,
    required this.scheduledAt,
  });
  final String runId, trigger;
  final DateTime scheduledAt;
  Map<String, dynamic> toJson() => {
    'runId': runId,
    'trigger': trigger,
    'scheduledAt': scheduledAt.millisecondsSinceEpoch,
  };
}

typedef PluginTaskRunner =
    Future<PluginTaskResult> Function(
      PluginTaskDefinition definition,
      PluginTaskRun run,
      AgentCancellationToken cancellation,
    );

class PluginTaskScheduler {
  PluginTaskScheduler({
    required this.dao,
    required this.run,
    required this.canRun,
    this.onChanged,
    DateTime Function()? clock,
    Duration Function()? jitter,
    this.autoTick = true,
    this.runBudget = const Duration(minutes: 5),
  }) : clock = clock ?? DateTime.now,
       jitter =
           jitter ?? (() => Duration(milliseconds: Random().nextInt(30001)));
  final PluginTaskDao dao;
  final PluginTaskRunner run;
  final bool Function(PluginTaskDefinition) canRun;
  final void Function()? onChanged;
  final DateTime Function() clock;
  final Duration Function() jitter;
  final bool autoTick;
  final Duration runBudget;
  final _definitions = <String, PluginTaskDefinition>{};
  final _active = <String, _TaskExecution>{};
  final _starting = <String>{};
  final _startsDone = <String, Completer<void>>{};
  final _cancelledStarts = <String>{};
  final _manual = <String>{};
  Completer<void> _pumpDone = Completer<void>()..complete();
  Timer? _timer;
  bool _foreground = true,
      _started = false,
      _disposed = false,
      _pumping = false;
  String _key(String plugin, String task) => '$plugin/$task';
  PluginTaskDefinition? definition(String plugin, String task) =>
      _definitions[_key(plugin, task)];
  bool pending(String plugin, String task) =>
      _active.containsKey(_key(plugin, task)) ||
      _starting.contains(_key(plugin, task)) ||
      _manual.contains(_key(plugin, task));
  bool running(String plugin, String task) =>
      _active.containsKey(_key(plugin, task));
  Future<void> initialize() => dao.recoverLeases(clock());
  Future<void> register(
    String plugin,
    List<PluginTaskDefinition> definitions,
  ) async {
    await stopPlugin(plugin);
    await dao.synchronize(plugin, definitions, clock());
    for (final definition in definitions) {
      _definitions[_key(plugin, definition.id)] = definition;
    }
  }

  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    if (autoTick) {
      _timer = Timer.periodic(const Duration(seconds: 15), (_) => kick());
    }
    await _deferOverdue();
    kick();
  }

  void kick() {
    if (!_disposed) {
      unawaited(tick());
    }
  }

  Future<void> _deferOverdue() async {
    final now = clock();
    for (final row in await dao.due(now)) {
      final def = definition(row.pluginId, row.taskId);
      if (def != null && canRun(def)) {
        await dao.defer(row, now.add(jitter()), now);
      }
    }
  }

  Future<void> setForeground(bool visible) async {
    if (_foreground == visible || _disposed) {
      return;
    }
    _foreground = visible;
    if (!visible) {
      _cancelledStarts.addAll(_starting);
      final runs = _active.values.toList();
      for (final run in runs) {
        run.cancel('background');
      }
      await Future.wait([
        ...runs.map((r) => r.finished.future),
        ..._startsDone.values.map((c) => c.future),
      ]);
    } else {
      await _deferOverdue();
      kick();
    }
  }

  Future<void> runNow(String plugin, String task) async {
    final key = _key(plugin, task), def = _definitions[_key(plugin, task)];
    if (_disposed || !_foreground || def == null || !canRun(def)) {
      throw PluginHostError(
        'unavailable',
        'Task cannot run in the current state',
      );
    }
    if (pending(plugin, task)) {
      return;
    }
    _manual.add(key);
    onChanged?.call();
    await tick();
  }

  Future<void> setEnabled(String plugin, String task, bool enabled) async {
    await dao.setEnabled(plugin, task, enabled, clock());
    if (!enabled) {
      await cancel(plugin, task);
    }
    onChanged?.call();
    if (enabled) {
      kick();
    }
  }

  Future<void> cancel(String plugin, String task) async {
    final key = _key(plugin, task);
    _manual.remove(key);
    if (_starting.contains(key)) {
      _cancelledStarts.add(key);
    }
    final active = _active[key];
    active?.cancel('cancelled');
    await active?.finished.future;
    await _startsDone[key]?.future;
    onChanged?.call();
  }

  Future<void> stopPlugin(String plugin) async {
    _definitions.removeWhere((_, def) => def.pluginId == plugin);
    await suspendPlugin(plugin);
  }

  /// Cancel executions while retaining definitions and persisted user schedules.
  Future<void> suspendPlugin(String plugin) async {
    _cancelledStarts.addAll(
      _starting.where((key) => key.startsWith('$plugin/')),
    );
    _manual.removeWhere((key) => key.startsWith('$plugin/'));
    final runs = _active.values
        .where((r) => r.definition.pluginId == plugin)
        .toList();
    for (final run in runs) {
      run.cancel('plugin_changed');
    }
    await Future.wait([
      ...runs.map((r) => r.finished.future),
      ..._startsDone.entries
          .where((e) => e.key.startsWith('$plugin/'))
          .map((e) => e.value.future),
    ]);
    onChanged?.call();
  }

  Future<void> tick() async {
    if (!_started || !_foreground || _disposed) {
      return;
    }
    if (_pumping) {
      await _pumpDone.future;
      await tick();
      return;
    }
    _pumping = true;
    _pumpDone = Completer<void>();
    try {
      while (_active.length < 2 && _foreground && !_disposed) {
        final now = clock();
        final rows = {
          for (final row in await dao.due(now))
            _key(row.pluginId, row.taskId): row,
        };
        for (final key in _manual.toList()) {
          final def = _definitions[key];
          if (def == null) {
            _manual.remove(key);
            continue;
          }
          final row = await dao.get(def.pluginId, def.id);
          if (row != null) {
            rows[key] = row;
          }
        }
        final candidates =
            rows.values.where((row) {
              final key = _key(row.pluginId, row.taskId),
                  def = _definitions[_key(row.pluginId, row.taskId)];
              return def != null &&
                  canRun(def) &&
                  !_active.containsKey(key) &&
                  !_starting.contains(key) &&
                  !_active.values.any(
                    (r) => r.definition.pluginId == row.pluginId,
                  ) &&
                  row.deletedAt == notDeletedSentinel;
            }).toList()..sort((a, b) {
              final first =
                  (_manual.contains(_key(a.pluginId, a.taskId))
                          ? now
                          : a.nextDueAt)
                      .compareTo(
                        _manual.contains(_key(b.pluginId, b.taskId))
                            ? now
                            : b.nextDueAt,
                      );
              if (first != 0) {
                return first;
              }
              final plugin = a.pluginId.compareTo(b.pluginId);
              return plugin != 0 ? plugin : a.taskId.compareTo(b.taskId);
            });
        if (candidates.isEmpty) {
          break;
        }
        final row = candidates.first,
            key = _key(row.pluginId, row.taskId),
            def = _definitions[_key(row.pluginId, row.taskId)]!;
        final manual = _manual.contains(key);
        final retry =
            !manual &&
            const {'retrying', 'interrupted'}.contains(row.lastStatus) &&
            row.runId != null;
        final runId = retry ? row.runId! : const Uuid().v4(),
            attempt = retry ? row.attempt + 1 : 1;
        _starting.add(key);
        _startsDone[key] = Completer<void>();
        try {
          if (!await dao.claim(
            row,
            runId: runId,
            attempt: attempt,
            now: now,
            manual: manual,
          )) {
            _manual.remove(key);
            break;
          }
          final latest = await dao.get(row.pluginId, row.taskId);
          if (_cancelledStarts.contains(key) ||
              _disposed ||
              !_foreground ||
              _definitions[key] != def ||
              !canRun(def) ||
              (!manual && latest?.enabled != true)) {
            await dao.finish(
              row,
              runId: runId,
              now: clock(),
              nextDueAt: clock().add(Duration(minutes: def.intervalMinutes)),
              status: 'cancelled',
              errorCode: 'cancelled',
            );
            _manual.remove(key);
            continue;
          }
          final execution = _TaskExecution(
            def,
            row,
            PluginTaskRun(
              runId: runId,
              trigger: manual ? 'manual' : 'scheduled',
              scheduledAt: manual ? now : row.nextDueAt,
            ),
            attempt,
          );
          _manual.remove(key);
          _active[key] = execution;
          onChanged?.call();
          unawaited(_execute(key, execution));
        } finally {
          _starting.remove(key);
          _cancelledStarts.remove(key);
          _startsDone.remove(key)?.complete();
        }
      }
    } catch (error, stack) {
      _log.error('Task dispatch failed', error: error, stackTrace: stack);
    } finally {
      _pumping = false;
      _pumpDone.complete();
    }
  }

  Future<void> _execute(String key, _TaskExecution execution) async {
    String status = 'success';
    String? errorCode, summary;
    Map<String, dynamic>? usage;
    try {
      try {
        final result =
            await run(
              execution.definition,
              execution.run,
              execution.cancellation.token,
            ).timeout(
              runBudget,
              onTimeout: () {
                execution.cancellation.cancel();
                throw PluginHostError(
                  'plugin_timeout',
                  'Task exceeded its total execution budget',
                );
              },
            );
        summary = result.summary;
        usage = result.usage;
      } catch (error, stack) {
        if (error is PluginTaskExecutionError) {
          usage = error.usage;
        }
        if (execution.cancelReason == null) {
          errorCode = error is PluginHostError
              ? error.code
              : error is PluginExecutionError
              ? error.code
              : 'task_failed';
          status =
              execution.attempt <= 3 &&
                  !pluginTaskNonRetryableCodes.contains(errorCode)
              ? 'retrying'
              : 'failed';
          _log.error(
            'Task failed plugin=${execution.definition.pluginId} task=${execution.definition.id} run=${execution.run.runId}',
            error: error,
            stackTrace: stack,
          );
        }
      }
      if (execution.cancelReason != null) {
        status = 'cancelled';
        errorCode = execution.cancelReason;
      }
      final now = clock();
      final delay = status == 'retrying'
          ? const [1, 5, 15][execution.attempt - 1]
          : execution.definition.intervalMinutes;
      await dao.finish(
        execution.row,
        runId: execution.run.runId,
        now: now,
        nextDueAt: now.add(Duration(minutes: delay)),
        status: status,
        summary: summary,
        errorCode: errorCode,
        usage: usage,
      );
    } catch (error, stack) {
      _log.error(
        'Task completion could not be persisted run=${execution.run.runId}',
        error: error,
        stackTrace: stack,
      );
    } finally {
      _active.remove(key);
      execution.finished.complete();
      onChanged?.call();
      kick();
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _timer?.cancel();
    _manual.clear();
    final runs = _active.values.toList();
    for (final execution in runs) {
      execution.cancel('shutdown');
    }
    await Future.wait([
      ...runs.map((r) => r.finished.future),
      ..._startsDone.values.map((c) => c.future),
    ]);
  }
}

class _TaskExecution {
  _TaskExecution(this.definition, this.row, this.run, this.attempt);
  final PluginTaskDefinition definition;
  final PluginTask row;
  final PluginTaskRun run;
  final int attempt;
  final cancellation = AgentCancellationController();
  final finished = Completer<void>();
  String? cancelReason;
  void cancel(String reason) {
    cancelReason ??= reason;
    cancellation.cancel();
  }
}
