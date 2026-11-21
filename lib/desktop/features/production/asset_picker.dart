// 职责: 资产库选择弹窗 — 列出已收进资产库的素材，按类型筛选、单选或移出，可就地导入媒体文件。
// 关联文件:
//   lib/desktop/features/production/support.dart
//   lib/desktop/features/production/node_card.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/share_asset_orchestrator.dart
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/assets.json
//   assets/translations/zh-CN/assets.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/file-access.md

import 'dart:io';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_filter_chip.dart';
import '../../../shared/components/reveric_more_menu_button.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/ffmpeg_runner.dart'
    show MediaCancellation;
import '../../../shared/services/production/share_asset_orchestrator.dart';
import '../../../shared/theme/theme.dart';
import '../asset/library_menu_item.dart';
import 'node_card.dart' show ProductionAssetThumb;
import 'support.dart' show productionRun;
import 'builtin_voices.dart';

final _log = AppLogger.forModule('Production');

/// 类型标签顺序与文案；只列调用方允许的类型。
const _typeLabels = {
  'image': LocaleKeys.mediaImages,
  'video': LocaleKeys.mediaVideos,
  'audio': LocaleKeys.mediaAudio,
};

const _mediaExtensions = {
  'image': ['png', 'jpg', 'jpeg', 'webp'],
  'video': ['mp4', 'mov'],
  'audio': ['mp3', 'wav', 'm4a'],
};

class ProductionAssetPicker extends HookWidget {
  const ProductionAssetPicker({
    super.key,
    required this.service,
    required this.types,
    this.confirmLabel,
    this.addToCanvas,
  });
  final ProductionCanvasService service;
  final Set<String> types;

  /// 主按钮文案；默认「确认」。
  final String? confirmLabel;
  final Future<void> Function(AssetRow)? addToCanvas;

  static const double _width = 860;
  static const double _gridHeight = 440;
  static const double _cardHeight = 164;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final showSources = addToCanvas != null;
    final source = useState<String?>(service.novelId);
    final tab = useState<String?>(null);
    final picked = useState<AssetRow?>(null);
    final importing = useState(false);
    final adding = useState(false);
    final sharedForPlacement = useState<String?>(null);
    final failure = useState<String?>(null);
    final database = service.library.database;
    final assets = useStream(
      useMemoized(
        () => database.assetDao
            .watchAssets(
              novelId: showSources ? null : service.novelId,
              inLibrary: true,
            )
            .map(
              (rows) =>
                  rows.where((asset) => types.contains(asset.type)).toList(),
            ),
        [database, service.novelId, showSources, types.join('|')],
      ),
    );
    final works = useStream(
      useMemoized(() => showSources ? database.novelDao.watchAll() : null, [
        database,
        showSources,
      ]),
    );
    final rows = assets.data ?? const <AssetRow>[];
    final visible = rows
        .where(
          (asset) =>
              (!showSources || asset.novelId == source.value) &&
              (tab.value == null || asset.type == tab.value),
        )
        .toList();
    final owners = showSources
        ? {
            for (final asset in rows)
              if (tab.value == null || asset.type == tab.value) asset.novelId,
          }
        : const <String?>{};
    final otherWorks = [
      for (final work in works.data ?? const <Novel>[])
        if (work.id != service.novelId && owners.contains(work.id)) work,
    ];
    final loadFailed = assets.hasError || works.hasError;
    useEffect(() {
      if (loadFailed) {
        _log.error(
          'asset picker failed to load sources',
          error: assets.error ?? works.error,
          stackTrace: assets.hasError ? assets.stackTrace : works.stackTrace,
        );
      }
      return null;
    }, [assets.error, works.error]);
    final extensions = [for (final type in types) ...?_mediaExtensions[type]];
    final selected = picked.value;
    final busy = importing.value || adding.value;

    bool needsSharing(AssetRow asset) =>
        showSources &&
        asset.novelId != null &&
        asset.novelId != service.novelId;

    void chooseAsset(AssetRow? asset) {
      picked.value = asset;
      failure.value = null;
    }

    void chooseSource(String? novelId) {
      if (source.value != novelId) {
        source.value = novelId;
        chooseAsset(null);
      }
    }

    void chooseType(String? type) {
      if (busy || tab.value == type) {
        return;
      }
      tab.value = type;
      if (showSources) {
        chooseAsset(null);
        final activeSource = source.value;
        if (activeSource != null &&
            activeSource != service.novelId &&
            !rows.any(
              (asset) =>
                  asset.novelId == activeSource &&
                  (type == null || asset.type == type),
            )) {
          source.value = service.novelId;
        }
      }
    }

    Future<void> confirm(AssetRow asset) async {
      final place = addToCanvas;
      if (place == null) {
        Navigator.pop(context, asset);
        return;
      }
      if (adding.value) {
        return;
      }
      adding.value = true;
      failure.value = null;
      final share = needsSharing(asset);
      var ready = asset;
      try {
        if (share) {
          ready = await ShareAssetOrchestrator().run(
            library: service.library,
            assetId: asset.id,
            sourceNovelId: asset.novelId!,
          );
          if (!context.mounted) {
            return;
          }
          sharedForPlacement.value = ready.id;
          source.value = null;
          picked.value = ready;
        }
        await place(ready);
        if (context.mounted) {
          Navigator.pop(context, ready);
        }
      } catch (error, stack) {
        _log.error(
          'asset picker add failed id=${asset.id}',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          failure.value = sharedForPlacement.value == asset.id
              ? LocaleKeys.productionAssetSharedPlacementFailed
              : share
              ? LocaleKeys.productionAssetShareFailed
              : LocaleKeys.productionFailed;
        }
      } finally {
        if (context.mounted) {
          adding.value = false;
        }
      }
    }

    Future<void> import() async {
      importing.value = true;
      try {
        final file = await openFile(
          acceptedTypeGroups: [
            XTypeGroup(
              label: context.t(LocaleKeys.productionAssets),
              extensions: extensions,
            ),
          ],
        );
        if (file == null) {
          return;
        }
        final asset = await service.library.importFile(
          File(file.path),
          name: file.name,
          novelId: service.novelId,
          purpose: AssetPurpose.production_upload,
          cancellation: MediaCancellation(),
        );
        if (context.mounted && types.contains(asset.type)) {
          tab.value = null;
          source.value = service.novelId;
          chooseAsset(asset);
        }
      } catch (error, stack) {
        _log.error(
          'asset picker import failed',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.mediaImportFailed))),
          );
        }
      } finally {
        if (context.mounted) {
          importing.value = false;
        }
      }
    }

    final grid = loadFailed
        ? Center(child: Text(context.t(LocaleKeys.productionAssetLoadFailed)))
        : !assets.hasData || (showSources && !works.hasData)
        ? const Center(child: CircularProgressIndicator())
        : visible.isEmpty
        ? Center(
            child: Text(
              context.t(LocaleKeys.mediaEmpty),
              style: typo.ui.copyWith(color: colors.textMuted),
            ),
          )
        : GridView.builder(
            gridDelegate: showSources
                ? const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160,
                    mainAxisExtent: _cardHeight,
                    mainAxisSpacing: RevericSpacing.md,
                    crossAxisSpacing: RevericSpacing.md,
                  )
                : const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisExtent: _cardHeight,
                    mainAxisSpacing: RevericSpacing.md,
                    crossAxisSpacing: RevericSpacing.md,
                  ),
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final asset = visible[index];
              final isSelected = selected?.id == asset.id;
              final foreign = needsSharing(asset);
              return _Card(
                key: ValueKey(asset.id),
                service: service,
                asset: asset,
                selected: isSelected,
                onTap: busy || (isSelected && foreign)
                    ? null
                    : isSelected
                    ? () => confirm(asset)
                    : () => chooseAsset(asset),
                canManage: !busy && !foreign,
              );
            },
          );

    final dialog = RevericDialog.panel(
      width: _width,
      title: Text(context.t(LocaleKeys.productionAssets)),
      content: SizedBox(
        width: _width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (types.length > 1)
                  Expanded(
                    child: Wrap(
                      spacing: RevericSpacing.xs,
                      runSpacing: RevericSpacing.xs,
                      children: [
                        RevericFilterChip(
                          label: context.t(LocaleKeys.commonFilterAll),
                          selected: tab.value == null,
                          onTap: () => chooseType(null),
                        ),
                        for (final entry in _typeLabels.entries)
                          if (types.contains(entry.key))
                            RevericFilterChip(
                              label: context.t(entry.value),
                              selected: tab.value == entry.key,
                              onTap: () => chooseType(entry.key),
                            ),
                      ],
                    ),
                  )
                else
                  const Spacer(),
                if (types.contains('audio')) ...[
                  RevericButton.secondary(
                    label: context.t(LocaleKeys.productionBuiltinVoices),
                    icon: RevericIcons.music_notes,
                    onPressed: busy
                        ? null
                        : () async {
                            importing.value = true;
                            try {
                              final asset = await pickProductionBuiltinVoice(
                                context,
                                service,
                              );
                              if (asset != null && context.mounted) {
                                chooseAsset(asset);
                                await confirm(asset);
                              }
                            } finally {
                              if (context.mounted) {
                                importing.value = false;
                              }
                            }
                          },
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                ],
                if (extensions.isNotEmpty)
                  RevericButton.secondary(
                    label: context.t(LocaleKeys.commonImport),
                    icon: RevericIcons.upload,
                    loading: importing.value,
                    onPressed: busy ? null : import,
                  ),
              ],
            ),
            const SizedBox(height: RevericSpacing.lg),
            SizedBox(
              height: _gridHeight,
              child: showSources
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 156,
                          child: _AssetSourceTree(
                            currentWorkId: service.novelId,
                            source: source.value,
                            works: otherWorks,
                            onChoose: busy ? null : chooseSource,
                          ),
                        ),
                        VerticalDivider(
                          width: RevericSpacing.x2l,
                          color: colors.borderSubtle,
                        ),
                        Expanded(child: grid),
                      ],
                    )
                  : grid,
            ),
            if (failure.value case final failureKey? when showSources) ...[
              const SizedBox(height: RevericSpacing.md),
              Semantics(
                liveRegion: true,
                child: Text(
                  context.t(failureKey),
                  style: typo.uiSmall.copyWith(color: colors.error),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        RevericButton.secondary(
          label: context.t(LocaleKeys.commonCancel),
          onPressed: adding.value ? null : () => Navigator.pop(context),
        ),
        RevericButton.primary(
          label: showSources
              ? context.t(
                  selected != null && needsSharing(selected)
                      ? LocaleKeys.productionAssetShareAndAdd
                      : LocaleKeys.productionAssetAddToCanvas,
                )
              : confirmLabel ?? context.t(LocaleKeys.commonConfirm),
          loading: adding.value,
          onPressed: selected == null || busy ? null : () => confirm(selected),
        ),
      ],
    );
    return PopScope(canPop: !adding.value, child: dialog);
  }
}

class _AssetSourceTree extends HookWidget {
  const _AssetSourceTree({
    required this.currentWorkId,
    required this.source,
    required this.works,
    required this.onChoose,
  });

  final String currentWorkId;
  final String? source;
  final List<Novel> works;
  final ValueChanged<String?>? onChoose;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final expanded = useState(false);

    Widget row({
      required String label,
      required String icon,
      bool selected = false,
      bool nested = false,
      VoidCallback? onTap,
    }) => Semantics(
      selected: selected,
      child: Material(
        color: selected ? colors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: InkWell(
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              nested ? RevericSpacing.xl : RevericSpacing.sm,
              RevericSpacing.sm,
              RevericSpacing.sm,
              RevericSpacing.sm,
            ),
            child: Row(
              children: [
                RevericIcon(icon, size: 14, color: colors.textMuted),
                const SizedBox(width: RevericSpacing.sm),
                Expanded(
                  child: Tooltip(
                    message: label,
                    child: Text(
                      label,
                      style: typo.uiSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return ListView(
      primary: false,
      children: [
        row(
          label: context.t(LocaleKeys.productionAssetCurrentWork),
          icon: RevericIcons.folder_outlined,
          selected: source == currentWorkId,
          onTap: onChoose == null ? null : () => onChoose!(currentWorkId),
        ),
        row(
          label: context.t(LocaleKeys.productionAssetShared),
          icon: RevericIcons.stack,
          selected: source == null,
          onTap: onChoose == null ? null : () => onChoose!(null),
        ),
        row(
          label: context.t(LocaleKeys.productionAssetOtherWorks),
          icon: expanded.value
              ? RevericIcons.caret_down
              : RevericIcons.caret_right,
          onTap: works.isEmpty || onChoose == null
              ? null
              : () => expanded.value = !expanded.value,
        ),
        if (expanded.value)
          for (final work in works)
            row(
              label: work.title,
              icon: RevericIcons.folder_outlined,
              selected: source == work.id,
              nested: true,
              onTap: onChoose == null ? null : () => onChoose!(work.id),
            ),
      ],
    );
  }
}

/// 一张素材卡：缩略图、名称、类型 · 规格；在已选中的卡上再点一下直接选定。
class _Card extends HookWidget {
  const _Card({
    super.key,
    required this.service,
    required this.asset,
    required this.selected,
    required this.onTap,
    required this.canManage,
  });
  final ProductionCanvasService service;
  final AssetRow asset;
  final bool selected;
  final VoidCallback? onTap;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final hovered = useState(false);
    final spec = asset.width != null && asset.height != null
        ? '${asset.width}×${asset.height}'
        : asset.durationMs != null
        ? '${(asset.durationMs! / 1000).toStringAsFixed(1)}s'
        : null;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => hovered.value = true,
      onExit: (_) => hovered.value = false,
      child: GestureDetector(
        // 不用 onDoubleTap：它会把单击延迟到双击超时之后，选中反馈发钝。
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(RevericRadius.large),
            border: Border.all(
              color: selected
                  ? colors.accent
                  : hovered.value
                  ? colors.borderInput
                  : colors.borderSubtle,
            ),
            boxShadow: [
              if (selected)
                BoxShadow(
                  color: colors.accent.withValues(alpha: .3),
                  spreadRadius: 2,
                ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(RevericRadius.medium),
                      child: ProductionAssetThumb(
                        service: service,
                        asset: asset,
                      ),
                    ),
                    if (hovered.value && canManage)
                      Positioned(
                        top: RevericSpacing.xxs,
                        right: RevericSpacing.xxs,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surface,
                            borderRadius: BorderRadius.circular(
                              RevericRadius.small,
                            ),
                          ),
                          child: RevericMoreMenuButton(
                            iconSize: 16,
                            entries: () => [
                              assetLibraryMenuItem(
                                context,
                                asset: asset,
                                onToggle: () => productionRun(
                                  context,
                                  () => service.library.database.assetDao
                                      .setInLibrary(asset.id, false),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: RevericSpacing.xs),
              Text(
                asset.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
              ),
              Text(
                [
                  context.t(_typeLabels[asset.type] ?? LocaleKeys.mediaTitle),
                  ?spec,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiTiny.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
