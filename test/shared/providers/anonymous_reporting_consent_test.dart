// 职责: 验证匿名诊断默认开启，用户选择在重启后仍生效。
// 关联文件:
//   lib/shared/providers/anonymous_reporting_providers.dart
//   lib/shared/services/anonymous_reporting_consent_service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/providers/anonymous_reporting_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to enabled when no choice is saved', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      await container.read(anonymousReportingConsentProvider.future),
      isTrue,
    );
  });

  test('persists consent changes across restarts', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(anonymousReportingConsentProvider.future);

    await container.read(anonymousReportingConsentProvider.notifier).set(false);
    expect(container.read(anonymousReportingConsentProvider).value, isFalse);

    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    expect(
      await restarted.read(anonymousReportingConsentProvider.future),
      isFalse,
    );

    await restarted.read(anonymousReportingConsentProvider.notifier).set(true);
    final restartedAgain = ProviderContainer();
    addTearDown(restartedAgain.dispose);
    expect(
      await restartedAgain.read(anonymousReportingConsentProvider.future),
      isTrue,
    );
  });
}
