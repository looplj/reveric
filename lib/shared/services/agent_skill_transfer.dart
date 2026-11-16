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

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../logger/app_logger.dart';
import '../models/agent_skill_reference.dart';
import '../models/novel_agent_skill.dart';
import '../providers/novel_agent_skill_providers.dart';
import 'agent_skill_import_parser.dart';

final _log = AppLogger.forModule('AgentSkillTransfer');

/// 扫描到的可导入技能候选（尚未写入库）。
class AgentSkillImportCandidate {
  const AgentSkillImportCandidate({
    required this.filePath,
    required this.parsed,
    required this.nameConflict,
    this.references = const [],
    this.hasScripts = false,
  });

  final String filePath;
  final AgentSkillImportParseResult parsed;
  final bool nameConflict;
  final List<AgentSkillReferenceFile> references;
  final bool hasScripts;

  String get name => parsed.name;
  String get description => parsed.description;
  String get category => parsed.category;
}

/// 只检测脚本资源是否存在，不读取或执行脚本。
bool agentSkillHasScripts(Iterable<String> paths) => paths.any((path) {
  final parts = path.replaceAll('\\', '/').split('/');
  return parts.contains('scripts') ||
      const {
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
      }.contains(p.posix.extension(path).toLowerCase());
});

/// 批量导入结果。
class AgentSkillImportResult {
  const AgentSkillImportResult({
    required this.imported,
    required this.skipped,
    required this.failed,
    this.skippedNames = const [],
    this.failedFiles = const [],
  });

  final int imported;
  final int skipped;
  final int failed;
  final List<String> skippedNames;
  final List<String> failedFiles;

  int get total => imported + skipped + failed;
}

/// 单个导出文件的相对路径和文本内容，供本地目录与 Android SAF 共用。
class AgentSkillTransferFile {
  const AgentSkillTransferFile({
    required this.relativePath,
    required this.content,
  });

  final String relativePath;
  final String content;
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
  const AgentSkillTransferService();

  static const skillMarkdownFileName = 'SKILL.md';
  static const referencesDirName = AgentSkillReferences.relativeDir;

  /// 读取系统选择器提供的内容，不将移动端 URI 当作普通文件路径。
  AgentSkillImportCandidate parseSelectedMarkdown({
    required String content,
    required String fileName,
    required List<NovelAgentSkillModel> existing,
  }) {
    final parsed = AgentSkillImportParser.parse(content);
    if (parsed == null) {
      throw const FormatException('Invalid skill Markdown frontmatter');
    }
    return AgentSkillImportCandidate(
      filePath: fileName,
      parsed: parsed,
      nameConflict: existing.any(
        (entry) => entry.name.trim() == parsed.name.trim(),
      ),
    );
  }

  /// 递归扫描 [dirPath] 下所有 `SKILL.md`，解析 frontmatter。
  /// 解析失败的文件不进入返回列表（计入日志）；同名已安装技能冲突标记 [nameConflict]。
  List<AgentSkillImportCandidate> discoverInDirectory({
    required String dirPath,
    required List<NovelAgentSkillModel> existing,
  }) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      throw FileSystemException('Directory not found', dirPath);
    }

    return _discoverFromFiles(
      files: _collectSkillMarkdownFiles(dir),
      existing: existing,
    );
  }

  /// 从用户选中的 `.md` / `SKILL.md` 文件解析候选（iOS 等无文件夹选择器的平台）。
  List<AgentSkillImportCandidate> discoverFromFiles({
    required List<String> filePaths,
    required List<NovelAgentSkillModel> existing,
  }) {
    final files = filePaths
        .map(File.new)
        .where((f) => f.path.toLowerCase().endsWith('.md'))
        .toList(growable: false);
    return _discoverFromFiles(files: files, existing: existing);
  }

  List<AgentSkillImportCandidate> _discoverFromFiles({
    required List<File> files,
    required List<NovelAgentSkillModel> existing,
  }) {
    final existingNames = existing.map((e) => e.name.trim()).toSet();
    final candidates = <AgentSkillImportCandidate>[];

    for (final file in files) {
      final String raw;
      try {
        raw = file.readAsStringSync();
      } catch (error, stackTrace) {
        _log.error(
          '[Transfer] read failed: ${file.path}',
          error: error,
          stackTrace: stackTrace,
        );
        continue;
      }

      final parsed = AgentSkillImportParser.parse(raw);
      if (parsed == null) {
        _log.error('[Transfer] parse failed: ${file.path}');
        continue;
      }

      final name = parsed.name.trim();
      candidates.add(
        AgentSkillImportCandidate(
          filePath: file.path,
          parsed: parsed,
          nameConflict: existingNames.contains(name),
          references: _loadReferencesBesideSkillMarkdown(file),
          hasScripts:
              Directory(p.join(file.parent.path, 'scripts')).existsSync() ||
              agentSkillHasScripts(
                file.parent
                    .listSync(followLinks: false)
                    .whereType<File>()
                    .map((entry) => p.basename(entry.path)),
              ),
        ),
      );
    }

    return candidates;
  }

  /// 递归读取 `SKILL.md` 同级 `references/**` 文本文件。
  static List<AgentSkillReferenceFile> _loadReferencesBesideSkillMarkdown(
    File skillMarkdown,
  ) {
    final skillDir = skillMarkdown.parent;
    final refsDir = Directory(p.join(skillDir.path, referencesDirName));
    if (!refsDir.existsSync()) {
      return const [];
    }

    final files = <AgentSkillReferenceFile>[];
    for (final entity in refsDir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) {
        continue;
      }
      final relativePath =
          '$referencesDirName/${p.relative(entity.path, from: refsDir.path).replaceAll('\\', '/')}';
      if (!AgentSkillReferences.isValidRelativePath(relativePath)) {
        continue;
      }
      try {
        final content = entity.readAsStringSync();
        files.add(
          AgentSkillReferenceFile(path: relativePath, content: content),
        );
      } catch (error, stackTrace) {
        _log.error(
          '[Transfer] read reference failed: ${entity.path}',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return AgentSkillReferences.sanitize(files);
  }

  /// 将用户勾选的候选写入应用全局已安装技能。
  /// 同名冲突先卸载再安装；同一批里的重复名称跳过。写入异常计入 failed。
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

    for (final candidate in candidates) {
      final name = candidate.parsed.name.trim();
      if (handledNames.contains(name)) {
        skipped++;
        skippedNames.add(name);
        continue;
      }

      final input = InstallSkillInput(
        sourceKind: AgentSkillSourceKind.novelLocal,
        name: name,
        description: candidate.parsed.description,
        prompt: candidate.parsed.body,
        whenToUse: candidate.parsed.whenToUse,
        category: candidate.parsed.category,
        tags: candidate.parsed.tags,
        references: candidate.references,
      );
      try {
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
      }
    }

    return AgentSkillImportResult(
      imported: imported,
      skipped: skipped,
      failed: failed,
      skippedNames: skippedNames,
      failedFiles: failedFiles,
    );
  }

  /// 导出为 Agent Skills 目录布局：每个技能一个子目录 + `SKILL.md`。
  List<AgentSkillTransferFile> buildDirectoryFiles(
    List<NovelAgentSkillModel> entries,
  ) {
    final usedDirNames = <String>{};
    final files = <AgentSkillTransferFile>[];
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
      files.add(
        AgentSkillTransferFile(
          relativePath: '$dirName/$skillMarkdownFileName',
          content: content,
        ),
      );
      for (final reference in AgentSkillReferences.sanitize(entry.references)) {
        files.add(
          AgentSkillTransferFile(
            relativePath: '$dirName/${reference.path}',
            content: reference.content,
          ),
        );
      }
    }
    return files;
  }

  /// 导出为 Agent Skills 目录布局：每个技能一个子目录 + `SKILL.md`。
  Future<List<String>> exportToDirectory({
    required String dirPath,
    required List<NovelAgentSkillModel> entries,
  }) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final paths = <String>[];
    for (final file in buildDirectoryFiles(entries)) {
      final filePath = p.join(dir.path, file.relativePath);
      final output = File(filePath);
      output.parent.createSync(recursive: true);
      output.writeAsStringSync(file.content);
      if (p.basename(filePath) == skillMarkdownFileName) {
        paths.add(filePath);
      }
    }

    return paths;
  }

  /// 导出为 ZIP：内含多个 `<skill-name>/SKILL.md`。
  Future<String> exportToZip({
    required String zipPath,
    required List<NovelAgentSkillModel> entries,
  }) async {
    final encoder = ZipFileEncoder();
    encoder.create(zipPath);

    try {
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
        encoder.addArchiveFile(
          ArchiveFile.string('$dirName/$skillMarkdownFileName', content),
        );
        for (final ref in entry.references) {
          encoder.addArchiveFile(
            ArchiveFile.string('$dirName/${ref.path}', ref.content),
          );
        }
      }
    } finally {
      encoder.closeSync();
    }

    return zipPath;
  }

  /// 收集目录下所有 `SKILL.md`（公开便于单测）。
  static List<File> collectSkillMarkdownFiles(Directory dir) {
    return _collectSkillMarkdownFiles(dir);
  }

  static List<File> _collectSkillMarkdownFiles(Directory dir) {
    return dir
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (f) =>
              p.basename(f.path).toLowerCase() ==
              skillMarkdownFileName.toLowerCase(),
        )
        .toList(growable: false)
      ..sort((a, b) => a.path.compareTo(b.path));
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
