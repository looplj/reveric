// 职责: 验证旧技能迁移、文件读写和安装索引的持久化。
// 关联文件:
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/services/agent_skill_file_store.dart
//   lib/shared/database/daos/novel_agent_skill_revision_dao.dart

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/agent_skill_reference.dart';
import 'package:reveric/shared/models/agent_skill_revision.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/providers/novel_agent_skill_providers.dart';
import 'package:reveric/shared/services/agent_skill_file_store.dart';
import 'package:reveric/shared/services/app_initialization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late AppDatabase db;
  late Directory support;
  late AgentSkillFileStore store;
  late ProviderContainer container;
  InstalledAgentSkillsNotifier notifier() =>
      container.read(installedAgentSkillsProvider.notifier);

  void restart() {
    container = ProviderContainer(
      overrides: [
        agentSkillAppDatabaseProvider.overrideWithValue(db),
        agentSkillFileStoreProvider.overrideWithValue(store),
      ],
    );
  }

  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    support = await Directory.systemTemp.createTemp('reveric_skills_');
    store = AgentSkillFileStore(() async => support);
    restart();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await support.delete(recursive: true);
  });

  test('旧库迁移当前正文、附件和来源，保留旧历史且卸载后不重导', () async {
    const old = NovelAgentSkillModel(
      id: 'legacy',
      sourceKind: AgentSkillSourceKind.official,
      name: '片段处理',
      description: 'desc',
      prompt: '\n  indented body\n',
      enabled: false,
      sortOrder: 7,
      sourceVersion: '2',
      sourceDisplayName: 'source',
      sourceListingPublicId: 'listing',
      executionBlockedReason: 'blocked',
      tags: ['comma, inside'],
      references: [
        AgentSkillReferenceFile(path: 'references/说明.md', content: 'guide'),
      ],
    );
    await db.novelAgentSkillDao.upsertWithReferences(
      skill: NovelAgentSkillsCompanion.insert(
        id: old.id,
        sourceKind: old.sourceKind.dbValue,
        sourceVersion: Value(old.sourceVersion),
        sourceDisplayName: Value(old.sourceDisplayName),
        sourceListingPublicId: Value(old.sourceListingPublicId),
        name: old.name,
        description: old.description,
        prompt: old.prompt,
        enabled: Value(old.enabled),
        sortOrder: Value(old.sortOrder),
        executionBlockedReason: Value(old.executionBlockedReason),
        tags: Value(old.tags),
      ),
      references: old.references,
    );
    await db.novelAgentSkillRevisionDao.appendRevision(
      content: old,
      changeSource: SkillRevisionSource.baseline,
    );

    await expectLater(store.readCurrent(), throwsStateError);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProvider, (call) async {
      expect(call.method, 'getApplicationSupportDirectory');
      return support.path;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
    const migrationId = 'installed_agent_skills_to_files_v1';
    final task = defaultAppInitializationTasks().singleWhere(
      (task) => task.id == migrationId,
    );
    await ensureAppInitializationTasks(database: db, tasks: [task]);
    expect(
      await db.appStateDao.get('app_initialization.$migrationId'),
      isNotNull,
    );

    final installed = (await notifier().readCurrent()).single;
    expect(installed.id, old.id);
    expect(installed.sourceKind, old.sourceKind);
    expect(installed.sourceVersion, old.sourceVersion);
    expect(installed.sourceListingPublicId, old.sourceListingPublicId);
    expect(installed.sourceDisplayName, old.sourceDisplayName);
    expect(installed.enabled, isFalse);
    expect(installed.sortOrder, old.sortOrder);
    expect(installed.executionBlockedReason, old.executionBlockedReason);
    expect(installed.prompt, old.prompt);
    expect(installed.tags, old.tags);
    expect(installed.references, old.references);
    expect(
      await File(
        p.join(installed.skillRoot!, 'references', '说明.md'),
      ).readAsString(),
      'guide',
    );
    final updated = await notifier().updateSnapshotFields(
      installed.copyWith(prompt: 'updated'),
    );
    expect(updated.skillRoot, installed.skillRoot);
    expect(
      (await notifier().readCurrent()).single.executionBlockedReason,
      'blocked',
    );
    expect((await notifier().readCurrent()).single.prompt, 'updated');
    expect(
      await db.novelAgentSkillRevisionDao.listRevisions(old.id),
      hasLength(1),
    );

    final current = (await notifier().readCurrent()).single;
    await notifier().remove(installed.id);
    await ensureAppInitializationTasks(database: db, tasks: [task]);
    expect(await Directory(p.dirname(current.skillRoot!)).exists(), isFalse);
    container.dispose();
    restart();
    expect(await notifier().readCurrent(), isEmpty);
    expect(await db.novelAgentSkillDao.getById(old.id), isNotNull);
    expect(
      await db.novelAgentSkillRevisionDao.listRevisions(old.id),
      hasLength(1),
    );
  });

  test('旧库迁移跳过不兼容附件并继续打开和安装技能', () async {
    const compatible = AgentSkillReferenceFile(
      path: 'references/Guide.md',
      content: 'kept reference',
    );
    const legacyReferences = [
      compatible,
      AgentSkillReferenceFile(path: 'references/scene:1.md', content: 'colon'),
      AgentSkillReferenceFile(path: 'references/CON.md', content: 'reserved'),
      AgentSkillReferenceFile(path: 'references/guide.md', content: 'case'),
      AgentSkillReferenceFile(
        path: 'references/Guide.md/child.md',
        content: 'file and directory collision',
      ),
    ];
    await db.novelAgentSkillDao.upsertWithReferences(
      skill: NovelAgentSkillsCompanion.insert(
        id: 'legacy',
        name: 'Legacy skill',
        description: 'description',
        prompt: 'legacy prompt',
        sourceKind: AgentSkillSourceKind.novelLocal.dbValue,
      ),
      references: legacyReferences,
    );

    await store.migrateLegacy(db);
    final legacy = (await store.open()).single;
    expect(legacy.prompt, 'legacy prompt');
    expect(legacy.references, [compatible]);
    final root = Directory(
      p.join(support.path, AgentSkillFileStore.directoryName),
    );
    expect(await AgentSkillFileStore.hasMigrationMarker(root), isTrue);
    expect(
      (await db.novelAgentSkillDao.getReferencesBySkillIds([
        legacy.id,
      ]))[legacy.id],
      unorderedEquals(legacyReferences),
    );

    await expectLater(
      notifier().replaceReferencesByName(
        name: legacy.name,
        references: legacyReferences,
      ),
      throwsFormatException,
    );
    final added = await notifier().install(
      const InstallSkillInput(
        sourceKind: AgentSkillSourceKind.novelLocal,
        name: 'New skill',
        description: 'description',
        prompt: 'new prompt',
      ),
    );
    expect((await store.open()).map((skill) => skill.id), [
      legacy.id,
      added.id,
    ]);
  });

  test('索引丢失且启动任务尚未标记完成时也拒绝从旧库重导', () async {
    await db.novelAgentSkillDao.upsert(
      NovelAgentSkillsCompanion.insert(
        id: 'legacy',
        name: '旧技能',
        description: '旧内容',
        prompt: '来自数据库',
        sourceKind: AgentSkillSourceKind.novelLocal.dbValue,
      ),
    );
    await store.migrateLegacy(db);
    expect(await db.appStateDao.getAllByPrefix('app_initialization.'), isEmpty);
    expect((await store.readCurrent()).single.id, 'legacy');
    await store.remove('legacy');
    expect(await store.readCurrent(), isEmpty);

    final index = File(
      p.join(
        support.path,
        AgentSkillFileStore.directoryName,
        AgentSkillFileStore.indexName,
      ),
    );
    await index.rename(p.join(support.path, 'missing-index-simulation.json'));

    await expectLater(store.migrateLegacy(db), throwsStateError);
    expect(await index.exists(), isFalse);
    expect(await db.novelAgentSkillDao.getById('legacy'), isNotNull);

    // Stores created before the on-disk marker relied on the startup record.
    await File(
      p.join(index.parent.path, AgentSkillFileStore.migrationMarkerName),
    ).delete();
    await db.appStateDao.set(
      key: AgentSkillFileStore.migrationCompletedKey,
      value: '2026-01-01T00:00:00Z',
    );
    await expectLater(store.migrateLegacy(db), throwsStateError);
    expect(await index.exists(), isFalse);
  });

  test('修改磁盘正文后重新读取，编辑时保留二进制资源', () async {
    await store.migrateLegacy(db);
    final installed = await notifier().install(
      const InstallSkillInput(
        sourceKind: AgentSkillSourceKind.novelLocal,
        name: 'local',
        description: 'desc',
        prompt: 'initial',
        packageFiles: {
          'scripts/tool.py': [112, 97, 115, 115],
          'assets/nested/data.bin': [0, 255, 2],
          'References/opaque.md': [255, 0],
        },
      ),
    );
    final markdown = File(p.join(installed.skillRoot!, 'SKILL.md'));
    await markdown.writeAsString(
      '---\nname: local\ndescription: desc\n---\nfrom disk',
    );
    final edited = (await notifier().readCurrent()).single;
    expect(edited.prompt, 'from disk');
    await notifier().updateSnapshotFields(edited.copyWith(prompt: 'from app'));

    final current = (await notifier().readCurrent()).single;
    expect(current.prompt, 'from app');
    expect(current.references, isEmpty);
    expect(
      await File(
        p.join(current.skillRoot!, 'References', 'opaque.md'),
      ).readAsBytes(),
      [255, 0],
    );
    expect(
      await File(
        p.join(current.skillRoot!, 'assets', 'nested', 'data.bin'),
      ).readAsBytes(),
      [0, 255, 2],
    );
  });

  test('损坏的技能仍可卸载，正常技能和原来的同名项可用', () async {
    await store.migrateLegacy(db);
    Future<NovelAgentSkillModel> install(String name) => notifier().install(
      InstallSkillInput(
        sourceKind: AgentSkillSourceKind.novelLocal,
        name: name,
        description: 'desc',
        prompt: name,
      ),
    );
    final duplicate = await install('rename-me');
    final healthy = await install('healthy');
    final invalid = await install('invalid');
    final missing = await install('missing');
    final oversized = await install('oversized');
    await File(
      p.join(duplicate.skillRoot!, 'SKILL.md'),
    ).writeAsString('---\nname: healthy\ndescription: desc\n---\nchanged');
    await File(p.join(invalid.skillRoot!, 'SKILL.md')).writeAsString('bad');
    await Directory(missing.skillRoot!).delete(recursive: true);
    final reference = File(
      p.join(oversized.skillRoot!, 'references', 'big.md'),
    );
    await reference.create(recursive: true);
    await reference.writeAsBytes(
      List.filled(AgentSkillReferences.maxContentBytes + 1, 65),
    );

    container.dispose();
    restart();
    final current = await notifier().readCurrent();
    expect(current.map((item) => item.id), [
      duplicate.id,
      healthy.id,
      invalid.id,
      missing.id,
      oversized.id,
    ]);
    expect(current.where((item) => item.isExecutable).single.id, healthy.id);
    expect(
      current.singleWhere((item) => item.id == invalid.id).name,
      'invalid',
    );
    await expectLater(notifier().toggleEnabled(invalid.id), throwsStateError);
    expect(
      await File(p.join(invalid.skillRoot!, 'SKILL.md')).readAsString(),
      'bad',
    );

    for (final broken in [duplicate, invalid, missing, oversized]) {
      await notifier().remove(broken.id);
    }
    expect((await notifier().readCurrent()).single.name, 'healthy');
  });

  test('覆盖失败保留原安装，并发安装同名只成功一次', () async {
    await store.migrateLegacy(db);
    const input = InstallSkillInput(
      sourceKind: AgentSkillSourceKind.novelLocal,
      name: 'local',
      description: 'desc',
      prompt: 'initial',
      sourceVersion: 'old',
      packageFiles: {
        'scripts/old.py': [0],
      },
    );
    final first = notifier().install(input);
    final second = notifier().install(input);
    final duplicate = expectLater(
      second,
      throwsA(isA<NovelSkillNameConflictException>()),
    );
    final installed = await first;
    await duplicate;
    await expectLater(
      notifier().installOverwrite(
        input.copyWith(
          packageFiles: {
            'scripts/../outside': [0],
          },
        ),
      ),
      throwsFormatException,
    );
    expect((await notifier().readCurrent()).single.id, installed.id);
    expect(await Directory(installed.skillRoot!).exists(), isTrue);

    final other = await notifier().install(input.copyWith(name: 'other'));
    await notifier().toggleEnabled(installed.id);
    final replaced = await notifier().installOverwrite(
      const InstallSkillInput(
        sourceKind: AgentSkillSourceKind.novelLocal,
        name: 'local',
        description: 'desc',
        prompt: 'replacement',
      ),
    );
    expect(replaced.id, installed.id);
    expect(replaced.enabled, isFalse);
    expect(replaced.createdAt, installed.createdAt);
    expect(replaced.sortOrder, installed.sortOrder);
    expect(replaced.sourceVersion, isNull);
    expect(replaced.prompt, 'replacement');
    expect(replaced.skillRoot, installed.skillRoot);
    expect(
      await File(p.join(replaced.skillRoot!, 'scripts', 'old.py')).exists(),
      isFalse,
    );
    expect((await notifier().readCurrent()).map((item) => item.id), [
      installed.id,
      other.id,
    ]);
  });

  test('重新打开时清理旧包和已卸载包，保留当前安装', () async {
    await store.migrateLegacy(db);
    final installed = await notifier().install(
      const InstallSkillInput(
        sourceKind: AgentSkillSourceKind.novelLocal,
        name: 'local',
        description: 'desc',
        prompt: 'current',
      ),
    );
    final installDir = p.dirname(installed.skillRoot!);
    final root = p.dirname(installDir);
    final old = await Directory(
      p.join(installDir, 'pkg_0123456789ABCDEF'),
    ).create();
    final removed = await Directory(
      p.join(root, 'removed', 'pkg_0123456789ABCDEF'),
    ).create(recursive: true);
    final unrelated = await Directory(p.join(root, 'unrelated')).create();
    final external = await File(
      p.join(support.path, 'external.txt'),
    ).writeAsString('external');
    if (!Platform.isWindows) {
      await Link(p.join(old.path, 'external')).create(external.path);
    }

    container.dispose();
    restart();
    expect((await notifier().readCurrent()).single.prompt, 'current');
    expect(await old.exists(), isFalse);
    expect(await Directory(p.dirname(removed.path)).exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
    expect(await external.readAsString(), 'external');
    expect(await Directory(installed.skillRoot!).exists(), isTrue);
  });

  for (final committed in [false, true]) {
    test('重新打开中断更新时按索引恢复正确内容 committed=$committed', () async {
      await store.migrateLegacy(db);
      final installed = await notifier().install(
        const InstallSkillInput(
          sourceKind: AgentSkillSourceKind.novelLocal,
          name: 'local',
          description: 'desc',
          prompt: 'original',
        ),
      );
      final destination = Directory(installed.skillRoot!);
      final storeRoot = Directory(
        p.join(support.path, AgentSkillFileStore.directoryName),
      );
      final replacement = await Directory(
        p.join(storeRoot.path, '.reveric_replace_package'),
      ).create();
      await File(p.join(replacement.path, 'target.json')).writeAsString(
        jsonEncode({
          'id': installed.id,
          'package': p.basename(destination.path),
          'had_package': true,
        }),
      );
      final index = File(p.join(storeRoot.path, AgentSkillFileStore.indexName));
      final pendingIndex = await index.copy(
        p.join(replacement.path, AgentSkillFileStore.indexName),
      );
      final previous = await destination.rename(
        p.join(replacement.path, 'previous'),
      );
      await destination.create();
      final markdown = AgentSkillFileStore.markdownName;
      final original = await File(
        p.join(previous.path, markdown),
      ).readAsString();
      await File(
        p.join(destination.path, markdown),
      ).writeAsString(original.replaceFirst('original', 'updated'));
      if (committed) {
        await pendingIndex.rename(index.path);
      }

      container.dispose();
      restart();
      final reopened = (await notifier().readCurrent()).single;
      expect(reopened.skillRoot, installed.skillRoot);
      expect(reopened.prompt, committed ? 'updated' : 'original');
      expect(await replacement.exists(), isFalse);
    });
  }
}
