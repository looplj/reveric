// 职责: 统一工具结果分类、后台任务展示与历史恢复所需的结果投影。
// 关联文件:
//   lib/shared/models/ai_message_block.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/services/ai/agent_message_mapping.dart
//   lib/shared/widgets/ai/tools/tool_card_descriptor.dart

import '../../models/ai_message_block.dart';
import 'run_command_parser.dart';
import 'tool_error_normalize.dart';

/// The submission receipt stays in history; the matching run supplies its
/// current outcome for both tool presentation and restored model context.
Map<String, dynamic>? aiToolOperationResult(AiToolCallBlock block) {
  final operations = (block.metadata?['operations'] as List? ?? const [])
      .whereType<Map>()
      .where((operation) => operation['call_id'] == block.callId)
      .toList();
  final Map<String, dynamic>? operation;
  if (operations.length == 1) {
    operation = Map<String, dynamic>.from(operations.single);
  } else if (operations.isEmpty &&
      block.toolName == 'Run' &&
      block.result?['run_id'] is String) {
    operation = block.result;
  } else {
    return null;
  }
  if (operation == null ||
      !const {
        'waiting_approval',
        'queued',
        'running',
        'cancelling',
        'completed',
        'failed',
        'cancelled',
        'interrupted',
      }.contains(operation['status'])) {
    return null;
  }
  final result = (operation['result'] as Map?)?.cast<String, dynamic>();
  return {
    ...operation,
    'ok':
        !const {
          'failed',
          'cancelled',
          'interrupted',
        }.contains(operation['status']) &&
        result?['ok'] != false,
    if (operation['status'] == 'cancelled') 'cancelled': true,
    for (final key in ['error_code', 'error', 'hint'])
      if (result?[key] != null) key: result![key],
  };
}

AiToolCallBlock aiToolOperationDisplayBlock(AiToolCallBlock block) {
  // Control calls return a snapshot of another operation. Its running status
  // must not restart a completed read, wait (including timeout), or cancel call.
  if (block.toolName == 'Run' &&
      ParsedRunCommand.fromBlock(block)?.topLevel == 'operations') {
    return block;
  }
  final result = aiToolOperationResult(block);
  if (result == null) {
    return block;
  }
  final status = switch (result['status']) {
    'waiting_approval' || 'queued' => AiToolCallStatus.pending,
    'running' || 'cancelling' => AiToolCallStatus.running,
    _ => aiToolResultStatus(result),
  };
  return block.copyWith(
    status: status,
    result: result,
    errorMessage: result['error'] as String?,
  );
}

const aiUserCancelledToolResultError = 'User cancelled';

Map<String, dynamic> aiCancelledToolResultPayload() {
  return const {
    'ok': false,
    'cancelled': true,
    'error': aiUserCancelledToolResultError,
    'error_code': 'user_cancelled',
  };
}

bool aiToolCallStatusIsActive(AiToolCallStatus status) {
  return status == AiToolCallStatus.pending ||
      status == AiToolCallStatus.running;
}

/// 双端工具卡与恢复记录使用同一终态分类，控制流标记优先保留。
AiToolCallStatus aiToolResultStatus(
  Map<String, dynamic>? result, {
  String? errorMessage,
}) {
  if (result?['cancelled'] == true || result?['skipped'] == true) {
    return AiToolCallStatus.cancelled;
  }
  if (result?['rejected'] == true) {
    return AiToolCallStatus.rejected;
  }
  return errorMessage != null ||
          (result != null && !toolResultIsSuccess(result))
      ? AiToolCallStatus.error
      : AiToolCallStatus.success;
}

Map<String, dynamic>? aiTerminalToolResultPayload({
  required AiToolCallStatus status,
  required Map<String, dynamic>? result,
  required String? errorMessage,
}) {
  if (aiToolCallStatusIsActive(status)) {
    return null;
  }
  if (result != null) {
    return normalizeToolFailureResult({
      ...result,
      if (status == AiToolCallStatus.cancelled) 'cancelled': true,
      if (status == AiToolCallStatus.rejected) 'rejected': true,
      if (status == AiToolCallStatus.error ||
          status == AiToolCallStatus.rejected ||
          errorMessage != null)
        'ok': false,
      'error': ?errorMessage,
    });
  }
  return switch (status) {
    AiToolCallStatus.cancelled => aiCancelledToolResultPayload(),
    AiToolCallStatus.rejected => {
      'ok': false,
      'error': errorMessage ?? 'Tool call rejected',
      'error_code': 'tool_call_rejected',
    },
    AiToolCallStatus.error => {
      'ok': false,
      'error': errorMessage ?? 'Tool call failed',
      'error_code': 'tool_call_failed',
    },
    AiToolCallStatus.success => {'ok': true},
    AiToolCallStatus.pending || AiToolCallStatus.running => null,
  };
}
