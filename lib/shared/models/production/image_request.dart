// 职责: 冻结图片生成规格、最终提示词及提交时采用的参考素材。
// 关联文件:
//   lib/shared/services/production/image_generate_orchestrator.dart
//   lib/shared/database/type_converters.dart
//   lib/shared/services/ai/image.dart
import '../ai_provider.dart';
import '../image/channels.dart';
import 'view_presets.dart';

class ProductionImageDraft {
  const ProductionImageDraft({
    required this.prompt,
    required this.modelId,
    required this.ratio,
    required this.resolution,
    this.providerId,
    this.title,
    this.preset,
  });
  final String prompt;
  final String modelId;
  final String ratio;
  final String resolution;
  final String? providerId;
  final String? title;
  final ImageGenerationPreset? preset;
}

class ProductionImageReference {
  const ProductionImageReference({
    required this.assetId,
    this.clipId,
    this.inputId,
  });
  final String assetId;
  final String? clipId;
  final String? inputId;
  Map<String, dynamic> toJson() => {
    'clip_id': clipId,
    'input_id': inputId,
    'asset_id': assetId,
  };
  factory ProductionImageReference.fromJson(Map<String, dynamic> json) =>
      ProductionImageReference(
        assetId: json['asset_id'] as String,
        clipId: json['clip_id'] as String?,
        inputId: json['input_id'] as String?,
      );
}

class ProductionImageRequest {
  ProductionImageRequest({
    required this.providerId,
    required this.modelId,
    required this.originalPrompt,
    required this.prompt,
    required this.ratio,
    required this.resolution,
    required this.size,
    List<ProductionImageReference> references = const [],
  }) : references = List.unmodifiable(references);
  final String providerId;
  final String modelId;
  final String originalPrompt;
  final String prompt;
  final String ratio;
  final String resolution;
  final String? size;
  final List<ProductionImageReference> references;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'provider_id': providerId,
    'model_id': modelId,
    'original_prompt': originalPrompt,
    'prompt': prompt,
    'ratio': ratio,
    'resolution': resolution,
    'size': size,
    'references': references.map((r) => r.toJson()).toList(),
  };
  factory ProductionImageRequest.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported image request');
    }
    return ProductionImageRequest(
      providerId: json['provider_id'] as String,
      modelId: json['model_id'] as String,
      originalPrompt: json['original_prompt'] as String,
      prompt: json['prompt'] as String,
      ratio: json['ratio'] as String,
      resolution: json['resolution'] as String,
      size: json['size'] as String?,
      references: (json['references'] as List)
          .map(
            (r) => ProductionImageReference.fromJson(r as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}

/// 制作场景的图像能力：未登记型号开放常用规格及参考图，由服务端校验。
class ProductionImageCapabilities {
  const ProductionImageCapabilities(this.provider, this.model);
  final AiProvider provider;
  final String model;
  static bool supports(AiProvider provider) =>
      provider.typeConfig.imageProtocol != null;

  ImageChannelModel? get _channel =>
      lookupImageChannelModel(provider.type, model);
  ImageModelCapabilities get _capabilities =>
      _channel?.capabilities ??
      ImageModelCapabilities(
        ratios: _unlistedImageRatios,
        resolutions: const {'auto', '1K', '2K', '4K'},
        sizes: _usesRatioParameters ? const {} : _unlistedImageSizes,
        unlimitedReferences: true,
      );

  bool get _usesRatioParameters =>
      provider.typeConfig.imageProtocol == ImageProtocol.openrouter_image ||
      provider.typeConfig.imageProtocol == ImageProtocol.gemini_image ||
      (provider.typeConfig.imageProtocol == ImageProtocol.new_api_images &&
          model.startsWith('gemini-'));

  /// 渠道支持生图即可使用；未登记型号的参数由服务端验证。
  bool get isSupported => supports(provider);

  /// 只暴露渠道登记的能力，未登记型号返回 null。
  ImageModelCapabilities? get verifiedCapabilities =>
      supports(provider) ? _channel?.capabilities : null;

  List<String> get ratios => _capabilities.ratios.toList();
  List<String> get resolutions => _capabilities.resolutions.toList();

  /// null 表示没有本地数量上限，由服务端校验。
  int? get maxReferences =>
      _capabilities.unlimitedReferences ? null : _capabilities.maxReferences;
  bool allowsReferenceCount(int count) =>
      _capabilities.allowsReferenceCount(count);
  String? size(String ratio, String resolution) =>
      _capabilities.size(ratio, resolution);

  void validate({
    required String prompt,
    required String ratio,
    required String resolution,
    required int references,
  }) {
    if (!isSupported ||
        !provider.enabled ||
        !provider.availableImageModels.contains(model) ||
        prompt.trim().isEmpty) {
      throw const FormatException('Unsupported image generation configuration');
    }
    _capabilities.validateReferences(references);
    _capabilities.validateSize(size(ratio, resolution), references: references);
  }
}

// 自动选项排在首位；像素协议不能单独表达比例或分辨率时，分别以 1K、1:1 补齐。
const _unlistedImageRatios = {
  'auto',
  '1:1',
  '16:9',
  '9:16',
  '4:3',
  '3:4',
  '3:2',
  '2:3',
  '2:1',
  '1:2',
  '21:9',
};
const _unlistedImageBaseSizes = {
  'auto': (1024, 1024),
  '1:1': (1024, 1024),
  '16:9': (1024, 576),
  '9:16': (576, 1024),
  '4:3': (1024, 768),
  '3:4': (768, 1024),
  '3:2': (1008, 672),
  '2:3': (672, 1008),
  '2:1': (1024, 512),
  '1:2': (512, 1024),
  '21:9': (1008, 432),
};
final _unlistedImageSizes = {
  for (final tier in {'auto': 1, '1K': 1, '2K': 2, '4K': 4}.entries)
    tier.key: {
      for (final entry in _unlistedImageBaseSizes.entries)
        if (tier.key != 'auto' || entry.key != 'auto')
          entry.key:
              '${entry.value.$1 * tier.value}x${entry.value.$2 * tier.value}',
    },
};
