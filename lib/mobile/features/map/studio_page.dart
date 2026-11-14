// 职责: 移动端地图工作台页 — 持有导航（当前地图 / 选中地点）与出图参数，编排画布、地点浮卡、
//       常驻生成栏与三个抽屉（制图师 / 历史 / 地点）。骨架对齐移动端封面工作台。
// 关联文件:
//   lib/shared/models/map_studio_nav.dart
//   lib/shared/hooks/use_map_generate_form.dart
//   lib/shared/providers/map_studio_controller.dart
//   lib/shared/widgets/map/image_map_canvas.dart
//   lib/shared/widgets/map/start_map_generation.dart
//   lib/mobile/features/map/bottom_bar.dart
//   lib/mobile/features/map/place_card.dart
//   lib/mobile/features/map/designer_sheet.dart
//   lib/mobile/features/map/history_sheet.dart
//   lib/mobile/features/map/places_sheet.dart
//   lib/mobile/pages/location_editor_page.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/shared/models/map_agent.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
// 遵循的 Rules:
//   .agents/rules/widget-decomposition.md
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
//   .agents/rules/file-access.md
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../shared/database/novel_content_database.dart';
import '../../../shared/hooks/use_map_generate_form.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/map_agent.dart';
import '../../../shared/models/map_studio_models.dart';
import '../../../shared/models/map_studio_nav.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/models/queued_chat_message.dart';
import '../../../shared/providers/map_agent_providers.dart';
import '../../../shared/providers/map_studio_controller.dart';
import '../../../shared/providers/map_studio_providers.dart'
    show mapImageChoicesProvider;
import '../../../shared/providers/maps_providers.dart';
import '../../../shared/services/map_image_store.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/map/image_map_canvas.dart';
import '../../../shared/widgets/map/location_types.dart';
import '../../../shared/widgets/map/map_generate_footer.dart';
import '../../../shared/widgets/map/start_map_generation.dart';
import '../../pages/agent_model_settings_page.dart';
import '../../pages/location_editor_page.dart';
import '../../pages/novel_chat_page.dart';
import 'bottom_bar.dart';
import 'designer_sheet.dart';
import 'history_sheet.dart';
import 'place_card.dart';
import 'places_sheet.dart';

final _log = AppLogger.forModule('MobileMapStudio');

/// 触屏的地点命中区边长。
const double _touchTargetSize = 44;

/// 打开 [worldId] 的地图工作台；[worldId] 也可以是子地点，页面沿父链找到所属 world。
Future<void> openMobileMapStudioPage(
  BuildContext context, {
  required String novelId,
  required String databasePath,
  required String worldId,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MobileMapStudioPage(
        novelId: novelId,
        databasePath: databasePath,
        worldId: worldId,
      ),
    ),
  );
}

class MobileMapStudioPage extends HookConsumerWidget {
  const MobileMapStudioPage({
    super.key,
    required this.novelId,
    required this.databasePath,
    required this.worldId,
  });

  final String novelId;
  final String databasePath;
  final String worldId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final ownerId = useState(worldId);
    // 当前所在的世界；Agent 把草案投到另一个世界的地点时跟着切过去。
    final currentWorldId = useState(worldId);
    final selectedLocationId = useState<String?>(null);
    final generating = useValueListenable(mapGenerationActivityCounter) > 0;

    final maps = ref.watch(mapsProvider(databasePath)).asData?.value;
    final locations = ref.watch(locationsProvider(databasePath)).asData?.value;
    final world = locations == null
        ? null
        : resolveMapWorld(locations, currentWorldId.value);
    // 地点抽屉里把整个世界删掉了：没东西可看，直接退回列表。
    final worldGone = maps != null && locations != null && world == null;
    useEffect(() {
      if (worldGone) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) {
            Navigator.of(context).maybePop();
          }
        });
      }
      return null;
    }, [worldGone]);
    if (maps == null || locations == null || world == null) {
      return Scaffold(
        backgroundColor: colors.canvas,
        appBar: AppBar(backgroundColor: colors.canvas),
        body: Center(
          child: worldGone
              ? const SizedBox.shrink()
              : CircularProgressIndicator(color: colors.accent),
        ),
      );
    }

    final nav = MapStudioNav.resolve(
      world: world,
      maps: maps,
      locations: locations,
      requestedOwnerId: ownerId.value,
    );

    void enterMap(String id) {
      final targetWorld = mapTopLevelWorldOf(id, nav.locationById);
      if (targetWorld != null) {
        currentWorldId.value = targetWorld.id;
      }
      ownerId.value = id;
      selectedLocationId.value = null;
    }

    void selectLocation(String? id) {
      selectedLocationId.value = id;
      if (id != null) {
        ownerId.value = nav.ownerForSelection(id);
      }
    }

    // 返回键先逐层退回上层地图，到 world 才离开页面；出图中不放行 ——
    // 页面一退 controller 就没人听了，已经发出的图片调用照样计费。
    final atWorld = nav.owner.id == world.id;
    return PopScope(
      canPop: !generating && atWorld,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        if (generating) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.t(LocaleKeys.mapEditorGenerationSwitchBlocked),
              ),
            ),
          );
          return;
        }
        final trail = nav.trail;
        enterMap(trail.length > 1 ? trail[trail.length - 2].id : world.id);
      },
      child: _OwnerStudio(
        // 换一张图就换一份出图参数，与桌面按所属地点重建制图师一致。
        key: ValueKey(nav.owner.id),
        novelId: novelId,
        databasePath: databasePath,
        nav: nav,
        locations: locations,
        selectedLocationId: selectedLocationId.value,
        onSelectLocation: selectLocation,
        onEnterMap: enterMap,
      ),
    );
  }
}

class _OwnerStudio extends HookConsumerWidget {
  const _OwnerStudio({
    super.key,
    required this.novelId,
    required this.databasePath,
    required this.nav,
    required this.locations,
    required this.selectedLocationId,
    required this.onSelectLocation,
    required this.onEnterMap,
  });

  final String novelId;
  final String databasePath;
  final MapStudioNav nav;
  final List<Location> locations;
  final String? selectedLocationId;
  final ValueChanged<String?> onSelectLocation;
  final ValueChanged<String> onEnterMap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final owner = nav.owner;
    final map = nav.currentMap;
    final settings = map == null
        ? const MapStudioSettings()
        : MapStudioSettings.fromMap(map.settings);
    final state = map == null
        ? null
        : ref.watch(mapStudioControllerProvider(databasePath, map.id));
    // 只在回调里取 notifier：build 期间不需要它，也不该为了拿它提前建出 controller。
    MapStudioController? controller() => map == null
        ? null
        : ref.read(mapStudioControllerProvider(databasePath, map.id).notifier);
    final isStarting = useState(false);
    final busy = state?.isBusy == true || isStarting.value;
    final agentDraft = ref.watch(
      mapDesignDraftProvider(databasePath: databasePath, worldId: owner.id),
    );

    final form = useMapGenerateForm(
      choices: ref.watch(mapImageChoicesProvider),
      locations: locations,
      rootId: owner.id,
      mapType: map?.type ?? mapTypeForOwner(owner),
      hasImage: settings.hasImage,
      lastStyleWord: settings.style,
      parentMap: nav.parentMap,
      parentMapName: nav.parentMapName,
    );
    useListenable(form.listenable);

    final imageBytes = _useMapImageBytes(state, settings);
    _useStudioToast(context, ref, databasePath, map?.id, state);

    final mapLocations = map == null
        ? const <MapLocation>[]
        : ref
                  .watch(
                    mapLocationsProvider(
                      databasePath: databasePath,
                      mapId: map.id,
                    ),
                  )
                  .asData
                  ?.value ??
              const <MapLocation>[];

    Future<void> generate() async {
      if (busy) {
        return;
      }
      final request = form.toRequest();
      if (map != null) {
        await controller()!.generate(
          request,
          novelId: novelId,
          sourceMapName: map.name,
        );
        return;
      }
      isStarting.value = true;
      try {
        await startMapGenerationForLocation(
          ref,
          databasePath: databasePath,
          novelId: novelId,
          owner: owner,
          request: request,
        );
      } catch (error, stackTrace) {
        _log.error(
          '[DB] map materialization failed: table=NovelMaps '
          'operation=INSERT locationId=${owner.id}',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      } finally {
        if (context.mounted) {
          isStarting.value = false;
        }
      }
    }

    // 抽屉是另一条 route，不随本页重建：生成脚自己 watch 地点 / 地图 / 草案，
    // 不能用这里的快照（Agent 刚建好的子地点会被当成不存在，生成被拦下）。
    Widget buildFooter(VoidCallback onGenerate) => _StudioGenerateFooter(
      databasePath: databasePath,
      ownerId: owner.id,
      form: form,
      onGenerate: onGenerate,
    );

    late final void Function() openDesigner;

    // 「让 Agent 设计」：带着这张图的所属地点进聊天页自动发送。Agent 提交的草案
    // 落在制图师抽屉顶部；从聊天页回来时草案已到就直接拉起抽屉。
    Future<void> askAgent({
      required String? styleId,
      required String? styleWord,
    }) async {
      final label = context.t(LocaleKeys.mapEditorAgentHandoffLabel);
      final prompt = buildMapAgentHandoffPrompt(
        styleId: styleId,
        styleWord: styleWord,
        subMapScale: owner.parentId == null
            ? null
            : mapAgentSubMapScale(map?.type ?? mapTypeForOwner(owner)),
      );
      final draftTarget = await Navigator.of(context).push(
        MaterialPageRoute<String>(
          builder: (_) => MobileNovelChatPage(
            novelId: novelId,
            databasePath: databasePath,
            returnMapDraftTarget: true,
            handoff: PendingChatHandoff(
              label: label,
              content: prompt,
              initialText: prompt,
              autoSend: true,
              references: [
                AiContextReference(
                  section: NovelWorkspaceSection.maps,
                  itemId: owner.id,
                  label: owner.name,
                  path: '/locations/${owner.id}',
                ),
              ],
            ),
          ),
        ),
      );
      if (!context.mounted) {
        return;
      }
      // Agent 可能把草案投给了另一张图（如在世界图上让它画某座城）：切过去，
      // 新地图的草案由下面的 effect 在首帧拉起抽屉。
      if (draftTarget != null && draftTarget != owner.id) {
        onEnterMap(draftTarget);
        return;
      }
      final draft = ref.read(
        mapDesignDraftProvider(databasePath: databasePath, worldId: owner.id),
      );
      if (draft != null) {
        openDesigner();
      }
    }

    openDesigner = () {
      openMobileMapDesignerSheet(
        context,
        form: form,
        databasePath: databasePath,
        rootId: owner.id,
        rootName: owner.name,
        busy: busy,
        buildFooter: buildFooter,
        onGenerate: generate,
        onAskAgent: askAgent,
      );
    };

    // Agent 在后台跑完、作者正停在工作台上时，草案一到就拉起抽屉（对齐桌面自动打开制图师）。
    // 聊天页还盖在上面时不弹，交给 askAgent 回来后处理。
    useEffect(() {
      if (agentDraft == null) {
        return null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
          openDesigner();
        }
      });
      return null;
    }, [agentDraft]);

    // 自定义画风没填时，错误提示在抽屉里的输入框上，得把抽屉拉起来。
    void generateFromBar() {
      if (!form.validateCustomStyle()) {
        openDesigner();
        return;
      }
      generate();
    }

    final selected = selectedLocationId == null
        ? null
        : nav.locationById[selectedLocationId];

    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const RevericIcon(RevericIcons.arrow_back, size: 18),
        ),
        title: _MapTrail(
          trail: nav.trail,
          version: settings.hasImage ? settings.version : null,
          onTap: onEnterMap,
        ),
        actions: [
          IconButton(
            key: const ValueKey('mobile_map_places'),
            tooltip: context.t(LocaleKeys.mapEditorStudioRailPlaces),
            onPressed: () => openMobileMapPlacesSheet(
              context,
              databasePath: databasePath,
              nav: nav,
              locations: locations,
              onSelect: onSelectLocation,
              onEnterMap: onEnterMap,
            ),
            icon: const RevericIcon(RevericIcons.list_bullets, size: 18),
          ),
          if (map != null)
            IconButton(
              key: const ValueKey('mobile_map_history'),
              tooltip: context.t(LocaleKeys.mapEditorStudioTabHistory),
              onPressed: busy
                  ? null
                  : () => openMobileMapHistorySheet(
                      context,
                      novelId: novelId,
                      onSelected: (asset) => controller()!.previewAsset(
                        asset,
                        novelId: novelId,
                        sourceMapName: map.name,
                      ),
                    ),
              icon: const RevericIcon(
                RevericIcons.history_outlined,
                size: 18,
              ),
            ),
          IconButton(
            key: const ValueKey('mobile_map_export'),
            tooltip: context.t(LocaleKeys.mapEditorStudioExport),
            onPressed: map == null || !settings.hasImage
                ? null
                : () => _exportMap(context, map, settings),
            icon: const RevericIcon(RevericIcons.download_outlined, size: 18),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: colors.surfaceDim,
              child: map != null && imageBytes != null
                  ? ImageMapCanvas(
                      map: map,
                      settings: settings,
                      imageBytes: imageBytes,
                      mapLocations: mapLocations,
                      locationById: nav.locationById,
                      selectedLocationId: selectedLocationId,
                      onSelectionChanged: onSelectLocation,
                      targetSize: _touchTargetSize,
                    )
                  : _CanvasPlaceholder(
                      title: busy
                          ? context.t(LocaleKeys.mapEditorStudioPainting)
                          : context.t(LocaleKeys.mapEditorStudioEmptyTitle),
                      subtitle: busy ? null : owner.name,
                      busy: busy,
                    ),
            ),
          ),
          if (selected != null && !busy)
            Positioned(
              left: RevericSpacing.md,
              right: RevericSpacing.md,
              bottom: RevericSpacing.md,
              child: MobileMapPlaceCard(
                location: selected,
                childCount: locations
                    .where((location) => location.parentId == selected.id)
                    .length,
                hasMap: nav.mappedLocationIds.contains(selected.id),
                isCurrentMap: selected.id == owner.id,
                onClose: () => onSelectLocation(null),
                onEdit: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MobileLocationEditorPage(
                      databasePath: databasePath,
                      locationId: selected.id,
                    ),
                  ),
                ),
                onEnterMap: () => onEnterMap(selected.id),
              ),
            ),
        ],
      ),
      bottomNavigationBar: MobileMapBottomBar(
        phase: busy
            ? MapStudioPhase.generating
            : state?.phase ?? MapStudioPhase.viewing,
        stageIndex: state?.stageIndex ?? 0,
        matchedCount: state?.draft?.readResult.matches.length ?? 0,
        candidateCount: state?.draft?.places.length ?? 0,
        requiresPlaceRecognition: state?.requiresPlaceRecognition ?? false,
        onOpenDesigner: openDesigner,
        footer: buildFooter(generateFromBar),
        onAdopt: () => controller()?.adopt(),
        onRegenerate: () => controller()?.regenerate(),
      ),
    );
  }
}

/// 页面底栏与制图师抽屉共用的生成脚，门禁与预估按最新的地点 / 地图 / 草案计算。
class _StudioGenerateFooter extends ConsumerWidget {
  const _StudioGenerateFooter({
    required this.databasePath,
    required this.ownerId,
    required this.form,
    required this.onGenerate,
  });

  final String databasePath;
  final String ownerId;
  final MapGenerateForm form;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locations =
        ref.watch(locationsProvider(databasePath)).asData?.value ??
        const <Location>[];
    final map = ref
        .watch(mapsProvider(databasePath))
        .asData
        ?.value
        .where((item) => item.locationId == ownerId)
        .firstOrNull;

    final agentDraft = ref.watch(
      mapDesignDraftProvider(databasePath: databasePath, worldId: ownerId),
    );
    return MapGenerateFooter(
      databasePath: databasePath,
      showGateTooltip: false,
      hasPendingAgentDraft: agentDraft != null,
      hasChildLocations: locations.any(
        (location) => location.parentId == ownerId,
      ),
      mapId: map?.id ?? ownerId,
      onConfigureImageModel: () => openMobileAgentModelSettingsPage(context),
      onGenerate: onGenerate,
    );
  }
}

/// 画布字节：优先用待采用草稿，否则按 settings 路径读文件。
Uint8List? _useMapImageBytes(
  MapStudioState? state,
  MapStudioSettings settings,
) {
  final bytes = useState<Uint8List?>(null);
  final draftBytes = state?.draft?.imageBytes;
  useEffect(() {
    if (draftBytes != null) {
      bytes.value = draftBytes;
      return null;
    }
    final path = settings.image;
    if (path == null || path.isEmpty) {
      bytes.value = null;
      return null;
    }
    var cancelled = false;
    MapImageStore().read(path).then((value) {
      if (!cancelled) bytes.value = value;
    });
    return () => cancelled = true;
  }, [draftBytes, settings.image, settings.version]);
  return bytes.value;
}

/// 错误与回读结果各弹一条短消息，弹完清掉 controller 里的错误。
void _useStudioToast(
  BuildContext context,
  WidgetRef ref,
  String databasePath,
  String? mapId,
  MapStudioState? state,
) {
  // messenger 在 build 阶段取好：effect 首次运行在 initHook 里，不能再读 InheritedWidget。
  final messenger = ScaffoldMessenger.maybeOf(context);
  final message =
      state?.errorMessage ??
      (state?.phase == MapStudioPhase.viewing ? state?.stageNote : null);
  final isError = state?.errorMessage != null;
  useEffect(() {
    if (message == null || message.isEmpty || messenger == null) {
      return null;
    }
    // 弹条与清错误都等这一帧画完：build 期间改 messenger 或 provider 状态会报错。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      messenger.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
      );
      if (isError && mapId != null) {
        final provider = mapStudioControllerProvider(databasePath, mapId);
        if (ref.exists(provider)) {
          ref.read(provider.notifier).clearError();
        }
      }
    });
    return null;
  }, [message]);
}

/// 手机上没有「另存为」对话框，导出走系统分享面板 —— 存相册、发微信都从这里分叉。
Future<void> _exportMap(
  BuildContext context,
  NovelMap map,
  MapStudioSettings settings,
) async {
  try {
    final absolute = await MapImageStore().absolutePathOf(settings.image!);
    if (absolute == null) {
      return;
    }
    final extension = absolute.contains('.')
        ? absolute.substring(absolute.lastIndexOf('.'))
        : '.png';
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(File(absolute).path)],
        fileNameOverrides: ['${map.name}-v${settings.version}$extension'],
      ),
    );
  } catch (error, stackTrace) {
    _log.error('map export failed', error: error, stackTrace: stackTrace);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
      );
    }
  }
}

/// 面包屑：上层可点回，末尾是当前地图与版本号。
class _MapTrail extends StatelessWidget {
  const _MapTrail({
    required this.trail,
    required this.version,
    required this.onTap,
  });

  final List<Location> trail;
  final int? version;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final current = trail.last;
    final ancestors = trail.sublist(0, trail.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (ancestors.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(
              children: [
                for (final item in ancestors) ...[
                  InkWell(
                    key: ValueKey('mobile_map_trail_${item.id}'),
                    onTap: () => onTap(item.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        item.name,
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                      ),
                    ),
                  ),
                  RevericIcon(
                    RevericIcons.chevron_right,
                    size: 10,
                    color: colors.textSubtle,
                  ),
                ],
              ],
            ),
          ),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: current.name, style: typo.uiSemibold),
              if (version != null)
                TextSpan(
                  text: '  v$version',
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
                ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _CanvasPlaceholder extends StatelessWidget {
  const _CanvasPlaceholder({
    required this.title,
    required this.subtitle,
    required this.busy,
  });

  final String title;
  final String? subtitle;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      child: DecoratedBox(
        key: ValueKey(
          busy ? 'mobile_map_generating_canvas' : 'mobile_map_empty_canvas',
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(RevericRadius.x2l),
          border: Border.all(color: colors.border),
        ),
        child: Center(
          child: Semantics(
            liveRegion: busy,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  SizedBox.square(
                    dimension: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.accent,
                    ),
                  )
                else
                  RevericIcon(
                    RevericIcons.map_outlined,
                    size: 36,
                    color: colors.textSubtle,
                  ),
                const SizedBox(height: RevericSpacing.md),
                Text(
                  title,
                  style: typo.uiSemibold.copyWith(color: colors.textSecondary),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: RevericSpacing.xs),
                  Text(
                    subtitle!,
                    style: typo.uiSmall.copyWith(color: colors.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
