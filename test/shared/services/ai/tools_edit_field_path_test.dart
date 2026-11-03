// 职责: 验证 Edit 的故事状态简写、字段纠错路径与预览和写入的一致性。
// 关联文件:
//   lib/shared/services/ai/tools_edit.dart
//   lib/shared/services/ai/tools_support.dart
//   lib/shared/services/ai/tools_outline.dart
//   lib/shared/services/ai/tools_canvas.dart
//   lib/shared/services/ai/tools.dart
import 'package:reveric/shared/app_config.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  late NovelContentDatabase db;
  late AppDatabase app;
  late NovelContentService content;
  late AiToolManager tools;
  late Map<String, dynamic> profile;
  late Map<String, dynamic>? preview;

  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    app = AppDatabase.forTest(NativeDatabase.memory());
    content = NovelContentService(db);
    profile = {'title': '作品', 'description': '旧内容'};
    preview = null;
    tools = AiToolManager(
      content,
      novelReader: () async => {...profile},
      novelWriter: (fields) async => profile.addAll(fields),
      workingOverlayService: WorkingOverlayService(
        db,
        content,
        novelActionsService: NovelActionsService(app),
      ),
      onToolStarted: (_, _, _, extra, _) => preview = extra,
    )..registerAllTools();
  });
  tearDown(() async {
    tools.dispose();
    await db.close();
    await app.close();
  });

  Future<Map<String, dynamic>> edit(String path) => tools.executeTool(
    name: 'Edit',
    input: {'path': path, 'old_text': '旧内容', 'new_text': '新内容'},
  );
  Future<Map<String, dynamic>> read(String path) =>
      tools.executeTool(name: 'Read', input: {'path': path});

  test('singleton Create shares Write validation and diff previews', () async {
    for (final tool in ['Create', 'Write']) {
      profile['description'] = '旧内容';
      final result = await tools.executeTool(
        name: tool,
        input: {
          'path': 'profile',
          'fields': {'description': '  新内容  '},
        },
      );
      expect(result['updated'], isTrue);
      expect(profile['description'], '新内容');
      expect(profile['title'], '作品');
      expect(preview?['diffOldText'], '旧内容');
      expect(preview?['diffNewText'], '新内容');

      // 未知字段跳过，可写字段照常落库；只有跳过项时既不写入也不产生预览。
      final ignored = await tools.executeTool(
        name: tool,
        input: {
          'path': 'profile',
          'fields': {'description': '再次更新', 'unknown': '无效字段'},
        },
      );
      expect(ignored['ok'], isTrue, reason: '$ignored');
      expect(ignored['ignored_fields'], ['unknown']);
      expect(profile['description'], '再次更新');

      preview = null;
      final skipped = await tools.executeTool(
        name: tool,
        input: {
          'path': 'profile',
          'fields': {'unknown': '无效字段'},
        },
      );
      expect(skipped['updated'], isFalse);
      expect(skipped['ignored_fields'], ['unknown']);
      expect(profile['description'], '再次更新');
      expect(preview, isNot(contains('diffOldText')));
      expect(preview, isNot(contains('diffNewText')));

      // 可写字段的值非法仍整次拒绝，跳过项一并回报。
      final rejected = await tools.executeTool(
        name: tool,
        input: {
          'path': 'profile',
          'fields': {
            'description': '不应保存',
            'status': '不存在的状态',
            'unknown': '无效字段',
          },
        },
      );
      expect(rejected['error_code'], 'invalid_argument');
      expect(rejected['ignored_fields'], ['unknown']);
      expect(profile['description'], '再次更新');
    }
  });

  test('outline Write preview uses the execution payload parser', () async {
    final created = await tools.executeTool(
      name: 'Create',
      input: {
        'path': 'outlines',
        'fields': {'title': '主线', 'status': 'pending'},
      },
    );
    expect(created['error'], isNull, reason: '$created');
    const path = 'outlines/主线/status';
    final rejected = await tools.executeTool(
      name: 'Write',
      input: {'path': path, 'fields': '{"status":"impossible"}'},
    );
    expect(rejected['error_code'], 'invalid_argument');
    expect(preview?['targetPath'], path);
    expect(preview, isNot(contains('diffOldText')));
    expect(preview, isNot(contains('diffNewText')));
    expect((await read(path))['value'], 'pending');

    final accepted = await tools.executeTool(
      name: 'Write',
      input: {'path': path, 'fields': '{"status":"active"}'},
    );
    expect(accepted['error'], isNull, reason: '$accepted');
    expect(preview?['diffOldText'], 'pending');
    expect(preview?['diffNewText'], 'in_progress');
    expect((await read(path))['value'], 'in_progress');
  });

  test('all formerly implicit paths fail without fabricating a diff', () async {
    for (final path in [
      'profile',
      'chapters/chapter_1',
      'volumes/volume_1',
      'characters/character_1',
      'foreshadowing/foreshadowing_1',
      'locations/location_1',
      'skills/skill_1',
      'items/item_1',
      'factions/faction_1',
      'creatures/creature_1',
      'lore/设定',
      'materials/素材',
      'outlines/主线',
      'outlines/主线/beats/beat_1',
      'canvas/画布',
      'canvas/画布/nodes/node_1',
    ]) {
      final result = await edit(path);
      expect(
        result['error_code'],
        'invalid_argument',
        reason: '$path: $result',
      );
      expect(
        result['hint'],
        contains(
          !ideationCanvasEnabled && path.startsWith('canvas/')
              ? '/_schema'
              : 'field',
        ),
      );
      expect(preview, isNot(contains('diffOldText')), reason: path);
      expect(preview, isNot(contains('diffNewText')), reason: path);
      expect(preview?['targetPath'], path);
    }
    expect(profile['description'], '旧内容');
  });

  test(
    'resource omission and an extra field argument cannot edit chapter content',
    () async {
      final id = await content.createChapter(siblingOrder: 1, title: '章节');
      await content.updateChapterContent(
        chapterId: id,
        title: '章节',
        outline: '',
        content: '旧内容',
      );
      final path = 'chapters/$id';
      for (final extra in [
        <String, dynamic>{},
        {'field': 'content'},
      ]) {
        final result = await tools.executeTool(
          name: 'Edit',
          input: {'path': path, 'old_text': '旧内容', 'new_text': '新内容', ...extra},
        );
        expect(result['error_code'], 'invalid_argument');
        expect((await content.getChapterById(id))!.content, '旧内容');
        expect(
          await db.workingChangeDao.getByResource('$path/content'),
          isEmpty,
        );
      }
      final invalid = await edit('$path/unknown');
      expect(invalid['error'], isNotNull);
      expect((await content.getChapterById(id))!.content, '旧内容');
      final result = await edit('$path/content');
      expect(result['error'], isNull, reason: '$result');
      expect((await content.getChapterById(id))!.content, '新内容');
      expect(preview?['targetPath'], '$path/content');
      expect(preview?['diffOldText'], '旧内容');
      expect(preview?['diffNewText'], '新内容');
    },
  );

  test('outline and beat require separate explicit content paths', () async {
    final created = await tools.executeTool(
      name: 'Create',
      input: {
        'path': 'outlines',
        'fields': {
          'title': '主线',
          'content': '旧内容',
          'beats': [
            {'title': '一拍', 'content': '旧内容'},
          ],
        },
      },
    );
    expect(created['created'], isTrue, reason: '$created');
    final listing = await read('outlines/主线/beats');
    final beatPath = (listing['entries'] as List).single['path'] as String;
    for (final path in ['outlines/主线', beatPath]) {
      final missing = await edit(path);
      expect(missing['error_code'], 'invalid_argument');
      expect(missing['editable_paths'], contains('$path/content'));
      expect(missing['error'], contains('$path/content'));
      expect((await read('$path/content'))['value'], '旧内容');
      final edited = await edit('$path/content');
      expect(edited['error'], isNull, reason: '$edited');
      expect((await read('$path/content'))['value'], '新内容');
    }
  });

  test('sticky node omission leaves its body unchanged', () async {
    if (!ideationCanvasEnabled) {
      expect((await edit('canvas/图/nodes/node_1/content'))['error'], isNotNull);
      return;
    }
    await tools.executeTool(
      name: 'Create',
      input: {
        'path': 'canvas',
        'fields': {'name': '图'},
      },
    );
    final node = await tools.executeTool(
      name: 'Create',
      input: {
        'path': 'canvas/图/nodes',
        'fields': {'type': 'sticky', 'content': '旧内容'},
      },
    );
    final path = node['path'] as String;
    expect((await edit(path))['error_code'], 'invalid_argument');
    expect((await read('$path/content'))['value'], '旧内容');
    expect((await edit('$path/content'))['ok'], isTrue);
    expect((await read('$path/content'))['value'], '新内容');
  });

  test('profile keeps explicit field editing and offers exact paths', () async {
    final missing = await edit('profile');
    expect(missing['error_code'], 'invalid_argument');
    expect(missing['editable_paths'], contains('profile/description'));
    expect(profile['description'], '旧内容');
    expect((await edit('profile/description'))['error'], isNull);
    expect(profile['description'], '新内容');
  });

  test('story state shorthand shares field editing and previews', () async {
    for (final path in ['story_state', '/story_state', 'story_state/content']) {
      await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'story_state',
          'fields': {'content': '旧内容'},
        },
      );
      final result = await edit(path);
      expect(result['error'], isNull, reason: '$result');
      expect(result['edited'], isTrue);
      expect(preview?['targetPath'], 'story_state/content');
      expect(preview?['diffOldText'], '旧内容');
      expect(preview?['diffNewText'], '新内容');
      expect((await read('story_state/content'))['value'], '新内容');
    }
  });

  test(
    'story state does not redirect invalid fields or bypass exact matching',
    () async {
      await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'story_state',
          'fields': {'content': '不同内容'},
        },
      );
      for (final path in [
        'story_state/unknown',
        'story_state/content/unknown',
      ]) {
        expect((await edit(path))['error'], isNotNull);
        expect(preview, isNot(contains('diffOldText')));
        expect((await read('story_state/content'))['value'], '不同内容');
      }
      expect((await edit('story_state'))['error_code'], 'failed_precondition');
      expect(preview, isNot(contains('diffOldText')));
      expect((await read('story_state/content'))['value'], '不同内容');
    },
  );

  test(
    'nested material errors offer paths relative to that document',
    () async {
      const path = 'materials/目录/素材';
      final folderId = await content.documentsService.createFolder(
        type: 'material',
        title: '目录',
      );
      await content.documentsService.createDocument(
        type: 'material',
        title: '素材',
        parentId: folderId,
        content: '旧内容',
      );
      final missing = await edit(path);
      expect(missing['error_code'], 'invalid_argument');
      expect(missing['editable_paths'], contains('$path/content'));
      expect(missing['error'], contains('$path/content'));
      expect((await read('$path/content'))['value'], '旧内容');
    },
  );

  test(
    'resource Write previews the supplied title instead of a preferred body',
    () async {
      final id = await content.createItem(
        type: 'skill',
        title: '旧标题',
        content: '旧内容',
      );
      final result = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'skills/$id',
          'fields': {'title': '新标题'},
        },
      );
      expect(result['error'], isNull, reason: '$result');
      expect(preview?['diffOldText'], '旧标题');
      expect(preview?['diffNewText'], '新标题');
      expect((await content.getItemById(id))!.content, '旧内容');
      final multiple = await tools.executeTool(
        name: 'Write',
        input: {
          'path': 'skills/$id',
          'fields': {'title': '另标题', 'content': '新内容'},
        },
      );
      expect(multiple['error'], isNull, reason: '$multiple');
      expect(preview, isNot(contains('diffOldText')));
      expect(preview, isNot(contains('diffNewText')));
      expect((await content.getItemById(id))!.title, '另标题');
      expect((await content.getItemById(id))!.content, '新内容');
    },
  );
}
