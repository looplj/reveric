// 职责: 验证移动端人物编辑器的分组布局、输入保存边界、名称校验及外部图像刷新。
// 关联文件:
//   lib/mobile/pages/character_editor_page.dart
//   lib/shared/widgets/character/character_profile_section.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/zh-CN/workspace.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/text-input-ime.md

import 'dart:async';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/mobile/pages/character_editor_page.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/character/character_profile_section.dart';
import 'package:reveric/shared/widgets/character_avatar.dart';
import 'package:reveric/shared/widgets/media_asset_image.dart';
import 'package:reveric/shared/widgets/subject_photo_name.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _databasePath = 'mobile_character_editor_test';
const _pastAutoSaveDebounce = Duration(milliseconds: 900);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  late NovelContentDatabase database;
  late NovelContentService service;
  late String characterId;
  late List<Completer<Object?>> pickerRequests;
  late List<String> pickerMethods;
  const pickerChannel = MethodChannel('plugins.flutter.io/image_picker');

  setUp(() async {
    rootBundle.clear();
    pickerRequests = [];
    pickerMethods = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, (call) {
          expect(['pickImage', 'pickMultiImage'], contains(call.method));
          pickerMethods.add(call.method);
          final request = Completer<Object?>();
          pickerRequests.add(request);
          return request.future;
        });
    database = NovelContentDatabase.forTest(NativeDatabase.memory());
    service = NovelContentService(database);
    characterId = await service.createCharacterProfile(
      name: '陈峰',
      aliases: const ['陈先生'],
      personality: '谨慎、自尊心强。',
      behaviorTags: const [
        CharacterBehaviorTag(tag: '嘴硬护短', context: '亲近者受伤时'),
      ],
      description: '左眉有一道浅疤。',
      currentState: '右臂受伤，滞留松江府。',
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, null);
    await database.close();
  });

  Future<void> pumpEditor(WidgetTester tester) async {
    await tester.pumpWidget(
      _wrap(
        ProviderScope(
          overrides: [
            novelContentServiceProvider(
              _databasePath,
            ).overrideWithValue(service),
            editorFontFamilyProvider.overrideWithValue('Georgia'),
            editorFontSizeProvider.overrideWithValue(16),
            editorLetterSpacingProvider.overrideWithValue(0),
            editorLineHeightProvider.overrideWithValue(1.8),
            mediaAssetFileProvider.overrideWith(
              (ref, assetId) => Stream.value(null),
            ),
          ],
          child: MobileCharacterEditorPage(
            novelId: 'work',
            databasePath: _databasePath,
            characterId: characterId,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('generated media refreshes while unsaved text remains intact', (
    tester,
  ) async {
    await pumpEditor(tester);
    final nameField = find.byType(TextField).first;
    await tester.enterText(nameField, '尚未保存的名字');
    await service.updateCharacterAvatarAndPhotos(
      entryId: characterId,
      avatarAssetId: 'generated-avatar',
      photos: const [SubjectPhoto(assetId: 'generated-photo', name: '雨夜')],
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CharacterAvatar>(find.byType(CharacterAvatar).first)
          .avatarAssetId,
      'generated-avatar',
    );
    expect(tester.widget<TextField>(nameField).controller!.text, '尚未保存的名字');
    await tester.scrollUntilVisible(
      find.byType(SubjectPhotoName),
      150,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SubjectPhotoName>(find.byType(SubjectPhotoName))
          .photo
          .assetId,
      'generated-photo',
    );
    await tester.pump(_pastAutoSaveDebounce);
    await tester.pumpAndSettle();
    final saved = (await service.getCharacterProfileById(characterId))!;
    expect(saved.name, '尚未保存的名字');
    expect(saved.avatarAssetId, 'generated-avatar');
    expect(saved.photos!.single.assetId, 'generated-photo');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('avatar picker prevents overlap and recovers after failure', (
    tester,
  ) async {
    await pumpEditor(tester);
    final avatar = find.byKey(const ValueKey('character-avatar-picker'));
    await tester.tap(avatar);
    await tester.tap(avatar);
    await tester.pump();
    final pendingCalls = pickerRequests.length;
    for (final request in pickerRequests) {
      request.complete(null);
    }
    await tester.pumpAndSettle();
    expect(pendingCalls, 1);

    await tester.tap(avatar);
    await tester.pump();
    pickerRequests.last.completeError(
      PlatformException(code: 'already_active'),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.tap(avatar);
    await tester.pump();
    expect(pickerRequests, hasLength(3));
    pickerRequests.last.complete(null);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('photo picker shares the avatar lock and releases it on cancel', (
    tester,
  ) async {
    await pumpEditor(tester);
    final avatarTap = tester
        .widget<GestureDetector>(
          find.byKey(const ValueKey('character-avatar-picker')),
        )
        .onTap!;
    final photo = find.byKey(const ValueKey('character-photo-picker'));
    await tester.scrollUntilVisible(
      photo,
      150,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    final photoTap = tester.widget<InkWell>(photo).onTap!;
    photoTap();
    photoTap();
    avatarTap();
    await tester.pump();
    expect(pickerMethods, ['pickMultiImage']);
    pickerRequests.single.complete(<String>[]);
    await tester.pumpAndSettle();

    avatarTap();
    await tester.pump();
    expect(pickerMethods, ['pickMultiImage', 'pickImage']);
    pickerRequests.last.complete(null);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('avatar picker ignores results after character page disposal', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tester.tap(find.byKey(const ValueKey('character-avatar-picker')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pickerRequests.single.complete('unused-avatar.png');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'relation anchor counts current active rows and updates to ended-only empty',
    (tester) async {
      final other = await service.createCharacterProfile(name: '关系对象');
      final relations = service.entityRelationsService;
      final activeId = await relations.createRelation(
        sourceType: 'character',
        sourceId: characterId,
        targetType: 'character',
        targetId: other,
        relationType: 'friend',
        proof: 'current',
      );
      await relations.createRelation(
        sourceType: 'character',
        sourceId: characterId,
        targetType: 'character',
        targetId: other,
        relationType: 'lover',
        status: 'ended',
        proof: 'past',
      );
      await pumpEditor(tester);
      int? count() => tester
          .widget<CharacterProfileAnchorBar>(
            find.byType(CharacterProfileAnchorBar),
          )
          .counts[CharacterProfileSectionId.relations];
      expect(count(), 1);
      await relations.recordChange(
        id: activeId,
        status: 'ended',
        proof: 'ended',
        reason: 'ended',
      );
      await tester.pumpAndSettle();
      expect(count() ?? 0, 0);
      expect(
        (await relations.getRelationsForEntity(
          entityType: 'character',
          entityId: characterId,
        )),
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'sectioned scroll, narrow layout, CJK save boundary, and name-alias conflict guard',
    (tester) async {
      await pumpEditor(tester);

      // 七个分组同属一条滚动：锚点栏一次列全，第一组内容直接可见。
      expect(find.byType(CharacterProfileAnchorBar), findsOneWidget);
      for (final section in characterProfileSections) {
        expect(
          find.descendant(
            of: find.byType(CharacterProfileAnchorBar),
            matching: find.text(section.titleKey.tr()),
          ),
          findsOneWidget,
          reason: '锚点栏缺少分组 ${section.id}',
        );
      }
      expect(find.text('别名与称号'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final nameField = find.byType(TextField).first;
      await tester.tap(nameField);
      await tester.pump();

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '陈',
          selection: TextSelection.collapsed(offset: 1),
          composing: TextRange(start: 0, end: 1),
        ),
      );
      await tester.pump(_pastAutoSaveDebounce);
      expect((await service.getCharacterProfileById(characterId))!.name, '陈峰');

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '陈锋',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump(_pastAutoSaveDebounce);
      await tester.pumpAndSettle();
      expect((await service.getCharacterProfileById(characterId))!.name, '陈锋');

      // 原来分散在三个 tab 的内容现在都在同一棵树上。
      expect(find.text('行为标签', skipOffstage: false), findsOneWidget);
      expect(find.text('本作首次出场', skipOffstage: false), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 名称字段还连着输入连接、Hero 还在视口内时验证冲突校验：
      // 把名称（当前为「陈锋」）改成与已有别名「陈先生」同名，
      // 防抖保存应被拦下并提示，数据库里的名字保持不变。
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '陈先生',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump(_pastAutoSaveDebounce);
      await tester.pumpAndSettle();
      expect(find.text('名称不能与已有别名重复'), findsOneWidget);
      expect((await service.getCharacterProfileById(characterId))!.name, '陈锋');

      // 改回不冲突的名称后错误消失，保存恢复。
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '陈枫',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump(_pastAutoSaveDebounce);
      await tester.pumpAndSettle();
      expect(find.text('名称不能与已有别名重复'), findsNothing);
      expect((await service.getCharacterProfileById(characterId))!.name, '陈枫');

      // 点末尾锚点把关系网络分组滚进视口，窄屏下不溢出。
      // 锚点栏本身横向可滚，末尾 chip 要先滚进来才能点到。
      final relationsAnchor = find.descendant(
        of: find.byType(CharacterProfileAnchorBar),
        matching: find.text('关系网络'),
      );
      await tester.drag(
        find.byType(CharacterProfileAnchorBar),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      // 页面滚动体：最外层 CustomScrollView 自己的 Scrollable
      // （长文编辑器内部也是 CustomScrollView，不能用 byType 直接取）。
      final pageScroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CustomScrollView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(pageScroll.position.pixels, 0);
      await tester.tap(relationsAnchor);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(pageScroll.position.pixels, greaterThan(0));
      expect(find.text('只读概览 · 编辑请前往关系图'), findsOneWidget);

      // 主动卸载 ProviderScope，并让 Drift stream 的零延迟清理完成，避免把
      // 测试框架的 pending timer 误判成人物编辑器自身的定时器泄漏。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}

Widget _wrap(Widget child) {
  return EasyLocalization(
    supportedLocales: const [Locale('zh', 'CN')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('zh', 'CN'),
    startLocale: const Locale('zh', 'CN'),
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
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 390, height: 360, child: child),
              ),
            ),
          ),
        );
      },
    ),
  );
}
