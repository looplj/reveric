// 职责: 组装 Reveric 的 A2UI 组件目录 reveric-ui-v1 — 基础目录同名组件沿用官方 Schema，补充自定义组件并绑定 Flutter builder。
// 关联文件:
//   lib/shared/widgets/a2ui/component.dart
//   lib/shared/widgets/a2ui/session.dart
//   lib/shared/widgets/a2ui/components/layout.dart
//   lib/shared/widgets/a2ui/components/button.dart
//   lib/shared/widgets/a2ui/components/text_field.dart

import 'package:a2ui_core/a2ui_core.dart';
import 'package:json_schema_builder/json_schema_builder.dart' show Schema;
import 'package:url_launcher/url_launcher.dart';

import '../../logger/app_logger.dart';
import 'component.dart';
import 'components/button.dart';
import 'components/choice_picker.dart';
import 'components/combo_field.dart';
import 'components/container.dart';
import 'components/display.dart';
import 'components/field_frame.dart';
import 'components/layout.dart';
import 'components/text_field.dart';
import 'components/toggle.dart';

final _log = AppLogger.forModule('A2uiCatalog');

/// 组件目录 ID，即对外 UI 协议名；`createSurface` 未声明 `catalogId` 时由宿主补上。
const String revericA2uiCatalogId = 'reveric-ui-v1';

/// 宿主唯一的组件目录。插件页面和以后 AI 生成的界面共用。
final A2uiCatalog revericA2uiCatalog = _buildCatalog();

const _dynamicString = {r'$ref': r'common_types.json#/$defs/DynamicString'};
const _dynamicBoolean = {r'$ref': r'common_types.json#/$defs/DynamicBoolean'};
const _checkable = {r'$ref': r'common_types.json#/$defs/Checkable'};
const _weight = {
  'type': 'number',
  'description':
      'The relative weight of this component within a Row or Column, like '
      "CSS 'flex-grow'. Only set it on a direct child of a Row or Column.",
};

/// 基础目录中采用的组件，名称与属性和官方 v1.0 基础目录一致。
const _basicBuilders = <String, A2uiComponentBuilder>{
  'Row': buildRow,
  'Column': buildColumn,
  'List': buildList,
  'Card': buildCard,
  'Divider': buildDivider,
  'Text': buildText,
  'Icon': buildIcon,
  'Button': buildButton,
  'TextField': buildTextField,
  'ChoicePicker': buildChoicePicker,
  'CheckBox': buildCheckBox,
};

/// 基础目录没有、由 Reveric 补充的组件。
final _customComponents = <A2uiComponent>[
  A2uiComponent(
    name: 'Gap',
    builder: buildGap,
    schema: Schema.fromMap({
      'type': 'object',
      'description':
          'Fixed empty space between siblings in a Row or Column, on top of '
          'the default spacing.',
      'properties': {
        'component': {'const': 'Gap'},
        'size': {
          'type': 'string',
          'description': 'How much space to add.',
          'enum': ['xs', 'sm', 'md', 'lg', 'xl'],
          'default': 'md',
        },
        'weight': _weight,
      },
      'required': ['component'],
    }),
  ),
  A2uiComponent(
    name: 'Markdown',
    builder: buildMarkdown,
    schema: Schema.fromMap({
      'type': 'object',
      'description':
          'Rich Markdown content: headings, lists, tables, code blocks and '
          'web links. Use Text for short labels and plain sentences.',
      'properties': {
        'component': {'const': 'Markdown'},
        'text': {
          ..._dynamicString,
          'description': 'The Markdown source to render.',
        },
        'weight': _weight,
      },
      'required': ['component', 'text'],
    }),
  ),
  A2uiComponent(
    name: 'Loading',
    builder: buildLoading,
    schema: Schema.fromMap({
      'type': 'object',
      'description':
          'An activity indicator for content that is still loading, with an '
          'optional short label.',
      'properties': {
        'component': {'const': 'Loading'},
        'label': {
          ..._dynamicString,
          'description': 'Short text shown next to the indicator.',
        },
        'weight': _weight,
      },
      'required': ['component'],
    }),
  ),
  A2uiComponent(
    name: 'FieldGroup',
    builder: buildFieldGroup,
    schema: Schema.fromMap({
      'type': 'object',
      'description':
          'Wraps a form field with helper description text placed tightly '
          'below it.',
      'properties': {
        'component': {'const': 'FieldGroup'},
        'child': {
          r'$ref': r'common_types.json#/$defs/Child',
          'description': 'The ID of the wrapped field component.',
        },
        'description': {
          ..._dynamicString,
          'description': 'Helper description shown below the field.',
        },
        'weight': _weight,
      },
      'required': ['component', 'child'],
    }),
  ),
  A2uiComponent(
    name: 'ComboField',
    builder: buildComboField,
    schema: Schema.fromMap({
      'type': 'object',
      'description':
          'An editable text field with a menu of suggested values. The text '
          'itself is the value, including text that is not one of the '
          'suggestions. Use ChoicePicker when the value must be one of the '
          'options.',
      'allOf': [
        _checkable,
        {
          'type': 'object',
          'properties': {
            'component': {'const': 'ComboField'},
            'label': {
              ..._dynamicString,
              'description': 'The text shown above the field.',
            },
            'value': {
              ..._dynamicString,
              'description': 'The current text. This is the saved value.',
            },
            'placeholder': {
              ..._dynamicString,
              'description': 'Text shown when the field is empty.',
            },
            'options': {
              'type': 'array',
              'description':
                  'Suggested values. Selecting one writes its value into the '
                  'field. label is the menu title; value is what gets saved.',
              'minItems': 1,
              'items': {
                'type': 'object',
                'properties': {
                  'value': {'type': 'string'},
                  'label': {'type': 'string'},
                },
                'required': ['value', 'label'],
              },
            },
            'weight': _weight,
          },
          'required': ['component', 'label', 'value', 'options'],
        },
      ],
    }),
  ),
  A2uiComponent(
    name: 'Switch',
    builder: buildSwitch,
    schema: Schema.fromMap({
      'type': 'object',
      'description':
          'An on/off switch with a label, for settings that take effect as a '
          'whole. Use CheckBox for picking items in a list.',
      'allOf': [
        _checkable,
        {
          'type': 'object',
          'properties': {
            'component': {'const': 'Switch'},
            'label': {
              ..._dynamicString,
              'description': 'The text shown before the switch.',
            },
            'value': {
              ..._dynamicBoolean,
              'description': 'Whether the switch is on.',
            },
            'weight': _weight,
          },
          'required': ['component', 'label', 'value'],
        },
      ],
    }),
  ),
];

A2uiCatalog _buildCatalog() {
  final basic = BasicCatalog.v1_0(openUrl: _openWebUrl);
  return A2uiCatalog(
    id: revericA2uiCatalogId,
    protocolVersion: A2uiProtocolVersion.v1_0,
    title: 'Reveric UI',
    instructions:
        'Build the UI from the components below. Layout: Column, Row, List, '
        'Card, Gap, Divider, FieldGroup. Display: Text, Markdown, Icon, Loading. '
        'Input: TextField, ComboField, ChoicePicker, CheckBox, Switch, Button. '
        'A Button child must be a Text, or an Icon for an icon-only button.',
    components: [
      for (final MapEntry(key: name, value: builder) in _basicBuilders.entries)
        A2uiComponent(
          name: name,
          schema: basic.components[name]!.schema,
          builder: builder,
          allowedChildren: name == 'Button' ? const ['Text', 'Icon'] : null,
        ),
      ..._customComponents,
    ],
    functions: [
      for (final function in basic.functions.values)
        _validationRules.contains(function.name)
            ? _RuleMessageFunction(function)
            : function,
    ],
  );
}

/// 基础目录中的校验函数。
const _validationRules = {'required', 'regex', 'length', 'numeric', 'email'};

/// 去掉校验函数自带的英文消息，让界面显示 check 规则里的 `message`
/// （插件或宿主按用户语言撰写）；规则未写 message 时由组件显示本地化的通用提示。
class _RuleMessageFunction extends FunctionImplementation {
  _RuleMessageFunction(this._inner)
    : super(
        name: _inner.name,
        argumentSchema: _inner.argumentSchema,
        returnType: _inner.returnType,
        description: _inner.description,
        allowedCallers: _inner.declaredAllowedCallers,
        requiresUserActivation: _inner.declaredRequiresUserActivation,
        definition: _inner.definition,
      );

  final FunctionImplementation _inner;

  @override
  Object? execute(
    Map<String, dynamic> args,
    DataContext context, [
    CancellationSignal? cancellationSignal,
  ]) {
    final result = _inner.execute(args, context, cancellationSignal);
    return result is ValidationResult
        ? ValidationResult(
            valid: result.valid,
            code: result.code,
            severity: result.severity,
          )
        : result;
  }
}

/// 基础目录的 `openUrl` 只允许打开 HTTP(S) 链接。
Future<void> _openWebUrl(Uri url) async {
  if ((url.scheme != 'http' && url.scheme != 'https') || url.host.isEmpty) {
    throw ArgumentError('Only http(s) URLs can be opened.');
  }
  if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
    _log.warning('openUrl launcher returned false');
  }
}
