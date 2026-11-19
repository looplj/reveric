// 职责: 原子保存导演预览图片、读取上次生成结果并通知画布刷新。
// 关联文件:
//   lib/shared/services/director/file_output.dart
//   lib/shared/services/director/storage.dart
//   lib/desktop/features/production/node_card.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md
//   .agents/rules/error-handling.md
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import '../../logger/app_logger.dart';
import 'storage.dart';

final _log = AppLogger.forModule('Director');

class DirectorPreview {
  DirectorPreview(this.storage);
  final DirectorStorage storage;
  static final _updates =
      StreamController<({String workspace, int sequence})>.broadcast();
  static int _sequence = 0;

  /// 图片落盘后通知对应工作区，不保留已关闭节点的缓存。
  static Stream<int> updates(String workspace) => _updates.stream
      .where((event) => event.workspace == workspace)
      .map((event) => event.sequence);
  File get image => File('${storage.root.path}/preview.png');

  Future<void> write(Uint8List bytes) async {
    await image.parent.create(recursive: true);
    final part = File('${image.path}.${const Uuid().v4()}.pending');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(image.path);
    _updates.add((
      workspace: path.basename(storage.root.path),
      sequence: ++_sequence,
    ));
  }

  Future<Uint8List?> read() async {
    try {
      if (!await image.exists()) {
        return null;
      }
      return await image.readAsBytes();
    } on FileSystemException catch (error, stack) {
      _log.error('preview cache read failed', error: error, stackTrace: stack);
      return null;
    }
  }
}
