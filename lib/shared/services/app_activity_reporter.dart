// 职责: 把应用启动和供应商链接点击写入匿名活动队列。
// 关联文件:
//   lib/shared/services/anonymous_outbox_service.dart
//   lib/shared/services/device_id_service.dart
//   lib/shared/widgets/settings/provider_overview.dart
//   lib/main.dart
//   lib/shared/app_config.dart

import 'dart:io';

import '../app_config.dart';
import 'anonymous_outbox_service.dart';
import 'device_id_service.dart';

const appLaunchEventType = 'app_launch';

/// 记录一次进程启动。同一条队列记录重试时沿用已有 event id。
Future<void> reportAppLaunch({
  required DeviceIdService deviceIdService,
  required AnonymousOutboxService outbox,
  DateTime Function()? now,
}) async {
  if (!outbox.canEnqueue) {
    return;
  }
  final occurredAt = (now ?? DateTime.now)().toUtc();
  final deviceId = await deviceIdService.getOrCreate();
  await _enqueueActivity(
    outbox: outbox,
    eventType: appLaunchEventType,
    deviceId: deviceId,
    occurredAt: occurredAt,
  );
}

Future<void> reportProviderLinkClick({
  required AnonymousOutboxService outbox,
  required String providerType,
  required DateTime occurredAt,
}) => _enqueueActivity(
  outbox: outbox,
  eventType: 'provider_link_click',
  providerType: providerType,
  // 协议要求 device_id，供应商点击统一用固定值，避免关联真实设备。
  deviceId: 'anonymous-provider-link-click',
  occurredAt: occurredAt.toUtc(),
);

Future<void> _enqueueActivity({
  required AnonymousOutboxService outbox,
  required String eventType,
  required String deviceId,
  required DateTime occurredAt,
  String? providerType,
}) => outbox.enqueue(
  AnonymousOutboxEventInput(
    channel: AnonymousOutboxChannel.activity,
    endpoint: AnonymousOutboxEndpoint.activity,
    deviceId: deviceId,
    occurredAt: occurredAt,
    payload: {
      'device_id': deviceId,
      'event_type': eventType,
      'provider_type': ?providerType,
      'app_version': appVersion,
      'platform': _activityPlatform(),
      'occurred_at': occurredAt.toIso8601String(),
    },
  ),
);

String _activityPlatform() {
  if (Platform.isMacOS) {
    return 'macos';
  }
  if (Platform.isWindows) {
    return 'windows';
  }
  if (Platform.isLinux) {
    return 'linux';
  }
  if (Platform.isAndroid) {
    return 'android';
  }
  if (Platform.isIOS) {
    return 'ios';
  }
  return 'unknown';
}
