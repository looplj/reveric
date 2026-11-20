// 职责: 在真实工具执行前按最新规则等待审批并重新验证冻结目标。
// 关联文件:
//   lib/shared/services/tool_permissions.dart
//   lib/shared/agent/tool_approval.dart
//   lib/shared/agent/agent_tool_dispatcher.dart
//   lib/shared/models/tool_permission.dart
import '../agent/agent_tool_dispatcher.dart';
import '../agent/tool_approval.dart';
import '../models/tool_permission.dart';
import 'tool_permissions.dart';

class ToolPermissionGate {
  const ToolPermissionGate(
    this.permissions,
    this.approvals, {
    this.enabled = toolApprovalEnabled,
  });
  final ToolPermissionService permissions;
  final AiToolApprovalController approvals;

  /// Off: skip rule lookup and approval; target verification still runs.
  final bool enabled;

  Future<void> authorize({
    required ToolActionRequest request,
    required String ownerSessionId,
    required String approvalId,
    required String callId,
    String? displayCallId,
    required String toolName,
    required AgentCancellationToken cancellation,
    required Future<void> Function() verifyTarget,
    void Function(AiToolApprovalRequest)? onWaiting,
  }) async {
    var approvedOnce = false;
    void checkCancelled() {
      if (cancellation.isCancellationRequested) {
        throw const ToolOperationException(
          'cancelled',
          'The operation was cancelled.',
        );
      }
    }

    if (!enabled) {
      checkCancelled();
      await verifyTarget();
      checkCancelled();
      return;
    }
    while (true) {
      checkCancelled();
      final ruleRevision = approvals.ruleRevisionFor(ownerSessionId);
      final rule = await permissions.resolve(request.action, request.context);
      checkCancelled();
      if (rule.decision == ToolPermissionDecision.deny) {
        throw const ToolPermissionException(
          'permission_denied',
          "This action is denied by the user's saved permission rule.",
          hint: _deniedHint,
        );
      }
      if (rule.decision == ToolPermissionDecision.ask && !approvedOnce) {
        final pending = AiToolApprovalRequest(
          ownerSessionId: ownerSessionId,
          approvalId: approvalId,
          callId: callId,
          displayCallId: displayCallId,
          toolName: toolName,
          action: request.action,
          permissionContext: request.context,
          targetPath: request.targetPath,
          targetLabel: request.targetLabel,
          arguments: request.summary,
          saveRule: (scope, decision) =>
              permissions.setRule(request.action, scope, decision),
        );
        final decision = approvals.request(pending);
        final unlink = cancellation.onCancel(() => approvals.cancel(pending));
        onWaiting?.call(pending);
        final ToolApprovalOutcome outcome;
        try {
          // Catch a save in this chat between the lookup and enqueueing.
          // Saves after registration wake this request through the broker.
          if (ruleRevision != approvals.ruleRevisionFor(ownerSessionId)) {
            approvals.recheck(pending);
          }
          outcome = await decision;
        } finally {
          unlink();
          approvals.cancel(pending);
        }
        checkCancelled();
        if (outcome == ToolApprovalOutcome.recheck) {
          continue;
        }
        if (outcome == ToolApprovalOutcome.cancelled) {
          throw const ToolOperationException(
            'cancelled',
            'The approval request was cancelled before the user decided.',
          );
        }
        if (outcome != ToolApprovalOutcome.allowed) {
          throw const ToolPermissionException(
            'permission_denied',
            'The user rejected this action in the approval prompt.',
            hint: _deniedHint,
          );
        }
        approvedOnce = true;
        continue;
      }
      await verifyTarget();
      checkCancelled();
      final latest = await permissions.resolve(request.action, request.context);
      checkCancelled();
      if (latest.decision == ToolPermissionDecision.deny) {
        throw const ToolPermissionException(
          'permission_denied',
          "This action is denied by the user's saved permission rule.",
          hint: _deniedHint,
        );
      }
      if (latest.decision == ToolPermissionDecision.ask && !approvedOnce) {
        continue;
      }
      return;
    }
  }
}

/// 用户拒绝是决定而非故障：不重试、不换方式绕过，交给用户决定下一步。
const _deniedHint =
    'This is the user\'s decision, not a failure. The action was not executed. '
    'Do not retry it or work around it with another tool. Tell the user it was '
    'not run and ask whether to adjust or skip it.';
