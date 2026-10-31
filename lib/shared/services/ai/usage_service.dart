// 职责: 记录本地 AI Token 用量，并提供统计、聚合与明细查询。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/providers/usage_query_providers.dart
//   lib/shared/services/ai/usage_hook.dart
// 遵循的 Rules:
//   .agents/rules/db-query-aggregation.md
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md

import 'dart:async';

import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../agent/client.dart' show AiUsage;
import '../../logger/app_logger.dart';
import '../../utils/random_id.dart';

final _log = AppLogger.forModule('Usage');

/// AI 用量统计来源。写入 `ai_usages.source` 的值必须与这里一致。
/// 新增枚举值前必须先与用户确认。
abstract final class UsageSources {
  static const chat = 'chat';
  static const assistant = 'assistant';
  static const roleplay = 'roleplay';
  static const monologue = 'monologue';
  static const theater = 'theater';
  static const council = 'council';
  static const plugin = 'plugin';

  static const values = [
    chat,
    assistant,
    roleplay,
    monologue,
    theater,
    council,
    plugin,
  ];

  /// 会话模式值作为统计来源。
  static String canonicalize(String source) {
    return source;
  }
}

/// 每日用量统计
class DailyUsage {
  final DateTime date;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;
  final int totalTokens;
  final int requestCount;

  const DailyUsage({
    required this.date,
    required this.inputTokens,
    required this.outputTokens,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
    required this.totalTokens,
    required this.requestCount,
  });

  int get year => date.year;
  int get month => date.month;
  int get day => date.day;
}

/// 模型用量统计
class ModelUsage {
  final String model;
  final String? provider;
  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final int requestCount;

  const ModelUsage({
    required this.model,
    this.provider,
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    required this.requestCount,
  });

  double get percentage => 0; // 需要外部计算
}

/// 时间段用量汇总
class UsageSummary {
  final int totalInputTokens;
  final int totalOutputTokens;
  final int totalCacheReadTokens;
  final int totalCacheWriteTokens;
  final int totalReasoningTokens;

  /// 默认展示口径，仅包含净输入与输出，不累计缓存读写。
  final int totalTokens;
  final int requestCount;
  final DateTime? startDate;
  final DateTime? endDate;

  const UsageSummary({
    this.totalInputTokens = 0,
    this.totalOutputTokens = 0,
    this.totalCacheReadTokens = 0,
    this.totalCacheWriteTokens = 0,
    this.totalReasoningTokens = 0,
    this.totalTokens = 0,
    this.requestCount = 0,
    this.startDate,
    this.endDate,
  });

  double get averagePerDay {
    if (startDate == null || endDate == null) return 0;
    final days = endDate!.difference(startDate!).inDays + 1;
    if (days <= 0) return 0;
    return totalTokens / days;
  }
}

class UsageSourceSummary {
  const UsageSourceSummary({
    required this.source,
    required this.totalTokens,
    required this.requestCount,
  });

  final String source;
  final int totalTokens;
  final int requestCount;
}

class DailySourceUsage {
  const DailySourceUsage({required this.date, required this.tokensBySource});

  final DateTime date;
  final Map<String, int> tokensBySource;

  int tokensFor(String source) => tokensBySource[source] ?? 0;
}

class UsageRunSummary {
  const UsageRunSummary({
    required this.id,
    required this.label,
    required this.totalTokens,
    required this.requestCount,
    required this.lastUsed,
  });

  final String id;
  final String label;
  final int totalTokens;
  final int requestCount;
  final DateTime lastUsed;
}

class UsageSubagentSummary {
  const UsageSubagentSummary({
    required this.sessionId,
    required this.name,
    required this.agentSlug,
    required this.provider,
    required this.model,
    required this.totalTokens,
    required this.requestCount,
    required this.runs,
  });

  final String sessionId;
  final String name;
  final String? agentSlug;
  final String? provider;
  final String? model;
  final int totalTokens;
  final int requestCount;
  final List<UsageRunSummary> runs;

  String get displayName {
    final normalizedName = name.trim();
    if (normalizedName.isNotEmpty) {
      return normalizedName;
    }
    final normalizedSlug = agentSlug?.trim();
    return normalizedSlug == null || normalizedSlug.isEmpty
        ? sessionId
        : normalizedSlug;
  }
}

class UsageSessionSummary {
  const UsageSessionSummary({
    required this.id,
    required this.title,
    required this.mode,
    required this.provider,
    required this.model,
    required this.totalTokens,
    required this.requestCount,
    required this.lastUsed,
    this.contextInputTokens = 0,
  });

  final String id;
  final String title;
  final String mode;
  final String? provider;
  final String? model;
  final int totalTokens;
  final int requestCount;
  final DateTime lastUsed;
  final int contextInputTokens;
}

class UsageSessionDetail {
  const UsageSessionDetail({
    required this.session,
    required this.tokens,
    required this.mainTokens,
    required this.mainRequestCount,
    required this.subagents,
    required this.records,
  });

  final UsageSessionSummary session;
  final UsageSummary tokens;
  final int mainTokens;
  final int mainRequestCount;
  final List<UsageSubagentSummary> subagents;
  final List<AiUsageRecord> records;
}

class UsageSessionMeter {
  const UsageSessionMeter({
    required this.totalTokens,
    required this.contextInputTokens,
    required this.model,
  });

  final int totalTokens;
  final int contextInputTokens;
  final String? model;
}

/// 会话用量列表的排序方式。
enum UsageSessionSort { last_used_descending, total_tokens_descending }

/// Usage 查询过滤器
class UsageFilter {
  final DateTime? startDate;
  final DateTime? endDate;
  final String? providerId;
  final String? model;
  final String? source;
  final UsageSessionSort sessionSort;

  const UsageFilter({
    this.startDate,
    this.endDate,
    this.providerId,
    this.model,
    this.source,
    this.sessionSort = UsageSessionSort.last_used_descending,
  });

  /// 创建稳定的自然月筛选范围，避免同月内因调用时刻变化产生不同查询键。
  factory UsageFilter.calendarMonth(
    DateTime date, {
    UsageSessionSort sessionSort = UsageSessionSort.last_used_descending,
  }) {
    final startDate = date.isUtc
        ? DateTime.utc(date.year, date.month)
        : DateTime(date.year, date.month);
    final nextMonth = date.isUtc
        ? DateTime.utc(date.year, date.month + 1)
        : DateTime(date.year, date.month + 1);
    return UsageFilter(
      startDate: startDate,
      endDate: nextMonth.subtract(const Duration(seconds: 1)),
      sessionSort: sessionSort,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UsageFilter &&
          startDate == other.startDate &&
          endDate == other.endDate &&
          providerId == other.providerId &&
          model == other.model &&
          source == other.source &&
          sessionSort == other.sessionSort;

  @override
  int get hashCode =>
      Object.hash(startDate, endDate, providerId, model, source, sessionSort);
}

/// AI Token Usage 统计服务
class UsageService {
  final AppDatabase _appDatabase;

  UsageService({required this._appDatabase});

  /// 记录一次 LLM 调用的 token 用量。
  ///
  /// 输入写净 Token 数，缓存读写单独记录，避免聚合时重复计数。
  Future<void> recordUsage({
    required String providerId,
    required String model,
    required AiUsage usage,
    String? sessionId,
    String? novelId,
    String source = 'chat',
    String? runId,
    String? runLabel,
  }) async {
    final id = buildRandomId('usage');
    // AiUsage.inputTokens 含 cache（gross），此处扣除缓存得到净输入。
    final netInput =
        usage.inputTokens - usage.cacheReadTokens - usage.cacheWriteTokens;
    try {
      await _appDatabase
          .into(_appDatabase.aiUsages)
          .insert(
            AiUsagesCompanion.insert(
              id: id,
              providerId: providerId,
              model: model,
              sessionId: Value(sessionId),
              novelId: Value(novelId),
              source: Value(source),
              runId: Value(runId),
              runLabel: Value(runLabel),
              inputTokens: Value(netInput < 0 ? 0 : netInput),
              outputTokens: Value(usage.outputTokens),
              cacheReadTokens: Value(usage.cacheReadTokens),
              cacheWriteTokens: Value(usage.cacheWriteTokens),
              reasoningTokens: Value(usage.reasoningTokens),
              createdAt: Value(DateTime.now()),
            ),
          );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] table=ai_usages operation=INSERT '
        'id=$id sessionId=$sessionId error=$error',
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 获取每日用量统计
  Future<List<DailyUsage>> getDailyUsage(UsageFilter filter) async {
    final rows = await _dailyUsageQuery(filter).get();
    return rows.map(_mapDailyUsage).toList();
  }

  Stream<List<DailyUsage>> watchDailyUsage(UsageFilter filter) {
    return _dailyUsageQuery(
      filter,
    ).watch().map((rows) => rows.map(_mapDailyUsage).toList());
  }

  Selectable<QueryRow> _dailyUsageQuery(UsageFilter filter) {
    return _appDatabase.customSelect(
      '''
SELECT
  date(created_at, 'unixepoch', 'localtime') AS usage_day,
  COALESCE(SUM(input_tokens), 0) AS input_tokens,
  COALESCE(SUM(output_tokens), 0) AS output_tokens,
  COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tokens,
  COALESCE(SUM(cache_write_tokens), 0) AS cache_write_tokens,
  COALESCE(SUM(reasoning_tokens), 0) AS reasoning_tokens,
  COUNT(*) AS request_count
FROM ai_usages
${_whereClause(filter)}
GROUP BY usage_day
ORDER BY usage_day ASC
''',
      variables: _whereVariables(filter),
      readsFrom: {_appDatabase.aiUsages},
    );
  }

  DailyUsage _mapDailyUsage(QueryRow row) {
    final inputTokens = row.read<int>('input_tokens');
    final outputTokens = row.read<int>('output_tokens');
    final cacheReadTokens = row.read<int>('cache_read_tokens');
    final cacheWriteTokens = row.read<int>('cache_write_tokens');
    return DailyUsage(
      date: DateTime.parse(row.read<String>('usage_day')),
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadTokens: cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens,
      reasoningTokens: row.read<int>('reasoning_tokens'),
      totalTokens: inputTokens + outputTokens,
      requestCount: row.read<int>('request_count'),
    );
  }

  /// 获取汇总统计
  Future<UsageSummary> getSummary(UsageFilter filter) async {
    return _mapUsageSummary(await _summaryQuery(filter).getSingle(), filter);
  }

  Stream<UsageSummary> watchSummary(UsageFilter filter) {
    return _summaryQuery(
      filter,
    ).watchSingle().map((row) => _mapUsageSummary(row, filter));
  }

  Selectable<QueryRow> _summaryQuery(UsageFilter filter) {
    return _appDatabase.customSelect(
      '''
SELECT
  COALESCE(SUM(input_tokens), 0) AS input_tokens,
  COALESCE(SUM(output_tokens), 0) AS output_tokens,
  COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tokens,
  COALESCE(SUM(cache_write_tokens), 0) AS cache_write_tokens,
  COALESCE(SUM(reasoning_tokens), 0) AS reasoning_tokens,
  COUNT(*) AS request_count
FROM ai_usages
${_whereClause(filter)}
''',
      variables: _whereVariables(filter),
      readsFrom: {_appDatabase.aiUsages},
    );
  }

  UsageSummary _mapUsageSummary(QueryRow row, UsageFilter filter) {
    final totalInput = row.read<int>('input_tokens');
    final totalOutput = row.read<int>('output_tokens');
    final totalCacheRead = row.read<int>('cache_read_tokens');
    final totalCacheWrite = row.read<int>('cache_write_tokens');

    return UsageSummary(
      totalInputTokens: totalInput,
      totalOutputTokens: totalOutput,
      totalCacheReadTokens: totalCacheRead,
      totalCacheWriteTokens: totalCacheWrite,
      totalReasoningTokens: row.read<int>('reasoning_tokens'),
      totalTokens: totalInput + totalOutput,
      requestCount: row.read<int>('request_count'),
      startDate: filter.startDate,
      endDate: filter.endDate,
    );
  }

  Future<List<UsageSourceSummary>> getSourceUsage(UsageFilter filter) async {
    return (await _sourceUsageQuery(
      filter,
    ).get()).map(_mapSourceUsage).toList(growable: false);
  }

  Stream<List<UsageSourceSummary>> watchSourceUsage(UsageFilter filter) {
    return _sourceUsageQuery(
      filter,
    ).watch().map((rows) => rows.map(_mapSourceUsage).toList(growable: false));
  }

  Selectable<QueryRow> _sourceUsageQuery(UsageFilter filter) {
    return _appDatabase.customSelect(
      '''
SELECT
  source AS usage_source,
  COALESCE(SUM(${_displayTokensSql()}), 0) AS total_tokens,
  COUNT(*) AS request_count
FROM ai_usages
${_whereClause(filter)}
GROUP BY source
ORDER BY total_tokens DESC
''',
      variables: _whereVariables(filter),
      readsFrom: {_appDatabase.aiUsages},
    );
  }

  UsageSourceSummary _mapSourceUsage(QueryRow row) {
    return UsageSourceSummary(
      source: row.read<String>('usage_source'),
      totalTokens: row.read<int>('total_tokens'),
      requestCount: row.read<int>('request_count'),
    );
  }

  Future<List<DailySourceUsage>> getDailySourceUsage(UsageFilter filter) async {
    return (await _dailySourceUsageQuery(
      filter,
    ).get()).map(_mapDailySourceUsage).toList(growable: false);
  }

  Stream<List<DailySourceUsage>> watchDailySourceUsage(UsageFilter filter) {
    return _dailySourceUsageQuery(filter).watch().map(
      (rows) => rows.map(_mapDailySourceUsage).toList(growable: false),
    );
  }

  Selectable<QueryRow> _dailySourceUsageQuery(UsageFilter filter) {
    final columns = <String>[
      for (final source in UsageSources.values)
        "COALESCE(SUM(CASE WHEN source = '$source' "
            'THEN ${_displayTokensSql()} ELSE 0 END), 0) AS $source',
      "COALESCE(SUM(CASE WHEN source NOT IN "
          "('${UsageSources.values.join("','")}') THEN ${_displayTokensSql()} "
          'ELSE 0 END), 0) AS other',
    ];
    return _appDatabase.customSelect(
      '''
SELECT
  date(created_at, 'unixepoch', 'localtime') AS usage_day,
  ${columns.join(',\n  ')}
FROM ai_usages
${_whereClause(filter)}
GROUP BY usage_day
ORDER BY usage_day ASC
''',
      variables: _whereVariables(filter),
      readsFrom: {_appDatabase.aiUsages},
    );
  }

  DailySourceUsage _mapDailySourceUsage(QueryRow row) {
    return DailySourceUsage(
      date: DateTime.parse(row.read<String>('usage_day')),
      tokensBySource: {
        for (final source in [...UsageSources.values, 'other'])
          source: row.read<int>(source),
      },
    );
  }

  /// 获取今日用量
  Future<UsageSummary> getTodayUsage() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return getSummary(UsageFilter(startDate: today, endDate: now));
  }

  /// 获取本月用量
  Future<UsageSummary> getThisMonthUsage() async {
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1);
    return getSummary(UsageFilter(startDate: startOfMonth, endDate: now));
  }

  /// 获取最近 N 天用量
  Future<List<DailyUsage>> getLastNDaysUsage(int days) async {
    final now = DateTime.now();
    final start = now.subtract(Duration(days: days - 1));
    final startDate = DateTime(start.year, start.month, start.day);
    return getDailyUsage(UsageFilter(startDate: startDate, endDate: now));
  }

  /// 获取用量明细记录总数
  Future<int> getUsageRecordCount(UsageFilter filter) async {
    final row = await _usageRecordCountQuery(filter).getSingle();
    return row.read<int>('cnt');
  }

  Stream<int> watchUsageRecordCount(UsageFilter filter) {
    return _usageRecordCountQuery(
      filter,
    ).watchSingle().map((row) => row.read<int>('cnt'));
  }

  Selectable<QueryRow> _usageRecordCountQuery(UsageFilter filter) {
    return _appDatabase.customSelect(
      'SELECT COUNT(*) AS cnt FROM ai_usages ${_whereClause(filter)}',
      variables: _whereVariables(filter),
      readsFrom: {_appDatabase.aiUsages},
    );
  }

  /// 获取用量明细分页列表
  Future<List<AiUsageRecord>> getUsageRecords(
    UsageFilter filter, {
    required int limit,
    required int offset,
  }) async {
    return (await _usageRecordsQuery(
      filter,
      limit: limit,
      offset: offset,
    ).get()).map(_mapUsageRecord).toList(growable: false);
  }

  Stream<List<AiUsageRecord>> watchUsageRecords(
    UsageFilter filter, {
    required int limit,
    required int offset,
  }) {
    return _usageRecordsQuery(
      filter,
      limit: limit,
      offset: offset,
    ).watch().map((rows) => rows.map(_mapUsageRecord).toList(growable: false));
  }

  Selectable<QueryRow> _usageRecordsQuery(
    UsageFilter filter, {
    required int limit,
    required int offset,
  }) {
    return _appDatabase.customSelect(
      '''
SELECT * FROM ai_usages
${_whereClause(filter)}
ORDER BY created_at DESC
LIMIT ? OFFSET ?
''',
      variables: [
        ..._whereVariables(filter),
        Variable(limit),
        Variable(offset),
      ],
      readsFrom: {_appDatabase.aiUsages},
    );
  }

  AiUsageRecord _mapUsageRecord(QueryRow row) {
    return AiUsageRecord(
      id: row.read<String>('id'),
      providerId: row.read<String>('provider_id'),
      model: row.read<String>('model'),
      sessionId: row.read<String?>('session_id'),
      novelId: row.read<String?>('novel_id'),
      source: row.read<String>('source'),
      runId: row.read<String?>('run_id'),
      runLabel: row.read<String?>('run_label'),
      inputTokens: row.read<int>('input_tokens'),
      outputTokens: row.read<int>('output_tokens'),
      cacheReadTokens: row.read<int>('cache_read_tokens'),
      cacheWriteTokens: row.read<int>('cache_write_tokens'),
      reasoningTokens: row.read<int>('reasoning_tokens'),
      createdAt: row.read<DateTime>('created_at'),
    );
  }

  Stream<UsageSessionMeter?> watchSessionMeter(String sessionId) {
    return _sessionMeterQuery(sessionId).watchSingle().map((row) {
      if (row.read<int>('request_count') == 0) return null;
      return UsageSessionMeter(
        totalTokens: row.read<int>('total_tokens'),
        contextInputTokens: row.read<int>('context_tokens'),
        model: row.read<String?>('model'),
      );
    });
  }

  Selectable<QueryRow> _sessionMeterQuery(String sessionId) {
    return _appDatabase.customSelect(
      '''
WITH relevant AS (
  SELECT usage.*
  FROM ai_usages AS usage
  WHERE usage.session_id = ?
     OR usage.session_id IN (
       SELECT child.id FROM ai_chat_sessions AS child WHERE child.parent_id = ?
     )
), latest AS (
  SELECT model,
         input_tokens + cache_read_tokens + cache_write_tokens AS context_tokens
  FROM relevant
  ORDER BY CASE WHEN session_id = ? THEN 0 ELSE 1 END, created_at DESC
  LIMIT 1
)
SELECT COALESCE(SUM(${_displayTokensSql('relevant')}), 0) AS total_tokens,
       COUNT(*) AS request_count,
       COALESCE((SELECT context_tokens FROM latest), 0) AS context_tokens,
       (SELECT model FROM latest) AS model
FROM relevant
''',
      variables: [
        Variable(sessionId),
        Variable(sessionId),
        Variable(sessionId),
      ],
      readsFrom: {_appDatabase.aiUsages, _appDatabase.aiChatSessions},
    );
  }

  Future<List<UsageSessionSummary>> getTopSessions(
    UsageFilter filter, {
    int limit = 50,
  }) async {
    return (await _topSessionsQuery(
      filter,
      limit: limit,
    ).get()).map(_mapSessionSummary).toList(growable: false);
  }

  Stream<List<UsageSessionSummary>> watchTopSessions(
    UsageFilter filter, {
    int limit = 50,
  }) {
    return _topSessionsQuery(filter, limit: limit).watch().map(
      (rows) => rows.map(_mapSessionSummary).toList(growable: false),
    );
  }

  Selectable<QueryRow> _topSessionsQuery(
    UsageFilter filter, {
    required int limit,
  }) {
    final orderBy = switch (filter.sessionSort) {
      UsageSessionSort.last_used_descending =>
        'last_used DESC, total_tokens DESC',
      UsageSessionSort.total_tokens_descending =>
        'total_tokens DESC, last_used DESC',
    };
    return _appDatabase.customSelect(
      '''
WITH attributed AS (
  SELECT
    u.*,
    COALESCE(child.parent_id, child.id, u.session_id) AS root_id
  FROM ai_usages AS u
  LEFT JOIN ai_chat_sessions AS child ON child.id = u.session_id
  ${_whereClause(filter, tableAlias: 'u')}
)
SELECT
  attributed.root_id AS session_id,
  COALESCE(
    NULLIF(root.title, ''),
    NULLIF(assistant.chat_id, ''),
    attributed.root_id
  ) AS title,
   CASE WHEN assistant.id IS NOT NULL THEN '${UsageSources.assistant}'
       ELSE COALESCE(
         root.mode,
         attributed.source
       )
  END AS mode,
  COALESCE(root.provider, assistant.provider, MAX(attributed.provider_id)) AS provider,
  COALESCE(root.model, assistant.model, MAX(attributed.model)) AS model,
  SUM(${_displayTokensSql('attributed')}) AS total_tokens,
  COUNT(*) AS request_count,
  MAX(attributed.created_at) AS last_used
FROM attributed
LEFT JOIN ai_chat_sessions AS root ON root.id = attributed.root_id
LEFT JOIN assistant_sessions AS assistant ON assistant.id = attributed.root_id
WHERE attributed.root_id IS NOT NULL AND attributed.root_id != ''
GROUP BY attributed.root_id
ORDER BY $orderBy
LIMIT ?
''',
      variables: [..._whereVariables(filter), Variable(limit)],
      readsFrom: {
        _appDatabase.aiUsages,
        _appDatabase.aiChatSessions,
        _appDatabase.assistantSessions,
      },
    );
  }

  UsageSessionSummary _mapSessionSummary(QueryRow row) {
    return UsageSessionSummary(
      id: row.read<String>('session_id'),
      title: row.read<String>('title'),
      mode: UsageSources.canonicalize(row.read<String>('mode')),
      provider: row.read<String?>('provider'),
      model: row.read<String?>('model'),
      totalTokens: row.read<int>('total_tokens'),
      requestCount: row.read<int>('request_count'),
      lastUsed: _readSqlDateTime(row.data['last_used']),
    );
  }

  Stream<UsageSessionDetail?> watchSessionDetail(String sessionId) {
    return _appDatabase
        .customSelect(
          'SELECT 1',
          readsFrom: {
            _appDatabase.aiUsages,
            _appDatabase.aiChatSessions,
            _appDatabase.assistantSessions,
          },
        )
        .watchSingle()
        .asyncMap((_) => getSessionDetail(sessionId));
  }

  Future<UsageSessionDetail?> getSessionDetail(String sessionId) async {
    final sessionRow = await _appDatabase
        .customSelect(
          'SELECT id, title, provider, model, mode '
          'FROM ai_chat_sessions WHERE id = ? LIMIT 1',
          variables: [Variable(sessionId)],
          readsFrom: {_appDatabase.aiChatSessions},
        )
        .getSingleOrNull();
    final assistantRow = sessionRow == null
        ? await _appDatabase
              .customSelect(
                'SELECT id, chat_id, channel_type, provider, model '
                'FROM assistant_sessions WHERE id = ? LIMIT 1',
                variables: [Variable(sessionId)],
                readsFrom: {_appDatabase.assistantSessions},
              )
              .getSingleOrNull()
        : null;
    const relevantWhere = '''
WHERE usage.session_id = ?
   OR usage.session_id IN (
     SELECT child.id FROM ai_chat_sessions AS child WHERE child.parent_id = ?
   )
''';
    final variables = [Variable(sessionId), Variable(sessionId)];
    final aggregate = await _appDatabase
        .customSelect(
          '''
SELECT
  COALESCE(SUM(input_tokens), 0) AS input_tokens,
  COALESCE(SUM(output_tokens), 0) AS output_tokens,
  COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tokens,
  COALESCE(SUM(cache_write_tokens), 0) AS cache_write_tokens,
  COALESCE(SUM(reasoning_tokens), 0) AS reasoning_tokens,
  COUNT(*) AS request_count,
  MAX(created_at) AS last_used
FROM ai_usages AS usage
$relevantWhere
''',
          variables: variables,
          readsFrom: {_appDatabase.aiUsages, _appDatabase.aiChatSessions},
        )
        .getSingle();
    final requestCount = aggregate.read<int>('request_count');
    if (requestCount == 0) {
      return null;
    }
    final latest = await _appDatabase
        .customSelect(
          '''
SELECT provider_id, model, source,
       input_tokens + cache_read_tokens + cache_write_tokens AS context_tokens
FROM ai_usages AS usage
$relevantWhere
ORDER BY CASE WHEN usage.session_id = ? THEN 0 ELSE 1 END, created_at DESC
LIMIT 1
''',
          variables: [...variables, Variable(sessionId)],
          readsFrom: {_appDatabase.aiUsages, _appDatabase.aiChatSessions},
        )
        .getSingle();
    final tokens = _mapUsageSummary(aggregate, const UsageFilter());
    final main = await _appDatabase
        .customSelect(
          '''
SELECT COALESCE(SUM(${_displayTokensSql()}), 0) AS total_tokens,
       COUNT(*) AS request_count
FROM ai_usages
WHERE session_id = ?
''',
          variables: [Variable(sessionId)],
          readsFrom: {_appDatabase.aiUsages},
        )
        .getSingle();
    final childRows = await _appDatabase
        .customSelect(
          '''
SELECT child.id AS session_id, child.title, child.agent_slug,
       child.provider, child.model,
       SUM(${_displayTokensSql('usage')}) AS total_tokens,
       COUNT(*) AS request_count
FROM ai_chat_sessions AS child
JOIN ai_usages AS usage ON usage.session_id = child.id
WHERE child.parent_id = ?
GROUP BY child.id
ORDER BY total_tokens DESC
''',
          variables: [Variable(sessionId)],
          readsFrom: {_appDatabase.aiUsages, _appDatabase.aiChatSessions},
        )
        .get();
    final runRows = await _appDatabase
        .customSelect(
          '''
SELECT usage.session_id, usage.run_id,
       COALESCE(MAX(NULLIF(usage.run_label, '')), usage.run_id) AS run_label,
       SUM(${_displayTokensSql('usage')}) AS total_tokens,
       COUNT(*) AS request_count,
       MAX(usage.created_at) AS last_used
FROM ai_usages AS usage
JOIN ai_chat_sessions AS child ON child.id = usage.session_id
WHERE child.parent_id = ? AND usage.run_id IS NOT NULL
GROUP BY usage.session_id, usage.run_id
ORDER BY last_used DESC
''',
          variables: [Variable(sessionId)],
          readsFrom: {_appDatabase.aiUsages, _appDatabase.aiChatSessions},
        )
        .get();
    final runsBySession = <String, List<UsageRunSummary>>{};
    for (final row in runRows) {
      final childSessionId = row.read<String>('session_id');
      runsBySession
          .putIfAbsent(childSessionId, () => [])
          .add(
            UsageRunSummary(
              id: row.read<String>('run_id'),
              label: row.read<String>('run_label'),
              totalTokens: row.read<int>('total_tokens'),
              requestCount: row.read<int>('request_count'),
              lastUsed: _readSqlDateTime(row.data['last_used']),
            ),
          );
    }
    final records =
        (await _appDatabase
                .customSelect(
                  '''
SELECT usage.* FROM ai_usages AS usage
$relevantWhere
ORDER BY usage.created_at DESC
LIMIT 50
''',
                  variables: variables,
                  readsFrom: {
                    _appDatabase.aiUsages,
                    _appDatabase.aiChatSessions,
                  },
                )
                .get())
            .map(_mapUsageRecord)
            .toList(growable: false);
    final rawMode =
        sessionRow?.read<String>('mode') ??
        (assistantRow != null
            ? UsageSources.assistant
            : latest.read<String>('source'));
    final assistantChatId = assistantRow?.read<String>('chat_id').trim();
    final title =
        sessionRow?.read<String>('title') ??
        (assistantChatId == null || assistantChatId.isEmpty
            ? null
            : assistantChatId) ??
        sessionId;
    final summary = UsageSessionSummary(
      id: sessionId,
      title: title.isEmpty ? sessionId : title,
      mode: UsageSources.canonicalize(rawMode),
      provider:
          sessionRow?.read<String?>('provider') ??
          assistantRow?.read<String?>('provider') ??
          latest.read<String?>('provider_id'),
      model:
          sessionRow?.read<String?>('model') ??
          assistantRow?.read<String?>('model') ??
          latest.read<String?>('model'),
      totalTokens: tokens.totalTokens,
      requestCount: requestCount,
      lastUsed: _readSqlDateTime(aggregate.data['last_used']),
      contextInputTokens: latest.read<int>('context_tokens'),
    );
    return UsageSessionDetail(
      session: summary,
      tokens: tokens,
      mainTokens: main.read<int>('total_tokens'),
      mainRequestCount: main.read<int>('request_count'),
      subagents: [
        for (final row in childRows)
          UsageSubagentSummary(
            sessionId: row.read<String>('session_id'),
            name: row.read<String>('title'),
            agentSlug: row.read<String?>('agent_slug'),
            provider: row.read<String?>('provider'),
            model: row.read<String?>('model'),
            totalTokens: row.read<int>('total_tokens'),
            requestCount: row.read<int>('request_count'),
            runs: runsBySession[row.read<String>('session_id')] ?? const [],
          ),
      ],
      records: records,
    );
  }

  String _whereClause(UsageFilter filter, {String? tableAlias}) {
    final prefix = tableAlias == null ? '' : '$tableAlias.';
    final clauses = <String>[];
    if (filter.startDate != null) {
      clauses.add('${prefix}created_at >= ?');
    }
    if (filter.endDate != null) {
      clauses.add('${prefix}created_at <= ?');
    }
    if (filter.providerId != null) {
      clauses.add('${prefix}provider_id = ?');
    }
    if (filter.model != null) {
      clauses.add('${prefix}model = ?');
    }
    if (filter.source != null) {
      clauses.add('${prefix}source = ?');
    }
    if (clauses.isEmpty) {
      return '';
    }
    return 'WHERE ${clauses.join(' AND ')}';
  }

  List<Variable<Object>> _whereVariables(UsageFilter filter) {
    return [
      if (filter.startDate != null) Variable(_epochSeconds(filter.startDate!)),
      if (filter.endDate != null) Variable(_epochSeconds(filter.endDate!)),
      if (filter.providerId != null) Variable(filter.providerId!),
      if (filter.model != null) Variable(filter.model!),
      if (filter.source != null) Variable(filter.source!),
    ];
  }

  String _displayTokensSql([String? tableAlias]) {
    final prefix = tableAlias == null ? '' : '$tableAlias.';
    return '${prefix}input_tokens + ${prefix}output_tokens';
  }

  DateTime _readSqlDateTime(Object? value) {
    if (value is DateTime) {
      return value;
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }
    return DateTime.tryParse(value?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  int _epochSeconds(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;
}
