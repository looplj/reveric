// 职责: 验证供应商跨平台未知类型展示、桌面菜单与移动端删除确认边界。
// 关联文件:
//   lib/shared/widgets/settings/provider_actions.dart
//   lib/shared/widgets/settings/mobile_provider_list.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/components/reveric_slidable_delete.dart';
import 'package:reveric/shared/components/reveric_switch.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/ai_providers_section.dart';
import 'package:reveric/shared/widgets/settings/mobile_provider_list.dart';
import 'package:reveric/shared/widgets/settings/provider_actions.dart';
import 'package:reveric/shared/widgets/settings/provider_config_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _deepseek = aiProviderBuiltinById('deepseek')!;
final _openai = aiProviderBuiltinById('openai')!;

class _Settings extends AppSettingsNotifier {
  final deleted = <String>[];

  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'en',
    aiSettings: AiSettings(providers: [_openai, _deepseek]),
  );

  @override
  Future<void> removeProvider(String id) async {
    deleted.add(id);
    final current = state.requireValue;
    state = AsyncData(
      current.copyWith(aiSettings: current.aiSettings.removeConfig(id)),
    );
  }
}

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

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  testWidgets(
    'unsupported provider remains visible without editable controls',
    (tester) async {
      final platform = debugDefaultTargetPlatformOverride;
      final isMobile =
          platform == TargetPlatform.android || platform == TargetPlatform.iOS;
      await tester.binding.setSurfaceSize(Size(isMobile ? 375 : 900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final unknown = _deepseek.copyWith(
        id: 'saved-openrouter',
        name: 'OpenRouter',
        type: 'test_xxx',
        enabled: true,
        apiKey: 'secret',
        builtin: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsProvider.overrideWith(_Settings.new),
            aiSettingsProvider.overrideWithValue(
              AiSettings(providers: [unknown]),
            ),
          ],
          child: _wrap(
            Column(
              children: [
                SizedBox(
                  height: 160,
                  child: isMobile
                      ? MobileProviderList(
                          configs: [unknown],

                          selectedId: unknown.id,
                          onSelect: (_) {},
                          onAddCustom: () {},
                        )
                      : ProviderListItem(
                          config: unknown,

                          isSelected: true,
                          onTap: () {},
                        ),
                ),
                Expanded(child: ProviderConfigPanel(providerId: unknown.id)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Unsupported in this version'), findsOneWidget);
      expect(
        find.text('This version does not support provider type test_xxx.'),
        findsOneWidget,
      );
      expect(
        tester.widget<RevericSwitch>(find.byType(RevericSwitch)).onChanged,
        isNull,
      );
      // 移动端列表自带搜索框；这里只验证配置面板没有可编辑项。
      expect(
        find.descendant(
          of: find.byType(ProviderConfigPanel),
          matching: find.byType(EditableText),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'desktop more menu opens delete confirmation and respects cancel',
    (tester) async {
      var deletes = 0;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => ProviderActionsMenu(
              config: _deepseek,
              onDelete: () => confirmDeleteProvider(
                context,
                config: _deepseek,
                onDelete: () async {
                  deletes++;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(deletes, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deletes, 0);
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(deletes, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'mobile detail has no actions menu at tablet width',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _wrap(
          ProviderActionsMenu(
            config: _deepseek,
            onDelete: () => fail('Mobile detail must not delete'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(IconButton), findsNothing);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'mobile swipe confirms deletion and cancel preserves the row',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final settings = _Settings();
      final container = ProviderContainer(
        overrides: [appSettingsProvider.overrideWith(() => settings)],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() => container.read(appSettingsProvider.future));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _wrap(
            Consumer(
              builder: (context, ref, _) {
                final configs = ref
                    .watch(appSettingsProvider)
                    .requireValue
                    .aiSettings
                    .allConfigs;
                return MobileProviderList(
                  configs: configs,

                  selectedId: null,
                  onSelect: (_) {},
                  onAddCustom: () {},
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RevericSlidableDelete), findsNWidgets(2));
      final row = find.byKey(const ValueKey('deepseek'));
      await tester.drag(row, const Offset(-250, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(settings.deleted, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(row, findsOneWidget);
      expect(settings.deleted, isEmpty);
      await tester.drag(row, const Offset(-250, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(settings.deleted, ['deepseek']);
      expect(row, findsNothing);
      expect(find.byKey(const ValueKey('openai')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
