// 职责: 验证应用启动进入活动队列，且载荷不含模型用量。
// 关联文件:
//   lib/shared/services/app_activity_reporter.dart
//   lib/shared/services/anonymous_outbox_service.dart

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/anonymous_outbox_service.dart';
import 'package:reveric/shared/services/app_activity_reporter.dart';
import 'package:reveric/shared/services/device_id_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('reportAppLaunch queues an activity event without model usage', () async {
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

    final row = await database.select(database.anonymousOutboxEvents).getSingle();
    expect(row.channel, 'activity');
    expect(row.endpoint, 'activity');
    final payload = jsonDecode(row.payloadJson) as Map<String, dynamic>;
    expect(payload['event_type'], appLaunchEventType);
    expect(payload['device_id'], row.deviceId);
    expect(payload['occurred_at'], occurredAt.toIso8601String());
    expect(payload.containsKey('model'), isFalse);
    expect(payload.containsKey('input_tokens'), isFalse);
    expect(payload.containsKey('session_id'), isFalse);
  });
}

class _UnusedClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw UnsupportedError('unused');
  }
}
