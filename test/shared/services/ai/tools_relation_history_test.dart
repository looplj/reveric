// 职责: 验证关系工具的变化、纠错、历史路径、预览和失败原子性。
// 关联文件:
//   lib/shared/services/ai/tools_relation.dart
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/entity_relations_service.dart
import 'package:drift/drift.dart' hide isNull, isNotNull;
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
  Map<String, dynamic>? preview;
  Future<List<Map<String, dynamic>>>? atPreview;
  Future<List<Map<String, dynamic>>> rows() async =>
      (await db
              .customSelect('SELECT * FROM entity_relations ORDER BY id')
              .get())
          .map((r) => r.data)
          .toList();
  setUp(() {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    app = AppDatabase.forTest(NativeDatabase.memory());
    content = NovelContentService(db);
    tools = AiToolManager(
      content,
      workingOverlayService: WorkingOverlayService(
        db,
        content,
        novelActionsService: NovelActionsService(app),
      ),
      onToolStarted: (_, _, _, extra, _) {
        preview = extra;
        atPreview = rows();
      },
    )..registerAllTools();
  });
  tearDown(() async {
    tools.dispose();
    await db.close();
    await app.close();
  });
  Future<Map<String, dynamic>> call(
    String name,
    String path, [
    Map<String, dynamic> args = const {},
  ]) => tools.executeTool(name: name, input: {'path': path, ...args});
  Future<String> create({String? chapterId, String status = 'active'}) async {
    final result = await call('Create', '/relations', {
      'fields': {
        'source_type': 'character',
        'source_id': 'a',
        'target_type': 'character',
        'target_id': 'b',
        'relation_type': 'friend',
        'proof': 'original proof',
        'status': status,
        'chapter_id': ?chapterId,
      },
    });
    expect(result['created'], isTrue, reason: '$result');
    return result['id'] as String;
  }

  Future<Map<String, dynamic>> change(
    String id,
    String type, {
    String status = 'active',
    String reason = 'reason',
  }) => call('Write', '/relations/$id', {
    'fields': {
      'relation_type': type,
      'status': status,
      'proof': 'proof $type $status',
      'reason': reason,
    },
  });
  Future<Map<String, dynamic>> edit(
    String id,
    String field,
    String old,
    String next, {
    bool all = false,
  }) => call('Edit', '/relations/$id/$field', {
    'old_text': old,
    'new_text': next,
    'all': all,
  });

  test(
    'friend enemy friend preserves ID, stable history paths and duplicate retries',
    () async {
      final id = await create();
      final before = await rows();
      final enemy = await change(id, 'enemy');
      expect(enemy['history_appended'], isTrue, reason: '$enemy');
      expect(enemy['id'], id);
      expect(
        await atPreview,
        before,
        reason: 'preview does not write history or current fields',
      );
      expect(preview?['diffOldText'], contains('friend'));
      expect(preview?['diffNewText'], contains('enemy'));
      final friend = await change(id, 'friend');
      expect(friend['id'], id);
      final repeat = await change(id, 'friend');
      expect(repeat['changed'], isFalse);
      expect(repeat['history_appended'], isFalse);
      final detail = await call('Read', 'relations/$id');
      expect(detail['history_count'], 2);
      expect(detail['history_path'], 'relations/$id/change_logs');
      expect(detail.containsKey('change_logs'), isFalse);
      final history = await call('Read', detail['history_path'] as String);
      final entries = history['entries'] as List;
      expect(entries, hasLength(3));
      expect(friend, isNot(contains('change_id')));
      expect(entries.first['relation_type'], 'friend');
      expect(entries.last['kind'], 'baseline');
      final single = await call('Read', entries.first['path'] as String);
      expect(single['id'], entries.first['id']);
      expect(single['proof'], 'proof friend active');
    },
  );

  test(
    'ended is Read-visible, not traversed, restoration searchable; filters use only current type',
    () async {
      final id = await create();
      await change(id, 'lover', status: 'ended');
      await content.entityRelationsService.createRelation(
        sourceType: 'character',
        sourceId: 'b',
        targetType: 'character',
        targetId: 'c',
        relationType: 'friend',
      );
      var graph = await tools.executeTool(
        name: 'GraphSearch',
        input: {'type': 'character', 'id': 'a', 'depth': 2},
      );
      expect(graph['total_relations'], 0);
      expect((await call('Read', 'relations/$id'))['status'], 'ended');
      expect(
        (await call('Read', 'relations?status=ended'))['entries'],
        hasLength(1),
      );
      expect(
        (await call(
          'Read',
          'relations?source_id=a&relation_type=friend',
        ))['entries'],
        isEmpty,
      );
      await change(id, 'lover', status: 'active');
      graph = await tools.executeTool(
        name: 'GraphSearch',
        input: {'type': 'character', 'id': 'a', 'depth': 2},
      );
      expect(graph['total_relations'], 2);
      final edge = (graph['layers'] as List).first['relations'].first as Map;
      expect(edge['status'], 'active');
      expect(edge.containsKey('change_logs'), isFalse);
      expect(edge.containsKey('history_count'), isFalse);
    },
  );

  test(
    'Write omitted evidence clears current position; Edit preserves it and last metadata',
    () async {
      final chapter = await content.createChapter(
        siblingOrder: 1,
        title: 'evidence',
      );
      final id = await create(chapterId: chapter);
      final before = (await content.entityRelationsService.getRelationById(
        id,
      ))!;
      final corrected = await edit(id, 'relation_type', 'friend', '敌人');
      expect(corrected['edited'], isTrue, reason: '$corrected');
      expect(corrected['history_appended'], isFalse);
      expect(corrected['chapter_id'], chapter);
      final after = (await content.entityRelationsService.getRelationById(id))!;
      expect(after.changeLogs.single.id, before.changeLogs.single.id);
      expect(after.changeLogs.single.kind, before.changeLogs.single.kind);
      expect(
        after.changeLogs.single.recordedAt,
        before.changeLogs.single.recordedAt,
      );
      expect(after.changeLogs.single.reason, before.changeLogs.single.reason);
      expect(after.changeLogs.single.chapterId, chapter);
      final changed = await change(id, 'friend');
      expect(changed['chapter_id'], isNull);
      expect(changed['scene_id'], isNull);
      expect(changed['has_evidence_location'], isFalse);
      expect(
        (await content.entityRelationsService.getRelationById(
          id,
        ))!.changeLogs.first.chapterId,
        chapter,
      );
      expect((await call('Read', 'relations/$id/chapter_id'))['value'], isNull);
      expect(
        (await call('Read', 'relations/$id/proof'))['value'],
        'proof friend active',
      );
    },
  );

  test(
    'legacy Edit does not freeze baseline, and preview never generates history',
    () async {
      await db
          .into(db.entityRelations)
          .insert(
            EntityRelationsCompanion.insert(
              id: 'legacy',
              sourceType: 'character',
              sourceId: 'a',
              targetType: 'character',
              targetId: 'b',
              relationType: 'enemy',
              proof: const Value('old old'),
            ),
          );
      final before = await rows();
      final result = await edit('legacy', 'proof', 'old', 'new', all: true);
      expect(result['edited'], isTrue, reason: '$result');
      expect(await atPreview, before);
      expect(preview?['diffOldText'], 'old old');
      expect(preview?['diffNewText'], 'new new');
      final corrected = (await content.entityRelationsService.getRelationById(
        'legacy',
      ))!;
      expect(corrected.changeLogs, isEmpty);
      await change('legacy', 'friend');
      final changed = (await content.entityRelationsService.getRelationById(
        'legacy',
      ))!;
      expect(changed.changeLogs, hasLength(2));
      expect(changed.changeLogs.first.proof, 'new new');
      expect(
        changed.changeLogs.first.recordedAt.isAtSameMomentAs(
          corrected.updatedAt,
        ),
        isTrue,
      );
    },
  );

  test(
    'missing relation proof or reason gives actionable validation',
    () async {
      final id = await create();
      final before = await rows();
      for (final fields in [
        {'relation_type': 'enemy', 'reason': 'changed'},
        {'relation_type': 'enemy', 'proof': 'evidence'},
        {'relation_type': 'enemy'},
      ]) {
        final result = await call('Write', 'relations/$id', {'fields': fields});
        expect(result['error_code'], 'invalid_argument');
        expect(result['required_fields'], ['proof', 'reason']);
        expect(result['missing_fields'], [
          for (final key in ['proof', 'reason'])
            if (!fields.containsKey(key)) key,
        ]);
        expect(await rows(), before);
      }
    },
  );

  test(
    'invalid Edit and Write leave all columns unchanged and have no preview',
    () async {
      final id = await create();
      final before = await rows();
      for (final args in [
        ('relation_type', 'wrong', 'enemy'),
        ('relation_type', 'friend', 'member'),
        ('status', 'active', 'unknown'),
        ('chapter_id', '', 'foreign'),
        ('source_id', 'a', 'c'),
        ('reason', '', 'x'),
        ('change_logs', '', '[]'),
      ]) {
        preview = null;
        final result = await edit(id, args.$1, args.$2, args.$3);
        expect(result.containsKey('error'), isTrue, reason: '$args $result');
        expect(preview, isNot(contains('diffNewText')), reason: '$args');
      }
      final stable = await rows();
      final proofFailure = await edit(id, 'proof', 'original proof', ' ');
      expect(proofFailure.containsKey('error'), isTrue);
      for (final fields in [
        {'relation_type': 'enemy'},
        {'proof': 'p', 'reason': ''},
        {'proof': 'p', 'reason': 'r', 'status': 'bad'},
        {'proof': 'p', 'reason': 'r', 'chapter_id': 'foreign'},
        {'proof': 'p', 'reason': 'r', 'chapter_id': 'c', 'scene_id': 's'},
      ]) {
        final result = await call('Write', 'relations/$id', {'fields': fields});
        expect(result.containsKey('error'), isTrue, reason: '$result');
        expect(preview, isNot(contains('diffNewText')));
        expect(await rows(), stable);
      }
      expect(
        (await rows()).single['change_logs'],
        before.single['change_logs'],
      );
      expect(
        (await call('Edit', 'relations/$id', {
          'old_text': 'a',
          'new_text': 'b',
        }))['error_code'],
        'invalid_argument',
      );
    },
  );

  test(
    'evidence Edit initializes, clears, rejects mutual references and invalid Create',
    () async {
      final chapter = await content.createChapter(
        siblingOrder: 1,
        title: 'evidence',
      );
      final id = await create();
      expect(
        (await edit(id, 'chapter_id', '', chapter))['chapter_id'],
        chapter,
      );
      expect(
        (await edit(id, 'scene_id', '', 'foreign'))['error_code'],
        'invalid_argument',
      );
      expect((await edit(id, 'chapter_id', chapter, ''))['chapter_id'], isNull);
      expect(
        (await edit(id, 'scene_id', '', 'foreign'))['error_code'],
        'invalid_argument',
      );
      final result = await call('Create', 'relations', {
        'fields': {
          'source_type': 'character',
          'source_id': 'a',
          'target_type': 'character',
          'target_id': 'b',
          'relation_type': 'friend',
          'proof': 'p',
          'chapter_id': 'foreign',
        },
      });
      expect(result['error_code'], 'invalid_argument');
    },
  );

  test(
    'history Remove is child-first, latest restores, middle retains; force never removes baseline',
    () async {
      final id = await create();
      await change(id, 'enemy');
      await change(id, 'lover');
      final history =
          (await call('Read', 'relations/$id/change_logs'))['entries'] as List;
      final first = history[1] as Map;
      final second = history[0] as Map;
      final middlePath = first['path'] as String;
      final middle = await call('Remove', middlePath);
      expect(middle['removed'], isTrue, reason: '$middle');
      expect(middle['current_changed'], isFalse);
      expect(middle['relation']['relation_type'], 'lover');
      expect(
        (await rows()).single['change_logs'],
        isNot(contains(first['id'])),
      );
      expect((await call('Read', middlePath))['error_code'], 'not_found');
      final latest = await call('Remove', second['path'] as String);
      expect(latest['current_changed'], isTrue);
      expect(latest['relation']['relation_type'], 'friend');
      final entries =
          (await call('Read', 'relations/$id/change_logs'))['entries'] as List;
      expect(
        (await call('Remove', entries.single['path'] as String, {
          'force': true,
        }))['error_code'],
        'failed_precondition',
      );
      expect(
        (await call('Remove', middlePath, {'force': true}))['missing'],
        isTrue,
      );
      expect(
        (await call('Edit', entries.single['path'] as String, {
          'old_text': 'friend',
          'new_text': 'enemy',
        })).containsKey('error'),
        isTrue,
      );
      await call('Remove', 'relations/$id');
      expect(await rows(), isEmpty);
      expect((await call('Read', 'relations/$id'))['error_code'], 'not_found');
    },
  );

  test(
    'damaged history reports a structured error while current summaries remain readable',
    () async {
      final id = await create();
      await db.customStatement(
        "UPDATE entity_relations SET change_logs = '{}' WHERE id = ?",
        [id],
      );
      expect(
        (await call('Read', 'relations/$id/change_logs'))['error_code'],
        'internal',
      );
      expect((await call('Read', 'relations'))['entries'], hasLength(1));
      expect(
        (await call('Read', 'relations/$id/proof'))['value'],
        'original proof',
      );
      expect((await change(id, 'enemy'))['error_code'], 'internal');
      expect((await rows()).single['change_logs'], '{}');
      expect((await call('Remove', 'relations/$id'))['removed'], isTrue);
      expect(await rows(), isEmpty);
    },
  );

  test(
    'listing serialization length stays fixed as history grows; history is explicitly readable',
    () async {
      final id = await create();
      final initial = (await call('Read', 'relations'))['entries'] as List;
      for (var i = 0; i < 8; i++) {
        await change(id, 'friend', reason: 'reason $i');
      }
      final listing = (await call('Read', 'relations'))['entries'] as List;
      expect((listing.single as Map).keys, (initial.single as Map).keys);
      expect(
        listing.single.toString().length,
        lessThan(initial.single.toString().length + 30),
      );
      expect(
        (await call('Read', 'relations/$id/change_logs'))['entries'],
        hasLength(9),
      );
      final schema = await call('Read', '_schema/relations/change_logs');
      expect(schema.toString(), contains('change_logs'));
      expect(schema.toString(), contains('reason'));
    },
  );
}
