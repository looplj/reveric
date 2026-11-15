// 职责: 显式读取静态资源声明，用作真实工具结果及紧凑文本的测试对照。
// 关联文件:
//   lib/shared/services/ai/tools_schema.dart
//   test/shared/services/ai/tools_schema_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/ai/tools.dart';

/// 只读取声明，不执行工具，也不包装或替换工具返回值。
Map<String, dynamic> resourceContractTreeForTesting(String path) {
  final facts = resourceContractForTesting(path);
  if (facts['subresources'] case final List children) {
    facts['subresources'] = [
      for (final child in children)
        resourceContractTreeForTesting(child['path'] as String),
    ];
  }
  return facts;
}

/// 对实际返回文本断言；facts 仅作为预期数据，不替换 actual。
void expectCompactContractMatchesFacts(Map actual, Map facts) {
  final text = actual['contract'] as String;
  final lines = text.split('\n');
  final path = actual['path'];
  expect(actual, isNot(contains('operation_contracts')));
  expect(actual, isNot(contains('fields')));
  final fields = facts['fields'] as Map;
  for (final entry in fields.entries) {
    final name = entry.key as String;
    final field = entry.value as Map;
    final matcher = RegExp(
      '^  - ${RegExp.escape(name)}'
      r'(\*)?(?:（([^）]*)）)?(?:：|$)',
    );
    final matches = [
      for (final line in lines)
        if (matcher.hasMatch(line)) line,
    ];
    expect(matches, hasLength(1), reason: '$path/$name');
    final row = matches.single;
    final header = matcher.firstMatch(row)!;
    final markers = (header[2] ?? '').split('，');
    final types = markers.where(
      (value) => RegExp(
        r'^(integer|number|boolean|object|array<.*>)$',
      ).hasMatch(value),
    );
    final type = _typeName(field);
    expect(
      types,
      type == 'string' ? isEmpty : equals([type]),
      reason: '$path/$name type',
    );
    final enums = field['enum'] as List? ?? const [];
    if (enums.isNotEmpty) {
      if (enums.every((value) => value is String)) {
        expect(
          markers,
          contains('取值 ${enums.join(' | ')}'),
          reason: '$path/$name enum',
        );
      } else {
        expect(_jsonAfter(row, '取值 '), enums, reason: '$path/$name enum');
      }
    }
    final value = _valueSchema(field);
    if (field['type'] == 'object' || field['type'] == 'array') {
      expect(_jsonAfter(row, '；结构 '), value, reason: '$path/$name structure');
    }
    for (final (key, label) in [
      ('create_value', 'Create结构 '),
      ('write_value', 'Write结构 '),
    ]) {
      if (field[key] case final Map variant) {
        if (!equals(value).matches(variant, {})) {
          if (key == 'write_value' && row.contains('Write结构同Create')) {
            expect(
              _jsonAfter(row, 'Create结构 '),
              variant,
              reason: '$path/$name write variant',
            );
          } else {
            expect(_jsonAfter(row, label), variant, reason: '$path/$name $key');
          }
        }
      }
    }
    if (field['reference_target'] case final String target) {
      expect(
        row.split('；'),
        contains('引用 $target'),
        reason: '$path/$name reference',
      );
    }
    if (field['reference_targets_by_field'] case final Map targets) {
      expect(
        _jsonAfter(row, '引用随字段 '),
        targets,
        reason: '$path/$name references',
      );
    }
  }
  for (final operation in facts['operation_contracts'] as List) {
    final key =
        '${operation['tool']}/${operation['target']}/${operation['field'] ?? ''}';
    if (!(facts['declared_operations'] as List).contains(key)) {
      continue;
    }
    final label = key.endsWith('/') ? key.substring(0, key.length - 1) : key;
    final rows = lines.where(
      (line) => line == '- $label' || line.startsWith('- $label：'),
    );
    expect(rows, hasLength(1), reason: '$path $key');
    final row = rows.single;
    final parameters = operation['parameter_names'] as List;
    if (parameters.isNotEmpty) {
      final actualParameters = Map<String, dynamic>.from(
        _jsonAfter(row, '参数=') as Map,
      );
      expect(
        actualParameters.keys,
        unorderedEquals(parameters),
        reason: '$path $key parameter names',
      );
      for (final name in parameters) {
        final parameter = Map<String, dynamic>.from(
          actualParameters[name] as Map,
        );
        final query = parameter.remove('query');
        expect(
          parameter,
          operation['input']['properties'][name],
          reason: '$path $key $name',
        );
        final queryFacts = facts['query_contracts'][name];
        if (queryFacts != null) {
          expect(
            query,
            '${queryFacts['match']}/${queryFacts['normalization']}',
          );
        }
      }
    }
    if (operation['input']['value'] case final Map value) {
      if (row.contains('value=本字段的Write结构')) {
        final field = fields[operation['field']] as Map;
        expect(
          value,
          field['write_value'] ?? _valueSchema(field),
          reason: '$path $key field input',
        );
      } else if (row.contains('value=array<本表字段>')) {
        final item = value['items'] as Map;
        expect(
          row,
          contains('元素字段=${(item['properties'] as Map).keys.join(',')}；'),
        );
        expect(row, contains('元素必填=${(item['required'] as List).join(',')}；'));
        expect(row, contains('identity=${value['identity']}；'));
        expect(row, contains('额外字段=${item['additional_properties']}'));
        for (final entry in (item['properties'] as Map).entries) {
          final itemValue = _valueSchema(entry.value as Map);
          if (fields[entry.key] == null ||
              !equals(
                _valueSchema(fields[entry.key] as Map),
              ).matches(itemValue, {})) {
            expect(_jsonAfter(row, '元素${entry.key}结构='), itemValue);
          }
        }
      } else {
        expect(_jsonAfter(row, 'value='), value, reason: '$path $key input');
      }
    }
    if (operation['tool'] != 'Read' && operation['result']['value'] != null) {
      expect(
        _jsonAfter(row, '返回结构='),
        operation['result']['value'],
        reason: '$path $key result',
      );
    }
  }
}

String _typeName(Map value) => value['type'] == 'array'
    ? 'array<${_typeName(value['items'] as Map)}>'
    : value['type'] as String;

Map<String, dynamic> _valueSchema(Map field) => {
  for (final key in [
    'type',
    'nullable',
    'enum',
    'pattern',
    'minimum',
    'maximum',
    'min_length',
    'example',
    'properties',
    'required',
    'additional_properties',
    'items',
    'identity',
    'reference_target',
    'reference_targets_by_field',
  ])
    if (field.containsKey(key) && (key != 'nullable' || field[key] == true))
      key: field[key],
};

/// 仅定位 JSON 片段边界，交给标准解码器解析；嵌套括号和字符串转义均保留。
Object? _jsonAfter(String text, String label) {
  final marker = text.indexOf(label);
  expect(marker, greaterThanOrEqualTo(0), reason: 'Missing $label in $text');
  final start = marker + label.length;
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final char = text[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        quoted = false;
      }
    } else if (char == '"') {
      quoted = true;
    } else if (char == '{' || char == '[') {
      depth++;
    } else if (char == '}' || char == ']') {
      depth--;
      if (depth == 0) {
        return jsonDecode(text.substring(start, i + 1));
      }
    }
  }
  fail('Incomplete JSON after $label in $text');
}
