// 职责: 顶栏画幅按钮 — 展示当前比例，点开以比例示意卡片设置整个导演工程的预览和输出画幅。
// 关联文件:
//   lib/shared/models/director/aspect_ratio.dart
//   lib/shared/services/director/session.dart
//   lib/shared/widgets/director/header.dart
//   lib/shared/components/reveric_popover.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';

import '../../components/reveric_button.dart';
import '../../components/reveric_icon_button.dart';
import '../../components/reveric_popover.dart';
import '../../models/director/aspect_ratio.dart';
import '../../services/director/session.dart';
import '../../theme/canvas_colors.dart';
import '../../theme/theme.dart';
import 'strings.dart';

String _label(BuildContext context, DirectorAspectRatio aspect) =>
    aspect == DirectorAspectRatio.adaptive
    ? tr(context, 'aspect_auto')
    : aspect.label;

class DirectorAspectButton extends StatelessWidget {
  const DirectorAspectButton({
    super.key,
    required this.session,
    this.compact = false,
  });
  final DirectorSession session;

  /// 只显示图标，比例写进提示。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final current = session.history.document.aspectRatio;
    if (session.readOnly) {
      return compact
          ? RevericIconButton(
              key: const ValueKey('director-aspect-button'),
              icon: RevericIcons.aspect_ratio,
              tooltip: '${tr(context, 'aspect')} · ${_label(context, current)}',
              onPressed: null,
            )
          : Tooltip(
              message: tr(context, 'aspect'),
              child: RevericButton.text(
                key: const ValueKey('director-aspect-button'),
                label: _label(context, current),
                icon: RevericIcons.aspect_ratio,
                size: RevericButtonSize.compact,
                onPressed: null,
              ),
            );
    }
    return RevericPopover(
      trigger: (context, open, toggle) => compact
          ? RevericIconButton(
              key: const ValueKey('director-aspect-button'),
              icon: RevericIcons.aspect_ratio,
              tooltip: '${tr(context, 'aspect')} · ${_label(context, current)}',
              onPressed: session.playing ? null : toggle,
            )
          : Tooltip(
              message: tr(context, 'aspect'),
              child: RevericButton.text(
                key: const ValueKey('director-aspect-button'),
                label: _label(context, current),
                icon: RevericIcons.aspect_ratio,
                size: RevericButtonSize.compact,
                onPressed: session.playing ? null : toggle,
              ),
            ),
      panel: (context, close) =>
          _AspectPanel(session: session, onPicked: close),
    );
  }
}

class _AspectPanel extends StatelessWidget {
  const _AspectPanel({required this.session, required this.onPicked});
  final DirectorSession session;
  final VoidCallback onPicked;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final document = session.history.document;
    final current = document.aspectRatio;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.all(RevericSpacing.lg),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(RevericRadius.large),
          boxShadow: canvasGlassShadows(colors),
        ),
        child: SizedBox(
          width: RevericSizes.directorAspectCard * 4 + RevericSpacing.sm * 3,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(context, 'aspect'),
                style: typo.uiSmall.copyWith(color: colors.textMuted),
              ),
              const SizedBox(height: RevericSpacing.md),
              Wrap(
                spacing: RevericSpacing.sm,
                runSpacing: RevericSpacing.sm,
                children: [
                  for (final aspect in DirectorAspectRatio.values)
                    Tooltip(
                      message: aspect == DirectorAspectRatio.adaptive
                          ? current == aspect
                                ? '${document.width} × ${document.height}'
                                : tr(context, 'aspect_viewport')
                          : '${aspect.width} × ${aspect.height}',
                      child: Semantics(
                        selected: current == aspect,
                        child: Material(
                          color: current == aspect
                              ? colors.selected
                              : colors.surfaceContainer,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              RevericRadius.medium,
                            ),
                            side: BorderSide(
                              color: current == aspect
                                  ? colors.accent
                                  : colors.border,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            key: ValueKey('director-aspect:${aspect.label}'),
                            onTap: () {
                              onPicked();
                              session.attempt(
                                () => session.history.setAspectRatio(aspect),
                              );
                            },
                            child: SizedBox(
                              width: RevericSizes.directorAspectCard,
                              height: RevericSizes.directorAspectCard,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  SizedBox.square(
                                    dimension: RevericSizes.iconButtonSize,
                                    child: Center(
                                      child: AspectRatio(
                                        aspectRatio:
                                            aspect ==
                                                DirectorAspectRatio.adaptive
                                            ? document.width / document.height
                                            : aspect.ratio,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: current == aspect
                                                  ? colors.accent
                                                  : colors.textMuted,
                                              width: 1.5,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              RevericRadius.small,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: RevericSpacing.xs),
                                  Text(
                                    _label(context, aspect),
                                    style: typo.uiSmall.copyWith(
                                      color: current == aspect
                                          ? colors.accent
                                          : colors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
