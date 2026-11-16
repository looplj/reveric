// 职责: 承接导演台调度的自动保存队列和关闭生命周期，向通用编辑区注入宿主界面。
// 关联文件:
//   lib/shared/services/screenplay/staging.dart
//   lib/shared/widgets/director/workspace.dart
//   lib/shared/widgets/screenplay/director_export.dart
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
import '../../models/director/document.dart';
import '../../services/director/session.dart';
import '../../models/director/actor_catalog.dart';
import '../../services/screenplay/staging.dart';
import '../../services/system_tray_service.dart';
import '../director/error_status.dart';
import '../director/header.dart';
import '../director/strings.dart';
import '../director/viewport.dart';
import '../director/workspace.dart';
import 'director_export.dart';

/// 导演台「AI 识图」：宿主负责选图和交给聊天，[reset] 清空当前导演台并等写入完成。
typedef ScreenplayDirectorRecognize =
    Future<void> Function(
      BuildContext context, {
      required Future<void> Function() reset,
    });

class ScreenplayDirectorWorkspace extends HookConsumerWidget {
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
  });
  final String databasePath;
  final DirectorActorCatalog? actorCatalog;
  final ScreenplayDirectorRecognize? recognize;
  final VideoStagingBinding binding;
  final VoidCallback onClose;
  final ValueChanged<Future<void> Function()?>? registerFlush;

  /// 打开导演台的画布节点；有它时顶栏提供导出。
  final ScreenplayDirectorCanvas? canvas;
  @visibleForTesting
  final Widget Function(DirectorSession, ViewState)? viewportBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = binding.session;
    useListenable(session);
    useProductionSubpage(
      ref,
      databasePath,
      '${tr(context, 'title')} · ${session.history.document.title}',
      stagingId: binding.stagingId,
    );
    final guarding = useRef(false);
    final allowPop = useState(false);
    final close = useRef(onClose)..value = onClose;
    final register = useRef(registerFlush)..value = registerFlush;

    Future<bool> guard() async {
      if (guarding.value) {
        return false;
      }
      guarding.value = true;
      try {
        FocusScope.of(context).unfocus();
        await WidgetsBinding.instance.endOfFrame;
        await binding.flush();
        return true;
      } finally {
        guarding.value = false;
      }
    }

    Future<void> leave() => session.attempt(() async {
      if (await guard() && context.mounted) {
        allowPop.value = true;
        await WidgetsBinding.instance.endOfFrame;
        if (context.mounted) {
          close.value();
        }
      }
    });

    useEffect(() {
      final listener = AppLifecycleListener(
        onInactive: session.background,
        onPause: session.background,
      );
      final unregisterExit = (Platform.isAndroid || Platform.isIOS)
          ? () {}
          : SystemTrayService().registerExitGuard(() async {
              try {
                FocusScope.of(context).unfocus();
                // 托盘退出时可能停止出帧；直接送达失焦通知，让字段提交后再 flush。
                await Future<void>.microtask(
                  FocusManager.instance.applyFocusChangesIfNeeded,
                );
                await binding.flush();
                if (session.hasPendingInput) {
                  throw const DocumentError('input', 'apply_pending');
                }
                return true;
              } catch (error, stack) {
                session.report(error, stack);
                return false;
              }
            });
      register.value?.call(() async {
        final bool accepted;
        try {
          accepted = await guard();
        } catch (error, stack) {
          session.report(error, stack);
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
    }, [binding]);

    return PopScope(
      canPop: allowPop.value,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(leave());
        }
      },
      child: DirectorWorkspace(
        session: session,
        actorCatalog: actorCatalog,
        onRecognizeImage: recognize == null
            ? null
            : () {
                final camera = defaultCameraName(context);
                unawaited(
                  session.attempt(
                    () => recognize!(
                      context,
                      reset: () async {
                        // 走可撤销命令，误覆盖后仍可在导演台撤销。
                        session.restore(
                          DirectorDocument.blank(
                            session.history.document.title,
                            camera: camera,
                          ),
                        );
                        await binding.flush();
                      },
                    ),
                  ),
                );
              },
        viewportBuilder: viewportBuilder,
        header: (viewMode) => DirectorHeader(
          session: session,
          onBack: leave,
          center: viewMode,
          trailing: canvas == null
              ? null
              : (compact) => DirectorExportButton(
                  binding: binding,
                  canvas: canvas!,
                  compact: compact,
                ),
        ),
        footer: DirectorErrorStatus(session: session),
      ),
    );
  }
}
