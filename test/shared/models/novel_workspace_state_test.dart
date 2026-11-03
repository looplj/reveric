// 职责: 验证小说工作区快照的版本化 JSON 容错与失效资源选择修复。
// 关联文件:
//   lib/shared/models/novel_workspace_state.dart
//   lib/shared/models/novel_workspace.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/novel_workspace.dart';
import 'package:reveric/shared/models/novel_workspace_state.dart';

void main() {
  test('restoring hidden pages selects an available workspace', () {
    final canvas = NovelWorkspaceStateData.fromJson({
      'selection': {'section': 'canvas', 'itemId': 'canvas_1'},
    });
    expect(canvas.selection, const WorkspaceSelection.overview());
    final beats = NovelWorkspaceStateData.fromJson({
      'selection': {'section': 'screenplay_beats', 'itemId': 'beat_1'},
    });
    expect(beats.selection, const WorkspaceSelection.overview());
  });

  group('NovelWorkspaceStateData', () {
    test('round-trips known fields and ignores unknown fields', () {
      final state = NovelWorkspaceStateData.fromJson(<String, dynamic>{
        'version': 99,
        'selection': <String, dynamic>{
          'section': 'outlines',
          'itemId': 'outline_1',
          'isCreating': true,
          'isViewingAllOutlines': true,
          'futureField': 'ignored',
        },
        'expandedNodes': <String, dynamic>{
          'chapters': <Object>['volume_2', 'volume_1', 42, ''],
          'lore': <Object>['folder_1'],
          'futureSection': <Object>['node_1'],
        },
        'futureRoot': true,
      });

      expect(
        state.selection,
        const WorkspaceSelection(
          section: NovelWorkspaceSection.outlines,
          itemId: 'outline_1',
          isViewingAllOutlines: true,
        ),
      );
      expect(state.selection.isCreating, isFalse);
      expect(state.expandedNodeIdsFor(NovelWorkspaceSection.chapters), <String>{
        'volume_1',
        'volume_2',
      });
      expect(state.expandedNodeIdsFor(NovelWorkspaceSection.lore), <String>{
        'folder_1',
      });

      final encoded = state.toJson();
      expect(encoded['version'], NovelWorkspaceStateData.currentVersion);
      expect(
        (encoded['expandedNodes'] as Map<String, dynamic>)['chapters'],
        <String>['volume_1', 'volume_2'],
      );
      expect(encoded['selection'], <String, dynamic>{
        'section': 'outlines',
        'itemId': 'outline_1',
        'isViewingAllOutlines': true,
      });
    });

    test('restores an obsolete search selection to overview', () {
      final state = NovelWorkspaceStateData.fromJson(<String, dynamic>{
        'selection': <String, dynamic>{'section': 'search'},
        'expandedNodes': <String, dynamic>{
          'search': <String>['stale_node'],
          'chapters': <String>['volume_1'],
        },
      });

      expect(state.selection, const WorkspaceSelection.overview());
      expect(state.expandedNodeIdsFor(NovelWorkspaceSection.chapters), {
        'volume_1',
      });
      expect(state.toJson()['expandedNodes'], isNot(contains('search')));
    });

    test('falls back field by field for malformed data', () {
      final state = NovelWorkspaceStateData.fromJson(<String, dynamic>{
        'selection': <String, dynamic>{
          'section': 'removed_section',
          'itemId': 'stale_item',
        },
        'expandedNodes': <String, dynamic>{
          'chapters': 'not-a-list',
          'materials': <Object?>[null, 1, 'folder_1'],
        },
      });

      expect(state.selection, const WorkspaceSelection.overview());
      expect(state.expandedNodeIdsFor(NovelWorkspaceSection.chapters), isEmpty);
      expect(
        state.expandedNodeIdsFor(NovelWorkspaceSection.materials),
        <String>{'folder_1'},
      );
    });
  });

  group('reconcileWorkspaceSelection', () {
    test(
      'uses the first current chapter when the restored chapter is gone',
      () {
        final repaired = reconcileWorkspaceSelection(
          selection: const WorkspaceSelection(
            section: NovelWorkspaceSection.chapters,
            itemId: 'deleted_chapter',
          ),
          availableItemIds: const <String>['chapter_2', 'chapter_3'],
          selectFirstWhenMissing: true,
        );

        expect(
          repaired,
          const WorkspaceSelection(
            section: NovelWorkspaceSection.chapters,
            itemId: 'chapter_2',
          ),
        );
      },
    );

    test('uses the first map when entering maps without a selection', () {
      final repaired = reconcileWorkspaceSelection(
        selection: const WorkspaceSelection(
          section: NovelWorkspaceSection.maps,
        ),
        availableItemIds: const <String>['map_1', 'map_2'],
        selectFirstWhenMissing: true,
      );

      expect(
        repaired,
        const WorkspaceSelection(
          section: NovelWorkspaceSection.maps,
          itemId: 'map_1',
        ),
      );
    });

    test('keeps the section and clears a deleted non-chapter item', () {
      final repaired = reconcileWorkspaceSelection(
        selection: const WorkspaceSelection(
          section: NovelWorkspaceSection.characters,
          itemId: 'deleted_character',
        ),
        availableItemIds: const <String>['character_2'],
      );

      expect(
        repaired,
        const WorkspaceSelection(section: NovelWorkspaceSection.characters),
      );
    });

    test('does not rewrite transient creation state', () {
      const selection = WorkspaceSelection.creating(
        section: NovelWorkspaceSection.materials,
      );

      expect(
        reconcileWorkspaceSelection(
          selection: selection,
          availableItemIds: const <String>[],
        ),
        same(selection),
      );
    });
  });

  group('reconcileScreenplayWorkspaceSelection', () {
    test('切集时大纲改用新集，其他剧本资源清除旧 item', () {
      for (final section in [
        NovelWorkspaceSection.screenplay_script,
        NovelWorkspaceSection.storyboard,
        NovelWorkspaceSection.screenplay_scenes,
      ]) {
        expect(
          reconcileScreenplayWorkspaceSelection(
            selection: WorkspaceSelection(
              section: section,
              itemId: 'old_resource',
            ),
            previousEpisodeId: 'episode_1',
            episodeId: 'episode_2',
            sceneId: null,
          ),
          WorkspaceSelection(section: section),
        );
      }

      expect(
        reconcileScreenplayWorkspaceSelection(
          selection: const WorkspaceSelection(
            section: NovelWorkspaceSection.screenplay_outline,
            itemId: 'episode_1',
          ),
          previousEpisodeId: 'episode_1',
          episodeId: 'episode_2',
          sceneId: null,
        ),
        const WorkspaceSelection(
          section: NovelWorkspaceSection.screenplay_outline,
          itemId: 'episode_2',
        ),
      );
    });

    test('同集切换场次时剧本和场次 section 跟随当前 scene', () {
      for (final section in [
        NovelWorkspaceSection.screenplay_script,
        NovelWorkspaceSection.screenplay_scenes,
      ]) {
        expect(
          reconcileScreenplayWorkspaceSelection(
            selection: WorkspaceSelection(section: section, itemId: 'scene_1'),
            previousEpisodeId: 'episode_1',
            episodeId: 'episode_1',
            sceneId: 'scene_2',
          ),
          WorkspaceSelection(section: section, itemId: 'scene_2'),
        );
      }
    });

    test('非剧本 section 不受剧本工作区变化影响', () {
      const selection = WorkspaceSelection(
        section: NovelWorkspaceSection.chapters,
        itemId: 'chapter_1',
      );

      expect(
        reconcileScreenplayWorkspaceSelection(
          selection: selection,
          previousEpisodeId: 'episode_1',
          episodeId: 'episode_2',
          sceneId: null,
        ),
        same(selection),
      );
    });
  });
}
