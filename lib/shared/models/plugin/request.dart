// 职责: 保存宿主分配的插件请求身份与作品作用域，供工具和请求提示共用。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/agent_dispatcher.dart
class PluginRequestContext {
  const PluginRequestContext({
    required this.requestId,
    required this.sessionId,
    required this.workId,
    required this.agentId,
    required this.mode,
    this.boundSessionId,
  });
  final String requestId, sessionId, agentId, mode;
  final String? workId, boundSessionId;
  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'sessionId': sessionId,
    'workId': workId,
    'agentId': agentId,
    'mode': mode,
  };
}
