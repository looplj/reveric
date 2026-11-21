// 职责: 将用户选中的聊天历史与附件归档为可在画廊只读展示的数据。
// 关联文件:
//   lib/shared/services/production/canvas_package.dart
//   lib/shared/services/ai/session_persistence.dart
//   lib/shared/services/ai/files/session_files.dart
//   lib/shared/widgets/ai/chat/chat_message_view.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md
//   .agents/rules/error-handling.md

part of 'canvas_package.dart';

class ProductionCanvasPackageConversationSummary {
  const ProductionCanvasPackageConversationSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.model,
    required this.agentSlug,
    required this.messageCount,
    required this.fileCount,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? model;
  final String? agentSlug;
  final int messageCount;
  final int fileCount;
}

class ProductionCanvasPackageConversation {
  const ProductionCanvasPackageConversation(this.summary, this.messages);

  final ProductionCanvasPackageConversationSummary summary;
  final List<AiMessage> messages;
}

class ProductionCanvasPackageGeneration {
  const ProductionCanvasPackageGeneration({
    this.nodeId,
    required this.title,
    required this.model,
    required this.parameters,
  });

  final String? nodeId;
  final String title;
  final String? model;
  final Map<String, Object?> parameters;
}

class ProductionCanvasPackagePreview {
  const ProductionCanvasPackagePreview._(
    this._directory,
    this.conversations,
    this.generations,
    this._closeDatabases, {
    this.canvas,
    this.canvasId,
    this.generationsByNodeId = const {},
    this.cacheDirectory,
    this.persistent = false,
  });

  final Directory _directory;
  final List<ProductionCanvasPackageConversation> conversations;
  final List<ProductionCanvasPackageGeneration> generations;
  final ProductionCanvasService? canvas;
  final String? canvasId;
  final Map<String, ProductionCanvasPackageGeneration> generationsByNodeId;
  final Directory? cacheDirectory;
  final Future<void> Function()? _closeDatabases;
  final bool persistent;

  /// 关闭数据库连接；持久化缓存不删除目录，临时预览会清理临时目录。
  Future<void> close() async {
    if (persistent) {
      await _closeDatabases?.call();
      return;
    }
    await delete();
  }

  Future<void> delete() async {
    try {
      await _closeDatabases?.call();
    } finally {
      if (!persistent && await _directory.exists()) {
        await _directory.delete(recursive: true);
      }
    }
  }
}

const _previewCacheMetaFormat = 'reveric.canvas_gallery_cache';
const _previewCacheMetaVersion = 1;
const _previewCacheNovelId = 'gallery_preview';
const canvasGalleryCacheReadyMarker = '.ready';

class _PreviewCacheMeta {
  const _PreviewCacheMeta({
    required this.canvasId,
    required this.nodeIds,
    required this.assetFiles,
    required this.archiveFiles,
  });

  final String canvasId;
  final Map<String, String> nodeIds;
  final Map<String, String> assetFiles;
  final Map<String, String> archiveFiles;

  Map<String, Object?> toJson() => {
    'format': _previewCacheMetaFormat,
    'version': _previewCacheMetaVersion,
    'canvas_id': canvasId,
    'node_ids': nodeIds,
    'asset_files': assetFiles,
    'archive_files': archiveFiles,
  };

  static _PreviewCacheMeta parse(Map<String, Object?> json) {
    if (json['format'] != _previewCacheMetaFormat ||
        json['version'] != _previewCacheMetaVersion ||
        json['canvas_id'] is! String ||
        (json['canvas_id']! as String).isEmpty) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    Map<String, String> readStringMap(Object? raw) {
      final map = _map(raw);
      final out = <String, String>{};
      for (final entry in map.entries) {
        if (entry.value is! String) {
          throw const ProductionCanvasPackageException('invalid_package');
        }
        out[entry.key] = entry.value! as String;
      }
      return out;
    }

    return _PreviewCacheMeta(
      canvasId: json['canvas_id']! as String,
      nodeIds: readStringMap(json['node_ids']),
      assetFiles: readStringMap(json['asset_files']),
      archiveFiles: readStringMap(json['archive_files']),
    );
  }
}

Future<_PreviewCacheMeta> _readPreviewCacheMeta(Directory cacheDir) async {
  final file = _packageFile(cacheDir, 'cache_meta.json');
  if (!await file.exists()) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  return _PreviewCacheMeta.parse(await _readPackageJson(file));
}

File _resolveCachedWorkspaceFile(Directory workspaceRoot, String stored) {
  if (stored.trim().isEmpty || stored.contains('://')) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  final syntax = RevericPaths.contextForStoredPath(stored);
  final segments = syntax.split(stored);
  if (syntax.isAbsolute(stored) ||
      segments.isEmpty ||
      segments.contains('..') ||
      segments.first != 'file_workspaces') {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  final resolved = p.normalize(p.join(workspaceRoot.path, p.joinAll(segments)));
  if (!p.isWithin(workspaceRoot.path, resolved)) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  return File(resolved);
}

Future<List<ProductionCanvasPackageConversation>> _readPackagedConversations(
  Directory directory,
  _Package package,
  File Function(String archivePath) resolveFile,
) async {
  final declarations = package.conversations;
  final files = {for (final file in declarations.files) file.id: file};
  final conversations = <ProductionCanvasPackageConversation>[];
  for (final session in declarations.sessions) {
    final sessionFile = _packageFile(directory, session.file);
    if (!await sessionFile.exists()) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final json = await _readPackageJson(sessionFile);
    final usedFiles = <String>{};
    final messages = [
      for (final raw in _list(json['messages']))
        _readPackagedMessage(_stringMap(raw), files, usedFiles, resolveFile),
    ].where(_packageMessageVisible).toList();
    conversations.add(
      ProductionCanvasPackageConversation(
        session.summary(
          messageCount: messages.length,
          fileCount: usedFiles.length,
        ),
        messages,
      ),
    );
  }
  return conversations;
}

({
  List<ProductionCanvasPackageGeneration> list,
  Map<String, ProductionCanvasPackageGeneration> byNodeId,
})
_buildPreviewGenerations(_Package package, Map<String, String> nodeIds) {
  final generations = <ProductionCanvasPackageGeneration>[];
  final generationsByNodeId = <String, ProductionCanvasPackageGeneration>{};
  for (final node in package.nodes) {
    if (node.clip?.previewGeneration case final generation?) {
      final mappedNodeId = nodeIds[node.id];
      final entry = ProductionCanvasPackageGeneration(
        nodeId: mappedNodeId,
        title: node.title,
        model: generation['model'] as String?,
        parameters: (Map<String, Object?>.of(generation)..remove('model')),
      );
      generations.add(entry);
      if (mappedNodeId != null) {
        generationsByNodeId[mappedNodeId] = entry;
      }
    }
  }
  return (list: generations, byNodeId: generationsByNodeId);
}

/// 将画布压缩包解包、导入本地落盘 SQLite 与媒体工作区，再原子切换为正式缓存目录。
///
/// Windows 上 SQLite 句柄未关闭时无法重命名目录，因此先关闭双库连接再重命名。
Future<void> prepareProductionCanvasPackageCache(
  File zip,
  Directory targetDir, {
  required MediaService media,
  void Function(double progress)? onProgress,
}) async {
  if (!await targetDir.parent.exists()) {
    await targetDir.parent.create(recursive: true);
  }
  final tmpDir = Directory(
    p.join(
      targetDir.parent.path,
      '${p.basename(targetDir.path)}.tmp_${buildRandomId('gallery')}',
    ),
  );
  await tmpDir.create(recursive: true);
  AppDatabase? appDb;
  NovelContentDatabase? contentDb;
  Future<void> closeDatabases() async {
    try {
      await contentDb?.close();
    } finally {
      contentDb = null;
      try {
        await appDb?.close();
      } finally {
        appDb = null;
      }
    }
  }

  try {
    final archive = await _CanvasPackageArchive.open(zip);
    final package = await archive.readManifest(tmpDir);
    final declarations = package.conversations;
    final extractFiles = <String>[
      ...declarations.sessions.map((session) => session.file),
      ...declarations.files.map((file) => file.file),
      ...package.assets.map((asset) => asset.file),
    ];
    await archive.extract(
      extractFiles,
      tmpDir,
      onProgress: onProgress == null
          ? null
          : (value) => onProgress((value * 0.45).clamp(0.0, 0.45)),
    );
    final appDbFile = File(toWindowsSafePath(p.join(tmpDir.path, 'app.db')));
    final contentDbFile = File(
      toWindowsSafePath(p.join(tmpDir.path, 'content.db')),
    );
    final openedAppDb = AppDatabase.ephemeral(
      NativeDatabase.createInBackground(appDbFile),
    );
    appDb = openedAppDb;
    // 无素材且无自定义风格时不会触发 appDb 写入，显式查询一次确保落盘建库。
    await openedAppDb.customSelect('SELECT 1').getSingle();
    final openedContentDb = NovelContentDatabase.ephemeral(
      NativeDatabase.createInBackground(contentDbFile),
    );
    contentDb = openedContentDb;
    await ScreenplayService(openedContentDb).createCanvasStructure();
    final workspaceRoot = Directory(p.join(tmpDir.path, 'workspace'));
    await workspaceRoot.create(recursive: true);
    final library = MediaLibraryService(openedAppDb, media, workspaceRoot);
    final importedPathsByAssetId = <String, String>{};
    final assetIds = await _importAssets(
      package,
      tmpDir,
      library,
      _previewCacheNovelId,
      <String>[],
      importedPathsByAssetId: importedPathsByAssetId,
      onProgress: onProgress == null
          ? null
          : (value) => onProgress((0.45 + value * 0.45).clamp(0.45, 0.9)),
    );
    final styles = ProductionStyleService(openedAppDb);
    final styleIds = <String, String>{};
    for (final entry in package.styles.entries) {
      final style = entry.value;
      final created = await styles.save(
        name: style.name,
        prompt: ProductionStylePrompt(before: style.before, after: style.after),
      );
      styleIds[entry.key] = created.id;
    }
    final canvas = ProductionCanvasService(
      StoryboardService(openedContentDb, contentKind: contentKindCanvas),
      library,
      _previewCacheNovelId,
    );
    final ensuredCanvasId = (await canvas.ensureCanvas('')).id;
    final written = await _writeCanvas(
      package,
      canvas,
      ensuredCanvasId,
      assetIds,
      styleIds,
      null,
      openedContentDb,
      previewMode: true,
    );
    final archiveFiles = <String, String>{
      for (final asset in package.assets)
        asset.file: ?importedPathsByAssetId[asset.id],
    };
    final meta = _PreviewCacheMeta(
      canvasId: ensuredCanvasId,
      nodeIds: written.nodeIds,
      assetFiles: importedPathsByAssetId,
      archiveFiles: archiveFiles,
    );
    await _packageFile(
      tmpDir,
      'cache_meta.json',
    ).writeAsString(jsonEncode(meta.toJson()));
    // 媒体已导入 workspace/file_workspaces，删除原始 media/ 副本，磁盘只留一份。
    final rawMediaDir = Directory(p.join(tmpDir.path, 'media'));
    if (await rawMediaDir.exists()) {
      await rawMediaDir.delete(recursive: true);
    }
    // 必须先关闭双库连接再重命名，避免 Windows 文件锁导致 rename 失败。
    await closeDatabases();
    await _packageFile(
      tmpDir,
      canvasGalleryCacheReadyMarker,
    ).writeAsString(DateTime.now().toUtc().toIso8601String());
    if (await targetDir.exists()) {
      await targetDir.delete(recursive: true);
    }
    await tmpDir.rename(targetDir.path);
    onProgress?.call(1);
  } catch (_) {
    try {
      await closeDatabases();
    } finally {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    }
    rethrow;
  }
}

/// 从已就绪的本地解包缓存目录秒开只读画布预览，跳过下载、解压与 ffprobe。
Future<ProductionCanvasPackagePreview> openProductionCanvasPackageCache(
  Directory cacheDir, {
  required MediaService media,
}) async {
  final readyFile = _packageFile(cacheDir, canvasGalleryCacheReadyMarker);
  final manifestFile = _packageFile(cacheDir, 'manifest.json');
  final appDbRaw = File(p.join(cacheDir.path, 'app.db'));
  final contentDbRaw = File(p.join(cacheDir.path, 'content.db'));
  final workspaceRoot = Directory(p.join(cacheDir.path, 'workspace'));
  if (!await readyFile.exists() ||
      !await manifestFile.exists() ||
      !await appDbRaw.exists() ||
      !await contentDbRaw.exists() ||
      !await workspaceRoot.exists()) {
    throw const ProductionCanvasPackageException('invalid_package');
  }
  AppDatabase? appDb;
  NovelContentDatabase? contentDb;
  Future<void> closeDatabases() async {
    try {
      await contentDb?.close();
    } finally {
      contentDb = null;
      try {
        await appDb?.close();
      } finally {
        appDb = null;
      }
    }
  }

  try {
    final package = _Package.parse(await _readPackageJson(manifestFile));
    final meta = await _readPreviewCacheMeta(cacheDir);
    final conversations = await _readPackagedConversations(cacheDir, package, (
      archivePath,
    ) {
      final mapped = meta.archiveFiles[archivePath];
      if (mapped != null) {
        return _resolveCachedWorkspaceFile(workspaceRoot, mapped);
      }
      return _packageFile(cacheDir, archivePath);
    });
    final openedAppDb = AppDatabase.ephemeral(
      NativeDatabase.createInBackground(File(toWindowsSafePath(appDbRaw.path))),
    );
    appDb = openedAppDb;
    final openedContentDb = NovelContentDatabase.ephemeral(
      NativeDatabase.createInBackground(
        File(toWindowsSafePath(contentDbRaw.path)),
      ),
    );
    contentDb = openedContentDb;
    try {
      await openedAppDb.customSelect('SELECT 1').getSingle();
      await openedContentDb.customSelect('SELECT 1').getSingle();
    } catch (_) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    final library = MediaLibraryService(openedAppDb, media, workspaceRoot);
    final canvasService = ProductionCanvasService(
      StoryboardService(openedContentDb, contentKind: contentKindCanvas),
      library,
      _previewCacheNovelId,
    );
    final generations = _buildPreviewGenerations(package, meta.nodeIds);
    return ProductionCanvasPackagePreview._(
      cacheDir,
      conversations,
      generations.list,
      closeDatabases,
      canvas: canvasService,
      canvasId: meta.canvasId,
      generationsByNodeId: generations.byNodeId,
      cacheDirectory: cacheDir,
      persistent: true,
    );
  } catch (_) {
    await closeDatabases();
    rethrow;
  }
}

Future<List<ProductionCanvasPackageConversation>>
listProductionCanvasPackageConversations({
  required AiSessionPersistenceService sessionPersistence,
  required NovelContentDatabase novelDatabase,
}) async {
  final sessions = await sessionPersistence
      .watchSessionsByMode(AiSessionMode.chat.value)
      .first;
  final result = <ProductionCanvasPackageConversation>[];
  for (final session in sessions.where(_packageSessionEligible)) {
    final persisted = await sessionPersistence.loadSessionMessages(
      sessionId: session.id,
      novelDatabase: novelDatabase,
    );
    final messages = persisted.messages
        .where(_packageMessageVisible)
        .map(
          (message) => message.copyWith(
            content: message.role == AiMessageRole.user
                ? parseUserMessagePresentation(message.content).text
                : _visibleAssistantText(message),
          ),
        )
        .toList();
    final files = <String>{
      for (final message in messages)
        for (final block in message.blocks)
          if (block is AiAttachmentBlock)
            block.path
          else if (block is AiImageBlock &&
              (block.hasImage || block.assetId != null))
            block.localFilePath ?? block.assetId ?? block.id,
    };
    result.add(
      ProductionCanvasPackageConversation(
        _summaryFromSession(session, session.id, messages.length, files.length),
        messages,
      ),
    );
  }
  return result;
}

Future<ProductionCanvasPackagePreview> readProductionCanvasPackagePreview(
  File zip, {
  MediaService? media,
  void Function(double progress)? onProgress,
}) async {
  final directory = await Directory.systemTemp.createTemp(
    'reveric_canvas_preview_',
  );
  AppDatabase? appDb;
  NovelContentDatabase? contentDb;
  Future<void> closeDatabases() async {
    try {
      await contentDb?.close();
    } finally {
      await appDb?.close();
    }
  }

  try {
    final archive = await _CanvasPackageArchive.open(zip);
    final package = await archive.readManifest(directory);
    final declarations = package.conversations;
    final extractFiles = <String>[
      ...declarations.sessions.map((session) => session.file),
      ...declarations.files.map((file) => file.file),
      if (media != null) ...package.assets.map((asset) => asset.file),
    ];
    await archive.extract(
      extractFiles,
      directory,
      onProgress: onProgress == null
          ? null
          : (value) => onProgress(
              (value * (media == null ? 0.85 : 0.45)).clamp(0.0, 1.0),
            ),
    );
    final conversations = await _readPackagedConversations(
      directory,
      package,
      (archivePath) => _packageFile(directory, archivePath),
    );

    ProductionCanvasService? canvasService;
    String? canvasId;
    var nodeIds = const <String, String>{};
    if (media != null) {
      appDb = AppDatabase.ephemeral(NativeDatabase.memory());
      contentDb = NovelContentDatabase.ephemeral(NativeDatabase.memory());
      await ScreenplayService(contentDb).createCanvasStructure();
      final workspaceRoot = Directory(p.join(directory.path, 'workspace'));
      await workspaceRoot.create(recursive: true);
      final library = MediaLibraryService(appDb, media, workspaceRoot);
      final assetIds = await _importAssets(
        package,
        directory,
        library,
        _previewCacheNovelId,
        <String>[],
        onProgress: onProgress == null
            ? null
            : (value) => onProgress((0.45 + value * 0.45).clamp(0.45, 0.9)),
      );
      final styles = ProductionStyleService(appDb);
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
        styleIds[entry.key] = created.id;
      }
      final canvas = ProductionCanvasService(
        StoryboardService(contentDb, contentKind: contentKindCanvas),
        library,
        _previewCacheNovelId,
      );
      final ensuredCanvasId = (await canvas.ensureCanvas('')).id;
      final written = await _writeCanvas(
        package,
        canvas,
        ensuredCanvasId,
        assetIds,
        styleIds,
        null,
        contentDb,
        previewMode: true,
      );
      canvasService = canvas;
      canvasId = ensuredCanvasId;
      nodeIds = written.nodeIds;
    }

    final generations = _buildPreviewGenerations(package, nodeIds);
    onProgress?.call(1);
    return ProductionCanvasPackagePreview._(
      directory,
      conversations,
      generations.list,
      media == null ? null : closeDatabases,
      canvas: canvasService,
      canvasId: canvasId,
      generationsByNodeId: generations.byNodeId,
    );
  } catch (_) {
    try {
      await closeDatabases();
    } finally {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
    rethrow;
  }
}

bool _packageSessionEligible(AiChatSession session) =>
    session.parentId == null &&
    session.mode == AiSessionMode.chat.value &&
    session.deletedAt == notDeletedSentinel;

bool _packageMessageVisible(AiMessage message) =>
    message.role != AiMessageRole.system &&
    message.type != AiMessageType.system_remind &&
    message.type != AiMessageType.tool_result &&
    message.type != AiMessageType.compact_summary;

Future<List<AiChatSession>> _selectPackageSessions(
  ProductionCanvasService canvas,
  AiSessionPersistenceService? persistence,
  List<String> ids,
) async {
  if (ids.isEmpty) {
    return const [];
  }
  final sessions = <AiChatSession>[];
  for (final id in ids.toSet()) {
    final session = await persistence?.getSession(id);
    if (session == null ||
        session.novelId != canvas.novelId ||
        !_packageSessionEligible(session)) {
      throw ProductionCanvasPackageException(
        'invalid_conversation',
        subject: id,
      );
    }
    sessions.add(session);
  }
  return sessions;
}

ProductionCanvasPackageConversationSummary _summaryFromSession(
  AiChatSession session,
  String id,
  int messages,
  int files,
) => ProductionCanvasPackageConversationSummary(
  id: id,
  title: session.title,
  createdAt: session.createdAt,
  updatedAt: session.updatedAt,
  model: session.model,
  agentSlug: session.agentSlug,
  messageCount: messages,
  fileCount: files,
);

class _PackagedConversationEntry {
  const _PackagedConversationEntry({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.model,
    required this.agentSlug,
    required this.file,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? model;
  final String? agentSlug;
  final String file;

  factory _PackagedConversationEntry.parse(Object? raw) {
    final json = _map(raw);
    final id = _packageString(json['id']);
    final title = _packageString(json['title']);
    final created = DateTime.tryParse(_packageString(json['created_at']));
    final updated = DateTime.tryParse(_packageString(json['updated_at']));
    final file = _packageString(json['file']);
    _requireZipName(file);
    if (!RegExp(r'^chats/[^/]+\.json$').hasMatch(file) ||
        created == null ||
        updated == null ||
        id.isEmpty) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    return _PackagedConversationEntry(
      id: id,
      title: title,
      createdAt: created,
      updatedAt: updated,
      model: _optionalPackageString(json['model']),
      agentSlug: _optionalPackageString(json['agent_slug']),
      file: file,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'model': model,
    'agent_slug': agentSlug,
    'file': file,
  };

  ProductionCanvasPackageConversationSummary summary({
    required int messageCount,
    required int fileCount,
  }) => ProductionCanvasPackageConversationSummary(
    id: id,
    title: title,
    createdAt: createdAt,
    updatedAt: updatedAt,
    model: model,
    agentSlug: agentSlug,
    messageCount: messageCount,
    fileCount: fileCount,
  );
}

class _PackagedConversationFile {
  const _PackagedConversationFile({
    required this.id,
    required this.name,
    required this.mime,
    required this.sizeBytes,
    required this.file,
  });

  final String id;
  final String name;
  final String mime;
  final int sizeBytes;
  final String file;

  factory _PackagedConversationFile.parse(Object? raw) {
    final json = _map(raw);
    final id = _packageString(json['id']);
    final name = _packageString(json['name']);
    final mime = _packageString(json['mime']);
    final size = json['size_bytes'];
    final file = _packageString(json['file']);
    _requireZipName(file);
    if (!RegExp(r'^(files|media)/[^/]+$').hasMatch(file) ||
        size is! int ||
        size < 0 ||
        mime.isEmpty ||
        id.isEmpty ||
        name.isEmpty ||
        name.contains('/') ||
        name.contains('\\')) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    return _PackagedConversationFile(
      id: id,
      name: name,
      mime: mime,
      sizeBytes: size,
      file: file,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'mime': mime,
    'size_bytes': sizeBytes,
    'file': file,
  };
}

class _PackagedConversations {
  const _PackagedConversations(
    this.sessions,
    this.files, [
    this.summaries = const [],
  ]);

  final List<_PackagedConversationEntry> sessions;
  final List<_PackagedConversationFile> files;
  final List<ProductionCanvasPackageConversationSummary> summaries;

  factory _PackagedConversations.parse(Map<String, Object?> manifest) {
    final sessions = _list(
      manifest['conversations'] ?? const [],
    ).map(_PackagedConversationEntry.parse).toList();
    final files = _list(
      manifest['conversation_files'] ?? const [],
    ).map(_PackagedConversationFile.parse).toList();
    if (sessions.map((session) => session.id).toSet().length !=
            sessions.length ||
        sessions.map((session) => session.file).toSet().length !=
            sessions.length ||
        files.map((file) => file.id).toSet().length != files.length ||
        files.map((file) => file.file).toSet().length != files.length) {
      throw const ProductionCanvasPackageException('invalid_package');
    }
    return _PackagedConversations(sessions, files);
  }

  Map<String, Object?> toJson() => {
    'conversations': sessions.map((session) => session.toJson()).toList(),
    'conversation_files': files.map((file) => file.toJson()).toList(),
  };
}

Future<_PackagedConversations> _writePackageConversations(
  ProductionCanvasService canvas,
  List<AiChatSession> sessions,
  Map<String, List<AiMessage>> messages,
  Directory directory,
  Map<String, String> sharedFiles,
) async {
  if (sessions.isEmpty) {
    return const _PackagedConversations([], []);
  }
  final store = SessionFiles(novelId: canvas.novelId);
  final entries = <_PackagedConversationEntry>[];
  final summaries = <ProductionCanvasPackageConversationSummary>[];
  final files = <String, _PackagedConversationFile>{};
  for (final session in sessions) {
    final usedFiles = <String>{};
    Future<String> archiveFile({
      required String name,
      required String mime,
      String? path,
      String? assetId,
      String? imageBase64,
    }) async {
      final id = '${files.length + 1}';
      late final String key;
      late final String archivePath;
      late final int size;
      try {
        File? source;
        if (assetId != null) {
          final asset = await canvas.library.database.assetDao.getAsset(
            assetId,
          );
          if (asset == null ||
              asset.type != 'image' ||
              (asset.novelId != null && asset.novelId != canvas.novelId)) {
            throw const FileSystemException('Conversation asset unavailable');
          }
          source = File(canvas.library.resolve(asset));
        } else if (path != null) {
          source = await store.resolve(path);
          final root = p.join(store.root, store.sessionPath(session.id));
          if (!p.isWithin(root, source.path)) {
            throw const FileSystemException(
              'Conversation file is outside this session',
            );
          }
        }
        if (source != null) {
          key = await source.resolveSymbolicLinks();
          final existing = files[key];
          if (existing != null) {
            usedFiles.add(existing.id);
            return existing.id;
          }
          final stat = await source.stat();
          if (stat.type != FileSystemEntityType.file) {
            throw const FileSystemException('Conversation file unavailable');
          }
          size = stat.size;
          final shared = sharedFiles[key];
          archivePath =
              shared ?? 'files/$id${_packageFileExtension(source.path)}';
          if (shared == null) {
            final target = _packageFile(directory, archivePath);
            await target.parent.create(recursive: true);
            await _copyStablePackageFile(
              source,
              target,
              expected: stat,
              subject: session.title,
              code: 'missing_conversation_file',
            );
          } else if (await _packageFile(directory, shared).length() != size) {
            throw const FileSystemException('Shared canvas file changed');
          }
        } else if (imageBase64 != null) {
          final bytes = base64Decode(imageBase64);
          if (bytes.isEmpty) {
            throw const FormatException('Empty conversation image');
          }
          key = '${session.id}:$id';
          archivePath = 'files/$id.png';
          size = bytes.length;
          final target = _packageFile(directory, archivePath);
          await target.parent.create(recursive: true);
          await target.writeAsBytes(bytes);
        } else {
          throw const FileSystemException(
            'Conversation file has no local archive',
          );
        }
      } on FileSystemException catch (error) {
        _log.warning(
          'export stage=conversation_file result=missing errorType=${error.runtimeType}',
        );
        throw ProductionCanvasPackageException(
          'missing_conversation_file',
          subject: session.title,
        );
      } on FormatException {
        throw ProductionCanvasPackageException(
          'missing_conversation_file',
          subject: session.title,
        );
      } on MediaException {
        throw ProductionCanvasPackageException(
          'missing_conversation_file',
          subject: session.title,
        );
      }
      files[key] = _PackagedConversationFile(
        id: id,
        name: _portableAssetName(name, archivePath),
        mime: mime,
        sizeBytes: size,
        file: archivePath,
      );
      usedFiles.add(id);
      return id;
    }

    final id = '${entries.length + 1}';
    final entry = _PackagedConversationEntry(
      id: id,
      title: session.title,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      model: session.model,
      agentSlug: session.agentSlug,
      file: 'chats/$id.json',
    );
    final sessionMessages = messages[session.id]!;
    final json = <Map<String, Object?>>[];
    for (final message in sessionMessages) {
      final blocks = <Map<String, Object?>>[];
      final userMessage = message.role == AiMessageRole.user;
      final presentation = userMessage
          ? parseUserMessagePresentation(message.content)
          : null;
      final imageIds = message.blocks
          .whereType<AiImageBlock>()
          .map((b) => b.id)
          .toSet();
      for (final block in message.blocks) {
        final blockId = '${json.length + 1}_${blocks.length + 1}';
        if (userMessage && block is AiTextBlock) {
          final text = parseUserMessagePresentation(
            block.text,
            withinHandoff: presentation?.handoff != null,
          ).text;
          if (text.isNotEmpty) {
            blocks.add({'kind': 'text', 'id': blockId, 'text': text});
          }
          continue;
        }
        if (userMessage && block is! AiAttachmentBlock ||
            block is AiToolCallBlock &&
                imageIds.contains('img_${block.callId}')) {
          continue;
        }
        final portable = await _packageBlock(block, blockId, archiveFile);
        if (portable != null) {
          blocks.add(portable);
        }
      }
      final labels = userMessage ? _packagedUserLabels(message.metadata) : null;
      json.add({
        'id': '${json.length + 1}',
        'role': message.role.name,
        'type': message.type.name,
        'content': presentation == null
            ? _visibleAssistantText(message)
            : _packagedUserContent(presentation),
        'metadata': ?labels,
        'timestamp': message.timestamp.toUtc().toIso8601String(),
        'blocks': blocks,
      });
    }
    final file = _packageFile(directory, entry.file);
    await file.parent.create(recursive: true);
    final bytes = utf8.encode(jsonEncode({'messages': json}));
    if (bytes.length > _maxManifestBytes) {
      throw ProductionCanvasPackageException(
        'package_too_large',
        subject: session.title,
      );
    }
    await file.writeAsBytes(bytes);
    entries.add(entry);
    summaries.add(
      _summaryFromSession(session, id, json.length, usedFiles.length),
    );
  }
  return _PackagedConversations(entries, files.values.toList(), summaries);
}

String _visibleAssistantText(AiMessage message) => message.blocks.isEmpty
    ? message.content
    : message.blocks.whereType<AiTextBlock>().map((block) => block.text).join();

String _packagedUserContent(UserMessagePresentation presentation) {
  final tags = <String>[];
  final handoff = presentation.handoff;
  if (handoff != null) {
    final title = _publicLabel(handoff.sourceTitle, handoff.sourceSessionId);
    final agents = [
      _publicLabel(handoff.fromAgent, handoff.sourceSessionId),
      _publicLabel(handoff.toAgent, handoff.sourceSessionId),
    ].nonNulls.join(' → ');
    final label = title ?? (agents.isEmpty ? null : agents);
    if (label != null) {
      tags.add(
        '<session-handoff source-title="${escapeXmlAttribute(label)}"/>',
      );
    }
  }
  for (final reference in presentation.references) {
    final path = reference.path;
    final identity = path.startsWith('ai-session:')
        ? path.substring('ai-session:'.length)
        : path;
    final label = _publicLabel(reference.label, identity);
    if (label == null) {
      continue;
    }
    const publicTypes = {'file', 'selection', 'agent_rule', 'session'};
    final type = publicTypes.contains(reference.type) ? reference.type : '';
    tags.add(
      '<user-remind type="$type" label="${escapeXmlAttribute(label)}"></user-remind>',
    );
  }
  return [...tags, presentation.text].join('\n').trim();
}

String? _publicLabel(String? raw, [String? privateValue]) {
  final label = raw?.trim();
  if (label == null ||
      label.isEmpty ||
      label == privateValue?.trim() ||
      label.startsWith('ai-session:') ||
      label.startsWith('file:') ||
      label.startsWith('content:') ||
      label.startsWith('file_workspaces/') ||
      label.startsWith(r'file_workspaces\') ||
      p.posix.isAbsolute(label) ||
      p.windows.isAbsolute(label) ||
      label.contains('\n') ||
      label.contains('\r')) {
    return null;
  }
  return label;
}

Map<String, dynamic>? _packagedUserLabels(Map<String, dynamic>? metadata) {
  final skills = skillNamesFromMessageMetadata(
    metadata,
  ).map(_publicLabel).nonNulls.toList();
  final subagents = subagentNamesFromMessageMetadata(
    metadata,
  ).map(_publicLabel).nonNulls.toList();
  if (skills.isEmpty && subagents.isEmpty) {
    return null;
  }
  return {
    if (skills.isNotEmpty) kAiMessageSkillNamesKey: skills,
    if (subagents.isNotEmpty) kAiMessageSubagentNamesKey: subagents,
  };
}

String _packageFileExtension(String path) {
  final extension = p.extension(path).toLowerCase();
  return RegExp(r'^\.[a-z0-9]{1,12}$').hasMatch(extension) ? extension : '.bin';
}

typedef _ArchiveConversationFile =
    Future<String> Function({
      required String name,
      required String mime,
      String? path,
      String? assetId,
      String? imageBase64,
    });

Future<Map<String, Object?>?> _packageBlock(
  AiMessageBlock block,
  String id,
  _ArchiveConversationFile archive,
) async {
  switch (block) {
    case AiTextBlock():
      return {'kind': 'text', 'id': id, 'text': block.text};
    case AiThinkingBlock():
      return {'kind': 'thinking', 'id': id, 'text': block.text};
    case AiAttachmentBlock():
      final fileId = await archive(
        name: block.name,
        mime: block.mimeType,
        path: block.path,
      );
      return {
        'kind': 'attachment',
        'id': id,
        'file_id': fileId,
        'name': _portableAssetName(block.name, 'attachment'),
        'image_number': block.imageNumber,
      };
    case AiImageBlock():
      return {
        'kind': 'image',
        'id': id,
        'prompt': block.prompt,
        'tool_name': block.toolName,
        'status': block.status.name,
        if (block.hasImage || block.assetId != null)
          'file_id': await archive(
            name: _portableAssetName(block.localFilePath ?? '', 'image.png'),
            mime: switch (_packageFileExtension(block.localFilePath ?? '')) {
              '.jpg' || '.jpeg' => 'image/jpeg',
              '.webp' => 'image/webp',
              '.gif' => 'image/gif',
              _ => 'image/png',
            },
            path: block.localFilePath,
            assetId: block.assetId,
            imageBase64: block.imageBase64,
          ),
      };
    case AiToolCallBlock():
      if (block.toolName == 'AskUser' ||
          block.toolName == 'SuggestNextAction') {
        return null;
      }
      return {
        'kind': 'tool_call',
        'id': id,
        'call_id': id,
        'tool_name': block.toolName,
        'status': _packageToolStatus(block.status).name,
        if (block.toolName == 'TodoWrite' && block.result?['todos'] is List)
          'todos': _packageTodos(block.result!['todos'] as List),
      };
    case AiAskUserBlock():
      return {
        'kind': 'ask_user',
        'id': id,
        'call_id': id,
        'questions': [
          for (final question in block.questions)
            AskUserQuestion.fromJson(question).toJson(),
        ],
        'status': block.status == AiAskUserStatus.pending
            ? AiAskUserStatus.interrupted.name
            : block.status.name,
        if (block.answers != null)
          'answers': [
            for (final answer in block.answers!)
              AskUserAnswer.fromJson(answer).toJson(),
          ],
        'resolution': block.resolution?.jsonValue,
        'unanswered_question_ids': block.unansweredQuestionIds,
      };
    case AiSuggestNextActionBlock():
      return null;
  }
}

AiToolCallStatus _packageToolStatus(AiToolCallStatus status) =>
    switch (status) {
      AiToolCallStatus.pending ||
      AiToolCallStatus.running => AiToolCallStatus.cancelled,
      _ => status,
    };

List<Map<String, Object?>> _packageTodos(List<dynamic> todos) => [
  for (final todo in todos)
    if (todo is Map && todo['content'] is String && todo['status'] is String)
      {'content': todo['content'], 'status': todo['status']},
];

AiMessage _readPackagedMessage(
  Map<String, dynamic> raw,
  Map<String, _PackagedConversationFile> files,
  Set<String> usedFiles,
  File Function(String archivePath) resolveFile,
) {
  try {
    final blocks = <AiMessageBlock>[];
    for (final item in _list(raw['blocks'])) {
      final block = _stringMap(item);
      final id = _packageString(block['id']);
      final String? reference = _optionalPackageString(block['file_id']);
      final file = reference == null ? null : files[reference];
      if (reference != null) {
        if (file == null) {
          throw const ProductionCanvasPackageException('invalid_package');
        }
        usedFiles.add(reference);
      }
      switch (block['kind']) {
        case 'text':
          blocks.add(AiTextBlock(id: id, text: _packageString(block['text'])));
        case 'thinking':
          blocks.add(
            AiThinkingBlock(id: id, text: _packageString(block['text'])),
          );
        case 'attachment':
          if (file == null) {
            throw const ProductionCanvasPackageException('invalid_package');
          }
          final name = _optionalPackageString(block['name']) ?? file.name;
          blocks.add(
            AiAttachmentBlock(
              id: id,
              name: _portableAssetName(name, file.file),
              path: resolveFile(file.file).path,
              mimeType: file.mime,
              imageNumber: block['image_number'] as int?,
            ),
          );
        case 'image':
          if (file != null && !file.mime.startsWith('image/')) {
            throw const ProductionCanvasPackageException('invalid_package');
          }
          blocks.add(
            AiImageBlock(
              id: id,
              prompt: _packageString(block['prompt']),
              toolName: _optionalPackageString(block['tool_name']),
              status: AiImageStatus.values.byName(
                _packageString(block['status']),
              ),
              localFilePath: file == null ? null : resolveFile(file.file).path,
            ),
          );
        case 'tool_call':
          final toolName = _packageString(block['tool_name']);
          final todos = block['todos'];
          blocks.add(
            AiToolCallBlock(
              id: id,
              callId: _packageString(block['call_id']),
              toolName: toolName,
              arguments: const {},
              status: _packageToolStatus(
                AiToolCallStatus.values.byName(_packageString(block['status'])),
              ),
              result: toolName == 'TodoWrite' && todos is List
                  ? {'todos': _packageTodos(todos)}
                  : null,
            ),
          );
        case 'ask_user':
          final status = AiAskUserStatus.values.byName(
            _packageString(block['status']),
          );
          final answers = block['answers'];
          final resolution = block['resolution'];
          blocks.add(
            AiAskUserBlock(
              id: id,
              callId: _packageString(block['call_id']),
              questions: [
                for (final question in _list(block['questions']))
                  AskUserQuestion.fromJson(_stringMap(question)).toJson(),
              ],
              answers: answers == null
                  ? null
                  : [
                      for (final answer in _list(answers))
                        AskUserAnswer.fromJson(_stringMap(answer)).toJson(),
                    ],
              status: status == AiAskUserStatus.pending
                  ? AiAskUserStatus.interrupted
                  : status,
              resolution: resolution == null
                  ? null
                  : AskUserResolution.values.byName(_packageString(resolution)),
              unansweredQuestionIds: (block['unanswered_question_ids'] as List?)
                  ?.cast<String>(),
            ),
          );
      }
    }
    final role = AiMessageRole.values.byName(_packageString(raw['role']));
    final metadata = raw['metadata'];
    return AiMessage(
      id: _packageString(raw['id']),
      role: role,
      metadata: role == AiMessageRole.user && metadata is Map
          ? _packagedUserLabels(_stringMap(metadata))
          : null,
      type: AiMessageType.values.byName(_packageString(raw['type'])),
      content: _packageString(raw['content']),
      timestamp: DateTime.parse(_packageString(raw['timestamp'])),
      blocks: blocks,
    );
  } on FormatException {
    throw const ProductionCanvasPackageException('invalid_package');
  } on ArgumentError {
    throw const ProductionCanvasPackageException('invalid_package');
  } on TypeError {
    throw const ProductionCanvasPackageException('invalid_package');
  }
}

String _packageString(Object? value) => value is String
    ? value
    : throw const ProductionCanvasPackageException('invalid_package');

String? _optionalPackageString(Object? value) =>
    value == null ? null : _packageString(value);
