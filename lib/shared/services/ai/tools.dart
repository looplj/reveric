// 职责: AI 工具管理器，负责注册 Run/Read/Glob/Grep/Write/Edit/Create/SpawnAgent 等工具并协调可回滚 working change patch。
// 关联文件:
//   lib/shared/services/ai/chat.dart
//   lib/shared/services/ai/tools_support.dart
//   lib/shared/services/ai/tool_error_normalize.dart
//   lib/shared/services/ai/tool_result_payloads.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/ai/tools_glob.dart
//   lib/shared/services/ai/tools_grep.dart
//   lib/shared/services/ai/tools_image.dart
//   lib/shared/services/ai/tools_run.dart
//   lib/shared/services/ai/tools_subagent.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/utils/text_unit_count.dart
// ignore_for_file: use_null_aware_elements, unused_element

import '../../app_config.dart';

import 'tool_operations.dart';
import 'mcp/run_command_handler.dart';
import 'files/attachments.dart';
import 'files/command_paths.dart';
import 'files/management.dart';
import 'ffmpeg/arguments.dart';
import 'ffmpeg/command.dart';
import 'media/production.dart';
import 'assets/client.dart' show ProviderAssetException;
import '../../models/provider_asset.dart';
import 'styles_run_command_handler.dart';
import '../../models/production/style.dart';
import '../../models/storyboard/prompt.dart';
import '../../models/production/panorama.dart';
import 'media/editing.dart';
import 'files/reader.dart';
import 'files/session_files.dart';
import '../production/ffmpeg_runner.dart';
import '../production/contact_sheet.dart' show contactSheetPositions;
import 'providers_run_command_handler.dart';
import '../../models/tool_permission.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
// 画布摆位算的是矩形几何，直接用 dart:ui 的 Offset/Rect/Size，避免为几个值类型
// 另造一套模型。
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:collection/collection.dart';
import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;
import '../../database/app_database.dart';
import '../../utils/entity_relation_types.dart';
import '../../utils/ai_path_name_check.dart';
import '../../models/entity_relation_history.dart';
import '../entity_relations_service.dart';
import '../../models/ai_session_mode.dart';
import '../../models/ai_nested_tool_call.dart';
import '../../models/canvas_ai_activity.dart';
import '../../models/canvas_layout.dart';
import '../../models/content_status.dart';
import '../../models/content_kind.dart';
import '../../models/map_agent.dart';
import '../../models/screenplay.dart';
import '../../models/production/settings.dart';
import '../production/canvas_service.dart';
import '../../models/screenplay_element.dart';
import '../../models/screenplay_element_render.dart';
import '../../models/subagent.dart';
import '../../models/agent_skill.dart';
import '../../database/novel_content_database.dart';
import '../../database/type_converters.dart' show SubjectPhotoListConverter;
import '../novel_actions.dart';
import '../novel_content.dart';
import '../maps_service.dart' show DuplicateLocationNameException;
import '../screenplay_service.dart';
import '../storyboard/service.dart';
import '../../models/director/document.dart'
    show DocumentError, DirectorDocument;
import '../../models/director/schema.dart' as director;
import '../director/query.dart' as director;
import '../director/contact_sheet.dart' as director;
import '../director/renderer.dart' show FrameRenderer;
import '../director/batch_commands.dart' show directorCommandFields;
import 'package:uuid/uuid.dart';
import '../storyboard/edit_orchestrator.dart';
import '../screenplay_create_orchestrator.dart';
import '../canvas_service.dart';
import '../../models/agent_rule.dart';
import '../../models/outline.dart';
import '../../utils/random_id.dart';
import '../../utils/resource_path.dart';
import '../../utils/short_entity_id.dart';
import '../../utils/short_entity_id_allocator.dart';
import '../../utils/json_repair.dart' show tryExtractJson;
import '../../utils/storage_paths.dart';
import '../../utils/text_unit_count.dart' show countTextUnitStats;
import '../../logger/app_logger.dart';
import '../bundled_control_skills.dart'
    show bundledControlRunCommandToCallName, bundledControlSkillForRun;
import '../working_overlay.dart';
import '../../agent/agent_tool_dispatcher.dart'
    show AgentToolDispatcher, ToolDef, ToolExecutionContext, ToolWorkingChange;
import '../../models/ask_user_models.dart'
    show AskUserInput, AskUserRequest, AiAskUserCallback;
import '../../heuristic/chat_next_action.dart';
import '../../models/todo.dart';
import 'image.dart';
import 'tool_error_normalize.dart';
import 'media_diagnostics.dart' show safeMediaDiagnostic;
import 'tool_result_payloads.dart';
import 'package:easy_localization/easy_localization.dart';

import '../../localization/locale_keys.dart';

// Re-export types for backward compatibility
export '../../agent/agent_tool_dispatcher.dart'
    show
        AgentCancellationController,
        AgentCancellationToken,
        AgentToolDispatcher,
        ToolDef,
        ToolExecutionContext;
export '../../models/ask_user_models.dart'
    show
        AskUserResult,
        AskUserResolution,
        AskUserAnswer,
        AskUserOption,
        AskUserQuestion,
        AskUserRequest,
        AskUserInput,
        AiAskUserCallback;
part 'tools_ask_user.dart';
part 'tools_suggest_next_action.dart';
part 'tools_subagent.dart';
part 'tools_support.dart';
part 'tools_schema.dart';
part 'tools_output_schema.dart';
part 'tools_cross_work.dart';
part 'tools_screenplay.dart';
part 'tools_storyboard.dart';
part 'tools_production.dart';
part 'stagings_run_command_handler.dart';
part 'tools_production_schema.dart';
part 'tools_read.dart';
part 'tools_resource_search_support.dart';
part 'tools_glob.dart';
part 'tools_grep.dart';
part 'tools_image.dart';
part 'tools_run.dart';
part 'tools_agent_rules.dart';
part 'tools_create.dart';
part 'tools_write.dart';
part 'tools_edit.dart';
part 'tools_replace.dart';
part 'tools_graph.dart';
part 'tools_relation.dart';
part 'tools_canvas.dart';
part 'tools_todo.dart';
part 'tools_skill.dart';
part 'tools_outline.dart';
part 'tools_remove.dart';
part 'tools_enum_validation.dart';

final _log = AppLogger.forModule('Tools');

final Object _toolExecutionContextZoneKey = Object();
final Object _runCallIdZoneKey = Object();
String? get _activeRunCallId => Zone.current[_runCallIdZoneKey] as String?;
final Object _workingChangeCaptureZoneKey = Object();

class _WorkingChangeCapture {
  ToolWorkingChange? value;
  void add(ToolWorkingChange change) {
    value = value?.cover(change) ?? change;
  }
}

ToolExecutionContext? get _currentToolExecutionContext =>
    Zone.current[_toolExecutionContextZoneKey] as ToolExecutionContext?;

/// 复用别的工具落库管线时，working change 该归因到哪个工具。
///
/// Replace 走的是 Edit 的写入路径，各 handler 里的 `toolName: 'Edit'` 是写死的。
/// 用 zone 传而不是给 `_applyEditToPath → handler.edit` 全链路加参数：调用链短，
/// 而且 subagent 与主 agent 共享同一个 [AiToolManager]，普通字段会互相串。
final Object _stagingToolNameZoneKey = Object();

String? get _currentStagingToolName =>
    Zone.current[_stagingToolNameZoneKey] as String?;

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------

// ToolDef, AgentToolDispatcher are defined in agent_tool_dispatcher.dart

// LLM tool calls are JSON-shaped but not always schema-strict: models may pass
// numbers as strings, booleans as "true"/"false", or a single item where a list
// was requested. Normalize those argument values at the tool boundary so user
// requests fail with tool-level validation errors instead of Dart cast errors.
//
// 默认不 trim：首尾空白对正则 pattern、Run 的参数值都是有效输入，统一 trim 会让
// Replace 的 `"李明 "` 静默按 `"李明"` 匹配并落库。拿参数值去比对枚举字面量或当
// 查找键（map key、字段名）的调用点传 `trim: true`。
String _parseStringArgument(
  Object? raw, {
  String defaultValue = '',
  bool trim = false,
}) {
  if (raw == null) {
    return defaultValue;
  }
  final value = raw.toString();
  return trim ? value.trim() : value;
}

String _parseTextArgument(Object? raw, {String defaultValue = ''}) {
  if (raw == null) {
    return defaultValue;
  }
  return raw.toString();
}

String? _parseOptionalTextArgument(Object? raw) {
  if (raw == null) {
    return null;
  }
  return raw.toString();
}

String? _parseOptionalStringArgument(Object? raw) {
  if (raw == null) {
    return null;
  }
  final value = raw.toString().trim();
  return value.isEmpty ? null : value;
}

bool _parseBoolArgument(Object? raw, {bool defaultValue = false}) {
  if (raw is bool) {
    return raw;
  }
  if (raw is num) {
    return raw != 0;
  }
  if (raw is String) {
    final value = raw.trim().toLowerCase();
    if (value == 'true' || value == 'yes' || value == '1') {
      return true;
    }
    if (value == 'false' || value == 'no' || value == '0') {
      return false;
    }
  }
  return defaultValue;
}

int? _parseIntArgument(Object? raw) {
  if (raw is int) {
    return raw;
  }
  if (raw is num) {
    return raw.toInt();
  }
  if (raw is String) {
    return int.tryParse(raw.trim());
  }
  return null;
}

List<dynamic> _parseListArgument(Object? raw) {
  if (raw is List) {
    return raw;
  }
  if (raw == null) {
    return const [];
  }
  return [raw];
}

List<SubjectPhoto> _normalizeSubjectPhotos(List values) =>
    values.map(SubjectPhoto.fromJson).toList();

/// 序列化已规范化的输入或持久化字段，保持 Working Change 文本格式。
String _encodeCharacterWorkingValue(String field, Object? value) {
  return switch (field) {
    'aliases' => jsonEncode(value ?? const []),
    'photos' => jsonEncode(
      (value as List? ?? const [])
          .map((raw) => SubjectPhoto.fromJson(raw).toJson())
          .toList(),
    ),
    'behavior_tags' => jsonEncode([
      for (final tag
          in (value as List? ?? const []).cast<Map<String, dynamic>>())
        {'tag': tag['tag'], 'context': tag['context']},
    ]),
    _ => value as String? ?? '',
  };
}

Map<String, dynamic>? _parseMapArgument(Object? raw) {
  if (raw is Map) {
    return Map<String, dynamic>.from(raw);
  }
  return null;
}

Map<String, int> _chapterWordCount(String content) {
  final stats = countTextUnitStats(content);
  return {
    'with_punctuation': stats.wordUnitsWithPunctuation,
    'without_punctuation': stats.wordUnitsWithoutPunctuation,
  };
}

/// AI 可写的作品状态：[contentStatuses] 去掉 archived —— 归档只在书库 UI 操作。
/// 作品状态的静态契约值。
const _aiNovelStatuses = <String>[
  contentStatusInProgress,
  contentStatusFinished,
  contentStatusAbandoned,
];

// 字段投影与操作模板共用值类型；不存储第二份字段权限名单。
const _subjectPhotosValue = _ValueSchema(
  _ValueType.array,
  items: _ValueSchema(
    _ValueType.object,
    properties: {
      'asset_id': _ValueProperty(
        _ValueSchema(_ValueType.string, minLength: 1),
        required: true,
      ),
      'name': _ValueProperty(_ValueSchema(_ValueType.string), required: true),
    },
  ),
);

const _emotionValue = _ValueSchema(
  _ValueType.array,
  items: _ValueSchema(_ValueType.string, minLength: 1),
  example: ['紧张', '决绝'],
);

const _eventValue = _ValueSchema(
  _ValueType.object,
  properties: {
    'title': _ValueProperty(
      _ValueSchema(_ValueType.string, minLength: 1),
      required: true,
    ),
    'summary': _ValueProperty(
      _ValueSchema(_ValueType.string, minLength: 1),
      required: true,
    ),
    'state_change': _ValueProperty(_ValueSchema(_ValueType.string)),
  },
);
// 章节事件规范化允许仅给 title 或 summary，并补齐另一个空字符串。
const _chapterEventValue = _ValueSchema(
  _ValueType.object,
  properties: {
    'title': _ValueProperty(_ValueSchema(_ValueType.string)),
    'summary': _ValueProperty(_ValueSchema(_ValueType.string)),
    'state_change': _ValueProperty(_ValueSchema(_ValueType.string)),
  },
);
const _outlineBeatFieldsDefinition = <String, _ResourceField>{
  'id': _ResourceField(
    value: _ValueSchema(
      _ValueType.string,
      referenceTarget: 'self',
      minLength: 1,
    ),
    read: _FieldRead(listing: true, path: true),
  ),
  'title': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(required: true),
    edit: _FieldEdit(),
    search: {_FieldSearch.body},
  ),
  'content': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    edit: _FieldEdit(),
    search: {_FieldSearch.body},
  ),
  'status': _ResourceField(
    value: _ValueSchema(
      _ValueType.string,
      enumAliases: _ChineseEnumMappings.outlineStatusAliases,
      enumValues: outlineStatuses,
    ),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'chapter_count': _ResourceField(
    aliases: ['chapterCount'],
    value: _ValueSchema(_ValueType.integer, minimum: 1),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
    description: '本节拍覆盖的章节数；从所属大纲的起始章号起按节拍顺序连续累加',
  ),
  'index': _ResourceField(
    value: _ValueSchema(_ValueType.integer),
    read: _FieldRead(listing: true, requiredInDetail: false),
    create: _FieldInputUse(),
    description: '插入位置；省略时追加到末尾',
  ),
};
const _outlineBeatDefinition = _ResourceDefinition(
  segment: 'beats',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'beat_id'),
  description: '节拍',
  group: contentKindNovel,
  hidden: false,
  listing: _ResourceListing(),
  fields: _outlineBeatFieldsDefinition,
  operations: [
    _ResourceOperation(
      _ResourceTool.remove,
      _ResourceTargetKind.resource,
      result: _ResourceResult(
        _ResourceResultKind.mutation,
        references: ['path', 'parent_path'],
      ),
    ),
    _ResourceOperation(
      _ResourceTool.read,
      _ResourceTargetKind.listing,
      result: _ResourceResult(
        _ResourceResultKind.listing,
        references: ['entries[].path'],
      ),
    ),
    _ResourceOperation(
      _ResourceTool.read,
      _ResourceTargetKind.resource,
      result: _ResourceResult(_ResourceResultKind.entity, references: ['path']),
    ),
    _ResourceOperation(
      _ResourceTool.create,
      _ResourceTargetKind.listing,
      input: _ResourceInput(_ResourceInputKind.create_fields),
    ),
    _ResourceOperation(
      _ResourceTool.write,
      _ResourceTargetKind.resource,
      input: _ResourceInput(_ResourceInputKind.resource_fields),
    ),
    _ResourceOperation(
      _ResourceTool.write,
      _ResourceTargetKind.listing,
      input: _ResourceInput(
        _ResourceInputKind.array_value,
        field: 'beats',
        value: _ValueSchema(
          _ValueType.array,
          items: _ValueSchema(
            _ValueType.object,
            fieldReference: _outlineBeatFieldsDefinition,
            projection: _FieldProjection.existing_item,
            requireProjectedFields: false,
          ),
          identity: _ArrayIdentity.optional_existing_id,
        ),
      ),
    ),
  ],
);
const _canvasStickyRequirement = _ResourceConstraint(
  _ConstraintKind.target_requirement,
  [],
  whenField: 'type',
  whenValues: [canvasNodeTypeSticky],
);

const _canvasNodeDefinition = _ResourceDefinition(
  segment: 'nodes',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'node_id'),
  description: '节点',
  listing: _ResourceListing(),
  fields: {
    'id': _ResourceField(
      value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
      read: _FieldRead(listing: true),
    ),
    'type': _ResourceField(
      value: _ValueSchema(
        _ValueType.string,
        enumValues: [canvasNodeTypeReference, canvasNodeTypeSticky],
      ),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(required: true),
      write: _FieldInputUse(),
    ),
    'ref_type': _ResourceField(
      value: _ValueSchema(
        _ValueType.string,
        nullable: true,
        enumValues: canvasNodeRefTypes,
      ),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(),
      write: _FieldInputUse(),
    ),
    'ref_id': _ResourceField(
      value: _ValueSchema(
        _ValueType.string,
        nullable: true,
        referenceTargetsByField: {
          'ref_type': {
            entityTypeCharacter: ['characters'],
            entityTypeChapter: ['chapters'],
            entityTypeForeshadowing: ['foreshadowing'],
            canvasNodeRefTypeOutline: ['outlines'],
            entityTypeLocation: ['locations'],
            entityTypeItem: ['items'],
            entityTypeFaction: ['factions'],
            entityTypeSkill: ['skills'],
            entityTypeCreature: ['creatures'],
            canvasNodeRefTypeDocument: ['lore', 'materials'],
            canvasNodeRefTypeScreenplayScene: ['scenes'],
          },
        },
      ),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(),
      write: _FieldInputUse(field: true),
    ),
    'title': _ResourceField(
      value: _ValueSchema(_ValueType.string),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(),
      write: _FieldInputUse(
        field: true,
        constraints: [_canvasStickyRequirement],
      ),
      search: {_FieldSearch.short_text},
    ),
    'content': _ResourceField(
      value: _ValueSchema(_ValueType.string),
      read: _FieldRead(path: true, constraints: [_canvasStickyRequirement]),
      create: _FieldInputUse(),
      write: _FieldInputUse(
        field: true,
        constraints: [_canvasStickyRequirement],
      ),
      edit: _FieldEdit(constraints: [_canvasStickyRequirement]),
      search: {_FieldSearch.body},
    ),
    'color': _ResourceField(
      value: _ValueSchema(
        _ValueType.string,
        nullable: true,
        enumValues: canvasNodeColorKeys,
        pattern: canvasNodeCustomColorPattern,
      ),
      description:
          '节点颜色：预设 key，或自定义 #RRGGBB；便签不传时用 sand，引用节点不传则不着色；Write 传 null 清除颜色',
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(),
      write: _FieldInputUse(field: true),
    ),
    'col': _ResourceField(
      value: _ValueSchema(_ValueType.integer),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(),
      write: _FieldInputUse(field: true),
    ),
    'row': _ResourceField(
      value: _ValueSchema(_ValueType.integer),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(),
      write: _FieldInputUse(field: true),
    ),
    'x': _ResourceField(
      value: _ValueSchema(_ValueType.number),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(),
      write: _FieldInputUse(field: true),
    ),
    'y': _ResourceField(
      value: _ValueSchema(_ValueType.number),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(),
      write: _FieldInputUse(field: true),
    ),
    'width': _ResourceField(
      value: _ValueSchema(_ValueType.number, nullable: true),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(),
    ),
    'height': _ResourceField(
      value: _ValueSchema(_ValueType.number, nullable: true),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(),
    ),
  },
  operations: [
    _ResourceOperation(
      _ResourceTool.read,
      _ResourceTargetKind.listing,
      parameters: {
        'search': _OperationParameter(
          _ValueSchema(_ValueType.string),
          query: _FieldQuery(match: _QueryMatch.contains),
        ),
      },
      result: _ResourceResult(
        _ResourceResultKind.listing,
        references: ['entries[].path'],
      ),
    ),
    _ResourceOperation(
      _ResourceTool.read,
      _ResourceTargetKind.resource,
      result: _ResourceResult(_ResourceResultKind.entity, references: ['path']),
    ),
    _ResourceOperation(
      _ResourceTool.create,
      _ResourceTargetKind.listing,
      input: _ResourceInput(_ResourceInputKind.create_fields),
      parameters: {
        'near': _OperationParameter(
          _ValueSchema(_ValueType.string, referenceTarget: 'nodes'),
          description: '摆位参考节点 ID',
        ),
        'direction': _OperationParameter(
          _ValueSchema(
            _ValueType.string,
            enumAliases: {
              'up': 'above',
              'top': 'above',
              'down': 'below',
              'bottom': 'below',
            },
            enumValues: ['right', 'left', 'above', 'below'],
          ),
        ),
      },
      constraints: [
        _ResourceConstraint(
          _ConstraintKind.required_when,
          ['ref_type', 'ref_id'],
          whenField: 'type',
          whenValues: [canvasNodeTypeReference],
        ),
        _ResourceConstraint(
          _ConstraintKind.required_when,
          ['content'],
          whenField: 'type',
          whenValues: [canvasNodeTypeSticky],
          presence: _ConstraintPresence.present,
        ),
      ],
    ),
    _ResourceOperation(
      _ResourceTool.write,
      _ResourceTargetKind.resource,
      input: _ResourceInput(_ResourceInputKind.resource_fields),
      parameters: {
        'near': _OperationParameter(
          _ValueSchema(_ValueType.string, referenceTarget: 'nodes'),
          description: '摆位参考节点 ID',
        ),
        'direction': _OperationParameter(
          _ValueSchema(
            _ValueType.string,
            enumAliases: {
              'up': 'above',
              'top': 'above',
              'down': 'below',
              'bottom': 'below',
            },
            enumValues: ['right', 'left', 'above', 'below'],
          ),
        ),
      },
      constraints: [
        _ResourceConstraint(_ConstraintKind.at_least_one, [
          'type',
          'ref_type',
          'ref_id',
          'col',
          'row',
          'x',
          'y',
          'title',
          'content',
          'color',
        ], presence: _ConstraintPresence.present),
      ],
    ),

    _ResourceOperation(
      _ResourceTool.remove,
      _ResourceTargetKind.resource,
      parameters: {
        'force': _OperationParameter(
          _ValueSchema(_ValueType.boolean),
          hasDefault: true,
          defaultValue: false,
        ),
      },
    ),
  ],
);
const _canvasEdgeDefinition = _ResourceDefinition(
  segment: 'edges',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'edge_id'),
  description: '连线',
  listing: _ResourceListing(),
  fields: {
    'id': _ResourceField(
      value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
      read: _FieldRead(listing: true),
    ),
    'source_node_id': _ResourceField(
      value: _ValueSchema(_ValueType.string, referenceTarget: 'nodes'),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(required: true),
    ),
    'target_node_id': _ResourceField(
      value: _ValueSchema(_ValueType.string, referenceTarget: 'nodes'),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(required: true),
    ),
    'type': _ResourceField(
      value: _ValueSchema(_ValueType.string, enumValues: canvasEdgeTypes),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(required: true),
    ),
    'label': _ResourceField(
      value: _ValueSchema(_ValueType.string),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(),
      search: {_FieldSearch.short_text},
    ),
  },
  operations: [
    _ResourceOperation(
      _ResourceTool.read,
      _ResourceTargetKind.listing,
      parameters: {
        'search': _OperationParameter(
          _ValueSchema(_ValueType.string),
          query: _FieldQuery(match: _QueryMatch.contains),
        ),
      },
      result: _ResourceResult(
        _ResourceResultKind.listing,
        references: ['entries[].path'],
      ),
    ),
    _ResourceOperation(
      _ResourceTool.read,
      _ResourceTargetKind.resource,
      result: _ResourceResult(_ResourceResultKind.entity, references: ['path']),
    ),
    _ResourceOperation(
      _ResourceTool.create,
      _ResourceTargetKind.listing,
      input: _ResourceInput(_ResourceInputKind.create_fields),
    ),
    _ResourceOperation(
      _ResourceTool.remove,
      _ResourceTargetKind.resource,
      parameters: {
        'force': _OperationParameter(
          _ValueSchema(_ValueType.boolean),
          hasDefault: true,
          defaultValue: false,
        ),
      },
    ),
  ],
);
const _screenplayTextElementTypes = [
  'action',
  'parenthetical',
  'dialogue',
  'transition',
  'note',
  'subtitle',
];
const _screenplayTextRequirement = _ResourceConstraint(
  _ConstraintKind.target_requirement,
  [],
  whenField: 'type',
  whenValues: _screenplayTextElementTypes,
);
const _screenplayCharacterRequirement = _ResourceConstraint(
  _ConstraintKind.target_requirement,
  [],
  whenField: 'type',
  whenValues: ['character'],
);

const _screenplayElementFields = <String, _ResourceField>{
  'id': _ResourceField(
    value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
    read: _FieldRead(listing: true),
    create: _FieldInputUse(),
  ),
  'type': _ResourceField(
    value: _ValueSchema(
      _ValueType.string,
      enumValues: [..._screenplayTextElementTypes, 'character'],
    ),
    read: _FieldRead(listing: true),
    create: _FieldInputUse(required: true),
    write: _FieldInputUse(),
    description:
        '场景标题通过场次字段设置，不作为正文元素。dialogue/parenthetical '
        '须跟在同一连续块的 character 后；action/transition/note/subtitle '
        '会结束该块，之后继续对白须重新给出 character。',
  ),
  'text': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(
      listing: true,
      path: true,
      constraints: [_screenplayTextRequirement],
    ),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
    edit: _FieldEdit(constraints: [_screenplayTextRequirement]),
    description: '非 character 元素的正文必须非空；character 的 text 须省略或为空。',
    search: {_FieldSearch.body},
  ),
  'character_id': _ResourceField(
    value: _ValueSchema(_ValueType.string, referenceTarget: 'characters'),
    read: _FieldRead(
      listing: true,
      path: true,
      constraints: [_screenplayCharacterRequirement],
    ),
    create: _FieldInputUse(),
    write: _FieldInputUse(),
    description: 'type=character 时必填，引用当前作品中存在且未删除的人物；其他类型不填写。',
    search: {_FieldSearch.short_text},
  ),
  'extension': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(
      listing: true,
      constraints: [_screenplayCharacterRequirement],
    ),
    create: _FieldInputUse(),
    write: _FieldInputUse(),
    description: '角色提示后缀，如 V.O.；仅 type=character 时可填写非空值。',
  ),
  'name': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(
      listing: true,
      constraints: [_screenplayCharacterRequirement],
    ),
    description: '角色展示名，只读',
  ),
};
const _screenplayElementCreateParameters = <String, _OperationParameter>{
  'after_element_id': _OperationParameter(
    _ValueSchema(_ValueType.string, referenceTarget: 'elements'),
  ),
};
const _screenplayElementArray = _ValueSchema(
  _ValueType.array,
  items: _ValueSchema(
    _ValueType.object,
    fieldReference: _screenplayElementFields,
    parameterReference: _screenplayElementCreateParameters,
    projection: _FieldProjection.create,
  ),
  identity: _ArrayIdentity.optional_existing_id,
);
const _screenplayElementDefinition = _ResourceDefinition(
  segment: 'elements',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'element_id'),
  description: '正文元素',
  group: contentKindScreenplay,
  hidden: false,
  listing: _ResourceListing(),
  fields: _screenplayElementFields,
  operations: [
    _ResourceOperation(
      _ResourceTool.read,
      _ResourceTargetKind.listing,
      result: _ResourceResult(
        _ResourceResultKind.listing,
        references: ['entries[].path'],
      ),
    ),
    _ResourceOperation(
      _ResourceTool.read,
      _ResourceTargetKind.resource,
      result: _ResourceResult(_ResourceResultKind.entity, references: ['path']),
    ),
    _ResourceOperation(
      _ResourceTool.create,
      _ResourceTargetKind.listing,
      input: _ResourceInput(_ResourceInputKind.create_fields),
      parameters: _screenplayElementCreateParameters,
    ),
    _ResourceOperation(
      _ResourceTool.write,
      _ResourceTargetKind.resource,
      input: _ResourceInput(_ResourceInputKind.resource_fields),
    ),
    _ResourceOperation(_ResourceTool.remove, _ResourceTargetKind.resource),
    _ResourceOperation(
      _ResourceTool.write,
      _ResourceTargetKind.listing,
      input: _ResourceInput(
        _ResourceInputKind.array_value,
        field: 'elements',
        value: _screenplayElementArray,
      ),
    ),
  ],
);

const _relationFields = <String, _ResourceField>{
  'id': _ResourceField(
    value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
    read: _FieldRead(listing: true),
  ),
  'source_type': _ResourceField(
    value: _ValueSchema(
      _ValueType.string,
      enumAliases: _ChineseEnumMappings.entityTypeZh,
      enumValues: entityTypes,
    ),
    read: _FieldRead(listing: true),
    create: _FieldInputUse(required: true),
    query: _FieldQuery(),
  ),
  'source_id': _ResourceField(
    value: _ValueSchema(_ValueType.string, referenceTarget: 'entities'),
    read: _FieldRead(listing: true),
    create: _FieldInputUse(required: true),
    query: _FieldQuery(),
  ),
  'target_type': _ResourceField(
    value: _ValueSchema(
      _ValueType.string,
      enumAliases: _ChineseEnumMappings.entityTypeZh,
      enumValues: entityTypes,
    ),
    read: _FieldRead(listing: true),
    create: _FieldInputUse(required: true),
    query: _FieldQuery(),
  ),
  'target_id': _ResourceField(
    value: _ValueSchema(_ValueType.string, referenceTarget: 'entities'),
    read: _FieldRead(listing: true),
    create: _FieldInputUse(required: true),
    query: _FieldQuery(),
  ),
  'relation_type': _ResourceField(
    value: _ValueSchema(
      _ValueType.string,
      enumAliases: _ChineseEnumMappings.relationTypeZh,
      enumValues: [
        ...characterRelationTypes,
        ...characterFactionRelationTypes,
        ...characterSkillRelationTypes,
        ...characterItemRelationTypes,
        ...factionRelationTypes,
        ...skillRelationTypes,
        ...itemRelationTypes,
        ...creatureRelationTypes,
      ],
    ),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(required: true),
    query: _FieldQuery(),
    write: _FieldInputUse(),
    edit: _FieldEdit(),
    description:
        '当前主要关系类型；合法值由 source_type → target_type 决定。Write 记录真实变化，Edit 修正录入。方向按「source 是 target 的 X」读，例外见关系指南。',
  ),
  'chapter_id': _ResourceField(
    value: _ValueSchema(
      _ValueType.string,
      nullable: true,
      referenceTarget: 'chapters',
    ),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    query: _FieldQuery(),
    write: _FieldInputUse(),
    edit: _FieldEdit(),
    description:
        '当前状态的证据章节 ID；与 scene_id 互斥。Write 省略时不保留旧章节证据；Edit 其他字段不影响本字段，Edit 本字段传空字符串表示清空。',
  ),
  'scene_id': _ResourceField(
    value: _ValueSchema(
      _ValueType.string,
      nullable: true,
      referenceTarget: 'scenes',
    ),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    query: _FieldQuery(),
    write: _FieldInputUse(),
    edit: _FieldEdit(),
    description:
        '当前状态的证据场次 ID；与 chapter_id 互斥。Write 省略时不保留旧场次证据；Edit 其他字段不影响本字段，Edit 本字段传空字符串表示清空。',
  ),
  'proof': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(required: true),
    write: _FieldInputUse(required: true),
    edit: _FieldEdit(),
    description: '本次关系状态的依据；写具体场面或设定说明，不重复关系类型。',
  ),
  'status': _ResourceField(
    value: _ValueSchema(_ValueType.string, enumValues: ['active', 'ended']),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(hasDefault: true, defaultValue: 'active'),
    write: _FieldInputUse(),
    edit: _FieldEdit(),
    query: _FieldQuery(),
    description: '关系状态：active 表示生效，ended 表示已结束。真实结束或恢复用 Write，状态录错用 Edit。',
  ),
  'reason': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    write: _FieldInputUse(required: true),
    description: 'Write 本次关系变化的原因；记录转变、结束、恢复或新的事实依据。Edit 不需要此字段。',
  ),
};

/// Identity fields projected from the actual readable resource tree.
@visibleForTesting
Set<String> readableResourceIdPathsForTesting() {
  final paths = <String>{};
  void visitValue(_ValueSchema value, String path) {
    if (value.items case final items?) {
      visitValue(items, '$path[]');
    }
    for (final entry in value.objectProperties.entries) {
      final childPath = '$path.${entry.key}';
      if (entry.key == 'id') {
        paths.add(childPath);
      }
      visitValue(entry.value.value, childPath);
    }
  }

  void visitResource(_ResourceDefinition resource, String path) {
    for (final entry in resource.fields.entries) {
      final read = entry.value.read;
      if (read == null || !(read.detail || read.listing || read.path)) {
        continue;
      }
      final fieldPath = '$path.${entry.key}';
      if (entry.key == 'id') {
        paths.add(fieldPath);
      }
      visitValue(entry.value.value, fieldPath);
    }
    for (final child in resource.children) {
      visitResource(child, '$path/${child.segment}');
    }
  }

  for (final resource in _resourceDefinitions.values) {
    visitResource(resource, resource.segment);
  }
  // `/works` is a cross-work listing rather than a content resource definition,
  // but its entries expose top-level work identities as readable IDs.
  paths.add('works.entries[].id');
  return Set.unmodifiable(paths);
}

const _resourceDefinitions = <String, _ResourceDefinition>{
  'production': _canvasProductionDefinition,
  'profile': _ResourceDefinition(
    segment: 'profile',
    address: _ResourceAddress(_AddressKind.singleton),
    description: '作品信息',
    hidden: false,
    fields: {
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.short_text},
      ),
      'author_name': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'description': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'category': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'status': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          enumAliases: _ChineseEnumMappings.novelStatusZh,
          enumValues: _aiNovelStatuses,
        ),
        read: _FieldRead(listing: true, path: true),
        write: _FieldInputUse(field: true),
      ),
      'tags': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '逗号分隔字符串',
        search: {_FieldSearch.body},
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),
    ],
  ),
  'story_state': _ResourceDefinition(
    segment: 'story_state',
    address: _ResourceAddress(_AddressKind.singleton),
    description: '故事状态',
    hidden: false,
    fields: {
      'content': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        write: _FieldInputUse(
          value: _ValueSchema(_ValueType.string, minLength: 1),
          field: true,
        ),
        edit: _FieldEdit(),
        description: '累积叙事状态 Markdown；在正文中记录覆盖到的章节或季、集、场次',
        search: {_FieldSearch.body},
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),
    ],
  ),
  'chapters': _ResourceDefinition(
    segment: 'chapters',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'chapter_id'),
    description: '章节',
    group: contentKindNovel,
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.short_text},
      ),
      'outline': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '写前的本章规划；不要用写完后的总结覆盖它',
        search: {_FieldSearch.body},
      ),
      'brief': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '写后的本章总结',
        search: {_FieldSearch.body},
      ),
      'content': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '章节正文，纯文本',
        search: {_FieldSearch.body},
      ),
      'word_count': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(listing: true, path: true),
        description: '字数',
      ),
      'status': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        description: '发布状态',
      ),
      'tension': _ResourceField(
        value: _ValueSchema(
          _ValueType.integer,
          nullable: true,
          minimum: 1,
          maximum: 10,
        ),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '本章叙事张力',
      ),
      'emotion': _ResourceField(
        value: _emotionValue,
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '情绪短标签',
      ),
      'events': _ResourceField(
        value: _ValueSchema(_ValueType.array, items: _chapterEventValue),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '章内事件数组 [{title, summary, state_change}]，state_change 可选',
      ),
      'volume_id': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          nullable: true,
          referenceTarget: 'volumes',
        ),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '所属卷 ID；清空后移出卷、放到根级末尾',
        query: _FieldQuery(),
      ),
      'relations': _ResourceField(
        value: _ValueSchema(
          _ValueType.array,
          items: _ValueSchema(
            _ValueType.object,
            fieldReference: _relationFields,
          ),
        ),
        read: _FieldRead(detail: false, path: true),
        description: '以该章节为证据产生的实体关系列表',
      ),
      'chapter_num': _ResourceField(
        value: _ValueSchema(_ValueType.integer, nullable: true),
        read: _FieldRead(listing: true, path: true),
        query: _FieldQuery(normalization: _QueryNormalization.integer),
        description: '章节序号，与标题无关 —— 用户说「第三章」指的是它',
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
  ),
  'volumes': _ResourceDefinition(
    segment: 'volumes',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'volume_id'),
    description: '卷',
    group: contentKindNovel,
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'volume_num': _ResourceField(
        value: _ValueSchema(_ValueType.integer, nullable: true),
        read: _FieldRead(listing: true),
      ),
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.short_text},
      ),
      'outline': _ResourceField(
        aliases: ['description'],
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
  ),
  'characters': _ResourceDefinition(
    segment: 'characters',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'character_id'),
    description: '角色',
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'photos': _ResourceField(
        value: _subjectPhotosValue,
        read: _FieldRead(path: true),
        write: _FieldInputUse(field: true),
        description: '角色图集',
      ),
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'name': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        query: _FieldQuery(),
        description: '角色称呼本身，不含头衔、称号、职务或括注；多个称呼拆成 name + aliases',
        search: {_FieldSearch.short_text},
      ),
      'role': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          enumAliases: _ChineseEnumMappings.characterRoleZh,
          enumValues: characterRoles,
        ),
        read: _FieldRead(path: true),
        create: _FieldInputUse(
          hasDefault: true,
          defaultValue: characterRoleSupporting,
        ),
        write: _FieldInputUse(
          field: true,
          hasDefault: true,
          defaultValue: characterRoleSupporting,
        ),
        query: _FieldQuery(),
        description: '在全书中的戏份层级，按整体判断而非单章表现',
      ),
      'gender': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          enumAliases: _ChineseEnumMappings.characterGenderZh,
          enumValues: characterGenders,
        ),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(
          hasDefault: true,
          defaultValue: characterGenderUnknown,
        ),
        write: _FieldInputUse(
          field: true,
          hasDefault: true,
          defaultValue: characterGenderUnknown,
        ),
        query: _FieldQuery(),
      ),
      'aliases': _ResourceField(
        value: _ValueSchema(
          _ValueType.array,
          items: _ValueSchema(_ValueType.string, minLength: 1),
        ),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        query: _FieldQuery(),
        description: '角色的其他称呼',
      ),
      'tags': _ResourceField(
        value: _ValueSchema(
          _ValueType.array,
          items: _ValueSchema(_ValueType.string, minLength: 1),
        ),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '用于按宗门、家族、阵营等维度归类角色的标签',
        search: {_FieldSearch.body},
      ),
      'identity': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '身份与称号：职业、组织身份、亲属身份或社会位置；只写已确立的，不写推测',
        search: {_FieldSearch.body},
      ),
      'age': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        query: _FieldQuery(),
        search: {_FieldSearch.body},
      ),
      'motivation': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '驱动其行动的核心欲求或目标',
        search: {_FieldSearch.body},
      ),
      'arc': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '贯穿全书的转变轨迹：从什么状态走向什么状态',
        search: {_FieldSearch.body},
      ),
      'biography': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '历史小传',
        search: {_FieldSearch.body},
      ),
      'appearance': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '稳定视觉外观',
        search: {_FieldSearch.body},
      ),
      'personality': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '内在性格',
        search: {_FieldSearch.body},
      ),
      'description': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '声线、动作习惯、可观察气质与公众印象',
        search: {_FieldSearch.body},
      ),
      'behavior_tags': _ResourceField(
        value: _ValueSchema(
          _ValueType.array,
          items: _ValueSchema(
            _ValueType.object,
            properties: {
              'tag': _ValueProperty(
                _ValueSchema(_ValueType.string, minLength: 1),
                required: true,
              ),
              'context': _ValueProperty(
                _ValueSchema(_ValueType.string, minLength: 1),
                required: true,
              ),
            },
          ),
        ),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '{tag, context} 对象数组，context 必填，表达「在什么情境下会怎样行动」',
      ),
      'current_state': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '随剧情变化的当前状态',
        search: {_FieldSearch.body},
      ),
      'first_appear_chapter_id': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          nullable: true,
          referenceTarget: 'chapters',
        ),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '首次出场章节 ID',
      ),
      'avatar_asset_id': _ResourceField(
        value: _ValueSchema(_ValueType.string, nullable: true),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '头像图片资产 ID；清空可移除头像',
      ),
      'skills': _ResourceField(
        value: _ValueSchema(
          _ValueType.array,
          items: _ValueSchema(
            _ValueType.object,
            properties: {
              'name': _ValueProperty(_ValueSchema(_ValueType.string)),
              'path': _ValueProperty(_ValueSchema(_ValueType.string)),
              'relation_type': _ValueProperty(_ValueSchema(_ValueType.string)),
            },
          ),
        ),
        read: _FieldRead(path: true),
        description:
            '技能列表，每项含 name、path、relation_type'
            '（learned 已学会 / mastering 学习中 / mastered 已精通 / creator 创造者）',
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
  ),
  'foreshadowing': _ResourceDefinition(
    segment: 'foreshadowing',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'foreshadowing_id'),
    description: '伏笔',
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.short_text},
      ),
      'setup': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '铺垫内容',
        search: {_FieldSearch.body},
      ),
      'payoff': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '回收内容',
        search: {_FieldSearch.body},
      ),
      'status': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          enumAliases: _ChineseEnumMappings.foreshadowingStatusAliases,
          enumValues: foreshadowingStatuses,
        ),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
      ),
      'setup_chapter_id': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          nullable: true,
          referenceTarget: 'chapters',
        ),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '小说铺垫章节 ID；与 setup_scene_id 互斥，null 清空',
      ),
      'payoff_chapter_id': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          nullable: true,
          referenceTarget: 'chapters',
        ),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '小说回收章节 ID；与 payoff_scene_id 互斥，null 清空',
      ),
      'setup_scene_id': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          nullable: true,
          referenceTarget: 'scenes',
        ),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '剧本铺垫场次 ID；与 setup_chapter_id 互斥，null 清空',
      ),
      'payoff_scene_id': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          nullable: true,
          referenceTarget: 'scenes',
        ),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '剧本回收场次 ID；与 payoff_chapter_id 互斥，null 清空',
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
        constraints: [
          _ResourceConstraint(_ConstraintKind.mutually_exclusive, [
            'setup_chapter_id',
            'setup_scene_id',
          ]),
          _ResourceConstraint(_ConstraintKind.mutually_exclusive, [
            'payoff_chapter_id',
            'payoff_scene_id',
          ]),
        ],
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
        constraints: [
          _ResourceConstraint(_ConstraintKind.mutually_exclusive, [
            'setup_chapter_id',
            'setup_scene_id',
          ]),
          _ResourceConstraint(_ConstraintKind.mutually_exclusive, [
            'payoff_chapter_id',
            'payoff_scene_id',
          ]),
        ],
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
  ),
  'locations': _ResourceDefinition(
    segment: 'locations',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'location_id'),
    description: '地点',
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'photos': _ResourceField(
        value: _subjectPhotosValue,
        read: _FieldRead(path: true),
        write: _FieldInputUse(field: true),
      ),
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'name': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        query: _FieldQuery(),
        search: {_FieldSearch.short_text},
      ),
      'description': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'type': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          enumAliases: _ChineseEnumMappings.locationTypeZh,
          enumValues: locationTypes,
        ),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(
          hasDefault: true,
          defaultValue: locationTypeGeneric,
        ),
        write: _FieldInputUse(field: true),
      ),
      'parent_id': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          nullable: true,
          referenceTarget: 'locations',
        ),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        query: _FieldQuery(),
        description: '上级地点 ID；仅 type=world 可省略。无父节点时先创建 world，再用返回的 id 创建子地点。',
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
  ),
  'skills': _ResourceDefinition(
    segment: 'skills',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'skill_id'),
    description: '技能',
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.short_text},
      ),
      'content': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'category': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
    itemType: 'skill',
  ),
  'items': _ResourceDefinition(
    segment: 'items',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'item_id'),
    description: '物品',
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.short_text},
      ),
      'content': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'category': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
    itemType: 'item',
  ),
  'factions': _ResourceDefinition(
    segment: 'factions',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'faction_id'),
    description: '势力',
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.short_text},
      ),
      'content': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'category': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
    itemType: 'faction',
  ),
  'creatures': _ResourceDefinition(
    segment: 'creatures',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'creature_id'),
    description: '生物',
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.short_text},
      ),
      'content': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'category': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
    itemType: 'creature',
  ),
  'lore': _ResourceDefinition(
    segment: 'lore',
    address: _ResourceAddress(
      _AddressKind.hierarchical_name,
      itemToken: 'title',
      nameField: 'title',
    ),
    description: '世界设定',
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'is_folder': _ResourceField(
        value: _ValueSchema(_ValueType.boolean),
        read: _FieldRead(listing: true),
      ),
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.short_text},
      ),
      'content': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'category': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
        parameters: {
          'type': _OperationParameter(
            _ValueSchema(
              _ValueType.string,
              enumAliases: _ChineseEnumMappings.documentCreateTypeZh,
              enumValues: ['document', 'folder'],
            ),
            description: 'document 建文档，folder 建目录；多级路径上缺失的父目录会自动创建',
          ),
        },
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
        missingTarget: _MissingTarget.create,
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
          'recursive': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
    documentType: 'lore',
  ),
  'outlines': _ResourceDefinition(
    segment: 'outlines',
    address: _ResourceAddress(
      _AddressKind.name,
      itemToken: 'title',
      nameField: 'title',
    ),
    description: '大纲',
    group: contentKindNovel,
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'is_folder': _ResourceField(
        value: _ValueSchema(_ValueType.boolean),
        read: _FieldRead(listing: false),
      ),
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.short_text},
      ),
      'content': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'status': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          enumAliases: _ChineseEnumMappings.outlineStatusAliases,
          enumValues: outlineStatuses,
        ),
        read: _FieldRead(listing: true, path: true, requiredInListing: false),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
      ),
      'start_chapter_num': _ResourceField(
        value: _ValueSchema(_ValueType.integer, minimum: 1),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(hasDefault: true, defaultValue: 1),
        write: _FieldInputUse(field: true),
        description: '本大纲覆盖的起始章节序号',
      ),
      'beats': _ResourceField(
        value: _ValueSchema(
          _ValueType.array,
          items: _ValueSchema(
            _ValueType.object,
            fieldReference: _outlineBeatFieldsDefinition,
          ),
          identity: _ArrayIdentity.plain_values,
        ),
        read: _FieldRead(),
        create: _FieldInputUse(
          value: _ValueSchema(
            _ValueType.array,
            items: _ValueSchema(
              _ValueType.object,
              fieldReference: _outlineBeatFieldsDefinition,
              projection: _FieldProjection.create,
              requireProjectedFields: false,
            ),
            identity: _ArrayIdentity.new_items,
          ),
        ),
        description: '节拍列表',
      ),
    },
    children: [_outlineBeatDefinition],
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
    documentType: 'outline',
  ),
  'materials': _ResourceDefinition(
    segment: 'materials',
    address: _ResourceAddress(
      _AddressKind.hierarchical_name,
      itemToken: 'title',
      nameField: 'title',
    ),
    description: '素材',
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'is_folder': _ResourceField(
        value: _ValueSchema(_ValueType.boolean),
        read: _FieldRead(listing: true),
      ),
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.short_text},
      ),
      'content': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'category': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            query: _FieldQuery(match: _QueryMatch.contains),
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
        parameters: {
          'type': _OperationParameter(
            _ValueSchema(
              _ValueType.string,
              enumAliases: _ChineseEnumMappings.documentCreateTypeZh,
              enumValues: ['document', 'folder'],
            ),
            description: 'document 建文档，folder 建目录；多级路径上缺失的父目录会自动创建',
          ),
        },
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
        missingTarget: _MissingTarget.create,
      ),

      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
          'recursive': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
    documentType: 'material',
  ),
  if (ideationCanvasEnabled)
    'canvas': _ResourceDefinition(
      segment: 'canvas',
      address: _ResourceAddress(
        _AddressKind.name,
        itemToken: 'name',
        nameField: 'name',
      ),
      description:
          '构思画布，用于剧情、关系与灵感组织；按集制作画布位于 `/episodes/{episode_id}/production/canvas`。',
      listing: _ResourceListing(),
      fields: {
        'id': _ResourceField(
          value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
          read: _FieldRead(listing: true),
        ),
        'name': _ResourceField(
          value: _ValueSchema(_ValueType.string),
          read: _FieldRead(listing: true, path: true),
          create: _FieldInputUse(required: true),
          write: _FieldInputUse(field: true),
          search: {_FieldSearch.short_text},
        ),
        'description': _ResourceField(
          value: _ValueSchema(_ValueType.string),
          read: _FieldRead(listing: true, path: true),
          create: _FieldInputUse(),
          write: _FieldInputUse(field: true),
          search: {_FieldSearch.short_text},
        ),
        'node_count': _ResourceField(
          value: _ValueSchema(_ValueType.integer),
          read: _FieldRead(listing: true),
        ),
        'edge_count': _ResourceField(
          value: _ValueSchema(_ValueType.integer),
          read: _FieldRead(listing: true),
        ),
        'layout': _ResourceField(
          value: _ValueSchema(
            _ValueType.object,
            properties: {
              'grid_pitch': _ValueProperty(
                _ValueSchema(
                  _ValueType.object,
                  properties: {
                    'x': _ValueProperty(_ValueSchema(_ValueType.number)),
                    'y': _ValueProperty(_ValueSchema(_ValueType.number)),
                  },
                ),
              ),
              'node_count': _ValueProperty(_ValueSchema(_ValueType.integer)),
              'edge_count': _ValueProperty(_ValueSchema(_ValueType.integer)),
              'off_grid': _ValueProperty(_ValueSchema(_ValueType.integer)),
              'mode': _ValueProperty(
                _ValueSchema(
                  _ValueType.string,
                  nullable: true,
                  enumValues: canvasLayoutSavedModes,
                ),
              ),
            },
          ),
          read: _FieldRead(detail: false, path: true),
          write: _FieldInputUse(
            resource: false,
            field: false,
            value: _ValueSchema(
              _ValueType.string,
              enumValues: canvasLayoutModes,
            ),
          ),
        ),
        'open': _ResourceField(
          value: _ValueSchema(_ValueType.boolean),
          write: _FieldInputUse(
            resource: false,
            field: false,
            value: _ValueSchema(_ValueType.boolean, enumValues: [true]),
          ),
        ),
      },
      children: [_canvasNodeDefinition, _canvasEdgeDefinition],
      operations: [
        _ResourceOperation(
          _ResourceTool.write,
          _ResourceTargetKind.field,
          field: 'layout',
          input: _ResourceInput(
            _ResourceInputKind.field_value,
            field: 'layout',
          ),
          result: _ResourceResult(
            _ResourceResultKind.mutation,
            value: _ValueSchema(
              _ValueType.object,
              properties: {
                'updated': _ValueProperty(_ValueSchema(_ValueType.boolean)),
              },
            ),
            references: ['path'],
          ),
        ),
        _ResourceOperation(
          _ResourceTool.write,
          _ResourceTargetKind.field,
          field: 'open',
          input: _ResourceInput(_ResourceInputKind.field_value, field: 'open'),
          result: _ResourceResult(
            _ResourceResultKind.mutation,
            value: _ValueSchema(
              _ValueType.object,
              properties: {
                'ok': _ValueProperty(_ValueSchema(_ValueType.boolean)),
              },
            ),
          ),
        ),
        _ResourceOperation(
          _ResourceTool.read,
          _ResourceTargetKind.listing,
          parameters: {
            'search': _OperationParameter(
              _ValueSchema(_ValueType.string),
              query: _FieldQuery(match: _QueryMatch.contains),
            ),
          },
          result: _ResourceResult(
            _ResourceResultKind.listing,
            references: ['entries[].path'],
          ),
        ),
        _ResourceOperation(
          _ResourceTool.read,
          _ResourceTargetKind.resource,
          result: _ResourceResult(
            _ResourceResultKind.entity,
            references: ['path'],
          ),
        ),
        _ResourceOperation(
          _ResourceTool.create,
          _ResourceTargetKind.listing,
          input: _ResourceInput(_ResourceInputKind.create_fields),
        ),
        _ResourceOperation(
          _ResourceTool.write,
          _ResourceTargetKind.resource,
          input: _ResourceInput(_ResourceInputKind.resource_fields),
          constraints: [
            _ResourceConstraint(_ConstraintKind.at_least_one, [
              'name',
              'description',
            ], presence: _ConstraintPresence.present),
          ],
        ),
        _ResourceOperation(
          _ResourceTool.remove,
          _ResourceTargetKind.resource,
          parameters: {
            'force': _OperationParameter(
              _ValueSchema(_ValueType.boolean),
              hasDefault: true,
              defaultValue: false,
            ),
          },
        ),
      ],
    ),
  'relations': _ResourceDefinition(
    segment: 'relations',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'relation_id'),
    description: '实体关系',
    listing: _ResourceListing(),
    fields: _relationFields,
    children: [
      _ResourceDefinition(
        segment: 'change_logs',
        address: _ResourceAddress(_AddressKind.id, itemToken: 'change_id'),
        description: '这条关系的有效初始记录和变化历史；删除最新变化会恢复前一个状态，删除更早变化不改变当前状态。',
        listing: _ResourceListing(),
        fields: {
          'id': _ResourceField(
            value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
            read: _FieldRead(listing: true),
          ),
          'kind': _ResourceField(
            value: _ValueSchema(
              _ValueType.string,
              enumValues: ['baseline', 'change'],
            ),
            read: _FieldRead(listing: true),
          ),
          'relation_type': _ResourceField(
            value: _ValueSchema(_ValueType.string),
            read: _FieldRead(listing: true),
          ),
          'status': _ResourceField(
            value: _ValueSchema(
              _ValueType.string,
              enumValues: ['active', 'ended'],
            ),
            read: _FieldRead(listing: true),
          ),
          'proof': _ResourceField(
            value: _ValueSchema(_ValueType.string),
            read: _FieldRead(listing: true),
          ),
          'chapter_id': _ResourceField(
            value: _ValueSchema(
              _ValueType.string,
              nullable: true,
              referenceTarget: 'chapters',
            ),
            read: _FieldRead(listing: true),
          ),
          'scene_id': _ResourceField(
            value: _ValueSchema(
              _ValueType.string,
              nullable: true,
              referenceTarget: 'scenes',
            ),
            read: _FieldRead(listing: true),
          ),
          'reason': _ResourceField(
            value: _ValueSchema(_ValueType.string),
            read: _FieldRead(listing: true),
          ),
          'recorded_at': _ResourceField(
            value: _ValueSchema(_ValueType.string),
            read: _FieldRead(listing: true),
          ),
        },
        operations: [
          _ResourceOperation(
            _ResourceTool.read,
            _ResourceTargetKind.listing,
            result: _ResourceResult(
              _ResourceResultKind.listing,
              references: ['path', 'entries[].path', 'parent_path'],
            ),
          ),
          _ResourceOperation(
            _ResourceTool.read,
            _ResourceTargetKind.resource,
            result: _ResourceResult(
              _ResourceResultKind.entity,
              references: ['path', 'parent_path'],
            ),
          ),
          _ResourceOperation(
            _ResourceTool.remove,
            _ResourceTargetKind.resource,
            parameters: {
              'force': _OperationParameter(
                _ValueSchema(_ValueType.boolean),
                hasDefault: true,
                defaultValue: false,
              ),
            },
            result: _ResourceResult(
              _ResourceResultKind.mutation,
              references: ['path', 'relation.path', 'relation.history_path'],
            ),
          ),
        ],
      ),
    ],
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path', 'entries[].history_path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path', 'history_path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
        constraints: [
          _ResourceConstraint(_ConstraintKind.mutually_exclusive, [
            'chapter_id',
            'scene_id',
          ]),
        ],
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
        constraints: [
          _ResourceConstraint(_ConstraintKind.mutually_exclusive, [
            'chapter_id',
            'scene_id',
          ]),
        ],
        result: _ResourceResult(
          _ResourceResultKind.mutation,
          references: ['path', 'history_path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.remove,
        _ResourceTargetKind.resource,
        parameters: {
          'force': _OperationParameter(
            _ValueSchema(_ValueType.boolean),
            hasDefault: true,
            defaultValue: false,
          ),
        },
      ),
    ],
  ),
  'screenplay': _ResourceDefinition(
    segment: 'screenplay',
    address: _ResourceAddress(_AddressKind.singleton),
    description: '剧本概览',
    group: contentKindScreenplay,
    fields: {
      'style_id': _ResourceField(
        value: _ValueSchema(_ValueType.string, nullable: true),
        read: _FieldRead(path: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '剧本默认视觉风格。使用 Run styles 返回的 ID；null 表示无风格。',
      ),
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
      ),
      'ratio': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          enumValues: ProductionSettings.ratios,
        ),
        read: _FieldRead(path: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
      ),
      'resolution': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          enumValues: ProductionSettings.resolutions,
        ),
        read: _FieldRead(path: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
      ),
      'width': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(path: true),
      ),
      'height': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(path: true),
      ),

      'kind': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(),
      ),
      'format': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(),
      ),
      'season_count': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(),
      ),
      'episode_count': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(),
      ),
      'scene_count': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(),
      ),
      'page_eighths': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(),
      ),
      'dialogue_line_count': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(),
      ),
      'word_count': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(),
      ),
    },
    operations: [
      _productionWrite,
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
    ],
  ),
  'seasons': _ResourceDefinition(
    segment: 'seasons',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'season_id'),
    description: '季',
    group: contentKindScreenplay,
    hidden: false,
    listing: _ResourceListing(),
    fields: {
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'season_number': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(listing: true),
        description: '只读；季不支持重排',
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        search: {_FieldSearch.short_text},
      ),
      'planned_episode_count': _ResourceField(
        value: _ValueSchema(_ValueType.integer, nullable: true, minimum: 1),
        read: _FieldRead(listing: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
      ),
    },
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),
    ],
  ),
  'episodes': _ResourceDefinition(
    segment: 'episodes',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'episode_id'),
    description: '集',
    group: contentKindScreenplay,
    hidden: false,
    listing: _ResourceListing(parentQuery: 'season_id'),
    fields: {
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'editing_id': _ResourceField(
        value: _ValueSchema(_ValueType.string, nullable: true),
        read: _FieldRead(listing: true, path: true),
      ),
      'season_id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'seasons'),
        read: _FieldRead(listing: true),
        create: _FieldInputUse(required: true),
        write: _FieldInputUse(field: true),
        query: _FieldQuery(),
        description: '所属季；写入会把该集移动到目标季',
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        search: {_FieldSearch.short_text},
      ),
      'episode_number': _ResourceField(
        value: _ValueSchema(_ValueType.integer, minimum: 1),
        read: _FieldRead(listing: true),
        write: _FieldInputUse(field: true),
        description: '目标位置；写入会把该集移到这个位置并重排同季其余集，取值 1 到该季集数',
      ),
      'outline': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(path: true),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '集大纲；写入计入待审阅改动',
        search: {_FieldSearch.body},
      ),
    },
    children: [_episodeProductionDefinition],
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
      ),
      _ResourceOperation(_ResourceTool.remove, _ResourceTargetKind.resource),
    ],
  ),
  'clips': _ResourceDefinition(
    segment: 'clips',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'clip_id'),
    description: '制作条目（分镜及独立图片、视频、音频）',
    group: contentKindScreenplay,
    hidden: false,
    listing: _ResourceListing(parentQuery: 'scene_id'),
    fields: {
      ..._productionClipFields,
      'is_storyboard': _ResourceField(
        value: _ValueSchema(_ValueType.boolean),
        description: '是否已编入场次的分镜，可为图片或视频；查询分镜使用 is_storyboard=true。',
        read: _FieldRead(listing: true, path: true),
        query: _FieldQuery(normalization: _QueryNormalization.boolean),
      ),
      'character_id': _ResourceField(
        value: _ValueSchema(_ValueType.string, nullable: true),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
      ),
      'location_id': _ResourceField(
        value: _ValueSchema(_ValueType.string, nullable: true),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
      ),
      'item_id': _ResourceField(
        value: _ValueSchema(_ValueType.string, nullable: true),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
      ),
      'scene_id': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          nullable: true,
          referenceTarget: 'scenes',
        ),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        query: _FieldQuery(),
      ),
      'episode_id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'episodes'),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        query: _FieldQuery(),
      ),
      'sort_order': _ResourceField(
        value: _ValueSchema(_ValueType.integer, nullable: true, minimum: 0),
        read: _FieldRead(listing: true, path: true),
        write: _FieldInputUse(field: true),
      ),
    },
    children: [_clipGenerations],
    operations: _productionClipOperations,
  ),
  'scenes': _ResourceDefinition(
    segment: 'scenes',
    address: _ResourceAddress(_AddressKind.id, itemToken: 'scene_id'),
    description: '场次',
    group: contentKindScreenplay,
    hidden: false,
    listing: _ResourceListing(parentQuery: 'episode_id'),
    fields: {
      'id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'self'),
        read: _FieldRead(listing: true),
      ),
      'episode_id': _ResourceField(
        value: _ValueSchema(_ValueType.string, referenceTarget: 'episodes'),
        read: _FieldRead(listing: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(),
        query: _FieldQuery(),
      ),
      'scene_number': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(listing: true),
        description: '只读；调整位置用 before_scene_id 或 after_scene_id',
      ),
      'location_id': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          nullable: true,
          referenceTarget: 'locations',
        ),
        read: _FieldRead(listing: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(),
      ),
      'interior_exterior': _ResourceField(
        value: _ValueSchema(
          _ValueType.string,
          nullable: true,
          enumValues: ['interior', 'exterior', 'interior_exterior'],
        ),
        read: _FieldRead(listing: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(),
      ),
      'title': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        description: '概括本场事件的短标题；可清空，不进入剧本正文',
        search: {_FieldSearch.body},
      ),
      'emotion': _ResourceField(
        value: _emotionValue,
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '正文的主导情绪标签，不得为空字符串或重复；空数组可清空',
      ),
      'events': _ResourceField(
        value: _ValueSchema(_ValueType.array, items: _eventValue),
        read: _FieldRead(path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        description: '按发生顺序排列；每项含非空 title、summary 和可选字符串 state_change；空数组可清空',
      ),
      'time': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        aliases: ['time_label'],
        read: _FieldRead(listing: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(),
      ),
      'synopsis': _ResourceField(
        value: _ValueSchema(_ValueType.string),
        read: _FieldRead(listing: true, path: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(field: true),
        edit: _FieldEdit(),
        search: {_FieldSearch.body},
      ),
      'stage': _ResourceField(
        value: _ValueSchema(_ValueType.string, enumValues: ['draft', 'final']),
        read: _FieldRead(listing: true),
        create: _FieldInputUse(),
        write: _FieldInputUse(),
        query: _FieldQuery(),
      ),
      'cast': _ResourceField(
        value: _ValueSchema(
          _ValueType.array,
          items: _ValueSchema(
            _ValueType.object,
            properties: {
              'character_id': _ValueProperty(
                _ValueSchema(_ValueType.string, referenceTarget: 'characters'),
              ),
              'name': _ValueProperty(_ValueSchema(_ValueType.string)),
            },
          ),
        ),
        read: _FieldRead(detail: false, path: true),
        create: _FieldInputUse(
          value: _ValueSchema(
            _ValueType.array,
            items: _ValueSchema(
              _ValueType.string,
              minLength: 1,
              referenceTarget: 'characters',
            ),
            identity: _ArrayIdentity.references,
            referenceTarget: 'characters',
          ),
        ),
        write: _FieldInputUse(
          field: true,
          value: _ValueSchema(
            _ValueType.array,
            items: _ValueSchema(
              _ValueType.string,
              minLength: 1,
              referenceTarget: 'characters',
            ),
            identity: _ArrayIdentity.references,
            referenceTarget: 'characters',
          ),
        ),
        description: '出场角色 ID 数组，如 ["cha_xxx"]。',
      ),
      'elements': _ResourceField(
        value: _screenplayElementArray,
        create: _FieldInputUse(),
        description: '正文元素；已有场次的正文通过 elements 子资源读写',
      ),
      'page_eighths': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(listing: true),
      ),
      'dialogue_line_count': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(listing: true),
      ),
      'word_count': _ResourceField(
        value: _ValueSchema(_ValueType.integer),
        read: _FieldRead(listing: true),
      ),
    },
    children: [_screenplayElementDefinition],
    operations: [
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.listing,
        parameters: {
          'search': _OperationParameter(
            _ValueSchema(_ValueType.string),
            description: '匹配场次短标题、梗概和时间标签',
          ),
        },
        result: _ResourceResult(
          _ResourceResultKind.listing,
          references: ['entries[].path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.read,
        _ResourceTargetKind.resource,
        result: _ResourceResult(
          _ResourceResultKind.entity,
          references: ['path'],
        ),
      ),
      _ResourceOperation(
        _ResourceTool.create,
        _ResourceTargetKind.listing,
        input: _ResourceInput(_ResourceInputKind.create_fields),
        parameters: {
          'before_scene_id': _OperationParameter(
            _ValueSchema(_ValueType.string, referenceTarget: 'scenes'),
          ),
          'after_scene_id': _OperationParameter(
            _ValueSchema(_ValueType.string, referenceTarget: 'scenes'),
          ),
        },
        // 落点必须显式：要么直接给集，要么给同集内的锚点场次继承。
        constraints: [
          _ResourceConstraint(_ConstraintKind.at_least_one, [
            'episode_id',
            'before_scene_id',
            'after_scene_id',
          ]),
          _ResourceConstraint(_ConstraintKind.mutually_exclusive, [
            'episode_id',
            'before_scene_id',
            'after_scene_id',
          ]),
        ],
      ),
      _ResourceOperation(
        _ResourceTool.write,
        _ResourceTargetKind.resource,
        input: _ResourceInput(_ResourceInputKind.resource_fields),
        parameters: {
          'before_scene_id': _OperationParameter(
            _ValueSchema(_ValueType.string, referenceTarget: 'scenes'),
          ),
          'after_scene_id': _OperationParameter(
            _ValueSchema(_ValueType.string, referenceTarget: 'scenes'),
          ),
        },
        constraints: [
          _ResourceConstraint(_ConstraintKind.mutually_exclusive, [
            'episode_id',
            'before_scene_id',
            'after_scene_id',
          ]),
        ],
      ),
      _ResourceOperation(_ResourceTool.remove, _ResourceTargetKind.resource),
    ],
  ),
};

ParsedPath parseAiToolPath(String rawPath) {
  return ParsedPath.parse(
    rawPath,
    schemaLookup: (name) => _resourceDefinitions[name],
  );
}

typedef AiToolEventCallback =
    void Function(
      String callId,
      String toolName,
      Map<String, dynamic> arguments,
      Map<String, dynamic>? result,
      String? errorMessage,
    );

typedef AiNovelReader = Future<Map<String, dynamic>?> Function();
typedef AiNovelWriter = Future<void> Function(Map<String, dynamic> fields);
// 清除快速开书占位标记（「加入书架」）：由 Run 的 add-to-library 命令显式触发，
// 不耦合任何写入动作。内部预检测，已非 draft 时无 DB 写入。
typedef AiNovelDraftClearer = Future<void> Function();

typedef AiToolCallRequestedCallback =
    void Function(
      String callId,
      String toolName,
      Map<String, dynamic> arguments,
    );
typedef AiToolShouldExecuteCallback = bool Function();
typedef AiImageGenerationCallback =
    Future<AiImageGenerationResult> Function(
      String prompt, {
      String? model,
      String? size,
      // 出图质量。null 表示不写这个参数，交给服务端默认。
      String? quality,
      // 复杂度。原样传用户的选择，由生图服务按型号校验并补目录默认值。
      String? complexity,
    });
typedef AiImageEditCallback =
    Future<AiImageGenerationResult> Function(
      String prompt, {
      required String imageData,
      String? model,
    });
typedef AiMultiImageEditCallback =
    Future<AiImageGenerationResult> Function(
      String prompt, {
      required List<String> imageData,
      String? model,
      String? size,
      String? quality,
      String? complexity,
    });
typedef AiCreateLocationCallback =
    Future<String> Function({
      required String name,
      String? description,
      String? type,
      String? parentId,
    });
typedef SkillLoaderCallback =
    Future<AgentSkillLoadResult?> Function(String name);
typedef SkillNamesProvider = List<String> Function();
typedef AiAgentSkillsCommandCallback =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> command);
typedef AiThemesCommandCallback =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> command);

typedef AiSubagentsCommandCallback =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> command);
typedef AiSessionsCommandCallback =
    Future<Map<String, dynamic>> Function(
      String action,
      Map<String, dynamic> options, {
      String? currentSessionId,
      String? sourceSessionId,
    });
typedef AiMapDraftCommandCallback =
    Future<Map<String, dynamic>> Function(MapDesignDraft draft);

/// Run notify 子命令回调：run agent 主动通知 Assistant（写 inbox）。
/// command 含 `action`(progress|question|complete|error) 与 `content`。
/// 由远程 Assistant 启动的 run 挂载；桌面本地 run 不挂载（notify 不可用）。
typedef AiRunNotifyCallback =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> command);

/// 画布操作上报回调：canvas 工具写库成功后广播「刚做了什么、碰了哪些节点」，
/// 供画布 UI 跟随镜头与提示状态。纯通知，不影响工具返回值。
/// 画布活动上报。返回 Future 时表示画布页正在演这一步,写工具会等它完成再返回
/// (背压);单次等待上限与取消放行由 [AiToolManager] 负责。
typedef AiCanvasActivityReporter =
    FutureOr<void> Function(CanvasAiActivity activity);

abstract class _AiToolManagerBase {
  NovelContentService get _primaryContentService;
  AiNovelReader? get _primaryNovelReader;
  NovelContentService get _contentService;
  CrossWorkAccess? get crossWorkAccess;
  Future<List<AiProvider>> Function()? get providerReader;
  WorkingOverlayService get workingOverlayService;
  String? get sessionId;
  String? get sourceSessionId;
  String get contentKind;
  String? get workId;
  String? get currentSeasonId;
  String? get currentEpisodeId;
  String get _targetContentKind;
  Map<String, dynamic>? _contentKindGate(ParsedPath parsed);
  List<Map<String, dynamic>> _workspaceRootEntries();
  bool isScreenplayPath(ParsedPath parsed);
  Future<Map<String, dynamic>> _executeScreenplay(
    ParsedPath parsed,
    _ResourceOperation operation, {
    Map<String, dynamic> fields = const {},
    bool force = false,
    ({String oldText, String newText, bool replaceAll})? edit,
  });

  AiNovelReader? get novelReader;
  AiNovelWriter? get novelWriter;
  AiNovelDraftClearer? get novelDraftClearer;
  AiImageGenerationCallback? get imageGenerationCallback;
  AiImageEditCallback? get imageEditCallback;
  AiAgentSkillsCommandCallback? get agentSkillsCommandCallback;
  AiThemesCommandCallback? get themesCommandCallback;
  AiSubagentsCommandCallback? get subagentsCommandCallback;
  AiSessionsCommandCallback? get sessionsCommandCallback;
  ToolOperationHost? get operationHost;
  McpRunCommandHandler? get mcpRunHandler;
  bool Function()? get mcpAllowed;
  Future<ProductionCanvasService> Function()? get productionStyleServiceBuilder;

  /// 画布工具放行。
  /// Feature 未授权时的通用升级引导入口。

  SkillLoaderCallback? get skillLoader;
  SkillNamesProvider? get skillNamesProvider;
  SuggestNextActionCallback? get suggestNextActionCallback;
  AiRunNotifyCallback? get notifyCallback;

  /// 把已校验的地图设计草稿交给当前宿主展示。
  AiMapDraftCommandCallback? mapDraftCommandCallback;

  /// 上报画布操作的回调(由 chat.dart 注入 riverpod canvasAiActivityProvider)。
  /// 画布 UI 靠它跟随镜头与显示状态条;未打开画布页时为空实现。
  AiCanvasActivityReporter? get canvasActivityReporter;

  /// Callback for creating locations directly (bypasses working change patch).
  AiCreateLocationCallback? createLocationCallback;

  _ResourceDefinition? _getCollectionSchema(String name) =>
      _resourceDefinitions[name];

  /// Publish after the outermost tool-owned transaction commits. A failed
  /// savepoint discards only its own compact capture, never earlier commits.
  Future<T> _withWorkingChangeTransaction<T>(
    Future<T> Function() action,
  ) async {
    if (_currentToolExecutionContext?.lifecycleObserver?.onWorkingChange ==
        null) {
      return _contentService.database.transaction(action);
    }
    final captured = _WorkingChangeCapture();
    final result = await _contentService.database.transaction(
      () => runZoned(
        action,
        zoneValues: {_workingChangeCaptureZoneKey: captured},
      ),
    );
    final change = captured.value;
    if (change != null) {
      _emitWorkingChange(change);
    }
    return result;
  }

  void _emitWorkingChange(ToolWorkingChange change) {
    final captured =
        Zone.current[_workingChangeCaptureZoneKey] as _WorkingChangeCapture?;
    if (captured != null) {
      captured.add(change);
    } else {
      _currentToolExecutionContext?.lifecycleObserver?.onWorkingChange?.call(
        change,
      );
    }
  }

  void _reportWorkingChange(WorkingChange change) {
    if (_currentToolExecutionContext?.lifecycleObserver?.onWorkingChange ==
        null) {
      return;
    }
    final session = change.sourceSessionId;
    final turn = change.sourceTurnId;
    if (session == null || turn == null) {
      throw StateError('Nested working change is missing source identity');
    }
    _emitWorkingChange(
      ToolWorkingChange(
        id: change.id,
        scope: AiWorkingChangeScope(
          sourceSessionId: session,
          sourceTurnId: turn,
          resourcePath: canonicalResourcePath(change.resourcePath),
        ),
      ),
    );
  }

  Future<WorkingChange> _stageTextChange({
    required String resourcePath,
    required String resourceType,
    required String? resourceId,
    required String? field,
    required String? oldText,
    required String newText,
    required String source,
    String? toolName,
    String? summary,
  }) async {
    final context = _currentToolExecutionContext;
    final staged = await workingOverlayService.stageTextChange(
      resourcePath: resourcePath,
      resourceType: resourceType,
      resourceId: resourceId,
      field: field,
      oldText: oldText,
      newText: newText,
      source: source,
      sourceSessionId: context?.sourceSessionId ?? sourceSessionId,
      sourceTurnId: context?.sourceTurnId,
      toolName: _currentStagingToolName ?? toolName,
      summary: summary,
    );
    _reportWorkingChange(staged);
    return staged;
  }

  Future<List<WorkingChange>> _stageTextChangesAtomically({
    required List<WorkingTextChangeRequest> changes,
    required String source,
    String? toolName,
  }) async {
    final context = _currentToolExecutionContext;
    final staged = await workingOverlayService.stageTextChangesAtomically(
      changes: changes,
      source: source,
      sourceSessionId: context?.sourceSessionId ?? sourceSessionId,
      sourceTurnId: context?.sourceTurnId,
      toolName: _currentStagingToolName ?? toolName,
    );
    for (final change in staged) {
      _reportWorkingChange(change);
    }
    return staged;
  }

  Future<WorkingChange> _stageCreateChange({
    required String resourcePath,
    required String resourceType,
    required String resourceId,
    required String previewText,
    required String source,
    String? toolName,
    String? summary,
  }) async {
    final context = _currentToolExecutionContext;
    final staged = await workingOverlayService.stageCreateChange(
      resourcePath: resourcePath,
      resourceType: resourceType,
      resourceId: resourceId,
      previewText: previewText,
      source: source,
      sourceSessionId: context?.sourceSessionId ?? sourceSessionId,
      sourceTurnId: context?.sourceTurnId,
      toolName: toolName,
      summary: summary,
    );
    _reportWorkingChange(staged);
    return staged;
  }
}

/// 工具分组 — 用于按需选择工具子集
enum AiToolGroup {
  run,
  read,
  search,
  web,
  create,
  write,
  edit,
  graph,
  image,
  subagent,
  askUser,
  suggestion,
  todo,
  skill,
}

class AiToolDefinition {
  const AiToolDefinition({
    required this.name,
    required this.group,
    this.agentConfigurable = true,
    this.subAgentConfigurable = true,
  });

  final String name;
  final AiToolGroup group;
  final bool agentConfigurable;
  final bool subAgentConfigurable;
}

const List<AiToolDefinition> aiToolCatalog = [
  AiToolDefinition(name: runToolName, group: AiToolGroup.run),
  AiToolDefinition(name: 'Read', group: AiToolGroup.read),
  AiToolDefinition(name: 'Glob', group: AiToolGroup.search),
  AiToolDefinition(name: 'Grep', group: AiToolGroup.search),
  AiToolDefinition(name: 'Create', group: AiToolGroup.create),
  AiToolDefinition(name: 'Write', group: AiToolGroup.write),
  AiToolDefinition(name: 'Remove', group: AiToolGroup.write),
  AiToolDefinition(name: 'Edit', group: AiToolGroup.edit),
  AiToolDefinition(name: 'Replace', group: AiToolGroup.edit),
  AiToolDefinition(name: 'GraphSearch', group: AiToolGroup.graph),
  AiToolDefinition(name: 'SpawnAgent', group: AiToolGroup.subagent),
  AiToolDefinition(
    name: sendAgentMessageToolName,
    group: AiToolGroup.subagent,
    subAgentConfigurable: false,
  ),
  AiToolDefinition(
    name: stopAgentToolName,
    group: AiToolGroup.subagent,
    subAgentConfigurable: false,
  ),
  AiToolDefinition(
    name: 'ForkAgent',
    group: AiToolGroup.subagent,
    agentConfigurable: false,
    subAgentConfigurable: false,
  ),
  AiToolDefinition(
    name: 'AskUser',
    group: AiToolGroup.askUser,
    subAgentConfigurable: false,
  ),
  // 同 AskUser：SubAgent 不得调用，否则正文写手会在委派中途给用户推导航。
  AiToolDefinition(
    name: suggestNextActionToolName,
    group: AiToolGroup.suggestion,
    subAgentConfigurable: false,
  ),
  AiToolDefinition(name: 'TodoWrite', group: AiToolGroup.todo),
  AiToolDefinition(name: 'AgentSkill', group: AiToolGroup.skill),
];

List<String> defaultAgentToolNames() => aiToolCatalog
    .where((item) => item.agentConfigurable)
    .map((item) => item.name)
    .toList();

List<String> defaultSubAgentToolNames() => aiToolCatalog
    .where((item) => item.subAgentConfigurable)
    .where((item) => item.name != spawnAgentToolName)
    .where((item) => item.name != forkAgentToolName)
    .map((item) => item.name)
    .toList();

/// 工具的"无 Genkit 上下文"调用签名,executeTool 直接走它,不走 Genkit auto-exec。
typedef RawToolHandler =
    Future<Map<String, dynamic>> Function(
      Map<String, dynamic> input,
      String? callId,
    );

/// Provides unified Read / Write / Edit / Create* tools over a resource path system.
class AiToolManager extends _AiToolManagerBase
    with
        _AiToolManagerPathHintsMixin,
        _AiToolManagerCanvasMixin,
        _AiToolManagerScreenplayMixin,
        _AiToolManagerOutlineMixin,
        _AiToolManagerReadMixin,
        _AiToolManagerResourceSearchSupportMixin,
        _AiToolManagerGlobMixin,
        _AiToolManagerGrepMixin,
        _AiToolManagerImageMixin,
        _AiToolManagerAgentRulesRunMixin,
        _AiToolManagerRunMixin,
        _AiToolManagerWriteMixin,
        _AiToolManagerEditMixin,
        _AiToolManagerReplaceMixin,
        // Graph 必须在 Create 之前：Create /relations 复用 _handleCreateRelation。
        _AiToolManagerGraphMixin,
        _AiToolManagerCrossWorkMixin,
        _AiToolManagerCreateMixin,
        _AiToolManagerRemoveMixin,
        _AiToolManagerTodoMixin,
        _AiToolManagerSuggestNextActionMixin
    implements AgentToolDispatcher, McpRunCommandHost {
  AiToolManager(
    this._primaryContentService, {
    required this.workingOverlayService,
    AiNovelReader? novelReader,
    this.crossWorkAccess,
    this.providerReader,
    this.novelWriter,
    this.novelDraftClearer,
    this.onToolCallRequested,
    this.onToolStarted,
    this.onToolFinished,
    this.shouldExecuteTool,
    this.imageGenerationCallback,
    this.imageEditCallback,
    AiCreateLocationCallback? createLocationCallback,
    this.subAgentListProvider,
    this.sessionModeNotifier,
    this.askUserCallback,
    this.suggestNextActionCallback,
    this.skillLoader,
    this.skillNamesProvider,
    this.agentSkillsCommandCallback,
    this.themesCommandCallback,
    this.subagentsCommandCallback,
    this.sessionsCommandCallback,
    this.operationHost,
    this.productionStyleServiceBuilder,

    this.sessionId,
    this.notifyCallback,
    this.canvasActivityReporter,
    this.sourceSessionId,
    this.contentKind = contentKindNovel,
    this.workId,
    this.currentSeasonId,
    this.currentEpisodeId,
  }) : _primaryNovelReader = novelReader {
    _validateResourceDefinitions(_resourceDefinitions);
    this.createLocationCallback = createLocationCallback;
  }

  @override
  NovelContentService get _contentService =>
      _currentResourceCallContext?.service ?? _primaryContentService;

  @override
  final NovelContentService _primaryContentService;

  @override
  final CrossWorkAccess? crossWorkAccess;

  @override
  final Future<List<AiProvider>> Function()? providerReader;

  @override
  final WorkingOverlayService workingOverlayService;

  @override
  final String? sessionId;

  @override
  String? sourceSessionId;

  @override
  final String contentKind;

  @override
  final String? workId;

  @override
  final String? currentSeasonId;

  @override
  final String? currentEpisodeId;

  @override
  AiNovelReader? get novelReader => _currentResourceCallContext == null
      ? _primaryNovelReader
      : _currentResourceCallContext!.novelReader;

  @override
  final AiNovelReader? _primaryNovelReader;

  @override
  final AiNovelWriter? novelWriter;

  @override
  final AiNovelDraftClearer? novelDraftClearer;

  final AiToolCallRequestedCallback? onToolCallRequested;

  final AiToolEventCallback? onToolStarted;

  final AiToolEventCallback? onToolFinished;
  final AiToolShouldExecuteCallback? shouldExecuteTool;

  @override
  final AiImageGenerationCallback? imageGenerationCallback;

  @override
  final AiImageEditCallback? imageEditCallback;

  final List<SubAgent> Function()? subAgentListProvider;

  /// 按名称异步加载技能完整指令的回调。由外部（通常通过 provider 查库）传入。
  /// 接收 skillName，返回 [AgentSkillLoadResult]；若未找到则返回 null。
  /// 可在初始化后重新赋值以切换当前 agent 的技能上下文。
  @override
  SkillLoaderCallback? skillLoader;
  @override
  SkillNamesProvider? skillNamesProvider;
  @override
  final AiAgentSkillsCommandCallback? agentSkillsCommandCallback;
  @override
  final AiThemesCommandCallback? themesCommandCallback;
  @override
  final AiSubagentsCommandCallback? subagentsCommandCallback;
  @override
  final AiSessionsCommandCallback? sessionsCommandCallback;

  @override
  ToolOperationHost? operationHost;
  @override
  McpRunCommandHandler? mcpRunHandler;
  @override
  bool Function()? mcpAllowed;

  /// 风格查询与选择仅需作品数据，在移动端也可用。
  @override
  Future<ProductionCanvasService> Function()? productionStyleServiceBuilder;
  @override
  @override
  final AiRunNotifyCallback? notifyCallback;

  @override
  final AiCanvasActivityReporter? canvasActivityReporter;
  final ValueNotifier<AiSessionMode>? sessionModeNotifier;
  final AiAskUserCallback? askUserCallback;

  /// 已裁决建议的挂载回调。为 null（宿主未提供导航能力，或用户在设置里关闭）时，
  /// SuggestNextAction 既不注册 dispatch 也不下发 ToolDef。
  @override
  final SuggestNextActionCallback? suggestNextActionCallback;

  /// 工具名 → 直接调用句柄(供 Agent runtime 自行 dispatch)。
  final Map<String, RawToolHandler> _dispatchHandlers = {};

  /// 工具按域分组(供 Council/Theater/Monologue 选只读子集)。
  final Map<AiToolGroup, List<String>> _toolGroups = {};

  /// 取所有已注册工具名(已通过 [registerTools] 注册)。
  @override
  List<String> allToolNames() => _dispatchHandlers.keys.toList();

  /// 取指定 group 集合下的工具名。
  List<String> toolNamesIn(Set<AiToolGroup> groups) {
    final out = <String>[];
    for (final g in groups) {
      final names = _toolGroups[g];
      if (names != null) out.addAll(names);
    }
    return out;
  }

  /// 直接执行已注册的工具(走与 Genkit fn 相同的 _runToolObserved /
  /// _runMutationTool 路径,但不依赖 Genkit auto-exec)。
  ///
  /// Agent.process loop 用这个 API 把工具循环掌控权握在自己手里。
  @override
  Future<Map<String, dynamic>> executeTool({
    required String name,
    required Map<String, dynamic> input,
    String? callId,
    bool emitEvents = true,
    ToolExecutionContext? context,
  }) {
    final handler = _dispatchHandlers[name];
    if (handler == null) {
      return Future.value(
        normalizeToolFailureResult({
          'ok': false,
          'error': 'Unknown tool: $name',
          'error_code': ToolErrorCode.not_found.name,
          'name': name,
        }),
      );
    }
    return runZoned(
      () {
        if (!emitEvents) {
          _suppressedToolEventDepth += 1;
          return handler(input, callId).whenComplete(() {
            _suppressedToolEventDepth -= 1;
          });
        }
        return handler(input, callId);
      },
      zoneValues: {
        _toolExecutionContextZoneKey: context,
        _runCallIdZoneKey: callId,
      },
    ).then(prepareToolResult);
  }

  /// 释放本会话持有的跨作品只读内容库 lease。同步且幂等。
  void dispose() {
    _disposeCrossWork();
  }

  void _registerDispatch(
    String name,
    AiToolGroup group,
    RawToolHandler handler,
  ) {
    _dispatchHandlers[name] = handler;
    _toolGroups.putIfAbsent(group, () => <String>[]).add(name);
  }

  int _callSequence = 0;
  int _suppressedToolEventDepth = 0;

  bool get _shouldEmitToolEvents => _suppressedToolEventDepth == 0;

  void _emitToolCallRequested(
    String callId,
    String toolName,
    Map<String, dynamic> input,
  ) {
    if (_currentToolExecutionContext?.parentToolCallId != null ||
        !_shouldEmitToolEvents) {
      return;
    }
    onToolCallRequested?.call(callId, toolName, input);
  }

  void _emitToolStarted(
    String callId,
    String toolName,
    Map<String, dynamic> input,
    Map<String, dynamic>? extra,
  ) {
    final context = _currentToolExecutionContext;
    if (context?.parentToolCallId != null) {
      context!.lifecycleObserver?.onStarted?.call(extra);
      return;
    }
    if (!_shouldEmitToolEvents) {
      return;
    }
    onToolStarted?.call(callId, toolName, input, extra, null);
  }

  void _emitToolFinished(
    String callId,
    String toolName,
    Map<String, dynamic> input,
    Map<String, dynamic>? result,
    String? errorMessage,
  ) {
    final context = _currentToolExecutionContext;
    if (context?.parentToolCallId != null) {
      context!.lifecycleObserver?.onFinished?.call(result, errorMessage);
      return;
    }
    if (!_shouldEmitToolEvents) {
      return;
    }
    onToolFinished?.call(callId, toolName, input, result, errorMessage);
  }

  String _nextCallId(String toolName, {String? ref}) {
    if (ref != null && ref.isNotEmpty) return ref;
    _callSequence += 1;
    return 'call_${toolName}_${DateTime.now().microsecondsSinceEpoch}_$_callSequence';
  }

  /// Registers all tool dispatch handlers (Genkit-defineTool removed).
  void registerAllTools() {
    for (final definition in _runCommands.values) {
      definition.validate();
    }
    _registerDispatch(
      runToolName,
      AiToolGroup.run,
      (input, callId) => _runToolObserved(
        toolName: runToolName,
        input: input,
        run: () => _handleRun(input),
        ref: callId,
      ),
    );

    _registerDispatch(
      'Read',
      AiToolGroup.read,
      (input, callId) => _runToolObserved(
        toolName: 'Read',
        input: input,
        run: () => _handleCrossWorkRead(input),
        ref: callId,
      ),
    );

    _registerDispatch(
      'Glob',
      AiToolGroup.search,
      (input, callId) => _runToolObserved(
        toolName: 'Glob',
        input: input,
        run: () => _handleCrossWorkGlob(input),
        ref: callId,
      ),
    );

    _registerDispatch(
      'Grep',
      AiToolGroup.search,
      (input, callId) => _runToolObserved(
        toolName: 'Grep',
        input: input,
        run: () => _handleCrossWorkGrep(input),
        ref: callId,
      ),
    );

    _registerDispatch(
      'Create',
      AiToolGroup.create,
      (input, callId) => _runMutationTool(
        toolName: 'Create',
        input: input,
        previewDiff: () async {
          final path = _parseStringArgument(input['path'], trim: true);
          final parsed = parseAiToolPath(path);
          if (parsed._resource?.schema.isSingleton == true &&
              !parsed.hasField) {
            return _previewWrite(input);
          }
          final fields = _parseMapArgument(input['fields']) ?? const {};
          return (
            path,
            null,
            _parseOptionalTextArgument(
              fields['content'] ?? fields['description'] ?? fields['title'],
            ),
          );
        },
        run: () => _handleCrossWorkMutation(
          toolName: 'Create',
          input: input,
          run: (localInput) => _handleCreate(localInput),
        ),
        ref: callId,
      ),
    );

    _registerDispatch(
      'Write',
      AiToolGroup.write,
      (input, callId) => _runMutationTool(
        toolName: 'Write',
        input: input,
        previewDiff: () => _previewWrite(input),
        run: () => _handleCrossWorkMutation(
          toolName: 'Write',
          input: input,
          run: (localInput) => _handleWrite(localInput),
        ),
        ref: callId,
      ),
    );

    _registerDispatch(
      'Remove',
      AiToolGroup.write,
      (input, callId) => _runMutationTool(
        toolName: 'Remove',
        input: input,
        previewDiff: () async {
          final path = _parseStringArgument(input['path'], trim: true);
          return (path, null, null);
        },
        run: () => _handleCrossWorkMutation(
          toolName: 'Remove',
          input: input,
          run: (localInput) => _handleRemove(localInput),
        ),
        ref: callId,
      ),
    );

    _registerDispatch(
      'Edit',
      AiToolGroup.edit,
      (input, callId) => _runMutationTool(
        toolName: 'Edit',
        input: input,
        previewDiff: () => _previewEdit(input),
        run: () => _handleCrossWorkMutation(
          toolName: 'Edit',
          input: input,
          run: (localInput) => _handleEdit(localInput),
        ),
        ref: callId,
      ),
    );

    _registerDispatch(
      'Replace',
      AiToolGroup.edit,
      (input, callId) => _runToolObserved(
        toolName: 'Replace',
        input: input,
        run: () => _handleCrossWorkMutation(
          toolName: 'Replace',
          input: input,
          run: (localInput) => _handleReplace(localInput),
        ),
        ref: callId,
      ),
    );

    _registerDispatch(
      'GraphSearch',
      AiToolGroup.graph,
      (input, callId) => _runToolObserved(
        toolName: 'GraphSearch',
        input: input,
        run: () => _handleCrossWorkGraphSearch(input),
        ref: callId,
      ),
    );

    if (subAgentListProvider != null) {
      _registerDispatch(
        spawnAgentToolName,
        AiToolGroup.subagent,
        (_, _) async => {
          'ok': false,
          'error':
              'SpawnAgent is only available through chat orchestrator dispatcher',
          'error_code': ToolErrorCode.unavailable.name,
        },
      );
      for (final name in [sendAgentMessageToolName, stopAgentToolName]) {
        _registerDispatch(
          name,
          AiToolGroup.subagent,
          (_, _) async => {
            'ok': false,
            'error':
                '$name is only available through chat orchestrator dispatcher',
            'error_code': ToolErrorCode.unavailable.name,
          },
        );
      }
    }

    if (askUserCallback != null) {
      _registerDispatch(
        'AskUser',
        AiToolGroup.askUser,
        (input, callId) => _runAskUserTool(input: input, ref: callId),
      );
    }

    if (suggestNextActionCallback != null) {
      _registerDispatch(
        suggestNextActionToolName,
        AiToolGroup.suggestion,
        (input, callId) => _runSuggestNextActionTool(input: input, ref: callId),
      );
    }

    // Register TodoWrite tool
    _registerDispatch(
      'TodoWrite',
      AiToolGroup.todo,
      (input, callId) => _runToolObserved(
        toolName: 'TodoWrite',
        input: input,
        run: () => _handleTodoWrite(input),
        ref: callId,
      ),
    );

    // Register AgentSkill tool
    if (skillLoader != null) {
      _registerDispatch(
        skillToolName,
        AiToolGroup.skill,
        (input, callId) => _runToolObserved(
          toolName: skillToolName,
          input: input,
          run: () => handleAgentSkillTool(
            input,
            skillLoader,
            availableNames: skillNamesProvider?.call() ?? const <String>[],
          ),
          ref: callId,
        ),
      );
    }
  }

  /// Runs a read-only tool while emitting lifecycle events so the UI can
  /// render progress without gating behind approval.
  Future<Map<String, dynamic>> _runToolObserved({
    required String toolName,
    required Map<String, dynamic> input,
    required Future<Map<String, dynamic>> Function() run,
    String? ref,
  }) async {
    final callId = _nextCallId(toolName, ref: ref);
    _emitToolCallRequested(callId, toolName, input);
    // Yield to the event loop so the UI can render the tool call card
    // before execution starts.
    await Future<void>.delayed(Duration.zero);

    // Mode permission check
    final mode = sessionModeNotifier?.value ?? AiSessionMode.chat;
    if (!mode.canUseTool(toolName)) {
      return _modeDeniedResult(toolName, mode);
    }

    if (_currentToolExecutionContext
                ?.cancellationToken
                ?.isCancellationRequested ==
            true ||
        (shouldExecuteTool != null && !shouldExecuteTool!())) {
      return aiCancelledToolResultPayload();
    }
    _emitToolStarted(callId, toolName, input, null);
    try {
      final result = _withContractHint(
        normalizeToolFailureResult(await run(), input: input),
        input,
      );
      _emitToolFinished(callId, toolName, input, result, null);
      return result;
    } catch (error, stackTrace) {
      _log.error(
        'tool execution failed tool=$toolName callId=$callId '
        'path=${input['path'] ?? ''}',
        error: error,
        stackTrace: stackTrace,
      );
      _emitToolFinished(callId, toolName, input, null, error.toString());
      rethrow;
    }
  }

  /// Runs a mutating tool and records preview metadata so the UI can present
  /// the resulting working change for accept / reject.
  Future<Map<String, dynamic>> _runMutationTool({
    required String toolName,
    required Map<String, dynamic> input,
    required Future<(String? path, String? oldText, String? newText)> Function()
    previewDiff,
    required Future<Map<String, dynamic>> Function() run,
    String? ref,
  }) async {
    final callId = _nextCallId(toolName, ref: ref);
    _emitToolCallRequested(callId, toolName, input);
    // Yield to the event loop so the UI can render the tool call card
    // before execution starts.
    await Future<void>.delayed(Duration.zero);

    // Mode permission check
    final mode = sessionModeNotifier?.value ?? AiSessionMode.chat;
    if (!mode.canUseTool(toolName)) {
      return _modeDeniedResult(toolName, mode);
    }

    if (_currentToolExecutionContext
                ?.cancellationToken
                ?.isCancellationRequested ==
            true ||
        (shouldExecuteTool != null && !shouldExecuteTool!())) {
      return aiCancelledToolResultPayload();
    }
    String? path;
    String? oldText;
    String? newText;
    try {
      final preview = await previewDiff();
      path = preview.$1;
      oldText = preview.$2;
      newText = preview.$3;
    } catch (_) {
      // Preview is best-effort; approval UI will fall back to raw arguments.
    }

    final extra = <String, dynamic>{};
    if (path != null) extra['targetPath'] = path;
    if (oldText != null) extra['diffOldText'] = oldText;
    if (newText != null) extra['diffNewText'] = newText;

    if (_currentToolExecutionContext
                ?.cancellationToken
                ?.isCancellationRequested ==
            true ||
        (shouldExecuteTool != null && !shouldExecuteTool!())) {
      return aiCancelledToolResultPayload();
    }

    _emitToolStarted(callId, toolName, input, extra.isEmpty ? null : extra);

    try {
      final result = _withContractHint(
        normalizeToolFailureResult(await run(), input: input),
        input,
      );
      _emitToolFinished(callId, toolName, input, result, null);
      return result;
    } catch (e) {
      _emitToolFinished(callId, toolName, input, null, e.toString());
      rethrow;
    }
  }

  Map<String, dynamic> _modeDeniedResult(String toolName, AiSessionMode mode) {
    return <String, dynamic>{
      'ok': false,
      'error': tr(
        LocaleKeys.toolNotAllowedFmt,
        namedArgs: {'mode': mode.value, 'tool_name': toolName},
      ),
      'error_code': ToolErrorCode.permission_denied.name,
      'mode': mode.value,
      'tool': toolName,
    };
  }

  /// Runs the AskUser tool by invoking the registered callback.
  Future<Map<String, dynamic>> _runAskUserTool({
    required Map<String, dynamic> input,
    String? ref,
  }) async {
    final callId = _nextCallId('AskUser', ref: ref);
    _emitToolCallRequested(callId, 'AskUser', input);
    await Future<void>.delayed(Duration.zero);

    final mode = sessionModeNotifier?.value ?? AiSessionMode.chat;
    if (!mode.canUseTool('AskUser')) {
      return _modeDeniedResult('AskUser', mode);
    }

    if (shouldExecuteTool != null && !shouldExecuteTool!()) {
      return aiCancelledToolResultPayload();
    }

    _emitToolStarted(callId, 'AskUser', input, null);

    try {
      final AskUserInput parsedInput;
      try {
        parsedInput = AskUserInput.fromJson(input);
      } on FormatException catch (error) {
        final invalid = normalizeToolFailureResult({
          'ok': false,
          'error': error.message,
          'error_code': ToolErrorCode.invalid_argument.name,
          'hint':
              'Pass questions and each options value as JSON arrays. '
              'Example: {"questions":[{"question":"Continue?",'
              '"options":[{"label":"Yes"},{"label":"No"}]}]}',
          'cancelled': false,
        }, input: input);
        _emitToolFinished(callId, 'AskUser', input, invalid, null);
        return invalid;
      }
      if (parsedInput.questions.isEmpty) {
        final empty = normalizeToolFailureResult({
          'ok': false,
          'error': 'AskUser requires at least one question in questions.',
          'error_code': ToolErrorCode.invalid_argument.name,
          'cancelled': false,
        }, input: input);
        _emitToolFinished(callId, 'AskUser', input, empty, null);
        return empty;
      }
      final request = AskUserRequest(
        callId: callId,
        questions: parsedInput.questions,
      );

      final result = await askUserCallback!(request);
      final resultJson = normalizeToolFailureResult(
        result.toJson(),
        input: input,
      );
      _emitToolFinished(callId, 'AskUser', input, resultJson, null);
      return resultJson;
    } catch (error, stackTrace) {
      _log.error(
        'AskUser request failed callId=$callId',
        error: error,
        stackTrace: stackTrace,
      );
      final failed = normalizeToolFailureResult({
        'ok': false,
        'error': 'AskUser could not complete the request.',
        'error_code': ToolErrorCode.internal.name,
        'cancelled': false,
      }, input: input);
      _emitToolFinished(callId, 'AskUser', input, failed, null);
      return failed;
    }
  }

  /// Runs the SuggestNextAction tool.
  ///
  /// 与 [_runAskUserTool] 平行，但**不建 Completer、不 await 用户操作** —— 本工具
  /// 在回合收尾被调用，挂起会让整个 turn 卡死（方案核心原则 6）。
  Future<Map<String, dynamic>> _runSuggestNextActionTool({
    required Map<String, dynamic> input,
    String? ref,
  }) async {
    const toolName = suggestNextActionToolName;
    final callId = _nextCallId(toolName, ref: ref);
    _emitToolCallRequested(callId, toolName, input);
    await Future<void>.delayed(Duration.zero);

    final mode = sessionModeNotifier?.value ?? AiSessionMode.chat;
    if (!mode.canUseTool(toolName)) {
      return _modeDeniedResult(toolName, mode);
    }
    if (shouldExecuteTool != null && !shouldExecuteTool!()) {
      return aiCancelledToolResultPayload();
    }

    _emitToolStarted(callId, toolName, input, null);
    final result = _handleSuggestNextAction(input, callId);
    _emitToolFinished(callId, toolName, input, result, null);
    return result;
  }

  /// Produces a diff preview for a Write call without persisting anything.
  Future<(String? path, String? oldText, String? newText)> _previewWrite(
    Map<String, dynamic> input,
  ) async {
    final parsed = ParsedPath.parse(
      _parseStringArgument(input['path'], trim: true),
      schemaLookup: _getCollectionSchema,
    );
    if ((parsed.isCrossWork &&
            parsed.workId != (crossWorkAccess?.currentWorkId ?? workId)) ||
        parsed.isWorksListing) {
      return (parsed.displayPath, null, null);
    }
    final prepared = await _prepareWrite(parsed, input, forPreview: true);
    if (prepared.error != null) {
      return (parsed.displayPath, null, null);
    }
    if (parsed.collection == 'relations') {
      try {
        final result = await _recordToolRelationChange(
          _contentService,
          parsed,
          prepared.fields!,
          preview: true,
        );
        return (
          parsed.displayPath,
          jsonEncode(
            _relationToJson(
              _relationSummary(result.previous ?? result.relation),
            ),
          ),
          jsonEncode(_relationToJson(_relationSummary(result.relation))),
        );
      } catch (_) {
        return (parsed.displayPath, null, null);
      }
    }
    final matched = parsed._resource!;
    final operation = matched.operation(_ResourceTool.write)!;
    final requirements = [
      ...operation.constraints,
      if (!parsed.hasField)
        for (final field in prepared.fields!.keys)
          ...?matched.schema.fields[field]?.write?.constraints,
    ];
    if (requirements.any(
      (rule) => rule.kind == _ConstraintKind.target_requirement,
    )) {
      final segments = matched.segments;
      final parent = parsed.hasField
          ? parseAiToolPath(segments.take(segments.length - 1).join('/'))
          : parsed;
      final resource = await _readRawResource(parent);
      if (resource.containsKey('error') ||
          _validateTargetRequirements(
                parsed,
                _ResourceTool.write,
                prepared.fields!,
                resource,
              ) !=
              null) {
        return (parsed.displayPath, null, null);
      }
    }
    if (parsed.isRoot || prepared.fields!.length != 1) {
      return (parsed.displayPath, null, null);
    }
    final entry = prepared.fields!.entries.single;
    final field = matched.schema.fields[entry.key];
    if (field?.readPath != true) {
      return (parsed.displayPath, null, null);
    }
    final target = parsed.hasField
        ? parsed
        : parseAiToolPath('${parsed.displayPath}/${entry.key}');
    final result = await _readRawResource(target);
    if (result.containsKey('error')) {
      return (parsed.displayPath, null, null);
    }
    final oldValue = result['value'];
    String previewValue(Object? value) => value is String
        ? value
        : value == null
        ? ''
        : jsonEncode(value);
    return (
      parsed.displayPath,
      previewValue(oldValue),
      previewValue(entry.value),
    );
  }

  /// Produces a diff preview from the same parsed field target used by Edit.
  Future<(String? path, String? oldText, String? newText)> _previewEdit(
    Map<String, dynamic> input,
  ) async {
    final parsed = _parseEditPath(
      _parseStringArgument(input['path'], trim: true),
    );
    if (_prepareEditTarget(parsed) != null ||
        (parsed.isCrossWork &&
            parsed.workId != (crossWorkAccess?.currentWorkId ?? workId)) ||
        parsed.isWorksListing) {
      return (parsed.displayPath, null, null);
    }
    final oldTextArg = _parseTextArgument(input['old_text']);
    final newTextArg = _parseTextArgument(input['new_text']);
    if (parsed.collection == 'relations') {
      try {
        final result = await _editToolRelationValue(
          _contentService,
          parsed,
          oldTextArg,
          newTextArg,
          _parseBoolArgument(input['all']),
          preview: true,
        );
        return (
          parsed.displayPath,
          EntityRelationsService.relationFieldValue(
                result.previous ?? result.relation,
                parsed.field!,
              ) ??
              '',
          EntityRelationsService.relationFieldValue(
                result.relation,
                parsed.field!,
              ) ??
              '',
        );
      } catch (_) {
        return (parsed.displayPath, null, null);
      }
    }
    final fullValue = isCanvasPath(parsed)
        ? await _previewCanvasEditableText(parsed)
        : (await _readResourceString(parsed)).text;
    if (fullValue == null) {
      return (parsed.displayPath, null, null);
    }
    final updated = _replaceExactText(
      fullValue,
      oldTextArg,
      newTextArg,
      path: parsed.displayPath,
      replaceAll: _parseBoolArgument(input['all']),
    );
    if (updated.error != null) {
      return (parsed.displayPath, null, null);
    }
    return (parsed.displayPath, fullValue, updated.value);
  }

  List<ToolDef> buildToolDefs() {
    final defs = <ToolDef>[
      ToolDef(
        name: runToolName,
        outputSchema: _builtinToolOutputSchema(runToolName),
        description: _runDescription,
        inputSchema: _runInputSchema,
      ),
      ToolDef(
        name: 'Read',
        outputSchema: _builtinToolOutputSchema('Read'),
        description: _readDescription,
        inputSchema: _readInputSchema,
      ),
      ToolDef(
        name: 'Glob',
        outputSchema: _builtinToolOutputSchema('Glob'),
        description: _globDescription,
        inputSchema: _globInputSchema,
      ),
      ToolDef(
        name: 'Grep',
        outputSchema: _builtinToolOutputSchema('Grep'),
        description: _grepDescription,
        inputSchema: _grepInputSchema,
      ),
      ToolDef(
        name: 'Create',
        outputSchema: _builtinToolOutputSchema('Create'),
        description: _createDescription,
        inputSchema: _createInputSchema,
      ),
      ToolDef(
        name: 'Write',
        outputSchema: _builtinToolOutputSchema('Write'),
        description: _writeDescription,
        inputSchema: _writeInputSchema,
      ),
      ToolDef(
        name: 'Edit',
        outputSchema: _builtinToolOutputSchema('Edit'),
        description: _editDescription,
        inputSchema: _editInputSchema,
      ),
      ToolDef(
        name: 'Replace',
        outputSchema: _builtinToolOutputSchema('Replace'),
        description: _replaceDescription,
        inputSchema: _replaceInputSchema,
      ),
      ToolDef(
        name: 'Remove',
        outputSchema: _builtinToolOutputSchema('Remove'),
        description: _removeDescription,
        inputSchema: _removeInputSchema,
      ),
      ToolDef(
        name: 'AskUser',
        outputSchema: _builtinToolOutputSchema('AskUser'),
        description: _askUserDescription,
        inputSchema: _askUserInputSchema,
      ),
      ToolDef(
        name: 'SpawnAgent',
        outputSchema: _builtinToolOutputSchema('SpawnAgent'),
        description: _spawnAgentDescription,
        inputSchema: _spawnAgentInputSchema,
      ),
      ToolDef(
        name: sendAgentMessageToolName,
        outputSchema: _builtinToolOutputSchema(sendAgentMessageToolName),
        description: _sendAgentMessageDescription,
        inputSchema: _sendAgentMessageInputSchema,
      ),
      ToolDef(
        name: stopAgentToolName,
        outputSchema: _builtinToolOutputSchema(stopAgentToolName),
        description: _stopAgentDescription,
        inputSchema: _stopAgentInputSchema,
      ),
    ];
    if (skillLoader != null) {
      defs.add(
        ToolDef(
          name: skillToolName,
          outputSchema: _builtinToolOutputSchema(skillToolName),
          description: _skillToolDescription,
          inputSchema: _skillToolInputSchema,
        ),
      );
    }
    // 宿主未提供导航能力，或用户在设置里关闭建议时，工具连 schema 都不下发。
    if (suggestNextActionCallback != null) {
      defs.add(
        ToolDef(
          name: suggestNextActionToolName,
          outputSchema: _builtinToolOutputSchema(suggestNextActionToolName),
          description: _suggestNextActionDescription,
          inputSchema: buildSuggestNextActionInputSchema(),
        ),
      );
    }

    defs.addAll([
      ToolDef(
        name: 'GraphSearch',
        outputSchema: _builtinToolOutputSchema('GraphSearch'),
        description: _graphSearchDescription,
        inputSchema: _graphSearchInputSchema,
      ),
      ToolDef(
        name: 'TodoWrite',
        outputSchema: _builtinToolOutputSchema('TodoWrite'),
        description: _todoWriteDescription,
        inputSchema: _todoWriteInputSchema,
      ),
    ]);
    return defs;
  }

  List<ToolDef>? _toolDefCache;

  @override
  List<ToolDef> allToolDefs() {
    if (_toolDefCache != null) return _toolDefCache!;
    _toolDefCache = buildToolDefs();
    return _toolDefCache!;
  }

  @override
  List<ToolDef> toolDefsForNames(List<String> names) {
    // Tool defs are filtered from the catalog/cache for LLM visibility only.
    // This does not prove executeTool has a dispatch handler; callback-backed
    // tools must still be registered in registerAllTools or intercepted by Agent.
    final all = allToolDefs();
    final byName = {for (final t in all) t.name: t};
    return names.map((n) => byName[n]).whereType<ToolDef>().toList();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static _WritePayloadResult _resolveWritePayload(
    ParsedPath parsed,
    Map<String, dynamic> input,
  ) {
    final fieldsResult = _tryCoerceContentMap(input['fields']);
    if (fieldsResult.error != null ||
        (input.containsKey('fields') && fieldsResult.value == null)) {
      return _WritePayloadResult(
        null,
        _resourceInputEnvelopeError(
          parsed: parsed,
          errorCode: ToolErrorCode.invalid_argument,
          message: fieldsResult.error ?? 'Write.fields must be an object.',
          issues: const [_ResourceInputIssue('invalid_type', field: 'fields')],
        ),
      );
    }
    final fields = Map<String, dynamic>.from(fieldsResult.value ?? const {});
    final targetField =
        parsed.field ??
        (parsed.isResourceListing
            ? parsed._resource!.schema.listingWriteField
            : null);
    if (targetField != null) {
      if (fields.containsKey('value')) {
        final value = fields.remove('value');
        _addResourceInputSource(fields, targetField, value);
      }
      if (input.containsKey('value')) {
        _addResourceInputSource(fields, targetField, input['value']);
      }
    } else if (parsed.collection == 'story_state' &&
        input.containsKey('value')) {
      final value = input['value'];
      if (value is String) {
        _addResourceInputSource(fields, 'content', value);
      } else {
        final shorthand = _tryCoerceContentMap(value);
        if (shorthand.error != null || shorthand.value == null) {
          return _WritePayloadResult(
            null,
            _resourceInputEnvelopeError(
              parsed: parsed,
              errorCode: ToolErrorCode.invalid_argument,
              message:
                  'Write.value must be a string or object for this resource.',
              issues: const [
                _ResourceInputIssue('invalid_type', field: 'value'),
              ],
            ),
          );
        }
        for (final entry in shorthand.value!.entries) {
          _addResourceInputSource(fields, entry.key, entry.value);
        }
      }
    } else if (input.containsKey('value')) {
      return _WritePayloadResult(
        null,
        _resourceInputEnvelopeError(
          parsed: parsed,
          errorCode: ToolErrorCode.invalid_argument,
          message: 'Full-resource Write requires fields.',
          issues: const [_ResourceInputIssue('unknown_field', field: 'value')],
        ),
      );
    }
    for (final entry in input.entries) {
      if (!{'path', 'fields', 'value'}.contains(entry.key)) {
        _addResourceInputSource(fields, entry.key, entry.value);
      }
    }
    return _WritePayloadResult(fields, null);
  }

  static Map<String, dynamic> _structuredWriteError({
    required String path,
    required ToolErrorCode errorCode,
    required String message,
    String operation = 'write',
    List<String>? missingFields,
    List<String>? requiredFields,
    String? hint,
    String? enumField,
  }) {
    final collection = collectionFromToolPath(path);
    final inferredEnumField = inferEnumField(message);
    return {
      'ok': false,
      'error': message,
      'error_code': errorCode.name,
      'path': path,
      'operation': operation,
      'missing_fields': missingFields,
      'required_fields': requiredFields,
      'hint': hint,
      if (collection != null) 'collection': collection,
      if (enumField != null || inferredEnumField != null)
        'enum_field': enumField ?? inferredEnumField,
    };
  }

  static _ReplaceTextResult _replaceExactText(
    String source,
    String oldText,
    String newText, {
    required String path,
    required bool replaceAll,
  }) {
    if (oldText.isEmpty) {
      if (source.isEmpty) {
        return _ReplaceTextResult(
          newText,
          null,
          1,
          changed: newText.isNotEmpty,
        );
      }
      return _ReplaceTextResult(
        null,
        'old_text must not be empty',
        0,
        errorCode: ToolErrorCode.invalid_argument,
        path: path,
      );
    }

    final matchCount = _countExactMatches(source, oldText);
    if (matchCount == 0) {
      final diagnosis = _diagnoseMissingOldText(source, oldText);
      return _ReplaceTextResult(
        null,
        'old_text not found in $path.${diagnosis.reason}',
        0,
        errorCode: ToolErrorCode.failed_precondition,
        rereadSource: true,
        hint: diagnosis.hint,
        path: path,
        diagnostics: {
          'match_reason': diagnosis.kind,
          'source_length': source.length,
          'old_text_length': oldText.length,
          if (diagnosis.divergence != null)
            'divergence_offset': diagnosis.divergence,
        },
      );
    }
    if (!replaceAll && matchCount > 1) {
      return _ReplaceTextResult(
        null,
        'Found $matchCount matches in $path. Use a more precise old_text, or set all=true to replace all exact matches.',
        matchCount,
        errorCode: ToolErrorCode.invalid_argument,
        hint:
            'Include more surrounding text, indentation, or line breaks to make old_text unique.',
        path: path,
      );
    }
    final next = replaceAll
        ? source.replaceAll(oldText, newText)
        : source.replaceFirst(oldText, newText);
    return _ReplaceTextResult(next, null, matchCount, changed: next != source);
  }

  /// Strips "第X章" (chapter number) prefix from a title.
  /// Handles Chinese numerals (一二三...), digits, and flexible spacing.
  /// Examples: "第一章 新的开始" → "新的开始", "第1章-测试" → "测试", "第 一 章　开始" → "开始"
  static String stripChapterTitlePrefix(String title) {
    return title
        .replaceFirst(
          RegExp(r'^第\s*[〇一二三四五六七八九十百千万零\d]+\s*章[\s\-—–_，,、：:。.　]*'),
          '',
        )
        .trim();
  }

  static List<String> _validRelationTypesFor(
    String sourceType,
    String targetType,
  ) => validRelationTypesFor(sourceType, targetType);

  /// GraphSearch 过滤用的合法 relation_type 并集，顺序跟随 [_validRelationTypesFor]。
  static final List<String> _allValidRelationTypes = () {
    final seen = <String>{};
    final ordered = <String>[];
    for (final sourceType in entityTypes) {
      for (final targetType in entityTypes) {
        for (final type in _validRelationTypesFor(sourceType, targetType)) {
          if (seen.add(type)) {
            ordered.add(type);
          }
        }
      }
    }
    return List<String>.unmodifiable(ordered);
  }();

  static Map<String, dynamic> _replaceTextErrorResult(
    _ReplaceTextResult result,
  ) {
    return {
      'error': result.error,
      if (result.errorCode != null) 'error_code': result.errorCode!.name,
      if (result.path != null) 'path': result.path,
      if (result.hint != null) 'hint': result.hint,
      // 诊断只进匿名上报，经 `_metadata` 传递，不发给模型。
      if (result.diagnostics != null)
        '_metadata': {'edit_diagnostics': result.diagnostics},
      if (result.rereadSource && result.path != null)
        'recovery': {
          'tool': 'Read',
          'input': {'path': result.path},
        },
    };
  }

  /// 诊断 old_text 未命中的原因，给模型可执行的下一步。
  ///
  /// 仅做只读比对，不改变匹配语义：逐字符精确匹配仍是唯一的成功条件。
  /// 目的是把"为什么没匹配上"写进错误文本与匿名上报，避免模型盲目重试。
  static ({String reason, String hint, String kind, int? divergence})
  _diagnoseMissingOldText(String source, String oldText) {
    String normalizeBreaks(String value) =>
        value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // 0. 字段是空的。空字段初始化应传空 old_text，不要当成 unknown_field。
    if (source.isEmpty) {
      return (
        reason: ' The field is currently empty.',
        kind: 'empty_source',
        divergence: null,
        hint: 'Pass old_text as an empty string to initialize this field.',
      );
    }

    // 1. 只有换行符风格不同 —— 最常见，且模型自己看不出来。
    if (normalizeBreaks(source).contains(normalizeBreaks(oldText))) {
      return (
        reason:
            ' The text exists but the line endings differ '
            '(the field uses CRLF or mixed line breaks).',
        kind: 'line_endings',
        divergence: null,
        hint:
            'Re-Read this field and copy old_text straight from the returned '
            'value without retyping the line breaks.',
      );
    }

    // 2. 只有首尾空白不同。
    final trimmed = oldText.trim();
    if (trimmed.isNotEmpty && trimmed != oldText && source.contains(trimmed)) {
      return (
        reason:
            ' The text exists but old_text has extra leading or trailing '
            'whitespace.',
        kind: 'outer_whitespace',
        divergence: null,
        hint:
            'Retry with old_text trimmed to exactly the characters present in '
            'the field.',
      );
    }

    // 3. 定位首次分歧点，让模型知道自己是从哪里开始编造的。
    final firstLine = const LineSplitter().convert(oldText).firstOrNull ?? '';
    if (firstLine.isNotEmpty && source.contains(firstLine)) {
      final anchor = source.indexOf(firstLine);
      var matched = 0;
      while (matched < oldText.length &&
          anchor + matched < source.length &&
          source.codeUnitAt(anchor + matched) == oldText.codeUnitAt(matched)) {
        matched += 1;
      }
      return (
        reason:
            ' The first line matches but old_text diverges from the field at '
            'character $matched.',
        kind: 'first_line_diverged',
        divergence: matched,
        hint:
            'Re-Read this field and copy old_text verbatim from that point on; '
            'do not reconstruct it from memory.',
      );
    }

    return (
      reason: '',
      kind: 'no_matching_anchor',
      divergence: null,
      hint:
          'Read this field immediately before retrying, then copy old_text '
          'exactly, including indentation, leading or trailing spaces, and '
          'line breaks.',
    );
  }

  static int _countExactMatches(String source, String pattern) {
    if (pattern.isEmpty) return 0;
    var count = 0;
    var start = 0;
    while (true) {
      final index = source.indexOf(pattern, start);
      if (index == -1) {
        return count;
      }
      count += 1;
      start = index + pattern.length;
    }
  }

  static _ContentMapResult _tryCoerceContentMap(
    Object? raw, {
    String toolName = 'Write',
  }) {
    if (raw == null) {
      return const _ContentMapResult(null, null);
    }
    if (raw is Map) {
      return _ContentMapResult(Map<String, dynamic>.from(raw), null);
    }
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return const _ContentMapResult(null, null);
      }
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return _ContentMapResult(Map<String, dynamic>.from(decoded), null);
        }
        return _ContentMapResult(
          null,
          '$toolName.fields must be a JSON object, not a JSON array or primitive',
        );
      } catch (_) {
        // 严格解析失败 —— 常见成因是模型输出带 markdown 围栏、尾逗号或单引号。
        // 走 repair 兜底；只接受非空 object，避免把被截断的正文修成残缺 fields
        // 后静默写库。
        final repaired = tryExtractJson(trimmed);
        if (repaired is Map && repaired.isNotEmpty) {
          return _ContentMapResult(Map<String, dynamic>.from(repaired), null);
        }
        return _ContentMapResult(
          null,
          '$toolName.fields must be a JSON object or a valid JSON object string',
        );
      }
    }
    return _ContentMapResult(
      null,
      '$toolName.fields must be a JSON object, got ${raw.runtimeType}',
    );
  }
}

class _ContentMapResult {
  const _ContentMapResult(this.value, this.error);

  final Map<String, dynamic>? value;
  final String? error;
}

class _WritePayloadResult {
  const _WritePayloadResult(this.fields, this.error);

  final Map<String, dynamic>? fields;
  final Map<String, dynamic>? error;
}

class _ReplaceTextResult {
  const _ReplaceTextResult(
    this.value,
    this.error,
    this.matchCount, {
    this.errorCode,
    this.hint,
    this.path,
    this.diagnostics,
    this.changed = false,
    this.rereadSource = false,
  });

  final String? value;
  final String? error;
  final int matchCount;
  // 替换后与原文不同；Edit 的 edited 据此如实返回，不以调用成功代替。
  final bool changed;
  // old_text 未命中时引导模型重读原文。
  final bool rereadSource;
  final ToolErrorCode? errorCode;
  final String? hint;
  final String? path;
  final Map<String, Object?>? diagnostics;
}
