// 职责: 按会话与独立审批身份持有冻结的工具审批，处理一次性决策、规则保存和取消。
// 关联文件:
//   lib/shared/models/tool_permission.dart
//   lib/shared/services/tool_permission_gate.dart
//   lib/shared/providers/ai_providers.dart
import 'dart:async';
import '../models/tool_permission.dart';

enum ToolApprovalOutcome { allowed, denied, cancelled, recheck }

class AiToolApprovalRequest {
  AiToolApprovalRequest({
    required this.ownerSessionId,
    required this.approvalId,
    required this.callId,
    this.displayCallId,
    required this.toolName,
    required this.action,
    required this.permissionContext,
    required this.targetPath,
    this.targetLabel,
    required Map<String, dynamic> arguments,
    required this.saveRule,
  }) : arguments = freezeToolArguments(arguments);
  final String ownerSessionId, approvalId, callId, toolName, action, targetPath;
  final String? displayCallId, targetLabel;
  final ToolPermissionContext permissionContext;
  final Map<String, dynamic> arguments;
  final Future<void> Function(
    ToolPermissionScope scope,
    ToolPermissionDecision decision,
  )
  saveRule;
  final Completer<ToolApprovalOutcome> _completer = Completer();
  bool resolving = false;
  bool saveFailed = false;
  bool get isResolved => _completer.isCompleted;
  Future<ToolApprovalOutcome> get decision => _completer.future;
}

/// A single application broker holds only pending requests; terminal requests are removed.
/// Requests are keyed by their own approval identity: several operations from one
/// tool call wait side by side. Saved permissions wake matching requests so their
/// gates can re-evaluate the effective rule without granting a one-time override.
class AiToolApprovalController {
  final _changes = StreamController<List<AiToolApprovalRequest>>.broadcast();
  final _pending = <(String, String), AiToolApprovalRequest>{};
  final _ruleRevisions = <String, int>{};
  bool _disposed = false;
  List<AiToolApprovalRequest> get pending => List.unmodifiable(_pending.values);
  List<AiToolApprovalRequest> pendingFor(String sessionId) =>
      pending.where((r) => r.ownerSessionId == sessionId).toList();
  Stream<List<AiToolApprovalRequest>> get stream => _changes.stream;
  int ruleRevisionFor(String sessionId) => _ruleRevisions[sessionId] ?? 0;
  void _publish() {
    if (!_disposed) {
      _changes.add(pending);
    }
  }

  bool _owns(AiToolApprovalRequest req) =>
      identical(_pending[(req.ownerSessionId, req.approvalId)], req);

  Future<ToolApprovalOutcome> request(AiToolApprovalRequest req) {
    if (_disposed) {
      return Future.value(ToolApprovalOutcome.cancelled);
    }
    final key = (req.ownerSessionId, req.approvalId);
    if (_pending.containsKey(key)) {
      throw StateError('Approval ${req.approvalId} is already pending.');
    }
    _pending[key] = req;
    _publish();
    return req.decision;
  }

  Future<bool> resolve(
    AiToolApprovalRequest req, {
    required bool allow,
    ToolPermissionScope? scope,
  }) async {
    if (!_owns(req) || req.resolving || req.isResolved) {
      return false;
    }
    if (scope != null && !req.permissionContext.scopes.contains(scope)) {
      throw const ToolPermissionException(
        'permission_denied',
        'This approval cannot save a rule for that scope.',
      );
    }
    req.resolving = true;
    req.saveFailed = false;
    _publish();
    try {
      if (scope != null) {
        await req.saveRule(
          scope,
          allow ? ToolPermissionDecision.allow : ToolPermissionDecision.deny,
        );
      }
      if (!_owns(req)) {
        return false;
      }
      _finish(
        req,
        allow ? ToolApprovalOutcome.allowed : ToolApprovalOutcome.denied,
      );
      if (allow && scope != null) {
        _ruleRevisions[req.ownerSessionId] =
            ruleRevisionFor(req.ownerSessionId) + 1;
        for (final pending in pendingFor(req.ownerSessionId)) {
          if (pending.action == req.action &&
              pending.permissionContext.scopes.contains(scope)) {
            recheck(pending);
          }
        }
      }
      return true;
    } catch (_) {
      req.saveFailed = true;
      rethrow;
    } finally {
      req.resolving = false;
      _publish();
    }
  }

  void _finish(AiToolApprovalRequest req, ToolApprovalOutcome outcome) {
    if (!_owns(req)) {
      return;
    }
    _pending.remove((req.ownerSessionId, req.approvalId));
    if (!req.isResolved) {
      req._completer.complete(outcome);
    }
    _publish();
  }

  void cancel(AiToolApprovalRequest req) =>
      _finish(req, ToolApprovalOutcome.cancelled);

  void recheck(AiToolApprovalRequest req) {
    // A decision already being saved belongs to that explicit user action.
    if (!req.resolving) {
      _finish(req, ToolApprovalOutcome.recheck);
    }
  }

  void cancelSession(String sessionId) {
    for (final req in pendingFor(sessionId)) {
      cancel(req);
    }
  }

  void dispose() {
    for (final req in pending) {
      cancel(req);
    }
    _disposed = true;
    _ruleRevisions.clear();
    unawaited(_changes.close());
  }
}
