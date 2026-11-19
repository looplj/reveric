// 职责: 测试 Grep AI 工具，验证它基于资源路径搜索 Read 可见文本字段。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_grep.dart
//   lib/shared/services/ai/tools_resource_search_support.dart

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import '../../../helpers/working_change_test_helper.dart';

void main() {
  group('Grep tool', () {
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
        workId: 'current',
      )..registerAllTools();
    });

    tearDown(() async {
      await db.close();
      await appDb.close();
    });

    // relations 不进扫描范围：它的 listing 是全量的（连 proof 都返回），Grep 能
    // 搜到的每个字 `/relations` 一次就给完了。展开成路径只是同一份数据的第二个
    // 副本，还按每条关系 7 条的速度吃扫描预算。
    test('relations 不进 Grep 扫描范围，listing 直接给出 proof', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '第一章',
      );
      final source = await contentService.createCharacterProfile(
        defaultName: '张三',
      );
      final target = await contentService.createCharacterProfile(
        defaultName: '李四',
      );
      await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'relations',
          'fields': {
            'source_type': 'character',
            'source_id': source,
            'target_type': 'character',
            'target_id': target,
            'relation_type': 'friend',
            'chapter_id': chapterId,
            'proof': '雪夜里两人共饮。',
          },
        },
      );

      final grep = await toolManager.executeTool(
        name: 'Grep',
        input: {'pattern': '雪夜', 'path': '/'},
        callId: 'call_grep_relation_proof',
      );
      expect(grep['text'], 'No results found.');
      // 没冲着 relations 去，不该冒出 relations 的提示。
      expect(grep['hint'], isNull);

      final scoped = await toolManager.executeTool(
        name: 'Grep',
        input: {'pattern': '雪夜', 'path': 'relations'},
        callId: 'call_grep_relation_scoped',
      );
      expect(scoped['hint'], contains('GraphSearch'));

      final listing = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'relations'},
        callId: 'call_read_relations_listing',
      );
      final entries = listing['entries'] as List<dynamic>;
      expect(entries.single['proof'], '雪夜里两人共饮。');
    });

    test('finds matches in resource text fields', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '第一章',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: '第一章',
        outline: '主角第一次看见蓝色火焰。',
        content: '他推开门。\n蓝色火焰在井口燃烧。\n他记住了这个伏笔。',
      );

      final result = await toolManager.executeTool(
        name: 'Grep',
        input: {
          'pattern': '蓝色火焰',
          'path': 'chapters',
          'output_mode': 'content',
        },
        callId: 'call_grep_chapter_content_test',
      );

      expect(result['ok'], isTrue);
      expect(result['truncated'], isFalse);
      expect(result['text'], contains('chapters/$chapterId/outline:1:'));
      expect(result['text'], contains('chapters/$chapterId/content:2:'));
    });

    test('defaults to content output with line numbers', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '第一章',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: '第一章',
        outline: '',
        content: '第一行\n目标线索\n第三行',
      );

      final result = await toolManager.executeTool(
        name: 'Grep',
        input: {'pattern': '目标线索', 'path': 'chapters/$chapterId/content'},
        callId: 'call_grep_default_content_line_number_test',
      );

      expect(result['ok'], isTrue);
      expect(result['text'], 'chapters/$chapterId/content:2:目标线索\n');
    });

    test(
      'searches write patch text immediately and reject reverts it',
      () async {
        final chapterId = await contentService.createChapter(
          siblingOrder: 1,
          title: '第一章',
        );
        await contentService.updateChapterContent(
          chapterId: chapterId,
          title: '第一章',
          outline: '',
          content: '旧正文',
        );

        await toolManager.executeTool(
          name: 'Write',
          input: {'path': 'chapters/$chapterId/content', 'value': '临时伏笔尚未提交'},
          callId: 'call_grep_working_overlay_write_test',
        );

        final result = await toolManager.executeTool(
          name: 'Grep',
          input: {
            'pattern': '临时伏笔',
            'path': 'chapters/$chapterId',
            'output_mode': 'files_with_matches',
          },
          callId: 'call_grep_working_overlay_test',
        );

        expect(result['ok'], isTrue);
        expect(result['text'], 'chapters/$chapterId/content\n');

        await overlay.rejectWorkingChange(await onlyActiveWorkingChangeId(db));

        final afterReject = await toolManager.executeTool(
          name: 'Grep',
          input: {
            'pattern': '临时伏笔',
            'path': 'chapters/$chapterId',
            'output_mode': 'files_with_matches',
          },
          callId: 'call_grep_reverted_write_test',
        );

        expect(afterReject['ok'], isTrue);
        expect(afterReject['text'], 'No results found.');
      },
    );

    test('supports glob filters for searched resource paths', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '第一章',
      );
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: '第一章',
        outline: '只在大纲出现的关键词',
        content: '正文没有目标词',
      );

      final result = await toolManager.executeTool(
        name: 'Grep',
        input: {
          'pattern': '关键词',
          'path': 'chapters',
          'glob': 'chapters/*/content',
        },
        callId: 'call_grep_glob_filter_test',
      );

      expect(result['ok'], isTrue);
      expect(result['text'], 'No results found.');
    });

    test('returns a structured error for invalid glob filters', () async {
      final result = await toolManager.executeTool(
        name: 'Grep',
        input: {'pattern': '关键词', 'glob': 'chapters/[z-a]/content'},
        callId: 'call_grep_invalid_glob_test',
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(result['error'], contains('Invalid glob pattern'));
    });

    test('count mode reports full per-file match counts', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '第一章',
      );
      final content = List.generate(25, (_) => '重复关键词').join('\n');
      await contentService.updateChapterContent(
        chapterId: chapterId,
        title: '第一章',
        outline: '',
        content: content,
      );

      final result = await toolManager.executeTool(
        name: 'Grep',
        input: {
          'pattern': '关键词',
          'path': 'chapters/$chapterId/content',
          'output_mode': 'count',
        },
        callId: 'call_grep_count_full_count_test',
      );

      expect(result['ok'], isTrue);
      expect(result['text'], 'chapters/$chapterId/content:25\n');
      expect(result['searched_files'], 1);
    });

    test(
      'per-field match cap reports truncation without losing count accuracy',
      () async {
        final id = await contentService.createChapter(
          siblingOrder: 1,
          title: '长正文',
        );
        await contentService.updateChapterContent(
          chapterId: id,
          title: '长正文',
          outline: '',
          content: List.filled(17, '线索').join('\n'),
        );
        final result = await toolManager.executeTool(
          name: 'Grep',
          input: {'path': 'chapters/$id/content', 'pattern': '线索'},
        );
        expect(result['truncated'], true);
        expect(result['text'], contains(':16:线索'));
        expect(result['text'], isNot(contains(':17:线索')));
        final count = await toolManager.executeTool(
          name: 'Grep',
          input: {
            'path': 'chapters/$id/content',
            'pattern': '线索',
            'output_mode': 'count',
          },
        );
        expect(count['truncated'], false);
        expect(count['text'], 'chapters/$id/content:17\n');
      },
    );

    test(
      'missing search target is an error instead of an empty match',
      () async {
        final result = await toolManager.executeTool(
          name: 'Grep',
          input: {'path': 'chapters/missing/content', 'pattern': '线索'},
        );
        expect(result['error'], isNotNull);
        expect(result['text'], isNull);
      },
    );

    test(
      'explicit work field searches report unavailable optional reader',
      () async {
        for (final input in [
          {'path': '/works/current/title', 'pattern': 'title'},
          {'path': '/works/current/description', 'pattern': 'title'},
        ]) {
          final result = await toolManager.executeTool(
            name: 'Grep',
            input: input,
          );
          expect(result['error_code'], 'unavailable');
        }
      },
    );

    test('reports search file budget truncation', () async {
      for (var i = 0; i < 340; i += 1) {
        await contentService.createChapter(siblingOrder: i + 1, title: '章节 $i');
      }

      final result = await toolManager.executeTool(
        name: 'Grep',
        input: {
          'pattern': '不存在的关键词',
          'path': 'chapters',
          'output_mode': 'count',
        },
        callId: 'call_grep_search_budget_test',
      );

      expect(result['ok'], isTrue);
      expect(result['truncated'], isTrue);
      expect(result['search_truncated'], isTrue);
      expect(result['searched_files'], 1000);
      expect(result['search_file_limit'], 1000);
    });

    test('finds a character by exact name then reads the character', () async {
      final targetId = await contentService.createCharacterProfile(
        defaultName: '阿青',
      );
      final otherId = await contentService.createCharacterProfile(
        defaultName: '李四',
      );
      await contentService.updateCharacterProfile(
        entryId: targetId,
        name: '阿青',
        role: characterRoleProtagonist,
        gender: characterGenderFemale,
        biography: '越女剑影',
        description: '正在竹林练剑',
      );
      await contentService.updateCharacterProfile(
        entryId: otherId,
        name: '李四',
        role: characterRoleSupporting,
        gender: characterGenderMale,
        biography: '茶馆伙计',
        description: '正在打听消息',
      );

      final grepResult = await toolManager.executeTool(
        name: 'Grep',
        input: {
          'pattern': '^阿青\$',
          'path': 'characters',
          'glob': 'characters/*/name',
          'output_mode': 'files_with_matches',
        },
        callId: 'call_grep_character_name_exact_test',
      );

      expect(grepResult['ok'], isTrue);
      expect(grepResult['text'], 'characters/$targetId/name\n');
      expect(grepResult['text'], isNot(contains('characters/$otherId/name')));

      final readResult = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'characters/$targetId'},
        callId: 'call_read_character_after_grep_name_test',
      );

      expect(readResult['id'], targetId);
      expect(readResult['name'], '阿青');
      expect(readResult['biography'], '越女剑影');
      expect(readResult['description'], '正在竹林练剑');
    });
  });
}
