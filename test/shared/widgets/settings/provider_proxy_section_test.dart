// 职责: 验证 AI 供应商代理设置在桌面与移动尺寸下的格式校验，以及不合法时不写回配置。
// 关联文件:
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/widgets/settings/proxy_settings_section.dart
//   lib/shared/models/network_proxy.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/components/reveric_text_field.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/provider_config_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _openai = aiProviderBuiltinById('openai')!;

class _Settings extends AppSettingsNotifier {
  final saved = <AiProvider>[];

  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'en',
    aiSettings: AiSettings(providers: [_openai]),
  );

  @override
  Future<void> setAiProviderConfig(AiProvider config) async =>
      saved.add(config);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  testWidgets('an older save preserves the active IME value and caret', (
    tester,
  ) async {
    final config = ValueNotifier(
      _openai.copyWith(id: 'custom', builtin: false, name: 'Provider'),
    );
    addTearDown(config.dispose);
    final firstWrite = Completer<void>();
    final names = <String>[];
    await tester.pumpWidget(
      _editingForm(config, (next) async {
        names.add(next.name);
        if (names.length == 1) {
          await firstWrite.future;
        }
        config.value = next;
      }),
    );
    await tester.pumpAndSettle();
    final field = find.byType(EditableText).first;
    await tester.enterText(field, 'A');
    await tester.pump();
    expect(names, ['A']);
    const composing = TextEditingValue(
      text: 'A你',
      selection: TextSelection.collapsed(offset: 1),
      composing: TextRange(start: 1, end: 2),
    );
    tester.testTextInput.updateEditingValue(composing);
    firstWrite.complete();
    await tester.pumpAndSettle();
    EditableText editable() => tester.widget<EditableText>(field);
    expect(editable().controller.value, composing);
    expect(editable().focusNode.hasFocus, isTrue);
    expect(names, ['A']);

    final committed = composing.copyWith(composing: TextRange.empty);
    tester.testTextInput.updateEditingValue(committed);
    await tester.pumpAndSettle();
    expect(names, ['A', 'A你']);
    expect(editable().controller.value, committed);
    expect(editable().focusNode.hasFocus, isTrue);
  });

  testWidgets('save failure preserves text and the next edit can save', (
    tester,
  ) async {
    final config = ValueNotifier(
      _openai.copyWith(id: 'custom', builtin: false, name: 'Provider'),
    );
    addTearDown(config.dispose);
    var writes = 0;
    await tester.pumpWidget(
      _editingForm(config, (next) async {
        if (++writes == 1) {
          throw StateError('simulated write failure');
        }
        config.value = next;
      }),
    );
    await tester.pumpAndSettle();
    final field = find.byType(EditableText).first;
    await tester.enterText(field, 'Draft');
    await tester.pumpAndSettle();
    expect(find.text('Save failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.widget<EditableText>(field).controller.text, 'Draft');
    expect(config.value.name, 'Provider');
    await tester.enterText(field, 'Draft updated');
    await tester.pumpAndSettle();
    expect(config.value.name, 'Draft updated');
    expect(writes, 2);
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets(
      '$platform validates the provider proxy before saving it',
      (tester) async {
        await tester.binding.setSurfaceSize(
          Size(platform == TargetPlatform.android ? 375 : 900, 1600),
        );
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final settings = _Settings();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appSettingsProvider.overrideWith(() => settings),
              aiSettingsProvider.overrideWithValue(
                AiSettings(providers: [_openai]),
              ),
            ],
            child: _wrap(ProviderConfigPanel(providerId: _openai.id)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Proxy'));
        await tester.tap(find.text('Proxy'));
        await tester.pumpAndSettle();

        Finder field(String label) => find.descendant(
          of: find.widgetWithText(RevericTextField, label),
          matching: find.byType(EditableText),
        );
        Future<void> enter(String label, String text) async {
          await tester.ensureVisible(field(label));
          await tester.enterText(field(label), text);
          await tester.pumpAndSettle();
        }

        await enter('URL', '127.0.0.1:7890');
        expect(find.textContaining('Enter an http://'), findsOne);
        expect(settings.saved, isEmpty);

        // 代理不合法时编辑其他字段，不能把未通过校验的代理一起写回。
        await enter('API Key', 'sk-test');
        expect(settings.saved.single.apiKey, 'sk-test');
        expect(settings.saved.single.proxyUrl, '');

        await enter('URL', 'socks5://127.0.0.1:1080');
        expect(find.textContaining('Enter an http://'), findsNothing);
        expect(settings.saved.last.proxyUrl, 'socks5://127.0.0.1:1080');

        final count = settings.saved.length;
        await enter('Username', 'us:er');
        expect(find.text('Enter both a username and a password.'), findsOne);
        expect(settings.saved, hasLength(count));

        await enter('Password', 'pa;ss');
        expect(
          find.text('Enter both a username and a password.'),
          findsNothing,
        );
        expect(
          (
            settings.saved.last.proxyUsername,
            settings.saved.last.proxyPassword,
          ),
          ('us:er', 'pa;ss'),
        );

        // HTTP 代理凭据不能含 `:` / `;`，切换后应提示且不保存。
        await enter('URL', 'http://127.0.0.1:7890');
        expect(find.textContaining("can't contain : or ;"), findsOne);
        expect(find.textContaining("can't contain ;."), findsOne);
        expect(settings.saved.last.proxyUrl, 'socks5://127.0.0.1:1080');
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}

Widget _editingForm(
  ValueNotifier<AiProvider> config,
  Future<void> Function(AiProvider) onChanged,
) => ProviderScope(
  child: _wrap(
    ValueListenableBuilder(
      valueListenable: config,
      builder: (context, value, _) => ProviderConfigForm(
        config: value,
        badge: const SizedBox.shrink(),
        headerActions: const [],
        onChanged: onChanged,
      ),
    ),
  ),
);

Widget _wrap(Widget child) => EasyLocalization(
  supportedLocales: const [Locale('en')],
  startLocale: const Locale('en'),
  fallbackLocale: const Locale('en'),
  path: 'assets/translations',
  assetLoader: const MergingAssetLoader(),
  child: Builder(
    builder: (context) => MaterialApp(
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: RevericThemeData.reveric.toThemeData(),
      home: RevericTheme(
        data: RevericThemeData.reveric,
        child: Scaffold(body: child),
      ),
    ),
  ),
);
