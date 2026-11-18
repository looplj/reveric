// 职责: 将采样画面拼成有标签、尺寸受限的 JPEG 检查图。
// 关联文件:
//   lib/shared/services/director/contact_sheet.dart
//   lib/shared/services/editing/render_service.dart
//   lib/shared/services/ai/ffmpeg/command.dart
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;

const contactSheetMaxFrames = 16;
const contactSheetMaxSide = 2048;
const _maxCell = 640, _gap = 4;

class ContactSheet {
  const ContactSheet(this.jpeg, this.width, this.height, this.cells);
  final Uint8List jpeg;
  final int width, height;
  final List<Map<String, dynamic>> cells;
}

List<int> contactSheetPositions(Object? value, String name, {int? end}) {
  if (value is! List ||
      value.isEmpty ||
      value.length > contactSheetMaxFrames ||
      value.any((v) => v is! int || v < 0 || (end != null && v >= end))) {
    throw FormatException(
      '$name must contain 1–$contactSheetMaxFrames nonnegative integers${end == null ? "" : " less than $end"}.',
    );
  }
  return List<int>.unmodifiable(value.cast<int>());
}

Future<ContactSheet> composeContactSheet(
  List<Uint8List> captures,
  List<Map<String, dynamic>> cells,
  int width,
  int height,
) async {
  if (captures.isEmpty ||
      captures.length > contactSheetMaxFrames ||
      captures.length != cells.length ||
      width <= 0 ||
      height <= 0) {
    throw ArgumentError('Invalid contact sheet dimensions or cells');
  }
  final labels = cells.map((cell) => cell['label'] as String).toList();
  final result = await Isolate.run(
    () => _compose(captures, labels, width, height),
  );
  return ContactSheet(result.$1, result.$2, result.$3, cells);
}

(Uint8List, int, int) _compose(
  List<Uint8List> captures,
  List<String> labels,
  int sourceWidth,
  int sourceHeight,
) {
  final count = captures.length;
  final columns = count <= 1
      ? 1
      : count <= 4
      ? 2
      : count <= 9
      ? 3
      : 4;
  final rows = (count / columns).ceil();
  final aspect = sourceWidth / sourceHeight;
  var cellWidth = math.min(
    math.min(sourceWidth, count == 1 ? contactSheetMaxSide : _maxCell),
    (contactSheetMaxSide - _gap * (columns - 1)) ~/ columns,
  );
  var cellHeight = (cellWidth / aspect).round();
  final rowLimit = (contactSheetMaxSide - _gap * (rows - 1)) ~/ rows;
  if (cellHeight > rowLimit) {
    cellHeight = rowLimit;
    cellWidth = (cellHeight * aspect).round();
  }
  final sheet = img.Image(
    width: columns * cellWidth + _gap * (columns - 1),
    height: rows * cellHeight + _gap * (rows - 1),
  );
  img.fill(sheet, color: img.ColorRgb8(32, 32, 32));
  for (var i = 0; i < count; i++) {
    final decoded = img.decodeImage(captures[i]);
    if (decoded == null) {
      throw StateError('capture_decode_failed');
    }
    final x = (i % columns) * (cellWidth + _gap),
        y = (i ~/ columns) * (cellHeight + _gap);
    img.compositeImage(
      sheet,
      img.copyResize(
        decoded,
        width: cellWidth,
        height: cellHeight,
        interpolation: img.Interpolation.average,
      ),
      dstX: x,
      dstY: y,
    );
    final font = img.arial24;
    final textWidth = labels[i]
        .split('')
        .fold(0, (sum, ch) => sum + font.characterXAdvance(ch));
    img.fillRect(
      sheet,
      x1: x,
      y1: y,
      x2: x + textWidth + 12,
      y2: y + font.lineHeight + 6,
      color: img.ColorRgba8(0, 0, 0, 180),
    );
    img.drawString(
      sheet,
      labels[i],
      font: font,
      x: x + 6,
      y: y + 3,
      color: img.ColorRgb8(255, 255, 255),
    );
  }
  return (img.encodeJpg(sheet, quality: 85), sheet.width, sheet.height);
}
