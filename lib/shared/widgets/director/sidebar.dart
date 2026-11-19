// 职责: 导演台左栏 — 分类图标栏切换对象、角色、道具、机位与运镜面板，并提供宿主注入的 AI 识图入口。
// 关联文件:
//   lib/shared/services/director/session.dart
//   lib/shared/widgets/director/panels/objects.dart
//   lib/shared/widgets/director/panels/actors.dart
//   lib/shared/widgets/director/panels/props.dart
//   lib/shared/widgets/director/panels/cameras.dart
//   lib/shared/widgets/director/panels/moves.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules: .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../services/director/session.dart';
import '../../services/director/actor_catalog.dart';
import '../../theme/theme.dart';
import 'panels/actors.dart';
import 'panels/cameras.dart';
import 'panels/moves.dart';
import 'panels/objects.dart';
import 'panels/props.dart';
import 'strings.dart';

class DirectorSidebar extends HookWidget {
  const DirectorSidebar({
    super.key,
    required this.session,
    required this.onAddCameraFromView,
    required this.actorCatalog,
    this.onRecognizeImage,
  });
  final DirectorSession session;
  final DirectorActorCatalogController actorCatalog;
  final void Function(String name) onAddCameraFromView;

  /// 「AI 识图」入口；宿主不支持时为 null，rail 不显示该项。
  final VoidCallback? onRecognizeImage;

  @override
  Widget build(BuildContext context) {
    useListenable(session);
    final colors = RevericTheme.colorsOf(context);
    if (session.readOnly) {
      return ColoredBox(
        color: colors.surfaceDim,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(RevericSpacing.lg),
          child: DirectorObjectsPanel(session: session),
        ),
      );
    }
    final categories = [
      ('objects', RevericIcons.account_tree),
      ('actors', RevericIcons.person),
      ('props', RevericIcons.cube),
      ('cameras', RevericIcons.video_camera),
      ('moves', RevericIcons.alt_route_outlined),
    ];
    final tab = categories.any((category) => category.$1 == session.panel)
        ? session.panel
        : 'objects';
    return ColoredBox(
      color: colors.surfaceDim,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: RevericSizes.directorRailWidth,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: RevericSpacing.sm),
              child: Column(
                children: [
                  for (final c in categories)
                    _RailButton(
                      key: ValueKey('director-tab:${c.$1}'),
                      icon: c.$2,
                      label: tr(context, 'tab_${c.$1}'),
                      selected: tab == c.$1,
                      onTap: () => session.setPanel(c.$1),
                    ),
                  if (onRecognizeImage != null) ...[
                    Divider(
                      height: RevericSpacing.md,
                      indent: RevericSpacing.sm,
                      endIndent: RevericSpacing.sm,
                      color: colors.borderSubtle,
                    ),
                    _RailButton(
                      key: const ValueKey('director-recognize-image'),
                      icon: RevericIcons.auto_awesome,
                      label: tr(context, 'recognize_image'),
                      selected: false,
                      onTap: onRecognizeImage!,
                    ),
                  ],
                ],
              ),
            ),
          ),
          VerticalDivider(width: 1, color: colors.borderSubtle),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(RevericSpacing.lg),
              child: switch (tab) {
                'actors' => DirectorActorsPanel(
                  session: session,
                  catalog: actorCatalog,
                ),
                'props' => DirectorPropsPanel(session: session),
                'cameras' => DirectorCamerasPanel(
                  session: session,
                  onAlignToView: onAddCameraFromView,
                ),
                'moves' => DirectorMovesPanel(session: session),
                _ => DirectorObjectsPanel(session: session),
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final color = selected ? colors.accent : colors.textMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: RevericSpacing.xxs),
      child: Semantics(
        selected: selected,
        child: Material(
          color: selected ? colors.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
          child: InkWell(
            borderRadius: BorderRadius.circular(RevericRadius.medium),
            onTap: onTap,
            child: SizedBox(
              width: RevericSizes.directorRailTab,
              height: RevericSizes.directorRailTab,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  RevericIcon(
                    icon,
                    size: RevericSizes.buttonIconSize,
                    color: color,
                  ),
                  const SizedBox(height: RevericSpacing.xxs),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiTiny.copyWith(color: color),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
