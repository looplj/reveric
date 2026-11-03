// 职责: 小说工作区模型测试 — 验证 AI 资源路径映射与大纲默认/全局视图选择状态。
// 关联文件:
//   lib/shared/models/novel_workspace.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/novel_workspace.dart';

void main() {
  group('NovelWorkspaceSectionX.aiResourcePath', () {
    test('uses path-schema collection names for id path resources', () {
      expect(
        NovelWorkspaceSection.chapters.aiResourcePath(itemId: 'chapter_1'),
        '/chapters/chapter_1',
      );
      expect(
        NovelWorkspaceSection.foreshadowings.aiResourcePath(itemId: 'fs_1'),
        '/foreshadowing/fs_1',
      );
    });

    test('uses title paths for document resources', () {
      expect(
        NovelWorkspaceSection.outlines.aiResourcePath(
          itemId: 'outline_internal_id',
          title: '主线',
        ),
        '/outlines/主线',
      );
      expect(
        NovelWorkspaceSection.lore.aiResourcePath(
          itemId: 'doc_internal_id',
          title: '魔法/火系',
        ),
        '/lore/魔法/火系',
      );
    });

    test('compendium paths stay stable across renames and require IDs', () {
      for (final section in [
        NovelWorkspaceSection.skills,
        NovelWorkspaceSection.items,
        NovelWorkspaceSection.factions,
        NovelWorkspaceSection.creatures,
      ]) {
        final path = '/${section.aiResourceType}/entry_1';
        expect(section.aiResourcePath(itemId: 'entry_1', title: '旧标题'), path);
        expect(section.aiResourcePath(itemId: 'entry_1', title: '新标题'), path);
        expect(section.aiResourcePath(title: '旧标题'), isNull);
      }
    });

    test('uses the canonical profile path for novel metadata', () {
      expect(
        NovelWorkspaceSection.novel_description.aiResourcePath(),
        '/profile',
      );
    });

    test('uses structured screenplay paths for screenplay sections', () {
      expect(
        NovelWorkspaceSection.screenplay_script.aiResourcePath(
          itemId: 'scene_1',
        ),
        '/scenes/scene_1/elements',
      );
      // 大纲区编辑的是集大纲，itemId 是集 ID 而不是场次 ID。
      expect(
        NovelWorkspaceSection.screenplay_outline.aiResourcePath(
          itemId: 'episode_1',
        ),
        '/episodes/episode_1/outline',
      );
      expect(
        NovelWorkspaceSection.screenplay_scenes.aiResourcePath(
          itemId: 'scene_1',
        ),
        '/scenes/scene_1',
      );
    });

    test('does not expose unsupported workspace sections as tool paths', () {
      expect(
        NovelWorkspaceSection.maps.aiResourcePath(itemId: 'map_1'),
        isNull,
      );
      expect(
        NovelWorkspaceSection.entity_graph.aiResourcePath(itemId: 'graph'),
        isNull,
      );
    });
  });

  group('novelWorkspaceSectionFromAiResourceType', () {
    // 「最近改动」点击跳转依赖此函数是 aiResourceType 的精确逆映射：
    // 改动记录存的是 resourceType 字符串，必须能还原回原 section 才能跳到正确内容。
    test('is the exact inverse of aiResourceType for navigable sections', () {
      const navigable = [
        NovelWorkspaceSection.chapters,
        NovelWorkspaceSection.outlines,
        NovelWorkspaceSection.characters,
        NovelWorkspaceSection.foreshadowings,
        NovelWorkspaceSection.lore,
        NovelWorkspaceSection.materials,
        NovelWorkspaceSection.skills,
        NovelWorkspaceSection.items,
        NovelWorkspaceSection.factions,
        NovelWorkspaceSection.creatures,
        NovelWorkspaceSection.novel_description,
        NovelWorkspaceSection.maps,
        // screenplay_script / screenplay_scenes 仍共用 'screenplay_scenes'，
        // 无法逆映射；outline 独占 'screenplay_episodes'，可以往返。
        NovelWorkspaceSection.screenplay_outline,
      ];
      for (final section in navigable) {
        expect(
          novelWorkspaceSectionFromAiResourceType(section.aiResourceType),
          section,
          reason: 'round-trip failed for ${section.name}',
        );
      }
    });

    test('returns null for unknown resource types', () {
      expect(novelWorkspaceSectionFromAiResourceType('overview'), isNull);
      expect(novelWorkspaceSectionFromAiResourceType('nope'), isNull);
      expect(
        novelWorkspaceSectionFromAiResourceType('screenplay_beats'),
        isNull,
      );
    });
  });

  group('WorkspaceSelection outline view', () {
    test('requires explicit opt-in before showing all outlines', () {
      const defaultSelection = WorkspaceSelection(
        section: NovelWorkspaceSection.outlines,
      );
      const allOutlinesSelection = WorkspaceSelection(
        section: NovelWorkspaceSection.outlines,
        isViewingAllOutlines: true,
      );

      expect(defaultSelection.isViewingAllOutlines, isFalse);
      expect(allOutlinesSelection.isViewingAllOutlines, isTrue);
    });
  });
}
