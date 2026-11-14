// 职责: 将统一素材认证提交与状态查询派发到实例的插件方法。
// 关联文件:
//   lib/shared/services/ai/assets/client.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/files.dart
import '../../../agent/agent_tool_dispatcher.dart';
import '../../../models/ai_provider.dart';
import '../../../models/provider_asset.dart';
import '../../plugins/files.dart';
import '../../plugins/host.dart';
import 'client.dart';

class PluginAssetClient implements ProviderAssetClient {
  PluginAssetClient(this.provider, this.host);
  final AiProvider provider;
  final PluginHostService host;
  final _cancellation = AgentCancellationController();

  @override
  Future<ProviderAssetSubmission> submit({
    required ProviderAssetFile file,
    required String name,
  }) async {
    final scope = PluginFileScope(
      pluginId: provider.pluginId!,
      providerId: provider.id,
      taskId: file.assetId,
    );
    try {
      final info = await scope.register(
        file.file,
        name: name,
        mimeType: file.mimeType,
      );
      final value = await host.callProvider(
        provider,
        'assets.submit',
        input: {'file': info, 'name': name},
        files: scope,
        taskId: file.assetId,
        cancellation: _cancellation.token,
      );
      if (value is! Map) {
        throw const ProviderAssetException('invalid_response');
      }
      return (
        remoteId: _string(value, 'remoteId')!,
        remoteTaskId: _string(value, 'remoteTaskId', optional: true),
        remoteGroupId: _string(value, 'remoteGroupId', optional: true),
      );
    } finally {
      scope.revoke();
    }
  }

  @override
  Future<ProviderAssetState> state(String id) async {
    final value = await host.callProvider(
      provider,
      'assets.state',
      input: {'id': id},
      cancellation: _cancellation.token,
    );
    if (value is! Map) {
      throw const ProviderAssetException('invalid_response');
    }
    final status = switch (value['status']) {
      'processing' => ProviderAssetStatus.processing,
      'active' => ProviderAssetStatus.active,
      'failed' => ProviderAssetStatus.failed,
      _ => throw const ProviderAssetException('invalid_response'),
    };
    return (
      status: status,
      errorCode: _string(value, 'errorCode', optional: true),
      errorMessage: _string(value, 'errorMessage', optional: true),
    );
  }

  static String? _string(Map value, String key, {bool optional = false}) {
    final item = value[key];
    if (optional && item == null) {
      return null;
    }
    if (item is! String || item.trim().isEmpty) {
      throw const ProviderAssetException('invalid_response');
    }
    return item;
  }

  @override
  void close() => _cancellation.cancel();
}
