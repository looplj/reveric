// 职责: 将已校验的插件节点映射为宿主组件，并以稳定节点 Key 隔离重建和跨父级移动。
// 关联文件:
//   lib/shared/models/plugin/ui_tree.dart
//   lib/shared/widgets/plugin_view/input.dart
//   lib/shared/widgets/plugin_view/viewport_list.dart
//   lib/shared/widgets/plugin_view/overlay.dart
//   lib/shared/theme/theme.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/performance.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../models/plugin/ui_tree.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_icon_button.dart';
import '../../components/reveric_badge.dart';
import '../../components/reveric_checkbox.dart';
import '../../components/reveric_switch.dart';
import '../../components/reveric_select.dart';
import '../../components/reveric_segmented_control.dart';
import '../../components/reveric_surfaces.dart';
import '../../components/reveric_spinner.dart';
import '../../components/reveric_placeholder.dart';
import '../../components/horizontal_wheel_scroll.dart';
import '../../theme/theme.dart';
import '../ai/markdown_text.dart';
import '../a2ui/components/display.dart' show a2uiIconAssets;
import 'input.dart';
import 'viewport_list.dart';
import 'overlay.dart';

class PluginUiTreeView extends HookWidget {
  const PluginUiTreeView({
    super.key,
    required this.tree,
    required this.onEvent,
  });
  final PluginUiTree tree;
  final PluginUiEventCallback onEvent;
  @override
  Widget build(BuildContext context) {
    final renderer = useMemoized(() => _Renderer(tree, onEvent), [tree]);
    renderer.onEvent = onEvent;
    return renderer.node(1);
  }
}

class _Renderer {
  _Renderer(this.tree, this.onEvent);
  final PluginUiTree tree;
  PluginUiEventCallback onEvent;
  void forward(PluginUiNode node, String event, Map<String, Object?> payload) =>
      onEvent(node, event, payload);
  final _cache = <int, Widget>{};
  int _pruned = -1;
  Widget node(int id) => _cache.putIfAbsent(
    id,
    () => _NodeView(
      key: GlobalKey(debugLabel: '${tree.surface}:$id'),
      renderer: this,
      id: id,
    ),
  );
  List<Widget> children(PluginUiNode value, String slot) => [
    for (final id in tree.children(value.id, slot)) node(id),
  ];
  Widget child(PluginUiNode value, String slot) {
    final items = children(value, slot);
    return items.length == 1
        ? items.single
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: items,
          );
  }

  Widget build(BuildContext context, PluginUiNode value) {
    if (_pruned != tree.sequence) {
      _cache.removeWhere((id, _) => tree.node(id) == null);
      _pruned = tree.sequence;
    }
    // The host root supplies bounded space; the mounted component owns layout.
    if (value.id == 1) {
      final roots = children(value, 'children');
      // A single root Scroll fills the page so its scrollbar sits at the edge.
      if (roots.length == 1 &&
          tree.node(tree.children(1, 'children').single)?.component ==
              'Scroll') {
        return roots.single;
      }
      return Align(
        alignment: Alignment.topLeft,
        child: roots.length == 1
            ? roots.single
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: roots,
              ),
      );
    }
    final p = value.props,
        colors = RevericTheme.colorsOf(context),
        typo = RevericTheme.typographyOf(context);
    final disabled = p['disabled'] == true;
    final parent = tree.node(value.parent ?? 0);
    final trigger =
        value.parentSlot == 'trigger' &&
        ['Menu', 'Popover'].contains(parent?.component);
    void emit(String event, Map<String, Object?> payload) =>
        onEvent(value, event, payload);
    VoidCallback? press = disabled
        ? null
        : value.handlers.containsKey('onPress')
        ? () => emit('onPress', {})
        : trigger
        ? () {}
        : null;
    final widget = switch (value.component) {
      'Column' || 'Row' => _flex(value),
      'Fragment' => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children(value, 'children'),
      ),
      'Wrap' => Wrap(
        spacing: spacing(p['gap'] as String),
        runSpacing: spacing(p['runGap'] as String),
        alignment: switch (p['align']) {
          'center' => WrapAlignment.center,
          'end' => WrapAlignment.end,
          _ => WrapAlignment.start,
        },
        children: children(value, 'children'),
      ),
      'Box' => _maxBounded(
        p,
        Container(
          width: (p['width'] as num?)?.toDouble(),
          height: (p['height'] as num?)?.toDouble(),
          constraints: BoxConstraints(
            minWidth: (p['minWidth'] as num?)?.toDouble() ?? 0,
            maxWidth: (p['maxWidth'] as num?)?.toDouble() ?? double.infinity,
            minHeight: (p['minHeight'] as num?)?.toDouble() ?? 0,
            maxHeight: (p['maxHeight'] as num?)?.toDouble() ?? double.infinity,
          ),
          padding: EdgeInsets.all(spacing(p['padding'] as String)),
          decoration: BoxDecoration(
            color: switch (p['surface']) {
              'base' => colors.surface,
              'elevated' => colors.surfaceContainerHigh,
              _ => null,
            },
            borderRadius: BorderRadius.circular(radius(p['radius'] as String)),
          ),
          child: child(value, 'child'),
        ),
      ),
      'Scroll' => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: (p['maxHeight'] as num?)?.toDouble() ?? double.infinity,
        ),
        child: p['direction'] == 'horizontal'
            ? HorizontalWheelScroll(
                builder: (context, controller) => SingleChildScrollView(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  child: child(value, 'child'),
                ),
              )
            : SingleChildScrollView(child: child(value, 'child')),
      ),
      'Gap' => SizedBox.square(dimension: spacing(p['size'] as String)),
      'List' => PluginUiViewportList(
        node: value,
        onEvent: forward,
        buildNode: node,
      ),
      'Text' => Text(
        p['text'] as String,
        maxLines: (p['maxLines'] as num?)?.toInt(),
        overflow: p['maxLines'] == null
            ? TextOverflow.clip
            : TextOverflow.ellipsis,
        style: (switch (p['variant']) {
          // Page titles belong to the host header; plugin headings are sections.
          'heading' => typo.uiSemibold,
          'caption' => typo.uiSmall,
          _ => typo.ui,
        }).copyWith(color: tone(context, p['tone'] as String)),
      ),
      'Markdown' => AiMarkdownText(
        p['text'] as String,
        style: typo.body.copyWith(color: colors.textPrimary),
      ),
      'Icon' => RevericIcon(
        a2uiIconAssets[p['name']]!,
        size: switch (p['size']) {
          'small' => RevericSizes.buttonIconSize,
          'large' => RevericSizes.placeholderIconSizeCompact,
          _ => RevericSizes.buttonIconSize,
        },
        color: tone(context, p['tone'] as String),
      ),
      'Card' => RevericElevatedCard(
        fallback: colors.surface,
        padding: EdgeInsets.all(spacing(p['padding'] as String)),
        child: child(value, 'child'),
      ),
      'Divider' =>
        p['direction'] == 'vertical'
            ? VerticalDivider(color: colors.borderSubtle)
            : Divider(color: colors.borderSubtle),
      'Badge' => RevericBadge(
        label: p['text'] as String,
        color: tone(context, p['tone'] as String),
      ),
      'Loading' => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: RevericSizes.buttonIconSize,
            child: RevericSpinner(color: colors.accent),
          ),
          if (p['label'] case final String label) ...[
            const SizedBox(width: RevericSpacing.sm),
            Flexible(child: Text(label, style: typo.ui)),
          ],
        ],
      ),
      'EmptyState' => RevericPlaceholder.empty(
        icon: RevericIcons.info,
        title: p['message'] as String,
        description: p['label'] as String?,
        action: Wrap(
          spacing: RevericSpacing.sm,
          children: children(value, 'actions'),
        ),
      ),
      'Button' => switch (p['variant']) {
        'primary' => RevericButton.primary(
          label: p['label'] as String,
          onPressed: press,
          loading: p['loading'] as bool,
          icon: a2uiIconAssets[p['icon']],
          size: buttonSize(p['size'] as String),
        ),
        'danger' => RevericButton.danger(
          label: p['label'] as String,
          onPressed: press,
          loading: p['loading'] as bool,
          icon: a2uiIconAssets[p['icon']],
          size: buttonSize(p['size'] as String),
        ),
        'text' => RevericButton.text(
          label: p['label'] as String,
          onPressed: press,
          loading: p['loading'] as bool,
          icon: a2uiIconAssets[p['icon']],
          size: buttonSize(p['size'] as String),
        ),
        _ => RevericButton.secondary(
          label: p['label'] as String,
          onPressed: press,
          loading: p['loading'] as bool,
          icon: a2uiIconAssets[p['icon']],
          size: buttonSize(p['size'] as String),
        ),
      },
      'IconButton' => RevericIconButton(
        icon: a2uiIconAssets[p['icon']]!,
        tooltip: p['tooltip'] as String,
        onPressed: press,
      ),
      'TextField' ||
      'SearchField' => PluginUiInput(tree: tree, node: value, onEvent: onEvent),
      'Select' => RevericSelect<String>(
        value: p['value'] as String?,
        enabled: !disabled && value.handlers.containsKey('onChange'),
        items: [
          for (final item in p['options'] as List)
            RevericSelectItem(
              value: (item as Map)['value'] as String,
              label: item['label'] as String,
              enabled: item['disabled'] != true,
            ),
        ],
        onChanged: (v) => emit('onChange', {'value': v}),
      ),
      'Checkbox' || 'Switch' => MergeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            value.component == 'Checkbox'
                ? RevericCheckbox(
                    value: p['value'] as bool,
                    onChanged: disabled
                        ? null
                        : (v) => emit('onChange', {'value': v}),
                  )
                : RevericSwitch(
                    value: p['value'] as bool,
                    onChanged: disabled
                        ? null
                        : (v) => emit('onChange', {'value': v}),
                  ),
            if (p['label'] case final String label) ...[
              const SizedBox(width: RevericSpacing.sm),
              Flexible(child: Text(label, style: typo.ui)),
            ],
          ],
        ),
      ),
      'Tabs' => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RevericSegmentedControl<String>(
            segments: [
              for (final item in p['items'] as List)
                RevericSegment(
                  value: (item as Map)['id'] as String,
                  label: item['label'] as String,
                ),
            ],
            selected: p['value'] as String,
            onChanged: (v) => emit('onChange', {'value': v}),
          ),
          const SizedBox(height: RevericSpacing.md),
          child(value, 'content'),
        ],
      ),
      'Collapsible' => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RevericButton.text(
            label: p['title'] as String,
            onPressed: () => emit('onOpenChange', {'open': p['open'] != true}),
          ),
          Visibility(
            visible: p['open'] as bool,
            maintainState: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: children(value, 'children'),
            ),
          ),
        ],
      ),
      'Menu' || 'Dialog' || 'Popover' => PluginUiOverlay(
        tree: tree,
        node: value,
        onEvent: forward,
        buildNode: node,
      ),
      _ => throw StateError('Unmapped validated component ${value.component}'),
    };
    return Semantics(
      identifier: p['testId'] as String?,
      label: p['accessibleLabel'] as String?,
      child: widget,
    );
  }

  /// Only a Row or Column with flex children needs the parent constraints;
  /// the rest skip the LayoutBuilder and its extra layout pass.
  Widget _flex(PluginUiNode value) {
    final p = value.props, vertical = value.component == 'Column';
    final ids = tree.children(value.id, 'children');
    final flexes = [
      for (final id in ids) (tree.node(id)!.props['flex'] as num).toInt(),
    ];
    final gap = spacing(p['gap'] as String);
    Widget layout(bool bounded) {
      final items = <Widget>[];
      for (final (index, id) in ids.indexed) {
        if (index > 0) {
          items.add(
            SizedBox(
              width: vertical ? null : gap,
              height: vertical ? gap : null,
            ),
          );
        }
        final flex = flexes[index];
        items.add(
          flex == 0
              ? node(id)
              : Flexible(
                  flex: flex,
                  fit: bounded ? FlexFit.tight : FlexFit.loose,
                  child: node(id),
                ),
        );
      }
      return Flex(
        direction: vertical ? Axis.vertical : Axis.horizontal,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: switch (p['align']) {
          'center' => CrossAxisAlignment.center,
          'end' => CrossAxisAlignment.end,
          'stretch' => CrossAxisAlignment.stretch,
          _ => CrossAxisAlignment.start,
        },
        mainAxisAlignment: switch (p['justify']) {
          'center' => MainAxisAlignment.center,
          'end' => MainAxisAlignment.end,
          'spaceBetween' => MainAxisAlignment.spaceBetween,
          _ => MainAxisAlignment.start,
        },
        children: items,
      );
    }

    if (!flexes.any((flex) => flex > 0)) {
      return layout(false);
    }
    return LayoutBuilder(
      builder: (context, constraints) => layout(
        vertical ? constraints.hasBoundedHeight : constraints.hasBoundedWidth,
      ),
    );
  }
}

class _NodeView extends StatelessWidget {
  const _NodeView({super.key, required this.renderer, required this.id});
  final _Renderer renderer;
  final int id;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PluginUiNode?>(
    valueListenable: renderer.tree.watch(id),
    builder: (context, node, _) =>
        node == null ? const SizedBox.shrink() : renderer.build(context, node),
  );
}

/// Keeps Box max constraints effective under a tight parent, such as a
/// stretched Column or the cross axis of a Scroll.
Widget _maxBounded(Map<String, Object?> props, Widget box) =>
    props['maxWidth'] == null && props['maxHeight'] == null
    ? box
    : Align(alignment: Alignment.topLeft, child: box);

double spacing(String value) => switch (value) {
  'none' => 0,
  'xxs' => RevericSpacing.xxs,
  'xs' => RevericSpacing.xs,
  'sm' => RevericSpacing.sm,
  'md' => RevericSpacing.md,
  'lg' => RevericSpacing.lg,
  'xl' => RevericSpacing.xl,
  'x2l' => RevericSpacing.x2l,
  'x3l' => RevericSpacing.x3l,
  'x4l' => RevericSpacing.x4l,
  _ => throw StateError('Invalid spacing'),
};
double radius(String value) => switch (value) {
  'none' => 0,
  'small' => RevericRadius.small,
  'medium' => RevericRadius.medium,
  'large' => RevericRadius.large,
  'card' => RevericRadius.card,
  _ => throw StateError('Invalid radius'),
};
Color tone(BuildContext context, String value) {
  final colors = RevericTheme.colorsOf(context);
  return switch (value) {
    'default' => colors.textPrimary,
    'muted' => colors.textMuted,
    'accent' => colors.accent,
    'success' => colors.success,
    'warning' => colors.warningText,
    'danger' => colors.deletionBorder,
    _ => throw StateError('Invalid tone'),
  };
}

RevericButtonSize buttonSize(String value) => switch (value) {
  'prominent' => RevericButtonSize.prominent,
  'compact' => RevericButtonSize.compact,
  _ => RevericButtonSize.standard,
};
