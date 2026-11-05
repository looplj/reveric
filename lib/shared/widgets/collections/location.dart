// 职责: 管理集合浏览范围，两端都在书架内就地切换集合，不再进入集合详情页。
// 关联文件:
//   lib/shared/providers/novel_collection_providers.dart
//   lib/shared/models/novel_collection.dart
//   lib/shared/widgets/collections/shelf.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../components/reveric_button.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/novel_collection.dart';
import '../../models/novel.dart';
import '../../providers/novel_collection_providers.dart';
import '../../theme/theme.dart';

class CollectionLocation {
  const CollectionLocation({
    required this.contentKind,
    required this.mobile,
    required this.collections,
    required this.current,
    required this.works,
    required this.counts,
    required this.onOpen,
    required this.onBack,
  });

  /// 当前库的作品类型；[collections] 只含本库可见的集合。
  final String contentKind;
  final bool mobile;
  final AsyncValue<List<LibraryCollection>> collections;
  final LibraryCollection? current;
  final AsyncValue<List<Novel>> works;
  final AsyncValue<Map<String, int?>> counts;
  final ValueChanged<String> onOpen;
  final VoidCallback onBack;
  void open(String id) => onOpen(id);

  /// 回到全部。
  void back() => onBack();
}

class LibraryCollectionRegion extends HookConsumerWidget {
  const LibraryCollectionRegion({
    super.key,
    required this.contentKind,
    this.mobile = false,
    this.initialCollectionId,
    required this.builder,
    this.onChange,
  });

  /// 当前库的作品类型：只列共用集合和本类型集合，作品与计数也按它筛选。
  final String contentKind;
  final bool mobile;

  /// 旧的集合路由落到书架时预选的集合。
  final String? initialCollectionId;
  final VoidCallback? onChange;
  final Widget Function(BuildContext, CollectionLocation) builder;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = useState<String?>(initialCollectionId);
    final collections = ref
        .watch(orderedCollectionsProvider)
        .whenData((all) => all.where((c) => c.visibleIn(contentKind)).toList());
    final counts = ref.watch(collectionCountsProvider(contentKind));
    final builtin = collections.value
        ?.where((c) => c.builtin && c.unavailableReason == null)
        .toList();
    final id =
        selectedId.value ?? (builtin?.length == 1 ? builtin!.single.id : null);
    final current = collections.value?.where((c) => c.id == id).firstOrNull;
    final watchedWorks = id == null
        ? const AsyncValue<List<Novel>>.data([])
        : ref.watch(collectionWorksProvider(id, contentKind));
    // 换类型或集合是一条新查询；加载期间沿用上一份结果，别让作品区闪成加载态。
    final lastWorks = useRef<List<Novel>?>(null);
    if (watchedWorks.hasValue) {
      lastWorks.value = watchedWorks.value;
    }
    final previous = lastWorks.value;
    final works = watchedWorks.isLoading && previous != null
        ? AsyncValue<List<Novel>>.data(previous)
        : watchedWorks;
    void back() {
      if (!context.mounted) {
        return;
      }
      onChange?.call();
      selectedId.value = builtin?.singleOrNull?.id;
    }

    if (current == null || builtin?.length != 1) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (collections.isLoading)
              const CircularProgressIndicator()
            else
              Text(
                context.t(
                  collections.hasError
                      ? LocaleKeys.libraryCollectionLoadFailed
                      : builtin?.length != 1
                      ? LocaleKeys.libraryCollectionInitializationFailed
                      : LocaleKeys.libraryCollectionMissing,
                ),
              ),
            if (!collections.isLoading && builtin?.length == 1) ...[
              const SizedBox(height: RevericSpacing.lg),
              RevericButton.secondary(
                label: context.t(LocaleKeys.libraryAll),
                icon: RevericIcons.arrow_back,
                onPressed: back,
              ),
            ],
          ],
        ),
      );
    }
    return builder(
      context,
      CollectionLocation(
        contentKind: contentKind,
        mobile: mobile,
        collections: collections,
        current: current,
        works: works,
        counts: counts,
        onOpen: (id) {
          if (current.id != id) {
            onChange?.call();
            selectedId.value = id;
          }
        },
        onBack: back,
      ),
    );
  }
}
