// 职责: 执行可取消的原生媒体会话，保留命令退出码与日志，并为媒体业务转换失败。
// 关联文件:
//   lib/shared/services/production/media_service.dart
//   lib/shared/models/production/media.dart
//   lib/shared/services/production/runtime.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/abstract_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/level.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import '../../logger/app_logger.dart';
import '../../models/production/media.dart';
import 'runtime.dart';

final _log = AppLogger.forModule('Media');

/// FFmpegKit retains thread-local overwrite flags between executions. Reset
/// both through FFmpeg's boolean negation options before applying this call's
/// policy. FFprobe has no overwrite options and must not use this prefix.
List<String> ffmpegSessionArguments(List<String> arguments) => [
  '-noy',
  '-non',
  ...arguments,
];

/// FFprobe writes its machine output through FFmpegKit's STDERR channel.
/// Diagnostic levels (including the banner and warnings) are not JSON.
String ffmpegProbeOutput(Iterable<Log> logs) => logs
    .where((log) => log.getLevel() == Level.avLogStderr)
    .map((log) => log.getMessage())
    .join();

/// Keep native error details useful without retaining local paths or URLs.
String ffmpegFailureDetail(
  String output,
  List<String> arguments, {
  int limit = 4096,
}) {
  var detail = output;
  for (final argument in arguments) {
    if (argument.startsWith('/') ||
        argument.startsWith('\\\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(argument)) {
      detail = detail.replaceAll(argument, '<path>');
    }
  }
  detail = detail
      .replaceAll(RegExp(r'''[A-Za-z][A-Za-z0-9+.-]*://[^\s"']+'''), '<url>')
      .replaceAll(RegExp(r"'(/|[A-Za-z]:[\\/]|\\\\)[^'\r\n]*'"), "'<path>'")
      .replaceAll(RegExp(r'"(/|[A-Za-z]:[\\/]|\\\\)[^"\r\n]*"'), '"<path>"');
  return detail.length <= limit
      ? detail
      : '[truncated] ${detail.substring(detail.length - limit)}';
}

/// Read a completed native session for probe, frame and rendering operations.
Future<String> readFfmpegSessionOutput(
  AbstractSession session, {
  required bool probe,
  required MediaCancellation cancellation,
  required List<String> arguments,
}) async {
  final code = await session.getReturnCode();
  if (cancellation.cancelled || ReturnCode.isCancel(code)) {
    throw const MediaException(MediaFailure.cancelled);
  }
  if (!ReturnCode.isSuccess(code)) {
    final logs = await session.getAllLogs();
    final details = logs
        .where((log) => log.getLevel() <= Level.avLogError)
        .map((log) => log.getMessage())
        .join();
    final nativeLog = ffmpegFailureDetail(
      logs.map((log) => log.getMessage()).join(),
      arguments,
      limit: 65536,
    );
    final failure = code == null ? await session.getFailStackTrace() : null;
    final message = ffmpegFailureDetail(
      [
        if (details.trim().isNotEmpty) details.trim(),
        if (failure != null && failure.trim().isNotEmpty) failure.trim(),
      ].join('\n'),
      arguments,
    );
    _log.error(
      'native ${probe ? 'probe' : 'encode'} failed '
      'session=${session.getSessionId()} code=${code?.getValue()} '
      'detail=$message',
    );
    throw MediaException(
      probe ? MediaFailure.invalid_media : MediaFailure.encoding_failed,
      nativeSessionId: session.getSessionId(),
      nativeExitCode: code?.getValue(),
      message: message.isNotEmpty
          ? message
          : nativeLog.trim().isNotEmpty
          ? ffmpegFailureDetail(nativeLog.trim(), arguments)
          : null,
      nativeLog: nativeLog,
    );
  }
  return probe
      ? ffmpegProbeOutput(await session.getAllLogs())
      : (await session.getOutput()) ?? '';
}

class MediaCancellation {
  void Function(Duration processed)? onProgress;
  bool _cancelled = false;
  Future<void> Function()? _cancel;
  bool get cancelled => _cancelled;
  Future<void> cancel() async {
    _cancelled = true;
    await _cancel?.call();
  }

  Future<void> bind(Future<void> Function() cancel) async {
    _cancel = cancel;
    if (_cancelled) {
      await cancel();
    }
  }

  void unbind() => _cancel = null;
}

class FfmpegExecutionResult {
  const FfmpegExecutionResult({
    required this.exitCode,
    this.output = '',
    this.cancelled = false,
    this.errorCode,
    this.error,
  });

  static Future<FfmpegExecutionResult> fromSession(
    AbstractSession session, {
    required bool cancelled,
  }) async {
    int? code;
    var output = '';
    String? error;
    try {
      code = (await session.getReturnCode())?.getValue();
    } catch (failure) {
      error = failure.toString();
    }
    try {
      output = (await session.getOutput()) ?? '';
      if (code == null && error == null) {
        error = await session.getFailStackTrace();
      }
    } catch (failure) {
      error = [?error, failure.toString()].join('\n');
    }
    return FfmpegExecutionResult(
      exitCode: code,
      output: output,
      cancelled: cancelled || code == ReturnCode.cancel,
      errorCode: code == null || error != null ? 'execution_failed' : null,
      error: error,
    );
  }

  final int? exitCode;
  final String output;
  final bool cancelled;
  final String? errorCode, error;
}

class FfmpegRunner {
  FfmpegRunner({String? ffmpegExecutable, String? ffprobeExecutable})
    : _ffmpegExecutable = ffmpegExecutable ?? 'ffmpeg',
      _ffprobeExecutable = ffprobeExecutable ?? 'ffprobe';

  static Future<void> _encodingTail = Future.value();

  final String _ffmpegExecutable;
  final String _ffprobeExecutable;

  /// Linux has no bundled FFmpegKit/fvp runtime, so media work uses the
  /// system binaries. Windows and macOS keep the native sessions.
  bool get _usesSystemTools => Platform.isLinux;

  Future<FfmpegExecutionResult> executeCommand(
    List<String> arguments, {
    required MediaCancellation cancellation,
  }) => _serialize(() => _executeCommand(arguments, cancellation));

  Future<FfmpegExecutionResult> _executeCommand(
    List<String> arguments,
    MediaCancellation cancellation,
  ) async {
    if (cancellation.cancelled) {
      return const FfmpegExecutionResult(exitCode: null, cancelled: true);
    }
    if (_usesSystemTools) {
      return _executeSystemCommand(arguments, cancellation);
    }
    var started = false;
    try {
      await initializeMediaRuntime();
      if (cancellation.cancelled) {
        return const FfmpegExecutionResult(exitCode: null, cancelled: true);
      }
      final result = Completer<FfmpegExecutionResult>();
      Future<void> finish(AbstractSession session) async {
        final outcome = await FfmpegExecutionResult.fromSession(
          session,
          cancelled: cancellation.cancelled,
        );
        if (outcome.exitCode != 0) {
          _log.error(
            'native command failed session=${session.getSessionId()} '
            'code=${outcome.exitCode} detail=${ffmpegFailureDetail(outcome.output, arguments)}',
          );
        }
        result.complete(outcome);
      }

      final session = await FFmpegKit.executeWithArgumentsAsync(
        ffmpegSessionArguments(arguments),
        finish,
        null,
        (statistics) => cancellation.onProgress?.call(
          Duration(milliseconds: statistics.getTime().round()),
        ),
      );
      started = true;
      final id = session.getSessionId();
      if (id == null) {
        return const FfmpegExecutionResult(
          exitCode: null,
          errorCode: 'start_failed',
          error: 'FFmpegKit did not create a native session.',
        );
      }
      await cancellation.bind(() => FFmpegKit.cancel(id));
      return await result.future;
    } on UnsupportedError {
      rethrow;
    } catch (error) {
      return FfmpegExecutionResult(
        exitCode: null,
        cancelled: cancellation.cancelled,
        errorCode: started ? 'execution_failed' : 'start_failed',
        error: error.toString(),
      );
    } finally {
      cancellation.unbind();
    }
  }

  Future<String> execute(
    List<String> arguments, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    if (probe) {
      return _execute(arguments, probe: true, cancellation: cancellation);
    }
    return _serialize(
      () => _execute(arguments, probe: false, cancellation: cancellation),
    );
  }

  Future<T> _serialize<T>(Future<T> Function() run) async {
    final previous = _encodingTail;
    final released = Completer<void>();
    _encodingTail = released.future;
    await previous;
    try {
      return await run();
    } finally {
      released.complete();
    }
  }

  Future<String> _execute(
    List<String> arguments, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    if (cancellation.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    if (_usesSystemTools) {
      return _executeSystem(
        arguments,
        probe: probe,
        cancellation: cancellation,
      );
    }
    await initializeMediaRuntime();
    if (cancellation.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    final result = Completer<String>();
    Future<void> finish(AbstractSession session) async {
      try {
        result.complete(
          await readFfmpegSessionOutput(
            session,
            probe: probe,
            cancellation: cancellation,
            arguments: arguments,
          ),
        );
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }

    final session = probe
        ? await FFprobeKit.executeWithArgumentsAsync(arguments, finish)
        : await FFmpegKit.executeWithArgumentsAsync(
            ffmpegSessionArguments(arguments),
            finish,
            null,
            (statistics) => cancellation.onProgress?.call(
              Duration(milliseconds: statistics.getTime().round()),
            ),
          );
    final id = session.getSessionId();
    if (id == null) {
      throw const MediaException(MediaFailure.encoding_failed);
    }
    await cancellation.bind(() => FFmpegKit.cancel(id));
    try {
      return await result.future;
    } finally {
      cancellation.unbind();
    }
  }

  Future<FfmpegExecutionResult> _executeSystemCommand(
    List<String> arguments,
    MediaCancellation cancellation,
  ) async {
    try {
      final result = await _startSystemProcess(
        arguments,
        probe: false,
        cancellation: cancellation,
      );
      final outcome = FfmpegExecutionResult(
        exitCode: result.exitCode,
        output: result.log,
        cancelled: cancellation.cancelled,
      );
      if (outcome.exitCode != 0) {
        _log.error(
          'system command failed code=${outcome.exitCode} '
          'detail=${ffmpegFailureDetail(result.stderr, arguments)}',
        );
      }
      return outcome;
    } on ProcessException catch (error) {
      _log.error('system command could not start: $error');
      return FfmpegExecutionResult(
        exitCode: null,
        cancelled: cancellation.cancelled,
        errorCode: 'start_failed',
        error: error.toString(),
      );
    } catch (error, stack) {
      _log.error('system command failed', error: error, stackTrace: stack);
      return FfmpegExecutionResult(
        exitCode: null,
        cancelled: cancellation.cancelled,
        errorCode: 'execution_failed',
        error: error.toString(),
      );
    }
  }

  Future<String> _executeSystem(
    List<String> arguments, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    final _SystemProcessResult result;
    try {
      result = await _startSystemProcess(
        arguments,
        probe: probe,
        cancellation: cancellation,
      );
    } on ProcessException catch (error, stack) {
      final executable = probe ? _ffprobeExecutable : _ffmpegExecutable;
      final message = '$executable is not available: ${error.message}';
      _log.error(
        'system ${probe ? 'probe' : 'encode'} could not start executable=$executable',
        error: error,
        stackTrace: stack,
      );
      throw MediaException(MediaFailure.tool_unavailable, message: message);
    }
    if (cancellation.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    if (result.exitCode != 0) {
      final detail = ffmpegFailureDetail(result.log, arguments, limit: 65536);
      final message = ffmpegFailureDetail(result.stderr, arguments);
      _log.error(
        'system ${probe ? 'probe' : 'encode'} failed '
        'code=${result.exitCode} detail=$message',
      );
      throw MediaException(
        probe ? MediaFailure.invalid_media : MediaFailure.encoding_failed,
        nativeExitCode: result.exitCode,
        message: message.isEmpty ? null : message,
        nativeLog: detail,
      );
    }
    return probe ? result.stdout : result.log;
  }

  Future<_SystemProcessResult> _startSystemProcess(
    List<String> arguments, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    final process = await Process.start(
      probe ? _ffprobeExecutable : _ffmpegExecutable,
      probe ? arguments : ffmpegSessionArguments(arguments),
    );
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final progressTail = StringBuffer();
    final stdoutDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(stdout.write)
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
          stderr.write(chunk);
          if (!probe && cancellation.onProgress != null) {
            progressTail.write(chunk);
            final text = progressTail.toString();
            if (text.length > 8192) {
              progressTail
                ..clear()
                ..write(text.substring(text.length - 4096));
            }
            final processed = _ffmpegProcessedTime(text);
            if (processed != null) {
              cancellation.onProgress!(processed);
            }
          }
        })
        .asFuture<void>();
    await cancellation.bind(() async {
      process.kill();
    });
    try {
      final code = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      return _SystemProcessResult(code, stdout.toString(), stderr.toString());
    } finally {
      cancellation.unbind();
    }
  }

  /// The stock ffmpeg progress line ends with `time=HH:MM:SS.mm`. Read the last
  /// one in the accumulated stderr so a chunk split cannot hide the update.
  static final _timePattern = RegExp(r'time=(\d+):(\d+):(\d+(?:\.\d+)?)');

  static Duration? _ffmpegProcessedTime(String stderr) {
    final matches = _timePattern.allMatches(stderr);
    if (matches.isEmpty) {
      return null;
    }
    final match = matches.last;
    return Duration(
      hours: int.parse(match.group(1)!),
      minutes: int.parse(match.group(2)!),
      microseconds:
          (double.parse(match.group(3)!) * Duration.microsecondsPerSecond)
              .round(),
    );
  }
}

class _SystemProcessResult {
  const _SystemProcessResult(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
  String get log => '$stdout$stderr';
}
