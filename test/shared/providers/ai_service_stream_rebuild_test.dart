// 职责: aiService / aiServiceAsync 回归测试 — streaming 合帧通知不得导致 AiClient 重建
// 关联文件:
//   lib/shared/providers/ai_providers.dart
//   lib/shared/services/ai/chat.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/testing.md

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/agent_profile.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';

// 回归背景：aiService / aiServiceAsync 曾整体 watch aiChatSessionProvider 只为
// 读取 trace 头字段；AiChatSession 在 streaming 期间按 100ms 窗口合帧通知，
// 每次通知都触发 AiClient / AiToolManager 重建（一轮长 agent 任务实测 2026 次）。
// 这里锁定契约：streaming delta 只改变 messages，不得触发 service 重建。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sessionId = 'ai_session_stream_rebuild_test';
  const fakeModel = 'fake-chat';

  final fakeProvider = AiProvider(
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
    models: [fakeModel],
    imageModels: [],
    embeddingModels: [],
    temperature: 0.7,
    maxTurns: 8,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: DateTime(2026, 1, 1),
    deletedAt: notDeletedSentinel,
  );

  late AppDatabase appDb;
  late ProviderContainer container;

  setUp(() {
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(appDb),
        currentAiConfigProvider(
          providerId: fakeProvider.id,
          model: fakeModel,
        ).overrideWithValue(fakeProvider),
        imageGenerationCallbackProvider.overrideWith((ref, workId) => null),
        aiSettingsProvider.overrideWithValue(AiSettings.defaults()),

        // fakeProvider 是自定义供应商，会撞上专业版门禁：AiProviderInitializer
        // 抛 AiProviderAccessDeniedException，aiServiceAsyncProvider 反复重建、
        // 一直停在 AsyncLoading，`.future` 永远不 settle（表现为整个测试 30s 超时）。
        // 这里只关心「流式合帧不重建 AiClient」，把门禁放开。
      ],
    );
    container
        .read(aiChatSessionProvider(sessionId).notifier)
        .startNewSession(
          sessionId: sessionId,
          title: 'Stream rebuild test',
          providerId: fakeProvider.id,
          model: fakeModel,
          sessionMode: AiSessionMode.chat,
          agentSlug: builtinAgentSlugOrchestrator,
        );
  });

  tearDown(() async {
    container.dispose();
    await appDb.close();
  });

  Future<void> driveStreamingDeltas() async {
    final notifier = container.read(aiChatSessionProvider(sessionId).notifier);
    notifier.startStreamingMessage();
    for (var i = 0; i < 5; i++) {
      notifier.appendTextDelta('chunk-$i ');
      // 超过 100ms 合帧窗口，确保每个窗口的 trailing-edge 通知都真实发出。
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    notifier.endStreamingMessage();
  }

  test('streaming deltas do not rebuild aiServiceProvider', () async {
    var emissions = 0;
    final sub = container.listen(aiServiceProvider(sessionId), (_, _) {
      emissions++;
    });
    addTearDown(sub.close);
    expect(container.read(aiServiceProvider(sessionId)), isNotNull);
    final baseline = emissions;

    await driveStreamingDeltas();

    expect(emissions, baseline);
  });

  test('streaming deltas do not rebuild aiServiceAsyncProvider', () async {
    var emissions = 0;
    final sub = container.listen(aiServiceAsyncProvider(sessionId), (_, _) {
      emissions++;
    });
    addTearDown(sub.close);
    final client = await container.read(
      aiServiceAsyncProvider(sessionId).future,
    );
    expect(client, isNotNull);
    final baseline = emissions;

    await driveStreamingDeltas();

    expect(emissions, baseline);
  });
}
