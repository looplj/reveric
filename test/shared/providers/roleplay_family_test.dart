// 职责: 验证 Roleplay family providers 按 sessionId 更新时不会形成自依赖
// 关联文件:
//   lib/shared/providers/roleplay_providers.dart
//   lib/shared/providers/agent_profile_providers.dart
//   lib/shared/services/ai/roleplay_orchestrator.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:reveric/shared/models/agent_profile.dart';
import 'package:reveric/shared/agent/agent_hook.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/models/ai_run_failure.dart';
import 'package:reveric/shared/models/roleplay_models.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/providers/agent_profile_providers.dart';
import 'package:reveric/shared/providers/ai_mode_processing.dart';
import 'package:reveric/shared/providers/roleplay_providers.dart';
import 'package:reveric/shared/providers/trace_providers.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/services/ai/chat.dart';
import 'package:reveric/shared/services/ai/mode_run_resources.dart';
import 'package:reveric/shared/services/ai/roleplay_orchestrator.dart';
import 'package:reveric/shared/services/ai/trace_reporter_service.dart';
import 'package:reveric/shared/services/anonymous_outbox_service.dart';
import 'package:reveric/shared/services/device_id_service.dart';

class _TestDeviceIdService extends DeviceIdService {
  @override
  Future<String> getOrCreate() async => 'test-device-id';
}

class _TitleAiClient extends AiClient {
  _TitleAiClient(this.titleFuture)
    : super(aiProviderBuiltinDefaults.first, chatModel: 'test-model');

  final Future<String> titleFuture;

  @override
  Future<String> chatCompletionDetached(
    List<AiMessage> messages, {
    required Duration timeout,
    AiSessionContext? context,
    List<AgentHook> hooks = const [],
  }) {
    return titleFuture;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Roleplay family providers', () {
    test(
      'sendMessage updates the current family instance without self-read',
      () async {
        const sessionId = 'rp_existing';
        final database = AppDatabase.forTest(NativeDatabase.memory());
        final httpClient = http.Client();
        final outbox = AnonymousOutboxService(
          database: database,
          httpClient: httpClient,
          getBaseUrl: () => null,
          getEnabled: () => false,
        );
        addTearDown(httpClient.close);
        addTearDown(database.close);
        final titleResult = Completer<String>();
        final container = ProviderContainer(
          overrides: [
            aiModeClientFactoryProvider.overrideWithValue(
              (_) async =>
                  AiModeOwnedClient(_TitleAiClient(titleResult.future), () {}),
            ),
            agentProfileBySlugProvider(
              slug: builtinAgentSlugRoleplayMaster,
            ).overrideWithValue(_roleplayAgentProfile),
            traceReporterServiceProvider.overrideWithValue(
              TraceReporterService(
                deviceIdService: _TestDeviceIdService(),
                outbox: outbox,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(aiModeProcessingTrackerProvider.notifier)
            .setForegroundSession(
              mode: AiSessionMode.roleplay,
              sessionId: sessionId,
              foreground: true,
            );

        final notifier = container.read(
          roleplaySessionProvider(sessionId).notifier,
        );
        const participant = RoleplayParticipant(
          characterId: 'char_1',
          name: '陆泽',
          role: 'protagonist',
          biography: '主角',
        );
        final now = DateTime(2026, 6, 3);
        notifier.setSession(
          RoleplaySession(
            id: sessionId,
            novelId: 'novel_1',
            character: participant,
            createdAt: now,
            updatedAt: now,
          ),
        );

        final failedWithTitle = Completer<RoleplaySession>();
        final subscription = container.listen(
          roleplaySessionProvider(sessionId),
          (_, session) {
            if (session?.phase == RoleplayPhase.error &&
                session?.title == 'Generated title' &&
                !failedWithTitle.isCompleted) {
              failedWithTitle.complete(session);
            }
          },
        );
        addTearDown(subscription.close);

        await expectLater(
          notifier.sendMessage(
            novelId: 'novel_1',
            userMessage: '继续',
            character: participant,
            selection: AiModeRunSelection(
              model: const AiModelOption(
                providerId: 'custom',
                providerDisplayName: 'Test',
                model: 'test-model',
                kind: AiModelKind.chat,
              ),
            ),
            context: const AiSessionContext(),
            preferredSessionId: sessionId,
          ),
          throwsA(
            isA<RoleplayRunException>()
                .having((error) => error.cause, 'cause', isA<StateError>())
                .having(
                  (error) => (error.cause! as StateError).message,
                  'cause.message',
                  contains('toolManager'),
                ),
          ),
        );
        titleResult.complete('Generated title');

        final failedSession = await failedWithTitle.future;
        expect(failedSession.title, 'Generated title');
        expect(failedSession.failure?.kind, AiRunFailureKind.requestFailed);
        expect(failedSession.messages.single.content, '继续');
      },
    );
  });
}

const _roleplayAgentProfile = AgentProfile(
  id: 'agent_roleplay_master',
  slug: builtinAgentSlugRoleplayMaster,
  name: 'Roleplay Master',
  description: '',
  systemPrompt: '',
  mode: 'roleplay',
  role: AgentProfileRole.custom,
  scope: AgentProfileScope.global,
  sortOrder: 0,
);
