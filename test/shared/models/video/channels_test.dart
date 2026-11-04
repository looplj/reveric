// 职责: 验证跨渠道模型共享、渠道能力覆盖及已确认的视频型号完整性。
// 关联文件:
//   lib/shared/models/video/catalog.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/models/video/capabilities.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/provider_resources.dart';
import 'package:reveric/shared/models/video/catalog.dart';
import 'package:reveric/shared/models/video/channels.dart';
import 'package:reveric/shared/models/video/capabilities.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import '../../../helpers/media_provider_types.dart';

const approvedOpenRouterModels = {
  'bytedance/seedance-2.5',
  'bytedance/seedance-2.0',
  'bytedance/seedance-2.0-fast',
  'bytedance/seedance-2.0-mini',
  'google/veo-3.1',
  'google/veo-3.1-fast',
  'google/veo-3.1-lite',
  'x-ai/grok-imagine-video-1.5',
  'x-ai/grok-imagine-video-1.5-lite',
  'alibaba/wan-3.0',
  'alibaba/wan-3.0-prime',
  'alibaba/wan-2.7',
  'alibaba/wan-2.6',
  'kwaivgi/kling-v3.0-pro',
  'kwaivgi/kling-v3.0-std',
  'kwaivgi/kling-video-o1',
  'minimax/hailuo-3',
  'minimax/hailuo-3-max',
  'minimax/hailuo-2.3',
  'runway/gen-4.5',
  'black-forest-labs/flux-3-video',
  'heygen/heygen-video-1',
  'alibaba/happyhorse-1.1',
};

void main() {
  test(
    'Token Plan lists split HappyHorse models with mode-specific limits',
    () {
      expect(videoModelsForProvider('qwen_token_plan'), [
        'happyhorse-1.1-t2v',
        'happyhorse-1.1-i2v',
        'happyhorse-1.1-r2v',
      ]);
      expect(videoModelsForProvider('qwen'), [
        'wan3.0-video',
        'wan3.0-video-prime',
      ]);
      for (final (suffix, mode, role, count) in [
        ('t2v', VideoMode.text, null, 0),
        ('i2v', VideoMode.first_frame, VideoInputRole.first_frame, 1),
        ('r2v', VideoMode.reference, VideoInputRole.reference_image, 9),
      ]) {
        final model = 'happyhorse-1.1-$suffix';
        final channel = lookupVideoChannelModel('qwen_token_plan', model)!;
        final provider = aiProviderBuiltinById(
          'openai',
        )!.copyWith(type: 'qwen_token_plan', videoModels: [model]);
        final resource = providerModelResource(provider, 'video', model);
        expect(resource['capabilities']['modes'], [mode.name]);
        expect(channel.durations, {
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
        });
        expect(channel.resolutions, {'480P', '720P', '1080P'});
        expect(channel.capabilities.maxReferences, count);
        const caps = VideoCapabilities('qwen_token_plan');
        VideoRequest req({VideoMode? chosenMode, int duration = 5}) =>
            VideoRequest(
              modelId: model,
              prompt: 'scene',
              mode: chosenMode ?? mode,
              resolution: '720P',
              ratio: suffix == 'i2v' ? 'adaptive' : '16:9',
              durationSeconds: duration,
            );
        final roles = role == null
            ? <VideoInputRole>[]
            : List.filled(count, role);
        caps.validateParameters(req(), roles);
        for (final duration in [2, 16]) {
          expect(
            () => caps.validateParameters(req(duration: duration), roles),
            throwsA(isA<VideoException>()),
          );
        }
        for (final wrongMode in VideoMode.values.where(
          (value) => value != mode,
        )) {
          expect(
            () => caps.validateParameters(req(chosenMode: wrongMode), roles),
            throwsA(isA<VideoException>()),
          );
        }
        if (role != null) {
          expect(
            () => caps.validateParameters(req(), []),
            throwsA(isA<VideoException>()),
          );
          expect(
            () => caps.validateParameters(req(), List.filled(count + 1, role)),
            throwsA(isA<VideoException>()),
          );
        }
      }
    },
  );
  test(
    'AtlasCloud channel limits remain distinct from native and OpenRouter channels',
    () {
      const protocol = VideoProtocol.atlascloud_video;
      final atlas25 = lookupVideoChannelModel(
        videoProviderType(protocol),
        'bytedance/seedance-2.5',
      )!;
      final atlas20 = lookupVideoChannelModel(
        videoProviderType(protocol),
        'bytedance/seedance-2.0',
      )!;
      expect(
        atlas25.capabilities.references[VideoMediaKind.video]!.maxSizeMb,
        200,
      );
      expect(
        atlas20.capabilities.references[VideoMediaKind.video]!.maxSizeMb,
        50,
      );
      expect(
        lookupVideoChannelModel(
          videoProviderType(VideoProtocol.ark_video),
          'doubao-seedance-2-5-260628',
        )!.capabilities.references[VideoMediaKind.video]!.maxSizeMb,
        50,
      );
      expect(
        lookupVideoChannelModel(videoProviderType(protocol), 'seedance-2-5'),
        isNull,
      );
      for (final model in [
        'bytedance/seedance-2.5',
        'bytedance/seedance-2.0',
      ]) {
        final request = VideoRequest(
          modelId: model,
          prompt: 'scene',
          mode: VideoMode.reference,
          resolution: '1080p',
          ratio: '16:9',
          audio: true,
        );
        void validate() => VideoCapabilities(
          videoProviderType(protocol),
        ).validateParameters(request, [VideoInputRole.reference_audio]);
        if (model.endsWith('2.5')) {
          validate();
        } else {
          expect(
            validate,
            throwsA(
              isA<VideoException>().having(
                (e) => e.field,
                'field',
                'audio_reference',
              ),
            ),
          );
        }
      }
    },
  );
  test('all approved models resolve to usable channel capabilities', () {
    expect(
      videoModelsForProvider(
        videoProviderType(VideoProtocol.openrouter_video),
      ).toSet(),
      approvedOpenRouterModels,
    );
    for (final id in approvedOpenRouterModels) {
      final route = lookupVideoChannelModel(
        videoProviderType(VideoProtocol.openrouter_video),
        id,
      )!;
      expect(route.model, same(lookupVideoModel(id)), reason: id);
      expect(route.resolutions, isNotEmpty, reason: id);
      expect(route.ratios, isNotEmpty, reason: id);
      expect(route.durations, isNotEmpty, reason: id);
      VideoCapabilities(
        videoProviderType(VideoProtocol.openrouter_video),
      ).validateParameters(
        VideoRequest(
          modelId: id,
          prompt: 'a scene',
          mode: VideoMode.text,
          resolution: route.resolutions.first,
          ratio: route.ratios.first,
          durationSeconds: route.minDurationSeconds,
          audio: route.requestDefaults.audio,
        ),
        [],
      );
    }
  });

  for (final (native, id, protocol) in [
    (
      'doubao-seedance-2-5-260628',
      'bytedance/seedance-2.5',
      VideoProtocol.ark_video,
    ),
    (
      'doubao-seedance-2-0-260128',
      'bytedance/seedance-2.0',
      VideoProtocol.ark_video,
    ),
    (
      'doubao-seedance-2-0-mini-260615',
      'bytedance/seedance-2.0-mini',
      VideoProtocol.ark_video,
    ),
    ('wan3.0-video', 'alibaba/wan-3.0', VideoProtocol.wan_video),
    ('wan3.0-video-prime', 'alibaba/wan-3.0-prime', VideoProtocol.wan_video),
    ('MiniMax-H3', 'minimax/hailuo-3', VideoProtocol.minimax_video_v2),
  ]) {
    test('$native and $id share one model independently of protocol', () {
      final direct = lookupVideoChannelModel(
        videoProviderType(protocol),
        native,
      )!;
      final router = lookupVideoChannelModel(
        videoProviderType(VideoProtocol.openrouter_video),
        id,
      )!;
      expect(direct.model, same(router.model));
      expect(lookupVideoModel(native), same(lookupVideoModel(id)));
    });
  }

  test('OpenRouter narrowing does not change the native model or channel', () {
    final ark = lookupVideoChannelModel(
      videoProviderType(VideoProtocol.ark_video),
      'doubao-seedance-2-5-260628',
    )!;
    final router = lookupVideoChannelModel(
      videoProviderType(VideoProtocol.openrouter_video),
      'bytedance/seedance-2.5',
    )!;
    expect(ark.model.capabilities.resolutions, contains('1080p'));
    expect(ark.resolutions, contains('1080p'));
    expect(router.resolutions, {'480p', '720p'});
    expect(ark.protocolOptions.supportsOmniReferenceTaskType, true);
    expect(router.protocolOptions.supportsOmniReferenceTaskType, false);
    final request = VideoRequest(
      modelId: 'bytedance/seedance-2.5',
      prompt: 'scene',
      mode: VideoMode.text,
      resolution: '1080p',
      ratio: '16:9',
      durationSeconds: 5,
      audio: true,
    );
    expect(
      () => VideoCapabilities(
        videoProviderType(VideoProtocol.openrouter_video),
      ).validateParameters(request, []),
      throwsA(
        isA<VideoException>().having((e) => e.field, 'field', 'resolution'),
      ),
    );
    VideoCapabilities(
      videoProviderType(VideoProtocol.ark_video),
    ).validateParameters(request, []);
  });

  test(
    'unregistered channel variants do not borrow another model configuration',
    () {
      expect(
        lookupVideoChannelModel(
          videoProviderType(VideoProtocol.openrouter_video),
          'bytedance/seedance-2.0-fastest',
        ),
        isNull,
      );
      expect(
        lookupVideoChannelModel(
          videoProviderType(VideoProtocol.openrouter_video),
          'doubao-seedance-2-5-260628',
        ),
        isNull,
      );
      expect(
        lookupVideoChannelModel(
          videoProviderType(VideoProtocol.ark_video),
          'google/veo-3.1',
        ),
        isNull,
      );
      expect(
        lookupVideoModel('alibaba/wan-3.0'),
        isNot(same(lookupVideoModel('alibaba/wan-3.0-prime'))),
      );
    },
  );

  test(
    'channel capabilities replace configured fields without mutating catalog',
    () {
      const route = VideoChannelModel(
        catalogId: 'veo-3.1',
        capabilities: VideoModelCapabilities(
          resolutions: {'720p', '8K'},
          ratios: {'16:9', '100:1'},
          durations: {4, 5, 6, 99},
          frameRoles: {VideoInputRole.first_frame},
        ),
      );
      expect(route.resolutions, {'720p', '8K'});
      expect(route.ratios, {'16:9', '100:1'});
      expect(route.durations, {4, 5, 6, 99});
      expect(route.frameRoles, {VideoInputRole.first_frame});
      expect(route.model.capabilities.resolutions, isNot(contains('8K')));
      expect(
        route.capabilities.maxReferences,
        route.model.capabilities.maxReferences,
      );
    },
  );

  test(
    'reference overrides merge by kind and field; empty and null are explicit',
    () {
      const base = VideoModelCapabilities(
        maxPromptCharacters: ConfigValue(100),
        supportsAudioOnlyReference: true,
        references: {
          VideoMediaKind.image: VideoReferenceLimits(
            maxCount: 2,
            maxSizeMb: ConfigValue(10),
          ),
          VideoMediaKind.audio: VideoReferenceLimits(
            maxCount: 3,
            maxDurationMs: ConfigValue(30000),
          ),
        },
      );
      final resolved = base.merge(
        const VideoModelCapabilities(
          maxPromptCharacters: ConfigValue(null),
          supportsAudioOnlyReference: false,
          resolutions: {},
          references: {
            VideoMediaKind.audio: VideoReferenceLimits(
              maxCount: 1,
              maxDurationMs: ConfigValue(null),
            ),
          },
        ),
      );
      expect(resolved.maxPromptCharacters, isNull);
      expect(resolved.supportsAudioOnlyReference, isFalse);
      expect(resolved.resolutions, isEmpty);
      expect(resolved.references[VideoMediaKind.image]!.maxSizeMb, 10);
      expect(resolved.references[VideoMediaKind.audio]!.maxCount, 1);
      expect(resolved.references[VideoMediaKind.audio]!.maxDurationMs, isNull);
      expect(
        base.merge(const VideoModelCapabilities(references: {})).references,
        isEmpty,
      );
    },
  );

  test('request defaults preserve false and explicit parameter omission', () {
    const base = VideoRequestDefaults(
      audio: ConfigValue(true),
      promptExtend: ConfigValue(true),
    );
    final merged = base.merge(
      const VideoRequestDefaults(
        audio: ConfigValue(false),
        promptExtend: ConfigValue(null),
      ),
    );
    expect(merged.audio, isFalse);
    expect(merged.promptExtend, isNull);
    expect(base.audio, isTrue);
  });
}
