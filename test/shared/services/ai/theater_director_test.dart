// 职责: 验证小剧场导演模式 — 被点名者优先接话、单人点名发言、导演指令进入后续 prompt、「无」舞台指示不展示。
// 关联文件:
//   lib/shared/services/ai/theater_orchestrator.dart
//   lib/shared/agent/agent_orchestrator.dart
//   lib/shared/models/theater_models.dart
//   lib/shared/agent/fake_agent.dart
import '../../../helpers/plugin_host.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_hook.dart';
import 'package:reveric/shared/agent/client.dart' show ProviderClient;
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/theater_models.dart';
import 'package:reveric/shared/services/ai/chat.dart';
import 'package:reveric/shared/services/ai/prompt_template.dart';
import 'package:reveric/shared/services/ai/theater_orchestrator.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

class _TheaterAiClient extends AiClient {
  _TheaterAiClient(this.fakeClient, this.fakeToolManager)
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
  }) async => 'Title';
}

const _alice = TheaterParticipant(
  characterId: 'alice',
  name: 'Alice',
  role: 'lead',
  biography: '',
);
const _bob = TheaterParticipant(
  characterId: 'bob',
  name: 'Bob',
  role: 'support',
  biography: '',
);
const _carol = TheaterParticipant(
  characterId: 'carol',
  name: 'Carol',
  role: 'support',
  biography: '',
);

/// 从 task prompt 中取出当前发言角色名。
String _speakerOf(FakeProviderClientRequest request) {
  final task = request.messages.last.content;
  return RegExp(r'## 当前发言角色：(\S+)').firstMatch(task)!.group(1)!;
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

  _TheaterAiClient client(String Function(String speaker) reply) {
    return _TheaterAiClient(
      FakeProviderClient(
        responder: (request) =>
            FakeProviderClientResponse.text(reply(_speakerOf(request))),
      ),
      toolManager,
    );
  }

  TheaterSession completedSession(List<TheaterLine> lines) {
    final now = DateTime(2026, 10, 1);
    return TheaterSession(
      id: 'theater',
      novelId: 'novel',
      sceneDescription: 'Scene',
      participants: const [_alice, _bob, _carol],
      lines: lines,
      phase: TheaterPhase.completed,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('addressed character replies next within the round', () async {
    final result = await (TheaterOrchestrator()..pluginHost = emptyPluginHost())
        .startPerformance(
          novelId: 'novel',
          sceneDescription: 'Scene',
          participants: const [_alice, _bob, _carol],
          aiService: client(
            (speaker) => speaker == 'Alice'
                ? '【对象】\nCarol\n\n【舞台指示】\n无\n\n【台词】\nCarol, explain.'
                : '【对象】\n无\n\n【舞台指示】\n无\n\n【台词】\n$speaker speaks.',
          ),
          config: const TheaterConfig(maxRounds: 1),
        );

    expect(result.lines.map((l) => l.characterId), ['alice', 'carol', 'bob']);
    expect(result.lines.first.addresseeId, 'carol');
    expect(result.lines.first.dialogue, 'Carol, explain.');
    // 「无」是格式占位，不应作为舞台指示展示。
    expect(result.lines.first.stageDirection, isNull);
  });

  test('solo speaker adds one line to the current round', () async {
    final session = completedSession([
      TheaterLine(
        id: 'l1',
        characterId: 'alice',
        characterName: 'Alice',
        dialogue: 'Hello.',
        turn: 2,
        timestamp: DateTime(2026, 10, 1),
      ),
    ]);

    final result = await (TheaterOrchestrator()..pluginHost = emptyPluginHost())
        .continuePerformance(
          session: session,
          aiService: client((speaker) => '【台词】\n$speaker answers.'),
          speakerId: 'bob',
        );

    expect(result.lines, hasLength(2));
    expect(result.lines.last.characterId, 'bob');
    expect(result.lines.last.turn, 2);
  });

  test('director notes reach the next speaker prompt', () async {
    final orchestrator = (TheaterOrchestrator()
      ..pluginHost = emptyPluginHost());
    final fakeClient = FakeProviderClient(
      responder: (request) {
        final speaker = _speakerOf(request);
        if (speaker == 'Alice') {
          // 作者在 Alice 发言期间插入指令，应在下一位发言前生效。
          orchestrator.queueDirection(
            TheaterLine.direction(
              id: 'd2',
              text: 'Bob drops the cup',
              turn: 1,
              timestamp: DateTime(2026, 10, 1),
            ),
          );
        }
        return FakeProviderClientResponse.text('【台词】\n$speaker reacts.');
      },
    );
    final session = completedSession([
      TheaterLine.direction(
        id: 'd1',
        text: 'Footsteps outside the door',
        turn: 0,
        timestamp: DateTime(2026, 10, 1),
      ),
    ]);

    final result = await orchestrator.continuePerformance(
      session: session,
      aiService: _TheaterAiClient(fakeClient, toolManager),
    );

    final tasks = [
      for (final r in fakeClient.capturedStreamRequests)
        r.messages.last.content,
    ];
    expect(tasks[0], contains('【导演】Footsteps outside the door'));
    expect(tasks[0], isNot(contains('Bob drops the cup')));
    expect(tasks[1], contains('【导演】Bob drops the cup'));
    expect(result.lines.map((l) => l.isDirection ? 'note' : l.characterId), [
      'note',
      'alice',
      'note',
      'bob',
      'carol',
    ]);
  });
}
