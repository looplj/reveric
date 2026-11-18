// 职责: 测试 SuggestNextAction 工具 — 契约（返回值/非阻塞）、门控（回调/模式/subagent）与丢弃行为。
// 关联文件:
//   lib/shared/services/ai/tools_suggest_next_action.dart
//   lib/shared/services/ai/tools.dart
//   lib/shared/models/ai_session_mode.dart

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/ai_session_mode.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  group('工具目录', () {
    test('SuggestNextAction 在目录中，且 SubAgent 不可配置', () {
      final entry = aiToolCatalog.firstWhere(
        (e) => e.name == suggestNextActionToolName,
      );
      expect(entry.group, AiToolGroup.suggestion);
      expect(entry.agentConfigurable, isTrue);
      expect(entry.subAgentConfigurable, isFalse);
    });

    test('defaultSubAgentToolNames 不含该工具', () {
      expect(
        defaultSubAgentToolNames(),
        isNot(contains(suggestNextActionToolName)),
      );
    });

    test('defaultAgentToolNames 含该工具', () {
      expect(defaultAgentToolNames(), contains(suggestNextActionToolName));
    });
  });

  group('模式门控', () {
    test('chat 可用，其余特殊模式不可用', () {
      expect(AiSessionMode.chat.canUseTool(suggestNextActionToolName), isTrue);
      for (final mode in [
        AiSessionMode.council,
        AiSessionMode.monologue,
        AiSessionMode.theater,
        AiSessionMode.roleplay,
      ]) {
        expect(
          mode.canUseTool(suggestNextActionToolName),
          isFalse,
          reason: '${mode.value} must not call SuggestNextAction',
        );
      }
    });
  });

  group('注册门控', () {
    test('callback == null → 既不注册 dispatch 也不下发 ToolDef', () {
      final manager = _buildManager();

      expect(
        manager.allToolNames(),
        isNot(contains(suggestNextActionToolName)),
      );
      expect(
        manager.allToolDefs().map((t) => t.name),
        isNot(contains(suggestNextActionToolName)),
      );
    });

    test('callback != null → 注册并下发', () {
      final manager = _buildManager(onSuggest: (_, _) {});

      expect(manager.allToolNames(), contains(suggestNextActionToolName));
      expect(
        manager.allToolDefs().map((t) => t.name),
        contains(suggestNextActionToolName),
      );
    });

    test('画布与小说下发相同的工具定义，画布只保留提示词建议', () async {
      List<Map<String, dynamic>>? received;
      final manager = _buildManager(
        contentKind: contentKindCanvas,
        onSuggest: (_, items) => received = items,
      );
      final def = manager.allToolDefs().singleWhere(
        (t) => t.name == suggestNextActionToolName,
      );
      final novelDef = _buildManager(
        onSuggest: (_, _) {},
      ).allToolDefs().singleWhere((t) => t.name == suggestNextActionToolName);
      expect(def.inputSchema, equals(novelDef.inputSchema));
      expect(def.description, novelDef.description);
      await manager.executeTool(
        name: suggestNextActionToolName,
        input: {
          'suggestions': [
            {'kind': 'feature', 'feature': 'ai_council', 'label': '圆桌'},
            {'kind': 'prompt', 'label': '核对首尾帧', 'prompt': '核对上下段首尾帧'},
          ],
        },
      );
      expect(received!.single['prompt'], '核对上下段首尾帧');
    });
    test('feature 枚举固定包含封面工作台', () {
      final manager = _buildManager(onSuggest: (_, _) {});

      final def = manager.allToolDefs().firstWhere(
        (t) => t.name == suggestNextActionToolName,
      );
      final properties = def.inputSchema['properties'] as Map;
      final items = (properties['suggestions'] as Map)['items'] as Map;
      final featureEnum =
          ((items['properties'] as Map)['feature'] as Map)['enum'] as List;

      final intentSchema = (items['properties'] as Map)['intent'] as Map;
      expect(intentSchema['enum'], [
        'continue_chat',
        'new_chat',
        'continue_in_new_chat',
        'agent_rule',
        'agent_skill',
      ]);
      expect(items['required'], isNot(contains('intent')));
      expect(featureEnum, [
        'ai_council',
        'ai_theater',
        'ai_roleplay',
        'ai_cover_studio',
      ]);
    });
  });

  group('执行契约', () {
    test('返回值恒为 {"ok": true}，不含 accepted / dropped', () async {
      List<Map<String, dynamic>>? captured;
      final manager = _buildManager(
        onSuggest: (_, suggestions) => captured = suggestions,
      );

      final result = await manager.executeTool(
        name: suggestNextActionToolName,
        input: {
          'suggestions': [
            {
              'kind': 'prompt',
              'intent': 'agent_rule',
              'label': '保存规则',
              'prompt': '请保存视角规则',
            },
          ],
        },
      );

      expect(result, {'ok': true});
      expect(captured, hasLength(1));
      expect(captured!.single['kind'], 'prompt');
      expect(captured!.single['intent'], 'agent_rule');
    });

    test('handler 不等待用户操作：单个 turn 内即刻完成', () async {
      final manager = _buildManager(onSuggest: (_, _) {});

      // 没有任何东西 complete 它 —— 若实现照抄了 AskUser 的 Completer，
      // 这个 await 会永久挂起并让测试超时。
      await manager
          .executeTool(
            name: suggestNextActionToolName,
            input: {
              'suggestions': [
                {'kind': 'feature', 'label': '去圆桌', 'feature': 'ai_council'},
              ],
            },
          )
          .timeout(const Duration(seconds: 3));
    });

    test('非法项被丢弃，合法项照常挂', () async {
      List<Map<String, dynamic>>? captured;
      final manager = _buildManager(
        onSuggest: (_, suggestions) => captured = suggestions,
      );

      final result = await manager.executeTool(
        name: suggestNextActionToolName,
        input: {
          'suggestions': [
            {'kind': 'feature', 'label': '去魔法工坊', 'feature': 'ai_magic_forge'},
            {'kind': 'prompt', 'label': '缺 prompt'},
            {'kind': 'feature', 'label': '去小剧场', 'feature': 'ai_theater'},
          ],
        },
      );

      expect(result, {'ok': true});
      expect(captured, hasLength(1));
      expect(captured!.single['feature'], 'ai_theater');
    });

    test('全部被丢弃时仍返回 ok，挂上去的是空列表', () async {
      List<Map<String, dynamic>>? captured;
      final manager = _buildManager(
        onSuggest: (_, suggestions) => captured = suggestions,
      );

      final result = await manager.executeTool(
        name: suggestNextActionToolName,
        input: {
          'suggestions': [
            {'kind': 'unknown', 'label': '???'},
          ],
        },
      );

      expect(result, {'ok': true});
      expect(captured, isEmpty);
    });

    test('传 5 条 → 最多挂 3 条', () async {
      List<Map<String, dynamic>>? captured;
      final manager = _buildManager(
        onSuggest: (_, suggestions) => captured = suggestions,
      );

      await manager.executeTool(
        name: suggestNextActionToolName,
        input: {
          'suggestions': [
            for (var i = 0; i < 5; i++)
              {'kind': 'prompt', 'label': '建议 $i', 'prompt': '提示词 $i'},
          ],
        },
      );

      expect(captured, hasLength(3));
    });
  });
}

AiToolManager _buildManager({
  SuggestNextActionCallback? onSuggest,
  String contentKind = contentKindNovel,
}) {
  final db = NovelContentDatabase.forTest(NativeDatabase.memory());
  final appDb = AppDatabase.forTest(NativeDatabase.memory());
  final contentService = NovelContentService(db);
  addTearDown(() async {
    await db.close();
    await appDb.close();
  });
  return AiToolManager(
    contentService,
    workingOverlayService: WorkingOverlayService(
      db,
      contentService,
      novelActionsService: NovelActionsService(appDb),
    ),
    suggestNextActionCallback: onSuggest,
    contentKind: contentKind,
  )..registerAllTools();
}
