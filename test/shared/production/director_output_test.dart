// 职责: 验证导演输出的固定帧、版本来源、登记幂等和编码失败重试。
// 关联文件:
//   lib/shared/services/production/director_output_orchestrator.dart
//   lib/shared/services/director/export_task.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/director/document.dart';
import 'package:reveric/shared/models/director/aspect_ratio.dart';
import 'package:reveric/shared/services/director/commands.dart';
import 'package:reveric/shared/services/director/export_task.dart';
import 'package:reveric/shared/services/director/renderer.dart';
import 'package:reveric/shared/services/director/storage.dart';
import 'package:reveric/shared/services/production/director_output_orchestrator.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';

class Frames implements FrameRenderer {
  final frames = <int>[];
  bool disposed = false;
  @override
  Future<Uint8List> capture(
    DirectorDocument d,
    int frame,
    String camera,
  ) async {
    frames.add(frame);
    return Uint8List.fromList([137, 80, 78, 71, frame]);
  }

  @override
  void dispose() {
    disposed = true;
  }
}

class Runner extends FfmpegRunner {
  int frameCount = 120;
  int width = 720, height = 1280;
  int encodes = 0;
  @override
  Future<String> execute(
    List<String> args, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    if (probe) {
      return jsonEncode({
        'format': {'duration': '5'},
        'streams': [
          {
            'codec_type': 'video',
            'codec_name': 'h264',
            'pix_fmt': 'yuv420p',
            'width': width,
            'height': height,
            'nb_frames': '$frameCount',
            'avg_frame_rate': '24/1',
          },
        ],
      });
    }
    encodes++;
    expect(args[args.indexOf('-vf') + 1], startsWith('scale=$width:$height:'));
    expect(args, containsAllInOrder(['-framerate', '24', '-i']));
    final pattern = args[args.indexOf('-i') + 1];
    expect(await File(pattern.replaceFirst('%06d', '000119')).exists(), true);
    await File(args.last).writeAsBytes([0, 0, 1, 2]);
    return '';
  }
}

void main() {
  late Directory root;
  late DirectorStorage workspace;
  late AppDatabase db;
  late Runner runner;
  late MediaLibraryService library;
  late DirectorDocument document;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('director-assets-test-');
    workspace = DirectorStorage(
      Directory('${root.path}/workspace')..createSync(),
      Directory('${root.path}/temp')..createSync(),
    );
    db = AppDatabase.forTest(NativeDatabase.memory());
    runner = Runner();
    library = MediaLibraryService(
      db,
      MediaService(runner),
      Directory('${root.path}/support'),
    );
    document = DirectorDocument.blank('scene');
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> finish(
    ExportTaskOrchestrator task,
    Directory frames,
    Json manifest,
  ) async {
    await DirectorOutputOrchestrator().run(
      library: library,
      novelId: 'work',
      documentTitle: document.title,
      cameraName:
          document.camera(manifest['cameraId'] as String)!['name'] as String,
      frames: frames,
      manifest: manifest,
      task: task,
    );
  }

  for (final aspect in DirectorAspectRatio.values) {
    test(
      '5 seconds preserves ${aspect.label} dimensions through encoding and registration',
      () async {
        final history = CommandHistory(document);
        addTearDown(history.dispose);
        history.updateViewportSize(1000, 600);
        history.setAspectRatio(aspect);
        document = history.document;
        runner.width = document.width;
        runner.height = document.height;
        final task = ExportTaskOrchestrator(), renderer = Frames();
        addTearDown(task.dispose);
        await task.run(
          workspace: workspace,
          document: document,
          renderer: renderer,
          cameraMode: 'fixed',
          cameraId: document.activeCameras.first['id'],
          savedRevisionId: 'revision-1',
          spaceProbe: (_) async => 1 << 40,
          onRendered: (dir, m) => finish(task, dir, m),
        );
        expect(task.state, OutputState.completed);
        expect(renderer.frames, List.generate(120, (i) => i));
        expect(renderer.disposed, true);
        final asset = (await db.assetDao.watchAssets().first).single;
        expect(asset.id, matches(r'^ast_[A-Za-z0-9]{12}$'));
        expect(asset.source, 'director');
        expect(
          asset.path,
          DirectorOutputOrchestrator.outputPath(
            task.operationId!,
            novelId: 'work',
            single: false,
          ),
        );
        expect(asset.durationMs, 5000);
        expect((asset.width, asset.height), (document.width, document.height));
        expect(asset.type, 'video');
        expect(await File(library.resolve(asset)).exists(), true);
        final manifest =
            jsonDecode(
                  await File(
                    '${task.result!.path}/manifest.json',
                  ).readAsString(),
                )
                as Json;
        expect(
          (manifest['width'], manifest['height']),
          (document.width, document.height),
        );
        await finish(task, task.result!, manifest);
        expect(await db.assetDao.watchAssets().first, hasLength(1));
        expect((await db.assetDao.watchAssets().first).single.id, asset.id);
        expect(runner.encodes, 1);
      },
    );
  }
  test(
    'frame count mismatch does not register; retry starts a new capture',
    () async {
      runner.frameCount = 119;
      final first = ExportTaskOrchestrator();
      addTearDown(first.dispose);
      await first.run(
        workspace: workspace,
        document: document,
        renderer: Frames(),
        cameraMode: 'fixed',
        cameraId: document.activeCameras.first['id'],
        savedRevisionId: 'saved',
        spaceProbe: (_) async => 1 << 40,
        onRendered: (dir, m) => finish(first, dir, m),
      );
      expect(first.state, OutputState.failed);
      expect(await db.assetDao.watchAssets().first, isEmpty);
      runner.frameCount = 120;
      final second = ExportTaskOrchestrator(), renderer = Frames();
      addTearDown(second.dispose);
      await second.run(
        workspace: workspace,
        document: document,
        renderer: renderer,
        cameraMode: 'fixed',
        cameraId: document.activeCameras.first['id'],
        savedRevisionId: 'current',
        spaceProbe: (_) async => 1 << 40,
        onRendered: (dir, m) => finish(second, dir, m),
      );
      expect(second.state, OutputState.completed);
      expect(renderer.frames, hasLength(120));
      expect(second.operationId, isNot(first.operationId));
      expect(await db.assetDao.watchAssets().first, hasLength(1));
    },
  );
  test(
    'PNG output records a single frozen frame without invoking the encoder',
    () async {
      final task = ExportTaskOrchestrator(), renderer = Frames();
      addTearDown(task.dispose);
      await task.run(
        workspace: workspace,
        document: document,
        renderer: renderer,
        cameraMode: 'fixed',
        cameraId: document.activeCameras.first['id'],
        savedRevisionId: 'saved',
        singleFrame: 35,
        spaceProbe: (_) async => 1 << 40,
        onRendered: (dir, m) => finish(task, dir, m),
      );
      expect(task.state, OutputState.completed);
      expect(renderer.frames, [35]);
      expect(runner.encodes, 0);
      final asset = (await db.assetDao.watchAssets().first).single;
      expect(asset.type, 'image');
      expect(asset.mimeType, 'image/png');
      expect(asset.durationMs, isNull);
      expect(
        asset.path,
        p.join(
          'file_workspaces',
          'work',
          'images',
          'director',
          task.operationId!,
          'still.png',
        ),
      );
      expect(await File(library.resolve(asset)).readAsBytes(), [
        137,
        80,
        78,
        71,
        35,
      ]);
    },
  );
}
