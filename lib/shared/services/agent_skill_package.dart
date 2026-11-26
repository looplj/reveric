// 职责: 定义技能包的导入路径、文件限额和流式复制规则。
// 关联文件:
//   lib/shared/services/agent_skill_transfer.dart
//   lib/shared/services/agent_skill_import_orchestrator.dart
//   lib/shared/services/agent_skill_file_store.dart
//   lib/mobile/services/android_saf_directory_import.dart

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../models/agent_skill_reference.dart';
import '../utils/storage_paths.dart';

const agentSkillMarkdownName = 'SKILL.md';
const agentSkillMaxMarkdownBytes = 1024 * 1024;
const agentSkillMaxPackageBytes = 128 * 1024 * 1024;
const agentSkillMaxPackageFiles = 5000;
const agentSkillMaxScanEntries = 20000;
const agentSkillMaxCandidates = 500;
const agentSkillMaxScanMarkdownBytes = 32 * 1024 * 1024;
const agentSkillIgnoredDirectories = {
  'node_modules',
  '__pycache__',
  '__macosx',
};
const agentSkillScriptExtensions = {
  '.py',
  '.js',
  '.mjs',
  '.cjs',
  '.ts',
  '.sh',
  '.bash',
  '.zsh',
  '.ps1',
  '.bat',
  '.cmd',
  '.rb',
  '.pl',
  '.lua',
  '.dart',
};

class AgentSkillImportLimitException implements Exception {
  const AgentSkillImportLimitException();
}

final _unsafeSegment = RegExp(r'[\\:<>"|?*\x00-\x1f]');
final _reservedName = RegExp(
  r'^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)',
  caseSensitive: false,
);

bool isPortableSkillPathSegment(String part) =>
    part.isNotEmpty &&
    !part.startsWith('.') &&
    !part.endsWith('.') &&
    !part.endsWith(' ') &&
    !_unsafeSegment.hasMatch(part) &&
    !_reservedName.hasMatch(part);

bool isAgentSkillRootMarkdown(String path) =>
    path.toLowerCase() == agentSkillMarkdownName.toLowerCase();

bool isAgentSkillTextReference(String path) =>
    path.startsWith(AgentSkillReferences.relativeDirPrefix) &&
    AgentSkillReferences.isValidRelativePath(path);

Future<Directory?> findAgentSkillReferenceDirectory(Directory package) async {
  final references = Directory(
    p.join(package.path, AgentSkillReferences.relativeDir),
  );
  await RevericPaths.requireNoLinks(package, references.path);
  if (!await references.exists()) {
    return null;
  }
  // Case-insensitive volumes also match a directory such as "References".
  await for (final entry in package.list(followLinks: false)) {
    if (entry is Directory &&
        p.basename(entry.path) == AgentSkillReferences.relativeDir) {
      return entry;
    }
  }
  return null;
}

bool isAgentSkillResourcePath(String path) =>
    !isAgentSkillRootMarkdown(path) &&
    !isAgentSkillTextReference(path) &&
    path.split('/').every(isPortableSkillPathSegment);

/// This excludes generated directories during import. Installed packages can
/// contain files written by prior versions and must round-trip as installed.
bool isAgentSkillImportFile(String path) {
  final parts = path.split('/');
  return parts.every(isPortableSkillPathSegment) &&
      !parts
          .take(parts.length - 1)
          .any(
            (part) => agentSkillIgnoredDirectories.contains(part.toLowerCase()),
          );
}

Stream<({String path, File file})> agentSkillPackageFiles(
  Directory root, {
  bool importing = false,
}) async* {
  Stream<({String path, File file})> visit(
    Directory directory,
    String prefix,
  ) async* {
    await for (final entry in directory.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (!isPortableSkillPathSegment(name)) {
        continue;
      }
      final path = prefix.isEmpty ? name : '$prefix/$name';
      if (entry is Directory) {
        if (!importing ||
            !agentSkillIgnoredDirectories.contains(name.toLowerCase())) {
          yield* visit(entry, path);
        }
      } else if (entry is File &&
          !isAgentSkillRootMarkdown(path) &&
          (importing || !isAgentSkillTextReference(path))) {
        yield (path: path, file: entry);
      }
    }
  }

  yield* visit(root, '');
}

/// Writes a single selected package into a fresh app-owned temporary directory.
class AgentSkillPackageWriter {
  AgentSkillPackageWriter(this.directory);

  final Directory directory;
  final _paths = <String>{};
  var _bytes = 0;
  var _referenceCount = 0;
  var _referenceBytes = 0;

  Future<void> copyFrom(File markdown, {required Directory sourceRoot}) async {
    await RevericPaths.requireNoLinks(sourceRoot, markdown.path);
    await addStream(
      agentSkillMarkdownName,
      markdown.openRead(),
      size: await markdown.length(),
    );
    await for (final entry in agentSkillPackageFiles(
      markdown.parent,
      importing: true,
    )) {
      await RevericPaths.requireNoLinks(sourceRoot, entry.file.path);
      await addStream(
        entry.path,
        entry.file.openRead(),
        size: await entry.file.length(),
      );
    }
  }

  Future<void> addStream(String path, Stream<List<int>> bytes, {int? size}) =>
      write(path, size: size, (file, limit) async {
        final handle = await file.open(mode: FileMode.writeOnly);
        try {
          var written = 0;
          await for (final chunk in bytes) {
            written += chunk.length;
            if (written > limit) {
              throw const AgentSkillImportLimitException();
            }
            await handle.writeFrom(chunk);
          }
        } finally {
          await handle.close();
        }
      });

  Future<void> write(
    String path,
    Future<void> Function(File file, int limit) copy, {
    int? size,
  }) async {
    if (!isAgentSkillImportFile(path) || !_paths.add(path.toLowerCase())) {
      throw FormatException('Invalid or conflicting skill package path', path);
    }
    if (_paths.length > agentSkillMaxPackageFiles) {
      throw const AgentSkillImportLimitException();
    }
    var limit = agentSkillMaxPackageBytes - _bytes;
    if (path == agentSkillMarkdownName) {
      limit = min(limit, agentSkillMaxMarkdownBytes);
    }
    final reference = isAgentSkillTextReference(path);
    if (reference) {
      _referenceCount++;
      if (_referenceCount > AgentSkillReferences.maxCount) {
        throw const AgentSkillImportLimitException();
      }
      limit = min(limit, AgentSkillReferences.maxContentBytes);
      limit = min(
        limit,
        AgentSkillReferences.maxTotalContentBytes - _referenceBytes,
      );
    }
    if (size != null && size > limit) {
      throw const AgentSkillImportLimitException();
    }
    final file = File(p.joinAll([directory.path, ...path.split('/')]));
    await file.parent.create(recursive: true);
    await file.create(exclusive: true);
    await copy(file, limit);
    final length = await file.length();
    if (length > limit || (size != null && size != length)) {
      throw const FormatException('Skill package file changed during import');
    }
    _bytes += length;
    if (reference) {
      _referenceBytes += length;
    }
  }
}
