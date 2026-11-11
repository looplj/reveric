// 职责: 对当前作品的视频节点执行本地媒体处理，并返回后台操作、产物和取消结果。
// 关联文件:
//   lib/shared/services/ai/media/production.dart
//   lib/shared/services/production/video_tool_orchestrator.dart
//   lib/shared/services/ai/tool_operations.dart
import 'dart:async';
import 'dart:io';
import '../../../agent/agent_tool_dispatcher.dart';
import '../../../database/app_database.dart' show AssetRow;
import '../../../database/novel_content_database.dart';
import '../../../models/tool_permission.dart';
import '../../../models/production/asset_content.dart';
import '../../../models/production/media.dart';
import '../../production/canvas_service.dart';
import '../../production/ffmpeg_runner.dart';
import '../../production/video_tool_orchestrator.dart';
import '../../storyboard/service.dart';
import '../files/session_files.dart';
import '../tool_operations.dart';

const productionVideoActions = {
  'capture-frame',
  'separate-audio',
  'mute-video',
  'trim-video',
};

class ProductionNodeCommands {
  ProductionNodeCommands(this.canvas);
  final ProductionCanvasService canvas;

  Future<Map<String, dynamic>> run(
    RunCommandSpec spec,
    Map<String, dynamic> options,
    ToolExecutionContext context,
    ToolOperationManager operations,
    String callId,
  ) async {
    options = freezeToolArguments(options);
    final action = spec.subcommand;
    final allowed = {
      'node_id',
      if (action == 'capture-frame') ...['position', 'at_ms'],
      if (action == 'trim-video') ...['start_ms', 'end_ms'],
    };
    if (options.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unknown production node option');
    }
    final nodeId = options['node_id'];
    if (nodeId is! String || nodeId.isEmpty) {
      throw const FormatException('node_id is required');
    }
    if (action == 'capture-frame') {
      final position = options['position'];
      if (!{'first', 'last', 'at'}.contains(position) ||
          (position == 'at'
              ? options['at_ms'] is! int || (options['at_ms'] as int) < 0
              : options.containsKey('at_ms'))) {
        throw const FormatException(
          'position must be first/last/at; only at requires nonnegative integer at_ms',
        );
      }
    }
    if (action == 'trim-video' &&
        (options['start_ms'] is! int ||
            options['end_ms'] is! int ||
            (options['start_ms'] as int) < 0 ||
            (options['end_ms'] as int) <= (options['start_ms'] as int))) {
      throw const FormatException(
        'trim requires integer 0 <= start_ms < end_ms',
      );
    }
    if (!Platform.isWindows && !Platform.isMacOS) {
      throw const ToolOperationException(
        'unsupported',
        'Video node processing requires Windows or macOS.',
      );
    }
    try {
      final node = await canvas.requireNode(nodeId);
      late AssetRow source;
      final episodeId = await canvas.shots.isCanvasWork
          ? ''
          : (await (canvas.db.select(
              canvas.db.screenplayEpisodes,
            )..where((t) => t.canvasId.equals(node.canvasId))).getSingle()).id;
      final files = SessionFiles(
        root: canvas.library.root.path,
        novelId: canvas.novelId,
      );
      late File file;
      // 节点素材已属于当前作品，本地处理不申请 files.read，也不比较审批前快照。
      // 执行开始时使用当前采用素材；处理中换图不重启、不二次确认。
      Future<void> resolveSource() async {
        try {
          source = await canvas.videoSource(nodeId);
          file = await files.resolve(canvas.library.resolve(source));
        } on StoryboardException catch (error) {
          throw ToolOperationException(
            'failed_precondition',
            'StoryboardException(${error.code})',
          );
        }
      }

      final path = productionNodePath(episodeId, nodeId);
      return await operations.start(
        context: context,
        callId: callId,
        workId: canvas.novelId,
        kind: spec.operation,
        targetPath: path,
        toolName: 'Run',
        // 截帧很快且下一步通常立即使用；其余媒体处理耗时不定，固定后台。
        background: action != 'capture-frame',
        input: options,
        targetLabel: node.title,
        verifyTarget: resolveSource,
        execute: (operation) async {
          final token = MediaCancellation();
          final unlink = operation.cancellation.onCancel(
            () => unawaited(token.cancel()),
          );
          AssetRow? imported;
          var stage = 'probe';
          final inputSource = (
            asset: source,
            path: file.path,
            onImported: (AssetRow asset) {
              imported = asset;
              stage = 'attach_output';
            },
          );
          final outputs = <Map<String, dynamic>>[];
          Map<String, dynamic> result(Map<String, dynamic> status) => {
            ...status,
            'source_node_id': nodeId,
            'source_asset_id': source.id,
            'outputs': outputs,
            if (imported != null && outputs.isEmpty)
              'registered_assets': [assetSummary(imported!)],
          };
          try {
            operation.checkCancelled();
            final info = await canvas.library.media.probe(
              file.path,
              cancellation: token,
            );
            if (action == 'capture-frame' &&
                options['position'] == 'at' &&
                Duration(milliseconds: options['at_ms'] as int) >=
                    info.duration) {
              throw const ToolOperationException(
                'invalid_argument',
                'at_ms must be strictly before the measured video duration',
              );
            }
            if (action == 'trim-video' &&
                Duration(milliseconds: options['end_ms'] as int) >
                    info.duration) {
              throw const ToolOperationException(
                'invalid_argument',
                'end_ms exceeds the measured video duration',
              );
            }
            operation.checkCancelled();
            stage = 'process';
            final processor = VideoToolOrchestrator();
            final output = await switch (action) {
              'capture-frame' => processor.frame(
                canvas,
                nodeId,
                (
                  at: options['position'] == 'at'
                      ? Duration(milliseconds: options['at_ms'] as int)
                      : null,
                  last: options['position'] == 'last',
                ),
                source: inputSource,
                cancellation: token,
              ),
              'separate-audio' => processor.separateAudio(
                canvas,
                nodeId,
                source: inputSource,
                cancellation: token,
              ),
              'mute-video' => processor.mute(
                canvas,
                nodeId,
                source: inputSource,
                cancellation: token,
              ),
              'trim-video' => processor.trim(
                canvas,
                nodeId,
                Duration(milliseconds: options['start_ms'] as int),
                Duration(milliseconds: options['end_ms'] as int),
                source: inputSource,
                cancellation: token,
              ),
              _ => throw const FormatException('Unknown video node action'),
            };
            outputs.add(await outputSummary(canvas, output, episodeId));
            stage = 'complete';
            operation.checkCancelled();
            return result({'ok': true});
          } catch (error) {
            final cancelled = operation.cancellation.isCancellationRequested;
            final code = cancelled
                ? 'cancelled'
                : switch (error) {
                    ToolOperationException e => e.code,
                    MediaException e => e.reason.name,
                    FormatException() => 'invalid_argument',
                    StoryboardException() => 'failed_precondition',
                    FileSystemException() => 'file_unavailable',
                    _ => 'internal',
                  };
            final diagnostic = ffmpegFailureDetail(
              switch (error) {
                ToolOperationException e => '${e.code}: ${e.message}',
                StoryboardException e => 'StoryboardException(${e.code})',
                _ => error.toString(),
              },
              [file.path],
            );
            return result({
              'ok': false,
              'error_code': code,
              'error': diagnostic,
              'failures': [
                {
                  'node_id': nodeId,
                  'stage': stage,
                  'error_code': code,
                  'error': diagnostic,
                },
              ],
              if (cancelled) 'cancelled': true,
              if (error is MediaException) ...{
                if (error.nativeSessionId != null)
                  'native_session_id': error.nativeSessionId,
                if (error.nativeLog != null) 'log': error.nativeLog,
                if (error.nativeExitCode != null)
                  'exit_code': error.nativeExitCode,
              },
            });
          } finally {
            unlink();
          }
        },
      );
    } on StoryboardException catch (error) {
      throw ToolOperationException(
        error.code == 'source_missing' ? 'not_found' : 'failed_precondition',
        'StoryboardException(${error.code})',
      );
    }
  }
}

Future<Map<String, dynamic>> outputSummary(
  ProductionCanvasService canvas,
  CanvasNode node,
  String episodeId,
) async {
  final assetId =
      node.mediaAssetId ??
      (node.clipId == null
          ? null
          : (await canvas.shots.getShot(node.clipId!))?.adoptedAssetId);
  final AssetRow? asset = assetId == null
      ? null
      : await canvas.requireAsset(assetId);
  return {
    'node_id': node.id,
    'node_path': productionNodePath(episodeId, node.id),
    'type': node.type,
    if (node.clipId != null) 'clip_id': node.clipId,
    if (asset != null) ...assetSummary(asset),
  };
}

Map<String, dynamic> assetSummary(AssetRow asset) {
  final content = asset.content;
  return {
    'asset_id': asset.id,
    'file_path': asset.path,
    if (content is ImageAssetContent) ...{
      'width': content.width,
      'height': content.height,
    },
    if (content is VideoAssetContent) ...{
      'width': content.width,
      'height': content.height,
      'duration_ms': content.durationMs,
    },
    if (content is AudioAssetContent) 'duration_ms': content.durationMs,
  };
}

String productionNodePath(String episodeId, String nodeId) => episodeId.isEmpty
    ? '/production/canvas/nodes/$nodeId'
    : '/episodes/$episodeId/production/canvas/nodes/$nodeId';
