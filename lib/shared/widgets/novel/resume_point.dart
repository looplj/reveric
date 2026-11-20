// 职责: 解析作品「继续写」的落点 — 小说取最近改过的章节与末句，剧本取工作区记住的场次与末句；桌面与移动端共用。
// 关联文件:
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/screenplay_providers.dart
//   lib/shared/providers/screenplay_workspace_state_provider.dart
//   lib/shared/providers/novel_workspace_state_provider.dart
//   lib/shared/utils/chapter_last_sentence.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../database/novel_content_database.dart'
    show ScreenplayEpisodeRow, ScreenplaySeasonRow;
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/content_kind.dart';
import '../../models/novel.dart';
import '../../models/novel_workspace.dart';
import '../../models/screenplay.dart';
import '../../providers/novel_providers.dart';
import '../../providers/novel_workspace_state_provider.dart';
import '../../providers/screenplay_providers.dart';
import '../../providers/screenplay_workspace_state_provider.dart';
import '../../utils/chapter_last_sentence.dart';
import '../screenplay/labels.dart';

/// 「继续写」卡片要回答的两件事：停在哪（[where]），最后写了什么（[excerpt]）。
class WorkResumePoint {
  const WorkResumePoint({this.where, this.excerpt, this.chapterId});

  final String? where;
  final String? excerpt;

  /// 小说的落点章节；打开作品前用它把工作区定位到这一章。
  final String? chapterId;
}

/// 在 build 中调用。数据还没加载出来或作品没有正文时，返回空落点。
WorkResumePoint watchWorkResumePoint(
  BuildContext context,
  WidgetRef ref,
  Novel work,
) {
  if (!work.hasContentDatabase || work.contentKind == contentKindCanvas) {
    return const WorkResumePoint();
  }
  final path = work.contentDatabasePath!;
  return work.contentKind == contentKindScreenplay
      ? _screenplayResumePoint(context, ref, work, path)
      : _novelResumePoint(context, ref, path);
}

WorkResumePoint _novelResumePoint(
  BuildContext context,
  WidgetRef ref,
  String path,
) {
  final chapter = ref.watch(lastEditedChapterProvider(path)).asData?.value;
  if (chapter == null) {
    return const WorkResumePoint();
  }
  final number = chapter.chapterNum == null
      ? null
      : context.t(
          LocaleKeys.commonChapterNumber,
          namedArgs: {'number': '${chapter.chapterNum}'},
        );
  final title = chapter.title?.trim() ?? '';
  return WorkResumePoint(
    where: [?number, if (title.isNotEmpty) title].join(' · '),
    excerpt: extractLastWrittenSentence(chapter.content),
    chapterId: chapter.id,
  );
}

WorkResumePoint _screenplayResumePoint(
  BuildContext context,
  WidgetRef ref,
  Novel work,
  String path,
) {
  final root = ref.watch(screenplayRootProvider(path)).asData?.value;
  if (root == null) {
    return const WorkResumePoint();
  }
  final state = ref.watch(
    screenplayWorkspaceStateControllerProvider(work.id, path),
  );
  final episodes =
      ref
          .watch(screenplayEpisodesOfScreenplayProvider(path, root.id))
          .asData
          ?.value ??
      const <ScreenplayEpisodeRow>[];
  final episode =
      episodes.where((e) => e.id == state.episodeId).firstOrNull ??
      episodes.where((e) => e.seasonId == state.seasonId).firstOrNull ??
      episodes.firstOrNull;
  if (episode == null) {
    return const WorkResumePoint();
  }
  final seasons =
      ref.watch(screenplaySeasonsProvider(path, root.id)).asData?.value ??
      const <ScreenplaySeasonRow>[];
  final season = seasons.where((s) => s.id == episode.seasonId).firstOrNull;
  final previews =
      ref
          .watch(screenplayEpisodeScriptPreviewProvider(path, episode.id))
          .asData
          ?.value ??
      const <EpisodeScriptScenePreview>[];
  final (:preview, :quote) = screenplayContinuePoint(previews, state.sceneId);
  final scene = preview?.scene;
  final episodeTitle = episode.title.trim();
  return WorkResumePoint(
    where: [
      // 只有一季时季号是噪音。
      if (seasons.length > 1 && season != null)
        context.t(
          LocaleKeys.screenplaySeason,
          namedArgs: {'number': '${season.seasonNumber}'},
        ),
      [
        screenplayEpisodeNumberLabel(context, episode),
        if (episodeTitle.isNotEmpty) episodeTitle,
      ].join(' '),
      if (scene != null)
        '${screenplaySceneLabel(context, scene)} ${screenplaySceneTitle(context, scene)}',
    ].join(' · '),
    excerpt: quote,
  );
}

/// 打开小说前把工作区定位到 [chapterId]，编辑器恢复时直接落在这一章。
/// 剧本工作区自己记住季 / 集 / 场，不需要这一步。
Future<void> selectResumeChapter(
  WidgetRef ref,
  String novelId,
  String chapterId,
) async {
  final provider = novelWorkspaceStateControllerProvider(novelId);
  // 定位后会异步落库；持有订阅直到写完，避免 provider 中途被回收。
  final subscription = ref.listenManual(provider, (_, _) {});
  try {
    final controller = ref.read(provider.notifier);
    await controller.ready;
    controller.updateSelection(
      WorkspaceSelection(
        section: NovelWorkspaceSection.chapters,
        itemId: chapterId,
      ),
    );
    await controller.flush();
  } finally {
    subscription.close();
  }
}
