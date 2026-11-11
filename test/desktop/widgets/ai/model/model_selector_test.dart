// 职责: 测试统一 ModelSelector 的 compact / field 两种形态：闭合态展示、菜单展开、选中与未设置回调、effort flyout 选择
// 关联文件:
//   lib/desktop/widgets/ai/model/model_selector.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/widgets/ai/model/model_selector.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _models = [
  AiModelOption(
    providerId: 'custom',
    providerDisplayName: 'Custom',
    model: 'mimo-v2.5',
    modelDisplayName: 'MiMo V2.5',
    kind: AiModelKind.chat,
  ),
  AiModelOption(
    providerId: 'deepseek',
    providerDisplayName: 'DeepSeek',
    model: 'deepseek-chat',
    kind: AiModelKind.chat,
  ),
];

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets(
    'compact: shows configured display name and selecting fires onSelect',
    (tester) async {
      AiModelOption? picked;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => ModelSelector.compact(
              colors: RevericTheme.colorsOf(context),
              typo: RevericTheme.typographyOf(context),
              modelName: 'MiMo V2.5',
              resolvedId: 'custom::mimo-v2.5',
              availableModels: _models,
              showAddModel: false,
              onSelect: (option) => picked = option,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('MiMo V2.5'), findsOneWidget);
      expect(find.text('mimo-v2.5'), findsNothing);

      await tester.tap(find.text('MiMo V2.5'));
      await tester.pumpAndSettle();

      // 菜单出现：另一 provider 名只在菜单里出现，足以证明菜单已展开。
      expect(find.text('DeepSeek'), findsOneWidget);
      await tester.tap(find.text('deepseek-chat'));
      await tester.pumpAndSettle();

      expect(picked?.id, 'deepseek::deepseek-chat');
    },
  );

  // 配置提供展示名时优先使用；缺失或空白时展示模型 ID。
  test('model display name is used whenever the channel provides one', () {
    const custom = AiModelOption(
      providerId: 'custom',
      providerDisplayName: 'Custom',
      model: 'deepseek-v4-flash',
      modelDisplayName: 'DeepSeek V4 Flash',
      kind: AiModelKind.chat,
    );
    const namedProvider = AiModelOption(
      providerId: 'deepseek',
      providerDisplayName: 'DeepSeek',
      model: 'deepseek-v4-flash',
      modelDisplayName: 'DeepSeek V4 Flash',
      kind: AiModelKind.chat,
    );
    const withoutDisplayName = AiModelOption(
      providerId: 'deepseek',
      providerDisplayName: 'DeepSeek',
      model: 'deepseek-v4-flash',
      kind: AiModelKind.chat,
    );
    const blankDisplayName = AiModelOption(
      providerId: 'deepseek',
      providerDisplayName: 'DeepSeek',
      model: 'deepseek-v4-flash',
      modelDisplayName: '   ',
      kind: AiModelKind.chat,
    );

    expect(custom.displayModelName, 'DeepSeek V4 Flash');
    expect(namedProvider.displayModelName, 'DeepSeek V4 Flash');
    expect(withoutDisplayName.displayModelName, 'deepseek-v4-flash');
    expect(blankDisplayName.displayModelName, 'deepseek-v4-flash');
  });

  testWidgets('field: placeholder when unset, picks a model and an unset row', (
    tester,
  ) async {
    String? changedTo = 'sentinel';
    await tester.pumpWidget(
      _wrap(
        ModelSelector.field(
          availableModels: _models,
          selectedId: null,
          unsetLabel: '跟随上层',
          onChanged: (id) => changedTo = id,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 未选中闭合态显示 unset 文案。
    expect(find.text('跟随上层'), findsOneWidget);

    await tester.tap(find.text('跟随上层'));
    await tester.pumpAndSettle();

    // 选一个真实模型 -> onChanged 拿到它的 id。
    await tester.tap(find.text('deepseek-chat'));
    await tester.pumpAndSettle();
    expect(changedTo, 'deepseek::deepseek-chat');

    // 重新打开并选「未设置」项 -> onChanged 拿到 null。
    await tester.tap(find.byType(ModelSelector));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随上层').last);
    await tester.pumpAndSettle();
    expect(changedTo, isNull);
  });

  testWidgets('field: menu list does not use primary scroll controller', (
    tester,
  ) async {
    final models = List.generate(
      12,
      (index) => AiModelOption(
        providerId: 'provider-$index',
        providerDisplayName: 'Provider $index',
        model: 'model-$index',
        kind: AiModelKind.chat,
      ),
    );

    await tester.pumpWidget(
      _app(
        home: RevericTheme(
          data: RevericThemeData.reveric,
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 420,
                height: 360,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: 260),
                      ModelSelector.field(
                        availableModels: models,
                        selectedId: models.first.id,
                        showAddModel: false,
                        onChanged: (_) {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ModelSelector));
    await tester.pumpAndSettle();

    final menuList = tester.widget<ListView>(find.byType(ListView).last);
    expect(menuList.primary, isFalse);
  });

  testWidgets(
    'field: near bottom of viewport opens upward so models stay on screen',
    (tester) async {
      // 模拟 start_dialog：模型字段贴在可视区底部，向下展开会被窗口裁切。
      final models = List.generate(
        6,
        (index) => AiModelOption(
          providerId: 'provider-$index',
          providerDisplayName: 'Provider $index',
          model: 'model-$index',
          kind: AiModelKind.chat,
        ),
      );

      await tester.binding.setSurfaceSize(const Size(800, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _app(
          home: RevericTheme(
            data: RevericThemeData.reveric,
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: SizedBox(
                    width: 360,
                    child: ModelSelector.field(
                      availableModels: models,
                      selectedId: models.first.id,
                      showAddModel: false,
                      onChanged: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final triggerTop = tester.getTopLeft(find.byType(ModelSelector)).dy;

      await tester.tap(find.byType(ModelSelector));
      await tester.pumpAndSettle();

      // 菜单应翻转到触发器上方：最后一项完全可见且位于触发器之上。
      final lastModel = find.text('model-5');
      expect(lastModel, findsOneWidget);
      final lastRect = tester.getRect(lastModel);
      expect(lastRect.bottom, lessThan(triggerTop));
      expect(lastRect.top, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('field: empty message when no models', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ModelSelector.field(
          availableModels: const [],
          selectedId: null,
          emptyMessage: '暂无可用模型',
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无可用模型'), findsOneWidget);
  });
}

Widget _wrap(Widget child) {
  return _app(
    home: RevericTheme(
      data: RevericThemeData.reveric,
      child: Scaffold(
        body: Center(child: SizedBox(width: 360, child: child)),
      ),
    ),
  );
}

/// 菜单里的搜索框、页脚和 effort 标签都走 i18n，需要真实 EasyLocalization 环境。
Widget _app({required Widget home}) => EasyLocalization(
  supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
  path: 'assets/translations',
  assetLoader: const MergingAssetLoader(),
  startLocale: const Locale('en'),
  fallbackLocale: const Locale('en'),
  saveLocale: false,
  child: Builder(
    builder: (context) => MaterialApp(
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: RevericThemeData.reveric.toThemeData(),
      // 与应用一致：主题包在 Navigator 之上，overlay 菜单里也能取到。
      builder: (context, child) =>
          RevericTheme(data: RevericThemeData.reveric, child: child!),
      home: home,
    ),
  ),
);
