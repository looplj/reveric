// 职责: 按生图能力过滤选项并复用全局默认模型的选择顺序。
// 关联文件:
//   lib/shared/providers/settings_providers.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/models/production/image_request.dart
import '../../../../shared/models/ai_provider.dart';
import '../../../../shared/models/production/image_request.dart';

/// 能完成派生的生图模型：已启用、支持参考图；全景还要求支持 2:1。
List<AiModelOption> viewModelOptions({
  required List<AiModelOption> options,
  required List<AiProvider> providers,
  bool panorama = false,
}) => options.where((option) {
  final provider = providers
      .where((p) => p.id == option.providerId)
      .firstOrNull;
  if (provider == null || !provider.enabled) {
    return false;
  }
  final capabilities = ProductionImageCapabilities(provider, option.model);
  return capabilities.isSupported &&
      capabilities.allowsReferenceCount(1) &&
      (!panorama || capabilities.ratios.contains('2:1'));
}).toList();

AiModelOption? resolveViewModel({
  required List<AiModelOption> options,
  required List<AiProvider> providers,
  required String? preferredOptionId,
  bool panorama = false,
}) => resolveSelectableModelOption(
  options: viewModelOptions(
    options: options,
    providers: providers,
    panorama: panorama,
  ),
  preferredOptionId: preferredOptionId,
);
