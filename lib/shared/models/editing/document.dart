// 职责: 保存版本化剪辑工程与固定媒体引用，并校验帧区间、轨道角色及内容结构。
// 关联文件:
//   lib/shared/services/editing/commands.dart
//   lib/shared/database/type_converters.dart
import 'dart:math' as math;

const editingFps = 24;
const editingSampleRate = 48000;
const editingSamplesPerFrame = editingSampleRate ~/ editingFps;
double editingSeconds(int frames) => frames / editingFps;
int editingFrames(int microseconds) => microseconds * editingFps ~/ 1000000;
int editingMicroseconds(int frames) => (frames * 1000000 / editingFps).round();

/// 轨道角色决定显示名、配色和能放的素材；主轨是唯一的磁吸视频轨。
abstract final class EditingRole {
  static const main = 'main';
  static const overlay = 'overlay';
  static const subtitle = 'subtitle';
  static const dialogue = 'dialogue';
  static const sfx = 'sfx';
  static const music = 'music';
  static const audio = 'audio';

  /// 普通文字轨：导出时总是烧录进画面，不参与字幕导出方式。
  static const text = 'text';
  static const byKind = {
    'video': [main, overlay],
    'audio': [dialogue, sfx, music, audio],
    'text': [subtitle, text],
  };
}

class EditingSource {
  const EditingSource({
    required this.assetId,
    required this.mediaType,
    required this.durationUs,
    this.hasAudio = false,
  });

  /// 源媒体资产；文件路径从资产读取。
  final String assetId;
  final String mediaType;
  final int durationUs;

  /// 视频是否带音轨；视频片段的原声直接从源文件混音。
  final bool hasAudio;
  Map<String, dynamic> toJson() => {
    'asset_id': assetId,
    'media_type': mediaType,
    'duration_us': durationUs,
    'has_audio': hasAudio,
  };
  factory EditingSource.fromJson(Map<String, dynamic> j) => EditingSource(
    assetId: j['asset_id'] as String,
    mediaType: j['media_type'] as String,
    durationUs: j['duration_us'] as int,
    hasAudio: j['has_audio'] as bool,
  );
}

class EditingTrack {
  const EditingTrack({
    required this.id,
    required this.kind,
    required this.role,
    required this.order,
    this.name = '',
    this.locked = false,
    this.hidden = false,
    this.muted = false,
  });
  final String id, kind, role, name;
  final int order;
  final bool locked, hidden, muted;
  bool get main => role == EditingRole.main;
  EditingTrack copyWith({
    int? order,
    String? name,
    bool? locked,
    bool? hidden,
    bool? muted,
  }) => EditingTrack(
    id: id,
    kind: kind,
    role: role,
    order: order ?? this.order,
    name: name ?? this.name,
    locked: locked ?? this.locked,
    hidden: hidden ?? this.hidden,
    muted: muted ?? this.muted,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'role': role,
    'order': order,
    'name': name,
    'locked': locked,
    'hidden': hidden,
    'muted': muted,
  };
  factory EditingTrack.fromJson(Map<String, dynamic> j) => EditingTrack(
    id: j['id'] as String,
    kind: j['kind'] as String,
    role: j['role'] as String,
    order: j['order'] as int,
    name: j['name'] as String,
    locked: j['locked'] as bool,
    hidden: j['hidden'] as bool,
    muted: j['muted'] as bool,
  );
}

/// 图层框上的锚点 (anchorX, anchorY) 落在画面的 (x, y)，坐标都按宽高归一化到 0..1。
class EditingTransform {
  const EditingTransform({
    this.scale = 1,
    this.x = .5,
    this.y = .5,
    this.anchorX = .5,
    this.anchorY = .5,
  });
  final double scale, x, y, anchorX, anchorY;
  bool samePlacement(EditingTransform other) =>
      x == other.x &&
      y == other.y &&
      anchorX == other.anchorX &&
      anchorY == other.anchorY;
  EditingTransform copyWith({
    double? scale,
    double? x,
    double? y,
    double? anchorX,
    double? anchorY,
  }) => EditingTransform(
    scale: scale ?? this.scale,
    x: x ?? this.x,
    y: y ?? this.y,
    anchorX: anchorX ?? this.anchorX,
    anchorY: anchorY ?? this.anchorY,
  );
  Map<String, dynamic> toJson() => {
    'scale': scale,
    'x': x,
    'y': y,
    'anchor_x': anchorX,
    'anchor_y': anchorY,
  };
  factory EditingTransform.fromJson(Map<String, dynamic> j) => EditingTransform(
    scale: (j['scale'] as num).toDouble(),
    x: (j['x'] as num).toDouble(),
    y: (j['y'] as num).toDouble(),
    anchorX: (j['anchor_x'] as num? ?? .5).toDouble(),
    anchorY: (j['anchor_y'] as num? ?? .5).toDouble(),
  );
}

/// 制作来源只记录身份，不参与素材解析或渲染。
class EditingOrigin {
  const EditingOrigin({required this.type, required this.id});
  final String type, id;
  Map<String, dynamic> toJson() => {'type': type, 'id': id};
  factory EditingOrigin.fromJson(Map<String, dynamic> j) =>
      EditingOrigin(type: j['type'] as String, id: j['id'] as String);
}

sealed class EditingContent {
  const EditingContent();
  String get kind;
  Map<String, dynamic> toJson();
  factory EditingContent.fromJson(Map<String, dynamic> j) =>
      switch (j['kind']) {
        'video' => EditingVideoContent.fromJson(j),
        'audio' => EditingAudioContent.fromJson(j),
        'text' => EditingTextContent.fromJson(j),
        _ => throw const FormatException('Unknown editing content kind'),
      };
}

/// 有源内容共用源时间和音量包络，视频画面与原声使用相同淡入淡出区间。
sealed class EditingSourceContent extends EditingContent {
  const EditingSourceContent({
    required this.source,
    this.sourceInUs = 0,
    this.gainDb = 0,
    this.fadeInFrames = 0,
    this.fadeOutFrames = 0,
  });
  final EditingSource source;
  final int sourceInUs, fadeInFrames, fadeOutFrames;
  final double gainDb;
  int sourceUsAt(int offsetFrames) =>
      sourceInUs + editingMicroseconds(offsetFrames);
  EditingSourceContent copyWith({
    EditingSource? source,
    int? sourceInUs,
    double? gainDb,
    int? fadeInFrames,
    int? fadeOutFrames,
  });
  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'source': source.toJson(),
    'source_in_us': sourceInUs,
    'gain_db': gainDb,
    'fade_in_frames': fadeInFrames,
    'fade_out_frames': fadeOutFrames,
  };
}

final class EditingVideoContent extends EditingSourceContent {
  const EditingVideoContent({
    required super.source,
    super.sourceInUs,
    super.gainDb,
    super.fadeInFrames,
    super.fadeOutFrames,
    this.transform = const EditingTransform(),
    this.opacity = 1,
    this.audioDetached = false,
  });
  final EditingTransform transform;
  final double opacity;
  final bool audioDetached;
  @override
  String get kind => 'video';
  @override
  EditingVideoContent copyWith({
    EditingSource? source,
    int? sourceInUs,
    double? gainDb,
    int? fadeInFrames,
    int? fadeOutFrames,
    EditingTransform? transform,
    double? opacity,
    bool? audioDetached,
  }) => EditingVideoContent(
    source: source ?? this.source,
    sourceInUs: sourceInUs ?? this.sourceInUs,
    gainDb: gainDb ?? this.gainDb,
    fadeInFrames: fadeInFrames ?? this.fadeInFrames,
    fadeOutFrames: fadeOutFrames ?? this.fadeOutFrames,
    transform: transform ?? this.transform,
    opacity: opacity ?? this.opacity,
    audioDetached: audioDetached ?? this.audioDetached,
  );
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'transform': transform.toJson(),
    'opacity': opacity,
    'audio_detached': audioDetached,
  };
  factory EditingVideoContent.fromJson(Map<String, dynamic> j) =>
      EditingVideoContent(
        source: EditingSource.fromJson(j['source'] as Map<String, dynamic>),
        sourceInUs: j['source_in_us'] as int,
        gainDb: (j['gain_db'] as num).toDouble(),
        fadeInFrames: j['fade_in_frames'] as int,
        fadeOutFrames: j['fade_out_frames'] as int,
        transform: EditingTransform.fromJson(
          j['transform'] as Map<String, dynamic>,
        ),
        opacity: (j['opacity'] as num).toDouble(),
        audioDetached: j['audio_detached'] as bool,
      );
}

final class EditingAudioContent extends EditingSourceContent {
  const EditingAudioContent({
    required super.source,
    super.sourceInUs,
    super.gainDb,
    super.fadeInFrames,
    super.fadeOutFrames,
  });
  @override
  String get kind => 'audio';
  @override
  EditingAudioContent copyWith({
    EditingSource? source,
    int? sourceInUs,
    double? gainDb,
    int? fadeInFrames,
    int? fadeOutFrames,
  }) => EditingAudioContent(
    source: source ?? this.source,
    sourceInUs: sourceInUs ?? this.sourceInUs,
    gainDb: gainDb ?? this.gainDb,
    fadeInFrames: fadeInFrames ?? this.fadeInFrames,
    fadeOutFrames: fadeOutFrames ?? this.fadeOutFrames,
  );
  factory EditingAudioContent.fromJson(Map<String, dynamic> j) =>
      EditingAudioContent(
        source: EditingSource.fromJson(j['source'] as Map<String, dynamic>),
        sourceInUs: j['source_in_us'] as int,
        gainDb: (j['gain_db'] as num).toDouble(),
        fadeInFrames: j['fade_in_frames'] as int,
        fadeOutFrames: j['fade_out_frames'] as int,
      );
}

final class EditingTextContent extends EditingContent {
  const EditingTextContent({
    required this.text,
    this.style = 'subtitle',
    this.transform = bottom,
    this.opacity = 1,
  });
  static const styles = ['subtitle', 'title'];

  /// 底部居中，文字块下沿留出 9% 边距。
  static const bottom = EditingTransform(y: .91, anchorY: 1);
  final String text, style;

  /// scale 是相对样式基准字号的倍数；多行文字按 anchorX 对齐。
  final EditingTransform transform;
  final double opacity;
  @override
  String get kind => 'text';
  EditingTextContent copyWith({
    String? text,
    String? style,
    EditingTransform? transform,
    double? opacity,
  }) => EditingTextContent(
    text: text ?? this.text,
    style: style ?? this.style,
    transform: transform ?? this.transform,
    opacity: opacity ?? this.opacity,
  );
  @override
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'text': text,
    'style': style,
    'transform': transform.toJson(),
    'opacity': opacity,
  };
  factory EditingTextContent.fromJson(Map<String, dynamic> j) =>
      EditingTextContent(
        text: j['text'] as String,
        style: j['style'] as String,
        transform: j['transform'] == null
            // 早期工程只存 top/center/bottom，按当时的版面换算成等价锚点。
            ? switch (j['position']) {
                'top' => const EditingTransform(y: .09, anchorY: 0),
                'center' => const EditingTransform(),
                _ => bottom,
              }
            : EditingTransform.fromJson(j['transform'] as Map<String, dynamic>),
        opacity: (j['opacity'] as num? ?? 1).toDouble(),
      );
}

const _keepOrigin = Object();

class EditingClip {
  const EditingClip({
    required this.id,
    required this.trackId,
    required this.startFrame,
    required this.durationFrames,
    required this.content,
    this.name = '',
    this.origin,
  });
  final String id, trackId, name;
  final int startFrame, durationFrames;
  final EditingOrigin? origin;
  final EditingContent content;
  int get endFrame => startFrame + durationFrames;
  EditingSourceContent? get media => switch (content) {
    EditingSourceContent media => media,
    EditingTextContent() => null,
  };
  int? get sourceEndUs => media?.sourceUsAt(durationFrames);
  EditingClip copyWith({
    String? id,
    String? trackId,
    String? name,
    int? startFrame,
    int? durationFrames,
    EditingContent? content,
    Object? origin = _keepOrigin,
  }) => EditingClip(
    id: id ?? this.id,
    trackId: trackId ?? this.trackId,
    name: name ?? this.name,
    startFrame: startFrame ?? this.startFrame,
    durationFrames: durationFrames ?? this.durationFrames,
    content: content ?? this.content,
    origin: identical(origin, _keepOrigin)
        ? this.origin
        : origin as EditingOrigin?,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'track_id': trackId,
    'name': name,
    'start_frame': startFrame,
    'duration_frames': durationFrames,
    'origin': origin?.toJson(),
    'content': content.toJson(),
  };
  factory EditingClip.fromJson(Map<String, dynamic> j) => EditingClip(
    id: j['id'] as String,
    trackId: j['track_id'] as String,
    name: j['name'] as String,
    startFrame: j['start_frame'] as int,
    durationFrames: j['duration_frames'] as int,
    origin: j['origin'] == null
        ? null
        : EditingOrigin.fromJson(j['origin'] as Map<String, dynamic>),
    content: EditingContent.fromJson(j['content'] as Map<String, dynamic>),
  );
}

class EditingDocument {
  EditingDocument({
    required this.ratio,
    required List<EditingTrack> tracks,
    required List<EditingClip> clips,
  }) : tracks = List.unmodifiable(tracks),
       clips = List.unmodifiable(clips);
  final String ratio;
  final List<EditingTrack> tracks;
  final List<EditingClip> clips;
  int get totalFrames => clips.fold(0, (n, c) => math.max(n, c.endFrame));
  EditingTrack track(String id) => tracks.singleWhere((t) => t.id == id);
  EditingTrack get mainTrack => tracks.singleWhere((t) => t.main);

  /// 主轨片段按时间先后排列；磁吸保证它们从 0 起首尾相接。
  List<EditingClip> get mainClips =>
      clips.where((c) => c.trackId == mainTrack.id).toList()
        ..sort((a, b) => a.startFrame.compareTo(b.startFrame));
  EditingDocument copyWith({
    String? ratio,
    List<EditingTrack>? tracks,
    List<EditingClip>? clips,
  }) => EditingDocument(
    ratio: ratio ?? this.ratio,
    tracks: tracks ?? this.tracks,
    clips: clips ?? this.clips,
  );

  /// 自上而下：字幕 T1、叠加 V2、主轨 V1、对白 A1、音效 A2、音乐 A3。
  factory EditingDocument.empty(String ratio) => EditingDocument(
    ratio: ratio,
    tracks: const [
      EditingTrack(
        id: 'T1',
        kind: 'text',
        role: EditingRole.subtitle,
        order: 0,
      ),
      EditingTrack(
        id: 'V2',
        kind: 'video',
        role: EditingRole.overlay,
        order: 1,
      ),
      EditingTrack(id: 'V1', kind: 'video', role: EditingRole.main, order: 0),
      EditingTrack(
        id: 'A1',
        kind: 'audio',
        role: EditingRole.dialogue,
        order: 0,
      ),
      EditingTrack(id: 'A2', kind: 'audio', role: EditingRole.sfx, order: 1),
      EditingTrack(id: 'A3', kind: 'audio', role: EditingRole.music, order: 2),
    ],
    clips: const [],
  );
  Map<String, dynamic> toJson() => {
    'format': 'reveric.editing',
    'version': 1,
    'fps': editingFps,
    'ratio': ratio,
    'tracks': tracks.map((t) => t.toJson()).toList(),
    'clips': clips.map((c) => c.toJson()).toList(),
  };
  factory EditingDocument.fromJson(Map<String, dynamic> j) {
    if (j['format'] != 'reveric.editing' ||
        j['version'] != 1 ||
        j['fps'] != editingFps) {
      throw const FormatException('Unsupported editing document');
    }
    final doc = EditingDocument(
      ratio: j['ratio'] as String,
      tracks: (j['tracks'] as List)
          .map((t) => EditingTrack.fromJson(t as Map<String, dynamic>))
          .toList(),
      clips: (j['clips'] as List)
          .map((c) => EditingClip.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
    doc.validate();
    return doc;
  }
  void validate() {
    void require(bool value, String reason) {
      if (!value) {
        throw FormatException(reason);
      }
    }

    void placement(EditingTransform t, double opacity) {
      bool unit(double n) => n >= 0 && n <= 1;
      require(
        t.scale.isFinite && t.scale > 0,
        'Invalid scale ${t.scale}: must be positive',
      );
      require(
        [t.x, t.y, t.anchorX, t.anchorY].every(unit),
        'Invalid position: x, y, anchor_x and anchor_y must be within 0..1',
      );
      require(unit(opacity), 'Invalid opacity $opacity: must be within 0..1');
    }

    require(
      const ['21:9', '16:9', '4:3', '1:1', '3:4', '9:16'].contains(ratio),
      'Invalid ratio',
    );
    require(
      tracks.map((t) => t.id).toSet().length == tracks.length,
      'Duplicate track',
    );
    require(
      clips.map((c) => c.id).toSet().length == clips.length,
      'Duplicate clip',
    );
    require(
      tracks.where((t) => t.main).length == 1 && mainTrack.kind == 'video',
      'Invalid main track',
    );
    for (final kind in EditingRole.byKind.keys) {
      final orders =
          tracks.where((t) => t.kind == kind).map((t) => t.order).toList()
            ..sort();
      require(
        List.generate(orders.length, (i) => orders[i] == i).every((v) => v),
        'Invalid track order',
      );
    }
    for (final t in tracks) {
      require(t.id.isNotEmpty, 'Invalid track: id must be nonempty');
      require(
        EditingRole.byKind[t.kind]?.contains(t.role) ?? false,
        'Invalid track ${t.id}: kind ${t.kind} with role ${t.role}. '
        'Valid roles: ${EditingRole.byKind.entries.map((e) => '${e.key}: ${e.value.join('/')}').join(', ')}',
      );
      final ordered = clips.where((c) => c.trackId == t.id).toList()
        ..sort((a, b) => a.startFrame.compareTo(b.startFrame));
      for (var i = 1; i < ordered.length; i++) {
        require(
          ordered[i - 1].endFrame <= ordered[i].startFrame,
          'Overlapping clips',
        );
      }
    }
    for (final c in clips) {
      require(
        c.id.isNotEmpty && tracks.any((t) => t.id == c.trackId),
        'Missing track',
      );
      require(c.startFrame >= 0 && c.durationFrames > 0, 'Invalid interval');
      final content = c.content;
      require(content.kind == track(c.trackId).kind, 'Wrong track type');
      if (content is EditingTextContent) {
        require(
          EditingTextContent.styles.contains(content.style),
          'Invalid text style ${content.style}. '
          'Valid styles: ${EditingTextContent.styles.join(', ')}',
        );
        placement(content.transform, content.opacity);
        continue;
      }
      final media = content as EditingSourceContent;
      final source = media.source;
      require(source.assetId.isNotEmpty, 'Invalid source identity');
      require(
        media.sourceInUs >= 0 && source.durationUs >= 0,
        'Invalid source interval',
      );
      require(media.gainDb.isFinite, 'Invalid gain');
      require(
        media.fadeInFrames >= 0 &&
            media.fadeOutFrames >= 0 &&
            media.fadeInFrames + media.fadeOutFrames <= c.durationFrames,
        'Invalid fades',
      );
      require(
        source.mediaType == 'image'
            ? media.sourceInUs == 0
            : c.sourceEndUs! <= source.durationUs + 1,
        'Source interval exceeds media',
      );
      if (media is EditingVideoContent) {
        final transform = media.transform;
        require(
          ['video', 'image'].contains(source.mediaType),
          'Invalid video source',
        );
        placement(transform, media.opacity);
        require(
          !media.audioDetached ||
              (source.mediaType == 'video' && source.hasAudio),
          'Source has no audio to detach',
        );
      } else {
        require(
          source.mediaType == 'audio' ||
              (source.mediaType == 'video' && source.hasAudio),
          'Invalid audio source',
        );
      }
    }
  }
}
