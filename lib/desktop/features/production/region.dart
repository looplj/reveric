// 职责: 复用剧本与独立画布的制作主体，组合剪辑、导演台并管理编辑离开保护与媒体导入。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/desktop/features/production/composer.dart
//   lib/desktop/features/storyboard/region.dart
//   lib/desktop/features/production/scene_recognition.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/file-access.md
import 'dart:async';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import '../../../shared/models/ai_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/components/reveric_segmented_control.dart';
import '../../../shared/database/app_database.dart' show Novel;
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/models/screenplay.dart';
import '../../../shared/providers/maps_providers.dart';
import '../../../shared/providers/production_media.dart';
import '../../../shared/providers/production_images.dart';
import '../../../shared/providers/production_audio.dart';
import '../../../shared/providers/production_chat.dart';
import '../../../shared/providers/production_view.dart';
import '../../../shared/providers/video_tasks.dart';
import '../../../shared/providers/workspace_navigation_provider.dart';
import '../../../shared/services/storyboard/edit_orchestrator.dart';
import '../../../shared/providers/storyboard.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/models/video/request.dart';
import '../../../shared/models/video/channels.dart';
import '../../../shared/models/production/image_request.dart';
import '../../../shared/models/audio/channels.dart';
import '../../../shared/services/production/audio_generate_orchestrator.dart';
import '../../../shared/services/production/generate_orchestrator.dart';
import '../../../shared/services/production/voices.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/screenplay_workspace_state_provider.dart';
import '../../../shared/services/ai/chat_attachments.dart' show NamedChatFile;
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/staging_export_orchestrator.dart';
import '../../../shared/services/production/ffmpeg_runner.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import '../../../shared/widgets/screenplay/labels.dart';
import '../../../shared/widgets/screenplay/loading.dart';
import '../canvas/widgets/floating_cluster.dart';
import '../screenplay/chrome.dart';
import '../storyboard/region.dart';
import 'board.dart';
import 'history_region.dart';
import 'history_actions.dart';
import '../editing/shell.dart';
import 'canvas_controls.dart';
import 'canvas_empty.dart';
import 'text_composer.dart';
import 'text_node.dart';
import '../../../shared/models/content_kind.dart';
import 'subject_picker.dart';
import 'node_bar.dart';
import 'depth_dialog.dart';
import 'node_card.dart' show productionAspect, productionNodeSize;
import 'composer.dart';
import 'edit_session.dart';
import 'support.dart';
import 'spec_panel.dart';
import 'task_status.dart';
import 'style_button.dart';
import 'image_composer.dart';
import 'audio_composer.dart';
import 'grid.dart';
import 'scene_recognition.dart';
import '../../../shared/widgets/screenplay/director_shell.dart';

/// 向聊天发一段制片相关的话；带 [files] 时这些文件作为附件放在正文之前。
/// [send] 为 true 时打开聊天后直接发送，否则只预填、由用户补完再发。
/// 带 [model] 时用该模型和 [effort] 档位新开对话并直接发送。
typedef ProductionAsk =
    void Function(
      String prompt, {
      List<XFile> files,
      bool send,
      AiModelOption? model,
      String? effort,
    });

class ProductionRegion extends HookConsumerWidget {
  const ProductionRegion({
    super.key,
    required this.novel,
    required this.registerFlush,
    this.selectedClipId,
    this.onAsk,
    this.chat,
  });
  final Novel novel;
  final ValueChanged<Future<void> Function()?> registerFlush;
  final String? selectedClipId;
  final ProductionAsk? onAsk;

  /// 浮在画布、剪辑和导演台上方的聊天层，由宿主按当前视图决定是否提供。
  final Widget? chat;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(
      screenplayWorkspaceStateControllerProvider(
        novel.id,
        novel.contentDatabasePath!,
      ),
    );
    final askRef = useRef(onAsk)..value = onAsk;
    final flushRef = useRef(registerFlush)..value = registerFlush;
    // 聊天状态只更新浮层；制作内容按作品与导航目标更新，自身的数据订阅仍照常重建。
    // 宿主每次 build 都会创建回调，通过 ref 转发以免缓存旧闭包。
    final content = useMemoized(
      () {
        if (workspace.episodeId == null) {
          return const SizedBox.shrink();
        }
        final path = novel.contentDatabasePath!;
        final episodeId = workspace.episodeId!;
        final ask = onAsk == null
            ? null
            : (
                String prompt, {
                List<XFile> files = const [],
                bool send = false,
                AiModelOption? model,
                String? effort,
              }) => askRef.value?.call(
                prompt,
                files: files,
                send: send,
                model: model,
                effort: effort,
              );
        Future<void> recognize(
          BuildContext context, {
          required Future<void> Function() reset,
        }) async {
          final service = ProductionCanvasService(
            ref.read(storyboardServiceProvider(path)),
            ref.read(mediaLibraryServiceProvider),
            novel.id,
          );
          final canvas = await service.ensureCanvas(episodeId);
          if (!context.mounted) {
            return;
          }
          final choice = await showSceneRecognitionDialog(
            context,
            service: service,
            canvasId: canvas.id,
          );
          if (choice == null) {
            return;
          }
          final asset = await service.requireAsset(
            choice.assetId,
            type: 'image',
          );
          if (choice.overwrite) {
            await reset();
          }
          final file = service.library.resolve(asset);
          ask!(
            sceneRecognitionPrompt(overwrite: choice.overwrite),
            files: [NamedChatFile.path(file, name: p.basename(file))],
          );
        }

        return EditingShell(
          novelId: novel.id,
          identity: (
            path: novel.contentDatabasePath!,
            episodeId: workspace.episodeId!,
          ),
          registerFlush: (flush) => flushRef.value(flush),
          builder: (openEditing, registerEditing) => ScreenplayDirectorShell(
            novelId: novel.id,
            databasePath: novel.contentDatabasePath!,
            recognize: ask == null ? null : recognize,
            navigationTarget: (
              workspace.episodeId,
              workspace.sceneId,
              selectedClipId,
            ),
            registerFlush: registerEditing,
            builder: (open, register) => ProductionHistoryRegion(
              key: ValueKey(workspace.episodeId),
              novel: novel,
              episodeId: workspace.episodeId!,
              child: ProductionTextAsk(
                ask: ask == null
                    ? null
                    : (prompt, {model, effort}) =>
                          ask(prompt, send: true, model: model, effort: effort),
                child: ProductionCanvasRegion(
                  key: ValueKey(workspace.episodeId),
                  novel: novel,
                  episodeId: workspace.episodeId!,
                  registerFlush: register,
                  selectedClipId: selectedClipId,
                  sceneActions: ProductionSceneActions(
                    ask: ask,
                    openDirector: open,
                    openEditing: openEditing,
                  ),
                ),
              ),
            ),
          ),
        );
      },
      [
        novel,
        workspace.episodeId,
        workspace.sceneId,
        selectedClipId,
        onAsk != null,
      ],
    );
    if (workspace.episodeId == null) {
      if (!workspace.isHydrated) {
        return const ScreenplayLoading();
      }
      return Center(child: Text(context.t(LocaleKeys.storyboardNoEpisode)));
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        // 放在两个子页面外，打开剪辑或导演台时不会随底层画布一起隐藏。
        if (chat != null)
          Positioned.fill(
            top: ScreenplayRegionToolbar.floatingExtent,
            child: chat!,
          ),
      ],
    );
  }
}

class ProductionCanvasRegion extends HookConsumerWidget {
  const ProductionCanvasRegion({
    super.key,
    required this.novel,
    required this.episodeId,
    required this.registerFlush,
    this.selectedClipId,
    required this.sceneActions,
  });
  final Novel novel;
  final String episodeId;
  final ValueChanged<Future<void> Function()?> registerFlush;
  final String? selectedClipId;
  final ProductionSceneActions sceneActions;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textAsk = ProductionTextAsk.of(context);
    final canvasWork = novel.contentKind == contentKindCanvas;
    final path = novel.contentDatabasePath!;
    final shots = ref.watch(storyboardServiceProvider(path));
    final library = ref.watch(mediaLibraryServiceProvider);
    final scope = ProductionHistoryScope.of(context);
    final service = scope.service;
    final history = scope.history;
    final canvas = AsyncSnapshot<CanvasEntry>.withData(
      ConnectionState.done,
      scope.canvas,
    );
    final viewProvider = productionViewProvider(novel.id);
    final viewState = ref.read(viewProvider.notifier);
    // 进入时停在左栏选的视图；之后左栏再切换由下方的 listen 带着焦点处理。
    final view = useState(
      canvasWork ? ProductionViewMode.canvas : ref.read(viewProvider),
    );
    final chatProvider = productionChatProvider(novel.id);
    final chatState = ref.read(chatProvider.notifier);
    final chatOpen = ref.watch(chatProvider.select((s) => s.open));
    // 视图和聊天外壳在同一次事件里一起切：编辑页同帧把面板从右栏挪进画布浮窗，
    // 面板实例（草稿、滚动位置）得以保留。
    void setView(ProductionViewMode next) {
      view.value = next;
      // 画布和列表都用浮窗聊天，只有分镜把聊天放回右栏。
      chatState.setCanvas(next != ProductionViewMode.segments);
      viewState.set(next);
    }

    useEffect(() {
      // 从左栏「画布」进入时聊天外壳也要跟着进浮窗。
      final initial = view.value;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        chatState.setCanvas(initial != ProductionViewMode.segments);
      });
      return () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          chatState.setCanvas(false);
        });
      };
    }, [chatState]);
    final workspace = canvasWork
        ? null
        : ref.watch(screenplayWorkspaceStateControllerProvider(novel.id, path));
    final clips =
        ref.watch(storyboardShotsProvider(path, episodeId)).value ??
        <ProductionClipRow>[];
    // 画布上要平移到的节点（第二栏点场次），不选中、不打开编辑浮层。
    final revealed = useState<String?>(null);
    final focusedClip = useState<String?>(selectedClipId);
    final composerEpoch = useState(0);
    final selected = useState<CanvasNode?>(null);
    // 失败提醒上的「查看原因」：选中节点并展开「结果」；n 递增让工具条重新挂载后展开。
    final resultsRequest = useState<({String nodeId, int n})?>(null);
    // 节点右键：在指针处打开工具条的「…」菜单；n 递增表示一次新请求。
    final menuRequest = useState<({String nodeId, Offset at, int n})?>(null);
    final imageJobs = ref.watch(imageTaskServiceProvider);
    final session = scope.session!;
    final camera = useMemoized(ProductionBoardCamera.new);
    final clipSnapshot = useStream(
      useMemoized(
        () => selected.value?.clipId == null
            ? const Stream<ProductionClipRow?>.empty()
            : (service.db.select(service.db.productionClips)
                    ..where((t) => t.id.equals(selected.value!.clipId!)))
                  .watchSingleOrNull(),
        [service, selected.value?.clipId],
      ),
    );
    // useStream 换流后保留上一份数据；只认属于当前选中节点的片段，免得工具条沿用上一个片段。
    final selectedClip = clipSnapshot.data?.id == selected.value?.clipId
        ? clipSnapshot.data
        : null;
    final busy = useState(false);
    final registration = useRef(registerFlush)..value = registerFlush;
    useEffect(() {
      Future<void> flush() async {
        if (!await session.close()) {
          throw StateError('Production editing retained');
        }
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          registration.value(flush);
        }
      });
      return () {
        registration.value(null);
      };
    }, [session]);
    Future<void> run(Future<void> Function() action) async {
      if (busy.value) {
        return;
      }
      busy.value = true;
      await productionRun(context, action);
      if (context.mounted) {
        busy.value = false;
      }
    }

    Future<void> select(CanvasNode node) async {
      if (selected.value?.id != node.id && !await session.close()) {
        return;
      }
      if (context.mounted) {
        if (selected.value?.id != node.id) {
          resultsRequest.value = null;
          menuRequest.value = null;
        }
        selected.value = node;
        revealed.value = null;
        focusedClip.value = node.clipId;
        setView(ProductionViewMode.canvas);
      }
    }

    Future<void> openResults(String clipId) async {
      if (!await session.close()) {
        return;
      }
      final node = await service.ensureShotNode(clipId);
      await select(node);
      if (context.mounted && selected.value?.id == node.id) {
        // 展开结果会重挂工具条，不能把旧的右键请求再弹一次。
        menuRequest.value = null;
        resultsRequest.value = (
          nodeId: node.id,
          n: (resultsRequest.value?.n ?? 0) + 1,
        );
      }
    }

    Future<void> retrySave(ProductionSaveRetry task) async {
      if ((await service.library.database.generationTaskDao.getById(
            task.taskId,
          ))?.kind.name ==
          'audio') {
        await ref.read(audioTaskServiceProvider).retrySaveOutput(task.taskId);
      } else if (task.image) {
        await imageJobs.retrySaveOutput(task.taskId);
      } else {
        final tasks = await ref.read(videoTaskServiceProvider.future);
        await tasks.retryDownload(task.taskId);
        await ref.read(productionResultServiceProvider).recover();
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.productionRetrySaveHint)),
          ),
        );
      }
    }

    final taskActions = ProductionTaskActions(
      openResults: (clipId) => run(() => openResults(clipId)),
      retrySave: (task) => run(() => retrySave(task)),
    );

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!context.mounted || selectedClipId == null) {
          return;
        }
        await run(() async {
          if (!await session.close()) {
            return;
          }
          final clip = await shots.getShot(selectedClipId!);
          if (!context.mounted || clip == null) {
            return;
          }
          focusedClip.value = clip.id;
          if (view.value == ProductionViewMode.canvas || clip.sceneId == null) {
            await select(await service.ensureShotNode(clip.id));
          }
        });
      });
      return null;
    }, [selectedClipId]);

    // 画布视图下在第二栏点场次：平移到这一场的第一个片段节点。
    final lastScene = useRef(workspace?.sceneId);
    useEffect(() {
      final sceneId = workspace?.sceneId;
      if (sceneId == lastScene.value) {
        return null;
      }
      lastScene.value = sceneId;
      final first = clips.where((c) => c.sceneId == sceneId).firstOrNull;
      if (view.value != ProductionViewMode.canvas || first == null) {
        return null;
      }
      productionRun(context, () async {
        if (!await session.close()) {
          return;
        }
        final node = await service.ensureShotNode(first.id);
        if (context.mounted) {
          selected.value = null;
          revealed.value = node.id;
        }
      });
      return null;
    }, [workspace?.sceneId]);

    // 第二栏高亮跟着焦点走：片段视图跟定位的片段，画布视图跟选中节点。
    // 先记下 lastScene，免得上面的「点场次就平移」把选中节点挤掉。
    final focusClipId = view.value == ProductionViewMode.canvas
        ? selected.value?.clipId
        : focusedClip.value;
    final focusScene = clips
        .where((c) => c.id == focusClipId)
        .firstOrNull
        ?.sceneId;
    useEffect(() {
      if (focusScene == null || focusScene == workspace?.sceneId) {
        return null;
      }
      lastScene.value = focusScene;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          final provider = screenplayWorkspaceStateControllerProvider(
            novel.id,
            path,
          );
          ref
              .read(provider.notifier)
              .update(ref.read(provider).copyWith(sceneId: focusScene));
        }
      });
      return null;
    }, [focusScene]);

    // 两个视图之间带着焦点切换：列表里定位的片段到画布上选中它的节点，反之亦然。
    Future<void> switchView(ProductionViewMode next) async {
      if (view.value == next || !await session.close()) {
        return;
      }
      if (next == ProductionViewMode.canvas && focusedClip.value != null) {
        final clip = await shots.getShot(focusedClip.value!);
        if (clip != null && context.mounted) {
          await select(await service.ensureShotNode(clip.id));
          return;
        }
      }
      if (!context.mounted) {
        return;
      }
      if (next == ProductionViewMode.segments) {
        final clip = selected.value?.clipId == null
            ? null
            : await shots.getShot(selected.value!.clipId!);
        if (!context.mounted) {
          return;
        }
        focusedClip.value = clip?.sceneId != null ? clip!.id : null;
      }
      selected.value = null;
      revealed.value = null;
      setView(next);
    }

    // 左栏切「分镜」/「画布」：走同一条带焦点的切换；被拒时把左栏高亮拉回实际视图。
    if (!canvasWork) {
      ref.listen(viewProvider, (_, next) async {
        if (next == view.value) {
          return;
        }
        await run(() => switchView(next));
        if (context.mounted && view.value != next) {
          viewState.set(view.value);
        }
      });
    }

    // 画布色带写场次，片段节点写「段 场号-序号」，序号按成片顺序。
    final scenes =
        (canvasWork
            ? null
            : ref.watch(screenplayScenesProvider(path, episodeId)).value) ??
        const <ScreenplaySceneSummary>[];
    final locationNames = {
      for (final location
          in (canvasWork ? null : ref.watch(locationsProvider(path)).value) ??
              const <Location>[])
        location.id: location.name,
    };
    final sceneLabels = <String, String>{};
    final sceneNumbers = <String, int>{};
    for (final scene in scenes) {
      final (time, interiorExterior) = screenplaySceneCondition(context, scene);
      sceneNumbers[scene.id] = scene.sceneNumber;
      sceneLabels[scene.id] = [
        screenplaySceneLabel(context, scene),
        if (scene.locationId != null)
          screenplaySceneLocation(context, scene, locationNames: locationNames),
        [time, interiorExterior].where((s) => s.isNotEmpty).join(' / '),
      ].where((s) => s.isNotEmpty).join(' · ');
    }
    final segmentLabels = <String, String>{};
    final sceneCounts = <String, int>{};
    for (final clip in canvasWork ? <ProductionClipRow>[] : clips) {
      final n = sceneCounts.update(
        clip.sceneId ?? '',
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      segmentLabels[clip.id] = context.t(
        LocaleKeys.productionExportSegment,
        namedArgs: {'number': '${sceneNumbers[clip.sceneId] ?? '?'}-$n'},
      );
    }
    final openingResults =
        selected.value != null &&
        resultsRequest.value?.nodeId == selected.value!.id;
    final selectedAsset = useStream(
      useMemoized(
        () => service.library.database.assetDao
            .watchAssets(novelId: novel.id)
            .map(
              (rows) => rows
                  .where((a) => a.id == selected.value?.mediaAssetId)
                  .firstOrNull,
            ),
        [service, selected.value?.mediaAssetId],
      ),
    ).data;
    final previewTarget = selected.value?.isGenerationNode == true
        ? selectedClip?.adoptedAssetId
        : selectedAsset?.id;

    void source(String sceneId) {
      final provider = screenplayWorkspaceStateControllerProvider(
        novel.id,
        path,
      );
      ref
          .read(provider.notifier)
          .update(ref.read(provider).copyWith(sceneId: sceneId));
      ref
          .read(workspaceNavigationProvider.notifier)
          .request(
            WorkspaceNavigationRequest(
              section: NovelWorkspaceSection.screenplay_script,
              itemId: sceneId,
            ),
          );
    }

    // 新建的节点放在当前视口中心，再选中它。
    Future<CanvasNode> placeNew(
      CanvasNode node, {
      bool selectNode = true,
    }) async {
      final center = camera.center;
      if (center != null) {
        final clip = node.clipId == null
            ? null
            : await service.shots.getShot(node.clipId!);
        final size = productionNodeSize(
          node,
          aspect: productionAspect(clip?.ratio),
        );
        await service.move(
          node.id,
          center.dx - size.width / 2,
          center.dy - size.height / 2,
        );
        node = await service.requireNode(node.id);
      }
      if (selectNode) {
        await select(node);
      }
      return node;
    }

    Future<CanvasNode> createAndPlace(
      Future<CanvasNode> Function() create,
    ) async {
      final node = await recordProductionChange(
        context,
        const [],
        () async => placeNew(await create(), selectNode: false),
      );
      await select(node);
      return node;
    }

    // 从资产库选一个素材放到画布；types 为空表示不限图片 / 视频 / 音频。
    Future<void> placeAsset(Set<String>? types) async {
      if (!await session.close() || !context.mounted) {
        return;
      }
      final asset = types == null
          ? await pickProductionAsset(context, service)
          : await pickProductionAsset(context, service, types: types);
      if (asset != null) {
        await createAndPlace(() => service.addMedia(canvas.data!.id, asset.id));
      }
    }

    Future<void> importMedia() async {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Media',
            extensions: [
              'png',
              'jpg',
              'jpeg',
              'webp',
              'mp4',
              'mov',
              'mp3',
              'wav',
              'm4a',
            ],
          ),
        ],
      );
      if (file == null) {
        return;
      }
      final asset = await library.importFile(
        File(file.path),
        name: file.name,
        novelId: novel.id,
        purpose: AssetPurpose.production_upload,
        cancellation: MediaCancellation(),
      );
      await placeNew(await service.addMedia(canvas.data!.id, asset.id));
    }

    // 打开导演台节点对应的调度。
    Future<void> openDirector(CanvasNode node) async {
      if (await session.close()) {
        await sceneActions.openDirector(
          node.stagingId!,
          canvas: (service: service, nodeId: node.id),
        );
      }
    }

    // 场次色带底部的「分镜」：排在这一场末尾，位置由场次排位决定，不挪到视口中心。
    Future<void> addSegment(String sceneId) async {
      if (!await session.close() || !context.mounted) {
        return;
      }
      final overlay = ref.read(workingOverlayServiceProvider(path));
      final node = await recordProductionChange(context, const [], () async {
        final clip = await StoryboardEditOrchestrator().create(
          service: shots,
          overlay: overlay,
          sceneId: sceneId,
          values: const {
            'duration_ms': ProductionCanvasService.defaultDurationMs,
          },
        );
        return service.ensureShotNode(clip.id);
      });
      await select(node);
    }

    Future<void> add(ProductionAddKind kind) async {
      if (!await session.close()) {
        return;
      }
      final overlay = ref.read(workingOverlayServiceProvider(path));
      switch (kind) {
        case ProductionAddKind.video:
          await createAndPlace(
            () => service.addFree(canvas.data!.id, overlay: overlay),
          );
        case ProductionAddKind.image:
          await createAndPlace(() => service.addImage(canvas.data!.id));
        case ProductionAddKind.character:
        case ProductionAddKind.location:
        case ProductionAddKind.compendium:
          if (!context.mounted) {
            return;
          }
          final subjectKind = switch (kind) {
            ProductionAddKind.character => SubjectKind.character,
            ProductionAddKind.location => SubjectKind.location,
            _ => SubjectKind.compendium,
          };
          final subjectId = await pickProductionSubject(
            context,
            service,
            kind: subjectKind,
          );
          if (subjectId != null) {
            await createAndPlace(
              () => service.addSubject(
                canvas.data!.id,
                characterId: kind == ProductionAddKind.character
                    ? subjectId
                    : null,
                locationId: kind == ProductionAddKind.location
                    ? subjectId
                    : null,
                itemId: kind == ProductionAddKind.compendium ? subjectId : null,
              ),
            );
          }
        case ProductionAddKind.text:
          await createAndPlace(
            () => service.addText(
              canvas.data!.id,
              title: context.t(LocaleKeys.productionText),
            ),
          );
        case ProductionAddKind.editing:
          await createAndPlace(
            () => service.addEditing(
              canvas.data!.id,
              title: context.t(LocaleKeys.editingTitle),
            ),
          );
        case ProductionAddKind.audio:
          await createAndPlace(() => service.addAudio(canvas.data!.id));
        case ProductionAddKind.director:
          final count = (await service.db.canvasDao.getNodesByCanvas(
            canvas.data!.id,
          )).where((n) => n.type == canvasNodeTypeStaging).length;
          if (!context.mounted) {
            return;
          }
          final node = await createAndPlace(
            () => service.addDirector(
              canvas.data!.id,
              context.t(
                LocaleKeys.productionDirectorName,
                namedArgs: {'n': '${count + 1}'},
              ),
            ),
          );
          await openDirector(await service.requireNode(node.id));
      }
    }

    // 拖线松手：只有一种用途直接挂上，否则在落点选用途；再把来源补成目标节点的一条输入。
    Future<void> connect(
      CanvasNode source,
      CanvasNode target,
      Offset at,
    ) async {
      if (!await session.close()) {
        return;
      }
      if (source.type == canvasNodeTypeText) {
        final clip = (await shots.getShot(target.clipId!))!;
        final inputs = await service.draftInputs(target.id);
        if (!inputs.any(
          (input) => input.isPrompt && input.refId == source.id,
        )) {
          await service.saveDraft(
            nodeId: target.id,
            values: shots.snapshot(clip),
            inputs: [...inputs, ProductionInput.text(source.id)],
            overlay: ref.read(workingOverlayServiceProvider(path)),
            history: history,
          );
        }
        if (context.mounted) {
          composerEpoch.value++;
          await select(await service.requireNode(target.id));
        }
        return;
      }
      if (source.type == canvasNodeTypeGroup) {
        await service.attachStoryboardGroup(
          source.id,
          target.id,
          overlay: ref.read(workingOverlayServiceProvider(path)),
          history: history,
        );
        if (context.mounted) {
          composerEpoch.value++;
          await select(await service.requireNode(target.id));
        }
        return;
      }
      final shot = target.clipId == null
          ? null
          : await shots.getShot(target.clipId!);
      final request = shotVideoRequest(shot!);
      final audioProvider =
          target.type == canvasNodeTypeAudio && shot.providerId != null
          ? await service.library.database.aiProviderDao.getById(
              shot.providerId!,
            )
          : null;
      final audioChannel = lookupAudioChannelModel(
        audioProvider?.type ?? '',
        shot.modelId,
      );
      final asset = source.clipId == null
          ? await service.requireAsset(source.mediaAssetId!)
          : null;
      final videoProvider =
          target.type == canvasNodeTypeVideo && shot.providerId != null
          ? await service.library.database.aiProviderDao.getById(
              shot.providerId!,
            )
          : null;
      final supportsMiddleFrames =
          !productionUsesFrames(request.mode) ||
          (lookupVideoChannelModel(
                    videoProvider?.type ?? '',
                    shot.modelId,
                  )?.capabilities.maxMiddleFrames ??
                  0) >
              0;
      final roles =
          (target.type == canvasNodeTypeImage
                  ? const [VideoInputRole.reference_image]
                  : target.type == canvasNodeTypeAudio
                  ? [
                      for (final role in [
                        VideoInputRole.reference_audio,
                        VideoInputRole.reference_image,
                      ])
                        if (audioChannel?.capabilities.references.containsKey(
                              role.kind.name,
                            ) ==
                            true)
                          role,
                    ]
                  : productionRoles(request.mode))
              .where(
                (r) =>
                    r.kind.name == (asset?.type ?? source.type) &&
                    (r != VideoInputRole.middle_frame || supportsMiddleFrames),
              )
              .toList();
      if (!context.mounted || roles.isEmpty) {
        return;
      }
      Future<void> attach(VideoInputRole picked) =>
          recordProductionChange(context, [target.id], () async {
            final existing = await service.draftInputs(target.id);
            final input =
                existing
                    .where(
                      (i) =>
                          i.refType == ProductionInputType.node &&
                          i.refId == source.id &&
                          i.role == picked,
                    )
                    .firstOrNull ??
                ProductionInput.node(source.id, picked);
            if (target.type == canvasNodeTypeAudio) {
              final next = [
                ...existing.where((e) => e.identity != input.identity),
                input,
              ];
              await resolveAudioReferences(
                service,
                shot.modelId ?? '',
                next,
                providerId: shot.providerId,
              );
              await service.saveAudio(
                nodeId: target.id,
                prompt: shot.prompt,
                providerId: shot.providerId,
                modelId: shot.modelId,
                inputs: next,
                overlay: ref.read(workingOverlayServiceProvider(path)),
              );
            } else if (target.type == canvasNodeTypeImage) {
              await service.saveImage(
                nodeId: target.id,
                draft: ProductionImageDraft(
                  prompt: shot.prompt,
                  modelId: shot.modelId ?? '',
                  providerId: shot.providerId,
                  ratio: shot.ratio,
                  resolution: shot.resolution,
                ),
                inputs: [
                  ...existing.where((e) => e.identity != input.identity),
                  input,
                ],
                overlay: ref.read(workingOverlayServiceProvider(path)),
              );
            } else {
              final fresh = !existing.any((e) => e.identity == input.identity);
              await service.save(
                nodeId: target.id,
                request: request,
                providerId: shot.providerId,
                inputs: [
                  ...existing.where((e) => e.identity != input.identity),
                  fresh && !productionUsesFrames(request.mode)
                      ? await service.withDefaultVoice(input)
                      : input,
                ],
                overlay: ref.read(workingOverlayServiceProvider(path)),
              );
            }
            if (context.mounted) {
              composerEpoch.value++;
              await select(await service.requireNode(target.id));
            }
          });

      if (roles.length == 1) {
        await attach(roles.single);
      } else {
        await showRevericContextMenu(
          context: context,
          position: at,
          minWidth: 140,
          entries: [
            for (final role in roles)
              RevericMenuItem(
                label: productionRole(context, role),
                onTap: () => run(() => attach(role)),
              ),
          ],
        );
      }
    }

    final toolbar = ScreenplayRegionToolbar(
      // 统计在底栏；剧集名在第二栏。分镜和画布是左栏的两个入口，
      // 分镜视图不挂顶栏，顶栏左侧只切画布 / 列表两种排布。
      // 两种排布共用画布的胶囊顶栏，切换时顶栏外观不跳。
      floating: true,
      leading: _ViewSwitch(
        selected: view.value,
        segments: [
          RevericSegment(
            value: ProductionViewMode.canvas,
            label: context.t(LocaleKeys.productionCanvas),
            icon: RevericIcons.flow_arrow,
          ),
          RevericSegment(
            value: ProductionViewMode.grid,
            label: context.t(LocaleKeys.productionList),
            icon: RevericIcons.category_outlined,
          ),
        ],
        onChanged: (next) => run(() => switchView(next)),
      ),
      trailing: [
        if (Platform.isMacOS || Platform.isWindows)
          const DepthTaskStatusButton(),
        Flexible(child: ProductionScreenplayStyle(service: service)),
        const _TopSeparator(),
        ProductionSpecChip(path: path, episodeId: episodeId),
        const _TopSeparator(),
        RevericIconButton(
          icon: RevericIcons.scissors_outlined,
          tooltip: context.t(LocaleKeys.editingTitle),
          onPressed: busy.value
              ? null
              : () => run(() async {
                  if (await session.close()) {
                    sceneActions.openEditing?.call();
                  }
                }),
        ),
      ],
    );

    // 工具条只在画布和列表里挂出；画布视图里它浮在满铺的画布上，
    // 列表是滚动列表，内容从工具条下方开始，免得首行被胶囊盖住。
    return Stack(
      children: [
        Positioned.fill(
          top: view.value == ProductionViewMode.grid
              ? ScreenplayRegionToolbar.floatingExtent
              : 0,
          child: Stack(
            children: [
              Positioned.fill(
                child: view.value == ProductionViewMode.segments
                    ? StoryboardRegion(
                        novel: novel,
                        editSession: session,
                        focusedClipId: focusedClip.value,
                        sceneActions: sceneActions,
                        taskActions: taskActions,
                        onProduce: (shotId) => run(() async {
                          if (await session.close()) {
                            await select(await service.ensureShotNode(shotId));
                          }
                        }),
                      )
                    : canvas.hasError
                    ? Center(
                        child: Text(context.t(LocaleKeys.productionFailed)),
                      )
                    : !canvas.hasData
                    ? const Center(child: CircularProgressIndicator())
                    : view.value == ProductionViewMode.grid
                    ? ProductionNodeGrid(
                        service: service,
                        canvasId: canvas.data!.id,
                        segments: clips,
                        onOpen: select,
                        taskActions: taskActions,
                      )
                    : ProductionHistoryActions(
                        history: history,
                        beforeRestore: session.close,
                        onRestored: () async {
                          final id = selected.value?.id;
                          final restored = id == null
                              ? null
                              : await service.db.canvasDao.getNodeById(id);
                          if (context.mounted) {
                            selected.value = restored;
                            composerEpoch.value++;
                          }
                        },
                        child: ProductionBoard(
                          service: service,
                          canvasId: canvas.data!.id,
                          topInset: canvasWork
                              ? 0
                              : ScreenplayRegionToolbar.floatingExtent,
                          empty: canvasWork
                              ? CanvasEmptyStart(
                                  onUpload: () =>
                                      run(sceneActions.uploadScript!),
                                  onPrompt: () =>
                                      run(() => add(ProductionAddKind.video)),
                                  onImport: () => run(importMedia),
                                )
                              : null,
                          selected: selected.value?.id,
                          revealed: revealed.value,
                          segments: clips,
                          segmentLabels: segmentLabels,
                          sceneLabels: sceneLabels,
                          onAddSegment: canvasWork
                              ? null
                              : (sceneId) => run(() => addSegment(sceneId)),
                          onSelect: select,
                          onContextMenu: (node, at) async {
                            await select(node);
                            if (context.mounted &&
                                selected.value?.id == node.id) {
                              menuRequest.value = (
                                nodeId: node.id,
                                at: at,
                                n: (menuRequest.value?.n ?? 0) + 1,
                              );
                            }
                          },
                          beforeRemoveSelection: session.close,
                          onClear: () => run(() async {
                            if (selected.value != null &&
                                await session.close()) {
                              selected.value = null;
                            }
                          }),
                          camera: camera,
                          taskActions: taskActions,
                          onDisconnect: (inputId, targetId) => run(() async {
                            if (!await session.close()) {
                              return;
                            }
                            final target = await service.requireNode(targetId);
                            final clip = (await shots.getShot(target.clipId!))!;
                            await service.saveDraft(
                              history: history,
                              nodeId: targetId,
                              values: shots.snapshot(clip),
                              inputs: clip.inputs
                                  .where((input) => input.id != inputId)
                                  .toList(),
                              overlay: ref.read(
                                workingOverlayServiceProvider(path),
                              ),
                            );
                          }),
                          onCreateGroupReference: (groupId, video, at) => run(
                            () async {
                              if (!await session.close()) {
                                return;
                              }
                              final placement = camera.placeDerived(
                                groupId,
                                audio: false,
                                size: productionCardSize(video ? 16 / 9 : 1),
                              );
                              final node = await service.addStoryboardReference(
                                groupId,
                                history: history,
                                video: video,
                                overlay: ref.read(
                                  workingOverlayServiceProvider(path),
                                ),
                                placement:
                                    placement ??
                                    (at: (x: at.dx, y: at.dy), moves: const {}),
                              );
                              if (context.mounted) {
                                await select(node);
                              }
                            },
                          ),
                          onConnect: (source, target, at) =>
                              run(() => connect(source, target, at)),
                          onOpenDirector: (node) =>
                              run(() => openDirector(node)),
                          bar: selected.value == null
                              ? null
                              : ProductionNodeBar(
                                  key: ValueKey(
                                    'bar/${selected.value!.id}/${openingResults ? resultsRequest.value!.n : 0}',
                                  ),
                                  openResults: openingResults,
                                  menuRequest:
                                      menuRequest.value?.nodeId ==
                                          selected.value!.id
                                      ? (
                                          at: menuRequest.value!.at,
                                          n: menuRequest.value!.n,
                                        )
                                      : null,
                                  service: service,
                                  path: path,
                                  node: selected.value!,
                                  clip: selectedClip,
                                  segmentLabels: segmentLabels,
                                  onPreview: previewTarget == null
                                      ? null
                                      : () => productionRun(
                                          context,
                                          () => previewProductionAsset(
                                            context,
                                            service,
                                            previewTarget,
                                          ),
                                        ),
                                  onSource: selectedClip?.sceneId == null
                                      ? null
                                      : () => run(() async {
                                          if (await session.close()) {
                                            source(selectedClip!.sceneId!);
                                          }
                                        }),
                                  onToSegments: selectedClip?.sceneId == null
                                      ? null
                                      : () => run(() async {
                                          if (!await session.close()) {
                                            return;
                                          }
                                          if (context.mounted) {
                                            focusedClip.value =
                                                selectedClip!.id;
                                            selected.value = null;
                                            setView(
                                              ProductionViewMode.segments,
                                            );
                                          }
                                        }),
                                  onCopy:
                                      selectedClip == null ||
                                          selectedClip.sceneId != null
                                      ? null
                                      : () => run(() async {
                                          if (await session.close()) {
                                            await select(
                                              await service.copyVideo(
                                                selected.value!.id,
                                                history: history,
                                                overlay: ref.read(
                                                  workingOverlayServiceProvider(
                                                    path,
                                                  ),
                                                ),
                                              ),
                                            );
                                          }
                                        }),
                                  onDelete: () => run(() async {
                                    final node = selected.value;
                                    if (node == null ||
                                        !await session.close() ||
                                        !context.mounted) {
                                      return;
                                    }
                                    final confirmed = await showConfirmDialog(
                                      context,
                                      title: context.t(LocaleKeys.commonDelete),
                                      message: context.t(
                                        node.clipId == null
                                            ? LocaleKeys
                                                  .productionDeleteNodeConfirm
                                            : LocaleKeys
                                                  .storyboardDeleteConfirm,
                                        namedArgs: {'title': node.title},
                                      ),
                                      confirmLabel: context.t(
                                        LocaleKeys.commonDelete,
                                      ),
                                      variant: ConfirmDialogVariant.error,
                                    );
                                    if (!confirmed || !context.mounted) {
                                      return;
                                    }
                                    await service.removeNode(
                                      node.id,
                                      history: history,
                                    );
                                    if (context.mounted &&
                                        selected.value?.id == node.id) {
                                      selected.value = null;
                                    }
                                  }),
                                  onOpenDirector: (node) =>
                                      run(() => openDirector(node)),
                                  onSelectNode: (node) =>
                                      run(() => select(node)),
                                  placeDerived: camera.placeDerived,
                                  // 导出可能要渲染整段，不占用画布的 busy，别的操作照常进行。
                                  onExport: (still) => productionRun(
                                    context,
                                    () => StagingExportOrchestrator().run(
                                      canvas: service,
                                      directorNodeId: selected.value!.id,
                                      still: still,
                                    ),
                                  ),
                                ),
                          composer: selected.value?.type == canvasNodeTypeText
                              ? textAsk == null
                                    ? null
                                    : SizedBox(
                                        width: RevericSizes
                                            .productionComposerWidth,
                                        child: ProductionTextComposer(
                                          key: ValueKey(selected.value!.id),
                                          node: selected.value!,
                                          onSend: textAsk,
                                        ),
                                      )
                              : selected.value?.isGenerationNode != true
                              ? null
                              : SizedBox(
                                  width:
                                      selected.value!.type ==
                                          canvasNodeTypeImage
                                      ? RevericSizes.productionComposerWidth
                                      : RevericSizes
                                            .productionVideoComposerWidth,
                                  child:
                                      selected.value!.type ==
                                          canvasNodeTypeImage
                                      ? ProductionImageComposer(
                                          key: ValueKey(
                                            '${selected.value!.id}/${composerEpoch.value}',
                                          ),
                                          service: service,
                                          node: selected.value!,
                                          session: session,
                                          path: path,
                                          clip: selectedClip,
                                          onExternalChange: () {
                                            if (context.mounted) {
                                              composerEpoch.value++;
                                            }
                                          },
                                        )
                                      : selected.value!.type ==
                                            canvasNodeTypeAudio
                                      ? ProductionAudioComposer(
                                          key: ValueKey(
                                            '${selected.value!.id}/${composerEpoch.value}',
                                          ),
                                          service: service,
                                          node: selected.value!,
                                          session: session,
                                          path: path,
                                          clip: selectedClip,
                                          onExternalChange: () {
                                            if (context.mounted) {
                                              composerEpoch.value++;
                                            }
                                          },
                                        )
                                      : ProductionComposer(
                                          key: ValueKey(
                                            '${selected.value!.id}/${composerEpoch.value}',
                                          ),
                                          service: service,
                                          node: selected.value!,
                                          session: session,
                                          path: path,
                                          clip: selectedClip,
                                          onExternalChange: () {
                                            if (context.mounted) {
                                              composerEpoch.value++;
                                            }
                                          },
                                        ),
                                ),
                          composerTrailingInset: chatOpen
                              ? RevericSizes.chatPanelWidth + RevericSpacing.x2l
                              : 0,
                          composerBottomInset:
                              ProductionAddDock.extent + RevericSpacing.x2l,
                          tools: ProductionCanvasTools(
                            onAssets: busy.value
                                ? null
                                : () => run(() => placeAsset(null)),
                            onImport: busy.value
                                ? null
                                : () => run(importMedia),
                          ),
                          controls: [
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: RevericSpacing.x2l,
                              child: Center(
                                child: ProductionAddDock(
                                  canvasWork: canvasWork,
                                  enabled: (_) => !busy.value,
                                  onAdd: (kind) => run(() => add(kind)),
                                  onImport: () => run(importMedia),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
        if (!canvasWork && view.value != ProductionViewMode.segments)
          Positioned(top: 0, left: 0, right: 0, child: toolbar),
      ],
    );
  }
}

/// 顶栏的视图切换。工具条的毛玻璃胶囊已经是轨道，这里用画布浮动按钮，
/// 和右侧的风格、规格同高同形，不再叠一层分段控件的轨道和滑块。
class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<RevericSegment<ProductionViewMode>> segments;
  final ProductionViewMode selected;
  final ValueChanged<ProductionViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    Widget item(RevericSegment<ProductionViewMode> segment) {
      final active = segment.value == selected;
      final color = active ? colors.textPrimary : colors.textSecondary;
      return Semantics(
        selected: active,
        inMutuallyExclusiveGroup: true,
        child: CanvasFloatingButton(
          axis: Axis.horizontal,
          selected: active,
          onTap: () => onChanged(segment.value),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (segment.icon case final icon?) ...[
                RevericIcon(
                  icon,
                  size: RevericSizes.buttonIconSize,
                  color: color,
                ),
                const SizedBox(width: RevericSpacing.xxs),
              ],
              Text(
                segment.label,
                maxLines: 1,
                style: (active ? typo.uiSemibold : typo.ui).copyWith(
                  color: color,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 与右侧胶囊里最高的图标按钮等高，两枚胶囊才能对齐。
    return SizedBox(
      height: RevericSizes.iconButtonSize,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (final segment in segments) item(segment)],
      ),
    );
  }
}

class _TopSeparator extends StatelessWidget {
  const _TopSeparator();
  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 18,
    color: RevericTheme.colorsOf(context).borderSubtle,
  );
}
