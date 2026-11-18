// 职责: 验证扩展参数的作用域、文件依赖展开、输入身份检查及受控 IO 边界。
// 关联文件:
//   lib/shared/services/ai/ffmpeg/arguments.dart
//   lib/shared/services/ai/ffmpeg/filters.dart
//   lib/shared/services/ai/ffmpeg/inputs.dart
//   lib/shared/services/ai/ffmpeg/command.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/services/ai/ffmpeg/arguments.dart';
import 'package:reveric/shared/services/ai/ffmpeg/command.dart';
import 'package:reveric/shared/services/ai/ffmpeg/filters.dart';
import 'package:reveric/shared/services/ai/ffmpeg/inputs.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';

class _InputCaptureRunner extends FfmpegRunner {
  final inputNames = <List<String>>[];

  @override
  Future<FfmpegExecutionResult> executeCommand(
    List<String> args, {
    required MediaCancellation cancellation,
  }) async {
    final template = args[args.indexOf('-i') + 1];
    inputNames.add(
      (await File(template).parent.list().toList())
          .map((file) => file.uri.pathSegments.last)
          .toList()
        ..sort(),
    );
    return const FfmpegExecutionResult(exitCode: 0);
  }
}

void main() {
  FfmpegArguments parse(List<String> args) =>
      FfmpegArguments.parse(args, probe: false);
  test(
    'processing parameters preserve per-stream values and negative mappings',
    () {
      final value = parse([
        '-hwaccel',
        'videotoolbox',
        '-i',
        'in.mkv',
        '-map',
        '0',
        '-map',
        '-0:s',
        '-c:v:0',
        'libx264',
        '-profile:v:0',
        'high',
        '-level:v:0',
        '4.1',
        '-maxrate:v',
        '2M',
        '-bufsize:v',
        '4M',
        '-g',
        '24',
        '-x264-params',
        'keyint=24:scenecut=0',
        '-metadata:s:a:0',
        'language=zho',
        '-disposition:a:0',
        'default',
        '-vf',
        'hqdn3d,unsharp,fade=t=in:d=0.2',
        '-af',
        'afftdn,loudnorm=I=-16,alimiter',
        'out.mp4',
      ]);
      expect(value.inputs.values, ['in.mkv']);
      expect(value.outputs.values, ['out.mp4']);
      expect(value.graphs, hasLength(2));
      final probe = FfmpegArguments.parse([
        '-show_frames',
        '-show_packets',
        '-show_chapters',
        '-read_intervals',
        '1%+2',
        '-show_entries',
        'frame=pts_time,key_frame',
        'in.mp4',
      ], probe: true);
      expect(probe.inputs.values, ['in.mp4']);
    },
  );

  test('null sinks allow analysis without a file output', () {
    final analysis = parse([
      '-i',
      'in.wav',
      '-af',
      'silencedetect',
      '-f',
      'null',
      '-',
    ]);
    expect(analysis.outputs, isEmpty);
    expect(analysis.nullOutputs, hasLength(1));
  });

  test(
    'quality scales stay codec dependent and fps modes match supported values',
    () {
      for (final quality in ['-2.5', '0', '100']) {
        expect(
          () => parse(['-i', 'in.mp4', '-q:v', quality, 'out.mp4']),
          returnsNormally,
        );
      }
      for (final quality in ['NaN', 'Infinity', '-Infinity']) {
        expect(
          () => parse(['-i', 'in.mp4', '-q:v', quality, 'out.mp4']),
          throwsFormatException,
        );
      }
      for (final mode in ['passthrough', 'cfr', 'vfr', 'auto', 'drop']) {
        expect(
          () => parse(['-i', 'in.mp4', '-fps_mode', mode, 'out.mp4']),
          returnsNormally,
        );
      }
    },
  );

  test('lavfi inputs and source filters are rejected in every graph entry', () {
    for (final source in [
      'color',
      'anullsrc',
      'testsrc',
      'testsrc2',
      'smptebars',
      'smptehdbars',
      'rgbtestsrc',
      'nullsrc',
      'sine',
      'anoisesrc',
      'aevalsrc',
      'color@background=c=black:s=16x16:d=1',
      'anullsrc@silent=r=48000:cl=stereo',
    ]) {
      for (final args in <List<String>>[
        ['-f', 'lavfi', '-i', source, 'out.mp4'],
        ['-filter_complex', '$source[out]', '-map', '[out]', 'out.mp4'],
        for (final option in ['-vf', '-af', '-filter:v:0', '-filter_complex'])
          ['-i', 'in.mp4', option, source, 'out.mp4'],
      ]) {
        expect(
          () => parse(args),
          throwsA(
            isA<ToolOperationException>().having(
              (error) => error.code,
              'code',
              'unsupported',
            ),
          ),
          reason: '$args',
        );
      }
    }
    expect(
      () => FfmpegArguments.parse(['-f', 'lavfi', 'color'], probe: true),
      throwsA(isA<ToolOperationException>()),
    );
    expect(
      () => parse(['-filter_complex', 'scale=16:16', 'out.mp4']),
      throwsFormatException,
    );
    expect(
      () => parse(['-i', 'in.mp4', '-vf', 'scale=16:16', 'out.mp4']),
      returnsNormally,
    );
  });

  test(
    'network, hidden writes, scripts and unrestricted device paths stay rejected',
    () {
      for (final args in <List<String>>[
        ['-i', 'https://example.com/in.mp4', 'out.mp4'],
        ['-i', 'in.mp4', '-y', 'out.mp4'],
        ['-i', 'in.mp4', '-report', 'out.mp4'],
        ['-i', 'in.mp4', '-vf', 'movie=other.mp4', 'out.mp4'],
        ['-i', 'in.mp4', '-vf', 'curves=plot=outside.txt', 'out.mp4'],
        ['-i', 'in.mp4', '-vf', 'drawtext=/text=outside.txt', 'out.mp4'],
        ['-i', 'in.mp4', '-vf', 'scale=/w=outside.txt', 'out.mp4'],
        [
          '-i',
          'in.mp4',
          '-vf',
          'subtitles=f=https\\://example.com/a.srt',
          'out.mp4',
        ],
        ['-i', 'in.mp4', '-x264-params', 'stats=outside.txt', 'out.mp4'],
        ['-i', 'in.mp4', '-x265-params', 'csv=outside.csv', 'out.mp4'],
        ['-f', 'avfoundation', '-i', '0', 'out.mp4'],
        ['-init_hw_device', 'opencl=dev:/outside', '-i', 'in.mp4', 'out.mp4'],
        ['-i', 'in.mp4', '-f', 'hls', 'out.mp4'],
        ['-i', 'in.mp4', '-segment_list', 'outside.txt', 'out.mp4'],
      ]) {
        expect(() => parse(args), throwsA(isA<Exception>()), reason: '$args');
      }
    },
  );

  test('disabled filters are rejected through every filter entry', () {
    for (final graph in [
      'deshake=filename=/outside/a.docx',
      'deshake=-1:-1:-1:-1:16:16:mirror:8:125:0:/outside/a.docx',
      'deshake@stabilize=filename=/outside/a.docx',
      'deshake=filename=${ffmpegFilterValue(r'C:\Users\user\Documents\a.docx')}',
      'deshake',
      'loop',
      'loop=loop=-1:size=1:start=0',
      'loop=-1:1:0',
      'loop@repeat=loop=-1:size=1:start=0',
      'aloop',
      'aloop=loop=-1:size=1024:start=0',
      'aloop=-1:1024:0',
      'aloop@repeat=loop=-1:size=1024:start=0',
    ]) {
      for (final args in <List<String>>[
        for (final option in ['-vf', '-af', '-filter:v:0', '-filter_complex'])
          ['-i', 'in.mp4', option, graph, 'out.mp4'],
        [
          '-i',
          'in.mp4',
          '-filter_complex',
          '[0:v]$graph[out]',
          '-map',
          '[out]',
          'out.mp4',
        ],
      ]) {
        expect(
          () => parse(args),
          throwsA(
            isA<ToolOperationException>().having(
              (error) => error.code,
              'code',
              'unsupported',
            ),
          ),
          reason: '$args',
        );
      }
    }
    expect(
      () => parse(['-i', 'in.mp4', '-vf', 'hqdn3d,unsharp', 'out.mp4']),
      returnsNormally,
    );
  });

  test('input looping options are rejected for every repetition count', () {
    for (final option in [
      '-loop',
      '-stream_loop',
      '-loop:v:0',
      '-stream_loop:0',
    ]) {
      for (final count in ['-1', '0', '1', '2']) {
        final args = [option, count, '-i', 'in.mp4', '-t', '1', 'out.mp4'];
        expect(
          () => parse(args),
          throwsA(
            isA<ToolOperationException>().having(
              (error) => error.code,
              'code',
              'unsupported',
            ),
          ),
          reason: '$args',
        );
      }
    }
    expect(
      () => parse(['-i', 'in.mp4', '-t', '1', 'out.mp4']),
      returnsNormally,
    );
  });

  test('filter option file loading is rejected after graph decoding', () {
    for (final graph in [
      "scale='/w=/outside/value.txt'",
      r'eq=\/brightness=/outside/value.txt',
      "eq='/brightness=/outside/value.txt'",
      r'eq=brightness=0:\/contrast=/outside/value.txt',
      "eq=brightness=0:'/contrast=/outside/value.txt'",
      "eq=' /brightness = /outside/value.txt'",
      "eq='\t/brightness\t=/outside/value.txt'",
      r'eq=\ /brightness=/outside/value.txt',
      "eq@adjust='/brightness=/outside/value.txt'",
      "volume='/volume=/outside/value.txt'",
      "drawtext='/text=/outside/value.txt'",
      'eq=/brightness=${ffmpegFilterValue(r'C:\Users\user\value.txt')}',
    ]) {
      for (final args in <List<String>>[
        for (final option in ['-vf', '-af', '-filter:v:0', '-filter_complex'])
          ['-i', 'in.mp4', option, graph, 'out.mp4'],
        [
          '-i',
          'in.mp4',
          '-filter_complex',
          '[0:v]$graph[out]',
          '-map',
          '[out]',
          'out.mp4',
        ],
      ]) {
        expect(
          () => parse(args),
          throwsA(
            isA<ToolOperationException>().having(
              (error) => error.code,
              'code',
              'unsupported',
            ),
          ),
          reason: '$args',
        );
      }
    }
  });

  test(
    'filter option checks preserve expressions and literal file-like text',
    () {
      for (final text in [
        'scale=1280:720',
        "scale=w='min(1280,iw)':h=-2",
        'eq=brightness=0:contrast=1',
        'volume=0.5',
        'null',
      ]) {
        final graph = FfmpegFilterGraph(text);
        expect(graph.dependencies, isEmpty);
        expect(graph.rewrite({}), text);
      }
      const literal = 'example:/w=/outside/value.txt';
      final text = 'drawtext=text=${ffmpegFilterValue(literal)}';
      final graph = FfmpegFilterGraph(text);
      expect(graph.dependencies, isEmpty);
      expect(
        graph.rewrite({}, defaultFont: '/fonts/a.ttf'),
        'drawtext=fontfile=/fonts/a.ttf:text=${ffmpegFilterValue(literal)}',
      );
      expect(
        FfmpegFilterGraph('subtitles=/outside/subtitle.srt').dependencies,
        {'/outside/subtitle.srt'},
      );
    },
  );

  test(
    'filter escaping round-trips Windows and POSIX paths with syntax characters',
    () {
      for (final path in [
        r"C:\媒体\O'Brien [a],b;字幕.srt",
        "/tmp/a:b's [字],x.srt",
      ]) {
        final graph = FfmpegFilterGraph(
          '[0:v]subtitles=filename=${ffmpegFilterValue(path)}[out]',
        );
        expect(graph.dependencies, {path});
        const replacement = r"C:\temp\O'Brien\字幕.srt";
        final rewritten = FfmpegFilterGraph(graph.rewrite({path: replacement}));
        expect(rewritten.dependencies, {replacement});
      }
      expect(FfmpegFilterGraph('subtitles=f=subtitle.srt').dependencies, {
        'subtitle.srt',
      });
    },
  );

  late Directory support;
  late Directory root;
  test(
    'parentheses cannot hide a filter separator from dependency validation',
    () {
      expect(
        () => parse([
          '-i',
          'in.mp4',
          '-vf',
          "scale=w='min(16,iw)':h=-2",
          'out.mp4',
        ]),
        returnsNormally,
      );
      expect(
        () => parse([
          '-i',
          'in.mp4',
          '-vf',
          'scale=w=min(16,iw):h=-2',
          'out.mp4',
        ]),
        throwsA(isA<Exception>()),
      );
      expect(
        () => parse([
          '-i',
          'in.mp4',
          '-vf',
          'scale=w=(1,movie=outside.mp4)',
          'out.mp4',
        ]),
        throwsA(isA<Exception>()),
      );
    },
  );
  late SessionFiles files;
  setUp(() async {
    support = await Directory.systemTemp.createTemp('ffmpeg-input-test-');
    support = Directory(await support.resolveSymbolicLinks());
    root = await Directory(
      '${support.path}/file_workspaces/work',
    ).create(recursive: true);
    files = SessionFiles(root: support.path, novelId: 'work');
  });
  tearDown(() => support.delete(recursive: true));

  test(
    'sequence changes invalidate approval instead of silently reading new files',
    () async {
      for (final n in [1, 2]) {
        await File('${root.path}/frame-$n.png').writeAsBytes([n]);
      }
      final parsed = parse(['-i', 'frame-%d.png', '-f', 'null', '-']);
      final runner = _InputCaptureRunner();
      final command = FfmpegCommand(files, runner);
      final first = await command.inspect(parsed);
      await File('${root.path}/frame-3.png').writeAsBytes([3]);
      final second = await command.inspect(parsed);
      expect(first.identities, hasLength(2));
      expect(second.identities, hasLength(3));
      expect(() => first.identities.clear(), throwsUnsupportedError);
      expect(() => first.paths.clear(), throwsUnsupportedError);
      await expectLater(first.verify(), throwsA(isA<ToolOperationException>()));
      await second.verify();
      expect(
        (await command.run('session', second, MediaCancellation()))['ok'],
        true,
      );
      expect(runner.inputNames, [
        ['frame-1.png', 'frame-2.png', 'frame-3.png'],
      ]);
    },
  );

  test(
    'sequence start numbers resolve to original files without staging',
    () async {
      for (final n in [10, 11, 12]) {
        await File('${root.path}/frame-$n.png').writeAsBytes([n]);
      }
      final parsed = parse([
        '-framerate',
        '24',
        '-start_number',
        '10',
        '-i',
        'frame-%02d.png',
        'out.mp4',
      ]);
      final command = FfmpegCommand(files, FfmpegRunner());
      final plan = await command.inspect(parsed);
      expect(plan.identities, hasLength(3));
      final actual = parsed.args.toList();
      await plan.resolveArguments('session', actual, MediaCancellation());
      expect(actual[5], '${root.path}/frame-%02d.png');
      expect(await File(actual[5].replaceFirst('%02d', '10')).readAsBytes(), [
        10,
      ]);
      await File('${root.path}/frame-11.png').writeAsBytes([0, 1]);
      await expectLater(plan.verify(), throwsA(isA<Exception>()));
      await File('${root.path}/frame-11.png').delete();
      await expectLater(
        FfmpegInputs.inspect(files, parsed),
        throwsFormatException,
      );
    },
  );

  test(
    'concat inspection resolves dependencies without rewriting the list or copying files',
    () async {
      await File('${root.path}/a file.mp4').writeAsBytes([1]);
      await File('${root.path}/b.mp4').writeAsBytes([2]);
      await File('${root.path}/list.txt').writeAsString(
        "ffconcat version 1.0\nfile 'a file.mp4'\ninpoint 0\noutpoint 1\nfile b.mp4\n",
      );
      final parsed = parse([
        '-f',
        'concat',
        '-i',
        'list.txt',
        '-c',
        'copy',
        'out.mp4',
      ]);
      final command = FfmpegCommand(files, FfmpegRunner());
      final plan = await command.inspect(parsed);
      expect(plan.identities, hasLength(3));
      final actual = parsed.args.toList();
      await plan.resolveArguments('session', actual, MediaCancellation());
      final text = await File(actual[3]).readAsString();
      expect(text, contains('inpoint 0\noutpoint 1'));
      expect(text, contains("file 'a file.mp4'"));
      expect(text, isNot(contains('option format_whitelist')));
      expect(actual[3], '${root.path}/list.txt');
      expect((await root.list().toList()).whereType<File>(), hasLength(3));
      await File(
        '${root.path}/nested.txt',
      ).writeAsString('ffconcat version 1.0\nfile b.mp4\n');
      await File('${root.path}/list.txt').writeAsString('file nested.txt');
      await expectLater(
        FfmpegInputs.inspect(files, parsed),
        throwsA(isA<ToolOperationException>()),
      );
      await File(
        '${root.path}/list.txt',
      ).writeAsString('file https://example.com/x.mp4');
      await expectLater(
        FfmpegInputs.inspect(files, parsed),
        throwsA(isA<Exception>()),
      );
    },
  );

  test(
    'filter dependencies and attachments resolve to the original files',
    () async {
      for (final name in [
        'in.mp4',
        'sub.srt',
        'font.ttf',
        'text.txt',
        'look.cube',
      ]) {
        await File('${root.path}/$name').writeAsString(name);
      }
      final parsed = parse([
        '-i',
        'in.mp4',
        '-vf',
        'drawtext=fontfile=font.ttf:textfile=text.txt,subtitles=sub.srt,lut3d=look.cube',
        '-attach',
        'font.ttf',
        '-metadata:s:t',
        'mimetype=application/x-truetype-font',
        'out.mkv',
      ]);
      final command = FfmpegCommand(files, FfmpegRunner());
      final plan = await command.inspect(parsed);
      expect(plan.identities, hasLength(5));
      final actual = parsed.args.toList();
      await plan.resolveArguments('session', actual, MediaCancellation());
      for (final path in FfmpegFilterGraph(actual[3]).dependencies) {
        expect(path, startsWith(files.root));
        expect(await File(path).exists(), true);
      }
      expect(actual[5], '${root.path}/font.ttf');
      final cancelled = MediaCancellation();
      await cancelled.cancel();
      await expectLater(
        plan.resolveArguments('session', actual, cancelled),
        throwsA(isA<Exception>()),
      );
    },
  );
  test('drawtext without fontfile resolves to the bundled font', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await File('${root.path}/in.mp4').writeAsString('data');
    await File('${root.path}/font.ttf').writeAsString('font');
    final parsed = parse([
      '-i',
      'in.mp4',
      '-vf',
      "drawtext=text='标题，测试':x=10,drawtext=fontfile=font.ttf:text=B,scale=2:2",
      'out.mp4',
    ]);
    var approvals = 0;
    final plan = await FfmpegCommand(files, FfmpegRunner()).inspect(
      parsed,
      authorizeExternal: (_) async {
        approvals++;
      },
    );
    expect(approvals, 0);
    final actual = parsed.args.toList();
    await plan.resolveArguments('session', actual, MediaCancellation());
    final segments = ffmpegSplit(actual[3], ',;');
    final graph = FfmpegFilterGraph(actual[3]);
    final fonts = graph.dependencies.where((p) => p.endsWith('.ttf')).toList();
    expect(fonts, hasLength(2));
    final bundled = fonts.singleWhere((p) => !p.startsWith(root.path));
    expect(bundled, endsWith('LXGWWenKai-Regular.ttf'));
    expect(await File(bundled).length(), greaterThan(1000000));
    expect(segments[0], startsWith('drawtext=fontfile='));
    expect(segments[2], contains(ffmpegFilterValue('${root.path}/font.ttf')));
    expect(segments[4], 'scale=2:2');
    expect(graph.usesDefaultFont, isFalse);
    expect(
      () => FfmpegFilterGraph('drawtext=text=A').rewrite({}),
      throwsStateError,
    );
  });

  test(
    'local concat, sequence, filters and attachments require no external approval',
    () async {
      for (final name in [
        'clip.mp4',
        'frame-1.png',
        'font.ttf',
        'sub.srt',
        'text.txt',
      ]) {
        await File('${root.path}/$name').writeAsString('data');
      }
      await File('${root.path}/list.txt').writeAsString('file clip.mp4');
      var approvals = 0;
      final command = FfmpegCommand(files, FfmpegRunner());
      final plan = await command.inspect(
        parse([
          '-f',
          'concat',
          '-i',
          'list.txt',
          '-i',
          'frame-%d.png',
          '-vf',
          'drawtext=fontfile=font.ttf:textfile=text.txt,subtitles=sub.srt',
          '-attach',
          'font.ttf',
          'out.mkv',
        ]),
        authorizeExternal: (_) async {
          approvals++;
        },
      );
      await plan.verify();
      expect(approvals, 0);
      expect(plan.identities, hasLength(6));
    },
  );

  test(
    'absolute paths inside the current work still require approval',
    () async {
      final source = await File('${root.path}/clip.mp4').writeAsString('data');
      final batches = <List<String>>[];
      await FfmpegCommand(files, FfmpegRunner()).inspect(
        parse(['-i', source.path, 'out.mp4']),
        authorizeExternal: (paths) async {
          batches.add(paths);
        },
      );
      expect(batches, [
        [source.path],
      ]);
    },
  );

  for (final kind in ['concat', 'sequence']) {
    test(
      'external $kind authorization happens before reading or enumerating',
      () async {
        final external = await Directory.systemTemp.createTemp(
          'external-input-',
        );
        addTearDown(() => external.delete(recursive: true));
        final path = kind == 'concat'
            ? '${external.path}/list.txt'
            : '${external.path}/frame-%d.png';
        if (kind == 'concat') {
          await File(
            path,
          ).writeAsString('invalid directive that must not be read');
        } else {
          await Directory('${external.path}/frame-1.png').create();
        }
        final denied = ToolOperationException(
          'permission_denied',
          'Denied before inspecting',
        );
        await expectLater(
          FfmpegCommand(files, FfmpegRunner()).inspect(
            parse([
              if (kind == 'concat') ...['-f', 'concat'],
              '-i',
              path,
              'out.mp4',
            ]),
            authorizeExternal: (_) async {
              throw denied;
            },
          ),
          throwsA(same(denied)),
        );
      },
    );
  }

  test(
    'concat external children receive a separate batch and new targets invalidate approval',
    () async {
      final outside = await Directory.systemTemp.createTemp('concat-external-');
      addTearDown(() => outside.delete(recursive: true));
      final first = await File(
        '${outside.path}/first.mp4',
      ).writeAsString('data');
      final second = await File(
        '${outside.path}/second.mp4',
      ).writeAsString('data');
      final list = await File(
        '${root.path}/list.txt',
      ).writeAsString("file '${first.path}'");
      final requests = <List<String>>[];
      final command = FfmpegCommand(files, FfmpegRunner());
      final plan = await command.inspect(
        parse(['-f', 'concat', '-i', 'list.txt', 'out.mp4']),
        authorizeExternal: (paths) async {
          requests.add(paths);
        },
      );
      expect(requests, [
        [first.path],
      ]);
      await list.writeAsString("file '${second.path}'");
      await expectLater(
        plan.verify(),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'conflict',
          ),
        ),
      );
      expect(requests, hasLength(1));
    },
  );
  for (final kind in ['concat', 'sequence']) {
    test(
      'verification refuses a retargeted external $kind parent before inspection',
      () async {
        final first = await Directory('${support.path}/first').create();
        final second = await Directory('${support.path}/second').create();
        if (kind == 'concat') {
          await File('${first.path}/list.txt').writeAsString('file clip.mp4');
          await File('${first.path}/clip.mp4').writeAsString('data');
          await File(
            '${second.path}/list.txt',
          ).writeAsString('invalid directive');
        } else {
          await File('${first.path}/frame-1.png').writeAsString('data');
          await Directory('${second.path}/frame-1.png').create();
        }
        final alias = await Link('${support.path}/alias').create(first.path);
        final path =
            '${alias.path}/${kind == 'concat' ? 'list.txt' : 'frame-%d.png'}';
        final plan = await FfmpegCommand(files, FfmpegRunner()).inspect(
          parse([
            if (kind == 'concat') ...['-f', 'concat'],
            '-i',
            path,
            'out.mp4',
          ]),
          authorizeExternal: (_) async {},
        );
        await alias.delete();
        await alias.create(second.path);
        await expectLater(
          plan.verify(),
          throwsA(
            isA<ToolOperationException>().having(
              (e) => e.code,
              'code',
              'conflict',
            ),
          ),
        );
      },
      skip: Platform.isWindows
          ? 'Windows links require host privileges.'
          : false,
    );
  }
  test(
    'later concat inputs are rechecked after earlier child approval waits',
    () async {
      final external = await Directory('${support.path}/external').create();
      final first = await File(
        '${external.path}/first.txt',
      ).writeAsString('file first.mp4');
      await File('${external.path}/first.mp4').writeAsString('data');
      final second = await File(
        '${external.path}/second.txt',
      ).writeAsString('file second.mp4');
      await File('${external.path}/second.mp4').writeAsString('data');
      final replacement = await File(
        '${external.path}/replacement.txt',
      ).writeAsString('invalid directive');
      final alias = await Link(
        '${external.path}/alias.txt',
      ).create(second.path);
      var batches = 0;
      await expectLater(
        FfmpegCommand(files, FfmpegRunner()).inspect(
          parse([
            '-f',
            'concat',
            '-i',
            first.path,
            '-f',
            'concat',
            '-i',
            alias.path,
            'out.mp4',
          ]),
          authorizeExternal: (_) async {
            if (++batches == 2) {
              await alias.delete();
              await alias.create(replacement.path);
            }
          },
        ),
        throwsA(
          isA<ToolOperationException>().having(
            (e) => e.code,
            'code',
            'conflict',
          ),
        ),
      );
      expect(batches, 2);
    },
    skip: Platform.isWindows ? 'Windows links require host privileges.' : false,
  );
}
