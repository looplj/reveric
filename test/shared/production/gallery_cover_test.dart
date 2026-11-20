// 职责: 验证选作画廊封面的图片沿用现有封面压缩，长边不超过 1600 且体积不超过 2MB。
// 关联文件:
//   lib/shared/services/production/canvas_preview.dart

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/services/production/canvas_preview.dart';

void main() {
  test('compresses a chosen image with the gallery cover encoder', () async {
    final wide = img.Image(width: 2400, height: 900);
    img.fill(wide, color: img.ColorRgb8(30, 90, 140));
    final wideJpeg = await encodeProductionGalleryCover(
      Uint8List.fromList(img.encodeJpg(wide, quality: 95)),
    );
    final decoded = img.decodeJpg(wideJpeg)!;
    expect(wideJpeg.length, lessThanOrEqualTo(2 * 1024 * 1024));
    expect(math.max(decoded.width, decoded.height), lessThanOrEqualTo(1600));
    expect(decoded.width, greaterThan(decoded.height));

    final small = img.Image(width: 32, height: 16);
    img.fill(small, color: img.ColorRgb8(255, 0, 0));
    final smallJpeg = await encodeProductionGalleryCover(
      Uint8List.fromList(img.encodeJpg(small)),
    );
    final smallDecoded = img.decodeJpg(smallJpeg)!;
    expect(smallDecoded.width, 32);
    expect(smallDecoded.height, 16);
  });
}
