// 职责: 表达 MCP 调用执行事实与返回内容，避免业务字段覆盖宿主状态。
// 关联文件:
//   lib/shared/services/mcp/result_adapter.dart
//   lib/shared/services/mcp/tool_dispatcher.dart

import 'dart:convert';
import 'package:mcp_dart/mcp_dart.dart' as sdk;

enum McpExecutionState { not_started, succeeded, failed, unknown }

class McpCallResult {
  McpCallResult({
    required this.executionState,
    List<sdk.Content> content = const [],
    this.structuredContent,
    this.errorCode,
    this.error,
    this.recovery,
    this.cancelled = false,
    this.rejected = false,
  }) : content = List.unmodifiable(content) {
    if (executionState != McpExecutionState.succeeded &&
        (errorCode == null || error == null)) {
      throw ArgumentError('Unsuccessful MCP results require diagnostics');
    }
  }
  final McpExecutionState executionState;
  final List<sdk.Content> content;
  List<String> get text =>
      content.whereType<sdk.TextContent>().map((item) => item.text).toList();
  final Map<String, dynamic>? structuredContent;
  final String? errorCode;
  final String? error;
  final String? recovery;
  final bool cancelled;
  final bool rejected;
  bool get ok => executionState == McpExecutionState.succeeded;

  /// 描述宿主实际交付的结果；服务的 outputSchema 只约束 structuredContent。
  static Map<String, dynamic> outputSchema(Object? structuredSchema) => {
    'type': 'object',
    'properties': {
      'ok': {'type': 'boolean'},
      'executionState': {
        'type': 'string',
        'enum': McpExecutionState.values.map((state) => state.name).toList(),
      },
      'content': {
        'type': 'array',
        'items': {
          'oneOf': [
            {
              'type': 'object',
              'properties': {
                'type': {'const': 'text'},
                'text': {'type': 'string'},
              },
              'required': ['type', 'text'],
            },
            {
              'type': 'object',
              'properties': {
                'type': {'const': 'image'},
                'mimeType': {'type': 'string'},
                'data': {'type': 'string'},
              },
              'required': ['type', 'mimeType', 'data'],
            },
          ],
        },
      },
      'structuredContent': _nestSchema(structuredSchema ?? {'type': 'object'}),
      'error_code': {'type': 'string'},
      'error': {'type': 'string'},
      // 以下字段供宿主内部处理，特意不加入 outputSchema，
      // 不引导模型在 Codemode 脚本中使用或依赖它们。
      // 'recovery': {'type': 'string'},
      // 'cancelled': {'type': 'boolean'},
      // 'rejected': {'type': 'boolean'},
    },
    'required': ['ok', 'executionState', 'content'],
    'additionalProperties': true,
  };

  Map<String, dynamic> toJson({bool includeImageData = true}) => {
    'ok': ok,
    'executionState': executionState.name,
    'content': [
      for (final item in content)
        if (item is sdk.ImageContent)
          {
            'type': 'image',
            'mimeType': item.mimeType,
            if (includeImageData) 'data': item.data,
          }
        else
          item.toJson(),
    ],
    if (structuredContent != null) 'structuredContent': structuredContent,
    if (!ok) 'error_code': errorCode,
    if (!ok) 'error': error,
    if (recovery != null) 'recovery': recovery,
    if (cancelled) 'cancelled': true,
    if (rejected) 'rejected': true,
  };
  factory McpCallResult.fromJson(Map<String, dynamic> json) => McpCallResult(
    executionState: McpExecutionState.values.byName(
      json['executionState'] as String,
    ),
    content: (json['content'] as List)
        .map((item) => sdk.Content.fromJson(item as Map<String, dynamic>))
        .toList(),
    structuredContent: json['structuredContent'] as Map<String, dynamic>?,
    errorCode: json['error_code'] as String?,
    error: json['error'] as String?,
    recovery: json['recovery'] as String?,
    cancelled: json['cancelled'] == true,
    rejected: json['rejected'] == true,
  );
  int get jsonBytes => utf8.encode(jsonEncode(toJson())).length;
  int get textJsonBytes =>
      utf8.encode(jsonEncode(toJson(includeImageData: false))).length;
}

// 嵌入后本地 JSON Pointer 仍须指向服务 schema，不能解析到宿主外层。
// const/default 等包含业务数据；properties/$defs 等的键是名称而非关键字。
Object? _nestSchema(Object? schema) {
  if (schema is List) {
    return schema.map(_nestSchema).toList();
  }
  if (schema is! Map) {
    return schema;
  }
  // 显式 $id 建立独立的引用基址，嵌套不改变它的引用范围。
  if (schema.containsKey(r'$id')) {
    return schema;
  }
  return <String, dynamic>{
    for (final entry in schema.entries)
      entry.key as String: switch (entry.key) {
        r'$ref'
            when entry.value is String &&
                (entry.value == '#' ||
                    (entry.value as String).startsWith('#/')) =>
          '#/properties/structuredContent${(entry.value as String).substring(1)}',
        'const' || 'enum' || 'default' || 'examples' => entry.value,
        'properties' ||
        'patternProperties' ||
        'dependentSchemas' ||
        'dependencies' ||
        r'$defs' ||
        'definitions' when entry.value is Map => <String, dynamic>{
          for (final child in (entry.value as Map).entries)
            child.key as String: _nestSchema(child.value),
        },
        _ => _nestSchema(entry.value),
      },
  };
}
