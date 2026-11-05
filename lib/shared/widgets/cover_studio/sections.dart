// 职责: 设计师面板的参数小节 — 作品卡片、可编辑提示词、点选追加的风格/色调/构图。
// 关联文件:
//   lib/shared/providers/cover_studio_providers.dart
//   lib/shared/providers/cover_providers.dart
//   lib/shared/services/cover_prompt_builder.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/form.md
//   .agents/rules/i18n.md
//   .agents/rules/text-input-ime.md

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../third/form/flutter_hook_form.dart';
import '../../database/app_database.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/image/channels.dart';
import '../../providers/ai_providers.dart';
import '../../providers/cover_providers.dart';
import '../../providers/cover_studio_providers.dart';
import '../../services/cover_prompt_builder.dart';
import '../../theme/theme.dart';
import 'chips.dart';
import '../media_asset_image.dart';

/// 设计师表单只有提示词一个字段：书名与署名不再单列输入框，避免与提示词正文
/// 各说各话。两端共用同一个 schema。
enum CoverStudioField<T> implements FieldSchema {
  prompt<String>();

  const CoverStudioField({this.validators});

  @override
  final List<Validator<dynamic>>? validators;
}

/// 作品卡片：封面缩略图 + 书名、署名 / 品类、标签与体量。
class CoverWorkSection extends ConsumerWidget {
  const CoverWorkSection({
    super.key,
    required this.novel,
    required this.databasePath,
  });

  final Novel novel;

  /// per-novel 内容库路径。为 null（内容库未打开）时只报应用库里的字数，
  /// 不编造章节数。
  final String? databasePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final path = databasePath;
    final stats = path == null
        ? null
        : ref.watch(coverWorkStatsProvider(path)).asData?.value;
    final subtitle = [
      novel.authorName.trim(),
      novel.category.trim(),
    ].where((text) => text.isNotEmpty).join(' · ');
    final words = stats?.totalWordCount ?? novel.wordCount;
    final measures = [
      if (words > 0) formatHomeWordCountLabel(context, words),
      if (stats != null)
        context.t(
          LocaleKeys.editorCoverWorkChapters,
          namedArgs: {'count': '${stats.chapterCount}'},
        ),
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CoverSectionHead(
          icon: RevericIcons.book,
          label: context.t(LocaleKeys.editorCoverWork),
        ),
        Container(
          padding: const EdgeInsets.all(RevericSpacing.lg),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            border: Border.all(color: colors.borderSubtle),
            borderRadius: BorderRadius.circular(RevericRadius.large),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _WorkThumb(coverAssetId: novel.coverAssetId),
              const SizedBox(width: RevericSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      novel.title,
                      style: typo.uiSemibold,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: RevericSpacing.xxs),
                      Text(
                        subtitle,
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (novel.tags.isNotEmpty) ...[
                      const SizedBox(height: RevericSpacing.xs),
                      Wrap(
                        spacing: RevericSpacing.xxs,
                        runSpacing: RevericSpacing.xxs,
                        children: [for (final tag in novel.tags) _WorkTag(tag)],
                      ),
                    ],
                    if (measures.isNotEmpty) ...[
                      const SizedBox(height: RevericSpacing.xs),
                      Text(
                        measures,
                        style: typo.uiTiny.copyWith(color: colors.textSubtle),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 卡片左侧的封面缩略图。没有封面时直说「未设置」，不画假书脊。
class _WorkThumb extends ConsumerWidget {
  const _WorkThumb({required this.coverAssetId});

  final String? coverAssetId;

  /// 缩略图宽度与它的缓存像素宽（2 倍图）。
  static const double _width = 58;
  static const int _cacheWidth = 116;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final resolved = watchMediaAssetFile(ref, coverAssetId);
    final radius = BorderRadius.circular(RevericRadius.small);

    return SizedBox(
      width: _width,
      child: AspectRatio(
        // 封面按竖版比例裁切展示，与画布默认出图比例一致。
        aspectRatio: 2 / 3,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            border: Border.all(color: colors.borderSubtle),
            borderRadius: radius,
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: resolved == null
                ? _blank(context)
                : Image.file(
                    File(resolved),
                    fit: BoxFit.cover,
                    cacheWidth: _cacheWidth,
                    errorBuilder: (_, _, _) => _blank(context),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _blank(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: Text(
        context.t(LocaleKeys.editorCoverWorkNoCover),
        textAlign: TextAlign.center,
        style: typo.uiTiny.copyWith(color: colors.textSubtle),
      ),
    );
  }
}

/// 作品标签。卡片本身已是 surfaceContainerHigh，标签退一档底色才看得出来。
class _WorkTag extends StatelessWidget {
  const _WorkTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border.all(color: colors.borderSubtle),
        borderRadius: BorderRadius.circular(RevericRadius.small),
      ),
      child: Text(label, style: typo.uiTiny.copyWith(color: colors.textMuted)),
    );
  }
}

/// 风格芯片：点一下把对应句子追加进提示词，不再作为选中态驱动自动拼装。
class CoverStyleSection extends StatelessWidget {
  const CoverStyleSection({super.key, required this.onAppend});

  final ValueChanged<String> onAppend;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CoverSectionHead(
          icon: RevericIcons.auto_awesome,
          label: context.t(LocaleKeys.editorCoverStyle),
        ),
        Text(
          context.t(LocaleKeys.editorCoverAppendHint),
          style: RevericTheme.typographyOf(
            context,
          ).uiTiny.copyWith(color: RevericTheme.colorsOf(context).textMuted),
        ),
        const SizedBox(height: RevericSpacing.sm),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final style in coverStyles)
              CoverChip(
                label: context.t(coverStyleLabelKey(style.id)),
                selected: false,
                onTap: () => onAppend(coverStyleSnippet(style.id)),
              ),
          ],
        ),
      ],
    );
  }
}

class CoverPaletteSection extends StatelessWidget {
  const CoverPaletteSection({super.key, required this.onAppend});

  final ValueChanged<String> onAppend;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CoverSectionHead(
          icon: RevericIcons.water_drop_outlined,
          label: context.t(LocaleKeys.editorCoverPalette),
        ),
        Wrap(
          spacing: RevericSpacing.sm,
          runSpacing: RevericSpacing.sm,
          children: [
            for (final palette in coverPalettes)
              CoverSwatch(
                label: context.t(coverPaletteLabelKey(palette.id)),
                startColor: Color(palette.startArgb),
                endColor: Color(palette.endArgb),
                selected: false,
                onTap: () => onAppend(coverPaletteSnippet(palette.id)),
              ),
          ],
        ),
      ],
    );
  }
}

class CoverCompositionSection extends StatelessWidget {
  const CoverCompositionSection({super.key, required this.onAppend});

  final ValueChanged<String> onAppend;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CoverSectionHead(
          icon: RevericIcons.space_dashboard_outlined,
          label: context.t(LocaleKeys.editorCoverComposition),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final composition in coverCompositions)
              CoverChip(
                label: context.t(coverCompositionLabelKey(composition.id)),
                selected: false,
                onTap: () => onAppend(coverCompositionSnippet(composition.id)),
              ),
          ],
        ),
      ],
    );
  }
}

class CoverQualitySection extends ConsumerWidget {
  const CoverQualitySection({super.key, required this.novelId});

  final String novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CoverSectionHead(
          icon: RevericIcons.auto_awesome,
          label: context.t(LocaleKeys.editorCoverQuality),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final quality in coverQualities)
              CoverChip(
                label: context.t(coverQualityLabelKey(quality.id)),
                selected: state.qualityId == quality.id,
                onTap: () => controller.setQuality(quality.id),
              ),
          ],
        ),
      ],
    );
  }
}

class CoverComplexitySection extends ConsumerWidget {
  const CoverComplexitySection({super.key, required this.novelId});

  final String novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(coverStudioImageModelSelectionProvider);
    if (selection == null) {
      return const SizedBox.shrink();
    }
    final levels = imageComplexityLevels(
      selection.config.type,
      selection.model,
    );
    if (levels.isEmpty) {
      return const SizedBox.shrink();
    }
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );
    final selected = imageComplexityFor(
      selection.config.type,
      selection.model,
      state.complexityId,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.x3l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverSectionHead(
            icon: RevericIcons.tune,
            label: context.t(LocaleKeys.commonComplexity),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final level in levels)
                CoverChip(
                  label: switch (imageComplexityLabelKey(level)) {
                    final key? => context.t(key),
                    _ => level,
                  },
                  selected: selected == level,
                  onTap: () => controller.setComplexity(level),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class CoverResolutionSection extends ConsumerWidget {
  const CoverResolutionSection({super.key, required this.novelId});

  final String novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CoverSectionHead(
          icon: RevericIcons.open_in_full_rounded,
          label: context.t(LocaleKeys.editorCoverResolution),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final resolution in coverResolutions)
              CoverChip(
                label: resolution.id.toUpperCase(),
                selected: state.resolutionId == resolution.id,
                onTap: () => controller.setResolution(resolution.id),
              ),
          ],
        ),
      ],
    );
  }
}

/// 比例用小方块示意形状，比只写「3:4」好认。
class CoverRatioSection extends ConsumerWidget {
  const CoverRatioSection({super.key, required this.novelId});

  final String novelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CoverSectionHead(
          icon: RevericIcons.image_outlined,
          label: context.t(LocaleKeys.editorCoverRatio),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final ratio in coverRatios)
              _RatioTile(
                ratio: ratio,
                selected: state.ratioId == ratio.id,
                onTap: () => controller.setRatio(ratio.id),
                colors: colors,
                typo: typo,
              ),
          ],
        ),
      ],
    );
  }
}

class _RatioTile extends StatelessWidget {
  const _RatioTile({
    required this.ratio,
    required this.selected,
    required this.onTap,
    required this.colors,
    required this.typo,
  });

  final CoverRatioOption ratio;
  final bool selected;
  final VoidCallback onTap;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? colors.accent : colors.textSecondary;
    // 形状缩略图统一塞进 22×22 的方格里，长边顶满。
    final landscape = ratio.w >= ratio.h;
    final width = landscape ? 22.0 : 22.0 * ratio.w / ratio.h;
    final height = landscape ? 22.0 * ratio.h / ratio.w : 22.0;

    return Material(
      color: selected ? colors.accent.withValues(alpha: 0.14) : colors.surface,
      borderRadius: BorderRadius.circular(RevericRadius.small),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.small),
        child: Container(
          width: 64,
          padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xs),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(RevericRadius.small),
            border: Border.all(color: selected ? colors.accent : colors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 24,
                child: Center(
                  child: Container(
                    width: width,
                    height: height,
                    decoration: BoxDecoration(
                      border: Border.all(color: foreground, width: 1.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Text(ratio.hint, style: typo.uiTiny.copyWith(color: foreground)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 高级设置：默认折叠，展开后才露出风格 / 色调 / 构图 / 封面档案 / 设计灵感
/// 这些可点选追加进提示词的碎片。
class CoverAdvancedSection extends ConsumerWidget {
  const CoverAdvancedSection({
    super.key,
    required this.novelId,
    required this.children,
  });

  final String novelId;
  final List<Widget> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final open = ref.watch(
      coverStudioControllerProvider(novelId).select((s) => s.advancedOpen),
    );
    final controller = ref.read(
      coverStudioControllerProvider(novelId).notifier,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: controller.toggleAdvanced,
          borderRadius: BorderRadius.circular(RevericRadius.small),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xxs),
            child: Row(
              children: [
                RevericIcon(
                  open ? RevericIcons.caret_down : RevericIcons.caret_right,
                  size: 13,
                  color: colors.textMuted,
                ),
                const SizedBox(width: RevericSpacing.xs),
                Text(
                  context.t(LocaleKeys.editorCoverAdvanced),
                  style: typo.uiSemibold.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ),
        if (open) ...[
          const SizedBox(height: RevericSpacing.md),
          for (final child in children) ...[
            child,
            const SizedBox(height: RevericSpacing.x3l),
          ],
        ],
      ],
    );
  }
}

String coverQualityLabelKey(String id) => switch (id) {
  'low' => LocaleKeys.editorCoverQualityLow,
  'medium' => LocaleKeys.editorCoverQualityMedium,
  'high' => LocaleKeys.editorCoverQualityHigh,
  _ => LocaleKeys.editorCoverQualityAuto,
};

/// 用户可编辑的提示词。定义权在这里；作品简介不预填，标题行一键追加。
/// 下面的灵感只负责追加。
class CoverPromptSection extends StatelessWidget {
  const CoverPromptSection({
    super.key,
    required this.field,
    required this.synopsis,
    required this.onAppend,
  });

  final Widget field;
  final String synopsis;
  final ValueChanged<String> onAppend;

  @override
  Widget build(BuildContext context) {
    final snippet = coverSynopsisSnippet(synopsis);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CoverSectionHead(
          icon: RevericIcons.file_text,
          label: context.t(LocaleKeys.editorCoverPromptPreview),
          trailing: snippet.isEmpty
              ? null
              : TextButton(
                  onPressed: () => onAppend(snippet),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                      horizontal: RevericSpacing.sm,
                    ),
                    minimumSize: Size.zero,
                  ),
                  child: Text(context.t(LocaleKeys.editorCoverAppendSynopsis)),
                ),
        ),
        field,
      ],
    );
  }
}

// ---- 显示标签 -------------------------------------------------------------
// 配方目录只存送给模型的中文措辞；界面标签在这里查 LocaleKeys。

String coverStyleLabelKey(String id) => switch (id) {
  '版画质感' => LocaleKeys.editorCoverStylePrint,
  '极简文字' => LocaleKeys.editorCoverStyleMinimalText,
  '摄影写实' => LocaleKeys.editorCoverStylePhotoreal,
  '手绘插画' => LocaleKeys.editorCoverStyleHandDrawn,
  _ => LocaleKeys.editorCoverStyleInk,
};

String coverPaletteLabelKey(String id) => switch (id) {
  'brass' => LocaleKeys.editorCoverPaletteBrass,
  'night' => LocaleKeys.editorCoverPaletteNight,
  'cinnabar' => LocaleKeys.editorCoverPaletteCinnabar,
  'grey' => LocaleKeys.editorCoverPaletteGrey,
  _ => LocaleKeys.editorCoverPaletteInk,
};

String coverCompositionLabelKey(String id) => switch (id) {
  '中心构图' => LocaleKeys.editorCoverCompositionCenter,
  '三分构图' => LocaleKeys.editorCoverCompositionThirds,
  '对称构图' => LocaleKeys.editorCoverCompositionSymmetric,
  _ => LocaleKeys.editorCoverCompositionNegative,
};
