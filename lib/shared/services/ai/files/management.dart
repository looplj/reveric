// 职责: 在管控目录内按 glob 列举文件，冻结删除范围并校验后清理匹配项。
// 关联文件:
//   lib/shared/services/ai/tools_run.dart
//   lib/shared/services/ai/files/session_files.dart
//   lib/shared/models/tool_permission.dart
import 'dart:io';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import '../../../logger/app_logger.dart';
import '../../../models/tool_permission.dart';
import '../../../utils/storage_paths.dart';
import 'session_files.dart';
import 'command_paths.dart';

final _log = AppLogger.forModule('Files');

typedef _Identity = ({
  String resolved,
  FileSystemEntityType type,
  int size,
  DateTime modified,
  DateTime changed,
  int mode,
});

class ManagedFiles {
  ManagedFiles(this.files, this.sessionId, {this._external = false})
    : _root = CommandPaths(files).root {
    SessionFiles.validateId(sessionId);
  }
  final bool _external;
  final SessionFiles files;
  final String sessionId;
  static const maxMatches = 4096;
  static const maxVisited = 16384;
  static final _magic = RegExp(r'[*?\[\]{}]');

  static p.Context _absoluteSyntax(String path) => path.startsWith('//')
      ? p.windows
      : RevericPaths.contextForStoredPath(path);

  static String nativeAbsolute(String path) {
    final syntax = _absoluteSyntax(path);
    final native = syntax.style == p.Style.windows
        ? path.replaceAll('/', r'\')
        : path;
    if (!syntax.isAbsolute(native)) {
      throw const FormatException('An absolute path is required.');
    }
    return syntax.normalize(native);
  }

  static String portableAbsolute(String path) {
    final syntax = _absoluteSyntax(path);
    final native = nativeAbsolute(path);
    return syntax.style == p.Style.windows
        ? native.replaceAll(r'\', '/')
        : native;
  }

  String _validate(String path) {
    if (path.isEmpty ||
        path.length > 1024 ||
        path.contains('\u0000') ||
        path.contains('://') ||
        RegExp(r'(^|[/\\,{])\.\.([/\\},]|$)').hasMatch(path)) {
      throw const FormatException('Use a local path without .. segments.');
    }
    if (_external) {
      if (!CommandPaths.isAbsolute(path)) {
        throw const FormatException(
          'External listings require an absolute path.',
        );
      }
      return portableAbsolute(path);
    }
    final target = CommandPaths(files).absolute(path, write: true);
    if (path.contains('\\') || path.contains(':')) {
      throw const FormatException(
        'Use / separators in work-relative selectors.',
      );
    }
    final normalized = path.endsWith('/') && path != '/'
        ? path.substring(0, path.length - 1)
        : path;
    if (normalized == '.') {
      return normalized;
    }
    if (normalized
        .split('/')
        .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException(
        'Empty, . and .. path segments are not allowed.',
      );
    }
    return p.posix.joinAll(p.split(p.relative(target, from: _root)));
  }

  final String _root;
  String _absolute(String path) => _external
      ? nativeAbsolute(path)
      : p.join(_root, p.joinAll(path.split('/')));
  String _reference(String absolute) => _external
      ? portableAbsolute(absolute)
      : p.posix.joinAll(p.split(p.relative(absolute, from: _root)));
  bool _protected(String path) => path == '.';

  Future<void> _checkDirectory(String relative) async {
    if (!_external) {
      try {
        await CommandPaths(
          files,
        ).checkRelative(relative.isEmpty ? '.' : relative);
      } on FormatException catch (error) {
        throw ToolOperationException(
          'invalid_argument',
          error.message.toString(),
        );
      }
    }
    final type = await FileSystemEntity.type(_absolute(relative));
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const ToolOperationException(
        'invalid_argument',
        'Directory paths must refer to directories.',
      );
    }
  }

  Future<_Identity> _identity(String relative) async {
    final parent = p.posix.dirname(relative);
    if (parent != '.') {
      await _checkDirectory(parent);
    }
    final absolute = _absolute(relative);
    final type = await FileSystemEntity.type(absolute, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const ToolOperationException(
        'invalid_argument',
        'Symbolic links cannot be selected.',
      );
    }
    final resolved = await File(absolute).resolveSymbolicLinks();
    final stat = await File(resolved).stat();
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      throw const ToolOperationException(
        'conflict',
        'A selected file is no longer available. List the directory again.',
      );
    }
    if (type == FileSystemEntityType.directory) {
      await _checkDirectory(relative);
    }
    return (
      resolved: resolved,
      type: type,
      size: stat.size,
      modified: stat.modified,
      changed: stat.changed,
      mode: stat.mode,
    );
  }

  /// Freeze the directory before approval without enumerating its contents.
  Future<Future<void> Function()> freezeExternal(String requested) async {
    final external = ManagedFiles(files, sessionId, external: true);
    final path = external._validate(requested);
    final parts = path.split('/');
    final firstMagic = parts.indexWhere(_magic.hasMatch);
    final target = firstMagic < 0
        ? external._absolute(path)
        : external._absolute('${parts.take(firstMagic).join('/')}/');
    Future<(String, FileSystemEntityType, int, DateTime, DateTime)>
    identity() async {
      final resolved = await File(target).resolveSymbolicLinks();
      final stat = await FileStat.stat(resolved);
      return (resolved, stat.type, stat.size, stat.modified, stat.changed);
    }

    final before = await identity();
    return () async {
      if (await identity() != before) {
        throw const ToolOperationException(
          'conflict',
          'The listing target changed during approval. Try again.',
        );
      }
    };
  }

  Future<ManagedFileSelection> select(
    String requested, {
    required bool remove,
    bool recursive = false,
  }) async {
    if (remove && (_external || CommandPaths.isAbsolute(requested))) {
      throw const FormatException('Removal requires a work-relative path.');
    }
    if (CommandPaths.isAbsolute(requested) && !_external) {
      return ManagedFiles(
        files,
        sessionId,
        external: true,
      ).select(requested, remove: false, recursive: recursive);
    }
    try {
      final path = _validate(requested);
      if (remove && _protected(path)) {
        throw const ToolOperationException(
          'invalid_argument',
          'The work root cannot be removed.',
        );
      }
      if (!_external) {
        await _checkDirectory('.');
      }
      final matches = <String, _Identity>{};
      final visited = <String>{};
      void count(String path) {
        visited.add(path);
        if (visited.length > maxVisited) {
          throw const ToolOperationException(
            'resource_exhausted',
            'Directory scan exceeds 16384 entries. Use a narrower path.',
          );
        }
      }

      Future<void> add(String relative) async {
        if (matches.containsKey(relative)) {
          return;
        }
        if (matches.length >= maxMatches) {
          throw const ToolOperationException(
            'resource_exhausted',
            'More than 4096 entries matched. Use a narrower pattern.',
          );
        }
        final identity = await _identity(relative);
        if (remove && _protected(relative)) {
          throw const ToolOperationException(
            'invalid_argument',
            'Managed root directories cannot be removed.',
          );
        }
        if (remove &&
            identity.type == FileSystemEntityType.directory &&
            !recursive) {
          throw const ToolOperationException(
            'failed_precondition',
            'Removing directories requires recursive=true.',
          );
        }
        matches[relative] = identity;
      }

      Stream<FileSystemEntity> walk(String relative, bool deep) async* {
        await _checkDirectory(relative);
        final directory = Directory(_absolute(relative));
        if (!await directory.exists()) {
          return;
        }
        await for (final entry in directory.list(followLinks: false)) {
          count(entry.path);
          yield entry;
          if (deep && entry is Directory) {
            yield* walk(_reference(entry.path), true);
          }
        }
      }

      if (!_magic.hasMatch(path)) {
        final parent = p.posix.dirname(path);
        if (parent != '.') {
          await _checkDirectory(parent);
        }
        final type = await FileSystemEntity.type(
          _absolute(path),
          followLinks: false,
        );
        if (type == FileSystemEntityType.notFound) {
          return ManagedFileSelection._(this, path, remove, recursive, matches);
        }
        if (type == FileSystemEntityType.directory && !remove) {
          await for (final entry in walk(path, recursive)) {
            if (entry is! Link) {
              await add(_reference(entry.path));
            }
          }
        } else {
          await add(path);
        }
      } else {
        final glob = Glob(
          path,
          context: _external ? _absoluteSyntax(path) : p.posix,
          caseSensitive: !Platform.isWindows,
        );
        final parts = path.split('/');
        final firstMagic = parts.indexWhere(_magic.hasMatch);
        final prefix = parts.take(firstMagic).join('/');
        final base = _external ? '$prefix/' : (prefix.isEmpty ? '.' : prefix);
        final deep = path.contains('**') || parts.length - firstMagic > 1;
        await for (final entry in walk(base, deep)) {
          final relative = _reference(entry.path);
          if (glob.matches(_external ? nativeAbsolute(relative) : relative)) {
            await add(relative);
          }
        }
      }
      if (recursive && (remove || _magic.hasMatch(path))) {
        final directories = matches.entries
            .where(
              (entry) => entry.value.type == FileSystemEntityType.directory,
            )
            .map((entry) => entry.key)
            .toList();
        for (final directory in directories) {
          if (directories.any((other) => p.posix.isWithin(other, directory))) {
            continue;
          }
          await for (final child in walk(directory, true)) {
            if (!remove && child is Link) {
              continue;
            }
            await add(_reference(child.path));
          }
        }
      }
      return ManagedFileSelection._(this, path, remove, recursive, matches);
    } on FileSystemException catch (error, stack) {
      _log.error(
        'selection failed type=${error.runtimeType}',
        error: error.osError,
        stackTrace: stack,
      );
      throw ToolOperationException('unavailable', error.toString());
    }
  }
}

class ManagedFileSelection {
  ManagedFileSelection._(
    this.owner,
    this.path,
    this.removing,
    this.recursive,
    Map<String, _Identity> entries,
  ) : _entries = Map.unmodifiable(entries);
  final ManagedFiles owner;
  final String path;
  final bool removing, recursive;
  final Map<String, _Identity> _entries;
  List<String> get paths => _entries.keys.toList()..sort();

  /// Entry counts per folder for approval display: entries under a selected
  /// directory count toward its topmost selected ancestor, others toward their
  /// parent folder.
  Map<String, int> get folderCounts {
    final directories = {
      for (final entry in _entries.entries)
        if (entry.value.type == FileSystemEntityType.directory) entry.key,
    };
    final counts = <String, int>{};
    for (final path in paths) {
      final parts = path.split('/');
      var folder = p.posix.dirname(path);
      for (var i = 1; i <= parts.length; i++) {
        final prefix = parts.take(i).join('/');
        if (directories.contains(prefix)) {
          folder = prefix;
          break;
        }
      }
      counts.update(folder, (count) => count + 1, ifAbsent: () => 1);
    }
    return Map.fromEntries(
      counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  Future<void> verify() async {
    final current = await owner.select(
      path,
      remove: removing,
      recursive: recursive,
    );
    if (current._entries.length != _entries.length ||
        _entries.entries.any(
          (entry) => current._entries[entry.key] != entry.value,
        )) {
      throw const ToolOperationException(
        'conflict',
        'The matched files changed before execution. List the directory and retry.',
      );
    }
  }

  Map<String, dynamic> listing({int offset = 0, int limit = 200}) {
    final ordered = paths;
    String displayPath(String path) {
      if (!owner._external) {
        return path;
      }
      final resolved = _entries[path]!.resolved;
      if (p.equals(owner._root, resolved) ||
          p.isWithin(owner._root, resolved)) {
        return p.posix.joinAll(
          p.split(p.relative(resolved, from: owner._root)),
        );
      }
      return path;
    }

    return {
      'ok': true,
      'path': path,
      'entries': [
        for (final path in ordered.skip(offset).take(limit))
          {
            'path': displayPath(path),
            'type': _entries[path]!.type == FileSystemEntityType.directory
                ? 'directory'
                : 'file',
            if (_entries[path]!.type == FileSystemEntityType.file)
              'bytes': _entries[path]!.size,
            'modified_at': _entries[path]!.modified.toUtc().toIso8601String(),
          },
      ],
      'total': ordered.length,
      if (offset + limit < ordered.length) 'next_offset': offset + limit,
    };
  }

  Future<Map<String, dynamic>> remove({
    required bool Function() cancelled,
  }) async {
    if (!removing) {
      throw StateError('A listing cannot be used as a removal plan.');
    }
    await verify();
    final ordered = paths
      ..sort((a, b) {
        final depth = b.split('/').length.compareTo(a.split('/').length);
        return depth == 0 ? a.compareTo(b) : depth;
      });
    final removed = <String>[];
    _log.info('removal started entries=${ordered.length}');
    try {
      for (final path in ordered) {
        if (cancelled()) {
          throw const ToolOperationException(
            'cancelled',
            'File removal was cancelled.',
          );
        }
        final current = await owner._identity(path);
        final original = _entries[path]!;
        if (current.type != original.type ||
            (current.type == FileSystemEntityType.file &&
                current != original)) {
          throw const ToolOperationException(
            'conflict',
            'A selected file changed during removal.',
          );
        }
        final absolute = owner._absolute(path);
        if (current.type == FileSystemEntityType.directory) {
          // Never recursively delete newly created files that were not approved.
          await Directory(absolute).delete();
        } else {
          await File(absolute).delete();
        }
        removed.add(path);
      }
      _log.info('removal completed entries=${removed.length}');
      return {'ok': true, 'removed': removed};
    } catch (error, stack) {
      _log.error(
        'removal failed removed=${removed.length} type=${error.runtimeType}',
        error: error is ToolOperationException
            ? error.code
            : error is FileSystemException
            ? error.osError
            : error,
        stackTrace: stack,
      );
      return {
        'ok': false,
        'error_code': error is ToolOperationException
            ? error.code
            : 'unavailable',
        'error': error is ToolOperationException
            ? error.message
            : error.toString(),
        if (cancelled()) 'cancelled': true,
        'removed': removed,
        'remaining': ordered.where((path) => !removed.contains(path)).toList(),
      };
    }
  }
}
