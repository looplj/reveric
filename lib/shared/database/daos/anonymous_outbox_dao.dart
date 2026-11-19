// 职责: 持久化、按优先级读取并维护匿名事件 Outbox。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/services/anonymous_outbox_service.dart
// 遵循的 Rules:
//   .agents/rules/db-query-aggregation.md
//   .agents/rules/error-handling.md

import 'package:drift/drift.dart';

import '../../logger/app_logger.dart';
import '../app_database.dart';

part 'anonymous_outbox_dao.drift.dart';

final _log = AppLogger.forModule('AnonymousOutboxDao');

@DriftAccessor(tables: [AnonymousOutboxEvents])
class AnonymousOutboxDao extends DatabaseAccessor<AppDatabase>
    with _$AnonymousOutboxDaoMixin {
  AnonymousOutboxDao(super.db);

  Future<void> enqueue({
    required String? eventId,
    required String channel,
    required int priority,
    required String endpoint,
    required String deviceId,
    required String payloadJson,
    required DateTime occurredAt,
  }) async {
    try {
      await into(anonymousOutboxEvents).insert(
        AnonymousOutboxEventsCompanion.insert(
          eventId: Value(eventId),
          channel: channel,
          priority: priority,
          endpoint: endpoint,
          deviceId: deviceId,
          payloadJson: payloadJson,
          occurredAt: occurredAt.toUtc(),
          createdAt: Value(DateTime.now().toUtc()),
          nextRetryAt: Value(DateTime.now().toUtc()),
        ),
        // 同一曝光/点击可能由会话恢复再次入队；保留首次事件和重试状态。
        onConflict: DoNothing(target: [anonymousOutboxEvents.eventId]),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] INSERT anonymous_outbox_events failed eventId=$eventId',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<List<AnonymousOutboxEvent>> nextReadyBatch({
    required DateTime now,
    required int limit,
  }) async {
    final first =
        await (select(anonymousOutboxEvents)
              ..where((table) => table.nextRetryAt.isSmallerOrEqualValue(now))
              ..orderBy([
                (table) => OrderingTerm.asc(table.priority),
                (table) => OrderingTerm.asc(table.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (first == null) {
      return const [];
    }

    return (select(anonymousOutboxEvents)
          ..where(
            (table) =>
                table.endpoint.equals(first.endpoint) &
                table.deviceId.equals(first.deviceId) &
                table.attemptCount.equals(first.attemptCount) &
                table.nextRetryAt.isSmallerOrEqualValue(now),
          )
          ..orderBy([(table) => OrderingTerm.asc(table.id)])
          ..limit(limit))
        .get();
  }

  Future<DateTime?> nextScheduledAt() async {
    final next =
        await (select(anonymousOutboxEvents)
              ..orderBy([(table) => OrderingTerm.asc(table.nextRetryAt)])
              ..limit(1))
            .getSingleOrNull();
    return next?.nextRetryAt;
  }

  Future<void> deleteBatch(List<int> ids) async {
    if (ids.isEmpty) {
      return;
    }
    try {
      await (delete(
        anonymousOutboxEvents,
      )..where((table) => table.id.isIn(ids))).go();
    } catch (error, stackTrace) {
      _log.error(
        '[DB] DELETE anonymous_outbox_events failed ids=$ids',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> scheduleRetry({
    required List<int> ids,
    required DateTime nextRetryAt,
  }) async {
    if (ids.isEmpty) {
      return;
    }
    try {
      final table = anonymousOutboxEvents;
      await (update(table)..where((row) => row.id.isIn(ids))).write(
        AnonymousOutboxEventsCompanion.custom(
          nextRetryAt: Variable(nextRetryAt.toUtc()),
          attemptCount: table.attemptCount + const Variable(1),
        ),
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] UPDATE anonymous_outbox_events retry failed ids=$ids',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> evictExcess({
    required String channel,
    required int maxEvents,
  }) async {
    final countRow = await customSelect(
      'SELECT COUNT(*) AS event_count FROM anonymous_outbox_events '
      'WHERE channel = ?',
      variables: [Variable<String>(channel)],
    ).getSingle();
    final count = countRow.read<int>('event_count');
    final excess = count - maxEvents;
    if (excess <= 0) {
      return;
    }

    try {
      await customStatement(
        'DELETE FROM anonymous_outbox_events '
        'WHERE id IN ('
        'SELECT id FROM anonymous_outbox_events '
        'WHERE channel = ? ORDER BY id ASC LIMIT ?'
        ')',
        [channel, excess],
      );
      _log.warning(
        '[DB] evicted anonymous_outbox_events channel=$channel count=$excess',
      );
    } catch (error, stackTrace) {
      _log.error(
        '[DB] DELETE anonymous_outbox_events overflow failed channel=$channel',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }
}
