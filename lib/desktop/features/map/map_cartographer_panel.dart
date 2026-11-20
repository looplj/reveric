// 职责: 制图师面板 — 生成参数（来源/画风/尺寸/补充要求/提示词预览）与地点检查器
// 关联文件:
//   lib/shared/widgets/map/map_location_children.dart
//   lib/shared/widgets/map/location_photos.dart
//   lib/shared/widgets/map/map_history_tab.dart
//   lib/shared/providers/map_studio_controller.dart
//   lib/shared/models/map_studio_models.dart
//   lib/shared/services/map_prompt_builder.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_select.dart';
import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/map_agent.dart';
import '../../../shared/providers/map_agent_providers.dart';
import '../../../shared/providers/maps_providers.dart';
import '../../../shared/services/maps_service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/unsaved_changes_dialog.dart';
import '../../../shared/services/generate_map_orchestrator.dart';
import '../../../shared/widgets/map/location_types.dart';
import '../../../shared/providers/map_studio_controller.dart';
import '../../../shared/hooks/use_map_generate_form.dart';
import '../../../shared/widgets/map/map_generate_fields.dart';
import '../../../shared/widgets/map/map_generate_footer.dart';
import '../../../shared/widgets/map/map_history_tab.dart';
import '../../../shared/widgets/map/location_photos.dart';
import '../../../shared/widgets/map/map_location_children.dart';
import '../../../shared/models/map_studio_models.dart';
import '../../widgets/agent_management/agent_model_settings_page.dart';

enum MapCartographerTab { generate, inspector, history }

class MapCartographerPanel extends HookConsumerWidget {
  const MapCartographerPanel({
    super.key,
    required this.novelId,
    required this.databasePath,
    required this.map,
    required this.settings,
    required this.locations,
    required this.selectedLocationId,
    required this.mappedLocationIds,
    this.parentMap,
    required this.onSelectionChanged,
    required this.onEnterMap,
    required this.onClose,
    this.pendingWorldId,
    this.onGenerateRequest,
    this.busy = false,
  });

  /// 无 Map 记录的地点（还没生成过地图）使用的入口：生成 tab 以该地点为根，
  /// 生成动作由 [onGenerateRequest] 接管（先落库 Map 再 generate）。
  const MapCartographerPanel.pending({
    super.key,
    required this.novelId,
    required this.databasePath,
    required this.pendingWorldId,
    required this.locations,
    required this.selectedLocationId,
    required this.mappedLocationIds,
    this.parentMap,
    required this.onSelectionChanged,
    required this.onEnterMap,
    required this.onClose,
    required this.onGenerateRequest,
    this.busy = false,
  }) : map = null,
       settings = const MapStudioSettings();

  final String databasePath;
  final String novelId;
  final NovelMap? map;
  final MapStudioSettings settings;
  final List<Location> locations;
  final String? selectedLocationId;

  /// 已有 Map 记录的地点，决定地点详情里是「打开地图」还是「新建地图」。
  final Set<String> mappedLocationIds;

  /// 最近一张已经画好的上层地图；生成 tab 用它做默认画风和可选的画风参考图。
  final NovelMap? parentMap;
  final ValueChanged<String?> onSelectionChanged;

  /// 切到某个地点自己的地图（没有 Map 记录时进入待生成状态）。
  final ValueChanged<String> onEnterMap;
  final VoidCallback onClose;

  /// pending 模式的生成根地点；非 null 表示该地点还没有 Map 记录。
  final String? pendingWorldId;

  /// pending 模式的生成动作接管方；pending 模式必填。
  final Future<void> Function(MapGenerationRequest request)? onGenerateRequest;

  /// pending 模式的外部忙态（落库 + 生成进行中）。
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final map = this.map;
    final state = map == null
        ? null
        : ref.watch(mapStudioControllerProvider(databasePath, map.id));
    final inspectorOnly = map == null && pendingWorldId == null;
    final rootId = map?.locationId ?? pendingWorldId;
    final rootLocation = locations
        .where((location) => location.id == rootId)
        .firstOrNull;
    final rootName = rootLocation?.name;
    final mapType =
        map?.type ??
        (rootLocation == null ? mapTypeWorld : mapTypeForOwner(rootLocation));
    final isBusy = state?.isBusy == true || busy;
    final MapAgentHandoffCallback? askAgent = rootId == null || rootName == null
        ? null
        : ({required styleId, required styleWord}) {
            ref
                .read(mapAgentHandoffProvider.notifier)
                .request(
                  MapAgentHandoffRequest(
                    databasePath: databasePath,
                    worldId: rootId,
                    worldName: rootName,
                    styleId: styleId,
                    styleWord: styleWord,
                    subMapScale: rootLocation?.parentId == null
                        ? null
                        : mapAgentSubMapScale(mapType),
                  ),
                );
            onClose();
          };
    final availableTabs = <MapCartographerTab>[
      MapCartographerTab.generate,
      MapCartographerTab.inspector,
      if (map != null) MapCartographerTab.history,
    ];
    final tab = useState(
      selectedLocationId == null && !inspectorOnly
          ? MapCartographerTab.generate
          : MapCartographerTab.inspector,
    );
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    useEffect(() {
      if (selectedLocationId == null) {
        return null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          tab.value = MapCartographerTab.inspector;
        }
      });
      return null;
    }, [selectedLocationId]);

    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelHeader(
            key: const ValueKey('map_cartographer_header'),
            colors: colors,
            typo: typo,
            subtitle: isBusy
                ? context.t(LocaleKeys.mapEditorStudioPainting)
                : selectedLocationId == null
                ? context.t(LocaleKeys.mapEditorStudioSubtitle)
                : null,
            onClose: onClose,
          ),
          if (!inspectorOnly)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.md,
                vertical: RevericSpacing.sm,
              ),
              child: Row(
                children: [
                  for (final value in availableTabs)
                    Expanded(
                      child: GestureDetector(
                        onTap: () => tab.value = value,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            color: tab.value == value
                                ? colors.accent.withValues(alpha: 0.12)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            switch (value) {
                              MapCartographerTab.generate => context.t(
                                LocaleKeys.mapEditorStudioTabGenerate,
                              ),
                              MapCartographerTab.inspector => context.t(
                                LocaleKeys.mapEditorStudioTabLocation,
                              ),
                              MapCartographerTab.history => context.t(
                                LocaleKeys.mapEditorStudioTabHistory,
                              ),
                            },
                            textAlign: TextAlign.center,
                            style: typo.uiSmall.copyWith(
                              color: tab.value == value
                                  ? colors.accent
                                  : colors.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: !inspectorOnly && tab.value == MapCartographerTab.generate
                ? _GenerateTab(
                    databasePath: databasePath,
                    locations: locations,
                    rootId: map?.locationId ?? pendingWorldId!,
                    rootName: rootName ?? map?.name ?? '',
                    mapType: mapType,
                    estimateMapId: map?.id ?? pendingWorldId!,
                    hasImage: settings.hasImage,
                    lastStyleWord: settings.style,
                    parentMap: parentMap,
                    parentMapName: parentMap == null
                        ? null
                        : locations
                                  .where(
                                    (location) =>
                                        location.id == parentMap!.locationId,
                                  )
                                  .firstOrNull
                                  ?.name ??
                              parentMap!.name,
                    referenceImageWidth:
                        settings.canvasWidth ?? map?.width.round() ?? 0,
                    referenceImageHeight:
                        settings.canvasHeight ?? map?.height.round() ?? 0,
                    busy: isBusy,
                    onAskAgent: askAgent,
                    onGenerate: map == null
                        ? onGenerateRequest!
                        : (request) => ref
                              .read(
                                mapStudioControllerProvider(
                                  databasePath,
                                  map.id,
                                ).notifier,
                              )
                              .generate(
                                request,
                                novelId: novelId,
                                sourceMapName: map.name,
                              ),
                  )
                : map != null && tab.value == MapCartographerTab.history
                ? MapHistoryTab(
                    novelId: novelId,
                    onSelected: (asset) => ref
                        .read(
                          mapStudioControllerProvider(
                            databasePath,
                            map.id,
                          ).notifier,
                        )
                        .previewAsset(
                          asset,
                          novelId: novelId,
                          sourceMapName: map.name,
                        ),
                  )
                : _InspectorTab(
                    novelId: novelId,
                    databasePath: databasePath,
                    settings: settings,
                    locations: locations,
                    selectedLocationId: selectedLocationId,
                    currentMapOwnerId: rootId,
                    mappedLocationIds: mappedLocationIds,
                    onSelectionChanged: onSelectionChanged,
                    onEnterMap: onEnterMap,
                  ),
          ),
        ],
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    super.key,
    required this.colors,
    required this.typo,
    required this.onClose,
    this.subtitle,
  });

  final RevericColors colors;
  final RevericTypography typo;
  final VoidCallback onClose;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.md),
      child: Row(
        children: [
          const RevericIcon(RevericIcons.explore, size: 16),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.t(LocaleKeys.mapEditorStudioTitle),
                  style: typo.uiSemibold,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: context.t(LocaleKeys.commonClose),
            onPressed: onClose,
            icon: const RevericIcon(RevericIcons.close, size: 16),
          ),
        ],
      ),
    );
  }
}

class _GenerateTab extends HookConsumerWidget {
  const _GenerateTab({
    required this.databasePath,
    required this.locations,
    required this.rootId,
    required this.rootName,
    required this.mapType,
    required this.estimateMapId,
    required this.hasImage,
    required this.lastStyleWord,
    required this.parentMap,
    required this.parentMapName,
    required this.referenceImageWidth,
    required this.referenceImageHeight,
    required this.busy,
    required this.onAskAgent,
    required this.onGenerate,
  });

  final String databasePath;
  final List<Location> locations;

  /// 参与生成的地点树根：正式地图是 map.locationId，pending 是待生成地点 id。
  final String rootId;

  /// 生成目标地图的名字，标在 tab 顶部：生成针对画布这张图，而不是选中的地点。
  final String rootName;

  /// 地图尺度，决定默认 prompt 的措辞。
  final String mapType;

  /// 预估缓存键里的 map id；pending 阶段还没有 Map 记录，用 world id 占位。
  final String estimateMapId;

  /// 当前地图是否已有图片（决定是否参考上一版重画）；pending 恒为 false。
  final bool hasImage;

  /// 这张图上次成图用的画风词；没画过为 null，此时默认沿用上层地图的画风。
  final String? lastStyleWord;

  /// 最近一张已经画好的上层地图，可选作画风参考图。
  final NovelMap? parentMap;
  final String? parentMapName;
  final int referenceImageWidth;
  final int referenceImageHeight;
  final bool busy;
  final MapAgentHandoffCallback? onAskAgent;
  final Future<void> Function(MapGenerationRequest request) onGenerate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = useMapGenerateForm(
      ref: ref,
      locations: locations,
      rootId: rootId,
      mapType: mapType,
      hasImage: hasImage,
      lastStyleWord: lastStyleWord,
      parentMap: parentMap,
      parentMapName: parentMapName,
    );
    useListenable(form.listenable);
    final agentDraft = ref.watch(
      mapDesignDraftProvider(databasePath: databasePath, worldId: rootId),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(RevericSpacing.md),
            child: MapGenerateFields(
              form: form,
              databasePath: databasePath,
              rootId: rootId,
              rootName: rootName,
              busy: busy,
              onAskAgent: onAskAgent,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.md,
            RevericSpacing.sm,
            RevericSpacing.md,
            RevericSpacing.md,
          ),
          child: MapGenerateFooter(
            modelId: form.modelId.value,
            databasePath: databasePath,
            hasPendingAgentDraft: agentDraft != null,
            hasChildLocations: locations.any(
              (location) => location.parentId == rootId,
            ),
            mapId: estimateMapId,
            onConfigureImageModel: () => showAgentModelSettingsDialog(context),
            onGenerate: busy
                ? () {}
                : () {
                    if (!form.validateCustomStyle()) {
                      return;
                    }
                    onGenerate(form.toRequest());
                  },
          ),
        ),
      ],
    );
  }
}

class _InspectorTab extends HookConsumerWidget {
  const _InspectorTab({
    required this.novelId,
    required this.databasePath,
    required this.settings,
    required this.locations,
    required this.selectedLocationId,
    required this.currentMapOwnerId,
    required this.mappedLocationIds,
    required this.onSelectionChanged,
    required this.onEnterMap,
  });

  final String databasePath;
  final String novelId;
  final MapStudioSettings settings;
  final List<Location> locations;
  final String? selectedLocationId;
  final String? currentMapOwnerId;
  final Set<String> mappedLocationIds;
  final ValueChanged<String?> onSelectionChanged;
  final ValueChanged<String> onEnterMap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = selectedLocationId == null
        ? null
        : locations.where((item) => item.id == selectedLocationId).firstOrNull;
    if (location == null) {
      return _InspectorBlank(settings: settings, locations: locations);
    }
    final parentLocation = location.parentId == null
        ? null
        : locations.where((item) => item.id == location.parentId).firstOrNull;
    // 以 location.id 为 key 重置表单：切换选中对象时控制器跟着换。
    final nameController = useTextEditingController(text: location.name);
    final descriptionController = useTextEditingController(
      text: location.description,
    );
    // 文本变化时重建，驱动「保存」按钮的 dirty 判定。
    useListenable(nameController);
    useListenable(descriptionController);
    final selectedType = useState(location.type);
    final selectedParent = useState<String?>(location.parentId);
    final nameError = useState<String?>(null);
    final saving = useState(false);
    final currentId = useRef(location.id)..value = location.id;
    useEffect(() {
      nameError.value = null;
      nameController.text = location.name;
      descriptionController.text = location.description;
      selectedType.value = location.type;
      selectedParent.value = location.parentId;
      return null;
    }, [location.id]);

    final dirty =
        nameController.text.trim() != location.name ||
        descriptionController.text.trim() != location.description ||
        selectedType.value != location.type ||
        selectedParent.value != location.parentId;

    Future<bool> save() async {
      if (saving.value) {
        return false;
      }
      final name = nameController.text.trim();
      if (name.isEmpty) {
        nameError.value = context.t(LocaleKeys.mapEditorLocationNameRequired);
        return false;
      }
      saving.value = true;
      nameError.value = null;
      try {
        final service = ref.read(locationsServiceProvider(databasePath));
        await service.updateLocation(
          id: location.id,
          name: name,
          description: descriptionController.text.trim(),
          type: selectedType.value,
          parentId: selectedParent.value,
          clearParentId: selectedParent.value == null,
        );
        return true;
      } catch (error) {
        if (context.mounted &&
            currentId.value == location.id &&
            nameController.text.trim() == name) {
          nameError.value = context.t(
            error is DuplicateLocationNameException
                ? LocaleKeys.mapEditorLocationNameDuplicate
                : LocaleKeys.commonSaveFailed,
          );
        }
        return false;
      } finally {
        if (context.mounted) {
          saving.value = false;
        }
      }
    }

    /// 离开当前地点（选别的地点 / 进入地图）前先处理未保存的修改。
    Future<void> leave(VoidCallback action) async {
      if (dirty) {
        final decision = await showUnsavedChangesDialog(
          context: context,
          titleKey: LocaleKeys.editorUnsavedChangesTitle,
          messageKey: LocaleKeys.editorUnsavedChangesMessage,
        );
        switch (decision) {
          case null:
            return;
          case UnsavedChangesDecision.discard:
            break;
          case UnsavedChangesDecision.save:
            if (!await save()) {
              return;
            }
        }
      }
      if (context.mounted) {
        action();
      }
    }

    Future<void> selectLocation(String locationId) =>
        leave(() => onSelectionChanged(locationId));

    final hasChildren = locations.any((item) => item.parentId == location.id);
    final hasMap = mappedLocationIds.contains(location.id);
    // 有子地点才有东西可画；正在看的就是它自己的图时不再给入口。
    final showMapEntry = hasChildren && location.id != currentMapOwnerId;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(RevericSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (parentLocation != null) ...[
            MapLocationParentLink(
              parent: parentLocation,
              onSelected: (parentId) {
                selectLocation(parentId);
              },
            ),
            const SizedBox(height: RevericSpacing.sm),
          ],
          RevericTextField(
            key: const ValueKey('map_location_inspector_name'),
            controller: nameController,
            errorText: nameError.value,
            label: context.t(LocaleKeys.mapEditorStudioFieldName),
          ),
          const SizedBox(height: RevericSpacing.md),
          RevericSelect<String>(
            label: context.t(LocaleKeys.mapEditorStudioFieldType),
            value: selectedType.value,
            items: [
              for (final type in mapLocationTypeOptions)
                RevericSelectItem<String>(
                  value: type,
                  label: mapLocationTypeLabel(type, context),
                ),
            ],
            onChanged: (value) => selectedType.value = value,
          ),
          const SizedBox(height: RevericSpacing.md),
          RevericSelect<String>(
            label: context.t(LocaleKeys.mapEditorParentLocation),
            value: selectedParent.value ?? '',
            items: [
              RevericSelectItem<String>(
                value: '',
                label: context.t(LocaleKeys.mapEditorNoParentLocation),
              ),
              for (final candidate in locations)
                if (candidate.id != location.id)
                  RevericSelectItem<String>(
                    value: candidate.id,
                    label: candidate.name,
                  ),
            ],
            onChanged: (value) {
              selectedParent.value = value.isEmpty ? null : value;
            },
          ),
          const SizedBox(height: RevericSpacing.md),
          RevericTextField(
            controller: descriptionController,
            label: context.t(LocaleKeys.mapEditorStudioFieldDescription),
            multiline: true,
            minLines: 2,
            maxLines: null,
          ),
          const SizedBox(height: RevericSpacing.md),
          // 照片增删改名即时写库，不参与上方字段的 dirty 判定。
          Text(
            context.t(LocaleKeys.mapEditorStudioFieldPhotos),
            style: RevericTheme.typographyOf(context).uiSmallSemibold.copyWith(
              color: RevericTheme.colorsOf(context).textSecondary,
            ),
          ),
          const SizedBox(height: RevericSpacing.xs),
          LocationPhotos(
            novelId: novelId,
            key: ValueKey('map_location_photos_${location.id}'),
            databasePath: databasePath,
            location: location,
            pickImages: _pickImages,
          ),
          const SizedBox(height: RevericSpacing.md),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: dirty && !saving.value ? () => save() : null,
              icon: const RevericIcon(RevericIcons.check, size: 13),
              label: Text(context.t(LocaleKeys.commonSave)),
            ),
          ),
          if (showMapEntry) ...[
            const SizedBox(height: RevericSpacing.md),
            OutlinedButton.icon(
              key: ValueKey('map_location_enter_map_${location.id}'),
              onPressed: () => leave(() => onEnterMap(location.id)),
              icon: RevericIcon(
                hasMap ? RevericIcons.map_outlined : RevericIcons.add,
                size: 14,
              ),
              label: Text(
                hasMap
                    ? context.t(LocaleKeys.mapEditorStudioOpenMap)
                    : context
                          .t(LocaleKeys.mapEditorStudioCreateMapFor)
                          .replaceFirst('{name}', location.name),
              ),
            ),
          ],
          MapLocationChildren(
            parentId: location.id,
            locations: locations,
            onSelected: (childId) {
              selectLocation(childId);
            },
          ),
        ],
      ),
    );
  }
}

Future<List<String>> _pickImages() async {
  final files = await openFiles(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'images', extensions: ['png', 'jpg', 'jpeg', 'webp']),
    ],
  );
  return files.map((file) => file.path).toList(growable: false);
}

class _InspectorBlank extends StatelessWidget {
  const _InspectorBlank({required this.settings, required this.locations});

  final MapStudioSettings settings;
  final List<Location> locations;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final unplaced = settings.unmatchedLocationIds.length;
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RevericIcon(
            RevericIcons.location_on,
            size: 18,
            color: colors.textMuted,
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.mapEditorNoSelection),
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: RevericSpacing.lg),
          Row(
            children: [
              Expanded(
                child: Text(
                  context.t(LocaleKeys.mapEditorStudioStatUnmatched),
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
              ),
              Text('$unplaced', style: typo.uiSemibold),
            ],
          ),
        ],
      ),
    );
  }
}
