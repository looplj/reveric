// 职责: 验证插件控件的跨平台菜单、浮层生命周期、只读列表窗口及节点移动保活。
// 关联文件:
//   lib/shared/widgets/plugin_view/tree_view.dart
//   lib/shared/widgets/plugin_view/overlay.dart
//   lib/shared/components/reveric_popover.dart
//   lib/shared/models/plugin/ui_tree.dart
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fjs/fjs.dart' as fjs;
import 'package:reveric/shared/components/reveric_popover.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/models/plugin/ui_tree.dart';
import 'package:reveric/shared/widgets/plugin_view/tree_view.dart';
import '../../models/plugin/ui_tree_test.dart'
    show batch, create, set, insert, id;
import 'input_test.dart' show wrap;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets('menu selects and closes owned popup ${platform.name}', (
      tester,
    ) async {
      final tree = PluginUiTree(surface: 'test', generation: 1),
          events = <Map<String, Object?>>[];
      tree.apply(
        batch(1, [
          create(2, 'Menu'),
          set(2, {
            'items': [
              {'id': 'pick', 'label': 'Choose'},
            ],
          }),
          fjs.UiOp.listen(id: id(2), event: 'onSelect', handler: id(1)),
          insert(1, 2),
          create(3, 'Button'),
          set(3, {'label': 'Actions'}),
          insert(2, 3, slot: 'trigger'),
        ]),
      );
      await tester.pumpWidget(
        wrap(
          PluginUiTreeView(
            tree: tree,
            onEvent: (node, event, payload) => events.add(payload),
          ),
          platform: platform,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      expect(find.text('Choose'), findsOneWidget);
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(events.single['id'], 'pick');
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      tree.apply(
        batch(2, [
          fjs.UiOp.remove(parent: id(2), child: id(3), slot: 'trigger'),
          fjs.UiOp.release(id: id(3)),
          fjs.UiOp.remove(parent: id(1), child: id(2), slot: 'children'),
          fjs.UiOp.release(id: id(2)),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Choose'), findsNothing);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      tree.dispose();
    });
  }
  testWidgets('popover retains default toggling and supports external state', (
    tester,
  ) async {
    final open = ValueNotifier<bool?>(null);
    await tester.pumpWidget(
      wrap(
        ValueListenableBuilder<bool?>(
          valueListenable: open,
          builder: (context, value, _) => RevericPopover(
            open: value,
            trigger: (context, isOpen, toggle) =>
                RevericButton.secondary(label: 'Toggle', onPressed: toggle),
            panel: (context, close) => const Text('Panel'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Toggle'));
    await tester.pumpAndSettle();
    expect(find.text('Panel'), findsOneWidget);
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(find.text('Panel'), findsNothing);
    open.value = true;
    await tester.pumpAndSettle();
    expect(find.text('Panel'), findsOneWidget);
    open.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Panel'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    open.dispose();
  });
  testWidgets('readonly list asks for visible window rather than all rows', (
    tester,
  ) async {
    final tree = PluginUiTree(surface: 'test', generation: 1),
        events = <Map<String, Object?>>[];
    tree.apply(
      batch(1, [
        create(2, 'List'),
        set(2, {'height': 100, 'itemExtent': 20, 'itemCount': 1000}),
        fjs.UiOp.listen(id: id(2), event: 'viewport', handler: id(1)),
        insert(1, 2),
      ]),
    );
    await tester.pumpWidget(
      wrap(
        PluginUiTreeView(
          tree: tree,
          onEvent: (node, event, payload) => events.add(payload),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(events.single, {'first': 0, 'count': 10});
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.jumpTo(40);
    await tester.pumpAndSettle();
    expect(events, hasLength(1));
    position.jumpTo(1000);
    await tester.pumpAndSettle();
    expect(events.last, {'first': 45, 'count': 15});
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    tree.dispose();
  });
  testWidgets('cross-parent move preserves focused editing state', (
    tester,
  ) async {
    final tree = PluginUiTree(surface: 'test', generation: 1);
    tree.apply(
      batch(1, [
        create(2, 'Column'),
        insert(1, 2),
        create(3, 'Box'),
        insert(2, 3),
        create(4, 'Box'),
        insert(2, 4),
        create(5, 'TextField'),
        set(5, {'value': ''}),
        insert(3, 5, slot: 'child'),
      ]),
    );
    await tester.pumpWidget(
      wrap(PluginUiTreeView(tree: tree, onEvent: (_, _, _) {})),
    );
    await tester.pumpAndSettle();
    final input = find.byType(TextField);
    await tester.enterText(input, 'draft');
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(EditableText)),
        controller = tester.widget<TextField>(input).controller!,
        focus = tester.widget<TextField>(input).focusNode!;
    tree.apply(batch(2, [insert(4, 5, slot: 'child')]));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(EditableText)), same(state));
    expect(controller.text, 'draft');
    expect(focus.hasFocus, true);
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    tree.dispose();
  });
}
