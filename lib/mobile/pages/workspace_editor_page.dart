// 职责: 移动端作品编辑入口 — 按内容类型分派编辑器，并处理进入时打开聊天。
// 关联文件:
//   lib/mobile/pages/novel_editor_page.dart
//   lib/mobile/features/screenplay/editor_page.dart
//   lib/shared/models/content_kind.dart
//   lib/shared/database/app_database.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/hooks.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../shared/database/app_database.dart';
import '../../shared/models/content_kind.dart';
import '../../shared/models/queued_chat_message.dart';
import '../features/screenplay/editor_page.dart';
import 'novel_editor_page.dart';
import 'novel_chat_page.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';

class MobileWorkspaceEditorPage extends HookWidget {
  const MobileWorkspaceEditorPage({
    super.key,
    required this.novel,
    this.initialChatKickoffPrompt,
    this.initialChatKickoffTitle,
    this.openChatOnEntry = false,
  });

  final Novel novel;
  final String? initialChatKickoffPrompt;

  /// 剧本开场会话的标题（如「导入剧本」）。
  final String? initialChatKickoffTitle;
  final bool openChatOnEntry;

  @override
  Widget build(BuildContext context) {
    final isScreenplay = novel.contentKind == contentKindScreenplay;
    final path = novel.contentDatabasePath;
    final kickoffPrompt = initialChatKickoffPrompt?.trim();
    final hasKickoff = kickoffPrompt != null && kickoffPrompt.isNotEmpty;
    useEffect(() {
      if (!isScreenplay ||
          (!openChatOnEntry && !hasKickoff) ||
          path == null ||
          path.isEmpty) {
        return null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) {
          return;
        }
        Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => MobileNovelChatPage(
              novelId: novel.id,
              databasePath: path,
              handoff: hasKickoff
                  ? PendingChatHandoff(
                      label: initialChatKickoffTitle ?? '',
                      content: kickoffPrompt,
                      initialText: kickoffPrompt,
                      autoSend: true,
                    )
                  : null,
            ),
          ),
        );
      });
      return null;
    }, [novel.id, path, isScreenplay, openChatOnEntry, kickoffPrompt]);

    if (novel.contentKind == contentKindCanvas) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: Text(context.t(LocaleKeys.productionCanvasDesktopOnly)),
          ),
        ),
      );
    }
    if (isScreenplay) {
      return MobileScreenplayEditorPage(novel: novel);
    }
    return MobileNovelEditorPage(
      novel: novel,

      initialChatKickoffPrompt: initialChatKickoffPrompt,
      openChatOnEntry: openChatOnEntry,
    );
  }
}
