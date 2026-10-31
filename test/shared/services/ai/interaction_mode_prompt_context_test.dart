// 职责: 验证互动模式的 system prompt 不注入编辑器当前小说、章节或工作区正文。
// 关联文件:
//   lib/shared/services/ai/prompts/use_cases/mode_prompt_use_case.dart
//   lib/shared/services/ai/agent_council_orchestrator.dart
//   lib/shared/services/ai/monologue_orchestrator.dart
//   lib/shared/services/ai/roleplay_orchestrator.dart
//   lib/shared/services/ai/theater_orchestrator.dart

import '../../../helpers/plugin_host.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_hook.dart';
import 'package:reveric/shared/agent/client.dart' show ProviderClient;
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/agent_council_models.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/monologue_models.dart';
import 'package:reveric/shared/models/roleplay_models.dart';
import 'package:reveric/shared/models/theater_models.dart';
import 'package:reveric/shared/services/ai/agent_council_orchestrator.dart';
import 'package:reveric/shared/services/ai/chat.dart';
import 'package:reveric/shared/services/ai/monologue_orchestrator.dart';
import 'package:reveric/shared/services/ai/prompt_template.dart';
import 'package:reveric/shared/services/ai/roleplay_orchestrator.dart';
import 'package:reveric/shared/services/ai/theater_orchestrator.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

const _context = AiSessionContext(
  databasePath: '/internal/database/path',
  workId: 'current',
  contentKind: 'screenplay',
  sourceNovelId: 'original_novel',
  novelName: 'SENTINEL_NOVEL_NAME',
  chapterTitle: 'SENTINEL_CHAPTER_TITLE',
  workspaceContent: 'SENTINEL_WORKSPACE_CONTENT',
);

class _PromptCaptureAiClient extends AiClient {
  _PromptCaptureAiClient(this.fakeClient, this.fakeToolManager)
    : super(aiProviderBuiltinDefaults.first, chatModel: 'test-model');

  final FakeProviderClient fakeClient;
  final AiToolManager fakeToolManager;

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
    return 'Captured title';
  }
}

void _expectNoEditorContext(String prompt) {
  expect(prompt, isNot(contains(_context.novelName!)));
  expect(prompt, isNot(contains(_context.chapterTitle!)));
  expect(prompt, isNot(contains(_context.workspaceContent!)));
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
    toolManager = AiToolManager(
      contentService,
      workingOverlayService: overlay,
      workId: _context.workId,
      contentKind: _context.contentKind,
    )..registerAllTools();
  });

  tearDown(() async {
    await contentDb.close();
    await appDb.close();
  });

  for (final malformed in [false, true]) {
    test('Council malformed=$malformed prompt excludes editor context', () async {
      final fakeClient = FakeProviderClient(
        responses: const [FakeProviderClientResponse.text('Council response')],
      );
      final aiClient = _PromptCaptureAiClient(fakeClient, toolManager);
      const invalidPrompt =
          'SENTINEL_COUNCIL_BASE_PROMPT\n{{#screenplay_workspace}}未闭合条件';

      await (AgentCouncilOrchestrator()..pluginHost = emptyPluginHost())
          .startDiscussion(
            novelId: 'novel',
            topic: 'Discuss the story',
            participants: [
              CouncilParticipant(
                id: 'plot_architect',
                name: 'Plot architect',
                description: 'Plans the plot',
                prompt: malformed
                    ? invalidPrompt
                    : 'SENTINEL_COUNCIL_BASE_PROMPT\n'
                          '{{#screenplay_workspace}}场次规则{{/screenplay_workspace}}'
                          '{{^screenplay_workspace}}章节规则{{/screenplay_workspace}}',
              ),
            ],
            aiService: aiClient,
            context: _context,
            config: const AgentCouncilConfig(
              maxRounds: 1,
              autoSummarize: false,
            ),
          );

      final systemPrompt =
          fakeClient.capturedStreamRequests.single.messages.first.content;
      expect(systemPrompt, contains('SENTINEL_COUNCIL_BASE_PROMPT'));
      if (malformed) {
        expect(systemPrompt, startsWith(invalidPrompt));
      } else {
        expect(systemPrompt, contains('场次规则'));
        expect(systemPrompt, isNot(contains('章节规则')));
        expect(systemPrompt, isNot(contains('{{')));
      }
      expect(systemPrompt, contains('当前作品工作路径：/works/current'));
      expect(systemPrompt, contains('原作工作路径：/works/original_novel'));
      expect(systemPrompt, isNot(contains('/internal/database/path')));
      _expectNoEditorContext(systemPrompt);
    });
  }

  test(
    'multi-model Council and resumed round share current identity after unlinking source',
    () async {
      final primary = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.text('first model result'),
        ],
      );
      final alternate = FakeProviderClient(
        responses: const [
          FakeProviderClientResponse.text('second model result'),
        ],
      );
      final mainClient = _PromptCaptureAiClient(primary, toolManager);
      final otherClient = _PromptCaptureAiClient(alternate, toolManager);
      final orchestrator = (AgentCouncilOrchestrator()
        ..pluginHost = emptyPluginHost());
      final first = await orchestrator.startDiscussion(
        novelId: 'current',
        topic: '按本次要求讨论',
        participants: const [
          CouncilParticipant(
            id: 'one',
            name: 'One',
            description: '',
            prompt: 'first persona',
          ),
          CouncilParticipant(
            id: 'two',
            name: 'Two',
            description: '',
            prompt: 'second persona',
            modelOptionId: 'alternate',
          ),
        ],
        aiService: mainClient,
        context: _context,
        aiServiceResolver: (_) async => otherClient,
        config: const AgentCouncilConfig(maxRounds: 1, autoSummarize: false),
      );
      await orchestrator.runRound(
        session: first,
        aiService: mainClient,
        context: _context.copyWith(clearSourceNovelId: true),
        aiServiceResolver: (_) async => otherClient,
      );
      for (final client in [primary, alternate]) {
        expect(client.capturedStreamRequests, hasLength(2));
        final firstSystem =
            client.capturedStreamRequests.first.messages.first.content;
        final nextSystem =
            client.capturedStreamRequests.last.messages.first.content;
        expect(firstSystem, contains('原作工作路径：/works/original_novel'));
        expect(nextSystem, isNot(contains('原作工作路径：')));
        expect(nextSystem, isNot(contains('original_novel')));
        expect(nextSystem, contains('当前作品工作路径：/works/current'));
        expect(nextSystem, isNot(contains('<work_context>')));
        _expectNoEditorContext(nextSystem);
      }
    },
  );

  test('character interaction system prompts exclude editor context', () {
    final now = DateTime(2026, 9, 3);
    const monologueCharacter = MonologueParticipant(
      characterId: 'character',
      name: 'Character',
      role: 'protagonist',
      biography: 'Character biography',
    );
    const roleplayCharacter = RoleplayParticipant(
      characterId: 'character',
      name: 'Character',
      role: 'protagonist',
      biography: 'Character biography',
    );
    const theaterCharacter = TheaterParticipant(
      characterId: 'character',
      name: 'Character',
      role: 'protagonist',
      biography: 'Character biography',
    );

    final prompts = [
      MonologueOrchestrator.monologuePrompt(
        session: MonologueSession(
          id: 'monologue',
          novelId: 'novel',
          topic: 'Inner thoughts',
          character: monologueCharacter,
          createdAt: now,
          updatedAt: now,
        ),
        context: _context,
      ),
      RoleplayOrchestrator.roleplayPrompt(
        session: RoleplaySession(
          id: 'roleplay',
          novelId: 'novel',
          character: roleplayCharacter,
          createdAt: now,
          updatedAt: now,
        ),
        context: _context,
      ),
      TheaterOrchestrator.theaterPrompt(theaterCharacter, const [
        theaterCharacter,
      ], context: _context),
    ];

    for (final prompt in prompts) {
      expect(prompt, contains('Character'));
      _expectNoEditorContext(prompt);
    }
  });
}
