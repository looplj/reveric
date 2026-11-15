// 职责: 把独立画布作品打成可移植的压缩包，并在导入时新建另一部画布作品。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/group_service.dart
//   lib/shared/services/novel_actions.dart
//   lib/desktop/features/production/canvas_package_file.dart
//   lib/desktop/features/production/package_actions.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/file-access.md
//   .agents/rules/error-handling.md
//   .agents/rules/data-deletion.md

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:archive/archive_io.dart' hide ZLibDecoder;
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../database/app_database.dart';
import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import '../../models/asset_purpose.dart';
import '../../models/content_kind.dart';
import '../../models/director/document.dart';
import '../../models/editing/document.dart';
import '../../models/production/media.dart';
import '../../models/production/settings.dart';
import '../../models/production/style.dart';
import '../../models/storyboard/prompt.dart';
import '../../models/video/request.dart';
import '../../utils/short_entity_id.dart';
import '../../utils/short_entity_id_allocator.dart';
import '../backup_zip.dart';
import '../novel_actions.dart';
import '../novel_content.dart';
import '../storyboard/service.dart';
import '../working_overlay.dart';
import 'canvas_service.dart';
import 'ffmpeg_runner.dart';
import 'library_service.dart';

const productionCanvasPackageFormat = 'production.canvas';
const _version = 1;
const _maxEntries = 10000;
const _maxManifestBytes = 32 * 1024 * 1024;
const _maxExpandedBytes = 8 * 1024 * 1024 * 1024;

final _log = AppLogger.forModule('ProductionCanvasPackage');

class ProductionCanvasPackageException implements Exception {
  const ProductionCanvasPackageException(this.code);
  final String code;
}

class ProductionCanvasPackageFile {
  ProductionCanvasPackageFile._(this.file, this._directory);
  final File file;
  final Directory _directory;

  Future<void> delete() async {
    if (await _directory.exists()) {
      await _directory.delete(recursive: true);
    }
  }
}

class ProductionCanvasPackageImport {
  const ProductionCanvasPackageImport({
    required this.novelId,
    required this.droppedStyles,
  });
  final String novelId;
  final int droppedStyles;
}

/// 导入导出都不改当前作品。导入只登记一部新的画布作品。
class ProductionCanvasPackageOrchestrator {
  const ProductionCanvasPackageOrchestrator();

  Future<ProductionCanvasPackageFile> exportToFile({
    required ProductionCanvasService canvas,
    required String canvasId,
    required String title,
    void Function(double progress)? onProgress,
  }) async {
    await _requireCanvasWork(canvas, canvasId);
    final parent = await Directory.systemTemp.createTemp(
      'reveric_canvas_package_',
    );
    try {
      final staging = Directory(p.join(parent.path, 'stage'));
      await staging.create();
      await _writeStaging(
        canvas,
        canvasId,
        staging,
        title,
        onProgress: onProgress == null
            ? null
            : (value) => onProgress((value * 0.75).clamp(0, 0.75)),
      );
      final zip = File(p.join(parent.path, 'canvas.zip'));
      await createBackupZip(
        staging,
        zip.path,
        onProgress: onProgress == null
            ? null
            : (value) => onProgress((0.75 + value * 0.25).clamp(0, 1)),
      );
      onProgress?.call(1);
      await staging.delete(recursive: true);
      return ProductionCanvasPackageFile._(zip, parent);
    } catch (error, stackTrace) {
      if (await parent.exists()) {
        await parent.delete(recursive: true);
      }
      if (error is! ProductionCanvasPackageException) {
        _log.error(
          'export stage=write result=failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
      rethrow;
    }
  }

  Future<ProductionCanvasPackageImport> importFile({
    required File zip,
    required NovelActionsService actions,
    required MediaLibraryService library,
    required String fallbackTitle,
    required NovelContentDatabase Function(String path) openContent,
    required Future<void> Function(NovelContentDatabase database)
    releaseContent,
    void Function(double progress)? onProgress,
  }) async {
    final parent = await Directory.systemTemp.createTemp(
      'reveric_canvas_import_',
    );
    try {
      final extracted = Directory(p.join(parent.path, 'out'));
      await extracted.create();
      await _extract(
        zip,
        extracted,
        parent,
        onProgress: onProgress == null
            ? null
            : (value) => onProgress((value * 0.6).clamp(0, 0.6)),
      );
      final package = await _readPackage(extracted);
      _log.info(
        'import stage=read result=success nodes=${package.nodes.length} '
        'assets=${package.assets.length}',
      );
      return await _install(
        package,
        extracted,
        actions: actions,
        library: library,
        fallbackTitle: fallbackTitle,
        openContent: openContent,
        releaseContent: releaseContent,
        onProgress: onProgress == null
            ? null
            : (value) => onProgress((0.6 + value * 0.4).clamp(0.6, 1)),
      );
    } finally {
      if (await parent.exists()) {
        await parent.delete(recursive: true);
      }
    }
  }
}

Future<void> _requireCanvasWork(
  ProductionCanvasService canvas,
  String canvasId,
) async {
  if (!await canvas.shots.isCanvasWork ||
      await canvas.episodeForCanvas(canvasId) != '') {
    _log.info('export stage=guard result=canvas_only');
    throw const ProductionCanvasPackageException('canvas_only');
  }
}

Future<void> _writeStaging(
  ProductionCanvasService canvas,
  String canvasId,
  Directory staging,
  String title, {
  void Function(double progress)? onProgress,
}) async {
  final content = await canvas.content(canvasId);
  final nodes = content.nodes
      .where((node) => node.type != canvasNodeTypeScene)
      .toList();
  if (nodes.isEmpty) {
    _log.info('export stage=read result=empty');
    throw const ProductionCanvasPackageException('empty');
  }
  final byId = {for (final node in nodes) node.id: node};
  final clips = <String, ProductionClipRow>{};
  for (final node in nodes) {
    final clipId = node.clipId;
    if (clipId == null) {
      continue;
    }
    final clip = await canvas.shots.getShot(clipId);
    if (clip == null) {
      throw const ProductionCanvasPackageException('unsupported');
    }
    clips[node.id] = clip;
  }
  final documents = await _documents(canvas, nodes);
  final referenced = _referencedAssets(nodes, clips, documents);
  for (final node in nodes) {
    if (node.parentId != null &&
        byId[node.parentId]?.type != canvasNodeTypeGroup) {
      throw const ProductionCanvasPackageException('unsupported');
    }
    if (node.parentId != null && node.type == canvasNodeTypeMedia) {
      final asset = await canvas.library.database.assetDao.getAsset(
        node.mediaAssetId!,
      );
      if (asset?.type != 'image') {
        throw const ProductionCanvasPackageException('unsupported');
      }
    }
    final clip = clips[node.id];
    for (final input in clip?.inputs ?? const <ProductionInput>[]) {
      if (input.refType == ProductionInputType.node &&
          !byId.containsKey(input.refId)) {
        throw const ProductionCanvasPackageException('unsupported');
      }
    }
    if (node.type == canvasNodeTypeGroup) {
      if (node.parentId != null ||
          node.width == null ||
          node.height == null ||
          node.width! <= 0 ||
          node.height! <= 0) {
        throw const ProductionCanvasPackageException('unsupported');
      }
    }
  }
  final stored = content.edges.where((edge) => edge.inputId == null).toList();
  for (final edge in stored) {
    if (edge.type != canvasEdgeTypeStagingOutput &&
        edge.type != canvasEdgeTypeDerivedOutput) {
      throw const ProductionCanvasPackageException('unsupported');
    }
    if (!byId.containsKey(edge.sourceNodeId) ||
        !byId.containsKey(edge.targetNodeId)) {
      throw const ProductionCanvasPackageException('unsupported');
    }
  }
  final media = Directory(p.join(staging.path, 'media'));
  await media.create();
  final queued =
      <({AssetRow asset, File source, String extension, int length})>[];
  for (final id in referenced) {
    final asset = await canvas.library.database.assetDao.getAsset(id);
    if (asset == null || asset.path == null) {
      _log.info('export stage=media result=missing asset=$id');
      throw const ProductionCanvasPackageException('missing_media');
    }
    final extension = p.extension(asset.path!).toLowerCase();
    final format = productionMediaFormats[extension];
    if (format == null || format.$1 != asset.type) {
      throw const ProductionCanvasPackageException('unsupported');
    }
    if (!_purposeKnown(asset.purpose)) {
      throw const ProductionCanvasPackageException('unsupported');
    }
    late final File source;
    try {
      source = File(canvas.library.resolve(asset));
    } on MediaException {
      _log.info('export stage=media result=missing asset=$id');
      throw const ProductionCanvasPackageException('missing_media');
    }
    final length = await source.exists() ? await source.length() : 0;
    if (length == 0) {
      _log.info('export stage=media result=missing asset=$id');
      throw const ProductionCanvasPackageException('missing_media');
    }
    queued.add((
      asset: asset,
      source: source,
      extension: extension,
      length: length,
    ));
  }
  final assets = <Map<String, Object?>>[];
  final total = queued.fold<int>(0, (sum, item) => sum + item.length);
  var copied = 0;
  for (var index = 0; index < queued.length; index++) {
    final item = queued[index];
    final name = '${(index + 1).toString().padLeft(4, '0')}${item.extension}';
    final destination = p.join(media.path, name);
    if (onProgress == null) {
      await item.source.copy(destination);
    } else {
      final start = copied;
      await _copyWithProgress(item.source, destination, (bytes) {
        onProgress(total == 0 ? 1 : (start + bytes) / total);
      });
    }
    copied += item.length;
    onProgress?.call(total == 0 ? 1 : copied / total);
    assets.add({
      'id': item.asset.id,
      'name': _portableAssetName(item.asset.name, 'media/$name'),
      'purpose': item.asset.purpose,
      'file': 'media/$name',
      'in_library': item.asset.inLibrary,
    });
  }
  if (queued.isEmpty) {
    onProgress?.call(1);
  }
  final root = await canvas.db.screenplayDao.getRoot();
  if (root == null ||
      !ProductionSettings.ratios.contains(root.ratio) ||
      !ProductionSettings.resolutions.contains(root.resolution)) {
    throw const ProductionCanvasPackageException('unsupported');
  }
  final manifest = {
    'format': productionCanvasPackageFormat,
    'version': _version,
    'title': title,
    'settings': {
      'style_id': root.styleId,
      'ratio': root.ratio,
      'resolution': root.resolution,
    },
    'nodes': [
      for (final node in nodes)
        _nodeJson(node, clips[node.id], documents[node.id]),
    ],
    'edges': [
      for (final edge in stored)
        {
          'source_id': edge.sourceNodeId,
          'target_id': edge.targetNodeId,
          'type': edge.type,
        },
    ],
    'assets': assets,
  };
  await File(
    p.join(staging.path, 'manifest.json'),
  ).writeAsString(jsonEncode(manifest));
  _log.info(
    'export stage=read result=success nodes=${nodes.length} assets=${assets.length}',
  );
}

Future<void> _copyWithProgress(
  File source,
  String destination,
  void Function(int copied) onCopied,
) async {
  final sink = File(destination).openWrite();
  var copied = 0;
  try {
    await for (final chunk in source.openRead()) {
      sink.add(chunk);
      copied += chunk.length;
      onCopied(copied);
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
}

Map<String, Object?> _nodeJson(
  CanvasNode node,
  ProductionClipRow? clip,
  Object? document,
) {
  if (node.isGenerationNode) {
    if (clip == null) {
      throw const ProductionCanvasPackageException('unsupported');
    }
    _requirePromptRefs(
      clip.prompt,
      clip.inputs.map((input) => input.id).toSet(),
    );
  } else if (clip != null ||
      (node.type == canvasNodeTypeMedia && node.mediaAssetId == null) ||
      (node.type == canvasNodeTypeStaging && document == null) ||
      (node.type == canvasNodeTypeEditing && document == null)) {
    throw const ProductionCanvasPackageException('unsupported');
  }
  if (!_knownNodeType(node.type)) {
    throw const ProductionCanvasPackageException('unsupported');
  }
  return {
    'id': node.id,
    'type': node.type,
    'title': node.title,
    'content': node.content,
    'x': node.x,
    'y': node.y,
    'width': node.width,
    'height': node.height,
    'z': node.zIndex,
    'sort': node.sortOrder,
    'parent_id': node.parentId,
    'style': node.style,
    'clip': clip == null
        ? null
        : {
            'title': clip.title,
            'prompt': clip.prompt,
            'provider_id': clip.providerId,
            'model_id': clip.modelId,
            'reference_mode': clip.referenceMode,
            'duration_ms': clip.durationMs,
            'generate_audio': clip.generateAudio,
            'ratio': clip.ratio,
            'resolution': clip.resolution,
            'style_selection': clip.styleSelection,
            'inputs': clip.inputs.map((input) => input.toJson()).toList(),
            'adopted_asset_id': clip.adoptedAssetId,
          },
    'asset_id': node.mediaAssetId,
    'staging': node.type == canvasNodeTypeStaging ? document : null,
    'editing': node.type == canvasNodeTypeEditing ? document : null,
  };
}

bool _knownNodeType(String type) => {
  canvasNodeTypeText,
  canvasNodeTypeVideo,
  canvasNodeTypeImage,
  canvasNodeTypeAudio,
  canvasNodeTypeMedia,
  canvasNodeTypeGroup,
  canvasNodeTypeStaging,
  canvasNodeTypeEditing,
}.contains(type);

void _requirePromptRefs(String prompt, Set<String> inputIds) {
  final StoryboardPrompt parsed;
  try {
    parsed = StoryboardPrompt.parse(prompt);
  } on FormatException {
    throw const ProductionCanvasPackageException('unsupported');
  }
  for (final part in parsed.references) {
    if (!inputIds.contains(part.inputId)) {
      throw const ProductionCanvasPackageException('unsupported');
    }
  }
}

Future<Map<String, Object?>> _documents(
  ProductionCanvasService canvas,
  List<CanvasNode> nodes,
) async {
  final documents = <String, Object?>{};
  for (final node in nodes) {
    if (node.stagingId != null) {
      final staging = await canvas.db.screenplayDao.getStaging(node.stagingId!);
      if (staging?.document == null) {
        throw const ProductionCanvasPackageException('unsupported');
      }
      documents[node.id] = _documentFormat(
        staging!.document!,
        'reveric.director',
        'director',
      );
    }
    if (node.editingId != null) {
      final editing = await canvas.db.editingDao.get(node.editingId!);
      if (editing == null) {
        throw const ProductionCanvasPackageException('unsupported');
      }
      documents[node.id] = _documentFormat(
        editing.document.toJson(),
        'reveric.editing',
        'editing',
      );
    }
  }
  return documents;
}

Set<String> _referencedAssets(
  List<CanvasNode> nodes,
  Map<String, ProductionClipRow> clips,
  Map<String, Object?> documents,
) {
  final ids = <String>{};
  for (final node in nodes) {
    final assetId = node.mediaAssetId;
    if (assetId != null) {
      ids.add(assetId);
    }
    final clip = clips[node.id];
    if (clip == null) {
      continue;
    }
    final adopted = clip.adoptedAssetId;
    if (adopted != null) {
      ids.add(adopted);
    }
    for (final input in clip.inputs) {
      if (input.refType == ProductionInputType.asset) {
        ids.add(input.refId);
      }
      final voice = input.voiceAssetId;
      if (voice != null) {
        ids.add(voice);
      }
    }
  }
  for (final document in documents.values) {
    _collectAssetIds(document, ids);
  }
  for (final node in nodes.where((node) => node.parentId != null)) {
    if (!isProductionGroupMemberType(node)) {
      throw const ProductionCanvasPackageException('unsupported');
    }
  }
  return ids;
}

void _collectAssetIds(Object? value, Set<String> ids) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key == 'asset_id' && entry.value is String) {
        if ((entry.value as String).isEmpty) {
          throw const ProductionCanvasPackageException('unsupported');
        }
        ids.add(entry.value as String);
      } else {
        _collectAssetIds(entry.value, ids);
      }
    }
  } else if (value is List) {
    for (final item in value) {
      _collectAssetIds(item, ids);
    }
  }
}

bool _purposeKnown(String value) =>
    AssetPurpose.values.any((purpose) => purpose.value == value);

Future<void> _extract(
  File zip,
  Directory dest,
  Directory scratch, {
  void Function(double progress)? onProgress,
}) async {
  if (!await zip.exists()) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  final source = p.extension(zip.path).toLowerCase() == '.zip'
      ? zip
      : await zip.copy(p.join(scratch.path, 'input.zip'));
  final input = InputFileStream(source.path);
  final headers = <ZipFileHeader>[];
  try {
    final directory = ZipDirectory();
    try {
      directory.read(input);
    } catch (error) {
      _log.warning(
        'import stage=zip result=invalid errorType=${error.runtimeType}',
      );
      throw const ProductionCanvasPackageException('invalid_package');
    }
    if (directory.filePosition < 0 ||
        directory.fileHeaders.isEmpty ||
        directory.fileHeaders.length > _maxEntries) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    var expanded = 0;
    for (final header in directory.fileHeaders) {
      if ((header.externalFileAttributes >> 16) & 0xf000 == 0xa000 ||
          (header.generalPurposeBitFlag & 1) != 0 ||
          (header.compressionMethod != 0 && header.compressionMethod != 8)) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
      _requireZipName(header.filename);
      expanded += header.uncompressedSize;
      if (expanded > _maxExpandedBytes) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
      headers.add(header);
    }
  } finally {
    await input.close();
  }
  await _streamExtract(source, dest, headers, onProgress: onProgress);
}

Future<void> _streamExtract(
  File zip,
  Directory dest,
  List<ZipFileHeader> headers, {
  void Function(double progress)? onProgress,
}) async {
  final handle = await zip.open();
  final ranges = <({ZipFileHeader header, int start})>[];
  try {
    for (final header in headers) {
      if (header.filename.endsWith('/')) {
        continue;
      }
      ranges.add((
        header: header,
        start: await _zipDataOffset(handle, header.localHeaderOffset),
      ));
    }
  } finally {
    await handle.close();
  }
  final total = ranges.fold<int>(
    0,
    (sum, range) => sum + range.header.uncompressedSize,
  );
  var done = 0;
  for (final range in ranges) {
    final header = range.header;
    final target = File(
      p.join(dest.path, p.joinAll(p.posix.split(header.filename))),
    );
    await target.parent.create(recursive: true);
    final raw = zip.openRead(range.start, range.start + header.compressedSize);
    final decoded = header.compressionMethod == 0
        ? raw
        : raw.transform(ZLibDecoder(raw: true));
    final sink = target.openWrite();
    var crc = 0;
    try {
      await for (final chunk in decoded) {
        crc = getCrc32(chunk, crc);
        sink.add(chunk);
        done += chunk.length;
        if (total > 0) {
          onProgress?.call((done / total).clamp(0.0, 1.0));
        }
      }
    } catch (error) {
      _log.warning(
        'import stage=extract result=invalid errorType=${error.runtimeType}',
      );
      throw const ProductionCanvasPackageException('invalid_package');
    } finally {
      await sink.close();
    }
    if (crc != header.crc32) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
  }
  onProgress?.call(1);
}

Future<int> _zipDataOffset(
  RandomAccessFile handle,
  int localHeaderOffset,
) async {
  await handle.setPosition(localHeaderOffset);
  final header = await handle.read(30);
  if (header.length != 30 ||
      header[0] != 0x50 ||
      header[1] != 0x4b ||
      header[2] != 0x03 ||
      header[3] != 0x04) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  final nameLength = header[26] | (header[27] << 8);
  final extraLength = header[28] | (header[29] << 8);
  return localHeaderOffset + 30 + nameLength + extraLength;
}

void _requireZipName(String name) {
  if (name.isEmpty ||
      name.contains('\\') ||
      name.startsWith('/') ||
      p.posix.isAbsolute(name)) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  final parts = p.posix.split(name);
  if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  final file = name.endsWith('/');
  if (file) {
    if (name != 'media/') {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    return;
  }
  if (name == 'manifest.json') {
    return;
  }
  if (parts.length != 2 ||
      parts.first != 'media' ||
      productionMediaFormat(parts.last) == null) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
}

Future<_Package> _readPackage(Directory root) async {
  final found = <String>{};
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (p.normalize(entity.path) != p.normalize(root.path) &&
        !p.isWithin(root.path, entity.path)) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final relative = p.posix.joinAll(
      p.split(p.relative(entity.path, from: root.path)),
    );
    if (entity is Link) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    if (entity is Directory) {
      if (relative != 'media') {
        throw const ProductionCanvasPackageException('invalid_package');
      }
      continue;
    }
    if (entity is! File) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    found.add(relative);
  }
  final manifestFile = File(p.join(root.path, 'manifest.json'));
  if (!await manifestFile.exists() ||
      await manifestFile.length() > _maxManifestBytes) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(await manifestFile.readAsString());
  } catch (error) {
    _log.warning(
      'import stage=parse result=invalid errorType=${error.runtimeType}',
    );
    throw const ProductionCanvasPackageException('invalid_package');
  }
  if (decoded is! Map) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  final package = _Package.parse(decoded.cast<String, Object?>());
  final expected = {
    'manifest.json',
    ...package.assets.map((asset) => asset.file),
  };
  if (found.length != expected.length || !found.containsAll(expected)) {
    if (package.assets.any((asset) => !found.contains(asset.file))) {
      throw const ProductionCanvasPackageException('missing_media');
    }
    throw const ProductionCanvasPackageException('invalid_package');
  }
  for (final asset in package.assets) {
    final file = File(p.join(root.path, asset.file));
    if (!p.isWithin(root.path, file.path) ||
        !await file.exists() ||
        await file.length() == 0) {
      throw const ProductionCanvasPackageException('missing_media');
    }
  }
  return package;
}

Future<ProductionCanvasPackageImport> _install(
  _Package package,
  Directory root, {
  required NovelActionsService actions,
  required MediaLibraryService library,
  required String fallbackTitle,
  required NovelContentDatabase Function(String path) openContent,
  required Future<void> Function(NovelContentDatabase database) releaseContent,
  void Function(double progress)? onProgress,
}) async {
  String? novelId;
  final createdAssets = <String>[];
  try {
    novelId = await _createWork(
      actions,
      package.title.trim().isEmpty
          ? fallbackTitle.trim()
          : package.title.trim(),
    );
    final novel = await actions.getNovel(novelId);
    final path = novel?.contentDatabasePath;
    if (path == null || path.isEmpty) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final content = openContent(path);
    try {
      final canvas = ProductionCanvasService(
        StoryboardService(content, contentKind: contentKindCanvas),
        library,
        novelId,
      );
      final canvasId = (await canvas.ensureCanvas('')).id;
      final assetIds = await _importAssets(
        package,
        root,
        library,
        novelId,
        createdAssets,
        onProgress: onProgress,
      );
      final dropped = await _writeCanvas(
        package,
        canvas,
        canvasId,
        assetIds,
        actions,
        content,
      );
      _log.info(
        'import stage=create result=success novel=$novelId '
        'nodes=${package.nodes.length} droppedStyles=$dropped',
      );
      return ProductionCanvasPackageImport(
        novelId: novelId,
        droppedStyles: dropped,
      );
    } finally {
      await releaseContent(content);
    }
  } catch (error, stackTrace) {
    _log.error(
      'import stage=write result=failed',
      error: error,
      stackTrace: stackTrace,
    );
    try {
      await _discard(actions, library, novelId, createdAssets);
    } catch (cleanup, cleanupStack) {
      _log.error(
        'import stage=cleanup result=failed',
        error: cleanup,
        stackTrace: cleanupStack,
      );
    }
    rethrow;
  }
}

Future<String> _createWork(NovelActionsService actions, String title) async {
  if (title.isEmpty) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  for (var attempt = 1; attempt <= 99; attempt++) {
    final candidate = attempt == 1 ? title : '$title ($attempt)';
    try {
      return await actions.createNovel(
        title: candidate,
        description: '',
        contentKind: contentKindCanvas,
        setNovelOnboardingEligible: false,
      );
    } on NovelTitleConflictException {
      if (attempt == 99) {
        rethrow;
      }
    }
  }
  throw const ProductionCanvasPackageException('invalid_package');
}

/// 包里的素材名和媒体文件使用同一个扩展名。显示名可以不带扩展名，导入和导出都按这个名字入库。
String _portableAssetName(String name, String packagedFile) {
  final extension = p.extension(packagedFile).toLowerCase();
  if (extension.isEmpty || p.extension(name).toLowerCase() == extension) {
    return name;
  }
  final stem = p.basenameWithoutExtension(name).trim();
  return '${stem.isEmpty ? 'media' : stem}$extension';
}

Future<Map<String, String>> _importAssets(
  _Package package,
  Directory root,
  MediaLibraryService library,
  String novelId,
  List<String> created, {
  void Function(double progress)? onProgress,
}) async {
  final ids = <String, String>{};
  final sizes = <int>[];
  var total = 0;
  for (final asset in package.assets) {
    final length = await File(p.join(root.path, asset.file)).length();
    sizes.add(length);
    total += length;
  }
  var done = 0;
  for (var index = 0; index < package.assets.length; index++) {
    final asset = package.assets[index];
    final length = sizes[index];
    final start = done;
    final imported = await library.importFile(
      File(p.join(root.path, asset.file)),
      name: _portableAssetName(asset.name, asset.file),
      novelId: novelId,
      purpose: asset.purpose,
      cancellation: MediaCancellation(),
      onProgress: onProgress == null || total == 0
          ? null
          : (value) =>
                onProgress(((start + value * length) / total).clamp(0, 1)),
    );
    ids[asset.id] = imported.id;
    created.add(imported.id);
    done += length;
    if (total > 0) {
      onProgress?.call((done / total).clamp(0.0, 1.0));
    }
  }
  onProgress?.call(1);
  return ids;
}

Future<int> _writeCanvas(
  _Package package,
  ProductionCanvasService canvas,
  String canvasId,
  Map<String, String> assetIds,
  NovelActionsService actions,
  NovelContentDatabase content,
) async {
  var dropped = 0;
  final overlay = WorkingOverlayService(
    content,
    NovelContentService(content),
    novelActionsService: actions,
  );
  final nodeIds = <String, String>{};
  final created = <String, CanvasNode>{};
  for (final node in package.nodes.where(
    (node) => node.type != canvasNodeTypeGroup,
  )) {
    final CanvasNode createdNode;
    switch (node.type) {
      case canvasNodeTypeText:
        createdNode = await canvas.addText(
          canvasId,
          title: node.title,
          content: node.content,
        );
      case canvasNodeTypeVideo:
        createdNode = await canvas.addFree(canvasId, overlay: overlay);
      case canvasNodeTypeImage:
        createdNode = await canvas.addImage(canvasId);
      case canvasNodeTypeAudio:
        createdNode = await canvas.addAudio(canvasId);
      case canvasNodeTypeMedia:
        createdNode = await canvas.addMedia(canvasId, assetIds[node.assetId]!);
      case canvasNodeTypeStaging:
        createdNode = await canvas.addDirector(canvasId, node.title);
      case canvasNodeTypeEditing:
        createdNode = await canvas.addEditing(
          canvasId,
          title: node.title,
          ratio: node.editingRatio,
        );
      default:
        throw const ProductionCanvasPackageException('invalid_package');
    }
    nodeIds[node.id] = createdNode.id;
    created[node.id] = createdNode;
  }
  for (final node in package.nodes.where((node) => node.clip != null)) {
    final clip = node.clip!;
    final current = (await canvas.shots.getShot(created[node.id]!.clipId!))!;
    final inputs = <Map<String, dynamic>>[];
    final inputIds = <String, String>{};
    for (final input in clip.inputs) {
      final newId = buildShortEntityId(ShortEntityIdType.productionInput);
      inputIds[input.id] = newId;
      final refId = input.refType == ProductionInputType.node.name
          ? nodeIds[input.refId]
          : assetIds[input.refId];
      if (refId == null) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
      final voice = input.voiceAssetId == null
          ? null
          : assetIds[input.voiceAssetId!];
      if (input.voiceAssetId != null && voice == null) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
      inputs.add({
        'id': newId,
        'ref_type': input.refType,
        'ref_id': refId,
        'role': input.role,
        'voice_asset_id': ?voice,
      });
    }
    final style = await _keepStyle(canvas, clip.styleSelection);
    if (style.dropped) {
      dropped += 1;
    }
    final values = canvas.shots.snapshot(current);
    values
      ..['episode_id'] = ''
      ..['character_id'] = null
      ..['location_id'] = null
      ..['item_id'] = null
      ..['scene_id'] = null
      ..['sort_order'] = null
      ..['title'] = clip.title
      ..['prompt'] = _rewritePrompt(clip.prompt, inputIds)
      ..['provider_id'] = clip.providerId
      ..['model_id'] = clip.modelId
      ..['reference_mode'] = clip.referenceMode
      ..['duration_ms'] = clip.durationMs
      ..['generate_audio'] = clip.generateAudio
      ..['ratio'] = clip.ratio
      ..['resolution'] = clip.resolution
      ..['style_selection'] = style.id;
    await canvas.shots.apply(current.id, values);
    await canvas.shots.restoreInputs(current.id, inputs);
    final adopted = clip.adoptedAssetId;
    if (adopted != null) {
      await canvas.adopt(created[node.id]!.id, assetIds[adopted]!);
    }
  }
  await canvas.write(canvasId, () async {
    for (final node in package.nodes.where(
      (node) => node.type != canvasNodeTypeGroup,
    )) {
      await canvas.db.canvasDao.updateActiveNodeFields(
        nodeIds[node.id]!,
        CanvasNodesCompanion(
          title: Value(node.title),
          width: Value(node.width),
          height: Value(node.height),
          zIndex: Value(node.z),
          sortOrder: Value(node.sort),
        ),
      );
    }
  });
  for (final node in package.nodes.where(
    (node) => node.type != canvasNodeTypeGroup,
  )) {
    if (node.parentId != null &&
        package.groupOf(node.parentId!) is _StoryboardGroup) {
      continue;
    }
    await canvas.move(nodeIds[node.id]!, node.x, node.y);
  }
  for (final node in package.nodes.where(
    (node) => node.type == canvasNodeTypeGroup,
  )) {
    final members =
        package.nodes.where((member) => member.parentId == node.id).toList()
          ..sort((a, b) => a.sort.compareTo(b.sort));
    final CanvasNode group;
    if (node.group is _StoryboardGroup) {
      final layout = node.group! as _StoryboardGroup;
      group = await canvas.groups.createStoryboard(
        canvasId,
        layout: StoryboardGroupLayout(
          cols: layout.cols,
          rows: layout.rows,
          ratio: layout.ratio,
          numbered: layout.numbered,
        ),
        origin: Offset(node.x, node.y),
        memberIds: const [],
        title: node.title,
      );
      for (final member in members) {
        await canvas.groups.attachToSlot(
          group.id,
          nodeIds[member.id]!,
          member.sort,
        );
      }
    } else {
      group = await canvas.groups.createFree(
        canvasId,
        frame: Rect.fromLTWH(node.x, node.y, node.width!, node.height!),
        memberIds: [for (final member in members) nodeIds[member.id]!],
        title: node.title,
        style: node.style,
      );
    }
    nodeIds[node.id] = group.id;
    await canvas.write(group.id, () async {
      await canvas.db.canvasDao.updateActiveNodeFields(
        group.id,
        CanvasNodesCompanion(
          zIndex: Value(node.z),
          sortOrder: Value(node.sort),
          style: Value(node.style ?? group.style),
        ),
      );
    });
  }
  for (final node in package.nodes) {
    if (node.staging != null) {
      final document = DirectorDocument.fromJson(
        _documentFormat(
          _remapAssets(node.staging!, assetIds),
          'director',
          'reveric.director',
        ),
      );
      await canvas.db.screenplayDao.saveStaging(
        created[node.id]!.stagingId!,
        document.toJson(),
        title: node.title,
        savedAt: DateTime.now(),
      );
    }
    if (node.editing != null) {
      final document = EditingDocument.fromJson(
        _documentFormat(
          _remapAssets(node.editing!, assetIds),
          'editing',
          'reveric.editing',
        ),
      );
      await canvas.db.editingDao.save(
        created[node.id]!.editingId!,
        expectedRevision: 0,
        document: document,
        title: node.title,
      );
    }
  }
  if (package.edges.isNotEmpty) {
    await canvas.write(canvasId, () async {
      for (final edge in package.edges) {
        try {
          await insertWithShortEntityId(
            type: ShortEntityIdType.canvasEdge,
            tableName: 'canvas_edges',
            idExists: canvas.db.canvasDao.edgeIdExists,
            insert: (id) => canvas.db
                .into(canvas.db.canvasEdges)
                .insert(
                  CanvasEdgesCompanion.insert(
                    id: id,
                    canvasId: canvasId,
                    sourceNodeId: nodeIds[edge.sourceId]!,
                    targetNodeId: nodeIds[edge.targetId]!,
                    type: Value(edge.type),
                  ),
                ),
          );
        } catch (error, stackTrace) {
          _log.error(
            '[DB] table=canvas_edges op=INSERT',
            error: error,
            stackTrace: stackTrace,
          );
          rethrow;
        }
      }
    });
  }
  await canvas.shots.saveSettings({
    'ratio': package.ratio,
    'resolution': package.resolution,
  });
  final rootStyle = await _keepStyle(canvas, package.styleId);
  if (rootStyle.dropped) {
    dropped += 1;
  }
  if (rootStyle.id != null) {
    await canvas.setScreenplayStyle(rootStyle.id);
  }
  return dropped;
}

Future<({String? id, bool dropped})> _keepStyle(
  ProductionCanvasService canvas,
  String? styleId,
) async {
  if (styleId == null || styleId == 'none') {
    return (id: styleId, dropped: false);
  }
  if (isProductionStylePresetRef(styleId)) {
    final preset = productionStylePreset(
      styleId.substring(productionStylePresetPrefix.length),
    );
    if (preset == null) {
      return (id: null, dropped: true);
    }
    return (id: styleId, dropped: false);
  }
  final style = await canvas.library.database.productionStyleDao.getStyle(
    styleId,
  );
  if (style == null) {
    return (id: null, dropped: true);
  }
  return (id: styleId, dropped: false);
}

String _rewritePrompt(String prompt, Map<String, String> inputIds) {
  final parsed = StoryboardPrompt.parse(prompt);
  final buffer = StringBuffer();
  for (final part in parsed.parts) {
    if (!part.isReference) {
      buffer.write(part.text);
      continue;
    }
    final next = inputIds[part.inputId];
    if (next == null) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    buffer.write(StoryboardPrompt.reference(next, part.label!));
  }
  return buffer.toString();
}

// 仅转换打包边界的文档标识，应用内文档继续使用各自的存储契约。
Map<String, dynamic> _documentFormat(
  Map<String, dynamic> document,
  String expected,
  String portable,
) {
  if (document['format'] != expected) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  return {...document, 'format': portable};
}

Map<String, dynamic> _remapAssets(
  Map<String, dynamic> value,
  Map<String, String> assetIds,
) {
  Object? remap(Object? current) {
    if (current is Map) {
      return <String, dynamic>{
        for (final entry in current.entries)
          entry.key.toString(): entry.key == 'asset_id' && entry.value is String
              ? assetIds[entry.value] ??
                    (throw const ProductionCanvasPackageException(
                      'invalid_package',
                    ))
              : remap(entry.value),
      };
    }
    if (current is List) {
      return [for (final item in current) remap(item)];
    }
    return current;
  }

  return remap(value)! as Map<String, dynamic>;
}

Future<void> _discard(
  NovelActionsService actions,
  MediaLibraryService library,
  String? novelId,
  List<String> assetIds,
) async {
  for (final id in assetIds) {
    try {
      await library.delete(id);
    } catch (error, stackTrace) {
      _log.error(
        'import stage=cleanup result=failed asset=$id',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
  if (novelId == null) {
    return;
  }
  final novel = await actions.getNovel(novelId);
  if (novel != null) {
    await actions.deleteNovel(novel);
  }
}

class _Package {
  _Package({
    required this.title,
    required this.styleId,
    required this.ratio,
    required this.resolution,
    required this.nodes,
    required this.edges,
    required this.assets,
  });
  final String title;
  final String? styleId;
  final String ratio;
  final String resolution;
  final List<_Node> nodes;
  final List<_Edge> edges;
  final List<_Asset> assets;

  _Group? groupOf(String id) {
    for (final node in nodes) {
      if (node.id == id) {
        return node.group;
      }
    }
    return null;
  }

  static _Package parse(Map<String, Object?> json) {
    _exact(json, const {
      'format',
      'version',
      'title',
      'settings',
      'nodes',
      'edges',
      'assets',
    });
    if (json['format'] != productionCanvasPackageFormat ||
        json['version'] != _version ||
        json['title'] is! String) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final settings = _map(json['settings']);
    _exact(settings, const {'style_id', 'ratio', 'resolution'});
    final styleId = settings['style_id'];
    final ratio = settings['ratio'];
    final resolution = settings['resolution'];
    if ((styleId != null && styleId is! String) ||
        styleId == 'none' ||
        ratio is! String ||
        resolution is! String ||
        !ProductionSettings.ratios.contains(ratio) ||
        !ProductionSettings.resolutions.contains(resolution)) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final nodeList = _list(json['nodes']);
    if (nodeList.isEmpty) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final nodes = [for (final node in nodeList) _Node.parse(_map(node))];
    if (nodes.map((node) => node.id).toSet().length != nodes.length) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final byId = {for (final node in nodes) node.id: node};
    for (final node in nodes) {
      final parent = node.parentId == null ? null : byId[node.parentId];
      if (node.parentId != null &&
          (parent == null || parent.type != canvasNodeTypeGroup)) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
      if (parent != null &&
          node.type != canvasNodeTypeImage &&
          node.type != canvasNodeTypeMedia) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
      for (final input in node.clip?.inputs ?? const <_Input>[]) {
        if (input.refType != ProductionInputType.node.name) {
          continue;
        }
        final target = byId[input.refId];
        if (target == null ||
            (input.role == 'prompt') != (target.type == canvasNodeTypeText)) {
          throw const ProductionCanvasPackageException('invalid_package');
        }
      }
      if (node.group is _StoryboardGroup) {
        final layout = node.group! as _StoryboardGroup;
        final slots = nodes
            .where((member) => member.parentId == node.id)
            .map((member) => member.sort)
            .toList();
        if (slots.toSet().length != slots.length ||
            slots.any(
              (slot) => slot < 0 || slot >= layout.cols * layout.rows,
            )) {
          throw const ProductionCanvasPackageException('invalid_package');
        }
      }
    }
    final edges = [
      for (final edge in _list(json['edges'])) _Edge.parse(_map(edge)),
    ];
    for (final edge in edges) {
      if (!byId.containsKey(edge.sourceId) ||
          !byId.containsKey(edge.targetId)) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
    }
    final assets = [
      for (final asset in _list(json['assets'])) _Asset.parse(_map(asset)),
    ];
    if (assets.map((asset) => asset.id).toSet().length != assets.length ||
        assets.map((asset) => asset.file).toSet().length != assets.length) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final referenced = <String>{};
    for (final node in nodes) {
      if (node.assetId != null) {
        referenced.add(node.assetId!);
      }
      final clip = node.clip;
      if (clip?.adoptedAssetId != null) {
        referenced.add(clip!.adoptedAssetId!);
        final adopted = assets.where(
          (asset) => asset.id == clip.adoptedAssetId,
        );
        if (adopted.isEmpty || adopted.single.type != node.type) {
          throw const ProductionCanvasPackageException('invalid_package');
        }
      }
      for (final input in clip?.inputs ?? const <_Input>[]) {
        if (input.refType == ProductionInputType.asset.name) {
          referenced.add(input.refId);
        }
        if (input.voiceAssetId != null) {
          referenced.add(input.voiceAssetId!);
        }
      }
      _collectReferenced(node.staging, referenced);
      _collectReferenced(node.editing, referenced);
    }
    if (referenced.length != assets.length ||
        !referenced.containsAll(assets.map((asset) => asset.id))) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    for (final node in nodes.where(
      (node) => node.parentId != null && node.type == canvasNodeTypeMedia,
    )) {
      final asset = assets.where((item) => item.id == node.assetId);
      if (asset.length != 1 || asset.single.type != 'image') {
        throw const ProductionCanvasPackageException('invalid_package');
      }
    }
    return _Package(
      title: json['title']! as String,
      styleId: styleId as String?,
      ratio: ratio,
      resolution: resolution,
      nodes: nodes,
      edges: edges,
      assets: assets,
    );
  }
}

void _collectReferenced(Object? value, Set<String> ids) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key == 'asset_id' && entry.value is String) {
        ids.add(entry.value as String);
      } else {
        _collectReferenced(entry.value, ids);
      }
    }
  } else if (value is List) {
    for (final item in value) {
      _collectReferenced(item, ids);
    }
  }
}

class _Node {
  _Node({
    required this.id,
    required this.type,
    required this.title,
    required this.content,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.z,
    required this.sort,
    required this.parentId,
    required this.style,
    required this.clip,
    required this.assetId,
    required this.staging,
    required this.editing,
    required this.group,
    required this.editingRatio,
  });
  final String id;
  final String type;
  final String title;
  final String content;
  final double x;
  final double y;
  final double? width;
  final double? height;
  final int z;
  final int sort;
  final String? parentId;
  final Map<String, dynamic>? style;
  final _Clip? clip;
  final String? assetId;
  final Map<String, dynamic>? staging;
  final Map<String, dynamic>? editing;
  final _Group? group;
  final String? editingRatio;

  static _Node parse(Map<String, Object?> json) {
    _exact(json, const {
      'id',
      'type',
      'title',
      'content',
      'x',
      'y',
      'width',
      'height',
      'z',
      'sort',
      'parent_id',
      'style',
      'clip',
      'asset_id',
      'staging',
      'editing',
    });
    final type = json['type'];
    if (json['id'] is! String ||
        (json['id']! as String).isEmpty ||
        type is! String ||
        !_knownNodeType(type) ||
        json['title'] is! String ||
        json['content'] is! String ||
        json['z'] is! int ||
        json['sort'] is! int) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final x = _finite(json['x']);
    final y = _finite(json['y']);
    final width = _positive(json['width']);
    final height = _positive(json['height']);
    final parentId = json['parent_id'];
    final style = json['style'] == null ? null : _stringMap(json['style']);
    final clip = json['clip'] == null ? null : _Clip.parse(_map(json['clip']));
    final assetId = json['asset_id'];
    final staging = json['staging'] == null
        ? null
        : _stringMap(json['staging']);
    final editing = json['editing'] == null
        ? null
        : _stringMap(json['editing']);
    if (parentId != null && parentId is! String) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    if (assetId != null && (assetId is! String || assetId.isEmpty)) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final generation = {
      canvasNodeTypeVideo,
      canvasNodeTypeImage,
      canvasNodeTypeAudio,
    }.contains(type);
    if (generation != (clip != null) ||
        (type == canvasNodeTypeMedia) != (assetId != null) ||
        (type == canvasNodeTypeStaging) != (staging != null) ||
        (type == canvasNodeTypeEditing) != (editing != null) ||
        (type == canvasNodeTypeGroup &&
            (clip != null ||
                assetId != null ||
                staging != null ||
                editing != null ||
                parentId != null ||
                width == null ||
                height == null))) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    _Group? group;
    String? editingRatio;
    if (type == canvasNodeTypeGroup) {
      try {
        final layout = ProductionGroupLayout.fromStyle(style);
        group = switch (layout) {
          FreeGroupLayout() => const _FreeGroup(),
          StoryboardGroupLayout() => _StoryboardGroup(
            cols: layout.cols,
            rows: layout.rows,
            ratio: layout.ratio,
            numbered: layout.numbered,
          ),
        };
      } on FormatException {
        throw const ProductionCanvasPackageException('invalid_package');
      }
    }
    if (type == canvasNodeTypeEditing) {
      final ratio = editing!['ratio'];
      if (ratio is! String) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
      editingRatio = ratio;
    }
    if (!x.isFinite || !y.isFinite) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    return _Node(
      id: json['id']! as String,
      type: type,
      title: json['title']! as String,
      content: json['content']! as String,
      x: x,
      y: y,
      width: width,
      height: height,
      z: json['z']! as int,
      sort: json['sort']! as int,
      parentId: parentId as String?,
      style: style,
      clip: clip,
      assetId: assetId as String?,
      staging: staging,
      editing: editing,
      group: group,
      editingRatio: editingRatio,
    );
  }
}

class _Clip {
  _Clip({
    required this.title,
    required this.prompt,
    required this.providerId,
    required this.modelId,
    required this.referenceMode,
    required this.durationMs,
    required this.generateAudio,
    required this.ratio,
    required this.resolution,
    required this.styleSelection,
    required this.inputs,
    required this.adoptedAssetId,
  });
  final String title;
  final String prompt;
  final String? providerId;
  final String? modelId;
  final String referenceMode;
  final int? durationMs;
  final bool? generateAudio;
  final String ratio;
  final String resolution;
  final String? styleSelection;
  final List<_Input> inputs;
  final String? adoptedAssetId;

  static _Clip parse(Map<String, Object?> json) {
    _exact(json, const {
      'title',
      'prompt',
      'provider_id',
      'model_id',
      'reference_mode',
      'duration_ms',
      'generate_audio',
      'ratio',
      'resolution',
      'style_selection',
      'inputs',
      'adopted_asset_id',
    });
    final provider = json['provider_id'];
    final model = json['model_id'];
    final duration = json['duration_ms'];
    final audio = json['generate_audio'];
    final style = json['style_selection'];
    final adopted = json['adopted_asset_id'];
    final mode = json['reference_mode'];
    final ratio = json['ratio'];
    final resolution = json['resolution'];
    if (json['title'] is! String ||
        json['prompt'] is! String ||
        (provider != null && provider is! String) ||
        (model != null && model is! String) ||
        (provider == null) != (model == null) ||
        (provider is String &&
            (provider.trim().isEmpty || (model as String).trim().isEmpty)) ||
        mode is! String ||
        !{
          VideoMode.reference.name,
          VideoMode.first_last_frame.name,
        }.contains(mode) ||
        (duration != null && (duration is! int || duration <= 0)) ||
        (audio != null && audio is! bool) ||
        ratio is! String ||
        resolution is! String ||
        resolution.trim().isEmpty ||
        (style != null && style is! String) ||
        (adopted != null && (adopted is! String || adopted.isEmpty))) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final inputs = [
      for (final input in _list(json['inputs'])) _Input.parse(_map(input)),
    ];
    if (inputs.map((input) => input.id).toSet().length != inputs.length) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    try {
      StoryboardPrompt.parse(json['prompt']! as String);
    } on FormatException {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    return _Clip(
      title: json['title']! as String,
      prompt: json['prompt']! as String,
      providerId: provider as String?,
      modelId: model as String?,
      referenceMode: mode,
      durationMs: duration as int?,
      generateAudio: audio as bool?,
      ratio: ratio,
      resolution: resolution,
      styleSelection: style as String?,
      inputs: inputs,
      adoptedAssetId: adopted as String?,
    );
  }
}

class _Input {
  _Input({
    required this.id,
    required this.refType,
    required this.refId,
    required this.role,
    required this.voiceAssetId,
  });
  final String id;
  final String refType;
  final String refId;
  final String role;
  final String? voiceAssetId;

  static _Input parse(Map<String, Object?> json) {
    const required = {'id', 'ref_type', 'ref_id', 'role'};
    final keys = json.keys.toSet();
    if (!keys.containsAll(required) ||
        keys.any((key) => key != 'voice_asset_id' && !required.contains(key))) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final voice = json['voice_asset_id'];
    if (json['id'] is! String ||
        (json['id']! as String).isEmpty ||
        json['ref_id'] is! String ||
        (json['ref_id']! as String).isEmpty ||
        json['ref_type'] is! String ||
        json['role'] is! String ||
        (voice != null && (voice is! String || voice.isEmpty))) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    try {
      ProductionInput.fromJson(json.cast<String, dynamic>());
    } on FormatException {
      throw const ProductionCanvasPackageException('invalid_package');
    } on ArgumentError {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    return _Input(
      id: json['id']! as String,
      refType: json['ref_type']! as String,
      refId: json['ref_id']! as String,
      role: json['role']! as String,
      voiceAssetId: voice as String?,
    );
  }
}

class _Edge {
  _Edge({required this.sourceId, required this.targetId, required this.type});
  final String sourceId;
  final String targetId;
  final String type;

  static _Edge parse(Map<String, Object?> json) {
    _exact(json, const {'source_id', 'target_id', 'type'});
    final type = json['type'];
    if (json['source_id'] is! String ||
        json['target_id'] is! String ||
        (type != canvasEdgeTypeStagingOutput &&
            type != canvasEdgeTypeDerivedOutput)) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    return _Edge(
      sourceId: json['source_id']! as String,
      targetId: json['target_id']! as String,
      type: type! as String,
    );
  }
}

class _Asset {
  _Asset({
    required this.id,
    required this.name,
    required this.purpose,
    required this.file,
    required this.inLibrary,
    required this.type,
  });
  final String id;
  final String name;
  final AssetPurpose purpose;
  final String file;
  final bool inLibrary;
  final String type;

  static _Asset parse(Map<String, Object?> json) {
    _exact(json, const {'id', 'name', 'purpose', 'file', 'in_library'});
    final file = json['file'];
    final purpose = json['purpose'];
    if (json['id'] is! String ||
        (json['id']! as String).isEmpty ||
        json['name'] is! String ||
        purpose is! String ||
        file is! String ||
        json['in_library'] is! bool) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final format = productionMediaFormat(file);
    final parts = p.posix.split(file);
    if (format == null || parts.length != 2 || parts.first != 'media') {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final match = AssetPurpose.values.where((item) => item.value == purpose);
    if (match.isEmpty) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    return _Asset(
      id: json['id']! as String,
      name: json['name']! as String,
      purpose: match.single,
      file: file,
      inLibrary: json['in_library']! as bool,
      type: format.$1,
    );
  }
}

sealed class _Group {
  const _Group();
}

final class _FreeGroup extends _Group {
  const _FreeGroup();
}

final class _StoryboardGroup extends _Group {
  const _StoryboardGroup({
    required this.cols,
    required this.rows,
    required this.ratio,
    required this.numbered,
  });
  final int cols;
  final int rows;
  final String ratio;
  final bool numbered;
}

void _exact(Map<dynamic, dynamic> json, Set<String> keys) {
  if (json.length != keys.length || !keys.containsAll(json.keys)) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  return value.cast<String, Object?>();
}

Map<String, dynamic> _stringMap(Object? value) {
  if (value is! Map) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  return value.map((key, item) => MapEntry(key.toString(), item));
}

List<Object?> _list(Object? value) {
  if (value is! List) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  return value;
}

double _finite(Object? value) {
  if (value is! num) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  return value.toDouble();
}

double? _positive(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! num || !value.isFinite || value <= 0) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  return value.toDouble();
}
