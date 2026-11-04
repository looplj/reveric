// 职责: 将制片导入入口统一导入去重资产库，允许直接采用导入或资产库中的结果，并另存采用的结果。
// 关联文件:
//   lib/shared/services/production/library_service.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/desktop/features/production/popover.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/file-access.md
import 'dart:io';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../../../shared/components/reveric_popover.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/ffmpeg_runner.dart';
import '../../../shared/theme/theme.dart';
import 'popover.dart';
import 'support.dart';

Future<AssetRow?> uploadProductionAsset(
  BuildContext context,
  ProductionCanvasService service,
  Set<String> types,
) async {
  const extensions = {
    'image': ['png', 'jpg', 'jpeg', 'webp'],
    'video': ['mp4', 'mov'],
    'audio': ['mp3', 'wav', 'm4a'],
  };
  final file = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(
        extensions: [for (final type in types) ...extensions[type] ?? []],
      ),
    ],
  );
  if (file == null) {
    return null;
  }
  final asset = await service.library.importFile(
    File(file.path),
    name: file.name,
    novelId: service.novelId,
    purpose: AssetPurpose.production_upload,
    cancellation: MediaCancellation(),
  );
  if (!types.contains(asset.type)) {
    throw const FormatException('Unsupported upload type');
  }
  return asset;
}

/// 输入框顶部的「＋ 添加参考」：向上展开「导入 / 从资产库选择」，选中的素材交给 [onPicked] 补成一条输入。
class ProductionAddInputButton extends StatelessWidget {
  const ProductionAddInputButton({
    super.key,
    required this.service,
    required this.types,
    required this.onPicked,
    this.enabled = true,
  });
  final ProductionCanvasService service;
  final Set<String> types;
  final Future<void> Function(AssetRow asset) onPicked;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    Future<void> choose(bool upload) => productionRun(context, () async {
      final asset = upload
          ? await uploadProductionAsset(context, service, types)
          : await pickProductionAsset(
              context,
              service,
              types: types,
              confirmLabel: context.t(LocaleKeys.productionAddInput),
            );
      if (asset != null && context.mounted) {
        await onPicked(asset);
      }
    });
    return RevericPopover(
      up: true,
      trigger: (_, open, toggle) => ProductionToolChip(
        icon: RevericIcons.add,
        label: context.t(LocaleKeys.productionAddInput),
        tooltip: context.t(LocaleKeys.productionAddInputHint),
        open: open,
        onTap: enabled ? toggle : null,
      ),
      panel: (_, close) => ProductionPopoverPanel(
        width: 260,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProductionPopoverItem(
              icon: RevericIcons.upload,
              label: context.t(LocaleKeys.commonImport),
              onTap: () {
                close();
                choose(true);
              },
            ),
            ProductionPopoverItem(
              icon: RevericIcons.folder_outlined,
              label: context.t(LocaleKeys.productionPickLibrary),
              onTap: () {
                close();
                choose(false);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 把采用的视频 / 图片另存到用户选的位置。
Future<void> exportProductionAsset(
  ProductionCanvasService service,
  String assetId,
) async {
  final row = await service.requireAsset(assetId);
  final asset = await service.requireFile(row.path!, type: row.type);
  final source = service.library.resolvePath(asset.path);
  final extension = source.contains('.') ? source.split('.').last : '';
  final location = await getSaveLocation(
    suggestedName: extension.isEmpty || asset.name.endsWith('.$extension')
        ? asset.name
        : '${asset.name}.$extension',
  );
  if (location != null) {
    await XFile(source).saveTo(location.path);
  }
}

Future<void> uploadProductionResult(
  BuildContext context,
  ProductionCanvasService service,
  CanvasNode node,
) async {
  final asset = await uploadProductionAsset(context, service, {node.type});
  if (asset != null) {
    await service.adopt(node.id, asset.id);
  }
}

/// 从资产库选一个同类素材，直接作为生成节点的采用结果。
Future<void> pickProductionResult(
  BuildContext context,
  ProductionCanvasService service,
  CanvasNode node,
) async {
  final asset = await pickProductionAsset(context, service, types: {node.type});
  if (asset != null) {
    await service.adopt(node.id, asset.id);
  }
}
