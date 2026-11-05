// 职责: 管理子任务的运行资源与状态，并将初始化失败转换为安全可读的工具结果。
// 关联文件:
//   lib/shared/services/ai/spawn_agent_handler.dart
//   lib/shared/services/ai/chat.dart
//   lib/shared/agent/agent.dart
part of 'spawn_agent_handler.dart';

class SpawnAgentResumeException implements Exception {
  const SpawnAgentResumeException(this.code, this.message);
  final String code;
  final String message;
}

/// 已确认的初始化失败原因；message 只包含可直接反馈给用户和模型的业务说明。
class SpawnAgentInitializationException implements Exception {
  const SpawnAgentInitializationException({
    required this.reason,
    required this.message,
  });

  final String reason;
  final String message;

  @override
  String toString() => '$reason: $message';
}

/// 工厂取得的资源一次性移交给 run；取得失败时由工厂释放部分资源。
class SpawnAgentResources {
  SpawnAgentResources({
    required this.client,
    required this.toolManager,
    required this._release,
  });

  final ProviderClient client;
  final AgentToolDispatcher toolManager;
  final void Function() _release;
  bool _released = false;

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _release();
  }
}

typedef SpawnAgentResourcesResolver =
    Future<SpawnAgentResources> Function({
      required String providerId,
      required String model,
      required String subSessionId,
      required String sourceSessionId,
    });

enum SpawnAgentRunStatus {
  initializing,
  running,
  stopping,
  completed,
  failed,
  cancelled,
}

/// 身份在启动时冻结。同步工具通过 result 等待；会话运行时可持有同一对象控制执行。
class SpawnAgentRun {
  SpawnAgentRun._({
    required this.runId,
    required this.subSessionId,
    required this.parentSessionId,
    required this.sourceSessionId,
    required this.sourceTurnId,
    required this.callId,
    required this.agentName,
    required this.name,
    required this.task,
    required Future<Map<String, dynamic>> Function(SpawnAgentRun) execute,
    required Future<void> Function(
      SpawnAgentRun,
      Map<String, dynamic>,
      Object,
      StackTrace,
    )
    reportInitializationFailure,
    required void Function(SpawnAgentRun)? onFinished,
    this._onStatusChanged,
    this._onEvent,
    this._waitForStart,
  }) {
    _spawnAgentLog.info(
      'run initializing runId=$runId subSessionId=$subSessionId '
      'parentSessionId=$parentSessionId sourceTurnId=$sourceTurnId callId=$callId',
    );
    result = Future.microtask(() async {
      Map<String, dynamic> outcome;
      try {
        outcome = await execute(this);
      } catch (error, stackTrace) {
        _spawnAgentLog.error(
          'SpawnAgent initialization failed runId=$runId '
          'subSessionId=$subSessionId',
          error: error,
          stackTrace: stackTrace,
        );
        final failure = _describeInitializationFailure(error);
        // 资源已就绪说明回退模型启动成功，后续失败与模型无关。
        final previousFailure = _resources == null ? _fallbackFailure : null;
        outcome = {
          'ok': false,
          'error_code': ToolErrorCode.unavailable.name,
          'failure_reason': failure.reason,
          'error': previousFailure == null
              ? failure.message
              : '子代理原模型启动失败：${previousFailure.message}\n'
                    '已尝试父会话模型“$_resourceModel”，但也未能启动：${failure.message}',
          if (previousFailure != null)
            'fallback_reason': previousFailure.reason,
          if (_resourceProviderId != null) 'provider_id': _resourceProviderId,
          if (_resourceModel != null) 'model': _resourceModel,
          'session_id': subSessionId,
        };
        await reportInitializationFailure(this, outcome, error, stackTrace);
      } finally {
        _cancellationSealed = true;
        _inbox.close();
        if (!_started.isCompleted) {
          _started.complete(false);
        }
        _resources?.release();
        _resources = null;
      }
      if (_contextUsage != null) {
        outcome = {...outcome, 'context': _contextUsage};
      }
      _status = outcome['cancelled'] == true
          ? SpawnAgentRunStatus.cancelled
          : outcome['ok'] == true
          ? SpawnAgentRunStatus.completed
          : SpawnAgentRunStatus.failed;
      _spawnAgentLog.info(
        'run finished runId=$runId subSessionId=$subSessionId '
        'status=${_status.name}',
      );
      try {
        onFinished?.call(this);
      } catch (error, stackTrace) {
        _spawnAgentLog.warning(
          'run final observer failed runId=$runId '
          'error=$error\n$stackTrace',
        );
      }
      return outcome;
    });
  }

  final String runId;

  /// 登记时刻。后台任务条按它算已运行时长，跨面板关闭重开仍然连续。
  final DateTime createdAt = DateTime.now();
  final String subSessionId;
  final String? parentSessionId;
  final String? sourceSessionId;
  final String? sourceTurnId;
  final String? callId;
  final String agentName;
  final String name;
  final String task;
  final void Function(SpawnAgentRun)? _onStatusChanged;
  final void Function(SpawnAgentRun, AgentEvent)? _onEvent;
  final Future<void>? Function(SpawnAgentRun)? _waitForStart;
  String? _cancellationSource;
  bool _cancellationSealed = false;
  final _cancellation = AgentCancellationController();
  final _inbox = AgentMessageInbox();
  final _started = Completer<bool>();
  SpawnAgentResources? _resources;
  Map<String, dynamic>? _contextUsage;
  final _nestedCalls = <String, Map<String, AiNestedToolCall>>{};
  String? _resourceProviderId;
  String? _resourceModel;
  ({String reason, String message})? _fallbackFailure;
  SpawnAgentRunStatus _status = SpawnAgentRunStatus.initializing;

  SpawnAgentRunStatus get status => _status;

  /// true 表示会话和资源已准备好；false 表示启动失败或启动前取消。
  Future<bool> get started => _started.future;

  /// 包含工具、Agent onEnd、终态持久化与资源释放；取消请求本身不完成此 Future。
  late final Future<Map<String, dynamic>> result;

  ({String reason, String message}) _describeInitializationFailure(
    Object error,
  ) {
    return switch (error) {
      SpawnAgentInitializationException(:final reason, :final message) => (
        reason: reason,
        message: message,
      ),
      _ => (
        reason: 'internal_error',
        message:
            '${_resourceModel == null || _resources != null ? '子代理' : '模型“$_resourceModel”'}'
            '启动时发生内部错误。请上传诊断日志以便排查。',
      ),
    };
  }

  bool sendMessage(String message) {
    if (message.trim().isEmpty || _cancellation.token.isCancellationRequested) {
      return false;
    }
    return _inbox.add(
      AgentMessage.user(id: buildRandomId('sub_instruction'), content: message),
    );
  }

  void cancel({String source = 'user_click'}) {
    if (_cancellationSealed ||
        _status == SpawnAgentRunStatus.completed ||
        _status == SpawnAgentRunStatus.failed ||
        _status == SpawnAgentRunStatus.cancelled) {
      return;
    }
    _cancellationSource ??= source;
    _status = SpawnAgentRunStatus.stopping;
    _spawnAgentLog.info(
      'run stopping runId=$runId source=$_cancellationSource',
    );
    _inbox.close();
    _cancellation.cancel();
    _onStatusChanged?.call(this);
  }

  void _markStarted() {
    if (_cancellation.token.isCancellationRequested) {
      return;
    }
    _status = SpawnAgentRunStatus.running;
    _spawnAgentLog.info('run started runId=$runId subSessionId=$subSessionId');
    _started.complete(true);
    _onStatusChanged?.call(this);
  }
}
