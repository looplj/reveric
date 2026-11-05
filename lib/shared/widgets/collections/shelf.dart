// 职责: 展示一行集合标签：桌面放不下的收进「更多」、可拖动排序、右键出集合菜单；
//       移动端横向滚动、长按出集合菜单。集合菜单提供重命名、左移、右移和删除。
// 关联文件:
//   lib/shared/widgets/collections/location.dart
//   lib/shared/widgets/collections/name_dialog.dart
//   lib/shared/providers/novel_collection_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../mobile/widgets/sheet.dart';
import '../../components/reveric_context_menu.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/novel_collection.dart';
import '../../providers/novel_collection_providers.dart';
import '../../providers/novel_providers.dart';
import '../../theme/theme.dart';
import '../confirm_dialog.dart';
import 'location.dart';
import 'name_dialog.dart';

String collectionLabel(BuildContext context, LibraryCollection collection) =>
    collection.builtin
    ? context.t(LocaleKeys.libraryAll)
    : collection.unavailableReason == null
    ? collection.name
    : '${collection.name} · ${context.t(LocaleKeys.libraryCollectionUnavailable)}';

Future<void> createCollection(
  BuildContext context,
  CollectionLocation location,
) async {
  final id = await showCollectionName(
    context,
    mobile: location.mobile,
    contentKind: location.contentKind,
  );
  if (context.mounted && id != null) {
    location.open(id);
  }
}

/// 把集合挪到去掉它之后列表的第 [to] 位；全部固定第一，别的挪不到它前面。
Future<void> moveCollection(
  BuildContext context,
  CollectionLocation location,
  String id,
  int to,
) async {
  final visible = <String>[
    for (final c in location.collections.value ?? <LibraryCollection>[]) c.id,
  ];
  final from = visible.indexOf(id);
  if (from <= 0) {
    return;
  }
  visible.removeAt(from);
  visible.insert(to.clamp(1, visible.length), id);
  final container = ProviderScope.containerOf(context, listen: false);
  // 顺序是两个库共用的一份：另一个库的集合留在原位，只按新顺序重填本库的位置。
  final slots = visible.toSet();
  final reordered = visible.iterator;
  final all = container.read(orderedCollectionsProvider).value;
  final ids = all == null
      ? visible
      : [
          for (final c in all)
            if (slots.contains(c.id) && reordered.moveNext())
              reordered.current
            else
              c.id,
        ];
  try {
    await saveCollectionOrder(container.read(appDatabaseProvider), ids);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.t(LocaleKeys.libraryCollectionOrderFailed)),
        ),
      );
    }
  }
}

Future<void> _deleteCollection(
  BuildContext context,
  CollectionLocation location,
  LibraryCollection collection,
) async {
  final confirmed = await showConfirmDialog(
    context,
    title: context.t(LocaleKeys.commonDelete),
    message: context.t(
      LocaleKeys.libraryCollectionDeleteConfirm,
      namedArgs: {'name': collection.name},
    ),
    confirmLabel: context.t(LocaleKeys.commonDelete),
    variant: ConfirmDialogVariant.error,
  );
  if (!confirmed || !context.mounted) {
    return;
  }
  try {
    await ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appDatabaseProvider).novelCollectionDao.softDelete(collection.id);
    // 删的是当前集合才回到全部；删别的不动当前选择。
    if (collection.id == location.current?.id) {
      location.back();
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t(LocaleKeys.libraryCollectionFailed))),
      );
    }
  }
}

/// 集合菜单：桌面在 [position] 弹右键菜单，移动端弹底部面板。全部不响应。
void showCollectionMenu(
  BuildContext context,
  CollectionLocation location,
  LibraryCollection collection, {
  Offset? position,
}) {
  if (collection.builtin) {
    return;
  }
  final colors = RevericTheme.colorsOf(context);
  final list = location.collections.value ?? [];
  final index = list.indexWhere((c) => c.id == collection.id);
  final entries = <RevericMenuEntry>[
    RevericMenuItem(
      label: context.t(LocaleKeys.commonRename),
      icon: RevericIcons.edit_outlined,
      onTap: () => showCollectionName(
        context,
        mobile: location.mobile,
        collection: collection,
      ),
    ),
    RevericMenuItem(
      label: context.t(LocaleKeys.libraryCollectionMoveLeft),
      icon: RevericIcons.arrow_back,
      enabled: index > 1,
      onTap: () => moveCollection(context, location, collection.id, index - 1),
    ),
    RevericMenuItem(
      label: context.t(LocaleKeys.libraryCollectionMoveRight),
      icon: RevericIcons.arrow_forward,
      enabled: index >= 0 && index < list.length - 1,
      onTap: () => moveCollection(context, location, collection.id, index + 1),
    ),
    const RevericMenuDivider(),
    RevericMenuItem(
      label: context.t(LocaleKeys.commonDelete),
      icon: RevericIcons.delete_outline,
      labelColor: colors.deletionBorder,
      iconColor: colors.deletionBorder,
      onTap: () => _deleteCollection(context, location, collection),
    ),
  ];
  if (!location.mobile) {
    showRevericContextMenu(
      context: context,
      position: position ?? Offset.zero,
      entries: entries,
      minWidth: 160,
    );
    return;
  }
  final typo = RevericTheme.typographyOf(context);
  showMobileSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x3l),
            child: Text(
              collection.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(height: RevericSpacing.sm),
          for (final entry in entries)
            switch (entry) {
              RevericMenuItem() => ListTile(
                enabled: entry.enabled,
                leading: RevericIcon(
                  entry.icon!,
                  size: 20,
                  color: entry.iconColor ?? colors.textSecondary,
                ),
                title: Text(
                  entry.label,
                  style: typo.ui.copyWith(
                    color: entry.labelColor ?? colors.textPrimary,
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  entry.onTap!();
                },
              ),
              _ => Divider(height: 1, color: colors.borderSubtle),
            },
          const SizedBox(height: RevericSpacing.x2l),
        ],
      ),
    ),
  );
}

const double _tabHeight = 44;
const double _tabGap = 4;
const double _addWidth = 36;
const double _nameMaxWidth = 160;

/// 一行集合标签，末尾是新建集合。当前集合总是可见。
class CollectionTabs extends StatelessWidget {
  const CollectionTabs({super.key, required this.location});
  final CollectionLocation location;
  @override
  Widget build(BuildContext context) => location.mobile
      ? _MobileTabs(location: location)
      : _DesktopTabs(location: location);
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.count,
    required this.active,
    this.horizontalPadding = RevericSpacing.md,
    this.nameMaxWidth = _nameMaxWidth,
    this.dropAfter,
  });
  final String label;
  final int? count;
  final bool active;
  final double horizontalPadding;
  final double nameMaxWidth;

  /// 拖动悬停时的插入指示：false 画在左边，true 画在右边。
  final bool? dropAfter;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return SizedBox(
      height: _tabHeight,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: AlignmentDirectional.centerStart,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: nameMaxWidth),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (active ? typo.uiSemibold : typo.ui).copyWith(
                      color: active ? colors.textPrimary : colors.textMuted,
                    ),
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 5),
                  Text(
                    '$count',
                    style: typo.uiTiny.copyWith(
                      color: active ? colors.accent : colors.textSubtle,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (active)
            Positioned(
              left: horizontalPadding,
              right: horizontalPadding,
              bottom: 0,
              height: 2,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.accent,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(2),
                  ),
                ),
              ),
            ),
          if (dropAfter != null)
            Positioned(
              left: dropAfter! ? null : -3,
              right: dropAfter! ? -3 : null,
              top: 10,
              bottom: 10,
              width: 2,
              child: ColoredBox(color: colors.accent),
            ),
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.location, required this.size});
  final CollectionLocation location;
  final double size;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Tooltip(
      message: context.t(LocaleKeys.commonCreate),
      child: InkWell(
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        onTap: () => createCollection(context, location),
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: RevericIcon(
              RevericIcons.add,
              size: location.mobile ? 18 : 14,
              color: colors.textSubtle,
              semanticLabel: context.t(LocaleKeys.commonCreate),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopTabs extends HookWidget {
  const _DesktopTabs({required this.location});
  final CollectionLocation location;
  @override
  Widget build(BuildContext context) {
    final typo = RevericTheme.typographyOf(context);
    final colors = RevericTheme.colorsOf(context);
    final drop = useState<({String id, bool after})?>(null);
    final all = location.collections.value ?? [];
    final counts = location.counts.value ?? const {};
    final current = location.current;
    final scaler = MediaQuery.textScalerOf(context);
    double textWidth(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    // 按选中态的粗体量，切换选中不会让标签在可见与溢出之间跳。
    double tabWidth(LibraryCollection c) {
      final count = counts[c.id];
      return RevericSpacing.md * 2 +
          math.min(
            _nameMaxWidth,
            textWidth(collectionLabel(context, c), typo.uiSemibold),
          ) +
          (count == null ? 0 : 5 + textWidth('$count', typo.uiTiny)) +
          1;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final widths = [for (final c in all) tabWidth(c)];
        final available = constraints.maxWidth - _addWidth;
        final total =
            widths.fold<double>(0, (a, b) => a + b) +
            _tabGap * math.max(0, widths.length - 1);
        var fit = widths.length;
        // 「更多」按钮按实际文案量宽：译文长度不同，写死的宽度会让末尾溢出。
        final moreWidth =
            RevericSpacing.md * 2 +
            textWidth(context.t(LocaleKeys.libraryCollectionMore), typo.ui) +
            _tabGap * 2 +
            textWidth('${all.length}', typo.uiTiny) +
            12 +
            _tabGap;
        if (total > available) {
          var used = moreWidth;
          fit = 0;
          for (final w in widths) {
            if (used + w + _tabGap > available) {
              break;
            }
            used += w + _tabGap;
            fit += 1;
          }
          fit = math.max(1, fit);
        }
        final visible = all.take(fit).toList();
        if (current != null &&
            fit < all.length &&
            !visible.any((c) => c.id == current.id)) {
          visible[visible.length - 1] = current;
        }
        // 连一个标签都放不下时仍要露出当前集合，只能让它的名字截短。
        var nameMaxWidth = _nameMaxWidth;
        if (fit < all.length && visible.length == 1) {
          final only = visible.single;
          final overflow = moreWidth + tabWidth(only) + _tabGap - available;
          if (overflow > 0) {
            nameMaxWidth = math.max(
              0,
              math.min(
                    _nameMaxWidth,
                    textWidth(collectionLabel(context, only), typo.uiSemibold),
                  ) -
                  overflow,
            );
          }
        }
        final hidden = all.where((c) => !visible.contains(c)).toList();

        void drag(String dragged) {
          final target = drop.value;
          drop.value = null;
          if (target == null || target.id == dragged) {
            return;
          }
          final ids = [
            for (final c in all)
              if (c.id != dragged) c.id,
          ];
          final to = ids.indexOf(target.id) + (target.after ? 1 : 0);
          moveCollection(context, location, dragged, math.max(1, to));
        }

        return ClipRect(
          child: Row(
            children: [
              for (final (index, collection) in visible.indexed) ...[
                if (index > 0) const SizedBox(width: _tabGap),
                _DesktopTab(
                  key: ValueKey('collection-${collection.id}'),
                  location: location,
                  collection: collection,
                  count: counts[collection.id],
                  nameMaxWidth: nameMaxWidth,
                  dropAfter: drop.value?.id == collection.id
                      ? drop.value!.after
                      : null,
                  onHover: (after) =>
                      drop.value = (id: collection.id, after: after),
                  onLeave: () {
                    if (drop.value?.id == collection.id) {
                      drop.value = null;
                    }
                  },
                  onDrop: drag,
                ),
              ],
              if (hidden.isNotEmpty) ...[
                const SizedBox(width: _tabGap),
                Builder(
                  builder: (buttonContext) => InkWell(
                    onTap: () {
                      final box =
                          buttonContext.findRenderObject()! as RenderBox;
                      showRevericContextMenu(
                        context: context,
                        position: box.localToGlobal(
                          Offset(0, box.size.height + RevericSpacing.xs),
                        ),
                        minWidth: 200,
                        entries: [
                          for (final collection in hidden)
                            RevericMenuItem(
                              label: collectionLabel(context, collection),
                              onTap: () => location.open(collection.id),
                              trailing: counts[collection.id] == null
                                  ? null
                                  : Text(
                                      '${counts[collection.id]}',
                                      style: typo.uiTiny.copyWith(
                                        color: colors.textSubtle,
                                      ),
                                    ),
                            ),
                        ],
                      );
                    },
                    child: SizedBox(
                      height: _tabHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: RevericSpacing.md,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              context.t(LocaleKeys.libraryCollectionMore),
                              style: typo.ui.copyWith(color: colors.textMuted),
                            ),
                            const SizedBox(width: _tabGap),
                            Text(
                              '${hidden.length}',
                              style: typo.uiTiny.copyWith(
                                color: colors.textSubtle,
                              ),
                            ),
                            const SizedBox(width: _tabGap),
                            RevericIcon(
                              RevericIcons.expand_more,
                              size: 12,
                              color: colors.textMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              _AddButton(location: location, size: 28),
            ],
          ),
        );
      },
    );
  }
}

/// 桌面标签：点击切换、右键出菜单；非全部的标签可拖，任何标签都能作为落点，
/// 但落到全部左侧会被 [moveCollection] 夹回第二位。
class _DesktopTab extends StatelessWidget {
  const _DesktopTab({
    super.key,
    required this.location,
    required this.collection,
    required this.count,
    required this.nameMaxWidth,
    required this.dropAfter,
    required this.onHover,
    required this.onLeave,
    required this.onDrop,
  });
  final CollectionLocation location;
  final LibraryCollection collection;
  final int? count;
  final double nameMaxWidth;
  final bool? dropAfter;
  final ValueChanged<bool> onHover;
  final VoidCallback onLeave;
  final ValueChanged<String> onDrop;
  @override
  Widget build(BuildContext context) {
    final active = collection.id == location.current?.id;
    final label = collectionLabel(context, collection);
    final tab = GestureDetector(
      onSecondaryTapUp: (details) => showCollectionMenu(
        context,
        location,
        collection,
        position: details.globalPosition,
      ),
      child: InkWell(
        onTap: () => location.open(collection.id),
        child: _Tab(
          label: label,
          count: count,
          active: active,
          nameMaxWidth: nameMaxWidth,
          dropAfter: dropAfter,
        ),
      ),
    );
    final target = DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != collection.id,
      onMove: (details) {
        final box = context.findRenderObject()! as RenderBox;
        final local = box.globalToLocal(details.offset);
        onHover(local.dx >= box.size.width / 2);
      },
      onLeave: (_) => onLeave(),
      onAcceptWithDetails: (details) => onDrop(details.data),
      builder: (context, _, _) => tab,
    );
    if (collection.builtin) {
      return target;
    }
    return Draggable<String>(
      data: collection.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: RevericTheme.colorsOf(context).surface,
        elevation: 4,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: _Tab(label: label, count: count, active: active),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: target),
      child: target,
    );
  }
}

class _MobileTabs extends HookWidget {
  const _MobileTabs({required this.location});
  final CollectionLocation location;
  @override
  Widget build(BuildContext context) {
    final all = location.collections.value ?? [];
    final counts = location.counts.value ?? const {};
    final currentId = location.current?.id;
    final currentKey = useMemoized(GlobalKey.new, [currentId]);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    // 仅滚动横向标签栏；跨祖先 ensureVisible 会连带把书架纵向位置拉回顶部。
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = currentKey.currentContext;
        if (target != null && target.mounted) {
          Scrollable.of(target, axis: Axis.horizontal).position.ensureVisible(
            target.findRenderObject()!,
            alignment: 0.5,
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 200),
          );
        }
      });
      return null;
    }, [currentId, reduceMotion]);
    return SingleChildScrollView(
      // 横向位置必须独立存储，不能覆盖外层书架的纵向 PageStorage 位置。
      key: const PageStorageKey('collection-tabs'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: Row(
        children: [
          for (final collection in all)
            InkWell(
              key: ValueKey('collection-${collection.id}'),
              onTap: () => location.open(collection.id),
              // 全部也要接住长按，否则松手会被当成一次点击。
              onLongPress: () =>
                  showCollectionMenu(context, location, collection),
              child: KeyedSubtree(
                key: collection.id == currentId ? currentKey : null,
                child: _Tab(
                  label: collectionLabel(context, collection),
                  count: counts[collection.id],
                  active: collection.id == currentId,
                  horizontalPadding: 11,
                  nameMaxWidth: 120,
                ),
              ),
            ),
          _AddButton(location: location, size: _tabHeight),
        ],
      ),
    );
  }
}
