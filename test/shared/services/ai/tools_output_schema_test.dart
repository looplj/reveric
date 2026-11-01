// 职责: 用真实工具返回验证按需 Read 契约、资源投影与跨资源写入结果。
// 关联文件:
//   lib/shared/services/ai/tools_output_schema.dart
//   lib/shared/services/ai/tools_schema.dart
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/codemode/tool.dart

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/ai/codemode/tool.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/ai/tool_catalog.dart';
import 'package:reveric/shared/services/mcp/runtime.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  late NovelContentDatabase db;
  late AppDatabase appDb;
  late NovelContentService content;
  late AiToolManager tools;
  late WorkingOverlayService overlay;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    content = NovelContentService(db);
    overlay = WorkingOverlayService(
      db,
      content,
      novelActionsService: NovelActionsService(appDb),
    );
    tools = AiToolManager(
      content,
      workingOverlayService: overlay,
      sessionId: 'test',
      skillLoader: (_) async => null,
      suggestNextActionCallback: (_, _) {},
    )..registerAllTools();
  });
  tearDown(() async {
    tools.dispose();
    await db.close();
    await appDb.close();
  });

  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> input, {
    AiToolManager? manager,
    bool ok = true,
  }) async {
    final target = manager ?? tools;
    final result = await target.executeTool(name: name, input: input);
    expect(result['ok'], ok, reason: '$name $input: $result');
    final definition = target.buildToolDefs().singleWhere(
      (tool) => tool.name == name,
    );
    expect(
      _accepts(definition.outputSchema!, result),
      isTrue,
      reason: '$name output schema: $result',
    );
    return result;
  }

  test(
    'builtin definitions expose output schemas through describeTool',
    () async {
      final runtime = McpRuntime(
        connect: (_) => throw StateError('No MCP connection expected'),
      );
      addTearDown(runtime.close);
      final catalog = AgentToolCatalog(
        runtime: runtime,
        builtins: () => [...tools.buildToolDefs(), codemodeToolDef],
      );
      for (final definition in [...tools.buildToolDefs(), codemodeToolDef]) {
        expect(definition.outputSchema, isNotNull, reason: definition.name);
        final described = await catalog.describeTool(definition.name);
        expect(
          described['outputSchema'],
          definition.outputSchema,
          reason: definition.name,
        );
      }
    },
  );

  test(
    'Write no-op semantics agree across resource kinds and arrays',
    () async {
      for (final (collection, fields, field, value)
          in <(String, Map<String, dynamic>, String, Object)>[
            ('volumes', {'title': '卷'}, 'title', '新卷'),
            ('characters', {'name': '角色'}, 'name', '新角色'),
            ('foreshadowing', {'title': '伏笔'}, 'title', '新伏笔'),
            ('skills', {'title': '技能'}, 'content', '新内容'),
            ('lore', {'title': '世界'}, 'content', '新世界'),
            ('canvas', {'name': '画布'}, 'description', '新说明'),
          ]) {
        final created = await call('Create', {
          'path': collection,
          'fields': fields,
        });
        final input = {'path': '${created['path']}/$field', 'value': value};
        expect(
          (await call('Write', input))['updated'],
          isTrue,
          reason: collection,
        );
        expect(
          (await call('Write', input))['updated'],
          isFalse,
          reason: collection,
        );
        expect((await call('Read', {'path': input['path']}))['value'], value);
      }
      final locationId = await content.locationsService.createLocation(
        name: '地点',
        type: 'world',
      );
      final locationInput = {
        'path': 'locations/$locationId/name',
        'value': '新地点',
      };
      expect((await call('Write', locationInput))['updated'], isTrue);
      expect((await call('Write', locationInput))['updated'], isFalse);
      final character = await call('Create', {
        'path': 'characters',
        'fields': {'name': '数组角色'},
      });
      for (final field in ['tags', 'aliases']) {
        final input = {
          'path': '${character['path']}/$field',
          'value': ['甲', '乙'],
        };
        expect((await call('Write', input))['updated'], isTrue);
        expect((await call('Write', input))['updated'], isFalse);
      }
      final chapter = await call('Create', {
        'path': 'chapters',
        'fields': {'title': '分析'},
      });
      for (final (field, value) in <(String, Object)>[
        ('tension', 5),
        ('emotion', ['tense']),
        (
          'events',
          [
            {'title': '事件', 'summary': '经过'},
          ],
        ),
      ]) {
        final input = {'path': '${chapter['path']}/$field', 'value': value};
        expect((await call('Write', input))['updated'], isTrue);
        expect((await call('Write', input))['updated'], isFalse);
      }
    },
  );

  test(
    'Write reports actual changes when repeating the same chapter value',
    () async {
      final chapter = await call('Create', {
        'path': 'chapters',
        'fields': {'title': '原题'},
      });
      final path = '${chapter['path']}/title';
      final changed = await call('Write', {'path': path, 'value': '新题'});
      expect(changed['updated'], isTrue);
      expect((await call('Read', {'path': path}))['value'], '新题');
      final unchanged = await call('Write', {'path': path, 'value': '新题'});
      expect(unchanged['updated'], isFalse);
      expect((await call('Read', {'path': path}))['value'], '新题');
    },
  );

  test('Grep exposes continuation after head_limit and terminates', () async {
    final chapter = await call('Create', {
      'path': 'chapters',
      'fields': {'title': '检索', 'content': '命中甲\n命中乙\n命中丙\n命中丁\n命中戊'},
    });
    final input = {
      'path': '${chapter['path']}/content',
      'pattern': '命中',
      'head_limit': 2,
    };
    final first = await call('Grep', input);
    expect(first['truncated'], isTrue);
    expect(first['has_more'], isTrue);
    expect(first['next_offset'], 2);
    final second = await call('Grep', {
      ...input,
      'offset': first['next_offset'],
    });
    expect(second['next_offset'], 4);
    final last = await call('Grep', {
      ...input,
      'offset': second['next_offset'],
    });
    expect(last['has_more'], isFalse);
    expect(last['truncated'], isFalse);
    expect(last, isNot(contains('next_offset')));
    final text = '${first['text']}${second['text']}${last['text']}';
    for (final suffix in ['甲', '乙', '丙', '丁', '戊']) {
      expect('命中$suffix'.allMatches(text), hasLength(1));
    }
  });

  test(
    'read contracts are independent of content kind and stored data',
    () async {
      final contracts = <String, Map<String, dynamic>>{};
      final index = await call('Read', {'path': '/_schema'});
      for (final entry in index['entries'] as List) {
        final path = entry['path'] as String;
        contracts[path] = await call('Read', {'path': path});
      }
      final script = AiToolManager(
        content,
        workingOverlayService: overlay,
        contentKind: 'screenplay',
      )..registerAllTools();
      addTearDown(script.dispose);
      for (final entry in contracts.entries) {
        expect(
          await call('Read', {'path': entry.key}, manager: script),
          entry.value,
        );
      }
      await call('Create', {
        'path': 'chapters',
        'fields': {'title': '契约'},
      });
      for (final entry in contracts.entries) {
        expect(await call('Read', {'path': entry.key}), entry.value);
      }
    },
  );

  test(
    'listing next_offset traverses every chapter once and terminates',
    () async {
      final paths = <String>[];
      for (var i = 0; i < 5; i++) {
        final created = await call('Create', {
          'path': 'chapters',
          'fields': {'title': '分页 $i'},
        });
        paths.add(created['path'] as String);
      }
      final contract = await call('Read', {'path': '/_schema/chapters'});
      final operation = (contract['operation_contracts'] as List)
          .cast<Map>()
          .singleWhere(
            (op) => op['tool'] == 'Read' && op['target'] == 'listing',
          );
      final properties =
          operation['result']['output_schema']['properties'] as Map;
      expect(properties, contains('next_offset'));
      expect(properties, isNot(contains('offset')));

      final seen = <String>[];
      var offset = 0;
      var pages = 0;
      while (true) {
        final page = await call('Read', {
          'path': 'chapters',
          'sort': 'chapter_num',
          'offset': offset,
          'limit': 2,
        });
        expect(page, isNot(contains('offset')));
        seen.addAll((page['entries'] as List).map((e) => e['path'] as String));
        pages++;
        if (page['has_more'] == false) {
          expect(page, isNot(contains('next_offset')));
          break;
        }
        expect(page['next_offset'], greaterThan(offset));
        expect(pages, lessThan(3));
        offset = page['next_offset'] as int;
      }
      expect(pages, 3);
      expect(seen, paths);

      for (final input in [
        {'path': 'chapters', 'offset': 5},
        {'path': 'chapters', 'offset': 100},
        {'path': 'chapters?chapter_num=999'},
      ]) {
        final empty = await call('Read', input);
        expect(empty['entries'], isEmpty);
        expect(empty['has_more'], isFalse);
        expect(empty, isNot(contains('offset')));
        expect(empty, isNot(contains('next_offset')));
      }
    },
  );

  test(
    'canvas layout uses value and reports changes without movement counts',
    () async {
      await call('Create', {
        'path': 'canvas',
        'fields': {'name': '空画布'},
      });
      final path = 'canvas/空画布/layout';
      final read = await call('Read', {'path': path});
      expect(read['value'], containsPair('mode', null));
      expect(read, isNot(contains('mode')));
      final contract = await call('Read', {'path': '/_schema/canvas'});
      final operation = (contract['operation_contracts'] as List)
          .cast<Map>()
          .singleWhere((op) => op['tool'] == 'Read' && op['field'] == 'layout');
      expect(
        _accepts(operation['result']['output_schema'] as Map, read),
        isTrue,
      );
      for (final mode in ['grid', 'tree_lr']) {
        // 空画布没有节点可移动，保存的布局模式变化仍必须报告 updated。
        expect(await call('Write', {'path': path, 'value': mode}), {
          'ok': true,
          'path': path,
          'updated': true,
        });
        expect(await call('Write', {'path': path, 'value': mode}), {
          'ok': true,
          'path': path,
          'updated': false,
        });
        expect((await call('Read', {'path': path}))['value']['mode'], mode);
      }
      final scoped = AiToolManager(
        content,
        workingOverlayService: overlay,
        workId: 'current',
      )..registerAllTools();
      addTearDown(scoped.dispose);
      for (final path in [
        'canvas/空画布/open',
        '/works/current/canvas/空画布/open',
      ]) {
        expect(
          await call('Write', {'path': path, 'value': true}, manager: scoped),
          {'ok': true},
        );
      }
      await call('Write', {
        'path': 'canvas/missing/open',
        'value': true,
      }, ok: false);
    },
  );

  test(
    'screenplay writes report actual changes and fields use value',
    () async {
      final fixture = await ScreenplayService(db).createInitialStructure();
      final script = AiToolManager(
        content,
        workingOverlayService: overlay,
        contentKind: 'screenplay',
        sessionId: 'test',
      )..registerAllTools();
      addTearDown(script.dispose);
      final beat = await call('Create', {
        'path': 'beats',
        'fields': {'episode_id': fixture.episodeId, 'act_number': 1},
      }, manager: script);
      final scene = await call('Create', {
        'path': 'scenes',
        'fields': {'episode_id': fixture.episodeId},
      }, manager: script);
      final element = await call('Create', {
        'path': '${scene['path']}/elements',
        'fields': {'type': 'action', 'text': '原文'},
      }, manager: script);
      for (final path in [
        'seasons/${fixture.seasonId}/title',
        'episodes/${fixture.episodeId}/title',
        'episodes/${fixture.episodeId}/outline',
        '${beat['path']}/title',
        '${beat['path']}/description',
        '${scene['path']}/title',
        '${scene['path']}/synopsis',
        '${element['path']}/text',
      ]) {
        final changed = await call('Write', {
          'path': path,
          'value': '修改后',
        }, manager: script);
        expect(changed['updated'], isTrue, reason: path);
        expect(changed, isNot(contains('change_id')));
        final unchanged = await call('Write', {
          'path': path,
          'value': ' 修改后 ',
        }, manager: script);
        expect(unchanged['updated'], isFalse, reason: path);
        final read = await call('Read', {'path': path}, manager: script);
        expect(read['value'], '修改后', reason: path);
        expect(read, isNot(contains(path.split('/').last)));
      }
      // 同值大纲不能掩盖同一次资源写入中的标题变化。
      final mixed = await call('Write', {
        'path': 'episodes/${fixture.episodeId}',
        'fields': {'title': '第二个标题', 'outline': '修改后'},
      }, manager: script);
      expect(mixed['updated'], isTrue);
      final changes = await overlay.getWorkingChanges();
      expect(changes.any((change) => change.field == 'outline'), isTrue);

      final elementsPath = '${scene['path']}/elements';
      final elements = [
        {'id': element['id'], 'type': 'action', 'text': '修改后'},
      ];
      expect(
        (await call('Write', {
          'path': elementsPath,
          'value': elements,
        }, manager: script))['updated'],
        isFalse,
      );
      elements.single['text'] = '替换后的正文';
      expect(
        (await call('Write', {
          'path': elementsPath,
          'value': elements,
        }, manager: script))['updated'],
        isTrue,
      );
      final movedBeat = await call('Write', {
        'path': beat['path'],
        'fields': {'act_number': 2},
      }, manager: script);
      expect(movedBeat['updated'], isTrue);
      expect(
        (await call('Read', {
          'path': beat['path'],
        }, manager: script))['act_number'],
        2,
      );

      final characters = <String>[];
      for (final name in ['甲', '乙', '丙']) {
        final character = await call('Create', {
          'path': 'characters',
          'fields': {'name': name},
        }, manager: script);
        characters.add(character['id'] as String);
      }
      final castPath = '${scene['path']}/cast';
      expect(
        (await call('Write', {
          'path': castPath,
          'value': characters,
        }, manager: script))['updated'],
        isTrue,
      );
      expect(
        (await call('Write', {
          'path': castPath,
          'value': characters,
        }, manager: script))['updated'],
        isFalse,
      );
      final cast = await call('Read', {
        'path': castPath,
        'limit': 2,
      }, manager: script);
      final tail = await call('Read', {
        'path': castPath,
        'offset': cast['next_offset'],
        'limit': 2,
      }, manager: script);
      expect(cast['value'], hasLength(2));
      expect(cast['total'], 3);
      expect(cast['has_more'], isTrue);
      expect(cast['next_offset'], 2);
      expect(cast, isNot(contains('offset')));
      expect(tail['value'], hasLength(1));
      expect(tail['has_more'], isFalse);
      expect(tail, isNot(contains('next_offset')));
      expect(tail, isNot(contains('offset')));
      expect(cast, isNot(contains('entries')));
      expect(
        [
          ...cast['value'] as List,
          ...tail['value'] as List,
        ].map((entry) => entry['character_id']),
        characters,
      );
      final sceneContract = await call('Read', {
        'path': '/_schema/scenes',
      }, manager: script);
      final castOperation = (sceneContract['operation_contracts'] as List)
          .cast<Map>()
          .singleWhere((op) => op['tool'] == 'Read' && op['field'] == 'cast');
      expect(
        _accepts(castOperation['result']['output_schema'] as Map, cast),
        isTrue,
      );
      for (final entry in <String, Object?>{
        'emotion': ['tense'],
        'events': <Object?>[],
      }.entries) {
        final path = '${scene['path']}/${entry.key}';
        await call('Write', {
          'path': path,
          'value': entry.value,
        }, manager: script);
        expect(
          (await call('Read', {'path': path}, manager: script))['value'],
          entry.value,
        );
      }
    },
  );

  test(
    'read schemas require identities and distinguish documents from folders',
    () async {
      Future<Map> schemaFor(String collection, String target) async {
        final contract = await call('Read', {'path': '/_schema/$collection'});
        return (contract['operation_contracts'] as List)
                .cast<Map>()
                .singleWhere(
                  (op) => op['tool'] == 'Read' && op['target'] == target,
                )['result']['output_schema']
            as Map;
      }

      final chapter = await call('Create', {
        'path': 'chapters',
        'fields': {'title': '必有字段', 'content': '正文'},
      });
      final list = await call('Read', {'path': 'chapters'});
      final listing = await schemaFor('chapters', 'listing');
      final itemSchema = listing['properties']['entries']['items'] as Map;
      final item = (list['entries'] as List).single as Map;
      expect(_accepts(itemSchema, item), isTrue);
      for (final key in ['id', 'title', 'path']) {
        expect(
          _accepts(itemSchema, Map.of(item)..remove(key)),
          isFalse,
          reason: key,
        );
      }
      final detail = await call('Read', {'path': chapter['path']});
      final detailSchema = await schemaFor('chapters', 'resource');
      expect(_accepts(detailSchema, detail), isTrue);
      expect(
        _accepts(detailSchema, Map.of(detail)..remove('content')),
        isFalse,
      );
      // A nullable field is still present; null is not the same as absence.
      expect(detail['volume_id'], isNull);
      expect(
        _accepts(detailSchema, Map.of(detail)..remove('volume_id')),
        isFalse,
      );

      for (final collection in ['lore', 'materials']) {
        final folder = await call('Create', {
          'path': collection,
          'fields': {'title': '目录', 'type': 'folder'},
        });
        final doc = await call('Create', {
          'path': collection,
          'fields': {'title': '文档', 'content': '正文'},
        });
        final folderRead = await call('Read', {'path': folder['path']});
        final docRead = await call('Read', {'path': doc['path']});
        final schema = await schemaFor(collection, 'resource');
        expect(_accepts(schema, folderRead), isTrue);
        expect(_accepts(schema, docRead), isTrue);
        expect(_accepts(schema, Map.of(docRead)..remove('content')), isFalse);
        expect(
          _accepts(schema, Map.of(folderRead)..remove('entries')),
          isFalse,
        );
        final branches = schema['anyOf'] as List;
        final document = branches.cast<Map>().singleWhere(
          (branch) => branch['properties']['is_folder']['const'] == false,
        );
        expect(_accepts(document, folderRead), isFalse);
      }
    },
  );

  test('graph relation output requires identity and endpoint fields', () async {
    await call('Create', {
      'path': 'relations',
      'fields': {
        'source_type': 'character',
        'source_id': 'a',
        'target_type': 'character',
        'target_id': 'b',
        'relation_type': 'friend',
        'proof': '证据',
      },
    });
    final result = await call('GraphSearch', {'type': 'character', 'id': 'a'});
    final contract = await call('Read', {'path': '/_schema/relations'});
    final listing = (contract['operation_contracts'] as List)
        .cast<Map>()
        .singleWhere((op) => op['tool'] == 'Read' && op['target'] == 'listing');
    final relationSchema =
        listing['result']['output_schema']['properties']['entries']['items']
            as Map;
    final relation = (result['layers'] as List).first['relations'].first as Map;
    expect(_accepts(relationSchema, relation), isTrue);
    for (final key in ['id', 'path', 'source_id', 'target_id']) {
      expect(
        _accepts(relationSchema, Map.of(relation)..remove(key)),
        isFalse,
        reason: key,
      );
    }
  });

  test(
    'nested read projections require beat data without requiring create fields',
    () async {
      final created = await call('Create', {
        'path': 'outlines',
        'fields': {
          'title': '读取投影',
          'content': '正文',
          'beats': [
            {'title': '第一拍', 'content': '铺垫'},
          ],
        },
      });
      final contract = await call('Read', {'path': '/_schema/outlines'});
      final operations = (contract['operation_contracts'] as List).cast<Map>();
      final listingSchema =
          operations.singleWhere(
                (op) => op['tool'] == 'Read' && op['target'] == 'listing',
              )['result']['output_schema']
              as Map;
      final list = await call('Read', {'path': 'outlines'});
      expect(_accepts(listingSchema, list), isTrue);
      final detailSchema =
          operations.singleWhere(
                (op) => op['tool'] == 'Read' && op['target'] == 'resource',
              )['result']['output_schema']
              as Map;
      final detail = await call('Read', {'path': created['path']});
      expect(_accepts(detailSchema, detail), isTrue);
      final beatSchema = detailSchema['properties']['beats']['items'] as Map;
      final beat = (detail['beats'] as List).single as Map;
      expect(_accepts(beatSchema, beat), isTrue);
      expect(beatSchema['required'], containsAll(['id', 'title', 'content']));
      expect(beatSchema['required'], isNot(contains('index')));
      expect(_accepts(beatSchema, Map.of(beat)..remove('id')), isFalse);
    },
  );

  test(
    'chapter reads match contracts and mutations report actual changes',
    () async {
      final created = await call('Create', {
        'path': 'chapters',
        'fields': {'title': '契约章节', 'content': '旧词\n旧词'},
      });
      final path = created['path'] as String;
      final schema = await call('Read', {'path': '/_schema/chapters'});
      final operations = (schema['operation_contracts'] as List).cast<Map>();
      Future<void> read(String path, String target, {String? field}) async {
        final result = await call('Read', {
          'path': path,
          if (field == 'content') 'limit': 1,
        });
        final operation = operations.singleWhere(
          (op) =>
              op['tool'] == 'Read' &&
              op['target'] == target &&
              op['field'] == field,
        );
        expect(
          _accepts(operation['result']['output_schema'] as Map, result),
          isTrue,
          reason: '$result',
        );
        if (field == 'content') {
          expect(result['has_more'], isTrue);
          expect(result['next_offset'], 1);
        }
      }

      await read('chapters', 'listing');
      await read(path, 'resource');
      await read('$path/content', 'field', field: 'content');
      await call('Edit', {
        'path': '$path/content',
        'old_text': '旧词',
        'new_text': '新词',
      }, ok: false);
      final edited = await call('Edit', {
        'path': '$path/content',
        'old_text': '旧词',
        'new_text': '新词',
        'all': true,
      });
      expect(edited['edited'], isTrue);
      expect(edited['match_count'], 2);
      expect(edited.containsKey('all'), isFalse);
      final unchanged = await call('Edit', {
        'path': '$path/content',
        'old_text': '新词',
        'new_text': '新词',
        'all': true,
      });
      expect(unchanged['edited'], isFalse);
      expect(unchanged['match_count'], 2);
      final ignored = await call('Write', {
        'path': path,
        'fields': {'unknown': 'x'},
      });
      expect(ignored['updated'], isFalse);
      expect(ignored['ignored_fields'], ['unknown']);
      await call('Write', {'path': '$path/content', 'value': '新词\n新词'});
      await call('Glob', {'pattern': 'chapters/*/content'});
      for (final mode in ['content', 'count', 'files_with_matches']) {
        await call('Grep', {
          'pattern': '新词',
          'path': 'chapters',
          'output_mode': mode,
        });
      }
      await call('Grep', {'pattern': '不存在', 'path': 'chapters'});
      await call('Replace', {
        'pattern': '新词',
        'replacement': '终词',
        'path': 'chapters',
      });
      final replaced = await call('Replace', {
        'pattern': '新词',
        'replacement': '终词',
        'path': 'chapters',
        'dry_run': false,
      });
      expect(replaced['total_replacements'], 2);
      await call('GraphSearch', {'type': 'chapter', 'id': created['id']});
      await call('Remove', {'path': path});
      final missing = await call('Remove', {'path': path, 'force': true});
      expect(missing['missing'], true);
      for (final name in codemodeToolNames) {
        await call(
          name,
          name == 'Read' ? {'path': '/_schema/not_a_collection'} : {},
          ok: false,
        );
      }
    },
  );

  test('listing contract does not advertise detail-only fields', () async {
    final created = await call('Create', {
      'path': 'foreshadowing',
      'fields': {'title': '线索', 'setup': '铺垫'},
    });
    final contract = await call('Read', {'path': '/_schema/foreshadowing'});
    final operations = (contract['operation_contracts'] as List).cast<Map>();
    final listingSchema =
        operations.singleWhere(
              (op) => op['tool'] == 'Read' && op['target'] == 'listing',
            )['result']['output_schema']
            as Map;
    final entryProperties =
        listingSchema['properties']['entries']['items']['properties'] as Map;
    expect(entryProperties, isNot(contains('status')));
    expect(entryProperties, contains('title'));
    final detailSchema =
        operations.singleWhere(
              (op) => op['tool'] == 'Read' && op['target'] == 'resource',
            )['result']['output_schema']
            as Map;
    expect(detailSchema['properties'], contains('status'));
    final listing = await call('Read', {'path': 'foreshadowing'});
    final detail = await call('Read', {'path': created['path']});
    expect(_accepts(listingSchema, listing), isTrue);
    expect(_accepts(detailSchema, detail), isTrue);
    expect((listing['entries'] as List).single, isNot(contains('status')));
    expect(detail, contains('status'));
  });

  test(
    'relation edits report exact counts including unchanged results',
    () async {
      final created = await call('Create', {
        'path': 'relations',
        'fields': {
          'source_type': 'character',
          'source_id': 'a',
          'target_type': 'character',
          'target_id': 'b',
          'relation_type': 'friend',
          'proof': '旧词旧词',
        },
      });
      final path = '${created['path']}/proof';
      final edited = await call('Edit', {
        'path': path,
        'old_text': '旧词',
        'new_text': '新词',
        'all': true,
      });
      expect(edited['match_count'], 2);
      expect(edited['edited'], isTrue);
      final unchanged = await call('Edit', {
        'path': path,
        'old_text': '新词',
        'new_text': '新词',
        'all': true,
      });
      expect(unchanged['match_count'], 2);
      expect(unchanged['edited'], isFalse);
      expect(unchanged.containsKey('all'), isFalse);
      await call('GraphSearch', {'type': 'character', 'id': 'a'});
    },
  );

  test(
    'canvas and screenplay Edit share counts without echoing input all',
    () async {
      await call('Create', {
        'path': 'canvas',
        'fields': {'name': '测试'},
      });
      final node = await call('Create', {
        'path': 'canvas/测试/nodes',
        'fields': {'type': 'sticky', 'content': '旧旧'},
      });
      final canvasEdit = await call('Edit', {
        'path': '${node['path']}/content',
        'old_text': '旧',
        'new_text': '新',
        'all': true,
      });
      expect(canvasEdit['match_count'], 2);
      expect(canvasEdit['edited'], isTrue);
      final canvasUnchanged = await call('Edit', {
        'path': '${node['path']}/content',
        'old_text': '新',
        'new_text': '新',
        'all': true,
      });
      expect(canvasUnchanged['edited'], isFalse);
      expect(canvasEdit.containsKey('updated'), isFalse);
      expect(canvasEdit.containsKey('replacements'), isFalse);
      expect(canvasEdit.containsKey('all'), isFalse);

      final fixture = await ScreenplayService(db).createInitialStructure();
      final manager = AiToolManager(
        content,
        workingOverlayService: overlay,
        contentKind: 'screenplay',
        sessionId: 'test',
      )..registerAllTools();
      addTearDown(manager.dispose);
      final path = 'episodes/${fixture.episodeId}/outline';
      await call('Write', {'path': path, 'value': '旧旧'}, manager: manager);
      await call(
        'Edit',
        {'path': path, 'old_text': '旧', 'new_text': '新'},
        manager: manager,
        ok: false,
      );
      final edited = await call('Edit', {
        'path': path,
        'old_text': '旧',
        'new_text': '新',
        'all': true,
      }, manager: manager);
      expect(edited['edited'], isTrue);
      expect(edited['match_count'], 2);
      expect(edited.containsKey('all'), isFalse);
      final read = await call('Read', {'path': path}, manager: manager);
      expect(read['value'], '新新');
      final contract = await call('Read', {
        'path': '/_schema/episodes',
      }, manager: manager);
      final op = (contract['operation_contracts'] as List)
          .cast<Map>()
          .singleWhere(
            (op) => op['tool'] == 'Read' && op['field'] == 'outline',
          );
      final schema = op['result']['output_schema'] as Map;
      expect(schema['required'], contains('value'));
      expect(_accepts(schema, read), isTrue);

      final beat = await call('Create', {
        'path': 'beats',
        'fields': {
          'episode_id': fixture.episodeId,
          'act_number': 1,
          'description': '旧旧',
        },
      }, manager: manager);
      final scene = await call('Create', {
        'path': 'scenes',
        'fields': {
          'episode_id': fixture.episodeId,
          'title': '旧旧',
          'synopsis': '旧旧',
        },
      }, manager: manager);
      final element = await call('Create', {
        'path': '${scene['path']}/elements',
        'fields': {'type': 'action', 'text': '旧旧'},
      }, manager: manager);
      for (final path in [
        '${beat['path']}/description',
        '${scene['path']}/title',
        '${scene['path']}/synopsis',
        '${element['path']}/text',
      ]) {
        final edited = await call('Edit', {
          'path': path,
          'old_text': '旧',
          'new_text': '新',
          'all': true,
        }, manager: manager);
        expect(edited['edited'], isTrue, reason: path);
        expect(edited['match_count'], 2, reason: path);
        expect(edited.containsKey('all'), isFalse);
        final unchanged = await call('Edit', {
          'path': path,
          'old_text': '新',
          'new_text': '新',
          'all': true,
        }, manager: manager);
        expect(unchanged['edited'], isFalse, reason: path);
        expect(unchanged['match_count'], 2, reason: path);
      }
      // 标题替换后会 trim；trim 后与原标题相同也不算改动。
      final trimmed = await call('Edit', {
        'path': '${scene['path']}/title',
        'old_text': '新新',
        'new_text': ' 新新 ',
      }, manager: manager);
      expect(trimmed['edited'], isFalse);
    },
  );
}

// 本组契约使用的 JSON Schema 子集；验证真实结果而非复制 handler 的执行逻辑。
bool _accepts(Map schema, Object? value) {
  if (schema['anyOf'] case final List branches) {
    if (!branches.any((branch) => _accepts(branch as Map, value))) {
      return false;
    }
  }
  if (schema.containsKey('const') && schema['const'] != value) {
    return false;
  }
  bool matchesType(Object? type) => switch (type) {
    'object' => value is Map,
    'array' => value is List,
    'string' => value is String,
    'boolean' => value is bool,
    'integer' => value is int,
    'number' => value is num,
    'null' => value == null,
    null => true,
    _ => false,
  };
  final type = schema['type'];
  if (type is List ? !type.any(matchesType) : !matchesType(type)) {
    return false;
  }
  if (value is Map) {
    final required = schema['required'] as List? ?? const [];
    if (required.any((key) => !value.containsKey(key))) {
      return false;
    }
    final properties = schema['properties'] as Map? ?? const {};
    for (final entry in value.entries) {
      if (properties.containsKey(entry.key)) {
        if (!_accepts(properties[entry.key] as Map, entry.value)) {
          return false;
        }
      }
    }
  }
  if (value is List) {
    if (schema['items'] case final Map items) {
      return value.every((item) => _accepts(items, item));
    }
  }
  return true;
}
