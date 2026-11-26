// 职责: 组合视频渠道的模型映射、能力覆盖、请求默认值与协议要求，并按 provider 类型查找渠道型号。
// 关联文件:
//   lib/shared/models/video/catalog.dart
//   lib/shared/models/video/config.dart
//   lib/shared/models/video/capabilities.dart
//   lib/shared/models/ai_provider.dart

import 'dart:math';

import '../ai_provider.dart' show ModelIdSource, aiProviderTypeConfigFor;
import 'catalog.dart';
import 'request.dart';

class VideoProtocolOptions {
  const VideoProtocolOptions({this.supportsOmniReferenceTaskType = false});

  final bool supportsOmniReferenceTaskType;
}

/// AtlasCloud 的不同生成端点使用不同字段，不能统一套用 Seedance 请求。
class AtlasCloudVideoOptions extends VideoProtocolOptions {
  const AtlasCloudVideoOptions({
    required this.text,
    this.frames,
    this.firstLastFrames,
    this.reference,
  });
  final AtlasCloudVideoRoute text;
  final AtlasCloudVideoRoute? frames;
  final AtlasCloudVideoRoute? firstLastFrames;
  final AtlasCloudVideoRoute? reference;

  AtlasCloudVideoRoute? routeFor(VideoMode mode) => switch (mode) {
    VideoMode.text => text,
    VideoMode.first_frame => frames,
    VideoMode.first_last_frame =>
      firstLastFrames ??
          (frames?.mediaFields.containsKey(VideoInputRole.last_frame) == true
              ? frames
              : null),
    VideoMode.reference => reference,
  };
}

class AtlasCloudVideoRoute {
  const AtlasCloudVideoRoute({
    required this.modelId,
    required this.resolutions,
    required this.ratios,
    required this.durations,
    required this.fields,
    this.mediaFields = const {},
    this.referenceCounts = const {},
    this.objectImages = false,
    this.mixedReferences = false,
    this.sizes = const {},
    this.eightSecondResolutions = const {},
  });
  final String modelId;
  final Set<String> resolutions;
  final Set<String> ratios;
  final Set<int> durations;

  /// 请求属性到官方字段的映射；没有登记的字段不发送。
  final Map<String, String> fields;
  final Map<VideoInputRole, String> mediaFields;
  final Map<VideoMediaKind, int> referenceCounts;
  final bool objectImages;
  final bool mixedReferences;

  /// 使用 size 的端点按 resolution/ratio 查找官方尺寸枚举。
  final Map<String, String> sizes;
  final Set<String> eightSecondResolutions;
}

/// 模型选择处展示的卖点标签；文案由 UI 层按枚举本地化。
enum VideoModelHighlight {
  /// 展示该型号支持的最长时长。
  max_duration,

  /// 优先排队通道。
  priority,
}

/// 选用模型前需要知道的提示（计费、限制等）；与卖点分开，UI 以提示图标呈现。
enum VideoModelNotice {
  /// 优先通道按更高价格计费。
  priority_billing(VideoModelHighlight.priority);

  const VideoModelNotice([this.highlight]);

  /// 该提示解释的卖点；对应徽标悬停时复用提示文案。
  final VideoModelHighlight? highlight;
}

class VideoChannelModel {
  const VideoChannelModel({
    required this.catalogId,
    this._capabilities = const VideoModelCapabilities(),
    this._requestDefaults = const VideoRequestDefaults(),
    this.protocolOptions = const VideoProtocolOptions(),
    this.highlights = const [],
    this.notices = const [],
  });
  final String catalogId;
  final List<VideoModelHighlight> highlights;
  final List<VideoModelNotice> notices;
  final VideoModelCapabilities _capabilities;
  final VideoRequestDefaults _requestDefaults;
  final VideoProtocolOptions protocolOptions;
  VideoModelCatalogEntry get model => videoModelsCatalog[catalogId]!;
  VideoModelCapabilities get capabilities =>
      model.capabilities.merge(_capabilities);
  VideoRequestDefaults get requestDefaults =>
      model.requestDefaults.merge(_requestDefaults);
  Set<String> get resolutions => capabilities.resolutions;
  Set<String> get ratios => capabilities.ratios;
  Set<int> get durations => capabilities.durations;
  Map<String, int> get maxDurationByResolution =>
      capabilities.maxDurationByResolution;
  Set<int> durationsForResolution(String resolution) {
    final maximum = maxDurationByResolution[resolution];
    return maximum == null
        ? durations
        : durations.where((seconds) => seconds <= maximum).toSet();
  }

  int get minDurationSeconds => durations.reduce(min);
  int get maxDurationSeconds => durations.reduce(max);

  /// 渠道登记了 audio 默认值，即要求请求携带 audio 参数；否则不得携带。
  bool get requiresAudio => requestDefaults.audio != null;

  /// 同 [requiresAudio]，对应 prompt_extend 参数。
  bool get requiresPromptExtend => requestDefaults.promptExtend != null;
  Set<VideoInputRole> get frameRoles => capabilities.frameRoles;
  bool get supportsAdaptiveTextRatio =>
      capabilities.supportsAdaptiveTextRatio && ratios.contains('adaptive');
}

final videoChannelModels = <VideoProtocol, Map<String, VideoChannelModel>>{
  VideoProtocol.new_api_video: {
    'doubao-seedance-2-5-260628': VideoChannelModel(
      capabilities: VideoModelCapabilities(framesRequireAdaptiveRatio: true),
      catalogId: 'doubao-seedance-2-5-260628',
      protocolOptions: VideoProtocolOptions(
        supportsOmniReferenceTaskType: true,
      ),
    ),
    'seedance-2.5官方版': VideoChannelModel(
      capabilities: VideoModelCapabilities(framesRequireAdaptiveRatio: true),
      catalogId: 'doubao-seedance-2-5-260628',
      protocolOptions: VideoProtocolOptions(
        supportsOmniReferenceTaskType: true,
      ),
    ),
    'doubao-seedance-2-0-260128': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-260128',
    ),
    'seedance-2.0官方版': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-260128',
    ),
    'doubao-seedance-2-0-fast-260128': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-fast-260128',
    ),
    'seedance-2.0-fast官方版': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-fast-260128',
    ),
    'doubao-seedance-2-0-mini-260615': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-mini-260615',
    ),
    // 88api rejects any generate_audio value for this alias, including false.
    'seedance-2.0-mini官方版': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-mini-260615',
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(null)),
    ),
    // New API's Google plugin forwards only the first frame.
    'veo-3.1': VideoChannelModel(
      catalogId: 'veo-3.1',
      capabilities: _newApiSingleFrame,
    ),
    'veo-3.1-fast': VideoChannelModel(
      catalogId: 'veo-3.1-fast',
      capabilities: _newApiSingleFrame,
    ),
    'veo-3.1-lite': VideoChannelModel(
      catalogId: 'veo-3.1-lite',
      capabilities: _newApiSingleFrame,
    ),
    'grok-imagine-video-1.5': VideoChannelModel(
      catalogId: 'grok-imagine-video-1.5',
      capabilities: _newApiSingleFrame,
    ),
    for (final id in ['wan3.0-video', 'wan3.0-video-prime'])
      id: VideoChannelModel(
        catalogId: id,
        capabilities: VideoModelCapabilities(framesRequireAdaptiveRatio: true),
        requestDefaults: VideoRequestDefaults(
          audio: ConfigValue(true),
          promptExtend: ConfigValue(true),
        ),
      ),
    'MiniMax-H3': VideoChannelModel(
      catalogId: 'MiniMax-H3',
      capabilities: VideoModelCapabilities(framesRequireAdaptiveRatio: true),
    ),
    'MiniMax-H3-Max': VideoChannelModel(
      catalogId: 'MiniMax-H3',
      capabilities: VideoModelCapabilities(
        resolutions: {'480P', '768P'},
        durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        framesRequireAdaptiveRatio: true,
      ),
    ),
    for (final id in [
      'viduq3-pro',
      'viduq3-turbo',
      'viduq4-preview',
      'viduq3-ad',
    ])
      id: VideoChannelModel(catalogId: id),
    for (final id in ['grok-video-3', 'grok-imagine-video'])
      id: VideoChannelModel(
        catalogId: 'xai-grok-imagine-video',
        capabilities: VideoModelCapabilities(
          modes: [VideoMode.text, VideoMode.first_frame, VideoMode.reference],
        ),
      ),
    'grok-imagine-video-1.5-preview': VideoChannelModel(
      catalogId: 'grok-imagine-video-1.5',
      capabilities: VideoModelCapabilities(
        resolutions: {'480p', '720p'},
        modes: [VideoMode.text, VideoMode.first_frame],
        maxReferences: 1,
      ),
    ),
    'doubao-seedance-2-5': VideoChannelModel(
      catalogId: 'doubao-seedance-2-5-260628',
      capabilities: VideoModelCapabilities(framesRequireAdaptiveRatio: true),
      protocolOptions: VideoProtocolOptions(
        supportsOmniReferenceTaskType: true,
      ),
    ),
    'doubao-seedance-2-0': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-260128',
    ),
    'doubao-seedance-2-0-fast': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-fast-260128',
    ),
    'doubao-seedance-2-0-mini': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-mini-260615',
    ),
  },
  // https://www.atlascloud.ai/docs/more-models/bytedance/seedance-2.5-reference-to-video/generateVideo
  VideoProtocol.atlascloud_video: {
    'bytedance/seedance-2.5': VideoChannelModel(
      catalogId: 'doubao-seedance-2-5-260628',
      capabilities: VideoModelCapabilities(
        draft: ConfigValue(
          VideoDraftCapabilities(
            resolution: '480p',
            completionResolution: '1080p',
            ttlHours: 168,
          ),
        ),
        supportsCertifiedAssets: true,
        supportsAdaptiveTextRatio: true,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(exclusiveMaxSize: true),
          VideoMediaKind.video: VideoReferenceLimits(
            maxSizeMb: ConfigValue(200),
            minPixels: ConfigValue(409600),
            maxPixels: ConfigValue(8295044),
          ),
        },
      ),
      protocolOptions: VideoProtocolOptions(
        supportsOmniReferenceTaskType: true,
      ),
    ),
    'bytedance/seedance-2.0': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-260128',
      capabilities: VideoModelCapabilities(
        supportsCertifiedAssets: true,
        resolutions: {'480p', '720p', '1080p'},
        references: {
          VideoMediaKind.video: VideoReferenceLimits(
            maxSizeMb: ConfigValue(50),
            minPixels: ConfigValue(409600),
            maxPixels: ConfigValue(2086876),
          ),
        },
      ),
    ),

    // Official endpoint schemas: https://www.atlascloud.ai/docs/openapi-index
    'alibaba/happyhorse-1.0': VideoChannelModel(
      catalogId: 'alibaba-happyhorse-1.0',
      requestDefaults: VideoRequestDefaults(),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'alibaba/happyhorse-1.0/text-to-video',
          resolutions: {'720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'alibaba/happyhorse-1.0/image-to-video',
          resolutions: {'720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {'duration': 'duration', 'resolution': 'resolution'},
          mediaFields: {VideoInputRole.first_frame: 'image'},
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'alibaba/happyhorse-1.0/reference-to-video',
          resolutions: {'720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
          },
          mediaFields: {VideoInputRole.reference_image: 'images'},
          referenceCounts: {VideoMediaKind.image: 9},
        ),
      ),
    ),
    'alibaba/happyhorse-1.1': VideoChannelModel(
      catalogId: 'happyhorse-1.1',
      capabilities: VideoModelCapabilities(
        resolutions: {'480p', '720p', '1080p'},
        // dart format off
        ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '4:5', '5:4', '9:21', '21:9'},
        // dart format on
        durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame},
        maxReferences: 9,
        modes: VideoMode.values,
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 9),
          VideoMediaKind.video: null,
          VideoMediaKind.audio: null,
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(null),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'alibaba/happyhorse-1.1/text-to-video',
          resolutions: {'480p', '720p', '1080p'},
          // dart format off
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '4:5', '5:4', '9:21', '21:9'},
          // dart format on
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'alibaba/happyhorse-1.1/image-to-video',
          resolutions: {'480p', '720p', '1080p'},
          // dart format off
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '4:5', '5:4', '9:21', '21:9'},
          // dart format on
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {'duration': 'duration', 'resolution': 'resolution'},
          mediaFields: {VideoInputRole.first_frame: 'image'},
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'alibaba/happyhorse-1.1/reference-to-video',
          resolutions: {'480p', '720p', '1080p'},
          // dart format off
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '4:5', '5:4', '9:21', '21:9'},
          // dart format on
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
          },
          mediaFields: {VideoInputRole.reference_image: 'images'},
          referenceCounts: {VideoMediaKind.image: 9},
        ),
      ),
    ),
    'alibaba/wan-2.5': VideoChannelModel(
      catalogId: 'alibaba-wan-2.5',
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(true),
        promptExtend: ConfigValue(false),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-2.5/text-to-video',
          resolutions: {'480p', '720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
          durations: {5, 10},
          fields: {
            'duration': 'duration',
            'audio': 'generate_audio',
            'prompt_extend': 'enable_prompt_expansion',
          },
          sizes: {
            '480p/16:9': '832*480',
            '480p/9:16': '480*832',
            '480p/1:1': '624*624',
            '720p/16:9': '1280*720',
            '720p/9:16': '720*1280',
            '720p/1:1': '960*960',
            '720p/4:3': '1088*832',
            '720p/3:4': '832*1088',
            '1080p/16:9': '1920*1080',
            '1080p/9:16': '1080*1920',
            '1080p/1:1': '1440*1440',
            '1080p/4:3': '1632*1248',
            '1080p/3:4': '1248*1632',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-2.5/image-to-video',
          resolutions: {'480p', '720p', '1080p'},
          ratios: {'16:9'},
          durations: {5, 10},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'audio': 'generate_audio',
            'prompt_extend': 'enable_prompt_expansion',
          },
          mediaFields: {VideoInputRole.first_frame: 'image'},
        ),
      ),
    ),
    'alibaba/wan-2.6': VideoChannelModel(
      catalogId: 'wan-2.6',
      capabilities: VideoModelCapabilities(
        resolutions: {'720p', '1080p'},
        ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
        durations: {5, 10, 15},
        frameRoles: {},
        maxReferences: 0,
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: null,
          VideoMediaKind.video: null,
          VideoMediaKind.audio: null,
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(true),
        promptExtend: ConfigValue(true),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-2.6/text-to-video',
          resolutions: {'720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
          durations: {5, 10, 15},
          fields: {
            'duration': 'duration',
            'audio': 'generate_audio',
            'prompt_extend': 'enable_prompt_expansion',
          },
          sizes: {
            '720p/16:9': '1280*720',
            '720p/9:16': '720*1280',
            '720p/1:1': '960*960',
            '720p/4:3': '1088*832',
            '720p/3:4': '832*1088',
            '1080p/16:9': '1920*1080',
            '1080p/9:16': '1080*1920',
            '1080p/1:1': '1440*1440',
            '1080p/4:3': '1632*1248',
            '1080p/3:4': '1248*1632',
          },
        ),
      ),
    ),
    'alibaba/wan-2.7': VideoChannelModel(
      catalogId: 'wan-2.7',
      capabilities: VideoModelCapabilities(
        resolutions: {'720P', '1080P'},
        ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
        durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 6,
        modes: VideoMode.values,
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 2),
          VideoMediaKind.video: VideoReferenceLimits(maxCount: 3),
          VideoMediaKind.audio: VideoReferenceLimits(maxCount: 1),
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(null),
        promptExtend: ConfigValue(true),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-2.7/text-to-video',
          resolutions: {'720P', '1080P'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
          durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_extend',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-2.7/image-to-video',
          resolutions: {'720P', '1080P'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
          durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'prompt_extend': 'prompt_extend',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'last_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-2.7/reference-to-video',
          resolutions: {'720P', '1080P'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
          durations: {2, 3, 4, 5, 6, 7, 8, 9, 10},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_extend',
          },
          mediaFields: {
            VideoInputRole.reference_image: 'images',
            VideoInputRole.reference_video: 'videos',
            VideoInputRole.reference_audio: 'audio',
          },
          referenceCounts: {
            VideoMediaKind.image: 1,
            VideoMediaKind.video: 3,
            VideoMediaKind.audio: 1,
          },
        ),
      ),
    ),
    'alibaba/wan-3.0-prime': VideoChannelModel(
      catalogId: 'wan3.0-video-prime',
      capabilities: VideoModelCapabilities(
        resolutions: {
          '1080p',
          '720p',
          '480p',
          '720p-esr',
          '1080p-esr',
          '1440p-esr',
          '4k-esr',
        },
        ratios: {'adaptive', '16:9', '4:3', '1:1', '3:4', '9:16'},
        // dart format off
        durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
        // dart format on
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 20,
        modes: VideoMode.values,
        supportsAdaptiveTextRatio: true,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 10),
          VideoMediaKind.video: VideoReferenceLimits(maxCount: 5),
          VideoMediaKind.audio: VideoReferenceLimits(maxCount: 5),
        },
        maxInputOutputDurationMs: ConfigValue(30000),
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(true),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-3.0-prime/text-to-video',
          resolutions: {
            '1080p',
            '720p',
            '480p',
            '720p-esr',
            '1080p-esr',
            '1440p-esr',
            '4k-esr',
          },
          ratios: {'adaptive', '16:9', '4:3', '1:1', '3:4', '9:16'},
          // dart format off
          durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
          // dart format on
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'audio': 'audio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-3.0-prime/image-to-video',
          resolutions: {
            '1080p',
            '720p',
            '480p',
            '720p-esr',
            '1080p-esr',
            '1440p-esr',
            '4k-esr',
          },
          ratios: {'adaptive', '16:9', '4:3', '1:1', '3:4', '9:16'},
          // dart format off
          durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
          // dart format on
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'audio': 'audio',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'last_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-3.0-prime/reference-to-video',
          resolutions: {
            '1080p',
            '720p',
            '480p',
            '720p-esr',
            '1080p-esr',
            '1440p-esr',
            '4k-esr',
          },
          ratios: {'adaptive', '16:9', '4:3', '1:1', '3:4', '9:16'},
          // dart format off
          durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
          // dart format on
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'audio': 'audio',
          },
          referenceCounts: {
            VideoMediaKind.image: 10,
            VideoMediaKind.video: 5,
            VideoMediaKind.audio: 5,
          },
          mixedReferences: true,
        ),
      ),
    ),
    'alibaba/wan-3.0': VideoChannelModel(
      catalogId: 'wan3.0-video',
      capabilities: VideoModelCapabilities(
        resolutions: {
          '1080p',
          '720p',
          '480p',
          '720p-esr',
          '1080p-esr',
          '1440p-esr',
          '4k-esr',
        },
        ratios: {'adaptive', '16:9', '4:3', '1:1', '3:4', '9:16'},
        // dart format off
        durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
        // dart format on
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 20,
        modes: VideoMode.values,
        supportsAdaptiveTextRatio: true,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 10),
          VideoMediaKind.video: VideoReferenceLimits(maxCount: 5),
          VideoMediaKind.audio: VideoReferenceLimits(maxCount: 5),
        },
        maxInputOutputDurationMs: ConfigValue(30000),
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(true),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-3.0/text-to-video',
          resolutions: {
            '1080p',
            '720p',
            '480p',
            '720p-esr',
            '1080p-esr',
            '1440p-esr',
            '4k-esr',
          },
          ratios: {'adaptive', '16:9', '4:3', '1:1', '3:4', '9:16'},
          // dart format off
          durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
          // dart format on
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'audio': 'audio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-3.0/image-to-video',
          resolutions: {
            '1080p',
            '720p',
            '480p',
            '720p-esr',
            '1080p-esr',
            '1440p-esr',
            '4k-esr',
          },
          ratios: {'adaptive', '16:9', '4:3', '1:1', '3:4', '9:16'},
          // dart format off
          durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
          // dart format on
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'audio': 'audio',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'last_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'alibaba/wan-3.0/reference-to-video',
          resolutions: {
            '1080p',
            '720p',
            '480p',
            '720p-esr',
            '1080p-esr',
            '1440p-esr',
            '4k-esr',
          },
          ratios: {'adaptive', '16:9', '4:3', '1:1', '3:4', '9:16'},
          // dart format off
          durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
          // dart format on
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'audio': 'audio',
          },
          referenceCounts: {
            VideoMediaKind.image: 10,
            VideoMediaKind.video: 5,
            VideoMediaKind.audio: 5,
          },
          mixedReferences: true,
        ),
      ),
    ),
    'atlascloud/van-2.5': VideoChannelModel(
      catalogId: 'atlascloud-van-2.5',
      requestDefaults: VideoRequestDefaults(promptExtend: ConfigValue(false)),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'atlascloud/van-2.5/text-to-video',
          resolutions: {'720p', '1080p'},
          ratios: {'16:9', '9:16'},
          durations: {5, 10},
          fields: {
            'duration': 'duration',
            'prompt_extend': 'enable_prompt_expansion',
          },
          sizes: {
            '720p/16:9': '1280*720',
            '720p/9:16': '720*1280',
            '1080p/16:9': '1920*1080',
            '1080p/9:16': '1080*1920',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'atlascloud/van-2.5/image-to-video',
          resolutions: {'720p', '1080p'},
          ratios: {'16:9'},
          durations: {5, 10},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'prompt_extend': 'enable_prompt_expansion',
          },
          mediaFields: {VideoInputRole.first_frame: 'image'},
        ),
      ),
    ),
    'atlascloud/van-2.6': VideoChannelModel(
      catalogId: 'atlascloud-van-2.6',
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(true),
        promptExtend: ConfigValue(true),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'atlascloud/van-2.6/text-to-video',
          resolutions: {'1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4'},
          durations: {5, 10, 15},
          fields: {
            'duration': 'duration',
            'audio': 'generate_audio',
            'prompt_extend': 'enable_prompt_expansion',
          },
          sizes: {
            '1080p/16:9': '1920*1080',
            '1080p/9:16': '1080*1920',
            '1080p/1:1': '1440*1440',
            '1080p/4:3': '1632*1248',
            '1080p/3:4': '1248*1632',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'atlascloud/van-2.6/image-to-video',
          resolutions: {'1080p'},
          ratios: {'16:9'},
          durations: {5, 10, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'audio': 'generate_audio',
            'prompt_extend': 'enable_prompt_expansion',
          },
          mediaFields: {VideoInputRole.first_frame: 'image'},
        ),
      ),
    ),
    'bytedance/seedance-2.0-fast': VideoChannelModel(
      catalogId: 'seedance-2.0-fast',
      capabilities: VideoModelCapabilities(
        supportsCertifiedAssets: true,
        resolutions: {'480p', '720p', '720p-SR', '1080p-SR', '1440p-SR'},
        ratios: {'16:9', '4:3', '1:1', '3:4', '9:16', '21:9', 'adaptive'},
        durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 15,
        modes: VideoMode.values,
        supportsAdaptiveTextRatio: true,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(
            maxCount: 9,
            maxSizeMb: ConfigValue(30),
          ),
          VideoMediaKind.video: VideoReferenceLimits(
            maxCount: 3,
            maxSizeMb: ConfigValue(50),
            minDurationMs: ConfigValue(2000),
            maxDurationMs: ConfigValue(15000),
            maxTotalDurationMs: ConfigValue(15000),
            minPixels: ConfigValue(409600),
            maxPixels: ConfigValue(2086876),
          ),
          VideoMediaKind.audio: VideoReferenceLimits(
            maxCount: 3,
            maxSizeMb: ConfigValue(15),
            minDurationMs: ConfigValue(2000),
            maxDurationMs: ConfigValue(15000),
            maxTotalDurationMs: ConfigValue(15000),
          ),
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(true),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'bytedance/seedance-2.0-fast/text-to-video',
          resolutions: {'480p', '720p', '720p-SR', '1080p-SR', '1440p-SR'},
          ratios: {'16:9', '4:3', '1:1', '3:4', '9:16', '21:9', 'adaptive'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'audio': 'generate_audio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'bytedance/seedance-2.0-fast/image-to-video',
          resolutions: {'480p', '720p', '720p-SR', '1080p-SR', '1440p-SR'},
          ratios: {'16:9', '4:3', '1:1', '3:4', '9:16', '21:9', 'adaptive'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'audio': 'generate_audio',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'last_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'bytedance/seedance-2.0-fast/reference-to-video',
          resolutions: {'480p', '720p', '720p-SR', '1080p-SR', '1440p-SR'},
          ratios: {'16:9', '4:3', '1:1', '3:4', '9:16', '21:9', 'adaptive'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'audio': 'generate_audio',
          },
          mediaFields: {
            VideoInputRole.reference_image: 'reference_images',
            VideoInputRole.reference_video: 'reference_videos',
            VideoInputRole.reference_audio: 'reference_audios',
          },
          referenceCounts: {
            VideoMediaKind.image: 9,
            VideoMediaKind.video: 3,
            VideoMediaKind.audio: 3,
          },
        ),
      ),
    ),
    'bytedance/seedance-2.0-mini': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-mini-260615',
      capabilities: VideoModelCapabilities(
        supportsCertifiedAssets: true,
        resolutions: {'480p', '720p', '720p-SR', '1080p-SR', '1440p-SR'},
        ratios: {'16:9', '4:3', '1:1', '3:4', '9:16', '21:9', 'adaptive'},
        durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 15,
        modes: VideoMode.values,
        supportsAdaptiveTextRatio: true,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(
            maxCount: 9,
            maxSizeMb: ConfigValue(30),
          ),
          VideoMediaKind.video: VideoReferenceLimits(
            maxCount: 3,
            maxSizeMb: ConfigValue(50),
            minDurationMs: ConfigValue(2000),
            maxDurationMs: ConfigValue(15000),
            maxTotalDurationMs: ConfigValue(15000),
            minPixels: ConfigValue(409600),
            maxPixels: ConfigValue(2086876),
          ),
          VideoMediaKind.audio: VideoReferenceLimits(
            maxCount: 3,
            maxSizeMb: ConfigValue(15),
            minDurationMs: ConfigValue(2000),
            maxDurationMs: ConfigValue(15000),
            maxTotalDurationMs: ConfigValue(15000),
          ),
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(true),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'bytedance/seedance-2.0-mini/text-to-video',
          resolutions: {'480p', '720p', '720p-SR', '1080p-SR', '1440p-SR'},
          ratios: {'16:9', '4:3', '1:1', '3:4', '9:16', '21:9', 'adaptive'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'audio': 'generate_audio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'bytedance/seedance-2.0-mini/image-to-video',
          resolutions: {'480p', '720p', '720p-SR', '1080p-SR', '1440p-SR'},
          ratios: {'16:9', '4:3', '1:1', '3:4', '9:16', '21:9', 'adaptive'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'audio': 'generate_audio',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'last_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'bytedance/seedance-2.0-mini/reference-to-video',
          resolutions: {'480p', '720p', '720p-SR', '1080p-SR', '1440p-SR'},
          ratios: {'16:9', '4:3', '1:1', '3:4', '9:16', '21:9', 'adaptive'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'audio': 'generate_audio',
          },
          mediaFields: {
            VideoInputRole.reference_image: 'reference_images',
            VideoInputRole.reference_video: 'reference_videos',
            VideoInputRole.reference_audio: 'reference_audios',
          },
          referenceCounts: {
            VideoMediaKind.image: 9,
            VideoMediaKind.video: 3,
            VideoMediaKind.audio: 3,
          },
        ),
      ),
    ),
    'google/gemini-omni-flash': VideoChannelModel(
      catalogId: 'google-gemini-omni-flash',
      requestDefaults: VideoRequestDefaults(),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'google/gemini-omni-flash/text-to-video',
          resolutions: {'720p'},
          ratios: {'16:9', '9:16'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'google/gemini-omni-flash/image-to-video',
          resolutions: {'720p'},
          ratios: {'16:9', '9:16'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
          mediaFields: {VideoInputRole.first_frame: 'image'},
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'google/gemini-omni-flash/reference-to-video',
          resolutions: {'720p'},
          ratios: {'16:9', '9:16'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
          mediaFields: {VideoInputRole.reference_image: 'images'},
          referenceCounts: {VideoMediaKind.image: 10},
        ),
      ),
    ),
    'google/veo3.1-fast': VideoChannelModel(
      catalogId: 'veo-3.1-fast',
      capabilities: VideoModelCapabilities(
        resolutions: {'720p', '1080p', '4k'},
        ratios: {'16:9', '9:16'},
        durations: {4, 6, 8},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 2,
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 2),
          VideoMediaKind.video: null,
          VideoMediaKind.audio: null,
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(false),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'google/veo3.1-fast/text-to-video',
          resolutions: {'720p', '1080p', '4k'},
          ratios: {'16:9', '9:16'},
          durations: {8, 4, 6},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
            'audio': 'generate_audio',
          },
          eightSecondResolutions: {'1080p', '4k'},
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'google/veo3.1-fast/image-to-video',
          resolutions: {'720p', '1080p', '4k'},
          ratios: {'16:9', '9:16'},
          durations: {8, 4, 6},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
            'audio': 'generate_audio',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'last_image',
          },
          eightSecondResolutions: {'1080p', '4k'},
        ),
      ),
    ),
    'google/veo3.1-lite': VideoChannelModel(
      catalogId: 'veo-3.1-lite',
      capabilities: VideoModelCapabilities(
        resolutions: {'720p', '1080p'},
        ratios: {'16:9', '9:16'},
        durations: {4, 6, 8},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 2,
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 2),
          VideoMediaKind.video: null,
          VideoMediaKind.audio: null,
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(null),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'google/veo3.1-lite/text-to-video',
          resolutions: {'720p', '1080p'},
          ratios: {'16:9', '9:16'},
          durations: {4, 6, 8},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
          eightSecondResolutions: {'1080p'},
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'google/veo3.1-lite/image-to-video',
          resolutions: {'720p', '1080p'},
          ratios: {'16:9', '9:16'},
          durations: {4, 6, 8},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
          mediaFields: {VideoInputRole.first_frame: 'image'},
          eightSecondResolutions: {'1080p'},
        ),
        firstLastFrames: AtlasCloudVideoRoute(
          modelId: 'google/veo3.1-lite/start-end-frame-to-video',
          resolutions: {'720p', '1080p'},
          ratios: {'16:9', '9:16'},
          durations: {4, 6, 8},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'last_image',
          },
          eightSecondResolutions: {'1080p'},
        ),
      ),
    ),
    'google/veo3.1': VideoChannelModel(
      catalogId: 'veo-3.1',
      capabilities: VideoModelCapabilities(
        resolutions: {'720p', '1080p', '4k'},
        ratios: {'16:9', '9:16'},
        durations: {4, 6, 8},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 3,
        modes: VideoMode.values,
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 3),
          VideoMediaKind.video: null,
          VideoMediaKind.audio: null,
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(false),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'google/veo3.1/text-to-video',
          resolutions: {'720p', '1080p', '4k'},
          ratios: {'16:9', '9:16'},
          durations: {8, 4, 6},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
            'audio': 'generate_audio',
          },
          eightSecondResolutions: {'1080p', '4k'},
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'google/veo3.1/image-to-video',
          resolutions: {'720p', '1080p', '4k'},
          ratios: {'16:9', '9:16'},
          durations: {8, 4, 6},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
            'audio': 'generate_audio',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'last_image',
          },
          eightSecondResolutions: {'1080p', '4k'},
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'google/veo3.1/reference-to-video',
          resolutions: {'720p', '1080p', '4k'},
          ratios: {'16:9', '9:16'},
          durations: {8},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'audio': 'generate_audio',
          },
          mediaFields: {VideoInputRole.reference_image: 'images'},
          referenceCounts: {VideoMediaKind.image: 3},
          eightSecondResolutions: {'1080p', '4k'},
        ),
      ),
    ),
    'kwaivgi/kling-v3.0-4k': VideoChannelModel(
      catalogId: 'kwaivgi-kling-v3.0-4k',
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-v3.0-4k/text-to-video',
          resolutions: {'1080P'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'ratio': 'aspect_ratio',
            'audio': 'sound',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-v3.0-4k/image-to-video',
          resolutions: {'1080P'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'audio': 'sound',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'end_image',
          },
        ),
      ),
    ),
    'kwaivgi/kling-v3.0-pro': VideoChannelModel(
      catalogId: 'kling-v3.0-pro',
      capabilities: VideoModelCapabilities(
        resolutions: {'1080P', '1440P-SR'},
        ratios: {'16:9', '9:16', '1:1'},
        durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 2,
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 2),
          VideoMediaKind.video: null,
          VideoMediaKind.audio: null,
        },
        maxPromptCharacters: ConfigValue(2500),
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(true),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-v3.0-pro/text-to-video',
          resolutions: {'1080P'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'ratio': 'aspect_ratio',
            'audio': 'sound',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-v3.0-pro/image-to-video',
          resolutions: {'1080P', '1440P-SR'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'audio': 'sound',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'end_image',
          },
        ),
      ),
    ),
    'kwaivgi/kling-v3.0-std': VideoChannelModel(
      catalogId: 'kling-v3.0-std',
      capabilities: VideoModelCapabilities(
        resolutions: {'720P', '1080P-SR', '1440P-SR'},
        ratios: {'16:9', '9:16', '1:1'},
        durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 2,
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 2),
          VideoMediaKind.video: null,
          VideoMediaKind.audio: null,
        },
        maxPromptCharacters: ConfigValue(2500),
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(true),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-v3.0-std/text-to-video',
          resolutions: {'720P'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'ratio': 'aspect_ratio',
            'audio': 'sound',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-v3.0-std/image-to-video',
          resolutions: {'720P', '1080P-SR', '1440P-SR'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'audio': 'sound',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'end_image',
          },
        ),
      ),
    ),
    'kwaivgi/kling-v3.0-turbo': VideoChannelModel(
      catalogId: 'kwaivgi-kling-v3.0-turbo',
      requestDefaults: VideoRequestDefaults(),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-v3.0-turbo/text-to-video',
          resolutions: {'720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-v3.0-turbo/image-to-video',
          resolutions: {'720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {'duration': 'duration', 'resolution': 'resolution'},
          mediaFields: {VideoInputRole.first_frame: 'image'},
        ),
      ),
    ),
    'kwaivgi/kling-video-o1': VideoChannelModel(
      catalogId: 'kling-video-o1',
      capabilities: VideoModelCapabilities(
        resolutions: {'720p'},
        ratios: {'16:9', '9:16', '1:1'},
        durations: {5, 10},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 2,
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 2),
          VideoMediaKind.video: null,
          VideoMediaKind.audio: null,
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(null),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-video-o1/text-to-video',
          resolutions: {'720p'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {5, 10},
          fields: {'duration': 'duration', 'ratio': 'aspect_ratio'},
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-video-o1/image-to-video',
          resolutions: {'720p'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {5, 10},
          fields: {'duration': 'duration', 'ratio': 'aspect_ratio'},
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'last_image',
          },
        ),
      ),
    ),
    'kwaivgi/kling-video-o3-4k': VideoChannelModel(
      catalogId: 'kwaivgi-kling-video-o3-4k',
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-video-o3-4k/text-to-video',
          resolutions: {'4k'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'ratio': 'aspect_ratio',
            'audio': 'sound',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-video-o3-4k/image-to-video',
          resolutions: {'4k'},
          ratios: {'16:9', '9:16', '1:1'},
          durations: {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {'duration': 'duration', 'audio': 'sound'},
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'end_image',
          },
        ),
      ),
    ),
    'kwaivgi/kling-v4.0': VideoChannelModel(
      capabilities: VideoModelCapabilities(framesRequireAdaptiveRatio: true),
      catalogId: 'kwaivgi-kling-v4.0',
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(null),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-v4.0/text-to-video',
          resolutions: {'720p', '1080p', '1080p-esr', '2k-esr', '4k-esr'},
          ratios: {'16:9', '9:16', '1:1', '21:9'},
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
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-v4.0/image-to-video',
          resolutions: {'720p', '1080p', '1080p-esr', '2k-esr', '4k-esr'},
          ratios: {'adaptive'},
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
          fields: {'duration': 'duration', 'resolution': 'resolution'},
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.middle_frame: 'middle_images',
            VideoInputRole.last_frame: 'last_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'kwaivgi/kling-v4.0/reference-to-video',
          resolutions: {'720p', '1080p', '1080p-esr', '2k-esr', '4k-esr'},
          ratios: {'16:9', '9:16', '1:1', '21:9'},
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
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
          mediaFields: {
            VideoInputRole.reference_image: 'reference_images',
            VideoInputRole.reference_video: 'reference_videos',
          },
          referenceCounts: {VideoMediaKind.image: 10, VideoMediaKind.video: 5},
        ),
      ),
    ),
    'minimax/h3-developer': VideoChannelModel(
      catalogId: 'MiniMax-H3',
      capabilities: VideoModelCapabilities(
        resolutions: {'480P', '768P', '1440p-sr', '4k-sr'},
        ratios: {'adaptive', '21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
        durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 12,
        modes: VideoMode.values,
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 9),
          VideoMediaKind.video: VideoReferenceLimits(maxCount: 3),
          VideoMediaKind.audio: VideoReferenceLimits(maxCount: 3),
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(null),
        promptExtend: ConfigValue(false),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'minimax/h3-developer/text-to-video',
          resolutions: {'480P', '768P', '1440p-sr', '4k-sr'},
          ratios: {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'minimax/h3-developer/image-to-video',
          resolutions: {'480P', '768P', '1440p-sr', '4k-sr'},
          ratios: {'adaptive'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'end_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'minimax/h3-developer/reference-to-video',
          resolutions: {'480P', '768P', '1440p-sr', '4k-sr'},
          ratios: {'adaptive', '21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
          mixedReferences: true,
          referenceCounts: {
            VideoMediaKind.image: 9,
            VideoMediaKind.video: 3,
            VideoMediaKind.audio: 3,
          },
        ),
      ),
    ),
    'minimax/h3-fast': VideoChannelModel(
      catalogId: 'minimax-h3-fast',
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(null),
        promptExtend: ConfigValue(false),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'minimax/h3-fast/text-to-video',
          resolutions: {'480P'},
          ratios: {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
          durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'minimax/h3-fast/image-to-video',
          resolutions: {'480P'},
          ratios: {'adaptive'},
          durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'end_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'minimax/h3-fast/reference-to-video',
          resolutions: {'480P'},
          ratios: {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
          durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
          mixedReferences: true,
          referenceCounts: {
            VideoMediaKind.image: 9,
            VideoMediaKind.video: 3,
            VideoMediaKind.audio: 3,
          },
        ),
      ),
    ),
    'minimax/h3-max': VideoChannelModel(
      catalogId: 'hailuo-3-max',
      capabilities: VideoModelCapabilities(
        resolutions: {'480P', '768P', '1440p-sr', '4k-sr'},
        ratios: {'adaptive', '21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
        durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 12,
        modes: VideoMode.values,
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 9),
          VideoMediaKind.video: VideoReferenceLimits(maxCount: 3),
          VideoMediaKind.audio: VideoReferenceLimits(maxCount: 3),
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(null),
        promptExtend: ConfigValue(false),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'minimax/h3-max/text-to-video',
          resolutions: {'480P', '768P', '1440p-sr', '4k-sr'},
          ratios: {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
          durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'minimax/h3-max/image-to-video',
          resolutions: {'480P', '768P', '1440p-sr', '4k-sr'},
          ratios: {'adaptive'},
          durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'end_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'minimax/h3-max/reference-to-video',
          resolutions: {'480P', '768P'},
          ratios: {'adaptive', '21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
          durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
          mixedReferences: true,
          referenceCounts: {
            VideoMediaKind.image: 9,
            VideoMediaKind.video: 3,
            VideoMediaKind.audio: 3,
          },
        ),
      ),
    ),
    'minimax/h3-max-turbo': VideoChannelModel(
      catalogId: 'minimax-h3-max-turbo',
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(null),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'minimax/h3-max-turbo/text-to-video',
          resolutions: {'480P', '768P'},
          ratios: {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
          durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'minimax/h3-max-turbo/image-to-video',
          resolutions: {'480P', '768P'},
          ratios: {'adaptive'},
          durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'end_image',
          },
        ),
      ),
    ),
    'minimax/h3': VideoChannelModel(
      catalogId: 'MiniMax-H3',
      capabilities: VideoModelCapabilities(
        resolutions: {'480P', '768P', '2K', '1080p-esr', '1440p-esr', '4k-esr'},
        ratios: {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16', 'adaptive'},
        durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        maxReferences: 12,
        modes: VideoMode.values,
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 9),
          VideoMediaKind.video: VideoReferenceLimits(maxCount: 3),
          VideoMediaKind.audio: VideoReferenceLimits(maxCount: 3),
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(null),
        promptExtend: ConfigValue(false),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'minimax/h3/text-to-video',
          resolutions: {'480P', '768P', '2K'},
          ratios: {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'minimax/h3/image-to-video',
          resolutions: {
            '480P',
            '768P',
            '2K',
            '1080p-esr',
            '1440p-esr',
            '4k-esr',
          },
          ratios: {'adaptive'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'end_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'minimax/h3/reference-to-video',
          resolutions: {
            '480P',
            '768P',
            '2K',
            '1080p-esr',
            '1440p-esr',
            '4k-esr',
          },
          ratios: {'adaptive', '21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
          durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'ratio',
            'prompt_extend': 'prompt_expansion',
          },
          referenceCounts: {
            VideoMediaKind.image: 9,
            VideoMediaKind.video: 3,
            VideoMediaKind.audio: 3,
          },
          mixedReferences: true,
        ),
      ),
    ),
    'pixverse/c1': VideoChannelModel(
      catalogId: 'pixverse-c1',
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'pixverse/c1/text-to-video',
          resolutions: {'360p', '540p', '720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '2:3', '3:2', '21:9'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'quality',
            'ratio': 'aspect_ratio',
            'audio': 'sound',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'pixverse/c1/image-to-video',
          resolutions: {'360p', '540p', '720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '2:3', '3:2', '21:9'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'quality',
            'audio': 'sound',
          },
          mediaFields: {VideoInputRole.first_frame: 'image'},
        ),
        firstLastFrames: AtlasCloudVideoRoute(
          modelId: 'pixverse/c1/start-end-to-video',
          resolutions: {'360p', '540p', '720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '2:3', '3:2', '21:9'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'quality',
            'audio': 'sound',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'end_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'pixverse/c1/reference-to-video',
          resolutions: {'360p', '540p', '720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '2:3', '3:2', '21:9'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'quality',
            'ratio': 'aspect_ratio',
            'audio': 'sound',
          },
          mediaFields: {VideoInputRole.reference_image: 'images'},
          referenceCounts: {VideoMediaKind.image: 7},
          objectImages: true,
        ),
      ),
    ),
    'pixverse/v6': VideoChannelModel(
      catalogId: 'pixverse-v6',
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'pixverse/v6/text-to-video',
          resolutions: {'360p', '540p', '720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '2:3', '3:2', '21:9'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'quality',
            'ratio': 'aspect_ratio',
            'audio': 'sound',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'pixverse/v6/image-to-video',
          resolutions: {'360p', '540p', '720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '2:3', '3:2', '21:9'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'quality',
            'audio': 'sound',
          },
          mediaFields: {VideoInputRole.first_frame: 'image'},
        ),
        firstLastFrames: AtlasCloudVideoRoute(
          modelId: 'pixverse/v6/start-end-to-video',
          resolutions: {'360p', '540p', '720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '2:3', '3:2', '21:9'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'quality',
            'audio': 'sound',
          },
          mediaFields: {
            VideoInputRole.first_frame: 'image',
            VideoInputRole.last_frame: 'end_image',
          },
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'pixverse/v6/reference-to-video',
          resolutions: {'360p', '540p', '720p', '1080p'},
          ratios: {'16:9', '9:16', '1:1', '4:3', '3:4', '2:3', '3:2', '21:9'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'quality',
            'ratio': 'aspect_ratio',
            'audio': 'sound',
          },
          mediaFields: {VideoInputRole.reference_image: 'images'},
          referenceCounts: {VideoMediaKind.image: 7},
          objectImages: true,
        ),
      ),
    ),
    'xai/grok-imagine-video-v1.5': VideoChannelModel(
      catalogId: 'grok-imagine-video-1.5',
      capabilities: VideoModelCapabilities(
        resolutions: {'480p', '720p', '1080p'},
        ratios: {'1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3'},
        durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame},
        maxReferences: 7,
        modes: VideoMode.values,
        supportsAdaptiveTextRatio: false,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 7),
          VideoMediaKind.video: null,
          VideoMediaKind.audio: null,
        },
      ),
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(null),
        promptExtend: ConfigValue(null),
      ),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'xai/grok-imagine-video-v1.5/text-to-video',
          resolutions: {'480p', '720p', '1080p'},
          ratios: {'1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'xai/grok-imagine-video-v1.5/image-to-video',
          resolutions: {'480p', '720p', '1080p'},
          ratios: {'1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
          mediaFields: {VideoInputRole.first_frame: 'image_url'},
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'xai/grok-imagine-video-v1.5/reference-to-video',
          resolutions: {'480p', '720p'},
          ratios: {'1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
          mediaFields: {VideoInputRole.reference_image: 'image_urls'},
          referenceCounts: {VideoMediaKind.image: 7},
        ),
      ),
    ),
    'xai/grok-imagine-video': VideoChannelModel(
      catalogId: 'xai-grok-imagine-video',
      requestDefaults: VideoRequestDefaults(),
      protocolOptions: AtlasCloudVideoOptions(
        text: AtlasCloudVideoRoute(
          modelId: 'xai/grok-imagine-video/text-to-video',
          resolutions: {'480p', '720p'},
          ratios: {'1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
        ),
        frames: AtlasCloudVideoRoute(
          modelId: 'xai/grok-imagine-video/image-to-video',
          resolutions: {'480p', '720p'},
          ratios: {'1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
          mediaFields: {VideoInputRole.first_frame: 'image_url'},
        ),
        reference: AtlasCloudVideoRoute(
          modelId: 'xai/grok-imagine-video/reference-to-video',
          resolutions: {'480p', '720p'},
          ratios: {'1:1', '16:9', '9:16', '4:3', '3:4', '3:2', '2:3'},
          durations: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
          fields: {
            'duration': 'duration',
            'resolution': 'resolution',
            'ratio': 'aspect_ratio',
          },
          mediaFields: {VideoInputRole.reference_image: 'image_urls'},
          referenceCounts: {VideoMediaKind.image: 7},
        ),
      ),
    ),
  },
  VideoProtocol.ark_video: {
    'doubao-seedance-2-5-260628': VideoChannelModel(
      capabilities: VideoModelCapabilities(
        draft: ConfigValue(
          VideoDraftCapabilities(
            resolution: '480p',
            completionResolution: '1080p',
            ttlHours: 168,
          ),
        ),
        framesRequireAdaptiveRatio: true,
        supportsCertifiedAssets: true,
      ),
      catalogId: 'doubao-seedance-2-5-260628',
      protocolOptions: VideoProtocolOptions(
        supportsOmniReferenceTaskType: true,
      ),
    ),
    'doubao-seedance-2-5-flash-261115': VideoChannelModel(
      catalogId: 'doubao-seedance-2-5-flash-261115',
      capabilities: VideoModelCapabilities(supportsCertifiedAssets: true),
      protocolOptions: VideoProtocolOptions(
        supportsOmniReferenceTaskType: true,
      ),
    ),
    'doubao-seedance-2-0-260128': VideoChannelModel(
      capabilities: VideoModelCapabilities(supportsCertifiedAssets: true),
      catalogId: 'doubao-seedance-2-0-260128',
    ),
    'doubao-seedance-2-0-mini-260615': VideoChannelModel(
      capabilities: VideoModelCapabilities(supportsCertifiedAssets: true),
      catalogId: 'doubao-seedance-2-0-mini-260615',
    ),
  },
  VideoProtocol.minimax_video_v2: {
    'MiniMax-H3': VideoChannelModel(
      capabilities: VideoModelCapabilities(framesRequireAdaptiveRatio: true),
      catalogId: 'MiniMax-H3',
    ),
  },
  VideoProtocol.wan_video: {
    'wan3.0-video': VideoChannelModel(
      capabilities: VideoModelCapabilities(framesRequireAdaptiveRatio: true),
      catalogId: 'wan3.0-video',
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(true),
        promptExtend: ConfigValue(true),
      ),
    ),
    'wan3.0-video-prime': VideoChannelModel(
      capabilities: VideoModelCapabilities(framesRequireAdaptiveRatio: true),
      catalogId: 'wan3.0-video-prime',
      requestDefaults: VideoRequestDefaults(
        audio: ConfigValue(true),
        promptExtend: ConfigValue(true),
      ),
    ),
  },
  VideoProtocol.agnes_video: {
    'agnes-video-2.5': VideoChannelModel(catalogId: 'agnes-video-2.5'),
    'agnes-video-2.5-flash': VideoChannelModel(
      catalogId: 'agnes-video-2.5-flash',
    ),
  },
  // https://openrouter.ai/api/v1/videos/models
  VideoProtocol.openrouter_video: {
    'bytedance/seedance-2.5': VideoChannelModel(
      catalogId: 'doubao-seedance-2-5-260628',
      capabilities: VideoModelCapabilities(
        resolutions: {'480p', '720p'},
        ratios: {'16:9', '4:3', '1:1', '3:4', '9:16', '21:9'},
        // dart format off
        durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
        // dart format on
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        modes: VideoMode.values,
      ),
    ),
    'bytedance/seedance-2.5-flash': VideoChannelModel(
      catalogId: 'doubao-seedance-2-5-flash-261115',
      capabilities: VideoModelCapabilities(
        ratios: {'16:9', '4:3', '1:1', '3:4', '9:16', '21:9'},
        maxReferences: 10,
        supportsAudioOnlyReference: false,
        framesRequireAdaptiveRatio: false,
      ),
    ),
    'bytedance/seedance-2.0': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-260128',
      capabilities: VideoModelCapabilities(
        resolutions: {'480p', '720p', '1080p', '4K'},
        ratios: {'1:1', '3:4', '9:16', '4:3', '16:9', '21:9', '9:21'},
        durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        modes: VideoMode.values,
      ),
    ),
    'bytedance/seedance-2.0-fast': VideoChannelModel(
      catalogId: 'seedance-2.0-fast',
      capabilities: VideoModelCapabilities(
        maxReferences: 15,
        supportsAudioOnlyReference: false,
        references: videoModelsCatalog['doubao-seedance-2-0-fast-260128']!
            .capabilities
            .references,
        modes: VideoMode.values,
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'bytedance/seedance-2.0-mini': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-mini-260615',
      capabilities: VideoModelCapabilities(
        resolutions: {'480p', '720p'},
        ratios: {'1:1', '3:4', '9:16', '4:3', '16:9', '21:9', '9:21'},
        durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        modes: VideoMode.values,
      ),
    ),
    'google/veo-3.1': VideoChannelModel(
      catalogId: 'veo-3.1',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: VideoMode.values,
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'google/veo-3.1-fast': VideoChannelModel(
      catalogId: 'veo-3.1-fast',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'google/veo-3.1-lite': VideoChannelModel(
      catalogId: 'veo-3.1-lite',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'x-ai/grok-imagine-video-1.5': VideoChannelModel(
      catalogId: 'grok-imagine-video-1.5',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
    ),
    'x-ai/grok-imagine-video-1.5-lite': VideoChannelModel(
      catalogId: 'grok-imagine-video-1.5-lite',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
    ),
    'alibaba/wan-3.0': VideoChannelModel(
      catalogId: 'wan3.0-video',
      capabilities: VideoModelCapabilities(
        resolutions: {'480p', '720p', '1080p'},
        ratios: {'16:9', '4:3', '1:1', '3:4', '9:16'},
        // dart format off
        durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
        // dart format on
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        modes: VideoMode.values,
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'alibaba/wan-3.0-prime': VideoChannelModel(
      catalogId: 'wan3.0-video-prime',
      capabilities: VideoModelCapabilities(
        resolutions: {'480p', '720p', '1080p'},
        ratios: {'16:9', '4:3', '1:1', '3:4', '9:16'},
        // dart format off
        durations: {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
        // dart format on
        frameRoles: {VideoInputRole.first_frame},
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'alibaba/wan-2.7': VideoChannelModel(
      catalogId: 'wan-2.7',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: VideoMode.values,
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'alibaba/wan-2.6': VideoChannelModel(
      catalogId: 'wan-2.6',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'kwaivgi/kling-v3.0-pro': VideoChannelModel(
      catalogId: 'kling-v3.0-pro',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'kwaivgi/kling-v3.0-std': VideoChannelModel(
      catalogId: 'kling-v3.0-std',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'kwaivgi/kling-video-o1': VideoChannelModel(
      catalogId: 'kling-video-o1',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'minimax/hailuo-3': VideoChannelModel(
      catalogId: 'MiniMax-H3',
      capabilities: VideoModelCapabilities(
        resolutions: {'2K'},
        ratios: {'21:9', '16:9', '4:3', '1:1', '3:4', '9:16'},
        durations: {5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
        frameRoles: {VideoInputRole.first_frame, VideoInputRole.last_frame},
        modes: VideoMode.values,
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'minimax/hailuo-3-max': VideoChannelModel(
      catalogId: 'hailuo-3-max',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
    ),
    'minimax/hailuo-2.3': VideoChannelModel(
      catalogId: 'hailuo-2.3',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
    ),
    'runway/gen-4.5': VideoChannelModel(
      catalogId: 'gen-4.5',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
    ),
    'black-forest-labs/flux-3-video': VideoChannelModel(
      catalogId: 'flux-3-video',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: [
          VideoMode.text,
          VideoMode.first_frame,
          VideoMode.first_last_frame,
        ],
      ),
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(true)),
    ),
    'heygen/heygen-video-1': VideoChannelModel(
      catalogId: 'heygen-video-1',
      capabilities: VideoModelCapabilities(
        modes: VideoMode.values,
        maxReferences: 12,
        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(maxCount: 9),
          VideoMediaKind.video: VideoReferenceLimits(maxCount: 3),
          VideoMediaKind.audio: VideoReferenceLimits(maxCount: 3),
        },
      ),
    ),
    'alibaba/happyhorse-1.1': VideoChannelModel(
      catalogId: 'happyhorse-1.1',
      capabilities: VideoModelCapabilities(
        references: {VideoMediaKind.video: null, VideoMediaKind.audio: null},
        modes: VideoMode.values,
      ),
    ),
  },
};

const _metasoH3Capabilities = VideoModelCapabilities(
  maxDurationByResolution: {'2K': 15},
  framesRequireAdaptiveRatio: true,
  maxPromptCharacters: ConfigValue(10000),
  resolutions: {'480p', '768P', '1080p', '2K'},
  // dart format off
  durations: {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30},
  // dart format on
);

// Public model catalog and API examples: https://metaso.cn/minimax-h3
final _providerVideoModels = <String, Map<String, VideoChannelModel>>{
  // https://platform.qianwenai.com/docs/api-reference/video-generation/happyhorse-text-to-video/create-task
  // https://platform.qianwenai.com/docs/api-reference/video-generation/happyhorse-image-to-video/create-task
  // https://platform.qianwenai.com/docs/api-reference/video-generation/happyhorse-reference-to-video/create-task
  'qwen_token_plan': {
    'happyhorse-1.1-t2v': VideoChannelModel(
      catalogId: 'happyhorse-1.1',
      capabilities: VideoModelCapabilities(
        modes: [VideoMode.text],
        resolutions: {'480P', '720P', '1080P'},
        ratios: {
          '16:9',
          '9:16',
          '1:1',
          '4:3',
          '3:4',
          '4:5',
          '5:4',
          '9:21',
          '21:9',
        },
        frameRoles: {},
        maxReferences: 0,

        supportsAudioOnlyReference: false,
        references: {VideoMediaKind.image: null},
      ),
    ),
    'happyhorse-1.1-i2v': VideoChannelModel(
      catalogId: 'happyhorse-1.1',
      capabilities: VideoModelCapabilities(
        modes: [VideoMode.first_frame],
        framesRequireAdaptiveRatio: true,
        resolutions: {'480P', '720P', '1080P'},
        ratios: {'adaptive'},
        frameRoles: {VideoInputRole.first_frame},
        maxReferences: 1,

        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(
            maxCount: 1,
            mimeTypes: ConfigValue({'image/jpeg', 'image/png', 'image/webp'}),
            maxSizeMb: ConfigValue(20),
            minDimension: ConfigValue(300),
            minRatio: ConfigValue(0.4),
            maxRatio: ConfigValue(2.5),
          ),
        },
      ),
    ),
    'happyhorse-1.1-r2v': VideoChannelModel(
      catalogId: 'happyhorse-1.1',
      capabilities: VideoModelCapabilities(
        modes: [VideoMode.reference],
        resolutions: {'480P', '720P', '1080P'},
        ratios: {
          '16:9',
          '9:16',
          '1:1',
          '4:3',
          '3:4',
          '4:5',
          '5:4',
          '9:21',
          '21:9',
        },
        frameRoles: {},
        maxReferences: 9,

        supportsAudioOnlyReference: false,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(
            maxCount: 9,
            mimeTypes: ConfigValue({'image/jpeg', 'image/png', 'image/webp'}),
            maxSizeMb: ConfigValue(20),
            minDimension: ConfigValue(400),
          ),
        },
      ),
    ),
  },
  'metaso': {
    'MiniMax-H3': VideoChannelModel(
      catalogId: 'MiniMax-H3',
      capabilities: _metasoH3Capabilities,
      highlights: [VideoModelHighlight.max_duration],
    ),
    'MiniMax-H3-priority': VideoChannelModel(
      catalogId: 'MiniMax-H3',
      capabilities: _metasoH3Capabilities,
      highlights: [
        VideoModelHighlight.max_duration,
        VideoModelHighlight.priority,
      ],
      notices: [VideoModelNotice.priority_billing],
    ),
    'seedance-2.0': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-260128',
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(null)),
      capabilities: VideoModelCapabilities(
        references: {
          VideoMediaKind.video: VideoReferenceLimits(
            maxSizeMb: ConfigValue(50),
          ),
        },
      ),
    ),
    'seedance-2.0-mini': VideoChannelModel(
      catalogId: 'doubao-seedance-2-0-mini-260615',
      requestDefaults: VideoRequestDefaults(audio: ConfigValue(null)),
      capabilities: VideoModelCapabilities(
        references: {
          VideoMediaKind.video: VideoReferenceLimits(
            maxSizeMb: ConfigValue(50),
          ),
        },
      ),
    ),
  },
  // 站点只接受自己返回的模型 ID；目录在「获取模型」时按 `/v1/models` 登记。
  'purefox_media': purefoxMediaVideoModels,
};

/// PureFox 媒体网关的视频型号目录：不预置，填 key 后按站点 `/v1/models`
/// 返回的 kind / qualities / duration / ref* 登记。
final purefoxMediaVideoModels = <String, VideoChannelModel>{};

/// 部分网关将视频型号标为 openai，按协议系列识别而不限定具体型号。
bool isNewApiVideoModel(String id) {
  final name = id.toLowerCase();
  return name.startsWith('doubao-seedance-') ||
      name.startsWith('wan3') ||
      name.startsWith('minimax-h3') ||
      name.startsWith('vidu') ||
      name.startsWith('grok-video-') ||
      name.startsWith('grok-imagine-video');
}

List<String> videoModelsForProvider(String providerType) =>
    (_providerVideoModels[providerType] ??
            videoChannelModels[aiProviderTypeConfigFor(
              providerType,
            )?.videoProtocol])
        ?.keys
        .toList(growable: false) ??
    const [];

/// 按 provider 类型查找渠道型号：先精确匹配渠道 ID；可接中转站的渠道再从 ID
/// 中识别目录型号。找不到时返回 null，是否允许使用由业务层决定。
VideoChannelModel? lookupVideoChannelModel(
  String providerType,
  String? modelId,
) {
  final config = aiProviderTypeConfigFor(providerType);
  final models =
      _providerVideoModels[providerType] ??
      videoChannelModels[config?.videoProtocol];
  if (config == null || models == null) {
    return null;
  }
  final exact = models[modelId?.trim()];
  if (exact != null || config.modelIdSource == ModelIdSource.registered) {
    return exact;
  }
  final catalogId = recognizeVideoModel(modelId);
  final channel = models.values
      .where((channel) => channel.catalogId == catalogId)
      .firstOrNull;
  if (channel != null) {
    return channel;
  }
  // New API 的 Seedance 请求格式适用于整个系列，型号 ID 由渠道返回。
  if (config.videoProtocol == VideoProtocol.new_api_video &&
      catalogId != null &&
      catalogId.startsWith('doubao-seedance-')) {
    return VideoChannelModel(
      catalogId: catalogId,
      capabilities: VideoModelCapabilities(
        // https://88api.ai/zh/docs/api/video/seedance-multi-resolution/
        supportsAudioOnlyReference: providerType == 'api88' ? false : null,
      ),
    );
  }
  return null;
}

const _newApiSingleFrame = VideoModelCapabilities(
  frameRoles: {VideoInputRole.first_frame},
  maxReferences: 1,
  modes: [VideoMode.text, VideoMode.first_frame, VideoMode.first_last_frame],
  references: {VideoMediaKind.image: VideoReferenceLimits(maxCount: 1)},
);
