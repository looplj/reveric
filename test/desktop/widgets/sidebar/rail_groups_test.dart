// 职责: 验证侧边栏 rail 导航表只在创作组按作品类型分叉，其余四组两种类型完全一致。
// 关联文件:
//   lib/desktop/widgets/sidebar/rail.dart
//   lib/shared/models/content_kind.dart
//   lib/shared/localization/locale_keys.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/widgets/sidebar/sidebar.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/content_kind.dart';

void main() {
  test('canvas and standalone screenplay beats have no navigation entry', () {
    for (final kind in [contentKindNovel, contentKindScreenplay]) {
      final labels = railGroupLabelKeysFor(kind).expand((group) => group);
      expect(labels, isNot(contains(LocaleKeys.workspaceCanvas)));
      expect(labels, isNot(contains(LocaleKeys.screenplayBeats)));
    }
  });

  // 创作组是第二组（系统 / 创作 / 世界观 / AI / 灵感）。
  const writingGroupIndex = 1;

  test('novel keeps the chapter-based writing group', () {
    final groups = railGroupLabelKeysFor(contentKindNovel);

    expect(groups[writingGroupIndex], <String>[
      LocaleKeys.workspaceChapters,
      LocaleKeys.workspaceSidebarOutline,
      LocaleKeys.workspaceCharacters,
      LocaleKeys.workspaceSidebarForeshadowing,
      LocaleKeys.workspaceSidebarAssets,
    ]);
  });

  test('screenplay splits production into storyboard and canvas entries', () {
    final groups = railGroupLabelKeysFor(contentKindScreenplay);

    expect(groups[writingGroupIndex], <String>[
      LocaleKeys.screenplayScript,
      LocaleKeys.screenplayOutline,
      LocaleKeys.workspaceCharacters,
      LocaleKeys.workspaceSidebarForeshadowing,
      LocaleKeys.screenplayScenes,
      LocaleKeys.storyboardBoard,
      LocaleKeys.productionCanvas,
      LocaleKeys.workspaceSidebarAssets,
    ]);
  });

  test('every other group is identical across content kinds', () {
    final novel = railGroupLabelKeysFor(contentKindNovel);
    final screenplay = railGroupLabelKeysFor(contentKindScreenplay);

    expect(screenplay.length, novel.length);
    for (var i = 0; i < novel.length; i += 1) {
      if (i == writingGroupIndex) continue;
      expect(screenplay[i], novel[i], reason: 'group $i must be shared');
    }
  });

  test('unknown content kinds fall back to the novel table', () {
    expect(
      railGroupLabelKeysFor('something_else'),
      railGroupLabelKeysFor(contentKindNovel),
    );
  });
}
