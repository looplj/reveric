// 职责: 验证导演台即时保存、关闭等待、失败重试和窄屏编辑区存活。
// 关联文件:
//   lib/shared/widgets/director/workspace.dart
//   test/desktop/director/harness.dart
import 'dart:async';
import 'package:reveric/shared/models/director/document.dart';
import 'package:reveric/shared/models/director/sampling.dart';
import 'package:reveric/shared/widgets/director/inspector.dart';
import 'package:reveric/shared/widgets/director/frame_content.dart';
import 'package:drift/native.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/database/novel_content_daos/screenplay_dao.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/providers/production_view.dart';
import 'package:reveric/shared/services/director/session.dart';
import 'package:reveric/shared/services/screenplay/staging.dart';
import 'package:reveric/shared/widgets/screenplay/director_workspace.dart';
import 'harness.dart';
import 'package:reveric/shared/services/system_tray_service.dart';
import 'package:reveric/desktop/widgets/desktop_save_shortcut.dart';

class FailingDao extends ScreenplayDao {
  FailingDao(super.db);
  bool failWrites = false;
  @override
  Future<int> saveStaging(
    String id,
    Map<String, dynamic> document, {
    required String title,
    required DateTime savedAt,
    String? checkpointId,
    Map<String, dynamic>? initialDocument,
  }) {
    if (failWrites) {
      return Future.error(StateError('test disk write failure'));
    }
    return super.saveStaging(
      id,
      document,
      title: title,
      savedAt: savedAt,
      checkpointId: checkpointId,
      initialDocument: initialDocument,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeDirectorTest);
  setUp(() => rootBundle.clear());

  late VideoStagingBinding binding;
  late NovelContentDatabase db;
  late FailingDao dao;
  var parentSaves = 0;
  setUp(() async {
    parentSaves = 0;
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    await db.screenplayDao.createStaging('staging', 'Scene');
    dao = FailingDao(db);
  });
  tearDown(() => db.close());

  Future<DirectorSession> mount(
    WidgetTester tester,
    Size size, {
    ScreenplayDirectorRecognize? recognize,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    binding = VideoStagingBinding(dao, 'staging');
    final session = await binding.load(camera: 'Camera');
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      binding.dispose();
      session.dispose();
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      directorTestApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: DesktopSaveShortcut(
                    onSave: () async {
                      parentSaves++;
                    },
                    child: ProviderScope(
                      child: ScreenplayDirectorWorkspace(
                        databasePath: 'staging.db',
                        binding: binding,
                        onClose: () => Navigator.of(context).pop(),
                        viewportBuilder: (_, _) => const SizedBox.expand(),
                        recognize: recognize,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('Launch'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Launch'));
    await tester.pumpAndSettle();
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(ScreenplayDirectorWorkspace)),
      ).read(productionSubpageProvider('staging.db'))?.stagingId,
      'staging',
    );
    return session;
  }

  testWidgets(
    'restored actor and its invalid dependent camera recover through inputs and autosave',
    (tester) async {
      binding = VideoStagingBinding(dao, 'staging');
      final s = await binding.load(camera: 'Camera');
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        binding.dispose();
        s.dispose();
        await tester.pumpAndSettle();
      });
      s.history.addObject('actor.male.v1', 'Actor');
      final healthy = s.history.document;
      final actor = healthy.objects.single['id'],
          camera = healthy.cameras.single['id'];
      s.restore(
        healthy.mutate((j) {
          j['objects'][0]['pose']['root_offset_y'] = 50;
          j['cameras'][0]['position'] = [0, 1.6, 0];
          j['cameras'][0]['camera_target'] = {
            'type': 'object',
            'object_id': actor,
            'offset': [0, 1, 0],
          };
        }),
      );
      await binding.flush();
      s.seek(12);
      s.select(actor);
      await tester.pumpWidget(
        directorTestApp(
          Column(
            children: [
              SizedBox(
                height: 130,
                child: DirectorFrameContent(
                  session: s,
                  builder: (_) =>
                      const SizedBox(key: ValueKey('dependent-frame-valid')),
                ),
              ),
              Expanded(
                child: Inspector(session: s, onAlignToView: (_) {}),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> edit(String key, String text) async {
        final field = find.byKey(ValueKey(key));
        await tester.ensureVisible(field);
        await tester.enterText(field, text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        await binding.flush();
        expect(tester.takeException(), isNull);
      }

      await tester.tap(find.text('Pose').last);
      await tester.pumpAndSettle();
      await edit('director-pose-value:root_offset_y', '0');
      expect(s.error, isNull);
      final intermediate = DirectorDocument.fromJson(
        (await dao.getStaging('staging'))!.document!,
      );
      expect(intermediate.objects.single['pose']['root_offset_y'], 0);
      expect(
        () => sampleDocument(intermediate, 12),
        throwsA(
          isA<DocumentError>().having(
            (e) => e.reason,
            'reason',
            'parallel_reference_up',
          ),
        ),
      );
      final diagnostic = tester.widget<Text>(
        find.byKey(const ValueKey('director-inspector-diagnostic')),
      );
      expect(diagnostic.data, contains(camera));
      s.select(camera);
      await tester.pumpAndSettle();
      final before = s.history.document.businessContent,
          undo = s.history.undoCount;
      await edit('director-field:camera_position:1', '2');
      expect(s.error, contains('parallel_reference_up'));
      expect(s.history.document.businessContent, before);
      expect(s.history.undoCount, undo);
      await edit('director-field:camera_position:1', '1.6');
      await edit('director-field:camera_position:2', '2');
      expect(s.error, isNull);
      expect(
        find.byKey(const ValueKey('dependent-frame-valid')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('director-inspector-diagnostic')),
        findsNothing,
      );
      final reopened = VideoStagingBinding(dao, 'staging');
      await reopened.load(camera: 'Camera');
      final sample = sampleDocument(reopened.session.history.document, 12);
      expect(sample.objects.single['pose']['root_offset_y'], 0);
      expect(sample.cameras[camera]!['position'], [0, 1.6, 2]);
      reopened.dispose();
      reopened.session.dispose();
    },
  );

  testWidgets('hidden tray exit commits focused input without another frame', (
    tester,
  ) async {
    final session = await mount(tester, const Size(1200, 900));
    await tester.enterText(
      find.byKey(const ValueKey('director-field:duration')),
      '6',
    );
    await tester.pump();
    expect(session.hasPendingInput, isTrue);
    const channels = [
      MethodChannel('reveric/process_exit'),
      MethodChannel('window_manager'),
    ];
    for (final channel in channels) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(tester.binding.framesEnabled, isFalse);
    int? exitCode;
    try {
      // Real event-loop time, deliberately no pump/frame until exit completes.
      await tester.runAsync(() async {
        await SystemTrayService().exitApplicationForTesting(
          (code) {
            exitCode = code;
          },
          timeout: const Duration(milliseconds: 500),
          unlock: () {},
          cleanExit: () async {},
        );
      });
      expect(exitCode, 0);
      expect(session.hasPendingInput, isFalse);
      expect(
        (await dao.getStaging('staging'))!.document!['duration_frames'],
        144,
      );
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (final channel in channels) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      }
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
    'system back commits a valid focused field and flushes before closing',
    (tester) async {
      final session = await mount(tester, const Size(1200, 900));
      await tester.enterText(
        find.byKey(const ValueKey('director-field:duration')),
        '6',
      );
      await tester.pump();
      expect(session.hasPendingInput, isTrue);
      final gate = Completer<void>();
      final blocked = dao.serializeStaging('staging', () => gate.future);
      await tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(ScreenplayDirectorWorkspace), findsOneWidget);
      gate.complete();
      await blocked;
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Launch'), findsOneWidget);
      expect(
        (await dao.getStaging('staging'))!.document!['duration_frames'],
        144,
      );
    },
  );

  testWidgets(
    'failed blur save keeps editor open and explicit save retries pending edits',
    (tester) async {
      final session = await mount(tester, const Size(1200, 900));
      await tester.enterText(
        find.byKey(const ValueKey('director-field:duration')),
        '6',
      );
      await tester.pump();
      dao.failWrites = true;
      await tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(ScreenplayDirectorWorkspace), findsOneWidget);
      expect(session.error, isNotNull);
      expect((await dao.getStaging('staging'))!.document, isNull);
      dao.failWrites = false;
      await session.save();
      await tester.pumpAndSettle();
      expect(
        (await dao.getStaging('staging'))!.document!['duration_frames'],
        144,
      );
      await tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .maybePop();
      await tester.pumpAndSettle();
      expect(find.text('Launch'), findsOneWidget);
    },
  );

  testWidgets(
    'Cmd+S in a focused field stays with the director save callback',
    (tester) async {
      await mount(tester, const Size(1200, 900));
      await tester.tap(find.byKey(const ValueKey('director-field:duration')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS, platform: 'macos');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect((await dao.getStaging('staging'))!.document, isNull);
      expect(parentSaves, 0);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Launch'), findsNothing);
    },
  );

  testWidgets(
    'Ctrl+S with invalid pending input neither saves nor invokes the parent',
    (tester) async {
      final session = await mount(tester, const Size(1200, 900));
      await tester.enterText(
        find.byKey(const ValueKey('director-field:duration')),
        '48',
      );
      await tester.pump();
      await tester.pump();
      expect(session.hasPendingInput, isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS, platform: 'windows');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect((await dao.getStaging('staging'))!.document, isNull);
      expect(parentSaves, 0);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('valid edits are saved before leaving without asking', (
    tester,
  ) async {
    final session = await mount(tester, const Size(1200, 900));
    session.history.addObject('prop.cube.v1', 'Saved prop');
    await tester.pumpAndSettle();
    expect(
      (await dao.getStaging('staging'))!.document!['objects'][0]['name'],
      'Saved prop',
    );
    await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Launch'), findsOneWidget);
    expect(
      (await dao.getStaging('staging'))!.document!['objects'][0]['name'],
      'Saved prop',
    );
  });

  testWidgets('AI scan entry appears only when the host supports it', (
    tester,
  ) async {
    await mount(tester, const Size(1200, 900));
    expect(
      find.byKey(const ValueKey('director-recognize-image')),
      findsNothing,
    );
  });

  testWidgets(
    'AI scan reset clears the stage, persists before handoff and stays undoable',
    (tester) async {
      Map<String, dynamic>? persisted;
      final session = await mount(
        tester,
        const Size(1200, 900),
        recognize: (context, {required reset}) async {
          await reset();
          persisted = (await dao.getStaging('staging'))!.document;
        },
      );
      session.history.addObject('actor.male.v1', 'Actor');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('director-recognize-image')));
      await tester.pumpAndSettle();
      expect(session.history.document.objects, isEmpty);
      expect(persisted!['objects'], isEmpty);
      expect(persisted!['cameras'], hasLength(1));
      session.history.undo();
      expect(session.history.document.objects, hasLength(1));
    },
  );

  testWidgets(
    'compact layout retains unapplied fields across section switches',
    (tester) async {
      final session = await mount(tester, const Size(375, 812));
      session.history.addObject('actor.male.v1', 'Actor');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Properties').first);
      await tester.pumpAndSettle();
      final duration = find.byKey(const ValueKey('director-field:duration'));
      await tester.ensureVisible(duration);
      await tester.enterText(duration, '48');
      await tester.pump();
      await tester.tap(find.text('Objects').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Properties').first);
      await tester.pumpAndSettle();
      expect(session.hasPendingInput, isTrue);
      expect(tester.widget<TextField>(duration).controller!.text, '48');
      expect(tester.takeException(), isNull);
      tester.view.physicalSize = const Size(812, 375);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(session.hasPendingInput, isTrue);
      expect(tester.widget<TextField>(duration).controller!.text, '48');
    },
  );
}
