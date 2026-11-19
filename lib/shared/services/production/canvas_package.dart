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
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import '../../database/app_database.dart';
import '../../database/novel_content_database.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_chat_models.dart';
import '../../models/ai_session_mode.dart';
import '../../models/ask_user_models.dart';
import '../../models/asset_purpose.dart';
import '../../models/content_kind.dart';
import '../../models/director/document.dart';
import '../../models/editing/document.dart';
import '../../models/production/media.dart';
import '../../models/production/settings.dart';
import '../../models/production/style.dart';
import '../../models/queued_chat_message.dart';
import '../../models/storyboard/prompt.dart';
import '../../models/user_message_presentation.dart';
import '../../models/video/request.dart';
import '../../utils/random_id.dart';
import '../../utils/short_entity_id.dart';
import '../../utils/short_entity_id_allocator.dart';
import '../../utils/storage_paths.dart';
import '../../utils/windows_safe_path.dart';
import '../ai/files/session_files.dart';
import '../ai/session_persistence.dart';
import '../ai/xml_utils.dart';
import '../backup_zip.dart';
import '../novel_actions.dart';
import '../novel_content.dart';
import '../screenplay_service.dart';
import '../storyboard/service.dart';
import '../working_overlay.dart';
import 'canvas_preview.dart';
import 'canvas_service.dart';
import 'ffmpeg_runner.dart';
import 'library_service.dart';
import 'media_service.dart';
import 'style_service.dart';

part 'canvas_package_conversations.dart';

const productionCanvasPackageFormat = 'production.canvas';
const _version = 1;
const _maxEntries = 10000;
const _maxManifestBytes = 32 * 1024 * 1024;
const _maxExpandedBytes = 8 * 1024 * 1024 * 1024;
const _maxGalleryZipBytes = 2 * 1024 * 1024 * 1024;

final _log = AppLogger.forModule('ProductionCanvasPackage');

class ProductionCanvasPackageException implements Exception {
  const ProductionCanvasPackageException(this.code, {this.subject});
  final String code;
  final String? subject;
}

class ProductionCanvasPackageFile {
  ProductionCanvasPackageFile._(this.file, this._directory, this._stage);

  final File file;
  final _CanvasPackageStage _stage;

  File? get cover => _stage.cover;
  int get nodeCount => _stage.nodeCount;
  int get assetCount => _stage.assetCount;
  int get conversationCount => _stage.conversations.sessions.length;
  int get conversationFileCount => _stage.conversations.files.length;
  List<ProductionCanvasPackageConversationSummary> get conversations =>
      _stage.conversations.summaries;
  List<String> get conversationFileNames => [
    for (final file in _stage.conversations.files) file.name,
  ];
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
    bool publicGallery = false,
    AiSessionPersistenceService? sessionPersistence,
    List<String> conversationIds = const [],
    void Function(double progress)? onProgress,
  }) async {
    await _requireCanvasWork(canvas, canvasId);
    final parent = await Directory.systemTemp.createTemp(
      'reveric_canvas_package_',
    );
    try {
      final staging = Directory(p.join(parent.path, 'stage'));
      await staging.create();
      final stage = await _writeStaging(
        canvas,
        canvasId,
        staging,
        title,
        publicGallery: publicGallery,
        sessionPersistence: sessionPersistence,
        conversationIds: conversationIds,
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
      if (publicGallery && await zip.length() > _maxGalleryZipBytes) {
        throw const ProductionCanvasPackageException('package_too_large');
      }
      onProgress?.call(1);
      await staging.delete(recursive: true);
      return ProductionCanvasPackageFile._(zip, parent, stage);
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
      final archive = await _CanvasPackageArchive.open(zip);
      final package = await archive.readManifest(parent);
      final extracted = Directory(p.join(parent.path, 'out'));
      await archive.extract(
        package.assets.map((asset) => asset.file),
        extracted,
        onProgress: onProgress == null
            ? null
            : (value) => onProgress((value * 0.6).clamp(0, 0.6)),
      );
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

  /// 直接从画廊已解包缓存目录安装新画布作品，无需重新下载或保留压缩包。
  Future<ProductionCanvasPackageImport> importFromCacheDirectory({
    required Directory cacheDirectory,
    required NovelActionsService actions,
    required MediaLibraryService library,
    required String fallbackTitle,
    required NovelContentDatabase Function(String path) openContent,
    required Future<void> Function(NovelContentDatabase database)
    releaseContent,
    void Function(double progress)? onProgress,
  }) async {
    final meta = await _readPreviewCacheMeta(cacheDirectory);
    final manifestFile = _packageFile(cacheDirectory, 'manifest.json');
    if (!await manifestFile.exists()) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final package = _Package.parse(await _readPackageJson(manifestFile));
    final workspaceRoot = Directory(p.join(cacheDirectory.path, 'workspace'));
    File resolveAssetFile(_Asset asset) {
      final stored = meta.assetFiles[asset.id];
      if (stored == null) {
        throw const ProductionCanvasPackageException('missing_media');
      }
      return _resolveCachedWorkspaceFile(workspaceRoot, stored);
    }

    for (final asset in package.assets) {
      final file = resolveAssetFile(asset);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file || stat.size == 0) {
        throw const ProductionCanvasPackageException('missing_media');
      }
    }
    _log.info(
      'import stage=cache_read result=success nodes=${package.nodes.length} '
      'assets=${package.assets.length}',
    );
    return _install(
      package,
      cacheDirectory,
      resolveAssetFile: resolveAssetFile,
      actions: actions,
      library: library,
      fallbackTitle: fallbackTitle,
      openContent: openContent,
      releaseContent: releaseContent,
      onProgress: onProgress,
    );
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

Future<
  ({
    List<CanvasNode> nodes,
    List<ProductionConnection> edges,
    Map<String, ProductionClipRow> clips,
    Map<String, Object?> documents,
  })
>
_readPackageCanvas(ProductionCanvasService canvas, String canvasId) async {
  final content = await canvas.content(canvasId);
  final nodes = content.nodes
      .where((node) => node.type != canvasNodeTypeScene)
      .toList();
  if (nodes.isEmpty) {
    throw const ProductionCanvasPackageException('empty');
  }
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
  return (
    nodes: nodes,
    edges: content.edges,
    clips: clips,
    documents: await _documents(canvas, nodes),
  );
}

/// 初始发布面板预览当前画布；最终封面和数据仍由冻结的归档生成。
Future<
  ({
    int nodeCount,
    int assetCount,
    int sourceBytes,
    ProductionCanvasPreviewResult preview,
  })
>
inspectProductionCanvasPublication({
  required ProductionCanvasService canvas,
  required String canvasId,
}) async {
  await _requireCanvasWork(canvas, canvasId);
  final source = await canvas.db.transaction(
    () => _readPackageCanvas(canvas, canvasId),
  );
  final references = _referencedAssets(
    source.nodes,
    source.clips,
    source.documents,
  );
  final files = <String, ({AssetRow asset, File file})>{};
  var size = 0;
  for (final id in references) {
    final asset = await canvas.library.database.assetDao.getAsset(id);
    if (asset?.path == null) {
      throw ProductionCanvasPackageException(
        'missing_media',
        subject: asset?.name,
      );
    }
    final file = File(canvas.library.resolve(asset!));
    size += await file.length();
    files[id] = (asset: asset, file: file);
  }
  final preview = await renderProductionCanvasCover(
    canvas: canvas,
    nodes: source.nodes,
    edges: source.edges,
    clips: source.clips,
    assets: files,
  );
  return (
    nodeCount: source.nodes.length,
    assetCount: files.length,
    sourceBytes: size,
    preview: preview,
  );
}

/// 这张画布上可当作封面的图片：放上画布的图片，以及图片节点已采用的生成图。
Future<List<({String id, String name, File file})>>
listProductionCanvasCoverImages({
  required ProductionCanvasService canvas,
  required String canvasId,
}) async {
  final content = await canvas.content(canvasId);
  final clipIds = [for (final node in content.nodes) ?node.clipId];
  final clips = clipIds.isEmpty
      ? const <ProductionClipRow>[]
      : await (canvas.db.select(
          canvas.db.productionClips,
        )..where((row) => row.id.isIn(clipIds))).get();
  final adopted = {for (final clip in clips) clip.id: clip.adoptedAssetId};
  final ordered = [...content.nodes]
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  final ids = <String>[];
  final seen = <String>{};
  for (final node in ordered) {
    final String? assetId;
    if (node.type == canvasNodeTypeMedia) {
      assetId = node.mediaAssetId;
    } else if (node.type == canvasNodeTypeImage) {
      assetId = node.clipId == null ? null : adopted[node.clipId];
    } else {
      assetId = null;
    }
    if (assetId != null && seen.add(assetId)) {
      ids.add(assetId);
    }
  }
  final images = <({String id, String name, File file})>[];
  for (final id in ids) {
    final asset = await canvas.library.database.assetDao.getAsset(id);
    final stored = asset?.path;
    if (asset?.type != 'image' || stored == null) {
      continue;
    }
    final file = File(canvas.library.resolve(asset!));
    if (!await file.exists() || await file.length() == 0) {
      continue;
    }
    images.add((id: asset.id, name: asset.name, file: file));
  }
  return images;
}

class _CanvasPackageStage {
  const _CanvasPackageStage({
    required this.cover,
    required this.nodeCount,
    required this.assetCount,
    required this.conversations,
  });

  final File? cover;
  final int nodeCount;
  final int assetCount;
  final _PackagedConversations conversations;
}

Future<_CanvasPackageStage> _writeStaging(
  ProductionCanvasService canvas,
  String canvasId,
  Directory staging,
  String title, {
  required bool publicGallery,
  required AiSessionPersistenceService? sessionPersistence,
  required List<String> conversationIds,
  void Function(double progress)? onProgress,
}) async {
  final sessions = await _selectPackageSessions(
    canvas,
    sessionPersistence,
    conversationIds,
  );
  final (source, root, messages) = await canvas.db.transaction(() async {
    final source = await _readPackageCanvas(canvas, canvasId);
    final root = await canvas.db.screenplayDao.getRoot();
    final messages = <String, List<AiMessage>>{
      for (final session in sessions)
        session.id: (await sessionPersistence!.loadSessionMessages(
          sessionId: session.id,
          novelDatabase: canvas.db,
        )).messages.where(_packageMessageVisible).toList(),
    };
    return (source, root, messages);
  });
  final (:edges, :nodes, :clips, :documents) = source;
  final byId = {for (final node in nodes) node.id: node};
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
  final stored = edges.where((edge) => edge.inputId == null).toList();
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
      <({AssetRow asset, File source, String extension, FileStat stat})>[];
  for (final id in referenced) {
    final asset = await canvas.library.database.assetDao.getAsset(id);
    if (asset == null || asset.path == null) {
      _log.info('export stage=media result=missing asset=$id');
      throw ProductionCanvasPackageException(
        'missing_media',
        subject: asset?.name ?? id,
      );
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
      throw ProductionCanvasPackageException(
        'missing_media',
        subject: asset.name,
      );
    }
    final stat = await source.stat();
    if (stat.type != FileSystemEntityType.file || stat.size == 0) {
      _log.info('export stage=media result=missing asset=$id');
      throw ProductionCanvasPackageException(
        'missing_media',
        subject: asset.name,
      );
    }
    queued.add((
      asset: asset,
      source: source,
      extension: extension,
      stat: stat,
    ));
  }
  final assets = <Map<String, Object?>>[];
  final total = queued.fold<int>(0, (sum, item) => sum + item.stat.size);
  final sharedFiles = <String, String>{};
  final stagedAssets = <String, ({AssetRow asset, File file})>{};
  var copied = 0;
  for (var index = 0; index < queued.length; index++) {
    final item = queued[index];
    final name = '${(index + 1).toString().padLeft(4, '0')}${item.extension}';
    final destination = File(p.join(media.path, name));
    final start = copied;
    await _copyStablePackageFile(
      item.source,
      destination,
      expected: item.stat,
      subject: item.asset.name,
      code: 'missing_media',
      onCopied: onProgress == null
          ? null
          : (bytes) => onProgress((start + bytes) / total),
    );
    copied += item.stat.size;
    final archivePath = 'media/$name';
    sharedFiles[await item.source.resolveSymbolicLinks()] = archivePath;
    stagedAssets[item.asset.id] = (asset: item.asset, file: destination);
    assets.add({
      'id': item.asset.id,
      'name': _portableAssetName(item.asset.name, archivePath),
      'purpose': item.asset.purpose,
      'file': archivePath,
      'in_library': item.asset.inLibrary,
    });
  }
  final conversations = await _writePackageConversations(
    canvas,
    sessions,
    messages,
    staging,
    sharedFiles,
  );
  onProgress?.call(1);
  if (root == null ||
      !ProductionSettings.ratios.contains(root.ratio) ||
      !ProductionSettings.resolutions.contains(root.resolution)) {
    throw const ProductionCanvasPackageException('unsupported');
  }
  final styles = <Map<String, Object?>>[];
  final styleIds = {
    root.styleId,
    ...clips.values.map((clip) => clip.styleSelection),
  };
  for (final id in styleIds.nonNulls) {
    if (id == 'none' || isProductionStylePresetRef(id)) {
      continue;
    }
    final style = await canvas.library.database.productionStyleDao.getStyle(id);
    if (style == null) {
      if (publicGallery) {
        throw ProductionCanvasPackageException('missing_style', subject: id);
      }
      continue;
    }
    styles.add({
      'id': style.id,
      'name': style.name,
      'before': style.before,
      'after': style.after,
    });
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
        _nodeJson(
          node,
          clips[node.id],
          documents[node.id],
          publicGallery: publicGallery,
        ),
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
    if (styles.isNotEmpty) 'styles': styles,
    if (conversations.sessions.isNotEmpty) ...conversations.toJson(),
  };
  final manifestBytes = utf8.encode(jsonEncode(manifest));
  if (manifestBytes.length > _maxManifestBytes) {
    throw const ProductionCanvasPackageException('package_too_large');
  }
  await _packageFile(staging, 'manifest.json').writeAsBytes(manifestBytes);
  File? cover;
  if (publicGallery) {
    try {
      final preview = await renderProductionCanvasCover(
        canvas: canvas,
        nodes: nodes,
        edges: edges,
        clips: clips,
        assets: stagedAssets,
      );
      cover = await File(
        p.join(staging.parent.path, 'cover.jpg'),
      ).writeAsBytes(preview.jpeg);
    } catch (error, stackTrace) {
      _log.error(
        'export stage=cover result=failed',
        error: error,
        stackTrace: stackTrace,
      );
      throw const ProductionCanvasPackageException('cover_failed');
    }
  }
  _log.info(
    'export stage=read result=success nodes=${nodes.length} assets=${assets.length}',
  );
  return _CanvasPackageStage(
    cover: cover,
    nodeCount: nodes.length,
    assetCount: assets.length,
    conversations: conversations,
  );
}

Future<void> _copyStablePackageFile(
  File source,
  File target, {
  required FileStat expected,
  required String subject,
  required String code,
  void Function(int bytes)? onCopied,
}) async {
  var copied = 0;
  final sink = target.openWrite();
  try {
    await sink.addStream(
      source.openRead().map((chunk) {
        copied += chunk.length;
        if (copied > expected.size) {
          throw ProductionCanvasPackageException(code, subject: subject);
        }
        onCopied?.call(copied);
        return chunk;
      }),
    );
    await sink.flush();
  } finally {
    await sink.close();
  }
  final finalStat = await source.stat();
  if (copied != expected.size ||
      finalStat.size != expected.size ||
      finalStat.modified != expected.modified ||
      finalStat.type != FileSystemEntityType.file) {
    throw ProductionCanvasPackageException(code, subject: subject);
  }
}

Map<String, Object?> _nodeJson(
  CanvasNode node,
  ProductionClipRow? clip,
  Object? document, {
  required bool publicGallery,
}) {
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
            'provider_id': publicGallery ? null : clip.providerId,
            'model_id': publicGallery ? null : clip.modelId,
            if (publicGallery)
              'preview_generation': {
                'model': clip.modelId,
                'reference_mode': clip.referenceMode,
                'duration_ms': clip.durationMs,
                'generate_audio': clip.generateAudio,
                'ratio': clip.ratio,
                'resolution': clip.resolution,
              },
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

class _CanvasPackageArchive {
  _CanvasPackageArchive(this.source, this.headers, this.dataLimit);

  final File source;
  final Map<String, ZipFileHeader> headers;
  final int dataLimit;

  static Future<_CanvasPackageArchive> open(File zip) async {
    if (!await zip.exists()) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final input = InputFileStream(zip.path);
    try {
      final directory = ZipDirectory();
      directory.read(input);
      if (directory.filePosition < 0 ||
          directory.centralDirectoryOffset < 0 ||
          directory.centralDirectoryOffset > directory.filePosition ||
          directory.fileHeaders.isEmpty ||
          directory.fileHeaders.length > _maxEntries ||
          directory.totalCentralDirectoryEntries !=
              directory.fileHeaders.length) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
      final headers = <String, ZipFileHeader>{};
      final keys = <String>{};
      var expanded = 0;
      for (final header in directory.fileHeaders) {
        final name = header.filename;
        _requireZipName(name);
        final directoryEntry = name.endsWith('/');
        final key = directoryEntry ? name.substring(0, name.length - 1) : name;
        if (!keys.add(key.toLowerCase()) ||
            (header.externalFileAttributes >> 16) & 0xf000 == 0xa000 ||
            (header.generalPurposeBitFlag & 1) != 0 ||
            (header.compressionMethod != 0 && header.compressionMethod != 8) ||
            header.compressedSize < 0 ||
            header.uncompressedSize < 0 ||
            (directoryEntry && header.uncompressedSize != 0)) {
          throw const ProductionCanvasPackageException('invalid_package');
        }
        expanded += header.uncompressedSize;
        if (expanded > _maxExpandedBytes) {
          throw const ProductionCanvasPackageException('invalid_package');
        }
        if (!directoryEntry) {
          headers[name] = header;
        }
      }
      return _CanvasPackageArchive(
        zip,
        headers,
        directory.centralDirectoryOffset,
      );
    } on ProductionCanvasPackageException {
      rethrow;
    } catch (error) {
      _log.warning(
        'import stage=zip result=invalid errorType=${error.runtimeType}',
      );
      throw const ProductionCanvasPackageException('invalid_package');
    } finally {
      await input.close();
    }
  }

  Future<_Package> readManifest(Directory dest) async {
    const name = 'manifest.json';
    final manifest = headers[name];
    if (manifest == null || manifest.uncompressedSize > _maxManifestBytes) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    await extract([name], dest);
    final package = _Package.parse(
      await _readPackageJson(_packageFile(dest, name)),
    );
    for (final asset in package.assets) {
      if ((headers[asset.file]?.uncompressedSize ?? 0) == 0) {
        throw const ProductionCanvasPackageException('missing_media');
      }
    }
    for (final session in package.conversations.sessions) {
      final header = headers[session.file];
      if (header == null ||
          header.uncompressedSize == 0 ||
          header.uncompressedSize > _maxManifestBytes) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
    }
    for (final file in package.conversations.files) {
      if (headers[file.file]?.uncompressedSize != file.sizeBytes) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
    }
    return package;
  }

  Future<void> extract(
    Iterable<String> names,
    Directory dest, {
    void Function(double progress)? onProgress,
  }) async {
    final selected = names.toSet().map((name) => headers[name]!).toList();
    final total = selected.fold<int>(
      0,
      (sum, entry) => sum + entry.uncompressedSize,
    );
    final handle = await source.open();
    var done = 0;
    try {
      for (final header in selected) {
        final start = await _zipDataOffset(handle, header.localHeaderOffset);
        if (start > dataLimit || header.compressedSize > dataLimit - start) {
          throw const ProductionCanvasPackageException('invalid_package');
        }
        final target = _packageFile(dest, header.filename);
        await target.parent.create(recursive: true);
        final raw = source.openRead(start, start + header.compressedSize);
        final decoded = header.compressionMethod == 0
            ? raw
            : raw.transform(ZLibDecoder(raw: true));
        final sink = target.openWrite();
        var crc = 0;
        var written = 0;
        try {
          await sink.addStream(
            decoded.map((chunk) {
              written += chunk.length;
              done += chunk.length;
              if (written > header.uncompressedSize ||
                  done > total ||
                  done > _maxExpandedBytes) {
                throw const ProductionCanvasPackageException('invalid_package');
              }
              crc = getCrc32(chunk, crc);
              if (total > 0) {
                onProgress?.call(done / total);
              }
              return chunk;
            }),
          );
        } finally {
          await sink.close();
        }
        if (written != header.uncompressedSize || crc != header.crc32) {
          throw const ProductionCanvasPackageException('invalid_package');
        }
      }
    } on ProductionCanvasPackageException {
      rethrow;
    } catch (error) {
      _log.warning(
        'import stage=extract result=invalid errorType=${error.runtimeType}',
      );
      throw const ProductionCanvasPackageException('invalid_package');
    } finally {
      await handle.close();
    }
    onProgress?.call(1);
  }
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
  final path = name.endsWith('/') ? name.substring(0, name.length - 1) : name;
  final parts = path.split('/');
  if (parts.any(
    (part) =>
        part.isEmpty ||
        part.endsWith('.') ||
        part.endsWith(' ') ||
        RegExp(r'[\\:\x00-\x1f<>?"|*]').hasMatch(part) ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(part),
  )) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
}

File _packageFile(Directory root, String name) =>
    File(p.joinAll([root.path, ...name.split('/')]));

Future<Map<String, Object?>> _readPackageJson(File file) async {
  try {
    return _map(jsonDecode(await file.readAsString()));
  } on FormatException catch (error) {
    _log.warning(
      'import stage=parse result=invalid errorType=${error.runtimeType}',
    );
    throw const ProductionCanvasPackageException('invalid_package');
  }
}

Future<ProductionCanvasPackageImport> _install(
  _Package package,
  Directory root, {
  File Function(_Asset asset)? resolveAssetFile,
  required NovelActionsService actions,
  required MediaLibraryService library,
  required String fallbackTitle,
  required NovelContentDatabase Function(String path) openContent,
  required Future<void> Function(NovelContentDatabase database) releaseContent,
  void Function(double progress)? onProgress,
}) async {
  String? novelId;
  final createdAssets = <String>[];
  final createdStyles = <String>[];
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
        resolveAssetFile: resolveAssetFile,
        onProgress: onProgress,
      );
      final styles = ProductionStyleService(library.database);
      final styleIds = <String, String>{};
      for (final entry in package.styles.entries) {
        final style = entry.value;
        final created = await styles.save(
          name: style.name,
          prompt: ProductionStylePrompt(
            before: style.before,
            after: style.after,
          ),
        );
        createdStyles.add(created.id);
        styleIds[entry.key] = created.id;
      }
      final written = await _writeCanvas(
        package,
        canvas,
        canvasId,
        assetIds,
        styleIds,
        actions,
        content,
      );
      final dropped = written.dropped;
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
      final styles = ProductionStyleService(library.database);
      for (final id in createdStyles) {
        await styles.delete(id);
      }
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
  File Function(_Asset asset)? resolveAssetFile,
  Map<String, String>? importedPathsByAssetId,
  void Function(double progress)? onProgress,
}) async {
  final ids = <String, String>{};
  final files = <File>[];
  final sizes = <int>[];
  var total = 0;
  for (final asset in package.assets) {
    final file = resolveAssetFile != null
        ? resolveAssetFile(asset)
        : File(p.join(root.path, asset.file));
    final length = await file.length();
    files.add(file);
    sizes.add(length);
    total += length;
  }
  var done = 0;
  for (var index = 0; index < package.assets.length; index++) {
    final asset = package.assets[index];
    final length = sizes[index];
    final start = done;
    final imported = await library.importFile(
      files[index],
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
    if (importedPathsByAssetId != null && imported.path != null) {
      importedPathsByAssetId[asset.id] = imported.path!;
    }
    created.add(imported.id);
    done += length;
    if (total > 0) {
      onProgress?.call((done / total).clamp(0.0, 1.0));
    }
  }
  onProgress?.call(1);
  return ids;
}

Future<({int dropped, Map<String, String> nodeIds})> _writeCanvas(
  _Package package,
  ProductionCanvasService canvas,
  String canvasId,
  Map<String, String> assetIds,
  Map<String, String> styleIds,
  NovelActionsService? actions,
  NovelContentDatabase content, {
  bool previewMode = false,
}) async {
  var dropped = 0;
  final overlay = actions == null
      ? null
      : WorkingOverlayService(
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
        if (overlay != null) {
          createdNode = await canvas.addFree(canvasId, overlay: overlay);
        } else {
          final clip = await canvas.shots.createVideo('');
          createdNode = await canvas.shots.ensureClipNode(clip.id);
        }
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
    final style = await _keepStyle(canvas, clip.styleSelection, styleIds);
    if (style.dropped) {
      dropped += 1;
    }
    final values = canvas.shots.snapshot(current);
    if (clip.previewGeneration == null) {
      values
        ..['provider_id'] = clip.providerId
        ..['model_id'] = clip.modelId
        ..['reference_mode'] = clip.referenceMode
        ..['duration_ms'] = clip.durationMs
        ..['generate_audio'] = clip.generateAudio
        ..['ratio'] = clip.ratio
        ..['resolution'] = clip.resolution;
    } else if (previewMode) {
      final generation = clip.previewGeneration!;
      final rawMode = generation['reference_mode'];
      final mode =
          rawMode is String &&
              VideoMode.values.any((value) => value.name == rawMode)
          ? rawMode
          : clip.referenceMode;
      final rawRatio = generation['ratio'];
      final rawResolution = generation['resolution'];
      final rawDuration = generation['duration_ms'];
      final rawAudio = generation['generate_audio'];
      values
        ..['provider_id'] = null
        ..['model_id'] = null
        ..['reference_mode'] = mode
        ..['ratio'] = rawRatio is String && rawRatio.isNotEmpty
            ? rawRatio
            : clip.ratio
        ..['resolution'] = rawResolution is String
            ? rawResolution
            : clip.resolution
        ..['duration_ms'] = rawDuration is int ? rawDuration : clip.durationMs
        ..['generate_audio'] = rawAudio is bool ? rawAudio : clip.generateAudio;
    } else {
      values
        ..['provider_id'] = null
        ..['model_id'] = null;
    }
    values
      ..['episode_id'] = ''
      ..['character_id'] = null
      ..['location_id'] = null
      ..['item_id'] = null
      ..['scene_id'] = null
      ..['sort_order'] = null
      ..['title'] = clip.title
      ..['prompt'] = _rewritePrompt(clip.prompt, inputIds)
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
          style: Value(node.style),
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
  final rootStyle = await _keepStyle(canvas, package.styleId, styleIds);
  if (rootStyle.dropped) {
    dropped += 1;
  }
  if (rootStyle.id != null) {
    await canvas.setScreenplayStyle(rootStyle.id);
  }
  return (dropped: dropped, nodeIds: nodeIds);
}

Future<({String? id, bool dropped})> _keepStyle(
  ProductionCanvasService canvas,
  String? styleId,
  Map<String, String> styleIds,
) async {
  if (styleId == null || styleId == 'none') {
    return (id: styleId, dropped: false);
  }
  final imported = styleIds[styleId];
  if (imported != null) {
    return (id: imported, dropped: false);
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

class _PackagedStyle {
  const _PackagedStyle(this.name, this.before, this.after);

  final String name;
  final String before;
  final String after;

  static Map<String, _PackagedStyle> parseAll(Object? raw) {
    final styles = <String, _PackagedStyle>{};
    for (final item in _list(raw ?? const [])) {
      final json = _map(item);
      final id = json['id'];
      final name = json['name'];
      final before = json['before'];
      final after = json['after'];
      if (id is! String ||
          id.isEmpty ||
          id == 'none' ||
          isProductionStylePresetRef(id) ||
          styles.containsKey(id) ||
          name is! String ||
          name.trim().isEmpty ||
          before is! String ||
          after is! String) {
        throw const ProductionCanvasPackageException('invalid_package');
      }
      styles[id] = _PackagedStyle(name, before, after);
    }
    return styles;
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
    required this.styles,
    required this.conversations,
  });
  final String title;
  final String? styleId;
  final String ratio;
  final String resolution;
  final List<_Node> nodes;
  final List<_Edge> edges;
  final List<_Asset> assets;
  final Map<String, _PackagedStyle> styles;
  final _PackagedConversations conversations;

  _Group? groupOf(String id) {
    for (final node in nodes) {
      if (node.id == id) {
        return node.group;
      }
    }
    return null;
  }

  static _Package parse(Map<String, Object?> json) {
    _requireKeys(json, const {
      'format',
      'version',
      'title',
      'settings',
      'nodes',
      'edges',
      'assets',
    });
    final version = json['version'];
    if (json['format'] == productionCanvasPackageFormat &&
        version is int &&
        version > _version) {
      throw const ProductionCanvasPackageException('unsupported');
    }
    if (json['format'] != productionCanvasPackageFormat ||
        version != _version ||
        json['title'] is! String) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final settings = _map(json['settings']);
    _requireKeys(settings, const {'style_id', 'ratio', 'resolution'});
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
    final styles = _PackagedStyle.parseAll(json['styles']);
    final styleReferences = {
      styleId,
      ...nodes.map((node) => node.clip?.styleSelection),
    };
    if (!styleReferences.containsAll(styles.keys)) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    return _Package(
      title: json['title']! as String,
      styleId: styleId as String?,
      ratio: ratio,
      resolution: resolution,
      nodes: nodes,
      edges: edges,
      assets: assets,
      styles: styles,
      conversations: _PackagedConversations.parse(json),
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
    _requireKeys(json, const {
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
    required this.previewGeneration,
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
  final Map<String, Object?>? previewGeneration;

  static _Clip parse(Map<String, Object?> json) {
    _requireKeys(json, const {
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
      previewGeneration: _parsePreviewGeneration(json['preview_generation']),
    );
  }
}

Map<String, Object?>? _parsePreviewGeneration(Object? input) {
  if (input == null) {
    return null;
  }
  final json = _map(input);
  final model = json['model'];
  final mode = json['reference_mode'];
  final duration = json['duration_ms'];
  final audio = json['generate_audio'];
  final ratio = json['ratio'];
  final resolution = json['resolution'];
  if ((model != null && model is! String) ||
      mode is! String ||
      (duration != null && (duration is! int || duration <= 0)) ||
      (audio != null && audio is! bool) ||
      ratio is! String ||
      resolution is! String) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  return {
    'model': model,
    'reference_mode': mode,
    'duration_ms': duration,
    'generate_audio': audio,
    'ratio': ratio,
    'resolution': resolution,
  };
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
    _requireKeys(json, const {'source_id', 'target_id', 'type'});
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
    _requireKeys(json, const {'id', 'name', 'purpose', 'file', 'in_library'});
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
    _requireZipName(file);
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

void _requireKeys(Map<dynamic, dynamic> json, Set<String> keys) {
  if (!json.keys.toSet().containsAll(keys)) {
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
