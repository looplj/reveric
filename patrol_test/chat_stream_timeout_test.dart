// 职责: Patrol 回归验证 — 大量历史下 provider 流失去终止信号时，三点 loading 必须超时收口
// 关联文件:
//   lib/shared/agent/agent.dart
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/shared/widgets/ai/chat/chat_message_view.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/agent/agent.dart';
import 'package:reveric/shared/agent/agent_config.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/agent/client.dart';
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/providers/ai_mode_processing.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/ai/chat_turn_outcome.dart';
import 'package:reveric/shared/services/ai/chat_turn_runner.dart';
import 'package:reveric/shared/services/ai/prompts/ai_prompt_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/widgets/ai/chat/chat_message_view.dart';
import 'package:reveric/shared/widgets/ai/chat/typing_indicator.dart';
import 'package:reveric/shared/widgets/ai/chat/ui_message.dart';
import 'package:patrol/patrol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/helpers/novel_fixture.dart';

const _sessionId = 'session_stream_timeout';

void main() {
  late Directory tempSupport;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();

    tempSupport = await Directory.systemTemp.createTemp(
      'reveric_chat_timeout_support_',
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
    await RevericPaths.initialize();
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await tempSupport.exists()) {
      await tempSupport.delete(recursive: true);
    }
  });

  patrolTest('大量历史的静默流超时后退出三点 loading', ($) async {
    final container = ProviderContainer(
      overrides: [aiSettingsProvider.overrideWithValue(AiSettings.defaults())],
    );
    addTearDown(container.dispose);

    final client = _NeverCompletingProviderClient();
    addTearDown(client.close);
    const inactivityTimeout = Duration(milliseconds: 100);
    final agent = Agent.custom(
      id: 'stream_timeout_agent',
      systemPrompt: 'Test silent stream handling.',
      client: client,
      config: const AgentConfig(),
      toolManager: FakeAgentToolDispatcher(),
      initialMessages: _largeHistory(),
      streamInactivityTimeout: inactivityTimeout,
    );

    final sessionNotifier = container.read(
      aiChatSessionProvider(_sessionId).notifier,
    );
    sessionNotifier.markLoaded();
    final userMessage = sessionNotifier.addUserMessage('continue');
    final runtime = container.read(aiChatRuntimeProvider(_sessionId).notifier);
    runtime.agent = agent;
    final requestId = runtime.startRequest();
    container
        .read(aiModeProcessingTrackerProvider.notifier)
        .setForegroundSession(
          mode: AiSessionMode.chat,
          sessionId: _sessionId,
          foreground: true,
        );

    final runner = ChatTurnRunner(
      container: container,
      novel: buildTestNovel(id: 'timeout_work', title: 'Timeout Test'),
      databasePath: null,
      aiPromptService: AiPromptService(),
      promptContext: const AiSessionContext(
        databasePath: null,
        novelName: 'Timeout Test',
      ),
    );

    await $.pumpWidgetAndSettle(_TestApp(container: container));

    final turnFuture = () async {
      try {
        return await runner.runTurn(
          userMessage.content,
          requestId: requestId,
          sessionId: _sessionId,
          userMessageId: userMessage.id,
        );
      } finally {
        runtime.markRequestIdle(requestId);
      }
    }();
    var finished = false;
    unawaited(turnFuture.then((_) => finished = true));

    // runTurn 在 AgentMessageStart 时创建空 streaming assistant；这就是用户看到的三点。
    await $.pump(const Duration(milliseconds: 1));
    expect($(AiTypingIndicator), findsOneWidget);
    expect(client.capturedMessages, hasLength(1));
    expect(
      client.capturedMessages.single.length,
      greaterThanOrEqualTo(362),
      reason: '请求必须携带大量既有历史，覆盖现场的高消息量条件',
    );

    // 按实际重试策略推进 fake clock，每次尝试额外留一帧处理收尾。
    const pumpStep = Duration(milliseconds: 100);
    var waitBudget = (inactivityTimeout + pumpStep) * (maxStreamRetries + 1);
    for (var attempt = 1; attempt <= maxStreamRetries; attempt++) {
      waitBudget += streamRetryDelay(attempt);
    }
    final maxSteps = (waitBudget.inMilliseconds / pumpStep.inMilliseconds)
        .ceil();
    for (var step = 0; step < maxSteps && !finished; step++) {
      await $.pump(pumpStep);
    }
    expect(finished, isTrue, reason: '静默流不能无限保持 in-flight');
    final outcome = await turnFuture;
    await $.pump();

    expect(outcome.status, ChatTurnStatus.failed);
    expect(client.streamCallCount, maxStreamRetries + 1);
    expect($(AiTypingIndicator), findsNothing);
    expect(
      container
          .read(aiChatSessionProvider(_sessionId))
          .messages
          .any((message) => message.isStreaming),
      isFalse,
      reason: '最终失败必须收口所有 assistant streaming 状态',
    );
    expect(
      container.read(aiChatRuntimeProvider(_sessionId)).isRequestInFlight,
      isFalse,
      reason: 'controller finally 路径必须恢复可发送状态',
    );
  });
}

List<AgentMessage> _largeHistory() {
  return List<AgentMessage>.generate(360, (index) {
    if (index.isEven) {
      return AgentMessage.user(
        id: 'history_user_$index',
        content: 'Historical user message $index',
      );
    }
    return AgentMessage.assistant(
      id: 'history_assistant_$index',
      content: 'Historical assistant message $index',
    );
  });
}

class _NeverCompletingProviderClient implements ProviderClient {
  int streamCallCount = 0;
  final List<List<AgentMessage>> capturedMessages = [];
  final List<StreamController<StreamEvent>> _controllers = [];

  @override
  Stream<StreamEvent> chatStream({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) {
    streamCallCount += 1;
    capturedMessages.add(List<AgentMessage>.from(messages));
    late final StreamController<StreamEvent> controller;
    controller = StreamController<StreamEvent>(
      onCancel: () {
        _controllers.remove(controller);
      },
    );
    _controllers.add(controller);
    return controller.stream;
  }

  Future<void> close() async {
    for (final controller in List.of(_controllers)) {
      await controller.close();
    }
    _controllers.clear();
  }

  @override
  Future<ChatResponse> chat({
    required List<AgentMessage> messages,
    List<ToolDef>? tools,
    AgentConfig? options,
  }) {
    throw UnimplementedError();
  }

  @override
  void cancel() {}
}

class _TestApp extends StatelessWidget {
  const _TestApp({required this.container});

  final ProviderContainer container;

  @override
  Widget build(BuildContext context) {
    return UncontrolledProviderScope(
      container: container,
      child: EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/translations',
        assetLoader: const MergingAssetLoader(),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            builder: (context, child) =>
                RevericTheme(data: RevericThemeData.reveric, child: child!),
            home: const Scaffold(body: _AssistantMessages()),
          ),
        ),
      ),
    );
  }
}

class _AssistantMessages extends ConsumerWidget {
  const _AssistantMessages();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rawMessages = ref.watch(
      aiChatSessionProvider(_sessionId).select((session) => session.messages),
    );
    final messages = groupMessagesForUi(
      rawMessages
          .where((message) => message.role == AiMessageRole.assistant)
          .toList(),
    );
    return ListView.builder(
      itemCount: messages.length,
      itemBuilder: (context, index) => ChatMessageView(
        message: messages[index],
        activeSessionId: _sessionId,
        databasePath: null,
        novelId: 'timeout_work',
      ),
    );
  }
}
