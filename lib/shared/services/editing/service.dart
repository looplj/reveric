// 职责: 以修订比较保存独立剪辑工程，核验素材可读性与源区间并计算运行时缓存指纹。
// 关联文件:
//   lib/shared/models/editing/document.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/production/library_service.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
import 'dart:io';
import 'package:drift/drift.dart';
import '../../models/content_kind.dart';
import '../novel_actions.dart';
import 'package:crypto/crypto.dart';
export '../../database/novel_content_daos/editing_dao.dart'
    show EditingConflict;
import 'package:uuid/uuid.dart';
import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import '../../models/editing/document.dart';
import '../../models/production/media.dart';
import '../production/library_service.dart';
import '../production/media_file.dart';
import '../production/ffmpeg_runner.dart';
import '../storyboard/service.dart';

final _log = AppLogger.forModule('Editing');

class EditingSourceProblem implements Exception {
  const EditingSourceProblem(this.ids);
  final List<String> ids;
}

typedef EditingAdoptedClip = ({String id, String title, String? assetId});

class EditingService {
  EditingService(this.database, this.library);
  final NovelContentDatabase database;
  final MediaLibraryService library;
  Future<VideoEditingRow> read(String editingId) async {
    final editing = await database.editingDao.get(editingId);
    if (editing == null) {
      throw StateError('Editing missing');
    }
    return editing;
  }

  /// 按当前内容库登记与持有该工程的节点验证归属，不接受其他作品或游离工程。
  Future<String> canvasForEditing(String editingId) async {
    final work = await NovelActionsService(
      library.database,
    ).getNovelByContentDatabasePath(database.filePath);
    if (work == null || work.contentKind != contentKindCanvas) {
      throw StateError('Canvas editing requires a canvas work');
    }
    await read(editingId);
    final node =
        await (database.select(database.canvasNodes)..where(
              (t) =>
                  t.type.equals(canvasNodeTypeEditing) &
                  t.refType.equals(canvasNodeRefTypeEditing) &
                  t.refId.equals(editingId) &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .getSingleOrNull();
    final canvas = node == null
        ? null
        : await database.canvasDao.getCanvasById(node.canvasId);
    if (canvas == null || canvas.kind != canvasKindProduction) {
      throw StateError('Editing canvas node is missing');
    }
    return canvas.id;
  }

  Future<List<EditingAdoptedClip>> canvasAdopted(String editingId) async {
    final canvasId = await canvasForEditing(editingId);
    final nodes = database.canvasNodes, clips = database.productionClips;
    final query =
        database.select(nodes).join([
            leftOuterJoin(
              clips,
              clips.id.equalsExp(nodes.refId) &
                  clips.kind.equals('video') &
                  clips.deletedAt.equals(notDeletedSentinel),
            ),
          ])
          ..where(
            nodes.canvasId.equals(canvasId) &
                nodes.type.equals(canvasNodeTypeVideo) &
                nodes.refType.equals(canvasNodeRefTypeProductionClip) &
                nodes.deletedAt.equals(notDeletedSentinel),
          )
          ..orderBy([
            OrderingTerm.asc(nodes.createdAt),
            OrderingTerm.asc(nodes.id),
          ]);
    return [
      for (final row in await query.get())
        (
          id: row.readTableOrNull(clips)?.id ?? row.readTable(nodes).id,
          title:
              row.readTableOrNull(clips)?.title ?? row.readTable(nodes).title,
          assetId: row.readTableOrNull(clips)?.adoptedAssetId,
        ),
    ];
  }

  Stream<List<EditingAdoptedClip>> watchCanvasAdopted(String editingId) =>
      database
          .customSelect(
            'SELECT 1',
            readsFrom: {
              database.canvasNodes,
              database.canvases,
              database.productionClips,
              database.videoEditings,
            },
          )
          .watch()
          .asyncMap((_) => canvasAdopted(editingId));

  Future<(EditingDocument, List<String>)> fromCanvasAdopted(
    String editingId,
    String ratio,
  ) async => _fromAdopted(await canvasAdopted(editingId), ratio);

  Future<(EditingDocument, int)> load(String editingId) async {
    final editing = await read(editingId);
    return (editing.document, editing.revision);
  }

  Future<int> save(
    String editingId,
    EditingDocument document,
    int expectedRevision,
  ) => database.editingDao.save(
    editingId,
    document: document,
    expectedRevision: expectedRevision,
  );

  Future<EditingSource> source(
    String assetId, {
    MediaCancellation? cancellation,
  }) async {
    final media = await ProductionMediaFile.read(
      library,
      await sourcePath(assetId),
    );
    final info = await library.probePath(media.path);
    if ((media.type == 'video' && !info.hasVideo) ||
        (media.type == 'audio' && !info.hasAudio) ||
        (media.type != 'image' &&
            editingFrames(info.duration.inMicroseconds) <= 0)) {
      throw EditingSourceProblem([assetId]);
    }
    return EditingSource(
      assetId: assetId,
      mediaType: media.type,
      durationUs: info.duration.inMicroseconds,
      hasAudio: info.hasAudio,
    );
  }

  /// 源资产的相对路径；资产不存在或已删除时视为素材缺失。
  Future<String> sourcePath(String assetId) async {
    final asset = await library.database.assetDao.getAsset(assetId);
    if (asset?.path == null) {
      throw EditingSourceProblem([assetId]);
    }
    return asset!.path!;
  }

  Future<String> _hash(String path, MediaCancellation? token) async {
    Stream<List<int>> bytes() async* {
      await for (final chunk in File(library.resolvePath(path)).openRead()) {
        if (token?.cancelled ?? false) {
          throw StateError('Cancelled');
        }
        yield chunk;
      }
    }

    return (await sha256.bind(bytes()).first).toString();
  }

  Future<void> verify(EditingDocument doc, MediaCancellation token) async {
    final checked = <String, MediaInfo>{};
    final broken = <String>[];
    for (final c in doc.clips.where((c) => c.media != null)) {
      if (token.cancelled) {
        throw const MediaException(MediaFailure.cancelled);
      }
      final source = c.media!.source;
      try {
        final info = checked[source.assetId] ??= await library.media.probe(
          library.resolvePath(await sourcePath(source.assetId)),
          cancellation: token,
        );
        if ((source.mediaType == 'video' && !info.hasVideo) ||
            (source.mediaType == 'audio' && !info.hasAudio) ||
            (source.mediaType == 'image' &&
                (info.width == null || info.height == null)) ||
            (source.hasAudio && !info.hasAudio) ||
            (source.mediaType != 'image' &&
                c.sourceEndUs! > info.duration.inMicroseconds + 1)) {
          broken.add(c.id);
        }
      } catch (error, stack) {
        _log.error(
          'source verification failed clip=${c.id}',
          error: error,
          stackTrace: stack,
        );
        broken.add(c.id);
      }
    }
    if (token.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    if (broken.isNotEmpty) {
      throw EditingSourceProblem(broken);
    }
  }

  Future<Map<String, String>> fingerprints(
    EditingDocument document,
    MediaCancellation token,
  ) async {
    final ids = document.clips
        .map((c) => c.media?.source.assetId)
        .whereType<String>()
        .toSet();
    return {for (final id in ids) id: await _hash(await sourcePath(id), token)};
  }

  /// 新片段默认用整段素材；图片默认 3 秒。位置由调用方按轨道规则决定。
  static EditingClip clipFor(
    EditingSource source,
    EditingTrack track, {
    int frame = 0,
    String name = '',
    EditingOrigin? origin,
  }) => EditingClip(
    id: const Uuid().v4(),
    trackId: track.id,
    origin: origin,
    content: switch (track.kind) {
      'video' => EditingVideoContent(source: source),
      'audio' => EditingAudioContent(source: source),
      _ => throw StateError('Wrong track type'),
    },
    startFrame: frame,
    durationFrames: source.mediaType == 'image'
        ? editingFps * 3
        : editingFrames(source.durationUs),
    name: name,
  );

  /// 按成片顺序把采用结果导入主轨；未采用的片段跳过，返回跳过的片段 id。
  Future<(EditingDocument, List<String>)> fromAdopted(
    String episodeId,
    String ratio,
  ) async {
    final rows = (await StoryboardService(
      database,
    ).episodeShots(episodeId)).where((r) => r.kind == 'video').toList();
    return _fromAdopted([
      for (final row in rows)
        (id: row.id, title: row.title, assetId: row.adoptedAssetId),
    ], ratio);
  }

  Future<(EditingDocument, List<String>)> _fromAdopted(
    List<EditingAdoptedClip> rows,
    String ratio,
  ) async {
    var doc = EditingDocument.empty(ratio);
    final skipped = <String>[];
    final broken = <String>[];
    for (final row in rows) {
      if (row.assetId == null) {
        skipped.add(row.id);
        continue;
      }
      try {
        final media = await source(row.assetId!);
        if (media.mediaType != 'video') {
          throw StateError('Not video');
        }
        doc = doc.copyWith(
          clips: [
            ...doc.clips,
            clipFor(
              media,
              doc.mainTrack,
              frame: doc.totalFrames,
              name: row.title,
              origin: EditingOrigin(type: 'production_clip', id: row.id),
            ),
          ],
        );
      } catch (error, stack) {
        _log.error(
          'import failed clip=${row.id}',
          error: error,
          stackTrace: stack,
        );
        broken.add(row.id);
      }
    }
    if (broken.isNotEmpty) {
      throw EditingSourceProblem(broken);
    }
    doc.validate();
    return (doc, skipped);
  }
}
