// 职责: AgentSkill 批量导入/导出 — 按 Agent Skills 规范处理 skill 目录（含 SKILL.md）。
//   导入：递归扫描文件夹内 SKILL.md，由调用方勾选后写入应用全局已安装技能。
//   导出：每个技能一个子目录 + SKILL.md，或打成 ZIP。
// 关联文件:
//   lib/shared/services/agent_skill_import_parser.dart
//   lib/shared/models/novel_agent_skill.dart
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/logger/app_logger.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md

import 'dart:io';
import 'dart:convert';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../logger/app_logger.dart';
import '../models/agent_skill_reference.dart';
import '../models/novel_agent_skill.dart';
import '../providers/novel_agent_skill_providers.dart';
import '../utils/storage_paths.dart';
import 'agent_skill_import_parser.dart';
import 'agent_skill_package.dart';

final _log = AppLogger.forModule('AgentSkillTransfer');

/// 扫描到的可导入技能候选（尚未写入库）。
class AgentSkillImportCandidate {
  const AgentSkillImportCandidate({
    required this.filePath,
    required this.parsed,
    required this.nameConflict,
    this.hasScripts = false,
    this.materialize,
  });

  final String filePath;
  final AgentSkillImportParseResult parsed;
  final bool nameConflict;
  final bool hasScripts;
  final Future<void> Function(Directory destination)? materialize;

  String get name => parsed.name;
  String get description => parsed.description;
  String get category => parsed.category;
}

/// 只检测脚本资源是否存在，不读取或执行脚本。
bool agentSkillHasScripts(Iterable<String> paths) => paths.any((path) {
  final parts = path.replaceAll('\\', '/').split('/');
  return parts.contains('scripts') ||
      agentSkillScriptExtensions.contains(
        p.posix.extension(path).toLowerCase(),
      );
});

enum AgentSkillImportFailureReason { too_large, unavailable, invalid, failed }

typedef AgentSkillImportFailure = ({
  String name,
  AgentSkillImportFailureReason reason,
});

/// 批量导入结果。
class AgentSkillImportResult {
  const AgentSkillImportResult({
    required this.imported,
    required this.skipped,
    required this.failed,
    this.skippedNames = const [],
    this.failedFiles = const [],
    this.failures = const [],
  });

  final int imported;
  final int skipped;
  final int failed;
  final List<String> skippedNames;
  final List<String> failedFiles;
  final List<AgentSkillImportFailure> failures;

  int get total => imported + skipped + failed;
}

/// 描述一个待写出的文件。包资源始终从本地文件逐个读取。
class AgentSkillTransferFile {
  const AgentSkillTransferFile({
    required this.relativePath,
    required this.content,
  }) : source = null;

  const AgentSkillTransferFile.resource({
    required this.relativePath,
    required this.source,
  }) : content = '';

  final String relativePath;
  final String content;
  final File? source;
}

/// AgentSkill 批量导入/导出服务。
///
/// 布局（Agent Skills 规范）:
/// ```
/// <dir>/
///   <skill-name>/
///     SKILL.md
///     references/   # optional
///       foo.md
/// ```
class AgentSkillTransferService {
  const AgentSkillTransferService({
    this.temporaryDirectory = getTemporaryDirectory,
  });

  final Future<Directory> Function() temporaryDirectory;

  static const skillMarkdownFileName = agentSkillMarkdownName;
  static const referencesDirName = AgentSkillReferences.relativeDir;

  /// 读取系统选择器提供的内容，不将移动端 URI 当作普通文件路径。
  AgentSkillImportCandidate parseSelectedMarkdown({
    required String content,
    required String fileName,
    required List<NovelAgentSkillModel> existing,
    bool hasScripts = false,
    Future<void> Function(Directory)? materialize,
  }) {
    final parsed = AgentSkillImportParser.parse(content);
    if (parsed == null) {
      throw const FormatException('Invalid skill Markdown frontmatter');
    }
    return AgentSkillImportCandidate(
      filePath: fileName,
      parsed: parsed,
      hasScripts: hasScripts,
      materialize: materialize,
      nameConflict: existing.any(
        (entry) => entry.name.trim() == parsed.name.trim(),
      ),
    );
  }

  /// Scans candidate markdown only. Resource reads begin on confirmation.
  Future<List<AgentSkillImportCandidate>> discoverInDirectory({
    required String dirPath,
    required List<NovelAgentSkillModel> existing,
  }) async {
    final root = Directory(await Directory(dirPath).resolveSymbolicLinks());
    final markdown = <File>[];
    final directoriesWithScripts = <String>{};
    var entries = 0;
    Future<void> visit(Directory parent) async {
      await for (final entry in parent.list(followLinks: false)) {
        if (++entries > agentSkillMaxScanEntries) {
          throw const AgentSkillImportLimitException();
        }
        final name = p.basename(entry.path);
        if (entry is Directory) {
          final lowerName = name.toLowerCase();
          if (lowerName == 'scripts') {
            directoriesWithScripts.add(parent.path);
          }
          if (!lowerName.startsWith('.') &&
              !agentSkillIgnoredDirectories.contains(lowerName) &&
              !{referencesDirName, 'scripts', 'assets'}.contains(lowerName)) {
            await visit(entry);
          }
        } else if (entry is File && isAgentSkillRootMarkdown(name)) {
          markdown.add(entry);
          if (markdown.length > agentSkillMaxCandidates) {
            throw const AgentSkillImportLimitException();
          }
        } else if (entry is File &&
            isPortableSkillPathSegment(name) &&
            agentSkillScriptExtensions.contains(
              p.extension(name).toLowerCase(),
            )) {
          directoriesWithScripts.add(parent.path);
        }
      }
    }

    await visit(root);
    markdown.sort((a, b) => a.path.compareTo(b.path));
    final candidates = <AgentSkillImportCandidate>[];
    var markdownBytes = 0;
    for (final file in markdown) {
      try {
        await RevericPaths.requireNoLinks(root, file.path);
        final size = await file.length();
        if (size > agentSkillMaxMarkdownBytes) {
          _log.warning(
            'Skipping oversized SKILL.md during directory discovery',
          );
          continue;
        }
        markdownBytes += size;
        if (markdownBytes > agentSkillMaxScanMarkdownBytes) {
          throw const AgentSkillImportLimitException();
        }
        final content = utf8.decode(
          await file.openRead(0, size).expand((chunk) => chunk).toList(),
        );
        candidates.add(
          parseSelectedMarkdown(
            content: content,
            fileName: file.path,
            existing: existing,
            hasScripts: directoriesWithScripts.contains(file.parent.path),
            materialize: (dir) =>
                AgentSkillPackageWriter(dir).copyFrom(file, sourceRoot: root),
          ),
        );
      } on FormatException catch (error, stackTrace) {
        _log.error(
          'Invalid skill Markdown during directory discovery',
          error: error,
          stackTrace: stackTrace,
        );
      } on FileSystemException catch (error, stackTrace) {
        _log.error(
          'Could not read a skill candidate during directory discovery',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return candidates;
  }

  Future<List<AgentSkillImportCandidate>> discoverFromFiles({
    required List<String> filePaths,
    required List<NovelAgentSkillModel> existing,
  }) async => [
    for (final path in filePaths.where(
      (path) => path.toLowerCase().endsWith('.md'),
    ))
      parseSelectedMarkdown(
        content: await File(path).readAsString(),
        fileName: path,
        existing: existing,
      ),
  ];

  Future<List<AgentSkillReferenceFile>> _readReferences(
    Directory package,
  ) async {
    final references = await findAgentSkillReferenceDirectory(package);
    if (references == null) {
      return const [];
    }
    final files = <AgentSkillReferenceFile>[];
    var bytes = 0;
    await for (final entry in references.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is! File) {
        continue;
      }
      final path = p
          .split(p.relative(entry.path, from: package.path))
          .join('/');
      if (!isAgentSkillTextReference(path)) {
        continue;
      }
      final size = await entry.length();
      bytes += size;
      if (size > AgentSkillReferences.maxContentBytes ||
          bytes > AgentSkillReferences.maxTotalContentBytes ||
          files.length >= AgentSkillReferences.maxCount) {
        throw const AgentSkillImportLimitException();
      }
      files.add(
        AgentSkillReferenceFile(
          path: path,
          content: await entry.readAsString(),
        ),
      );
    }
    return AgentSkillReferences.normalizeOrThrow(files);
  }

  /// 将用户勾选的候选写入应用全局已安装技能。
  /// 同名覆盖保留原安装 ID；同一批里的重复名称跳过。写入异常计入 failed。
  Future<AgentSkillImportResult> importCandidates({
    required List<AgentSkillImportCandidate> candidates,
    required InstalledAgentSkillsNotifier notifier,
    required List<NovelAgentSkillModel> existing,
  }) async {
    final existingNames = existing.map((e) => e.name.trim()).toSet();
    final handledNames = <String>{};

    var imported = 0;
    var skipped = 0;
    var failed = 0;
    final skippedNames = <String>[];
    final failedFiles = <String>[];
    final failures = <AgentSkillImportFailure>[];

    for (final candidate in candidates) {
      final name = candidate.parsed.name.trim();
      if (handledNames.contains(name)) {
        skipped++;
        skippedNames.add(name);
        continue;
      }

      Directory? packageDirectory;
      try {
        var parsed = candidate.parsed;
        var references = const <AgentSkillReferenceFile>[];
        final materialize = candidate.materialize;
        if (materialize != null) {
          packageDirectory = await (await temporaryDirectory()).createTemp(
            'reveric_skill_import_',
          );
          await materialize(packageDirectory);
          final markdown = File(
            p.join(packageDirectory.path, skillMarkdownFileName),
          );
          if (await markdown.length() > agentSkillMaxMarkdownBytes) {
            throw const AgentSkillImportLimitException();
          }
          final current = AgentSkillImportParser.parse(
            await markdown.readAsString(),
          );
          if (current == null || current.name.trim() != name) {
            throw const FormatException(
              'Skill name or Markdown changed after discovery',
            );
          }
          parsed = current;
          references = await _readReferences(packageDirectory);
        }
        final input = InstallSkillInput(
          sourceKind: AgentSkillSourceKind.novelLocal,
          name: name,
          description: parsed.description,
          prompt: parsed.body,
          whenToUse: parsed.whenToUse,
          category: parsed.category,
          tags: parsed.tags,
          references: references,
          packageDirectory: packageDirectory,
        );
        if (candidate.nameConflict || existingNames.contains(name)) {
          await notifier.installOverwrite(input);
        } else {
          await notifier.createNovelLocalSkill(input);
        }
        existingNames.add(name);
        handledNames.add(name);
        imported++;
      } catch (error, stackTrace) {
        _log.error(
          '[Transfer] createEntry failed: ${candidate.filePath}',
          error: error,
          stackTrace: stackTrace,
        );
        failed++;
        failedFiles.add(candidate.filePath);
        failures.add((
          name: name,
          reason: switch (error) {
            AgentSkillImportLimitException() =>
              AgentSkillImportFailureReason.too_large,
            FileSystemException() => AgentSkillImportFailureReason.unavailable,
            FormatException() => AgentSkillImportFailureReason.invalid,
            _ => AgentSkillImportFailureReason.failed,
          },
        ));
      } finally {
        if (packageDirectory != null) {
          try {
            if (await packageDirectory.exists()) {
              await packageDirectory.delete(recursive: true);
            }
          } on FileSystemException catch (error, stackTrace) {
            _log.error(
              'Skill import cache cleanup failed',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
      }
    }

    return AgentSkillImportResult(
      imported: imported,
      skipped: skipped,
      failed: failed,
      skippedNames: skippedNames,
      failedFiles: failedFiles,
      failures: failures,
    );
  }

  /// 导出为 Agent Skills 目录布局：每个技能一个子目录 + `SKILL.md`。
  Stream<AgentSkillTransferFile> _exportFiles(
    List<NovelAgentSkillModel> entries,
  ) async* {
    final usedDirNames = <String>{};
    for (final entry in entries) {
      final dirName = _uniqueDirName(
        _sanitizeFileName(entry.name),
        usedDirNames,
      );
      usedDirNames.add(dirName);
      final content = AgentSkillImportParser.write(
        name: entry.name,
        description: entry.description,
        body: entry.prompt,
        whenToUse: entry.whenToUse,
        category: entry.category,
        tags: entry.tags,
      );
      yield AgentSkillTransferFile(
        relativePath: '$dirName/$skillMarkdownFileName',
        content: content,
      );
      for (final reference in AgentSkillReferences.sanitize(entry.references)) {
        yield AgentSkillTransferFile(
          relativePath: '$dirName/${reference.path}',
          content: reference.content,
        );
      }
      final skillRoot = entry.skillRoot;
      if (skillRoot != null) {
        final directory = Directory(skillRoot);
        await RevericPaths.requireNoLinks(directory, directory.path);
        if (!await directory.exists()) {
          throw const FileSystemException(
            'Installed skill folder is unavailable',
          );
        }
        await for (final resource in agentSkillPackageFiles(directory)) {
          await RevericPaths.requireNoLinks(directory, resource.file.path);
          yield AgentSkillTransferFile.resource(
            relativePath: '$dirName/${resource.path}',
            source: resource.file,
          );
        }
      }
    }
  }

  /// 导出为 Agent Skills 目录布局：每个技能一个子目录 + `SKILL.md`。
  Future<List<String>> exportToDirectory({
    required String dirPath,
    required List<NovelAgentSkillModel> entries,
  }) async {
    final dir = Directory(dirPath);
    await dir.create(recursive: true);

    final paths = <String>[];
    await for (final file in _exportFiles(entries)) {
      final filePath = p.join(dir.path, file.relativePath);
      final output = File(filePath);
      await RevericPaths.requireNoLinks(dir, output.path);
      await output.parent.create(recursive: true);
      final source = file.source;
      if (source == null) {
        await output.writeAsString(file.content);
      } else {
        await source.copy(output.path);
      }
      final parts = file.relativePath.split('/');
      if (parts.length == 2 && parts.last == skillMarkdownFileName) {
        paths.add(filePath);
      }
    }

    return paths;
  }

  /// 导出为 ZIP：内含多个 `<skill-name>/SKILL.md`。
  Future<String> exportToZip({
    required String zipPath,
    required List<NovelAgentSkillModel> entries,
  }) => compute(_writeZip, (zipPath, entries));

  static Future<String> _writeZip(
    (String, List<NovelAgentSkillModel>) input,
  ) async {
    final (zipPath, entries) = input;
    const transfer = AgentSkillTransferService();
    final encoder = ZipFileEncoder();
    encoder.create(zipPath);

    try {
      await for (final file in transfer._exportFiles(entries)) {
        final source = file.source;
        if (source == null) {
          encoder.addArchiveFile(
            ArchiveFile.string(file.relativePath, file.content),
          );
        } else {
          final input = InputFileStream(source.path);
          try {
            // archive 4.x buffers compressed entries. Stored entries stream to disk.
            encoder.addArchiveFile(
              ArchiveFile.stream(file.relativePath, input)
                ..compression = CompressionType.none,
            );
          } finally {
            await input.close();
          }
        }
      }
    } finally {
      encoder.closeSync();
    }

    return zipPath;
  }

  static String _sanitizeFileName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_')
        .trim();
    final result = cleaned.isEmpty ? 'untitled' : cleaned;
    final sanitized = result.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
    return sanitized.isEmpty || sanitized == '.' || sanitized == '..'
        ? 'untitled'
        : sanitized;
  }

  static String _uniqueDirName(String baseName, Set<String> used) {
    if (!used.contains(baseName)) {
      return baseName;
    }
    var index = 2;
    while (used.contains('$baseName ($index)')) {
      index++;
    }
    return '$baseName ($index)';
  }
}
