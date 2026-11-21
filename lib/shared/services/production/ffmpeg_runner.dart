// 职责: 执行可取消的原生媒体会话，保留命令退出码与日志，并为媒体业务转换失败。
// 关联文件:
//   lib/shared/services/production/media_service.dart
//   lib/shared/models/production/media.dart
//   lib/shared/services/production/runtime.dart

import 'dart:async';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/abstract_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'package:ffmpeg_kit_flutter_new/level.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
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
  ReturnCode? code;
  Object? unavailable;
  try {
    code = await session.getReturnCode();
  } catch (error) {
    unavailable = error;
  }
  if (cancellation.cancelled || ReturnCode.isCancel(code)) {
    throw const MediaException(MediaFailure.cancelled);
  }
  if (unavailable != null) {
    // The bounded native history can drop a finished session before its
    // result is read; the outcome is then unknown and must not pass as valid.
    _log.error(
      'native ${probe ? 'probe' : 'encode'} result unavailable '
      'session=${session.getSessionId()} error=$unavailable',
    );
    throw MediaException(
      probe ? MediaFailure.invalid_media : MediaFailure.encoding_failed,
      nativeSessionId: session.getSessionId(),
      message: 'Native session result unavailable: $unavailable',
    );
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
  final List<void Function()> _listeners = [];
  bool get cancelled => _cancelled;
  Future<void> cancel() async {
    _cancelled = true;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
    await _cancel?.call();
  }

  void addCancelListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeCancelListener(void Function() listener) {
    _listeners.remove(listener);
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

void Function(Statistics) _reportProgress(MediaCancellation cancellation) =>
    (statistics) => cancellation.onProgress?.call(
      Duration(milliseconds: statistics.getTime().round()),
    );

/// Completion comes from the reply to FFmpegKitConfig.ffmpegExecute /
/// ffprobeExecute. The async execute API instead delivers completion by
/// looking the session up in the native history, which evicts in creation
/// order (running sessions included); an evicted session then never completes
/// and would hold the encoding queue forever.
class FfmpegRunner {
  FfmpegRunner();

  static Future<void> _encodingTail = Future.value();

  Future<FfmpegExecutionResult> executeCommand(
    List<String> arguments, {
    required MediaCancellation cancellation,
  }) => serialize(cancellation, () => _executeCommand(arguments, cancellation));

  Future<FfmpegExecutionResult> _executeCommand(
    List<String> arguments,
    MediaCancellation cancellation,
  ) async {
    if (cancellation.cancelled) {
      return const FfmpegExecutionResult(exitCode: null, cancelled: true);
    }
    var started = false;
    try {
      await initializeMediaRuntime();
      if (cancellation.cancelled) {
        return const FfmpegExecutionResult(exitCode: null, cancelled: true);
      }
      final session = await FFmpegSession.create(
        ffmpegSessionArguments(arguments),
        null,
        null,
        _reportProgress(cancellation),
      );
      final id = session.getSessionId();
      if (id == null) {
        return const FfmpegExecutionResult(
          exitCode: null,
          errorCode: 'start_failed',
          error: 'FFmpegKit did not create a native session.',
        );
      }
      await cancellation.bind(() => FFmpegKit.cancel(id));
      if (cancellation.cancelled) {
        return const FfmpegExecutionResult(exitCode: null, cancelled: true);
      }
      await FFmpegKitConfig.ffmpegExecute(session);
      started = true;
      final outcome = await FfmpegExecutionResult.fromSession(
        session,
        cancelled: cancellation.cancelled,
      );
      if (outcome.exitCode != 0) {
        _log.error(
          'native command failed session=$id '
          'code=${outcome.exitCode} detail=${ffmpegFailureDetail(outcome.output, arguments)}',
        );
      }
      return outcome;
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
    return serialize(
      cancellation,
      () => _execute(arguments, probe: false, cancellation: cancellation),
    );
  }

  /// Runs encodes one at a time. A cancelled waiter leaves the queue at once
  /// (its [run] sees the cancellation and starts no native session), while
  /// later encodes still wait for the one ahead of it.
  @visibleForTesting
  static Future<T> serialize<T>(
    MediaCancellation cancellation,
    Future<T> Function() run,
  ) async {
    final previous = _encodingTail;
    final released = Completer<void>();
    _encodingTail = released.future;
    final stopped = Completer<bool>();
    void stop() {
      if (!stopped.isCompleted) {
        stopped.complete(false);
      }
    }

    cancellation.addCancelListener(stop);
    final bool ready;
    try {
      ready = await Future.any([previous.then((_) => true), stopped.future]);
    } finally {
      cancellation.removeCancelListener(stop);
    }
    if (!ready) {
      unawaited(previous.whenComplete(released.complete));
      return run();
    }
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
    await initializeMediaRuntime();
    if (cancellation.cancelled) {
      throw const MediaException(MediaFailure.cancelled);
    }
    final AbstractSession session;
    final Future<void> Function() run;
    if (probe) {
      final ffprobe = await FFprobeSession.create(arguments);
      session = ffprobe;
      run = () => FFmpegKitConfig.ffprobeExecute(ffprobe);
    } else {
      final ffmpeg = await FFmpegSession.create(
        ffmpegSessionArguments(arguments),
        null,
        null,
        _reportProgress(cancellation),
      );
      session = ffmpeg;
      run = () => FFmpegKitConfig.ffmpegExecute(ffmpeg);
    }
    final id = session.getSessionId();
    if (id == null) {
      throw const MediaException(MediaFailure.encoding_failed);
    }
    await cancellation.bind(() => FFmpegKit.cancel(id));
    try {
      if (cancellation.cancelled) {
        throw const MediaException(MediaFailure.cancelled);
      }
      try {
        await run();
      } catch (error) {
        throw MediaException(
          probe ? MediaFailure.invalid_media : MediaFailure.encoding_failed,
          nativeSessionId: id,
          message: 'Native session did not start: $error',
        );
      }
      return await readFfmpegSessionOutput(
        session,
        probe: probe,
        cancellation: cancellation,
        arguments: arguments,
      );
    } finally {
      cancellation.unbind();
    }
  }
}
