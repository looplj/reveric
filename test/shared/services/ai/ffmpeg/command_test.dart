// 职责: 验证 execute 直接读写原路径、保留命令结果与失败文件，并保持 probe 行为。
// 关联文件:
//   lib/shared/services/ai/ffmpeg/arguments.dart
//   lib/shared/services/ai/ffmpeg/command.dart
//   lib/shared/services/ai/ffmpeg/outputs.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/services/ai/ffmpeg/arguments.dart';
import 'package:reveric/shared/services/ai/ffmpeg/command.dart';
import 'package:reveric/shared/services/ai/ffmpeg/outputs.dart';
import 'package:reveric/shared/services/ai/ffmpeg/filters.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';

class Runner extends FfmpegRunner {
  final commands = <List<String>>[];
  @override
  Future<String> execute(
    List<String> args, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    commands.add(args);
    if (probe) {
      return jsonEncode({
        'streams': [
          {'codec_type': 'video', 'codec_name': 'png', 'width': 8, 'height': 4},
        ],
        'format': {'duration': '0'},
      });
    }
    if (args.first == '-version') {
      return 'ffmpeg test';
    }
    if (args.first == '-encoders') {
      return ' V..... png PNG\n V....D libx264 AVC';
    }
    if (args.first == '-formats') {
      return ' DE image2 Images';
    }
    if (args.first == '-filters') {
      return ' ... scale V->V';
    }
    if (args.length == 1 || args.contains('-h')) {
      return '';
    }
    await File(
      args.last,
    ).writeAsBytes(img.encodePng(img.Image(width: 8, height: 4)));
    return 'encoded';
  }
}

class _CommandRunner extends Runner {
  FfmpegExecutionResult result = const FfmpegExecutionResult(
    exitCode: 0,
    output: 'encoded',
  );
  String? contents = 'encoded artifact';
  bool waitForCancellation = false;
  Future<void> Function(List<String>)? onExecute;

  @override
  Future<FfmpegExecutionResult> executeCommand(
    List<String> args, {
    required MediaCancellation cancellation,
  }) async {
    commands.add(args);
    await onExecute?.call(args);
    if (contents != null && args.last != '-') {
      await File(args.last).writeAsString(contents!);
    }
    if (waitForCancellation) {
      while (!cancellation.cancelled) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }
    return result;
  }
}

void main() {
  test(
    'capabilities expose file processing without generated inputs',
    () async {
      final result = await FfmpegCommand(
        SessionFiles(novelId: 'work'),
        Runner(),
      ).capabilities(MediaCancellation());
      expect(result['generated_inputs'], false);
      expect(result['allowed_formats'], isNot(contains('lavfi')));
      expect(result['allowed_filters'], contains('scale'));
      expect(result['usable_filters'], contains('scale'));
      for (final source in ['color', 'anullsrc', 'testsrc', 'sine']) {
        expect(result['allowed_filters'], isNot(contains(source)));
        expect(result['usable_filters'], isNot(contains(source)));
      }
    },
  );

  test(
    'advertised filter dependencies and sequence extensions are executable',
    () async {
      final capabilities = await FfmpegCommand(
        SessionFiles(novelId: 'work'),
        Runner(),
      ).capabilities(MediaCancellation());
      final dependencies = (capabilities['filter_dependencies'] as List)
          .cast<String>();
      expect(
        dependencies,
        containsAll(['subtitles:filename', 'subtitles:f', 'ass:f']),
      );
      for (final dependency in dependencies) {
        final parts = dependency.split(':');
        final graph = FfmpegFilterGraph('${parts[0]}=${parts[1]}=resource.dat');
        expect(graph.dependencies, {'resource.dat'}, reason: dependency);
      }
      final extensions = capabilities['image_sequences']['extensions'] as List;
      expect(extensions, containsAll(['.png', '.jpg', '.jpeg', '.webp']));
      for (final extension in extensions) {
        final parsed = FfmpegArguments.parse([
          '-i',
          'in.mp4',
          '-frames:v',
          '1',
          'frame-%d$extension',
        ], probe: false);
        expect(parsed.sequences.values.single.at(0), 'frame-1$extension');
      }
    },
  );

  test(
    'rejects network, scripts, playlists, multiple implicit IO and nonlocal filters before execution',
    () {
      for (final args in <List<String>>[
        ['-i', 'https://example.com/video.mp4', 'out.mp4'],
        ['-i', 'in.mp4', '-vf', 'movie=/secret.png', 'out.mp4'],
        [
          '-i',
          'in.mp4',
          '-filter_complex',
          '[0:v]scale=100:100[a];[a]movie=/secret.mp4',
          'out.mp4',
        ],
        ['-i', 'in.mp4', '-/filter:v', 'script.txt', 'out.mp4'],
        ['-i', 'in.mp4', '-y', 'out.mp4'],
        ['-i', 'in.mp4', '-f', 'tee', 'out.mp4'],
        ['-i', 'in.mp4', '-progress', 'progress.txt', 'out.mp4'],
      ]) {
        expect(
          () => FfmpegArguments.parse(args, probe: false),
          throwsA(isA<ToolOperationException>()),
          reason: args.join(' '),
        );
      }
    },
  );
  test(
    'parses stream labels and quoted expression commas without treating them as filters',
    () {
      final parsed = FfmpegArguments.parse([
        '-ss',
        '00:00:12.500',
        '-i',
        'in.mp4',
        '-vf',
        "scale='min(2048,iw)':-2,crop=100:100",
        '-frames:v',
        '1',
        'frame.jpg',
      ], probe: false);
      expect(parsed.inputs.values, ['in.mp4']);
      expect(parsed.outputs.values, ['frame.jpg']);
      expect(
        () => FfmpegArguments.parse(['-of', 'xml', 'in.mp4'], probe: true),
        throwsA(isA<ToolOperationException>()),
      );
    },
  );
  late Directory support;
  late Directory root;
  late File source;
  late SessionFiles files;
  late _CommandRunner runner;
  late FfmpegCommand command;
  setUp(() async {
    support = await Directory.systemTemp.createTemp('ffmpeg-command-');
    support = Directory(await support.resolveSymbolicLinks());
    root = await Directory(
      '${support.path}/file_workspaces/work',
    ).create(recursive: true);
    source = await File('${root.path}/source.mp4').writeAsBytes([1, 2, 3]);
    files = SessionFiles(root: support.path, novelId: 'work');
    runner = _CommandRunner();
    command = FfmpegCommand(files, runner);
  });
  tearDown(() => support.delete(recursive: true));
  Future<Map<String, dynamic>> run([List<String>? args]) async => command.run(
    'session',
    await command.inspect(
      FfmpegArguments.parse(
        args ?? ['-i', source.path, 'media/out.png'],
        probe: false,
      ),
    ),
    MediaCancellation(),
  );

  test(
    'reads the original input and writes only the requested output without probing or previews',
    () async {
      final result = await run();
      expect(result, {
        'ok': true,
        'status': 'completed',
        'exit_code': 0,
        'log': 'encoded',
        'log_truncated': false,
      });
      expect(runner.commands, hasLength(1));
      final args = runner.commands.single;
      expect(args[args.indexOf('-i') + 1], await source.resolveSymbolicLinks());
      expect(args.last, '${root.path}/media/out.png');
      expect(
        args,
        containsAll([
          '-nostdin',
          '-hide_banner',
          '-protocol_whitelist',
          'file',
        ]),
      );
      expect(args, isNot(contains('-n')));
      expect(
        await File('${root.path}/media/out.png').readAsString(),
        'encoded artifact',
      );
      expect(await Directory('${root.path}/sessions').exists(), false);
      expect(
        (await root.list(recursive: true).toList()).whereType<File>(),
        hasLength(2),
      );
    },
  );

  for (final contents in [null, '']) {
    test(
      'accepts exit zero with ${contents == null ? "missing" : "empty"} output',
      () async {
        runner.contents = contents;
        final result = await run();
        expect(result['ok'], true);
        expect(result['exit_code'], 0);
        expect(runner.commands, hasLength(1));
      },
    );
  }

  test(
    'returns native failure diagnostics and leaves incomplete output in place',
    () async {
      runner.result = const FfmpegExecutionResult(
        exitCode: 23,
        output: 'Invalid encoder: example',
      );
      final result = await run();
      expect(result['ok'], false);
      expect(result['status'], 'failed');
      expect(result['exit_code'], 23);
      expect(result['log'], 'Invalid encoder: example');
      expect(result.containsKey('files'), false);
      expect(
        await File('${root.path}/media/out.png').readAsString(),
        runner.contents,
      );
    },
  );

  test(
    'returns cancellation with the real exit code and retained output',
    () async {
      runner.result = const FfmpegExecutionResult(
        exitCode: 255,
        output: 'Exiting normally, received signal 2.',
        cancelled: true,
      );
      final result = await run();
      expect(result['status'], 'cancelled');
      expect(result['cancelled'], true);
      expect(result['exit_code'], 255);
      expect(result['log'], contains('signal 2'));
      expect(await File('${root.path}/media/out.png').exists(), true);
    },
  );

  test(
    'timeout waits for cancellation and preserves the native result',
    () async {
      command = FfmpegCommand(
        files,
        runner,
        executionTimeout: const Duration(milliseconds: 30),
      );
      runner.waitForCancellation = true;
      runner.result = const FfmpegExecutionResult(
        exitCode: 255,
        output: 'interrupted',
        cancelled: true,
      );
      final result = await run();
      expect(result['status'], 'timed_out');
      expect(result['error_code'], 'deadline_exceeded');
      expect(result['exit_code'], 255);
      expect(result['log'], 'interrupted');
      expect(await File('${root.path}/media/out.png').exists(), true);
    },
  );

  test('startup failure has no invented exit code', () async {
    runner.contents = null;
    runner.result = const FfmpegExecutionResult(
      exitCode: null,
      errorCode: 'start_failed',
      error: 'Native library unavailable',
    );
    final result = await run();
    expect(result['status'], 'start_failed');
    expect(result['exit_code'], null);
    expect(result['error'], 'Native library unavailable');
  });

  test(
    'long failure logs report truncation and preserve the final diagnostic',
    () async {
      runner.result = FfmpegExecutionResult(
        exitCode: 1,
        output: '${'x' * 70000}last error',
      );
      final result = await run();
      expect(result['log_truncated'], true);
      expect((result['log'] as String).length, 16384);
      expect(result['log'], endsWith('last error'));
    },
  );

  test('successful runs keep only the closing summary of the log', () async {
    runner.result = FfmpegExecutionResult(
      exitCode: 0,
      output: '${'Stream #0:0 mapping\n' * 2000}video:109kB audio:0kB',
    );
    final result = await run();
    expect(result['ok'], true);
    expect(result['log_truncated'], true);
    expect((result['log'] as String).length, 2048);
    expect(result['log'], endsWith('video:109kB audio:0kB'));
  });

  test('does not repeat -hide_banner when the caller passes it', () async {
    await run(['-hide_banner', '-i', source.path, 'media/out.png']);
    expect(
      runner.commands.single.where((arg) => arg == '-hide_banner'),
      hasLength(1),
    );
  });

  test(
    'refuses overwriting existing targets and output path escapes',
    () async {
      await run();
      await expectLater(run(), throwsA(isA<ToolOperationException>()));
      for (final path in [
        '../../other/frame.png',
        'C:/outside.png',
        r'\\server\share\outside.png',
        '${root.path}/outside.png',
        '../outside.png',
      ]) {
        await expectLater(
          FfmpegOutputs.resolveTarget(files, 'session', path),
          throwsFormatException,
        );
      }
      expect(
        await File('${root.path}/media/out.png').readAsString(),
        'encoded artifact',
      );
      expect(runner.commands, hasLength(1));
    },
  );

  test(
    'allows repeated first passes with the same statistics prefix',
    () async {
      runner.onExecute = (args) async {
        final prefix = args[args.indexOf('-passlogfile') + 1];
        if (args[args.indexOf('-pass') + 1] == '1') {
          await File('$prefix-0.log').writeAsString('statistics');
        }
      };
      for (final pass in [1, 1, 2]) {
        await run([
          '-i',
          source.path,
          '-c:v',
          'libx264',
          '-pass',
          '$pass',
          '-passlogfile',
          'media/stats',
          if (pass == 1) ...['-f', 'null', '-'] else 'media/pass2.mp4',
        ]);
      }
      expect(runner.commands, hasLength(3));
      expect(runner.commands.map((args) => args[args.indexOf('-pass') + 1]), [
        '1',
        '1',
        '2',
      ]);
      expect(
        await File('${root.path}/media/stats-0.log').readAsString(),
        'statistics',
      );
    },
  );

  test(
    'probe still returns parsed information and a session input copy',
    () async {
      final result = await command.run(
        'session',
        await command.inspect(
          FfmpegArguments.parse(['-show_streams', source.path], probe: true),
        ),
        MediaCancellation(),
      );
      expect(result['probe']['streams'], isNotEmpty);
      expect(result['file_path'], startsWith('sessions/session/'));
      expect(await File('${root.path}/${result['file_path']}').readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );
}
