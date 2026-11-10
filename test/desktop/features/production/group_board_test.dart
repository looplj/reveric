// 职责: 验证制作分组的拖动、缩放回退、真实框选删除和重开持久化。
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
import 'package:reveric/desktop/features/production/history_region.dart';
import 'package:reveric/desktop/features/production/grid/group_node.dart';
import 'package:reveric/desktop/features/production/grid/group_bar.dart';
import 'package:reveric/shared/components/reveric_checkbox.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/desktop/features/production/node_card.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
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

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('storyboard groups drag, select, convert and restore on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
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
      final service = _CountingCanvas(
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
      service.moves = 0;
      final group = await service.createStoryboardGroup(
        first.canvasId,
        layout: const StoryboardGroupLayout(cols: 2, rows: 2),
        origin: const Offset(100, 150),
        memberIds: [first.id, second.id],
        sourceNodeId: first.id,
      );
      final canvas = (await db.canvasDao.getCanvasById(first.canvasId))!;
      final history = CanvasHistory(shots, first.canvasId);
      var deletePreparations = 0;
      (String, bool)? creation;
      (String, String)? connection;
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
                      body: ProductionHistoryScope(
                        service: service,
                        canvas: canvas,
                        history: history,
                        child: ValueListenableBuilder(
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
                            beforeRemoveSelection: () async {
                              deletePreparations++;
                              return true;
                            },
                            onConnect: (source, target, _) =>
                                connection = (source.id, target.id),
                            onCreateGroupReference: (id, video, _) =>
                                creation = (id, video),
                            onOpenDirector: (_) {},
                            bar: ProductionGroupBar(
                              service: service,
                              node: group,
                            ),
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
        controller.setViewport(const flow.GraphViewport());
        await tester.pumpAndSettle();
        expect(controller.theme!.connectionTheme.style.id, 'production-bezier');
        expect(
          controller.theme!.temporaryConnectionTheme.style.id,
          'production-bezier',
        );
        final groupFlow = controller.getNode(group.id)! as ProductionFlowGroup;
        final layout = groupFlow.layout as StoryboardGroupLayout;
        expect(groupFlow.nodeIds, {first.id, second.id});
        expect(controller.getNode(first.id)!.size.value, layout.cellSize);
        expect(
          controller.getNode(second.id)!.position.value,
          groupFlow.position.value + layout.cellOffset(1),
        );
        final firstWidget = find.byWidgetPredicate(
          (w) => w is ProductionNodeCard && w.node.id == first.id,
        );
        expect(
          tester.widget<ProductionNodeCard>(firstWidget).storyboardCell,
          isTrue,
        );
        await tester.tap(find.byKey(ValueKey('group-title/${group.id}')));
        await tester.pumpAndSettle();
        expect(selected.value, group.id);
        await tester.tap(find.byType(RevericCheckbox));
        await tester.pumpAndSettle();
        expect(
          tester.widget<ProductionNodeCard>(firstWidget).storyboardNumber,
          1,
        );
        expect(
          find.byKey(ValueKey('group-empty/${group.id}/2')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('group-empty/${group.id}/3')),
          findsOneWidget,
        );
        tester.view.physicalSize = const Size(600, 900);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        tester.view.physicalSize = const Size(1200, 900);
        controller.setViewport(const flow.GraphViewport());
        await tester.pumpAndSettle();
        // Members remain selectable, but their toolbar and independent ports are disabled.
        await tester.tapAt(const Offset(200, 210));
        await tester.pumpAndSettle();
        expect(selected.value, first.id);
        expect(controller.selectedNodeIds, {first.id});
        expect(
          controller.getNode(first.id)!.ports.any((p) => p.id == 'out'),
          isTrue,
        );
        expect(find.byType(ProductionGroupBar), findsNothing);
        expect(
          controller.getNode(first.id)!.ports.every((p) => !p.isConnectable),
          isTrue,
        );
        final outlet = find.byKey(ValueKey('group-outlet/${group.id}'));
        expect(outlet, findsOneWidget);
        expect(find.byKey(ValueKey('group-fan/${group.id}')), findsOneWidget);
        await tester.tap(outlet);
        await tester.pumpAndSettle();
        expect(find.text('Reference all 2 images'), findsOneWidget);
        await tester.tap(find.text('Image generation'));
        await tester.pumpAndSettle();
        expect(creation, (group.id, false));
        final target = await service.addImage(first.canvasId);
        await service.move(target.id, 900, 150);
        await tester.pumpAndSettle();
        controller.setViewport(const flow.GraphViewport());
        await tester.pumpAndSettle();
        final connect = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await connect.down(tester.getCenter(outlet));
        await connect.moveBy(const Offset(30, 0));
        await tester.pump();
        await connect.moveTo(const Offset(940, 200));
        await tester.pump();
        await connect.up();
        await connect.removePointer();
        await tester.pumpAndSettle();
        expect(connection, (group.id, target.id));
        await service.removeNode(target.id);
        await tester.pumpAndSettle();
        service.moves = 0;
        Future<void> dragCell(
          String id,
          Offset end, {
          bool cancel = false,
        }) async {
          final start = controller
              .graphToScreen(
                flow.GraphPosition(
                  (controller.getNode(id)!.position.value &
                          controller.getNode(id)!.size.value)
                      .center,
                ),
              )
              .offset;
          final pointer = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await pointer.down(start);
          await pointer.moveTo(Offset.lerp(start, end, .5)!);
          await tester.pump();
          await pointer.moveTo(end);
          await tester.pump();
          // The lifted card follows the pointer before it lands.
          final card = tester.getCenter(
            find.descendant(
              of: find.byKey(ValueKey('storyboard-cell/$id')),
              matching: find.byType(ProductionNodeCard),
            ),
          );
          expect((card - end).distance, lessThan(1));
          if (cancel) {
            await pointer.cancel();
          } else {
            await pointer.up();
          }
          await pointer.removePointer();
          await tester.pumpAndSettle();
        }

        Offset slotCenter(int slot) =>
            groupFlow.position.value +
            layout.cellOffset(slot) +
            layout.cellSize.center(Offset.zero);
        await dragCell(first.id, slotCenter(1));
        expect((await service.requireNode(first.id)).sortOrder, 1);
        expect((await service.requireNode(second.id)).sortOrder, 0);
        await dragCell(first.id, slotCenter(3));
        expect((await service.requireNode(first.id)).sortOrder, 3);
        await dragCell(first.id, slotCenter(2), cancel: true);
        expect((await service.requireNode(first.id)).sortOrder, 3);
        await dragCell(first.id, const Offset(850, 700));
        expect((await service.requireNode(first.id)).sortOrder, 3);
        await dragCell(first.id, slotCenter(0));
        await dragCell(second.id, slotCenter(1));
        expect((await service.requireNode(first.id)).sortOrder, 0);
        expect((await service.requireNode(second.id)).sortOrder, 1);
        // Two-finger trackpad scrolling over a cell pans the canvas, never swaps.
        final trackpad = await tester.createGesture(
          kind: PointerDeviceKind.trackpad,
        );
        final panFrom = controller
            .graphToScreen(flow.GraphPosition(slotCenter(0)))
            .offset;
        final panTo = controller
            .graphToScreen(flow.GraphPosition(slotCenter(1)))
            .offset;
        await trackpad.panZoomStart(panFrom);
        await trackpad.panZoomUpdate(panFrom, pan: panTo - panFrom);
        await tester.pump();
        await trackpad.panZoomEnd();
        await trackpad.removePointer();
        await tester.pumpAndSettle();
        expect((await service.requireNode(first.id)).sortOrder, 0);
        expect((await service.requireNode(second.id)).sortOrder, 1);
        controller.setViewport(const flow.GraphViewport());
        await tester.pumpAndSettle();
        expect(service.moves, 0, reason: 'reordering never moves the group');
        final cellBefore = controller.getNode(first.id)!.position.value;
        await tester.dragFrom(const Offset(200, 210), const Offset(40, 20));
        await tester.pumpAndSettle();
        expect(controller.getNode(first.id)!.position.value, cellBefore);
        // Drag the empty lower half of the frame using an actual pointer.
        final stepsBeforeDrag = history.undoCount;
        final pointer = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await pointer.down(const Offset(200, 370));
        await tester.pump();
        await pointer.moveBy(const Offset(40, 20));
        await tester.pump();
        await pointer.moveBy(const Offset(40, 20));
        await pointer.up();
        await pointer.removePointer();
        await tester.pumpAndSettle();
        expect(service.moves, 1);
        expect(history.undoCount, stepsBeforeDrag + 1);
        await history.undo();
        await tester.pumpAndSettle();
        expect((await service.requireNode(group.id)).x, group.x);
        await history.redo();
        await tester.pumpAndSettle();
        final moved = await service.requireNode(group.id);
        expect(moved.x, greaterThan(group.x));
        for (final id in [first.id, second.id]) {
          final row = await service.requireNode(id);
          expect(
            Offset(row.x, row.y),
            Offset(moved.x, moved.y) + layout.cellOffset(row.sortOrder),
          );
        }
        // A mixed selection without its group must not move storyboard cells.
        controller.selectNodes([first.id, second.id]);
        controller.startNodeDrag(first.id);
        controller.moveNodeDrag(const Offset(50, 10));
        controller.endNodeDrag();
        await tester.pumpAndSettle();
        expect(
          controller.getNode(first.id)!.position.value,
          Offset(moved.x, moved.y),
        );
        // Convert, persist and reload; free members regain their native dimensions.
        final rects = await productionGroupMemberRects(service, group.id);
        await service.groups.toFree(
          group.id,
          rects.map((id, rect) => MapEntry(id, rect.size)),
        );
        await tester.pumpAndSettle();
        expect(
          (controller.getNode(group.id) as ProductionFlowGroup).layout,
          isA<FreeGroupLayout>(),
        );
        expect(
          tester.widget<ProductionNodeCard>(firstWidget).storyboardCell,
          isFalse,
        );
        expect(
          controller.getNode(first.id)!.size.value,
          const Size.square(220),
        );
        final free = controller.getNode(group.id)! as ProductionFlowGroup;
        final minimum = free.memberBounds;
        expect(
          free
              .constrain(const Rect.fromLTWH(0, 0, 10, 10))
              .contains(minimum.bottomRight),
          isFalse,
        );
        expect(
          free.constrain(const Rect.fromLTWH(0, 0, 10, 10)).bottomRight,
          minimum.bottomRight,
        );
        await tester.tap(find.byKey(ValueKey('group-title/${group.id}')));
        await tester.pumpAndSettle();
        controller.setViewport(const flow.GraphViewport());
        await tester.pumpAndSettle();
        final resize = find.byKey(
          ValueKey('group-resize/${group.id}/${Alignment.bottomRight}'),
        );
        expect(controller.selectedNodeIds, {group.id});
        final renderedGroup = tester.widget<ProductionGroupNode>(
          find.byType(ProductionGroupNode),
        );
        expect(
          identical(renderedGroup.group, controller.getNode(group.id)),
          isTrue,
          reason: 'renderer uses live group',
        );
        expect(renderedGroup.group.layout, isA<FreeGroupLayout>());
        expect(renderedGroup.group.isSelected, isTrue);
        final beforeResize = await service.requireNode(group.id);
        final originalFrame =
            Offset(beforeResize.x, beforeResize.y) &
            Size(beforeResize.width!, beforeResize.height!);
        final cancelling = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await cancelling.down(tester.getCenter(resize));
        await cancelling.moveBy(const Offset(40, 30));
        await tester.pump();
        await cancelling.moveBy(const Offset(40, 30));
        await tester.pump();
        expect(free.position.value & free.size.value, isNot(originalFrame));
        await cancelling.cancel();
        await cancelling.removePointer();
        await tester.pumpAndSettle();
        expect(free.position.value & free.size.value, originalFrame);
        expect((await service.requireNode(group.id)).width, beforeResize.width);
        service.groups.rejectResize = true;
        await tester.drag(resize, const Offset(60, 40));
        await tester.pumpAndSettle();
        expect(free.position.value & free.size.value, originalFrame);
        final rejectedResize = await service.requireNode(group.id);
        expect(
          Offset(rejectedResize.x, rejectedResize.y) &
              Size(rejectedResize.width!, rejectedResize.height!),
          originalFrame,
        );

        await tester.drag(resize, const Offset(60, 40));
        await tester.pumpAndSettle();
        final afterResize = await service.requireNode(group.id);
        expect(afterResize.width!, greaterThan(beforeResize.width!));
        expect(afterResize.height!, greaterThan(beforeResize.height!));
        // Moving a free member outside expands the frame without detaching it.
        controller.selectNode(first.id);
        controller.startNodeDrag(first.id);
        controller.moveNodeDrag(const Offset(-150, -100));
        controller.endNodeDrag();
        await tester.pumpAndSettle();
        final expanded = await service.requireNode(group.id);
        final outside = await service.requireNode(first.id);
        expect(outside.parentId, group.id);
        expect(
          expanded.x,
          lessThanOrEqualTo(outside.x - FreeGroupLayout.padding),
        );
        expect(
          expanded.y,
          lessThanOrEqualTo(
            outside.y - FreeGroupLayout.padding - productionNodeHeaderExtent,
          ),
        );
        final root = tester.widget<ProviderScope>(find.byType(ProviderScope));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(root);
        await tester.pumpAndSettle();
        final reopened = tester
            .widget<flow.NodeFlowEditor<String, String>>(
              find.byType(flow.NodeFlowEditor<String, String>),
            )
            .controller;
        expect(
          (reopened.getNode(group.id) as ProductionFlowGroup).layout,
          isA<FreeGroupLayout>(),
        );
        final stored = await service.requireNode(first.id);
        expect(
          reopened.getNode(first.id)!.position.value,
          Offset(stored.x, stored.y),
        );
        // Real marquee selects cells without their container; the visible action deletes through the service.
        await service.groups.toStoryboard(
          group.id,
          await productionGroupMemberRects(service, group.id),
        );
        await tester.pumpAndSettle();
        reopened.setViewport(const flow.GraphViewport(x: 100, y: 100));
        await tester.pumpAndSettle();
        final currentGroup = reopened.getNode(group.id)! as ProductionFlowGroup;
        final currentLayout = currentGroup.layout as StoryboardGroupLayout;
        final topLeft = currentGroup.position.value + const Offset(100, 100);
        final marquee = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await marquee.down(topLeft + const Offset(-20, -30));
        await tester.pump();
        await marquee.moveTo(
          topLeft +
              Offset(
                currentLayout.frameSize.width + 10,
                currentLayout.cellSize.height + 10,
              ),
        );
        await tester.pump();
        await marquee.up();
        await marquee.removePointer();
        await tester.pumpAndSettle();
        expect(reopened.selectedNodeIds, {first.id, second.id});
        expect((await service.content(first.canvasId)).edges, hasLength(1));
        await tester.tap(
          find.byKey(const ValueKey('production-delete-selection')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(RevericButton, 'Delete').last);
        await tester.pumpAndSettle();
        expect(deletePreparations, 1);
        expect(await service.groups.members(group.id), isEmpty);
        expect((await service.content(first.canvasId)).nodes.map((n) => n.id), [
          group.id,
        ]);
        expect((await service.content(first.canvasId)).edges, isEmpty);
        expect(reopened.connections, isEmpty);
        for (final member in [first, second]) {
          final deleted = await (db.select(
            db.canvasNodes,
          )..where((t) => t.id.equals(member.id))).getSingle();
          expect(
            deleted.deletedAt.isAfter(DateTime.fromMillisecondsSinceEpoch(0)),
            isTrue,
          );
          final clip = await (db.select(
            db.productionClips,
          )..where((t) => t.id.equals(member.clipId!))).getSingle();
          expect(
            clip.deletedAt.isAfter(DateTime.fromMillisecondsSinceEpoch(0)),
            isTrue,
          );
        }
        expect(
          find.byKey(ValueKey('group-empty/${group.id}/0')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        history.dispose();
        await db.close();
        await main.close();
        debugDefaultTargetPlatformOverride = null;
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}

class _CountingCanvas extends ProductionCanvasService {
  _CountingCanvas(super.shots, super.library, super.novelId);
  int moves = 0;
  late final _ResizeRejectGroups _groups = _ResizeRejectGroups(shots);
  @override
  _ResizeRejectGroups get groups => _groups;
  @override
  Future<void> moveNodes(
    String canvasId,
    Map<String, ({double x, double y})> positions, {
    CanvasHistory? history,
  }) {
    moves++;
    return super.moveNodes(canvasId, positions, history: history);
  }
}

class _ResizeRejectGroups extends ProductionGroupService {
  _ResizeRejectGroups(super.shots);
  bool rejectResize = false;
  @override
  Future<void> resizeFree(
    String groupId,
    Rect frame, {
    CanvasHistory? history,
  }) async {
    if (rejectResize) {
      rejectResize = false;
      throw StateError('resize write rejected');
    }
    await super.resizeFree(groupId, frame, history: history);
  }
}
