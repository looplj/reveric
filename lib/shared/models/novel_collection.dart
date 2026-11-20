// 职责: 表达集合定义与规则可用状态，规范持久化导航顺序和成员三态。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/queries/collection_filter.dart
//   lib/shared/providers/novel_collection_providers.dart
import '../database/app_database.dart';
import '../database/queries/collection_filter.dart';

class LibraryCollection {
  LibraryCollection(this.record) {
    try {
      validateCollectionConfiguration(record);
    } on FormatException catch (error) {
      unavailableReason = error.message;
    }
  }
  final NovelCollection record;
  String? unavailableReason;
  String get id => record.id;
  String get name => record.name;
  bool get builtin => record.builtin;

  /// null 表示各库共用，目前只有内置「全部」。
  String? get contentKind => record.contentKind;

  /// 是否出现在 [kind] 这个库里。
  bool visibleIn(String kind) => contentKind == null || contentKind == kind;
  bool get manual =>
      !builtin && record.filterMode == 'manual' && unavailableReason == null;
}

bool? collectionMembership(Set<String> members, Iterable<String> ids) {
  final selected = ids.toSet();
  final hits = selected.intersection(members).length;
  if (hits == 0) {
    return false;
  }
  return hits == selected.length ? true : null;
}

List<LibraryCollection> orderCollections(
  List<LibraryCollection> definitions,
  List<String>? saved,
) {
  final all = definitions.toList()
    ..sort((a, b) {
      final time = a.record.createdAt.compareTo(b.record.createdAt);
      return time == 0 ? a.id.compareTo(b.id) : time;
    });
  final byId = {for (final collection in all) collection.id: collection};
  final ordered = <LibraryCollection>[];
  void add(String id) {
    final collection = byId.remove(id);
    if (collection != null) {
      ordered.add(collection);
    }
  }

  for (final collection in all.where((c) => c.builtin)) {
    add(collection.id);
  }
  for (final id
      in saved ??
          const [
            'collection:in_progress',
            'collection:finished',
            'collection:novel:in_progress',
            'collection:novel:finished',
            'collection:screenplay:in_progress',
            'collection:screenplay:finished',
            'collection:canvas:in_progress',
            'collection:canvas:archived',
          ]) {
    add(id);
  }
  ordered.addAll(byId.values);
  return ordered;
}
