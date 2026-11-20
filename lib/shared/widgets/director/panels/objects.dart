// 职责: 对象面板 — 搜索并分组列出角色、道具和机位，右键删除对象。
// 关联文件:
//   lib/shared/services/director/session.dart
//   lib/shared/services/director/commands.dart
//   lib/shared/widgets/director/panels/common.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/search-debounce.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../components/reveric_search_field.dart';
import '../../../services/director/session.dart';
import '../../../theme/theme.dart';
import '../strings.dart';
import 'common.dart';

class DirectorObjectsPanel extends HookWidget {
  const DirectorObjectsPanel({super.key, required this.session});
  final DirectorSession session;

  @override
  Widget build(BuildContext context) {
    final query = useState('');
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final document = session.history.document;
    bool match(Map<String, dynamic> o) =>
        query.value.isEmpty ||
        (o['name'] as String).toLowerCase().contains(query.value);
    final active = document.objects.where((o) => match(o));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RevericDebouncedSearchField(
          hint: tr(context, 'search_objects'),
          height: RevericSizes.fieldHeightSm,
          onDebouncedChanged: (v) => query.value = v,
        ),
        const SizedBox(height: RevericSpacing.lg),
        for (final group in [('actor', 'actors'), ('prop', 'props')])
          if (active.any((o) => o['kind'] == group.$1)) ...[
            PanelTitle(tr(context, group.$2), top: RevericSpacing.xxs),
            for (final o in active.where((o) => o['kind'] == group.$1))
              PanelRow(
                key: ValueKey('director-object:${o['id']}'),
                title: o['name'],
                color: group.$1 == 'actor' ? o['color'] : null,
                icon: RevericIcons.cube,
                selected: session.selected == o['id'],
                onTap: () => session.select(o['id']),
                menu: session.readOnly
                    ? null
                    : () => objectMenu(context, session, o['id']),
              ),
            const SizedBox(height: RevericSpacing.sm),
          ],
        PanelTitle(tr(context, 'cameras'), top: RevericSpacing.xxs),
        for (final c in document.activeCameras.where(match))
          PanelRow(
            key: ValueKey('director-object:${c['id']}'),
            title: c['name'],
            icon: RevericIcons.video_camera,
            trailing: '${c['focal_length_mm']}mm',
            selected: session.selected == c['id'],
            onTap: () => session.select(c['id']),
            menu: session.readOnly
                ? null
                : () => objectMenu(context, session, c['id']),
          ),
        if (active.isEmpty && query.value.isNotEmpty)
          Text(
            tr(context, 'no_match'),
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
      ],
    );
  }
}
