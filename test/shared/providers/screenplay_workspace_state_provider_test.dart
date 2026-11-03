// 职责: 验证剧本工作区按作品恢复、逐级修复并串行持久化选择。
// 关联文件:
//   lib/shared/providers/screenplay_workspace_state_provider.dart
//   lib/shared/models/screenplay_workspace_state.dart
//   lib/shared/services/screenplay_service.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/testing.md

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:reveric/shared/models/screenplay.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/screenplay_workspace_state.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/screenplay_workspace_state_provider.dart';
import 'package:reveric/shared/services/screenplay_service.dart';

void main() {
  test('unknown section falls back to overview', () {
    final state = ScreenplayWorkspaceState.fromJson({
      'section': 'beats',
      'episodeId': 'ep1',
    });
    expect(state.section, ScreenplayWorkspaceSection.overview);
    expect(state.episodeId, 'ep1');
  });
  test(
    'scene navigation resolves current hierarchy after a cross-season move and rejects deletion',
    () async {
      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final service = ScreenplayService(db);
      final initial = await service.createInitialStructure();
      final rootId = (await db.screenplayDao.getRoot())!.id;
      final sceneId = await service.createScene(
        screenplayId: rootId,
        episodeId: initial.episodeId,
      );
      final target = await service.createSeason(screenplayId: rootId);
      await service.moveSceneToEpisodeEnd(sceneId, target.episodeId);
      const path = 'memory:scene-navigation';
      const workId = 'scene-navigation';
      await appDb.appStateDao.set(
        key: screenplayWorkspaceAppStateKey(workId),
        value: jsonEncode({
          'version': 1,
          'section': 'outline',
          'seasonId': initial.seasonId,
          'episodeId': initial.episodeId,
          'sceneId': sceneId,
        }),
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(appDb),
          novelContentDatabaseProvider(path).overrideWithValue(db),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
        await appDb.close();
      });
      final provider = screenplayWorkspaceStateControllerProvider(workId, path);
      // 只 read 发起，验证 command 自己持有异步生命周期。
      final notifier = container.read(provider.notifier);
      await notifier.openSceneScript(sceneId);
      final state = container.read(provider);
      expect(state.section, ScreenplayWorkspaceSection.script);
      expect(state.seasonId, target.seasonId);
      expect(state.episodeId, target.episodeId);
      expect(state.sceneId, sceneId);
      await notifier.flush();
      final stored =
          jsonDecode(
                (await appDb.appStateDao.get(
                  screenplayWorkspaceAppStateKey(workId),
                ))!,
              )
              as Map;
      expect(stored['sceneId'], sceneId);
      expect(stored['episodeId'], target.episodeId);
      final sub = container.listen(provider, (_, _) {});
      await container.read(provider.notifier).ready;
      await service.deleteSeason(target.seasonId);
      final before = container.read(provider);
      await expectLater(
        container.read(provider.notifier).openSceneScript(sceneId),
        throwsA(
          isA<ScreenplayServiceException>().having(
            (e) => e.errorCode,
            'code',
            'scene_not_found',
          ),
        ),
      );
      expect(container.read(provider), same(before));
      sub.close();
    },
  );

  test(
    'outline navigation restores first, selects the target season and clears stale scene ids',
    () async {
      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      final contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
      final service = ScreenplayService(contentDb);
      final initial = await service.createInitialStructure();
      final root = (await contentDb.screenplayDao.getRoot())!;
      final sceneId = await service.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
      );
      final target = await service.createSeason(screenplayId: root.id);
      const workId = 'outline_navigation';
      const databasePath = 'memory:outline-navigation';
      await appDb.appStateDao.set(
        key: screenplayWorkspaceAppStateKey(workId),
        value: jsonEncode({
          'version': 1,
          'section': 'script',
          'seasonId': initial.seasonId,
          'episodeId': initial.episodeId,
          'sceneId': sceneId,
        }),
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(appDb),
          novelContentDatabaseProvider(
            databasePath,
          ).overrideWithValue(contentDb),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await contentDb.close();
        await appDb.close();
      });
      final provider = screenplayWorkspaceStateControllerProvider(
        workId,
        databasePath,
      );
      // 和导航入口一样只 read，不用监听者掩盖异步 command 的生命周期问题。
      final notifier = container.read(provider.notifier);
      await notifier.openEpisodeOutline(target.episodeId);
      final selected = container.read(provider);
      expect(selected.section, ScreenplayWorkspaceSection.outline);
      expect(selected.seasonId, target.seasonId);
      expect(selected.episodeId, target.episodeId);
      expect(selected.sceneId, isNull);
      await notifier.flush();
      final stored =
          jsonDecode(
                (await appDb.appStateDao.get(
                  screenplayWorkspaceAppStateKey(workId),
                ))!,
              )
              as Map<String, dynamic>;
      expect(stored['section'], 'outline');
      expect(stored['seasonId'], target.seasonId);
      expect(stored['episodeId'], target.episodeId);
      expect(stored.containsKey('sceneId'), isFalse);

      final subscription = container.listen(provider, (_, _) {});
      await container.read(provider.notifier).ready;
      final before = container.read(provider);
      await expectLater(
        container.read(provider.notifier).openEpisodeOutline('missing_episode'),
        throwsStateError,
      );
      expect(container.read(provider), same(before));
      subscription.close();
    },
  );

  test('repairs invalid saved ids within the valid parent hierarchy', () async {
    final appDb = AppDatabase.forTest(NativeDatabase.memory());
    final contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    final created = await ScreenplayService(contentDb).createInitialStructure();
    const workId = 'work_1';
    const databasePath = 'memory:screenplay';
    await appDb.appStateDao.set(
      key: screenplayWorkspaceAppStateKey(workId),
      value: jsonEncode(<String, dynamic>{
        'version': 1,
        'section': 'script',
        'seasonId': 'missing_season',
        'episodeId': 'missing_episode',
        'sceneId': 'missing_scene',
      }),
    );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(appDb),
        novelContentDatabaseProvider(databasePath).overrideWithValue(contentDb),
      ],
    );
    final provider = screenplayWorkspaceStateControllerProvider(
      workId,
      databasePath,
    );
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await contentDb.close();
      await appDb.close();
    });

    final notifier = container.read(provider.notifier);
    await notifier.ready;
    await notifier.flush();
    final state = container.read(provider);
    expect(state.section, ScreenplayWorkspaceSection.script);
    expect(state.seasonId, created.seasonId);
    expect(state.episodeId, created.episodeId);
    expect(state.sceneId, isNull);
    final stored =
        jsonDecode(
              (await appDb.appStateDao.get(
                screenplayWorkspaceAppStateKey(workId),
              ))!,
            )
            as Map<String, dynamic>;
    expect(stored['seasonId'], created.seasonId);
    expect(stored['episodeId'], created.episodeId);
  });

  test('selects the next surviving season at the deleted position', () {
    const state = ScreenplayWorkspaceState(
      section: ScreenplayWorkspaceSection.outline,
      seasonId: 'deleted',
      episodeId: 'old_episode',
      sceneId: 'old_scene',
      isHydrated: true,
    );
    final repaired = reconcileScreenplayWorkspaceState(
      state: state,
      seasonIds: const ['season_1', 'season_3'],
      episodeIdsBySeason: const {
        'season_1': ['episode_1'],
        'season_3': ['episode_3'],
      },
      sceneIdsByEpisode: const {
        'episode_1': ['scene_1'],
        'episode_3': ['scene_3'],
      },
      preferredSeasonIndex: 1,
    );
    expect(repaired.seasonId, 'season_3');
    expect(repaired.episodeId, 'episode_3');
    expect(repaired.sceneId, 'scene_3');
  });
}
