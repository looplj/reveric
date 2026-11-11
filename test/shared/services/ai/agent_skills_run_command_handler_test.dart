// 职责: 锁定 AgentSkills Run handler 操作应用全局已安装技能，官方目录搜索仅返回摘要字段。
// 关联文件:
//   lib/shared/services/ai/agent_skills_run_command_handler.dart
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/providers/agent_skill_catalog_providers.dart
//   assets/bundled_skills/setup/SKILL.md
//   assets/bundled_skills/setup/references/
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'package:reveric/shared/app_config.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/services.dart' show AssetBundle;
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/providers/agent_skill_providers.dart'
    show agentSkillAppDatabaseProvider;
import 'package:reveric/shared/models/agent_skill_revision.dart';
import 'package:reveric/shared/models/novel_agent_skill.dart';
import 'package:reveric/shared/providers/agent_skill_catalog_providers.dart';
import 'package:reveric/shared/providers/novel_agent_skill_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart'
    show appDatabaseProvider;
import 'package:reveric/shared/services/agent_skill_catalog_service.dart';
import 'package:reveric/shared/services/ai/agent_skills_run_command_handler.dart';

class _FileAssetBundle extends AssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final bytes = await File(key).readAsBytes();
    return ByteData.sublistView(bytes);
  }
}

/// officialAgentSkillsProvider 读本地打包目录，测试仍 override catalog service；
/// 测试内统一覆盖为内存库,避免命中真实 path_provider/sqlite。
ProviderContainer _buildContainer({required List<Override> overrides}) {
  final database = AppDatabase.forTest(NativeDatabase.memory());
  addTearDown(database.close);
  return ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      agentSkillAppDatabaseProvider.overrideWithValue(database),
      ...overrides,
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('search returns compact official catalog entries', () async {
    final fake = _FakeAgentSkillCatalogService(
      officialList: const OfficialAgentSkillCatalog(
        agentSkills: [
          OfficialAgentSkillSummary(
            listingId: 'official-1',
            name: '章节规划',
            description: '规划章节目标、冲突与结尾钩子。',
            category: '',
            tags: [],
            version: 1,
            updatedAt: '2026-01-01T00:00:00Z',
          ),
        ],
      ),
    );
    final container = _buildContainer(
      overrides: [agentSkillCatalogServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    final handler = AgentSkillsRunCommandHandler(container: container);

    final result = await handler.run({
      'action': 'search',
      'query': '章节',
      'source': 'official',
    });
    final entries = result['entries']! as List<dynamic>;
    final found = entries.single as Map<String, dynamic>;

    expect(found['name'], '章节规划');
    expect(found['description'], '规划章节目标、冲突与结尾钩子。');
    expect(found, isNot(contains('when_to_use')));
    expect(found, isNot(contains('prompt')));
    final combined = await handler.run({'action': 'search'});
    expect(combined['ok'], isTrue);
    expect(combined['entries'], hasLength(1));
    expect(combined['unavailable_sources'], ['marketplace']);
    final market = await handler.run({
      'action': 'search',
      'source': 'marketplace',
    });
    expect(market['ok'], isFalse);
    expect(market['error_code'], 'unavailable');
  });

  // 目录量小：search 暂返回来源全量，不做 query 文本过滤（见 handler._search）。
  test('search returns full source catalog ignoring query text', () async {
    final fake = _FakeAgentSkillCatalogService(
      officialList: const OfficialAgentSkillCatalog(
        agentSkills: [
          OfficialAgentSkillSummary(
            listingId: 'outline',
            name: '章节规划',
            description: '章节规划阶段的规则。',
            category: '',
            tags: [],
            version: 1,
            updatedAt: '2026-01-01T00:00:00Z',
          ),
          OfficialAgentSkillSummary(
            listingId: 'writing',
            name: '章节写作',
            description: '章节正文写作阶段的规则。',
            category: '',
            tags: [],
            version: 1,
            updatedAt: '2026-01-01T00:00:00Z',
          ),
          OfficialAgentSkillSummary(
            listingId: 'world',
            name: '世界观设定',
            description: '网文世界观与设定工程。',
            category: '',
            tags: [],
            version: 1,
            updatedAt: '2026-01-01T00:00:00Z',
          ),
        ],
      ),
    );
    final container = _buildContainer(
      overrides: [agentSkillCatalogServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    final handler = AgentSkillsRunCommandHandler(container: container);

    final result = await handler.run({
      'action': 'search',
      'query': '完全不存在的关键词',
      'source': 'official',
    });
    final found = result['entries']! as List<dynamic>;
    expect(found.map((e) => (e as Map)['name']), ['章节规划', '章节写作', '世界观设定']);
    expect(result['total'], 3);
  });

  test('search rejects the removed library source', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final handler = AgentSkillsRunCommandHandler(container: container);

    final result = await handler.run({'action': 'search', 'source': 'library'});

    expect(result['ok'], isFalse);
    expect(result['error_code'], 'invalid_argument');
  });

  test(
    'list returns compact installed entries (app-global, no novel scoping)',
    () async {
      final skill = NovelAgentSkillModel(
        id: 'installed_skill',
        sourceKind: AgentSkillSourceKind.official,
        name: '章节规划',
        whenToUse: '用户要求规划章节时',
        description: '规划章节目标、冲突与结尾钩子。',
        prompt: '# 完整技能指令\n\n仅在实际调用时加载。',
      );
      final container = ProviderContainer(
        overrides: [
          installedAgentSkillsProvider.overrideWith(
            () => _FakeInstalledAgentSkillsNotifier([skill]),
          ),
        ],
      );
      addTearDown(container.dispose);
      final handler = AgentSkillsRunCommandHandler(container: container);

      final result = await handler.run({'action': 'list'});
      final entries = result['entries']! as List<dynamic>;
      final found = entries.single as Map<String, dynamic>;

      expect(found['call_name'], '章节规划');
      expect(found['description'], '规划章节目标、冲突与结尾钩子。');
      expect(found, isNot(contains('when_to_use')));
      expect(found, isNot(contains('prompt')));
    },
  );

  test('同一 turn 内的多次写入聚合成一条历史版本', () async {
    final container = _buildContainer(overrides: const []);
    addTearDown(container.dispose);
    final handler = AgentSkillsRunCommandHandler(container: container);
    final database = container.read(agentSkillAppDatabaseProvider);

    final created = await handler.run({
      'action': 'create',
      'name': '章节审稿',
      'prompt': '审查章节',
    });
    final skillId = (created['skill']! as Map<String, dynamic>)['id'] as String;

    for (final path in ['a', 'b', 'c']) {
      final result = await handler.run({
        'action': 'reference-create',
        '_turn_id': 'turn_1',
        'name': '章节审稿',
        'path': 'references/$path.md',
        'content': 'body $path',
      });
      expect(result['ok'], isTrue);
    }

    final revisions = await database.novelAgentSkillRevisionDao.listRevisions(
      skillId,
    );
    // install 基线 + 本轮聚合出的一条。
    expect(revisions, hasLength(2));
    expect(revisions.first.changeSource, SkillRevisionSource.ai_edit);
    expect(revisions.first.fileCount, 3);
  });

  test('AI 改写官方技能会先脱离来源转为本地', () async {
    final container = _buildContainer(overrides: const []);
    addTearDown(container.dispose);
    final handler = AgentSkillsRunCommandHandler(container: container);
    final notifier = container.read(installedAgentSkillsProvider.notifier);

    final installed = await notifier.install(
      const InstallSkillInput(
        sourceKind: AgentSkillSourceKind.official,
        sourceListingPublicId: 'official-listing-1',
        sourceVersion: '3',
        sourceDisplayName: '官方技能',
        name: '官方技能',
        description: 'desc',
        prompt: '官方指令',
      ),
    );

    final updated = await handler.run({
      'action': 'update',
      'id': installed.id,
      'prompt': '被 AI 改写的指令',
    });

    expect(updated['ok'], isTrue);
    expect(updated['converted_to_local'], isTrue);
    expect(updated['notice'], contains('official'));

    final after = container
        .read(installedAgentSkillsProvider)
        .value!
        .firstWhere((item) => item.id == installed.id);
    expect(after.sourceKind, AgentSkillSourceKind.novelLocal);
    expect(after.sourceListingPublicId, isNull);
    expect(after.sourceVersion, isNull);
    expect(after.prompt, '被 AI 改写的指令');
  });

  test('AI 改写本地技能不产生脱离来源说明', () async {
    final container = _buildContainer(overrides: const []);
    addTearDown(container.dispose);
    final handler = AgentSkillsRunCommandHandler(container: container);

    final created = await handler.run({
      'action': 'create',
      'name': '本地技能',
      'prompt': '本地指令',
    });
    final skillId = (created['skill']! as Map<String, dynamic>)['id'] as String;

    final updated = await handler.run({
      'action': 'update',
      'id': skillId,
      'prompt': '改过的指令',
    });

    expect(updated['ok'], isTrue);
    expect(updated.containsKey('converted_to_local'), isFalse);
  });

  test('AI 改写官方技能的附件同样会脱离来源', () async {
    final container = _buildContainer(overrides: const []);
    addTearDown(container.dispose);
    final handler = AgentSkillsRunCommandHandler(container: container);
    final notifier = container.read(installedAgentSkillsProvider.notifier);

    final installed = await notifier.install(
      const InstallSkillInput(
        sourceKind: AgentSkillSourceKind.marketplace,
        sourceListingPublicId: 'market-listing-1',
        sourceVersion: '2',
        sourceDisplayName: '市场技能',
        name: '市场技能',
        description: 'desc',
        prompt: '市场指令',
      ),
    );

    final result = await handler.run({
      'action': 'reference-create',
      'name': '市场技能',
      'path': 'references/note.md',
      'content': '# 笔记',
    });

    expect(result['ok'], isTrue);
    expect(result['converted_to_local'], isTrue);

    final after = container
        .read(installedAgentSkillsProvider)
        .value!
        .firstWhere((item) => item.id == installed.id);
    expect(after.sourceKind, AgentSkillSourceKind.novelLocal);
    expect(after.references.single.path, 'references/note.md');
  });

  test('Reference CRUD persists nested files by Skill name', () async {
    final container = _buildContainer(overrides: const []);
    addTearDown(container.dispose);
    final handler = AgentSkillsRunCommandHandler(container: container);

    final created = await handler.run({
      'action': 'create',
      'name': '章节审稿',
      'prompt': '审查章节',
      'references': [
        {'path': 'references/review/rubric.md', 'content': '# 初版量表'},
      ],
    });
    expect(created['ok'], isTrue);

    final listed = await handler.run({
      'action': 'reference-list',
      'name': '章节审稿',
    });
    expect(listed['references'], [
      {'path': 'references/review/rubric.md'},
    ]);
    expect(listed['count'], 1);

    final disabled = await handler.run({
      'action': 'update',
      'id': (created['skill']! as Map<String, dynamic>)['id'],
      'enabled': 'false',
    });
    expect(disabled['ok'], isTrue);

    // Run agent-skills 是管理面：禁用快照仍可读取和维护 references。
    final disabledRead = await handler.run({
      'action': 'reference-get',
      'name': '章节审稿',
      'path': 'references/review/rubric.md',
    });
    expect(disabledRead['reference'], {
      'path': 'references/review/rubric.md',
      'content': '# 初版量表',
    });

    final updated = await handler.run({
      'action': 'reference-update',
      'name': '章节审稿',
      'path': 'references/review/rubric.md',
      'content': '# 更新量表',
    });
    expect(updated['ok'], isTrue);

    final moved = await handler.run({
      'action': 'reference-move',
      'name': '章节审稿',
      'path': 'references/review/rubric.md',
      'new_path': 'references/rubric.md',
    });
    expect(moved['references'], [
      {'path': 'references/rubric.md'},
    ]);

    final fetched = await handler.run({
      'action': 'reference-get',
      'name': '章节审稿',
      'path': 'references/rubric.md',
    });
    expect(fetched['reference'], {
      'path': 'references/rubric.md',
      'content': '# 更新量表',
    });

    final deleted = await handler.run({
      'action': 'reference-delete',
      'name': '章节审稿',
      'path': 'references/rubric.md',
    });
    expect(deleted['references'], isEmpty);

    final invalid = await handler.run({
      'action': 'reference-create',
      'name': '章节审稿',
      'path': 'references/../unsafe.md',
      'content': 'unsafe',
    });
    expect(invalid['ok'], isFalse);
    expect(invalid['error_code'], 'invalid_argument');
  });

  test(
    'canvas cannot bypass bundled filtering through reference commands',
    () async {
      final container = _buildContainer(overrides: const []);
      addTearDown(container.dispose);
      final handler = AgentSkillsRunCommandHandler(
        container: container,
        assetBundle: _FileAssetBundle(),
        contentKind: 'canvas',
      );
      for (final name in ['创作向导', '剧本工具使用规范', '故事连续性维护']) {
        final listed = await handler.run({
          'action': 'reference-list',
          'name': name,
        });
        expect(listed['ok'], false, reason: '$listed');
        final fetched = await handler.run({
          'action': 'reference-get',
          'name': name,
          'path': 'references/clips.md',
        });
        expect(fetched['ok'], false, reason: '$fetched');
      }
      expect(
        (await handler.run({'action': 'reference-list', 'name': '系统管理'}))['ok'],
        true,
      );
    },
  );

  test('continuity references load independently for each task', () async {
    final container = _buildContainer(overrides: const []);
    addTearDown(container.dispose);
    final handler = AgentSkillsRunCommandHandler(
      container: container,
      assetBundle: _FileAssetBundle(),
    );
    final listed = await handler.run({
      'action': 'reference-list',
      'name': '故事连续性维护',
    });
    expect(listed['ok'], isTrue);
    expect(listed['references'], [
      {'path': 'references/novel.md'},
      {'path': 'references/relations.md'},
      {'path': 'references/screenplay.md'},
    ]);
    for (final kind in ['novel', 'screenplay', 'relations']) {
      final fetched = await handler.run({
        'action': 'reference-get',
        'name': '故事连续性维护',
        'path': 'references/$kind.md',
      });
      expect(fetched['ok'], isTrue);
      final content =
          (fetched['reference']! as Map<String, dynamic>)['content'] as String;
      if (kind == 'novel') {
        for (final field in ['brief', 'events', 'tension', 'emotion']) {
          expect(content, contains('{chapter_path}/$field'));
        }
      } else if (kind == 'relations') {
        expect(content, contains('### character → character'));
        expect(content, contains('chapter_id'));
        expect(content, contains('scene_id'));
        expect(content, contains('proof'));
      } else {
        expect(content, contains('scene_id'));
        expect(content, contains('区分观众已知与角色已知'));
        expect(content, isNot(contains('{chapter_path}/brief')));
      }
    }
  });

  test('canvas reference access follows the feature switch', () async {
    final container = _buildContainer(overrides: const []);
    addTearDown(container.dispose);
    final handler = AgentSkillsRunCommandHandler(
      container: container,
      assetBundle: _FileAssetBundle(),
    );
    for (final action in ['reference-list', 'reference-get']) {
      final result = await handler.run({
        'action': action,
        'name': '画布构图指南',
        if (action == 'reference-get') 'path': 'references/idea-board.md',
      });
      expect(result['ok'], ideationCanvasEnabled, reason: '$result');
      if (!ideationCanvasEnabled) {
        expect(result, isNot(contains('references')));
        expect(result, isNot(contains('reference')));
      }
    }
  });

  test(
    'bundled skill references are readable but cannot be modified',
    () async {
      final container = _buildContainer(overrides: const []);
      addTearDown(container.dispose);
      final handler = AgentSkillsRunCommandHandler(
        container: container,
        assetBundle: _FileAssetBundle(),
      );

      final listed = await handler.run({
        'action': 'reference-list',
        'name': '创作向导',
      });
      expect(listed['ok'], isTrue);
      expect(listed['references'], [
        {'path': 'references/fanfic.md'},
        {'path': 'references/imitation.md'},
        {'path': 'references/original.md'},
        {'path': 'references/sequel.md'},
      ]);

      final fetched = await handler.run({
        'action': 'reference-get',
        'name': '创作向导',
        'path': 'references/fanfic.md',
      });
      expect(fetched['ok'], isTrue);
      expect(
        (fetched['reference']! as Map<String, dynamic>)['content'],
        contains('故事线平行'),
      );

      final write = await handler.run({
        'action': 'reference-create',
        'name': '创作向导',
        'path': 'references/extra.md',
        'content': '# 不允许写入',
      });
      expect(write['ok'], isFalse);
      expect(write['error_code'], 'permission_denied');
    },
  );

  test(
    'management guides are fetched individually and remain read-only',
    () async {
      final container = _buildContainer(overrides: const []);
      addTearDown(container.dispose);
      final handler = AgentSkillsRunCommandHandler(
        container: container,
        assetBundle: _FileAssetBundle(),
      );
      final listed = await handler.run({
        'action': 'reference-list',
        'name': '系统管理',
      });
      expect(listed['ok'], isTrue);
      expect(listed['references'], [
        {'path': 'references/agent-rules.md'},
        {'path': 'references/agent-skills.md'},
        {'path': 'references/providers.md'},
        {'path': 'references/settings.md'},
        {'path': 'references/skill-design.md'},
        {'path': 'references/subagents.md'},
        {'path': 'references/themes.md'},
      ]);
      for (final reference in listed['references'] as List) {
        final path = (reference as Map)['path'] as String;
        final fetched = await handler.run({
          'action': 'reference-get',
          'name': '系统管理',
          'path': path,
        });
        expect(fetched['ok'], isTrue);
        expect(fetched['reference'], {
          'path': path,
          'content': File(
            'assets/bundled_skills/management/$path',
          ).readAsStringSync(),
        });
      }
      for (final action in [
        'reference-create',
        'reference-update',
        'reference-move',
        'reference-delete',
      ]) {
        final write = await handler.run({
          'action': action,
          'name': '系统管理',
          'path': 'references/agent-rules.md',
          'new_path': 'references/renamed.md',
          'content': '# changed',
        });
        expect(write['error_code'], 'permission_denied', reason: action);
      }
      final missing = await handler.run({
        'action': 'reference-get',
        'name': '系统管理',
        'path': 'references/missing.md',
      });
      expect(missing['error_code'], 'not_found');
    },
  );
}

/// 测试用 [InstalledAgentSkillsNotifier] fake —— 固定返回给定列表,跳过 DB 链路。
class _FakeInstalledAgentSkillsNotifier extends InstalledAgentSkillsNotifier {
  _FakeInstalledAgentSkillsNotifier(this._skills);

  final List<NovelAgentSkillModel> _skills;

  @override
  Future<List<NovelAgentSkillModel>> build() async => _skills;
}

/// 实现 [AgentSkillCatalogService] 接口的 fake，仅实现本测试用到的 listOfficial。
class _FakeAgentSkillCatalogService extends AgentSkillCatalogService {
  _FakeAgentSkillCatalogService({required this._officialList});

  final OfficialAgentSkillCatalog _officialList;

  @override
  Future<OfficialAgentSkillCatalog> listOfficial() async => _officialList;

  @override
  Future<OfficialAgentSkill> getOfficial({required String listingId}) =>
      throw UnimplementedError('getOfficial is not used in this test.');
}
