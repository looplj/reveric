// 职责: 对视频节点的视频截帧、分离音轨、静音或裁剪，产物入资产库并作为派生节点挂到画布上（可由画布指定落点并让位）。
// 关联文件:
//   lib/shared/services/production/media_service.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/library_service.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/file-access.md

import 'package:path/path.dart' as p;
import '../../database/app_database.dart' show AssetRow;
import '../../models/production/media.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import 'canvas_service.dart';
import 'ffmpeg_runner.dart';
import 'media_service.dart';

final _log = AppLogger.forModule('VideoTool');

/// 截帧位置：[at] 为 null 时按 [last] 取首帧或尾帧。
typedef VideoFramePosition = ({Duration? at, bool last});

/// 本次执行使用的素材和产物登记回调；省略时从当前节点解析。
typedef VideoToolSource = ({
  AssetRow asset,
  String path,
  void Function(AssetRow) onImported,
});

class VideoToolOrchestrator {
  Future<CanvasNode> frame(
    ProductionCanvasService service,
    String nodeId,
    VideoFramePosition position, {
    ProductionNodePlacement? Function()? place,
    VideoToolSource? source,
    MediaCancellation? cancellation,
  }) => _run(
    service,
    nodeId,
    'frame',
    (media, path, token) => media.extractFrame(
      path,
      at: position.at ?? Duration.zero,
      last: position.at == null && position.last,
      cancellation: token,
    ),
    (stem) => position.at != null
        ? '${stem}_${position.at!.inMilliseconds}ms.png'
        : '${stem}_${position.last ? 'last' : 'first'}.png',
    place,
    source,
    cancellation,
  );

  Future<CanvasNode> separateAudio(
    ProductionCanvasService service,
    String nodeId, {
    ProductionNodePlacement? Function()? place,
    VideoToolSource? source,
    MediaCancellation? cancellation,
  }) async {
    final asset = await separateAudioAsset(
      service,
      source?.asset ?? await service.videoSource(nodeId),
      path: source?.path,
      cancellation: cancellation ?? MediaCancellation(),
    );
    source?.onImported(asset);
    return service.addDerivedOutput(nodeId, asset.id, placement: place?.call());
  }

  Future<AssetRow> separateAudioAsset(
    ProductionCanvasService service,
    AssetRow source, {
    String? path,
    required MediaCancellation cancellation,
  }) async {
    final library = service.library;
    final result = await library.media.extractAudio(
      path ?? library.resolve(source),
      cancellation: cancellation,
    );
    try {
      return await library.importFile(
        result.file,
        name: '${p.basenameWithoutExtension(source.name)}_audio.m4a',
        novelId: service.novelId,
        purpose: AssetPurpose.production_video_tool,
        cancellation: cancellation,
      );
    } finally {
      await result.dispose();
    }
  }

  Future<CanvasNode> mute(
    ProductionCanvasService service,
    String nodeId, {
    ProductionNodePlacement? Function()? place,
    VideoToolSource? source,
    MediaCancellation? cancellation,
  }) => _run(
    service,
    nodeId,
    'mute',
    (media, path, token) => media.mute(path, cancellation: token),
    (stem) => '${stem}_muted.mp4',
    place,
    source,
    cancellation,
  );

  Future<CanvasNode> trim(
    ProductionCanvasService service,
    String nodeId,
    Duration start,
    Duration end, {
    ProductionNodePlacement? Function()? place,
    VideoToolSource? source,
    MediaCancellation? cancellation,
  }) => _run(
    service,
    nodeId,
    'trim',
    (media, path, token) => media.trim(path, start, end, cancellation: token),
    (stem) => '${stem}_${start.inMilliseconds}-${end.inMilliseconds}ms.mp4',
    place,
    source,
    cancellation,
  );

  Future<CanvasNode> _run(
    ProductionCanvasService service,
    String nodeId,
    String operation,
    Future<EncodedMedia> Function(
      MediaService media,
      String path,
      MediaCancellation token,
    )
    transform,
    String Function(String stem) name,
    ProductionNodePlacement? Function()? place,
    VideoToolSource? inputSource,
    MediaCancellation? cancellation,
  ) async {
    _log.info('started operation=$operation node=$nodeId');
    final source = inputSource?.asset ?? await service.videoSource(nodeId);
    final token = cancellation ?? MediaCancellation();
    if (token.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    final library = service.library;
    final result = await transform(
      library.media,
      inputSource?.path ?? library.resolve(source),
      token,
    );
    try {
      final asset = await library.importFile(
        result.file,
        name: name(p.basenameWithoutExtension(source.name)),
        novelId: service.novelId,
        purpose: AssetPurpose.production_video_tool,
        cancellation: token,
      );
      inputSource?.onImported(asset);
      // 已登记资产完成节点挂接；迟到取消由调用方连同输出一起返回。
      // 处理要几秒，落点在入库后再算，用的是画布此刻的布局。
      final node = await service.addDerivedOutput(
        nodeId,
        asset.id,
        placement: place?.call(),
      );
      _log.info(
        'completed operation=$operation node=$nodeId output=${node.id}',
      );
      return node;
    } finally {
      await result.dispose();
    }
  }
}
