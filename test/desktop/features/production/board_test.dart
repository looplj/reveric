// 职责: 验证制作画布的框选、组拖动保存与鼠标和触摸板导航。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/desktop/features/production/interaction.dart
//   lib/shared/services/production/canvas_service.dart
import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/production/board.dart';
import 'package:reveric/desktop/features/production/node_card.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:reveric/third/flow/vyuh_node_flow.dart' as flow;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('marquee, group persistence and navigation on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final main = app.AppDatabase.forTest(NativeDatabase.memory());
      final shots = StoryboardService(db);
      final episode = (await ScreenplayService(
        db,
      ).createInitialStructure()).episodeId;
      final first = await shots.ensureClipNode(
        (await shots.createImage(
          episode,
          values: {'title': 'First', 'prompt': 'First image'},
        )).id,
      );
      final second = await shots.ensureClipNode(
        (await shots.createImage(
          episode,
          values: {'title': 'Second', 'prompt': 'Second image'},
        )).id,
      );
      final service = ProductionCanvasService(
        shots,
        MediaLibraryService(
          main,
          MediaService(FfmpegRunner()),
          Directory.systemTemp,
        ),
        'work',
      );
      await service.moveNodes(first.canvasId, {
        first.id: (x: 100, y: 150),
        second.id: (x: 500, y: 150),
      });
      final selected = ValueNotifier<String?>(null);
      addTearDown(selected.dispose);
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [appBackgroundActiveProvider.overrideWithValue(false)],
            child: EasyLocalization(
              supportedLocales: const [Locale('en')],
              path: 'assets/translations',
              assetLoader: const MergingAssetLoader(),
              startLocale: const Locale('en'),
              fallbackLocale: const Locale('en'),
              child: Builder(
                builder: (context) => MaterialApp(
                  localizationsDelegates: context.localizationDelegates,
                  supportedLocales: context.supportedLocales,
                  locale: context.locale,
                  theme: RevericThemeData.reveric.toThemeData(),
                  home: RevericTheme(
                    data: RevericThemeData.reveric,
                    child: Scaffold(
                      body: ValueListenableBuilder(
                        valueListenable: selected,
                        builder: (_, id, _) => ProductionBoard(
                          service: service,
                          canvasId: first.canvasId,
                          selected: id,
                          segments: const [],
                          segmentLabels: const {},
                          sceneLabels: const {},
                          camera: ProductionBoardCamera(),
                          onSelect: (node) => selected.value = node.id,
                          onClear: () => selected.value = null,
                          onConnect: (_, _, _) {},
                          onOpenDirector: (_) {},
                          bar: const Text('Selection tools'),
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
        final controller = tester
            .widget<flow.NodeFlowEditor<String, String>>(
              find.byType(flow.NodeFlowEditor<String, String>),
            )
            .controller;
        controller.setViewport(const flow.GraphViewport());
        await tester.pumpAndSettle();
        expect(controller.theme!.connectionTheme.style.id, 'production-bezier');
        expect(
          controller.theme!.temporaryConnectionTheme.style.id,
          'production-bezier',
        );
        Future<void> drag(
          Offset from,
          Offset to, {
          int buttons = kPrimaryMouseButton,
          bool marquee = false,
        }) async {
          final pointer = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
            buttons: buttons,
          );
          await pointer.down(from);
          await tester.pump();
          await pointer.moveTo(Offset.lerp(from, to, .5)!);
          await tester.pump();
          await pointer.moveTo(to);
          if (marquee) {
            await tester.pump();
            expect(controller.isDrawingSelection, isTrue);
            expect(controller.selectedNodeIds, {first.id, second.id});
            expect(
              find.byKey(const ValueKey('production-selection-bounds')),
              findsNothing,
            );
          }
          await pointer.up();
          await tester.pumpAndSettle();
          await pointer.removePointer();
        }

        final selectionFrame = find.byKey(
          const ValueKey('production-selection-bounds'),
        );
        Rect frameBounds() => tester.getRect(selectionFrame);
        void expectFrameAroundSelection() {
          expect(selectionFrame, findsOneWidget);
          final frame = frameBounds();
          Rect? all;
          for (final id in controller.selectedNodeIds) {
            final node = controller.getNode(id)!;
            final topLeft = controller.viewport
                .toScreen(flow.GraphPosition(node.position.value))
                .offset;
            final rect = topLeft & (node.size.value * controller.viewport.zoom);
            expect(frame.contains(rect.topLeft), isTrue);
            expect(frame.contains(rect.bottomRight), isTrue);
            all = all == null ? rect : all.expandToInclude(rect);
          }
          expect(all!.left - frame.left, closeTo(RevericSpacing.x2l, .01));
          expect(frame.right - all.right, closeTo(RevericSpacing.x2l, .01));
          expect(frame.bottom - all.bottom, closeTo(RevericSpacing.x2l, .01));
          expect(
            all.top - frame.top,
            greaterThan(productionNodeHeaderExtent * controller.viewport.zoom),
          );
        }

        // Establish an editing focus, then box-select both nodes with no modifiers.
        await tester.tapAt(const Offset(200, 180));
        await tester.pumpAndSettle();
        expect(selected.value, first.id);
        expect(selectionFrame, findsNothing);
        await drag(
          const Offset(70, 110),
          const Offset(850, 470),
          marquee: true,
        );
        expect(controller.selectedNodeIds, {first.id, second.id});
        expectFrameAroundSelection();
        expect(controller.viewport.zoom, 1);
        expect(controller.viewport.x, 0);
        expect(find.text('Selection tools'), findsNothing);
        expect(
          tester
              .widgetList<ProductionNodeCard>(find.byType(ProductionNodeCard))
              .every((card) => card.selected),
          isTrue,
        );

        // A DB refresh must preserve the local multi-selection.
        await service.move(first.id, 110, 150);
        await tester.pumpAndSettle();
        expect(controller.selectedNodeIds, {first.id, second.id});
        final starts = {
          for (final node in controller.nodes.values)
            node.id: node.position.value,
        };
        final frameBeforeDrag = frameBounds();
        await drag(const Offset(200, 180), const Offset(270, 230));
        final delta =
            controller.getNode(first.id)!.position.value - starts[first.id]!;
        expect(delta.distance, greaterThan(20));
        expectFrameAroundSelection();
        expect(frameBounds().topLeft - frameBeforeDrag.topLeft, delta);
        for (final id in starts.keys) {
          final position = controller.getNode(id)!.position.value;
          expect(position - starts[id]!, delta);
          final saved = await service.requireNode(id);
          expect(position, Offset(saved.x, saved.y));
        }
        expect(controller.selectedNodeIds, {first.id, second.id});

        final groupStarts = {
          for (final node in controller.nodes.values)
            node.id: node.position.value,
        };
        final firstFlow = controller.getNode(first.id)!;
        final secondFlow = controller.getNode(second.id)!;
        final gap = Offset(
          (firstFlow.position.value.dx +
                  firstFlow.size.value.width +
                  secondFlow.position.value.dx) /
              2,
          firstFlow.position.value.dy + firstFlow.size.value.height / 2,
        );
        final groupPointer = await tester.startGesture(
          gap,
          kind: PointerDeviceKind.mouse,
        );
        await groupPointer.moveBy(const Offset(80, 40));
        await tester.pump();
        expect(controller.isDrawingSelection, isFalse);
        expect(controller.draggedNodeId, isNotNull);
        await groupPointer.up();
        await groupPointer.removePointer();
        await tester.pumpAndSettle();
        expect(controller.selectedNodeIds, {first.id, second.id});
        for (final id in groupStarts.keys) {
          final position = controller.getNode(id)!.position.value;
          expect(position - groupStarts[id]!, const Offset(80, 40));
          final saved = await service.requireNode(id);
          expect(position, Offset(saved.x, saved.y));
        }
        expectFrameAroundSelection();

        // Drag the frame itself at 50% zoom, then cancel a second drag.
        controller.setViewport(
          const flow.GraphViewport(x: 100, y: 100, zoom: .5),
        );
        await tester.pumpAndSettle();
        Offset frameHandle() =>
            Offset(frameBounds().left + 2, frameBounds().center.dy);
        final zoomStarts = {
          for (final node in controller.nodes.values)
            node.id: node.position.value,
        };
        final handle = frameHandle();
        await drag(handle, handle + const Offset(40, 20));
        final persistedGroup = <String, Offset>{};
        for (final id in zoomStarts.keys) {
          final position = controller.getNode(id)!.position.value;
          expect(position - zoomStarts[id]!, const Offset(80, 40));
          final saved = await service.requireNode(id);
          expect(position, Offset(saved.x, saved.y));
          persistedGroup[id] = position;
        }
        final cancelGroup = await tester.startGesture(
          frameHandle(),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await cancelGroup.moveBy(const Offset(30, 15));
        await tester.pump();
        expect(
          controller.getNode(first.id)!.position.value,
          isNot(persistedGroup[first.id]),
        );
        await cancelGroup.cancel();
        await cancelGroup.removePointer();
        await tester.pumpAndSettle();
        expect(controller.canvasLocked, isFalse);
        expect(controller.selectedNodeIds, {first.id, second.id});
        for (final entry in persistedGroup.entries) {
          expect(controller.getNode(entry.key)!.position.value, entry.value);
          final saved = await service.requireNode(entry.key);
          expect(Offset(saved.x, saved.y), entry.value);
        }
        // Space inside the frame navigates without moving any selected node.
        final panFrom = frameHandle();
        final groupViewport = controller.viewport;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await drag(panFrom, panFrom + const Offset(30, 20));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        expect(controller.viewport.x - groupViewport.x, closeTo(30, .01));
        expect(controller.viewport.y - groupViewport.y, closeTo(20, .01));
        for (final entry in persistedGroup.entries) {
          expect(controller.getNode(entry.key)!.position.value, entry.value);
        }
        controller.setViewport(const flow.GraphViewport());
        await tester.pumpAndSettle();

        final before = controller.viewport;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await drag(const Offset(950, 550), const Offset(1010, 590));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        expect(controller.viewport.x - before.x, closeTo(60, .01));
        expect(controller.viewport.y - before.y, closeTo(40, .01));
        expect(controller.selectedNodeIds, {first.id, second.id});
        expectFrameAroundSelection();
        final middle = controller.viewport;
        await drag(
          const Offset(950, 550),
          const Offset(980, 570),
          buttons: kMiddleMouseButton,
        );
        expect(controller.viewport.x - middle.x, closeTo(30, .01));
        expect(controller.viewport.y - middle.y, closeTo(20, .01));

        final trackpad = await tester.createGesture(
          kind: PointerDeviceKind.trackpad,
        );
        final panStart = controller.viewport;
        await trackpad.panZoomStart(const Offset(300, 300));
        await trackpad.panZoomUpdate(
          const Offset(300, 300),
          pan: const Offset(60, 40),
        );
        await tester.pump();
        await trackpad.panZoomEnd();
        await tester.pumpAndSettle();
        expect(controller.viewport.zoom, panStart.zoom);
        expect(controller.viewport.x, isNot(panStart.x));
        expect(controller.selectedNodeIds, {first.id, second.id});
        final scrollStart = controller.viewport;
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(300, 300),
            kind: PointerDeviceKind.trackpad,
            scrollDelta: Offset(15, 25),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.viewport.zoom, scrollStart.zoom);
        expect(controller.viewport.x - scrollStart.x, closeTo(-15, .01));
        expect(controller.viewport.y - scrollStart.y, closeTo(-25, .01));
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(300, 300),
            kind: PointerDeviceKind.mouse,
            scrollDelta: Offset(0, -20),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.viewport.zoom, greaterThan(scrollStart.zoom));
        final pinchZoom = controller.viewport.zoom;
        await trackpad.panZoomStart(const Offset(300, 300));
        await trackpad.panZoomUpdate(const Offset(300, 300), scale: 1.2);
        await tester.pump();
        await trackpad.panZoomEnd();
        await tester.pumpAndSettle();
        expect(controller.viewport.zoom, greaterThan(pinchZoom));
        expectFrameAroundSelection();
        controller.setViewport(const flow.GraphViewport(zoom: .43));
        await tester.pumpAndSettle();
        expectFrameAroundSelection();

        // Cancelled marquee releases navigation; a blank click clears selection.
        final cancelled = await tester.startGesture(
          const Offset(1050, 700),
          kind: PointerDeviceKind.mouse,
        );
        await cancelled.moveBy(const Offset(20, 20));
        await cancelled.cancel();
        await tester.pumpAndSettle();
        expect(controller.isDrawingSelection, isFalse);
        expect(controller.canvasLocked, isFalse);
        await tester.tapAt(const Offset(1050, 700));
        await tester.pumpAndSettle();
        expect(controller.selectedNodeIds, isEmpty);
        expect(selected.value, isNull);
        expect(selectionFrame, findsNothing);
        expect(tester.takeException(), isNull);

        // 同一输入改用途和切模式时，连线对象、视口与选择保持稳定。
        final video = await shots.createVideo(episode);
        final videoNode = await shots.ensureClipNode(video.id);
        final input = ProductionInput.node(first.id, VideoInputRole.last_frame);
        await shots.restoreInputs(video.id, [input.toJson()]);
        await tester.pumpAndSettle();
        selected.value = videoNode.id;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        controller.selectNode(videoNode.id);
        await tester.pump();
        final edgeId = '${videoNode.id}:${input.id}';
        final edge = controller.getConnection(edgeId)!;
        expect(edge.label?.text, 'Last-frame reference');
        final viewport = controller.viewport;
        await shots.restoreInputs(video.id, [
          input.withRole(VideoInputRole.first_frame).toJson(),
        ]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.getConnection(edgeId), same(edge));
        expect(edge.label?.text, 'First-frame reference');
        for (final (mode, label) in [
          ('first_last_frame', 'First frame'),
          ('reference', 'First-frame reference'),
        ]) {
          await shots.apply(video.id, {
            ...shots.snapshot((await shots.getShot(video.id))!),
            'reference_mode': mode,
          });
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(edge.label?.text, label);
          expect(controller.viewport, viewport);
          expect(controller.selectedNodeIds, {videoNode.id});
        }
        final middleA = input.withRole(VideoInputRole.middle_frame);
        final middleB = ProductionInput.node(
          second.id,
          VideoInputRole.middle_frame,
        );
        await shots.restoreInputs(video.id, [
          middleA.toJson(),
          middleB.toJson(),
        ]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(edge.label?.text, 'Middle ref. 1');
        final otherEdge = controller.getConnection(
          '${videoNode.id}:${middleB.id}',
        )!;
        expect(otherEdge.label?.text, 'Middle ref. 2');
        await shots.restoreInputs(video.id, [
          middleB.toJson(),
          middleA.toJson(),
        ]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.getConnection(edgeId), same(edge));
        expect(edge.label?.text, 'Middle ref. 2');
        expect(otherEdge.label?.text, 'Middle ref. 1');
        expect(controller.viewport, viewport);
        await shots.apply(video.id, {
          ...shots.snapshot((await shots.getShot(video.id))!),
          'reference_mode': 'first_last_frame',
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(edge.label?.text, 'Middle 2');
        expect(otherEdge.label?.text, 'Middle 1');
        // Keep the grabbed point under the pointer throughout a zoomed drag.
        for (final zoom in [.5, 1.0, 1.5]) {
          controller.setViewport(
            flow.GraphViewport(x: 150, y: 100, zoom: zoom),
          );
          controller.setNodePosition(first.id, const Offset(100, 150));
          await tester.pumpAndSettle();
          final card = find.byWidgetPredicate(
            (widget) =>
                widget is ProductionNodeCard && widget.node.id == first.id,
          );
          final start = tester.getTopLeft(card);
          final pointer = await tester.startGesture(
            tester.getCenter(card),
            kind: PointerDeviceKind.mouse,
          );
          // A fast first move must not be discarded when the drag wins.
          await pointer.moveBy(const Offset(120, 60));
          await tester.pump();
          expect(controller.draggedNodeId, first.id);
          for (var step = 0; step <= 6; step++) {
            if (step > 0) {
              await pointer.moveBy(const Offset(12, 6));
              await tester.pump();
            }
            expect(
              (tester.getTopLeft(card) -
                      start -
                      Offset(120 + 12.0 * step, 60 + 6.0 * step))
                  .distance,
              lessThan(.01),
              reason: 'zoom=$zoom, step=$step',
            );
          }
          await pointer.up();
          await pointer.removePointer();
          await tester.pumpAndSettle();
        }
        controller.clearSelection();
      } finally {
        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        await main.close();
      }
    });
  }
  testWidgets('tall composer stays above bottom canvas controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    final main = app.AppDatabase.forTest(NativeDatabase.memory());
    final shots = StoryboardService(db);
    final episode = (await ScreenplayService(
      db,
    ).createInitialStructure()).episodeId;
    final node = await shots.ensureClipNode(
      (await shots.createImage(
        episode,
        values: {'title': 'Only', 'prompt': 'Only image'},
      )).id,
    );
    final service = ProductionCanvasService(
      shots,
      MediaLibraryService(
        main,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      ),
      'work',
    );
    const composer = ValueKey('tall-composer');
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appBackgroundActiveProvider.overrideWithValue(false)],
          child: EasyLocalization(
            supportedLocales: const [Locale('en')],
            path: 'assets/translations',
            assetLoader: const MergingAssetLoader(),
            startLocale: const Locale('en'),
            fallbackLocale: const Locale('en'),
            child: Builder(
              builder: (context) => MaterialApp(
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: RevericThemeData.reveric.toThemeData(),
                home: RevericTheme(
                  data: RevericThemeData.reveric,
                  child: Scaffold(
                    body: ProductionBoard(
                      service: service,
                      canvasId: node.canvasId,
                      selected: node.id,
                      segments: const [],
                      segmentLabels: const {},
                      sceneLabels: const {},
                      camera: ProductionBoardCamera(),
                      onSelect: (_) {},
                      onClear: () {},
                      onConnect: (_, _, _) {},
                      onOpenDirector: (_) {},
                      composerBottomInset: 100,
                      composer: const SingleChildScrollView(
                        child: SizedBox(
                          key: composer,
                          width: 400,
                          height: 2000,
                        ),
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
      final controller = tester
          .widget<flow.NodeFlowEditor<String, String>>(
            find.byType(flow.NodeFlowEditor<String, String>),
          )
          .controller;
      controller.selectNode(node.id);
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byType(SingleChildScrollView).last);
      expect(viewport.bottom, lessThanOrEqualTo(600 - 100));
      controller.clearSelection();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.close();
      await main.close();
    }
  });

  testWidgets('right-click selects the node and reports the pointer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    final main = app.AppDatabase.forTest(NativeDatabase.memory());
    final shots = StoryboardService(db);
    final episode = (await ScreenplayService(
      db,
    ).createInitialStructure()).episodeId;
    final node = await shots.ensureClipNode(
      (await shots.createImage(
        episode,
        values: {'title': 'Only', 'prompt': 'Only image'},
      )).id,
    );
    final service = ProductionCanvasService(
      shots,
      MediaLibraryService(
        main,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      ),
      'work',
    );
    final selected = <String>[];
    final menus = <(String, Offset)>[];
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appBackgroundActiveProvider.overrideWithValue(false)],
          child: EasyLocalization(
            supportedLocales: const [Locale('en')],
            path: 'assets/translations',
            assetLoader: const MergingAssetLoader(),
            startLocale: const Locale('en'),
            fallbackLocale: const Locale('en'),
            child: Builder(
              builder: (context) => MaterialApp(
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: RevericThemeData.reveric.toThemeData(),
                home: RevericTheme(
                  data: RevericThemeData.reveric,
                  child: Scaffold(
                    body: ProductionBoard(
                      service: service,
                      canvasId: node.canvasId,
                      selected: null,
                      segments: const [],
                      segmentLabels: const {},
                      sceneLabels: const {},
                      camera: ProductionBoardCamera(),
                      onSelect: (row) => selected.add(row.id),
                      onContextMenu: (row, at) => menus.add((row.id, at)),
                      onClear: () {},
                      onConnect: (_, _, _) {},
                      onOpenDirector: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<flow.NodeFlowEditor<String, String>>(
            find.byType(flow.NodeFlowEditor<String, String>),
          )
          .controller;
      final at = tester.getCenter(find.byType(ProductionNodeCard));
      await tester.tapAt(
        at,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(controller.selectedNodeIds, {node.id});
      expect(selected, [node.id]);
      expect(menus, [(node.id, at)]);
      controller.clearSelection();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.close();
      await main.close();
    }
  });

  testWidgets(
    'default editor mouse pan and touch pan remain available',
    (tester) async {
      final controller = flow.NodeFlowController<String, String>();
      for (final marquee in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: flow.NodeFlowEditor<String, String>(
                controller: controller,
                theme: flow.NodeFlowTheme.light,
                nodeBuilder: (_, _) => const SizedBox.shrink(),
                marqueeSelectionOnDrag: marquee,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // Touch stays a navigation gesture even when mouse marquee is enabled.
        for (final kind in [
          PointerDeviceKind.touch,
          if (!marquee) PointerDeviceKind.mouse,
        ]) {
          final before = controller.viewport;
          await tester.dragFrom(
            const Offset(200, 200),
            const Offset(80, 50),
            kind: kind,
          );
          await tester.pumpAndSettle();
          expect(controller.viewport.x, isNot(before.x));
          expect(controller.viewport.zoom, before.zoom);
          expect(controller.isDrawingSelection, isFalse);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
