// 职责: 移动端地点编辑页 — 名称/类型/父级/描述 markdown 编辑（防抖自动保存）、照片、子地点列表展示与跳转、添加子地点。
// 关联文件:
//   lib/mobile/pages/location_editor_save.dart
//   lib/mobile/widgets/detail_scaffold.dart
//   lib/shared/widgets/map/location_photos.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/providers/maps_providers.dart
//   lib/shared/services/maps_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/error-handling.md
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../shared/components/reveric_select.dart';
import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/providers/maps_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/utils/text_input_composing.dart';
import '../../shared/widgets/map/location_photos.dart';
import '../../shared/widgets/md/reveric_markdown_editor.dart';
import '../widgets/detail_scaffold.dart';
import '../widgets/editor_app_bar.dart';
import 'location_editor_save.dart';

/// 地点编辑页（按 id 加载）：从地点列表按 id 取条目后渲染编辑主体。
/// 拆 loader 让条目跳转/列表打开统一「只传 id」，主体同步拿到具体对象不变。
class MobileLocationEditorPage extends ConsumerWidget {
  const MobileLocationEditorPage({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.locationId,
  });

  final String databasePath;
  final String novelId;
  final String locationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(locationsProvider(databasePath)).asData?.value;
    final location = list?.cast<Location?>().firstWhere(
      (l) => l?.id == locationId,
      orElse: () => null,
    );
    if (location == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _LocationEditorBody(
      key: ValueKey(location.id),
      novelId: novelId,
      databasePath: databasePath,
      location: location,
    );
  }
}

class _LocationEditorBody extends HookConsumerWidget {
  const _LocationEditorBody({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.location,
  });

  final String databasePath;
  final String novelId;
  final Location location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);

    final nameController = useTextEditingController(text: location.name);
    final descriptionController = useTextEditingController(
      text: location.description,
    );
    final descriptionFocusNode = useFocusNode();
    final scrollController = useScrollController();
    final editorSectionKey = useMemoized(GlobalKey.new);
    // 共享 undo/redo 控制器：名称/描述同页，按钮作用于当前焦点字段。
    final undoController = useMemoized(UndoHistoryController.new);
    useEffect(() => undoController.dispose, const []);
    final selectedType = useState<String>(location.type);
    final selectedParentId = useState<String?>(location.parentId);

    final service = ref.watch(locationsServiceProvider(databasePath));
    final saver = useMemoized(
      () => LocationEditorSaveController(
        service: service,
        locationId: location.id,
        savedAt: location.updatedAt,
        initialValues: (
          name: location.name.trim(),
          description: location.description,
          type: location.type,
          parentId: location.parentId,
        ),
      ),
      [service, location.id],
    );
    useEffect(() => saver.dispose, [saver]);
    useListenable(saver);
    final navigating = useRef(false);
    final locationsAsync = ref.watch(locationsProvider(databasePath));
    final allLocations = locationsAsync.asData?.value ?? const <Location>[];

    // 可选父级：排除自身与 room 类型（与桌面 _EditLocationDialog 一致）。
    final parentCandidates = allLocations
        .where(
          (item) => item.id != location.id && item.type != locationTypeRoom,
        )
        .toList();

    bool hasComposingText() =>
        isTextInputComposing(nameController) ||
        isTextInputComposing(descriptionController);
    void scheduleSave() {
      if (hasComposingText()) {
        return;
      }
      saver.update((
        name: nameController.text.trim(),
        description: descriptionController.text,
        type: selectedType.value,
        parentId: selectedParentId.value,
      ));
    }

    useOnListenableChange(nameController, scheduleSave);
    useOnListenableChange(descriptionController, scheduleSave);
    useListenableSelector(
      descriptionController,
      () => isTextInputComposing(descriptionController),
    );

    Future<bool> flushForNavigation() async {
      if (hasComposingText()) {
        return false;
      }
      scheduleSave();
      return saver.flush();
    }

    Future<void> leave() async {
      if (navigating.value) {
        return;
      }
      navigating.value = true;
      try {
        if (await flushForNavigation() && context.mounted) {
          final navigator = Navigator.of(context);
          if (navigator.canPop()) {
            navigator.pop();
          }
        }
      } finally {
        navigating.value = false;
      }
    }

    // 键盘弹出时把编辑区滚入可视区域，避免上半表单项占满压缩后的视口。
    useEffect(() {
      void scrollEditorIntoView() {
        if (!descriptionFocusNode.hasFocus) {
          return;
        }
        final target = editorSectionKey.currentContext;
        if (target == null) {
          return;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!target.mounted) {
            return;
          }
          Scrollable.ensureVisible(
            target,
            alignment: 0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        });
      }

      descriptionFocusNode.addListener(scrollEditorIntoView);
      return () {
        descriptionFocusNode.removeListener(scrollEditorIntoView);
      };
    }, const []);

    Future<void> addSubLocation() async {
      if (navigating.value) {
        return;
      }
      navigating.value = true;
      try {
        if (!await flushForNavigation() || !context.mounted) {
          return;
        }
        final id = await service.createLocationWithDefaultName(
          defaultName: context.t(LocaleKeys.mobileEditorNewLocation),
          type: locationTypeRegion,
          parentId: location.id,
        );
        if (context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MobileLocationEditorPage(
                novelId: novelId,
                databasePath: databasePath,
                locationId: id,
              ),
            ),
          );
        }
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      } finally {
        navigating.value = false;
      }
    }

    // 当前地点的子地点（按 sortOrder）。
    final children =
        allLocations.where((l) => l.parentId == location.id).toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    Future<void> openChildEditor(Location child) async {
      if (navigating.value) {
        return;
      }
      navigating.value = true;
      try {
        if (await flushForNavigation() && context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MobileLocationEditorPage(
                novelId: novelId,
                databasePath: databasePath,
                locationId: child.id,
              ),
            ),
          );
        }
      } finally {
        navigating.value = false;
      }
    }

    useListenable(nameController);

    final displayName = nameController.text.trim().isEmpty
        ? context.t(LocaleKeys.commonUntitled)
        : nameController.text.trim();

    final errorText = switch (saver.failure) {
      LocationEditorSaveFailure.duplicate_name => context.t(
        LocaleKeys.mapEditorLocationNameDuplicate,
      ),
      LocationEditorSaveFailure.save_failed => context.t(
        LocaleKeys.commonSaveFailed,
      ),
      null => null,
    };
    return PopScope<void>(
      canPop: !saver.isDirty && !saver.isSaving && !hasComposingText(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(leave());
        }
      },
      child: Scaffold(
        backgroundColor: colors.canvas,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              MobileEditorAppBar(
                title: displayName,
                subtitle: _locationTypeLabel(selectedType.value, context),
                saving: saver.isSaving,
                savedAt: saver.savedAt,
                onBack: leave,
                undoController: undoController,
                backButtonKey: const ValueKey('mobile_location_back_button'),
              ),
              Expanded(
                child: CustomScrollView(
                  controller: scrollController,
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        mobileDetailBodyPadding.left,
                        mobileDetailBodyPadding.top,
                        mobileDetailBodyPadding.right,
                        0,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          children: [
                            MobileDetailTitleField(
                              key: const ValueKey('mobile_location_name_field'),
                              controller: nameController,
                              undoController: undoController,
                              hintText: context.t(
                                LocaleKeys.mapEditorLocationNameHint,
                              ),
                              errorText: errorText,
                            ),
                            const SizedBox(height: RevericSpacing.xl),
                            MobileDetailFieldList(
                              children: [
                                MobileDetailFieldRow(
                                  label: context.t(LocaleKeys.commonType),
                                  child: MobileDetailSelect<String>(
                                    value: selectedType.value,
                                    items: [
                                      for (final type in locationTypes)
                                        RevericSelectItem<String>(
                                          value: type,
                                          label: _locationTypeLabel(
                                            type,
                                            context,
                                          ),
                                        ),
                                    ],
                                    onChanged: (next) {
                                      selectedType.value = next;
                                      scheduleSave();
                                    },
                                  ),
                                ),
                                MobileDetailFieldRow(
                                  label: context.t(
                                    LocaleKeys.mapEditorParentLocation,
                                  ),
                                  child: MobileDetailSelect<String?>(
                                    value: selectedParentId.value,
                                    items: [
                                      RevericSelectItem<String?>(
                                        value: null,
                                        label: context.t(
                                          LocaleKeys.mapEditorNoParentLocation,
                                        ),
                                      ),
                                      for (final item in parentCandidates)
                                        RevericSelectItem<String?>(
                                          value: item.id,
                                          label: item.name,
                                        ),
                                    ],
                                    onChanged: (value) {
                                      selectedParentId.value = value;
                                      scheduleSave();
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: RevericSpacing.x2l),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: MobileDetailSectionLabel(
                                text: context.t(
                                  LocaleKeys.mapEditorStudioFieldPhotos,
                                ),
                              ),
                            ),
                            LocationPhotos(
                              novelId: novelId,
                              databasePath: databasePath,
                              location: location,
                              pickImages: _pickImages,
                            ),
                            const SizedBox(height: RevericSpacing.x2l),
                            _ChildrenListSection(
                              children: children,
                              onTap: openChildEditor,
                              onAdd: addSubLocation,
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        RevericSpacing.x4l,
                        RevericSpacing.lg,
                        RevericSpacing.x4l,
                        RevericSpacing.x4l,
                      ),
                      sliver: SliverLayoutBuilder(
                        builder: (context, sliverConstraints) {
                          const sectionLabelHeight =
                              RevericSpacing.lg + RevericSpacing.sm;
                          final remainingHeight =
                              sliverConstraints.viewportMainAxisExtent -
                              sliverConstraints.precedingScrollExtent -
                              RevericSpacing.x4l;
                          final editorHeight = math.max(
                            360.0,
                            remainingHeight - sectionLabelHeight,
                          );

                          return SliverToBoxAdapter(
                            child: KeyedSubtree(
                              key: editorSectionKey,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  MobileDetailSectionLabel(
                                    text: context.t(LocaleKeys.commonContent),
                                  ),
                                  SizedBox(
                                    height: editorHeight,
                                    child: RevericMarkdownEditor(
                                      controller: descriptionController,
                                      focusNode: descriptionFocusNode,
                                      undoController: undoController,
                                      hintText: context.t(
                                        LocaleKeys
                                            .mapEditorLocationDescriptionHint,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<List<String>> _pickImages() async {
  final picked = await ImagePicker().pickMultiImage();
  return picked.map((file) => file.path).toList(growable: false);
}

/// 当前地点的子地点列表，每行可点击进入子地点编辑页；末行为「添加子地点」。
class _ChildrenListSection extends StatelessWidget {
  const _ChildrenListSection({
    required this.children,
    required this.onTap,
    required this.onAdd,
  });

  final List<Location> children;
  final ValueChanged<Location> onTap;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.mobileEditorSubLocations),
          style: typo.uiSemibold.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: RevericSpacing.sm),
        for (final child in children) ...[
          InkWell(
            key: ValueKey('mobile_location_child_item_${child.id}'),
            onTap: () => onTap(child),
            borderRadius: BorderRadius.circular(RevericRadius.large),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.lg,
                vertical: RevericSpacing.md,
              ),
              decoration: BoxDecoration(
                color: colors.surfaceContainer,
                borderRadius: BorderRadius.circular(RevericRadius.large),
                border: Border.all(color: colors.borderSubtle),
              ),
              child: Row(
                children: [
                  RevericIcon(
                    _locationTypeIcon(child.type),
                    size: 16,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: Text(
                      child.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmallSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  Text(
                    _locationTypeLabel(child.type, context),
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  RevericIcon(
                    RevericIcons.chevron_right,
                    size: 16,
                    color: colors.textSubtle,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: RevericSpacing.xs),
        ],
        InkWell(
          key: const ValueKey('mobile_location_add_sub_button'),
          onTap: onAdd,
          borderRadius: BorderRadius.circular(RevericRadius.large),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.lg,
              vertical: RevericSpacing.md,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(RevericRadius.large),
              border: Border.all(color: colors.borderSubtle),
            ),
            child: Row(
              children: [
                RevericIcon(
                  RevericIcons.add,
                  size: 16,
                  color: colors.textMuted,
                ),
                const SizedBox(width: RevericSpacing.sm),
                Text(
                  context.t(LocaleKeys.mobileEditorAddSubLocation),
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _locationTypeIcon(String type) {
  switch (type) {
    case locationTypeWorld:
    case locationTypeContinent:
    case locationTypeCountry:
      return RevericIcons.public;
    case locationTypeRegion:
    case locationTypeMountain:
    case locationTypePlain:
    case locationTypeForest:
    case locationTypeRiver:
    case locationTypeLake:
    case locationTypeSea:
    case locationTypeIsland:
      return RevericIcons.terrain;
    case locationTypeCity:
    case locationTypeDistrict:
    case locationTypeVillage:
      return RevericIcons.location_city;
    case locationTypeLandmark:
    case locationTypeBuilding:
    case locationTypeRoom:
      return RevericIcons.place;
    default:
      return RevericIcons.circle_outlined;
  }
}

String _locationTypeLabel(String type, BuildContext context) {
  switch (type) {
    case locationTypeGeneric:
      return context.t(LocaleKeys.locationTypeGeneric);
    case locationTypeWorld:
      return context.t(LocaleKeys.locationTypeWorld);
    case locationTypeContinent:
      return context.t(LocaleKeys.locationTypeContinent);
    case locationTypeCountry:
      return context.t(LocaleKeys.locationTypeCountry);
    case locationTypeRegion:
      return context.t(LocaleKeys.locationTypeRegion);
    case locationTypeMountain:
      return context.t(LocaleKeys.locationTypeMountain);
    case locationTypePlain:
      return context.t(LocaleKeys.locationTypePlain);
    case locationTypeForest:
      return context.t(LocaleKeys.locationTypeForest);
    case locationTypeRiver:
      return context.t(LocaleKeys.locationTypeRiver);
    case locationTypeLake:
      return context.t(LocaleKeys.locationTypeLake);
    case locationTypeSea:
      return context.t(LocaleKeys.locationTypeSea);
    case locationTypeIsland:
      return context.t(LocaleKeys.locationTypeIsland);
    case locationTypeCity:
      return context.t(LocaleKeys.locationTypeCity);
    case locationTypeDistrict:
      return context.t(LocaleKeys.locationTypeDistrict);
    case locationTypeVillage:
      return context.t(LocaleKeys.locationTypeVillage);
    case locationTypeBuilding:
      return context.t(LocaleKeys.locationTypeBuilding);
    case locationTypeRoom:
      return context.t(LocaleKeys.locationTypeRoom);
    case locationTypeLandmark:
      return context.t(LocaleKeys.locationTypeLandmark);
    case locationTypeCustom:
      return context.t(LocaleKeys.locationTypeCustom);
    case locationTypeNatural:
      return context.t(LocaleKeys.locationTypeNatural);
    default:
      return type;
  }
}
