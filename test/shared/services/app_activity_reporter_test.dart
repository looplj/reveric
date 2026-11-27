// 职责: 验证应用启动和供应商链接点击的匿名活动载荷。
// 关联文件:
//   lib/shared/services/app_activity_reporter.dart
//   lib/shared/services/anonymous_outbox_service.dart

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/app_config.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/anonymous_outbox_service.dart';
import 'package:reveric/shared/services/app_activity_reporter.dart';
import 'package:reveric/shared/services/device_id_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'reportAppLaunch queues an activity event without model usage',
    () async {
      SharedPreferences.setMockInitialValues({});
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final outbox = AnonymousOutboxService(
        database: database,
        httpClient: _UnusedClient(),
        getBaseUrl: () => 'https://anonymous.example',
        getEnabled: () => true,
        autoFlush: false,
      );
      addTearDown(() async {
        outbox.dispose();
        await database.close();
      });

      final occurredAt = DateTime.utc(2026, 11, 24, 10);
      await reportAppLaunch(
        deviceIdService: DeviceIdService(),
        outbox: outbox,
        now: () => occurredAt,
      );

      final row = await database
          .select(database.anonymousOutboxEvents)
          .getSingle();
      expect(row.channel, 'activity');
      expect(row.endpoint, 'activity');
      final payload = jsonDecode(row.payloadJson) as Map<String, dynamic>;
      expect(payload['event_type'], appLaunchEventType);
      expect(payload, isNot(contains('provider_type')));
      expect(payload['device_id'], row.deviceId);
      expect(payload['occurred_at'], occurredAt.toIso8601String());
      expect(payload.containsKey('model'), isFalse);
      expect(payload.containsKey('input_tokens'), isFalse);
      expect(payload.containsKey('session_id'), isFalse);
    },
  );

  test(
    'each provider link click sends a distinct event without a device ID',
    () async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('', 204);
      });
      final outbox = AnonymousOutboxService(
        database: database,
        httpClient: client,
        getBaseUrl: () => 'https://anonymous.example',
        getEnabled: () => true,
        autoFlush: false,
      );
      addTearDown(() async {
        outbox.dispose();
        client.close();
        await database.close();
      });

      final occurredAt = DateTime.utc(2026, 11, 24, 10);
      for (final type in ['api88', 'token91', 'token91']) {
        await reportProviderLinkClick(
          outbox: outbox,
          providerType: type,
          occurredAt: occurredAt,
        );
      }
      await outbox.flush();

      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/analysis/activity/events');
      final events = (jsonDecode(request.body) as Map)['events'] as List;
      expect(events, hasLength(3));
      expect(events.map((event) => event['event_id']).toSet(), hasLength(3));
      for (final (index, type) in ['api88', 'token91', 'token91'].indexed) {
        expect(events[index], {
          'event_type': 'provider_link_click',
          'provider_type': type,
          'event_id': isNotEmpty,
          'device_id': 'anonymous-provider-link-click',
          'app_version': appVersion,
          'platform': isNotEmpty,
          'occurred_at': occurredAt.toIso8601String(),
        });
      }
    },
  );
}

class _UnusedClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw UnsupportedError('unused');
  }
}
