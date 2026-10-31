// 职责: 工具调度接口定义 — Agent 运行时通过此接口执行工具，不关心具体实现
// 关联文件:
//   lib/shared/agent/agent.dart
//   lib/shared/services/ai/tools.dart

import '../models/ai_nested_tool_call.dart';
import 'message.dart' show AgentMessage;

/// 工具定义 — 供 LLM tool_choice 使用
class ToolDef {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Map<String, dynamic>? outputSchema;

  const ToolDef({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.outputSchema,
  });
}

/// 一次 Agent 运行的只读取消信号。
///
/// 工具和子 Agent 只能监听取消，不能反向取消所属的父运行。
class AgentCancellationToken {
  AgentCancellationToken._();

  bool _isCancellationRequested = false;
  final Set<void Function()> _listeners = <void Function()>{};

  bool get isCancellationRequested => _isCancellationRequested;

  /// 注册取消监听。若取消已发生，监听会立即同步执行。
  ///
  /// 返回的函数用于解除监听。
  void Function() onCancel(void Function() listener) {
    if (_isCancellationRequested) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _cancel() {
    if (_isCancellationRequested) {
      return;
    }
    _isCancellationRequested = true;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

/// 持有并触发一次 Agent 运行的取消信号。
class AgentCancellationController {
  final AgentCancellationToken token = AgentCancellationToken._();

  void cancel() => token._cancel();
}

/// 单次 Agent turn 的工具执行上下文。
///
/// 这个对象只随本次 tool call 传递，不应被 Agent/ToolManager 长期保存。
///
/// [sourceTurnId] 可变：同一次 `Agent.process` 内若有「立即发送」的排队消息作为
/// 新一轮被消费，turn runner 会把它改写成新 user 消息 id，保证该轮工具改动按轮
/// 归属到正确的消息，而不是沿用上一条消息的 turn id。
///
/// [sessionId] 是当前 Agent 对话身份，供 Todo 和 `History scope=current`
/// 等会话内状态使用。[sourceSessionId] 表示本次 Agent 运行的来源会话，
/// 供 Write/Edit/Create 等 mutation 归属与 `History scope=source` 使用。
/// 主 Agent 两者相同；Spawn 子 Agent 使用 `sessionId=sub`、
/// `sourceSessionId=parent`。
/// [cancellationToken] 由 [Agent.process] 在运行期绑定；独立子运行使用自己的
/// 取消控制器，同步 Spawn 在等待期间显式桥接父取消信号。
class ToolExecutionContext {
  ToolExecutionContext({
    this.sessionId,
    this.sourceSessionId,
    this.sourceTurnId,
    this.cancellationToken,
    this.parentToolCallId,
    this.operationOwnerSessionId,
    this.approvalHostCallId,
    this.lifecycleObserver,
  });

  /// Host-granted operation owner; model arguments cannot set this authority.
  final String? operationOwnerSessionId;
  final String? approvalHostCallId;
  final String? sessionId;
  final String? sourceSessionId;
  String? sourceTurnId;
  AgentCancellationToken? cancellationToken;

  /// Present only for a host-created nested call; never inferred from IDs.
  final String? parentToolCallId;
  final ToolLifecycleObserver? lifecycleObserver;
}

/// Cancellation owned by one composite tool, linked to the parent turn.
class ToolExecutionScope {
  ToolExecutionScope({AgentCancellationToken? parent}) {
    _unlink = parent?.onCancel(() => cancel());
  }

  final AgentCancellationController _controller = AgentCancellationController();
  void Function()? _unlink;
  String? errorCode;
  AgentCancellationToken get token => _controller.token;
  bool get isCancelled => token.isCancellationRequested;

  void cancel({String code = 'user_cancelled'}) {
    errorCode ??= code;
    _controller.cancel();
  }

  void dispose() {
    _unlink?.call();
    _unlink = null;
  }
}

/// A compact association emitted only for real committed working changes.
class ToolWorkingChange {
  const ToolWorkingChange({
    required this.id,
    required this.scope,
    this.multiple = false,
  });
  final String id;
  final AiWorkingChangeScope scope;
  final bool multiple;

  ToolWorkingChange cover(ToolWorkingChange other) {
    if (scope.sourceSessionId != other.scope.sourceSessionId ||
        scope.sourceTurnId != other.scope.sourceTurnId) {
      throw StateError('Working change capture crossed a source turn');
    }
    return ToolWorkingChange(
      id: id,
      scope: scope.cover(other.scope),
      multiple: multiple || other.multiple || id != other.id,
    );
  }
}

/// Scoped business lifecycle of a nested call; the caller owns the result.
class ToolLifecycleObserver {
  const ToolLifecycleObserver({
    this.onStarted,
    this.onFinished,
    this.onWorkingChange,
    this.onProgress,
  });
  final void Function(Map<String, dynamic>? preview)? onStarted;
  final void Function(Map<String, dynamic>? result, String? error)? onFinished;
  final void Function(ToolWorkingChange change)? onWorkingChange;
  final void Function(Map<String, dynamic> progress)? onProgress;
}

/// 工具调度接口 — Agent 运行时通过此接口执行工具，不关心具体注册/回调实现。
///
/// [AiToolManager] 实现了此接口；浮窗聊天等轻量场景可实现自己的调度器。
abstract interface class AgentToolDispatcher {
  Future<Map<String, dynamic>> executeTool({
    required String name,
    required Map<String, dynamic> input,
    String? callId,
    bool emitEvents = true,
    ToolExecutionContext? context,
  });
  List<String> allToolNames();
  List<ToolDef> allToolDefs();
  List<ToolDef> toolDefsForNames(List<String> names);
}

// AgentToolCallRequest 已合并为 message.dart 中的 ToolCall

/// 可选的请求级动态能力；普通 Agent 调度器保持静态契约。
abstract interface class AgentRequestToolDispatcher {
  /// 每次模型请求前调用；[runStart] 为一次 run 的首个请求，run 级状态只在此时刷新。
  Future<void> prepareRequest({required bool runStart});
  String get requestSystemPrompt;

  /// 本次 run 替换 Agent system prompt 的文本；null 表示沿用原 prompt。
  String? get systemPromptOverride;

  /// 根据当前上下文返回本轮需追加的消息；由 Agent 写入上下文并作为新消息发布。
  List<AgentMessage> requestMessages(List<AgentMessage> context);
  bool isExternalCall(String name, Map<String, dynamic> input);
  Map<String, dynamic>? callMetadata(
    String name,
    Map<String, dynamic> input,
    ToolExecutionContext? context,
  );
  String externalErrorDiagnostic(Object error);
}
