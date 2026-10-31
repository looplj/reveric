// 职责: 用真实本地 fjs 库验证 TSX 编译产物到 Dart 节点树及 Flutter 输入的完整桥接。
// 关联文件:
//   lib/shared/services/plugins/ui_session.dart
//   lib/shared/widgets/plugin_view/surface.dart
//   assets/plugin_preview/counter.js
import 'dart:async';
import 'dart:io';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/models/plugin/ui_tree.dart';
import 'package:reveric/shared/services/plugins/ui_session.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import 'package:reveric/shared/widgets/plugin_view/surface.dart';
import 'input_test.dart' show wrap;

Future<void> until(PluginUiSession session, bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (session.error.value != null) {
      throw StateError(session.error.value!);
    }
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Native UI condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<PluginUiSession> start() async {
  final session = PluginUiSession(
    tree: PluginUiTree(
      surface: 'native-${DateTime.now().microsecondsSinceEpoch}',
      generation: 1,
    ),
    hostCall: (method, args) async {
      if (method == 'storage.get' && args['key'] == 'preview.delay') {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return null;
      }
      throw PluginHostError('unavailable', method);
    },
  );
  await session.start(
    source: File('assets/plugin_preview/counter.js').readAsStringSync(),
    scope: {
      'plugin': {'id': 'test.preview', 'version': '1.0.0'},
      'request': {
        'requestId': 'test',
        'sessionId': 'test',
        'workId': null,
        'agentId': 'test',
        'mode': 'preview',
      },
    },
    environment: {
      'width': 500,
      'height': 600,
      'platform': 'macos',
      'theme': 'light',
      'locale': 'en',
      'visible': true,
    },
  );
  await until(session, () => session.ready.value);
  return session;
}

bool text(PluginUiSession session, String value) => session.tree.nodes.values
    .any((node) => node.component == 'Text' && node.props['text'] == value);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final path = Platform.environment['FJS_PROBE_LIBRARY'];
    if (path == null) {
      throw StateError(
        'Set FJS_PROBE_LIBRARY to the locally built fjs library',
      );
    }
    await LibFjs.init(externalLibrary: ExternalLibrary.open(path));
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());
  test(
    'native stream commits typed batches, async results and dirty state',
    () async {
      final session = await start();
      try {
        expect(text(session, 'Count 0'), true);
        expect(session.tree.nodes.length, lessThan(100));
        final button = session.tree.nodes.values.singleWhere(
          (node) => node.component == 'Button',
        );
        session.dispatch(button, 'onPress', {});
        await until(
          session,
          () => text(session, 'Count 1') && text(session, 'Loaded 1'),
        );
        final input = session.tree.nodes.values.singleWhere(
          (node) => node.component == 'TextField',
        );
        final revision = session.tree.recordEdit(input.id);
        session.dispatch(input, 'onChange', {
          'value': 'Alice',
          'editRevision': revision,
        });
        await until(session, () => session.dirty.value);
        expect(session.tree.node(input.id)!.props['value'], 'Alice');
        expect(session.error.value, null);
      } finally {
        await session.close();
        session.dispose();
      }
    },
  );
  testWidgets('real native page responds to Flutter click and text editing', (
    tester,
  ) async {
    final session = (await tester.runAsync(start))!;
    await tester.pumpWidget(wrap(PluginUiSurface(session: session)));
    await tester.pumpAndSettle();
    expect(find.text('Count 0'), findsOneWidget);
    await tester.tap(find.text('Add'));
    await tester.runAsync(() => until(session, () => text(session, 'Count 1')));
    await tester.pumpAndSettle();
    expect(find.text('Count 1'), findsOneWidget);
    expect(find.text('Positive'), findsOneWidget);
    final input = find.byType(TextField);
    await tester.ensureVisible(input);
    await tester.enterText(input, 'Native draft');
    await tester.runAsync(() => until(session, () => session.dirty.value));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, 'Native draft');
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.runAsync(session.close);
    session.dispose();
  });
}
