// 职责: 参考图小节 — 序号化列出已选参考图与图片库/本地选图，数量卡在模型上限。
// 关联文件:
//   lib/shared/providers/cover_studio_providers.dart
//   lib/shared/services/cover_prompt_builder.dart
//   lib/shared/services/image_library_service.dart
//   lib/desktop/features/cover_studio/designer.dart
//   lib/mobile/features/cover_studio/designer_sheet.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
//   .agents/rules/i18n.md

import 'dart:io';
import 'package:reveric/shared/models/asset_purpose.dart';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/dotted_border_box.dart';
import '../../database/app_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../providers/cover_studio_providers.dart';
import '../../providers/novel_providers.dart';
import '../../theme/theme.dart';
import 'chips.dart';

/// 从本地选图，返回选中文件的绝对路径；用户取消时返回空列表。
///
/// 桌面走 `file_selector` 的系统文件对话框，移动走 `ImagePicker` 相册，两者的
/// 依赖都不该进共享层，所以由调用方注入。
typedef CoverReferencePicker = Future<List<String>> Function();

class CoverReferenceSection extends HookConsumerWidget {
  const CoverReferenceSection({
    super.key,
    required this.novelId,
    required this.libraryAssets,
    required this.pickImagePaths,
  });

  final String novelId;
  final List<AssetRow> libraryAssets;
  final CoverReferencePicker pickImagePaths;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final uploading = useState(false);
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );
    ref.watch(coverImageChoicesProvider);
    final limit = controller.referenceLimit;
    final atLimit = limit != null && state.references.length >= limit;
    final byId = {for (final asset in libraryAssets) asset.id: asset};

    Future<void> pickFile() async {
      if (uploading.value || atLimit) {
        return;
      }
      final paths = await pickImagePaths();
      if (paths.isEmpty) {
        return;
      }
      uploading.value = true;
      try {
        // 循环中 state 会变，每次读最新 references 判断上限；截断时补一次提示。
        var truncated = false;
        for (final path in paths) {
          final currentReferences = ref
              .read(coverStudioControllerProvider(novelId))
              .references;
          final currentLimit = controller.referenceLimit;
          if (currentLimit != null &&
              currentReferences.length >= currentLimit) {
            truncated = true;
            break;
          }
          final imported = await ref
              .read(imageLibraryServiceProvider)
              .importFile(
                path,
                novelId: novelId,
                purpose: AssetPurpose.reference,
                source: 'uploaded',
              );
          controller.addReference(imported.id);
        }
        if (truncated) {
          controller.notifyReferenceLimit();
        }
      } finally {
        uploading.value = false;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CoverSectionHead(
          icon: RevericIcons.image_outlined,
          label: context.t(LocaleKeys.editorCoverReferences),
          trailing: TextButton(
            onPressed: atLimit && !state.pickingReference
                ? null
                : controller.togglePicking,
            child: Text(
              context.t(
                state.pickingReference
                    ? LocaleKeys.editorCoverReferenceCollapse
                    : LocaleKeys.editorCoverReferenceAdd,
              ),
            ),
          ),
        ),
        if (state.references.isEmpty && !state.pickingReference)
          DottedBorderBox(
            color: colors.border,
            borderRadius: RevericRadius.full,
            child: SizedBox(
              width: double.infinity,
              height: 96,
              child: InkWell(
                onTap: pickFile,
                borderRadius: BorderRadius.circular(RevericRadius.full),
                // 提示语在窄容器里放不下一行，英文尤其长：图标固定，文案可换行
                // 居中，不用 Row 硬挤。桌面侧栏 332px、移动抽屉也不宽。
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    RevericIcon(
                      RevericIcons.image_outlined,
                      size: 18,
                      color: colors.textMuted,
                    ),
                    const SizedBox(height: RevericSpacing.sm),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: RevericSpacing.md,
                      ),
                      child: Text(
                        context.t(LocaleKeys.editorCoverReferenceDropHint),
                        textAlign: TextAlign.center,
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        for (final (index, assetId) in state.references.indexed)
          _ReferenceRow(
            key: ValueKey(assetId),
            novelId: novelId,
            asset: byId[assetId],
            ordinal: index + 1,
          ),
        if (state.references.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.xs),
          Text(
            context.t(LocaleKeys.editorCoverReferenceUsageHint),
            style: typo.uiTiny.copyWith(color: colors.textSubtle),
          ),
        ],
        if (state.pickingReference && !atLimit) ...[
          const SizedBox(height: RevericSpacing.sm),
          _Picker(
            novelId: novelId,
            libraryAssets: libraryAssets,
            uploading: uploading.value,
            onUpload: pickFile,
          ),
        ],
      ],
    );
  }
}

/// 一行参考图：缩略图 + 「图 N」序号 + 文件名 + 删除。序号要和下发时 image N
/// 的顺序对齐，作者才能在提示词里点名说「图 2 保留构图」。
class _ReferenceRow extends ConsumerWidget {
  const _ReferenceRow({
    super.key,
    required this.novelId,
    required this.asset,
    required this.ordinal,
  });

  final String novelId;
  final AssetRow? asset;
  final int ordinal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );
    final current = asset;
    if (current == null) {
      return const SizedBox.shrink();
    }
    final path = ref.read(imageLibraryServiceProvider).resolve(current.path);

    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(RevericRadius.medium),
            child: SizedBox(
              width: 48,
              height: 58,
              child: path == null
                  ? ColoredBox(color: colors.surfaceContainer)
                  : Image.file(File(path), fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              context.t(
                LocaleKeys.editorCoverReferenceOrdinal,
                namedArgs: {'index': '$ordinal'},
              ),
              style: typo.uiSmall.copyWith(color: colors.textPrimary),
            ),
          ),
          IconButton(
            tooltip: context.t(LocaleKeys.commonDelete),
            onPressed: () => controller.removeReference(current.id),
            icon: const RevericIcon(RevericIcons.close, size: 12),
          ),
        ],
      ),
    );
  }
}

enum _AssetFilter { all, maps, covers, characters, uploads }

class _Picker extends HookConsumerWidget {
  const _Picker({
    required this.novelId,
    required this.libraryAssets,
    required this.uploading,
    required this.onUpload,
  });

  final String novelId;
  final List<AssetRow> libraryAssets;
  final bool uploading;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );
    final library = ref.read(imageLibraryServiceProvider);
    final filter = useState(_AssetFilter.all);
    final visibleAssets = libraryAssets.where((asset) {
      return switch (filter.value) {
        _AssetFilter.all => true,
        _AssetFilter.maps => asset.purpose == AssetPurpose.map.value,
        _AssetFilter.covers => asset.purpose == AssetPurpose.cover.value,
        _AssetFilter.characters =>
          asset.purpose == AssetPurpose.avatar.value ||
              asset.purpose == AssetPurpose.photo.value,
        _AssetFilter.uploads => asset.purpose == AssetPurpose.reference.value,
      };
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: uploading ? null : onUpload,
          icon: const RevericIcon(RevericIcons.upload, size: 15),
          label: Text(context.t(LocaleKeys.editorCoverReferenceUploadFile)),
        ),
        const SizedBox(height: RevericSpacing.sm),
        Text(
          context.t(LocaleKeys.editorCoverReferenceLibrary),
          style: typo.uiTiny.copyWith(color: colors.textSubtle),
        ),
        const SizedBox(height: RevericSpacing.xs),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final value in _AssetFilter.values)
              CoverChip(
                key: ValueKey('asset_filter_${value.name}'),
                label: context.t(_assetFilterLabel(value)),
                selected: filter.value == value,
                onTap: () => filter.value = value,
              ),
          ],
        ),
        const SizedBox(height: RevericSpacing.sm),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final asset in visibleAssets.take(12))
              Builder(
                builder: (context) {
                  final path = library.resolve(asset.path);
                  if (path == null) {
                    return const SizedBox.shrink();
                  }
                  return GestureDetector(
                    onTap: () => controller.addReference(asset.id),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(RevericRadius.medium),
                      child: Image.file(
                        File(path),
                        width: 42,
                        height: 50,
                        fit: BoxFit.cover,
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ],
    );
  }
}

String _assetFilterLabel(_AssetFilter filter) => switch (filter) {
  _AssetFilter.all => LocaleKeys.editorAssetFilterAll,
  _AssetFilter.maps => LocaleKeys.editorAssetFilterMaps,
  _AssetFilter.covers => LocaleKeys.editorAssetFilterCovers,
  _AssetFilter.characters => LocaleKeys.editorAssetFilterCharacters,
  _AssetFilter.uploads => LocaleKeys.editorAssetFilterUploads,
};
