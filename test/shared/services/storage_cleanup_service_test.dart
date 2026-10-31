// 职责: 验证会话、历史及软删除清理的保留期、作品保护、事务失败与打开竞争。
// 关联文件:
//   lib/shared/services/storage_cleanup_service.dart
//   lib/shared/database/novel_content_daos/novel_state_snapshot_dao.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/data-deletion.md

import 'dart:io';
import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/storage_cleanup_service.dart';
import 'package:reveric/shared/services/novel_maintenance_coordinator.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'session files are removed before any chat rows and failed cleanup is retried',
    () async {
      var fail = true;
      late dynamic fixture;
      final seen = <Set<String>>[];
      fixture = await _sessionFixture(
        deleteSessionFiles: (novelId, ids) async {
          expect(novelId, 'novel');
          seen.add(ids.toSet());
          expect(await fixture.app.aiChatSessionDao.getById('root'), isNotNull);
          expect(
            await fixture.content.aiChatMessageDao.getBySession('root'),
            isNotEmpty,
          );
          if (fail) {
            throw const FileSystemException('Cannot delete a session file');
          }
        },
      );
      final first = await fixture.service.runNow();
      expect(first.failedTrees, 1);
      expect(
        await fixture.app.aiChatSessionDao.getById('grandchild'),
        isNotNull,
      );
      expect(
        await fixture.content.aiChatMessageDao.getBySession('root'),
        isNotEmpty,
      );
      fail = false;
      final second = await fixture.service.runNow();
      expect(second.completedTrees, 1);
      expect(await fixture.app.aiChatSessionDao.getById('root'), isNull);
      expect(seen, [
        {'root', 'child', 'grandchild'},
        {'root', 'child', 'grandchild'},
      ]);
    },
  );

  group('ChangeCommitDao.deleteOlderThan', () {
    late NovelContentDatabase database;
    final cutoff = DateTime.utc(2026, 8, 1);

    setUp(() async {
      database = NovelContentDatabase.forTest(NativeDatabase.memory());
      for (final (id, time) in [
        ('expired', cutoff.subtract(const Duration(days: 1))),
        ('boundary', cutoff),
        ('recent', cutoff.add(const Duration(days: 1))),
      ]) {
        await database
            .into(database.changeCommits)
            .insert(
              ChangeCommitsCompanion.insert(id: id, createdAt: Value(time)),
            );
        await database
            .into(database.changeCommitItems)
            .insert(
              ChangeCommitItemsCompanion.insert(
                id: 'item-$id',
                commitId: id,
                workingChangeId: 'change-$id',
                resourcePath: '/chapters/test',
                resourceType: 'chapters',
                // 明细自身的时间不决定是否清理，归属提交的时间才决定。
                createdAt: Value(
                  id == 'expired'
                      ? cutoff
                      : cutoff.subtract(const Duration(days: 2)),
                ),
              ),
            );
      }
    });

    tearDown(() => database.close());

    test(
      'deletes expired commits and their items using the same cutoff',
      () async {
        expect(await database.changeCommitDao.deleteOlderThan(cutoff), 1);
        expect(
          (await database.select(database.changeCommits).get())
              .map((r) => r.id)
              .toSet(),
          {'boundary', 'recent'},
        );
        expect(
          (await database.select(database.changeCommitItems).get())
              .map((r) => r.id)
              .toSet(),
          {'item-boundary', 'item-recent'},
        );
        expect(await database.changeCommitDao.deleteOlderThan(cutoff), 0);
      },
    );

    test('main deletion failure rolls back the item deletion', () async {
      await database.customStatement(
        "CREATE TRIGGER fail_commit BEFORE DELETE ON change_commits BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
      );
      await expectLater(
        database.changeCommitDao.deleteOlderThan(cutoff),
        throwsA(isA<Exception>()),
      );
      expect(await database.select(database.changeCommits).get(), hasLength(3));
      expect(
        await database.select(database.changeCommitItems).get(),
        hasLength(3),
      );
    });
  });

  group('NovelStateSnapshotDao.deleteSupersededOlderThan', () {
    late NovelContentDatabase database;

    setUp(() {
      database = NovelContentDatabase.forTest(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test('deletes old superseded only, keeps active/stale/recent', () async {
      final cutoff = DateTime.utc(2026, 8, 1);
      await _insertSnapshot(
        database,
        id: 'superseded-old',
        status: novelStateSnapshotStatusSuperseded,
        createdAt: cutoff.subtract(const Duration(days: 2)),
      );
      await _insertSnapshot(
        database,
        id: 'superseded-new',
        status: novelStateSnapshotStatusSuperseded,
        createdAt: cutoff.add(const Duration(days: 1)),
      );
      await _insertSnapshot(
        database,
        id: 'active-old',
        status: novelStateSnapshotStatusActive,
        createdAt: cutoff.subtract(const Duration(days: 10)),
      );
      await _insertSnapshot(
        database,
        id: 'stale-old',
        status: 'stale',
        createdAt: cutoff.subtract(const Duration(days: 10)),
      );

      final deleted = await database.novelStateSnapshotDao
          .deleteSupersededOlderThan(cutoff);

      expect(deleted, 1);
      final remaining = await database
          .select(database.novelStateSnapshots)
          .get();
      expect(remaining.map((row) => row.id).toSet(), {
        'superseded-new',
        'active-old',
        'stale-old',
      });
    });
  });

  group('StorageCleanupService', () {
    test(
      'purges expired global and orphan records without requiring an owning novel',
      () async {
        final f = await _sessionFixture();
        for (final (id, owner) in [
          ('global', ''),
          ('orphan', 'missing-novel'),
        ]) {
          await _seedCleanupRow(
            f.app,
            'agents',
            id,
            values: {
              'novel_id': owner,
              'scope': owner.isEmpty ? 'global' : 'novel',
            },
          );
        }
        final result = await f.service.runNow();
        expect(result.failedSoftDeleteBatches, 0);
        expect(result.deletedSoftRows['agents'], 2);
        expect(await f.app.select(f.app.agents).get(), isEmpty);
      },
    );

    test(
      'opening a novel after soft-delete candidate scan prevents its deletion',
      () async {
        final barrier = _SqlBarrier();
        final f = await _sessionFixture(barrier: barrier);
        await _seedCleanupRow(f.app, 'agents', 'deleted-agent');
        var opened = false;
        barrier.afterSelect = (sql) async {
          if (sql.startsWith('SELECT id AS id FROM agents')) {
            barrier.afterSelect = null;
            opened = true;
            final lease = f.coordinator.open('novel');
            addTearDown(lease.release);
          }
        };
        final result = await f.service.runNow();
        expect(opened, isTrue);
        expect(result.failedSoftDeleteBatches, 0);
        expect(result.deletedSoftRows.containsKey('agents'), isFalse);
        expect(await f.app.select(f.app.agents).get(), hasLength(1));
      },
    );

    test(
      'purges approved soft-deleted tables using deletion time, not creation time',
      () async {
        final f = await _sessionFixture();
        final old =
            DateTime.now()
                .subtract(const Duration(days: 40))
                .millisecondsSinceEpoch ~/
            1000;
        final recent =
            DateTime.now()
                .subtract(const Duration(days: 1))
                .millisecondsSinceEpoch ~/
            1000;
        const main = ['agents', 'ai_shortcut_actions', 'ai_providers'];
        const content = [
          'character_profiles',
          'items',
          'chapter_nodes',
          'foreshadowings',
          'agent_rules',
          'documents',
          'outlines',
          'outline_beats',
          'canvases',
          'canvas_nodes',
          'screenplays',
          'screenplay_seasons',
          'screenplay_episodes',
          'screenplay_scenes',
          'screenplay_beats',
          'screenplay_scene_characters',
          'screenplay_scene_elements',
          'locations',
          'novel_maps',
          'map_locations',
        ];
        for (final (database, tables) in [
          (f.app, main),
          (f.content, content),
        ]) {
          for (final table in tables) {
            for (final (suffix, deletedAt) in [
              ('old', old),
              ('recent', recent),
              ('active', 0),
            ]) {
              await _seedCleanupRow(
                database,
                table,
                '$table-$suffix',
                deletedAt: deletedAt,
              );
            }
          }
        }
        await _seedCleanupRow(f.app, 'assets', 'image', deletedAt: old);
        await _seedCleanupRow(f.app, 'image_batches', 'batch', deletedAt: old);
        await f.app.customStatement('UPDATE novels SET deleted_at = ?', [old]);

        final result = await f.service.runNow();

        expect(result.failedSoftDeleteBatches, 0);
        for (final (database, tables) in [
          (f.app, main),
          (f.content, content),
        ]) {
          for (final table in tables) {
            final key = table == 'outlines' ? 'document_id' : 'id';
            final remaining = await database
                .customSelect('SELECT $key AS id FROM $table')
                .get();
            expect(remaining.map((r) => r.read<String>('id')).toSet(), {
              '$table-recent',
              '$table-active',
            }, reason: table);
            expect(result.deletedSoftRows[table], 1, reason: table);
          }
        }
        expect(await f.app.select(f.app.novels).get(), hasLength(1));
        expect(await f.app.select(f.app.assets).get(), hasLength(1));
        expect(await f.app.select(f.app.imageBatches).get(), hasLength(1));
        expect(result.totalDeleted, 3 + 3 + 1 + main.length + content.length);
        final second = await f.service.runNow();
        expect(second.deletedSoftRows, isEmpty);
        expect(second.failedSoftDeleteBatches, 0);
      },
    );

    for (final protection in ['open', 'agent']) {
      test(
        'soft-deleted rows remain while novel has $protection activity',
        () async {
          final f = await _sessionFixture();
          await _seedCleanupRow(f.content, 'documents', 'deleted-document');
          await _seedCleanupRow(f.app, 'agents', 'deleted-agent');
          await _seedCleanupRow(f.app, 'ai_providers', 'deleted-provider');
          switch (protection) {
            case 'open':
              final lease = f.coordinator.open('novel');
              addTearDown(lease.release);
            case 'agent':
              f.running.add('unknown-session');
          }
          final result = await f.service.runNow();
          expect(result.failedSoftDeleteBatches, 0);
          expect(result.deletedSoftRows, isEmpty);
          expect(
            await f.content.select(f.content.documents).get(),
            hasLength(1),
          );
          expect(await f.app.select(f.app.agents).get(), hasLength(1));
          expect(await f.app.select(f.app.aiProviders).get(), hasLength(1));
        },
      );
    }

    test(
      'soft-delete cleanup handles multiple batches and reports failed batch without counting rollback',
      () async {
        final f = await _sessionFixture();
        final old = DateTime.now().subtract(const Duration(days: 40));
        await f.content.batch((batch) {
          batch.insertAll(f.content.documents, [
            for (var i = 0; i < 405; i++)
              DocumentsCompanion.insert(
                id: 'doc-$i',
                type: 'lore',
                title: 'Doc $i',
                deletedAt: Value(old),
              ),
          ]);
        });
        await _seedCleanupRow(f.app, 'agents', 'deleted-agent');
        await f.app.customStatement(
          "CREATE TRIGGER fail_agent BEFORE DELETE ON agents BEGIN SELECT RAISE(ABORT, 'injected'); END",
        );
        final result = await f.service.runNow();
        expect(result.deletedSoftRows['documents'], 405);
        expect(result.failedSoftDeleteBatches, 1);
        expect(await f.app.select(f.app.agents).get(), hasLength(1));
        expect(await f.content.select(f.content.documents).get(), isEmpty);
      },
    );

    test('cleans the same expired tree in both databases', () async {
      final fixture = await _sessionFixture();
      await fixture.app
          .into(fixture.app.todos)
          .insert(
            TodosCompanion.insert(
              id: 'orphan',
              content: 'Keep historical orphan',
              sessionId: 'missing-session',
              createdAt: Value(DateTime(2000)),
              updatedAt: Value(DateTime(2000)),
            ),
          );
      final result = await fixture.service.runNow();
      expect(result.deletedSessions, 3);
      expect(result.deletedMessages, 3);
      expect(
        await fixture.app.todoDao.getTodosBySession('grandchild'),
        isEmpty,
      );
      expect(
        await fixture.app.todoDao.getTodosBySession('missing-session'),
        hasLength(1),
      );
      expect(
        await fixture.content.novelStateDao.getActiveChatSessionId(),
        isNull,
      );
      expect(
        (await fixture.content.novelStateDao.get('other_pointer'))?.data,
        'keep',
      );
    });

    test(
      'keeps a recent separate tree, its old message and active pointer',
      () async {
        final f = await _sessionFixture();
        await f.app.aiChatSessionDao.upsert(
          id: 'recent',
          novelId: 'novel',
          title: 'Recent',
        );
        await f.content
            .into(f.content.aiChatMessages)
            .insert(
              AiChatMessagesCompanion.insert(
                id: 'old-message-in-recent',
                sessionId: 'recent',
                role: 'user',
                createdAt: Value(
                  DateTime.now().subtract(const Duration(days: 40)),
                ),
              ),
            );
        await f.content.novelStateDao.setActiveChatSessionId('recent');
        final result = await f.service.runNow();
        expect(result.deletedSessions, 3);
        expect(result.deletedMessages, 3);
        expect(
          await f.content.novelStateDao.getActiveChatSessionId(),
          'recent',
        );
        expect(
          await f.content.aiChatMessageDao.getBySession('recent'),
          hasLength(1),
        );
      },
    );

    test('cleans trees larger than one SQL parameter batch', () async {
      final f = await _sessionFixture();
      final old = DateTime.now().subtract(const Duration(days: 40));
      await f.app.batch((batch) {
        batch.insertAll(f.app.aiChatSessions, [
          for (var i = 0; i < 450; i++)
            AiChatSessionsCompanion.insert(
              id: 'extra-$i',
              novelId: 'novel',
              parentId: const Value('child'),
              createdAt: Value(old),
              updatedAt: Value(old),
            ),
        ]);
      });
      final result = await f.service.runNow();
      expect(result.deletedSessions, 453);
      expect(result.deletedMessages, 3);
      expect(result.deletedTodos, 1);
      expect(result.completedTrees, 1);
    });

    for (final activity in ['session', 'message', 'todo']) {
      test(
        'recent $activity protects the entire tree and old messages',
        () async {
          final f = await _sessionFixture();
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          switch (activity) {
            case 'session':
              await f.app.customStatement(
                'UPDATE ai_chat_sessions SET updated_at = ? WHERE id = ?',
                [now, 'grandchild'],
              );
            case 'message':
              await f.content.customStatement(
                'UPDATE ai_chat_messages SET created_at = ? WHERE id = ?',
                [now, 'message-grandchild'],
              );
            case 'todo':
              await f.app.customStatement('UPDATE todos SET updated_at = ?', [
                now,
              ]);
          }
          final result = await f.service.runNow();
          expect(result.deletedSessions, 0);
          expect(result.deletedMessages, 0);
          expect(
            await f.content.aiChatMessageDao.getBySession('root'),
            hasLength(1),
          );
          expect(
            await f.app.todoDao.getTodosBySession('grandchild'),
            hasLength(1),
          );
        },
      );
    }

    test(
      'open pages and background child runs protect all content history',
      () async {
        final f = await _sessionFixture();
        await _insertSnapshot(
          f.content,
          id: 'snapshot',
          status: novelStateSnapshotStatusSuperseded,
          createdAt: DateTime.now().subtract(const Duration(days: 40)),
        );
        final first = f.coordinator.open('novel');
        final second = f.coordinator.open('novel');
        first.release();
        expect((await f.service.runNow()).totalDeleted, 0);
        second.release();
        f.running.add('grandchild');
        expect((await f.service.runNow()).totalDeleted, 0);
        f.running.clear();
        final result = await f.service.runNow();
        expect(result.deletedSessions, 3);
        expect(result.deletedSnapshots, 1);
      },
    );

    for (final reference in ['subscription', 'active_change']) {
      test('$reference retains the tree across repeated cleanup runs', () async {
        final f = await _sessionFixture();
        switch (reference) {
          case 'subscription':
            await f.app
                .into(f.app.sessionSubscriptions)
                .insert(
                  SessionSubscriptionsCompanion.insert(
                    id: 'subscription',
                    sessionId: 'child',
                    subscriberType: 'remote_chat',
                    targetId: 'target',
                    channelType: const Value('wechat'),
                  ),
                );
          case 'active_change':
            await f.content.customStatement(
              "INSERT INTO working_changes (id, resource_path, resource_type, change_type, source, source_session_id, created_at, updated_at) VALUES ('change', '/test', 'chapter', 'update', 'ai', 'child', 1, 1)",
            );
        }
        expect((await f.service.runNow()).deletedSessions, 0);
        expect((await f.service.runNow()).deletedSessions, 0);
        expect(
          await f.content.aiChatMessageDao.getBySession('root'),
          hasLength(1),
        );
      });
    }

    for (final invalid in ['cross_novel', 'cycle', 'missing_database']) {
      test('$invalid is skipped without deleting history', () async {
        final f = await _sessionFixture();
        switch (invalid) {
          case 'cross_novel':
            await f.app.customStatement(
              "UPDATE ai_chat_sessions SET novel_id = 'another' WHERE id = 'child'",
            );
          case 'cycle':
            await f.app.customStatement(
              "UPDATE ai_chat_sessions SET parent_id = 'grandchild' WHERE id = 'root'",
            );
          case 'missing_database':
            await f.app.customStatement(
              'UPDATE novels SET content_database_path = ?',
              ['${f.content.filePath}.missing'],
            );
        }
        expect((await f.service.runNow()).deletedSessions, 0);
        expect(
          await f.content.aiChatMessageDao.getBySession('root'),
          hasLength(1),
        );
      });
    }

    for (final recent in [false, true]) {
      test(
        'orphan siblings and missing parent resources are one group: $recent',
        () async {
          final f = await _sessionFixture();
          await f.app.customStatement(
            "DELETE FROM ai_chat_sessions WHERE id = 'child'",
          );
          await f.app.customStatement(
            "UPDATE ai_chat_sessions SET parent_id = 'child' WHERE id = 'root'",
          );
          if (recent) {
            await f.app.aiChatSessionDao.touch('grandchild');
          }
          final result = await f.service.runNow();
          expect(result.deletedSessions, recent ? 0 : 2);
          expect(result.deletedMessages, recent ? 0 : 3);
          expect(result.deletedTodos, recent ? 0 : 1);
          expect(result.groups['orphan_tree']?.candidate, 1);
          expect(
            await f.content.novelStateDao.getActiveChatSessionId(),
            recent ? 'child' : isNull,
          );
        },
      );
    }

    test('records-only groups clean together; unowned Todo remains', () async {
      final f = await _sessionFixture();
      await f.app.customStatement('DELETE FROM ai_chat_sessions');
      await f.app.customStatement(
        "INSERT INTO todos (id, content, session_id, created_at, updated_at) VALUES ('unowned', 'keep', 'unknown', 1, 1)",
      );
      final result = await f.service.runNow();
      expect(result.deletedMessages, 3);
      expect(result.deletedTodos, 1);
      expect(result.groups['orphan_records']?.completed, 3);
      expect(result.unattributed, 1);
      expect(await f.app.todoDao.getTodosBySession('unknown'), hasLength(1));
    });

    for (final recent in [false, true]) {
      test('pointer-only age determines retention: $recent', () async {
        final f = await _sessionFixture();
        await f.app.customStatement('DELETE FROM ai_chat_sessions');
        await f.app.customStatement('DELETE FROM todos');
        await f.content.customStatement('DELETE FROM ai_chat_messages');
        if (!recent) {
          await f.content.customStatement(
            "UPDATE novel_states SET updated_at = 1 WHERE key = 'active_chat_session'",
          );
        }
        final result = await f.service.runNow();
        expect(result.completedTrees, recent ? 0 : 1);
        expect(
          await f.content.novelStateDao.getActiveChatSessionId(),
          recent ? 'child' : isNull,
        );
      });
    }

    for (final reference in ['subscription', 'active_change', 'running']) {
      test('missing parent $reference protects orphan group', () async {
        final f = await _sessionFixture();
        await f.app.customStatement(
          "DELETE FROM ai_chat_sessions WHERE id = 'root'",
        );
        switch (reference) {
          case 'subscription':
            await f.app
                .into(f.app.sessionSubscriptions)
                .insert(
                  SessionSubscriptionsCompanion.insert(
                    id: 'sub',
                    sessionId: 'root',
                    subscriberType: 'remote_chat',
                    targetId: 'target',
                  ),
                );
          case 'active_change':
            await f.content.customStatement(
              "INSERT INTO working_changes (id, resource_path, resource_type, change_type, source, source_session_id, created_at, updated_at) VALUES ('change', '/test', 'chapter', 'update', 'ai', 'root', 1, 1)",
            );
          case 'running':
            f.running.add('root');
        }
        expect((await f.service.runNow()).deletedMessages, 0);
        expect((await f.service.runNow()).deletedSessions, 0);
      });
    }

    for (final failedStage in ['main', 'content']) {
      for (final recent in [false, true]) {
        test(
          'records-only $failedStage failure retries with fresh activity: $recent',
          () async {
            final f = await _sessionFixture();
            await f.app.customStatement('DELETE FROM ai_chat_sessions');
            await f.content.customStatement(
              "UPDATE ai_chat_messages SET session_id = 'grandchild'",
            );
            await f.content.novelStateDao.setActiveChatSessionId('grandchild');
            if (failedStage == 'main') {
              await f.app.customStatement(
                "CREATE TRIGGER fail_main BEFORE DELETE ON todos BEGIN SELECT RAISE(ABORT, 'failure'); END",
              );
            } else {
              await f.content.customStatement(
                "CREATE TRIGGER fail_content BEFORE DELETE ON ai_chat_messages BEGIN SELECT RAISE(ABORT, 'failure'); END",
              );
            }
            final failed = await f.service.runNow();
            expect(failed.failedTrees, 1);
            expect(failed.deletedMessages, 0);
            expect(failed.deletedTodos, failedStage == 'main' ? 0 : 1);
            expect(
              await f.content.aiChatMessageDao.getBySession('grandchild'),
              hasLength(3),
            );
            if (failedStage == 'main') {
              await f.app.customStatement('DROP TRIGGER fail_main');
            } else {
              await f.content.customStatement('DROP TRIGGER fail_content');
            }
            if (recent) {
              await f.content.customStatement(
                'UPDATE ai_chat_messages SET created_at = ?',
                [DateTime.now().millisecondsSinceEpoch ~/ 1000],
              );
            }
            expect((await f.service.runNow()).deletedMessages, recent ? 0 : 3);
          },
        );
      }
    }

    for (final mutation in [
      'restore',
      'child',
      'message',
      'todo',
      'registry',
      'open',
    ]) {
      test('orphan candidate rechecks $mutation', () async {
        final barrier = _SqlBarrier();
        final f = await _sessionFixture(barrier: barrier);
        await f.app.customStatement(
          "DELETE FROM ai_chat_sessions WHERE id = 'root'",
        );
        NovelOpenLease? opening;
        var changed = false;
        barrier.afterSelect = (sql) async {
          if (changed ||
              !sql.startsWith('SELECT 1 FROM session_subscriptions')) {
            return;
          }
          changed = true;
          switch (mutation) {
            case 'restore':
              await f.app.aiChatSessionDao.upsert(
                id: 'root',
                novelId: 'novel',
                title: 'Restored',
              );
            case 'child':
              await f.app.aiChatSessionDao.upsert(
                id: 'new-child',
                novelId: 'novel',
                title: 'New',
                parentId: 'root',
              );
            case 'message':
              await f.content.customStatement(
                'UPDATE ai_chat_messages SET created_at = ?',
                [DateTime.now().millisecondsSinceEpoch ~/ 1000],
              );
            case 'todo':
              await f.app.customStatement('UPDATE todos SET updated_at = ?', [
                DateTime.now().millisecondsSinceEpoch ~/ 1000,
              ]);
            case 'registry':
              await f.app.novelDao.create(
                id: 'new',
                title: 'New',
                description: '',
              );
            case 'open':
              opening = f.coordinator.open('novel');
          }
        };
        final result = await f.service.runNow();
        expect(changed, isTrue);
        expect(result.deletedMessages, 0);
        expect(result.deletedSessions, 0);
        opening?.release();
      });
    }

    for (final condition in [
      'conflict',
      'missing',
      'corrupt',
      'soft_deleted_novel',
      'changed_evidence',
    ]) {
      test('orphan ownership scan: $condition', () async {
        final barrier = _SqlBarrier();
        final f = await _sessionFixture(barrier: barrier);
        await f.app.customStatement(
          "DELETE FROM ai_chat_sessions WHERE id = 'root'",
        );
        if (condition == 'soft_deleted_novel') {
          await f.app.customStatement('UPDATE novels SET deleted_at = 1');
        } else {
          final path = '${f.content.filePath}.other';
          await f.app.novelDao.create(
            id: 'other',
            title: 'Other',
            description: '',
            contentDatabasePath: path,
          );
          if (condition == 'corrupt') {
            await File(path).writeAsString('invalid sqlite');
          } else if (condition != 'missing') {
            final other = NovelContentDatabase(path);
            addTearDown(other.close);
            await other.novelStateDao.upsert(key: 'unrelated', status: 'idle');
            if (condition == 'conflict') {
              await other.novelStateDao.setActiveChatSessionId('root');
            } else {
              var changed = false;
              barrier.afterSelect = (sql) async {
                if (!changed &&
                    sql.startsWith('SELECT 1 FROM session_subscriptions')) {
                  changed = true;
                  await other.novelStateDao.setActiveChatSessionId('root');
                }
              };
            }
          }
        }
        final result = await f.service.runNow();
        expect(
          result.deletedMessages,
          condition == 'soft_deleted_novel' ? 3 : 0,
        );
        expect(
          result.deletedSessions,
          condition == 'soft_deleted_novel' ? 2 : 0,
        );
        if (condition == 'conflict') {
          expect(result.conflicts, 1);
        }
        if (condition == 'missing' || condition == 'corrupt') {
          expect(result.scanFailures, 1);
        }
      });
    }

    test('soft-deleted sessions remain members of the normal tree', () async {
      final f = await _sessionFixture();
      await f.app.customStatement(
        "UPDATE ai_chat_sessions SET deleted_at = 1 WHERE id = 'root'",
      );
      final result = await f.service.runNow();
      expect(result.groups['normal_tree']?.completed, 1);
      expect(result.groups['orphan_tree'], isNull);
      expect(result.deletedSessions, 3);
    });

    for (final recordsOnly in [false, true]) {
      test(
        'orphan opening waits through both commits: recordsOnly=$recordsOnly',
        () async {
          final barrier = _SqlBarrier();
          final f = await _sessionFixture(barrier: barrier);
          await f.app.customStatement(
            recordsOnly
                ? 'DELETE FROM ai_chat_sessions'
                : "DELETE FROM ai_chat_sessions WHERE id = 'root'",
          );
          if (recordsOnly) {
            await f.content.customStatement(
              "UPDATE ai_chat_messages SET session_id = 'grandchild'",
            );
            await f.content.novelStateDao.setActiveChatSessionId('grandchild');
          }
          final reached = Completer<void>();
          final proceed = Completer<void>();
          barrier.beforeDelete = (sql) async {
            if (sql.contains('todos') && !reached.isCompleted) {
              reached.complete();
              await proceed.future;
            }
          };
          final cleanup = f.service.runNow();
          await reached.future;
          final opening = f.coordinator.open('novel');
          var readable = false;
          opening.ready.then((_) => readable = true);
          await Future<void>.delayed(Duration.zero);
          expect(readable, isFalse);
          proceed.complete();
          final result = await cleanup;
          await opening.ready;
          expect(result.completedTrees, 1);
          expect(result.deletedMessages, 3);
          expect(result.deletedTodos, 1);
          expect(
            await f.content.novelStateDao.getActiveChatSessionId(),
            isNull,
          );
          opening.release();
        },
      );
    }

    for (final stage in ['main', 'content']) {
      test('orphan tree $stage failure preserves retry root', () async {
        final f = await _sessionFixture();
        await f.app.customStatement(
          "DELETE FROM ai_chat_sessions WHERE id = 'root'",
        );
        if (stage == 'main') {
          await f.app.customStatement(
            "CREATE TRIGGER fail_main BEFORE DELETE ON ai_chat_sessions BEGIN SELECT RAISE(ABORT, 'failure'); END",
          );
        } else {
          await f.content.customStatement(
            "CREATE TRIGGER fail_content BEFORE UPDATE ON novel_states BEGIN SELECT RAISE(ABORT, 'failure'); END",
          );
        }
        final result = await f.service.runNow();
        expect(result.failedTrees, 1);
        expect(result.deletedMessages, stage == 'main' ? 3 : 0);
        expect(result.deletedTodos, 0);
        expect(await f.app.aiChatSessionDao.getById('child'), isNotNull);
        if (stage == 'main') {
          await f.app.customStatement('DROP TRIGGER fail_main');
        } else {
          await f.content.customStatement('DROP TRIGGER fail_content');
        }
        expect((await f.service.runNow()).deletedSessions, 2);
      });
    }

    test('content failure rolls back and retains all main records', () async {
      final f = await _sessionFixture();
      await f.content.customStatement(
        "CREATE TRIGGER fail_clear BEFORE UPDATE ON novel_states BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
      );
      final failed = await f.service.runNow();
      expect(failed.failedTrees, 1);
      expect(failed.deletedMessages, 0);
      expect(
        await f.content.aiChatMessageDao.getBySession('root'),
        hasLength(1),
      );
      expect(await f.content.novelStateDao.getActiveChatSessionId(), 'child');
      expect(await f.app.aiChatSessionDao.getById('root'), isNotNull);
      expect(await f.app.todoDao.getTodosBySession('grandchild'), hasLength(1));
    });

    for (final newActivity in [false, true]) {
      test(
        'main failure retries with fresh activity check: $newActivity',
        () async {
          final f = await _sessionFixture();
          await f.app.customStatement(
            "CREATE TRIGGER fail_main BEFORE DELETE ON ai_chat_sessions BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
          );
          final failed = await f.service.runNow();
          expect(failed.failedTrees, 1);
          expect(failed.deletedMessages, 3);
          expect(await f.app.aiChatSessionDao.getById('root'), isNotNull);
          expect(
            await f.app.todoDao.getTodosBySession('grandchild'),
            hasLength(1),
          );
          await f.app.customStatement('DROP TRIGGER fail_main');
          if (newActivity) {
            await f.app.aiChatSessionDao.touch('child');
          }
          final retried = await f.service.runNow();
          expect(retried.deletedSessions, newActivity ? 0 : 3);
          expect(retried.deletedMessages, 0);
        },
      );
    }

    test('opening after candidate scan prevents the commit', () async {
      final barrier = _SqlBarrier();
      final f = await _sessionFixture(barrier: barrier);
      NovelOpenLease? opening;
      barrier.afterSelect = (sql) async {
        if (sql.startsWith('SELECT 1 FROM session_subscriptions')) {
          opening ??= f.coordinator.open('novel');
        }
      };
      final result = await f.service.runNow();
      expect(opening, isNotNull);
      expect(result.deletedSessions, 0);
      expect(result.deletedMessages, 0);
      opening!.release();
    });

    test(
      'opening during the cross-database commit waits for main commit',
      () async {
        final barrier = _SqlBarrier();
        final f = await _sessionFixture(barrier: barrier);
        final old = DateTime.now().subtract(const Duration(days: 40));
        await f.app
            .into(f.app.aiChatSessions)
            .insert(
              AiChatSessionsCompanion.insert(
                id: 'second-root',
                novelId: 'novel',
                createdAt: Value(old),
                updatedAt: Value(old),
              ),
            );
        final reachedMain = Completer<void>();
        final finishMain = Completer<void>();
        barrier.beforeDelete = (sql) async {
          if (sql.contains('todos')) {
            reachedMain.complete();
            await finishMain.future;
          }
        };
        final cleanup = f.service.runNow();
        await reachedMain.future;
        final opening = f.coordinator.open('novel');
        var readAllowed = false;
        opening.ready.then((_) => readAllowed = true);
        await Future<void>.delayed(Duration.zero);
        expect(readAllowed, isFalse);
        finishMain.complete();
        final result = await cleanup;
        await opening.ready;
        expect(result.completedTrees, 1);
        expect(await f.app.aiChatSessionDao.getById('root'), isNull);
        expect(await f.app.aiChatSessionDao.getById('second-root'), isNotNull);
        expect(await f.content.aiChatMessageDao.getBySession('root'), isEmpty);
        opening.release();
      },
    );

    test('enforces retention bounds on construction and updates', () async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(database.close);
      final service = StorageCleanupService(
        coordinator: NovelMaintenanceCoordinator(),
        runningSessionIds: () => {},
        appDatabase: database,
        retentionDays: 1,
      );
      addTearDown(service.dispose);
      expect(service.retentionDays, 7);
      service.updateConfig(retentionDays: 6);
      expect(service.retentionDays, 7);
      service.updateConfig(retentionDays: 400);
      expect(service.retentionDays, 365);
      expect(
        StorageCleanupService(
          coordinator: NovelMaintenanceCoordinator(),
          runningSessionIds: () => {},
          appDatabase: database,
          retentionDays: 400,
        ).retentionDays,
        365,
      );
    });

    test('cleans superseded snapshots for novels', () async {
      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(appDb.close);

      final tempDir = await Directory.systemTemp.createTemp(
        'reveric_storage_cleanup_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final contentPath = p.join(tempDir.path, 'novel.db');
      final contentDb = NovelContentDatabase(contentPath);
      addTearDown(contentDb.close);

      final cutoffAnchor = DateTime.now().subtract(const Duration(days: 30));
      await _insertSnapshot(
        contentDb,
        id: 'superseded-old',
        status: novelStateSnapshotStatusSuperseded,
        createdAt: cutoffAnchor.subtract(const Duration(days: 1)),
      );
      await _insertSnapshot(
        contentDb,
        id: 'active-keep',
        status: novelStateSnapshotStatusActive,
        createdAt: cutoffAnchor.subtract(const Duration(days: 1)),
      );
      await contentDb.close();

      await appDb.novelDao.create(
        id: 'novel-1',
        title: 'Cleanup Novel',
        description: 'for cleanup test',
        contentDatabasePath: contentPath,
      );

      final service = StorageCleanupService(
        coordinator: NovelMaintenanceCoordinator(),
        runningSessionIds: () => {},
        appDatabase: appDb,
        retentionDays: 30,
      );
      final result = await service.runNow();

      expect(result.deletedSnapshots, 1);

      final reopened = NovelContentDatabase(contentPath);
      addTearDown(reopened.close);
      final snapshots = await reopened
          .select(reopened.novelStateSnapshots)
          .get();
      expect(snapshots.map((row) => row.id).toSet(), {'active-keep'});
    });
  });
}

Future<
  ({
    AppDatabase app,
    NovelContentDatabase content,
    StorageCleanupService service,
    NovelMaintenanceCoordinator coordinator,
    Set<String> running,
  })
>
_sessionFixture({
  _SqlBarrier? barrier,
  Future<void> Function(String, Iterable<String>)? deleteSessionFiles,
}) async {
  final native = NativeDatabase.memory();
  final app = AppDatabase.forTest(
    barrier == null ? native : native.interceptWith(barrier),
  );
  final coordinator = NovelMaintenanceCoordinator();
  final running = <String>{};
  final directory = await Directory.systemTemp.createTemp('reveric_pr2_');
  final path = p.join(directory.path, 'content.sqlite');
  final content = NovelContentDatabase(path);
  addTearDown(() async {
    await content.close();
    await app.close();
    await directory.delete(recursive: true);
  });
  await app.novelDao.create(
    id: 'novel',
    title: 'Test',
    description: '',
    contentDatabasePath: path,
  );
  final old = DateTime.now().subtract(const Duration(days: 40));
  for (final (id, parent) in [
    ('root', null),
    ('child', 'root'),
    ('grandchild', 'child'),
  ]) {
    await app
        .into(app.aiChatSessions)
        .insert(
          AiChatSessionsCompanion.insert(
            id: id,
            novelId: 'novel',
            parentId: Value(parent),
            updatedAt: Value(old),
            createdAt: Value(old),
          ),
        );
    await content
        .into(content.aiChatMessages)
        .insert(
          AiChatMessagesCompanion.insert(
            id: 'message-$id',
            sessionId: id,
            role: 'user',
            content: const Value('history'),
            createdAt: Value(old),
          ),
        );
  }
  await app
      .into(app.todos)
      .insert(
        TodosCompanion.insert(
          id: 'todo',
          content: 'Task',
          sessionId: 'grandchild',
          createdAt: Value(old),
          updatedAt: Value(old),
        ),
      );
  await content.novelStateDao.setActiveChatSessionId('child');
  await content.novelStateDao.upsert(
    key: 'other_pointer',
    status: 'idle',
    data: 'keep',
  );
  return (
    app: app,
    content: content,
    coordinator: coordinator,
    running: running,
    service: StorageCleanupService(
      coordinator: coordinator,
      runningSessionIds: () => running,
      deleteSessionFiles: deleteSessionFiles ?? (_, _) async {},
      appDatabase: app,
    ),
  );
}

// 用真实 schema 补齐必填标量，避免几十张表的保留期测试依赖无关业务字段。
Future<void> _seedCleanupRow(
  GeneratedDatabase database,
  String table,
  String id, {
  int? deletedAt,
  Map<String, Object?> values = const {},
}) async {
  final old =
      DateTime.now()
          .subtract(const Duration(days: 40))
          .millisecondsSinceEpoch ~/
      1000;
  final columns = await database
      .customSelect('PRAGMA table_info($table)')
      .get();
  final row = <String, Object?>{};
  for (final column in columns) {
    final name = column.read<String>('name');
    if (column.read<int>('notnull') == 1 &&
        column.readNullable<String>('dflt_value') == null) {
      row[name] = column.read<String>('type') == 'TEXT' ? id : 0;
    }
    switch (name) {
      case 'id':
      case 'document_id':
        row[name] = id;
      case 'created_at':
      case 'updated_at':
        row[name] = old;
      case 'deleted_at':
        row[name] = deletedAt ?? old;
      case 'novel_id':
      case 'source_novel_id':
        row[name] = 'novel';
    }
  }
  if (table == 'agents') {
    row['scope'] = 'novel';
  }
  if (table == 'screenplay_scene_elements') {
    row['type'] = 'action';
  }
  row.addAll(values);
  await database.customStatement(
    'INSERT INTO $table (${row.keys.map((k) => '"$k"').join(',')}) VALUES (${List.filled(row.length, '?').join(',')})',
    row.values.toList(),
  );
}

Future<void> _insertSnapshot(
  NovelContentDatabase database, {
  required String id,
  required String status,
  required DateTime createdAt,
}) {
  return database
      .into(database.novelStateSnapshots)
      .insert(
        NovelStateSnapshotsCompanion.insert(
          id: id,
          content: const Value('snapshot body'),
          status: Value(status),
          createdAt: Value(createdAt),
        ),
      );
}

class _SqlBarrier extends QueryInterceptor {
  Future<void> Function(String)? afterSelect;
  Future<void> Function(String)? beforeDelete;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await executor.runSelect(statement, args);
    await afterSelect?.call(statement);
    return result;
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await beforeDelete?.call(statement);
    return executor.runDelete(statement, args);
  }
}
