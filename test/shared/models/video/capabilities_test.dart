// 职责: 验证视频模型目录驱动的参数和参考媒体边界校验。
// 关联文件:
//   lib/shared/models/video/catalog.dart
//   lib/shared/models/video/capabilities.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/video/capabilities.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import '../../../helpers/media_provider_types.dart';

Matcher invalid(String field) => throwsA(
  isA<VideoException>()
      .having((e) => e.code, 'code', VideoErrorCode.invalid_request)
      .having((e) => e.field, 'field', field),
);

VideoReference reference({
  VideoInputRole role = VideoInputRole.reference_image,
  String? mimeType,
  int fileSize = 100,
  int dimension = 720,
  int? height,
  int durationMs = 2000,
  double frameRate = 30,
}) => VideoReference(
  role: role,
  url: Uri.https('reference.example', '/media').toString(),
  mimeType:
      mimeType ??
      switch (role.kind) {
        VideoMediaKind.image => 'image/png',
        VideoMediaKind.video => 'video/mp4',
        VideoMediaKind.audio => 'audio/mpeg',
      },
  fileSize: fileSize,
  mediaInfo: VideoMediaInfo(
    width: dimension,
    height: height ?? dimension,
    durationMs: durationMs,
    frameRate: frameRate,
  ),
);

void main() {
  final agnesCaps = VideoCapabilities(
    videoProviderType(VideoProtocol.agnes_video),
  );
  VideoRequest agnesRequest({
    String model = 'agnes-video-2.5-flash',
    String resolution = '720P',
    String ratio = '16:9',
    int duration = 5,
    VideoMode mode = VideoMode.reference,
  }) => VideoRequest(
    modelId: model,
    prompt: 'bird',
    mode: mode,
    resolution: resolution,
    ratio: ratio,
    durationSeconds: duration,
  );
  test(
    'Agnes Flash rejects unsupported resolution and video before submission',
    () {
      expect(
        () => agnesCaps.validate(agnesRequest(resolution: '1080P'), [
          reference(),
        ]),
        invalid('resolution'),
      );
      expect(
        () => agnesCaps.validate(agnesRequest(), [
          reference(role: VideoInputRole.reference_video),
        ]),
        invalid('video_count'),
      );
      expect(
        () => agnesCaps.validate(
          agnesRequest(),
          List.generate(6, (_) => reference()),
        ),
        invalid('image_count'),
      );
      expect(
        () =>
            agnesCaps.validate(agnesRequest(ratio: 'adaptive'), [reference()]),
        invalid('ratio'),
      );
      for (final duration in [3, 13]) {
        expect(
          () => agnesCaps.validate(agnesRequest(duration: duration), [
            reference(),
          ]),
          invalid('duration'),
        );
      }
      for (final duration in [4, 12]) {
        agnesCaps.validate(agnesRequest(duration: duration), [reference()]);
      }
    },
  );
  test('Agnes enforces strict individual and combined image byte limits', () {
    expect(
      () => agnesCaps.validate(agnesRequest(), [
        reference(fileSize: 15 * 1024 * 1024),
      ]),
      invalid('file_size'),
    );
    agnesCaps.validate(agnesRequest(), [
      reference(fileSize: 15 * 1024 * 1024 - 1),
    ]);
    expect(
      () => agnesCaps.validate(
        agnesRequest(),
        List.generate(5, (_) => reference(fileSize: 10 * 1024 * 1024)),
      ),
      invalid('image_size'),
    );
    expect(
      () => agnesCaps.validate(agnesRequest(), [reference(dimension: 255)]),
      invalid('dimensions'),
    );
  });
  test(
    'Agnes audio-only references validate total duration rather than each clip minimum',
    () {
      agnesCaps.validate(agnesRequest(), [
        reference(role: VideoInputRole.reference_audio, durationMs: 1000),
        reference(role: VideoInputRole.reference_audio, durationMs: 1000),
      ]);
      for (final duration in [1999, 12001]) {
        expect(
          () => agnesCaps.validate(agnesRequest(), [
            reference(
              role: VideoInputRole.reference_audio,
              durationMs: duration,
            ),
          ]),
          invalid('audio_duration'),
        );
      }
    },
  );
  test(
    'Agnes standard supports one video while keyframes use explicit ratios',
    () {
      agnesCaps.validate(
        agnesRequest(model: 'agnes-video-2.5', resolution: '2K'),
        [reference(role: VideoInputRole.reference_video)],
      );
      for (final roles in [
        [VideoInputRole.first_frame],
        [VideoInputRole.last_frame],
        [VideoInputRole.first_frame, VideoInputRole.last_frame],
      ]) {
        agnesCaps.validate(
          agnesRequest(
            mode: roles.singleOrNull == VideoInputRole.first_frame
                ? VideoMode.first_frame
                : VideoMode.first_last_frame,
          ),
          [for (final role in roles) reference(role: role)],
        );
      }
    },
  );

  for (final sample in [
    (
      model: 'doubao-seedance-2-5-260628',
      protocol: VideoProtocol.ark_video,
      resolution: '720p',
      minSeconds: 4,
      maxSeconds: 30,
      maxPrompt: null,
      imageCount: 30,
      imageMb: 30,
      minDimension: 300,
      maxDimension: 6000,
      minFps: 24.0,
      maxDurationMs: 30000,
    ),
    (
      model: 'MiniMax-H3',
      protocol: VideoProtocol.minimax_video_v2,
      resolution: '768P',
      minSeconds: 4,
      maxSeconds: 15,
      maxPrompt: 7000,
      imageCount: 9,
      imageMb: 30,
      minDimension: 256,
      maxDimension: 5760,
      minFps: 23.976,
      maxDurationMs: 15000,
    ),
    (
      model: 'wan3.0-video',
      protocol: VideoProtocol.wan_video,
      resolution: '720P',
      minSeconds: 2,
      maxSeconds: 30,
      maxPrompt: 20000,
      imageCount: 10,
      imageMb: 20,
      minDimension: 240,
      maxDimension: 8000,
      minFps: 16.0,
      maxDurationMs: 15000,
    ),
    (
      model: 'wan3.0-video-prime',
      protocol: VideoProtocol.wan_video,
      resolution: '720P',
      minSeconds: 2,
      maxSeconds: 30,
      maxPrompt: 20000,
      imageCount: 10,
      imageMb: 20,
      minDimension: 240,
      maxDimension: 8000,
      minFps: 16.0,
      maxDurationMs: 15000,
    ),
  ]) {
    final caps = VideoCapabilities(videoProviderType(sample.protocol));
    final base = VideoRequest(
      modelId: sample.model,
      prompt: 'A bird flying',
      mode: VideoMode.reference,
      resolution: sample.resolution,
      ratio: '16:9',
      audio: sample.protocol == VideoProtocol.minimax_video_v2 ? null : false,
      promptExtend: sample.protocol == VideoProtocol.wan_video ? false : null,
    );
    VideoRequest request(Map<String, dynamic> changes) =>
        VideoRequest.fromJson({...base.toJson(), ...changes});
    const roles = [VideoInputRole.reference_image];

    test(
      '${sample.model} preserves parameter boundaries and option presence',
      () {
        for (final duration in [sample.minSeconds, sample.maxSeconds]) {
          caps.validateParameters(
            request({'duration_seconds': duration}),
            roles,
          );
        }
        for (final duration in [sample.minSeconds - 1, sample.maxSeconds + 1]) {
          expect(
            () => caps.validateParameters(
              request({'duration_seconds': duration}),
              roles,
            ),
            invalid('duration'),
          );
        }
        for (final change in {
          'prompt': '   ',
          'resolution': 'invalid',
          'ratio': 'invalid',
          'audio': base.audio == null ? false : null,
          'prompt_extend': base.promptExtend == null ? false : null,
        }.entries) {
          expect(
            () => caps.validateParameters(
              request({change.key: change.value}),
              roles,
            ),
            invalid(change.key),
          );
        }
        final limit = sample.maxPrompt;
        if (limit != null) {
          // 非 BMP 字符按 rune 计数，不按 UTF-16 code unit 计数。
          caps.validateParameters(request({'prompt': '🎬' * limit}), roles);
          expect(
            () => caps.validateParameters(
              request({'prompt': '🎬' * (limit + 1)}),
              roles,
            ),
            invalid('prompt'),
          );
        }
      },
    );

    test('${sample.model} checks reference counts without reading media', () {
      caps.validateParameters(
        base,
        List.filled(sample.imageCount, roles.single),
      );
      expect(
        () => caps.validateParameters(
          base,
          List.filled(sample.imageCount + 1, roles.single),
        ),
        invalid('image_count'),
      );
      final text = request({'mode': 'text'});
      caps.validateParameters(text, []);
      expect(() => caps.validateParameters(text, roles), invalid('references'));
      final frames = request({'mode': 'first_last_frame', 'ratio': 'adaptive'});
      caps.validateParameters(frames, [
        VideoInputRole.last_frame,
        VideoInputRole.first_frame,
      ]);
      expect(
        () => caps.validateParameters(frames, [
          VideoInputRole.first_frame,
          VideoInputRole.first_frame,
        ]),
        invalid('references'),
      );
    });

    test('${sample.model} enforces image sizes, dimensions and formats', () {
      for (final dimension in [sample.minDimension, sample.maxDimension]) {
        caps.validate(base, [
          reference(
            dimension: dimension,
            fileSize: sample.imageMb * 1024 * 1024,
          ),
        ]);
      }
      for (final dimension in [
        sample.minDimension - 1,
        sample.maxDimension + 1,
      ]) {
        expect(
          () => caps.validate(base, [reference(dimension: dimension)]),
          invalid('dimensions'),
        );
      }
      expect(
        () => caps.validate(base, [
          reference(fileSize: sample.imageMb * 1024 * 1024 + 1),
        ]),
        invalid('file_size'),
      );
      for (final format in ['image/heic', 'image/heif', 'image/bmp']) {
        final supported = format == 'image/bmp'
            ? sample.protocol == VideoProtocol.wan_video
            : sample.protocol == VideoProtocol.minimax_video_v2;
        expect(
          () => caps.validate(base, [reference(mimeType: format)]),
          supported ? returnsNormally : invalid('mime_type'),
        );
      }
    });

    test(
      '${sample.model} enforces finite frame rates and total media duration',
      () {
        const video = VideoInputRole.reference_video;
        caps.validate(base, [reference(role: video, frameRate: sample.minFps)]);
        for (final fps in [
          sample.minFps - 0.001,
          double.nan,
          double.infinity,
        ]) {
          expect(
            () => caps.validate(base, [reference(role: video, frameRate: fps)]),
            invalid('frame_rate'),
          );
        }
        expect(
          () => caps.validate(base, [reference(role: video, frameRate: 61)]),
          sample.protocol == VideoProtocol.wan_video
              ? returnsNormally
              : invalid('frame_rate'),
        );
        for (final role in [video, VideoInputRole.reference_audio]) {
          caps.validate(base, [
            reference(role: role, durationMs: sample.maxDurationMs),
          ]);
          expect(
            () => caps.validate(base, [
              reference(role: role, durationMs: sample.maxDurationMs + 1),
            ]),
            invalid('input_duration'),
          );
          expect(
            () => caps.validate(base, [
              reference(role: role, durationMs: sample.maxDurationMs),
              reference(role: role),
            ]),
            invalid('${role.kind.name}_duration'),
          );
        }
      },
    );

    test('${sample.model} is not validated by another channel', () {
      final other = sample.protocol == VideoProtocol.ark_video
          ? VideoProtocol.wan_video
          : VideoProtocol.ark_video;
      // 未登记型号由业务层拦截，底层校验原样放行。
      expect(
        () => VideoCapabilities(
          videoProviderType(other),
        ).validateParameters(base, roles),
        returnsNormally,
      );
    });
  }

  for (final model in [
    'doubao-seedance-2-0-260128',
    'doubao-seedance-2-0-mini-260615',
  ]) {
    final caps = VideoCapabilities(videoProviderType(VideoProtocol.ark_video));
    VideoRequest request({
      String resolution = '720p',
      int duration = 5,
      VideoMode mode = VideoMode.reference,
      String ratio = '16:9',
    }) => VideoRequest(
      modelId: model,
      prompt: 'A bird flying',
      mode: mode,
      resolution: resolution,
      ratio: ratio,
      durationSeconds: duration,
      audio: true,
    );
    test('$model uses its own output specifications', () {
      for (final resolution in ['480p', '720p', '1080p', '4k']) {
        final supported =
            !model.contains('mini') || ['480p', '720p'].contains(resolution);
        expect(
          () => caps.validate(request(resolution: resolution), [reference()]),
          supported ? returnsNormally : invalid('resolution'),
        );
      }
      for (final duration in [4, 15]) {
        caps.validate(request(duration: duration), [reference()]);
      }
      for (final duration in [3, 16, 30]) {
        expect(
          () => caps.validate(request(duration: duration), [reference()]),
          invalid('duration'),
        );
      }
      caps.validateParameters(
        request(mode: VideoMode.text, ratio: 'adaptive'),
        [],
      );
      caps.validateParameters(request(mode: VideoMode.first_frame), [
        VideoInputRole.first_frame,
      ]);
      caps.validateParameters(request(mode: VideoMode.first_last_frame), [
        VideoInputRole.first_frame,
        VideoInputRole.last_frame,
      ]);
    });
    test(
      '$model requires visual input with audio and checks each media count',
      () {
        expect(
          () => caps.validateParameters(request(), [
            VideoInputRole.reference_audio,
          ]),
          invalid('audio_reference'),
        );
        for (final role in [
          VideoInputRole.reference_image,
          VideoInputRole.reference_video,
        ]) {
          caps.validateParameters(request(), [
            role,
            VideoInputRole.reference_audio,
          ]);
        }
        for (final sample in [
          (VideoInputRole.reference_image, 9),
          (VideoInputRole.reference_video, 3),
          (VideoInputRole.reference_audio, 3),
        ]) {
          final companion = sample.$1 == VideoInputRole.reference_audio
              ? [VideoInputRole.reference_image]
              : <VideoInputRole>[];
          caps.validateParameters(request(), [
            ...companion,
            ...List.filled(sample.$2, sample.$1),
          ]);
          expect(
            () => caps.validateParameters(request(), [
              ...companion,
              ...List.filled(sample.$2 + 1, sample.$1),
            ]),
            invalid('${sample.$1.kind.name}_count'),
          );
        }
      },
    );
    test(
      '$model accepts documented image formats and strictly bounds image size',
      () {
        for (final mime in [
          'image/jpeg',
          'image/png',
          'image/webp',
          'image/bmp',
          'image/tiff',
          'image/gif',
          'image/heic',
          'image/heif',
        ]) {
          caps.validate(request(), [
            reference(mimeType: mime, fileSize: 30 * 1024 * 1024 - 1),
          ]);
        }
        expect(
          () =>
              caps.validate(request(), [reference(fileSize: 30 * 1024 * 1024)]),
          invalid('file_size'),
        );
      },
    );
    test('$model bounds video pixels, bytes and media duration', () {
      const role = VideoInputRole.reference_video;
      for (final dimensions in [(614, 664), (3326, 2494)]) {
        caps.validate(request(), [
          reference(
            role: role,
            dimension: dimensions.$1,
            height: dimensions.$2,
            fileSize: 200 * 1024 * 1024,
          ),
        ]);
      }
      for (final dimensions in [(614, 663), (3326, 2495)]) {
        expect(
          () => caps.validate(request(), [
            reference(
              role: role,
              dimension: dimensions.$1,
              height: dimensions.$2,
            ),
          ]),
          invalid('dimensions'),
        );
      }
      expect(
        () => caps.validate(request(), [
          reference(role: role, fileSize: 200 * 1024 * 1024 + 1),
        ]),
        invalid('file_size'),
      );
      for (final mediaRole in [role, VideoInputRole.reference_audio]) {
        final companion = mediaRole.kind == VideoMediaKind.audio
            ? [reference()]
            : <VideoReference>[];
        for (final ms in [2000, 15000]) {
          caps.validate(request(), [
            ...companion,
            reference(role: mediaRole, durationMs: ms),
          ]);
        }
        for (final ms in [1999, 15001]) {
          expect(
            () => caps.validate(request(), [
              ...companion,
              reference(role: mediaRole, durationMs: ms),
            ]),
            invalid('input_duration'),
          );
        }
        expect(
          () => caps.validate(request(), [
            ...companion,
            reference(role: mediaRole, durationMs: 15000),
            reference(role: mediaRole),
          ]),
          invalid('${mediaRole.kind.name}_duration'),
        );
      }
    });
  }

  test('MiniMax applies combined reference count after per-kind limits', () {
    final caps = VideoCapabilities(
      videoProviderType(VideoProtocol.minimax_video_v2),
    );
    const request = VideoRequest(
      modelId: 'MiniMax-H3',
      prompt: 'A bird',
      mode: VideoMode.reference,
      resolution: '768P',
      ratio: '16:9',
    );
    final roles = [
      ...List.filled(9, VideoInputRole.reference_image),
      ...List.filled(3, VideoInputRole.reference_video),
    ];
    caps.validateParameters(request, roles);
    expect(
      () => caps.validateParameters(request, [
        ...roles,
        VideoInputRole.reference_audio,
      ]),
      invalid('reference_count'),
    );
  });
}
