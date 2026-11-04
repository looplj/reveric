// 职责: 测试 AI 工具设计的正交性与一致性 — 工具目录、schema、描述交叉验证
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_create.dart
//   lib/shared/services/ai/tools_write.dart
//   lib/shared/services/ai/tools_edit.dart
//   lib/shared/services/ai/tools_glob.dart
//   lib/shared/services/ai/tools_grep.dart
//   lib/shared/services/ai/tools_outline.dart
//   lib/shared/services/ai/tools_remove.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  group('Tool catalog integrity', () {
    test('CreateEntry is removed from catalog', () {
      final names = aiToolCatalog.map((e) => e.name).toList();
      expect(names, isNot(contains('CreateEntry')));
    });

    test('Search is not exposed in the tool registry', () {
      final names = aiToolCatalog.map((e) => e.name).toList();
      expect(names, isNot(contains('Search')));
    });

    test('Create, Edit, and Replace are in catalog', () {
      final names = aiToolCatalog.map((e) => e.name).toList();
      expect(names, contains('Create'));
      expect(names, contains('Edit'));
      expect(names, contains('Replace'));
    });

    test('Glob and Grep are exposed as resource search tools', () {
      final names = aiToolCatalog.map((e) => e.name).toList();
      expect(names, contains('Glob'));
      expect(names, contains('Grep'));
      expect(
        aiToolCatalog.firstWhere((e) => e.name == 'Glob').group,
        AiToolGroup.search,
      );
      expect(
        aiToolCatalog.firstWhere((e) => e.name == 'Grep').group,
        AiToolGroup.search,
      );
    });

    test('Create belongs to AiToolGroup.create', () {
      final entry = aiToolCatalog.firstWhere((e) => e.name == 'Create');
      expect(entry.group, AiToolGroup.create);
      expect(entry.agentConfigurable, isTrue);
      expect(entry.subAgentConfigurable, isTrue);
    });

    test('Edit belongs to AiToolGroup.edit', () {
      final entry = aiToolCatalog.firstWhere((e) => e.name == 'Edit');
      expect(entry.group, AiToolGroup.edit);
      expect(entry.agentConfigurable, isTrue);
    });

    test('no duplicate tool names in catalog', () {
      final names = aiToolCatalog.map((e) => e.name).toList();
      expect(names.length, names.toSet().length);
    });

    test('legacy CreateX/EditX tools are removed from catalog', () {
      final names = aiToolCatalog.map((e) => e.name).toList();
      expect(names, isNot(contains('CreateChapter')));
      expect(names, isNot(contains('CreateOutline')));
      expect(names, isNot(contains('CreateBeat')));
      expect(names, isNot(contains('CreateVolume')));
      expect(names, isNot(contains('CreateCharacter')));
      expect(names, isNot(contains('CreateLocation')));
      expect(names, isNot(contains('CreateForeshadowing')));
      expect(names, isNot(contains('EditOutline')));
      expect(names, isNot(contains('EditBeat')));
    });

    test('catalog contains exactly expected Create tools', () {
      final createTools = aiToolCatalog
          .where((e) => e.group == AiToolGroup.create)
          .map((e) => e.name)
          .toSet();
      expect(createTools, {'Create'});
    });

    test('catalog contains exactly expected Write+Edit tools', () {
      final writeTools = aiToolCatalog
          .where((e) => e.group == AiToolGroup.write)
          .map((e) => e.name)
          .toSet();
      final editTools = aiToolCatalog
          .where((e) => e.group == AiToolGroup.edit)
          .map((e) => e.name)
          .toSet();
      expect(writeTools, {'Write', 'Remove'});
      expect(editTools, {'Edit', 'Replace'});
    });
  });

  group('Default agent tools', () {
    test('default agent tools include Create and Edit', () {
      final names = defaultAgentToolNames();
      expect(names, contains('Create'));
      expect(names, contains('Edit'));
      expect(names, isNot(contains('CreateOutline')));
      expect(names, isNot(contains('CreateVolume')));
      expect(names, isNot(contains('EditOutline')));
    });

    test('default agent tools do not include CreateEntry', () {
      final names = defaultAgentToolNames();
      expect(names, isNot(contains('CreateEntry')));
    });

    test('default tools do not include Search', () {
      expect(defaultAgentToolNames(), isNot(contains('Search')));
      expect(defaultSubAgentToolNames(), isNot(contains('Search')));
    });

    test('default tools include resource Glob and Grep', () {
      expect(defaultAgentToolNames(), contains('Glob'));
      expect(defaultAgentToolNames(), contains('Grep'));
      expect(defaultSubAgentToolNames(), contains('Glob'));
      expect(defaultSubAgentToolNames(), contains('Grep'));
    });

    test('default tools include Run for agents and subagents', () {
      expect(defaultAgentToolNames(), contains('Run'));
      expect(defaultSubAgentToolNames(), contains('Run'));
    });

    test(
      'default sub-agent tools include Create but not legacy CreateX tools',
      () {
        final names = defaultSubAgentToolNames();
        expect(names, contains('Create'));
        expect(names, isNot(contains('CreateOutline')));
        expect(names, isNot(contains('CreateVolume')));
      },
    );

    test('default sub-agent tools exclude AskUser and SpawnAgent', () {
      final names = defaultSubAgentToolNames();
      expect(names, isNot(contains('AskUser')));
      expect(names, isNot(contains(spawnAgentToolName)));
      expect(names, isNot(contains(forkAgentToolName)));
    });

    test(
      'SpawnAgent registers with subAgentListProvider, ForkAgent does not',
      () {
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        final appDb = AppDatabase.forTest(NativeDatabase.memory());
        final contentService = NovelContentService(db);
        final manager = AiToolManager(
          contentService,
          workingOverlayService: WorkingOverlayService(
            db,
            contentService,
            novelActionsService: NovelActionsService(appDb),
          ),
          subAgentListProvider: () => const [],
        )..registerAllTools();

        addTearDown(() async {
          await db.close();
          await appDb.close();
        });

        expect(manager.allToolNames(), contains(spawnAgentToolName));
        expect(manager.allToolNames(), isNot(contains(forkAgentToolName)));
      },
    );

    test('SpawnAgent schema only creates new sessions', () {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      final contentService = NovelContentService(db);
      final manager = AiToolManager(
        contentService,
        workingOverlayService: WorkingOverlayService(
          db,
          contentService,
          novelActionsService: NovelActionsService(appDb),
        ),
        subAgentListProvider: () => const [],
      )..registerAllTools();

      addTearDown(() async {
        await db.close();
        await appDb.close();
      });

      final def = manager.allToolDefs().firstWhere(
        (tool) => tool.name == spawnAgentToolName,
      );
      final properties = def.inputSchema['properties'] as Map;
      expect(properties, isNot(contains('session_id')));
      expect(properties, contains('agent'));
      expect(def.inputSchema['required'], ['agent', 'name', 'task']);
    });

    test('tool definitions do not expose Search', () {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      final contentService = NovelContentService(db);
      final manager = AiToolManager(
        contentService,
        workingOverlayService: WorkingOverlayService(
          db,
          contentService,
          novelActionsService: NovelActionsService(appDb),
        ),
      )..registerAllTools();

      addTearDown(() async {
        await db.close();
        await appDb.close();
      });

      expect(
        manager.allToolDefs().map((tool) => tool.name),
        isNot(contains('Search')),
      );
      expect(
        manager.allToolDefs().map((tool) => tool.name),
        containsAll(['Create', 'Glob', 'Grep']),
      );
      expect(
        manager
            .toolDefsForNames(const ['Read', 'Search'])
            .map((tool) => tool.name),
        contains('Read'),
      );
      expect(
        manager
            .toolDefsForNames(const ['Read', 'Search'])
            .map((tool) => tool.name),
        isNot(contains('Search')),
      );
    });
  });

  group('Strip chapter title prefix', () {
    test('strips "第X章" prefix with Chinese numerals', () {
      expect(AiToolManager.stripChapterTitlePrefix('第一章 新的开始'), '新的开始');
    });

    test('strips "第X章" prefix with Arabic digits', () {
      expect(AiToolManager.stripChapterTitlePrefix('第1章 新的开始'), '新的开始');
    });

    test('returns empty for prefix-only input', () {
      expect(AiToolManager.stripChapterTitlePrefix('第1章'), '');
    });

    test('returns unchanged when no prefix', () {
      expect(AiToolManager.stripChapterTitlePrefix('新的开始'), '新的开始');
    });

    test('returns empty for empty input', () {
      expect(AiToolManager.stripChapterTitlePrefix(''), '');
    });
  });
}
