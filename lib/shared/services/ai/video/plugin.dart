// 职责: 将统一视频提交和单次查询派发到实例插件，校验视频回执并保留阶段错误。
// 关联文件:
//   lib/shared/services/ai/video/client.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/files.dart
import '../../../agent/agent_tool_dispatcher.dart';
import '../../../localization/ai_run_failure_localization.dart';
import '../../../models/ai_provider.dart';
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import '../../plugins/files.dart';
import '../../plugins/host.dart';
import '../../plugins/runtime.dart';
import 'client.dart';

/// 无效状态不丢弃已经返回的合法远端身份；宿主持久化后等待显式核对。
class InvalidVideoReceipt extends VideoException {
  InvalidVideoReceipt(String id, Object error)
    : receipt = ProviderSubmitted(id),
      super(
        VideoErrorCode.invalid_response,
        detail: 'Invalid video receipt state: $error',
      );
  final ProviderSubmitted receipt;
}

class PluginVideoClient extends VideoClient {
  PluginVideoClient({
    required this.provider,
    required this.host,
    required this.taskId,
    required super.httpClient,
    required this.cancellation,
  }) : super(providerType: provider.type, endpoint: Uri(), apiKey: '');
  final AiProvider provider;
  final PluginHostService host;
  final String taskId;
  final AgentCancellationToken cancellation;

  @override
  Future<void> validateSubmission(
    SubmitVideoInput input,
    PluginFileScope files,
  ) async {
    if (input.draftOf != null && input.references.isNotEmpty) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'draft',
      );
    }
  }

  @override
  Future<ProviderSubmitResult> submit(
    SubmitVideoInput input,
    PluginFileScope files,
  ) async {
    final value = await _call('video.submit', input.toJson(), files);
    try {
      final result = ProviderSubmitResult.fromJson(value);
      if (result is! ProviderSubmitted) {
        throw const FormatException('Video submission must return submitted');
      }
      return result;
    } catch (error) {
      final id = value['remoteTaskId'];
      if (value['status'] == 'submitted' &&
          id is String &&
          id.trim().isNotEmpty) {
        throw InvalidVideoReceipt(id, error);
      }
      throw VideoException(
        VideoErrorCode.submission_unknown,
        detail: 'Invalid video receipt: $error',
      );
    }
  }

  @override
  Future<ProviderQueryResult> query(ProviderQueryInput input) async {
    final files = PluginFileScope(
      pluginId: provider.pluginId!,
      providerId: provider.id,
      taskId: taskId,
    );
    try {
      final value = await _call('video.query', input.toJson(), files);
      final result = ProviderQueryResult.fromJson(value);
      if (result is ProviderSucceeded &&
          (result.outputs.length != 1 ||
              result.outputs.single is! ProviderUrlOutput)) {
        throw const FormatException('Video requires exactly one URL output');
      }
      return result;
    } on FormatException catch (error) {
      throw VideoException(VideoErrorCode.invalid_response, detail: '$error');
    } finally {
      files.revoke();
    }
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> input,
    PluginFileScope files,
  ) async {
    try {
      final value = await host.callProvider(
        provider,
        method,
        input: input,
        taskId: taskId,
        files: files,
        cancellation: cancellation,
      );
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Provider result must be an object');
      }
      return value;
    } catch (error) {
      final code = switch (error) {
        PluginHostError() => error.code,
        PluginExecutionError() => error.code,
        _ => null,
      };
      final classification =
          VideoErrorCode.values.asNameMap()[code] ??
          (method == 'video.submit'
              ? VideoErrorCode.submission_unknown
              : error is FormatException
              ? VideoErrorCode.invalid_response
              : VideoErrorCode.unavailable);
      final resolved = switch (error) {
        PluginExecutionError(:final code, :final message)
            when !code.startsWith('plugin_') && code != 'user_cancelled' =>
          resolveProviderFailureMessage(code: code, message: message),
        _ => (messageKey: null, providerMessage: null),
      };
      throw VideoException(
        classification,
        messageKey: resolved.messageKey,
        providerMessage: resolved.providerMessage,
        detail: '$error',
      );
    }
  }

  @override
  String get createPath => throw UnsupportedError('Plugin owns video protocol');
  @override
  String queryPath(String id) =>
      throw UnsupportedError('Plugin owns video protocol');
  @override
  Map<String, dynamic> encode(
    VideoRequest request,
    List<VideoReference> references,
  ) => throw UnsupportedError('Plugin owns video protocol');
  @override
  String submissionId(Map<String, dynamic> json) =>
      throw UnsupportedError('Plugin owns video protocol');
  @override
  VideoTaskResult decodeResult(Map<String, dynamic> json) =>
      throw UnsupportedError('Plugin owns video protocol');
}
