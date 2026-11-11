// 职责: 在同一事务内幂等初始化作品库默认集合，并按作品类型补种状态集合。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/queries/collection_filter.dart
//   lib/shared/services/app_initialization.dart
//   lib/shared/models/content_kind.dart
//   lib/shared/models/content_status.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
import 'package:drift/drift.dart';
import 'package:easy_localization/easy_localization.dart';
import '../../database/app_database.dart';
import '../../database/queries/collection_filter.dart';
import '../../models/collections/filter.dart';
import '../../models/content_kind.dart';
import '../../models/content_status.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';

final _log = AppLogger.forModule('CollectionSeeds');

Future<void> seedDefaultCollections(AppDatabase database) async {
  final keys = {
    'all': LocaleKeys.libraryAll,
    'in_progress': LocaleKeys.libraryStatusInProgress,
    'finished': LocaleKeys.libraryStatusFinished,
  };
  final names = {for (final entry in keys.entries) entry.key: tr(entry.value)};
  if (keys.entries.any((entry) => names[entry.key] == entry.value)) {
    throw StateError(
      'Collection seed translations must be loaded before initialization',
    );
  }
  await seedCollections(database, names: names);
}

Future<void> seedCollections(
  AppDatabase database, {
  required Map<String, String> names,
}) async {
  try {
    await database.transaction(() async {
      for (final seed in ['all', 'in_progress', 'finished']) {
        final id = 'collection:$seed';
        final existing = await (database.select(
          database.novelCollections,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (existing != null) {
          continue;
        }
        final name = names[seed];
        if (name == null || name.isEmpty) {
          throw StateError('Missing localized collection seed name: $seed');
        }
        await database
            .into(database.novelCollections)
            .insert(
              NovelCollectionsCompanion.insert(
                id: id,
                name: name,
                builtin: Value(seed == 'all'),
                filterMode: const Value('rule'),
                filter: Value(
                  seed == 'all'
                      ? null
                      : CollectionFilter.fromRoot(
                          CollectionCompare('novel.status', 'eq', seed),
                        ),
                ),
              ),
            );
      }
      final protected =
          await (database.select(database.novelCollections)..where(
                (t) =>
                    t.builtin.equals(true) &
                    t.deletedAt.equals(notDeletedSentinel),
              ))
              .get();
      if (protected.length != 1 || protected.single.id != 'collection:all') {
        throw StateError('Expected exactly one active builtin collection');
      }
      validateCollectionConfiguration(protected.single);
    });
  } catch (error, stackTrace) {
    _log.error(
      '[DB][novel_collections][INSERT] id=default_collections_v1',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

/// 软删除没有作品类型、且不是内置「全部」的集合。
///
/// 早期状态集合不带 [NovelCollections.contentKind]，小说、剧本、画布三个库都会显示。
/// 已有行和成员只标删除，不物理删除。
Future<void> removeUnscopedCollections(AppDatabase database) async {
  try {
    final rows =
        await (database.select(database.novelCollections)..where(
              (t) =>
                  t.builtin.equals(false) &
                  t.contentKind.isNull() &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .get();
    for (final row in rows) {
      await database.novelCollectionDao.softDelete(row.id);
    }
  } catch (error, stackTrace) {
    _log.error(
      '[DB][novel_collections][UPDATE_SOFT_DELETE] id=unscoped',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

class _KindStatusSeed {
  const _KindStatusSeed({
    required this.id,
    required this.nameKey,
    required this.contentKind,
    required this.status,
  });

  final String id;
  final String nameKey;
  final String contentKind;
  final String status;
}

const _kindStatusSeeds = <_KindStatusSeed>[
  _KindStatusSeed(
    id: 'collection:novel:in_progress',
    nameKey: LocaleKeys.libraryStatusInProgress,
    contentKind: contentKindNovel,
    status: contentStatusInProgress,
  ),
  _KindStatusSeed(
    id: 'collection:novel:finished',
    nameKey: LocaleKeys.libraryStatusFinished,
    contentKind: contentKindNovel,
    status: contentStatusFinished,
  ),
  _KindStatusSeed(
    id: 'collection:screenplay:in_progress',
    nameKey: LocaleKeys.libraryStatusInProgress,
    contentKind: contentKindScreenplay,
    status: contentStatusInProgress,
  ),
  _KindStatusSeed(
    id: 'collection:screenplay:finished',
    nameKey: LocaleKeys.libraryStatusFinished,
    contentKind: contentKindScreenplay,
    status: contentStatusFinished,
  ),
  _KindStatusSeed(
    id: 'collection:canvas:in_progress',
    nameKey: LocaleKeys.libraryStatusActive,
    contentKind: contentKindCanvas,
    status: contentStatusInProgress,
  ),
  _KindStatusSeed(
    id: 'collection:canvas:archived',
    nameKey: LocaleKeys.libraryStatusArchived,
    contentKind: contentKindCanvas,
    status: contentStatusArchived,
  ),
];

Future<void> seedKindStatusCollections(AppDatabase database) async {
  final names = {
    for (final seed in _kindStatusSeeds) seed.id: tr(seed.nameKey),
  };
  if (_kindStatusSeeds.any((seed) => names[seed.id] == seed.nameKey)) {
    throw StateError(
      'Collection seed translations must be loaded before initialization',
    );
  }
  await insertKindStatusCollections(database, names: names);
}

/// 按作品类型写入状态集合。id 已存在（含软删除）时保留原记录，不覆盖名称和筛选。
Future<void> insertKindStatusCollections(
  AppDatabase database, {
  required Map<String, String> names,
}) async {
  try {
    await database.transaction(() async {
      for (final seed in _kindStatusSeeds) {
        final existing = await (database.select(
          database.novelCollections,
        )..where((t) => t.id.equals(seed.id))).getSingleOrNull();
        if (existing != null) {
          continue;
        }
        final name = names[seed.id];
        if (name == null || name.isEmpty) {
          throw StateError(
            'Missing localized collection seed name: ${seed.id}',
          );
        }
        await database
            .into(database.novelCollections)
            .insert(
              NovelCollectionsCompanion.insert(
                id: seed.id,
                name: name,
                filterMode: const Value('rule'),
                filter: Value(
                  CollectionFilter.fromRoot(
                    CollectionCompare('novel.status', 'eq', seed.status),
                  ),
                ),
                contentKind: Value(seed.contentKind),
              ),
            );
      }
    });
  } catch (error, stackTrace) {
    _log.error(
      '[DB][novel_collections][INSERT] id=kind_status_collections_v1',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}
