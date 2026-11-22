// 职责: 验证原生会话的退出码、输出通道、取消和错误脱敏。
// 关联文件:
//   lib/shared/services/production/ffmpeg_runner.dart
import 'dart:async';
import 'dart:convert';
import 'package:ffmpeg_kit_flutter_new/level.dart';
import 'package:ffmpeg_kit_flutter_new/abstract_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:flutter_test/flutter_test.dart';
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
  int? getSessionId() => 7;
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

  for (final probe in [false, true]) {
    test(
      'unreadable native result fails the ${probe ? 'probe' : 'encode'} instead of passing',
      () async {
        await expectLater(
          readFfmpegSessionOutput(
            _Session(null, '', codeError: 'getReturnCode failed.'),
            probe: probe,
            cancellation: MediaCancellation(),
            arguments: const [],
          ),
          throwsA(
            isA<MediaException>()
                .having(
                  (e) => e.reason,
                  'reason',
                  probe
                      ? MediaFailure.invalid_media
                      : MediaFailure.encoding_failed,
                )
                .having((e) => e.nativeSessionId, 'session', 7)
                .having(
                  (e) => e.message,
                  'message',
                  contains('getReturnCode failed.'),
                ),
          ),
        );
      },
    );
  }

  test(
    'unreadable result of a cancelled session reports cancellation',
    () async {
      final token = MediaCancellation();
      await token.cancel();
      await expectLater(
        readFfmpegSessionOutput(
          _Session(null, '', codeError: 'getReturnCode failed.'),
          probe: false,
          cancellation: token,
          arguments: const [],
        ),
        throwsA(
          isA<MediaException>().having(
            (e) => e.reason,
            'reason',
            MediaFailure.cancelled,
          ),
        ),
      );
    },
  );

  test(
    'stopping a queued encode returns while the encode ahead never finishes',
    () async {
      final ahead = Completer<void>();
      final first = FfmpegRunner.serialize(
        MediaCancellation(),
        () => ahead.future,
      );
      final token = MediaCancellation();
      var queuedSawCancel = false;
      final queued = FfmpegRunner.serialize(token, () async {
        queuedSawCancel = token.cancelled;
      });
      var laterStarted = false;
      final later = FfmpegRunner.serialize(MediaCancellation(), () async {
        laterStarted = true;
      });
      await pumpEventQueue();

      await token.cancel();
      await queued.timeout(const Duration(seconds: 1));
      expect(queuedSawCancel, isTrue);
      await pumpEventQueue();
      expect(
        laterStarted,
        isFalse,
        reason: 'later encodes must still wait for the one running ahead',
      );

      ahead.complete();
      await first;
      await later.timeout(const Duration(seconds: 1));
      expect(laterStarted, isTrue);
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
}
