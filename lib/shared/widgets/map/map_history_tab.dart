// 职责: 地图历史面板 — 按作品筛选地图图片资产并提供预览入口。
// 关联文件:
//   lib/shared/models/map_asset_metadata.dart
//   lib/shared/providers/map_studio_controller.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/state-management.md

import 'dart:io';
import 'package:reveric/shared/models/asset_purpose.dart';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../database/app_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../providers/novel_providers.dart';
import '../../theme/theme.dart';
import '../../models/map_asset_metadata.dart';

class MapHistoryTab extends ConsumerWidget {
  const MapHistoryTab({
    super.key,
    required this.novelId,
    required this.onSelected,
  });

  final String novelId;
  final ValueChanged<AssetRow> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(
      imageAssetsProvider(novelId, purpose: AssetPurpose.map.value),
    );
    return assets.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: Text(
          context.t(LocaleKeys.mapEditorStudioHistoryLoadFailed),
          style: RevericTheme.typographyOf(
            context,
          ).uiSmall.copyWith(color: RevericTheme.colorsOf(context).textMuted),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(RevericSpacing.xl),
              child: Text(
                context.t(LocaleKeys.mapEditorStudioHistoryEmpty),
                textAlign: TextAlign.center,
                style: RevericTheme.typographyOf(context).uiSmall.copyWith(
                  color: RevericTheme.colorsOf(context).textMuted,
                ),
              ),
            ),
          );
        }
        return ListView.separated(
          key: const ValueKey('map_history_list'),
          padding: const EdgeInsets.all(RevericSpacing.md),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: RevericSpacing.sm),
          itemBuilder: (context, index) {
            final asset = items[index];
            return _MapHistoryRow(asset: asset, onTap: () => onSelected(asset));
          },
        );
      },
    );
  }
}

class _MapHistoryRow extends ConsumerWidget {
  const _MapHistoryRow({required this.asset, required this.onTap});

  final AssetRow asset;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final path = ref.read(imageLibraryServiceProvider).resolve(asset.path);
    final metadata = MapAssetMetadata.fromJson(asset.metadataJson);
    final specs = <String>[
      if (metadata.styleWord != null) metadata.styleWord!,
      if (metadata.resolutionId != null) metadata.resolutionId!.toUpperCase(),
      if (metadata.qualityId != null)
        context.t(_qualityLabelKey(metadata.qualityId!)),
      ?metadata.customSize?.replaceFirst('x', ' × '),
      ?metadata.customQuality,
      if ((asset.model ?? '').trim().isNotEmpty) asset.model!.trim(),
    ];
    final sourceName = metadata.sourceMapName;
    final created = _formatDate(asset.createdAt);

    return Material(
      color: colors.surfaceContainer,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: InkWell(
        key: ValueKey('map_history_asset_${asset.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Padding(
          padding: const EdgeInsets.all(RevericSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(RevericRadius.small),
                child: SizedBox(
                  width: 84,
                  height: 58,
                  child: path == null
                      ? ColoredBox(color: colors.surfaceContainerHigh)
                      : Image.file(
                          File(path),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => ColoredBox(
                            color: colors.surfaceContainerHigh,
                            child: Center(
                              child: RevericIcon(
                                RevericIcons.image_outlined,
                                size: 18,
                                color: colors.textSubtle,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sourceName ?? context.t(LocaleKeys.mapEditorStudioTitle),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmallSemibold,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [created, ...specs].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                    if ((asset.prompt ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        asset.prompt!.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiTiny.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
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

String _formatDate(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

String _qualityLabelKey(String qualityId) => switch (qualityId) {
  'low' => LocaleKeys.mapEditorQualityLow,
  'high' => LocaleKeys.mapEditorQualityHigh,
  _ => LocaleKeys.mapEditorQualityMedium,
};
