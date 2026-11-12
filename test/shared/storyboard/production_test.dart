// 职责: 验证分镜保存、Agent 引用校验、并发冲突、回退与文本导出。
// 关联文件:
//   lib/shared/services/storyboard/edit_orchestrator.dart
//   lib/shared/services/ai/tools.dart
import 'package:drift/native.dart';
import 'package:reveric/shared/models/novel.dart';
import 'package:reveric/shared/models/screenplay_element.dart';
import 'package:reveric/shared/services/screenplay_edit_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/storyboard/prompt.dart';
import 'package:reveric/shared/models/novel_workspace.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/storyboard/edit_orchestrator.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  late NovelContentDatabase db;
  late AppDatabase app;
  late StoryboardService service;
  late WorkingOverlayService overlay;
  late AiToolManager tools;
  late String sceneId;
  late String episodeId;
  final edits = StoryboardEditOrchestrator();
  setUp(() async {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    app = AppDatabase.forTest(NativeDatabase.memory());
    final screenplay = ScreenplayService(db);
    final initial = await screenplay.createInitialStructure();
    episodeId = initial.episodeId;
    sceneId = await screenplay.createScene(
      screenplayId: (await db.screenplayDao.getRoot())!.id,
      episodeId: episodeId,
      title: '夜雨',
    );
    final content = NovelContentService(
      db,
      novelActionsService: NovelActionsService(app),
    );
    overlay = WorkingOverlayService(
      db,
      content,
      novelActionsService: NovelActionsService(app),
    );
    service = StoryboardService(db);
    tools = AiToolManager(
      content,
      workingOverlayService: overlay,
      contentKind: 'screenplay',
      sessionId: 'test',
      workId: 'work',
    )..registerAllTools();
  });
  tearDown(() async {
    await db.close();
    await app.close();
  });

  Future<void> resetShelf() async {
    await app.customStatement(
      "UPDATE novels SET updated_at = CASE id WHEN 'work' THEN 100 ELSE 200 END",
    );
  }

  Future<void> seedShelf() async {
    await app.novelDao.create(
      id: 'work',
      title: 'Edited screenplay',
      description: '',
      contentKind: 'screenplay',
      contentDatabasePath: db.filePath,
    );
    await app.novelDao.create(
      id: 'other',
      title: 'Previous hero',
      description: '',
    );
    await resetShelf();
  }

  Future<void> expectEditedHero() async {
    final works = await app.novelDao.getAll();
    expect(
      works.shelfVisible.sortedForShelf(LibrarySortOrder.updated).first.id,
      'work',
    );
    expect(
      works.singleWhere((n) => n.id == 'other').updatedAt,
      DateTime.fromMillisecondsSinceEpoch(200000),
    );
  }

  test(
    'work activity: AI screenplay edits refresh hero and word count',
    () async {
      await seedShelf();
      final result = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'scenes/$sceneId/elements',
          'value': [
            {'type': 'action', 'text': '李默推开门。'},
          ],
        },
      );
      expect(result['ok'], isTrue, reason: '$result');
      expect(
        (await db.screenplayDao.getElementRows(
          sceneId,
        )).any((e) => e.textContent == '李默推开门。'),
        isTrue,
      );
      await expectEditedHero();
      expect((await app.novelDao.get('work'))!.wordCount, greaterThan(0));
    },
  );

  test('work activity: manual screenplay save refreshes hero', () async {
    await seedShelf();
    final screenplay = ScreenplayService(
      db,
      novelActionsService: NovelActionsService(app),
      novelId: 'work',
    );
    await screenplay.writeElements(
      sceneId: sceneId,
      elements: [
        const ScreenplayElement(
          type: ScreenplayElementType.action,
          text: '旧正文',
        ),
      ],
    );
    await resetShelf();
    final before = await screenplay.readDocument(episodeId);
    final target = before.withBodyEdits([
      for (final e in before.elements)
        e.isHeading ? e : e.copyWith(text: '作者写下新的一幕。'),
    ]);
    await ScreenplayEditOrchestrator().save(
      database: db,
      service: screenplay,
      overlay: overlay,
      baseline: before,
      target: target,
    );
    await expectEditedHero();
    expect((await app.novelDao.get('work'))!.wordCount, greaterThan(0));
  });

  test(
    'work activity: clip creation and AI/manual saves refresh hero',
    () async {
      await seedShelf();
      final shot = await edits.create(
        service: service,
        overlay: overlay,
        sceneId: sceneId,
        values: {'title': 'Initial'},
      );
      await expectEditedHero();
      await resetShelf();
      final result = await tools.executeTool(
        name: 'Write',
        input: {'path': 'clips/${shot.id}/prompt', 'value': '夜雨中的街道'},
      );
      expect(result['ok'], isTrue, reason: '$result');
      await expectEditedHero();
      await resetShelf();
      await edits.save(
        service: service,
        overlay: overlay,
        shotId: shot.id,
        values: {'title': 'Manual'},
      );
      await expectEditedHero();
      expect((await service.getShot(shot.id))!.title, 'Manual');
      expect((await app.novelDao.get('work'))!.wordCount, 0);
    },
  );

  test(
    'work activity: reading, unchanged and rejected clip saves keep hero',
    () async {
      final shot = await edits.create(
        service: service,
        overlay: overlay,
        sceneId: sceneId,
        values: {'title': 'Initial'},
      );
      await seedShelf();
      await tools.executeTool(
        name: 'Read',
        input: {'path': 'clips/${shot.id}'},
      );
      await edits.save(
        service: service,
        overlay: overlay,
        shotId: shot.id,
        values: {'title': 'Initial'},
      );
      await expectLater(
        edits.save(
          service: service,
          overlay: overlay,
          shotId: shot.id,
          values: {'prompt': '<ref input_id="missing" label="missing" />'},
          origin: const ShotEditOrigin.agent(sessionId: 'test', tool: 'Write'),
        ),
        throwsFormatException,
      );
      final works = await app.novelDao.getAll();
      expect(
        works.shelfVisible.sortedForShelf(LibrarySortOrder.updated).first.id,
        'other',
      );
      expect(
        (await app.novelDao.get('work'))!.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(100000),
      );
    },
  );

  test(
    'shot template continues the final interval and preserves references',
    () {
      const original =
          'Shot 2（近景·固定·1.5s）\n【0-1.5s】\n首帧：<ref input_id="c" label="片段" />';
      final result = StoryboardPrompt.appendShot(original);
      expect(result, startsWith(original));
      expect(result, contains('Shot 3'));
      expect(result, contains('【1.5-3.5s】'));
      expect(
        RegExp(r'^Shot', multiLine: true).allMatches(result),
        hasLength(2),
      );
      expect(StoryboardPrompt.parse(result).references.single.inputId, 'c');
    },
  );

  test(
    'defaults initialize new shots; saves update supplied fields without revision checks',
    () async {
      final first = await edits.create(
        service: service,
        overlay: overlay,
        sceneId: sceneId,
        values: {'title': 'A'},
      );
      await service.saveSettings({'ratio': '9:16', 'resolution': '1080p'});
      final second = await edits.create(
        service: service,
        overlay: overlay,
        sceneId: sceneId,
      );
      expect((await service.getShot(first.id))!.ratio, '16:9');
      expect(second.ratio, '9:16');
      expect(second.resolution, '1080p');
      await edits.save(
        service: service,
        overlay: overlay,
        shotId: first.id,
        values: {'title': 'B'},
      );
      await service.setErrorDismissed(first.id, true);
      expect((await service.getShot(first.id))!.errorDismissed, isTrue);
      await edits.save(
        service: service,
        overlay: overlay,
        shotId: first.id,
        values: {'title': 'C'},
      );
      expect((await service.getShot(first.id))!.title, 'C');
      expect((await service.getShot(first.id))!.errorDismissed, isTrue);
      expect((await service.episodeShots(episodeId)).length, 2);
    },
  );

  test(
    'prompt parser preserves mixed text, escaping and repeated references',
    () {
      final ref = StoryboardPrompt.reference('id&1', '雨中的"她"');
      final source = '参考 $ref，转身。$ref';
      final parsed = StoryboardPrompt.parse(source);
      expect(parsed.source, source);
      expect(parsed.references.first.inputId, 'id&1');
      expect(parsed.references.first.label, '雨中的"她"');
      expect(parsed.plainText, '参考 雨中的"她"，转身。雨中的"她"');
      for (final invalid in [
        '<ref label="A" />',
        '<ref input_id="a" label="A"></ref>',
        '<ref input_id="a" label="A"><ref /></ref>',
        '<ref input_id="a&b" label="A" />',
      ]) {
        expect(() => StoryboardPrompt.parse(invalid), throwsFormatException);
      }
      expect(
        () => StoryboardPrompt.parse(
          'only $ref',
        ).requireValidReferences(['id&1']),
        returnsNormally,
      );
    },
  );

  test(
    'clip references accept changed labels and counts but reject unknown inputs',
    () {
      final source = StoryboardPrompt.reference('clip&1', '片段"A"');
      final prompt = StoryboardPrompt.parse('$source followed by $source');
      expect(prompt.references.first.inputId, 'clip&1');
      expect(prompt.source, '$source followed by $source');
      expect(
        () => StoryboardPrompt.parse(
          '<ref input_id="a" clip_id="c" label="X" />',
        ),
        throwsFormatException,
      );
      expect(
        () => StoryboardPrompt.parse(source).requireValidReferences(['clip&1']),
        returnsNormally,
      );
      expect(
        () => StoryboardPrompt.parse(
          StoryboardPrompt.reference('different-input', '片段"A"'),
        ).requireValidReferences(['clip&1']),
        throwsFormatException,
      );
    },
  );

  test(
    'agent text changes can be rejected; damaged references roll back whole save',
    () async {
      const prompt = '看向 <ref input_id="a" label="角色" />。';
      final shot = await edits.create(
        service: service,
        overlay: overlay,
        sceneId: sceneId,
        values: {'prompt': prompt},
      );
      await expectLater(
        edits.save(
          service: service,
          overlay: overlay,
          shotId: shot.id,
          values: {'title': 'bad', 'prompt': '<ref input_id="a" />'},
          origin: const ShotEditOrigin.agent(sessionId: 'test', tool: 'Write'),
        ),
        throwsFormatException,
      );
      expect((await service.getShot(shot.id))!.title, '');
      await edits.save(
        service: service,
        overlay: overlay,
        shotId: shot.id,
        values: {'prompt': '慢慢看向角色。'},
        origin: const ShotEditOrigin.agent(sessionId: 'test', tool: 'Write'),
      );
      final change = (await overlay.getWorkingChanges()).singleWhere(
        (c) => c.status == workingChangeStatusActive,
      );
      await overlay.rejectWorkingChange(change.id);
      expect((await service.getShot(shot.id))!.prompt, prompt);
    },
  );

  test(
    'manual save takes over AI changes; copies get new identity and independent feedback',
    () async {
      final shot = await edits.create(
        service: service,
        overlay: overlay,
        sceneId: sceneId,
      );
      final ai = await edits.save(
        service: service,
        overlay: overlay,
        shotId: shot.id,
        values: {'title': 'AI'},
        origin: const ShotEditOrigin.agent(sessionId: 'test', tool: 'Write'),
      );
      final saved = await edits.save(
        service: service,
        overlay: overlay,
        shotId: ai.id,
        values: {'title': '作者'},
      );
      expect(
        (await overlay.getWorkingChanges()).where(
          (c) => c.status == workingChangeStatusActive,
        ),
        isEmpty,
      );
      final copied = await edits.copy(
        service: service,
        overlay: overlay,
        shot: saved,
        sceneId: sceneId,
      );
      expect(copied.id, isNot(saved.id));
      expect(copied.errorDismissed, isFalse);
      expect(copied.title, '作者');
      expect(copied.adoptedAssetId, isNull);
      await edits.reorder(
        service: service,
        overlay: overlay,
        ordered: [copied, saved],
      );
      expect((await service.sceneShots(sceneId)).map((s) => s.id), [
        copied.id,
        saved.id,
      ]);
    },
  );

  test('clip tools use screenplay defaults without public revision', () async {
    await service.saveSettings({'ratio': '16:9', 'resolution': '720p'});
    final created = await tools.executeTool(
      name: 'Create',
      input: {
        'path': 'clips',
        'fields': {'scene_id': sceneId, 'title': '一镜', 'prompt': '夜雨'},
      },
    );
    expect(created['error_code'], isNull, reason: '$created');
    final id = created['id'];
    expect(id, isA<String>());
    expect(created.containsKey('revision'), isFalse);
    final read = await tools.executeTool(
      name: 'Read',
      input: {'path': 'clips/$id/prompt'},
    );
    expect(read['value'], '夜雨', reason: '$read');
    final write = await tools.executeTool(
      name: 'Write',
      input: {'path': 'clips/$id/prompt', 'value': '新夜雨'},
    );
    expect(write['error_code'], isNull, reason: '$write');
    final listing = await tools.executeTool(
      name: 'Read',
      input: {'path': 'clips?episode_id=$episodeId'},
    );
    expect(listing['error_code'], isNull, reason: '$listing');
    expect((listing['entries'] as List).length, 1);
    expect((await service.getShot(id as String))!.prompt, '新夜雨');
  });

  test(
    'clips contract creates both kinds and exposes immutable identity with nullable video fields',
    () async {
      final schema = await tools.executeTool(
        name: 'Read',
        input: {'path': '/_schema/clips'},
      );
      expect(schema['resource_path'], 'clips/{clip_id}');
      final fields = schema['fields'] as Map;
      expect(fields['kind']['create'], isTrue);
      expect(fields['kind']['write'], isFalse);
      expect(fields['episode_id']['create'], isTrue);
      expect(fields['episode_id']['write'], isFalse);
      final episodeSchema = await tools.executeTool(
        name: 'Read',
        input: {'path': '/_schema/episodes'},
      );
      expect(
        (episodeSchema['subresources'] as List).map(
          (entry) => entry['resource_path'],
        ),
        ['episodes/{episode_id}/production'],
      );
      expect(fields['scene_id']['nullable'], isTrue);
      expect(fields['sort_order']['nullable'], isTrue);
      expect(fields['generate_audio']['nullable'], isTrue);
      expect(fields['generate_audio']['write'], isTrue);
      expect(fields.keys, isNot(contains('status')));
      expect(fields.keys, contains('reference_mode'));
      expect(
        fields.keys,
        isNot(
          anyOf(
            contains('generation_mode'),
            contains('fps'),
            contains('width'),
            contains('height'),
          ),
        ),
      );

      final segment = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'clips',
          'fields': {'scene_id': sceneId, 'prompt': 'Original'},
        },
      );
      expect(segment['kind'], 'video', reason: '$segment');
      expect(segment['episode_id'], episodeId);
      final video = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'clips',
          'fields': {
            'kind': 'video',
            'episode_id': episodeId,
            'title': 'Experiment',
            'prompt': 'Trial',
          },
        },
      );
      expect(video['error_code'], isNull, reason: '$video');
      expect(video['created'], isTrue);
      expect(video['id'], matches(RegExp(r'^clip_[A-Z0-9]{6}$')));
      expect(video['kind'], 'video');
      expect(video['path'], 'clips/${video['id']}');
      expect(video['scene_id'], isNull);
      expect(video['sort_order'], isNull);
      expect(video.containsKey('status'), isFalse);
      final id = video['id'] as String;
      expect(
        (await db.select(db.canvasNodes).get()).where((n) => n.clipId == id),
        hasLength(1),
      );
      final write = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'clips/$id',
          'fields': {'title': 'Changed', 'scene_id': null, 'sort_order': null},
        },
      );
      expect(write['error_code'], isNull, reason: '$write');
      expect(write['updated'], isTrue);
      expect((await service.getShot(id))!.title, 'Changed');
      final muted = await tools.executeTool(
        name: 'Write',
        input: {'path': 'clips/$id/generate_audio', 'value': false},
      );
      expect(muted['error_code'], isNull, reason: '$muted');
      expect((await service.getShot(id))!.generateAudio, isFalse);
      expect(
        (await tools.executeTool(
          name: 'Read',
          input: {'path': 'clips/$id/generate_audio'},
        ))['value'],
        isFalse,
      );
      expect(
        NovelWorkspaceSection.storyboard.aiResourcePath(itemId: id),
        '/clips/$id',
      );
      final edited = await tools.executeTool(
        name: 'Edit',
        input: {
          'path': 'clips/$id/prompt',
          'old_text': 'Trial',
          'new_text': 'Trial in rain',
        },
      );
      expect(edited['error_code'], isNull, reason: '$edited');
      expect(edited['edited'], isTrue);
      expect((await service.getShot(id))!.prompt, 'Trial in rain');

      final listing = await tools.executeTool(
        name: 'Read',
        input: {'path': 'clips?episode_id=$episodeId'},
      );
      expect(
        (listing['entries'] as List).map((r) => r['id']),
        unorderedEquals([segment['id'], id]),
      );
      final rootListing = await tools.executeTool(
        name: 'Read',
        input: {'path': 'clips'},
      );
      expect(
        (rootListing['entries'] as List).map((r) => r['kind']),
        unorderedEquals(['video', 'video']),
      );
      expect(
        (await tools.executeTool(
          name: 'Read',
          input: {'path': 'shots/$id'},
        ))['error_code'],
        isNotNull,
      );
      for (final patch in [
        {'kind': 'segment'},
        {'episode_id': episodeId},
        {'status': 'completed'},
      ]) {
        final ignored = await tools.executeTool(
          name: 'Write',
          input: {'path': 'clips/$id', 'fields': patch},
        );
        expect(ignored['ignored_fields'], patch.keys.toList());
        expect(ignored['updated'], isFalse);
      }
      for (final patch in [
        {'sort_order': 0},
      ]) {
        final invalid = await tools.executeTool(
          name: 'Write',
          input: {'path': 'clips/$id', 'fields': patch},
        );
        expect(invalid['error_code'], isNotNull, reason: '$patch => $invalid');
      }
      final invalidOrder = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'clips/${segment['id']}',
          'fields': {'sort_order': null},
        },
      );
      expect(invalidOrder['error_code'], isNotNull);
      expect((await service.getShot(id))!.kind, 'video');
      expect((await service.getShot(id))!.sceneId, isNull);
    },
  );

  test(
    'image and video clips join and leave storyboard without changing identity',
    () async {
      for (final kind in ['image', 'video']) {
        final created = await tools.executeTool(
          name: 'Create',
          input: {
            'path': 'clips',
            'fields': {
              'kind': kind,
              'episode_id': episodeId,
              'prompt': 'Keep me',
            },
          },
        );
        expect(created['error_code'], isNull, reason: '$created');
        final id = created['id'] as String;
        final node = (await db.select(db.canvasNodes).get()).singleWhere(
          (n) => n.clipId == id,
        );
        expect(node.type, kind);
        final joined = await tools.executeTool(
          name: 'Write',
          input: {
            'path': 'clips/$id',
            'fields': {'scene_id': sceneId},
          },
        );
        expect(joined['error_code'], isNull, reason: '$joined');
        expect(joined['kind'], kind);
        expect(joined.containsKey('status'), isFalse);
        expect((await service.episodeShots(episodeId)).single.id, id);
        expect(
          (await service.episodeClips(episodeId)).where((c) => c.id == id),
          hasLength(1),
        );
        final left = await tools.executeTool(
          name: 'Write',
          input: {
            'path': 'clips/$id',
            'fields': {'scene_id': null},
          },
        );
        expect(left['error_code'], isNull, reason: '$left');
        final saved = (await service.getShot(id))!;
        expect(saved.kind, kind);
        expect(saved.sceneId, isNull);
        expect(saved.sortOrder, isNull);
        expect(saved.errorDismissed, isFalse);
        expect(saved.prompt, 'Keep me');
        expect(await service.episodeShots(episodeId), isEmpty);
        expect(
          (await db.select(db.canvasNodes).get())
              .singleWhere((n) => n.clipId == id)
              .id,
          node.id,
        );
      }
      final image = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'clips',
          'fields': {'kind': 'image', 'scene_id': sceneId},
        },
      );
      expect(image['error_code'], isNull, reason: '$image');
      expect(image['kind'], 'image');
      expect(image['ratio'], '1:1');
      expect(image['resolution'], '1K');
      final copied = await edits.copy(
        service: service,
        overlay: overlay,
        shot: (await service.getShot(image['id'] as String))!,
        sceneId: sceneId,
      );
      expect(copied.kind, 'image');
      expect(copied.sortOrder, 1);
    },
  );

  test(
    'clips distinguish storyboard membership and filter before pagination',
    () async {
      Future<Map<String, dynamic>> create(Map<String, dynamic> fields) async {
        final result = await tools.executeTool(
          name: 'Create',
          input: {'path': 'clips', 'fields': fields},
        );
        expect(result['error_code'], isNull, reason: '$result');
        return result;
      }

      final blank = await create({'scene_id': sceneId, 'duration_ms': 6000});
      final image = await create({
        'scene_id': sceneId,
        'kind': 'image',
        'title': '图片分镜',
      });
      final video = await create({
        'scene_id': sceneId,
        'prompt': '剧情',
        'duration_ms': 8000,
      });
      final independent = await create({
        'episode_id': episodeId,
        'kind': 'video',
      });
      final reference = await create({
        'episode_id': episodeId,
        'kind': 'image',
      });
      await create({'episode_id': episodeId, 'kind': 'audio'});
      expect(blank['is_storyboard'], isTrue);
      expect(image['is_storyboard'], isTrue);
      expect(independent['is_storyboard'], isFalse);

      Future<Map<String, dynamic>> read(
        String query, {
        int? offset,
        int? limit,
      }) async {
        final result = await tools.executeTool(
          name: 'Read',
          input: {'path': 'clips?$query', 'offset': ?offset, 'limit': ?limit},
        );
        expect(result['error_code'], isNull, reason: '$result');
        return result;
      }

      List<dynamic> ids(Map<String, dynamic> result) =>
          (result['entries'] as List).map((r) => r['id']).toList();
      final scope = 'episode_id=$episodeId';
      expect(ids(await read(scope)), hasLength(6));
      expect(ids(await read('$scope&is_storyboard=true')), [
        blank['id'],
        image['id'],
        video['id'],
      ]);
      expect(ids(await read('scene_id=$sceneId&kind=image')), [image['id']]);
      expect(ids(await read('$scope&is_storyboard=false&kind=image')), [
        reference['id'],
      ]);
      expect(ids(await read('is_storyboard=true&kind=video')), [
        blank['id'],
        video['id'],
      ]);
      expect(ids(await read('$scope&is_storyboard=true&kind=audio')), isEmpty);
      final page = await read(
        '$scope&is_storyboard=true&kind=video',
        offset: 1,
        limit: 1,
      );
      expect(ids(page), [video['id']]);
      expect(page['total'], 2);
      expect(page['has_more'], isFalse);
      final first = await read(
        '$scope&is_storyboard=true&kind=video',
        limit: 1,
      );
      expect(ids(first), [blank['id']]);
      expect(first['has_more'], isTrue);
      final field = await tools.executeTool(
        name: 'Read',
        input: {'path': "clips/${image['id']}/is_storyboard"},
      );
      expect(field['value'], isTrue);
      for (final query in [
        'is_storyboard=yes',
        'is_storyboard=1',
        'kind=segment',
      ]) {
        final invalid = await tools.executeTool(
          name: 'Read',
          input: {'path': 'clips?$query'},
        );
        expect(invalid['error_code'], 'invalid_argument');
      }
      final rejected = await tools.executeTool(
        name: 'Write',
        input: {
          'path': "clips/${video['id']}",
          'fields': {'is_storyboard': false},
        },
      );
      expect(rejected['updated'], isFalse);
      expect(rejected['ignored_fields'], contains('is_storyboard'));
      expect((await service.getShot(video['id'] as String))!.sceneId, sceneId);
      final detached = await tools.executeTool(
        name: 'Write',
        input: {
          'path': "clips/${video['id']}",
          'fields': {'scene_id': null},
        },
      );
      expect(detached['is_storyboard'], isFalse);
      expect(ids(await read('$scope&is_storyboard=true&kind=video')), [
        blank['id'],
      ]);
    },
  );

  test(
    'invalid clip create combinations roll back rows and history, and AI video changes use clips paths',
    () async {
      for (final fields in [
        <String, dynamic>{},
        {'kind': 'video'},
        {'kind': 'video', 'episode_id': 'missing', 'scene_id': sceneId},
        {'kind': 'segment', 'episode_id': episodeId},
      ]) {
        final created = await tools.executeTool(
          name: 'Create',
          input: {'path': 'clips', 'fields': fields},
        );
        expect(created['error_code'], isNotNull, reason: '$fields => $created');
        expect(await db.select(db.productionClips).get(), isEmpty);
        expect(await db.select(db.canvasNodes).get(), isEmpty);
        expect(await overlay.getWorkingChanges(), isEmpty);
      }
      final created = await tools.executeTool(
        name: 'Create',
        input: {
          'path': 'clips',
          'fields': {'kind': 'video', 'episode_id': episodeId, 'prompt': 'Try'},
        },
      );
      final id = created['id'] as String;
      final change = (await overlay.getWorkingChanges()).single;
      expect(change.resourcePath, 'clips/$id');
      await overlay.rejectWorkingChange(change.id);
      expect(await service.getShot(id), isNull);
      // 场次节点随场次保留，片段节点随片段撤回。
      expect(
        (await db.canvasDao.getNodesByCanvas(
          (await db.screenplayDao.getEpisode(episodeId))!.canvasId!,
        )).where((node) => node.sceneId == null),
        isEmpty,
      );
    },
  );

  test(
    'Agent can remove references and reject malformed prompt writes',
    () async {
      final source = await service.createVideo(episodeId);
      final prompt =
          'Continue ${StoryboardPrompt.reference(source.id, 'Trial')}.';
      final target = await service.createVideo(
        episodeId,
        values: {'prompt': prompt},
      );
      final read = await tools.executeTool(
        name: 'Read',
        input: {'path': 'clips/${target.id}/prompt'},
      );
      expect(read['value'], prompt);
      final edited = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'clips/${target.id}/prompt',
          'value': 'Removed reference',
        },
      );
      expect(edited['error_code'], isNull, reason: '$edited');
      final changes = await overlay.getWorkingChanges();
      expect(changes.single.resourcePath, 'clips/${target.id}/document');
      final damaged = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'clips/${target.id}',
          'fields': {
            'title': 'Must not apply',
            'prompt': '<ref input_id="bad" />',
          },
        },
      );
      expect(damaged['error_code'], isNotNull);
      expect((await service.getShot(target.id))!.title, '');
      await overlay.rejectWorkingChange(changes.single.id);
      expect((await service.getShot(target.id))!.prompt, prompt);
      final segment = await service.create(sceneId);
      await ScreenplayService(db).deleteScene(sceneId);
      final detached = await tools.executeTool(
        name: 'Read',
        input: {'path': 'clips/${segment.id}'},
      );
      expect(detached['episode_id'], episodeId);
      expect(detached['scene_id'], sceneId);
    },
  );

  test(
    'agent reorder is atomic and copies cross episodes retain source identity',
    () async {
      final first = await service.create(sceneId, values: {'title': 'First'});
      final second = await service.create(sceneId, values: {'title': 'Second'});
      final moved = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'clips/${second.id}',
          'fields': {'sort_order': 0},
        },
      );
      expect(moved['error_code'], isNull, reason: '$moved');
      expect((await service.sceneShots(sceneId)).map((s) => s.id), [
        second.id,
        first.id,
      ]);
      final root = (await db.screenplayDao.getRoot())!;
      final season = await ScreenplayService(
        db,
      ).createSeason(screenplayId: root.id, title: 'Second season');
      final destination = await ScreenplayService(
        db,
      ).createScene(screenplayId: root.id, episodeId: season.episodeId);
      final current = (await service.getShot(first.id))!;
      await expectLater(
        edits.save(
          service: service,
          overlay: overlay,
          shotId: current.id,
          values: {'scene_id': destination},
        ),
        throwsA(isA<StoryboardException>()),
      );
      final copied = await edits.copy(
        service: service,
        overlay: overlay,
        shot: current,
        sceneId: destination,
      );
      expect(copied.id, isNot(current.id));
      expect((await service.getShot(first.id))!.sceneId, sceneId);
      final schema = await tools.executeTool(
        name: 'Read',
        input: {'path': '/_schema/clips'},
      );
      expect(schema.toString(), isNot(contains('revision')));
    },
  );

  test('committed shot edits can be rolled back', () async {
    final shot = await service.create(sceneId, values: {'title': 'Original'});
    await edits.save(
      service: service,
      overlay: overlay,
      shotId: shot.id,
      values: {'title': 'Edited'},
    );
    final commit = (await db.select(db.changeCommitItems).get()).singleWhere(
      (item) => item.resourceId == shot.id && item.newText!.contains('Edited'),
    );
    expect(
      await overlay.rollbackCommit(
        commitId: commit.commitId,
        resourceId: shot.id,
      ),
      RestoreResourceResult.restored,
    );
    expect((await service.getShot(shot.id))!.title, 'Original');
  });

  test(
    'manual settings save updates flat fields without change history',
    () async {
      await service.saveSettings({'ratio': '9:16', 'resolution': '1080p'});
      final root = await tools.executeTool(
        name: 'Read',
        input: {'path': 'screenplay'},
      );
      expect(root['ratio'], '9:16');
      expect(root['resolution'], '1080p');
      expect(root['width'], 1080);
      expect(root['height'], 1920);
      expect(root.containsKey('document'), isFalse);
      for (final field in ['ratio', 'resolution']) {
        final value = await tools.executeTool(
          name: 'Read',
          input: {'path': 'screenplay/$field'},
        );
        expect(value['value'], root[field]);
      }
      expect(await overlay.getWorkingChanges(), isEmpty);
      expect(await db.select(db.changeCommitItems).get(), isEmpty);
    },
  );

  test(
    'screenplay defaults support writes and edits without changing existing clips',
    () async {
      final oldClip = await service.create(sceneId);
      for (final name in ['Create', 'Write']) {
        final result = await tools.executeTool(
          name: name,
          input: {
            'path': 'screenplay',
            'fields': {'ratio': '9:16', 'resolution': '1080p'},
          },
        );
        expect(result['ok'], isTrue, reason: '$result');
      }
      final read = await tools.executeTool(
        name: 'Read',
        input: {'path': 'screenplay'},
      );
      expect(read['ratio'], '9:16');
      expect(read['resolution'], '1080p');
      expect(read['width'], 1080);
      expect(read['height'], 1920);
      final unchanged = (await service.getShot(oldClip.id))!;
      expect(unchanged.ratio, oldClip.ratio);
      expect(unchanged.resolution, oldClip.resolution);
      final newClip = await service.create(sceneId);
      expect(newClip.ratio, '9:16');
      expect(newClip.resolution, '1080p');
      final image = await service.createImage(episodeId);
      expect(image.ratio, '1:1');
      expect(image.resolution, '1K');
      for (final entry in {
        'ratio': ('9:16', '4:3'),
        'resolution': ('1080p', '720p'),
      }.entries) {
        final edited = await tools.executeTool(
          name: 'Edit',
          input: {
            'path': 'screenplay/${entry.key}',
            'old_text': entry.value.$1,
            'new_text': entry.value.$2,
          },
        );
        expect(edited['ok'], isTrue, reason: '$edited');
        final written = await tools.executeTool(
          name: 'Write',
          input: {'path': 'screenplay/${entry.key}', 'value': entry.value.$1},
        );
        expect(written['ok'], isTrue, reason: '$written');
      }
      final original = await service.requireSettings();
      for (final input in [
        {
          'path': 'screenplay',
          'fields': {'ratio': '16:9', 'resolution': '1K'},
        },
        {'path': 'screenplay/width', 'value': 400},
      ]) {
        final result = await tools.executeTool(name: 'Write', input: input);
        expect(result['ok'], isFalse, reason: '$result');
        expect(await service.requireSettings(), original);
      }
      final invalidEdit = await tools.executeTool(
        name: 'Edit',
        input: {
          'path': 'screenplay/ratio',
          'old_text': '9:16',
          'new_text': 'invalid',
        },
      );
      expect(invalidEdit['ok'], isFalse);
      expect(await service.requireSettings(), original);
    },
  );

  test(
    'screenplay defaults are readable and old episode settings paths are unavailable',
    () async {
      final missing = await tools.executeTool(
        name: 'Read',
        input: {'path': 'episodes/$episodeId/production'},
      );
      expect(missing['canvas_path'], 'episodes/$episodeId/production/canvas');
      expect(missing.containsKey('ratio'), isFalse);
      final root = await tools.executeTool(
        name: 'Read',
        input: {'path': 'screenplay'},
      );
      expect(root['ratio'], '16:9');
      expect(root['id'], (await service.getSettings())!.id);
      final resolution = await tools.executeTool(
        name: 'Read',
        input: {'path': 'screenplay/resolution'},
      );
      expect(resolution['value'], '720p');
      final denied = await tools.executeTool(
        name: 'Remove',
        input: {'path': 'screenplay'},
      );
      expect(denied['ok'], isFalse);
      expect(await overlay.getWorkingChanges(), isEmpty);
      expect(await service.hasSettingsPrompted(), isFalse);
      final glob = await tools.executeTool(
        name: 'Glob',
        input: {'pattern': 'episodes/**'},
      );
      expect(glob['error_code'], isNull, reason: '$glob');
      final shot = await edits.create(
        service: service,
        overlay: overlay,
        sceneId: sceneId,
        values: {'prompt': 'unique_storyboard_needle'},
      );
      final grep = await tools.executeTool(
        name: 'Grep',
        input: {'path': 'clips', 'pattern': 'unique_storyboard_needle'},
      );
      expect(grep['error_code'], isNull, reason: '$grep');
      expect(grep.toString(), contains(shot.id));
    },
  );
}
