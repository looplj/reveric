// 职责: 按宿主接口或调度 id 加载导演文档，持有数据库适配与工作区文件资源。
// 关联文件:
//   lib/shared/widgets/screenplay/director_workspace_host.dart
//   lib/shared/widgets/director/session_host.dart
//   lib/shared/widgets/screenplay/director_workspace.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../models/director/actor_catalog.dart';
import '../../providers/novel_providers.dart';
import '../../services/director/session.dart';
import '../director/session_host.dart';
import '../director/strings.dart';
import '../director/viewport.dart';
import 'director_export.dart';
import 'director_workspace.dart';
import 'director_workspace_host.dart';

class ScreenplayDirectorHost extends StatelessWidget {
  const ScreenplayDirectorHost({
    super.key,
    required this.novelId,
    required this.databasePath,
    required this.stagingId,
    required this.onClose,
    this.registerFlush,
    this.canvas,
    this.recognize,
    this.viewportBuilder,
  }) : host = null;

  /// 使用外部宿主（如画廊只读沙箱）加载导演台，不访问全局作品 Provider。
  const ScreenplayDirectorHost.hosted({
    super.key,
    required this.host,
    required this.onClose,
    this.registerFlush,
    this.recognize,
    this.viewportBuilder,
  }) : novelId = null,
       databasePath = null,
       stagingId = null,
       canvas = null;

  final DirectorWorkspaceHost? host;
  final String? novelId;
  final String? databasePath;
  final String? stagingId;
  final ScreenplayDirectorCanvas? canvas;
  final ScreenplayDirectorRecognize? recognize;

  /// 自定义 viewport 自主管理渲染依赖；默认视口仍由此宿主准备 GPU 资源。
  @visibleForTesting
  final Widget Function(DirectorSession, ViewState)? viewportBuilder;
  final VoidCallback onClose;
  final ValueChanged<Future<void> Function()?>? registerFlush;

  @override
  Widget build(BuildContext context) {
    if (host case final activeHost?) {
      return _HostedDirectorHost(
        host: activeHost,
        onClose: onClose,
        registerFlush: registerFlush,
        recognize: recognize,
        viewportBuilder: viewportBuilder,
      );
    }
    return _WorkDirectorHost(
      novelId: novelId!,
      databasePath: databasePath!,
      stagingId: stagingId!,
      canvas: canvas,
      onClose: onClose,
      registerFlush: registerFlush,
      recognize: recognize,
      viewportBuilder: viewportBuilder,
    );
  }
}

class _WorkDirectorHost extends HookConsumerWidget {
  const _WorkDirectorHost({
    required this.novelId,
    required this.databasePath,
    required this.stagingId,
    required this.onClose,
    this.canvas,
    this.registerFlush,
    this.recognize,
    this.viewportBuilder,
  });

  final String novelId;
  final String databasePath;
  final String stagingId;
  final ScreenplayDirectorCanvas? canvas;
  final VoidCallback onClose;
  final ValueChanged<Future<void> Function()?>? registerFlush;
  final ScreenplayDirectorRecognize? recognize;
  final Widget Function(DirectorSession, ViewState)? viewportBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final database = ref.watch(novelContentDatabaseProvider(databasePath));
    final host = useMemoized(
      () => ScreenplayDirectorWorkspaceHost(
        database: database,
        databasePath: databasePath,
        novelId: novelId,
        stagingId: stagingId,
        canvas: canvas,
      ),
      [database, databasePath, stagingId, novelId, viewportBuilder],
    );
    useEffect(
      () => () {
        unawaited(host.dispose());
      },
      [host],
    );
    return _HostedDirectorHost(
      host: host,
      onClose: onClose,
      registerFlush: registerFlush,
      recognize: recognize,
      viewportBuilder: viewportBuilder,
    );
  }
}

class _HostedDirectorHost extends HookWidget {
  const _HostedDirectorHost({
    required this.host,
    required this.onClose,
    this.registerFlush,
    this.recognize,
    this.viewportBuilder,
  });

  final DirectorWorkspaceHost host;
  final VoidCallback onClose;
  final ValueChanged<Future<void> Function()?>? registerFlush;
  final ScreenplayDirectorRecognize? recognize;
  final Widget Function(DirectorSession, ViewState)? viewportBuilder;

  @override
  Widget build(BuildContext context) {
    final camera = defaultCameraName(context);
    final catalog = useMemoized(() => ObjectRef<DirectorActorCatalog?>(null), [
      host,
    ]);
    final loader = useMemoized(
      () => () async {
        final loaded = await host.load(
          defaultCameraName: camera,
          initializeRenderer: viewportBuilder == null,
        );
        catalog.value = loaded.actorCatalog;
        return loaded.session;
      },
      [host, viewportBuilder],
    );
    return DirectorSessionHost(
      key: ObjectKey(host),
      sessionLoader: loader,
      onClose: onClose,
      builder: (context, session) => ScreenplayDirectorWorkspace.hosted(
        host: host,
        session: session,
        actorCatalog: catalog.value!,
        onClose: onClose,
        registerFlush: registerFlush,
        recognize: recognize,
        viewportBuilder: viewportBuilder,
      ),
    );
  }
}
