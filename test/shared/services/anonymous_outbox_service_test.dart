// 职责: 验证匿名 Outbox 按约定投递、退避并限制重试。
// 关联文件:
//   lib/shared/services/anonymous_outbox_service.dart
//   lib/shared/database/daos/anonymous_outbox_dao.dart
//   lib/shared/database/app_database.dart

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/anonymous_outbox_service.dart';

void main() {
  late AppDatabase database;
  late _RecordingClient httpClient;
  late AnonymousOutboxService outbox;
  late DateTime now;

  AnonymousOutboxService makeOutbox() => AnonymousOutboxService(
    database: database,
    httpClient: httpClient,
    getBaseUrl: () => 'https://anonymous.example/',
    getEnabled: () => true,
    autoFlush: false,
    now: () => now,
  );

  setUp(() {
    database = AppDatabase.forTest(NativeDatabase.memory());
    httpClient = _RecordingClient();
    now = DateTime.now().toUtc().add(const Duration(minutes: 1));
    outbox = makeOutbox();
  });

  tearDown(() async {
    outbox.dispose();
    httpClient.close();
    await database.close();
  });

  test(
    'disabled reporting neither queues new events nor sends pending events',
    () async {
      var enabled = true;
      outbox.dispose();
      outbox = AnonymousOutboxService(
        database: database,
        httpClient: httpClient,
        getBaseUrl: () => 'https://anonymous.example',
        getEnabled: () => enabled,
        autoFlush: false,
      );
      Future<void> enqueue(String id) => outbox.enqueue(
        AnonymousOutboxEventInput(
          eventId: id,
          channel: AnonymousOutboxChannel.trace,
          endpoint: AnonymousOutboxEndpoint.trace,
          deviceId: 'device',
          occurredAt: DateTime.now().toUtc(),
          payload: {'event_id': id},
        ),
      );

      await enqueue('pending');
      enabled = false;
      await enqueue('disabled');
      await outbox.flush();
      expect(httpClient.requests, isEmpty);
      final pending = await database
          .select(database.anonymousOutboxEvents)
          .get();
      expect(pending, hasLength(1));
      expect(pending.single.eventId, 'pending');

      enabled = true;
      await outbox.flush();
      expect(httpClient.requests, hasLength(1));
      expect(
        await database.select(database.anonymousOutboxEvents).get(),
        isEmpty,
      );
    },
  );

  test(
    'transactional events are sent only after commit, never on rollback',
    () async {
      outbox.dispose();
      outbox = AnonymousOutboxService(
        database: database,
        httpClient: httpClient,
        getBaseUrl: () => 'https://anonymous.example',
        getEnabled: () => true,
      );
      Future<void> enqueue(String id) => outbox.enqueue(
        AnonymousOutboxEventInput(
          eventId: id,
          channel: AnonymousOutboxChannel.trace,
          endpoint: AnonymousOutboxEndpoint.trace,
          deviceId: 'device',
          occurredAt: DateTime.now().toUtc(),
          payload: {'event_id': id},
        ),
      );
      await expectLater(
        database.transaction(() async {
          await enqueue('rolled-back');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(httpClient.requests, isEmpty);
          throw StateError('business write failed');
        }),
        throwsStateError,
      );
      await outbox.flush();
      expect(httpClient.requests, isEmpty);
      await database.transaction(() async {
        await enqueue('committed');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(httpClient.requests, isEmpty);
      });
      // flush coalesces concurrent requests; the queued follow-up can begin
      // after the Future returned by the previous flush has completed.
      await _waitFor(() => httpClient.requests.length == 1);
      await outbox.flush();
      expect(httpClient.requests, hasLength(1));
      expect(httpClient.requests.single.body, contains('committed'));
    },
  );

  test(
    'duplicate event keeps its first payload, timestamp and retry backoff',
    () async {
      final firstTime = DateTime.utc(2026, 9, 20);
      Future<void> enqueue(DateTime at) => outbox.enqueue(
        AnonymousOutboxEventInput(
          eventId: 'stable-event',
          channel: AnonymousOutboxChannel.trace,
          endpoint: AnonymousOutboxEndpoint.trace,
          deviceId: 'device',
          occurredAt: at,
          payload: {'occurred_at': at.toIso8601String()},
        ),
      );
      await enqueue(firstTime);
      final retryAt = DateTime.now().toUtc().add(const Duration(hours: 1));
      final original = await database
          .select(database.anonymousOutboxEvents)
          .getSingle();
      await database.anonymousOutboxDao.scheduleRetry(
        ids: [original.id],
        nextRetryAt: retryAt,
      );
      await Future.wait([
        enqueue(firstTime.add(const Duration(days: 1))),
        enqueue(firstTime),
      ]);
      final row = await database
          .select(database.anonymousOutboxEvents)
          .getSingle();
      expect(row.eventId, original.eventId);
      expect(row.payloadJson, original.payloadJson);
      expect(row.occurredAt, original.occurredAt);
      expect(row.attemptCount, 1);
      expect(
        row.nextRetryAt.millisecondsSinceEpoch ~/ 1000,
        retryAt.millisecondsSinceEpoch ~/ 1000,
      );
    },
  );

  test('trace retry preserves JSON and event ID until acknowledged', () async {
    httpClient.statusCode = 500;
    await outbox.enqueue(
      AnonymousOutboxEventInput(
        eventId: 'b7f9cceb-9158-4ec4-a0bc-6c0ea210c0d8',
        channel: AnonymousOutboxChannel.trace,
        endpoint: AnonymousOutboxEndpoint.trace,
        deviceId: 'derived-device-id',
        occurredAt: DateTime.utc(2026, 7, 15, 12),
        payload: {
          'event_id': 'b7f9cceb-9158-4ec4-a0bc-6c0ea210c0d8',
          'event_type': 'turn_end',
        },
      ),
    );
    await outbox.flush();

    final failed = await database
        .select(database.anonymousOutboxEvents)
        .getSingle();
    expect(failed.attemptCount, 1);
    expect(httpClient.requests, hasLength(1));

    final firstRequest = httpClient.requests.single;
    final rawBody = firstRequest.body;
    expect(firstRequest.url.path, '/v1/analysis/traces/events');
    expect(jsonDecode(rawBody), {
      'events': [
        {
          'event_id': 'b7f9cceb-9158-4ec4-a0bc-6c0ea210c0d8',
          'event_type': 'turn_end',
        },
      ],
    });

    httpClient.statusCode = 204;
    now = now.add(const Duration(seconds: 30));
    await outbox.flush();

    final remaining = await database
        .select(database.anonymousOutboxEvents)
        .get();
    expect(remaining, isEmpty);
    expect(httpClient.requests, hasLength(2));
    expect(httpClient.requests.last.body, rawBody);
  });

  test('dispose after 204 still deletes the acknowledged batch', () async {
    httpClient.statusCode = 204;
    final responseGate = Completer<void>();
    httpClient.responseGate = responseGate.future;
    await outbox.enqueue(
      AnonymousOutboxEventInput(
        channel: AnonymousOutboxChannel.trace,
        endpoint: AnonymousOutboxEndpoint.trace,
        deviceId: 'dispose-race-device',
        occurredAt: DateTime.utc(2026, 7, 15, 12),
        payload: {'event_type': 'turn_end'},
      ),
    );

    final flushFuture = outbox.flush();
    await _waitFor(() => httpClient.requests.length == 1);
    outbox.dispose();
    responseGate.complete();
    await flushFuture;

    final remaining = await database
        .select(database.anonymousOutboxEvents)
        .get();
    expect(remaining, isEmpty);
  });

  test('trace capacity evicts its oldest event without affecting activity events', () async {
    for (var index = 0; index < 4097; index += 1) {
      await outbox.enqueue(
        AnonymousOutboxEventInput(
          eventId:
              '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
          channel: AnonymousOutboxChannel.trace,
          endpoint: AnonymousOutboxEndpoint.trace,
          deviceId: 'device-$index',
          occurredAt: DateTime.utc(2026, 7, 15),
          payload: {'event_id': 'event-$index'},
        ),
      );
    }
    await outbox.enqueue(
      AnonymousOutboxEventInput(
        channel: AnonymousOutboxChannel.activity,
        endpoint: AnonymousOutboxEndpoint.activity,
        deviceId: 'activity-device',
        occurredAt: DateTime.utc(2026, 7, 15),
        payload: {'event_type': 'app_launch'},
      ),
    );

    final traceCount = await database
        .customSelect(
          "SELECT COUNT(*) AS event_count FROM anonymous_outbox_events WHERE channel = 'trace'",
        )
        .getSingle();
    final activityCount = await database
        .customSelect(
          "SELECT COUNT(*) AS event_count FROM anonymous_outbox_events WHERE channel = 'activity'",
        )
        .getSingle();

    expect(traceCount.read<int>('event_count'), 4096);
    expect(activityCount.read<int>('event_count'), 1);
  });

  test('shares backoff across endpoints and stops after two retries', () async {
    httpClient.statusCode = 500;
    await outbox.enqueue(
      AnonymousOutboxEventInput(
        channel: AnonymousOutboxChannel.trace,
        endpoint: AnonymousOutboxEndpoint.trace,
        deviceId: 'retry-device',
        occurredAt: now,
        payload: {'event_type': 'turn_end'},
      ),
    );

    await outbox.flush();
    expect(httpClient.requests, hasLength(1));

    await outbox.enqueue(
      AnonymousOutboxEventInput(
        channel: AnonymousOutboxChannel.toolError,
        endpoint: AnonymousOutboxEndpoint.toolError,
        deviceId: 'retry-device',
        occurredAt: now,
        payload: {'tool_name': 'Read'},
      ),
    );
    now = now.add(const Duration(seconds: 29));
    await outbox.flush();
    expect(httpClient.requests, hasLength(1));

    now = now.add(const Duration(seconds: 1));
    await outbox.flush();
    expect(httpClient.requests, hasLength(2));

    // The remaining trace retry survives an app restart.
    outbox.dispose();
    outbox = makeOutbox();
    now = now.add(const Duration(minutes: 2));
    await outbox.flush();
    expect(httpClient.requests, hasLength(3));
    expect(
      httpClient.requests.map((request) => request.body).toSet(),
      hasLength(1),
    );
    final queued = await database.select(database.anonymousOutboxEvents).get();
    expect(queued.single.channel, 'toolError');

    httpClient.statusCode = 204;
    now = now.add(const Duration(minutes: 2));
    await outbox.flush();
    expect(httpClient.requests, hasLength(4));
    expect(httpClient.requests.last.url.path, '/v1/analysis/tool-call-errors');
    final remaining = await database
        .select(database.anonymousOutboxEvents)
        .get();
    expect(remaining, isEmpty);
  });

  test('app launch is posted on the activity endpoint, including a legacy usage row', () async {
    httpClient.statusCode = 204;
    await database.anonymousOutboxDao.enqueue(
      eventId: 'legacy-usage',
      channel: 'usage',
      priority: AnonymousOutboxChannel.activity.priority,
      endpoint: 'usage',
      deviceId: 'test-device',
      payloadJson:
          '{"device_id":"test-device","event_type":"app_launch","occurred_at":"2026-11-24T00:00:00.000Z"}',
      occurredAt: now,
    );
    await outbox.flush();

    final request = httpClient.requests.single;
    expect(request.url.path, '/v1/analysis/activity/events');
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    final event = payload['events'].single as Map<String, dynamic>;
    expect(event['event_type'], 'app_launch');
    expect(event.containsKey('input_tokens'), isFalse);
    expect(event.containsKey('model'), isFalse);
    expect(
      await database.select(database.anonymousOutboxEvents).get(),
      isEmpty,
    );
  });

  test('permanent rejections are never retried', () async {
    httpClient.statusCode = 400;
    await outbox.enqueue(
      AnonymousOutboxEventInput(
        channel: AnonymousOutboxChannel.requestError,
        endpoint: AnonymousOutboxEndpoint.requestError,
        deviceId: 'test-device',
        occurredAt: now,
        payload: {'error_type': 'stream_error'},
      ),
    );
    await outbox.flush();
    now = now.add(const Duration(hours: 1));
    await outbox.flush();

    final request = httpClient.requests.single;
    expect(request.url.path, '/v1/analysis/request-errors');
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    expect(payload['events'].single['event_id'], isNotEmpty);
    expect(
      await database.select(database.anonymousOutboxEvents).get(),
      isEmpty,
    );
  });

  test('an event on its last attempt keeps a new event queued', () async {
    Future<void> enqueue(String eventId) => outbox.enqueue(
      AnonymousOutboxEventInput(
        channel: AnonymousOutboxChannel.trace,
        endpoint: AnonymousOutboxEndpoint.trace,
        deviceId: 'test-device',
        occurredAt: now,
        payload: {'event_type': 'turn_end'},
        eventId: eventId,
      ),
    );
    await enqueue('last-attempt');
    final row = await database
        .select(database.anonymousOutboxEvents)
        .getSingle();
    for (var retry = 0; retry < 2; retry++) {
      await database.anonymousOutboxDao.scheduleRetry(
        ids: [row.id],
        nextRetryAt: now.subtract(const Duration(seconds: 1)),
      );
    }
    await enqueue('first-attempt');
    httpClient.statusCode = 500;
    await outbox.flush();

    expect(httpClient.requests.single.body, contains('last-attempt'));
    final queued = await database
        .select(database.anonymousOutboxEvents)
        .getSingle();
    expect(queued.eventId, 'first-attempt');
    expect(queued.attemptCount, 0);
  });

  test(
    'dispose prevents late enqueue and flush from touching the database',
    () async {
      outbox.dispose();

      await expectLater(
        outbox.enqueue(
          AnonymousOutboxEventInput(
            channel: AnonymousOutboxChannel.trace,
            endpoint: AnonymousOutboxEndpoint.trace,
            deviceId: 'disposed-device',
            occurredAt: DateTime.utc(2026, 7, 15),
            payload: {'event_type': 'turn_end'},
          ),
        ),
        completes,
      );
      await expectLater(outbox.flush(), completes);

      final remaining = await database
          .select(database.anonymousOutboxEvents)
          .get();
      expect(remaining, isEmpty);
    },
  );
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not met before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _RecordedRequest {
  const _RecordedRequest({
    required this.url,
    required this.headers,
    required this.body,
  });

  final Uri url;
  final Map<String, String> headers;
  final String body;
}

class _RecordingClient extends http.BaseClient {
  int statusCode = 204;
  Future<void>? responseGate;
  final requests = <_RecordedRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    requests.add(
      _RecordedRequest(url: request.url, headers: request.headers, body: body),
    );
    final gate = responseGate;
    if (gate != null) {
      await gate;
    }
    return http.StreamedResponse(Stream.value(utf8.encode('')), statusCode);
  }
}
