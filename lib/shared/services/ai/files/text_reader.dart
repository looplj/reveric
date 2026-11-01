// 职责: 流式解码文本并生成有界的按行分页和 Unicode 安全续读游标。
// 关联文件:
//   lib/shared/services/ai/files/reader.dart
//   lib/shared/services/production/ffmpeg_runner.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../../../models/tool_permission.dart';
import '../../production/ffmpeg_runner.dart';

String decodeText(Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 255 && bytes[1] == 254) ||
          (bytes[0] == 254 && bytes[1] == 255))) {
    if (bytes.length.isOdd) {
      throw const FormatException('Incomplete UTF-16 text');
    }
    final endian = bytes[0] == 255 ? Endian.little : Endian.big;
    final data = ByteData.sublistView(bytes);
    final units = [
      for (var i = 2; i < bytes.length; i += 2) data.getUint16(i, endian),
    ];
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
          throw const FormatException('Invalid UTF-16 text');
        }
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const FormatException('Invalid UTF-16 text');
      }
    }
    final text = String.fromCharCodes(units);
    if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(text)) {
      throw const FormatException('Binary files cannot be read as text');
    }
    return text;
  }
  final text = utf8.decode(bytes);
  if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(text)) {
    throw const FormatException('Binary files cannot be read as text');
  }
  return text;
}

Stream<String> _decoded(File file) async* {
  final handle = await file.open();
  final List<int> prefix;
  try {
    prefix = await handle.read(2);
  } finally {
    await handle.close();
  }
  final utf16 =
      prefix.length == 2 &&
      ((prefix[0] == 255 && prefix[1] == 254) ||
          (prefix[0] == 254 && prefix[1] == 255));
  if (!utf16) {
    await for (final text in file.openRead().transform(utf8.decoder)) {
      if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(text)) {
        throw const FormatException('Binary files cannot be read as text');
      }
      yield text;
    }
    return;
  }
  var pending = <int>[];
  final little = prefix[0] == 255;
  await for (final chunk in file.openRead(2)) {
    final bytes = [...pending, ...chunk];
    var end = bytes.length - bytes.length % 2;
    if (end >= 2) {
      final last = little
          ? bytes[end - 2] + (bytes[end - 1] << 8)
          : (bytes[end - 2] << 8) + bytes[end - 1];
      if (last >= 0xd800 && last <= 0xdbff) {
        end -= 2;
      }
    }
    pending = bytes.sublist(end);
    if (end > 0) {
      yield decodeText(Uint8List.fromList([...prefix, ...bytes.take(end)]));
    }
  }
  if (pending.isNotEmpty) {
    yield decodeText(Uint8List.fromList([...prefix, ...pending]));
  }
}

Future<Map<String, dynamic>> readTextPage(
  File file,
  Map<String, dynamic> options, {
  MediaCancellation? cancellation,
}) async {
  const maximum = 64 * 1024;
  var offset = options['offset'] ?? 0;
  final limit = options['limit'] ?? 200;
  var skip = 0;
  final continuation = options['continuation'];
  if (continuation != null) {
    if (options.containsKey('offset') ||
        options.containsKey('limit') ||
        continuation is! String) {
      throw const FormatException(
        'continuation cannot be combined with offset or limit',
      );
    }
    final value = jsonDecode(utf8.decode(base64Url.decode(continuation)));
    if (value is! Map || value['line'] is! int || value['skip'] is! int) {
      throw const FormatException('Invalid continuation');
    }
    offset = value['line'];
    skip = value['skip'] as int;
  }
  if (offset is! int ||
      offset < 0 ||
      limit is! int ||
      limit < 1 ||
      limit > 1000 ||
      skip < 0) {
    throw const FormatException(
      'offset must be nonnegative and limit must be 1..1000',
    );
  }
  final output = StringBuffer();
  final pending = StringBuffer();
  var used = 0;
  var pendingBytes = 0;
  var line = 0;
  var position = 0;
  Map<String, dynamic> result(bool more, {bool partial = false}) => {
    'text': output.toString(),
    'has_more': more,
    'truncated': more,
    'next_offset': line,
    if (partial)
      'continuation': base64Url.encode(
        utf8.encode(jsonEncode({'line': line, 'skip': position})),
      ),
  };
  await for (final chunk in _decoded(file)) {
    if (cancellation?.cancelled ?? false) {
      throw const ToolOperationException(
        'cancelled',
        'File reading was cancelled.',
      );
    }
    for (final rune in chunk.runes) {
      if (line < offset) {
        if (rune == 10) {
          line++;
        }
        continue;
      }
      if (line >= offset + limit) {
        return result(true);
      }
      final part = String.fromCharCode(rune);
      if (line == offset && position < skip) {
        if (rune == 10 || position + part.length > skip) {
          throw const FormatException('Invalid continuation');
        }
        position += part.length;
        continue;
      }
      final count = utf8.encode(part).length;
      if (used > 0 && used + pendingBytes + count > maximum) {
        return result(true);
      }
      if (pendingBytes + count > maximum) {
        output.write(pending);
        return result(true, partial: true);
      }
      pending.write(part);
      pendingBytes += count;
      position += part.length;
      if (rune == 10) {
        output.write(pending);
        used += pendingBytes;
        pending.clear();
        pendingBytes = 0;
        position = 0;
        line++;
      }
    }
  }
  if (line == offset && position < skip) {
    throw const FormatException('Invalid continuation');
  }
  output.write(pending);
  return result(false);
}
