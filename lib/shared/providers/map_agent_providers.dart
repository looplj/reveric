// 职责: 地图 Agent 瞬态状态 — 在聊天工具、地图工作台与编辑器外壳之间传递草稿和 handoff 请求。
// 关联文件:
//   lib/shared/models/map_agent.dart
//   lib/shared/services/ai/chat_turn_runner.dart
//   lib/desktop/features/map/map_cartographer_panel.dart
//   lib/desktop/pages/novel_editor.dart
//   lib/shared/providers/workspace_navigation_provider.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/map_agent.dart';
import '../models/novel_workspace.dart';
import 'workspace_navigation_provider.dart';

part 'map_agent_providers.g.dart';

const _maxRetainedMapDesignDrafts = 32;

/// 草稿需要在制图师关闭时仍可由 Agent 投递，因此保留轻量值；数量有硬上限，
/// 应用或忽略后立即移除，不持有 controller、stream 或数据库连接。
@Riverpod(keepAlive: true)
class MapDesignDrafts extends _$MapDesignDrafts {
  @override
  Map<MapDesignDraftKey, MapDesignDraft> build() => const {};

  void submit({required String databasePath, required MapDesignDraft draft}) {
    if (databasePath.trim().isEmpty ||
        draft.worldId.trim().isEmpty ||
        draft.prompt.trim().isEmpty ||
        !mapDesignStyleIds.contains(draft.styleId) ||
        (draft.styleId == mapCustomStyleId &&
            (draft.customStyleWord == null ||
                draft.customStyleWord!.trim().isEmpty)) ||
        draft.resolutionId.trim().isEmpty ||
        draft.qualityId.trim().isEmpty) {
      throw ArgumentError('Invalid map design draft');
    }
    final key = MapDesignDraftKey(
      databasePath: databasePath,
      worldId: draft.worldId,
    );
    final next = Map<MapDesignDraftKey, MapDesignDraft>.of(state)..remove(key);
    next[key] = draft;
    while (next.length > _maxRetainedMapDesignDrafts) {
      next.remove(next.keys.first);
    }
    state = next;
    ref
        .read(workspaceNavigationProvider.notifier)
        .request(
          WorkspaceNavigationRequest(
            section: NovelWorkspaceSection.maps,
            itemId: draft.worldId,
          ),
        );
  }

  void discard({required String databasePath, required String worldId}) {
    final key = MapDesignDraftKey(databasePath: databasePath, worldId: worldId);
    if (!state.containsKey(key)) {
      return;
    }
    state = Map<MapDesignDraftKey, MapDesignDraft>.of(state)..remove(key);
  }
}

@riverpod
MapDesignDraft? mapDesignDraft(
  Ref ref, {
  required String databasePath,
  required String worldId,
}) {
  final drafts = ref.watch(mapDesignDraftsProvider);
  return drafts[MapDesignDraftKey(
    databasePath: databasePath,
    worldId: worldId,
  )];
}

/// 一次只保留最新请求；NovelEditor 的常驻 listener 负责把它转成交接草稿。
/// 请求很小且必须跨制图师关闭动作保留，因此使用单实例 keepAlive。
@Riverpod(keepAlive: true)
class MapAgentHandoff extends _$MapAgentHandoff {
  @override
  MapAgentHandoffRequest? build() => null;

  void request(MapAgentHandoffRequest request) {
    state = request;
  }
}
