// 职责: 验证插件任务在桌面和 Android 设置中的暂停、运行、取消及持久状态显示。
// 关联文件:
//   lib/shared/widgets/settings/plugins/tasks_panel.dart
//   lib/shared/services/plugins/tasks.dart
import 'dart:async';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import '../../../services/plugins/host_test.dart' show FakeExecutor, package;
import '../plugins_section_test.dart' show wrapPluginSettings;

class _TaskExecutor extends FakeExecutor {
  @override
  Future<List<Map<String, dynamic>>> activate(
    PluginManifest manifest,
    String code,
  ) async => [
    {
      'kind': 'task',
      'task': {'id': 'organize'},
    },
  ];
  @override
  Future<String?> runTask(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String taskId,
    Map<String, dynamic> run,
    AgentCancellationToken cancellation,
  ) async {
    final done = Completer<String?>();
    cancellation.onCancel(
      () => done.completeError(PluginHostError('cancelled', 'Stopped')),
    );
    return done.future;
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets(
      'task controls persist on ${platform.name}',
      (tester) async {
        final db = AppDatabase.forTest(NativeDatabase.memory());
        final host = PluginHostService(
          dao: db.pluginDao,
          registry: PluginRegistry(hostToolNames: {}),
          packages: () async {
            final plugin = package();
            return [
              PluginPackage(
                plugin.path,
                PluginManifest.fromJson({
                  ...plugin.manifest.json,
                  'tasks': {
                    'organize': {
                      'title': 'Organize memories',
                      'intervalMinutes': 60,
                    },
                  },
                }),
                plugin.code,
              ),
            ];
          },
          executorFactory: (call, stop) => _TaskExecutor(),
          platform: 'macos',
        );
        await tester.runAsync(host.start);
        addTearDown(() async {
          await host.dispose();
          await db.close();
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 900);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Future<void> settleData() async {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pumpAndSettle();
        }

        await tester.pumpWidget(wrapPluginSettings(host, platform: platform));
        await settleData();
        await tester.tap(find.byKey(const ValueKey('plugin-details-test.web')));
        await settleData();
        expect(find.text('Organize memories'), findsOneWidget);
        Future<void> tap(String key) async {
          final target = find.byKey(ValueKey(key));
          await tester.ensureVisible(target);
          await tester.tap(target);
          await settleData();
        }

        await tap('task-toggle-organize');
        expect(
          (await db.pluginTaskDao.get('test.web', 'organize'))!.enabled,
          false,
        );
        expect(find.text('Paused'), findsOneWidget);
        await tap('task-run-organize');
        expect(host.tasks.running('test.web', 'organize'), true);
        await tap('task-cancel-organize');
        expect(
          (await db.pluginTaskDao.get('test.web', 'organize'))!.lastStatus,
          'cancelled',
        );
        expect(
          (await db.pluginTaskDao.get('test.web', 'organize'))!.enabled,
          false,
        );
        tester.view.physicalSize = const Size(1000, 900);
        await tester.pumpAndSettle();
        await tap('task-toggle-organize');
        expect(
          (await db.pluginTaskDao.get('test.web', 'organize'))!.enabled,
          true,
        );
        expect(find.textContaining('Last finished:'), findsOneWidget);
        expect(find.textContaining('Next run:'), findsOneWidget);
        await tap('plugin-toggle-test.web');
        expect(host.tasks.definition('test.web', 'organize'), isNull);
        expect(find.textContaining('Next run:'), findsNothing);
        expect(
          tester
              .widget<RevericButton>(
                find.byKey(const ValueKey('task-toggle-organize')),
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}
