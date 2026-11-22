// 职责: 验证桌面朗读配置保存、角色播放、关闭释放及 Windows/macOS 窄窗口布局。
// 关联文件:
//   lib/desktop/features/narration/dialog.dart
//   lib/desktop/features/narration/player.dart
//   lib/shared/services/screenplay/narration_service.dart

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/narration/dialog.dart';
import 'package:reveric/desktop/features/narration/button.dart';
import 'package:reveric/shared/models/screenplay_editing.dart';
import 'package:reveric/shared/widgets/screenplay/document_session.dart';
import 'package:reveric/shared/widgets/screenplay/editing_controller.dart';
import 'package:reveric/desktop/features/narration/player.dart';
import 'package:reveric/shared/components/reveric_icon_button.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/models/audio/result.dart';
import 'package:reveric/shared/models/narration.dart';
import 'package:reveric/shared/providers/narration.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/screenplay/narration_orchestrator.dart';
import 'package:reveric/shared/services/screenplay/narration_service.dart';
import '../../director/harness.dart';
import '../../../shared/models/narration_test.dart' show narrationFixture;
import '../../../shared/services/narration_service_test.dart'
    show insertNarrationProvider, narrationModel;

class _Player implements NarrationPlayer {
  bool disposed = false;
  bool playing = false;
  @override
  Future<void> play() async {
    playing = true;
  }

  @override
  Future<void> pause() async {
    playing = false;
  }

  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> dispose() async {
    disposed = true;
    playing = false;
  }

  @override
  void onFinished(void Function(Object?) callback) {}
}

class _Session implements ScreenplayDocumentSession {
  _Session() {
    final source = narrationFixture();
    controller =
        ScreenplayEditingController.forDocument(
            source.document,
            ScreenplayElementKeys(),
          )
          ..characterNames = source.characterNames
          ..locationNames = source.locationNames;
  }
  @override
  late final ScreenplayEditingController controller;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(initializeDirectorTest);
  setUp(() => rootBundle.clear());
  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    testWidgets(
      '$platform: config, playback controls and close work in a narrow window',
      (tester) async {
        tester.view.physicalSize = const Size(640, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final session = _Session();
        addTearDown(session.controller.dispose);
        final db = AppDatabase.forTest(NativeDatabase.memory());
        addTearDown(db.close);
        await insertNarrationProvider(db);
        final requests = <AudioRequest>[];
        final players = <_Player>[];
        final service = NarrationService(
          database: db,
          invoke: (_, request, _, _) async {
            requests.add(request);
            return AudioGenerationResult(Uint8List.fromList([1, 2]));
          },
        );
        await service.save(
          'work',
          NarrationSettings(
            providerId: 'speech',
            modelId: narrationModel,
            narrator: 'Kore',
            voices: {'a': 'Puck'},
            includeNarration: false,
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              narrationServiceProvider.overrideWithValue(service),
              narrationPlayerFactoryProvider.overrideWithValue((_) async {
                final player = _Player();
                players.add(player);
                return player;
              }),
            ],
            child: directorTestApp(
              Center(
                child: NarrationButton(
                  workId: 'work',
                  session: session,
                  sceneId: 's2',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('screenplay-narration')));
        await tester.pumpAndSettle();
        expect(find.byType(NarrationDialog), findsOneWidget);
        expect(find.text('Upbeat male'), findsOneWidget);
        // Edit a role voice and ensure the submitted plan uses the new value.
        await tester.tap(find.text('Upbeat male'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bright female').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Play'));
        await tester.pumpAndSettle();
        expect(requests.single.prompt, '到了。');
        expect(requests.single.parameters.voice, 'Zephyr');
        expect((await service.load('work')).voices['a'], 'Zephyr');
        expect(find.text('甲'), findsOneWidget);
        expect(find.text('到了。'), findsOneWidget);
        expect(players.single.playing, isTrue);
        await tester.tap(find.text('Pause'));
        await tester.pumpAndSettle();
        expect(players.single.playing, isFalse);
        await tester.tap(find.text('Play'));
        await tester.pumpAndSettle();
        expect(players.single.playing, isTrue);
        expect(requests.length, 1);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(NarrationDialog), findsNothing);
        expect(players.single.disposed, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(players.single.disposed, isTrue);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
  testWidgets(
    'novel dialog reads the committed draft and stops with its own navigator',
    (tester) async {
      tester.view.physicalSize = const Size(480, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      await insertNarrationProvider(db);
      final requests = <AudioRequest>[];
      final player = _Player();
      final service = NarrationService(
        database: db,
        invoke: (_, request, _, _) async {
          requests.add(request);
          return AudioGenerationResult(Uint8List.fromList([1, 2]));
        },
      );
      await service.save(
        'novel',
        NarrationSettings(
          providerId: 'speech',
          modelId: narrationModel,
          narrator: 'Kore',
        ),
        scope: NarrationSettingsScope.novel,
      );
      final controller = TextEditingController(text: 'Saved draft');
      addTearDown(controller.dispose);
      final windowOpen = ValueNotifier(true);
      addTearDown(windowOpen.dispose);
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            narrationServiceProvider.overrideWithValue(service),
            narrationPlayerFactoryProvider.overrideWithValue(
              (_) async => player,
            ),
          ],
          child: directorTestApp(
            ValueListenableBuilder(
              valueListenable: windowOpen,
              builder: (context, open, _) => open
                  ? Navigator(
                      key: navigatorKey,
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          body: Center(
                            child: ChapterNarrationButton(
                              workId: 'novel',
                              controller: controller,
                              isChapterReady: true,
                            ),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.value = const TextEditingValue(
        text: 'xin',
        composing: TextRange(start: 0, end: 3),
      );
      await tester.pump();
      final button = find.byTooltip('Read aloud');
      expect(
        tester
            .widget<RevericIconButton>(find.byType(RevericIconButton))
            .onPressed,
        isNull,
      );
      controller.text = '最新的草稿。';
      await tester.pump();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(navigatorKey.currentState!.canPop(), isTrue);
      expect(find.byType(NarrationDialog), findsOneWidget);
      expect(find.text('Voice'), findsOneWidget);
      expect(find.text('Character voices'), findsNothing);
      expect(
        find.text('Read scene headings, actions and subtitles'),
        findsNothing,
      );
      expect(requests, isEmpty);

      await tester.tap(find.text('Play'));
      await tester.pumpAndSettle();
      expect(requests.single.prompt, '最新的草稿。');
      expect(requests.single.parameters.voice, 'Kore');
      expect(player.playing, isTrue);

      windowOpen.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(NarrationDialog), findsNothing);
      expect(player.disposed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'the rollout hides narration on Android and Linux',
    (tester) async {
      final session = _Session();
      addTearDown(session.controller.dispose);
      await tester.pumpWidget(
        directorTestApp(NarrationButton(workId: 'work', session: session)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screenplay-narration')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.linux,
    }),
  );
}
