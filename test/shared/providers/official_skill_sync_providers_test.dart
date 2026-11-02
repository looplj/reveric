// 职责: 验证启动同步安装、升级与卸载官方技能，维护附件历史并尊重本地技能和删除选择。
// 关联文件:
//   lib/shared/providers/official_skill_sync_providers.dart
//   lib/shared/services/official_skill_sync.dart
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/database/app_database.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/testing.md
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/agent_skill_revision.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/providers/agent_skill_catalog_providers.dart';
import 'package:reveric/shared/providers/agent_skill_providers.dart';
import 'package:reveric/shared/providers/official_skill_sync_providers.dart';
import 'package:reveric/shared/providers/novel_agent_skill_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/agent_skill_catalog_service.dart';
import 'package:reveric/shared/services/app_initialization.dart';
import 'package:reveric/shared/services/bundled_official_skills.dart';
import 'package:reveric/shared/services/official_skill_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => rootBundle.clear());

  test(
    'packaged catalog installs all official skills with full references',
    () async {
      final setup = _TestSetup(
        AppDatabase.forTest(NativeDatabase.memory()),
        _BundledCatalogService(),
      );
      addTearDown(setup.dispose);
      await markOnboardingCompleted(setup.database);
      final result = await setup.sync();
      expect(result.failed, 0);
      expect(result.installed, bundledOfficialSkillSpecs.length);
      final installed = await setup.skills();
      for (final spec in bundledOfficialSkillSpecs) {
        final skill = installed.singleWhere((s) => s.name == spec.name);
        final source = await const BundledOfficialSkillsLoader().get(
          rootBundle,
          spec.name,
        );
        expect(skill.prompt, source.prompt);
        expect(skill.sourceVersion, '${source.version}');
        expect(skill.references, [
          for (final ref in source.references)
            AgentSkillReferenceFile(path: ref.path, content: ref.content),
        ]);
      }
    },
  );

  test(
    'merged catalog removes legacy installations and their child rows',
    () async {
      final setup = _TestSetup(
        AppDatabase.forTest(NativeDatabase.memory()),
        _BundledCatalogService(),
      );
      addTearDown(setup.dispose);
      final notifier = setup.container.read(
        installedAgentSkillsProvider.notifier,
      );
      final retired = <NovelAgentSkillModel>[];
      for (final name in ['剧本改编', '分集规划', '剧本对白', '剧本审查', '剧本对白']) {
        retired.add(
          await notifier.install(
            InstallSkillInput(
              sourceKind: AgentSkillSourceKind.official,
              sourceListingPublicId: 'legacy-listing-${retired.length}',
              sourceDisplayName: name,
              sourceVersion: '4',
              name: '旧技能 ${retired.length}',
              description: '旧官方技能',
              prompt: 'old prompt',
              enabled: retired.length.isEven,
              references: const [
                AgentSkillReferenceFile(
                  path: 'references/old.md',
                  content: 'shared old reference',
                ),
              ],
            ),
          ),
        );
      }
      final local = await notifier.install(
        const InstallSkillInput(
          sourceKind: AgentSkillSourceKind.official,
          sourceDisplayName: '剧本对白',
          name: '我的对白',
          description: '保留',
          prompt: 'local prompt',
          references: [
            AgentSkillReferenceFile(
              path: 'references/old.md',
              content: 'shared old reference',
            ),
          ],
        ),
      );
      await notifier.convertToNovelLocal(local.id);
      final writing = await notifier.install(
        const InstallSkillInput(
          sourceKind: AgentSkillSourceKind.official,
          sourceDisplayName: '剧本写作',
          sourceVersion: '0',
          name: '我的剧本写作',
          description: '旧写作',
          prompt: 'old writing',
          enabled: false,
        ),
      );
      final retiredRevisionIds = <String>[];
      for (final skill in retired) {
        final revisions = await setup.database.novelAgentSkillRevisionDao
            .listRevisions(skill.id);
        retiredRevisionIds.addAll(revisions.map((revision) => revision.id));
      }
      setup.restart();
      final result = await setup.sync();
      expect(result.uninstalled, 5);
      expect(result.upgraded, 1);
      expect(result.failed, 0);
      final after = await setup.skills();
      for (final skill in retired) {
        expect(after.map((s) => s.id), isNot(contains(skill.id)));
        expect(
          await setup.database.novelAgentSkillDao.getById(skill.id),
          isNull,
        );
        expect(
          await setup.database.novelAgentSkillRevisionDao.listRevisions(
            skill.id,
          ),
          isEmpty,
        );
      }
      expect(
        await setup.database.novelAgentSkillDao.getReferencesBySkillIds(
          retired.map((skill) => skill.id),
        ),
        isEmpty,
      );
      final files = setup.database.novelAgentSkillRevisionFiles;
      expect(
        await (setup.database.select(
          files,
        )..where((row) => row.revisionId.isIn(retiredRevisionIds))).get(),
        isEmpty,
      );
      final keptLocal = after.singleWhere((skill) => skill.id == local.id);
      expect(keptLocal.sourceKind, AgentSkillSourceKind.novelLocal);
      expect(keptLocal.prompt, local.prompt);
      expect(keptLocal.references, local.references);
      final localHistory = await setup.database.novelAgentSkillRevisionDao
          .listRevisions(local.id);
      final localRevision = await setup.database.novelAgentSkillRevisionDao
          .getRevision(localHistory.first.id);
      expect(localRevision!.references, local.references);
      final upgraded = after.singleWhere((skill) => skill.id == writing.id);
      expect(upgraded.name, writing.name);
      expect(upgraded.enabled, isFalse);
      expect(upgraded.sortOrder, writing.sortOrder);
      expect(upgraded.sourceVersion, '2');
      expect(upgraded.references, hasLength(6));
      final slashSkills = await loadChatSlashSkills(db: setup.database);
      expect(
        slashSkills
            .map((skill) => skill.id)
            .toSet()
            .intersection(retired.map((skill) => skill.id).toSet()),
        isEmpty,
      );
      setup.restart();
      final repeat = await setup.sync();
      expect(repeat.uninstalled, 0);
      expect(repeat.installed, 0);
      expect(repeat.upgraded, 0);
      expect(
        (await setup.skills()).map((skill) => skill.id).toSet(),
        after.map((skill) => skill.id).toSet(),
      );
    },
  );

  test(
    'two startup readers share slow installation without a page listener',
    () async {
      final detailReady = Completer<void>();
      final setup = _setup(detailReady: detailReady.future);
      addTearDown(setup.dispose);
      final first = setup.sync();
      final second = setup.sync();
      await setup.catalog.firstDetailRequested.future.timeout(
        const Duration(seconds: 5),
      );
      await pumpEventQueue();
      detailReady.complete();
      expect((await first).installed, setup.catalog.names.length);
      await second;
      expect(setup.catalog.requestedIds, setup.catalog.listingIds);
      expect(
        (await setup.skills()).map((skill) => skill.name),
        setup.catalog.names,
      );
    },
  );

  test(
    'existing users receive snapshots, references and install history once',
    () async {
      final setup = _setup();
      addTearDown(setup.dispose);
      await markOnboardingCompleted(setup.database);
      await setup.database.appStateDao.set(
        key: 'app_initialization.screenplay_official_skills_v1',
        value: 'completed',
      );
      expect((await setup.sync()).installed, setup.catalog.names.length);
      final installed = await setup.skills();
      expect(
        installed.map((skill) => skill.sourceKind),
        everyElement(AgentSkillSourceKind.official),
      );
      expect(setup.catalog.requestedIds, setup.catalog.listingIds);
      for (final skill in installed) {
        expect(skill.enabled, isTrue);
        expect(skill.references, const [
          AgentSkillReferenceFile(
            path: 'references/design.md',
            content: 'reference v1',
          ),
        ]);
        final revisions = await setup.database.novelAgentSkillRevisionDao
            .listRevisions(skill.id);
        expect(revisions, hasLength(1));
        expect(revisions.single.changeSource, SkillRevisionSource.install);
        final revision = await setup.database.novelAgentSkillRevisionDao
            .getRevision(revisions.single.id);
        expect(revision!.references, skill.references);
      }
      setup.restart();
      expect((await setup.sync()).installed, 0);
      expect(
        (await setup.skills()).map((s) => s.id),
        installed.map((s) => s.id),
      );
      expect(setup.catalog.requestedIds, setup.catalog.listingIds);
    },
  );

  test(
    'deleted skills stay removed after restart while new catalog entries install',
    () async {
      final setup = _setup();
      addTearDown(setup.dispose);
      await setup.sync();
      final removed = (await setup.skills()).first;
      await setup.container
          .read(installedAgentSkillsProvider.notifier)
          .remove(removed.id);
      setup.catalog.names.add('新增技能');
      setup.restart();
      final result = await setup.sync();
      expect(result.installed, 1);
      expect(result.failed, 0);
      final after = await setup.skills();
      expect(after.map((s) => s.name), isNot(contains(removed.name)));
      expect(after.map((s) => s.name), contains('新增技能'));
    },
  );

  test(
    'renamed disabled official skills upgrade without duplicate installation',
    () async {
      final setup = _setup();
      addTearDown(setup.dispose);
      await setup.sync();
      final original = (await setup.skills()).first;
      final notifier = setup.container.read(
        installedAgentSkillsProvider.notifier,
      );
      await notifier.rename(original.id, '我的章节写作');
      await notifier.toggleEnabled(original.id);
      setup.catalog.version = 2;
      setup.restart();
      final result = await setup.sync();
      expect(result.installed, 0);
      expect(result.upgraded, setup.catalog.names.length);
      final after = await setup.skills();
      expect(after, hasLength(setup.catalog.names.length));
      final upgraded = after.singleWhere((s) => s.id == original.id);
      expect(upgraded.name, '我的章节写作');
      expect(upgraded.enabled, isFalse);
      expect(upgraded.sourceVersion, '2');
      expect(upgraded.references.single.content, 'reference v2');
    },
  );

  test(
    'local conversion plus rename is not replaced or installed again',
    () async {
      final setup = _setup();
      addTearDown(setup.dispose);
      await setup.sync();
      final original = (await setup.skills()).first;
      final notifier = setup.container.read(
        installedAgentSkillsProvider.notifier,
      );
      await notifier.convertToNovelLocal(original.id);
      await notifier.rename(original.id, '我的本地技能');
      setup.catalog.version = 2;
      setup.restart();
      final result = await setup.sync();
      expect(result.installed, 0);
      expect(result.upgraded, setup.catalog.names.length - 1);
      final local = (await setup.skills()).singleWhere(
        (s) => s.id == original.id,
      );
      expect(local.sourceKind, AgentSkillSourceKind.novelLocal);
      expect(local.name, '我的本地技能');
      expect(local.prompt, original.prompt);
    },
  );

  test(
    'pre-existing local name is preserved and recorded as handled',
    () async {
      final setup = _setup();
      addTearDown(setup.dispose);
      final local = await setup.container
          .read(installedAgentSkillsProvider.notifier)
          .createNovelLocalSkill(
            InstallSkillInput(
              sourceKind: AgentSkillSourceKind.novelLocal,
              name: setup.catalog.names.first,
              description: 'keep',
              prompt: 'local',
              enabled: false,
            ),
          );
      expect((await setup.sync()).installed, setup.catalog.names.length - 1);
      final after = (await setup.skills()).singleWhere((s) => s.id == local.id);
      expect(after.prompt, 'local');
      expect(after.enabled, isFalse);
      await setup.container
          .read(installedAgentSkillsProvider.notifier)
          .remove(local.id);
      setup.restart();
      expect((await setup.sync()).installed, 0);
    },
  );

  test(
    'failed detail retries next startup without duplicate successful installs',
    () async {
      final setup = _setup(failOnceListingId: 'debug-listing-1');
      addTearDown(setup.dispose);
      final first = await setup.sync();
      expect(first.installed, setup.catalog.names.length - 1);
      expect(first.failed, 1);
      final partial = await setup.skills();
      setup.restart();
      final retry = await setup.sync();
      expect(retry.installed, 1);
      expect(retry.failed, 0);
      final after = await setup.skills();
      expect(after, hasLength(setup.catalog.names.length));
      for (final skill in partial) {
        expect(after.map((s) => s.id), contains(skill.id));
        expect(
          await setup.database.novelAgentSkillRevisionDao.listRevisions(
            skill.id,
          ),
          hasLength(1),
        );
      }
    },
  );
}

class _TestSetup {
  _TestSetup(this.database, this.catalog) {
    container = _container();
  }
  final AppDatabase database;
  final _FakeCatalogService catalog;
  late ProviderContainer container;

  ProviderContainer _container() => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      agentSkillAppDatabaseProvider.overrideWithValue(database),
      agentSkillCatalogServiceProvider.overrideWithValue(catalog),
    ],
  );
  Future<OfficialSkillSyncResult> sync() =>
      container.read(officialSkillSyncProvider.future);
  Future<List<NovelAgentSkillModel>> skills() =>
      container.read(installedAgentSkillsProvider.future);
  void restart() {
    container.dispose();
    container = _container();
  }

  Future<void> dispose() async {
    container.dispose();
    await database.close();
  }
}

_TestSetup _setup({String? failOnceListingId, Future<void>? detailReady}) =>
    _TestSetup(
      AppDatabase.forTest(NativeDatabase.memory()),
      _FakeCatalogService(
        failOnceListingId: failOnceListingId,
        detailReady: detailReady,
      ),
    );

class _FakeCatalogService extends AgentSkillCatalogService {
  _FakeCatalogService({this.failOnceListingId, this.detailReady});

  final names = <String>['章节写作', '地图设计指南', '剧本对白'];
  int version = 1;
  List<String> get listingIds => [
    for (var i = 0; i < names.length; i++) 'debug-listing-$i',
  ];
  final String? failOnceListingId;
  final Future<void>? detailReady;
  final firstDetailRequested = Completer<void>();
  final List<String> requestedIds = [];
  final Set<String> _failedIds = {};

  @override
  Future<OfficialAgentSkill> getOfficial({required String listingId}) async {
    requestedIds.add(listingId);
    if (!firstDetailRequested.isCompleted) {
      firstDetailRequested.complete();
    }
    if (detailReady != null) {
      await detailReady;
    }
    if (listingId == failOnceListingId && _failedIds.add(listingId)) {
      throw StateError('temporary catalog failure');
    }
    final index = listingIds.indexOf(listingId);
    return OfficialAgentSkill(
      listingId: listingId,
      name: names[index],
      whenToUse: 'when default $index',
      description: 'description $index',
      prompt: 'prompt $index v$version',
      references: [
        AgentSkillReferenceFile(
          path: 'references/design.md',
          content: 'reference v$version',
        ),
      ],
      category: 'writing',
      tags: const [],
      version: version,
      updatedAt: '2026-08-02T00:00:00Z',
      sortOrder: index,
    );
  }

  @override
  Future<OfficialAgentSkillCatalog> listOfficial() async =>
      OfficialAgentSkillCatalog(
        agentSkills: [
          for (var index = 0; index < names.length; index++)
            OfficialAgentSkillSummary(
              listingId: listingIds[index],
              name: names[index],
              description: 'description $index',
              category: 'writing',
              tags: const [],
              version: version,
              updatedAt: '2026-08-02T00:00:00Z',
            ),
        ],
      );
}

class _BundledCatalogService extends _FakeCatalogService {
  @override
  Future<OfficialAgentSkillCatalog> listOfficial() =>
      const BundledOfficialSkillsLoader().list(rootBundle);

  @override
  Future<OfficialAgentSkill> getOfficial({required String listingId}) =>
      const BundledOfficialSkillsLoader().get(rootBundle, listingId);
}
