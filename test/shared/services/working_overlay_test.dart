// 职责: 验证 WorkingOverlay 的 patch 写入、冲突保护、提交、拒绝与历史回滚语义。
// 关联文件:
//   lib/shared/services/working_overlay.dart
//   lib/shared/database/novel_content_daos/change_commit_dao.dart

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';

import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  late NovelContentDatabase db;
  late AppDatabase appDb;
  late NovelContentService contentService;
  late WorkingOverlayService service;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    contentService = NovelContentService(db);
    final actionsService = NovelActionsService(appDb);
    service = WorkingOverlayService(
      db,
      contentService,
      novelActionsService: actionsService,
    );
  });

  tearDown(() async {
    await db.close();
    await appDb.close();
  });

  Future<String> stageCreateChange(String resourcePath, String resourceId) {
    return service
        .stageCreateChange(
          resourcePath: resourcePath,
          resourceType: 'test',
          resourceId: resourceId,
          previewText: 'text',
          source: workingChangeSourceManual,
        )
        .then((change) => change.id);
  }

  test(
    'new work description changes share history and rollback with legacy rows',
    () async {
      await appDb.novelDao.create(
        id: 'work',
        title: '作品',
        description: '旧简介',
        contentDatabasePath: db.filePath,
      );
      const historyPath = '/works/work/description';
      const legacyPath = 'profile/description';
      const message = 'history.commit_message.manual_novel_description_save';
      final change = await service.stageTextChange(
        resourcePath: historyPath,
        resourceType: 'novel',
        resourceId: 'work',
        field: 'description',
        oldText: '旧简介',
        newText: '中间版本',
        source: workingChangeSourceManual,
      );
      final commit = await service.commitManualSave(
        manualChangeIds: [change.id],
        resourceScopes: const [historyPath],
        manualMessage: message,
      );
      // 模拟升级前已保存的历史数据。
      await (db.update(
        db.workingChanges,
      )..where((table) => table.id.equals(change.id))).write(
        const WorkingChangesCompanion(resourcePath: Value(legacyPath)),
      );
      await (db.update(
        db.changeCommitItems,
      )..where((table) => table.workingChangeId.equals(change.id))).write(
        const ChangeCommitItemsCompanion(resourcePath: Value(legacyPath)),
      );

      final current = await service.stageTextChange(
        resourcePath: historyPath,
        resourceType: 'novel',
        resourceId: 'work',
        field: 'description',
        oldText: '中间版本',
        newText: '新简介',
        source: workingChangeSourceManual,
      );
      expect(current.resourcePath, historyPath);
      final nextCommit = await service.commitManualSave(
        manualChangeIds: [current.id],
        resourceScopes: const [historyPath],
        manualMessage: message,
      );
      expect(nextCommit, commit);
      final history = await service.getChangeCommitItemsForResource(
        historyPath,
      );
      expect(
        history.map((item) => item.resourcePath),
        unorderedEquals([legacyPath, historyPath]),
      );
      final changes = await service.getWorkingChangesForResource(historyPath);
      expect(
        changes.map((row) => row.id),
        unorderedEquals([change.id, current.id]),
      );
      expect(
        await service.getWorkingChangesForResource('/works/other/description'),
        isEmpty,
      );
      expect((await appDb.novelDao.get('work'))?.description, '新简介');

      await service.rollbackCommit(commitId: commit!);
      expect((await appDb.novelDao.get('work'))?.description, '旧简介');
      final afterRollback = await service.getChangeCommitItemsForResource(
        historyPath,
      );
      expect(
        afterRollback
            .where((item) => item.commitId != commit)
            .single
            .resourcePath,
        historyPath,
      );
    },
  );

  test(
    'overwriting a folder with a document keeps its children reachable',
    () async {
      final documents = contentService.documentsService;
      final winner = await documents.createDocument(
        type: 'lore',
        title: 'Old',
        content: 'historical',
      );
      final change = await service.stageTextChange(
        resourcePath: '/lore/$winner/title',
        resourceType: 'lore',
        resourceId: winner,
        field: 'title',
        oldText: 'Old',
        newText: 'New',
        source: workingChangeSourceAi,
      );
      final loser = await documents.createFolder(type: 'lore', title: 'Old');
      final child = await documents.createDocument(
        type: 'lore',
        title: 'Child',
        parentId: loser,
      );
      await service.rollbackChange(change.id);
      expect((await documents.getDocumentById(winner))!.isFolder, isFalse);
      expect((await documents.getDocumentById(winner))!.content, 'historical');
      expect((await documents.getDocumentById(child))!.parentId, isNull);
      expect(
        (await documents.getChildren(null)).map((row) => row.id),
        containsAll([winner, child]),
      );
    },
  );

  test(
    'overwrites preserve tombstones and migrate item relations atomically',
    () async {
      final winner = await contentService.createItem(
        type: entityTypeSkill,
        title: 'Old',
        content: 'historical',
      );
      final change = await service.stageTextChange(
        resourcePath: '/skills/$winner/title',
        resourceType: 'skills',
        resourceId: winner,
        field: 'title',
        oldText: 'Old',
        newText: 'New',
        source: workingChangeSourceAi,
      );
      final loser = await contentService.createItem(
        type: entityTypeSkill,
        title: 'Old',
        content: 'occupied',
      );
      final person = await contentService.createCharacterProfile(
        name: 'Person',
      );
      final relation = await contentService.entityRelationsService
          .createRelation(
            sourceType: entityTypeCharacter,
            sourceId: person,
            targetType: entityTypeSkill,
            targetId: loser,
            relationType: characterSkillMastered,
          );
      await expectLater(
        db.transaction(() async {
          await service.rollbackChange(change.id);
          throw StateError('abort transaction');
        }),
        throwsStateError,
      );
      expect((await contentService.getItemById(winner))!.title, 'New');
      expect(await contentService.getItemById(loser), isNotNull);
      expect(
        (await contentService.entityRelationsService.getRelationById(
          relation,
        ))!.targetId,
        loser,
      );
      expect(
        (await service.getWorkingChangeById(change.id))!.status,
        workingChangeStatusActive,
      );
      await service.rollbackChange(change.id);
      expect((await contentService.getItemById(winner))!.title, 'Old');
      expect((await contentService.getItemById(winner))!.content, 'historical');
      expect(await contentService.getItemById(loser), isNull);
      expect(
        (await contentService.entityRelationsService.getRelationById(
          relation,
        ))!.targetId,
        winner,
      );
      expect(
        (await db
                .customSelect(
                  'SELECT content FROM items WHERE id = ?',
                  variables: [Variable.withString(loser)],
                )
                .getSingle())
            .read<String>('content'),
        'occupied',
      );
    },
  );

  test('outline overwrite migrates beats and remains editable', () async {
    final outlines = contentService.outlineService;
    final winner = await outlines.createOutline(defaultTitle: 'Old');
    final change = await service.stageTextChange(
      resourcePath: '/outlines/$winner/title',
      resourceType: 'outlines',
      resourceId: winner,
      field: 'title',
      oldText: 'Old',
      newText: 'New',
      source: workingChangeSourceAi,
    );
    final loser = await outlines.createOutline(
      defaultTitle: 'Old',
      beats: [outlines.createBeatDraft(title: 'Keep beat')],
    );
    final beat = (await outlines.getByDocumentId(loser))!.beats.single.id;
    await service.rollbackChange(change.id);
    expect(await outlines.getByDocumentId(loser), isNull);
    final restored = (await outlines.getByDocumentId(winner))!;
    expect(restored.beats.single.id, beat);
    await outlines.saveOutline(restored.copyWith(content: 'edited'));
    expect((await outlines.getByDocumentId(winner))!.content, 'edited');
  });

  test(
    'rollback overwrites duplicate folders and migrates children recursively',
    () async {
      final documents = contentService.documentsService;
      final winner = await documents.createFolder(type: 'lore', title: 'Old');
      final child = await documents.createFolder(
        type: 'lore',
        parentId: winner,
        title: 'Shared',
      );
      final change = await service.stageTextChange(
        resourcePath: '/lore/$winner/title',
        resourceType: 'lore',
        resourceId: winner,
        field: 'title',
        oldText: 'Old',
        newText: 'New',
        source: workingChangeSourceAi,
      );
      final loser = await documents.createFolder(type: 'lore', title: 'Old');
      final duplicateChild = await documents.createFolder(
        type: 'lore',
        parentId: loser,
        title: 'Shared',
      );
      final grandchild = await documents.createDocument(
        type: 'lore',
        parentId: duplicateChild,
        title: 'Leaf',
        content: 'preserve',
      );
      final sibling = await documents.createDocument(
        type: 'lore',
        parentId: loser,
        title: 'Sibling',
      );
      expect(
        await service.rollbackChange(change.id),
        RollbackChangeResult.rolledBack,
      );
      expect(
        (await documents.getDocumentByNamePath(
          type: 'lore',
          namePath: ['Old'],
        ))!.id,
        winner,
      );
      expect(
        (await documents.getDocumentByNamePath(
          type: 'lore',
          namePath: ['Old', 'Shared', 'Leaf'],
        ))!.id,
        grandchild,
      );
      expect(
        (await documents.getDocumentById(grandchild))!.content,
        'preserve',
      );
      expect((await documents.getDocumentById(sibling))!.parentId, winner);
      expect((await documents.getDocumentById(child))!.parentId, winner);
      expect(await documents.getDocumentById(loser), isNull);
      expect(await documents.getDocumentById(duplicateChild), isNull);
      final tombstone = await db
          .customSelect(
            'SELECT deleted_at FROM documents WHERE id = ?',
            variables: [Variable.withString(loser)],
          )
          .getSingle();
      expect(tombstone.read<int>('deleted_at'), greaterThan(0));
      expect(
        await service.rollbackChange(change.id),
        RollbackChangeResult.noop,
      );
    },
  );

  test('document overwrite keeps historical identity and content', () async {
    final documents = contentService.documentsService;
    final winner = await documents.createDocument(
      type: 'lore',
      title: 'Old',
      content: 'history',
    );
    final change = await service.stageTextChange(
      resourcePath: '/lore/$winner/title',
      resourceType: 'lore',
      resourceId: winner,
      field: 'title',
      oldText: 'Old',
      newText: 'New',
      source: workingChangeSourceAi,
    );
    final loser = await documents.createDocument(
      type: 'lore',
      title: 'Old',
      content: 'occupied',
    );
    await service.rollbackChange(change.id);
    final current = await documents.getDocumentByNamePath(
      type: 'lore',
      namePath: ['Old'],
    );
    expect(current!.id, winner);
    expect(current.content, 'history');
    expect(await documents.getDocumentById(loser), isNull);
    await documents.updateDocument(
      id: winner,
      title: 'Old',
      content: 'normal edit',
    );
    expect((await documents.getDocumentById(winner))!.content, 'normal edit');
  });

  test('rollback repairs a parent cycle instead of persisting it', () async {
    final locations = contentService.locationsService;
    final root = await locations.createLocation(name: 'Root');
    final child = await locations.createLocation(name: 'Child', parentId: root);
    final change = await service.stageTextChange(
      resourcePath: '/locations/$root/parent_id',
      resourceType: 'locations',
      resourceId: root,
      field: 'parent_id',
      oldText: child,
      newText: '',
      source: workingChangeSourceAi,
      restoreHistory: true,
    );
    await service.rollbackChange(change.id);
    expect((await locations.getLocationById(root))!.parentId, isNull);
    expect((await locations.getLocationById(child))!.parentId, root);
    expect(await locations.getDescendantIds(root), [child]);
  });

  test(
    'commit rollback reports missing targets and restores the other fields',
    () async {
      final ids = <String>[];
      final changes = <WorkingChange>[];
      for (var index = 0; index < 2; index++) {
        final id = await contentService.createChapter(
          siblingOrder: index,
          title: 'Chapter $index',
        );
        ids.add(id);
        changes.add(
          await service.stageTextChange(
            resourcePath: '/chapters/$id/content',
            resourceType: 'chapters',
            resourceId: id,
            field: 'content',
            oldText: '',
            newText: 'AI',
            source: workingChangeSourceAi,
          ),
        );
      }
      final commit = await service.commitWorkingChanges(
        changes.map((row) => row.id).toList(),
        source: workingChangeSourceAi,
        message: 'accept',
      );
      await contentService.deleteChapter(ids.first);
      expect(
        await service.rollbackCommit(commitId: commit!),
        RestoreResourceResult.partiallyRestored,
      );
      expect((await contentService.getChapterById(ids.last))!.content, '');
      expect(
        (await service.getWorkingChangeById(changes.first.id))!.status,
        workingChangeStatusCommitted,
      );
      expect(
        (await service.getWorkingChangeById(changes.last.id))!.status,
        workingChangeStatusRejected,
      );
      expect(
        await service.rollbackCommit(commitId: commit),
        RestoreResourceResult.skipped,
      );
    },
  );

  test(
    'missing commit history is skipped without marking an active neighbour rejected',
    () async {
      final id = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter',
      );
      final change = await service.stageTextChange(
        resourcePath: '/chapters/$id/content',
        resourceType: 'chapters',
        resourceId: id,
        field: 'content',
        oldText: '',
        newText: 'AI',
        source: workingChangeSourceAi,
      );
      await (db.update(
        db.workingChanges,
      )..where((row) => row.id.equals(change.id))).write(
        const WorkingChangesCompanion(
          status: Value(workingChangeStatusCommitted),
        ),
      );
      final reviews = await service.resolveFieldReviews([change]);
      final result = await service.rollbackFields(reviews);
      expect(result.rolledBack, 0);
      expect(result.skippedPaths, [change.resourcePath]);
      expect((await contentService.getChapterById(id))!.content, 'AI');
      expect(
        (await service.getWorkingChangeById(change.id))!.status,
        workingChangeStatusCommitted,
      );
    },
  );

  test(
    'partial rollback ignores a stale snapshot and keeps an undoable current baseline',
    () async {
      final id = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter',
      );
      final change = await service.stageTextChange(
        resourcePath: '/chapters/$id/content',
        resourceType: 'chapters',
        resourceId: id,
        field: 'content',
        oldText: 'A\nB',
        newText: 'X\nY',
        source: workingChangeSourceAi,
      );
      final review = (await service.resolveFieldReviews([change])).single;
      await contentService.updateChapterContentPartial(
        chapterId: id,
        content: 'later manual',
      );
      expect(
        await service.rollbackFieldLines(review, {'d:1', 'i:1'}),
        RollbackChangeResult.rolledBack,
      );
      expect((await contentService.getChapterById(id))!.content, 'A\nY');
      final reverse = (await service.getWorkingChanges()).singleWhere(
        (row) => row.source == workingChangeSourceManual,
      );
      expect(reverse.oldText, 'later manual');
      await service.rollbackChange(reverse.id);
      expect(
        (await contentService.getChapterById(id))!.content,
        'later manual',
      );
    },
  );

  test(
    'rollback normalizes an obsolete role while normal editing remains validated',
    () async {
      final id = await contentService.createCharacterProfile(name: '角色');
      final profile = (await contentService.getCharacterProfileById(id))!;
      final change = await service.stageTextChange(
        resourcePath: '/characters/$id/role',
        resourceType: 'characters',
        resourceId: id,
        field: 'role',
        oldText: 'legacy_role',
        newText: profile.role,
        source: workingChangeSourceAi,
      );
      expect(
        await service.rollbackChange(change.id),
        RollbackChangeResult.rolledBack,
      );
      expect(
        (await contentService.getCharacterProfileById(id))!.role,
        characterRoleSupporting,
      );
      await expectLater(
        contentService.updateCharacterProfile(
          entryId: id,
          name: profile.name,
          role: 'legacy_role',
          gender: profile.gender,
          biography: profile.biography,
          description: profile.description,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'turn rollback keeps created folders and their later children',
    () async {
      final documents = contentService.documentsService;
      final folder = await documents.createFolder(
        type: 'lore',
        title: 'Folder',
      );
      final created = await documents.createDocument(
        type: 'lore',
        title: 'Created',
        parentId: folder,
      );
      final changes = [
        await service.stageCreateChange(
          resourcePath: '/lore/$folder',
          resourceType: 'lore',
          resourceId: folder,
          previewText: 'Folder',
          source: workingChangeSourceAi,
          sourceTurnId: 'u1',
        ),
        await service.stageCreateChange(
          resourcePath: '/lore/$created',
          resourceType: 'lore',
          resourceId: created,
          previewText: 'Created',
          source: workingChangeSourceAi,
          sourceTurnId: 'u1',
        ),
      ];
      final manual = await documents.createDocument(
        type: 'lore',
        title: 'Manual',
        parentId: folder,
      );
      final result = await service.rollbackTurns(turnIds: ['u1']);
      expect(result.rolledBack, 2);
      expect(result.skippedPaths, isEmpty);
      expect(await documents.getDocumentById(created), isNull);
      expect(await documents.getDocumentById(folder), isNotNull);
      expect((await documents.getDocumentById(manual))!.parentId, folder);
      for (final change in changes) {
        expect(
          (await service.getWorkingChangeById(change.id))!.status,
          workingChangeStatusRejected,
        );
      }
    },
  );

  test(
    'duplicate location names roll back a multi-resource working batch',
    () async {
      final locations = contentService.locationsService;
      final first = await locations.createLocation(
        name: '城甲',
        description: '原文甲',
      );
      final second = await locations.createLocation(
        name: '城乙',
        description: '原文乙',
      );
      final before = await locations.getLocations();
      await expectLater(
        service.stageTextChangesAtomically(
          changes: [
            WorkingTextChangeRequest(
              resourcePath: 'locations/$first/description',
              resourceType: 'locations',
              summary: 'test location batch',
              resourceId: first,
              field: 'description',
              oldText: '原文甲',
              newText: '不应保存',
            ),
            WorkingTextChangeRequest(
              resourcePath: 'locations/$first/name',
              resourceType: 'locations',
              summary: 'test location batch',
              resourceId: first,
              field: 'name',
              oldText: '城甲',
              newText: '新城',
            ),
            WorkingTextChangeRequest(
              resourcePath: 'locations/$second/name',
              resourceType: 'locations',
              summary: 'test location batch',
              resourceId: second,
              field: 'name',
              oldText: '城乙',
              newText: '新城',
            ),
          ],
          source: workingChangeSourceAi,
        ),
        throwsException,
      );
      expect(await locations.getLocations(), before);
      expect(await db.workingChangeDao.getAll(), isEmpty);
    },
  );

  for (final committed in [false, true]) {
    test(
      'location ${committed ? 'committed' : 'active'} rollback restores its name even when reused',
      () async {
        final locations = contentService.locationsService;
        final first = await locations.createLocation(name: '旧城');
        final change = await service.stageTextChange(
          resourcePath: 'locations/$first/name',
          resourceType: 'locations',
          resourceId: first,
          field: 'name',
          oldText: '旧城',
          newText: '新城',
          source: workingChangeSourceAi,
        );
        final commitId = committed
            ? await service.commitWorkingChanges(
                [change.id],
                source: workingChangeSourceAi,
                message: 'accept',
              )
            : null;
        final other = await locations.createLocation(name: '旧城');
        await (committed
            ? service.rollbackCommit(commitId: commitId!)
            : service.rejectWorkingChange(change.id));
        expect((await locations.getLocationById(first))!.name, '旧城');
        expect(await locations.getLocationById(other), isNull);
        expect(
          (await db.workingChangeDao.getById(change.id))!.status,
          workingChangeStatusRejected,
        );
        await expectLater(
          locations.createLocation(name: '旧城'),
          throwsException,
        );
      },
    );
  }

  test('manual save replays foreshadowing position fields', () async {
    final first = await contentService.createChapter(
      siblingOrder: 0,
      title: '第一章',
    );
    final second = await contentService.createChapter(
      siblingOrder: 1,
      title: '第二章',
    );
    final id = await contentService.createForeshadowing(
      title: '玉佩',
      setupChapterId: first,
    );
    // 与桌面端保存一致：位置按列名作为文本改动暂存，空串表示清空。
    final changeIds = <String>[];
    for (final spec in [
      ('setup_chapter_id', first, second),
      ('payoff_chapter_id', '', first),
    ]) {
      final change = await service.stageTextChange(
        resourcePath: '/foreshadowing/$id/${spec.$1}',
        resourceType: 'foreshadowing',
        resourceId: id,
        field: spec.$1,
        oldText: spec.$2,
        newText: spec.$3,
        source: workingChangeSourceManual,
        summary: 'Update foreshadowing ${spec.$1}',
      );
      changeIds.add(change.id);
    }
    await service.commitManualSave(
      manualChangeIds: changeIds,
      resourceScopes: ['/foreshadowing/$id'],
      manualMessage: 'history.commit_message.manual_foreshadowing_save',
    );

    final saved = (await contentService.getForeshadowingById(id))!;
    expect(saved.setupChapterId, second);
    expect(saved.payoffChapterId, first);
  });

  group('autoSaveCommit', () {
    test('first call creates a new commit', () async {
      final changeId = await stageCreateChange('/test/r1', 'r1');

      final commitId = await service.autoSaveCommit(
        [changeId],
        source: workingChangeSourceManual,
        message: 'test.msg',
      );

      expect(commitId, isNotNull);

      final commits = await db.changeCommitDao.getAll();
      expect(commits.length, 1);
      expect(commits.first.changeCount, 1);

      final items = await db.changeCommitDao.getItemsByCommit(commitId!);
      expect(items.length, 1);
    });

    test('second call with same source+message amends', () async {
      final id1 = await stageCreateChange('/test/r1', 'r1');
      final commitId1 = await service.autoSaveCommit(
        [id1],
        source: workingChangeSourceManual,
        message: 'test.msg',
      );

      final id2 = await stageCreateChange('/test/r2', 'r2');
      final commitId2 = await service.autoSaveCommit(
        [id2],
        source: workingChangeSourceManual,
        message: 'test.msg',
      );

      expect(commitId1, commitId2);

      final commits = await db.changeCommitDao.getAll();
      expect(commits.length, 1);
      expect(commits.first.changeCount, 2);

      final items = await db.changeCommitDao.getItemsByCommit(commitId1!);
      expect(items.length, 2);
    });

    test('different message creates new commit', () async {
      final id1 = await stageCreateChange('/test/r1', 'r1');
      await service.autoSaveCommit(
        [id1],
        source: workingChangeSourceManual,
        message: 'test.msg1',
      );

      final id2 = await stageCreateChange('/test/r2', 'r2');
      await service.autoSaveCommit(
        [id2],
        source: workingChangeSourceManual,
        message: 'test.msg2',
      );

      final commits = await db.changeCommitDao.getAll();
      expect(commits.length, 2);
    });

    test('commitWorkingChanges never amends', () async {
      final id1 = await stageCreateChange('/test/r1', 'r1');
      await service.commitWorkingChanges(
        [id1],
        source: workingChangeSourceManual,
        message: 'test.msg',
      );

      final id2 = await stageCreateChange('/test/r2', 'r2');
      await service.commitWorkingChanges(
        [id2],
        source: workingChangeSourceManual,
        message: 'test.msg',
      );

      final commits = await db.changeCommitDao.getAll();
      expect(commits.length, 2);
    });

    test('AI edits merge by source while manual edits stay separate', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      final resourcePath = '/chapters/$chapterId/content';
      final chapterScope = '/chapters/$chapterId';

      final aiChange = await service.stageTextChange(
        resourcePath: resourcePath,
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'original',
        newText: 'ai draft',
        source: workingChangeSourceAi,
        summary: 'AI draft',
      );

      final mergedAiChange = await service.stageTextChange(
        resourcePath: resourcePath,
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'original',
        newText: 'ai revised draft',
        source: workingChangeSourceAi,
        summary: 'AI revised draft',
      );

      final editedChange = await service.stageTextChange(
        resourcePath: resourcePath,
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'ai revised draft',
        newText: 'edited draft',
        source: workingChangeSourceManual,
        summary: 'Manual edit',
      );

      final commitId = await service.commitManualSave(
        manualChangeIds: [editedChange.id],
        resourceScopes: [chapterScope],
        manualMessage: 'history.commit_message.manual_chapter_save',
      );

      expect(mergedAiChange.id, aiChange.id);
      expect(editedChange.id, isNot(aiChange.id));
      expect(commitId, isNotNull);

      final changes = await db.workingChangeDao.getByResource(resourcePath);
      final activeAiChanges = changes
          .where(
            (change) =>
                change.status == workingChangeStatusActive &&
                change.source == workingChangeSourceAi,
          )
          .toList();
      final committedAiChanges = changes
          .where(
            (change) =>
                change.status == workingChangeStatusCommitted &&
                change.source == workingChangeSourceAi,
          )
          .toList();
      final committedManualChanges = changes
          .where(
            (change) =>
                change.status == workingChangeStatusCommitted &&
                change.source == workingChangeSourceManual,
          )
          .toList();

      expect(activeAiChanges, isEmpty);
      expect(committedAiChanges.length, 1);
      expect(committedAiChanges.first.id, aiChange.id);
      expect(committedAiChanges.first.oldText, 'original');
      expect(committedAiChanges.first.newText, 'ai revised draft');
      expect(committedManualChanges.length, 1);
      expect(committedManualChanges.first.oldText, 'ai revised draft');
      expect(committedManualChanges.first.newText, 'edited draft');

      final chapter = await contentService.getChapterById(chapterId);
      expect(chapter?.content, 'edited draft');
    });

    test(
      'commitManualSave auto-commits create patch in the same resource scope',
      () async {
        final chapterId = await contentService.createChapter(
          siblingOrder: 1,
          title: 'Chapter 1',
        );
        final createChange = await service.stageCreateChange(
          resourcePath: '/chapters/$chapterId',
          resourceType: 'chapters',
          resourceId: chapterId,
          previewText: 'Chapter 1',
          source: workingChangeSourceAi,
          summary: 'AI created chapter',
        );
        final manualChange = await service.stageTextChange(
          resourcePath: '/chapters/$chapterId/title',
          resourceType: 'chapters',
          resourceId: chapterId,
          field: 'title',
          oldText: 'Chapter 1',
          newText: 'Renamed Chapter',
          source: workingChangeSourceManual,
          summary: 'Manual rename',
        );

        await service.commitManualSave(
          manualChangeIds: [manualChange.id],
          resourceScopes: ['/chapters/$chapterId'],
          manualMessage: 'history.commit_message.manual_chapter_save',
        );

        final createRow = await db.workingChangeDao.getById(createChange.id);
        expect(createRow?.status, workingChangeStatusCommitted);
      },
    );

    test(
      'stageTextChange writes real data and reject reverts the patch',
      () async {
        final chapterId = await contentService.createChapter(
          siblingOrder: 1,
          title: 'Chapter 1',
        );
        await contentService.updateChapterContent(
          chapterId: chapterId,
          title: 'Chapter 1',
          outline: '',
          content: 'original content',
        );
        final resourcePath = '/chapters/$chapterId/content';
        final change = await service.stageTextChange(
          resourcePath: resourcePath,
          resourceType: 'chapters',
          resourceId: chapterId,
          field: 'content',
          oldText: 'original content',
          newText: 'patched content',
          source: workingChangeSourceAi,
          summary: 'AI patch',
        );

        var chapter = await contentService.getChapterById(chapterId);
        expect(chapter?.content, 'patched content');

        await service.rejectWorkingChange(change.id);

        chapter = await contentService.getChapterById(chapterId);
        expect(chapter?.content, 'original content');
        final rejected = await db.workingChangeDao.getById(change.id);
        expect(rejected?.status, workingChangeStatusRejected);
      },
    );

    test('stageTextChange rejects a stale expectedCurrentText', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'newer content',
      );

      expect(
        () => service.stageTextChange(
          resourcePath: '/chapters/$chapterId/content',
          resourceType: 'chapters',
          resourceId: chapterId,
          field: 'content',
          oldText: 'stale content',
          newText: 'patched content',
          source: workingChangeSourceManual,
          expectedCurrentText: 'stale content',
        ),
        throwsA(isA<WorkingOverlayConflictException>()),
      );

      expect(
        (await contentService.getChapterById(chapterId))?.content,
        'newer content',
      );
      expect(await db.workingChangeDao.getAll(), isEmpty);
    });

    test(
      'commitWorkingChanges records an already applied patch once',
      () async {
        final chapterId = await contentService.createChapter(
          siblingOrder: 1,
          title: 'Chapter 1',
        );
        await contentService.updateChapterContent(
          chapterId: chapterId,
          title: 'Chapter 1',
          outline: '',
          content: 'original content',
        );
        final resourcePath = '/chapters/$chapterId/content';
        final change = await service.stageTextChange(
          resourcePath: resourcePath,
          resourceType: 'chapters',
          resourceId: chapterId,
          field: 'content',
          oldText: 'original content',
          newText: 'patched content',
          source: workingChangeSourceAi,
          summary: 'AI patch',
        );

        final commitId = await service.commitWorkingChanges(
          [change.id],
          source: workingChangeSourceAi,
          message: 'test.accept_applied_patch',
        );

        expect(commitId, isNotNull);
        final chapter = await contentService.getChapterById(chapterId);
        expect(chapter?.content, 'patched content');
        final committed = await db.workingChangeDao.getById(change.id);
        expect(committed?.status, workingChangeStatusCommitted);
        final items = await db.changeCommitDao.getItemsByCommit(commitId!);
        expect(items.single.oldText, 'original content');
        expect(items.single.newText, 'patched content');
      },
    );

    test('rejectWorkingChange removes created relation patches', () async {
      final relationId = await contentService.entityRelationsService
          .createRelation(
            sourceType: 'character',
            sourceId: 'character_a',
            targetType: 'character',
            targetId: 'character_b',
            relationType: 'friend',
          );
      final change = await service.stageCreateChange(
        resourcePath: '/relations/$relationId',
        resourceType: 'relations',
        resourceId: relationId,
        previewText:
            'Relation: character(character_a) -> character(character_b)',
        source: workingChangeSourceAi,
        toolName: 'Create',
        summary: 'AI created relation',
      );

      expect(
        await contentService.entityRelationsService.getAllRelations(),
        hasLength(1),
      );

      await service.rejectWorkingChange(change.id);

      expect(
        await contentService.entityRelationsService.getAllRelations(),
        isEmpty,
      );
      final rejected = await db.workingChangeDao.getById(change.id);
      expect(rejected?.status, workingChangeStatusRejected);
    });

    test(
      'repeated AI edits to the same chapter field coalesce into one change and one commit',
      () async {
        final chapterId = await contentService.createChapter(
          siblingOrder: 1,
          title: 'Chapter 1',
        );
        await contentService.updateChapterContent(
          chapterId: chapterId,
          title: 'Chapter 1',
          outline: '',
          content: 'v0',
        );
        final resourcePath = '/chapters/$chapterId/content';

        // 模拟真实 Edit 工具：每次读取当前实时内容作为 oldText，连续编辑三次。
        Future<WorkingChange> editTo(String next) async {
          final current = (await contentService.getChapterById(
            chapterId,
          ))!.content;
          return service.stageTextChange(
            resourcePath: resourcePath,
            resourceType: 'chapters',
            resourceId: chapterId,
            field: 'content',
            oldText: current,
            newText: next,
            source: workingChangeSourceAi,
            toolName: 'Edit',
            summary: 'AI edited chapter content',
          );
        }

        final c1 = await editTo('v1');
        final c2 = await editTo('v2');
        final c3 = await editTo('v3');

        // 三次 Edit 合并为同一条 working change。
        expect(c2.id, c1.id);
        expect(c3.id, c1.id);

        final active = (await db.workingChangeDao.getByResource(
          resourcePath,
        )).where((ch) => ch.status == workingChangeStatusActive).toList();
        expect(active, hasLength(1), reason: '同字段多次 Edit 只应有一条 active 变更');
        // 基线锁定为首次编辑前的原始值，newText 为最新结果。
        expect(active.single.oldText, 'v0');
        expect(active.single.newText, 'v3');

        // 内容实时生效，链式编辑结果正确。
        expect((await contentService.getChapterById(chapterId))!.content, 'v3');

        // 提交整轮 → 单个 commit、单个 item，回滚基线为原始值。
        final commitId = await service.commitWorkingChanges(
          [c1.id],
          source: workingChangeSourceAi,
          message: 'history.commit_message.accept_all_pending_ai_changes',
        );
        expect(commitId, isNotNull);

        final commits = await db.changeCommitDao.getAll();
        expect(commits, hasLength(1));
        expect(commits.first.changeCount, 1);

        final items = await db.changeCommitDao.getItemsByCommit(commitId!);
        expect(items, hasLength(1));
        expect(items.single.oldText, 'v0');
        expect(items.single.newText, 'v3');
      },
    );
  });

  group('restoreResourceToCommit', () {
    test('reverts chapter content to selected commit snapshot', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'version 1',
      );

      final change1 = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'version 1',
        newText: 'version 2',
        source: workingChangeSourceManual,
      );
      final commit1 = await service.commitWorkingChanges(
        [change1.id],
        source: workingChangeSourceManual,
        message: 'history.commit_message.manual_chapter_save',
      );

      final change2 = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'version 2',
        newText: 'version 3',
        source: workingChangeSourceManual,
      );
      await service.commitWorkingChanges(
        [change2.id],
        source: workingChangeSourceManual,
        message: 'history.commit_message.manual_chapter_save',
      );

      final result = await service.restoreResourceToCommit(
        resourceId: chapterId,
        commitId: commit1!,
      );

      expect(result, RestoreResourceResult.restored);
      final chapter = await contentService.getChapterById(chapterId);
      expect(chapter?.content, 'version 2');

      final commits = await db.changeCommitDao.getAll();
      expect(
        commits.any(
          (commit) =>
              commit.message == historyCommitMessageRestoreToHistoricalVersion,
        ),
        isTrue,
      );
    });

    test(
      'returns alreadyAtVersion when content already matches snapshot',
      () async {
        final chapterId = await contentService.createChapter(
          siblingOrder: 1,
          title: 'Chapter 1',
        );
        await contentService.updateChapterContent(
          chapterId: chapterId,
          title: 'Chapter 1',
          outline: '',
          content: 'stable content',
        );
        final change = await service.stageTextChange(
          resourcePath: '/chapters/$chapterId/content',
          resourceType: 'chapters',
          resourceId: chapterId,
          field: 'content',
          oldText: 'stable content',
          newText: 'stable content',
          source: workingChangeSourceManual,
        );
        final commitId = await service.commitWorkingChanges(
          [change.id],
          source: workingChangeSourceManual,
          message: 'history.commit_message.manual_chapter_save',
        );

        final result = await service.restoreResourceToCommit(
          resourceId: chapterId,
          commitId: commitId!,
        );

        expect(result, RestoreResourceResult.alreadyAtVersion);
      },
    );
  });

  group('rollbackCommit', () {
    test(
      'rolls back a committed resource creation and its field changes',
      () async {
        final chapterId = await contentService.createChapter(
          siblingOrder: 1,
          title: 'Created chapter',
        );
        final createChange = await service.stageCreateChange(
          resourcePath: '/chapters/$chapterId',
          resourceType: 'chapters',
          resourceId: chapterId,
          previewText: '正文 Created chapter',
          source: workingChangeSourceAi,
        );
        final outlineChange = await service.stageTextChange(
          resourcePath: '/chapters/$chapterId/outline',
          resourceType: 'chapters',
          resourceId: chapterId,
          field: 'outline',
          oldText: '',
          newText: 'Created outline',
          source: workingChangeSourceAi,
        );
        final contentChange = await service.stageTextChange(
          resourcePath: '/chapters/$chapterId/content',
          resourceType: 'chapters',
          resourceId: chapterId,
          field: 'content',
          oldText: '',
          newText: 'Created content',
          source: workingChangeSourceAi,
        );
        final commitId = await service.commitWorkingChanges(
          [createChange.id, outlineChange.id, contentChange.id],
          source: workingChangeSourceAi,
          message: 'history.commit_message.auto_commit_ai_changes',
        );

        final result = await service.rollbackCommit(commitId: commitId!);

        expect(result, RestoreResourceResult.restored);
        expect(await contentService.getChapterById(chapterId), isNull);
        expect(
          (await service.getWorkingChangeById(createChange.id))?.status,
          workingChangeStatusRejected,
        );
        expect(
          (await service.getWorkingChangeById(outlineChange.id))?.status,
          workingChangeStatusRejected,
        );
        expect(
          (await service.getWorkingChangeById(contentChange.id))?.status,
          workingChangeStatusRejected,
        );

        final secondResult = await service.rollbackCommit(commitId: commitId);
        expect(secondResult, RestoreResourceResult.alreadyAtVersion);
      },
    );

    test('rolls selected commit back to its before-change value', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'version 1',
      );

      final change1 = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'version 1',
        newText: 'version 2',
        source: workingChangeSourceManual,
      );
      final commit1 = await service.commitWorkingChanges(
        [change1.id],
        source: workingChangeSourceManual,
        message: 'history.commit_message.manual_chapter_save',
      );

      final change2 = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'version 2',
        newText: 'version 3',
        source: workingChangeSourceManual,
      );
      await service.commitWorkingChanges(
        [change2.id],
        source: workingChangeSourceManual,
        message: 'history.commit_message.manual_chapter_save',
      );

      final result = await service.rollbackCommit(
        commitId: commit1!,
        resourceId: chapterId,
      );

      expect(result, RestoreResourceResult.restored);
      final chapter = await contentService.getChapterById(chapterId);
      expect(chapter?.content, 'version 1');

      final commits = await db.changeCommitDao.getAll();
      expect(
        commits.any(
          (commit) =>
              commit.message == historyCommitMessageRollbackSelectedCommit,
        ),
        isTrue,
      );
    });

    test(
      'returns alreadyAtVersion when selected change is already rolled back',
      () async {
        final chapterId = await contentService.createChapter(
          siblingOrder: 1,
          title: 'Chapter 1',
        );
        await contentService.updateChapterContent(
          chapterId: chapterId,
          title: 'Chapter 1',
          outline: '',
          content: 'version 1',
        );
        final change = await service.stageTextChange(
          resourcePath: '/chapters/$chapterId/content',
          resourceType: 'chapters',
          resourceId: chapterId,
          field: 'content',
          oldText: 'version 1',
          newText: 'version 2',
          source: workingChangeSourceManual,
        );
        final commitId = await service.commitWorkingChanges(
          [change.id],
          source: workingChangeSourceManual,
          message: 'history.commit_message.manual_chapter_save',
        );

        await service.rollbackCommit(
          commitId: commitId!,
          resourceId: chapterId,
        );
        final result = await service.rollbackCommit(
          commitId: commitId,
          resourceId: chapterId,
        );

        expect(result, RestoreResourceResult.alreadyAtVersion);
      },
    );
  });

  group('historical rollback boundaries', () {
    for (final mode in ['single', 'turn', 'lines', 'commit']) {
      test(
        '$mode keeps unrelated active fields and records unchanged',
        () async {
          final id = await contentService.createChapter(
            siblingOrder: 1,
            title: 'Chapter',
          );
          await contentService.updateChapterContent(
            chapterId: id,
            title: 'Chapter',
            outline: 'original outline',
            content: 'a\nb\nc',
          );
          final selected = await service.stageTextChange(
            resourcePath: 'chapters/$id/content',
            resourceType: 'chapters',
            resourceId: id,
            field: 'content',
            oldText: 'a\nb\nc',
            newText: 'a\nB\nc\nd',
            source: workingChangeSourceAi,
            sourceTurnId: 'selected-turn',
          );
          final commit = await service.commitWorkingChanges(
            [selected.id],
            source: workingChangeSourceAi,
            message: 'selected',
          );
          final outside = await service.stageTextChange(
            resourcePath: 'chapters/$id/outline',
            resourceType: 'chapters',
            resourceId: id,
            field: 'outline',
            oldText: 'original outline',
            newText: 'pending outside',
            source: workingChangeSourceAi,
            sourceTurnId: 'outside-turn',
          );
          final outsideRow = (await db.workingChangeDao.getById(
            outside.id,
          ))!.toJson();
          await contentService.updateChapterContent(
            chapterId: id,
            title: 'Chapter',
            outline: 'pending outside',
            content: 'later manual',
          );
          switch (mode) {
            case 'turn':
              await service.rollbackTurn(turnId: 'selected-turn');
            case 'lines':
              await service.rollbackChangeLines(selected.id, {'i:4'});
            case 'commit':
              await service.rollbackCommit(commitId: commit!);
            default:
              await service.rollbackChange(selected.id);
          }
          final chapter = (await contentService.getChapterById(id))!;
          expect(chapter.content, mode == 'lines' ? 'a\nB\nc' : 'a\nb\nc');
          expect(chapter.outline, 'pending outside');
          expect(
            (await db.workingChangeDao.getById(outside.id))!.toJson(),
            outsideRow,
          );
          final items = await db.select(db.changeCommitItems).get();
          expect(items.where((r) => r.workingChangeId == outside.id), isEmpty);
        },
      );
    }

    test(
      'missing target is not restored and leaves original commit bookkeeping intact',
      () async {
        final id = await contentService.createChapter(
          siblingOrder: 1,
          title: 'Chapter',
        );
        final change = await service.stageTextChange(
          resourcePath: 'chapters/$id/content',
          resourceType: 'chapters',
          resourceId: id,
          field: 'content',
          oldText: '',
          newText: 'AI',
          source: workingChangeSourceAi,
          sourceTurnId: 'missing-turn',
        );
        final commit = await service.commitWorkingChanges(
          [change.id],
          source: workingChangeSourceAi,
          message: 'selected',
        );
        await contentService.deleteChapter(id);
        final before = (await db.workingChangeDao.getById(change.id))!.toJson();
        expect(
          await service.rollbackChange(change.id),
          RollbackChangeResult.skipped,
        );
        expect(
          await service.rollbackChangeLines(change.id, {'i:1'}),
          RollbackChangeResult.skipped,
        );
        expect(
          await service.rollbackCommit(commitId: commit!),
          RestoreResourceResult.skipped,
        );
        final result = await service.rollbackTurn(turnId: 'missing-turn');
        expect(result.rolledBack, 0);
        expect(result.skipped, 1);
        expect(result.skippedPaths, [change.resourcePath]);
        expect(
          (await db.workingChangeDao.getById(change.id))!.toJson(),
          before,
        );
        expect(await service.getChangeCommits(), hasLength(1));
      },
    );

    test(
      'commit rollback repetition does not overwrite a new later edit',
      () async {
        final id = await contentService.createChapter(
          siblingOrder: 1,
          title: 'Chapter',
        );
        final change = await service.stageTextChange(
          resourcePath: 'chapters/$id/content',
          resourceType: 'chapters',
          resourceId: id,
          field: 'content',
          oldText: '',
          newText: 'AI',
          source: workingChangeSourceAi,
        );
        final commit = await service.commitWorkingChanges(
          [change.id],
          source: workingChangeSourceAi,
          message: 'selected',
        );
        await service.rollbackCommit(commitId: commit!);
        final later = await service.stageTextChange(
          resourcePath: 'chapters/$id/content',
          resourceType: 'chapters',
          resourceId: id,
          field: 'content',
          oldText: '',
          newText: 'new after rollback',
          source: workingChangeSourceAi,
        );
        final before = (await db.workingChangeDao.getById(later.id))!.toJson();
        final commits = (await service.getChangeCommits())
            .map((r) => r.toJson())
            .toList();
        expect(
          await service.rollbackCommit(commitId: commit),
          RestoreResourceResult.alreadyAtVersion,
        );
        expect(
          (await contentService.getChapterById(id))!.content,
          'new after rollback',
        );
        expect((await db.workingChangeDao.getById(later.id))!.toJson(), before);
        expect(
          (await service.getChangeCommits()).map((r) => r.toJson()).toList(),
          commits,
        );
      },
    );
  });

  group('stageCreateChange sourceTurnId', () {
    test('stores sourceTurnId on create change', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );

      final change = await service.stageCreateChange(
        resourcePath: '/chapters/$chapterId',
        resourceType: 'chapters',
        resourceId: chapterId,
        previewText: 'Chapter 1',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );

      expect(change.sourceTurnId, 'turn_1');
    });

    test('rolls back active create changes by sourceTurnId', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await service.stageCreateChange(
        resourcePath: '/chapters/$chapterId',
        resourceType: 'chapters',
        resourceId: chapterId,
        previewText: 'Chapter 1',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );

      final result = await service.rollbackTurn(turnId: 'turn_1');

      expect(result.rolledBack, 1);

      final chapter = await contentService.getChapterById(chapterId);
      expect(chapter, isNull);
    });

    test('rolls back committed create changes by sourceTurnId', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      final change = await service.stageCreateChange(
        resourcePath: '/chapters/$chapterId',
        resourceType: 'chapters',
        resourceId: chapterId,
        previewText: 'Chapter 1',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );
      final outlineChange = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/outline',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'outline',
        oldText: '',
        newText: 'Created outline',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );
      final contentChange = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: '',
        newText: 'Created content',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );
      await service.commitWorkingChanges(
        [change.id, outlineChange.id, contentChange.id],
        source: workingChangeSourceAi,
        message: 'history.commit_message.auto_commit_ai_changes',
      );

      final result = await service.rollbackTurn(turnId: 'turn_1');

      expect(result.rolledBack, 3);

      expect(await contentService.getChapterById(chapterId), isNull);
      expect(
        (await service.getWorkingChangeById(change.id))?.status,
        workingChangeStatusRejected,
      );
      expect(
        (await service.getWorkingChangeById(outlineChange.id))?.status,
        workingChangeStatusRejected,
      );
      expect(
        (await service.getWorkingChangeById(contentChange.id))?.status,
        workingChangeStatusRejected,
      );
    });
  });

  group('stageTextChange sourceTurnId', () {
    test('stores sourceTurnId on new change', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'old',
      );

      final change = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'old',
        newText: 'new',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );

      expect(change.sourceTurnId, 'turn_1');
    });

    test('preserves sourceTurnId in separate turn segments', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'v1',
      );

      await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'v1',
        newText: 'v2',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );
      final change = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'v2',
        newText: 'v3',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_2',
      );

      expect(change.sourceTurnId, 'turn_2');
      expect(change.oldText, 'v2');
      expect(
        await db.workingChangeDao.getByResource(change.resourcePath),
        hasLength(2),
      );
      expect(change.newText, 'v3');
    });

    test('does not coalesce the same resource across AI sessions', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'v1',
      );

      final first = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'v1',
        newText: 'v2',
        source: workingChangeSourceAi,
        sourceSessionId: 'session_1',
        sourceTurnId: 'turn_1',
      );
      final second = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'v2',
        newText: 'v3',
        source: workingChangeSourceAi,
        sourceSessionId: 'session_2',
        sourceTurnId: 'turn_2',
      );

      expect(second.id, isNot(first.id));
      expect(first.sourceSessionId, 'session_1');
      expect(second.sourceSessionId, 'session_2');
    });
  });

  group('review P2-4 persisted chronology', () {
    final sameSecond = DateTime.utc(2020);
    Future<String> stageNamed(
      String chapterId,
      String id,
      String session,
      String oldText,
      String newText,
    ) async {
      final change = await service.stageTextChange(
        resourcePath: 'chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: oldText,
        newText: newText,
        source: workingChangeSourceAi,
        sourceSessionId: session,
        sourceTurnId: 'same-second-turn',
      );
      await (db.update(
        db.workingChanges,
      )..where((row) => row.id.equals(change.id))).write(
        WorkingChangesCompanion(
          id: Value(id),
          createdAt: Value(sameSecond),
          updatedAt: Value(sameSecond),
        ),
      );
      return id;
    }

    Future<String> chapter() async {
      final id = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter',
      );
      await contentService.updateChapterContent(
        chapterId: id,
        title: 'Chapter',
        outline: '',
        content: 'zero',
      );
      return id;
    }

    Future<void> assertNet(
      String chapterId,
      List<String> originalIds,
      String before,
    ) async {
      expect((await contentService.getChapterById(chapterId))!.content, 'zero');
      final rows = await service.getWorkingChanges();
      expect(
        rows.where((r) => originalIds.contains(r.id)).map((r) => r.status),
        everyElement(workingChangeStatusRejected),
      );
      final reverse = rows.singleWhere(
        (r) => r.source == workingChangeSourceManual,
      );
      expect(reverse.oldText, before);
      expect(reverse.newText, 'zero');
      final reverseCommit = (await service.getChangeCommits()).singleWhere(
        (r) => r.source == workingChangeSourceManual,
      );
      final items = await service.getChangeCommitItemsForCommit(
        reverseCommit.id,
      );
      expect(items, hasLength(1));
      expect(items.single.oldText, before);
      expect(items.single.newText, 'zero');
      final beforeRepeat = rows.map((r) => r.toJson()).toList();
      await service.rollbackTurn(turnId: 'same-second-turn');
      expect(
        (await service.getWorkingChanges()).map((r) => r.toJson()).toList(),
        beforeRepeat,
      );
      await service.rollbackCommit(commitId: reverseCommit.id);
      expect((await contentService.getChapterById(chapterId))!.content, before);
    }

    test(
      'same-second turn ignores random ID order for two committed snapshots',
      () async {
        final id = await chapter();
        final first = await stageNamed(
          id,
          'a-first',
          'session-a',
          'zero',
          'one',
        );
        await service.commitWorkingChanges(
          [first],
          source: workingChangeSourceAi,
          message: 'first',
        );
        final second = await stageNamed(
          id,
          'z-second',
          'session-b',
          'one',
          'two',
        );
        await service.commitWorkingChanges(
          [second],
          source: workingChangeSourceAi,
          message: 'second',
        );
        await (db.update(db.workingChanges)
              ..where((r) => r.id.isIn([first, second])))
            .write(WorkingChangesCompanion(updatedAt: Value(sameSecond)));
        await service.rollbackTurn(turnId: 'same-second-turn');
        await assertNet(id, [first, second], 'two');
      },
    );

    test(
      'same-second commit ignores item IDs and reversed acceptance order',
      () async {
        final id = await chapter();
        final first = await stageNamed(
          id,
          'z-first',
          'session-a',
          'zero',
          'one',
        );
        final second = await stageNamed(
          id,
          'a-second',
          'session-b',
          'one',
          'two',
        );
        final commit = await service.commitWorkingChanges(
          [second, first],
          source: workingChangeSourceAi,
          message: 'reversed acceptance',
        );
        for (final item in await service.getChangeCommitItemsForCommit(
          commit!,
        )) {
          await (db.update(
            db.changeCommitItems,
          )..where((r) => r.id.equals(item.id))).write(
            ChangeCommitItemsCompanion(
              id: Value(
                item.workingChangeId == second
                    ? 'a-newer-item'
                    : 'z-older-item',
              ),
              createdAt: Value(sameSecond),
            ),
          );
        }
        await service.rollbackCommit(commitId: commit);
        await assertNet(id, [first, second], 'two');
      },
    );

    test(
      'returning to a previous session preserves a separate baseline',
      () async {
        final id = await chapter();
        final first = await stageNamed(
          id,
          'a-first',
          'session-a',
          'zero',
          'one',
        );
        final second = await stageNamed(
          id,
          'z-second',
          'session-b',
          'one',
          'two',
        );
        final coalesced = await service.stageTextChange(
          resourcePath: 'chapters/$id/content',
          resourceType: 'chapters',
          resourceId: id,
          field: 'content',
          oldText: 'two',
          newText: 'three',
          source: workingChangeSourceAi,
          sourceSessionId: 'session-a',
          sourceTurnId: 'same-second-turn',
        );
        expect(coalesced.id, isNot(first));
        expect(coalesced.oldText, 'two');
        await service.commitWorkingChanges(
          [second, first, coalesced.id],
          source: workingChangeSourceAi,
          message: 'interleaved',
        );
        await (db.update(
          db.workingChanges,
        )..where((r) => r.id.equals(first))).write(
          WorkingChangesCompanion(
            updatedAt: Value(sameSecond.add(const Duration(seconds: 1))),
          ),
        );
        await (db.update(db.workingChanges)..where((r) => r.id.equals(second)))
            .write(WorkingChangesCompanion(updatedAt: Value(sameSecond)));
        await service.rollbackTurn(turnId: 'same-second-turn');
        await assertNet(id, [first, second], 'three');
      },
    );
  });

  group('T0 turn segments and field reviews', () {
    late String chapterId;
    Future<WorkingChange> write(
      String turn,
      String text, {
      bool commit = false,
      String session = 'session',
    }) async {
      final before = (await contentService.getChapterById(chapterId))!.content;
      final change = await service.stageTextChange(
        resourcePath: 'chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: before,
        newText: text,
        source: workingChangeSourceAi,
        sourceSessionId: session,
        sourceTurnId: turn,
      );
      if (commit) {
        await service.commitWorkingChanges(
          [change.id],
          source: workingChangeSourceAi,
          message: 'accept',
        );
      }
      return (await db.workingChangeDao.getById(change.id))!;
    }

    Future<List<WorkingChange>> aiChanges() async =>
        (await service.getWorkingChanges())
            .where(
              (row) =>
                  row.source == workingChangeSourceAi &&
                  (row.status == workingChangeStatusActive ||
                      row.status == workingChangeStatusCommitted),
            )
            .toList();
    setUp(() async {
      chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'T0',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'T0',
        outline: '',
        content: 'A',
      );
    });
    for (final firstCommitted in [false, true]) {
      for (final secondCommitted in [false, true]) {
        test(
          'rollback second turn preserves first first=$firstCommitted second=$secondCommitted',
          () async {
            final first = await write('u1', 'B', commit: firstCommitted);
            final second = await write('u2', 'C', commit: secondCommitted);
            expect(second.id, isNot(first.id));
            expect(second.oldText, 'B');
            final result = await service.rollbackTurns(turnIds: ['u2']);
            expect(result.rolledBack, 1);
            expect(
              (await contentService.getChapterById(chapterId))!.content,
              'B',
            );
            expect(
              (await db.workingChangeDao.getById(first.id))!.status,
              first.status,
            );
            await service.rollbackTurns(turnIds: ['u1', 'u2']);
            expect(
              (await contentService.getChapterById(chapterId))!.content,
              'A',
            );
          },
        );
        test(
          'interleaved range restores earliest baseline first=$firstCommitted second=$secondCommitted',
          () async {
            final first = await write('u1', 'B', commit: firstCommitted);
            final second = await write('u2', 'C', commit: secondCommitted);
            final third = await write('u1', 'D');
            expect({first.id, second.id, third.id}, hasLength(3));
            final result = await service.rollbackTurns(turnIds: ['u2', 'u1']);
            expect(result.rolledBack, 3);
            expect(
              (await contentService.getChapterById(chapterId))!.content,
              'A',
            );
            expect(
              (await service.rollbackTurns(turnIds: ['u1', 'u2'])).rolledBack,
              0,
            );
          },
        );
      }
    }

    for (final useFieldReview in [false, true]) {
      test(
        'mixed status rollback records an undoable net reverse review=$useFieldReview',
        () async {
          final first = await write('u1', 'B');
          final second = await write('u2', 'C', commit: true);
          if (useFieldReview) {
            await service.rollbackFields(
              await service.resolveFieldReviews([first, second]),
            );
          } else {
            await service.rollbackTurns(turnIds: ['u1', 'u2']);
          }
          expect(
            (await contentService.getChapterById(chapterId))!.content,
            'A',
          );
          for (final change in [first, second]) {
            expect(
              (await db.workingChangeDao.getById(change.id))!.status,
              workingChangeStatusRejected,
            );
          }
          final reverseRows = (await service.getWorkingChanges())
              .where((row) => row.source == workingChangeSourceManual)
              .toList();
          expect(reverseRows, hasLength(1));
          expect(reverseRows.single.oldText, 'C');
          expect(reverseRows.single.newText, 'A');
          final reverseCommit = (await service.getChangeCommits()).singleWhere(
            (row) => row.source == workingChangeSourceManual,
          );
          expect(
            await service.rollbackCommit(commitId: reverseCommit.id),
            RestoreResourceResult.restored,
          );
          expect(
            (await contentService.getChapterById(chapterId))!.content,
            'C',
          );
        },
      );
      for (final committed in [false, true]) {
        test(
          'dependent location renames roll back atomically review=$useFieldReview committed=$committed',
          () async {
            final locations = contentService.locationsService;
            final first = await locations.createLocation(name: 'A');
            final second = await locations.createLocation(name: 'B');
            final changes = <WorkingChange>[];
            for (final (id, before, after) in [
              (first, 'A', 'C'),
              (second, 'B', 'A'),
            ]) {
              final change = await service.stageTextChange(
                resourcePath: 'locations/$id/name',
                resourceType: 'locations',
                resourceId: id,
                field: 'name',
                oldText: before,
                newText: after,
                source: workingChangeSourceAi,
                sourceTurnId: 'u1',
              );
              if (committed) {
                await service.commitWorkingChanges(
                  [change.id],
                  source: workingChangeSourceAi,
                  message: 'accept',
                );
              }
              changes.add((await db.workingChangeDao.getById(change.id))!);
            }
            if (useFieldReview) {
              await service.rollbackFields(
                await service.resolveFieldReviews(changes),
              );
            } else {
              await service.rollbackTurns(turnIds: ['u1']);
            }
            expect((await locations.getLocationById(first))!.name, 'A');
            expect((await locations.getLocationById(second))!.name, 'B');
            for (final change in changes) {
              expect(
                (await db.workingChangeDao.getById(change.id))!.status,
                workingChangeStatusRejected,
              );
            }
          },
        );
      }
    }

    test('commit rollback restores dependent location renames', () async {
      final locations = contentService.locationsService;
      final first = await locations.createLocation(name: 'A');
      final second = await locations.createLocation(name: 'B');
      final changeIds = <String>[];
      for (final (id, before, after) in [
        (first, 'A', 'C'),
        (second, 'B', 'A'),
      ]) {
        final change = await service.stageTextChange(
          resourcePath: 'locations/$id/name',
          resourceType: 'locations',
          resourceId: id,
          field: 'name',
          oldText: before,
          newText: after,
          source: workingChangeSourceAi,
          sourceTurnId: 'u1',
        );
        changeIds.add(change.id);
      }
      final commitId = (await service.commitWorkingChanges(
        changeIds,
        source: workingChangeSourceAi,
        message: 'accept',
      ))!;
      expect(
        await service.rollbackCommit(commitId: commitId),
        RestoreResourceResult.restored,
      );
      expect((await locations.getLocationById(first))!.name, 'A');
      expect((await locations.getLocationById(second))!.name, 'B');
    });

    test(
      'continuous same turn coalesces, direct manual edit breaks segment',
      () async {
        final first = await write('u1', 'B');
        expect((await write('u1', 'C')).id, first.id);
        await contentService.updateChapterContent(
          chapterId: chapterId,
          title: 'T0',
          outline: '',
          content: 'manual',
        );
        final next = await write('u1', 'D');
        expect(next.id, isNot(first.id));
        expect(next.oldText, 'manual');
      },
    );
    test(
      'field review uses oldest baseline and real current content',
      () async {
        final first = await write('u1', 'B');
        final second = await write('u2', 'C');
        await write('other', 'outside', session: 'other-session');
        final reviews = await service.resolveFieldReviews([second, first]);
        expect(reviews, hasLength(1));
        expect(reviews.single.changes.map((row) => row.id), [
          first.id,
          second.id,
        ]);
        expect(reviews.single.oldText, 'A');
        expect(reviews.single.newText, 'outside');
        await service.rollbackFields(reviews);
        expect((await contentService.getChapterById(chapterId))!.content, 'A');
      },
    );
    test(
      'partial rollback refreshes snapshots without reviving previously reverted lines',
      () async {
        await contentService.updateChapterContent(
          chapterId: chapterId,
          title: 'T0',
          outline: '',
          content: 'a\nb\nc',
        );
        final first = await write('u1', 'A\nb\nc');
        final second = await write('u2', 'A\nB\nC');
        var review = (await service.resolveFieldReviews(
          await aiChanges(),
        )).single;
        await service.rollbackFieldLines(review, {'d:1', 'i:1'});
        expect(
          (await contentService.getChapterById(chapterId))!.content,
          'a\nB\nC',
        );
        review = (await service.resolveFieldReviews(await aiChanges())).single;
        await service.rollbackFieldLines(review, {'d:2', 'i:2'});
        expect(
          (await contentService.getChapterById(chapterId))!.content,
          'a\nb\nC',
        );
        for (final original in [first, second]) {
          final saved = (await db.workingChangeDao.getById(original.id))!;
          expect(saved.sourceTurnId, original.sourceTurnId);
          expect(saved.oldText, original.oldText);
          expect(saved.newText, original.newText);
        }
      },
    );
    test(
      'partial reverse records the displayed right snapshot after staged manual edit',
      () async {
        await contentService.updateChapterContent(
          chapterId: chapterId,
          title: 'T0',
          outline: '',
          content: 'a\nb\nc',
        );
        final ai = await write('u1', 'A\nB\nc');
        await service.stageTextChange(
          resourcePath: ai.resourcePath,
          resourceType: ai.resourceType,
          resourceId: chapterId,
          field: 'content',
          oldText: ai.newText,
          newText: 'A\nB\nmanual',
          source: workingChangeSourceManual,
        );
        final review = (await service.resolveFieldReviews([ai])).single;
        await service.rollbackFieldLines(review, {'d:1', 'i:1'});
        expect(
          (await contentService.getChapterById(chapterId))!.content,
          'a\nB\nmanual',
        );
        final reverse = (await service.getWorkingChanges()).singleWhere(
          (row) =>
              row.source == workingChangeSourceManual &&
              row.status == workingChangeStatusCommitted,
        );
        expect(reverse.oldText, 'A\nB\nmanual');
        expect(reverse.newText, 'a\nB\nmanual');
      },
    );
    test(
      'turn rollback after separately reverting creation finishes remaining history',
      () async {
        final created = await service.stageCreateChange(
          resourcePath: 'chapters/$chapterId',
          resourceType: 'chapters',
          resourceId: chapterId,
          previewText: 'T0',
          source: workingChangeSourceAi,
          sourceTurnId: 'u1',
        );
        final edited = await write('u1', 'B');
        await service.commitWorkingChanges(
          [created.id, edited.id],
          source: workingChangeSourceAi,
          message: 'accept',
        );
        await service.rollbackChange(created.id);
        expect(await contentService.getChapterById(chapterId), isNull);
        expect((await service.rollbackTurn(turnId: 'u1')).rolledBack, 1);
        expect(
          (await db.workingChangeDao.getById(edited.id))!.status,
          workingChangeStatusRejected,
        );
      },
    );
    test(
      'whole field rollback is idempotent even with the old snapshot',
      () async {
        await write('u1', 'B', commit: true);
        await write('u2', 'C');
        final reviews = await service.resolveFieldReviews(await aiChanges());
        expect((await service.rollbackFields(reviews)).rolledBack, 2);
        final historyCount = (await service.getWorkingChanges()).length;
        expect((await service.rollbackFields(reviews)).rolledBack, 0);
        expect((await service.getWorkingChanges()).length, historyCount);
        expect((await contentService.getChapterById(chapterId))!.content, 'A');
      },
    );
    test(
      'stale right snapshot restores history over later manual edits',
      () async {
        final change = await write('u1', 'B');
        final review = (await service.resolveFieldReviews([change])).single;
        await contentService.updateChapterContent(
          chapterId: chapterId,
          title: 'T0',
          outline: '',
          content: 'outside',
        );
        expect((await service.rollbackFields([review])).rolledBack, 1);
        expect(
          await service.rollbackFieldLines(review, {'d:1', 'i:1'}),
          RollbackChangeResult.noop,
        );
        expect((await contentService.getChapterById(chapterId))!.content, 'A');
        expect(
          (await db.workingChangeDao.getById(change.id))!.status,
          workingChangeStatusRejected,
        );
      },
    );
    test(
      'missing target is reported while available changes roll back',
      () async {
        final first = await write('u1', 'B');
        final missing = await contentService.createChapter(
          siblingOrder: 2,
          title: 'Missing',
        );
        final second = await service.stageTextChange(
          resourcePath: 'chapters/$missing/content',
          resourceType: 'chapters',
          resourceId: missing,
          field: 'content',
          oldText: '',
          newText: 'C',
          source: workingChangeSourceAi,
          sourceTurnId: 'u2',
        );
        await contentService.deleteChapter(missing);
        final result = await service.rollbackTurns(turnIds: ['u1', 'u2']);
        expect(result.rolledBack, 1);
        expect(result.skipped, 1);
        expect(result.skippedPaths, [second.resourcePath]);
        expect((await contentService.getChapterById(chapterId))!.content, 'A');
        expect(
          (await db.workingChangeDao.getById(first.id))!.status,
          workingChangeStatusRejected,
        );
        expect(
          (await db.workingChangeDao.getById(second.id))!.status,
          workingChangeStatusActive,
        );
      },
    );
  });

  group('rollbackTurn', () {
    test(
      'review P2-3 same-turn committed field changes preserve one net reverse snapshot',
      () async {
        final id = await contentService.createChapter(
          siblingOrder: 1,
          title: 'Chapter',
        );
        await contentService.updateChapterContent(
          chapterId: id,
          title: 'Chapter',
          outline: '',
          content: 'zero',
        );
        final originalIds = <String>[];
        for (final texts in [('zero', 'one'), ('one', 'two')]) {
          final change = await service.stageTextChange(
            resourcePath: 'chapters/$id/content',
            resourceType: 'chapters',
            resourceId: id,
            field: 'content',
            oldText: texts.$1,
            newText: texts.$2,
            source: workingChangeSourceAi,
            sourceTurnId: 'same-turn',
          );
          await service.commitWorkingChanges(
            [change.id],
            source: workingChangeSourceAi,
            message: 'same-turn piece',
          );
          originalIds.add(change.id);
          await (db.update(
            db.workingChanges,
          )..where((row) => row.id.equals(change.id))).write(
            WorkingChangesCompanion(
              updatedAt: Value(
                DateTime.utc(2020).add(Duration(seconds: originalIds.length)),
              ),
            ),
          );
        }
        expect((await service.rollbackTurn(turnId: 'same-turn')).rolledBack, 2);
        expect((await contentService.getChapterById(id))!.content, 'zero');
        final changes = await service.getWorkingChanges();
        expect(
          changes.where((r) => originalIds.contains(r.id)).map((r) => r.status),
          everyElement(workingChangeStatusRejected),
        );
        final reverse = changes
            .where((r) => r.source == workingChangeSourceManual)
            .toList();
        expect(reverse, hasLength(1));
        expect(reverse.single.status, workingChangeStatusCommitted);
        expect(reverse.single.oldText, 'two');
        expect(reverse.single.newText, 'zero');
        final reverseCommit = (await service.getChangeCommits()).singleWhere(
          (r) => r.source == workingChangeSourceManual,
        );
        final items = await service.getChangeCommitItemsForCommit(
          reverseCommit.id,
        );
        expect(items, hasLength(1));
        expect(reverseCommit.changeCount, 1);
        expect(items.single.oldText, 'two');
        expect(items.single.newText, 'zero');
        expect(
          await service.rollbackCommit(commitId: reverseCommit.id),
          RestoreResourceResult.restored,
        );
        expect((await contentService.getChapterById(id))!.content, 'two');
      },
    );

    test('rolls back active changes', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'before',
      );

      await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'before',
        newText: 'after',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );

      final result = await service.rollbackTurn(turnId: 'turn_1');

      expect(result.rolledBack, 1);

      final chapter = await contentService.getChapterById(chapterId);
      expect(chapter?.content, 'before');
    });

    test('rolls back committed changes', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'before',
      );

      final change = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'before',
        newText: 'after',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );
      await service.commitWorkingChanges(
        [change.id],
        source: workingChangeSourceAi,
        message: 'history.commit_message.manual_chapter_save',
      );

      final result = await service.rollbackTurn(turnId: 'turn_1');

      expect(result.rolledBack, 1);

      final chapter = await contentService.getChapterById(chapterId);
      expect(chapter?.content, 'before');
    });

    test('restores historical target after a later manual edit', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'before',
      );

      final change = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'before',
        newText: 'after ai',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );
      await service.commitWorkingChanges(
        [change.id],
        source: workingChangeSourceAi,
        message: 'history.commit_message.manual_chapter_save',
      );

      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'after manual edit',
      );

      final result = await service.rollbackTurn(turnId: 'turn_1');

      expect(result.rolledBack, 1);
      final chapter = await contentService.getChapterById(chapterId);
      expect(chapter?.content, 'before');
    });

    test('turn rollback overwrites later edits without an override', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'before',
      );

      final change = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'before',
        newText: 'after ai',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );
      await service.commitWorkingChanges(
        [change.id],
        source: workingChangeSourceAi,
        message: 'history.commit_message.manual_chapter_save',
      );

      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'after manual edit',
      );

      final result = await service.rollbackTurn(turnId: 'turn_1');

      expect(result.rolledBack, 1);

      final chapter = await contentService.getChapterById(chapterId);
      expect(chapter?.content, 'before');
    });

    test('returns empty result when no changes match turnId', () async {
      final result = await service.rollbackTurn(turnId: 'nonexistent');

      expect(result.rolledBack, 0);

      expect(result.skipped, 0);
    });

    test(
      'marks rolled-back committed change as rejected (idempotent)',
      () async {
        final chapterId = await contentService.createChapter(
          siblingOrder: 1,
          title: 'Chapter 1',
        );
        await contentService.updateChapterContent(
          chapterId: chapterId,
          title: 'Chapter 1',
          outline: '',
          content: 'before',
        );

        final change = await service.stageTextChange(
          resourcePath: '/chapters/$chapterId/content',
          resourceType: 'chapters',
          resourceId: chapterId,
          field: 'content',
          oldText: 'before',
          newText: 'after',
          source: workingChangeSourceAi,
          sourceTurnId: 'turn_1',
        );
        await service.commitWorkingChanges(
          [change.id],
          source: workingChangeSourceAi,
          message: 'history.commit_message.manual_chapter_save',
        );

        await service.rollbackTurn(turnId: 'turn_1');

        // 原 committed 行被标记 rejected：不再出现在「待回退」态。
        final after = await db.workingChangeDao.getById(change.id);
        expect(after?.status, workingChangeStatusRejected);

        // 二次回退幂等：不再反写、不破坏正文。
        final second = await service.rollbackTurn(turnId: 'turn_1');
        expect(second.rolledBack, 0);

        final chapter = await contentService.getChapterById(chapterId);
        expect(chapter?.content, 'before');
      },
    );
  });

  group('rollbackChange', () {
    Future<({String changeId, String chapterId})> commitAiChange({
      required String oldText,
      required String newText,
    }) async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: oldText,
      );
      final change = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: oldText,
        newText: newText,
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );
      await service.commitWorkingChanges(
        [change.id],
        source: workingChangeSourceAi,
        message: 'history.commit_message.manual_chapter_save',
      );
      return (changeId: change.id, chapterId: chapterId);
    }

    test('rolls back a committed create change', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      final change = await service.stageCreateChange(
        resourcePath: '/chapters/$chapterId',
        resourceType: 'chapters',
        resourceId: chapterId,
        previewText: 'Chapter 1',
        source: workingChangeSourceAi,
      );
      await service.commitWorkingChanges(
        [change.id],
        source: workingChangeSourceAi,
        message: 'history.commit_message.auto_commit_ai_changes',
      );

      final result = await service.rollbackChange(change.id);

      expect(result, RollbackChangeResult.rolledBack);
      expect(await contentService.getChapterById(chapterId), isNull);
      expect(
        (await service.getWorkingChangeById(change.id))?.status,
        workingChangeStatusRejected,
      );
    });

    test('rolls back a committed change and marks it rejected', () async {
      final c = await commitAiChange(oldText: 'before', newText: 'after');

      final result = await service.rollbackChange(c.changeId);

      expect(result, RollbackChangeResult.rolledBack);
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, 'before');
      final after = await db.workingChangeDao.getById(c.changeId);
      expect(after?.status, workingChangeStatusRejected);
    });

    test('restores old text when field changed after AI edit', () async {
      final c = await commitAiChange(oldText: 'before', newText: 'after ai');
      await contentService.updateChapterContent(
        chapterId: c.chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'after manual edit',
      );

      final result = await service.rollbackChange(c.changeId);

      expect(result, RollbackChangeResult.rolledBack);
      // 回退仅恢复该字段的历史目标。
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, 'before');
    });

    test('single rollback overwrites the later manual edit', () async {
      final c = await commitAiChange(oldText: 'before', newText: 'after ai');
      await contentService.updateChapterContent(
        chapterId: c.chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'after manual edit',
      );

      final result = await service.rollbackChange(c.changeId);

      expect(result, RollbackChangeResult.rolledBack);
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, 'before');
    });
  });

  group('rollbackChangeLines', () {
    // old: [l1, l2, l3] → new: [l1, L2, l3, l4]
    // diff: context l1 | -l2(d:2) +L2(i:2) | context l3 | +l4(i:4)
    const oldText = 'l1\nl2\nl3';
    const newText = 'l1\nL2\nl3\nl4';

    Future<({String changeId, String chapterId})> stageAiChange({
      bool commit = true,
    }) async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: oldText,
      );
      final change = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: oldText,
        newText: newText,
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );
      if (commit) {
        await service.commitWorkingChanges(
          [change.id],
          source: workingChangeSourceAi,
          message: 'history.commit_message.auto_commit_ai_changes',
        );
      }
      return (changeId: change.id, chapterId: chapterId);
    }

    test('部分退回只恢复被退回的行，原 change 保持 committed', () async {
      final c = await stageAiChange();

      final result = await service.rollbackChangeLines(c.changeId, {'i:4'});

      expect(result, RollbackChangeResult.rolledBack);
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, 'l1\nL2\nl3');
      final original = await db.workingChangeDao.getById(c.changeId);
      expect(original?.status, workingChangeStatusCommitted);
      final commits = await db.changeCommitDao.getAll();
      final reverse = commits.where(
        (commit) =>
            commit.message == 'history.commit_message.rollback_change_lines',
      );
      expect(reverse.length, 1);
      final items = await db.changeCommitDao.getItemsByCommit(reverse.first.id);
      expect(items.single.oldText, newText);
      expect(items.single.newText, 'l1\nL2\nl3');
    });

    test(
      'review P2 active partial-line missing target leaves all history unchanged',
      () async {
        final c = await stageAiChange(commit: false);
        await contentService.deleteChapter(c.chapterId);
        Future<List<Object>> history() async => [
          (await db.select(db.workingChanges).get())
              .map((r) => r.toJson())
              .toList(),
          (await db.select(db.changeCommits).get())
              .map((r) => r.toJson())
              .toList(),
          (await db.select(db.changeCommitItems).get())
              .map((r) => r.toJson())
              .toList(),
        ];
        final before = await history();
        expect(
          await service.rollbackChangeLines(c.changeId, {'i:4'}),
          RollbackChangeResult.skipped,
        );
        expect(await history(), before);
      },
    );

    test('重复按行回退已在目标状态时不新增改动', () async {
      final c = await stageAiChange();
      await service.rollbackChangeLines(c.changeId, {'i:4'});
      final changes = (await service.getWorkingChanges())
          .map((r) => r.toJson())
          .toList();
      final commits = (await service.getChangeCommits())
          .map((r) => r.toJson())
          .toList();
      expect(
        await service.rollbackChangeLines(c.changeId, {'i:4'}),
        RollbackChangeResult.noop,
      );
      expect(
        (await service.getWorkingChanges()).map((r) => r.toJson()).toList(),
        changes,
      );
      expect(
        (await service.getChangeCommits()).map((r) => r.toJson()).toList(),
        commits,
      );
    });

    test('无有效退回行时 noop，内容不变', () async {
      final c = await stageAiChange();

      final result = await service.rollbackChangeLines(c.changeId, {'d:99'});

      expect(result, RollbackChangeResult.noop);
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, newText);
    });

    test('空退回集合 noop', () async {
      final c = await stageAiChange();

      final result = await service.rollbackChangeLines(c.changeId, const {});

      expect(result, RollbackChangeResult.noop);
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, newText);
    });

    test('全部退回委托整条回退，原 change 标记 rejected', () async {
      final c = await stageAiChange();

      final result = await service.rollbackChangeLines(c.changeId, {
        'd:2',
        'i:2',
        'i:4',
      });

      expect(result, RollbackChangeResult.rolledBack);
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, oldText);
      final original = await db.workingChangeDao.getById(c.changeId);
      expect(original?.status, workingChangeStatusRejected);
    });

    test('AI 改动后字段被手改仍恢复选中行的历史目标', () async {
      final c = await stageAiChange();
      await contentService.updateChapterContent(
        chapterId: c.chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'after manual edit',
      );

      final result = await service.rollbackChangeLines(c.changeId, {'i:4'});

      expect(result, RollbackChangeResult.rolledBack);
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, 'l1\nL2\nl3');
    });

    test('按行回退覆盖手改并写入目标文本', () async {
      final c = await stageAiChange();
      await contentService.updateChapterContent(
        chapterId: c.chapterId,
        title: 'Chapter 1',
        outline: '',
        content: 'after manual edit',
      );

      final result = await service.rollbackChangeLines(c.changeId, {'i:4'});

      expect(result, RollbackChangeResult.rolledBack);
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, 'l1\nL2\nl3');
    });

    test('active 的 change 先提交规范化再按行回退', () async {
      final c = await stageAiChange(commit: false);

      final result = await service.rollbackChangeLines(c.changeId, {'i:4'});

      expect(result, RollbackChangeResult.rolledBack);
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, 'l1\nL2\nl3');
      final original = await db.workingChangeDao.getById(c.changeId);
      expect(original?.status, workingChangeStatusCommitted);
      final commits = await db.changeCommitDao.getAll();
      final messages = commits.map((commit) => commit.message).toSet();
      expect(
        messages,
        containsAll([
          'history.commit_message.auto_commit_ai_changes',
          'history.commit_message.rollback_change_lines',
        ]),
      );
    });

    test('会话内二次退回按累计选中行恢复历史目标', () async {
      final c = await stageAiChange();
      await service.rollbackChangeLines(c.changeId, {'i:4'});

      // rejectedLineKeys 传全量退回集合，目标合成后为 oldText。
      final result = await service.rollbackChangeLines(c.changeId, {
        'd:2',
        'i:2',
        'i:4',
      });

      expect(result, RollbackChangeResult.rolledBack);
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, oldText);
      final original = await db.workingChangeDao.getById(c.changeId);
      expect(original?.status, workingChangeStatusRejected);
    });

    test('二次退回直接按累计选择恢复历史目标', () async {
      final c = await stageAiChange();
      await service.rollbackChangeLines(c.changeId, {'i:4'});

      final result = await service.rollbackChangeLines(c.changeId, {
        'd:2',
        'i:2',
        'i:4',
      });

      expect(result, RollbackChangeResult.rolledBack);
      final chapter = await contentService.getChapterById(c.chapterId);
      expect(chapter?.content, oldText);
    });

    test('二次部分退回（非全量）写出累计选中行目标', () async {
      // old: [l1, l2, l3, l4] → new: [l1, L2, l3, L4, l5]
      // rows: (l2→L2) [d:2,i:2] | (l4→L4) [d:4,i:4] | (+l5) [i:5]
      const richOld = 'l1\nl2\nl3\nl4';
      const richNew = 'l1\nL2\nl3\nL4\nl5';
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: '',
        content: richOld,
      );
      final change = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: richOld,
        newText: richNew,
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );
      await service.commitWorkingChanges(
        [change.id],
        source: workingChangeSourceAi,
        message: 'history.commit_message.auto_commit_ai_changes',
      );
      await service.rollbackChangeLines(change.id, {'d:2', 'i:2'});

      final result = await service.rollbackChangeLines(change.id, {
        'd:2',
        'i:2',
        'd:4',
        'i:4',
      });

      expect(result, RollbackChangeResult.rolledBack);
      final chapter = await contentService.getChapterById(chapterId);
      expect(chapter?.content, 'l1\nl2\nl3\nl4\nl5');
    });
  });

  // 取代被删的 auto_accept_commit_test：一轮 agent turn 的多笔 AI 改动应折叠成单个 commit。
  group('auto-accept turn commit folding', () {
    test('multiple AI changes in one turn fold into a single commit', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: 'Chapter 1',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: 'Chapter 1',
        outline: 'outline before',
        content: 'content before',
      );

      final contentChange = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/content',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'content',
        oldText: 'content before',
        newText: 'content after',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );
      final outlineChange = await service.stageTextChange(
        resourcePath: '/chapters/$chapterId/outline',
        resourceType: 'chapters',
        resourceId: chapterId,
        field: 'outline',
        oldText: 'outline before',
        newText: 'outline after',
        source: workingChangeSourceAi,
        sourceTurnId: 'turn_1',
      );

      final commitId = await service.commitWorkingChanges(
        [contentChange.id, outlineChange.id],
        source: workingChangeSourceAi,
        message: 'history.commit_message.auto_commit_ai_changes',
      );

      expect(commitId, isNotNull);
      final commits = await db.changeCommitDao.getAll();
      expect(commits, hasLength(1));
      final items = await db.changeCommitDao.getItemsByCommit(commitId!);
      expect(items, hasLength(2));
    });
  });

  group('commitActiveAiChangesForSession', () {
    test(
      'queries current changes and commits only the target AI session',
      () async {
        expect(await service.getWorkingChanges(), isEmpty);

        final targetChange = await service.stageCreateChange(
          resourcePath: '/test/target',
          resourceType: 'test',
          resourceId: 'target',
          previewText: 'target',
          source: workingChangeSourceAi,
          sourceSessionId: 'session_target',
        );
        final otherSessionChange = await service.stageCreateChange(
          resourcePath: '/test/other',
          resourceType: 'test',
          resourceId: 'other',
          previewText: 'other',
          source: workingChangeSourceAi,
          sourceSessionId: 'session_other',
        );
        final manualChange = await service.stageCreateChange(
          resourcePath: '/test/manual',
          resourceType: 'test',
          resourceId: 'manual',
          previewText: 'manual',
          source: workingChangeSourceManual,
          sourceSessionId: 'session_target',
        );

        final commitId = await service.commitActiveAiChangesForSession(
          'session_target',
          message: 'history.commit_message.auto_commit_ai_changes',
        );

        expect(commitId, isNotNull);
        expect(
          (await db.workingChangeDao.getById(targetChange.id))?.status,
          workingChangeStatusCommitted,
        );
        expect(
          (await db.workingChangeDao.getById(otherSessionChange.id))?.status,
          workingChangeStatusActive,
        );
        expect(
          (await db.workingChangeDao.getById(manualChange.id))?.status,
          workingChangeStatusActive,
        );
      },
    );
  });
}
