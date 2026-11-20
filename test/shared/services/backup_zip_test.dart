// 职责: 验证磁盘中转备份 ZIP 的内容、压缩及跨平台条目路径兼容性。
// 关联文件:
//   lib/shared/services/backup_zip.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/backup_zip.dart';
import 'package:path/path.dart' as p;

void main() {
  test('backup ZIP preserves multi-chunk, empty and Unicode files', () async {
    final root = await Directory.systemTemp.createTemp('backup_zip_test_');
    try {
      final source = await Directory(p.join(root.path, 'source')).create();
      final random = Random(42);
      final payload = Uint8List.fromList(
        List.generate(2 * 1024 * 1024 + 17, (_) => random.nextInt(256)),
      );
      final expected = <String, List<int>>{
        '视频/随机.bin': payload,
        'empty.txt': [],
        '文本.txt': utf8.encode('备份正文\n' * 100000),
      };
      for (final entry in expected.entries) {
        final file = File(p.join(source.path, entry.key));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value);
      }
      final zipPath = p.join(root.path, 'backup.zip');
      await createBackupZip(source, zipPath);
      final input = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeStream(input);
      try {
        expect(
          archive.files.map((file) => file.name),
          unorderedEquals(expected.keys),
        );
        for (final entry in archive.files) {
          expect(entry.compression, CompressionType.deflate);
          expect(entry.size, expected[entry.name]!.length);
          expect(entry.crc32, getCrc32(expected[entry.name]!));
          expect(entry.content, orderedEquals(expected[entry.name]!));
        }
        // 保留正文压缩能力，不能用关闭压缩规避内存问题。
        expect(File(zipPath).lengthSync(), lessThan(payload.length + 10000));
      } finally {
        archive.clear();
        input.closeSync();
      }
    } finally {
      await root.delete(recursive: true);
    }
  });
}
