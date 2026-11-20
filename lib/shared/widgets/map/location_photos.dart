// 职责: 展示地点照片条，导入、移除与改名后立即写入地点。
// 关联文件:
//   lib/shared/services/maps_service.dart
//   lib/shared/services/image_library_service.dart
//   lib/shared/widgets/subject_photo_name.dart
//   lib/desktop/features/map/map_cartographer_panel.dart
//   lib/mobile/pages/location_editor_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/error-handling.md
//   .agents/rules/file-access.md

import 'package:flutter/material.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../database/novel_content_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../providers/maps_providers.dart';
import '../../providers/novel_providers.dart';
import '../../services/maps_service.dart';
import '../../theme/theme.dart';
import '../media_asset_image.dart';
import '../subject_photo_name.dart';

final _log = AppLogger.forModule('Photo');

class LocationPhotos extends HookConsumerWidget {
  const LocationPhotos({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.location,
    required this.pickImages,
  });

  final String databasePath;
  final String novelId;
  final Location location;

  /// 平台选图入口，返回 `dart:io` 可读的图片路径；取消时返回空列表。
  final Future<List<String>> Function() pickImages;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adding = useState(false);
    final photos = location.photos ?? const <SubjectPhoto>[];
    final mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final tileSize = mobile ? 80.0 : 76.0;
    // 只在增删改名时取 service，渲染照片区不打开作品数据库。
    LocationsService service() =>
        ref.read(locationsServiceProvider(databasePath));

    void showFailure() {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
        );
      }
    }

    Future<void> add() async {
      if (adding.value) {
        return;
      }
      adding.value = true;
      try {
        final selected = await pickImages();
        if (selected.isEmpty) {
          return;
        }
        final library = ref.read(imageLibraryServiceProvider);
        // 逐张导入，单张失败跳过不影响其余；导入完成后一次写入地点。
        final imported = <String>[];
        var failed = false;
        for (final path in selected) {
          try {
            final asset = await library.importFile(
              path,
              novelId: novelId,
              purpose: AssetPurpose.photo,
            );
            imported.add(asset.id);
          } catch (error, stackTrace) {
            failed = true;
            _log.error(
              'Location photo import failed '
              'location=${location.id}',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
        if (imported.isNotEmpty) {
          await service().addPhotos(id: location.id, assetIds: imported);
        }
        if (failed) {
          showFailure();
        }
      } catch (error, stackTrace) {
        _log.error(
          'Location photo add failed location=${location.id}',
          error: error,
          stackTrace: stackTrace,
        );
        showFailure();
      } finally {
        if (context.mounted) {
          adding.value = false;
        }
      }
    }

    Future<void> remove(String assetId) async {
      try {
        await service().removePhoto(id: location.id, assetId: assetId);
      } catch (_) {
        // removePhoto 已记录 [DB] 日志，这里只负责提示。
        showFailure();
      }
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final photo in photos) ...[
            SizedBox(
              key: ValueKey('location_photo_${photo.assetId}'),
              width: tileSize,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PhotoThumbnail(
                    assetId: photo.assetId,
                    size: tileSize,
                    onRemove: () => remove(photo.assetId),
                  ),
                  SubjectPhotoName(
                    photo: photo,
                    onRename: (name) async {
                      await service().renamePhoto(
                        id: location.id,
                        assetId: photo.assetId,
                        name: name,
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
          _AddPhotoTile(size: tileSize, adding: adding.value, onTap: add),
        ],
      ),
    );
  }
}

class _PhotoThumbnail extends StatelessWidget {
  const _PhotoThumbnail({
    required this.assetId,
    required this.size,
    required this.onRemove,
  });

  final String assetId;
  final double size;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(RevericRadius.large),
            child: MediaAssetImage(
              assetId: assetId,
              placeholder: ColoredBox(
                color: colors.surfaceDim,
                child: Center(
                  child: RevericIcon(
                    RevericIcons.broken_image_outlined,
                    size: 22,
                    color: colors.textSubtle,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: RevericSpacing.xxs,
            right: RevericSpacing.xxs,
            child: Tooltip(
              message: context.t(LocaleKeys.commonRemove),
              child: Material(
                color: colors.surface.withValues(alpha: 0.92),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onRemove,
                  child: Padding(
                    padding: const EdgeInsets.all(RevericSpacing.xxs),
                    child: RevericIcon(
                      RevericIcons.close,
                      size: 14,
                      color: colors.error,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddPhotoTile extends StatelessWidget {
  const _AddPhotoTile({
    required this.size,
    required this.adding,
    required this.onTap,
  });

  final double size;
  final bool adding;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final radius = BorderRadius.circular(RevericRadius.large);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('location_photo_add'),
        onTap: adding ? null : onTap,
        borderRadius: radius,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: colors.borderInput),
          ),
          child: adding
              ? const Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    RevericIcon(
                      RevericIcons.add,
                      size: 18,
                      color: colors.textMuted,
                    ),
                    const SizedBox(height: RevericSpacing.xxs),
                    Text(
                      context.t(LocaleKeys.commonAdd),
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
