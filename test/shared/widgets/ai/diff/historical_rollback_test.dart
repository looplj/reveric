// 职责: 验证双端共享回滚、桌面整体回滚和按行审阅直接恢复选定历史目标。
// 关联文件:
//   lib/shared/widgets/ai/diff/recent_changes_log.dart
//   lib/desktop/widgets/ai/diff/pending_changes_detail_dialog.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/diff.json
//   assets/translations/zh-CN/diff.json
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/widgets/ai/diff/pending_changes_detail_dialog.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/outline.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/services/working_change_summary.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/diff/diff_view.dart';
import 'package:reveric/shared/widgets/ai/diff/recent_changes_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../helpers/outline_fixture.dart';

const _path = 'historical-review-test';

void main() {
  late NovelContentDatabase db;
  late AppDatabase appDb;
  late NovelContentService content;
  late WorkingOverlayService overlay;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() async {
    rootBundle.clear();
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    await db.select(db.outlines).get();
    await appDb.select(appDb.novels).get();
    content = NovelContentService(db);
    overlay = WorkingOverlayService(
      db,
      content,
      novelActionsService: NovelActionsService(appDb),
    );
  });
  tearDown(() async {
    await db.close();
    await appDb.close();
  });
  Future<void> mount(
    WidgetTester tester,
    Widget child, {
    required bool mobile,
  }) async {
    await tester.binding.setSurfaceSize(
      mobile ? const Size(600, 1000) : const Size(1400, 1000),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelContentServiceProvider(_path).overrideWithValue(content),
          workingOverlayServiceProvider(_path).overrideWithValue(overlay),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: RevericThemeData.reveric.toThemeData(),
              builder: (context, route) =>
                  RevericTheme(data: RevericThemeData.reveric, child: route!),
              home: Scaffold(body: child),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'session refresh preserves selection until that field snapshot changes',
    (tester) async {
      final rows = (await tester.runAsync(() async {
        final id = await content.createChapter(
          siblingOrder: 1,
          title: 'Chapter',
        );
        final first = await overlay.stageTextChange(
          resourcePath: 'chapters/$id/content',
          resourceType: 'chapters',
          resourceId: id,
          field: 'content',
          oldText: 'a\nb\nc',
          newText: 'a\nB\nC',
          source: workingChangeSourceAi,
          sourceSessionId: 'session',
          sourceTurnId: 'u1',
        );
        final second = await overlay.stageTextChange(
          resourcePath: 'chapters/$id/outline',
          resourceType: 'chapters',
          resourceId: id,
          field: 'outline',
          oldText: 'x',
          newText: 'y',
          source: workingChangeSourceAi,
          sourceSessionId: 'session',
          sourceTurnId: 'u1',
        );
        return [first, second];
      }))!;
      await mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => PendingChangesDetailDialog.showFromChanges(
              context,
              novelId: 'work',
              databasePath: _path,
              changes: rows,
            ),
            child: const Text('Review'),
          ),
        ),
        mobile: false,
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      AiDiffView contentDiff() => tester
          .widgetList<AiDiffView>(find.byType(AiDiffView))
          .firstWhere((diff) => diff.oldText == 'a\nb\nc');
      contentDiff().onSetLinesRejected!(['d:2', 'i:2'], true);
      await tester.pumpAndSettle();
      expect(contentDiff().rejectedLineKeys, isNotEmpty);
      await tester.runAsync(
        () => overlay.stageTextChange(
          resourcePath: rows.last.resourcePath,
          resourceType: 'chapters',
          resourceId: rows.last.resourceId,
          field: 'outline',
          oldText: 'y',
          newText: 'z',
          source: workingChangeSourceAi,
          sourceSessionId: 'session',
          sourceTurnId: 'u1',
        ),
      );
      await tester.pumpAndSettle();
      expect(contentDiff().rejectedLineKeys, {
        'd:2',
        'i:2',
      }, reason: 'an outline update must preserve the content selection');
      await tester.runAsync(
        () => overlay.stageTextChange(
          resourcePath: rows.first.resourcePath,
          resourceType: 'chapters',
          resourceId: rows.first.resourceId,
          field: 'content',
          oldText: 'a\nB\nC',
          newText: 'a\nnew B\nC',
          source: workingChangeSourceAi,
          sourceSessionId: 'session',
          sourceTurnId: 'u1',
        ),
      );
      await tester.pumpAndSettle();
      final retained = contentDiff().rejectedLineKeys.toSet();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(
        retained,
        isEmpty,
        reason: 'a changed content snapshot must clear its old selection',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  for (final mobile in [false, true]) {
    for (final committed in [false, true]) {
      testWidgets(
        'absolute beat Undo restores identity without overwrite dialog mobile=$mobile committed=$committed',
        (tester) async {
          final fixture = (await tester.runAsync(() async {
            final now = DateTime(2020);
            final original = OutlineDraft(
              documentId: 'main',
              title: 'Main',
              beats: [
                for (final id in ['a', 'b', 'c'])
                  content.outlineService
                      .createBeatDraft(title: id, content: 'body $id')
                      .copyWith(createdAt: now),
              ],
              createdAt: now,
              updatedAt: now,
              deletedAt: notDeletedSentinel,
            );
            await insertOutlineFixture(db, original);
            final before = (await content.outlineService.getByDocumentId(
              'main',
            ))!;
            final manager = AiToolManager(
              content,
              workingOverlayService: overlay,
              workId: 'review-work',
            )..registerAllTools();
            final removed = await manager.executeTool(
              name: 'Remove',
              input: {
                'path':
                    '/works/review-work/outlines/Main/beats/${before.beats[1].id}',
              },
            );
            expect(removed['removed'], true);
            final change = (await overlay.getWorkingChanges()).single;
            if (committed) {
              await overlay.commitWorkingChanges(
                [change.id],
                source: workingChangeSourceAi,
                message: 'accept',
              );
            }
            final deleted = (await content.outlineService.getByDocumentId(
              'main',
            ))!;
            await content.outlineService.saveOutline(
              deleted.copyWith(
                beats: deleted.beats.reversed
                    .map((b) => b.copyWith(content: 'later'))
                    .toList(),
              ),
            );
            final changes = await overlay.getWorkingChanges();
            return (
              before: before,
              change: change,
              changes: changes,
              manager: manager,
            );
          }))!;
          final before = fixture.before;
          final change = fixture.change;
          final changes = fixture.changes;
          final manager = fixture.manager;
          await mount(
            tester,
            SingleChildScrollView(
              child: RecentChangesLog(
                novelId: 'work',
                databasePath: _path,
                changes: changes,
                bounded: !mobile,
                enableNavigation: false,
                showRollbackAll: false,
              ),
            ),
            mobile: mobile,
          );
          await tester.tap(find.byTooltip('Undo'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          final restored = (await content.outlineService.getByDocumentId(
            'main',
          ))!;
          expect(
            outlineBeatsHaveSameContent(restored.beats, before.beats),
            true,
          );
          expect(
            restored.beats.map((b) => b.createdAt),
            before.beats.map((b) => b.createdAt),
          );
          expect(
            (await db.workingChangeDao.getById(change.id))!.status,
            workingChangeStatusRejected,
          );
          expect(tester.takeException(), isNull);
          manager.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );
    }
  }

  for (final statuses in [
    [workingChangeStatusActive],
    [workingChangeStatusCommitted],
    [workingChangeStatusCommitted, workingChangeStatusActive],
  ]) {
    testWidgets('desktop rollback all restores historical text for $statuses', (
      tester,
    ) async {
      final changes = (await tester.runAsync(() async {
        final changes = <WorkingChange>[];
        for (var index = 0; index < statuses.length; index++) {
          final id = await content.createChapter(
            siblingOrder: index + 1,
            title: 'Chapter $index',
          );
          await content.updateChapterContent(
            chapterId: id,
            title: 'Chapter $index',
            outline: '',
            content: 'original $index',
          );
          final change = await overlay.stageTextChange(
            resourcePath: 'chapters/$id/content',
            resourceType: 'chapters',
            resourceId: id,
            field: 'content',
            oldText: 'original $index',
            newText: 'AI edit $index',
            source: workingChangeSourceAi,
          );
          if (statuses[index] == workingChangeStatusCommitted) {
            await overlay.commitWorkingChanges(
              [change.id],
              source: workingChangeSourceAi,
              message: 'auto accept',
            );
          }
          await content.updateChapterContent(
            chapterId: id,
            title: 'Chapter $index',
            outline: 'unrelated outline',
            content: 'later edit $index',
          );
          changes.add((await db.workingChangeDao.getById(change.id))!);
        }
        return changes;
      }))!;
      await mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => PendingChangesDetailDialog.showFromChanges(
              context,
              novelId: 'work',
              databasePath: _path,
              changes: changes,
            ),
            child: const Text('Review'),
          ),
        ),
        mobile: false,
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      final rollbackButton = find.widgetWithText(
        OutlinedButton,
        'Roll Back All',
      );
      expect(
        tester.widget<OutlinedButton>(rollbackButton).onPressed,
        isNotNull,
      );
      await tester.tap(rollbackButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pumpAndSettle();
      for (var index = 0; index < changes.length; index++) {
        final change = changes[index];
        expect(
          (await content.getChapterById(change.resourceId!))!.content,
          'later edit $index',
        );
        expect(
          (await db.workingChangeDao.getById(change.id))!.status,
          statuses[index],
        );
      }
      await tester.tap(rollbackButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Roll back'));
      await tester.pumpAndSettle();
      expect(find.byType(PendingChangesDetailDialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      for (final change in changes) {
        final chapter = (await content.getChapterById(change.resourceId!))!;
        expect(chapter.content, change.oldText);
        expect(chapter.outline, 'unrelated outline');
        expect(
          (await db.workingChangeDao.getById(change.id))!.status,
          workingChangeStatusRejected,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  for (final mobile in [false, true]) {
    testWidgets(
      'multi-turn resource has one summary and rolls back to earliest target mobile=$mobile',
      (tester) async {
        final fixture = (await tester.runAsync(() async {
          final id = await content.createChapter(
            siblingOrder: 1,
            title: 'Multi-turn chapter',
          );
          final rows = <WorkingChange>[];
          for (final (turn, oldText, newText) in [
            ('u1', '', 'B'),
            ('u2', 'B', 'C'),
            ('u1', 'C', 'D'),
          ]) {
            rows.add(
              await overlay.stageTextChange(
                resourcePath: 'chapters/$id/content',
                resourceType: 'chapters',
                resourceId: id,
                field: 'content',
                oldText: oldText,
                newText: newText,
                source: workingChangeSourceAi,
                sourceTurnId: turn,
              ),
            );
          }
          return (id: id, rows: rows);
        }))!;
        expect(countChangeGroups(fixture.rows), 1);
        await mount(
          tester,
          RecentChangesLog(
            novelId: 'work',
            databasePath: _path,
            changes: fixture.rows,
            bounded: !mobile,
          ),
          mobile: mobile,
        );
        expect(find.byTooltip('Undo'), findsOneWidget);
        await tester.tap(find.byTooltip('Undo'));
        await tester.pumpAndSettle();
        expect((await content.getChapterById(fixture.id))!.content, '');
        for (final row in fixture.rows) {
          expect(
            (await db.workingChangeDao.getById(row.id))!.status,
            workingChangeStatusRejected,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'aggregated field refresh clears stale line selection after outside edit',
    (tester) async {
      final fixture = (await tester.runAsync(() async {
        final id = await content.createChapter(
          siblingOrder: 1,
          title: 'Chapter',
        );
        final rows = <WorkingChange>[];
        for (final (turn, before, after) in [
          ('u1', 'a\nb\nc', 'a\nB\nc'),
          ('u2', 'a\nB\nc', 'a\nB\nC'),
        ]) {
          rows.add(
            await overlay.stageTextChange(
              resourcePath: 'chapters/$id/content',
              resourceType: 'chapters',
              resourceId: id,
              field: 'content',
              oldText: before,
              newText: after,
              source: workingChangeSourceAi,
              sourceTurnId: turn,
            ),
          );
        }
        return (id: id, rows: rows);
      }))!;
      await mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => PendingChangesDetailDialog.showFromChanges(
              context,
              novelId: 'work',
              databasePath: _path,
              changes: fixture.rows,
            ),
            child: const Text('Review'),
          ),
        ),
        mobile: false,
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.byType(AiDiffView), findsOneWidget);
      final detail = tester.widget<PendingChangesDetailDialog>(
        find.byType(PendingChangesDetailDialog),
      );
      expect(detail.items.single.fields, hasLength(1));
      expect(detail.items.single.changes, hasLength(2));
      expect(detail.items.single.delta, lineDelta('a\nb\nc', 'a\nB\nC'));
      var diff = tester.widget<AiDiffView>(find.byType(AiDiffView));
      expect(diff.oldText, 'a\nb\nc');
      expect(diff.newText, 'a\nB\nC');
      diff.onSetLinesRejected!(['d:2', 'i:2'], true);
      await tester.pumpAndSettle();
      expect(
        tester.widget<AiDiffView>(find.byType(AiDiffView)).rejectedLineKeys,
        isNotEmpty,
      );
      await tester.runAsync(
        () => content.updateChapterContent(
          chapterId: fixture.id,
          title: 'Chapter',
          outline: '',
          content: 'outside\nnew\ntext',
        ),
      );
      await tester.pumpAndSettle();
      diff = tester.widget<AiDiffView>(find.byType(AiDiffView));
      expect(diff.newText, 'outside\nnew\ntext');
      expect(diff.rejectedLineKeys, isEmpty);
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
      expect(
        (await content.getChapterById(fixture.id))!.content,
        'outside\nnew\ntext',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'desktop line review stays enabled after manual edits and applies historical selection',
    (tester) async {
      final fixture = (await tester.runAsync(() async {
        final id = await content.createChapter(
          siblingOrder: 1,
          title: 'Chapter',
        );
        await content.updateChapterContent(
          chapterId: id,
          title: 'Chapter',
          outline: '',
          content: 'a\nb\nc',
        );
        final change = await overlay.stageTextChange(
          resourcePath: 'chapters/$id/content',
          resourceType: 'chapters',
          resourceId: id,
          field: 'content',
          oldText: 'a\nb\nc',
          newText: 'a\nB\nc\nd',
          source: workingChangeSourceAi,
        );
        await overlay.commitWorkingChanges(
          [change.id],
          source: workingChangeSourceAi,
          message: 'accept',
        );
        await content.updateChapterContent(
          chapterId: id,
          title: 'Chapter',
          outline: 'outside',
          content: 'a\nB\nc\nmanual',
        );
        final changes = await overlay.getWorkingChanges();
        return (id: id, changes: changes);
      }))!;
      final id = fixture.id;
      final changes = fixture.changes;
      await mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => PendingChangesDetailDialog.showFromChanges(
              context,
              novelId: 'work',
              databasePath: _path,
              changes: changes,
            ),
            child: const Text('Review'),
          ),
        ),
        mobile: false,
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      final diff = tester.widget<AiDiffView>(find.byType(AiDiffView));
      expect(diff.oldText, 'a\nb\nc');
      expect(diff.newText, 'a\nB\nc\nmanual');
      expect(diff.reviewMode, true);
      expect(diff.onSetLinesRejected, isNotNull);
      diff.onSetLinesRejected!(['i:4'], true);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
      expect((await content.getChapterById(id))!.content, 'a\nB\nc');
      expect((await content.getChapterById(id))!.outline, 'outside');
      expect(find.byType(PendingChangesDetailDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
