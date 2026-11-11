// 职责: 复用分块合成规则生成完整时间线预览与指定帧检查拼图。
// 关联文件:
//   lib/shared/models/editing/document.dart
//   lib/shared/services/editing/service.dart
//   lib/shared/services/production/ffmpeg_runner.dart
//   lib/shared/services/production/media_service.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md
//   .agents/rules/service-naming.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../../logger/app_logger.dart';
import '../../models/editing/document.dart';
import '../../models/production/settings.dart';
import '../../models/production/media.dart';
import '../production/ffmpeg_runner.dart';
import '../production/media_service.dart';
import '../production/contact_sheet.dart';
import '../production/frame_capture.dart';
import 'service.dart';
import 'disk_space.dart';

final _log = AppLogger.forModule('EditingRender');

typedef EditingProgress = void Function(String stage, double progress);

/// 字幕导出方式：烧录进画面、另存 SRT（标题仍烧录）、不导出。
abstract final class EditingSubtitles {
  static const burn = 'burn';
  static const srt = 'srt';
  static const none = 'none';
}

class EditingInsufficientSpace implements Exception {
  const EditingInsufficientSpace();
}

class EditingRenderService {
  EditingRenderService(this.projects, this.runner);
  final EditingService projects;
  final FfmpegRunner runner;
  Future<void> _tail = Future.value();
  Future<void> get whenIdle => _tail;
  MediaCancellation? _preview;
  Future<Directory>? _cache;
  Future<String>? _font;
  static const chunkFrames = 120;
  static const cacheLimit = 2 * 1024 * 1024 * 1024;

  /// 预览块缓存放在 App 私有目录里跨启动复用，所有实例共用一份；
  /// 块的最后使用时间记在 video.mp4 的修改时间上，按它统一淘汰。
  Future<Directory> _cacheDirectory() => _cache ??= () async {
    final dir = Directory(
      p.join(projects.library.root.path, 'cache', 'editing_preview'),
    );
    await dir.create(recursive: true);
    await _sweep(dir);
    return dir;
  }();

  /// 清掉崩溃或强杀留下的半成品块。
  /// 只删一段时间没动过的，避免碰到另一个实例正在写的目录。
  static Future<void> _sweep(Directory cache) async {
    final now = DateTime.now();
    Future<void> clear(Directory dir, String prefix, Duration age) async {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! Directory ||
            !p.basename(entity.path).startsWith(prefix)) {
          continue;
        }
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > age) {
            await entity.delete(recursive: true);
          }
        } on FileSystemException catch (error) {
          _log.warning('stale cache sweep: $error');
        }
      }
    }

    await clear(cache, '.block-', const Duration(hours: 1));
  }

  Future<EncodedMedia> render(
    EditingDocument document, {
    required MediaCancellation cancellation,
    required EditingProgress progress,
    String resolution = '720p',
    String subtitles = EditingSubtitles.burn,
    bool preview = false,
  }) {
    final previous = _preview;
    if (preview) {
      _preview = cancellation;
    } else {
      _preview = null;
    }
    final result = _tail.then((_) async {
      _check(cancellation);
      return _render(
        document,
        (resolution: resolution, subtitles: subtitles, preview: preview),
        cancellation,
        progress,
      );
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    if (previous != null) {
      unawaited(previous.cancel());
    }
    return result;
  }

  void _check(MediaCancellation token) {
    if (token.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
  }

  /// 节点封面复用时间线的单帧合成规则，包含裁切、叠层与字幕，不提交整段预览。
  Future<Uint8List> firstFrame(
    EditingDocument document, {
    required MediaCancellation cancellation,
  }) {
    final result = _tail.then((_) async {
      document.validate();
      _check(cancellation);
      if (document.totalFrames == 0) {
        throw StateError('Empty timeline');
      }
      await projects.verify(document, cancellation);
      final size = ProductionSettings.dimensions(document.ratio, '480p');
      final temporary = await Directory.systemTemp.createTemp(
        'reveric_editing_poster_',
      );
      try {
        await _block(
          document,
          (start: 0, count: 1, size: size, subtitles: EditingSubtitles.burn),
          temporary,
          cancellation,
          (_, _) {},
          includeAudio: false,
        );
        return await captureMediaFrame(
          runner,
          '${temporary.path}/video.mp4',
          File('${temporary.path}/first.png'),
          cancellation,
        );
      } catch (error, stack) {
        if (!cancellation.cancelled) {
          _log.error('First frame failed', error: error, stackTrace: stack);
        }
        rethrow;
      } finally {
        cancellation.onProgress = null;
        await temporary.delete(recursive: true);
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<ContactSheet> frames(
    EditingDocument document,
    List<int> frames, {
    required MediaCancellation cancellation,
    required EditingProgress progress,
  }) {
    final positions = contactSheetPositions(
      frames,
      'frames',
      end: document.totalFrames,
    );
    final result = _tail.then((_) async {
      document.validate();
      _check(cancellation);
      await projects.verify(document, cancellation);
      final size = ProductionSettings.dimensions(document.ratio, '480p');
      final temporary = await Directory.systemTemp.createTemp(
        'reveric_editing_frames_',
      );
      final captures = <Uint8List>[];
      try {
        for (var i = 0; i < positions.length; i++) {
          _check(cancellation);
          final block = await temporary.createTemp('frame-');
          await _block(
            document,
            (
              start: positions[i],
              count: 1,
              size: size,
              subtitles: EditingSubtitles.burn,
            ),
            block,
            cancellation,
            (stage, value) => progress(stage, (i + value) / positions.length),
            includeAudio: false,
          );
          captures.add(
            await captureMediaFrame(
              runner,
              '${block.path}/video.mp4',
              File('${block.path}/frame.png'),
              cancellation,
            ),
          );
          await block.delete(recursive: true);
        }
        _check(cancellation);
        return await composeContactSheet(
          captures,
          [
            for (final frame in positions)
              {
                'label': 'F$frame',
                'frame': frame,
                'timestamp_ms': editingMicroseconds(frame) / 1000,
              },
          ],
          size.$1,
          size.$2,
        );
      } catch (error, stack) {
        _log.error('frames failed', error: error, stackTrace: stack);
        rethrow;
      } finally {
        cancellation.onProgress = null;
        await temporary.delete(recursive: true);
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// 该方式下要烧录进画面的文字片段。
  static bool burns(EditingClip clip, String subtitles) {
    final content = clip.content;
    return content is EditingTextContent &&
        content.text.trim().isNotEmpty &&
        (subtitles == EditingSubtitles.burn ||
            (subtitles == EditingSubtitles.srt && content.style == 'title'));
  }

  /// 字幕样式的文字片段按时间顺序写成 SRT。
  static String srt(EditingDocument doc) {
    String time(int frame) {
      final ms = (frame * 1000 / editingFps).round();
      String two(int v) => v.toString().padLeft(2, '0');
      return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
    }

    final cues =
        doc.clips
            .where(
              (c) =>
                  doc.track(c.trackId).kind == 'text' &&
                  !doc.track(c.trackId).hidden &&
                  c.content is EditingTextContent &&
                  (c.content as EditingTextContent).style == 'subtitle' &&
                  (c.content as EditingTextContent).text.trim().isNotEmpty,
            )
            .toList()
          ..sort((a, b) => a.startFrame.compareTo(b.startFrame));
    return [
      for (var i = 0; i < cues.length; i++)
        '${i + 1}\n${time(cues[i].startFrame)} --> ${time(cues[i].endFrame)}\n${(cues[i].content as EditingTextContent).text.trim()}\n',
    ].join('\n');
  }

  static String cacheKey(
    EditingDocument doc,
    int start,
    int count,
    (int, int) size, {
    String subtitles = EditingSubtitles.burn,
    Map<String, String> sourceFingerprints = const {},
  }) {
    final active =
        doc.clips
            .where((c) => c.startFrame < start + count && c.endFrame > start)
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'renderer': 4,
              'subtitles': subtitles,
              'start': start,
              'count': count,
              'size': [size.$1, size.$2],
              'clips': [
                for (final c in active)
                  {
                    ...(c.toJson()
                      ..remove('name')
                      ..remove('origin')),
                    if (c.media != null)
                      'sourceFingerprint':
                          sourceFingerprints[c.media!.source.assetId],
                    'track': {
                      'kind': doc.track(c.trackId).kind,
                      'order': doc.track(c.trackId).order,
                      'hidden': doc.track(c.trackId).hidden,
                      'muted': doc.track(c.trackId).muted,
                    },
                  },
              ],
            }),
          ),
        )
        .toString();
  }

  Future<EncodedMedia> _render(
    EditingDocument doc,
    ({String resolution, String subtitles, bool preview}) options,
    MediaCancellation token,
    EditingProgress progress,
  ) async {
    final (:resolution, :subtitles, :preview) = options;
    doc.validate();
    if (doc.totalFrames == 0) {
      throw StateError('Empty timeline');
    }
    progress('verify', 0);
    await projects.verify(doc, token);
    final fingerprints = await projects.fingerprints(doc, token);
    _check(token);
    final size = ProductionSettings.dimensions(
      doc.ratio,
      preview ? '480p' : resolution,
    );
    final temporary = await Directory.systemTemp.createTemp(
      'reveric_editing_render_',
    );
    try {
      final cache = preview ? await _cacheDirectory() : null;
      // Float stereo PCM plus retained/copy video and one layer's scratch space.
      final seconds = editingSeconds(doc.totalFrames);
      final requiredBytes =
          ((seconds * (editingSampleRate * 8 * 2 + size.$1 * size.$2 * .5) +
                      size.$1 * size.$2 * 120 * 2) *
                  1.1)
              .ceil();
      if (editingFreeBytes(temporary.path) < requiredBytes) {
        throw const EditingInsufficientSpace();
      }
      final videos = <File>[];
      final audio = File('${temporary.path}/audio.f32');
      final sink = audio.openWrite();
      try {
        for (var start = 0; start < doc.totalFrames; start += chunkFrames) {
          _check(token);
          final count = math.min(chunkFrames, doc.totalFrames - start);
          final key = cacheKey(
            doc,
            start,
            count,
            size,
            subtitles: subtitles,
            sourceFingerprints: fingerprints,
          );
          final cached = cache == null ? null : Directory('${cache.path}/$key');
          final hit = cached != null && await cached.exists();
          // 预览块直接建在缓存目录里，完成后同卷改名即可入缓存。
          final block = hit
              ? cached
              : await (cache ?? temporary).createTemp(
                  cache == null ? 'block-' : '.block-',
                );
          if (!hit) {
            progress('render', start / doc.totalFrames * .85);
            try {
              await _block(
                doc,
                (start: start, count: count, size: size, subtitles: subtitles),
                block,
                token,
                (stage, value) => progress(
                  stage,
                  (start + count * value) / doc.totalFrames * .85,
                ),
                preview: preview,
              );
            } catch (_) {
              if (cache != null) {
                await block.delete(recursive: true);
              }
              rethrow;
            }
          }
          final video = File('${temporary.path}/part-${videos.length}.mp4');
          await File('${block.path}/video.mp4').copy(video.path);
          videos.add(video);
          await sink.addStream(File('${block.path}/audio.f32').openRead());
          if (cached != null) {
            if (hit) {
              await File(
                '${cached.path}/video.mp4',
              ).setLastModified(DateTime.now());
            } else {
              await _store(block, cached);
            }
          }
          progress('render', (start + count) / doc.totalFrames * .85);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (cache != null) {
        await _evict(cache);
      }
      _check(token);
      final list = File('${temporary.path}/concat.txt');
      await list.writeAsString(
        [
          for (var i = 0; i < videos.length; i++) "file 'part-$i.mp4'",
        ].join('\n'),
      );
      final output = File('${temporary.path}/result.mp4');
      token.onProgress = (d) => progress(
        'assemble',
        .85 +
            .1 *
                (d.inMicroseconds / editingMicroseconds(doc.totalFrames)).clamp(
                  0,
                  1,
                ),
      );
      await runner.execute(
        [
          '-y',
          '-f',
          'concat',
          '-safe',
          '1',
          '-i',
          list.path,
          '-f',
          'f32le',
          '-ar',
          '$editingSampleRate',
          '-ac',
          '2',
          '-i',
          audio.path,
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-c:v',
          'copy',
          '-af',
          'alimiter=limit=0.95:attack=5:release=50:level=false:latency=true',
          '-c:a',
          'aac',
          '-b:a',
          '192k',
          '-movflags',
          '+faststart',
          output.path,
        ],
        probe: false,
        cancellation: token,
      );
      progress('validate', .95);
      final info = await projects.library.media.probe(
        output.path,
        cancellation: token,
      );
      _validate(info, size, doc.totalFrames, audio: true);
      // 预览马上就会被播放器读到，不再额外整片解码一遍。
      if (!preview) {
        await runner.execute(
          ['-v', 'error', '-xerror', '-i', output.path, '-f', 'null', '-'],
          probe: false,
          cancellation: token,
        );
      }
      _check(token);
      progress('done', 1);
      return EncodedMedia(output, info, temporary);
    } catch (error, stack) {
      _log.error('composition failed', error: error, stackTrace: stack);
      await temporary.delete(recursive: true);
      rethrow;
    } finally {
      token.onProgress = null;
    }
  }

  /// 预览块用最快档编码，只供播放器预览，并保留在 App 私有缓存中复用。
  List<String> _videoOutput(
    (int, int) size,
    int count,
    String path, {
    bool preview = false,
  }) => [
    '-an',
    '-c:v',
    'libx264',
    '-preset',
    preview ? 'ultrafast' : 'veryfast',
    '-crf',
    preview ? '23' : '20',
    '-pix_fmt',
    'yuv420p',
    '-r',
    '$editingFps',
    '-frames:v',
    '$count',
    '-g',
    '120',
    '-keyint_min',
    '120',
    '-sc_threshold',
    '0',
    '-bf',
    '0',
    '-flags',
    '+cgop',
    '-video_track_timescale',
    '${editingFps * 1000}',
    path,
  ];
  Future<String> _fontFile() => _font ??= () async {
    final dir = await Directory.systemTemp.createTemp('reveric_editing_font_');
    final file = File('${dir.path}/subtitle.ttf');
    final data = await rootBundle.load('assets/fonts/LXGWWenKai-Regular.ttf');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file.path;
  }();

  /// 滤镜参数里的路径：统一正斜杠并转义冒号（Windows 盘符）。
  static String _filterPath(String path) =>
      path.replaceAll('\\', '/').replaceAll(':', '\\:').replaceAll("'", '');

  /// 按画面宽度折行；中日韩字符按一个字宽、其他按半个字宽估算。
  static List<String> _wrap(String text, double limit) {
    final lines = <String>[];
    for (final paragraph in text.trim().split('\n')) {
      var line = StringBuffer();
      var width = 0.0;
      for (final rune in paragraph.runes) {
        final w = rune < 0x2E80 ? .55 : 1.0;
        if (width + w > limit && line.isNotEmpty) {
          lines.add(line.toString());
          line = StringBuffer();
          width = 0;
        }
        line.writeCharCode(rune);
        width += w;
      }
      lines.add(line.toString());
    }
    return lines.where((l) => l.trim().isNotEmpty).toList();
  }

  Future<void> _block(
    EditingDocument doc,
    ({int start, int count, (int, int) size, String subtitles}) range,
    Directory dir,
    MediaCancellation token,
    EditingProgress progress, {
    bool includeAudio = true,
    bool preview = false,
  }) async {
    final (:start, :count, :size, :subtitles) = range;
    final seconds = editingSeconds(count);
    var video = '${dir.path}/base.mp4';
    var audio = '${dir.path}/base.f32';
    Future<void> run(List<String> args) =>
        runner.execute(args, probe: false, cancellation: token);
    await run([
      '-y',
      '-f',
      'lavfi',
      '-i',
      'color=c=black:s=${size.$1}x${size.$2}:r=$editingFps:d=$seconds',
      ..._videoOutput(size, count, video, preview: preview),
    ]);
    if (includeAudio) {
      await run([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'anullsrc=r=$editingSampleRate:cl=stereo',
        '-af',
        'atrim=end_sample=${count * editingSamplesPerFrame}',
        '-f',
        'f32le',
        audio,
      ]);
    }
    // 画面自下而上叠：视频轨按层级，字幕最后压在最上面；音频顺序不影响混音。
    int rank(EditingTrack t) => switch (t.kind) {
      'video' => t.order,
      'text' => 1000 + t.order,
      _ => 2000 + t.order,
    };
    final clips =
        doc.clips
            .where((c) => c.startFrame < start + count && c.endFrame > start)
            .toList()
          ..sort(
            (a, b) => rank(
              doc.track(a.trackId),
            ).compareTo(rank(doc.track(b.trackId))),
          );
    for (var i = 0; i < clips.length; i++) {
      _check(token);
      final c = clips[i];
      final content = c.content;
      final media = c.media;
      final track = doc.track(c.trackId);
      if (!includeAudio && track.kind == 'audio') {
        continue;
      }
      final first = math.max(start, c.startFrame);
      final frames = math.min(start + count, c.endFrame) - first;
      final elapsed = first - c.startFrame;
      final delay = first - start;
      final window =
          'between(t,${editingSeconds(delay)},${editingSeconds(delay + frames) - 1 / (2 * editingFps)})';
      token.onProgress = (d) => progress(
        'render',
        (i + (d.inMicroseconds / 1000000 / seconds).clamp(0, 1)) /
            (clips.length + 1),
      );
      // 淡入淡出按片段内帧号计算，跨块时从已过去的帧数接着算。
      String fade(String n, int samplesPerFrame) {
        final scale = samplesPerFrame;
        final fadeIn = media!.fadeInFrames == 0
            ? '1'
            : 'min(1,($n+${elapsed * scale})/${media.fadeInFrames * scale})';
        final fadeOut = media.fadeOutFrames == 0
            ? '1'
            : 'min(1,(${(c.durationFrames - elapsed) * scale}-$n)/${media.fadeOutFrames * scale})';
        return '$fadeIn*$fadeOut';
      }

      Future<void> mix(String path, double inputStart) async {
        final next = '${dir.path}/mix-$i.f32';
        final envelope =
            '${math.pow(10, media!.gainDb / 20)}*${fade('n', editingSamplesPerFrame)}';
        await run([
          '-y',
          '-f',
          'f32le',
          '-ar',
          '$editingSampleRate',
          '-ac',
          '2',
          '-i',
          audio,
          '-ss',
          '$inputStart',
          '-i',
          path,
          '-filter_complex',
          '[1:a:0]asetpts=PTS-STARTPTS,aresample=$editingSampleRate,aformat=sample_fmts=flt:channel_layouts=stereo,'
              'apad,atrim=end_sample=${frames * editingSamplesPerFrame},aeval=\'val(0)*$envelope|val(1)*$envelope\','
              'adelay=${delay * editingSamplesPerFrame}S:all=1[a];[0:a][a]amix=inputs=2:duration=first:normalize=0,'
              'atrim=end_sample=${count * editingSamplesPerFrame}[out]',
          '-map',
          '[out]',
          '-f',
          'f32le',
          next,
        ]);
        await File(audio).delete();
        audio = next;
      }

      if (content is EditingTextContent) {
        if (track.hidden || !burns(c, subtitles)) {
          continue;
        }
        final title = content.style == 'title';
        final short = math.min(size.$1, size.$2);
        final fontSize = (short * (title ? .075 : .05)).round();
        final lineHeight = fontSize * 1.4;
        final lines = _wrap(content.text, size.$1 * .84 / fontSize);
        final block = lines.length * lineHeight;
        final top = switch (content.position) {
          'top' => size.$2 * .09,
          'center' => (size.$2 - block) / 2,
          _ => size.$2 * .91 - block,
        };
        final font = _filterPath(await _fontFile());
        final filters = <String>[];
        for (var j = 0; j < lines.length; j++) {
          final file = File('${dir.path}/text-$i-$j.txt');
          await file.writeAsString(lines[j]);
          filters.add(
            "drawtext=fontfile='$font':textfile='${_filterPath(file.path)}':"
            'expansion=none:fontsize=$fontSize:fontcolor=white:'
            'borderw=${math.max(1, fontSize ~/ 18)}:bordercolor=black@0.6:'
            'shadowcolor=black@0.5:shadowx=0:shadowy=1:'
            'x=(w-text_w)/2:y=${(top + j * lineHeight).round()}:'
            "enable='$window'",
          );
        }
        final next = '${dir.path}/layer-$i.mp4';
        await run([
          '-y',
          '-i',
          video,
          '-vf',
          filters.join(','),
          ..._videoOutput(size, count, next, preview: preview),
        ]);
        await File(video).delete();
        video = next;
        continue;
      }
      final source = media!.source;
      final path = projects.library.resolvePath(
        await projects.sourcePath(source.assetId),
      );
      final inputStart = media.sourceUsAt(elapsed) / 1000000;
      if (content is EditingVideoContent && !track.hidden) {
        final next = '${dir.path}/layer-$i.mp4';
        final w = math.max(
          2,
          (size.$1 * content.transform.scale / 2).round() * 2,
        );
        final h = math.max(
          2,
          (size.$2 * content.transform.scale / 2).round() * 2,
        );
        // 素材在缩放后的图层框内等比居中，框中心使用归一化坐标。
        final position =
            'x=W*${content.transform.x}-w/2:y=H*${content.transform.y}-h/2';
        final alpha = media.fadeInFrames == 0 && media.fadeOutFrames == 0
            ? 'colorchannelmixer=aa=${content.opacity}'
            : "geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':"
                  "a='alpha(X,Y)*${content.opacity}*${fade('N', 1)}'";
        await run([
          '-y',
          '-i',
          video,
          if (source.mediaType == 'image') ...[
            '-loop',
            '1',
          ] else ...[
            '-ss',
            '$inputStart',
          ],
          '-i',
          path,
          '-filter_complex',
          '[1:v:0]setpts=PTS-STARTPTS,fps=$editingFps,trim=end_frame=$frames,'
              'scale=$w:$h:force_original_aspect_ratio=decrease,setsar=1,format=rgba,'
              '$alpha,setpts=PTS+$delay/$editingFps/TB[fg];'
              '[0:v][fg]overlay=$position:'
              "eof_action=pass:repeatlast=0:enable='$window'[v]",
          '-map',
          '[v]',
          ..._videoOutput(size, count, next, preview: preview),
        ]);
        await File(video).delete();
        video = next;
        if (includeAudio &&
            source.mediaType == 'video' &&
            source.hasAudio &&
            !content.audioDetached) {
          await mix(path, inputStart);
        }
      } else if (track.kind == 'audio' && !track.muted) {
        await mix(path, inputStart);
      }
    }
    await File(video).rename('${dir.path}/video.mp4');
    if (includeAudio) {
      await File(audio).rename('${dir.path}/audio.f32');
    }
    final info = await projects.library.media.probe(
      '${dir.path}/video.mp4',
      cancellation: token,
    );
    _validate(info, size, count, audio: false);
    if (includeAudio &&
        await File('${dir.path}/audio.f32').length() !=
            count * editingSamplesPerFrame * 2 * 4) {
      throw const MediaException(MediaFailure.encoding_failed);
    }
  }

  void _validate(
    MediaInfo info,
    (int, int) size,
    int frames, {
    required bool audio,
  }) {
    if (info.width != size.$1 ||
        info.height != size.$2 ||
        info.frameRate != editingFps ||
        info.videoCodec != 'h264' ||
        info.pixelFormat != 'yuv420p' ||
        info.frameCount != frames ||
        info.timeBase != '1/${editingFps * 1000}' ||
        (info.duration.inMicroseconds - editingMicroseconds(frames)).abs() >
            1000000 / editingFps ||
        (audio && (!info.hasAudio || info.audioCodec != 'aac'))) {
      throw const MediaException(MediaFailure.encoding_failed);
    }
  }

  /// 同一块可能被另一个实例抢先写入缓存，此时丢掉自己这份。
  static Future<void> _store(Directory block, Directory cached) async {
    try {
      await block.rename(cached.path);
    } on FileSystemException {
      if (!await cached.exists()) {
        rethrow;
      }
      await block.delete(recursive: true);
    }
  }

  static Future<void> _evict(Directory cache) async {
    final entries = <(Directory, int, DateTime)>[];
    var total = 0;
    await for (final entity in cache.list(followLinks: false)) {
      if (entity is! Directory || p.basename(entity.path).startsWith('.')) {
        continue;
      }
      var bytes = 0;
      var used = DateTime.fromMillisecondsSinceEpoch(0);
      try {
        await for (final file in entity.list()) {
          if (file is File) {
            final stat = await file.stat();
            bytes += stat.size;
            if (p.basename(file.path) == 'video.mp4') {
              used = stat.modified;
            }
          }
        }
      } on FileSystemException catch (error) {
        // 另一个实例刚淘汰了这一块。
        if (_log.isDebugEnabled) {
          _log.debug('cache entry vanished: $error');
        }
        continue;
      }
      total += bytes;
      entries.add((entity, bytes, used));
    }
    entries.sort((a, b) => a.$3.compareTo(b.$3));
    for (final entry in entries) {
      if (total <= cacheLimit) {
        break;
      }
      try {
        await entry.$1.delete(recursive: true);
      } on FileSystemException catch (error) {
        if (_log.isDebugEnabled) {
          _log.debug('cache entry vanished: $error');
        }
      }
      total -= entry.$2;
    }
  }

  Future<void> dispose() async {
    await _preview?.cancel();
    await _tail;
    final font = await _font;
    if (font != null) {
      await File(font).parent.delete(recursive: true);
    }
  }
}
