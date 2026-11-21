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

const _ffmpegAbi = {
  'avutil': 60,
  'swresample': 6,
  'swscale': 9,
  'avcodec': 62,
  'avformat': 62,
  'avfilter': 11,
};

Future<void> initializeMediaRuntime() => _initialization ??= _initialize();

Future<void> _initialize() async {
  if (Platform.isLinux) {
    await _initializeLinux();
    return;
  }
  if (!Platform.isMacOS && !Platform.isWindows) {
    throw UnsupportedError(
      'Production playback requires Windows, macOS, or Linux',
    );
  }
  final directory = p.dirname(Platform.resolvedExecutable);
  final libraries = _openFfmpegAbi((name, version) {
    if (Platform.isMacOS) {
      return p.normalize(
        p.join(directory, '..', 'Frameworks', 'lib$name.framework', 'lib$name'),
      );
    }
    return p.join(directory, '$name-$version.dll');
  });
  await fvp.registerWith(
    options: <String, dynamic>{
      'platforms': <String>['macos', 'windows'],
      'global': libraries,
    },
  );
  await _startFfmpegKit();
  // av_log has one callback inside each loaded FFmpeg. MDK binds the copy it
  // opens; FFmpegKit must own the copy it encodes with so FFprobe JSON and
  // session logs are retained.
  if (Platform.isWindows) {
    // The Windows 8.1.2 wrapper joins its callback thread on disable. Rebind
    // through its public API; the callback function is not exported by the DLL.
    await FFmpegKitConfig.disableRedirection();
    await FFmpegKitConfig.enableRedirection();
    return;
  }
  _bindLogCallback(
    p.normalize(
      p.join(directory, '..', 'Frameworks', 'ffmpegkit.framework', 'ffmpegkit'),
    ),
    libraries['avutil']! as String,
  );
}

/// Linux 播放用 FVP 自带的 MDK 和 libffmpeg.so.9。编码和探测用旁边的
/// FFmpegKit 共享库，不启动独立的 ffmpeg 进程。
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
  final libraries = _openFfmpegAbi(
    (name, version) => p.join(directory, 'lib', 'lib$name.so.$version'),
  );
  await fvp.registerWith(
    options: <String, dynamic>{
      'platforms': <String>['linux'],
    },
  );
  await _startFfmpegKit();
  // Linux 的 libffmpegkit 导出了和 macOS 相同的回调符号。MDK 用的是另一份
  // libffmpeg.so.9，这里只把 FFmpegKit 那份 avutil 的日志回调交回去。
  _bindLogCallback(
    p.join(directory, 'lib', 'libffmpegkit.so'),
    libraries['avutil']! as String,
  );
}

Map<String, Object> _openFfmpegAbi(
  String Function(String name, int version) pathFor,
) {
  final libraries = <String, Object>{};
  for (final entry in _ffmpegAbi.entries) {
    final name = entry.key;
    final path = pathFor(name, entry.value);
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
  return libraries;
}

Future<void> _startFfmpegKit() async {
  await FFmpegKitConfig.init();
  // Session results are read from the native history, which keeps 10 sessions
  // by default and evicts in creation order; an editing render plus a burst of
  // probes exceeds that. The native hard limit rejects 1000 or more.
  await FFmpegKitConfig.setSessionHistorySize(500);
  // Sessions keep their logs for probe output and failure details; without a
  // callback the plugin would otherwise print every av_log line to the console.
  FFmpegKitConfig.setLogRedirectionStrategy(
    LogRedirectionStrategy.neverPrintLogs,
  );
}

void _bindLogCallback(String kitPath, String avutilPath) {
  // Apple and Linux disable does not join the consumer, so keep that thread
  // running and point av_log at the exported callback.
  final callback = DynamicLibrary.open(
    kitPath,
  ).lookup<Void>('ffmpegkit_log_callback_function');
  DynamicLibrary.open(
    avutilPath,
  ).lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
    'av_log_set_callback',
  )(callback);
}
