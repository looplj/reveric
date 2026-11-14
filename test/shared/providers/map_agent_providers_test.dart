// 职责: 验证地图 Agent 草稿在制图师关闭期间可保留，并按世界独立应用或忽略。
// 关联文件:
//   lib/shared/providers/map_agent_providers.dart
//   lib/shared/models/map_agent.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/map_agent.dart';
import 'package:reveric/shared/models/novel_workspace.dart';
import 'package:reveric/shared/providers/map_agent_providers.dart';
import 'package:reveric/shared/providers/workspace_navigation_provider.dart';

void main() {
  test('retains drafts per world until explicitly discarded', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const first = MapDesignDraft(worldId: 'world_1', prompt: 'First map');
    const second = MapDesignDraft(worldId: 'world_2', prompt: 'Second map');

    container
        .read(mapDesignDraftsProvider.notifier)
        .submit(databasePath: '/novel.sqlite', draft: first);
    container
        .read(mapDesignDraftsProvider.notifier)
        .submit(databasePath: '/novel.sqlite', draft: second);

    expect(
      container.read(
        mapDesignDraftProvider(
          databasePath: '/novel.sqlite',
          worldId: 'world_1',
        ),
      ),
      same(first),
    );
    expect(
      container.read(
        mapDesignDraftProvider(
          databasePath: '/novel.sqlite',
          worldId: 'world_2',
        ),
      ),
      same(second),
    );

    container
        .read(mapDesignDraftsProvider.notifier)
        .discard(databasePath: '/novel.sqlite', worldId: 'world_1');

    expect(
      container.read(
        mapDesignDraftProvider(
          databasePath: '/novel.sqlite',
          worldId: 'world_1',
        ),
      ),
      isNull,
    );
    expect(
      container.read(
        mapDesignDraftProvider(
          databasePath: '/novel.sqlite',
          worldId: 'world_2',
        ),
      ),
      same(second),
    );
  });

  test('rejects an empty image parameter in a draft', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      () => container
          .read(mapDesignDraftsProvider.notifier)
          .submit(
            databasePath: '/novel.sqlite',
            draft: const MapDesignDraft(
              worldId: 'world_1',
              prompt: 'Map',
              resolutionId: '',
            ),
          ),
      throwsArgumentError,
    );
  });

  test(
    'preserves arbitrary declared image parameters until generation validation',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const draft = MapDesignDraft(
        worldId: 'world',
        prompt: 'Map',
        resolutionId: 'workflow-large',
        qualityId: 'studio',
      );
      container
          .read(mapDesignDraftsProvider.notifier)
          .submit(databasePath: '/novel.sqlite', draft: draft);
      final saved = container.read(
        mapDesignDraftProvider(databasePath: '/novel.sqlite', worldId: 'world'),
      )!;
      expect(saved.resolutionId, 'workflow-large');
      expect(saved.qualityId, 'studio');
    },
  );
  test('custom draft style requires a non-empty description', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      () => container
          .read(mapDesignDraftsProvider.notifier)
          .submit(
            databasePath: '/novel.sqlite',
            draft: const MapDesignDraft(
              worldId: 'world_1',
              prompt: 'Map',
              styleId: mapCustomStyleId,
            ),
          ),
      throwsArgumentError,
    );
    expect(
      () => container
          .read(mapDesignDraftsProvider.notifier)
          .submit(
            databasePath: '/novel.sqlite',
            draft: const MapDesignDraft(
              worldId: 'world_1',
              prompt: 'Map',
              styleId: mapCustomStyleId,
              customStyleWord: '低多边形复古航海图',
            ),
          ),
      returnsNormally,
    );
  });

  test('submitting a draft requests its world in the map workspace', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(mapDesignDraftsProvider.notifier)
        .submit(
          databasePath: '/novel.sqlite',
          draft: const MapDesignDraft(
            worldId: 'world_1',
            prompt: 'Agent-authored map prompt',
          ),
        );

    final request = container.read(workspaceNavigationProvider);
    expect(request, isNotNull);
    expect(request!.section, NovelWorkspaceSection.maps);
    expect(request.itemId, 'world_1');
  });
}
