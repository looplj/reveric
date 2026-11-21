// 职责: 验证 Codex 登录态失败提示、重新检测及窄屏布局。
// 关联文件:
//   lib/shared/widgets/settings/codex_connection.dart
//   lib/shared/services/ai/codex/credentials.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/services/ai/codex/credentials.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/codex_connection.dart';

final _codexProvider = AiProvider(
  asrModels: const [],
  audioModels: const [],
  videoModels: const [],
  id: 'codex',
  name: 'Codex',
  builtin: false,
  type: 'codex',
  enabled: true,
  apiKey: '',
  baseUrl: '',
  models: const [],
  imageModels: const [],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  testWidgets('missing login can be rechecked after signing in at 375px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var attempts = 0;
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/translations',
        assetLoader: const MergingAssetLoader(),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(
                body: SingleChildScrollView(
                  child: CodexConnection(
                    config: _codexProvider,
                    loadCredentials: ({client}) async {
                      attempts++;
                      if (attempts == 1) {
                        throw const CodexAuthException(
                          CodexAuthFailure.missing,
                        );
                      }
                      return const CodexCredentials(
                        accessToken: 'secret',
                        accountId: 'account',
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('auth.json was not found'), findsOneWidget);
    expect(find.text('secret'), findsNothing);
    await tester.tap(find.text('Check login'));
    await tester.pumpAndSettle();
    expect(find.text('Local Codex credentials are available'), findsOneWidget);
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });
}
