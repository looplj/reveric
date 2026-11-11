// 职责: 从当前作品的全景节点按指定视角取景，并返回逐方向截图、失败及取消结果。
// 关联文件:
//   lib/shared/services/ai/media/production.dart
//   lib/shared/services/production/panorama_service.dart
//   lib/shared/services/production/node_source.dart
//   lib/shared/services/production/derived_placement.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' show Size;
import '../../../agent/agent_tool_dispatcher.dart';
import '../../../models/tool_permission.dart';
import '../../../models/production/panorama.dart';
import '../../../models/production/media.dart';
import '../../production/derived_placement.dart';
import '../../production/ffmpeg_runner.dart';
import '../../production/node_source.dart';
import '../../production/panorama_service.dart';
import '../../storyboard/service.dart';
import '../tool_operations.dart';
import 'nodes.dart';
import 'production.dart';

class ProductionPanoramaCommands {
  ProductionPanoramaCommands(this.host);
  final ProductionToolHost host;

  Future<Map<String, dynamic>> run(
    RunCommandSpec spec,
    Map<String, dynamic> raw,
    ToolExecutionContext context,
    ToolOperationManager operations,
    String callId,
  ) async {
    final options = freezeToolArguments(raw);
    if (options.keys.any((key) => !{'node_id', 'views'}.contains(key))) {
      throw const FormatException('Unknown panorama capture option');
    }
    final nodeId = options['node_id'];
    if (nodeId is! String || nodeId.trim().isEmpty) {
      throw const FormatException('node_id is required');
    }
    final rawViews = options['views'];
    if (rawViews is! List || rawViews.isEmpty || rawViews.length > 4) {
      throw const FormatException(
        'views must contain 1..4 explicit directions',
      );
    }
    final views = <PanoramaView>[];
    final titles = <String?>[];
    for (final raw in rawViews) {
      if (raw is! Map ||
          raw.keys.any(
            (key) => !{'yaw', 'pitch', 'fov', 'title'}.contains(key),
          )) {
        throw const FormatException(
          'Each view accepts yaw, pitch, fov and optional title',
        );
      }
      final yaw = raw['yaw'], pitch = raw['pitch'], fov = raw['fov'];
      if (yaw is! num ||
          pitch is! num ||
          fov is! num ||
          (raw.containsKey('title') && raw['title'] is! String)) {
        throw const FormatException(
          'Each view requires numeric yaw/pitch/fov and an optional string title',
        );
      }
      final view = PanoramaView(
        yaw: yaw.toDouble(),
        pitch: pitch.toDouble(),
        fov: fov.toDouble(),
      );
      view.validate();
      views.add(
        PanoramaView(yaw: view.displayYaw, pitch: view.pitch, fov: view.fov),
      );
      titles.add(raw['title'] as String?);
    }
    if (views.length == 4) {
      final offsets = [
        for (final view in views) (view.yaw - views.first.yaw) % 360,
      ]..sort();
      if (views.any(
            (view) =>
                view.pitch != views.first.pitch || view.fov != views.first.fov,
          ) ||
          offsets.indexed.any(
            (entry) => (entry.$2 - entry.$1 * 90).abs() > 1e-8,
          )) {
        throw const FormatException(
          'Four views require equal pitch/fov and yaw directions spaced by 90 degrees',
        );
      }
    }
    late ProductionNodeSource source;
    Future<void> resolveSource() async {
      try {
        source = await ProductionNodeSource.image(host.canvas, nodeId);
        if (!isProductionPanoramaSource(source.node)) {
          throw const StoryboardException('invalid_reference');
        }
      } on StoryboardException catch (error) {
        throw ToolOperationException(
          'failed_precondition',
          'A panorama image or image node with panorama view enabled is required (${error.code}).',
        );
      } on MediaException catch (error) {
        throw ToolOperationException(
          error.reason.name,
          ffmpegFailureDetail(error.toString(), const []),
        );
      }
    }

    await resolveSource();

    final requests = [
      for (final (index, view) in views.indexed)
        (
          view: view,
          name: titles[index] ?? '${source.node.title} ${index + 1}'.trim(),
        ),
    ];
    return operations.start(
      context: context,
      callId: callId,
      workId: host.canvas.novelId,
      kind: spec.operation,
      targetPath: productionNodePath(source.episodeId, nodeId),
      toolName: 'Run',
      background: true,
      input: options,
      // 全景取景只读取作品内节点；执行时检查当前来源，无文件审批或来源快照比较。
      targetLabel: source.node.title,
      verifyTarget: resolveSource,
      execute: (operation) async {
        final token = MediaCancellation();
        final unlink = operation.cancellation.onCancel(
          () => unawaited(token.cancel()),
        );
        PanoramaCaptureResult? captured;
        final outputs = <Map<String, dynamic>>[];
        final failures = <Map<String, dynamic>>[];
        try {
          operation.checkCancelled();
          final placement = await defaultProductionDerivedPlacement(
            host.canvas,
            nodeId,
            Size(views.length == 1 ? 300 : 640, views.length <= 2 ? 300 : 640),
          );
          captured = await host.panorama.capture(
            nodeId,
            requests,
            inputSource: source,
            cancellation: token,
            placement: placement,
          );
          for (final entry in captured.byView.entries) {
            try {
              outputs.add({
                ...await outputSummary(
                  host.canvas,
                  entry.value,
                  source.episodeId,
                ),
                'view_index': entry.key,
                'view': views[entry.key].toJson(),
              });
            } catch (error) {
              failures.add({
                'view_index': entry.key,
                'view': views[entry.key].toJson(),
                'node_id': entry.value.id,
                'stage': 'output',
                ..._failure(error),
              });
            }
          }
          for (final entry in captured.viewFailures.entries) {
            failures.add({
              'view_index': entry.key,
              'view': views[entry.key].toJson(),
              'stage': entry.value.stage.name,
              ..._failure(entry.value.error),
            });
          }
        } catch (error) {
          failures.add({
            'source_node_id': nodeId,
            'stage': 'capture',
            ..._failure(error),
          });
        } finally {
          unlink();
        }
        final cancelled = operation.cancellation.isCancellationRequested;
        return {
          'ok': failures.isEmpty && !cancelled,
          'source_node_id': nodeId,
          'source_asset_id': source.asset.id,
          'outputs': outputs,
          'views': [
            for (final (index, view) in views.indexed)
              {
                'view_index': index,
                'view': view.toJson(),
                'title': requests[index].name,
                'node_id': ?captured?.byView[index]?.id,
              },
          ],
          if (captured?.registeredAssets.isNotEmpty == true)
            'registered_assets': [
              for (final entry in captured!.registeredAssets.entries)
                {'view_index': entry.key, ...assetSummary(entry.value)},
            ],
          if (failures.isNotEmpty) ...{
            'failures': failures,
            'error_code': failures.first['error_code'],
            'error': failures.first['error'],
          },
          if (cancelled) ...{'cancelled': true, 'error_code': 'cancelled'},
        };
      },
    );
  }
}

Map<String, dynamic> _failure(Object error) => {
  'error_code': switch (error) {
    ToolOperationException e => e.code,
    StoryboardException e =>
      e.code == 'request_conflict' ? 'conflict' : 'failed_precondition',
    FormatException() => 'invalid_argument',
    FileSystemException() => 'file_unavailable',
    UnsupportedError() => 'unsupported',
    MediaException e => e.reason.name,
    _ => 'internal',
  },
  'error': ffmpegFailureDetail(switch (error) {
    ToolOperationException e => '${e.code}: ${e.message}',
    StoryboardException e => 'StoryboardException(${e.code})',
    _ => error.toString(),
  }, const []),
};
