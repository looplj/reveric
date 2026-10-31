// 职责: 用真实 fjs 验证插件桥接、注册生命周期、错误和资源终止。
// 关联文件:
//   lib/shared/services/plugins/runtime.dart
import 'dart:async';
import 'dart:io';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import 'package:reveric/shared/services/ai/codemode/runtime.dart';

final manifest = PluginManifest.fromJson({
  'id': 'test.plugin',
  'name': 'Test',
  'version': '1.0.0',
  'pluginApiVersion': '^1',
  'main': 'dist/index.js',
});
String plugin(String handler, {String apply = ''}) =>
    "var __revericPlugin={async apply(setup){$apply setup.tools.register({name:'Echo',description:'Echo input',inputSchema:{type:'object'},handler:async(input,context)=>{$handler}});}};";
void main() {
  setUpAll(() async {
    final path = Platform.environment['FJS_PROBE_LIBRARY'];
    if (path == null) {
      throw StateError('Set FJS_PROBE_LIBRARY to built native fjs');
    }
    await LibFjs.init(externalLibrary: ExternalLibrary.open(path));
  });
  PluginRuntime runtime({
    PluginHostCall? call,
    Duration timeout = const Duration(seconds: 60),
  }) => PluginRuntime(
    hostCall: call ?? (method, args) async => args,
    callTimeout: timeout,
  );
  test(
    'codemode and plugins share initialization without sharing execution',
    () async {
      final result = await FjsRuntime().run(
        code: 'return 7;',
        tools: [],
        executeTool: (name, input) async => {},
      );
      expect(result.ok, true);
      expect(result.returnValue, 7);
      expect(
        await runtime().activate(manifest, plugin('return {};')),
        hasLength(1),
      );
    },
  );
  test('manifest pages bind exactly their declared handlers', () async {
    final uiManifest = PluginManifest.fromJson({
      ...manifest.json,
      'pages': {
        'counter': {
          'title': 'Counter',
          'location': 'home.plugin',
          'protocol': 'reveric-tsx-v1',
          'source': 'dist/counter.js',
        },
        'report': {
          'title': 'Report',
          'location': 'home.plugin',
          'protocol': 'reveric-ui-v1',
          'source': 'views/report.json',
          'actions': ['load'],
          'onMount': 'load',
        },
      },
    });
    final viewCode = plugin(
      'return {};',
      apply: """
      setup.pages.registerAction('report','load',async()=>[]);
    """,
    );
    final definitions = await runtime().activate(uiManifest, viewCode);
    expect(definitions, hasLength(3));
    expect(definitions[2]['view']['actions'], ['load']);
    expect(
      await runtime().invoke(
        uiManifest,
        viewCode,
        definitions,
        'Echo',
        {},
        'call',
        null,
      ),
      {},
    );
    await expectLater(
      runtime().activate(manifest, viewCode),
      throwsA(isA<PluginExecutionError>()),
    );
    await expectLater(
      runtime().invoke(
        uiManifest,
        viewCode.replaceFirst("'load'", "'changed'"),
        definitions,
        'Echo',
        {},
        'call',
        null,
      ),
      throwsA(isA<PluginExecutionError>()),
    );
    await expectLater(
      runtime().activate(
        uiManifest,
        viewCode.replaceFirst(
          "setup.pages.registerAction('report','load',async()=>[]);",
          '',
        ),
      ),
      throwsA(isA<PluginExecutionError>()),
    );
  });
  test(
    'A2UI actions run fresh, preserve scope and reject surface creation',
    () async {
      final uiManifest = PluginManifest.fromJson({
        ...manifest.json,
        'pages': {
          'report': {
            'title': 'Report',
            'location': 'home.plugin',
            'protocol': 'reveric-ui-v1',
            'source': 'report.json',
            'actions': ['load', 'bad'],
          },
        },
      });
      const code = """
var counter = 0;
var __revericPlugin={apply(setup){setup.pages.registerAction('report','load',async (data,event,context)=>[{version:'v1.0',updateDataModel:{path:'/',value:{count:++counter,workId:context.page.workId,input:data}}}]);
 setup.pages.registerAction('report','bad',async()=>[{version:'v1.0',createSurface:{surfaceId:'forged'}}]);
}};
""";
      final defs = await runtime().activate(uiManifest, code);
      for (var i = 0; i < 2; i++) {
        final result = await runtime().runViewAction(
          uiManifest,
          code,
          defs,
          'report',
          'load',
          {
            'data': {'text': 'draft'},
            'event': {},
            'page': {
              'viewId': 'report',
              'instanceId': 'page',
              'workId': 'fixed',
            },
          },
          'call',
          null,
        );
        expect(result.single['updateDataModel']['value'], {
          'count': 1,
          'workId': 'fixed',
          'input': {'text': 'draft'},
        });
      }
      await expectLater(
        runtime().runViewAction(
          uiManifest,
          code,
          defs,
          'report',
          'bad',
          {'page': {}},
          'call',
          null,
        ),
        throwsA(isA<PluginExecutionError>()),
      );
      await expectLater(
        runtime().runViewAction(
          uiManifest,
          code,
          defs,
          'report',
          'missing',
          {},
          'call',
          null,
        ),
        throwsA(isA<PluginExecutionError>()),
      );
    },
  );
  test(
    'task and page declarations reject missing, extra and duplicate handlers',
    () async {
      final declared = PluginManifest.fromJson({
        ...manifest.json,
        'tasks': {
          'job': {'title': 'Job', 'intervalMinutes': 15},
        },
        'pages': {
          'report': {
            'title': 'Report',
            'location': 'home.plugin',
            'protocol': 'reveric-ui-v1',
            'source': 'report.json',
            'actions': ['load'],
          },
        },
      });
      const task = "setup.tasks.register('job', async()=>{});";
      const page = "setup.pages.registerAction('report','load',async()=>[]);";
      final valid = plugin('return {};', apply: task + page);
      expect(await runtime().activate(declared, valid), hasLength(3));
      for (final registrations in [
        '',
        task,
        page,
        task + task + page,
        task + page + page,
        "$task${page}setup.tasks.register('extra',async()=>{});",
        "$task${page}setup.pages.registerAction('report','extra',async()=>[]);",
        "$task${page}setup.pages.registerAction('missing','load',async()=>[]);",
      ]) {
        await expectLater(
          runtime().activate(
            declared,
            plugin('return {};', apply: registrations),
          ),
          throwsA(isA<PluginExecutionError>()),
        );
      }
    },
  );
  test('fresh runtimes register, bridge promises and return JSON', () async {
    final code = plugin(
      "return await context.http.fetch('https://example.com');",
    );
    final definitions = await runtime().activate(manifest, code);
    expect(definitions.single['name'], 'Echo');
    final result = await runtime(
      call: (m, a) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return {'body': '中文'};
      },
    ).invoke(manifest, code, definitions, 'Echo', {}, 'call', null);
    expect(result, {'body': '中文'});
  });
  test('apply Host calls and registration after apply fail', () async {
    await expectLater(
      runtime().activate(
        manifest,
        plugin(
          'return {};',
          apply: "await setup.http.fetch('https://example.com');",
        ),
      ),
      throwsA(isA<PluginExecutionError>()),
    );
    final code = plugin("setup.tools.register({name:'Late'}); return {};");
    final defs = await runtime().activate(manifest, code);
    await expectLater(
      runtime().invoke(manifest, code, defs, 'Echo', {}, '', null),
      throwsA(isA<PluginExecutionError>()),
    );
  });
  test('Host blocks direct bridge writes during apply', () async {
    final calls = <String>[];
    final executor = runtime(
      call: (method, args) async {
        calls.add(method);
        return null;
      },
    );
    const write = "await context.storage.set('probe', true); return {};";
    final definitions = await executor.activate(manifest, plugin(write));
    await expectLater(
      executor.invoke(
        manifest,
        plugin(
          write,
          apply: """
await fjs.bridge_call(JSON.stringify({kind:'call', method:'storage.set', args:{key:'probe', value:true}}));
""",
        ),
        definitions,
        'Echo',
        {},
        'call',
        null,
      ),
      throwsA(isA<PluginExecutionError>()),
    );
    expect(calls, isEmpty);
    await executor.invoke(
      manifest,
      plugin(write),
      definitions,
      'Echo',
      {},
      'call',
      null,
    );
    expect(calls, ['storage.set']);
  });
  test(
    'Host validates snapshots even if plugin bypasses JS comparison',
    () async {
      final calls = <String>[];
      final executor = runtime(
        call: (method, args) async {
          calls.add(method);
          return null;
        },
      );
      final code = plugin(
        "await context.storage.set('probe', true); return {};",
      );
      final definitions = await executor.activate(manifest, code);
      final changed = "function __same() { return true; }\n$code";
      await expectLater(
        executor.invoke(
          manifest,
          changed,
          [
            {...definitions.single, 'description': 'Changed'},
          ],
          'Echo',
          {},
          'call',
          null,
        ),
        throwsA(
          isA<PluginExecutionError>().having(
            (error) => error.code,
            'code',
            'plugin_registration_mismatch',
          ),
        ),
      );
      expect(calls, isEmpty);
      await executor.invoke(
        manifest,
        changed,
        definitions,
        'Echo',
        {},
        'call',
        null,
      );
      expect(calls, ['storage.set']);
    },
  );
  test(
    'registration mismatch, thrown host errors and invalid result remain diagnostic',
    () async {
      final code = plugin('return {};');
      final defs = await runtime().activate(manifest, code);
      await expectLater(
        runtime().invoke(
          manifest,
          code,
          [
            {...defs.single, 'description': 'changed'},
          ],
          'Echo',
          {},
          '',
          null,
        ),
        throwsA(
          isA<PluginExecutionError>().having(
            (e) => e.code,
            'code',
            'plugin_registration_mismatch',
          ),
        ),
      );
      for (final handler in [
        'return 42;',
        "return {body:'x'.repeat(270000)};",
      ]) {
        final bad = plugin(handler);
        await expectLater(
          runtime().invoke(manifest, bad, defs, 'Echo', {}, '', null),
          throwsA(
            isA<PluginExecutionError>().having(
              (e) => e.code,
              'code',
              'plugin_invalid_result',
            ),
          ),
        );
      }
      for (final (thrown, expected) in [
        (
          "throw Object.assign(new Error('Quota used'),{code:'quota_exceeded'});",
          'quota_exceeded',
        ),
        (
          "throw Object.assign(new Error('Bad'),{code:'Not A Code'});",
          'plugin_error',
        ),
      ]) {
        await expectLater(
          runtime().invoke(
            manifest,
            plugin(thrown),
            defs,
            'Echo',
            {},
            '',
            null,
          ),
          throwsA(
            isA<PluginExecutionError>().having((e) => e.code, 'code', expected),
          ),
        );
      }
      final net = plugin(
        "return await context.http.fetch('https://example.com');",
      );
      await expectLater(
        runtime(
          call: (m, a) async =>
              throw PluginHostError('network', 'DNS unavailable'),
        ).invoke(manifest, net, defs, 'Echo', {}, '', null),
        throwsA(
          isA<PluginExecutionError>()
              .having((e) => e.code, 'code', 'network')
              .having((e) => e.message, 'message', contains('DNS unavailable')),
        ),
      );
    },
  );
  test(
    'timeout and cancellation close runtime; subsequent call succeeds',
    () async {
      final code = plugin('await new Promise(()=>{}); return {};');
      final defs = await runtime().activate(manifest, code);
      await expectLater(
        runtime(
          timeout: const Duration(milliseconds: 100),
        ).invoke(manifest, code, defs, 'Echo', {}, '', null),
        throwsA(
          isA<PluginExecutionError>().having(
            (e) => e.code,
            'code',
            'plugin_timeout',
          ),
        ),
      );
      final controller = AgentCancellationController();
      final future = runtime().invoke(
        manifest,
        code,
        defs,
        'Echo',
        {},
        '',
        controller.token,
      );
      Timer(const Duration(milliseconds: 100), controller.cancel);
      await expectLater(
        future,
        throwsA(
          isA<PluginExecutionError>().having(
            (e) => e.code,
            'code',
            'user_cancelled',
          ),
        ),
      );
      expect(
        await runtime().invoke(
          manifest,
          plugin('return {ok:true};'),
          defs,
          'Echo',
          {},
          '',
          null,
        ),
        {'ok': true},
      );
    },
  );
  test('memory exhaustion closes runtime', () async {
    final code = plugin(
      "const a=[]; while(true) {a.push(new Array(100000).fill('abcdefgh'));}",
    );
    final defs = await runtime().activate(manifest, code);
    await expectLater(
      runtime().invoke(manifest, code, defs, 'Echo', {}, '', null),
      throwsA(
        isA<PluginExecutionError>().having(
          (e) => e.code,
          'code',
          'plugin_memory_limit',
        ),
      ),
    );
  });
}
