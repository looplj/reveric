// 职责: 将插件菜单、弹窗和 Popover 映射到平台宿主交互，并随节点销毁关闭所属浮层。
// 关联文件:
//   lib/shared/models/plugin/ui_tree.dart
//   lib/shared/widgets/plugin_view/input.dart
//   lib/shared/components/reveric_popover.dart
//   lib/shared/components/reveric_context_menu.dart
//   lib/mobile/widgets/sheet.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../models/plugin/ui_tree.dart';
import '../../components/reveric_context_menu.dart';
import '../../components/reveric_popover.dart';
import '../../components/reveric_dialog.dart';
import '../../theme/theme.dart';
import '../../../mobile/widgets/sheet.dart';
import 'input.dart';

class PluginUiOverlay extends HookWidget {
  const PluginUiOverlay({
    super.key,
    required this.tree,
    required this.node,
    required this.onEvent,
    required this.buildNode,
  });
  final PluginUiTree tree;
  final PluginUiNode node;
  final PluginUiEventCallback onEvent;
  final Widget Function(int) buildNode;
  @override
  Widget build(BuildContext context) {
    final route = useRef<Route<void>?>(null);
    final latest = useRef(node);
    latest.value = node;
    final callback = useRef(onEvent);
    callback.value = onEvent;
    final mobile = [
      TargetPlatform.android,
      TargetPlatform.iOS,
    ].contains(Theme.of(context).platform);
    void closeRoute() {
      final owned = route.value;
      route.value = null;
      if (owned != null && owned.isActive && owned.navigator?.mounted == true) {
        owned.navigator!.removeRoute(owned);
      }
    }

    useEffect(
      () =>
          () =>
              WidgetsBinding.instance.addPostFrameCallback((_) => closeRoute()),
      [tree, node.id],
    );
    Widget slot(PluginUiNode value, String name) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final id in tree.children(value.id, name)) buildNode(id)],
    );
    Future<void> showModal() async {
      if (route.value != null) {
        return;
      }
      Widget body(BuildContext modalContext) {
        route.value = ModalRoute.of<void>(modalContext);
        return ValueListenableBuilder<PluginUiNode?>(
          valueListenable: tree.watch(node.id),
          builder: (context, current, _) {
            if (current == null) {
              return const SizedBox.shrink();
            }
            if (current.component == 'Dialog') {
              return RevericDialog.panel(
                title: Text(current.props['title'] as String),
                content: SingleChildScrollView(child: slot(current, 'body')),
                actions: [
                  for (final id in tree.children(current.id, 'actions'))
                    buildNode(id),
                ],
              );
            }
            return Padding(
              padding: const EdgeInsets.all(RevericSpacing.x2l),
              child: SingleChildScrollView(child: slot(current, 'body')),
            );
          },
        );
      }

      if (node.component == 'Dialog') {
        await showRevericDialog<void>(context: context, builder: body);
      } else {
        await showMobileSheet<void>(
          context: context,
          showDragHandle: true,
          builder: body,
        );
      }
      route.value = null;
      if (context.mounted) {
        callback.value(latest.value, 'onOpenChange', {'open': false});
      }
    }

    final open = node.props['open'] == true;
    useEffect(() {
      if (node.component == 'Dialog' || node.component == 'Popover' && mobile) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) {
            return;
          }
          if (open) {
            unawaited(showModal());
          } else {
            closeRoute();
          }
        });
      }
      return null;
    }, [node.component, open, mobile]);
    if (node.component == 'Dialog') {
      return const SizedBox.shrink();
    }
    if (node.component == 'Popover') {
      if (mobile) {
        return InkWell(
          onTap: () => onEvent(node, 'onOpenChange', {'open': !open}),
          child: AbsorbPointer(
            child: ExcludeFocus(child: slot(node, 'trigger')),
          ),
        );
      }
      return RevericPopover(
        open: open,
        onOpenChanged: (value) =>
            onEvent(latest.value, 'onOpenChange', {'open': value}),
        trigger: (context, open, toggle) => InkWell(
          onTap: toggle,
          child: AbsorbPointer(
            child: ExcludeFocus(child: slot(latest.value, 'trigger')),
          ),
        ),
        panel: (context, close) => ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: RevericSizes.dialogWidth,
            maxHeight: MediaQuery.sizeOf(context).height * .7,
          ),
          child: SingleChildScrollView(child: slot(latest.value, 'body')),
        ),
      );
    }
    Future<void> showMenu() async {
      final items = (latest.value.props['items'] as List).cast<Map>();
      if (mobile) {
        await showMobileSheet<void>(
          context: context,
          showDragHandle: true,
          builder: (context) {
            route.value = ModalRoute.of<void>(context);
            final colors = RevericTheme.colorsOf(context),
                typo = RevericTheme.typographyOf(context);
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in items)
                    ListTile(
                      enabled: item['disabled'] != true,
                      title: Text(
                        item['label'] as String,
                        style: typo.ui.copyWith(
                          color: item['disabled'] == true
                              ? colors.textSubtle
                              : item['danger'] == true
                              ? colors.deletionBorder
                              : colors.textPrimary,
                        ),
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        callback.value(latest.value, 'onSelect', {
                          'id': item['id'],
                        });
                      },
                    ),
                ],
              ),
            );
          },
        );
      } else {
        final box = context.findRenderObject()! as RenderBox;
        final colors = RevericTheme.colorsOf(context);
        await showRevericContextMenu(
          context: context,
          position: box.localToGlobal(Offset(0, box.size.height)),
          onRouteCreated: (owned) => route.value = owned,
          entries: [
            for (final item in items)
              RevericMenuItem(
                label: item['label'] as String,
                enabled: item['disabled'] != true,
                labelColor: item['danger'] == true
                    ? colors.deletionBorder
                    : null,
                onTap: () => callback.value(latest.value, 'onSelect', {
                  'id': item['id'],
                }),
              ),
          ],
        );
      }
      route.value = null;
    }

    return InkWell(
      onTap: () => unawaited(showMenu()),
      child: AbsorbPointer(child: ExcludeFocus(child: slot(node, 'trigger'))),
    );
  }
}
