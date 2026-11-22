// 职责: 桌面端沉浸式阅读页 — 格式化正文渲染、目录抽屉、章节或连续滚动阅读、阅读设置 popover、进度持久化。
// 关联文件:
//   lib/shared/widgets/novel_open_boundary.dart
//   lib/desktop/pages/home.dart
//   lib/shared/widgets/reading/reading_content_view.dart
//   lib/shared/widgets/reading/reading_theme_palette.dart
//   lib/shared/utils/chapter_text_formatter.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/reading_progress_providers.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/logger/app_logger.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/theme/theme.dart
//   assets/translations/en/reading.json
//   assets/translations/zh-CN/reading.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/widgets/novel_open_boundary.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/chapter.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/providers/reading_progress_providers.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/utils/chapter_text_formatter.dart';
import '../../../shared/widgets/reading/reading_content_view.dart';
import '../../../shared/widgets/reading/chapter_title.dart';
import '../../../shared/widgets/reading/reading_settings_controls.dart';
import '../../../shared/widgets/reading/reading_theme_palette.dart';
import '../../widgets/desktop_window_frame.dart';
import '../narration/button.dart';
import '../narration/dialog.dart';

final _log = AppLogger.forModule('ReadingRestore');

const _readingToolbarHeight = RevericSizes.buttonHeight + RevericSpacing.x2l;
const _desktopReadingMaxWidth = 800.0;
const _readingTocItemExtent =
    RevericSizes.buttonHeight + RevericSpacing.x4l + RevericSpacing.sm;

/// 桌面端阅读页，提供阅读进度、章节切换和当前章朗读。
///
/// 通过 [novelId]、[novelTitle]、[databasePath] 构造。
/// 进入时自动恢复上次阅读章节；切换章节时持久化进度；滚动时持久化偏移。
class DesktopReadingPage extends HookConsumerWidget {
  const DesktopReadingPage({
    super.key,
    required this.novelId,
    required this.novelTitle,
    required this.databasePath,
    this.detachedWindow = false,
    this.pinned = false,
    this.onPinnedChanged,
  });

  final String novelId;
  final String novelTitle;
  final String databasePath;

  /// 承载在独立子窗口中：使用原生标题栏，由系统按钮关闭，不显示返回。
  final bool detachedWindow;

  /// 子窗口是否置顶；[onPinnedChanged] 为空时不显示置顶按钮。
  final bool pinned;
  final ValueChanged<bool>? onPinnedChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NovelOpenBoundary(
      novelId: novelId,
      child: HookConsumer(
        builder: (context, ref, _) => _buildContent(context, ref),
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref) {
    final typo = RevericTheme.typographyOf(context);

    // 阅读设置
    final fontFamily = ref.watch(readingFontFamilyProvider);
    final fontSize = ref.watch(readingFontSizeProvider);
    final letterSpacing = ref.watch(readingLetterSpacingProvider);
    final lineHeight = ref.watch(readingLineHeightProvider);
    final paragraphSpacing = ref.watch(readingParagraphSpacingProvider);
    final margin = ref.watch(readingMarginProvider);
    final bold = ref.watch(readingBoldProvider);
    final backgroundTheme = ref.watch(readingBackgroundThemeProvider);
    final readingMode = ref.watch(desktopReadingModeProvider);
    final palette = ReadingPalette.of(backgroundTheme);

    // 章节树
    final chaptersAsync = ref.watch(chapterTreeProvider(databasePath));
    final readableChapters =
        chaptersAsync.value?.where((chapter) => chapter.isChapter).toList() ??
        const <Chapter>[];
    final isChapterTreeLoading =
        chaptersAsync.isLoading && !chaptersAsync.hasValue;
    final hasChapterTreeError = chaptersAsync.hasError;

    // 阅读进度
    final progressAsync = ref.watch(novelReadingProgressProvider(novelId));
    final progress = progressAsync.value;

    // 本地状态：当前章节 id、滚动偏移
    final currentChapterId = useState<String?>(progress?.chapterId);
    final continuousAnchorChapterId = useState<String?>(progress?.chapterId);
    final scrollController = useMemoized(() => ScrollController(), []);
    final lastSavedOffset = useRef<double?>(null);
    final lastContinuousProgress =
        useRef<({String chapterId, double scrollOffset})?>(null);
    final debounceTimer = useRef<Timer?>(null);

    // dispose 时 cancel timer + flush 待写偏移
    useEffect(() {
      // 在 build 阶段捕获 notifier，dispose 时 ref 已不可用。
      final notifier = ref.read(novelReadingProgressProvider(novelId).notifier);
      return () {
        debounceTimer.value?.cancel();
        final pendingContinuousProgress = lastContinuousProgress.value;
        if (pendingContinuousProgress != null) {
          unawaited(
            notifier.setChapterProgress(
              chapterId: pendingContinuousProgress.chapterId,
              scrollOffset: pendingContinuousProgress.scrollOffset,
            ),
          );
          return;
        }
        final pendingOffset = lastSavedOffset.value;
        if (pendingOffset != null) {
          unawaited(notifier.setScrollOffset(pendingOffset));
        }
      };
    }, [novelId]);

    // 应用生命周期监听：进入后台时 flush 待写偏移
    useEffect(() {
      final notifier = ref.read(novelReadingProgressProvider(novelId).notifier);
      final observer = _AppLifecycleObserver(
        onPaused: () {
          debounceTimer.value?.cancel();
          final pendingContinuousProgress = lastContinuousProgress.value;
          if (pendingContinuousProgress != null) {
            unawaited(
              notifier.setChapterProgress(
                chapterId: pendingContinuousProgress.chapterId,
                scrollOffset: pendingContinuousProgress.scrollOffset,
              ),
            );
            lastContinuousProgress.value = null;
            return;
          }
          final pendingOffset = lastSavedOffset.value;
          if (pendingOffset != null) {
            unawaited(notifier.setScrollOffset(pendingOffset));
            lastSavedOffset.value = null;
          }
        },
      );
      WidgetsBinding.instance.addObserver(observer);
      return () {
        WidgetsBinding.instance.removeObserver(observer);
      };
    }, [novelId]);

    // 进度恢复：仅在首次加载（chapters + progress 都就绪）时执行一次。
    // 之后章节切换由 selectChapter / updateContinuousChapter 负责，
    // restore effect 不再干预，避免与用户操作竞争。
    final progressRestored = useRef(false);
    useEffect(() {
      if (progressRestored.value) {
        return null;
      }
      // 等待 chapters 和 progress 都就绪。
      // progress == null 表示 AsyncLoading，需要继续等待。
      if (readableChapters.isEmpty || progress == null) {
        return null;
      }
      progressRestored.value = true;
      final preferredId = progress.chapterId ?? readableChapters.first.id;
      if (_log.isDebugEnabled) {
        _log.debug(
          'desktop novel=$novelId '
          'chapterId=${progress.chapterId} '
          'scrollOffset=${progress.scrollOffset} '
          'preferredId=$preferredId',
        );
      }
      currentChapterId.value = preferredId;
      continuousAnchorChapterId.value = preferredId;
      if (progress.chapterId == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(
            ref
                .read(novelReadingProgressProvider(novelId).notifier)
                .setChapterId(preferredId),
          );
        });
      }
      return null;
    }, [readableChapters.length, progress]);

    final selectedChapterId =
        currentChapterId.value ??
        (readableChapters.isEmpty ? null : readableChapters.first.id);
    final selectedChapterSummary = selectedChapterId == null
        ? null
        : readableChapters
              .where((chapter) => chapter.id == selectedChapterId)
              .firstOrNull;
    final currentChapterAsync = selectedChapterId == null
        ? null
        : ref.watch(
            chapterContentByIdProvider(
              path: databasePath,
              chapterId: selectedChapterId,
            ),
          );
    final currentChapter = currentChapterAsync?.value;
    final narrationChapter =
        supportsDesktopNarration &&
            selectedChapterSummary != null &&
            currentChapter?.id == selectedChapterId
        ? currentChapter
        : null;
    // 当前章节序号
    final currentIndex = selectedChapterId == null
        ? -1
        : readableChapters.indexWhere(
            (chapter) => chapter.id == selectedChapterId,
          );
    final nextChapterId =
        currentIndex >= 0 && currentIndex < readableChapters.length - 1
        ? readableChapters[currentIndex + 1].id
        : null;
    if (readingMode == DesktopReadingMode.chapter && nextChapterId != null) {
      // 仅预取下一章的数据，不在当前页面构建隐藏正文，避免连续阅读卡顿。
      ref.watch(
        chapterContentByIdProvider(
          path: databasePath,
          chapterId: nextChapterId,
        ),
      );
    }

    // 滚动偏移持久化（debounce 500ms）
    void handleScrollOffset(double offset) {
      lastContinuousProgress.value = null;
      debounceTimer.value?.cancel();
      debounceTimer.value = Timer(const Duration(milliseconds: 500), () {
        if ((lastSavedOffset.value ?? -1) == offset) {
          return;
        }
        lastSavedOffset.value = offset;
        ref
            .read(novelReadingProgressProvider(novelId).notifier)
            .setScrollOffset(offset);
      });
    }

    void handleContinuousProgress(String chapterId, double offset) {
      if (currentChapterId.value != chapterId) {
        currentChapterId.value = chapterId;
      }
      final previous = lastContinuousProgress.value;
      if (previous != null &&
          previous.chapterId == chapterId &&
          (previous.scrollOffset - offset).abs() < 1) {
        return;
      }
      lastSavedOffset.value = null;
      lastContinuousProgress.value = (
        chapterId: chapterId,
        scrollOffset: offset,
      );
      debounceTimer.value?.cancel();
      debounceTimer.value = Timer(const Duration(milliseconds: 500), () {
        final pending = lastContinuousProgress.value;
        if (pending == null) {
          return;
        }
        unawaited(
          ref
              .read(novelReadingProgressProvider(novelId).notifier)
              .setChapterProgress(
                chapterId: pending.chapterId,
                scrollOffset: pending.scrollOffset,
              ),
        );
      });
    }

    // 切换章节
    Future<void> selectChapter(String chapterId) async {
      // 取消待写的上一章滚动偏移，防止 debounce 回调把旧偏移写入新章节。
      debounceTimer.value?.cancel();
      lastSavedOffset.value = null;
      lastContinuousProgress.value = null;
      if (readingMode == DesktopReadingMode.chapter &&
          scrollController.hasClients) {
        scrollController.jumpTo(0);
      }
      if (readingMode == DesktopReadingMode.continuous_scroll) {
        continuousAnchorChapterId.value = chapterId;
      }
      currentChapterId.value = chapterId;
      await ref
          .read(novelReadingProgressProvider(novelId).notifier)
          .setChapterId(chapterId);
    }

    void updateContinuousChapter(String chapterId) {
      if (currentChapterId.value == chapterId) {
        return;
      }
      debounceTimer.value?.cancel();
      lastSavedOffset.value = null;
      lastContinuousProgress.value = null;
      currentChapterId.value = chapterId;
    }

    Future<void> goPrevious() async {
      if (currentIndex <= 0) return;
      await selectChapter(readableChapters[currentIndex - 1].id);
    }

    Future<void> goNext() async {
      if (currentIndex < 0 || currentIndex >= readableChapters.length - 1) {
        return;
      }
      await selectChapter(readableChapters[currentIndex + 1].id);
    }

    // 目录抽屉
    final scaffoldKey = useMemoized(() => GlobalKey<ScaffoldState>(), []);
    final topBarKey = useMemoized(() => GlobalKey(), []);
    // 原生标题栏在内容区之外，子窗口里工具栏直接贴顶。
    final topBarTop = detachedWindow ? 0.0 : DesktopWindowFrame.titleBarHeight;

    // 连续流中的 offset 是当前章节内部坐标；单章模式同样复用该字段。
    final initialOffset = progress?.chapterId == selectedChapterId
        ? progress?.scrollOffset ?? 0.0
        : 0.0;
    final continuousAnchorIndex = readableChapters.indexWhere(
      (chapter) =>
          chapter.id == (continuousAnchorChapterId.value ?? selectedChapterId),
    );

    return Scaffold(
      key: scaffoldKey,
      backgroundColor: palette.background,
      endDrawer: _ReadingTocDrawer(
        chapters: readableChapters,
        currentChapterId: selectedChapterId,
        palette: palette,
        onSelected: (chapterId) {
          selectChapter(chapterId);
          Navigator.of(context).pop();
        },
      ),
      body: DesktopWindowFrame(
        showCustomTitleBar: !detachedWindow,
        titleBarGestureExclusionKeys: [topBarKey],
        child: Stack(
          children: [
            // 正文
            if (isChapterTreeLoading)
              Center(child: CircularProgressIndicator(color: palette.iconColor))
            else if (hasChapterTreeError)
              _ReadingEmptyState(
                palette: palette,
                typo: typo,
                message: context.t(LocaleKeys.commonLoadFailed),
                description: '',
              )
            else if (readableChapters.isEmpty)
              _ReadingEmptyState(
                palette: palette,
                typo: typo,
                message: context.t(LocaleKeys.readingNoChapters),
                description: context.t(LocaleKeys.readingNoChaptersDescription),
              )
            else if (readingMode != DesktopReadingMode.continuous_scroll &&
                currentChapter == null)
              if (currentChapterAsync?.isLoading ?? false)
                Center(
                  child: CircularProgressIndicator(color: palette.iconColor),
                )
              else
                _ReadingEmptyState(
                  palette: palette,
                  typo: typo,
                  message: context.t(LocaleKeys.readingNoContent),
                  description: '',
                )
            else
              Padding(
                padding: EdgeInsets.only(
                  top: topBarTop + _readingToolbarHeight,
                  bottom: readingMode == DesktopReadingMode.chapter
                      ? _readingToolbarHeight
                      : 0,
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: _desktopReadingMaxWidth,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child:
                            readingMode == DesktopReadingMode.continuous_scroll
                            ? ReadingContinuousChapterStream(
                                key: ValueKey(
                                  'continuous-${continuousAnchorChapterId.value ?? selectedChapterId}',
                                ),
                                databasePath: databasePath,
                                chapters: readableChapters,
                                initialChapterIndex: continuousAnchorIndex,
                                palette: palette,
                                fontFamily: fontFamily,
                                fontSize: fontSize,
                                letterSpacing: letterSpacing,
                                lineHeight: lineHeight,
                                paragraphSpacing: paragraphSpacing,
                                horizontalMargin: margin,
                                bold: bold,
                                onActiveChapterChanged: (chapterId) {
                                  updateContinuousChapter(chapterId);
                                },
                                onChapterProgressChanged:
                                    handleContinuousProgress,
                                initialScrollOffset: initialOffset,
                              )
                            : ReadingContentView(
                                key: ValueKey(
                                  '$selectedChapterId-${readingMode.name}',
                                ),
                                // 章号只在章节树条目上；正文详情直查原表不带章号。
                                chapterTitle: readingChapterTitle(
                                  context,
                                  selectedChapterSummary ?? currentChapter!,
                                ),
                                chapterBody: formatText(
                                  currentChapter!.content,
                                ),
                                palette: palette,
                                fontFamily: fontFamily,
                                fontSize: fontSize,
                                letterSpacing: letterSpacing,
                                lineHeight: lineHeight,
                                paragraphSpacing: paragraphSpacing,
                                horizontalMargin: margin,
                                bold: bold,
                                mode: ReadingContentMode.scroll,
                                scrollController: scrollController,
                                onScrollOffsetChanged: handleScrollOffset,
                                initialScrollOffset: initialOffset,
                                showScrollbar: false,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            // 顶部工具栏（避开 DesktopWindowFrame 的标题栏区域）
            Positioned(
              top: topBarTop,
              left: 0,
              right: 0,
              child: _ReadingTopBar(
                key: topBarKey,
                novelTitle: novelTitle,
                chapterTitle: switch (selectedChapterSummary ??
                    currentChapter) {
                  final chapter? => readingChapterTitle(context, chapter),
                  null => '',
                },
                palette: palette,
                typo: typo,
                onBack: detachedWindow
                    ? null
                    : () => Navigator.of(context).pop(),
                pinned: pinned,
                onPinnedChanged: onPinnedChanged,
                actions: (
                  tableOfContents: () =>
                      scaffoldKey.currentState?.openEndDrawer(),
                  settings: () => _openSettingsDialog(context),
                  narrate:
                      narrationChapter == null ||
                          narrationChapter.content.trim().isEmpty
                      ? null
                      : () {
                          if ((currentChapterId.value ?? selectedChapterId) ==
                              narrationChapter.id) {
                            showNovelNarration(
                              context,
                              workId: novelId,
                              databasePath: databasePath,
                              text: narrationChapter.content,
                            );
                          }
                        },
                ),
              ),
            ),
            // 底部章节切换栏
            if (readingMode == DesktopReadingMode.chapter &&
                readableChapters.isNotEmpty &&
                currentChapter != null)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _ReadingBottomBar(
                  palette: palette,
                  typo: typo,
                  currentIndex: currentIndex,
                  totalCount: readableChapters.length,
                  hasPrevious: currentIndex > 0,
                  hasNext:
                      currentIndex >= 0 &&
                      currentIndex < readableChapters.length - 1,
                  onPrevious: goPrevious,
                  onNext: goNext,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _openSettingsDialog(BuildContext context) {
    final container = ProviderScope.containerOf(context, listen: false);
    showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (_) => UncontrolledProviderScope(
        container: container,
        child: const _ReadingSettingsDialog(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 顶部工具栏
// ---------------------------------------------------------------------------

class _ReadingTopBar extends StatelessWidget {
  const _ReadingTopBar({
    super.key,
    required this.novelTitle,
    required this.chapterTitle,
    required this.palette,
    required this.typo,
    required this.onBack,
    required this.pinned,
    required this.onPinnedChanged,
    required this.actions,
  });

  final String novelTitle;
  final String chapterTitle;
  final ReadingPalette palette;
  final RevericTypography typo;
  final VoidCallback? onBack;
  final bool pinned;
  final ValueChanged<bool>? onPinnedChanged;
  final ({
    VoidCallback tableOfContents,
    VoidCallback settings,
    VoidCallback? narrate,
  })
  actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _readingToolbarHeight,
      decoration: BoxDecoration(
        color: palette.background.withValues(alpha: 0.96),
        border: Border(bottom: BorderSide(color: palette.divider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x4l),
      child: Row(
        children: [
          if (onBack case final onBack?) ...[
            _IconButton(
              icon: RevericIcons.arrow_back,
              color: palette.iconColor,
              tooltip: context.t(LocaleKeys.readingExit),
              onPressed: onBack,
            ),
            const SizedBox(width: RevericSpacing.x2l),
          ],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  novelTitle,
                  style: typo.uiSmall.copyWith(color: palette.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (chapterTitle.isNotEmpty)
                  Text(
                    chapterTitle,
                    style: typo.uiSemibold.copyWith(color: palette.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (onPinnedChanged case final onPinnedChanged?) ...[
            _IconButton(
              icon: pinned ? RevericIcons.push_pin_fill : RevericIcons.push_pin,
              color: palette.iconColor,
              tooltip: context.t(
                pinned
                    ? LocaleKeys.readingUnpinWindow
                    : LocaleKeys.readingPinWindow,
              ),
              onPressed: () => onPinnedChanged(!pinned),
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
          if (supportsDesktopNarration) ...[
            IconButtonTheme(
              data: IconButtonThemeData(
                style: IconButton.styleFrom(
                  foregroundColor: palette.iconColor,
                  disabledForegroundColor: palette.textSecondary,
                ).merge(IconButtonTheme.of(context).style),
              ),
              child: RevericIconButton(
                icon: RevericIcons.play_arrow,
                tooltip: context.t(LocaleKeys.narrationTitle),
                onPressed: actions.narrate,
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
          _IconButton(
            icon: RevericIcons.format_list_bulleted,
            color: palette.iconColor,
            tooltip: context.t(LocaleKeys.readingTableOfContents),
            onPressed: actions.tableOfContents,
          ),
          const SizedBox(width: RevericSpacing.sm),
          _IconButton(
            icon: RevericIcons.settings_outlined,
            color: palette.iconColor,
            tooltip: context.t(LocaleKeys.readingSettingsTitle),
            onPressed: actions.settings,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 底部章节切换栏
// ---------------------------------------------------------------------------

class _ReadingBottomBar extends StatelessWidget {
  const _ReadingBottomBar({
    required this.palette,
    required this.typo,
    required this.currentIndex,
    required this.totalCount,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onNext,
  });

  final ReadingPalette palette;
  final RevericTypography typo;
  final int currentIndex;
  final int totalCount;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _readingToolbarHeight,
      decoration: BoxDecoration(
        color: palette.background.withValues(alpha: 0.96),
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x4l),
      child: Row(
        children: [
          Expanded(
            child: _ChapterNavButton(
              icon: RevericIcons.chevron_left,
              label: context.t(LocaleKeys.readingPreviousChapter),
              enabled: hasPrevious,
              palette: palette,
              typo: typo,
              onTap: onPrevious,
              alignStart: true,
            ),
          ),
          Center(
            child: Text(
              context.t(
                LocaleKeys.readingChapterProgress,
                namedArgs: {
                  'current': '${currentIndex + 1}',
                  'total': '$totalCount',
                },
              ),
              style: typo.uiSmall.copyWith(color: palette.textSecondary),
            ),
          ),
          Expanded(
            child: _ChapterNavButton(
              icon: RevericIcons.chevron_right,
              label: context.t(LocaleKeys.readingNextChapter),
              enabled: hasNext,
              palette: palette,
              typo: typo,
              onTap: onNext,
              alignStart: false,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChapterNavButton extends StatelessWidget {
  const _ChapterNavButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.palette,
    required this.typo,
    required this.onTap,
    required this.alignStart,
  });

  final String icon;
  final String label;
  final bool enabled;
  final ReadingPalette palette;
  final RevericTypography typo;
  final VoidCallback onTap;
  final bool alignStart;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? palette.textPrimary : palette.textSecondary;
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.sm,
          ),
          child: Row(
            mainAxisAlignment: alignStart
                ? MainAxisAlignment.start
                : MainAxisAlignment.end,
            children: alignStart
                ? [
                    RevericIcon(icon, size: 18, color: color),
                    const SizedBox(width: RevericSpacing.xs),
                    Text(label, style: typo.uiSmall.copyWith(color: color)),
                  ]
                : [
                    Text(label, style: typo.uiSmall.copyWith(color: color)),
                    const SizedBox(width: RevericSpacing.xs),
                    RevericIcon(icon, size: 18, color: color),
                  ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 目录抽屉
// ---------------------------------------------------------------------------

class _ReadingTocDrawer extends StatefulWidget {
  const _ReadingTocDrawer({
    required this.chapters,
    required this.currentChapterId,
    required this.palette,
    required this.onSelected,
  });

  final List<Chapter> chapters;
  final String? currentChapterId;
  final ReadingPalette palette;
  final ValueChanged<String> onSelected;

  @override
  State<_ReadingTocDrawer> createState() => _ReadingTocDrawerState();
}

class _ReadingTocDrawerState extends State<_ReadingTocDrawer> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: _selectedScrollOffset(
        widget.chapters,
        widget.currentChapterId,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant _ReadingTocDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentChapterId != widget.currentChapterId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(
            _selectedScrollOffset(widget.chapters, widget.currentChapterId),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typo = RevericTheme.typographyOf(context);
    return Container(
      width: 320,
      color: widget.palette.background,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(RevericSpacing.x4l),
              child: Text(
                context.t(LocaleKeys.readingTableOfContents),
                style: typo.heading2.copyWith(
                  color: widget.palette.chapterTitle,
                ),
              ),
            ),
            Divider(height: 1, color: widget.palette.divider),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: EdgeInsets.zero,
                itemExtent: _readingTocItemExtent,
                itemCount: widget.chapters.length,
                itemBuilder: (context, index) {
                  final chapter = widget.chapters[index];
                  final isSelected = chapter.id == widget.currentChapterId;
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => widget.onSelected(chapter.id),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: RevericSpacing.x4l,
                          vertical: RevericSpacing.x2l,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              width: 3,
                              color: isSelected
                                  ? widget.palette.chapterTitle
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                        child: Text(
                          readingChapterTitle(context, chapter),
                          style: (isSelected ? typo.uiSemibold : typo.ui)
                              .copyWith(
                                color: isSelected
                                    ? widget.palette.chapterTitle
                                    : widget.palette.textPrimary,
                              ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

double _selectedScrollOffset(List<Chapter> chapters, String? chapterId) {
  final selectedIndex = chapters.indexWhere(
    (chapter) => chapter.id == chapterId,
  );
  return selectedIndex > 2 ? (selectedIndex - 2) * _readingTocItemExtent : 0;
}

// ---------------------------------------------------------------------------
// 空状态
// ---------------------------------------------------------------------------

class _ReadingEmptyState extends StatelessWidget {
  const _ReadingEmptyState({
    required this.palette,
    required this.typo,
    required this.message,
    required this.description,
  });

  final ReadingPalette palette;
  final RevericTypography typo;
  final String message;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.x6l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.book_open,
              size: 56,
              color: palette.textSecondary,
            ),
            const SizedBox(height: RevericSpacing.x3l),
            Text(
              message,
              style: typo.heading2.copyWith(color: palette.textPrimary),
              textAlign: TextAlign.center,
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: RevericSpacing.sm),
              Text(
                description,
                style: typo.ui.copyWith(color: palette.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 通用图标按钮
// ---------------------------------------------------------------------------

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  final String icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: RevericIcon(icon, size: 18, color: color),
      splashRadius: 20,
    );
  }
}

// ---------------------------------------------------------------------------
// 阅读设置 Dialog（inline 调整）
// ---------------------------------------------------------------------------

class _ReadingSettingsDialog extends ConsumerWidget {
  const _ReadingSettingsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final notifier = ref.read(appSettingsProvider.notifier);
    final availableHeight = MediaQuery.sizeOf(context).height;
    final dialogHeight = (availableHeight - RevericSpacing.x6l * 2)
        .clamp(0.0, 680.0)
        .toDouble();

    return Dialog(
      backgroundColor: colors.surface,
      insetPadding: const EdgeInsets.all(RevericSpacing.x6l),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
      ),
      child: SizedBox(
        width: 720,
        height: dialogHeight,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.x4l,
                RevericSpacing.x3l,
                RevericSpacing.x2l,
                RevericSpacing.x2l,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.t(LocaleKeys.readingSettingsTitle),
                      style: typo.heading2.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  IconButton(
                    tooltip: context.t(LocaleKeys.commonClose),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: RevericIcon(
                      RevericIcons.close_rounded,
                      size: 18,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.borderSubtle),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(RevericSpacing.x4l),
                child: const ReadingSettingsControls(
                  compact: false,
                  platform: ReadingSettingsPlatform.desktop,
                ),
              ),
            ),
            Divider(height: 1, color: colors.borderSubtle),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.x2l,
                  vertical: RevericSpacing.sm,
                ),
                child: ReadingSettingsResetButton(
                  onPressed: notifier.resetReadingTypography,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 生命周期监听
// ---------------------------------------------------------------------------

class _AppLifecycleObserver extends WidgetsBindingObserver {
  _AppLifecycleObserver({required this.onPaused});

  final VoidCallback onPaused;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      onPaused();
    }
  }
}
