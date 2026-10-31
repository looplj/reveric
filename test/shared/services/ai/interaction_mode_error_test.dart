// 职责: 验证互动模式遇到 Agent 错误时停止生成，并保留并行完成的会话标题。
// 关联文件:
//   lib/shared/services/ai/agent_council_orchestrator.dart
//   lib/shared/services/ai/theater_orchestrator.dart
//   lib/shared/services/ai/roleplay_orchestrator.dart
//   lib/shared/services/ai/monologue_orchestrator.dart
//   lib/shared/agent/fake_agent.dart
import '../../../helpers/plugin_host.dart';
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/client.dart' show ProviderClient;
import 'package:reveric/shared/agent/agent_hook.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/agent_council_models.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/ai_run_failure.dart';
import 'package:reveric/shared/models/monologue_models.dart';
import 'package:reveric/shared/models/roleplay_models.dart';
import 'package:reveric/shared/models/theater_models.dart';
import 'package:reveric/shared/services/ai/chat.dart';
import 'package:reveric/shared/services/ai/agent_council_orchestrator.dart';
import 'package:reveric/shared/services/ai/monologue_orchestrator.dart';
import 'package:reveric/shared/services/ai/prompt_template.dart';
import 'package:reveric/shared/services/ai/roleplay_orchestrator.dart';
import 'package:reveric/shared/services/ai/theater_orchestrator.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

class _ModeAiClient extends AiClient {
  _ModeAiClient(
    this.fakeClient,
    this.fakeToolManager, {
    Future<String>? titleFuture,
  }) : _titleFuture = titleFuture ?? Future.value('Generated title'),
       super(aiProviderBuiltinDefaults.first, chatModel: 'test-model');

  final FakeProviderClient fakeClient;
  final AiToolManager fakeToolManager;
  final Future<String> _titleFuture;

  @override
  ProviderClient get providerClient => fakeClient;

  @override
  AiToolManager? get toolManager => fakeToolManager;

  @override
  Future<String> chatCompletionDetached(
    List<AiMessage> messages, {
    required Duration timeout,
    AiSessionContext? context,
    List<AgentHook> hooks = const [],
  }) async {
    return _titleFuture;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NovelContentDatabase contentDb;
  late AppDatabase appDb;
  late AiToolManager toolManager;

  setUpAll(PromptTemplateService.loadAll);

  setUp(() {
    contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    final contentService = NovelContentService(contentDb);
    final overlay = WorkingOverlayService(
      contentDb,
      contentService,
      novelActionsService: NovelActionsService(appDb),
    );
    toolManager = AiToolManager(contentService, workingOverlayService: overlay)
      ..registerAllTools();
  });

  tearDown(() async {
    await contentDb.close();
    await appDb.close();
  });

  _ModeAiClient failingClient({Future<String>? titleFuture}) {
    return _ModeAiClient(
      FakeProviderClient(responder: (_) => throw StateError('provider failed')),
      toolManager,
      titleFuture: titleFuture,
    );
  }

  test(
    'Council publishes its title when discussion generation fails',
    () async {
      final generatedTitle = Completer<String>();
      final titleResult = Completer<String>();

      final run = (AgentCouncilOrchestrator()..pluginHost = emptyPluginHost())
          .startDiscussion(
            novelId: 'novel',
            context: const AiSessionContext(),
            topic: 'Topic',
            participants: const [
              CouncilParticipant(
                id: 'agent',
                name: 'Agent',
                description: '',
                prompt: '',
              ),
            ],
            aiService: failingClient(titleFuture: titleResult.future),
            config: const AgentCouncilConfig(maxRounds: 1),
            onTitleGenerated: generatedTitle.complete,
          );

      await expectLater(
        run.timeout(const Duration(seconds: 1)),
        throwsA(isA<AgentCouncilRunException>()),
      );
      titleResult.complete('Generated title');
      await expectLater(generatedTitle.future, completion('Generated title'));
    },
  );

  test(
    'Council keeps a completed discussion when automatic summary fails',
    () async {
      var requestCount = 0;
      final aiService = _ModeAiClient(
        FakeProviderClient(
          responder: (_) {
            requestCount += 1;
            if (requestCount == 1) {
              return const FakeProviderClientResponse.text(
                'A useful council response',
              );
            }
            throw StateError('summary parser dependency failed');
          },
        ),
        toolManager,
      );
      final phases = <CouncilPhase>[];

      final result =
          await (AgentCouncilOrchestrator()..pluginHost = emptyPluginHost())
              .startDiscussion(
                novelId: 'novel',
                context: const AiSessionContext(),
                topic: 'Topic',
                participants: const [
                  CouncilParticipant(
                    id: 'agent',
                    name: 'Agent',
                    description: '',
                    prompt: '',
                  ),
                ],
                aiService: aiService,
                config: const AgentCouncilConfig(maxRounds: 1),
                onPhaseChanged: (session) => phases.add(session.phase),
              );

      expect(result.phase, CouncilPhase.completed);
      expect(result.rounds, hasLength(1));
      expect(result.rounds.single.isComplete, isTrue);
      expect(result.summary, isNull);
      expect(result.failure?.kind, AiRunFailureKind.requestFailed);
      expect(result.canUpdateSummary, isTrue);
      expect(
        phases,
        containsAllInOrder([
          CouncilPhase.completed,
          CouncilPhase.summarizing,
          CouncilPhase.completed,
        ]),
      );
    },
  );

  test('Theater stops before adding a fallback line', () async {
    final generatedLines = <TheaterLine>[];
    final generatedTitle = Completer<String>();

    final run = (TheaterOrchestrator()..pluginHost = emptyPluginHost())
        .startPerformance(
          novelId: 'novel',
          sceneDescription: 'Scene',
          participants: const [
            TheaterParticipant(
              characterId: 'first',
              name: 'First',
              role: 'protagonist',
              biography: '',
            ),
            TheaterParticipant(
              characterId: 'second',
              name: 'Second',
              role: 'supporting',
              biography: '',
            ),
          ],
          aiService: failingClient(),
          config: const TheaterConfig(maxRounds: 1),
          onLineGenerated: (_, line) => generatedLines.add(line),
          onTitleGenerated: generatedTitle.complete,
        );

    await expectLater(run, throwsA(isA<TheaterRunException>()));
    expect(generatedLines, isEmpty);
    await expectLater(generatedTitle.future, completion('Generated title'));
  });

  test('Roleplay keeps the user turn but does not add a fake reply', () async {
    final generatedMessages = <RoleplayMessage>[];
    final generatedTitle = Completer<String>();
    final now = DateTime(2026, 7, 31);
    const character = RoleplayParticipant(
      characterId: 'character',
      name: 'Character',
      role: 'protagonist',
      biography: '',
    );
    final session = RoleplaySession(
      id: 'roleplay',
      novelId: 'novel',
      character: character,
      createdAt: now,
      updatedAt: now,
    );

    final run = (RoleplayOrchestrator()..pluginHost = emptyPluginHost())
        .sendMessage(
          novelId: 'novel',
          userMessage: 'Hello',
          character: character,
          session: session,
          aiService: failingClient(),
          onMessageGenerated: (_, message) => generatedMessages.add(message),
          onTitleGenerated: generatedTitle.complete,
        );

    await expectLater(run, throwsA(isA<RoleplayRunException>()));
    expect(generatedMessages, isEmpty);
    await expectLater(generatedTitle.future, completion('Generated title'));
  });

  test('Monologue stops before adding a fallback entry', () async {
    final generatedEntries = <MonologueEntry>[];
    final generatedTitle = Completer<String>();
    const character = MonologueParticipant(
      characterId: 'character',
      name: 'Character',
      role: 'protagonist',
      biography: '',
    );

    final run = (MonologueOrchestrator()..pluginHost = emptyPluginHost())
        .startSession(
          novelId: 'novel',
          topic: 'Topic',
          character: character,
          aiService: failingClient(),
          onMonologueGenerated: (_, entry) => generatedEntries.add(entry),
          onTitleGenerated: generatedTitle.complete,
        );

    await expectLater(run, throwsA(isA<MonologueRunException>()));
    expect(generatedEntries, isEmpty);
    await expectLater(generatedTitle.future, completion('Generated title'));
  });
}
