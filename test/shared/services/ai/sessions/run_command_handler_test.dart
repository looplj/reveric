// 职责: 验证会话命令的作品边界、过滤、稳定分页与错误契约。
// 关联文件:
//   lib/shared/services/ai/sessions/run_command_handler.dart
//   lib/shared/database/daos/ai_chat_session_dao.dart
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/ai_message_block.dart';
import 'package:reveric/shared/services/ai/sessions/run_command_handler.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_content.dart';

void main() {
  late AppDatabase app;
  late NovelContentDatabase first;
  late NovelContentDatabase second;
  late _Access access;
  late SessionsRunCommandHandler handler;
  setUp(() async {
    app = AppDatabase.forTest(NativeDatabase.memory());
    first = NovelContentDatabase.forTest(NativeDatabase.memory());
    second = NovelContentDatabase.forTest(NativeDatabase.memory());
    access = _Access({'w1': first, 'w2': second});
    handler = SessionsRunCommandHandler(
      database: app,
      access: access,
      workId: 'w1',
    );
    for (final work in ['w1', 'w2']) {
      await app.novelDao.create(id: work, title: work, description: '');
    }
    for (final id in ['a', 'b']) {
      await app.aiChatSessionDao.upsert(
        id: id,
        novelId: 'w1',
        title: 'Untitled $id',
        parentId: id == 'b' ? 'a' : null,
      );
    }
    await app.aiChatSessionDao.upsert(
      id: 'foreign',
      novelId: 'w2',
      title: 'Foreign',
    );
  });
  tearDown(() async {
    await first.close();
    await second.close();
    await app.close();
  });
  Future<void> message(
    String id, {
    String session = 'a',
    String content = 'text',
    String role = 'user',
    String type = 'text',
    int sequence = 0,
    List<AiMessageBlock>? blocks,
  }) async {
    await first.aiChatMessageDao.upsertSessionMessages(
      messages: [
        AiChatMessagesCompanion.insert(
          id: id,
          sessionId: session,
          role: role,
          type: Value(type),
          content: Value(content),
          sequence: Value(sequence),
          blocks: Value(blocks),
          createdAt: Value(DateTime.utc(2026)),
        ),
      ],
    );
  }

  List<dynamic> items(Map<String, dynamic> r) {
    expect(r['ok'], true, reason: '$r');
    return (r['data'] as Map)['items'] as List;
  }

  test(
    'list includes children and every mode with literal titles and tie pagination',
    () async {
      for (final mode in ['council', 'monologue', 'theater', 'roleplay']) {
        await app.aiChatSessionDao.upsert(
          id: mode,
          novelId: 'w1',
          title: '100%_$mode',
          mode: mode,
        );
      }
      final all = <String>[];
      String? cursor;
      do {
        final r = await handler.run('list', {'limit': 2, 'cursor': ?cursor});
        all.addAll(items(r).map((e) => e['id'] as String));
        cursor = (r['data'] as Map)['next_cursor'] as String?;
      } while (cursor != null);
      expect(all.toSet(), {
        'a',
        'b',
        'council',
        'monologue',
        'theater',
        'roleplay',
      });
      expect(all.length, 6);
      expect(items(await handler.run('list', {'query': '%_'})).length, 4);
      expect(
        items(await handler.run('list', {'parent_id': 'a'})).single['id'],
        'b',
      );
    },
  );
  test(
    'explicit reads need no active session; work and message ownership are enforced',
    () async {
      await message('m');
      expect(
        items(await handler.run('read', {'session_id': 'a'})).single['id'],
        'm',
      );
      expect(
        (await handler.run('read', {'session_id': 'foreign'}))['error_code'],
        'not_found',
      );
      expect(
        items(
          await handler.run('read', {'work_id': 'w2', 'session_id': 'foreign'}),
        ),
        isEmpty,
      );
      expect(
        (await handler.run('get', {
          'session_id': 'b',
          'id': 'm',
        }))['error_code'],
        'not_found',
      );
      expect((await handler.run('read', {}))['error_code'], 'invalid_argument');
      expect(
        (await handler.run('list', {'work_id': 'missing'}))['error_code'],
        'not_found',
      );
      expect(access.active, 0);
    },
  );
  test('source and current follow each invocation', () async {
    await message('parent');
    await message('child', session: 'b');
    expect(
      items(
        await handler.run(
          'read',
          {},
          currentSessionId: 'b',
          sourceSessionId: 'a',
        ),
      ).single['id'],
      'parent',
    );
    expect(
      items(
        await handler.run(
          'read',
          {'scope': 'current'},
          currentSessionId: 'b',
          sourceSessionId: 'a',
        ),
      ).single['id'],
      'child',
    );
  });
  test(
    'sparse work search scans past 200 and excludes invalid owners',
    () async {
      for (var i = 0; i < 205; i++) {
        await message('m$i', content: 'unrelated');
      }
      await message('zmatch', session: 'b', content: 'literal %_[');
      await message('zforeign', session: 'foreign', content: 'literal %_[');
      await message('zorphan', session: 'orphan', content: 'literal %_[');
      await app.aiChatSessionDao.upsert(
        id: 'deleted',
        novelId: 'w1',
        title: 'deleted',
      );
      await message('zdeleted', session: 'deleted', content: 'literal %_[');
      await app.aiChatSessionDao.softDelete('deleted');
      final r = await handler.run('search', {
        'scope': 'work',
        'query': '%_[',
        'order': 'asc',
        'limit': 1,
      });
      final found = items(r);
      expect(found.length, 1);
      expect(found.single['id'], 'zmatch');
      expect(found.single['session_id'], 'b');
      expect(found.single['session_title'], 'Untitled b');
      expect((r['data'] as Map)['has_more'], false);
      expect(access.active, 0);
    },
  );
  test(
    'filters tools within mixed messages and resumes Unicode content without losing tail',
    () async {
      final long = '😀' * 2401;
      await message(
        'mixed',
        role: 'assistant',
        content: 'body',
        blocks: [
          const AiTextBlock(id: 'text', text: 'body'),
          const AiThinkingBlock(id: 'thought', text: 'secret'),
          const AiToolCallBlock(
            id: 'success',
            callId: 'c1',
            toolName: 'Read',
            arguments: {'q': 'needle'},
            status: AiToolCallStatus.success,
          ),
          AiToolCallBlock(
            id: 'error',
            callId: 'c2',
            toolName: 'Run',
            arguments: {},
            result: {'detail': long},
            status: AiToolCallStatus.error,
          ),
        ],
      );
      final base = {
        'session_id': 'a',
        'tool_status': 'error',
        'max_chars': 1000,
      };
      final texts = <String>[];
      String? cursor;
      do {
        final r = await handler.run('read', {...base, 'cursor': ?cursor});
        final parts = items(r).single['parts'] as List;
        expect(parts.single['id'], 'error');
        expect(parts.single['part_index'], 2);
        texts.add(parts.single['text'] as String);
        cursor = (r['data'] as Map)['next_cursor'] as String?;
      } while (cursor != null);
      expect(texts.join(), contains(long));
      expect(texts.length, 3);
      final normal = items(await handler.run('read', {'session_id': 'a'}));
      expect((normal.single['parts'] as List).single['text'], 'body');
      final search = items(
        await handler.run('search', {
          'session_id': 'a',
          'query': 'needle',
          'kinds': ['tool'],
        }),
      );
      expect((search.single['parts'] as List).single['id'], 'success');
    },
  );
  test(
    'message limit and same-time keys do not repeat or skip messages',
    () async {
      for (final id in ['c', 'a', 'b']) {
        await message(id);
      }
      for (final order in ['asc', 'desc']) {
        final result = <String>[];
        String? cursor;
        do {
          final r = await handler.run('read', {
            'session_id': 'a',
            'order': order,
            'limit': 1,
            'cursor': ?cursor,
          });
          result.addAll(items(r).map((e) => e['id'] as String));
          cursor = (r['data'] as Map)['next_cursor'] as String?;
        } while (cursor != null);
        expect(result, order == 'asc' ? ['a', 'b', 'c'] : ['c', 'b', 'a']);
      }
    },
  );
  test(
    'cursor rejects altered filters, missing blocks and malformed values',
    () async {
      await message(
        'long',
        role: 'assistant',
        blocks: [AiTextBlock(id: 'block', text: 'x' * 2001)],
      );
      final r = await handler.run('get', {
        'session_id': 'a',
        'id': 'long',
        'max_chars': 1000,
      });
      final cursor = (r['data'] as Map)['next_cursor'];
      expect(
        (await handler.run('get', {
          'session_id': 'a',
          'id': 'long',
          'cursor': cursor,
          'kinds': ['tool'],
        }))['error_code'],
        'invalid_argument',
      );
      await message(
        'long',
        role: 'assistant',
        blocks: [AiTextBlock(id: 'changed', text: 'x' * 2001)],
      );
      expect(
        (await handler.run('get', {
          'session_id': 'a',
          'id': 'long',
          'cursor': cursor,
        }))['error_code'],
        'invalid_argument',
      );
      expect(
        (await handler.run('read', {
          'session_id': 'a',
          'cursor': 'garbage',
        }))['error_code'],
        'invalid_argument',
      );
      expect(
        (await handler.run('get', {
          'session_id': 'a',
          'id': 'long',
          'block_id': 'missing',
        }))['error_code'],
        'not_found',
      );
      expect(access.active, 0);
    },
  );
  test(
    'get invalidates continuation when its explicitly selected block disappears',
    () async {
      await message(
        'long',
        role: 'assistant',
        blocks: [AiTextBlock(id: 'selected', text: 'x' * 2001)],
      );
      final options = {
        'session_id': 'a',
        'id': 'long',
        'block_id': 'selected',
        'max_chars': 1000,
      };
      final firstPage = await handler.run('get', options);
      expect(items(firstPage), hasLength(1));
      final cursor = (firstPage['data'] as Map)['next_cursor'];
      expect(cursor, isNotNull);

      await message(
        'long',
        role: 'assistant',
        blocks: [AiTextBlock(id: 'replacement', text: 'x' * 2001)],
      );
      expect(
        (await handler.run('get', {
          ...options,
          'cursor': cursor,
        }))['error_code'],
        'invalid_argument',
      );
      expect((await handler.run('get', options))['error_code'], 'not_found');
      expect(access.active, 0);
    },
  );

  test('invalid arguments never silently broaden query', () async {
    for (final options in <Map<String, dynamic>>[
      {'limit': 0},
      {'limit': 101},
      {'limit': '3'},
      {'kinds': []},
      {
        'kinds': ['thinking'],
      },
      {'scope': 'work', 'session_id': 'a'},
      {'scope': 'typo'},
      {'tool_status': 'done'},
      {
        'tool_name': 'Read',
        'kinds': ['user'],
      },
      {'max_chars': 999},
      {'query': ''},
      {'role': 'user'},
    ]) {
      expect(
        (await handler.run('search', {
          'query': 'x',
          ...options,
        }, currentSessionId: 'a'))['error_code'],
        'invalid_argument',
      );
    }
    final noWork = SessionsRunCommandHandler(database: app, access: access);
    expect((await noWork.run('list', {}))['error_code'], 'invalid_argument');
  });

  for (final (reason, expectedCode) in [
    ('work_unavailable', 'unavailable'),
    ('works_unavailable', 'unavailable'),
    ('work_not_found', 'not_found'),
    ('unsupported_content_kind', 'unsupported'),
  ]) {
    test('session access maps $reason to $expectedCode', () async {
      access.failure = CrossWorkAccessException(reason, 'Work access failed.');
      for (final action in ['read', 'search', 'get']) {
        final result = await handler.run(action, {
          'session_id': 'a',
          if (action == 'search') 'query': 'text',
          if (action == 'get') 'id': 'm',
        });
        expect(result['ok'], isFalse);
        expect(result['error_code'], expectedCode, reason: '$action: $result');
        expect(result['error'], 'Work access failed.');
        expect(result.containsKey('data'), isFalse);
        expect(access.active, 0);
      }
    });
  }
}

class _Access implements CrossWorkAccess {
  _Access(this.databases);
  final Map<String, NovelContentDatabase> databases;
  int active = 0;
  CrossWorkAccessException? failure;
  @override
  String get currentWorkId => 'w1';
  @override
  Future<List<CrossWorkDescriptor>> listWorks() async => [];
  @override
  Future<CrossWorkLease> acquire(String workId) async {
    if (failure != null) {
      throw failure!;
    }
    active++;
    return CrossWorkLease(
      work: CrossWorkDescriptor(
        workId: workId,
        title: workId,
        databasePath: 'memory',
        contentKind: 'novel',
        novelMetadata: {},
      ),
      service: NovelContentService(databases[workId]!),
      release: () {
        active--;
      },
    );
  }
}
