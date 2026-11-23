// 职责: 浏览画布画廊，顶部 hero 突出置顶或最新画布，其余按服务端顺序展示分页卡片网格并进入只读画布详情。
// 关联文件:
//   lib/desktop/features/canvas_gallery/detail.dart
//   lib/desktop/features/canvas_gallery/gallery_frame.dart
//   lib/shared/providers/canvas_gallery_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
//   .agents/rules/icons.md
//   .agents/rules/performance.md

import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/components/reveric_placeholder.dart';
import '../../../shared/components/reveric_surfaces.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/canvas_gallery_providers.dart';
import '../../../shared/services/canvas_gallery/service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/app_background.dart';
import '../canvas/widgets/glass.dart';
import 'detail.dart';
import 'gallery_frame.dart';

/// 封面统一按 16:10 展示；画布预览图本身接近这个比例，裁切最少。
const _coverAspect = 16 / 10;
const _gridGap = RevericSpacing.x2l;

/// 封面四周留出的内边距；内圆角 = 卡片圆角 − 内边距，保持同心。
const _coverInset = RevericSpacing.xs;
const _coverRadius = RevericRadius.x2l;

class CanvasGalleryPage extends HookConsumerWidget {
  const CanvasGalleryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final service = ref.watch(canvasGalleryServiceProvider);
    final items = useState<List<CanvasGalleryItem>?>(null);
    final cursor = useState<String?>(null);
    final loading = useState(true);
    final failed = useState(false);
    final current = useRef<CancelToken?>(null);
    final scroll = useScrollController();

    Future<void> load({required bool append}) async {
      if (!context.mounted) {
        return;
      }
      current.value?.cancel();
      final token = CancelToken();
      current.value = token;
      loading.value = true;
      failed.value = false;
      try {
        final page = await service.list(
          cursor: append ? cursor.value : null,
          cancel: token,
        );
        if (!context.mounted || token.isCancelled) {
          return;
        }
        final seen = <String>{};
        items.value = [
          for (final item in [if (append) ...?items.value, ...page.items])
            if (seen.add(item.id)) item,
        ];
        cursor.value = page.nextCursor;
        if (!append && scroll.hasClients) {
          scroll.jumpTo(0);
        }
      } catch (_) {
        if (context.mounted && !token.isCancelled) {
          failed.value = true;
        }
      } finally {
        if (context.mounted && !token.isCancelled) {
          loading.value = false;
        }
      }
    }

    useEffect(() {
      unawaited(Future.microtask(() => load(append: false)));
      return () => current.value?.cancel();
    }, [service]);

    Widget retry(VoidCallback onPressed) => RevericButton.secondary(
      label: context.t(LocaleKeys.commonRetry),
      onPressed: onPressed,
    );

    final visible = items.value;
    CanvasGalleryItem? featured;
    var rest = const <CanvasGalleryItem>[];
    if (visible != null && visible.isNotEmpty) {
      featured =
          visible.where((item) => item.pinned).firstOrNull ??
          visible.reduce(
            (a, b) => b.publishedAt.isAfter(a.publishedAt) ? b : a,
          );
      rest = [
        for (final item in visible)
          if (item.id != featured.id) item,
      ];
    }
    final Widget body;
    if (visible == null && loading.value) {
      body = _GalleryScroll(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: RevericSpacing.x3l)),
          const SliverToBoxAdapter(child: _GalleryHeroSkeleton()),
          const SliverToBoxAdapter(child: SizedBox(height: RevericSpacing.x6l)),
          _GallerySliverGrid(
            itemCount: 6,
            itemBuilder: (_, _) => const _GallerySkeletonCard(),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: RevericSpacing.x5l)),
        ],
      );
    } else if ((visible == null || visible.isEmpty) && failed.value) {
      body = Center(
        child: RevericPlaceholder.error(
          title: context.t(LocaleKeys.productionGalleryLoadFailed),
          action: retry(() => load(append: false)),
        ),
      );
    } else if (visible == null || visible.isEmpty) {
      body = Center(
        child: RevericPlaceholder.empty(
          icon: RevericIcons.flow_arrow,
          title: context.t(LocaleKeys.productionGalleryEmpty),
        ),
      );
    } else {
      final hero = featured!;
      void open(CanvasGalleryItem item) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CanvasGalleryDetailPage(item: item),
        ),
      );
      body = _GalleryScroll(
        controller: scroll,
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: RevericSpacing.x3l)),
          SliverToBoxAdapter(
            child: _GalleryHero(
              key: ValueKey(hero.id),
              item: hero,
              onOpen: () => open(hero),
            ),
          ),
          if (rest.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(
                  top: RevericSpacing.x6l,
                  bottom: RevericSpacing.x2l,
                ),
                child: Text(
                  context.t(LocaleKeys.productionGalleryMore),
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
              ),
            ),
            _GallerySliverGrid(
              itemCount: rest.length,
              itemBuilder: (context, index) {
                final item = rest[index];
                return _GalleryCard(
                  key: ValueKey(item.id),
                  item: item,
                  onTap: () => open(item),
                );
              },
            ),
          ],
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                0,
                RevericSpacing.x3l,
                0,
                RevericSpacing.x5l,
              ),
              child: Center(
                child: failed.value
                    ? ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: RevericSizes.placeholderMaxWidth,
                        ),
                        child: GalleryNoticeBanner(
                          message: context.t(
                            LocaleKeys.productionGalleryLoadFailed,
                          ),
                          action: RevericButton.secondary(
                            label: context.t(LocaleKeys.commonRetry),
                            size: RevericButtonSize.compact,
                            onPressed: () => load(append: cursor.value != null),
                          ),
                        ),
                      )
                    : cursor.value != null
                    ? RevericButton.secondary(
                        label: context.t(LocaleKeys.productionGalleryLoadMore),
                        loading: loading.value,
                        onPressed: () => load(append: true),
                      )
                    : loading.value
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
            ),
          ),
        ],
      );
    }

    return GalleryFrame(
      title: context.t(LocaleKeys.productionCanvasGallery),
      action: RevericIconButton(
        icon: RevericIcons.arrows_clockwise,
        tooltip: context.t(LocaleKeys.commonRefresh),
        onPressed: loading.value ? null : () => load(append: false),
      ),
      body: body,
    );
  }
}

/// 内容区宽度封顶并居中：宽窗口下卡片不贴左上角、右侧也不留一大片空白。
class _GalleryScroll extends StatelessWidget {
  const _GalleryScroll({this.controller, required this.slivers});

  final ScrollController? controller;
  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.max(
          RevericSpacing.x4l,
          (constraints.maxWidth - RevericSizes.canvasGalleryContentMaxWidth) /
              2,
        );
        return CustomScrollView(
          controller: controller,
          slivers: [
            for (final sliver in slivers)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: side),
                sliver: sliver,
              ),
          ],
        );
      },
    );
  }
}

/// hero 与骨架共用的版式：左边大封面约占一半宽度，右边信息栏与封面等高。
class _HeroLayout extends StatelessWidget {
  const _HeroLayout({required this.cover, required this.info});

  final Widget cover;
  final Widget info;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final coverWidth = (constraints.maxWidth * 0.48).clamp(
            RevericSizes.canvasGalleryHeroCoverMinWidth,
            RevericSizes.canvasGalleryHeroCoverMaxWidth,
          );
          return SizedBox(
            height: coverWidth / _coverAspect,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: coverWidth,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(RevericRadius.x2l),
                    child: cover,
                  ),
                ),
                const SizedBox(width: RevericSpacing.x4l),
                Expanded(child: info),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 画廊第一屏的主角：置顶或最新发布的一张画布，参照书架「继续」区放大展示。
class _GalleryHero extends HookConsumerWidget {
  const _GalleryHero({super.key, required this.item, required this.onOpen});

  final CanvasGalleryItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final active = ref.watch(appBackgroundActiveProvider);
    final hovered = useState(false);
    final radius = BorderRadius.circular(RevericRadius.card);
    final meta = typo.uiSmall.copyWith(
      color: colors.textMuted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => hovered.value = true,
      onExit: (_) => hovered.value = false,
      child: AnimatedContainer(
        duration: CanvasMotion.hover,
        curve: CanvasMotion.curve,
        decoration: BoxDecoration(
          color: appElevatedBackgroundColor(colors, active, colors.surface),
          borderRadius: radius,
          border: Border.all(
            color: hovered.value
                ? colors.accent.withValues(alpha: 0.35)
                : revericCardBorder(colors),
          ),
          boxShadow: revericCardShadows(colors),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Material(
            type: MaterialType.transparency,
            child: Semantics(
              label: item.title,
              button: true,
              child: InkWell(
                onTap: onOpen,
                hoverColor: colors.hover.withValues(alpha: 0.18),
                child: _HeroLayout(
                  cover: AnimatedScale(
                    scale: hovered.value ? 1.02 : 1.0,
                    duration: CanvasMotion.hover,
                    curve: CanvasMotion.curve,
                    child: GalleryCover(uri: item.cover),
                  ),
                  info: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (item.pinned)
                        _PinnedPill(
                          label: context.t(LocaleKeys.productionGalleryPinned),
                        )
                      else
                        Text(
                          context.t(LocaleKeys.productionGalleryLatest),
                          style: typo.uiTinySemibold.copyWith(
                            color: colors.accent,
                          ),
                        ),
                      const SizedBox(height: RevericSpacing.md),
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: typo.heading2.copyWith(
                          color: colors.textPrimary,
                          fontSize: 26,
                        ),
                      ),
                      if (item.description.isNotEmpty) ...[
                        const SizedBox(height: RevericSpacing.lg),
                        Flexible(
                          child: Text(
                            item.description,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: typo.bodySmall.copyWith(
                              color: colors.textSecondary,
                              height: 1.7,
                            ),
                          ),
                        ),
                      ],
                      const Spacer(),
                      const SizedBox(height: RevericSpacing.x2l),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              [
                                if (item.conversationCount > 0)
                                  context.t(
                                    LocaleKeys
                                        .productionGalleryConversationCount,
                                    namedArgs: {
                                      'count': '${item.conversationCount}',
                                    },
                                  ),
                                gallerySize(context, item.size),
                                galleryDate(context, item.publishedAt),
                              ].join('  ·  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: meta,
                            ),
                          ),
                          const SizedBox(width: RevericSpacing.sm),
                          RevericButton.primary(
                            label: context.t(LocaleKeys.commonOpen),
                            icon: RevericIcons.flow_arrow,
                            size: RevericButtonSize.prominent,
                            onPressed: onOpen,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GalleryHeroSkeleton extends StatelessWidget {
  const _GalleryHeroSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return RevericElevatedCard(
      fallback: colors.surface,
      clipBehavior: Clip.antiAlias,
      child: _HeroLayout(
        cover: ColoredBox(color: colors.surfaceDim),
        info: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SkeletonBar(width: 56, height: 11, color: colors.surfaceDim),
            const SizedBox(height: RevericSpacing.md),
            _SkeletonBar(width: 240, height: 26, color: colors.surfaceDim),
            const SizedBox(height: RevericSpacing.lg),
            _SkeletonBar(width: 320, height: 12, color: colors.surfaceDim),
            const SizedBox(height: RevericSpacing.sm),
            _SkeletonBar(width: 260, height: 12, color: colors.surfaceDim),
            const Spacer(),
            Row(
              children: [
                _SkeletonBar(width: 160, height: 11, color: colors.surfaceDim),
                const Spacer(),
                _SkeletonBar(width: 96, height: 40, color: colors.surfaceDim),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 列数沿用 max-extent 规则；行高按实际卡宽算出封面高度再加固定信息区，
/// 封面始终保持 16:10，不随窗口宽度被压扁或拉长。
class _GallerySliverGrid extends StatelessWidget {
  const _GallerySliverGrid({
    required this.itemCount,
    required this.itemBuilder,
  });

  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        final columns = math.max(
          1,
          (width / (RevericSizes.canvasGalleryCardMaxWidth + _gridGap)).ceil(),
        );
        final tileWidth = (width - _gridGap * (columns - 1)) / columns;
        final coverHeight = (tileWidth - _coverInset * 2) / _coverAspect;
        return SliverGrid.builder(
          itemCount: itemCount,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: _gridGap,
            mainAxisSpacing: _gridGap,
            mainAxisExtent:
                _coverInset +
                coverHeight +
                RevericSizes.canvasGalleryCardInfoHeight,
          ),
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}

class _GalleryCard extends HookConsumerWidget {
  const _GalleryCard({super.key, required this.item, required this.onTap});

  final CanvasGalleryItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final active = ref.watch(appBackgroundActiveProvider);
    final hovered = useState(false);
    final radius = BorderRadius.circular(RevericRadius.card);
    final fill = appElevatedBackgroundColor(colors, active, colors.surface);
    final border = hovered.value
        ? colors.accent.withValues(alpha: 0.35)
        : revericCardBorder(colors);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => hovered.value = true,
      onExit: (_) => hovered.value = false,
      child: AnimatedContainer(
        duration: CanvasMotion.hover,
        curve: CanvasMotion.curve,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: radius,
          border: Border.all(color: border),
          boxShadow: revericCardShadows(colors),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Material(
            type: MaterialType.transparency,
            child: Semantics(
              label: item.title,
              button: true,
              child: InkWell(
                onTap: onTap,
                hoverColor: colors.hover.withValues(alpha: 0.28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        _coverInset,
                        _coverInset,
                        _coverInset,
                        0,
                      ),
                      child: AspectRatio(
                        aspectRatio: _coverAspect,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(_coverRadius),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              AnimatedScale(
                                scale: hovered.value ? 1.03 : 1.0,
                                duration: CanvasMotion.hover,
                                curve: CanvasMotion.curve,
                                child: GalleryCover(uri: item.cover),
                              ),
                              if (item.pinned)
                                PositionedDirectional(
                                  top: RevericSpacing.sm,
                                  start: RevericSpacing.sm,
                                  child: _PinnedPill(
                                    label: context.t(
                                      LocaleKeys.productionGalleryPinned,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          RevericSpacing.lg,
                          RevericSpacing.md,
                          RevericSpacing.lg,
                          RevericSpacing.lg,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              style: typo.uiSemibold.copyWith(
                                color: colors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (item.description.isNotEmpty) ...[
                              const SizedBox(height: RevericSpacing.xxs),
                              Text(
                                item.description,
                                style: typo.uiSmall.copyWith(
                                  color: colors.textMuted,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            const Spacer(),
                            _GalleryCardMeta(item: item),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GalleryCardMeta extends StatelessWidget {
  const _GalleryCardMeta({required this.item});

  final CanvasGalleryItem item;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final style = typo.uiTiny.copyWith(
      color: colors.textSubtle,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // 对话数和大小合成一段文字整体省略，窄卡片里日期始终完整显示。
    return Row(
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                if (item.conversationCount > 0) ...[
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        end: RevericSpacing.xxs,
                      ),
                      child: RevericIcon(
                        RevericIcons.chat_bubble_outline,
                        size: 12,
                        color: colors.textSubtle,
                      ),
                    ),
                  ),
                  TextSpan(
                    text: context.t(
                      LocaleKeys.productionGalleryConversationCount,
                      namedArgs: {'count': '${item.conversationCount}'},
                    ),
                  ),
                  const TextSpan(text: '  ·  '),
                ],
                TextSpan(text: gallerySize(context, item.size)),
              ],
            ),
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: RevericSpacing.sm),
        Text(galleryDate(context, item.publishedAt), style: style),
      ],
    );
  }
}

class _PinnedPill extends StatelessWidget {
  const _PinnedPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(RevericRadius.capsule),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.sm,
          vertical: RevericSpacing.xxs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(
              RevericIcons.push_pin_fill,
              size: 11,
              color: colors.onAccent,
            ),
            const SizedBox(width: RevericSpacing.xxs),
            Text(
              label,
              style: typo.uiTinySemibold.copyWith(color: colors.onAccent),
            ),
          ],
        ),
      ),
    );
  }
}

class _GallerySkeletonCard extends StatelessWidget {
  const _GallerySkeletonCard();

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return RevericElevatedCard(
      fallback: colors.surface,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              _coverInset,
              _coverInset,
              _coverInset,
              0,
            ),
            child: AspectRatio(
              aspectRatio: _coverAspect,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceDim,
                  borderRadius: BorderRadius.circular(_coverRadius),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.lg,
                RevericSpacing.md,
                RevericSpacing.lg,
                RevericSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SkeletonBar(
                    width: 148,
                    height: 14,
                    color: colors.surfaceDim,
                  ),
                  const SizedBox(height: RevericSpacing.sm),
                  _SkeletonBar(
                    width: 200,
                    height: 11,
                    color: colors.surfaceDim,
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      _SkeletonBar(
                        width: 68,
                        height: 10,
                        color: colors.surfaceDim,
                      ),
                      const Spacer(),
                      _SkeletonBar(
                        width: 56,
                        height: 10,
                        color: colors.surfaceDim,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({
    required this.width,
    required this.height,
    required this.color,
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(RevericRadius.small),
    ),
  );
}
