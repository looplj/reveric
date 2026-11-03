// 职责: 桌面端小说概览页 — 标题/标签、继续写作 hero、项目简介与灵感片段、写作入口卡片
// 关联文件:
//   lib/desktop/widgets/workspace/novel_workspace_panel.dart
//   lib/shared/models/novel_workspace.dart
//   lib/shared/database/app_database.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_surfaces.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/database/app_database.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/content_kind.dart';
import '../../../shared/models/content_status.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/theme/theme.dart';
import '../agent_management/agent_model_settings_page.dart';
import '../novel_create_submitter.dart';
import 'hero.dart';
import '../../../shared/widgets/media_asset_image.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const int _coverThumbnailCacheWidth = 240;

class NovelOverview extends StatelessWidget {
  const NovelOverview({
    super.key,
    required this.novel,
    required this.chapters,
    this.lastWrittenChapter,
    required this.characterProfiles,
    required this.worldbuildingEntries,
    required this.foreshadowings,
    required this.canOpenCoverStudio,
    required this.onOpenCoverStudio,
    required this.onUploadCover,
    required this.onSelectionChanged,
    required this.onContinueWriting,
    this.onEditNovel,
    required this.coverThumbnailKey,
    required this.coverMenuTrigger,
  });

  final Novel novel;
  final List<Chapter> chapters;
  final Chapter? lastWrittenChapter;
  final List<CharacterProfile> characterProfiles;
  final List<Document> worldbuildingEntries;
  final List<Foreshadowing> foreshadowings;
  final bool canOpenCoverStudio;
  final VoidCallback onOpenCoverStudio;
  final VoidCallback onUploadCover;
  final ValueSetter<WorkspaceSelection> onSelectionChanged;
  final ValueChanged<String> onContinueWriting;
  final VoidCallback? onEditNovel;
  final GlobalKey coverThumbnailKey;
  final ValueNotifier<int> coverMenuTrigger;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.x6l,
        vertical: RevericSpacing.x5l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TitleSection(novel: novel, onEditNovel: onEditNovel),
          const SizedBox(height: RevericSpacing.x4l),
          ContinueWritingHero(
            onContinueWriting: onContinueWriting,
            chapters: chapters,
            lastWrittenChapter: lastWrittenChapter,
            onSelectionChanged: onSelectionChanged,
          ),
          const SizedBox(height: RevericSpacing.x4l),
          _SecondRow(
            novel: novel,
            chapters: chapters,
            characterProfiles: characterProfiles,
            worldbuildingEntries: worldbuildingEntries,
            foreshadowings: foreshadowings,
            canOpenCoverStudio: canOpenCoverStudio,
            onOpenCoverStudio: onOpenCoverStudio,
            onUploadCover: onUploadCover,
            onSelectionChanged: onSelectionChanged,
            coverThumbnailKey: coverThumbnailKey,
            coverMenuTrigger: coverMenuTrigger,
          ),
          const SizedBox(height: RevericSpacing.x4l),
          _WritingEntries(onSelectionChanged: onSelectionChanged),
        ],
      ),
    );
  }
}

// =============================================================================
// Title section: 大标题 + 编辑按钮 + 标签 + 状态徽章
// =============================================================================
class _TitleSection extends ConsumerWidget {
  const _TitleSection({required this.novel, this.onEditNovel});

  final Novel novel;
  final VoidCallback? onEditNovel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final tags = novel.tags;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                novel.title,
                style: typo.display.copyWith(color: colors.textPrimary),
              ),
            ),
            const SizedBox(width: RevericSpacing.md),
            IconButton(
              tooltip: context.t(LocaleKeys.editorEditNovelInfo),
              onPressed: onEditNovel,
              splashRadius: 18,
              icon: RevericIcon(
                RevericIcons.edit_outlined,
                size: 18,
                color: colors.textMuted,
              ),
            ),
            // 草稿不在改编的原著候选里，选不回来，所以只给书架上的小说。
            if (novel.contentKind == contentKindNovel && !novel.draft) ...[
              const SizedBox(width: RevericSpacing.sm),
              RevericButton.secondary(
                onPressed: () => showNovelAdaptationDialog(context, ref, novel),
                icon: RevericIcons.movie_outlined,
                label: context.t(LocaleKeys.libraryActionAdapt),
                size: RevericButtonSize.compact,
              ),
            ],
          ],
        ),
        const SizedBox(height: RevericSpacing.md),
        _StatusBadge(status: novel.status),
        if (tags.isNotEmpty) ...[
          const SizedBox(height: RevericSpacing.sm),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: RevericSpacing.sm,
            runSpacing: RevericSpacing.sm,
            children: [
              for (final tag in tags)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.md,
                    vertical: RevericSpacing.xxs,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainer,
                    borderRadius: BorderRadius.circular(RevericRadius.full),
                    border: Border.all(color: colors.borderSubtle),
                  ),
                  child: Text(
                    tag,
                    style: typo.uiTiny.copyWith(color: colors.textSecondary),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final color = _statusColor(colors, status);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.md,
        vertical: RevericSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(RevericRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: RevericSpacing.xs),
          Text(
            _statusLabel(context, status),
            style: typo.uiTinySemibold.copyWith(color: color),
          ),
        ],
      ),
    );
  }

  Color _statusColor(RevericColors colors, String status) {
    switch (status) {
      case contentStatusFinished:
        return colors.success;
      case contentStatusAbandoned:
        return colors.error;
      case contentStatusArchived:
        return colors.textMuted;
      case contentStatusInProgress:
      default:
        return colors.accentWarm;
    }
  }

  String _statusLabel(BuildContext context, String status) {
    switch (status) {
      case contentStatusFinished:
        return context.t(LocaleKeys.libraryStatusFinished);
      case contentStatusAbandoned:
        return context.t(LocaleKeys.libraryStatusAbandoned);
      case contentStatusArchived:
        return context.t(LocaleKeys.libraryStatusArchived);
      case contentStatusInProgress:
      default:
        return context.t(LocaleKeys.libraryStatusInProgress);
    }
  }
}

// =============================================================================
// Second row: 项目简介 + 创作片段
// =============================================================================
class _SecondRow extends StatelessWidget {
  const _SecondRow({
    required this.novel,
    required this.chapters,
    required this.characterProfiles,
    required this.worldbuildingEntries,
    required this.foreshadowings,
    required this.canOpenCoverStudio,
    required this.onOpenCoverStudio,
    required this.onUploadCover,
    required this.onSelectionChanged,
    required this.coverThumbnailKey,
    required this.coverMenuTrigger,
  });

  final Novel novel;
  final List<Chapter> chapters;
  final List<CharacterProfile> characterProfiles;
  final List<Document> worldbuildingEntries;
  final List<Foreshadowing> foreshadowings;
  final bool canOpenCoverStudio;
  final VoidCallback onOpenCoverStudio;
  final VoidCallback onUploadCover;
  final ValueSetter<WorkspaceSelection> onSelectionChanged;
  final GlobalKey coverThumbnailKey;
  final ValueNotifier<int> coverMenuTrigger;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProjectIntroCard(
          novel: novel,
          chapters: chapters,
          characterProfiles: characterProfiles,
          worldbuildingEntries: worldbuildingEntries,
          foreshadowings: foreshadowings,
          canOpenCoverStudio: canOpenCoverStudio,
          onOpenCoverStudio: onOpenCoverStudio,
          onUploadCover: onUploadCover,
          coverThumbnailKey: coverThumbnailKey,
          coverMenuTrigger: coverMenuTrigger,
        ),
        const SizedBox(height: RevericSpacing.x2l),
        _SnippetsCard(
          foreshadowings: foreshadowings,
          worldbuildingEntries: worldbuildingEntries,
          onSelectionChanged: onSelectionChanged,
        ),
      ],
    );
  }
}

class _ProjectIntroCard extends ConsumerWidget {
  const _ProjectIntroCard({
    required this.novel,
    required this.chapters,
    required this.characterProfiles,
    required this.worldbuildingEntries,
    required this.foreshadowings,
    required this.canOpenCoverStudio,
    required this.onOpenCoverStudio,
    required this.onUploadCover,
    required this.coverThumbnailKey,
    required this.coverMenuTrigger,
  });

  final Novel novel;
  final List<Chapter> chapters;
  final List<CharacterProfile> characterProfiles;
  final List<Document> worldbuildingEntries;
  final List<Foreshadowing> foreshadowings;
  final bool canOpenCoverStudio;
  final VoidCallback onOpenCoverStudio;
  final VoidCallback onUploadCover;
  final GlobalKey coverThumbnailKey;
  final ValueNotifier<int> coverMenuTrigger;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final resolvedCoverPath = watchMediaAssetFile(ref, novel.coverAssetId);
    final coverFile = resolvedCoverPath == null
        ? null
        : File(resolvedCoverPath);
    final hasCover = coverFile != null;

    return RevericElevatedCard(
      fallback: colors.surfaceContainerHigh,
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RevericIcon(
                RevericIcons.menu_book_outlined,
                size: 16,
                color: colors.accentWarm,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.workspaceProjectIntro),
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
              const Spacer(),
              if (novel.description.isNotEmpty)
                _CopyButton(text: novel.description),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CoverThumbnail(
                hasCover: hasCover,
                coverFile: coverFile,
                canOpenCoverStudio: canOpenCoverStudio,
                onOpenCoverStudio: onOpenCoverStudio,
                onUploadCover: onUploadCover,
                coverThumbnailKey: coverThumbnailKey,
                coverMenuTrigger: coverMenuTrigger,
              ),
              const SizedBox(width: RevericSpacing.lg),
              Expanded(
                child: SizedBox(
                  height: 120,
                  child: SingleChildScrollView(
                    child: SelectableText(
                      novel.description.isEmpty
                          ? context.t(LocaleKeys.commonNoDescription)
                          : novel.description,
                      style: typo.bodySmall.copyWith(
                        color: colors.textSecondary,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          RevericElevatedCard(
            fallback: colors.surface,
            borderRadius: BorderRadius.circular(RevericRadius.large),
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.lg,
              vertical: RevericSpacing.sm,
            ),
            child: Wrap(
              spacing: RevericSpacing.lg,
              runSpacing: RevericSpacing.xs,
              children: [
                _statText(
                  context,
                  context.t(LocaleKeys.workspaceStatChapters),
                  '${chapters.length}',
                ),
                _statText(
                  context,
                  context.t(LocaleKeys.workspaceStatSettings),
                  '${worldbuildingEntries.length}',
                ),
                _statText(
                  context,
                  context.t(LocaleKeys.workspaceStatCharacters),
                  '${characterProfiles.length}',
                ),
                _statText(
                  context,
                  context.t(LocaleKeys.workspaceStatNotes),
                  '${foreshadowings.length}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statText(BuildContext context, String label, String value) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: typo.uiSmall.copyWith(color: colors.textMuted)),
        const SizedBox(width: RevericSpacing.xs),
        Text(
          value,
          style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
        ),
      ],
    );
  }
}

class _CoverThumbnail extends HookWidget {
  const _CoverThumbnail({
    required this.hasCover,
    required this.coverFile,
    required this.canOpenCoverStudio,
    required this.onOpenCoverStudio,
    required this.onUploadCover,
    required this.coverThumbnailKey,
    required this.coverMenuTrigger,
  });

  final bool hasCover;
  final File? coverFile;
  final bool canOpenCoverStudio;
  final VoidCallback onOpenCoverStudio;
  final VoidCallback onUploadCover;
  final GlobalKey coverThumbnailKey;
  final ValueNotifier<int> coverMenuTrigger;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final coverImageProvider = hasCover && coverFile != null
        ? ResizeImage(FileImage(coverFile!), width: _coverThumbnailCacheWidth)
        : null;
    final menuOpen = useRef(false);

    Future<void> openMenu() async {
      if (!context.mounted || menuOpen.value) {
        return;
      }
      final box =
          coverThumbnailKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) {
        return;
      }
      menuOpen.value = true;
      try {
        await showRevericContextMenu(
          context: context,
          position: box.localToGlobal(Offset(0, box.size.height)),
          entries: [
            if (hasCover) ...[
              RevericMenuItem(
                label: context.t(LocaleKeys.workspaceCoverPreview),
                icon: RevericIcons.open_in_full_rounded,
                onTap: () {
                  if (coverFile != null) {
                    _showCoverPreview(context, coverFile!);
                  }
                },
              ),
              RevericMenuItem(
                label: context.t(LocaleKeys.workspaceCoverSaveLocal),
                icon: RevericIcons.download,
                onTap: () {
                  if (coverFile != null) {
                    _saveCoverLocally(context, coverFile!);
                  }
                },
              ),
              const RevericMenuDivider(),
            ],
            RevericMenuItem(
              label: context.t(LocaleKeys.editorOpenCoverStudio),
              icon: RevericIcons.auto_awesome,
              onTap: () {
                if (canOpenCoverStudio) {
                  onOpenCoverStudio();
                } else {
                  showAgentModelSettingsDialog(context);
                }
              },
            ),
            RevericMenuItem(
              label: context.t(LocaleKeys.editorUploadCover),
              icon: RevericIcons.upload_outlined,
              onTap: onUploadCover,
            ),
          ],
        );
      } finally {
        menuOpen.value = false;
      }
    }

    useOnListenableChange(coverMenuTrigger, () {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          openMenu();
        }
      });
    });

    return InkWell(
      onTap: openMenu,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: RevericElevatedCard(
        key: coverThumbnailKey,
        fallback: colors.surface,
        width: 80,
        height: 112,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        clipBehavior: Clip.antiAlias,
        child: coverImageProvider == null
            ? _CoverThumbnailPlaceholder(colors: colors)
            : SizedBox.expand(
                child: Image(
                  image: coverImageProvider,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      _CoverThumbnailPlaceholder(colors: colors),
                ),
              ),
      ),
    );
  }
}

void _showCoverPreview(BuildContext context, File coverFile) {
  final colors = RevericTheme.colorsOf(context);
  final screenSize = MediaQuery.sizeOf(context);

  showDialog<void>(
    context: context,
    barrierColor: colors.textPrimary.withValues(alpha: 0.72),
    builder: (context) {
      return Dialog(
        backgroundColor: colors.surface,
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(RevericSpacing.x4l),
        child: SizedBox(
          width: screenSize.width * 0.72,
          height: screenSize.height * 0.78,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Center(
                    child: Image.file(
                      coverFile,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          _CoverThumbnailPlaceholder(colors: colors),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: RevericSpacing.sm,
                right: RevericSpacing.sm,
                child: IconButton(
                  tooltip: context.t(LocaleKeys.commonClose),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: RevericIcon(
                    RevericIcons.close_rounded,
                    size: 18,
                    color: colors.textPrimary,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: colors.surface.withValues(alpha: 0.9),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> _saveCoverLocally(BuildContext context, File coverFile) async {
  final location = await getSaveLocation(
    suggestedName: coverFile.uri.pathSegments.last,
  );
  if (!context.mounted || location == null) {
    return;
  }

  try {
    final savedFile = await coverFile.copy(location.path);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.t(
            LocaleKeys.workspaceCoverSaveSuccess,
            namedArgs: {'file': savedFile.path},
          ),
        ),
      ),
    );
  } catch (error, stackTrace) {
    debugPrintStack(
      label: 'Failed to save novel cover',
      stackTrace: stackTrace,
    );
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t(LocaleKeys.workspaceCoverSaveFailed))),
    );
  }
}

class _CoverThumbnailPlaceholder extends StatelessWidget {
  const _CoverThumbnailPlaceholder({required this.colors});

  final RevericColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: RevericIcon(
        RevericIcons.image_outlined,
        size: 32,
        color: colors.textMuted,
      ),
    );
  }
}

class _SnippetsCard extends StatelessWidget {
  const _SnippetsCard({
    required this.foreshadowings,
    required this.worldbuildingEntries,
    required this.onSelectionChanged,
  });

  final List<Foreshadowing> foreshadowings;
  final List<Document> worldbuildingEntries;
  final ValueSetter<WorkspaceSelection> onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final notes = _buildNotes(context);

    return RevericElevatedCard(
      fallback: colors.surfaceContainerHigh,
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RevericIcon(
                RevericIcons.auto_awesome,
                size: 16,
                color: colors.accentWarm,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.workspaceCreativeSnippets),
                style: typo.uiSemibold.copyWith(color: colors.textPrimary),
              ),
              const Spacer(),
              InkWell(
                onTap: () => onSelectionChanged(
                  const WorkspaceSelection(
                    section: NovelWorkspaceSection.foreshadowings,
                  ),
                ),
                borderRadius: BorderRadius.circular(RevericRadius.medium),
                child: Padding(
                  padding: const EdgeInsets.all(RevericSpacing.xs),
                  child: Row(
                    children: [
                      Text(
                        context.t(LocaleKeys.workspaceCreativeSnippetsViewMore),
                        style: typo.uiSmall.copyWith(color: colors.accentWarm),
                      ),
                      RevericIcon(
                        RevericIcons.chevron_right,
                        size: 14,
                        color: colors.accentWarm,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          if (notes.isEmpty)
            _SnippetEmptyState(
              onTap: () => onSelectionChanged(
                const WorkspaceSelection(
                  section: NovelWorkspaceSection.foreshadowings,
                ),
              ),
            )
          else
            _StickyNotesRow(notes: notes),
        ],
      ),
    );
  }

  List<_SnippetNote> _buildNotes(BuildContext context) {
    final result = <_SnippetNote>[];
    final inspirationLabel = context.t(
      LocaleKeys.workspaceSnippetTagInspiration,
    );
    final settingLabel = context.t(LocaleKeys.workspaceSnippetTagSetting);
    final relationLabel = context.t(LocaleKeys.workspaceSnippetTagRelation);

    for (final foreshadow in foreshadowings) {
      if (result.length >= 3) break;
      final body = foreshadow.setup.isNotEmpty
          ? foreshadow.setup
          : foreshadow.payoff;
      if (body.isEmpty) continue;
      result.add(
        _SnippetNote(
          body: body,
          title: foreshadow.title,
          tag: inspirationLabel,
        ),
      );
    }

    if (result.length < 3) {
      for (final entry in worldbuildingEntries) {
        if (result.length >= 3) break;
        if (entry.content.isEmpty) continue;
        result.add(
          _SnippetNote(
            body: entry.content,
            title: entry.title,
            tag: result.length == 2 ? relationLabel : settingLabel,
          ),
        );
      }
    }

    return result;
  }
}

class _SnippetNote {
  const _SnippetNote({
    required this.body,
    required this.title,
    required this.tag,
  });

  final String body;
  final String title;
  final String tag;
}

class _StickyNotesRow extends StatelessWidget {
  const _StickyNotesRow({required this.notes});

  final List<_SnippetNote> notes;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final palette = <Color>[
      colors.accentAmber.withValues(alpha: 0.18),
      colors.accent.withValues(alpha: 0.12),
      colors.accentWarm.withValues(alpha: 0.16),
    ];
    final tints = <Color>[colors.accentAmber, colors.accent, colors.accentWarm];

    return SizedBox(
      height: 168,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final count = notes.length.clamp(1, 3);
          final spacing = RevericSpacing.lg;
          final available = constraints.maxWidth;
          final itemWidth = ((available - spacing * (count - 1)) / count).clamp(
            160.0,
            220.0,
          );
          final angles = const [-0.04, 0.02, -0.015];
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < count; i++) ...[
                if (i > 0) SizedBox(width: spacing),
                Transform.rotate(
                  angle: angles[i % angles.length],
                  child: SizedBox(
                    width: itemWidth,
                    child: _StickyNoteCard(
                      note: notes[i],
                      background: palette[i % palette.length],
                      accent: tints[i % tints.length],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _StickyNoteCard extends StatelessWidget {
  const _StickyNoteCard({
    required this.note,
    required this.background,
    required this.accent,
  });

  final _SnippetNote note;
  final Color background;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        boxShadow: [
          BoxShadow(
            color: colors.textPrimary.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Text(
              note.body,
              style: typo.bodySmall.copyWith(
                color: colors.textPrimary,
                height: 1.5,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '— ${note.tag}',
              style: typo.uiTiny.copyWith(
                color: accent,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SnippetEmptyState extends StatelessWidget {
  const _SnippetEmptyState({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return RevericElevatedInkWell(
      fallback: colors.surface,
      onTap: onTap,
      height: 140,
      padding: const EdgeInsets.all(RevericSpacing.lg),
      borderRadius: BorderRadius.circular(RevericRadius.large),
      alignment: Alignment.center,
      child: Text(
        context.t(LocaleKeys.workspaceCreativeSnippetsEmpty),
        textAlign: TextAlign.center,
        style: typo.uiSmall.copyWith(color: colors.textMuted),
      ),
    );
  }
}

// =============================================================================
// Writing entries: 4 large cards
// =============================================================================
class _WritingEntries extends StatelessWidget {
  const _WritingEntries({required this.onSelectionChanged});

  final ValueSetter<WorkspaceSelection> onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final entries = <_EntrySpec>[
      _EntrySpec(
        icon: RevericIcons.edit_note_outlined,
        title: context.t(LocaleKeys.workspaceWritingMain),
        hint: context.t(LocaleKeys.workspaceWritingMainHint),
        tint: colors.accentAmber,
        section: NovelWorkspaceSection.chapters,
      ),
      _EntrySpec(
        icon: RevericIcons.public_outlined,
        title: context.t(LocaleKeys.workspaceLore),
        hint: context.t(LocaleKeys.workspaceLoreHint),
        tint: colors.accent,
        section: NovelWorkspaceSection.lore,
      ),
      _EntrySpec(
        icon: RevericIcons.auto_stories_outlined,
        title: context.t(LocaleKeys.workspaceWritingOutlinePlot),
        hint: context.t(LocaleKeys.workspaceWritingOutlinePlotHint),
        tint: colors.accentWarm,
        section: NovelWorkspaceSection.outlines,
      ),
      _EntrySpec(
        icon: RevericIcons.people_alt_outlined,
        title: context.t(LocaleKeys.workspaceWritingCharacters),
        hint: context.t(LocaleKeys.workspaceWritingCharactersHint),
        tint: colors.accent,
        section: NovelWorkspaceSection.characters,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.workspaceWritingEntrances),
          style: typo.heading2.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: RevericSpacing.lg),
        LayoutBuilder(
          builder: (context, constraints) {
            const minCardWidth = 200.0;
            const spacing = RevericSpacing.lg;
            final totalSpacing = spacing * 3;
            final canFitFourInOneRow =
                constraints.maxWidth >= minCardWidth * 4 + totalSpacing;

            if (canFitFourInOneRow) {
              return Row(
                spacing: spacing,
                children: [
                  for (final entry in entries)
                    Expanded(
                      child: _EntryCard(
                        spec: entry,
                        onTap: () => onSelectionChanged(
                          WorkspaceSelection(section: entry.section),
                        ),
                      ),
                    ),
                ],
              );
            } else {
              final rowSpacing = spacing;
              final colSpacing = spacing;
              final cardWidth = (constraints.maxWidth - rowSpacing) / 2;
              return Column(
                spacing: colSpacing,
                children: [
                  Row(
                    spacing: rowSpacing,
                    children: [
                      for (final entry in entries.take(2))
                        SizedBox(
                          width: cardWidth,
                          child: _EntryCard(
                            spec: entry,
                            onTap: () => onSelectionChanged(
                              WorkspaceSelection(section: entry.section),
                            ),
                          ),
                        ),
                    ],
                  ),
                  Row(
                    spacing: rowSpacing,
                    children: [
                      for (final entry in entries.skip(2))
                        SizedBox(
                          width: cardWidth,
                          child: _EntryCard(
                            spec: entry,
                            onTap: () => onSelectionChanged(
                              WorkspaceSelection(section: entry.section),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            }
          },
        ),
      ],
    );
  }
}

class _EntrySpec {
  const _EntrySpec({
    required this.icon,
    required this.title,
    required this.hint,
    required this.tint,
    required this.section,
  });

  final String icon;
  final String title;
  final String hint;
  final Color tint;
  final NovelWorkspaceSection section;
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.spec, required this.onTap});

  final _EntrySpec spec;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.pill),
      child: Container(
        padding: const EdgeInsets.all(RevericSpacing.x2l),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              spec.tint.withValues(alpha: 0.14),
              spec.tint.withValues(alpha: 0.04),
            ],
          ),
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          border: Border.all(color: colors.borderSubtle),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(RevericRadius.large),
              ),
              alignment: Alignment.center,
              child: RevericIcon(spec.icon, size: 20, color: spec.tint),
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              spec.title,
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.xs),
            Text(
              spec.hint,
              style: typo.uiSmall.copyWith(
                color: colors.textMuted,
                height: 1.5,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: RevericSpacing.lg),
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: colors.surface.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: RevericIcon(
                  RevericIcons.arrow_forward,
                  size: 14,
                  color: spec.tint,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Helpers
// =============================================================================
class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);

    return SizedBox(
      width: 24,
      height: 24,
      child: IconButton(
        onPressed: () {
          Clipboard.setData(ClipboardData(text: text));
        },
        icon: RevericIcon(
          RevericIcons.copy_rounded,
          size: 14,
          color: colors.textMuted,
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        tooltip: context.t(LocaleKeys.commonCopy),
      ),
    );
  }
}
