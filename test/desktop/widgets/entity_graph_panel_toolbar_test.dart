// 职责: 验证桌面关系图工具栏在窄画布下把右侧操作收进「⋯」菜单而不溢出。
// 关联文件:
//   lib/desktop/widgets/entity_graph_panel.dart
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/widgets/entity_graph_panel.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../shared/widgets/relation/harness.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('toolbar collapses actions into a menu when narrow', (
    tester,
  ) async {
    rootBundle.clear();
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(2000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final more = find.byTooltip('More actions');

    Future<void> pumpAt(double width) async {
      await tester.pumpWidget(
        relationHarness(
          db,
          EntityGraphPanel(
            novelId: 'work',
            databasePath: 'test',
            selectedEntityKey: null,
            onSelectedEntityKeyChanged: (_) {},
          ),
          width: width,
          height: 700,
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // 测试字体每个字符按字号等宽绘制，文案比真实字体宽得多。
    await pumpAt(1800);
    expect(tester.takeException(), isNull);
    expect(find.text('Show Labels'), findsOneWidget);
    expect(more, findsNothing);

    // 右侧详情栏固定 321；画布只够放左侧三个选择框时，操作组应收起。
    await pumpAt(860);
    expect(tester.takeException(), isNull);
    expect(find.text('Show Labels'), findsNothing);
    expect(more, findsOneWidget);

    await tester.tap(more);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Show Labels'), findsOneWidget);
    expect(find.text('Reset'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });
}
