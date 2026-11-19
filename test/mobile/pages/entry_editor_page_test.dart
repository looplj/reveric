// 职责: 验证移动条目页的图鉴照片、滚动布局、保存失败反馈、退出冲刷和输入法编辑边界。
// 关联文件:
//   lib/mobile/pages/entry_editor_page.dart
//   lib/mobile/pages/novel_editor_page.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/database/novel_content_database.dart
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/mobile/pages/entry_editor_page.dart';
import 'package:reveric/mobile/pages/novel_editor_page.dart';
import 'package:reveric/mobile/widgets/editor_app_bar.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/widgets/media_asset_image.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/md/reveric_markdown_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(() => rootBundle.clear());

  test('groups compendium while retaining skill editing and progress', () {
    expect(
      mobileNovelEditorSectionLabelKeys,
      contains(LocaleKeys.workspaceSidebarCompendium),
    );
    expect(
      mobileNovelEditorSectionLabelKeys,
      contains(LocaleKeys.workspaceStoryProgress),
    );
    for (final key in [
      LocaleKeys.workspaceItems,
      LocaleKeys.workspaceFactions,
      LocaleKeys.workspaceCreatures,
      LocaleKeys.workspaceSkills,
    ]) {
      expect(mobileNovelEditorSectionLabelKeys, isNot(contains(key)));
    }
    expect(MobileEditorSection.skills.typeValue, entityTypeSkill);
    expect(MobileEditorSection.skills.labelKey, LocaleKeys.workspaceSkills);
    expect(
      MobileEditorSection.skills.newLabelKey,
      LocaleKeys.workspaceNewSkill,
    );
    expect({
      MobileEditorSection.lore.categoryHintKey,
      MobileEditorSection.materials.categoryHintKey,
      MobileEditorSection.skills.categoryHintKey,
      MobileEditorSection.items.categoryHintKey,
      MobileEditorSection.factions.categoryHintKey,
      MobileEditorSection.creatures.categoryHintKey,
    }, hasLength(6));
    expect(
      MobileEditorSection.skills.categoryHintKey,
      LocaleKeys.workspaceEntryCategorySkillsHint,
    );
  });

  for (final section in [
    MobileEditorSection.items,
    MobileEditorSection.creatures,
    MobileEditorSection.factions,
    MobileEditorSection.skills,
  ]) {
    testWidgets(
      '$section shows compendium photos and removes only the reference',
      (tester) async {
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        addTearDown(db.close);
        final service = NovelContentService(db);
        await db
            .into(db.items)
            .insert(
              ItemsCompanion.insert(
                id: 'entry',
                type: section.typeValue,
                title: 'Entry',
                photos: const Value([
                  SubjectPhoto(assetId: 'photo', name: 'Reference'),
                ]),
              ),
            );
        final entries = await db.itemDao.getByType(section.typeValue);
        try {
          await tester.pumpWidget(
            _wrapEditor(
              ProviderScope(
                overrides: [
                  novelContentServiceProvider(
                    'test',
                  ).overrideWithValue(service),
                  itemsProvider(
                    path: 'test',
                    type: section.typeValue,
                  ).overrideWith((ref) => Stream.value(entries)),
                  mediaAssetFileProvider(
                    'photo',
                  ).overrideWith((ref) => Stream.value(null)),
                ],
                child: MobileEntryEditorPage(
                  novelId: 'work',
                  databasePath: 'test',
                  section: section,
                  entryId: 'entry',
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('照片集'), findsOneWidget);
          expect(find.text('Reference'), findsOneWidget);
          final remove = find.text('移除');
          await tester.ensureVisible(remove);
          await tester.pumpAndSettle();
          await tester.tap(remove);
          await tester.pumpAndSettle();
          expect((await db.itemDao.getById('entry'))!.photos, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
    );
  }

  testWidgets('scrolls instead of overflowing on compact heights', (
    tester,
  ) async {
    await tester.pumpWidget(_wrapEditor(_editor()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final pageScrollView = find.ancestor(
      of: find.byType(RevericMarkdownEditor),
      matching: find.byType(CustomScrollView),
    );
    expect(pageScrollView, findsOneWidget);

    await tester.drag(pageScrollView, const Offset(0, -180));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('failed autosave preserves the draft and exposes a safe error', (
    tester,
  ) async {
    var fail = true;
    final saved = <String>[];
    await tester.pumpWidget(
      _wrapEditor(
        _editor(
          onSave: (title, content, category) async {
            if (fail) {
              throw ArgumentError('private database error');
            }
            saved.add(title);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Edited');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(find.text('保存失败'), findsOneWidget);
    expect(find.textContaining('private database error'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'Edited',
    );
    fail = false;
    await tester.enterText(find.byType(TextField).first, 'Corrected');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(saved, ['Corrected']);
    expect(find.text('保存失败'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets(
    'failed exit flush keeps the page open until the draft can save',
    (tester) async {
      var fail = true;
      await tester.pumpWidget(
        _wrapEditor(
          Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _editor(
                      onSave: (_, _, _) async {
                        if (fail) {
                          throw StateError('write failed');
                        }
                      },
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Unsaved');
      tester
          .widget<MobileEditorAppBar>(find.byType(MobileEditorAppBar))
          .onBack();
      await tester.pumpAndSettle();
      expect(find.byType(MobileEntryEditorView), findsOneWidget);
      expect(find.text('保存失败'), findsOneWidget);
      fail = false;
      tester
          .widget<MobileEditorAppBar>(find.byType(MobileEditorAppBar))
          .onBack();
      await tester.pumpAndSettle();
      expect(find.byType(MobileEntryEditorView), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets('composition delays persistence and prevents back navigation', (
    tester,
  ) async {
    final saved = <String>[];
    await tester.pumpWidget(
      _wrapEditor(
        _editor(
          onSave: (title, _, _) async {
            saved.add(title);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final title = tester
        .widget<TextField>(find.byType(TextField).first)
        .controller!;
    title.value = const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(saved, isEmpty);
    expect(
      tester.widget<PopScope<void>>(find.byType(PopScope<void>)).canPop,
      isFalse,
    );
    title.value = const TextEditingValue(
      text: '你',
      selection: TextSelection.collapsed(offset: 1),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(saved, ['你']);
    expect(
      tester.widget<PopScope<void>>(find.byType(PopScope<void>)).canPop,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('forced unmount handles a rejected final save', (tester) async {
    final pending = Completer<void>();
    var saves = 0;
    await tester.pumpWidget(
      _wrapEditor(
        _editor(
          onSave: (_, _, _) {
            saves++;
            return pending.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Unsaved');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(saves, 1);
    pending.completeError(ArgumentError('duplicate title'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  testWidgets('unmount flushes the newest draft after an in-flight save', (
    tester,
  ) async {
    final first = Completer<void>();
    final saved = <String>[];
    await tester.pumpWidget(
      _wrapEditor(
        _editor(
          onSave: (title, content, category) async {
            saved.add(title);
            if (saved.length == 1) {
              await first.future;
            }
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'First');
    await tester.pump(const Duration(milliseconds: 800));
    expect(saved, ['First']);
    await tester.enterText(find.byType(TextField).first, 'Latest');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(saved, ['First']);
    first.complete();
    await tester.pumpAndSettle();
    expect(saved, ['First', 'Latest']);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

Widget _editor({Future<void> Function(String, String, String)? onSave}) {
  return MobileEntryEditorView(
    sectionLabel: '物品',
    initialTitle: '玉佩',
    initialContent: '',
    initialCategory: '',
    titleHint: '标题',
    contentHint: '正文',
    categoryHint: '分类',
    onSave: onSave ?? (_, _, _) async {},
  );
}

Widget _wrapEditor(Widget child) {
  return EasyLocalization(
    supportedLocales: const [Locale('zh', 'CN')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('zh', 'CN'),
    startLocale: const Locale('zh', 'CN'),
    child: Builder(
      builder: (context) {
        return ProviderScope(
          overrides: [
            editorFontFamilyProvider.overrideWithValue('Georgia'),
            editorFontSizeProvider.overrideWithValue(16),
            editorLetterSpacingProvider.overrideWithValue(0),
            editorLineHeightProvider.overrideWithValue(1.8),
          ],
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData().copyWith(
              platform: TargetPlatform.android,
            ),
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: 390, height: 360, child: child),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
