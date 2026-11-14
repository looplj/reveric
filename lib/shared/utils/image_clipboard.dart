// 职责: 将原尺寸图片编码为 PNG 并写入系统图片剪贴板，供外部应用粘贴。
// 关联文件:
//   lib/desktop/features/production/node_bar.dart
//   lib/desktop/features/asset/media_preview.dart
//   lib/shared/widgets/ai/chat/attachment_input.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:path/path.dart' as p;
import 'package:super_clipboard/super_clipboard.dart' as clip;

Future<void> copyImageToClipboard(
  File file, {
  required String name,
  clip.ClipboardWriter? clipboard,
}) async {
  final writer = clipboard ?? clip.SystemClipboard.instance;
  if (writer == null) {
    throw UnsupportedError('Image clipboard is unavailable');
  }
  final codec = await ui.instantiateImageCodec(await file.readAsBytes());
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('Image could not be encoded as PNG');
      }
      final item =
          clip.DataWriterItem(
            suggestedName: p.setExtension(p.basename(name), '.png'),
          )..add(
            clip.Formats.png(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            ),
          );
      await writer.write([item]);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
