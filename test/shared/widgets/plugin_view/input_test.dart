// 职责: 验证插件输入的 IME、父级重建、防抖与离屏字段生命周期。
// 关联文件:
//   lib/shared/widgets/plugin_view/input.dart
//   lib/shared/widgets/plugin_view/tree_view.dart
//   lib/shared/models/plugin/ui_tree.dart
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fjs/fjs.dart' as fjs;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/plugin/ui_tree.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:reveric/shared/widgets/plugin_view/tree_view.dart';
import '../../models/plugin/ui_tree_test.dart'
    show batch, create, set, insert, id;

Widget wrap(Widget child, {TargetPlatform platform = TargetPlatform.macOS}) =>
    EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: Builder(
        builder: (context) => ProviderScope(
          overrides: [appBackgroundActiveProvider.overrideWithValue(false)],
          child: MaterialApp(
            locale: context.locale,
            supportedLocales: context.supportedLocales,
            localizationsDelegates: context.localizationDelegates,
            theme: RevericThemeData.reveric.toThemeData().copyWith(
              platform: platform,
            ),
            builder: (context, route) =>
                RevericTheme(data: RevericThemeData.reveric, child: route!),
            home: Scaffold(
              body: SizedBox(width: 500, height: 600, child: child),
            ),
          ),
        ),
      ),
    );
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
    for (final component in ['TextField', 'SearchField']) {
      for (final continued in [false, true]) {
        testWidgets(
          'deferred IME echo $component continued=$continued ${platform.name}',
          (tester) async {
            final tree = PluginUiTree(surface: 'test', generation: 1);
            final events = <Map<String, Object?>>[];
            tree.apply(
              batch(1, [
                create(2, component),
                set(2, {'value': ''}),
                fjs.UiOp.listen(id: id(2), event: 'onChange', handler: id(1)),
                insert(1, 2),
              ]),
            );
            await tester.pumpWidget(
              wrap(
                PluginUiTreeView(
                  tree: tree,
                  onEvent: (_, event, payload) {
                    expectSync(event, 'onChange');
                    events.add(payload);
                  },
                ),
                platform: platform,
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byType(TextField));
            await tester.pumpAndSettle();
            final field = tester.widget<TextField>(find.byType(TextField));
            void edit(String text, {required bool composing}) {
              tester.testTextInput.updateEditingValue(
                TextEditingValue(
                  text: text,
                  selection: TextSelection.collapsed(offset: text.length),
                  composing: composing
                      ? TextRange(start: 0, end: text.length)
                      : TextRange.empty,
                ),
              );
            }

            edit('a', composing: true);
            await tester.pump();
            tree.apply(
              batch(2, [
                set(2, {'value': 'A'}, revision: 1),
              ]),
            );
            await tester.pump();
            expect(field.controller!.text, 'a');
            if (continued) {
              edit('ab', composing: true);
              await tester.pump();
            }
            expect(events, isEmpty);
            // Commit only the composing range; the text does not change.
            edit(continued ? 'ab' : 'a', composing: false);
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pumpAndSettle();
            expect(field.controller!.text, continued ? 'ab' : 'A');
            expect(
              events,
              continued
                  ? [
                      {'value': 'ab', 'editRevision': 2},
                    ]
                  : isEmpty,
            );
            expect(field.focusNode!.hasFocus, isTrue);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
            tree.dispose();
          },
        );
      }
    }
    testWidgets(
      'IME and parent rebuild retain controller and focus ${platform.name}',
      (tester) async {
        final tree = PluginUiTree(surface: 'test', generation: 1);
        final parent = ValueNotifier(0), events = <Map<String, Object?>>[];
        tree.apply(
          batch(1, [
            create(2, 'TextField'),
            set(2, {'value': '', 'label': 'Title'}),
            fjs.UiOp.listen(id: id(2), event: 'onChange', handler: id(1)),
            insert(1, 2),
          ]),
        );
        await tester.pumpWidget(
          wrap(
            ValueListenableBuilder<int>(
              valueListenable: parent,
              builder: (context, _, child) => PluginUiTreeView(
                tree: tree,
                onEvent: (node, event, payload) {
                  events.add(payload);
                  parent.value++;
                },
              ),
            ),
            platform: platform,
          ),
        );
        await tester.pumpAndSettle();
        final input = find.byType(TextField);
        await tester.tap(input);
        await tester.pumpAndSettle();
        final controller = tester.widget<TextField>(input).controller!,
            focus = tester.widget<TextField>(input).focusNode!;
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'ni',
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2),
          ),
        );
        await tester.pump();
        expect(events, isEmpty);
        expect(focus.hasFocus, true);
        tree.apply(
          batch(2, [
            set(2, {'value': 'stale'}, revision: 0),
          ]),
        );
        await tester.pump();
        expect(controller.text, 'ni');
        expect(controller.value.composing, const TextRange(start: 0, end: 2));
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '你',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
        await tester.pumpAndSettle();
        expect(events.single['value'], '你');
        expect(parent.value, 1);
        expect(tester.widget<TextField>(input).controller, same(controller));
        expect(tester.widget<TextField>(input).focusNode, same(focus));
        expect(focus.hasFocus, true);
        tree.apply(
          batch(3, [
            set(2, {'value': '你'}, revision: 2),
          ]),
        );
        await tester.pumpAndSettle();
        expect(controller.selection, const TextSelection.collapsed(offset: 1));
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        tree.dispose();
        parent.dispose();
      },
    );
  }
  testWidgets('search debounces callbacks and clears immediately', (
    tester,
  ) async {
    final tree = PluginUiTree(surface: 'test', generation: 1),
        events = <String>[];
    tree.apply(
      batch(1, [
        create(2, 'SearchField'),
        set(2, {'value': '', 'debounceMs': 300}),
        insert(1, 2),
      ]),
    );
    await tester.pumpWidget(
      wrap(
        PluginUiTreeView(
          tree: tree,
          onEvent: (node, event, payload) =>
              events.add(payload['value'] as String),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'one');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), 'two');
    await tester.pump(const Duration(milliseconds: 299));
    expect(events, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(events, ['two']);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(events, ['two', '']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    tree.dispose();
  });
  testWidgets('submit sends a pending debounced change before submitting', (
    tester,
  ) async {
    final tree = PluginUiTree(surface: 'test', generation: 1),
        events = <String>[];
    tree.apply(
      batch(1, [
        create(2, 'SearchField'),
        set(2, {'value': '', 'debounceMs': 300}),
        fjs.UiOp.listen(id: id(2), event: 'onChange', handler: id(1)),
        fjs.UiOp.listen(id: id(2), event: 'onSubmit', handler: id(2)),
        insert(1, 2),
      ]),
    );
    await tester.pumpWidget(
      wrap(
        PluginUiTreeView(
          tree: tree,
          onEvent: (node, event, payload) => events.add(
            '$event:${payload['value']}:${payload['editRevision']}',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 400));
    expect(events, ['onChange:draft:1', 'onSubmit:draft:1']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    tree.dispose();
  });
  testWidgets('host values replace edits in a field without onChange', (
    tester,
  ) async {
    final tree = PluginUiTree(surface: 'test', generation: 1);
    tree.apply(
      batch(1, [
        create(2, 'TextField'),
        set(2, {'value': 'initial'}),
        insert(1, 2),
      ]),
    );
    await tester.pumpWidget(
      wrap(PluginUiTreeView(tree: tree, onEvent: (_, _, _) {})),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.pump();
    expect(tree.editRevision(2), 0);
    tree.apply(
      batch(2, [
        set(2, {'value': ''}),
      ]),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    tree.dispose();
  });
  testWidgets('scrolling an editing column keeps every field mounted', (
    tester,
  ) async {
    final tree = PluginUiTree(surface: 'test', generation: 1);
    tree.apply(
      batch(1, [
        create(2, 'Scroll'),
        insert(1, 2),
        create(3, 'Column'),
        insert(2, 3, slot: 'child'),
        for (var i = 4; i < 29; i++) ...[
          create(i, 'TextField'),
          set(i, {'value': '', 'label': 'Field $i'}),
          insert(3, i),
        ],
      ]),
    );
    await tester.pumpWidget(
      wrap(PluginUiTreeView(tree: tree, onEvent: (_, _, _) {})),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(25));
    await tester.enterText(find.byType(TextField).first, 'draft');
    final controller = tester
        .widget<TextField>(find.byType(TextField).first)
        .controller!;
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -1200),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(25));
    expect(controller.text, 'draft');
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    tree.dispose();
  });
}
