// 职责: 装配应用级视频调度器并按任务 ID 提供轻量数据库状态流。
// 关联文件:
//   lib/shared/services/ai/video/task_service.dart
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/providers/object_storage.dart
//   lib/shared/providers/novel_providers.dart
//   lib/main.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/service-naming.md

import 'dart:async';
import 'production_media.dart';
import '../services/production/result_service.dart';
import '../services/production/canvas_service.dart';
import '../services/storyboard/service.dart';
import '../database/novel_content_database.dart';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../logger/app_logger.dart';
import '../utils/storage_paths.dart';
import '../services/ai/assets/certification.dart';
import '../services/ai/video/reference_storage_service.dart';
import '../services/ai/video/task_service.dart';
import 'novel_providers.dart';
import 'object_storage.dart';

final _log = AppLogger.forModule('VideoTasks');

final referenceStorageServiceProvider = Provider<ReferenceStorageService>((
  ref,
) {
  final storage = ref.watch(objectStorageServiceProvider);
  final service = ReferenceStorageService(
    probe: ref.watch(mediaServiceProvider).probe,
    database: ref.watch(appDatabaseProvider),
    storage: storage,
  );
  ref.onDispose(service.dispose);
  return service;
});

/// 渠道私域素材认证；启动时接着轮询上次没出结果的记录。
final providerAssetServiceProvider = Provider<ProviderAssetService>((ref) {
  final service = ProviderAssetService(
    database: ref.watch(appDatabaseProvider),
    references: ref.watch(referenceStorageServiceProvider),
    probe: ref.watch(mediaServiceProvider).probe,
  );
  ref.onDispose(service.dispose);
  unawaited(
    service.resume().catchError((Object error, StackTrace stack) {
      _log.error(
        'provider asset resume failed',
        error: error,
        stackTrace: stack,
      );
    }),
  );
  return service;
});

final productionResultServiceProvider = Provider<ProductionResultService>((
  ref,
) {
  final app = ref.watch(appDatabaseProvider);
  final library = ref.watch(mediaLibraryServiceProvider);
  return ProductionResultService(app, (novelId) async {
    final novel = await app.novelDao.get(novelId);
    if (novel == null || novel.contentDatabasePath == null) {
      return null;
    }
    final databasePath = RevericPaths.resolveDatabasePath(
      novel.contentDatabasePath!,
    );
    if (!await File(databasePath).exists()) {
      throw StateError('Production content database is unavailable');
    }
    return ProductionCanvasService(
      StoryboardService(NovelContentDatabase(databasePath)),
      library,
      novelId,
    );
  }, release: (service) => service.db.close());
});

/// One instance owns the app's timers/clients; page subscriptions do not own it.
final videoTaskServiceProvider = FutureProvider<VideoTaskService>((ref) async {
  final database = ref.watch(appDatabaseProvider);
  final references = ref.watch(referenceStorageServiceProvider);
  final root = Directory(RevericPaths.fileWorkspaceParent);
  if (!ref.mounted) {
    throw StateError('Video startup disposed');
  }
  final results = ref.watch(productionResultServiceProvider);
  final service = VideoTaskService(
    beforeCreate: results.beforeCreate,
    beforeSubmit: results.beforeSubmit,
    recoverSources: results.recover,
    sourceName: results.sourceName,
    database: database,
    probeResult: ref.watch(mediaServiceProvider).probe,
    rootDirectory: root,
    references: references,
  );
  ref.onDispose(service.dispose);
  var checking = false;
  Future<void> checkNetwork() async {
    if (checking || !ref.mounted) {
      return;
    }
    checking = true;
    try {
      final interfaces = await NetworkInterface.list(includeLoopback: false);
      if (ref.mounted) {
        service.setOnline(interfaces.any((i) => i.addresses.isNotEmpty));
      }
    } catch (error) {
      // Interface discovery is only a wake-up signal; HTTP failures retain normal backoff.
      _log.warning('interface observation failed type=${error.runtimeType}');
    } finally {
      checking = false;
    }
  }

  await checkNetwork();
  final timer = Timer.periodic(
    const Duration(seconds: 5),
    (_) => unawaited(checkNetwork()),
  );
  ref.onDispose(timer.cancel);
  try {
    await service.start();
  } catch (error, stack) {
    _log.error('startup recovery failed', error: error, stackTrace: stack);
    rethrow;
  }
  return service;
});

final videoTaskProvider = StreamProvider.autoDispose
    .family<GenerationTask?, String>(
      (ref, id) =>
          ref.watch(appDatabaseProvider).generationTaskDao.watchTask(id),
    );
