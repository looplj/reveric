// 职责: 组合图像渠道的型号映射、能力覆盖、请求默认值与协议要求，并按 provider 类型查找渠道型号。
// 关联文件:
//   lib/shared/models/image/catalog.dart
//   lib/shared/models/image/config.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json

import '../../localization/locale_keys.dart';
import '../ai_provider.dart' show ModelIdSource, aiProviderTypeConfigFor;
import 'catalog.dart';
export 'catalog.dart';

enum ImageProtocol {
  moss_image,
  agnes_image,
  qwen_image,
  ark_image,
  openrouter_image,
  atlascloud_image,
  openai_images,
  new_api_images,
  codex_image,
  gemini_image,
  purefox_media,
  minimax_image,
}

/// 只有对应协议才读取的渠道选项，每个协议一种类型。
sealed class ImageProtocolOptions {
  const ImageProtocolOptions();
}

enum MidjourneyProtocol { proxy, images, atlascloud }

class MidjourneyImageOptions extends ImageProtocolOptions {
  const MidjourneyImageOptions(this.protocol);
  final MidjourneyProtocol protocol;
}

class AgnesImageOptions extends ImageProtocolOptions {
  const AgnesImageOptions({this.sizeTiersWithRatio = false});

  /// 尺寸按「档位 + 比例」两个参数发送，而不是像素值。
  final bool sizeTiersWithRatio;
}

class QwenImageOptions extends ImageProtocolOptions {
  const QwenImageOptions({this.usesImagesApi = false});

  /// 走 OpenAI 风格的 images/generations，否则走多模态生成接口。
  final bool usesImagesApi;
}

class ArkImageOptions extends ImageProtocolOptions {
  const ArkImageOptions({this.requiresSequentialDisabled = false});
  final bool requiresSequentialDisabled;
}

class AtlasCloudImageOptions extends ImageProtocolOptions {
  const AtlasCloudImageOptions({
    this.editModel,
    this.sizeSeparator = 'x',
    this.usesResolution = false,
    this.qualityLevels = const {},
  });

  /// 带参考图时改用的模型路由。
  final String? editModel;
  final String sizeSeparator;

  /// 用比例 + 分辨率档位代替像素尺寸。
  final bool usesResolution;
  final Set<String> qualityLevels;
}

class ImageChannelModel {
  const ImageChannelModel({
    required this.catalogId,
    this.includedInPresets = true,
    this._capabilities = const ImageModelCapabilities(),
    this._requestDefaults = const ImageRequestDefaults(),
    this.protocolOptions,
  });
  final String catalogId;
  final bool includedInPresets;
  final ImageModelCapabilities _capabilities;
  final ImageRequestDefaults _requestDefaults;
  final ImageProtocolOptions? protocolOptions;
  ImageModelCatalogEntry get model => imageModelsCatalog[catalogId]!;
  ImageModelCapabilities get capabilities =>
      model.capabilities.merge(_capabilities);
  ImageRequestDefaults get requestDefaults =>
      model.requestDefaults.merge(_requestDefaults);
}

// OpenRouter selects the output size and format unless explicitly requested.
const _openrouterDefaults = ImageRequestDefaults(
  size: ConfigValue(null),
  responseFormat: ConfigValue(null),
  outputFormat: ConfigValue(null),
);

final imageChannelModels = <ImageProtocol, Map<String, ImageChannelModel>>{
  ..._listedImageChannels,
  ImageProtocol.moss_image: {
    for (final id in ['moss-image-base-1.0', 'moss-image-sft-1.0'])
      id: ImageChannelModel(catalogId: id),
  },
  ImageProtocol.new_api_images: {
    'mj_imagine': ImageChannelModel(
      catalogId: 'midjourney',
      protocolOptions: MidjourneyImageOptions(MidjourneyProtocol.proxy),
    ),
    for (final id in [
      'midjourney-v8.2',
      'midjourney-v8.2-fast',
      'midjourney-v8.2-turbo',
    ])
      id: ImageChannelModel(
        catalogId: 'midjourney-v8.2',
        protocolOptions: MidjourneyImageOptions(MidjourneyProtocol.images),
      ),
    ..._pixelSizeChannels,
    for (final id in imageModelsCatalog.keys.where(
      (id) => id.startsWith('gemini-'),
    ))
      id: ImageChannelModel(catalogId: id, includedInPresets: false),
    'doubao-seedream-5-5': ImageChannelModel(
      catalogId: 'seedream-5.5',
      includedInPresets: false,
    ),
    'doubao-seedream-5-0-pro': ImageChannelModel(
      catalogId: 'seedream-5.0-pro',
      includedInPresets: false,
    ),
  },
  ImageProtocol.openai_images: _pixelSizeChannels,
  ImageProtocol.codex_image: _pixelSizeChannels,
  ImageProtocol.gemini_image: _geminiChannels,
  ImageProtocol.purefox_media: purefoxMediaImageModels,
  // https://platform.minimax.io/docs/api-reference/image-generation-h3-generations
  ImageProtocol.minimax_image: {
    for (final id in ['MiniMax-H3-Image', 'MiniMax-H3-Image-Highspeed'])
      id: ImageChannelModel(catalogId: id),
  },
};

/// PureFox 媒体网关的图片型号目录：不预置，填 key 后按站点 `/v1/models`
/// 返回的 kind / qualities / refImages 登记。
final purefoxMediaImageModels = <String, ImageChannelModel>{};

const _listedImageChannels = <ImageProtocol, Map<String, ImageChannelModel>>{
  // https://www.atlascloud.ai/docs/openapi-index
  ImageProtocol.atlascloud_image: {
    'youchuan/v8.2/text-to-image': ImageChannelModel(
      catalogId: 'midjourney-v8.2',
      capabilities: ImageModelCapabilities(
        resolutions: {'auto', '2K'},
        ratios: {
          'auto',
          '1:1',
          '16:9',
          '9:16',
          '4:3',
          '3:4',
          '3:2',
          '2:3',
          '21:9',
          '9:21',
        },
      ),
      protocolOptions: MidjourneyImageOptions(MidjourneyProtocol.atlascloud),
    ),
    // https://static.atlascloud.ai/model/schema/openai-gpt-image-2.6-sunburst-text-to-image.json
    'openai/gpt-image-2.6-sunburst/text-to-image': ImageChannelModel(
      catalogId: 'gpt-image-2.6-sunburst',
      capabilities: _atlasGptImage25Capabilities,
      requestDefaults: _atlasGptImage25Defaults,
      protocolOptions: AtlasCloudImageOptions(
        editModel: 'openai/gpt-image-2.6-sunburst/edit',
        qualityLevels: {'auto', 'low', 'medium', 'high', 'xhigh', 'max'},
      ),
    ),
    'openai/gpt-image-2.6-flare/text-to-image': ImageChannelModel(
      catalogId: 'gpt-image-2.6-flare',
      capabilities: _atlasGptImage25Capabilities,
      requestDefaults: _atlasGptImage25Defaults,
      protocolOptions: AtlasCloudImageOptions(
        editModel: 'openai/gpt-image-2.6-flare/edit',
        qualityLevels: {'auto', 'low', 'medium', 'high', 'xhigh', 'max'},
      ),
    ),
    // https://static.atlascloud.ai/model/schema/openai-gpt-image-2.5-sunburst-text-to-image.json
    'openai/gpt-image-2.5-sunburst/text-to-image': ImageChannelModel(
      catalogId: 'gpt-image-2.5-sunburst',
      capabilities: _atlasGptImage25Capabilities,
      requestDefaults: _atlasGptImage25Defaults,
      protocolOptions: AtlasCloudImageOptions(
        editModel: 'openai/gpt-image-2.5-sunburst/edit',
        qualityLevels: {'auto', 'low', 'medium', 'high', 'xhigh', 'max'},
      ),
    ),
    'openai/gpt-image-2.5-flare/text-to-image': ImageChannelModel(
      catalogId: 'gpt-image-2.5-flare',
      capabilities: _atlasGptImage25Capabilities,
      requestDefaults: _atlasGptImage25Defaults,
      protocolOptions: AtlasCloudImageOptions(
        editModel: 'openai/gpt-image-2.5-flare/edit',
        qualityLevels: {'auto', 'low', 'medium', 'high', 'xhigh', 'max'},
      ),
    ),
    'bytedance/seedream-v5.0-pro/text-to-image': ImageChannelModel(
      catalogId: 'seedream-5.0-pro',
      capabilities: ImageModelCapabilities(
        ratios: {'1:1', '4:3', '3:4', '16:9', '9:16'},
        resolutions: {'1.5K', '2K'},
        sizes: {
          '1.5K': {
            '1:1': '1536x1536',
            '4:3': '1776x1328',
            '3:4': '1328x1776',
            '16:9': '2048x1152',
            '9:16': '1152x2048',
          },
          '2K': {
            '1:1': '2048x2048',
            '4:3': '2368x1776',
            '3:4': '1776x2368',
            '16:9': '2816x1584',
            '9:16': '1584x2816',
          },
        },
        maxReferences: 10,
        minPixels: ConfigValue(null),
        maxPixels: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudImageOptions(
        editModel: 'bytedance/seedream-v5.0-pro/edit',
        sizeSeparator: '*',
      ),
    ),
    'bytedance/seedream-v5.0-lite': ImageChannelModel(
      catalogId: 'seedream-5.0-lite',
      capabilities: ImageModelCapabilities(
        sizes: {
          '2K': {
            '1:1': '2048x2048',
            '4:3': '2304x1728',
            '3:4': '1728x2304',
            '16:9': '2848x1600',
            '9:16': '1600x2848',
          },
          '3K': {
            '1:1': '3072x3072',
            '4:3': '3456x2592',
            '3:4': '2592x3456',
            '16:9': '4096x2304',
            '9:16': '2304x4096',
          },
        },
      ),
      protocolOptions: AtlasCloudImageOptions(
        editModel: 'bytedance/seedream-v5.0-lite/edit',
        sizeSeparator: '*',
      ),
    ),
    'google/nano-banana-2/text-to-image': ImageChannelModel(
      catalogId: 'gemini-3.1-flash-image',
      capabilities: _atlasBananaCapabilities,
      requestDefaults: _atlasBananaDefaults,
      protocolOptions: AtlasCloudImageOptions(
        editModel: 'google/nano-banana-2/edit',
        usesResolution: true,
      ),
    ),
    'google/nano-banana-pro/text-to-image': ImageChannelModel(
      catalogId: 'gemini-3-pro-image',
      capabilities: ImageModelCapabilities(
        ratios: _atlasBananaRatios,
        resolutions: {'1K', '2K', '4K'},
        sizes: {},
        maxReferences: 10,
      ),
      requestDefaults: _atlasBananaDefaults,
      protocolOptions: AtlasCloudImageOptions(
        editModel: 'google/nano-banana-pro/edit',
        usesResolution: true,
      ),
    ),
    'openai/gpt-image-2/text-to-image': ImageChannelModel(
      catalogId: 'gpt-image-2',
      capabilities: ImageModelCapabilities(
        ratios: {'1:1', '3:2', '2:3'},
        resolutions: {'1K'},
        sizes: {
          '1K': {'1:1': '1024x1024', '3:2': '1536x1024', '2:3': '1024x1536'},
        },
        maxReferences: 10,
      ),
      requestDefaults: ImageRequestDefaults(size: ConfigValue('1024x1024')),
      protocolOptions: AtlasCloudImageOptions(
        editModel: 'openai/gpt-image-2/edit',
        qualityLevels: {'low', 'medium', 'high'},
      ),
    ),
  },
  ImageProtocol.agnes_image: {
    'agnes-image-2.0-flash': ImageChannelModel(
      catalogId: 'agnes-image-2.0-flash',
    ),
    'agnes-image-2.1-flash': ImageChannelModel(
      catalogId: 'agnes-image-2.1-flash',
      protocolOptions: AgnesImageOptions(sizeTiersWithRatio: true),
    ),
    'agnes-image-2.5-flash': ImageChannelModel(
      catalogId: 'agnes-image-2.5-flash',
      protocolOptions: AgnesImageOptions(sizeTiersWithRatio: true),
    ),
  },
  ImageProtocol.qwen_image: {
    'qwen-image-3.0-pro': ImageChannelModel(
      catalogId: 'qwen-image-3.0-pro',
      protocolOptions: QwenImageOptions(usesImagesApi: true),
    ),
    'qwen-image-3.0': ImageChannelModel(
      catalogId: 'qwen-image-3.0',
      protocolOptions: QwenImageOptions(usesImagesApi: true),
    ),
    'qwen-image-2.1-pro': ImageChannelModel(
      catalogId: 'qwen-image-2.1-pro',
      includedInPresets: false,
      protocolOptions: QwenImageOptions(usesImagesApi: true),
    ),
    'qwen-image-2.1-turbo': ImageChannelModel(
      catalogId: 'qwen-image-2.1-turbo',
      includedInPresets: false,
      protocolOptions: QwenImageOptions(usesImagesApi: true),
    ),
    'qwen-image-2.0-pro': ImageChannelModel(
      catalogId: 'qwen-image-2.0-pro',
      includedInPresets: false,
    ),
    'qwen-image-2.0': ImageChannelModel(
      catalogId: 'qwen-image-2.0',
      includedInPresets: false,
    ),
    'wan2.7-image-pro': ImageChannelModel(catalogId: 'wan2.7-image-pro'),
  },
  ImageProtocol.ark_image: {
    'doubao-seedream-5-5-261028': ImageChannelModel(catalogId: 'seedream-5.5'),
    'doubao-seedream-5-0-pro-260628': ImageChannelModel(
      catalogId: 'seedream-5.0-pro',
    ),
    'doubao-seedream-5-0-flash-260915': ImageChannelModel(
      catalogId: 'seedream-5.0-flash',
    ),
    'doubao-seedream-5-0-260128': ImageChannelModel(
      catalogId: 'seedream-5.0-lite',
      protocolOptions: ArkImageOptions(requiresSequentialDisabled: true),
    ),
    'doubao-seedream-4-5-251128': ImageChannelModel(
      catalogId: 'seedream-4.5',
      protocolOptions: ArkImageOptions(requiresSequentialDisabled: true),
    ),
    'doubao-seedream-4-0-250828': ImageChannelModel(
      catalogId: 'seedream-4.0',
      protocolOptions: ArkImageOptions(requiresSequentialDisabled: true),
    ),
  },
  ImageProtocol.openrouter_image: {
    // https://openrouter.ai/api/v1/images/models
    'qwen/qwen-image-2.1-turbo': ImageChannelModel(
      catalogId: 'qwen-image-2.1-turbo',
      includedInPresets: false,
      capabilities: ImageModelCapabilities(
        ratios: {
          '1:1',
          '1:2',
          '1:4',
          '2:1',
          '2:3',
          '3:2',
          '3:4',
          '4:1',
          '4:3',
          '4:5',
          '5:4',
          '9:16',
          '16:9',
        },
        resolutions: {'1K', '2K'},
        sizes: {},
        maxReferences: 4,
        minPixels: ConfigValue(null),
        maxPixels: ConfigValue(null),
        maxAspectRatio: ConfigValue(null),
      ),
      requestDefaults: _openrouterDefaults,
    ),
    'krea/k3-edit': ImageChannelModel(
      catalogId: 'k3-edit',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'google/gemini-nano-banana-2.1': ImageChannelModel(
      catalogId: 'gemini-nano-banana-2.1',
      requestDefaults: _openrouterDefaults,
    ),
    'tencent/hy-image-v3.5-preview': ImageChannelModel(
      catalogId: 'hy-image-v3.5-preview',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'bytedance-seed/seedream-5-0-flash': ImageChannelModel(
      catalogId: 'seedream-5.0-flash',
      includedInPresets: false,
      capabilities: ImageModelCapabilities(
        ratios: {
          '1:1',
          '1:2',
          '2:1',
          '2:3',
          '3:2',
          '3:4',
          '4:3',
          '4:5',
          '5:4',
          '9:16',
          '16:9',
          '9:19.5',
          '19.5:9',
          '9:20',
          '20:9',
          '9:21',
          '21:9',
          'auto',
        },
        resolutions: {'1K', '2K'},
        sizes: {},
        maxReferences: 14,
        minPixels: ConfigValue(null),
        maxPixels: ConfigValue(null),
        maxAspectRatio: ConfigValue(null),
      ),
      requestDefaults: _openrouterDefaults,
    ),
    'black-forest-labs/flux-3-image': ImageChannelModel(
      catalogId: 'flux-3-image',
      requestDefaults: _openrouterDefaults,
    ),
    'recraft/recraft-v4.1-flash': ImageChannelModel(
      catalogId: 'recraft-v4.1-flash',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'inclusionai/ming-image-0.1-design': ImageChannelModel(
      catalogId: 'ming-image-0.1-design',
      includedInPresets: false,
      requestDefaults: ImageRequestDefaults(outputFormat: ConfigValue('png')),
    ),
    'openai/gpt-image-2.6-sunburst': ImageChannelModel(
      catalogId: 'gpt-image-2.6-sunburst',
      requestDefaults: _openrouterDefaults,
    ),
    'openai/gpt-image-2.6-flare': ImageChannelModel(
      catalogId: 'gpt-image-2.6-flare',
      requestDefaults: _openrouterDefaults,
    ),
    'openai/gpt-image-2.5-sunburst': ImageChannelModel(
      catalogId: 'gpt-image-2.5-sunburst',
      requestDefaults: _openrouterDefaults,
    ),
    'openai/gpt-image-2.5-flare': ImageChannelModel(
      catalogId: 'gpt-image-2.5-flare',
      requestDefaults: _openrouterDefaults,
    ),
    'microsoft/mai-image-2.6': ImageChannelModel(
      catalogId: 'mai-image-2.6',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'microsoft/mai-image-2.6-flash': ImageChannelModel(
      catalogId: 'mai-image-2.6-flash',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'meta/muse-image': ImageChannelModel(
      catalogId: 'muse-image',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'recraft/recraft-v4-styles-pro': ImageChannelModel(
      catalogId: 'recraft-v4-styles-pro',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'recraft/recraft-v4-styles': ImageChannelModel(
      catalogId: 'recraft-v4-styles',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'bytedance-seed/seedream-5-0-lite': ImageChannelModel(
      catalogId: 'seedream-5.0-lite',
      includedInPresets: false,
      capabilities: ImageModelCapabilities(
        ratios: {
          '1:1',
          '1:2',
          '2:1',
          '2:3',
          '3:2',
          '3:4',
          '4:3',
          '4:5',
          '5:4',
          '9:16',
          '16:9',
          '9:19.5',
          '19.5:9',
          '9:20',
          '20:9',
          '9:21',
          '21:9',
          'auto',
        },
        resolutions: {'2K', '4K'},
        sizes: {},
        maxReferences: 14,
        minPixels: ConfigValue(null),
        maxPixels: ConfigValue(null),
        maxAspectRatio: ConfigValue(null),
      ),
      requestDefaults: _openrouterDefaults,
    ),
    'bytedance-seed/seedream-5-0-pro': ImageChannelModel(
      catalogId: 'seedream-5.0-pro',
      capabilities: ImageModelCapabilities(
        ratios: {
          '1:1',
          '1:2',
          '2:1',
          '2:3',
          '3:2',
          '3:4',
          '4:3',
          '4:5',
          '5:4',
          '9:16',
          '16:9',
          '9:19.5',
          '19.5:9',
          '9:20',
          '20:9',
          '9:21',
          '21:9',
          'auto',
        },
        resolutions: {'1K', '2K'},
        sizes: {},
        maxReferences: 14,
        minPixels: ConfigValue(null),
        maxPixels: ConfigValue(null),
        maxAspectRatio: ConfigValue(null),
      ),
      requestDefaults: _openrouterDefaults,
    ),
    'x-ai/grok-imagine-image-2.0': ImageChannelModel(
      catalogId: 'grok-imagine-image-2.0',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'qwen/qwen-image-3-pro': ImageChannelModel(
      catalogId: 'qwen-image-3.0-pro',
      includedInPresets: false,
      capabilities: ImageModelCapabilities(
        ratios: {
          '1:1',
          '1:2',
          '1:4',
          '2:1',
          '2:3',
          '3:2',
          '3:4',
          '4:1',
          '4:3',
          '4:5',
          '5:4',
          '9:16',
          '16:9',
        },
        resolutions: {'1K', '2K'},
        sizes: {},
        maxReferences: 4,
        minPixels: ConfigValue(null),
        maxPixels: ConfigValue(null),
        maxAspectRatio: ConfigValue(null),
      ),
      requestDefaults: _openrouterDefaults,
    ),
    'qwen/qwen-image-3': ImageChannelModel(
      catalogId: 'qwen-image-3.0',
      capabilities: ImageModelCapabilities(
        ratios: {
          '1:1',
          '1:2',
          '1:4',
          '2:1',
          '2:3',
          '3:2',
          '3:4',
          '4:1',
          '4:3',
          '4:5',
          '5:4',
          '9:16',
          '16:9',
        },
        resolutions: {'1K', '2K'},
        sizes: {},
        maxReferences: 4,
        minPixels: ConfigValue(null),
        maxPixels: ConfigValue(null),
        maxAspectRatio: ConfigValue(null),
      ),
      requestDefaults: _openrouterDefaults,
    ),
    'microsoft/mai-image-2.5-pro': ImageChannelModel(
      catalogId: 'mai-image-2.5-pro',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'krea/krea-2-large': ImageChannelModel(
      catalogId: 'krea-2-large',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'krea/krea-2-medium': ImageChannelModel(
      catalogId: 'krea-2-medium',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'krea/krea-2-medium-turbo': ImageChannelModel(
      catalogId: 'krea-2-medium-turbo',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'google/gemini-3.1-flash-lite-image': ImageChannelModel(
      catalogId: 'gemini-3.1-flash-lite-image',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'openai/gpt-image-2': ImageChannelModel(
      catalogId: 'gpt-image-2',
      capabilities: ImageModelCapabilities(
        ratios: {
          '1:1',
          '3:2',
          '2:3',
          '4:3',
          '3:4',
          '16:9',
          '9:16',
          '21:9',
          'auto',
        },
        resolutions: {'auto'},
        sizes: {},
        maxReferences: 16,
        minPixels: ConfigValue(null),
        maxPixels: ConfigValue(null),
        maxAspectRatio: ConfigValue(null),
      ),
      requestDefaults: _openrouterDefaults,
    ),
    'openai/gpt-image-1-mini': ImageChannelModel(
      catalogId: 'gpt-image-1-mini',
      includedInPresets: false,
      capabilities: ImageModelCapabilities(
        ratios: {'1:1', '3:2', '2:3', 'auto'},
        resolutions: {'auto'},
        sizes: {},
        maxReferences: 16,
        minPixels: ConfigValue(null),
        maxPixels: ConfigValue(null),
        maxAspectRatio: ConfigValue(null),
      ),
      requestDefaults: _openrouterDefaults,
    ),
    'openai/gpt-image-1': ImageChannelModel(
      catalogId: 'gpt-image-1',
      includedInPresets: false,
      capabilities: ImageModelCapabilities(
        ratios: {'1:1', '3:2', '2:3', 'auto'},
        resolutions: {'auto'},
        sizes: {},
        maxReferences: 16,
        minPixels: ConfigValue(null),
        maxPixels: ConfigValue(null),
        maxAspectRatio: ConfigValue(null),
      ),
      requestDefaults: _openrouterDefaults,
    ),
    'google/gemini-3.1-flash-image': ImageChannelModel(
      catalogId: 'gemini-3.1-flash-image',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'google/gemini-3-pro-image': ImageChannelModel(
      catalogId: 'gemini-3-pro-image',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'sourceful/riverflow-v2.5-pro': ImageChannelModel(
      catalogId: 'riverflow-v2.5-pro',
      includedInPresets: false,
      requestDefaults: ImageRequestDefaults(outputFormat: ConfigValue('png')),
    ),
    'sourceful/riverflow-v2.5-fast': ImageChannelModel(
      catalogId: 'riverflow-v2.5-fast',
      includedInPresets: false,
      requestDefaults: ImageRequestDefaults(outputFormat: ConfigValue('jpeg')),
    ),
    'microsoft/mai-image-2.5': ImageChannelModel(
      catalogId: 'mai-image-2.5',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'x-ai/grok-imagine-image-quality': ImageChannelModel(
      catalogId: 'grok-imagine-image-quality',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'recraft/recraft-v4.1-utility-pro': ImageChannelModel(
      catalogId: 'recraft-v4.1-utility-pro',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'recraft/recraft-v4.1-utility': ImageChannelModel(
      catalogId: 'recraft-v4.1-utility',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'recraft/recraft-v4.1-pro': ImageChannelModel(
      catalogId: 'recraft-v4.1-pro',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'recraft/recraft-v4.1': ImageChannelModel(
      catalogId: 'recraft-v4.1',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'recraft/recraft-v4-pro': ImageChannelModel(
      catalogId: 'recraft-v4-pro',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'recraft/recraft-v4': ImageChannelModel(
      catalogId: 'recraft-v4',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'recraft/recraft-v3': ImageChannelModel(
      catalogId: 'recraft-v3',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'openai/gpt-5.4-image-2': ImageChannelModel(
      catalogId: 'gpt-5.4-image-2',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'google/gemini-3.1-flash-image-preview': ImageChannelModel(
      catalogId: 'gemini-3.1-flash-image-preview',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'sourceful/riverflow-v2-pro': ImageChannelModel(
      catalogId: 'riverflow-v2-pro',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'sourceful/riverflow-v2-fast': ImageChannelModel(
      catalogId: 'riverflow-v2-fast',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'black-forest-labs/flux.2-klein-4b': ImageChannelModel(
      catalogId: 'flux.2-klein-4b',
      includedInPresets: false,
      requestDefaults: ImageRequestDefaults(outputFormat: ConfigValue('png')),
    ),
    'bytedance-seed/seedream-4.5': ImageChannelModel(
      catalogId: 'seedream-4.5',
      includedInPresets: false,
      capabilities: ImageModelCapabilities(
        ratios: {
          '1:1',
          '1:2',
          '2:1',
          '2:3',
          '3:2',
          '3:4',
          '4:3',
          '4:5',
          '5:4',
          '9:16',
          '16:9',
          '9:19.5',
          '19.5:9',
          '9:20',
          '20:9',
          '9:21',
          '21:9',
          'auto',
        },
        resolutions: {'1K', '2K', '4K'},
        sizes: {},
        maxReferences: 14,
        minPixels: ConfigValue(null),
        maxPixels: ConfigValue(null),
        maxAspectRatio: ConfigValue(null),
      ),
      requestDefaults: _openrouterDefaults,
    ),
    'black-forest-labs/flux.2-max': ImageChannelModel(
      catalogId: 'flux.2-max',
      includedInPresets: false,
      requestDefaults: ImageRequestDefaults(outputFormat: ConfigValue('png')),
    ),
    'black-forest-labs/flux.2-flex': ImageChannelModel(
      catalogId: 'flux.2-flex',
      includedInPresets: false,
      requestDefaults: ImageRequestDefaults(outputFormat: ConfigValue('png')),
    ),
    'black-forest-labs/flux.2-pro': ImageChannelModel(
      catalogId: 'flux.2-pro',
      includedInPresets: false,
      requestDefaults: ImageRequestDefaults(outputFormat: ConfigValue('png')),
    ),
    'google/gemini-3-pro-image-preview': ImageChannelModel(
      catalogId: 'gemini-3-pro-image-preview',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'openai/gpt-5-image-mini': ImageChannelModel(
      catalogId: 'gpt-5-image-mini',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'openai/gpt-5-image': ImageChannelModel(
      catalogId: 'gpt-5-image',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
    'google/gemini-2.5-flash-image': ImageChannelModel(
      catalogId: 'gemini-2.5-flash-image',
      includedInPresets: false,
      requestDefaults: _openrouterDefaults,
    ),
  },
};

/// 按 provider 类型查找渠道型号：先精确匹配渠道 ID；可接中转站的渠道再从 ID
/// 中识别目录型号。找不到时返回 null，是否允许使用由业务层决定。
ImageChannelModel? lookupImageChannelModel(
  String providerType,
  String? modelId,
) {
  final config = aiProviderTypeConfigFor(providerType);
  final models = imageChannelModels[config?.imageProtocol];
  if (config == null || models == null) {
    return null;
  }
  final exact = models[modelId?.trim()];
  if (exact != null || config.modelIdSource == ModelIdSource.registered) {
    return exact;
  }
  final catalogId = recognizeImageModel(modelId);
  return models.values
      .where((channel) => channel.catalogId == catalogId)
      .firstOrNull;
}

({ImageModelCapabilities capabilities, ImageRequestDefaults defaults})?
_imageSpec(String providerType, String? modelId) {
  final channel = lookupImageChannelModel(providerType, modelId);
  if (channel != null) {
    return (
      capabilities: channel.capabilities,
      defaults: channel.requestDefaults,
    );
  }
  final entry = lookupImageModel(modelId);
  if (entry == null) {
    return null;
  }
  return (capabilities: entry.capabilities, defaults: entry.requestDefaults);
}

Set<String> imageComplexityLevels(String providerType, String? modelId) =>
    _imageSpec(providerType, modelId)?.capabilities.complexityLevels ??
    const {};

/// 型号没有复杂度档位时返回 null。有档位但没选中、或选中值不在目录里时，用目录默认值。
String? imageComplexityFor(
  String providerType,
  String? modelId,
  String? selected,
) {
  final spec = _imageSpec(providerType, modelId);
  if (spec == null || spec.capabilities.complexityLevels.isEmpty) {
    return null;
  }
  if (selected != null &&
      spec.capabilities.complexityLevels.contains(selected)) {
    return selected;
  }
  final fallback = spec.defaults.complexity;
  if (fallback != null &&
      spec.capabilities.complexityLevels.contains(fallback)) {
    return fallback;
  }
  return null;
}

/// 目录外的档位返回 null，由界面直接显示原值。
String? imageComplexityLabelKey(String level) => switch (level) {
  'low' => LocaleKeys.commonComplexityLow,
  'medium' => LocaleKeys.commonComplexityMedium,
  'high' => LocaleKeys.commonComplexityHigh,
  _ => null,
};

List<String> imageModelsForProvider(String providerType) =>
    imageChannelModels[aiProviderTypeConfigFor(providerType)?.imageProtocol]
        ?.entries
        .where((entry) => entry.value.includedInPresets)
        .map((entry) => entry.key)
        .toList(growable: false) ??
    const [];

// OpenAI Images 与 Codex 按像素尺寸编码，只能承载登记了尺寸表的目录型号。
final _pixelSizeChannels = {
  for (final entry in imageModelsCatalog.entries)
    if (entry.value.capabilities.sizes.isNotEmpty)
      entry.key: ImageChannelModel(
        catalogId: entry.key,
        includedInPresets: false,
      ),
};

// Gemini 直连与网关共用 generateContent 契约，直接沿用目录登记的 Gemini 能力。
final _geminiChannels = {
  for (final id in imageModelsCatalog.keys.where(
    (id) => id.startsWith('gemini-'),
  ))
    id: ImageChannelModel(catalogId: id, includedInPresets: false),
};

const _atlasBananaRatios = {
  '1:1',
  '3:2',
  '2:3',
  '3:4',
  '4:3',
  '4:5',
  '5:4',
  '9:16',
  '16:9',
  '21:9',
};
const _atlasBananaCapabilities = ImageModelCapabilities(
  ratios: _atlasBananaRatios,
  resolutions: {'1K', '2K', '4K'},
  sizes: {},
  maxReferences: 14,
);
const _atlasBananaDefaults = ImageRequestDefaults(
  size: ConfigValue(null),
  outputFormat: ConfigValue('png'),
);

// AtlasCloud accepts WIDTHxHEIGHT; each edge must be divisible by 16.
const _atlasGptImage25Capabilities = ImageModelCapabilities(
  ratios: {'1:1', '4:3', '3:4', '16:9', '9:16'},
  resolutions: {'1K', '2K', '4K'},
  maxReferences: 16,
  maxPixels: ConfigValue(8294400),
  maxAspectRatio: ConfigValue(3),
  // 这组 schema 没有 complexity，空集盖掉目录里 2.6 的复杂度档位。
  complexityLevels: {},
  sizes: {
    '1K': {
      '1:1': '1024x1024',
      '4:3': '1024x768',
      '3:4': '768x1024',
      '16:9': '1536x864',
      '9:16': '864x1536',
    },
    '2K': {
      '1:1': '2048x2048',
      '4:3': '2048x1536',
      '3:4': '1536x2048',
      '16:9': '2048x1152',
      '9:16': '1152x2048',
    },
    '4K': {
      '1:1': '2880x2880',
      '4:3': '2880x2160',
      '3:4': '2160x2880',
      '16:9': '3840x2160',
      '9:16': '2160x3840',
    },
  },
);
const _atlasGptImage25Defaults = ImageRequestDefaults(
  size: ConfigValue('1024x1024'),
  outputFormat: ConfigValue('png'),
);
