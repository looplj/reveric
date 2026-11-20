// 职责: 为宿主提供导演工作区、预览静帧及工程文件导入导出。
// 关联文件:
//   lib/shared/services/director/storage.dart
//   lib/shared/services/director/preview.dart
//   lib/shared/services/director/renderer.dart
//   lib/shared/services/director/session.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../../models/director/document.dart';
import 'renderer.dart';
import 'preview.dart';
import 'session.dart';
import 'storage.dart';

class DirectorFileOutput {
  DirectorFileOutput(this.storage, this.session);
  final DirectorStorage storage;
  final DirectorSession session;
  bool _disposed = false;
  static final _previewWrites = <String, Future<void>>{};

  static Future<DirectorFileOutput> open(
    DirectorSession session,
    String scope, {
    required String novelId,
  }) async {
    return DirectorFileOutput(
      await workspace(scope, novelId: novelId),
      session,
    );
  }

  /// 调度的私有工作区：导出任务、预览静帧和工程文件都放在这里。
  static Future<DirectorStorage> workspace(
    String scope, {
    required String novelId,
  }) async {
    final base = await DirectorStorage.open(novelId);
    final root = _workspace(base, scope);
    await root.create(recursive: true);
    return DirectorStorage(root, base.temporary);
  }

  static void _validateScope(String scope) {
    if (!RegExp(r'^[\w-]+$').hasMatch(scope)) {
      throw ArgumentError.value(scope, 'scope');
    }
  }

  static Directory _workspace(DirectorStorage base, String scope) {
    _validateScope(scope);
    return Directory(p.join(base.root.path, 'workspaces', scope));
  }

  /// 解析调度工作区目录，不创建目录。
  static Directory workspaceDirectory(
    String scope, {
    required String novelId,
    Directory? root,
  }) {
    _validateScope(scope);
    final directorRoot = DirectorStorage.resolveRoot(novelId, base: root);
    return Directory(p.join(directorRoot.path, 'workspaces', scope));
  }

  /// 沙箱缓存目录（随画廊缓存目录一并回收）：`<root>/cache/director_preview/<scope>`。
  static Directory cachedPreviewDirectory(Directory root, String scope) {
    _validateScope(scope);
    return Directory(p.join(root.path, 'cache', 'director_preview', scope));
  }

  /// 读取上次生成的预览；尚未生成时返回空，不创建目录。
  static Future<Uint8List?> readPreview(
    String scope, {
    required String novelId,
    Directory? root,
  }) {
    final dir = workspaceDirectory(scope, novelId: novelId, root: root);
    return DirectorPreview(DirectorStorage(dir, dir)).read();
  }

  /// 读取沙箱缓存中的第 0 帧预览；未命中时按需离屏渲染并写入 `<root>/cache/director_preview/<scope>/preview.png`。
  static Future<Uint8List?> readOrRenderCachedPreview({
    required Directory root,
    required String scope,
    required Future<DirectorDocument?> Function() loadDocument,
    FrameRenderer? renderer,
  }) async {
    final dir = cachedPreviewDirectory(root, scope);
    final storage = DirectorStorage(dir, dir);
    final cache = DirectorPreview(storage);
    final existing = await cache.read();
    if (existing != null) {
      return existing;
    }
    final key = storage.root.path;
    final pending = _previewWrites[key];
    if (pending != null) {
      await pending;
      final afterPending = await cache.read();
      if (afterPending != null) {
        return afterPending;
      }
    }
    final document = await loadDocument();
    if (document == null) {
      return null;
    }
    await renderPreview(document, storage, renderer: renderer);
    return cache.read();
  }

  static Stream<int> previewUpdates(String scope) =>
      DirectorPreview.updates(scope);

  /// 手动关闭与显式工具使用相同的切镜序列预览。
  Future<void> writePreview(DirectorDocument document) =>
      renderPreview(document, storage);

  /// 独立渲染切镜序列的第 0 帧。
  static Future<void> renderPreview(
    DirectorDocument document,
    DirectorStorage storage, {
    FrameRenderer? renderer,
  }) {
    final key = storage.root.path;
    final operation = (_previewWrites[key] ?? Future<void>.value()).then((
      _,
    ) async {
      final capture = renderer ?? DirectorRenderer();
      try {
        final bytes = await capture.capture(document, 0, document.cameraAt(0));
        await DirectorPreview(storage).write(bytes);
      } finally {
        capture.dispose();
      }
    });
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _previewWrites[key] = settled;
    settled.then((_) {
      if (identical(_previewWrites[key], settled)) {
        _previewWrites.remove(key);
      }
    });
    return operation;
  }

  Future<void> importDocument() async {
    final document = await storage.importDocument();
    if (document != null && !_disposed) {
      session.restore(document);
    }
  }

  Future<void> exportDocument() async {
    if (session.hasPendingInput) {
      throw const DocumentError('input', 'apply_pending');
    }
    final document = session.history.document;
    final file = File(
      '${storage.root.path}/exports/${document.id}_${DateTime.now().microsecondsSinceEpoch}.director.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(document.encode(), flush: true);
    await storage.offerFile(file, '${document.title}.director.json');
  }

  void dispose() {
    _disposed = true;
  }
}
