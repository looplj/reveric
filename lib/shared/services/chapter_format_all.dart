// 职责: 逐章读取最新正文、排版并写回，避免缓存全书文本。
// 关联文件:
//   lib/shared/utils/chapter_text_formatter.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/database/novel_content_daos/chapter_dao.dart
//   lib/desktop/widgets/workspace/novel_workspace_panel.dart
//   lib/mobile/pages/chapter_editor_page.dart

import '../utils/chapter_text_formatter.dart';
import 'novel_content.dart';

/// 对全书章节正文执行排版并直写数据库。
///
/// 不走 working overlay stage：批量排版是确定性纯文本变换，无需逐字段历史；
/// 单章仍可从章节历史回滚。每章经 [NovelContentService.updateFormattedChapterContent]
/// 独立写回正文及更新时间，保留字数、不更新小说记录。
///
/// 执行时重新读取 [chapterIds] 的最新正文，已规范或已删除的章节跳过写入。
/// [onProgress] 在每章处理后回调 `(已处理章数, 总章数)`，供进度 UI 使用。
///
/// 返回实际改写的章节数。
Future<int> formatAllChapterContents({
  required NovelContentService contentService,
  required List<String> chapterIds,
  int indentCount = 2,
  bool blankLineBetweenParagraphs = true,
  bool allowSpaces = true,
  void Function(int done, int total)? onProgress,
}) async {
  var processed = 0;
  var changed = 0;
  for (final id in chapterIds) {
    final content = await contentService.getChapterBodyById(id);
    // 确认后被删除的章节直接跳过，不中断其余章节。
    if (content != null) {
      final formatted = formatText(
        content,
        indentCount: indentCount,
        blankLineBetweenParagraphs: blankLineBetweenParagraphs,
        allowSpaces: allowSpaces,
      );
      if (formatted != content) {
        await contentService.updateFormattedChapterContent(
          chapterId: id,
          content: formatted,
        );
        changed++;
      }
    }
    processed++;
    onProgress?.call(processed, chapterIds.length);
  }
  return changed;
}
