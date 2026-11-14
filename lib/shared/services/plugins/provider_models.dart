// 职责: 携带一次模型发现的声明、实例配置指纹和刷新序号，供用户选择后原子保存。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/models/plugin/provider.dart
//   lib/shared/providers/settings_providers.dart
import '../../models/plugin/provider.dart';

class PluginProviderDiscovery {
  PluginProviderDiscovery({
    required this.providerId,
    required this.providerType,
    required this.epoch,
    required this.configurationHash,
    required Iterable<PluginProviderModel> models,
  }) : models = List.unmodifiable(models);
  final String providerId, providerType, configurationHash;
  final int epoch;
  final List<PluginProviderModel> models;
}
