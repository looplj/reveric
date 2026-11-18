// 职责: 通过真实节点工具栏验证进入、关闭切分及点击创建后选中新分组。
// 关联文件:
//   lib/desktop/features/production/node_bar.dart
//   lib/desktop/features/production/grid/split_bar.dart
//   lib/desktop/features/production/board.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/desktop/features/production/board.dart';
import 'package:reveric/desktop/features/production/node_bar.dart';
import 'package:reveric/desktop/features/production/grid/session.dart';
import 'package:reveric/desktop/features/production/grid/split_bar.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import '../../director/harness.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(initializeDirectorTest);
  testWidgets(
    'real node toolbar closes split mode and creates/selects a new group',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('grid-entry-'),
      ))!;
      final main = app.AppDatabase.forTest(NativeDatabase.memory());
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final service = ProductionCanvasService(
        StoryboardService(db),
        MediaLibraryService(main, _ImageMedia(), root),
        'work',
      );
      late CanvasNode source;
      try {
        final episode = (await ScreenplayService(
          db,
        ).createInitialStructure()).episodeId;
        final board = await service.ensureCanvas(episode);
        source = (await tester.runAsync(() async {
          final picture = img.Image(width: 8, height: 4);
          for (var y = 0; y < 4; y++) {
            for (var x = 0; x < 8; x++) {
              picture.setPixelRgb(x, y, x * 30, y * 60, 90);
            }
          }
          final file = await File(
            '${root.path}/source.png',
          ).writeAsBytes(img.encodePng(picture));
          final asset = await service.library.importFile(
            file,
            name: 'Source.png',
            novelId: 'work',
            purpose: AssetPurpose.production_output,
            cancellation: MediaCancellation(),
          );
          return service.addMedia(board.id, asset.id);
        }))!;
        final selected = ValueNotifier<CanvasNode>(source);
        addTearDown(selected.dispose);
        final camera = ProductionBoardCamera();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appBackgroundActiveProvider.overrideWithValue(false),
              aiSettingsProvider.overrideWithValue(AiSettings.defaults()),
              availableAiModelOptionsByKindProvider(
                AiModelKind.image,
              ).overrideWithValue(const []),
            ],
            child: directorTestApp(
              ValueListenableBuilder(
                valueListenable: selected,
                builder: (_, node, _) => ProductionBoard(
                  service: service,
                  canvasId: source.canvasId,
                  selected: node.id,
                  segments: const [],
                  segmentLabels: const {},
                  sceneLabels: const {},
                  onSelect: (node) => selected.value = node,
                  onClear: () {},
                  onConnect: (_, _, _) {},
                  onOpenDirector: (_) {},
                  camera: camera,
                  bar: ProductionNodeBar(
                    service: service,
                    path: root.path,
                    node: node,
                    clip: null,
                    segmentLabels: const {},
                    onPreview: null,
                    onSource: null,
                    onToSegments: null,
                    onCopy: null,
                    onDelete: () {},
                    onOpenDirector: (_) {},
                    onSelectNode: (created) => selected.value = created,
                    onExport: (_) async {},
                    placeDerived: camera.placeDerived,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> enter() async {
          for (var attempt = 0; attempt < 30; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pumpAndSettle();
            final split = tester.widget<RevericButton>(
              find.widgetWithText(RevericButton, 'Split grid'),
            );
            if (split.onPressed != null) {
              break;
            }
          }
          await tester.tap(find.text('Split grid'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('4 (2×2)'));
          await tester.pumpAndSettle();
          expect(find.byType(ProductionSplitBar), findsOneWidget);
        }

        await enter();
        await tester.tap(find.byTooltip('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(ProductionSplitBar), findsNothing);
        expect(selected.value.id, source.id);
        await enter();
        await tester.tap(find.byKey(const ValueKey('grid-cell/1/1')));
        // flow 的节点双击识别器会等单击超时后才释放内部格子的 tap。
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        final checkedSession = ProductionGridSession.maybeOf(
          tester.element(find.byType(ProductionNodeBar)),
        )!;
        expect(checkedSession.selected, {3});
        expect(find.text('1 cells selected'), findsOneWidget);
        await tester.tap(find.text('Create storyboard group'));
        // 交替推进真实文件/isolate IO 与 Widget 的 FakeAsync 队列，等待真实按钮操作结束。
        for (
          var attempt = 0;
          attempt < 200 && selected.value.id == source.id;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(selected.value.type, canvasNodeTypeGroup);
        expect(selected.value.id, isNot(source.id));
        await tester.pumpAndSettle();
        expect(find.byType(ProductionSplitBar), findsNothing);
        final session = ProductionGridSession.maybeOf(
          tester.element(find.byType(ProductionNodeBar)),
        )!;
        expect(session.active, isFalse);
        final members = await service.groups.members(selected.value.id);
        expect(members, hasLength(1));
        expect(members.single.sortOrder, 0);
        expect(members.single.title, endsWith('2-2'));
        final edges = (await service.content(board.id)).edges;
        expect(edges.single.sourceNodeId, source.id);
        expect(edges.single.targetNodeId, selected.value.id);
        expect((await service.requireNode(source.id)).parentId, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        // Drift closes through real isolate IO, which FakeAsync never advances.
        await tester.runAsync(() async {
          await db.close();
          await main.close();
          await root.delete(recursive: true);
        });
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _ImageMedia extends MediaService {
  _ImageMedia() : super(FfmpegRunner());
  @override
  Future<MediaInfo> probe(
    String path, {
    MediaCancellation? cancellation,
  }) async => const MediaInfo(
    duration: Duration.zero,
    hasAudio: false,
    hasVideo: true,
    width: 8,
    height: 4,
  );
}
