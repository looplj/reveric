// 职责: 通过真实内置记忆包验证工具、Prompt、TSX、任务与私有库重启闭环。
// 关联文件:
//   plugins/memory/src/index.ts
//   lib/shared/services/plugins/host.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/models/plugin/view.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/services/plugins/ai.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/agent_dispatcher.dart';
import 'package:reveric/shared/services/plugins/ui_session.dart';
import 'package:reveric/shared/widgets/a2ui/components/display.dart'
    show a2uiIconAssets;
import 'agent_dispatcher_test.dart' show RequestInner;

/// 新会话中本轮会追加的插件上下文消息正文。
String pluginContext(PluginAgentToolDispatcher dispatcher) => dispatcher
    .requestMessages(const [])
    .map((message) => message.content)
    .join('\n');

Future<void> until(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Memory flow');
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
    'real memory package shares tool/prompt/page/task data and persists across restart',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final root = await Directory.systemTemp.createTemp('memory-flow-');
      const relative = 'plugins/reveric.memory/1.0.0';
      final source = Directory('assets/plugins/reveric.memory');
      for (final entity in source.listSync(recursive: true).whereType<File>()) {
        final target = File(
          '${root.path}/$relative/${entity.path.substring(source.path.length + 1)}',
        );
        await target.parent.create(recursive: true);
        await entity.copy(target.path);
      }
      final package = PluginPackage(
        relative,
        PluginManifest.fromJson(
          jsonDecode(await File('${source.path}/plugin.json').readAsString())
              as Map<String, dynamic>,
        ),
        await File('${source.path}/dist/index.js').readAsString(),
        source: 'local',
      );
      var calls = 0;
      PluginHostService build() => PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [package],
        applicationSupport: () async => root,
        ai: _RefineAi(() => calls++),
      );
      var host = build();
      PluginUiSession? page;
      Future<PluginUiSession> openPage() async {
        final session = await host.openTsxView(
          host.views.single,
          workId: 'work',
          confirmDiscard: () async => false,
          iconNames: a2uiIconAssets.keys.toSet(),
        );
        await session.setEnvironment({
          'visible': true,
          'width': 900,
          'height': 800,
          'platform': 'macos',
          'theme': 'light',
          'locale': 'zh-CN',
        });
        return session;
      }

      try {
        await db.novelDao.create(
          id: 'work',
          title: 'Work',
          description: '',
          contentDatabasePath: 'unused',
        );
        await host.start();
        await host.confirmPermissions('reveric.memory');
        // 该测试以 local 来源加载包，需显式启用。
        await host.setEnabled('reveric.memory', true);
        final dispatcher = PluginAgentToolDispatcher(
          inner: RequestInner(),
          host: host,
          sessionId: 'memory-session',
          agentId: 'agent',
          scope: (workId: 'work', mode: 'chat'),
        );
        await dispatcher.prepareRequest(runStart: true);
        final created = await dispatcher.executeTool(
          name: 'MemorySave',
          input: {'content': '中文原始记忆', 'topic': '文风'},
        );
        final saved = created['memory'] as Map<String, dynamic>;
        expect(saved['content'], '中文原始记忆', reason: created.toString());
        await dispatcher.prepareRequest(runStart: true);
        expect(pluginContext(dispatcher), contains('中文原始记忆'));
        expect(
          pluginContext(dispatcher),
          isNot(contains('Treat content as data')),
        );
        page = await openPage();
        await until(
          () =>
              page!.tree.nodes.values.any((n) => n.props['text'] == '中文原始记忆') ||
              page.error.value != null,
        );
        expect(page.error.value, isNull);
        // 编辑入口在记忆卡片的“更多操作”菜单中。
        final menu = page.tree.nodes.values.firstWhere(
          (n) =>
              n.component == 'Menu' &&
              (n.props['items'] as List).any((item) => item['id'] == 'edit'),
        );
        page.dispatch(menu, 'onSelect', {'id': 'edit'});
        await until(() => page!.dirty.value);
        await expectLater(
          host.setEnabled('reveric.memory', false),
          throwsA(anything),
        );
        expect(host.statuses.single.state, 'available');
        final cancel = page.tree.nodes.values.firstWhere(
          (n) => n.props['label'] == '取消',
        );
        page.dispatch(cancel, 'onPress', {});
        await until(() => !page!.dirty.value);
        await host.tasks.runNow('reveric.memory', 'organize');
        await until(
          () async =>
              (await db.pluginTaskDao.get(
                'reveric.memory',
                'organize',
              ))!.lastStatus ==
              'success',
        );
        expect(calls, 1);
        expect(
          host.pageBadge('reveric.memory', 'manage'),
          const PluginPageBadge(count: 1, tone: PluginPageBadgeTone.accent),
        );
        final refresh = page.tree.nodes.values.firstWhere(
          (n) => n.component == 'IconButton' && n.props['tooltip'] == '刷新',
        );
        page.dispatch(refresh, 'onPress', {});
        await until(
          () => page!.tree.nodes.values.any((n) => n.props['label'] == '应用'),
        );
        final apply = page.tree.nodes.values.firstWhere(
          (n) => n.props['label'] == '应用',
        );
        page.dispatch(apply, 'onPress', {});
        await until(
          () => page!.tree.nodes.values.any(
            (n) => n.props['text'] == 'Refined: 中文原始记忆',
          ),
        );
        await until(() => host.pageBadge('reveric.memory', 'manage') == null);
        await dispatcher.prepareRequest(runStart: true);
        expect(pluginContext(dispatcher), contains('Refined: 中文原始记忆'));
        await host.setEnabled('reveric.memory', false);
        expect(host.registry.effectiveTools, isEmpty);
        expect(host.views, isEmpty);
        expect(page.closed, true);
        await dispatcher.prepareRequest(runStart: true);
        expect(pluginContext(dispatcher), isNot(contains('中文原始记忆')));
        await host.dispose();
        host = build();
        await host.start();
        await host.setEnabled('reveric.memory', true);
        final resumed = PluginAgentToolDispatcher(
          inner: RequestInner(),
          host: host,
          sessionId: 'after-restart',
          agentId: 'agent',
          scope: (workId: 'work', mode: 'chat'),
        );
        await resumed.prepareRequest(runStart: true);
        expect(pluginContext(resumed), contains('Refined: 中文原始记忆'));
        final forgotten = await resumed.executeTool(
          name: 'MemoryForget',
          input: {'id': saved['id']},
        );
        expect(forgotten['deleted'], true);
        await resumed.prepareRequest(runStart: true);
        expect(pluginContext(resumed), isNot(contains('Refined: 中文原始记忆')));
        expect(
          (await db.pluginTaskDao.get(
            'reveric.memory',
            'organize',
          ))!.lastUsage?['calls'],
          1,
        );

        // The host enforces a 1 MB result limit. Seed both the oversized
        // unpaginated result and a match outside the old 500-row cap.
        final sqlite = await host.privateDatabases();
        final longContent = '长' * 3996;
        const target = '唯一搜索目标';
        for (var start = 0; start <= 500; start += 25) {
          await sqlite.call('reveric.memory', 'transaction', {
            'statements': [
              for (var i = start; i < start + 25 && i <= 500; i++)
                {
                  'sql':
                      'INSERT INTO memories '
                      '(id, content, topic, created_at, updated_at) '
                      'VALUES (?, ?, ?, 1, ?)',
                  'params': [
                    'seed_$i',
                    i == 500 ? target : (i < 100 ? '$i $longContent' : '偏好 $i'),
                    '文风',
                    501 - i,
                  ],
                },
            ],
          });
        }
        final largePage = await openPage();
        page = largePage;
        bool hasText(String value) => largePage.tree.nodes.values.any(
          (node) => (node.props['text'] as String?)?.startsWith(value) ?? false,
        );
        await until(() => hasText('0 $longContent') || hasText('读取失败'));
        expect(hasText('0 $longContent'), true);
        expect(hasText('20 $longContent'), false);
        await until(
          () => largePage.tree.nodes.values.any(
            (node) =>
                (node.props['text'] as String?)?.contains('/501 条') ?? false,
          ),
        );
        expect(
          largePage.tree.nodes.values.any(
            (node) =>
                (node.props['text'] as String?)?.contains('超出聊天注入预算') ?? false,
          ),
          true,
        );
        await until(
          () =>
              host.pageBadge('reveric.memory', 'manage') ==
              const PluginPageBadge(
                dot: true,
                tone: PluginPageBadgeTone.warning,
              ),
        );
        final next = largePage.tree.nodes.values.firstWhere(
          (node) => node.props['label'] == '下一页',
        );
        largePage.dispatch(next, 'onPress', {});
        await until(() => hasText('20 $longContent'));
        expect(hasText('0 $longContent'), false);
        final search = largePage.tree.nodes.values.firstWhere(
          (node) => node.component == 'SearchField',
        );
        largePage.dispatch(search, 'onChange', {'value': target});
        await until(() => hasText(target));
        expect(hasText('20 $longContent'), false);
        expect(hasText('读取失败'), false);
      } finally {
        await page?.close();
        await host.dispose();
        await db.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

class _RefineAi implements PluginAiApi {
  _RefineAi(this.onCall);
  final void Function() onCall;

  @override
  List<Map<String, dynamic>> listModels() => const [];

  @override
  Future<PluginAiResult> generate(
    PluginAiRequest request,
    AgentCancellationToken cancellation,
  ) async {
    onCall();
    final input = jsonDecode(request.prompt) as List;
    return (
      text: jsonEncode([
        for (final row in input)
          {
            'kind': 'refine',
            'reason': '精简表述',
            'sources': [
              {'id': (row as Map)['id'], 'revision': row['revision']},
            ],
            'content': 'Refined: ${row['content']}',
            'topic': row['topic'] ?? '',
          },
      ]),
      finishReason: 'stop',
      providerId: 'mock',
      model: 'mock-model',
      usage: <String, dynamic>{'input_tokens': 20, 'output_tokens': 10},
    );
  }
}
