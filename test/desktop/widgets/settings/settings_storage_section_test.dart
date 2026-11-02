// 职责: 验证桌面存储页将本地存储与对象存储合并展示，选择目录后即时迁移并重新载入。
// 关联文件:
//   lib/desktop/widgets/settings/settings_storage_section.dart
//   lib/shared/widgets/file_workspace_startup_gate.dart
//   lib/shared/services/file_workspace_orchestrator.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json

import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
// Use file_selector's locked platform test interface.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/desktop/widgets/settings/settings_storage_section.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/object_storage_config.dart';
import 'package:reveric/shared/providers/object_storage.dart';
import 'package:reveric/shared/services/file_workspace_orchestrator.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/widgets/file_workspace_startup_gate.dart';
import 'package:reveric/shared/widgets/settings/object_storage_form.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DirectoryPicker extends FileSelectorPlatform {
  String? selection;
  Object? error;

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    if (error case final error?) {
      throw error;
    }
    return selection;
  }
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(done(), true);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory support;
  late Directory external;
  late FileSelectorPlatform originalPicker;
  late _DirectoryPicker picker;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() async {
    rootBundle.clear();
    root = await Directory.systemTemp.createTemp('storage-ui-');
    root = Directory(await root.resolveSymbolicLinks());
    support = await Directory(p.join(root.path, 'support')).create();
    external = await Directory(p.join(root.path, 'external')).create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path,
        );
    await RevericPaths.initialize();
    originalPicker = FileSelectorPlatform.instance;
    picker = _DirectoryPicker();
    FileSelectorPlatform.instance = picker;
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    FileSelectorPlatform.instance = originalPicker;
    await RevericPaths.initialize();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('storage migrates immediately and reloads on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(900, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final original = File(
        p.join(support.path, 'file_workspaces/work/file.txt'),
      );
      await tester.runAsync(() async {
        await original.parent.create(recursive: true);
        await original.writeAsString('source');
      });
      await tester.pumpWidget(
        _wrap(
          const FileWorkspaceStartupGate(
            loading: SizedBox.shrink(),
            child: StorageSettingsSection(),
          ),
        ),
      );
      final current = find.byKey(const ValueKey('file_workspace_current'));
      await _until(tester, () => current.evaluate().isNotEmpty);
      expect(find.byType(ObjectStorageForm), findsOneWidget);
      expect(find.text('Local storage'), findsOneWidget);
      expect(find.text('Object storage'), findsOneWidget);
      expect(find.text('Restore from File'), findsNothing);

      final choose = find.byKey(const ValueKey('file_workspace_choose'));
      await tester.tap(choose); // Cancelled native picker.
      await tester.pumpAndSettle();
      expect(find.text(external.path), findsNothing);
      picker.selection = external.path;
      await tester.tap(choose);
      await tester.pumpAndSettle();
      expect(find.text(external.path), findsOneWidget);
      expect(RevericPaths.fileWorkspaceParent, support.path);

      await tester.tap(find.byKey(const ValueKey('file_workspace_migrate')));
      await _until(
        tester,
        () =>
            RevericPaths.fileWorkspaceParent == external.path &&
            find
                .text(p.join(external.path, 'file_workspaces'))
                .evaluate()
                .isNotEmpty,
      );
      await tester.runAsync(() async {
        final copied = File(
          p.join(external.path, 'file_workspaces/work/file.txt'),
        );
        expect(await copied.readAsString(), 'source');
        expect(await original.readAsString(), 'source');
        final location = await FileWorkspaceOrchestrator().load();
        expect(location.activeParent, external.path);
      });
      tester.view.physicalSize = const Size(620, 900);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('location load failure has its own message and can be retried', (
    tester,
  ) async {
    final config = File(p.join(support.path, 'settings.local.json'));
    await tester.runAsync(() => config.writeAsString('{broken'));
    final messages = <String>[];
    final originalPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        messages.add(message ?? '');
    try {
      await tester.pumpWidget(_wrap(const StorageSettingsSection()));
      await _until(tester, () => find.text('Retry').evaluate().isNotEmpty);
      expect(
        find.text("Couldn't load the storage setting. Try again."),
        findsOneWidget,
      );
      expect(find.textContaining("Can't use this folder."), findsNothing);
      expect(messages.join('\n'), contains('Unexpected character'));
      expect(messages.join('\n'), isNot(contains('{broken')));
      await tester.runAsync(() => config.writeAsString('{}'));
      await tester.tap(find.text('Retry'));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('file_workspace_current'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text('Retry'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    } finally {
      debugPrint = originalPrint;
    }
  });

  testWidgets(
    'save failure logs OS diagnostics without exposing the user path',
    (tester) async {
      await tester.pumpWidget(_wrap(const StorageSettingsSection()));
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('file_workspace_current'))
            .evaluate()
            .isNotEmpty,
      );
      final missing = p.join(root.path, 'missing-private-location');
      final messages = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) =>
          messages.add(message ?? '');
      try {
        await tester.enterText(
          find.byKey(const ValueKey('file_workspace_target')),
          missing,
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('file_workspace_migrate')));
        await _until(
          tester,
          () => find
              .textContaining("Can't use this folder.")
              .evaluate()
              .isNotEmpty,
        );
        final log = messages.join('\n');
        expect(log, contains('select/save failed'));
        expect(log, contains('errno = 2'));
        expect(log, isNot(contains(missing)));
        expect(RevericPaths.fileWorkspaceParent, support.path);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      } finally {
        debugPrint = originalPrint;
      }
    },
  );

  testWidgets(
    'migration failure keeps business unmounted and cancel resumes original root',
    (tester) async {
      final source = File(
        p.join(support.path, 'file_workspaces/work/file.txt'),
      );
      final conflict = File(
        p.join(external.path, 'file_workspaces/work/file.txt'),
      );
      await tester.runAsync(() async {
        await source.parent.create(recursive: true);
        await source.writeAsString('source');
        await conflict.parent.create(recursive: true);
        await conflict.writeAsString('different');
      });
      await tester.pumpWidget(
        _wrap(
          const FileWorkspaceStartupGate(
            loading: SizedBox.shrink(),
            child: StorageSettingsSection(),
          ),
        ),
      );
      final current = find.byKey(const ValueKey('file_workspace_current'));
      await _until(tester, () => current.evaluate().isNotEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('file_workspace_target')),
        external.path,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('file_workspace_migrate')));
      await _until(
        tester,
        () => find.text("Move didn't finish").evaluate().isNotEmpty,
      );
      expect(current, findsNothing);
      expect(find.text('Use application directory'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await _until(tester, () => current.evaluate().isNotEmpty);
      expect(RevericPaths.fileWorkspaceParent, support.path);
      await tester.runAsync(() async {
        expect((await FileWorkspaceOrchestrator().load()).activeParent, isNull);
        expect(await source.readAsString(), 'source');
        expect(await conflict.readAsString(), 'different');
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final corruptConfig in [false, true]) {
    testWidgets(
      'startup recovery works with ${corruptConfig ? 'corrupt config' : 'missing active disk'}',
      (tester) async {
        final original = File(
          p.join(support.path, 'file_workspaces/work/file.txt'),
        );
        late File retainedExternal;
        await tester.runAsync(() async {
          await original.parent.create(recursive: true);
          await original.writeAsString('retained original');
          final orchestrator = FileWorkspaceOrchestrator();
          await orchestrator.migrate(external.path);
          final externalFile = File(
            p.join(external.path, 'file_workspaces/work/file.txt'),
          );
          await externalFile.writeAsString('latest external version');
          if (corruptConfig) {
            retainedExternal = externalFile;
            await File(
              p.join(support.path, 'settings.local.json'),
            ).writeAsString('{broken');
          } else {
            final offline = await external.rename('${external.path}-offline');
            retainedExternal = File(
              p.join(offline.path, 'file_workspaces/work/file.txt'),
            );
          }
          await RevericPaths.initialize();
        });
        await tester.pumpWidget(
          _wrap(
            const FileWorkspaceStartupGate(
              loading: SizedBox.shrink(),
              child: Text('business ready'),
            ),
          ),
        );
        await _until(
          tester,
          () => find.text('File directory unavailable').evaluate().isNotEmpty,
        );
        expect(find.text('business ready'), findsNothing);
        expect(find.text('Cancel'), findsNothing);
        final recover = find.text('Use application directory');
        expect(recover, findsOneWidget);
        await tester.tap(recover);
        await _until(
          tester,
          () => find.text('business ready').evaluate().isNotEmpty,
        );
        expect(RevericPaths.fileWorkspaceParent, support.path);
        await tester.runAsync(() async {
          final settings = await FileWorkspaceOrchestrator().load();
          expect(settings.activeParent, isNull);
          expect(await original.readAsString(), 'retained original');
          expect(
            await retainedExternal.readAsString(),
            'latest external version',
          );
          await RevericPaths.initialize();
          await FileWorkspaceOrchestrator().initialize();
          expect(RevericPaths.fileWorkspaceParent, support.path);
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}

Widget _wrap(Widget child) => ProviderScope(
  overrides: [
    objectStorageConfigProvider.overrideWith(
      (ref) => Stream.value(const ObjectStorageConfig()),
    ),
  ],
  child: EasyLocalization(
    supportedLocales: const [Locale('en')],
    startLocale: const Locale('en'),
    fallbackLocale: const Locale('en'),
    saveLocale: false,
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    child: Builder(
      builder: (context) => MaterialApp(
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        theme: RevericThemeData.reveric.toThemeData(),
        home: RevericTheme(
          data: RevericThemeData.reveric,
          child: Scaffold(body: child),
        ),
      ),
    ),
  ),
);
