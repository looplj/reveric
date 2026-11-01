// 职责: 在原生 Flutter 应用中验收内置记忆页面的中文输入、保存和 Prompt 共享数据。
// 关联文件:
//   plugins/memory/src/views/manage.tsx
//   lib/shared/widgets/plugin_view/surface.dart
//   lib/shared/services/plugins/host.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/agent/agent.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_event.dart';
import 'package:reveric/shared/agent/client/openai_responses_client.dart';
import 'package:reveric/shared/services/plugins/agent_dispatcher.dart';
import '../test/shared/services/plugins/agent_dispatcher_test.dart'
    show RequestInner;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
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
import 'package:reveric/shared/widgets/plugin_view/surface.dart';
import 'package:reveric/shared/widgets/a2ui/components/display.dart'
    show a2uiIconAssets;

import '../test/shared/widgets/plugin_view/input_test.dart' show wrap;

Future<void> waitFor(PluginUiSession page, bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (page.error.value != null) {
      throw StateError(page.error.value!);
    }
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Memory page');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => rootBundle.clear());
  testWidgets(
    'native memory page saves Chinese input and updates shared data',
    (tester) async {
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      SharedPreferences.setMockInitialValues({});
      await EasyLocalization.ensureInitialized();
      final root = await Directory.systemTemp.createTemp('memory-native-');
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final manifest = PluginManifest.fromJson(
        jsonDecode(
              await rootBundle.loadString(
                'assets/plugins/reveric.memory/plugin.json',
              ),
            )
            as Map<String, dynamic>,
      );
      final package = PluginPackage(
        'assets/plugins/reveric.memory',
        manifest,
        await rootBundle.loadString(
          'assets/plugins/reveric.memory/dist/index.js',
        ),
      );
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [package],
        applicationSupport: () async => root,
      );
      PluginUiSession? page;
      final frames = <FrameTiming>[];
      void timings(List<FrameTiming> values) {
        frames.addAll(values);
      }

      binding.addTimingsCallback(timings);
      try {
        await tester.runAsync(() async {
          await host.start();
          await host.confirmPermissions('reveric.memory');
          // Memory 默认关闭，测试需要先开启。
          await host.setEnabled('reveric.memory', true);
          page = await host.openTsxView(
            host.views.single,
            workId: null,
            confirmDiscard: () async => false,
            iconNames: a2uiIconAssets.keys.toSet(),
          );
        });
        await tester.pumpWidget(wrap(PluginUiSurface(session: page!)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('新建'));
        await tester.runAsync(() => waitFor(page!, () => page!.dirty.value));
        await tester.pumpAndSettle();
        final input = find.byWidgetPredicate(
          (w) => w is TextField && w.maxLines != 1,
        );
        await tester.ensureVisible(input);
        await tester.enterText(input, '中文记忆：主角不喝咖啡。');
        await tester.runAsync(
          () => waitFor(
            page!,
            () => page!.tree.nodes.values.any(
              (n) => n.props['value'] == '中文记忆：主角不喝咖啡。',
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('保存'));
        await tester.tap(find.text('保存'));
        await tester.runAsync(() => waitFor(page!, () => !page!.dirty.value));
        await tester.pumpAndSettle();
        expect(find.text('中文记忆：主角不喝咖啡。'), findsOneWidget);
        final result = await tester.runAsync(
          () => host.execute('MemorySearch', {}),
        );
        expect((result!['items'] as List).single['content'], '中文记忆：主角不喝咖啡。');
        expect(tester.takeException(), isNull);
        Future<void> saveWork(String workId, String text) async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await page!.close();
            page!.dispose();
            await db.novelDao.create(
              id: workId,
              title: workId,
              description: '',
              contentDatabasePath: 'test-$workId',
            );
            page = await host.openTsxView(
              host.views.single,
              workId: workId,
              confirmDiscard: () async => true,
              iconNames: a2uiIconAssets.keys.toSet(),
            );
          });
          await tester.pumpWidget(wrap(PluginUiSurface(session: page!)));
          await tester.pumpAndSettle();
          await tester.tap(find.text('新建'));
          await tester.runAsync(() => waitFor(page!, () => page!.dirty.value));
          await tester.pumpAndSettle();
          final field = find.byWidgetPredicate(
            (w) => w is TextField && w.maxLines != 1,
          );
          await tester.ensureVisible(field);
          await tester.enterText(field, text);
          await tester.runAsync(
            () => waitFor(
              page!,
              () =>
                  page!.tree.nodes.values.any((n) => n.props['value'] == text),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('保存'));
          await tester.tap(find.text('保存'));
          await tester.runAsync(() => waitFor(page!, () => !page!.dirty.value));
          await tester.pumpAndSettle();
        }

        await saveWork('work-a', '作品甲只在春天开花。');
        await saveWork('work-b', '作品乙的天空是绿色。');
        final wire = <String, String>{};
        final calls = <String, int>{};
        for (final scope in [
          (null, 'main-global'),
          ('work-a', 'main-a'),
          ('work-a', 'child-a'),
          ('work-b', 'main-b'),
          ('work-b', 'child-b'),
        ]) {
          final transport = MockClient((request) async {
            wire[scope.$2] = request.body;
            calls[scope.$2] = (calls[scope.$2] ?? 0) + 1;
            final delta = {
              'type': 'response.output_text.delta',
              'sequence_number': 0,
              'item_id': 'message',
              'output_index': 0,
              'content_index': 0,
              'delta': 'ok',
            };
            final terminal = {
              'type': 'response.completed',
              'sequence_number': 1,
              'response': {
                'id': 'fixture',
                'object': 'response',
                'status': 'completed',
                'output': [],
              },
            };
            return http.Response(
              'event: response.output_text.delta\ndata: ${jsonEncode(delta)}\n\nevent: response.completed\ndata: ${jsonEncode(terminal)}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          });
          final client = OpenAIResponsesClient(
            apiKey: 'fixture',
            baseUrl: 'https://example.invalid',
            model: 'gpt-5',
            httpClient: transport,
            streamHttpClientFactory: () => transport,
          );
          final dispatcher = PluginAgentToolDispatcher(
            inner: RequestInner(),
            host: host,
            sessionId: scope.$2,
            agentId: scope.$2,
            scope: (workId: scope.$1, mode: 'chat'),
          );
          final agent = Agent.custom(
            id: scope.$2,
            systemPrompt: 'System',
            client: client,
            config: const AgentConfig(maxTokens: 32),
            toolManager: dispatcher,
          );
          final events = await tester.runAsync(
            () => agent.process('Verify scoped memory').toList(),
          );
          expect(events!.whereType<AgentDone>().single.finalText, 'ok');
          expect(calls[scope.$2], 1);
          transport.close();
          expect(wire[scope.$2], contains('中文记忆：主角不喝咖啡。'));
          expect(
            wire[scope.$2],
            scope.$1 == 'work-a'
                ? contains('作品甲只在春天开花。')
                : isNot(contains('作品甲只在春天开花。')),
          );
          expect(
            wire[scope.$2],
            scope.$1 == 'work-b'
                ? contains('作品乙的天空是绿色。')
                : isNot(contains('作品乙的天空是绿色。')),
          );
        }
        stdout.writeln(
          'MEMORY_REQUEST_WIRE scopes=${wire.keys.join(",")} actual_agent_and_http=true',
        );

        final build = frames.map((f) => f.buildDuration.inMicroseconds).toList()
          ..sort();
        final raster =
            frames.map((f) => f.rasterDuration.inMicroseconds).toList()..sort();
        Map<String, Object> stats(List<int> v) => v.isEmpty
            ? {'samples': 0}
            : {
                'samples': v.length,
                'p50_us': v[(v.length * .5).floor()],
                'p95_us': v[((v.length - 1) * .95).ceil()],
                'max_us': v.last,
              };
        binding.reportData = {
          'memory_build': stats(build),
          'memory_raster': stats(raster),
          'rss_bytes': ProcessInfo.currentRss,
          'max_rss_bytes': ProcessInfo.maxRss,
        };
        stdout.writeln(
          'MEMORY_NATIVE_ACCEPTANCE ${jsonEncode(binding.reportData)}',
        );
      } finally {
        binding.removeTimingsCallback(timings);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await page?.close();
          page?.dispose();
          await host.dispose();
          await db.close();
          await root.delete(recursive: true);
        });
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
