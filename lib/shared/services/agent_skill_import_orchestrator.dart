// 职责: 扫描公开仓库的技能清单，按需读取选中的技能包。
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
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../logger/app_logger.dart';
import 'agent_skill_import_parser.dart';
import 'agent_skill_import_source.dart';
import 'agent_skill_package.dart';
import 'agent_skill_transfer.dart';

export 'agent_skill_package.dart' show AgentSkillImportLimitException;

final _log = AppLogger.forModule('AgentSkillImport');

class AgentSkillImportUnavailableException implements Exception {
  const AgentSkillImportUnavailableException();
}

class AgentSkillImportOrchestrator {
  static const maxDownloadBytes = 32 * 1024 * 1024;
  static const maxExpandedBytes = 128 * 1024 * 1024;
  static const maxSkillBytes = agentSkillMaxMarkdownBytes;

  Future<List<AgentSkillImportCandidate>> discover({
    required AgentSkillImportSource source,
    required Set<String> existingNames,
    required Dio client,
    required CancelToken cancelToken,
    Future<Dio> Function()? openPackageClient,
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
          openPackageClient: openPackageClient,
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
      final compressed = bytes.takeBytes();
      final result = await compute(_scanArchive, (
        compressed,
        subpath,
        source.singleFile,
        existingNames,
      ));
      if (cancelToken.isCancelled) {
        throw cancelToken.cancelError!;
      }
      _log.info('repository scan complete candidates=${result.length}');
      return [
        for (final skill in result)
          AgentSkillImportCandidate(
            filePath: skill.filePath,
            parsed: skill.parsed,
            nameConflict: skill.nameConflict,
            hasScripts: skill.hasScripts,
            materialize: (destination) => compute(_copyArchivePackage, (
              compressed,
              skill.filePath,
              destination.path,
            )),
          ),
      ];
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
    required Future<Dio> Function()? openPackageClient,
  }) async {
    final (revision, subpath) = target;
    Future<Object?> getJson(Uri uri, Dio client, CancelToken token) async =>
        (await client.get<Object?>(
          uri.toString(),
          cancelToken: token,
          options: Options(receiveTimeout: const Duration(seconds: 20)),
        )).data;
    final data = await getJson(source.treeUri(revision), client, cancelToken);
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
    Future<String> readEncoded(
      String path,
      int limit,
      Dio client,
      CancelToken token,
    ) async {
      final (sha, size) = files[path]!;
      if (size > limit || size > maxDownloadBytes) {
        throw const AgentSkillImportLimitException();
      }
      final blob = await getJson(source.blobUri(sha), client, token);
      if (blob is! Map ||
          blob['encoding'] != 'base64' ||
          blob['content'] is! String) {
        throw const FormatException('Invalid repository blob response');
      }
      return blob['content'] as String;
    }

    final whitespace = RegExp(r'\s');
    Iterable<String> encodedChunks(String encoded) sync* {
      const chunkSize = 64 * 1024;
      for (var offset = 0; offset < encoded.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, encoded.length);
        yield encoded.substring(offset, end).replaceAll(whitespace, '');
      }
    }

    var previewBytes = 0;
    final candidates = <AgentSkillImportCandidate>[];
    for (final path in skillPaths) {
      if (files[path]!.$2 > maxSkillBytes) {
        _log.warning('Skipping oversized SKILL.md in repository tree');
        continue;
      }
      previewBytes += files[path]!.$2;
      if (previewBytes > agentSkillMaxScanMarkdownBytes) {
        throw const AgentSkillImportLimitException();
      }
      final packagePaths = _packagePaths(files.keys, path).toList();
      try {
        final size = files[path]!.$2;
        final encoded = (await readEncoded(
          path,
          maxSkillBytes,
          client,
          cancelToken,
        )).replaceAll(whitespace, '');
        if (encoded.length > ((size + 2) ~/ 3) * 4) {
          throw const AgentSkillImportLimitException();
        }
        final markdown = base64.decode(encoded);
        if (markdown.length != size) {
          throw const FormatException(
            'Repository file size does not match its tree entry',
          );
        }
        candidates.add(
          _candidate(
            path,
            utf8.decode(markdown),
            existingNames,
            hasScripts: agentSkillHasScripts(
              packagePaths.map((entry) => entry.relative),
            ),
            materialize: (destination) async {
              final packageClient = openPackageClient == null
                  ? client
                  : await openPackageClient();
              final token = CancelToken();
              final writer = AgentSkillPackageWriter(destination);
              try {
                await writer.addStream(
                  agentSkillMarkdownName,
                  Stream.value(markdown),
                  size: markdown.length,
                );
                for (final entry in packagePaths) {
                  final expectedSize = files[entry.source]!.$2;
                  Stream<List<int>> readBytes() async* {
                    final encoded = await readEncoded(
                      entry.source,
                      expectedSize,
                      packageClient,
                      token,
                    );
                    yield* base64.decoder.bind(
                      Stream.fromIterable(encodedChunks(encoded)),
                    );
                  }

                  await writer.addStream(
                    entry.relative,
                    readBytes(),
                    size: expectedSize,
                  );
                }
              } finally {
                if (openPackageClient != null) {
                  packageClient.close(force: true);
                }
              }
            },
          ),
        );
      } on FormatException catch (error, stackTrace) {
        _log.error(
          'Invalid SKILL.md in repository tree',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (cancelToken.isCancelled) {
      throw cancelToken.cancelError!;
    }
    if (candidates.isEmpty && skillPaths.isNotEmpty) {
      throw const FormatException(
        'No readable SKILL.md in the repository tree',
      );
    }
    return candidates;
  }
}

Map<String, ZipFile> _archiveFiles(Uint8List bytes) {
  if (bytes.length < 22 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x4b ||
      !((bytes[2] == 3 && bytes[3] == 4) || (bytes[2] == 5 && bytes[3] == 6))) {
    throw const FormatException('Response is not a ZIP archive');
  }
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.length > agentSkillMaxScanEntries) {
    throw const AgentSkillImportLimitException();
  }
  final files = <String, ZipFile>{};
  var expandedBytes = 0;
  for (final header in directory.fileHeaders) {
    final file = header.file!;
    expandedBytes += file.uncompressedSize;
    if (file.uncompressedSize < 0 ||
        expandedBytes > AgentSkillImportOrchestrator.maxExpandedBytes) {
      throw const AgentSkillImportLimitException();
    }
    final unixMode = (header.externalFileAttributes >> 16) & 0xf000;
    if (unixMode != 0 && unixMode != 0x8000) {
      continue;
    }
    final segments = file.filename.split('/');
    if (segments.length < 2 ||
        segments.first.isEmpty ||
        segments.first == '.' ||
        segments.first == '..' ||
        agentSkillIgnoredDirectories.contains(segments.first.toLowerCase()) ||
        segments.first.contains('\\')) {
      continue;
    }
    final path = segments.skip(1).join('/');
    if (_safeRepositoryPath(path)) {
      if (files.containsKey(path)) {
        throw const FormatException('Duplicate ZIP file path');
      }
      files[path] = file;
    }
  }
  return files;
}

Iterable<({String source, String relative})> _packagePaths(
  Iterable<String> files,
  String markdown,
) sync* {
  final parent = p.posix.dirname(markdown);
  final prefix = parent == '.' ? '' : '$parent/';
  for (final path in files) {
    if (path != markdown && path.startsWith(prefix)) {
      final relative = path.substring(prefix.length);
      if (!isAgentSkillRootMarkdown(relative) &&
          isAgentSkillImportFile(relative)) {
        yield (source: path, relative: relative);
      }
    }
  }
}

List<AgentSkillImportCandidate> _scanArchive(
  (Uint8List, String, bool, Set<String>) input,
) {
  final (bytes, subpath, singleFile, existingNames) = input;
  final files = _archiveFiles(bytes);
  final candidates = <AgentSkillImportCandidate>[];
  final skillPaths = _skillPaths(files.keys, subpath, singleFile);
  var previewBytes = 0;
  for (final path in skillPaths) {
    final file = files[path]!;
    if (file.uncompressedSize > agentSkillMaxMarkdownBytes) {
      _log.warning('Skipping oversized SKILL.md in repository ZIP');
      continue;
    }
    previewBytes += file.uncompressedSize;
    if (previewBytes > agentSkillMaxScanMarkdownBytes) {
      throw const AgentSkillImportLimitException();
    }
    try {
      final output = OutputMemoryStream();
      file.decompress(_LimitedZipOutput(output, file.uncompressedSize));
      if (output.length != file.uncompressedSize) {
        throw const FormatException('Repository ZIP Markdown size mismatch');
      }
      candidates.add(
        _candidate(
          path,
          utf8.decode(output.getBytes()),
          existingNames,
          hasScripts: agentSkillHasScripts(
            _packagePaths(files.keys, path).map((entry) => entry.relative),
          ),
        ),
      );
    } on FormatException catch (error, stackTrace) {
      _log.error(
        'Invalid SKILL.md in repository ZIP',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
  if (candidates.isEmpty && skillPaths.isNotEmpty) {
    throw const FormatException('No readable SKILL.md in the repository ZIP');
  }
  return candidates;
}

Future<void> _copyArchivePackage((Uint8List, String, String) input) async {
  final (bytes, markdown, destination) = input;
  final files = _archiveFiles(bytes);
  final writer = AgentSkillPackageWriter(Directory(destination));
  for (final entry in [
    (source: markdown, relative: agentSkillMarkdownName),
    ..._packagePaths(files.keys, markdown),
  ]) {
    final file = files[entry.source]!;
    await writer.write(entry.relative, (destination, limit) async {
      final output = OutputFileStream(destination.path);
      try {
        file.decompress(_LimitedZipOutput(output, file.uncompressedSize));
      } finally {
        output.closeSync();
      }
    }, size: file.uncompressedSize);
  }
}

/// ZIP entry sizes are untrusted until the decoder finishes writing.
class _LimitedZipOutput extends OutputStream {
  _LimitedZipOutput(this.output, this.limit)
    : super(byteOrder: output.byteOrder);
  final OutputStream output;
  final int limit;

  @override
  int get length => output.length;

  void _check(int count) {
    if (length + count > limit) {
      throw const AgentSkillImportLimitException();
    }
  }

  @override
  void clear() => output.clear();

  @override
  void flush() => output.flush();

  @override
  Uint8List subset(int start, [int? end]) => output.subset(start, end);

  @override
  void writeByte(int value) {
    _check(1);
    output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    output.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    output.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    output.writeBackReference(distance, count);
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
  if (selected.length > agentSkillMaxCandidates) {
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
              agentSkillIgnoredDirectories.contains(s.toLowerCase()),
        );

AgentSkillImportCandidate _candidate(
  String path,
  String raw,
  Set<String> existingNames, {
  required bool hasScripts,
  Future<void> Function(Directory)? materialize,
}) {
  final parsed = AgentSkillImportParser.parse(raw);
  if (parsed == null) {
    throw const FormatException('Invalid SKILL.md frontmatter');
  }
  return AgentSkillImportCandidate(
    filePath: path,
    parsed: parsed,
    nameConflict: existingNames.contains(parsed.name.trim()),
    hasScripts: hasScripts,
    materialize: materialize,
  );
}
