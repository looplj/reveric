// 职责: 验证移动剧本编辑器的单季隐藏、概览选集与手机/平板连续剧本布局。
// 关联文件:
//   lib/mobile/features/screenplay/editor_page.dart
//   lib/mobile/features/screenplay/script_page.dart
//   lib/shared/providers/screenplay_workspace_state_provider.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/mobile/features/screenplay/editor_page.dart';
import 'package:reveric/mobile/features/screenplay/script_page.dart';
import 'package:reveric/shared/widgets/screenplay/document_editor.dart';
import 'package:reveric/mobile/features/screenplay/assistant_bar.dart';
import 'package:reveric/mobile/widgets/characters_panel.dart';
import 'package:reveric/mobile/widgets/compendium_panel.dart';
import 'package:reveric/mobile/widgets/entity_graph_panel.dart';
import 'package:reveric/mobile/widgets/section_chips.dart';
import 'package:reveric/mobile/widgets/workspace_header.dart';
import 'package:reveric/mobile/pages/entry_editor_page.dart';
import 'package:reveric/shared/widgets/story_progress_panel.dart';
import 'package:reveric/shared/widgets/screenplay/character_picker.dart';
import 'package:reveric/shared/widgets/screenplay/backspace_target.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/content_status.dart';
import 'package:reveric/shared/models/novel_type.dart';
import 'package:reveric/shared/models/screenplay_workspace_state.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/screenplay_workspace_state_provider.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  test('groups compendium into a single tab instead of four separate tabs', () {
    expect(
      mobileScreenplaySectionLabelKeys[ScreenplayWorkspaceSection.compendium],
      LocaleKeys.workspaceSidebarCompendium,
    );
    for (final key in const [
      LocaleKeys.workspaceItems,
      LocaleKeys.workspaceFactions,
      LocaleKeys.workspaceCreatures,
      LocaleKeys.workspaceSkills,
    ]) {
      expect(mobileScreenplaySectionLabelKeys.values, isNot(contains(key)));
    }
  });

  testWidgets('adapts season controls and scene editor to available width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final appDb = AppDatabase.forTest(NativeDatabase.memory());
    final contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    final service = ScreenplayService(contentDb, novelId: 'screenplay_mobile');
    final initial = await service.createInitialStructure();
    final root = (await contentDb.screenplayDao.getRoot())!;
    final sceneId = await service.createScene(
      screenplayId: root.id,
      episodeId: initial.episodeId,
      synopsis: 'Opening image',
    );
    const path = 'memory:mobile_screenplay';
    final novel = _screenplay(path);
    addTearDown(() async {
      await contentDb.close();
      await appDb.close();
    });

    await tester.pumpWidget(
      _wrap(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(appDb),
            novelContentDatabaseProvider(path).overrideWithValue(contentDb),
          ],
          child: MobileScreenplayEditorPage(novel: novel),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Season 1'), findsNothing);
    expect(find.text('Episode 1'), findsWidgets);

    await service.createSeason(screenplayId: root.id);
    await tester.pumpAndSettle();
    expect(find.text('Season 1'), findsWidgets);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MobileScreenplayEditorPage)),
    );
    final workspaceProvider = screenplayWorkspaceStateControllerProvider(
      novel.id,
      path,
    );
    await tester.tap(find.text('Keep writing').last);
    expect(
      container.read(workspaceProvider).section,
      ScreenplayWorkspaceSection.script,
    );
    await tester.pumpAndSettle();
    expect(find.byType(ScreenplayDocumentEditor), findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('Action').first).dy,
      lessThan(tester.getBottomLeft(find.byType(ScreenplayDocumentEditor)).dy),
    );
    expect(
      tester.getTopLeft(find.byType(MobileScreenplayAssistantBar)).dy,
      greaterThan(tester.getBottomLeft(find.text('Action').first).dy),
    );
    expect(
      find.descendant(
        of: find.byType(MobileScreenplayAssistantBar),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(900, 900);
    await tester.pumpAndSettle();
    expect(find.byType(ScreenplayDocumentEditor), findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('Action').first).dy,
      lessThan(tester.getBottomLeft(find.byType(ScreenplayDocumentEditor)).dy),
    );
    expect(
      tester.getTopLeft(find.byType(MobileScreenplayAssistantBar)).dy,
      greaterThan(tester.getBottomLeft(find.text('Action').first).dy),
    );
    expect(
      find.descendant(
        of: find.byType(MobileScreenplayAssistantBar),
        matching: find.byType(FilledButton),
      ),
      findsOneWidget,
    );

    await contentDb
        .into(contentDb.characterProfiles)
        .insert(
          CharacterProfilesCompanion.insert(
            id: 'speaker',
            name: 'Mobile Speaker',
          ),
        );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Character').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(ScreenplayCharacterPickerBody),
        matching: find.text('Mobile Speaker'),
      ),
    );
    await tester.pumpAndSettle();
    final dialogueFields = tester
        .widgetList<TextField>(find.byType(TextField))
        .where((field) => field.focusNode?.hasFocus == true)
        .toList();
    expect(dialogueFields, hasLength(1), reason: '选人后直接打开对白输入');
    expect(dialogueFields.single.controller!.text, isEmpty);
    await tester.enterText(
      find.byWidget(dialogueFields.single),
      'Mobile dialogue.',
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    final dialogueRows = await contentDb.screenplayDao.getElementRows(sceneId);
    expect(dialogueRows.map((row) => row.type), ['character', 'dialogue']);
    expect(dialogueRows.last.textContent, 'Mobile dialogue.');
    final footer = find.byType(MobileScreenplayAssistantBar);
    expect(
      find.descendant(
        of: footer,
        matching: find.text('Words 3 · Dialogue words 3'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: footer,
        matching: find.textContaining('Autosaved at'),
      ),
      findsOneWidget,
    );
    final footerRect = tester.getRect(footer);
    final footerSession = tester
        .widget<MobileScreenplayAssistantBar>(footer)
        .session!;
    final savedAt = footerSession.lastSavedAt;
    await service.updateScene(sceneId: sceneId, synopsis: 'Background refresh');
    await tester.pumpAndSettle();
    expect(tester.getRect(footer), footerRect);
    expect(
      tester.widget<MobileScreenplayAssistantBar>(footer).session,
      same(footerSession),
    );
    expect(footerSession.lastSavedAt, savedAt);
    await tester.tap(find.text('Mobile Speaker：'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(ScreenplayCharacterPickerBody),
        matching: find.text('Mobile Speaker'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    final resumedDialogue = tester.widget<TextField>(find.byType(TextField));
    expect(resumedDialogue.focusNode!.hasFocus, isTrue);
    expect(resumedDialogue.controller!.text, 'Mobile dialogue.');
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    final speakerPosition = tester.getTopLeft(find.text('Mobile Speaker：'));
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(find.text('Mobile Speaker：'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Mobile Speaker：')), speakerPosition);
    final characterTarget = find.ancestor(
      of: find.text('Mobile Speaker：'),
      matching: find.byType(ScreenplayBackspaceTarget),
    );
    final caretPaint = find
        .descendant(of: characterTarget, matching: find.byType(CustomPaint))
        .first;
    expect(tester.widget<CustomPaint>(caretPaint).foregroundPainter, isNotNull);
    expect(
      tester.renderObject(caretPaint),
      paints..rect(color: RevericThemeData.reveric.colors.accent),
    );
    expect(find.byType(TextField), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Mobile Speaker：')), speakerPosition);
    expect(tester.widget<CustomPaint>(caretPaint).foregroundPainter, isNotNull);
    expect(
      (await contentDb.screenplayDao.getElementRows(
        sceneId,
      )).map((row) => row.type),
      ['character'],
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Mobile Speaker：'), findsNothing);
    expect(await contentDb.screenplayDao.getElementRows(sceneId), isEmpty);

    await tester.tap(find.text('Action').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'The door opens.');
    // IME preedit must stay in the same field without moving focus.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'The door 中opens.',
        selection: TextSelection.collapsed(offset: 10),
        composing: TextRange(start: 9, end: 10),
      ),
    );
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byType(TextField).first)
          .focusNode!
          .hasFocus,
      isTrue,
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'The door opens.',
        selection: TextSelection.collapsed(offset: 9),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byType(TextField).first)
          .focusNode!
          .hasFocus,
      isTrue,
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'The door \nopens.',
        selection: TextSelection.collapsed(offset: 10),
      ),
    );
    await tester.pumpAndSettle();
    final nextLine = tester
        .widgetList<TextField>(find.byType(TextField))
        .singleWhere((field) => field.focusNode?.hasFocus == true);
    expect(nextLine.controller!.text, 'opens.');
    expect(nextLine.controller!.selection.baseOffset, 0);

    // 等自动保存和数据库回流完成，选区与输入框实例都必须留在新行。
    nextLine.controller!.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(
      (await contentDb.screenplayDao.getElementRows(
        sceneId,
      )).map((row) => row.textContent),
      ['The door ', 'opens.'],
    );
    await tester.pumpAndSettle();
    final savedLine = tester
        .widgetList<TextField>(find.byType(TextField))
        .singleWhere((field) => field.focusNode?.hasFocus == true);
    expect(savedLine.focusNode, same(nextLine.focusNode));
    expect(savedLine.controller!.selection.baseOffset, 3);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    final previousLine = tester.widget<TextField>(find.byType(TextField).first);
    expect(previousLine.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(savedLine.focusNode!.hasFocus, isTrue);

    await tester.tap(find.text('Outline').first);
    await tester.pumpAndSettle();
    expect(
      container.read(workspaceProvider).section,
      ScreenplayWorkspaceSection.outline,
    );
    expect(
      (await contentDb.screenplayDao.getElementRows(
        sceneId,
      )).map((row) => row.textContent).toList(),
      ['The door ', 'opens.'],
    );

    // The added destinations use the same content panels as novels, and
    // changing sections preserves the screenplay's selected episode/scene.
    final before = container.read(workspaceProvider);
    for (final section in [
      ScreenplayWorkspaceSection.characters,
      ScreenplayWorkspaceSection.compendium,
      ScreenplayWorkspaceSection.entity_graph,
      ScreenplayWorkspaceSection.story_progress,
    ]) {
      container
          .read(workspaceProvider.notifier)
          .update(container.read(workspaceProvider).copyWith(section: section));
      await tester.pumpAndSettle();
      switch (section) {
        case ScreenplayWorkspaceSection.characters:
          expect(find.byType(MobileCharactersPanel), findsOneWidget);
        case ScreenplayWorkspaceSection.compendium:
          expect(find.byType(MobileWorkspaceHeader), findsOneWidget);
          expect(find.byType(MobileSectionChips), findsOneWidget);
          expect(find.byType(MobileCompendiumPanel), findsOneWidget);
          // Create action lives in the shared top header (+ icon), not as an
          // extra top text button row above the panel.
          expect(find.text('New Compendium Entry'), findsOneWidget);
          await tester.tap(find.byTooltip('New Compendium Entry'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('New Skill'));
          await tester.pumpAndSettle();
          expect(find.byType(MobileEntryEditorPage), findsOneWidget);
          expect(
            await contentDb.itemDao.getByType(entityTypeSkill),
            hasLength(1),
          );
          await tester.pageBack();
          await tester.pumpAndSettle();
        case ScreenplayWorkspaceSection.entity_graph:
          expect(find.byType(MobileEntityGraphPanel), findsOneWidget);
        case ScreenplayWorkspaceSection.story_progress:
          expect(find.byType(StoryProgressPanel), findsOneWidget);
        default:
          fail('Unexpected destination');
      }
      expect(container.read(workspaceProvider).episodeId, before.episodeId);
      expect(container.read(workspaceProvider).sceneId, before.sceneId);
      expect(tester.takeException(), isNull);
    }
    // Saving must finish before opening AI; a failed save stays in the editor
    // and reports the error instead of opening chat against stale text.
    container
        .read(workspaceProvider.notifier)
        .update(
          container
              .read(workspaceProvider)
              .copyWith(section: ScreenplayWorkspaceSection.script),
        );
    await tester.pumpAndSettle();
    tester
        .widget<MobileScreenplayScriptPage>(
          find.byType(MobileScreenplayScriptPage),
        )
        .registerFlush(
          () async => throw StateError('simulated scene save failure'),
        );
    final assistant = find.descendant(
      of: find.byType(MobileScreenplayAssistantBar),
      matching: find.byType(FilledButton),
    );
    await tester.tap(assistant);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(MobileScreenplayScriptPage), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Novel _screenplay(String path) {
  final now = DateTime(2026);
  return Novel(
    id: 'screenplay_mobile',
    title: 'Mobile Screenplay',
    authorName: '',
    description: '',
    status: contentStatusInProgress,
    type: novelTypeOriginal,
    contentKind: contentKindScreenplay,
    contentDatabasePath: path,
    wordCount: 0,
    draft: false,
    category: '',
    tags: const [],
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

Widget _wrap(Widget child) {
  if (child is ProviderScope) {
    return ProviderScope(overrides: child.overrides, child: _wrap(child.child));
  }
  return EasyLocalization(
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) => RevericTheme(
        data: RevericThemeData.reveric,
        child: MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(),
          home: child,
        ),
      ),
    ),
  );
}
