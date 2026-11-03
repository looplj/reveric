// 职责: 测试统一 Create 工具的章节、地点、文档与素材创建语义
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/maps_service.dart
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_create.dart

import 'package:reveric/shared/app_config.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_status.dart';
import 'package:reveric/shared/services/ai/prompts/prompt_fragments.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/maps_service.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import '../../../helpers/working_change_test_helper.dart';

void main() {
  group('AiToolManager.stripChapterTitlePrefix', () {
    test('strips "第X章" prefix with Chinese numerals', () {
      expect(AiToolManager.stripChapterTitlePrefix('第一章 新的开始'), '新的开始');
    });

    test('strips "第X章" prefix with Arabic digits', () {
      expect(AiToolManager.stripChapterTitlePrefix('第1章 新的开始'), '新的开始');
    });

    test('strips "第X章" prefix with leading/trailing spaces', () {
      expect(AiToolManager.stripChapterTitlePrefix('第 1 章 新的开始'), '新的开始');
    });

    test('strips "第X章" prefix with full-width space (U+3000)', () {
      expect(AiToolManager.stripChapterTitlePrefix('第1章　新的开始'), '新的开始');
    });

    test('strips "第X章" prefix with dash separator', () {
      expect(AiToolManager.stripChapterTitlePrefix('第1章-测试'), '测试');
    });

    test('strips "第X章" prefix with em-dash separator', () {
      expect(AiToolManager.stripChapterTitlePrefix('第1章——测试'), '测试');
    });

    test('strips "第X章" prefix with Chinese comma separator', () {
      expect(AiToolManager.stripChapterTitlePrefix('第1章，测试'), '测试');
    });

    test('strips multi-digit chapter numbers', () {
      expect(AiToolManager.stripChapterTitlePrefix('第12章 测试'), '测试');
    });

    test('strips compound Chinese numerals (e.g. 十二, 二十)', () {
      expect(AiToolManager.stripChapterTitlePrefix('第十二章 测试'), '测试');
    });

    test('strips "第百章" pattern', () {
      expect(AiToolManager.stripChapterTitlePrefix('第百章 终章'), '终章');
    });

    test('returns empty string when title is only the prefix', () {
      expect(AiToolManager.stripChapterTitlePrefix('第1章'), '');
    });

    test('returns title unchanged when no prefix', () {
      expect(AiToolManager.stripChapterTitlePrefix('新的开始'), '新的开始');
    });

    test('returns empty for empty input', () {
      expect(AiToolManager.stripChapterTitlePrefix(''), '');
    });

    test('handles "零" (zero) in chapter number', () {
      expect(AiToolManager.stripChapterTitlePrefix('第零章 序幕'), '序幕');
    });

    test('preserves Chinese punctuation after prefix', () {
      expect(AiToolManager.stripChapterTitlePrefix('第一章：新的开始'), '新的开始');
    });

    test('strips with underscore separator', () {
      expect(AiToolManager.stripChapterTitlePrefix('第1章_测试'), '测试');
    });

    test('handles mixed spaces around characters', () {
      expect(AiToolManager.stripChapterTitlePrefix('第  一  章  测试'), '测试');
    });
  });

  group('CreateChapter', () {
    late NovelContentDatabase db;
    late AppDatabase appDb;
    late NovelContentService contentService;
    late AiToolManager toolManager;

    setUp(() async {
      db = NovelContentDatabase.forTest(NativeDatabase.memory());
      appDb = AppDatabase.forTest(NativeDatabase.memory());
      contentService = NovelContentService(db);
      final overlay = WorkingOverlayService(
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

    test('number-only chapter title explains how to correct it', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          'fields': {'title': '第十二章', 'content': '测试正文'},
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(result['error'], contains('only a chapter number'));
      expect(result['hint'], contains('fields.title'));
      expect(await db.select(db.chapters).get(), isEmpty);

      final corrected = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          'fields': {'title': '第十二章 风暴开端', 'content': '测试正文'},
        },
      );
      expect(corrected['ok'], isTrue);
      final chapter = await contentService.getChapterById(
        corrected['id'] as String,
      );
      expect(chapter!.title, '风暴开端');
      expect(chapter.content, '测试正文');
    });

    test(
      'Create ignores unsupported chapter type and creates a normal chapter',
      () async {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'chapters',
            'fields': {'title': '新的转折', 'type': 'extra', 'content': '正文'},
          },
        );

        expect(result['ok'], isTrue, reason: '$result');
        expect(result['ignored_fields'], ['type']);
        final chapter = (await contentService.getChapterById(
          result['id'] as String,
        ))!;
        expect(chapter.type, 'chapter');
        expect(chapter.content, '正文');
      },
    );

    test(
      'missing fields object returns an executable input contract',
      () async {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {'path': 'chapters'},
        );

        expect(result['ok'], isFalse);
        expect(result['error_code'], 'invalid_argument');
        expect(result['input_contract'], {
          'required': ['path', 'fields'],
          'input': {'path': 'chapters', 'fields': <String, dynamic>{}},
          'allowed_fields': [
            'title',
            'outline',
            'brief',
            'content',
            'tension',
            'emotion',
            'events',
            'volume_id',
          ],
          'required_fields': ['title'],
        });
        expect(result['field_constraint'], {
          'field': 'title',
          'required': true,
        });
      },
    );

    test('moves known flat arguments into fields', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {'path': 'chapters', 'title': '第一章 扁平参数', 'content': '正文内容'},
      );

      expect(result['created'], isTrue);
      final chapter = await contentService.getChapterById(
        result['id'] as String,
      );
      expect(chapter?.title, '扁平参数');
      expect(chapter?.content, '正文内容');
    });

    test('accepts fields encoded as a JSON object string', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          'fields': '{"title":"第一章 JSON 字段","content":"正文"}',
        },
      );

      expect(result['created'], isTrue);
      final chapter = await contentService.getChapterById(
        result['id'] as String,
      );
      expect(chapter?.title, 'JSON 字段');
    });

    test('deduplicates equal fields from both accepted shapes', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          'title': '第一章 相同字段',
          'fields': {'title': '第一章 相同字段', 'content': '正文'},
        },
      );

      expect(result['created'], isTrue);
    });

    test('rejects conflicting fields without creating a chapter', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          'title': '第一章 顶层标题',
          'fields': {'title': '第一章 内层标题', 'content': '正文'},
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(await contentService.getChapters(), isEmpty);
    });

    test('rejects arrays and primitives passed as fields', () async {
      for (final fields in <Object>[
        ['title'],
        1,
        true,
        'not json',
      ]) {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {'path': 'chapters', 'fields': fields},
        );

        expect(result['ok'], isFalse);
        expect(result['error_code'], 'invalid_argument');
      }
    });

    test(
      'ignores unsupported flattened fields when creating a chapter',
      () async {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'chapters',
            'fields': {'title': '第一章 新的开始'},
            'chapter_num': 8,
          },
        );

        expect(result['ok'], isTrue, reason: '$result');
        expect(result['ignored_fields'], ['chapter_num']);
        final chapter = (await contentService.getChapterById(
          result['id'] as String,
        ))!;
        expect(chapter.chapterNum, 1);
      },
    );

    test('Create chapter accepts brief and tension', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          'fields': {'title': '第一章 风暴', 'brief': '本章摘要', 'tension': 7},
        },
      );

      expect(result['created'], isTrue);
      final chapter = await contentService.getChapterById(
        result['id'] as String,
      );
      expect(chapter?.brief, '本章摘要');
      expect(chapter?.tension, 7);
    });

    test('creates first chapter when the novel has no chapters yet', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          'fields': {'title': '第一章 风暴开端', 'content': '正文内容。'},
        },
        context: ToolExecutionContext(
          sourceSessionId: 'ai_session_background',
          sourceTurnId: 'turn_1',
        ),
      );

      expect(result['created'], isTrue);
      expect(result, isNot(contains('type')));

      final id = result['id'] as String;
      final chapter = await contentService.getChapterById(id);
      expect(chapter, isNotNull);
      expect(chapter!.type, nodeTypeChapter);
      expect(chapter.title, '风暴开端');
      expect(chapter.content, '正文内容。');
      expect(chapter.siblingOrder, 1);
      expect(result['content_word_counts'], {
        'with_punctuation': 5,
        'without_punctuation': 4,
      });
      expect(result, isNot(contains('word_count')));
      expect(
        (result['content_word_counts']
            as Map<String, dynamic>)['with_punctuation'],
        chapter.wordCount,
      );

      expect(result.containsKey('working_change_id'), isFalse);
      final change = await onlyActiveWorkingChange(db);
      expect(change.resourcePath, 'chapters/$id');
      expect(change.status, workingChangeStatusActive);
      expect(change.source, workingChangeSourceAi);
      expect(change.sourceSessionId, 'ai_session_background');
      expect(change.sourceTurnId, 'turn_1');
    });

    test('Create failure on chapters carries the field contract', () async {
      // 字段契约只在失败时按路径返回，不再常驻 _links.create。
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          'fields': {'content': '缺标题'},
        },
      );

      expect(result['ok'], isFalse);
      final contract = result['input_contract'] as Map<String, dynamic>;
      expect(contract['allowed_fields'], [
        'title',
        'outline',
        'brief',
        'content',
        'tension',
        'emotion',
        'events',
        'volume_id',
      ]);
      expect(contract['required_fields'], ['title']);
      expect(result.containsKey('_schemas'), isFalse);
    });

    test('pathSchema field notes include create fields and enums', () {
      final notes = pathSchemaFieldNotes();

      expect(notes, contains('- locations'));
      expect(notes, contains('- name*'));
      expect(notes, contains('取值 generic | world | continent'));
      expect(notes, isNot(contains('取值 chapter | extra')));
      expect(notes, contains('- volumes'));
      expect(notes, contains('- title*'));
      expect(notes, isNot(contains('volumes: title*, description')));
      expect(notes, contains('- outlines/{title}/beats'));
      expect(notes, contains('节拍列表'));
      expect(notes, isNot(contains('取值 active | archived')));
      expect(notes, isNot(contains('\n- canvas\n')));
      expect(notes, isNot(contains('canvas/{name}/nodes')));
      expect(notes, isNot(contains('\n- relations\n')));
      expect(notes, isNot(contains('取值 reference | sticky')));
    });

    test('pathSchema field notes come from collection schemas', () {
      final notes = pathSchemaFieldNotes();

      expect(notes, contains('- appearance：稳定视觉外观'));
      expect(notes, contains('- tags（array<string>）：用于按宗门、家族、阵营等维度归类角色的标签'));
      expect(
        notes,
        contains('- behavior_tags（array<object>）：{tag, context} 对象数组'),
      );
      expect(notes, contains('- tension（integer，1～10，nullable）：本章叙事张力'));
      expect(notes, contains('- status（readonly）：发布状态'));
      expect(notes, contains('- avatar_asset_id（nullable）：'));
      expect(notes, contains('- word_count（readonly，integer）：字数'));
      expect(notes, contains('- skills（readonly，array<object>）：技能列表'));
      expect(notes, isNot(contains('- proof*')));
    });

    test('pathSchema field notes expose only story_state content', () {
      final notes = pathSchemaFieldNotes();
      final storyStateFields = notes
          .split('\n')
          .skipWhile((line) => line != '- story_state（故事状态）')
          .skip(1)
          .takeWhile((line) => line.startsWith('  '));

      expect(storyStateFields, [
        '  path: story_state',
        '  - content：累积叙事状态 Markdown；在正文中记录覆盖到的章节或季、集、场次',
      ]);
    });

    test('pathSchema prompt explains the readonly marker', () {
      final prompt = PromptFragments.pathSchemaBlock();

      expect(prompt, contains('未标类型为 string'));
      expect(prompt, contains('readonly 不可传入写操作'));
      expect(prompt, contains('- status（readonly）：发布状态'));
    });

    test(
      'field notes expose numeric bounds, examples and real input permissions',
      () {
        final notes = pathSchemaFieldNotes();
        expect(notes, contains('tension（integer，1～10，nullable）：本章叙事张力'));
        expect(notes, contains('emotion（array<string>）：情绪短标签；示例 ["紧张","决绝"]'));
        expect(notes, contains('is_folder（readonly，boolean）'));
        expect(notes, contains('index（integer）：插入位置；省略时追加到末尾'));
        expect(notes, contains('beats（array<object>）：节拍列表'));
        expect(notes, isNot(contains('beats（readonly）')));
        expect(notes, isNot(contains('index（readonly）')));
        expect(notes, isNot(contains('id（readonly）')));
        final prompt = PromptFragments.pathSchemaBlock();
        expect(prompt, contains('id（只读）'));
        expect(prompt, contains('可原样携带已有 id'));
      },
    );

    test(
      'resource paths accompany field tables without a second visible path index',
      () {
        final notes = pathSchemaFieldNotes();
        expect(
          notes,
          contains('- chapters（章节）\n  path: chapters/{chapter_id}'),
        );
        expect(notes, contains('- outlines（大纲）\n  path: outlines/{title}'));
        expect(
          notes,
          contains(
            '- foreshadowing（伏笔）\n'
            '  path: foreshadowing/{foreshadowing_id}',
          ),
        );
        expect(notes, contains('- skills（技能）\n  path: skills/{skill_id}'));
        for (final label in [
          'profile（作品信息）',
          'story_state（故事状态）',
          'volumes（卷）',
          'characters（角色）',
          'locations（地点）',
          'items（物品）',
          'factions（势力）',
          'creatures（生物）',
          'lore（世界设定）',
          'materials（素材）',
        ]) {
          expect(notes, contains('- $label\n  path: '));
        }
        expect(
          notes,
          contains(
            '- outlines/{title}/beats（节拍）\n  path: outlines/{title}/beats/{beat_id}',
          ),
        );
        expect(
          notes,
          contains('path: lore/{title}；支持多级：lore/{folder}/{title}'),
        );
        expect(notes, contains('  path: profile\n'));
        final grammar = pathSchema();
        for (final kind in ['novel', 'screenplay']) {
          final prompt = PromptFragments.pathSchemaBlock(kind: kind);
          expect(prompt, contains('Read /_schema/{collection}'));
          expect(prompt, isNot(contains('canvas/{name}')));
          expect(prompt, isNot(contains('relations/{relation_id}')));
          expect(prompt, isNot(contains('按需查询契约的路径')));
        }
        expect(grammar, isNot(contains('ID 寻址：')));
        expect(grammar, isNot(contains('标题即路径：')));
      },
    );

    test('path schema owns query guidance and resource query fields', () async {
      final notes = pathSchemaFieldNotes();
      expect(
        notes,
        contains(
          'path: characters/{character_id}\n'
          '  Read / Glob / Grep query: search、name、role、gender、aliases、age',
        ),
      );
      expect(
        notes,
        contains(
          'path: chapters/{chapter_id}\n'
          '  Read / Glob / Grep query: search、volume_id、chapter_num',
        ),
      );
      expect(pathSchema(), contains('不区分大小写的包含匹配'));
      expect(pathSchema(), contains('其余 query 精准匹配'));
      expect(pathSchema(), contains('query 只过滤该 path 的直属条目'));
      expect(notes, isNot(contains('query: season_id')));
      final screenplayNotes = pathSchemaFieldNotes(kind: 'screenplay');
      expect(
        screenplayNotes,
        contains(
          'path: episodes/{episode_id}\n  Read / Glob / Grep query: season_id',
        ),
      );
      expect(
        screenplayNotes,
        contains(
          'path: scenes/{scene_id}\n  Read / Glob / Grep query: search、episode_id、stage',
        ),
      );
      expect(screenplayNotes, isNot(contains('query: search、chapter_num')));
      for (final collection in ['canvas', 'relations']) {
        expect(notes, isNot(contains('\n- $collection')));
        expect(screenplayNotes, isNot(contains('\n- $collection')));
        final contract = await toolManager.executeTool(
          name: 'Read',
          input: {'path': '/_schema/$collection'},
        );
        if (collection == 'canvas' && !ideationCanvasEnabled) {
          expect(contract['error'], isNotNull);
          continue;
        }
        expect(contract['query'], isNotEmpty);
        for (final child in (contract['subresources'] as List).cast<Map>()) {
          // 关系变化历史只用于展示与追溯，不参与搜索（ADR 0037）。
          if ((child['resource_path'] as String).contains('/change_logs/')) {
            expect(child['query'], isNot(contains('search')));
            continue;
          }
          expect(child['query'], contains('search'), reason: '$child');
        }
      }
    });

    test(
      'Create volume accepts outline and keeps description as alias',
      () async {
        final byOutline = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'volumes',
            'fields': {'title': '第一卷', 'outline': '卷大纲'},
          },
        );
        expect(byOutline['created'], isTrue);
        final outlineVolume = await contentService.getChapterById(
          byOutline['id'] as String,
        );
        expect(outlineVolume!.outline, '卷大纲');

        final byAlias = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'volumes',
            'fields': {'title': '第二卷', 'description': '旧别名大纲'},
          },
        );
        expect(byAlias['created'], isTrue);
        final aliasVolume = await contentService.getChapterById(
          byAlias['id'] as String,
        );
        expect(aliasVolume!.outline, '旧别名大纲');
      },
    );

    test(
      'Create trims outer whitespace and preserves internal indentation in chapter content',
      () async {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'chapters',
            'fields': {'title': '缩进测试', 'content': '　　第一行\n　　第二行'},
          },
        );

        expect(result['created'], isTrue);
        final chapter = await contentService.getChapterById(
          result['id'] as String,
        );
        expect(chapter!.content, '　　第一行\n　　第二行'.trim());
      },
    );

    test('unified Create creates a chapter through collection path', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          'fields': {'title': '第一章 风暴开端', 'content': '正文内容'},
        },
      );

      expect(result['created'], isTrue);
      final selfPath = result['path'] as String;
      expect(selfPath, startsWith('chapters/'));
      expect(result.containsKey('_links'), isFalse);

      final id = result['id'] as String;
      final chapter = await contentService.getChapterById(id);
      expect(chapter, isNotNull);
      expect(chapter!.title, '风暴开端');

      final change = await onlyActiveWorkingChange(db);
      expect(change.toolName, 'Create');
    });

    test(
      'creates chapter, updates content, and stages working change',
      () async {
        await contentService.createChapter(siblingOrder: 1, title: '第一章');

        final result = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'chapters',
            'fields': {'title': '第二章 新的转折', 'outline': '大纲', 'content': '正文内容'},
          },
        );

        expect(result['created'], isTrue);
        expect(result, isNot(contains('type')));

        final id = result['id'] as String;
        final chapter = await contentService.getChapterById(id);
        expect(chapter, isNotNull);
        expect(chapter!.type, nodeTypeChapter);
        expect(chapter.title, '新的转折');
        expect(chapter.outline, '大纲');
        expect(chapter.content, '正文内容');
        expect(chapter.siblingOrder, 2);

        final change = await onlyActiveWorkingChange(db);
        expect(change.resourcePath, 'chapters/$id');
        expect(change.resourceId, id);
        expect(change.resourceType, 'chapters');
        expect(change.status, workingChangeStatusActive);
        expect(change.source, workingChangeSourceAi);
        expect(change.toolName, 'Create');
      },
    );

    test('creates a chapter in the requested volume', () async {
      final firstVolumeId = await contentService.createVolume(title: '第一卷');
      await contentService.createVolume(title: '第二卷');

      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          'fields': {'title': '第一章 卷内续写', 'volume_id': firstVolumeId},
        },
      );

      final chapter = await contentService.getChapterById(
        result['id'] as String,
      );
      expect(result['volume_id'], firstVolumeId);
      expect(chapter!.parentId, firstVolumeId);
      expect(chapter.siblingOrder, 1);
    });

    test(
      'continues in the latest numbered chapter volume by default',
      () async {
        final firstVolumeId = await contentService.createVolume(title: '第一卷');
        final secondVolumeId = await contentService.createVolume(title: '第二卷');
        await contentService.createChapter(
          siblingOrder: 1,
          title: '第一章',
          parentId: firstVolumeId,
        );
        await contentService.createChapter(
          siblingOrder: 1,
          title: '第二卷番外',
          type: nodeTypeExtra,
          parentId: secondVolumeId,
        );

        final result = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'chapters',
            'fields': {'title': '第二章 继续'},
          },
        );

        final chapter = await contentService.getChapterById(
          result['id'] as String,
        );
        expect(result['volume_id'], firstVolumeId);
        expect(chapter!.parentId, firstVolumeId);
        expect(chapter.siblingOrder, 2);
      },
    );

    test('rejects a chapter ID as the requested volume', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '已有章节',
      );

      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          'fields': {'title': '错误归属', 'volume_id': chapterId},
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'unsupported');
    });
  });

  group('CreateLocation', () {
    late NovelContentDatabase db;
    late AppDatabase appDb;
    late NovelContentService contentService;
    late LocationsService locationsService;
    late WorkingOverlayService overlay;
    late AiToolManager toolManager;

    setUp(() async {
      db = NovelContentDatabase.forTest(NativeDatabase.memory());
      appDb = AppDatabase.forTest(NativeDatabase.memory());
      contentService = NovelContentService(db);
      locationsService = LocationsService(db);
      overlay = WorkingOverlayService(
        db,
        contentService,
        novelActionsService: NovelActionsService(appDb),
      );
      toolManager = AiToolManager(
        contentService,
        workingOverlayService: overlay,
        createLocationCallback:
            ({
              required String name,
              String? description,
              String? type,
              String? parentId,
            }) {
              return locationsService.createLocation(
                name: name,
                description: description ?? '',
                type: type == null || type.isEmpty ? locationTypeGeneric : type,
                parentId: parentId,
              );
            },
      )..registerAllTools();
    });

    tearDown(() async {
      await db.close();
      await appDb.close();
    });

    test(
      'location duplicate Create, Write and Edit reject without side effects',
      () async {
        await locationsService.createLocation(
          name: '江城',
          type: locationTypeWorld,
        );
        final id = await locationsService.createLocation(
          name: '旧城',
          description: '原描述',
          type: locationTypeWorld,
        );
        final before = await locationsService.getLocationById(id);
        final inputs = <String, Map<String, dynamic>>{
          'Create': {
            'path': 'locations',
            'fields': {'name': ' 江城 ', 'type': 'world'},
          },
          'Write': {
            'path': 'locations/$id',
            'fields': {'description': '不应修改', 'name': '江城'},
          },
          'Edit': {
            'path': 'locations/$id/name',
            'old_text': '旧城',
            'new_text': '江城',
          },
        };
        for (final entry in inputs.entries) {
          final result = await toolManager.executeTool(
            name: entry.key,
            input: entry.value,
          );
          expect(
            result['error_code'],
            'already_exists',
            reason: '${entry.key}: $result',
          );
          expect(await locationsService.getLocationById(id), before);
          expect(await locationsService.getLocations(), hasLength(2));
          expect(await db.workingChangeDao.getAll(), isEmpty);
        }
      },
    );

    test('creates a location when callback is configured', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'locations',
          'fields': {'name': '地球', 'description': '现实地球', 'type': 'world'},
        },
      );

      expect(result['ok'], isTrue);
      expect(result['created'], isTrue);
      expect(result['name'], '地球');

      final id = result['id'] as String;
      final location = await locationsService.getLocationById(id);
      expect(location, isNotNull);
      expect(location!.name, '地球');
      expect(location.description, '现实地球');
      expect(location.type, 'world');
    });

    test(
      'Create trims outer whitespace and preserves internal indentation in location description',
      () async {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'locations',
            'fields': {'name': '地球', 'description': '　　蓝色星球', 'type': 'world'},
          },
        );

        expect(result['ok'], isTrue);
        final location = await locationsService.getLocationById(
          result['id'] as String,
        );
        expect(location!.description, '　　蓝色星球'.trim());
      },
    );

    test('unified Create creates a location through collection path', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'locations',
          'fields': {'name': '地球', 'description': '现实地球', 'type': 'world'},
        },
      );

      expect(result['ok'], isTrue);
      expect(result['created'], isTrue);
      expect(result['path'], startsWith('locations/'));
      expect(result.containsKey('_links'), isFalse);
    });

    test('rejects non-world locations without parent_id', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'locations',
          'fields': {'name': '上海', 'description': '城市', 'type': 'city'},
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(result['error'], contains('parent_id'));
    });

    test('creates a non-world location under parent_id', () async {
      final worldResult = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'locations',
          'fields': {'name': '地球', 'type': 'world'},
        },
      );
      final worldId = worldResult['id'] as String;

      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'locations',
          'fields': {
            'name': '上海',
            'description': '城市',
            'type': 'city',
            'parent_id': worldId,
          },
        },
      );

      expect(result['ok'], isTrue);
      final location = await locationsService.getLocationById(
        result['id'] as String,
      );
      expect(location, isNotNull);
      expect(location!.name, '上海');
      expect(location.type, 'city');
      expect(location.parentId, worldId);
    });

    test('Read exposes locations through generic resource paths', () async {
      final worldResult = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'locations',
          'fields': {'name': '地球', 'type': 'world'},
        },
      );
      final worldId = worldResult['id'] as String;
      final cityResult = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'locations',
          'fields': {
            'name': '上海',
            'description': '城市',
            'type': 'city',
            'parent_id': worldId,
          },
        },
      );
      final cityId = cityResult['id'] as String;

      final listing = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'locations'},
      );
      final entries = listing['entries'] as List<dynamic>;
      expect(entries.map((entry) => entry['id']), contains(worldId));
      expect(entries.map((entry) => entry['id']), contains(cityId));

      final detail = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'locations/$cityId'},
      );
      expect(detail['name'], '上海');
      expect(detail['description'], '城市');
      expect(detail['type'], 'city');
      expect(detail['parent_id'], worldId);
      expect(detail.containsKey('tags'), isFalse);
      expect(detail.containsKey('status'), isFalse);
    });

    test(
      'location search, exact edits and rollback use the same normalized target',
      () async {
        final id = await locationsService.createLocation(
          name: '地球',
          description: '旧线索',
          type: locationTypeWorld,
        );
        final path = 'locations/$id/description';
        final written = await toolManager.executeTool(
          name: 'Write',
          input: {'path': path, 'value': '  新线索  '},
        );
        expect(written['updated'], isTrue);
        expect(
          (await locationsService.getLocationById(id))!.description,
          '新线索',
        );
        final glob = await toolManager.executeTool(
          name: 'Glob',
          input: {'pattern': 'locations/*/description'},
        );
        expect(glob['matches'], [path]);
        final grep = await toolManager.executeTool(
          name: 'Grep',
          input: {
            'path': 'locations',
            'pattern': '新线索',
            'output_mode': 'files_with_matches',
          },
        );
        expect(grep['text'], contains(path));
        final edited = await toolManager.executeTool(
          name: 'Edit',
          input: {'path': path, 'old_text': '新线索', 'new_text': '  精确线索  '},
        );
        expect(edited['edited'], isTrue);
        expect(
          (await locationsService.getLocationById(id))!.description,
          '  精确线索  ',
        );
        final change = await onlyActiveWorkingChange(db);
        await overlay.rollbackChange(change.id);
        expect(
          (await locationsService.getLocationById(id))!.description,
          '旧线索',
        );
        final rejected = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': 'locations/$id',
            'fields': {'description': '不应修改', 'parent_id': 'missing'},
          },
        );
        expect(rejected['error_code'], 'invalid_argument');
        expect(
          (await locationsService.getLocationById(id))!.description,
          '旧线索',
        );
        final history = await overlay.getWorkingChanges();
        expect(history, hasLength(1));
        expect(history.single.id, change.id);
        expect(history.single.status, 'rejected');
      },
    );

    test('Create failure on locations carries the field contract', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'locations',
          'fields': {'type': 'world'},
        },
      );

      expect(result['ok'], isFalse);
      final contract = result['input_contract'] as Map<String, dynamic>;
      expect(contract['input'], {
        'path': 'locations',
        'fields': <String, dynamic>{},
      });
      expect(contract['allowed_fields'], [
        'name',
        'description',
        'type',
        'parent_id',
      ]);
      expect(contract['required_fields'], ['name']);
      expect(result.containsKey('_schemas'), isFalse);
    });

    test('invalid foreshadowing status returns its field constraint', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'foreshadowing',
          'fields': {'title': '伏笔', 'status': 'active'},
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(result['field_constraint'], {
        'field': 'status',
        'enum': ['pending', 'planted', 'payoff', 'abandoned'],
      });
    });

    test(
      'Write applies location changes immediately and accept records them',
      () async {
        final worldResult = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'locations',
            'fields': {'name': '地球', 'type': 'world'},
          },
        );
        final cityResult = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'locations',
            'fields': {
              'name': '上海',
              'description': '旧描述',
              'type': 'city',
              'parent_id': worldResult['id'] as String,
            },
          },
        );
        final cityId = cityResult['id'] as String;

        final result = await toolManager.executeTool(
          name: 'Write',
          input: {'path': 'locations/$cityId/description', 'value': '新描述'},
        );

        expect(result['updated'], isTrue);
        final beforeAccept = await locationsService.getLocationById(cityId);
        expect(beforeAccept!.description, '新描述');

        final commitId = await overlay.commitWorkingChanges(
          [(await onlyActiveWorkingChange(db)).id],
          source: workingChangeSourceAi,
          message: 'test.accept_ai_location_write',
        );

        expect(commitId, isNotNull);
        final afterAccept = await locationsService.getLocationById(cityId);
        expect(afterAccept!.description, '新描述');
      },
    );

    test(
      'Write trims outer whitespace and preserves internal indentation in location description',
      () async {
        final worldResult = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'locations',
            'fields': {'name': '地球', 'type': 'world'},
          },
        );
        final cityResult = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'locations',
            'fields': {
              'name': '上海',
              'description': '旧描述',
              'type': 'city',
              'parent_id': worldResult['id'] as String,
            },
          },
        );
        final cityId = cityResult['id'] as String;

        final result = await toolManager.executeTool(
          name: 'Write',
          input: {'path': 'locations/$cityId/description', 'value': '　　新描述'},
        );

        expect(result['updated'], isTrue);
        final location = await locationsService.getLocationById(cityId);
        expect(location!.description, '　　新描述'.trim());
      },
    );

    test(
      'Write applies a location type and parent from the same final snapshot',
      () async {
        final worldResult = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'locations',
            'fields': {'name': '斗气世界', 'type': 'world'},
          },
        );
        final rootId = await locationsService.createLocation(
          name: '迦南学院',
          type: locationTypeGeneric,
        );

        final result = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': 'locations/$rootId',
            'fields': {
              'description': '位于黑角域的学院。',
              'type': 'building',
              'parent_id': worldResult['id'] as String,
            },
          },
        );

        expect(result['updated'], isTrue);
        expect(
          result['fields'],
          unorderedEquals(['description', 'type', 'parent_id']),
        );
        final location = await locationsService.getLocationById(rootId);
        expect(location!.description, '位于黑角域的学院。');
        expect(location.type, locationTypeBuilding);
        expect(location.parentId, worldResult['id']);
      },
    );

    test(
      'Write rolls back every location field when a later field fails',
      () async {
        final worldId = await locationsService.createLocation(
          name: '斗气世界',
          description: '旧描述',
          type: locationTypeWorld,
        );
        final childId = await locationsService.createLocation(
          name: '黑角域',
          type: locationTypeRegion,
          parentId: worldId,
        );

        await expectLater(
          () => toolManager.executeTool(
            name: 'Write',
            input: {
              'path': 'locations/$worldId',
              'fields': {'description': '新描述', 'parent_id': childId},
            },
          ),
          throwsArgumentError,
        );

        final location = await locationsService.getLocationById(worldId);
        expect(location!.description, '旧描述');
        expect(location.parentId, isNull);
        expect(await overlay.getWorkingChanges(), isEmpty);
      },
    );

    test(
      'Edit applies location changes immediately and accept records them',
      () async {
        final worldResult = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'locations',
            'fields': {'name': '地球', 'type': 'world'},
          },
        );
        final cityResult = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'locations',
            'fields': {
              'name': '上海',
              'description': '旧城市描述',
              'type': 'city',
              'parent_id': worldResult['id'] as String,
            },
          },
        );
        final cityId = cityResult['id'] as String;

        final result = await toolManager.executeTool(
          name: 'Edit',
          input: {
            'path': 'locations/$cityId/description',
            'old_text': '旧城市',
            'new_text': '新城市',
          },
        );

        expect(result['edited'], isTrue);
        final beforeAccept = await locationsService.getLocationById(cityId);
        expect(beforeAccept!.description, '新城市描述');

        final commitId = await overlay.commitWorkingChanges(
          [(await onlyActiveWorkingChange(db)).id],
          source: workingChangeSourceAi,
          message: 'test.accept_ai_location_edit',
        );

        expect(commitId, isNotNull);
        final afterAccept = await locationsService.getLocationById(cityId);
        expect(afterAccept!.description, '新城市描述');
      },
    );

    test('Write rejects non-world location type without parent_id', () async {
      final worldResult = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'locations',
          'fields': {'name': '地球', 'type': 'world'},
        },
      );
      final worldId = worldResult['id'] as String;

      final result = await toolManager.executeTool(
        name: 'Write',
        input: {'path': 'locations/$worldId/type', 'value': 'city'},
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
    });

    test('Write rejects unknown location parent_id', () async {
      final worldResult = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'locations',
          'fields': {'name': '地球', 'type': 'world'},
        },
      );
      final worldId = worldResult['id'] as String;

      final result = await toolManager.executeTool(
        name: 'Write',
        input: {
          'path': 'locations/$worldId',
          'fields': {'type': 'city', 'parent_id': 'location_missing'},
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
    });
  });

  group('Create item collections', () {
    late NovelContentDatabase db;
    late AppDatabase appDb;
    late NovelContentService contentService;
    late AiToolManager toolManager;

    setUp(() async {
      db = NovelContentDatabase.forTest(NativeDatabase.memory());
      appDb = AppDatabase.forTest(NativeDatabase.memory());
      contentService = NovelContentService(db);
      final overlay = WorkingOverlayService(
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

    test('unified Create creates a skill', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'skills',
          'fields': {'title': '火球术', 'content': '发射火球'},
        },
      );

      expect(result['created'], isTrue);
      expect(result['ignored_fields'], isNull);
      expect(result['path'], 'skills/${result['id']}');
      expect(result.containsKey('_links'), isFalse);

      final detail = await toolManager.executeTool(
        name: 'Read',
        input: {'path': result['path']},
      );
      expect(detail['title'], '火球术');
      expect(detail.containsKey('status'), isFalse);
      final stored = await contentService.getItemById(result['id'] as String);
      expect(stored!.status, itemEntryStatusActive);

      final change = await onlyActiveWorkingChange(db);
      expect(change.toolName, 'Create');
    });

    test('item Create rejects a resource path', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'skills/火球术',
          'fields': {'content': '发射火球'},
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(result['hint'], contains('"path":"skills"'));
      expect(result['hint'], contains('generated on create'));
      expect(await contentService.getItemsByType('skill'), isEmpty);
    });

    test('id path hint says the id is generated on create', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters/chapter_1',
          'fields': {'title': '风暴开端'},
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(result['hint'], contains('generated on create'));
    });

    test(
      'unified Create trims outer whitespace and preserves internal indentation in item content',
      () async {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'items',
            'fields': {'title': '怀表', 'content': '　　旧银怀表'},
          },
        );

        expect(result['created'], isTrue);
        final item = await contentService.getItemById(result['id'] as String);
        expect(item!.content, '　　旧银怀表'.trim());
      },
    );

    test('unified Create creates a creature', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'creatures',
          'fields': {'title': '铁甲犀牛', 'content': '坚硬外壳'},
        },
      );

      expect(result['created'], isTrue);
      expect(result['path'], startsWith('creatures/'));
      expect(result.containsKey('_links'), isFalse);
    });

    test('unified Create rejects missing title for item', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'items',
          'fields': {'content': '没有标题'},
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(result['missing_fields'], contains('title'));
    });

    test('Write rejects creating items at collection root', () async {
      final result = await toolManager.executeTool(
        name: 'Write',
        input: {
          'path': 'factions',
          'fields': {'title': '暗影公会'},
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'unsupported');
      expect(result['error'], contains('Create /factions'));
    });
  });

  group('Create document collections', () {
    late NovelContentDatabase db;
    late AppDatabase appDb;
    late NovelContentService contentService;
    late AiToolManager toolManager;

    setUp(() async {
      db = NovelContentDatabase.forTest(NativeDatabase.memory());
      appDb = AppDatabase.forTest(NativeDatabase.memory());
      contentService = NovelContentService(db);
      final overlay = WorkingOverlayService(
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

    test('Create creates lore document at collection root', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'lore',
          'fields': {'title': '魔法系统', 'content': '元素规则'},
        },
      );

      expect(result['created'], isTrue);
      expect(result['is_folder'], isFalse);
      expect(result['path'], 'lore/魔法系统');
      expect(result.containsKey('_links'), isFalse);
      expect(result.containsKey('working_change_id'), isFalse);
      expect(result['ignored_fields'], isNull);

      final document = await contentService.documentsService
          .getDocumentByNamePath(
            type: documentTypeLore,
            namePath: const ['魔法系统'],
          );
      expect(document, isNotNull);
      expect(document!.isFolder, isFalse);
      expect(document.content, '元素规则');
      expect(document.tags, '');

      final change = await onlyActiveWorkingChange(db);
      expect(change.toolName, 'Create');
      expect(change.resourceType, 'lore');
    });

    test('Create failure on lore carries the field contract', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'lore',
          'fields': {'content': '缺标题'},
        },
      );

      expect(result['ok'], isFalse);
      final contract = result['input_contract'] as Map<String, dynamic>;
      expect(contract['allowed_fields'], [
        'title',
        'content',
        'category',
        'type',
      ]);
      expect(contract['required_fields'], ['title']);
    });

    test(
      'Create auto-creates missing parent folders for materials document',
      () async {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'materials/设定资料/地理',
            'fields': {'title': '群岛', 'content': '海上群岛'},
          },
        );

        expect(result['created'], isTrue);
        expect(result['is_folder'], isFalse);
        expect(result['path'], 'materials/设定资料/地理/群岛');
        expect(result['created_parent_folders'], [
          'materials/设定资料',
          'materials/设定资料/地理',
        ]);

        final rootFolder = await contentService.documentsService
            .getDocumentByNamePath(
              type: documentTypeMaterial,
              namePath: const ['设定资料'],
            );
        final childFolder = await contentService.documentsService
            .getDocumentByNamePath(
              type: documentTypeMaterial,
              namePath: const ['设定资料', '地理'],
            );
        final document = await contentService.documentsService
            .getDocumentByNamePath(
              type: documentTypeMaterial,
              namePath: const ['设定资料', '地理', '群岛'],
            );
        expect(rootFolder!.isFolder, isTrue);
        expect(childFolder!.isFolder, isTrue);
        expect(document!.isFolder, isFalse);
        expect(document.parentId, childFolder.id);
      },
    );

    test(
      'Create creates material folder without staging rollback change',
      () async {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'materials/资料库/地理',
            'fields': {'type': 'folder'},
          },
        );

        expect(result['created'], isTrue);
        expect(result['is_folder'], isTrue);
        expect(result.containsKey('working_change_id'), isFalse);
        expect(result['path'], 'materials/资料库/地理');

        final folder = await contentService.documentsService
            .getDocumentByNamePath(
              type: documentTypeMaterial,
              namePath: const ['资料库', '地理'],
            );
        expect(folder, isNotNull);
        expect(folder!.isFolder, isTrue);

        final changes = await db.workingChangeDao.getAll();
        expect(changes, isEmpty);
      },
    );

    test(
      'Create normalizes directory alias to folder for document collections',
      () async {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'materials/设定资料',
            'fields': {'type': 'directory'},
          },
        );

        expect(result['created'], isTrue);
        expect(result['is_folder'], isTrue);
      },
    );

    test(
      'named document Create failures retain their matched input contract',
      () async {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {'path': 'materials/资料目录/设定', 'fields': 'invalid JSON'},
        );
        expect(result['error_code'], 'invalid_argument');
        expect((result['input_contract'] as Map)['input'], {
          'path': 'materials/资料目录/设定',
          'fields': <String, dynamic>{},
        });
      },
    );

    // 线上 0.9.7 invalid_fields：模型把 fields 塞成字符串，jsonDecode 直接失败。
    test('Create repairs malformed fields JSON strings', () async {
      final result = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'chapters',
          // 尾逗号 + markdown 围栏，标准 jsonDecode 会抛。
          'fields': '```json\n{"title": "修复后的章节", "content": "正文",}\n```',
        },
      );

      expect(result['created'], isTrue);
      final chapter = await contentService.getChapterById(
        result['id'] as String,
      );
      expect(chapter!.title, '修复后的章节');
      expect(chapter.content, '正文');
    });

    test(
      'Create still rejects fields strings that cannot be repaired',
      () async {
        final result = await toolManager.executeTool(
          name: 'Create',
          input: {'path': 'chapters', 'fields': '这不是 JSON，只是一段说明文字'},
        );

        expect(result['ok'], isFalse);
        expect(result['error_code'], 'invalid_argument');
      },
    );
  });
}
