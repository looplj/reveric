// 职责: 应用本地资源（封面、头像、内容库等）路径的相对/绝对解析与归一化。
// 关联文件:
//   lib/main.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/services/demo_novel.dart
//   lib/mobile/widgets/novel_cover.dart
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 资源以逻辑相对路径持久化；整个 file_workspaces 文件夹可放在指定父目录下。
/// 写入时用 [toRelative] 归一化，读取时用 [resolveStored] 解析。
/// 启动时必须先调用 [initialize] 缓存根目录。
class RevericPaths {
  RevericPaths._();

  static String? _supportRoot;
  static String? _fileWorkspaceParent;

  /// 启动期一次性缓存 Application Support 根目录路径。
  /// 必须在调用 [supportRoot] / [resolveStored] / [toRelative] 之前完成。
  static Future<void> initialize({String? fileWorkspaceParent}) async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _supportRoot = dir.path;
    _fileWorkspaceParent = fileWorkspaceParent;
  }

  /// 文件工作区的物理父目录；数据库、设置、缓存仍在 supportRoot。
  static String get fileWorkspaceParent => _fileWorkspaceParent ?? supportRoot;

  static String get fileWorkspaceRoot =>
      p.join(fileWorkspaceParent, 'file_workspaces');

  /// 文件工作区路径从所选父目录解析，其余资源仍从应用目录解析。
  static String resolveRelative(String relative, {required String support}) {
    final syntax = contextForStoredPath(relative);
    if (syntax.split(relative).contains('..') || syntax.isAbsolute(relative)) {
      throw const FormatException('Invalid application relative path');
    }
    // Reject traversal before normalization, then classify paths such as ./file_workspaces.
    final parts = syntax.split(syntax.normalize(relative));
    final root = parts.isNotEmpty && parts.first == 'file_workspaces'
        ? _fileWorkspaceParent ?? support
        : support;
    return p.join(root, p.joinAll(parts));
  }

  /// 同步读取已缓存的 Application Support 根目录。
  /// 必备依赖 — 未初始化时直接抛错（参见项目规则「必备依赖非空规则」）。
  static String get supportRoot {
    final root = _supportRoot;
    if (root == null) {
      throw StateError(
        'RevericPaths.initialize() must be awaited before supportRoot is read.',
      );
    }
    return root;
  }

  /// 存储值可能来自另一平台；按路径本身选择语法，而不是使用宿主系统语法。
  static p.Context contextForStoredPath(String stored) {
    return stored.contains('\\') || RegExp(r'^[A-Za-z]:').hasMatch(stored)
        ? p.windows
        : p.posix;
  }

  /// 作品文件工作目录；null 明确表示共享／全局归属。
  static String fileWorkspaceDirectory(String? novelId) {
    if (novelId != null &&
        (novelId.toLowerCase() == 'shared' ||
            !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(novelId))) {
      throw ArgumentError.value(novelId, 'novelId');
    }
    return p.posix.join('file_workspaces', novelId ?? 'shared');
  }

  /// 作品媒体目录；null 明确表示共享／全局归属。
  static String mediaDirectory(String? novelId, String type) {
    final folder = switch (type) {
      'image' => 'images',
      'video' => 'videos',
      'audio' => 'audio',
      'file' => 'files',
      _ => throw ArgumentError.value(type, 'type'),
    };
    return p.posix.join(fileWorkspaceDirectory(novelId), folder);
  }

  /// 构造受控相对路径，拒绝 Windows 与 POSIX 路径穿越。
  static String mediaPath(String? novelId, String type, String name) {
    final syntax = contextForStoredPath(name);
    final segments = syntax.split(name);
    if (name.isEmpty ||
        syntax.isAbsolute(name) ||
        segments.any((part) => part == '..' || part == '.' || part.isEmpty) ||
        name.contains(':')) {
      throw ArgumentError.value(name, 'name');
    }
    return p.posix.join(
      mediaDirectory(novelId, type),
      p.posix.joinAll(segments),
    );
  }

  /// 图片客户端拥有的未登记结果，仅允许 file_workspaces 根目录下的专用 .part 文件。
  static bool isImageResultPart(Directory root, String path) {
    final absolute = p.normalize(p.absolute(path));
    return p.equals(
          p.dirname(absolute),
          p.join(root.absolute.path, 'file_workspaces'),
        ) &&
        p.basename(absolute).startsWith('reveric_image_result_') &&
        absolute.endsWith('.part');
  }

  /// 已有文件只有实际位于当前作品及类型目录内才能原地登记。
  static Future<bool> ownsMediaFile(
    Directory root,
    String novelId,
    String type,
    File file,
  ) async {
    final directory = p.join(root.path, mediaDirectory(novelId, type));
    if (!p.isWithin(directory, p.normalize(file.absolute.path)) ||
        !await file.exists()) {
      return false;
    }
    await requireNoLinks(root, file.path);
    return true;
  }

  /// 不跟随管控根内的符号链接；写入时也检查尚不存在目标的全部祖先。
  static Future<void> requireNoLinks(Directory root, String path) async {
    final base = p.normalize(root.absolute.path);
    final target = p.normalize(p.absolute(path));
    if (target != base && !p.isWithin(base, target)) {
      throw const FileSystemException('Path escapes storage root');
    }
    var current = base;
    final parts = target == base
        ? <String>[]
        : p.split(p.relative(target, from: base));
    for (final part in ['', ...parts]) {
      current = part.isEmpty ? current : p.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FileSystemException(
          'Symbolic links are not allowed in media storage',
        );
      }
    }
  }

  /// 解析相对路径或当前可读的绝对路径；空值和缺失文件返回 null。
  static String? resolveStored(String? stored) {
    if (stored == null || stored.isEmpty) {
      return null;
    }
    final path = resolveDatabasePath(stored);
    return File(path).existsSync() ? path : null;
  }

  /// 解析数据库路径。已有应用目录的调用方可显式传入 [support]。
  static String resolveDatabasePath(String stored, {String? support}) {
    final syntax = contextForStoredPath(stored);
    if (syntax.isAbsolute(stored)) {
      return stored;
    }
    if (syntax.split(stored).contains('..')) {
      throw const FormatException(
        'Stored path escapes the application directory.',
      );
    }
    return resolveRelative(stored, support: support ?? supportRoot);
  }

  /// 把绝对路径归一化为相对当前根的路径，便于持久化。
  ///
  /// 路径不在当前根下时返回 null —— 调用方应保留原值（不要意外清空 DB 列）。
  /// 已经是相对路径直接返回。
  static String? toRelative(String? path) {
    if (path == null || path.isEmpty) {
      return null;
    }
    if (p.isRelative(path)) {
      return path;
    }
    final root = supportRoot;
    final normalizedPath = p.normalize(path);
    final normalizedRoot = p.normalize(root);
    final workspace = p.normalize(fileWorkspaceRoot);
    if (p.isWithin(workspace, normalizedPath)) {
      return p.posix.join(
        'file_workspaces',
        p.posix.joinAll(p.split(p.relative(normalizedPath, from: workspace))),
      );
    }
    if (p.isWithin(normalizedRoot, normalizedPath)) {
      return p.posix.joinAll(
        p.split(p.relative(normalizedPath, from: normalizedRoot)),
      );
    }
    return null;
  }
}
