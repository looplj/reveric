// 职责: 通过真实 JS 任务验证 Host AI 权限、跨重试配额、用量与更新/撤权取消。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/tasks.dart
//   lib/shared/services/plugins/task_ai.dart
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
import 'package:reveric/shared/services/plugins/task_ai.dart';

const code = """
var __revericPlugin={apply(setup){setup.tasks.register('organize',async(context)=>{
const mode=(await context.storage.get('mode'))||'normal';
let response;
for(let i=0;i<(mode==='quota'?3:1);i++) response=await context.ai.generateText({system:'system',prompt:mode,maxOutputTokens:50});
await context.storage.set('output',response.text);
return {summary:'Finished '+context.runId};
});}};
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
    'real task runs persist usage, cap retries and cancel on permission revoke/update',
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
      final calls = <PluginTaskAiRequest>[];
      AgentCancellationToken? waiting;
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
        taskAi: (request, cancellation) async {
          calls.add(request);
          if (request.prompt == 'wait') {
            waiting = cancellation;
            final gate = Completer<PluginTaskAiResult>();
            cancellation.onCancel(
              () => gate.completeError(
                PluginHostError('cancelled', 'AI stopped'),
              ),
            );
            return gate.future;
          }
          return (
            text: 'AI suggestion',
            usage: {
              'input_tokens': 10,
              'output_tokens': 4,
              'model': 'mock',
              'providerId': 'mock',
            },
          );
        },
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
        expect((await row()).lastUsage?['input_tokens'], 10);
        expect((await row()).lastUsage?['calls'], 1);
        expect(
          jsonDecode(
            (await database.pluginDao.getStorage('test.tasks', 'data.output'))!,
          ),
          'AI suggestion',
        );
        await mode('quota');
        await host.tasks.runNow('test.tasks', 'organize');
        await finished('retrying');
        final quota = await row();
        expect(quota.lastErrorCode, 'rate_limited');
        expect(quota.lastUsage?['calls'], 2);
        expect(calls, hasLength(3));
        await database.pluginTaskDao.defer(
          quota,
          DateTime.now().subtract(const Duration(seconds: 1)),
          DateTime.now(),
        );
        await host.tasks.tick();
        await until(
          () async =>
              !host.tasks.pending('test.tasks', 'organize') &&
              (await row()).attempt == 2,
        );
        expect((await row()).runId, quota.runId);
        expect(calls, hasLength(3));
        await mode('wait');
        await host.tasks.runNow('test.tasks', 'organize');
        await until(() => waiting != null);
        await host.revokePermissions('test.tasks');
        expect(waiting!.isCancellationRequested, true);
        expect((await row()).lastStatus, 'cancelled');
        expect(host.statuses.single.state, 'needs_permission');
        await host.confirmPermissions('test.tasks');
        waiting = null;
        await host.tasks.runNow('test.tasks', 'organize');
        await until(() => waiting != null);
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
        expect(waiting!.isCancellationRequested, true);
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
