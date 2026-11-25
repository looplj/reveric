// 职责: 串行编排数据工具与 Run 命令，记录写入和后台回执并等待在途提交收口。
// 关联文件:
//   lib/shared/services/ai/codemode/runtime.dart
//   lib/shared/services/ai/codemode/scheduler.dart
//   lib/shared/services/ai/codemode/tool.dart
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/models/ai_nested_tool_call.dart
import 'dart:async';
import 'dart:convert';

import '../../../agent/agent_tool_dispatcher.dart';
import '../../../agent/message.dart' show ToolCall;
import '../../../models/ai_nested_tool_call.dart';
import '../../../utils/random_id.dart';
import '../tool_error_normalize.dart';
import '../tool_result_payloads.dart';
import '../tool_catalog.dart';
import '../../../models/mcp/call_result.dart';
import '../../mcp/result_adapter.dart';
import 'runtime.dart';
import 'scheduler.dart';
import 'tool.dart';

class CodemodeOrchestrator {
  Future<Map<String, dynamic>> execute({
    required Map<String, dynamic> input,
    required ToolExecutionContext context,
    required String parentToolCallId,
    required AgentToolDispatcher tools,
    required CodemodeToolRunner runTool,
    required void Function(AiNestedToolCall record) onRecord,
    required CodemodeScheduler scheduler,
    required bool Function() isAllowed,
    required Iterable<String> Function() allowedToolNames,
    AgentToolCatalog? catalog,
    FjsRuntime Function()? runtimeFactory,
    CodemodeRuntimeLimits limits = const CodemodeRuntimeLimits(),
  }) async {
    Map<String, dynamic> failure(String code) => {
      'ok': false,
      'error_code': code,
      'error': codemodeErrorMessage(code),
      if (code == 'user_cancelled') 'cancelled': true,
      'output': const [],
      'call_count': 0,
      'completed_count': 0,
      'failed_count': 0,
    };
    final rawSource = input['code'];
    if (rawSource is! String || input.length != 1) {
      return failure('codemode_invalid_input');
    }
    final source = normalizeCodemodeSource(rawSource);
    if (!isAllowed()) {
      return failure('codemode_tool_forbidden');
    }
    final sourceSessionId = context.sourceSessionId;
    final sourceTurnId = context.sourceTurnId;
    final scope = ToolExecutionScope(parent: context.cancellationToken);
    final operations = <_Operation>[];
    var queue = Future<void>.value();
    var sealed = false;
    CodemodeLease? lease;
    FjsRuntime? runtime;
    CodemodeRuntimeResult? runtimeResult;
    String? admissionError;

    bool external(String name) => catalog != null && name.startsWith('mcp__');
    bool permitted(String name) =>
        isAllowed() &&
        (external(name) ||
            (codemodeToolNames.contains(name) &&
                allowedToolNames().contains(name) &&
                tools.allToolNames().contains(name)));

    void publish(_Operation operation) {
      if (sealed) {
        return;
      }
      onRecord(operation.record);
    }

    _Operation begin(String name, Map<String, dynamic> args) {
      final operation = _Operation(
        AiNestedToolCall(
          callId: buildRandomId('tool'),
          toolName: name,
          source: external(name) ? 'mcp' : 'builtin',
          server: catalog?.runtime.knownTools[name]?.server,
          remoteToolName: catalog?.runtime.knownTools[name]?.rawName,
          sourceSessionId: external(name)
              ? context.sessionId ?? sourceSessionId
              : sourceSessionId,
          parentCallId: parentToolCallId,
          argumentsPreview: jsonEncode(args),
          targetPath: !external(name) && args['path'] is String
              ? (args['path'] as String).trim().replaceFirst(RegExp(r'^/+'), '')
              : null,
        ),
      );
      operations.add(operation);
      publish(operation);
      return operation;
    }

    Map<String, dynamic> reject(_Operation operation, String code) {
      final result = failure(code);
      operation.record = operation.record.copyWith(
        status: code == 'user_cancelled' || code == 'codemode_finished'
            ? AiNestedToolStatus.cancelled
            : AiNestedToolStatus.rejected,
        errorCode: code,
        resultPreview: jsonEncode(result),
        durationMs: operation.watch.elapsedMilliseconds,
      );
      publish(operation);
      return result;
    }

    Future<Map<String, dynamic>> enqueue(
      String name,
      Map<String, dynamic> args,
    ) {
      final operation = begin(name, args);
      final response = Completer<Map<String, dynamic>>();
      queue = queue
          .then((_) async {
            if (scope.isCancelled) {
              response.complete(
                reject(operation, scope.errorCode ?? 'user_cancelled'),
              );
              return;
            }
            if (!permitted(name)) {
              response.complete(reject(operation, 'codemode_tool_forbidden'));
              scope.cancel(code: 'codemode_tool_forbidden');
              runtime?.cancel(errorCode: 'codemode_tool_forbidden');
              return;
            }
            operation.write = codemodeWriteToolNames.contains(name);
            Map<String, dynamic> result;
            try {
              result = await _executeNested(
                runTool: runTool,
                call: ToolCall(
                  callId: operation.record.callId,
                  toolName: name,
                  arguments: args,
                ),
                // 等待已进入的写入和 Run 收口，避免取消竞速丢失提交结果或后台回执。
                waitOnCancel: () =>
                    operation.entered &&
                    (operation.write || name == 'Run' || external(name)),
                context: ToolExecutionContext(
                  sessionId: context.sessionId,
                  operationOwnerSessionId: context.operationOwnerSessionId,
                  approvalHostCallId:
                      context.approvalHostCallId ?? parentToolCallId,
                  sourceSessionId: sourceSessionId,
                  sourceTurnId: sourceTurnId,
                  cancellationToken: scope.token,
                  parentToolCallId: parentToolCallId,
                  lifecycleObserver: ToolLifecycleObserver(
                    onProgress: (progress) {
                      if (operation.finished) {
                        return;
                      }
                      operation.record = operation.record.copyWith(
                        resultPreview: jsonEncode({'mcp_progress': progress}),
                      );
                      publish(operation);
                    },
                    onStarted: (preview) {
                      if (name == 'Run') {
                        if (preview?['codemode_effect_started'] is bool) {
                          operation.effectStarted =
                              preview!['codemode_effect_started'] == true;
                          return;
                        }
                        if (preview?['codemode_mutating'] is! bool) {
                          return;
                        }
                        operation.write = preview!['codemode_mutating'] == true;
                        operation.runCommand =
                            preview['run_command'] as String?;
                      }
                      operation.entered = true;
                      operation.record = operation.record.copyWith(
                        targetPath: preview?['targetPath'] is String
                            ? preview!['targetPath'] as String
                            : null,
                        effectStatus: operation.write
                            ? AiToolEffectStatus.unknown
                            : AiToolEffectStatus.none,
                      );
                      publish(operation);
                    },
                    onWorkingChange: (change) {
                      final changeScope = change.scope;
                      if (changeScope.sourceSessionId != sourceSessionId ||
                          changeScope.sourceTurnId != sourceTurnId) {
                        throw StateError(
                          'Working change belongs to another source turn',
                        );
                      }
                      operation.record = operation.record.withWorkingChange(
                        change.id,
                        changeScope,
                        multiple: change.multiple,
                      );
                      publish(operation);
                    },
                    onFinished: (raw, error) {
                      if ((operation.write ||
                              name == 'Run' ||
                              external(name)) &&
                          !operation.finished) {
                        operation.rawResult = raw;
                      }
                    },
                  ),
                ),
              );
            } catch (_) {
              result = failure('codemode_runtime_failed');
            }
            // hook 拦截不能被脚本 catch 后继续：关闭 scope，后续调用全部拒绝。
            if (result['error_code'] == 'hook_aborted') {
              scope.cancel(code: 'codemode_runtime_failed');
              runtime?.cancel(errorCode: 'codemode_runtime_failed');
            }
            // 取消竞速返回的 payload 不能抹掉写入真实返回的事实。
            final business =
                (operation.write || name == 'Run' || external(name)) &&
                    operation.rawResult != null
                ? operation.rawResult!
                : result;
            // 取得本次真实提交结果后，释放操作记录上的额外引用。
            operation.rawResult = null;
            final success = toolResultIsSuccess(business);
            final partial =
                business['failed'] is Map &&
                (business['failed'] as Map).isNotEmpty;
            final changed =
                success &&
                business['missing'] != true &&
                business['dry_run'] != true &&
                ([
                      'created',
                      'updated',
                      'edited',
                      'removed',
                    ].any((key) => business[key] == true) ||
                    (business['total_replacements'] is num &&
                        (business['total_replacements'] as num) > 0) ||
                    (business['created_parent_folders'] is List &&
                        (business['created_parent_folders'] as List)
                            .isNotEmpty));
            // A queued background receipt proves submission, not completion.
            final runId = business['run_id'];
            final runStatus = business['status'];
            operation.runId = runId is String ? runId : null;
            operation.pending =
                operation.runId != null &&
                const {
                  'waiting_approval',
                  'queued',
                  'running',
                  'cancelling',
                }.contains(runStatus);
            final payload = business['result'] is Map
                ? business['result'] as Map
                : business;
            final explicitNoChange =
                payload['updated'] == false ||
                payload['changed'] == false ||
                payload['missing'] == true ||
                payload['dry_run'] == true ||
                (payload['removed'] is List &&
                    (payload['removed'] as List).isEmpty);
            final runChanged =
                name == 'Run' &&
                success &&
                !explicitNoChange &&
                !operation.pending &&
                (runStatus == null || runStatus == 'completed');
            final runPartial =
                payload['remaining'] is List &&
                (payload['remaining'] as List).isNotEmpty;
            final actionNotAccepted =
                name == 'Run' && business['accepted'] == false;
            operation.confirmed =
                operation.write &&
                operation.entered &&
                !actionNotAccepted &&
                (changed || runChanged);
            operation.uncertain =
                operation.write &&
                operation.entered &&
                !operation.pending &&
                operation.mayHaveEffects(business) &&
                !actionNotAccepted &&
                (!success || partial || runPartial);
            // Later operations read/wait/cancel receipts settle submissions made
            // earlier in this script; keep the original call and command identity.
            if (operation.runId != null &&
                const {
                  'completed',
                  'failed',
                  'cancelled',
                  'interrupted',
                }.contains(runStatus)) {
              for (final prior in operations) {
                if (identical(prior, operation) ||
                    prior.runId != operation.runId ||
                    !prior.pending) {
                  continue;
                }
                prior.pending = operation.pending;
                prior.confirmed = prior.write && prior.entered && runChanged;
                prior.uncertain =
                    prior.write &&
                    prior.entered &&
                    !prior.pending &&
                    prior.mayHaveEffects(business) &&
                    (!success || partial || runPartial);
                prior.record = prior.record.copyWith(
                  effectStatus: prior.uncertain
                      ? AiToolEffectStatus.unknown
                      : prior.confirmed
                      ? AiToolEffectStatus.confirmed
                      : AiToolEffectStatus.none,
                );
                publish(prior);
              }
            }
            final externalCall = external(name);
            final preview = externalCall && business['executionState'] is String
                ? McpResultAdapter.limit(
                    McpCallResult.fromJson(business),
                    McpResultAdapter.modelBudget,
                  ).toJson(includeImageData: false)
                : (Map<String, dynamic>.from(business)..remove('_metadata'));
            operation.finished = true;
            operation.record = operation.record.copyWith(
              status: business['cancelled'] == true
                  ? AiNestedToolStatus.cancelled
                  : success
                  ? AiNestedToolStatus.success
                  : AiNestedToolStatus.error,
              executionState: externalCall
                  ? business['executionState'] as String?
                  : null,
              effectStatus: externalCall
                  ? (business['executionState'] == 'not_started'
                        ? AiToolEffectStatus.none
                        : AiToolEffectStatus.unknown)
                  : operation.uncertain
                  ? AiToolEffectStatus.unknown
                  : operation.confirmed
                  ? AiToolEffectStatus.confirmed
                  : AiToolEffectStatus.none,
              resultPreview: jsonEncode(preview),
              errorCode: business['error_code'] is String
                  ? business['error_code'] as String
                  : null,
              targetPath: business['path'] is String
                  ? business['path'] as String
                  : null,
              resourceId: business['id'] is String
                  ? business['id'] as String
                  : null,
              workingChangeId:
                  operation.record.workingChangeId ??
                  (business['working_change_id'] is String
                      ? business['working_change_id'] as String
                      : null),
              durationMs: operation.watch.elapsedMilliseconds,
            );
            publish(operation);
            // UI metadata is not part of the script's business result contract.
            response.complete(
              Map<String, dynamic>.from(result)..remove('_metadata'),
            );
          })
          .catchError((Object _) {
            operation.rawResult = null;
            if (!response.isCompleted) {
              operation.uncertain =
                  operation.write &&
                  operation.entered &&
                  operation.mayHaveEffects(failure('codemode_runtime_failed'));
              operation.record = operation.record.copyWith(
                effectStatus: operation.uncertain
                    ? AiToolEffectStatus.unknown
                    : AiToolEffectStatus.none,
              );
              response.complete(reject(operation, 'codemode_runtime_failed'));
            }
            runtime?.cancel(errorCode: 'codemode_runtime_failed');
          });
      return response.future;
    }

    try {
      lease = await scheduler.acquire(cancellationToken: scope.token);
      runtime = (runtimeFactory ?? FjsRuntime.new)();
      final allowed = allowedToolNames().toSet();
      final contracts = tools
          .allToolDefs()
          .where(
            (tool) =>
                codemodeToolNames.contains(tool.name) &&
                allowed.contains(tool.name),
          )
          .toList();
      runtimeResult = await runtime.run(
        code: source,
        tools: contracts,
        executeTool: enqueue,
        isDynamicTool: external,
        discover: catalog == null
            ? null
            : (method, args) async {
                final Map<String, dynamic> result;
                switch (method) {
                  case 'listMcpServers':
                    result = catalog.listMcpServers(
                      cursor: args['cursor'] as String?,
                    );
                  case 'listTools':
                    result = await catalog.listTools(
                      mcpServer: args['mcpServer'] as String?,
                      cursor: args['cursor'] as String?,
                    );
                  case 'searchTool':
                    result = await catalog.searchTool(
                      args['query'] as String,
                      mcpServer: args['mcpServer'] as String?,
                      source: args['source'] as String?,
                      limit: args['limit'] as int? ?? 8,
                    );
                  case 'describeTool':
                    result = await catalog.describeTool(args['name'] as String);
                  default:
                    throw ArgumentError('Unknown discovery method');
                }
                return result;
              },
        limits: limits,
        cancellationToken: scope.token,
        cancellationErrorCode: () => scope.errorCode ?? 'user_cancelled',
        onTerminate: (code) => scope.cancel(code: code ?? 'codemode_finished'),
        onRejectedTool: (name, args, code) {
          reject(begin(name, args), code);
        },
      );
      // Reads/previews race scope cancellation; started mutations retain
      // their real Future, so this waits for every actual write commit outcome.
      await queue;
    } on CodemodeAdmissionException catch (error) {
      admissionError = error.errorCode;
    } catch (_) {
      admissionError = 'codemode_runtime_failed';
      scope.cancel(code: admissionError);
      await queue;
    } finally {
      sealed = true;
      scope.dispose();
      if (lease != null) {
        await lease.releaseAfter(runtime?.settled ?? Future<void>.value());
      }
    }
    final result =
        runtimeResult?.toJson() ??
        failure(admissionError ?? 'codemode_runtime_failed');
    final completed = operations
        .where(
          (operation) => operation.record.status == AiNestedToolStatus.success,
        )
        .length;
    final summary = _operationSummary(operations);
    return {
      ...result,
      if (admissionError != null) ...failure(admissionError),
      'call_count': operations.length,
      'completed_count': completed,
      'failed_count': operations.length - completed,
      ...summary,
      'diagnostics': {
        ...?runtimeResult?.diagnostics,
        'source_bytes': utf8.encode(source).length,
        'call_count': operations.length,
        'phase': 'finished',
      },
    };
  }
}

/// 执行子调用的入口，需与模型发起的调用走同一条 hooks 管线（见 [Agent.runToolCall]）。
typedef CodemodeToolRunner =
    Future<Map<String, dynamic>> Function(
      ToolCall call,
      ToolExecutionContext context,
    );

/// 以子调用身份执行一个工具。工具异常转成错误结果交给脚本，不中断整段脚本。
/// [waitOnCancel] 为 false 时，取消立即返回取消结果，不等工具收尾。
Future<Map<String, dynamic>> _executeNested({
  required CodemodeToolRunner runTool,
  required ToolCall call,
  required bool Function() waitOnCancel,
  required ToolExecutionContext context,
}) async {
  final token = context.cancellationToken;
  if (token?.isCancellationRequested == true) {
    return aiCancelledToolResultPayload();
  }
  final dispatched = runTool(call, context).catchError(
    (Object error) => <String, dynamic>{
      'ok': false,
      'error': '$error',
      'error_code': 'exception',
    },
  );
  final cancelled = Completer<Map<String, dynamic>>();
  final unlink = token?.onCancel(() {
    if (!waitOnCancel() && !cancelled.isCompleted) {
      cancelled.complete(aiCancelledToolResultPayload());
    }
  });
  try {
    final result = await Future.any([dispatched, cancelled.future]);
    return normalizeToolFailureResult(result, input: call.arguments);
  } finally {
    unlink?.call();
  }
}

class _Operation {
  _Operation(this.record);
  AiNestedToolCall record;
  final Stopwatch watch = Stopwatch()..start();
  bool write = false;
  // null 表示只有写命令声明；true/false 来自实际执行阶段的通知。
  bool? effectStarted;
  bool pending = false;
  String? runCommand;
  String? runId;
  bool entered = false;
  bool finished = false;
  bool confirmed = false;
  bool uncertain = false;
  Map<String, dynamic>? rawResult;

  bool mayHaveEffects(Map<String, dynamic> result) =>
      record.workingChangeId != null ||
      (effectStarted ??
          (record.toolName != 'Run' ||
              result['error_code'] != 'invalid_argument'));
}

Map<String, dynamic> _operationSummary(List<_Operation> operations) {
  final pending = <String, _Operation>{};
  for (final operation in operations) {
    if (operation.pending && operation.runId != null) {
      pending.putIfAbsent(operation.runId!, () => operation);
    }
  }
  Map<String, dynamic> item(_Operation operation, bool compact) => {
    'call_id': operation.record.callId,
    'tool_name': operation.record.toolName,
    if (operation.runCommand != null) 'command': operation.runCommand,
    if (operation.runId != null) 'run_id': operation.runId,
    if (!compact && operation.record.targetPath != null)
      'target_path': operation.record.targetPath,
    if (operation.record.resourceId != null)
      'resource_id': operation.record.resourceId,
    if (operation.record.workingChangeId != null)
      'working_change_id': operation.record.workingChangeId,
    if (operation.record.hasMultipleWorkingChanges)
      'working_changes_grouped': true,
  };
  Map<String, dynamic> build(bool compact) => {
    'completed_operations': [
      for (final operation in operations)
        if (operation.confirmed) item(operation, compact),
    ],
    'uncertain_operations': [
      for (final operation in operations)
        if (operation.uncertain) item(operation, compact),
    ],
    'pending_operations': [
      for (final operation in pending.values) item(operation, compact),
    ],
    if (compact) 'operation_summary_omitted': true,
    if (operations.any((operation) => operation.uncertain))
      'verification_required':
          'Some operations may have changed data. Read their targets before retrying.',
  };
  final full = build(false);
  if (utf8.encode(jsonEncode(full)).length <= 16 * 1024) {
    return full;
  }
  final compact = build(true);
  if (utf8.encode(jsonEncode(compact)).length <= 16 * 1024) {
    return compact;
  }
  return {
    ...compact,
    for (final key in [
      'completed_operations',
      'uncertain_operations',
      'pending_operations',
    ])
      key: [
        for (final item in compact[key] as List)
          {
            'call_id': item['call_id'],
            'tool_name': item['tool_name'],
            if (item['run_id'] != null) 'run_id': item['run_id'],
          },
      ],
  };
}
