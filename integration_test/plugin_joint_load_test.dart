// 职责: 在真实原生宿主联合运行四页面、任务 AI、Prompt 和 SQL 并验证关闭后的资源归零。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/tasks.dart
//   lib/shared/widgets/plugin_view/surface.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:fjs/fjs.dart' as fjs;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/ui_session.dart';
import 'package:reveric/shared/widgets/a2ui/components/display.dart'
    show a2uiIconAssets;
import 'package:reveric/shared/widgets/plugin_view/surface.dart';
import '../test/shared/widgets/plugin_view/input_test.dart' show wrap;

Future<void> until(FutureOr<bool> Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!await ready()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Joint plugin load');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => rootBundle.clear());
  testWidgets(
    'four pages plus task AI and Prompt SQL return resources to baseline',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await EasyLocalization.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('plugin-joint-');
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final json =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/plugins/reveric.memory/plugin.json',
                ),
              )
              as Map<String, dynamic>;
      final packages = [
        PluginPackage(
          'assets/plugins/reveric.memory',
          PluginManifest.fromJson(json),
          await rootBundle.loadString(
            'assets/plugins/reveric.memory/dist/index.js',
          ),
        ),
        PluginPackage(
          'assets/plugins/reveric.memory',
          PluginManifest.fromJson({
            ...json,
            'id': 'test.joint',
            'name': 'Joint',
            'pages': {
              'page': {
                'title': 'Joint',
                'location': 'home.plugin',
                'protocol': 'reveric-tsx-v1',
                'source': 'dist/views/manage.js',
              },
            },
            'tasks': {
              'hold': {'title': 'Joint AI', 'intervalMinutes': 60},
            },
          }),
          """
var __revericPlugin={apply(c){
c.prompts.context({id:'sql',handler:async(context)=>{const rows=await context.sqlite.query({sql:'SELECT content FROM memories WHERE deleted_at IS NULL'});return 'Joint SQL rows '+rows.length;}});
c.tasks.register('hold',async(context)=>{await context.ai.generateText({system:'Fixture',prompt:'Joint load',maxOutputTokens:10});await context.storage.set('done',true);return {summary:'done'};});
c.tools.register({name:'JointTool',description:'Fixture SQL',inputSchema:{type:'object'},handler:async(input,context)=>({rows:await context.sqlite.query({sql:'SELECT content FROM memories WHERE deleted_at IS NULL'})})});
}};
""",
        ),
      ];
      final aiWaits = <Completer<void>>[];
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => packages,
        applicationSupport: () async => root,
        taskAi: (request, cancellation) async {
          final done = Completer<void>();
          aiWaits.add(done);
          final unlink = cancellation.onCancel(() {
            if (!done.isCompleted) {
              done.completeError(StateError('Cancelled'));
            }
          });
          try {
            await done.future;
            return (
              text: '[]',
              usage: <String, dynamic>{'input_tokens': 5, 'output_tokens': 2},
            );
          } finally {
            unlink();
          }
        },
      );
      final pages = <PluginUiSession>[];
      var peakRss = 0;
      Timer? sampler;
      try {
        await tester.runAsync(() async {
          await db.novelDao.create(
            id: 'joint-work',
            title: 'Joint',
            description: '',
            contentDatabasePath: 'unused',
          );
          await host.start();
          await host.confirmPermissions('reveric.memory');
          await host.confirmPermissions('test.joint');
          expect(
            fjs.UiSession.resourceCounts().values.every(
              (n) => n == BigInt.zero,
            ),
            true,
          );
          expect(
            (await host.execute('MemoryCreate', {
              'scope': 'global',
              'content': '联合负载记忆',
              'category': 'fact',
            }))['content'],
            '联合负载记忆',
          );
          for (final view in host.views) {
            for (final work in <String?>[null, 'joint-work']) {
              pages.add(
                await host.openTsxView(
                  view,
                  workId: work,
                  confirmDiscard: () async => true,
                  iconNames: a2uiIconAssets.keys.toSet(),
                ),
              );
            }
          }
          await until(() => pages.every((p) => p.ready.value));
        });
        await tester.pumpWidget(
          wrap(
            GridView.count(
              // The manage toolbar needs about 360 logical pixels; two
              // columns inside the 500-wide harness would overflow it.
              crossAxisCount: 1,
              children: [
                for (final page in pages) PluginUiSurface(session: page),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final baselineRss = ProcessInfo.currentRss;
        final counts = fjs.UiSession.resourceCounts();
        expect(counts['engines'], BigInt.from(4));
        await tester.runAsync(() async {
          sampler = Timer.periodic(const Duration(milliseconds: 5), (_) {
            final rss = ProcessInfo.currentRss;
            if (rss > peakRss) {
              peakRss = rss;
            }
          });
          await host.tasks.runNow('reveric.memory', 'organize');
          await host.tasks.runNow('test.joint', 'hold');
          await until(() => aiWaits.length == 2);
          expect(host.tasks.running('reveric.memory', 'organize'), true);
          expect(host.tasks.running('test.joint', 'hold'), true);
          final database = await host.privateDatabases();
          final sql = database.call('reveric.memory', 'query', {
            'statement': {
              'sql':
                  'WITH RECURSIVE seq(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM seq WHERE x<150000) SELECT SUM(x) AS total FROM seq',
            },
          });
          final request = await host.requestContext(
            sessionId: 'joint-request',
            fallbackSessionId: 'joint-request',
            agentId: 'main',
            scope: (workId: 'joint-work', mode: 'chat'),
          );
          final prompt = host.requestPromptContext(request);
          final tool = host.execute('JointTool', {});
          await sql;
          expect(
            (await prompt).map((result) => result.text).join('\n'),
            contains('联合负载记忆'),
          );
          expect((await tool)['rows'], isEmpty);
          expect(fjs.UiSession.resourceCounts()['engines'], BigInt.from(4));
          for (final wait in aiWaits) {
            wait.complete();
          }
          await until(
            () =>
                !host.tasks.pending('reveric.memory', 'organize') &&
                !host.tasks.pending('test.joint', 'hold'),
          );
          expect(
            (await db.pluginTaskDao.get(
              'reveric.memory',
              'organize',
            ))!.lastStatus,
            'success',
          );
          expect(
            (await db.pluginTaskDao.get('test.joint', 'hold'))!.lastStatus,
            'success',
          );
        });
        sampler?.cancel();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await Future.wait(pages.map((p) => p.close()));
          for (final page in pages) {
            page.dispose();
          }
          await host.dispose();
        });
        final after = fjs.UiSession.resourceCounts();
        expect(after.values.every((n) => n == BigInt.zero), true);
        binding.reportData = {
          'pages': 4,
          'simultaneous_task_ai': 2,
          'prompt_sql_overlap': true,
          'baseline_four_pages_rss': baselineRss,
          'joint_peak_rss': peakRss,
          'native_before': counts.map((k, v) => MapEntry(k, v.toInt())),
          'native_after': after.map((k, v) => MapEntry(k, v.toInt())),
        };
        stdout.writeln('PLUGIN_JOINT_LOAD ${jsonEncode(binding.reportData)}');
      } finally {
        sampler?.cancel();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await host.dispose();
          await db.close();
          await root.delete(recursive: true);
        });
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
