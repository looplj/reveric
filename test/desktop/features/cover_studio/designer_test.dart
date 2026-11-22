// 职责: 验证封面设计师面板能真正构建 — 作品卡片、外部 controller 与 form 共存、各参数小节渲染、失败文案映射。
// 关联文件:
//   lib/desktop/features/cover_studio/designer.dart
//   lib/desktop/features/cover_studio/canvas.dart
//   lib/shared/providers/cover_studio_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/image/choices.dart';
import 'package:reveric/shared/models/plugin/provider.dart';
import 'package:reveric/shared/models/plugin/provider_registry.dart';
import 'package:reveric/shared/widgets/cover_studio/chips.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/providers/cover_studio_providers.dart';
import 'package:reveric/desktop/features/cover_studio/designer.dart';
import 'package:reveric/shared/components/reveric_text_field.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/cover_prompt_builder.dart';
import 'package:reveric/shared/services/cover_studio_orchestrator.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/studio_image_model_selector.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:reveric/shared/widgets/cover_studio/sections.dart';
import 'package:reveric/shared/widgets/cover_studio/slot_view.dart';
import 'package:reveric/third/form/flutter_hook_form.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  late AppDatabase database;

  setUp(() {
    rootBundle.clear();
    database = AppDatabase.forTest(NativeDatabase.memory());
  });
  tearDown(() => database.close());

  // 同一文件里第二个 testWidgets 重新包一层 EasyLocalization 会拿到空子树，
  // 所以设计师面板的几项断言合并在同一个 test 内连续 pump，不拆多个 testWidgets。
  testWidgets('设计师面板在 332px 宽下能构建、无溢出，只有提示词一个输入框', (tester) async {
    // 332 是 studio_page 里第四列的真实宽度，窄面板才照得出溢出。
    await tester.binding.setSurfaceSize(const Size(332, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final provider = aiProviderBuiltinById(
      'openai',
    )!.copyWith(id: 'cover-ui', type: 'plugin:test.cover');
    pluginProviderModels.replace(
      provider,
      parsePluginProviderModels([
        {
          'kind': 'image',
          'id': 'cover',
          'capabilities': {
            'ratios': ['7:5'],
            'resolutions': ['custom'],
            'complexityLevels': ['fine'],
            'maxReferences': 0,
            'minReferences': 0,
            'unlimitedReferences': false,
            'referenceTransport': 'file',
          },
          'requestDefaults': {'quality': 'studio', 'complexity': 'fine'},
        },
      ]),
    );
    addTearDown(() => pluginProviderModels.remove(provider.id));
    final choices = ImageModelChoices(provider, 'cover');
    await tester.pumpWidget(
      _wrap(
        database: database,
        choices: choices,
        child: const _DesignerHarness(),
      ),
    );
    await tester.pump();

    // 回归点一：给了外部 controller 就不能再给 initialValue，否则
    // TextFormField 断言失败、整个封面工作台白屏。
    // 回归点二：窄面板下任何一行溢出都会在这里变成 FlutterError。
    expect(tester.takeException(), isNull);

    // 作品卡片：书名、署名 · 品类、标签、没封面时说明未设置。
    expect(find.text('南渡记'), findsOneWidget);
    expect(find.text('柳三变 · 历史'), findsOneWidget);
    expect(find.text('明末'), findsOneWidget);
    expect(find.text('No cover'), findsOneWidget);

    final model = find.byType(StudioImageModelSelector);
    expect(model, findsOneWidget);
    final modelBottom = tester.getBottomLeft(model).dy;
    for (final section in [
      CoverQualitySection,
      CoverComplexitySection,
      CoverResolutionSection,
      CoverRatioSection,
    ]) {
      expect(modelBottom, lessThan(tester.getTopLeft(find.byType(section)).dy));
    }

    // 书名与署名不再单列输入框，改提示词是唯一入口。
    for (final label in ['7:5', 'custom', 'studio', 'fine']) {
      final chip = tester.widget<CoverChip>(
        find.widgetWithText(CoverChip, label),
      );
      expect(chip.onTap, isNull);
      expect(chip.selected, isTrue);
    }
    expect(find.text('2K'), findsNothing);
    expect(find.text('Title'), findsNothing);
    expect(find.text('Pen name'), findsNothing);
    expect(find.widgetWithText(TextField, '柳三变'), findsNothing);
    // 默认提示词已填进可编辑框。
    expect(
      find.widgetWithText(
        TextField,
        defaultCoverPrompt(novelTitle: '南渡记', authorName: '柳三变'),
      ),
      findsOneWidget,
    );
    expect(find.byType(RevericTextField), findsOneWidget);
    expect(find.text('Add synopsis'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isNot(contains('作品简介：')),
    );

    await tester.tap(find.text('Add synopsis'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      contains('作品简介：明末江南的一段旧事。'),
    );

    // 书名位置 / 字形气质暂时不做界面入口。
    expect(find.text('Placement'), findsNothing);
    expect(find.text('Lettering'), findsNothing);
    // 额外要求已去掉。
    expect(find.text('Extra Requirements'), findsNothing);

    expect(find.textContaining('Generate 1 schemes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unlisted 88API model edits quality and size independently', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(332, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const modelId = 'gateway-custom-image';
    final provider = aiProviderBuiltinById(
      'api88',
    )!.copyWith(imageModels: [modelId]);
    final choices = ImageModelChoices(provider, modelId);
    await tester.pumpWidget(
      _wrap(
        database: database,
        choices: choices,
        child: const CoverImageParametersSection(novelId: 'novel_test'),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(CoverImageParametersSection)),
    );
    CustomImageParameters readParams() => container
        .read(coverStudioControllerProvider('novel_test'))
        .customImageParameters;

    final model = find.byType(StudioImageModelSelector);
    final qualityHeader = find.byKey(
      const ValueKey('studio_image_quality_section'),
    );
    final sizeHeader = find.byKey(const ValueKey('studio_image_size_section'));
    expect(model, findsOneWidget);
    expect(qualityHeader, findsOneWidget);
    expect(sizeHeader, findsOneWidget);
    expect(
      tester.getBottomLeft(model).dy,
      lessThan(tester.getTopLeft(qualityHeader).dy),
    );
    // 质量预置 low / medium / high，尺寸预置封面常见场景。
    for (final preset in ['low', 'medium', 'high']) {
      expect(
        find.byKey(ValueKey('studio_image_quality_$preset')),
        findsOneWidget,
      );
    }
    for (final sizePreset in [
      '1024x1536',
      '768x1024',
      '1024x1024',
      '1536x1024',
    ]) {
      expect(
        find.byKey(ValueKey('studio_image_size_$sizePreset')),
        findsOneWidget,
      );
    }
    expect(readParams(), defaultCustomImageParameters);

    // 选预置质量，再切自定义就地编辑（不弹 Dialog）。
    await tester.tap(find.byKey(const ValueKey('studio_image_quality_high')));
    await tester.pumpAndSettle();
    expect(readParams(), (quality: 'high', size: null));

    await tester.tap(find.byKey(const ValueKey('studio_image_quality_custom')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    final qualityInput = find.byKey(
      const ValueKey('studio_image_custom_quality_input'),
    );
    expect(qualityInput, findsOneWidget);
    await tester.enterText(qualityInput, 'standard');
    await tester.pump();
    expect(readParams(), (quality: 'standard', size: null));

    // 选预置尺寸后切自定义：预填宽高并横排展示，校验非法值与修正值。
    await tester.tap(find.byKey(const ValueKey('studio_image_size_1024x1536')));
    await tester.pumpAndSettle();
    expect(readParams(), (quality: 'standard', size: '1024x1536'));

    await tester.tap(find.byKey(const ValueKey('studio_image_size_custom')));
    await tester.pumpAndSettle();
    final widthInput = find.byKey(
      const ValueKey('studio_image_custom_width_input'),
    );
    final heightInput = find.byKey(
      const ValueKey('studio_image_custom_height_input'),
    );
    expect(widthInput, findsOneWidget);
    expect(heightInput, findsOneWidget);
    expect(
      tester.getCenter(widthInput).dy,
      moreOrLessEquals(tester.getCenter(heightInput).dy, epsilon: 1),
    );
    expect(tester.widget<TextField>(widthInput).controller?.text, '1024');
    expect(tester.widget<TextField>(heightInput).controller?.text, '1536');

    await tester.enterText(widthInput, '0');
    await tester.enterText(heightInput, '1152');
    await tester.pump();
    expect(find.text('Enter a positive whole number.'), findsOneWidget);

    await tester.enterText(widthInput, '864');
    await tester.pump();
    expect(find.text('Enter a positive whole number.'), findsNothing);
    expect(readParams(), (quality: 'standard', size: '864x1152'));

    // 单独把质量切回默认，不影响已设置的自定义尺寸。
    await tester.tap(
      find.byKey(const ValueKey('studio_image_quality_default')),
    );
    await tester.pumpAndSettle();
    expect(qualityInput, findsNothing);
    expect(readParams(), (quality: null, size: '864x1152'));
    expect(tester.takeException(), isNull);
  });

  group('coverSlotErrorCopy', () {
    test('每类错误各自映射到自己的标题，不落到未知兜底', () {
      final mapped = {
        for (final code in AiImageErrorCode.values)
          code: coverSlotErrorCopy(
            CoverSlotView(
              ordinal: 0,
              status: imageBatchSlotStatusFailed,
              errorCode: code.name,
            ),
          ).$1,
      };

      expect(
        mapped[AiImageErrorCode.moderation],
        LocaleKeys.editorCoverErrorModerationTitle,
      );
      expect(
        mapped[AiImageErrorCode.rate_limit],
        LocaleKeys.editorCoverErrorRateLimitTitle,
      );
      expect(
        mapped[AiImageErrorCode.auth],
        LocaleKeys.editorCoverErrorAuthTitle,
      );
      expect(
        mapped[AiImageErrorCode.size],
        LocaleKeys.editorCoverErrorSizeTitle,
      );
      expect(
        mapped[AiImageErrorCode.param],
        LocaleKeys.editorCoverErrorParamTitle,
      );
      expect(
        mapped[AiImageErrorCode.credit],
        LocaleKeys.editorCoverErrorCreditTitle,
      );
      expect(
        mapped[AiImageErrorCode.model_forbidden],
        LocaleKeys.editorCoverErrorModelForbiddenTitle,
      );
      expect(mapped.values.toSet(), hasLength(AiImageErrorCode.values.length));
    });

    test('作者叫停与认不出的错误分开说', () {
      expect(
        coverSlotErrorCopy(
          const CoverSlotView(
            ordinal: 0,
            status: imageBatchSlotStatusFailed,
            errorCode: coverSlotErrorCanceled,
          ),
        ).$1,
        LocaleKeys.editorCoverErrorCanceledTitle,
      );
      expect(
        coverSlotErrorCopy(
          const CoverSlotView(
            ordinal: 0,
            status: imageBatchSlotStatusFailed,
            errorCode: 'something_new_from_the_gateway',
          ),
        ).$1,
        LocaleKeys.editorCoverErrorUnknownTitle,
      );
    });
  });
}

/// 按 studio_page 的真实用法搭起来：form 不给 initialValues，字段用外部
/// controller。databasePath 传 null 以跳过需要 per-novel content DB 的封面档案。
class _DesignerHarness extends HookWidget {
  const _DesignerHarness();

  @override
  Widget build(BuildContext context) {
    final form = useForm<CoverStudioField>(listen: false);
    final promptController = useTextEditingController(
      text: defaultCoverPrompt(
        novelTitle: _novel.title,
        authorName: _novel.authorName,
      ),
    );

    void appendPrompt(String fragment) {
      final next = appendCoverPromptFragment(promptController.text, fragment);
      if (next == promptController.text) {
        return;
      }
      promptController.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }

    return CoverStudioDesigner(
      novel: _novel,
      databasePath: null,
      libraryAssets: const [],
      form: form,
      promptController: promptController,
      onGenerate: () {},
      onReadBrief: () {},
      onAppendPrompt: appendPrompt,
    );
  }
}

final _novel = Novel(
  id: 'novel_test',
  title: '南渡记',
  authorName: '柳三变',
  description: '明末江南的一段旧事。',
  draft: false,
  category: '历史',
  tags: const ['明末'],
  status: '',
  type: '',
  contentKind: contentKindNovel,
  wordCount: 0,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  deletedAt: notDeletedSentinel,
);

Widget _wrap({
  ImageModelChoices? choices,
  required AppDatabase database,
  required Widget child,
}) {
  return ProviderScope(
    overrides: [
      aiSettingsProvider.overrideWithValue(AiSettings(providers: const [])),
      appDatabaseProvider.overrideWithValue(database),
      if (choices != null) coverImageChoicesProvider.overrideWithValue(choices),
      // 门禁会 watch Reveric 封面模型；测试不接 settings DB，固定为无配置。
      coverStudioImageModelSelectionProvider.overrideWithValue(null),
      appBackgroundActiveProvider.overrideWithValue(false),
    ],
    child: EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      fallbackLocale: const Locale('en'),
      startLocale: const Locale('en'),
      child: Builder(
        builder: (context) {
          return MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(body: child),
            ),
          );
        },
      ),
    ),
  );
}
