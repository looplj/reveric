// 职责: 验证插件配置表单的生成、校验、保存提交、凭据不回显与替换／清空流程，以及设置页操作。
// 关联文件:
//   lib/shared/widgets/settings/plugins/config_form.dart
//   lib/shared/widgets/settings/plugins/config_surface.dart
//   lib/shared/models/plugin/setting_field.dart
//   lib/shared/models/plugin/action.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/components/reveric_switch.dart';
import 'package:reveric/shared/components/reveric_text_field.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/plugin/action.dart';
import 'package:reveric/shared/models/plugin/setting_field.dart';
import 'package:reveric/shared/models/plugin/text.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:reveric/shared/widgets/settings/plugins/config_form.dart';
import 'package:reveric/shared/widgets/settings/plugins/config_surface.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child) {
  return EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) {
        return ProviderScope(
          overrides: [appBackgroundActiveProvider.overrideWithValue(false)],
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(
                body: SizedBox(width: 640, height: 900, child: child),
              ),
            ),
          ),
        );
      },
    ),
  );
}

final _fields = parsePluginSettingFields({
  'apiKey': {
    'type': 'secret',
    'title': 'API Key',
    'required': true,
    'description': 'Find it in the dashboard.',
  },
  'proxyToken': {'type': 'secret', 'title': 'Proxy token'},
  'maxResults': {
    'type': 'integer',
    'title': 'Max results',
    'default': 5,
    'min': 1,
    'max': 20,
  },
  'safe': {'type': 'boolean', 'title': 'Safe search', 'default': true},
  'region': {
    'type': 'select',
    'title': 'Region',
    'default': 'cn',
    'options': [
      {'value': 'cn', 'label': 'China'},
      {'value': 'us', 'label': 'United States'},
    ],
  },
});

const _actions = [
  PluginAction(
    name: 'verify',
    title: PluginText({'zh-CN': '验证密钥', 'en': 'Verify key'}),
    requires: ['apiKey'],
  ),
];

Finder _field(String label) => find.descendant(
  of: find.widgetWithText(RevericTextField, label),
  matching: find.byType(TextField),
);

Finder _button(String label) => find.widgetWithText(RevericButton, label);

Future<List<PluginConfigSubmission>> _pump(
  WidgetTester tester, {
  Map<String, Object?> values = const {},
  Set<String> savedSecrets = const {},
  Object? failWith,
  PluginActionRunner? onAction,
  ValueNotifier<bool>? dirty,
}) async {
  final submissions = <PluginConfigSubmission>[];
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    _wrap(
      PluginConfigForm(
        fields: _fields,
        values: values,
        savedSecrets: savedSecrets,
        onSave: (submission) async {
          submissions.add(submission);
          if (failWith != null) {
            throw failWith;
          }
        },
        actions: _actions,
        onAction: onAction,
        dirty: dirty,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return submissions;
}

Future<void> _save(WidgetTester tester) async {
  await tester.ensureVisible(_button('Save'));
  await tester.tap(_button('Save'));
  await tester.pumpAndSettle();
}

String _noLength(int length) => '';
String _noRange(num? min, num? max) => '';
String _noField(String field) => '';
String _noResult(String action, String result) => '';
String _gone(String model) => '$model (gone)';

void main() {
  setUp(() => rootBundle.clear());

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
    testWidgets('renders every field type ($platform)', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await _pump(tester);

        expect(tester.takeException(), isNull);
        expect(_field('API Key'), findsOneWidget);
        expect(_field('Max results'), findsOneWidget);
        expect(find.text('Find it in the dashboard.'), findsOneWidget);
        expect(find.byType(RevericSwitch), findsOneWidget);
        expect(find.text('China'), findsOneWidget);
        expect(
          tester.widget<TextField>(_field('Max results')).controller!.text,
          '5',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('a required secret blocks saving until it is filled', (
    tester,
  ) async {
    final submissions = await _pump(tester);

    expect(tester.widget<RevericButton>(_button('Save')).onPressed, isNull);

    await tester.enterText(_field('API Key'), 'sk-1');
    await tester.pump();
    await _save(tester);

    final submission = submissions.single;
    expect(submission.secrets, {'apiKey': 'sk-1'});
    expect(submission.settings, {
      'maxResults': 5,
      'safe': true,
      'region': 'cn',
    });
    expect(find.text('Saved'), findsOneWidget);
    // 保存后凭据不回显，输入框清空并提示已设置。
    expect(tester.widget<TextField>(_field('API Key')).controller!.text, '');
    expect(find.text('Already set. Leave blank to keep it.'), findsOneWidget);
  });

  testWidgets('a saved secret is kept when left blank', (tester) async {
    final submissions = await _pump(
      tester,
      values: {'maxResults': 8, 'safe': false, 'region': 'us'},
      savedSecrets: {'apiKey'},
    );

    expect(tester.widget<RevericButton>(_button('Save')).onPressed, isNotNull);

    await _save(tester);

    expect(submissions.single.secrets, isEmpty);
    expect(submissions.single.settings, {
      'maxResults': 8,
      'safe': false,
      'region': 'us',
    });
  });

  testWidgets('clearing a saved secret takes effect on save', (tester) async {
    final submissions = await _pump(
      tester,
      savedSecrets: {'apiKey', 'proxyToken'},
    );
    final clearButtons = find.widgetWithText(RevericButton, 'Clear');
    expect(clearButtons, findsNWidgets(2));

    // 清空必填的 API Key 后仍可保存，并提示保存后插件会关闭。
    await tester.tap(clearButtons.first);
    await tester.pumpAndSettle();
    expect(tester.widget<RevericButton>(_button('Save')).onPressed, isNotNull);
    expect(
      find.text(
        'Cleared when you save. The plugin turns off until you add a new one.',
      ),
      findsOneWidget,
    );
    expect(clearButtons, findsOneWidget);

    await tester.tap(clearButtons);
    await tester.pumpAndSettle();
    expect(find.text('Cleared when you save.'), findsOneWidget);
    await _save(tester);

    expect(submissions.single.secrets, {'apiKey': null, 'proxyToken': null});
    expect(find.widgetWithText(RevericButton, 'Clear'), findsNothing);
  });

  testWidgets('typing after clearing replaces the secret', (tester) async {
    final submissions = await _pump(tester, savedSecrets: {'apiKey'});

    await tester.tap(find.widgetWithText(RevericButton, 'Clear'));
    await tester.pumpAndSettle();
    await tester.enterText(_field('API Key'), 'sk-2');
    await tester.pump();
    await _save(tester);

    expect(submissions.single.secrets, {'apiKey': 'sk-2'});
    expect(find.widgetWithText(RevericButton, 'Clear'), findsOneWidget);
  });

  testWidgets('out-of-range numbers show the rule message', (tester) async {
    await _pump(tester, savedSecrets: {'apiKey'});

    await tester.enterText(_field('Max results'), '30');
    await tester.pump();

    expect(find.text('Enter a number from 1 to 20'), findsOneWidget);
    expect(tester.widget<RevericButton>(_button('Save')).onPressed, isNull);

    await tester.enterText(_field('Max results'), '');
    await tester.pump();

    // 可选数字留空表示未设置。
    expect(find.text('Enter a number from 1 to 20'), findsNothing);
    expect(tester.widget<RevericButton>(_button('Save')).onPressed, isNotNull);
  });

  testWidgets('a failed save keeps the input and says so', (tester) async {
    await _pump(tester, failWith: StateError('disk full'));

    await tester.enterText(_field('API Key'), 'sk-1');
    await tester.pump();
    await _save(tester);

    expect(find.text('Save failed'), findsOneWidget);
    expect(find.text('disk full'), findsNothing);
    expect(
      tester.widget<TextField>(_field('API Key')).controller!.text,
      'sk-1',
    );
  });

  testWidgets('an action runs with the unsaved draft and keeps its result', (
    tester,
  ) async {
    final calls = <(String, PluginConfigSubmission)>[];
    await _pump(
      tester,
      onAction: (name, submission) async {
        calls.add((name, submission));
        return (ok: true, code: null);
      },
    );

    expect(
      tester.widget<RevericButton>(_button('Verify key')).onPressed,
      isNull,
    );
    expect(find.byTooltip('Fill in API Key first'), findsOneWidget);

    await tester.enterText(_field('API Key'), 'sk-draft');
    await tester.pump();
    await tester.ensureVisible(_button('Verify key'));
    await tester.tap(_button('Verify key'));
    await tester.pumpAndSettle();

    final (name, submission) = calls.single;
    expect(name, 'verify');
    expect(submission.secrets, {'apiKey': 'sk-draft'});
    expect(submission.settings['maxResults'], 5);
    expect(find.text('Verify key: Succeeded'), findsOneWidget);

    // 修改操作依赖的凭据，结果清除。
    await tester.enterText(_field('API Key'), 'sk-other');
    await tester.pumpAndSettle();
    expect(find.text('Verify key: Succeeded'), findsNothing);
  });

  testWidgets('the result line shows only the latest outcome', (tester) async {
    await _pump(
      tester,
      onAction: (name, submission) async => (ok: true, code: null),
    );

    await tester.enterText(_field('API Key'), 'sk-1');
    await tester.pump();
    await tester.ensureVisible(_button('Verify key'));
    await tester.tap(_button('Verify key'));
    await tester.pumpAndSettle();
    expect(find.text('Verify key: Succeeded'), findsOneWidget);

    // 改动与操作无关的字段不影响结果；保存后结果行换成保存结果。
    await tester.enterText(_field('Max results'), '9');
    await tester.pumpAndSettle();
    expect(find.text('Verify key: Succeeded'), findsOneWidget);
    await _save(tester);
    expect(find.text('Verify key: Succeeded'), findsNothing);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('an action uses the saved secret until it is cleared', (
    tester,
  ) async {
    final calls = <PluginConfigSubmission>[];
    await _pump(
      tester,
      savedSecrets: {'apiKey'},
      onAction: (name, submission) async {
        calls.add(submission);
        return (ok: false, code: 'unauthorized');
      },
    );

    await tester.ensureVisible(_button('Verify key'));
    await tester.tap(_button('Verify key'));
    await tester.pumpAndSettle();
    expect(calls.single.secrets, isEmpty);
    expect(find.text('Verify key: Invalid credentials'), findsOneWidget);

    await tester.tap(find.widgetWithText(RevericButton, 'Clear').first);
    await tester.pumpAndSettle();
    expect(find.text('Verify key: Invalid credentials'), findsNothing);
    expect(
      tester.widget<RevericButton>(_button('Verify key')).onPressed,
      isNull,
    );
  });

  testWidgets('a result for input that changed meanwhile is dropped', (
    tester,
  ) async {
    final pending = Completer<PluginActionResult>();
    await _pump(tester, onAction: (name, submission) => pending.future);

    await tester.enterText(_field('API Key'), 'sk-1');
    await tester.pump();
    await tester.ensureVisible(_button('Verify key'));
    await tester.tap(_button('Verify key'));
    await tester.pump();
    await tester.enterText(_field('API Key'), 'sk-2');
    await tester.pump();
    pending.complete((ok: true, code: null));
    await tester.pumpAndSettle();

    expect(find.text('Verify key: Succeeded'), findsNothing);
    expect(
      tester.widget<RevericButton>(_button('Verify key')).onPressed,
      isNotNull,
    );
  });

  testWidgets('actions are hidden without a runner', (tester) async {
    await _pump(tester);
    expect(_button('Verify key'), findsNothing);
  });

  test('action results map codes to host wording', () {
    const strings = PluginConfigStrings(
      save: '',
      saved: '',
      saveFailed: '',
      clear: '',
      required: '',
      secretSavedHint: '',
      secretClearHint: '',
      requiredSecretClearHint: '',
      invalidInteger: '',
      invalidNumber: '',
      maxLength: _noLength,
      range: _noRange,
      actionSucceeded: 'ok',
      actionUnauthorized: 'auth',
      actionNetwork: 'net',
      actionTimeout: 'slow',
      actionFailed: 'fail',
      actionRequires: _noField,
      actionResult: _noResult,
      modelDefault: '',
      modelUnavailable: _noField,
    );
    expect(pluginActionResultText((ok: true, code: 'x'), strings), 'ok');
    expect(
      [
        for (final code in [
          'unauthorized',
          'network',
          'timeout',
          'other',
          null,
        ])
          pluginActionResultText((ok: false, code: code), strings),
      ],
      ['auth', 'net', 'slow', 'fail', 'fail'],
    );
  });

  test('reading the submission validates against the field rules', () {
    final result = readPluginConfigSubmission(
      fields: _fields,
      data: {
        'settings': {'maxResults': '2.5', 'safe': true, 'region': <String>[]},
        'secrets': {'apiKey': '', 'proxyToken': 'p'},
        'secretCleared': {'apiKey': true},
        'secretSaved': {'apiKey': false},
      },
    );

    // 显式清空的必填凭据不算缺失；从未设置且留空才算。
    expect(result.issues, {'maxResults': PluginSettingIssue.not_integer});
    expect(result.submission.secrets, {'apiKey': null, 'proxyToken': 'p'});
    expect(result.submission.settings['region'], isNull);
    expect(
      readPluginConfigSubmission(
        fields: _fields,
        data: {
          'secrets': {'apiKey': ''},
          'secretSaved': {'apiKey': false},
        },
      ).issues['apiKey'],
      PluginSettingIssue.missing,
    );
  });

  test('model fields offer configured models and keep a removed one', () {
    final fields = parsePluginSettingFields({
      'model': {'type': 'model', 'title': 'Model'},
    });
    const strings = PluginConfigStrings(
      save: '',
      saved: '',
      saveFailed: '',
      clear: '',
      required: '',
      secretSavedHint: '',
      secretClearHint: '',
      requiredSecretClearHint: '',
      invalidInteger: '',
      invalidNumber: '',
      maxLength: _noLength,
      range: _noRange,
      actionSucceeded: '',
      actionUnauthorized: '',
      actionNetwork: '',
      actionTimeout: '',
      actionFailed: '',
      actionRequires: _noField,
      actionResult: _noResult,
      modelDefault: 'Default model',
      modelUnavailable: _gone,
    );
    final messages = buildPluginConfigMessages(
      fields: fields,
      values: {
        'model': {'providerId': 'old', 'model': 'retired'},
      },
      savedSecrets: const {},
      strings: strings,
      locale: const Locale('en'),
      modelOptions: const [
        (
          selection: (providerId: 'openai', model: 'gpt-5'),
          label: 'OpenAI · GPT-5',
        ),
      ],
    );
    final surface = messages.single['createSurface'] as Map<String, Object?>;
    final picker = (surface['components'] as List).cast<Map>().firstWhere(
      (component) => component['id'] == 'field_model',
    );
    expect(
      [for (final option in picker['options'] as List) option['label']],
      ['Default model', 'OpenAI · GPT-5', 'retired (gone)'],
    );

    final data = surface['dataModel'] as Map<String, Object?>;
    final saved = (data['settings'] as Map)['model'] as List;
    expect(
      readPluginConfigSubmission(
        fields: fields,
        data: data,
      ).submission.settings,
      {
        'model': {'providerId': 'old', 'model': 'retired'},
      },
    );
    expect(saved, hasLength(1));
    // 选回「跟随默认」即清空配置。
    expect(
      readPluginConfigSubmission(
        fields: fields,
        data: {
          'settings': {
            'model': [''],
          },
        },
      ).submission.settings,
      {'model': null},
    );
  });

  testWidgets('dirty follows unsaved input and resets after saving', (
    tester,
  ) async {
    final dirty = ValueNotifier(false);
    addTearDown(dirty.dispose);
    await _pump(tester, dirty: dirty);
    expect(dirty.value, false);
    await tester.enterText(_field('Max results'), '7');
    await tester.pumpAndSettle();
    expect(dirty.value, true);
    await tester.enterText(_field('API Key'), 'secret');
    await tester.pumpAndSettle();
    await _save(tester);
    expect(dirty.value, false);
  });

  testWidgets('dirty resets after saving settings without secrets', (
    tester,
  ) async {
    final dirty = ValueNotifier(false);
    addTearDown(dirty.dispose);
    final submissions = await _pump(
      tester,
      savedSecrets: {'apiKey'},
      dirty: dirty,
    );
    await tester.enterText(_field('Max results'), '7');
    await tester.pumpAndSettle();
    expect(dirty.value, true);
    await _save(tester);
    expect(submissions.single.secrets, isEmpty);
    expect(dirty.value, false);
  });
}
