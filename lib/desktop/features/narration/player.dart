// 职责: 使用桌面媒体运行库播放朗读音频并清理本次创建的临时文件。
// 关联文件:
//   lib/shared/services/production/runtime.dart
//   lib/shared/services/screenplay/narration_orchestrator.dart

import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import '../../../shared/models/audio/exception.dart';
import '../../../shared/services/production/runtime.dart';
import '../../../shared/services/screenplay/narration_orchestrator.dart';

final narrationPlayerFactoryProvider =
    Provider<Future<NarrationPlayer> Function(NarrationAudio)>(
      (ref) => DesktopNarrationPlayer.create,
    );

class DesktopNarrationPlayer implements NarrationPlayer {
  DesktopNarrationPlayer._(this._controller, this._directory);
  final VideoPlayerController _controller;
  final Directory _directory;
  void Function(Object?)? _finished;
  bool _reported = false;

  static Future<NarrationPlayer> create(
    NarrationAudio audio, {
    Future<void> Function() initializeRuntime = initializeMediaRuntime,
    VideoPlayerController Function(File) createController =
        VideoPlayerController.file,
  }) async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      throw UnsupportedError('Narration requires Windows, macOS or Linux');
    }
    await initializeRuntime();
    final temp = await getTemporaryDirectory();
    await temp.create(recursive: true);
    final directory = await temp.createTemp('reveric_narration_');
    VideoPlayerController? controller;
    try {
      final file = File('${directory.path}/speech.${audio.extension}');
      await file.writeAsBytes(audio.bytes, flush: true);
      controller = createController(file);
      await controller.initialize();
      if (controller.value.duration <= Duration.zero) {
        throw const AudioException('invalid_result');
      }
      final player = DesktopNarrationPlayer._(controller, directory);
      controller.addListener(player._listen);
      return player;
    } catch (_) {
      try {
        await controller?.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
      rethrow;
    }
  }

  void _listen() {
    if (_reported || _finished == null) {
      return;
    }
    final value = _controller.value;
    if (value.hasError || value.isCompleted) {
      _reported = true;
      _finished?.call(
        value.hasError
            ? const AudioException('narration_playback_failed')
            : null,
      );
    }
  }

  @override
  void onFinished(void Function(Object? error) callback) {
    _finished = callback;
    _listen();
  }

  @override
  Future<void> play() {
    _reported = false;
    return _controller.play();
  }

  @override
  Future<void> pause() => _controller.pause();
  @override
  Future<void> setSpeed(double speed) => _controller.setPlaybackSpeed(speed);
  @override
  Future<void> dispose() async {
    _finished = null;
    _controller.removeListener(_listen);
    try {
      await _controller.dispose();
    } finally {
      await _directory.delete(recursive: true);
    }
  }
}
