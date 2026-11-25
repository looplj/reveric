// 职责: 验证跨平台审批卡的会话隔离、冻结目标、作用域保存与失败重试。
// 关联文件:
//   lib/shared/widgets/ai/tool_operation_activity.dart
//   lib/shared/widgets/ai/tool_approval_card.dart
//   lib/shared/widgets/ai/tool_permission_editor.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/testing.md
import 'package:drift/native.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/tool_permissions.dart';
import 'package:reveric/shared/providers/tool_permissions.dart';
import 'package:reveric/shared/widgets/ai/tool_permission_editor.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/agent/tool_approval.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/tool_operation_activity.dart';
import 'package:reveric/shared/widgets/ai/tool_permission_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets(
      'approval stays in its session and saves only the chosen scope on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final broker = AiToolApprovalController();
        final container = ProviderContainer(
          overrides: [
            aiToolApprovalControllerProvider.overrideWithValue(broker),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(broker.dispose);
        ToolPermissionScope? savedScope;
        final input = <String, dynamic>{
          'model': 'frozen-model',
          'inputs': ['frames/frame-%d.png', 'clips/list.txt'],
          'input_file_count': 142,
          'input_directory_count': 12,
          'input_directories_preview': ['/media/clips', '/media/frames'],
        };
        final request = AiToolApprovalRequest(
          ownerSessionId: 'owner',
          approvalId: 'approval-1',
          callId: 'nested',
          displayCallId: 'host',
          toolName: 'Create',
          action: 'generation.video',
          permissionContext: const ToolPermissionContext(
            workId: 'work',
            sessionId: 'owner',
            episodeId: 'episode',
          ),
          targetPath: '/clips/frozen',
          arguments: input,
          saveRule: (scope, decision) async {
            savedScope = scope;
            expect(decision, ToolPermissionDecision.allow);
          },
        );
        final decision = broker.request(request);
        input['model'] = 'changed';
        Widget activity(String session) => ToolOperationActivity(
          sessionId: session,
          blocks: const [
            AiToolCallBlock(
              id: 'block',
              callId: 'host',
              toolName: 'Codemode',
              arguments: {},
              status: AiToolCallStatus.success,
            ),
          ],
        );
        await tester.pumpWidget(_wrap(container, platform, activity('other')));
        await tester.pumpAndSettle();
        expect(find.text('Generate video'), findsNothing);
        await tester.pumpWidget(_wrap(container, platform, activity('owner')));
        await tester.pumpAndSettle();
        expect(find.text('Generate video'), findsOneWidget);
        expect(find.text('/clips/frozen'), findsOneWidget);
        expect(
          find.text('frozen-model · Files to read 142 · Total directories 12'),
          findsOneWidget,
        );
        expect(find.textContaining('changed'), findsNothing);
        await tester.tap(find.text('Details'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Files to read'), findsOneWidget);
        expect(find.text('Total directories'), findsOneWidget);
        expect(find.text('Read locations (partial list)'), findsOneWidget);
        expect(find.text('frames/frame-%d.png'), findsOneWidget);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(savedScope, isNull);
        await tester.tap(find.byType(ToolPermissionSelector<int>));
        await tester.pumpAndSettle();
        await tester.tap(find.text("Don't ask again · This chat").last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Allow'));
        await tester.pumpAndSettle();
        expect(await decision, ToolApprovalOutcome.allowed);
        expect(
          savedScope,
          const ToolPermissionScope(
            ToolPermissionScopeType.session,
            workId: 'work',
            id: 'owner',
          ),
        );
        expect(broker.pending, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  testWidgets(
    'removal details list folder counts and allow from the dialog',
    (tester) async {
      final broker = AiToolApprovalController();
      final container = ProviderContainer(
        overrides: [aiToolApprovalControllerProvider.overrideWithValue(broker)],
      );
      addTearDown(container.dispose);
      addTearDown(broker.dispose);
      final request = AiToolApprovalRequest(
        ownerSessionId: 'owner',
        approvalId: 'approval-1',
        callId: 'call',
        toolName: 'Run',
        action: 'files.remove',
        permissionContext: const ToolPermissionContext(workId: ''),
        targetPath: 'media/frames',
        targetLabel: 'media/frames',
        arguments: {
          'matched_count': 903,
          'recursive': true,
          'folders': [
            {'path': 'media/frames/s2/', 'count': 301},
            {'path': 'media/frames/s3/', 'count': 602},
          ],
        },
        saveRule: (_, _) async => fail('once must not save a rule'),
      );
      final decision = broker.request(request);
      await tester.pumpWidget(
        _wrap(
          container,
          TargetPlatform.windows,
          const ToolOperationActivity(
            sessionId: 'owner',
            blocks: [
              AiToolCallBlock(
                id: 'block',
                callId: 'call',
                toolName: 'Run',
                arguments: {},
                status: AiToolCallStatus.success,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Matched items 903 · Includes subfolders'),
        findsOneWidget,
      );
      expect(find.text('media/frames/s2/'), findsNothing);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('To delete'), findsOneWidget);
      expect(find.text('media/frames/s2/'), findsOneWidget);
      expect(find.text('602 items'), findsOneWidget);
      await tester.tap(
        find.descendant(of: find.byType(Dialog), matching: find.text('Allow')),
      );
      await tester.pumpAndSettle();
      expect(await decision, ToolApprovalOutcome.allowed);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'permission editor saves a rule and restores default inheritance',
    (tester) async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final permissions = ToolPermissionService(
        db,
        episodeExists: (_, _) async => false,
      );
      final container = ProviderContainer(
        overrides: [
          toolPermissionServiceProvider.overrideWithValue(permissions),
        ],
      );
      await tester.pumpWidget(
        _wrap(
          container,
          TargetPlatform.windows,
          const ToolPermissionEditor(
            permissionContext: ToolPermissionContext(workId: ''),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.text('Delete files'), findsOneWidget);
      expect(find.text('Execute local commands'), findsOneWidget);
      final shellPermission = find.descendant(
        of: find.byKey(const ValueKey('global/shell.execute')),
        matching: find.byType(ToolPermissionSelector<String>),
      );
      await tester.tap(shellPermission);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deny').last);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        expect(
          (await permissions.resolve(
            shellExecutePermission,
            const ToolPermissionContext(workId: ''),
          )).decision,
          ToolPermissionDecision.deny,
        );
      });
      expect(find.text('Deny'), findsOneWidget);
      expect(find.text('Default'), findsNothing);
      await tester.tap(shellPermission);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask each time').hitTestable().last);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        expect(
          await db.toolPermissionDao.rules(const ToolPermissionScope.global()),
          isEmpty,
        );
      });
      expect(find.text('Deny'), findsNothing);
      expect(
        find.descendant(
          of: shellPermission,
          matching: find.text('Ask each time'),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      container.dispose();
      await tester.pumpAndSettle();
      await db.close();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'failed scoped save remains pending and never reports approval',
    (tester) async {
      final broker = AiToolApprovalController();
      final container = ProviderContainer(
        overrides: [aiToolApprovalControllerProvider.overrideWithValue(broker)],
      );
      addTearDown(container.dispose);
      addTearDown(broker.dispose);
      final request = AiToolApprovalRequest(
        ownerSessionId: 'owner',
        approvalId: 'approval-1',
        callId: 'call',
        toolName: 'Run',
        action: 'files.read',
        permissionContext: const ToolPermissionContext(workId: ''),
        targetPath: '/frozen.png',
        arguments: {},
        saveRule: (_, _) async => throw StateError('failure'),
      );
      final decision = broker.request(request);
      await tester.pumpWidget(
        _wrap(
          container,
          TargetPlatform.windows,
          const ToolOperationActivity(
            sessionId: 'owner',
            blocks: [
              AiToolCallBlock(
                id: 'block',
                callId: 'call',
                toolName: 'Run',
                arguments: {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ToolPermissionSelector<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Don't ask again · All works").last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      expect(request.isResolved, false);
      expect(
        find.text('Could not save the rule. Not authorized.'),
        findsOneWidget,
      );
      await tester.tap(find.byType(ToolPermissionSelector<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Just this once').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(await decision, ToolApprovalOutcome.denied);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'subject image approval renders under its image card',
    (tester) async {
      final broker = AiToolApprovalController();
      final container = ProviderContainer(
        overrides: [aiToolApprovalControllerProvider.overrideWithValue(broker)],
      );
      addTearDown(container.dispose);
      addTearDown(broker.dispose);
      final decision = broker.request(
        AiToolApprovalRequest(
          ownerSessionId: 'owner',
          approvalId: 'approval-1',
          callId: 'avatar-call',
          toolName: 'Run',
          action: 'generation.image',
          permissionContext: const ToolPermissionContext(workId: 'work'),
          targetPath: '/characters/c_1',
          targetLabel: 'Mage',
          arguments: const {'size': '1024x1024'},
          saveRule: (_, _) async {},
        ),
      );
      await tester.pumpWidget(
        _wrap(
          container,
          TargetPlatform.macOS,
          const ToolOperationActivity(
            sessionId: 'owner',
            blocks: [AiImageBlock(id: 'img_avatar-call', prompt: 'mage')],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Generate images'), findsOneWidget);
      expect(find.text('Mage'), findsOneWidget);
      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();
      expect(await decision, ToolApprovalOutcome.denied);
      expect(find.text('Mage'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Widget _wrap(
  ProviderContainer container,
  TargetPlatform platform,
  Widget child,
) {
  final theme = RevericThemeData.reveric;
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
          theme: theme.toThemeData().copyWith(platform: platform),
          home: RevericTheme(
            data: theme,
            child: Scaffold(body: SingleChildScrollView(child: child)),
          ),
        ),
      ),
    ),
  );
}
