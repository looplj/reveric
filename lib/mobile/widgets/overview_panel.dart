// 职责: 移动端作品概览分区 — 展示作品摘要、封面操作、写作入口及作品级规则入口
// 关联文件:
//   lib/mobile/pages/novel_editor_page.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/agent_rule_providers.dart
//   lib/shared/utils/chapter_last_sentence.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/models/novel.dart
//   lib/shared/models/content_status.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/agent_rule.json
//   assets/translations/zh-CN/agent_rule.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../shared/components/reveric_badge.dart';
import '../../shared/components/reveric_button.dart';
import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/models/content_kind.dart';
import '../../shared/models/content_status.dart';
import '../../shared/models/novel.dart';
import '../../shared/providers/agent_rule_providers.dart';
import '../../shared/providers/cover_studio_providers.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/utils/chapter_last_sentence.dart';
import '../pages/agent_model_settings_page.dart';
import '../pages/novel_create_page.dart';
import '../../shared/widgets/media_asset_image.dart';

final _log = AppLogger.forModule('MobileOverview');

/// 概览页可跳转的目标分区（由 page 层映射成分区索引）。
enum MobileOverviewTarget {
  chapters,
  lore,
  outlines,
  characters,
  foreshadowings,
}

/// 移动端作品概览分区。只读总览：读取章节/角色/世界观/伏笔统计与上次写到，
/// 提供继续写作与各分区入口；所有跳转交由 page 层处理（切分区 / 选章）。
class MobileOverviewPanel extends ConsumerStatefulWidget {
  const MobileOverviewPanel({
    super.key,
    required this.novel,
    required this.databasePath,
    required this.onOpenSection,
    required this.onContinueWriting,
    required this.onOpenChat,
    required this.onOpenChatWithPrompt,
    required this.onEditNovel,
    required this.onOpenAgentRules,
    required this.onOpenCoverStudio,
    required this.onUploadCover,
  });

  final Novel novel;
  final String databasePath;

  /// 切换到目标分区（chapters 仅切回写作面板，保留当前选章）。
  final ValueChanged<MobileOverviewTarget> onOpenSection;

  /// 打开 AI 对话并自动发送继续写作请求。
  final ValueChanged<String> onContinueWriting;

  /// 直接进入本作品的 AI 对话（新建会话），无需先打开章节。
  final VoidCallback onOpenChat;

  /// 进入本作品的 AI 对话并预填一句提示词（用户可改后再发送）。
  final ValueChanged<String> onOpenChatWithPrompt;

  /// 进入作品信息编辑页（复用书架长按的编辑入口）。
  final VoidCallback onEditNovel;

  /// 进入作品级智能体规则管理页。
  final VoidCallback onOpenAgentRules;

  /// 进入 AI 封面工作台。
  final ValueChanged<Novel> onOpenCoverStudio;

  /// 从系统相册选择并更新作品封面。
  final Future<void> Function() onUploadCover;

  @override
  ConsumerState<MobileOverviewPanel> createState() =>
      _MobileOverviewPanelState();
}

class _MobileOverviewPanelState extends ConsumerState<MobileOverviewPanel> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToAgentConfig() {
    if (!_scrollController.hasClients) {
      return;
    }
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 监听 novelProvider 取最新作品信息，编辑页保存后概览即时刷新；流未就绪时回退到传入值。
    final novel =
        ref.watch(novelProvider(widget.novel.id)).asData?.value ?? widget.novel;
    final chapters =
        ref.watch(chapterTreeProvider(widget.databasePath)).asData?.value ??
        const <Chapter>[];
    final lastWritten = ref
        .watch(lastWrittenChapterProvider(widget.databasePath))
        .asData
        ?.value;
    final characters =
        ref
            .watch(characterProfilesProvider(widget.databasePath))
            .asData
            ?.value ??
        const <CharacterProfile>[];
    final worldbuilding =
        ref
            .watch(
              documentsProvider(
                path: widget.databasePath,
                type: documentTypeLore,
              ),
            )
            .asData
            ?.value
            .where((d) => !d.isFolder)
            .toList() ??
        const <Document>[];
    final foreshadowings =
        ref.watch(foreshadowingsProvider(widget.databasePath)).asData?.value ??
        const <Foreshadowing>[];
    final canOpenCoverStudio = ref.watch(canOpenCoverStudioProvider);

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x4l,
        RevericSpacing.lg,
        RevericSpacing.x4l,
        RevericSpacing.x5l,
      ),
      children: [
        _TitleSection(novel: novel, onEditNovel: widget.onEditNovel),
        const SizedBox(height: RevericSpacing.x3l),
        _ContinueHero(
          chapters: chapters,
          lastWritten: lastWritten,
          onContinueWriting: widget.onContinueWriting,
          onOpenSection: widget.onOpenSection,
          onOpenChat: widget.onOpenChat,
          onOpenChatWithPrompt: widget.onOpenChatWithPrompt,
          onScrollToAgentConfig: _scrollToAgentConfig,
        ),
        const SizedBox(height: RevericSpacing.x3l),
        _ProjectIntroCard(
          novel: novel,
          chapterCount: chapters.where((c) => c.isChapter).length,
          settingCount: worldbuilding.length,
          characterCount: characters.length,
          noteCount: foreshadowings.length,
          canOpenCoverStudio: canOpenCoverStudio,
          onOpenCoverStudio: widget.onOpenCoverStudio,
          onUploadCover: widget.onUploadCover,
        ),
        const SizedBox(height: RevericSpacing.x3l),
        _SnippetsCard(
          foreshadowings: foreshadowings,
          worldbuildingEntries: worldbuilding,
          onOpenSection: widget.onOpenSection,
        ),
        const SizedBox(height: RevericSpacing.x3l),
        _WritingEntries(onOpenSection: widget.onOpenSection),
        const SizedBox(height: RevericSpacing.x3l),
        _AgentConfigSection(
          databasePath: widget.databasePath,
          onOpenAgentRules: widget.onOpenAgentRules,
        ),
      ],
    );
  }
}

// =============================================================================
// Agent config: AI 配置入口（智能体规则）
// =============================================================================
class _AgentConfigSection extends ConsumerWidget {
  const _AgentConfigSection({
    required this.databasePath,
    required this.onOpenAgentRules,
  });

  final String databasePath;
  final VoidCallback onOpenAgentRules;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final ruleCount =
        ref.watch(agentRulesStreamProvider(databasePath)).value?.length ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.workspaceAgentConfig),
          style: typo.heading2.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: RevericSpacing.lg),
        _AgentConfigRow(
          icon: RevericIcons.rule_outlined,
          iconColor: colors.accentWarm,
          iconBackground: colors.accentWarm.withValues(alpha: 0.14),
          label: context.t(LocaleKeys.agentRuleTitle),
          hint: context.t(LocaleKeys.agentRuleOverviewHint),
          value: context.t(
            LocaleKeys.agentRuleCount,
            namedArgs: {'count': '$ruleCount'},
          ),
          onTap: onOpenAgentRules,
        ),
      ],
    );
  }
}

class _AgentConfigRow extends StatelessWidget {
  const _AgentConfigRow({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.label,
    required this.hint,
    required this.value,
    required this.onTap,
  });

  final String icon;
  final Color iconColor;
  final Color iconBackground;
  final String label;
  final String hint;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: Container(
        padding: const EdgeInsets.all(RevericSpacing.lg),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(RevericRadius.large),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: iconBackground,
                borderRadius: BorderRadius.circular(RevericRadius.large),
              ),
              alignment: Alignment.center,
              child: RevericIcon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            Text(value, style: typo.uiSmall.copyWith(color: colors.textMuted)),
            RevericIcon(
              RevericIcons.chevron_right,
              size: 18,
              color: colors.textSubtle,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Title: 标题 + 标签 + 状态徽章
// =============================================================================
class _TitleSection extends StatelessWidget {
  const _TitleSection({required this.novel, required this.onEditNovel});

  final Novel novel;
  final VoidCallback onEditNovel;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final tags = novel.tags;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                novel.title,
                style: typo.display.copyWith(color: colors.textPrimary),
              ),
            ),
            // 草稿不在改编的原著候选里，选不回来，所以只给书架上的小说。
            if (novel.contentKind == contentKindNovel && !novel.draft) ...[
              const SizedBox(width: RevericSpacing.sm),
              RevericButton.secondary(
                onPressed: () => openNovelAdaptation(context, novel),
                icon: RevericIcons.movie_outlined,
                label: context.t(LocaleKeys.libraryActionAdapt),
                size: RevericButtonSize.compact,
              ),
            ],
            const SizedBox(width: RevericSpacing.sm),
            InkWell(
              onTap: onEditNovel,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(RevericSpacing.sm),
                child: RevericIcon(
                  RevericIcons.edit_outlined,
                  size: 20,
                  color: colors.textSecondary,
                ),
              ),
            ),
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
                    borderRadius: BorderRadius.circular(RevericRadius.pill),
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
    return RevericBadge(
      label: _statusLabel(context, status),
      color: _statusColor(RevericTheme.colorsOf(context), status),
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
// Continue writing hero: 上次写到预览 + 继续写按钮 + 次要入口
// =============================================================================
class _ContinueHero extends StatelessWidget {
  const _ContinueHero({
    required this.chapters,
    required this.lastWritten,
    required this.onContinueWriting,
    required this.onOpenSection,
    required this.onOpenChat,
    required this.onOpenChatWithPrompt,
    required this.onScrollToAgentConfig,
  });

  final List<Chapter> chapters;
  final Chapter? lastWritten;
  final ValueChanged<String> onContinueWriting;
  final ValueChanged<MobileOverviewTarget> onOpenSection;
  final VoidCallback onOpenChat;
  final ValueChanged<String> onOpenChatWithPrompt;
  final VoidCallback onScrollToAgentConfig;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final latest = _resolveLatestChapter(chapters);
    final lastSentence = extractLastWrittenSentence(lastWritten?.content);
    final hasChapter = latest != null;
    final continueLabel = hasChapter
        ? context.t(
            LocaleKeys.workspaceContinueChapter,
            namedArgs: {'number': '${latest.chapterNum ?? "?"}'},
          )
        : context.t(LocaleKeys.workspaceStartFirstChapter);
    // 「上次写到」来源章节不是要继续的最新章节时，提示句子来自更早一章。
    final isLastFromOlderChapter =
        lastWritten != null && latest != null && lastWritten!.id != latest.id;
    final lastWroteLabel = isLastFromOlderChapter
        ? context.t(
            LocaleKeys.workspaceLastWroteFromChapter,
            namedArgs: {'number': '${lastWritten!.chapterNum ?? "?"}'},
          )
        : context.t(LocaleKeys.workspaceLastWroteText);
    final quickPrompts = <String>[
      context.t(LocaleKeys.workspaceAiQuickContinue),
      context.t(LocaleKeys.workspaceAiQuickPlot),
      context.t(LocaleKeys.workspaceAiQuickSetting),
    ];

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.accentWarm.withValues(alpha: 0.10),
            colors.accentAmber.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RevericIcon(
                RevericIcons.eco_outlined,
                size: 16,
                color: colors.accentWarm,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.workspaceContinueWriting),
                style: typo.uiSemibold.copyWith(color: colors.accentWarm),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          Text(
            lastWroteLabel,
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            lastSentence ?? context.t(LocaleKeys.workspaceLastWroteEmpty),
            style: typo.heading2.copyWith(
              color: colors.textPrimary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            context.t(LocaleKeys.workspaceContinueWritingHint),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: RevericSpacing.x2l),
          SizedBox(
            width: double.infinity,
            child: RevericButton.primary(
              onPressed: () => onContinueWriting(continueLabel),
              icon: RevericIcons.create_outlined,
              label: continueLabel,
            ),
          ),
          const SizedBox(height: RevericSpacing.md),
          // 让 AI 写：仿输入条，一键进作品级对话（无需先打开章节）。
          _AiPromptBar(onTap: onOpenChat),
          const SizedBox(height: RevericSpacing.md),
          Wrap(
            spacing: RevericSpacing.sm,
            runSpacing: RevericSpacing.sm,
            children: [
              for (final prompt in quickPrompts)
                _QuickPromptChip(
                  label: prompt,
                  onTap: () => onOpenChatWithPrompt(prompt),
                ),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          Wrap(
            spacing: RevericSpacing.sm,
            runSpacing: RevericSpacing.sm,
            children: [
              RevericButton.secondary(
                icon: RevericIcons.list_alt_outlined,
                label: context.t(LocaleKeys.workspaceViewOutline),
                onPressed: () => onOpenSection(MobileOverviewTarget.outlines),
              ),
              RevericButton.secondary(
                icon: RevericIcons.public_outlined,
                label: context.t(LocaleKeys.workspaceBrowseSettings),
                onPressed: () => onOpenSection(MobileOverviewTarget.lore),
              ),
              RevericButton.secondary(
                icon: RevericIcons.auto_awesome_outlined,
                label: context.t(LocaleKeys.workspaceAgentConfig),
                onPressed: onScrollToAgentConfig,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Chapter? _resolveLatestChapter(List<Chapter> chapters) {
    final filtered = chapters.where((c) => c.isNumberedChapter).toList();
    if (filtered.isEmpty) {
      return null;
    }
    filtered.sort((a, b) => (b.chapterNum ?? 0).compareTo(a.chapterNum ?? 0));
    return filtered.first;
  }
}

/// 仿输入条的 AI 入口：点击进入本作品 AI 对话（新建会话）。
class _AiPromptBar extends StatelessWidget {
  const _AiPromptBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.pill),
      child: Container(
        height: 46,
        padding: const EdgeInsets.only(
          left: RevericSpacing.lg,
          right: RevericSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          border: Border.all(color: colors.borderInput),
        ),
        child: Row(
          children: [
            RevericIcon(
              RevericIcons.auto_awesome,
              size: 17,
              color: colors.accent,
            ),
            const SizedBox(width: RevericSpacing.sm),
            Expanded(
              child: Text(
                context.t(LocaleKeys.workspaceAskAiPlaceholder),
                style: typo.uiSmall.copyWith(color: colors.textSubtle),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: colors.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: RevericIcon(
                RevericIcons.send_rounded,
                size: 16,
                color: colors.onAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 快捷意图 chip：点击进入 AI 对话并预填该提示词。
class _QuickPromptChip extends StatelessWidget {
  const _QuickPromptChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: colors.accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          border: Border.all(color: colors.borderSubtle),
        ),
        child: Text(
          label,
          style: typo.uiSmallSemibold.copyWith(color: colors.accentWarm),
        ),
      ),
    );
  }
}

// =============================================================================
// Project intro: 封面 + 简介 + 统计
// =============================================================================
class _ProjectIntroCard extends ConsumerWidget {
  const _ProjectIntroCard({
    required this.novel,
    required this.chapterCount,
    required this.settingCount,
    required this.characterCount,
    required this.noteCount,
    required this.canOpenCoverStudio,
    required this.onOpenCoverStudio,
    required this.onUploadCover,
  });

  final Novel novel;
  final int chapterCount;
  final int settingCount;
  final int characterCount;
  final int noteCount;
  final bool canOpenCoverStudio;
  final ValueChanged<Novel> onOpenCoverStudio;
  final Future<void> Function() onUploadCover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final resolvedCoverPath = watchMediaAssetFile(ref, novel.coverAssetId);
    final coverFile = resolvedCoverPath == null
        ? null
        : File(resolvedCoverPath);
    final hasCover = coverFile != null;

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
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
                onOpenCoverStudio: () => onOpenCoverStudio(novel),
                onUploadCover: onUploadCover,
              ),
              const SizedBox(width: RevericSpacing.lg),
              Expanded(
                child: Text(
                  novel.description.isEmpty
                      ? context.t(LocaleKeys.commonNoDescription)
                      : novel.description,
                  style: typo.uiSmall.copyWith(
                    color: colors.textSecondary,
                    height: 1.6,
                  ),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.lg,
              vertical: RevericSpacing.md,
            ),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(RevericRadius.large),
              border: Border.all(color: colors.borderSubtle),
            ),
            child: Wrap(
              spacing: RevericSpacing.x2l,
              runSpacing: RevericSpacing.sm,
              children: [
                _statText(
                  context,
                  context.t(LocaleKeys.workspaceStatChapters),
                  '$chapterCount',
                ),
                _statText(
                  context,
                  context.t(LocaleKeys.workspaceStatSettings),
                  '$settingCount',
                ),
                _statText(
                  context,
                  context.t(LocaleKeys.workspaceStatCharacters),
                  '$characterCount',
                ),
                _statText(
                  context,
                  context.t(LocaleKeys.workspaceStatNotes),
                  '$noteCount',
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

enum _CoverAction { preview, save, studio, upload }

class _CoverThumbnail extends HookWidget {
  const _CoverThumbnail({
    required this.hasCover,
    required this.coverFile,
    required this.canOpenCoverStudio,
    required this.onOpenCoverStudio,
    required this.onUploadCover,
  });

  final bool hasCover;
  final File? coverFile;
  final bool canOpenCoverStudio;
  final VoidCallback onOpenCoverStudio;
  final Future<void> Function() onUploadCover;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final file = coverFile;
    final selecting = useState(false);

    Future<void> showActions() async {
      if (!context.mounted || selecting.value) {
        return;
      }
      selecting.value = true;
      try {
        await _showCoverActions(context, file);
      } catch (error, stackTrace) {
        _log.error('Cover action failed', error: error, stackTrace: stackTrace);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      } finally {
        if (context.mounted) {
          selecting.value = false;
        }
      }
    }

    return InkWell(
      key: const ValueKey('mobile-overview-cover'),
      onTap: selecting.value ? null : showActions,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: Container(
        width: 80,
        height: 112,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.large),
          border: Border.all(color: colors.borderSubtle),
        ),
        alignment: Alignment.center,
        child: hasCover && file != null
            ? Image(
                image: ResizeImage(FileImage(file), width: 240),
                fit: BoxFit.cover,
                width: 80,
                height: 112,
              )
            : RevericIcon(
                RevericIcons.image_outlined,
                size: 28,
                color: colors.textSubtle,
              ),
      ),
    );
  }

  Future<void> _showCoverActions(BuildContext context, File? coverFile) async {
    final colors = RevericTheme.colorsOf(context);
    final action = await showModalBottomSheet<_CoverAction>(
      context: context,
      backgroundColor: colors.surface,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(RevericRadius.x2l),
        ),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x4l,
              RevericSpacing.md,
              RevericSpacing.x4l,
              RevericSpacing.x5l,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (coverFile != null) ...[
                  _CoverActionTile(
                    icon: RevericIcons.open_in_full_rounded,
                    label: context.t(LocaleKeys.workspaceCoverPreview),
                    onTap: () {
                      Navigator.of(sheetContext).pop(_CoverAction.preview);
                    },
                  ),
                  const SizedBox(height: RevericSpacing.sm),
                  _CoverActionTile(
                    icon: RevericIcons.download,
                    label: context.t(LocaleKeys.workspaceCoverSaveLocal),
                    onTap: () {
                      Navigator.of(sheetContext).pop(_CoverAction.save);
                    },
                  ),
                  const SizedBox(height: RevericSpacing.sm),
                ],
                _CoverActionTile(
                  icon: RevericIcons.auto_awesome,
                  label: context.t(LocaleKeys.editorOpenCoverStudio),
                  onTap: () {
                    Navigator.of(sheetContext).pop(_CoverAction.studio);
                  },
                ),
                const SizedBox(height: RevericSpacing.sm),
                _CoverActionTile(
                  icon: RevericIcons.upload_outlined,
                  label: context.t(LocaleKeys.editorUploadCover),
                  onTap: () {
                    Navigator.of(sheetContext).pop(_CoverAction.upload);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!context.mounted || action == null) {
      return;
    }

    switch (action) {
      case _CoverAction.preview:
        if (coverFile != null) {
          _showCoverPreview(context, coverFile);
        }
        break;
      case _CoverAction.save:
        if (coverFile != null) {
          await _saveCoverLocally(context, coverFile);
        }
        break;
      case _CoverAction.studio:
        if (canOpenCoverStudio) {
          onOpenCoverStudio();
        } else {
          await openMobileAgentModelSettingsPage(context);
        }
        break;
      case _CoverAction.upload:
        await onUploadCover();
        break;
    }
  }

  void _showCoverPreview(BuildContext context, File coverFile) {
    final colors = RevericTheme.colorsOf(context);
    showDialog<void>(
      context: context,
      barrierColor: colors.textPrimary.withValues(alpha: 0.72),
      builder: (context) {
        return Dialog.fullscreen(
          backgroundColor: colors.canvas,
          child: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    maxScale: 4,
                    child: Center(
                      child: Image.file(
                        coverFile,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => RevericIcon(
                          RevericIcons.broken_image_outlined,
                          size: 48,
                          color: colors.textMuted,
                        ),
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
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(coverFile.path)],
          fileNameOverrides: [coverFile.uri.pathSegments.last],
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
}

class _CoverActionTile extends StatelessWidget {
  const _CoverActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: RevericSizes.buttonHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.lg,
          vertical: RevericSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(RevericRadius.large),
          border: Border.all(color: colors.borderSubtle),
        ),
        child: Row(
          children: [
            RevericIcon(icon, size: 18, color: colors.textSecondary),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Text(
                label,
                style: typo.ui.copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Snippets: 灵感便签（伏笔 setup/payoff + 世界观正文）
// =============================================================================
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

class _SnippetsCard extends StatelessWidget {
  const _SnippetsCard({
    required this.foreshadowings,
    required this.worldbuildingEntries,
    required this.onOpenSection,
  });

  final List<Foreshadowing> foreshadowings;
  final List<Document> worldbuildingEntries;
  final ValueChanged<MobileOverviewTarget> onOpenSection;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final notes = _buildNotes(context);

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
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
              Expanded(
                child: Text(
                  context.t(LocaleKeys.workspaceCreativeSnippets),
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
              ),
              InkWell(
                onTap: () => onOpenSection(MobileOverviewTarget.foreshadowings),
                borderRadius: BorderRadius.circular(RevericRadius.large),
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
              onTap: () => onOpenSection(MobileOverviewTarget.foreshadowings),
            )
          else
            for (var i = 0; i < notes.length; i++) ...[
              if (i > 0) const SizedBox(height: RevericSpacing.md),
              _StickyNoteCard(note: notes[i], index: i),
            ],
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
      if (result.length >= 3) {
        break;
      }
      final body = foreshadow.setup.isNotEmpty
          ? foreshadow.setup
          : foreshadow.payoff;
      if (body.isEmpty) {
        continue;
      }
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
        if (result.length >= 3) {
          break;
        }
        if (entry.content.isEmpty) {
          continue;
        }
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

class _StickyNoteCard extends StatelessWidget {
  const _StickyNoteCard({required this.note, required this.index});

  final _SnippetNote note;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final palette = <Color>[
      colors.accentAmber.withValues(alpha: 0.18),
      colors.accent.withValues(alpha: 0.12),
      colors.accentWarm.withValues(alpha: 0.16),
    ];
    final tints = <Color>[colors.accentAmber, colors.accent, colors.accentWarm];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: palette[index % palette.length],
        borderRadius: BorderRadius.circular(RevericRadius.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            note.body,
            style: typo.uiSmall.copyWith(
              color: colors.textPrimary,
              height: 1.5,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: RevericSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '— ${note.tag}',
              style: typo.uiTiny.copyWith(
                color: tints[index % tints.length],
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

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: Container(
        width: double.infinity,
        height: 96,
        padding: const EdgeInsets.all(RevericSpacing.lg),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.large),
          border: Border.all(color: colors.borderSubtle),
        ),
        child: Text(
          context.t(LocaleKeys.workspaceCreativeSnippetsEmpty),
          textAlign: TextAlign.center,
          style: typo.uiSmall.copyWith(color: colors.textMuted),
        ),
      ),
    );
  }
}

// =============================================================================
// Writing entries: 4 张写作入口卡片（2×2）
// =============================================================================
class _EntrySpec {
  const _EntrySpec({
    required this.icon,
    required this.title,
    required this.hint,
    required this.tint,
    required this.target,
  });

  final String icon;
  final String title;
  final String hint;
  final Color tint;
  final MobileOverviewTarget target;
}

class _WritingEntries extends StatelessWidget {
  const _WritingEntries({required this.onOpenSection});

  final ValueChanged<MobileOverviewTarget> onOpenSection;

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
        target: MobileOverviewTarget.chapters,
      ),
      _EntrySpec(
        icon: RevericIcons.public_outlined,
        title: context.t(LocaleKeys.workspaceLore),
        hint: context.t(LocaleKeys.workspaceLoreHint),
        tint: colors.accent,
        target: MobileOverviewTarget.lore,
      ),
      _EntrySpec(
        icon: RevericIcons.auto_stories_outlined,
        title: context.t(LocaleKeys.workspaceWritingOutlinePlot),
        hint: context.t(LocaleKeys.workspaceWritingOutlinePlotHint),
        tint: colors.accentWarm,
        target: MobileOverviewTarget.outlines,
      ),
      _EntrySpec(
        icon: RevericIcons.people_alt_outlined,
        title: context.t(LocaleKeys.workspaceWritingCharacters),
        hint: context.t(LocaleKeys.workspaceWritingCharactersHint),
        tint: colors.accent,
        target: MobileOverviewTarget.characters,
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
        Row(
          children: [
            Expanded(
              child: _EntryCard(spec: entries[0], onOpenSection: onOpenSection),
            ),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: _EntryCard(spec: entries[1], onOpenSection: onOpenSection),
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.md),
        Row(
          children: [
            Expanded(
              child: _EntryCard(spec: entries[2], onOpenSection: onOpenSection),
            ),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: _EntryCard(spec: entries[3], onOpenSection: onOpenSection),
            ),
          ],
        ),
      ],
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.spec, required this.onOpenSection});

  final _EntrySpec spec;
  final ValueChanged<MobileOverviewTarget> onOpenSection;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return InkWell(
      onTap: () => onOpenSection(spec.target),
      borderRadius: BorderRadius.circular(RevericRadius.xl),
      child: Container(
        padding: const EdgeInsets.all(RevericSpacing.lg),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              spec.tint.withValues(alpha: 0.14),
              spec.tint.withValues(alpha: 0.04),
            ],
          ),
          borderRadius: BorderRadius.circular(RevericRadius.xl),
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
            const SizedBox(height: RevericSpacing.md),
            Text(
              spec.title,
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.xs),
            Text(
              spec.hint,
              style: typo.uiTiny.copyWith(color: colors.textMuted, height: 1.5),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);

    return InkWell(
      onTap: () => Clipboard.setData(ClipboardData(text: text)),
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.xs),
        child: RevericIcon(
          RevericIcons.copy_rounded,
          size: 14,
          color: colors.textMuted,
        ),
      ),
    );
  }
}
