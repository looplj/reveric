// 职责: 验证 AI 工具完整读写 M1 人物档案字段并保持结构化数据。
// 关联文件:
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/ai/tools_create.dart
//   lib/shared/services/ai/tools_write.dart
//   lib/shared/services/ai/tools_edit.dart
//   lib/shared/services/working_overlay.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:convert';
import 'package:drift/native.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

import '../../../helpers/resource_contract.dart';

void main() {
  late NovelContentDatabase database;
  late AppDatabase appDatabase;
  late NovelContentService contentService;
  late WorkingOverlayService overlay;
  late AiToolManager toolManager;

  setUp(() async {
    database = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDatabase = AppDatabase.forTest(NativeDatabase.memory());
    for (final id in [
      'images/a.png',
      'images/b.png',
      'images/c.png',
      'images/portrait.png',
    ]) {
      await appDatabase.assetDao.insertAsset(
        AssetsCompanion.insert(
          id: id,
          type: 'image',
          purpose: 'upload',
          path: Value(id),
          content: const Value(ImageAssetContent(mimeType: 'image/png')),
        ),
      );
    }
    contentService = NovelContentService(
      database,
      imageLibraryService: buildImageLibraryService(appDatabase),
    );
    overlay = WorkingOverlayService(
      database,
      contentService,
      novelActionsService: NovelActionsService(appDatabase),
    );
    toolManager = AiToolManager(contentService, workingOverlayService: overlay)
      ..registerAllTools();
  });

  tearDown(() async {
    await database.close();
    await appDatabase.close();
  });

  test(
    'Read photos returns named JSON objects for both detail and field paths',
    () async {
      final id = await contentService.createCharacterProfile(name: 'Subject');
      await contentService.updateCharacterAvatarAndPhotos(
        entryId: id,
        photos: const [
          SubjectPhoto(assetId: 'images/portrait.png', name: '正面'),
        ],
      );
      final detail = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'characters/$id'},
      );
      final field = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'characters/$id/photos'},
      );
      final expected = [
        {'asset_id': 'images/portrait.png', 'name': '正面'},
      ];
      expect(detail['photos'], expected);
      expect(field['value'], expected);
    },
  );

  test('schema exposes photos for both resource and field Write', () async {
    final schema = resourceContractTreeForTesting('/_schema/characters');
    final operations = (schema['operation_contracts'] as List).cast<Map>();
    final resource = operations.singleWhere(
      (op) => op['tool'] == 'Write' && op['target'] == 'resource',
    );
    final photoSchema = resource['input']['properties']['photos'];
    expect(photoSchema['type'], 'array');
    expect(photoSchema['items']['required'], containsAll(['asset_id', 'name']));
    expect(
      operations.where(
        (op) => op['tool'] == 'Write' && op['field'] == 'photos',
      ),
      hasLength(1),
    );
  });

  for (final fieldPath in [true, false]) {
    test(
      'Write ${fieldPath ? 'field' : 'resource'} replaces named photos and can be rejected',
      () async {
        final id = await contentService.createCharacterProfile(name: 'Subject');
        const before = [
          SubjectPhoto(assetId: 'images/a.png', name: '原图'),
          SubjectPhoto(assetId: 'images/b.png', name: '冬装'),
        ];
        await contentService.updateCharacterAvatarAndPhotos(
          entryId: id,
          photos: before,
        );
        final photos = [
          {'asset_id': 'images/b.png', 'name': ' 正面 '},
          {'name': '', 'asset_id': 'images/a.png'},
          {'asset_id': 'images/c.png', 'name': '正面'},
        ];
        final result = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': fieldPath ? 'characters/$id/photos' : 'characters/$id',
            if (fieldPath) 'value': photos else 'fields': {'photos': photos},
          },
        );
        expect(result['updated'], isTrue, reason: '$result');
        expect(
          (await contentService.getCharacterProfileById(id))!.photos,
          const [
            SubjectPhoto(assetId: 'images/b.png', name: '正面'),
            SubjectPhoto(assetId: 'images/a.png'),
            SubjectPhoto(assetId: 'images/c.png', name: '正面'),
          ],
        );
        final changes = await database.workingChangeDao.getByResource(
          'characters/$id/photos',
        );
        final active = changes.singleWhere(
          (change) => change.status == workingChangeStatusActive,
        );
        expect(
          jsonDecode(active.oldText!),
          before.map((photo) => photo.toJson()).toList(),
        );
        expect(
          (await overlay.resolveFieldReviews([
            active,
          ])).single.isStructuredField,
          isTrue,
        );
        expect(
          await overlay.rejectWorkingChange(active.id),
          RollbackChangeResult.rolledBack,
        );
        expect(
          (await contentService.getCharacterProfileById(id))!.photos,
          before,
        );

        final clear = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': fieldPath ? 'characters/$id/photos' : 'characters/$id',
            if (fieldPath) 'value': [] else 'fields': {'photos': []},
          },
        );
        expect(clear['updated'], isTrue);
        expect(
          (await contentService.getCharacterProfileById(id))!.photos,
          isEmpty,
        );
        final cleared = (await database.workingChangeDao.getByResource(
          'characters/$id/photos',
        )).singleWhere((change) => change.status == workingChangeStatusActive);
        await overlay.commitWorkingChanges(
          [cleared.id],
          source: workingChangeSourceAi,
          message: 'Clear photos',
        );
        final review = (await overlay.resolveFieldReviews([
          (await overlay.getWorkingChangeById(cleared.id))!,
        ])).single;
        final rollback = await overlay.rollbackFields([review]);
        expect(rollback.skipped, 0);
        expect(
          (await contentService.getCharacterProfileById(id))!.photos,
          before,
        );
      },
    );
  }

  for (final invalid in <Object>[
    ['images/legacy.png'],
    [
      {'asset_id': 'images/a.png'},
    ],
    [
      {'name': 'missing path'},
    ],
    [
      {'path': ' ', 'name': ''},
    ],
    [
      {'asset_id': 'images/a.png', 'name': []},
    ],
  ]) {
    test(
      'invalid photos reject the entire multi-field Write: $invalid',
      () async {
        final id = await contentService.createCharacterProfile(
          name: 'Original',
        );
        final result = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': 'characters/$id',
            'fields': {'name': 'Changed', 'photos': invalid},
          },
        );
        expect(result['error_code'], 'invalid_argument', reason: '$result');
        final row = (await contentService.getCharacterProfileById(id))!;
        expect(row.name, 'Original');
        expect(row.photos, isNull);
        expect(await database.select(database.workingChanges).get(), isEmpty);
      },
    );
  }

  test('Create and Read preserve the layered character profile', () async {
    final created = await toolManager.executeTool(
      name: 'Create',
      input: {
        'path': 'characters',
        'fields': {
          'name': '陈峰',
          'aliases': ['陈先生', '峰哥'],
          'tags': ['云岚宗', '内门弟子'],
          'biography': '曾任松江府画师。',
          'appearance': '身形修长，黑发束冠。',
          'personality': '谨慎、自尊心强。',
          'description': '左眉有浅疤，说话很慢。',
          'behavior_tags': [
            {'tag': '嘴硬护短', 'context': '亲近者受伤时'},
          ],
          'current_state': '右臂受伤，滞留松江府。',
        },
      },
    );

    expect(created['created'], isTrue);
    final id = created['id'] as String;
    final read = await toolManager.executeTool(
      name: 'Read',
      input: {'path': 'characters/$id'},
    );
    expect(read['aliases'], ['陈先生', '峰哥']);
    expect(read['tags'], ['云岚宗', '内门弟子']);
    expect(read['personality'], '谨慎、自尊心强。');
    expect(read['appearance'], '身形修长，黑发束冠。');
    expect(read['description'], '左眉有浅疤，说话很慢。');
    expect(read['behavior_tags'], [
      {'tag': '嘴硬护短', 'context': '亲近者受伤时'},
    ]);
    expect(read['current_state'], '右臂受伤，滞留松江府。');

    final byAlias = await toolManager.executeTool(
      name: 'Read',
      input: {'path': 'characters?search=峰哥'},
    );
    expect(byAlias['entries'], hasLength(1));
    expect(byAlias['entries'].single['id'], id);

    final byTag = await toolManager.executeTool(
      name: 'Read',
      input: {'path': 'characters?search=云岚宗'},
    );
    expect(byTag['entries'], hasLength(1));
    expect(byTag['entries'].single['id'], id);
  });

  test('Write stages and applies structured and dynamic fields', () async {
    final id = await contentService.createCharacterProfile(name: '陈峰');

    final result = await toolManager.executeTool(
      name: 'Write',
      input: {
        'path': 'characters/$id',
        'fields': {
          'aliases': ['陈先生'],
          'appearance': '身形清瘦，常戴斗笠。',
          'personality': '谨慎，但愿意承担风险。',
          'behavior_tags': [
            {'tag': '遇强则静', 'context': '对手明显更强时'},
          ],
          'current_state': '伤势恢复，准备离开松江府。',
        },
      },
    );

    expect(result['updated'], isTrue);
    expect(result['fields'], [
      'aliases',
      'appearance',
      'personality',
      'behavior_tags',
      'current_state',
    ]);
    final character = await contentService.getCharacterProfileById(id);
    expect(character!.aliases, ['陈先生']);
    expect(character.appearance, '身形清瘦，常戴斗笠。');
    expect(character.personality, '谨慎，但愿意承担风险。');
    expect(character.behaviorTags.single.tag, '遇强则静');
    expect(character.currentState, '伤势恢复，准备离开松江府。');
  });

  test('Write rejects behavior tags without context', () async {
    final id = await contentService.createCharacterProfile(name: '陈峰');

    final result = await toolManager.executeTool(
      name: 'Write',
      input: {
        'path': 'characters/$id/behavior_tags',
        'value': [
          {'tag': '嘴硬护短'},
        ],
      },
    );

    expect(result['ok'], isFalse);
    expect(result['error_code'], 'invalid_argument');
    final character = await contentService.getCharacterProfileById(id);
    expect(character!.behaviorTags, isEmpty);
  });

  test('Write updates management tags without a working change', () async {
    final id = await contentService.createCharacterProfile(name: '陈峰');

    final result = await toolManager.executeTool(
      name: 'Write',
      input: {
        'path': 'characters/$id/tags',
        'value': [' 云岚宗 ', '内门弟子', '云岚宗'],
      },
    );

    expect(result['updated'], isTrue);
    expect((await contentService.getCharacterProfileById(id))!.tags, [
      '云岚宗',
      '内门弟子',
    ]);
    expect(
      await database.workingChangeDao.getByResource('characters/$id/tags'),
      isEmpty,
    );
  });

  test('reject restores a structured aliases patch', () async {
    final id = await contentService.createCharacterProfile(
      name: '陈峰',
      aliases: const ['陈先生'],
    );

    final result = await toolManager.executeTool(
      name: 'Write',
      input: {
        'path': 'characters/$id/aliases',
        'value': ['峰哥'],
      },
    );

    expect(result['updated'], isTrue);
    expect((await contentService.getCharacterProfileById(id))!.aliases, ['峰哥']);
    final changes = await database.workingChangeDao.getByResource(
      'characters/$id/aliases',
    );
    final active = changes.singleWhere(
      (change) => change.status == workingChangeStatusActive,
    );
    await overlay.rejectWorkingChange(active.id);

    expect((await contentService.getCharacterProfileById(id))!.aliases, [
      '陈先生',
    ]);
  });

  for (final fieldPath in [true, false]) {
    test(
      'Write ${fieldPath ? 'field' : 'resource'} clears tags without a working change',
      () async {
        final id = await contentService.createCharacterProfile(
          name: '陈峰',
          tags: const ['云岚宗', '内门弟子'],
          description: '仍在宗门修行。',
        );

        final result = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': fieldPath ? 'characters/$id/tags' : 'characters/$id',
            if (fieldPath)
              'value': <String>[]
            else
              'fields': {'tags': <String>[]},
          },
        );

        expect(result['updated'], isTrue);
        final character = await contentService.getCharacterProfileById(id);
        expect(character!.tags, isEmpty);
        expect(character.description, '仍在宗门修行。');
        expect(await database.select(database.workingChanges).get(), isEmpty);
      },
    );
  }

  test('reject restores the exact character text before Edit', () async {
    const original = '说话很慢。\n  习惯先观察，再行动。  \n仍在观察。';
    final id = await contentService.createCharacterProfile(
      name: '陈峰',
      description: original,
    );
    final path = 'characters/$id/description';

    final result = await toolManager.executeTool(
      name: 'Edit',
      input: {
        'path': path,
        'old_text': '  习惯先观察，再行动。  ',
        'new_text': '  先救人，再问缘由。  ',
      },
    );

    expect(result['edited'], isTrue);
    expect(result['match_count'], 1);
    final read = await toolManager.executeTool(
      name: 'Read',
      input: {'path': path},
    );
    expect(read['value'], '说话很慢。\n  先救人，再问缘由。  \n仍在观察。');
    final changes = await database.workingChangeDao.getByResource(path);
    final active = changes.singleWhere(
      (change) => change.status == workingChangeStatusActive,
    );
    await overlay.rejectWorkingChange(active.id);

    expect(
      (await contentService.getCharacterProfileById(id))!.description,
      original,
    );
  });

  for (final targetKind in ['volume', 'soft-deleted chapter']) {
    test('Write rejects a $targetKind as first appearance', () async {
      final originalChapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '初见',
      );
      final targetId = targetKind == 'volume'
          ? await contentService.createVolume(title: '第一卷')
          : await contentService.createChapter(siblingOrder: 2, title: '已删除章节');
      if (targetKind == 'soft-deleted chapter') {
        await database.chapterDao.softDelete(targetId);
        expect(await contentService.getChapterById(targetId), isNull);
      }
      final id = await contentService.createCharacterProfile(
        name: '陈峰',
        firstAppearChapterId: originalChapterId,
      );

      final result = await toolManager.executeTool(
        name: 'Write',
        input: {
          'path': 'characters/$id/first_appear_chapter_id',
          'value': targetId,
        },
      );

      expect(result['ok'], isFalse);
      expect(result['error_code'], 'invalid_argument');
      expect(
        (await contentService.getCharacterProfileById(
          id,
        ))!.firstAppearChapterId,
        originalChapterId,
      );
      expect(await database.select(database.workingChanges).get(), isEmpty);
    });
  }

  test('Write rejects an unknown first appearance chapter', () async {
    final id = await contentService.createCharacterProfile(name: '陈峰');

    final result = await toolManager.executeTool(
      name: 'Write',
      input: {
        'path': 'characters/$id/first_appear_chapter_id',
        'value': 'missing-chapter',
      },
    );

    expect(result['ok'], isFalse);
    expect(result['error_code'], 'invalid_argument');
    expect(
      (await contentService.getCharacterProfileById(id))!.firstAppearChapterId,
      isNull,
    );
  });
}
