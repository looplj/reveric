// 职责: Patrol E2E — 用 FakeAgent 模拟多轮 tool call，验证连续 assistant 响应合并为单张活动卡
// 关联文件:
//   lib/shared/widgets/ai/chat/chat_message_view.dart
//   lib/shared/agent/fake_agent.dart
//   lib/shared/services/ai/ai_http_client_lease.dart
//   lib/shared/services/ai/headless_session_turn.dart
//   lib/shared/services/ai/chat_turn_runner.dart
//   assets/translations/en/ai.json
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:reveric/shared/agent/fake_agent.dart';
import 'package:reveric/shared/agent/message.dart' show ToolCall;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/providers/ai_mode_processing.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/prompt_template_provider.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/subagent_providers.dart';
import 'package:reveric/shared/services/ai/ai_http_client_lease.dart';
import 'package:reveric/shared/services/ai/headless_session_turn.dart';
import 'package:reveric/shared/services/ai/prompts/ai_prompt_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:reveric/shared/widgets/ai/chat/chat_message_view.dart';
import 'package:reveric/shared/widgets/ai/chat/ui_message.dart';
import 'package:patrol/patrol.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sessionId = 'session_merge_1';
const _novelId = 'novel_1';

void main() {
  late Directory tempSupport;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();

    // chat_turn_runner 内有 `AppDatabase()` 直构（绕过 override 的 appDatabaseProvider），
    // 触发 _openConnection → path_provider。mock 该 channel 指向临时目录，并初始化
    // RevericPaths，与 novel_actions_test / storage_paths_test 一致。
    tempSupport = await Directory.systemTemp.createTemp(
      'reveric_chat_merge_support_',
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

  patrolTest('连续两轮 thinking + tool call 的 assistant 响应合并为单张活动卡', ($) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final db = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    final tempDir = await Directory.systemTemp.createTemp(
      'reveric_chat_merge_patrol_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    final databasePath = '${tempDir.path}/content.sqlite';
    final novel = _testNovel(databasePath);
    final httpClient = http.Client();
    addTearDown(httpClient.close);

    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),

        aiHttpClientRegistryProvider.overrideWithValue(
          AiHttpClientRegistry(clientFactory: (_) => httpClient),
        ),
        aiPromptServiceProvider.overrideWithValue(AiPromptService()),
        mergedSubAgentsProvider.overrideWithValue(const []),
        currentAiConfigProvider(
          providerId: _fakeProvider.id,
          model: _fakeModelOption.model,
        ).overrideWithValue(_fakeProvider),
        imageGenerationCallbackProvider.overrideWith((ref, workId) => null),
        imageEditCallbackProvider.overrideWith((ref, workId) => null),
        availableAiModelOptionsByKindProvider(
          AiModelKind.chat,
        ).overrideWithValue(const [_fakeModelOption]),
        appBackgroundActiveProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);

    // 预加载 session（含 provider/model），让 headless turn 跳过 DB 元数据查询。
    container
        .read(aiChatSessionProvider(_sessionId).notifier)
        .loadSession(
          sessionId: _sessionId,
          title: 'Merge session',
          messages: const [],
          providerId: _fakeProvider.id,
          model: _fakeModelOption.model,
          sessionMode: AiSessionMode.chat,
        );
    // 钉住 session provider，turn 结束后内存 transcript 不被 autoDispose 回收，
    // 供随后 UI 渲染读取同一份消息。
    final sessionKeepAlive = container.listen(
      aiChatSessionProvider(_sessionId),
      (_, _) {},
    );
    addTearDown(sessionKeepAlive.close);
    container
        .read(aiModeProcessingTrackerProvider.notifier)
        .setForegroundSession(
          mode: AiSessionMode.chat,
          sessionId: _sessionId,
          foreground: true,
        );

    // FakeAgent 模拟 LLM：两轮各 thinking + 一个 tool call（无 text，不切组），
    // 第三轮返回 text 结束。chat_turn_runner 会按轮次产出多条独立 assistant 消息。
    container
        .read(aiChatRuntimeProvider(_sessionId).notifier)
        .agent = FakeAgent.create(
      responses: const [
        FakeProviderClientResponse.toolCalls([
          ToolCall(
            callId: 'call_read',
            toolName: 'Read',
            arguments: {'path': '第三章'},
          ),
        ], thinking: '先读取第三章开头，确认三人身份伏笔的顺序。'),
        FakeProviderClientResponse.toolCalls([
          ToolCall(
            callId: 'call_search',
            toolName: 'Search',
            arguments: {'query': '木匣'},
          ),
        ], thinking: '再检索木匣伏笔的落点，准备调整呈现时机。'),
        FakeProviderClientResponse.text('已经调整完成。'),
      ],
    );

    final outcome = await runHeadlessSessionTurn(
      container,
      sessionId: _sessionId,
      databasePath: databasePath,
      novel: novel,
      seed: '帮我把第三章开头改得含蓄一些。',
    );
    expect(outcome.isCompleted, isTrue, reason: 'fake turn 应正常完成');

    // 数据层：多轮产出多条独立 assistant 消息，groupMessagesForUi 合并为一条。
    final rawMessages = container
        .read(aiChatSessionProvider(_sessionId))
        .messages;
    final assistantRaw = rawMessages
        .where((m) => m.role == AiMessageRole.assistant)
        .toList();
    expect(
      assistantRaw.length,
      greaterThanOrEqualTo(2),
      reason: '多轮 tool call 应产出多条独立 assistant 消息',
    );
    final ui = groupMessagesForUi(rawMessages);
    final assistantUi = ui
        .where((m) => m.role == AiMessageRole.assistant)
        .toList();
    expect(assistantUi, hasLength(1), reason: '连续 assistant 响应合并为一条 UIMessage');

    // turn 应已彻底收尾：所有消息 isStreaming 为 false。
    // 否则 typing_indicator 的 controller.repeat() 无限动画会让随后的
    // pumpWidgetAndSettle 超时，报成「卡住」而非清晰断言。这里把隐式前提显式化。
    expect(
      rawMessages.any((m) => m.isStreaming),
      isFalse,
      reason: 'turn 收尾后不应有消息残留 streaming 态',
    );

    // 渲染前置：turn 收尾后所有消息必须已退出 streaming。
    // typing_indicator 用 controller.repeat()（永不停止动画），任一消息残留 isStreaming 会让
    // pumpWidgetAndSettle 永不 settle → 超时。此处显式断言，把隐式前提变成可读失败。
    final streamingLeft = rawMessages.where((m) => m.isStreaming).toList();
    expect(
      streamingLeft,
      isEmpty,
      reason: 'turn 收尾后不应有消息残留 isStreaming（否则 pumpWidgetAndSettle 会超时）',
    );

    // UI 层：渲染共享列表，断言只有一张「执行过程」活动卡，且两轮的工具都在卡内。
    _setDesktopSurface($, const Size(1200, 1400));
    await $.pumpWidgetAndSettle(
      UncontrolledProviderScope(
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
              home: const Scaffold(
                body: _ChatListHarness(
                  sessionId: _sessionId,
                  databasePath: null,
                  novelId: _novelId,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 仅一张活动卡（未合并时会是两张）。'Process' 为 aiToolProcessTitle 的英文文案。
    expect($('Process'), findsOneWidget);
    // 两轮的工具步骤都落在同一张卡里。
    expect($('Read'), findsOneWidget);
    expect($('Search'), findsOneWidget);
  });
}

/// 复刻 mobile/desktop 的共享渲染路径：groupMessagesForUi → ChatMessageView。
class _ChatListHarness extends ConsumerWidget {
  const _ChatListHarness({
    required this.sessionId,
    required this.databasePath,
    required this.novelId,
  });

  final String sessionId;
  final String? databasePath;
  final String? novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(
      aiChatSessionProvider(sessionId).select((session) => session.messages),
    );
    final uiMessages = groupMessagesForUi(messages);
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: uiMessages.length,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: ChatMessageView(
          message: uiMessages[index],
          activeSessionId: sessionId,
          databasePath: databasePath,
          novelId: novelId,
        ),
      ),
    );
  }
}

void _setDesktopSurface(PatrolIntegrationTester $, Size size) {
  $.tester.view.devicePixelRatio = 1.0;
  $.tester.view.physicalSize = size;
  addTearDown(() {
    $.tester.view.resetPhysicalSize();
    $.tester.view.resetDevicePixelRatio();
  });
}

const _fakeModelOption = AiModelOption(
  providerId: 'fake_provider',
  providerDisplayName: 'Fake Provider',
  model: 'fake-chat',
  kind: AiModelKind.chat,
  isDefault: true,
);

final _fakeProvider = AiProvider(
  id: _fakeModelOption.providerId,
  name: _fakeModelOption.providerDisplayName,
  builtin: false,
  type: 'openai',
  enabled: true,
  apiKey: 'test-api-key',
  baseUrl: 'https://example.invalid/v1',
  models: [_fakeModelOption.model],
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
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);

Novel _testNovel(String databasePath) {
  final now = DateTime(2026, 1, 1);
  return Novel(
    id: _novelId,
    title: 'Merge Novel',
    authorName: '',
    description: '',
    status: 'draft',
    type: 'novel',
    contentKind: contentKindNovel,
    contentDatabasePath: databasePath,
    wordCount: 0,
    draft: false,
    category: '',
    tags: const [],
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}
