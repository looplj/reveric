// 职责: 执行受控 FFmpeg 命令并返回原生结果，提供独立的媒体探测、能力查询与提帧。
// 关联文件:
//   lib/shared/services/ai/ffmpeg/arguments.dart
//   lib/shared/services/ai/ffmpeg/outputs.dart
//   lib/shared/services/ai/files/session_files.dart
//   lib/shared/services/production/ffmpeg_runner.dart
//   lib/shared/services/ai/ffmpeg/inputs.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;
import '../../../models/tool_permission.dart';
import '../../../models/production/media.dart';
import '../../production/ffmpeg_runner.dart';
import '../../production/contact_sheet.dart';
import '../../production/audio_inspection.dart';
import '../../../models/editing/document.dart' show editingSampleRate;
import '../../production/frame_capture.dart';
import '../media/frames.dart';
import '../files/session_files.dart';
import '../files/command_paths.dart';
import 'arguments.dart';
import 'outputs.dart';
import 'inputs.dart';

class FfmpegCommand {
  FfmpegCommand(
    this.files,
    this.runner, {
    this.executionTimeout = const Duration(minutes: 30),
  });
  final Duration executionTimeout;
  final SessionFiles files;
  final FfmpegRunner runner;

  Future<Map<String, dynamic>> inspectAudio(
    String path,
    Map<String, dynamic> options,
    MediaCancellation cancellation,
  ) async {
    final start = options['start_ms'], end = options['end_ms'];
    final window = options['window_ms'] ?? 100;
    if (start is! int ||
        end is! int ||
        start < 0 ||
        end <= start ||
        end - start > audioInspectionMaxSeconds * 1000 ||
        window is! int ||
        window < 10 ||
        window > 1000) {
      throw const FormatException(
        'Use a positive interval of up to 10000 ms and window_ms from 10 to 1000.',
      );
    }
    final source = await CommandPaths(files).resolve(path);
    final dir = await Directory.systemTemp.createTemp('reveric_ffmpeg_audio_');
    try {
      final output = File('${dir.path}/source.f32');
      await runner.execute(
        [
          '-v',
          'error',
          '-protocol_whitelist',
          'file',
          '-format_whitelist',
          ffmpegFileDemuxers,
          '-ss',
          '${start}ms',
          '-i',
          source.path,
          '-t',
          '${end - start}ms',
          '-map',
          '0:a:0',
          '-ar',
          '$editingSampleRate',
          '-ac',
          '2',
          '-f',
          'f32le',
          output.path,
        ],
        probe: false,
        cancellation: cancellation,
      );
      final bytes = await output.readAsBytes();
      const samplesPerMs = editingSampleRate ~/ 1000;
      if (bytes.length != (end - start) * samplesPerMs * 8) {
        throw const FormatException(
          'The audio stream does not cover the full requested interval.',
        );
      }
      final audio = InspectionAudio(bytes);
      return {
        'ok': true,
        'source_file_path': path,
        'start_ms': start,
        'end_ms': end,
        'window_ms': window,
        ...audio.levels(
          origin: start,
          samplesPerUnit: samplesPerMs,
          window: window,
          unit: 'ms',
        ),
      };
    } finally {
      await dir.delete(recursive: true);
    }
  }

  Future<Map<String, dynamic>> frames(
    String sessionId,
    String path,
    List<int> timestamps,
    MediaCancellation cancellation,
  ) async {
    final positions = contactSheetPositions(timestamps, 'timestamps_ms');
    final execution = _frames(sessionId, path, positions, cancellation);
    return execution.timeout(
      const Duration(minutes: 5),
      onTimeout: () async {
        await cancellation.cancel();
        try {
          await execution;
        } on Object {
          // Wait for native work and temporary-file cleanup before reporting timeout.
        }
        throw const MediaException(MediaFailure.timeout);
      },
    );
  }

  Future<Map<String, dynamic>> _frames(
    String sessionId,
    String path,
    List<int> positions,
    MediaCancellation cancellation,
  ) async {
    if (cancellation.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    final source = await CommandPaths(files).resolve(path);
    final temporary = await Directory.systemTemp.createTemp(
      'reveric_ffmpeg_frames_',
    );
    try {
      final copy = File(
        p.join(temporary.path, 'input${p.extension(source.path)}'),
      );
      final sink = copy.openWrite();
      try {
        await sink.addStream(
          source.openRead().map((bytes) {
            if (cancellation.cancelled) {
              throw const ToolOperationException(
                'cancelled',
                'Frame extraction was cancelled.',
              );
            }
            return bytes;
          }),
        );
      } finally {
        await sink.close();
      }
      // Reuse the restricted probe path so playlists and network protocols stay disabled.
      final parsed = FfmpegArguments.parse([
        '-show_format',
        '-show_streams',
        copy.path,
      ], probe: true);
      final probe = await runner.execute(
        [
          '-v',
          'error',
          '-of',
          'json',
          '-protocol_whitelist',
          'file',
          '-format_whitelist',
          ffmpegFileDemuxers,
          ...parsed.args,
        ],
        probe: true,
        cancellation: cancellation,
      );
      final info = MediaInfo.fromProbe(
        jsonDecode(probe) as Map<String, dynamic>,
      );
      if (!info.hasVideo || info.duration <= Duration.zero) {
        throw const FormatException(
          'frames requires a video with a known positive duration.',
        );
      }
      if (positions.any(
        (time) => time * 1000 >= info.duration.inMicroseconds,
      )) {
        throw const FormatException(
          'timestamps_ms must be before the end of the video.',
        );
      }
      final captures = <Uint8List>[];
      for (var i = 0; i < positions.length; i++) {
        captures.add(
          await captureMediaFrame(
            runner,
            copy.path,
            File('${temporary.path}/frame-$i.png'),
            cancellation,
            timestampUs: positions[i] * 1000,
            detailMaxSide: positions.length == 1 ? contactSheetMaxSide : null,
          ),
        );
      }
      final first = img.decodeImage(captures.first);
      if (first == null) {
        throw const MediaException(MediaFailure.encoding_failed);
      }
      final sheet = await composeContactSheet(
        captures,
        [
          for (final time in positions)
            {'label': '${time}ms', 'timestamp_ms': time},
        ],
        first.width,
        first.height,
      );
      return {
        ...await deliverFrameSheet(files, sessionId, sheet, cancellation),
        'source_file_path': path,
      };
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<Map<String, dynamic>> capabilities(
    MediaCancellation cancellation, {
    String? component,
  }) async {
    if (component != null) {
      if (!RegExp(
        r'^(encoder|decoder|filter|muxer|demuxer|bsf)=[A-Za-z0-9_]+$',
      ).hasMatch(component)) {
        throw const FormatException('component must be kind=name.');
      }
      final help = await runner.execute(
        ['-hide_banner', '-h', component],
        probe: false,
        cancellation: cancellation,
      );
      return {'ok': true, 'component': component, 'help': help};
    }
    Future<String> query(String flag) =>
        runner.execute([flag], probe: false, cancellation: cancellation);
    final version = await query('-version');
    final encoders = await query('-encoders');
    final formats = await query('-formats');
    final filters = await query('-filters');
    final decoders = await query('-decoders');
    final demuxers = await query('-demuxers');
    final muxers = await query('-muxers');
    final hardware = await query('-hwaccels');
    final bsfs = await query('-bsfs');
    List<String> names(String text, String pattern) => RegExp(
      pattern,
      multiLine: true,
    ).allMatches(text).map((m) => m.group(1)!).toList();
    return {
      'ok': true,
      'version': version.split('\n').first,
      'encoders': names(encoders, r'^\s*[VAS][A-Z.]{5}\s+(\S+)'),
      'formats': names(formats, r'^\s*[D .][E .]\s+(\S+)'),
      'filters': names(filters, r'^\s*[TSC.]{2,3}\s+(\S+)'),
      'decoders': names(decoders, r'^\s*[VAS][A-Z.]{5}\s+(\S+)'),
      'demuxers': names(demuxers, r'^\s*D\s+(\S+)'),
      'muxers': names(muxers, r'^\s*E\s+(\S+)'),
      'hardware_acceleration': names(hardware, r'^([a-z][a-z0-9_]*)\s*$'),
      'bitstream_filters': names(bsfs, r'^([a-z][a-z0-9_]*)\s*$'),
      'usable_filters': names(
        filters,
        r'^\s*[TSC.]{2,3}\s+(\S+)',
      ).where(ffmpegFilters.contains).toList(),
      'allowed_filters': ffmpegFilters.toList(),
      'allowed_formats': ffmpegFormats.toList(),
      'allowed_flags': ffmpegFlags.toList(),
      'allowed_value_options': ['-i', ...ffmpegValueOptions],
      'allowed_output_extensions': ffmpegOutputExtensions.toList(),
      'allowed_probe_flags': ffmpegProbeFlags.toList(),
      'allowed_probe_options': ffmpegProbeOptions.toList(),
      'allowed_input_demuxers': ffmpegFileDemuxers.split(','),
      'stream_specifiers': true,
      'filter_dependencies': [
        for (final filter in ffmpegFilterFileOptions.entries)
          for (final option in filter.value) '${filter.key}:$option',
      ],
      'drawtext_default_font': 'built-in CJK font when fontfile is omitted',
      'concat_input': true,
      'generated_inputs': false,
      'null_output': true,
      'two_pass': {
        'passes': [1, 2],
        'codecs': ['libx264'],
        'managed': false,
      },
      'segments': {'max_files': ffmpegMaxSegments},
      'limits': {
        'inputs': ffmpegMaxInputs,
        'input_files': ffmpegMaxInputFiles,
        'output_specs': ffmpegMaxOutputs,
        'arguments': ffmpegMaxArguments,
        'argument_bytes': ffmpegMaxArgumentBytes,
      },
      'image_sequences': {
        'input': true,
        'output': true,
        'placeholders': ['%d', '%0Nd (N=1..9)'],
        'extensions': ffmpegImageSequenceExtensions.toList(),
        'requires_frames_v': true,
        'default_start_number': 1,
        'max_frames': ffmpegMaxSequenceFrames,
      },
    };
  }

  Future<void> validateOutputs(String sessionId, FfmpegArguments parsed) async {
    for (final path in parsed.outputs.values) {
      await FfmpegOutputs.resolveTarget(files, sessionId, path);
    }
    if (parsed.pass != null) {
      await FfmpegOutputs.resolveTarget(
        files,
        sessionId,
        parsed.passLogIndex == null
            ? 'ffmpeg2pass'
            : parsed.args[parsed.passLogIndex!],
        allowExisting: true,
      );
    }
  }

  Future<FfmpegInputs> inspect(
    FfmpegArguments parsed, {
    Future<void> Function(List<String> paths)? authorizeExternal,
  }) =>
      FfmpegInputs.inspect(files, parsed, authorizeExternal: authorizeExternal);

  Future<Map<String, dynamic>> run(
    String sessionId,
    FfmpegInputs plan,
    MediaCancellation cancellation,
  ) async {
    final parsed = plan.parsed;
    final actual = parsed.args.toList();
    final outputs = FfmpegOutputs(files, sessionId, parsed, cancellation);
    try {
      outputs.check();
      await plan.resolveArguments(sessionId, actual, cancellation);
      await outputs.prepare(actual);
      await outputs.validateInputs(plan.paths);
      final command = <String>[
        if (!parsed.probe) ...[
          '-nostdin',
          // The version banner is ~19 KB of build flags and local paths per run.
          if (!actual.contains('-hide_banner')) '-hide_banner',
        ],
      ];
      for (var index = 0; index < actual.length; index++) {
        if (outputs.defaultPassLog case final prefix?
            when parsed.outputs.containsKey(index) ||
                parsed.nullOutputs.contains(index)) {
          command.addAll(['-passlogfile', prefix]);
        }
        if (actual[index] == '-i' ||
            (parsed.probe && parsed.inputs.containsKey(index))) {
          final inputIndex = parsed.probe ? index : index + 1;
          final format = parsed.inputFormats[inputIndex];
          command.addAll([
            '-protocol_whitelist',
            'file',
            '-format_whitelist',
            format == 'concat'
                ? 'concat,$ffmpegFileDemuxers'
                : ffmpegFileDemuxers,
          ]);
        }
        if (parsed.sequences[index] case final sequence?
            when !sequence.segment) {
          command.addAll(['-f', 'image2']);
        }
        command.add(actual[index]);
      }
      if (parsed.probe) {
        if (!actual.contains('-of') && !actual.contains('-print_format')) {
          command.insertAll(0, ['-of', 'json']);
        }
        final execution = runner.execute(
          command,
          probe: true,
          cancellation: cancellation,
        );
        final log = await execution.timeout(
          const Duration(seconds: 30),
          onTimeout: () async {
            await cancellation.cancel();
            try {
              await execution;
            } on Object {
              // Wait for native cancellation before returning the timeout.
            }
            throw const ToolOperationException(
              'deadline_exceeded',
              'Media processing timed out.',
            );
          },
        );
        if (utf8.encode(log).length > 4 * 1024 * 1024) {
          throw const ToolOperationException(
            'resource_exhausted',
            'Probe output exceeds 4 MiB. Narrow show_entries or read_intervals.',
          );
        }
        return {
          'ok': true,
          'probe': jsonDecode(log),
          'file_path': CommandPaths(
            files,
          ).reference(File(actual[parsed.inputs.keys.single])),
        };
      }
      outputs.check();
      outputs.startBudget();
      var timedOut = false;
      final execution = runner.executeCommand(
        command,
        cancellation: cancellation,
      );
      final result = await execution.timeout(
        executionTimeout,
        onTimeout: () async {
          timedOut = true;
          await cancellation.cancel();
          return execution;
        },
      );
      Object? budgetFailure;
      try {
        await outputs.verifyBudget();
      } on Object catch (error) {
        budgetFailure = error;
      }
      final cancelled = result.cancelled || cancellation.cancelled;
      final status = budgetFailure != null
          ? (budgetFailure is ToolOperationException &&
                    budgetFailure.code == 'resource_exhausted'
                ? 'resource_limit'
                : 'execution_failed')
          : timedOut
          ? 'timed_out'
          : cancelled
          ? 'cancelled'
          : result.errorCode ?? (result.exitCode == 0 ? 'completed' : 'failed');
      final log = result.output;
      // Successful runs only need the closing summary; failures keep more
      // context for the diagnostic.
      final logLimit = status == 'completed' ? 2048 : 16384;
      return {
        'ok': status == 'completed',
        'status': status,
        'exit_code': result.exitCode,
        'log': log.length > logLimit
            ? log.substring(log.length - logLimit)
            : log,
        'log_truncated': log.length > logLimit,
        if (status == 'cancelled') 'cancelled': true,
        if (budgetFailure != null) ...{
          'error_code': budgetFailure is ToolOperationException
              ? budgetFailure.code
              : 'internal',
          'error': budgetFailure is ToolOperationException
              ? budgetFailure.message
              : budgetFailure.toString(),
        } else if (timedOut) ...{
          'error_code': 'deadline_exceeded',
          'error': 'Media processing timed out.',
        } else if (result.errorCode != null) ...{
          'error_code': result.errorCode,
          'error': result.error,
        },
      };
    } finally {
      await outputs.dispose();
    }
  }
}
