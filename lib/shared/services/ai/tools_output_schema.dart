// 职责: 声明内置工具输出结构，并从资源定义生成 Read 按需返回契约。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_schema.dart
//   lib/shared/services/ai/tools_support.dart
part of 'tools.dart';

const _outputString = <String, dynamic>{'type': 'string'};
const _outputInteger = <String, dynamic>{'type': 'integer'};
const _outputBoolean = <String, dynamic>{'type': 'boolean'};
const _outputTrue = <String, dynamic>{'type': 'boolean', 'const': true};
const _outputFalse = <String, dynamic>{'type': 'boolean', 'const': false};

Map<String, dynamic> _outputObject(
  Map<String, dynamic> properties,
  List<String> required,
) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': true,
};

const _outputPagination = <String, dynamic>{
  'total': _outputInteger,
  'next_offset': _outputInteger,
  'limit': _outputInteger,
  'has_more': _outputBoolean,
};
const _outputTextPagination = <String, dynamic>{
  'total_lines': _outputInteger,
  'start_line': _outputInteger,
  'end_line': _outputInteger,
  'limit': _outputInteger,
  'has_more': _outputBoolean,
  'next_offset': _outputInteger,
};

/// 输出只描述读取形状；输入枚举校验、别名、引用与创建默认值不复制进输出。
Map<String, dynamic> _readValueSchema(_ValueSchema value) => {
  'type': value.nullable ? [value.type.name, 'null'] : value.type.name,
  if (value.type == _ValueType.object) ...{
    'properties': {
      for (final entry in value.objectProperties.entries)
        entry.key: _readValueSchema(entry.value.value),
    },
    'required': [
      for (final entry in value.objectProperties.entries)
        if (value.fieldReference != null &&
                (value.projection == _FieldProjection.detail ||
                    value.projection == _FieldProjection.listing)
            ? _requiredReadField(
                value.fieldReference![entry.key]!,
                value.projection == _FieldProjection.listing,
              )
            : entry.value.required)
          entry.key,
    ],
  },
  if (value.items != null) 'items': _readValueSchema(value.items!),
};

// 读取的必有性与创建必填无关；有条件可见的字段不作无条件 required。
bool _requiredReadField(_ResourceField field, bool listing) {
  final read = field.read!;
  return read.constraints.isEmpty &&
      (listing ? read.requiredInListing : read.requiredInDetail);
}

Map<String, dynamic> _resourceReadObject(
  _ResourceDefinition node, {
  required bool listing,
}) {
  final fields = node.project(
    listing ? _FieldProjection.listing : _FieldProjection.detail,
  );
  return _outputObject(
    {
      'path': _outputString,
      'work_id': _outputString,
      for (final entry in fields.entries)
        entry.key: _readValueSchema(entry.value.value),
    },
    [
      'path',
      for (final key in fields.keys)
        if (_requiredReadField(node.fields[key]!, listing)) key,
    ],
  );
}

/// 按需公开资源的精确返回字段，避免将全量资源字段常驻在 Read 工具描述中。
Map<String, dynamic> _resourceReadOutputSchema(
  _ResourceDefinition node,
  _ResourceOperation operation,
) {
  if (operation.target == _ResourceTargetKind.listing) {
    return _outputObject(
      {
        'type': {'const': 'listing'},
        'entries': {
          'type': 'array',
          'items': _resourceReadObject(node, listing: true),
        },
        ..._outputPagination,
      },
      ['type', 'entries'],
    );
  }
  if (operation.target == _ResourceTargetKind.field) {
    final field = operation.field!;
    final value = operation.result.value ?? node.fields[field]?.value;
    return _outputObject(
      {
        'value': value == null ? <String, dynamic>{} : _readValueSchema(value),
        ..._outputPagination,
        ..._outputTextPagination,
      },
      ['value'],
    );
  }
  final detail = _resourceReadObject(node, listing: false);
  if (node.documentType != null && node.segment != 'outlines') {
    final entry = _resourceReadObject(node, listing: true);
    return {
      'anyOf': [
        {
          ...detail,
          'properties': {
            ...detail['properties'] as Map,
            'is_folder': _outputFalse,
          },
        },
        _outputObject(
          {
            ...entry['properties'] as Map,
            'is_folder': _outputTrue,
            'type': {'const': 'folder'},
            'entries': {'type': 'array', 'items': entry},
            ..._outputPagination,
          },
          [...entry['required'] as List<String>, 'type', 'entries'],
        ),
      ],
    };
  }
  return detail;
}

const _outputStrings = <String, dynamic>{
  'type': 'array',
  'items': _outputString,
};
const _outputMap = <String, dynamic>{
  'type': 'object',
  'additionalProperties': true,
};
const _outputMaps = <String, dynamic>{'type': 'array', 'items': _outputMap};

/// 工具级静态输出契约；Read 的路径专属字段仍由 /_schema 按资源提供。
Map<String, dynamic> _builtinToolOutputSchema(String name) {
  final (properties, required) = switch (name) {
    'Read' => (
      <String, dynamic>{
        'path': _outputString,
        'type': _outputString,
        'entries': _outputMaps,
        'value': <String, dynamic>{},
        ..._outputPagination,
        ..._outputTextPagination,
      },
      <String>[],
    ),
    'Glob' => (
      <String, dynamic>{
        'matches': _outputStrings,
        'total': _outputInteger,
        'truncated': _outputBoolean,
        'scanned_paths': _outputInteger,
        'scan_limit': _outputInteger,
        'scan_truncated': _outputBoolean,
      },
      [
        'matches',
        'total',
        'truncated',
        'scanned_paths',
        'scan_limit',
        'scan_truncated',
      ],
    ),
    'Grep' => (
      <String, dynamic>{
        'text': _outputString,
        'truncated': _outputBoolean,
        'has_more': _outputBoolean,
        'next_offset': _outputInteger,
        'scanned_paths': _outputInteger,
        'scan_limit': _outputInteger,
        'scan_truncated': _outputBoolean,
        'searched_files': _outputInteger,
        'search_file_limit': _outputInteger,
        'search_truncated': _outputBoolean,
      },
      [
        'text',
        'truncated',
        'has_more',
        'scanned_paths',
        'scan_truncated',
        'searched_files',
        'search_truncated',
      ],
    ),
    'Create' || 'Write' => (
      <String, dynamic>{
        'path': _outputString,
        'id': _outputString,
        'created': _outputBoolean,
        'updated': _outputBoolean,
        'fields': _outputStrings,
        'ignored_fields': _outputStrings,
        'content_word_counts': _outputObject(
          {
            'with_punctuation': _outputInteger,
            'without_punctuation': _outputInteger,
          },
          ['with_punctuation', 'without_punctuation'],
        ),
      },
      name == 'Create' ? ['path'] : <String>[],
    ),
    'Edit' => (
      <String, dynamic>{
        'path': _outputString,
        'edited': _outputBoolean,
        'match_count': _outputInteger,
        'content_word_counts': _outputObject(
          {
            'with_punctuation': _outputInteger,
            'without_punctuation': _outputInteger,
          },
          ['with_punctuation', 'without_punctuation'],
        ),
      },
      ['edited', 'match_count'],
    ),
    'Replace' => (
      <String, dynamic>{
        'dry_run': _outputBoolean,
        'matched_fields': _outputInteger,
        'total_matches': _outputInteger,
        'samples': _outputStrings,
        'applied_fields': _outputInteger,
        'total_replacements': _outputInteger,
        'skipped_fields': _outputMap,
        'failed': {
          'type': 'object',
          'additionalProperties': _outputObject(
            {'count': _outputInteger, 'sample_paths': _outputStrings},
            ['count', 'sample_paths'],
          ),
        },
      },
      ['dry_run'],
    ),
    'Remove' => (
      <String, dynamic>{
        'path': _outputString,
        'removed': _outputBoolean,
        'missing': _outputBoolean,
      },
      ['removed'],
    ),
    'GraphSearch' => (
      <String, dynamic>{
        'start_entity_type': _outputString,
        'start_entity_id': _outputString,
        'total_relations': _outputInteger,
        'layers': {
          'type': 'array',
          'items': _outputObject(
            {'depth': _outputInteger, 'relations': _outputMaps},
            ['depth', 'relations'],
          ),
        },
      },
      ['start_entity_type', 'start_entity_id', 'total_relations', 'layers'],
    ),
    'AskUser' => (
      <String, dynamic>{
        'answers': {
          'type': 'array',
          'items': _outputObject(
            {
              'question_id': _outputString,
              'selected_options': _outputStrings,
              'answer': _outputString,
            },
            ['question_id'],
          ),
        },
        'cancelled': _outputBoolean,
        'resolution': _outputString,
        'unanswered_question_ids': _outputStrings,
        'message': _outputString,
      },
      ['cancelled'],
    ),
    'SpawnAgent' => (
      <String, dynamic>{
        'session_id': _outputString,
        'run_id': _outputString,
        'status': _outputString,
        'output': _outputString,
      },
      ['session_id'],
    ),
    'SendAgentMessage' || 'StopAgent' => (
      <String, dynamic>{
        'session_id': _outputString,
        'accepted': _outputBoolean,
        'status': _outputString,
        'run_id': _outputString,
      },
      ['session_id', 'accepted'],
    ),
    'AgentSkill' => (<String, dynamic>{'content': _outputString}, ['content']),
    'SuggestNextAction' => (<String, dynamic>{}, <String>[]),
    'TodoWrite' => (
      <String, dynamic>{
        'todos': {
          'type': 'array',
          'items': _outputObject(
            {
              'id': _outputString,
              'content': _outputString,
              'status': _outputString,
              'priority': _outputString,
            },
            ['id', 'content', 'status', 'priority'],
          ),
        },
        'summary': _outputString,
      },
      ['todos', 'summary'],
    ),
    // Run 的命名空间独立定义业务返回；这里描述共有执行状态和异步回执。
    'Run' => (
      <String, dynamic>{
        'output': <String, dynamic>{},
        'run_id': _outputString,
        'status': _outputString,
        'background': _outputBoolean,
        'result': _outputMap,
        'exit_code': _outputInteger,
        'has_more': _outputBoolean,
        'next_offset': {
          'type': ['integer', 'null'],
        },
      },
      <String>[],
    ),
    _ => throw StateError('Missing builtin output schema: $name'),
  };
  return {
    'type': 'object',
    'anyOf': [
      _outputObject(
        {
          'ok': _outputTrue,
          'hint': {
            'type': ['string', 'null'],
          },
          ...properties,
        },
        ['ok', ...required],
      ),
      _outputObject(
        {
          'ok': _outputFalse,
          'error_code': _outputString,
          'error': _outputString,
          'hint': {
            'type': ['string', 'null'],
          },
          'cancelled': _outputBoolean,
          'skipped': _outputBoolean,
          'rejected': _outputBoolean,
        },
        ['ok'],
      ),
    ],
  };
}
