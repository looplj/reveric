// 职责: 验证插件业务数据的作品边界、版本冲突、历史和事务回滚。
// 关联文件:
//   lib/shared/services/plugins/data.dart
//   lib/shared/services/working_overlay.dart
import 'package:drift/native.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/services/plugins/data.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'host_test.dart' show FakeExecutor;

class _DataExecutor extends FakeExecutor {
  _DataExecutor(this.call, this.id);
  final PluginHostCall call;
  final String id;
  @override
  Future<Map<String, dynamic>> invoke(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String tool,
    Map<String, dynamic> input,
    String callId,
    AgentCancellationToken? cancellation, {
    Map<String, dynamic> request = const {},
  }) async =>
      Map<String, dynamic>.from(await call('chapters.get', {'id': id}) as Map);
}

void main() {
  late AppDatabase app;
  late NovelContentDatabase contentDb;
  late NovelContentService content;
  late WorkingOverlayService overlay;
  late PluginDataService data;
  late String chapter;
  setUp(() async {
    app = AppDatabase.forTest(NativeDatabase.memory());
    contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    content = NovelContentService(contentDb);
    overlay = WorkingOverlayService(
      contentDb,
      content,
      novelActionsService: NovelActionsService(app),
    );
    await app.novelDao.create(
      id: 'work',
      title: 'Work',
      description: '',
      contentDatabasePath: 'memory-work',
    );
    await app.aiChatSessionDao.upsert(
      id: 'session',
      novelId: 'work',
      title: 'Session',
    );
    data = PluginDataService(
      database: app,
      services: (_) => (content: content, overlay: overlay),
    );
    chapter = await content.createChapter(siblingOrder: 1, title: 'Original');
  });
  tearDown(() async {
    await contentDb.close();
    await app.close();
  });
  Future<Map<String, dynamic>> read(String resource, String id) async =>
      await data.call('$resource.get', {'id': id}, sessionId: 'session')
          as Map<String, dynamic>;
  Matcher code(String expected) => throwsA(
    isA<PluginHostError>().having((error) => error.code, 'code', expected),
  );

  test(
    'Host page scope reads a work without creating a chat session',
    () async {
      final value =
          await data.call(
                'chapters.get',
                {'id': chapter},
                sessionId: null,
                scopeWorkId: 'work',
              )
              as Map;
      expect(value['id'], chapter);
      expect(value['workId'], 'work');
      await expectLater(
        data.call('chapters.get', {'id': chapter}, sessionId: null),
        code('invalid_scope'),
      );
    },
  );

  test(
    'versioned update commits history and rejects stale overwrites',
    () async {
      final before = await read('chapters', chapter);
      final after =
          await data.call(
                'chapters.update',
                {
                  'id': chapter,
                  'expectedVersion': before['version'],
                  'patch': {'content': 'first'},
                },
                sessionId: 'session',
                executionContext: ToolExecutionContext(
                  sourceSessionId: 'session',
                  sourceTurnId: 'turn',
                ),
                toolName: 'UpdateChapter',
              )
              as Map;
      expect(after['content'], 'first');
      expect(after['version'], isNot(before['version']));
      expect(await contentDb.changeCommitDao.getAll(), isNotEmpty);
      final change = (await contentDb.workingChangeDao.getAll()).single;
      expect(change.source, workingChangeSourceAi);
      expect(change.sourceTurnId, 'turn');
      expect(change.toolName, 'UpdateChapter');
      await expectLater(
        data.call('chapters.update', {
          'id': chapter,
          'expectedVersion': before['version'],
          'patch': {'content': 'stale'},
        }, sessionId: 'session'),
        code('version_conflict'),
      );
      expect((await read('chapters', chapter))['content'], 'first');
    },
  );
  test('invalid later field rolls back earlier fields and history', () async {
    final id = await content.createCharacterProfile(name: 'Original');
    final before = await read('characters', id);
    await expectLater(
      data.call('characters.update', {
        'id': id,
        'expectedVersion': before['version'],
        'patch': {'name': 'Changed', 'role': 'invalid-role'},
      }, sessionId: 'session'),
      throwsArgumentError,
    );
    expect((await read('characters', id))['name'], 'Original');
    expect(await contentDb.workingChangeDao.getAll(), isEmpty);
  });
  test(
    'pending overlay prevents plugin from committing unrelated changes',
    () async {
      await overlay.stageTextChange(
        resourcePath: '/chapters/$chapter/content',
        resourceType: 'chapters',
        resourceId: chapter,
        field: 'content',
        oldText: '',
        newText: 'draft',
        source: workingChangeSourceAi,
      );
      final before = await read('chapters', chapter);
      await expectLater(
        data.call('chapters.update', {
          'id': chapter,
          'expectedVersion': before['version'],
          'patch': {'title': 'New'},
        }, sessionId: 'session'),
        code('draft_conflict'),
      );
      expect((await read('chapters', chapter))['title'], 'Original');
    },
  );
  test(
    'current-work operations reject forged scopes and absent sessions',
    () async {
      await expectLater(
        data.call('chapters.get', {'id': chapter}, sessionId: null),
        code('invalid_scope'),
      );
      await expectLater(
        data.call('chapters.get', {
          'id': chapter,
          'workId': 'other',
        }, sessionId: 'session'),
        code('invalid_scope'),
      );
      final result =
          await data.call('chapters.list', {'limit': 1}, sessionId: 'session')
              as Map;
      expect(result['items'], [
        {
          'id': chapter,
          'title': 'Original',
          'version': (await read('chapters', chapter))['version'],
          'order': 1,
        },
      ]);
      await expectLater(
        data.call('chapters.listAcrossWorks', {}, sessionId: 'session'),
        code('invalid_argument'),
      );
    },
  );
  test(
    'host checks both declaration and persisted grant for every call',
    () async {
      final manifest = PluginManifest.fromJson({
        'id': 'example.data',
        'name': 'Data',
        'version': '1.0.0',
        'pluginApiVersion': '^1',
        'main': 'dist/index.js',
        'defaultEnabled': true,
        'permissions': ['chapters.read'],
      });
      final host = PluginHostService(
        dao: app.pluginDao,
        data: data,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [PluginPackage('assets/data', manifest, '')],
        executorFactory: (call, stop) => _DataExecutor(call, chapter),
        platform: 'macos',
      );
      try {
        await host.start();
        expect(host.statuses.single.state, 'needs_permission');
        await host.confirmPermissions('example.data');
        expect(
          (await host.execute('WebSearch', {}, sessionId: 'session'))['title'],
          'Original',
        );
        await app.pluginDao.revokePermission('example.data', 'chapters.read');
        final result = await host.execute(
          'WebSearch',
          {},
          sessionId: 'session',
        );
        expect(result['ok'], false);
        expect(result['error_code'], 'permission_denied');
      } finally {
        await host.dispose();
      }
    },
  );
}
