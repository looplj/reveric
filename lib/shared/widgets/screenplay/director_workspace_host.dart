// 职责: 定义导演台工作区宿主接口并提供作品持久化宿主与画廊只读沙箱宿主实现。
// 关联文件:
//   lib/shared/widgets/screenplay/director_host.dart
//   lib/shared/widgets/screenplay/director_workspace.dart
//   lib/shared/services/screenplay/staging.dart
//   lib/shared/services/director/session.dart
//   lib/shared/services/production/canvas_service.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/file-access.md

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart';

import '../../database/novel_content_database.dart'
    show
        NovelContentDatabase,
        canvasKindProduction,
        canvasNodeRefTypeStaging,
        canvasNodeTypeStaging,
        notDeletedSentinel;
import '../../models/director/actor_catalog.dart';
import '../../models/director/document.dart';
import '../../services/director/actor_models.dart';
import '../../services/director/export_task.dart';
import '../../services/director/file_output.dart';
import '../../services/director/session.dart';
import '../../services/production/canvas_service.dart';
import '../../services/screenplay/actor_catalog.dart';
import '../../services/screenplay/staging.dart';
import 'director_export.dart';

typedef DirectorHostSession = ({
  DirectorSession session,
  DirectorActorCatalog actorCatalog,
});

/// 导演台工作区宿主接口：隔离作品持久化/文件工作区与画廊只读沙箱两类运行环境。
abstract interface class DirectorWorkspaceHost {
  bool get readOnly;
  String get stagingId;

  /// 上报工作区面包屑的内容库路径；画廊等独立页面返回 null。
  String? get subpageDatabasePath;

  /// 是否注册桌面端托盘退出守卫；画廊只读模式返回 false。
  bool get enableExitGuard;

  /// 准备渲染依赖并加载只读/可写导演会话。
  Future<DirectorHostSession> load({
    required String defaultCameraName,
    required bool initializeRenderer,
  });

  /// 构建顶栏右侧宿主操作（如导出按钮）；只读宿主返回 null。
  Widget? buildHeaderTrailing(BuildContext context, {required bool compact});

  Future<void> flush();
  Future<void> dispose();
}

/// 作品/剧本/画布工作区的可写导演台宿主，包装持久化绑定、文件输出与导出入口。
class ScreenplayDirectorWorkspaceHost implements DirectorWorkspaceHost {
  ScreenplayDirectorWorkspaceHost({
    required this.database,
    required this.databasePath,
    required this.novelId,
    required this.stagingId,
    this.canvas,
  }) : binding = VideoStagingBinding(database.screenplayDao, stagingId);

  final NovelContentDatabase database;
  final String databasePath;
  final String novelId;
  final ScreenplayDirectorCanvas? canvas;
  final VideoStagingBinding binding;

  DirectorFileOutput? _output;
  bool _disposed = false;

  @override
  bool get readOnly => false;

  @override
  final String stagingId;

  @override
  String? get subpageDatabasePath => databasePath;

  @override
  bool get enableExitGuard => true;

  @override
  Future<DirectorHostSession> load({
    required String defaultCameraName,
    required bool initializeRenderer,
  }) async {
    if (initializeRenderer) {
      await Scene.initializeStaticResources();
      await ActorModels.load();
    }
    final catalog = loadScreenplayActorCatalog(database);
    final session = await binding.load(
      camera: defaultCameraName,
      exportVersions: (id) => ExportTaskOrchestrator.completedFor(
        _output!.storage,
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
      if (_disposed) {
        binding.dispose();
        files.dispose();
      } else {
        _output = files;
      }
      return (session: session, actorCatalog: catalog);
    } catch (_) {
      binding.dispose();
      session.dispose();
      rethrow;
    }
  }

  @override
  Widget? buildHeaderTrailing(BuildContext context, {required bool compact}) {
    if (canvas == null) {
      return null;
    }
    return DirectorExportButton(
      binding: binding,
      canvas: canvas!,
      compact: compact,
    );
  }

  @override
  Future<void> flush() => binding.flush();

  @override
  Future<void> dispose() async {
    _disposed = true;
    binding.dispose();
    _output?.dispose();
    _output = null;
  }
}

/// 画廊只读沙箱导演台宿主：直接读取沙箱数据库文档，不写库、不建磁盘工作区、不挂托盘守卫。
class GalleryDirectorWorkspaceHost implements DirectorWorkspaceHost {
  const GalleryDirectorWorkspaceHost({
    required this.canvas,
    required this.stagingId,
  });

  final ProductionCanvasService canvas;

  @override
  bool get readOnly => true;

  @override
  final String stagingId;

  @override
  String? get subpageDatabasePath => null;

  @override
  bool get enableExitGuard => false;

  @override
  Future<DirectorHostSession> load({
    required String defaultCameraName,
    required bool initializeRenderer,
  }) async {
    if (initializeRenderer) {
      await Scene.initializeStaticResources();
      await ActorModels.load();
    }
    final node =
        await (canvas.db.select(canvas.db.canvasNodes)..where(
              (t) =>
                  t.type.equals(canvasNodeTypeStaging) &
                  t.refType.equals(canvasNodeRefTypeStaging) &
                  t.refId.equals(stagingId) &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .getSingleOrNull();
    final row = node == null
        ? null
        : await canvas.db.canvasDao.getCanvasById(node.canvasId);
    if (row == null || row.kind != canvasKindProduction) {
      throw const DocumentError('staging', 'not_found');
    }
    final stored = await canvas.db.screenplayDao.getStaging(stagingId);
    if (stored == null) {
      throw const DocumentError('staging', 'not_found');
    }
    final document = stored.document == null
        ? DirectorDocument.blank(stored.title, camera: defaultCameraName)
        : DirectorDocument.fromJson(stored.document!);
    return (
      session: DirectorSession(document, readOnly: true),
      actorCatalog: const DirectorActorCatalog(initialActors: []),
    );
  }

  @override
  Widget? buildHeaderTrailing(BuildContext context, {required bool compact}) =>
      null;

  @override
  Future<void> flush() async {}

  @override
  Future<void> dispose() async {}
}
