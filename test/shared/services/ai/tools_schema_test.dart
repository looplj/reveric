// 职责: 验证全局契约静态一致性、分组可发现性和旧路径拒绝。
// 关联文件:
//   lib/shared/services/ai/tools_schema.dart
//   lib/shared/services/ai/tools.dart
import 'package:reveric/shared/app_config.dart';
import 'package:drift/native.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/canvas_layout.dart'
    show canvasNodeCustomColorPattern;
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_content.dart';

void main() {
  test(
    'sub-agent control contracts stay static and are excluded from child tools',
    () async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final manager = _manager(db, 'novel', withSubAgents: true);
      addTearDown(manager.dispose);
      final before = manager.buildToolDefs();
      final spawn = before.singleWhere((def) => def.name == spawnAgentToolName);
      final background = spawn.inputSchema['properties']['background'] as Map;
      expect(background['type'], 'boolean');
      expect(background['default'], isTrue);
      expect(spawn.inputSchema['required'], ['agent', 'name', 'task']);
      expect(spawn.inputSchema['properties'], isNot(contains('session_id')));
      expect(spawn.inputSchema['additionalProperties'], isFalse);
      final send = before.singleWhere(
        (def) => def.name == sendAgentMessageToolName,
      );
      expect(send.inputSchema['required'], ['session_id', 'message']);
      expect(
        (send.inputSchema['properties'] as Map).keys,
        unorderedEquals(['session_id', 'message']),
      );
      final stop = before.singleWhere((def) => def.name == stopAgentToolName);
      expect(stop.inputSchema['required'], ['session_id']);
      for (final name in [
        spawnAgentToolName,
        sendAgentMessageToolName,
        stopAgentToolName,
      ]) {
        expect(defaultAgentToolNames(), contains(name));
        expect(defaultSubAgentToolNames(), isNot(contains(name)));
        expect(manager.allToolNames(), contains(name));
        final rejected = await manager.executeTool(name: name, input: {});
        expect(rejected['ok'], isFalse);
        expect(rejected['error_code'], 'unavailable');
      }
      final after = manager.buildToolDefs();
      for (final def in [spawn, send, stop]) {
        expect(
          after.singleWhere((value) => value.name == def.name).inputSchema,
          same(def.inputSchema),
        );
      }
    },
  );

  test(
    'chapter creation accepts the advertised example and enforces tension bounds',
    () async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final manager = _manager(db, 'novel');
      addTearDown(manager.dispose);
      final contract = await manager.executeTool(
        name: 'Read',
        input: {'path': '/_schema/chapters'},
      );
      final emotion = contract['fields']['emotion']['example'];
      expect(emotion, ['紧张', '决绝']);
      final tension = contract['fields']['tension'] as Map;
      for (final value in ['开局悬念', 0, 11]) {
        final rejected = await manager.executeTool(
          name: 'Create',
          input: {
            'path': 'chapters',
            'fields': {'title': '无效张力', 'tension': value, 'emotion': emotion},
          },
        );
        expect(rejected['ok'], isFalse);
        expect(rejected['error_code'], 'invalid_argument');
        expect(
          (rejected['validation_errors'] as List).single['field'],
          'tension',
        );
      }
      for (final value in [tension['minimum'], tension['maximum']]) {
        final created = await manager.executeTool(
          name: 'Create',
          input: {
            'path': 'chapters',
            'fields': {
              'title': '有效张力 $value',
              'tension': value,
              'emotion': emotion,
            },
          },
        );
        expect(created['ok'], isTrue);
      }
    },
  );

  test(
    'folder output flag is readonly while folder creation uses type',
    () async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final manager = _manager(db, 'novel');
      addTearDown(manager.dispose);
      for (final collection in ['lore', 'materials']) {
        final document = await manager.executeTool(
          name: 'Create',
          input: {
            'path': collection,
            'fields': {'title': '文档', 'is_folder': true},
          },
        );
        expect(document['ok'], isTrue, reason: '$document');
        expect(document['ignored_fields'], ['is_folder']);
        final read = await manager.executeTool(
          name: 'Read',
          input: {'path': '$collection/文档'},
        );
        expect(read['is_folder'], isNot(isTrue));
        final created = await manager.executeTool(
          name: 'Create',
          input: {
            'path': collection,
            'fields': {'title': '目录', 'type': 'folder', 'is_folder': false},
          },
        );
        expect(created['ok'], isTrue);
        expect(created['is_folder'], isTrue);
        expect(created['ignored_fields'], ['is_folder']);
      }
    },
  );

  test(
    'every registered node has explicit operation targets and field projections',
    () async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final manager = _manager(db, 'novel');
      addTearDown(manager.dispose);
      final index = await manager.executeTool(
        name: 'Read',
        input: {'path': '/_schema'},
      );
      final fieldOnlyWrites = <String>{};
      void checkNode(Map node, {required bool singleton}) {
        final fields = node['fields'] as Map;
        final operations = (node['operation_contracts'] as List).cast<Map>();
        final resourceWrite = operations
            .where((op) => op['tool'] == 'Write' && op['target'] == 'resource')
            .firstOrNull;
        final resourceWriteFields =
            resourceWrite?['input']['properties'] as Map? ?? const {};
        for (final operation in operations) {
          if (operation['tool'] == 'Write' &&
              operation['target'] == 'field' &&
              !resourceWriteFields.containsKey(operation['field'])) {
            fieldOnlyWrites.add(
              '${node['resource_path']}/${operation['field']}',
            );
          }
        }
        if (node['resource_path'] == 'outlines/{title}/beats/{beat_id}') {
          expect(
            resourceWriteFields.keys,
            unorderedEquals(['status', 'chapter_count']),
          );
        }
        if (node['resource_path'] == 'outlines/{title}') {
          expect(
            resourceWriteFields.keys,
            unorderedEquals([
              'title',
              'content',
              'status',
              'start_chapter_num',
            ]),
          );
        }
        final keys = operations
            .map((op) => '${op['tool']}/${op['target']}/${op['field']}')
            .toList();
        expect(
          keys.toSet(),
          hasLength(keys.length),
          reason: node['resource_path'] as String,
        );
        final creates = operations
            .where((op) => op['tool'] == 'Create')
            .toList();
        final history =
            node['resource_path'] ==
            'relations/{relation_id}/change_logs/{change_id}';
        final readOnly = operations.every((op) => op['tool'] == 'Read');
        expect(
          creates,
          hasLength(history || readOnly ? 0 : 1),
          reason: node['resource_path'] as String,
        );
        if (history) {
          expect(
            operations.map((op) => '${op['tool']}/${op['target']}'),
            unorderedEquals([
              'Read/listing',
              'Read/resource',
              'Remove/resource',
            ]),
          );
        }
        if (singleton && resourceWrite != null) {
          expect(creates.single, {...resourceWrite, 'tool': 'Create'});
          for (final field in fields.values.cast<Map>()) {
            expect(field['create'], field['write']);
            expect(field['create_value'], field['write_value']);
          }
        }
        if (!singleton) {
          if (!history && !readOnly) {
            expect(creates.single['target'], 'listing');
            expect(creates.single['input']['kind'], 'create_fields');
          }
          expect(fields['id']['type'], 'string');
          expect(fields['id']['write'], isFalse);
        }
        for (final entry in fields.entries) {
          final field = entry.value as Map;
          for (final capability in [
            ('read_path', 'Read'),
            ('write_path', 'Write'),
            ('edit', 'Edit'),
          ]) {
            if (field[capability.$1] == true) {
              expect(
                operations.any(
                  (op) =>
                      op['tool'] == capability.$2 &&
                      op['target'] == 'field' &&
                      op['field'] == entry.key,
                ),
                isTrue,
                reason: '${node['resource_path']}/${entry.key}',
              );
            }
          }
          if (field['edit'] == true) {
            expect(field['type'], 'string');
          }
          if (field.containsKey('description')) {
            expect(field['description'], isNot(isEmpty));
          }
        }
        for (final operation in operations) {
          expect(operation, isNot(contains('default_field')));
          if (operation['tool'] == 'Edit') {
            expect(operation['target'], 'field');
            expect(operation['field'], isA<String>());
          }
        }
        for (final child in (node['subresources'] as List).cast<Map>()) {
          checkNode(child, singleton: child['address']['kind'] == 'singleton');
        }
      }

      for (final entry in (index['entries'] as List).cast<Map>()) {
        final contract = await manager.executeTool(
          name: 'Read',
          input: {'path': entry['path']},
        );
        checkNode(contract, singleton: contract['singleton'] as bool);
      }
      expect(fieldOnlyWrites, {
        if (ideationCanvasEnabled) ...[
          'canvas/{name}/layout',
          'canvas/{name}/open',
        ],
      });
      final chapters = await manager.executeTool(
        name: 'Read',
        input: {'path': '/_schema/chapters'},
      );
      expect(chapters['fields']['tension']['type'], 'integer');
      expect(chapters['fields']['tension']['minimum'], 1);
      expect(chapters['fields']['tension']['maximum'], 10);
    },
  );

  test(
    'canvas contracts distinguish creation, field writes and mutation results',
    () async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final manager = _manager(db, 'novel');
      addTearDown(manager.dispose);
      final canvas = await manager.executeTool(
        name: 'Read',
        input: {'path': '/_schema/canvas'},
      );
      if (!ideationCanvasEnabled) {
        expect(canvas, contains('error'));
        return;
      }
      final fields = canvas['fields'] as Map;
      expect(
        fields.keys,
        unorderedEquals([
          'id',
          'name',
          'description',
          'node_count',
          'edge_count',
          'layout',
          'open',
        ]),
      );
      expect(canvas['operations'], isNot(contains('Edit')));
      final operations = (canvas['operation_contracts'] as List).cast<Map>();
      final write = operations.singleWhere(
        (op) => op['tool'] == 'Write' && op['target'] == 'resource',
      );
      expect(
        (write['input']['properties'] as Map).keys,
        unorderedEquals(['name', 'description']),
      );
      expect(write['input']['required'], isEmpty);
      expect(
        write['constraints'],
        contains(
          equals({
            'kind': 'at_least_one',
            'presence': 'present',
            'fields': ['name', 'description'],
          }),
        ),
      );
      final layout = operations.singleWhere(
        (op) => op['tool'] == 'Write' && op['field'] == 'layout',
      );
      expect(layout['input']['value']['type'], 'string');
      expect(layout['input']['value']['enum'], [
        'tidy',
        'auto',
        'tree_lr',
        'tree_tb',
        'grid',
      ]);
      expect(fields['layout']['properties']['mode']['nullable'], isTrue);
      expect(fields['layout']['properties']['mode']['enum'], [
        'auto',
        'tree_lr',
        'tree_tb',
        'grid',
      ]);
      expect(
        layout['result']['value']['properties']['updated']['type'],
        'boolean',
      );
      expect(fields['layout']['type'], 'object');
      expect(fields['layout']['properties'], contains('grid_pitch'));
      expect(fields['layout']['detail'], isFalse);
      expect(fields['open']['read'], isFalse);
      final open = operations.singleWhere(
        (op) => op['tool'] == 'Write' && op['field'] == 'open',
      );
      expect(open['input']['value']['enum'], [true]);
      expect(open['result']['value']['properties']['ok']['type'], 'boolean');

      final children = (canvas['subresources'] as List).cast<Map>();
      final nodes = children.first;
      final nodeFields = nodes['fields'] as Map;
      expect(nodeFields['ref_type']['enum'], contains('screenplay_scene'));
      expect(
        nodeFields['ref_id']['reference_targets_by_field']['ref_type']['screenplay_scene'],
        ['scenes'],
      );
      expect(
        nodeFields['ref_id']['reference_targets_by_field']['ref_type']['chapter'],
        ['chapters'],
      );
      expect(
        nodeFields['ref_id']['reference_targets_by_field']['ref_type']['document'],
        ['lore', 'materials'],
      );
      expect(nodeFields, isNot(contains('near')));
      expect(nodeFields, isNot(contains('direction')));
      for (final name in ['x', 'y', 'width', 'height']) {
        expect(nodeFields[name]['type'], 'number');
      }
      expect(nodeFields['width']['create'], isTrue);
      expect(nodeFields['width']['write'], isFalse);
      expect(nodeFields['content']['listing'], isFalse);
      expect(nodeFields['content']['edit'], isTrue);
      final stickyRead = [
        {
          'kind': 'target_requirement',
          'when_field': 'type',
          'when_values': ['sticky'],
        },
      ];
      expect(nodeFields['content']['read_constraints'], stickyRead);
      // 所有节点都能设色：color 不再限定便签可读，支持预设或 #RRGGBB。
      expect(nodeFields['color']['read_constraints'], isNull);
      expect(nodeFields['color']['pattern'], canvasNodeCustomColorPattern);
      expect(nodeFields['title']['read_constraints'], isNull);
      expect(nodeFields['color']['search'], isNull);
      final nodeOps = (nodes['operation_contracts'] as List).cast<Map>();
      expect(
        nodeOps.singleWhere(
          (op) => op['tool'] == 'Read' && op['field'] == 'content',
        )['constraints'],
        stickyRead,
      );
      final nodeWrite = nodeOps.singleWhere(
        (op) => op['tool'] == 'Write' && op['target'] == 'resource',
      );
      expect((nodeWrite['constraints'] as List).single['presence'], 'present');
      final createNode = nodeOps.singleWhere((op) => op['tool'] == 'Create');
      expect(createNode['input']['properties'], contains('near'));
      expect(createNode['input']['required'], ['type']);
      expect(
        createNode['constraints'],
        contains(
          equals({
            'kind': 'required_when',
            'presence': 'present',
            'fields': ['content'],
            'when_field': 'type',
            'when_values': ['sticky'],
          }),
        ),
      );

      expect(
        createNode['constraints'],
        contains(
          equals({
            'kind': 'required_when',
            'fields': ['ref_type', 'ref_id'],
            'when_field': 'type',
            'when_values': ['reference'],
          }),
        ),
      );
      final edit = nodeOps.singleWhere(
        (op) => op['tool'] == 'Edit' && op['field'] == 'content',
      );
      expect(edit['target'], 'field');
      expect(
        edit['constraints'],
        contains(
          equals({
            'kind': 'target_requirement',
            'when_field': 'type',
            'when_values': ['sticky'],
          }),
        ),
      );
      expect(
        nodeOps.where(
          (op) => op['tool'] == 'Write' && op['target'] == 'listing',
        ),
        isEmpty,
      );
      expect(children.last['operations'], ['Read', 'Create', 'Remove']);
      expect(pathSchemaFieldNotes(), isNot(contains('- canvas')));
    },
  );

  test(
    'outline list input shares beat fields without advertising future id preservation',
    () async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final manager = _manager(db, 'novel');
      addTearDown(manager.dispose);
      final outline = await manager.executeTool(
        name: 'Read',
        input: {'path': '/_schema/outlines'},
      );
      final beat = (outline['subresources'] as List).single as Map;
      expect(beat['address'], {'kind': 'id', 'item_token': 'beat_id'});
      expect(beat['operations'], contains('Remove'));
      expect(beat['fields'], isNot(contains('start_chapter_num')));
      expect(beat['fields']['id']['read_path'], isTrue);
      final operations = (outline['operation_contracts'] as List).cast<Map>();
      expect(
        operations.where(
          (op) => op['tool'] == 'Write' && op['target'] == 'listing',
        ),
        isEmpty,
      );
      final contentEdit = operations.singleWhere(
        (op) => op['tool'] == 'Edit' && op['field'] == 'content',
      );
      expect(contentEdit['target'], 'field');
      final beatOps = (beat['operation_contracts'] as List).cast<Map>();
      final listWrite = beatOps.singleWhere(
        (op) => op['tool'] == 'Write' && op['target'] == 'listing',
      );
      expect(
        listWrite['input']['value'],
        isNot(outline['fields']['beats']['create_value']),
      );
      expect(listWrite['input']['value']['identity'], 'optional_existing_id');
      expect(
        outline['fields']['beats']['create_value']['identity'],
        'new_items',
      );
      expect(listWrite['input']['value']['items']['required'], isEmpty);
      final createBeat = beatOps.singleWhere((op) => op['tool'] == 'Create');
      expect(createBeat['input']['required'], ['title']);
      expect(
        listWrite['input']['value']['items']['properties'],
        contains('id'),
      );
      expect(outline['fields']['beats']['items']['properties'], contains('id'));
      for (final key in ['title', 'content', 'status', 'chapter_count']) {
        final input =
            listWrite['input']['value']['items']['properties'][key] as Map;
        expect(input['type'], beat['fields'][key]['type']);
      }
      expect(outline['fields']['title']['required_on_create'], isTrue);
      expect(outline['fields']['start_chapter_num']['create_default'], 1);
    },
  );

  test(
    'screenplay distinguishes resource fields, parameters, array identity and reference output',
    () async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final manager = _manager(db, 'screenplay');
      addTearDown(manager.dispose);
      final scenes = await manager.executeTool(
        name: 'Read',
        input: {'path': '/_schema/scenes'},
      );
      final fields = scenes['fields'] as Map;
      expect(fields, isNot(contains('search')));
      expect(fields, isNot(contains('before_scene_id')));
      expect(fields['cast']['items']['type'], 'object');
      expect(fields['cast']['write_value']['items']['type'], 'string');
      expect(fields['cast']['write_value']['identity'], 'references');
      expect(fields['cast']['write_value']['reference_target'], 'characters');
      expect(fields['cast']['detail'], isFalse);
      expect(
        fields['events']['items']['properties'].keys,
        unorderedEquals(['title', 'summary', 'state_change']),
      );
      expect(fields['events']['items']['required'], ['title', 'summary']);
      final element = (scenes['subresources'] as List).single as Map;
      final listWrite = (element['operation_contracts'] as List)
          .cast<Map>()
          .singleWhere(
            (op) => op['tool'] == 'Write' && op['target'] == 'listing',
          );
      expect(listWrite['input']['value']['identity'], 'optional_existing_id');
      expect(
        listWrite['input']['value']['items']['properties']['id']['type'],
        'string',
      );
      expect(element['fields'], isNot(contains('after_element_id')));
      final seasons = await manager.executeTool(
        name: 'Read',
        input: {'path': '/_schema/seasons'},
      );
      final create = (seasons['operation_contracts'] as List)
          .cast<Map>()
          .singleWhere((op) => op['tool'] == 'Create');
      expect(create['input']['required'], isEmpty);
      expect(seasons['operations'], isNot(contains('Remove')));
      final singleton = await manager.executeTool(
        name: 'Read',
        input: {'path': '/_schema/screenplay'},
      );
      expect(singleton['operations'], ['Read', 'Create', 'Write', 'Edit']);
      expect(singleton['fields']['style_id']['write_path'], isTrue);
      for (final name in ['ratio', 'resolution']) {
        final field = singleton['fields'][name] as Map;
        expect(field['read'], isTrue);
        expect(field['read_path'], isTrue);
        expect(field['create'], isFalse);
        expect(field['write'], isFalse);
        expect(field['write_path'], isFalse);
        expect(field['edit'], isFalse);
      }
      final readOnlyWrite = await manager.executeTool(
        name: 'Write',
        input: {'path': 'screenplay/ratio', 'value': '9:16'},
      );
      expect(readOnlyWrite['error_code'], 'invalid_argument');
      final remove = await manager.executeTool(
        name: 'Remove',
        input: {'path': 'screenplay', 'force': true},
      );
      expect(remove['error_code'], 'invalid_argument');
      final readOperations = (singleton['operation_contracts'] as List)
          .cast<Map>()
          .where((operation) => operation['tool'] == 'Read');
      expect(
        readOperations.where((operation) => operation['target'] == 'resource'),
        hasLength(1),
      );
      expect(
        readOperations
            .where((operation) => operation['target'] == 'field')
            .map((operation) => operation['field']),
        containsAll(['ratio', 'resolution']),
      );
    },
  );

  test(
    'contracts are identical across work types and groups reuse each collection',
    () async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final managers = [
        for (final kind in ['novel', 'screenplay']) _manager(db, kind),
      ];
      addTearDown(db.close);
      for (final manager in managers) {
        addTearDown(manager.dispose);
      }
      Future<Map<String, dynamic>> read(AiToolManager manager, String path) =>
          manager.executeTool(name: 'Read', input: {'path': path});
      final index = await read(managers.first, '/_schema');
      expect(await read(managers.last, '/_schema'), index);
      final entries = (index['entries'] as List).cast<Map>();
      expect(
        entries.where((entry) => entry['collection'] == 'clips'),
        hasLength(1),
      );
      expect(entries.where((entry) => entry['collection'] == 'shots'), isEmpty);
      expect(
        entries.singleWhere(
          (entry) => entry['collection'] == 'foreshadowing',
        )['group'],
        'shared',
      );
      for (final group in ['shared', 'novel', 'screenplay']) {
        final grouped = await read(managers.first, '/_schema/groups/$group');
        expect(await read(managers.last, '/_schema/groups/$group'), grouped);
        final expected = entries
            .where((entry) => entry['group'] == group)
            .toList();
        final contracts = grouped['contracts'] as List;
        expect(contracts, hasLength(expected.length));
        for (final entry in expected) {
          final contract = await read(managers.first, entry['path'] as String);
          expect(
            contracts.cast<Map>().singleWhere(
              (item) => item['collection'] == entry['collection'],
            ),
            Map<String, dynamic>.from(contract)..remove('ok'),
          );
          expect(await read(managers.last, entry['path'] as String), contract);
        }
      }
      expect(
        (await read(managers.first, '/_schema/scenes'))['subresources'],
        isNotEmpty,
      );
      expect(
        (await read(managers.first, '/_schema/screenplay'))['subresources'],
        isEmpty,
      );
      expect(
        (await read(managers.first, '/_schema/canvas'))[ideationCanvasEnabled
            ? 'fields'
            : 'error'],
        isNotNull,
      );
      for (final collection in ['seasons', 'episodes', 'scenes']) {
        final contract = await read(managers.first, '/_schema/$collection');
        final fields = contract['fields'] as Map;
        expect(fields, contains('id'));
        expect(fields['id']['write'], isFalse);
        final token = '${collection.substring(0, collection.length - 1)}_id';
        expect(fields, isNot(contains(token)));
        expect(contract['resource_path'], '$collection/{$token}');
      }
      final sceneContract = await read(managers.first, '/_schema/scenes');
      final sceneFields = sceneContract['fields'] as Map;
      expect(sceneFields, contains('episode_id'));
      expect(sceneFields, isNot(contains('beat_id')));
      final elementContract = (sceneContract['subresources'] as List).single;
      expect(
        elementContract['resource_path'],
        'scenes/{scene_id}/elements/{element_id}',
      );
      expect(elementContract['fields'], contains('id'));
      expect(elementContract['fields'], isNot(contains('element_id')));
      expect(elementContract['fields']['id']['create'], isTrue);
      expect(elementContract['fields'], contains('character_id'));
      final characterIdField = elementContract['fields']['character_id'];
      expect(characterIdField['read_path'], isTrue);
      expect(characterIdField['search'], ['short_text']);
      expect(characterIdField['edit'], isFalse);
      final textRead = elementContract['fields']['text']['read_constraints'];
      expect(textRead, [
        {
          'kind': 'target_requirement',
          'when_field': 'type',
          'when_values': [
            'action',
            'parenthetical',
            'dialogue',
            'transition',
            'note',
            'subtitle',
          ],
        },
      ]);
      for (final field in ['character_id', 'extension', 'name']) {
        expect(elementContract['fields'][field]['read_constraints'], [
          {
            'kind': 'target_requirement',
            'when_field': 'type',
            'when_values': ['character'],
          },
        ]);
      }
      for (final path in [
        '/_schema/groups',
        '/_schema/groups/unknown',
        '/_schema/unknown',
        '/_schema/scenes/extra',
        '/_schema?limit=1',
        '/works/missing/_schema/scenes',
      ]) {
        expect((await read(managers.first, path))['ok'], isFalse, reason: path);
      }
      for (final tool in ['Create', 'Write', 'Edit', 'Replace', 'Remove']) {
        expect(
          (await managers.first.executeTool(
            name: tool,
            input: {
              'path': '/_schema/scenes',
              'value': 'x',
              'fields': {'title': 'x'},
              'old_text': 'x',
              'new_text': 'y',
              'pattern': 'x',
              'replacement': 'y',
            },
          ))['error_code'],
          'permission_denied',
        );
      }
    },
  );

  test(
    'legacy work aliases and nested screenplay paths fail explicitly',
    () async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final manager = _manager(db, 'screenplay');
      addTearDown(db.close);
      addTearDown(manager.dispose);
      for (final path in [
        '/novel',
        'novel/title',
        '/novel/description',
        'profile/title/extra',
        'characters/character_1/name/extra',
        '/novel/current_state/content',
        'screenplay/scenes',
        'screenplay/episodes/episode_1',
        'screenplay/seasons',
      ]) {
        for (final tool in ['Read', 'Glob', 'Grep', 'Replace']) {
          final result = await manager.executeTool(
            name: tool,
            input: {
              'path': path,
              'pattern': tool == 'Glob' ? '**' : 'x',
              'replacement': 'y',
            },
          );
          expect(result['ok'], isFalse, reason: '$tool $path: $result');
        }
      }
      final wrongType = await manager.executeTool(
        name: 'Read',
        input: {'path': 'chapters'},
      );
      expect(wrongType['error_code'], 'invalid_argument');
      expect(wrongType['hint'], contains('/_schema/groups/screenplay'));
    },
  );
}

AiToolManager _manager(
  NovelContentDatabase db,
  String kind, {
  bool withSubAgents = false,
}) {
  final app = AppDatabase.forTest(NativeDatabase.memory());
  addTearDown(app.close);
  final service = NovelContentService(db);
  return AiToolManager(
    service,
    contentKind: kind,
    subAgentListProvider: withSubAgents ? () => [] : null,
    workingOverlayService: WorkingOverlayService(
      db,
      service,
      novelActionsService: NovelActionsService(app),
    ),
  )..registerAllTools();
}
