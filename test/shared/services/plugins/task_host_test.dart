// 职责: 通过真实 JS 任务与工具验证 Host AI 权限、用量累计与更新/撤权取消。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/tasks.dart
//   lib/shared/services/plugins/ai.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/installer.dart';
import 'package:reveric/shared/services/plugins/package_archive.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import 'package:reveric/shared/services/plugins/ai.dart';

const code = """
var __revericPlugin={apply(setup){setup.tasks.register('organize',async(context)=>{
const mode=(await context.storage.get('mode'))||'normal';
let response;
for(let i=0;i<(mode==='repeat'?3:1);i++) response=await context.ai.generateText({system:'system',prompt:mode,maxOutputTokens:50});
await context.storage.set('output',response.text);
return {summary:'Finished '+context.runId};
});
setup.tools.register({name:'AiEcho',description:'Echo',inputSchema:{type:'object'},handler:async(input,context)=>{
const models=await context.ai.listModels();
const response=await context.ai.generateText({system:'s',prompt:'tool',providerId:models[0].providerId,model:models[0].model,reasoningEffort:'low'});
return {models:models.length,...response};
}});}};
""";
Map<String, dynamic> manifest(String version) => {
  'id': 'test.tasks',
  'name': 'Tasks',
  'version': version,
  'pluginApiVersion': '^1',
  'tasks': {
    'organize': {'title': 'Organize', 'intervalMinutes': 60},
  },
  'main': 'dist/index.js',
  'defaultEnabled': true,
  'permissions': ['ai.generateText'],
};
Future<void> until(FutureOr<bool> Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!await condition()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Host task condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
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
    'real task and tool AI calls record usage and cancel on permission revoke/update',
    () async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      final root = await Directory.systemTemp.createTemp('plugin-task-host-');
      final folder = await Directory(
        '${root.path}/plugins/test.tasks/1.0.0/dist',
      ).create(recursive: true);
      await File('${folder.path}/index.js').writeAsString(code);
      await File(
        '${folder.parent.path}/plugin.json',
      ).writeAsString(jsonEncode(manifest('1.0.0')));
      final ai = _FakeAi();
      final calls = ai.calls;
      final host = PluginHostService(
        dao: database.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        applicationSupport: () async => root,
        packages: () async => [
          PluginPackage(
            'plugins/test.tasks/1.0.0',
            PluginManifest.fromJson(manifest('1.0.0')),
            code,
            source: 'local',
          ),
        ],
        ai: ai,
      );
      Future<void> mode(String value) => database.pluginDao.setPluginData(
        'test.tasks',
        'mode',
        jsonEncode(value),
      );
      Future<PluginTask> row() async =>
          (await database.pluginTaskDao.get('test.tasks', 'organize'))!;
      Future<void> finished(String status) => until(
        () async =>
            !host.tasks.pending('test.tasks', 'organize') &&
            (await row()).lastStatus == status,
      );
      try {
        await host.start();
        expect(host.statuses.single.state, 'needs_permission');
        await host.confirmPermissions('test.tasks');
        await host.tasks.runNow('test.tasks', 'organize');
        await finished('success');
        expect(calls, hasLength(1));
        expect(calls.single.maxOutputTokens, 50);
        expect(calls.single.pluginId, 'test.tasks');
        expect(calls.single.label, 'task:organize');
        expect(calls.single.runId, (await row()).runId);
        expect((await row()).lastUsage?['input_tokens'], 10);
        expect((await row()).lastUsage?['calls'], 1);
        expect(
          jsonDecode(
            (await database.pluginDao.getStorage('test.tasks', 'data.output'))!,
          ),
          'AI suggestion',
        );
        await mode('repeat');
        await host.tasks.runNow('test.tasks', 'organize');
        await finished('success');
        expect(calls, hasLength(4));
        expect((await row()).lastUsage?['calls'], 3);
        expect((await row()).lastUsage?['input_tokens'], 30);
        final tool = await host.execute('AiEcho', {});
        expect(tool['models'], 1);
        expect(tool['text'], 'AI suggestion');
        expect(tool['finishReason'], 'stop');
        expect(tool['providerId'], 'mock');
        expect(calls.last.label, 'tool:AiEcho');
        expect(calls.last.runId, isNull);
        expect(calls.last.model, 'mock-model');
        expect(calls.last.reasoningEffort, 'low');
        await mode('wait');
        await host.tasks.runNow('test.tasks', 'organize');
        await until(() => ai.waiting != null);
        await host.revokePermissions('test.tasks');
        expect(ai.waiting!.isCancellationRequested, true);
        expect((await row()).lastStatus, 'cancelled');
        expect(host.statuses.single.state, 'needs_permission');
        await host.confirmPermissions('test.tasks');
        ai.waiting = null;
        await host.tasks.runNow('test.tasks', 'organize');
        await until(() => ai.waiting != null);
        final archive = Archive()
          ..addFile(
            ArchiveFile.string('plugin.json', jsonEncode(manifest('2.0.0'))),
          )
          ..addFile(ArchiveFile.string('dist/index.js', code));
        await PluginInstallOrchestrator().install(
          host: host,
          archive: PluginPackageArchive.decode(
            Uint8List.fromList(ZipEncoder().encode(archive)),
          ),
          grantedPermissions: {'ai.generateText'},
          temporaryRoot: root,
        );
        expect(ai.waiting!.isCancellationRequested, true);
        expect(host.statuses.single.manifest!.version, '2.0.0');
        expect((await row()).lastStatus, 'cancelled');
        await host.setForeground(false);
        await expectLater(
          host.tasks.runNow('test.tasks', 'organize'),
          throwsA(isA<PluginHostError>()),
        );
        await host.setForeground(true);
        await mode('normal');
        await host.tasks.runNow('test.tasks', 'organize');
        await finished('success');
      } finally {
        await host.dispose();
        await database.close();
        await root.delete(recursive: true);
      }
    },
  );
}

class _FakeAi implements PluginAiApi {
  final calls = <PluginAiRequest>[];
  AgentCancellationToken? waiting;

  @override
  List<Map<String, dynamic>> listModels() => [
    {'providerId': 'mock', 'model': 'mock-model'},
  ];

  @override
  Future<PluginAiResult> generate(
    PluginAiRequest request,
    AgentCancellationToken cancellation,
  ) {
    calls.add(request);
    if (request.prompt == 'wait') {
      waiting = cancellation;
      final gate = Completer<PluginAiResult>();
      cancellation.onCancel(
        () => gate.completeError(PluginHostError('cancelled', 'AI stopped')),
      );
      return gate.future;
    }
    return Future.value((
      text: 'AI suggestion',
      finishReason: 'stop',
      providerId: 'mock',
      model: 'mock-model',
      usage: <String, dynamic>{'input_tokens': 10, 'output_tokens': 4},
    ));
  }
}
