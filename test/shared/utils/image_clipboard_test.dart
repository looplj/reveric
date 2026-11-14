// 职责: 验证图片复制写入真实 PNG 数据、保留尺寸和透明度，以及失败时不覆盖剪贴板。
// 关联文件:
//   lib/shared/utils/image_clipboard.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/utils/image_clipboard.dart';
import 'package:super_clipboard/super_clipboard.dart' as clip;
// Inspect the representations produced by the locked clipboard dependency.
// ignore: depend_on_referenced_packages
import 'package:super_native_extensions/raw_clipboard.dart' as raw;

class _Clipboard implements clip.ClipboardWriter {
  final items = <clip.DataWriterItem>[];
  @override
  Future<void> write(Iterable<clip.DataWriterItem> items) async {
    this.items.addAll(items);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Clipboard clipboard;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('image-clipboard-test-');
    clipboard = _Clipboard();
  });
  tearDown(() => directory.delete(recursive: true));

  for (final extension in ['png', 'jpg']) {
    test('$extension is copied as full-size PNG image data', () async {
      final input = img.Image(width: 37, height: 19, numChannels: 4);
      img.fill(input, color: img.ColorRgba8(200, 100, 50, 128));
      final file = File('${directory.path}/source.$extension');
      await file.writeAsBytes(
        extension == 'png' ? img.encodePng(input) : img.encodeJpg(input),
      );
      await copyImageToClipboard(
        file,
        name: '原图.$extension',
        clipboard: clipboard,
      );
      final item = clipboard.items.single;
      expect(item.suggestedName, '原图.png');
      final encoded = await item.data.single;
      final representation =
          encoded.representations.single as raw.DataRepresentationSimple;
      expect(representation.format, clip.Formats.png.providerFormat);
      final decoded = img.decodePng(representation.data as Uint8List)!;
      expect((decoded.width, decoded.height), (37, 19));
      if (extension == 'png') {
        expect(decoded.getPixel(0, 0).a, 128);
      }
      // The clipboard holds bytes independent of the source file's lifetime.
      await file.delete();
      expect(img.decodePng(representation.data as Uint8List), isNotNull);
    });
  }

  test('missing or corrupt image does not overwrite clipboard', () async {
    final file = File('${directory.path}/missing.png');
    await expectLater(
      copyImageToClipboard(file, name: 'missing.png', clipboard: clipboard),
      throwsA(isA<FileSystemException>()),
    );
    await file.writeAsString('not an image');
    await expectLater(
      copyImageToClipboard(file, name: 'corrupt.png', clipboard: clipboard),
      throwsA(anything),
    );
    expect(clipboard.items, isEmpty);
  });
}
