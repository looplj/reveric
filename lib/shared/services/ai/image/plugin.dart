// 职责: 将统一图片提交与查询派发给插件，校验回执并绑定每次调用的 Host 输出文件。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/media_files.dart
//   lib/shared/services/ai/image/output.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import '../../../agent/agent_tool_dispatcher.dart';
import '../../../models/ai_provider.dart';
import '../../../localization/locale_keys.dart';
import 'package:easy_localization/easy_localization.dart';
import '../../plugins/host.dart';
import '../../plugins/files.dart';
import '../../plugins/media_files.dart';
import '../../plugins/runtime.dart';
import '../image.dart';
import 'client.dart';

class PluginImageClient extends ImageClient {
  PluginImageClient(super.config, this.host);
  final PluginHostService host;
  final _cancellation = AgentCancellationController();
  @override
  void cancel() {
    _cancellation.cancel();
    super.cancel();
  }

  @override
  Future<ProviderSubmitResult> submit(
    SubmitImageInput input,
    ImageOutputContext outputs,
  ) async {
    final store = outputs.files;
    final value = await _call(
      'image.submit',
      input.toJson(),
      outputs.inputScope,
      store,
    );
    try {
      final result = ProviderSubmitResult.fromJson(value);
      if (result is ProviderSucceeded) {
        outputs.adopt(result, store);
      }
      return result;
    } catch (error) {
      final id = value['remoteTaskId'];
      if (value['status'] == 'submitted' &&
          id is String &&
          id.trim().isNotEmpty) {
        throw AiImageFetchException(
          tr(LocaleKeys.aiImageCandidatesFetchFailed),
          providerTaskId: id,
          debugMessage: 'Invalid provider submission receipt: $error',
        );
      }
      throw AiImageSubmissionException(
        tr(
          value['status'] == 'succeeded'
              ? LocaleKeys.aiImageInvalidOutputs
              : LocaleKeys.aiImageSubmissionUnknown,
        ),
        failureCode: value['status'] == 'succeeded'
            ? 'invalid_outputs'
            : 'submission_unknown',
        debugMessage: 'Invalid provider submission receipt: $error',
      );
    }
  }

  @override
  Future<ProviderQueryResult> query(
    ProviderQueryInput input,
    ImageOutputContext outputs,
  ) async {
    // A previous invocation has already revoked its handles; queries receive a new scope.
    final scope = PluginFileScope(
      pluginId: config.pluginId!,
      providerId: config.id,
      taskId: outputs.inputScope.taskId,
    );
    final store = PluginMediaFiles(
      directory: outputs.files.directory,
      scope: scope,
    );
    final value = await _call('image.query', input.toJson(), scope, store);
    final result = ProviderQueryResult.fromJson(value);
    if (result is ProviderSucceeded) {
      outputs.adopt(result, store);
    }
    return result;
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> input,
    PluginFileScope scope,
    PluginMediaFiles store,
  ) async {
    final value = await host.callProvider(
      config,
      method,
      input: input,
      taskId: scope.taskId,
      files: scope,
      mediaFiles: store,
      cancellation: _cancellation.token,
    );
    if (value is! Map<String, dynamic>) {
      throw PluginHostError(
        'invalid_response',
        'Provider image result must be an object',
      );
    }
    return value;
  }
}
