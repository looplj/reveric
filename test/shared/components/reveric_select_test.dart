// 职责: 验证下拉菜单的定位、选择及搜索过滤。
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

  for (final (edge, alignment, dropUp) in [
    ('bottom', Alignment.bottomCenter, false),
    ('top', Alignment.topCenter, true),
  ]) {
    testWidgets('opens toward available space at the $edge of the window', (
      tester,
    ) async {
      String? selected;
      await tester.pumpWidget(
        _wrap(
          RevericSelect<String>(
            value: 'allow',
            dropUp: dropUp,
            items: const [
              RevericSelectItem(value: 'allow', label: 'Allow'),
              RevericSelectItem(value: 'ask', label: 'Ask each time'),
              RevericSelectItem(value: 'deny', label: 'Deny'),
            ],
            onChanged: (value) => selected = value,
          ),
          alignment: alignment,
        ),
      );
      await tester.pumpAndSettle();

      final trigger = find.byType(RevericSelect<String>);
      await tester.tap(trigger);
      await tester.pumpAndSettle();

      final deny = find.text('Deny').hitTestable();
      expect(find.text('Ask each time').hitTestable(), findsOneWidget);
      expect(deny, findsOneWidget);
      final triggerRect = tester.getRect(trigger);
      final optionRect = tester.getRect(deny);
      expect(
        dropUp
            ? optionRect.top - triggerRect.bottom
            : triggerRect.top - optionRect.bottom,
        greaterThan(0),
      );
      await tester.tap(deny);
      expect(selected, 'deny');
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

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

Widget _wrap(Widget child, {Alignment alignment = Alignment.center}) {
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
              body: Align(
                alignment: alignment,
                child: SizedBox(width: 240, child: child),
              ),
            ),
          ),
        );
      },
    ),
  );
}
