// 职责: 验证插件清单 settings 字段的解析规则与配置值校验。
// 关联文件:
//   lib/shared/models/plugin/setting_field.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/plugin/setting_field.dart';

void main() {
  group('parsePluginSettingFields', () {
    test('parses every field type in declaration order', () {
      final fields = parsePluginSettingFields({
        'apiKey': {'type': 'secret', 'title': 'API Key', 'required': true},
        'maxResults': {
          'type': 'integer',
          'title': '默认结果数量',
          'default': 5,
          'min': 1,
          'max': 20,
        },
        'endpoint': {
          'type': 'string',
          'title': 'Endpoint',
          'maxLength': 200,
          'unknownProp': 1,
        },
        'prompt': {'type': 'text', 'title': 'Prompt'},
        'temperature': {'type': 'number', 'title': 'Temperature', 'max': 2},
        'safe': {'type': 'boolean', 'title': 'Safe', 'default': true},
        'region': {
          'type': 'select',
          'title': 'Region',
          'default': 'cn',
          'options': [
            {'value': 'cn', 'label': '中国'},
            {'value': 'us', 'label': 'US'},
          ],
        },
      });

      expect(fields.map((f) => f.key), [
        'apiKey',
        'maxResults',
        'endpoint',
        'prompt',
        'temperature',
        'safe',
        'region',
      ]);
      expect(fields[0].isSecret, isTrue);
      expect(fields[0].required, isTrue);
      expect(fields[1].defaultValue, 5);
      expect(fields[1].min, 1);
      expect(fields[2].maxLength, 200);
      expect(
        fields[6].options.map((o) => o.label.resolve(const Locale('en'))),
        ['中国', 'US'],
      );
    });

    test('an omitted settings object has no fields', () {
      expect(parsePluginSettingFields(null), isEmpty);
    });

    test('booleans are never required', () {
      final field = parsePluginSettingFields({
        'safe': {'type': 'boolean', 'title': 'Safe', 'required': true},
      }).single;

      expect(field.required, isFalse);
    });

    for (final (name, json) in [
      ('settings is not an object', ['x']),
      (
        'an unknown type',
        {
          'a': {'type': 'color', 'title': 'A'},
        },
      ),
      (
        'a missing title',
        {
          'a': {'type': 'string'},
        },
      ),
      (
        'a key that is not an identifier',
        {
          'a-b': {'type': 'string', 'title': 'A'},
        },
      ),
      (
        'a default of the wrong type',
        {
          'a': {'type': 'integer', 'title': 'A', 'default': '5'},
        },
      ),
      (
        'a default outside the range',
        {
          'a': {'type': 'integer', 'title': 'A', 'default': 50, 'max': 20},
        },
      ),
      (
        'a secret default',
        {
          'a': {'type': 'secret', 'title': 'A', 'default': 'sk'},
        },
      ),
      (
        'fractional integer bounds',
        {
          'a': {'type': 'integer', 'title': 'A', 'min': 0.5},
        },
      ),
      (
        'min greater than max',
        {
          'a': {'type': 'number', 'title': 'A', 'min': 3, 'max': 1},
        },
      ),
      (
        'a select without options',
        {
          'a': {'type': 'select', 'title': 'A', 'options': []},
        },
      ),
      (
        'duplicate option values',
        {
          'a': {
            'type': 'select',
            'title': 'A',
            'options': [
              {'value': 'x', 'label': 'X'},
              {'value': 'x', 'label': 'Y'},
            ],
          },
        },
      ),
      (
        'a known property of the wrong type',
        {
          'a': {'type': 'string', 'title': 'A', 'required': 'yes'},
        },
      ),
    ]) {
      test('rejects $name', () {
        expect(() => parsePluginSettingFields(json), throwsFormatException);
      });
    }
  });

  group('validatePluginSettingValue', () {
    final fields = {
      for (final field in parsePluginSettingFields({
        'name': {
          'type': 'string',
          'title': 'Name',
          'required': true,
          'maxLength': 3,
        },
        'count': {'type': 'integer', 'title': 'Count', 'min': 1, 'max': 5},
        'ratio': {'type': 'number', 'title': 'Ratio'},
        'region': {
          'type': 'select',
          'title': 'Region',
          'options': [
            {'value': 'cn', 'label': 'CN'},
          ],
        },
      }))
        field.key: field,
    };

    test('accepts valid values and unset optional values', () {
      expect(validatePluginSettingValue(fields['name']!, 'abc'), isNull);
      expect(validatePluginSettingValue(fields['count']!, 3), isNull);
      expect(validatePluginSettingValue(fields['count']!, null), isNull);
      expect(validatePluginSettingValue(fields['ratio']!, 0.5), isNull);
      expect(validatePluginSettingValue(fields['region']!, 'cn'), isNull);
    });

    test('reports each kind of invalid value', () {
      expect(
        validatePluginSettingValue(fields['name']!, ''),
        PluginSettingIssue.missing,
      );
      expect(
        validatePluginSettingValue(fields['name']!, 'abcd'),
        PluginSettingIssue.too_long,
      );
      expect(
        validatePluginSettingValue(fields['count']!, 2.5),
        PluginSettingIssue.not_integer,
      );
      expect(
        validatePluginSettingValue(fields['count']!, 0),
        PluginSettingIssue.below_min,
      );
      expect(
        validatePluginSettingValue(fields['count']!, 6),
        PluginSettingIssue.above_max,
      );
      expect(
        validatePluginSettingValue(fields['ratio']!, 'x'),
        PluginSettingIssue.wrong_type,
      );
      expect(
        validatePluginSettingValue(fields['region']!, 'us'),
        PluginSettingIssue.unknown_option,
      );
    });
  });

  group('model fields', () {
    final field = parsePluginSettingFields({
      'organizeModel': {'type': 'model', 'title': 'Model'},
    }).single;

    test('parse without a default and hold a provider/model pair', () {
      expect(field.type, PluginSettingType.model);
      expect(field.defaultValue, isNull);
      expect(
        validatePluginSettingValue(field, {
          'providerId': 'openai',
          'model': 'gpt-5',
        }),
        isNull,
      );
      expect(validatePluginSettingValue(field, null), isNull);
      expect(pluginModelSelection({'providerId': 'openai', 'model': 'gpt-5'}), (
        providerId: 'openai',
        model: 'gpt-5',
      ));
    });

    test('a manifest cannot pick a default model', () {
      expect(
        () => parsePluginSettingFields({
          'm': {
            'type': 'model',
            'title': 'Model',
            'default': {'providerId': 'openai', 'model': 'gpt-5'},
          },
        }),
        throwsFormatException,
      );
    });

    test('rejects values that are not a complete pair', () {
      for (final value in [
        'openai::gpt-5',
        {'providerId': 'openai'},
        {'providerId': '', 'model': 'gpt-5'},
        {'providerId': 'openai', 'model': 5},
      ]) {
        expect(
          validatePluginSettingValue(field, value),
          PluginSettingIssue.wrong_type,
        );
      }
      final required = parsePluginSettingFields({
        'm': {'type': 'model', 'title': 'Model', 'required': true},
      }).single;
      expect(
        validatePluginSettingValue(required, null),
        PluginSettingIssue.missing,
      );
    });
  });
}
