// 职责: 移动端地图地点抽屉 — 当前 world 的地点树；点地点在画布上选中，行尾地图图标进入它的地图，
//       左滑删除，右上角在当前地图下新建地点。
// 关联文件:
//   lib/mobile/features/map/studio_page.dart
//   lib/mobile/features/map/location_tree.dart
//   lib/mobile/pages/location_editor_page.dart
//   lib/mobile/widgets/delete_confirm.dart
//   lib/shared/models/map_studio_nav.dart
//   lib/shared/providers/maps_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/map_studio_nav.dart';
import '../../../shared/providers/maps_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/screenplay/labels.dart';
import '../../pages/location_editor_page.dart';
import '../../widgets/delete_confirm.dart';
import 'location_tree.dart';

Future<void> openMobileMapPlacesSheet(
  BuildContext context, {
  required String databasePath,
  required String novelId,
  required MapStudioNav nav,
  required List<Location> locations,
  required ValueChanged<String?> onSelect,
  required ValueChanged<String> onEnterMap,
}) {
  final colors = RevericTheme.colorsOf(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: colors.surface,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    builder: (sheetContext) => _PlacesSheet(
      novelId: novelId,
      databasePath: databasePath,
      nav: nav,
      onSelect: (id) {
        Navigator.of(sheetContext).pop();
        onSelect(id);
      },
      onEnterMap: (id) {
        Navigator.of(sheetContext).pop();
        onEnterMap(id);
      },
    ),
  );
}

class _PlacesSheet extends HookConsumerWidget {
  const _PlacesSheet({
    required this.databasePath,
    required this.novelId,
    required this.nav,
    required this.onSelect,
    required this.onEnterMap,
  });

  final String databasePath;
  final String novelId;
  final MapStudioNav nav;
  final ValueChanged<String?> onSelect;
  final ValueChanged<String> onEnterMap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    // 抽屉开着时增删地点要立刻反映，直接听地点流而不是用打开时的快照。
    final locations =
        ref.watch(locationsProvider(databasePath)).asData?.value ??
        nav.locationById.values.toList();
    // 默认展开到当前地图所在的那一层。
    final expandedIds = useState<Set<String>>({
      nav.world.id,
      for (final item in nav.trail) item.id,
    });
    final world =
        locations.where((item) => item.id == nav.world.id).firstOrNull ??
        nav.world;

    Future<void> deleteLocation(Location location) async {
      final service = ref.read(locationsServiceProvider(databasePath));
      final confirmed = await showMobileDeleteConfirm(
        context,
        title: location.name,
        blockedReason: screenplayInUseBlockedReason(
          context,
          introKey: LocaleKeys.screenplayLocationInUse,
          references: service.getScreenplaySceneReferences(location.id),
        ),
      );
      if (!confirmed) {
        return;
      }
      await service.deleteLocation(location.id);
    }

    Future<void> createLocation() async {
      final id = await ref
          .read(locationsServiceProvider(databasePath))
          .createLocationWithDefaultName(
            defaultName: context.t(LocaleKeys.mobileEditorNewLocation),
            type: locationTypeRegion,
            parentId: nav.owner.id,
          );
      if (!context.mounted) {
        return;
      }
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

    Widget? enterMapButton(Location location) {
      final hasChildren = locations.any((item) => item.parentId == location.id);
      if (!hasChildren || location.id == nav.owner.id) {
        return null;
      }
      final mapped = nav.mappedLocationIds.contains(location.id);
      return IconButton(
        key: ValueKey('mobile_map_places_enter_${location.id}'),
        tooltip: context.t(
          mapped
              ? LocaleKeys.mapEditorStudioOpenMap
              : LocaleKeys.mapEditorStudioNewMap,
        ),
        onPressed: () => onEnterMap(location.id),
        icon: RevericIcon(
          RevericIcons.map_outlined,
          size: 18,
          color: mapped ? colors.accent : colors.textSubtle,
        ),
      );
    }

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.78,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x2l,
              0,
              RevericSpacing.md,
              RevericSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.t(LocaleKeys.mapEditorStudioRailPlaces),
                    style: typo.heading2,
                  ),
                ),
                IconButton(
                  key: const ValueKey('mobile_map_places_create'),
                  tooltip: context.t(LocaleKeys.mobileEditorNewLocation),
                  onPressed: createLocation,
                  icon: const RevericIcon(RevericIcons.add, size: 20),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.borderSubtle),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                RevericSpacing.lg,
                RevericSpacing.lg,
                RevericSpacing.lg,
                RevericSpacing.lg + MediaQuery.of(context).padding.bottom,
              ),
              children: [
                MobileLocationTreeItem(
                  location: world,
                  allLocations: locations,
                  expandedIds: expandedIds,
                  depth: 0,
                  onTap: (location) => onSelect(location.id),
                  onDelete: deleteLocation,
                  trailingBuilder: enterMapButton,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
