// 职责: 将制作生成工具接到持久任务及会话后台运行与取消。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/result_service.dart
//   lib/shared/services/ai/tool_operations.dart
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/video/task_result.dart';
import '../assets/certification.dart';
import '../video/draft.dart';
import 'nodes.dart';
import 'image_nodes.dart';
import 'panorama_nodes.dart';
import '../../production/panorama_service.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:path/path.dart' as p;
import '../../production/ffmpeg_runner.dart';
import '../../editing/sessions.dart';
import '../files/session_files.dart';
import '../files/command_paths.dart';
import '../files/attachments.dart';
import 'package:collection/collection.dart';
import '../../../agent/agent_tool_dispatcher.dart';
import '../../../database/app_database.dart' as app;
import '../../../database/novel_content_database.dart';
import '../../../models/tool_permission.dart';
import '../../production/canvas_service.dart';
import '../../production/image_generate_orchestrator.dart';
import '../../production/audio_generate_orchestrator.dart';
import '../../production/generate_orchestrator.dart';
import '../../production/image_service.dart';
import '../../production/audio_service.dart';
import '../../production/result_service.dart';
import '../../storyboard/service.dart';
import '../video/task_service.dart';
import '../tool_operations.dart';

/// 授权冻结的是原草稿身份与内容，不依赖当前片段的编辑配置。
class _DraftCompletionPreview {
  const _DraftCompletionPreview(this.source);
  final app.GenerationTask source;
}

/// Session-bound operations. Approval-gated commands use [operations] on every platform;
/// media commands are registered only when [media] is true.
class ToolOperationHost {
  const ToolOperationHost(
    this.operations, {
    this.media = true,
    this.production,
    this.openSettings,
  }) : assert(media || production == null);
  final ToolOperationManager operations;
  final void Function(String section)? openSettings;

  /// The host provides production, editing, ffmpeg and local file commands.
  final bool media;

  /// Absent when the session has no work content database.
  final Future<ProductionToolHost> Function()? production;
}

class ProductionToolHost {
  ProductionToolHost({
    required this.canvas,
    required this.images,
    required this.audio,
    required this.video,
    required this.results,
    this.editingSessions,
    this.assets,
    PanoramaService? panorama,
  }) : panorama = panorama ?? PanoramaService(canvas);
  final ProductionCanvasService canvas;
  final ImageTaskService images;
  final AudioTaskService audio;
  final Future<VideoTaskService> Function() video;
  final ProductionResultService results;
  final EditingSessions? editingSessions;

  /// 渠道私域素材认证；宿主不提供时 `assets certify` 返回 unavailable。
  final ProviderAssetService? assets;
  final PanoramaService panorama;
  app.AppDatabase get database => canvas.library.database;

  Future<CanvasNode> nodeForClip(String id) async {
    final clip = await canvas.shots.getShot(id);
    if (clip == null) {
      throw const ToolOperationException(
        'not_found',
        'The production clip does not exist.',
      );
    }
    await canvas.shots.requireEpisode(clip.episodeId);
    final canvasId = clip.episodeId.isEmpty
        ? (await canvas.ensureCanvas('')).id
        : (await canvas.db.screenplayDao.getEpisode(clip.episodeId))!.canvasId;
    if (canvasId == null) {
      throw const ToolOperationException(
        'failed_precondition',
        'The production canvas has not been created.',
      );
    }
    final node = (await canvas.db.canvasDao.getNodesByCanvas(
      canvasId,
    )).where((n) => n.clipId == id).firstOrNull;
    if (node == null) {
      throw const ToolOperationException(
        'not_found',
        'The production node does not exist.',
      );
    }
    return node;
  }

  /// 将作品相对文件导入为制作产物，持久引用始终使用应用根相对路径。
  Future<app.AssetRow> permanentAsset(String path, {String? kind}) async {
    final files = SessionFiles(
      root: canvas.library.root.path,
      novelId: canvas.novelId,
    );
    if (CommandPaths.isAbsolute(path) || path.contains('://')) {
      throw const ToolOperationException(
        'invalid_argument',
        'Read the file into the current work before adopting it.',
      );
    }
    final source = await CommandPaths(files).resolve(path);
    final stored = files.reference(source);
    if (SessionFiles.isSessionPath(stored)) {
      final asset = await canvas.library.importFile(
        source,
        name: p.basename(source.path),
        novelId: canvas.novelId,
        purpose: AssetPurpose.production_output,
        cancellation: MediaCancellation(),
      );
      if (kind != null && asset.type != kind) {
        throw const ToolOperationException(
          'invalid_argument',
          'The file media type does not match the target.',
        );
      }
      return asset;
    }
    final file = await canvas.requireFile(stored, type: kind);
    final info = await canvas.library.probePath(file.path);
    final valid = switch (file.type) {
      'image' =>
        info.hasVideo &&
            info.width != null &&
            info.height != null &&
            {'png', 'mjpeg', 'webp'}.contains(info.videoCodec),
      'video' => info.hasVideo && info.duration > Duration.zero,
      'audio' =>
        info.hasAudio && !info.hasVideo && info.duration > Duration.zero,
      _ => false,
    };
    if (!valid) {
      throw const ToolOperationException(
        'invalid_argument',
        'The file contents do not match the media type.',
      );
    }
    final owner = await database.assetDao.findByPath(file.path);
    if (owner?.novelId != null && owner!.novelId != canvas.novelId) {
      throw const ToolPermissionException(
        'permission_denied',
        'This asset belongs to another work.',
      );
    }
    return canvas.assetForPath(file.path, type: kind);
  }

  Future<app.AssetRow> importPath(
    String path,
    ToolExecutionContext context,
    ToolOperationManager operations,
    String callId,
  ) async {
    if (!CommandPaths.isAbsolute(path) && !path.contains('://')) {
      return permanentAsset(path);
    }
    final files = SessionFiles(
      root: canvas.library.root.path,
      novelId: canvas.novelId,
    );
    final source = await files.resolve(path);
    final before = await source.stat();
    final receipt = await operations.start(
      context: context,
      callId: callId,
      workId: canvas.novelId,
      kind: 'files.read',
      targetPath: path,
      toolName: 'Run',
      background: false,
      input: {'path': path},
      permission: ToolActionRequest(
        action: 'files.read',
        context: ToolPermissionContext(
          workId: canvas.novelId,
          sessionId: context.sourceSessionId ?? context.sessionId,
        ),
        targetPath: path,
        summary: {'path': path, 'purpose': 'Import into production media'},
      ),
      verifyTarget: () async {
        final current = await files.resolve(path);
        final stat = await current.stat();
        if (current.path != source.path ||
            stat.size != before.size ||
            stat.modified != before.modified) {
          throw const ToolOperationException(
            'conflict',
            'The selected file changed.',
          );
        }
      },
      execute: (operation) async {
        final copy = await files.copy(
          context.sessionId!,
          source,
          cancelled: () => operation.cancellation.isCancellationRequested,
        );
        operation.checkCancelled();
        return {'ok': true, 'file_path': CommandPaths(files).reference(copy)};
      },
    );
    final result = receipt['result'] as Map?;
    if (result?['ok'] != true) {
      throw ToolOperationException(
        receipt['error_code'] as String? ?? 'cancelled',
        'The media file was not authorized or imported.',
      );
    }
    return permanentAsset(result!['file_path'] as String);
  }

  Future<void> adopt(String clipId, String? assetId) async {
    final node = await nodeForClip(clipId);
    if (assetId != null) {
      await canvas.adopt(node.id, assetId);
    } else {
      await canvas.unadopt(node.id);
    }
  }

  Future<Object> preview(
    String kind,
    String nodeId, {
    bool draft = false,
    String? draftTaskId,
  }) async {
    try {
      if (draftTaskId != null) {
        final node = await canvas.requireNode(nodeId);
        final source = await database.generationTaskDao.getById(draftTaskId);
        if (source == null ||
            source.novelId != canvas.novelId ||
            source.sourceType != 'production_clip' ||
            source.sourceId != node.clipId) {
          throw const ToolOperationException(
            'not_found',
            'The draft task does not belong to this clip.',
          );
        }
        return _DraftCompletionPreview(
          await (await video()).inspectDraftCompletion(source.id),
        );
      }
      return await switch (kind) {
        'image' => ProductionImageGenerateOrchestrator().preview(
          canvas,
          nodeId,
        ),
        'audio' => ProductionAudioGenerateOrchestrator().preview(
          canvas,
          nodeId,
        ),
        'video' => ProductionGenerateOrchestrator().preview(
          canvas,
          nodeId,
          draft: draft,
        ),
        _ => throw const FormatException('Unknown generation kind'),
      };
    } on VideoException catch (error) {
      throw ToolOperationException(
        error.field ?? error.code.name,
        [error.toString(), ?error.detail].join('\n'),
      );
    } on StoryboardException catch (error) {
      throw ToolOperationException(error.code, error.toString());
    }
  }

  Map<String, dynamic> snapshot(Object value) => switch (value) {
    ProductionImagePreview(:final request) => request.toJson(),
    ProductionAudioPreview(:final request) => request.toJson(),
    _DraftCompletionPreview(:final source) => {
      'provider_id': source.providerId,
      'draft': false,
      'draft_task_id': source.id,
      'request': source.videoRequest.withResolution('1080p').toJson(),
    },
    ProductionPreview(
      :final request,
      :final inputs,
      :final providerId,
      :final draft,
    ) =>
      {
        'provider_id': providerId,
        'draft': draft,
        'request': request.toJson(),
        'inputs': [
          for (final input in inputs)
            {
              'path': input.file.path,
              'role': input.role.name,
              'mime_type': input.mimeType,
            },
        ],
      },
    _ => throw StateError('Unknown generation preview'),
  };

  /// Facts shown on the approval card; the frozen snapshot itself stays the execution input.
  Map<String, dynamic> approvalFacts(Map<String, dynamic> snapshot) {
    final request = snapshot['request'] is Map
        ? (snapshot['request'] as Map).cast<String, dynamic>()
        : snapshot;
    final references =
        snapshot['inputs'] as List? ?? request['references'] as List? ?? [];
    return {
      if (snapshot['draft'] == true)
        'mode': tr(LocaleKeys.productionDraftLabel),
      if (snapshot['draft_task_id'] != null)
        'mode': tr(LocaleKeys.productionCompleteDraft),
      'model': request['model_id'],
      'ratio': request['ratio'],
      'resolution': request['resolution'],
      if (request['duration_seconds'] != null)
        'duration': '${request['duration_seconds']}s',
      if (request['audio'] case final bool audio)
        'audio': tr(
          audio ? LocaleKeys.productionAudioOn : LocaleKeys.productionAudioOff,
        ),
      if (references.isNotEmpty) 'references': references.length,
      'prompt': request['prompt'],
    }..removeWhere((_, value) => value == null);
  }

  Future<Map<String, dynamic>> summary(app.GenerationTask task) async {
    final clip = await canvas.shots.getShot(task.sourceId);
    String? draftBlockedReason = 'not_draft';
    if (task.kind == app.GenerationKind.video && task.draft) {
      try {
        await (await video()).inspectDraftCompletion(task.id);
        draftBlockedReason = null;
      } on VideoException catch (error) {
        draftBlockedReason = error.field ?? error.code.name;
      }
    }
    return commandFileResult({
      'ok': task.status == app.GenerationTaskStatus.completed,
      'task_id': task.id,
      'id': task.id,
      'kind': task.kind.name,
      'status': task.status.name,
      'draft': task.draft,
      'draft_task_id': task.draftTaskId,
      if (task.kind == app.GenerationKind.video) ...{
        'draft_expires_at': task.draft
            ? task.draftExpiresAt?.toIso8601String()
            : null,
        'can_complete_draft': draftBlockedReason == null,
        'draft_completion_blocked_reason': draftBlockedReason,
      },
      if (task.status == app.GenerationTaskStatus.cancelled) 'cancelled': true,
      'cancel_requested_at': task.cancelRequestedAt?.toIso8601String(),
      'result_asset_id': task.resultAssetId,
      'result_file_path': task.path,
      'result_applied': clip?.lastAppliedGenerationTaskId == task.id,
      if (task.errorCode != null) 'error_code': task.errorCode,
      if (task.errorMessage != null) 'error': task.errorMessage,
      if (task.errorDetail != null) 'provider_error': task.errorDetail,
    }, SessionFiles(root: canvas.library.root.path, novelId: canvas.novelId));
  }

  Future<Map<String, dynamic>> run(
    RunCommandSpec spec,
    Map<String, dynamic> options,
    ToolExecutionContext context,
    ToolOperationManager operations,
    String callId,
  ) async {
    if (spec.subcommand == 'capture-panorama') {
      return ProductionPanoramaCommands(
        this,
      ).run(spec, options, context, operations, callId);
    }
    if (productionImageActions.contains(spec.subcommand)) {
      return ProductionImageCommands(
        this,
      ).run(spec, options, context, operations, callId);
    }
    if (productionVideoActions.contains(spec.subcommand)) {
      return ProductionNodeCommands(
        canvas,
      ).run(spec, options, context, operations, callId);
    }
    options = freezeToolArguments(options);
    final isVideo = spec.subcommand == 'generate-video';
    if (options.keys.any(
      (key) => !{
        'clip_id',
        if (isVideo) ...['draft', 'draft_task_id'],
      }.contains(key),
    )) {
      throw const FormatException('Unknown production generation option');
    }
    final clipId = options['clip_id'];
    if (clipId is! String || clipId.isEmpty) {
      throw const FormatException('clip_id is required');
    }
    if (options.containsKey('draft') && options['draft'] is! bool) {
      throw const FormatException('draft must be a boolean');
    }
    final draftTaskId = options['draft_task_id'];
    if (options.containsKey('draft_task_id') &&
        (draftTaskId is! String ||
            draftTaskId.trim().isEmpty ||
            draftTaskId != draftTaskId.trim())) {
      throw const FormatException(
        'draft_task_id must be a non-empty local generation task ID',
      );
    }
    final draft = options['draft'] == true;
    if (draft && draftTaskId != null) {
      throw const FormatException(
        'draft=true and draft_task_id are mutually exclusive',
      );
    }
    final kind = spec.subcommand.substring('generate-'.length);
    final target =
        '${await canvas.shots.isCanvasWork ? '/production' : ''}/clips/$clipId';
    final node = await nodeForClip(clipId);
    final clip = (await canvas.shots.getShot(clipId))!;
    if (clip.kind != kind) {
      throw const FormatException(
        'The generation action does not match the clip kind',
      );
    }
    final frozen = await preview(
      kind,
      node.id,
      draft: draft,
      draftTaskId: draftTaskId,
    );
    final frozenSnapshot = snapshot(frozen);
    return operations.start(
      context: context,
      callId: callId,
      workId: canvas.novelId,
      kind: spec.operation,
      targetPath: target,
      toolName: 'Run',
      // 生成要等审批和上游任务，固定后台执行，完成后再投递结果。
      background: true,
      input: options,
      permission: ToolActionRequest(
        action: spec.capability,
        targetLabel: clip.title.isEmpty ? null : clip.title,
        context: ToolPermissionContext(
          workId: canvas.novelId,
          sessionId: context.sourceSessionId ?? context.sessionId,
          episodeId: clip.episodeId,
        ),
        targetPath: target,
        summary: approvalFacts(frozenSnapshot),
      ),
      verifyTarget: () async {
        if (!const DeepCollectionEquality().equals(
          frozenSnapshot,
          snapshot(
            await preview(
              kind,
              node.id,
              draft: draft,
              draftTaskId: draftTaskId,
            ),
          ),
        )) {
          throw const ToolOperationException(
            'conflict',
            'The production inputs changed before generation.',
          );
        }
      },
      execute: (operation) => generate(frozen, clipId, operation),
    );
  }

  /// Executes a frozen request after its caller has completed authorization.
  Future<Map<String, dynamic>> generate(
    Object frozen,
    String clipId,
    ToolOperationContext operation,
  ) async {
    String? taskId;
    Map<String, dynamic> failure = const {};

    final cancelled = Completer<Map<String, dynamic>>();
    Future<void> cancel() async {
      try {
        final id = taskId;
        final task = id == null
            ? null
            : await database.generationTaskDao.getById(id);
        if (task == null) {
          if (!cancelled.isCompleted) {
            cancelled.complete({
              'ok': false,
              'cancelled': true,
              'upstream_may_continue': false,
            });
          }
          return;
        }
        final decision = await results.requestCancellation(task.id);
        final current = (await database.generationTaskDao.getById(task.id))!;
        if (!decision.accepted && !current.status.isTerminal) {
          return;
        }
        if (!cancelled.isCompleted) {
          cancelled.complete(
            current.status.isTerminal
                ? await summary(current)
                : {
                    'ok': false,
                    'cancelled': true,
                    'task_id': task.id,
                    'upstream_may_continue':
                        task.status != app.GenerationTaskStatus.prepared,
                    'result_applied': decision.resultApplied,
                  },
          );
        }
      } catch (error, stack) {
        if (!cancelled.isCompleted) {
          cancelled.completeError(error, stack);
        }
      }
    }

    final unlink = operation.cancellation.onCancel(() => unawaited(cancel()));
    Future<void> prepared(String id) async {
      taskId = id;
      operation.report(taskId: id);
      if (operation.cancellation.isCancellationRequested) {
        await results.requestCancellation(id);
      }
    }

    Future<Map<String, dynamic>> generate() async {
      operation.checkCancelled();
      switch (frozen) {
        case ProductionImagePreview(:final request):
          taskId = await images.submit(
            novelId: canvas.novelId,
            sourceType: 'production_clip',
            sourceId: clipId,
            request: request,
            onPrepared: prepared,
            onFailure: (diagnostic, code) {
              failure = {'error': diagnostic, 'error_code': ?code};
            },
          );
        case ProductionAudioPreview(:final request):
          taskId = await audio.submit(
            novelId: canvas.novelId,
            sourceType: 'production_clip',
            sourceId: clipId,
            request: request,
            onPrepared: prepared,
          );
        case ProductionPreview(
          :final request,
          :final providerId,
          :final inputs,
          :final draft,
        ):
          final video = await this.video();
          final id = await video.create(
            novelId: canvas.novelId,
            sourceType: 'production_clip',
            sourceId: clipId,
            providerId: providerId,
            request: request,
            inputs: inputs,
            draft: draft,
          );
          await prepared(id);
          if (!operation.cancellation.isCancellationRequested) {
            await video.submit(id, acknowledgeReferenceUpload: true);
            await video.start();
          }
        case _DraftCompletionPreview(:final source):
          final video = await this.video();
          final id = await video.createDraftCompletion(source.id);
          await prepared(id);
          if (!operation.cancellation.isCancellationRequested) {
            await video.submit(id);
            await video.start();
          }
        default:
          throw StateError('Unknown generation preview');
      }
      final task = await database.generationTaskDao
          .watchTask(taskId!)
          .where(
            (task) =>
                task != null &&
                (task.status.isTerminal ||
                    task.status == app.GenerationTaskStatus.action_required ||
                    task.status == app.GenerationTaskStatus.submission_unknown),
          )
          .first;
      await results.recover();
      return {...await summary(task!), ...failure};
    }

    try {
      return await Future.any([generate(), cancelled.future]);
    } on VideoException catch (error) {
      final task = taskId == null
          ? null
          : await database.generationTaskDao.getById(taskId!);
      return {
        if (task != null) ...await summary(task),
        'ok': false,
        'error_code': error.field ?? error.code.name,
        'error': [error.toString(), ?error.detail].join('\n'),
      };
    } on StoryboardException catch (error) {
      throw ToolOperationException(
        error.code == 'request_conflict' ? 'conflict' : 'failed_precondition',
        'The production request could not be completed (${error.code}).',
      );
    } finally {
      unlink();
    }
  }
}
