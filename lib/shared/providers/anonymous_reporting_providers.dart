// 职责: 装配匿名 Outbox 与用户上报同意状态的全局 Provider。
// 关联文件:
//   lib/shared/services/anonymous_outbox_service.dart
//   lib/shared/services/anonymous_reporting_consent_service.dart
//   lib/shared/providers/device_id_providers.dart
//   lib/shared/widgets/settings/general_settings_section.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/state-management.md

import 'dart:async';
import 'dart:io';

import 'package:http/io_client.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../app_config.dart';
import '../services/anonymous_outbox_service.dart';
import '../services/anonymous_reporting_consent_service.dart';
import 'novel_providers.dart';

part 'anonymous_reporting_providers.g.dart';

@Riverpod(keepAlive: true)
AnonymousReportingConsentService anonymousReportingConsentService(Ref ref) =>
    const AnonymousReportingConsentService();

/// 匿名诊断上报设置。首次使用默认开启。
@Riverpod(keepAlive: true)
class AnonymousReportingConsent extends _$AnonymousReportingConsent {
  @override
  Future<bool> build() =>
      ref.watch(anonymousReportingConsentServiceProvider).isGranted();

  Future<void> set(bool granted) async {
    await ref
        .read(anonymousReportingConsentServiceProvider)
        .setGranted(granted);
    if (ref.mounted) {
      state = AsyncValue.data(granted);
    }
  }
}

@Riverpod(keepAlive: true)
AnonymousOutboxService anonymousOutboxService(Ref ref) {
  final httpClient = IOClient(
    HttpClient()..connectionTimeout = const Duration(seconds: 5),
  );
  final service = AnonymousOutboxService(
    database: ref.watch(appDatabaseProvider),
    httpClient: httpClient,
    getBaseUrl: () => anonymousReportingBaseUrl,
    // 先加载本机设置，避免在读取到已关闭的设置前发送。
    getEnabled: () =>
        anonymousReportingBaseUrl.isNotEmpty &&
        ref.read(anonymousReportingConsentProvider).value == true,
  );
  ref.listen(anonymousReportingConsentProvider, (previous, next) {
    if (previous?.value != true && next.value == true) {
      unawaited(service.flush());
    }
  });
  ref.onDispose(() {
    service.dispose();
    httpClient.close();
  });
  return service;
}
