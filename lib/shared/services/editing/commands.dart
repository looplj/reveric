// 职责: 将剪辑操作转成经过锁定、源区间和主轨磁吸校验的不可变工程快照。
// 关联文件:
//   lib/shared/models/editing/document.dart
//   lib/desktop/features/editing/session.dart
import 'dart:math' as math;
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';
import '../../models/editing/document.dart';

abstract final class EditingCommands {
  static void _policy(EditingDocument doc) {
    doc.validate();
    var next = 0;
    for (final clip in doc.mainClips) {
      if (clip.startFrame != next) {
        throw const FormatException('Main track is not contiguous');
      }
      next = clip.endFrame;
    }
    for (final clip in doc.clips) {
      final content = clip.content;
      final (scale, max) = switch (content) {
        EditingVideoContent(:final transform) => (transform.scale, 1),
        EditingTextContent(:final transform) => (transform.scale, 2),
        EditingAudioContent() => (1.0, 1),
      };
      if (scale < .2 || scale > max) {
        throw FormatException(
          'Invalid scale $scale: ${content.kind} scale must be within .2..$max',
        );
      }
      if (content is EditingSourceContent &&
          (content.gainDb < -60 || content.gainDb > 12)) {
        throw const FormatException('Invalid gain');
      }
    }
  }

  static EditingDocument setRatio(EditingDocument doc, String ratio) {
    final next = doc.copyWith(ratio: ratio);
    _policy(next);
    return next;
  }

  static EditingDocument updateTrack(EditingDocument doc, EditingTrack track) {
    final old = doc.track(track.id);
    if (old.kind != track.kind ||
        old.role != track.role ||
        old.order != track.order) {
      throw StateError('Track identity and order cannot be updated');
    }
    if (old.locked &&
        (track.locked ||
            old.name != track.name ||
            old.hidden != track.hidden ||
            old.muted != track.muted)) {
      throw StateError('Track locked');
    }
    final next = doc.copyWith(
      tracks: [for (final t in doc.tracks) t.id == track.id ? track : t],
    );
    _policy(next);
    return next;
  }

  static EditingDocument addAudioTrack(EditingDocument doc) =>
      _addTrack(doc, 'audio', EditingRole.audio);

  static EditingDocument addTextTrack(EditingDocument doc) =>
      _addTrack(doc, 'text', EditingRole.text);

  static EditingDocument _addTrack(
    EditingDocument doc,
    String kind,
    String role,
  ) {
    final order = doc.tracks.where((t) => t.kind == kind).length;
    final next = doc.copyWith(
      tracks: [
        ...doc.tracks,
        EditingTrack(
          id: const Uuid().v4(),
          kind: kind,
          role: role,
          order: order,
        ),
      ],
    );
    _policy(next);
    return next;
  }

  static EditingDocument reorderTrack(
    EditingDocument doc,
    String id,
    int order,
  ) {
    final track = doc.track(id);
    final other = doc.tracks.singleWhere(
      (t) => t.kind == track.kind && t.order == order,
    );
    if (track.locked || other.locked) {
      throw StateError('Track locked');
    }
    if (track.main || other.main) {
      throw StateError('Main track is fixed');
    }
    final next = doc.copyWith(
      tracks: [
        for (final t in doc.tracks)
          t.id == id
              ? t.copyWith(order: order)
              : t.id == other.id
              ? t.copyWith(order: track.order)
              : t,
      ],
    );
    _policy(next);
    return next;
  }

  static EditingDocument removeTrack(EditingDocument doc, String id) {
    final removed = doc.track(id);
    if (removed.locked) {
      throw StateError('Track locked');
    }
    if (removed.main) {
      throw StateError('Main track is fixed');
    }
    final stripped = _change(
      doc,
      doc.clips.where((c) => c.trackId == id).toList(),
      [],
    );
    final next = stripped.copyWith(
      tracks: [
        for (final t in doc.tracks.where((t) => t.id != id))
          t.kind == removed.kind && t.order > removed.order
              ? t.copyWith(order: t.order - 1)
              : t,
      ],
    );
    _policy(next);
    return next;
  }

  static EditingClip _clip(EditingDocument doc, String id) =>
      doc.clips.singleWhere((c) => c.id == id);
  static bool _onMain(EditingDocument doc, EditingClip clip) =>
      doc.track(clip.trackId).main;
  static String _occupied(String trackId, EditingClip other) =>
      'Occupied: track $trackId already has clip ${other.id} at frames '
      '${other.startFrame}-${other.endFrame}.';

  static EditingDocument _change(
    EditingDocument doc,
    List<EditingClip> affected,
    List<EditingClip> replacements,
  ) {
    for (final c in [...affected, ...replacements]) {
      if (doc.track(c.trackId).locked) {
        throw StateError('Track locked');
      }
    }
    final ids = affected.map((c) => c.id).toSet();
    final next = doc.copyWith(
      clips: [...doc.clips.where((c) => !ids.contains(c.id)), ...replacements],
    );
    _policy(next);
    return next;
  }

  /// 主轨按给定顺序首尾相接重排；顺序之外的主轨片段视为删除。
  static EditingDocument _layoutMain(
    EditingDocument doc,
    List<EditingClip> ordered,
  ) {
    var frame = 0;
    final placed = <EditingClip>[];
    for (final c in ordered) {
      placed.add(c.copyWith(startFrame: frame, trackId: doc.mainTrack.id));
      frame += c.durationFrames;
    }
    return _change(doc, doc.mainClips, placed);
  }

  static List<EditingClip> _swap(
    List<EditingClip> clips,
    String id,
    List<EditingClip> replacements,
  ) => [
    for (final c in clips) ...(c.id == id ? replacements : [c]),
  ];

  /// 非主轨自由摆放，可换到同类的另一条非主轨。
  static EditingDocument move(
    EditingDocument doc,
    String id,
    int frame, {
    String? trackId,
  }) {
    final original = _clip(doc, id);
    final target = doc.track(trackId ?? original.trackId);
    if (_onMain(doc, original) ||
        target.main ||
        target.kind != doc.track(original.trackId).kind) {
      throw StateError('Wrong track type');
    }
    return _change(
      doc,
      [original],
      [original.copyWith(startFrame: frame, trackId: target.id)],
    );
  }

  /// 主轨拖动只改变先后顺序，`index` 是去掉自己后的插入位置。
  static EditingDocument reorder(EditingDocument doc, String id, int index) {
    final clip = _clip(doc, id);
    if (!_onMain(doc, clip)) {
      throw StateError('Not on main track');
    }
    final rest = doc.mainClips.where((c) => c.id != id).toList();
    rest.insert(index.clamp(0, rest.length), clip);
    return _layoutMain(doc, rest);
  }

  /// 主轨插入位置：落点之前、中点在落点左边的片段数。
  static int mainIndexAt(EditingDocument doc, int frame) {
    final main = doc.mainClips;
    final i = main.indexWhere(
      (c) => frame < c.startFrame + c.durationFrames / 2,
    );
    return i < 0 ? main.length : i;
  }

  static EditingDocument insertMain(
    EditingDocument doc,
    EditingClip clip,
    int index,
  ) {
    final main = doc.mainClips;
    main.insert(index.clamp(0, main.length), clip);
    return _layoutMain(doc, main);
  }

  /// 首尾裁切。主轨保持位置不变，后面的片段随时长变化前移或顺延。
  static EditingDocument trim(
    EditingDocument doc,
    String id,
    int start,
    int end,
  ) {
    final c = _clip(doc, id);
    final delta = start - c.startFrame;
    final duration = end - start;
    final media = c.media;
    final next = c.copyWith(
      startFrame: start,
      durationFrames: duration,
      content: media?.copyWith(
        sourceInUs: media.source.mediaType == 'image'
            ? 0
            : media.sourceUsAt(delta),
        fadeInFrames: math.min(media.fadeInFrames, math.max(0, duration)),
        fadeOutFrames: math.min(
          media.fadeOutFrames,
          math.max(0, duration - media.fadeInFrames),
        ),
      ),
    );
    return _onMain(doc, c)
        ? _layoutMain(doc, _swap(doc.mainClips, id, [next]))
        : _change(doc, [c], [next]);
  }

  static EditingDocument split(EditingDocument doc, String id, int frame) {
    final c = _clip(doc, id);
    final left = frame - c.startFrame;
    if (left <= 0 || left >= c.durationFrames) {
      throw StateError('Split outside clip');
    }
    final media = c.media;
    final parts = [
      c.copyWith(
        durationFrames: left,
        content: media?.copyWith(
          fadeInFrames: math.min(left, media.fadeInFrames),
          fadeOutFrames: 0,
        ),
      ),
      c.copyWith(
        id: const Uuid().v4(),
        startFrame: frame,
        durationFrames: c.durationFrames - left,
        content: media?.copyWith(
          sourceInUs: media.source.mediaType == 'image'
              ? 0
              : media.sourceUsAt(left),
          fadeInFrames: 0,
          fadeOutFrames: math.min(c.durationFrames - left, media.fadeOutFrames),
        ),
      ),
    ];
    return _change(doc, [c], parts);
  }

  /// 删除主轨片段时后面的片段前移补齐。
  static EditingDocument remove(EditingDocument doc, String id) {
    final c = _clip(doc, id);
    return _onMain(doc, c)
        ? _layoutMain(doc, _swap(doc.mainClips, id, []))
        : _change(doc, [c], []);
  }

  /// 未手动定位的视频画面：满幅居中，缩小后贴右上角留 6% 边距。
  static EditingTransform autoPlacement(double scale) => scale < 1
      ? EditingTransform(scale: scale, x: .94, y: .06, anchorX: 1, anchorY: 0)
      : EditingTransform(scale: scale);

  /// 视频图层框占画面的 scale 比例，锚点写法不同但框重合即视为同一位置。
  static bool _sameBox(EditingTransform a, EditingTransform b) {
    bool near(double p, double q) => (p - q).abs() < 1e-9;
    return near(a.scale, b.scale) &&
        near(a.x - a.anchorX * a.scale, b.x - b.anchorX * b.scale) &&
        near(a.y - a.anchorY * a.scale, b.y - b.anchorY * b.scale);
  }

  static EditingDocument update(EditingDocument doc, EditingClip clip) {
    final old = _clip(doc, clip.id);
    final content = clip.content;
    final previous = old.content;
    if (content is EditingVideoContent && previous is EditingVideoContent) {
      final next = content.transform;
      final before = previous.transform;
      // 只改缩放时，自动摆放的画面跟着重新摆放；手动定位过的保持锚点不动。
      if (next.scale != before.scale &&
          next.samePlacement(before) &&
          _sameBox(before, autoPlacement(before.scale))) {
        clip = clip.copyWith(
          content: content.copyWith(transform: autoPlacement(next.scale)),
        );
      }
    }
    return _onMain(doc, old)
        ? _layoutMain(doc, _swap(doc.mainClips, clip.id, [clip]))
        : _change(doc, [old], [clip]);
  }

  /// 在非主轨的空处放片段，时长截到下一个片段开头。
  static EditingDocument place(EditingDocument doc, EditingClip clip) {
    final track = doc.track(clip.trackId);
    if (track.main) {
      throw StateError('Use insertMain');
    }
    final others = doc.clips.where((c) => c.trackId == track.id);
    final blocker = others.firstWhereOrNull(
      (c) => clip.startFrame >= c.startFrame && clip.startFrame < c.endFrame,
    );
    if (blocker != null) {
      throw StateError(_occupied(track.id, blocker));
    }
    final next = others
        .where((c) => c.startFrame > clip.startFrame)
        .fold<int?>(
          null,
          (n, c) => n == null ? c.startFrame : math.min(n, c.startFrame),
        );
    return _change(doc, [], [
      clip.copyWith(
        durationFrames: next == null
            ? clip.durationFrames
            : math.min(clip.durationFrames, next - clip.startFrame),
      ),
    ]);
  }

  static EditingDocument addText(
    EditingDocument doc,
    String trackId,
    int frame,
    String text,
  ) => place(
    doc,
    EditingClip(
      id: const Uuid().v4(),
      trackId: trackId,
      startFrame: frame,
      durationFrames: editingFps * 3,
      content: EditingTextContent(text: text),
    ),
  );

  /// 替换素材：从源头开始取，时长不超过原片段和新素材。
  static EditingDocument replace(
    EditingDocument doc,
    String id,
    EditingSource source, {
    EditingOrigin? origin,
  }) {
    final c = _clip(doc, id);
    final media = c.media;
    if (media == null) {
      throw StateError('Text clip');
    }
    var content = media.copyWith(
      source: source,
      sourceInUs: 0,
      fadeInFrames: 0,
      fadeOutFrames: 0,
    );
    if (content is EditingVideoContent) {
      content = content.copyWith(
        audioDetached:
            content.audioDetached &&
            source.mediaType == 'video' &&
            source.hasAudio,
      );
    }
    return update(
      doc,
      c.copyWith(
        content: content,
        origin: origin,
        durationFrames: source.mediaType == 'image'
            ? c.durationFrames
            : math.min(c.durationFrames, editingFrames(source.durationUs)),
      ),
    );
  }

  /// 原声按原区间分离；自动安置只使用对白和普通音频轨，必要时新建轨道。
  static EditingDocument extractAudio(
    EditingDocument doc,
    String clipId, {
    String? trackId,
  }) {
    final clip = _clip(doc, clipId);
    final content = clip.content;
    if (content is! EditingVideoContent ||
        content.source.mediaType != 'video' ||
        !content.source.hasAudio) {
      throw StateError('Video source has no audio');
    }
    if (content.audioDetached) {
      throw StateError('Audio already detached');
    }
    if (doc.track(clip.trackId).locked) {
      throw StateError('Track locked');
    }
    EditingClip? blocker(EditingTrack track) => doc.clips.firstWhereOrNull(
      (c) =>
          c.trackId == track.id &&
          c.startFrame < clip.endFrame &&
          c.endFrame > clip.startFrame,
    );
    bool free(EditingTrack track) => blocker(track) == null;
    EditingTrack? target;
    if (trackId != null) {
      target = doc.track(trackId);
      if (target.kind != 'audio') {
        throw StateError('Wrong track type');
      }
      if (target.locked) {
        throw StateError('Track locked');
      }
      if (blocker(target) case final other?) {
        throw StateError(_occupied(target.id, other));
      }
    } else {
      final candidates =
          doc.tracks
              .where(
                (t) =>
                    t.kind == 'audio' &&
                    !t.locked &&
                    !t.hidden &&
                    !t.muted &&
                    [EditingRole.dialogue, EditingRole.audio].contains(t.role),
              )
              .toList()
            ..sort((a, b) {
              final role = (a.role == EditingRole.dialogue ? 0 : 1).compareTo(
                b.role == EditingRole.dialogue ? 0 : 1,
              );
              return role == 0 ? a.order.compareTo(b.order) : role;
            });
      target = candidates.where(free).firstOrNull;
      if (target == null) {
        doc = addAudioTrack(doc);
        target = doc.tracks.last;
      }
    }
    return _change(
      doc,
      [clip],
      [
        clip.copyWith(content: content.copyWith(audioDetached: true)),
        EditingClip(
          id: const Uuid().v4(),
          trackId: target.id,
          name: clip.name,
          startFrame: clip.startFrame,
          durationFrames: clip.durationFrames,
          origin: clip.origin,
          content: EditingAudioContent(
            source: content.source,
            sourceInUs: content.sourceInUs,
            gainDb: content.gainDb,
            fadeInFrames: content.fadeInFrames,
            fadeOutFrames: content.fadeOutFrames,
          ),
        ),
      ],
    );
  }

  static int snap(
    EditingDocument doc,
    int frame,
    double pixelsPerFrame,
    int playhead, {
    Set<String> excluding = const {},
  }) {
    final targets = [
      0,
      playhead,
      for (final c in doc.clips.where((c) => !excluding.contains(c.id))) ...[
        c.startFrame,
        c.endFrame,
      ],
    ];
    final closest = targets.reduce(
      (a, b) => (a - frame).abs() <= (b - frame).abs() ? a : b,
    );
    return (closest - frame).abs() * pixelsPerFrame <= 8 ? closest : frame;
  }
}
