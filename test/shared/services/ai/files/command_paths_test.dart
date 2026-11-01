// 职责: 验证作品命令路径与应用引用分离并阻止跨作品、绝对写入及链接逃逸。
// 关联文件:
//   lib/shared/services/ai/files/command_paths.dart
//   lib/shared/services/ai/ffmpeg/outputs.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/services/ai/files/command_paths.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';
import 'package:reveric/shared/services/ai/ffmpeg/arguments.dart';
import 'package:reveric/shared/services/ai/ffmpeg/command.dart';
import 'package:reveric/shared/services/ai/ffmpeg/outputs.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';

void main() {
  late Directory root;
  late SessionFiles files;
  late CommandPaths paths;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('command-paths-');
    files = SessionFiles(root: root.path, novelId: 'work');
    paths = CommandPaths(files);
    await Directory(paths.root).create(recursive: true);
  });
  tearDown(() => root.delete(recursive: true));

  test('stored references resolve to the same current-work file', () async {
    final file = await files.allocate('session', '.txt');
    await file.writeAsString('attachment');
    final stored = files.reference(file);
    for (final path in [stored, stored.replaceAll('/', r'\')]) {
      expect(
        (await paths.resolve(path)).path,
        await file.resolveSymbolicLinks(),
      );
      expect(paths.absolute(path, write: true), file.path);
    }
    expect(
      (await paths.resolve(paths.reference(file))).path,
      await file.resolveSymbolicLinks(),
    );
  });

  for (final path in [
    'file_workspaces/other/sessions/s/file.txt',
    'file_workspaces/shared/sessions/s/file.txt',
    'file_workspaces',
    'file_workspaces/work/../other/file.txt',
    r'file_workspaces\other\sessions\s\file.txt',
  ]) {
    test('rejects foreign or malformed stored reference $path', () {
      expect(() => paths.absolute(path), throwsFormatException);
      expect(() => paths.absolute(path, write: true), throwsFormatException);
    });
  }

  test(
    'relative inputs and outputs use the work root including bare filenames',
    () async {
      final input = await File('${paths.root}/input.txt').writeAsString('data');
      expect(
        (await paths.resolve('input.txt')).path,
        await input.resolveSymbolicLinks(),
      );
      final output = await FfmpegOutputs.resolveTarget(
        files,
        'session',
        'out.mp4',
      );
      expect(output.path, '${paths.root}/out.mp4');
      expect(files.reference(output), 'file_workspaces/work/out.mp4');
      expect(paths.reference(output), 'out.mp4');
      final otherSession = await FfmpegOutputs.resolveTarget(
        files,
        'session',
        'sessions/other/out.mp4',
      );
      expect(otherSession.path, '${paths.root}/sessions/other/out.mp4');
    },
  );

  for (final path in [
    '/tmp/out.mp4',
    r'C:\work\out.mp4',
    'C:/work/out.mp4',
    r'\\server\share\out.mp4',
    '../other/out.mp4',
    'C:out.mp4',
  ]) {
    test(
      'rejects unsafe output $path for primary and pass log writes',
      () async {
        await expectLater(
          FfmpegOutputs.resolveTarget(files, 'session', path),
          throwsA(anyOf(isA<FormatException>(), isA<ToolOperationException>())),
        );
        await expectLater(
          () async {
            final parsed = FfmpegArguments.parse([
              '-i',
              'in.mp4',
              '-c:v',
              'libx264',
              '-pass',
              '1',
              '-passlogfile',
              path,
              '-f',
              'null',
              '-',
            ], probe: false);
            await FfmpegCommand(
              files,
              FfmpegRunner(),
            ).validateOutputs('session', parsed);
          },
          throwsA(anyOf(isA<FormatException>(), isA<ToolOperationException>())),
        );
      },
    );
  }

  test('absolute paths within the work remain forbidden outputs', () async {
    await expectLater(
      FfmpegOutputs.resolveTarget(files, 'session', '${paths.root}/out.mp4'),
      throwsFormatException,
    );
  });

  test(
    'relative IO rejects links before traversing another work',
    () async {
      final other = await Directory(
        '${root.path}/file_workspaces/other',
      ).create();
      final kept = await File(
        '${other.path}/keep.txt',
      ).writeAsString('private');
      await Link('${paths.root}/link').create(other.path);
      await expectLater(paths.resolve('link/keep.txt'), throwsFormatException);
      await expectLater(
        paths.resolve('file_workspaces/work/link/keep.txt'),
        throwsFormatException,
      );
      await expectLater(
        FfmpegOutputs.resolveTarget(files, 'session', 'link/new.mp4'),
        throwsFormatException,
      );
      expect(await kept.readAsString(), 'private');
    },
    skip: Platform.isWindows ? 'Windows links require host privileges.' : false,
  );

  test('commands require a work and cannot use shared as their default', () {
    for (final id in [null, '', 'shared']) {
      expect(
        () => CommandPaths(
          SessionFiles(root: root.path, novelId: id),
        ).absolute('a.txt'),
        throwsFormatException,
      );
    }
  });
}
