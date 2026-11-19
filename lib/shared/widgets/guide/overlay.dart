// 职责: 渲染跨平台分步锚点高亮引导遮罩与指向气泡，支持自动滚动、边界避让与键盘翻步。
// 关联文件:
//   lib/shared/widgets/guide/tour.dart
//   lib/shared/widgets/guide/trigger.dart
//   lib/shared/components/reveric_button.dart
//   lib/shared/theme/reveric_elevation.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/onboarding.json
//   assets/translations/zh-CN/onboarding.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/code-style.md
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../components/reveric_button.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../theme/theme.dart';
import 'tour.dart';

/// 显示一套分步锚点高亮引导；在用户完成、跳过或按 Esc 关闭后返回。
Future<void> showGuideTour(
  BuildContext context, {
  required List<GuideStep> steps,
}) async {
  if (steps.isEmpty || !context.mounted) {
    return;
  }
  final themeData = RevericTheme.of(context);
  await showGeneralDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    barrierLabel: context.t(LocaleKeys.onboardingGuideReplayTooltip),
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, _, _) => RevericTheme(
      data: themeData,
      child: _GuideTourOverlay(steps: steps),
    ),
    transitionBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: child,
    ),
  );
}

enum _BubblePlacement { below, above, right, left, center }

class _GuideTourOverlay extends HookWidget {
  const _GuideTourOverlay({required this.steps});

  final List<GuideStep> steps;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final media = MediaQuery.of(context);
    final viewport = media.size;
    final padding = media.padding;

    final stepIndex = useState(0);
    final targetRect = useState<Rect?>(null);
    final measureToken = useState(0);
    final currentStep = steps[stepIndex.value];
    final isFirst = stepIndex.value == 0;
    final isLast = stepIndex.value == steps.length - 1;

    Future<void> resolveTarget(GuideStep step, int expectedIndex) async {
      step.onBeforeEnter?.call();
      await WidgetsBinding.instance.endOfFrame;
      if (!context.mounted || stepIndex.value != expectedIndex) {
        return;
      }

      final targetContext = step.targetKey?.currentContext;
      if (targetContext != null && targetContext.mounted) {
        final scrollable = Scrollable.maybeOf(targetContext);
        if (scrollable != null) {
          try {
            await Scrollable.ensureVisible(
              targetContext,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: 0.35,
            );
          } catch (_) {
            // 目标已卸载或不在可滚视口内时直接回退测量。
          }
          if (!context.mounted || stepIndex.value != expectedIndex) {
            return;
          }
          await WidgetsBinding.instance.endOfFrame;
        }
      }

      if (!context.mounted || stepIndex.value != expectedIndex) {
        return;
      }
      targetRect.value = _measureTargetRect(step);
    }

    final resolveRef = useRef(resolveTarget);
    resolveRef.value = resolveTarget;

    useEffect(() {
      final index = stepIndex.value;
      final step = steps[index];
      unawaited(resolveRef.value(step, index));
      return null;
    }, [stepIndex.value, measureToken.value, viewport.width, viewport.height]);

    void closeTour() {
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    void goBack() {
      if (stepIndex.value > 0) {
        stepIndex.value = stepIndex.value - 1;
      }
    }

    void goNext() {
      if (stepIndex.value < steps.length - 1) {
        stepIndex.value = stepIndex.value + 1;
      } else {
        closeTour();
      }
    }

    void triggerPrimaryAction() {
      final action = currentStep.onPrimaryAction;
      closeTour();
      if (action != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          action();
        });
      }
    }

    final rect = targetRect.value;
    final inflated = rect?.inflate(currentStep.highlightPadding);
    final spotlightRect = inflated == null
        ? null
        : Rect.fromLTRB(
            math.max(4.0, inflated.left),
            math.max(4.0, inflated.top),
            math.min(viewport.width - 4.0, inflated.right),
            math.min(viewport.height - 4.0, inflated.bottom),
          );
    final cardWidth = math.min(
      viewport.width >= 600 ? 360.0 : 340.0,
      math.max(240.0, viewport.width - RevericSpacing.x4l),
    );
    const estimatedCardHeight = 228.0;
    const margin = RevericSpacing.lg;
    const gap = RevericSpacing.md;

    final layout = _computeBubbleLayout(
      viewport: viewport,
      safePadding: padding,
      spotlight: spotlightRect,
      cardWidth: cardWidth,
      estimatedCardHeight: estimatedCardHeight,
      margin: margin,
      gap: gap,
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): closeTour,
        const SingleActivator(LogicalKeyboardKey.arrowRight): goNext,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): goBack,
      },
      child: Focus(
        autofocus: true,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    // 不在点击遮罩时误关，但允许轻触重新校准目标区域。
                    measureToken.value = measureToken.value + 1;
                  },
                  child: CustomPaint(
                    painter: _SpotlightBackdropPainter(
                      spotlight: spotlightRect,
                      radius: currentStep.highlightRadius,
                      scrimColor: Colors.black.withValues(alpha: 0.48),
                      ringColor: colors.accent,
                      glowColor: colors.accent.withValues(alpha: 0.24),
                    ),
                  ),
                ),
              ),
              if (layout.placement == _BubblePlacement.center)
                Center(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      margin,
                      padding.top + margin,
                      margin,
                      padding.bottom + margin,
                    ),
                    child: _GuideCard(
                      step: currentStep,
                      stepIndex: stepIndex.value,
                      totalSteps: steps.length,
                      width: cardWidth,
                      isFirst: isFirst,
                      isLast: isLast,
                      colors: colors,
                      typo: typo,
                      onClose: closeTour,
                      onBack: goBack,
                      onNext: goNext,
                      onPrimaryAction: currentStep.onPrimaryAction != null
                          ? triggerPrimaryAction
                          : null,
                    ),
                  ),
                )
              else
                Positioned(
                  left: layout.left,
                  top: layout.top,
                  bottom: layout.bottom,
                  child: _AnchoredGuideCard(
                    placement: layout.placement,
                    arrowOffset: layout.arrowOffset,
                    cardWidth: cardWidth,
                    surfaceColor: colors.surface,
                    borderColor: revericCardBorder(colors),
                    child: _GuideCard(
                      step: currentStep,
                      stepIndex: stepIndex.value,
                      totalSteps: steps.length,
                      width: cardWidth,
                      isFirst: isFirst,
                      isLast: isLast,
                      colors: colors,
                      typo: typo,
                      onClose: closeTour,
                      onBack: goBack,
                      onNext: goNext,
                      onPrimaryAction: currentStep.onPrimaryAction != null
                          ? triggerPrimaryAction
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Rect? _measureTargetRect(GuideStep step) {
    final targetContext = step.targetKey?.currentContext;
    if (targetContext == null || !targetContext.mounted) {
      return null;
    }
    final renderObject = targetContext.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.hasSize ||
        !renderObject.attached) {
      return null;
    }
    final size = renderObject.size;
    if (size.width <= 0 || size.height <= 0) {
      return null;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    if (!topLeft.dx.isFinite || !topLeft.dy.isFinite) {
      return null;
    }
    return topLeft & size;
  }
}

class _BubbleLayout {
  const _BubbleLayout({
    required this.placement,
    this.left,
    this.top,
    this.bottom,
    this.arrowOffset = 0,
  });

  final _BubblePlacement placement;
  final double? left;
  final double? top;
  final double? bottom;

  /// 箭头沿卡片主轴相对卡片左上角的偏移。
  final double arrowOffset;
}

_BubbleLayout _computeBubbleLayout({
  required Size viewport,
  required EdgeInsets safePadding,
  required Rect? spotlight,
  required double cardWidth,
  required double estimatedCardHeight,
  required double margin,
  required double gap,
}) {
  if (spotlight == null) {
    return const _BubbleLayout(placement: _BubblePlacement.center);
  }

  final minX = safePadding.left + margin;
  final maxX = math.max(minX, viewport.width - safePadding.right - margin);
  final minY = safePadding.top + margin;
  final maxY = math.max(minY, viewport.height - safePadding.bottom - margin);

  final clamped = spotlight.intersect(Rect.fromLTRB(minX, minY, maxX, maxY));
  if (clamped.width <= 0 || clamped.height <= 0) {
    return const _BubbleLayout(placement: _BubblePlacement.center);
  }

  final spaceBelow = maxY - clamped.bottom - gap;
  final spaceAbove = clamped.top - minY - gap;
  final spaceRight = maxX - clamped.right - gap;
  final spaceLeft = clamped.left - minX - gap;

  double clampCardLeft(double targetCenterX) {
    final maxLeft = math.max(minX, maxX - cardWidth);
    return (targetCenterX - cardWidth / 2).clamp(minX, maxLeft);
  }

  double clampCardTop(double targetCenterY) {
    final maxTop = math.max(minY, maxY - estimatedCardHeight);
    return (targetCenterY - estimatedCardHeight / 2).clamp(minY, maxTop);
  }

  if (spaceRight >= cardWidth + 12 && clamped.height > 120) {
    final left = clamped.right + gap;
    final top = clampCardTop(clamped.center.dy);
    final arrowY = (clamped.center.dy - top).clamp(24.0, 120.0);
    return _BubbleLayout(
      placement: _BubblePlacement.right,
      left: left,
      top: top,
      arrowOffset: arrowY,
    );
  }

  if (spaceLeft >= cardWidth + 12 && clamped.height > 120) {
    final left = clamped.left - gap - cardWidth - _arrowDepth;
    final top = clampCardTop(clamped.center.dy);
    final arrowY = (clamped.center.dy - top).clamp(24.0, 120.0);
    return _BubbleLayout(
      placement: _BubblePlacement.left,
      left: math.max(minX, left),
      top: top,
      arrowOffset: arrowY,
    );
  }

  if (spaceBelow >= estimatedCardHeight) {
    final left = clampCardLeft(clamped.center.dx);
    final arrowX = (clamped.center.dx - left).clamp(24.0, cardWidth - 24.0);
    return _BubbleLayout(
      placement: _BubblePlacement.below,
      left: left,
      top: clamped.bottom + gap,
      arrowOffset: arrowX,
    );
  }

  if (spaceAbove >= estimatedCardHeight) {
    final left = clampCardLeft(clamped.center.dx);
    final arrowX = (clamped.center.dx - left).clamp(24.0, cardWidth - 24.0);
    return _BubbleLayout(
      placement: _BubblePlacement.above,
      left: left,
      bottom: viewport.height - clamped.top + gap,
      arrowOffset: arrowX,
    );
  }

  if (spaceRight >= cardWidth + 12) {
    final left = clamped.right + gap;
    final top = clampCardTop(clamped.center.dy);
    final arrowY = (clamped.center.dy - top).clamp(24.0, 120.0);
    return _BubbleLayout(
      placement: _BubblePlacement.right,
      left: left,
      top: top,
      arrowOffset: arrowY,
    );
  }

  if (spaceLeft >= cardWidth + 12) {
    final left = clamped.left - gap - cardWidth - _arrowDepth;
    final top = clampCardTop(clamped.center.dy);
    final arrowY = (clamped.center.dy - top).clamp(24.0, 120.0);
    return _BubbleLayout(
      placement: _BubblePlacement.left,
      left: math.max(minX, left),
      top: top,
      arrowOffset: arrowY,
    );
  }

  return const _BubbleLayout(placement: _BubblePlacement.center);
}

const double _arrowDepth = 8.0;
const double _arrowBase = 16.0;

class _AnchoredGuideCard extends StatelessWidget {
  const _AnchoredGuideCard({
    required this.placement,
    required this.arrowOffset,
    required this.cardWidth,
    required this.surfaceColor,
    required this.borderColor,
    required this.child,
  });

  final _BubblePlacement placement;
  final double arrowOffset;
  final double cardWidth;
  final Color surfaceColor;
  final Color borderColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    switch (placement) {
      case _BubblePlacement.below:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(
                left: (arrowOffset - _arrowBase / 2).clamp(
                  16.0,
                  cardWidth - 16.0 - _arrowBase,
                ),
              ),
              child: CustomPaint(
                size: const Size(_arrowBase, _arrowDepth),
                painter: _TailPainter(
                  color: surfaceColor,
                  borderColor: borderColor,
                  direction: _TailDirection.up,
                ),
              ),
            ),
            child,
          ],
        );
      case _BubblePlacement.above:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            child,
            Padding(
              padding: EdgeInsets.only(
                left: (arrowOffset - _arrowBase / 2).clamp(
                  16.0,
                  cardWidth - 16.0 - _arrowBase,
                ),
              ),
              child: CustomPaint(
                size: const Size(_arrowBase, _arrowDepth),
                painter: _TailPainter(
                  color: surfaceColor,
                  borderColor: borderColor,
                  direction: _TailDirection.down,
                ),
              ),
            ),
          ],
        );
      case _BubblePlacement.right:
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: math.max(16.0, arrowOffset - 8.0)),
              child: CustomPaint(
                size: const Size(_arrowDepth, _arrowBase),
                painter: _TailPainter(
                  color: surfaceColor,
                  borderColor: borderColor,
                  direction: _TailDirection.left,
                ),
              ),
            ),
            child,
          ],
        );
      case _BubblePlacement.left:
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            child,
            Padding(
              padding: EdgeInsets.only(top: math.max(16.0, arrowOffset - 8.0)),
              child: CustomPaint(
                size: const Size(_arrowDepth, _arrowBase),
                painter: _TailPainter(
                  color: surfaceColor,
                  borderColor: borderColor,
                  direction: _TailDirection.right,
                ),
              ),
            ),
          ],
        );
      case _BubblePlacement.center:
        return child;
    }
  }
}

class _GuideCard extends StatelessWidget {
  const _GuideCard({
    required this.step,
    required this.stepIndex,
    required this.totalSteps,
    required this.width,
    required this.isFirst,
    required this.isLast,
    required this.colors,
    required this.typo,
    required this.onClose,
    required this.onBack,
    required this.onNext,
    this.onPrimaryAction,
  });

  final GuideStep step;
  final int stepIndex;
  final int totalSteps;
  final double width;
  final bool isFirst;
  final bool isLast;
  final RevericColors colors;
  final RevericTypography typo;
  final VoidCallback onClose;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback? onPrimaryAction;

  @override
  Widget build(BuildContext context) {
    final border = revericCardBorder(colors);
    return Container(
      key: ValueKey('guide-step-${step.id}'),
      width: width,
      padding: const EdgeInsets.all(RevericSpacing.xl),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(RevericRadius.card),
        border: Border.all(
          color: border == Colors.transparent ? colors.borderSubtle : border,
        ),
        boxShadow: revericCardShadows(colors),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (step.icon != null) ...[
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: colors.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(RevericRadius.medium),
                  ),
                  child: Center(
                    child: RevericIcon(
                      step.icon!,
                      size: 15,
                      color: colors.accent,
                    ),
                  ),
                ),
                const SizedBox(width: RevericSpacing.sm),
              ],
              if (totalSteps > 1)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainer,
                    borderRadius: BorderRadius.circular(RevericRadius.pill),
                  ),
                  child: Text(
                    '${stepIndex + 1} / $totalSteps',
                    style: typo.uiTinySemibold.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ),
              const Spacer(),
              InkWell(
                key: const ValueKey('guide-close-button'),
                onTap: onClose,
                borderRadius: BorderRadius.circular(RevericRadius.small),
                child: Padding(
                  padding: const EdgeInsets.all(RevericSpacing.xs),
                  child: RevericIcon(
                    RevericIcons.close_rounded,
                    size: 16,
                    color: colors.textMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.md),
          Text(
            step.title,
            style: typo.heading2.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: RevericSpacing.sm),
          Text(
            step.description,
            style: typo.uiSmall.copyWith(
              color: colors.textSecondary,
              height: 1.55,
            ),
          ),
          if (!isLast &&
              step.primaryActionLabel != null &&
              onPrimaryAction != null) ...[
            const SizedBox(height: RevericSpacing.md),
            RevericButton.secondary(
              size: RevericButtonSize.compact,
              label: step.primaryActionLabel!,
              icon: RevericIcons.arrow_forward,
              onPressed: onPrimaryAction,
            ),
          ],
          const SizedBox(height: RevericSpacing.lg),
          Row(
            children: [
              if (!isLast)
                RevericButton.text(
                  size: RevericButtonSize.compact,
                  label: context.t(LocaleKeys.onboardingSkip),
                  onPressed: onClose,
                )
              else if (step.primaryActionLabel != null &&
                  onPrimaryAction != null)
                RevericButton.text(
                  size: RevericButtonSize.compact,
                  label: context.t(LocaleKeys.onboardingGuideDone),
                  onPressed: onClose,
                ),
              const Spacer(),
              if (!isFirst) ...[
                RevericButton.secondary(
                  size: RevericButtonSize.compact,
                  label: context.t(LocaleKeys.onboardingBack),
                  onPressed: onBack,
                ),
                const SizedBox(width: RevericSpacing.sm),
              ],
              if (isLast &&
                  step.primaryActionLabel != null &&
                  onPrimaryAction != null)
                RevericButton.primary(
                  size: RevericButtonSize.compact,
                  label: step.primaryActionLabel!,
                  icon: RevericIcons.arrow_forward,
                  onPressed: onPrimaryAction,
                )
              else
                RevericButton.primary(
                  size: RevericButtonSize.compact,
                  label: isLast
                      ? context.t(LocaleKeys.onboardingGuideDone)
                      : context.t(LocaleKeys.onboardingNext),
                  onPressed: onNext,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpotlightBackdropPainter extends CustomPainter {
  const _SpotlightBackdropPainter({
    required this.spotlight,
    required this.radius,
    required this.scrimColor,
    required this.ringColor,
    required this.glowColor,
  });

  final Rect? spotlight;
  final double radius;
  final Color scrimColor;
  final Color ringColor;
  final Color glowColor;

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Offset.zero & size;
    final rect = spotlight;
    if (rect == null) {
      canvas.drawRect(fullRect, Paint()..color = scrimColor);
      return;
    }

    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(fullRect)
      ..addRRect(rrect);
    canvas.drawPath(path, Paint()..color = scrimColor);

    final glowPaint = Paint()
      ..color = glowColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0;
    canvas.drawRRect(rrect.inflate(1.5), glowPaint);

    final ringPaint = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRRect(rrect, ringPaint);
  }

  @override
  bool shouldRepaint(covariant _SpotlightBackdropPainter oldDelegate) =>
      oldDelegate.spotlight != spotlight ||
      oldDelegate.radius != radius ||
      oldDelegate.scrimColor != scrimColor ||
      oldDelegate.ringColor != ringColor ||
      oldDelegate.glowColor != glowColor;
}

enum _TailDirection { up, down, left, right }

class _TailPainter extends CustomPainter {
  const _TailPainter({
    required this.color,
    required this.borderColor,
    required this.direction,
  });

  final Color color;
  final Color borderColor;
  final _TailDirection direction;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    switch (direction) {
      case _TailDirection.up:
        path
          ..moveTo(0, size.height)
          ..lineTo(size.width / 2, 0)
          ..lineTo(size.width, size.height)
          ..close();
      case _TailDirection.down:
        path
          ..moveTo(0, 0)
          ..lineTo(size.width / 2, size.height)
          ..lineTo(size.width, 0)
          ..close();
      case _TailDirection.left:
        path
          ..moveTo(size.width, 0)
          ..lineTo(0, size.height / 2)
          ..lineTo(size.width, size.height)
          ..close();
      case _TailDirection.right:
        path
          ..moveTo(0, 0)
          ..lineTo(size.width, size.height / 2)
          ..lineTo(0, size.height)
          ..close();
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    if (borderColor != Colors.transparent) {
      canvas.drawPath(
        path,
        Paint()
          ..color = borderColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.75,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TailPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.borderColor != borderColor ||
      oldDelegate.direction != direction;
}
