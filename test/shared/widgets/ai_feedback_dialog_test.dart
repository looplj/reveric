// 职责: 验证三平台诊断弹窗仅含取消和上传，失败保留输入，成功关闭并提示。
// 关联文件:
//   lib/shared/widgets/ai/chat/feedback_dialog.dart
//   lib/shared/providers/upload_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'dart:convert';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/upload_providers.dart';
import 'package:reveric/shared/services/anonymous_file_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/chat/feedback_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets('feedback has only cancel/upload on $platform', (tester) async {
      tester.view.physicalSize = Size(
        platform == TargetPlatform.android ? 390 : 1000,
        900,
      );
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic>? sent;
      var attempts = 0;
      final service = AnonymousFileService(
        baseUrl: 'https://diagnostics.example',
        createClient: () => MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          attempts++;
          if (attempts == 1) {
            return http.Response('{"error":"rate_limited"}', 429);
          }
          return http.Response('{"upload_id":"test"}', 201);
        }),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            anonymousUploadServiceProvider.overrideWithValue(service),
          ],
          child: EasyLocalization(
            supportedLocales: const [Locale('zh', 'CN')],
            path: 'assets/translations',
            assetLoader: const MergingAssetLoader(),
            startLocale: const Locale('zh', 'CN'),
            child: Builder(
              builder: (context) => MaterialApp(
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: RevericThemeData.reveric.toThemeData().copyWith(
                  platform: platform,
                ),
                home: RevericTheme(
                  data: RevericThemeData.reveric,
                  child: Scaffold(
                    body: Consumer(
                      builder: (context, ref, _) => TextButton(
                        onPressed: () => showAiChatFeedbackDialog(
                          context: context,
                          ref: ref,
                          sessionState: AiChatSessionState(
                            title: 'test session',
                          ),
                          novelId: null,
                          databasePath: null,
                        ),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('上报诊断信息'), findsOneWidget);
      expect(find.byType(RevericButton), findsNWidgets(2));
      expect(find.text('诊断文件'), findsNothing);
      expect(find.text('在 GitHub 提交'), findsNothing);
      expect(find.text('导出诊断文件'), findsNothing);
      expect(find.text('通过邮件发送'), findsNothing);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('上传'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '回复中断');
      await tester.tap(find.text('上传'));
      await tester.pumpAndSettle();
      expect(sent?['description'], '回复中断');
      expect(sent?['title'], 'test session');
      expect(tester.takeException(), isNull);
      expect(find.text('上报诊断信息'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '回复中断',
      );
      expect(find.text('上传失败，请重试。'), findsOneWidget);
      await tester.tap(find.text('上传'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('上报诊断信息'), findsNothing);
      expect(find.text('诊断信息已上传，感谢反馈！'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
