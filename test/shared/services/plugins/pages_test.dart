// 职责: 通过真实 fjs 页面验证宿主实例限额、草稿取消与停用后的资源释放。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/ui_session.dart
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:reveric/shared/widgets/a2ui/session.dart';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import 'package:reveric/shared/services/plugins/ui_session.dart';

Future<void> ready(PluginUiSession session) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!session.ready.value) {
    if (session.error.value != null) {
      throw StateError(session.error.value!);
    }
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Page mount');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final path = Platform.environment['FJS_PROBE_LIBRARY'];
    if (path == null) {
      throw StateError('Set FJS_PROBE_LIBRARY');
    }
    await LibFjs.init(externalLibrary: ExternalLibrary.open(path));
  });
  test(
    'A2UI onMount actions share lifecycle and preserve data between runtimes',
    () async {
      final root = await Directory.systemTemp.createTemp('plugin-a2ui-test-');
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final directory = await Directory(
        '${root.path}/plugins/test.a2ui/1.0.0',
      ).create(recursive: true);
      await File('${directory.path}/page.json').writeAsString(
        jsonEncode([
          {
            'version': 'v1.0',
            'createSurface': {
              'surfaceId': 'foreign',
              'components': [
                {'id': 'root', 'component': 'Text', 'text': 'Report'},
              ],
              'dataModel': {'count': 0},
            },
          },
        ]),
      );
      final package = PluginPackage(
        'plugins/test.a2ui/1.0.0',
        PluginManifest.fromJson({
          'id': 'test.a2ui',
          'name': 'A2UI',
          'version': '1.0.0',
          'main': 'index.js',
          'pluginApiVersion': '^1',
          'defaultEnabled': true,
          'pages': {
            'report': {
              'title': 'Report',
              'location': 'home.plugin',
              'protocol': 'reveric-ui-v1',
              'source': 'page.json',
              'onMount': 'load',
              'actions': ['load'],
            },
          },
        }),
        """var __revericPlugin={apply(setup){setup.pages.registerAction('report','load',async(data,event,context)=>{
      await context.view.setDirty(true);
      await context.ui.toast({message:'Loaded'});
      return [{version:'v1.0',updateDataModel:{path:'/',value:{count:data.count+1,workId:context.page.workId}}}];
    });}};""",
        source: 'local',
      );
      final host = PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [package],
        applicationSupport: () async => root,
      );
      try {
        await host.start();
        var discard = false;
        final uiCalls = <String>[];
        final page = await host.openA2uiView(
          host.views.single,
          workId: 'work',
          uiCall: (method, args) async {
            uiCalls.add(method);
            return null;
          },
          confirmDiscard: () async => discard,
        );
        addTearDown(page.dispose);
        Future<void> count(int expected) async {
          final end = DateTime.now().add(const Duration(seconds: 8));
          while ((page.surface.dataSnapshot() as Map)['count'] != expected) {
            if (page.actionError.value != null) {
              throw page.actionError.value!;
            }
            if (DateTime.now().isAfter(end)) {
              throw TimeoutException('A2UI action');
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }

        await count(1);
        expect(uiCalls, ['ui.toast']);
        expect(page.dirty.value, true);
        page.surface.dispatchAction(
          A2uiActionEvent(
            name: 'load',
            sourceComponentId: 'root',
            context: {},
            data: page.surface.dataSnapshot(),
          ),
        );
        await count(2);
        expect(page.surface.dataSnapshot(), {'count': 2, 'workId': 'work'});
        await expectLater(
          host.uninstall('test.a2ui'),
          throwsA(isA<PluginHostError>()),
        );
        expect(page.closed, false);
        discard = true;
        await host.uninstall('test.a2ui');
        expect(page.closed, true);
        expect(host.views, isEmpty);
      } finally {
        await host.dispose();
        await database.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'page instances enforce caps and dirty cancellation preserves enabled state',
    () async {
      final root = await Directory.systemTemp.createTemp('plugin-page-test-');
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final directory = await Directory(
        '${root.path}/plugins/test.pages/1.0.0',
      ).create(recursive: true);
      await File('${directory.path}/page.js').writeAsString(
        File('assets/plugin_preview/counter.js').readAsStringSync(),
      );
      final package = PluginPackage(
        'plugins/test.pages/1.0.0',
        PluginManifest.fromJson({
          'id': 'test.pages',
          'name': 'Pages',
          'version': '1.0.0',
          'main': 'index.js',
          'pluginApiVersion': '^1',
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
        "var __revericPlugin={apply(setup){}};",
        source: 'local',
      );
      final host = PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [package],
        applicationSupport: () async => root,
      );
      final sessions = <PluginUiSession>[];
      try {
        await host.start();
        expect(host.statuses.single.state, 'available');
        final view = host.views.single;
        var discard = false;
        final first = await host.openTsxView(
          view,
          workId: null,
          confirmDiscard: () async => discard,
        );
        sessions.add(first);
        final second = await host.openTsxView(
          view,
          workId: null,
          confirmDiscard: () async => true,
        );
        sessions.add(second);
        await ready(first);
        await ready(second);
        expect(first.tree.surface, isNot(second.tree.surface));
        await expectLater(
          host.openTsxView(
            view,
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
        first.dirty.value = true;
        await expectLater(
          host.setEnabled(view.pluginId, false),
          throwsA(
            isA<PluginHostError>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        expect(first.closed, false);
        expect(second.closed, false);
        expect(
          (await database.pluginDao.getPlugin(view.pluginId))!.enabled,
          true,
        );
        discard = true;
        await host.setEnabled(view.pluginId, false);
        expect(first.closed, true);
        expect(second.closed, true);
        expect(host.views, isEmpty);
        await expectLater(
          first.hostCall('storage.get', {'key': 'test'}),
          throwsA(isA<PluginHostError>()),
        );
        await host.setEnabled(view.pluginId, true);
        final reopened = await host.openTsxView(
          host.views.single,
          workId: null,
          confirmDiscard: () async => true,
        );
        sessions.add(reopened);
        await ready(reopened);
        expect(reopened.tree.surface, isNot(first.tree.surface));
      } finally {
        await host.dispose();
        for (final session in sessions) {
          session.dispose();
        }
        await database.close();
        await root.delete(recursive: true);
      }
    },
  );
}
