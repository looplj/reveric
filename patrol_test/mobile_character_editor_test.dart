// 职责: Patrol 移动端人物编辑器 — 验证行为标签新增后的失焦去重与自动保存边界。
// 关联文件:
//   lib/mobile/pages/character_editor_page.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
//   .agents/rules/testing.md

import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/mobile/pages/character_editor_page.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:patrol/patrol.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _databasePath = 'mobile_character_editor_patrol_db';
const _pastAutoSaveDebounce = Duration(milliseconds: 900);

void main() {
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    support = await Directory.systemTemp.createTemp('reveric_patrol_support_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory' ||
              call.method == 'getTemporaryDirectory') {
            return support.path;
          }
          return null;
        });
    await RevericPaths.initialize();
  });

  tearDownAll(() async {
    await AppDatabase.closeCached();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await support.delete(recursive: true);
  });

  patrolTest('rejects a duplicate behavior tag after another tag is added', (
    $,
  ) async {
    // ignore: invalid_use_of_visible_for_testing_member
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    final service = NovelContentService(db);
    final characterId = await service.createCharacterProfile(
      name: '林默',
      behaviorTags: const [
        CharacterBehaviorTag(tag: '先观察', context: '进入陌生环境时'),
      ],
    );

    _setMobileSurface($, const Size(390, 844));
    await $.pumpWidgetAndSettle(
      _MobileCharacterEditorHarness(
        db: db,
        service: service,
        characterId: characterId,
      ),
    );

    // 先新增第二行，确保已有行不会继续持有旧的标签列表快照。
    final addTagField = $(
      const ValueKey('mobile-character-behavior-tag-field'),
    );
    final addContextField = $(
      const ValueKey('mobile-character-behavior-context-field'),
    );
    await $.tester.ensureVisible(addTagField.finder);
    await $.pumpAndSettle();
    await addTagField.enterText('主动站出来');
    await addContextField.enterText('同伴被指责时');
    await $(const ValueKey('mobile-character-behavior-add-button')).tap();
    await $.pumpAndSettle();
    expect(
      $(const ValueKey('mobile-character-behavior-row-tag:1')),
      findsOneWidget,
    );
    await $.tester.pump(_pastAutoSaveDebounce);
    await $.pumpAndSettle();

    final afterAdd = await service.getCharacterProfileById(characterId);
    expect(afterAdd?.behaviorTags, hasLength(2));

    // 编辑第一行后主动失焦，重复错误应保留，数据库也不能丢掉第二行。
    final firstTagField = $(
      const ValueKey('mobile-character-behavior-row-tag:0'),
    );
    final firstContextField = $(
      const ValueKey('mobile-character-behavior-row-context:0'),
    );
    await $.tester.ensureVisible(firstTagField.finder);
    await $.pumpAndSettle();
    // Patrol 的 enterText 会在每次调用后主动释放焦点；用输入法事件保持同一行焦点，
    // 只在两个字段都编辑完成后再失焦，覆盖真实的整行提交路径。
    await $.tester.tap(firstTagField.finder);
    $.tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '主动站出来',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await $.tester.tap(firstContextField.finder);
    $.tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '同伴被指责时',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await $.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await $.pumpAndSettle();

    expect($('相同的行为标签与触发情境已存在'), findsOneWidget);
    await $.tester.pump(_pastAutoSaveDebounce);
    await $.pumpAndSettle();
    final afterDuplicate = await service.getCharacterProfileById(characterId);
    expect(afterDuplicate?.behaviorTags, hasLength(2));
    expect(
      afterDuplicate?.behaviorTags
          .map((tag) => '${tag.tag}|${tag.context}')
          .toList(),
      unorderedEquals(
        afterAdd!.behaviorTags.map((tag) => '${tag.tag}|${tag.context}'),
      ),
    );
    expect($.tester.takeException(), isNull);
  });
}

void _setMobileSurface(PatrolIntegrationTester $, Size size) {
  $.tester.view.devicePixelRatio = 1.0;
  $.tester.view.physicalSize = size;
  addTearDown(() {
    $.tester.view.resetPhysicalSize();
    $.tester.view.resetDevicePixelRatio();
  });
}

class _MobileCharacterEditorHarness extends StatelessWidget {
  const _MobileCharacterEditorHarness({
    required this.db,
    required this.service,
    required this.characterId,
  });

  final NovelContentDatabase db;
  final NovelContentService service;
  final String characterId;

  @override
  Widget build(BuildContext context) {
    return EasyLocalization(
      supportedLocales: const [Locale('zh', 'CN')],
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      fallbackLocale: const Locale('zh', 'CN'),
      startLocale: const Locale('zh', 'CN'),
      child: ProviderScope(
        overrides: [
          novelContentDatabaseProvider(_databasePath).overrideWithValue(db),
          novelContentServiceProvider(_databasePath).overrideWithValue(service),
          editorFontFamilyProvider.overrideWithValue('Georgia'),
          editorFontSizeProvider.overrideWithValue(16),
          editorLetterSpacingProvider.overrideWithValue(0.0),
          editorLineHeightProvider.overrideWithValue(1.8),
        ],
        child: Builder(
          builder: (context) {
            return MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: RevericThemeData.reveric.toThemeData(),
              home: RevericTheme(
                data: RevericThemeData.reveric,
                child: Scaffold(
                  body: MobileCharacterEditorPage(
                    novelId: 'novel-test',
                    databasePath: _databasePath,
                    characterId: characterId,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
