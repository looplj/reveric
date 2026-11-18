// 职责: 检查输入依赖与审批期间的变化，解析原文件路径并仅为 probe 保留会话副本。
// 关联文件:
//   lib/shared/services/ai/ffmpeg/arguments.dart
//   lib/shared/services/ai/ffmpeg/filters.dart
//   lib/shared/services/ai/files/session_files.dart
//   lib/shared/services/production/ffmpeg_runner.dart
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../../models/tool_permission.dart';
import '../../production/bundled_font.dart';
import '../../production/ffmpeg_runner.dart';
import '../files/session_files.dart';
import '../files/command_paths.dart';
import 'arguments.dart';
import 'filters.dart';
import 'sequence.dart';

class FfmpegInputs {
  FfmpegInputs._(this.files, this.parsed);
  final SessionFiles files;
  final FfmpegArguments parsed;
  final _paths = <String>{};
  Set<String> get paths => Set.unmodifiable(_paths);
  late final Map<String, ({String resolved, int size, DateTime modified})>
  identities;
  final _observed =
      <String, ({String resolved, int size, DateTime modified})>{};
  final _sequenceStarts = <int, String>{};
  final _authorized = <String>{};
  final _authorizedIdentities =
      <String, (String, FileSystemEntityType, int, DateTime, DateTime)>{};
  Future<void> Function(List<String> paths)? _authorizeExternal;
  CommandPaths get _commands => CommandPaths(files);

  Future<void> _authorize(Iterable<String> paths) async {
    for (final path in paths.where(_authorized.contains)) {
      if (await _accessIdentity(path) != _authorizedIdentities[path]) {
        throw const ToolOperationException(
          'conflict',
          'An authorized input changed during dependency inspection. Try again.',
        );
      }
    }
    final pending = paths
        .where(
          (path) =>
              CommandPaths.isAbsolute(path) && !_authorized.contains(path),
        )
        .toSet()
        .toList();
    if (pending.isEmpty) {
      return;
    }
    final before = {
      for (final path in pending) path: await _accessIdentity(path),
    };
    await _authorizeExternal?.call(pending);
    for (final path in pending) {
      if (before[path] != await _accessIdentity(path)) {
        throw const ToolOperationException(
          'conflict',
          'An input changed during approval. Try again.',
        );
      }
    }
    _authorized.addAll(pending);
    _authorizedIdentities.addAll(before);
  }

  Future<(String, FileSystemEntityType, int, DateTime, DateTime)>
  _accessIdentity(String path) async {
    final syntax = p.Context(
      style: path.contains(r'\') ? p.Style.windows : p.Style.posix,
    );
    final target = FfmpegSequence.hasPlaceholder(path)
        ? syntax.dirname(path)
        : path;
    final resolved = await File(target).resolveSymbolicLinks();
    final stat = await FileStat.stat(resolved);
    return (resolved, stat.type, stat.size, stat.modified, stat.changed);
  }

  static Future<FfmpegInputs> inspect(
    SessionFiles files,
    FfmpegArguments parsed, {
    Future<void> Function(List<String> paths)? authorizeExternal,
  }) async {
    final plan = FfmpegInputs._(files, parsed)
      .._authorizeExternal = authorizeExternal;
    final direct = {
      ...parsed.inputs.values,
      ...parsed.fileInputs.values,
      for (final graph in parsed.graphs.values) ...graph.dependencies,
    };
    for (final path in direct) {
      plan._commands.absolute(path);
      if (!CommandPaths.isAbsolute(path)) {
        await plan._commands.checkRelative(path);
      }
    }
    // External lists and sequence directories must be approved before inspection.
    await plan._authorize(direct);
    for (final path in direct.where(
      (path) => !FfmpegSequence.hasPlaceholder(path),
    )) {
      plan._observed[path] = await plan._identity(path);
    }
    plan._paths.addAll(parsed.fileInputs.values);
    for (final entry in parsed.inputs.entries) {
      if (FfmpegSequence.hasPlaceholder(entry.value)) {
        if (parsed.probe ||
            (parsed.inputFormats[entry.key] != null &&
                parsed.inputFormats[entry.key] != 'image2')) {
          throw const FormatException('Sequence inputs require image2.');
        }
        await plan._sequence(entry.key, entry.value);
      } else {
        plan._paths.add(entry.value);
        if (parsed.inputFormats[entry.key] == 'concat') {
          await plan._list(entry.value);
        }
      }
    }
    for (final graph in parsed.graphs.values) {
      plan._paths.addAll(graph.dependencies);
    }
    if (plan._paths.length > ffmpegMaxInputFiles) {
      throw const ToolOperationException(
        'resource_exhausted',
        'Input dependencies exceed 4096 files.',
      );
    }
    plan.identities = Map.unmodifiable({
      for (final path in plan._paths)
        path: plan._observed[path] ?? await plan._identity(path),
    });
    return plan;
  }

  Future<({String resolved, int size, DateTime modified})> _identity(
    String path,
  ) async {
    final file = await _commands.resolve(path);
    final stat = await file.stat();
    return (resolved: file.path, size: stat.size, modified: stat.modified);
  }

  Future<void> verify() async {
    // Check the original targets before reopening lists or enumerating sequences.
    for (final entry in _authorizedIdentities.entries) {
      if (await _accessIdentity(entry.key) != entry.value) {
        throw const ToolOperationException(
          'conflict',
          'An authorized input target changed before execution. Try again.',
        );
      }
    }
    for (final entry in identities.entries) {
      if (await _identity(entry.key) != entry.value) {
        throw const ToolOperationException(
          'conflict',
          'An input changed before execution. Try again.',
        );
      }
    }
    final current = await inspect(
      files,
      parsed,
      authorizeExternal: (paths) async {
        if (paths.any((path) => !_authorized.contains(path))) {
          throw const ToolOperationException(
            'conflict',
            'Input dependencies changed after approval. Try again.',
          );
        }
      },
    );
    if (current.identities.length != identities.length ||
        identities.entries.any(
          (entry) => current.identities[entry.key] != entry.value,
        )) {
      throw const ToolOperationException(
        'conflict',
        'An input changed before execution. Try again.',
      );
    }
  }

  Future<void> _sequence(int index, String pattern) async {
    await _authorize([pattern]);
    final syntax = p.Context(
      style: pattern.contains(r'\') ? p.Style.windows : p.Style.posix,
    );
    final name = syntax.basename(pattern);
    final matches = RegExp(r'%(?:0([1-9]))?d').allMatches(name).toList();
    if (matches.length != 1 ||
        FfmpegSequence.hasPlaceholder(syntax.dirname(pattern))) {
      throw const FormatException('Use one %d or %0Nd in the input filename.');
    }
    final match = matches.single;
    final width = int.parse(match.group(1) ?? '0');
    final regex = RegExp(
      '^${RegExp.escape(name.substring(0, match.start))}'
      '(\\d{${width == 0 ? 1 : width},})'
      '${RegExp.escape(name.substring(match.end))}\$',
    );
    if (syntax.isRelative(pattern) && syntax.split(pattern).contains('..')) {
      throw const FormatException('Invalid relative sequence path.');
    }
    final parent = syntax.dirname(pattern);
    if (!CommandPaths.isAbsolute(pattern)) {
      await _commands.checkRelative(parent);
    }
    final directory = Directory(_commands.absolute(parent));
    final found = <int, String>{};
    await for (final entity in directory.list(followLinks: false)) {
      final m = regex.firstMatch(p.basename(entity.path));
      if (m == null) {
        continue;
      }
      final number = int.tryParse(m.group(1)!);
      if (number == null || number > 2147483647 || entity is! File) {
        throw const FormatException('Invalid sequence entry.');
      }
      final canonical = pattern.replaceFirst(
        match.group(0)!,
        '$number'.padLeft(width, '0'),
      );
      if (syntax.basename(canonical) != p.basename(entity.path)) {
        throw const FormatException('Ambiguous sequence numbering.');
      }
      found[number] = CommandPaths.isAbsolute(pattern)
          ? entity.path
          : _commands.reference(File(entity.path));
      if (found.length > ffmpegMaxInputFiles) {
        throw const ToolOperationException(
          'resource_exhausted',
          'Image sequence exceeds 4096 input files.',
        );
      }
    }
    final first =
        parsed.inputStarts[index] ??
        (found.keys.where((n) => n >= 0 && n < 5).toList()..sort()).firstOrNull;
    if (first == null || !found.containsKey(first)) {
      throw const FormatException('No image at the requested sequence start.');
    }
    final numbers = found.keys.where((n) => n >= first).toList()..sort();
    for (var i = 0; i < numbers.length; i++) {
      if (numbers[i] != first + i) {
        throw const FormatException('Input image sequence contains a gap.');
      }
    }
    _sequenceStarts[index] = found[first]!;
    for (final n in numbers) {
      final path = found[n]!;
      _paths.add(path);
      _observed[path] = await _identity(path);
    }
  }

  Future<void> _list(String path) async {
    await _authorize([path]);
    final file = await _commands.resolve(path);
    if (await file.length() > ffmpegMaxArgumentBytes) {
      throw const ToolOperationException(
        'resource_exhausted',
        'Concat list exceeds 256 KiB.',
      );
    }
    var lineCount = 0, fileCount = 0;
    final children = <String>[];
    for (final raw in await file.readAsLines()) {
      final line = raw.trim();
      if (line.isEmpty ||
          line.startsWith('#') ||
          line == 'ffconcat version 1.0') {
        continue;
      }
      final match = RegExp(r'^(\S+)\s+(.+)$').firstMatch(line);
      if (match == null) {
        throw const FormatException('Invalid concat directive.');
      }
      final key = match.group(1)!, value = match.group(2)!;
      if (key == 'file') {
        final reference = ffmpegUnquote(value);
        FfmpegArguments.localPath(reference);
        if (FfmpegSequence.hasPlaceholder(reference)) {
          throw const FormatException(
            'Concat entries must be individual files.',
          );
        }
        final explicitAbsolute = CommandPaths.isAbsolute(reference);
        final syntax = p.Context(
          style: reference.contains(r'\') ? p.Style.windows : p.Style.posix,
        );
        final resolved = explicitAbsolute
            ? reference
            : p.normalize(
                p.join(file.parent.path, p.joinAll(syntax.split(reference))),
              );
        final String childPath;
        if (!CommandPaths.isAbsolute(path) && !explicitAbsolute) {
          if (!p.isWithin(_commands.root, resolved)) {
            throw const FormatException(
              'Concat relative entries cannot escape the current work.',
            );
          }
          childPath = _commands.reference(File(resolved));
          await _commands.checkRelative(childPath);
        } else {
          childPath = resolved;
        }
        children.add(childPath);
        fileCount++;
      } else if ({'duration', 'inpoint', 'outpoint'}.contains(key) &&
          RegExp(r'^-?(?:\d+:){0,2}\d+(?:\.\d+)?$').hasMatch(value)) {
        if (fileCount == 0) {
          throw const FormatException('Concat timing must follow a file.');
        }
      } else {
        throw const ToolOperationException(
          'unsupported',
          'Concat supports file, duration, inpoint and outpoint directives.',
        );
      }
      if (++lineCount > ffmpegMaxInputFiles * 4 ||
          fileCount > ffmpegMaxInputFiles) {
        throw const ToolOperationException(
          'resource_exhausted',
          'Concat list is too large.',
        );
      }
    }
    if (fileCount == 0) {
      throw const FormatException('Concat list contains no files.');
    }
    await _authorize(children);
    for (final path in children) {
      // Nested lists could introduce undeclared dependencies during native execution.
      final child = await _commands.resolve(path);
      final handle = await child.open();
      try {
        final prefix = String.fromCharCodes(await handle.read(20));
        if (prefix.startsWith('ffconcat version 1.0')) {
          throw const ToolOperationException(
            'unsupported',
            'Nested concat inputs are not supported.',
          );
        }
      } finally {
        await handle.close();
      }
      _paths.add(path);
    }
  }

  Future<void> resolveArguments(
    String sessionId,
    List<String> actual,
    MediaCancellation cancellation,
  ) async {
    void check() {
      if (cancellation.cancelled) {
        throw const ToolOperationException(
          'cancelled',
          'Input preparation was cancelled.',
        );
      }
    }

    for (final entry in parsed.inputs.entries) {
      check();
      if (_sequenceStarts[entry.key] case final first?) {
        final syntax = p.Context(
          style: entry.value.contains(r'\') ? p.Style.windows : p.Style.posix,
        );
        actual[entry.key] = p.join(
          p.dirname(identities[first]!.resolved),
          syntax.basename(entry.value),
        );
      } else {
        final source = File(identities[entry.value]!.resolved);
        final input = parsed.probe
            ? await files.copy(
                sessionId,
                source,
                cancelled: () => cancellation.cancelled,
              )
            : source;
        actual[entry.key] = input.path;
      }
    }
    final font = parsed.graphs.values.any((graph) => graph.usesDefaultFont)
        ? await bundledFontFile()
        : null;
    for (final graph in parsed.graphs.entries) {
      actual[graph.key] = graph.value.rewrite({
        for (final path in graph.value.dependencies)
          path: identities[path]!.resolved,
      }, defaultFont: font);
    }
    for (final entry in parsed.fileInputs.entries) {
      actual[entry.key] = identities[entry.value]!.resolved;
    }
    check();
  }
}
