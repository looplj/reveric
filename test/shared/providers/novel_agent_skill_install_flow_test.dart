// 职责: AgentSkill 安装治理回归测试 — 验证应用全局技能的目录安装/升级、
//   同名覆盖与快照保留契约。
// 关联文件:
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/providers/agent_skill_catalog_providers.dart
//   lib/shared/models/official_agent_skill.dart
//   lib/shared/services/agent_skill_catalog_service.dart
//   lib/shared/database/app_database.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/error-handling.md
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/providers/agent_skill_catalog_providers.dart';
import 'package:reveric/shared/providers/novel_agent_skill_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/agent_skill_catalog_service.dart';
import 'package:reveric/shared/services/agent_skill_file_store.dart';

void main() {
  group('installFromOfficial', () {
    test(
      'no conflict: writes skill with correct fields and sort_order',
      () async {
        final setup = await _setup();
        addTearDown(setup.tearDown);

        const source = OfficialAgentSkill(
          listingId: 'official-listing-1',
          name: 'Weather',
          whenToUse: 'when weather',
          description: 'weather desc',
          prompt: 'weather prompt',
          category: 'utils',
          tags: ['weather'],
          version: 3,
          sortOrder: 0,
          updatedAt: '2026-01-01T00:00:00Z',
        );

        final result = await setup.notifier.installFromOfficial(source: source);

        expect(result, isA<InstallFromCatalogSuccess>());
        final success = result as InstallFromCatalogSuccess;
        expect(success.novelAgentSkillId, isNotEmpty);

        final skills = setup.readState();
        expect(skills.length, 1);
        final skill = skills.first;
        expect(skill.id, success.novelAgentSkillId);
        expect(skill.sourceKind, AgentSkillSourceKind.official);
        expect(skill.sourceListingPublicId, 'official-listing-1');
        expect(skill.sourceVersion, '3');
        expect(skill.sourceDisplayName, 'Weather');
        expect(skill.name, 'Weather');
        expect(skill.whenToUse, 'when weather');
        expect(skill.description, 'weather desc');
        expect(skill.prompt, 'weather prompt');
        // 目录详情不包含 agent_scopes，本地默认为空。
        expect(skill.agentScopes, isEmpty);
        expect(skill.category, 'utils');
        expect(skill.tags, ['weather']);
        expect(skill.enabled, isTrue);
        expect(skill.sortOrder, 0);
        expect(skill.executionBlockedReason, isNull);
      },
    );

    test('installs references snapshot from official detail', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      const source = OfficialAgentSkill(
        listingId: 'official-listing-refs',
        name: 'Forms',
        whenToUse: 'when forms',
        description: 'forms desc',
        prompt: 'forms prompt',
        category: 'utils',
        tags: ['forms'],
        version: 1,
        sortOrder: 0,
        updatedAt: '2026-01-01T00:00:00Z',
        references: [
          AgentSkillReferenceFile(
            path: 'references/forms.md',
            content: '# Forms',
          ),
        ],
      );

      final result = await setup.notifier.installFromOfficial(source: source);
      expect(result, isA<InstallFromCatalogSuccess>());

      final skill = setup.readState().single;
      expect(skill.references, hasLength(1));
      expect(skill.references.single.path, 'references/forms.md');
      expect(skill.references.single.content, '# Forms');
    });

    test('second install gets sort_order = 1', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      await setup.notifier.installFromOfficial(
        source: _officialDto('Alpha', version: 1),
      );
      await setup.notifier.installFromOfficial(
        source: _officialDto('Beta', version: 1),
      );

      final skills = setup.readState();
      expect(skills.length, 2);
      expect(skills[0].name, 'Alpha');
      expect(skills[0].sortOrder, 0);
      expect(skills[1].name, 'Beta');
      expect(skills[1].sortOrder, 1);
    });

    test(
      'conflict: returns InstallFromCatalogConflict and does not write',
      () async {
        final setup = await _setup();
        addTearDown(setup.tearDown);

        await setup.notifier.installFromOfficial(
          source: _officialDto('Weather', version: 1),
        );
        final before = setup.readState();

        final result = await setup.notifier.installFromOfficial(
          source: _officialDto('Weather', version: 2),
        );

        expect(result, isA<InstallFromCatalogConflict>());
        final conflict = result as InstallFromCatalogConflict;
        expect(conflict.conflictingName, 'Weather');
        expect(conflict.existingId, isNotEmpty);

        final after = setup.readState();
        expect(after.length, before.length);
        expect(after.first.sourceVersion, '1');
      },
    );

    test('overrideName: uses provided name', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      await setup.notifier.installFromOfficial(
        source: _officialDto('Weather', version: 1),
      );
      final result = await setup.notifier.installFromOfficial(
        source: _officialDto('Weather', version: 2),
        overrideName: 'Weather_v2',
      );

      expect(result, isA<InstallFromCatalogSuccess>());
      final skills = setup.readState();
      expect(skills.length, 2);
      expect(skills.last.name, 'Weather_v2');
    });
  });

  group('overwriteInstall', () {
    test('official overwrite replaces the local package', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      final original = await setup.notifier.install(
        const InstallSkillInput(
          sourceKind: AgentSkillSourceKind.novelLocal,
          name: 'Weather',
          description: 'Local skill',
          prompt: 'Local instructions',
          packageFiles: {
            'scripts/old.py': [1],
            'assets/old.bin': [2],
          },
        ),
      );
      final originalId = original.id;

      // 禁用 + 改 sortOrder 验证保留。
      await setup.notifier.toggleEnabled(originalId);
      await setup.notifier.reorder([originalId]);
      final toggled = setup.readState().firstWhere((s) => s.id == originalId);
      expect(toggled.enabled, isFalse);

      // 覆盖安装为 official v4;name 相同,用 overwriteInstall 显式覆盖。
      final newDto = _officialDto('Weather', version: 4);
      final returnedId = await setup.notifier.overwriteInstall(
        existingNovelAgentSkillId: originalId,
        source: InstallFromOfficialSource(newDto),
      );

      expect(returnedId, originalId);
      final overwritten = setup.readState().firstWhere(
        (s) => s.id == originalId,
      );
      // 保留字段。
      expect(overwritten.id, original.id);
      expect(overwritten.name, original.name);
      expect(overwritten.skillRoot, original.skillRoot);
      expect(overwritten.enabled, isFalse); // 保留禁用态
      expect(overwritten.sortOrder, original.sortOrder);
      expect(overwritten.createdAt, original.createdAt);
      // 覆盖字段。
      expect(overwritten.sourceKind, AgentSkillSourceKind.official);
      expect(overwritten.sourceListingPublicId, newDto.listingId);
      expect(overwritten.sourceVersion, '4');
      expect(overwritten.sourceDisplayName, 'Weather');
      expect(overwritten.prompt, newDto.prompt);
      expect(overwritten.tags, newDto.tags);
      expect(
        await File('${original.skillRoot}/scripts/old.py').exists(),
        isFalse,
      );
      expect(
        await File('${original.skillRoot}/assets/old.bin').exists(),
        isFalse,
      );
      // 清空 blocked reason。
      expect(overwritten.executionBlockedReason, isNull);
      // 列表长度不变(没有新增)。
      expect(setup.readState().length, 1);
    });

    test(
      'overwrite from marketplace to official saves official listing_id',
      () async {
        final setup = await _setup();
        addTearDown(setup.tearDown);

        final installed = await setup.notifier.install(
          const InstallSkillInput(
            sourceKind: AgentSkillSourceKind.marketplace,
            sourceListingPublicId: 'market-listing',
            sourceVersion: '1',
            name: 'Market Skill',
            description: '',
            prompt: 'saved content',
          ),
        );
        final id = installed.id;

        await setup.notifier.overwriteInstall(
          existingNovelAgentSkillId: id,
          source: InstallFromOfficialSource(
            _officialDto('Market Skill', version: 2),
          ),
        );

        final overwritten = setup.readState().firstWhere((s) => s.id == id);
        expect(overwritten.sourceKind, AgentSkillSourceKind.official);
        expect(overwritten.sourceListingPublicId, 'official-listing');
        expect(overwritten.sourceVersion, '2');
      },
    );
  });

  group('upgradeNovelAgentSkill', () {
    test('official: finds higher version and overwrites snapshot', () async {
      final fake = _FakeCatalogService(
        officialList: OfficialAgentSkillCatalog(
          agentSkills: [
            _officialDto(
              'Weather',
              version: 2,
              prompt: 'v2 prompt',
              references: const [
                AgentSkillReferenceFile(
                  path: 'references/v2.md',
                  content: 'v2 ref',
                ),
              ],
            ),
          ],
        ),
      );
      final setup = await _setup(catalogService: fake);
      addTearDown(setup.tearDown);

      final installResult = await setup.notifier.installFromOfficial(
        source: _officialDto('Weather', version: 1, prompt: 'v1 prompt'),
      );
      final id = (installResult as InstallFromCatalogSuccess).novelAgentSkillId;
      final original = setup.readState().firstWhere((s) => s.id == id);
      expect(original.prompt, 'v1 prompt');
      final oldScript = File('${original.skillRoot}/scripts/old.py');
      await oldScript.create(recursive: true);
      await oldScript.writeAsString('old script');
      final oldAsset = File('${original.skillRoot}/assets/old.bin');
      await oldAsset.create(recursive: true);
      await oldAsset.writeAsBytes([1, 2, 3]);

      final result = await setup.notifier.upgradeNovelAgentSkill(
        novelAgentSkillId: id,
      );

      expect(result, isA<UpgradeSuccess>());
      final success = result as UpgradeSuccess;
      expect(success.oldVersion, 1);
      expect(success.newVersion, 2);

      final upgraded = setup.readState().firstWhere((s) => s.id == id);
      expect(upgraded.sourceVersion, '2');
      expect(upgraded.prompt, 'v2 prompt');
      expect(upgraded.references, hasLength(1));
      expect(upgraded.references.single.path, 'references/v2.md');
      expect(upgraded.references.single.content, 'v2 ref');
      expect(upgraded.skillRoot, original.skillRoot);
      expect(await oldScript.exists(), isFalse);
      expect(await oldAsset.exists(), isFalse);
      // 保留字段。
      expect(upgraded.name, 'Weather');
      expect(upgraded.enabled, isTrue);
      expect(upgraded.sortOrder, 0);
    });

    test('official: already latest returns AlreadyLatestVersion', () async {
      final fake = _FakeCatalogService(
        officialList: OfficialAgentSkillCatalog(
          agentSkills: [_officialDto('Weather', version: 2)],
        ),
      );
      final setup = await _setup(catalogService: fake);
      addTearDown(setup.tearDown);

      final installResult = await setup.notifier.installFromOfficial(
        source: _officialDto('Weather', version: 2),
      );
      final id = (installResult as InstallFromCatalogSuccess).novelAgentSkillId;

      final result = await setup.notifier.upgradeNovelAgentSkill(
        novelAgentSkillId: id,
      );

      expect(result, isA<AlreadyLatestVersion>());
      expect((result as AlreadyLatestVersion).currentVersion, 2);
      // 未写入新内容。
      expect(
        setup.readState().firstWhere((s) => s.id == id).sourceVersion,
        '2',
      );
    });

    test(
      'official: matches stale installs by catalog name even if listing id is a leftover uuid',
      () async {
        final fake = _FakeCatalogService(
          officialList: OfficialAgentSkillCatalog(
            agentSkills: [
              _officialDto('Weather', version: 4, listingId: 'Weather'),
            ],
          ),
        );
        final setup = await _setup(catalogService: fake);
        addTearDown(setup.tearDown);

        await setup.notifier.install(
          InstallSkillInput(
            sourceKind: AgentSkillSourceKind.official,
            sourceListingPublicId: '09a34832-9cac-46a2-853c-d0d1679d1b74',
            sourceVersion: '1',
            sourceDisplayName: 'Weather',
            name: 'Weather',
            description: 'old desc',
            prompt: 'old prompt',
          ),
        );
        final id = setup.readState().single.id;

        final result = await setup.notifier.upgradeNovelAgentSkill(
          novelAgentSkillId: id,
        );

        expect(result, isA<UpgradeSuccess>());
        final upgraded = setup.readState().single;
        expect(upgraded.sourceVersion, '4');
        expect(upgraded.sourceListingPublicId, 'Weather');
        expect(upgraded.prompt, 'prompt');
      },
    );

    test(
      'official: not found in catalog returns UpgradeNotTraceable',
      () async {
        final fake = _FakeCatalogService(
          officialList: const OfficialAgentSkillCatalog(agentSkills: []),
        );
        final setup = await _setup(catalogService: fake);
        addTearDown(setup.tearDown);

        final installResult = await setup.notifier.installFromOfficial(
          source: _officialDto('Weather', version: 1),
        );
        final id =
            (installResult as InstallFromCatalogSuccess).novelAgentSkillId;

        final result = await setup.notifier.upgradeNovelAgentSkill(
          novelAgentSkillId: id,
        );

        expect(result, isA<UpgradeNotTraceable>());
      },
    );

    test('novel_local: returns UpgradeNotTraceable', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      final installResult = await setup.notifier.createNovelLocalSkill(
        InstallSkillInput(
          sourceKind: AgentSkillSourceKind.novelLocal,
          name: 'Local',
          description: 'd',
          prompt: 'p',
        ),
      );
      final id = installResult.id;

      final result = await setup.notifier.upgradeNovelAgentSkill(
        novelAgentSkillId: id,
      );

      expect(result, isA<UpgradeNotTraceable>());
    });

    test(
      'marketplace snapshots remain unchanged without a connection',
      () async {
        final setup = await _setup();
        addTearDown(setup.tearDown);
        final installed = await setup.notifier.install(
          const InstallSkillInput(
            sourceKind: AgentSkillSourceKind.marketplace,
            sourceListingPublicId: 'market-listing',
            sourceVersion: '1',
            name: 'Market Skill',
            description: '',
            prompt: 'saved content',
          ),
        );
        expect(
          await setup.notifier.upgradeNovelAgentSkill(
            novelAgentSkillId: installed.id,
          ),
          isA<UpgradeNotTraceable>(),
        );
        expect(
          await setup.notifier.checkUpgradeAvailable(
            novelAgentSkillId: installed.id,
          ),
          isA<UpgradeAvailabilityNotTraceable>(),
        );
        final saved = setup.readState().single;
        expect(saved.prompt, 'saved content');
        expect(saved.sourceVersion, '1');
      },
    );
  });

  group('checkUpgradeAvailable', () {
    test(
      'official: returns available when bundled catalog has higher version',
      () async {
        final fake = _FakeCatalogService(
          officialList: OfficialAgentSkillCatalog(
            agentSkills: [_officialDto('Weather', version: 5)],
          ),
        );
        final setup = await _setup(catalogService: fake);
        addTearDown(setup.tearDown);

        final installResult = await setup.notifier.installFromOfficial(
          source: _officialDto('Weather', version: 1),
        );
        final id =
            (installResult as InstallFromCatalogSuccess).novelAgentSkillId;

        final result = await setup.notifier.checkUpgradeAvailable(
          novelAgentSkillId: id,
        );

        expect(result, isA<UpgradeAvailabilityAvailable>());
        final available = result as UpgradeAvailabilityAvailable;
        expect(available.currentVersion, 1);
        expect(available.latestVersion, 5);
        // 不写入。
        expect(
          setup.readState().firstWhere((s) => s.id == id).sourceVersion,
          '1',
        );
      },
    );

    test('official: returns upToDate when versions match', () async {
      final fake = _FakeCatalogService(
        officialList: OfficialAgentSkillCatalog(
          agentSkills: [_officialDto('Weather', version: 2)],
        ),
      );
      final setup = await _setup(catalogService: fake);
      addTearDown(setup.tearDown);

      final installResult = await setup.notifier.installFromOfficial(
        source: _officialDto('Weather', version: 2),
      );
      final id = (installResult as InstallFromCatalogSuccess).novelAgentSkillId;

      final result = await setup.notifier.checkUpgradeAvailable(
        novelAgentSkillId: id,
      );

      expect(result, isA<UpgradeAvailabilityUpToDate>());
      expect((result as UpgradeAvailabilityUpToDate).currentVersion, 2);
    });

    test('novel_local: returns notTraceable', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      final installResult = await setup.notifier.createNovelLocalSkill(
        InstallSkillInput(
          sourceKind: AgentSkillSourceKind.novelLocal,
          name: 'Local',
          description: 'd',
          prompt: 'p',
        ),
      );

      final result = await setup.notifier.checkUpgradeAvailable(
        novelAgentSkillId: installResult.id,
      );

      expect(result, isA<UpgradeAvailabilityNotTraceable>());
    });
  });

  group('convertToNovelLocal', () {
    test('official: detaches source trace, keeps snapshot', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      final installResult = await setup.notifier.installFromOfficial(
        source: _officialDto('Weather', version: 1),
      );
      final id = (installResult as InstallFromCatalogSuccess).novelAgentSkillId;

      final converted = await setup.notifier.convertToNovelLocal(id);

      expect(converted.sourceKind, AgentSkillSourceKind.novelLocal);
      expect(converted.sourceListingPublicId, isNull);
      expect(converted.sourceVersion, isNull);
      expect(converted.sourceDisplayName, isNull);
      expect(converted.name, 'Weather');
      expect(converted.executionBlockedReason, isNull);
    });

    test('novel_local: is a no-op', () async {
      final setup = await _setup();
      addTearDown(setup.tearDown);

      final local = await setup.notifier.createNovelLocalSkill(
        InstallSkillInput(
          sourceKind: AgentSkillSourceKind.novelLocal,
          name: 'Local',
          description: 'd',
          prompt: 'p',
        ),
      );

      final result = await setup.notifier.convertToNovelLocal(local.id);

      expect(result.id, local.id);
      expect(result.sourceKind, AgentSkillSourceKind.novelLocal);
    });
  });
}

// ── 测试夹具 ─────────────────────────────────────────────────────────────────

class _TestSetup {
  _TestSetup({required this.db, required this.container});

  final AppDatabase db;
  final ProviderContainer container;

  InstalledAgentSkillsNotifier get notifier =>
      container.read(installedAgentSkillsProvider.notifier);

  List<NovelAgentSkillModel> readState() =>
      container.read(installedAgentSkillsProvider).value!;

  Future<void> tearDown() async {
    container.dispose();
    await db.close();
  }
}

Future<_TestSetup> _setup({_FakeCatalogService? catalogService}) async {
  final db = AppDatabase.forTest(NativeDatabase.memory());
  final support = await Directory.systemTemp.createTemp('reveric_install_');
  addTearDown(() => support.delete(recursive: true));
  final store = AgentSkillFileStore(() async => support);
  await store.migrateLegacy(db);
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      agentSkillAppDatabaseProvider.overrideWithValue(db),
      agentSkillFileStoreProvider.overrideWithValue(store),
      if (catalogService != null)
        agentSkillCatalogServiceProvider.overrideWithValue(catalogService),
    ],
  );
  // 预热 installedAgentSkillsProvider,确保 state 进入 data。
  await container.read(installedAgentSkillsProvider.future);

  return _TestSetup(db: db, container: container);
}

OfficialAgentSkill _officialDto(
  String name, {
  int version = 1,
  String prompt = 'prompt',
  String listingId = 'official-listing',
  List<AgentSkillReferenceFile> references = const [],
}) {
  return OfficialAgentSkill(
    listingId: listingId,
    name: name,
    whenToUse: 'when $name',
    description: 'desc $name',
    prompt: prompt,
    category: 'utils',
    tags: const [/* tag */],
    version: version,
    sortOrder: 0,
    updatedAt: '2026-01-01T00:00:00Z',
    references: references,
  );
}

/// 仅实现 install flow 测试需要的 catalog 方法;其余方法抛 UnimplementedError。
class _FakeCatalogService extends AgentSkillCatalogService {
  _FakeCatalogService({OfficialAgentSkillCatalog? officialList})
    : _officialList =
          officialList ?? const OfficialAgentSkillCatalog(agentSkills: []);

  final OfficialAgentSkillCatalog _officialList;

  @override
  Future<OfficialAgentSkillCatalog> listOfficial() async => _officialList;

  @override
  Future<OfficialAgentSkill> getOfficial({required String listingId}) async {
    for (final entry in _officialList.agentSkills) {
      if (entry is OfficialAgentSkill &&
          (entry.listingId == listingId || entry.name == listingId)) {
        return entry;
      }
    }
    throw StateError('official detail not found: $listingId');
  }
}
