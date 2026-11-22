// 职责: 从实例模型声明提供界面选项、默认偏好与严格规格解析，不改写显式的不支持参数。
// 关联文件:
//   lib/shared/models/provider_model.dart
//   lib/shared/models/production/image_request.dart
//   lib/shared/models/image/channels.dart
import '../ai_provider.dart';
import '../provider_model.dart';
import '../production/image_request.dart';
import 'channels.dart';

typedef CustomImageParameters = ({String? quality, String? size});

const CustomImageParameters defaultCustomImageParameters = (
  quality: null,
  size: null,
);

bool supportsCustomImageParameters(AiProvider provider, String model) =>
    resolveImageModel(provider, model) == null;

class ImageModelChoices {
  ImageModelChoices(this.provider, this.model)
    : capabilities = ProductionImageCapabilities(
        provider,
        model,
      ).effectiveCapabilities,
      defaults =
          resolveImageModel(provider, model)?.requestDefaults ??
          const ImageRequestDefaults(),
      rawDefaults = resolveImageModel(provider, model)?.rawDefaults ?? const {};
  final AiProvider provider;
  final String model;
  final ImageModelCapabilities capabilities;
  final ImageRequestDefaults defaults;
  final Map<String, dynamic> rawDefaults;
  bool get supportsCustomParameters =>
      supportsCustomImageParameters(provider, model);
  List<String> get ratios => capabilities.ratios.toList();
  List<String> get resolutions => capabilities.resolutions.toList();
  List<String> get complexities => capabilities.complexityLevels.toList();
  int? get referenceLimit =>
      capabilities.unlimitedReferences ? null : capabilities.maxReferences;
  List<String> get qualities {
    if (capabilities.qualityLevels.isNotEmpty) {
      return capabilities.qualityLevels.toList();
    }
    if (provider.isPluginProvider) {
      return [if (defaults.quality != null) defaults.quality!];
    }
    final options = lookupImageChannelModel(
      provider.type,
      model,
    )?.protocolOptions;
    if (options is AtlasCloudImageOptions && options.qualityLevels.isNotEmpty) {
      return options.qualityLevels.toList();
    }
    if ({
      ImageProtocol.openai_images,
      ImageProtocol.new_api_images,
      ImageProtocol.codex_image,
    }.contains(provider.typeConfig.imageProtocol)) {
      return ['auto', 'low', 'medium', 'high'];
    }
    return [if (defaults.quality != null) defaults.quality!];
  }

  String ratio(String value) {
    if (ratios.contains(value)) {
      return value;
    }
    final legacy = RegExp(r'^\d+_\d+$').hasMatch(value)
        ? value.replaceAll('_', ':')
        : value;
    return ratios.contains(legacy) ? legacy : value;
  }

  String resolution(String value) {
    if (resolutions.contains(value)) {
      return value;
    }
    final legacy = RegExp(r'^[124]k$').hasMatch(value)
        ? value.toUpperCase()
        : value;
    return resolutions.contains(legacy) ? legacy : value;
  }

  String defaultRatio(String preferred) {
    final value = ratio(preferred);
    if (ratios.contains(value)) {
      return value;
    }
    for (final sizes in capabilities.sizes.values) {
      for (final size in sizes.entries) {
        if (size.value == defaults.size) {
          return size.key;
        }
      }
    }
    return ratios.contains('auto') ? 'auto' : ratios.first;
  }

  String defaultResolution(String preferred) {
    final value = resolution(preferred);
    if (resolutions.contains(value)) {
      return value;
    }
    for (final sizes in capabilities.sizes.entries) {
      if (sizes.value.containsValue(defaults.size)) {
        return sizes.key;
      }
    }
    return resolutions.contains('auto') ? 'auto' : resolutions.first;
  }

  String? defaultQuality(String preferred) => qualities.contains(preferred)
      ? preferred
      : defaults.quality ?? qualities.firstOrNull;
  String? size(String selectedRatio, String selectedResolution) =>
      capabilities.size(ratio(selectedRatio), resolution(selectedResolution)) ??
      defaults.size;

  void validateCustomSize(String? size, {required int references}) {
    capabilities.validateReferences(references);
    capabilities.validateSize(size, references: references);
  }

  void validate({
    required String ratio,
    required String resolution,
    required int references,
    String? quality,
    String? complexity,
  }) {
    final pixels = size(ratio, resolution);
    capabilities.validateReferences(references);
    capabilities.validateSize(pixels, references: references);
    if (quality != null && !qualities.contains(quality)) {
      throw const FormatException('Unsupported image quality');
    }
    if (complexity != null && !complexities.contains(complexity)) {
      throw const FormatException('Unsupported image complexity');
    }
  }
}
