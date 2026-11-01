// 职责: 在新构建的原生宿主中验证打包插件、真实 fjs 与设置启停，不访问用户数据库。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/widgets/settings/plugins/section.dart
//   test/shared/widgets/settings/plugins_section_test.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import '../test/shared/widgets/settings/plugins_section_test.dart'
    show wrapPluginSettings;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => rootBundle.clear());
  testWidgets(
    'bundled plugin runs through native fjs and settings disable new calls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await EasyLocalization.ensureInitialized();
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final host = PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(
          hostToolNames: {'Read', 'Write', 'Run', 'Codemode'},
        ),
      );
      HttpServer? server;
      try {
        await tester.runAsync(() async {
          await host.start();
          expect(web(host).state, 'available', reason: web(host).error);
          expect(
            host.registry.effectiveTools.map((tool) => tool.name),
            containsAll(['WebSearch', 'WebFetch']),
          );
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server!.listen((request) async {
            request.response.headers.contentType = ContentType.html;
            request.response.write(
              '<html><head><title>Native smoke</title></head><body><h1>Native plugin</h1><p>Readable local response.</p></body></html>',
            );
            await request.response.close();
          });
          final result = await host.execute('WebFetch', {
            'url': 'http://127.0.0.1:${server!.port}/page',
          });
          expect(result['ok'], true, reason: result.toString());
          expect(result['content'], contains('Readable local response.'));
          stdout.writeln(
            'PLUGIN_NATIVE_SMOKE activated=${web(host).manifest!.version} fetch=ok',
          );
        });
        await tester.pumpWidget(wrapPluginSettings(host));
        await tester.pumpAndSettle();
        expect(find.text('Web Search'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('plugin-details-reveric.web')),
        );
        await tester.pumpAndSettle();
        // 详情页的工具列表默认折叠。
        await tester.tap(find.text('Tools (2)'));
        await tester.pumpAndSettle();
        expect(find.text('WebSearch'), findsOneWidget);
        expect(find.text('WebFetch'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('plugin-toggle-reveric.web')),
        );
        await tester.runAsync(() => _waitState(host, 'disabled'));
        await tester.pumpAndSettle();
        expect(find.text('Disabled'), findsOneWidget);
        expect(
          (await host.execute('WebFetch', {
            'url': 'http://127.0.0.1:${server!.port}/page',
          }))['error_code'],
          'plugin_unavailable',
        );
        await tester.tap(
          find.byKey(const ValueKey('plugin-toggle-reveric.web')),
        );
        await tester.runAsync(() => _waitState(host, 'available'));
        await tester.pumpAndSettle();
        expect(find.text('Available'), findsOneWidget);
        stdout.writeln(
          'PLUGIN_NATIVE_SMOKE settings=disable-enable-ok user_db=untouched',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        await tester.runAsync(() async {
          await server?.close(force: true);
          await host.dispose();
          await database.close();
        });
      }
    },
  );
}

PluginStatus web(PluginHostService host) =>
    host.statuses.singleWhere((status) => status.manifest?.id == 'reveric.web');

Future<void> _waitState(PluginHostService host, String expected) async {
  await Future<void>(() async {
    while (web(host).state != expected) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }).timeout(const Duration(seconds: 10));
}
