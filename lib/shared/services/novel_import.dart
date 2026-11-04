// 职责: 解析并导入 TXT 小说，可同步创建关联原著的改编剧本。
// 关联文件:
//   lib/shared/services/novel_actions.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/models/novel_type.dart

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../logger/app_logger.dart';

import '../models/novel_type.dart';
import '../models/content_kind.dart';
import '../utils/text_file_decoder.dart';
import '../utils/text_unit_count.dart';
import 'novel_actions.dart';
import 'novel_content.dart';

final _log = AppLogger.forModule('Import');

class ParsedNovelImport {
  const ParsedNovelImport({
    required this.suggestedTitle,
    required this.chapters,
    required this.volumeCount,
    required this.wordCount,
  });

  final String suggestedTitle;
  final List<ImportedChapterNode> chapters;
  final int volumeCount;
  final int wordCount;
}

class NovelImportResult {
  const NovelImportResult({
    required this.novelId,
    this.screenplayId,
    required this.chapterCount,
    required this.volumeCount,
    required this.wordCount,
  });

  final String novelId;
  final String? screenplayId;
  final int chapterCount;
  final int volumeCount;
  final int wordCount;
}

class NovelImportService {
  NovelImportService({
    required this.actions,
    Future<void> Function(
      NovelContentService service,
      List<ImportedChapterNode> chapters,
    )?
    chapterImporter,
  }) : _chapterImporter =
           chapterImporter ??
           ((service, chapters) => service.replaceChaptersForImport(chapters));

  final NovelActionsService actions;
  final Future<void> Function(
    NovelContentService service,
    List<ImportedChapterNode> chapters,
  )
  _chapterImporter;

  Future<ParsedNovelImport> parseTxtFile(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    final text = decodeImportedTextBytes(
      bytes,
      onGbkDecodeFailure: (error) {
        if (_log.isDebugEnabled) {
          _log.debug('GBK decode failed, fallback to UTF-8: $error');
        }
      },
    );
    final fallbackTitle = p.basenameWithoutExtension(filePath).trim();
    return parseTxt(text, fallbackTitle: fallbackTitle);
  }

  /// Normalize a chapter heading for duplicate detection.
  String _normalizeChapterTitle(String rawTitle) {
    return rawTitle
        .replaceAll(RegExp(r'【[^】]*】'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceFirst(RegExp(r'^正文\s+', caseSensitive: false), '')
        .trim();
  }

  /// Extract the user-facing title from a normalized chapter heading.
  String _chapterTitleFromHeading(String normalizedTitle) {
    return normalizedTitle
        .replaceFirst(
          RegExp(
            r'^第\s*[0-9零〇一二两三四五六七八九十百千万]+\s*[章节回]\s*[:：]?\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  ParsedNovelImport parseTxt(String text, {required String fallbackTitle}) {
    final normalized = text
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final lines = const LineSplitter().convert(normalized);
    final chapters = <ImportedChapterNode>[];
    final volumes = <String>{};
    final content = StringBuffer();
    String? currentVolume;
    String? currentChapterTitle;
    String? lastNormalizedTitle;
    var hasChapterHeading = false;

    void flushChapter() {
      final title = currentChapterTitle?.trim();
      if (title == null) {
        return;
      }
      final chapterContent = content.toString().trimRight();
      // Skip chapters with no content — they're empty formatting duplicates.
      if (chapterContent.isEmpty) {
        content.clear();
        return;
      }
      chapters.add(
        ImportedChapterNode(
          title: title,
          volumeTitle: currentVolume,
          content: chapterContent,
        ),
      );
      content.clear();
    }

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (_isVolumeHeading(line)) {
        flushChapter();
        currentVolume = line;
        volumes.add(line);
        currentChapterTitle = null;
        lastNormalizedTitle = null;
        continue;
      }
      if (_isChapterHeading(line)) {
        hasChapterHeading = true;
        final normalizedTitle = _normalizeChapterTitle(line);
        // If content is still empty and the same normalized title was the
        // previous chapter, this is a formatting duplicate (e.g. same chapter
        // heading with/without 【】 or different whitespace). Just update the
        // title reference and keep accumulating.
        if (content.toString().trimRight().isEmpty &&
            lastNormalizedTitle == normalizedTitle) {
          currentChapterTitle = _chapterTitleFromHeading(normalizedTitle);
          continue;
        }
        flushChapter();
        currentChapterTitle = _chapterTitleFromHeading(normalizedTitle);
        lastNormalizedTitle = normalizedTitle;
        continue;
      }
      if (currentChapterTitle == null && line.isEmpty && content.isEmpty) {
        continue;
      }
      if (currentChapterTitle == null && line.isNotEmpty) {
        currentChapterTitle = _fallbackChapterTitle(fallbackTitle);
      }
      if (currentChapterTitle != null) {
        content.writeln(rawLine);
      }
    }
    flushChapter();

    if (!hasChapterHeading) {
      chapters.clear();
    }

    return ParsedNovelImport(
      suggestedTitle: fallbackTitle.isEmpty ? '未命名作品' : fallbackTitle,
      chapters: chapters,
      volumeCount: volumes.length,
      wordCount: chapters.fold<int>(
        0,
        (sum, chapter) => sum + countTextUnits(chapter.content.trim()),
      ),
    );
  }

  Future<NovelImportResult> importTxt({
    required String filePath,
    required String title,
    required String description,
    required String category,
    required String type,
    required List<String> tags,
    String? adaptationTitle,
    int? plannedEpisodeCount,
  }) async {
    if (adaptationTitle != null &&
        (adaptationTitle.trim().isEmpty ||
            (plannedEpisodeCount != null && plannedEpisodeCount < 1))) {
      throw ArgumentError('Invalid adaptation title or planned episode count');
    }
    final parsed = await parseTxtFile(filePath);
    if (parsed.chapters.isEmpty) {
      throw const NovelImportException('TXT 文件未识别到章节，无法导入。');
    }
    // Check for duplicate title before attempting creation.
    final existing = await actions.findNovelByTitle(title);
    if (existing != null) {
      throw NovelImportException('作品「$title」已存在，请使用不同的名称。');
    }
    String? novelId;
    String? screenplayId;
    try {
      // 章节在作品登记前写入内容库：导入失败时作品不会登记，也不会进回收站。
      var totalWordCount = 0;
      novelId = await actions.createNovel(
        title: title,
        description: description,
        category: category,
        type: novelTypes.contains(type) ? type : novelTypeOriginal,
        tags: tags,
        setNovelOnboardingEligible: false,
        populateContent: (contentDatabase) async {
          final contentService = NovelContentService(
            contentDatabase,
            novelActionsService: actions,
          );
          await _chapterImporter(contentService, parsed.chapters);
          final importedChapters = await contentService.getChapters();
          totalWordCount = importedChapters.fold<int>(
            0,
            (sum, chapter) => sum + chapter.wordCount,
          );
        },
      );
      await actions.updateNovelWordCount(
        novelId: novelId,
        wordCount: totalWordCount,
      );
      if (adaptationTitle != null) {
        final baseTitle = adaptationTitle.trim();
        var screenplayTitle = baseTitle;
        var suffix = 2;
        while (await actions.findNovelByTitle(screenplayTitle) != null) {
          screenplayTitle = '$baseTitle ($suffix)';
          suffix++;
        }
        screenplayId = await actions.createNovel(
          title: screenplayTitle,
          description: description,
          category: category,
          tags: tags,
          contentKind: contentKindScreenplay,
          type: novelTypeAdaptation,
          sourceNovelId: novelId,
          plannedEpisodeCount: plannedEpisodeCount,
        );
      }
    } catch (error, stackTrace) {
      _log.error(
        'IMPORT_TXT id=${novelId ?? '<not_created>'} error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      // 改编剧本创建失败时整次导入作废：已登记的原著移入回收站，可恢复。
      if (novelId != null) {
        try {
          final createdNovel = await actions.getNovel(novelId);
          if (createdNovel != null) {
            await actions.deleteNovel(createdNovel);
          }
        } catch (cleanupError, cleanupStackTrace) {
          _log.error(
            'ROLLBACK_IMPORT_TXT id=$novelId error=$cleanupError',
            error: cleanupError,
            stackTrace: cleanupStackTrace,
          );
        }
      }
      rethrow;
    }

    return NovelImportResult(
      novelId: novelId,
      screenplayId: screenplayId,
      chapterCount: parsed.chapters.length,
      volumeCount: parsed.volumeCount,
      wordCount: parsed.wordCount,
    );
  }

  bool _isVolumeHeading(String line) {
    if (line.isEmpty || line.length > 80) {
      return false;
    }
    return RegExp(
      r'^(第\s*[0-9零〇一二两三四五六七八九十百千万]+\s*[卷部集篇]|卷\s*[0-9零〇一二两三四五六七八九十百千万]+)(\s|[:：]|$)',
      caseSensitive: false,
    ).hasMatch(line);
  }

  bool _isChapterHeading(String line) {
    if (line.isEmpty || line.length > 100) {
      return false;
    }
    return RegExp(
          r'^((正文\s+)?第\s*[0-9零〇一二两三四五六七八九十百千万]+\s*[章节回]|番外|序章|楔子)(\s|[:：]|$)',
          caseSensitive: false,
        ).hasMatch(line) ||
        RegExp(
          r'^(chapter\s+\d+|prologue|epilogue)(\s|[:：]|$)',
          caseSensitive: false,
        ).hasMatch(line);
  }

  String _fallbackChapterTitle(String fallbackTitle) {
    final title = fallbackTitle.trim();
    return title.isEmpty ? '正文' : title;
  }
}

class NovelImportException implements Exception {
  const NovelImportException(this.message);

  final String message;

  @override
  String toString() => message;
}
