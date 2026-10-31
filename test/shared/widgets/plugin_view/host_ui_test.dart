// 职责: 验证插件临时 UI 使用宿主确认控件，关闭页面清理弹层并阻止迟到调用。
// 关联文件:
//   lib/shared/widgets/plugin_view/host_ui.dart
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import 'package:reveric/shared/widgets/plugin_view/host_ui.dart';
import 'input_test.dart' show wrap;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());
  testWidgets(
    'temporary confirmation, same-plugin navigation and close cleanup',
    (tester) async {
      PluginPageUi? ui;
      final targets = <String>[];
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              ui ??= PluginPageUi(context, (id) async {
                targets.add(id);
              });
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final answer = ui!.call('ui.dialog', {
        'title': 'Plugin confirmation',
        'message': 'Continue?',
      });
      await tester.pumpAndSettle();
      expect(find.text('Plugin confirmation'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(await answer, true);
      await ui!.call('ui.navigate', {'viewId': 'report'});
      expect(targets, ['report']);
      final pending = ui!.call('ui.dialog', {'title': 'Closing page'});
      await tester.pumpAndSettle();
      ui!.close();
      await tester.pumpAndSettle();
      expect(find.text('Closing page'), findsNothing);
      expect(await pending, false);
      await expectLater(
        ui!.call('ui.toast', {'message': 'Late'}),
        throwsA(isA<PluginHostError>()),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
