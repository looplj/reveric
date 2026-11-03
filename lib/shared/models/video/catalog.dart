// 职责: 集中维护视频型号、独立能力与共用请求默认值。
// 关联文件:
//   lib/shared/models/video/config.dart
//   lib/shared/models/video/channels.dart

import 'request.dart';
import '../model_config.dart' show ModelIdRecognizer;
import 'config.dart';
export 'config.dart';

class VideoModelCatalogEntry {
  const VideoModelCatalogEntry({
    required this.capabilities,
    this.aliases = const {},
    this.requestDefaults = const VideoRequestDefaults(),
  });
  final Set<String> aliases;
  final VideoModelCapabilities capabilities;
  final VideoRequestDefaults requestDefaults;
}

const _imageFormats = {'image/jpeg', 'image/png', 'image/webp'};
const _videoFormats = {'video/mp4', 'video/quicktime'};
const _audioFormats = {'audio/mpeg', 'audio/wav', 'audio/x-wav'};

/// 官方 ID 对应的模型目录；渠道名称通过 [lookupVideoModel] 匹配已登记别名。
const Map<String, VideoModelCatalogEntry> videoModelsCatalog = {
  // AtlasCloud endpoint specifications: https://www.atlascloud.ai/docs/openapi-index
  'kwaivgi-kling-v4.0': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'720p', '1080p', '1080p-esr', '2k-esr', '4k-esr'},
      ratios: {'16:9', '9:16', '1:1', '21:9', 'adaptive'},
      durations: {
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
        20,
        21,
        22,
        23,
        24,
        25,
        26,
        27,
        28,
        29,
        30,
      },
      frameRoles: {
        VideoInputRole.first_frame,
        VideoInputRole.middle_frame,
        VideoInputRole.last_frame,
      },
      maxMiddleFrames: 8,
      maxReferences: 15,
      allowsReferenceMode: true,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 10),
        VideoMediaKind.video: VideoReferenceLimits(maxCount: 5),
        VideoMediaKind.audio: null,
      },
    ),
  ),
  'minimax-h3-fast': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'480P'},
      ratios: {'adaptive', '21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
      durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 12,
      allowsReferenceMode: true,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 9),
        VideoMediaKind.video: VideoReferenceLimits(maxCount: 3),
        VideoMediaKind.audio: VideoReferenceLimits(maxCount: 3),
      },
    ),
  ),
  'minimax-h3-max-turbo': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'480P', '768P'},
      ratios: {'adaptive', '21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
      durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      allowsReferenceMode: false,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 2),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
    ),
  ),
  'alibaba-happyhorse-1.0': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'720p', '1080p'},
      ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
      durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 9,
      allowsReferenceMode: true,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 9),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
    ),
  ),
  'alibaba-wan-2.5': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'480p', '720p', '1080p'},
      ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
      durations: {5, 10},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 1,
      allowsReferenceMode: false,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 1),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
    ),
  ),
  'atlascloud-van-2.5': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'720p', '1080p'},
      ratios: {'16:9', '9:16'},
      durations: {5, 10},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 1,
      allowsReferenceMode: false,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 1),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
    ),
  ),
  'atlascloud-van-2.6': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'1080p'},
      ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
      durations: {5, 10, 15},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 1,
      allowsReferenceMode: false,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 1),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
    ),
  ),
  'google-gemini-omni-flash': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'720p'},
      ratios: {'16:9', '9:16'},
      durations: {3, 4, 5, 6, 7, 8, 9, 10},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 10,
      allowsReferenceMode: true,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 10),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
    ),
  ),
  'kwaivgi-kling-v3.0-4k': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'1080P'},
      ratios: {'16:9', '9:16', '1:1'},
      durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      allowsReferenceMode: false,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 2),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
      maxPromptCharacters: ConfigValue(2500),
    ),
  ),
  'kwaivgi-kling-v3.0-turbo': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'720p', '1080p'},
      ratios: {'16:9', '9:16', '1:1'},
      durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 1,
      allowsReferenceMode: false,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 1),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
      maxPromptCharacters: ConfigValue(2500),
    ),
  ),
  'kwaivgi-kling-video-o3-4k': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'4k'},
      ratios: {'16:9', '9:16', '1:1'},
      durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      allowsReferenceMode: false,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 2),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
    ),
  ),
  'pixverse-c1': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'360p', '540p', '720p', '1080p'},
      ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '2:3', '3:2', '21:9'},
      durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 7,
      allowsReferenceMode: true,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 7),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
      maxPromptCharacters: ConfigValue(5000),
    ),
  ),
  'pixverse-v6': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'360p', '540p', '720p', '1080p'},
      ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '2:3', '3:2', '21:9'},
      durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 7,
      allowsReferenceMode: true,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 7),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
      maxPromptCharacters: ConfigValue(5000),
    ),
  ),
  'xai-grok-imagine-video': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'480p', '720p'},
      ratios: {'1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3'},
      durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 7,
      allowsReferenceMode: true,
      supportsAdaptiveTextRatio: false,
      supportsAudioOnlyReference: false,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(maxCount: 7),
        VideoMediaKind.video: null,
        VideoMediaKind.audio: null,
      },
    ),
  ),
  // Published video specifications: https://openrouter.ai/api/v1/videos/models
  'seedance-2.0-fast': VideoModelCatalogEntry(
    aliases: {'seedance-2-0-fast'},
    capabilities: VideoModelCapabilities(
      resolutions: {'480p', '720p'},
      ratios: {'1:1', '3:4', '9:16', '4:3', '16:9', '21:9', '9:21'},
      durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'veo-3.1': VideoModelCatalogEntry(
    aliases: {'veo-3-1'},
    capabilities: VideoModelCapabilities(
      resolutions: {'720p', '1080p', '4K'},
      ratios: {'16:9', '9:16'},
      durations: {4, 6, 8},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'veo-3.1-fast': VideoModelCatalogEntry(
    aliases: {'veo-3-1-fast'},
    capabilities: VideoModelCapabilities(
      resolutions: {'720p', '1080p', '4K'},
      ratios: {'16:9', '9:16'},
      durations: {4, 6, 8},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'veo-3.1-lite': VideoModelCatalogEntry(
    aliases: {'veo-3-1-lite'},
    capabilities: VideoModelCapabilities(
      resolutions: {'720p', '1080p'},
      ratios: {'16:9', '9:16'},
      durations: {4, 6, 8},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'grok-imagine-video-1.5': VideoModelCatalogEntry(
    aliases: {'grok-imagine-video-1-5'},
    capabilities: VideoModelCapabilities(
      resolutions: {'480p', '720p', '1080p'},
      ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '3:2', '2:3'},
      durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'grok-imagine-video-1.5-lite': VideoModelCatalogEntry(
    aliases: {'grok-imagine-video-1-5-lite'},
    capabilities: VideoModelCapabilities(
      resolutions: {'480p', '720p', '1080p'},
      ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '3:2', '2:3'},
      durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'wan-2.7': VideoModelCatalogEntry(
    aliases: {'wan-2-7'},
    capabilities: VideoModelCapabilities(
      resolutions: {'720p', '1080p'},
      ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
      durations: {2, 3, 4, 5, 6, 7, 8, 9, 10},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'wan-2.6': VideoModelCatalogEntry(
    aliases: {'wan-2-6'},
    capabilities: VideoModelCapabilities(
      resolutions: {'720p', '1080p'},
      ratios: {'16:9', '9:16'},
      durations: {5, 10},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'kling-v3.0-pro': VideoModelCatalogEntry(
    aliases: {'kling-v3-0-pro'},
    capabilities: VideoModelCapabilities(
      resolutions: {'720p'},
      ratios: {'16:9', '9:16', '1:1'},
      durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'kling-v3.0-std': VideoModelCatalogEntry(
    aliases: {'kling-v3-0-std'},
    capabilities: VideoModelCapabilities(
      resolutions: {'720p'},
      ratios: {'16:9', '9:16', '1:1'},
      durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'kling-video-o1': VideoModelCatalogEntry(
    aliases: {'kling-video-o1'},
    capabilities: VideoModelCapabilities(
      resolutions: {'720p'},
      ratios: {'16:9', '9:16', '1:1'},
      durations: {5, 10},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'hailuo-3-max': VideoModelCatalogEntry(
    aliases: {'hailuo-3-max'},
    capabilities: VideoModelCapabilities(
      resolutions: {'768p', '480p'},
      ratios: {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
      durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'hailuo-2.3': VideoModelCatalogEntry(
    aliases: {'hailuo-2-3'},
    capabilities: VideoModelCapabilities(
      resolutions: {'1080p'},
      ratios: {'16:9'},
      durations: {6, 10},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'gen-4.5': VideoModelCatalogEntry(
    aliases: {'gen-4-5'},
    capabilities: VideoModelCapabilities(
      resolutions: {'720p'},
      ratios: {'16:9', '9:16'},
      durations: {2, 3, 4, 5, 6, 7, 8, 9, 10},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'flux-3-video': VideoModelCatalogEntry(
    aliases: {'flux-3-video'},
    capabilities: VideoModelCapabilities(
      resolutions: {'720p', '1080p'},
      ratios: {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
      durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20},
      frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'heygen-video-1': VideoModelCatalogEntry(
    aliases: {'heygen-video-1'},
    capabilities: VideoModelCapabilities(
      resolutions: {'480p', '768p', '2K'},
      ratios: {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
      durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  'happyhorse-1.1': VideoModelCatalogEntry(
    aliases: {'happyhorse-1-1'},
    capabilities: VideoModelCapabilities(
      resolutions: {'720p', '1080p'},
      ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '21:9', '9:21'},
      durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      frameRoles: {VideoInputRole.first_frame},
      maxReferences: 2,
      references: {VideoMediaKind.image: _frameImages},
    ),
  ),
  // https://agnes-ai.com/zh-Hans/docs/agnes-video-25
  'agnes-video-2.5': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'720P', '1080P', '1K', '2K'},
      ratios: _agnesRatios,
      durations: {4, 5, 6, 7, 8, 9, 10, 11, 12},
      supportsLastFrameOnly: true,
      maxReferences: 12,
      references: {
        VideoMediaKind.image: _agnesImages,
        VideoMediaKind.audio: _agnesAudio,
        VideoMediaKind.video: VideoReferenceLimits(
          maxCount: 1,
          maxSizeMb: ConfigValue(50),
          exclusiveMaxSize: true,
          mimeTypes: ConfigValue(null),
          minDurationMs: ConfigValue(2000),
          maxDurationMs: ConfigValue(12000),
          maxTotalDurationMs: ConfigValue(12000),
          minFrameRate: ConfigValue(24),
          maxFrameRate: ConfigValue(60),
        ),
      },
    ),
  ),
  // https://agnes-ai.com/zh-Hans/docs/agnes-video-25-flash
  'agnes-video-2.5-flash': VideoModelCatalogEntry(
    capabilities: VideoModelCapabilities(
      resolutions: {'720P'},
      ratios: _agnesRatios,
      durations: {4, 5, 6, 7, 8, 9, 10, 11, 12},
      supportsLastFrameOnly: true,
      maxReferences: 8,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(
          maxCount: 5,
          maxSizeMb: ConfigValue(15),
          maxTotalSizeMb: ConfigValue(50),
          exclusiveMaxSize: true,
          mimeTypes: ConfigValue(null),
          minDimension: ConfigValue(256),
          maxDimension: ConfigValue(5760),
        ),
        VideoMediaKind.audio: _agnesAudio,
      },
    ),
  ),
  'doubao-seedance-2-5-260628': VideoModelCatalogEntry(
    requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    aliases: {'seedance-2-5'},
    capabilities: VideoModelCapabilities(
      resolutions: {'480p', '720p', '1080p'},
      // dart format off
      durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
      // dart format on
      maxReferences: 50,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(
          maxCount: 30,
          maxSizeMb: ConfigValue(30),
          mimeTypes: ConfigValue(_imageFormats),
          minDimension: ConfigValue(300),
          maxDimension: ConfigValue(6000),
          minRatio: ConfigValue(0.4),
          maxRatio: ConfigValue(2.5),
        ),
        VideoMediaKind.video: VideoReferenceLimits(
          maxCount: 10,
          maxSizeMb: ConfigValue(50),
          mimeTypes: ConfigValue(_videoFormats),
          minDimension: ConfigValue(300),
          maxDimension: ConfigValue(6000),
          minRatio: ConfigValue(0.4),
          maxRatio: ConfigValue(2.5),
          minDurationMs: ConfigValue(2000),
          maxDurationMs: ConfigValue(30000),
          maxTotalDurationMs: ConfigValue(30000),
          minFrameRate: ConfigValue(24),
          maxFrameRate: ConfigValue(60),
        ),
        VideoMediaKind.audio: VideoReferenceLimits(
          maxCount: 10,
          maxSizeMb: ConfigValue(15),
          mimeTypes: ConfigValue(_audioFormats),
          minDurationMs: ConfigValue(2000),
          maxDurationMs: ConfigValue(30000),
          maxTotalDurationMs: ConfigValue(30000),
        ),
      },
    ),
  ),
  // 官方模型 ID 与规格：https://docs.volcengine.com/docs/ark/seedance-2-0
  // 输入限制：https://docs.volcengine.com/docs/ark/create-video-generation-task-api
  'doubao-seedance-2-0-260128': VideoModelCatalogEntry(
    requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    aliases: {'seedance-2-0'},
    capabilities: VideoModelCapabilities(
      resolutions: {'480p', '720p', '1080p', '4k'},
      durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      supportsAudioOnlyReference: false,
      supportsAdaptiveTextRatio: true,
      // 官方按媒体类型列出上限，未另列更低的合计上限。
      maxReferences: 9 + 3 + 3,
      references: _seedance20References,
    ),
  ),
  'doubao-seedance-2-0-fast-260128': VideoModelCatalogEntry(
    requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    aliases: {'seedance-2-0-fast'},
    capabilities: VideoModelCapabilities(
      resolutions: {'480p', '720p'},
      durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      supportsAudioOnlyReference: false,
      supportsAdaptiveTextRatio: true,
      maxReferences: 9 + 3 + 3,
      references: _seedance20References,
    ),
  ),
  'doubao-seedance-2-0-mini-260615': VideoModelCatalogEntry(
    requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    aliases: {'seedance-2-0-mini'},
    capabilities: VideoModelCapabilities(
      resolutions: {'480p', '720p'},
      durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      supportsAudioOnlyReference: false,
      supportsAdaptiveTextRatio: true,
      maxReferences: 9 + 3 + 3,
      references: _seedance20References,
    ),
  ),
  'MiniMax-H3': VideoModelCatalogEntry(
    aliases: {'minimax-h3', 'hailuo-3'},
    capabilities: VideoModelCapabilities(
      maxPromptCharacters: ConfigValue(7000),
      resolutions: {'768P', '2K'},
      durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
      maxReferences: 12,
      references: {
        VideoMediaKind.image: VideoReferenceLimits(
          maxCount: 9,
          maxSizeMb: ConfigValue(30),
          mimeTypes: ConfigValue({
            ..._imageFormats,
            'image/heic',
            'image/heif',
          }),
          minDimension: ConfigValue(256),
          maxDimension: ConfigValue(5760),
          minRatio: ConfigValue(0.4),
          maxRatio: ConfigValue(2.5),
        ),
        VideoMediaKind.video: VideoReferenceLimits(
          maxCount: 3,
          maxSizeMb: ConfigValue(50),
          mimeTypes: ConfigValue(_videoFormats),
          minDimension: ConfigValue(256),
          maxDimension: ConfigValue(5760),
          minRatio: ConfigValue(0.4),
          maxRatio: ConfigValue(2.5),
          minDurationMs: ConfigValue(2000),
          maxDurationMs: ConfigValue(15000),
          maxTotalDurationMs: ConfigValue(15000),
          minFrameRate: ConfigValue(23.976),
          maxFrameRate: ConfigValue(60),
        ),
        VideoMediaKind.audio: VideoReferenceLimits(
          maxCount: 3,
          maxSizeMb: ConfigValue(15),
          mimeTypes: ConfigValue(_audioFormats),
          minDurationMs: ConfigValue(2000),
          maxDurationMs: ConfigValue(15000),
          maxTotalDurationMs: ConfigValue(15000),
        ),
      },
    ),
  ),
  'wan3.0-video': _wan,
  'wan3.0-video-prime': _wanPrime,
};

// Only first/last-frame inputs are described here; no undocumented size limit.
const _frameImages = VideoReferenceLimits(
  maxCount: 2,
  mimeTypes: ConfigValue(_imageFormats),
);

const _agnesRatios = {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16'};
// Agnes 未公布 MIME 白名单；未声明的限制交给服务端校验。
const _agnesImages = VideoReferenceLimits(
  maxCount: 8,
  maxSizeMb: ConfigValue(15),
  maxTotalSizeMb: ConfigValue(50),
  exclusiveMaxSize: true,
  mimeTypes: ConfigValue(null),
  minDimension: ConfigValue(256),
  maxDimension: ConfigValue(5760),
);
const _agnesAudio = VideoReferenceLimits(
  maxCount: 3,
  maxSizeMb: ConfigValue(15),
  maxTotalSizeMb: ConfigValue(64),
  exclusiveMaxSize: true,
  mimeTypes: ConfigValue(null),
  minTotalDurationMs: ConfigValue(2000),
  maxTotalDurationMs: ConfigValue(12000),
);

const _seedance20References = {
  VideoMediaKind.image: VideoReferenceLimits(
    maxCount: 9,
    maxSizeMb: ConfigValue(30),
    exclusiveMaxSize: true,
    mimeTypes: ConfigValue({
      ..._imageFormats,
      'image/bmp',
      'image/tiff',
      'image/gif',
      'image/heic',
      'image/heif',
    }),
    minDimension: ConfigValue(300),
    maxDimension: ConfigValue(6000),
    minRatio: ConfigValue(0.4),
    maxRatio: ConfigValue(2.5),
  ),
  VideoMediaKind.video: VideoReferenceLimits(
    maxCount: 3,
    maxSizeMb: ConfigValue(200),
    mimeTypes: ConfigValue(_videoFormats),
    minDimension: ConfigValue(300),
    maxDimension: ConfigValue(6000),
    minRatio: ConfigValue(0.4),
    maxRatio: ConfigValue(2.5),
    minPixels: ConfigValue(407696),
    maxPixels: ConfigValue(8295044),
    minDurationMs: ConfigValue(2000),
    maxDurationMs: ConfigValue(15000),
    maxTotalDurationMs: ConfigValue(15000),
    minFrameRate: ConfigValue(24),
    maxFrameRate: ConfigValue(60),
  ),
  VideoMediaKind.audio: VideoReferenceLimits(
    maxCount: 3,
    maxSizeMb: ConfigValue(15),
    mimeTypes: ConfigValue(_audioFormats),
    minDurationMs: ConfigValue(2000),
    maxDurationMs: ConfigValue(15000),
    maxTotalDurationMs: ConfigValue(15000),
  ),
};

const _wan = VideoModelCatalogEntry(
  aliases: {'wan3-0-video', 'wan-3-0'},
  capabilities: VideoModelCapabilities(
    maxPromptCharacters: ConfigValue(20000),
    resolutions: {'480P', '720P', '1080P'},
    // dart format off
    durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
    // dart format on
    maxReferences: 20,
    maxInputOutputDurationMs: ConfigValue(30000),
    references: _wanReferences,
  ),
);

const _wanPrime = VideoModelCatalogEntry(
  aliases: {'wan3-0-video-prime', 'wan-3-0-prime'},
  capabilities: VideoModelCapabilities(
    maxPromptCharacters: ConfigValue(20000),
    resolutions: {'480P', '720P', '1080P'},
    // dart format off
    durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
    // dart format on
    maxReferences: 20,
    maxInputOutputDurationMs: ConfigValue(30000),
    references: _wanReferences,
  ),
);

const _wanReferences = {
  VideoMediaKind.image: VideoReferenceLimits(
    maxCount: 10,
    maxSizeMb: ConfigValue(20),
    mimeTypes: ConfigValue({..._imageFormats, 'image/bmp'}),
    minDimension: ConfigValue(240),
    maxDimension: ConfigValue(8000),
    minRatio: ConfigValue(0.125),
    maxRatio: ConfigValue(8),
  ),
  VideoMediaKind.video: VideoReferenceLimits(
    maxCount: 5,
    maxSizeMb: ConfigValue(50),
    mimeTypes: ConfigValue(_videoFormats),
    minDimension: ConfigValue(240),
    maxDimension: ConfigValue(4096),
    minRatio: ConfigValue(0.125),
    maxRatio: ConfigValue(8),
    minDurationMs: ConfigValue(1000),
    maxDurationMs: ConfigValue(15000),
    maxTotalDurationMs: ConfigValue(15000),
    minFrameRate: ConfigValue(16),
  ),
  VideoMediaKind.audio: VideoReferenceLimits(
    maxCount: 5,
    maxSizeMb: ConfigValue(15),
    mimeTypes: ConfigValue(_audioFormats),
    minDurationMs: ConfigValue(1000),
    maxDurationMs: ConfigValue(15000),
    maxTotalDurationMs: ConfigValue(15000),
  ),
};

final _videoModelRecognizer = ModelIdRecognizer({
  for (final entry in videoModelsCatalog.entries)
    entry.key: entry.value.aliases,
});

/// 渠道型号 ID 对应的目录 ID；规则见 [ModelIdRecognizer]。
String? recognizeVideoModel(String? modelId) =>
    _videoModelRecognizer.recognize(modelId);

VideoModelCatalogEntry? lookupVideoModel(String? modelId) =>
    videoModelsCatalog[recognizeVideoModel(modelId)];
