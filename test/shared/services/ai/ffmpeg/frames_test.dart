// 职责: 验证视频多点检查的顺序、图片返回、边界拒绝及取消清理。
// 关联文件:
//   lib/shared/services/ai/ffmpeg/command.dart
//   lib/shared/services/production/contact_sheet.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/services/ai/ffmpeg/command.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';

class _Runner extends FfmpegRunner {
  final commands = <List<String>>[];
  bool audioOnly = false, cancelCapture = false, emptyCapture = false;
  @override
  Future<String> execute(
    List<String> args, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    commands.add(args);
    if (probe) {
      return jsonEncode({
        'streams': [
          {
            'codec_type': audioOnly ? 'audio' : 'video',
            'width': 160,
            'height': 90,
          },
        ],
        'format': {'duration': '5'},
      });
    }
    if (cancelCapture) {
      await cancellation.cancel();
    }
    if (!emptyCapture) {
      final at = double.parse(args[args.indexOf('-ss') + 1]);
      final frame = img.Image(width: 160, height: 90);
      img.fill(
        frame,
        color: at == 0 ? img.ColorRgb8(255, 0, 0) : img.ColorRgb8(0, 0, 255),
      );
      await File(args.last).writeAsBytes(img.encodePng(frame));
    }
    return '';
  }
}

void main() {
  late Directory support;
  late Directory root;
  late SessionFiles files;
  late _Runner runner;
  late FfmpegCommand command;
  setUp(() async {
    support = await Directory.systemTemp.createTemp('frames-test-');
    support = Directory(await support.resolveSymbolicLinks());
    root = await Directory(
      '${support.path}/file_workspaces/work',
    ).create(recursive: true);
    files = SessionFiles(root: support.path, novelId: 'work');
    await File('${root.path}/source.mp4').writeAsBytes([1, 2, 3]);
    runner = _Runner();
    command = FfmpegCommand(files, runner);
  });
  tearDown(() => support.delete(recursive: true));

  test(
    'returns one labeled image preserving unsorted and duplicate samples',
    () async {
      final result = await command.frames('session', 'source.mp4', [
        2000,
        0,
        2000,
      ], MediaCancellation());
      expect(result['content_format'], 'session_files_v1');
      expect((result['content'] as List).single['type'], 'image');
      expect((result['cells'] as List).map((c) => c['timestamp_ms']), [
        2000,
        0,
        2000,
      ]);
      final output = await files.resolve(result['file_path'] as String);
      final sheet = img.decodeJpg(await output.readAsBytes())!;
      expect([sheet.width, sheet.height], [result['width'], result['height']]);
      expect(sheet.getPixel(80, 60).b, greaterThan(240));
      expect(sheet.getPixel(244, 60).r, greaterThan(240));
      expect(sheet.getPixel(80, 154).b, greaterThan(240));
      final capture = runner.commands[1];
      expect(
        capture,
        containsAll(['-protocol_whitelist', 'file', '-frames:v', '1']),
      );
      final input = capture[capture.indexOf('-i') + 1];
      expect(input, isNot('${root.path}/source.mp4'));
      expect(await File(input).exists(), false);
      expect(await File('${root.path}/source.mp4').readAsBytes(), [1, 2, 3]);
      expect(await (await files.directory('session')).list().length, 1);
    },
  );

  test(
    'rejects empty, excessive, negative and out of duration samples',
    () async {
      for (final positions in [
        <int>[],
        List.filled(17, 0),
        [-1],
        [5000],
      ]) {
        await expectLater(
          command.frames(
            'session',
            'source.mp4',
            positions,
            MediaCancellation(),
          ),
          throwsFormatException,
        );
      }
      runner.audioOnly = true;
      await expectLater(
        command.frames('session', 'source.mp4', [0], MediaCancellation()),
        throwsFormatException,
      );
      expect(
        runner.commands.where((args) => args.contains('-frames:v')),
        isEmpty,
      );
    },
  );

  test(
    'cancellation and missing decoded frame leave no partial sheet or scratch input',
    () async {
      runner.cancelCapture = true;
      await expectLater(
        command.frames('session', 'source.mp4', [0], MediaCancellation()),
        throwsA(
          isA<MediaException>().having(
            (e) => e.reason,
            'reason',
            MediaFailure.cancelled,
          ),
        ),
      );
      var input = runner.commands.last[runner.commands.last.indexOf('-i') + 1];
      expect(await File(input).exists(), false);
      runner.cancelCapture = false;
      runner.emptyCapture = true;
      await expectLater(
        command.frames('session', 'source.mp4', [4900], MediaCancellation()),
        throwsFormatException,
      );
      input = runner.commands.last[runner.commands.last.indexOf('-i') + 1];
      expect(await File(input).exists(), false);
      expect(await (await files.directory('session')).list().length, 0);
    },
  );
}
