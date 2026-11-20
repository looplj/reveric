// 职责: 测试 AI Read 工具的 URL 查询参数过滤功能 — 验证 search 包含匹配、其余精准匹配和 path 正确性
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/models/character_profile.dart
//   lib/shared/services/novel_content.dart

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

import '../../../helpers/resource_contract.dart';

String encodeQuery(String key, String value) =>
    Uri(queryParameters: {key: value}).query;

void main() {
  group('AI Read query parameters', () {
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

    Future<void> seedChapters(List<String> titles) async {
      for (var i = 0; i < titles.length; i++) {
        await contentService.createChapter(
          siblingOrder: i + 1,
          title: titles[i],
        );
      }
    }

    Future<void> seedCharacters(List<String> names) async {
      for (var i = 0; i < names.length; i++) {
        await contentService.createCharacterProfile(defaultName: names[i]);
      }
    }

    Future<void> seedOutlines(List<String> titles) async {
      for (var i = 0; i < titles.length; i++) {
        await contentService.outlineService.createOutline(
          defaultTitle: titles[i],
        );
      }
    }

    Future<void> seedDocuments(
      String type,
      List<String> titles, {
      List<bool>? isFolder,
    }) async {
      for (var i = 0; i < titles.length; i++) {
        if (isFolder?[i] == true) {
          await contentService.documentsService.createFolder(
            type: type,
            title: titles[i],
          );
        } else {
          await contentService.documentsService.createDocument(
            type: type,
            title: titles[i],
          );
        }
      }
    }

    test('chapters query by search filters results', () async {
      await seedChapters(['第一章', '第二章', '第三章']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters?${encodeQuery('search', '第二章')}'},
        callId: 'call_chapters_query',
      );

      expect(result['error'], isNull);
      final entries = result['entries'] as List<dynamic>;
      expect(entries.length, 1);
      final first = entries.first as Map<String, dynamic>;
      expect(first['title'], '第二章');
      expect(first['path'], startsWith('chapters/'));
    });

    test(
      'volume filtering composes with queries and runs before pagination',
      () async {
        final volume = await contentService.createVolume(title: '第一卷');
        final otherVolume = await contentService.createVolume(title: '第二卷');
        final ids = <String, String>{};
        for (final (title, parentId) in [
          ('A', volume),
          ('B', otherVolume),
          ('C', volume),
          ('D', otherVolume),
          ('E', volume),
          ('F', null),
        ]) {
          ids[title] = await contentService.createChapter(
            siblingOrder: ids.length + 1,
            title: title,
            parentId: parentId,
          );
        }
        Future<Map<String, dynamic>> readVolume(
          String id, {
          Map<String, String> query = const {},
          int offset = 0,
          int limit = 20,
        }) => toolManager.executeTool(
          name: 'Read',
          input: {
            'path':
                'chapters?${Uri(queryParameters: {'volume_id': id, ...query}).query}',
            'sort': 'title',
            'offset': offset,
            'limit': limit,
          },
        );

        final all = await readVolume(volume);
        expect(all['error'], isNull, reason: '$all');
        expect((all['entries'] as List).map((e) => e['id']), [
          ids['A'],
          ids['C'],
          ids['E'],
        ]);
        final page = await readVolume(volume, offset: 1, limit: 1);
        expect((page['entries'] as List).single['id'], ids['C']);
        final chapter = await contentService.getChapterById(ids['C']!);
        final combined = await readVolume(
          volume,
          query: {'search': 'C', 'chapter_num': '${chapter!.chapterNum}'},
        );
        expect((combined['entries'] as List).single['id'], ids['C']);
        final differentVolume = await readVolume(
          otherVolume,
          query: {'search': 'C'},
        );
        expect(differentVolume['error'], isNull);
        expect(differentVolume['entries'], isEmpty);
        final missing = await readVolume('vol_missing');
        expect(missing['error'], isNull);
        expect(missing['entries'], isEmpty);
      },
    );

    test('chapters query is case-insensitive', () async {
      await seedChapters(['第一章', '第二章', '第三章']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters?${encodeQuery('search', '第二章')}'}, // 大写
        callId: 'call_chapters_query_case',
      );

      final entries = result['entries'] as List<dynamic>;
      expect(entries.length, 1);
    });

    test('chapters query returns error for invalid param', () async {
      await seedChapters(['第一章']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters?invalid=foo'},
        callId: 'call_chapters_invalid_param',
      );

      expect(result['error'], isNotNull);
      expect(result['error_code'], 'invalid_argument');
    });

    test('chapters query rejects legacy title parameter', () async {
      await seedChapters(['第一章']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters?${encodeQuery('title', '第一章')}'},
        callId: 'call_chapters_legacy_title',
      );

      expect(result['error_code'], 'invalid_argument');
    });

    test('chapters search matches a title substring', () async {
      await seedChapters(['第一章', '第二章', '第三章']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters?${encodeQuery('search', '二')}'},
        callId: 'call_chapters_search_substring',
      );

      final entries = result['entries'] as List<dynamic>;
      expect(entries, hasLength(1));
      expect((entries.first as Map<String, dynamic>)['title'], '第二章');
    });

    test('characters query by search filters results', () async {
      await seedCharacters(['张三', '李四', '王五']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'characters?${encodeQuery('search', '李四')}'},
        callId: 'call_characters_query',
      );

      expect(result['error'], isNull);
      final entries = result['entries'] as List<dynamic>;
      expect(entries.length, 1);
      final first = entries.first as Map<String, dynamic>;
      expect(first['name'], '李四');
      expect(first['path'], startsWith('characters/'));
    });

    test(
      'legacy character name remains an exact filter alongside search',
      () async {
        await seedCharacters(['Alice', 'Alice junior', 'Bob']);
        final result = await toolManager.executeTool(
          name: 'Read',
          input: {'path': 'characters?name=alice&search=ali'},
          callId: 'legacy_name',
        );
        expect(result['error'], isNull);
        final entries = result['entries'] as List<dynamic>;
        expect(entries, hasLength(1));
        expect((entries.single as Map)['name'], 'Alice');
      },
    );

    test('obsolete worldbuilding collection is rejected', () async {
      await seedDocuments('lore', ['Magic']);
      for (final path in [
        'worldbuilding',
        'worldbuilding?search=Magic',
        'worldbuilding/Magic/content',
      ]) {
        final result = await toolManager.executeTool(
          name: 'Read',
          input: {'path': path},
          callId: 'legacy_lore',
        );
        expect(result['error'], isNotNull, reason: path);
      }
    });

    test(
      'legacy location name is exact and does not search descriptions',
      () async {
        await contentService.locationsService.createLocation(
          name: 'World',
          type: 'world',
        );
        await contentService.locationsService.createLocation(
          name: 'World Two',
          type: 'world',
        );
        final result = await toolManager.executeTool(
          name: 'Read',
          input: {'path': 'locations?name=world'},
          callId: 'legacy_location_name',
        );
        expect(result['error'], isNull);
        final entries = result['entries'] as List<dynamic>;
        expect(entries, hasLength(1));
        expect((entries.single as Map)['name'], 'World');
      },
    );

    test(
      'location parent filtering returns direct children before pagination',
      () async {
        final locations = contentService.locationsService;
        final world = await locations.createLocation(
          name: 'World',
          type: 'world',
        );
        final otherWorld = await locations.createLocation(
          name: 'Other World',
          type: 'world',
        );
        final ids = <String, String>{};
        for (final (name, parentId) in [
          ('A City', world),
          ('B City', otherWorld),
          ('C City', world),
          ('D City', otherWorld),
          ('E City', world),
        ]) {
          ids[name] = await locations.createLocation(
            name: name,
            type: 'city',
            parentId: parentId,
          );
        }
        final grandchild = await locations.createLocation(
          name: 'C City',
          parentId: ids['A City'],
        );
        Future<Map<String, dynamic>> readChildren(
          String parentId, {
          Map<String, String> query = const {},
          int offset = 0,
          int limit = 20,
        }) {
          final queryString = {'parent_id': parentId, ...query}.entries
              .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
              .join('&');
          return toolManager.executeTool(
            name: 'Read',
            input: {
              'path': 'locations?$queryString',
              'sort': 'name',
              'offset': offset,
              'limit': limit,
            },
          );
        }

        final all = await readChildren(world);
        expect(all['error'], isNull, reason: '$all');
        final entries = all['entries'] as List;
        expect(entries.map((e) => e['id']), [
          ids['A City'],
          ids['C City'],
          ids['E City'],
        ]);
        expect(entries.map((e) => e['parent_id']), everyElement(world));
        expect(
          entries.map((e) => e['path']),
          entries.map((e) => 'locations/${e['id']}'),
        );
        final nested = await readChildren(ids['A City']!);
        expect(nested['error'], isNull);
        expect((nested['entries'] as List).single['id'], grandchild);

        final page = await readChildren(world, offset: 1, limit: 1);
        expect(page['error'], isNull);
        expect((page['entries'] as List).single['id'], ids['C City']);
        final combined = await readChildren(
          world,
          query: {'search': 'city', 'name': 'c city'},
        );
        expect(combined['error'], isNull);
        expect((combined['entries'] as List).single['id'], ids['C City']);
        final otherBranch = await readChildren(
          otherWorld,
          query: {'search': 'C City'},
        );
        expect(otherBranch['error'], isNull);
        expect(otherBranch['entries'], isEmpty);
        for (final parentId in [ids['E City']!, 'location_missing']) {
          final empty = await readChildren(parentId);
          expect(empty['error'], isNull);
          expect(empty['entries'], isEmpty);
        }
        final contract = resourceContractTreeForTesting('/_schema/locations');
        expect(contract['error'], isNull);
        expect(contract['query'], contains('parent_id'));
        expect(contract['query_contracts']['parent_id']['match'], 'exact');
      },
    );

    test('folder query retains hierarchy and canonical child paths', () async {
      final parentId = await contentService.documentsService.createFolder(
        type: 'lore',
        title: 'Magic',
      );
      await contentService.documentsService.createDocument(
        type: 'lore',
        parentId: parentId,
        title: 'Fire',
      );
      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'lore/Magic?search=Fire'},
        callId: 'legacy_folder',
      );
      expect(result['error'], isNull);
      expect(
        ((result['entries'] as List).single as Map)['path'],
        'lore/Magic/Fire',
      );
      final invalid = await toolManager.executeTool(
        name: 'Read',
        input: {'path': '/worldbuilding_extra'},
        callId: 'invalid_legacy_prefix',
      );
      expect(invalid['error_code'], 'invalid_argument');
    });

    test('characters search matches identity but not biography', () async {
      await contentService.createCharacterProfile(
        defaultName: '张三',
        identity: '松江府县令',
        biography: '早年做过游侠',
      );
      await contentService.createCharacterProfile(
        defaultName: '李四',
        identity: '江湖游侠',
        biography: '曾任县令幕僚',
      );

      final byIdentity = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'characters?${encodeQuery('search', '县令')}'},
        callId: 'call_characters_search_identity',
      );
      expect(byIdentity['error'], isNull);
      final identityHits = byIdentity['entries'] as List<dynamic>;
      expect(identityHits, hasLength(1));
      final identityHit = identityHits.single as Map<String, dynamic>;
      expect(identityHit['name'], '张三');
      expect(identityHit['identity'], '松江府县令');

      final byBiography = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'characters?${encodeQuery('search', '幕僚')}'},
        callId: 'call_characters_search_skips_biography',
      );
      expect(byBiography['error'], isNull);
      expect(byBiography['entries'], isEmpty);
    });

    test('characters query accepts a literal percent character', () async {
      await seedCharacters(['完成度 50%']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'characters?search=完成度 50%'},
        callId: 'call_characters_literal_percent',
      );

      expect(result['error'], isNull);
      final entries = result['entries'] as List<dynamic>;
      expect(entries, hasLength(1));
      final first = entries.single as Map<String, dynamic>;
      expect(first['name'], '完成度 50%');
    });

    test('characters query by gender filters results', () async {
      final maleId = await contentService.createCharacterProfile(
        defaultName: '张三',
        gender: characterGenderMale,
      );
      await contentService.createCharacterProfile(
        defaultName: '李四',
        gender: characterGenderFemale,
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {
          'path': 'characters?${encodeQuery('gender', characterGenderMale)}',
        },
        callId: 'call_characters_query_gender',
      );

      expect(result['error'], isNull);
      final entries = result['entries'] as List<dynamic>;
      expect(entries.length, 1);
      final first = entries.first as Map<String, dynamic>;
      expect(first['id'], maleId);
      expect(first['name'], '张三');
      expect(first['gender'], characterGenderMale);
      expect(first['path'], startsWith('characters/'));
    });

    test('characters query by role filters results', () async {
      final protagonistId = await contentService.createCharacterProfile(
        defaultName: '张三',
        role: characterRoleProtagonist,
      );
      await contentService.createCharacterProfile(
        defaultName: '李四',
        role: characterRoleSupporting,
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {
          'path': 'characters?${encodeQuery('role', characterRoleProtagonist)}',
        },
        callId: 'call_characters_query_role',
      );

      expect(result['error'], isNull);
      final entries = result['entries'] as List<dynamic>;
      expect(entries, hasLength(1));
      final first = entries.single as Map<String, dynamic>;
      expect(first['id'], protagonistId);
      expect(first['role'], characterRoleProtagonist);
    });

    test('characters query by aliases filters results', () async {
      final characterId = await contentService.createCharacterProfile(
        defaultName: '张三',
        aliases: ['阿三', '三哥'],
      );
      await contentService.createCharacterProfile(
        defaultName: '李四',
        aliases: ['阿四'],
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'characters?${encodeQuery('aliases', '三哥')}'},
        callId: 'call_characters_query_aliases',
      );

      expect(result['error'], isNull);
      final entries = result['entries'] as List<dynamic>;
      expect(entries, hasLength(1));
      final first = entries.single as Map<String, dynamic>;
      expect(first['id'], characterId);
      expect(first['aliases'], contains('三哥'));
    });

    test('characters query by age filters results', () async {
      await contentService.createCharacterProfile(defaultName: '张三', age: '34');
      await contentService.createCharacterProfile(defaultName: '李四', age: '29');

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'characters?${encodeQuery('age', '34')}'},
        callId: 'call_characters_query_age',
      );

      expect(result['error'], isNull);
      final entries = result['entries'] as List<dynamic>;
      expect(entries, hasLength(1));
      final first = entries.single as Map<String, dynamic>;
      expect(first['name'], '张三');
      expect(first['age'], '34');
      expect(first['path'], startsWith('characters/'));
    });

    test('outlines query by search filters results', () async {
      await seedOutlines(['主线', '副线', '隐藏线']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'outlines?${encodeQuery('search', '副线')}'},
        callId: 'call_outlines_query',
      );

      expect(result['error'], isNull);
      final entries = result['entries'] as List<dynamic>;
      expect(entries.length, 1);
      final first = entries.first as Map<String, dynamic>;
      expect(first['title'], '副线');
      expect(first['path'], 'outlines/副线');
      expect(first.containsKey('_links'), isFalse);
    });

    test('outlines query path is correct', () async {
      await seedOutlines(['主线', '副线']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'outlines?${encodeQuery('search', '主线')}'},
        callId: 'call_outlines_query_path',
      );

      final entries = result['entries'] as List<dynamic>;
      final first = entries.first as Map<String, dynamic>;
      // 对于 usesNamePath 的集合，path 应该是 /outlines/{title}
      expect(first['path'], 'outlines/主线');
    });

    // lore/materials 的 query 过滤 path 的直属 children：集合根查根级文档，
    // 文件夹路径查该文件夹内。跨层按标题定位仍走 Glob（见 tools_glob_test）。
    test('lore query filters root-level documents', () async {
      await seedDocuments('lore', ['魔法系统', '历史背景', '地理设定']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'lore?${encodeQuery('search', '历史背景')}'},
        callId: 'call_lore_query',
      );

      final entries = result['entries'] as List<dynamic>;
      expect(entries, hasLength(1));
      expect((entries.first as Map<String, dynamic>)['title'], '历史背景');
      expect((entries.first as Map<String, dynamic>)['path'], 'lore/历史背景');
    });

    test('lore query inside a folder filters that folder children', () async {
      final folderId = await contentService.documentsService.createFolder(
        type: 'lore',
        title: '魔法系统',
      );
      for (final title in ['火系魔法', '水系魔法']) {
        await contentService.documentsService.createDocument(
          type: 'lore',
          parentId: folderId,
          title: title,
        );
      }
      // 同名文档放在根级：确认过滤的是「该文件夹的 children」，不是全库同名命中。
      await contentService.documentsService.createDocument(
        type: 'lore',
        title: '火系魔法',
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'lore/魔法系统?${encodeQuery('search', '火系魔法')}'},
        callId: 'call_lore_folder_query',
      );

      final entries = result['entries'] as List<dynamic>;
      expect(entries, hasLength(1));
      expect((entries.first as Map<String, dynamic>)['title'], '火系魔法');
      expect((entries.first as Map<String, dynamic>)['path'], 'lore/魔法系统/火系魔法');
    });

    // query 不跨层：子文件夹里的文档不会被集合根的 query 捞出来，
    // 否则返回的 path 会缺少父文件夹段，模型拿去 Read 必然 not_found。
    test('lore root query does not reach nested documents', () async {
      final folderId = await contentService.documentsService.createFolder(
        type: 'lore',
        title: '魔法系统',
      );
      await contentService.documentsService.createDocument(
        type: 'lore',
        parentId: folderId,
        title: '火系魔法',
      );

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'lore?${encodeQuery('search', '火系魔法')}'},
        callId: 'call_lore_nested_query',
      );

      expect(result['entries'], isEmpty);
    });

    test('materials query filters root-level documents', () async {
      await seedDocuments('material', ['第一章草稿', '人物设定稿', '世界观稿']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'materials?${encodeQuery('search', '人物设定稿')}'},
        callId: 'call_materials_query',
      );

      final entries = result['entries'] as List<dynamic>;
      expect(entries, hasLength(1));
      expect((entries.first as Map<String, dynamic>)['title'], '人物设定稿');
    });

    test('lore listing without query still lists root entries', () async {
      await seedDocuments('lore', ['魔法系统', '非魔法', '魔法历史']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'lore'},
        callId: 'call_lore_listing',
      );

      expect(result['error'], isNull);
      final entries = result['entries'] as List<dynamic>;
      expect(entries.length, 3);
      expect(
        entries.map((e) => (e as Map<String, dynamic>)['path']),
        containsAll(<String>['lore/魔法系统']),
      );
    });

    test('query with no match returns empty entries', () async {
      await seedChapters(['第一章', '第二章']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters?${encodeQuery('search', '不存在')}'},
        callId: 'call_query_no_match',
      );

      expect(result['error'], isNull);
      final entries = result['entries'] as List<dynamic>;
      expect(entries.length, 0);
    });

    test('query params are ignored when reading single resource', () async {
      final chapterId = await contentService.createChapter(
        siblingOrder: 1,
        title: '第一章',
      );

      // 有 id 时，查询参数应该被忽略
      final result = await toolManager.executeTool(
        name: 'Read',
        input: {'path': 'chapters/$chapterId?${encodeQuery('search', '第二章')}'},
        callId: 'call_query_with_id',
      );

      expect(result['error'], isNull);
      expect(result['title'], '第一章'); // 返回的是匹配 id 的章节
    });

    test('query works with offset/limit', () async {
      await seedChapters(['第一章', '第二章', '第三章', '第四章']);

      final result = await toolManager.executeTool(
        name: 'Read',
        input: {
          'path': 'chapters?${encodeQuery('search', '第二章')}',
          'limit': 10,
          'offset': 0,
        },
        callId: 'call_query_with_limit',
      );

      expect(result['entries'], isNotNull);
      final entries = result['entries'] as List<dynamic>;
      expect(entries.length, 1);
      expect(entries.first['title'], '第二章');
    });
  });
}
