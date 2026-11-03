// 职责: 桌面端新建作品的提交流程 — 建作品后关闭表单并进入新作品编辑器；首页新建与小说概览「改编」共用。
// 关联文件:
//   lib/desktop/widgets/novel_form_dialog.dart
//   lib/desktop/pages/home.dart
//   lib/desktop/pages/workspace_editor_page.dart
//   lib/desktop/widgets/workspace/novel_overview.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/components/dialog_feedback.dart';
import '../../shared/components/reveric_dialog.dart';
import '../../shared/database/app_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/models/content_kind.dart';
import '../../shared/models/novel_form_prefill.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/services/novel_actions.dart'
    show NovelTitleConflictException;
import '../pages/workspace_editor_page.dart';
import 'novel_form_dialog.dart';

final _log = AppLogger.forModule('NovelCreate');

/// 新建表单的提交回调：写入作品，成功后关掉表单并从 [context] 所在的导航栈打开新作品。
/// [feedbackContext] 是表单对话框内的上下文，失败提示显示在对话框上。
NovelFormSubmitter createWorkSubmitter(
  BuildContext context,
  WidgetRef ref, {
  required BuildContext feedbackContext,
}) {
  return ({
    required title,
    required authorName,
    required description,
    required category,
    required type,
    required contentKind,
    required plannedEpisodeCount,
    required sourceNovelId,
    required coverSourcePath,
    required removeCover,
    required tags,
  }) async {
    final actions = ref.read(novelActionsProvider);
    final messenger = ScaffoldMessenger.of(feedbackContext);
    final navigator = Navigator.of(context);

    try {
      final novelId = await actions.createNovel(
        title: title,
        authorName: authorName,
        description: description,
        category: category,
        type: type,
        contentKind: contentKind,
        plannedEpisodeCount: plannedEpisodeCount,
        sourceNovelId: sourceNovelId,
        coverSourcePath: coverSourcePath,
        tags: tags,
      );

      if (!context.mounted) {
        return true;
      }
      // Pop the dialog before pushing a new route, otherwise
      // handleSubmit's Navigator.of(context).pop() would pop
      // NovelEditorPage instead of the dialog.
      Navigator.of(context, rootNavigator: true).pop();
      if (context.mounted) {
        navigator.push(
          MaterialPageRoute(
            builder: (_) => WorkspaceEditorPage(
              novelId: novelId,
              openChatOnEntry: contentKind == contentKindNovel,
            ),
          ),
        );
      }
      return true;
    } on NovelTitleConflictException catch (error) {
      _log.error('createNovel title conflict', error: error);
      if (!feedbackContext.mounted) {
        return false;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            context.t(
              LocaleKeys.libraryDuplicateName,
              namedArgs: {'name': error.title},
            ),
          ),
        ),
      );
      return false;
    } catch (error) {
      _log.error('caught error=$error', error: error);
      if (!feedbackContext.mounted) {
        return false;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(context.t(LocaleKeys.libraryCreateNovelFailed))),
      );
      return false;
    }
  };
}

/// 从一本小说出发新建改编剧本：类型、来源与原著信息预填，其余交给用户确认。
void showNovelAdaptationDialog(
  BuildContext context,
  WidgetRef ref,
  Novel source,
) {
  showRevericDialog<void>(
    context: context,
    builder: (_) => DialogFeedback.scope(
      builder: (dialogContext) => NovelFormDialog.create(
        initialContentKind: contentKindScreenplay,
        prefill: NovelFormPrefill.adaptationOf(
          source,
          title: context.t(
            LocaleKeys.libraryAdaptationTitle,
            namedArgs: {'title': source.title},
          ),
        ),
        onSubmit: createWorkSubmitter(
          context,
          ref,
          feedbackContext: dialogContext,
        ),
      ),
    ),
  );
}
