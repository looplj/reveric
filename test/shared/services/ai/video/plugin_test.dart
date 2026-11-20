// 职责: 验证插件视频客户端映射标准错误码、透传可读拒绝消息并拦截内部运行时异常。
// 关联文件:
//   lib/shared/services/ai/video/plugin.dart
//   lib/shared/localization/ai_run_failure_localization.dart
//   lib/shared/models/video/task_result.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/video/client.dart';
import 'package:reveric/shared/services/ai/video/plugin.dart';
import 'package:reveric/shared/services/plugins/files.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/media_files.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

class _StubPluginHost implements PluginHostService {
  _StubPluginHost(this.onCall);

  final Future<Object?> Function(String method) onCall;

  @override
  Future<Object?> callProvider(
    AiProvider provider,
    String method, {
    Map<String, dynamic> input = const {},
    Map<String, Object?> draftSettings = const {},
    Map<String, String?> draftSecrets = const {},
    String? taskId,
    PluginFileScope? files,
    PluginMediaFiles? mediaFiles,
    AgentCancellationToken? cancellation,
  }) => onCall(method);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  final provider = aiProviderBuiltinById('openai')!.copyWith(
    id: 'plugin-video',
    type: 'plugin:reveric.xiaoyunque',
    enabled: true,
    apiKey: '',
    baseUrl: '',
  );

  SubmitVideoInput submitInput() => SubmitVideoInput(
    request: const VideoRequest(
      modelId: 'MiniMax-H3',
      prompt: 'test',
      mode: VideoMode.text,
      resolution: '480p',
      ratio: '16:9',
    ),
    references: const [],
  );

  PluginVideoClient buildClient(
    Future<Object?> Function(String method) onCall,
  ) {
    return PluginVideoClient(
      provider: provider,
      host: _StubPluginHost(onCall),
      taskId: 'task-1',
      httpClient: MockClient((_) async => throw UnimplementedError()),
      cancellation: AgentCancellationController().token,
    );
  }

  PluginFileScope fileScope() => PluginFileScope(
    pluginId: 'reveric.xiaoyunque',
    providerId: provider.id,
    taskId: 'task-1',
  );

  test(
    'passes through standard business error code and provider message',
    () async {
      const providerMessage =
          '不支持的视频模型：MiniMax-H3，请使用以下模型之一：seedance2.0_vision';
      final client = buildClient(
        (_) async => throw PluginExecutionError('rejected', providerMessage),
      );
      await expectLater(
        client.submit(submitInput(), fileScope()),
        throwsA(
          isA<VideoException>()
              .having((e) => e.code, 'code', VideoErrorCode.rejected)
              .having((e) => e.messageKey, 'messageKey', isNull)
              .having(
                (e) => e.providerMessage,
                'providerMessage',
                providerMessage,
              ),
        ),
      );
    },
  );

  test('recognizes known error patterns into localized keys', () async {
    final client = buildClient(
      (_) async =>
          throw PluginExecutionError('rejected', 'insufficient balance'),
    );
    await expectLater(
      client.submit(submitInput(), fileScope()),
      throwsA(
        isA<VideoException>()
            .having((e) => e.code, 'code', VideoErrorCode.rejected)
            .having(
              (e) => e.messageKey,
              'messageKey',
              LocaleKeys.aiProviderPaymentRequired,
            )
            .having((e) => e.providerMessage, 'providerMessage', isNull),
      ),
    );
  });

  test(
    'maps authentication and query not_found while hiding internal errors',
    () async {
      final authClient = buildClient(
        (_) async =>
            throw PluginExecutionError('authentication', '无效 Access Key'),
      );
      await expectLater(
        authClient.submit(submitInput(), fileScope()),
        throwsA(
          isA<VideoException>()
              .having((e) => e.code, 'code', VideoErrorCode.authentication)
              .having(
                (e) => e.providerMessage,
                'providerMessage',
                '无效 Access Key',
              ),
        ),
      );

      final queryClient = buildClient(
        (_) async => throw PluginExecutionError('not_found', '任务不存在'),
      );
      await expectLater(
        queryClient.query(ProviderQueryInput('remote-1')),
        throwsA(
          isA<VideoException>()
              .having((e) => e.code, 'code', VideoErrorCode.not_found)
              .having((e) => e.providerMessage, 'providerMessage', '任务不存在'),
        ),
      );

      final runtimeErrorClient = buildClient(
        (_) async => throw PluginExecutionError(
          'plugin_error',
          'TypeError: stack\n  at index.js:12',
        ),
      );
      await expectLater(
        runtimeErrorClient.submit(submitInput(), fileScope()),
        throwsA(
          isA<VideoException>()
              .having((e) => e.code, 'code', VideoErrorCode.submission_unknown)
              .having((e) => e.messageKey, 'messageKey', isNull)
              .having((e) => e.providerMessage, 'providerMessage', isNull),
        ),
      );

      final hostErrorClient = buildClient(
        (_) async => throw PluginHostError(
          'unavailable',
          'Provider plugin is not available',
        ),
      );
      await expectLater(
        hostErrorClient.submit(submitInput(), fileScope()),
        throwsA(
          isA<VideoException>()
              .having((e) => e.code, 'code', VideoErrorCode.unavailable)
              .having((e) => e.messageKey, 'messageKey', isNull)
              .having((e) => e.providerMessage, 'providerMessage', isNull),
        ),
      );
    },
  );
}
