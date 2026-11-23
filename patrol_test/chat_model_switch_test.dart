// 职责: Patrol E2E — 用 FakeAgent 验证聊天模型随发送切换时清理私有推理状态并保留已完成工具历史
// 关联文件:
//   lib/shared/services/ai/chat_session_controller.dart
//   lib/shared/services/ai/agent_message_mapping.dart
//   lib/shared/agent/fake_agent.dart
//   lib/shared/services/ai/session_persistence.dart
//   lib/shared/providers/ai_providers.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/prompt_template_provider.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/subagent_providers.dart';
import 'package:reveric/shared/services/ai/agent_message_mapping.dart';
import 'package:reveric/shared/services/ai/chat_prompt_builder.dart';
import 'package:reveric/shared/services/ai/chat_session_controller.dart';
import 'package:reveric/shared/services/ai/prompts/ai_prompt_service.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:patrol/patrol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/helpers/novel_fixture.dart';

const _sessionId = 'session_model_switch_1';
const _novelId = 'novel_model_switch_1';

void main() {
  late Directory tempSupport;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();

    tempSupport = await Directory.systemTemp.createTemp(
      'reveric_chat_model_switch_support_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getApplicationSupportDirectory' ||
                call.method == 'getTemporaryDirectory') {
              return tempSupport.path;
            }
            return null;
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('reveric/system_notifications'),
          (_) async => null,
        );
    await RevericPaths.initialize();
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('reveric/system_notifications'),
          null,
        );
    if (await tempSupport.exists()) {
      await tempSupport.delete(recursive: true);
    }
  });

  patrolTest('选择新模型后发送会清理私有推理状态并保留工具历史', ($) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final appDatabase = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(appDatabase.close);
    final tempDir = await Directory.systemTemp.createTemp(
      'reveric_chat_model_switch_patrol_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final databasePath = '${tempDir.path}/content.sqlite';
    final fakeClient = FakeProviderClient(
      responses: const [FakeProviderClientResponse.text('已用新模型继续回答。')],
      repeatLastResponse: false,
    );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(appDatabase),

        aiPromptServiceProvider.overrideWithValue(AiPromptService()),
        mergedSubAgentsProvider.overrideWithValue(const []),
        currentAiConfigProvider(
          providerId: _sourceOption.providerId,
          model: _sourceOption.model,
        ).overrideWithValue(_sourceProvider),
        currentAiConfigProvider(
          providerId: _targetOption.providerId,
          model: _targetOption.model,
        ).overrideWithValue(_targetProvider),
        availableAiModelOptionsByKindProvider(
          AiModelKind.chat,
        ).overrideWithValue(const [_sourceOption, _targetOption]),
        imageGenerationCallbackProvider.overrideWith((ref, workId) => null),
        imageEditCallbackProvider.overrideWith((ref, workId) => null),
        aiSettingsProvider.overrideWithValue(AiSettings.defaults()),
      ],
    );
    addTearDown(container.dispose);

    final history = _seedHistory();
    final persistence = container.read(
      aiSessionPersistenceServiceProvider(
        novelId: _novelId,
        databasePath: databasePath,
      ),
    );
    final novelDatabase = container.read(
      novelContentDatabaseProvider(databasePath),
    );
    await persistence.createActiveSession(
      id: _sessionId,
      title: 'Model switch session',
      provider: _sourceOption.providerId,
      model: _sourceOption.model,
      mode: AiSessionMode.chat.value,
    );
    await persistence.saveMessages(
      sessionId: _sessionId,
      messages: history,
      novelDatabase: novelDatabase,
    );
    container
        .read(aiChatSessionProvider(_sessionId).notifier)
        .loadSession(
          sessionId: _sessionId,
          title: 'Model switch session',
          messages: history,
          providerId: _sourceOption.providerId,
          model: _sourceOption.model,
          sessionMode: AiSessionMode.chat,
        );
    // 真实聊天面板会 watch runtime；测试中的 send 会在模型切换落库后继续使用
    // 同一 notifier，因此也要钉住 autoDispose runtime，避免 async gap 后被释放。
    final runtimeKeepAlive = container.listen(
      aiChatRuntimeProvider(_sessionId),
      (_, _) {},
    );
    addTearDown(runtimeKeepAlive.close);

    final beforeSend = container.read(aiChatSessionProvider(_sessionId));
    expect(beforeSend.providerId, _sourceOption.providerId);
    expect(beforeSend.model, _sourceOption.model);

    // 运行时切换会清空旧 Agent；监听新会话状态后，注入包含已清洗 history 的
    // FakeAgent，确保后续真实 send/runTurn 链路可检查目标模型看到的上下文。
    final sessionSubscription = container.listen(
      aiChatSessionProvider(_sessionId),
      (_, next) {
        if (next.providerId != _targetOption.providerId ||
            next.model != _targetOption.model) {
          return;
        }
        final initialMessages = next.messages
            .expand(convertAiMessageToAgentMessagesForModel)
            .toList(growable: false);
        container
            .read(aiChatRuntimeProvider(_sessionId).notifier)
            .agent = FakeAgent.create(
          client: fakeClient,
          initialMessages: initialMessages,
        );
      },
    );
    addTearDown(sessionSubscription.close);

    final controller = _buildController(container, databasePath: databasePath);
    await controller.send(
      '请继续。',
      pendingModelSelection: PendingChatModelSelection(
        providerId: _targetOption.providerId,
        model: _targetOption.model,
      ),
    );

    final session = container.read(aiChatSessionProvider(_sessionId));
    expect(session.providerId, _targetOption.providerId);
    expect(session.model, _targetOption.model);
    expect(
      session.messages.expand((message) => message.blocks),
      isNot(contains(isA<AiThinkingBlock>())),
      reason: '跨模型后不得保留原 provider 的 thinking/signature 状态',
    );
    final runtimeToolCall = session.messages
        .expand((message) => message.blocks)
        .whereType<AiToolCallBlock>()
        .single;
    expect(runtimeToolCall.callId, 'read_chapter');
    expect(runtimeToolCall.status, AiToolCallStatus.success);
    expect(runtimeToolCall.result, {'ok': true, 'content': '章节已读取'});
    expect(runtimeToolCall.thoughtSignature, isNull);

    expect(fakeClient.capturedStreamRequests, hasLength(1));
    final targetModelHistory =
        fakeClient.capturedStreamRequests.single.messages;
    final agentToolCall = targetModelHistory
        .expand((message) => message.blocks)
        .whereType<ToolCallBlock>()
        .single;
    expect(agentToolCall.callId, 'read_chapter');
    expect(agentToolCall.thoughtSignature, isNull);
    expect(
      targetModelHistory
          .expand((message) => message.blocks)
          .whereType<ThinkingBlock>(),
      isEmpty,
      reason: 'FakeAgent 收到的目标模型上下文不应含旧 provider 私有 thinking',
    );
    expect(
      targetModelHistory.where(
        (message) => message.type == AgentMessageType.tool_result,
      ),
      hasLength(1),
      reason: '已完成的工具结果必须继续提供给目标模型',
    );

    final persistedSession = await persistence.getSession(_sessionId);
    expect(persistedSession?.provider, _targetOption.providerId);
    expect(persistedSession?.model, _targetOption.model);
    final persisted = await persistence.loadSessionMessages(
      sessionId: _sessionId,
      novelDatabase: novelDatabase,
    );
    expect(
      persisted.messages.expand((message) => message.blocks),
      isNot(contains(isA<AiThinkingBlock>())),
      reason: 'content DB 也必须清理私有推理数据，不能只改 runtime',
    );
    final persistedToolCall = persisted.messages
        .expand((message) => message.blocks)
        .whereType<AiToolCallBlock>()
        .single;
    expect(persistedToolCall.callId, 'read_chapter');
    expect(persistedToolCall.status, AiToolCallStatus.success);
    expect(persistedToolCall.result, {'ok': true, 'content': '章节已读取'});
    expect(persistedToolCall.thoughtSignature, isNull);
  });
}

ChatSessionController _buildController(
  ProviderContainer container, {
  required String databasePath,
}) {
  return ChatSessionController(
    container: container,
    scope: ChatScope(
      activeSessionId: _sessionId,
      novel: buildTestNovel(id: _novelId, title: 'Model switch novel'),
      databasePath: databasePath,
    ),
    host: ChatHost(
      clearComposer: () {},
      focusComposer: () {},
      openModelSelector: () {},
      resetScroll: () {},
      isMounted: () => true,
    ),
    store: DefaultChatComposerStore(),
    promptBuilder: ChatPromptBuilder(),
    availableSubAgents: const [],
    aiPromptService: AiPromptService(),
    promptContext: AiSessionContext(
      databasePath: databasePath,
      novelName: 'Model switch novel',
    ),
  );
}

List<AiMessage> _seedHistory() {
  return [
    AiMessage.user(id: 'user_1', content: '读取第一章。'),
    AiMessage(
      id: 'assistant_1',
      role: AiMessageRole.assistant,
      content: '章节已读取。',
      type: AiMessageType.text,
      timestamp: DateTime(2026, 7, 26),
      blocks: const [
        AiThinkingBlock(
          id: 'thinking_1',
          text: '这是旧模型的私有推理。',
          signature: 'old-thinking-signature',
          encryptedContents: ['old-encrypted-content'],
        ),
        AiToolCallBlock(
          id: 'tool_read_chapter',
          callId: 'read_chapter',
          toolName: 'Read',
          arguments: {'path': '第一章'},
          status: AiToolCallStatus.success,
          result: {'ok': true, 'content': '章节已读取'},
          thoughtSignature: 'b2xkLXRvb2wtc2lnbmF0dXJl',
        ),
      ],
    ),
  ];
}

const _sourceOption = AiModelOption(
  providerId: 'source_provider',
  providerDisplayName: 'Source Provider',
  model: 'source-model',
  kind: AiModelKind.chat,
  isDefault: true,
);

const _targetOption = AiModelOption(
  providerId: 'target_provider',
  providerDisplayName: 'Target Provider',
  model: 'target-model',
  kind: AiModelKind.chat,
);

final _sourceProvider = _providerFor(_sourceOption);
final _targetProvider = _providerFor(_targetOption);

AiProvider _providerFor(AiModelOption option) {
  return AiProvider(
    id: option.providerId,
    name: option.providerDisplayName,
    builtin: false,
    type: 'openai',
    enabled: true,
    apiKey: 'test-api-key',
    baseUrl: 'https://example.invalid/v1',
    models: [option.model],
    imageModels: const [],
    audioModels: const [],
    videoModels: const [],
    asrModels: const [],
    embeddingModels: const [],
    temperature: 0.7,
    maxTurns: 8,
    proxyUrl: '',
    proxyUsername: '',
    proxyPassword: '',
    updatedAt: DateTime(2026, 7, 26),
    deletedAt: notDeletedSentinel,
  );
}
