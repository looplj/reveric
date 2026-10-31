// 职责: 验证互动模式的错误状态序列化、取消语义及跨 family 失败路由。
// 关联文件:
//   lib/shared/models/ai_run_failure.dart
//   lib/shared/providers/agent_council_providers.dart
//   lib/shared/providers/theater_providers.dart
//   lib/shared/providers/monologue_providers.dart
//   lib/shared/providers/roleplay_providers.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_hook.dart';
import 'package:reveric/shared/models/agent_profile.dart';
import 'package:reveric/shared/models/agent_council_models.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/monologue_models.dart';
import 'package:reveric/shared/models/ai_run_failure.dart';
import 'package:reveric/shared/models/roleplay_models.dart';
import 'package:reveric/shared/models/theater_models.dart';
import 'package:reveric/shared/providers/agent_profile_providers.dart';
import 'package:reveric/shared/providers/agent_council_providers.dart';
import 'package:reveric/shared/providers/monologue_providers.dart';
import 'package:reveric/shared/providers/roleplay_providers.dart';
import 'package:reveric/shared/providers/theater_providers.dart';
import 'package:reveric/shared/providers/trace_providers.dart';
import 'package:reveric/shared/services/ai/agent_council_orchestrator.dart';
import 'package:reveric/shared/services/ai/chat.dart';
import 'package:reveric/shared/services/ai/mode_run_resources.dart';
import 'package:reveric/shared/services/ai/monologue_orchestrator.dart';
import 'package:reveric/shared/services/ai/roleplay_orchestrator.dart';
import 'package:reveric/shared/services/ai/theater_orchestrator.dart';
import 'package:reveric/shared/services/ai/trace_reporter_service.dart';

class _MissingToolManagerAiClient extends AiClient {
  _MissingToolManagerAiClient()
    : super(aiProviderBuiltinDefaults.first, chatModel: 'test-model');

  @override
  Future<String> chatCompletionDetached(
    List<AiMessage> messages, {
    required Duration timeout,
    AiSessionContext? context,
    List<AgentHook> hooks = const [],
  }) async {
    return '';
  }
}

class _FakeTraceReporterService implements TraceReporterService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 7, 31);
  const failure = AiRunFailure.http(statusCode: 402, providerId: 'custom');

  test('all interaction modes preserve and clear safe run errors', () {
    final theater = TheaterSession(
      id: 'theater',
      novelId: 'novel',
      sceneDescription: 'Scene',
      participants: const [],
      phase: TheaterPhase.error,
      failure: failure,
      createdAt: now,
      updatedAt: now,
    );
    final roleplay = RoleplaySession(
      id: 'roleplay',
      novelId: 'novel',
      character: const RoleplayParticipant(
        characterId: 'character',
        name: 'Character',
        role: 'protagonist',
        biography: '',
      ),
      phase: RoleplayPhase.error,
      failure: failure,
      createdAt: now,
      updatedAt: now,
    );
    final monologue = MonologueSession(
      id: 'monologue',
      novelId: 'novel',
      topic: 'Topic',
      character: const MonologueParticipant(
        characterId: 'character',
        name: 'Character',
        role: 'protagonist',
        biography: '',
      ),
      phase: MonologuePhase.error,
      failure: failure,
      createdAt: now,
      updatedAt: now,
    );

    final restoredTheater = TheaterSession.fromJson(
      jsonDecode(jsonEncode(theater.toJson())) as Map<String, dynamic>,
    );
    final restoredRoleplay = RoleplaySession.fromJson(
      jsonDecode(jsonEncode(roleplay.toJson())) as Map<String, dynamic>,
    );
    final restoredMonologue = MonologueSession.fromJson(
      jsonDecode(jsonEncode(monologue.toJson())) as Map<String, dynamic>,
    );

    expect(restoredTheater.failure, failure);
    expect(restoredRoleplay.failure, failure);
    expect(restoredMonologue.failure, failure);
    expect(restoredTheater.copyWith(clearFailure: true).failure, isNull);
    expect(restoredRoleplay.copyWith(clearFailure: true).failure, isNull);
    expect(restoredMonologue.copyWith(clearFailure: true).failure, isNull);
  });

  test('pause completes Theater and Monologue without showing an error', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final theaterProvider = theaterSessionProvider('theater');
    container
        .read(theaterProvider.notifier)
        .setSession(
          TheaterSession(
            id: 'theater',
            novelId: 'novel',
            sceneDescription: 'Scene',
            participants: const [],
            phase: TheaterPhase.error,
            failure: failure,
            createdAt: now,
            updatedAt: now,
          ),
        );
    container.read(theaterProvider.notifier).pause();

    final monologueProvider = monologueSessionProvider('monologue');
    container
        .read(monologueProvider.notifier)
        .setSession(
          MonologueSession(
            id: 'monologue',
            novelId: 'novel',
            topic: 'Topic',
            character: const MonologueParticipant(
              characterId: 'character',
              name: 'Character',
              role: 'protagonist',
              biography: '',
            ),
            phase: MonologuePhase.error,
            failure: failure,
            createdAt: now,
            updatedAt: now,
          ),
        );
    container.read(monologueProvider.notifier).pause();

    expect(container.read(theaterProvider)?.phase, TheaterPhase.completed);
    expect(container.read(theaterProvider)?.failure, isNull);
    expect(container.read(monologueProvider)?.phase, MonologuePhase.completed);
    expect(container.read(monologueProvider)?.failure, isNull);
  });

  test('cancel uses a distinct failure-free phase in every mode', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final councilProvider = agentCouncilSessionProvider('council');
    container
        .read(councilProvider.notifier)
        .setSession(
          AgentCouncilSession(
            id: 'council',
            novelId: 'novel',
            topic: 'Topic',
            participants: const [],
            phase: CouncilPhase.error,
            failure: failure,
            createdAt: now,
            updatedAt: now,
          ),
        );
    container.read(councilProvider.notifier).cancel();

    final theaterProvider = theaterSessionProvider('theater_cancel');
    container
        .read(theaterProvider.notifier)
        .setSession(
          TheaterSession(
            id: 'theater_cancel',
            novelId: 'novel',
            sceneDescription: 'Scene',
            participants: const [],
            phase: TheaterPhase.error,
            failure: failure,
            createdAt: now,
            updatedAt: now,
          ),
        );
    container.read(theaterProvider.notifier).cancel();

    final roleplayProvider = roleplaySessionProvider('roleplay');
    container
        .read(roleplayProvider.notifier)
        .setSession(
          RoleplaySession(
            id: 'roleplay',
            novelId: 'novel',
            character: const RoleplayParticipant(
              characterId: 'character',
              name: 'Character',
              role: 'protagonist',
              biography: '',
            ),
            phase: RoleplayPhase.error,
            failure: failure,
            createdAt: now,
            updatedAt: now,
          ),
        );
    container.read(roleplayProvider.notifier).cancel();

    final monologueProvider = monologueSessionProvider('monologue_cancel');
    container
        .read(monologueProvider.notifier)
        .setSession(
          MonologueSession(
            id: 'monologue_cancel',
            novelId: 'novel',
            topic: 'Topic',
            character: const MonologueParticipant(
              characterId: 'character',
              name: 'Character',
              role: 'protagonist',
              biography: '',
            ),
            phase: MonologuePhase.error,
            failure: failure,
            createdAt: now,
            updatedAt: now,
          ),
        );
    container.read(monologueProvider.notifier).cancel();

    final states = [
      (
        isCancelled:
            container.read(councilProvider)!.phase == CouncilPhase.cancelled,
        failure: container.read(councilProvider)!.failure,
      ),
      (
        isCancelled:
            container.read(theaterProvider)!.phase == TheaterPhase.cancelled,
        failure: container.read(theaterProvider)!.failure,
      ),
      (
        isCancelled:
            container.read(roleplayProvider)!.phase == RoleplayPhase.cancelled,
        failure: container.read(roleplayProvider)!.failure,
      ),
      (
        isCancelled:
            container.read(monologueProvider)!.phase ==
            MonologuePhase.cancelled,
        failure: container.read(monologueProvider)!.failure,
      ),
    ];
    for (final state in states) {
      expect(state.isCancelled, isTrue);
      expect(state.failure, isNull);
    }
    expect(
      AgentCouncilSession.fromJson(
        jsonDecode(jsonEncode(container.read(councilProvider)!.toJson()))
            as Map<String, dynamic>,
      ).phase,
      CouncilPhase.cancelled,
    );
    expect(
      TheaterSession.fromJson(
        jsonDecode(jsonEncode(container.read(theaterProvider)!.toJson()))
            as Map<String, dynamic>,
      ).phase,
      TheaterPhase.cancelled,
    );
    expect(
      RoleplaySession.fromJson(
        jsonDecode(jsonEncode(container.read(roleplayProvider)!.toJson()))
            as Map<String, dynamic>,
      ).phase,
      RoleplayPhase.cancelled,
    );
    expect(
      MonologueSession.fromJson(
        jsonDecode(jsonEncode(container.read(monologueProvider)!.toJson()))
            as Map<String, dynamic>,
      ).phase,
      MonologuePhase.cancelled,
    );
  });

  test('cross-family start failures update only the target session', () async {
    final container = ProviderContainer(
      overrides: [
        aiModeClientFactoryProvider.overrideWithValue(
          (_) async => AiModeOwnedClient(_MissingToolManagerAiClient(), () {}),
        ),
        agentProfileBySlugProvider(
          slug: builtinAgentSlugTheaterActor,
        ).overrideWithValue(null),
        agentProfileBySlugProvider(
          slug: builtinAgentSlugMonologueNarrator,
        ).overrideWithValue(null),
        agentProfileBySlugProvider(
          slug: builtinAgentSlugRoleplayMaster,
        ).overrideWithValue(null),
        traceReporterServiceProvider.overrideWithValue(
          _FakeTraceReporterService(),
        ),
      ],
    );
    addTearDown(container.dispose);
    const roleplayCharacter = RoleplayParticipant(
      characterId: 'character',
      name: 'Character',
      role: 'protagonist',
      biography: '',
    );
    const monologueCharacter = MonologueParticipant(
      characterId: 'character',
      name: 'Character',
      role: 'protagonist',
      biography: '',
    );

    final councilSource = agentCouncilSessionProvider('council_source');
    container
        .read(councilSource.notifier)
        .setSession(
          AgentCouncilSession(
            id: 'council_source',
            novelId: 'novel',
            topic: 'Existing council',
            participants: const [],
            phase: CouncilPhase.completed,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await expectLater(
      container
          .read(councilSource.notifier)
          .startCouncil(
            novelId: 'novel',
            context: const AiSessionContext(
              workId: 'novel',
              contentKind: 'novel',
            ),
            topic: 'New council',
            participants: const [
              CouncilParticipant(
                id: 'agent',
                name: 'Agent',
                description: '',
                prompt: '',
              ),
            ],
            selection: AiModeRunSelection(
              model: const AiModelOption(
                providerId: 'custom',
                providerDisplayName: 'Test',
                model: 'test-model',
                kind: AiModelKind.chat,
              ),
            ),
            preferredSessionId: 'council_target',
          ),
      throwsA(isA<AgentCouncilRunException>()),
    );

    final theaterSource = theaterSessionProvider('theater_source');
    container
        .read(theaterSource.notifier)
        .setSession(
          TheaterSession(
            id: 'theater_source',
            novelId: 'novel',
            sceneDescription: 'Existing theater',
            participants: const [],
            phase: TheaterPhase.completed,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await expectLater(
      container
          .read(theaterSource.notifier)
          .startPerformance(
            novelId: 'novel',
            sceneDescription: 'New theater',
            participants: const [
              TheaterParticipant(
                characterId: 'character',
                name: 'Character',
                role: 'protagonist',
                biography: '',
              ),
            ],
            selection: AiModeRunSelection(
              model: const AiModelOption(
                providerId: 'custom',
                providerDisplayName: 'Test',
                model: 'test-model',
                kind: AiModelKind.chat,
              ),
            ),
            preferredSessionId: 'theater_target',
            context: const AiSessionContext(),
          ),
      throwsA(isA<TheaterRunException>()),
    );

    final monologueSource = monologueSessionProvider('monologue_source');
    container
        .read(monologueSource.notifier)
        .setSession(
          MonologueSession(
            id: 'monologue_source',
            novelId: 'novel',
            topic: 'Existing monologue',
            character: monologueCharacter,
            phase: MonologuePhase.completed,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await expectLater(
      container
          .read(monologueSource.notifier)
          .startSession(
            novelId: 'novel',
            topic: 'New monologue',
            character: monologueCharacter,
            selection: AiModeRunSelection(
              model: const AiModelOption(
                providerId: 'custom',
                providerDisplayName: 'Test',
                model: 'test-model',
                kind: AiModelKind.chat,
              ),
            ),
            preferredSessionId: 'monologue_target',
            context: const AiSessionContext(),
          ),
      throwsA(isA<MonologueRunException>()),
    );

    final roleplaySource = roleplaySessionProvider('roleplay_source');
    container
        .read(roleplaySource.notifier)
        .setSession(
          RoleplaySession(
            id: 'roleplay_source',
            novelId: 'novel',
            title: 'Existing roleplay',
            character: roleplayCharacter,
            phase: RoleplayPhase.completed,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await expectLater(
      container
          .read(roleplaySource.notifier)
          .sendMessage(
            novelId: 'novel',
            userMessage: 'New roleplay',
            character: roleplayCharacter,
            selection: AiModeRunSelection(
              model: const AiModelOption(
                providerId: 'custom',
                providerDisplayName: 'Test',
                model: 'test-model',
                kind: AiModelKind.chat,
              ),
            ),
            preferredSessionId: 'roleplay_target',
            context: const AiSessionContext(),
          ),
      throwsA(isA<RoleplayRunException>()),
    );

    expect(container.read(councilSource)?.id, 'council_source');
    expect(container.read(councilSource)?.phase, CouncilPhase.completed);
    expect(container.read(theaterSource)?.id, 'theater_source');
    expect(container.read(theaterSource)?.phase, TheaterPhase.completed);
    expect(container.read(monologueSource)?.id, 'monologue_source');
    expect(container.read(monologueSource)?.phase, MonologuePhase.completed);
    expect(container.read(roleplaySource)?.id, 'roleplay_source');
    expect(container.read(roleplaySource)?.phase, RoleplayPhase.completed);

    final councilTarget = container.read(
      agentCouncilSessionProvider('council_target'),
    );
    final theaterTarget = container.read(
      theaterSessionProvider('theater_target'),
    );
    final monologueTarget = container.read(
      monologueSessionProvider('monologue_target'),
    );
    final roleplayTarget = container.read(
      roleplaySessionProvider('roleplay_target'),
    );
    expect(councilTarget?.id, 'council_target');
    expect(councilTarget?.failure?.kind, AiRunFailureKind.requestFailed);
    expect(theaterTarget?.id, 'theater_target');
    expect(theaterTarget?.failure?.kind, AiRunFailureKind.requestFailed);
    expect(monologueTarget?.id, 'monologue_target');
    expect(monologueTarget?.failure?.kind, AiRunFailureKind.requestFailed);
    expect(roleplayTarget?.id, 'roleplay_target');
    expect(roleplayTarget?.failure?.kind, AiRunFailureKind.requestFailed);
    expect(
      container.read(agentCouncilSessionProvider('council_target'))?.phase,
      CouncilPhase.error,
    );
    expect(
      container.read(theaterSessionProvider('theater_target'))?.phase,
      TheaterPhase.error,
    );
    expect(
      container.read(monologueSessionProvider('monologue_target'))?.phase,
      MonologuePhase.error,
    );
    expect(
      container.read(roleplaySessionProvider('roleplay_target'))?.phase,
      RoleplayPhase.error,
    );
  });
}
