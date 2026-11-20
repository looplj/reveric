// 职责: 移动端章节分区列表 — 按卷分组展示章节卡片（可折叠卷）、章号 + 标题 + 字数 + 状态、点击 push 章节编辑页、左滑删除、卷头卷内建章/重命名/删除、浮动跳到开头/末尾，空状态引导新建。
// 关联文件:
//   lib/mobile/pages/chapter_editor_page.dart
//   lib/mobile/pages/novel_editor_page.dart
//   lib/mobile/widgets/delete_confirm.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/models/chapter.dart
//   lib/shared/models/novel.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/chapter.dart';
import '../../shared/models/novel.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/utils/chapter_tree_layout.dart';
import 'delete_confirm.dart';
import 'section_scaffold.dart';
import 'sheet.dart';
import '../../shared/components/reveric_icon_button.dart';

class MobileChaptersPanel extends HookConsumerWidget {
  const MobileChaptersPanel({
    super.key,
    required this.novel,
    required this.databasePath,
    required this.onOpenChapter,
    required this.onCreate,
    required this.onCreateVolume,
    required this.onCreateChapterInVolume,
    required this.onRenameVolume,
    required this.onDeleteVolume,
  });

  final Novel novel;
  final String databasePath;

  /// 点击章节卡片打开编辑页；由 page 层统一 push，panel 不直接导航。
  final ValueChanged<String> onOpenChapter;

  /// 新建章节入口（根级）；空状态引导按钮与标题栏新建共用。
  final VoidCallback onCreate;

  /// 新建卷入口；由标题栏新建菜单触发，page 层负责弹窗与建卷。
  final VoidCallback onCreateVolume;

  /// 在指定卷内新建章节；由卷头 + 按钮触发，参数为卷 id。
  final ValueChanged<String> onCreateChapterInVolume;

  /// 重命名卷；由卷头菜单触发，page 层负责弹窗与改名。
  final ValueChanged<String> onRenameVolume;

  /// 删除卷（级联删除卷下章节）；由卷头菜单触发，page 层负责确认。
  final ValueChanged<String> onDeleteVolume;

  Future<void> _deleteChapter(
    BuildContext context,
    WidgetRef ref,
    Chapter chapter,
  ) async {
    final confirmed = await showMobileDeleteConfirm(
      context,
      title: chapter.displayTitle,
    );
    if (!confirmed) {
      return;
    }
    final service = ref.read(
      workContentServiceProvider((path: databasePath, novelId: novel.id)),
    );
    await service.deleteChapter(chapter.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chaptersAsync = ref.watch(chapterTreeProvider(databasePath));
    // 最近所写章节：列表中以 accentWarm 高亮其章号，对齐设计稿的「当前」标记。
    final lastWrittenId = ref
        .watch(lastWrittenChapterProvider(databasePath))
        .asData
        ?.value
        ?.id;

    final chapters = chaptersAsync.asData?.value;

    final scrollController = useScrollController();
    // 与桌面 chapter_tree 一致：Set 内为已展开的卷 id，默认全部折叠。
    final expandedVolumeIds = useState<Set<String>>(const {});
    // 跳转按钮可见性走 ValueNotifier + AnimatedBuilder，避免滚动时每帧 rebuild 整棵 ListView。
    final showJumpToStart = useValueNotifier(false);
    final showJumpToEnd = useValueNotifier(false);
    final isJumpAnimating = useRef(false);
    useEffect(() {
      void syncJumpButtons() {
        if (!scrollController.hasClients) {
          return;
        }
        final pos = scrollController.position;
        final max = pos.maxScrollExtent;
        final nextStart = pos.pixels > 48;
        final nextEnd = max > 0 && pos.pixels < max - 48;
        if (showJumpToStart.value != nextStart) {
          showJumpToStart.value = nextStart;
        }
        if (showJumpToEnd.value != nextEnd) {
          showJumpToEnd.value = nextEnd;
        }
      }

      void onScroll() {
        if (isJumpAnimating.value) {
          return;
        }
        syncJumpButtons();
      }

      scrollController.addListener(onScroll);
      WidgetsBinding.instance.addPostFrameCallback((_) => syncJumpButtons());
      return () => scrollController.removeListener(onScroll);
    }, [chapters]);

    void toggleVolumeExpanded(String volumeId) {
      final next = Set<String>.from(expandedVolumeIds.value);
      if (next.contains(volumeId)) {
        next.remove(volumeId);
      } else {
        next.add(volumeId);
      }
      expandedVolumeIds.value = next;
    }

    void handleCreateChapterInVolume(String volumeId) {
      if (!expandedVolumeIds.value.contains(volumeId)) {
        expandedVolumeIds.value = {...expandedVolumeIds.value, volumeId};
      }
      onCreateChapterInVolume(volumeId);
    }

    final flatItems = useMemoized(
      () => chapters == null
          ? const <_ChapterListItem>[]
          : _buildFlatChapterList(chapters, expandedVolumeIds.value),
      [chapters, expandedVolumeIds.value],
    );

    Future<void> jumpToListEdge({required bool toEnd}) async {
      if (!scrollController.hasClients) {
        return;
      }
      final position = scrollController.position;
      final current = position.pixels;
      final max = position.maxScrollExtent;
      final target = toEnd ? max : 0.0;
      final distance = (target - current).abs();
      if (distance < 1) {
        return;
      }

      if (position.isScrollingNotifier.value) {
        scrollController.jumpTo(current);
      }

      isJumpAnimating.value = true;
      try {
        final viewport = position.viewportDimension;
        // 大列表（如 1000+ 章）或长距：先 jump 到目标附近（单帧，配合 itemExtentBuilder
        // 无需逐条 layout），再仅对末段 ~1 屏做 animate，避免 Slidable 卡片逐帧构建。
        final useSnapThenAnimate =
            flatItems.length >= _largeChapterListThreshold ||
            distance > viewport * 0.9;
        if (useSnapThenAnimate) {
          final tail = viewport.clamp(280.0, 480.0);
          final snapTarget = toEnd
              ? (target - tail).clamp(0.0, max)
              : (target + tail).clamp(0.0, max);
          scrollController.jumpTo(snapTarget);
          await WidgetsBinding.instance.endOfFrame;
          if (!scrollController.hasClients) {
            return;
          }
          final remaining = (target - scrollController.offset).abs();
          if (remaining > 16) {
            await scrollController.animateTo(
              target,
              duration: Duration(milliseconds: _jumpDuration(remaining)),
              curve: Curves.easeOutCubic,
            );
          } else {
            scrollController.jumpTo(target);
          }
          return;
        }

        await scrollController.animateTo(
          target,
          duration: Duration(milliseconds: _jumpDuration(distance)),
          curve: Curves.easeOutCubic,
        );
      } finally {
        isJumpAnimating.value = false;
        if (scrollController.hasClients) {
          final pos = scrollController.position;
          final maxExtent = pos.maxScrollExtent;
          showJumpToStart.value = pos.pixels > 48;
          showJumpToEnd.value = maxExtent > 0 && pos.pixels < maxExtent - 48;
        }
      }
    }

    if (chapters == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final hasChapters = chapters.any((chapter) => !chapter.isVolume);
    if (!hasChapters) {
      return MobileSectionEmptyState(
        icon: RevericIcons.menu_book_outlined,
        sectionLabel: context.t(LocaleKeys.workspaceChapters),
        hint: context.t(LocaleKeys.workspaceChaptersHint),
        actionLabel: context.t(LocaleKeys.workspaceNewChapter),
        onCreate: onCreate,
      );
    }

    return Stack(
      children: [
        ListView.builder(
          controller: scrollController,
          padding: mobileSectionListPadding,
          addAutomaticKeepAlives: false,
          // 固定行高：1000+ 章时 maxScrollExtent 可 O(1) 算出，jumpTo 无需逐条 layout。
          itemExtentBuilder: (index, _) => _listItemExtent(flatItems[index]),
          itemCount: flatItems.length,
          itemBuilder: (context, index) {
            final item = flatItems[index];
            if (item.volume != null) {
              final volume = item.volume!;
              final isExpanded = expandedVolumeIds.value.contains(volume.id);
              return Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.xs,
                  RevericSpacing.md,
                  RevericSpacing.xs,
                  RevericSpacing.sm,
                ),
                child: _VolumeHeader(
                  volume: volume,
                  chapterCount: item.volumeChapterCount,
                  isExpanded: isExpanded,
                  onToggleExpanded: () => toggleVolumeExpanded(volume.id),
                  onCreateChapterInVolume: handleCreateChapterInVolume,
                  onRenameVolume: onRenameVolume,
                  onDeleteVolume: onDeleteVolume,
                ),
              );
            }
            final chapter = item.chapter!;
            return Padding(
              padding: const EdgeInsets.only(bottom: RevericSpacing.sm),
              child: RepaintBoundary(
                child: _ChapterListCard(
                  chapter: chapter,
                  isLastWritten: chapter.id == lastWrittenId,
                  onTap: () => onOpenChapter(chapter.id),
                  onDelete: () => _deleteChapter(context, ref, chapter),
                ),
              ),
            );
          },
        ),
        AnimatedBuilder(
          animation: Listenable.merge([showJumpToStart, showJumpToEnd]),
          builder: (context, _) {
            final showStart = showJumpToStart.value;
            final showEnd = showJumpToEnd.value;
            if (!showStart && !showEnd) {
              return const SizedBox.shrink();
            }
            return Positioned(
              bottom:
                  MediaQuery.viewPaddingOf(context).bottom + RevericSpacing.x2l,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (showStart)
                    _JumpToStartButton(
                      onTap: () => jumpToListEdge(toEnd: false),
                    ),
                  if (showEnd)
                    _JumpToEndButton(onTap: () => jumpToListEdge(toEnd: true)),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// 卷标题行（折叠箭头 + 书本图标 + 卷名 + 章数 + 卷内新建章 + 更多操作菜单）。
class _VolumeHeader extends StatelessWidget {
  const _VolumeHeader({
    required this.volume,
    required this.chapterCount,
    required this.isExpanded,
    required this.onToggleExpanded,
    required this.onCreateChapterInVolume,
    required this.onRenameVolume,
    required this.onDeleteVolume,
  });

  final Chapter volume;
  final int chapterCount;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;

  /// 在该卷内新建章节；参数为卷 id。
  final ValueChanged<String> onCreateChapterInVolume;

  /// 重命名卷；参数为卷 id。
  final ValueChanged<String> onRenameVolume;

  /// 删除卷；参数为卷 id。
  final ValueChanged<String> onDeleteVolume;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onToggleExpanded,
            borderRadius: BorderRadius.circular(RevericRadius.small),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xxs),
              child: Row(
                children: [
                  AnimatedRotation(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    turns: isExpanded ? 0.5 : 0,
                    child: RevericIcon(
                      RevericIcons.expand_more_rounded,
                      size: 16,
                      color: colors.textSubtle,
                    ),
                  ),
                  const SizedBox(width: RevericSpacing.xxs),
                  RevericIcon(
                    RevericIcons.auto_stories_outlined,
                    size: 13,
                    color: colors.textSubtle,
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  Expanded(
                    child: Text(
                      volume.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiTinySemibold.copyWith(
                        color: colors.textSubtle,
                      ),
                    ),
                  ),
                  if (!isExpanded && chapterCount > 0) ...[
                    const SizedBox(width: RevericSpacing.xs),
                    Text(
                      '$chapterCount',
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        // 卷内新建章节：小 + 按钮，点击在当前卷下追加一章（折叠时先展开卷）。
        InkWell(
          onTap: () => onCreateChapterInVolume(volume.id),
          borderRadius: BorderRadius.circular(RevericRadius.pill),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.xs,
              vertical: RevericSpacing.xxs,
            ),
            child: RevericIcon(
              RevericIcons.add,
              size: 14,
              color: colors.accentWarm,
            ),
          ),
        ),
        // 更多操作：重命名 / 删除卷。
        RevericIconButton(
          icon: RevericIcons.more_horiz,
          tooltip: context.t(LocaleKeys.commonMoreActions),
          onPressed: () async {
            final action = await showMobileSheet<_VolumeAction>(
              context: context,
              showDragHandle: true,
              builder: (sheetContext) => SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      leading: RevericIcon(
                        RevericIcons.edit,
                        color: colors.textSecondary,
                      ),
                      title: Text(context.t(LocaleKeys.workspaceRenameVolume)),
                      onTap: () =>
                          Navigator.of(sheetContext).pop(_VolumeAction.rename),
                    ),
                    ListTile(
                      leading: RevericIcon(
                        RevericIcons.delete_outline,
                        color: colors.warningText,
                      ),
                      title: Text(
                        context.t(LocaleKeys.commonDelete),
                        style: typo.ui.copyWith(color: colors.warningText),
                      ),
                      onTap: () =>
                          Navigator.of(sheetContext).pop(_VolumeAction.delete),
                    ),
                  ],
                ),
              ),
            );
            if (!context.mounted) {
              return;
            }
            switch (action) {
              case _VolumeAction.rename:
                onRenameVolume(volume.id);
              case _VolumeAction.delete:
                onDeleteVolume(volume.id);
              case null:
                break;
            }
          },
        ),
      ],
    );
  }
}

/// 卷头更多菜单的可选项。
enum _VolumeAction { rename, delete }

/// 按滚动距离计算动画时长：~0.35ms/px，250–650ms 区间（仅短距 animate 使用）。
int _jumpDuration(double distance) {
  return (distance * 0.35).round().clamp(250, 650);
}

/// 超过此章节数启用 snap + 短距 animate，避免长距 animateTo 逐帧构建。
const int _largeChapterListThreshold = 80;

/// 章节行固定高度（卡片 + 行间距），须与 itemBuilder 内边距一致。
const double _chapterListItemExtent = 88;

/// 卷头行固定高度（含上下 padding），须与 itemBuilder 内边距一致。
const double _volumeHeaderListItemExtent =
    RevericSizes.touchTargetSize + RevericSpacing.md + RevericSpacing.sm;

double _listItemExtent(_ChapterListItem item) {
  return item.volume != null
      ? _volumeHeaderListItemExtent
      : _chapterListItemExtent;
}

/// 列表左侧章号：根级散章用全书章号，卷内章节用卷内编号（对齐 desktop chapter_tree）。
int? _chapterDisplayNumber(Chapter chapter) {
  if (chapter.isExtra) {
    return null;
  }
  if (chapter.parentId == null) {
    return chapter.chapterNum;
  }
  return chapter.volumeChapterNum ?? chapter.chapterNum;
}

/// 浮动「跳到开头」按钮：圆形 surface 底 + 向上箭头图标。
class _JumpToStartButton extends StatelessWidget {
  const _JumpToStartButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Tooltip(
      message: context.t(LocaleKeys.workspaceJumpToStart),
      child: Material(
        color: colors.surfaceContainer,
        shape: CircleBorder(side: BorderSide(color: colors.border)),
        clipBehavior: Clip.antiAlias,
        elevation: 2,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(RevericSpacing.md),
            child: RevericIcon(
              RevericIcons.arrow_upward_rounded,
              size: 22,
              color: colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 浮动「跳到末尾」按钮：圆形 surface 底 + 向下箭头图标。
class _JumpToEndButton extends StatelessWidget {
  const _JumpToEndButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Tooltip(
      message: context.t(LocaleKeys.workspaceJumpToEnd),
      child: Material(
        color: colors.surfaceContainer,
        shape: CircleBorder(side: BorderSide(color: colors.border)),
        clipBehavior: Clip.antiAlias,
        elevation: 2,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(RevericSpacing.md),
            child: RevericIcon(
              RevericIcons.arrow_downward_rounded,
              size: 22,
              color: colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 章节列表卡片：章号 + 标题 + 字数/未开始 + 状态 chip（对齐 designs/mobile ChaptersBody）。
/// 左滑露出右侧删除按钮（Slidable endActionPane）。连接处对齐设计稿 SwipeRow：
/// 外层 ClipRRect 裁整行圆角；删除条实心 error 底 + 方角 + onAccent 图标/文案；
/// 卡片本体在左滑打开时把右侧两角拉直，使右缘与红色删除区严丝合缝，
/// 收起时恢复四角圆角。
class _ChapterListCard extends StatefulWidget {
  const _ChapterListCard({
    required this.chapter,
    required this.isLastWritten,
    required this.onTap,
    required this.onDelete,
  });

  final Chapter chapter;
  final bool isLastWritten;
  final VoidCallback onTap;

  /// 左滑删除按钮回调（调用方负责确认 + 删除）。
  final VoidCallback onDelete;

  @override
  State<_ChapterListCard> createState() => _ChapterListCardState();
}

class _ChapterListCardState extends State<_ChapterListCard>
    with TickerProviderStateMixin {
  /// 左滑删除区占整行宽度的比例；卡片右角拉直进度须按此归一化。
  static const double _endActionExtentRatio = 0.26;

  late final SlidableController _controller;

  @override
  void initState() {
    super.initState();
    // 在 initState 创建，才能用 State 的 TickerProviderStateMixin 作 vsync；
    // 构造期引用 this 不安全，故不用字段初始化器。
    _controller = SlidableController(this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final chapter = widget.chapter;

    // chapterTreeProvider 不加载 content，须用 wordCount 判断是否有正文。
    final hasContent = chapter.wordCount > 0;
    final displayChapterNumber = _chapterDisplayNumber(chapter);
    final subtitle = hasContent
        ? context.t(
            LocaleKeys.mobileEditorWordCount,
            namedArgs: {'count': '${chapter.wordCount}'},
          )
        : context.t(LocaleKeys.mobileChapterNotStarted);

    // 卡片随左滑进度把右侧两角拉直（对齐设计稿 SwipeRow 的 borderTopRightRadius/
    // borderBottomRightRadius 在 open 时置 0）；InkWell/Container 的圆角同步切换，
    // 让卡片右缘与实心红删除区拼成一条直边，不再出现两段圆弧。
    return ClipRRect(
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: Slidable(
        controller: _controller,
        endActionPane: ActionPane(
          motion: const BehindMotion(),
          extentRatio: _endActionExtentRatio,
          children: [
            CustomSlidableAction(
              onPressed: (_) => widget.onDelete(),
              // error 底略降透明度，透出暖色画布，缓和纯红在奶油色面板里的突兀；
              // 外层 ClipRRect 负责右侧圆角，这里用方角避免双重圆角缝隙。
              backgroundColor: colors.error.withValues(alpha: 0.88),
              borderRadius: BorderRadius.zero,
              padding: EdgeInsets.zero,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RevericIcon(
                    RevericIcons.delete_outline,
                    size: 20,
                    color: colors.onAccent,
                  ),
                  const SizedBox(height: RevericSpacing.xxs),
                  Text(
                    context.t(LocaleKeys.commonDelete),
                    style: typo.uiTiny.copyWith(color: colors.onAccent),
                  ),
                ],
              ),
            ),
          ],
        ),
        child: AnimatedBuilder(
          animation: _controller.animation,
          builder: (context, _) {
            // ratio<0 表示左滑露出 endActionPane；ratio 是「已拖动占整行宽度」的
            // 比例，全开时仅到 -extentRatio，故须除以 extentRatio 归一化到 0..1，
            // 否则全开时 open 只到 ~0.26、右角拉不直（残留圆角）。
            final open = (-_controller.ratio / _endActionExtentRatio).clamp(
              0.0,
              1.0,
            );
            final rightRadius = RevericRadius.large * (1.0 - open);
            final cardBorderRadius = BorderRadius.only(
              topLeft: Radius.circular(RevericRadius.large),
              bottomLeft: Radius.circular(RevericRadius.large),
              topRight: Radius.circular(rightRadius),
              bottomRight: Radius.circular(rightRadius),
            );
            return InkWell(
              onTap: widget.onTap,
              borderRadius: cardBorderRadius,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.xl,
                  vertical: RevericSpacing.lg,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainer,
                  borderRadius: cardBorderRadius,
                  border: Border.all(color: colors.border),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        displayChapterNumber != null
                            ? context.t(
                                LocaleKeys.commonChapterNumber,
                                namedArgs: {'number': '$displayChapterNumber'},
                              )
                            : '·',
                        textAlign: TextAlign.center,
                        style: typo.bodySmall.copyWith(
                          fontWeight: FontWeight.w700,
                          color: widget.isLastWritten
                              ? colors.accentWarm
                              : colors.textSubtle,
                        ),
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            chapter.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: typo.bodySmall.copyWith(
                              fontWeight: FontWeight.w700,
                              color: hasContent
                                  ? colors.textPrimary
                                  : colors.textSubtle,
                            ),
                          ),
                          const SizedBox(height: RevericSpacing.xxs),
                          Text(
                            subtitle,
                            style: typo.uiTiny.copyWith(
                              color: colors.textSubtle,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    _ChapterStateChip(chapter: chapter),
                    const SizedBox(width: RevericSpacing.sm),
                    RevericIcon(
                      RevericIcons.chevron_right,
                      size: 16,
                      color: colors.textSubtle,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 章节状态 chip（对齐 designs/mobile StateChip）。
class _ChapterStateChip extends StatelessWidget {
  const _ChapterStateChip({required this.chapter});

  final Chapter chapter;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final hasContent = chapter.wordCount > 0;

    late final String label;
    late final Color foreground;
    late final Color background;

    if (chapter.isPublished) {
      label = context.t(LocaleKeys.chapterStatPublished);
      foreground = colors.success;
      background = colors.success.withValues(alpha: 0.13);
    } else if (hasContent) {
      label = context.t(LocaleKeys.chapterStatDraft);
      foreground = colors.accentWarm;
      background = colors.accentWarm.withValues(alpha: 0.13);
    } else {
      label = context.t(LocaleKeys.mobileChapterNotStarted);
      foreground = colors.textSubtle;
      background = colors.textSubtle.withValues(alpha: 0.13);
    }

    return MobileSectionTagChip(
      label: label,
      foregroundColor: foreground,
      backgroundColor: background,
    );
  }
}

/// ListView.builder 的单行条目：卷头或章节卡片。
class _ChapterListItem {
  const _ChapterListItem.volume(this.volume, {required this.volumeChapterCount})
    : chapter = null;

  const _ChapterListItem.chapter(this.chapter)
    : volume = null,
      volumeChapterCount = 0;

  final Chapter? volume;
  final Chapter? chapter;
  final int volumeChapterCount;
}

List<_ChapterListItem> _buildFlatChapterList(
  List<Chapter> chapters,
  Set<String> expandedVolumeIds,
) {
  final groups = _buildChapterGroups(chapters);
  final items = <_ChapterListItem>[];
  for (final group in groups) {
    if (group.volume != null) {
      items.add(
        _ChapterListItem.volume(
          group.volume!,
          volumeChapterCount: group.items.length,
        ),
      );
      if (expandedVolumeIds.contains(group.volume!.id)) {
        for (final chapter in group.items) {
          items.add(_ChapterListItem.chapter(chapter));
        }
      }
    } else {
      for (final chapter in group.items) {
        items.add(_ChapterListItem.chapter(chapter));
      }
    }
  }
  return items;
}

/// 把扁平章节树整理成「根级散章 → 各卷」的有序分组（镜像章节目录 sheet）。
class _ChapterGroup {
  const _ChapterGroup({this.volume, required this.items});

  /// 卷节点；为 null 表示根级未分卷的散章分组。
  final Chapter? volume;
  final List<Chapter> items;
}

List<_ChapterGroup> _buildChapterGroups(List<Chapter> chapters) {
  final mount = mountChaptersForTree(chapters);
  final rootChapters = mount.roots.where((c) => c.isChapter).toList();
  final volumes = mount.roots.where((c) => c.isVolume).toList();

  final groups = <_ChapterGroup>[];
  if (rootChapters.isNotEmpty) {
    groups.add(_ChapterGroup(items: rootChapters));
  }
  for (final volume in volumes) {
    groups.add(
      _ChapterGroup(
        volume: volume,
        items: mount.childrenByVolume[volume.id] ?? const [],
      ),
    );
  }
  return groups;
}
