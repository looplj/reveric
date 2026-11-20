// 职责: 持久化并串行投递匿名 Agent 诊断事件。
// 关联文件:
//   lib/shared/database/daos/anonymous_outbox_dao.dart
//   lib/shared/services/ai/trace_reporter_service.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../logger/app_logger.dart';

final _log = AppLogger.forModule('AnonymousOutbox');

enum AnonymousOutboxChannel {
  usage(priority: 1, maxEvents: 1024),
  trace(priority: 2, maxEvents: 4096),
  toolError(priority: 3, maxEvents: 2048),
  requestError(priority: 4, maxEvents: 2048);

  const AnonymousOutboxChannel({
    required this.priority,
    required this.maxEvents,
  });

  final int priority;
  final int maxEvents;
}

enum AnonymousOutboxEndpoint {
  // 旧队列可能含用量事件，Reveric 只发送诊断事件。
  usage(null),
  trace('/v1/analysis/traces/events'),
  toolError('/v1/analysis/tool-call-errors'),
  requestError('/v1/analysis/request-errors');

  const AnonymousOutboxEndpoint(this.path);

  final String? path;
}

enum _DeliveryResult { accepted, rejected, retry }

class AnonymousOutboxEventInput {
  const AnonymousOutboxEventInput({
    required this.channel,
    required this.endpoint,
    required this.deviceId,
    required this.payload,
    required this.occurredAt,
    this.eventId,
  });

  final AnonymousOutboxChannel channel;
  final AnonymousOutboxEndpoint endpoint;
  final String deviceId;
  final Map<String, dynamic> payload;
  final DateTime occurredAt;
  final String? eventId;
}

/// 将 endpoint 专属事件持久化后按固定协议批量上报。
class AnonymousOutboxService {
  AnonymousOutboxService({
    required this._database,
    required this._httpClient,
    required this._getBaseUrl,
    required this._getEnabled,
    this._autoFlush = true,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _dispatchZone = Zone.current;

  static const _batchSize = 100;
  static const _requestTimeout = Duration(seconds: 8);
  static const _retryDelays = [Duration(seconds: 30), Duration(minutes: 2)];

  final AppDatabase _database;
  final http.Client _httpClient;
  final String? Function() _getBaseUrl;
  final bool Function() _getEnabled;
  final bool _autoFlush;
  final DateTime Function() _now;
  // 服务在事务外创建；后台投递不得继承 enqueue 调用方的 Drift 事务，
  // 否则可能在业务提交前发出事件，或在事务结束后继续使用已关闭事务。
  final Zone _dispatchZone;

  Future<void>? _activeFlush;
  Timer? _retryTimer;
  DateTime? _retryNotBefore;
  bool _flushRequested = false;
  bool _disposed = false;

  bool get canEnqueue => !_disposed && _getEnabled();

  /// 写入成功后触发后台 flush；调用方不必等待网络完成。
  Future<void> enqueue(AnonymousOutboxEventInput input) async {
    if (_disposed) {
      if (_log.isDebugEnabled) {
        _log.debug(
          'enqueue skipped: disposed=true channel=${input.channel.name}',
        );
      }
      return;
    }
    if (!_getEnabled()) {
      if (_log.isDebugEnabled) {
        _log.debug(
          'enqueue skipped: reporting disabled channel=${input.channel.name}',
        );
      }
      return;
    }

    final eventId = input.eventId ?? const Uuid().v4();
    try {
      await _database.anonymousOutboxDao.enqueue(
        eventId: eventId,
        channel: input.channel.name,
        priority: input.channel.priority,
        endpoint: input.endpoint.name,
        deviceId: input.deviceId,
        payloadJson: jsonEncode(input.payload),
        occurredAt: input.occurredAt,
      );
      if (_disposed) {
        return;
      }
      await _database.anonymousOutboxDao.evictExcess(
        channel: input.channel.name,
        maxEvents: input.channel.maxEvents,
      );
    } catch (error, stackTrace) {
      _log.warning(
        '[DB] table=anonymous_outbox_events operation=ENQUEUE '
        'eventId=$eventId error=$error\n$stackTrace',
      );
      return;
    }
    if (_autoFlush && !_disposed) {
      _dispatchZone.run(() => unawaited(flush()));
    }
  }

  /// 串行投递所有当前可重试的分组批次。
  Future<void> flush() {
    if (_disposed) {
      return Future<void>.value();
    }
    _retryTimer?.cancel();
    _retryTimer = null;

    final active = _activeFlush;
    if (active != null) {
      _flushRequested = true;
      return active;
    }

    final future = _flushLoop().catchError((error, stackTrace) {
      _log.warning('flush loop stopped unexpectedly error=$error\n$stackTrace');
    });
    _activeFlush = future;
    return future.whenComplete(() {
      _activeFlush = null;
      if (_flushRequested) {
        _flushRequested = false;
        unawaited(flush());
      }
    });
  }

  Future<void> _flushLoop() async {
    if (!_getEnabled()) {
      _log.debug('flush skipped: reporting disabled');
      return;
    }

    final baseUrl = _getBaseUrl()?.trim();
    if (baseUrl == null || baseUrl.isEmpty) {
      _log.warning('flush skipped: anonymous reporting base URL is empty');
      return;
    }

    while (!_disposed && _getEnabled()) {
      final now = _now().toUtc();
      final retryNotBefore = _retryNotBefore;
      if (retryNotBefore != null && now.isBefore(retryNotBefore)) {
        _scheduleFlushAt(retryNotBefore);
        return;
      }

      late final List<AnonymousOutboxEvent> batch;
      try {
        batch = await _database.anonymousOutboxDao.nextReadyBatch(
          now: now,
          limit: _batchSize,
        );
      } catch (error, stackTrace) {
        _log.warning(
          '[DB] table=anonymous_outbox_events operation=SELECT_READY '
          'error=$error\n$stackTrace',
        );
        return;
      }
      if (_disposed || !_getEnabled()) {
        return;
      }
      if (batch.isEmpty) {
        await _scheduleNextFlush();
        return;
      }

      final ids = batch.map((event) => event.id).toList(growable: false);
      final attemptCount = batch.first.attemptCount;
      final result = attemptCount > _retryDelays.length
          ? _DeliveryResult.rejected
          : await _sendBatch(baseUrl, batch);
      if (result == _DeliveryResult.retry) {
        if (_disposed) {
          return;
        }
        // 同一个接收服务的退避也约束新入队事件和恢复前台触发的 flush。
        final delay =
            _retryDelays[attemptCount.clamp(0, _retryDelays.length - 1)];
        final retryAt = _now().toUtc().add(delay);
        _retryNotBefore = retryAt;
        if (attemptCount < _retryDelays.length) {
          try {
            await _database.anonymousOutboxDao.scheduleRetry(
              ids: ids,
              nextRetryAt: retryAt,
            );
          } catch (error, stackTrace) {
            _log.warning(
              '[DB] table=anonymous_outbox_events operation=SCHEDULE_RETRY '
              'ids=$ids error=$error\n$stackTrace',
            );
            return;
          }
          _scheduleFlushAt(retryAt);
          return;
        }
        _log.warning(
          'retry limit reached endpoint=${batch.first.endpoint} count=${batch.length}',
        );
      }
      try {
        await _database.anonymousOutboxDao.deleteBatch(ids);
      } catch (error, stackTrace) {
        _log.warning(
          '[DB] table=anonymous_outbox_events operation=DELETE_BATCH '
          'ids=$ids error=$error\n$stackTrace',
        );
        return;
      }
      if (result == _DeliveryResult.retry) {
        await _scheduleNextFlush();
        return;
      }
    }
  }

  Future<void> _scheduleNextFlush() async {
    if (_disposed) {
      return;
    }
    _retryTimer?.cancel();
    late final DateTime? nextRetryAt;
    try {
      nextRetryAt = await _database.anonymousOutboxDao.nextScheduledAt();
    } catch (error, stackTrace) {
      _log.warning(
        '[DB] table=anonymous_outbox_events operation=SELECT_NEXT_RETRY '
        'error=$error\n$stackTrace',
      );
      _retryTimer = null;
      return;
    }
    if (nextRetryAt != null) {
      final retryNotBefore = _retryNotBefore;
      _scheduleFlushAt(
        retryNotBefore != null && retryNotBefore.isAfter(nextRetryAt)
            ? retryNotBefore
            : nextRetryAt,
      );
    }
  }

  void _scheduleFlushAt(DateTime nextRetryAt) {
    if (_disposed || !_getEnabled()) {
      return;
    }
    _retryTimer?.cancel();
    final delay = nextRetryAt.difference(_now().toUtc());
    _retryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      if (_disposed) {
        return;
      }
      _retryTimer = null;
      unawaited(flush());
    });
  }

  Future<_DeliveryResult> _sendBatch(
    String baseUrl,
    List<AnonymousOutboxEvent> batch,
  ) async {
    final first = batch.first;
    final endpoint = AnonymousOutboxEndpoint.values.byName(first.endpoint);
    final path = endpoint.path;
    if (path == null) {
      return _DeliveryResult.rejected;
    }
    final events = [
      for (final event in batch)
        {
          ...jsonDecode(event.payloadJson) as Map<String, dynamic>,
          // 旧队列的 event_id 可能为空，同一行重传时也需要稳定键。
          'event_id':
              event.eventId ??
              'outbox-${event.id}-${event.createdAt.millisecondsSinceEpoch}',
        },
    ];
    final url = '${baseUrl.replaceFirst(RegExp(r'/$'), '')}$path';
    final abort = Completer<void>();
    try {
      final request =
          http.AbortableRequest(
              'POST',
              Uri.parse(url),
              abortTrigger: abort.future,
            )
            ..followRedirects = false
            ..headers['Content-Type'] = 'application/json'
            ..bodyBytes = utf8.encode(jsonEncode({'events': events}));
      final response = await _httpClient
          .send(request)
          .then(http.Response.fromStream)
          .timeout(
            _requestTimeout,
            onTimeout: () {
              abort.complete();
              throw TimeoutException(
                'Anonymous report timed out',
                _requestTimeout,
              );
            },
          );
      if (response.statusCode == 204) {
        if (_log.isDebugEnabled) {
          _log.debug(
            'flush accepted endpoint=${endpoint.name} count=${batch.length}',
          );
        }
        return _DeliveryResult.accepted;
      }
      _log.warning(
        'flush rejected url=$url count=${batch.length} '
        'status=${response.statusCode} body=${response.body}',
      );
      return switch (response.statusCode) {
        408 || 429 || (>= 500 && < 600) => _DeliveryResult.retry,
        _ => _DeliveryResult.rejected,
      };
    } catch (error, stackTrace) {
      _log.warning(
        'flush failed url=$url count=${batch.length} '
        'error=$error\n$stackTrace',
      );
    }
    return _DeliveryResult.retry;
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
  }
}
