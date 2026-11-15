// 职责: 从静态资源声明生成紧凑契约，并按集合、子资源和分组提供查询。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_support.dart
//   lib/shared/services/ai/tools_cross_work.dart
part of 'tools.dart';

Map<String, dynamic> _schemaError(ToolErrorCode code, String message) => {
  'ok': false,
  'error_code': code.name,
  'error': message,
  'hint': 'Read /_schema.',
};

typedef _ContractRenderer =
    Map<String, dynamic> Function(
      _ResourceDefinition node, {
      String? contractPath,
      String? resourcePath,
    });

/// 仅供测试核对静态声明与实际读写语义，不属于模型可调用接口。
@visibleForTesting
Map<String, dynamic> resourceContractForTesting(String path) =>
    _readSchemaContract(parseAiToolPath(path), render: _validationContract);

Map<String, dynamic> _readSchemaContract(
  ParsedPath parsed, {
  _ContractRenderer render = _collectionContract,
}) {
  if (parsed.workId != null || parsed.hasQuery) {
    return _schemaError(
      ToolErrorCode.invalid_argument,
      'Use global contract paths without query parameters.',
    );
  }
  final parts = parsed.originalPath.split('/');
  if (parts.length == 1) {
    return {
      'type': 'listing',
      'path': '/_schema',
      'entries': [
        for (final schema in _resourceDefinitions.values)
          {
            'collection': schema.name,
            'group': schema.group,
            'description': schema.description,
            'path': '/_schema/${schema.name}',
          },
      ],
    };
  }
  if (parts.length == 3 &&
      parts[1] == 'groups' &&
      _collectionGroups.contains(parts[2])) {
    return {
      'path': parsed.displayPath,
      'group': parts[2],
      'contracts': [
        for (final schema in _resourceDefinitions.values)
          if (schema.group == parts[2]) render(schema),
      ],
    };
  }
  final root = _resourceDefinitions[parts[1]];
  if (root == null) {
    return _schemaError(
      ToolErrorCode.invalid_argument,
      'Unknown collection, group, or contract path.',
    );
  }
  var schema = root;
  var resourcePath = _resourcePathTemplate(schema);
  for (final segment in parts.skip(2)) {
    final child = schema.children
        .where((node) => node.segment == segment)
        .firstOrNull;
    if (child == null) {
      return _schemaError(
        ToolErrorCode.invalid_argument,
        'Unknown subresource contract: ${parsed.displayPath}.',
      );
    }
    resourcePath = child.isSingleton
        ? '$resourcePath/${child.segment}'
        : '$resourcePath/${child.segment}/{${child.itemToken}}';
    schema = child;
  }
  return render(
    schema,
    contractPath: parsed.displayPath,
    resourcePath: resourcePath,
  );
}

Map<String, dynamic> _collectionContract(
  _ResourceDefinition node, {
  String? contractPath,
  String? resourcePath,
}) {
  final path = resourcePath ?? _resourcePathTemplate(node);
  final schemaPath = contractPath ?? '/_schema/${node.segment}';
  final lines = <String>[
    for (final field in node.fields.keys)
      _resourceFieldNote(node, field, node.enumFields[field], contract: true),
    '整体操作与例外：',
    for (final operation in node._operations)
      _contractOperationNote(node, operation),
    if (node.isSingleton &&
        node._operations.any(
          (op) =>
              op.tool == _ResourceTool.write &&
              op.target == _ResourceTargetKind.resource,
        ))
      'Create/resource 与 Write/resource 使用相同字段、默认值及约束。',
    if (node.documentType != null && node.segment != 'outlines')
      '目录读取返回 is_folder=true 与 entries；文档详情返回 is_folder=false。',
  ];
  return {
    ..._contractMetadata(node, schemaPath, path),
    'query': node.queryFields,
    'contract': lines.join('\n'),
  };
}

Map<String, dynamic> _contractMetadata(
  _ResourceDefinition node,
  String schemaPath,
  String resourcePath,
) => {
  'collection': node.segment,
  'group': node.group,
  'description': node.description,
  'path': schemaPath,
  'resource_path': resourcePath,
  'listing_path': node.isSingleton
      ? null
      : resourcePath.substring(0, resourcePath.lastIndexOf('/')),
  'singleton': node.isSingleton,
  'subresources': [
    for (final child in node.children)
      {
        'collection': child.segment,
        'description': child.description,
        'path': '$schemaPath/${child.segment}',
      },
  ],
};

List<String> _contractFieldNotes(_ResourceDefinition node, String name) {
  final field = node.fields[name]!;
  final read = field.read;
  final create = node.isSingleton ? field.write : field.create;
  final permissions = <String>[
    if (read?.detail == true)
      '详情${_requiredReadField(field, false) ? '' : '(可选)'}',
    if (read?.listing == true)
      '列表${_requiredReadField(field, true) ? '' : '(可选)'}',
    if (field.readPath) '字段Read',
    if (node.createFields.contains(name)) 'Create',
    if (node.writeFields.contains(name)) 'Write',
    if (node.operation(_ResourceTool.write, _ResourceTargetKind.field, name) !=
        null)
      '字段Write',
    if (field.canEdit) '字段Edit',
  ];
  final notes = <String>[
    '权限 ${permissions.join('/')}',
    if (field.value.type == _ValueType.object ||
        field.value.type == _ValueType.array)
      '结构 ${jsonEncode(field.value.toJson())}',
    if (field.value.enumValues.any((value) => value is! String))
      '取值 ${jsonEncode(field.value.enumValues)}',
    if (field.value.pattern != null)
      '格式 ${field.value.pattern}${field.value.enumValues.isEmpty ? '' : '（枚举或格式匹配其一）'}',
    if (field.value.referenceTarget != null)
      '引用 ${field.value.referenceTarget}',
    if (field.value.referenceTargetsByField.isNotEmpty)
      '引用随字段 ${jsonEncode(field.value.referenceTargetsByField)}',
    if (create?.hasDefault == true)
      'Create默认 ${jsonEncode(create!.defaultValue)}',
    if (field.write?.hasDefault == true)
      'Write默认 ${jsonEncode(field.write!.defaultValue)}',
    if (field.query != null)
      'query ${field.query!.match.name}/${field.query!.normalization.name}',
    if (field.search.isNotEmpty)
      '搜索 ${field.search.map((use) => use.name).join('/')}',
    if (field.aliases.isNotEmpty) '别名 ${field.aliases.join('/')}',
  ];
  final base = jsonEncode(field.value.toJson());
  final createValue = create?.value;
  final writeValue = field.write?.value;
  if (createValue != null && jsonEncode(createValue.toJson()) != base) {
    notes.add('Create结构 ${jsonEncode(createValue.toJson())}');
  }
  if (writeValue != null && jsonEncode(writeValue.toJson()) != base) {
    notes.add(
      createValue != null &&
              jsonEncode(createValue.toJson()) ==
                  jsonEncode(writeValue.toJson())
          ? 'Write结构同Create'
          : 'Write结构 ${jsonEncode(writeValue.toJson())}',
    );
  }
  for (final (tool, constraints) in [
    ('Read', read?.constraints ?? const <_ResourceConstraint>[]),
    ('Create', create?.constraints ?? const <_ResourceConstraint>[]),
    ('Write', field.write?.constraints ?? const <_ResourceConstraint>[]),
    ('Edit', field.edit?.constraints ?? const <_ResourceConstraint>[]),
  ]) {
    if (constraints.isNotEmpty) {
      notes.add(
        '$tool约束 ${jsonEncode(constraints.map((rule) => rule.toJson()).toList())}',
      );
    }
  }
  return notes;
}

String _contractOperationNote(
  _ResourceDefinition node,
  _ResourceOperation operation,
) {
  final properties = node.inputProperties(operation);
  final details = <String>[];
  final fieldNames = properties.keys.where(
    (name) => !operation.parameters.containsKey(name),
  );
  if (fieldNames.isNotEmpty) {
    details.add('fields=${fieldNames.join(',')}');
  }
  final required = properties.entries
      .where((entry) => entry.value.required)
      .map((entry) => entry.key);
  if (required.isNotEmpty) {
    details.add('必填=${required.join(',')}');
  }
  if (operation.parameters.isNotEmpty) {
    details.add('参数=${jsonEncode(_contractParameters(operation.parameters))}');
  }
  final input = node.inputValue(operation);
  if (input != null) {
    final field = node.fields[operation.field];
    if (field != null &&
        jsonEncode(input.toJson()) == jsonEncode(field.writeValue.toJson())) {
      details.add('value=本字段的Write结构（未单列时同字段类型）');
    } else if (input.type == _ValueType.array &&
        identical(input.items?.fieldReference, node.fields)) {
      final item = input.items!;
      details.add(
        'value=array<本表字段>；元素字段=${item.objectProperties.keys.join(',')}；'
        '元素必填=${item.objectProperties.entries.where((e) => e.value.required).map((e) => e.key).join(',')}；'
        'identity=${input.identity.name}；额外字段=${item.additionalProperties}',
      );
      for (final entry in item.objectProperties.entries) {
        if (node.fields[entry.key] == null ||
            jsonEncode(entry.value.value.toJson()) !=
                jsonEncode(node.fields[entry.key]!.value.toJson())) {
          details.add(
            '元素${entry.key}结构=${jsonEncode(entry.value.value.toJson())}',
          );
        }
      }
    } else {
      details.add('value=${jsonEncode(input.toJson())}');
    }
  }
  if (operation.input.field != null) {
    details.add('field=${operation.input.field}');
  }
  if (operation.constraints.isNotEmpty) {
    details.add(
      '约束=${jsonEncode(operation.constraints.map((rule) => rule.toJson()).toList())}',
    );
  }
  if (operation.missingTarget != _MissingTarget.error) {
    details.add('目标缺失=${operation.missingTarget.name}');
  }
  if (operation.tool != _ResourceTool.read) {
    details.add('返回=${operation.result.kind.name}');
    if (operation.result.value != null) {
      details.add('返回结构=${jsonEncode(operation.result.value!.toJson())}');
    }
    if (operation.result.references.isNotEmpty) {
      details.add('引用=${operation.result.references.join(',')}');
    }
  }
  return '- ${_resourceToolName(operation.tool)}/${operation.target.name}${operation.field == null ? '' : '/${operation.field}'}${details.isEmpty ? '' : '：${details.join('；')}'}';
}

Map<String, dynamic> _contractParameters(
  Map<String, _OperationParameter> parameters,
) => {
  for (final entry in parameters.entries)
    entry.key: {
      ...entry.value.value.toJson(),
      if (entry.value.hasDefault) 'default': entry.value.defaultValue,
      if (entry.value.description.isNotEmpty)
        'description': entry.value.description,
      if (entry.value.query != null)
        'query':
            '${entry.value.query!.match.name}/${entry.value.query!.normalization.name}',
    },
};

Map<String, dynamic> _validationContract(
  _ResourceDefinition schema, {
  String? contractPath,
  String? resourcePath,
}) => {
  ..._contractMetadata(
    schema,
    contractPath ?? '/_schema/${schema.segment}',
    resourcePath ?? _resourcePathTemplate(schema),
  ),
  'exclusive_fields': schema.exclusiveFields,
  'declared_operations': [
    for (final op in schema._operations)
      '${_resourceToolName(op.tool)}/${op.target.name}/${op.field ?? ''}',
  ],
  ..._nodeContract(schema, resourcePath ?? _resourcePathTemplate(schema)),
};

Map<String, dynamic> _nodeContract(_ResourceDefinition node, String path) => {
  'resource_path': path,
  'address': {
    'kind': node.address.kind.name,
    if (node.address.itemToken != null) 'item_token': node.address.itemToken,
    if (node.address.nameField != null) 'name_field': node.address.nameField,
  },
  'operations': [
    for (final tool in _ResourceTool.values)
      if (node.operations.any((operation) => operation.tool == tool))
        _resourceToolName(tool),
  ],
  'fields': {
    for (final entry in node.fields.entries)
      entry.key: {
        ...entry.value.value.toJson(),
        'read': entry.value.canRead,
        'create': node.createFields.contains(entry.key),
        'write': entry.value.canWrite,
        'edit': entry.value.canEdit,
        'read_path': entry.value.readPath,
        'write_path':
            node.operation(
              _ResourceTool.write,
              _ResourceTargetKind.field,
              entry.key,
            ) !=
            null,
        'detail': entry.value.read?.detail ?? false,
        'listing': entry.value.read?.listing ?? false,
        if (entry.value.read?.constraints.isNotEmpty == true)
          'read_constraints': entry.value.read!.constraints
              .map((rule) => rule.toJson())
              .toList(),
        'required_on_create': entry.value.requiredOnCreate,
        'nullable': entry.value.nullable,
        if (entry.value.description.isNotEmpty)
          'description': entry.value.description,
        if ((node.isSingleton ? entry.value.write : entry.value.create)
                ?.hasDefault ==
            true)
          'create_default':
              (node.isSingleton ? entry.value.write : entry.value.create)!
                  .defaultValue,
        if (entry.value.write?.hasDefault == true)
          'write_default': entry.value.write!.defaultValue,
        if (entry.value.search.isNotEmpty)
          'search': entry.value.search.map((use) => use.name).toList(),
        if (entry.value.write?.constraints.isNotEmpty == true)
          'write_constraints': entry.value.write!.constraints
              .map((rule) => rule.toJson())
              .toList(),
        if ((node.isSingleton ? entry.value.write : entry.value.create)
                ?.value !=
            null)
          'create_value':
              (node.isSingleton ? entry.value.write : entry.value.create)!
                  .value!
                  .toJson(),
        if (entry.value.write?.value != null)
          'write_value': entry.value.write!.value!.toJson(),
      },
  },
  'query': node.queryFields,
  'query_contracts': {
    for (final entry in node.fields.entries)
      if (entry.value.query != null)
        entry.key: {
          'match': entry.value.query!.match.name,
          'normalization': entry.value.query!.normalization.name,
        },
    for (final entry
        in node
                .operation(_ResourceTool.read, _ResourceTargetKind.listing)
                ?.parameters
                .entries ??
            const <MapEntry<String, _OperationParameter>>[])
      if (entry.value.query != null)
        entry.key: {
          'match': entry.value.query!.match.name,
          'normalization': entry.value.query!.normalization.name,
        },
  },
  'create_exclusive': node.createExclusive,
  'write_exclusive': node.writeExclusive,
  if (node.listingWriteField != null)
    'listing_write_field': node.listingWriteField,
  'operation_contracts': [
    for (final operation in node.operations)
      _operationContract(node, operation),
  ],
};

String _resourceToolName(_ResourceTool tool) => switch (tool) {
  _ResourceTool.read => 'Read',
  _ResourceTool.create => 'Create',
  _ResourceTool.write => 'Write',
  _ResourceTool.edit => 'Edit',
  _ResourceTool.remove => 'Remove',
};

Map<String, dynamic> _operationContract(
  _ResourceDefinition node,
  _ResourceOperation operation,
) {
  final properties = node.inputProperties(operation);
  final defaults = <String, Object?>{
    for (final entry in operation.parameters.entries)
      if (entry.value.hasDefault) entry.key: entry.value.defaultValue,
    for (final entry in node.fields.entries)
      if (operation.input.kind == _ResourceInputKind.create_fields &&
          entry.value.create?.hasDefault == true)
        entry.key: entry.value.create!.defaultValue,
    for (final entry in node.fields.entries)
      if ((operation.tool == _ResourceTool.write ||
              (node.isSingleton && operation.tool == _ResourceTool.create)) &&
          entry.value.write?.hasDefault == true)
        entry.key: entry.value.write!.defaultValue,
  };
  return {
    'tool': _resourceToolName(operation.tool),
    'parameter_names': operation.parameters.keys.toList(),
    'target': operation.target.name,
    if (operation.field != null) 'field': operation.field,
    'input': {
      'kind': operation.input.kind.name,
      if (node.inputValue(operation) != null)
        'value': node.inputValue(operation)!.toJson(),
      if (operation.input.field != null) 'field': operation.input.field,
      if (properties.isNotEmpty)
        'properties': {
          for (final entry in properties.entries)
            entry.key: {
              ...entry.value.value.toJson(),
              if (defaults.containsKey(entry.key))
                'default': defaults[entry.key],
              if (entry.value.description.isNotEmpty)
                'description': entry.value.description,
            },
        },
      'required': [
        for (final entry in properties.entries)
          if (entry.value.required) entry.key,
      ],
    },
    'constraints': [
      for (final constraint in operation.constraints) constraint.toJson(),
    ],
    'missing_target': operation.missingTarget.name,
    'result': {
      'kind': operation.result.kind.name,
      if (operation.tool == _ResourceTool.read)
        'output_schema': _resourceReadOutputSchema(node, operation),
      if (operation.result.value != null)
        'value': operation.result.value!.toJson(),
      'references': operation.result.references,
    },
  };
}

/// 参数与路径类错误才引导查契约；指向作品本身的访问错误与资源契约无关。
bool _isContractValidationError(Map<String, dynamic> result) =>
    !toolResultIsSuccess(result) &&
    !_isWorkLevelPath(result['path']) &&
    (result['validation_errors'] is List ||
        {
          ToolErrorCode.invalid_argument.name,
          ToolErrorCode.unsupported.name,
        }.contains(result['error_code']));

bool _isWorkLevelPath(Object? path) =>
    path is String && RegExp(r'^/works(/[^/]+)?$').hasMatch(path);

String _resourceContractPath(ParsedPath parsed) {
  final root = _resourceDefinitions[parsed.collection];
  if (root == null) {
    return '/_schema';
  }
  final rootPath = '/_schema/${root.segment}';
  final target = parsed._resource?.schema;
  final pending = [(root, rootPath)];
  while (pending.isNotEmpty) {
    final (node, path) = pending.removeLast();
    if (identical(node, target)) {
      return path;
    }
    pending.addAll(
      node.children.map((child) => (child, '$path/${child.segment}')),
    );
  }
  return rootPath;
}

Map<String, dynamic> _withContractHint(
  Map<String, dynamic> result,
  Map<String, dynamic> input,
) {
  if (!_isContractValidationError(result)) {
    return result;
  }
  final parsed = parseAiToolPath(_parseStringArgument(input['path']));
  if (parsed.collection == '_schema' || parsed.isRoot) {
    return result;
  }
  final schema = _resourceDefinitions[parsed.collection];
  final contract = _resourceContractPath(parsed);
  final rootContract = schema == null ? '/_schema' : '/_schema/${schema.name}';
  final hint = (result['hint'] as String? ?? '').replaceAll(
    'Read $rootContract.',
    'Read $contract.',
  );
  if (hint.contains('Read $contract')) {
    return {...result, 'hint': hint};
  }
  return {...result, 'hint': '${hint.isEmpty ? "" : "$hint "}Read $contract.'};
}
