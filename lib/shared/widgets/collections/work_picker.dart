// 职责: 从同类型书架中搜索并批量添加作品，已加入成员只读显示。
// 关联文件:
//   lib/shared/widgets/collections/surface.dart
//   lib/shared/widgets/collections/cover.dart
//   lib/shared/providers/novel_collection_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_checkbox.dart';
import '../../components/reveric_search_field.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/novel.dart';
import '../../providers/novel_providers.dart';
import '../../providers/novel_collection_providers.dart';
import '../../theme/theme.dart';
import 'cover.dart';
import 'surface.dart';

Future<void> showCollectionWorkPicker(
  BuildContext context, {
  required bool mobile,
  required String collectionId,
  required String contentKind,
}) => showCollectionSurface<void>(
  context,
  mobile: mobile,
  builder: (_) => _WorkPicker(
    mobile: mobile,
    collectionId: collectionId,
    contentKind: contentKind,
  ),
);

class _WorkPicker extends HookConsumerWidget {
  const _WorkPicker({
    required this.mobile,
    required this.collectionId,
    required this.contentKind,
  });
  final bool mobile;
  final String collectionId;

  /// 集合所在库的作品类型，只列这一类作品。
  final String contentKind;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = useDebouncedSearch();
    final selected = useState(<String>{});
    final busy = useState(false);
    final error = useState(false);
    final collections = ref.watch(novelCollectionsProvider);
    final novels = ref.watch(novelsProvider);
    final collection = collections.value
        ?.where((c) => c.id == collectionId)
        .firstOrNull;
    final available =
        novels.value?.shelfVisible
            .where((n) => n.contentKind == contentKind)
            .toList() ??
        <Novel>[];
    final memberships = ref.watch(
      collectionMembershipsProvider(
        collectionWorkIdsKey(available.map((n) => n.id)),
      ),
    );
    final memberIds = memberships.value?[collectionId] ?? <String>{};
    final picked = selected.value
        .intersection(available.map((n) => n.id).toSet())
        .difference(memberIds);
    final visible =
        available
            .where((n) => n.title.toLowerCase().contains(search.query))
            .toList()
          ..sort(
            (a, b) => (memberIds.contains(a.id) ? 1 : 0).compareTo(
              memberIds.contains(b.id) ? 1 : 0,
            ),
          );
    Future<void> add() async {
      if (busy.value || picked.isEmpty || collection == null) {
        return;
      }
      busy.value = true;
      try {
        await ref
            .read(appDatabaseProvider)
            .novelCollectionDao
            .setMembership(collectionId, picked, included: true);
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      } catch (_) {
        if (context.mounted) {
          error.value = true;
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    return PopScope(
      canPop: !busy.value,
      child: CollectionSurface(
        mobile: mobile,
        title: context.t(LocaleKeys.libraryCollectionAddWorks),
        actions: [
          Text(
            context.t(
              LocaleKeys.libraryCollectionSelected,
              namedArgs: {'count': '${picked.length}'},
            ),
          ),
          RevericButton.primary(
            label: context.t(LocaleKeys.commonAdd),
            loading: busy.value,
            onPressed:
                picked.isEmpty ||
                    !memberships.hasValue ||
                    collection?.manual != true
                ? null
                : add,
          ),
        ],
        child: SizedBox(
          height: 400,
          child: Column(
            children: [
              RevericSearchField(
                controller: search.controller,
                hint: context.t(LocaleKeys.librarySearchPlaceholder),
              ),
              const SizedBox(height: RevericSpacing.md),
              Expanded(
                child:
                    collections.hasError ||
                        novels.hasError ||
                        memberships.hasError
                    ? Center(
                        child: Text(
                          context.t(LocaleKeys.libraryCollectionLoadFailed),
                        ),
                      )
                    : !collections.hasValue ||
                          !novels.hasValue ||
                          !memberships.hasValue
                    ? const Center(child: CircularProgressIndicator())
                    : collection == null
                    ? Center(
                        child: Text(
                          context.t(LocaleKeys.libraryCollectionMissing),
                        ),
                      )
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final work = visible[index];
                          final already = memberIds.contains(work.id);
                          void select() {
                            final next = {...selected.value};
                            if (!next.add(work.id)) {
                              next.remove(work.id);
                            }
                            selected.value = next;
                          }

                          return MergeSemantics(
                            child: ListTile(
                              enabled: !already && !busy.value,
                              onTap: already || busy.value ? null : select,
                              leading: SizedBox(
                                width: 36,
                                height: 48,
                                child: CollectionWorkCover(work: work),
                              ),
                              title: Text(
                                work.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: already
                                  ? Text(
                                      context.t(
                                        LocaleKeys
                                            .libraryCollectionAlreadyAdded,
                                      ),
                                    )
                                  : null,
                              trailing: RevericCheckbox(
                                value: already || picked.contains(work.id),
                                onChanged: already || busy.value
                                    ? null
                                    : (_) => select(),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (error.value)
                Text(context.t(LocaleKeys.libraryCollectionFailed)),
            ],
          ),
        ),
      ),
    );
  }
}
