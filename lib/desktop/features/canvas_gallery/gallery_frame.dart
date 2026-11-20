// 职责: 提供画廊页面的桌面窗口框架、共享封面、进度条与语义提示条组件。
// 关联文件:
//   lib/desktop/features/canvas_gallery/page.dart
//   lib/desktop/features/canvas_gallery/detail.dart
//   lib/desktop/features/canvas_gallery/publish_dialog.dart
//   lib/desktop/widgets/desktop_window_frame.dart
//   lib/desktop/widgets/home/novel_home_helpers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/desktop-window-frame.md
//   .agents/rules/hooks.md
//   .agents/rules/icons.md

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/services/canvas_gallery/service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/app_background.dart';
import '../../widgets/desktop_window_frame.dart';
import '../../widgets/home/novel_home_helpers.dart';
import '../canvas/widgets/glass.dart';

class GalleryFrame extends HookConsumerWidget {
  const GalleryFrame({
    super.key,
    required this.title,
    required this.body,
    this.titleTrailing,
    this.action,
    this.showDivider = true,
  });

  final String title;
  final Widget body;
  final Widget? titleTrailing;
  final Widget? action;
  final bool showDivider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final appBackgroundActive = ref.watch(appBackgroundActiveProvider);
    final backKey = useMemoized(GlobalKey.new);
    final actionKey = useMemoized(GlobalKey.new);

    return Scaffold(
      backgroundColor: appScaffoldBackgroundColor(colors, appBackgroundActive),
      body: DesktopWindowFrame(
        titleBarGestureExclusionKeys: [backKey, if (action != null) actionKey],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: DesktopWindowFrame.titleBarHeight,
              child: Row(
                children: [
                  SizedBox(width: DesktopWindowFrame.sidebarLeadingInset),
                  Expanded(
                    child: SizedBox(
                      height: DesktopWindowFrame.titleBarHeight,
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: DesktopWindowFrame.sidebarLeadingInset == 0
                              ? RevericSpacing.md
                              : RevericSpacing.xs,
                          right: RevericSpacing.md,
                        ),
                        child: Row(
                          children: [
                            RevericIconButton(
                              key: backKey,
                              icon: RevericIcons.arrow_back,
                              tooltip: context.t(LocaleKeys.commonBack),
                              onPressed: Navigator.of(context).pop,
                            ),
                            const SizedBox(width: RevericSpacing.xs),
                            Flexible(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: typo.uiSemibold.copyWith(
                                  fontSize: 15,
                                  color: colors.textPrimary,
                                ),
                              ),
                            ),
                            if (titleTrailing != null) ...[
                              const SizedBox(width: RevericSpacing.sm),
                              titleTrailing!,
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (action case final trailing?)
                    Padding(
                      key: actionKey,
                      padding: EdgeInsets.only(
                        right:
                            DesktopWindowFrame.trailingInset +
                            RevericSpacing.lg,
                      ),
                      child: trailing,
                    ),
                ],
              ),
            ),
            if (showDivider)
              Divider(
                height: RevericSizes.dividerThickness,
                thickness: RevericSizes.dividerThickness,
                color: colors.borderSubtle,
              ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

class GalleryCover extends StatelessWidget {
  const GalleryCover({super.key, required this.uri, this.contain = false});

  final Uri uri;
  final bool contain;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return ColoredBox(
      color: colors.surfaceDim,
      child: Image.network(
        uri.toString(),
        headers: const {HttpHeaders.userAgentHeader: canvasGalleryUserAgent},
        fit: contain ? BoxFit.contain : BoxFit.cover,
        cacheWidth: contain ? 1600 : 720,
        frameBuilder: (_, child, frame, synchronous) {
          if (synchronous) {
            return child;
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              const HomeCanvasPlaceholder(iconSize: 28),
              AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: CanvasMotion.hover,
                curve: CanvasMotion.curve,
                child: child,
              ),
            ],
          );
        },
        errorBuilder: (_, _, _) => const HomeCanvasPlaceholder(iconSize: 28),
      ),
    );
  }
}

class GalleryProgressBar extends StatelessWidget {
  const GalleryProgressBar({super.key, required this.label, this.progress});

  final String label;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final value = progress?.clamp(0.0, 1.0);
    final percent = value == null ? null : '${(value * 100).floor()}%';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSmall.copyWith(color: colors.textSecondary),
              ),
            ),
            if (percent != null) ...[
              const SizedBox(width: RevericSpacing.sm),
              Text(
                percent,
                style: typo.mono.copyWith(
                  color: colors.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: RevericSpacing.xs),
        LinearProgressIndicator(
          value: value,
          minHeight: 4,
          borderRadius: BorderRadius.circular(RevericRadius.small),
          color: colors.accent,
          backgroundColor: colors.surfaceDim,
        ),
      ],
    );
  }
}

enum GalleryNoticeTone { warning, error }

class GalleryNoticeBanner extends StatelessWidget {
  const GalleryNoticeBanner({
    super.key,
    required this.message,
    this.tone = GalleryNoticeTone.error,
    this.action,
  });

  final String message;
  final GalleryNoticeTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final isWarning = tone == GalleryNoticeTone.warning;
    final bg = isWarning ? colors.warningBg : colors.deletionBg;
    final fg = isWarning ? colors.warningText : colors.error;
    final icon = isWarning
        ? RevericIcons.warning_amber_rounded
        : RevericIcons.error_outline;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.lg,
        vertical: RevericSpacing.md,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: fg.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: RevericIcon(icon, size: 16, color: fg),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: typo.uiSmall.copyWith(color: fg, height: 1.45),
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: RevericSpacing.md),
            action!,
          ],
        ],
      ),
    );
  }
}

String gallerySize(BuildContext context, int bytes) {
  final format = NumberFormat.decimalPatternDigits(
    locale: Localizations.localeOf(context).toLanguageTag(),
    decimalDigits: bytes >= (1 << 20) ? 1 : 0,
  );
  if (bytes >= (1 << 30)) {
    return '${format.format(bytes / (1 << 30))} GiB';
  }
  if (bytes >= (1 << 20)) {
    return '${format.format(bytes / (1 << 20))} MiB';
  }
  if (bytes >= (1 << 10)) {
    return '${format.format(bytes / (1 << 10))} KiB';
  }
  return '${format.format(bytes)} B';
}

String galleryDate(BuildContext context, DateTime date) => DateFormat.yMMMd(
  Localizations.localeOf(context).toLanguageTag(),
).format(date.toLocal());
