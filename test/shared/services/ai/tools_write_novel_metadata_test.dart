// 职责: 测试 Create/Write/Edit/Read 对作品元数据直写与回读，以及 Remove 拒绝删除。
// 关联文件:
//   lib/shared/services/ai/tools_write.dart
//   lib/shared/services/ai/tools_read.dart
//   lib/shared/services/ai/tools.dart

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  group('Write/Read novel metadata', () {
    late Directory tempSupport;
    late NovelContentDatabase db;
    late AppDatabase appDb;
    late NovelContentService contentService;
    late AiToolManager toolManager;
    late Map<String, dynamic> store;

    AiToolManager managerForStoredWork(String workId) {
      final actions = NovelActionsService(appDb);
      final manager = AiToolManager(
        contentService,
        workId: workId,
        workingOverlayService: WorkingOverlayService(
          db,
          contentService,
          novelActionsService: actions,
        ),
        novelReader: () async {
          final novel = (await actions.getNovel(workId))!;
          return {'title': novel.title, 'draft': novel.draft};
        },
        novelWriter: (fields) => actions.updateNovelMetadata(
          novelId: workId,
          title: fields['title'] as String?,
          draft: fields['draft'] as bool?,
        ),
      )..registerAllTools();
      addTearDown(manager.dispose);
      return manager;
    }

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      tempSupport = await Directory.systemTemp.createTemp(
        'reveric_write_novel_meta_',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async {
              if (call.method == 'getApplicationSupportDirectory') {
                return tempSupport.path;
              }
              return null;
            },
          );
      await RevericPaths.initialize();

      db = NovelContentDatabase.forTest(NativeDatabase.memory());
      appDb = AppDatabase.forTest(NativeDatabase.memory());
      contentService = NovelContentService(db);
      store = <String, dynamic>{
        'title': '未命名作品',
        'author_name': '',
        'description': '',
        'category': '',
        'status': 'in_progress',
        'draft': true,
        'tags': <String>[],
        'word_count': 0,
      };

      toolManager = AiToolManager(
        contentService,
        workId: 'current',
        workingOverlayService: WorkingOverlayService(
          db,
          contentService,
          novelActionsService: NovelActionsService(appDb),
        ),
        novelReader: () async =>
            Map<String, dynamic>.from(store)
              ..['tags'] = List<String>.from(store['tags'] as List),
        novelWriter: (fields) async {
          if (fields.containsKey('title')) {
            store['title'] = fields['title'];
          }
          if (fields.containsKey('author_name')) {
            store['author_name'] = fields['author_name'];
          }
          if (fields.containsKey('description')) {
            store['description'] = fields['description'];
          }
          if (fields.containsKey('category')) {
            store['category'] = fields['category'];
          }
          if (fields.containsKey('tags')) {
            store['tags'] = List<String>.from(fields['tags'] as List);
          }
          if (fields.containsKey('status')) {
            store['status'] = fields['status'];
          }
          if (fields.containsKey('draft')) {
            store['draft'] = fields['draft'];
          }
        },
      )..registerAllTools();
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await db.close();
      await appDb.close();
      if (await tempSupport.exists()) {
        await tempSupport.delete(recursive: true);
      }
    });

    test(
      'Write can add a work to the shelf but cannot return it to draft',
      () async {
        const title = '草稿书名';
        const draftPath = '/works/current/draft';
        await appDb.novelDao.create(
          id: 'current',
          title: title,
          description: '',
          draft: true,
        );
        final manager = managerForStoredWork('current');
        final draft = await manager.executeTool(
          name: 'Read',
          input: {'path': draftPath},
        );
        expect(draft['value'], isTrue);

        final published = await manager.executeTool(
          name: 'Write',
          input: {'path': draftPath, 'value': false},
        );
        expect(published['updated'], isTrue);
        expect(published['fields'], ['draft']);

        for (final input in [
          {'path': draftPath, 'value': true},
          {
            'path': '/works/current',
            'fields': {'title': '不应保存', 'draft': true},
          },
        ]) {
          final rejected = await manager.executeTool(
            name: 'Write',
            input: input,
          );
          expect(rejected['ok'], isFalse);
          expect(rejected['error_code'], 'permission_denied');
          expect(rejected['path'], input['path']);
          final onShelf = await appDb.novelDao.getShelfByTitle(title);
          expect(onShelf?.id, 'current');
          expect(onShelf?.draft, isFalse);
        }
      },
    );

    test(
      'Write author name, category and tags directly without working_change',
      () async {
        final authorResult = await toolManager.executeTool(
          name: 'Write',
          input: {'path': '/works/current/author_name', 'value': '辰东'},
          callId: 'call_write_novel_author_name',
        );
        expect(authorResult['error'], isNull);
        expect(authorResult['updated'], isTrue);
        expect(authorResult['fields'], contains('author_name'));
        expect(authorResult.containsKey('working_change_id'), isFalse);
        expect(store['author_name'], '辰东');

        final categoryResult = await toolManager.executeTool(
          name: 'Write',
          input: {'path': '/works/current/category', 'value': '玄幻'},
          callId: 'call_write_novel_category',
        );
        expect(categoryResult['error'], isNull);
        expect(categoryResult['updated'], isTrue);
        expect(categoryResult['fields'], contains('category'));
        expect(categoryResult.containsKey('working_change_id'), isFalse);
        expect(store['category'], '玄幻');

        final tagsResult = await toolManager.executeTool(
          name: 'Write',
          input: {'path': '/works/current/tags', 'value': '重生, 系统, 爽文'},
          callId: 'call_write_novel_tags',
        );
        expect(tagsResult['error'], isNull);
        expect(tagsResult['updated'], isTrue);
        expect(tagsResult['fields'], contains('tags'));
        expect(tagsResult.containsKey('working_change_id'), isFalse);
        expect(store['tags'], ['重生', '系统', '爽文']);
      },
    );

    test('status 直写落到 writer，不留成永远 apply 不了的 working change', () async {
      // 改前 status 走 _stageTextChange，返回 updated:true 却只记了一条 patch；
      // working overlay 的 novel 分支不 apply status，接受与否都不会落库。
      final result = await toolManager.executeTool(
        name: 'Write',
        input: {'path': '/works/current/status', 'value': 'finished'},
        callId: 'call_write_novel_status',
      );

      expect(result['error'], isNull);
      expect(result['updated'], isTrue);
      expect(result['fields'], contains('status'));
      expect(result.containsKey('working_change_id'), isFalse);
      expect(store['status'], 'finished');
    });

    test('status 拒绝枚举外的值', () async {
      final result = await toolManager.executeTool(
        name: 'Write',
        input: {'path': '/works/current/status', 'value': 'hiatus'},
        callId: 'call_write_novel_status_invalid',
      );

      expect(result['error_code'], 'invalid_argument');
      expect(result['enum_field'], 'status');
      expect(store['status'], 'in_progress');
    });

    test(
      'Write updates a work and rejects invalid fields atomically',
      () async {
        final written = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': '/works/current',
            'fields': {
              'title': '  新作品  ',
              'status': 'IN PROGRESS',
              'tags': '甲, 乙',
            },
          },
        );
        expect(written['updated'], isTrue);
        expect(store['title'], '新作品');
        expect(store['status'], 'in_progress');
        expect(store['tags'], ['甲', '乙']);
        final before = Map<String, dynamic>.from(store);
        for (final tool in ['Create', 'Write']) {
          final rejected = await toolManager.executeTool(
            name: tool,
            input: {
              'path': '/works/current',
              'fields': {'title': '不应保存', 'status': 'unknown'},
            },
          );
          expect(rejected['error_code'], 'invalid_argument');
          expect(store, before);
        }
        for (final path in ['/works/current', '/works/current/title']) {
          final result = await toolManager.executeTool(
            name: 'Remove',
            input: {'path': path, 'force': true, 'recursive': true},
          );
          expect(result['ok'], isFalse);
          expect(store, before);
        }
        expect(await db.select(db.workingChanges).get(), isEmpty);
      },
    );

    test('Read returns author name, category and comma-joined tags', () async {
      store['author_name'] = '天蚕土豆';
      store['category'] = '都市';
      store['tags'] = ['商战', '重生'];

      final authorName = await toolManager.executeTool(
        name: 'Read',
        input: {'path': '/works/current/author_name'},
        callId: 'call_read_novel_author_name',
      );
      expect(authorName['value'], '天蚕土豆');

      final category = await toolManager.executeTool(
        name: 'Read',
        input: {'path': '/works/current/category'},
        callId: 'call_read_novel_category',
      );
      expect(category['value'], '都市');

      final tags = await toolManager.executeTool(
        name: 'Read',
        input: {'path': '/works/current/tags'},
        callId: 'call_read_novel_tags',
      );
      expect(tags['value'], '商战, 重生');

      final all = await toolManager.executeTool(
        name: 'Read',
        input: {'path': '/works/current'},
        callId: 'call_read_novel_all',
      );
      expect(all['id'], 'current');
      expect(all['entries'], isA<List>());
      expect(all['author_name'], '天蚕土豆');
      expect(all['category'], '都市');
      expect(all['tags'], '商战, 重生');
    });

    test('batch Write keeps sibling metadata fields', () async {
      final result = await toolManager.executeTool(
        name: 'Write',
        input: {
          'path': '/works/current',
          'fields': {
            'title': '剑起苍穹',
            'author_name': '忘语',
            'category': '仙侠',
            'tags': '修真, 热血',
            'description': '一剑破万法。',
          },
        },
        callId: 'call_write_novel_batch',
      );
      expect(result['error'], isNull);
      expect(result['updated'], isTrue);
      expect(
        result['fields'],
        containsAll([
          'title',
          'author_name',
          'category',
          'tags',
          'description',
        ]),
      );
      expect(store['title'], '剑起苍穹');
      expect(store['author_name'], '忘语');
      expect(store['category'], '仙侠');
      expect(store['tags'], ['修真', '热血']);
      expect(store['description'], '一剑破万法。');
    });

    test(
      'Edit null novel description with empty old_text initializes the field',
      () async {
        store['description'] = null;

        final result = await toolManager.executeTool(
          name: 'Edit',
          input: {
            'path': '/works/current/description',
            'old_text': '',
            'new_text': '一剑破万法。',
          },
          callId: 'call_edit_novel_null_description',
        );

        expect(result['error'], isNull);
        expect(result['edited'], isTrue);
        expect(result['error_code'], isNull);
        expect(store['description'], '一剑破万法。');
      },
    );

    test(
      'Edit null novel description with non-empty old_text is not unknown_field',
      () async {
        store['description'] = null;

        final result = await toolManager.executeTool(
          name: 'Edit',
          input: {
            'path': '/works/current/description',
            'old_text': '旧简介',
            'new_text': '新简介',
          },
          callId: 'call_edit_novel_null_description_miss',
        );

        expect(result['error_code'], 'failed_precondition');
        expect(result['error'], isNot(contains('Unknown')));
        expect(result['error'], isNot(contains('not a text field')));
        expect(result['hint'], contains('empty string'));
      },
    );

    test(
      'title conflicts are recoverable through Write, Edit and Replace',
      () async {
        const currentId = 'current';
        const titlePath = '/works/current/title';
        const originalTitle = '旧书名';
        const takenTitle = '已有书名';
        const availableTitle = '新书名';
        await appDb.novelDao.create(
          id: currentId,
          title: originalTitle,
          description: '',
        );
        await appDb.novelDao.create(
          id: 'other',
          title: takenTitle,
          description: '',
        );
        final manager = managerForStoredWork(currentId);

        final write = await manager.executeTool(
          name: 'Write',
          input: {'path': titlePath, 'value': takenTitle},
        );
        expect(write['error_code'], 'already_exists');
        expect(write['error'], contains(takenTitle));
        expect(write['hint'], isNotEmpty);

        Future<Map<String, dynamic>> editTitle(String newTitle) =>
            manager.executeTool(
              name: 'Edit',
              input: {
                'path': titlePath,
                'old_text': originalTitle,
                'new_text': newTitle,
              },
            );

        final edit = await editTitle(takenTitle);
        expect(edit['ok'], isFalse);
        expect(edit['error_code'], 'already_exists');
        expect(edit['error'], write['error']);
        expect(edit['hint'], write['hint']);
        expect(edit['path'], titlePath);
        expect(edit['operation'], 'edit');

        final replace = await manager.executeTool(
          name: 'Replace',
          input: {
            'path': titlePath,
            'pattern': originalTitle,
            'replacement': takenTitle,
            'dry_run': false,
          },
        );
        expect(replace['applied_fields'], 0);
        expect(replace['failed'], {
          'already_exists': {
            'count': 1,
            'sample_paths': [titlePath],
          },
        });
        expect((await appDb.novelDao.get(currentId))!.title, originalTitle);

        final retry = await editTitle(availableTitle);
        expect(retry['edited'], isTrue);
        expect((await appDb.novelDao.get(currentId))!.title, availableTitle);
        expect((await appDb.novelDao.get('other'))!.title, takenTitle);
      },
    );

    test('Edit author name directly without working_change', () async {
      store['author_name'] = '旧笔名';

      final result = await toolManager.executeTool(
        name: 'Edit',
        input: {
          'path': '/works/current/author_name',
          'old_text': '旧笔名',
          'new_text': '新笔名',
        },
        callId: 'call_edit_novel_author_name',
      );

      expect(result['error'], isNull);
      expect(result['edited'], isTrue);
      expect(result.containsKey('working_change_id'), isFalse);
      expect(store['author_name'], '新笔名');
    });

    test(
      'rejects the retired profile path and returns the canonical work path',
      () async {
        final result = await toolManager.executeTool(
          name: 'Read',
          input: {'path': '/works/current/title'},
        );

        final legacy = await toolManager.executeTool(
          name: 'Read',
          input: {'path': 'profile/title'},
        );
        expect(legacy['error_code'], 'invalid_argument');
        expect(result['value'], store['title']);
        expect(result['path'], '/works/current/title');
      },
    );
  });
}
