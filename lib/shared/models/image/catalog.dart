// 职责: 集中维护图像型号、模型能力与共用请求默认值。
// 关联文件:
//   lib/shared/models/image/config.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/models/production/image_request.dart

import '../model_config.dart' show ModelIdRecognizer;
import 'config.dart';
export 'config.dart';

class ImageModelCatalogEntry {
  const ImageModelCatalogEntry({
    required this.capabilities,
    this.aliases = const {},
    this.requestDefaults = const ImageRequestDefaults(),
  });
  final ImageModelCapabilities capabilities;
  final Set<String> aliases;
  final ImageRequestDefaults requestDefaults;
}

/// 运行时目录：获取模型后可登记站点返回的动态型号。
final imageModelsCatalog = <String, ImageModelCatalogEntry>{
  for (final id in ['midjourney', 'midjourney-v8.2'])
    id: ImageModelCatalogEntry(
      capabilities: ImageModelCapabilities(
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
        },
        resolutions: {'auto'},
      ),
    ),
  // https://platform.moss.cn/docs/reference/images-generations/
  'moss-image-base-1.0': _mossImage,
  'moss-image-sft-1.0': _mossImage,
  // https://agnes-ai.com/zh-Hans/docs/agnes-image-20-flash
  'agnes-image-2.0-flash': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {'1:1', '4:3', '3:4'},
      resolutions: {'1K'},
      sizes: {
        '1K': {'1:1': '1024x1024', '4:3': '1024x768', '3:4': '768x1024'},
      },
      maxReferences: 4,
    ),
    requestDefaults: _agnesImage20FlashDefaults,
  ),
  'agnes-image-2.1-flash': ImageModelCatalogEntry(
    capabilities: _agnesImage21FlashCapabilities,
    requestDefaults: _agnesImage20FlashDefaults,
  ),
  'agnes-image-2.5-flash': ImageModelCatalogEntry(
    capabilities: _agnesImage21FlashCapabilities,
    requestDefaults: _agnesImage20FlashDefaults,
  ),
  // https://help.aliyun.com/zh/model-studio/qwen-image-generation-and-editing-api-reference
  'qwen-image-3.0-pro': ImageModelCatalogEntry(
    capabilities: _qwenImage30ProCapabilities,
    requestDefaults: _qwenImage30ProDefaults,
  ),
  'qwen-image-3.0': ImageModelCatalogEntry(
    capabilities: _qwenImage30ProCapabilities,
    requestDefaults: _qwenImage30ProDefaults,
  ),
  'qwen-image-2.1-pro': ImageModelCatalogEntry(
    capabilities: _qwenImage21ProCapabilities,
    requestDefaults: _qwenImage30ProDefaults,
  ),
  'qwen-image-2.1-turbo': ImageModelCatalogEntry(
    capabilities: _qwenImage21ProCapabilities,
    requestDefaults: _qwenImage30ProDefaults,
  ),
  // https://help.aliyun.com/zh/model-studio/qwen-image-api
  'qwen-image-2.0-pro': ImageModelCatalogEntry(
    capabilities: _qwenImage30ProCapabilities,
    requestDefaults: _qwenImage30ProDefaults,
  ),
  'qwen-image-2.0': ImageModelCatalogEntry(
    capabilities: _qwenImage30ProCapabilities,
    requestDefaults: _qwenImage30ProDefaults,
  ),
  // https://help.aliyun.com/zh/model-studio/wan-image-generation-and-editing-api-reference
  'wan2.7-image-pro': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {'1:1', '16:9', '9:16', '4:3', '3:4'},
      resolutions: {'1K', '2K', '4K'},
      sizes: {
        '1K': {
          '1:1': '1024x1024',
          '16:9': '1344x768',
          '9:16': '768x1344',
          '4:3': '1184x864',
          '3:4': '864x1184',
        },
        '2K': {
          '1:1': '2048x2048',
          '16:9': '2688x1536',
          '9:16': '1536x2688',
          '4:3': '2368x1728',
          '3:4': '1728x2368',
        },
        '4K': {
          '1:1': '4096x4096',
          '16:9': '4096x2304',
          '9:16': '2304x4096',
          '4:3': '4096x3072',
          '3:4': '3072x4096',
        },
      },
      maxReferences: 9,
      minPixels: ConfigValue(589824),
      maxPixels: ConfigValue(16777216),
      maxEditPixels: ConfigValue(4194304),
      maxAspectRatio: ConfigValue(8),
    ),
    requestDefaults: ImageRequestDefaults(
      size: ConfigValue('2048x2048'),
      watermark: ConfigValue(false),
    ),
  ),
  // https://docs.volcengine.com/docs/ark/image-generation-api
  // Seedream 5.5：1K / 1.5K / 2K，总像素与宽高比同 5.0 pro，最多 10 张参考图。
  // 不支持组图、联网搜索和 fast 提示词优化。
  'seedream-5.5': ImageModelCatalogEntry(
    capabilities: _seedream50ProCapabilities,
    requestDefaults: _seedream50ProDefaults,
  ),
  'seedream-5.0-pro': ImageModelCatalogEntry(
    capabilities: _seedream50ProCapabilities,
    requestDefaults: _seedream50ProDefaults,
  ),
  'seedream-5.0-flash': ImageModelCatalogEntry(
    capabilities: _seedream50ProCapabilities,
    requestDefaults: _seedream50ProDefaults,
  ),
  'seedream-5.0-lite': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {'1:1', '16:9', '9:16', '4:3', '3:4'},
      resolutions: {'2K', '3K'},
      sizes: {
        '2K': {
          '1:1': '2048x2048',
          '16:9': '2560x1440',
          '9:16': '1440x2560',
          '4:3': '2304x1728',
          '3:4': '1728x2304',
        },
        '3K': {
          '1:1': '3072x3072',
          '16:9': '3840x2160',
          '9:16': '2160x3840',
          '4:3': '3456x2592',
          '3:4': '2592x3456',
        },
      },
      maxReferences: 14,
      minPixels: ConfigValue(3686400),
      maxPixels: ConfigValue(10404495),
      maxAspectRatio: ConfigValue(16),
    ),
    requestDefaults: _seedream50ProDefaults,
    // Ark 的 5.0 lite 端点名不带 lite。
    aliases: {'seedream-5-0'},
  ),
  'seedream-4.5': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {'1:1', '16:9', '9:16', '4:3', '3:4'},
      resolutions: {'2K', '4K'},
      sizes: {
        '2K': {
          '1:1': '2048x2048',
          '16:9': '2560x1440',
          '9:16': '1440x2560',
          '4:3': '2304x1728',
          '3:4': '1728x2304',
        },
        '4K': {
          '1:1': '4096x4096',
          '16:9': '5120x2880',
          '9:16': '2880x5120',
          '4:3': '4608x3456',
          '3:4': '3456x4608',
        },
      },
      maxReferences: 14,
      minPixels: ConfigValue(3686400),
      maxPixels: ConfigValue(16777216),
      maxAspectRatio: ConfigValue(16),
    ),
    requestDefaults: ImageRequestDefaults(
      size: ConfigValue('2048x2048'),
      responseFormat: ConfigValue('b64_json'),
      watermark: ConfigValue(false),
      promptOptimization: ConfigValue('standard'),
    ),
  ),
  'seedream-4.0': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {'1:1', '16:9', '9:16', '4:3', '3:4'},
      resolutions: {'1K', '2K', '4K'},
      sizes: {
        '1K': {
          '1:1': '1024x1024',
          '16:9': '1280x720',
          '9:16': '720x1280',
          '4:3': '1152x864',
          '3:4': '864x1152',
        },
        '2K': {
          '1:1': '2048x2048',
          '16:9': '2560x1440',
          '9:16': '1440x2560',
          '4:3': '2304x1728',
          '3:4': '1728x2304',
        },
        '4K': {
          '1:1': '4096x4096',
          '16:9': '5120x2880',
          '9:16': '2880x5120',
          '4:3': '4608x3456',
          '3:4': '3456x4608',
        },
      },
      maxReferences: 14,
      minPixels: ConfigValue(921600),
      maxPixels: ConfigValue(16777216),
      maxAspectRatio: ConfigValue(16),
    ),
    requestDefaults: ImageRequestDefaults(
      size: ConfigValue('2048x2048'),
      responseFormat: ConfigValue('b64_json'),
      watermark: ConfigValue(false),
      promptOptimization: ConfigValue('fast'),
    ),
  ),
  'gpt-image-2': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {'1:1', '16:9', '9:16', '4:3', '3:4'},
      resolutions: {'2K', '4K'},
      maxReferences: 16,
      minPixels: ConfigValue(655360),
      maxPixels: ConfigValue(8294400),
      sizes: {
        '2K': {
          '1:1': '2048x2048',
          '16:9': '2048x1152',
          '9:16': '1152x2048',
          '4:3': '2048x1536',
          '3:4': '1536x2048',
        },
        '4K': {
          '1:1': '2880x2880',
          '16:9': '3072x1728',
          '9:16': '1728x3072',
          '4:3': '3072x2304',
          '3:4': '2304x3072',
        },
      },
    ),
  ),
  'gpt-image-1': ImageModelCatalogEntry(capabilities: _gptImage1Capabilities),
  'gpt-image-1-mini': ImageModelCatalogEntry(
    capabilities: _gptImage1Capabilities,
  ),
  'gpt-image-1.5': ImageModelCatalogEntry(capabilities: _gptImage1Capabilities),
  'dall-e-3': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {'1:1', '16:9', '9:16'},
      resolutions: {'1K'},
      maxReferences: 0,
      sizes: {
        '1K': {'1:1': '1024x1024', '16:9': '1792x1024', '9:16': '1024x1792'},
      },
    ),
  ),
  // Published capabilities: https://openrouter.ai/api/v1/images/models
  'gemini-nano-banana-2.1': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {
        '1:1',
        '1:4',
        '1:8',
        '2:3',
        '3:2',
        '3:4',
        '4:1',
        '4:3',
        '4:5',
        '5:4',
        '8:1',
        '9:16',
        '16:9',
        '21:9',
      },
      resolutions: {'1K', '2K', '4K'},
      minReferences: 0,
      maxReferences: 14,
    ),
  ),
  'hy-image-v3.5-preview': ImageModelCatalogEntry(
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
      resolutions: {'1K', '1.5K', '2K', '4K'},
      minReferences: 0,
      maxReferences: 20,
    ),
  ),
  'flux-3-image': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {
        '21:9',
        '2:1',
        '16:9',
        '3:2',
        '7:5',
        '4:3',
        '5:4',
        '1:1',
        '4:5',
        '3:4',
        '5:7',
        '2:3',
        '9:16',
        '1:2',
        '9:21',
        'auto',
      },
      resolutions: {'768', '1K', '1.5K', '2K', '4K'},
      minReferences: 0,
      maxReferences: 10,
    ),
  ),
  'recraft-v4.1-flash': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {'1:1', '4:3', '3:4', '16:9', '9:16', 'auto'},
      resolutions: {'auto'},
      minReferences: 0,
      maxReferences: 0,
    ),
  ),
  'ming-image-0.1-design': ImageModelCatalogEntry(
    capabilities: _mingImage01DesignCapabilities,
  ),
  'gpt-image-2.6-sunburst': ImageModelCatalogEntry(
    capabilities: _gptImage26Capabilities,
    requestDefaults: _gptImage26Defaults,
  ),
  'gpt-image-2.6-flare': ImageModelCatalogEntry(
    capabilities: _gptImage26Capabilities,
    requestDefaults: _gptImage26Defaults,
  ),
  'gpt-image-2.5-sunburst': ImageModelCatalogEntry(
    capabilities: _gptImage25SunburstCapabilities,
  ),
  'gpt-image-2.5-flare': ImageModelCatalogEntry(
    capabilities: _gptImage25SunburstCapabilities,
  ),
  'mai-image-2.6': ImageModelCatalogEntry(
    capabilities: _maiImage26Capabilities,
  ),
  'mai-image-2.6-flash': ImageModelCatalogEntry(
    capabilities: _maiImage26Capabilities,
  ),
  'muse-image': ImageModelCatalogEntry(
    capabilities: _mingImage01DesignCapabilities,
  ),
  'recraft-v4-styles-pro': ImageModelCatalogEntry(
    capabilities: _recraftV4StylesProCapabilities,
  ),
  'recraft-v4-styles': ImageModelCatalogEntry(
    capabilities: _recraftV4StylesProCapabilities,
  ),
  'grok-imagine-image-2.0': ImageModelCatalogEntry(
    capabilities: _grokImagineImage20Capabilities,
  ),
  'mai-image-2.5-pro': ImageModelCatalogEntry(
    capabilities: _maiImage25ProCapabilities,
  ),
  'k3-edit': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {'1:1', '4:3', '3:2', '16:9', '4:5', '2:3', '9:16'},
      resolutions: {'1K', '2K'},
      minReferences: 1,
      maxReferences: 8,
    ),
  ),
  'krea-2-large': ImageModelCatalogEntry(capabilities: _krea2LargeCapabilities),
  'krea-2-medium': ImageModelCatalogEntry(
    capabilities: _krea2LargeCapabilities,
  ),
  'krea-2-medium-turbo': ImageModelCatalogEntry(
    capabilities: _krea2LargeCapabilities,
  ),
  'gemini-3.1-flash-lite-image': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {
        '1:1',
        '1:4',
        '1:8',
        '2:3',
        '3:2',
        '3:4',
        '4:1',
        '4:3',
        '4:5',
        '5:4',
        '8:1',
        '9:16',
        '16:9',
        '21:9',
      },
      resolutions: {'1K'},
      minReferences: 0,
      maxReferences: 14,
    ),
  ),
  'gemini-3.1-flash-image': ImageModelCatalogEntry(
    capabilities: _gemini31FlashImageCapabilities,
  ),
  'gemini-3-pro-image': ImageModelCatalogEntry(
    capabilities: _gemini3ProImageCapabilities,
  ),
  'riverflow-v2.5-pro': ImageModelCatalogEntry(
    capabilities: _riverflowV25ProCapabilities,
  ),
  'riverflow-v2.5-fast': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {
        '1:1',
        '4:3',
        '3:4',
        '3:2',
        '2:3',
        '16:9',
        '9:16',
        '21:9',
        'auto',
      },
      resolutions: {'1K', '2K'},
      minReferences: 0,
      maxReferences: 4,
    ),
  ),
  'mai-image-2.5': ImageModelCatalogEntry(
    capabilities: _maiImage25ProCapabilities,
  ),
  'grok-imagine-image-quality': ImageModelCatalogEntry(
    capabilities: _grokImagineImage20Capabilities,
  ),
  'recraft-v4.1-utility-pro': ImageModelCatalogEntry(
    capabilities: _recraftV41UtilityProCapabilities,
  ),
  'recraft-v4.1-utility': ImageModelCatalogEntry(
    capabilities: _recraftV41UtilityProCapabilities,
  ),
  'recraft-v4.1-pro': ImageModelCatalogEntry(
    capabilities: _recraftV41UtilityProCapabilities,
  ),
  'recraft-v4.1': ImageModelCatalogEntry(
    capabilities: _recraftV41UtilityProCapabilities,
  ),
  'recraft-v4-pro': ImageModelCatalogEntry(
    capabilities: _recraftV41UtilityProCapabilities,
  ),
  'recraft-v4': ImageModelCatalogEntry(
    capabilities: _recraftV41UtilityProCapabilities,
  ),
  'recraft-v3': ImageModelCatalogEntry(
    capabilities: _recraftV41UtilityProCapabilities,
  ),
  'gpt-5.4-image-2': ImageModelCatalogEntry(
    capabilities: _gpt54Image2Capabilities,
  ),
  'gemini-3.1-flash-image-preview': ImageModelCatalogEntry(
    capabilities: _gemini31FlashImageCapabilities,
  ),
  'riverflow-v2-pro': ImageModelCatalogEntry(
    capabilities: _riverflowV25ProCapabilities,
  ),
  'riverflow-v2-fast': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {
        '1:1',
        '4:3',
        '3:4',
        '3:2',
        '2:3',
        '16:9',
        '9:16',
        '21:9',
        'auto',
      },
      resolutions: {'1K', '2K', '4K'},
      minReferences: 0,
      maxReferences: 4,
    ),
  ),
  'flux.2-klein-4b': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {
        '1:1',
        '4:3',
        '3:4',
        '3:2',
        '2:3',
        '16:9',
        '9:16',
        '21:9',
        'auto',
      },
      resolutions: {'auto'},
      minReferences: 0,
      maxReferences: 4,
    ),
  ),
  'flux.2-max': ImageModelCatalogEntry(capabilities: _flux2MaxCapabilities),
  'flux.2-flex': ImageModelCatalogEntry(capabilities: _flux2MaxCapabilities),
  'flux.2-pro': ImageModelCatalogEntry(capabilities: _flux2MaxCapabilities),
  'gemini-3-pro-image-preview': ImageModelCatalogEntry(
    capabilities: _gemini3ProImageCapabilities,
  ),
  'gpt-5-image-mini': ImageModelCatalogEntry(
    capabilities: _gpt5ImageMiniCapabilities,
  ),
  'gpt-5-image': ImageModelCatalogEntry(
    capabilities: _gpt5ImageMiniCapabilities,
  ),
  // https://platform.minimax.io/docs/api-reference/image-generation-h3-generations
  // 比例加面积档位出图；显式宽高的总像素为 655360–20000000，宽高比 1:3–3:1。
  'MiniMax-H3-Image': ImageModelCatalogEntry(
    capabilities: _minimaxH3ImageCapabilities,
    requestDefaults: _minimaxH3ImageDefaults,
  ),
  'MiniMax-H3-Image-Highspeed': ImageModelCatalogEntry(
    capabilities: _minimaxH3ImageCapabilities,
    requestDefaults: _minimaxH3ImageDefaults,
  ),
  'gemini-2.5-flash-image': ImageModelCatalogEntry(
    capabilities: ImageModelCapabilities(
      ratios: {
        '1:1',
        '2:3',
        '3:2',
        '3:4',
        '4:3',
        '4:5',
        '5:4',
        '9:16',
        '16:9',
        '21:9',
      },
      resolutions: {'auto'},
      minReferences: 0,
      maxReferences: 3,
    ),
  ),
};

const _agnesImage21FlashCapabilities = ImageModelCapabilities(
  ratios: {'1:1', '3:4', '4:3', '16:9', '9:16', '2:3', '3:2', '21:9'},
  resolutions: {'1K', '2K', '3K', '4K'},
  sizes: {
    '1K': {
      '1:1': '1024x1024',
      '3:4': '864x1152',
      '4:3': '1152x864',
      '16:9': '1312x736',
      '9:16': '736x1312',
      '2:3': '832x1248',
      '3:2': '1248x832',
      '21:9': '1568x672',
    },
    '2K': {
      '1:1': '2048x2048',
      '3:4': '1728x2304',
      '4:3': '2304x1728',
      '16:9': '2624x1472',
      '9:16': '1472x2624',
      '2:3': '1664x2496',
      '3:2': '2496x1664',
      '21:9': '3136x1344',
    },
    '3K': {
      '1:1': '3072x3072',
      '3:4': '2592x3456',
      '4:3': '3456x2592',
      '16:9': '3936x2208',
      '9:16': '2208x3936',
      '2:3': '2496x3744',
      '3:2': '3744x2496',
      '21:9': '4704x2016',
    },
    '4K': {
      '1:1': '4096x4096',
      '3:4': '3456x4608',
      '4:3': '4608x3456',
      '16:9': '5248x2944',
      '9:16': '2944x5248',
      '2:3': '3328x4992',
      '3:2': '4992x3328',
      '21:9': '6272x2688',
    },
  },
  maxReferences: 4,
);

const _qwenImage30ProCapabilities = ImageModelCapabilities(
  ratios: {'1:1', '16:9', '9:16', '4:3', '3:4'},
  resolutions: {'1K', '2K'},
  sizes: {
    '1K': {
      '1:1': '1024x1024',
      '16:9': '1344x768',
      '9:16': '768x1344',
      '4:3': '1184x864',
      '3:4': '864x1184',
    },
    '2K': {
      '1:1': '2048x2048',
      '16:9': '2688x1536',
      '9:16': '1536x2688',
      '4:3': '2368x1728',
      '3:4': '1728x2368',
    },
  },
  maxReferences: 3,
  minPixels: ConfigValue(262144),
  maxPixels: ConfigValue(4194304),
  maxAspectRatio: ConfigValue(8),
);

const _qwenImage21ProCapabilities = ImageModelCapabilities(
  ratios: {'1:1', '16:9', '9:16', '4:3', '3:4'},
  resolutions: {'1K', '2K'},
  sizes: {
    '1K': {
      '1:1': '1024x1024',
      '16:9': '1344x768',
      '9:16': '768x1344',
      '4:3': '1184x864',
      '3:4': '864x1184',
    },
    '2K': {
      '1:1': '2048x2048',
      '16:9': '2688x1536',
      '9:16': '1536x2688',
      '4:3': '2368x1728',
      '3:4': '1728x2368',
    },
  },
  maxReferences: 10,
  minPixels: ConfigValue(262144),
  maxPixels: ConfigValue(4194304),
  maxAspectRatio: ConfigValue(8),
);

const _seedream50ProCapabilities = ImageModelCapabilities(
  ratios: {'1:1', '16:9', '9:16', '4:3', '3:4'},
  resolutions: {'1K', '1.5K', '2K'},
  sizes: {
    '1K': {
      '1:1': '1024x1024',
      '16:9': '1280x720',
      '9:16': '720x1280',
      '4:3': '1152x864',
      '3:4': '864x1152',
    },
    '1.5K': {
      '1:1': '1536x1536',
      '16:9': '1920x1080',
      '9:16': '1080x1920',
      '4:3': '1728x1296',
      '3:4': '1296x1728',
    },
    '2K': {
      '1:1': '2048x2048',
      '16:9': '2560x1440',
      '9:16': '1440x2560',
      '4:3': '2304x1728',
      '3:4': '1728x2304',
    },
  },
  maxReferences: 10,
  minPixels: ConfigValue(921600),
  maxPixels: ConfigValue(4624220),
  maxAspectRatio: ConfigValue(16),
);

const _gptImage1Capabilities = ImageModelCapabilities(
  ratios: {'1:1', '3:2', '2:3'},
  resolutions: {'1K'},
  maxReferences: 16,
  sizes: {
    '1K': {'1:1': '1024x1024', '3:2': '1536x1024', '2:3': '1024x1536'},
  },
);

const _mingImage01DesignCapabilities = ImageModelCapabilities(
  ratios: {'auto'},
  resolutions: {'auto'},
  minReferences: 0,
  maxReferences: 0,
);

const _gptImage25SunburstCapabilities = ImageModelCapabilities(
  ratios: {'1:1', '3:2', '2:3', '4:3', '3:4', '16:9', '9:16', '21:9', 'auto'},
  resolutions: {'1K', '2K', '4K'},
  minReferences: 0,
  maxReferences: 16,
);

const _gpt54Image2Capabilities = ImageModelCapabilities(
  ratios: {'1:1', '3:2', '2:3', '4:3', '3:4', '16:9', '9:16', '21:9', 'auto'},
  resolutions: {'auto'},
  minReferences: 0,
  maxReferences: 16,
);

const _gptImage26Capabilities = ImageModelCapabilities(
  ratios: {'1:1', '3:2', '2:3', '4:3', '3:4', '16:9', '9:16', '21:9', 'auto'},
  resolutions: {'1K', '2K', '4K'},
  minReferences: 0,
  maxReferences: 16,
  complexityLevels: {'low', 'medium', 'high'},
);

const _gptImage26Defaults = ImageRequestDefaults(
  complexity: ConfigValue('high'),
);

const _maiImage26Capabilities = ImageModelCapabilities(
  ratios: {'1:1', '4:3', '3:4', '16:9', '9:16', '3:2', '2:3', 'auto'},
  resolutions: {'auto'},
  minReferences: 0,
  maxReferences: 5,
);

const _recraftV4StylesProCapabilities = ImageModelCapabilities(
  ratios: {
    '1:1',
    '2:1',
    '1:2',
    '3:2',
    '2:3',
    '4:3',
    '3:4',
    '5:4',
    '4:5',
    '16:9',
    '9:16',
    'auto',
  },
  resolutions: {'auto'},
  minReferences: 1,
  maxReferences: 10,
);

const _grokImagineImage20Capabilities = ImageModelCapabilities(
  ratios: {
    '1:1',
    '3:4',
    '4:3',
    '9:16',
    '16:9',
    '2:3',
    '3:2',
    '9:19.5',
    '19.5:9',
    '9:20',
    '20:9',
    '1:2',
    '2:1',
    'auto',
  },
  resolutions: {'1K', '2K'},
  minReferences: 0,
  maxReferences: 3,
);

const _maiImage25ProCapabilities = ImageModelCapabilities(
  ratios: {'1:1', '4:3', '3:4', '16:9', '9:16', '3:2', '2:3', 'auto'},
  resolutions: {'auto'},
  minReferences: 0,
  maxReferences: 1,
);

const _krea2LargeCapabilities = ImageModelCapabilities(
  ratios: {'1:1', '4:3', '3:2', '16:9', '4:5', '2:3', '9:16'},
  resolutions: {'1K'},
  minReferences: 0,
  maxReferences: 1,
);

const _gemini31FlashImageCapabilities = ImageModelCapabilities(
  ratios: {
    '1:1',
    '1:4',
    '1:8',
    '2:3',
    '3:2',
    '3:4',
    '4:1',
    '4:3',
    '4:5',
    '5:4',
    '8:1',
    '9:16',
    '16:9',
    '21:9',
  },
  resolutions: {'512', '1K', '2K', '4K'},
  minReferences: 0,
  maxReferences: 14,
);

const _gemini3ProImageCapabilities = ImageModelCapabilities(
  ratios: {
    '1:1',
    '2:3',
    '3:2',
    '3:4',
    '4:3',
    '4:5',
    '5:4',
    '9:16',
    '16:9',
    '21:9',
  },
  resolutions: {'1K', '2K', '4K'},
  minReferences: 0,
  maxReferences: 14,
);

const _riverflowV25ProCapabilities = ImageModelCapabilities(
  ratios: {'1:1', '4:3', '3:4', '3:2', '2:3', '16:9', '9:16', '21:9', 'auto'},
  resolutions: {'1K', '2K', '4K'},
  minReferences: 0,
  maxReferences: 10,
);

const _recraftV41UtilityProCapabilities = ImageModelCapabilities(
  ratios: {'1:1', '4:3', '3:4', '16:9', '9:16', 'auto'},
  resolutions: {'auto'},
  minReferences: 0,
  maxReferences: 1,
);

const _flux2MaxCapabilities = ImageModelCapabilities(
  ratios: {'1:1', '4:3', '3:4', '3:2', '2:3', '16:9', '9:16', '21:9', 'auto'},
  resolutions: {'auto'},
  minReferences: 0,
  maxReferences: 8,
);

const _gpt5ImageMiniCapabilities = ImageModelCapabilities(
  ratios: {'1:1', '3:2', '2:3', 'auto'},
  resolutions: {'auto'},
  minReferences: 0,
  maxReferences: 16,
);

const _minimaxH3ImageCapabilities = ImageModelCapabilities(
  ratios: {
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
    '3:1',
    '1:3',
  },
  resolutions: {'1K', '2K', '4K'},
  maxReferences: 16,
  minPixels: ConfigValue(655360),
  maxPixels: ConfigValue(20000000),
  maxAspectRatio: ConfigValue(3),
);

const _minimaxH3ImageDefaults = ImageRequestDefaults(
  responseFormat: ConfigValue('b64_json'),
  outputFormat: ConfigValue('png'),
);

const _agnesImage20FlashDefaults = ImageRequestDefaults(
  size: ConfigValue('1024x1024'),
  responseFormat: ConfigValue('b64_json'),
);

const _qwenImage30ProDefaults = ImageRequestDefaults(
  size: ConfigValue('2048x2048'),
  watermark: ConfigValue(false),
  promptExtend: ConfigValue(true),
);

const _seedream50ProDefaults = ImageRequestDefaults(
  size: ConfigValue('2048x2048'),
  responseFormat: ConfigValue('b64_json'),
  outputFormat: ConfigValue('png'),
  watermark: ConfigValue(false),
  promptOptimization: ConfigValue('standard'),
);
final _imageModelRecognizer = ModelIdRecognizer({
  for (final entry in imageModelsCatalog.entries)
    entry.key: entry.value.aliases,
});

/// 渠道型号 ID 对应的目录 ID；规则见 [ModelIdRecognizer]。
String? recognizeImageModel(String? modelId) =>
    _imageModelRecognizer.recognize(modelId);

ImageModelCatalogEntry? lookupImageModel(String? modelId) =>
    imageModelsCatalog[recognizeImageModel(modelId)];

const _mossImage = ImageModelCatalogEntry(
  capabilities: ImageModelCapabilities(
    ratios: {'1:1', '16:9', '9:16', '4:3', '3:4'},
    resolutions: {'1K'},
    sizes: {
      '1K': {
        '1:1': '1024x1024',
        '16:9': '1536x864',
        '9:16': '864x1536',
        '4:3': '1024x768',
        '3:4': '768x1024',
      },
    },
    maxPixels: ConfigValue(2097152),
  ),
  requestDefaults: ImageRequestDefaults(
    size: ConfigValue('1024x1024'),
    responseFormat: ConfigValue('url'),
  ),
);
