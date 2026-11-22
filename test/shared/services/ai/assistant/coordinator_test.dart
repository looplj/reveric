// 职责: 验证 AssistantCoordinator 端到端编排 — handler 注册、入站分发、兜底文案路径
// 关联文件:
//   lib/shared/services/ai/assistant/coordinator.dart
//   lib/shared/services/remote/remote_bridge_service.dart
//   lib/shared/database/daos/assistant_session_dao.dart
//   lib/shared/services/ai/prompts/ai_prompt_service.dart
//
// 说明：不验证真实 LLM turn（需 ProviderClient + HTTP），只覆盖 coordinator 的
// wiring 与失败兜底分支——这是 PR-3「onInboundMessage → Assistant turn → text block
// 回微信」中可自动验证的部分；剩余 happy-path 由方案 §6 的手动测试覆盖。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/assistant/coordinator.dart';
import 'package:reveric/shared/services/ai/usage_service.dart';
import 'package:reveric/shared/services/ai/prompts/ai_prompt_service.dart';
import 'package:reveric/shared/services/remote/channel_adapter.dart';
import 'package:reveric/shared/services/remote/remote_bridge_service.dart';

const _testChannelType = 'wechat';
const _testChatId = 'wxid_alice';
const _testModel = 'fake-chat';

final _fakeProvider = AiProvider(
  asrModels: const [],
  audioModels: const [],
  videoModels: const [],
  id: 'fake_provider',
  name: 'Fake Provider',
  builtin: false,
  type: 'openai',
  enabled: true,
  apiKey: 'test-api-key',
  baseUrl: 'https://example.invalid/v1',
  models: const [_testModel],
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

InboundMessage _inbound({
  String text = '你好',
  String chatId = _testChatId,
  String? displayName,
}) {
  return InboundMessage(
    messageId: 'm_${DateTime.now().microsecondsSinceEpoch}',
    address: ChannelAddress(
      channelType: _testChannelType,
      chatId: chatId,
      displayName: displayName,
    ),
    text: text,
    timestamp: DateTime.now().millisecondsSinceEpoch,
  );
}

/// 重写 [RemoteBridgeService] 的出站/通知方法，记录调用而不触达 adapter。
class _RecordingBridge extends RemoteBridgeService {
  _RecordingBridge();

  final List<(String chatId, String text)> sentMessages = [];
  final List<String> processingStartCalls = [];
  final List<String> processingEndCalls = [];

  @override
  Future<bool> sendToUser(String chatId, String text) async {
    sentMessages.add((chatId, text));
    return true;
  }

  @override
  Future<void> notifyProcessingStart(String chatId) async {
    processingStartCalls.add(chatId);
  }

  @override
  Future<void> notifyProcessingEnd(String chatId) async {
    processingEndCalls.add(chatId);
  }
}

Future<Map<String, dynamic>> _stubStartJob(
  String novelId,
  String seed, {
  required String chatId,
  required String channelType,
}) async => {'ok': false, 'error': 'start job stub'};

Future<Map<String, dynamic>> _stubJobStatus(
  String jobId, {
  required String chatId,
  required String channelType,
}) async => {'ok': false, 'error': 'job status stub'};

Future<Map<String, dynamic>> _stubSendToJob(
  String jobId,
  String text, {
  required String chatId,
  required String channelType,
}) async => {'ok': false, 'error': 'send to job stub'};

Future<Map<String, dynamic>> _stubCreateNovel(
  Map<String, dynamic> novel,
) async => {'ok': false, 'error': 'create novel stub'};

Future<Map<String, dynamic>> _stubEditNovel(
  String novelId,
  Map<String, dynamic> fields,
) async => {'ok': false, 'error': 'edit novel stub'};

Future<Map<String, dynamic>> _stubListChapters(String novelId) async => {
  'ok': false,
  'error': 'list chapters stub',
};

void main() {
  late AppDatabase db;
  late _RecordingBridge bridge;
  late AssistantCoordinator coordinator;
  late List<String> capturedSessionIds;

  setUp(() {
    db = AppDatabase.forTest(NativeDatabase.memory());
    bridge = _RecordingBridge();
    capturedSessionIds = <String>[];
  });

  tearDown(() async {
    coordinator.stop();
    bridge.dispose();
    await db.close();
  });

  group('AssistantCoordinator.start/stop', () {
    test('start registers inbound handler on bridge', () {
      coordinator = AssistantCoordinator(
        bridge: bridge,
        dao: db.assistantSessionDao,
        inboxDao: db.assistantInboxDao,
        aiPromptService: AiPromptService(),
        usageService: UsageService(appDatabase: db),
        clientFactory:
            ({
              required String providerId,
              required String model,
              required String sessionId,
            }) async {
              throw StateError('should not be called');
            },
        readAiSettings: () => const AiSettings(),
        listNovels: () async => const [],
        startJob: _stubStartJob,
        jobStatus: _stubJobStatus,
        sendToJob: _stubSendToJob,
        createNovel: _stubCreateNovel,
        editNovel: _stubEditNovel,
        listChapters: _stubListChapters,
      );
      expect(bridge.onInboundMessage, isNull);

      coordinator.start();
      expect(bridge.onInboundMessage, isNotNull);

      // 重复 start 是 no-op（不抛错、不重复注册）
      coordinator.start();
      coordinator.start();
    });

    test('stop unregisters inbound handler', () {
      coordinator = AssistantCoordinator(
        bridge: bridge,
        dao: db.assistantSessionDao,
        inboxDao: db.assistantInboxDao,
        aiPromptService: AiPromptService(),
        usageService: UsageService(appDatabase: db),
        clientFactory:
            ({
              required String providerId,
              required String model,
              required String sessionId,
            }) async {
              throw StateError('should not be called');
            },
        readAiSettings: () => const AiSettings(),
        listNovels: () async => const [],
        startJob: _stubStartJob,
        jobStatus: _stubJobStatus,
        sendToJob: _stubSendToJob,
        createNovel: _stubCreateNovel,
        editNovel: _stubEditNovel,
        listChapters: _stubListChapters,
      );
      coordinator.start();
      expect(bridge.onInboundMessage, isNotNull);

      coordinator.stop();
      expect(bridge.onInboundMessage, isNull);

      // 重复 stop 是 no-op
      coordinator.stop();
    });

    test('stop is no-op when never started', () {
      coordinator = AssistantCoordinator(
        bridge: bridge,
        dao: db.assistantSessionDao,
        inboxDao: db.assistantInboxDao,
        aiPromptService: AiPromptService(),
        usageService: UsageService(appDatabase: db),
        clientFactory:
            ({
              required String providerId,
              required String model,
              required String sessionId,
            }) async {
              throw StateError('should not be called');
            },
        readAiSettings: () => const AiSettings(),
        listNovels: () async => const [],
        startJob: _stubStartJob,
        jobStatus: _stubJobStatus,
        sendToJob: _stubSendToJob,
        createNovel: _stubCreateNovel,
        editNovel: _stubEditNovel,
        listChapters: _stubListChapters,
      );
      coordinator.stop(); // 不抛错
      expect(bridge.onInboundMessage, isNull);
    });
  });

  group('AssistantCoordinator._handleInbound', () {
    test('empty inbound text is ignored — no processing, no send', () async {
      coordinator = AssistantCoordinator(
        bridge: bridge,
        dao: db.assistantSessionDao,
        inboxDao: db.assistantInboxDao,
        aiPromptService: AiPromptService(),
        usageService: UsageService(appDatabase: db),
        clientFactory:
            ({
              required String providerId,
              required String model,
              required String sessionId,
            }) async {
              throw StateError('should not be called');
            },
        readAiSettings: () => const AiSettings(),
        listNovels: () async => const [],
        startJob: _stubStartJob,
        jobStatus: _stubJobStatus,
        sendToJob: _stubSendToJob,
        createNovel: _stubCreateNovel,
        editNovel: _stubEditNovel,
        listChapters: _stubListChapters,
      );
      coordinator.start();

      await bridge.onInboundMessage!(_inbound(text: '   \n  '));

      expect(bridge.processingStartCalls, isEmpty);
      expect(bridge.processingEndCalls, isEmpty);
      expect(bridge.sentMessages, isEmpty);
    });

    test(
      'no chat model configured → fallback message + processing lifecycle',
      () async {
        coordinator = AssistantCoordinator(
          bridge: bridge,
          dao: db.assistantSessionDao,
          inboxDao: db.assistantInboxDao,
          aiPromptService: AiPromptService(),
          usageService: UsageService(appDatabase: db),
          clientFactory:
              ({
                required String providerId,
                required String model,
                required String sessionId,
              }) async {
                throw StateError(
                  'should not be called when no model configured',
                );
              },
          readAiSettings: () => const AiSettings(), // 无 providers
          listNovels: () async => const [],
          startJob: _stubStartJob,
          jobStatus: _stubJobStatus,
          sendToJob: _stubSendToJob,
          createNovel: _stubCreateNovel,
          editNovel: _stubEditNovel,
          listChapters: _stubListChapters,
        );
        coordinator.start();

        await bridge.onInboundMessage!(_inbound(text: '列出小说'));

        expect(bridge.processingStartCalls, [_testChatId]);
        expect(bridge.processingEndCalls, [_testChatId]);
        expect(bridge.sentMessages, hasLength(1));
        expect(bridge.sentMessages.last.$1, _testChatId);
        expect(bridge.sentMessages.last.$2, contains('尚未配置默认聊天模型'));
      },
    );

    test(
      'clientFactory throws → friendly error fallback + processing lifecycle',
      () async {
        coordinator = AssistantCoordinator(
          bridge: bridge,
          dao: db.assistantSessionDao,
          inboxDao: db.assistantInboxDao,
          aiPromptService: AiPromptService(),
          usageService: UsageService(appDatabase: db),
          clientFactory:
              ({
                required String providerId,
                required String model,
                required String sessionId,
              }) async {
                throw StateError('boom: client init failed');
              },
          readAiSettings: () => AiSettings(providers: [_fakeProvider]),
          listNovels: () async => const [],
          startJob: _stubStartJob,
          jobStatus: _stubJobStatus,
          sendToJob: _stubSendToJob,
          createNovel: _stubCreateNovel,
          editNovel: _stubEditNovel,
          listChapters: _stubListChapters,
        );
        coordinator.start();

        await bridge.onInboundMessage!(_inbound(text: '列出小说'));

        expect(bridge.processingStartCalls, [_testChatId]);
        expect(bridge.processingEndCalls, [_testChatId]);
        expect(bridge.sentMessages, hasLength(1));
        expect(bridge.sentMessages.last.$1, _testChatId);
        expect(bridge.sentMessages.last.$2, contains('抱歉'));
      },
    );

    test(
      'two inbound turns on same chatId → session reused (same id)',
      () async {
        var clientCallCount = 0;
        coordinator = AssistantCoordinator(
          bridge: bridge,
          dao: db.assistantSessionDao,
          inboxDao: db.assistantInboxDao,
          aiPromptService: AiPromptService(),
          usageService: UsageService(appDatabase: db),
          clientFactory:
              ({
                required String providerId,
                required String model,
                required String sessionId,
              }) async {
                clientCallCount += 1;
                // 捕获每次 turn 看到的 sessionId，验证两次相同
                capturedSessionIds.add(sessionId);
                throw StateError('intentional failure for test');
              },
          readAiSettings: () => AiSettings(providers: [_fakeProvider]),
          listNovels: () async => const [],
          startJob: _stubStartJob,
          jobStatus: _stubJobStatus,
          sendToJob: _stubSendToJob,
          createNovel: _stubCreateNovel,
          editNovel: _stubEditNovel,
          listChapters: _stubListChapters,
        );
        coordinator.start();

        await bridge.onInboundMessage!(_inbound(text: 'first'));
        await bridge.onInboundMessage!(_inbound(text: 'second'));

        // 两次都触发 clientFactory（每次 turn 都新建 client）
        expect(clientCallCount, 2);
        // 两次都只发送各自的失败兜底消息 → 共 2 条
        expect(bridge.sentMessages, hasLength(2));
        // 同 chatId 复用同一 session（getOrCreateByChat 幂等）
        expect(capturedSessionIds, hasLength(2));
        expect(
          capturedSessionIds.toSet().length,
          1,
          reason: 'same chatId must resolve to same sessionId',
        );
      },
    );

    test('cross-chatId messages resolve to different sessions', () async {
      coordinator = AssistantCoordinator(
        bridge: bridge,
        dao: db.assistantSessionDao,
        inboxDao: db.assistantInboxDao,
        aiPromptService: AiPromptService(),
        usageService: UsageService(appDatabase: db),
        clientFactory:
            ({
              required String providerId,
              required String model,
              required String sessionId,
            }) async {
              capturedSessionIds.add(sessionId);
              throw StateError('fail');
            },
        readAiSettings: () => AiSettings(providers: [_fakeProvider]),
        listNovels: () async => const [],
        startJob: _stubStartJob,
        jobStatus: _stubJobStatus,
        sendToJob: _stubSendToJob,
        createNovel: _stubCreateNovel,
        editNovel: _stubEditNovel,
        listChapters: _stubListChapters,
      );
      coordinator.start();

      await bridge.onInboundMessage!(_inbound(text: 'hi', chatId: 'wxid_a'));
      await bridge.onInboundMessage!(_inbound(text: 'hi', chatId: 'wxid_b'));

      expect(capturedSessionIds, hasLength(2));
      expect(
        capturedSessionIds.toSet().length,
        2,
        reason: 'different chatId must resolve to different sessionIds',
      );
    });
  });
}
