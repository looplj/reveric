// 职责: 验证圆桌离页后按需创建成员客户端、执行 Read、落库并归还租约。
// 关联文件:
//   lib/shared/services/ai/mode_run_resources.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/ai/ai_http_client_lease.dart

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/testing.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/providers/agent_council_providers.dart';
import 'package:reveric/shared/providers/trace_providers.dart';
import 'package:reveric/shared/models/agent_council_models.dart';
import 'package:reveric/shared/services/ai/agent_council_orchestrator.dart';
import 'package:reveric/shared/services/ai/mode_run_resources.dart';
import 'package:reveric/shared/services/ai/chat.dart';
import 'package:reveric/shared/services/ai/trace_reporter_service.dart';
import 'package:reveric/shared/services/ai/usage_service.dart';
import 'package:reveric/shared/providers/usage_query_providers.dart';
import 'dart:async';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/providers/ai_providers.dart'
    show aiHttpClientRegistryProvider;
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/ai/ai_http_client_lease.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  testWidgets(
    'second member reads and persists after the council page is removed',
    (tester) async {
      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      final contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
      final actions = NovelActionsService(appDb);
      final content = NovelContentService(contentDb);
      final overlay = WorkingOverlayService(
        contentDb,
        content,
        novelActionsService: actions,
      );
      final config = AiProvider(
        asrModels: const [],
        id: 'custom_test',
        name: 'Test',
        builtin: false,
        type: AiProviderType.openai_compatible.name,
        enabled: true,
        apiKey: 'test',
        baseUrl: 'https://example.invalid/v1',
        models: const ['test', 'second'],
        imageModels: const [],
        audioModels: const [],
        videoModels: const [],
        embeddingModels: const [],
        temperature: 0.7,
        maxTurns: 8,
        proxyUrl: '',
        proxyUsername: '',
        proxyPassword: '',
        updatedAt: DateTime(2026),
        deletedAt: notDeletedSentinel,
      );
      const option = AiModelOption(
        providerId: 'custom_test',
        providerDisplayName: 'Test',
        model: 'test',
        kind: AiModelKind.chat,
      );
      const second = AiModelOption(
        providerId: 'custom_test',
        providerDisplayName: 'Test',
        model: 'second',
        kind: AiModelKind.chat,
      );
      final round = (await tester.runAsync(
        () async => _DelayedReadRound(second.id),
      ))!;
      final registry = AiHttpClientRegistry(
        clientFactory: (_) =>
            MockClient((_) async => throw StateError('No HTTP expected')),
      );
      final container = ProviderContainer(
        overrides: [
          traceReporterServiceProvider.overrideWith((ref) => _Trace()),
          usageServiceProvider.overrideWith((ref) => _Usage()),
          currentAiConfigProvider(
            providerId: second.providerId,
            model: second.model,
          ).overrideWith((ref) => config),
          currentAiConfigProvider(
            providerId: option.providerId,
            model: option.model,
          ).overrideWith((ref) => config),

          aiHttpClientRegistryProvider.overrideWithValue(registry),
          appDatabaseProvider.overrideWithValue(appDb),
          novelActionsProvider.overrideWithValue(actions),
          novelContentServiceProvider('work-db').overrideWithValue(content),
          novelContentDatabaseProvider('work-db').overrideWithValue(contentDb),
          workingOverlayServiceProvider('work-db').overrideWithValue(overlay),
        ],
      );
      final mode = ValueNotifier(AiSessionMode.council);
      addTearDown(() async {
        container.dispose();
        mode.dispose();
        await contentDb.close();
        await appDb.close();
      });
      await tester.runAsync(
        () => appDb.novelDao.create(
          id: 'work',
          title: 'Original',
          description: '',
          contentDatabasePath: 'work-db',
        ),
      );
      final now = DateTime(2026);
      final notifier = (await tester.runAsync(() async {
        final notifier = container.read(
          agentCouncilSessionProvider('session').notifier,
        );
        notifier.setSession(
          AgentCouncilSession(
            id: 'session',
            novelId: 'work',
            topic: 'Topic',
            title: 'Test Council',
            participants: const [],
            phase: CouncilPhase.completed,
            createdAt: now,
            updatedAt: now,
          ),
        );
        container
                .read(agentCouncilRuntimeProvider('session').notifier)
                .orchestrator =
            round;
        return notifier;
      }))!;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, ref, child) {
              ref.watch(agentCouncilSessionProvider('session'));
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      late Future<({String sessionId, CouncilPhase phase})?> pending;
      await tester.runAsync(() async {
        pending = notifier.runAdditionalRound(
          selection: AiModeRunSelection(model: option, memberModels: [second]),
          context: const AiSessionContext(
            workId: 'work',
            databasePath: 'work-db',
          ),
        );
        await round.started.future;
      });
      expect(registry.debugRefCountFor(config), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => actions.updateNovelMetadata(novelId: 'work', title: 'Updated'),
      );
      round.resume.complete();
      final result = await tester.runAsync(() => pending);
      expect(result?.phase, CouncilPhase.completed);
      expect(round.readTitle, 'Updated');
      expect(registry.debugRefCountFor(config), 0);
      final rows = await tester.runAsync(
        () => contentDb.aiChatMessageDao.getBySession('session'),
      );
      expect(rows, isNotEmpty);
      expect(rows!.any((row) => row.content.contains('Updated')), isTrue);
      expect(
        container.read(agentCouncilRuntimeProvider('session')).isProcessing,
        isFalse,
      );
      // 主操作已结束后，应用退出仍须回收尚未完成的独立标题客户端。
      final titleStarted = (await tester.runAsync(
        () async => Completer<void>(),
      ))!;
      final titleGate = (await tester.runAsync(
        () async => Completer<String>(),
      ))!;
      final resources = AiModeRunResources(
        factory: container.read(aiModeClientFactoryProvider),
        selection: AiModeRunSelection(model: option),
        context: const AiSessionContext(
          workId: 'work',
          databasePath: 'work-db',
        ),
        sessionId: 'session',
        mode: AiSessionMode.council,
      );
      late Future<String> title;
      await tester.runAsync(() async {
        title = resources.withDetachedClient((_) {
          titleStarted.complete();
          return titleGate.future;
        });
        await titleStarted.future;
        await resources.close();
      });
      expect(registry.debugRefCountFor(config), 1);
      container.dispose();
      expect(registry.debugRefCountFor(config), 0);
      titleGate.complete('Late title');
      await tester.runAsync(() => title);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

class _Trace implements TraceReporterService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelayedReadRound extends AgentCouncilOrchestrator {
  _DelayedReadRound(this.memberModel);
  final String memberModel;
  final started = Completer<void>();
  final resume = Completer<void>();
  String? readTitle;

  @override
  Future<AgentCouncilSession> runRound({
    required AgentCouncilSession session,
    required AiClient aiService,
    required AiSessionContext context,
    AgentCouncilConfig config = const AgentCouncilConfig(),
    CouncilMessageCallback? onMessageGenerated,
    CouncilPhaseCallback? onPhaseChanged,
    CouncilAiServiceResolver? aiServiceResolver,
    String Function(String)? t,
    CouncilTextDeltaCallback? onTextDelta,
    CouncilThinkingDeltaCallback? onThinkingDelta,
    CouncilToolCallCallback? onToolCall,
    TraceReporterService? traceReporter,
    UsageService? usageService,
    String? speakerId,
  }) async {
    started.complete();
    await resume.future;
    final second = await aiServiceResolver!(memberModel);
    final read = await second!.toolManager!.executeTool(
      name: 'Read',
      input: {'path': '/works/${session.novelId}/title'},
      callId: 'after-unmount',
    );
    readTitle = read['value'] as String?;
    final message = CouncilMessage(
      id: 'message',
      participantId: 'second',
      participantName: 'Second',
      content: readTitle!,
      timestamp: DateTime.now(),
      round: 1,
    );
    final completed = session.copyWith(
      phase: CouncilPhase.completed,
      rounds: [
        CouncilRound(roundNumber: 1, messages: [message], isComplete: true),
      ],
    );
    onMessageGenerated?.call(completed, message);
    onPhaseChanged?.call(completed);
    return completed;
  }
}

class _Usage implements UsageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
