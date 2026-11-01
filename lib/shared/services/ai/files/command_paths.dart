// 职责: 将作品相对路径和当前作品的存储引用解析到作品目录，并阻止相对路径越界。
// 关联文件:
//   lib/shared/services/ai/files/session_files.dart
//   lib/shared/utils/storage_paths.dart
//   lib/shared/services/ai/ffmpeg/inputs.dart
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../../utils/storage_paths.dart';
import 'session_files.dart';

class CommandPaths {
  CommandPaths(this.files);
  final SessionFiles files;

  String get root {
    final id = files.novelId;
    if (id == null || id.isEmpty || id.toLowerCase() == 'shared') {
      throw const FormatException('File commands require a current work.');
    }
    return p.join(files.root, RevericPaths.fileWorkspaceDirectory(id));
  }

  static bool isAbsolute(String path) =>
      p.posix.isAbsolute(path) || p.windows.isAbsolute(path);

  String absolute(String path, {bool write = false}) {
    // Access the work root even for absolute inputs: commands require a work.
    final base = root;
    if (path.isEmpty || path.contains('\u0000') || path.contains('://')) {
      throw const FormatException('Use an accessible local file path.');
    }
    if (isAbsolute(path)) {
      if (write) {
        throw const FormatException('Writes require a work-relative path.');
      }
      return path;
    }
    final syntax = RevericPaths.contextForStoredPath(path);
    if (path.contains(':') || syntax.split(path).contains('..')) {
      throw const FormatException(
        'Relative paths cannot contain .. or a drive prefix.',
      );
    }
    var parts = syntax.split(syntax.normalize(path));
    if (parts.first == 'file_workspaces') {
      // Attachments retain application-root references for persistence. Resolve
      // only this work's prefix here; other works must use explicit access paths.
      if (parts.length < 2 || parts[1] != files.novelId) {
        throw const FormatException(
          'Stored file references must belong to the current work.',
        );
      }
      parts = parts.skip(2).toList();
    }
    return p.normalize(p.join(base, p.joinAll(parts)));
  }

  /// Check each existing ancestor before traversing it, including the work root.
  /// Missing tails are allowed for outputs; links are rejected for relative IO.
  Future<void> checkRelative(String path) async {
    final target = absolute(path, write: true);
    var current = files.root;
    for (final part in p.split(p.relative(target, from: files.root))) {
      if (part == '.') {
        continue;
      }
      current = p.join(current, part);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const FormatException(
          'Work-relative paths cannot contain symbolic links.',
        );
      }
      if (type == FileSystemEntityType.notFound) {
        return;
      }
    }
  }

  Future<File> resolve(String path) async {
    final target = absolute(path);
    if (!isAbsolute(path)) {
      await checkRelative(path);
    }
    return files.resolve(target);
  }

  String reference(File file) {
    if (!p.isWithin(root, file.path)) {
      throw const FormatException('The file is outside the current work.');
    }
    return p.posix.joinAll(p.split(p.relative(file.path, from: root)));
  }
}
