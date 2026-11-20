// 职责: 在最新导演调度文档上原子编辑子资源，并按 AI 回合保留修改前快照。
// 关联文件:
//   lib/shared/services/screenplay/staging.dart
//   lib/shared/models/director/document.dart
//   lib/shared/services/storyboard/service.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../database/novel_content_database.dart';
import '../../models/director/document.dart';
import '../../models/production/settings.dart';
import '../storyboard/service.dart';
import '../director/commands.dart';
import '../director/batch_commands.dart';
import '../director/file_output.dart';
import '../director/renderer.dart';
import '../director/storage.dart';
import 'staging.dart';

class StagingEditService {
  StagingEditService(
    this.database, {
    this.previewRenderer = DirectorRenderer.new,
    this.previewWorkspace = DirectorFileOutput.workspace,
  });
  final FrameRenderer Function() previewRenderer;
  final Future<DirectorStorage> Function(String, {required String novelId})
  previewWorkspace;
  final NovelContentDatabase database;
  static const collections = {
    'objects',
    'cameras',
    'tracks',
    'motion_paths',
    'camera_cuts',
    'camera_moves',
  };

  Future<VideoStagingRow> require(String id) async {
    final row = await database.screenplayDao.getStaging(id);
    if (row == null) {
      throw const DocumentError('staging', 'not_found');
    }
    return row;
  }

  /// 显式生成最新已保存文档的预览，不修改文档或历史。
  Future<void> preview(String id, {required String novelId}) async {
    final storage = await previewWorkspace(id, novelId: novelId);
    final document = await database.screenplayDao.serializeStaging(
      id,
      () async {
        final row = await require(id);
        if (row.document == null) {
          throw const DocumentError('document', 'not_initialized');
        }
        return DirectorDocument.fromJson(row.document!);
      },
    );
    await DirectorFileOutput.renderPreview(
      document,
      storage,
      renderer: previewRenderer(),
    );
  }

  Future<VideoStagingRow> create(String title, {Json? document}) =>
      StoryboardService(database).write('CREATE_STAGING', title, () async {
        final settings = await StoryboardService(database).requireSettings();
        final json = document ?? DirectorDocument.blank(title).toJson();
        if (document == null) {
          (json['output'] as Map).remove('aspect_mode');
          json['output']['width'] = settings.width;
          json['output']['height'] = settings.height;
        }
        final validated = DirectorDocument.fromJson(json);
        await validateReferences(validated);
        final id = const Uuid().v4();
        await database.screenplayDao.createStaging(id, validated.title);
        await database.screenplayDao.saveStaging(
          id,
          validated.toJson(),
          title: validated.title,
          savedAt: DateTime.now(),
        );
        return require(id);
      });

  Future<VideoStagingRow> duplicate(
    String id, {
    String? title,
    int? expectedVersion,
  }) async {
    await VideoStagingBinding.openFor(database.screenplayDao, id)?.flush();
    return database.screenplayDao.serializeStaging(id, () async {
      final source = await require(id);
      if (expectedVersion != null && source.version != expectedVersion) {
        throw const DocumentError('version', 'conflict');
      }
      if (source.document == null) {
        throw const DocumentError('document', 'not_initialized');
      }
      final parsed = DirectorDocument.fromJson(source.document!);
      final nextTitle = title ?? _defaultCopyTitle(parsed.title);
      final duplicated = parsed.instantiate().mutate(
        (j) => j['title'] = nextTitle,
      );
      await validateReferences(duplicated);
      return StoryboardService(database).write(
        'CREATE_STAGING',
        duplicated.title,
        () async {
          final newId = const Uuid().v4();
          await database.screenplayDao.createStaging(newId, duplicated.title);
          await database.screenplayDao.saveStaging(
            newId,
            duplicated.toJson(),
            title: duplicated.title,
            savedAt: DateTime.now(),
          );
          return require(newId);
        },
      );
    });
  }

  static String _defaultCopyTitle(String base) {
    const suffix = ' Copy';
    final trimmed = base.trim();
    if (trimmed.isEmpty) {
      return 'Staging Copy';
    }
    final candidate = '$trimmed$suffix';
    if (candidate.runes.length <= 80) {
      return candidate;
    }
    final prefix = String.fromCharCodes(
      trimmed.runes.take(80 - suffix.length),
    ).trimRight();
    return prefix.isEmpty ? 'Staging Copy' : '$prefix$suffix';
  }

  Future<VideoStagingRow> save(
    String id, {
    required String turnId,
    Json? document,
    String? title,
    List<Json> edits = const [],
    List<Json> commands = const [],
    List<Json>? commandResults,
  }) => database.screenplayDao.serializeStaging(id, () async {
    final row = await require(id);
    final current = row.document == null
        ? DirectorDocument.blank(row.title)
        : DirectorDocument.fromJson(row.document!);
    var json = document == null ? current.toJson() : cloneJson(document);
    if (json['id'] != current.id) {
      throw const DocumentError('id', 'immutable');
    }
    if (title != null) {
      json['title'] = title;
    }
    for (final edit in edits) {
      applyEdit(json, edit);
    }
    if (commands.isNotEmpty) {
      final history = CommandHistory(DirectorDocument.fromJson(json));
      try {
        final results = applyDirectorCommands(history, commands);
        json = history.document.toJson();
        commandResults?.addAll(results);
      } finally {
        history.dispose();
      }
    }
    json['revision'] = current.revision + 1;
    final next = DirectorDocument.fromJson(json);
    await validateReferences(next, previous: current);
    if (next.businessContent == current.businessContent) {
      return row;
    }
    await database.screenplayDao.saveStaging(
      id,
      next.toJson(),
      title: next.title,
      savedAt: DateTime.now(),
      checkpointId: const Uuid().v5(
        Namespace.url.value,
        'staging/$id/turn/$turnId',
      ),
      initialDocument: current.toJson(),
    );
    final saved = await require(id);
    VideoStagingBinding.openFor(database.screenplayDao, id)?.receive(saved);
    return saved;
  });

  Future<void> remove(String id) => database.screenplayDao.serializeStaging(
    id,
    () => StoryboardService(database).write(
      'UPDATE video_stagings',
      id,
      () async {
        await require(id);
        final refs =
            await (database.select(database.canvasNodes)..where(
                  (t) =>
                      t.refType.equals(canvasNodeRefTypeStaging) &
                      t.refId.equals(id) &
                      t.deletedAt.equals(notDeletedSentinel),
                ))
                .get();
        if (refs.isNotEmpty) {
          throw const DocumentError('staging', 'referenced');
        }
        await (database.update(database.videoStagings)
              ..where((t) => t.id.equals(id)))
            .write(VideoStagingsCompanion(deletedAt: Value(DateTime.now())));
      },
    ),
  );

  Future<void> validateReferences(
    DirectorDocument document, {
    DirectorDocument? previous,
  }) async {
    final previousAssets = {
      for (final item in [...?previous?.objects])
        if (item['asset_id'] != null) item['id']: item['asset_id'],
    };
    for (final item in document.objects) {
      if (item['asset_id'] != null &&
          previousAssets[item['id']] != item['asset_id']) {
        throw const DocumentError('asset_id', 'asset_binding_unavailable');
      }
    }
    for (final actor in document.objects) {
      final id = actor['catalog_id'];
      if (id is String) {
        if (await database.characterProfileDao.getById(id) == null) {
          throw const DocumentError('catalog_id', 'invalid_reference');
        }
      }
    }
  }

  static void applyEdit(Json document, Json edit) {
    final collection = edit['collection'];
    if (!collections.contains(collection)) {
      throw const DocumentError('collection', 'invalid');
    }
    final items = document[collection] as List;
    final op = edit['op'];
    if (!{'create', 'write', 'remove'}.contains(op) ||
        edit.keys.any(
          (key) => !{'op', 'collection', 'id', 'frame', 'data'}.contains(key),
        ) ||
        (edit['data'] != null && edit['data'] is! Map)) {
      throw const DocumentError('edit', 'invalid');
    }
    final data = Map<String, dynamic>.from(edit['data'] as Map? ?? const {});
    final id = edit['id'];
    if (edit.containsKey('frame')) {
      if (collection != 'tracks') {
        throw const DocumentError('frame', 'track_required');
      }
      final track = items
          .cast<Json>()
          .where((item) => item['id'] == id)
          .firstOrNull;
      if (track == null) {
        throw const DocumentError('track', 'not_found');
      }
      final keys = track['keys'] as List;
      final frame = edit['frame'];
      if (frame is! int || frame < 0 || data.containsKey('frame')) {
        throw const DocumentError('frame', 'invalid');
      }
      final index = keys.indexWhere((key) => key['frame'] == frame);
      if (op == 'create') {
        if (index >= 0) {
          throw const DocumentError('frame', 'duplicate');
        }
        keys.add({...data, 'frame': frame});
      } else {
        if (index < 0) {
          throw const DocumentError('frame', 'not_found');
        }
        if (op == 'remove') {
          keys.removeAt(index);
        } else if (op == 'write') {
          keys[index] = {...keys[index] as Map, ...data, 'frame': frame};
        } else {
          throw const DocumentError('op', 'invalid');
        }
      }
      keys.sort((a, b) => (a['frame'] as int).compareTo(b['frame'] as int));
      if (keys.isEmpty) {
        items.remove(track);
      }
      return;
    }
    final index = items.indexWhere((item) => item['id'] == id);
    if (op == 'create') {
      if (data.containsKey('id') || id == null || index >= 0) {
        throw const DocumentError('id', 'invalid');
      }
      items.add({...data, 'id': id});
    } else {
      if (index < 0) {
        throw const DocumentError('id', 'not_found');
      }
      if (data.containsKey('id')) {
        throw const DocumentError('id', 'immutable');
      }
      if (op == 'remove' && {'objects', 'cameras'}.contains(collection)) {
        CommandHistory.removeObject(document, id as String);
      } else if (op == 'remove') {
        items.removeAt(index);
      } else if (op == 'write') {
        items[index] = {...items[index] as Map, ...data};
      } else {
        throw const DocumentError('op', 'invalid');
      }
    }
  }
}
