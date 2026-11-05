// 职责: 为两端作品操作菜单提供加入集合、移出当前手动集合的操作。
// 关联文件:
//   lib/shared/widgets/collections/membership_picker.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../components/reveric_context_menu.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/novel.dart';
import '../../models/novel_collection.dart';
import '../../providers/novel_providers.dart';
import '../../theme/theme.dart';
import 'membership_picker.dart';

/// 书架当前选中的集合，作品菜单据此决定是否提供「移出集合」。
class CurrentCollectionScope extends InheritedWidget {
  const CurrentCollectionScope({
    super.key,
    required this.collection,
    required super.child,
  });
  final LibraryCollection? collection;
  static LibraryCollection? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CurrentCollectionScope>()
      ?.collection;
  @override
  bool updateShouldNotify(CurrentCollectionScope oldWidget) =>
      oldWidget.collection?.id != collection?.id ||
      oldWidget.collection?.manual != collection?.manual;
}

List<RevericMenuItem> collectionWorkMenuItems(
  BuildContext context,
  Novel novel, {
  bool mobile = false,
  Offset? position,
}) {
  if (novel.draft) {
    return [];
  }
  final current = CurrentCollectionScope.maybeOf(context);
  return [
    RevericMenuItem(
      label: context.t(LocaleKeys.libraryCollectionAddTo),
      icon: RevericIcons.stack,
      onTap: () => showCollectionMembership(
        context,
        mobile: mobile,
        workIds: {novel.id},
        contentKind: novel.contentKind,
        position: position,
      ),
    ),
    if (current case final collection? when collection.manual)
      RevericMenuItem(
        label: context.t(LocaleKeys.libraryCollectionRemove),
        icon: RevericIcons.remove,
        onTap: () => removeCollectionWorks(context, collection.id, {novel.id}),
      ),
  ];
}

Future<bool> removeCollectionWorks(
  BuildContext context,
  String id,
  Set<String> workIds,
) async {
  try {
    await ProviderScope.containerOf(context, listen: false)
        .read(appDatabaseProvider)
        .novelCollectionDao
        .setMembership(id, workIds, included: false);
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.t(LocaleKeys.libraryCollectionFailed))),
      );
    }
    return false;
  }
}
