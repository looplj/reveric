// 职责: 承载独立画布作品的全窗制作、剪辑、导演台与浮动聊天，并统一离开保存。
// 关联文件:
//   lib/desktop/features/production/region.dart
//   lib/desktop/features/production/canvas_work_header.dart
//   lib/desktop/features/editing/canvas_shell.dart
//   lib/desktop/widgets/ai/chat/panel.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/desktop-window-frame.md
//   .agents/rules/file-access.md
import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../../../shared/services/director/session.dart';
import '../../../shared/widgets/director/viewport.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/database/app_database.dart' show Novel;
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/ai_provider.dart';
import '../../../shared/models/novel_workspace.dart';
import '../../../shared/providers/production_chat.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/app_background.dart';
import '../../../shared/widgets/screenplay/director_shell.dart';
import '../../widgets/desktop_window_frame.dart';
import '../../widgets/ai/chat/panel.dart';
import '../../widgets/ai/chat/floating.dart';
import '../editing/canvas_shell.dart';
import 'canvas_work_header.dart';
import 'edit_session.dart';
import 'history_region.dart';
import 'region.dart';
import 'support.dart';
import 'text_node.dart';

class CanvasWorkPage extends HookConsumerWidget {
  const CanvasWorkPage({
    super.key,
    required this.novel,
    this.initialSessionId,
    this.initialPrompt,
    this.openChatOnEntry = false,
    this.directorViewportBuilder,
  });
  final Novel novel;
  final String? initialSessionId, initialPrompt;
  final bool openChatOnEntry;
  @visibleForTesting
  final Widget Function(DirectorSession, ViewState)? directorViewportBuilder;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = useState(initialSessionId);
    final draft = useState<AiChatHandoffDraft?>(null);
    final shortcut = useState<AiChatShortcutDraft?>(null);
    final flush = useRef<Future<void> Function()?>(null);
    final titleFlush = useRef<Future<void> Function()?>(null);
    final allowPop = useState(false);
    final leaving = useRef(false);
    final headerKeys = useMemoized(
      () => (
        back: GlobalKey(),
        title: GlobalKey(),
        save: GlobalKey(),
        cancel: GlobalKey(),
        settings: GlobalKey(),
      ),
    );
    final chatProvider = productionChatProvider(novel.id);
    final chat = ref.watch(chatProvider);
    final chatState = ref.read(chatProvider.notifier);
    final chatStarted = useRef(false);
    if (chat.open) {
      chatStarted.value = true;
    }
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) {
          return;
        }
        chatState.setCanvas(true);
        if (openChatOnEntry || initialPrompt != null) {
          chatState.setOpen(true);
        }
        if (initialPrompt != null) {
          draft.value = AiChatHandoffDraft(
            id: 'canvas-initial',
            label: '',
            title: '',
            content: initialPrompt!,
            initialText: initialPrompt,
            autoSend: false,
          );
        }
      });
      return null;
    }, [novel.id]);
    Future<void> leave() async {
      if (leaving.value) {
        return;
      }
      leaving.value = true;
      try {
        await titleFlush.value?.call();
        await flush.value?.call();
        if (!context.mounted) {
          return;
        }
        allowPop.value = true;
        await WidgetsBinding.instance.endOfFrame;
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      } finally {
        leaving.value = false;
      }
    }

    // 文本节点输入框的发送：要求已在节点下方写完，打开聊天后用选中的模型新开对话并提交；
    // 没有可用模型时提交到当前会话，由聊天提示去配置。
    void ask(String prompt, {AiModelOption? model, String? effort}) {
      chatState.setOpen(true);
      if (model != null) {
        draft.value = AiChatHandoffDraft(
          id: 'canvas-text-${DateTime.now().microsecondsSinceEpoch}',
          label: '',
          title: '',
          content: prompt,
          initialText: prompt,
          providerId: model.providerId,
          model: model.model,
          reasoningEffort: effort,
          autoSend: true,
        );
        return;
      }
      shortcut.value = AiChatShortcutDraft(
        id: 'production_${DateTime.now().microsecondsSinceEpoch}',
        text: prompt,
        autoSend: true,
      );
    }

    Future<void> uploadScript() async {
      chatState.setOpen(true);
      final files = await openFiles(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Script', extensions: ['txt', 'md', 'pdf']),
        ],
      );
      if (!context.mounted || files.isEmpty) {
        return;
      }
      const prompt = '请读取附件剧本，按原文顺序规划画布分镜。先说明制作安排，暂不生成媒体。';
      final label = context.t(LocaleKeys.productionUploadScript);
      draft.value = AiChatHandoffDraft(
        id: 'canvas-script-${DateTime.now().microsecondsSinceEpoch}',
        label: label,
        title: label,
        content: prompt,
        initialText: prompt,
        files: files,
        autoSend: false,
      );
    }

    return PopScope(
      canPop: allowPop.value,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(productionRun(context, leave));
        }
      },
      child: Scaffold(
        backgroundColor: appScaffoldBackgroundColor(
          RevericTheme.colorsOf(context),
          ref.watch(appBackgroundActiveProvider),
        ),
        body: DesktopWindowFrame(
          titleBarGestureExclusionKeys: [
            headerKeys.back,
            headerKeys.title,
            headerKeys.save,
            headerKeys.cancel,
            headerKeys.settings,
          ],
          child: Stack(
            fit: StackFit.expand,
            children: [
              ProductionHistoryRegion(
                novel: novel,
                episodeId: '',
                child: Column(
                  children: [
                    CanvasWorkHeader(
                      gestureKeys: headerKeys,
                      novel: novel,
                      onBack: () => productionRun(context, leave),
                      registerFlush: (value) => titleFlush.value = value,
                    ),
                    Expanded(
                      child: ScreenplayDirectorShell(
                        novelId: novel.id,
                        databasePath: novel.contentDatabasePath!,
                        viewportBuilder: directorViewportBuilder,
                        registerFlush: (value) => flush.value = value,
                        builder: (openDirector, registerDirector) =>
                            CanvasEditingShell(
                              novel: novel,
                              registerFlush: registerDirector,
                              builder: (registerCanvas) => ProductionTextAsk(
                                ask: ask,
                                child: ProductionCanvasRegion(
                                  novel: novel,
                                  episodeId: '',
                                  registerFlush: (saveCanvas) => registerCanvas(
                                    saveCanvas == null
                                        ? null
                                        : () async {
                                            await titleFlush.value?.call();
                                            await saveCanvas();
                                          },
                                  ),
                                  sceneActions: ProductionSceneActions(
                                    openDirector: (id, {canvas}) async {
                                      await titleFlush.value?.call();
                                      await openDirector(id, canvas: canvas);
                                    },
                                    uploadScript: uploadScript,
                                  ),
                                ),
                              ),
                            ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned.fill(
                top: DesktopWindowFrame.titleBarHeight,
                child: FloatingAiChat(
                  open: chat.open,
                  onOpenChanged: chatState.setOpen,
                  sessionId: sessionId.value,
                  panel: !chatStarted.value
                      ? const SizedBox.shrink()
                      : AiChatPanel(
                          novel: novel,
                          databasePath: novel.contentDatabasePath,
                          workspaceSection: NovelWorkspaceSection.storyboard,
                          workspaceTitle: novel.title,
                          activeSessionId: sessionId.value,
                          floating: true,
                          avoidWindowCaption: false,
                          onClose: () => chatState.setOpen(false),
                          onRequestNewSession: () async {
                            sessionId.value =
                                '__new__${DateTime.now().microsecondsSinceEpoch}';
                          },
                          onSessionRestored: (id) => sessionId.value = id,
                          onActiveSessionIdChanged: (id) async =>
                              sessionId.value = id,
                          handoffDraft: draft.value,
                          onRequestHandoff: (value) => draft.value = value,
                          onHandoffDraftConsumed: (id) {
                            if (draft.value?.id == id) {
                              draft.value = null;
                            }
                          },
                          shortcutDraft: shortcut.value,
                          onShortcutDraftConsumed: (id) {
                            if (shortcut.value?.id == id) {
                              shortcut.value = null;
                            }
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
