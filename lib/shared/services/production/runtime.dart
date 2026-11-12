// 职责: 按平台初始化桌面播放运行库与共享 FFmpeg 库，并统一播放与编码的日志回调归属。
// 关联文件:
//   lib/shared/services/production/playback_service.dart
//   lib/shared/services/production/ffmpeg_runner.dart
import 'dart:ffi';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/log_redirection_strategy.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:path/path.dart' as p;

Future<void>? _initialization;

Future<void> initializeMediaRuntime() => _initialization ??= _initialize();

Future<void> _initialize() async {
  if (Platform.isLinux) {
    await _initializeLinux();
    return;
  }
  if (!Platform.isMacOS && !Platform.isWindows) {
    throw UnsupportedError('Production playback requires Windows or macOS');
  }
  final directory = p.dirname(Platform.resolvedExecutable);
  const versions = {
    'avutil': 60,
    'swresample': 6,
    'swscale': 9,
    'avcodec': 62,
    'avformat': 62,
    'avfilter': 11,
  };
  final libraries = <String, Object>{};
  for (final entry in versions.entries) {
    final name = entry.key;
    final path = Platform.isMacOS
        ? p.normalize(
            p.join(
              directory,
              '..',
              'Frameworks',
              'lib$name.framework',
              'lib$name',
            ),
          )
        : p.join(directory, '$name-${entry.value}.dll');
    // Fail before creating a player if packaging or ABI does not match FFmpegKit.
    final library = DynamicLibrary.open(path);
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
      '${name}_version',
    )();
    if (version >> 16 != entry.value) {
      throw StateError('Unexpected FFmpeg ABI for $name: ${version >> 16}');
    }
    libraries[name] = path;
  }
  await fvp.registerWith(
    options: <String, dynamic>{
      'platforms': <String>['macos', 'windows'],
      'global': libraries,
    },
  );
  await FFmpegKitConfig.init();
  // Sessions keep their logs for probe output and failure details; without a
  // callback the plugin would otherwise print every av_log line to the console.
  FFmpegKitConfig.setLogRedirectionStrategy(
    LogRedirectionStrategy.neverPrintLogs,
  );
  // av_log has one process-wide callback. MDK installs its own while binding
  // FFmpeg; FFmpegKit must own it so FFprobe JSON and session logs are retained.
  // All playback/encoding entry points await this initialization before work.
  if (Platform.isWindows) {
    // The Windows 8.1.2 wrapper joins its callback thread on disable. Rebind
    // through its public API; the callback function is not exported by the DLL.
    await FFmpegKitConfig.disableRedirection();
    await FFmpegKitConfig.enableRedirection();
    return;
  }
  final kitPath = p.normalize(
    p.join(directory, '..', 'Frameworks', 'ffmpegkit.framework', 'ffmpegkit'),
  );
  // Apple's disable does not join the consumer, so keep that thread running.
  final callback = DynamicLibrary.open(
    kitPath,
  ).lookup<Void>('ffmpegkit_log_callback_function');
  DynamicLibrary.open(
    libraries['avutil']! as String,
  ).lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'av_log_set_callback',
  )(callback);
}

/// Linux 由 FVP 插件自带 MDK 运行库与 FFmpeg 共享库，直接使用，不经过 FFmpegKit。
/// 编码和探测使用应用包内的 ffmpeg / ffprobe，不依赖系统安装。
Future<void> _initializeLinux() async {
  final directory = p.dirname(Platform.resolvedExecutable);
  final runtime = <String>['libmdk.so.0', 'libffmpeg.so.9', 'libc++.so.1'];
  for (final name in runtime) {
    final path = p.join(directory, 'lib', name);
    // 缺少运行库时要在建播放器前失败，而不是让 dlopen 抛出不可读的错误。
    if (!File(path).existsSync()) {
      throw StateError('Missing Linux playback runtime: $path');
    }
  }
  await fvp.registerWith(
    options: <String, dynamic>{
      'platforms': <String>['linux'],
    },
  );
}
