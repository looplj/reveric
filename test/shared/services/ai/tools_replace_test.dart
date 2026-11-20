// 职责: 测试 Replace AI 工具，验证跨资源正则替换的预览、写入和回滚行为。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_replace.dart
//   lib/shared/services/ai/tools_edit.dart
//   lib/shared/services/working_overlay.dart

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/screenplay_element.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  group('Replace tool', () {
    late NovelContentDatabase db;
    late AppDatabase appDb;
    late NovelContentService contentService;
    late WorkingOverlayService overlay;
    late AiToolManager toolManager;

    setUp(() {
      db = NovelContentDatabase.forTest(NativeDatabase.memory());
      appDb = AppDatabase.forTest(NativeDatabase.memory());
      contentService = NovelContentService(db);
      overlay = WorkingOverlayService(
        db,
        contentService,
        novelActionsService: NovelActionsService(appDb),
      );
      toolManager = AiToolManager(
        contentService,
        workingOverlayService: overlay,
      )..registerAllTools();
    });

    tearDown(() async {
      await db.close();
      await appDb.close();
    });

    Future<String> createChapterWithContent(
      String content, {
      int order = 1,
    }) async {
      final id = await contentService.createChapter(
        siblingOrder: order,
        title: '第$order章',
      );
      await contentService.updateChapterContent(
        chapterId: id,
        title: '第$order章',
        outline: '',
        content: content,
      );
      return id;
    }

    Future<String> readChapterContent(String id) async {
      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters/$id/content'},
      );
      return result['value'] as String;
    }

    Future<List<String>> screenplayFixture() async {
      final service = ScreenplayService(db);
      final initial = await service.createInitialStructure();
      final root = (await db.screenplayDao.getRoot())!;
      await service.updateSeason(seasonId: initial.seasonId, title: '线索季');
      await service.updateEpisode(episodeId: initial.episodeId, title: '线索集');
      await service.updateEpisodeOutline(
        episodeId: initial.episodeId,
        outline: '线索大纲',
      );
      await service.createBeat(
        screenplayId: root.id,
        episodeId: initial.episodeId,
        actNumber: 1,
        title: '线索节拍',
        description: '线索说明',
      );
      final character = await contentService.createCharacterProfile(
        defaultName: '线索人物',
      );
      final scenes = <String>[];
      for (var i = 0; i < 2; i++) {
        final scene = await service.createScene(
          screenplayId: root.id,
          episodeId: initial.episodeId,
          synopsis: '线索梗概$i',
          timeLabel: '线索时间',
        );
        scenes.add(scene);
        await service.writeElements(
          sceneId: scene,
          elements: [
            ScreenplayElement(
              id: '',
              type: ScreenplayElementType.action,
              text: '线索动作$i',
            ),
            ScreenplayElement(
              id: '',
              type: ScreenplayElementType.character,
              characterId: character,
              extension: 'V.O.',
            ),
            ScreenplayElement(
              id: '',
              type: ScreenplayElementType.parenthetical,
              text: '线索提示$i',
            ),
            ScreenplayElement(
              id: '',
              type: ScreenplayElementType.dialogue,
              text: '线索台词$i',
            ),
          ],
        );
      }
      toolManager = AiToolManager(
        contentService,
        workingOverlayService: overlay,
        contentKind: contentKindScreenplay,
        sessionId: 'screenplay_session',
      )..registerAllTools();
      return scenes;
    }

    test(
      'screenplay preview and execution share edit permissions, accumulate scene edits and undo',
      () async {
        final scenes = await screenplayFixture();
        final episodeId = (await db.screenplayDao.getScene(
          scenes.first,
        ))!.episodeId;
        final beatId = (await db.screenplayDao.getBeatRows(
          episodeId,
        )).single.id;
        final original = {
          for (final scene in scenes)
            scene: await db.screenplayDao.getElementRows(scene),
        };
        final cast = {
          for (final scene in scenes)
            scene: await db.screenplayDao.getSceneCharacters(scene),
        };
        const input = {
          'path': '/',
          'glob': '{seasons,episodes,scenes}/**',
          'pattern': '线索',
          'replacement': '新词',
        };
        final preview = await toolManager.executeTool(
          name: 'Replace',
          input: input,
        );
        expect(preview['matched_fields'], 9, reason: '$preview');
        expect(preview['total_matches'], 9);
        expect(preview['skipped_fields'], {'not_editable': 5});
        expect((await db.screenplayDao.getEpisode(episodeId))!.outline, '线索大纲');
        expect((await db.screenplayDao.getBeat(beatId))!.description, '线索说明');
        expect(await overlay.getWorkingChanges(), isEmpty);
        for (final scene in scenes) {
          expect(await db.screenplayDao.getElementRows(scene), original[scene]);
        }
        final result = await toolManager.executeTool(
          name: 'Replace',
          input: {...input, 'dry_run': false},
        );
        expect(result['applied_fields'], 9, reason: '$result');
        expect(result['total_replacements'], 9);
        expect((await db.screenplayDao.getEpisode(episodeId))!.outline, '新词大纲');
        expect((await db.screenplayDao.getBeat(beatId))!.description, '线索说明');
        expect(result['failed'], isNull);
        expect(result['skipped_fields'], preview['skipped_fields']);
        for (final scene in scenes) {
          final rows = await db.screenplayDao.getElementRows(scene);
          expect(
            rows.map(
              (row) => (
                row.id,
                row.type,
                row.characterId,
                row.extension,
                row.sortOrder,
              ),
            ),
            original[scene]!.map(
              (row) => (
                row.id,
                row.type,
                row.characterId,
                row.extension,
                row.sortOrder,
              ),
            ),
          );
          expect(
            rows.map((row) => row.textContent),
            original[scene]!.map(
              (row) => row.textContent.replaceAll('线索', '新词'),
            ),
          );
          expect(
            (await db.screenplayDao.getScene(scene))!.synopsis,
            startsWith('新词梗概'),
          );
          expect((await db.screenplayDao.getScene(scene))!.timeLabel, '线索时间');
          expect(await db.screenplayDao.getSceneCharacters(scene), cast[scene]);
        }
        final changes = await overlay.getWorkingChanges();
        expect(changes, hasLength(5));
        expect(
          changes.map((change) => change.resourcePath),
          contains('episodes/$episodeId/outline'),
        );
        expect(
          changes.map((change) => change.toolName),
          everyElement('Replace'),
        );
        expect(
          changes.map((change) => change.sourceSessionId),
          everyElement('screenplay_session'),
        );
        for (final change in changes) {
          await overlay.rejectWorkingChange(change.id);
        }
        expect((await db.screenplayDao.getEpisode(episodeId))!.outline, '线索大纲');
        // 旧节拍不再暴露给 AI 资源树，替换和驳回都不应修改它。
        expect((await db.screenplayDao.getBeat(beatId))!.description, '线索说明');
        for (final scene in scenes) {
          expect(
            (await db.screenplayDao.getElementRows(
              scene,
            )).map((row) => row.textContent),
            original[scene]!.map((row) => row.textContent),
          );
          expect(
            (await db.screenplayDao.getScene(scene))!.synopsis,
            startsWith('线索梗概'),
          );
        }
      },
    );

    test(
      'screenplay missing session and another session conflict are counted per field',
      () async {
        final scenes = await screenplayFixture();
        final noSession = AiToolManager(
          contentService,
          workingOverlayService: overlay,
          contentKind: contentKindScreenplay,
        )..registerAllTools();
        final missing = await noSession.executeTool(
          name: 'Replace',
          input: {
            'path': 'scenes',
            'pattern': '线索',
            'replacement': '新词',
            'dry_run': false,
          },
        );
        expect(missing['applied_fields'], 0);
        expect((missing['failed'] as Map)['unavailable']['count'], 8);
        expect(await overlay.getWorkingChanges(), isEmpty);
        final locked = scenes.first;
        final element = (await db.screenplayDao.getElementRows(locked)).first;
        final edit = await toolManager.executeTool(
          name: 'Edit',
          input: {
            'path': 'scenes/$locked/elements/${element.id}/text',
            'old_text': '线索',
            'new_text': '线索已改',
          },
        );
        expect(edit['ok'], isTrue);
        final otherSession = AiToolManager(
          contentService,
          workingOverlayService: overlay,
          contentKind: contentKindScreenplay,
          sessionId: 'other_session',
        )..registerAllTools();
        final result = await otherSession.executeTool(
          name: 'Replace',
          input: {
            'path': 'scenes',
            'pattern': '线索',
            'replacement': '新词',
            'dry_run': false,
          },
        );
        // 现有跨会话锁只保护 elements；synopsis 沿用独立字段权限。
        expect(result['applied_fields'], 5, reason: '$result');
        final failed = (result['failed'] as Map)['conflict'] as Map;
        expect(failed['count'], 3);
        expect(
          (failed['sample_paths'] as List).every(
            (path) => (path as String).startsWith('scenes/$locked/'),
          ),
          isTrue,
        );
        expect((await db.screenplayDao.getScene(locked))!.synopsis, '新词梗概0');
        expect(
          (await db.screenplayDao.getElementRows(locked)).first.textContent,
          '线索已改动作0',
        );
      },
    );

    test('defaults to dry run without staging a working change', () async {
      final id = await createChapterWithContent('李明走进院子。');

      final result = await toolManager.executeTool(
        name: 'Replace',
        input: {
          'pattern': '李明',
          'replacement': '李泽明',
          'path': 'chapters/$id/content',
        },
      );

      expect(result['ok'], isTrue);
      expect(result['dry_run'], isTrue);
      expect(result['matched_fields'], 1);
      expect(await readChapterContent(id), '李明走进院子。');
      expect(await overlay.getWorkingChanges(), isEmpty);
    });

    test(
      'dry run samples list every variant so prefix collisions stay visible',
      () async {
        final first = await createChapterWithContent('李明说话。李明说话。');
        await createChapterWithContent('李明月抬起头。', order: 2);

        final result = await toolManager.executeTool(
          name: 'Replace',
          input: {
            'pattern': '李明',
            'replacement': '李泽明',
            'glob': 'chapters/*/content',
          },
        );

        expect(result['matched_fields'], 2);
        expect(result['total_matches'], 3);
        // 变体 = 匹配串 + 后 2 字，按出现次数倒序，全部列出。
        expect(result['samples'], ['李明说话 2', '李明月抬 1']);
        expect(await readChapterContent(first), '李明说话。李明说话。');
      },
    );

    test('reports pattern_too_broad instead of truncating variants', () async {
      // 每个数字都是一个不同的变体，1100 > 变体上限 1000。
      final id = await createChapterWithContent(
        List.generate(1100, (index) => '$index').join(' '),
      );

      final result = await toolManager.executeTool(
        name: 'Replace',
        input: {
          'pattern': r'\d+',
          'replacement': 'n',
          'path': 'chapters/$id/content',
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'resource_exhausted');
      expect(result['samples'], isNull);
      expect(result['total_matches'], 1100);
    });

    test(
      'negative lookahead replaces each target field and keeps prefix names',
      () async {
        final first = await createChapterWithContent('李明说话，李明月旁观。');
        final second = await createChapterWithContent('李明离开。', order: 2);

        final result = await toolManager.executeTool(
          name: 'Replace',
          input: {
            'pattern': '李明(?!月)',
            'replacement': '李泽明',
            'glob': 'chapters/*/content',
            'dry_run': false,
          },
        );

        expect(result['ok'], isTrue);
        expect(result['applied_fields'], 2);
        expect(result['total_replacements'], 2);
        expect(await readChapterContent(first), '李泽明说话，李明月旁观。');
        expect(await readChapterContent(second), '李泽明离开。');
        final changes = await overlay.getWorkingChanges();
        expect(changes, hasLength(2));
        // 复用 Edit 的落库管线，但归因必须是 Replace。
        expect(
          changes.map((change) => change.toolName),
          everyElement('Replace'),
        );
        for (final change in changes) {
          await overlay.rejectWorkingChange(change.id);
        }
        expect(await readChapterContent(first), '李明说话，李明月旁观。');
        expect(await readChapterContent(second), '李明离开。');
      },
    );

    test(
      'expands capture groups and keeps literal replacement text literal',
      () async {
        final id = await createChapterWithContent("'第一句'，'第二句'");

        final grouped = await toolManager.executeTool(
          name: 'Replace',
          input: {
            'pattern': "'([^']*)'",
            'replacement': '"\$1"',
            'path': 'chapters/$id/content',
            'dry_run': false,
          },
        );

        expect(grouped['total_replacements'], 2);
        expect(await readChapterContent(id), '"第一句"，"第二句"');
        final groupedChange = (await overlay.getWorkingChanges()).single;
        await overlay.rejectWorkingChange(groupedChange.id);

        await contentService.updateChapterContent(
          chapterId: id,
          title: '第1章',
          outline: '',
          content: 'a.b',
        );

        final literal = await toolManager.executeTool(
          name: 'Replace',
          input: {
            'pattern': 'a.b',
            'replacement': r'$1',
            'path': 'chapters/$id/content',
            'literal': true,
            'dry_run': false,
          },
        );

        expect(literal['total_replacements'], 1);
        expect(literal['applied_fields'], 1);
        expect(await readChapterContent(id), r'$1');
      },
    );

    test(
      'skips published chapters but applies other matching fields',
      () async {
        final editable = await createChapterWithContent('李明出现。');
        final published = await createChapterWithContent('李明已经发布。', order: 2);
        await contentService.updateChapterStat(
          chapterId: published,
          stat: chapterStatPublished,
        );

        final result = await toolManager.executeTool(
          name: 'Replace',
          input: {
            'pattern': '李明',
            'replacement': '李泽明',
            'glob': 'chapters/*/content',
            'dry_run': false,
          },
        );

        final failed = result['failed'] as Map<dynamic, dynamic>;
        expect(result['applied_fields'], 1);
        expect(failed['locked']['count'], 1);
        expect(await readChapterContent(editable), '李泽明出现。');
        expect(await readChapterContent(published), '李明已经发布。');
      },
    );

    test('filters non-editable fields before matching them', () async {
      final id = await createChapterWithContent('正文没有目标。');
      final character = await contentService.createCharacterProfile(
        name: '角色',
        aliases: const ['李明'],
      );

      final result = await toolManager.executeTool(
        name: 'Replace',
        input: {
          'pattern': '李明',
          'replacement': '李泽明',
          'glob': '/{chapters,characters}/*/*',
        },
      );

      expect(result['matched_fields'], 0);
      expect(result['skipped_fields']['not_editable'], greaterThan(0));
      expect(result['failed'], isNull);
      expect(await readChapterContent(id), '正文没有目标。');
      expect(character, isNotEmpty);
    });

    test('rewrites the story_state snapshot in place', () async {
      final seeded = await toolManager.executeTool(
        name: 'Write',
        input: {
          'path': 'story_state',
          'fields': {'content': '林越持有卖身契，李明尚未登场。'},
        },
      );
      expect(seeded['updated'], isTrue);

      final preview = await toolManager.executeTool(
        name: 'Replace',
        input: {'pattern': '李明', 'replacement': '李泽明', 'path': 'story_state'},
      );
      expect(preview['matched_fields'], 1);
      expect(preview['total_matches'], 1);

      final applied = await toolManager.executeTool(
        name: 'Replace',
        input: {
          'pattern': '李明',
          'replacement': '李泽明',
          'path': 'story_state',
          'dry_run': false,
        },
      );
      expect(applied['ok'], isTrue);
      expect(applied['applied_fields'], 1);
      expect(applied['failed'], isNull);

      final read = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'story_state'},
      );
      expect(read['content'], '林越持有卖身契，李泽明尚未登场。');
      // 当前快照更新，不产生 working change。
      expect(await overlay.getWorkingChanges(), isEmpty);
    });

    test(
      'rejects missing scope and invalid patterns without scanning',
      () async {
        final missingScope = await toolManager.executeTool(
          name: 'Replace',
          input: {'pattern': '李明', 'replacement': '李泽明'},
        );
        final invalidPattern = await toolManager.executeTool(
          name: 'Replace',
          input: {'pattern': '(', 'replacement': '李泽明', 'path': 'chapters'},
        );

        expect(missingScope['error_code'], 'invalid_argument');
        expect(invalidPattern['error_code'], 'invalid_argument');
      },
    );

    test('covers every chapter past the shared scan budget', () async {
      // 1200 章 × 13 个路径远超 Glob/Grep 的 5000 条扫描预算；Replace 不设预算，
      // 且 glob 下推后每章只占 1 个名额，必须一章不漏。
      const total = 1200;
      final now = DateTime.now();
      await db.batch((batch) {
        for (var index = 0; index < total; index += 1) {
          batch.insert(
            db.chapters,
            ChaptersCompanion.insert(
              id: 'replace-scan-$index',
              type: nodeTypeChapter,
              siblingOrder: index,
              title: Value('第$index章'),
              outline: const Value(''),
              content: const Value('李明出现。'),
              wordCount: const Value(1),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
        }
      });

      final preview = await toolManager.executeTool(
        name: 'Replace',
        input: {
          'pattern': '李明',
          'replacement': '李泽明',
          'glob': 'chapters/*/content',
        },
      );

      expect(preview['matched_fields'], total);
      expect(preview['total_matches'], total);
      expect(preview['scan_truncated'], isNull);

      final applied = await toolManager.executeTool(
        name: 'Replace',
        input: {
          'pattern': '李明',
          'replacement': '李泽明',
          'glob': 'chapters/*/content',
          'dry_run': false,
        },
      );

      expect(applied['applied_fields'], total);
      expect(applied['failed'], isNull);
      expect(await readChapterContent('replace-scan-0'), '李泽明出现。');
      expect(await readChapterContent('replace-scan-${total - 1}'), '李泽明出现。');
    });

    test('is rejected by every read-only special session mode', () {
      for (final mode in [
        AiSessionMode.council,
        AiSessionMode.monologue,
        AiSessionMode.theater,
        AiSessionMode.roleplay,
      ]) {
        expect(mode.canUseTool('Replace'), isFalse, reason: mode.name);
      }
    });
  });
}
