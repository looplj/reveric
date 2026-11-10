// 职责: 提供对象存储服务与当前配置的监听。
// 关联文件:
//   lib/shared/services/object_storage/service.dart
//   lib/shared/models/object_storage_config.dart
//   lib/shared/providers/video_tasks.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/service-naming.md

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/object_storage_config.dart';
import '../services/object_storage/service.dart';
import 'novel_providers.dart';

final objectStorageServiceProvider = Provider<ObjectStorageService>((ref) {
  return ObjectStorageService(database: ref.watch(appDatabaseProvider));
});

/// 配置经 [ObjectStorageService.save] 或 [ObjectStorageService.clear] 写入，读取侧监听同一行 app_settings。
final objectStorageConfigProvider = StreamProvider<ObjectStorageConfig>((ref) {
  return ref.watch(objectStorageServiceProvider).watch();
});
