// 职责: 验证展开聊天右侧栏响应式隐藏/缩放、ChatSidePanel 高度分配及 ChatHeader 收起按钮与窗口标题栏避让。
// 关联文件:
//   lib/desktop/widgets/ai/chat/expanded_chat_area.dart
//   lib/desktop/widgets/ai/chat/chat_side_panel.dart
//   lib/desktop/widgets/ai/chat/header.dart
//   lib/desktop/widgets/desktop_window_frame.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/desktop-window-frame.md
//   .agents/rules/testing.md
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/widgets/ai/chat/chat_side_panel.dart';
import 'package:reveric/desktop/widgets/ai/chat/expanded_chat_area.dart';
import 'package:reveric/desktop/widgets/ai/chat/header.dart';
import 'package:reveric/desktop/widgets/desktop_window_frame.dart';
import 'package:reveric/shared/database/novel_content_database.dart'
    show WorkingChange;
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/todo.dart';
import 'package:reveric/shared/providers/ai_providers.dart'
    show AiChatRuntimeState, AiChatSessionState;
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/todo_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/chat/todo_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowManagerChannel = MethodChannel('window_manager');

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(() {
    rootBundle.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowManagerChannel, null);
  });

  group('resolveExpandedChatSidePanelWidth', () {
    test('returns null when there is no todo or pending change content', () {
      expect(
        resolveExpandedChatSidePanelWidth(1400, hasSidePanelContent: false),
        isNull,
      );
      expect(
        resolveExpandedChatSidePanelWidth(805, hasSidePanelContent: false),
        isNull,
      );
    });

    test('falls back to null when available width cannot keep chat >= 500', () {
      expect(
        resolveExpandedChatSidePanelWidth(760, hasSidePanelContent: true),
        isNull,
      );
      expect(
        resolveExpandedChatSidePanelWidth(640, hasSidePanelContent: true),
        isNull,
      );
    });

    test('scales side panel responsively within 260..360 when space fits', () {
      // 1366 窗口且左侧栏较宽（560px）时，展开区 805px：侧栏收缩到 260，聊天保留 544px。
      expect(
        resolveExpandedChatSidePanelWidth(805, hasSidePanelContent: true),
        260,
      );
      // 1366 窗口且默认左侧栏（340px）时，展开区 1025px：按 30% 取 307.5px。
      expect(
        resolveExpandedChatSidePanelWidth(1025, hasSidePanelContent: true),
        closeTo(307.5, 0.01),
      );
      // 宽屏封顶在 RevericSizes.chatPanelWidth（360px）。
      expect(
        resolveExpandedChatSidePanelWidth(1400, hasSidePanelContent: true),
        RevericSizes.chatPanelWidth,
      );
    });
  });

  testWidgets(
    'ChatSidePanel gives full height to TodoPanel without empty split divider',
    (tester) async {
      final todos = [createTodo(content: 'Outline Act 1', sessionId: 's1')];

      await tester.pumpWidget(
        _wrapApp(
          overrides: [
            sessionTodosProvider(
              's1',
            ).overrideWith(() => _FixedSessionTodos(todos)),
          ],
          child: const SizedBox(
            width: 300,
            height: 600,
            child: ChatSidePanel(
              novelId: 'n1',
              databasePath: '/tmp/n1.db',
              changes: <WorkingChange>[],
              sessionId: 's1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TodoPanel), findsOneWidget);
      expect(find.text('Outline Act 1'), findsOneWidget);
      // 侧栏根 Column 仅有顶栏下方 1 条 Divider，不再为缺失的 PendingChanges 画中间空分隔线。
      final sidePanelColumn = tester.widget<Column>(
        find
            .descendant(
              of: find.byType(ChatSidePanel),
              matching: find.byType(Column),
            )
            .first,
      );
      expect(sidePanelColumn.children.whereType<Divider>(), hasLength(1));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'ChatHeader keeps the view toggle before New conversation and clears window captions',
    (tester) async {
      const windowSize = Size(900, 600);
      await tester.binding.setSurfaceSize(windowSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final actionsKey = GlobalKey();
      final expanded = ValueNotifier(true);
      addTearDown(expanded.dispose);
      final windowCalls = <String>[];
      var collapseCount = 0;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowManagerChannel, (call) async {
            windowCalls.add(call.method);
            if (call.method == 'isMaximized') {
              return false;
            }
            return null;
          });

      await tester.pumpWidget(
        _wrapApp(
          child: DesktopWindowFrame(
            titleBarGestureExclusionKeys: [actionsKey],
            child: Column(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: expanded,
                  builder: (context, isExpanded, child) => ChatHeader(
                    sessionState: AiChatSessionState(
                      sessionId: 's1',
                      title: 'Chapter 422',
                    ),
                    runtimeState: const AiChatRuntimeState(),
                    avoidWindowCaption: !isExpanded,
                    clearWindowCaptionTrailing: isExpanded,
                    actionsGestureExclusionKey: actionsKey,
                    onRequestNewSession: () {},
                    onExpand: isExpanded ? null : () {},
                    onCollapse: isExpanded ? () => collapseCount++ : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 标题栏保持在顶部 48px，不因避让窗口按钮而整行下移。
      final headerRect = tester.getRect(find.byType(ChatHeader));
      expect(headerRect.top, 0);
      expect(headerRect.height, DesktopWindowFrame.titleBarHeight);

      final collapseFinder = find.byTooltip('Collapse chat');
      final newSessionFinder = find.byTooltip('New conversation');
      expect(collapseFinder, findsOneWidget);
      final collapseRect = tester.getRect(collapseFinder);
      final newSessionRect = tester.getRect(newSessionFinder);
      expect(collapseRect.right, lessThan(newSessionRect.left));
      expect(collapseRect.top, greaterThanOrEqualTo(0));
      expect(
        collapseRect.bottom,
        lessThanOrEqualTo(DesktopWindowFrame.titleBarHeight),
      );

      if (defaultTargetPlatform == TargetPlatform.macOS) {
        expect(newSessionRect.right, greaterThan(windowSize.width - 40));
      } else {
        // Windows / Linux：按钮右缘不得侵占右侧 138px 系统窗口按钮区。
        expect(
          newSessionRect.right,
          lessThanOrEqualTo(
            windowSize.width - DesktopWindowFrame.windowsCaptionButtonsWidth,
          ),
        );
      }

      // 双击收起按钮应触发业务回调，而不是被标题栏拖拽层抢走触发窗口最大化。
      await tester.tap(collapseFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(collapseFinder);
      await tester.pump();

      expect(collapseCount, greaterThan(0));
      expect(windowCalls, isNot(contains('maximize')));
      expect(windowCalls, isNot(contains('unmaximize')));

      expanded.value = false;
      await tester.pumpAndSettle();

      final expandRect = tester.getRect(find.byTooltip('Expand chat'));
      expect(expandRect.right, lessThan(tester.getRect(newSessionFinder).left));
      expect(collapseFinder, findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    }),
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

class _FixedSessionTodos extends SessionTodos {
  _FixedSessionTodos(this._todos);

  final List<Todo> _todos;

  @override
  Future<List<Todo>> build(String? sessionId) async => _todos;
}

Widget _wrapApp({required Widget child, List<dynamic> overrides = const []}) {
  return ProviderScope(
    overrides: [
      appBackgroundImagePathProvider.overrideWithValue(''),
      appBackgroundFitProvider.overrideWithValue(AppBackgroundFit.cover),
      appBackgroundThemeProvider.overrideWithValue(null),
      aiSettingsProvider.overrideWithValue(const AiSettings()),
      availableAiModelsProvider.overrideWithValue(const <AiModelOption>[]),
      ...overrides,
    ],
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
          theme: RevericThemeData.revericDark.toThemeData(),
          home: RevericTheme(
            data: RevericThemeData.revericDark,
            child: Scaffold(body: child),
          ),
        ),
      ),
    ),
  );
}
