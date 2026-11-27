// 职责: 订阅作品库中指定章节的高亮标记。
// 关联文件:
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/widgets/chapter/highlight_selection.dart

import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../database/novel_content_database.dart';
import 'novel_providers.dart';

final chapterHighlightsProvider = StreamProvider.autoDispose
    .family<List<ChapterHighlight>, ({String path, String chapterId})>((
      ref,
      chapter,
    ) {
      return ref
          .watch(novelContentServiceProvider(chapter.path))
          .watchChapterHighlights(chapter.chapterId);
    });
