// 职责: 验证 AI 剧本路径的读写、全作品搜索、内容类型门禁与跨作品隔离。
// 关联文件:
//   lib/shared/services/ai/tools_screenplay.dart
//   lib/shared/services/ai/tools_cross_work.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/services/screenplay_service.dart
//   lib/shared/database/novel_content_daos/screenplay_dao.dart

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/database/novel_content_daos/screenplay_dao.dart';
import 'package:reveric/shared/models/screenplay.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/screenplay_element.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  late _ScreenplayReadProbeDatabase database;
  late AppDatabase appDatabase;
  late NovelContentService contentService;
  late WorkingOverlayService overlay;

  setUp(() {
    database = _ScreenplayReadProbeDatabase();
    appDatabase = AppDatabase.forTest(NativeDatabase.memory());
    contentService = NovelContentService(database);
    overlay = WorkingOverlayService(
      database,
      contentService,
      novelActionsService: NovelActionsService(appDatabase),
    );
  });

  tearDown(() async {
    await database.close();
    await appDatabase.close();
  });

  AiToolManager manager({
    String kind = contentKindScreenplay,
    String? seasonId,
    String? episodeId,
    String? sessionId = 'session_1',
    CrossWorkAccess? crossWorkAccess,
  }) {
    return AiToolManager(
      contentService,
      workingOverlayService: overlay,
      contentKind: kind,
      currentSeasonId: seasonId,
      currentEpisodeId: episodeId,
      sessionId: sessionId,
      workId: 'current',
      crossWorkAccess: crossWorkAccess,
    )..registerAllTools();
  }

  test('cast removal blocked by dialogue returns JSON-safe details', () async {
    final service = ScreenplayService(database);
    final initial = await service.createInitialStructure();
    final root = (await database.screenplayDao.getRoot())!;
    final characterId = await contentService.createCharacterProfile(
      defaultName: '林岚',
    );
    final sceneId = await service.createScene(
      screenplayId: root.id,
      episodeId: initial.episodeId,
    );
    await service.writeElements(
      sceneId: sceneId,
      elements: [
        ScreenplayElement(
          type: ScreenplayElementType.character,
          characterId: characterId,
        ),
        const ScreenplayElement(
          type: ScreenplayElementType.dialogue,
          text: '我还在这里。',
        ),
      ],
    );
    final tools = manager();
    addTearDown(tools.dispose);
    final result = await tools.executeTool(
      name: 'Write',
      input: {
        'path': 'scenes/$sceneId',
        'fields': {'cast': <String>[]},
      },
    );
    expect(result['ok'], isFalse);
    expect(result['error_code'], 'failed_precondition');
    final decoded = jsonDecode(jsonEncode(result)) as Map<String, dynamic>;
    expect(decoded['details'], [characterId]);
    expect(
      (await database.screenplayDao.getSceneCharacters(sceneId))
          .map((row) => row.characterId),
      [characterId],
    );
  });

  test(
    'retired beats are inaccessible while scene writes preserve legacy associations',
    () async {
      final service = ScreenplayService(database);
      final initial = await service.createInitialStructure();
      final root = (await database.screenplayDao.getRoot())!;
      final beatId = await service.createBeat(
        screenplayId: root.id,
        episodeId: initial.episodeId,
        actNumber: 1,
        title: 'Legacy',
      );
      final sceneId = await service.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
        beatId: beatId,
      );
      final tools = manager();
      addTearDown(tools.dispose);
      for (final name in ['Read', 'Create', 'Write', 'Edit', 'Remove']) {
        final result = await tools.executeTool(
          name: name,
          input: {
            'path': 'beats/$beatId',
            'fields': {'title': 'Changed'},
            'old_text': 'Legacy',
            'new_text': 'Changed',
          },
        );
        expect(result['error'], isNotNull, reason: '$result');
      }
      final schema = await tools.executeTool(
        name: 'Read',
        input: {'path': '/_schema/beats'},
      );
      expect(schema['error'], isNotNull);
      final changed = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'scenes/$sceneId',
          'fields': {'title': 'New title', 'beat_id': null},
        },
      );
      expect(changed['ok'], isTrue, reason: '$changed');
      expect(changed['ignored_fields'], contains('beat_id'));
      expect((await database.screenplayDao.getScene(sceneId))!.beatId, beatId);
      expect((await database.screenplayDao.getBeat(beatId))!.title, 'Legacy');
      final scene = await tools.executeTool(
        name: 'Read',
        input: {'path': 'scenes/$sceneId'},
      );
      expect(scene, isNot(contains('beat_id')));
    },
  );

  Future<
    ({
      List<String> seasons,
      List<String> episodes,
      List<String> scenes,
      List<String> beats,
      Map<String, String> texts,
      List<String> characters,
      String characterId,
    })
  >
  searchFixture() async {
    final service = ScreenplayService(database);
    final initial = await service.createInitialStructure();
    final root = (await database.screenplayDao.getRoot())!;
    final second = await service.createSeason(
      screenplayId: root.id,
      title: 'text',
    );
    await service.updateSeason(seasonId: initial.seasonId, title: 'synopsis');
    final third = await service.createEpisode(
      seasonId: second.seasonId,
      title: 'text',
    );
    final seasons = [initial.seasonId, second.seasonId];
    final episodes = [initial.episodeId, second.episodeId, third];
    final character = await contentService.createCharacterProfile(
      defaultName: '角色专属词',
    );
    final texts = <String, String>{
      'seasons/${seasons[0]}/title': 'synopsis',
      'seasons/${seasons[1]}/title': 'text',
    };
    final scenes = <String>[];
    final beats = <String>[];
    final characters = <String>[];
    for (var i = 0; i < episodes.length; i++) {
      final episode = episodes[i];
      await service.updateEpisode(episodeId: episode, title: 'text');
      await service.updateEpisodeOutline(
        episodeId: episode,
        outline: '/线索大纲$i\n/下一行',
      );
      texts['episodes/$episode/title'] = 'text';
      texts['episodes/$episode/outline'] = '/线索大纲$i\n/下一行';
      final beat = await service.createBeat(
        screenplayId: root.id,
        episodeId: episode,
        actNumber: 1,
        title: 'synopsis',
        description: '线索说明$i',
      );
      beats.add(beat);
      final scene = await service.createScene(
        screenplayId: root.id,
        episodeId: episode,
        beatId: beat,
        synopsis: '线索梗概$i',
        timeLabel: '时间专属词',
        stage: i == 1 ? 'final' : 'draft',
      );
      scenes.add(scene);
      texts['scenes/$scene/title'] = '';
      texts['scenes/$scene/synopsis'] = '线索梗概$i';
      await service.writeElements(
        sceneId: scene,
        elements: [
          ScreenplayElement(
            id: '',
            type: ScreenplayElementType.action,
            text: '/线索动作$i\n/线索幕落$i',
          ),
          ScreenplayElement(
            id: '',
            type: ScreenplayElementType.character,
            characterId: character,
            extension: 'EXTONLY',
          ),
          for (final type in [
            ScreenplayElementType.parenthetical,
            ScreenplayElementType.dialogue,
            ScreenplayElementType.transition,
            ScreenplayElementType.subtitle,
            ScreenplayElementType.note,
          ])
            ScreenplayElement(id: '', type: type, text: '线索${type.name}$i'),
        ],
      );
      for (final row in await database.screenplayDao.getElementRows(scene)) {
        final path = 'scenes/$scene/elements/${row.id}';
        if (row.type == 'character') {
          characters.add(path);
        } else {
          texts['$path/text'] = row.textContent;
        }
      }
    }
    return (
      seasons: seasons,
      episodes: episodes,
      scenes: scenes,
      beats: beats,
      texts: texts,
      characters: characters,
      characterId: character,
    );
  }

  test(
    'screenplay Write distinguishes missing targets from invalid references',
    () async {
      final fixture = await searchFixture();
      final tools = manager();
      for (final path in [
        'seasons/missing',
        'episodes/missing',
        'scenes/missing',
        'scenes/${fixture.scenes.first}/elements/missing',
      ]) {
        final result = await tools.executeTool(
          name: 'Write',
          input: {
            'path': path,
            'fields': path.contains('/elements/')
                ? {'text': 'new text'}
                : {'title': 'new title'},
          },
        );
        expect(result['error_code'], 'not_found', reason: '$result');
      }
      final path = 'episodes/${fixture.episodes.first}';
      final before = await tools.executeTool(
        name: 'Read',
        input: {'path': path},
      );
      final invalid = await tools.executeTool(
        name: 'Write',
        input: {
          'path': path,
          'fields': {'season_id': 'missing', 'title': 'must not be saved'},
        },
      );
      expect(invalid['error_code'], 'invalid_argument', reason: '$invalid');
      expect(
        await tools.executeTool(name: 'Read', input: {'path': path}),
        before,
      );
      expect(await overlay.getWorkingChanges(), isEmpty);
    },
  );

  test(
    'screenplay Create rejects missing placement references as invalid_argument',
    () async {
      final fixture = await searchFixture();
      final tools = manager();
      for (final (path, fields) in [
        ('episodes', {'season_id': 'missing', 'title': 'new episode'}),
        (
          'scenes/${fixture.scenes.first}/elements',
          {
            'type': 'action',
            'text': 'new action',
            'after_element_id': 'missing',
          },
        ),
      ]) {
        final before = await tools.executeTool(
          name: 'Read',
          input: {'path': path},
        );
        final result = await tools.executeTool(
          name: 'Create',
          input: {'path': path, 'fields': fields},
        );
        expect(result['error_code'], 'invalid_argument', reason: '$result');
        expect(
          await tools.executeTool(name: 'Read', input: {'path': path}),
          before,
        );
      }
      expect(await overlay.getWorkingChanges(), isEmpty);
    },
  );

  for (final field in ['title', 'synopsis', 'text', 'outline']) {
    test(
      'screenplay Edit classifies replacement failures for $field',
      () async {
        final fixture = await searchFixture();
        final tools = manager();
        final path = switch (field) {
          'title' || 'synopsis' => 'scenes/${fixture.scenes.first}/$field',
          'text' => fixture.texts.keys.firstWhere(
            (key) => key.contains('/elements/'),
          ),
          _ => 'episodes/${fixture.episodes.first}/outline',
        };
        final written = await tools.executeTool(
          name: 'Write',
          input: {'path': path, 'value': 'repeat repeat'},
        );
        expect(written['ok'], isTrue, reason: '$written');
        final beforeChanges = (await overlay.getWorkingChanges())
            .map((e) => e.toJson())
            .toList();
        for (final (oldText, code) in [
          ('', 'invalid_argument'),
          ('repeat', 'invalid_argument'),
          ('absent', 'failed_precondition'),
        ]) {
          final result = await tools.executeTool(
            name: 'Edit',
            input: {'path': path, 'old_text': oldText, 'new_text': 'changed'},
          );
          expect(result['error_code'], code, reason: '$result');
          if (oldText == 'absent') {
            expect(result['recovery'], {
              'tool': 'Read',
              'input': {'path': path},
            });
          }
          expect(
            (await tools.executeTool(
              name: 'Read',
              input: {'path': path},
            ))['value'],
            'repeat repeat',
          );
          expect(
            (await overlay.getWorkingChanges()).map((e) => e.toJson()).toList(),
            beforeChanges,
          );
        }
        final changed = await tools.executeTool(
          name: 'Edit',
          input: {
            'path': path,
            'old_text': 'repeat',
            'new_text': 'changed',
            'all': true,
          },
        );
        expect(changed['edited'], isTrue, reason: '$changed');
        expect(changed['match_count'], 2);
        expect(
          (await tools.executeTool(
            name: 'Read',
            input: {'path': path},
          ))['value'],
          'changed changed',
        );
      },
    );
  }

  test(
    'screenplay Edit initializes empty fields consistently with other resources',
    () async {
      final initial = await ScreenplayService(
        database,
      ).createInitialStructure();
      final tools = manager();
      final path = 'episodes/${initial.episodeId}/outline';
      final noChange = await tools.executeTool(
        name: 'Edit',
        input: {'path': path, 'old_text': '', 'new_text': ''},
      );
      expect(noChange['ok'], isTrue, reason: '$noChange');
      expect(noChange['edited'], isFalse);
      expect(noChange['match_count'], 1);
      expect(
        (await tools.executeTool(name: 'Read', input: {'path': path}))['value'],
        '',
      );
      final result = await tools.executeTool(
        name: 'Edit',
        input: {'path': path, 'old_text': '', 'new_text': 'new outline'},
      );
      expect(result['ok'], isTrue, reason: '$result');
      expect(result['edited'], isTrue);
      expect(result['match_count'], 1);
      expect(
        (await tools.executeTool(name: 'Read', input: {'path': path}))['value'],
        'new outline',
      );
      final overwrite = await tools.executeTool(
        name: 'Edit',
        input: {'path': path, 'old_text': '', 'new_text': 'must not overwrite'},
      );
      expect(overwrite['error_code'], 'invalid_argument', reason: '$overwrite');
      expect(
        (await tools.executeTool(name: 'Read', input: {'path': path}))['value'],
        'new outline',
      );
    },
  );

  for (final (fields, message) in [
    ({'character_id': ''}, 'Character elements require character_id.'),
    ({'text': '错误正文'}, 'Character elements cannot contain text.'),
  ]) {
    test(
      'screenplay element shape rejects $fields as invalid_argument',
      () async {
        final fixture = await searchFixture();
        final tools = manager();
        final path = fixture.characters.first;
        final before = await tools.executeTool(
          name: 'Read',
          input: {'path': path},
        );

        final result = await tools.executeTool(
          name: 'Write',
          input: {'path': path, 'fields': fields},
        );

        expect(result['ok'], isFalse);
        expect(result['error_code'], 'invalid_argument', reason: '$result');
        expect(result['error'], message);
        expect(result['hint'], contains('Read /_schema/scenes'));
        expect(
          await tools.executeTool(name: 'Read', input: {'path': path}),
          before,
        );
        expect(await overlay.getWorkingChanges(), isEmpty);
      },
    );
  }

  test(
    'entity arrays retain duplicates without IDs, reject duplicate IDs and report all invalid leaves',
    () async {
      final initial = await ScreenplayService(
        database,
      ).createInitialStructure();
      final tools = manager(episodeId: initial.episodeId);
      final scene = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'scenes',
          'fields': {'episode_id': initial.episodeId},
        },
      );
      expect(scene['ok'], true, reason: '$scene');
      final path = '${scene['path']}/elements';
      final written = await tools.executeTool(
        name: 'Write',
        input: {
          'path': path,
          'value':
              "[{'type':'ACTION','text':123}, {'type':'action','text':' 123 '}]",
        },
      );
      expect(written['ok'], true, reason: '$written');
      final entries =
          (await tools.executeTool(
                name: 'Read',
                input: {'path': path},
              ))['entries']
              as List;
      expect(entries, hasLength(2));
      expect(entries.map((entry) => entry['id']).toSet(), hasLength(2));
      expect(entries.map((entry) => entry['text']), ['123', '123']);
      final id = entries.first['id'];
      final before = (await database.select(database.workingChanges).get())
          .map((row) => row.toJson())
          .toList();
      for (final value in <Object>[
        [
          {'id': id, 'type': 'action', 'text': 'a'},
          {'id': id, 'type': 'action', 'text': 'b'},
        ],
        [
          {'id': 123, 'type': 'action', 'text': 'bad identity'},
        ],
        [
          {'type': null, 'text': []},
          {'text': 'missing type'},
        ],
      ]) {
        final rejected = await tools.executeTool(
          name: 'Write',
          input: {'path': path, 'value': value},
        );
        expect(rejected['error_code'], 'invalid_argument', reason: '$rejected');
        expect(rejected['validation_errors'], isNotEmpty);
        expect(
          (await database.select(database.workingChanges).get())
              .map((row) => row.toJson())
              .toList(),
          before,
        );
      }
      final duplicate = await tools.executeTool(
        name: 'Write',
        input: {
          'path': path,
          'value': [
            {'id': id, 'type': 'action'},
            {'id': id, 'type': 'action'},
          ],
        },
      );
      expect((duplicate['validation_errors'] as List).cast<Map>().single, {
        'code': 'duplicate_id',
        'field': 'elements[1].id',
      });
    },
  );

  test(
    'resource IDs use id while paths and references keep typed names',
    () async {
      await ScreenplayService(database).createInitialStructure();
      final tools = manager();
      addTearDown(tools.dispose);
      final season = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'seasons',
          'fields': {'title': '新季'},
        },
      );
      expect(season['ok'], isTrue, reason: '$season');
      expect(season, isNot(contains('season_id')));
      expect(season['episode_id'], isA<String>());
      final episode = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'episodes',
          'fields': {'season_id': season['id'], 'title': '新集'},
        },
      );
      expect(episode['editing_id'], isA<String>());
      expect(episode['editing_revision'], 0);
      final editing = (await database.editingDao.get(
        episode['editing_id'] as String,
      ))!;
      expect(editing.title, '新集');
      expect(editing.document.clips, isEmpty);
      final editingRef = await tools.executeTool(
        name: 'Read',
        input: {'path': '${episode['path']}/editing_id'},
      );
      expect(editingRef['value'], editing.id);
      final characterId = await contentService.createCharacterProfile(
        defaultName: '林岚',
      );
      final scene = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'scenes',
          'fields': {
            'episode_id': episode['id'],
            'cast': [characterId],
            'elements': [
              {'type': 'action', 'text': '推门而入。'},
            ],
          },
        },
      );
      for (final entry in {
        'seasons': season,
        'episodes': episode,
        'scenes': scene,
      }.entries) {
        final created = entry.value;
        expect(created['ok'], isTrue, reason: '$created');
        expect(created['created'], isTrue);
        expect(created['id'], isA<String>());
        expect(created['path'], '${entry.key}/${created['id']}');
        final read = await tools.executeTool(
          name: 'Read',
          input: {'path': created['path']},
        );
        expect(read['id'], created['id']);
      }
      final episodeRead = await tools.executeTool(
        name: 'Read',
        input: {'path': episode['path']},
      );
      expect(episodeRead['season_id'], season['id']);
      expect(episodeRead, isNot(contains('episode_id')));
      final sceneRead = await tools.executeTool(
        name: 'Read',
        input: {'path': scene['path']},
      );
      expect(sceneRead['episode_id'], episode['id']);
      expect(sceneRead, isNot(contains('beat_id')));
      expect(sceneRead, isNot(contains('scene_id')));

      final elementsPath = '${scene['path']}/elements';
      final listing = await tools.executeTool(
        name: 'Read',
        input: {'path': elementsPath},
      );
      final element = (listing['entries'] as List).single as Map;
      expect(element['id'], isA<String>());
      expect(element, isNot(contains('element_id')));
      expect(element['path'], '$elementsPath/${element['id']}');
      final write = await tools.executeTool(
        name: 'Write',
        input: {
          'path': elementsPath,
          'value': [
            {'id': element['id'], 'type': 'action', 'text': '轻轻推门而入。'},
          ],
        },
      );
      expect(write['ok'], isTrue, reason: '$write');
      final stored = await database.screenplayDao.getElementRows(
        scene['id'] as String,
      );
      expect(stored.single.id, element['id']);
      expect(stored.single.textContent, '轻轻推门而入。');
      final elementRead = await tools.executeTool(
        name: 'Read',
        input: {'path': element['path']},
      );
      expect(elementRead['id'], element['id']);
      expect(elementRead['text'], '轻轻推门而入。');
      final added = await tools.executeTool(
        name: 'Create',
        input: {
          'path': elementsPath,
          'fields': {
            'type': 'action',
            'text': '关门。',
            'after_element_id': element['id'],
          },
        },
      );
      expect(added['created'], isTrue, reason: '$added');
      final removed = await tools.executeTool(
        name: 'Remove',
        input: {'path': added['path']},
      );
      expect(removed['removed'], isTrue, reason: '$removed');
      expect(
        await database.screenplayDao.getElementRows(scene['id'] as String),
        hasLength(1),
      );
    },
  );

  test(
    'scene fields have typed paths, independent history and atomic validation',
    () async {
      final service = ScreenplayService(database);
      final initial = await service.createInitialStructure();
      final root = (await database.screenplayDao.getRoot())!;
      final id = await service.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
      );
      final tools = manager();
      final values = <String, Object?>{
        'title': '东门遇险',
        'emotion': ['紧张', '警觉'],
        'events': [
          {'title': '遇袭', 'summary': '门口有人拦路', 'state_change': '退路被截断'},
        ],
      };
      for (final entry in values.entries) {
        final result = await tools.executeTool(
          name: 'Write',
          input: {
            'path': 'scenes/$id/${entry.key}',
            'fields': {entry.key: entry.value},
          },
        );
        expect(result['ok'], true, reason: '$result');
        final read = await tools.executeTool(
          name: 'Read',
          input: {'path': 'scenes/$id/${entry.key}'},
        );
        expect(read['value'], entry.value, reason: '$read');
      }
      final invalid = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'scenes/$id',
          'fields': {
            'title': '不可保存',
            'events': [
              {'title': '缺摘要'},
            ],
          },
        },
      );
      expect(invalid['ok'], false);
      expect((await database.screenplayDao.getScene(id))!.title, '东门遇险');
      final list = await tools.executeTool(
        name: 'Read',
        input: {'path': 'scenes?episode_id=${initial.episodeId}'},
      );
      expect(
        ((list['entries'] as List).single as Map).containsKey('events'),
        false,
      );
      final changes = await overlay.getWorkingChanges();
      expect(changes.map((c) => c.field).toSet(), values.keys.toSet());
      await overlay.rejectWorkingChange(
        changes.firstWhere((c) => c.field == 'emotion').id,
      );
      final scene = (await database.screenplayDao.getScene(id))!;
      expect(scene.emotion, isNull);
      expect(scene.title, '东门遇险');
      expect(scene.events, values['events']);
      final clear = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'scenes/$id/title',
          'fields': {'title': ''},
        },
      );
      expect(clear['ok'], true);
      expect((await database.screenplayDao.getScene(id))!.title, '');
    },
  );

  test(
    'beats and scenes listings span the screenplay in season and episode order without a selection',
    () async {
      final fixture = await searchFixture();
      final tools = manager();
      for (final (collection, expected) in [('scenes', fixture.scenes)]) {
        final listing = await tools.executeTool(
          name: 'Read',
          input: {'path': collection},
        );
        expect(listing['error'], isNull, reason: '$collection: $listing');
        // 没有落到单集，不回显 episode_id。
        expect(listing.containsKey('episode_id'), isFalse);
        final entries = (listing['entries'] as List).cast<Map>();
        expect([for (final entry in entries) entry['id']], expected);
        // 集内位置不因跨集拼接而重编号。
        expect([
          for (final entry in entries) entry['episode_id'],
        ], fixture.episodes);
        expect(
          [
            for (final entry in entries)
              entry[collection == 'beats' ? 'beat_number' : 'scene_number'],
          ],
          [1, 1, 1],
        );
      }
      // 当前集不会把整剧读悄悄缩成一集；缩小作用域必须显式写进 query。
      final selected = manager(episodeId: fixture.episodes[1]);
      final unscoped = await selected.executeTool(
        name: 'Read',
        input: {'path': 'scenes'},
      );
      expect(unscoped.containsKey('episode_id'), isFalse);
      expect(unscoped['total'], fixture.scenes.length);
      expect([
        for (final entry in (unscoped['entries'] as List).cast<Map>())
          entry['id'],
      ], fixture.scenes);
      final scoped = await selected.executeTool(
        name: 'Read',
        input: {'path': 'scenes?episode_id=${fixture.episodes[1]}'},
      );
      expect(scoped['episode_id'], fixture.episodes[1]);
      expect(scoped['total'], 1);
      expect(
        [
          for (final entry in (scoped['entries'] as List).cast<Map>())
            entry['id'],
        ],
        [fixture.scenes[1]],
      );
    },
  );

  test(
    'Glob discovers readable IDs and raw text across all seasons independent of selection',
    () async {
      final fixture = await searchFixture();
      List<String>? baseline;
      for (final tools in [
        manager(),
        manager(
          seasonId: fixture.seasons.first,
          episodeId: fixture.episodes.first,
        ),
        manager(seasonId: 'missing', episodeId: 'missing'),
      ]) {
        final result = await tools.executeTool(
          name: 'Glob',
          input: {'pattern': '{seasons,episodes,beats,scenes}/**'},
        );
        expect(result['ok'], isTrue, reason: '$result');
        expect(result['truncated'], isFalse);
        final paths = (result['matches'] as List).cast<String>();
        expect(paths.toSet(), hasLength(paths.length));
        expect(paths, containsAll(fixture.texts.keys));
        baseline ??= paths;
        expect(paths, baseline);
        expect(
          paths.any(
            (path) =>
                path.endsWith('/time_label') ||
                path.endsWith('/name') ||
                path.endsWith('/extension'),
          ),
          isFalse,
        );
        for (final character in fixture.characters) {
          expect(paths, contains(character));
          expect(paths, contains('$character/character_id'));
          expect(paths, isNot(contains('$character/text')));
        }
        for (final path in paths) {
          if (path == 'episodes') {
            continue; // 多季时仍要显式 season_id，与 search 不同。
          }
          final read = await tools.executeTool(
            name: 'Read',
            input: {'path': path},
          );
          expect(read['error'], isNull, reason: '$path: $read');
          expect(read['path'], path);
          if (fixture.texts.containsKey(path)) {
            final field = path.split('/').last;
            expect(read['value'], fixture.texts[path], reason: path);
            expect(
              read.containsKey('synopsis') && field != 'synopsis',
              isFalse,
            );
          }
        }
      }
    },
  );

  test(
    'Grep covers original screenplay text in all output modes and excludes display metadata',
    () async {
      final fixture = await searchFixture();
      final tools = manager();
      final textPath = fixture.texts.keys.firstWhere(
        (path) => fixture.texts[path]!.contains('线索动作'),
      );
      for (final mode in ['content', 'count', 'files_with_matches']) {
        final result = await tools.executeTool(
          name: 'Grep',
          input: {'path': textPath, 'pattern': '线索', 'output_mode': mode},
        );
        expect(result['searched_files'], 1);
        expect(result['text'], switch (mode) {
          'count' => '$textPath:2\n',
          'files_with_matches' => '$textPath\n',
          _ => '$textPath:1:/线索动作0\n$textPath:2:/线索幕落0\n',
        });
      }
      final all = await tools.executeTool(
        name: 'Grep',
        input: {
          'path': '/',
          'glob': '{seasons,episodes,beats,scenes}/**',
          'pattern': '线索',
          'output_mode': 'files_with_matches',
        },
      );
      expect(
        all['searched_files'],
        fixture.texts.length + fixture.characters.length,
      );
      expect(
        (all['text'] as String).trim().split('\n'),
        unorderedEquals(
          fixture.texts.entries
              .where((entry) => entry.value.contains('线索'))
              .map((entry) => entry.key),
        ),
      );
      final omitted = await tools.executeTool(
        name: 'Grep',
        input: {
          'path': '/',
          'glob': '{seasons,episodes,beats,scenes}/**',
          'pattern': '时间专属词|角色专属词|EXTONLY',
        },
      );
      expect(omitted['text'], 'No results found.');
      for (final tool in ['Read', 'Glob', 'Grep', 'Replace']) {
        final explicit = await tools.executeTool(
          name: tool,
          input: {
            'path': '${fixture.characters.first}/text',
            'pattern': tool == 'Glob' ? '**' : '^',
            if (tool == 'Replace') 'replacement': '不能插入',
          },
        );
        expect(explicit['ok'], isFalse, reason: '$tool: $explicit');
        expect(explicit['error_code'], 'invalid_argument');
        expect(explicit['path'], '${fixture.characters.first}/text');
      }
    },
  );

  test(
    'character ID reads and searches locate references across seasons',
    () async {
      final fixture = await searchFixture();
      final service = ScreenplayService(database);
      final otherCharacter = await contentService.createCharacterProfile(
        defaultName: '另一角色',
      );
      final root = (await database.screenplayDao.getRoot())!;
      final otherScene = await service.createScene(
        screenplayId: root.id,
        episodeId: fixture.episodes.first,
      );
      await service.writeElements(
        sceneId: otherScene,
        elements: [
          ScreenplayElement(
            type: ScreenplayElementType.character,
            characterId: otherCharacter,
          ),
        ],
      );
      final otherElement = (await database.screenplayDao.getElementRows(
        otherScene,
      )).single;
      final referencePaths = [
        for (final path in fixture.characters) '$path/character_id',
      ];
      final expectedReferences = {
        for (final path in referencePaths) path: fixture.characterId,
        'scenes/$otherScene/elements/${otherElement.id}/character_id':
            otherCharacter,
      };
      final tools = manager(episodeId: fixture.episodes.first);
      addTearDown(tools.dispose);
      const glob = 'scenes/*/elements/*/character_id';
      final found = await tools.executeTool(
        name: 'Glob',
        input: {'pattern': glob},
      );
      expect(found['ok'], isTrue, reason: '$found');
      expect(found['matches'], unorderedEquals(expectedReferences.keys));
      for (final entry in expectedReferences.entries) {
        final read = await tools.executeTool(
          name: 'Read',
          input: {'path': entry.key},
        );
        expect(read['ok'], isTrue, reason: '$read');
        expect(read['path'], entry.key);
        expect(read['value'], entry.value);
        expect(read, isNot(contains('text')));
      }
      final matches = await tools.executeTool(
        name: 'Grep',
        input: {
          'path': 'scenes',
          'glob': glob,
          'pattern': '^${RegExp.escape(fixture.characterId)}\$',
          'output_mode': 'files_with_matches',
        },
      );
      expect(matches['ok'], isTrue, reason: '$matches');
      expect(matches['searched_files'], expectedReferences.length);
      expect(
        (matches['text'] as String).trim().split('\n'),
        unorderedEquals(referencePaths),
      );
      final direct = await tools.executeTool(
        name: 'Grep',
        input: {
          'path': referencePaths.first,
          'pattern': fixture.characterId,
          'literal': true,
        },
      );
      expect(direct['ok'], isTrue, reason: '$direct');
      expect(direct['searched_files'], 1);
      expect(
        direct['text'],
        '${referencePaths.first}:1:${fixture.characterId}\n',
      );
      final textPath = fixture.texts.keys.firstWhere(
        (path) => path.endsWith('/text'),
      );
      final invalidPath =
          '${textPath.substring(0, textPath.length - '/text'.length)}/character_id';
      for (final tool in ['Read', 'Glob', 'Grep']) {
        final invalid = await tools.executeTool(
          name: tool,
          input: {
            'path': invalidPath,
            if (tool != 'Read')
              'pattern': tool == 'Glob' ? '**' : fixture.characterId,
          },
        );
        expect(invalid['error_code'], 'invalid_argument', reason: '$invalid');
        expect(invalid['path'], invalidPath);
      }
    },
  );

  test('Edit and Replace cannot alter searchable character IDs', () async {
    final fixture = await searchFixture();
    final original = {
      for (final scene in fixture.scenes)
        scene: await database.screenplayDao.getElementRows(scene),
    };
    final tools = manager();
    addTearDown(tools.dispose);
    final path = '${fixture.characters.first}/character_id';
    final edit = await tools.executeTool(
      name: 'Edit',
      input: {
        'path': path,
        'old_text': fixture.characterId,
        'new_text': 'changed_id',
      },
    );
    expect(edit['ok'], isFalse, reason: '$edit');
    for (final scope in [
      {'path': path},
      {'path': 'scenes', 'glob': 'scenes/*/elements/*/character_id'},
    ]) {
      for (final dryRun in [true, false]) {
        final result = await tools.executeTool(
          name: 'Replace',
          input: {
            ...scope,
            'pattern': fixture.characterId,
            'replacement': 'changed_id',
            'literal': true,
            'dry_run': dryRun,
          },
        );
        expect(result['ok'], isTrue, reason: '$result');
        expect(result[dryRun ? 'matched_fields' : 'applied_fields'], 0);
        expect(result['skipped_fields'], {
          'not_editable': scope['path'] == path ? 1 : fixture.characters.length,
        });
      }
    }
    expect(await overlay.getWorkingChanges(), isEmpty);
    for (final scene in fixture.scenes) {
      expect(
        await database.screenplayDao.getElementRows(scene),
        original[scene],
      );
    }
  });

  test(
    'search listing queries constrain their own scope without leaking into paths',
    () async {
      final fixture = await searchFixture();
      final tools = manager(episodeId: fixture.episodes.first);
      for (final scope in <String, List<String>>{
        'episodes?season_id=${fixture.seasons[1]}': [
          fixture.episodes[1],
          fixture.episodes[2],
        ],
        'episodes/${fixture.episodes[1]}': [fixture.episodes[1]],
        'scenes?episode_id=${fixture.episodes[1]}': [fixture.scenes[1]],
        'scenes?stage=final&search=线索': [fixture.scenes[1]],
        'scenes/${fixture.scenes[0]}': [fixture.scenes[0]],
      }.entries) {
        final result = await tools.executeTool(
          name: 'Glob',
          input: {'path': scope.key, 'pattern': '**'},
        );
        expect(result['ok'], isTrue, reason: '${scope.key}: $result');
        final paths = (result['matches'] as List).cast<String>();
        final canonical = scope.key.split('?').first;
        expect(paths, contains(canonical));
        expect(
          paths.every(
            (path) =>
                !path.contains('?') &&
                (path == canonical || scope.value.any(path.contains)),
          ),
          isTrue,
          reason: '${scope.key}: $paths',
        );
        for (final id in scope.value) {
          expect(paths.any((path) => path.contains(id)), isTrue);
        }
      }
      final exact = fixture.texts.keys.last;
      final result = await tools.executeTool(
        name: 'Glob',
        input: {'path': exact, 'pattern': '**'},
      );
      expect(result['matches'], [exact]);
    },
  );

  test(
    'search validates invalid paths and queries even when glob cannot match',
    () async {
      final fixture = await searchFixture();
      final tools = manager();
      for (final scope in <String, String>{
        'scenes?episode_id=missing': 'not_found',
        'episodes?season_id=missing': 'not_found',
        'scenes/missing': 'not_found',
        'scenes/${fixture.scenes.first}/elements/missing/text': 'not_found',
        'scenes/${fixture.scenes.first}/time_label': 'invalid_argument',
        'seasons?search=none': 'invalid_argument',
        'episodes?unknown=value': 'invalid_argument',
        'scenes?stage=invalid&search=none': 'invalid_argument',
        'scenes/${fixture.scenes.first}?episode_id=missing': 'invalid_argument',
      }.entries) {
        for (final tool in ['Glob', 'Grep', 'Replace']) {
          final result = await tools.executeTool(
            name: tool,
            input: {
              'path': scope.key,
              'pattern': tool == 'Glob' ? '**/never' : '线索',
              if (tool != 'Glob') 'glob': '**/never',
              if (tool == 'Replace') 'replacement': '新词',
            },
          );
          expect(
            result['error_code'],
            scope.value,
            reason: '$tool ${scope.key}: $result',
          );
          expect(result['path'], scope.key.split('?').first);
        }
      }
      expect(await overlay.getWorkingChanges(), isEmpty);
      final emptyEpisode = await ScreenplayService(
        database,
      ).createEpisode(seasonId: fixture.seasons.first);
      final empty = await tools.executeTool(
        name: 'Grep',
        input: {'path': 'scenes?episode_id=$emptyEpisode', 'pattern': '线索'},
      );
      expect(empty['text'], 'No results found.');
      expect(empty['searched_files'], 0);
      expect(empty['truncated'], isFalse);
    },
  );

  test(
    'cross-work screenplay search uses target seasons and prefixes only paths once',
    () async {
      final fixture = await searchFixture();
      final sourceDb = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(sourceDb.close);
      final source = NovelContentService(sourceDb);
      for (final kind in [contentKindNovel, contentKindScreenplay]) {
        final tools = AiToolManager(
          source,
          workingOverlayService: overlay,
          contentKind: kind,
          currentSeasonId: 'source_season',
          currentEpisodeId: 'source_episode',
          crossWorkAccess: _ScreenplayCrossWorkAccess(contentService),
        )..registerAllTools();
        addTearDown(tools.dispose);
        final found = await tools.executeTool(
          name: 'Grep',
          input: {
            'glob': '/works/target/**/outline',
            'pattern': '^/',
            'output_mode': 'content',
          },
        );
        expect(found['searched_files'], 3, reason: '$found');
        expect(found['text'], contains(':1:/线索大纲'));
        expect(found['text'], contains(':2:/下一行'));
        expect(found['text'], isNot(contains('/works/target/works/target')));
        final glob = await tools.executeTool(
          name: 'Glob',
          input: {'path': '/works/target', 'pattern': '**/outline'},
        );
        expect(
          glob['matches'],
          unorderedEquals(
            fixture.episodes.map((id) => '/works/target/episodes/$id/outline'),
          ),
        );
        for (final dry in [true, false]) {
          final denied = await tools.executeTool(
            name: 'Replace',
            input: {
              'path': '/works/target',
              'pattern': '线索',
              'replacement': '越界',
              'dry_run': dry,
            },
          );
          expect(denied['error_code'], 'permission_denied');
        }
      }
    },
  );

  test(
    'screenplay story state supports content-only writes and edits',
    () async {
      final tools = manager();
      const body = '# 故事状态（截至第二季第三集第 5 场）\n林越持有钥匙';
      final written = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'story_state',
          'fields': {'content': body},
        },
      );
      expect(written['updated'], isTrue);
      final read = await tools.executeTool(
        name: 'Read',
        input: {'path': 'story_state'},
      );
      expect(read['content'], body);
      expect(read.containsKey('source_chapter_id'), isFalse);
      final edited = await tools.executeTool(
        name: 'Edit',
        input: {
          'path': 'story_state/content',
          'old_text': '钥匙',
          'new_text': '断刃',
        },
      );
      expect(edited['edited'], isTrue);
      expect(
        (await contentService.getCurrentStateSnapshot())?.content,
        body.replaceAll('钥匙', '断刃'),
      );
      expect(await contentService.getChapters(), isEmpty);
      expect(
        await database.select(database.novelStateSnapshots).get(),
        hasLength(2),
      );
    },
  );

  test(
    'content kind gate filters roots and rejects mismatched collections',
    () async {
      final novelManager = manager(kind: contentKindNovel);
      final mismatch = await novelManager.executeTool(
        name: 'Read',
        input: {'path': 'screenplay'},
      );
      expect(mismatch['error_code'], 'invalid_argument');

      await ScreenplayService(database).createInitialStructure();
      final screenplayManager = manager();
      final chapters = await screenplayManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters'},
      );
      expect(chapters['error_code'], 'invalid_argument');
    },
  );

  test('missing character references remain readable through name', () async {
    final service = ScreenplayService(database);
    final initial = await service.createInitialStructure();
    final root = (await database.screenplayDao.getRoot())!;
    final character = await contentService.createCharacterProfile(
      defaultName: '林岚',
    );
    final scene = await service.createScene(
      screenplayId: root.id,
      episodeId: initial.episodeId,
    );
    await service.writeElements(
      sceneId: scene,
      elements: [
        ScreenplayElement(
          type: ScreenplayElementType.character,
          characterId: character,
        ),
        const ScreenplayElement(
          type: ScreenplayElementType.dialogue,
          text: '你来了。',
        ),
      ],
    );
    final tools = manager();
    for (final missing in [false, true]) {
      if (missing) {
        // 模拟历史数据中的失效引用；正常业务删除会被引用检查拦截。
        await database.characterProfileDao.softDelete(character);
      }
      final cast = await tools.executeTool(
        name: 'Read',
        input: {'path': 'scenes/$scene/cast'},
      );
      final elements = await tools.executeTool(
        name: 'Read',
        input: {'path': 'scenes/$scene/elements'},
      );
      final cue = (elements['entries'] as List).cast<Map>().first;
      final detail = await tools.executeTool(
        name: 'Read',
        input: {'path': cue['path']},
      );
      for (final entry in [(cast['value'] as List).single, cue, detail]) {
        expect(entry['character_id'], character);
        expect(entry['name'], missing ? '（角色不存在）' : '林岚');
        expect(entry.containsKey('character_deleted'), isFalse);
      }
    }
    expect(
      pathSchemaFieldNotes(kind: contentKindScreenplay),
      isNot(contains('character_deleted')),
    );
    final schema = await tools.executeTool(
      name: 'Read',
      input: {'path': '/_schema/scenes'},
    );
    expect(schema.toString(), isNot(contains('character_deleted')));
  });

  test('scene Create prevalidates every input before any INSERT', () async {
    final initial = await ScreenplayService(database).createInitialStructure();
    final character = await contentService.createCharacterProfile(
      defaultName: '林岚',
    );
    final beforeScenes = await database.select(database.screenplayScenes).get();
    final beforeElements = await database
        .select(database.screenplaySceneElements)
        .get();
    // 任何 INSERT 都会失败，证明返回的业务错误来自预校验而非插入后的回滚。
    await database.customStatement(
      "CREATE TRIGGER reject_scene_insert BEFORE INSERT ON screenplay_scenes BEGIN SELECT RAISE(ABORT, 'unexpected scene insert'); END",
    );
    final cases = <(Map<String, dynamic>, String)>[
      (
        {
          'cast': ['林岚'],
        },
        'invalid_argument',
      ),
      (
        {
          'cast': [character, character],
        },
        'invalid_argument',
      ),
      (
        {
          'cast': [' '],
        },
        'invalid_argument',
      ),
      (
        {
          'elements': [
            {'type': 'character', 'character_id': character},
            {'type': 'action', 'text': '推门。'},
            {'type': 'dialogue', 'text': '你来了。'},
          ],
        },
        'invalid_argument',
      ),
      (
        {
          'elements': [
            {'type': 'character', 'character_id': 'missing'},
          ],
        },
        'invalid_argument',
      ),
      ({'episode_id': 'missing'}, 'invalid_argument'),
      ({'location_id': 'missing'}, 'invalid_argument'),
      ({'before_scene_id': 'missing'}, 'invalid_argument'),
    ];
    const anchors = {'episode_id', 'before_scene_id', 'after_scene_id'};
    for (final (fields, code) in cases) {
      // 落点必须显式给；用例本身不测落点时补一个，不依赖当前集。
      final scoped = fields.keys.any(anchors.contains)
          ? fields
          : {'episode_id': initial.episodeId, ...fields};
      final result = await manager().executeTool(
        name: 'Create',
        input: {
          'path': '/scenes',
          'fields': {'synopsis': '失败不留场次', ...scoped},
        },
      );
      expect(result['error_code'], code, reason: '$fields');
    }
    expect(
      await database.select(database.screenplayScenes).get(),
      beforeScenes,
    );
    expect(
      await database.select(database.screenplaySceneElements).get(),
      beforeElements,
    );
    expect(
      await database.select(database.screenplaySceneCharacters).get(),
      isEmpty,
    );
    expect(await database.workingChangeDao.getAll(), isEmpty);
  });

  test(
    'scene Create rolls back content if staging fails after validation',
    () async {
      final initial = await ScreenplayService(
        database,
      ).createInitialStructure();
      final character = await contentService.createCharacterProfile(
        defaultName: '林岚',
      );
      final beforeScenes = await database
          .select(database.screenplayScenes)
          .get();
      final beforeElements = await database
          .select(database.screenplaySceneElements)
          .get();
      await database.customStatement(
        "CREATE TRIGGER reject_scene_change BEFORE INSERT ON working_changes BEGIN SELECT RAISE(ABORT, 'staging failed'); END",
      );
      await expectLater(
        manager().executeTool(
          name: 'Create',
          input: {
            'path': 'scenes',
            'fields': {
              'episode_id': initial.episodeId,
              'synopsis': '有效输入但写入失败',
              'cast': [character],
              'elements': [
                {'type': 'character', 'character_id': character},
                {'type': 'dialogue', 'text': '你来了。'},
              ],
            },
          },
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        await database.select(database.screenplayScenes).get(),
        beforeScenes,
      );
      expect(
        await database.select(database.screenplaySceneElements).get(),
        beforeElements,
      );
      expect(
        await database.select(database.screenplaySceneCharacters).get(),
        isEmpty,
      );
      expect(await database.workingChangeDao.getAll(), isEmpty);
    },
  );

  test(
    'legacy scene paths remain readable while results use relative paths',
    () async {
      final initial = await ScreenplayService(
        database,
      ).createInitialStructure();
      final tools = manager();
      final result = await tools.executeTool(
        name: 'Create',
        input: {
          'path': '/scenes',
          'fields': {'episode_id': initial.episodeId, 'synopsis': '兼容路径'},
        },
      );
      final path = 'scenes/${result['id']}';
      expect(result['path'], path);
      final relative = await tools.executeTool(
        name: 'Read',
        input: {'path': path},
      );
      final legacy = await tools.executeTool(
        name: 'Read',
        input: {'path': '/$path'},
      );
      expect(legacy, relative);
      expect(legacy['path'], path);
      expect(
        (await database.workingChangeDao.getAll()).single.resourcePath,
        path,
      );
    },
  );

  test('episode Create requires an explicit season', () async {
    final initial = await ScreenplayService(database).createInitialStructure();
    // 单季剧本也要显式给季，否则新集会跟着选中季走。
    final tools = manager(seasonId: initial.seasonId);
    final missing = await tools.executeTool(
      name: 'Create',
      input: {
        'path': 'episodes',
        'fields': {'title': '没有落点'},
      },
    );
    expect(missing['error_code'], 'invalid_argument');
    expect(missing['missing_fields'], ['season_id']);
    final created = await tools.executeTool(
      name: 'Create',
      input: {
        'path': 'episodes',
        'fields': {'season_id': initial.seasonId, 'title': '显式落点'},
      },
    );
    expect(created['ok'], isTrue, reason: '$created');
    final foreign = await tools.executeTool(
      name: 'Create',
      input: {
        'path': 'episodes',
        'fields': {'season_id': 'missing', 'title': '不存在的季'},
      },
    );
    expect(foreign['error_code'], 'invalid_argument');
  });

  test(
    'scene validation explains cast input and missing placement fields',
    () async {
      final initial = await ScreenplayService(
        database,
      ).createInitialStructure();
      final character = await contentService.createCharacterProfile(
        defaultName: '角色',
      );
      final tools = manager();
      final rejected = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'scenes?episode_id=${initial.episodeId}',
          'fields': {
            'cast': [
              {'character_id': character},
            ],
          },
        },
      );
      expect(rejected['ok'], isFalse);
      expect(rejected['error'], contains('cast[0] must be string'));
      expect(rejected['error'], contains('Provide at least one of'));
      expect(
        rejected['error'],
        contains(
          'Provide at least one of episode_id, before_scene_id, after_scene_id in fields.',
        ),
      );
      expect(rejected.containsKey('required_fields'), isFalse);
      expect(await database.select(database.screenplayScenes).get(), isEmpty);
      final created = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'scenes',
          'fields': {
            'episode_id': initial.episodeId,
            'cast': [character],
          },
        },
      );
      expect(created['ok'], isTrue, reason: '$created');
    },
  );

  test(
    'scene time is canonical and time_label remains an input alias',
    () async {
      final initial = await ScreenplayService(
        database,
      ).createInitialStructure();
      final tools = manager();
      for (final key in ['time', 'time_label']) {
        final created = await tools.executeTool(
          name: 'Create',
          input: {
            'path': 'scenes',
            'fields': {'episode_id': initial.episodeId, key: '清晨'},
          },
        );
        expect(created['ok'], isTrue, reason: '$created');
        expect(created.containsKey('ignored_fields'), isFalse);
        final path = created['path'];
        for (final updateKey in ['time', 'time_label']) {
          final updated = await tools.executeTool(
            name: 'Write',
            input: {
              'path': path,
              'fields': {updateKey: '夜-$updateKey'},
            },
          );
          expect(updated['ok'], isTrue, reason: '$updated');
          final read = await tools.executeTool(
            name: 'Read',
            input: {'path': path},
          );
          expect(read['time'], '夜-$updateKey');
          expect(read.containsKey('time_label'), isFalse);
        }
        final conflict = await tools.executeTool(
          name: 'Write',
          input: {
            'path': path,
            'fields': {'time': '早晨', 'time_label': '傍晚'},
          },
        );
        expect(conflict['ok'], isFalse);
        expect(conflict['error'], contains('Conflicting values for time'));
        final row = await database.screenplayDao.getScene(
          created['id'] as String,
        );
        expect(row!.timeLabel, '夜-time_label');
      }
    },
  );

  test('scene Create requires an explicit episode or anchor', () async {
    final initial = await ScreenplayService(database).createInitialStructure();
    // 选中集不再充当默认落点，否则新场次会悄悄落进用户正在看的那一集。
    final tools = manager(episodeId: initial.episodeId);
    final missing = await tools.executeTool(
      name: 'Create',
      input: {
        'path': 'scenes',
        'fields': {'synopsis': '没有落点'},
      },
    );
    expect(missing['error_code'], 'invalid_argument');
    expect(missing.containsKey('missing_fields'), isFalse);
    expect(missing.containsKey('required_fields'), isFalse);
    expect((missing['validation_errors'] as List).single['at_least_one_of'], [
      'episode_id',
      'before_scene_id',
      'after_scene_id',
    ]);
    expect(await database.select(database.screenplayScenes).get(), isEmpty);
    final created = await tools.executeTool(
      name: 'Create',
      input: {
        'path': 'scenes',
        'fields': {'episode_id': initial.episodeId, 'synopsis': '显式落点'},
      },
    );
    expect(created['ok'], isTrue);
  });

  test(
    'scene Create reports conflicting anchors and invalid enum together',
    () async {
      final initial = await ScreenplayService(
        database,
      ).createInitialStructure();
      final tools = manager();
      final fields = <String, dynamic>{
        'episode_id': initial.episodeId,
        'before_scene_id': 'scene_anchor',
        'interior_exterior': '内',
        'synopsis': 'An interior scene',
      };
      final result = await tools.executeTool(
        name: 'Create',
        input: {'path': 'scenes', 'fields': fields},
      );
      final errors = result['validation_errors'] as List;
      expect(
        errors.map((e) => (e as Map)['code']),
        containsAll(['conflicting_fields', 'invalid_enum']),
      );
      expect((result['input_contract'] as Map)['enum_fields'], {
        'interior_exterior': [
          'interior',
          'exterior',
          'interior_exterior',
          null,
        ],
        'stage': ['draft', 'final'],
      });
      final before = await tools.executeTool(
        name: 'Read',
        input: {'path': 'scenes?episode_id=${initial.episodeId}'},
      );
      expect(before['entries'], isEmpty);
      fields.remove('before_scene_id');
      fields['interior_exterior'] = 'interior';
      final corrected = await tools.executeTool(
        name: 'Create',
        input: {'path': 'scenes', 'fields': fields},
      );
      expect(corrected['ok'], isTrue);

      // 同批后续调用缺 path 时仍失败，不从成功调用继承路径。
      final missingPath = await tools.executeTool(
        name: 'Create',
        input: {'fields': fields},
      );
      expect(missingPath['error_code'], 'invalid_argument');
      expect(missingPath['missing_fields'], ['path']);
      final after = await tools.executeTool(
        name: 'Read',
        input: {'path': 'scenes?episode_id=${initial.episodeId}'},
      );
      expect(after['entries'], hasLength(1));
    },
  );

  test(
    'empty season Create and nullable partial Write preserve their operation-local contracts',
    () async {
      await ScreenplayService(database).createInitialStructure();
      final tools = manager();
      addTearDown(tools.dispose);
      final created = await tools.executeTool(
        name: 'Create',
        input: {'path': 'seasons', 'fields': <String, dynamic>{}},
      );
      expect(created['ok'], isTrue, reason: '$created');
      final id = created['id'] as String;
      expect(await database.screenplayDao.getSeason(id), isNotNull);
      final set = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'seasons/$id',
          'fields': {'planned_episode_count': 8},
        },
      );
      expect(set['ok'], isTrue, reason: '$set');
      final cleared = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'seasons/$id',
          'fields': {'planned_episode_count': null},
        },
      );
      expect(cleared['ok'], isTrue, reason: '$cleared');
      expect(
        (await database.screenplayDao.getSeason(id))!.plannedEpisodeCount,
        isNull,
      );
      final denied = await tools.executeTool(
        name: 'Create',
        input: {'path': 'screenplay', 'fields': <String, dynamic>{}},
      );
      expect(denied['ok'], isFalse);
    },
  );

  test(
    'malformed screenplay fields still return the specific path contract',
    () async {
      final tools = manager();
      for (final fields in [null, 'not an object', <Object>[]]) {
        final result = await tools.executeTool(
          name: 'Create',
          input: {'path': 'seasons', 'fields': fields},
        );
        expect(result['ok'], isFalse);
        expect((result['input_contract'] as Map)['allowed_fields'], [
          'title',
          'planned_episode_count',
        ]);
      }
    },
  );

  test(
    'episode listing spans every season regardless of the current one',
    () async {
      final created = await ScreenplayService(
        database,
      ).createInitialStructure();
      final root = await database.screenplayDao.getRoot();
      final second = await ScreenplayService(
        database,
      ).createSeason(screenplayId: root!.id, title: '第二季');
      // 选中第二季不应把整剧的集列表悄悄缩成第二季的。
      final screenplayManager = manager(seasonId: second.seasonId);

      final result = await screenplayManager.executeTool(
        name: 'Read',
        input: {'path': 'episodes'},
      );

      expect(result.containsKey('season_id'), isFalse);
      expect(result['total'], 2);
      expect(
        [
          for (final entry in (result['entries'] as List).cast<Map>())
            entry['id'],
        ],
        [created.episodeId, second.episodeId],
      );

      final scoped = await screenplayManager.executeTool(
        name: 'Read',
        input: {'path': 'episodes?season_id=${second.seasonId}'},
      );
      expect(scoped['season_id'], second.seasonId);
      expect((scoped['entries'] as List).single['id'], second.episodeId);
    },
  );

  test(
    'structured element write stages one scene-level overlay change',
    () async {
      final created = await ScreenplayService(
        database,
      ).createInitialStructure();
      final root = await database.screenplayDao.getRoot();
      final sceneId = await ScreenplayService(database).createScene(
        screenplayId: root!.id,
        episodeId: created.episodeId,
        timeLabel: '夜',
      );
      final screenplayManager = manager(seasonId: created.seasonId);

      final write = await screenplayManager.executeTool(
        name: 'Write',
        input: {
          'path': 'scenes/$sceneId/elements',
          'value': [
            {'type': 'action', 'text': '李默推开门。'},
            {'type': 'transition', 'text': '切至：'},
          ],
        },
      );

      expect(write['ok'], isTrue);
      final changes = await overlay.getWorkingChangesForResource(
        'scenes/$sceneId/elements',
      );
      expect(changes, hasLength(1));
      expect(changes.single.resourceType, 'screenplay_scenes');
      expect(changes.single.field, 'elements');
      expect(changes.single.sourceSessionId, 'session_1');

      final read = await screenplayManager.executeTool(
        name: 'Read',
        input: {'path': 'scenes/$sceneId/elements'},
      );
      final entries = read['entries'] as List<dynamic>;
      expect(entries, hasLength(2));
      expect(entries.first['type'], 'action');
      expect(entries.first['text'], '李默推开门。');
    },
  );

  test(
    'episode scalar paths preserve title, ordering and season writes',
    () async {
      final service = ScreenplayService(database);
      final initial = await service.createInitialStructure();
      final sibling = await service.createEpisode(seasonId: initial.seasonId);
      final root = (await database.screenplayDao.getRoot())!;
      final otherSeason = await service.createSeason(screenplayId: root.id);
      final tools = manager();
      for (final entry in <String, Object>{
        'title': 'Updated episode',
        'episode_number': 2,
        'season_id': otherSeason.seasonId,
      }.entries) {
        final result = await tools.executeTool(
          name: 'Write',
          input: {
            'path': 'episodes/${initial.episodeId}/${entry.key}',
            'value': entry.value,
          },
        );
        expect(result['ok'], isTrue, reason: '${entry.key}: $result');
        final current = (await database.screenplayDao.getEpisode(
          initial.episodeId,
        ))!;
        expect(
          switch (entry.key) {
            'title' => current.title,
            'episode_number' => current.episodeNumber,
            'season_id' => current.seasonId,
            _ => throw StateError('Unexpected test field'),
          },
          entry.value,
          reason: entry.key,
        );
      }
      final episode = (await database.screenplayDao.getEpisode(
        initial.episodeId,
      ))!;
      expect(episode.title, 'Updated episode');
      expect(episode.episodeNumber, 2);
      expect(episode.seasonId, otherSeason.seasonId);
      expect(
        (await database.screenplayDao.getEpisode(sibling))!.episodeNumber,
        1,
      );
      expect(await overlay.getWorkingChanges(), isEmpty);
    },
  );

  test('episode outline write and edit stage overlay changes', () async {
    final created = await ScreenplayService(database).createInitialStructure();
    final episodeId = created.episodeId;
    final tools = manager(seasonId: created.seasonId);

    final write = await tools.executeTool(
      name: 'Write',
      input: {'path': 'episodes/$episodeId/outline', 'value': '第一集要把两人推到摊牌。'},
    );
    expect(write['ok'], isTrue, reason: '$write');
    final changes = await overlay.getWorkingChangesForResource(
      'episodes/$episodeId/outline',
    );
    expect(changes, hasLength(1));
    expect(changes.single.resourceType, 'screenplay_episodes');
    expect(changes.single.field, 'outline');
    expect(changes.single.sourceSessionId, 'session_1');

    // apply-on-stage：Read 直接看到待审阅的值。
    final read = await tools.executeTool(
      name: 'Read',
      input: {'path': 'episodes/$episodeId/outline'},
    );
    expect(read['value'], '第一集要把两人推到摊牌。');

    final edit = await tools.executeTool(
      name: 'Edit',
      input: {
        'path': 'episodes/$episodeId/outline',
        'old_text': '摊牌',
        'new_text': '决裂',
      },
    );
    expect(edit['ok'], isTrue, reason: '$edit');
    expect(
      (await database.screenplayDao.getEpisode(episodeId))!.outline,
      '第一集要把两人推到决裂。',
    );

    final missed = await tools.executeTool(
      name: 'Edit',
      input: {
        'path': 'episodes/$episodeId/outline',
        'old_text': '不存在的原文',
        'new_text': 'x',
      },
    );
    expect(missed['error_code'], 'failed_precondition', reason: '$missed');
  });

  test('screenplay Write reports updated only when data changes', () async {
    final service = ScreenplayService(database);
    final initial = await service.createInitialStructure();
    final root = (await database.screenplayDao.getRoot())!;
    final sceneId = await service.createScene(
      screenplayId: root.id,
      episodeId: initial.episodeId,
      timeLabel: '夜',
    );
    final tools = manager(seasonId: initial.seasonId);

    for (final (input, expected) in [
      (
        {
          'path': 'scenes/$sceneId',
          'fields': {'time_label': '夜'},
        },
        false,
      ),
      (
        {
          'path': 'scenes/$sceneId',
          'fields': {'time_label': '早晨'},
        },
        true,
      ),
      (
        {'path': 'episodes/${initial.episodeId}/outline', 'value': '两人摊牌。'},
        true,
      ),
      (
        {'path': 'episodes/${initial.episodeId}/outline', 'value': '两人摊牌。'},
        false,
      ),
    ]) {
      final result = await tools.executeTool(name: 'Write', input: input);
      expect(result['ok'], isTrue, reason: '$input $result');
      expect(result['updated'], expected, reason: '$input $result');
    }
  });

  test('episode outline overlay rejects a second session', () async {
    final created = await ScreenplayService(database).createInitialStructure();
    final episodeId = created.episodeId;
    final first = await manager(sessionId: 'session_1').executeTool(
      name: 'Write',
      input: {'path': 'episodes/$episodeId/outline', 'value': '会话一的大纲'},
    );
    expect(first['ok'], isTrue, reason: '$first');
    // 同会话再写是合并。
    final merged = await manager(sessionId: 'session_1').executeTool(
      name: 'Write',
      input: {'path': 'episodes/$episodeId/outline', 'value': '会话一的第二版'},
    );
    expect(merged['ok'], isTrue, reason: '$merged');
    expect(
      await overlay.getWorkingChangesForResource('episodes/$episodeId/outline'),
      hasLength(1),
    );
    // 换会话叠加会把前一个会话的 oldText 冲掉，必须拦住。
    final other = await manager(sessionId: 'session_2').executeTool(
      name: 'Write',
      input: {'path': 'episodes/$episodeId/outline', 'value': '会话二的大纲'},
    );
    expect(other['error_code'], 'conflict', reason: '$other');
    expect(
      (await database.screenplayDao.getEpisode(episodeId))!.outline,
      '会话一的第二版',
    );
  });

  test(
    'scene body overlay merges per session and rejects another session',
    () async {
      final created = await ScreenplayService(
        database,
      ).createInitialStructure();
      final root = await database.screenplayDao.getRoot();
      final sceneId = await ScreenplayService(
        database,
      ).createScene(screenplayId: root!.id, episodeId: created.episodeId);
      final firstManager = manager(seasonId: created.seasonId);

      await firstManager.executeTool(
        name: 'Write',
        input: {
          'path': 'scenes/$sceneId/elements',
          'value': [
            {'type': 'action', 'text': '第一稿'},
          ],
        },
      );
      await firstManager.executeTool(
        name: 'Write',
        input: {
          'path': 'scenes/$sceneId/elements',
          'value': [
            {'type': 'action', 'text': '第二稿'},
          ],
        },
      );

      final changes = await overlay.getWorkingChangesForResource(
        'scenes/$sceneId/elements',
      );
      expect(changes, hasLength(1));
      expect(changes.single.oldText, '[]');
      expect(changes.single.newText, contains('第二稿'));

      final secondManager = manager(
        seasonId: created.seasonId,
        sessionId: 'session_2',
      );
      final conflict = await secondManager.executeTool(
        name: 'Write',
        input: {
          'path': 'scenes/$sceneId/elements',
          'value': [
            {'type': 'action', 'text': '竞争稿'},
          ],
        },
      );
      expect(conflict['error_code'], 'conflict');

      final rows = await database.screenplayDao.getElementRows(sceneId);
      expect(rows.single.textContent, '第二稿');
    },
  );

  test('screenplay body write requires a session context', () async {
    final created = await ScreenplayService(database).createInitialStructure();
    final root = await database.screenplayDao.getRoot();
    final sceneId = await ScreenplayService(
      database,
    ).createScene(screenplayId: root!.id, episodeId: created.episodeId);

    final result = await manager(seasonId: created.seasonId, sessionId: null)
        .executeTool(
          name: 'Write',
          input: {
            'path': 'scenes/$sceneId/elements',
            'value': [
              {'type': 'action', 'text': '不应写入'},
            ],
          },
        );

    expect(result['error_code'], 'unavailable');
    expect(await database.screenplayDao.getElementRows(sceneId), isEmpty);
  });

  test('new season joins the episode listing', () async {
    final initial = await ScreenplayService(database).createInitialStructure();
    final screenplayManager = manager(seasonId: initial.seasonId);

    final created = await screenplayManager.executeTool(
      name: 'Create',
      input: {
        'path': 'seasons',
        'fields': {'title': '第二季'},
      },
    );

    // 选中季不再收窄 listing，新季的集直接出现在整剧列表里。
    final defaultEpisodes = await screenplayManager.executeTool(
      name: 'Read',
      input: {'path': 'episodes'},
    );
    expect(defaultEpisodes.containsKey('season_id'), isFalse);
    expect(
      [
        for (final entry in (defaultEpisodes['entries'] as List).cast<Map>())
          entry['id'],
      ],
      [initial.episodeId, created['episode_id']],
    );
  });

  test('cross-work multi-season episode listing spans every season', () async {
    final targetDatabase = NovelContentDatabase.forTest(
      NativeDatabase.memory(),
    );
    addTearDown(targetDatabase.close);
    final targetService = NovelContentService(targetDatabase);
    final targetScreenplay = ScreenplayService(targetDatabase);
    final initial = await targetScreenplay.createInitialStructure();
    final root = await targetDatabase.screenplayDao.getRoot();
    final second = await targetScreenplay.createSeason(screenplayId: root!.id);
    final access = _ScreenplayCrossWorkAccess(targetService);
    final screenplayManager = manager(
      kind: contentKindNovel,
      crossWorkAccess: access,
    );

    final result = await screenplayManager.executeTool(
      name: 'Read',
      input: {'path': '/works/target/episodes'},
    );

    expect(result['error'], isNull);
    expect(result.containsKey('season_id'), isFalse);
    expect(
      [
        for (final entry in (result['entries'] as List).cast<Map>())
          entry['id'],
      ],
      [initial.episodeId, second.episodeId],
    );
    final missing = await screenplayManager.executeTool(
      name: 'Read',
      input: {'path': '/works/target/episodes?season_id=missing'},
    );
    expect(missing['error_code'], 'not_found');
    expect(missing['hint'], contains('/works/target/seasons'));
    expect(access.releaseCount, 0);
    screenplayManager.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(access.releaseCount, 1);
  });

  test(
    'screenplay read paths round-trip without replacing IDs by titles',
    () async {
      final service = ScreenplayService(database);
      final initial = await service.createInitialStructure();
      final root = (await database.screenplayDao.getRoot())!;
      await service.updateSeason(seasonId: initial.seasonId, title: 'synopsis');
      await service.updateEpisode(
        episodeId: initial.episodeId,
        title: 'synopsis',
      );
      final scene = await service.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
        synopsis: '/场景原文',
      );
      await service.writeElements(
        sceneId: scene,
        elements: [
          ScreenplayElement(
            id: '',
            type: ScreenplayElementType.action,
            text: '/灯光熄灭\n/幕落',
          ),
        ],
      );
      final elementId = (await database.screenplayDao.getElementRows(
        scene,
      )).single.id;
      final tools = manager(
        episodeId: initial.episodeId,
        crossWorkAccess: _ScreenplayCrossWorkAccess(contentService),
      );
      addTearDown(tools.dispose);
      for (final collection in ['scenes']) {
        final local = await tools.executeTool(
          name: 'Read',
          input: {'path': '/$collection'},
        );
        final absolute = await tools.executeTool(
          name: 'Read',
          input: {'path': '/works/current/$collection'},
        );
        // 当前集不隐式收窄 listing，相对与绝对路径都返回整剧。
        expect(local.containsKey('episode_id'), isFalse);
        expect(absolute.containsKey('episode_id'), isFalse);
        expect(absolute['total'], local['total']);
        expect(
          [
            for (final entry in (absolute['entries'] as List).cast<Map>())
              entry['id'],
          ],
          [
            for (final entry in (local['entries'] as List).cast<Map>())
              entry['id'],
          ],
        );
        final invalid = await tools.executeTool(
          name: 'Read',
          input: {'path': '/$collection?episode_id=missing'},
        );
        expect(invalid['error_code'], 'not_found');
      }
      for (final pair in [
        ('seasons', 'seasons/${initial.seasonId}'),
        ('episodes', 'episodes/${initial.episodeId}'),
        ('scenes/$scene/elements', 'scenes/$scene/elements/$elementId'),
      ]) {
        final listed = await tools.executeTool(
          name: 'Read',
          input: {'path': pair.$1},
        );
        final entry = (listed['entries'] as List).single as Map;
        expect(entry['path'], pair.$2);
        final read = await tools.executeTool(
          name: 'Read',
          input: {'path': entry['path']},
        );
        expect(read['path'], pair.$2);
        expect(read['error'], isNull);
      }
      for (final field in [
        '$scene/synopsis',
        '$scene/elements/$elementId/text',
      ]) {
        final path = 'scenes/$field';
        final read = await tools.executeTool(
          name: 'Read',
          input: {'path': path},
        );
        expect(read['path'], path);
      }
    },
  );

  test(
    'cross-work scene text stays raw and listings span the target screenplay',
    () async {
      final target = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(target.close);
      final service = ScreenplayService(target);
      final initial = await service.createInitialStructure();
      final root = (await target.screenplayDao.getRoot())!;
      final scene = await service.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
      );
      const body = '/灯光熄灭\n/幕落';
      await service.writeElements(
        sceneId: scene,
        elements: [
          ScreenplayElement(
            id: '',
            type: ScreenplayElementType.action,
            text: body,
          ),
        ],
      );
      final elementId = (await target.screenplayDao.getElementRows(
        scene,
      )).single.id;
      // 当前作品的集不会泄漏到外部读取；省略 episode_id 时枚举目标作品自己的集。
      final tools = manager(
        episodeId: initial.episodeId,
        crossWorkAccess: _ScreenplayCrossWorkAccess(
          NovelContentService(target),
        ),
      );
      addTearDown(tools.dispose);
      for (final collection in ['scenes']) {
        final path = '/works/target/$collection';
        final expected = collection == 'scenes' ? 1 : 0;
        final unscoped = await tools.executeTool(
          name: 'Read',
          input: {'path': path},
        );
        expect(unscoped['error'], isNull);
        // 枚举整剧时不回显单集作用域。
        expect(unscoped.containsKey('episode_id'), isFalse);
        expect(unscoped['entries'], hasLength(expected));
        final invalid = await tools.executeTool(
          name: 'Read',
          input: {'path': '$path?episode_id=missing'},
        );
        expect(invalid['error_code'], 'not_found');
        expect(invalid['hint'], contains('/works/target/episodes'));
        final valid = await tools.executeTool(
          name: 'Read',
          input: {'path': '$path?episode_id=${initial.episodeId}'},
        );
        expect(valid['error'], isNull);
        expect(valid['episode_id'], initial.episodeId);
        expect(valid['entries'], hasLength(expected));
      }
      final path = '/works/target/scenes/$scene/elements';
      final listing = await tools.executeTool(
        name: 'Read',
        input: {'path': path},
      );
      final entry = (listing['entries'] as List).single as Map;
      expect(entry['text'], body);
      expect(entry['path'], '$path/$elementId');
      final field = await tools.executeTool(
        name: 'Read',
        input: {'path': '${entry['path']}/text'},
      );
      expect(field['value'], body);
      expect(field['path'], '$path/$elementId/text');
    },
  );

  test(
    'Write rejects invalid fields and rolls back a failed scene move',
    () async {
      final service = ScreenplayService(database);
      final initial = await service.createInitialStructure();
      final root = (await database.screenplayDao.getRoot())!;
      final sceneId = await service.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
        timeLabel: '夜',
      );
      final tools = manager();
      for (final fields in [
        {'time_label': '早晨', 'cast': 'bad'},
        {'time_label': '早晨', 'stage': 'unknown'},
        {'time_label': '早晨', 'before_scene_id': 'missing'},
      ]) {
        final result = await tools.executeTool(
          name: 'Write',
          input: {'path': 'scenes/$sceneId', 'fields': fields},
        );
        expect(result['ok'], isFalse, reason: '$fields');
        expect(
          (await database.screenplayDao.getScene(sceneId))!.timeLabel,
          '夜',
        );
        expect(
          await overlay.getWorkingChangesForResource(
            'scenes/$sceneId/elements',
          ),
          isEmpty,
        );
      }
      for (final fields in [
        {'unknown_title': '不存在的字段'},
        {'time_label': '早晨', 'unexpected': true},
        {'time_label': '早晨', 'scene_number': 3},
      ]) {
        final result = await tools.executeTool(
          name: 'Write',
          input: {'path': 'scenes/$sceneId', 'fields': fields},
        );
        expect(result['ok'], isTrue, reason: '$result');
        expect(result['ignored_fields'], [fields.keys.last]);
        if (fields.containsKey('time_label')) {
          expect(
            (await database.screenplayDao.getScene(sceneId))!.timeLabel,
            '早晨',
          );
        } else {
          expect(result['updated'], isFalse);
          expect(
            (await database.screenplayDao.getScene(sceneId))!.timeLabel,
            '夜',
          );
        }
      }
      final readonly = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'episodes/${initial.episodeId}',
          'fields': {'title': '可写标题', 'id': 'episode_x'},
        },
      );
      expect(readonly['ok'], isTrue, reason: '$readonly');
      expect(readonly['ignored_fields'], ['id']);
      expect(
        (await database.screenplayDao.getEpisode(initial.episodeId))!.title,
        '可写标题',
      );
      // 结构字段与大纲同批写入：前者直写，后者走待审阅，任何一半都不能被静默丢掉。
      final mixed = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'episodes/${initial.episodeId}',
          'fields': {'title': '新集名', 'outline': '新大纲'},
        },
      );
      expect(mixed['error_code'], isNull, reason: '$mixed');
      final afterMixed = (await database.screenplayDao.getEpisode(
        initial.episodeId,
      ))!;
      expect(afterMixed.title, '新集名');
      expect(afterMixed.outline, '新大纲');
      final invalidPath = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'episodes/${initial.episodeId}/unknown/extra',
          'fields': {'title': '不能写入'},
        },
      );
      expect(invalidPath['error_code'], 'invalid_argument');
      final precedence = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'scenes/$sceneId/synopsis',
          'value': '正确梗概',
          'fields': {'synopsis': '错误梗概'},
        },
      );
      expect(precedence['error_code'], 'invalid_argument');
      expect(
        (await database.screenplayDao.getScene(sceneId))!.synopsis,
        isNot('正确梗概'),
      );
    },
  );

  test('Read query validation follows the screenplay resource level', () async {
    final initial = await ScreenplayService(database).createInitialStructure();
    final tools = manager(episodeId: initial.episodeId);
    for (final path in [
      'seasons?search=不存在',
      'episodes?search=不存在',
      'beats?stage=draft',
      'scenes?season_id=${initial.seasonId}',
      'scenes?stage=unknown',
      'episodes/${initial.episodeId}?season_id=${initial.seasonId}',
    ]) {
      final result = await tools.executeTool(
        name: 'Read',
        input: {'path': path},
      );
      expect(result['error_code'], 'invalid_argument', reason: path);
    }
    final valid = await tools.executeTool(
      name: 'Read',
      input: {
        'path':
            'scenes?episode_id=${initial.episodeId}&search=不存在&stage=draft&limit=1',
      },
    );
    expect(valid['error'], isNull);
    expect(valid['entries'], isEmpty);
  });

  test('search supports screenplay scans and respects kind gates', () async {
    await ScreenplayService(database).createInitialStructure();
    final tools = manager();
    final character = await tools.executeTool(
      name: 'Create',
      input: {
        'path': 'characters',
        'fields': {'name': '林越', 'description': '唯一线索'},
      },
    );
    expect(character['error'], isNull);
    for (final tool in ['Glob', 'Grep', 'Replace']) {
      Map<String, dynamic> input(String path) => {
        'path': path,
        'pattern': tool == 'Glob' ? '**' : '唯一线索',
        if (tool == 'Replace') 'replacement': '新线索',
      };
      for (final path in ['/', 'screenplay']) {
        final result = await tools.executeTool(name: tool, input: input(path));
        expect(result['ok'], isTrue, reason: '$tool $path');
      }
      final denied = await tools.executeTool(
        name: tool,
        input: input('chapters'),
      );
      expect(denied['error_code'], 'invalid_argument', reason: tool);
      final scoped = await tools.executeTool(
        name: tool,
        input: input('characters'),
      );
      expect(scoped['error'], isNull, reason: tool);
    }
    final found = await tools.executeTool(
      name: 'Grep',
      input: {'path': 'characters', 'pattern': '唯一线索'},
    );
    expect(found['text'], contains('唯一线索'));
    final deniedPattern = await tools.executeTool(
      name: 'Glob',
      input: {'pattern': 'chapters/*/content'},
    );
    expect(deniedPattern['error_code'], 'invalid_argument');
    final scopedPattern = await tools.executeTool(
      name: 'Grep',
      input: {'glob': 'characters/*/description', 'pattern': '唯一线索'},
    );
    expect(scopedPattern['text'], contains('唯一线索'));
    final cross = manager(
      kind: contentKindNovel,
      crossWorkAccess: _ScreenplayCrossWorkAccess(contentService),
    );
    addTearDown(cross.dispose);
    final crossDenied = await cross.executeTool(
      name: 'Grep',
      input: {'path': '/works/target/chapters', 'pattern': '唯一线索'},
    );
    expect(crossDenied['error_code'], 'invalid_argument');
    expect(crossDenied['hint'], contains('Read /works/target'));
    expect(crossDenied['hint'], contains('Read /_schema/groups/screenplay'));
    expect(crossDenied['hint'], isNot(contains('/_schema/groups/works/')));
    final crossUnsupported = await cross.executeTool(
      name: 'Grep',
      input: {'path': '/works/target', 'pattern': '唯一线索'},
    );
    expect(crossUnsupported['ok'], isTrue);
    expect(crossUnsupported['text'], contains('唯一线索'));
    final crossFound = await cross.executeTool(
      name: 'Grep',
      input: {'path': '/works/target/characters', 'pattern': '唯一线索'},
    );
    expect(crossFound['text'], contains('/works/target/characters/'));
    expect(crossFound['text'], contains('唯一线索'));
  });

  test(
    'nested schema parses singleton, listing, IDs and fields distinctly',
    () {
      final root = parseAiToolPath('screenplay');
      expect(root.id, isNull);
      expect(root.field, isNull);
      final listing = parseAiToolPath('seasons');
      expect(listing.id, isNull);
      expect(listing.field, isNull);
      expect(listing.usesNamePath, isFalse);
      final resource = parseAiToolPath('scenes/synopsis');
      expect(resource.id, 'synopsis');
      expect(resource.field, isNull);
      final field = parseAiToolPath(
        '/works/target/scenes/synopsis/elements/text/text',
      );
      expect(field.workId, 'target');
      expect(field.id, 'text');
      expect(field.field, 'text');
      expect(field.usesNamePath, isFalse);
      expect(parseAiToolPath('outlines/卷一/content').namePath, ['卷一']);
    },
  );

  test(
    'screenplay field notes expose supported resources and preserve validation',
    () async {
      final service = ScreenplayService(database);
      final initial = await service.createInitialStructure();
      final root = (await database.screenplayDao.getRoot())!;
      final tools = manager();
      final notes = pathSchemaFieldNotes(kind: contentKindScreenplay);
      expect(notes, contains('- seasons（季）\n  path: seasons/{season_id}'));
      expect(notes, contains('- episodes（集）\n  path: episodes/{episode_id}'));
      expect(notes, isNot(contains('- beats（节拍）')));
      expect(notes, contains('- scenes（场次）\n  path: scenes/{scene_id}'));
      expect(notes, contains('- scenes/{scene_id}/elements（正文元素）\n'));
      expect(notes, isNot(contains('screenplay/')));
      expect(notes, contains('episode_number'));
      expect(notes, contains('element_id'));
      expect(notes, contains('seasons/{season_id}'));
      expect(notes, isNot(contains('beats/{beat_id}')));
      // screenplay 单例保持 hidden：整表只读的派生统计不占常驻字段字典。
      for (final field in ['season_count', 'page_eighths（readonly）']) {
        expect(notes, isNot(contains(field)));
      }
      // story_state 只暴露 content —— status 恒为 active，读出来做不了判断。
      expect(notes, contains('story_state'));
      expect(notes, isNot(contains('快照版本状态')));
      final novelNotes = pathSchemaFieldNotes(kind: contentKindNovel);
      for (final field in ['episode_number', 'element_id', 'season_count']) {
        expect(novelNotes, isNot(contains(field)));
      }
      final paths = '${pathSchema(kind: contentKindScreenplay)}\n$notes';
      expect(paths, contains('episodes/{episode_id}'));
      expect(paths, contains('scenes/{scene_id}/elements/{element_id}'));
      expect(notes, contains('text：'));
      // 普通可见集合的字段说明仍输出。
      expect(notes, contains('appearance'));
      final createdContract = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'episodes',
          'fields': {
            'season_id': initial.seasonId,
            'title': '陨落的天才',
            'target_duration_seconds': 1200,
            'episode_number': 4,
            'outline': '创建时附带的大纲',
            'cast': [],
          },
        },
      );
      expect(createdContract['ok'], isTrue, reason: '$createdContract');
      expect(createdContract['ignored_fields'], [
        'target_duration_seconds',
        'episode_number',
        'outline',
        'cast',
      ]);
      final createdEpisode = (await database.screenplayDao.getEpisode(
        createdContract['id'] as String,
      ))!;
      expect(createdEpisode.title, '陨落的天才');
      expect(createdEpisode.episodeNumber, 2);
      expect(createdEpisode.outline, isEmpty);
      final contract = await tools.executeTool(
        name: 'Read',
        input: {'path': '/_schema/episodes'},
      );
      expect(contract['fields']['episode_number']['create'], isFalse);
      expect(contract['fields']['outline']['create'], isFalse);
      await service.createEpisode(seasonId: initial.seasonId);
      final write = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'episodes/${initial.episodeId}',
          'fields': {
            'title': '新的集标题',
            'episode_number': 2,
            'season_id': initial.seasonId,
          },
        },
      );
      expect(write['ok'], isTrue);
      final episode = (await database.screenplayDao.getEpisode(
        initial.episodeId,
      ))!;
      expect(episode.episodeNumber, 2);
      final scene = await service.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
      );
      final arrayPath = 'scenes/$scene/elements';
      final array = await tools.executeTool(
        name: 'Write',
        input: {
          'path': arrayPath,
          'value': [
            {'type': 'action', 'text': '有效正文'},
          ],
        },
      );
      expect(array['ok'], isTrue);
      final rows = await database.screenplayDao.getElementRows(scene);
      final element = rows.single;
      final malformed = await tools.executeTool(
        name: 'Write',
        input: {
          'path': arrayPath,
          'value': [
            {
              'type': 'action',
              'text': {'invalid': 123},
            },
          ],
        },
      );
      expect(malformed['error_code'], 'invalid_argument');
      expect(
        (await database.screenplayDao.getElementRows(scene)).single.textContent,
        '有效正文',
      );
      final single = await tools.executeTool(
        name: 'Write',
        input: {'path': '$arrayPath/${element.id}/text', 'value': '修改后的正文'},
      );
      expect(single['ok'], isTrue);
      final readonly = await tools.executeTool(
        name: 'Write',
        input: {
          'path': '$arrayPath/${element.id}',
          'fields': {'id': 'other'},
        },
      );
      expect(readonly['ok'], isTrue, reason: '$readonly');
      expect(readonly['updated'], isFalse);
      expect(readonly['ignored_fields'], ['id']);
      expect(
        (await database.screenplayDao.getElementRows(scene)).single.id,
        element.id,
      );
    },
  );

  test(
    'search surfaces listing and text read failures and Replace counts application reads',
    () async {
      final fixture = await searchFixture();
      final sceneId = fixture.scenes.first;
      // 具体落在哪个 element 取决于扫描顺序与随机 id，只约束它属于注入失败的场次。
      final elementPath = startsWith('scenes/$sceneId/elements/');
      final tools = manager();
      addTearDown(tools.dispose);
      for (final failurePath in ['scenes', 'elements']) {
        database.screenplayDao.beforeSceneListing = failurePath == 'scenes'
            ? (_) => throw StateError('injected read failure')
            : null;
        database.screenplayDao.beforeElementRead = failurePath == 'elements'
            ? (scene, count) async {
                if (scene == sceneId && count == 2) {
                  throw StateError('injected read failure');
                }
              }
            : null;
        for (final tool in [
          'Grep',
          'Replace',
          if (failurePath == 'scenes') 'Glob',
        ]) {
          database.screenplayDao.elementReadCounts.clear();
          final result = await tools.executeTool(
            name: tool,
            input: {
              'path': '/',
              'pattern': tool == 'Glob' ? '**' : '线索',
              if (tool == 'Replace') 'replacement': '新词',
            },
          );
          expect(result['error_code'], 'internal', reason: '$result');
          expect(
            result['path'],
            failurePath == 'scenes' ? 'scenes' : elementPath,
          );
          expect(result['error'], isNot(contains('injected')));
        }
        expect(await overlay.getWorkingChanges(), isEmpty);
        database.screenplayDao.elementReadCounts.clear();
        final result = await tools.executeTool(
          name: 'Replace',
          input: {
            'path': '/',
            'pattern': '线索',
            'replacement': '新词',
            'dry_run': false,
          },
        );
        if (failurePath == 'scenes') {
          expect(result['error_code'], 'internal');
          expect(await overlay.getWorkingChanges(), isEmpty);
        } else {
          expect(result['applied_fields'], 23, reason: '$result');
          final failed = (result['failed'] as Map)['internal'] as Map;
          expect(failed['count'], 1);
          expect(failed['sample_paths'], [elementPath]);
        }
      }
    },
  );

  test(
    'screenplay search exposes budgets while Replace reaches the last target beyond them',
    () async {
      final service = ScreenplayService(database);
      final initial = await service.createInitialStructure();
      final root = (await database.screenplayDao.getRoot())!;
      final scenes = <String>[];
      for (var i = 0; i < 51; i++) {
        final scene = await service.createScene(
          screenplayId: root.id,
          episodeId: initial.episodeId,
        );
        scenes.add(scene);
        await service.writeElements(
          sceneId: scene,
          elements: [
            for (var j = 0; j < 50; j++)
              const ScreenplayElement(
                type: ScreenplayElementType.action,
                text: '线索',
              ),
          ],
        );
      }
      scenes.sort();
      final lastRows = await database.screenplayDao.getElementRows(scenes.last);
      final lastIds = lastRows.map((row) => row.id).toList()..sort();
      await service.writeElements(
        sceneId: scenes.last,
        elements: [
          for (final row in lastRows)
            ScreenplayElement(
              id: row.id,
              type: ScreenplayElementType.action,
              text: row.id == lastIds.last ? '最后线索' : row.textContent,
            ),
        ],
      );
      final tools = manager();
      final glob = await tools.executeTool(
        name: 'Glob',
        input: {'path': 'scenes', 'pattern': '**'},
      );
      expect(glob['matches'], hasLength(200));
      expect(glob['scan_truncated'], isTrue);
      final grep = await tools.executeTool(
        name: 'Grep',
        input: {'glob': '**/text', 'pattern': 'not present'},
      );
      expect(grep['searched_files'], 1000);
      expect(grep['search_truncated'], isTrue);
      final preview = await tools.executeTool(
        name: 'Replace',
        input: {'path': 'scenes', 'pattern': '线索', 'replacement': '新词'},
      );
      expect(preview['matched_fields'], 2550, reason: '$preview');
      expect(preview['total_matches'], 2550);
      expect(await overlay.getWorkingChanges(), isEmpty);
      final applied = await tools.executeTool(
        name: 'Replace',
        input: {
          'path': 'scenes',
          'pattern': '最后线索',
          'replacement': '最后新词',
          'dry_run': false,
        },
      );
      expect(applied['applied_fields'], 1);
      expect(applied['total_replacements'], 1);
      final last = await tools.executeTool(
        name: 'Read',
        input: {'path': 'scenes/${scenes.last}/elements/${lastIds.last}/text'},
      );
      expect(last['value'], '最后新词');
    },
  );

  test(
    'Replace reports an element removed after discovery without dropping other writes',
    () async {
      final fixture = await searchFixture();
      final targets =
          fixture.texts.keys
              .where((path) => path.contains('/elements/'))
              .toList()
            ..sort();
      final removed = targets.last;
      final parsed = parseAiToolPath(removed);
      final scene = removed.split('/')[1];
      var removedAfterDiscovery = false;
      final firstScene = parseAiToolPath(targets.first).locator('scene_id')!;
      database.screenplayDao.beforeElementRead = (sceneId, count) async {
        if (sceneId == firstScene && count == 2 && !removedAfterDiscovery) {
          removedAfterDiscovery = true;
          await ScreenplayService(
            database,
          ).deleteElement(sceneId: scene, elementId: parsed.id!);
        }
      };
      database.screenplayDao.elementReadCounts.clear();
      final tools = manager();
      addTearDown(tools.dispose);
      final result = await tools.executeTool(
        name: 'Replace',
        input: {
          'path': '/',
          'pattern': '线索',
          'replacement': '新词',
          'dry_run': false,
        },
      );
      expect(removedAfterDiscovery, isTrue);
      expect(result['applied_fields'], 23, reason: '$result');
      expect((result['failed'] as Map)['not_found'], {
        'count': 1,
        'sample_paths': [removed],
      });
      expect(
        (await database.screenplayDao.getElementRows(
          scene,
        )).any((row) => row.id == parsed.id),
        isFalse,
      );
    },
  );

  test(
    'tool definitions stay static across work kinds and current absolute search equals relative search',
    () async {
      final fixture = await searchFixture();
      final novel = manager(kind: contentKindNovel).buildToolDefs();
      final tools = manager(
        crossWorkAccess: _ScreenplayCrossWorkAccess(contentService),
      );
      addTearDown(tools.dispose);
      final screenplay = tools.buildToolDefs();
      expect(
        screenplay.map((tool) => (tool.name, tool.description)),
        novel.map((tool) => (tool.name, tool.description)),
      );
      for (var i = 0; i < screenplay.length; i++) {
        expect(screenplay[i].inputSchema, novel[i].inputSchema);
      }
      final scope = 'scenes?episode_id=${fixture.episodes[1]}';
      for (final tool in ['Glob', 'Grep', 'Replace']) {
        final input = {
          'pattern': tool == 'Glob' ? '**' : '线索',
          if (tool == 'Replace') 'replacement': '新词',
        };
        final local = await tools.executeTool(
          name: tool,
          input: {...input, 'path': scope},
        );
        final absolute = await tools.executeTool(
          name: tool,
          input: {...input, 'path': '/works/current/$scope'},
        );
        expect(absolute, {
          ...local,
          'work_id': 'current',
          if (tool == 'Glob')
            'matches': [
              for (final path in local['matches'] as List)
                '/works/current/$path',
            ],
          if (tool == 'Grep')
            'text': (local['text'] as String).replaceAllMapped(
              RegExp(r'^(?=scenes/)', multiLine: true),
              (match) => '/works/current/',
            ),
        }, reason: tool);
      }
    },
  );

  test(
    'foreshadowing positions stage as working changes and roll back on their own',
    () async {
      final fixture = await searchFixture();
      final tools = manager();
      final created = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'foreshadowing',
          'fields': {
            'title': '共享伏笔',
            'setup': '原文',
            'setup_scene_id': fixture.scenes.first,
          },
        },
      );
      final id = created['id'] as String;
      final result = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'foreshadowing/$id',
          'fields': {'setup': '新文', 'payoff_scene_id': fixture.scenes.last},
        },
      );
      expect(result['updated'], isTrue, reason: '$result');
      final changes = await database.workingChangeDao.getAll();
      final positionChange = changes.singleWhere(
        (row) => row.field == 'payoff_scene_id',
      );
      expect(positionChange.oldText, isEmpty);
      expect(positionChange.newText, fixture.scenes.last);
      final textChange = changes.singleWhere((row) => row.field == 'setup');
      await overlay.rollbackChange(textChange.id);
      final entry = (await contentService.getForeshadowingById(id))!;
      expect(entry.setup, '原文');
      expect(entry.setupSceneId, fixture.scenes.first);
      expect(entry.payoffSceneId, fixture.scenes.last);
      final cleared = await tools.executeTool(
        name: 'Write',
        input: {'path': 'foreshadowing/$id/setup_scene_id', 'value': null},
      );
      expect(cleared['updated'], isTrue, reason: '$cleared');
      expect(
        (await contentService.getForeshadowingById(id))!.setupSceneId,
        isNull,
      );
      await ScreenplayService(database).deleteScene(fixture.scenes.last);
      final textOnly = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'foreshadowing/$id',
          'fields': {'setup': '继续编辑'},
        },
      );
      expect(textOnly['updated'], isTrue);
      expect(
        (await contentService.getForeshadowingById(id))!.payoffSceneId,
        fixture.scenes.last,
      );
      await overlay.rollbackChange(positionChange.id);
      expect(
        (await contentService.getForeshadowingById(id))!.payoffSceneId,
        isNull,
      );
    },
  );

  test(
    'foreshadowing rejects invalid positions and rolls mixed writes back after stage failure',
    () async {
      final fixture = await searchFixture();
      final tools = manager();
      final id = await contentService.createForeshadowing(
        title: '伏笔',
        setup: '原文',
      );
      for (final fields in [
        {'setup_scene_id': 'missing'},
        {'setup_chapter_id': 'chapter_other'},
        {
          'setup_scene_id': fixture.scenes.first,
          'setup_chapter_id': 'chapter_other',
        },
      ]) {
        final result = await tools.executeTool(
          name: 'Write',
          input: {
            'path': 'foreshadowing/$id',
            'fields': {...fields, 'setup': '不应写入'},
          },
        );
        expect(result['error_code'], 'invalid_argument', reason: '$result');
        expect((await contentService.getForeshadowingById(id))!.setup, '原文');
      }
      await database.customStatement(
        "CREATE TRIGGER fail_stage BEFORE INSERT ON working_changes BEGIN SELECT RAISE(ABORT, 'stage failed'); END",
      );
      await expectLater(
        tools.executeTool(
          name: 'Write',
          input: {
            'path': 'foreshadowing/$id',
            'fields': {'setup_scene_id': fixture.scenes.first, 'setup': '不应写入'},
          },
        ),
        throwsA(anything),
      );
      final unchanged = (await contentService.getForeshadowingById(id))!;
      expect(unchanged.setupSceneId, isNull);
      expect(unchanged.setup, '原文');
    },
  );

  test(
    'novel foreshadowing accepts chapters, rejects volumes and scenes',
    () async {
      final chapter = await contentService.createChapter(
        siblingOrder: 0,
        title: '正文',
      );
      final volume = await contentService.createVolume(title: '卷');
      final id = await contentService.createForeshadowing(
        title: '小说伏笔',
        setupChapterId: chapter,
      );
      expect(
        (await contentService.getForeshadowingById(id))!.setupChapterId,
        chapter,
      );
      await expectLater(
        contentService.updateForeshadowingPositions(
          entryId: id,
          fields: {'setup_chapter_id': volume},
        ),
        throwsFormatException,
      );
      await expectLater(
        contentService.updateForeshadowingPositions(
          entryId: id,
          fields: {'payoff_scene_id': 'scene_other'},
        ),
        throwsFormatException,
      );
      await contentService.updateForeshadowingPositions(
        entryId: id,
        fields: {'setup_chapter_id': null},
      );
      expect(
        (await contentService.getForeshadowingById(id))!.setupChapterId,
        isNull,
      );
    },
  );

  test(
    'element operations retain the addressed scene and element identity',
    () async {
      final service = ScreenplayService(database);
      final initial = await service.createInitialStructure();
      final root = (await database.screenplayDao.getRoot())!;
      final scenes = <String>[];
      for (var i = 0; i < 2; i++) {
        scenes.add(
          await service.createScene(
            screenplayId: root.id,
            episodeId: initial.episodeId,
          ),
        );
      }
      final tools = manager(episodeId: initial.episodeId);
      addTearDown(tools.dispose);
      final created = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'scenes/${scenes.first}/elements',
          'fields': {'type': ' ACTION ', 'text': '  /first\n/second  '},
        },
      );
      expect(created['ok'], isTrue, reason: '$created');
      final id = created['id'] as String;
      final path = 'scenes/${scenes.first}/elements/$id';
      expect(created['path'], path);
      expect(created['entries'], hasLength(1));
      final written = await tools.executeTool(
        name: 'Write',
        input: {
          'path': path,
          'fields': {'text': '  /original\n/body  '},
        },
      );
      expect(written['ok'], isTrue, reason: '$written');
      final edited = await tools.executeTool(
        name: 'Edit',
        input: {
          'path': '$path/text',
          'old_text': '/original',
          'new_text': '/edited',
        },
      );
      expect(edited['ok'], isTrue, reason: '$edited');
      final read = await tools.executeTool(
        name: 'Read',
        input: {'path': '$path/text'},
      );
      expect(read['value'], '/edited\n/body');
      expect(
        (await database.screenplayDao.getElementRows(scenes.first)).single.id,
        id,
      );
      expect(await database.screenplayDao.getElementRows(scenes.last), isEmpty);
      final before = (await database.select(database.workingChanges).get())
          .map((row) => row.toJson())
          .toList();
      for (final operation in <(String, Map<String, dynamic>)>[
        ('Read', {}),
        (
          'Write',
          {
            'fields': {'text': 'wrong'},
          },
        ),
        ('Edit', {'old_text': '/edited', 'new_text': 'wrong'}),
        ('Remove', {}),
      ]) {
        final wrongPath =
            'scenes/${scenes.last}/elements/$id${operation.$1 == 'Edit' ? '/text' : ''}';
        final result = await tools.executeTool(
          name: operation.$1,
          input: {'path': wrongPath, ...operation.$2},
        );
        expect(result['error_code'], 'not_found', reason: '$result');
      }
      expect(
        (await database.select(database.workingChanges).get())
            .map((row) => row.toJson())
            .toList(),
        before,
      );
      final removed = await tools.executeTool(
        name: 'Remove',
        input: {'path': path},
      );
      expect(removed['ok'], isTrue, reason: '$removed');
      expect(
        await database.screenplayDao.getElementRows(scenes.first),
        isEmpty,
      );
    },
  );

  for (final concurrentEdit in ['none', 'prepend', 'clear']) {
    test(
      'element Create after an anchor returns its saved identity: $concurrentEdit',
      () async {
        final service = ScreenplayService(database);
        final initial = await service.createInitialStructure();
        final root = (await database.screenplayDao.getRoot())!;
        final sceneId = await service.createScene(
          screenplayId: root.id,
          episodeId: initial.episodeId,
        );
        final initialElements = await service.writeElements(
          sceneId: sceneId,
          elements: const [
            ScreenplayElement(type: ScreenplayElementType.action, text: 'A'),
            ScreenplayElement(type: ScreenplayElementType.action, text: 'B'),
          ],
        );
        final anchorId = initialElements.elements.first.id!;
        String? savedId;
        var concurrentWriteCompleted = false;
        if (concurrentEdit != 'none') {
          database.afterOuterTransaction = () async {
            // Simulate a different editor immediately after the first committed
            // transaction, before the Create caller resumes its next await.
            database.afterOuterTransaction = null;
            final saved = await database.screenplayDao.getElementRows(sceneId);
            savedId = saved.singleWhere((row) => row.textContent == 'C').id;
            await service.writeElements(
              sceneId: sceneId,
              elements: [
                if (concurrentEdit == 'prepend') ...[
                  const ScreenplayElement(
                    type: ScreenplayElementType.action,
                    text: 'X',
                  ),
                  for (final row in saved)
                    ScreenplayElement(
                      id: row.id,
                      type: ScreenplayElementType.action,
                      text: row.textContent,
                    ),
                ],
              ],
            );
            concurrentWriteCompleted = true;
          };
        }
        final tools = manager(episodeId: initial.episodeId);
        addTearDown(tools.dispose);
        final created = await tools.executeTool(
          name: 'Create',
          input: {
            'path': 'scenes/$sceneId/elements',
            'fields': {
              'type': 'action',
              'text': 'C',
              'after_element_id': anchorId,
            },
          },
        );
        expect(created['ok'], isTrue, reason: '$created');
        if (concurrentEdit != 'none') {
          expect(concurrentWriteCompleted, isTrue);
          expect(created['id'], savedId);
        }
        final entries = created['entries'] as List;
        expect(entries.map((entry) => entry['text']), ['A', 'C', 'B']);
        expect(created['id'], entries[1]['id']);
        expect(created['id'], isNot(anchorId));
        expect(created['path'], 'scenes/$sceneId/elements/${created['id']}');
        final current = await database.screenplayDao.getElementRows(sceneId);
        expect(current.map((row) => row.textContent), switch (concurrentEdit) {
          'prepend' => ['X', 'A', 'C', 'B'],
          'clear' => <String>[],
          _ => ['A', 'C', 'B'],
        });
        final changes = await overlay.getWorkingChanges();
        expect(changes, hasLength(1));
        expect(changes.single.resourceId, sceneId);
      },
    );
  }

  test(
    'missing and deleted scene children never act as an empty collection',
    () async {
      final service = ScreenplayService(database);
      final initial = await service.createInitialStructure();
      final root = (await database.screenplayDao.getRoot())!;
      final scene = await service.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
      );
      final tools = manager(episodeId: initial.episodeId);
      addTearDown(tools.dispose);
      final empty = await tools.executeTool(
        name: 'Read',
        input: {'path': 'scenes/$scene/elements'},
      );
      expect(empty['entries'], isEmpty);
      await service.deleteScene(scene);
      for (final sceneId in ['missing', scene]) {
        final path = 'scenes/$sceneId/elements';
        for (final operation in <(String, Map<String, dynamic>)>[
          ('Read', {}),
          ('Write', {'value': []}),
          (
            'Create',
            {
              'fields': {'type': 'action', 'text': 'body'},
            },
          ),
        ]) {
          final result = await tools.executeTool(
            name: operation.$1,
            input: {'path': path, ...operation.$2},
          );
          expect(result['error'], isNotNull, reason: '$result');
          expect(result['ok'], isNot(true));
          expect(result['error_code'], 'not_found', reason: '$result');
          expect(result['type'], isNot('listing'));
        }
      }
      expect(await overlay.getWorkingChanges(), isEmpty);
    },
  );

  test(
    'current absolute season creation returns a readable episode reference',
    () async {
      await ScreenplayService(database).createInitialStructure();
      final tools = manager();
      addTearDown(tools.dispose);
      final created = await tools.executeTool(
        name: 'Create',
        input: {
          'path': '/works/current/seasons',
          'fields': {'title': 'chapters and scenes'},
        },
      );
      expect(created['work_id'], 'current');
      expect(
        created['episode_path'],
        '/works/current/episodes/${created['episode_id']}',
      );
      final episode = await tools.executeTool(
        name: 'Read',
        input: {'path': created['episode_path']},
      );
      expect(episode['id'], created['episode_id']);
      expect(episode['work_id'], 'current');
      expect(episode['season_id'], created['id']);
    },
  );

  test(
    'screenplay Write and Edit previews use normalized current absolute targets',
    () async {
      final fixture = await ScreenplayService(
        database,
      ).createInitialStructure();
      Map<String, dynamic>? preview;
      final tools = AiToolManager(
        contentService,
        workingOverlayService: overlay,
        contentKind: contentKindScreenplay,
        workId: 'current',
        sessionId: 'session_1',
        onToolStarted: (_, _, _, extra, _) => preview = extra,
      )..registerAllTools();
      addTearDown(tools.dispose);
      final path = '/works/current/episodes/${fixture.episodeId}/outline';
      final written = await tools.executeTool(
        name: 'Write',
        input: {'path': path, 'value': '  前文旧词后文  '},
      );
      expect(written['error'], isNull);
      expect(preview?['diffNewText'], '前文旧词后文');
      final edited = await tools.executeTool(
        name: 'Edit',
        input: {'path': path, 'old_text': '旧词', 'new_text': '新词'},
      );
      expect(edited['error'], isNull);
      expect(preview?['targetPath'], path);
      expect(preview?['diffOldText'], '前文旧词后文');
      expect(preview?['diffNewText'], '前文新词后文');
      final read = await tools.executeTool(name: 'Read', input: {'path': path});
      expect(read['value'], '前文新词后文');
    },
  );

  test(
    'cross-work season resolution and current absolute writes use separate databases',
    () async {
      final local = await ScreenplayService(database).createInitialStructure();
      final remoteDb = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(remoteDb.close);
      final remoteService = ScreenplayService(remoteDb);
      final remote = await remoteService.createInitialStructure();
      await remoteService.updateSeason(
        seasonId: remote.seasonId,
        title: 'remote season',
      );
      final tools = manager(
        seasonId: local.seasonId,
        episodeId: local.episodeId,
        crossWorkAccess: _ScreenplayCrossWorkAccess(
          NovelContentService(remoteDb),
        ),
      );
      addTearDown(tools.dispose);
      final listing = await tools.executeTool(
        name: 'Read',
        input: {'path': '/works/target/episodes'},
      );
      // 枚举的是目标库自己的季，本地选中季既不参与也不泄漏。
      expect(listing.containsKey('season_id'), isFalse);
      expect((listing['entries'] as List).single['id'], remote.episodeId);
      expect(
        (listing['entries'] as List).single['path'],
        '/works/target/episodes/${remote.episodeId}',
      );
      final invalid = await tools.executeTool(
        name: 'Read',
        input: {'path': '/works/target/episodes?season_id=${local.seasonId}'},
      );
      expect(invalid['error_code'], 'not_found');
      final updated = await tools.executeTool(
        name: 'Write',
        input: {
          'path': '/works/current/seasons/${local.seasonId}',
          'fields': {
            'title': '  local revised  ',
            'planned_episode_count': '2.6',
          },
        },
      );
      expect(updated['ok'], isTrue, reason: '$updated');
      final localRow = (await database.screenplayDao.getSeason(
        local.seasonId,
      ))!;
      expect(localRow.title, 'local revised');
      expect(localRow.plannedEpisodeCount, 3);
      expect(
        (await remoteDb.screenplayDao.getSeason(remote.seasonId))!.title,
        'remote season',
      );
      final denied = await tools.executeTool(
        name: 'Write',
        input: {
          'path': '/works/target/seasons/${remote.seasonId}',
          'fields': {'title': 'wrong'},
        },
      );
      expect(denied['error_code'], 'permission_denied');
      expect(
        (await remoteDb.screenplayDao.getSeason(remote.seasonId))!.title,
        'remote season',
      );
    },
  );

  test('screenplay Remove force only tolerates missing targets', () async {
    final service = ScreenplayService(database);
    final initial = await service.createInitialStructure();
    final root = (await database.screenplayDao.getRoot())!;
    final scene = await service.createScene(
      screenplayId: root.id,
      episodeId: initial.episodeId,
    );
    final character = await contentService.createCharacterProfile(name: '角色');
    await service.writeElements(
      sceneId: scene,
      elements: [
        ScreenplayElement(
          type: ScreenplayElementType.character,
          characterId: character,
        ),
        ScreenplayElement(type: ScreenplayElementType.dialogue, text: '台词'),
      ],
    );
    final elements = await database.screenplayDao.getElementRows(scene);
    final characterElement = elements.firstWhere((e) => e.type == 'character');
    final tools = manager();
    addTearDown(tools.dispose);
    for (final path in [
      'episodes/ep_missing',
      'scenes/sc_missing',
      'scenes/$scene/elements/el_missing',
    ]) {
      final strict = await tools.executeTool(
        name: 'Remove',
        input: {'path': path},
      );
      expect(strict['error'], isNotNull);
      final forced = await tools.executeTool(
        name: 'Remove',
        input: {'path': '/works/current/$path', 'force': true},
      );
      expect(forced['removed'], isTrue, reason: '$forced');
      expect(forced['missing'], isTrue);
      expect(forced['path'], '/works/current/$path');
    }
    final dependent = await tools.executeTool(
      name: 'Remove',
      input: {
        'path': 'scenes/$scene/elements/${characterElement.id}',
        'force': true,
      },
    );
    expect(dependent['error_code'], 'failed_precondition');
    final lastEpisode = await tools.executeTool(
      name: 'Remove',
      input: {'path': 'episodes/${initial.episodeId}', 'force': true},
    );
    expect(lastEpisode['error_code'], 'failed_precondition');
    expect(await database.screenplayDao.getElementRows(scene), elements);
    expect(
      await database.screenplayDao.getEpisode(initial.episodeId),
      isNotNull,
    );
    expect(await database.select(database.workingChanges).get(), isEmpty);
  });

  test(
    'screenplay text pagination preserves fields, newlines and work scope',
    () async {
      final remoteDb = NovelContentDatabase.forTest(NativeDatabase.memory());
      addTearDown(remoteDb.close);
      const body = '第一行\r\n第二行\r\n第三行\r\n第四行';
      final fixtures =
          <
            ({
              String prefix,
              String episode,
              String beat,
              String scene,
              String element,
            })
          >[];
      for (final db in [database, remoteDb]) {
        final service = ScreenplayService(db);
        final initial = await service.createInitialStructure();
        final root = (await db.screenplayDao.getRoot())!;
        await service.updateEpisodeOutline(
          episodeId: initial.episodeId,
          outline: body,
        );
        final beat = await service.createBeat(
          screenplayId: root.id,
          episodeId: initial.episodeId,
          actNumber: 1,
          description: body,
        );
        final scene = await service.createScene(
          screenplayId: root.id,
          episodeId: initial.episodeId,
          synopsis: body,
        );
        await service.writeElements(
          sceneId: scene,
          elements: [
            ScreenplayElement(type: ScreenplayElementType.action, text: body),
          ],
        );
        final element = (await db.screenplayDao.getElementRows(
          scene,
        )).firstWhere((e) => e.type == 'action').id;
        for (final prefix
            in identical(db, database)
                ? ['', '/works/current/']
                : ['/works/target/']) {
          fixtures.add((
            prefix: prefix,
            episode: initial.episodeId,
            beat: beat,
            scene: scene,
            element: element,
          ));
        }
      }
      final tools = manager(
        crossWorkAccess: _ScreenplayCrossWorkAccess(
          NovelContentService(remoteDb),
        ),
      );
      addTearDown(tools.dispose);
      for (final fixture in fixtures) {
        for (final path in [
          'episodes/${fixture.episode}/outline',
          'scenes/${fixture.scene}/synopsis',
          'scenes/${fixture.scene}/elements/${fixture.element}/text',
        ]) {
          final key = path.split('/').last;
          final result = await tools.executeTool(
            name: 'Read',
            input: {'path': '${fixture.prefix}$path', 'offset': 1, 'limit': 2},
          );
          expect(result['error'], isNull, reason: '$result');
          expect(result['value'], '第二行\r\n第三行');
          expect(result.containsKey(key), isFalse);
          expect(result['total_lines'], 4);
          expect(result['start_line'], 2);
          expect(result['end_line'], 3);
          expect(result['has_more'], isTrue);
          expect(result['next_offset'], 3);
          expect(result['path'], '${fixture.prefix}$path');
          final tail = await tools.executeTool(
            name: 'Read',
            input: {'path': '${fixture.prefix}$path?offset=3&limit=2'},
          );
          expect(tail['value'], '第四行');
          expect(tail['has_more'], isFalse);
        }
      }
    },
  );

  test('screenplay long text reads use default page limits', () async {
    final service = ScreenplayService(database);
    final initial = await service.createInitialStructure();
    final root = (await database.screenplayDao.getRoot())!;
    final body = List.generate(205, (i) => 'line $i').join('\r\n');
    final scene = await service.createScene(
      screenplayId: root.id,
      episodeId: initial.episodeId,
      synopsis: body,
    );
    await service.writeElements(
      sceneId: scene,
      elements: [
        ScreenplayElement(type: ScreenplayElementType.action, text: body),
      ],
    );
    final element = (await database.screenplayDao.getElementRows(
      scene,
    )).firstWhere((e) => e.type == 'action').id;
    final tools = manager();
    addTearDown(tools.dispose);
    for (final path in [
      'scenes/$scene/synopsis',
      'scenes/$scene/elements/$element/text',
    ]) {
      final result = await tools.executeTool(
        name: 'Read',
        input: {'path': path},
      );
      expect(result['limit'], 200);
      expect(result['total_lines'], 205);
      expect(result['next_offset'], 200);
      expect(
        result['value'],
        List.generate(200, (i) => 'line $i').join('\r\n'),
      );
    }
  });

  test('path prompt is filtered by workspace kind', () {
    final novel = pathSchema(kind: contentKindNovel);
    final screenplay = pathSchema(kind: contentKindScreenplay);

    expect(novel, contains('chapters/{chapter_id}'));
    expect(novel, isNot(contains('scenes/{scene_id}')));
    expect(screenplay, contains('scenes/{scene_id}'));
    expect(screenplay, isNot(contains('chapters/{chapter_id}')));
    expect(screenplay, contains('/works/{work_id}'));
  });
}

class _ScreenplayReadProbeDatabase extends NovelContentDatabase {
  _ScreenplayReadProbeDatabase() : super.forTest(NativeDatabase.memory());

  Future<void> Function()? afterOuterTransaction;
  int _transactionDepth = 0;

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    final outer = _transactionDepth++ == 0;
    late T result;
    try {
      result = await super.transaction(action, requireNew: requireNew);
    } finally {
      _transactionDepth--;
    }
    if (outer) {
      await afterOuterTransaction?.call();
    }
    return result;
  }

  late final _probeDao = _ScreenplayReadProbeDao(this);

  @override
  _ScreenplayReadProbeDao get screenplayDao => _probeDao;
}

class _ScreenplayReadProbeDao extends ScreenplayDao {
  _ScreenplayReadProbeDao(super.database);

  void Function(String episodeId)? beforeSceneListing;
  Future<void> Function(String sceneId, int count)? beforeElementRead;
  final elementReadCounts = <String, int>{};
  Future<void> Function(String id)? beforeBeatRead;

  @override
  Future<ScreenplayBeatRow?> getBeat(String id) async {
    await beforeBeatRead?.call(id);
    return super.getBeat(id);
  }

  @override
  Stream<List<ScreenplaySceneSummary>> watchScenes(String episodeId) {
    beforeSceneListing?.call(episodeId);
    return super.watchScenes(episodeId);
  }

  @override
  Future<List<ScreenplaySceneElementRow>> getElementRows(String sceneId) async {
    final count = elementReadCounts.update(
      sceneId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    await beforeElementRead?.call(sceneId, count);
    return super.getElementRows(sceneId);
  }
}

class _ScreenplayCrossWorkAccess implements CrossWorkAccess {
  _ScreenplayCrossWorkAccess(this.service);

  final NovelContentService service;
  int releaseCount = 0;

  @override
  String get currentWorkId => 'current';

  @override
  Future<CrossWorkLease> acquire(String workId) async {
    return CrossWorkLease(
      work: CrossWorkDescriptor(
        workId: workId,
        title: '目标剧本',
        databasePath: 'memory',
        contentKind: contentKindScreenplay,
        novelMetadata: const {
          'title': '目标剧本',
          'content_kind': contentKindScreenplay,
        },
      ),
      service: service,
      release: () => releaseCount += 1,
    );
  }

  @override
  Future<List<CrossWorkDescriptor>> listWorks() async => const [];
}
