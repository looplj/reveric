// 职责: 按实例身份缓存已选择的插件模型声明，并通知模型消费者重新计算可用能力。
// 关联文件:
//   lib/shared/models/plugin/provider.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/providers/plugin_providers.dart
import 'package:flutter/foundation.dart';
import '../ai_provider.dart';
import 'provider.dart';

final pluginProviderModels = PluginProviderModelRegistry();

class PluginProviderModelRegistry extends ChangeNotifier {
  final _instances =
      <
        String,
        ({
          String type,
          Map<(AiModelKind, String), PluginProviderModel> models,
          String? error,
        })
      >{};
  final _refreshErrors =
      <String, ({String type, String code, String? detail})>{};
  int revision = 0;
  ({String code, String? detail})? refreshErrorFor(AiProvider provider) {
    final error = _refreshErrors[provider.id];
    return error?.type == provider.type
        ? (code: error!.code, detail: error.detail)
        : null;
  }

  void refreshFailed(
    AiProvider provider, {
    required String code,
    String? detail,
  }) {
    _refreshErrors[provider.id] = (
      type: provider.type,
      code: code,
      detail: detail,
    );
    changed();
  }

  PluginProviderModel? find(
    AiProvider provider,
    AiModelKind kind,
    String modelId,
  ) {
    final entry = _instances[provider.id];
    return entry?.type == provider.type ? entry?.models[(kind, modelId)] : null;
  }

  String? errorFor(AiProvider provider) {
    final entry = _instances[provider.id];
    return entry?.type == provider.type ? entry?.error : null;
  }

  void replace(
    AiProvider provider,
    Iterable<PluginProviderModel> models, {
    bool clearRefreshError = true,
  }) {
    if (clearRefreshError) {
      _refreshErrors.remove(provider.id);
    }
    _instances[provider.id] = (
      type: provider.type,
      models: {for (final model in models) (model.kind, model.id): model},
      error: null,
    );
    changed();
  }

  void invalid(AiProvider provider, String error) {
    _instances[provider.id] = (type: provider.type, models: {}, error: error);
    changed();
  }

  void remove(String providerId) {
    _refreshErrors.remove(providerId);
    if (_instances.remove(providerId) != null) {
      changed();
    }
  }

  void removePlugin(String pluginId) {
    _refreshErrors.removeWhere((_, entry) => entry.type == 'plugin:$pluginId');
    _instances.removeWhere((_, entry) => entry.type == 'plugin:$pluginId');
    changed();
  }

  void changed() {
    revision++;
    notifyListeners();
  }
}
