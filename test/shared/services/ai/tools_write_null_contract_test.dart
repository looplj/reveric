// 职责: 验证模型 null 输入归一化、真实可空值清除及两种 Write 路径的一致性。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_support.dart
//   lib/shared/services/ai/tools_schema.dart
//   lib/shared/services/ai/tools_write.dart
//   lib/shared/services/ai/tools_screenplay.dart
import 'package:reveric/shared/app_config.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  late NovelContentDatabase db;
  late AppDatabase app;
  late NovelContentService content;
  late WorkingOverlayService overlay;
  late AiToolManager tools;
  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    app = AppDatabase.forTest(NativeDatabase.memory());
    content = NovelContentService(db);
    overlay = WorkingOverlayService(
      db,
      content,
      novelActionsService: NovelActionsService(app),
    );
    tools = AiToolManager(
      content,
      workingOverlayService: overlay,
      sessionId: 'null-contract',
    )..registerAllTools();
  });
  tearDown(() async {
    tools.dispose();
    await db.close();
    await app.close();
  });
  Future<Map<String, dynamic>> call(String name, Map<String, dynamic> input) =>
      tools.executeTool(name: name, input: input);
  Future<Map<String, dynamic>> contract(String collection) =>
      call('Read', {'path': '/_schema/$collection'});
  Map fieldInput(Map node, String field) =>
      (node['operation_contracts'] as List).cast<Map>().singleWhere(
            (op) =>
                op['tool'] == 'Write' &&
                op['target'] == 'field' &&
                op['field'] == field,
          )['input']['value']
          as Map;
  Map resourceInput(Map node) =>
      (node['operation_contracts'] as List).cast<Map>().singleWhere(
            (op) => op['tool'] == 'Write' && op['target'] == 'resource',
          )['input']['properties']
          as Map;

  for (final resourceWrite in [false, true]) {
    Future<Map<String, dynamic>> write(
      String path,
      String field,
      Object? value,
    ) => call(
      'Write',
      resourceWrite
          ? {
              'path': path,
              'fields': {field: value},
            }
          : {'path': '$path/$field', 'value': value},
    );

    test(
      'null clears chapter text and arrays; resource=$resourceWrite',
      () async {
        final created = await call('Create', {
          'path': 'chapters',
          'fields': {
            'title': '章节',
            'content': '原文',
            'outline': '规划',
            'brief': '摘要',
            'emotion': ['紧张'],
            'events': [
              {'title': '转折'},
            ],
          },
        });
        final path = created['path'] as String;
        final node = await contract('chapters');
        for (final field in [
          'content',
          'outline',
          'brief',
          'emotion',
          'events',
        ]) {
          expect(node['fields'][field]['nullable'] == true, isFalse);
          expect(
            fieldInput(node, field),
            Map.of(resourceInput(node)[field] as Map)..remove('description'),
          );
          final cleared = await write(path, field, null);
          expect(cleared['error'], isNull, reason: '$cleared');
          expect(
            (await call('Read', {'path': '$path/$field'}))['value'],
            isEmpty,
          );
        }
        expect((await call('Read', {'path': '$path/title'}))['value'], '章节');
        final missing = await call('Write', {'path': '$path/content'});
        expect(missing['error'], isNotNull);
      },
    );

    test(
      'tension and optional chapter links clear; resource=$resourceWrite',
      () async {
        final volume = await call('Create', {
          'path': 'volumes',
          'fields': {'title': '卷'},
        });
        final created = await call('Create', {
          'path': 'chapters',
          'fields': {'title': '章节', 'tension': 7, 'volume_id': volume['id']},
        });
        final path = created['path'] as String;
        final node = await contract('chapters');
        for (final field in ['tension', 'volume_id']) {
          expect(node['fields'][field]['nullable'], isTrue);
          expect(
            fieldInput(node, field),
            Map.of(resourceInput(node)[field] as Map)..remove('description'),
          );
          final result = await write(path, field, null);
          expect(result['error'], isNull, reason: '$result');
          expect(
            (await call('Read', {'path': '$path/$field'}))['value'],
            isNull,
          );
        }
        final stored = await content.getChapterById(created['id'] as String);
        expect(stored!.tension, isNull);
        expect(stored.parentId, isNull);
        final reset = await write(path, 'volume_id', volume['id']);
        expect(reset['error'], isNull);
        final emptyString = await write(path, 'volume_id', '');
        expect(emptyString['error'], isNull);
        expect(
          (await content.getChapterById(created['id'] as String))!.parentId,
          isNull,
        );
      },
    );

    test(
      'ordinary entity fields clear consistently; resource=$resourceWrite',
      () async {
        for (final collection in [
          'skills',
          'items',
          'factions',
          'creatures',
          'lore',
          'materials',
        ]) {
          final created = await call('Create', {
            'path': collection,
            'fields': {'title': collection, 'content': '原文', 'category': '分类'},
          });
          final path = created['path'] as String;
          final node = await contract(collection);
          for (final field in ['content', 'category']) {
            expect(
              fieldInput(node, field),
              Map.of(resourceInput(node)[field] as Map)..remove('description'),
            );
            expect(node['fields'][field]['nullable'] == true, isFalse);
            final result = await write(path, field, null);
            expect(result['error'], isNull, reason: '$result');
            expect((await call('Read', {'path': '$path/$field'}))['value'], '');
          }
        }
        final chapter = await call('Create', {
          'path': 'chapters',
          'fields': {'title': '首章'},
        });
        final character = await call('Create', {
          'path': 'characters',
          'fields': {
            'name': '角色',
            'biography': '小传',
            'aliases': ['称呼'],
            'first_appear_chapter_id': chapter['id'],
          },
        });
        final path = character['path'] as String;
        for (final field in [
          'biography',
          'aliases',
          'first_appear_chapter_id',
          'avatar_asset_id',
        ]) {
          final result = await write(path, field, null);
          expect(result['error'], isNull, reason: '$result');
          final value = (await call('Read', {'path': '$path/$field'}))['value'];
          expect(
            value,
            field == 'biography' || field == 'aliases' ? isEmpty : isNull,
          );
        }
      },
    );

    test(
      'nullable foreshadowing references clear; resource=$resourceWrite',
      () async {
        final chapter = await call('Create', {
          'path': 'chapters',
          'fields': {'title': '章节'},
        });
        final created = await call('Create', {
          'path': 'foreshadowing',
          'fields': {
            'title': '伏笔',
            'setup': '铺垫',
            'payoff': '回收',
            'setup_chapter_id': chapter['id'],
            'payoff_chapter_id': chapter['id'],
          },
        });
        final path = created['path'] as String;
        final node = await contract('foreshadowing');
        for (final field in [
          'setup',
          'payoff',
          'setup_chapter_id',
          'payoff_chapter_id',
          'setup_scene_id',
          'payoff_scene_id',
        ]) {
          expect(
            fieldInput(node, field)['nullable'] == true,
            field.endsWith('_id'),
          );
          expect(
            fieldInput(node, field),
            Map.of(resourceInput(node)[field] as Map)..remove('description'),
          );
          final result = await write(path, field, null);
          expect(result['error'], isNull, reason: '$result');
          expect(
            (await call('Read', {'path': '$path/$field'}))['value'],
            field.endsWith('_id') ? isNull : equals(''),
          );
        }
      },
    );

    test('declared defaults handle null; resource=$resourceWrite', () async {
      final character = await call('Create', {
        'path': 'characters',
        'fields': {'name': '角色', 'role': null, 'gender': null},
      });
      expect(character['error'], isNull, reason: '$character');
      for (final field in ['role', 'gender']) {
        final path = character['path'] as String;
        final result = await write(path, field, null);
        expect(result['error'], isNull, reason: '$result');
        expect(
          (await call('Read', {'path': '$path/$field'}))['value'],
          field == 'role' ? 'supporting' : 'unknown',
        );
      }
      if (!ideationCanvasEnabled) {
        expect((await call('Read', {'path': '/canvas'}))['error'], isNotNull);
        return;
      }
      await call('Create', {
        'path': 'canvas',
        'fields': {'name': 'c'},
      });
      final node = await call('Create', {
        'path': 'canvas/c/nodes',
        'fields': {
          'type': 'sticky',
          'title': '标题',
          'content': '正文',
          'color': null,
          'width': null,
          'height': null,
        },
      });
      expect(node['error'], isNull, reason: '$node');
      final path = node['path'] as String;
      for (final field in ['color', 'title', 'content']) {
        final result = await write(path, field, null);
        expect(result['error'], isNull, reason: '$result');
        expect(
          (await call('Read', {'path': '$path/$field'}))['value'],
          field == 'color' ? 'sand' : '',
        );
      }
      final before = await call('Read', {'path': path});
      final invalid = await write(path, 'x', null);
      expect(invalid['error'], isNotNull);
      expect(await call('Read', {'path': path}), before);
    });
  }

  test(
    'null creation normalizes empties and still checks required values',
    () async {
      final rejected = await call('Create', {
        'path': 'chapters',
        'fields': {'title': null},
      });
      expect(rejected['error_code'], 'invalid_argument');
      final chapter = await call('Create', {
        'path': 'chapters',
        'fields': {
          'title': '章节',
          'tension': null,
          'content': null,
          'events': null,
          'emotion': null,
        },
      });
      expect(chapter['error'], isNull, reason: '$chapter');
      final read = await call('Read', {'path': chapter['path']});
      expect(read['content'], '');
      expect(read['tension'], isNull);
      expect(read['emotion'], isEmpty);
      expect(read['events'], isEmpty);
      final badEvent = await call('Write', {
        'path': '${chapter['path']}/emotion',
        'value': [null],
      });
      expect(badEvent['error'], isNotNull);
      final badTension = await call('Write', {
        'path': '${chapter['path']}/tension',
        'value': 0,
      });
      expect(badTension['error'], isNotNull);
      final state = await call('Write', {
        'path': 'story_state/content',
        'value': null,
      });
      expect(state['error'], isNotNull);
    },
  );
  test(
    'location null clearing preserves required parent constraints',
    () async {
      final worldId = await content.locationsService.createLocation(
        name: '世界',
        type: 'world',
        description: '原文',
      );
      final childId = await content.locationsService.createLocation(
        name: '子地点',
        type: 'generic',
        parentId: worldId,
      );
      final world = {'id': worldId, 'path': 'locations/$worldId'};
      final child = {'id': childId, 'path': 'locations/$childId'};
      final rejected = await call('Write', {
        'path': child['path'],
        'fields': {'description': null, 'parent_id': null},
      });
      expect(rejected['error_code'], 'invalid_argument');
      expect(
        (await call('Read', {'path': "${child['path']}/parent_id"}))['value'],
        world['id'],
      );
      final cleared = await call('Write', {
        'path': world['path'],
        'fields': {'description': null, 'parent_id': null},
      });
      expect(cleared['error'], isNull, reason: '$cleared');
      expect(
        (await call('Read', {'path': "${world['path']}/description"}))['value'],
        '',
      );
      expect(
        (await call('Read', {'path': "${world['path']}/parent_id"}))['value'],
        isNull,
      );
    },
  );

  test('reference requirements count provided values, not just keys', () async {
    if (!ideationCanvasEnabled) {
      expect((await call('Read', {'path': '/canvas'}))['error'], isNotNull);
      return;
    }
    await call('Create', {
      'path': 'canvas',
      'fields': {'name': 'c'},
    });
    for (final refId in [null, '', '   ']) {
      final rejected = await call('Create', {
        'path': 'canvas/c/nodes',
        'fields': {
          'type': 'reference',
          'ref_type': 'character',
          'ref_id': refId,
        },
      });
      expect(rejected['error_code'], 'invalid_argument', reason: '$rejected');
    }
    expect(
      (await call('Read', {'path': 'canvas/c/nodes'}))['entries'],
      isEmpty,
    );
    final character = await call('Create', {
      'path': 'characters',
      'fields': {'name': '角色'},
    });
    final created = await call('Create', {
      'path': 'canvas/c/nodes',
      'fields': {
        'type': 'reference',
        'ref_type': 'character',
        'ref_id': character['id'],
      },
    });
    expect(created['error'], isNull, reason: '$created');
  });

  test(
    'screenplay nullable values and resource-only references keep their contracts',
    () async {
      final initial = await ScreenplayService(db).createInitialStructure();
      tools.dispose();
      tools = AiToolManager(
        content,
        workingOverlayService: overlay,
        contentKind: 'screenplay',
        sessionId: 'null-contract',
      )..registerAllTools();
      final scene = await call('Create', {
        'path': 'scenes',
        'fields': {
          'episode_id': initial.episodeId,
          'emotion': ['紧张'],
          'events': [
            {'title': '相逢', 'summary': '角色相逢'},
          ],
        },
      });
      final targets = [
        ('seasons', 'seasons/${initial.seasonId}', 'planned_episode_count', 8),
        ('scenes', scene['path'] as String, 'emotion', <String>['紧张']),
        (
          'scenes',
          scene['path'] as String,
          'events',
          <Map<String, dynamic>>[
            {'title': '相逢', 'summary': '角色相逢'},
          ],
        ),
      ];
      for (final (collection, path, field, value) in targets) {
        final node = await contract(collection);
        expect(fieldInput(node, field)['nullable'] == true, value is int);
        final set = await call('Write', {
          'path': '$path/$field',
          'value': value,
        });
        expect(set['error'], isNull, reason: '$set');
        final cleared = await call('Write', {
          'path': '$path/$field',
          'value': null,
        });
        expect(cleared['error'], isNull, reason: '$cleared');
      }
      expect(
        (await db.screenplayDao.getSeason(
          initial.seasonId,
        ))!.plannedEpisodeCount,
        isNull,
      );
      final stored = (await db.screenplayDao.getScene(scene['id'] as String))!;
      expect(stored.emotion, isEmpty);
      expect(stored.events, isEmpty);
      final node = await contract('scenes');
      for (final field in ['beat_id', 'location_id', 'interior_exterior']) {
        expect(resourceInput(node)[field]['nullable'], isTrue);
        final ops = (node['operation_contracts'] as List).cast<Map>();
        expect(
          ops.where(
            (op) =>
                op['tool'] == 'Write' &&
                op['target'] == 'field' &&
                op['field'] == field,
          ),
          isEmpty,
        );
      }
      final cleared = await call('Write', {
        'path': scene['path'],
        'fields': {
          'beat_id': null,
          'location_id': null,
          'interior_exterior': null,
        },
      });
      expect(cleared['error'], isNull, reason: '$cleared');
    },
  );
}
