// 职责: 定义剪辑工作区宿主接口并提供作品持久化宿主与画廊只读沙箱宿主实现。
// 关联文件:
//   lib/desktop/features/editing/region.dart
//   lib/shared/services/editing/service.dart
//   lib/shared/services/editing/session.dart
//   lib/shared/services/editing/sessions.dart
//   lib/shared/services/production/canvas_service.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md

import 'package:drift/drift.dart' show BooleanExpressionOperators;

import '../../../shared/database/app_database.dart' show AppDatabase, AssetRow;
import '../../../shared/database/novel_content_database.dart'
    show
        canvasKindProduction,
        canvasNodeRefTypeEditing,
        canvasNodeTypeEditing,
        notDeletedSentinel;
import '../../../shared/services/editing/render_service.dart';
import '../../../shared/services/editing/service.dart';
import '../../../shared/services/editing/session.dart';
import '../../../shared/services/editing/sessions.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/ffmpeg_runner.dart';
import '../../../shared/services/storyboard/service.dart';

typedef EditingSpec = ({String? ratio, String? resolution});

/// 剪辑工作区宿主接口：隔离作品持久化/全局 Provider 与画廊只读沙箱两类运行环境。
abstract interface class EditingWorkspaceHost {
  bool get readOnly;

  /// 是否从独立画布进入剪辑（决定顶栏返回按钮的图标与提示）。
  bool get isCanvasEditing;

  /// 若需向工作区面包屑上报当前子页，返回内容库路径；独立页面（如画廊）返回 null。
  String? get subpageDatabasePath;

  /// 仅可写作品模式使用（导入采用片段、素材面板、导出命名）。
  String? get novelId;
  String? get databasePath;
  String? get episodeId;

  EditingService get projects;
  EditingRenderService get renderer;

  EditingSession acquireSession(String editingId);
  void releaseSession(EditingSession session);

  /// 打开剪辑前的访问校验。
  Future<void> verifyAccess(String editingId);

  /// 源资产流（随资产变更刷新片段名称与路径）。
  Stream<List<AssetRow>> watchSources();

  /// 画面规格流（比例与分辨率）。
  Stream<EditingSpec?> watchSpec();

  /// 释放宿主自建的本地资源。
  Future<void> dispose();
}

/// 作品/剧本/画布工作区的可写剪辑宿主，包装现有 Riverpod 提供的持久化服务与会话缓存。
class WorkEditingHost implements EditingWorkspaceHost {
  WorkEditingHost({
    required this.novelId,
    required this.databasePath,
    required this.episodeId,
    required this.projects,
    required this.renderer,
    required this.sessions,
    required this.appDb,
    required this.storyboard,
  });

  final EditingSessions sessions;
  final AppDatabase appDb;
  final StoryboardService storyboard;

  @override
  bool get readOnly => false;

  @override
  bool get isCanvasEditing => episodeId == null;

  @override
  String? get subpageDatabasePath => databasePath;

  @override
  final String novelId;

  @override
  final String databasePath;

  @override
  final String? episodeId;

  @override
  final EditingService projects;

  @override
  final EditingRenderService renderer;

  @override
  EditingSession acquireSession(String editingId) =>
      sessions.get(projects, editingId);

  @override
  void releaseSession(EditingSession session) => sessions.prune();

  @override
  Future<void> verifyAccess(String editingId) async {
    if (episodeId == null) {
      await projects.canvasForEditing(editingId);
    }
  }

  @override
  Stream<List<AssetRow>> watchSources() => appDb.assetDao.watchAssets();

  @override
  Stream<EditingSpec?> watchSpec() => storyboard.watchSettings().map(
    (row) =>
        row == null ? null : (ratio: row.ratio, resolution: row.resolution),
  );

  @override
  Future<void> dispose() async {}
}

/// 画廊只读沙箱剪辑宿主：直接消费解包缓存的 `ProductionCanvasService`，退出即释放、不写库。
class GalleryEditingHost implements EditingWorkspaceHost {
  GalleryEditingHost(this.canvas, {EditingService? projects, this._renderer})
    : projects =
          projects ??
          EditingService(canvas.db, canvas.library, novelId: canvas.novelId);

  final ProductionCanvasService canvas;

  @override
  bool get readOnly => true;

  @override
  bool get isCanvasEditing => true;

  @override
  String? get subpageDatabasePath => null;

  @override
  String? get novelId => null;

  @override
  String? get databasePath => null;

  @override
  String? get episodeId => null;

  @override
  final EditingService projects;

  EditingRenderService? _renderer;

  @override
  EditingRenderService get renderer =>
      _renderer ??= EditingRenderService(projects, FfmpegRunner());

  @override
  EditingSession acquireSession(String editingId) =>
      EditingSession(projects, editingId, readOnly: true);

  @override
  void releaseSession(EditingSession session) => session.dispose();

  @override
  Future<void> verifyAccess(String editingId) async {
    await projects.read(editingId);
    final node =
        await (canvas.db.select(canvas.db.canvasNodes)..where(
              (t) =>
                  t.type.equals(canvasNodeTypeEditing) &
                  t.refType.equals(canvasNodeRefTypeEditing) &
                  t.refId.equals(editingId) &
                  t.deletedAt.equals(notDeletedSentinel),
            ))
            .getSingleOrNull();
    final row = node == null
        ? null
        : await canvas.db.canvasDao.getCanvasById(node.canvasId);
    if (row == null || row.kind != canvasKindProduction) {
      throw StateError('Editing canvas node is missing');
    }
  }

  @override
  Stream<List<AssetRow>> watchSources() =>
      canvas.library.database.assetDao.watchAssets();

  @override
  Stream<EditingSpec?> watchSpec() => canvas.db.screenplayDao.watchRoot().map(
    (row) =>
        row == null ? null : (ratio: row.ratio, resolution: row.resolution),
  );

  @override
  Future<void> dispose() async {
    final active = _renderer;
    _renderer = null;
    if (active != null) {
      await active.dispose();
    }
  }
}
