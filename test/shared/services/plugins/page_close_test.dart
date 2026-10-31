// 职责: 验证真实原生页面清理完成前保留宿主配额，并拒绝迟到请求和重复关闭竞态。
// 关联文件:
//   lib/shared/services/plugins/ui_session.dart
//   lib/shared/services/plugins/host.dart
//   third/fjs/libfjs/src/api/ui.rs
import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart' as fjs;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

Future<void> until(FutureOr<bool> Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!await condition()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Native close condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final library = Platform.environment['FJS_PROBE_LIBRARY'];
    if (library == null) {
      throw StateError('Set FJS_PROBE_LIBRARY');
    }
    await fjs.LibFjs.init(externalLibrary: ExternalLibrary.open(library));
  });
  for (final cleanup in [
    'const end=Date.now()+250;while(Date.now()<end){}',
    'while(true){}',
  ]) {
    test(
      'close shares completion and holds engine slots during $cleanup',
      () async {
        expect(
          fjs.UiSession.resourceCounts().values.every(
            (value) => value == BigInt.zero,
          ),
          true,
        );
        final root = await Directory.systemTemp.createTemp(
          'plugin-page-close-',
        );
        final folder = await Directory(
          '${root.path}/plugins/test.close/1.0.0',
        ).create(recursive: true);
        await File('${folder.path}/page.js').writeAsString('''
var __revericView={mount(context){const u=__revericUi,n=__revericNative;
return u.mount(()=>{const s=u.signal(0);u.effect(()=>s());setInterval(()=>{},50);
u.cleanup(()=>{$cleanup});context.ui.dialog({title:'pending'}).catch(()=>{});
const node=n.create('Button');n.set(node,{label:'ready'});n.listen(node,'onPress',()=>s.set(s()+1));return node;
},context.root);}};
''');
        final package = PluginPackage(
          'plugins/test.close/1.0.0',
          PluginManifest.fromJson({
            'id': 'test.close',
            'name': 'Close',
            'version': '1.0.0',
            'pluginApiVersion': '^1',
            'main': 'index.js',
            'defaultEnabled': true,
            'pages': {
              'page': {
                'title': 'Page',
                'location': 'home.plugin',
                'protocol': 'reveric-tsx-v1',
                'source': 'page.js',
              },
            },
          }),
          "var __revericPlugin={apply(c){}};",
          source: 'local',
        );
        final db = AppDatabase.forTest(NativeDatabase.memory());
        final host = PluginHostService(
          dao: db.pluginDao,
          registry: PluginRegistry(hostToolNames: {}),
          packages: () async => [package],
          applicationSupport: () async => root,
        );
        final waits = <Completer<Object?>>[];
        var cancelled = 0;
        try {
          await host.start();
          Future<Object?> ui(String method, Map<String, dynamic> args) {
            final done = Completer<Object?>();
            waits.add(done);
            return done.future;
          }

          final first = await host.openTsxView(
            host.views.single,
            workId: null,
            confirmDiscard: () async => true,
            uiCall: ui,
            onClose: () => cancelled++,
          );
          final second = await host.openTsxView(
            host.views.single,
            workId: null,
            confirmDiscard: () async => true,
            uiCall: ui,
            onClose: () => cancelled++,
          );
          await until(
            () => waits.length == 2 && first.ready.value && second.ready.value,
          );
          final live = fjs.UiSession.resourceCounts();
          expect(live['engines'], BigInt.from(2));
          for (final key in [
            'graph_nodes',
            'subscriptions',
            'timers',
            'pending_host',
            'event_handlers',
          ]) {
            expect(live[key]! > BigInt.zero, true, reason: key);
          }
          final watch = Stopwatch()..start();
          final closing = first.close();
          final other = second.close();
          expect(identical(first.close(), closing), true);
          expect(first.closed, true);
          expect(cancelled, 2);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(fjs.UiSession.resourceCounts()['engines'], BigInt.from(2));
          await expectLater(
            host.openTsxView(
              host.views.single,
              workId: null,
              confirmDiscard: () async => true,
            ),
            throwsA(
              isA<PluginHostError>().having(
                (e) => e.code,
                'code',
                'plugin_ui_limit',
              ),
            ),
          );
          await Future.wait([closing, other]);
          expect(
            watch.elapsedMilliseconds,
            greaterThanOrEqualTo(cleanup.startsWith('while') ? 1800 : 200),
          );
          expect(
            fjs.UiSession.resourceCounts().values.every(
              (value) => value == BigInt.zero,
            ),
            true,
          );
          for (final done in waits) {
            done.complete(null);
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(first.error.value, isNull);
          expect(second.error.value, isNull);
          first.dispose();
          second.dispose();
          final replacement = await host.openTsxView(
            host.views.single,
            workId: null,
            confirmDiscard: () async => true,
            uiCall: (m, a) async => null,
          );
          await until(() => replacement.ready.value);
          await replacement.close();
          replacement.dispose();
          expect(
            fjs.UiSession.resourceCounts().values.every(
              (value) => value == BigInt.zero,
            ),
            true,
          );
        } finally {
          await host.dispose();
          await db.close();
          await root.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  }
}
