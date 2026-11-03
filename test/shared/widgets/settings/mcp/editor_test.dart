// 职责: 验证跨平台配置预览不连接，并保留窄屏表单字段和错误提示。
// 关联文件:
//   lib/shared/widgets/settings/mcp/server_editor.dart
//   lib/desktop/widgets/agent_management/mcp_page.dart
//   lib/shared/widgets/settings/leave_guard.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:mcp_dart/mcp_dart.dart' as sdk;
import 'package:reveric/desktop/widgets/agent_management/mcp_page.dart';
import 'package:reveric/shared/components/reveric_dialog.dart';
import 'package:reveric/shared/services/mcp/diagnostics.dart';
import 'package:reveric/shared/widgets/settings/mcp/server_row.dart';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/mcp_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/leave_guard.dart';
import 'package:reveric/shared/widgets/settings/mcp/server_editor.dart';

import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/mcp/config.dart';
import 'package:reveric/shared/services/mcp/settings_service.dart';
import '../../../services/mcp/runtime_test.dart' show FakeConnection;

void main() {
  test(
    'safe error categories have distinct actionable translations without secrets',
    () {
      final errors = [
        ProcessException('secret', [], 'secret', 2),
        const McpConfigurationFailure(
          McpFailureKind.working_directory,
          'secret',
        ),
        sdk.McpError(-1, 'secret'),
        sdk.UnauthorizedError('secret'),
        sdk.UnauthorizedError('Client registration failed: secret'),
      ];
      final keys = errors
          .map(
            (error) =>
                mcpFailureLocaleKey(mcpFailureKind(error, authorization: true)),
          )
          .toList();
      expect(keys.toSet(), hasLength(errors.length));
      for (final locale in ['en', 'zh-CN']) {
        final messages =
            jsonDecode(
                  File(
                    'assets/translations/$locale/settings.json',
                  ).readAsStringSync(),
                )
                as Map;
        for (final key in keys) {
          expect(messages[key], isA<String>());
          expect(messages[key], isNot(contains('secret')));
          expect((messages[key] as String).length, greaterThan(12));
        }
      }
    },
  );
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.android,
  ]) {
    testWidgets(
      '$platform previews pasted configuration without a runtime',
      (tester) async {
        tester.view.physicalSize = Size(
          platform == TargetPlatform.android ? 360 : 700,
          800,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              mcpSettingsServiceProvider.overrideWith(
                (_) => throw StateError(
                  'Preview must not instantiate connections',
                ),
              ),
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
                  theme: RevericThemeData.reveric.toThemeData(),
                  home: RevericTheme(
                    data: RevericThemeData.reveric,
                    child: Scaffold(
                      body: McpServerEditor(
                        mobile: platform == TargetPlatform.android,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(EditableText).first, 'invalid');
        await tester.tap(find.text('Review configuration'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Check the configuration format'),
          findsOneWidget,
        );
        await tester.enterText(
          find.byType(EditableText).first,
          '{"mcpServers":{"notes":{"url":"https://example.test/mcp"}}}',
        );
        await tester.tap(find.text('Review configuration'));
        await tester.pumpAndSettle();
        expect(find.text('notes'), findsOneWidget);
        expect(find.text('Remote HTTP'), findsOneWidget);
        expect(find.text('https://example.test/mcp'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(find.byType(ListView), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant({platform}),
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
  testWidgets(
    'manual Android form validates before saving and connects after commit',
    (tester) async {
      late AppDatabase database;
      late McpSettingsService service;
      var connections = 0;
      await tester.runAsync(() async {
        database = AppDatabase.forTest(NativeDatabase.memory());
        service = McpSettingsService(
          database,
          supportsStdio: false,
          connector: (_) async {
            connections++;
            return FakeConnection();
          },
        );
        await service.initialized;
      });
      final closed = Completer<void>();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [mcpSettingsServiceProvider.overrideWithValue(service)],
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
                  home: RevericTheme(
                    data: RevericThemeData.reveric,
                    child: Builder(
                      builder: (context) => Scaffold(
                        body: TextButton(
                          onPressed: () async {
                            await showMcpServerEditor(context);
                            closed.complete();
                          },
                          child: const Text('Open fixture'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open fixture'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Manual setup'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Check the configuration format'),
          findsOneWidget,
        );
        expect(connections, 0);
        await tester.enterText(find.byType(EditableText).at(0), 'notes');
        await tester.enterText(
          find.byType(EditableText).at(2),
          'https://example.test/mcp',
        );
        await tester.runAsync(() async {
          final committed = database.appSettingsDao
              .watch(McpSettings.key)
              .firstWhere((raw) => raw != null);
          await tester.tap(find.text('Save'));
          await committed.timeout(const Duration(seconds: 3));
        });
        await tester.pumpAndSettle();
        expect(closed.isCompleted, true);
        await tester.runAsync(() async {
          final saved = McpSettings.decode(
            await database.appSettingsDao.get(McpSettings.key),
          ).servers.single;
          expect(saved.name, 'notes');
          expect(saved.enabled, true);
          await service.runtime.ensureReady('notes');
          expect(connections, 1);
        });
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await service.close();
          await database.close();
        });
      }
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
    timeout: const Timeout(Duration(seconds: 30)),
  );
  testWidgets(
    'desktop edits in place and Escape returns to the list',
    (tester) async {
      late AppDatabase database;
      late McpSettingsService service;
      await tester.runAsync(() async {
        database = AppDatabase.forTest(NativeDatabase.memory());
        service = McpSettingsService(
          database,
          supportsStdio: true,
          connector: (_) async => FakeConnection(),
        );
        await service.initialized;
      });
      final server = McpServerConfig(
        name: 'notes',
        connection: McpHttpConfig(url: 'https://example.test/mcp'),
      );
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              mcpSettingsServiceProvider.overrideWithValue(service),
              mcpSettingsProvider.overrideWith(
                (_) => Stream.value(McpSettings([server])),
              ),
              mcpConnectionStatesProvider.overrideWith(
                (_) => Stream.value(const {}),
              ),
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
                  theme: RevericThemeData.reveric.toThemeData(),
                  home: RevericTheme(
                    data: RevericThemeData.reveric,
                    child: Builder(
                      builder: (context) => Scaffold(
                        body: TextButton(
                          onPressed: () => showRevericDialog<void>(
                            context: context,
                            builder: (_) => const Dialog(
                              child: SizedBox(
                                width: 700,
                                height: 600,
                                child: Scaffold(body: McpServersRegion()),
                              ),
                            ),
                          ),
                          child: const Text('Open fixture'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open fixture'));
        await tester.pumpAndSettle();
        expect(find.text('notes'), findsOneWidget);
        expect(find.text('Remote HTTP'), findsOneWidget);

        await tester.tap(find.text('notes'));
        await tester.pumpAndSettle();
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Remote HTTP'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Cancel'), findsNothing);
        expect(find.text('notes'), findsOneWidget);

        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(find.text('Paste configuration'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Paste configuration'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await service.close();
          await database.close();
        });
      }
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
    timeout: const Timeout(Duration(seconds: 30)),
  );
  testWidgets(
    'desktop asks before leaving a changed form',
    (tester) async {
      late AppDatabase database;
      late McpSettingsService service;
      await tester.runAsync(() async {
        database = AppDatabase.forTest(NativeDatabase.memory());
        service = McpSettingsService(
          database,
          supportsStdio: true,
          connector: (_) async => FakeConnection(),
        );
        await service.initialized;
      });
      final leave = SettingsLeaveController();
      bool? left;
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      Finder inPrompt(String text) => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(text),
      );
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              mcpSettingsServiceProvider.overrideWithValue(service),
              mcpSettingsProvider.overrideWith(
                (_) => Stream.value(McpSettings([])),
              ),
              mcpConnectionStatesProvider.overrideWith(
                (_) => Stream.value(const {}),
              ),
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
                  theme: RevericThemeData.reveric.toThemeData(),
                  home: RevericTheme(
                    data: RevericThemeData.reveric,
                    child: Builder(
                      builder: (context) => Scaffold(
                        body: TextButton(
                          onPressed: () => showRevericDialog<void>(
                            context: context,
                            builder: (_) => Dialog(
                              child: SettingsLeaveScope(
                                controller: leave,
                                child: SizedBox(
                                  width: 700,
                                  height: 760,
                                  child: Scaffold(
                                    body: Column(
                                      children: [
                                        TextButton(
                                          onPressed: () async {
                                            left = await leave.confirmLeave();
                                          },
                                          child: const Text('Leave fixture'),
                                        ),
                                        const Expanded(
                                          child: McpServersRegion(),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          child: const Text('Open fixture'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open fixture'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Leave fixture'));
        await tester.pumpAndSettle();
        expect(left, true);
        expect(find.text('Unsaved changes'), findsNothing);

        await tester.tap(find.text('Manual setup'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(EditableText).at(0), 'notes');
        await tester.enterText(
          find.byType(EditableText).at(2),
          'https://example.test/mcp',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Leave fixture'));
        await tester.pumpAndSettle();
        expect(find.text('Unsaved changes'), findsOneWidget);
        await tester.tap(inPrompt('Cancel'));
        await tester.pumpAndSettle();
        expect(left, false);
        expect(find.text('Manual setup'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Unsaved changes'), findsOneWidget);
        await tester.tap(inPrompt('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Manual setup'), findsOneWidget);

        left = null;
        await tester.tap(find.text('Leave fixture'));
        await tester.pumpAndSettle();
        // 弹窗结果在 FakeAsync zone 里续接保存，真实 DB 写入需要交替让出真实时间和 pump。
        await tester.tap(inPrompt('Save'));
        for (var i = 0; i < 200 && left == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(left, true);
        await tester.runAsync(() async {
          final saved = McpSettings.decode(
            await database.appSettingsDao.get(McpSettings.key),
          ).servers.single;
          expect(saved.name, 'notes');
        });

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.tap(inPrompt('Discard'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Manual setup'), findsNothing);
        expect(
          find.text('Add a service by pasting its MCP configuration.'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await service.close();
          await database.close();
        });
      }
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
    timeout: const Timeout(Duration(seconds: 30)),
  );
  for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
    testWidgets(
      '$platform explains duplicate names instead of a generic failure',
      (tester) async {
        late AppDatabase database;
        late McpSettingsService service;
        await tester.runAsync(() async {
          database = AppDatabase.forTest(NativeDatabase.memory());
          service = McpSettingsService(
            database,
            supportsStdio: false,
            connector: (_) async => FakeConnection(),
          );
          await service.initialized;
          await service.save(
            McpServerConfig(
              name: 'docs-api',
              connection: McpHttpConfig(url: 'https://example.test/mcp'),
            ),
            create: true,
          );
        });
        Future<void> settle(Finder expected) async {
          // 保存走真实 DB，需要交替让出真实时间和 pump。
          for (var i = 0; i < 200 && expected.evaluate().isEmpty; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(expected, findsOneWidget);
        }

        tester.view.physicalSize = Size(
          platform == TargetPlatform.android ? 360 : 900,
          900,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        const taken =
            'A service named "docs-api" already exists. Choose another name.';
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                mcpSettingsServiceProvider.overrideWithValue(service),
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
                    theme: RevericThemeData.reveric.toThemeData(),
                    home: RevericTheme(
                      data: RevericThemeData.reveric,
                      child: Scaffold(
                        body: McpServerEditor(
                          mobile: platform == TargetPlatform.android,
                          onClose: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(EditableText).first,
            '{"mcpServers":{"docs_api":{"url":"https://example.test/other"}}}',
          );
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Save'));
          await settle(
            find.text(
              '"docs_api" conflicts with "docs-api". Choose another name.',
            ),
          );
          expect(find.text('Save failed'), findsNothing);

          await tester.tap(find.text('Manual setup'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(EditableText).at(0), 'docs-api');
          await tester.enterText(
            find.byType(EditableText).at(2),
            'https://example.test/other',
          );
          await tester.tap(find.text('Save'));
          await settle(find.text(taken));
          expect(find.text('Save failed'), findsNothing);

          await tester.enterText(find.byType(EditableText).at(0), 'docs');
          await tester.pumpAndSettle();
          expect(find.text(taken), findsNothing);
          await tester.runAsync(() async {
            expect(
              McpSettings.decode(
                await database.appSettingsDao.get(McpSettings.key),
              ).servers.map((s) => s.name),
              ['docs-api'],
            );
          });
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await service.close();
            await database.close();
          });
        }
      },
      variant: TargetPlatformVariant({platform}),
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}
