// 职责: 通过桌面小说编辑页验证保存队列和删除操作跨页面卸载的生命周期。
// 关联文件:
//   lib/desktop/pages/novel_editor.dart
//   lib/desktop/widgets/workspace/outline_editor.dart
//   lib/desktop/widgets/workspace/outline_beat_dialog.dart
//   lib/shared/services/outline_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'dart:convert';
import 'dart:async';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:reveric/shared/components/reveric_select.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/pages/novel_editor.dart';
import 'package:reveric/desktop/widgets/sidebar/sidebar.dart';
import 'package:reveric/desktop/widgets/workspace/outline_editor.dart';
import 'package:reveric/desktop/widgets/workspace/outline_timeline_strip.dart';
import 'package:reveric/desktop/widgets/workspace/novel_workspace_panel.dart';
import 'package:reveric/shared/widgets/md/reveric_markdown_editor.dart';
import 'package:reveric/shared/form/form.dart';
import 'package:reveric/shared/components/reveric_dropdowns.dart';
import 'package:reveric/desktop/widgets/workspace/outline_beat_dialog.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/outline.dart';
import 'package:reveric/shared/models/novel_workspace.dart';
import 'package:reveric/shared/models/novel_workspace_state.dart';
import 'package:reveric/shared/providers/novel_workspace_state_provider.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/outline_service.dart';
import 'package:reveric/shared/services/ai/prompt_template.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/outline_fixture.dart';

const _path = 'desktop-outline-save-test';

void main() {
  late NovelContentDatabase db;
  late AppDatabase appDb;
  late _ControlledContentService service;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await PromptTemplateService.loadAll();
    for (final font in {
      'LXGWWenKai': 'LXGWWenKai',
      'Georgia': 'LXGWWenKai',
      'Literata': 'Literata',
    }.entries) {
      await (FontLoader(
            font.key,
          )..addFont(rootBundle.load('assets/fonts/${font.value}-Regular.ttf')))
          .load();
    }
  });
  setUp(() async {
    rootBundle.clear();
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    service = _ControlledContentService(db);
    // 菜单交互需要真实命中页面，使用已完成首次引导的测试账户。
    await appDb.appStateDao.set(key: 'chat_onboarding_shown', value: 'true');
    for (final feature in ['feature_usage', 'outline_craft']) {
      await appDb
          .into(appDb.featureUsages)
          .insert(
            FeatureUsagesCompanion.insert(
              featureId: 'feature_onboarding.$feature',
              firstUsedAt: DateTime(2026),
              lastUsedAt: DateTime(2026),
            ),
          );
    }

    await appDb.novelDao.create(
      id: 'novel',
      title: 'Novel',
      description: '',
      contentDatabasePath: _path,
    );
    final now = DateTime.fromMillisecondsSinceEpoch(100000);
    await insertOutlineFixture(
      db,
      OutlineDraft(
        documentId: 'main',
        title: 'Main',
        startChapterNum: 4,
        beats: [
          for (final id in ['a', 'b', 'c'])
            OutlineBeatDraft(
              id: id,
              title: id,
              content: 'body $id',
              chapterCount: 2,
              createdAt: now,
            ),
        ],
        createdAt: now,
        updatedAt: now,
        deletedAt: notDeletedSentinel,
      ),
    );
    await appDb.appStateDao.set(
      key: novelWorkspaceAppStateKey('novel'),
      value: jsonEncode(
        NovelWorkspaceStateData(
          selection: const WorkspaceSelection(
            section: NovelWorkspaceSection.outlines,
            itemId: 'main',
          ),
          isHydrated: true,
        ).toJson(),
      ),
    );
  });
  tearDown(() async {
    await db.close();
    await appDb.close();
  });
  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(appDb),
          appSettingsDatabaseProvider.overrideWithValue(appDb),
          novelContentDatabaseProvider(_path).overrideWithValue(db),
          novelContentServiceProvider(_path).overrideWithValue(service),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('zh', 'CN')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          fallbackLocale: const Locale('zh', 'CN'),
          startLocale: const Locale('zh', 'CN'),
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: RevericThemeData.reveric.toThemeData(),
              builder: (context, child) =>
                  RevericTheme(data: RevericThemeData.reveric, child: child!),
              home: const NovelEditorPage(novelId: 'novel'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OutlineEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  testWidgets('chapter deletion finishes after the editor is unmounted', (
    tester,
  ) async {
    final chapterId = await service.createChapter(
      title: 'Delete me',
      siblingOrder: 0,
    );
    await mount(tester);
    service.deleteGate = Completer<void>();
    final pending = tester
        .widget<LeftSidebar>(find.byType(LeftSidebar))
        .onDeleteChapter!(chapterId);
    // Observe failure immediately so the old callback cannot escape the test zone.
    Object? failure;
    final observed = pending.catchError((Object error) {
      failure = error;
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    service.deleteGate!.complete();
    await observed;
    expect(await service.getChapterById(chapterId), isNull);
    expect(failure, isNull);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets(
    'dialog changes, cancellation, reorder, delete, rapid queue and resource switches persist identities',
    (tester) async {
      await mount(tester);
      OutlineTimelineStrip timeline() => tester.widget<OutlineTimelineStrip>(
        find.byType(OutlineTimelineStrip),
      );
      Future<OutlineDraft> stored() async =>
          (await service.outlineService.getByDocumentId('main'))!;
      Future<void> settle() async {
        await tester.pump();
        await tester.pumpAndSettle();
      }

      Future<void> fillDialog(String title, {bool save = true}) async {
        expect(find.byType(OutlineBeatDialog), findsOneWidget);
        final titleField = find.descendant(
          of: find.byType(HookedTextFormField<BeatFormField>),
          matching: find.byType(TextField),
        );
        await tester.enterText(titleField, title);
        tester
                .widget<RevericMarkdownEditor>(
                  find.descendant(
                    of: find.byType(OutlineBeatDialog),
                    matching: find.byType(RevericMarkdownEditor),
                  ),
                )
                .controller
                .text =
            'body $title';
        tester
            .widget<RevericFormDropdown<String>>(
              find.descendant(
                of: find.byType(OutlineBeatDialog),
                matching: find.byType(RevericFormDropdown<String>),
              ),
            )
            .onChanged!(outlineStatusFinished);
        final countField = find
            .descendant(
              of: find.byType(OutlineBeatDialog),
              matching: find.byType(TextField),
            )
            .first;
        await tester.enterText(countField, '3');
        if (save) {
          await tester.tap(
            find.descendant(
              of: find.byType(OutlineBeatDialog),
              matching: find.widgetWithText(FilledButton, '保存'),
            ),
          );
        } else {
          await tester.tap(
            find.descendant(
              of: find.byType(OutlineBeatDialog),
              matching: find.widgetWithText(TextButton, '取消'),
            ),
          );
        }
        await settle();
      }

      final statusSelect = find.descendant(
        of: find.byType(OutlineEditor),
        matching: find.byType(RevericSelect<String>),
      );
      final finishedLabel = tester
          .widget<RevericSelect<String>>(statusSelect)
          .items
          .firstWhere((item) => item.value == outlineStatusFinished)
          .label;
      await tester.tap(statusSelect);
      await settle();
      await tester.tap(find.text(finishedLabel));
      // 状态属于正文编辑态，等待页面的两秒自动保存防抖。
      await tester.pump(const Duration(seconds: 2));
      await settle();
      expect((await stored()).status, outlineStatusFinished);

      timeline().onAddBeat();
      await settle();
      await fillDialog('new');
      final added = (await stored()).beats.last;
      expect(added.id, matches(RegExp(r'^obt_[A-Z0-9]{6}$')));
      expect(
        tester
            .widget<OutlineEditor>(find.byType(OutlineEditor))
            .draft!
            .beats
            .last
            .id,
        added.id,
      );
      expect(await db.select(db.outlineBeats).get(), hasLength(4));
      timeline().onEditBeat(3);
      await settle();
      await fillDialog('new edited');
      final updated = (await stored()).beats.last;
      expect(updated.id, added.id);
      expect(updated.createdAt, added.createdAt);
      expect(updated.content, 'body new edited');
      expect(updated.status, outlineStatusFinished);
      expect(updated.chapterCount, 3);
      expect((await stored()).beats.take(3).map((b) => b.id), ['a', 'b', 'c']);
      final beforeCancel = (await db.select(db.outlineBeats).get())
          .map((r) => r.toJson())
          .toList();
      timeline().onAddBeat();
      await settle();
      await fillDialog('cancel new', save: false);
      timeline().onEditBeat(0);
      await settle();
      await fillDialog('cancel existing', save: false);
      expect(
        (await db.select(db.outlineBeats).get())
            .map((r) => r.toJson())
            .toList(),
        beforeCancel,
      );
      timeline().onReorderBeats(3, 0);
      await settle();
      for (final range in ['第 4–6 章', '第 7–8 章', '第 9–10 章', '第 11–12 章']) {
        expect(find.text(range), findsOneWidget);
      }
      expect((await stored()).beats.map((b) => b.id), [
        added.id,
        'a',
        'b',
        'c',
      ]);
      expect(
        (await db.select(db.outlineBeats).get()).every(
          (r) => r.deletedAt == notDeletedSentinel,
        ),
        true,
      );
      timeline().onDeleteBeat(2);
      await settle();
      expect((await stored()).beats.map((b) => b.id), [added.id, 'a', 'c']);
      expect(
        (await db.select(db.outlineBeats).get())
            .singleWhere((r) => r.id == 'b')
            .deletedAt,
        isNot(notDeletedSentinel),
      );

      // Queue another change then immediately switch resources; the page must flush
      // the current draft rather than applying a delayed earlier DB echo.
      final firstSave = service.outlineService.pauseNextSave();
      timeline().onDeleteBeat(1);
      await tester.pump();
      timeline().onEditBeat(0);
      await settle();
      await fillDialog('latest');
      expect(timeline().draft.beats.first.title, 'latest');
      expect((await stored()).beats.first.title, 'new edited');
      firstSave.complete();

      tester
          .widget<NovelWorkspacePanel>(find.byType(NovelWorkspacePanel))
          .onSelectionChanged(const WorkspaceSelection.overview());
      await settle();
      expect((await stored()).beats.map((b) => b.id), [added.id, 'c']);
      tester
          .widget<NovelWorkspacePanel>(find.byType(NovelWorkspacePanel))
          .onSelectionChanged(
            const WorkspaceSelection(
              section: NovelWorkspaceSection.outlines,
              itemId: 'main',
            ),
          );
      await settle();
      expect(timeline().draft.beats.map((b) => b.id), [added.id, 'c']);
      expect(timeline().draft.beats.first.title, 'latest');
      timeline().onDeleteBeat(1);
      await settle();
      timeline().onDeleteBeat(0);
      await settle();
      expect((await stored()).beats, isEmpty);
      expect(
        (await db.select(db.outlineBeats).get()).every(
          (r) => r.deletedAt != notDeletedSentinel,
        ),
        true,
      );
      tester
          .widget<NovelWorkspacePanel>(find.byType(NovelWorkspacePanel))
          .onSelectionChanged(const WorkspaceSelection.overview());
      await settle();
      tester
          .widget<NovelWorkspacePanel>(find.byType(NovelWorkspacePanel))
          .onSelectionChanged(
            const WorkspaceSelection(
              section: NovelWorkspaceSection.outlines,
              itemId: 'main',
            ),
          );
      await settle();
      expect(timeline().draft.beats, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
  testWidgets(
    'canonical duplicate-title save accepts external updates and never overwrites them on exit',
    (tester) async {
      await service.outlineService.createOutline(defaultTitle: 'Other');
      await mount(tester);
      await tester.enterText(
        find.byKey(const ValueKey('outline-title-main')),
        'Other',
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      final saved = (await service.outlineService.getByDocumentId('main'))!;
      expect(saved.title, 'Other (2)');
      final afterSave = tester
          .widget<OutlineEditor>(find.byType(OutlineEditor))
          .draft!;
      debugPrint(
        'B4 title ack: persisted=${saved.title} local=${afterSave.title}',
      );
      await service.outlineService.saveOutline(
        saved.copyWith(
          content: 'external overview',
          beats: [
            saved.beats.first.copyWith(content: 'external beat'),
            ...saved.beats.skip(1),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final displayed = tester
          .widget<OutlineEditor>(find.byType(OutlineEditor))
          .draft!;
      debugPrint(
        'B4 external update: localTitle=${displayed.title} localContent=${displayed.content} localBeatCount=${displayed.beats.length}',
      );
      // Teardown is part of the assertion: a retained stale pending draft must not
      // be re-saved over the subsequent external edit.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final afterExit = (await service.outlineService.getByDocumentId('main'))!;
      debugPrint(
        'B4 exit: persisted=${afterExit.title} content=${afterExit.content} beatCount=${afterExit.beats.length}',
      );
      expect(afterSave.title, 'Other (2)');
      expect(displayed.content, 'external overview');
      expect(displayed.beats.first.content, 'external beat');
      expect(afterExit.content, 'external overview');
      expect(afterExit.beats.first.content, 'external beat');
      await mount(tester);
      final reopened = tester
          .widget<OutlineEditor>(find.byType(OutlineEditor))
          .draft!;
      expect(reopened.title, 'Other (2)');
      expect(reopened.content, 'external overview');
      expect(reopened.beats.first.content, 'external beat');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

// Hold a real save before its DB transaction to expose in-flight UI races.
class _ControlledOutlineService extends OutlineService {
  _ControlledOutlineService(super.database);
  Completer<void>? _nextSave;
  Completer<void> pauseNextSave() => _nextSave = Completer<void>();
  @override
  Future<void> saveOutline(OutlineDraft draft) async {
    final gate = _nextSave;
    _nextSave = null;
    if (gate != null) {
      await gate.future;
    }
    await super.saveOutline(draft);
  }
}

class _ControlledContentService extends NovelContentService {
  _ControlledContentService(super.db) : super(novelId: 'novel');
  Completer<void>? deleteGate;
  @override
  Future<void> deleteChapter(String chapterId) async {
    await deleteGate?.future;
    await super.deleteChapter(chapterId);
  }

  late final _controlledOutline = _ControlledOutlineService(database);
  @override
  _ControlledOutlineService get outlineService => _controlledOutline;
}
