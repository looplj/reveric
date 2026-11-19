// 职责: 验证启动失败 reporter 绕过 Outbox 并按匿名错误监控契约直连后端。
// 关联文件:
//   lib/shared/logger/startup_failure_reporter.dart
//   lib/shared/services/device_id_service.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:reveric/shared/logger/startup_failure_reporter.dart';
import 'package:reveric/shared/services/anonymous_reporting_consent_service.dart';
import 'package:reveric/shared/services/crash_reporting/crash_sentinel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'sends startup failures to the anonymous error endpoint by default',
    () async {
      SharedPreferences.setMockInitialValues({});
      final client = _RecordingClient();
      final reporter = StartupFailureReporter(
        httpClient: client,
        getDeviceId: () async => 'device-123',
      );

      final outcome = await reporter.reportWithOutcome(
        phase: 'application_startup',
        error: StateError('startup failed'),
        stackTrace: StackTrace.current,
      );

      expect(outcome, StartupFailureReportOutcome.reported);
      expect(
        client.requests.single.url,
        'https://anonymous-api.reveric.app/v1/analysis/request-errors',
      );
    },
  );

  test('early lifecycle failures send redacted reasons', () async {
    final client = _RecordingClient();
    final reporter = StartupFailureReporter(
      httpClient: client,
      getDeviceId: () async => 'test',
      getBaseUrl: () => 'https://anonymous.example',
      getEnabled: () async => true,
    );
    await reporter.reportLifecycleFailure(
      phase: 'single_instance_activation',
      reason: 'port_unreachable',
      error: const FileSystemException(
        'private-secret',
        '/Users/private/install',
        OSError('denied', 5),
      ),
      stackTrace: StackTrace.fromString(
        '#0 activate (package:reveric/shared/services/single_instance_service.dart:1:2)',
      ),
    );
    final event =
        (jsonDecode(client.requests.single.body)['events'] as List).single
            as Map;
    expect(event['error_code'], 'single_instance_activation');
    expect(event['exception_message'], contains('reason=port_unreachable'));
    expect(event['exception_message'], contains('os_code=5'));
    expect(
      event['exception_message'],
      contains('single_instance_service.dart:1:2'),
    );
    expect(event['exception_message'], isNot(contains('private')));
  });
  test(
    'exit classification and capture failures survive the 500 character limit',
    () async {
      final client = _RecordingClient();
      final reporter = StartupFailureReporter(
        httpClient: client,
        getDeviceId: () async => 'test',
        getBaseUrl: () => 'https://anonymous.example/',
        getEnabled: () async => true,
      );
      await reporter.report(
        phase: 'previous_session_crashed',
        error: PreviousSessionCrash(
          origin: PreviousSessionCrashOrigin.pendingReplay,
          markerContent: jsonEncode({
            'pid': 1234,
            'native_crash': true,
            'exit_source': 'tray',
            'native_exit_phase': 'crash_handler',
            'exception_code': '0xC0000005',
            'dump_status': 'failed',
            'dump_error': 5,
            'summary_error': 13,
            'native_handler_configured': true,
            'started_at': '2026-09-20T12:00:00.123456Z',
            'app_version': '2.0.0',
            'session_token': 'private-correlation-token',
            'extra_future_field': 'x' * 1000,
          }),
        ),
        stackTrace: StackTrace.fromString(
          '#0 report (package:reveric/crash_sentinel.dart:1:1)',
        ),
      );
      final event =
          (jsonDecode(client.requests.single.body)['events'] as List).single
              as Map;
      final message = event['exception_message'] as String;
      expect(message.length, lessThanOrEqualTo(500));
      for (final value in [
        'classification=confirmed_crash',
        '0xC0000005',
        '"dump_error":5',
        '"summary_error":13',
      ]) {
        expect(message, contains(value));
      }
      expect(message, isNot(contains('private-correlation-token')));
    },
  );

  test('keeps project frames behind framework frames without full paths', () async {
    final client = _RecordingClient();
    final reporter = StartupFailureReporter(
      httpClient: client,
      getDeviceId: () async => 'test',
      getBaseUrl: () => 'https://anonymous.example/',
      getEnabled: () async => true,
    );
    await reporter.report(
      phase: 'flutter_framework',
      error: StateError('x' * 800),
      stackTrace: StackTrace.fromString(
        [
          for (var i = 0; i < 8; i++)
            '#$i frame (package:flutter/src/widgets/selectable_region.dart:${100 + i}:1)',
          '#8 frame (package:reveric/shared/widgets/selection_owner.dart:123:4)',
          '#9 frame (package:reveric/mobile/pages/example_page.dart:456:7)',
        ].join('\n'),
      ),
    );
    final event =
        (jsonDecode(client.requests.single.body)['events'] as List).single
            as Map;
    final message = event['exception_message'] as String;
    expect(message, contains('selectable_region.dart:100:1'));
    expect(message, contains('selection_owner.dart:123:4'));
    expect(message, contains('example_page.dart:456:7'));
    expect(message, isNot(contains('package:reveric/')));
    expect(message.length, lessThanOrEqualTo(500));
  });
  test(
    'reports a migration failure directly with startup diagnostics',
    () async {
      final client = _RecordingClient();
      final reporter = StartupFailureReporter(
        httpClient: client,
        getDeviceId: () async => 'device-123',
        getBaseUrl: () => 'https://anonymous.example/diagnostics/events/',
        getEnabled: () async => true,
        now: () => DateTime.utc(2026, 7, 24, 12),
      );

      final outcome = await reporter.reportWithOutcome(
        phase: 'app_database_migration_v23_to_v24',
        error: StateError('missing column'),
        stackTrace: StackTrace.fromString(
          '#0 migrate (file:///Users/example/app_database.dart:100:12)\n',
        ),
      );

      expect(outcome, StartupFailureReportOutcome.reported);
      expect(client.requests, hasLength(1));
      final request = client.requests.single;
      expect(request.url, 'https://anonymous.example/diagnostics/events');

      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final event =
          (body['events'] as List<Object?>).single as Map<String, dynamic>;
      expect(event['device_id'], 'device-123');
      expect(event['session_mode'], 'startup');
      expect(event['model'], 'app');
      expect(event['error_code'], 'app_database_migration_v23_to_v24');
      expect(event['exception_type'], 'StateError');
      expect(
        event['exception_message'],
        contains('phase=app_database_migration'),
      );
      expect(event['exception_message'], contains('app_database.dart:100:12'));
    },
  );

  test('keeps the stack when the error text is very long', () async {
    // Riverpod 的 UnmountedRefException 自带数百字符说明；stack 拼在末尾，
    // 整体截断会先把它切掉，线上因此一帧都拿不到、无法定位调用点。
    final client = _RecordingClient();
    final reporter = StartupFailureReporter(
      httpClient: client,
      getDeviceId: () async => 'device-123',
      getBaseUrl: () => 'https://anonymous.example/',
      getEnabled: () async => true,
      now: () => DateTime.utc(2026, 8, 16, 12),
    );

    final outcome = await reporter.reportWithOutcome(
      phase: 'uncaught_async',
      error: StateError('x' * 800),
      stackTrace: StackTrace.fromString(
        '#0 resolve (file:///Users/example/ai_providers.dart:364:12)\n'
        '#1 spawn (file:///Users/example/spawn_agent_handler.dart:566:20)\n',
      ),
    );

    expect(outcome, StartupFailureReportOutcome.reported);
    final body =
        jsonDecode(client.requests.single.body) as Map<String, dynamic>;
    final event =
        (body['events'] as List<Object?>).single as Map<String, dynamic>;
    final message = event['exception_message'] as String;

    expect(message, contains('ai_providers.dart:364:12'));
    expect(message, contains('spawn_agent_handler.dart:566:20'));
    expect(message.length, lessThanOrEqualTo(520));
  });

  test('does not send when anonymous reporting is disabled', () async {
    SharedPreferences.setMockInitialValues({});
    await const AnonymousReportingConsentService().setGranted(false);
    final client = _RecordingClient();
    final reporter = StartupFailureReporter(
      httpClient: client,
      getDeviceId: () async => 'device-123',
    );

    final outcome = await reporter.reportWithOutcome(
      phase: 'application_startup',
      error: StateError('failed'),
      stackTrace: StackTrace.current,
    );

    expect(outcome, StartupFailureReportOutcome.skipped);
    expect(client.requests, isEmpty);
  });

  test(
    'returns retryable failure when the backend rejects the report',
    () async {
      final reporter = StartupFailureReporter(
        httpClient: _RecordingClient(statusCode: 503),
        getDeviceId: () async => 'device-123',
        getBaseUrl: () => 'https://anonymous.example',
        getEnabled: () async => true,
      );

      final outcome = await reporter.reportWithOutcome(
        phase: 'native_crash',
        error: StateError('failed'),
        stackTrace: StackTrace.current,
      );

      expect(outcome, StartupFailureReportOutcome.retryableFailure);
    },
  );

  test('returns retryable failure when the base URL is unavailable', () async {
    final reporter = StartupFailureReporter(
      httpClient: _RecordingClient(),
      getDeviceId: () async => 'device-123',
      getBaseUrl: () => '',
      getEnabled: () async => true,
    );

    final outcome = await reporter.reportWithOutcome(
      phase: 'native_crash',
      error: StateError('failed'),
      stackTrace: StackTrace.current,
    );

    expect(outcome, StartupFailureReportOutcome.retryableFailure);
  });
}

class _RecordedRequest {
  const _RecordedRequest({
    required this.url,
    required this.headers,
    required this.body,
  });

  final String url;
  final Map<String, String> headers;
  final String body;
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient({this.statusCode = 204});

  final int statusCode;
  final requests = <_RecordedRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    requests.add(
      _RecordedRequest(
        url: request.url.toString(),
        headers: request.headers,
        body: body,
      ),
    );
    return http.StreamedResponse(const Stream.empty(), statusCode);
  }
}
