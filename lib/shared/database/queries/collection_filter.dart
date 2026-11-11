// 职责: 将已校验集合条件编译为参数绑定的 SQL 谓词，固定基础作品范围并可按类型筛选。
// 关联文件:
//   lib/shared/models/collections/filter.dart
//   lib/shared/models/collections/fields.dart
//   lib/shared/database/daos/novel_collection_dao.dart
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import '../../models/collections/filter.dart';
import '../../models/collections/fields.dart';
import '../../models/content_kind.dart';
import '../app_database.dart';

class CollectionPredicate {
  const CollectionPredicate(this.sql, this.variables);
  final String sql;
  final List<Variable> variables;
}

class CollectionFilterCompiler {
  const CollectionFilterCompiler({
    this.fields = collectionFields,
    this.columns = const {
      'novel.status': 'status',
      'novel.type': 'type',
      'novel.category': 'category',
      'novel.tags': 'tags',
      'novel.title': 'title',
      'novel.word_count': 'word_count',
    },
  });
  final Map<String, CollectionField> fields;
  // Trusted schema mapping supplied by code, never by the saved document.
  final Map<String, String> columns;

  /// [contentKind] 是浏览时的类型筛选，null 表示小说与剧本都包含。
  CollectionPredicate compile({
    String? contentKind,
    CollectionFilter? filter,
    String? manualId,
  }) {
    if (contentKind != null) {
      validateContentKind(contentKind);
    }
    final variables = <Variable>[];
    String bind(Object value) {
      variables.add(
        value is int ? Variable<int>(value) : Variable<String>(value as String),
      );
      return '?';
    }

    String compare(CollectionCompare c) {
      final column = columns[c.field];
      if (column == null || !RegExp(r'^[a-z_]+$').hasMatch(column)) {
        throw FormatException(
          'Unsupported collection field mapping: ${c.field}',
        );
      }
      final field = 'n."$column"';
      final tags = fields[c.field]!.type == CollectionValueType.tags;
      return switch (c.op) {
        'eq' => '$field = ${bind(c.value!)} COLLATE BINARY',
        'neq' => '$field != ${bind(c.value!)} COLLATE BINARY',
        'gt' => '$field > ${bind(c.value!)}',
        'gte' => '$field >= ${bind(c.value!)}',
        'lt' => '$field < ${bind(c.value!)}',
        'lte' => '$field <= ${bind(c.value!)}',
        'contains' when tags =>
          'EXISTS (SELECT 1 FROM json_each($field) AS tag WHERE tag.value = ${bind(c.value!)} COLLATE BINARY)',
        'contains' => 'instr($field, ${bind(c.value!)}) > 0',
        'starts_with' => 'instr($field, ${bind(c.value!)}) = 1',
        'ends_with' =>
          'substr($field, -length(${bind(c.value!)})) = ${bind(c.value!)} COLLATE BINARY',
        'is_empty' => tags ? 'json_array_length($field) = 0' : "$field = ''",
        'is_not_empty' =>
          tags ? 'json_array_length($field) > 0' : "$field != ''",
        _ => throw FormatException('Unsupported collection operator: ${c.op}'),
      };
    }

    String node(CollectionCondition condition) => switch (condition) {
      CollectionGroup(:final any, :final items) =>
        '(${items.map(node).join(any ? ' OR ' : ' AND ')})',
      CollectionNot(:final item) => '(NOT ${node(item)})',
      CollectionCompare() => compare(condition),
    };
    var sql = 'n.deleted_at = 0 AND n.draft = 0';
    if (defaultTargetPlatform == TargetPlatform.android) {
      sql += ' AND n.content_kind <> ${bind(contentKindCanvas)}';
    }
    if (contentKind != null) {
      sql += ' AND n.content_kind = ${bind(contentKind)}';
    }
    if (manualId != null) {
      sql +=
          ' AND EXISTS (SELECT 1 FROM novel_collection_members AS m WHERE m.novel_id = n.id AND m.collection_id = ${bind(manualId)} AND m.deleted_at = 0)';
    }
    if (filter != null) {
      final checked = CollectionFilter.parse(filter.raw, fields: fields);
      checked.requireValid();
      sql += ' AND (${node(checked.root!)})';
    }
    return CollectionPredicate(sql, variables);
  }

  CollectionPredicate forCollection(
    NovelCollection collection, {
    String? contentKind,
  }) {
    validateCollectionConfiguration(collection);
    return compile(
      contentKind: contentKind,
      filter: collection.filter,
      manualId: collection.filterMode == 'manual' ? collection.id : null,
    );
  }
}

void validateCollectionConfiguration(NovelCollection collection) {
  if (collection.contentKind case final kind? when !isValidContentKind(kind)) {
    throw const FormatException('Invalid collection content kind');
  }
  if (collection.builtin) {
    if (collection.filterMode != 'rule' || collection.filter != null) {
      throw const FormatException('Invalid builtin collection');
    }
  } else if (collection.filterMode == 'manual') {
    if (collection.filter != null) {
      throw const FormatException('Manual collection cannot contain a filter');
    }
  } else if (collection.filterMode == 'rule') {
    if (collection.filter == null) {
      throw const FormatException('Rule collection requires a filter');
    }
    collection.filter!.requireValid();
  } else {
    throw FormatException(
      'Unsupported collection mode: ${collection.filterMode}',
    );
  }
}
