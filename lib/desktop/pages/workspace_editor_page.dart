// 职责: 按作品类型分派桌面编辑器，画布作品直接进入独立制作页面。
// 关联文件:
//   lib/desktop/pages/novel_editor.dart
//   lib/desktop/widgets/sidebar/rail.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/desktop-window-frame.md

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../widgets/desktop_window_frame.dart';
import 'novel_editor.dart';
import '../../shared/models/content_kind.dart';
import '../features/production/canvas_work.dart';

class WorkspaceEditorPage extends ConsumerWidget {
  const WorkspaceEditorPage({
    super.key,
    required this.novelId,
    this.initialSessionId,
    this.initialChatKickoffPrompt,
    this.initialChatKickoffTitle,
    this.openChatOnEntry = false,
  });

  final String novelId;
  final String? initialSessionId;
  final String? initialChatKickoffPrompt;
  final String? initialChatKickoffTitle;
  final bool openChatOnEntry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(novelProvider(novelId))
        .when(
          data: (novel) {
            if (novel == null) {
              return _WorkspaceRouteState(
                message: context.t(LocaleKeys.libraryWorkspaceLoadFailed),
              );
            }
            if (novel.contentKind == contentKindCanvas) {
              if (novel.contentDatabasePath == null) {
                return _WorkspaceRouteState(
                  message: context.t(LocaleKeys.libraryWorkspaceLoadFailed),
                );
              }
              return CanvasWorkPage(
                novel: novel,
                initialSessionId: initialSessionId,
                initialPrompt: initialChatKickoffPrompt,
                openChatOnEntry: openChatOnEntry,
              );
            }
            return NovelEditorPage(
              novelId: novelId,
              initialSessionId: initialSessionId,

              initialChatKickoffPrompt: initialChatKickoffPrompt,
              initialChatKickoffTitle: initialChatKickoffTitle,
              openChatOnEntry: openChatOnEntry,
            );
          },
          loading: () => _WorkspaceRouteState(
            message: context.t(LocaleKeys.libraryScreenplayWorkspacePreparing),
            loading: true,
          ),
          error: (_, _) => _WorkspaceRouteState(
            message: context.t(LocaleKeys.libraryWorkspaceLoadFailed),
          ),
        );
  }
}

class _WorkspaceRouteState extends StatelessWidget {
  const _WorkspaceRouteState({required this.message, this.loading = false});

  final String message;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return DesktopWindowFrame(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: RevericSpacing.lg),
            ],
            Text(message, style: typo.ui.copyWith(color: colors.textSecondary)),
          ],
        ),
      ),
    );
  }
}
