// 职责: 校验 MCP 图片，保留工具结果并为模型与调用记录限制文本体积。
// 关联文件:
//   lib/shared/models/mcp/call_result.dart
//   lib/shared/services/mcp/tool_dispatcher.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:mcp_dart/mcp_dart.dart' as sdk;
import '../../models/mcp/call_result.dart';

class McpResultAdapter {
  /// Budget for the model's JSON text. Image bytes have their own limits.
  static const modelBudget = 32 * 1024;
  static const _maxImageBytes = 3 * 1024 * 1024;
  static const _maxTotalImageBytes = 8 * 1024 * 1024;
  static const _maxImages = 8;
  static const _maxImageDimension = 4096;

  static McpCallResult normalize(Map<String, dynamic> raw) {
    final content = <sdk.Content>[];
    final text = <String>[];
    final unsupported = <String>{};
    final imageErrors = <String>{};
    var imageCount = 0;
    var imageBytes = 0;
    for (final item in (raw['content'] as List? ?? [])) {
      switch (item) {
        case {'type': 'text', 'text': final String value}:
          content.add(sdk.TextContent(text: value));
          text.add(value);
        case {'type': 'image'}:
          try {
            if (++imageCount > _maxImages) {
              throw const FormatException('image count exceeds 8');
            }
            final image = _readImage(item, imageBytes);
            imageBytes += image.bytes;
            content.add(image.content);
          } on FormatException catch (error) {
            imageErrors.add(error.message);
          }
        default:
          unsupported.add(item is Map ? '${item['type']}' : 'invalid');
      }
    }
    final structured = raw['structuredContent'];
    if (structured != null && structured is! Map<String, dynamic>) {
      unsupported.add('structuredContent_non_object');
    }
    final failed = raw['isError'] == true;
    return McpCallResult(
      executionState: failed
          ? McpExecutionState.failed
          : McpExecutionState.succeeded,
      content: [
        ...content,
        if (unsupported.isNotEmpty)
          sdk.TextContent(
            text:
                '[Unsupported MCP content omitted: ${unsupported.join(', ')}]',
          ),
        if (imageErrors.isNotEmpty)
          sdk.TextContent(
            text: '[MCP image omitted: ${imageErrors.join('; ')}]',
          ),
      ],
      structuredContent: structured is Map<String, dynamic> ? structured : null,
      errorCode: failed ? 'mcp_tool_error' : null,
      error: failed
          ? String.fromCharCodes(text.join('\n').runes.take(2048))
          : null,
    );
  }

  static ({sdk.ImageContent content, int bytes}) _readImage(
    Map item,
    int usedBytes,
  ) {
    final data = item['data'];
    final mimeType = item['mimeType'];
    if (data is! String || data.isEmpty || mimeType is! String) {
      throw const FormatException('missing image data or MIME type');
    }
    if (data.length > (_maxImageBytes + 2) ~/ 3 * 4) {
      throw const FormatException('image exceeds 3 MiB');
    }
    final decoder = switch (mimeType) {
      'image/png' => img.PngDecoder(),
      'image/jpeg' => img.JpegDecoder(),
      'image/webp' => img.WebPDecoder(),
      _ => throw const FormatException('unsupported image MIME type'),
    };
    final Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      throw const FormatException('invalid base64');
    }
    if (bytes.length > _maxImageBytes ||
        usedBytes + bytes.length > _maxTotalImageBytes) {
      throw const FormatException('image exceeds byte budget');
    }
    try {
      final info = decoder.startDecode(bytes);
      if (info == null || info.width <= 0 || info.height <= 0) {
        throw const FormatException('unreadable image');
      }
      if (info.width > _maxImageDimension || info.height > _maxImageDimension) {
        throw const FormatException('image dimensions exceed 4096 pixels');
      }
    } on Exception catch (error) {
      if (error is FormatException) {
        rethrow;
      }
      throw const FormatException('unreadable image');
    } on RangeError {
      throw const FormatException('unreadable image');
    }
    return (
      content: sdk.ImageContent(data: base64Encode(bytes), mimeType: mimeType),
      bytes: bytes.length,
    );
  }

  static McpCallResult limit(McpCallResult result, int budget) {
    if (result.textJsonBytes <= budget) {
      return result;
    }
    // Only model-facing output and history previews are shortened here.
    // Full-output storage and readback are not implemented; omitted preview
    // content cannot be recovered through a result reference. Scripts receive
    // the original result before this display-only conversion.
    var structured = result.structuredContent;
    final images = result.content.whereType<sdk.ImageContent>().toList();
    McpCallResult build(List<String> text) => McpCallResult(
      executionState: result.executionState,
      content: [
        for (final value in text) sdk.TextContent(text: value),
        ...images,
      ],
      structuredContent: structured,
      errorCode: result.errorCode,
      error: result.error,
      cancelled: result.cancelled,
      rejected: result.rejected,
      recovery: result.ok
          ? 'The operation succeeded; this output is a truncated preview. Do not repeat a write.'
          : result.recovery,
    );
    // Keep small IDs and other structured results intact when text is large.
    // If the object itself is too large, show it as a JSON text preview instead
    // of inventing an incomplete object that looks usable by a program.
    final preview = <String>[];
    if (structured != null && build(const []).textJsonBytes > budget) {
      preview.add(jsonEncode(structured));
      structured = null;
    }
    preview.addAll(result.text);
    final full = build(preview);
    if (full.textJsonBytes <= budget) {
      return full;
    }
    if (build(const []).textJsonBytes > budget) {
      throw ArgumentError('MCP budget is too small for host status');
    }
    final runes = preview.join('\n').runes.toList();
    String excerpt(int count) {
      final head = (count + 1) ~/ 2;
      final tail = count ~/ 2;
      return '${String.fromCharCodes(runes.take(head))}\n[truncated]\n'
          '${String.fromCharCodes(runes.skip(runes.length - tail))}';
    }

    var low = 0;
    var high = runes.length;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (build([excerpt(middle)]).textJsonBytes <= budget) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    final bounded = build([excerpt(low)]);
    return bounded.textJsonBytes <= budget ? bounded : build(const []);
  }
}
