// 职责: 验证子运行的真实工具管理器、HTTP 与跨作品租约不受父资源释放和事件屏蔽影响。
// 关联文件:
//   lib/shared/services/ai/chat.dart
//   lib/shared/services/ai/spawn_agent_handler.dart
//   lib/shared/services/ai/ai_http_client_lease.dart
//   lib/shared/services/ai/tools.dart

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/ai/ai_http_client_lease.dart';
import 'package:reveric/shared/services/ai/ai_service_config.dart';
import 'package:reveric/shared/services/ai/chat.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/spawn_agent_handler.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  late AppDatabase appDb;
  late NovelContentDatabase novelDb;
  late NovelContentService content;
  late WorkingOverlayService overlay;
  late AiProvider config;
  late AiHttpClientRegistry registry;
  late _RecordingHttpClient httpClient;
  final clients = <AiClient>[];
  final resources = <SpawnAgentResources>[];
  final leases = <AiHttpClientLease>[];

  setUp(() {
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    novelDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    content = NovelContentService(novelDb);
    overlay = WorkingOverlayService(
      novelDb,
      content,
      novelActionsService: NovelActionsService(appDb),
    );
    config = _provider();
    httpClient = _RecordingHttpClient();
    registry = AiHttpClientRegistry(
      clientFactory: (provider) =>
          provider.id == config.id ? httpClient : _RecordingHttpClient(),
    );
  });

  tearDown(() async {
    for (final child in resources) {
      child.release();
    }
    for (final parent in clients) {
      parent.dispose();
    }
    for (final lease in leases) {
      lease.release();
    }
    resources.clear();
    clients.clear();
    leases.clear();
    await novelDb.close();
    await appDb.close();
  });

  Future<AiClient> parent({
    AiNovelReader? reader,
    CrossWorkAccess? access,
    AiToolEventCallback? started,
    AiToolEventCallback? finished,
  }) async {
    final lease = registry.acquire(config);
    leases.add(lease);
    final client = AiClient.fromConfig(
      AiServiceConfig(
        provider: config,
        chatModel: 'model',
        novelContentService: content,
        workingOverlayService: overlay,
        novelReader: reader,
        workId: 'current',
        sessionId: 'parent',
        sourceSessionId: 'parent',
        crossWorkAccess: access,
        providerReader: appDb.aiProviderDao.getAll,
        onToolStarted: started,
        onToolFinished: finished,
      ),
      httpClient: lease.client,
    );
    clients.add(client);
    await client.initialize();
    return client;
  }

  Future<SpawnAgentResources> child(
    AiClient parent, {
    String id = 'child',
  }) async {
    final resource = await parent.createSubAgentResources(
      config: config,
      model: 'model',
      subSessionId: id,
      sourceSessionId: 'parent',
      httpLease: registry.acquire(config),
      traceHeadersProvider: () => {'x-session-id': id},
    );
    resources.add(resource);
    return resource;
  }

  test('child requires media capability for inherited style queries', () async {
    final client = await parent();
    final canvas = ProductionCanvasService(
      StoryboardService(novelDb),
      MediaLibraryService(
        appDb,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      ),
      'current',
    );
    client.toolManager!.productionStyleServiceBuilder = () async => canvas;
    final operations = ToolOperationManager(
      ownerSessionId: 'parent',
      registry: ToolOperationRegistry(),
      gate: () => throw StateError('No permission check expected'),
      onChanged: (_) {},
      onRecord: (_) {},
    );
    addTearDown(operations.dispose);
    client.toolManager!.operationHost = ToolOperationHost(operations);
    final resource = await child(client);
    client.toolManager!.operationHost = ToolOperationHost(
      operations,
      media: false,
    );
    final withoutMedia = await child(client, id: 'child-without-media');
    client.dispose();
    final result = await resource.toolManager.executeTool(
      name: 'Run',
      input: {
        'command': 'styles',
        'subcommand': 'read',
        'options': {'style_id': 'preset:pixel-art'},
      },
    );
    expect(result['ok'], isTrue, reason: '$result');
    expect(result['id'], 'preset:pixel-art');
    expect(result['before'], isNotEmpty);
    final unavailable = await withoutMedia.toolManager.executeTool(
      name: 'Run',
      input: {
        'command': 'styles',
        'subcommand': 'read',
        'options': {'style_id': 'preset:pixel-art'},
      },
    );
    expect(unavailable['ok'], isFalse);
    expect(unavailable['output'], contains('unknown command: styles'));
  });

  test(
    'parent and child tools share live global provider configuration',
    () async {
      await appDb.aiProviderDao.upsert(config);
      final client = await parent();
      final operations = ToolOperationManager(
        ownerSessionId: 'parent',
        registry: ToolOperationRegistry(),
        gate: () => throw StateError('No permission check expected'),
        onChanged: (_) {},
        onRecord: (_) {},
      );
      addTearDown(operations.dispose);
      client.toolManager!.operationHost = ToolOperationHost(operations);
      final resource = await child(client);
      for (final tools in [client.toolManager!, resource.toolManager]) {
        final result = await tools.executeTool(
          name: 'Run',
          input: {'command': 'providers', 'subcommand': 'list'},
        );
        expect(result['entries'], hasLength(1));
        expect(result['entries'][0]['id'], config.id);
        expect(result['entries'][0].containsKey('apiKey'), false);
      }
      await appDb.aiProviderDao.upsert(config.copyWith(enabled: false));
      final updated = await resource.toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'providers',
          'subcommand': 'list',
          'options': {'enabled': true},
        },
      );
      expect(updated['entries'], isEmpty);
    },
  );

  for (final parentFinishesFirst in [true, false]) {
    test(
      'overlapping tools keep parent events paired, parent finishes first=$parentFinishesFirst',
      () async {
        final entered = [Completer<void>(), Completer<void>()];
        final finish = [Completer<void>(), Completer<void>()];
        var reads = 0;
        var active = 0;
        final events = <String>[];
        final client = await parent(
          reader: () async {
            final index = reads++;
            entered[index].complete();
            await finish[index].future;
            return {'title': 'title'};
          },
          started: (id, name, input, result, error) {
            active++;
            events.add('start:$id');
          },
          finished: (id, name, input, result, error) {
            active--;
            events.add('end:$id');
          },
        );
        final resource = await child(client);
        expect(resource.client, isNot(same(client.providerClient)));
        expect(resource.toolManager, isNot(same(client.toolManager)));
        final mainTool = client.toolManager!.executeTool(
          name: 'Read',
          input: {'path': '/profile/title'},
          callId: 'parent_tool',
        );
        await entered[0].future;
        final childTool = resource.toolManager.executeTool(
          name: 'Read',
          input: {'path': '/profile/title'},
          callId: 'child_tool',
          emitEvents: false,
        );
        await entered[1].future;
        expect(active, 1);
        final first = parentFinishesFirst ? 0 : 1;
        finish[first].complete();
        await (parentFinishesFirst ? mainTool : childTool);
        expect(active, parentFinishesFirst ? 0 : 1);
        finish[1 - first].complete();
        expect((await mainTool).containsKey('error'), isFalse);
        expect((await childTool).containsKey('error'), isFalse);
        expect(events, ['start:parent_tool', 'end:parent_tool']);
        expect(active, 0);
      },
    );
  }

  test(
    'parent disposal preserves child reads, writes, sibling and cross-work leases',
    () async {
      final access = _CrossWorkAccess(content);
      final client = await parent(access: access);
      final first = await child(client);
      final second = await child(client, id: 'second');
      final chapterId = await content.createChapter(
        siblingOrder: 1,
        title: 'before',
      );
      for (final manager in [
        client.toolManager!,
        first.toolManager,
        second.toolManager,
      ]) {
        final result = await manager.executeTool(
          name: 'Read',
          input: {'path': '/works/other/profile/title'},
        );
        expect(result.containsKey('error'), isFalse);
      }
      expect(access.acquires, 3);
      client.dispose();
      leases.single.release();
      await Future<void>.delayed(Duration.zero);
      expect(registry.debugRefCountFor(config), 2);
      expect(httpClient.closes, 0);
      expect(access.releases, 1);
      final context = ToolExecutionContext(
        sessionId: 'child',
        sourceSessionId: 'parent',
        sourceTurnId: 'turn',
      );
      final write = await first.toolManager.executeTool(
        name: 'Write',
        input: {'path': '/chapters/$chapterId/title', 'value': 'after'},
        context: context,
      );
      expect(write.containsKey('error'), isFalse);
      expect((await content.getChapterById(chapterId))?.title, 'after');
      final read = await first.toolManager.executeTool(
        name: 'Read',
        input: {'path': '/works/other/profile/title'},
      );
      expect(read.containsKey('error'), isFalse);
      first.release();
      first.release();
      await Future<void>.delayed(Duration.zero);
      expect(access.releases, 2);
      expect(registry.debugRefCountFor(config), 1);
      expect(httpClient.closes, 0);
      final siblingRead = await second.toolManager.executeTool(
        name: 'Read',
        input: {'path': '/works/other/profile/title'},
      );
      expect(siblingRead.containsKey('error'), isFalse);
      second.release();
      await Future<void>.delayed(Duration.zero);
      expect(access.releases, 3);
      expect(registry.debugRefCountFor(config), 0);
      expect(httpClient.closes, 1);
    },
  );

  test(
    'client initialization failure releases the acquired HTTP lease',
    () async {
      final client = await parent();
      final unavailable = config.copyWith(
        id: 'video-only-provider',
        type: 'metaso',
      );
      final lease = registry.acquire(unavailable);
      await expectLater(
        client.createSubAgentResources(
          config: unavailable,
          model: 'unavailable-test-model',
          subSessionId: 'child',
          sourceSessionId: 'parent',
          httpLease: lease,
          traceHeadersProvider: () => {},
        ),
        throwsUnsupportedError,
      );
      expect(registry.debugRefCountFor(unavailable), 0);
      expect(registry.debugRefCountFor(config), 1);
    },
  );
}

class _CrossWorkAccess implements CrossWorkAccess {
  _CrossWorkAccess(this.service);
  final NovelContentService service;
  int acquires = 0;
  int releases = 0;
  final descriptor = const CrossWorkDescriptor(
    workId: 'other',
    title: 'Other',
    databasePath: '/other.sqlite',
    contentKind: 'novel',
    novelMetadata: {'title': 'Other'},
  );
  @override
  String get currentWorkId => 'current';
  @override
  Future<List<CrossWorkDescriptor>> listWorks() async => [descriptor];
  @override
  Future<CrossWorkLease> acquire(String workId) async {
    acquires++;
    return CrossWorkLease(
      work: descriptor,
      service: service,
      release: () => releases++,
    );
  }
}

AiProvider _provider() => AiProvider(
  audioModels: const [],
  videoModels: const [],
  id: 'test',
  name: 'Test',
  builtin: false,
  type: 'openai',
  enabled: true,
  apiKey: 'test-key',
  baseUrl: 'https://example.invalid/v1',
  models: const ['model'],
  imageModels: const [],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);

class _RecordingHttpClient extends http.BaseClient {
  int closes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();
  @override
  void close() {
    closes++;
  }
}
