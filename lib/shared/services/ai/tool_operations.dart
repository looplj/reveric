// 职责: 按会话拥有工具操作、审批、取消与一次性完成通知，释放终态执行资源。
// 关联文件:
//   lib/shared/services/tool_permission_gate.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/services/ai/tools_run.dart
//   lib/shared/services/ai/chat_turn_runner.dart
import 'dart:async';
import 'dart:convert';
import '../../agent/message.dart';
import 'files/attachments.dart';
import '../../models/ai_chat_models.dart';
import '../../agent/agent_tool_dispatcher.dart';
import '../../models/tool_permission.dart';
import '../../models/production/media.dart';
import '../../logger/app_logger.dart';
import '../../utils/random_id.dart';
import '../tool_permission_gate.dart';

final _log = AppLogger.forModule('ToolOperation');

enum ToolOperationStatus {
  waiting_approval,
  queued,
  running,
  cancelling,
  completed,
  failed,
  cancelled,
  interrupted,
}

bool toolOperationTerminal(ToolOperationStatus status) => const {
  ToolOperationStatus.completed,
  ToolOperationStatus.failed,
  ToolOperationStatus.cancelled,
  ToolOperationStatus.interrupted,
}.contains(status);

class ToolOperationRecord {
  ToolOperationRecord({
    required this.runId,
    required this.ownerSessionId,
    required this.sourceSessionId,
    required this.sourceTurnId,
    required this.callId,
    required this.workId,
    required this.kind,
    required this.targetPath,
    required this.background,
    required this.createdAt,
    this.status = ToolOperationStatus.queued,
    this.taskId,
    this.historyCallId,
    this.displayCallId,
    this.episodeId,
    this.capability,
    this.targetLabel,
    this.progress,
    this.result,
    this.diagnostic,
    this.approvalRequested = false,
  });
  final String runId,
      ownerSessionId,
      sourceSessionId,
      sourceTurnId,
      callId,
      workId,
      kind,
      targetPath;
  final bool background;
  final DateTime createdAt;
  ToolOperationStatus status;
  String? taskId;
  final String? historyCallId, displayCallId, episodeId;

  /// Permission capability declared by the command; null for operations without approval.
  String? capability;

  /// Human-readable target for activity rows; [targetPath] stays the identity.
  final String? targetLabel;

  /// True once the run waited for a user decision; only these leave a receipt.
  bool approvalRequested;
  Map<String, dynamic>? progress, result;
  String? diagnostic;
  bool get terminal => toolOperationTerminal(status);
  Map<String, dynamic> toJson() => {
    'run_id': runId,
    'owner_session_id': ownerSessionId,
    'source_session_id': sourceSessionId,
    'source_turn_id': sourceTurnId,
    'call_id': callId,
    'history_call_id': ?historyCallId,
    'display_call_id': ?displayCallId,
    'episode_id': ?episodeId,
    'capability': ?capability,
    'target_label': ?targetLabel,
    'work_id': workId,
    'kind': kind,
    'target_path': targetPath,
    'background': background,
    'status': status.name,
    'created_at': createdAt.millisecondsSinceEpoch,
    'task_id': ?taskId,
    'progress': ?progress,
    'result': ?result,
    'diagnostic': ?diagnostic,
    if (approvalRequested) 'approval_requested': true,
  };
  Map<String, dynamic> response() => {
    'ok': result?['ok'] != false,
    ...toJson(),
    if (status == ToolOperationStatus.cancelled) 'cancelled': true,
    if (background && !terminal)
      'hint': 'Use Run operations with run_id="$runId".',
    for (final key in ['error_code', 'error', 'hint'])
      if (result?[key] != null) key: result![key],
  };

  factory ToolOperationRecord.fromJson(Map<String, dynamic> json) =>
      ToolOperationRecord(
        runId: json['run_id'] as String,
        ownerSessionId: json['owner_session_id'] as String,
        sourceSessionId: json['source_session_id'] as String,
        sourceTurnId: json['source_turn_id'] as String,
        callId: json['call_id'] as String,
        historyCallId: json['history_call_id'] as String?,
        displayCallId: json['display_call_id'] as String?,
        episodeId: json['episode_id'] as String?,
        capability: json['capability'] as String?,
        targetLabel: json['target_label'] as String?,
        workId: json['work_id'] as String,
        kind: json['kind'] as String,
        targetPath: json['target_path'] as String,
        background: json['background'] as bool,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          json['created_at'] as int,
        ),
        status: ToolOperationStatus.values.byName(json['status'] as String),
        taskId: json['task_id'] as String?,
        progress: (json['progress'] as Map?)?.cast<String, dynamic>(),
        result: (json['result'] as Map?)?.cast<String, dynamic>(),
        diagnostic: json['diagnostic'] as String?,
        approvalRequested: json['approval_requested'] == true,
      );
}

class ToolOperationCompletion {
  ToolOperationCompletion(this.record)
    : messageId = buildRandomId('operation_completion');
  final ToolOperationRecord record;
  final String messageId;
  List<ImageBlock> modelImages = const [];
  String get reminder =>
      '<system-remind type="operation_completed">\nRun: ${record.runId}\nKind: ${record.kind}\nTarget: ${record.targetPath}\nStatus: ${record.status.name}\nResult: ${jsonEncode(record.result)}\n</system-remind>';
}

class ToolOperationState {
  const ToolOperationState({
    this.runs = const [],
    this.pending = const [],
    this.activeCount = 0,
  });
  final int activeCount;
  final List<ToolOperationRecord> runs;
  final List<ToolOperationCompletion> pending;
  bool get needsRetention =>
      activeCount > 0 || runs.any((r) => !r.terminal) || pending.isNotEmpty;
}

/// Shared ownership directory stores identity only, never operation resources.
class ToolOperationRegistry {
  final _changes = StreamController<ToolOperationRecord>.broadcast();
  Stream<ToolOperationRecord> get changes => _changes.stream;
  void notify(ToolOperationRecord record) => _changes.add(record);
  void dispose() => _changes.close();
  final owners = <String, String>{};
  final records = <String, ToolOperationRecord>{};
  Iterable<ToolOperationRecord> forSession(String sessionId) =>
      records.values.where((record) => record.sourceSessionId == sessionId);
}

AiMessage recoverToolOperationHistory(
  AiMessage message,
  Iterable<ToolOperationRecord> activeRecords,
) {
  final active = {for (final record in activeRecords) record.runId: record};
  return message.copyWith(
    blocks: [
      for (final block in message.blocks)
        if (block is AiToolCallBlock && block.metadata?['operations'] is List)
          block.copyWith(
            metadata: {
              ...?block.metadata,
              'operations': [
                for (final snapshot in block.metadata!['operations'] as List)
                  _recoverOperationSnapshot(
                    Map<String, dynamic>.from(snapshot as Map),
                    active,
                  ),
              ],
            },
          )
        else
          block,
    ],
  );
}

Map<String, dynamic> _recoverOperationSnapshot(
  Map<String, dynamic> snapshot,
  Map<String, ToolOperationRecord> active,
) {
  final record = ToolOperationRecord.fromJson(snapshot);
  if (active.containsKey(record.runId)) {
    return active[record.runId]!.toJson();
  }
  if (!record.terminal) {
    record.status = ToolOperationStatus.interrupted;
    record.result = {
      'ok': false,
      'error_code': 'interrupted',
      'error': 'The application stopped before this operation completed.',
    };
  }
  return record.toJson();
}

AiMessage mergeToolOperationHistory(
  AiMessage message,
  Iterable<ToolOperationRecord> records,
) {
  return message.copyWith(
    blocks: [
      for (final block in message.blocks)
        if (block is AiToolCallBlock)
          mergeToolOperationBlock(block, records)
        else
          block,
    ],
  );
}

AiToolCallBlock mergeToolOperationBlock(
  AiToolCallBlock block,
  Iterable<ToolOperationRecord> records,
) {
  final matching = records
      .where(
        (record) => (record.historyCallId ?? record.callId) == block.callId,
      )
      .toList();
  if (matching.isEmpty) {
    return block;
  }
  return block.copyWith(
    metadata: {
      ...?block.metadata,
      'operations': matching.map((record) => record.toJson()).toList(),
    },
  );
}

class ToolOperationContext {
  ToolOperationContext(
    this.cancellation,
    this.report,
    this.input, {
    this._authorize,
  });
  final Future<void> Function(ToolActionRequest, Future<void> Function())?
  _authorize;

  Future<void> authorize(
    ToolActionRequest request,
    Future<void> Function() verifyTarget,
  ) {
    final authorize = _authorize;
    if (authorize == null) {
      throw StateError('This operation cannot request additional file access.');
    }
    return authorize(request, verifyTarget);
  }

  final Map<String, dynamic> input;
  final AgentCancellationToken cancellation;
  final void Function({String? taskId, Map<String, dynamic>? progress}) report;
  void checkCancelled() {
    if (cancellation.isCancellationRequested) {
      throw const ToolOperationException(
        'cancelled',
        'The operation was cancelled.',
      );
    }
  }
}

class _ActiveOperation {
  _ActiveOperation(this.record);
  final ToolOperationRecord record;
  final cancellation = AgentCancellationController();
  final done = Completer<Map<String, dynamic>>();
  bool mayNotify = true;
  Timer? cancelTimer;
  void Function()? unlinkParent;
}

class ToolOperationManager {
  ToolOperationManager({
    required this.ownerSessionId,
    required this.registry,
    required this.gate,
    required this.onChanged,
    required this.onRecord,
    this.onFinished,
    this.cancelTimeout = const Duration(seconds: 30),
  });
  final String ownerSessionId;
  final ToolOperationRegistry registry;
  final ToolPermissionGate Function() gate;
  final void Function(ToolOperationState state) onChanged;
  final void Function(ToolOperationRecord record) onRecord;
  final Duration cancelTimeout;
  final Future<void> Function(ToolOperationRecord record)? onFinished;
  final _active = <String, _ActiveOperation>{};
  final _records = <String, ToolOperationRecord>{};
  final _pending = <String, ToolOperationCompletion>{};
  bool _disposed = false;
  bool _mutating = false;

  /// Sub-agent runs persisted in child sessions are indexed once per runtime.
  bool childHistoryRestored = false;
  ToolOperationState get state => ToolOperationState(
    activeCount: _active.length,
    runs: List.unmodifiable(_records.values),
    pending: List.unmodifiable(_pending.values),
  );
  void _publish([ToolOperationRecord? record]) {
    if (_disposed) {
      return;
    }
    if (record != null) {
      registry.records[record.runId] = record;
      registry.notify(record);
      onRecord(record);
    }
    onChanged(state);
  }

  String _caller(ToolExecutionContext context) => context.sessionId ?? '';
  void _authorizeCaller(ToolExecutionContext context, [String? runId]) {
    if ((_caller(context) != ownerSessionId &&
            context.operationOwnerSessionId != ownerSessionId) ||
        (runId != null &&
            registry.owners[runId] != null &&
            registry.owners[runId] != ownerSessionId)) {
      throw const ToolPermissionException(
        'permission_denied',
        'This operation belongs to another session.',
      );
    }
  }

  ToolOperationRecord _require(String id, ToolExecutionContext context) {
    _authorizeCaller(context, id);
    final record = _records[id];
    if (record == null) {
      throw const ToolOperationException(
        'not_found',
        'The operation does not exist.',
      );
    }
    if (record.sourceSessionId != _caller(context) &&
        !(_caller(context) == ownerSessionId &&
            context.operationOwnerSessionId == ownerSessionId)) {
      throw const ToolPermissionException(
        'permission_denied',
        'This operation belongs to another session.',
      );
    }
    return record;
  }

  /// Register synchronously; all async validation, approval and execution follow registration.
  Future<Map<String, dynamic>> start({
    required ToolExecutionContext context,
    required String callId,
    required String workId,
    required String kind,
    required String targetPath,
    required String toolName,
    required bool background,
    required Future<Map<String, dynamic>> Function(ToolOperationContext context)
    execute,
    required Future<void> Function() verifyTarget,
    Map<String, dynamic> input = const {},
    String? targetLabel,
    ToolActionRequest? permission,
    Future<void> Function()? release,
  }) {
    _authorizeCaller(context);
    if (permission != null &&
        !toolPermissionActions.contains(permission.action)) {
      throw const ToolOperationException(
        'failed_precondition',
        'This operation declares an unregistered permission.',
      );
    }
    // A nested command has not reached execution while it is awaiting approval.
    context.lifecycleObserver?.onStarted?.call({
      'codemode_effect_started': false,
    });
    final frozenInput = freezeToolArguments(input);
    if (_disposed ||
        _mutating ||
        callId.isEmpty ||
        (context.sourceTurnId == null || context.sourceTurnId!.isEmpty)) {
      throw const ToolOperationException(
        'failed_precondition',
        'The session cannot start an operation.',
      );
    }
    if (permission != null &&
        (permission.context.workId != workId ||
            permission.targetPath != targetPath)) {
      throw const FormatException(
        'Permission target does not match the operation.',
      );
    }
    final record = ToolOperationRecord(
      runId: buildRandomId('run'),
      ownerSessionId: ownerSessionId,
      sourceSessionId: context.sessionId ?? ownerSessionId,
      sourceTurnId: context.sourceTurnId!,
      callId: callId,
      historyCallId: context.parentToolCallId,
      displayCallId:
          context.approvalHostCallId ?? context.parentToolCallId ?? callId,
      episodeId: permission?.context.episodeId,
      capability: permission?.action,
      targetLabel: permission?.targetLabel ?? targetLabel,
      workId: workId,
      kind: kind,
      targetPath: targetPath,
      background: background,
      createdAt: DateTime.now(),
    );
    final active = _ActiveOperation(record)..mayNotify = background;
    _active[record.runId] = active;
    _records[record.runId] = record;
    registry.owners[record.runId] = ownerSessionId;
    _publish(record);
    if (!background) {
      active.unlinkParent = context.cancellationToken?.onCancel(
        () => _cancel(active),
      );
    }
    unawaited(
      Future<void>(() async {
        Map<String, dynamic> result;
        try {
          Future<void> authorize(
            ToolActionRequest request,
            Future<void> Function() verify,
          ) async {
            if (!toolPermissionActions.contains(request.action) ||
                request.context.workId != workId ||
                request.targetPath != targetPath) {
              throw const FormatException(
                'Permission target does not match the operation.',
              );
            }
            record.capability = request.action;
            await gate().authorize(
              request: request,
              ownerSessionId: ownerSessionId,
              approvalId: record.runId,
              callId: callId,
              displayCallId: record.displayCallId,
              toolName: toolName,
              cancellation: active.cancellation.token,
              verifyTarget: verify,
              onWaiting: (_) {
                if (active.cancellation.token.isCancellationRequested) {
                  return;
                }
                record
                  ..status = ToolOperationStatus.waiting_approval
                  ..approvalRequested = true;
                _publish(record);
              },
            );
            if (!record.terminal) {
              record.status = ToolOperationStatus.running;
              _publish(record);
            }
          }

          if (permission != null) {
            await authorize(permission, verifyTarget);
          } else {
            await verifyTarget();
          }
          final execution = ToolOperationContext(
            active.cancellation.token,
            ({taskId, progress}) {
              if (record.terminal) {
                return;
              }
              record.taskId = taskId ?? record.taskId;
              record.progress = progress == null
                  ? record.progress
                  : freezeToolArguments(progress);
              _publish(record);
            },
            frozenInput,
            authorize: authorize,
          );
          execution.checkCancelled();
          record.status = ToolOperationStatus.running;
          _publish(record);
          context.lifecycleObserver?.onStarted?.call({
            'codemode_effect_started': true,
          });
          result = await execute(execution);
        } on MediaException catch (error, stack) {
          _log.error(
            'media failed run=${record.runId} '
            'kind=${record.kind} stage=${record.progress?['stage'] ?? 'execute'}',
            error: error,
            stackTrace: stack,
          );
          final reason = active.cancellation.token.isCancellationRequested
              ? MediaFailure.cancelled
              : error.reason;
          result = {
            'ok': false,
            'error_code': reason.name,
            'error':
                error.message ??
                switch (reason) {
                  MediaFailure.invalid_media => 'The media could not be read.',
                  MediaFailure.encoding_failed => 'Media encoding failed.',
                  MediaFailure.cancelled => 'Media processing was cancelled.',
                  MediaFailure.busy => 'The media processor is busy.',
                  MediaFailure.timeout => 'Media processing timed out.',
                  MediaFailure.tool_unavailable =>
                    'The media tools are unavailable on this platform.',
                  MediaFailure.no_audio => 'The media has no audio track.',
                },
            if (error.nativeSessionId != null)
              'native_session_id': error.nativeSessionId,
            if (error.nativeLog != null) ...{
              'exit_code': error.nativeExitCode,
              'log': error.nativeLog,
            },
            if (reason == MediaFailure.cancelled) 'cancelled': true,
          };
        } on ToolOperationException catch (error) {
          result = {
            'ok': false,
            'error_code': error.code,
            'error': error.message,
            if (error.hint != null) 'hint': error.hint,
            if (error.code == 'cancelled') 'cancelled': true,
          };
        } catch (error, stack) {
          _log.error(
            'execution failed run=${record.runId}',
            error: error,
            stackTrace: stack,
          );
          result = active.cancellation.token.isCancellationRequested
              ? {
                  'ok': false,
                  'cancelled': true,
                  'error_code': 'cancelled',
                  'error': 'The operation was cancelled.',
                }
              : {
                  'ok': false,
                  'error_code': 'internal',
                  'error': 'The operation failed.',
                };
        }
        try {
          await release?.call();
        } catch (error, stack) {
          _log.error(
            'release failed run=${record.runId}',
            error: error,
            stackTrace: stack,
          );
          result = {
            'ok': false,
            'error_code': 'internal',
            'error': 'The operation could not release its resources.',
          };
        }
        active.cancelTimer?.cancel();
        active.unlinkParent?.call();
        record.status = result['cancelled'] == true
            ? ToolOperationStatus.cancelled
            : result['ok'] == false
            ? ToolOperationStatus.failed
            : ToolOperationStatus.completed;
        record.result = freezeToolArguments(result);
        try {
          await onFinished?.call(record);
        } catch (error, stack) {
          _log.error(
            'history persistence failed run=${record.runId}',
            error: error,
            stackTrace: stack,
          );
          record.status = ToolOperationStatus.failed;
          record.result = {
            'ok': false,
            'error_code': 'internal',
            'error': 'The operation result could not be saved.',
            'completed_result': record.result,
          };
        }
        _active.remove(record.runId);
        if (!_disposed &&
            active.mayNotify &&
            record.status != ToolOperationStatus.cancelled) {
          final completion = ToolOperationCompletion(record);
          if (record.result != null) {
            completion.modelImages = (await assembleToolResultContent(
              record.result!,
            )).whereType<ImageBlock>().toList();
          }
          _pending[record.runId] = completion;
        }
        _publish(record);
        active.done.complete(record.response());
      }),
    );
    return background ? Future.value(record.response()) : active.done.future;
  }

  Map<String, dynamic> list(
    ToolExecutionContext context, {
    ToolOperationStatus? status,
    int offset = 0,
    int limit = 50,
  }) {
    _authorizeCaller(context);
    if (offset < 0 || limit < 1 || limit > 200) {
      throw const FormatException('Invalid operation pagination.');
    }
    final records = _records.values
        .where(
          (r) =>
              r.sourceSessionId == _caller(context) ||
              (_caller(context) == ownerSessionId &&
                  context.operationOwnerSessionId == ownerSessionId),
        )
        .where((r) => status == null || r.status == status)
        .toList()
        .reversed
        .toList();
    final page = records.skip(offset).take(limit).toList();
    final more = offset + page.length < records.length;
    return {
      'ok': true,
      'entries': page.map((r) => r.toJson()).toList(),
      'has_more': more,
      'next_offset': more ? offset + page.length : null,
    };
  }

  Map<String, dynamic> read(String id, ToolExecutionContext context) =>
      _require(id, context).response();

  Future<Map<String, dynamic>> wait(
    String id,
    ToolExecutionContext context, {
    int timeoutMs = 30000,
  }) async {
    final record = _require(id, context);
    if (timeoutMs < 1 || timeoutMs > 60000) {
      throw const FormatException('timeout_ms must be between 1 and 60000.');
    }
    if (record.terminal && !_active.containsKey(id)) {
      return record.response();
    }
    final done = Completer<Map<String, dynamic>>();
    final timer = Timer(Duration(milliseconds: timeoutMs), () {
      if (!done.isCompleted) {
        done.complete({...record.response(), 'timed_out': true});
      }
    });
    final unlink = context.cancellationToken?.onCancel(() {
      if (!done.isCompleted) {
        done.complete({'ok': false, 'cancelled': true, 'run_id': id});
      }
    });
    try {
      return await Future.any([_active[id]!.done.future, done.future]);
    } finally {
      timer.cancel();
      unlink?.call();
    }
  }

  Map<String, dynamic> cancel(String id, ToolExecutionContext context) {
    final record = _require(id, context);
    _pending.remove(id);
    if (record.terminal) {
      _active[id]?.mayNotify = false;
      _publish();
      return {...record.response(), 'accepted': false};
    }
    _cancel(_active[id]!);
    return {...record.response(), 'ok': true, 'accepted': true};
  }

  void _cancel(_ActiveOperation active) {
    active.mayNotify = false;
    if (active.record.terminal) {
      return;
    }
    if (active.record.status == ToolOperationStatus.cancelling) {
      return;
    }
    active.record.status = ToolOperationStatus.cancelling;
    active.cancellation.cancel();
    active.cancelTimer = Timer(cancelTimeout, () {
      if (!active.record.terminal) {
        active.record.diagnostic = 'cancel_timeout';
        _publish(active.record);
      }
    });
    _publish(active.record);
  }

  ToolOperationCompletion? takeCompletion(String id) {
    final notice = _pending.remove(id);
    _publish();
    return notice;
  }

  void revokeCompletions(Set<String> turnIds) {
    _pending.removeWhere(
      (_, notice) => turnIds.contains(notice.record.sourceTurnId),
    );
    for (final run in _active.values) {
      if (turnIds.contains(run.record.sourceTurnId)) {
        run.mayNotify = false;
      }
    }
    _publish();
  }

  void beginSessionMutation() {
    _mutating = true;
  }

  void endSessionMutation() {
    _mutating = false;
  }

  Future<void> stopTurns(Set<String> turnIds) async {
    _pending.removeWhere(
      (_, notice) => turnIds.contains(notice.record.sourceTurnId),
    );
    final active = _active.values
        .where((r) => turnIds.contains(r.record.sourceTurnId))
        .toList();
    for (final run in active) {
      _cancel(run);
    }
    _publish();
    await Future.wait(active.map((r) => r.done.future));
  }

  void restore(Iterable<Map<String, dynamic>> snapshots) {
    for (final json in snapshots) {
      final record = ToolOperationRecord.fromJson(json);
      if (record.ownerSessionId != ownerSessionId ||
          _records.containsKey(record.runId)) {
        continue;
      }
      if (!record.terminal) {
        record.status = ToolOperationStatus.interrupted;
        record.result = {
          'ok': false,
          'error_code': 'interrupted',
          'error': 'The application stopped before this operation completed.',
        };
      }
      _records[record.runId] = record;
      registry.owners[record.runId] = ownerSessionId;
      _publish(record);
    }
  }

  void dispose() {
    for (final run in _active.values) {
      _cancel(run);
    }
    _pending.clear();
    _disposed = true;
    registry.owners.removeWhere((_, owner) => owner == ownerSessionId);
    registry.records.removeWhere(
      (_, record) => record.ownerSessionId == ownerSessionId,
    );
  }
}
