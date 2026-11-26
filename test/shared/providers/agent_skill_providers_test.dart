// 职责: AgentSkill Provider 回归测试 — 验证 chat slash 已安装技能筛选与实时刷新。
// 关联文件:
//   lib/shared/providers/agent_skill_providers.dart
//   lib/shared/models/agent_skill.dart
//   lib/shared/database/app_database.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/agent_skill.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/providers/agent_skill_providers.dart';
import 'package:reveric/shared/providers/novel_agent_skill_providers.dart';
import 'package:reveric/shared/services/agent_skill_file_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'chatSlashSkillsProvider refreshes after an installed skill is persisted',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final support = await Directory.systemTemp.createTemp('reveric_slash_');
      final store = AgentSkillFileStore(() async => support);
      await store.migrateLegacy(db);
      final container = ProviderContainer(
        overrides: [
          agentSkillAppDatabaseProvider.overrideWithValue(db),
          agentSkillFileStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
        await support.delete(recursive: true);
      });

      final initialLoad = Completer<List<SkillDefinition>>();
      final refreshed = Completer<List<SkillDefinition>>();
      final subscription = container.listen(chatSlashSkillsProvider, (
        previous,
        next,
      ) {
        final skills = next.asData?.value;
        if (skills == null) {
          return;
        }
        if (!initialLoad.isCompleted) {
          initialLoad.complete(skills);
        }
        if (skills.any((skill) => skill.name == 'my_skill') &&
            !refreshed.isCompleted) {
          refreshed.complete(skills);
        }
      });
      addTearDown(subscription.close);

      final initial = await initialLoad.future.timeout(
        const Duration(seconds: 2),
      );
      expect(initial.map((skill) => skill.name), isNot(contains('my_skill')));

      final notifier = container.read(installedAgentSkillsProvider.notifier);
      final skill = await notifier.install(
        const InstallSkillInput(
          sourceKind: AgentSkillSourceKind.novelLocal,
          name: 'my_skill',
          description: 'Imported skill',
          prompt: 'Do the imported work.',
        ),
      );

      final updated = await refreshed.future.timeout(
        const Duration(seconds: 2),
      );
      expect(updated.single.name, 'my_skill');
      expect(updated.single.skillRoot, skill.skillRoot);
      await notifier.toggleEnabled(skill.id);
      expect(container.read(chatSlashSkillsProvider).requireValue, isEmpty);
      expect(
        await db.appStateDao.getAllByPrefix('app_initialization.'),
        isEmpty,
        reason: '技能订阅和刷新只读已迁移的文件索引',
      );
    },
  );
}
