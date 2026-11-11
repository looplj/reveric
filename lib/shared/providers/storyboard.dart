// 职责: 提供片段服务和随内容库写入更新的片段、制作设置流。
// 关联文件:
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/storyboard/service.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../database/novel_content_database.dart';
import '../services/storyboard/service.dart';
import 'novel_providers.dart';
part 'storyboard.g.dart';

@riverpod
StoryboardService storyboardService(Ref ref, String databasePath) {
  final actions = ref.watch(novelActionsProvider);
  return StoryboardService(
    ref.watch(novelContentDatabaseProvider(databasePath)),
    resolveContentKind: () async {
      final novel = await actions.getNovelByContentDatabasePath(databasePath);
      if (novel == null) {
        throw StateError('Production work registration is unavailable');
      }
      return novel.contentKind;
    },
  );
}

@riverpod
Stream<List<ProductionClipRow>> storyboardShots(
  Ref ref,
  String databasePath,
  String episodeId,
) => ref.watch(storyboardServiceProvider(databasePath)).watchShots(episodeId);
@riverpod
Stream<ScreenplayRow?> episodeProduction(
  Ref ref,
  String databasePath,
  String episodeId,
) => ref.watch(storyboardServiceProvider(databasePath)).watchSettings();
