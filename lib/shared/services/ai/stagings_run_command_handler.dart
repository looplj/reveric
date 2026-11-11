// 职责: 执行 Run stagings 的文档查询、原子编辑、历史恢复与画面检查。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_run.dart
//   lib/shared/services/screenplay/staging_edit.dart
//   lib/shared/services/director/contact_sheet.dart
part of 'tools.dart';

const _stagingCollections = {
  'objects',
  'cameras',
  'tracks',
  'motion_paths',
  'camera_cuts',
  'camera_moves',
};
void _productionCommandKeys(Map<String, dynamic> options, Set<String> allowed) {
  final unknown = options.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw FormatException(
      'Unknown command options: ${unknown.join(', ')}. '
      'Allowed: ${allowed.isEmpty ? 'none' : allowed.join(', ')}.',
    );
  }
}

String _stagingId(Map<String, dynamic> options) {
  final value = options['staging_id'];
  if (value is! String || value.trim().isEmpty) {
    throw const ToolOperationException(
      'invalid_argument',
      'staging_id is required. Use the staging_id from the current workspace context, the ref_id of a director node on the production canvas, or an id from Run stagings list.',
    );
  }
  return value;
}

ToolOperationException _stagingNotFound(String id) => ToolOperationException(
  'not_found',
  'Staging $id not found. Use the staging_id from the current workspace context or an id from Run stagings list; character, episode and canvas node ids are not staging ids.',
);

String _productionCommandText(Map<String, dynamic> options, String key) {
  final value = options[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a nonempty string.');
  }
  return value;
}

int _productionCommandInteger(Map<String, dynamic> options, String key) {
  final value = options[key];
  if (value is! int || value < 0) {
    throw FormatException('$key must be a nonnegative integer.');
  }
  return value;
}

extension _StagingsCommands on _AiToolManagerBase {
  Future<Map<String, dynamic>> _runStagingsCommand(
    String action,
    Map<String, dynamic> options,
  ) async {
    if (contentKind != contentKindScreenplay &&
        contentKind != contentKindCanvas) {
      throw const ToolOperationException(
        'unavailable',
        'Staging commands require a screenplay or canvas work.',
      );
    }
    final allowed = switch (action) {
      'list' || 'schema' => <String>{},
      'presets' => {'catalog', 'ids'},
      'sample' => {'staging_id', 'frames'},
      'frames' => {'staging_id', 'frames', 'camera_mode', 'camera_id'},
      'create' => {'title', 'document'},
      'read' => {'staging_id', 'collection', 'id', 'frame'},
      'apply' => {'staging_id', 'edits', 'commands'},
      'write' => {'staging_id', 'document'},
      'restore' => {'staging_id', 'version'},
      'remove' || 'preview' => {'staging_id'},
      _ => throw _RunCommandException(
        'Unknown staging action. ${_bundledSkillCommandGuidance('stagings', contentKind: contentKind)}',
      ),
    };
    // 只在执行边界兼容复数别名，后续校验和执行统一使用规范参数。
    if (allowed.contains('staging_id') && options.containsKey('stagings_id')) {
      final alias = options['stagings_id'];
      if (options.containsKey('staging_id') && options['staging_id'] != alias) {
        throw const FormatException('staging_id and stagings_id must match.');
      }
      options = Map<String, dynamic>.of(options)
        ..remove('stagings_id')
        ..['staging_id'] = alias;
    }
    if (action == 'apply' && options.containsKey('document')) {
      throw const FormatException(
        'apply does not accept document. Use stagings write for a complete replacement.',
      );
    }
    if (action == 'apply' && options.containsKey('title')) {
      throw const FormatException(
        'apply does not accept title. Use the set_title command.',
      );
    }
    _productionCommandKeys(options, allowed);
    if (action == 'write' && !options.containsKey('document')) {
      throw const FormatException('write requires a complete document.');
    }
    if (options.containsKey('title') && options['title'] is! String ||
        options.containsKey('document') &&
            options['document'] is! Map<String, dynamic>) {
      throw const FormatException(
        'title must be a string; document must be an object.',
      );
    }
    final service = _contentService.stagingEditService;
    final db = _contentService.database;
    Map<String, dynamic> data(VideoStagingRow row) => {
      'ok': true,
      'id': row.id,
      'title': row.title,
      'version': row.version,
      'document': row.document,
    };
    try {
      if (action == 'schema') {
        return {
          'ok': true,
          ...director.directorSchema(),
          'commands': {
            for (final entry in directorCommandFields.entries)
              entry.key: {
                'required': entry.value.$1.split(' '),
                'optional': entry.value.$2
                    .split(' ')
                    .where((s) => s.isNotEmpty)
                    .toList(),
              },
          },
        };
      }
      if (action == 'presets') {
        return {'ok': true, ...director.directorPresets(options: options)};
      }
      if (action == 'list') {
        final rows = await (db.select(
          db.videoStagings,
        )..where((t) => t.deletedAt.equals(notDeletedSentinel))).get();
        return {
          'ok': true,
          'entries': [
            for (final row in rows)
              data(row)
                ..remove('document')
                ..remove('ok'),
          ],
        };
      }
      if (action == 'create') {
        return data(
          await service.create(
            options['title'] as String? ?? 'Staging',
            document: options['document'] as Map<String, dynamic>?,
          ),
        );
      }
      final id = _stagingId(options);
      final row = await db.screenplayDao.getStaging(id);
      if (row == null) {
        throw _stagingNotFound(id);
      }
      if (action == 'sample') {
        if (row.document == null) {
          throw const DocumentError('document', 'not_initialized');
        }
        final frozen = DirectorDocument.fromJson(row.document!);
        return {
          'ok': true,
          'staging_id': id,
          'version': row.version,
          ...director.sampleDirector(frozen, options['frames']),
        };
      }
      if (action == 'frames') {
        return await _stagingFrames(row, options, service.previewRenderer);
      }
      if (action == 'read') {
        if (!options.containsKey('collection')) {
          if (options.containsKey('id') || options.containsKey('frame')) {
            throw const FormatException('id and frame require a collection.');
          }
          return data(row);
        }
        final collection = _productionCommandText(options, 'collection');
        if (!_stagingCollections.contains(collection)) {
          throw const FormatException('Unknown staging collection.');
        }
        if (row.document == null) {
          throw const DocumentError('document', 'not_initialized');
        }
        final entries = (row.document![collection] as List)
            .cast<Map>()
            .toList();
        final identity = {'ok': true, 'staging_id': id, 'version': row.version};
        if (!options.containsKey('id')) {
          if (options.containsKey('frame')) {
            throw const FormatException('frame requires a track id.');
          }
          return {
            ...identity,
            'entries': [
              for (final item in entries) {'id': item['id'], 'data': item},
            ],
          };
        }
        final itemId = _productionCommandText(options, 'id');
        final item = entries.where((item) => item['id'] == itemId).firstOrNull;
        if (item == null) {
          throw const DocumentError('id', 'not_found');
        }
        if (options.containsKey('frame')) {
          if (collection != 'tracks') {
            throw const FormatException('frame requires collection=tracks.');
          }
          final frame = _productionCommandInteger(options, 'frame');
          final key = (item['keys'] as List)
              .cast<Map>()
              .where((key) => key['frame'] == frame)
              .firstOrNull;
          if (key == null) {
            throw const DocumentError('frame', 'not_found');
          }
          return {...identity, 'id': itemId, 'frame': frame, 'data': key};
        }
        return {...identity, 'id': itemId, 'data': item};
      }
      if (action == 'preview') {
        final novelId = workId;
        if (novelId == null || novelId.isEmpty) {
          throw const ToolOperationException(
            'unavailable',
            'Staging preview requires a work context.',
          );
        }
        try {
          await service.preview(id, novelId: novelId);
        } on DocumentError {
          rethrow;
        } catch (error, stack) {
          _log.error(
            '[Staging] preview failed id=$id',
            error: error,
            stackTrace: stack,
          );
          throw const ToolOperationException(
            'internal',
            'Failed to generate staging preview.',
          );
        }
        return {'ok': true, 'id': id, 'updated': true};
      }
      if (action == 'remove') {
        await service.remove(id);
        return {'ok': true, 'id': id, 'removed': true};
      }
      final turnId = _currentToolExecutionContext?.sourceTurnId;
      if (turnId == null || turnId.isEmpty) {
        throw const ToolOperationException(
          'unavailable',
          'Staging edits require an active conversation turn.',
        );
      }
      Map<String, dynamic>? replacement =
          options['document'] as Map<String, dynamic>?;
      final edits = <Map<String, dynamic>>[];
      if (action == 'restore') {
        final version = _productionCommandInteger(options, 'version');
        final revision = await db.screenplayDao.getStagingRevision(id, version);
        if (revision == null) {
          throw const DocumentError('version', 'not_found');
        }
        replacement = revision.value;
      } else if (action == 'apply') {
        if (options.keys.every((key) => key == 'staging_id')) {
          throw const FormatException('apply requires edits or commands.');
        }
        if (options.containsKey('edits')) {
          final raw = options['edits'];
          if (raw is! List ||
              raw.isEmpty ||
              raw.any((edit) => edit is! Map<String, dynamic>)) {
            throw const FormatException(
              'edits must be a nonempty array of objects.',
            );
          }
          for (final value in raw) {
            final edit = Map<String, dynamic>.of(value as Map<String, dynamic>);
            final fields = edit['data'];
            if (fields is Map<String, dynamic> &&
                fields.containsKey('id') &&
                !edit.containsKey('frame')) {
              final nestedId = fields['id'];
              if (nestedId is! String || nestedId.trim().isEmpty) {
                throw const FormatException(
                  'data.id must be a nonempty string.',
                );
              }
              if (edit['id'] != null && edit['id'] != nestedId) {
                throw const FormatException('id and data.id must match.');
              }
              // 先提取资源身份，再生成缺省 ID；领域编辑只接收外层身份。
              edit['id'] = nestedId;
              edit['data'] = Map<String, dynamic>.of(fields)..remove('id');
            }
            if (edit['op'] == 'create' && !edit.containsKey('frame')) {
              edit['id'] ??= const Uuid().v4();
            }
            edits.add(edit);
          }
        }
      }
      final commands = <Map<String, dynamic>>[];
      if (options.containsKey('commands')) {
        final raw = options['commands'];
        if (raw is! List ||
            raw.isEmpty ||
            raw.any((v) => v is! Map<String, dynamic>)) {
          throw const FormatException(
            'commands must be a nonempty array of objects.',
          );
        }
        commands.addAll(raw.cast<Map<String, dynamic>>());
      }
      final commandResults = <Map<String, dynamic>>[];
      final saved = await service.save(
        id,
        turnId: turnId,
        document: replacement,
        edits: edits,
        commands: commands,
        commandResults: commandResults,
      );
      return {
        ...data(saved),
        'command_results': commandResults,
        'results': [
          for (final edit in edits)
            {
              'op': edit['op'],
              'collection': edit['collection'],
              'id': edit['id'],
              if (edit.containsKey('frame')) 'frame': edit['frame'],
            },
        ],
      };
    } on DocumentError catch (error) {
      throw ToolOperationException(
        error.reason == 'conflict'
            ? 'conflict'
            : error.reason == 'not_found'
            ? 'not_found'
            : 'invalid_argument',
        'Invalid staging command: ${error.path}: ${error.reason}',
      );
    } on ScreenplayServiceException catch (error) {
      return _screenplayException('stagings/$action', error);
    }
  }

  Future<Map<String, dynamic>> _stagingFrames(
    VideoStagingRow row,
    Map<String, dynamic> options,
    FrameRenderer Function() renderer,
  ) async {
    if (row.document == null) {
      throw const DocumentError('document', 'not_initialized');
    }
    final frozen = DirectorDocument.fromJson(row.document!);
    final frames = options['frames'];
    if (frames is! List ||
        frames.isEmpty ||
        frames.length > director.contactSheetMaxFrames ||
        frames.any((f) => f is! int || f < 0 || f > frozen.durationFrames)) {
      throw FormatException(
        'frames must contain 1–${director.contactSheetMaxFrames} integer frames from 0 to ${frozen.durationFrames}.',
      );
    }
    final mode = options['camera_mode'] ?? 'sequence';
    final cameraId = options['camera_id'];
    if (mode == 'fixed'
        ? cameraId is! String || frozen.camera(cameraId) == null
        : mode != 'sequence' || cameraId != null) {
      throw const FormatException(
        'camera_mode must be sequence or fixed; fixed requires an existing camera_id and sequence forbids camera_id.',
      );
    }
    final session = _currentToolExecutionContext?.sessionId ?? sessionId;
    if (session == null || session.isEmpty) {
      throw const ToolOperationException(
        'unavailable',
        'Staging frames require an active conversation session.',
      );
    }
    final director.ContactSheet sheet;
    try {
      sheet = await director.renderContactSheet(
        frozen,
        frames.cast<int>(),
        cameraId: cameraId as String?,
        renderer: renderer(),
      );
    } on DocumentError {
      rethrow;
    } catch (error, stack) {
      _log.error(
        '[Staging] frames render failed id=${row.id}',
        error: error,
        stackTrace: stack,
      );
      throw const ToolOperationException(
        'internal',
        'Failed to render staging frames.',
      );
    }
    final files = SessionFiles(novelId: workId);
    final file = await files.allocate(session, '.jpg');
    await file.writeAsBytes(sheet.jpeg, flush: true);
    final path = files.reference(file);
    return commandFileResult({
      'ok': true,
      'staging_id': row.id,
      'version': row.version,
      'width': sheet.width,
      'height': sheet.height,
      'cells': sheet.cells,
      'content_format': 'session_files_v1',
      'file_path': path,
      'content': [
        {'type': 'image', 'file_path': path, 'mime_type': 'image/jpeg'},
      ],
    }, files);
  }
}
