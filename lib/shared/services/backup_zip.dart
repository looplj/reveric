// 职责: 通过磁盘中转压缩数据，以有界文件缓冲创建备份 ZIP。
// 关联文件:
//   lib/shared/services/backup_service.dart

import 'dart:io';

import 'package:archive/archive_io.dart' hide ZLibEncoder;
import 'package:path/path.dart' as p;

/// 在工作 isolate 中调用；每次只保留一个文件的压缩临时副本。
Future<void> createBackupZip(Directory source, String zipPath) async {
  final scratch = await Directory.systemTemp.createTemp('reveric_zip_');
  try {
    final output = OutputFileStream(zipPath);
    try {
      final encoder = ZipEncoder()..startEncode(output);
      await for (final entity in source.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) {
          continue;
        }
        final compressed = File(p.join(scratch.path, 'entry.deflate'));
        var crc = 0;
        var size = 0;
        // archive 的默认压缩路径会在内存里累积整个压缩结果。
        // dart:io 的流转换及 pipe 保持背压，压缩结果直接落盘。
        await entity
            .openRead()
            .map((chunk) {
              crc = getCrc32(chunk, crc);
              size += chunk.length;
              return chunk;
            })
            .transform(ZLibEncoder(raw: true))
            .pipe(compressed.openWrite());

        final input = InputFileStream(compressed.path);
        try {
          final stat = await entity.stat();
          final entry =
              ArchiveFile.file(
                  p.posix.fromUri(
                    p.toUri(p.relative(entity.path, from: source.path)),
                  ),
                  size,
                  _DeflatedContent(input),
                )
                ..compression = CompressionType.deflate
                ..crc32 = crc
                ..mode = stat.mode
                ..lastModTime = stat.modified.millisecondsSinceEpoch ~/ 1000;
          encoder.add(entry, autoClose: false);
        } finally {
          input.closeSync();
        }
      }
      encoder.endEncode();
    } finally {
      output.closeSync();
    }
  } finally {
    await scratch.delete(recursive: true);
  }
}

// 仅向 ZIP 编码器提供预压缩数据，避免再次压缩和累积内存缓冲。
class _DeflatedContent extends FileContentStream {
  _DeflatedContent(super.stream);

  @override
  bool get isCompressed => true;
}
