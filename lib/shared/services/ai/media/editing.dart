// 职责: 将 Run editing 接到共享剪辑会话、原子命令、画面检查、后台预览及预览文件清理。
// 关联文件:
//   lib/shared/services/editing/session.dart
//   lib/shared/services/editing/agent_commands.dart
//   lib/shared/services/editing/render_service.dart
//   lib/shared/services/ai/tool_operations.dart
import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../../agent/agent_tool_dispatcher.dart';
import '../../../logger/app_logger.dart';
import '../../../database/novel_content_database.dart';
import '../../../models/editing/document.dart';
import '../../../models/tool_permission.dart';
import '../../../models/production/media.dart';
import '../../editing/service.dart';
import '../../editing/agent_commands.dart';
import '../../editing/render_service.dart';
import '../../production/ffmpeg_runner.dart';
import '../files/session_files.dart';
import '../files/command_paths.dart';
import '../files/attachments.dart';
import '../tool_operations.dart';
import 'production.dart';
import 'frames.dart';
import '../../production/contact_sheet.dart';

final _log = AppLogger.forModule('EditingPreview');

class EditingToolHost {
  EditingToolHost(this.production, {FfmpegRunner? runner})
    : runner = runner ?? FfmpegRunner();
  final FfmpegRunner runner;
  final ProductionToolHost production;
  Future<Map<String, dynamic>> run(
    String action,
    Map<String, dynamic> options,
    ToolExecutionContext context,
    ToolOperationManager operations,
    String callId,
  ) async {
    try {
      return await _run(action, options, context, operations, callId);
    } on EditingConflict {
      throw const ToolOperationException(
        'conflict',
        'The editing revision changed or is busy. Read it again.',
      );
    } on EditingSourceProblem {
      throw const ToolOperationException(
        'failed_precondition',
        'One or more editing sources are unavailable or exceed their media range.',
      );
    } on MediaException {
      throw const ToolOperationException(
        'failed_precondition',
        'The media cannot be imported or rendered.',
      );
    } on TypeError {
      throw const FormatException('Editing parameter has an invalid type.');
    } on StateError catch (error) {
      throw ToolOperationException('failed_precondition', error.message);
    } on RangeError {
      throw const FormatException(
        'Editing position is outside the valid range.',
      );
    }
  }

  Future<Map<String, dynamic>> _run(
    String action,
    Map<String, dynamic> options,
    ToolExecutionContext context,
    ToolOperationManager operations,
    String callId,
  ) async {
    final canvas = production.canvas;
    final service = EditingService(canvas.db, canvas.library);
    final sessions = production.editingSessions;
    if (sessions == null) {
      throw const ToolOperationException(
        'unavailable',
        'Shared editing sessions are unavailable.',
      );
    }
    final keys = EditingAgentCommands.keys,
        text = EditingAgentCommands.text,
        number = EditingAgentCommands.integer;
    if (action == 'cleanup') {
      keys(options, {'run_id'});
      return _cleanupPreview(text(options, 'run_id'), context, operations);
    }
    if (action == 'list') {
      keys(options, {'offset', 'limit'});
      final offset = options.containsKey('offset')
          ? number(options, 'offset')
          : 0;
      final limit = options.containsKey('limit')
          ? number(options, 'limit')
          : 50;
      if (limit < 1 || limit > 200) {
        throw const FormatException('limit must be 1..200.');
      }
      final rows = await canvas.db
          .customSelect(
            'SELECT id, title, revision, updated_at, json_extract(document, \'\$.ratio\') AS ratio FROM video_editings WHERE deleted_at = 0 ORDER BY updated_at DESC, id LIMIT ? OFFSET ?',
            variables: [Variable(limit), Variable(offset)],
          )
          .get();
      return {
        'ok': true,
        'entries': [
          for (final row in rows)
            {
              'id': row.read<String>('id'),
              'title': row.read<String>('title'),
              'revision': row.read<int>('revision'),
              'ratio': row.read<String>('ratio'),
              'updated_at': row.read<int>('updated_at'),
            },
        ],
        'offset': offset,
        'limit': limit,
      };
    }
    if (action == 'create') {
      keys(options, {'title', 'ratio'});
      final doc = EditingDocument.empty(text(options, 'ratio'));
      final canvasWork = await canvas.shots.isCanvasWork;
      final String id;
      String? nodeId;
      if (canvasWork) {
        final node = await canvas.addEditing(
          (await canvas.ensureCanvas('')).id,
          title: text(options, 'title'),
          ratio: doc.ratio,
        );
        id = node.editingId!;
        nodeId = node.id;
      } else {
        id = const Uuid().v4();
        await canvas.db.editingDao.create(id, text(options, 'title'), doc);
      }
      return {
        'ok': true,
        'id': id,
        'editing_id': id,
        'node_id': ?nodeId,
        if (nodeId != null) 'node_path': '/production/canvas/nodes/$nodeId',
        'revision': (await canvas.db.editingDao.get(id))!.revision,
        'document': doc.toJson(),
      };
    }
    if (!{
      'read',
      'apply',
      'undo',
      'redo',
      'preview',
      'frames',
    }.contains(action)) {
      throw const ToolOperationException(
        'unsupported',
        'Unsupported editing action.',
      );
    }
    keys(options, switch (action) {
      'read' => {'editing_id', 'track_id', 'start_frame', 'end_frame'},
      'frames' => {'editing_id', 'expected_revision', 'frames'},
      'apply' => {'editing_id', 'expected_revision', 'commands'},
      _ => {'editing_id', 'expected_revision'},
    });
    final id = text(options, 'editing_id');
    if (await canvas.shots.isCanvasWork) {
      await service.canvasForEditing(id);
    }

    if (await canvas.db.editingDao.get(id) == null) {
      throw const ToolOperationException(
        'not_found',
        'Editing project not found.',
      );
    }
    final session = sessions.get(service, id);
    final release = session.retain();
    try {
      await session.ensureLoaded();
      await session.flush();
      final current = await service.read(id);
      if (current.revision != session.revision) {
        await session.reload();
      }
      Map<String, dynamic> data() => {
        'ok': true,
        'id': id,
        'editing_id': id,
        'title': session.title,
        'revision': session.revision,
        'fps': editingFps,
        'ratio': session.document!.ratio,
        'tracks': session.document!.tracks.map((t) => t.toJson()).toList(),
        'clips': session.document!.clips.map((c) => c.toJson()).toList(),
        'total_frames': session.document!.totalFrames,
      };
      if (action == 'read') {
        if (options.containsKey('track_id') &&
            (options.containsKey('start_frame') ||
                options.containsKey('end_frame'))) {
          throw const FormatException('Choose a track or a frame interval.');
        }
        if (options.containsKey('start_frame') !=
            options.containsKey('end_frame')) {
          throw const FormatException(
            'Provide both start_frame and end_frame.',
          );
        }
        final result = data();
        var clips = session.document!.clips;
        if (options.containsKey('track_id')) {
          final track = text(options, 'track_id');
          if (!session.document!.tracks.any((t) => t.id == track)) {
            throw const ToolOperationException(
              'not_found',
              'Editing track not found.',
            );
          }
          clips = clips.where((c) => c.trackId == track).toList();
          result['tracks'] = session.document!.tracks
              .where((t) => t.id == track)
              .map((t) => t.toJson())
              .toList();
        }
        if (options.containsKey('start_frame')) {
          final start = number(options, 'start_frame'),
              end = number(options, 'end_frame');
          if (start >= end) {
            throw const FormatException(
              'start_frame must be before end_frame.',
            );
          }
          clips = clips
              .where((c) => c.startFrame < end && c.endFrame > start)
              .toList();
        }
        return {...result, 'clips': clips.map((c) => c.toJson()).toList()};
      }
      final expected = number(options, 'expected_revision');
      if (session.revision != expected) {
        throw const EditingConflict();
      }
      if (action == 'apply') {
        final commands = EditingAgentCommands.parse(options['commands']);
        final before = session.document!;
        final engine = EditingAgentCommands((command) async {
          if ((command['path'] == null) ==
              (command['production_clip_id'] == null)) {
            throw const FormatException('Provide path or production_clip_id.');
          }
          String assetId;
          if (command['production_clip_id'] != null) {
            final clipId = text(command, 'production_clip_id');
            final clip = await canvas.shots.getShot(clipId);
            if (clip == null || clip.adoptedAssetId == null) {
              throw const ToolOperationException(
                'failed_precondition',
                'The production clip has no adopted file.',
              );
            }
            await canvas.shots.requireEpisode(clip.episodeId);
            assetId = clip.adoptedAssetId!;
          } else {
            assetId = (await production.importPath(
              text(command, 'path'),
              context,
              operations,
              callId,
            )).id;
          }
          return service.source(assetId);
        });
        final results = await session.transact(expected, (doc, title) async {
          final result = await engine.apply(doc, title, commands);
          await service.verify(result.document, MediaCancellation());
          if (context.cancellationToken?.isCancellationRequested == true) {
            throw const ToolOperationException(
              'cancelled',
              'Editing was cancelled before saving.',
            );
          }
          return result;
        });
        return {
          ...data(),
          'results': results,
          'changes': EditingAgentCommands.changes(before, session.document!),
        };
      }
      if (action == 'undo' || action == 'redo') {
        final before = session.document!;
        await session.travel(expected, redo: action == 'redo');
        return {
          ...data(),
          'changes': EditingAgentCommands.changes(before, session.document!),
        };
      }
      final frozen = session.document!;
      final positions = action == 'frames'
          ? contactSheetPositions(
              options['frames'],
              'frames',
              end: frozen.totalFrames,
            )
          : null;
      final files = SessionFiles(
        root: canvas.library.root.path,
        novelId: canvas.novelId,
      );
      return await operations.start(
        context: context,
        callId: callId,
        workId: canvas.novelId,
        kind: 'editing.$action',
        targetPath: '/editings/$id',
        toolName: 'Run',
        targetLabel: session.title,
        // 预览要渲染整条时间线，固定后台；抽帧很快且结果要立即查看。
        background: action == 'preview',
        input: options,
        verifyTarget: () async {},
        execute: (operation) async {
          final renderer = EditingRenderService(service, runner);
          final token = MediaCancellation();
          final unlink = operation.cancellation.onCancel(
            () => unawaited(token.cancel()),
          );
          try {
            operation.checkCancelled();
            if (positions != null) {
              if (!Platform.isMacOS && !Platform.isWindows) {
                throw UnsupportedError(
                  'Editing rendering requires Windows or macOS.',
                );
              }
              final sheet = await renderer.frames(
                frozen,
                positions,
                cancellation: token,
                progress: (stage, progress) => operation.report(
                  progress: {'stage': stage, 'progress': progress},
                ),
              );
              return commandFileResult({
                ...await deliverFrameSheet(
                  files,
                  context.sessionId!,
                  sheet,
                  token,
                ),
                'editing_id': id,
                'revision': expected,
                'fps': editingFps,
              }, files);
            }
            final encoded = await renderer.render(
              frozen,
              cancellation: token,
              progress: (stage, progress) => operation.report(
                progress: {'stage': stage, 'progress': progress},
              ),
              preview: true,
            );
            try {
              final snapshot = await files.copy(
                context.sessionId!,
                encoded.file,
                cancelled: () => operation.cancellation.isCancellationRequested,
              );
              if (operation.cancellation.isCancellationRequested) {
                await snapshot.delete();
                operation.checkCancelled();
              }
              return commandFileResult({
                'ok': true,
                'editing_id': id,
                'revision': expected,
                'files': [
                  {
                    'delivered': true,
                    'file_path': files.reference(snapshot),
                    'snapshot_path': files.reference(snapshot),
                    'bytes': await snapshot.length(),
                  },
                ],
                'width': encoded.info.width,
                'height': encoded.info.height,
                'fps': encoded.info.frameRate,
                'duration_ms': encoded.info.duration.inMilliseconds,
              }, files);
            } finally {
              await encoded.dispose();
            }
          } on EditingSourceProblem {
            throw const ToolOperationException(
              'failed_precondition',
              'One or more editing sources are unavailable or exceed their media range.',
            );
          } on FormatException catch (error) {
            throw ToolOperationException('invalid_argument', error.message);
          } on UnsupportedError {
            throw const ToolOperationException(
              'unsupported',
              'Editing rendering requires Windows or macOS.',
            );
          } finally {
            unlink();
            await renderer.dispose();
          }
        },
      );
    } finally {
      release();
      sessions.prune();
    }
  }

  Future<Map<String, dynamic>> _cleanupPreview(
    String runId,
    ToolExecutionContext context,
    ToolOperationManager operations,
  ) async {
    final run = operations.read(runId, context);
    if (run['kind'] != 'editing.preview' ||
        run['work_id'] != production.canvas.novelId ||
        !{'completed', 'failed'}.contains(run['status'])) {
      throw const ToolOperationException(
        'failed_precondition',
        'Only finished editing previews in this work can be cleaned up.',
      );
    }
    final result = run['result'] as Map?;
    final outputs = result?['files'];
    if (outputs is! List || outputs.isEmpty) {
      throw const ToolOperationException(
        'failed_precondition',
        'This preview has no recorded output files to clean up.',
      );
    }
    final files = SessionFiles(
      root: production.canvas.library.root.path,
      novelId: production.canvas.novelId,
    );
    final sessionId = run['source_session_id'] as String;
    final commandPaths = CommandPaths(files);
    final paths = <String>{};
    for (final output in outputs) {
      if (output is! Map) {
        throw const FormatException('Invalid preview output record.');
      }
      final path = output['snapshot_path'];
      final reference = output['file_path'];
      if (path is! String || reference is! String) {
        throw const FormatException('Invalid preview output path.');
      }
      final parts = p.posix.split(path);
      if (parts.length != 5 ||
          parts[0] != 'file_workspaces' ||
          parts[1] != production.canvas.novelId ||
          parts[2] != 'sessions' ||
          parts[3] != sessionId ||
          path.contains('\\') ||
          p.posix.extension(path).toLowerCase() != '.mp4' ||
          files.reference(
                File(commandPaths.absolute(reference, write: true)),
              ) !=
              path) {
        throw const FormatException('Preview output escaped its session.');
      }
      await commandPaths.checkRelative(reference);
      paths.add(path);
    }
    try {
      // Validate the session directory and every output before removing any file.
      final directory = await files.directory(sessionId);
      final targets = <File>[];
      final missing = <String>[];
      for (final path in paths) {
        final file = File(p.join(directory.path, p.posix.basename(path)));
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          missing.add(commandPaths.reference(file));
        } else if (type == FileSystemEntityType.file) {
          targets.add(file);
        } else {
          throw const FormatException('Preview output must be a regular file.');
        }
      }
      for (final file in targets) {
        await file.delete();
      }
      return {
        'ok': true,
        'run_id': runId,
        'removed': targets.map(commandPaths.reference).toList(),
        'missing': missing,
      };
    } on FileSystemException catch (error, stack) {
      _log.error('cleanup failed run=$runId', error: error, stackTrace: stack);
      throw const ToolOperationException(
        'file_cleanup_failed',
        'Some preview files could not be removed. Retry cleanup for this run.',
      );
    }
  }
}
