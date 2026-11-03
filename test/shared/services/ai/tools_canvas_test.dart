// 职责: 测试 AI 画布路径工具 — /canvas 路径解析、Read/Create/Write/Edit/Remove 语义与错误透出
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_canvas.dart
//   lib/shared/services/canvas_service.dart
//   lib/shared/database/novel_content_database.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md

import 'package:reveric/shared/app_config.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/canvas_ai_activity.dart';
import 'package:reveric/shared/models/canvas_layout.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/canvas_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  late NovelContentDatabase db;
  late AppDatabase appDb;
  late NovelContentService contentService;
  late WorkingOverlayService overlay;
  late AiToolManager toolManager;
  late String canvasId;
  late List<CanvasAiActivity> reportedActivities;

  /// 模拟画布页的节拍器：非 null 时 reporter 返回它给的 Future（背压）。
  Future<void> Function(CanvasAiActivity activity)? pacer;
  Map<String, dynamic>? preview;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    contentService = NovelContentService(db);

    overlay = WorkingOverlayService(
      db,
      contentService,
      novelActionsService: NovelActionsService(appDb),
    );
    reportedActivities = <CanvasAiActivity>[];
    pacer = null;
    toolManager = AiToolManager(
      contentService,
      workingOverlayService: overlay,
      canvasActivityReporter: (activity) {
        reportedActivities.add(activity);
        return pacer?.call(activity);
      },
      onToolStarted: (_, _, _, extra, _) => preview = extra,
    )..registerAllTools();
  });

  tearDown(() async {
    await db.close();
    await appDb.close();
  });

  if (!ideationCanvasEnabled) {
    test(
      'disabled canvas is absent from discovery and rejects tool access',
      () async {
        for (final path in ['/canvas', '/canvas/test', '/_schema/canvas']) {
          final result = await toolManager.executeTool(
            name: 'Read',
            input: {'path': path},
          );
          expect(result, contains('error'), reason: path);
        }
        for (final name in ['Create', 'Write', 'Edit', 'Remove']) {
          final result = await toolManager.executeTool(
            name: name,
            input: {
              'path': '/canvas/test',
              'fields': {'name': 'test'},
              'old_string': 'old',
              'new_string': 'new',
            },
          );
          expect(result, contains('error'), reason: name);
        }
        final schema = await toolManager.executeTool(
          name: 'Read',
          input: {'path': '/_schema'},
        );
        expect(
          (schema['entries'] as List).cast<Map>().map((e) => e['collection']),
          isNot(contains('canvas')),
        );
      },
    );
    return;
  }

  // ---- 资源造数 helpers ----

  Future<void> insertCharacter(String id, String name) async {
    final now = DateTime.now();
    await db
        .into(db.characterProfiles)
        .insert(
          CharacterProfilesCompanion.insert(
            id: id,
            name: name,
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  }

  Future<void> insertChapter(String id, String title) async {
    await db
        .into(db.chapters)
        .insert(
          ChaptersCompanion.insert(
            id: id,
            type: nodeTypeChapter,
            siblingOrder: 1,
            title: Value(title),
          ),
        );
  }

  Future<void> insertForeshadowing(String id, String title) async {
    await db
        .into(db.foreshadowings)
        .insert(ForeshadowingsCompanion.insert(id: id, title: title));
  }

  // ---- 工具调用 helpers ----
  //
  // 画布没有专用工具：全部经通用 Read / Create / Write / Edit / Remove 走路径。

  Future<Map<String, dynamic>> read(String path, {int? offset, int? limit}) {
    return toolManager.executeTool(
      name: 'Read',
      input: {'path': path, 'offset': ?offset, 'limit': ?limit},
    );
  }

  Future<Map<String, dynamic>> create(
    String path,
    Map<String, dynamic> fields,
  ) {
    return toolManager.executeTool(
      name: 'Create',
      input: {'path': path, 'fields': fields},
    );
  }

  Future<Map<String, dynamic>> write(
    String path, {
    Map<String, dynamic>? fields,
    Object? value,
  }) {
    return toolManager.executeTool(
      name: 'Write',
      input: {'path': path, 'fields': ?fields, 'value': ?value},
    );
  }

  Future<Map<String, dynamic>> remove(String path, {bool force = false}) {
    return toolManager.executeTool(
      name: 'Remove',
      input: {'path': path, if (force) 'force': true},
    );
  }

  /// 成功响应的权威路径统一在顶层 `path`。
  String selfPath(Map<String, dynamic> result) {
    return result['path'] as String;
  }

  // 画布由用户手动创建；测试直接建库拿到 id，路径用画布名。
  Future<String> createCanvas(String name) async {
    canvasId = await contentService.canvasService.createCanvas(name: name);
    return canvasId;
  }

  Future<Map<String, dynamic>> addNode(
    String canvasName,
    Map<String, dynamic> fields,
  ) {
    return create('canvas/$canvasName/nodes', fields);
  }

  Future<Map<String, dynamic>> addEdge(
    String canvasName,
    Map<String, dynamic> fields,
  ) {
    return create('canvas/$canvasName/edges', fields);
  }

  Future<Map<String, dynamic>> autoLayout(String canvasName) {
    return write('canvas/$canvasName/layout', value: 'auto');
  }

  test(
    'loaded canvas guide examples execute against their declared targets',
    () async {
      await createCanvas('指南验收');
      final guide = await File(
        'assets/bundled_skills/canvas-composition/SKILL.md',
      ).readAsString();
      final example = guide.split('## 便签与连线调用示例').last.split('## 先看清场地').first;
      final calls = RegExp(
        r'^(Create|Read|Write|Edit) (\{.*\})$',
        multiLine: true,
      ).allMatches(example).toList();
      expect(calls, hasLength(8));
      final replacements = <String, String>{'{name}': '指南验收'};
      final results = <Map<String, dynamic>>[];
      for (final call in calls) {
        var json = call.group(2)!;
        for (final entry in replacements.entries) {
          json = json.replaceAll(entry.key, entry.value);
        }
        final input = jsonDecode(json) as Map<String, dynamic>;
        final result = await toolManager.executeTool(
          name: call.group(1)!,
          input: input,
        );
        expect(result['error'], isNull, reason: '$input → $result');
        results.add(result);
        if (call.group(1) == 'Create' &&
            (input['path'] as String).endsWith('/nodes')) {
          final key = replacements.containsKey('{first_node_id}')
              ? '{second_node_id}'
              : '{first_node_id}';
          replacements[key] = result['id'] as String;
        }
      }
      final first = (await db.canvasDao.getNodeById(
        replacements['{first_node_id}']!,
      ))!;
      expect(first.canvasId, canvasId);
      expect(first.content, '发现关键线索');
      expect(first.width, 280.5);
      expect(first.height, 168.5);
      expect(first.x, 0);
      expect(first.y, 0);
      expect(results[5]['value'], containsPair('node_count', 2));
      expect(results[5]['value'], containsPair('edge_count', 1));
      expect(results[5]['value'], containsPair('off_grid', 0));
      expect(results[5]['value']['grid_pitch'], {
        'x': canvasGridPitchX,
        'y': canvasGridPitchY,
      });
      expect(results[6]['updated'], isA<bool>());
      expect(results[7], {'ok': true});
      final edge = (await db.canvasDao.getEdgeById(
        results[4]['id'] as String,
      ))!;
      expect(edge.sourceNodeId, first.id);
      expect(edge.targetNodeId, replacements['{second_node_id}']);
      final rejected = await write(
        '${selfPath(results[4])}/label',
        value: '不会改写',
      );
      expect(rejected['ok'], isFalse);
      expect(
        (await db.canvasDao.getEdgeById(edge.id))!.toJson(),
        edge.toJson(),
      );
    },
  );

  test(
    'reserved canvas names retain child identity across all operations',
    () async {
      for (final name in [
        'nodes',
        'edges',
        'layout',
        'open',
        'name',
        'description',
        'x',
        '0',
      ]) {
        final canvas = await create('/canvas', {'name': name});
        final node = await addNode(name, {'type': 'sticky', 'content': '原文'});
        final nodePath = selfPath(node);
        expect((await read('canvas/$name'))['id'], canvas['id']);
        expect((await read(nodePath))['id'], node['id']);
        expect((await write('$nodePath/content', value: '新正文'))['ok'], isTrue);
        expect(
          (await toolManager.executeTool(
            name: 'Edit',
            input: {
              'path': '$nodePath/content',
              'old_text': '新',
              'new_text': '完整',
            },
          ))['ok'],
          isTrue,
        );
        expect((await read('$nodePath/content'))['value'], '完整正文');
        final invalidParentField = await write('canvas/$name/x', value: 1.5);
        expect(invalidParentField['ok'], isFalse);
        final invalidDepth = await remove(
          '$nodePath/content/extra',
          force: true,
        );
        expect(invalidDepth['error_code'], 'invalid_argument');
        expect((await read(nodePath))['id'], node['id']);
        expect((await remove(nodePath))['removed'], isTrue);
        expect((await read('canvas/$name'))['id'], canvas['id']);
        expect((await remove('canvas/$name'))['removed'], isTrue);
      }
    },
  );

  test(
    'edge labels normalize as text while near retains node ID validation',
    () async {
      await createCanvas('reference-contract');
      await insertCharacter('source-character', 'source');
      final source = await addNode('reference-contract', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'source-character',
      });
      var index = 0;
      for (final label in <Object?>[42, true, ' same ', '', null]) {
        final targetId = 'target-${index++}';
        await insertCharacter(targetId, targetId);
        final target = await addNode('reference-contract', {
          'type': 'reference',
          'ref_type': 'character',
          'ref_id': targetId,
        });
        final created = await toolManager.executeTool(
          name: 'Create',
          input: {
            'path': 'canvas/reference-contract/edges',
            if (label is String) 'label': label,
            'fields': {
              'source_node_id': source['id'],
              'target_node_id': target['id'],
              'type': 'relationship',
              'label': label is String ? label.trim() : label,
            },
          },
        );
        expect(created['ok'], isTrue, reason: '$created');
        expect(
          (await db.canvasDao.getEdgeById(created['id'] as String))!.label,
          label == null || label.toString().trim().isEmpty
              ? null
              : label.toString().trim(),
        );
      }
      final node = await addNode('reference-contract', {
        'type': 'sticky',
        'content': 'unchanged',
      });
      Future<List<Object?>> snapshot() async => [
        (await db.canvasDao.getNodesByCanvas(
          canvasId,
        )).map((row) => row.toJson()).toList(),
        (await db.select(db.workingChanges).get())
            .map((row) => row.toJson())
            .toList(),
      ];
      final before = await snapshot();
      for (final near in <Object>[42, true]) {
        for (final create in [true, false]) {
          final result = await toolManager.executeTool(
            name: create ? 'Create' : 'Write',
            input: {
              'path': create
                  ? 'canvas/reference-contract/nodes'
                  : selfPath(node),
              'fields': {
                if (create) 'type': 'sticky',
                'content': 'must not write',
                'near': near,
              },
            },
          );
          expect(result['error_code'], 'invalid_argument', reason: '$result');
          expect(result['validation_errors'], [
            {
              'code': 'invalid_type',
              'field': 'near',
              'expected_type': 'string',
            },
          ]);
          expect(await snapshot(), before);
        }
      }
      final contract = await read('/_schema/canvas');
      final edges = (contract['subresources'] as List).cast<Map>().singleWhere(
        (node) => (node['resource_path'] as String).contains('/edges/'),
      );
      expect(edges['fields']['label'], isNot(contains('reference_target')));
      final listing = (edges['operation_contracts'] as List)
          .cast<Map>()
          .singleWhere(
            (operation) =>
                operation['tool'] == 'Read' && operation['target'] == 'listing',
          );
      expect(listing['input']['properties']['search'], {'type': 'string'});
    },
  );

  test(
    'canvas preserves number fractions, rounds integers and shares boolean aliases',
    () async {
      await createCanvas('numbers');
      final node = await addNode('numbers', {
        'type': 'sticky',
        'content': '  first\n  second  ',
        'x': '7.8',
        'y': 8.2,
      });
      expect(node['ok'], true, reason: '$node');
      final path = selfPath(node);
      final stored = (await db.canvasDao.getNodeById(node['id'] as String))!;
      expect(stored.x, 7.8);
      expect(stored.y, 8.2);
      expect((await read('$path/content'))['value'], 'first\n  second');
      for (final value in <Object>[-7.5, '-7.5']) {
        final result = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': '$path/col',
            'value': value,
            'fields': {'col': -8},
          },
        );
        expect(result['ok'], true, reason: '$result');
        expect((await read('$path/col'))['value'], -8);
      }
      for (final value in <Object>[true, ' TRUE ', 'yes', '1', 1]) {
        final opened = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': 'canvas/numbers/open',
            'value': value,
            'fields': {'open': true},
          },
        );
        expect(opened['ok'], true, reason: '$opened');
      }
      for (final value in <Object>['not a boolean', 2, 'NaN']) {
        final rejected = await toolManager.executeTool(
          name: 'Write',
          input: {'path': 'canvas/numbers/open', 'value': value},
        );
        expect(rejected['error_code'], 'invalid_argument', reason: '$rejected');
      }
    },
  );

  // ---- 路径解析 ----

  group('canvas 路径解析', () {
    test('画布名唯一，重名创建返回 duplicate_name', () async {
      await createCanvas('主线');

      final result = await create('canvas', {'name': '主线'});

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'already_exists');
    });

    test('画布名不能含 /，否则子资源段会错位', () async {
      final result = await create('canvas', {'name': 'a/b'});

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
    });

    test('Create canvas 建库并返回可复制的 self path', () async {
      final result = await create('canvas', {
        'name': '人物关系',
        'description': '谁跟谁',
      });

      expect(result['ok'], isTrue);
      expect(selfPath(result), 'canvas/人物关系');

      final canvas = await contentService.canvasService.getCanvasByName('人物关系');
      expect(canvas, isNotNull);
      expect(canvas!.description, '谁跟谁');
      expect(result['id'], canvas.id);
      final detail = await read(selfPath(result));
      expect(detail['id'], canvas.id);
      final listing = await read('canvas');
      expect((listing['entries'] as List).single['id'], canvas.id);
    });

    test('建画布广播 create_canvas —— 宿主靠它把详情页推上来', () async {
      final result = await create('canvas', {'name': '新图'});

      expect(result['ok'], isTrue);
      final created = reportedActivities
          .where((a) => a.kind == CanvasAiActivityKind.create_canvas)
          .toList();
      expect(created, hasLength(1));
      final canvas = await contentService.canvasService.getCanvasByName('新图');
      expect(created.single.canvasId, canvas!.id);
    });

    test('建画布失败时不广播 —— 页面不该为一次失败的调用跳走', () async {
      await createCanvas('已存在');
      reportedActivities.clear();

      final result = await create('canvas', {'name': '已存在'});

      expect(result['ok'], isFalse);
      expect(reportedActivities, isEmpty);
    });

    test('不存在的画布名返回 canvas_not_found 并给出 hint', () async {
      final result = await read('canvas/查无此画布/nodes');

      expect(result['error_code'], 'not_found');
    });

    test('canvas?name= 不是合法 query，只认 search', () async {
      await createCanvas('主线');
      await createCanvas('支线');

      final result = await read('canvas?name=主线');

      expect(result['error_code'], 'invalid_argument');
      expect(result['entries'], isNull);
    });

    test('canvas?search= 按 name 与 description 包含匹配', () async {
      await contentService.canvasService.createCanvas(
        name: '主线',
        description: '世界观总图',
      );
      await contentService.canvasService.createCanvas(
        name: '支线',
        description: '人物关系',
      );

      final byName = await read('canvas?search=主线');
      expect(byName['error'], isNull);
      expect((byName['entries'] as List).map((e) => (e as Map)['name']), [
        '主线',
      ]);

      final byDescription = await read('canvas?search=人物');
      expect(
        (byDescription['entries'] as List).map((e) => (e as Map)['name']),
        ['支线'],
      );
    });

    test('canvas/{name}/nodes?search= 按 title 包含匹配', () async {
      await createCanvas('c');
      await addNode('c', {
        'type': 'sticky',
        'title': '伏笔A',
        'content': '不该被搜到的正文',
        'x': 0,
        'y': 0,
      });
      await addNode('c', {
        'type': 'sticky',
        'title': '角色卡',
        'content': '伏笔相关笔记',
        'x': 100,
        'y': 0,
      });

      final result = await read('canvas/c/nodes?search=伏笔');

      expect(result['error'], isNull);
      final entries = result['entries'] as List;
      expect(entries, hasLength(1));
      expect((entries.single as Map)['title'], '伏笔A');
    });

    test('canvas/{name}/edges?search= 按 label 包含匹配', () async {
      await createCanvas('c');
      final n1 = await addNode('c', {
        'type': 'sticky',
        'content': 'a',
        'x': 0,
        'y': 0,
      });
      final n2 = await addNode('c', {
        'type': 'sticky',
        'content': 'b',
        'x': 100,
        'y': 0,
      });
      await addEdge('c', {
        'source_node_id': n1['id'],
        'target_node_id': n2['id'],
        'type': 'causal',
        'label': '师徒',
      });
      await addEdge('c', {
        'source_node_id': n2['id'],
        'target_node_id': n1['id'],
        'type': 'causal',
        'label': '敌对',
      });

      final result = await read('canvas/c/edges?search=师');

      expect(result['error'], isNull);
      final entries = result['entries'] as List;
      expect(entries, hasLength(1));
      expect((entries.single as Map)['label'], '师徒');
    });

    test('节点路径带上画布名，跨画布的 node_id 不认', () async {
      await createCanvas('c1');
      final node = await addNode('c1', {'type': 'sticky', 'content': 'x'});
      final nodeId = node['id'] as String;
      await createCanvas('c2');

      final result = await write(
        'canvas/c2/nodes/$nodeId',
        fields: {'col': 1, 'row': 0},
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'not_found');
      final before = (await db.canvasDao.getNodeById(nodeId))!.toJson();
      final wrongPath = 'canvas/c2/nodes/$nodeId';
      expect((await read(wrongPath))['error_code'], 'not_found');
      final edited = await toolManager.executeTool(
        name: 'Edit',
        input: {
          'path': '$wrongPath/content',
          'old_text': 'x',
          'new_text': 'wrong canvas',
        },
      );
      expect(edited['error_code'], 'not_found');
      expect((await remove(wrongPath))['error_code'], 'not_found');
      expect((await remove(wrongPath, force: true))['missing'], isTrue);
      expect((await db.canvasDao.getNodeById(nodeId))!.toJson(), before);
    });
  });

  // ---- layout ----

  group('layout', () {
    test(
      'four layout values dispatch correctly; diamond keeps content and connections',
      () async {
        await createCanvas('Branch');
        final ids = <String>[];
        for (final title in ['发现线索', '调查', '离开', '车站汇合']) {
          ids.add(
            (await addNode('Branch', {
                  'type': 'sticky',
                  'title': title,
                  'content': '正文$title',
                }))['id']
                as String,
          );
        }
        for (final (from, to) in [(0, 1), (0, 2), (1, 3), (2, 3)]) {
          await addEdge('Branch', {
            'source_node_id': ids[from],
            'target_node_id': ids[to],
            'type': 'timeline',
            'label': '选择',
          });
        }
        final edges = await db.canvasDao.getEdgesByCanvas(canvasId);
        final original = await db.canvasDao.getNodesByCanvas(canvasId);
        String? arranged;
        for (final mode in canvasLayoutModes) {
          final result = await write('canvas/Branch/layout', value: mode);
          expect(result['ok'], isTrue, reason: '$result');
          // 整理现有布局不是一种布局，读回的仍是上一次排列的模式。
          if (mode != canvasLayoutTidy) {
            arranged = mode;
          }
          expect(
            (await read('canvas/Branch/layout'))['value']['mode'],
            arranged,
          );
          expect(
            (await db.canvasDao.getCanvasById(canvasId))!.layout,
            arranged,
          );
          final nodes = await db.canvasDao.getNodesByCanvas(canvasId);
          expect(nodes.map((n) => n.id).toSet(), ids.toSet());
          expect(
            nodes.map((n) => n.content).toList(),
            original.map((n) => n.content).toList(),
          );
          expect(await db.canvasDao.getEdgesByCanvas(canvasId), edges);
          if (mode == canvasLayoutTreeLr || mode == canvasLayoutTreeTb) {
            final map = {for (final n in nodes) n.id: n};
            for (final e in edges) {
              final a = map[e.sourceNodeId]!, b = map[e.targetNodeId]!;
              expect(
                mode == canvasLayoutTreeLr ? b.x > a.x : b.y > a.y,
                isTrue,
              );
            }
          }
        }
        final before = await db.canvasDao.getNodesByCanvas(canvasId);
        await write('canvas/Branch/nodes/${ids.first}/content', value: '新正文');
        final edited = await toolManager.executeTool(
          name: 'Edit',
          input: {
            'path': 'canvas/Branch/nodes/${ids.first}/content',
            'old_text': '新',
            'new_text': '另一份',
          },
        );
        expect(edited['ok'], isTrue);
        final after = await db.canvasDao.getNodesByCanvas(canvasId);
        expect(
          after.map((n) => (n.id, n.x, n.y)).toList(),
          before.map((n) => (n.id, n.x, n.y)).toList(),
        );
        expect(
          (await read('canvas/Branch/layout'))['value']['mode'],
          canvasLayoutGrid,
        );
      },
    );
    test('undirected tree requests fail and leave graph untouched', () async {
      await createCanvas('Undirected');
      final a = await addNode('Undirected', {'type': 'sticky', 'content': 'A'});
      final b = await addNode('Undirected', {'type': 'sticky', 'content': 'B'});
      await addEdge('Undirected', {
        'source_node_id': a['id'],
        'target_node_id': b['id'],
        'type': 'relationship',
      });
      final before = await db.canvasDao.getNodesByCanvas(canvasId);
      for (final mode in [canvasLayoutTreeLr, canvasLayoutTreeTb]) {
        final result = await write('canvas/Undirected/layout', value: mode);
        expect(result['error_code'], 'failed_precondition');
      }
      expect(
        (await db.canvasDao.getNodesByCanvas(
          canvasId,
        )).map((node) => node.toJson()).toList(),
        before.map((node) => node.toJson()).toList(),
      );
      expect((await read('canvas/Undirected/layout'))['value']['mode'], isNull);
    });
    test('tool surfaces layout_conflict without partial coordinates', () async {
      await createCanvas('Concurrent');
      final a = await addNode('Concurrent', {'type': 'sticky', 'content': 'A'});
      await addNode('Concurrent', {'type': 'sticky', 'content': 'B'});
      final concurrentService = _LayoutContentService(
        db,
        CanvasService(
          db,
          layoutComputer: (request) async {
            await contentService.canvasService.updateNodePosition(
              nodeId: a['id'] as String,
              x: 123,
              y: 456,
            );
            return resolveCanvasGridLayout(request.nodes);
          },
        ),
      );
      final manager = AiToolManager(
        concurrentService,
        workingOverlayService: overlay,
      )..registerAllTools();
      final result = await manager.executeTool(
        name: 'Write',
        input: {'path': 'canvas/Concurrent/layout', 'value': 'grid'},
      );
      expect(result['error_code'], 'conflict');
      expect((await db.canvasDao.getNodeById(a['id'] as String))!.x, 123);
      expect((await db.canvasDao.getCanvasById(canvasId))!.layout, isNull);
    });

    test('把伏笔挪到其兑现章节所在列，并回报是否更新', () async {
      await createCanvas('伏笔地图');
      // 章节排 row 0，伏笔排 row 1 —— 模型摆节点时还不知道后面要连哪些边。
      final chapters = <Map<String, dynamic>>[];
      for (var i = 0; i < 3; i++) {
        await insertChapter('ch_$i', '第 $i 章');
        chapters.add(
          await addNode('伏笔地图', {
            'type': 'reference',
            'ref_type': 'chapter',
            'ref_id': 'ch_$i',
            'col': i,
            'row': 0,
          }),
        );
      }
      final foreshadowings = <Map<String, dynamic>>[];
      for (var i = 0; i < 2; i++) {
        await insertForeshadowing('fs_$i', '伏笔 $i');
        foreshadowings.add(
          await addNode('伏笔地图', {
            'type': 'reference',
            'ref_type': 'foreshadowing',
            'ref_id': 'fs_$i',
            'col': i,
            'row': 1,
          }),
        );
      }
      // fs_0 兑现在第 2 章、fs_1 兑现在第 0 章：两条边交叉。
      for (final (fsIndex, chapterIndex) in const [(0, 2), (1, 0)]) {
        final edge = await addEdge('伏笔地图', {
          'source_node_id': foreshadowings[fsIndex]['id'],
          'target_node_id': chapters[chapterIndex]['id'],
          'type': 'foreshadow_payoff',
        });
        expect(edge['ok'], isTrue);
      }

      final result = await autoLayout('伏笔地图');

      expect(result['ok'], isTrue);
      expect(result['updated'], isTrue);

      final f0 = await db.canvasDao.getNodeById(
        foreshadowings[0]['id'] as String,
      );
      final f1 = await db.canvasDao.getNodeById(
        foreshadowings[1]['id'] as String,
      );
      expect(f0!.x, canvasGridOrigin(2, 1).dx);
      expect(f1!.x, canvasGridOrigin(0, 1).dx);

      // 已经排好后再调一次不该继续挪动。
      final again = await autoLayout('伏笔地图');
      expect(again['updated'], isFalse);
    });

    for (final entry in {'open': true, 'layout': 'auto'}.entries) {
      test('${entry.key} 必须显式提供字段值后才执行动作', () async {
        await createCanvas('c');
        final node = await addNode('c', {'type': 'sticky', 'content': '保留正文'});
        final before = (await db.canvasDao.getNodeById(
          node['id'] as String,
        ))!.toJson();
        reportedActivities.clear();
        final path = 'canvas/c/${entry.key}';
        for (final extra in <Map<String, dynamic>>[
          {},
          {'fields': {}},
          {
            'fields': {'unrelated': entry.value},
          },
        ]) {
          final result = await toolManager.executeTool(
            name: 'Write',
            input: {'path': path, ...extra},
          );
          // 无关字段跳过后，路径字段照样算缺失，动作绝不能顺势执行。
          expect(
            result['error_code'],
            'invalid_argument',
            reason: '$extra: $result',
          );
          expect(
            result['ignored_fields'],
            (extra['fields'] as Map?)?.containsKey('unrelated') == true
                ? ['unrelated']
                : isNull,
            reason: '$extra: $result',
          );
          expect(reportedActivities, isEmpty);
          expect(
            (await db.canvasDao.getNodeById(node['id'] as String))!.toJson(),
            before,
          );
        }
        for (final extra in <Map<String, dynamic>>[
          {'value': null},
          {
            'value': null,
            'fields': {entry.key: entry.value},
          },
          {
            'fields': {'value': null},
          },
          {
            'fields': {entry.key: null},
          },
        ]) {
          final result = await toolManager.executeTool(
            name: 'Write',
            input: {'path': path, ...extra},
          );
          expect(
            result['error_code'],
            entry.key == 'layout' ||
                    (extra.containsKey('value') && extra['fields'] != null)
                ? 'invalid_argument'
                : 'invalid_argument',
            reason: '$extra: $result',
          );
          expect(reportedActivities, isEmpty);
          expect(
            (await db.canvasDao.getNodeById(node['id'] as String))!.toJson(),
            before,
          );
        }
        for (final extra in <Map<String, dynamic>>[
          {'value': entry.value},
          {
            'fields': {'value': entry.value},
          },
          {
            'fields': {entry.key: entry.value},
          },
        ]) {
          reportedActivities.clear();
          final result = await toolManager.executeTool(
            name: 'Write',
            input: {'path': path, ...extra},
          );
          expect(result['ok'], true, reason: '$extra: $result');
          expect(reportedActivities.map((activity) => activity.kind), [
            entry.key == 'open'
                ? CanvasAiActivityKind.open_canvas
                : CanvasAiActivityKind.auto_layout,
          ]);
        }
      });
    }

    test('文本字段将 null 与空字符串都解释为清空', () async {
      await createCanvas('c');
      final node = await addNode('c', {'type': 'sticky', 'content': '保留正文'});
      final path = '${selfPath(node)}/content';
      final cleared = await toolManager.executeTool(
        name: 'Write',
        input: {'path': path, 'value': null},
      );
      expect(cleared['updated'], true);
      expect((await read(path))['value'], '');
      expect((await write(path, value: ''))['updated'], false);
      expect((await read(path))['value'], '');
    });

    test('layout rejects unknown values', () async {
      await createCanvas('c');

      final result = await write('canvas/c/layout', value: 'radial');

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(result['field_constraint']['enum'], canvasLayoutModes);
    });

    test('写 open 广播 open_canvas —— 宿主据此把画布切进主内容区', () async {
      final id = await createCanvas('主线');
      reportedActivities.clear();

      final result = await write('canvas/主线/open', value: true);

      expect(result['ok'], isTrue);
      expect(result, {'ok': true});
      final opened = reportedActivities
          .where((a) => a.kind == CanvasAiActivityKind.open_canvas)
          .toList();
      expect(opened, hasLength(1));
      expect(opened.single.canvasId, id);
    });

    test('open 只接受 true', () async {
      await createCanvas('主线');
      reportedActivities.clear();

      final result = await write('canvas/主线/open', value: 'maybe');

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(reportedActivities, isEmpty);
    });

    test('open 不存在的画布返回 canvas_not_found', () async {
      final result = await write('canvas/查无此画布/open', value: true);

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'not_found');
    });

    test('Read layout 回报 off_grid，手拖过的节点不参与重排', () async {
      await createCanvas('c');
      await addNode('c', {
        'type': 'sticky',
        'content': '网格上',
        'col': 0,
        'row': 0,
      });
      await addNode('c', {
        'type': 'sticky',
        'content': '手摆的',
        'x': 13,
        'y': 27,
      });

      final result = await read('canvas/c/layout');

      expect(result['value']['node_count'], 2);
      expect(result['value']['off_grid'], 1);
    });
  });

  // ---- Create 节点：reference ----

  group('Create 节点 reference', () {
    for (final refType in [
      entityTypeCharacter,
      canvasNodeRefTypeScreenplayScene,
    ]) {
      test(
        '$refType preserves raw reference IDs and rejects invalid types without writes',
        () async {
          final String refId;
          if (refType == entityTypeCharacter) {
            refId = 'char_raw';
            await insertCharacter(refId, 'Existing');
            // 如果数字/布尔值被错误地字符串化，下面这些已有 ID 会使调用成功。
            for (final id in ['42', 'true', 'false']) {
              await insertCharacter(id, id);
            }
          } else {
            final screenplay = ScreenplayService(db);
            final initial = await screenplay.createInitialStructure();
            refId = await screenplay.createScene(
              screenplayId: (await db.screenplayDao.getRoot())!.id,
              episodeId: initial.episodeId,
            );
          }
          await createCanvas('raw-refs');
          final valid = await addNode('raw-refs', {
            'type': canvasNodeTypeReference,
            'ref_type': refType,
            'ref_id': refId,
          });
          expect(valid['ok'], isTrue, reason: '$valid');
          final before = await db.canvasDao.getNodesByCanvas(canvasId);
          expect(before.single.refId, refId);
          for (final (raw, errorCode) in <(Object?, String)>[
            ('', 'invalid_argument'),
            (null, 'invalid_argument'),
            (' $refId ', 'invalid_argument'),
            ('   ', 'invalid_argument'),
            (42, 'invalid_argument'),
            (true, 'invalid_argument'),
            (false, 'invalid_argument'),
          ]) {
            final rejected = await addNode('raw-refs', {
              'type': canvasNodeTypeReference,
              'ref_type': refType,
              'ref_id': raw,
            });
            expect(rejected['ok'], isFalse, reason: '$raw: $rejected');
            expect(
              rejected['error_code'],
              errorCode,
              reason: '$raw: $rejected',
            );
            expect(await db.canvasDao.getNodesByCanvas(canvasId), before);
          }
        },
      );
    }

    test(
      'scene IDs create distinct references, read back and reject missing scenes',
      () async {
        final screenplay = ScreenplayService(db);
        final initial = await screenplay.createInitialStructure();
        final rootId = (await db.screenplayDao.getRoot())!.id;
        final sceneId = await screenplay.createScene(
          screenplayId: rootId,
          episodeId: initial.episodeId,
          title: 'Opening',
        );
        await createCanvas('scene-refs');
        final first = await addNode('scene-refs', {
          'type': 'reference',
          'ref_type': 'screenplay_scene',
          'ref_id': sceneId,
        });
        final second = await addNode('scene-refs', {
          'type': 'reference',
          'ref_type': 'screenplay_scene',
          'ref_id': sceneId,
        });
        expect(first['ok'], isTrue, reason: '$first');
        expect(second['ok'], isTrue, reason: '$second');
        expect(first['id'], isNot(second['id']));
        final detail = await read(selfPath(first));
        expect(detail['ref_type'], 'screenplay_scene');
        expect(detail['ref_id'], sceneId);
        expect(detail['title'], 'Opening');
        final listing = await read('canvas/scene-refs/nodes');
        expect(listing['entries'], hasLength(2));
        await screenplay.deleteScene(sceneId);
        final rejected = await addNode('scene-refs', {
          'type': 'reference',
          'ref_type': 'screenplay_scene',
          'ref_id': sceneId,
        });
        expect(rejected['ok'], isFalse);
        expect(rejected['error_code'], 'invalid_argument');
        expect(await db.canvasDao.getNodesByCanvas(canvasId), hasLength(2));
      },
    );

    test('creates reference node for existing character', () async {
      await createCanvas('c');
      await insertCharacter('char_1', '主角');

      final result = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_1',
        'x': 100,
        'y': 200,
      });

      expect(result['ok'], isTrue);
      expect(result['id'], isA<String>());
      expect(selfPath(result), startsWith('canvas/c/nodes/'));

      final node = await db.canvasDao.getNodeById(result['id']);
      expect(node, isNotNull);
      expect(node!.type, canvasNodeTypeReference);
      expect(node.refType, entityTypeCharacter);
      expect(node.refId, 'char_1');
      expect(node.title, '主角'); // 缓存资源标题
    });

    test('returns invalid_reference when refId does not exist', () async {
      await createCanvas('c');

      final result = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'ghost',
        'x': 0,
        'y': 0,
      });

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
    });
  });

  // ---- Create 节点：sticky ----

  group('画布节奏背压', () {
    test('画布页开着时写工具等这一步演完才返回', () async {
      await createCanvas('c');
      final step = Completer<void>();
      pacer = (_) => step.future;

      var returned = false;
      final pending =
          addNode('c', {'type': 'sticky', 'title': '灵感', 'content': '正文'}).then(
            (result) {
              returned = true;
              return result;
            },
          );

      // 库已经写完、事件已经报上去，但画面还没演完：调用不能先返回。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(reportedActivities.map((a) => a.kind), [
        CanvasAiActivityKind.add_node,
      ]);
      expect(returned, isFalse);

      step.complete();
      final result = await pending;
      expect(result['ok'], isTrue);
    });

    test('画布页卡住时写工具到上限也照样返回', () async {
      await createCanvas('c');
      // 永不完成：UI 卡死、导演异常，都不能拖住 AI 回合。
      pacer = (_) => Completer<void>().future;

      final watch = Stopwatch()..start();
      final result = await addNode('c', {
        'type': 'sticky',
        'title': '灵感',
        'content': '正文',
      });

      expect(result['ok'], isTrue);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });

  group('Create 节点 sticky', () {
    test('creates sticky node with content', () async {
      await createCanvas('c');

      final result = await addNode('c', {
        'type': 'sticky',
        'title': '灵感',
        'content': '主角与反派对决',
        'x': 50,
        'y': 75,
      });

      expect(result['ok'], isTrue);
      expect(result['id'], isA<String>());

      final node = await db.canvasDao.getNodeById(result['id']);
      expect(node, isNotNull);
      expect(node!.type, canvasNodeTypeSticky);
      expect(node.title, '灵感');
      expect(node.content, '主角与反派对决');
    });

    test(
      'sticky content is required by the public contract but may be empty',
      () async {
        await createCanvas('c');

        final result = await addNode('c', {'type': 'sticky', 'x': 0, 'y': 0});

        expect(result['ok'], isFalse);
        expect(result['error_code'], 'invalid_argument');
        expect(result['validation_errors'], [
          {
            'code': 'required',
            'fields': ['content'],
          },
        ]);
        expect(await db.canvasDao.getNodesByCanvas(canvasId), isEmpty);
        final empty = await addNode('c', {'type': 'sticky', 'content': ''});
        expect(empty['ok'], isTrue, reason: '$empty');
        expect(
          (await db.canvasDao.getNodeById(empty['id'] as String))!.content,
          '',
        );
      },
    );

    test('缺 type 时报错并带上 create 入参契约', () async {
      await createCanvas('c');

      final result = await addNode('c', {'content': 'x'});

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      final contract = result['input_contract'] as Map<String, dynamic>;
      expect(contract['required_fields'], contains('type'));
      expect(contract['allowed_fields'], contains('col'));
    });

    test('color 落到 style，缺省时用默认纸色', () async {
      await createCanvas('c');

      final colored = await addNode('c', {
        'type': 'sticky',
        'content': '主角坠崖',
        'color': 'rose',
        'col': 0,
        'row': 0,
      });
      final plain = await addNode('c', {
        'type': 'sticky',
        'content': '开局',
        'col': 1,
        'row': 0,
      });

      final coloredNode = await db.canvasDao.getNodeById(colored['id']);
      final plainNode = await db.canvasDao.getNodeById(plain['id']);
      expect(canvasNodeColorValueOf(coloredNode!.style), 'rose');
      expect(
        canvasNodeColorValueOf(plainNode!.style),
        canvasStickyColorDefault,
      );
    });

    test('非法 color 报错而不是静默换成默认色', () async {
      // 静默降级会让模型以为配色生效了,下一步继续按错误的分组往下画。
      await createCanvas('c');

      final result = await addNode('c', {
        'type': 'sticky',
        'content': 'x',
        'color': 'neon',
      });

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
    });
  });

  // ---- 摆位 ----
  //
  // 回归：模型此前需要自己算 x/y，按 260 排 280 宽的便签，整条时间线互相压
  // 20px。现在它只表达「第几格 / 挨着谁」，坐标与避让由算法保证。

  group('摆位', () {
    Future<Map<String, dynamic>> addSticky(Map<String, dynamic> extra) {
      return addNode('c', {'type': 'sticky', 'content': 'beat', ...extra});
    }

    setUp(() async {
      await createCanvas('c');
    });

    test('col/row 换算成画布坐标，并回报实际落点', () async {
      final result = await addSticky({'col': 2, 'row': 1});

      expect(result['ok'], isTrue);
      expect(result['x'], canvasGridOrigin(2, 1).dx);
      expect(result['y'], canvasGridOrigin(2, 1).dy);
      expect(result['col'], 2);
      expect(result['row'], 1);
      expect(result['adjusted'], isFalse);
    });

    test('一整行 col 递增的便签互不重叠', () async {
      for (var col = 0; col < 4; col++) {
        expect((await addSticky({'col': col, 'row': 0}))['ok'], isTrue);
      }

      final nodes = await db.canvasDao.getNodesByCanvas(canvasId);
      final rects = [
        for (final node in nodes)
          Rect.fromLTWH(
            node.x,
            node.y,
            node.width ?? canvasStickyDefaultWidth,
            node.height ?? canvasStickyDefaultHeight,
          ),
      ];
      expect(rects, hasLength(4));
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(
            rects[i].overlaps(rects[j]),
            isFalse,
            reason: '第 $i 与第 $j 个便签重叠了',
          );
        }
      }
    });

    test('near + direction 摆到锚点节点右侧', () async {
      final anchor = await addSticky({'col': 0, 'row': 0});
      final result = await addSticky({
        'near': anchor['id'],
        'direction': 'right',
      });

      expect(result['ok'], isTrue);
      expect(result['x'], canvasStickyDefaultWidth + canvasGridGapX);
      expect(result['y'], 0);
    });

    test('目标格已被占用时自动避让并回报 adjusted', () async {
      await addSticky({'col': 1, 'row': 0});
      final result = await addSticky({'col': 1, 'row': 0});

      expect(result['adjusted'], isTrue);
      expect(result['x'], greaterThan(canvasGridOrigin(1, 0).dx));
    });

    test('不给任何摆位参数时追加到下一个空格', () async {
      await addSticky({'col': 0, 'row': 0});
      final result = await addSticky({});

      expect(result['ok'], isTrue);
      expect(result['col'], 1);
      expect(result['row'], 0);
    });

    test('x/y 是逃生口：原样落库，不被算法挪走', () async {
      await addSticky({'col': 0, 'row': 0});
      final result = await addSticky({'x': 12.5, 'y': '34.25'});

      expect(result['x'], 12.5);
      expect(result['y'], 34.25);
      expect(result['adjusted'], isFalse);
    });

    test('非法 direction 报错而不是静默降级', () async {
      final anchor = await addSticky({'col': 0, 'row': 0});
      final result = await addSticky({
        'near': anchor['id'],
        'direction': 'northwest',
      });

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
    });
  });

  // ---- Create 边 ----

  group('Create 边', () {
    test('creates edge between nodes of same canvas', () async {
      await createCanvas('c');
      await insertCharacter('char_1', '主角');
      await insertCharacter('char_2', '反派');

      final n1 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_1',
        'x': 0,
        'y': 0,
      });
      final n2 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_2',
        'x': 100,
        'y': 0,
      });

      final result = await addEdge('c', {
        'source_node_id': n1['id'],
        'target_node_id': n2['id'],
        'type': 'relationship',
        'label': '宿敌',
      });

      expect(n1['created'], isTrue, reason: '$n1');
      expect(result['ok'], isTrue);
      expect(result['created'], isTrue);
      expect(result['id'], isA<String>());
      expect(selfPath(result), startsWith('canvas/c/edges/'));
    });

    test(
      'returns invalid_edge_semantics when endpoints cross canvases',
      () async {
        await createCanvas('c1');
        await insertCharacter('char_1', '主角');
        final n1 = await addNode('c1', {
          'type': 'reference',
          'ref_type': 'character',
          'ref_id': 'char_1',
          'x': 0,
          'y': 0,
        });

        await createCanvas('c2');
        final n2 = await addNode('c2', {
          'type': 'reference',
          'ref_type': 'character',
          'ref_id': 'char_1',
          'x': 0,
          'y': 0,
        });

        // n1 属于 c1，n2 属于 c2，路径指向 c2 → 端点跨 canvas
        final result = await addEdge('c2', {
          'source_node_id': n1['id'],
          'target_node_id': n2['id'],
          'type': 'relationship',
        });

        expect(result['ok'], isFalse);
        expect(result['error_code'], 'invalid_argument');
      },
    );

    test(
      'returns invalid_edge_semantics for wrong foreshadow_payoff semantics',
      () async {
        await createCanvas('c');
        await insertCharacter('char_1', '主角');
        await insertChapter('ch_1', '第一章');

        final charNode = await addNode('c', {
          'type': 'reference',
          'ref_type': 'character',
          'ref_id': 'char_1',
          'x': 0,
          'y': 0,
        });
        final chNode = await addNode('c', {
          'type': 'reference',
          'ref_type': 'chapter',
          'ref_id': 'ch_1',
          'x': 100,
          'y': 0,
        });

        // source 非 foreshadowing → 语义错
        final result = await addEdge('c', {
          'source_node_id': charNode['id'],
          'target_node_id': chNode['id'],
          'type': 'foreshadow_payoff',
        });

        expect(result['ok'], isFalse);
        expect(result['error_code'], 'invalid_argument');
      },
    );

    test('returns duplicate_edge for same (source, target, type)', () async {
      await createCanvas('c');
      await insertCharacter('char_1', '主角');
      await insertCharacter('char_2', '反派');

      final n1 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_1',
        'x': 0,
        'y': 0,
      });
      final n2 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_2',
        'x': 100,
        'y': 0,
      });

      await addEdge('c', {
        'source_node_id': n1['id'],
        'target_node_id': n2['id'],
        'type': 'causal',
      });

      final dup = await addEdge('c', {
        'source_node_id': n1['id'],
        'target_node_id': n2['id'],
        'type': 'causal',
      });

      expect(dup['ok'], isFalse);
      expect(dup['error_code'], 'already_exists');
    });

    test('边类型非法时带上全部合法值', () async {
      await createCanvas('c');
      await insertCharacter('char_1', '主角');
      await insertCharacter('char_2', '反派');

      final n1 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_1',
        'x': 0,
        'y': 0,
      });
      final n2 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_2',
        'x': 100,
        'y': 0,
      });

      final result = await addEdge('c', {
        'source_node_id': n1['id'],
        'target_node_id': n2['id'],
        'type': 'arrow',
      });

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(result['field_constraint'], {
        'field': 'type',
        'enum': canvasEdgeTypes,
      });
    });

    test('缺端点时报错并提示去 nodes listing 复制 id', () async {
      await createCanvas('c');

      final result = await addEdge('c', {'type': 'relationship'});

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(result['missing_fields'], contains('source_node_id'));
      expect(result['hint'], contains('Read /_schema/canvas'));
    });
  });

  // ---- Read listing ----

  group('Read 节点 listing', () {
    test('返回节点条目与通用分页字段', () async {
      await createCanvas('c');
      await insertCharacter('char_1', '主角');

      await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_1',
        'x': 0,
        'y': 0,
      });
      await addNode('c', {'type': 'sticky', 'content': '便签', 'x': 10, 'y': 10});

      final result = await read('canvas/c/nodes');

      expect(result['canvas'], 'c');
      final entries = result['entries'] as List;
      expect(entries, hasLength(2));
      expect(entries.first['id'], isA<String>());
      expect(entries.first['type'], isA<String>());
      expect(entries.first['x'], isA<double>());
      expect(entries.first['y'], isA<double>());
      // 网格坐标直接给出来，模型不用自己按 pitch 反算。
      expect(entries.first['col'], isA<int>());
      expect(entries.first['row'], isA<int>());
      expect(entries.first['path'], startsWith('canvas/c/nodes/'));

      expect(result['total'], 2);
      expect(result['limit'], 50);
      expect(result['has_more'], isFalse);
    });

    test('limit 生效并标记 has_more', () async {
      await createCanvas('c');
      for (var i = 0; i < 3; i++) {
        await addNode('c', {
          'type': 'sticky',
          'content': 'node_$i',
          'x': i.toDouble(),
          'y': 0,
        });
      }

      final result = await read('canvas/c/nodes', limit: 2);

      expect((result['entries'] as List), hasLength(2));
      expect(result['total'], 3);
      expect(result['limit'], 2);
      expect(result['has_more'], isTrue);
    });

    test('offset/limit 翻页', () async {
      await createCanvas('c');
      for (var i = 0; i < 5; i++) {
        await addNode('c', {
          'type': 'sticky',
          'content': 'node_$i',
          'x': i.toDouble(),
          'y': 0,
        });
      }

      final page2 = await read('canvas/c/nodes', offset: 2, limit: 2);
      expect(page2['total'], 5);
      expect(page2, isNot(contains('offset')));
      expect(page2['next_offset'], 4);
      expect(page2['limit'], 2);
      expect(page2['has_more'], isTrue);
      expect((page2['entries'] as List), hasLength(2));

      final page3 = await read('canvas/c/nodes', offset: 4, limit: 2);
      expect(page3['has_more'], isFalse);
      expect(page3, isNot(contains('offset')));
      expect(page3, isNot(contains('next_offset')));
      expect(page3['total'], 5);
      expect((page3['entries'] as List), hasLength(1));
    });

    test('Read 单个节点与单个字段', () async {
      await createCanvas('c');
      final node = await addNode('c', {
        'type': 'sticky',
        'content': '主角坠崖',
        'col': 1,
        'row': 2,
      });
      final path = selfPath(node);

      final resource = await read(path);
      expect(resource['content'], '主角坠崖');
      expect(resource['col'], 1);
      expect(resource['row'], 2);

      final field = await read('$path/content');
      expect(field['value'], '主角坠崖');
    });
  });

  group('Read 边 listing', () {
    test('返回边条目与通用分页字段', () async {
      await createCanvas('c');
      await insertCharacter('char_1', '主角');
      await insertCharacter('char_2', '反派');

      final n1 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_1',
        'x': 0,
        'y': 0,
      });
      final n2 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_2',
        'x': 10,
        'y': 0,
      });

      await addEdge('c', {
        'source_node_id': n1['id'],
        'target_node_id': n2['id'],
        'type': 'relationship',
      });

      final result = await read('canvas/c/edges');

      expect(result['canvas'], 'c');
      final entries = result['entries'] as List;
      expect(entries, hasLength(1));
      expect(entries.first['id'], isA<String>());
      expect(result['total'], 1);
      expect(result['has_more'], isFalse);
    });
  });

  group('Read 画布', () {
    test('canvas listing 带节点与边计数', () async {
      await createCanvas('主线');
      await addNode('主线', {'type': 'sticky', 'content': 'a'});

      final result = await read('canvas');

      final entries = result['entries'] as List;
      expect(entries, hasLength(1));
      expect(entries.first['name'], '主线');
      expect(entries.first['path'], 'canvas/主线');
      expect(entries.first['node_count'], 1);
      expect(entries.first['edge_count'], 0);
    });

    test('单张画布返回画布 path，子资源导航交给 pathSchema', () async {
      await createCanvas('主线');

      final result = await read('canvas/主线');

      expect(result['node_count'], 0);
      // _links.subresources 已删；/canvas/{name}/nodes 等路径由 pathSchema 的
      // 子资源清单提供，响应只回权威 path。
      expect(result['path'], 'canvas/主线');
      expect(result.containsKey('_links'), isFalse);
    });
  });

  // ---- Remove ----

  group('Remove', () {
    test('删节点：软删并级联硬删它的边', () async {
      await createCanvas('c');
      await insertCharacter('char_1', '主角');
      await insertCharacter('char_2', '反派');

      final n1 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_1',
        'x': 0,
        'y': 0,
      });
      final n2 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_2',
        'x': 100,
        'y': 0,
      });
      final edgeResult = await addEdge('c', {
        'source_node_id': n1['id'],
        'target_node_id': n2['id'],
        'type': 'relationship',
      });

      final result = await remove(selfPath(n1));

      expect(result['ok'], isTrue);
      expect(result['removed'], isTrue);
      expect(await db.canvasDao.getNodeById(n1['id']), isNull);
      expect(await db.canvasDao.getEdgeById(edgeResult['id']), isNull);
    });

    test('删不存在的节点报 node_not_found，不谎报成功', () async {
      // 旧的 CanvasRemoveNode 无条件返回 deleted:true，模型会以为删掉了。
      await createCanvas('c');

      final result = await remove('canvas/c/nodes/ghost_node');

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'not_found');
    });

    test('force 删不存在的节点按幂等处理并标 missing', () async {
      await createCanvas('c');

      final result = await remove('canvas/c/nodes/ghost_node', force: true);

      expect(result['ok'], isTrue);
      expect(result['removed'], isTrue);
      expect(result['missing'], isTrue);
    });

    test('删边：硬删', () async {
      await createCanvas('c');
      await insertCharacter('char_1', '主角');
      await insertCharacter('char_2', '反派');

      final n1 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_1',
        'x': 0,
        'y': 0,
      });
      final n2 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_2',
        'x': 100,
        'y': 0,
      });
      final edgeResult = await addEdge('c', {
        'source_node_id': n1['id'],
        'target_node_id': n2['id'],
        'type': 'relationship',
      });

      final result = await remove(selfPath(edgeResult));

      expect(result['ok'], isTrue);
      expect(result['removed'], isTrue);
      expect(await db.canvasDao.getEdgeById(edgeResult['id']), isNull);
    });

    test('删不存在的边报 edge_not_found，不谎报成功', () async {
      await createCanvas('c');

      final result = await remove('canvas/c/edges/ghost_edge');

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'not_found');
    });

    test('force 删不存在的边按幂等处理并标 missing', () async {
      await createCanvas('c');

      final result = await remove('canvas/c/edges/ghost_edge', force: true);

      expect(result['ok'], isTrue);
      expect(result['removed'], isTrue);
      expect(result['missing'], isTrue);
    });

    test('删画布：软删', () async {
      await createCanvas('c');

      final result = await remove('canvas/c');

      expect(result['ok'], isTrue);
      expect(result['removed'], isTrue);
      expect(await contentService.canvasService.getCanvasByName('c'), isNull);
    });
  });

  // ---- Write 节点 ----

  group('Write 节点', () {
    test('便签原地转引用并转回，保留正文、位置与连线', () async {
      await createCanvas('c');
      final screenplay = ScreenplayService(db);
      final initial = await screenplay.createInitialStructure();
      final sceneId = await screenplay.createScene(
        screenplayId: (await db.screenplayDao.getRoot())!.id,
        episodeId: initial.episodeId,
        title: '逃生场景',
      );
      final node = await addNode('c', {
        'type': 'sticky',
        'title': '地铁线',
        'content': '救下幸存者，损失一箱物资。',
        'color': 'rose',
        'x': 20,
        'y': 40,
        'width': 300,
        'height': 200,
      });
      final other = await addNode('c', {'type': 'sticky', 'content': '汇合'});
      await addEdge('c', {
        'source_node_id': node['id'],
        'target_node_id': other['id'],
        'type': 'causal',
        'label': '回到基地',
      });
      final before = (await db.canvasDao.getNodeById(node['id']))!;
      final edges = await db.canvasDao.getEdgesByCanvas(canvasId);
      final path = selfPath(node);
      reportedActivities.clear();

      final result = await write(
        path,
        fields: {
          'type': 'reference',
          'ref_type': 'screenplay_scene',
          'ref_id': sceneId,
        },
      );

      expect(result['ok'], isTrue, reason: '$result');
      expect(result['path'], path);
      final reference = (await db.canvasDao.getNodeById(node['id']))!;
      expect(
        reference.toJson(),
        before
            .copyWith(
              type: 'reference',
              refType: const Value('screenplay_scene'),
              refId: Value(sceneId),
              title: '逃生场景',
              updatedAt: reference.updatedAt,
            )
            .toJson(),
      );
      expect((await read(path))['content'], isNull);
      expect(await db.canvasDao.getEdgesByCanvas(canvasId), edges);
      expect(await db.canvasDao.getNodesByCanvas(canvasId), hasLength(2));
      expect(reportedActivities.map((activity) => activity.kind), [
        CanvasAiActivityKind.update_node,
      ]);

      final restored = await write(path, fields: {'type': 'sticky'});
      expect(restored['ok'], isTrue, reason: '$restored');
      final sticky = (await db.canvasDao.getNodeById(node['id']))!;
      expect(sticky.refType, isNull);
      expect(sticky.refId, isNull);
      expect(sticky.content, before.content);
      expect(sticky.title, '逃生场景');
      expect(
        (sticky.x, sticky.y, sticky.width, sticky.height),
        (before.x, before.y, before.width, before.height),
      );
      expect(await db.canvasDao.getEdgesByCanvas(canvasId), edges);
    });

    test('引用目标可原地更换，标题跟随目标，转便签可同时写正文', () async {
      await createCanvas('c');
      await insertCharacter('char_a', '角色甲');
      await insertCharacter('char_b', '角色乙');
      await insertChapter('chapter_target', '目标章节');
      final node = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_a',
      });
      final path = selfPath(node);
      expect((await write('$path/ref_id', value: 'char_b'))['ok'], isTrue);
      expect((await read(path))['title'], '角色乙');
      expect(
        (await write(
          path,
          fields: {'ref_type': 'chapter', 'ref_id': 'chapter_target'},
        ))['ok'],
        isTrue,
      );
      expect((await read(path))['title'], '目标章节');

      final result = await write(
        path,
        fields: {'type': 'sticky', 'title': '新的构想', 'content': '从这里继续设计'},
      );
      expect(result['ok'], isTrue, reason: '$result');
      final sticky = (await db.canvasDao.getNodeById(node['id']))!;
      expect(
        (sticky.type, sticky.refType, sticky.refId),
        ('sticky', null, null),
      );
      expect((sticky.title, sticky.content), ('新的构想', '从这里继续设计'));
    });

    test('转换失败不会先写入位置或样式', () async {
      await createCanvas('c');
      await insertCharacter('char_a', '角色甲');
      final node = await addNode('c', {
        'type': 'sticky',
        'title': '原便签',
        'content': '保留正文',
        'x': 20,
        'y': 40,
      });
      final before = await db.canvasDao.getNodeById(node['id']);
      for (final fields in <Map<String, dynamic>>[
        {'type': 'reference'},
        {'type': 'reference', 'ref_type': 'character', 'ref_id': 'missing'},
        {'type': 'reference', 'ref_type': 'character', 'ref_id': null},
        {
          'type': 'reference',
          'ref_type': 'character',
          'ref_id': 'char_a',
          'content': '不能覆盖',
        },
        {'type': 'sticky', 'ref_type': 'character', 'ref_id': 'char_a'},
        {'type': 'unknown'},
      ]) {
        reportedActivities.clear();
        final result = await write(
          selfPath(node),
          fields: {...fields, 'x': 1000, 'color': 'rose'},
        );
        expect(result['ok'], isFalse, reason: '$fields: $result');
        expect(
          (await db.canvasDao.getNodeById(node['id']))!.toJson(),
          before!.toJson(),
        );
        expect(reportedActivities, isEmpty);
      }
    });

    test('现有引用不能清空目标或改到不存在的资源', () async {
      await createCanvas('c');
      await insertCharacter('char_a', '角色甲');
      final node = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_a',
      });
      final before = await db.canvasDao.getNodeById(node['id']);
      for (final fields in <Map<String, dynamic>>[
        {'ref_id': null},
        {'ref_id': 'missing'},
        {'ref_type': null},
        {'ref_type': 'chapter'},
      ]) {
        final result = await write(
          selfPath(node),
          fields: {...fields, 'x': 1000},
        );
        expect(result['ok'], isFalse, reason: '$result');
        expect(await db.canvasDao.getNodeById(node['id']), before);
      }
    });

    test('转换不能破坏已有伏笔回收边，失败保留两个端点与边', () async {
      await createCanvas('c');
      await insertForeshadowing('fore_a', '伏笔');
      await insertChapter('chapter_target', '回收章节');
      await insertCharacter('char_a', '角色甲');
      final source = await addNode('c', {
        'type': 'reference',
        'ref_type': 'foreshadowing',
        'ref_id': 'fore_a',
      });
      final target = await addNode('c', {
        'type': 'reference',
        'ref_type': 'chapter',
        'ref_id': 'chapter_target',
      });
      await addEdge('c', {
        'source_node_id': source['id'],
        'target_node_id': target['id'],
        'type': 'foreshadow_payoff',
      });
      final nodes = await db.canvasDao.getNodesByCanvas(canvasId);
      final edges = await db.canvasDao.getEdgesByCanvas(canvasId);
      for (final node in [source, target]) {
        for (final fields in <Map<String, dynamic>>[
          {'type': 'sticky', 'content': '保留连线'},
          {'ref_type': 'character', 'ref_id': 'char_a'},
        ]) {
          reportedActivities.clear();
          final result = await write(
            selfPath(node),
            fields: {...fields, 'x': 1000},
          );
          expect(result['error_code'], 'invalid_argument', reason: '$result');
          expect(await db.canvasDao.getNodesByCanvas(canvasId), nodes);
          expect(await db.canvasDao.getEdgesByCanvas(canvasId), edges);
          expect(reportedActivities, isEmpty);
        }
      }
    });

    test('col/row 重新摆位', () async {
      await createCanvas('c');
      final node = await addNode('c', {
        'type': 'sticky',
        'content': 'test',
        'col': 0,
        'row': 0,
      });

      final result = await write(selfPath(node), fields: {'col': 2, 'row': 1});

      expect(result['ok'], isTrue);
      expect(result['col'], 2);
      expect(result['row'], 1);
      final stored = await db.canvasDao.getNodeById(node['id']);
      expect(stored!.x, canvasGridOrigin(2, 1).dx);
      expect(stored.y, canvasGridOrigin(2, 1).dy);
    });

    test('x/y 成对写入', () async {
      await createCanvas('c');
      final node = await addNode('c', {
        'type': 'sticky',
        'content': 'test',
        'x': 0,
        'y': 0,
      });

      final result = await write(selfPath(node), fields: {'x': 42, 'y': 17});

      expect(result['ok'], isTrue);
      final stored = await db.canvasDao.getNodeById(node['id']);
      expect(stored!.x, 42);
      expect(stored.y, 17);
    });

    test('只写 x 时保留原来的 y', () async {
      await createCanvas('c');
      final node = await addNode('c', {
        'type': 'sticky',
        'content': 'test',
        'x': 10,
        'y': 90,
      });

      await write(selfPath(node), fields: {'x': 42});

      final stored = await db.canvasDao.getNodeById(node['id']);
      expect(stored!.x, 42);
      expect(stored.y, 90);
    });

    test('写 title 和 color，不动正文', () async {
      await createCanvas('c');
      final node = await addNode('c', {
        'type': 'sticky',
        'content': 'beat',
        'col': 0,
        'row': 0,
      });

      final result = await write(
        selfPath(node),
        fields: {'title': '代价', 'color': 'rose'},
      );

      expect(result['ok'], isTrue);
      final stored = await db.canvasDao.getNodeById(node['id']);
      expect(stored!.title, '代价');
      expect(canvasNodeColorValueOf(stored.style), 'rose');
      expect(stored.content, 'beat');
    });

    test('color 接受自定义 hex，统一存成大写', () async {
      await createCanvas('c');
      final node = await addNode('c', {
        'type': 'sticky',
        'content': 'beat',
        'col': 0,
        'row': 0,
      });
      final ok = await write(selfPath(node), fields: {'color': '#3366cc'});
      expect(ok['ok'], isTrue, reason: '$ok');
      final stored = await db.canvasDao.getNodeById(node['id']);
      expect(canvasNodeColorValueOf(stored!.style), '#3366CC');

      final bad = await write(selfPath(node), fields: {'color': '#3366c'});
      expect(bad['ok'], isFalse);
      expect(bad['error_code'], 'invalid_argument');
    });

    test('非法 color 报错而不是静默忽略', () async {
      await createCanvas('c');
      final node = await addNode('c', {
        'type': 'sticky',
        'content': 'beat',
        'col': 0,
        'row': 0,
      });

      final result = await write(selfPath(node), fields: {'color': 'neon'});

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
    });

    test('一个可写字段都没给时报 missing_required_fields', () async {
      await createCanvas('c');
      final node = await addNode('c', {'type': 'sticky', 'content': 'beat'});

      final result = await write(selfPath(node), fields: {});

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
    });

    test(
      'reference content Write refuses the entire mutation before moving',
      () async {
        await createCanvas('c');
        await insertCharacter('char_guard', '主角');
        final node = await addNode('c', {
          'type': 'reference',
          'ref_type': 'character',
          'ref_id': 'char_guard',
        });
        final path = selfPath(node);
        final before = await read(path);
        for (final result in [
          await write('$path/content', value: '非法正文'),
          await write(path, fields: {'x': 420.5, 'content': '非法正文'}),
        ]) {
          expect(result['error_code'], 'invalid_argument', reason: '$result');
          expect(await read(path), before);
        }
      },
    );

    test(
      'canonical validation preserves empty content and layout aliases',
      () async {
        await createCanvas('c');
        final node = await addNode('c', {'type': ' sticky ', 'content': '正文'});
        expect(node['error'], isNull, reason: '$node');
        expect(
          (await write(selfPath(node), fields: {'content': ''}))['updated'],
          true,
        );
        expect((await read('${selfPath(node)}/content'))['value'], '');
        expect(
          (await write('canvas/c', fields: {'description': ''}))['updated'],
          false,
        );
        expect((await write('canvas/c/layout', value: ' AUTO '))['ok'], true);
      },
    );

    test(
      'canvas search paths Read and Replace the matched sticky field',
      () async {
        await createCanvas('nodes');
        final node = await addNode('nodes', {
          'type': 'sticky',
          'content': '查找正文',
        });
        final path = '${selfPath(node)}/content';
        final glob = await toolManager.executeTool(
          name: 'Glob',
          input: {'path': 'canvas/nodes', 'pattern': '**/content'},
        );
        expect(glob['matches'], contains(path), reason: '$glob');
        expect((await read(path))['value'], '查找正文');
        final grep = await toolManager.executeTool(
          name: 'Grep',
          input: {'path': 'canvas/nodes', 'pattern': '查找正文'},
        );
        expect(grep.toString(), contains(path));
        final replace = await toolManager.executeTool(
          name: 'Replace',
          input: {
            'path': 'canvas/nodes',
            'pattern': '查找正文',
            'replacement': '替换正文',
            'dry_run': false,
          },
        );
        expect(replace['applied_fields'], 1, reason: '$replace');
        expect((await read(path))['value'], '替换正文');
      },
    );

    group('mixed canvas search', () {
      late String stickyPath;
      late String referencePath;

      setUp(() async {
        await createCanvas('mixed');
        await insertChapter('search_chapter', '章节线索');
        final reference = await addNode('mixed', {
          'type': 'reference',
          'ref_type': 'chapter',
          'ref_id': 'search_chapter',
        });
        final sticky = await addNode('mixed', {
          'type': 'sticky',
          'content': '便签线索',
        });
        referencePath = selfPath(reference);
        stickyPath = selfPath(sticky);
      });

      test(
        'read projections retain applicable fields and keep color out of Grep',
        () async {
          final listing = await read('canvas/mixed/nodes');
          final entries = (listing['entries'] as List).cast<Map>();
          final sticky = entries.singleWhere(
            (entry) => entry['path'] == stickyPath,
          );
          final reference = entries.singleWhere(
            (entry) => entry['path'] == referencePath,
          );
          expect(sticky, contains('color'));
          expect(sticky, isNot(contains('content')));
          // 引用节点也能设色；未设色时读到 null。
          expect(reference['color'], isNull);
          expect(reference, isNot(contains('content')));
          expect((await read(stickyPath))['content'], '便签线索');
          final detail = await read(referencePath);
          expect(detail['title'], '章节线索');
          expect(detail, isNot(contains('content')));
          expect(detail['color'], isNull);
          final color = (await read('$stickyPath/color'))['value'];
          expect(color, sticky['color']);
          final grep = await toolManager.executeTool(
            name: 'Grep',
            input: {'path': stickyPath, 'pattern': '^$color\$'},
          );
          expect(grep['ok'], isTrue, reason: '$grep');
          expect(grep['text'], 'No results found.');
        },
      );

      test('Grep searches the workspace and reference titles', () async {
        final workspace = await toolManager.executeTool(
          name: 'Grep',
          input: {'pattern': '线索'},
        );
        expect(workspace['ok'], isTrue, reason: '$workspace');
        expect(workspace['text'], contains('$stickyPath/content:1:便签线索'));
        expect(workspace['text'], contains('$referencePath/title:1:章节线索'));
        expect(
          workspace['text'],
          contains('chapters/search_chapter/title:1:章节线索'),
        );

        final reference = await toolManager.executeTool(
          name: 'Grep',
          input: {'path': referencePath, 'pattern': '线索'},
        );
        expect(reference['ok'], isTrue, reason: '$reference');
        expect(reference['text'], '$referencePath/title:1:章节线索\n');
      });

      test('Glob enumerates only readable fields for each node type', () async {
        for (final root in [
          'canvas/mixed',
          'canvas/mixed/nodes',
          stickyPath,
          referencePath,
        ]) {
          final glob = await toolManager.executeTool(
            name: 'Glob',
            input: {'path': root, 'pattern': '**/{content,color,title}'},
          );
          expect(glob['ok'], isTrue, reason: '$glob');
          expect(
            glob['matches'],
            unorderedEquals([
              if (root != referencePath) ...[
                '$stickyPath/content',
                '$stickyPath/color',
                '$stickyPath/title',
              ],
              if (root != stickyPath) ...[
                '$referencePath/color',
                '$referencePath/title',
              ],
            ]),
            reason: '$glob',
          );
          for (final path in (glob['matches'] as List).cast<String>()) {
            final field = await read(path);
            expect(field['error'], isNull, reason: '$field');
          }
        }
      });

      test(
        'Replace previews and applies only the matching sticky content',
        () async {
          final input = {
            'path': 'canvas/mixed',
            'pattern': '便签线索',
            'replacement': '替换正文',
          };
          final preview = await toolManager.executeTool(
            name: 'Replace',
            input: {...input, 'dry_run': true},
          );
          expect(preview['ok'], isTrue, reason: '$preview');
          expect(preview['matched_fields'], 1, reason: '$preview');
          expect((await read('$stickyPath/content'))['value'], '便签线索');

          final applied = await toolManager.executeTool(
            name: 'Replace',
            input: {...input, 'dry_run': false},
          );
          expect(applied['ok'], isTrue, reason: '$applied');
          expect(applied['applied_fields'], 1, reason: '$applied');
          expect(applied['failed'], isNull, reason: '$applied');
          expect((await read('$stickyPath/content'))['value'], '替换正文');
          expect((await read('$referencePath/title'))['value'], '章节线索');
        },
      );

      test(
        'explicit nonexistent reference fields still report errors',
        () async {
          for (final field in ['content']) {
            final path = '$referencePath/$field';
            for (final tool in ['Read', 'Grep', 'Glob']) {
              final result = await toolManager.executeTool(
                name: tool,
                input: {
                  'path': path,
                  if (tool == 'Grep') 'pattern': '线索',
                  if (tool == 'Glob') 'pattern': '**',
                },
              );
              expect(
                result['error_code'],
                'invalid_argument',
                reason: '$result',
              );
              expect(result['path'], path);
            }
          }
        },
      );
    });

    test('Edit preview enforces the same sticky target requirement', () async {
      await createCanvas('c');
      await insertCharacter('preview_character', '主角');
      final reference = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'preview_character',
      });
      final rejected = await toolManager.executeTool(
        name: 'Edit',
        input: {
          'path': '${selfPath(reference)}/content',
          'old_text': '',
          'new_text': '非法正文',
        },
      );
      expect(rejected['error_code'], 'invalid_argument');
      expect(preview, isNot(contains('diffOldText')));
      expect(preview, isNot(contains('diffNewText')));
      final rejectedWrite = await toolManager.executeTool(
        name: 'Write',
        input: {'path': '${selfPath(reference)}/content', 'value': '非法正文'},
      );
      expect(rejectedWrite['error_code'], 'invalid_argument');
      expect(preview, isNot(contains('diffOldText')));
      expect(preview, isNot(contains('diffNewText')));
      final sticky = await addNode('c', {
        'type': 'sticky',
        'content': '前文旧内容后文',
      });
      final edited = await toolManager.executeTool(
        name: 'Edit',
        input: {
          'path': '${selfPath(sticky)}/content',
          'old_text': '旧内容',
          'new_text': '新内容',
        },
      );
      expect(edited['edited'], true);
      expect(edited['match_count'], 1);
      expect(edited.containsKey('all'), false);
      expect(edited.containsKey('updated'), false);
      expect(edited.containsKey('replacements'), false);
      expect(preview?['diffOldText'], '前文旧内容后文');
      expect(preview?['diffNewText'], '前文新内容后文');
    });

    test('边不支持改写', () async {
      await createCanvas('c');
      await insertCharacter('char_1', '主角');
      await insertCharacter('char_2', '反派');
      final n1 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_1',
      });
      final n2 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_2',
      });
      final edge = await addEdge('c', {
        'source_node_id': n1['id'],
        'target_node_id': n2['id'],
        'type': 'relationship',
      });

      final result = await write(selfPath(edge), fields: {'label': '新标签'});

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'permission_denied');
    });
  });

  // ---- Write 画布 ----

  group('Write 画布', () {
    test('改名后旧路径失效，返回新路径与提示', () async {
      await createCanvas('旧名');

      final result = await write('canvas/旧名', fields: {'name': '新名'});

      expect(result['ok'], isTrue);
      expect(selfPath(result), 'canvas/新名');
      expect(result['hint'], contains('canvas/旧名'));
      expect(
        await contentService.canvasService.getCanvasByName('新名'),
        isNotNull,
      );
    });

    test('改名撞上已有画布返回 duplicate_name', () async {
      await createCanvas('甲');
      await createCanvas('乙');

      final result = await write('canvas/乙', fields: {'name': '甲'});

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'already_exists');
    });

    test('写 description', () async {
      await createCanvas('c');

      final result = await write('canvas/c/description', value: '这张图讲主线');

      expect(result['ok'], isTrue);
      final canvas = await contentService.canvasService.getCanvasByName('c');
      expect(canvas!.description, '这张图讲主线');
    });
  });

  // ---- Edit 便签正文 ----

  group('Edit 便签正文', () {
    test('精确替换便签正文', () async {
      await createCanvas('c');
      final node = await addNode('c', {
        'type': 'sticky',
        'content': '主角在雾港上岸',
        'col': 0,
        'row': 0,
      });

      final result = await toolManager.executeTool(
        name: 'Edit',
        input: {
          'path': '${selfPath(node)}/content',
          'old_text': '雾港',
          'new_text': '盐港',
        },
      );

      expect(result['ok'], isTrue);
      final stored = await db.canvasDao.getNodeById(node['id']);
      expect(stored!.content, '主角在盐港上岸');
    });

    test('引用节点没有正文，Edit 报错', () async {
      await createCanvas('c');
      await insertCharacter('char_1', '主角');
      final node = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_1',
      });

      final result = await toolManager.executeTool(
        name: 'Edit',
        input: {
          'path': '${selfPath(node)}/content',
          'old_text': 'x',
          'new_text': 'y',
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
    });
  });

  // ---- 不静默兜底成功 ----

  group('error transparency', () {
    test('tool failure returns ok:false, not silently ok:true', () async {
      await createCanvas('c');

      final result = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'nonexistent',
        'x': 0,
        'y': 0,
      });

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(result['error'], isA<String>());
      expect(result['path'], isA<String>());
    });
  });

  // ---- canvas 边不进入 EntityRelations ----

  group('boundary with entity_graph', () {
    test('canvas edge does not appear in EntityRelations', () async {
      await createCanvas('c');
      await insertCharacter('char_1', '主角');
      await insertCharacter('char_2', '反派');

      final n1 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_1',
        'x': 0,
        'y': 0,
      });
      final n2 = await addNode('c', {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': 'char_2',
        'x': 100,
        'y': 0,
      });
      await addEdge('c', {
        'source_node_id': n1['id'],
        'target_node_id': n2['id'],
        'type': 'relationship',
        'label': '宿敌',
      });

      final relations = await (db.select(db.entityRelations)).get();
      expect(relations, isEmpty);
    });
  });

  // ---- 一条龙 ----

  group('end-to-end flow', () {
    test('建画布 → 放节点 → 连边 → 收尾重排，全程只用通用工具', () async {
      final created = await create('canvas', {'name': '伏笔脉络'});
      expect(created['ok'], isTrue);
      expect(selfPath(created), 'canvas/伏笔脉络');

      await insertForeshadowing('fs_1', '伏笔一');
      await insertChapter('ch_1', '第一章');

      final fsNode = await addNode('伏笔脉络', {
        'type': 'reference',
        'ref_type': 'foreshadowing',
        'ref_id': 'fs_1',
        'col': 0,
        'row': 1,
      });
      expect(fsNode['ok'], isTrue);

      final chNode = await addNode('伏笔脉络', {
        'type': 'reference',
        'ref_type': 'chapter',
        'ref_id': 'ch_1',
        'col': 0,
        'row': 0,
      });
      expect(chNode['ok'], isTrue);

      final edgeResult = await addEdge('伏笔脉络', {
        'source_node_id': fsNode['id'],
        'target_node_id': chNode['id'],
        'type': 'foreshadow_payoff',
      });
      expect(edgeResult['ok'], isTrue);

      final nodes = await read('canvas/伏笔脉络/nodes');
      expect((nodes['entries'] as List).length, 2);
      final edges = await read('canvas/伏笔脉络/edges');
      expect((edges['entries'] as List).length, 1);

      final layout = await autoLayout('伏笔脉络');
      expect(layout['ok'], isTrue);
      expect(layout['updated'], isA<bool>());
    });
  });
}

class _LayoutContentService extends NovelContentService {
  _LayoutContentService(super.database, this.subject);
  final CanvasService subject;
  @override
  CanvasService get canvasService => subject;
}
