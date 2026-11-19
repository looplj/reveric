// 职责: 按作品装配剪辑持久化与共用渲染依赖。
// 关联文件:
//   lib/shared/services/editing/service.dart
//   lib/shared/services/editing/render_service.dart
//   lib/shared/providers/production_media.dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/editing/service.dart';
import '../services/editing/sessions.dart';
import '../services/editing/render_service.dart';
import '../services/production/ffmpeg_runner.dart';
import 'novel_providers.dart';
import 'production_media.dart';

final editingServiceProvider = Provider.autoDispose
    .family<EditingService, ({String path, String novelId})>(
      (ref, work) => EditingService(
        ref.watch(novelContentDatabaseProvider(work.path)),
        ref.watch(mediaLibraryServiceProvider),
        novelId: work.novelId,
      ),
    );
final editingRenderServiceProvider = Provider.autoDispose
    .family<EditingRenderService, ({String path, String novelId})>((ref, work) {
      final service = EditingRenderService(
        ref.watch(editingServiceProvider(work)),
        FfmpegRunner(),
      );
      ref.onDispose(() => unawaited(service.dispose()));
      return service;
    });

// 只缓存轻量文档历史，最多保留 32 个闲置会话；UI 和运行中的命令不回收。
final editingSessionsProvider = Provider<EditingSessions>((ref) {
  final sessions = EditingSessions();
  ref.onDispose(sessions.dispose);
  return sessions;
});
