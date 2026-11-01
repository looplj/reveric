// 职责: 将文件副本与处理产物归属会话并限定会话 GC 的删除边界。
// 关联文件:
//   lib/shared/utils/storage_paths.dart
//   lib/shared/services/storage_cleanup_service.dart
//   lib/shared/services/ai/files/reader.dart
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../../utils/random_id.dart';
import '../../../utils/storage_paths.dart';

class SessionFiles {
  SessionFiles({this._root, this.novelId});
  final String? novelId;
  final String? _root;
  String get root => Directory(
    _root ?? RevericPaths.fileWorkspaceParent,
  ).resolveSymbolicLinksSync();

  static void validateId(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('Invalid session identity');
    }
  }

  String get sessionsPath {
    final id = novelId;
    if (id == null) {
      throw StateError('A work is required for session file writes');
    }
    return p.posix.join(RevericPaths.fileWorkspaceDirectory(id), 'sessions');
  }

  String sessionPath(String sessionId) {
    validateId(sessionId);
    return p.posix.join(sessionsPath, sessionId);
  }

  static bool isSessionPath(String path) => RegExp(
    r'^file_workspaces/[A-Za-z0-9_-]+/sessions/[A-Za-z0-9_-]+/',
  ).hasMatch(path);

  Future<Directory> directory(String sessionId) async {
    validateId(sessionId);
    final base = Directory(p.join(root, sessionsPath));
    await base.create(recursive: true);
    if (p.normalize(await base.resolveSymbolicLinks()) !=
        p.normalize(
          p.join(await Directory(root).resolveSymbolicLinks(), sessionsPath),
        )) {
      throw const FormatException('Session directory cannot be a link');
    }
    final directory = Directory(p.join(base.path, sessionId));
    await directory.create(recursive: true);
    if (p.normalize(await directory.resolveSymbolicLinks()) !=
        p.normalize(p.join(await base.resolveSymbolicLinks(), sessionId))) {
      throw const FormatException('Session directory escaped storage');
    }
    return directory;
  }

  Future<File> allocate(String sessionId, String extension) async {
    if (!RegExp(r'^\.[A-Za-z0-9]{1,12}$').hasMatch(extension)) {
      throw const FormatException('Invalid file extension');
    }
    final dir = await directory(sessionId);
    return File(p.join(dir.path, '${buildRandomId('file')}$extension'));
  }

  Future<File> copy(
    String sessionId,
    File source, {
    bool Function()? cancelled,
  }) async {
    final dir = await directory(sessionId);
    final resolved = await source.resolveSymbolicLinks();
    if (p.isWithin(await dir.resolveSymbolicLinks(), resolved)) {
      return File(resolved);
    }
    final extension = p.extension(source.path);
    final target = await allocate(
      sessionId,
      extension.isEmpty ? '.bin' : extension,
    );
    try {
      final output = target.openWrite();
      try {
        await output.addStream(
          source.openRead().map((bytes) {
            if (cancelled?.call() ?? false) {
              throw const FileSystemException('File copy cancelled');
            }
            return bytes;
          }),
        );
        await output.flush();
      } finally {
        await output.close();
      }
      return target;
    } catch (_) {
      if (await target.exists()) {
        await target.delete();
      }
      rethrow;
    }
  }

  String reference(File file) =>
      p.posix.joinAll(p.split(p.relative(file.path, from: root)));

  Future<File> resolve(String path) async {
    if (path.contains('://') || path.contains('\u0000')) {
      throw const FormatException(
        'Use an accessible local file or an imported application file',
      );
    }
    final syntax = RevericPaths.contextForStoredPath(path);
    final relative = syntax.isRelative(path);
    if (relative && (syntax.split(path).contains('..') || path.isEmpty)) {
      throw const FormatException('Invalid relative file path');
    }
    final parts = syntax.split(syntax.normalize(path));
    final base = _root == null && relative && parts.first != 'file_workspaces'
        ? RevericPaths.supportRoot
        : root;
    final file = File(relative ? p.join(base, p.joinAll(parts)) : path);
    if (await FileSystemEntity.type(file.path) != FileSystemEntityType.file) {
      throw FileSystemException('File is unavailable', path);
    }
    final resolved = await file.resolveSymbolicLinks();
    if (relative &&
        !p.isWithin(await Directory(base).resolveSymbolicLinks(), resolved)) {
      throw const FormatException('File escaped application storage');
    }
    return File(resolved);
  }

  Future<void> deleteSessions(Iterable<String> ids) async {
    // Validate the complete group before deleting anything. Missing directories
    // are already clean, including retries after a partially completed cleanup.
    for (final id in ids) {
      validateId(id);
    }
    final base = Directory(p.join(root, sessionsPath));
    if (!await base.exists()) {
      return;
    }
    final expected = p.join(
      await Directory(root).resolveSymbolicLinks(),
      sessionsPath,
    );
    if (p.normalize(await base.resolveSymbolicLinks()) !=
        p.normalize(expected)) {
      throw const FormatException('Session storage cannot be a link');
    }
    for (final id in ids) {
      final path = p.join(base.path, id);
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        continue;
      }
      if (type != FileSystemEntityType.directory) {
        throw const FormatException('Invalid session storage entry');
      }
      // dart:io recursively removes links themselves, never their targets.
      await Directory(path).delete(recursive: true);
    }
  }
}
