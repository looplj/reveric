// 职责: 为每个插件复用后台 SQLite 连接，串行排队并区分取消、等待超时与未知提交结果。
// 关联文件:
//   lib/shared/services/plugins/sqlite_worker.dart
//   lib/shared/services/plugins/sql_contract.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/database_install.dart
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import '../../agent/agent_tool_dispatcher.dart';
import '../../logger/app_logger.dart';
import 'runtime.dart';
import 'sqlite_worker.dart';

final _log = AppLogger.forModule('PluginSqlQueue');

class PluginSqliteService {
  PluginSqliteService({
    required this.root,
    this.idleTimeout = const Duration(seconds: 60),
  });
  final Directory root;
  final Duration idleTimeout;
  final _sessions = <String, _SqlWorkerSession>{};
  final _paused = <String>{};
  bool _disposed = false;
  String pathFor(String id) {
    if (!RegExp(r'^[a-z0-9]+(\.[a-z0-9-]+)+$').hasMatch(id)) {
      throw PluginHostError('invalid_argument', 'Invalid plugin identity');
    }
    return p.join(root.path, 'plugin_data', id, 'data.sqlite');
  }

  _SqlWorkerSession _session(String id) {
    if (_disposed) {
      throw PluginHostError('database_closed', 'Database service is disposed');
    }
    return _sessions.putIfAbsent(
      id,
      () => _SqlWorkerSession(
        pathFor(id),
        id: id,
        idleTimeout: idleTimeout,
        onIdle: () async {
          try {
            await close(id);
          } catch (error, stack) {
            _log.error(
              'Idle database close failed plugin=$id',
              error: error,
              stackTrace: stack,
            );
          }
        },
      ),
    );
  }

  Future<Object?> call(
    String id,
    String operation,
    Map<String, dynamic> args, {
    AgentCancellationToken? cancellation,
    Duration waitBudget = const Duration(seconds: 5),
    bool readOnly = false,
  }) {
    if (_paused.contains(id)) {
      return Future.error(
        PluginHostError(
          'database_paused',
          'Plugin database is paused for maintenance',
        ),
      );
    }
    if (!const {'query', 'execute', 'transaction'}.contains(operation) ||
        (readOnly && operation != 'query')) {
      return Future.error(
        PluginHostError(
          'permission_denied',
          'SQLite operation is not allowed in this context',
        ),
      );
    }
    return _session(
      id,
    ).send(operation, args, cancellation: cancellation, waitBudget: waitBudget);
  }

  Future<void> migrate(String id, List<Map<String, Object?>> migrations) async {
    await _session(
      id,
    ).send('migrate', {'migrations': migrations}, waitBudget: null);
  }

  void pause(String id) {
    _paused.add(id);
  }

  void resume(String id) {
    _paused.remove(id);
  }

  Future<void> drain(
    String id, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    await _sessions[id]?.waitIdle(timeout);
  }

  Future<void> backup(String id, String destination) async {
    await _session(id).send('backup', {'path': destination}, waitBudget: null);
  }

  Future<void> close(
    String id, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final session = _sessions[id];
    if (session == null) {
      return;
    }
    await session.close(timeout);
    if (identical(_sessions[id], session)) {
      _sessions.remove(id);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final id in _sessions.keys.toList()) {
      await close(id, timeout: const Duration(minutes: 5));
    }
  }

  /// Host-only preparation of a staged copy, never exposed through context.sqlite.
  static Future<void> migrateStaged(
    String path,
    List<Map<String, Object?>> migrations,
  ) async {
    final worker = _SqlWorkerSession(
      path,
      id: 'staged',
      idleTimeout: const Duration(minutes: 5),
      onIdle: () async {},
    );
    try {
      await worker.send('migrate', {
        'migrations': migrations,
      }, waitBudget: null);
    } finally {
      await worker.close(const Duration(minutes: 5));
    }
  }
}

class _SqlJob {
  _SqlJob(this.id, this.operation, this.args);
  final int id;
  final String operation;
  final Map args;
  final result = Completer<Object?>();
  Timer? timer;
  void Function()? unlink;
  bool get write =>
      operation == 'execute' ||
      operation == 'transaction' ||
      operation == 'migrate';
  void detach() {
    timer?.cancel();
    unlink?.call();
    unlink = null;
  }
}

class _SqlWorkerSession {
  _SqlWorkerSession(
    String path, {
    required this.id,
    required this.idleTimeout,
    required this.onIdle,
  }) {
    _subscription = _output.listen(_receive);
    Isolate.spawn(
          pluginSqlWorker,
          {'path': path, 'output': _output.sendPort},
          onError: _output.sendPort,
          onExit: _output.sendPort,
        )
        .catchError((Object error, StackTrace stack) {
          _fail('database_open_failed', error.toString());
          throw error;
        })
        .then<void>((_) {}, onError: (Object _) {});
  }
  final String id;
  final Duration idleTimeout;
  final Future<void> Function() onIdle;
  final _output = ReceivePort();
  late final StreamSubscription<dynamic> _subscription;
  final _queue = <_SqlJob>[];
  _SqlJob? _active;
  SendPort? _input;
  Timer? _idleTimer;
  Completer<void> _idle = Completer<void>()..complete();
  bool _closed = false, _closing = false;
  int _nextId = 0;
  Future<Object?> send(
    String operation,
    Map args, {
    AgentCancellationToken? cancellation,
    Duration? waitBudget = const Duration(seconds: 5),
  }) {
    if (_closed || (_closing && operation != 'close')) {
      return Future.error(
        PluginHostError('database_closed', 'Database connection is closing'),
      );
    }
    if (_queue.length + (_active == null ? 0 : 1) >= 32) {
      return Future.error(
        PluginHostError(
          'database_busy',
          'At most 32 pending database calls are allowed',
        ),
      );
    }
    if (cancellation?.isCancellationRequested == true) {
      return Future.error(
        PluginHostError('cancelled', 'Database call cancelled before start'),
      );
    }
    _idleTimer?.cancel();
    if (_idle.isCompleted) {
      _idle = Completer<void>();
    }
    final job = _SqlJob(++_nextId, operation, args);
    _queue.add(job);
    if (waitBudget != null) {
      job.timer = Timer(waitBudget, () => _stopWaiting(job, cancelled: false));
    }
    job.unlink = cancellation?.onCancel(
      () => _stopWaiting(job, cancelled: true),
    );
    _pump();
    return job.result.future;
  }

  void _stopWaiting(_SqlJob job, {required bool cancelled}) {
    if (job.result.isCompleted) {
      return;
    }
    final queued = _queue.remove(job);
    final code = queued
        ? (cancelled ? 'cancelled' : 'wait_timeout')
        : (job.write ? 'commit_unknown' : 'wait_timeout');
    job.detach();
    job.result.completeError(
      PluginHostError(
        code,
        queued
            ? 'Database call ended before execution'
            : 'Caller stopped waiting; SQLite operation continues and must not be retried automatically',
      ),
    );
    if (queued) {
      _pump();
    }
  }

  void _pump() {
    if (_closed || _active != null) {
      return;
    }
    if (_queue.isEmpty) {
      if (!_idle.isCompleted) {
        _idle.complete();
      }
      _idleTimer?.cancel();
      if (!_closing) {
        _idleTimer = Timer(idleTimeout, () => unawaited(onIdle()));
      }
      return;
    }
    final input = _input;
    if (input == null) {
      return;
    }
    final job = _queue.removeAt(0);
    _active = job;
    input.send({'id': job.id, 'operation': job.operation, 'args': job.args});
  }

  void _receive(dynamic message) {
    if (message is Map && message['ready'] is SendPort) {
      _input = message['ready'] as SendPort;
      _pump();
      return;
    }
    if (message is! Map || message['id'] == null) {
      if (!_closed && (!_closing || _active != null)) {
        final error = message is Map ? message['error'] : message;
        _fail('database_worker_failed', error.toString());
      }
      return;
    }
    final job = _active;
    if (job == null || message['id'] != job.id) {
      _fail(
        'database_protocol_error',
        'Worker returned an unexpected request ID',
      );
      return;
    }
    _active = null;
    job.detach();
    final error = message['error'];
    if (job.result.isCompleted) {
      _log.info(
        '[DB] late completion plugin=$id request=${job.id} operation=${job.operation} outcome=${error == null ? (job.write ? 'committed' : 'completed') : 'failed'}',
      );
      if (error != null) {
        _log.error(
          '[DB] late SQLite failure plugin=$id request=${job.id}',
          error: error,
        );
      }
    } else if (error is Map) {
      job.result.completeError(
        PluginHostError(
          error['code'] as String? ?? 'database_error',
          error.toString(),
        ),
      );
    } else {
      job.result.complete(message['result']);
    }
    _pump();
  }

  void _fail(String code, String message) {
    _closed = true;
    _idleTimer?.cancel();
    final active = _active;
    final jobs = [?_active, ..._queue];
    _active = null;
    _queue.clear();
    for (final job in jobs) {
      job.detach();
      if (!job.result.isCompleted) {
        job.result.completeError(
          PluginHostError(
            job.write && identical(job, active) ? 'commit_unknown' : code,
            message,
          ),
        );
      }
    }
    if (!_idle.isCompleted) {
      _idle.complete();
    }
    unawaited(_subscription.cancel());
    _output.close();
  }

  Future<void> waitIdle(Duration timeout) async {
    try {
      await _idle.future.timeout(timeout);
    } on TimeoutException {
      throw PluginHostError(
        'database_busy',
        'Database operation is still running; connection remains open',
      );
    }
  }

  Future<void>? _closeFuture;
  Future<void> close(Duration timeout) => _closeFuture ??= _close(timeout)
      .catchError((Object error, StackTrace stack) {
        _closeFuture = null;
        Error.throwWithStackTrace(error, stack);
      });
  Future<void> _close(Duration timeout) async {
    if (_closed) {
      return;
    }
    await waitIdle(timeout);
    if (_closed || _closing) {
      return;
    }
    _closing = true;
    _idleTimer?.cancel();
    await send('close', {}, waitBudget: null);
    _closed = true;
    await _subscription.cancel();
    _output.close();
  }
}
