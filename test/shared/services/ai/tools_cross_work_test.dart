// 职责: 验证 AI 工具的作品路径寻址、写入门禁与跨作品内容库 lease 生命周期。
// 关联文件:
//   lib/shared/services/ai/tools_cross_work.dart
//   lib/shared/services/ai/tools_support.dart
//   lib/shared/services/ai/tools.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart

import 'package:reveric/shared/app_config.dart';
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/novel_type.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/utils/short_entity_id.dart';

void main() {
  group('cross-work path contract', () {
    test('works prefix preserves the existing inner path parse', () {
      final local = parseAiToolPath('chapters/chapter_1/content?foo=bar');
      final cross = parseAiToolPath(
        '/works/work_1/chapters/chapter_1/content?foo=bar',
      );

      expect(cross.workId, 'work_1');
      expect(cross.collection, local.collection);
      expect(cross.id, local.id);
      expect(cross.field, local.field);
      expect(cross.queryParameters, local.queryParameters);
      expect(cross.displayPath, '/works/work_1/chapters/chapter_1/content');
      expect(cross.localDisplayPath, 'chapters/chapter_1/content');

      final works = parseAiToolPath('works');
      expect(works.isWorksListing, isTrue);
      expect(works.workId, isNull);

      final legacyProfile = parseAiToolPath('profile/title');
      expect(legacyProfile.collection, 'profile');
      expect(legacyProfile.field, 'title');
      expect(legacyProfile.displayPath, 'profile/title');

      final legacyState = parseAiToolPath('/works/work_1/story_state');
      expect(legacyState.collection, 'story_state');
      expect(legacyState.displayPath, '/works/work_1/story_state');
    });

    test('path schema exposes resource-specific ID placeholders', () {
      final schema = '${pathSchema()}\n${pathSchemaFieldNotes()}';

      expect(schema, contains('/works/{work_id}'));
      expect(schema, contains('profile'));
      expect(schema, contains('story_state'));
      expect(schema, isNot(contains('/novel')));
      expect(schema, contains('chapters/{chapter_id}'));
      expect(schema, contains('characters/{character_id}'));
      expect(schema, isNot(contains('relations/{relation_id}')));
      expect(schema, isNot(contains('- ID 寻址：/chapters')));
      final idAddressingLine = schema
          .split('\n')
          .singleWhere((line) => line.startsWith('  path: chapters/'));
      expect(idAddressingLine, isNot(contains('/works/{work_id}')));
      expect(schema, isNot(contains('{id}')));
      expect(schema, contains('相对路径：以当前作品为起点'));
      expect(schema, contains('绝对路径：以 /works/{work_id} 为起点'));
      expect(schema, contains('用户未明确要求引用、比较或改编其他作品时，不要读取 /works'));
      expect(schema, contains('每项至少返回 id、title、path'));
      expect(schema, contains('Create、Write、Edit、Replace、Remove 只能修改当前作品'));
    });
  });

  test('work access failures never receive resource schema hints', () async {
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    final service = NovelContentService(db);
    final app = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(app.close);
    final overlay = WorkingOverlayService(
      db,
      service,
      novelActionsService: NovelActionsService(app),
    );

    for (final (code, expectedCode) in [
      ('cross_work_unavailable', 'unavailable'),
      ('works_unavailable', 'unavailable'),
      ('work_not_found', 'not_found'),
      ('work_unavailable', 'unavailable'),
      ('future_runtime_error', 'unavailable'),
    ]) {
      final manager = AiToolManager(
        service,
        workingOverlayService: overlay,
        crossWorkAccess: code == 'cross_work_unavailable'
            ? null
            : _FailingCrossWorkAccess(code),
      )..registerAllTools();
      addTearDown(manager.dispose);
      final result = await manager.executeTool(
        name: 'Read',
        input: {
          'path': code == 'works_unavailable'
              ? '/works'
              : '/works/target/chapters/id/content',
        },
      );
      expect(result['error_code'], expectedCode);
      expect(result.toString(), isNot(contains('/_schema')));
      expect(result.containsKey('validation_errors'), isFalse);
      expect(
        result['path'],
        code == 'works_unavailable' ? '/works' : '/works/target',
      );
    }
  });

  group('cross-work read tools', () {
    late NovelContentDatabase currentDatabase;
    late NovelContentDatabase targetDatabase;
    late AppDatabase appDatabase;
    late NovelContentService currentService;
    late NovelContentService targetService;
    late _FakeCrossWorkAccess access;
    late AiToolManager manager;
    late String currentChapterId;
    late String targetChapterId;

    setUp(() async {
      currentDatabase = NovelContentDatabase.forTest(NativeDatabase.memory());
      targetDatabase = NovelContentDatabase.forTest(NativeDatabase.memory());
      appDatabase = AppDatabase.forTest(NativeDatabase.memory());
      ShortEntityIdBuilder ids() {
        var counter = 0;
        return (type) =>
            '${shortEntityIdPrefixes[type]}_${(counter++).toRadixString(36).toUpperCase().padLeft(6, '0')}';
      }

      currentService = NovelContentService(currentDatabase, idBuilder: ids());
      targetService = NovelContentService(targetDatabase, idBuilder: ids());
      currentChapterId = await currentService.createChapter(
        siblingOrder: 1,
        title: '当前作品第一章',
      );
      await currentService.updateChapterContent(
        chapterId: currentChapterId,
        title: '当前作品第一章',
        outline: '当前作品大纲',
        content: '当前第一行\n当前作品线索',
      );
      targetChapterId = await targetService.createChapter(
        siblingOrder: 1,
        title: '源作品第一章',
      );
      await targetService.updateChapterContent(
        chapterId: targetChapterId,
        title: '源作品第一章',
        outline: '源作品大纲',
        content: '第一行\n跨作品线索\n第三行',
      );
      await targetService.writeCurrentStateSnapshot(content: '源作品累积状态');
      access = _FakeCrossWorkAccess(targetService);
      final overlay = WorkingOverlayService(
        currentDatabase,
        currentService,
        novelActionsService: NovelActionsService(appDatabase),
      );
      manager = AiToolManager(
        currentService,
        workingOverlayService: overlay,
        crossWorkAccess: access,
      )..registerAllTools();
    });

    tearDown(() async {
      manager.dispose();
      await currentDatabase.close();
      await targetDatabase.close();
      await appDatabase.close();
    });

    test(
      'current absolute reads share service, type and values with relative reads',
      () async {
        for (final path in ['chapters', 'chapters/$currentChapterId/content']) {
          final relative = await manager.executeTool(
            name: 'Read',
            input: {'path': path},
          );
          final absolute = await manager.executeTool(
            name: 'Read',
            input: {'path': '/works/work_current/$path'},
          );
          expect(absolute['error'], isNull, reason: '$absolute');
          expect(absolute['path'], '/works/work_current/$path');
          expect(absolute['work_id'], 'work_current');
          if (relative.containsKey('value')) {
            expect(absolute['value'], relative['value']);
          } else {
            expect(
              (absolute['entries'] as List).single['id'],
              currentChapterId,
            );
            expect(
              (relative['entries'] as List).single['id'],
              currentChapterId,
            );
          }
        }
        expect(access.acquireCount, 0);
      },
    );

    test(
      'the same short identity stays scoped across alternating work reads',
      () async {
        expect(currentChapterId, targetChapterId);
        expect(currentChapterId, 'chp_000000');
        for (var i = 0; i < 3; i++) {
          for (final entry in const {
            'work_current': '当前第一行\n当前作品线索',
            'work_target': '第一行\n跨作品线索\n第三行',
          }.entries) {
            final result = await manager.executeTool(
              name: 'Read',
              input: {
                'path':
                    '/works/${entry.key}/chapters/$currentChapterId/content',
              },
            );
            expect(result['value'], entry.value);
            expect(result['work_id'], entry.key);
          }
        }
        final denied = await manager.executeTool(
          name: 'Write',
          input: {
            'path': '/works/work_target/chapters/$currentChapterId/title',
            'value': 'must not cross works',
          },
        );
        expect(denied['error_code'], 'permission_denied');
        expect(
          (await targetService.getChapterById(targetChapterId))!.title,
          '源作品第一章',
        );
        expect(
          access.acquireCount,
          1,
        ); // Repeated reads reuse only the target lease.
      },
    );

    test(
      'current work identity works without a cross-work discovery provider',
      () async {
        final local = AiToolManager(
          currentService,
          workingOverlayService: manager.workingOverlayService,
          workId: 'standalone',
        )..registerAllTools();
        addTearDown(local.dispose);
        final read = await local.executeTool(
          name: 'Read',
          input: {
            'path': '/works/standalone/chapters/$currentChapterId/content',
          },
        );
        expect(read['value'], '当前第一行\n当前作品线索');
        final write = await local.executeTool(
          name: 'Write',
          input: {
            'path': '/works/standalone/chapters/$currentChapterId/title',
            'value': ' 改名 ',
          },
        );
        expect(write['error'], isNull, reason: '$write');
        expect(
          (await currentService.getChapterById(currentChapterId))!.title,
          '改名',
        );
        final denied = await local.executeTool(
          name: 'Write',
          input: {
            'path': '/works/work_target/chapters/$targetChapterId/title',
            'value': '拒绝',
          },
        );
        expect(denied['error_code'], 'permission_denied');
      },
    );

    test(
      'cross-work canvas uses target kind, paths and read-only boundary',
      () async {
        access.contentKind = contentKindCanvas;
        await ScreenplayService(targetDatabase).createCanvasStructure();
        final clips = StoryboardService(
          targetDatabase,
          contentKind: contentKindCanvas,
        );
        final clip = await clips.createVideo(
          '',
          values: {'title': 'Canvas target'},
        );
        final listing = await manager.executeTool(
          name: 'Read',
          input: {'path': '/works/work_target/production/clips'},
        );
        expect(listing['error'], isNull, reason: '$listing');
        final entry = (listing['entries'] as List).single;
        expect(entry['path'], '/works/work_target/production/clips/${clip.id}');
        expect(entry['id'], clip.id);
        expect(entry.containsKey('episode_id'), false);
        final denied = await manager.executeTool(
          name: 'Write',
          input: {
            'path': entry['path'],
            'fields': {'title': 'Denied'},
          },
        );
        expect(denied['error_code'], 'permission_denied');
        final wrongKind = await manager.executeTool(
          name: 'Read',
          input: {'path': '/works/work_target/episodes'},
        );
        expect(wrongKind['error'], isNotNull);
        expect((await clips.getShot(clip.id))!.title, 'Canvas target');
      },
    );

    test(
      'target content kind is explicit and unknown kinds never inherit current kind',
      () async {
        access.contentKind = 'future_kind';
        for (final path in [
          '/works/work_target',
          '/works/work_target/chapters',
        ]) {
          final result = await manager.executeTool(
            name: 'Read',
            input: {'path': path},
          );
          expect(result['error_code'], 'unsupported');
          expect(result['path'], '/works/work_target');
          expect(result.toString(), isNot(contains('/_schema')));
        }
        expect(access.releaseCount, 2);
        access.contentKind = contentKindScreenplay;
        // Metadata deliberately says novel; only the explicit descriptor field is authoritative.
        final root = await manager.executeTool(
          name: 'Read',
          input: {'path': '/works/work_target'},
        );
        expect(
          (root['entries'] as List).any(
            (entry) => entry['path'] == '/works/work_target/seasons',
          ),
          isTrue,
        );
        final mismatch = await manager.executeTool(
          name: 'Read',
          input: {'path': '/works/work_target/chapters'},
        );
        expect(mismatch['error_code'], 'invalid_argument');
      },
    );

    test(
      'business strings and nested JSON keys are preserved verbatim',
      () async {
        const text = '  chapters/notes\nRead scenes and outlines/main.  ';
        const payload = {
          'path': 'chapters/business',
          'episode_path': 'episodes/business',
          'matches': ['scenes/business'],
          'hint': 'Read chapters and outlines.',
          'error': 'materials is prose',
          'nested': {'path': 'characters/business'},
        };
        access.extraMetadata = {'payload': payload};
        await targetService.updateChapterContent(
          chapterId: targetChapterId,
          title: '原文',
          outline: '',
          content: text,
        );
        final body = await manager.executeTool(
          name: 'Read',
          input: {
            'path': '/works/work_target/chapters/$targetChapterId/content',
          },
        );
        expect(body['value'], text);
        final profile = await manager.executeTool(
          name: 'Read',
          input: {'path': '/works/work_target/profile'},
        );
        expect(profile['payload'], payload);
        expect(profile['path'], '/works/work_target/profile');
        expect(profile['work_id'], 'work_target');
      },
    );

    test(
      'unclassified acquisition failures are content access failures',
      () async {
        access.acquireFailure = StateError('private database error');
        final result = await manager.executeTool(
          name: 'Read',
          input: {'path': '/works/work_target/chapters'},
        );
        expect(result['error_code'], 'unavailable');
        expect(result['path'], '/works/work_target');
        expect(result.toString(), isNot(contains('private database error')));
        expect(result.toString(), isNot(contains('/_schema')));
      },
    );

    test(
      'volume queries stay scoped even when work-local IDs coincide',
      () async {
        final currentVolume = await currentService.createVolume(title: '当前卷');
        final targetVolume = await targetService.createVolume(title: '目标卷');
        expect(currentVolume, targetVolume);
        await currentService.createChapter(
          siblingOrder: 1,
          parentId: currentVolume,
          title: '当前卷章节',
        );
        await targetService.createChapter(
          siblingOrder: 1,
          parentId: targetVolume,
          title: '目标卷章节',
        );
        for (final (work, title) in [
          ('work_current', '当前卷章节'),
          ('work_target', '目标卷章节'),
        ]) {
          final result = await manager.executeTool(
            name: 'Read',
            input: {'path': '/works/$work/chapters?volume_id=$currentVolume'},
          );
          expect(result['error'], isNull, reason: '$result');
          final entry = (result['entries'] as List).single;
          expect(entry['title'], title);
          expect(entry['volume_id'], currentVolume);
          expect(entry['work_id'], work);
          expect(entry['path'], '/works/$work/chapters/${entry['id']}');
        }
      },
    );

    test('Read discovers works and prefixes target resource paths', () async {
      final listing = await manager.executeTool(
        name: 'Read',
        input: {'path': '/works'},
      );
      expect(listing['path'], '/works');
      final workEntry = (listing['entries'] as List<dynamic>).single;
      expect(workEntry['id'], 'work_target');
      expect(workEntry, isNot(contains('work_id')));
      expect(workEntry['title'], '目标作品');
      expect(workEntry['author_name'], '作者');
      expect(workEntry['path'], '/works/work_target');

      final chapters = await manager.executeTool(
        name: 'Read',
        input: {'path': '/works/work_target/chapters'},
      );
      expect(chapters['work_id'], 'work_target');
      expect(chapters['path'], '/works/work_target/chapters');
      final entries = chapters['entries'] as List<dynamic>;
      expect(entries.single['work_id'], 'work_target');
      expect(
        entries.single['path'],
        '/works/work_target/chapters/$targetChapterId',
      );

      final profile = await manager.executeTool(
        name: 'Read',
        input: {'path': '/works/work_target/profile/title'},
      );
      expect(profile['value'], '目标作品');
      expect(profile['path'], '/works/work_target/profile/title');

      final storyState = await manager.executeTool(
        name: 'Read',
        input: {'path': '/works/work_target/story_state'},
      );
      expect(storyState['content'], '源作品累积状态');
      expect(storyState['path'], '/works/work_target/story_state');

      final root = await manager.executeTool(
        name: 'Read',
        input: {'path': '/works/work_target'},
      );
      final rootEntries = root['entries'] as List<dynamic>;
      expect(
        rootEntries.where((entry) => entry['collection'] == 'works'),
        isEmpty,
      );
    });

    test(
      'item ID paths preserve work scope for listing, search and writes',
      () async {
        for (final entry in const {
          'skills': 'skill',
          'items': 'item',
          'factions': 'faction',
          'creatures': 'creature',
        }.entries) {
          final localId = await currentService.createItem(
            type: entry.value,
            title: '同名',
            content: '本地正文',
          );
          final targetId = await targetService.createItem(
            type: entry.value,
            title: '同名',
            content: '来源正文',
          );
          final targetPath = '/works/work_target/${entry.key}/$targetId';
          final listing = await manager.executeTool(
            name: 'Read',
            input: {'path': '/works/work_target/${entry.key}?search=同名'},
          );
          expect(
            (listing['entries'] as List).single,
            containsPair('path', targetPath),
          );
          final detail = await manager.executeTool(
            name: 'Read',
            input: {'path': targetPath},
          );
          expect(detail['id'], targetId);
          expect(detail['content'], '来源正文');
          final glob = await manager.executeTool(
            name: 'Glob',
            input: {'pattern': '/works/work_target/${entry.key}/*/content'},
          );
          expect(glob['matches'], ['$targetPath/content']);
          for (final operation in ['Write', 'Edit', 'Remove']) {
            final result = await manager.executeTool(
              name: operation,
              input: {
                'path': targetPath,
                if (operation == 'Write') 'fields': {'content': '篡改'},
                if (operation == 'Edit') ...{
                  'old_text': '来源',
                  'new_text': '篡改',
                },
              },
            );
            expect(result['error'], isNotNull, reason: '$operation: $result');
          }
          expect((await targetService.getItemById(targetId))!.content, '来源正文');
          expect((await currentService.getItemById(localId))!.content, '本地正文');
        }
      },
    );

    test(
      'character skill references preserve relative and absolute work scope',
      () async {
        final localCharacter = await currentService.createCharacterProfile(
          name: '角色',
        );
        final remoteCharacter = await targetService.createCharacterProfile(
          name: '角色',
        );
        final localSkill = await currentService.createItem(
          type: 'skill',
          title: '技能',
          content: '当前技能',
        );
        final remoteSkill = await targetService.createItem(
          type: 'skill',
          title: '技能',
          content: '目标技能',
        );
        expect(localCharacter, remoteCharacter);
        expect(localSkill, remoteSkill);
        for (final service in [currentService, targetService]) {
          await service.entityRelationsService.createRelation(
            sourceType: 'character',
            sourceId: localCharacter,
            targetType: 'skill',
            targetId: localSkill,
            relationType: 'mastered',
            proof: 'Read skills/literal',
          );
        }
        for (final prefix in [
          '',
          '/works/work_current/',
          '/works/work_target/',
        ]) {
          for (final suffix in ['', '/skills']) {
            final result = await manager.executeTool(
              name: 'Read',
              input: {'path': '${prefix}characters/$localCharacter$suffix'},
            );
            final skills = result[suffix.isEmpty ? 'skills' : 'value'] as List;
            final path = skills.single['path'];
            expect(path, '${prefix}skills/$localSkill');
            final read = await manager.executeTool(
              name: 'Read',
              input: {'path': path},
            );
            expect(
              read['content'],
              prefix.contains('work_target') ? '目标技能' : '当前技能',
            );
          }
        }
      },
    );

    test(
      'cross-work recovery hints keep the target collection and outline',
      () async {
        await targetService.outlineService.createOutline(defaultTitle: '主线');
        await targetService.canvasService.createCanvas(name: '图');
        for (final sample in {
          'chapters/ch_missing': 'chapters',
          'characters/char_missing': 'characters',
          'skills/skill_missing': 'skills',
          'lore/缺失': 'lore',
          'outlines/缺失': 'outlines',
          'canvas/缺失': 'canvas',
          'canvas/图/nodes/node_missing': 'canvas/图/nodes',
          'outlines/主线/beats/beat_missing': 'outlines/主线/beats',
          'outlines/主线/beats/0': 'outlines/主线/beats',
        }.entries) {
          final result = await manager.executeTool(
            name: 'Read',
            input: {'path': '/works/work_target/${sample.key}'},
          );
          expect(result['error'], isNotNull, reason: '${sample.key}: $result');
          expect(
            result['hint'],
            contains(
              !ideationCanvasEnabled && sample.key.startsWith('canvas/')
                  ? 'Read /works/work_target and Read /_schema'
                  : 'Read /works/work_target/${sample.value}',
            ),
            reason: '$result',
          );
        }
      },
    );

    test('absolute search keeps literal prose and pagination unchanged', () async {
      const body =
          '/灯光熄灭\nchapters and scenes are ordinary words.\nRead outlines/main.';
      await targetService.updateChapterContent(
        chapterId: targetChapterId,
        title: 'chapters',
        outline: '',
        content: body,
      );
      final grep = await manager.executeTool(
        name: 'Grep',
        input: {
          'path': '/works/work_target/chapters/$targetChapterId/content',
          'pattern': '.',
        },
      );
      expect(
        grep['text'],
        '/works/work_target/chapters/$targetChapterId/content:1:/灯光熄灭\n'
        '/works/work_target/chapters/$targetChapterId/content:2:chapters and scenes are ordinary words.\n'
        '/works/work_target/chapters/$targetChapterId/content:3:Read outlines/main.\n',
      );
      final glob = await manager.executeTool(
        name: 'Glob',
        input: {'path': '/works/work_target/chapters', 'pattern': '**/content'},
      );
      for (final path in glob['matches'] as List) {
        final read = await manager.executeTool(
          name: 'Read',
          input: {'path': path},
        );
        expect(read['value'], body);
      }
      final paged = await manager.executeTool(
        name: 'Read',
        input: {
          'path': '/works/work_target/chapters/$targetChapterId/content',
          'limit': 1,
        },
      );
      expect(paged['value'], '/灯光熄灭');
      expect(paged['total_lines'], 3);
      expect(paged['next_offset'], 1);
      expect(paged['has_more'], true);
      final listing = await manager.executeTool(
        name: 'Read',
        input: {
          'path': '/works/work_target/chapters?search=chapters',
          'limit': 1,
        },
      );
      expect((listing['entries'] as List).single['title'], 'chapters');
      expect((listing['entries'] as List).single['id'], targetChapterId);
      expect(listing['total'], 1);
      expect(listing['has_more'], false);
    });

    test(
      'absolute Replace preserves samples and serializes failed references',
      () async {
        await currentService.updateChapterContent(
          chapterId: currentChapterId,
          title: '当前',
          outline: '',
          content: 'chapters /灯光熄灭 scenes',
        );
        final preview = await manager.executeTool(
          name: 'Replace',
          input: {
            'path': '/works/work_current/chapters/$currentChapterId/content',
            'pattern': 'chapters',
            'replacement': 'outlines',
          },
        );
        expect(preview['samples'], ['chapters / 1']);
        await currentService.updateChapterStat(
          chapterId: currentChapterId,
          stat: chapterStatPublished,
        );
        final result = await manager.executeTool(
          name: 'Replace',
          input: {
            'path': '/works/work_current/chapters/$currentChapterId/content',
            'pattern': 'chapters',
            'replacement': 'outlines',
            'dry_run': false,
          },
        );
        expect(result['applied_fields'], 0);
        expect(result['failed']['locked']['sample_paths'], [
          '/works/work_current/chapters/$currentChapterId/content',
        ]);
      },
    );

    test(
      'relative and current absolute edits produce full matching previews',
      () async {
        final previews = <Map<String, dynamic>?>[];
        final previewManager = AiToolManager(
          currentService,
          workingOverlayService: manager.workingOverlayService,
          crossWorkAccess: access,
          onToolStarted: (_, _, _, extra, _) => previews.add(extra),
        )..registerAllTools();
        addTearDown(previewManager.dispose);
        for (final prefix in ['', '/works/work_current/']) {
          await previewManager.executeTool(
            name: 'Edit',
            input: {
              'path': '${prefix}chapters/$currentChapterId/content',
              'old_text': prefix.isEmpty ? '当前作品' : '新作品',
              'new_text': prefix.isEmpty ? '新作品' : '当前作品',
            },
          );
        }
        expect(previews.first?['diffOldText'], '当前第一行\n当前作品线索');
        expect(previews.first?['diffNewText'], '当前第一行\n新作品线索');
        expect(previews.last?['diffOldText'], previews.first?['diffNewText']);
        expect(previews.last?['diffNewText'], previews.first?['diffOldText']);
        expect(
          previews.last?['targetPath'],
          '/works/work_current/chapters/$currentChapterId/content',
        );
      },
    );

    test('Glob and Grep stay inside one target work', () async {
      final glob = await manager.executeTool(
        name: 'Glob',
        input: {
          'pattern': '/works/work_target/chapters/*/content',
          'path': '/works/work_target/chapters',
        },
      );
      expect(glob['work_id'], 'work_target');
      expect(glob['matches'], [
        '/works/work_target/chapters/$targetChapterId/content',
      ]);

      final grep = await manager.executeTool(
        name: 'Grep',
        input: {
          'pattern': '跨作品线索',
          'path': '/works/work_target/chapters/$targetChapterId/content',
        },
      );
      expect(grep['work_id'], 'work_target');
      expect(
        grep['text'],
        '/works/work_target/chapters/$targetChapterId/content:2:跨作品线索\n',
      );
    });

    test(
      'relation history paths stay in the target work and all mutations remain denied',
      () async {
        final id = await targetService.entityRelationsService.createRelation(
          sourceType: 'character',
          sourceId: 'a',
          targetType: 'character',
          targetId: 'b',
          relationType: 'friend',
          proof: 'target',
        );
        final change = await targetService.entityRelationsService.recordChange(
          id: id,
          status: 'ended',
          proof: 'ended',
          reason: 'ended',
        );
        final base = '/works/work_target/relations/$id';
        final detail = await manager.executeTool(
          name: 'Read',
          input: {'path': base},
        );
        expect(detail['history_path'], '$base/change_logs');
        final history = await manager.executeTool(
          name: 'Read',
          input: {'path': detail['history_path']},
        );
        final entries = history['entries'] as List;
        expect(entries.first['path'], '$base/change_logs/${change.changeId}');
        expect(entries.first['parent_path'], base);
        expect(entries.first['work_id'], 'work_target');
        final one = await manager.executeTool(
          name: 'Read',
          input: {'path': entries.first['path']},
        );
        expect(one['id'], change.changeId);
        expect(one['path'], entries.first['path']);
        expect(
          (await manager.executeTool(
            name: 'Read',
            input: {'path': '$base/status'},
          ))['value'],
          'ended',
        );
        for (final request in [
          (
            'Write',
            {
              'path': base,
              'fields': {'status': 'active', 'reason': 'r', 'proof': 'p'},
            },
          ),
          (
            'Edit',
            {'path': '$base/status', 'old_text': 'ended', 'new_text': 'active'},
          ),
          ('Remove', {'path': entries.first['path'], 'force': true}),
        ]) {
          final denied = await manager.executeTool(
            name: request.$1,
            input: request.$2,
          );
          expect(denied['error_code'], 'permission_denied');
        }
        expect(
          (await targetService.entityRelationsService.getRelationById(
            id,
          ))!.changeLogs,
          hasLength(2),
        );
      },
    );

    test(
      'current-work absolute relation mutations return stable scoped references',
      () async {
        final id = await currentService.entityRelationsService.createRelation(
          sourceType: 'character',
          sourceId: 'a',
          targetType: 'character',
          targetId: 'b',
          relationType: 'friend',
          proof: 'p',
        );
        final base = '/works/work_current/relations/$id';
        final written = await manager.executeTool(
          name: 'Write',
          input: {
            'path': base,
            'fields': {
              'relation_type': 'enemy',
              'proof': 'changed',
              'reason': 'changed',
            },
          },
        );
        expect(written['path'], base);
        expect(written['history_path'], '$base/change_logs');
        final edited = await manager.executeTool(
          name: 'Edit',
          input: {
            'path': '$base/status',
            'old_text': 'active',
            'new_text': 'ended',
          },
        );
        expect(edited['status'], 'ended');
        expect(edited['history_appended'], isFalse);
        expect(written, isNot(contains('change_id')));
        final history = await manager.executeTool(
          name: 'Read',
          input: {'path': '$base/change_logs'},
        );
        final latest = (history['entries'] as List).first as Map;
        final path = latest['path'] as String;
        final removed = await manager.executeTool(
          name: 'Remove',
          input: {'path': path},
        );
        expect(removed['path'], path);
        expect(removed['id'], latest['id']);
        expect(removed['relation']['id'], id);
        expect(removed['relation']['path'], base);
        expect(removed['relation']['history_path'], '$base/change_logs');
        expect(removed['relation']['status'], 'active');
      },
    );

    test('GraphSearch accepts work_id and annotates relation paths', () async {
      final relationId = await targetService.entityRelationsService
          .createRelation(
            sourceType: 'character',
            sourceId: 'character_source',
            targetType: 'character',
            targetId: 'character_target',
            relationType: 'friend',
            proof: '/灯光熄灭 chapters and scenes; Read outlines/main.',
          );

      final result = await manager.executeTool(
        name: 'GraphSearch',
        input: {
          'type': 'character',
          'id': 'character_source',
          'work_id': 'work_target',
        },
      );

      expect(result['work_id'], 'work_target');
      final layers = result['layers'] as List<dynamic>;
      final relations = layers.single['relations'] as List<dynamic>;
      expect(relations.single['work_id'], 'work_target');
      expect(
        relations.single['proof'],
        '/灯光熄灭 chapters and scenes; Read outlines/main.',
      );
      expect(
        relations.single['path'],
        '/works/work_target/relations/$relationId',
      );
    });

    test('GraphSearch without work_id keeps current paths', () async {
      final relationId = await currentService.entityRelationsService
          .createRelation(
            sourceType: 'character',
            sourceId: 'character_current',
            targetType: 'character',
            targetId: 'character_peer',
            relationType: 'friend',
            proof: '同作品关系',
          );
      final result = await manager.executeTool(
        name: 'GraphSearch',
        input: {'type': 'character', 'id': 'character_current'},
      );

      expect(result.containsKey('work_id'), isFalse);
      expect(result['start_entity_id'], 'character_current');
      final layers = result['layers'] as List<dynamic>;
      final relations = layers.single['relations'] as List<dynamic>;
      expect(relations.single.containsKey('work_id'), isFalse);
      expect(relations.single['path'], 'relations/$relationId');
      expect(access.acquireCount, 0);
    });

    test('all mutating tools accept the current work absolute path', () async {
      final created = await manager.executeTool(
        name: 'Create',
        input: {
          'path': '/works/work_current/chapters',
          'fields': {'title': '当前作品新章', 'content': '新章正文'},
        },
      );
      expect(created['created'], isTrue);
      expect(created['path'], startsWith('/works/work_current/chapters/'));

      final write = await manager.executeTool(
        name: 'Write',
        input: {
          'path': '/works/work_current/chapters/$currentChapterId/title',
          'value': '当前作品第一章（改）',
        },
      );
      expect(write['error_code'], isNull);
      expect(
        write['path'],
        '/works/work_current/chapters/$currentChapterId/title',
      );

      final edit = await manager.executeTool(
        name: 'Edit',
        input: {
          'path': '/works/work_current/chapters/$currentChapterId/content',
          'old_text': '当前第一行',
          'new_text': '修改后的第一行',
        },
      );
      expect(edit['error_code'], isNull);
      expect(
        edit['path'],
        '/works/work_current/chapters/$currentChapterId/content',
      );

      final replace = await manager.executeTool(
        name: 'Replace',
        input: {
          'pattern': '当前作品',
          'replacement': '本作',
          'glob': '/works/work_current/chapters/*/content',
        },
      );
      expect(replace['ok'], isTrue);
      expect(replace['matched_fields'], greaterThan(0));
      expect(replace['work_id'], 'work_current');

      final removed = await manager.executeTool(
        name: 'Remove',
        input: {'path': created['path']},
      );
      expect(removed['ok'], isTrue);
      expect(removed['path'], created['path']);
      expect(access.acquireCount, 0);
    });

    test('all mutating tools reject works scope before reading', () async {
      final cases = <(String, Map<String, dynamic>)>[
        (
          'Create',
          {
            'path': '/works/work_target/chapters',
            'fields': {'title': '不能创建'},
          },
        ),
        (
          'Write',
          {
            'path': '/works/work_target/chapters/$targetChapterId/content',
            'value': '不能覆盖',
          },
        ),
        (
          'Edit',
          {
            'path': '/works/work_target/chapters/$targetChapterId/content',
            'old_text': '第一行',
            'new_text': '不能替换',
          },
        ),
        (
          'Replace',
          {
            'pattern': '第一行',
            'replacement': '不能批量替换',
            'glob': '/works/work_target/chapters/*/content',
          },
        ),
        ('Remove', {'path': '/works/work_target/chapters/$targetChapterId'}),
      ];

      for (final testCase in cases) {
        final result = await manager.executeTool(
          name: testCase.$1,
          input: testCase.$2,
        );
        expect(result['error_code'], 'permission_denied', reason: testCase.$1);
        expect(
          result['error'],
          '${testCase.$1} can only modify the current work.',
        );
        expect(result['hint'], contains('/works/work_current/…'));
      }
      expect(access.acquireCount, 0);
    });

    test('broad or conflicting work search is rejected', () async {
      final broadGlob = await manager.executeTool(
        name: 'Glob',
        input: {'pattern': '/works/**/chapters/*'},
      );
      final broadGrep = await manager.executeTool(
        name: 'Grep',
        input: {'pattern': '线索', 'path': '/works'},
      );
      final conflict = await manager.executeTool(
        name: 'Glob',
        input: {
          'pattern': '/works/work_other/chapters/*',
          'path': '/works/work_target',
        },
      );
      final nonLeadingWorks = await manager.executeTool(
        name: 'Glob',
        input: {'pattern': 'lore/works/**'},
      );

      expect(broadGlob['error_code'], 'invalid_argument');
      expect(broadGrep['error_code'], 'invalid_argument');
      expect(conflict['error_code'], 'invalid_argument');
      expect(nonLeadingWorks['error_code'], isNot('invalid_argument'));
      expect(access.acquireCount, 0);
    });

    test(
      'question-mark work patterns never open a truncated work id',
      () async {
        for (final workPattern in ['work_targe?', 'work_?arget', '?']) {
          final result = await manager.executeTool(
            name: 'Glob',
            input: {'pattern': '/works/$workPattern/chapters/*'},
          );
          expect(result['error_code'], 'invalid_argument', reason: '$result');
        }
        expect(access.acquireCount, 0);
      },
    );

    test('unknown work returns work_not_found', () async {
      final result = await manager.executeTool(
        name: 'Read',
        input: {'path': '/works/missing/chapters'},
      );

      expect(result['error_code'], 'not_found');
      expect(result['path'], '/works/missing');
    });
  });

  group('cross-work lease lifecycle', () {
    late NovelContentDatabase currentDatabase;
    late NovelContentDatabase targetDatabase;
    late AppDatabase appDatabase;
    late _FakeCrossWorkAccess access;
    late AiToolManager manager;

    setUp(() {
      currentDatabase = NovelContentDatabase.forTest(NativeDatabase.memory());
      targetDatabase = NovelContentDatabase.forTest(NativeDatabase.memory());
      appDatabase = AppDatabase.forTest(NativeDatabase.memory());
      final currentService = NovelContentService(currentDatabase);
      access = _FakeCrossWorkAccess(
        NovelContentService(targetDatabase),
        acquireGate: Completer<void>(),
      );
      manager = AiToolManager(
        currentService,
        workingOverlayService: WorkingOverlayService(
          currentDatabase,
          currentService,
          novelActionsService: NovelActionsService(appDatabase),
        ),
        crossWorkAccess: access,
      )..registerAllTools();
    });

    tearDown(() async {
      manager.dispose();
      if (!(access.acquireGate?.isCompleted ?? true)) {
        access.acquireGate!.complete();
      }
      await Future<void>.delayed(Duration.zero);
      await currentDatabase.close();
      await targetDatabase.close();
      await appDatabase.close();
    });

    test(
      'concurrent reads share one acquisition and dispose releases once',
      () async {
        final first = manager.executeTool(
          name: 'Read',
          input: {'path': '/works/work_target/chapters'},
        );
        final second = manager.executeTool(
          name: 'Read',
          input: {'path': '/works/work_target/characters'},
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(access.acquireCount, 1);
        access.acquireGate!.complete();
        await Future.wait([first, second]);
        expect(access.releaseCount, 0);

        manager.dispose();
        manager.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(access.releaseCount, 1);
      },
    );

    test(
      'dispose while acquisition is pending releases on completion',
      () async {
        final pending = manager.executeTool(
          name: 'Read',
          input: {'path': '/works/work_target/chapters'},
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(access.acquireCount, 1);

        manager.dispose();
        access.acquireGate!.complete();
        final result = await pending;

        expect(result['error_code'], 'unavailable');
        expect(access.releaseCount, 1);
      },
    );
  });

  group('CrossWorkResolver', () {
    test(
      'resolver failures retain their classification through the complete Read chain',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'reveric_work_errors_',
        );
        addTearDown(() => temp.delete(recursive: true));
        final app = AppDatabase.forTest(NativeDatabase.memory());
        addTearDown(app.close);
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        addTearDown(db.close);
        final service = NovelContentService(db);
        final overlay = WorkingOverlayService(
          db,
          service,
          novelActionsService: NovelActionsService(app),
        );
        final present = File('${temp.path}/present.sqlite');
        await present.writeAsBytes([]);
        for (final id in [
          'missing_path',
          'missing_file',
          'open_failure',
          'draft',
          'deleted',
        ]) {
          await app.novelDao.create(
            id: id,
            title: id,
            description: '',
            draft: id == 'draft',
            contentDatabasePath: id == 'missing_path'
                ? null
                : id == 'missing_file'
                ? '${temp.path}/missing.sqlite'
                : present.path,
          );
        }
        await app.novelDao.softDelete('deleted');
        final resolver = CrossWorkResolver(
          appDatabase: app,
          currentDatabasePath: '${temp.path}/current.sqlite',
          currentContentService: service,
          currentWorkId: 'current',
          databaseOpener: (_) => throw StateError('private opener failure'),
        );
        final manager = AiToolManager(
          service,
          workingOverlayService: overlay,
          crossWorkAccess: resolver,
        )..registerAllTools();
        addTearDown(manager.dispose);
        for (final id in [
          'absent',
          'draft',
          'deleted',
          'missing_path',
          'missing_file',
          'open_failure',
        ]) {
          final code = ['absent', 'draft', 'deleted'].contains(id)
              ? 'work_not_found'
              : 'work_unavailable';
          await expectLater(
            () => resolver.acquire(id),
            throwsA(
              isA<CrossWorkAccessException>().having(
                (e) => e.errorCode,
                'errorCode',
                code,
              ),
            ),
          );
          final result = await manager.executeTool(
            name: 'Read',
            input: {'path': '/works/$id/chapters'},
          );
          expect(
            result['error_code'],
            code == 'work_not_found' ? 'not_found' : 'unavailable',
            reason: id,
          );
          expect(result['path'], '/works/$id');
          expect(result.toString(), isNot(contains('/_schema')));
          expect(result.toString(), isNot(contains('private opener failure')));
          expect(
            result['hint'],
            code == 'work_not_found'
                ? contains('Read /works')
                : contains('temporarily unavailable'),
          );
        }
      },
    );

    test('filters discovery and opens a valid target database', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'reveric_cross_work_',
      );
      final targetPath = '${tempDirectory.path}/target.sqlite';
      final currentPath = '${tempDirectory.path}/current.sqlite';
      final missingPath = '${tempDirectory.path}/missing.sqlite';
      await File(currentPath).writeAsBytes([]);
      final targetDatabase = NovelContentDatabase(targetPath);
      final targetService = NovelContentService(targetDatabase);
      final chapterId = await targetService.createChapter(
        siblingOrder: 1,
        title: '可读取章节',
      );
      await targetDatabase.close();

      final appDatabase = AppDatabase.forTest(NativeDatabase.memory());
      final currentDatabase = NovelContentDatabase.forTest(
        NativeDatabase.memory(),
      );
      final currentService = NovelContentService(currentDatabase);
      await appDatabase.novelDao.create(
        id: 'work_target',
        title: '目标作品',
        description: '',
        contentDatabasePath: targetPath,
      );
      await appDatabase.novelDao.create(
        id: 'work_current',
        title: '当前作品',
        description: '',
        contentDatabasePath: currentPath,
        type: novelTypeAdaptation,
        contentKind: contentKindScreenplay,
        sourceNovelId: 'work_target',
      );
      await appDatabase.novelDao.create(
        id: 'work_draft',
        title: '草稿',
        description: '',
        contentDatabasePath: targetPath,
        draft: true,
      );
      await appDatabase.novelDao.create(
        id: 'work_missing',
        title: '缺失内容库',
        description: '',
        contentDatabasePath: missingPath,
      );
      final resolver = CrossWorkResolver(
        appDatabase: appDatabase,
        currentDatabasePath: currentPath,
        currentContentService: currentService,
        currentWorkId: 'work_current',
      );

      try {
        expect(resolver.currentWorkId, 'work_current');
        final works = await resolver.listWorks();
        expect(works, hasLength(2));
        expect(
          works.map((work) => work.workId),
          containsAll(<String>['work_current', 'work_target']),
        );
        expect(
          works
              .singleWhere((work) => work.workId == 'work_target')
              .toListingEntry(),
          containsPair('content_kind', 'novel'),
        );
        expect(
          works
              .singleWhere((work) => work.workId == 'work_target')
              .toListingEntry(),
          containsPair('relationship', novelTypeAdaptation),
        );

        final lease = await resolver.acquire('work_target');
        final chapter = await lease.service.getChapterById(chapterId);
        expect(chapter?.title, '可读取章节');
        lease.release();
        lease.release();
        expect(NovelContentDatabase.isCachedForTesting(targetPath), isFalse);

        expect(
          () => resolver.acquire('work_draft'),
          throwsA(
            isA<CrossWorkAccessException>().having(
              (error) => error.errorCode,
              'errorCode',
              'work_not_found',
            ),
          ),
        );
      } finally {
        await currentDatabase.close();
        await appDatabase.close();
        await tempDirectory.delete(recursive: true);
      }
    });
  });
}

class _FakeCrossWorkAccess implements CrossWorkAccess {
  _FakeCrossWorkAccess(this.targetService, {this.acquireGate});

  final NovelContentService targetService;
  final Completer<void>? acquireGate;
  int acquireCount = 0;
  int releaseCount = 0;
  String contentKind = contentKindNovel;
  Map<String, dynamic> extraMetadata = const {};
  Object? acquireFailure;

  @override
  String get currentWorkId => 'work_current';

  CrossWorkDescriptor get descriptor => CrossWorkDescriptor(
    workId: 'work_target',
    title: '目标作品',
    databasePath: 'target.sqlite',
    contentKind: contentKind,
    novelMetadata: {
      ...extraMetadata,
      'content_kind': contentKindNovel,
      'title': '目标作品',
      'author_name': '作者',
      'description': '简介',
      'category': '类型',
      'status': 'in_progress',
      'word_count': 3,
      'tags': <String>[],
    },
  );

  @override
  Future<CrossWorkLease> acquire(String workId) async {
    acquireCount += 1;
    if (acquireFailure != null) {
      throw acquireFailure!;
    }
    if (workId != descriptor.workId) {
      throw CrossWorkAccessException(
        'work_not_found',
        'Work was not found: $workId',
      );
    }
    await acquireGate?.future;
    return CrossWorkLease(
      work: descriptor,
      service: targetService,
      release: () {
        releaseCount += 1;
      },
    );
  }

  @override
  Future<List<CrossWorkDescriptor>> listWorks() async => [descriptor];
}

class _FailingCrossWorkAccess implements CrossWorkAccess {
  _FailingCrossWorkAccess(this.code);
  final String code;
  @override
  String get currentWorkId => 'current';
  @override
  Future<CrossWorkLease> acquire(String workId) async =>
      throw CrossWorkAccessException(code, 'Content temporarily unavailable.');
  @override
  Future<List<CrossWorkDescriptor>> listWorks() async =>
      throw StateError('Injected list failure');
}
