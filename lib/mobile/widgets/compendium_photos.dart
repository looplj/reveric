// 职责: 在移动端图鉴条目中展示照片并支持添加、移除与改名。
// 关联文件:
//   lib/mobile/pages/entry_editor_page.dart
//   lib/shared/services/item_photo_import_orchestrator.dart
//   lib/shared/widgets/media_asset_image.dart
//   lib/shared/widgets/subject_photo_name.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/file-access.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../shared/components/reveric_button.dart';
import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/services/item_photo_import_orchestrator.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/media_asset_image.dart';
import '../../shared/widgets/subject_photo_name.dart';

final _log = AppLogger.forModule('Photo');

class MobileCompendiumPhotos extends HookConsumerWidget {
  const MobileCompendiumPhotos({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.item,
  });

  final String databasePath;
  final String novelId;
  final Item item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = useState(false);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final content = ref
        .read(novelContentServiceProvider(databasePath))
        .forNovel(novelId);

    Future<void> run(Future<void> Function() action) async {
      if (busy.value) {
        return;
      }
      busy.value = true;
      try {
        await action();
      } catch (error, stackTrace) {
        _log.error(
          'Compendium photo update failed id=${item.id}',
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
          busy.value = false;
        }
      }
    }

    Future<void> add() async {
      final library = ref.read(imageLibraryServiceProvider);
      // image_picker 返回应用缓存中的可读副本，与移动端地点照片入口一致。
      final selected = await ImagePicker().pickMultiImage();
      if (selected.isEmpty) {
        return;
      }
      await ItemPhotoImportOrchestrator().import(
        content: content,
        library: library,
        itemId: item.id,
        paths: selected.map((file) => file.path).toList(),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t(LocaleKeys.workspaceItemPhotos), style: typo.uiSemibold),
        const SizedBox(height: RevericSpacing.md),
        Wrap(
          spacing: RevericSpacing.md,
          runSpacing: RevericSpacing.md,
          children: [
            for (final photo in item.photos ?? const <SubjectPhoto>[])
              SizedBox(
                key: ValueKey('compendium-photo-${photo.assetId}'),
                width: 96,
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(RevericRadius.large),
                      child: SizedBox.square(
                        dimension: 96,
                        child: MediaAssetImage(
                          assetId: photo.assetId,
                          placeholder: ColoredBox(
                            color: colors.surfaceDim,
                            child: const Center(
                              child: RevericIcon(RevericIcons.image),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SubjectPhotoName(
                      photo: photo,
                      onRename: (name) =>
                          content.renameItemPhoto(item.id, photo.assetId, name),
                    ),
                    RevericButton.text(
                      label: context.t(LocaleKeys.commonRemove),
                      onPressed: busy.value
                          ? null
                          : () => run(
                              () => content.removeItemPhoto(
                                item.id,
                                photo.assetId,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        RevericButton.text(
          label: context.t(LocaleKeys.commonAdd),
          onPressed: busy.value ? null : () => run(add),
        ),
      ],
    );
  }
}
