// 职责: 验证移动端人物图像生成的风格校验、取消、保存门禁与聊天接力内容。
// 关联文件:
//   lib/mobile/widgets/character_image_actions.dart
//   lib/mobile/widgets/character_image_style_sheet.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/agent.json
//   assets/translations/zh-CN/agent.json
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:async';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/mobile/pages/agent_model_settings_page.dart';
import 'package:reveric/mobile/pages/novel_chat_page.dart';
import 'package:reveric/mobile/widgets/character_image_actions.dart';
import 'package:reveric/mobile/widgets/character_image_style_sheet.dart';
import 'package:reveric/shared/components/reveric_button.dart';
import 'package:reveric/shared/database/app_database.dart' show Novel;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/character_profile.dart';
import 'package:reveric/shared/models/novel_workspace.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/novel_fixture.dart';

const _path = 'character-image-actions-test';

class _NovelActions extends Fake implements NovelActionsService {
  @override
  Future<Novel?> getNovel(String novelId) async {
    expect(novelId, buildTestNovel().id);
    return buildTestNovel(databasePath: _path);
  }
}

// 记录真实路由参数，在目标页面挂载前返回，隔离聊天运行时和设置页的依赖。
class _DestinationObserver extends NavigatorObserver {
  final destinations = <Widget>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! MaterialPageRoute || previousRoute == null) {
      return;
    }
    final page = route.builder(navigator!.context);
    if (page is MobileNovelChatPage || page is MobileAgentModelSettingsPage) {
      destinations.add(page);
      scheduleMicrotask(() => navigator!.pop());
    }
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  late NovelContentDatabase database;
  late NovelContentService service;
  late String characterId;
  late _DestinationObserver observer;
  late int preparations;

  setUp(() async {
    rootBundle.clear();
    database = NovelContentDatabase.forTest(NativeDatabase.memory());
    service = NovelContentService(database);
    characterId = await service.createCharacterProfile(name: '原名');
    observer = _DestinationObserver();
    preparations = 0;
  });

  tearDown(() async => database.close());

  Future<void> pumpActions(
    WidgetTester tester, {
    bool configured = true,
    bool saved = true,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isImageGenerationConfiguredProvider.overrideWith((ref) => configured),
          novelContentServiceProvider(_path).overrideWithValue(service),
          novelActionsProvider.overrideWithValue(_NovelActions()),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('en'),
          child: Builder(
            builder: (context) => RevericTheme(
              data: RevericThemeData.reveric,
              child: MaterialApp(
                navigatorObservers: [observer],
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: RevericThemeData.reveric.toThemeData().copyWith(
                  platform: TargetPlatform.android,
                ),
                home: Scaffold(
                  body: MobileCharacterImageActions(
                    novelId: buildTestNovel().id,
                    databasePath: _path,
                    characterId: characterId,
                    prepareCharacter: () async {
                      preparations++;
                      if (saved) {
                        final character = (await service
                            .getCharacterProfileById(characterId))!;
                        await service.updateCharacterProfile(
                          entryId: characterId,
                          name: '新名字',
                          role: character.normalizedRole,
                          gender: character.normalizedGender,
                          biography: character.biography,
                          description: character.description,
                        );
                      }
                      return saved;
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'custom avatar style validates and uses saved character context',
    (tester) async {
      await pumpActions(tester);
      await tester.tap(find.byKey(const ValueKey('character-generate-avatar')));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const ValueKey('character-image-confirm'));
      expect(tester.widget<RevericButton>(confirm).onPressed, isNull);
      await tester.tap(find.text(LocaleKeys.agentRoleCustom.tr()));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('character-image-custom-style')),
        '   ',
      );
      await tester.pump();
      expect(tester.widget<RevericButton>(confirm).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('character-image-custom-style')),
        '水墨',
      );
      await tester.enterText(
        find.byKey(const ValueKey('character-image-extra')),
        '黑发，白衣',
      );
      // 窄屏与键盘共同压缩视口，确认按钮仍可见，表单字段保持挂载。
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      final page = observer.destinations.single as MobileNovelChatPage;
      expect(preparations, 1);
      expect(page.databasePath, _path);
      expect(page.novelId, buildTestNovel().id);
      final handoff = page.handoff!;
      expect(handoff.autoSend, isTrue);
      expect(handoff.initialText, handoff.content);
      expect(handoff.content, contains('Avatar portrait:'));
      expect(
        handoff.content,
        contains('command=character，subcommand=generate-avatar'),
      );
      expect(handoff.content, contains('command=help，subcommand=character'));
      expect(handoff.content, contains('新名字'));
      expect(handoff.content, contains('水墨\n\n黑发，白衣'));
      expect(handoff.references.single.itemId, characterId);
      expect(
        handoff.references.single.section,
        NovelWorkspaceSection.characters,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'photo generation references only an existing avatar and supports cancel',
    (tester) async {
      await service.updateCharacterAvatarAndPhotos(
        entryId: characterId,
        avatarAssetId: 'existing-avatar',
      );
      await pumpActions(tester);
      final action = find.byKey(const ValueKey('character-generate-photo'));
      await tester.tap(action);
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byType(MobileCharacterImageStyleSheet)),
      ).pop();
      await tester.pumpAndSettle();
      expect(preparations, 0);
      expect(observer.destinations, isEmpty);
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text(LocaleKeys.editorCoverStyleCinematic.tr()));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('character-image-confirm')));
      await tester.pumpAndSettle();
      final page = observer.destinations.single as MobileNovelChatPage;
      expect(page.handoff!.content, contains('Character photo:'));
      expect(
        page.handoff!.content,
        contains('command=character，subcommand=generate-photo'),
      );
      expect(
        page.handoff!.content,
        contains('options.asset_id 填「existing-avatar」'),
      );
      expect(page.handoff!.content, contains('保持角色形象一致性'));
      expect(page.handoff!.references.single.itemId, characterId);
      await service.updateCharacterAvatarAndPhotos(
        entryId: characterId,
        avatarAssetId: '',
      );
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text(LocaleKeys.editorCoverStyleCinematic.tr()));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('character-image-confirm')));
      await tester.pumpAndSettle();
      final withoutAvatar = observer.destinations.last as MobileNovelChatPage;
      expect(withoutAvatar.handoff!.content, contains('Character photo:'));
      expect(withoutAvatar.handoff!.content, contains('请为角色「新名字」生成照片或插画。'));
      expect(withoutAvatar.handoff!.content, isNot(contains('参考头像')));
      expect(
        withoutAvatar.handoff!.content,
        isNot(contains('options.asset_id')),
      );
      await finish(tester);
    },
  );

  testWidgets(
    'missing image model opens settings without starting generation',
    (tester) async {
      await pumpActions(tester, configured: false);
      await tester.tap(find.byKey(const ValueKey('character-generate-avatar')));
      await tester.pumpAndSettle();
      expect(observer.destinations.single, isA<MobileAgentModelSettingsPage>());
      expect(preparations, 0);
      expect(find.byType(MobileCharacterImageStyleSheet), findsNothing);
      await finish(tester);
    },
  );

  testWidgets('failed save blocks generation and restores actions', (
    tester,
  ) async {
    await pumpActions(tester, saved: false);
    await tester.tap(find.byKey(const ValueKey('character-generate-photo')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(LocaleKeys.editorCoverStyleIllustration.tr()));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('character-image-confirm')));
    await tester.pumpAndSettle();
    expect(observer.destinations, isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      tester
          .widget<RevericButton>(
            find.byKey(const ValueKey('character-generate-photo')),
          )
          .onPressed,
      isNotNull,
    );
    await finish(tester);
  });
}
