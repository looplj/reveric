// 职责: 持有剪辑页的界面状态（播放头、吸附、右栏、替换目标）并把放素材、分割、删除等操作落成会话提交。
// 关联文件:
//   lib/desktop/features/editing/session.dart
//   lib/shared/services/editing/commands.dart
//   lib/shared/services/editing/service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
import 'package:flutter/material.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/editing/document.dart';
import '../../../shared/services/editing/commands.dart';
import '../../../shared/services/editing/service.dart';
import 'session.dart';
import 'support.dart';
import '../../../shared/database/app_database.dart' show AssetRow;

/// 素材面板里的一项：资产库资产或片段的当前采用结果。
class EditingMedia {
  const EditingMedia({
    required this.assetId,
    required this.path,
    required this.type,
    required this.name,
    this.productionClipId,
  });
  final String assetId;
  final String? productionClipId;

  /// 资产当前的相对路径，只用于缩略图。
  final String path;
  final String type, name;
}

class EditingController extends ChangeNotifier {
  EditingController(this.session);
  final EditingSession session;
  final playhead = ValueNotifier(0);

  /// 拖动时命中的吸附点（帧），时间线画虚线。
  final snapLine = ValueNotifier<int?>(null);
  bool snap = true;
  bool importing = false;
  bool _disposed = false;

  /// 预览区注册的播放／暂停，供空格快捷键调用。
  VoidCallback? togglePlay;
  bool assets = false;
  String? replaceFor;

  /// 片段源资产，由剪辑区随资产表刷新；路径和名称只在显示时从这里取。
  Map<String, AssetRow> sources = const {};

  /// 源资产的绝对路径；资产缺失时为 null。
  String? sourceFile(EditingSource source) {
    final path = sources[source.assetId]?.path;
    return path == null ? null : session.projects.library.resolvePath(path);
  }

  /// 源资产的文件名；资产缺失时为空。
  String sourceName(EditingSource source) =>
      sources[source.assetId]?.path?.split('/').last ?? '';

  EditingDocument get doc => session.document!;

  void toggleSnap() {
    snap = !snap;
    notifyListeners();
  }

  void showAssets(bool value) {
    assets = value;
    if (!value) {
      replaceFor = null;
    }
    notifyListeners();
  }

  void select(String? id) {
    session.select(id);
    if (id != null) {
      assets = false;
      replaceFor = null;
      notifyListeners();
    }
  }

  void seek(int frame) => playhead.value = frame.clamp(0, doc.totalFrames);

  void selectAndSeek(EditingClip clip) {
    select(clip.id);
    seek(clip.startFrame);
  }

  void startReplace(String id) {
    replaceFor = id;
    assets = true;
    notifyListeners();
  }

  List<int> get _cuts => {
    0,
    doc.totalFrames,
    for (final c in doc.clips) ...[c.startFrame, c.endFrame],
  }.toList()..sort();
  void previousCut() =>
      seek(_cuts.lastWhere((f) => f < playhead.value, orElse: () => 0));
  void nextCut() => seek(
    _cuts.firstWhere((f) => f > playhead.value, orElse: () => doc.totalFrames),
  );

  /// 分割对象：选中的片段；没有选中时取播放头下的主轨片段。
  EditingClip? get splitTarget {
    final frame = playhead.value;
    bool inside(EditingClip c) => frame > c.startFrame && frame < c.endFrame;
    final selected = session.selected;
    if (selected != null) {
      return inside(selected) ? selected : null;
    }
    return doc.mainClips.where(inside).firstOrNull;
  }

  void split(BuildContext context) {
    final target = splitTarget;
    if (target == null) {
      return;
    }
    editingRun(context, () {
      session.commit(EditingCommands.split(doc, target.id, playhead.value));
      editingSay(
        context,
        context.t(
          LocaleKeys.editingSplitDone,
          namedArgs: {'time': editingTimecode(playhead.value)},
        ),
      );
    });
  }

  void remove(BuildContext context) {
    final clip = session.selected;
    if (clip == null) {
      return;
    }
    editingRun(context, () {
      session.commit(EditingCommands.remove(doc, clip.id));
      session.select(null);
      if (doc.track(clip.trackId).main && doc.mainClips.isNotEmpty) {
        editingSay(
          context,
          context.t(
            LocaleKeys.editingRippleDeleted,
            namedArgs: {'seconds': editingDurationLabel(clip.durationFrames)},
          ),
        );
      }
    });
  }

  static bool accepts(EditingTrack track, String type) => switch (track.kind) {
    'video' => type == 'video' || type == 'image',
    'audio' => type == 'audio',
    _ => false,
  };

  /// 放素材：主轨插到最近的衔接点，后面的片段顺延；其他轨放在落点的空处。
  Future<void> place(
    BuildContext context,
    EditingMedia media,
    String trackId,
    int frame,
  ) async {
    final track = doc.track(trackId);
    if (track.locked) {
      editingSay(context, context.t(LocaleKeys.editingTrackLocked));
      return;
    }
    if (!accepts(track, media.type)) {
      editingSay(
        context,
        context.t(
          track.kind == 'audio'
              ? LocaleKeys.editingAudioOnly
              : track.kind == 'text'
              ? LocaleKeys.editingTextOnly
              : LocaleKeys.editingVisualOnly,
        ),
      );
      return;
    }
    final snapshot = doc;
    final source = await session.projects.source(media.assetId);
    if (!context.mounted || !identical(snapshot, session.document)) {
      return;
    }
    final clip = EditingService.clipFor(
      source,
      track,
      origin: media.productionClipId == null
          ? null
          : EditingOrigin(type: 'production_clip', id: media.productionClipId!),
      frame: frame,
      name: media.name,
    );
    if (track.main) {
      session.commit(
        EditingCommands.insertMain(
          snapshot,
          clip,
          EditingCommands.mainIndexAt(snapshot, frame),
        ),
      );
    } else {
      final occupied = snapshot.clips.any(
        (c) =>
            c.trackId == trackId && frame >= c.startFrame && frame < c.endFrame,
      );
      if (occupied) {
        editingSay(context, context.t(LocaleKeys.editingOccupied));
        return;
      }
      session.commit(EditingCommands.place(snapshot, clip));
    }
    select(clip.id);
  }

  /// 「＋」放到播放头：视频进主轨，图片进叠加，音频进第一条播放头处空着的音频轨。
  Future<void> addAtPlayhead(BuildContext context, EditingMedia media) {
    final frame = playhead.value;
    final target = switch (media.type) {
      'video' => doc.mainTrack,
      'image' =>
        doc.tracks.where((t) => t.kind == 'video' && !t.main).firstOrNull,
      _ => doc.tracks.where((t) {
        return t.kind == 'audio' &&
            !t.locked &&
            !doc.clips.any(
              (c) =>
                  c.trackId == t.id &&
                  frame >= c.startFrame &&
                  frame < c.endFrame,
            );
      }).firstOrNull,
    };
    if (target == null) {
      editingSay(context, context.t(LocaleKeys.editingNoFreeTrack));
      return Future.value();
    }
    return place(context, media, target.id, frame);
  }

  Future<void> replace(BuildContext context, EditingMedia media) async {
    final id = replaceFor;
    if (id == null) {
      return;
    }
    final snapshot = doc;
    final source = await session.projects.source(media.assetId);
    if (!context.mounted || !identical(snapshot, session.document)) {
      return;
    }
    session.commit(
      EditingCommands.replace(
        snapshot,
        id,
        source,
        origin: media.productionClipId == null
            ? null
            : EditingOrigin(
                type: 'production_clip',
                id: media.productionClipId!,
              ),
      ),
    );
    select(id);
    editingSay(
      context,
      context.t(LocaleKeys.editingReplaced, namedArgs: {'name': media.name}),
    );
  }

  Future<void> importAdopted(BuildContext context, String? episodeId) async {
    if (_disposed || importing || doc.clips.isNotEmpty) {
      return;
    }
    final snapshot = doc;
    if (snapshot.mainTrack.locked) {
      editingSay(context, context.t(LocaleKeys.editingTrackLocked));
      return;
    }
    importing = true;
    notifyListeners();
    try {
      final (imported, skipped) = episodeId == null
          ? await session.projects.fromCanvasAdopted(
              session.editingId,
              snapshot.ratio,
            )
          : await session.projects.fromAdopted(episodeId, snapshot.ratio);
      if (_disposed ||
          !context.mounted ||
          !identical(snapshot, session.document)) {
        return;
      }
      var next = snapshot;
      for (final clip in imported.mainClips) {
        next = EditingCommands.insertMain(next, clip, next.mainClips.length);
      }
      if (!identical(next, snapshot)) {
        session.commit(next);
        await session.flush();
      }
      if (!_disposed && context.mounted) {
        editingSay(
          context,
          context.t(
            skipped.isEmpty
                ? LocaleKeys.editingImported
                : LocaleKeys.editingImportedSkipped,
            namedArgs: {
              'count': '${imported.clips.length}',
              'skipped': '${skipped.length}',
            },
          ),
        );
      }
    } finally {
      importing = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  void addText(BuildContext context, EditingTrack track) =>
      editingRun(context, () {
        final frame = playhead.value;
        if (doc.clips.any(
          (c) =>
              c.trackId == track.id &&
              frame >= c.startFrame &&
              frame < c.endFrame,
        )) {
          editingSay(context, context.t(LocaleKeys.editingOccupied));
          return;
        }
        session.commit(
          EditingCommands.addText(
            doc,
            track.id,
            frame,
            context.t(LocaleKeys.editingNewSubtitle),
          ),
        );
        select(
          session.document!.clips
              .where((c) => c.trackId == track.id && c.startFrame == frame)
              .single
              .id,
        );
      });

  void changeTrack(BuildContext context, EditingTrack next) => editingRun(
    context,
    () => session.commit(EditingCommands.updateTrack(doc, next)),
  );

  void addAudioTrack(BuildContext context) => editingRun(context, () {
    session.commit(EditingCommands.addAudioTrack(doc));
  });

  @override
  void dispose() {
    _disposed = true;
    playhead.dispose();
    snapLine.dispose();
    super.dispose();
  }
}
