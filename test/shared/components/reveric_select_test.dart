// 职责: 验证下拉菜单按标题和副标题过滤选项，无匹配时给出空结果。
// 关联文件:
//   lib/shared/components/reveric_select.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/components/reveric_select.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(rootBundle.clear);

  testWidgets(
    'search keeps items whose label or subtitle matches',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          RevericSelect<String>(
            value: 'sunburst',
            searchable: true,
            items: const [
              RevericSelectItem(
                value: 'sunburst',
                label: 'openai/gpt-image-2.5-sunburst',
                subtitle: 'Atlas Cloud',
              ),
              RevericSelectItem(
                value: 'flare',
                label: 'openai/gpt-image-2.5-flare',
                subtitle: 'Atlas Cloud',
              ),
              RevericSelectItem(
                value: 'seedream',
                label: 'bytedance/seedream-v5.0-pro',
                subtitle: 'Atlas Cloud',
              ),
              RevericSelectItem(
                value: 'banana',
                label: 'google/nano-banana-2',
                subtitle: 'OpenRouter',
              ),
            ],
            onChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(RevericSelect<String>));
      await tester.pumpAndSettle();

      expect(find.text('openai/gpt-image-2.5-flare'), findsOneWidget);
      expect(find.text('bytedance/seedream-v5.0-pro'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'flare');
      await _settleSearch(tester);

      // 触发器始终显示当前选中项，过滤只作用于菜单。
      expect(find.text('openai/gpt-image-2.5-sunburst'), findsOneWidget);
      expect(find.text('openai/gpt-image-2.5-flare'), findsOneWidget);
      expect(find.text('bytedance/seedream-v5.0-pro'), findsNothing);

      await tester.enterText(find.byType(TextField), 'OpenRouter');
      await _settleSearch(tester);

      expect(find.text('google/nano-banana-2'), findsOneWidget);
      expect(find.text('openai/gpt-image-2.5-flare'), findsNothing);
      expect(find.text('bytedance/seedream-v5.0-pro'), findsNothing);

      await tester.enterText(find.byType(TextField), 'missing');
      await _settleSearch(tester);

      expect(find.text('No matches'), findsOneWidget);
      expect(find.text('google/nano-banana-2'), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

/// 输入先在下一帧进入 hook 并开始 debounce，落定后再过一帧才写回菜单。
Future<void> _settleSearch(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

Widget _wrap(Widget child) {
  return EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) {
        return MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(),
          home: RevericTheme(
            data: RevericThemeData.reveric,
            child: Scaffold(
              body: Center(child: SizedBox(width: 240, child: child)),
            ),
          ),
        );
      },
    ),
  );
}
