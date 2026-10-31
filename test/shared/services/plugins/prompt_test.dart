// 职责: 验证真实插件 Prompt 的请求身份、仅变化时追加的上下文快照、只读限制、预算省略及 system 替换的模式匹配与冲突。
// 关联文件:
//   lib/shared/services/plugins/prompt.dart
//   lib/shared/services/plugins/agent_dispatcher.dart
//   lib/shared/services/plugins/runtime.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/agent_dispatcher.dart';
import 'agent_dispatcher_test.dart' show RequestInner;

PluginPackage plugin(String id, String code) => PluginPackage(
  'unused',
  PluginManifest.fromJson({
    'id': id,
    'name': id,
    'version': '1.0.0',
    'pluginApiVersion': '^1',
    'main': 'index.js',
    'defaultEnabled': true,
  }),
  code,
);

const setTool = """
setup.tools.register({name:'Set',description:'Set test state',inputSchema:{type:'object'},handler:async(input,context)=>{
 for(const [key,value] of Object.entries(input)){await context.storage.set(key,value);}
 return {requestId:context.request.requestId,workId:context.request.workId,agentId:context.request.agentId};
}});
""";

Future<AppDatabase> _database() async {
  final database = AppDatabase.forTest(NativeDatabase.memory());
  await database.novelDao.create(
    id: 'work',
    title: 'Work',
    description: '',
    contentDatabasePath: 'test-content',
  );
  await database.aiChatSessionDao.upsert(
    id: 'session',
    novelId: 'work',
    title: 'Session',
  );
  return database;
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
    'context snapshots are appended only when changed and failures keep the previous one',
    () async {
      final database = await _database();
      final host = PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [
          plugin('test.prompt', """
var __revericPlugin={apply(setup){
setup.prompts.context({id:'memory',handler:async context=>{
 const mode=await context.storage.get('mode');
 if(mode==='forbidden'){await __call('storage.set',{key:'forbidden',value:'write'});return 'invalid';}
 if(mode==='slow'){await new Promise(()=>{});}
 if(mode==='large'){return '中'.repeat(1100);}
 if(mode==='clear'){return null;}
 const value=await context.storage.get('memory');
 return value===null?null:context.request.agentId+'@'+context.request.workId+':'+value;
}});
$setTool
}};
"""),
        ],
      );
      final inner = RequestInner();
      final dispatcher = PluginAgentToolDispatcher(
        inner: inner,
        host: host,
        sessionId: 'session',
        agentId: 'test-agent',
        scope: (workId: 'work', mode: 'chat'),
      );
      final history = <AgentMessage>[];
      Future<List<AgentMessage>> round({bool runStart = false}) async {
        await dispatcher.prepareRequest(runStart: runStart);
        final added = dispatcher.requestMessages(history);
        history.addAll(added);
        return added;
      }

      try {
        await host.start();
        expect(host.statuses.single.state, 'available');
        expect(await round(runStart: true), isEmpty);
        expect(dispatcher.requestSystemPrompt, 'MCP summary');
        expect(dispatcher.systemPromptOverride, isNull);
        final write = await dispatcher.executeTool(
          name: 'Set',
          input: {'memory': 'first', 'mode': 'normal'},
        );
        expect(write['workId'], 'work');
        expect(write['agentId'], 'test-agent');
        final first = await round();
        expect(first, hasLength(1));
        expect(first.single.role, AgentMessageRole.user);
        expect(
          first.single.content,
          startsWith(
            '<system-remind type="plugin_context" plugin="test.prompt" provider="memory">',
          ),
        );
        expect(first.single.content, contains('test-agent@work:first'));
        // 内容未变：工具轮与重试都不再追加。
        expect(await round(), isEmpty);
        expect(await round(runStart: true), isEmpty);
        await dispatcher.executeTool(name: 'Set', input: {'memory': 'second'});
        final second = await round();
        expect(second.single.content, contains('test-agent@work:second'));
        expect(await round(), isEmpty);

        final child = PluginAgentToolDispatcher(
          inner: RequestInner(),
          host: host,
          sessionId: 'ephemeral-child',
          agentId: 'child',
          scope: (workId: 'work', mode: 'roleplay'),
        );
        await child.prepareRequest(runStart: true);
        expect(
          child.requestMessages(const []).single.content,
          contains('child@work:second'),
        );
        final global = PluginAgentToolDispatcher(
          inner: RequestInner(),
          host: host,
          sessionId: 'headless-global',
          agentId: 'global',
          scope: (workId: null, mode: 'chat'),
        );
        await global.prepareRequest(runStart: true);
        expect(
          global.requestMessages(const []).single.content,
          contains('global@null:second'),
        );

        await dispatcher.executeTool(name: 'Set', input: {'mode': 'forbidden'});
        expect(await round(), isEmpty);
        expect(
          await database.pluginDao.getStorage('test.prompt', 'data.forbidden'),
          null,
        );
        expect(
          host.statuses.single.promptDiagnostic?.code,
          'permission_denied',
        );
        await dispatcher.executeTool(name: 'Set', input: {'mode': 'large'});
        expect(await round(), isEmpty);
        expect(host.statuses.single.promptDiagnostic?.code, 'prompt_budget');
        await dispatcher.executeTool(name: 'Set', input: {'mode': 'slow'});
        final clock = Stopwatch()..start();
        expect(await round(), isEmpty);
        expect(clock.elapsedMilliseconds, lessThan(1500));
        expect(
          host.statuses.single.promptDiagnostic?.code,
          anyOf('prompt_timeout', 'plugin_timeout'),
        );

        // 插件变为没有内容时追加一次空快照，之后保持不变。
        await dispatcher.executeTool(name: 'Set', input: {'mode': 'clear'});
        final cleared = await round();
        expect(cleared.single.content, contains('{"content":null}'));
        expect(await round(), isEmpty);
        // 恢复到与历史中更早快照相同的内容也要追加：只和最后一条比较。
        await dispatcher.executeTool(name: 'Set', input: {'mode': 'normal'});
        expect(
          (await round()).single.content,
          contains('test-agent@work:second'),
        );

        await host.setEnabled('test.prompt', false);
        expect(await round(), isEmpty);
        expect(inner.requests, 13);
      } finally {
        await host.dispose();
        await database.close();
      }
    },
  );

  test(
    'system prompt replaces matching modes once per run and conflicts apply none',
    () async {
      final database = await _database();
      final persona = plugin('test.persona', """
var __revericPlugin={apply(setup){
setup.prompts.system({id:'persona',modes:['roleplay','theater'],handler:async context=>{
 if(context.request.agentId==='skip'){return null;}
 const version=await context.storage.get('version');
 return version==='none'?null:'persona '+context.request.agentId+' '+context.request.mode+' v'+version;
}});
$setTool
}};
""");
      var packages = [persona];
      PluginHostService build() => PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => packages,
      );
      var host = build();
      try {
        await host.start();
        expect(host.statuses.single.state, 'available');
        final chat = PluginAgentToolDispatcher(
          inner: RequestInner(),
          host: host,
          sessionId: 'session',
          agentId: 'chat',
          scope: (workId: 'work', mode: 'chat'),
        );
        final roleplay = PluginAgentToolDispatcher(
          inner: RequestInner(),
          host: host,
          sessionId: 'session',
          agentId: 'alice',
          scope: (workId: 'work', mode: 'roleplay'),
        );
        await roleplay.executeTool(name: 'Set', input: {'version': '1'});
        await chat.prepareRequest(runStart: true);
        expect(chat.systemPromptOverride, isNull);
        await roleplay.prepareRequest(runStart: true);
        expect(roleplay.systemPromptOverride, 'persona alice roleplay v1');
        expect(roleplay.requestSystemPrompt, 'MCP summary');
        // 插件按 agentId 选择注入对象，返回 null 的 Agent 保留默认 prompt。
        final skipped = PluginAgentToolDispatcher(
          inner: RequestInner(),
          host: host,
          sessionId: 'session',
          agentId: 'skip',
          scope: (workId: 'work', mode: 'roleplay'),
        );
        await skipped.prepareRequest(runStart: true);
        expect(skipped.systemPromptOverride, isNull);
        await roleplay.executeTool(name: 'Set', input: {'version': '2'});
        // 同一 run 内的工具轮保持 run 开头的结果。
        await roleplay.prepareRequest(runStart: false);
        expect(roleplay.systemPromptOverride, 'persona alice roleplay v1');
        await roleplay.prepareRequest(runStart: true);
        expect(roleplay.systemPromptOverride, 'persona alice roleplay v2');
        await roleplay.executeTool(name: 'Set', input: {'version': 'none'});
        await roleplay.prepareRequest(runStart: true);
        expect(roleplay.systemPromptOverride, isNull);
        await host.dispose();

        packages = [
          persona,
          plugin('test.rival', """
var __revericPlugin={apply(setup){
setup.prompts.system({id:'rival',modes:['theater'],handler:async()=>'rival'});
}};
"""),
          plugin('test.invalid', """
var __revericPlugin={apply(setup){
setup.prompts.system({id:'bad',modes:['unknown'],handler:async()=>'bad'});
}};
"""),
        ];
        host = build();
        await host.start();
        final states = {
          for (final status in host.statuses) status.id: status.state,
        };
        expect(states['test.persona'], 'available');
        expect(states['test.rival'], 'available');
        expect(states['test.invalid'], isNot('available'));
        final theater = PluginAgentToolDispatcher(
          inner: RequestInner(),
          host: host,
          sessionId: 'session',
          agentId: 'bob',
          scope: (workId: 'work', mode: 'theater'),
        );
        await theater.prepareRequest(runStart: true);
        expect(theater.systemPromptOverride, isNull);
        for (final id in ['test.persona', 'test.rival']) {
          expect(
            host.statuses
                .firstWhere((status) => status.id == id)
                .promptDiagnostic
                ?.code,
            'prompt_conflict',
          );
        }
        await host.setEnabled('test.rival', false);
        await theater.prepareRequest(runStart: true);
        expect(theater.systemPromptOverride, isNull); // version 仍为 none
        expect(
          host.statuses
              .firstWhere((status) => status.id == 'test.persona')
              .promptDiagnostic,
          isNull,
        );
      } finally {
        await host.dispose();
        await database.close();
      }
    },
  );
}
