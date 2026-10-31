// 职责: 提供 BuildContext 本地化扩展与跨平台共享的作品字数文案格式化。
// 关联文件:
//   lib/shared/localization/locale_keys.dart
//   lib/shared/models/novel_workspace.dart
//   lib/shared/utils/number_format.dart
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';

import '../../shared/models/novel_workspace.dart';
import '../utils/number_format.dart';
import 'locale_keys.dart';

extension BuildContextLocalizationX on BuildContext {
  String t(
    String key, {
    List<String>? args,
    Map<String, String>? namedArgs,
    String? gender,
  }) {
    return tr(
      key,
      args: args,
      namedArgs: namedArgs,
      gender: gender,
      context: this,
    );
  }
}

String formatHomeWordCountLabel(BuildContext context, int wordCount) {
  return context.t(
    LocaleKeys.homeStatWordCount,
    namedArgs: {
      'count': formatHomeNovelWordCount(
        wordCount,
        languageCode: Localizations.localeOf(context).languageCode,
      ),
    },
  );
}

String sectionLocaleKey(NovelWorkspaceSection section) {
  return switch (section) {
    NovelWorkspaceSection.overview => LocaleKeys.workspaceOverview,
    NovelWorkspaceSection.canvas => LocaleKeys.workspaceCanvas,
    NovelWorkspaceSection.maps => LocaleKeys.workspaceMaps,
    NovelWorkspaceSection.novel_description =>
      LocaleKeys.workspaceNovelDescription,
    NovelWorkspaceSection.lore => LocaleKeys.workspaceLore,
    NovelWorkspaceSection.outlines => LocaleKeys.workspaceOutlines,
    NovelWorkspaceSection.materials => LocaleKeys.workspaceMaterials,
    NovelWorkspaceSection.characters => LocaleKeys.workspaceCharacters,
    NovelWorkspaceSection.skills => LocaleKeys.workspaceSkills,
    NovelWorkspaceSection.items => LocaleKeys.workspaceItems,
    NovelWorkspaceSection.factions => LocaleKeys.workspaceFactions,
    NovelWorkspaceSection.creatures => LocaleKeys.workspaceCreatures,
    NovelWorkspaceSection.chapters => LocaleKeys.workspaceChapters,
    NovelWorkspaceSection.foreshadowings => LocaleKeys.workspaceForeshadowings,
    NovelWorkspaceSection.entity_graph => LocaleKeys.workspaceEntityGraph,
    NovelWorkspaceSection.story_progress => LocaleKeys.workspaceStoryProgress,
    NovelWorkspaceSection.screenplay_script => LocaleKeys.screenplayScript,
    NovelWorkspaceSection.screenplay_outline => LocaleKeys.screenplayOutline,
    NovelWorkspaceSection.screenplay_beats => LocaleKeys.screenplayBeats,
    NovelWorkspaceSection.screenplay_scenes => LocaleKeys.screenplayScenes,
    NovelWorkspaceSection.storyboard => LocaleKeys.productionTitle,
  };
}
