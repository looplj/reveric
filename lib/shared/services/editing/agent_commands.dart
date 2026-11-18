// 职责: 严格解析 Agent 剪辑命令组，复用已有命令逐步校验并返回实际影响范围。
// 关联文件:
//   lib/shared/services/editing/commands.dart
//   lib/shared/services/editing/session.dart
//   lib/shared/models/editing/document.dart
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';
import '../../models/editing/document.dart';
import '../../models/tool_permission.dart';
import 'commands.dart';
import 'service.dart';

class EditingAgentCommands {
  EditingAgentCommands(this.resolveSource);
  final Future<EditingSource> Function(Map<String, dynamic>) resolveSource;
  static void keys(Map value, Set<String> allowed) {
    final unknown = value.keys.where((key) => !allowed.contains(key));
    if (unknown.isNotEmpty) {
      throw FormatException(
        'Unknown editing parameter: ${unknown.join(', ')}. '
        'Allowed: ${allowed.join(', ')}.',
      );
    }
  }

  static String text(Map value, String key) {
    final result = value[key];
    if (result is! String || result.isEmpty) {
      throw FormatException('$key must be a nonempty string.');
    }
    return result;
  }

  static int integer(Map value, String key) {
    final result = value[key];
    if (result is! int || result < 0) {
      throw FormatException('$key must be a nonnegative integer.');
    }
    return result;
  }

  static List<Map<String, dynamic>> parse(Object? value) {
    if (value is! List ||
        value.isEmpty ||
        value.length > 100 ||
        utf8.encode(jsonEncode(value)).length > 256 * 1024 ||
        value.any((c) => c is! Map)) {
      throw const FormatException(
        'commands must contain 1..100 objects and fit within 256 KiB.',
      );
    }
    return value.map((c) => Map<String, dynamic>.from(c as Map)).toList();
  }

  static List<Map<String, dynamic>> changes(
    EditingDocument before,
    EditingDocument after,
  ) {
    final ids = {
      ...before.clips.map((c) => c.id),
      ...after.clips.map((c) => c.id),
    };
    return [
      for (final id in ids)
        if (!const DeepCollectionEquality().equals(
          before.clips.where((c) => c.id == id).firstOrNull?.toJson(),
          after.clips.where((c) => c.id == id).firstOrNull?.toJson(),
        ))
          {
            'clip_id': id,
            'before': _range(before, id),
            'after': _range(after, id),
          },
    ];
  }

  static Map<String, dynamic>? _range(EditingDocument doc, String id) {
    final clip = doc.clips.where((c) => c.id == id).firstOrNull;
    return clip == null
        ? null
        : {
            'track_id': clip.trackId,
            'start_frame': clip.startFrame,
            'end_frame': clip.endFrame,
            'source_in_us': clip.media?.sourceInUs ?? 0,
            'duration_frames': clip.durationFrames,
          };
  }

  Future<
    ({
      EditingDocument document,
      String title,
      List<Map<String, dynamic>> result,
    })
  >
  apply(
    EditingDocument original,
    String title,
    List<Map<String, dynamic>> commands,
  ) async {
    var index = 0;
    String at(String message) {
      final op = commands[index]['op'];
      return 'commands[$index]${op is String ? ' ($op)' : ''}: $message';
    }

    try {
      return await _apply(original, title, commands, (i) => index = i);
    } on ToolOperationException catch (error) {
      throw ToolOperationException(
        error.code,
        at(error.message),
        hint: error.hint,
      );
    } on FormatException catch (error) {
      throw FormatException(at(error.message));
    } on StateError catch (error) {
      throw StateError(at(error.message));
    }
  }

  Future<
    ({
      EditingDocument document,
      String title,
      List<Map<String, dynamic>> result,
    })
  >
  _apply(
    EditingDocument original,
    String title,
    List<Map<String, dynamic>> commands,
    void Function(int index) onCommand,
  ) async {
    var doc = original;
    final results = <Map<String, dynamic>>[];
    final locked = original.tracks
        .where((t) => t.locked)
        .map((t) => t.id)
        .toSet();
    for (final (index, command) in commands.indexed) {
      onCommand(index);
      final before = doc;
      final op = text(command, 'op');
      final clipId = command['clip_id'] as String?;
      final clip = clipId == null
          ? null
          : doc.clips.where((c) => c.id == clipId).firstOrNull;
      if (clipId != null && clip == null) {
        throw ToolOperationException(
          'not_found',
          'Editing clip not found: $clipId.',
        );
      }
      final trackId = command['track_id'] as String? ?? clip?.trackId;
      final track = trackId == null
          ? null
          : doc.tracks.where((t) => t.id == trackId).firstOrNull;
      if (trackId != null && track == null) {
        throw ToolOperationException(
          'not_found',
          'Editing track not found: $trackId.',
        );
      }
      final unlock =
          op == 'update_track' &&
          commands.length == 1 &&
          command['fields'] is Map &&
          (command['fields'] as Map).length == 1 &&
          command['fields']['locked'] == false;
      if (!unlock &&
          (locked.contains(trackId) || locked.contains(clip?.trackId))) {
        throw const ToolOperationException(
          'failed_precondition',
          'The track is locked. Unlock it in a separate command.',
        );
      }
      String id() {
        final value = command.containsKey('id')
            ? text(command, 'id')
            : const Uuid().v4();
        if (doc.clips.any((c) => c.id == value) ||
            doc.tracks.any((t) => t.id == value)) {
          throw const FormatException('The new ID is already in use.');
        }
        return value;
      }

      Map<String, dynamic> fields(Set<String> allowed) {
        final value = command['fields'];
        if (value is! Map || value.isEmpty) {
          throw const FormatException('fields must be a nonempty object.');
        }
        keys(value, allowed);
        return Map<String, dynamic>.from(value);
      }

      switch (op) {
        case 'add_audio_track' || 'add_text_track':
          keys(command, {'op', 'id'});
          final nextId = id();
          final next = op == 'add_audio_track'
              ? EditingCommands.addAudioTrack(doc)
              : EditingCommands.addTextTrack(doc);
          final added = next.tracks.last;
          doc = next.copyWith(
            tracks: [
              ...doc.tracks,
              EditingTrack(
                id: nextId,
                kind: added.kind,
                role: added.role,
                order: added.order,
              ),
            ],
          );
        case 'update_track':
          keys(command, {'op', 'track_id', 'fields'});
          text(command, 'track_id');
          final f = fields({'name', 'locked', 'hidden', 'muted'});
          if (f['locked'] == false && (f.length != 1 || commands.length != 1)) {
            throw const FormatException('Unlock must be a separate command.');
          }
          if (f.containsKey('muted') && track!.kind != 'audio') {
            throw const FormatException('Only audio tracks can be muted.');
          }
          doc = EditingCommands.updateTrack(
            doc,
            track!.copyWith(
              name: f['name'] as String?,
              locked: f['locked'] as bool?,
              hidden: f['hidden'] as bool?,
              muted: f['muted'] as bool?,
            ),
          );
        case 'reorder_track':
          keys(command, {'op', 'track_id', 'order'});
          doc = EditingCommands.reorderTrack(
            doc,
            text(command, 'track_id'),
            integer(command, 'order'),
          );
        case 'remove_track':
          keys(command, {'op', 'track_id'});
          doc = EditingCommands.removeTrack(doc, text(command, 'track_id'));
        case 'add_media':
          keys(command, {
            'op',
            'id',
            'track_id',
            'path',
            'production_clip_id',
            'index',
            'start_frame',
          });
          text(command, 'track_id');
          if (track!.main
              ? command.containsKey('start_frame')
              : command.containsKey('index')) {
            throw const FormatException(
              'Use index for the main track, start_frame for other tracks.',
            );
          }
          final source = await resolveSource(command);
          final media =
              EditingService.clipFor(
                source,
                track,
                origin: command['production_clip_id'] == null
                    ? null
                    : EditingOrigin(
                        type: 'production_clip',
                        id: text(command, 'production_clip_id'),
                      ),
              ).copyWith(
                id: id(),
                startFrame: track.main ? 0 : integer(command, 'start_frame'),
              );
          doc = track.main
              ? EditingCommands.insertMain(
                  doc,
                  media,
                  integer(command, 'index'),
                )
              : EditingCommands.place(doc, media);
        case 'add_text':
          keys(command, {'op', 'id', 'track_id', 'start_frame', 'text'});
          final next = EditingCommands.addText(
            doc,
            text(command, 'track_id'),
            integer(command, 'start_frame'),
            text(command, 'text'),
          );
          final added = next.clips.last;
          final nextId = id();
          doc = next.copyWith(
            clips: [
              for (final c in next.clips)
                c.id == added.id ? c.copyWith(id: nextId) : c,
            ],
          );
        case 'reorder_clip':
          keys(command, {'op', 'clip_id', 'index'});
          doc = EditingCommands.reorder(
            doc,
            text(command, 'clip_id'),
            integer(command, 'index'),
          );
        case 'move_clip':
          keys(command, {'op', 'clip_id', 'start_frame', 'track_id'});
          doc = EditingCommands.move(
            doc,
            text(command, 'clip_id'),
            integer(command, 'start_frame'),
            trackId: command['track_id'] as String?,
          );
        case 'trim_clip':
          keys(command, {'op', 'clip_id', 'start_frame', 'end_frame'});
          doc = EditingCommands.trim(
            doc,
            text(command, 'clip_id'),
            integer(command, 'start_frame'),
            integer(command, 'end_frame'),
          );
        case 'split_clip':
          keys(command, {'op', 'clip_id', 'frame'});
          doc = EditingCommands.split(
            doc,
            text(command, 'clip_id'),
            integer(command, 'frame'),
          );
        case 'duplicate_clip':
          keys(command, {'op', 'clip_id', 'id', 'index', 'start_frame'});
          text(command, 'clip_id');
          final copy = clip!.copyWith(
            id: id(),
            startFrame: track!.main ? 0 : integer(command, 'start_frame'),
          );
          if (track.main
              ? command.containsKey('start_frame')
              : command.containsKey('index')) {
            throw const FormatException('Invalid duplicate position.');
          }
          doc = track.main
              ? EditingCommands.insertMain(doc, copy, integer(command, 'index'))
              : EditingCommands.place(doc, copy);
        case 'remove_clip':
          keys(command, {'op', 'clip_id'});
          doc = EditingCommands.remove(doc, text(command, 'clip_id'));
        case 'update_clip':
          keys(command, {'op', 'clip_id', 'fields'});
          text(command, 'clip_id');
          const placement = {
            'scale',
            'opacity',
            'x',
            'y',
            'anchor_x',
            'anchor_y',
          };
          const source = {'gain_db', 'fade_in_frames', 'fade_out_frames'};
          var content = clip!.content;
          final f = fields({
            'name',
            ...switch (content) {
              EditingVideoContent() => {...placement, ...source},
              EditingAudioContent() => source,
              EditingTextContent() => {...placement, 'text', 'text_style'},
            },
          });
          double? number(String key) {
            final value = f[key];
            if (value != null && (value is! num || !value.isFinite)) {
              throw FormatException('$key must be finite.');
            }
            return (value as num?)?.toDouble();
          }
          EditingTransform place(EditingTransform transform) =>
              transform.copyWith(
                scale: number('scale'),
                x: number('x'),
                y: number('y'),
                anchorX: number('anchor_x'),
                anchorY: number('anchor_y'),
              );
          if (content is EditingSourceContent) {
            content = content.copyWith(
              gainDb: number('gain_db'),
              fadeInFrames: f.containsKey('fade_in_frames')
                  ? integer(f, 'fade_in_frames')
                  : null,
              fadeOutFrames: f.containsKey('fade_out_frames')
                  ? integer(f, 'fade_out_frames')
                  : null,
            );
            if (content is EditingVideoContent) {
              content = content.copyWith(
                opacity: number('opacity'),
                transform: place(content.transform),
              );
            }
          } else if (content is EditingTextContent) {
            content = content.copyWith(
              text: f['text'] as String?,
              style: f['text_style'] as String?,
              opacity: number('opacity'),
              transform: place(content.transform),
            );
          }
          doc = EditingCommands.update(
            doc,
            clip.copyWith(name: f['name'] as String?, content: content),
          );
        case 'extract_audio':
          keys(command, {'op', 'clip_id', 'track_id'});
          doc = EditingCommands.extractAudio(
            doc,
            text(command, 'clip_id'),
            trackId: command['track_id'] as String?,
          );
        case 'replace_source':
          keys(command, {'op', 'clip_id', 'path', 'production_clip_id'});
          doc = EditingCommands.replace(
            doc,
            text(command, 'clip_id'),
            await resolveSource(command),
            origin: command['production_clip_id'] == null
                ? null
                : EditingOrigin(
                    type: 'production_clip',
                    id: text(command, 'production_clip_id'),
                  ),
          );
        case 'set_ratio':
          keys(command, {'op', 'ratio'});
          doc = EditingCommands.setRatio(doc, text(command, 'ratio'));
        case 'rename':
          keys(command, {'op', 'title'});
          title = text(command, 'title');
        default:
          throw const ToolOperationException(
            'unsupported',
            'Unsupported editing command.',
          );
      }
      doc.validate();
      results.add({
        'op': op,
        'created_clip_ids': doc.clips
            .where((c) => !before.clips.any((b) => b.id == c.id))
            .map((c) => c.id)
            .toList(),
        'created_track_ids': doc.tracks
            .where((t) => !before.tracks.any((b) => b.id == t.id))
            .map((t) => t.id)
            .toList(),
        'changes': changes(before, doc),
      });
    }
    return (document: doc, title: title, result: results);
  }
}
