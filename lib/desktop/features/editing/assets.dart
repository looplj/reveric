// 职责: 右栏「素材」：按片段采用结果与资产库里的视频、图片、音频分组列出素材，支持筛选、导入、加入或移出资产库、拖到时间线、加到播放头和替换。
// 关联文件:
//   lib/desktop/features/editing/controller.dart
//   lib/shared/providers/production_media.dart
//   lib/shared/providers/storyboard.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/file-access.md
import 'dart:io';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/components/reveric_more_menu_button.dart';
import '../../../shared/components/reveric_segmented_control.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/production_media.dart';
import '../../../shared/providers/screenplay_providers.dart';
import '../../../shared/providers/storyboard.dart';
import '../../../shared/services/production/ffmpeg_runner.dart';
import '../../../shared/services/production/media_file.dart';
import '../../../shared/theme/theme.dart';
import '../asset/library_menu_item.dart';
import 'controller.dart';
import '../../../shared/services/editing/service.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/models/screenplay.dart';
import 'inspector.dart';
import 'support.dart';

class EditingAssets extends HookConsumerWidget {
  const EditingAssets({
    super.key,
    required this.controller,
    required this.novelId,
    required this.path,
    required this.episodeId,
  });
  final EditingController controller;
  final String novelId;

  /// 内容库路径，用来读本集片段的采用结果。
  final String path;
  final String? episodeId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final assets = ref.watch(mediaAssetsProvider).value ?? const [];
    final adoptedById = {for (final asset in assets) asset.id: asset};
    final shots = episodeId == null
        ? const <ProductionClipRow>[]
        : ref.watch(storyboardShotsProvider(path, episodeId!)).value ??
              const [];
    final scenes = episodeId == null
        ? const <ScreenplaySceneSummary>[]
        : ref.watch(screenplayScenesProvider(path, episodeId!)).value ??
              const [];
    final canvasClips = useStream(
      useMemoized(
        () => episodeId == null
            ? controller.session.projects.watchCanvasAdopted(
                controller.session.editingId,
              )
            : const Stream<List<EditingAdoptedClip>>.empty(),
        [controller.session, episodeId],
      ),
    );
    final replaceFor = controller.replaceFor;
    final filter = useState('video');
    final busy = useState(false);
    useEffect(() {
      if (replaceFor != null) {
        filter.value = 'video';
      }
      return null;
    }, [replaceFor]);
    final library = controller.session.projects.library;
    final doc = controller.doc;
    final used = <String, int>{};
    for (final c in doc.clips) {
      if (c.media != null) {
        used.update(c.media!.source.assetId, (n) => n + 1, ifAbsent: () => 1);
      }
    }

    Future<void> act(Future<void> Function() action) async {
      busy.value = true;
      try {
        await editingRun(context, action);
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    Future<void> import() async {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Media',
            extensions: [
              'mp4',
              'mov',
              'mkv',
              'webm',
              'png',
              'jpg',
              'jpeg',
              'webp',
              'wav',
              'mp3',
              'm4a',
              'flac',
              'ogg',
              'aac',
            ],
          ),
        ],
      );
      if (file == null) {
        return;
      }
      await library.importFile(
        File(file.path),
        name: file.name,
        novelId: novelId,
        purpose: AssetPurpose.editing_upload,
        addToLibrary: true,
        cancellation: MediaCancellation(),
      );
    }

    Widget item(EditingMedia media, {String? subtitle, bool tile = false}) {
      final count = used[media.assetId];
      final canReplace =
          replaceFor != null &&
          (media.type == 'video' || media.type == 'image');
      final asset = adoptedById[media.assetId];
      final primary = canReplace
          ? RevericButton.secondary(
              label: context.t(LocaleKeys.editingReplaceAction),
              size: RevericButtonSize.compact,
              onPressed: busy.value
                  ? null
                  : () => act(() => controller.replace(context, media)),
            )
          : RevericIconButton(
              icon: RevericIcons.add,
              tooltip: context.t(LocaleKeys.editingAddAtPlayhead),
              onPressed: busy.value
                  ? null
                  : () => act(() => controller.addAtPlayhead(context, media)),
            );
      return _BinItem(
        media: media,
        tile: tile,
        thumbPath: library.resolvePath(media.path),
        subtitle: [
          ?subtitle,
          if (count != null)
            context.t(
              LocaleKeys.editingUsedCount,
              namedArgs: {'count': '$count'},
            ),
        ].join(' · '),
        action: asset == null
            ? primary
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  primary,
                  RevericMoreMenuButton(
                    entries: () => [
                      assetLibraryMenuItem(
                        context,
                        asset: asset,
                        onToggle: () => act(
                          () => library.database.assetDao.setInLibrary(
                            asset.id,
                            !asset.inLibrary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      );
    }

    Widget section(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.xs,
        RevericSpacing.md,
        RevericSpacing.xs,
        RevericSpacing.xs,
      ),
      child: Text(
        label,
        style: typo.uiTinySemibold.copyWith(color: colors.textSubtle),
      ),
    );

    final sceneById = {for (final s in scenes) s.id: s};
    final perScene = <String, int>{};
    final segments = episodeId == null
        ? [
            for (final clip in canvasClips.data ?? <EditingAdoptedClip>[])
              (
                clipId: clip.id,
                title: clip.title.trim().isEmpty
                    ? context.t(LocaleKeys.productionVideoTag)
                    : clip.title,
                assetId: clip.assetId,
                number: null as String?,
              ),
          ]
        : [
            for (final shot in shots.where((s) => s.kind == 'video'))
              (
                clipId: shot.id,
                title: shot.title,
                assetId: shot.adoptedAssetId,
                number:
                    '${sceneById[shot.sceneId]?.sceneNumber ?? '?'}.${perScene.update(shot.sceneId ?? '', (n) => n + 1, ifAbsent: () => 1)}'
                        as String?,
              ),
          ];
    final adoptedIds = {
      for (final s in segments)
        if (s.assetId != null) s.assetId!,
    };
    List<EditingMedia> of(String type) => [
      for (final a in assets)
        if (a.path != null &&
            a.inLibrary &&
            (a.novelId == null || a.novelId == novelId) &&
            !adoptedIds.contains(a.id) &&
            productionMediaFormat(a.path!)?.$1 == type)
          EditingMedia(assetId: a.id, path: a.path!, type: type, name: a.name),
    ];
    final others = of('video');
    final replacing = replaceFor == null
        ? null
        : doc.clips.where((c) => c.id == replaceFor).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (replacing != null)
          Container(
            margin: const EdgeInsets.fromLTRB(
              RevericSpacing.lg,
              0,
              RevericSpacing.lg,
              RevericSpacing.sm,
            ),
            padding: const EdgeInsets.fromLTRB(RevericSpacing.md, 2, 2, 2),
            decoration: BoxDecoration(
              color: colors.selected,
              border: Border.all(color: colors.accent),
              borderRadius: BorderRadius.circular(RevericRadius.large),
            ),
            child: Row(
              children: [
                RevericIcon(
                  RevericIcons.arrows_clockwise,
                  size: 13,
                  color: colors.textPrimary,
                ),
                const SizedBox(width: RevericSpacing.xs),
                Expanded(
                  child: Text(
                    context.t(
                      LocaleKeys.editingReplacing,
                      namedArgs: {
                        'name': editingClipLabel(controller, replacing),
                      },
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiSmall.copyWith(color: colors.textPrimary),
                  ),
                ),
                RevericIconButton(
                  icon: RevericIcons.close,
                  tooltip: context.t(LocaleKeys.commonCancel),
                  onPressed: () => controller.showAssets(false),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.lg,
            0,
            RevericSpacing.lg,
            RevericSpacing.xs,
          ),
          child: RevericSegmentedControl<String>(
            selected: filter.value,
            segments: [
              RevericSegment(
                value: 'video',
                label: context.t(LocaleKeys.editingFilterVideo),
              ),
              RevericSegment(
                value: 'image',
                label: context.t(LocaleKeys.editingFilterImage),
              ),
              RevericSegment(
                value: 'audio',
                label: context.t(LocaleKeys.editingFilterAudio),
              ),
            ],
            onChanged: (v) => filter.value = v,
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.sm,
              0,
              RevericSpacing.sm,
              RevericSpacing.lg,
            ),
            children: [
              if (filter.value == 'video') ...[
                section(context.t(LocaleKeys.editingAdoptedSegments)),
                if (canvasClips.hasError)
                  Text(context.t(LocaleKeys.commonLoadFailed)),
                for (final s in segments)
                  if (adoptedById[s.assetId]?.path == null)
                    _PendingItem(
                      title: s.number == null
                          ? s.title
                          : '${context.t(LocaleKeys.productionExportSegment, namedArgs: {'number': s.number!})} · ${s.title}',
                    )
                  else
                    item(
                      EditingMedia(
                        assetId: s.assetId!,
                        path: adoptedById[s.assetId]!.path!,
                        type: 'video',
                        name: s.title,
                        productionClipId: s.clipId,
                      ),
                      subtitle: s.number == null
                          ? null
                          : context.t(
                              LocaleKeys.productionExportSegment,
                              namedArgs: {'number': s.number!},
                            ),
                    ),
                if (others.isNotEmpty) ...[
                  section(context.t(LocaleKeys.editingOtherVideos)),
                  for (final m in others) item(m),
                ],
              ] else if (filter.value == 'image')
                LayoutBuilder(
                  builder: (context, constraints) {
                    const gap = RevericSpacing.sm;
                    final width = (constraints.maxWidth - gap) / 2;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final m in of('image'))
                          SizedBox(width: width, child: item(m, tile: true)),
                      ],
                    );
                  },
                )
              else
                for (final m in of(filter.value)) item(m),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(RevericSpacing.md),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.border)),
          ),
          child: RevericButton.secondary(
            label: context.t(LocaleKeys.commonImport),
            icon: RevericIcons.upload,
            onPressed: busy.value ? null : () => act(import),
          ),
        ),
      ],
    );
  }
}

/// 素材一项：可拖到时间线；悬停时露出「＋」或「替换」。
class _BinItem extends HookWidget {
  const _BinItem({
    required this.media,
    required this.thumbPath,
    this.subtitle = '',
    this.action,
    this.tile = false,
  });
  final EditingMedia media;

  /// 网格格子：上方 16:9 缩略图、下方名称，操作浮在缩略图右上角。
  final bool tile;
  final String? thumbPath;
  final String subtitle;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final hover = useState(false);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final m = media;
    Widget cell() => Container(
      padding: const EdgeInsets.all(RevericSpacing.xs),
      decoration: BoxDecoration(
        color: hover.value ? colors.hover : null,
        borderRadius: BorderRadius.circular(RevericRadius.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                children: [
                  EditingMediaThumb(
                    path: thumbPath,
                    type: m.type,
                    size: constraints.biggest,
                  ),
                  if (action != null)
                    Positioned(
                      top: RevericSpacing.xs,
                      right: RevericSpacing.xs,
                      child: Opacity(
                        opacity: hover.value ? 1 : 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surface,
                            borderRadius: BorderRadius.circular(
                              RevericRadius.medium,
                            ),
                          ),
                          child: action,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (m.name.isNotEmpty || subtitle.isNotEmpty) ...[
            const SizedBox(height: RevericSpacing.xs),
            Text(
              [
                if (m.name.isNotEmpty) m.name,
                if (subtitle.isNotEmpty) subtitle,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiTiny.copyWith(color: colors.textMuted),
            ),
          ],
        ],
      ),
    );
    Widget row({bool feedback = false}) => Container(
      width: feedback ? 240 : null,
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.xs,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: feedback || hover.value ? colors.hover : null,
        borderRadius: BorderRadius.circular(RevericRadius.large),
      ),
      child: Row(
        children: [
          EditingMediaThumb(
            path: thumbPath,
            type: m.type,
            size: const Size(48, 27),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
              ],
            ),
          ),
          if (!feedback && action != null)
            Opacity(opacity: hover.value ? 1 : 0, child: action),
        ],
      ),
    );
    return MouseRegion(
      onEnter: (_) => hover.value = true,
      onExit: (_) => hover.value = false,
      cursor: SystemMouseCursors.grab,
      child: Tooltip(
        message: context.t(LocaleKeys.editingDragHint),
        waitDuration: const Duration(milliseconds: 800),
        child: Draggable<EditingMedia>(
          data: m,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Material(
            color: colors.surface,
            elevation: 4,
            borderRadius: BorderRadius.circular(RevericRadius.large),
            child: row(feedback: true),
          ),
          child: tile ? cell() : row(),
        ),
      ),
    );
  }
}

/// 还没有采用结果的片段：只占一行灰字，不可拖拽。
class _PendingItem extends StatelessWidget {
  const _PendingItem({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.xs,
        vertical: RevericSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiSmall.copyWith(color: colors.textSubtle),
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.editingNotAdopted),
            style: typo.uiTiny.copyWith(color: colors.textSubtle),
          ),
        ],
      ),
    );
  }
}
