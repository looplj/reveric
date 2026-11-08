// 职责: 验证视频节点悬停、点击播放，以及媒体节点双击和工具条弹窗预览。
// 关联文件:
//   lib/desktop/features/production/inline_media.dart
//   lib/shared/services/production/playback_service.dart
//   test/desktop/director/harness.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:reveric/desktop/features/production/inline_media.dart';
import 'package:reveric/desktop/features/asset/media_preview.dart';
import 'package:reveric/desktop/features/production/board.dart';
import 'package:reveric/desktop/features/production/node_bar.dart';
import 'package:reveric/desktop/features/production/support.dart';
import 'package:reveric/desktop/features/production/node_card.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/production_media.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/playback_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:reveric/third/flow/vyuh_node_flow.dart' as flow;
import '../../director/harness.dart';

void main() {
  late AppDatabase assets;
  late NovelContentDatabase db;
  late ProductionCanvasService service;
  late _Playback playback;
  setUpAll(initializeDirectorTest);
  setUp(() {
    rootBundle.clear();
    assets = AppDatabase.forTest(NativeDatabase.memory());
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    service = ProductionCanvasService(
      StoryboardService(db),
      MediaLibraryService(
        assets,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      ),
      'work',
    );
    playback = _Playback();
  });
  tearDown(() async {
    await playback.dispose();
    await db.close();
    await assets.close();
  });

  Future<void> mount(
    WidgetTester tester, {
    String path = 'file_workspaces/work/video.mp4',
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [playbackServiceProvider.overrideWithValue(playback)],
        child: directorTestApp(
          Center(
            child: SizedBox(
              width: 320,
              height: 180,
              child: ProductionInlineVideo(
                service: service,
                nodeId: 'node',
                filePath: path,
                selected: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<TestGesture> hover(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(ProductionInlineVideo)));
    await tester.pump();
    return mouse;
  }

  for (final type in ['image', 'video']) {
    for (final generated in [false, true]) {
      testWidgets(
        '$type generated=$generated opens from double tap and toolbar',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final root = (await tester.runAsync(
            () => Directory.systemTemp.createTemp('production-preview-'),
          ))!;
          final path =
              'file_workspaces/work/source.${type == 'image' ? 'png' : 'mp4'}';
          try {
            await tester.runAsync(() async {
              final file = File('${root.path}/$path');
              await file.parent.create(recursive: true);
              await file.writeAsBytes(
                type == 'image'
                    ? base64Decode(
                        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                      )
                    : [1],
              );
            });
            service = ProductionCanvasService(
              StoryboardService(db),
              MediaLibraryService(assets, _Media(), root),
              'work',
            );
            await assets.assetDao.insertAsset(
              AssetsCompanion.insert(
                id: 'preview-asset',
                type: type,
                purpose: 'upload',
                novelId: const Value('work'),
                path: Value(path),
                content: Value(
                  type == 'image'
                      ? const ImageAssetContent(mimeType: 'image/png')
                      : const VideoAssetContent(mimeType: 'video/mp4'),
                ),
              ),
            );
            final episode = (await ScreenplayService(
              db,
            ).createInitialStructure()).episodeId;
            final canvas = await service.ensureCanvas(episode);
            ProductionClipRow? clip;
            late CanvasNode node;
            if (generated) {
              clip = type == 'image'
                  ? await service.shots.createImage(episode)
                  : await service.shots.createVideo(episode);
              node = await service.shots.ensureClipNode(clip.id);
              await tester.runAsync(
                () => service.adopt(node.id, 'preview-asset'),
              );
              clip = await service.shots.getShot(clip.id);
            } else {
              node = (await tester.runAsync(
                () => service.addMedia(canvas.id, 'preview-asset'),
              ))!;
            }
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  appBackgroundActiveProvider.overrideWithValue(false),
                  aiSettingsProvider.overrideWithValue(AiSettings.defaults()),
                  mediaLibraryServiceProvider.overrideWithValue(
                    service.library,
                  ),
                  playbackServiceProvider.overrideWithValue(playback),
                ],
                child: directorTestApp(
                  Builder(
                    builder: (context) => ProductionBoard(
                      service: service,
                      canvasId: canvas.id,
                      selected: node.id,
                      segments: const [],
                      segmentLabels: const {},
                      sceneLabels: const {},
                      camera: ProductionBoardCamera(),
                      onSelect: (_) {},
                      onClear: () {},
                      onConnect: (_, _, _) {},
                      onOpenDirector: (_) {},
                      bar: ProductionNodeBar(
                        service: service,
                        path: root.path,
                        node: node,
                        clip: clip,
                        segmentLabels: const {},
                        onPreview: () => productionRun(
                          context,
                          () => previewProductionAsset(
                            context,
                            service,
                            'preview-asset',
                          ),
                        ),
                        onSource: null,
                        onToSegments: null,
                        onCopy: null,
                        onDelete: () {},
                        onOpenDirector: (_) {},
                        onSelectNode: (_) {},
                        onExport: (_) async {},
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            Future<void> expectPreview() async {
              for (
                var i = 0;
                i < 50 && find.byType(MediaPreviewDialog).evaluate().isEmpty;
                i++
              ) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 10)),
                );
                await tester.pump(const Duration(milliseconds: 20));
              }
              await tester.pumpAndSettle();
              expect(find.byType(MediaPreviewDialog), findsOneWidget);
              expect(
                tester
                    .widget<MediaPreviewDialog>(find.byType(MediaPreviewDialog))
                    .path,
                path,
              );
              if (type == 'video') {
                expect(playback.player.value.isPlaying, isTrue);
                expect(
                  find.descendant(
                    of: find.byType(MediaPreviewDialog),
                    matching: find.byType(VideoPlayer),
                  ),
                  findsOneWidget,
                );
              }
              await tester.tap(find.byTooltip('Close'));
              await tester.pumpAndSettle();
              expect(find.byType(MediaPreviewDialog), findsNothing);
              expect(playback.active.value, isNull);
            }

            // 用真实双击覆盖画布与卡片内部播放手势的竞争。
            final card = find.byType(ProductionNodeCard);
            await tester.tapAt(tester.getCenter(card));
            await tester.pump(const Duration(milliseconds: 50));
            await tester.tapAt(tester.getCenter(card));
            await expectPreview();
            await tester.tap(
              find.descendant(
                of: find.byType(ProductionNodeBar),
                matching: find.text(type == 'video' ? 'Play' : 'View'),
              ),
            );
            await expectPreview();
            // 关闭后可重新双击，不残留防重入状态。
            final controller = tester
                .widget<flow.NodeFlowEditor<String, String>>(
                  find.byType(flow.NodeFlowEditor<String, String>),
                )
                .controller;
            controller.events.node!.onDoubleTap!(controller.getNode(node.id)!);
            await expectPreview();
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
            await tester.runAsync(() => root.delete(recursive: true));
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }

  testWidgets(
    'hover waits 500ms, plays an unselected node and exits to its poster',
    (tester) async {
      await mount(tester);
      final mouse = await hover(tester);
      await tester.pump(const Duration(milliseconds: 499));
      expect(playback.opens, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(playback.opens, ['video.mp4']);
      expect(playback.player.value.isPlaying, isTrue);
      expect(find.byType(VideoPlayer), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(playback.active.value, isNull);
      expect(find.byType(ProductionPlayMark), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('brief hover and removal cancel the delayed open', (
    tester,
  ) async {
    await mount(tester);
    final mouse = await hover(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 1));
    expect(playback.opens, isEmpty);
    await mouse.moveTo(tester.getCenter(find.byType(ProductionInlineVideo)));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(playback.opens, isEmpty);
  });

  testWidgets('exiting while opening releases the pending preview', (
    tester,
  ) async {
    playback.gate = Completer<void>();
    await mount(tester);
    final mouse = await hover(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(playback.opens, ['video.mp4']);
    await mouse.moveTo(Offset.zero);
    playback.gate!.complete();
    await tester.pump();
    expect(playback.active.value, isNull);
    expect(find.byType(VideoPlayer), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('click plays immediately and cancels the hover timer', (
    tester,
  ) async {
    await mount(tester);
    final mouse = await hover(tester);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(ProductionPlayMark));
    await tester.pump();
    expect(playback.opens, ['video.mp4']);
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 1));
    expect(playback.opens, hasLength(1));
    expect(playback.active.value, productionInlineOwner('node'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('replacing the video cancels the old hover timer', (
    tester,
  ) async {
    await mount(tester);
    await hover(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await mount(tester, path: 'file_workspaces/work/replacement.mp4');
    await tester.pump(const Duration(seconds: 1));
    expect(playback.opens, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

class _Media extends MediaService {
  _Media() : super(FfmpegRunner());

  @override
  Future<MediaInfo> probe(
    String path, {
    MediaCancellation? cancellation,
  }) async => const MediaInfo(
    duration: Duration(seconds: 5),
    hasAudio: false,
    hasVideo: true,
    width: 320,
    height: 180,
  );
}

class _Playback extends PlaybackService {
  final opens = <String>[];
  Completer<void>? gate;
  String? owner;
  @override
  final player = VideoPlayerController.file(File('unused.mp4'));

  @override
  Future<void> open({
    required String owner,
    required String path,
    bool play = false,
  }) async {
    this.owner = owner;
    opens.add(path.split(Platform.pathSeparator).last);
    await gate?.future;
    if (this.owner != owner) {
      return;
    }
    player.value = VideoPlayerValue(
      duration: const Duration(seconds: 5),
      size: const Size(320, 180),
      isInitialized: true,
      isPlaying: play,
    );
    active.value = owner;
  }

  @override
  Future<void> release(String owner) async {
    if (this.owner == owner) {
      this.owner = null;
      await Future<void>.value();
      active.value = null;
    }
  }

  @override
  Future<void> dispose() async {
    await player.dispose();
    active.dispose();
  }
}
