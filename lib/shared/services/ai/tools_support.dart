// 职责: 定义 AI 资源契约、解析调用目标，并统一输入规范化、校验及契约引导。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_schema.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/services/working_overlay.dart
// 遵循的 Rules:
//   .agents/rules/tools_path.md
// 注意: 新增资源集合时，只需更新 _resourceDefinitions —— 路径模板与字段表由
//   pathSchemaFieldNotes() 渲出，hidden 资源由 bundled AgentSkill 按需介绍。
//   pathSchema 只保留通用寻址、作品边界与契约发现规则。
part of 'tools.dart';

Map<String, dynamic> _resourceError(
  String path,
  ToolErrorCode code,
  String message, {
  String? hint,
  Object? details,
}) => {
  'ok': false,
  'error': message,
  'error_code': code.name,
  'path': path,
  'hint': ?hint,
  'details': ?details,
};

/// Screenplay / Canvas / Relation service 的细分错误码在工具出口收敛为大类；
/// 具体原因由异常 message 保留在 `error` 中。`not_found` 只表示 path 指向的
/// 目标不存在；参数里引用的资源不存在属于 `invalid_argument`。
ToolErrorCode _serviceErrorCode(String code) => switch (code) {
  'not_found' ||
  'canvas_not_found' ||
  'node_not_found' ||
  'edge_not_found' ||
  'scene_not_found' => ToolErrorCode.not_found,
  'duplicate_name' ||
  'duplicate_edge' ||
  'screenplay_already_exists' => ToolErrorCode.already_exists,
  'layout_conflict' ||
  'relation_changed' ||
  'stale_screenplay_edit' => ToolErrorCode.conflict,
  'old_text_not_found' ||
  'beat_anchor_outside_act' ||
  'beat_anchor_outside_episode' ||
  'dependent_elements_exist' ||
  'entity_in_use' ||
  'first_scene_heading_required' ||
  'initial_snapshot_not_removable' ||
  'last_episode_required' ||
  'last_season_required' ||
  'layout_requires_directed_edges' => ToolErrorCode.failed_precondition,
  'read_only_field' => ToolErrorCode.permission_denied,
  'missing_session_context' => ToolErrorCode.unavailable,
  'save_failed' ||
  'invalid_relation_history' ||
  'invalid_screenplay_document' => ToolErrorCode.internal,
  'missing_required_fields' ||
  'invalid_fields' ||
  'invalid_element_fields' ||
  'character_id_required' ||
  'invalid_reference' ||
  'invalid_beat_ref' ||
  'invalid_chapter_ref' ||
  'invalid_character_ref' ||
  'invalid_element_ref' ||
  'invalid_episode_ref' ||
  'invalid_location_ref' ||
  'invalid_scene_ref' ||
  'invalid_screenplay_ref' ||
  'invalid_season_ref' ||
  'mutually_exclusive_fields' ||
  'empty_old_text' ||
  'ambiguous_old_text' ||
  'dialogue_character_required' ||
  'duplicate_element_id' ||
  'invalid_name' ||
  'invalid_type' ||
  'invalid_ref_type' ||
  'invalid_geometry' ||
  'invalid_edge_semantics' ||
  'invalid_relation_type' ||
  'invalid_relation_status' ||
  'invalid_act_number' ||
  'invalid_beat_anchor' ||
  'invalid_scene_anchor' ||
  'invalid_element_type' ||
  'invalid_episode_number' ||
  'invalid_interior_exterior' ||
  'invalid_planned_episode_count' ||
  'invalid_scene_emotion' ||
  'invalid_scene_event' ||
  'invalid_scene_stage' ||
  'invalid_screenplay_selection' ||
  'invalid_season_number' ||
  'invalid_split_position' => ToolErrorCode.invalid_argument,
  _ => ToolErrorCode.internal,
};

/// Shared path schema used by all tools (Read / Write / Edit / Glob / Grep / prompts).
///
/// 路径语法的唯一真源。响应侧只回一个扁平 `path`，不做运行时导航 —— 曾经有过一层
/// HATEOAS `_links`（self / collection / resource / subresources / create），删掉的
/// 理由见 [_attachResultPath]。那层删掉之后模型只能靠这份静态语法把路径结构拼出来；
/// 能拼的只有结构，ID 与标题仍然必须照抄。
///
/// 路径模板从 [_resourceDefinitions] 生成并随 [pathSchemaFieldNotes] 输出，
/// 这里只保留通用规则；hidden 资源由 bundled AgentSkill 按需介绍。
/// 字段名来自资源数据的顶层 key。
String pathSchema({String kind = contentKindNovel}) =>
    '''路径语法：
${_buildPathGrammarReference(kind: kind)}

- 相对路径：以当前作品为起点，如 ${kind == contentKindCanvas
        ? 'production/clips/{clip_id}'
        : kind == contentKindScreenplay
        ? 'scenes/{scene_id}'
        : 'chapters/{chapter_id}'}。用户未明确要求引用、比较或改编其他作品时，不要读取 /works，使用相对路径。
- 绝对路径：以 /works/{work_id} 为起点，如 /works/{work_id}/${kind == contentKindCanvas
        ? 'production/clips/{clip_id}'
        : kind == contentKindScreenplay
        ? 'scenes/{scene_id}'
        : 'chapters/{chapter_id}'}。
- Read /works 发现本地作品（包括当前作品），每项至少返回 id、title、path；Read、Glob、Grep 跨作品读取时，单次调用必须明确一个 work_id
- 跨作品只读；Create、Write、Edit、Replace、Remove 只能修改当前作品。读取其他作品不改变写入目标；按读取结果中的作品类型选择资源与契约。
- 已有资源优先使用工具返回的 `path`；引用已有资源的 ID 或定位名称时，从工具结果原样复制，不得自行构造或修改。新建或重命名时填写的新名称不受此限制。
- 实体自身标识统一为 id（只读），关联字段和查询作用域保留各自名称；允许保留身份的数组整体写入可原样携带已有 id。
- 契约发现：已有说明足够时直接操作；不确定时用 Read /_schema/{collection} 查询字段与能力，Read /_schema 查询集合索引，Read /_schema/groups/{shared|novel|screenplay|canvas} 查询整组契约。''';

/// 单字段 Write 的旧调用适配；类型由值定义生成。

enum _ValueType { string, integer, number, boolean, object, array }

enum _AddressKind { singleton, id, name, hierarchical_name }

enum _ResourceTool { read, create, write, edit, remove }

enum _ResourceTargetKind { listing, resource, field }

enum _ResourceInputKind {
  none,
  create_fields,
  resource_fields,
  field_value,
  text_edit,
  array_value,
}

enum _ResourceResultKind { entity, listing, field_value, mutation }

enum _FieldProjection { detail, listing, create, write, existing_item }

enum _ArrayIdentity {
  plain_values,
  new_items,
  optional_existing_id,
  references,
}

enum _ConstraintKind {
  at_least_one,
  mutually_exclusive,
  requires_together,
  required_when,
  target_requirement,
}

enum _ConstraintPresence { provided, present }

enum _QueryMatch { exact, contains }

enum _QueryNormalization {
  string,
  integer,
  boolean;

  Object? normalize(Object? value) {
    if (value is! String) {
      return value;
    }
    return switch (this) {
      string => value,
      integer => int.tryParse(value),
      boolean => switch (value) {
        'true' => true,
        'false' => false,
        _ => null,
      },
    };
  }
}

enum _FieldSearch { short_text, body }

enum _MissingTarget { error, create }

class _ResourceAddress {
  const _ResourceAddress(this.kind, {this.itemToken, this.nameField});
  final _AddressKind kind;
  final String? itemToken;
  final String? nameField;
}

class _ValueProperty {
  const _ValueProperty(
    this.value, {
    this.required = false,
    this.description = '',
    this.aliases = const [],
  });
  final _ValueSchema value;
  final bool required;
  final String description;
  final List<String> aliases;
}

/// 对象与数组可引用子资源投影，避免再声明一份元素字段。
class _ValueSchema {
  const _ValueSchema(
    this.type, {
    this.nullable = false,
    this.enumValues = const [],
    this.enumAliases = const {},
    this.pattern,
    this.minimum,
    this.maximum,
    this.minLength,
    this.properties = const {},
    this.additionalProperties = false,
    this.items,
    this.identity = _ArrayIdentity.plain_values,
    this.fieldReference,
    this.parameterReference,
    this.projection = _FieldProjection.detail,
    this.requireProjectedFields = true,
    this.referenceTarget,
    this.referenceTargetsByField = const {},
    this.example,
  });
  final _ValueType type;
  final bool nullable;
  final List<Object?> enumValues;
  final Map<String, String> enumAliases;

  /// 字符串的正则格式；与 [enumValues] 同时给出时，命中枚举或匹配格式均合法。
  final String? pattern;
  final num? minimum;
  final num? maximum;
  final int? minLength;
  final Map<String, _ValueProperty> properties;
  final bool additionalProperties;
  final _ValueSchema? items;
  final _ArrayIdentity identity;
  final Map<String, _ResourceField>? fieldReference;
  final Map<String, _OperationParameter>? parameterReference;
  final _FieldProjection projection;
  final bool requireProjectedFields;
  final String? referenceTarget;
  final Map<String, Map<String, List<String>>> referenceTargetsByField;
  final Object? example;

  Map<String, _ValueProperty> get objectProperties => {
    ...fieldReference != null
        ? _projectResourceFields(
            fieldReference!,
            projection,
            requireFields: requireProjectedFields,
          )
        : properties,
    for (final entry
        in parameterReference?.entries ??
            const <MapEntry<String, _OperationParameter>>[])
      entry.key: _ValueProperty(
        entry.value.value,
        required: entry.value.required,
        description: entry.value.description,
      ),
  };

  bool accepts(Object? value) {
    if (value == null) {
      return nullable;
    }
    if (enumValues.isNotEmpty && !enumValues.contains(value)) {
      if (!_matchesPattern(value)) {
        return false;
      }
    } else if (pattern != null &&
        enumValues.isEmpty &&
        !_matchesPattern(value)) {
      return false;
    }
    switch (type) {
      case _ValueType.string:
        return value is String &&
            (minLength == null || value.trim().length >= minLength!);
      case _ValueType.integer:
      case _ValueType.number:
        return value is num &&
            value.isFinite &&
            (type != _ValueType.integer || value is int) &&
            (minimum == null || value >= minimum!) &&
            (maximum == null || value <= maximum!);
      case _ValueType.boolean:
        return value is bool;
      case _ValueType.array:
        return value is List && items != null && value.every(items!.accepts);
      case _ValueType.object:
        if (value is! Map || value.keys.any((key) => key is! String)) {
          return false;
        }
        final fields = objectProperties;
        if (fields.entries.any(
          (entry) => entry.value.required && !value.containsKey(entry.key),
        )) {
          return false;
        }
        return value.entries.every(
          (entry) => fields.containsKey(entry.key)
              ? fields[entry.key]!.value.accepts(entry.value)
              : additionalProperties,
        );
    }
  }

  bool _matchesPattern(Object value) =>
      pattern != null && value is String && RegExp(pattern!).hasMatch(value);

  Map<String, dynamic> toJson() => {
    'type': type.name,
    if (nullable) 'nullable': true,
    if (enumValues.isNotEmpty) 'enum': enumValues.toSet().toList(),
    if (pattern != null) 'pattern': pattern,
    if (minimum != null) 'minimum': minimum,
    if (maximum != null) 'maximum': maximum,
    if (minLength != null) 'min_length': minLength,
    if (example != null) 'example': example,
    if (type == _ValueType.object) ...{
      'properties': {
        for (final entry in objectProperties.entries)
          entry.key: {
            ...entry.value.value.toJson(),
            if (entry.value.description.isNotEmpty)
              'description': entry.value.description,
          },
      },
      'required': [
        for (final entry in objectProperties.entries)
          if (entry.value.required) entry.key,
      ],
      'additional_properties': additionalProperties,
    },
    if (items != null) 'items': items!.toJson(),
    if (type == _ValueType.array) 'identity': identity.name,
    if (referenceTarget != null) 'reference_target': referenceTarget,
    if (referenceTargetsByField.isNotEmpty)
      'reference_targets_by_field': referenceTargetsByField,
  };
}

class _FieldRead {
  const _FieldRead({
    this.detail = true,
    this.listing = false,
    this.path = false,
    this.constraints = const [],
    this.requiredInListing = true,
    this.requiredInDetail = true,
  });
  // 读取输出中键是否必有；与创建输入必填、值是否允许 null 分开声明。
  final bool requiredInListing;
  final bool requiredInDetail;
  final bool detail;
  final bool listing;
  final bool path;
  final List<_ResourceConstraint> constraints;

  bool acceptsTarget(Map<String, dynamic> target) {
    for (final rule in constraints) {
      if (!target.containsKey(rule.whenField)) {
        throw StateError(
          'Read target is missing discriminator ${rule.whenField}',
        );
      }
      if (!rule.accepts(const {}, target: target)) {
        return false;
      }
    }
    return true;
  }
}

class _FieldInputUse {
  const _FieldInputUse({
    this.required = false,
    this.value,
    this.resource = true,
    this.field = false,
    this.defaultValue,
    this.hasDefault = false,
    this.constraints = const [],
  });
  final bool required;
  final _ValueSchema? value;

  final bool resource;
  final bool field;
  final Object? defaultValue;
  final bool hasDefault;
  final List<_ResourceConstraint> constraints;
}

class _FieldEdit {
  const _FieldEdit({this.constraints = const []});
  final List<_ResourceConstraint> constraints;
}

class _FieldQuery {
  const _FieldQuery({
    this.match = _QueryMatch.exact,
    this.normalization = _QueryNormalization.string,
  });
  final _QueryMatch match;
  final _QueryNormalization normalization;
}

class _ResourceField {
  const _ResourceField({
    required this.value,
    this.description = '',
    this.read,
    this.create,
    this.write,
    this.edit,
    this.query,
    this.search = const {},
    this.aliases = const [],
  });
  final _ValueSchema value;
  final String description;
  final _FieldRead? read;
  final _FieldInputUse? create;
  final _FieldInputUse? write;
  final _FieldEdit? edit;
  final _FieldQuery? query;
  final Set<_FieldSearch> search;
  final List<String> aliases;

  // 既有参数适配及文案消费者的派生视图，A4/A5 按入口改接具体操作。
  bool get canRead => read != null;
  bool get canCreate => create != null;
  bool get canWrite => write != null;
  bool get canEdit => edit != null;
  bool get canQuery => query != null;
  bool get readPath => read?.path ?? false;
  bool get writePath => write?.field ?? false;
  bool get requiredOnCreate => create?.required ?? false;
  _ValueSchema get writeValue => write?.value ?? value;
  _ValueType get type => value.type;
  bool get nullable => value.nullable;
  num? get minimum => value.minimum;
  List<String> get values => value.enumValues.whereType<String>().toList();
  bool accepts(Object? input, {bool queryValue = false}) => value.accepts(
    queryValue
        ? (query?.normalization ?? _QueryNormalization.string).normalize(input)
        : input,
  );
}

class _OperationParameter {
  const _OperationParameter(
    this.value, {
    this.required = false,
    this.description = '',
    this.defaultValue,
    this.hasDefault = false,
    this.query,
  });
  final _ValueSchema value;
  final bool required;
  final String description;
  final Object? defaultValue;
  final bool hasDefault;
  final _FieldQuery? query;
}

class _ResourceConstraint {
  const _ResourceConstraint(
    this.kind,
    this.fields, {
    this.whenField,
    this.whenValues = const [],
    this.presence = _ConstraintPresence.provided,
  });
  final _ConstraintKind kind;
  final List<String> fields;
  final String? whenField;
  final List<Object?> whenValues;
  final _ConstraintPresence presence;

  bool accepts(
    Map<String, dynamic> input, {
    Map<String, dynamic> target = const {},
  }) {
    bool matchesPresence(String field) =>
        input.containsKey(field) &&
        (presence == _ConstraintPresence.present ||
            (input[field] != null &&
                (input[field] is! String ||
                    (input[field] as String).trim().isNotEmpty)));
    final count = fields.where(matchesPresence).length;
    return switch (kind) {
      _ConstraintKind.at_least_one => count > 0,
      _ConstraintKind.mutually_exclusive => count <= 1,
      _ConstraintKind.requires_together => count == 0 || count == fields.length,
      _ConstraintKind.required_when =>
        !whenValues.contains(input[whenField]) || count == fields.length,
      _ConstraintKind.target_requirement => whenValues.contains(
        target[whenField],
      ),
    };
  }

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    if (presence != _ConstraintPresence.provided) 'presence': presence.name,
    if (fields.isNotEmpty) 'fields': fields,
    if (whenField != null) 'when_field': whenField,
    if (whenValues.isNotEmpty) 'when_values': whenValues,
  };
}

class _ResourceInput {
  const _ResourceInput(this.kind, {this.value, this.field});
  final _ResourceInputKind kind;
  final _ValueSchema? value;
  final String? field;
}

class _ResourceResult {
  const _ResourceResult(this.kind, {this.value, this.references = const []});
  final _ResourceResultKind kind;
  final _ValueSchema? value;

  /// 明确的结果引用位置；不扫描业务字符串。
  final List<String> references;
}

const _textEditParameters = <String, _OperationParameter>{
  'old_text': _OperationParameter(
    _ValueSchema(_ValueType.string),
    required: true,
  ),
  'new_text': _OperationParameter(
    _ValueSchema(_ValueType.string),
    required: true,
  ),
  'all': _OperationParameter(
    _ValueSchema(_ValueType.boolean),
    hasDefault: true,
    defaultValue: false,
  ),
};

class _ResourceOperation {
  const _ResourceOperation(
    this.tool,
    this.target, {
    this.field,
    this.input = const _ResourceInput(_ResourceInputKind.none),
    this.parameters = const {},
    this.constraints = const [],
    this.missingTarget = _MissingTarget.error,
    this.result = const _ResourceResult(
      _ResourceResultKind.mutation,
      references: ['path'],
    ),
  });
  final _ResourceTool tool;
  final _ResourceTargetKind target;
  final String? field;
  final _ResourceInput input;
  final Map<String, _OperationParameter> parameters;
  final List<_ResourceConstraint> constraints;
  final _MissingTarget missingTarget;
  final _ResourceResult result;
  (_ResourceTool, _ResourceTargetKind, String?) get key =>
      (tool, target, field);
}

class _ResourceListing {
  const _ResourceListing({this.parentQuery});

  /// 搜索省略父级筛选时，按此关联字段枚举所有父资源，避免继承当前 UI 选择。
  final String? parentQuery;
}

const _collectionGroupShared = 'shared';
const _collectionGroups = [
  _collectionGroupShared,
  contentKindNovel,
  contentKindScreenplay,
  contentKindCanvas,
];

/// 根和子资源共用唯一声明结构；旧消费者所需的名单全部由字段和操作投影。
class _ResourceDefinition {
  const _ResourceDefinition({
    required this.segment,
    required this.address,
    this.description = '',
    this.group = _collectionGroupShared,
    this.hidden = true,
    this.discoverable = true,
    required this.fields,
    this.children = const [],
    this.listing,
    required this._operations,
    this.itemType,
    this.documentType,
    this.optionalChild = false,
  });
  final String segment;
  final _ResourceAddress address;
  final String description;
  final String group;

  /// 不进入常驻路径模板与字段表；由 bundled AgentSkill 按需介绍，仍可查询契约。
  final bool hidden;
  final bool discoverable;
  final Map<String, _ResourceField> fields;
  final List<_ResourceDefinition> children;

  /// 可选子资源尚未创建时，祖先搜索不枚举它；显式读取仍报告不存在。
  final bool optionalChild;
  final _ResourceListing? listing;
  final List<_ResourceOperation> _operations;
  final String? itemType;
  final String? documentType;

  List<_ResourceOperation> get operations => List.unmodifiable([
    ..._operations,
    if (isSingleton)
      for (final operation in _operations)
        if (operation.tool == _ResourceTool.write &&
            operation.target == _ResourceTargetKind.resource)
          _ResourceOperation(
            _ResourceTool.create,
            operation.target,
            input: operation.input,
            parameters: operation.parameters,
            constraints: operation.constraints,
            missingTarget: operation.missingTarget,
            result: operation.result,
          ),
    for (final entry in fields.entries) ...[
      if (entry.value.readPath)
        _ResourceOperation(
          _ResourceTool.read,
          _ResourceTargetKind.field,
          field: entry.key,
          constraints: entry.value.read!.constraints,
          result: _ResourceResult(
            _ResourceResultKind.field_value,
            value: entry.value.value,
          ),
        ),
      if (entry.value.writePath)
        _ResourceOperation(
          _ResourceTool.write,
          _ResourceTargetKind.field,
          field: entry.key,
          input: _ResourceInput(
            _ResourceInputKind.field_value,
            field: entry.key,
            value: entry.value.writeValue,
          ),
          constraints: entry.value.write!.constraints,
        ),
      if (entry.value.canEdit)
        _ResourceOperation(
          _ResourceTool.edit,
          _ResourceTargetKind.field,
          field: entry.key,
          input: const _ResourceInput(_ResourceInputKind.text_edit),
          constraints: entry.value.edit!.constraints,
          parameters: _textEditParameters,
        ),
    ],
  ]);

  _ResourceOperation? operation(
    _ResourceTool tool,
    _ResourceTargetKind target, [
    String? field,
  ]) => operations.where((op) => op.key == (tool, target, field)).firstOrNull;

  Map<String, _ValueProperty> project(_FieldProjection projection) =>
      _projectResourceFields(fields, projection);

  _ValueSchema? inputValue(_ResourceOperation operation) =>
      operation.input.value ??
      (operation.input.kind == _ResourceInputKind.field_value
          ? fields[operation.field]?.writeValue
          : null);

  Map<String, _ValueProperty> inputProperties(_ResourceOperation op) => {
    if (op.input.kind == _ResourceInputKind.create_fields)
      ...project(_FieldProjection.create),
    if (op.input.kind == _ResourceInputKind.resource_fields)
      ...project(_FieldProjection.write),
    for (final entry in op.parameters.entries)
      entry.key: _ValueProperty(
        entry.value.value,
        required: entry.value.required,
        description: entry.value.description,
      ),
  };

  String get name => segment;
  String get rel => segment;
  String get itemToken => address.itemToken ?? '';
  String? get idPlaceholder => address.itemToken;
  bool get isSingleton => address.kind == _AddressKind.singleton;
  bool get usesNamePath =>
      address.kind == _AddressKind.name ||
      address.kind == _AddressKind.hierarchical_name;

  /// 画布作品开放 canvas 组，以及与小说、剧本相同的作品 profile。
  bool supports(String kind) {
    if (kind == contentKindCanvas) {
      return group == kind || segment == 'profile';
    }
    return group == _collectionGroupShared || group == kind;
  }

  bool get isItemCollection => itemType != null;
  bool get isDocumentCollection => documentType != null;
  List<_ResourceDefinition> get subResources => children;
  List<String> get readFields => fields.entries
      .where((entry) => entry.value.readPath)
      .map((entry) => entry.key)
      .toList();

  Iterable<String> readFieldsFor(Map<String, dynamic> target) => fields.entries
      .where(
        (entry) =>
            entry.value.readPath && entry.value.read!.acceptsTarget(target),
      )
      .map((entry) => entry.key);

  /// 实例读取按同一份条件投影；listing 仍只返回声明为列表可见的字段。
  Map<String, dynamic> readValues(
    Map<String, dynamic> values, {
    bool listing = false,
  }) => {
    for (final entry in fields.entries)
      if ((listing ? entry.value.read?.listing : entry.value.read?.detail) ==
              true &&
          values.containsKey(entry.key) &&
          entry.value.read!.acceptsTarget(values))
        entry.key: values[entry.key],
  };
  List<String> get writableFields => fields.entries
      .where((entry) => entry.value.canWrite)
      .map((entry) => entry.key)
      .toList();
  List<String> get writeFields => [
    ...project(_FieldProjection.write).keys,
    ...?operation(
      _ResourceTool.write,
      _ResourceTargetKind.resource,
    )?.parameters.keys,
  ];
  List<String> get createFields => isSingleton
      ? writeFields
      : [
          ...project(_FieldProjection.create).keys,
          ...?operation(
            _ResourceTool.create,
            _ResourceTargetKind.listing,
          )?.parameters.keys,
        ];
  List<String> get createOnlyFields =>
      createFields.where((key) => fields[key]?.canRead != true).toList();
  List<String> get requiredFields {
    final create = operation(_ResourceTool.create, _ResourceTargetKind.listing);
    if (isSingleton || create == null) {
      return const [];
    }
    return inputProperties(create).entries
        .where((entry) => entry.value.required)
        .map((entry) => entry.key)
        .toList();
  }

  List<String> get createRequiredFields => requiredFields;
  bool get removable =>
      operation(_ResourceTool.remove, _ResourceTargetKind.resource) != null;
  bool get isReadOnly => !operations.any(
    (op) => op.tool == _ResourceTool.write || op.tool == _ResourceTool.edit,
  );
  List<String> get editableFields => fields.entries
      .where((entry) => entry.value.canEdit)
      .map((entry) => entry.key)
      .toList();
  Set<String> get readOnlyFields => fields.entries
      .where(
        (entry) =>
            entry.value.canRead &&
            !entry.value.canCreate &&
            !entry.value.canWrite &&
            !entry.value.canEdit,
      )
      .map((entry) => entry.key)
      .toSet();
  List<String> get queryFields => [
    ...?operation(
      _ResourceTool.read,
      _ResourceTargetKind.listing,
    )?.parameters.keys,
    for (final entry in fields.entries)
      if (entry.value.canQuery) entry.key,
  ];
  List<String> get queryableFields => queryFields;
  bool get isQueryable => queryFields.isNotEmpty;
  Set<String> get nullableFields => fields.entries
      .where((entry) => entry.value.nullable)
      .map((entry) => entry.key)
      .toSet();
  Map<String, String> get fieldDescriptions => {
    for (final entry in fields.entries)
      if (entry.value.description.isNotEmpty)
        entry.key: entry.value.description,
    for (final op in _operations)
      for (final entry in op.parameters.entries)
        if (entry.value.description.isNotEmpty)
          entry.key: entry.value.description,
  };
  Map<String, List<String>> get enumFields => {
    for (final entry in fields.entries)
      if (entry.value.values.isNotEmpty) entry.key: entry.value.values,
    for (final op in _operations)
      for (final entry in op.parameters.entries)
        if (entry.value.value.enumValues.isNotEmpty)
          entry.key: entry.value.value.enumValues.whereType<String>().toList(),
  };
  Map<String, List<Object?>> get createEnums => {
    for (final entry in inputProperties(
      operation(_ResourceTool.create, _ResourceTargetKind.listing)!,
    ).entries)
      if (entry.value.value.enumValues.isNotEmpty)
        entry.key: [
          ...entry.value.value.enumValues,
          if (entry.value.value.nullable) null,
        ],
  };
  List<String> get positiveIntegerFields => fields.entries
      .where(
        (entry) =>
            entry.value.canCreate &&
            entry.value.type == _ValueType.integer &&
            entry.value.minimum == 1,
      )
      .map((entry) => entry.key)
      .toList();
  List<List<String>> _exclusive(_ResourceTool tool) => [
    for (final op in _operations)
      if (op.tool == tool)
        for (final rule in op.constraints)
          if (rule.kind == _ConstraintKind.mutually_exclusive) rule.fields,
  ];
  List<List<String>> get exclusiveFields => _exclusive(_ResourceTool.create);
  List<String> get createExclusive =>
      _exclusive(_ResourceTool.create).firstOrNull ?? [];
  List<String> get writeExclusive =>
      _exclusive(_ResourceTool.write).firstOrNull ?? [];
  String? get listingWriteField =>
      operation(_ResourceTool.write, _ResourceTargetKind.listing)?.input.field;

  /// A4 之前的名称路径解析仍需识别子资源末段；只从树派生，不能作为父字段权限。
  Set<String> get pathFieldSegments => {
    for (final entry in fields.entries)
      if (entry.value.readPath || entry.value.writePath || entry.value.canEdit)
        entry.key,
    for (final operation in _operations)
      if (operation.target == _ResourceTargetKind.field) operation.field!,
    for (final child in children) ...child.pathFieldSegments,
  };
}

void _validateResourceDefinitions(Map<String, _ResourceDefinition> roots) {
  final active = <_ResourceDefinition>{};
  void checkAliases(Map<String, _ValueProperty> fields, String path) {
    final names = <String, String>{for (final key in fields.keys) key: key};
    for (final entry in fields.entries) {
      for (final alias in entry.value.aliases) {
        if (names.containsKey(alias) && names[alias] != entry.key) {
          throw StateError('$path: field alias conflicts with $alias');
        }
        names[alias] = entry.key;
      }
    }
  }

  void checkValue(_ValueSchema value, String path, Set<_ValueSchema> stack) {
    if (!stack.add(value)) {
      throw StateError('$path: cyclic value projection');
    }
    if (value.minimum != null &&
        value.maximum != null &&
        value.minimum! > value.maximum!) {
      throw StateError('$path: inverted range');
    }
    if (value.example != null && !value.accepts(value.example)) {
      throw StateError('$path: example does not match value contract');
    }
    for (final item in value.enumValues) {
      if (!value.accepts(item)) {
        throw StateError('$path: enum value does not match type');
      }
    }
    final enumTargets = <String, String>{};
    for (final item in value.enumValues.whereType<String>()) {
      final key = _resourceEnumFormat(item);
      if (enumTargets.containsKey(key) && enumTargets[key] != item) {
        throw StateError('$path: ambiguous enum format');
      }
      enumTargets[key] = item;
    }
    for (final entry in value.enumAliases.entries) {
      if (!value.enumValues.contains(entry.value)) {
        throw StateError('$path: enum alias has unknown target');
      }
      final key = _resourceEnumFormat(entry.key);
      if (enumTargets.containsKey(key) && enumTargets[key] != entry.value) {
        throw StateError('$path: conflicting enum alias');
      }
      enumTargets[key] = entry.value;
    }
    checkAliases(value.objectProperties, path);
    if ((value.minimum != null || value.maximum != null) &&
        value.type != _ValueType.integer &&
        value.type != _ValueType.number) {
      throw StateError('$path: range requires a numeric type');
    }
    if (value.type != _ValueType.array &&
        (value.items != null ||
            value.identity != _ArrayIdentity.plain_values)) {
      throw StateError('$path: array rules on a non-array value');
    }
    if (value.type == _ValueType.array && value.items == null) {
      throw StateError('$path: array requires items');
    }
    if (value.identity == _ArrayIdentity.optional_existing_id &&
        value.items?.objectProperties['id']?.value.type != _ValueType.string) {
      throw StateError('$path: existing identity requires string id');
    }
    if (value.identity == _ArrayIdentity.new_items &&
        value.items?.objectProperties.containsKey('id') == true) {
      throw StateError('$path: new-item input cannot preserve id');
    }
    if (value.identity == _ArrayIdentity.references &&
        (value.items?.type != _ValueType.string ||
            value.referenceTarget == null)) {
      throw StateError(
        '$path: reference list requires string ids and a target',
      );
    }
    if (value.items != null) {
      checkValue(value.items!, '$path[]', stack);
    }
    for (final entry in value.objectProperties.entries) {
      checkValue(entry.value.value, '$path.${entry.key}', stack);
    }
    stack.remove(value);
  }

  void visit(_ResourceDefinition node, String path, String group) {
    if (!active.add(node)) {
      throw StateError('$path: resource cycle');
    }
    if (node.segment.isEmpty || node.segment.contains('/')) {
      throw StateError('$path: invalid segment');
    }
    if (node.group != group) {
      throw StateError('$path: child group differs from parent');
    }
    if (!node.isSingleton && node.itemToken.isEmpty) {
      throw StateError('$path: missing item token');
    }
    if (node.usesNamePath &&
        (node.address.nameField == null ||
            !node.fields.containsKey(node.address.nameField))) {
      throw StateError('$path: missing name field');
    }
    checkAliases({
      for (final entry in node.fields.entries)
        entry.key: _ValueProperty(
          entry.value.value,
          aliases: entry.value.aliases,
        ),
    }, path);
    final create = node.operation(
      _ResourceTool.create,
      node.isSingleton
          ? _ResourceTargetKind.resource
          : _ResourceTargetKind.listing,
    );
    if (create != null &&
        create.input.kind !=
            (node.isSingleton
                ? _ResourceInputKind.resource_fields
                : _ResourceInputKind.create_fields)) {
      throw StateError('$path: Create requires an explicit fields input');
    }
    // Read/Remove-only history does not expose Create. Mutable collections still require it.
    if (!node.isSingleton && !node.isReadOnly && create == null) {
      throw StateError('$path: missing Create contract');
    }
    if (node.isSingleton && node.removable) {
      throw StateError('$path: singleton cannot support Remove');
    }
    if (!node.isSingleton && node.listing == null) {
      throw StateError('$path: missing listing');
    }
    final parentQuery = node.listing?.parentQuery;
    if (parentQuery != null) {
      final parentField = node.fields[parentQuery];
      final parent = roots[parentField?.value.referenceTarget];
      if (parentField?.canQuery != true ||
          parent?.listing == null ||
          identical(parent, node)) {
        throw StateError('$path: invalid search parent query');
      }
    }
    final keys = <(_ResourceTool, _ResourceTargetKind, String?)>{};
    for (final op in node.operations) {
      final opPath =
          '$path/${op.tool.name}/${op.target.name}/${op.field ?? ""}';
      if (!keys.add(op.key)) {
        throw StateError('$opPath: duplicate operation');
      }
      if (op.target == _ResourceTargetKind.field &&
          !node.fields.containsKey(op.field)) {
        throw StateError('$opPath: unknown field');
      }
      if (op.tool == _ResourceTool.edit &&
          op.target != _ResourceTargetKind.field) {
        throw StateError('$opPath: Edit requires an explicit field target');
      }
      final input = node.inputProperties(op);
      checkAliases(input, opPath);
      for (final entry in op.parameters.entries) {
        if (node.fields.containsKey(entry.key)) {
          throw StateError('$opPath: parameter shadows field ${entry.key}');
        }
        checkValue(entry.value.value, '$opPath/${entry.key}', {});
        if (entry.value.hasDefault &&
            !entry.value.value.accepts(entry.value.defaultValue)) {
          throw StateError('$opPath: invalid parameter default');
        }
      }
      final value = node.inputValue(op);
      if (value != null) {
        checkValue(value, opPath, {});
      }
      if (op.result.value != null) {
        checkValue(op.result.value!, '$opPath/result', {});
      }
      if (op.input.kind == _ResourceInputKind.field_value && value == null) {
        throw StateError('$opPath: missing field input value');
      }
      if (op.input.kind == _ResourceInputKind.array_value &&
          op.input.value?.type != _ValueType.array) {
        throw StateError('$opPath: missing array input');
      }
      for (final rule in op.constraints) {
        if (rule.kind == _ConstraintKind.target_requirement) {
          if (!node.fields.containsKey(rule.whenField)) {
            throw StateError('$opPath: unknown target property');
          }
        } else if (rule.fields.any((key) => !input.containsKey(key)) ||
            (rule.whenField != null && !input.containsKey(rule.whenField))) {
          throw StateError('$opPath: constraint references unknown input');
        }
      }
    }
    for (final entry in node.fields.entries) {
      final field = entry.value;
      for (final rule
          in field.read?.constraints ?? const <_ResourceConstraint>[]) {
        final discriminator = node.fields[rule.whenField];
        if (rule.kind != _ConstraintKind.target_requirement ||
            rule.fields.isNotEmpty ||
            rule.whenValues.isEmpty ||
            discriminator?.read?.detail != true ||
            (node.listing != null && discriminator?.read?.listing != true) ||
            discriminator!.read!.constraints.isNotEmpty ||
            rule.whenValues.any(
              (value) => !discriminator.value.accepts(value),
            )) {
          throw StateError(
            '$path/${entry.key}: invalid read target requirement',
          );
        }
      }
      if (field.canWrite &&
          !node.operations.any(
            (op) =>
                op.tool == _ResourceTool.write &&
                (op.field == entry.key ||
                    (op.target == _ResourceTargetKind.resource &&
                        field.write!.resource)),
          )) {
        throw StateError(
          '$path/${entry.key}: Write field without an operation',
        );
      }
      checkValue(field.value, '$path/${entry.key}', {});
      if (field.canEdit && field.type != _ValueType.string) {
        throw StateError('$path/${entry.key}: Edit requires text');
      }
      if (field.canCreate && create == null) {
        throw StateError('$path/${entry.key}: Create field without operation');
      }
      if (field.write?.resource == true &&
          node.operation(_ResourceTool.write, _ResourceTargetKind.resource) ==
              null) {
        throw StateError(
          '$path/${entry.key}: resource Write field without operation',
        );
      }
      for (final use in [
        field.create,
        field.write,
      ].whereType<_FieldInputUse>()) {
        final schema = use.value ?? field.value;
        checkValue(schema, '$path/${entry.key}/input', {});
        if (use.hasDefault && !schema.accepts(use.defaultValue)) {
          throw StateError('$path/${entry.key}: invalid default');
        }
      }
    }
    final segments = <String>{};
    for (final child in node.children) {
      if (!segments.add(child.segment)) {
        throw StateError('$path: duplicate child ${child.segment}');
      }
      visit(child, '$path/${child.segment}', group);
    }
    active.remove(node);
  }

  for (final entry in roots.entries) {
    if (entry.key != entry.value.segment) {
      throw StateError('${entry.key}: root segment mismatch');
    }
    visit(entry.value, entry.key, entry.value.group);
  }
}

Map<String, _ValueProperty> _projectResourceFields(
  Map<String, _ResourceField> fields,
  _FieldProjection projection, {
  bool requireFields = true,
}) => {
  for (final entry in fields.entries)
    if (switch (projection) {
      _FieldProjection.detail => entry.value.read?.detail ?? false,
      _FieldProjection.listing => entry.value.read?.listing ?? false,
      _FieldProjection.create => entry.value.canCreate,
      _FieldProjection.existing_item =>
        entry.value.canCreate || entry.key == 'id',
      _FieldProjection.write => entry.value.write?.resource ?? false,
    })
      entry.key: _ValueProperty(
        switch (projection) {
          _FieldProjection.create =>
            entry.value.create?.value ?? entry.value.value,
          _FieldProjection.write => entry.value.writeValue,
          _ => entry.value.value,
        },
        required:
            requireFields &&
            projection == _FieldProjection.create &&
            entry.value.requiredOnCreate,
        description: entry.value.description,
        aliases: entry.value.aliases,
      ),
};

/// listing 的标题/名称模糊搜索参数。不是资源字段，只出现在 query。
const _listingSearchQueryParam = 'search';

Map<String, dynamic>? _validateTargetRequirements(
  ParsedPath parsed,
  _ResourceTool tool,
  Map<String, dynamic> input,
  Map<String, dynamic> target,
) {
  final resource = parsed._resource!;
  final operation = resource.schema.operation(
    tool,
    parsed.hasField ? _ResourceTargetKind.field : _ResourceTargetKind.resource,
    parsed.field,
  )!;
  final constraints = [
    ...operation.constraints,
    if (!parsed.hasField && tool == _ResourceTool.write)
      for (final field in input.keys)
        ...?resource.schema.fields[field]?.write?.constraints,
  ];
  for (final constraint in constraints) {
    if (constraint.kind == _ConstraintKind.target_requirement &&
        !constraint.accepts(input, target: target)) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        'This operation requires ${constraint.whenField}=${constraint.whenValues.join(' or ')}.',
        hint: 'Read /_schema/${parsed.collection}.',
      );
    }
  }
  return null;
}

Map<String, dynamic>? _resourceOperationGate(
  ParsedPath parsed,
  _ResourceTool tool,
) {
  final target = parsed._resource;
  if (target == null) {
    return _resourceError(
      parsed.displayPath,
      ToolErrorCode.invalid_argument,
      'Unsupported resource path.',
    );
  }
  final kind = target.field != null
      ? _ResourceTargetKind.field
      : target.listing
      ? _ResourceTargetKind.listing
      : _ResourceTargetKind.resource;
  var operation = target.schema.operation(tool, kind, target.field);
  // 层级文档的名称路径可指向待创建文档或目录内的新条目。
  if (tool == _ResourceTool.create &&
      kind == _ResourceTargetKind.resource &&
      target.schema.address.kind == _AddressKind.hierarchical_name) {
    operation = target.schema.operation(tool, _ResourceTargetKind.listing);
  }
  if (operation != null) {
    return null;
  }
  return _resourceOperationError(parsed, tool);
}

/// 仅适配已经拒绝的操作，不参与权限判定；保留旧错误码和处理建议。
Map<String, dynamic> _resourceOperationError(
  ParsedPath parsed,
  _ResourceTool tool,
) {
  final target = parsed._resource!;
  final kind = target.field != null
      ? _ResourceTargetKind.field
      : target.listing
      ? _ResourceTargetKind.listing
      : _ResourceTargetKind.resource;
  if (parsed.collection == 'outlines' && target.hasUnknownField) {
    return _resourceError(
      parsed.displayPath,
      ToolErrorCode.invalid_argument,
      'Unsupported resource path. Read /_schema/${parsed.collection}.',
    );
  }
  if (target.schema.isSingleton &&
      target.schema.isReadOnly &&
      tool != _ResourceTool.read &&
      tool != _ResourceTool.remove) {
    return _resourceError(
      parsed.displayPath,
      ToolErrorCode.permission_denied,
      'This resource is read-only.',
    );
  }
  if (tool == _ResourceTool.edit) {
    if (kind == _ResourceTargetKind.resource) {
      return _editFieldRequiredError(parsed);
    }
    if (kind == _ResourceTargetKind.field) {
      return _editFieldNotEditableError(
        path: parsed.displayPath,
        node: target.schema,
        field: target.field!,
        noun: target.schema.segment,
      );
    }
    if (kind == _ResourceTargetKind.listing &&
        target.schema.operation(_ResourceTool.write, kind) != null) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.unsupported,
        'Use Write on ${parsed.displayPath} with value.',
        hint: 'Editable with Edit: ${_editableFieldList(target.schema)}.',
      );
    }
    if (kind == _ResourceTargetKind.listing) {
      return _resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        'Edit requires a resource and explicit field.',
      );
    }
  }
  if (tool == _ResourceTool.create && kind == _ResourceTargetKind.resource) {
    final collectionPath = canonicalResourcePath(
      target.segments.take(target.segments.length - 1).join('/'),
    );
    return _resourceError(
      parsed.displayPath,
      ToolErrorCode.invalid_argument,
      'Create must target the collection.',
      hint: target.schema.usesNamePath
          ? 'Move the title into fields: {"path":"$collectionPath","fields":{"title":"..."}}'
          : 'The id is generated on create; use {"path":"$collectionPath","fields":{...}}.',
    );
  }
  if (tool == _ResourceTool.write &&
      kind == _ResourceTargetKind.listing &&
      target.schema == _resourceDefinitions[parsed.collection] &&
      parsed.collection != 'canvas') {
    return _resourceError(
      parsed.displayPath,
      ToolErrorCode.unsupported,
      'Use Create /${parsed.displayPath} to create a resource.',
    );
  }
  if (tool == _ResourceTool.remove) {
    return AiToolManager._structuredWriteError(
      path: parsed.displayPath,
      errorCode: ToolErrorCode.invalid_argument,
      message:
          'Remove requires a removable resource, not a collection or field.',
      operation: 'delete',
    );
  }
  if (tool == _ResourceTool.write &&
      parsed.collection == 'canvas' &&
      !parsed.hasField) {
    return _resourceError(
      parsed.displayPath,
      ToolErrorCode.permission_denied,
      'This target does not support Write.',
    );
  }
  if (target.schema.group == contentKindScreenplay) {
    return _invalidScreenplayPath(parsed);
  }
  if (tool == _ResourceTool.write &&
      target.field != null &&
      target.schema.fields[target.field]?.canRead == true &&
      target.schema.fields[target.field]?.canWrite != true) {
    return _skippedReadOnlyWriteResult(
      path: parsed.displayPath,
      field: target.field!,
      resourceLabel: target.schema.segment,
    );
  }
  final allowed = switch (tool) {
    _ResourceTool.read => target.schema.readFields,
    _ResourceTool.write => [
      for (final entry in target.schema.fields.entries)
        if (entry.value.writePath) entry.key,
    ],
    _ResourceTool.edit => target.schema.editableFields,
    _ => <String>[],
  };
  final label = target.schema.segment == 'volumes'
      ? 'volume'
      : target.schema.segment;
  return _resourceError(
    parsed.displayPath,
    ToolErrorCode.invalid_argument,
    'Unknown $label field: ${target.field}. '
    '${tool == _ResourceTool.write ? 'Writable' : 'Supported'} fields: ${allowed.join(', ')}.',
  );
}

class _ResourceInputSources {
  _ResourceInputSources(this.values);
  final List<Object?> values;
}

void _addResourceInputSource(
  Map<String, dynamic> fields,
  String key,
  Object? value,
) {
  if (!fields.containsKey(key)) {
    fields[key] = value;
  } else {
    final previous = fields[key];
    fields[key] = _ResourceInputSources([
      if (previous is _ResourceInputSources) ...previous.values else previous,
      value,
    ]);
  }
}

String _resourceEnumFormat(String value) => value
    .trim()
    .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
    .replaceAllMapped(RegExp(r'([A-Z])([A-Z][a-z])'), (m) => '${m[1]}_${m[2]}')
    .toLowerCase()
    .replaceAll(RegExp(r'[-_\s]+'), '_');

Iterable<Object?> _resourceInputValues(Object? raw) sync* {
  if (raw is _ResourceInputSources) {
    for (final value in raw.values) {
      yield* _resourceInputValues(value);
    }
  } else {
    yield raw;
  }
}

Object? _normalizeResourceValue(
  Object? raw,
  _ValueSchema schema,
  String path,
  List<_ResourceInputIssue> issues, {
  required List<String> ignored,
}) {
  if (raw == null) {
    if (schema.nullable) {
      return null;
    }
    return switch (schema.type) {
      _ValueType.string => '',
      _ValueType.array => <dynamic>[],
      _ => null,
    };
  }
  Object? value = raw;
  switch (schema.type) {
    case _ValueType.integer:
    case _ValueType.number:
      final number = raw is num
          ? raw
          : raw is String
          ? num.tryParse(raw.trim())
          : null;
      if (number != null && number.isFinite) {
        value = schema.type == _ValueType.integer ? number.round() : number;
      }
    case _ValueType.boolean:
      value = switch (raw is String ? raw.trim().toLowerCase() : raw) {
        true || 'true' || 'yes' || '1' || 1 => true,
        false || 'false' || 'no' || '0' || 0 => false,
        _ => raw,
      };
    case _ValueType.string:
      if (schema.referenceTarget != null ||
          schema.referenceTargetsByField.isNotEmpty) {
        return schema.nullable && raw == '' ? null : raw;
      }
      if (schema.nullable && raw == '' && schema.enumValues.isNotEmpty) {
        return null;
      }
      if (raw is String || raw is num || raw is bool) {
        value = raw.toString().trim();
      }
      if (value is String &&
          schema.enumValues.isNotEmpty &&
          !schema.enumValues.contains(value) &&
          !schema._matchesPattern(value)) {
        final formatted = _resourceEnumFormat(value);
        value =
            schema.enumValues
                .whereType<String>()
                .where((item) => _resourceEnumFormat(item) == formatted)
                .firstOrNull ??
            schema.enumAliases.entries
                .where((entry) => _resourceEnumFormat(entry.key) == formatted)
                .firstOrNull
                ?.value ??
            value;
      }
    case _ValueType.array:
    case _ValueType.object:
      if (raw is String) {
        try {
          value = jsonDecode(raw.trim());
        } catch (_) {
          value = tryExtractJson(raw) ?? raw;
        }
      }
      if (schema.type == _ValueType.object && value is! Map ||
          schema.type == _ValueType.array && value is! List) {
        return raw;
      }
      if (schema.type == _ValueType.object &&
          value is Map &&
          value.keys.every((key) => key is String)) {
        final extra = schema.additionalProperties
            ? Map<String, dynamic>.from(value)
            : <String, dynamic>{};
        value = <String, dynamic>{
          ...extra,
          ..._normalizeResourceFields(
            Map<String, dynamic>.from(value)..removeWhere(
              (key, _) =>
                  schema.additionalProperties &&
                  !schema.objectProperties.containsKey(key),
            ),
            schema.objectProperties,
            path,
            issues,
            allFields: schema.fieldReference ?? const {},
            ignored: ignored,
          ),
        };
      } else if (schema.type == _ValueType.array && value is List) {
        final normalized = <Object?>[];
        final ids = <Object?>{};
        for (var i = 0; i < value.length; i++) {
          final item = _normalizeResourceValue(
            value[i],
            schema.items!,
            '$path[$i]',
            issues,
            ignored: ignored,
          );
          _validateResourceValue(item, schema.items!, '$path[$i]', issues);
          if (schema.identity == _ArrayIdentity.optional_existing_id &&
              item is Map &&
              item['id'] != null &&
              !ids.add(item['id'])) {
            issues.add(
              _ResourceInputIssue('duplicate_id', field: '$path[$i].id'),
            );
          }
          if (schema.identity == _ArrayIdentity.references &&
              item is String &&
              !ids.add(item)) {
            issues.add(_ResourceInputIssue('duplicate_id', field: '$path[$i]'));
          }
          if (schema.identity != _ArrayIdentity.plain_values ||
              !normalized.any(
                (existing) => _jsonLikeValuesEqual(existing, item),
              )) {
            normalized.add(item);
          }
        }
        value = normalized;
      }
  }
  return value;
}

/// 未知与当前操作不可写的键记入 [ignored] 并跳过，不进 [issues]；嵌套对象和数组
/// 元素用同一条规则，位置沿用 `beats[0].foo` 这样的定位串。
Map<String, dynamic> _normalizeResourceFields(
  Map<String, dynamic> raw,
  Map<String, _ValueProperty> properties,
  String prefix,
  List<_ResourceInputIssue> issues, {
  required List<String> ignored,
  Map<String, _ResourceField> allFields = const {},
  bool create = false,
}) {
  final sources = <String, dynamic>{};
  for (final entry in raw.entries) {
    final key = properties.containsKey(entry.key)
        ? entry.key
        : properties.entries
                  .where(
                    (property) => property.value.aliases.contains(entry.key),
                  )
                  .firstOrNull
                  ?.key ??
              entry.key;
    _addResourceInputSource(sources, key, entry.value);
  }
  final normalized = <String, dynamic>{};
  String location(String key) => prefix.isEmpty ? key : '$prefix.$key';
  for (final entry in sources.entries) {
    final property = properties[entry.key];
    if (property == null) {
      ignored.add(location(entry.key));
      continue;
    }
    final fieldIssues = <_ResourceInputIssue>[];
    final values = <Object?>[];
    for (final source in _resourceInputValues(entry.value)) {
      final field = allFields[entry.key];
      final use = create ? field?.create : field?.write;
      final value = _normalizeResourceValue(
        source == null && use?.hasDefault == true ? use!.defaultValue : source,
        property.value,
        location(entry.key),
        fieldIssues,
        ignored: ignored,
      );
      values.add(value);
      if (property.required &&
          ((value == null && !property.value.nullable) ||
              (create && value is String && value.isEmpty))) {
        fieldIssues.add(
          _ResourceInputIssue('required', field: location(entry.key)),
        );
      } else {
        _validateResourceValue(
          value,
          property.value,
          location(entry.key),
          fieldIssues,
        );
      }
    }
    normalized[entry.key] = values.first;
    if (values
        .skip(1)
        .any((value) => !_jsonLikeValuesEqual(value, values.first))) {
      fieldIssues.add(
        _ResourceInputIssue(
          'conflicting_fields',
          field: location(entry.key),
          value: property.value,
        ),
      );
    }
    // Repeated sources must not repeat the same leaf problem or reorder diagnostics.
    final uniqueIssues = <String, _ResourceInputIssue>{
      for (final issue in fieldIssues) jsonEncode(issue.toJson()): issue,
    };
    for (final key in uniqueIssues.keys.toList()..sort()) {
      issues.add(uniqueIssues[key]!);
    }
  }
  for (final entry in properties.entries) {
    if (entry.value.required && !sources.containsKey(entry.key)) {
      issues.add(_ResourceInputIssue('required', field: location(entry.key)));
    }
  }
  return normalized;
}

void _validateResourceValue(
  Object? value,
  _ValueSchema schema,
  String path,
  List<_ResourceInputIssue> issues,
) {
  // Recursive values were checked while normalizing; report only their leaf issues.
  if (schema.type == _ValueType.object &&
          value is Map &&
          value.keys.every((key) => key is String) ||
      schema.type == _ValueType.array && value is List) {
    return;
  }
  if (!schema.accepts(value)) {
    issues.add(
      _ResourceInputIssue(
        schema.enumValues.isNotEmpty
            ? 'invalid_enum'
            : schema.type == _ValueType.integer
            ? 'invalid_integer'
            : 'invalid_type',
        field: path,
        value: schema,
        suggestion: schema.enumValues.isNotEmpty && value is String
            ? _EnumValidator._findClosestMatch(
                value,
                schema.enumValues.whereType<String>().toList(),
              )
            : null,
      ),
    );
  }
}

/// 一条静态输入问题；所有资源共同收集，兼容错误码仅在出口投影。
class _ResourceInputIssue {
  const _ResourceInputIssue(
    this.code, {
    this.field,
    this.fields = const [],
    this.value,
    this.constraint,
    this.suggestion,
  });

  final String code;
  final String? field;
  final List<String> fields;
  final _ValueSchema? value;
  final _ResourceConstraint? constraint;
  final String? suggestion;

  Map<String, dynamic> toJson() => {
    'code': code,
    if (field != null) 'field': field,
    if (fields.isNotEmpty) 'fields': fields,
    if (value?.enumValues.isNotEmpty == true)
      'enum': [...value!.enumValues, if (value!.nullable) null],
    if (value?.minimum != null) 'minimum': value!.minimum,
    if (value?.maximum != null) 'maximum': value!.maximum,
    if (value?.minLength != null) 'min_length': value!.minLength,
    if (suggestion != null) 'suggestion': suggestion,
    if (code == 'invalid_type' && value != null)
      'expected_type': _valueTypeNote(value!),
    if (constraint?.kind == _ConstraintKind.at_least_one)
      'at_least_one_of': constraint!.fields,
    if (constraint?.kind == _ConstraintKind.mutually_exclusive)
      'at_most_one_of': constraint!.fields,
  };
}

/// Normalize and validate once for Create, Write and its preview.
///
/// `ignoredFields` 是被跳过的未知或不可写键；剩下的有效字段照常校验，值不合法仍
/// 整次拒绝。
({
  Map<String, dynamic>? fields,
  Map<String, dynamic>? error,
  List<String> ignoredFields,
})
_prepareResourceInput(
  ParsedPath parsed,
  Map<String, dynamic> fields, {
  required bool create,
}) {
  final target = parsed._resource!;
  final tool = create ? _ResourceTool.create : _ResourceTool.write;
  final kind = create
      ? _ResourceTargetKind.listing
      : parsed.hasField
      ? _ResourceTargetKind.field
      : target.listing
      ? _ResourceTargetKind.listing
      : _ResourceTargetKind.resource;
  final operation = target.schema.operation(
    tool,
    kind,
    create ? null : parsed.field,
  )!;
  final properties = kind == _ResourceTargetKind.field
      ? {
          ...target.schema.inputProperties(operation),
          parsed.field!: _ValueProperty(
            target.schema.inputValue(operation)!,
            required: true,
            aliases: target.schema.fields[parsed.field]?.aliases ?? const [],
          ),
        }
      : operation.input.kind == _ResourceInputKind.array_value
      ? {
          operation.input.field!: _ValueProperty(
            operation.input.value!,
            required: true,
          ),
        }
      : target.schema.inputProperties(operation);
  if (create &&
      target.schema.address.kind == _AddressKind.hierarchical_name &&
      parsed.hasId) {
    final key = target.schema.address.nameField!;
    final property = properties[key]!;
    properties[key] = _ValueProperty(property.value, aliases: property.aliases);
  }
  final issues = <_ResourceInputIssue>[];
  final ignored = <String>[];
  final normalized = _normalizeResourceFields(
    fields,
    properties,
    '',
    issues,
    ignored: ignored,
    allFields: target.schema.fields,
    create: create,
  );
  // 写入的字段被跳光时不再评估约束：没有可写的值，约束没有判断对象，调用方据此
  // 跳过执行器。Create 仍要报必填缺失。
  if (!create && issues.isEmpty && normalized.isEmpty && ignored.isNotEmpty) {
    return (fields: normalized, error: null, ignoredFields: ignored);
  }
  if (!create && fields.isEmpty && kind != _ResourceTargetKind.field) {
    issues.add(
      _ResourceInputIssue('required', fields: properties.keys.toList()),
    );
  }
  for (final constraint in operation.constraints) {
    if (constraint.kind != _ConstraintKind.target_requirement &&
        !constraint.accepts(normalized)) {
      final affected = constraint.fields
          .where(
            (field) => !issues.any(
              (issue) => issue.code == 'required' && issue.field == field,
            ),
          )
          .toList();
      if (affected.isNotEmpty) {
        issues.add(
          _ResourceInputIssue(
            constraint.kind == _ConstraintKind.mutually_exclusive
                ? 'conflicting_fields'
                : 'required',
            fields: affected,
            constraint: constraint,
          ),
        );
      }
    }
  }
  return issues.isEmpty
      ? (fields: normalized, error: null, ignoredFields: ignored)
      : (
          fields: null,
          error: _resourceInputError(parsed, tool, issues, properties),
          ignoredFields: ignored,
        );
}

/// 被跳过的字段不改变成功或失败，只在响应里留一条可执行的提示。
Map<String, dynamic> _attachIgnoredFields(
  Map<String, dynamic> result,
  List<String> ignoredFields,
) {
  if (ignoredFields.isEmpty) {
    return result;
  }
  final warning = 'Ignored unsupported fields: ${ignoredFields.join(', ')}.';
  return {
    ...result,
    'ignored_fields': ignoredFields,
    'warning': warning,
    'hint': result['hint'] ?? warning,
  };
}

Map<String, dynamic> _resourceInputError(
  ParsedPath parsed,
  _ResourceTool tool,
  List<_ResourceInputIssue> issues,
  Map<String, _ValueProperty> properties,
) {
  final missing = <String>{
    for (final issue in issues.where(
      (issue) =>
          issue.code == 'required' &&
          issue.constraint?.kind != _ConstraintKind.at_least_one,
    ))
      if (issue.field != null) issue.field! else ...issue.fields,
  }.toList();
  final messages = <String>{};
  for (final issue in issues) {
    final names = issue.field ?? issue.fields.join(', ');
    if (issue.constraint?.kind == _ConstraintKind.at_least_one) {
      messages.add(
        'Provide at least one of ${issue.fields.join(', ')} in fields.',
      );
    } else if (issue.constraint?.kind == _ConstraintKind.mutually_exclusive) {
      messages.add('Provide only one of ${issue.fields.join(', ')} in fields.');
    } else if (issue.code == 'required') {
      messages.add('Missing $names in fields.');
    } else if (issue.code == 'conflicting_fields') {
      messages.add('Conflicting values for $names; provide one value.');
    } else if (issue.value case final value?) {
      final requirements = _valueFieldNotes(
        value,
        includeType: false,
      ).join(', ');
      messages.add(
        '$names must be ${_valueTypeNote(value)}'
        '${requirements.isEmpty ? '' : ' ($requirements)'}'
        '${value.enumValues.isEmpty ? '' : '; allowed: ${value.enumValues.join(', ')}'}'
        '${value.pattern == null ? '' : '; or matching ${value.pattern}'}.'
        '${issue.suggestion == null ? '' : ' Use ${issue.suggestion}.'}',
      );
    } else {
      messages.add('$names: ${issue.code}.');
    }
  }
  return _resourceValidationResult(
    parsed,
    tool,
    issues,
    error: {
      ..._resourceError(
        parsed.displayPath,
        ToolErrorCode.invalid_argument,
        messages.join(' '),
      ),
      if (missing.isNotEmpty) 'missing_fields': missing,
      if (missing.isNotEmpty) 'required_fields': missing,
    },
    allowedFields: properties.keys.toList(),
  );
}

/// 参数外壳尚不能成为资源字段时，仍使用同一种问题和响应投影。
Map<String, dynamic> _resourceInputEnvelopeError({
  required ParsedPath parsed,
  _ResourceTool tool = _ResourceTool.write,
  required ToolErrorCode errorCode,
  required String message,
  required List<_ResourceInputIssue> issues,
  List<String>? missingFields,
  List<String>? requiredFields,
  String? hint,
  String? operation,
}) => _resourceValidationResult(
  parsed,
  tool,
  issues,
  error: AiToolManager._structuredWriteError(
    path: parsed.displayPath,
    errorCode: errorCode,
    message: message,
    operation: operation ?? tool.name,
    missingFields: missingFields,
    requiredFields: requiredFields,
    hint: hint,
  ),
);

Map<String, dynamic> _resourceValidationResult(
  ParsedPath parsed,
  _ResourceTool tool,
  List<_ResourceInputIssue> issues, {
  required Map<String, dynamic> error,
  List<String>? allowedFields,
}) {
  final first =
      issues.where((issue) => issue.code == 'read_only_field').firstOrNull ??
      issues.first;
  return _withContractHint(
    {
      ...error,
      'operation': error['operation'] ?? tool.name,
      'allowed_fields': ?allowedFields,
      'validation_errors': issues.map((issue) => issue.toJson()).toList(),
      if (first.value?.enumValues.isNotEmpty == true) 'enum_field': first.field,
      if (first.field != null && first.field != 'fields')
        'field_constraint': {
          'field': first.field,
          if (first.value?.enumValues.isNotEmpty == true)
            'enum': [
              ...first.value!.enumValues,
              if (first.value!.nullable) null,
            ],
          'pattern': ?first.value?.pattern,
          if (first.code == 'required') 'required': true,
        },
    },
    {'path': parsed.displayPath},
  );
}

Map<String, dynamic>? _validateResourceQuery(ParsedPath parsed) {
  if (!parsed.hasQuery) {
    return null;
  }
  final resource = parsed._resource;
  final node = resource?.schema;
  final strict =
      node?.group == contentKindScreenplay || node?.group == contentKindCanvas;
  final allowed = node != null && (!strict || resource!.listing)
      ? node.queryFields
      : <String>[];
  if (!strict && allowed.isEmpty) {
    return _resourceError(
      parsed.displayPath,
      ToolErrorCode.unsupported,
      'Query parameters are not supported for ${parsed.collection} listing paths.',
    );
  }
  final invalid = parsed.queryParameters.entries
      .where((entry) {
        if (!allowed.contains(entry.key)) {
          return true;
        }
        final field = node!.fields[entry.key];
        final parameter = node
            .operation(_ResourceTool.read, _ResourceTargetKind.listing)
            ?.parameters[entry.key];
        final value = field?.value ?? parameter!.value;
        final query = field?.query ?? parameter?.query;
        final normalized = (query?.normalization ?? _QueryNormalization.string)
            .normalize(entry.value);
        // URL query 参数只能传单个值；数组字段的过滤语义是「数组含该元素」，
        // 因此按 items 校验，而不是要求传入完整数组。
        final queryValue = value.type == _ValueType.array ? value.items : value;
        return queryValue == null || !queryValue.accepts(normalized);
      })
      .map((entry) => entry.key)
      .toList();
  if (invalid.isEmpty) {
    return null;
  }
  return {
    ..._resourceError(
      parsed.displayPath,
      ToolErrorCode.invalid_argument,
      strict
          ? 'Unsupported query parameters or values: ${invalid.join(', ')}.'
          : 'Invalid query parameters: ${invalid.join(', ')}. Allowed: ${allowed.join(', ')}.',
    ),
    'allowed_query_params': allowed,
  };
}

/// 按 schema 匹配后的资源层级；父 ID 与末级 ID 不混用。
class _ResolvedResourcePath {
  const _ResolvedResourcePath(
    this.schema,
    this.ids, {
    this.field,
    this.listing = false,
    this.listingValue,
    this.segments = const [],
  });
  final _ResourceDefinition schema;
  final Map<String, String> ids;
  final String? field;
  final bool listing;
  final _ResourceField? listingValue;
  final List<String> segments;

  _ResourceOperation? operation(_ResourceTool tool) => schema.operation(
    tool,
    field != null
        ? _ResourceTargetKind.field
        : listing
        ? _ResourceTargetKind.listing
        : _ResourceTargetKind.resource,
    field,
  );

  bool get hasUnknownField =>
      field != null &&
      !schema.operations.any(
        (operation) =>
            operation.target == _ResourceTargetKind.field &&
            operation.field == field,
      );
}

_ResolvedResourcePath? _resolveResourcePath(
  List<String> parts,
  _ResourceDefinition root,
) {
  var node = root;
  var index = 1;
  final ids = <String, String>{};
  _ResourceDefinition? parent;
  while (true) {
    if (!node.isSingleton) {
      if (index == parts.length) {
        return _ResolvedResourcePath(
          node,
          ids,
          segments: parts,
          listing: true,
          listingValue: parent?.fields[node.listingWriteField],
        );
      }
      if (node.address.kind == _AddressKind.hierarchical_name) {
        final remaining = parts.sublist(index);
        final field =
            remaining.length > 1 &&
                node.pathFieldSegments.contains(remaining.last)
            ? remaining.removeLast()
            : null;
        ids[node.itemToken] = remaining.join('/');
        return _ResolvedResourcePath(node, ids, segments: parts, field: field);
      }
      ids[node.itemToken] = parts[index++];
    }
    if (index == parts.length) {
      return _ResolvedResourcePath(node, ids, segments: parts);
    }
    final child = node.children
        .where((child) => child.segment == parts[index])
        .firstOrNull;
    if (child != null) {
      parent = node;
      node = child;
      index++;
      continue;
    }
    if (index == parts.length - 1) {
      // 尾段按字段保留，合法性由命中节点的操作定义判断。
      return _ResolvedResourcePath(
        node,
        ids,
        segments: parts,
        field: parts[index],
      );
    }
    return null;
  }
}

class ParsedPath {
  // 公共解析冻结本次调用的作品作用域；脱离工具调用的路径解析仍可独立使用。
  final _ResourceScope? _scope;

  /// 工具调用中相对与绝对路径都保留实际目标作品身份。
  String? get targetWorkId => workId ?? _scope?.targetWorkId;

  /// 跨作品路径中的稳定作品 ID；null 表示当前作品。
  final String? workId;

  /// 资源集合名称，如 'chapters', 'characters', 'lore' 等
  /// root 路径时为空字符串
  final String collection;

  /// 资源 ID，用于非 Document 类型（chapters, characters 等）
  /// 访问集合列表时为 null
  final String? id;

  /// 名称路径，用于 Document 类型（lore/outlines/materials）
  /// 支持多层嵌套，如 ['魔法系统', '火系魔法']
  /// 访问集合列表时为空列表
  final List<String> namePath;

  /// 资源字段名，如 'title', 'content', 'summary'
  /// 访问完整资源时为 null
  final String? field;

  /// URL 查询参数，如 {'source_type': 'character', 'relation_type': 'ally'}
  final Map<String, String> queryParameters;

  /// 规范化后的原始路径（去除首尾斜杠和查询字符串）
  final String originalPath;

  final _ResolvedResourcePath? _resource;

  bool get isValidResourcePath =>
      _resource != null && !_resource.hasUnknownField;
  String? get resourceSegment => _resource?.schema.segment;
  String? locator(String token) => _resource?.ids[token];
  String? get outlineBeatId => isOutlineBeat ? locator('beat_id') : null;
  bool get isOutlineBeat =>
      collection == 'outlines' && resourceSegment == 'beats';
  bool get isResourceListing => _resource?.listing == true;
  bool get canEditField =>
      _resource?.schema.operation(
        _ResourceTool.edit,
        _ResourceTargetKind.field,
        field,
      ) !=
      null;

  /// 是否为 root 路径
  bool get isRoot => collection.isEmpty;

  /// 是否显式指向某一部作品。
  bool get isCrossWork => workId != null;

  /// 是否为本地作品发现入口。
  bool get isWorksListing => collection == 'works' && workId == null;

  /// 是否包含资源 ID 或名称路径
  bool get hasId => id != null || namePath.isNotEmpty;

  /// 是否包含字段名
  bool get hasField => field != null;

  /// 是否使用名称路径（Document 类型）
  bool get usesNamePath => namePath.isNotEmpty;

  /// 是否包含查询参数
  bool get hasQuery => queryParameters.isNotEmpty;

  /// 当前作品输出相对路径，显式作品与全局入口保留绝对路径。
  String get displayPath => canonicalResourcePath(originalPath);

  /// 去掉 `/works/{work_id}` 后交给现有资源 handler 的路径。
  String get localDisplayPath {
    final targetWorkId = workId;
    if (targetWorkId == null) {
      return displayPath;
    }
    final prefix = 'works/$targetWorkId';
    if (originalPath == prefix) {
      return '/';
    }
    return canonicalResourcePath(originalPath.substring(prefix.length + 1));
  }

  /// 安全解码查询参数：非法 percent 转义（如 AI 路径里裸的 '%'）时退回原串，
  /// 不抛异常。否则该 path 的 card 每次 build 都抛 Illegal percent encoding，
  /// 流式期间反复重建会造成严重卡顿。
  static String _safeDecodeComponent(String input) {
    try {
      return Uri.decodeComponent(input);
    } catch (_) {
      return input;
    }
  }

  /// 解析原始路径字符串
  ///
  /// [rawPath] 可以是任意格式的路径，如 'chapters/123/content'、'chapters/123' 等
  /// 支持 URL 查询参数，如 'relations?source_type=character&relation_type=ally'
  /// 会自动规范化路径格式
  /// 对于 Document 类型，支持多层路径，如 'lore/魔法系统/火系魔法/content'
  static ParsedPath parse(
    String rawPath, {
    // ignore: library_private_types_in_public_api
    required _ResourceDefinition? Function(String) schemaLookup,
  }) {
    // 提取查询参数
    final queryStart = rawPath.indexOf('?');
    String pathPart;
    final queryParams = <String, String>{};
    if (queryStart >= 0) {
      pathPart = rawPath.substring(0, queryStart);
      final queryStr = rawPath.substring(queryStart + 1);
      for (final pair in queryStr.split('&')) {
        final eqIndex = pair.indexOf('=');
        if (eqIndex > 0) {
          final key = _safeDecodeComponent(pair.substring(0, eqIndex));
          final value = _safeDecodeComponent(pair.substring(eqIndex + 1));
          if (key.isNotEmpty) {
            queryParams[key] = value;
          }
        } else if (pair.isNotEmpty) {
          queryParams[_safeDecodeComponent(pair)] = '';
        }
      }
    } else {
      pathPart = rawPath;
    }

    var normalized = _normalizePath(pathPart);
    var segments = _splitPath(normalized);

    if (segments.firstOrNull == 'works') {
      if (segments.length == 1) {
        return ParsedPath._(
          collection: 'works',
          id: null,
          namePath: const [],
          field: null,
          queryParameters: queryParams,
          originalPath: normalized,
        );
      }

      final workId = segments[1];
      final inner = ParsedPath.parse(
        segments.skip(2).join('/'),
        schemaLookup: schemaLookup,
      );
      final canonicalPath = inner.originalPath.isEmpty
          ? 'works/$workId'
          : 'works/$workId/${inner.originalPath}';
      return ParsedPath._(
        workId: workId,
        resource: inner._resource,
        collection: inner.collection,
        id: inner.id,
        namePath: inner.namePath,
        field: inner.field,
        queryParameters: queryParams,
        originalPath: canonicalPath,
      );
    }

    if (segments.isEmpty) {
      return ParsedPath._(
        collection: '',
        id: null,
        namePath: const [],
        field: null,
        queryParameters: queryParams,
        originalPath: normalized,
      );
    }

    final collection = segments[0];
    final schema = schemaLookup(collection);

    final resource = schema == null
        ? null
        : _resolveResourcePath(segments, schema);
    final field = resource?.field;
    // 旧业务适配只接收匹配后的参数；不再参与路径语法判断。
    final namePath = schema?.usesNamePath == true
        ? segments
              .skip(1)
              .take(segments.length - 1 - (field == null ? 0 : 1))
              .toList()
        : <String>[];
    return ParsedPath._(
      resource: resource,
      collection: collection,
      id:
          schema?.usesNamePath == true ||
              schema?.isSingleton == true ||
              resource?.listing == true
          ? null
          : resource?.ids.values.lastOrNull,
      namePath: namePath,
      field: field,
      queryParameters: queryParams,
      originalPath: normalized,
    );
  }

  /// 私有构造函数，通过 [parse] 方法创建实例
  ParsedPath._({
    this._resource,
    this.workId,
    required this.collection,
    this.id,
    required this.namePath,
    this.field,
    this.queryParameters = const {},
    required this.originalPath,
  }) : _scope = _currentResourceCallContext?.scope;

  static final _multiSlash = RegExp(r'/+');
  static final _edgeSlash = RegExp(r'^/|/$');

  static String _normalizePath(String path) =>
      path.trim().replaceAll(_multiSlash, '/').replaceAll(_edgeSlash, '');

  static List<String> _splitPath(String normalizedPath) =>
      normalizedPath.isEmpty ? [] : normalizedPath.split('/');
}

List<Map<String, dynamic>> _buildRootDirectoryEntries({
  String kind = contentKindNovel,
}) {
  return [
    for (final schema in _resourceDefinitions.values)
      if (schema.supports(kind) && schema.discoverable)
        {'collection': schema.name, 'path': schema.name},
  ];
}

/// AI 路径空间以文件系统为目标心智模型：`/` 是全局根，挂载作品与全局只读资源；
/// 当前作品的绝对根由会话上下文注入，`chapters/...` 等路径相对该目录解析。
List<Map<String, dynamic>> _buildFilesystemRootDirectoryEntries() {
  return const [
    {'collection': 'works', 'path': '/works'},
    {'collection': '_schema', 'path': '/_schema'},
  ];
}

String? _collectionPathFromRootEntry(Object? entry) {
  if (entry is Map) {
    final map = Map<String, dynamic>.from(entry);
    final path = _parseStringArgument(map['path']);
    if (path.isNotEmpty) {
      return path;
    }
    final collection = _parseStringArgument(map['collection']);
    if (collection.isNotEmpty) {
      return _collectionDisplayPath(collection);
    }
    return null;
  }
  final collection = entry.toString().replaceAll('/', '');
  if (collection.isEmpty) {
    return null;
  }
  return _collectionDisplayPath(collection);
}

final _resourceIdPattern = RegExp(r'^[a-z]+_[A-Za-z0-9]+$');

bool _looksLikeResourceId(String segment) {
  return _resourceIdPattern.hasMatch(segment);
}

bool _isNotFoundErrorMessage(String message) {
  final lower = message.toLowerCase();
  return lower.contains('not found') || message.contains('未找到');
}

mixin _AiToolManagerPathHintsMixin on _AiToolManagerBase {
  Future<Map<String, dynamic>> _enrichNotFoundError(
    ParsedPath parsed,
    Map<String, dynamic> result,
  ) async {
    if (!result.containsKey('error')) {
      return result;
    }
    if (result['hint'] != null) {
      return result;
    }
    final errorCode = result['error_code'] as String?;
    if (errorCode != null && errorCode != ToolErrorCode.not_found.name) {
      return result;
    }
    final error = _parseStringArgument(result['error']);
    if (!_isNotFoundErrorMessage(error)) {
      return result;
    }

    final hint = await _notFoundHintForParsedPath(parsed);
    if (hint == null) {
      return result;
    }

    return {
      ...result,
      'error_code': result['error_code'] ?? ToolErrorCode.not_found.name,
      'path': result['path'] ?? parsed.displayPath,
      'hint': hint,
    };
  }

  Future<String?> _notFoundHintForParsedPath(ParsedPath parsed) async {
    if (parsed.isRoot) {
      return null;
    }

    final schema = _resourceDefinitions[parsed.collection];
    if (schema == null) {
      return null;
    }

    if (schema.usesNamePath) {
      return _namePathNotFoundHint(parsed, schema);
    }

    if (schema.isSingleton) {
      return null;
    }

    final key = parsed.id;
    if (key == null) {
      return null;
    }

    return _idPathNotFoundHint(parsed.collection, key);
  }

  Future<String?> _idPathNotFoundHint(String collection, String key) async {
    if (_looksLikeResourceId(key)) {
      return 'Resource id "$key" was not found. Read ${_resourceReferencePath(collection)} and copy entries[].path.';
    }

    return '$collection paths require resource ids from Read ${_resourceReferencePath(collection)} listing. '
        'Do not put title/name in the path segment.';
  }

  Future<String?> _namePathNotFoundHint(
    ParsedPath parsed,
    _ResourceDefinition schema,
  ) async {
    if (parsed.namePath.isEmpty) {
      return null;
    }

    for (final segment in parsed.namePath) {
      if (_looksLikeResourceId(segment)) {
        return 'Path segment "$segment" looks like a document id. '
            '${parsed.collection} uses title paths — use the document title instead.';
      }
    }

    return '${parsed.collection} paths use document titles. '
        'Read ${_resourceReferencePath(parsed.collection)} or a parent folder and copy entries[].path.';
  }
}

/// Write 的可写字段 = [_ResourceDefinition.writableFields]。
///
/// 字段权限仅来自统一定义。
List<String> _writableFields(String collection) {
  return _resourceDefinitions[collection]?.writableFields ?? const [];
}

String _editableFieldList(_ResourceDefinition node) =>
    node.editableFields.join(', ');

List<String> _writeScalarFields(_ResourceDefinition node) => [
  for (final operation in node.operations)
    if (operation.tool == _ResourceTool.write &&
        operation.target == _ResourceTargetKind.field &&
        node.operation(
              _ResourceTool.edit,
              _ResourceTargetKind.field,
              operation.field,
            ) ==
            null)
      operation.field!,
];

String _collectionDisplayPath(String collection) {
  return canonicalResourcePath(collection);
}

String _joinDisplayPath(String base, String segment) {
  final normalizedBase = base.endsWith('/')
      ? base.substring(0, base.length - 1)
      : base;
  return '$normalizedBase/$segment';
}

String _parentDisplayPath(ParsedPath parsed) {
  if (parsed.field == null) {
    return parsed.displayPath;
  }
  final segments = parsed.originalPath.split('/');
  if (segments.length <= 1) {
    return parsed.displayPath;
  }
  return canonicalResourcePath(
    segments.sublist(0, segments.length - 1).join('/'),
  );
}

String _resourceDisplayPath(ParsedPath parsed) {
  if (parsed.field != null) {
    return _parentDisplayPath(parsed);
  }
  return parsed.displayPath;
}

List<String>? _createAllowedFields(ParsedPath parsed) =>
    _isCreatableParsed(parsed) ? parsed._resource!.schema.createFields : null;

List<String> _createRequiredFields(ParsedPath parsed) =>
    _isCreatableParsed(parsed)
    ? parsed._resource!.schema.requiredFields
    : const [];

Map<String, dynamic> _createInputContract(ParsedPath parsed) {
  final allowedFields = _createAllowedFields(parsed) ?? const <String>[];
  final resourceSchema = parsed._resource?.listing == true
      ? parsed._resource?.schema
      : null;
  return {
    'required': ['path', 'fields'],
    'input': {'path': parsed.displayPath, 'fields': <String, dynamic>{}},
    'allowed_fields': allowedFields,
    'required_fields': _createRequiredFields(parsed),
    if (resourceSchema != null &&
        (resourceSchema.group == contentKindScreenplay ||
            resourceSchema != _resourceDefinitions[parsed.collection])) ...{
      'enum_fields': resourceSchema.createEnums,
      'positive_integer_fields': resourceSchema.positiveIntegerFields,
      if (resourceSchema.createExclusive.isNotEmpty)
        'at_most_one_of': resourceSchema.createExclusive,
    },
  };
}

/// 字段字典里**不展开**枚举取值的集合。
///
/// relations 的两个取值域都已经写在 AgentSkill「故事连续性维护」的关系附件里：实体类型 8 个值，
/// relation_type 按 (source_type, target_type) 二维展开。字典再抄一遍，等于把同一
/// 份清单常驻每一轮 —— 而 source_type / target_type 用的是同一个 entityTypes。
///
/// 拿掉不会让取值变得不可发现：[enumFields] 本身保留，公共校验仍从
/// 它取值，猜错时 invalid_entity_type / invalid_relation_type 的错误信息会带上该字段
/// 的全部合法值（见 tools_graph_test.dart 的两个错误路径用例）。
const _createEnumHiddenCollections = {'relations'};

/// 资源在路径里的定位段占位符：`{chapter_id}` / `{title}` / `{name}`。
///
/// ID 寻址的集合使用资源专名；[_ResourceDefinition.usesNamePath] 的集合用它自己的
/// 标识字段名 —— lore / materials / outlines / skills 等是 `title`，canvas 是 `name`。
String _pathKeyToken(_ResourceDefinition schema) =>
    '{${schema.address.itemToken!}}';

/// 单个资源的路径模板：`profile`、`chapters/{chapter_id}`、`lore/{title}`。
String _resourcePathTemplate(_ResourceDefinition schema) {
  final root = schema.name;
  if (schema.isSingleton) {
    return root;
  }
  return '$root/${_pathKeyToken(schema)}';
}

Iterable<({String listing, String item, _ResourceDefinition schema})>
_nestedResourceTemplates(
  String parent,
  List<_ResourceDefinition> children, {
  bool visibleOnly = false,
}) sync* {
  for (final child in children) {
    if (visibleOnly && child.hidden) {
      continue;
    }
    final listing = '$parent/${child.segment}';
    final item = '$listing/{${child.itemToken}}';
    yield (listing: listing, item: item, schema: child);
    yield* _nestedResourceTemplates(
      item,
      child.subResources,
      visibleOnly: visibleOnly,
    );
  }
}

String _resourceFieldNotes(_ResourceDefinition schema) {
  final lines = [
    for (final field in schema.fields.keys)
      if (field != 'id' || !schema.readOnlyFields.contains(field))
        _resourceFieldNote(schema, field, schema.enumFields[field]),
  ];
  if (schema.createExclusive.isNotEmpty) {
    lines.add('  - 创建时不可同时提供：${schema.createExclusive.join('、')}');
  }
  if (schema.writeExclusive.isNotEmpty) {
    lines.add('  - 修改时不可同时提供：${schema.writeExclusive.join('、')}');
  }
  return lines.join('\n');
}

String _resourceFieldNote(
  _ResourceDefinition schema,
  String field,
  List<String>? enumValues,
) {
  final spec = schema.fields[field];
  final parameter = schema.operations
      .map((operation) => operation.parameters[field])
      .whereType<_OperationParameter>()
      .firstOrNull;
  final value = spec?.value ?? parameter!.value;
  final description = schema.fieldDescriptions[field] ?? '';
  final markers = [
    if (schema.readOnlyFields.contains(field)) 'readonly',
    ..._valueFieldNotes(value),
    if (enumValues != null && enumValues.isNotEmpty)
      '取值 ${enumValues.join(' | ')}',
  ];
  final details = [
    if (description.isNotEmpty) description,
    if (value.example != null) '示例 ${jsonEncode(value.example)}',
  ];
  final star = schema.requiredFields.contains(field) ? '*' : '';
  final marker = markers.isEmpty ? '' : '（${markers.join('，')}）';
  return '  - $field$star$marker${details.isEmpty ? '' : '：${details.join('；')}'}';
}

String _subSchemaDisplayPath(
  _ResourceDefinition parent,
  _ResourceDefinition sub,
) => '${_resourcePathTemplate(parent)}/${sub.segment}';

/// 通用语法；可见集合的模板跟随各自字段表输出，hidden 资源不枚举。
String _buildPathGrammarReference({String kind = contentKindNovel}) {
  return [
    '- Read / Glob / Grep 的集合 listing 路径可带 query 过滤，如 '
        '${kind == contentKindCanvas
            ? 'production/clips?kind=video'
            : kind == contentKindScreenplay
            ? 'scenes?episode_id=...'
            : 'chapters?chapter_num=1'}。'
        '可用参数见各资源的 query；字段表中未标 query 的资源不支持 query。隐藏资源查询 /_schema 契约。',
    '- search 对 listing 的标题、名称等短文本字段做不区分大小写的包含匹配；'
        '其余 query 精准匹配（字符串不区分大小写）。',
    '- query 只过滤该 path 的直属条目：`lore?search=X` 查根级，'
        '`lore/魔法系统?search=X` 查该文件夹内。要跨层按标题定位用 Glob `**/{标题}`。',
    '- 字段路径：资源 path + "/" + 字段名，须由对应契约支持；子资源使用自己的 path。'
        '仅单字段可读的内容须单独 Read。改长文本用 Edit 做精确替换。',
  ].join('\n');
}

/// pathSchema 字段字典：含义、输入权限、类型、约束与示例。
/// 同一份 schema，只渲一次。
///
/// 只渲自身及所有祖先均为 `hidden: false` 的集合 / 子资源。隐藏节点的整棵子树跳过。
/// canvas、relations 以及默认 hidden 的
/// 子资源（nodes / edges）不出现，字段说明在各自的 bundled AgentSkill 里按需载入
/// ——这是刻意的常驻额度取舍，理由见 [_ResourceDefinition.hidden]。
String pathSchemaFieldNotes({String kind = contentKindNovel}) {
  final nestedNotes = <String>[];
  final groupedByNotes = <String, List<String>>{};
  for (final schema in _resourceDefinitions.values) {
    if (schema.hidden || !schema.supports(kind)) {
      continue;
    }
    if (schema.group == contentKindScreenplay && !schema.isSingleton) {
      nestedNotes.add('- ${_resourceLabel(schema, schema.name)}');
      nestedNotes.add(_resourcePathNote(schema, schema.name));
      nestedNotes.add(_resourceFieldNotes(schema));
    }
    if (schema.subResources.any((sub) => sub.group == contentKindScreenplay)) {
      for (final resource in _nestedResourceTemplates(
        _resourcePathTemplate(schema),
        schema.subResources,
        visibleOnly: true,
      )) {
        nestedNotes.add(
          '- ${_resourceLabel(resource.schema, resource.listing)}',
        );
        nestedNotes.add(_resourcePathNote(resource.schema, resource.listing));
        nestedNotes.add(_resourceFieldNotes(resource.schema));
      }
      continue;
    }
    if (schema.group == contentKindScreenplay && !schema.isSingleton) {
      continue;
    }
    _collectFieldNotes(
      groupedByNotes,
      displayPath: schema.name,
      fields: _fieldsForPathSchemaNotes(schema),
      schema: schema,
      enumFields: _createEnumHiddenCollections.contains(schema.name)
          ? const <String, List<String>>{}
          : schema.enumFields,
    );
    for (final sub in schema.subResources) {
      if (sub.hidden) {
        continue;
      }
      _collectFieldNotes(
        groupedByNotes,
        displayPath: _subSchemaDisplayPath(schema, sub),
        fields: _fieldsForSubSchemaNotes(sub),
        schema: sub,
        enumFields: sub.enumFields,
      );
    }
  }
  final lines = <String>[];
  for (final entry in groupedByNotes.entries) {
    lines.add('- ${entry.value.join('、')}');
    lines.add(entry.key);
  }
  lines.addAll(nestedNotes);
  return lines.join('\n');
}

List<String> _fieldsForPathSchemaNotes(_ResourceDefinition schema) {
  final seen = <String>{};
  final result = <String>[];
  void add(String field) {
    if (seen.add(field)) {
      result.add(field);
    }
  }

  for (final field in schema.createFields) {
    add(field);
  }
  for (final field in schema.readFields) {
    add(field);
  }
  for (final field in schema.readOnlyFields) {
    add(field);
  }
  for (final field in schema.fieldDescriptions.keys) {
    add(field);
  }
  return result;
}

List<String> _fieldsForSubSchemaNotes(_ResourceDefinition sub) {
  final seen = <String>{};
  final result = <String>[];
  void add(String field) {
    if (seen.add(field)) {
      result.add(field);
    }
  }

  for (final field in sub.createFields) {
    add(field);
  }
  for (final field in sub.readFields) {
    add(field);
  }
  for (final field in sub.readOnlyFields) {
    add(field);
  }
  for (final field in sub.fieldDescriptions.keys) {
    add(field);
  }
  return result;
}

void _collectFieldNotes(
  Map<String, List<String>> groupedByNotes, {
  required String displayPath,
  required List<String> fields,
  required _ResourceDefinition schema,
  required Map<String, List<String>> enumFields,
}) {
  final notes = <String>[_resourcePathNote(schema, displayPath)];
  for (final field in fields) {
    final isCreate = schema.createFields.contains(field);
    final isReadOnly = schema.readOnlyFields.contains(field);
    if (field == 'id' && isReadOnly) {
      continue;
    }
    final note = schema.fieldDescriptions[field];
    final enumValues = enumFields[field];
    if (!isCreate && !isReadOnly && note == null && enumValues == null) {
      continue;
    }
    notes.add(_resourceFieldNote(schema, field, enumValues));
  }
  if (notes.isEmpty) {
    return;
  }
  groupedByNotes
      .putIfAbsent(notes.join('\n'), () => <String>[])
      .add(_resourceLabel(schema, displayPath));
}

String _resourceLabel(_ResourceDefinition schema, String listing) =>
    schema.description.isEmpty ? listing : '$listing（${schema.description}）';

String _resourcePathNote(_ResourceDefinition schema, String listing) {
  if (schema.isSingleton) {
    return '  path: $listing';
  }
  final item = '$listing/{${schema.itemToken}}';
  final nested = schema.address.kind == _AddressKind.hierarchical_name
      ? '；支持多级：$listing/{folder}/{${schema.itemToken}}'
      : '';
  final listingWrite = schema.listingWriteField != null ? '；列表支持整体替换数组' : '';
  final queryFields = schema.queryFields;
  final query = queryFields.isEmpty
      ? ''
      : '\n  Read / Glob / Grep query: ${queryFields.join('、')}';
  return '  path: $item$nested$listingWrite$query';
}

String _valueTypeNote(_ValueSchema value) => value.type == _ValueType.array
    ? 'array<${_valueTypeNote(value.items!)}>'
    : value.type.name;

List<String> _valueFieldNotes(_ValueSchema value, {bool includeType = true}) =>
    [
      if (includeType && value.type != _ValueType.string) _valueTypeNote(value),
      if (value.minimum != null && value.maximum != null)
        '${value.minimum}～${value.maximum}'
      else ...[
        if (value.minimum != null) '>=${value.minimum}',
        if (value.maximum != null) '<=${value.maximum}',
      ],
      if (value.minLength != null) '最短 ${value.minLength} 字符',
      if (value.nullable) 'nullable',
    ];

/// 没有资源缺失时创建能力的集合，需要使用显式 Create。
String _buildCreateOnlyCollectionList() => _resourceDefinitions.values
    .where(
      (node) =>
          !node.isSingleton &&
          !node.operations.any(
            (op) =>
                op.tool == _ResourceTool.write &&
                op.missingTarget == _MissingTarget.create,
          ),
    )
    .map((node) => node.name)
    .join('、');

bool _isCreatableParsed(ParsedPath parsed) {
  final resource = parsed._resource;
  if (resource == null || parsed.hasField) {
    return false;
  }
  return (resource.schema.isSingleton ||
          resource.listing ||
          resource.schema.address.kind == _AddressKind.hierarchical_name) &&
      resource.schema.operation(
            _ResourceTool.create,
            resource.schema.isSingleton
                ? _ResourceTargetKind.resource
                : _ResourceTargetKind.listing,
          ) !=
          null;
}

/// create 失败时附带精准的字段级约束（该字段合法枚举值 / 单个缺失必需字段 /
/// 缺 fields 的入参契约）。完整字段清单见静态工具描述，不在此重复。
Map<String, dynamic> _attachCreateErrorContract(
  ParsedPath parsed,
  Map<String, dynamic> result,
) {
  if (!_isCreatableParsed(parsed) || !_isContractValidationError(result)) {
    return result;
  }

  final out = Map<String, dynamic>.from(result);
  out['input_contract'] = _createInputContract(parsed);
  final missingFields = out['missing_fields'];
  if (missingFields is List && missingFields.contains('fields')) {
    return out;
  }

  if (out['field_constraint'] != null) {
    return out;
  }
  final enumField = out['enum_field'];
  if (enumField is String &&
      parsed._resource!.schema.fields.containsKey(enumField)) {
    final values = parsed._resource.schema.enumFields[enumField];
    out['field_constraint'] = {'field': enumField, 'enum': ?values};
    return out;
  }

  if (missingFields is List && missingFields.length == 1) {
    out['field_constraint'] = {'field': missingFields.first, 'required': true};
  }
  return out;
}

/// 成功响应的权威路径，统一写在顶层 `path`。
///
/// 这里原本是一层 HATEOAS `_links`（`self` / `collection` / `resource` /
/// `subresources` / `create`）。删掉的理由：HATEOAS 的前提是客户端运行时才发现
/// API，而模型每轮都拿着完整静态地图 —— [pathSchema] 给路径语法、
/// [pathSchemaFieldNotes] 给字段表、tool schema 固定不变（AGENTS.md 第 13 条禁止
/// 动态改）。没有东西需要「发现」，`_links` 只是把常驻内容按响应重发一遍。
///
/// 而且那五个 rel 里只有 `self` 不可推导：`collection` 是 self.path 的第一段，
/// `resource` 是 self.path 去掉末段，`subresources` 是 self.path 加固定段名，
/// `create` 复述字段表。集合 listing 的 `self` 更是恒等于请求 path，零信息。
///
/// 剩下的那点价值 ——「ID 只能复制不能生成」——作用在一个字符串上，不需要链接图：
/// Create 返回新生成的 ID，模型照抄这个 `path` 即可。
Map<String, dynamic> _attachResultPath(Map<String, dynamic> out, String path) {
  out['path'] = path;
  return out;
}

/// listing 条目只给扁平的 `path`，与响应级 [_attachResultPath] 同一条规则。
///
/// 所有实体条目都保留自身 `id`，包括名称路径资源。
/// `path` 用于工具寻址，`id` 供业务关联和画布引用原样复制。
Map<String, dynamic> _attachListingEntryPath({
  required ParsedPath listParsed,
  required _ResourceDefinition schema,
  required Map<String, dynamic> entry,
}) {
  if (schema.name == 'outlines' &&
      (listParsed.isOutlineBeat && listParsed.isResourceListing)) {
    final outlineName = listParsed.locator('title')!;
    final id = entry['id'];
    if (id is! String) {
      return entry;
    }
    return {...entry, 'path': 'outlines/$outlineName/beats/$id'};
  }

  final entryPath = schema.usesNamePath
      ? _joinDisplayPath(
          listParsed.displayPath,
          _parseStringArgument(entry['title']),
        )
      : _joinDisplayPath(
          _collectionDisplayPath(schema.name),
          _parseStringArgument(entry['id']),
        );
  if (schema.usesNamePath && _parseStringArgument(entry['title']).isEmpty) {
    return entry;
  }
  if (!schema.usesNamePath && _parseStringArgument(entry['id']).isEmpty) {
    return entry;
  }

  return {...entry, 'path': entryPath};
}

enum _ReadResultKind {
  root,
  listing,
  fieldRead,
  beatResource,
  folder,
  resource,
}

_ReadResultKind _classifyReadResult(
  Map<String, dynamic> out,
  ParsedPath parsed,
) {
  if (parsed.isRoot) {
    return _ReadResultKind.root;
  }
  if (out['type'] == 'listing') {
    return _ReadResultKind.listing;
  }
  if (out.containsKey('value') && parsed.field != null) {
    return _ReadResultKind.fieldRead;
  }
  if ((parsed.isOutlineBeat && !parsed.isResourceListing)) {
    return _ReadResultKind.beatResource;
  }
  if (out['is_folder'] == true) {
    return _ReadResultKind.folder;
  }
  return _ReadResultKind.resource;
}

Map<String, dynamic> _attachReadResourcePath(
  ParsedPath parsed,
  Map<String, dynamic> result,
) {
  if (result.containsKey('error')) {
    return result;
  }

  final out = Map<String, dynamic>.from(result);

  if (parsed.collection == 'relations' &&
      parsed.resourceSegment == 'change_logs') {
    // Snapshot paths include both stable IDs; root listing inference would drop the parent.
    return _attachResultPath(out, parsed.displayPath);
  }

  // 已匹配子资源 schema 的路径不再进入名称文档的字段与标题推断。
  if (const {
    contentKindScreenplay,
    contentKindCanvas,
  }.contains(_resourceDefinitions[parsed.collection]?.group)) {
    return _attachResultPath(out, parsed.displayPath);
  }

  // 画布及子资源直接沿用公共匹配目标，保留业务返回的实际路径。
  final canvasAttached = attachCanvasResourcePath(parsed, out);
  if (canvasAttached != null) {
    return canvasAttached;
  }

  final kind = _classifyReadResult(out, parsed);
  final path = switch (kind) {
    _ReadResultKind.root => '/',
    _ReadResultKind.listing => parsed.displayPath,
    _ReadResultKind.fieldRead => parsed.displayPath,
    _ReadResultKind.beatResource ||
    _ReadResultKind.folder ||
    _ReadResultKind.resource => _resourceDisplayPath(parsed),
  };
  _attachResultPath(out, path);

  if (kind == _ReadResultKind.listing || kind == _ReadResultKind.folder) {
    _attachListingEntryPaths(parsed, out);
  }
  return out;
}

String? _toolResultResourcePath(Map<String, dynamic>? result) {
  final path = _parseStringArgument(result?['path']);
  return path.isEmpty ? null : path;
}

void _attachListingEntryPaths(ParsedPath parsed, Map<String, dynamic> out) {
  final schema = _resourceDefinitions[parsed.collection];
  final entries = out['entries'];
  if (entries is! List || schema == null) {
    return;
  }
  out['entries'] = entries.map((raw) {
    if (raw is! Map) {
      return raw;
    }
    return _attachListingEntryPath(
      listParsed: parsed,
      schema: schema,
      entry: Map<String, dynamic>.from(raw),
    );
  }).toList();
}

Map<String, dynamic> _attachMutationResourcePath(
  ParsedPath parsed,
  Map<String, dynamic> result,
) {
  if (result.containsKey('error') || result.containsKey('error_code')) {
    return result;
  }

  // handler 在 result 里写入 'path' 作为权威值（写与编辑都同 parsed.displayPath；
  // 后续可能由 handler 报告更具体路径）。没写时兜底用 parsed.displayPath。
  final out = Map<String, dynamic>.from(result);
  return _attachResultPath(out, out['path'] as String? ?? parsed.displayPath);
}

Map<String, dynamic> _attachCreateResourcePath(
  ParsedPath parsed,
  Map<String, dynamic> result,
) {
  if (result.containsKey('error') || result['ok'] == false) {
    return _attachCreateErrorContract(parsed, result);
  }

  // create handler 把新资源的 path 写在 result['path'] —— 新生成的 ID 只有这里有，
  // 模型必须照抄它。空串说明 handler 没报路径，这时留一个空 path 会诱导拼接，删掉。
  final out = Map<String, dynamic>.from(result);
  if (_parseStringArgument(out['path']).isEmpty) {
    out.remove('path');
  }
  return out;
}

AgentRule? _findAgentRuleByTitle(List<AgentRule> rules, String title) {
  for (final rule in rules) {
    if (rule.name == title) {
      return rule;
    }
  }
  return null;
}
