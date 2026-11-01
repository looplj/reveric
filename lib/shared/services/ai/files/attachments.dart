// 职责: 转换命令文件结果的展示路径，并按持久化副本引用加载模型内容。
// 关联文件:
//   lib/shared/agent/message.dart
//   lib/shared/agent/tool_result.dart
//   lib/shared/services/ai/files/session_files.dart
//   lib/shared/services/ai/agent_message_mapping.dart
//   lib/shared/utils/storage_paths.dart
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:image/image.dart' as img;
import '../../../agent/message.dart';
import '../../../agent/tool_result.dart';
import '../../../utils/storage_paths.dart';
import 'session_files.dart';

const maxAttachmentBytes = 3 * 1024 * 1024;
const maxAttachmentTotalBytes = 8 * 1024 * 1024;

/// Command paths are reusable within a work; snapshots retain application-root
/// references for chat replay, branch copies and backup collection.
Map<String, dynamic> commandFileResult(
  Map<String, dynamic> payload,
  SessionFiles files,
) {
  final id = files.novelId;
  if (id == null || id.isEmpty || id == 'shared') {
    throw const FormatException('File command results require a current work.');
  }
  final workspace = RevericPaths.fileWorkspaceDirectory(id);
  final absoluteWorkspace = p.join(files.root, workspace);
  String reference(String path) {
    if (p.posix.isWithin(workspace, path)) {
      return p.posix.relative(path, from: workspace);
    }
    if (p.isAbsolute(path) && p.isWithin(absoluteWorkspace, path)) {
      return p.posix.joinAll(
        p.split(p.relative(path, from: absoluteWorkspace)),
      );
    }
    return path;
  }

  Map<String, dynamic> item(Map<String, dynamic> value) {
    final result = Map<String, dynamic>.of(value);
    final stored = value['file_path'];
    if (stored is String) {
      result['file_path'] = reference(stored);
      if (SessionFiles.isSessionPath(stored)) {
        result.putIfAbsent('snapshot_path', () => stored);
      }
    }
    for (final key in ['source_file_path', 'result_file_path']) {
      if (value[key] case final String path) {
        result[key] = reference(path);
      }
    }
    return result;
  }

  final result = item(payload);
  for (final key in ['content', 'files']) {
    if (payload[key] case final List values) {
      result[key] = values.map((value) {
        if (value is! Map<String, dynamic>) {
          return value;
        }
        final converted = item(value);
        // FileReader emits one JSON metadata text block alongside its content.
        // Convert only that envelope, never paths mentioned in file text.
        if (key == 'content' &&
            payload['content_format'] == 'session_files_v1' &&
            payload['kind'] != null &&
            value['type'] == 'text' &&
            value['text'] is String) {
          final metadata = jsonDecode(value['text'] as String);
          if (metadata is Map<String, dynamic> &&
              metadata['file_path'] == payload['file_path'] &&
              metadata['kind'] == payload['kind']) {
            converted['text'] = jsonEncode(item(metadata));
          }
        }
        return converted;
      }).toList();
    }
  }
  if (payload['result'] case final Map<String, dynamic> nested) {
    result['result'] = commandFileResult(nested, files);
  }
  return result;
}

/// Only the explicitly versioned file-result contract contains model content.
/// Other tools may use a field called content with unrelated business meaning.
Map<String, dynamic>? fileContentPayload(Map<String, dynamic> payload) {
  if (payload['content_format'] == 'session_files_v1') {
    return payload;
  }
  final result = payload['result'];
  if (result is Map<String, dynamic>) {
    return fileContentPayload(result);
  }
  return null;
}

/// File closure is separate from multimodal hydration. Media delivery results
/// explicitly reference session snapshots without supplying model image blocks.
Iterable<String> resultFilePaths(Map<String, dynamic> payload) sync* {
  if (payload['content_format'] == 'session_files_v1') {
    final snapshot = payload['snapshot_path'] ?? payload['file_path'];
    if (snapshot is String) {
      yield snapshot;
    }
    for (final item in payload['content'] as List? ?? const []) {
      if (item is Map &&
          item['type'] == 'image' &&
          (item['snapshot_path'] ?? item['file_path']) is String) {
        yield (item['snapshot_path'] ?? item['file_path']) as String;
      }
    }
  }
  if (payload['content_format'] == 'session_files_v1' ||
      payload['ok'] is bool) {
    for (final file
        in payload['files'] is List ? payload['files'] as List : const []) {
      if (file is Map &&
          file['snapshot_path'] is String &&
          (payload['content_format'] == 'session_files_v1' ||
              (file['delivered'] is bool &&
                  file['file_path'] is String &&
                  SessionFiles.isSessionPath(
                    file['snapshot_path'] as String,
                  )))) {
        yield file['snapshot_path'] as String;
      }
    }
  }
  final result = payload['result'];
  if (result is Map<String, dynamic>) {
    yield* resultFilePaths(result);
  }
}

Future<List<MessageBlock>> assembleToolResultContent(
  Map<String, dynamic> payload, {
  String? root,
}) async {
  final result = fileContentPayload(payload);
  if (result == null) {
    return [TextBlock(jsonEncode(payload))];
  }
  final blocks = <MessageBlock>[TextBlock(jsonEncode(payload))];
  final files = SessionFiles(root: root);
  var total = 0;
  for (final item in result['content'] as List? ?? const []) {
    if (item is! Map) {
      continue;
    }
    if (item['type'] == 'text' && item['text'] is String) {
      blocks.add(TextBlock(item['text'] as String));
    } else if (item['type'] == 'image') {
      final path = item['snapshot_path'] ?? item['file_path'];
      final mime = item['mime_type'];
      try {
        if (path is! String ||
            !SessionFiles.isSessionPath(path) ||
            !{'image/png', 'image/jpeg'}.contains(mime)) {
          throw const FormatException('Invalid image reference');
        }
        final file = await files.resolve(path);
        final length = await file.length();
        if (length > maxAttachmentBytes ||
            total + length > maxAttachmentTotalBytes) {
          throw const FormatException('Image reference exceeds limits');
        }
        final bytes = await file.readAsBytes();
        if (bytes.length > maxAttachmentBytes ||
            total + bytes.length > maxAttachmentTotalBytes) {
          throw const FormatException('Image reference exceeds limits');
        }
        final decoder = img.findDecoderForData(bytes);
        final info = decoder?.startDecode(bytes);
        if (info == null ||
            info.width > 2048 ||
            info.height > 2048 ||
            decoder!.decodeFrame(0) == null) {
          throw const FormatException('Unreadable image reference');
        }
        total += bytes.length;
        blocks.add(
          ImageBlock(data: base64Encode(bytes), mimeType: mime as String),
        );
      } catch (_) {
        // Explicit historical contract: unavailable copies never interrupt chat.
        blocks.add(TextBlock('Image unavailable: $path'));
      }
    }
  }
  return blocks.isEmpty ? [TextBlock(jsonEncode(payload))] : blocks;
}

Future<Map<String, dynamic>> prepareToolResult(
  Map<String, dynamic> result,
) async {
  if (fileContentPayload(result) == null) {
    return result;
  }
  return StructuredToolResult(
    result,
    content: await assembleToolResultContent(result),
  );
}
