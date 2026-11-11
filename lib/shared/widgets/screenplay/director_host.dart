// 职责: 按调度 id 加载导演文档，持有数据库适配与工作区文件资源。
// 关联文件:
//   lib/shared/services/screenplay/staging.dart
//   lib/shared/services/director/file_output.dart
//   lib/shared/widgets/director/session_host.dart
//   lib/shared/widgets/screenplay/director_workspace.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import '../../services/director/actor_models.dart';
import '../../services/director/session.dart';
import '../director/viewport.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../providers/novel_providers.dart';
import '../../services/screenplay/staging.dart';
import '../../services/director/file_output.dart';
import '../../services/director/export_task.dart';
import '../../models/director/actor_catalog.dart';
import '../../services/screenplay/actor_catalog.dart';
import '../director/session_host.dart';
import '../director/strings.dart';
import 'director_export.dart';
import 'director_workspace.dart';

class ScreenplayDirectorHost extends HookConsumerWidget {
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
  });
  final String novelId;
  final String databasePath;
  final String stagingId;
  final ScreenplayDirectorRecognize? recognize;

  /// 自定义 viewport 自主管理渲染依赖；默认视口仍由此宿主准备 GPU 资源。
  @visibleForTesting
  final Widget Function(DirectorSession, ViewState)? viewportBuilder;
  final VoidCallback onClose;
  final ValueChanged<Future<void> Function()?>? registerFlush;
  final ScreenplayDirectorCanvas? canvas;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final database = ref.watch(novelContentDatabaseProvider(databasePath));
    final binding = useMemoized(
      () => VideoStagingBinding(database.screenplayDao, stagingId),
      [database, stagingId, novelId, viewportBuilder],
    );
    final camera = defaultCameraName(context);
    final output = useMemoized(() => ObjectRef<DirectorFileOutput?>(null), [
      binding,
    ]);
    final catalog = useMemoized(() => ObjectRef<DirectorActorCatalog?>(null), [
      binding,
    ]);
    final disposed = useMemoized(() => ObjectRef(false), [binding]);
    final loader = useMemoized(
      () => () async {
        if (viewportBuilder == null) {
          await Scene.initializeStaticResources();
          await ActorModels.load();
        }
        catalog.value = loadScreenplayActorCatalog(database);
        final session = await binding.load(
          camera: camera,
          exportVersions: (id) => ExportTaskOrchestrator.completedFor(
            output.value!.storage,
            binding.session.history.document.id,
            id,
          ),
        );
        try {
          final files = await DirectorFileOutput.open(
            session,
            stagingId,
            novelId: novelId,
          );
          binding.updatePreview = files.writePreview;
          if (disposed.value) {
            binding.dispose();
            files.dispose();
          } else {
            output.value = files;
          }
          return session;
        } catch (_) {
          binding.dispose();
          session.dispose();
          rethrow;
        }
      },
      [binding],
    );
    useEffect(
      () => () {
        disposed.value = true;
        binding.dispose();
        output.value?.dispose();
      },
      [binding],
    );
    return DirectorSessionHost(
      key: ObjectKey(binding),
      sessionLoader: loader,
      onClose: onClose,
      builder: (context, session) => ScreenplayDirectorWorkspace(
        databasePath: databasePath,
        binding: binding,
        actorCatalog: catalog.value!,
        onClose: onClose,
        registerFlush: registerFlush,
        canvas: canvas,
        recognize: recognize,
        viewportBuilder: viewportBuilder,
      ),
    );
  }
}
