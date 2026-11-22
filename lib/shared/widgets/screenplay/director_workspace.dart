// 职责: 承接导演台调度的自动保存队列和关闭生命周期，向通用编辑区注入宿主界面。
// 关联文件:
//   lib/shared/services/screenplay/staging.dart
//   lib/shared/widgets/screenplay/director_workspace_host.dart
//   lib/shared/widgets/director/workspace.dart
//   lib/shared/widgets/screenplay/director_export.dart
//   lib/shared/widgets/production/canvas_overlay.dart
//   lib/shared/hooks/use_production_subpage.dart
//   lib/shared/services/system_tray_service.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
//   assets/translations/en/assets.json
//   assets/translations/zh-CN/assets.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../hooks/use_production_subpage.dart';
import '../../models/director/actor_catalog.dart';
import '../../models/director/document.dart';
import '../../services/director/session.dart';
import '../../services/screenplay/staging.dart';
import '../../services/system_tray_service.dart';
import '../production/canvas_overlay.dart';
import '../director/error_status.dart';
import '../director/header.dart';
import '../director/strings.dart';
import '../director/viewport.dart';
import '../director/workspace.dart';
import 'director_export.dart';
import 'director_workspace_host.dart';

/// 导演台「AI 识图」：宿主负责选图和交给聊天，[reset] 清空当前导演台并等写入完成。
typedef ScreenplayDirectorRecognize =
    Future<void> Function(
      BuildContext context, {
      required Future<void> Function() reset,
    });

class ScreenplayDirectorWorkspace extends HookWidget {
  const ScreenplayDirectorWorkspace({
    super.key,
    required this.databasePath,
    required this.binding,
    required this.onClose,
    this.registerFlush,
    this.viewportBuilder,
    this.actorCatalog,
    this.canvas,
    this.recognize,
  }) : host = null,
       session = null;

  const ScreenplayDirectorWorkspace.hosted({
    super.key,
    required this.host,
    required this.session,
    required this.onClose,
    this.registerFlush,
    this.viewportBuilder,
    this.actorCatalog,
    this.recognize,
  }) : databasePath = null,
       binding = null,
       canvas = null;

  final String? databasePath;
  final VideoStagingBinding? binding;
  final ScreenplayDirectorCanvas? canvas;
  final DirectorWorkspaceHost? host;
  final DirectorSession? session;

  final DirectorActorCatalog? actorCatalog;
  final ScreenplayDirectorRecognize? recognize;
  final VoidCallback onClose;
  final ValueChanged<Future<void> Function()?>? registerFlush;
  @visibleForTesting
  final Widget Function(DirectorSession, ViewState)? viewportBuilder;

  @override
  Widget build(BuildContext context) {
    final activeHost = host;
    final activeBinding = binding;
    final activeSession = session ?? activeBinding!.session;
    final readOnly = activeHost?.readOnly ?? activeSession.readOnly;
    final subpagePath = activeHost != null
        ? activeHost.subpageDatabasePath
        : databasePath;
    final stagingId = activeHost?.stagingId ?? activeBinding!.stagingId;
    final enableExitGuard = activeHost?.enableExitGuard ?? !readOnly;
    final lifecycleKey = (activeHost ?? activeBinding)!;

    useListenable(activeSession);
    final guarding = useRef(false);
    final allowPop = useState(false);
    final close = useRef(onClose)..value = onClose;
    final register = useRef(registerFlush)..value = registerFlush;
    final overlay = CanvasWorkOverlayScope.maybeOf(context);
    final overlayRef = useRef(overlay)..value = overlay;
    final leaveRef = useRef<Future<void> Function()?>(null);

    Future<void> flush() async {
      if (activeHost != null) {
        await activeHost.flush();
      } else if (activeBinding != null) {
        await activeBinding.flush();
      }
    }

    Future<bool> guard() async {
      if (readOnly) {
        return true;
      }
      if (guarding.value) {
        return false;
      }
      guarding.value = true;
      try {
        FocusScope.of(context).unfocus();
        await WidgetsBinding.instance.endOfFrame;
        await flush();
        return true;
      } finally {
        guarding.value = false;
      }
    }

    Future<void> leave() async {
      if (readOnly) {
        allowPop.value = true;
        if (context.mounted) {
          close.value();
        }
        return;
      }
      await activeSession.attempt(() async {
        if (await guard() && context.mounted) {
          allowPop.value = true;
          await WidgetsBinding.instance.endOfFrame;
          if (context.mounted) {
            close.value();
          }
        }
      });
    }

    leaveRef.value = leave;
    final directorGeneration = overlay?.directorGeneration ?? -1;
    useEffect(() {
      final token = directorGeneration;
      final bus = overlayRef.value;
      if (bus == null || token < 0) {
        return null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        bus.setDirectorLeave(token, () {
          final current = leaveRef.value;
          if (current == null) {
            return Future<void>.value();
          }
          return current();
        });
      });
      return null;
    }, [directorGeneration, lifecycleKey]);

    useEffect(() {
      final listener = AppLifecycleListener(
        onInactive: activeSession.background,
        onPause: activeSession.background,
      );
      final unregisterExit =
          (!enableExitGuard || Platform.isAndroid || Platform.isIOS)
          ? () {}
          : SystemTrayService().registerExitGuard(() async {
              try {
                FocusScope.of(context).unfocus();
                // 托盘退出时可能停止出帧；直接送达失焦通知，让字段提交后再 flush。
                await Future<void>.microtask(
                  FocusManager.instance.applyFocusChangesIfNeeded,
                );
                await flush();
                if (activeSession.hasPendingInput) {
                  throw const DocumentError('input', 'apply_pending');
                }
                return true;
              } catch (error, stack) {
                activeSession.report(error, stack);
                return false;
              }
            });
      register.value?.call(() async {
        if (readOnly) {
          return;
        }
        final bool accepted;
        try {
          accepted = await guard();
        } catch (error, stack) {
          activeSession.report(error, stack);
          rethrow;
        }
        if (!accepted) {
          throw StateError('director_close_cancelled');
        }
      });
      return () {
        register.value?.call(null);
        unregisterExit();
        listener.dispose();
      };
    }, [lifecycleKey, enableExitGuard, readOnly]);

    Widget? buildTrailing(bool compact) {
      if (readOnly) {
        return null;
      }
      if (activeHost != null) {
        return activeHost.buildHeaderTrailing(context, compact: compact);
      }
      if (canvas == null || activeBinding == null) {
        return null;
      }
      return DirectorExportButton(
        binding: activeBinding,
        canvas: canvas!,
        compact: compact,
      );
    }

    final workspace = DirectorWorkspace(
      session: activeSession,
      actorCatalog: actorCatalog,
      onRecognizeImage: readOnly || recognize == null
          ? null
          : () {
              final camera = defaultCameraName(context);
              unawaited(
                activeSession.attempt(
                  () => recognize!(
                    context,
                    reset: () async {
                      // 走可撤销命令，误覆盖后仍可在导演台撤销。
                      activeSession.restore(
                        DirectorDocument.blank(
                          activeSession.history.document.title,
                          camera: camera,
                        ),
                      );
                      await flush();
                    },
                  ),
                ),
              );
            },
      viewportBuilder: viewportBuilder,
      header: (viewMode) {
        final window = CanvasWorkOverlayScope.maybeOf(context);
        return KeyedSubtree(
          key: window?.directorChromeKey,
          child: DirectorHeader(
            session: activeSession,
            title: activeSession.history.document.title,
            onBack: leave,
            center: viewMode,
            trailing: readOnly ? null : buildTrailing,
            leadingInset: window?.leadingInset ?? 0,
            trailingInset: window?.trailingInset ?? 0,
            barExtent: window?.captionExtent ?? 0,
          ),
        );
      },
      footer: DirectorErrorStatus(session: activeSession),
    );

    return PopScope(
      canPop: allowPop.value,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(leave());
        }
      },
      child: subpagePath == null
          ? workspace
          : _DirectorSubpageReporter(
              databasePath: subpagePath,
              label:
                  '${tr(context, 'title')} · ${activeSession.history.document.title}',
              stagingId: stagingId,
              child: workspace,
            ),
    );
  }
}

class _DirectorSubpageReporter extends HookConsumerWidget {
  const _DirectorSubpageReporter({
    required this.databasePath,
    required this.label,
    required this.stagingId,
    required this.child,
  });

  final String databasePath;
  final String label;
  final String stagingId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    useProductionSubpage(ref, databasePath, label, stagingId: stagingId);
    return child;
  }
}
