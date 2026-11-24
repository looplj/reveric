// 职责: 把应用启动写入匿名活动队列，不携带模型用量。
// 关联文件:
//   lib/shared/services/anonymous_outbox_service.dart
//   lib/shared/services/device_id_service.dart
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
  await outbox.enqueue(
    AnonymousOutboxEventInput(
      channel: AnonymousOutboxChannel.activity,
      endpoint: AnonymousOutboxEndpoint.activity,
      deviceId: deviceId,
      occurredAt: occurredAt,
      payload: {
        'device_id': deviceId,
        'event_type': appLaunchEventType,
        'app_version': appVersion,
        'platform': _activityPlatform(),
        'occurred_at': occurredAt.toIso8601String(),
      },
    ),
  );
}

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
