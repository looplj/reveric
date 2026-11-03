// 职责: 测试 AI 工具响应的权威 path 附加与错误契约（原 _links 超媒体导航已删除）
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/ai/tools_write.dart
//   lib/shared/services/ai/prompts/prompt_fragments.dart

import 'package:reveric/shared/app_config.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/ai/prompts/prompt_fragments.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  group('AI result path contract', () {
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

    Future<void> seedOutline({String title = '主线'}) async {
      await contentService.outlineService.createOutline(defaultTitle: title);
    }

    test('Write/Edit descriptions embed the long-text tool rule', () {
      final defs = toolManager.allToolDefs();
      final writeDesc = defs.firstWhere((d) => d.name == 'Write').description;
      final editDesc = defs.firstWhere((d) => d.name == 'Edit').description;

      // 长文本改 Edit 的推荐写在共享 pathSchema；工具描述不再抄字段清单。
      expect(pathSchema(), contains('改长文本用 Edit'));
      expect(pathSchema(), contains('精确替换'));
      expect(pathSchema(), isNot(contains('不支持 Edit')));
      expect(editDesc, isNot(contains('status/chapter_count')));
      expect(writeDesc, contains('覆盖'));
      expect(editDesc, contains('替换'));
      expect(editDesc, contains('content_word_counts'));
    });

    test('resource tool descriptions forbid inferred resource paths', () {
      final defs = toolManager.allToolDefs();
      final readDef = defs.firstWhere((d) => d.name == 'Read');
      final readPathSchema =
          (readDef.inputSchema['properties'] as Map<String, dynamic>)['path']
              as Map<String, dynamic>;

      // 资源来源约束集中在公共路径规则，Read 参数只声明可接受的路径类型。
      expect(pathSchema(), contains('从工具结果原样复制，不得自行构造或修改'));
      expect(readPathSchema['description'], contains('资源路径或字段路径'));
      expect(readPathSchema['description'], isNot(contains('禁止')));

      // 失败恢复统一放入主代理和子代理共用的工具使用准则。
      expect(pathSchema(), isNot(contains('not_found')));
      expect(
        PromptFragments.toolUseGuidelines(),
        contains('not_found 后禁止原样重试'),
      );
      expect(pathSchemaFieldNotes(), contains('- appearance：稳定视觉外观'));

      // 所有工具描述都不能向模型展示看似可模仿、实际不存在的资源 ID。
      const fakeIdTokens = [
        'chapter_abc',
        'chapter_001',
        'char_abc',
        'char_def',
        'character_abc',
        'fores_xyz',
        'relation_xyz',
        'volume_xxx',
        'volume_abc',
        'location_abc',
        'skill_abc',
        'skill_skill',
        'skill_example',
        'faction_xyz',
      ];
      for (final def in defs) {
        for (final token in fakeIdTokens) {
          expect(
            def.description,
            isNot(contains(token)),
            reason: '${def.name} description contains fake id "$token"',
          );
        }
      }
    });

    test(
      'runtime path error messages do not suggest fake resource ids',
      () async {
        // 模型猜错路径的那一刻会读到这些错误消息，其中同样不能出现可模仿的假 ID。
        const fakeIdShape =
            r'(chapter|char|character|volume|fores|relation|skill|item|faction|creature|location|outline|msg)_(abc|xyz|xxx|def|[0-9]{3})';

        final editOnCollection = await toolManager.executeTool(
          name: 'Edit',
          input: {'path': 'chapters', 'old_text': 'a', 'new_text': 'b'},
          callId: 'call_edit_collection_path_no_fake_id',
        );
        expect(editOnCollection['error_code'], 'invalid_argument');

        final removeRelationRoot = await toolManager.executeTool(
          name: 'Remove',
          input: {'path': 'relations'},
          callId: 'call_remove_relation_root_no_fake_id',
        );
        expect(removeRelationRoot['error_code'], 'invalid_argument');

        final removeOnCollection = await toolManager.executeTool(
          name: 'Remove',
          input: {'path': 'characters'},
          callId: 'call_remove_collection_path_no_fake_id',
        );
        expect(removeOnCollection['error_code'], 'invalid_argument');

        for (final result in [
          editOnCollection,
          removeRelationRoot,
          removeOnCollection,
        ]) {
          expect(result['error'].toString(), isNot(matches(fakeIdShape)));
        }

        // Run help 是运行期模型可见文本，示例中的 ID 同样必须是占位符而非假 ID。
        // 引号包裹的 word_数字 值形状覆盖 c_123 这类短前缀编造 ID。
        const quotedIdValueShape = r'"[a-z]+_[0-9]{3}"';
        for (final input in [
          {'command': 'help'},
          {'command': 'help', 'subcommand': 'image'},
        ]) {
          final help = await toolManager.executeTool(
            name: 'Run',
            input: input,
            callId: 'call_run_help_no_fake_id_${input['subcommand'] ?? 'top'}',
          );
          expect(help['ok'], isTrue);
          expect(help['output'].toString(), isNot(matches(fakeIdShape)));
          expect(help['output'].toString(), isNot(matches(quotedIdValueShape)));
        }
      },
    );

    test('Read chapter listing attaches flat paths per entry', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '第一章',
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters'},
        callId: 'call_read_chapter_listing_links',
      );

      // 顶层 path 是权威路径，条目只给扁平 path，不再有 _links。
      expect(result['path'], 'chapters');
      expect(result.containsKey('_links'), isFalse);
      expect(result.containsKey('_schemas'), isFalse);

      final entries = result['entries'] as List<dynamic>;
      expect(entries, isNotEmpty);
      final first = entries.first as Map<String, dynamic>;
      expect(first['path'], 'chapters/$chapterId');
      expect(first.containsKey('_links'), isFalse);
    });

    test('Read single chapter returns the resource path', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '链接测试章',
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters/$chapterId'},
        callId: 'call_read_chapter_resource_links',
      );

      expect(result['path'], 'chapters/$chapterId');
      expect(result.containsKey('_links'), isFalse);
    });

    test('Read folder returns the folder path', () async {
      await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'materials/资料库',
          'fields': {'type': 'folder'},
        },
        callId: 'call_create_material_folder_links',
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'materials/资料库'},
        callId: 'call_read_material_folder_links',
      );

      expect(result['path'], 'materials/资料库');
      expect(result['is_folder'], isTrue);
    });

    for (final collection in ['lore', 'materials']) {
      test(
        '$collection keeps a located document identity through a mixed rename and rollback',
        () async {
          final type = collection == 'lore' ? 'lore' : 'material';
          final folderId = await contentService.documentsService.createFolder(
            type: type,
            title: '目录',
          );
          final id = await contentService.documentsService.createDocument(
            type: type,
            parentId: folderId,
            title: '旧名',
            content: '旧正文',
            category: '旧分类',
          );
          final written = await toolManager.executeTool(
            name: 'Write',
            input: {
              'path': '$collection/目录/旧名',
              'fields': {
                'title': '  新名  ',
                'content': '  新正文  ',
                'category': '新分类',
              },
            },
          );
          expect(written['updated'], isTrue, reason: '$written');
          final stored = (await contentService.documentsService.getDocumentById(
            id,
          ))!;
          expect(stored.title, '新名');
          expect(stored.content, '新正文');
          expect(stored.category, '新分类');
          expect(stored.parentId, folderId);
          final newPath = '$collection/目录/新名';
          final read = await toolManager.executeTool(
            name: 'Read',
            input: {'path': newPath},
          );
          expect(read['id'], id);
          final glob = await toolManager.executeTool(
            name: 'Glob',
            input: {'pattern': '$collection/**/content'},
          );
          expect(glob['matches'], contains('$newPath/content'));
          final changes = await db.workingChangeDao.getAll();
          expect(changes, hasLength(3));
          expect(
            changes.map((change) => change.resourcePath),
            unorderedEquals([
              '$collection/$id/title',
              '$collection/$id/content',
              '$collection/$id/category',
            ]),
          );
          final commitId = await overlay.commitWorkingChanges(
            changes.map((change) => change.id).toList(),
            source: workingChangeSourceAi,
            message: 'accept document',
          );
          expect(
            await overlay.rollbackCommit(commitId: commitId!),
            RestoreResourceResult.restored,
          );
          final restored = (await contentService.documentsService
              .getDocumentById(id))!;
          expect(restored.title, '旧名');
          expect(restored.content, '旧正文');
          expect(restored.category, '旧分类');
        },
      );

      test(
        '$collection Write creation uses the target name and requires existing parent folders',
        () async {
          final missingParent = await toolManager.executeTool(
            name: 'Write',
            input: {
              'path': '$collection/不存在/新文',
              'fields': {'content': '正文'},
            },
          );
          expect(missingParent['error_code'], 'invalid_argument');
          final root = await toolManager.executeTool(
            name: 'Read',
            input: {'path': collection},
          );
          expect(root['entries'], isEmpty);
          final created = await toolManager.executeTool(
            name: 'Write',
            input: {
              'path': '$collection/路径标题',
              'fields': {'title': '忽略此标题', 'category': ''},
            },
          );
          expect(created['created'], isTrue, reason: '$created');
          expect(created['path'], '$collection/路径标题');
          final detail = await toolManager.executeTool(
            name: 'Read',
            input: {'path': created['path']},
          );
          expect(detail['id'], created['id']);
          expect(detail['title'], '路径标题');
          expect(detail['content'], '');
          final noContent = await toolManager.executeTool(
            name: 'Write',
            input: {
              'path': '$collection/不创建',
              'fields': {'title': '仅标题'},
            },
          );
          expect(noContent['error_code'], 'invalid_argument');
          expect(await db.workingChangeDao.getAll(), hasLength(1));
        },
      );

      test('$collection exposes stable ids for document references', () async {
        final schema = await toolManager.executeTool(
          name: 'Read',
          input: {'path': '/_schema/canvas'},
        );
        if (ideationCanvasEnabled) {
          final nodes = (schema['subresources'] as List).first as Map;
          final documentTargets =
              nodes['fields']['ref_id']['reference_targets_by_field']['ref_type']['document']
                  as List;
          expect(documentTargets, ['lore', 'materials']);
          expect(documentTargets, contains(collection));
        } else {
          expect(schema['error'], isNotNull);
        }
        final folder = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': '$collection/资料库',
            'fields': {'type': 'folder'},
          },
        );
        expect(folder['created'], isTrue);
        final document = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': '${folder['path']}/设定',
            'fields': {'content': '文档正文'},
          },
        );
        expect(document['created'], isTrue);
        expect(document['id'], isA<String>());

        final listing = await toolManager.executeTool(
          name: 'Read',
          input: {'path': collection},
        );
        final folderEntry = (listing['entries'] as List).single as Map;
        expect(folderEntry['id'], folder['id']);
        expect(folderEntry['path'], folder['path']);
        final children = await toolManager.executeTool(
          name: 'Read',
          input: {'path': folderEntry['path']},
        );
        expect(children['id'], folder['id']);
        final documentEntry = (children['entries'] as List).single as Map;
        expect(documentEntry['id'], document['id']);
        expect(documentEntry['path'], document['path']);
        final detail = await toolManager.executeTool(
          name: 'Read',
          input: {'path': documentEntry['path']},
        );
        expect(detail['id'], document['id']);
        expect(detail['content'], '文档正文');
        final content = await toolManager.executeTool(
          name: 'Read',
          input: {'path': '${detail['path']}/content'},
        );
        expect(content['value'], '文档正文');

        final canvas = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'canvas',
            'fields': {'name': '引用图'},
          },
        );
        if (!ideationCanvasEnabled) {
          expect(canvas['error'], isNotNull);
          return;
        }
        final node = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': '${canvas['path']}/nodes',
            'fields': {
              'type': 'reference',
              'ref_type': 'document',
              'ref_id': detail['id'],
            },
          },
        );
        expect(node['ok'], isTrue);
        final storedNode = await db.canvasDao.getNodeById(node['id'] as String);
        expect(storedNode!.refId, document['id']);
        expect(storedNode.refType, 'document');
      });
    }

    test('Read field response returns the field path', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '字段链接章',
      );
      await toolManager.executeTool(
        name: 'Write',
        input: {'path': 'chapters/$chapterId/content', 'value': '正文内容'},
        callId: 'call_seed_chapter_content_links',
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters/$chapterId/content'},
        callId: 'call_read_chapter_field_links',
      );

      expect(result['path'], 'chapters/$chapterId/content');
      expect(result.containsKey('_links'), isFalse);
    });

    test(
      'Edit missing text directs the agent to reread the exact field',
      () async {
        final chapterId = await contentService.createChapter(
          siblingOrder: 1,
          title: '编辑恢复章',
        );
        await toolManager.executeTool(
          name: 'Write',
          input: {'path': 'chapters/$chapterId/content', 'value': '当前正文'},
          callId: 'call_seed_chapter_content_edit_recovery',
        );

        final result = await toolManager.executeTool(
          name: 'Edit',
          input: {
            'path': 'chapters/$chapterId/content',
            'old_text': '过期正文',
            'new_text': '新正文',
          },
          callId: 'call_edit_chapter_content_not_found',
        );

        expect(result['error_code'], 'failed_precondition');
        expect(result['path'], 'chapters/$chapterId/content');
        expect(result['recovery'], {
          'tool': 'Read',
          'input': {'path': 'chapters/$chapterId/content'},
        });
      },
    );

    test('Write field response returns the field path', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '写入链接章',
      );

      final result = await toolManager.executeTool(
        name: 'Write',
        input: {'path': 'chapters/$chapterId/content', 'value': '新的正文'},
        callId: 'call_write_chapter_field_links',
      );

      expect(result['path'], 'chapters/$chapterId/content');
      expect(result.containsKey('_links'), isFalse);
    });

    test('Read outline resource returns its path', () async {
      await seedOutline();

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'outlines/主线'},
        callId: 'call_read_outline_field_tool_links',
      );

      expect(result['path'], 'outlines/主线');
      expect(result.containsKey('_links'), isFalse);
    });

    test('Read beat resource returns its path', () async {
      await seedOutline();
      await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'outlines/主线/beats',
          'fields': {'title': '第一拍', 'content': '内容'},
        },
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {
          'path':
              'outlines/主线/beats/${(await contentService.outlineService.getByTitle('主线'))!.beats.first.id}',
        },
        callId: 'call_read_beat_field_tool_links',
      );

      expect(
        result['path'],
        'outlines/主线/beats/${(await contentService.outlineService.getByTitle('主线'))!.beats.first.id}',
      );
      expect(result.containsKey('_links'), isFalse);
    });

    test('Read beat status field returns the field path', () async {
      await seedOutline();
      await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'outlines/主线/beats',
          'fields': {'title': '第一拍', 'content': '内容'},
        },
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {
          'path':
              'outlines/主线/beats/${(await contentService.outlineService.getByTitle('主线'))!.beats.first.id}/status',
        },
        callId: 'call_read_beat_status_field_tool_links',
      );

      expect(
        result['path'],
        'outlines/主线/beats/${(await contentService.outlineService.getByTitle('主线'))!.beats.first.id}/status',
      );
      expect(result.containsKey('_links'), isFalse);
    });

    test('Run agent-rules manages agent rule CRUD', () async {
      final create = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'agent-rules',
          'subcommand': 'create',
          'options': {'name': '章节字数', 'content': '4000-5000 字'},
        },
        callId: 'call_run_agent_rules_create',
      );
      expect(create['ok'], isTrue);
      expect(create['created'], isTrue);
      expect(create['name'], '章节字数');

      final list = await toolManager.executeTool(
        name: 'Run',
        input: {'command': 'agent-rules', 'subcommand': 'list'},
        callId: 'call_run_agent_rules_list',
      );
      expect(list['ok'], isTrue);
      expect(list['count'], 1);
      final listedRules = list['rules'] as List<dynamic>;
      final listedRule = listedRules.single as Map<String, dynamic>;
      expect(listedRule, isNot(contains('path')));
      expect(listedRule['read_command'], {
        'tool': 'Run',
        'input': {
          'command': 'agent-rules',
          'subcommand': 'read',
          'options': {'name': '章节字数'},
        },
      });
      expect(list['hint'], contains('Run command=agent-rules'));

      final update = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'agent-rules',
          'subcommand': 'update',
          'options': {'name': '章节字数', 'content': '4500-5500 字'},
        },
        callId: 'call_run_agent_rules_update',
      );
      expect(update['ok'], isTrue);
      expect(update['updated'], isTrue);

      final updatedList = await toolManager.executeTool(
        name: 'Run',
        input: {'command': 'agent-rules', 'subcommand': 'list'},
        callId: 'call_run_agent_rules_list_after_update',
      );
      final rules = updatedList['rules'] as List<dynamic>;
      expect(rules.single['name'], '章节字数');
      expect(rules.single, isNot(contains('path')));

      final delete = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'agent-rules',
          'subcommand': 'delete',
          'options': {'name': '章节字数'},
        },
        callId: 'call_run_agent_rules_delete',
      );
      expect(delete['ok'], isTrue);
      expect(delete['deleted'], isTrue);
    });

    test('Read relations supports SQL-backed query parameters', () async {
      await db
          .into(db.chapters)
          .insert(
            ChaptersCompanion.insert(
              id: 'chapter_1',
              type: 'chapter',
              siblingOrder: 1,
            ),
          );
      final firstId = await contentService.entityRelationsService
          .createRelation(
            sourceType: entityTypeCharacter,
            sourceId: 'char_a',
            targetType: entityTypeCharacter,
            targetId: 'char_b',
            relationType: characterRelationFriend,
            chapterId: 'chapter_1',
          );
      await contentService.entityRelationsService.createRelation(
        sourceType: entityTypeCharacter,
        sourceId: 'char_a',
        targetType: entityTypeCharacter,
        targetId: 'char_c',
        relationType: characterRelationEnemy,
        chapterId: 'chapter_1',
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {
          'path':
              'relations?source_type=character&source_id=char_a&target_id=char_b',
        },
        callId: 'call_read_relations_query',
      );

      // 顶层 path 不带 query；query 单独回显。
      expect(result['path'], 'relations');
      expect(result['query'], {
        'source_type': entityTypeCharacter,
        'source_id': 'char_a',
        'target_id': 'char_b',
      });
      final entries = result['entries'] as List<dynamic>;
      expect(entries, hasLength(1));
      expect(entries.single['id'], firstId);
      expect(result['total'], 1);
    });

    test('Read relations rejects unsupported query parameters', () async {
      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'relations?unknown=value'},
        callId: 'call_read_relations_invalid_query',
      );

      expect(result['error'], contains('Invalid query parameters: unknown'));
    });

    test(
      'Read rejects invalid query parameters for queryable collections',
      () async {
        final result = await toolManager.executeTool(
          name: 'Read',
          input: {'path': 'chapters?invalid=value'},
          callId: 'call_read_chapters_invalid_query',
        );

        expect(result['error_code'], 'invalid_argument');
      },
    );

    test('Read filesystem root exposes works and global contracts', () async {
      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': '/'},
        callId: 'call_read_root_directory_links',
      );

      expect(result['path'], '/');
      expect(result.containsKey('_links'), isFalse);
      final entries = result['entries'] as List<dynamic>;
      expect(entries, [
        {'collection': 'works', 'path': '/works'},
        {'collection': '_schema', 'path': '/_schema'},
      ]);
      expect(
        (entries.first as Map<String, dynamic>).containsKey('_links'),
        isFalse,
      );
    });

    test('Read no longer supports agent rule resource paths', () async {
      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': '/.agents/rules/章节字数'},
        callId: 'call_read_agent_rule_path_unsupported',
      );

      expect(result['error_code'], 'invalid_argument');
    });

    test('Read not_found hints id path when title is used', () async {
      await contentService.createChapter(siblingOrder: 1, title: '误用标题');

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters/误用标题'},
        callId: 'call_read_title_as_id_hint',
      );

      expect(result['error'], contains('not found'));
      expect(result['error_code'], 'not_found');
      expect(result['hint'], contains('resource ids'));
      expect(result['hint'], contains('Read chapters'));
    });

    test('Write not_found enriches hint for missing id', () async {
      final result = await toolManager.executeTool(
        name: 'Write',
        input: {'path': 'chapters/不存在的标题/content', 'value': 'test'},
        callId: 'call_write_title_as_id_hint',
      );

      expect(result['error_code'], 'not_found');
      expect(result['hint'], contains('resource ids'));
    });

    test('Create failure carries the field contract for the path', () async {
      // 原 _links.create 复述字段表；现在只在失败时按路径返回 input_contract。
      final missingTitle = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'skills',
          'fields': {'content': '正文'},
        },
        callId: 'call_create_skill_missing_title',
      );
      expect(missingTitle['ok'], isFalse);
      final contract = missingTitle['input_contract'] as Map<String, dynamic>;
      expect(contract['input'], {
        'path': 'skills',
        'fields': <String, dynamic>{},
      });
      expect(contract['allowed_fields'], containsAll(['title', 'content']));
      expect(contract['required_fields'], ['title']);

      final missingName = await toolManager.executeTool(
        name: 'Create',
        input: {
          'path': 'characters',
          'fields': {'role': '主角'},
        },
        callId: 'call_create_character_missing_name',
      );
      expect(missingName['ok'], isFalse);
      expect(
        (missingName['input_contract']
            as Map<String, dynamic>)['required_fields'],
        ['name'],
      );
    });
  });
}
