// 职责: 封面档案读稿服务 — 读开头三章抽出品类/色温/主角/时代与带出处的意象，并落 novel_states。
// 关联文件:
//   lib/shared/models/cover_brief.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/database/novel_content_daos/novel_state_dao.dart
//   lib/shared/services/ai/chat.dart
// 遵循的 Rules:
//   .agents/rules/ai-calling.md
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md

import 'dart:async';
import 'dart:convert';

import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_chat_models.dart';
import '../../models/cover_brief.dart';
import '../../utils/json_repair.dart';
import 'chat.dart';

final _log = AppLogger.forModule('CoverBrief');

/// [NovelStates] 里存封面档案的 key。
const String novelStateKeyCoverBrief = 'cover_brief';

/// 读稿进行中。读完落回 [novelStateStatusIdle]。
const String coverBriefStatusReading = 'reading';

/// 只读开头三章：封面要的是作品的调子和开场意象，不是全书剧情，
/// 读全稿既慢又贵，收益也不在封面上。
const int coverBriefChapterCount = 3;

/// 每章送进模型的正文上限，超出截断。
const int _chapterExcerptRunes = 2000;

/// 读稿整段（拿 client + 一次补全）的上限。超时后复位 idle，避免进度条永远转。
const Duration coverBriefReadTimeout = Duration(seconds: 60);

const _systemPrompt = '''
你是一位封面美术指导。你会读一部长篇小说的开头，判断它的封面该往哪个方向做。

## 你要给出的判断
- category: 品类，形如「历史 · 群像」「都市 · 悬疑」，不超过 12 字
- style: 风格，一句话或短词。可参考这些方向：水墨写意、版画质感、极简文字、摄影写实、手绘插画；正文更贴别的画法时按正文写，不要硬套
- palette: 色调，一句话或短词。可参考：墨与宣、黄铜、夜航、朱砂、素灰；正文更贴别的色调时按正文写
- temperature: 色温倾向，一句话，说明以什么为底、暖色留给什么
- figure: 主角怎么处理，一句话。群像或主角形象不清晰时，明说建议用意象替代具体人物
- era: 时代与器物约束，一句话，点明要避开什么
- motifs: 2 到 4 个候选意象，每个必须能指回具体章节

## 规则
1. 只写你从正文里真的读到的东西，不要推测、不要套模板。
2. 每个意象必须带 from 字段，写清出自哪一章（用给你的章节标题）。找不到出处的意象直接不要。
3. 意象要是画得出来的画面，不是抽象概念。「江面与渔火」可以，「命运的重量」不行。
4. 全部用中文书写，每项都简短。

## 输出格式
只返回 JSON 对象，不要任何解释文字：
{"category":"...","style":"...","palette":"...","temperature":"...","figure":"...","era":"...","motifs":[{"text":"...","from":"..."}]}
''';

/// 档案的当前状态。四态（未读 / 读取中 / 已读 / 已读但过时）里前三态由它表达，
/// 过时与否要比对稿子体量，由 [isCoverBriefStale] 另算。
class CoverBriefState {
  const CoverBriefState({this.brief, this.reading = false});

  final CoverBrief? brief;
  final bool reading;
}

class CoverBriefService {
  CoverBriefService({
    required this._clientFactory,
    this._timeout = coverBriefReadTimeout,
  });

  final Future<AiClient?> Function() _clientFactory;
  final Duration _timeout;

  /// 本进程正在读的内容库。用来区分「活着的读稿」和进程死后留在库里的孤儿 reading。
  final Set<NovelContentDatabase> _reading = {};

  /// 读出已存的档案；没读过返回 null。
  Future<CoverBrief?> load(NovelContentDatabase contentDb) async {
    final state = await contentDb.novelStateDao.get(novelStateKeyCoverBrief);
    final data = state?.data;
    if (data == null || data.isEmpty) return null;
    try {
      return CoverBrief.fromJson(jsonDecode(data));
    } catch (error, stackTrace) {
      _log.error(
        'failed to decode stored brief',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Stream<CoverBriefState> watch(NovelContentDatabase contentDb) async* {
    try {
      await _recoverOrphanedReading(contentDb);
    } catch (error, stackTrace) {
      _log.error(
        'failed to recover orphaned reading',
        error: error,
        stackTrace: stackTrace,
      );
    }
    yield* contentDb.novelStateDao
        .watch(novelStateKeyCoverBrief)
        .map(_stateFromRow);
  }

  /// 拿当前稿子的体量与来源章节时间，用来判断已有档案是否过时。
  Future<CoverBriefStats> currentStats(
    NovelContentDatabase contentDb, {
    required CoverBrief? brief,
  }) async {
    final listStats = await contentDb.chapterDao.getListStats();
    final sourceUpdatedAt = <String, DateTime>{};
    if (brief != null && brief.sources.isNotEmpty) {
      final chapters = await contentDb.chapterDao.getByIds(
        brief.sources.map((source) => source.chapterId).toSet(),
      );
      for (final chapter in chapters) {
        sourceUpdatedAt[chapter.id] = chapter.updatedAt;
      }
    }
    return CoverBriefStats(
      chapterCount: listStats.chapterCount,
      wordCount: listStats.totalWordCount,
      sourceUpdatedAt: sourceUpdatedAt,
    );
  }

  /// 读一遍开头三章并落档案。
  ///
  /// 读不成（没有 AI client、没有正文、模型返回不可解析）时返回 null 并把状态
  /// 复位到 idle —— 读稿失败不该挡住出图，提示词里少那几行而已。
  Future<CoverBrief?> read({
    required NovelContentDatabase contentDb,
    required String novelTitle,
    required String novelDescription,
  }) async {
    final chapters = await _leadingChapters(contentDb);
    if (chapters.isEmpty) {
      _log.debug('no chapter content to read');
      return null;
    }

    if (!_reading.add(contentDb)) {
      _log.debug('read already in flight');
      return null;
    }

    final clock = Stopwatch()..start();
    try {
      await _upsert(
        contentDb,
        status: coverBriefStatusReading,
        // 读的过程中保留旧档案，读失败时界面不会突然变空。
        data: (await contentDb.novelStateDao.get(
          novelStateKeyCoverBrief,
        ))?.data,
      );
      final client = await _clientFactory().timeout(_remaining(clock));
      if (client == null) {
        _log.debug('no AI client available');
        return null;
      }
      final response = await client
          .chatCompletion([
            AiMessage.system(id: 'cover_brief_sys', content: _systemPrompt),
            AiMessage.user(
              id: 'cover_brief_usr',
              content: _buildUserPrompt(
                novelTitle: novelTitle,
                novelDescription: novelDescription,
                chapters: chapters,
              ),
            ),
          ])
          .timeout(
            _remaining(clock),
            onTimeout: () {
              client.cancel();
              throw TimeoutException('coverBrief.read', _timeout);
            },
          );

      final parsed = parseCoverBriefResponse(response);
      if (parsed == null) {
        _log.error('model returned an unparseable brief');
        return null;
      }

      final listStats = await contentDb.chapterDao.getListStats();
      final brief = CoverBrief(
        category: parsed.category,
        style: parsed.style,
        palette: parsed.palette,
        temperature: parsed.temperature,
        figure: parsed.figure,
        era: parsed.era,
        motifs: parsed.motifs,
        readAt: DateTime.now(),
        sources: chapters
            .map(
              (chapter) => CoverBriefSource(
                chapterId: chapter.id,
                updatedAt: chapter.updatedAt,
              ),
            )
            .toList(growable: false),
        chapterCount: listStats.chapterCount,
        wordCount: listStats.totalWordCount,
      );
      await _upsert(
        contentDb,
        status: novelStateStatusIdle,
        data: jsonEncode(brief.toJson()),
      );
      return brief;
    } on TimeoutException catch (error, stackTrace) {
      _log.error('read timed out', error: error, stackTrace: stackTrace);
      return null;
    } catch (error, stackTrace) {
      _log.error('read failed', error: error, stackTrace: stackTrace);
      return null;
    } finally {
      _reading.remove(contentDb);
      final state = await contentDb.novelStateDao.get(novelStateKeyCoverBrief);
      if (state?.status == coverBriefStatusReading) {
        await _upsert(
          contentDb,
          status: novelStateStatusIdle,
          data: state?.data,
        );
      }
    }
  }

  /// 库里还标着 reading、但本进程并没有对应的读稿任务：进程中途退出留下的孤儿。
  /// 封面页会把 reading 当成进行中并跳过自动重读，不复位就会一直转圈。
  Future<void> _recoverOrphanedReading(NovelContentDatabase contentDb) async {
    if (_reading.contains(contentDb)) {
      return;
    }
    final state = await contentDb.novelStateDao.get(novelStateKeyCoverBrief);
    if (state?.status != coverBriefStatusReading) {
      return;
    }
    _log.warning('clearing orphaned cover_brief reading status');
    await _upsert(contentDb, status: novelStateStatusIdle, data: state?.data);
  }

  Duration _remaining(Stopwatch clock) {
    final left = _timeout - clock.elapsed;
    if (left <= Duration.zero) {
      throw TimeoutException('coverBrief.read', _timeout);
    }
    return left;
  }

  Future<void> _upsert(
    NovelContentDatabase contentDb, {
    required String status,
    String? data,
  }) async {
    try {
      await contentDb.novelStateDao.upsert(
        key: novelStateKeyCoverBrief,
        status: status,
        data: data,
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=novel_states op=UPDATE key=$novelStateKeyCoverBrief '
        'status=$status error=$error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  CoverBriefState _stateFromRow(NovelState? state) {
    final data = state?.data;
    final reading = state?.status == coverBriefStatusReading;
    if (data == null || data.isEmpty) {
      return CoverBriefState(reading: reading);
    }
    try {
      return CoverBriefState(
        brief: CoverBrief.fromJson(jsonDecode(data)),
        reading: reading,
      );
    } catch (_) {
      return CoverBriefState(reading: reading);
    }
  }

  /// 开头三个有正文的章节，按树顺序。卷节点和空章跳过。
  Future<List<Chapter>> _leadingChapters(NovelContentDatabase contentDb) async {
    final all = await contentDb.chapterDao.getAll();
    return all
        .where(
          (chapter) =>
              chapter.type != nodeTypeVolume &&
              chapter.content.trim().isNotEmpty,
        )
        .take(coverBriefChapterCount)
        .toList(growable: false);
  }

  String _buildUserPrompt({
    required String novelTitle,
    required String novelDescription,
    required List<Chapter> chapters,
  }) {
    final buffer = StringBuffer()..writeln('书名：$novelTitle');
    final description = novelDescription.trim();
    if (description.isNotEmpty) {
      buffer.writeln('简介：$description');
    }
    buffer.writeln();
    buffer.writeln('以下是开头 ${chapters.length} 章的正文（可能已截断）：');
    for (final chapter in chapters) {
      final title = chapter.title?.trim();
      buffer
        ..writeln()
        ..writeln('## ${title == null || title.isEmpty ? '无标题章节' : title}')
        ..writeln(_truncate(chapter.content.trim(), _chapterExcerptRunes));
    }
    return buffer.toString().trim();
  }

  String _truncate(String text, int maxRunes) {
    final runes = text.runes.toList(growable: false);
    if (runes.length <= maxRunes) return text;
    return '${String.fromCharCodes(runes.take(maxRunes))}…';
  }
}

/// 模型答出来的档案内容，还没配上读稿快照。
class CoverBriefDraft {
  const CoverBriefDraft({
    required this.category,
    required this.style,
    required this.palette,
    required this.temperature,
    required this.figure,
    required this.era,
    required this.motifs,
  });

  final String category;
  final String style;
  final String palette;
  final String temperature;
  final String figure;
  final String era;
  final List<CoverBriefMotif> motifs;
}

/// 解析模型返回的档案 JSON。答非所问、全空或解不出 JSON 时返回 null。
CoverBriefDraft? parseCoverBriefResponse(String response) {
  final json = _extractJsonObject(response);
  if (json == null) return null;
  final category = json['category']?.toString().trim() ?? '';
  final style = json['style']?.toString().trim() ?? '';
  final palette = json['palette']?.toString().trim() ?? '';
  final temperature = json['temperature']?.toString().trim() ?? '';
  final figure = json['figure']?.toString().trim() ?? '';
  final era = json['era']?.toString().trim() ?? '';
  final motifs = <CoverBriefMotif>[
    if (json['motifs'] case final List<dynamic> raw)
      ...raw.map(CoverBriefMotif.fromJson).nonNulls,
  ];
  // 全空说明模型没答上来，别把一份空档案落进库里装作读过了。
  if (category.isEmpty &&
      style.isEmpty &&
      palette.isEmpty &&
      temperature.isEmpty &&
      figure.isEmpty &&
      era.isEmpty &&
      motifs.isEmpty) {
    return null;
  }
  return CoverBriefDraft(
    category: category,
    style: style,
    palette: palette,
    temperature: temperature,
    figure: figure,
    era: era,
    motifs: motifs,
  );
}

/// 模型常把 JSON 包在 ```json 代码块或前后说明里。这类提取 + 修复走仓库已有的
/// [tryExtractJson]（宽松、失败返回 null），不要在这里再写一份括号配对。
Map<String, dynamic>? _extractJsonObject(String response) {
  final decoded = tryExtractJson(response);
  if (decoded is Map<String, dynamic>) return decoded;
  if (decoded is Map) return Map<String, dynamic>.from(decoded);
  return null;
}
