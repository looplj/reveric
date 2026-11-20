// 职责: 验证制作画布离屏预览（canvas-preview）的几何、作用域、缩略图缓存、错误约束与会话图片回传契约。
// 关联文件:
//   lib/shared/services/production/canvas_preview.dart
//   lib/shared/services/production/video_thumbnail_cache.dart
//   lib/shared/services/ai/media/production.dart
//   lib/shared/services/ai/tools_run.dart

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/services/ai/files/attachments.dart';
import 'package:reveric/shared/services/ai/files/command_paths.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/editing/sessions.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/production/audio_service.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/image_service.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/result_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/services/working_overlay.dart';

class _Harness {
  _Harness({
    required this.root,
    required this.db,
    required this.app,
    required this.tools,
    required this.canvas,
    required this.library,
    required this.sessions,
    required this.operations,
  });

  final Directory root;
  final NovelContentDatabase db;
  final AppDatabase app;
  final AiToolManager tools;
  final ProductionCanvasService canvas;
  final MediaLibraryService library;
  final EditingSessions sessions;
  final ToolOperationManager operations;

  Future<Map<String, dynamic>> call(
    String tool,
    String path, [
    Map<String, dynamic>? fields,
  ]) async {
    final result = await tools.executeTool(
      name: tool,
      input: {'path': path, 'fields': ?fields},
      context: ToolExecutionContext(
        sessionId: 'session',
        sourceSessionId: 'session',
        sourceTurnId: 'turn',
      ),
    );
    jsonEncode(result);
    return result;
  }

  Future<Map<String, dynamic>> runPreview(
    Map<String, dynamic> options, {
    String? parentToolCallId,
    String? sessionId = 'session',
  }) async {
    final result = await tools.executeTool(
      name: 'Run',
      input: {
        'command': 'production',
        'subcommand': 'canvas-preview',
        'options': options,
      },
      context: ToolExecutionContext(
        sessionId: sessionId,
        sourceSessionId: sessionId,
        sourceTurnId: 'turn',
        parentToolCallId: parentToolCallId,
      ),
    );
    jsonEncode(result);
    return result;
  }

  Future<void> dispose() async {
    tools.dispose();
    operations.dispose();
    sessions.dispose();
    await db.close();
    await app.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }
}

Future<_Harness> _createHarness({required String contentKind}) async {
  final root = await Directory.systemTemp.createTemp('canvas_preview_test_');
  final db = NovelContentDatabase.forTest(NativeDatabase.memory());
  final app = AppDatabase.forTest(NativeDatabase.memory());
  if (contentKind == contentKindCanvas) {
    await ScreenplayService(db).createCanvasStructure();
  }
  await app.novelDao.create(
    id: 'work',
    title: 'Work',
    description: '',
    contentKind: contentKind,
    contentDatabasePath: db.filePath,
  );
  final library = MediaLibraryService(
    app,
    MediaService(FfmpegRunner()),
    root,
  );
  final canvas = ProductionCanvasService(
    StoryboardService(db, contentKind: contentKind),
    library,
    'work',
  );
  final content = NovelContentService(db);
  final overlay = WorkingOverlayService(
    db,
    content,
    novelActionsService: NovelActionsService(app),
  );
  final sessions = EditingSessions();
  final operations = ToolOperationManager(
    ownerSessionId: 'session',
    registry: ToolOperationRegistry(),
    gate: () => throw StateError('No external permission gate expected'),
    onChanged: (_) {},
    onRecord: (_) {},
  );
  final host = ProductionToolHost(
    canvas: canvas,
    images: _Images(),
    audio: _Audio(),
    video: () => throw StateError('No video provider expected'),
    results: _Results(),
    editingSessions: sessions,
  );
  final tools = AiToolManager(
    content,
    workingOverlayService: overlay,
    novelReader: () async => {
      'title': 'Work',
      'author_name': 'Tester',
      'description': '',
      'category': '',
      'status': 'in_progress',
      'tags': <String>[],
    },
    contentKind: contentKind,
    workId: 'work',
    sessionId: 'session',
    operationHost: ToolOperationHost(
      operations,
      production: () async => host,
    ),
    productionStyleServiceBuilder: () async => canvas,
  )..registerAllTools();

  return _Harness(
    root: root,
    db: db,
    app: app,
    tools: tools,
    canvas: canvas,
    library: library,
    sessions: sessions,
    operations: operations,
  );
}

Future<AssetRow> _insertTestImageAsset(
  _Harness h, {
  required String id,
  required String fileName,
  required int width,
  required int height,
  required List<int> rgb,
}) async {
  final relPath = p.posix.join('file_workspaces', 'work', 'assets', fileName);
  final file = File(h.library.resolvePath(relPath));
  await file.parent.create(recursive: true);
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(rgb[0], rgb[1], rgb[2]));
  await file.writeAsBytes(img.encodePng(image), flush: true);

  await h.app.into(h.app.assets).insert(
        AssetsCompanion.insert(
          id: id,
          novelId: const Value('work'),
          type: 'image',
          purpose: 'reference',
          name: Value(fileName),
          path: Value(relPath),
          source: const Value('imported'),
          content: Value(
            ImageAssetContent(
              mimeType: 'image/png',
              width: width,
              height: height,
            ),
          ),
        ),
      );
  return (await h.app.assetDao.getAsset(id))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'canvas-work preview renders session_files_v1 JPEG without extra metadata keys',
    () async {
      final h = await _createHarness(contentKind: contentKindCanvas);
      addTearDown(h.dispose);

      final asset = await _insertTestImageAsset(
        h,
        id: 'ast_img_1',
        fileName: 'hero.png',
        width: 320,
        height: 180,
        rgb: [30, 140, 220],
      );

      final textNode = await h.call('Create', 'production/canvas/nodes', {
        'type': 'text',
        'title': '大纲',
        'content': '第一幕角色设定与镜头提示词。',
        'x': 0,
        'y': 0,
      });
      final mediaNode = await h.call('Create', 'production/canvas/nodes', {
        'type': 'media',
        'asset_id': asset.id,
        'title': '主角参考',
        'x': 420,
        'y': 0,
      });
      final videoNode = await h.call('Create', 'production/canvas/nodes', {
        'type': 'video',
        'title': '主镜头 01',
        'x': 840,
        'y': 0,
      });
      final audioNode = await h.call('Create', 'production/canvas/nodes', {
        'type': 'audio',
        'title': '对白配音',
        'x': 840,
        'y': 320,
      });
      // 与 videoNode 部分重叠的节点，验证重叠路径正常绘制不报错。
      final overlapNode = await h.call('Create', 'production/canvas/nodes', {
        'type': 'image',
        'title': '重叠尾帧',
        'x': 880,
        'y': 20,
      });

      final clipId = videoNode['ref_id'] as String;
      await h.call('Write', 'production/clips/$clipId', {
        'prompt': '使用参考图与文本设定',
        'inputs': [
          {
            'id': 'in_txt',
            'ref_type': 'node',
            'ref_id': textNode['id'],
            'role': 'prompt',
          },
          {
            'id': 'in_ref',
            'ref_type': 'node',
            'ref_id': mediaNode['id'],
            'role': 'reference_image',
          },
          {
            'id': 'in_ov',
            'ref_type': 'node',
            'ref_id': overlapNode['id'],
            'role': 'last_frame',
          },
        ],
      });
      expect(audioNode['ok'], true);

      final result = await h.runPreview({});
      expect(result['ok'], true, reason: '$result');
      expect(result.containsKey('issues'), false);
      expect(result.containsKey('nodes'), false);
      expect(result.containsKey('offscreen_clusters'), false);

      final width = result['width'] as int;
      final height = result['height'] as int;
      expect(width, inInclusiveRange(240, 2048));
      expect(height, inInclusiveRange(240, 2048));

      final bounds = result['bounds'] as Map<String, dynamic>;
      expect((bounds['width'] as num).toDouble(), greaterThan(800));
      expect((bounds['height'] as num).toDouble(), greaterThan(300));

      expect(result['content_format'], 'session_files_v1');
      final filePath = result['file_path'] as String;
      final snapshotPath = result['snapshot_path'] as String;
      expect(filePath, endsWith('.jpg'));
      expect(snapshotPath, endsWith('.jpg'));

      final files = SessionFiles(root: h.root.path, novelId: 'work');
      final sessionFile = await CommandPaths(files).resolve(filePath);
      expect(sessionFile.path, (await files.resolve(snapshotPath)).path);
      final bytes = await sessionFile.readAsBytes();
      final decoded = img.decodeJpg(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, width);
      expect(decoded.height, height);

      final hydrated = await assembleToolResultContent(result, root: h.root.path);
      final images = hydrated.whereType<ImageBlock>().toList();
      expect(images, hasLength(1));
      expect(images.single.mimeType, 'image/jpeg');
    },
  );

  test(
    'scope=main excludes distant outlier cluster while scope=all, node_ids, and bounds target accurately',
    () async {
      final h = await _createHarness(contentKind: contentKindCanvas);
      addTearDown(h.dispose);

      await h.call('Create', 'production/canvas/nodes', {
        'type': 'text',
        'title': '主区 1',
        'content': 'Main 1',
        'x': 0,
        'y': 0,
      });
      await h.call('Create', 'production/canvas/nodes', {
        'type': 'text',
        'title': '主区 2',
        'content': 'Main 2',
        'x': 420,
        'y': 0,
      });
      await h.call('Create', 'production/canvas/nodes', {
        'type': 'text',
        'title': '主区 3',
        'content': 'Main 3',
        'x': 420,
        'y': 320,
      });
      final outlier = await h.call('Create', 'production/canvas/nodes', {
        'type': 'text',
        'title': '远端残留',
        'content': 'Outlier',
        'x': 4200,
        'y': 4000,
      });

      final mainResult = await h.runPreview({'scope': 'main'});
      expect(mainResult['ok'], true, reason: '$mainResult');
      final mainBounds = mainResult['bounds'] as Map<String, dynamic>;
      final mainRight =
          (mainBounds['x'] as num).toDouble() + (mainBounds['width'] as num).toDouble();
      expect(mainRight, lessThan(2000));

      final allResult = await h.runPreview({'scope': 'all'});
      expect(allResult['ok'], true, reason: '$allResult');
      final allBounds = allResult['bounds'] as Map<String, dynamic>;
      final allRight =
          (allBounds['x'] as num).toDouble() + (allBounds['width'] as num).toDouble();
      expect(allRight, greaterThan(4200));

      final nodeFocus = await h.runPreview({
        'node_ids': [outlier['id']],
      });
      expect(nodeFocus['ok'], true, reason: '$nodeFocus');
      final focusBounds = nodeFocus['bounds'] as Map<String, dynamic>;
      expect((focusBounds['x'] as num).toDouble(), greaterThan(3800));

      final explicitBounds = await h.runPreview({
        'bounds': {'x': 100, 'y': 200, 'width': 800, 'height': 600},
      });
      expect(explicitBounds['ok'], true, reason: '$explicitBounds');
      expect(explicitBounds['bounds'], {
        'x': 100.0,
        'y': 200.0,
        'width': 800.0,
        'height': 600.0,
      });
    },
  );

  test(
    'cachedVideoThumbnail reads pre-cached PNG without spawning ffmpeg and misses safely',
    () async {
      final h = await _createHarness(contentKind: contentKindCanvas);
      addTearDown(h.dispose);

      const relPath = 'file_workspaces/work/assets/sample.mp4';
      final videoFile = File(h.library.resolvePath(relPath));
      await videoFile.parent.create(recursive: true);
      await videoFile.writeAsBytes([1, 2, 3, 4], flush: true);

      expect(await h.library.cachedVideoThumbnail(relPath), isNull);

      final stat = await videoFile.stat();
      final key = sha256
          .convert(
            utf8.encode(
              'v1\n$relPath\n${stat.size}\n${stat.modified.microsecondsSinceEpoch}',
            ),
          )
          .toString();
      final cacheFile = File(
        p.join(h.root.path, 'cache', 'video_thumbs', '$key.png'),
      );
      await cacheFile.parent.create(recursive: true);
      final thumb = img.Image(width: 64, height: 36);
      img.fill(thumb, color: img.ColorRgb8(240, 180, 60));
      await cacheFile.writeAsBytes(img.encodePng(thumb), flush: true);

      final hit = await h.library.cachedVideoThumbnail(relPath);
      expect(hit, isNotNull);
      expect(hit!.path, cacheFile.path);
    },
  );

  test(
    'screenplay preview validates episode_id & uncreated canvas and codemode rejects canvas-preview',
    () async {
      final h = await _createHarness(contentKind: contentKindScreenplay);
      addTearDown(h.dispose);

      final episodeId =
          (await ScreenplayService(h.db).createInitialStructure()).episodeId;

      final missingEp = await h.runPreview({});
      expect(missingEp['ok'], false);

      final beforeCanvas = await h.runPreview({'episode_id': episodeId});
      expect(beforeCanvas['ok'], false);
      expect(beforeCanvas['error'], contains('has not been created'));

      final created = await h.call(
        'Create',
        'episodes/$episodeId/production/canvas',
      );
      expect(created['ok'], true, reason: '$created');

      final afterCanvas = await h.runPreview({'episode_id': episodeId});
      expect(afterCanvas['ok'], true, reason: '$afterCanvas');

      final blockedCodemode = await h.runPreview(
        {'episode_id': episodeId},
        parentToolCallId: 'codemode',
      );
      expect(blockedCodemode['ok'], false);
      expect(blockedCodemode['error'], contains('direct Run call'));

      final rejectedThumbOpt = await h.runPreview({
        'episode_id': episodeId,
        'thumbnails': false,
      });
      expect(rejectedThumbOpt['ok'], false);

      final rejectedCombo = await h.runPreview({
        'episode_id': episodeId,
        'scope': 'main',
        'bounds': {'x': 0, 'y': 0, 'width': 500, 'height': 500},
      });
      expect(rejectedCombo['ok'], false);
    },
  );
}

class _Images implements ImageTaskService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Audio implements AudioTaskService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Results implements ProductionResultService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
