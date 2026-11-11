// 职责: 将图片派生、预设草稿与宫格操作接入生成审批、生成等待、后台提交及逐项结果返回。
// 关联文件:
//   lib/shared/services/ai/media/production.dart
//   lib/shared/services/production/view_derive_orchestrator.dart
//   lib/shared/services/production/grid_orchestrator.dart
//   lib/shared/services/production/node_source.dart
import 'dart:async';
import '../../../agent/agent_tool_dispatcher.dart';
import '../../../database/novel_content_database.dart';
import '../../../models/ai_provider.dart';
import '../../../models/tool_permission.dart';
import '../../../models/production/image_request.dart';
import '../../../models/production/media.dart';
import '../../../models/production/view_presets.dart';
import '../../production/ffmpeg_runner.dart';
import '../../production/grid_orchestrator.dart';
import '../../production/image_generate_orchestrator.dart';
import '../../production/node_source.dart';
import '../../production/view_derive_orchestrator.dart';
import '../../storyboard/service.dart';
import '../tool_operations.dart';
import 'production.dart';
import 'nodes.dart';

const productionImageActions = {'derive-view', 'image-preset', 'split-grid'};

class ProductionImageCommands {
  ProductionImageCommands(this.host);
  final ProductionToolHost host;

  Future<Map<String, dynamic>> run(
    RunCommandSpec spec,
    Map<String, dynamic> options,
    ToolExecutionContext context,
    ToolOperationManager operations,
    String callId,
  ) async {
    try {
      return await _run(spec, options, context, operations, callId);
    } on StoryboardException catch (error) {
      throw ToolOperationException(
        error.code == 'request_conflict' ? 'conflict' : 'failed_precondition',
        'StoryboardException(${error.code})',
      );
    } on MediaException catch (error) {
      throw ToolOperationException(
        error.reason.name,
        ffmpegFailureDetail(error.toString(), const []),
      );
    }
  }

  Future<Map<String, dynamic>> _run(
    RunCommandSpec spec,
    Map<String, dynamic> raw,
    ToolExecutionContext context,
    ToolOperationManager operations,
    String callId,
  ) async {
    final options = freezeToolArguments(raw);
    final action = spec.subcommand;
    final allowed = {
      'node_id',
      if (action == 'image-preset') ...['method', 'title'],
      if (action == 'derive-view') ...[
        'preset',
        'args',
        'provider_id',
        'model_id',
        'title',
      ],
      if (action == 'split-grid') ...[
        'rows',
        'cols',
        'cells',
        'upscale',
        'provider_id',
        'model_id',
      ],
    };
    if (options.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unknown image node option');
    }
    final nodeId = options['node_id'];
    if (nodeId is! String || nodeId.trim().isEmpty) {
      throw const FormatException('node_id is required');
    }
    if (options.containsKey('title') && options['title'] is! String) {
      throw const FormatException('title must be a string');
    }
    final title = options['title'] as String?;
    final method = action == 'image-preset'
        ? _enumValue(
            ImageGenerationMethod.values.where(
              (m) => m != ImageGenerationMethod.free,
            ),
            options['method'],
            'method',
          )
        : null;
    final preset = action == 'derive-view'
        ? _enumValue(
            [ViewPreset.camera, ViewPreset.light],
            options['preset'],
            'preset',
          )
        : null;
    final args = preset == null ? null : _viewArgs(preset, options['args']);
    final int? rows, cols, multiplier;
    final cells = <int>{};
    if (action == 'split-grid') {
      final r = options['rows'], c = options['cols'];
      if (r is! int ||
          c is! int ||
          r < 1 ||
          r > 5 ||
          c < 1 ||
          c > 5 ||
          r * c <= 1) {
        throw const FormatException(
          'rows and cols must be 1..5 with more than one cell',
        );
      }
      rows = r;
      cols = c;
      final selected = options['cells'];
      if (selected != null && selected is! List) {
        throw const FormatException('cells must be an integer array');
      }
      for (final value in selected as List? ?? const []) {
        if (value is! int || value < 0 || value >= r * c || !cells.add(value)) {
          throw const FormatException(
            'cells must contain distinct in-range integer indices',
          );
        }
      }
      final factor = options['upscale'];
      if (options.containsKey('upscale') &&
          (factor is! int || !{2, 4}.contains(factor) || cells.isEmpty)) {
        throw const FormatException(
          'upscale requires 2 or 4 and nonempty cells',
        );
      }
      multiplier = factor as int?;
      if (multiplier == null &&
          (options.containsKey('provider_id') ||
              options.containsKey('model_id'))) {
        throw const FormatException('provider_id/model_id require upscale');
      }
    } else {
      rows = null;
      cols = null;
      multiplier = null;
    }
    final generates = action == 'derive-view' || multiplier != null;
    AiModelOption? model;
    if (generates) {
      final providerId = options['provider_id'], modelId = options['model_id'];
      if (providerId is! String ||
          providerId.isEmpty ||
          modelId is! String ||
          modelId.isEmpty) {
        throw const FormatException('provider_id and model_id are required');
      }
      final provider = await host.database.aiProviderDao.getById(providerId);
      if (provider == null ||
          !provider.enabled ||
          !provider.imageModels.contains(modelId)) {
        throw const ToolOperationException(
          'failed_precondition',
          'The selected image provider/model is unavailable.',
        );
      }
      if (multiplier != null) {
        final supported = gridUpscaleMultipliers(
          ProductionImageCapabilities(provider, modelId),
        );
        if (!supported.contains(multiplier)) {
          throw ToolOperationException(
            'failed_precondition',
            'The selected image provider/model does not support ${multiplier}x grid upscale. '
                'Supported multipliers: ${supported.isEmpty ? 'none' : supported.map((factor) => '${factor}x').join(', ')}.',
          );
        }
      }
      model = AiModelOption(
        providerId: providerId,
        providerDisplayName: provider.name,
        model: modelId,
        kind: AiModelKind.image,
      );
    }
    var source = await ProductionNodeSource.image(host.canvas, nodeId);
    if (method != null) {
      final node = await ViewDeriveOrchestrator().createDraft(
        service: host.canvas,
        sourceNodeId: nodeId,
        method: method,
        title: title ?? source.node.title,
      );
      return {
        'ok': true,
        'source_node_id': nodeId,
        'source_asset_id': source.asset.id,
        'outputs': [
          {
            ...await outputSummary(host.canvas, node, source.episodeId),
            'generated': false,
          },
        ],
      };
    }
    // node_id 指向作品内素材，本地操作无需文件审批。生成审批期间允许换图、改配置；
    // 批准后读取当前来源并组装请求，不比较旧快照，也不为提交前的短时间窗再次审批。
    final target = productionNodePath(source.episodeId, nodeId);
    Future<void> resolveSource() async {
      try {
        source = await ProductionNodeSource.image(host.canvas, nodeId);
      } on StoryboardException catch (error) {
        throw ToolOperationException(
          'failed_precondition',
          'The source image is unavailable: StoryboardException(${error.code})',
        );
      }
    }

    return operations.start(
      context: context,
      callId: callId,
      workId: host.canvas.novelId,
      kind: spec.operation,
      targetPath: target,
      toolName: 'Run',
      background: true,
      input: options,
      permission: generates
          ? ToolActionRequest(
              action: 'generation.image',
              targetPath: target,
              targetLabel: source.node.title,
              context: ToolPermissionContext(
                workId: host.canvas.novelId,
                sessionId: context.sourceSessionId ?? context.sessionId,
                episodeId: source.episodeId,
              ),
              summary: {
                'source_node_id': nodeId,
                'operation': action,
                'provider_id': model!.providerId,
                'model': model.model,
                'upscale': ?multiplier,
              },
            )
          : null,
      verifyTarget: resolveSource,
      execute: (operation) async {
        final token = MediaCancellation();
        final unlink = operation.cancellation.onCancel(
          () => unawaited(token.cancel()),
        );
        final created = <int, String>{};
        final generated = <String, Map<String, dynamic>>{};
        final failures = <Map<String, dynamic>>[];
        final registered = <Map<String, dynamic>>[];
        CanvasNode? group;
        var stage = 'authorization';
        try {
          operation.checkCancelled();
          stage = 'create';
          if (preset != null) {
            late ProductionImagePreview prepared;
            final node = await ViewDeriveOrchestrator().create(
              service: host.canvas,
              sourceNodeId: nodeId,
              preset: preset,
              args: args!,
              model: model,
              title: title ?? source.node.title,
              inputSource: source,
              cancellation: token,
              onPreview: (preview) {
                prepared = preview;
              },
            );
            created[0] = node.id;
            operation.checkCancelled();
            stage = 'generation';
            generated[node.id] = await _generate(prepared, operation);
          } else {
            void onCreated(CanvasNode node, Map<int, String> members) {
              group = node;
              created.addAll(members);
            }

            if (multiplier == null) {
              await GridOrchestrator().split(
                canvas: host.canvas,
                sourceNodeId: nodeId,
                rows: rows!,
                cols: cols!,
                selected: cells,
                inputSource: source,
                cancellation: token,
                onCreated: onCreated,
                onImported: (cell, asset) =>
                    registered.add({'cell': cell, ...assetSummary(asset)}),
              );
            } else {
              final result = await GridOrchestrator().upscale(
                canvas: host.canvas,
                jobs: host.images,
                sourceNodeId: nodeId,
                rows: rows!,
                cols: cols!,
                selected: cells,
                model: model!,
                multiplier: multiplier,
                inputSource: source,
                cancellation: token,
                onCreated: onCreated,
                onImported: (cell, asset) =>
                    registered.add({'cell': cell, ...assetSummary(asset)}),
              );
              generated.addAll(result.results);
              for (final entry in result.failures.entries) {
                failures.add({
                  'node_id': entry.key,
                  'stage': entry.value.stage.name,
                  'error_code': entry.value.errorCode == 'request_conflict'
                      ? 'conflict'
                      : entry.value.errorCode,
                  'error': entry.value.message,
                  'task_id': ?entry.value.taskId,
                });
              }
            }
          }
        } catch (error) {
          failures.add({'node_id': nodeId, 'stage': stage, ..._error(error)});
        } finally {
          unlink();
        }
        final outputs = <Map<String, dynamic>>[];
        for (final entry in created.entries) {
          final result = generated[entry.value];
          if (result?['ok'] == false) {
            failures.add({
              'node_id': entry.value,
              if (group != null) 'cell': entry.key,
              'stage': 'generation',
              'error_code':
                  result?['error_code'] ??
                  (result?['cancelled'] == true
                      ? 'cancelled'
                      : result?['status'] ?? 'generation_failed'),
              'error': result?['error'] ?? 'Generation did not complete.',
              'task_id': ?result?['task_id'],
            });
          }
          try {
            final node = await host.canvas.requireNode(entry.value);
            final taskResult = result?['submitted'] == true
                ? await host.summary(
                    await host.images.requireRun(result!['task_id'] as String),
                  )
                : result;
            final taskAssetId = taskResult?['result_asset_id'];
            final taskAsset = taskAssetId is String
                ? await host.canvas.requireAsset(taskAssetId)
                : null;
            outputs.add({
              ...await outputSummary(host.canvas, node, source.episodeId),
              if (taskAsset != null) ...assetSummary(taskAsset),
              if (group != null) 'cell': entry.key,
              if (generates) 'generated': taskResult?['ok'] == true,
              if (multiplier != null) 'submitted': result?['submitted'] == true,
              if (result != null) ...{
                'task_id': ?result['task_id'],
                'task_status': ?taskResult?['status'],
                'result_applied': ?taskResult?['result_applied'],
                'upstream_may_continue': ?taskResult?['upstream_may_continue'],
              },
            });
          } catch (error) {
            failures.add({
              'node_id': entry.value,
              if (group != null) 'cell': entry.key,
              'stage': 'output',
              ..._error(error),
            });
          }
        }
        final cancelled = operation.cancellation.isCancellationRequested;
        return {
          'ok': failures.isEmpty && !cancelled,
          'source_node_id': nodeId,
          'source_asset_id': source.asset.id,
          'outputs': outputs,
          if (group != null) ...{
            'group_node_id': group!.id,
            'members': [
              for (final e in created.entries)
                {'cell': e.key, 'node_id': e.value},
            ],
          },
          if (registered.isNotEmpty && group == null)
            'registered_assets': registered,
          if (generated.length == 1)
            'task_id': ?generated.values.single['task_id'],
          if (failures.isNotEmpty) ...{
            'failures': failures,
            'error_code': failures.first['error_code'],
            'error': failures.first['error'],
          },
          if (cancelled) ...{
            'cancelled': true,
            'error_code': 'cancelled',
            if (generated.values.any((result) => result['submitted'] == true))
              'upstream_may_continue': true,
          },
        };
      },
    );
  }

  Future<Map<String, dynamic>> _generate(
    ProductionImagePreview preview,
    ToolOperationContext operation,
  ) async {
    String? trackedTaskId;
    final execution = ToolOperationContext(operation.cancellation, ({
      taskId,
      progress,
    }) {
      trackedTaskId = taskId ?? trackedTaskId;
      operation.report(taskId: taskId, progress: progress);
    }, operation.input);
    try {
      return await host.generate(preview, preview.sourceId, execution);
    } catch (error) {
      return {'ok': false, ..._error(error), 'task_id': ?trackedTaskId};
    }
  }
}

Map<String, dynamic> _error(Object error) => {
  'error_code': switch (error) {
    ToolOperationException e => e.code,
    FormatException() => 'invalid_argument',
    MediaException e => e.reason.name,
    StoryboardException e =>
      e.code == 'request_conflict' ? 'conflict' : 'failed_precondition',
    _ => 'internal',
  },
  'error': ffmpegFailureDetail(switch (error) {
    ToolOperationException e => '${e.code}: ${e.message}',
    StoryboardException e => 'StoryboardException(${e.code})',
    _ => error.toString(),
  }, const []),
};

T _enumValue<T extends Enum>(Iterable<T> values, Object? raw, String field) =>
    values.where((v) => v.name == raw).firstOrNull ??
    (throw FormatException('Unsupported $field: $raw'));

ViewPresetArgs _viewArgs(ViewPreset preset, Object? raw) {
  if (raw != null && raw is! Map) {
    throw const FormatException('args must be an object');
  }
  final args = raw as Map? ?? const {};
  final allowed = preset == ViewPreset.camera
      ? {'yaw', 'pitch', 'framing'}
      : {'direction', 'brightness', 'texture', 'temperature', 'description'};
  if (args.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('args contain fields from another preset');
  }
  if (preset == ViewPreset.camera) {
    final yaw = args['yaw'] ?? 0, pitch = args['pitch'] ?? 0;
    if (yaw is! int ||
        pitch is! int ||
        !cameraYawFragments.containsKey(yaw) ||
        !cameraPitchFragments.containsKey(pitch)) {
      throw const FormatException('Unsupported camera yaw/pitch');
    }
    return ViewPresetArgs(
      yaw: yaw,
      pitch: pitch,
      framing: _enumValue(
        CameraFraming.values,
        args['framing'] ?? 'medium',
        'framing',
      ),
    );
  }
  final description = args['description'] ?? '';
  if (description is! String) {
    throw const FormatException('description must be a string');
  }
  return ViewPresetArgs(
    direction: _enumValue(
      LightDirection.values,
      args['direction'] ?? 'front',
      'direction',
    ),
    brightness: _enumValue(
      LightBrightness.values,
      args['brightness'] ?? 'moderate',
      'brightness',
    ),
    texture: _enumValue(
      LightTexture.values,
      args['texture'] ?? 'soft',
      'texture',
    ),
    temperature: _enumValue(
      LightTemperature.values,
      args['temperature'] ?? 'neutral',
      'temperature',
    ),
    description: description,
  );
}
