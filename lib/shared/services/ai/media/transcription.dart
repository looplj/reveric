// 职责: 将素材和画布转录命令接入会话审批、后台执行与结果跟踪。
// 关联文件:
//   lib/shared/services/ai/media/production.dart
//   lib/shared/services/production/transcription_service.dart
//   lib/shared/services/ai/tool_operations.dart

import 'dart:async';

import '../../../agent/agent_tool_dispatcher.dart';
import '../../../models/production/media.dart';
import '../../../models/tool_permission.dart';
import '../../../models/transcription/result.dart';
import '../../production/canvas_service.dart';
import '../../production/ffmpeg_runner.dart';
import '../../production/transcription_service.dart';
import '../../production/video_tool_orchestrator.dart';
import '../../storyboard/service.dart';
import '../tool_operations.dart';
import 'nodes.dart';

Future<Map<String, dynamic>> runTranscriptionCommand({
  required TranscriptionService service,
  required ProductionCanvasService canvas,
  required ToolExecutionContext context,
  required ToolOperationManager operations,
  required String callId,
  required String id,
  required bool nodeScope,
}) async {
  try {
    final node = nodeScope ? await canvas.requireNode(id) : null;
    final source = nodeScope
        ? await canvas.currentMediaAsset(id)
        : await canvas.requireAsset(id);
    if (source.type != 'audio' && source.type != 'video') {
      throw const TranscriptionException('invalid_media');
    }
    final selection = await service.selection();
    final episodeId = node == null || await canvas.shots.isCanvasWork
        ? ''
        : (await (canvas.db.select(canvas.db.screenplayEpisodes)
                    ..where((table) => table.canvasId.equals(node.canvasId)))
                  .getSingle())
              .id;
    final path = node == null
        ? '/assets/$id'
        : productionNodePath(episodeId, id);
    return await operations.start(
      context: context,
      callId: callId,
      workId: canvas.novelId,
      kind: nodeScope ? 'production.transcribe' : 'assets.transcribe',
      targetPath: path,
      toolName: 'Run',
      background: true,
      input: {nodeScope ? 'node_id' : 'id': id},
      permission: ToolActionRequest(
        action: 'media.transcribe',
        context: ToolPermissionContext(
          workId: canvas.novelId,
          sessionId: context.sourceSessionId ?? context.sessionId,
          episodeId: episodeId,
        ),
        targetPath: path,
        targetLabel: source.name,
        summary: {
          'asset_id': source.id,
          'provider': selection.provider.name,
          'model': selection.model.id,
        },
      ),
      verifyTarget: () async {
        await canvas.requireAsset(source.id);
        if (nodeScope && (await canvas.currentMediaAsset(id)).id != source.id) {
          throw const ToolOperationException(
            'conflict',
            'The canvas node media changed before transcription.',
          );
        }
      },
      execute: (operation) async {
        try {
          final result = await service.run(
            canvas: canvas,
            assetId: source.id,
            nodeId: node?.id,
            selection: selection,
            cancellation: operation.cancellation,
            onTask: (id) => operation.report(taskId: id),
          );
          final nodeId = result.nodeId;
          return {
            'ok': true,
            'source_asset_id': source.id,
            'task_id': result.taskId,
            'segment_count': result.segmentCount,
            'transcript_path': result.path,
            if (nodeId != null) ...{
              'node_id': nodeId,
              'node_path': productionNodePath(episodeId, nodeId),
            },
          };
        } on TranscriptionException catch (error) {
          return {
            'ok': false,
            'error_code': error.code,
            'error': error.detail ?? error.code,
            if (error.code == 'cancelled') 'cancelled': true,
          };
        }
      },
    );
  } on TranscriptionException catch (error) {
    throw ToolOperationException(error.code, error.detail ?? error.code);
  } on StoryboardException catch (error) {
    throw ToolOperationException('failed_precondition', error.reason);
  }
}

Future<Map<String, dynamic>> runSeparateAudioAssetCommand({
  required ProductionCanvasService canvas,
  required ToolExecutionContext context,
  required ToolOperationManager operations,
  required String callId,
  required String id,
}) async {
  final source = await canvas.requireAsset(id, type: 'video');
  return operations.start(
    context: context,
    callId: callId,
    workId: canvas.novelId,
    kind: 'assets.separate-audio',
    targetPath: '/assets/$id',
    toolName: 'Run',
    background: true,
    input: {'id': id},
    verifyTarget: () async {
      await canvas.requireAsset(id, type: 'video');
    },
    execute: (operation) async {
      final token = MediaCancellation();
      final unlink = operation.cancellation.onCancel(
        () => unawaited(token.cancel()),
      );
      try {
        final asset = await VideoToolOrchestrator().separateAudioAsset(
          canvas,
          source,
          cancellation: token,
        );
        return {'ok': true, 'source_asset_id': id, ...assetSummary(asset)};
      } on MediaException catch (error) {
        return {
          'ok': false,
          'error_code': error.reason.name,
          'error': error.message ?? error.reason.name,
          if (error.reason == MediaFailure.cancelled) 'cancelled': true,
        };
      } finally {
        unlink();
      }
    },
  );
}
