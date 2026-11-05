// 职责: 验证原生会话与 Linux 系统进程的退出码、输出通道、取消和错误脱敏。
// 关联文件:
//   lib/shared/services/production/ffmpeg_runner.dart
import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/level.dart';
import 'package:ffmpeg_kit_flutter_new/abstract_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';

class _Session implements AbstractSession {
  _Session(
    this.code,
    this.output, {
    this.failure,
    this.outputError,
    this.codeError,
  });
  final int? code;
  final String output;
  final String? failure, outputError, codeError;
  @override
  Future<ReturnCode?> getReturnCode() async {
    if (codeError != null) {
      throw StateError(codeError!);
    }
    return code == null ? null : ReturnCode(code!);
  }

  @override
  Future<String?> getOutput() async {
    if (outputError != null) {
      throw StateError(outputError!);
    }
    return output;
  }

  @override
  Future<String?> getFailStackTrace() async => failure;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final code in [0, 1, 23, 255]) {
    test(
      'native exit $code keeps diagnostics instead of throwing a generic media failure',
      () async {
        final result = await FfmpegExecutionResult.fromSession(
          _Session(code, 'native log'),
          cancelled: false,
        );
        expect(result.exitCode, code);
        expect(result.output, 'native log');
        expect(result.cancelled, code == ReturnCode.cancel);
        expect(result.errorCode, null);
      },
    );
  }
  test('cancellation retains actual native code and diagnostics', () async {
    final result = await FfmpegExecutionResult.fromSession(
      _Session(1, 'interrupted'),
      cancelled: true,
    );
    expect(result.exitCode, 1);
    expect(result.output, 'interrupted');
    expect(result.cancelled, true);
  });
  test(
    'native session failure preserves null code, logs and failure trace',
    () async {
      final result = await FfmpegExecutionResult.fromSession(
        _Session(null, 'before failure', failure: 'native stack'),
        cancelled: false,
      );
      expect(result.exitCode, null);
      expect(result.output, 'before failure');
      expect(result.errorCode, 'execution_failed');
      expect(result.error, 'native stack');
    },
  );
  test(
    'log retrieval failure does not discard an available exit code',
    () async {
      final result = await FfmpegExecutionResult.fromSession(
        _Session(3, '', outputError: 'log retrieval failed'),
        cancelled: false,
      );
      expect(result.exitCode, 3);
      expect(result.error, contains('log retrieval failed'));
      expect(result.errorCode, 'execution_failed');
    },
  );
  test(
    'exit code retrieval failure still returns available native logs',
    () async {
      final result = await FfmpegExecutionResult.fromSession(
        _Session(
          null,
          'encoder diagnostic',
          codeError: 'code retrieval failed',
        ),
        cancelled: false,
      );
      expect(result.exitCode, null);
      expect(result.output, 'encoder diagnostic');
      expect(result.error, contains('code retrieval failed'));
    },
  );

  test('probe JSON survives interleaved native banners and warnings', () {
    final logs = [
      Log(1, Level.avLogInfo, 'ffprobe version n8.1.2\n'),
      Log(1, Level.avLogStderr, '{"streams":['),
      Log(1, Level.avLogWarning, 'warning: metadata {is not JSON}\n'),
      Log(1, Level.avLogStderr, '{"codec_type":"video"}]}'),
    ];
    expect(
      () => jsonDecode(logs.map((l) => l.getMessage()).join()),
      throwsFormatException,
    );
    expect(jsonDecode(ffmpegProbeOutput(logs)), {
      'streams': [
        {'codec_type': 'video'},
      ],
    });
  });

  test('failure details retain the cause but redact paths and URLs', () {
    const mac = '/Users/Writer/My Videos/private.mp4';
    const windows = r'C:\Users\Writer\My Videos\private.mp4';
    final detail = ffmpegFailureDetail(
      "Error opening '$mac': Permission denied\n"
      'Error opening "$windows": Access denied\n'
      "Cannot open '/tmp/private data/output.mp4'\n"
      'Request https://user:secret@example.test/video?token=private failed',
      [mac, windows],
    );
    expect(detail, contains('Permission denied'));
    expect(detail, contains('Access denied'));
    expect(detail, contains('<path>'));
    expect(detail, contains('<url>'));
    expect(detail, isNot(contains('Writer')));
    expect(detail, isNot(contains('private')));
    expect(detail, isNot(contains('secret')));
  });

  test('long native errors retain the final diagnostic within a bound', () {
    final detail = ffmpegFailureDetail('${'x' * 10000}\nencoder failed', []);
    expect(detail, endsWith('encoder failed'));
    expect(detail.length, lessThan(4200));
  });

  group('Linux system binaries', skip: !Platform.isLinux, () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('ffmpeg-runner-');
    });

    tearDown(() async {
      await root.delete(recursive: true);
    });

    Future<String> script(String name, String body) async {
      final file = File(p.join(root.path, name));
      await file.writeAsString('#!/bin/sh\n$body');
      final chmod = await Process.run('chmod', ['+x', file.path]);
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
      return file.path;
    }

    FfmpegRunner runner(String executable) => FfmpegRunner(
      ffmpegExecutable: executable,
      ffprobeExecutable: executable,
    );

    test(
      'probe reads JSON from stdout and ignores stderr diagnostics',
      () async {
        final executable = await script(
          'ffprobe',
          "printf '%s' '{\"streams\":[]}'\nprintf 'banner' >&2\n",
        );
        final output = await runner(executable).execute(
          ['-of', 'json', '/tmp/in.mp4'],
          probe: true,
          cancellation: MediaCancellation(),
        );
        expect(jsonDecode(output), {'streams': <Object>[]});
      },
    );

    test(
      'encode keeps both channels in the log and maps a failed exit',
      () async {
        final executable = await script(
          'ffmpeg',
          "printf 'frame info\\n'\n"
              "printf 'Error opening /tmp/private.mp4: Permission denied\\n' >&2\n"
              'exit 3\n',
        );
        final failure = await runner(executable)
            .execute(
              ['-y', '-i', '/tmp/private.mp4', '/tmp/out.mp4'],
              probe: false,
              cancellation: MediaCancellation(),
            )
            .then<Object?>((value) => value, onError: (Object error) => error);
        expect(failure, isA<MediaException>());
        final media = failure! as MediaException;
        expect(media.reason, MediaFailure.encoding_failed);
        expect(media.nativeExitCode, 3);
        expect(media.message, contains('Permission denied'));
        expect(media.message, isNot(contains('private')));
        expect(media.nativeLog, contains('frame info'));
      },
    );

    test('command reports the real exit code and combined output', () async {
      final executable = await script(
        'ffmpeg',
        "printf 'out\\n'\nprintf 'err\\n' >&2\nexit 7\n",
      );
      final result = await runner(
        executable,
      ).executeCommand(['-version'], cancellation: MediaCancellation());
      expect(result.exitCode, 7);
      expect(result.output, contains('out'));
      expect(result.output, contains('err'));
      expect(result.errorCode, isNull);
    });

    test('missing executable is reported as tool_unavailable', () async {
      final failure = await runner(p.join(root.path, 'missing-ffmpeg'))
          .execute(['-version'], probe: true, cancellation: MediaCancellation())
          .then<Object?>((value) => value, onError: (Object error) => error);
      expect(failure, isA<MediaException>());
      expect(
        (failure! as MediaException).reason,
        MediaFailure.tool_unavailable,
      );
      expect((failure as MediaException).message, contains('missing-ffmpeg'));
    });

    test('cancellation kills the system process', () async {
      final executable = await script('ffmpeg', 'exec sleep 60\n');
      final cancellation = MediaCancellation();
      final execution = runner(executable).execute(
        ['-y', '/tmp/out.mp4'],
        probe: false,
        cancellation: cancellation,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await cancellation.cancel();
      await expectLater(
        execution,
        throwsA(
          isA<MediaException>().having(
            (error) => error.reason,
            'reason',
            MediaFailure.cancelled,
          ),
        ),
      );
    });
  });
}
