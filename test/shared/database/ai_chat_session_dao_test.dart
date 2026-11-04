// 职责: 测试 AI 会话 DAO — 验证全局最近会话按模式过滤。
// 关联文件:
//   lib/shared/database/daos/ai_chat_session_dao.dart
//   lib/shared/database/app_database.dart
//   lib/shared/models/ai_session_mode.dart

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTest(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'maintenance reads descendants including soft-deleted sessions',
    () async {
      await db.aiChatSessionDao.upsert(
        id: 'root',
        novelId: 'novel',
        title: 'Root',
      );
      await db.aiChatSessionDao.upsert(
        id: 'child',
        novelId: 'novel',
        title: 'Child',
        parentId: 'root',
      );
      await db.aiChatSessionDao.upsert(
        id: 'grandchild',
        novelId: 'novel',
        title: 'Grandchild',
        parentId: 'child',
      );
      await db.aiChatSessionDao.softDelete('child');
      final tree = await db.aiChatSessionDao.getCleanupSessions(rootId: 'root');
      expect(tree.map((s) => s.id).toSet(), {'root', 'child', 'grandchild'});
      expect(tree.singleWhere((s) => s.id == 'grandchild').parentId, 'child');
    },
  );

  group('AiChatSessionDao.watchRecent', () {
    test('filters by mode before applying the recent-session limit', () async {
      await db.novelDao.create(id: 'novel_1', title: 'Novel', description: '');
      await db.aiChatSessionDao.upsert(
        id: 'chat_1',
        novelId: 'novel_1',
        title: 'Chat session',
        mode: AiSessionMode.chat.value,
      );
      await db.aiChatSessionDao.upsert(
        id: 'council_1',
        novelId: 'novel_1',
        title: 'Council session',
        mode: AiSessionMode.council.value,
      );

      final sessions = await db.aiChatSessionDao
          .watchRecent(limit: 1, mode: AiSessionMode.chat.value)
          .first;

      expect(sessions.map((session) => session.id), ['chat_1']);
    });

    test(
      'hides sessions of works in the trash and reappears on restore',
      () async {
        await db.novelDao.create(
          id: 'novel_1',
          title: 'Novel',
          description: '',
        );
        await db.aiChatSessionDao.upsert(
          id: 'chat_1',
          novelId: 'novel_1',
          title: 'Chat session',
        );
        final emitted = <List<String>>[];
        final subscription = db.aiChatSessionDao
            .watchRecent(limit: 3)
            .map((rows) => [for (final row in rows) row.id])
            .listen(emitted.add);
        addTearDown(subscription.cancel);
        await pumpEventQueue();

        await db.novelDao.softDelete('novel_1');
        await pumpEventQueue();
        await db.novelDao.restore('novel_1');
        await pumpEventQueue();

        expect(emitted, [
          ['chat_1'],
          <String>[],
          ['chat_1'],
        ]);
      },
    );
  });
}
