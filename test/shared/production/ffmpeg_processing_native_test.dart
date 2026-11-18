// 职责: 用显式原生 FFmpeg 验证已有素材处理、序列回编、依赖文件、分段、两遍编码与探测。
// 关联文件:
//   lib/shared/services/ai/ffmpeg/command.dart
//   lib/shared/services/ai/ffmpeg/arguments.dart
//   lib/shared/services/ai/ffmpeg/filters.dart
//   lib/shared/services/ai/files/management.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/ai/ffmpeg/arguments.dart';
import 'package:reveric/shared/services/ai/ffmpeg/command.dart';
import 'package:reveric/shared/services/ai/ffmpeg/filters.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';
import 'package:reveric/shared/services/ai/files/management.dart';
import 'package:reveric/shared/models/tool_permission.dart';

const _binary = String.fromEnvironment('FFMPEG_TEST_BIN');

class _Runner extends FfmpegRunner {
  final calls = <List<String>>[];
  @override
  Future<FfmpegExecutionResult> executeCommand(
    List<String> arguments, {
    required MediaCancellation cancellation,
  }) => _run(arguments, false, cancellation);

  @override
  Future<String> execute(
    List<String> arguments, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    final result = await _run(arguments, probe, cancellation);
    if (result.exitCode != 0) {
      throw StateError(
        'Native FFmpeg failed (${result.exitCode}): ${result.output}',
      );
    }
    return result.output;
  }

  Future<FfmpegExecutionResult> _run(
    List<String> arguments,
    bool probe,
    MediaCancellation cancellation,
  ) async {
    calls.add(arguments.toList());
    final process = await Process.start(
      probe ? p.join(p.dirname(_binary), 'ffprobe') : _binary,
      arguments,
    );
    await cancellation.bind(() async {
      process.kill();
    });
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    try {
      final code = await process.exitCode;
      final stdout = await out, stderr = await err;
      return FfmpegExecutionResult(
        exitCode: code,
        output: probe && code == 0 ? stdout : '$stdout$stderr',
        cancelled: cancellation.cancelled,
      );
    } finally {
      cancellation.unbind();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group(
    'native processing',
    () {
      late Directory support;
      late Directory root;
      late _Runner runner;
      late SessionFiles files;
      late FfmpegCommand command;
      Future<Map<String, dynamic>> run(
        List<String> args, {
        bool probe = false,
      }) async {
        final parsed = FfmpegArguments.parse(args, probe: probe);
        final plan = await command.inspect(parsed);
        await plan.verify();
        final result = await command.run('session', plan, MediaCancellation());
        expect(
          result['ok'],
          true,
          reason: '${result['log']} ${result['error']}',
        );
        if (!probe) {
          expect(result['exit_code'], 0);
          expect(result.containsKey('files'), false);
          expect(result.containsKey('content'), false);
        }
        return result;
      }

      Future<String> source() async {
        final input = File('${root.path}/source.mp4');
        // Fixture generation is outside the AI command's allowed inputs.
        await runner.execute(
          [
            '-f',
            'lavfi',
            '-i',
            'testsrc2=size=96x64:rate=12:duration=1',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:duration=1',
            '-c:v',
            'libx264',
            '-g',
            '4',
            '-pix_fmt',
            'yuv420p',
            '-c:a',
            'aac',
            input.path,
          ],
          probe: false,
          cancellation: MediaCancellation(),
        );
        return input.path;
      }

      setUp(() async {
        support = await Directory.systemTemp.createTemp(
          "ffmpeg-processing-'字-,",
        );
        runner = _Runner();
        support = Directory(await support.resolveSymbolicLinks());
        root = await Directory(
          '${support.path}/file_workspaces/work',
        ).create(recursive: true);
        files = SessionFiles(root: support.path, novelId: 'work');
        command = FfmpegCommand(files, runner);
      });
      tearDown(() => support.delete(recursive: true));
      Future<File> output(String name) =>
          files.resolve('file_workspaces/work/$name');
      Future<Map<String, dynamic>> probeOutput(String name) async =>
          jsonDecode(
                await runner.execute(
                  [
                    '-v',
                    'error',
                    '-show_format',
                    '-show_streams',
                    '-of',
                    'json',
                    (await output(name)).path,
                  ],
                  probe: true,
                  cancellation: MediaCancellation(),
                ),
              )
              as Map<String, dynamic>;

      test(
        'delivers metadata and subtitles with inferred or explicit formats',
        () async {
          final input = await source();
          for (final name in ['meta.ffmeta', 'upper.FFMETA']) {
            await run(['-i', input, name]);
            expect(
              await (await output(name)).readAsString(),
              startsWith(';FFMETADATA1'),
            );
          }
          final subtitle = File('${root.path}/input.srt');
          await subtitle.writeAsString(
            '1\n00:00:00,000 --> 00:00:01,000\nhello\n',
          );
          for (final name in ['out.SRT', 'out.ASS', 'out.SSA', 'out.VTT']) {
            await run(['-i', subtitle.path, name]);
            expect(
              await (await output(name)).readAsString(),
              contains('hello'),
            );
          }
          for (final name in ['video.ffmeta', 'video.srt', 'video.pcm']) {
            await run(['-i', input, '-c:v', 'libx264', '-f', 'mp4', name]);
            final info = await probeOutput(name);
            expect(info['streams'][0]['width'], 96);
            expect(info['streams'][0]['height'], 64);
          }
        },
      );

      test(
        'processes video/audio files, probes frames and runs null analysis',
        () async {
          final input = await source();
          final result = await run([
            '-i',
            input,
            '-vf',
            'drawbox=x=0:y=0:w=16:h=16:color=red:t=fill,fade=t=in:d=0.1',
            '-af',
            'afftdn,loudnorm=I=-16,alimiter',
            '-c:v:0',
            'libx264',
            '-profile:v:0',
            'high',
            '-maxrate:v',
            '1M',
            '-bufsize:v',
            '2M',
            '-metadata:s:a:0',
            'language=zho',
            'processed.mp4',
          ]);
          expect(result['ok'], true);
          final probe = await run([
            '-show_frames',
            '-select_streams',
            'v:0',
            '-read_intervals',
            '0%+0.5',
            '-show_entries',
            'frame=pts_time,key_frame',
            input,
          ], probe: true);
          expect(probe['probe']['frames'], isNotEmpty);
          final analysis = await run([
            '-i',
            input,
            '-vn',
            '-af',
            'volumedetect',
            '-f',
            'null',
            '-',
          ]);
          expect(analysis.containsKey('files'), false);
          expect(analysis['log'], contains('mean_volume'));
          final capabilities = await command.capabilities(MediaCancellation());
          expect(capabilities['decoders'], contains('h264'));
          expect(capabilities['usable_filters'], contains('loudnorm'));
          final help = await command.capabilities(
            MediaCancellation(),
            component: 'encoder=libx264',
          );
          expect(help['help'], contains('libx264'));
        },
      );

      test('round-trips image sequences and creates a palette GIF', () async {
        final input = await source();
        await run([
          '-i',
          input,
          '-vf',
          'fps=3',
          '-frames:v',
          '3',
          'images/f-%03d.png',
        ]);
        await run([
          '-framerate',
          '3',
          '-start_number',
          '1',
          '-i',
          'images/f-%03d.png',
          '-c:v',
          'libx264',
          '-pix_fmt',
          'yuv420p',
          'roundtrip.mp4',
        ]);
        expect(
          double.parse(
            (await probeOutput('roundtrip.mp4'))['format']['duration'],
          ),
          1.0,
        );
        await run([
          '-i',
          input,
          '-filter_complex',
          '[0:v]split[a][b];[a]palettegen[p];[b][p]paletteuse[out]',
          '-map',
          '[out]',
          'preview.gif',
        ]);
        expect(await (await output('preview.gif')).length(), greaterThan(0));
      });

      test(
        'reads original subtitle, text, font and LUT dependencies with escaped paths',
        () async {
          final input = await source();
          final subtitle = File("${root.path}/字 O'Brien.srt");
          await subtitle.writeAsString(
            '1\n00:00:00,000 --> 00:00:00,900\nCaption\n',
          );
          final text = File('${root.path}/label.txt');
          await text.writeAsString('Label');
          final lut = File('${root.path}/look.cube');
          await lut.writeAsString(
            'LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n',
          );
          final font = File('assets/fonts/Literata-Regular.ttf').absolute.path;
          final filter =
              'drawtext=fontfile=${ffmpegFilterValue(font)}:'
              'textfile=${ffmpegFilterValue(text.path)}:fontsize=12,'
              'subtitles=filename=${ffmpegFilterValue(subtitle.path)},'
              'lut3d=file=${ffmpegFilterValue(lut.path)}';
          final result = await run([
            '-i',
            input,
            '-vf',
            filter,
            '-c:v',
            'libx264',
            'captioned.mp4',
          ]);
          expect(result['ok'], true);
          await run(['-i', subtitle.path, '-c:s', 'ass', 'captions.ass']);
          expect(
            await (await output('captions.ass')).readAsString(),
            contains('Caption'),
          );
        },
      );

      test(
        'drawtext without fontfile burns CJK text with the bundled font',
        () async {
          final input = await source();
          final result = await run([
            '-i',
            input,
            '-vf',
            "drawtext=text='她还没变异呢，还是人':fontsize=24:fontcolor=white:x=4:y=4",
            '-frames:v',
            '1',
            'titled.png',
          ]);
          expect(result['ok'], true);
          expect(await (await output('titled.png')).length(), greaterThan(0));
        },
      );

      test(
        'sequence retries after files cleanup while unrelated old numbers remain intact',
        () async {
          final input = await source();
          await Directory('${root.path}/images').create();
          final earlier = await File(
            '${root.path}/images/frame-001.png',
          ).writeAsString('earlier output');
          final later = await File(
            '${root.path}/images/frame-999.png',
          ).writeAsString('later output');
          final args = [
            '-i',
            input,
            '-frames:v',
            '2',
            '-start_number',
            '100',
            'images/frame-%03d.png',
          ];
          await run(args);
          final parsed = FfmpegArguments.parse(args, probe: false);
          await expectLater(
            command.run(
              'session',
              await command.inspect(parsed),
              MediaCancellation(),
            ),
            throwsA(
              isA<ToolOperationException>()
                  .having((e) => e.code, 'code', 'already_exists')
                  .having((e) => e.hint, 'hint', contains('Run files remove')),
            ),
          );
          final managed = ManagedFiles(files, 'session');
          final listing = await managed.select(
            'images/frame-10[01].png',
            remove: false,
          );
          expect(listing.paths, [
            'images/frame-100.png',
            'images/frame-101.png',
          ]);
          final cleanup = await managed.select(
            'images/frame-10[01].png',
            remove: true,
          );
          expect((await cleanup.remove(cancelled: () => false))['ok'], true);
          await run(args);
          expect(
            await (await output('images/frame-100.png')).length(),
            greaterThan(0),
          );
          expect(
            await (await output('images/frame-101.png')).length(),
            greaterThan(0),
          );
          expect(await earlier.readAsString(), 'earlier output');
          expect(await later.readAsString(), 'later output');
        },
      );

      test(
        'concat reads the unchanged list and segments directly into target files',
        () async {
          final input = await source();
          final sourceFile = await files.resolve(input);
          final list = File('${root.path}/parts.txt');
          final escaped = sourceFile.path.replaceAll("'", "'\\''");
          await list.writeAsString("file '$escaped'\nfile '$escaped'\n");
          final originalList = await list.readAsString();
          await run([
            '-f',
            'concat',
            '-safe',
            '0',
            '-i',
            list.path,
            '-c',
            'copy',
            'joined.mp4',
          ]);
          expect(
            double.parse(
              (await probeOutput('joined.mp4'))['format']['duration'],
            ),
            inInclusiveRange(1.9, 2.2),
          );
          expect(await list.readAsString(), originalList);
          await Directory('${root.path}/videos').create();
          final old = await File(
            '${root.path}/videos/part-999.mp4',
          ).writeAsString('old segment');
          await run([
            '-i',
            'joined.mp4',
            '-c',
            'copy',
            '-f',
            'segment',
            '-segment_time',
            '0.5',
            '-reset_timestamps',
            '1',
            '-segment_start_number',
            '5',
            'videos/part-%03d.mp4',
          ]);
          final outputs = await Directory(
            '${root.path}/videos',
          ).list().toList();
          expect(outputs.length, greaterThan(1));
          expect(await File('${root.path}/videos/part-005.mp4').exists(), true);
          expect(await old.readAsString(), 'old segment');
          for (final file in outputs.whereType<File>()) {
            expect(await file.length(), greaterThan(0));
          }
        },
      );

      test(
        'repeated first passes replace explicit statistics and remain usable by pass two',
        () async {
          final input = await source();
          final before = runner.calls.length;
          for (final pass in [1, 1, 2]) {
            await run([
              '-i',
              input,
              '-an',
              '-c:v',
              'libx264',
              '-b:v',
              '100k',
              '-pass',
              '$pass',
              '-passlogfile',
              'media/stats',
              if (pass == 1) ...['-f', 'null', '-'] else 'twopass.mp4',
            ]);
          }
          expect(runner.calls.length - before, 3);
          expect(await File('${root.path}/media/stats-0.log').exists(), true);
          expect(await (await output('twopass.mp4')).length(), greaterThan(0));
        },
      );

      test(
        'repeated first passes reuse default session statistics before pass two',
        () async {
          final input = await source();
          for (final pass in [1, 1, 2]) {
            await run([
              '-i',
              input,
              '-an',
              '-c:v',
              'libx264',
              '-b:v',
              '100k',
              '-pass',
              '$pass',
              if (pass == 1) ...['-f', 'null', '-'] else 'default-pass.mp4',
            ]);
          }
          expect(await File('${root.path}/ffmpeg2pass-0.log').exists(), true);
          expect(
            await (await output('default-pass.mp4')).length(),
            greaterThan(0),
          );
        },
      );

      test(
        'attaches and extracts font files without probing them as media',
        () async {
          final input = await source();
          final font = File('assets/fonts/Literata-Regular.ttf').absolute.path;
          await run([
            '-i',
            input,
            '-c',
            'copy',
            '-attach',
            font,
            '-metadata:s:t',
            'mimetype=application/x-truetype-font',
            'attached.mkv',
          ]);
          await run([
            '-dump_attachment:t:0',
            'font.ttf',
            '-i',
            'attached.mkv',
            '-f',
            'null',
            '-',
          ]);
          expect(
            await (await output('font.ttf')).readAsBytes(),
            await File(font).readAsBytes(),
          );
        },
      );
      test(
        'native failure returns its actual exit code and diagnostic without probing',
        () async {
          final input = await source();
          final before = runner.calls.length;
          final parsed = FfmpegArguments.parse([
            '-i',
            input,
            '-c:v',
            'nonexistent_encoder',
            'bad.mp4',
          ], probe: false);
          final result = await command.run(
            'session',
            await command.inspect(parsed),
            MediaCancellation(),
          );
          expect(result['ok'], false);
          expect(result['exit_code'], isNonZero);
          expect(result['log'], contains('nonexistent_encoder'));
          expect(runner.calls.length - before, 1);
        },
      );
    },
    skip: _binary.isEmpty
        ? 'Set FFMPEG_TEST_BIN for native processing checks.'
        : false,
  );
}
