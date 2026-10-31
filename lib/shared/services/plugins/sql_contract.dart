// 职责: 校验插件私有 SQL 的 AST 契约和桥接值，保留软删除与宿主迁移账本边界。
// 关联文件:
//   lib/shared/services/plugins/sqlite_worker.dart
//   lib/shared/services/plugins/sqlite.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:sqlparser/sqlparser.dart';

const pluginSqlPayloadLimit = 1024 * 1024;
const pluginSqlSafeInteger = 9007199254740991;

class PluginSqlError implements Exception {
  PluginSqlError(this.code, this.message, {this.details = const {}});
  final String code, message;
  final Map<String, Object?> details;
  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    ...details,
  };
  @override
  String toString() => jsonEncode(toJson());
}

Never _reject(String message) => throw PluginSqlError('invalid_sql', message);

Object? decodeSqlValue(Object? value) {
  if (value == null || value is String) {
    return value;
  }
  if (value is num) {
    if (!value.isFinite ||
        (value == value.truncateToDouble() &&
            (value > pluginSqlSafeInteger || value < -pluginSqlSafeInteger))) {
      throw PluginSqlError(
        'invalid_argument',
        'Use bigint for unsafe integers; numbers must be finite',
      );
    }
    return value;
  }
  if (value is Map && value.length == 2 && value['value'] is String) {
    final payload = value['value'] as String;
    if (value['__revericSql'] == 'int64') {
      final n = BigInt.tryParse(payload);
      if (n == null || n < -(BigInt.one << 63) || n >= (BigInt.one << 63)) {
        throw PluginSqlError(
          'invalid_argument',
          'Integer exceeds signed 64-bit range',
        );
      }
      return n.toInt();
    }
    if (value['__revericSql'] == 'blob') {
      try {
        return base64Decode(payload);
      } on FormatException {
        throw PluginSqlError('invalid_argument', 'Invalid BLOB base64');
      }
    }
  }
  throw PluginSqlError(
    'invalid_argument',
    'SQL value must be null, string, number, bigint or Uint8Array',
  );
}

Object? encodeSqlValue(Object? value) {
  if (value is int &&
      (value > pluginSqlSafeInteger || value < -pluginSqlSafeInteger)) {
    return {'__revericSql': 'int64', 'value': value.toString()};
  }
  if (value is Uint8List) {
    return {'__revericSql': 'blob', 'value': base64Encode(value)};
  }
  if (value is double && !value.isFinite) {
    throw PluginSqlError('invalid_result', 'SQL returned non-finite REAL');
  }
  return value;
}

Iterable<AstNode> _walk(AstNode node) sync* {
  yield node;
  for (final child in node.childNodes) {
    yield* _walk(child);
  }
}

void _name(String name) {
  if (name.toLowerCase().startsWith('_reveric') ||
      name.toLowerCase().startsWith('sqlite_')) {
    _reject('Host/system tables are not available');
  }
}

Statement validatePluginSql(
  String sql, {
  required bool query,
  bool migration = false,
}) {
  if (utf8.encode(sql).length > pluginSqlPayloadLimit) {
    _reject('SQL exceeds 1 MB');
  }
  final parsed = SqlEngine().parse(ParserEntrypoint.statement, sql);
  if (parsed.errors.isNotEmpty) {
    _reject(parsed.errors.map((e) => e.message).join('; '));
  }
  final root = parsed.rootNode;
  if (query) {
    if (root is! BaseSelectStatement) {
      _reject('query requires SELECT');
    }
  } else if (root is InsertStatement) {
    if (root.mode == InsertMode.replace ||
        root.mode == InsertMode.insertOrReplace ||
        root.upsert != null ||
        root.returning != null) {
      _reject('REPLACE, UPSERT and RETURNING are not supported');
    }
  } else if (root is UpdateStatement) {
    if (root.or == FailureMode.replace || root.returning != null) {
      _reject('REPLACE and RETURNING are not supported');
    }
  } else if (migration && root is CreateTableStatement) {
    _name(root.tableName);
    if (root.columns.isEmpty || root.isStrict || root.withoutRowId) {
      _reject('Migration tables require ordinary columns');
    }
  } else if (migration && root is CreateIndexStatement) {
    _name(root.indexName);
  } else if (migration &&
      root is AlterTableStatement &&
      root.instruction is AddColumn) {
    // Additive column migration only.
  } else {
    _reject('Only INSERT/UPDATE, or additive migration DDL, are allowed');
  }
  for (final node in _walk(root)) {
    if (node is TableReference) {
      _name(node.tableName);
      if (node.schemaName != null) {
        _reject('Schema-qualified tables are not supported');
      }
    }
    if (node is NamedVariable) {
      _reject('Only positional parameters are supported');
    }
    if (node is SqlInvocation) {
      final name = node.name.toLowerCase();
      if (name.startsWith('pragma_') ||
          const {
            'load_extension',
            'readfile',
            'writefile',
            'edit',
            'fts3_tokenizer',
          }.contains(name)) {
        _reject('File/extension/pragma functions are unavailable');
      }
    }
    if (node is CollateExpression) {
      _reject('Custom collation is unavailable');
    }
    if (node is ColumnConstraint) {
      if (node is Default ||
          (node is NotNull && node.onConflict == null) ||
          (node is PrimaryKeyColumn &&
              !node.autoIncrement &&
              node.onConflict == null)) {
        continue;
      }
      _reject('Only defaults, nullability and primary key columns are allowed');
    }
    if (node is TableConstraint &&
        !(node is KeyClause && node.isPrimaryKey && node.onConflict == null)) {
      _reject('Only primary key table declarations are allowed');
    }
  }
  return root;
}

List<String> pluginMigrationStatements(String source) {
  final parsed = SqlEngine().parse(ParserEntrypoint.multiple, source);
  if (parsed.errors.isNotEmpty) {
    _reject(parsed.errors.map((e) => e.message).join('; '));
  }
  return [
    for (final statement in parsed.rootNode.statements) statement.span!.text,
  ];
}
