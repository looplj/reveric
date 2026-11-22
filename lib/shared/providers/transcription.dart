// 职责: 装配转写服务和应用启动时的任务恢复。
// 关联文件:
//   lib/shared/services/production/transcription_service.dart
//   lib/shared/providers/production_media.dart
//   lib/shared/providers/object_storage.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/transcription/result.dart';
import '../services/production/canvas_service.dart';
import '../services/production/transcription_service.dart';
import '../services/storyboard/service.dart';
import 'novel_providers.dart';
import 'object_storage.dart';
import 'production_media.dart';
import 'settings_providers.dart';

final transcriptionServiceProvider = Provider<TranscriptionService>((ref) {
  final database = ref.watch(appDatabaseProvider);
  final library = ref.watch(mediaLibraryServiceProvider);
  final service = TranscriptionService(
    database: database,
    library: library,
    storage: ref.watch(objectStorageServiceProvider),
    defaultAsrModelId: () async => (await ref.read(
      appSettingsProvider.future,
    )).aiSettings.defaultAsrModelId,
    canvasForWork: (workId) async {
      final work = await database.novelDao.get(workId);
      final path = work?.contentDatabasePath;
      if (work == null || path == null) {
        throw const TranscriptionException('source_missing');
      }
      final content = ref.read(novelContentServiceProvider(path));
      return ProductionCanvasService(
        StoryboardService(content.database, contentKind: work.contentKind),
        library,
        workId,
      );
    },
  );
  ref.onDispose(service.dispose);
  return service;
});

final transcriptionRecoveryProvider = FutureProvider<void>(
  (ref) => ref.watch(transcriptionServiceProvider).recover(),
);
