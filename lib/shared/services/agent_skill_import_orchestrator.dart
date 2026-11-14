// 职责: 下载公开仓库并在内存中扫描技能及 references，返回待确认的导入候选。
// 关联文件:
//   lib/shared/services/agent_skill_import_source.dart
//   lib/shared/services/agent_skill_transfer.dart
//   lib/shared/services/agent_skill_import_parser.dart
//   lib/shared/models/agent_skill_reference.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../logger/app_logger.dart';
import '../models/agent_skill_reference.dart';
import 'agent_skill_import_parser.dart';
import 'agent_skill_import_source.dart';
import 'agent_skill_transfer.dart';

final _log = AppLogger.forModule('AgentSkillImport');

class AgentSkillImportLimitException implements Exception {
  const AgentSkillImportLimitException();
}

class AgentSkillImportUnavailableException implements Exception {
  const AgentSkillImportUnavailableException();
}

class AgentSkillImportOrchestrator {
  static const maxDownloadBytes = 32 * 1024 * 1024;
  static const maxExpandedBytes = 128 * 1024 * 1024;
  static const maxSkillBytes = 1024 * 1024;

  Future<List<AgentSkillImportCandidate>> discover({
    required AgentSkillImportSource source,
    required Set<String> existingNames,
    required Dio client,
    required CancelToken cancelToken,
  }) async {
    _log.info('repository scan start host=${source.host}');
    try {
      String? revision;
      var subpath = '';
      if (source.revisionPath.isNotEmpty) {
        // 尝试最长 ref，避免把 feature/topic 分支误认为 feature 下的目录。
        final maxSegments =
            source.revisionPath.length - (source.singleFile ? 1 : 0);
        for (var count = maxSegments; count >= 1; count--) {
          final ref = source.revisionPath.take(count).join('/');
          final Response<Object?> response;
          try {
            response = await client.get<Object?>(
              source.revisionUri(ref).toString(),
              cancelToken: cancelToken,
              options: Options(
                validateStatus: (status) => status == 200 || status == 404,
                receiveTimeout: const Duration(seconds: 20),
                sendTimeout: const Duration(seconds: 20),
              ),
            );
          } on DioException catch (error) {
            // GitHub 对不存在的 ref 返回 422；其他校验错误仍交给调用方。
            final data = error.response?.data;
            if (source.host == 'github.com' &&
                error.response?.statusCode == 422 &&
                data is Map &&
                data['message'] == 'No commit found for SHA: $ref') {
              continue;
            }
            rethrow;
          }
          if (response.statusCode == 404) {
            continue;
          }
          final data = response.data;
          final sha = data is Map ? data[source.revisionResponseKey] : null;
          if (sha is! String ||
              !RegExp(r'^[a-fA-F0-9]{40,64}$').hasMatch(sha)) {
            throw const FormatException('Invalid repository revision response');
          }
          revision = sha;
          subpath = source.revisionPath.skip(count).join('/');
          break;
        }
        if (revision == null) {
          throw const AgentSkillImportUnavailableException();
        }
      }
      final defaultBranchUri = source.defaultBranchUri;
      if (revision == null && defaultBranchUri != null) {
        final metadata = await client.get<Object?>(
          defaultBranchUri.toString(),
          cancelToken: cancelToken,
          options: Options(receiveTimeout: const Duration(seconds: 20)),
        );
        final data = metadata.data;
        final branch = data is Map ? data['default_branch'] : null;
        if (branch is! String || branch.trim().isEmpty) {
          throw const FormatException('Repository default branch is missing');
        }
        revision = branch;
      }
      if (source.usesFileApi) {
        final candidates = await _discoverFiles(
          source: source,
          target: (revision!, subpath),
          existingNames: existingNames,
          client: client,
          cancelToken: cancelToken,
        );
        _log.info(
          'repository file scan complete candidates=${candidates.length}',
        );
        return candidates;
      }
      final response = await client.get<ResponseBody>(
        source.archiveUri(revision).toString(),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 20),
        ),
      );
      final body = response.data!;
      final length = int.tryParse(
        body.headers[Headers.contentLengthHeader]?.firstOrNull ?? '',
      );
      if (length != null && length > maxDownloadBytes) {
        cancelToken.cancel('Repository archive exceeds download limit');
        throw const AgentSkillImportLimitException();
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (bytes.length + chunk.length > maxDownloadBytes) {
          cancelToken.cancel('Repository archive exceeds download limit');
          throw const AgentSkillImportLimitException();
        }
        bytes.add(chunk);
      }
      if (cancelToken.isCancelled) {
        throw cancelToken.cancelError!;
      }
      final result = await compute(_scanArchive, (
        bytes.takeBytes(),
        subpath,
        source.singleFile,
        existingNames,
      ));
      if (cancelToken.isCancelled) {
        throw cancelToken.cancelError!;
      }
      _log.info('repository scan complete candidates=${result.length}');
      return result;
    } on DioException catch (error, stackTrace) {
      _log.error(
        'repository request failed host=${source.host} '
        'status=${error.response?.statusCode} type=${error.type.name}',
        error: error.response?.data is Map
            ? (error.response!.data as Map)['message']
            : error.message,
        stackTrace: stackTrace,
      );
      rethrow;
    } catch (error, stackTrace) {
      _log.error(
        'repository scan failed host=${source.host}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<List<AgentSkillImportCandidate>> _discoverFiles({
    required AgentSkillImportSource source,
    required (String, String) target,
    required Set<String> existingNames,
    required Dio client,
    required CancelToken cancelToken,
  }) async {
    final (revision, subpath) = target;
    Future<Object?> getJson(Uri uri) async => (await client.get<Object?>(
      uri.toString(),
      cancelToken: cancelToken,
      options: Options(receiveTimeout: const Duration(seconds: 20)),
    )).data;
    final data = await getJson(source.treeUri(revision));
    if (data is! Map || data['tree'] is! List) {
      throw const FormatException('Invalid repository tree response');
    }
    final tree = data['tree'] as List;
    if (data['truncated'] == true || tree.length > 20000) {
      throw const AgentSkillImportLimitException();
    }
    final files = <String, (String, int)>{};
    for (final item in tree) {
      if (item is! Map ||
          item['type'] != 'blob' ||
          !{'100644', '100755'}.contains(item['mode'])) {
        continue;
      }
      final path = item['path'];
      final sha = item['sha'];
      final size = item['size'];
      if (path is! String ||
          sha is! String ||
          size is! int ||
          size < 0 ||
          !RegExp(r'^[a-fA-F0-9]{40,64}$').hasMatch(sha)) {
        throw const FormatException('Invalid repository file entry');
      }
      if (_safeRepositoryPath(path)) {
        files[path] = (sha, size);
      }
    }
    final skillPaths = _skillPaths(files.keys, subpath, source.singleFile);
    var totalBytes = 0;
    Future<String> read(String path, int limit) async {
      final (sha, size) = files[path]!;
      if (size > limit || totalBytes + size > maxDownloadBytes) {
        throw const AgentSkillImportLimitException();
      }
      final blob = await getJson(source.blobUri(sha));
      if (blob is! Map ||
          blob['encoding'] != 'base64' ||
          blob['content'] is! String) {
        throw const FormatException('Invalid repository blob response');
      }
      final encoded = (blob['content'] as String).replaceAll(RegExp(r'\s'), '');
      if (encoded.length > ((limit + 2) ~/ 3) * 4) {
        throw const AgentSkillImportLimitException();
      }
      final bytes = base64.decode(encoded);
      totalBytes += bytes.length;
      if (bytes.length > limit || totalBytes > maxDownloadBytes) {
        throw const AgentSkillImportLimitException();
      }
      return utf8.decode(bytes);
    }

    final candidates = <AgentSkillImportCandidate>[];
    for (final path in skillPaths) {
      final parent = p.posix.dirname(path);
      final prefix = parent == '.' ? '' : '$parent/';
      final referencePaths =
          files.keys
              .where(
                (key) =>
                    key.startsWith('${prefix}references/') &&
                    AgentSkillReferences.isValidRelativePath(
                      key.substring(prefix.length),
                    ),
              )
              .toList()
            ..sort();
      final referenceBytes = referencePaths.fold<int>(
        0,
        (sum, key) => sum + files[key]!.$2,
      );
      if (referencePaths.length > AgentSkillReferences.maxCount ||
          referenceBytes > AgentSkillReferences.maxTotalContentBytes) {
        throw const AgentSkillImportLimitException();
      }
      final raw = await read(path, maxSkillBytes);
      final references = <AgentSkillReferenceFile>[
        for (final referencePath in referencePaths)
          AgentSkillReferenceFile(
            path: referencePath.substring(prefix.length),
            content: await read(
              referencePath,
              AgentSkillReferences.maxContentBytes,
            ),
          ),
      ];
      candidates.add(
        _candidate(
          path,
          raw,
          references,
          existingNames,
          hasScripts: agentSkillHasScripts(
            files.keys
                .where((key) => key.startsWith(prefix))
                .map((key) => key.substring(prefix.length)),
          ),
        ),
      );
    }
    if (cancelToken.isCancelled) {
      throw cancelToken.cancelError!;
    }
    return candidates;
  }
}

List<AgentSkillImportCandidate> _scanArchive(
  (Uint8List, String, bool, Set<String>) input,
) {
  final (bytes, subpath, singleFile, existingNames) = input;
  if (bytes.length < 22 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x4b ||
      !((bytes[2] == 3 && bytes[3] == 4) || (bytes[2] == 5 && bytes[3] == 6))) {
    throw const FormatException('Response is not a ZIP archive');
  }
  // 在解压前检查目录，包括会被 ZIP decoder 提前读取的符号链接。
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  var expandedBytes = 0;
  if (directory.fileHeaders.length > 20000) {
    throw const AgentSkillImportLimitException();
  }
  for (final header in directory.fileHeaders) {
    expandedBytes += header.uncompressedSize;
    if (expandedBytes > AgentSkillImportOrchestrator.maxExpandedBytes ||
        header.uncompressedSize >
            AgentSkillImportOrchestrator.maxExpandedBytes) {
      throw const AgentSkillImportLimitException();
    }
  }
  final archive = ZipDecoder().decodeBytes(bytes);
  try {
    final files = <String, ArchiveFile>{};
    for (final file in archive.files) {
      final segments = file.name.split('/');
      if (!file.isFile ||
          file.isSymbolicLink ||
          segments.length < 2 ||
          file.name.contains('\\') ||
          segments.any((s) => s.isEmpty || s == '.' || s == '..') ||
          segments.skip(1).any((s) => s == '.git' || s == 'node_modules')) {
        continue;
      }
      final path = segments.skip(1).join('/');
      files[path] = file;
    }
    final skillPaths = _skillPaths(files.keys, subpath, singleFile);
    final candidates = <AgentSkillImportCandidate>[];
    for (final path in skillPaths) {
      final file = files[path]!;
      if (file.size > AgentSkillImportOrchestrator.maxSkillBytes) {
        throw const AgentSkillImportLimitException();
      }
      final parent = p.posix.dirname(path);
      final prefix = parent == '.' ? '' : '$parent/';
      final references = <AgentSkillReferenceFile>[];
      for (final entry in files.entries) {
        if (!entry.key.startsWith('${prefix}references/')) {
          continue;
        }
        final relativePath = entry.key.substring(prefix.length);
        if (!AgentSkillReferences.isValidRelativePath(relativePath)) {
          continue;
        }
        if (entry.value.size > AgentSkillReferences.maxContentBytes) {
          throw const AgentSkillImportLimitException();
        }
        references.add(
          AgentSkillReferenceFile(
            path: relativePath,
            content: utf8.decode(entry.value.content),
          ),
        );
      }
      candidates.add(
        _candidate(
          path,
          utf8.decode(file.content),
          references,
          existingNames,
          hasScripts: agentSkillHasScripts(
            files.keys
                .where((key) => key.startsWith(prefix))
                .map((key) => key.substring(prefix.length)),
          ),
        ),
      );
    }
    return candidates;
  } finally {
    archive.clearSync();
  }
}

List<String> _skillPaths(
  Iterable<String> paths,
  String subpath,
  bool singleFile,
) {
  final selected =
      paths
          .where(
            (path) =>
                p.posix.basename(path).toLowerCase() == 'skill.md' &&
                (singleFile
                    ? path == subpath
                    : subpath.isEmpty || path.startsWith('$subpath/')),
          )
          .toList()
        ..sort();
  if (selected.length > 500) {
    throw const AgentSkillImportLimitException();
  }
  return selected;
}

bool _safeRepositoryPath(String path) =>
    !path.contains('\\') &&
    !path.contains('\u0000') &&
    !path
        .split('/')
        .any(
          (s) =>
              s.isEmpty ||
              s == '.' ||
              s == '..' ||
              s == '.git' ||
              s == 'node_modules',
        );

AgentSkillImportCandidate _candidate(
  String path,
  String raw,
  List<AgentSkillReferenceFile> references,
  Set<String> existingNames, {
  bool hasScripts = false,
}) {
  final parsed = AgentSkillImportParser.parse(raw);
  if (parsed == null) {
    throw const FormatException('Invalid SKILL.md frontmatter');
  }
  return AgentSkillImportCandidate(
    filePath: path,
    parsed: parsed,
    nameConflict: existingNames.contains(parsed.name.trim()),
    references: AgentSkillReferences.normalizeOrThrow(references),
    hasScripts: hasScripts,
  );
}
