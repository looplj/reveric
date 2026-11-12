// 职责: AppDatabase schema migration — 每个版本一个独立 method，按版本顺序执行。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/app_database_indexes.dart
//   lib/shared/database/queries/collection_filter.dart
// 遵循的 Rules:
//   .agents/rules/db-migration.md
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../models/collections/filter.dart';
import '../models/content_kind.dart';
import 'app_database.dart';
import 'app_database_indexes.dart';
import 'queries/collection_filter.dart';

/// AppDatabase schema migration 步骤集合。
///
/// 每个 `migrateToV{n}` 对应 `from < n` 的升级块，按版本号顺序在
/// [AppDatabase.migration] 的 `onUpgrade` 中调用。
class AppDatabaseMigrations {
  AppDatabaseMigrations(this.db);

  final AppDatabase db;

  /// v6: 同次图片任务的有序候选结果。
  Future<void> migrateToV6(Migrator m) =>
      m.addColumn(db.generationTasks, db.generationTasks.imageOutputs);

  /// v2: 插件注册表、插件存储与插件密钥。
  Future<void> migrateToV2(Migrator m) async {
    await m.createTable(db.pluginRegistry);
    await m.createTable(db.pluginStorage);
    await m.createTable(db.pluginSecrets);
  }

  /// v3: 插件权限与任务表；v2 建出的插件存储补软删除列；移除记忆表。
  Future<void> migrateToV3(Migrator m, {required int from}) async {
    await m.createTable(db.pluginPermissions);
    await m.createTable(db.pluginTasks);
    await createPluginTaskIndexes(m.database);
    if (from >= 2) {
      await m.addColumn(db.pluginStorage, db.pluginStorage.deletedAt);
    }
    await db.customStatement('DROP TABLE IF EXISTS memories');
  }

  /// v5: 普通上传与认证记录隔离，保存已完成上传的读取地址和有效期。
  Future<void> migrateToV5(Migrator m) async {
    await m.addColumn(db.providerAssets, db.providerAssets.kind);
    await m.addColumn(db.providerAssets, db.providerAssets.contextHash);
    await m.addColumn(db.providerAssets, db.providerAssets.remoteUrl);
    await m.addColumn(db.providerAssets, db.providerAssets.expiresAt);
  }

  /// v4: 集合按作品类型分开。
  Future<void> migrateToV4(Migrator m) async {
    if (!await _tableHasColumn('novel_collections', 'content_kind')) {
      await m.addColumn(db.novelCollections, db.novelCollections.contentKind);
    }
    await _splitCollectionsByContentKind();
  }

  /// 默认集合按状态筛选，两个库都适用，迁移后仍共用（content_kind 为 null）。
  static const _sharedCollectionIds = [
    'collection:all',
    'collection:in_progress',
    'collection:finished',
  ];

  /// schema v4：给其余集合定类型。按集合里现有作品（规则集合按命中作品）判断，
  /// 空集合归小说；小说和剧本混在一起的拆成两个同名集合——原集合留小说，
  /// 剧本成员移到新集合，导航顺序里新集合紧跟原集合。已删除的集合只定类型不拆。
  /// 只用 SQL 读写，不依赖之后可能变化的生成类。
  Future<void> _splitCollectionsByContentKind() async {
    final now = DateTime.now();
    final rows = await db
        .customSelect(
          'SELECT id, filter_mode, filter, deleted_at FROM novel_collections '
          'WHERE id NOT IN (${List.filled(_sharedCollectionIds.length, '?').join(',')})',
          variables: [for (final id in _sharedCollectionIds) Variable(id)],
        )
        .get();
    final splits = <String, String>{};
    for (final row in rows) {
      final id = row.read<String>('id');
      final deleted = row.read<int>('deleted_at') != 0;
      final kinds = await _collectionWorkKinds(
        id: id,
        manual: row.read<String>('filter_mode') == 'manual',
        rawFilter: row.readNullable<String>('filter'),
      );
      final split = !deleted && kinds.length > 1;
      final kind = kinds.length == 1 ? kinds.single : contentKindNovel;
      await db.customStatement(
        'UPDATE novel_collections SET content_kind = ? WHERE id = ?',
        [kind, id],
      );
      if (!split) {
        continue;
      }
      final copyId = const Uuid().v4();
      splits[id] = copyId;
      await db.customUpdate(
        'INSERT INTO novel_collections '
        '(id, name, builtin, filter_mode, filter, content_kind, created_at, updated_at, deleted_at) '
        'SELECT ?, name, builtin, filter_mode, filter, ?, created_at, ?, 0 '
        'FROM novel_collections WHERE id = ?',
        variables: [
          Variable(copyId),
          const Variable(contentKindScreenplay),
          Variable(now),
          Variable(id),
        ],
      );
      await db.customUpdate(
        'INSERT INTO novel_collection_members '
        '(collection_id, novel_id, created_at, updated_at, deleted_at) '
        'SELECT ?, m.novel_id, m.created_at, ?, 0 '
        'FROM novel_collection_members AS m JOIN novels AS n ON n.id = m.novel_id '
        'WHERE m.collection_id = ? AND m.deleted_at = 0 AND n.content_kind = ?',
        variables: [
          Variable(copyId),
          Variable(now),
          Variable(id),
          const Variable(contentKindScreenplay),
        ],
      );
      await db.customUpdate(
        'UPDATE novel_collection_members SET deleted_at = ?, updated_at = ? '
        'WHERE collection_id = ? AND deleted_at = 0 AND novel_id IN '
        '(SELECT id FROM novels WHERE content_kind = ?)',
        variables: [
          Variable(now),
          Variable(now),
          Variable(id),
          const Variable(contentKindScreenplay),
        ],
      );
    }
    if (splits.isEmpty) {
      return;
    }
    const orderKey = 'library.collection_order';
    final order = await db
        .customSelect(
          'SELECT value FROM app_settings WHERE key = ?',
          variables: [const Variable(orderKey)],
        )
        .getSingleOrNull();
    final saved = order == null
        ? null
        : jsonDecode(order.read<String>('value'));
    if (saved is! List) {
      return;
    }
    await db.customUpdate(
      'UPDATE app_settings SET value = ?, updated_at = ? WHERE key = ?',
      variables: [
        Variable(
          jsonEncode([
            for (final id in saved) ...[id, ?splits[id]],
          ]),
        ),
        Variable(now),
        const Variable(orderKey),
      ],
    );
  }

  /// 集合里在架作品涉及的类型；规则无法解析时按空集合处理。
  Future<Set<String>> _collectionWorkKinds({
    required String id,
    required bool manual,
    required String? rawFilter,
  }) async {
    if (!manual && rawFilter == null) {
      return {};
    }
    final CollectionPredicate predicate;
    try {
      predicate = const CollectionFilterCompiler().compile(
        manualId: manual ? id : null,
        filter: manual ? null : CollectionFilter.parse(rawFilter!),
      );
    } on FormatException {
      return {};
    }
    final rows = await db
        .customSelect(
          'SELECT DISTINCT n.content_kind AS kind FROM novels AS n WHERE ${predicate.sql}',
          variables: predicate.variables,
        )
        .get();
    return {for (final row in rows) row.read<String>('kind')};
  }

  Future<bool> _tableHasColumn(String table, String column) async {
    final quotedTable = table.replaceAll('"', '""');
    final rows = await db
        .customSelect('PRAGMA table_info("$quotedTable")')
        .get();
    return rows.any((row) => row.data['name'] == column);
  }
}
