// 职责: 验证拖入文本和媒体的落点、持久化、错误边界与撤销重做。
// 关联文件:
//   lib/desktop/features/production/drop_orchestrator.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_clipboard/super_clipboard.dart' as clip;
import 'package:reveric/desktop/features/production/drop_orchestrator.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/production/canvas_history.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NovelContentDatabase db;
  late app.AppDatabase assets;
  late Directory root;
  late ProductionCanvasService service;
  late CanvasHistory history;
  late String canvas;
  setUp(() async {
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    assets = app.AppDatabase.forTest(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('production-drop-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
    final initial = await ScreenplayService(db).createInitialStructure();
    final shots = StoryboardService(db);
    service = ProductionCanvasService(
      shots,
      MediaLibraryService(assets, _Media(), root),
      'work',
    );
    canvas = (await service.ensureCanvas(initial.episodeId)).id;
    history = CanvasHistory(shots, canvas);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    history.dispose();
    await db.close();
    await assets.close();
    await root.delete(recursive: true);
  });
  Future<void> drop(clip.DataReader reader) => ProductionDropOrchestrator().run(
    reader: reader,
    service: service,
    canvasId: canvas,
    position: const Offset(-120, 315),
    history: history,
  );
  Future<List<CanvasNode>> nodes() async =>
      (await service.watchContent(canvas).first).nodes;

  test(
    'selected text preserves whitespace and exact position through undo/redo',
    () async {
      await drop(_Reader(text: '  中文\nsecond line  '));
      final node = (await nodes()).single;
      expect(node.content, '  中文\nsecond line  ');
      expect((node.x, node.y), (-120, 315));
      await history.undo();
      expect(await nodes(), isEmpty);
      await history.redo();
      expect((await nodes()).single.toJson(), node.toJson());
    },
  );
  test('file URI takes priority over accompanying filename text', () async {
    final file = await File('${root.path}/场景.MD').writeAsString('第一场\n正文');
    await drop(_Reader(uri: file.uri, text: '场景.MD'));
    final node = (await nodes()).single;
    expect(node.title, '场景');
    expect(node.content, '第一场\n正文');
    expect(await file.readAsString(), '第一场\n正文');
  });
  for (final extension in ['png', 'mp4', 'mp3']) {
    test('$extension imports a durable asset at the drop point', () async {
      final bytes = extension == 'png'
          ? base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            )
          : List<int>.filled(128, 42);
      final file = await File('${root.path}/素材.$extension').writeAsBytes(bytes);
      await drop(_Reader(uri: file.uri));
      final node = (await nodes()).single;
      final asset = await service.requireAsset(node.mediaAssetId!);
      expect(
        asset.type,
        {'png': 'image', 'mp4': 'video', 'mp3': 'audio'}[extension],
      );
      expect((node.x, node.y), (-120, 315));
      expect(service.library.resolve(asset), isNot(file.path));
      expect(await File(service.library.resolve(asset)).readAsBytes(), bytes);
      await history.undo();
      expect(await nodes(), isEmpty);
      await history.redo();
      expect((await nodes()).single.mediaAssetId, asset.id);
      expect(await file.exists(), isTrue);
    });
  }
  for (final valid in [true, false]) {
    test('native bitmap stream cleans temporary files, valid=$valid', () async {
      final bytes = valid
          ? base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            )
          : Uint8List.fromList([1, 2]);
      if (valid) {
        await drop(_FileReader(bytes));
        expect((await nodes()).single.mediaAssetId, isNotNull);
      } else {
        await expectLater(
          drop(_FileReader(bytes)),
          throwsA(isA<MediaException>()),
        );
        expect(await nodes(), isEmpty);
      }
      expect(
        await root
            .list()
            .where(
              (entry) =>
                  entry.path.contains('production-drop-', root.path.length),
            )
            .toList(),
        isEmpty,
      );
    });
  }
  test(
    'unsupported, empty and missing files create no nodes or history',
    () async {
      for (final name in ['empty.txt', 'unknown.zip']) {
        final file = await File('${root.path}/$name').writeAsString('');
        await expectLater(drop(_Reader(uri: file.uri)), throwsFormatException);
      }
      await expectLater(drop(_Reader(text: '  ')), throwsFormatException);
      await expectLater(
        drop(_Reader(uri: Uri.file('${root.path}/missing.txt'))),
        throwsA(isA<FileSystemException>()),
      );
      expect(await nodes(), isEmpty);
      expect(history.canUndo, isFalse);
    },
  );
}

class _Reader extends clip.DataReader {
  _Reader({this.text, this.uri});
  final String? text;
  final Uri? uri;
  @override
  List<clip.DataFormat> getFormats(List<clip.DataFormat> formats) => formats
      .where(
        (f) =>
            (f == clip.Formats.plainText && text != null) ||
            (f == clip.Formats.fileUri && uri != null),
      )
      .toList();
  @override
  clip.ReadProgress? getValue<T extends Object>(
    clip.ValueFormat<T> format,
    clip.AsyncValueChanged<T?> onValue, {
    void Function(Object)? onError,
  }) {
    onValue((identical(format, clip.Formats.fileUri) ? uri : text) as T?);
    return _Progress();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Progress implements clip.ReadProgress {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Media extends MediaService {
  _Media() : super(FfmpegRunner());
  @override
  Future<MediaInfo> probe(
    String path, {
    MediaCancellation? cancellation,
  }) async {
    final audio = path.endsWith('.mp3');
    return MediaInfo(
      duration: const Duration(seconds: 1),
      hasAudio: true,
      hasVideo: !audio,
      width: audio ? null : 640,
      height: audio ? null : 360,
      formatName: audio ? 'mp3' : 'mov,mp4',
    );
  }
}

class _FileReader extends _Reader {
  _FileReader(this.bytes);
  final Uint8List bytes;
  @override
  List<clip.DataFormat> getFormats(List<clip.DataFormat> formats) =>
      formats.where((f) => f == clip.Formats.png).toList();
  @override
  clip.ReadProgress? getFile(
    clip.FileFormat? format,
    clip.AsyncValueChanged<clip.DataReaderFile> onFile, {
    void Function(Object)? onError,
    bool allowVirtualFiles = true,
    bool synthesizeFilesFromURIs = true,
  }) {
    onFile(_FileData(bytes));
    return _Progress();
  }
}

class _FileData implements clip.DataReaderFile {
  _FileData(this.bytes);
  final Uint8List bytes;
  @override
  Stream<Uint8List> getStream() => Stream.value(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
