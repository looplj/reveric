// 职责: 校验并持久暂存 Provider 图片响应，登记调用归属后发放输出句柄。
// 关联文件:
//   lib/shared/services/plugins/files.dart
//   lib/shared/services/plugins/host.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart' show compute;
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import 'files.dart';
import 'runtime.dart';

class PluginMediaFiles {
  PluginMediaFiles({required this.directory, required this.scope});
  final Directory directory;
  final PluginFileScope scope;
  final _outputs = <String, File>{};
  final _owned = <String>{};
  final _descriptors = <String, ({String mimeType, int byteLength})>{};

  Future<Map<String, dynamic>> stage(
    List<int> bytes, {
    void Function()? ensureActive,
  }) async {
    ensureActive?.call();
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (!await compute(_validImage, data)) {
      throw PluginHostError(
        'invalid_response',
        'Provider output is not a valid image',
      );
    }
    final mime = lookupMimeType('', headerBytes: data);
    if (mime == null || !mime.startsWith('image/')) {
      throw PluginHostError('invalid_response', 'Unrecognized image format');
    }
    ensureActive?.call();
    await directory.create(recursive: true);
    ensureActive?.call();
    final handle = const Uuid().v4();
    final subtype = mime.split('/').last;
    final extension = subtype == 'jpeg' ? 'jpg' : subtype;
    final file = File(
      '${directory.path}/reveric_image_result_$handle.$extension.part',
    );
    // Write ownership first, so a crash during the file write never leaves an unowned output.
    await File('${directory.path}/$handle.json').writeAsString(
      jsonEncode({
        'handle': handle,
        'pluginId': scope.pluginId,
        'providerId': scope.providerId,
        'taskId': scope.taskId,
        'path': file.path,
        'mimeType': mime,
        'byteLength': data.length,
        'confirmed': false,
        'sha256': sha256.convert(data).toString(),
      }),
      flush: true,
    );
    ensureActive?.call();
    await file.writeAsBytes(data, flush: true);
    ensureActive?.call();
    _outputs[handle] = file;
    _owned.add(handle);
    _descriptors[handle] = (mimeType: mime, byteLength: data.length);
    return {
      'kind': 'file',
      'handle': handle,
      'mimeType': mime,
      'byteLength': data.length,
    };
  }

  Future<void> confirm(
    String handle,
    List<Map<String, dynamic>> receipt,
  ) async {
    if (!_owned.contains(handle)) {
      return;
    }
    output(handle);
    final record = File('${directory.path}/$handle.json');
    final value =
        jsonDecode(await record.readAsString()) as Map<String, dynamic>;
    value['confirmed'] = true;
    value['confirmedAt'] = DateTime.now().microsecondsSinceEpoch;
    value['receipt'] = receipt;
    final next = File('${record.path}.next');
    await next.writeAsString(jsonEncode(value), flush: true);
    await next.rename(record.path);
  }

  Map<String, dynamic> bindRecovered(
    File file,
    String mimeType,
    int byteLength,
  ) {
    final handle = const Uuid().v4();
    _outputs[handle] = file;
    _descriptors[handle] = (mimeType: mimeType, byteLength: byteLength);
    return {
      'kind': 'file',
      'handle': handle,
      'mimeType': mimeType,
      'byteLength': byteLength,
    };
  }

  Future<void> discard(String handle) async {
    final file = output(handle);
    if (_owned.remove(handle)) {
      if (await file.exists()) {
        await file.delete();
      }
      final record = File('${directory.path}/$handle.json');
      if (await record.exists()) {
        await record.delete();
      }
    }
    _outputs.remove(handle);
    _descriptors.remove(handle);
  }

  void validateOutput(String handle, String mimeType, int byteLength) {
    output(handle);
    final descriptor = _descriptors[handle]!;
    if (descriptor.mimeType != mimeType ||
        descriptor.byteLength != byteLength) {
      throw PluginHostError(
        'invalid_response',
        'Output metadata does not match the Host file',
      );
    }
  }

  File output(Object? handle) {
    final file = _outputs[handle];
    if (file == null) {
      throw PluginHostError(
        'invalid_response',
        'Output handle was not created by this invocation',
      );
    }
    return file;
  }
}

bool _validImage(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  return image != null && image.width > 0 && image.height > 0;
}
