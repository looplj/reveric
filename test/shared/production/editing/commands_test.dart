// 职责: 验证剪辑命令的帧区间、主轨磁吸、文字片段、锁定、SRT 与缓存失效合同。
// 关联文件:
//   lib/shared/services/editing/commands.dart
//   lib/shared/services/editing/render_service.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/editing/disk_space.dart';
import 'package:reveric/shared/models/editing/document.dart';
import 'package:reveric/shared/services/editing/commands.dart';
import 'package:reveric/shared/services/editing/render_service.dart';
import 'package:reveric/shared/database/type_converters.dart';

const videoSource = EditingSource(
  assetId: 'media/video.mp4',
  mediaType: 'video',
  durationUs: 10000000,
  hasAudio: true,
);
const audioSource = EditingSource(
  assetId: 'media/music.wav',
  mediaType: 'audio',
  durationUs: 20000000,
);

/// 主轨三段（0–96–216–336），音乐轨一段，字幕一条。
EditingDocument fixture() => EditingDocument.empty('16:9').copyWith(
  clips: const [
    EditingClip(
      id: 'm1',
      trackId: 'V1',
      startFrame: 0,
      durationFrames: 96,
      content: EditingVideoContent(source: videoSource),
    ),
    EditingClip(
      id: 'm2',
      trackId: 'V1',
      startFrame: 96,
      durationFrames: 120,
      content: EditingVideoContent(source: videoSource, sourceInUs: 1000000),
    ),
    EditingClip(
      id: 'm3',
      trackId: 'V1',
      startFrame: 216,
      durationFrames: 120,
      content: EditingVideoContent(source: videoSource),
    ),
    EditingClip(
      id: 'music',
      trackId: 'A3',
      startFrame: 24,
      durationFrames: 240,
      content: EditingAudioContent(source: audioSource),
    ),
    EditingClip(
      id: 'sub',
      trackId: 'T1',
      startFrame: 48,
      durationFrames: 48,
      content: EditingTextContent(text: '开船了'),
    ),
  ],
);

List<(String, int, int)> mainLayout(EditingDocument doc) => [
  for (final c in doc.mainClips) (c.id, c.startFrame, c.durationFrames),
];

void main() {
  test(
    'native capacity query returns available bytes without ABI overflow',
    () {
      expect(
        editingFreeBytes(Directory.systemTemp.path),
        greaterThan(1024 * 1024),
      );
    },
  );
  test(
    'reading accepts main gaps; commands enforce policy and text source type',
    () {
      final doc = fixture();
      doc.validate();
      final gapped = doc.copyWith(
        clips: [
          for (final c in doc.clips)
            c.id == 'm1' ? c.copyWith(durationFrames: 90) : c,
        ],
      );
      expect(() => EditingDocument.fromJson(gapped.toJson()), returnsNormally);
      expect(
        () => EditingCommands.setRatio(gapped, '9:16'),
        throwsFormatException,
      );
      expect(
        () => EditingCommands.updateTrack(
          gapped,
          gapped.track('A1').copyWith(name: 'voice'),
        ),
        throwsFormatException,
      );
      expect(
        () => doc
            .copyWith(
              clips: [
                ...doc.clips,
                const EditingClip(
                  id: 'bad',
                  trackId: 'T1',
                  startFrame: 200,
                  durationFrames: 24,
                  content: EditingVideoContent(source: videoSource),
                ),
              ],
            )
            .validate(),
        throwsFormatException,
      );
    },
  );
  test('removing or trimming a main clip closes up the following clips', () {
    final removed = EditingCommands.remove(fixture(), 'm2');
    expect(mainLayout(removed), [('m1', 0, 96), ('m3', 96, 120)]);
    // Left trim keeps the clip in place and advances its source in-point.
    final trimmed = EditingCommands.trim(removed, 'm3', 96 + 24, 96 + 120);
    expect(mainLayout(trimmed), [('m1', 0, 96), ('m3', 96, 96)]);
    expect(
      trimmed.clips.singleWhere((c) => c.id == 'm3').media!.sourceInUs,
      1000000,
    );
    // Free tracks are untouched by main-track ripples.
    expect(trimmed.clips.singleWhere((c) => c.id == 'music').startFrame, 24);
  });
  test('reorder and insert keep the main track contiguous', () {
    final reordered = EditingCommands.reorder(fixture(), 'm3', 0);
    expect(mainLayout(reordered), [
      ('m3', 0, 120),
      ('m1', 120, 96),
      ('m2', 216, 120),
    ]);
    final doc = fixture();
    final index = EditingCommands.mainIndexAt(doc, 100);
    expect(index, 1);
    final inserted = EditingCommands.insertMain(
      doc,
      const EditingClip(
        id: 'new',
        trackId: 'V1',
        startFrame: 0,
        durationFrames: 24,
        content: EditingVideoContent(source: videoSource),
      ),
      index,
    );
    expect(mainLayout(inserted).map((e) => e.$1), ['m1', 'new', 'm2', 'm3']);
    expect(inserted.totalFrames, 360);
  });
  test('split keeps the exact source interval on both halves', () {
    final next = EditingCommands.split(fixture(), 'm2', 97);
    final halves = next.mainClips.where((c) => c.startFrame >= 96).toList();
    expect(halves[0].durationFrames, 1);
    expect(halves[1].startFrame, 97);
    expect(halves[1].media!.sourceInUs, 1000000 + 41667);
    expect(next.totalFrames, fixture().totalFrames);
  });
  test('place trims to the next clip and refuses occupied frames', () {
    final doc = fixture();
    final placed = EditingCommands.place(
      doc,
      const EditingClip(
        id: 'early',
        trackId: 'A3',
        startFrame: 0,
        durationFrames: 240,
        content: EditingAudioContent(source: audioSource),
      ),
    );
    expect(placed.clips.singleWhere((c) => c.id == 'early').durationFrames, 24);
    expect(() => EditingCommands.addText(doc, 'T1', 60, 'x'), throwsStateError);
    final text = EditingCommands.addText(doc, 'T1', 0, '标题');
    expect(
      text.clips
          .singleWhere(
            (c) => c.startFrame == 0 && c.content is EditingTextContent,
          )
          .endFrame,
      48,
    );
  });
  test('locked tracks, main-track moves and source overflow reject edits', () {
    final doc = fixture();
    final locked = doc.copyWith(
      tracks: [
        for (final t in doc.tracks) t.id == 'V1' ? t.copyWith(locked: true) : t,
      ],
    );
    expect(() => EditingCommands.remove(locked, 'm1'), throwsStateError);
    expect(() => EditingCommands.move(doc, 'm1', 24), throwsStateError);
    expect(
      () => EditingCommands.move(doc, 'music', 24, trackId: 'V2'),
      throwsStateError,
    );
    expect(
      () => EditingCommands.trim(doc, 'm1', 0, 241),
      throwsFormatException,
    );
    expect(() => EditingCommands.split(doc, 'm1', 96), throwsStateError);
    expect(() => EditingCommands.removeTrack(doc, 'V1'), throwsStateError);
  });
  test('replace starts from the new source and keeps the duration', () {
    const short = EditingSource(
      assetId: 'media/short.mp4',
      mediaType: 'video',
      durationUs: 2000000,
    );
    final next = EditingCommands.replace(fixture(), 'm2', short);
    expect(mainLayout(next), [('m1', 0, 96), ('m2', 96, 48), ('m3', 144, 120)]);
    expect(next.clips.singleWhere((c) => c.id == 'm2').media!.sourceInUs, 0);
  });
  test('converter preserves editing document and refuses unknown format', () {
    const converter = EditingDocumentConverter();
    final doc = fixture();
    expect(converter.fromSql(converter.toSql(doc)).toJson(), doc.toJson());
    expect(
      () => converter.fromSql(
        converter.toSql(doc).replaceFirst('"version":1', '"version":2'),
      ),
      throwsFormatException,
    );
  });
  test('SRT holds subtitle-style text only; titles stay burned in', () {
    final doc = EditingCommands.addText(fixture(), 'T1', 0, '片名');
    final withTitle = EditingCommands.update(
      doc,
      doc.clips
          .singleWhere(
            (c) =>
                c.content is EditingTextContent &&
                (c.content as EditingTextContent).text == '片名',
          )
          .copyWith(
            content: const EditingTextContent(text: '片名', style: 'title'),
          ),
    );
    expect(
      EditingRenderService.srt(withTitle),
      '1\n00:00:02,000 --> 00:00:04,000\n开船了\n',
    );
    final title = withTitle.clips.singleWhere(
      (c) =>
          c.content is EditingTextContent &&
          (c.content as EditingTextContent).text == '片名',
    );
    final subtitle = withTitle.clips.singleWhere(
      (c) =>
          c.content is EditingTextContent &&
          (c.content as EditingTextContent).text == '开船了',
    );
    final t1 = withTitle.track('T1');
    expect(EditingRenderService.burns(t1, title, EditingSubtitles.srt), isTrue);
    expect(
      EditingRenderService.burns(t1, subtitle, EditingSubtitles.srt),
      isFalse,
    );
    expect(
      EditingRenderService.burns(t1, title, EditingSubtitles.none),
      isFalse,
    );
  });

  test('text tracks stack freely, always burn and stay out of SRT', () {
    var doc = EditingCommands.addTextTrack(fixture());
    doc = EditingCommands.addTextTrack(doc);
    final added = doc.tracks.where((t) => t.role == EditingRole.text).toList();
    expect(added.map((t) => (t.kind, t.order)), [('text', 1), ('text', 2)]);
    doc = EditingCommands.addText(doc, added.first.id, 48, 'LOGO');
    doc = EditingCommands.addText(doc, added.last.id, 48, '第一集');
    final logo = doc.clips.singleWhere((c) => c.trackId == added.first.id);
    for (final mode in [
      EditingSubtitles.burn,
      EditingSubtitles.srt,
      EditingSubtitles.none,
    ]) {
      expect(EditingRenderService.burns(added.first, logo, mode), isTrue);
    }
    expect(EditingRenderService.srt(doc), EditingRenderService.srt(fixture()));
    expect(
      EditingRenderService.cacheKey(doc, 48, 48, (854, 480)),
      isNot(
        EditingRenderService.cacheKey(
          doc.copyWith(
            tracks: [
              for (final t in doc.tracks)
                t.id == added.first.id
                    ? EditingTrack(
                        id: t.id,
                        kind: t.kind,
                        role: EditingRole.subtitle,
                        order: t.order,
                      )
                    : t,
            ],
          ),
          48,
          48,
          (854, 480),
        ),
      ),
    );
    final removed = EditingCommands.removeTrack(doc, added.first.id);
    expect(removed.clips.where((c) => c.id == logo.id), isEmpty);
    expect(removed.tracks.singleWhere((t) => t.id == added.last.id).order, 1);
  });

  test(
    'text placement keeps scale, opacity and anchors within product range',
    () {
      final doc = fixture();
      final sub = doc.clips.singleWhere((c) => c.id == 'sub');
      final content = sub.content as EditingTextContent;
      EditingDocument update(EditingTextContent next) =>
          EditingCommands.update(doc, sub.copyWith(content: next));
      const corner = EditingTransform(
        scale: 2,
        x: .96,
        y: .04,
        anchorX: 1,
        anchorY: 0,
      );
      final placed = update(content.copyWith(transform: corner, opacity: .5));
      expect(placed.clips.singleWhere((c) => c.id == 'sub').content.toJson(), {
        'kind': 'text',
        'text': '开船了',
        'style': 'subtitle',
        'transform': corner.toJson(),
        'opacity': .5,
      });
      expect(
        () => update(
          content.copyWith(transform: content.transform.copyWith(scale: 2.5)),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('.2..2'),
          ),
        ),
      );
      for (final invalid in [
        content.copyWith(transform: corner.copyWith(anchorX: 1.5)),
        content.copyWith(transform: corner.copyWith(y: -.1)),
        content.copyWith(opacity: 1.2),
      ]) {
        expect(() => update(invalid), throwsFormatException);
      }
      expect(
        () => update(content.copyWith(style: 'caption')),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('subtitle, title'),
          ),
        ),
      );
    },
  );

  test(
    'legacy text positions and centred transforms read as equivalent anchors',
    () {
      final json = fixture().toJson();
      final clips = json['clips'] as List;
      final video = (clips.first as Map)['content'] as Map;
      video['transform'] = {'scale': .4, 'x': .74, 'y': .26};
      final text = (clips.last as Map)['content'] as Map;
      final expected = {
        'top': const EditingTransform(y: .09, anchorY: 0),
        'center': const EditingTransform(),
        'bottom': EditingTextContent.bottom,
      };
      for (final MapEntry(key: position, value: transform)
          in expected.entries) {
        text
          ..clear()
          ..addAll(<String, dynamic>{
            'kind': 'text',
            'text': '旧字幕',
            'style': 'subtitle',
            'position': position,
          });
        final doc = EditingDocument.fromJson(Map<String, dynamic>.from(json));
        final content = doc.clips.last.content as EditingTextContent;
        expect(content.transform.toJson(), transform.toJson());
        expect(content.opacity, 1);
        expect(content.toJson().containsKey('position'), isFalse);
        final old =
            (doc.mainClips.first.content as EditingVideoContent).transform;
        expect((old.anchorX, old.anchorY), (.5, .5));
        // 旧版自动摆放的右上角画面，换缩放后仍按自动规则重新摆放。
        final resized = EditingCommands.update(
          doc,
          doc.mainClips.first.copyWith(
            content: (doc.mainClips.first.content as EditingVideoContent)
                .copyWith(transform: old.copyWith(scale: .6)),
          ),
        );
        expect(
          (resized.mainClips.first.content as EditingVideoContent).transform
              .toJson(),
          EditingCommands.autoPlacement(.6).toJson(),
        );
      }
    },
  );
  test(
    'cache keys ignore track locks and names, invalidate changed interval only',
    () {
      final doc = fixture();
      final key = EditingRenderService.cacheKey(doc, 0, 96, (854, 480));
      final named = doc.copyWith(
        tracks: [
          for (final t in doc.tracks) t.copyWith(name: 'new', locked: true),
        ],
      );
      expect(EditingRenderService.cacheKey(named, 0, 96, (854, 480)), key);
      final changed = EditingCommands.update(
        doc,
        doc.clips
            .singleWhere((c) => c.id == 'm3')
            .copyWith(
              content: const EditingVideoContent(
                source: videoSource,
                gainDb: -6,
              ),
            ),
      );
      expect(EditingRenderService.cacheKey(changed, 0, 96, (854, 480)), key);
      expect(
        EditingRenderService.cacheKey(changed, 240, 96, (854, 480)),
        isNot(EditingRenderService.cacheKey(doc, 240, 96, (854, 480))),
      );
      expect(
        EditingRenderService.cacheKey(doc, 0, 96, (
          854,
          480,
        ), subtitles: EditingSubtitles.none),
        isNot(key),
      );
    },
  );
  test('preview invalidates only the streams affected by video edits', () {
    final doc = fixture();
    final clip = doc.mainClips.first;
    final video = clip.content as EditingVideoContent;
    String key(EditingDocument project, EditingRenderPart part) =>
        EditingRenderService.cacheKey(project, 0, 96, (854, 480), part: part);
    for (final (change, redraw, remix) in [
      (video.copyWith(gainDb: -10), false, true),
      (video.copyWith(audioDetached: true), false, true),
      (video.copyWith(opacity: .5), true, false),
      (video.copyWith(fadeOutFrames: 12), true, true),
    ]) {
      final edited = EditingCommands.update(
        doc,
        clip.copyWith(content: change),
      );
      expect(
        key(edited, EditingRenderPart.video) !=
            key(doc, EditingRenderPart.video),
        redraw,
      );
      expect(
        key(edited, EditingRenderPart.audio) !=
            key(doc, EditingRenderPart.audio),
        remix,
      );
    }
  });
  test('source endpoints preserve microsecond rounding tolerance', () {
    const source = EditingSource(
      assetId: 'boundary',
      mediaType: 'video',
      durationUs: 83333,
    );
    final doc = EditingDocument.empty('16:9').copyWith(
      clips: const [
        EditingClip(
          id: 'boundary',
          trackId: 'V1',
          startFrame: 0,
          durationFrames: 2,
          content: EditingVideoContent(source: source),
        ),
      ],
    );
    final split = EditingCommands.split(doc, 'boundary', 1);
    expect(split.mainClips.last.media!.sourceInUs, 41667);
    expect(split.mainClips.last.sourceEndUs, 83334);
    expect(() => split.validate(), returnsNormally);
    final last = split.mainClips.last;
    final beyond = split.copyWith(
      clips: [
        split.mainClips.first,
        last.copyWith(content: last.media!.copyWith(sourceInUs: 41668)),
      ],
    );
    expect(() => beyond.validate(), throwsFormatException);
    expect(editingSeconds(24), 1);
    expect(editingSamplesPerFrame, 2000);
  });

  test('content schema is snake_case and rejects unknown or old content', () {
    final doc = fixture();
    final json = doc.toJson();
    final clip = (json['clips'] as List).first as Map<String, dynamic>;
    expect(
      clip.keys,
      containsAll([
        'track_id',
        'start_frame',
        'duration_frames',
        'content',
        'origin',
      ]),
    );
    expect(clip.containsKey('source'), isFalse);
    final content = clip['content'] as Map<String, dynamic>;
    expect(content['kind'], 'video');
    expect(content['audio_detached'], false);
    expect((content['source'] as Map)['asset_id'], videoSource.assetId);
    final text = doc.clips.last.content.toJson();
    expect(text.keys.toSet(), {
      'kind',
      'text',
      'style',
      'transform',
      'opacity',
    });
    expect(EditingDocument.fromJson(json).toJson(), json);
    expect(EditingDocument.fromJson(json).clips.first.origin, isNull);
    content['kind'] = 'future';
    expect(() => EditingDocument.fromJson(json), throwsFormatException);
    expect(
      () => EditingClip.fromJson({'id': 'old', 'trackId': 'V1'}),
      throwsA(isA<TypeError>()),
    );
  });

  test('reading accepts product limits while commands reject them', () {
    final doc = fixture();
    final first = doc.mainClips.first;
    for (final content in [
      first.media!.copyWith(gainDb: 13),
      (first.content as EditingVideoContent).copyWith(
        transform: const EditingTransform(scale: 1.5),
      ),
    ]) {
      final permissive = doc.copyWith(
        clips: [
          for (final c in doc.clips)
            c.id == first.id ? c.copyWith(content: content) : c,
        ],
      );
      expect(
        () => EditingDocument.fromJson(permissive.toJson()),
        returnsNormally,
      );
      expect(
        () => EditingCommands.addAudioTrack(permissive),
        throwsFormatException,
      );
      expect(
        () => EditingCommands.setRatio(permissive, '9:16'),
        throwsFormatException,
      );
      expect(
        () => EditingCommands.updateTrack(
          permissive,
          permissive.track('A1').copyWith(name: 'Voice'),
        ),
        throwsFormatException,
      );
    }
    for (final transform in [
      const EditingTransform(scale: 0),
      const EditingTransform(x: double.nan),
      const EditingTransform(y: double.infinity),
    ]) {
      final invalid = doc.copyWith(
        clips: [
          first.copyWith(
            content: (first.content as EditingVideoContent).copyWith(
              transform: transform,
            ),
          ),
        ],
      );
      expect(() => invalid.validate(), throwsFormatException);
    }
  });

  test(
    'scale updates recenter the box and unrelated updates preserve its position',
    () {
      final doc = fixture();
      final clip = doc.mainClips.first;
      final video = clip.content as EditingVideoContent;
      final resized = EditingCommands.update(
        doc,
        clip.copyWith(
          content: video.copyWith(transform: const EditingTransform(scale: .4)),
        ),
      );
      final changed = resized.mainClips.first;
      final transform = (changed.content as EditingVideoContent).transform;
      expect(transform.toJson(), {
        'scale': .4,
        'x': .94,
        'y': .06,
        'anchor_x': 1.0,
        'anchor_y': 0.0,
      });
      final renamed = EditingCommands.update(
        resized,
        changed.copyWith(name: 'Name'),
      );
      expect(
        (renamed.mainClips.first.content as EditingVideoContent).transform,
        same(transform),
      );
      final full = EditingCommands.update(
        renamed,
        renamed.mainClips.first.copyWith(content: video),
      );
      expect(
        (full.mainClips.first.content as EditingVideoContent).transform
            .toJson(),
        {'scale': 1.0, 'x': .5, 'y': .5, 'anchor_x': .5, 'anchor_y': .5},
      );
      final placed = EditingCommands.update(
        full,
        full.mainClips.first.copyWith(
          content: video.copyWith(
            transform: const EditingTransform(
              scale: .5,
              x: .1,
              y: .9,
              anchorX: 0,
              anchorY: 1,
            ),
          ),
        ),
      );
      final manual = placed.mainClips.first;
      final rescaled = EditingCommands.update(
        placed,
        manual.copyWith(
          content: (manual.content as EditingVideoContent).copyWith(
            transform: (manual.content as EditingVideoContent).transform
                .copyWith(scale: .3),
          ),
        ),
      );
      expect(
        (rescaled.mainClips.first.content as EditingVideoContent).transform
            .toJson(),
        {'scale': .3, 'x': .1, 'y': .9, 'anchor_x': 0.0, 'anchor_y': 1.0},
      );
    },
  );

  test(
    'detach preserves source range, gain, fades, origin and leaves the input untouched',
    () {
      final initial = fixture();
      final original = initial.mainClips[1];
      const origin = EditingOrigin(type: 'production_clip', id: 'shot');
      final doc = EditingCommands.update(
        initial,
        original.copyWith(
          origin: origin,
          content: original.media!.copyWith(
            gainDb: -6,
            fadeInFrames: 12,
            fadeOutFrames: 24,
          ),
        ),
      );
      final before = doc.toJson();
      final next = EditingCommands.extractAudio(doc, 'm2');
      final audio = next.clips.singleWhere(
        (c) => c.content is EditingAudioContent && c.id != 'music',
      );
      expect(audio.id, isNot('m2'));
      expect(audio.trackId, 'A1');
      expect(
        (audio.startFrame, audio.durationFrames, audio.media!.sourceInUs),
        (96, 120, 1000000),
      );
      expect(audio.media!.source, same(videoSource));
      expect(
        (
          audio.media!.gainDb,
          audio.media!.fadeInFrames,
          audio.media!.fadeOutFrames,
        ),
        (-6, 12, 24),
      );
      expect(audio.origin, same(origin));
      expect(
        (next.mainClips[1].content as EditingVideoContent).audioDetached,
        isTrue,
      );
      expect(doc.toJson(), before);
      expect(() => EditingCommands.extractAudio(next, 'm2'), throwsStateError);
      final split = EditingCommands.split(next, 'm2', 120);
      expect(
        split.mainClips.where((c) => c.origin != null).map((c) => c.origin),
        everyElement(same(origin)),
      );
      expect(
        split.mainClips
            .where((c) => c.origin != null)
            .map((c) => (c.content as EditingVideoContent).audioDetached),
        everyElement(isTrue),
      );
    },
  );

  test(
    'automatic detach chooses a completely free dialogue or generic track',
    () {
      final doc = EditingCommands.addAudioTrack(fixture());
      final generic = doc.tracks.last;
      for (final blocked in [
        doc.copyWith(
          clips: [
            ...doc.clips,
            doc.clips
                .singleWhere((c) => c.id == 'music')
                .copyWith(
                  id: 'occupied',
                  trackId: 'A1',
                  startFrame: 200,
                  durationFrames: 24,
                ),
          ],
        ),
        for (final change in [
          doc.track('A1').copyWith(locked: true),
          doc.track('A1').copyWith(hidden: true),
          doc.track('A1').copyWith(muted: true),
        ])
          doc.copyWith(
            tracks: [for (final t in doc.tracks) t.id == 'A1' ? change : t],
          ),
      ]) {
        final next = EditingCommands.extractAudio(blocked, 'm2');
        expect(next.clips.last.trackId, generic.id);
        expect(next.tracks.length, doc.tracks.length);
      }
      final adjacent = doc.copyWith(
        clips: [
          ...doc.clips,
          doc.clips
              .singleWhere((c) => c.id == 'music')
              .copyWith(
                id: 'before',
                trackId: 'A1',
                startFrame: 0,
                durationFrames: 96,
              ),
          doc.clips
              .singleWhere((c) => c.id == 'music')
              .copyWith(
                id: 'after',
                trackId: 'A1',
                startFrame: 216,
                durationFrames: 24,
              ),
        ],
      );
      expect(
        EditingCommands.extractAudio(adjacent, 'm2').clips.last.trackId,
        'A1',
      );
    },
  );

  test(
    'detach creates a generic track when dialogue is absent or unavailable',
    () {
      final doc = fixture();
      final withoutDialogue = EditingCommands.removeTrack(doc, 'A1');
      final next = EditingCommands.extractAudio(withoutDialogue, 'm2');
      expect(next.tracks.last.role, EditingRole.audio);
      expect(next.tracks.last.order, 2);
      expect(next.clips.last.trackId, next.tracks.last.id);
      final locked = doc.copyWith(
        tracks: [
          for (final t in doc.tracks)
            t.kind == 'audio' ? t.copyWith(locked: true) : t,
        ],
      );
      final allocated = EditingCommands.extractAudio(locked, 'm2');
      expect(allocated.tracks.last.role, EditingRole.audio);
      expect(allocated.tracks.last.order, 3);
    },
  );

  test(
    'explicit detach refuses wrong, locked or occupied tracks without changing the document',
    () {
      final doc = fixture();
      final before = doc.toJson();
      for (final id in ['missing', 'V2', 'T1', 'A3']) {
        expect(
          () => EditingCommands.extractAudio(doc, 'm2', trackId: id),
          throwsStateError,
        );
      }
      for (final id in ['V1', 'A1']) {
        final locked = doc.copyWith(
          tracks: [
            for (final t in doc.tracks)
              t.id == id ? t.copyWith(locked: true) : t,
          ],
        );
        expect(
          () => EditingCommands.extractAudio(locked, 'm2', trackId: 'A1'),
          throwsStateError,
        );
      }
      expect(
        () => EditingCommands.extractAudio(doc, 'music'),
        throwsStateError,
      );
      expect(() => EditingCommands.extractAudio(doc, 'sub'), throwsStateError);
      final muted = EditingCommands.updateTrack(
        doc,
        doc.track('A1').copyWith(muted: true, hidden: true),
      );
      final explicit = EditingCommands.extractAudio(muted, 'm2', trackId: 'A1');
      expect(explicit.clips.last.trackId, 'A1');
      expect(explicit.track('A1').muted, isTrue);
      expect(doc.toJson(), before);
    },
  );

  test(
    'replacement keeps detached video silent and preserves the independent audio',
    () {
      final doc = EditingCommands.extractAudio(fixture(), 'm2');
      final audio = doc.clips.last;
      const origin = EditingOrigin(type: 'production_clip', id: 'new-shot');
      const replacement = EditingSource(
        assetId: 'replacement',
        mediaType: 'video',
        durationUs: 1000000,
        hasAudio: true,
      );
      final next = EditingCommands.replace(
        doc,
        'm2',
        replacement,
        origin: origin,
      );
      expect(
        (next.mainClips[1].content as EditingVideoContent).audioDetached,
        isTrue,
      );
      expect(next.mainClips[1].origin, same(origin));
      expect(next.clips.singleWhere((c) => c.id == audio.id), same(audio));
      final ordinary = EditingCommands.replace(next, 'm2', replacement);
      expect(ordinary.mainClips[1].origin, isNull);
      for (final source in [
        const EditingSource(
          assetId: 'image',
          mediaType: 'image',
          durationUs: 0,
        ),
        const EditingSource(
          assetId: 'silent',
          mediaType: 'video',
          durationUs: 1000000,
        ),
      ]) {
        final silent = EditingCommands.replace(next, 'm2', source);
        expect(
          (silent.mainClips[1].content as EditingVideoContent).audioDetached,
          isFalse,
        );
        expect(
          () => EditingCommands.extractAudio(silent, 'm2'),
          throwsStateError,
        );
        final invalid = silent.copyWith(
          clips: [
            silent.mainClips[1].copyWith(
              content: EditingVideoContent(source: source, audioDetached: true),
            ),
          ],
        );
        expect(() => invalid.validate(), throwsFormatException);
      }
    },
  );

  test(
    'speed keeps the source range, ripples the main track and caps by source',
    () {
      final doc = fixture();
      final fast = EditingCommands.retime(doc, 'm2', 2);
      expect(mainLayout(fast), [
        ('m1', 0, 96),
        ('m2', 96, 60),
        ('m3', 156, 120),
      ]);
      final m2 = fast.clips.singleWhere((c) => c.id == 'm2');
      expect(
        (m2.media!.sourceInUs, m2.sourceEndUs, m2.media!.speed),
        (1000000, 6000000, 2.0),
      );
      expect(m2.media!.framesFromSourceStart, 12);
      expect(m2.media!.framesToSourceEnd, 108);
      fast.validate();
      final slow = EditingCommands.retime(doc, 'm2', .5);
      expect(mainLayout(slow)[1], ('m2', 96, 240));
      expect(slow.clips.singleWhere((c) => c.id == 'm2').sourceEndUs, 6000000);
      final back = EditingCommands.retime(fast, 'm2', 1);
      expect(mainLayout(back), mainLayout(doc));
      expect(
        back.clips.singleWhere((c) => c.id == 'm2').toJson(),
        doc.clips.singleWhere((c) => c.id == 'm2').toJson(),
      );

      final split = EditingCommands.split(fast, 'm2', 126);
      final halves = split.mainClips.where((c) => c.media!.speed == 2).toList();
      expect(halves.map((c) => (c.media!.sourceInUs, c.sourceEndUs)), [
        (1000000, 3500000),
        (3500000, 6000000),
      ]);
      split.validate();
      expect(
        () => EditingCommands.trim(fast, 'm2', 96, 96 + 108).validate(),
        returnsNormally,
      );
      expect(
        () => EditingCommands.trim(fast, 'm2', 96, 96 + 109).validate(),
        throwsFormatException,
      );
      expect(
        EditingCommands.trim(
          fast,
          'm2',
          96 - 12,
          156,
        ).clips.singleWhere((c) => c.id == 'm2').media!.sourceInUs,
        0,
      );

      final faded = EditingCommands.update(
        doc,
        doc.clips
            .singleWhere((c) => c.id == 'm2')
            .copyWith(
              content: doc.clips
                  .singleWhere((c) => c.id == 'm2')
                  .media!
                  .copyWith(fadeInFrames: 48, fadeOutFrames: 48),
            ),
      );
      final quick = EditingCommands.retime(faded, 'm2', 4);
      final q = quick.clips.singleWhere((c) => c.id == 'm2');
      expect(
        (q.durationFrames, q.media!.fadeInFrames, q.media!.fadeOutFrames),
        (30, 30, 0),
      );
      quick.validate();

      final audio = EditingCommands.extractAudio(fast, 'm2').clips.last;
      expect((audio.durationFrames, audio.media!.speed), (60, 2.0));

      final replaced = EditingCommands.replace(fast, 'm2', videoSource);
      expect(replaced.clips.singleWhere((c) => c.id == 'm2').media!.speed, 2.0);
      const short = EditingSource(
        assetId: 'short',
        mediaType: 'video',
        durationUs: 1000000,
      );
      expect(
        EditingCommands.replace(
          fast,
          'm2',
          short,
        ).clips.singleWhere((c) => c.id == 'm2').durationFrames,
        12,
      );
      const image = EditingSource(
        assetId: 'image',
        mediaType: 'image',
        durationUs: 0,
      );
      final still = EditingCommands.replace(fast, 'm2', image);
      expect(still.clips.singleWhere((c) => c.id == 'm2').media!.speed, 1.0);
      expect(() => EditingCommands.retime(still, 'm2', 2), throwsStateError);
    },
  );

  test(
    'speed rejects bad values, overlaps and stays compatible with old JSON',
    () {
      final doc = fixture();
      for (final speed in [.2, 4.5, double.nan]) {
        expect(
          () => EditingCommands.retime(doc, 'm2', speed),
          throwsFormatException,
        );
      }
      expect(() => EditingCommands.retime(doc, 'sub', 2), throwsStateError);
      final crowded = EditingCommands.place(
        doc,
        const EditingClip(
          id: 'sfx',
          trackId: 'A3',
          startFrame: 270,
          durationFrames: 24,
          content: EditingAudioContent(source: audioSource),
        ),
      );
      expect(
        () => EditingCommands.retime(crowded, 'music', .5),
        throwsStateError,
      );
      final music = EditingCommands.retime(
        crowded,
        'music',
        2,
      ).clips.singleWhere((c) => c.id == 'music');
      expect(
        (music.startFrame, music.durationFrames, music.sourceEndUs),
        (24, 120, 10000000),
      );

      final m2 = doc.clips.singleWhere((c) => c.id == 'm2');
      expect(
        () => doc
            .copyWith(
              clips: [
                for (final c in doc.clips)
                  c.id == 'm2'
                      ? c.copyWith(content: m2.media!.copyWith(speed: 4.5))
                      : c,
              ],
            )
            .validate(),
        throwsFormatException,
      );
      expect(
        () => EditingDocument.empty('16:9')
            .copyWith(
              clips: const [
                EditingClip(
                  id: 'still',
                  trackId: 'V1',
                  startFrame: 0,
                  durationFrames: 24,
                  content: EditingVideoContent(
                    source: EditingSource(
                      assetId: 'image',
                      mediaType: 'image',
                      durationUs: 0,
                    ),
                    speed: 2,
                  ),
                ),
              ],
            )
            .validate(),
        throwsFormatException,
      );

      final json = EditingCommands.retime(doc, 'm2', 1.5).toJson();
      final clips = (json['clips'] as List).cast<Map<String, dynamic>>();
      expect(
        clips.singleWhere((c) => c['id'] == 'm2')['content']['speed'],
        1.5,
      );
      expect(EditingDocument.fromJson(json).toJson(), json);
      for (final clip in clips) {
        (clip['content'] as Map).remove('speed');
      }
      final legacy = EditingDocument.fromJson(json);
      expect(legacy.clips.map((c) => c.media?.speed).whereType<double>(), [
        1.0,
        1.0,
        1.0,
        1.0,
      ]);
    },
  );
}
