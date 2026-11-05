// 职责: 将聊天草稿中的有序文件引用归档到会话，并恢复模型可读取的文字与图片块。
// 关联文件:
//   lib/shared/models/ai_message_block.dart
//   lib/shared/agent/message.dart
//   lib/shared/services/ai/files/session_files.dart
//   lib/shared/services/ai/image_reference_compression.dart
//   lib/shared/utils/text_file_decoder.dart
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../agent/message.dart';
import '../../logger/app_logger.dart';
import '../../models/ai_message_block.dart';
import '../../utils/random_id.dart';
import '../../utils/text_file_decoder.dart';
import 'files/session_files.dart';
import 'image_reference_compression.dart';

const chatImageMaxBytes = 1024 * 1024;
const chatImageMaxCount = 4;
const chatImageMaxDimension = 2048;
const chatImageJpegQuality = 85;
const chatTextMaxCharacters = 100000;
const chatFileExtensions = ['png', 'jpg', 'jpeg', 'webp', 'txt', 'md', 'csv'];
final _log = AppLogger.forModule('ChatAttachments');

class ChatAttachmentException implements Exception {
  const ChatAttachmentException(this.reason);
  final String reason;
  @override
  String toString() => 'ChatAttachmentException($reason)';
}

Object _safeFileError(Object error) => error is FileSystemException
    ? FileSystemException('Attachment I/O failed', '', error.osError)
    : error;

class NamedChatFile extends XFile {
  NamedChatFile.data(super.bytes, {required String name})
    : _displayName = name,
      super.fromData();
  NamedChatFile.path(super.path, {required String name}) : _displayName = name;
  final String _displayName;
  @override
  String get name => _displayName;
}

class ChatDraftAttachment {
  const ChatDraftAttachment(this.file, {this._name, this.imageNumber});
  final XFile file;
  final String? _name;
  final int? imageNumber;

  ChatDraftAttachment withImageNumber(int number) =>
      ChatDraftAttachment(file, name: _name, imageNumber: number);
  String get name => _name ?? file.name;
  bool get isImage => const [
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
  ].contains(p.extension(name).toLowerCase());
}

/// Snapshot captured at send/copy time; controller edits cannot mutate it.
class ChatDraft {
  ChatDraft(this.text, Map<String, ChatDraftAttachment> attachments)
    : attachments = Map.unmodifiable(attachments);
  final String text;
  final Map<String, ChatDraftAttachment> attachments;
  bool get hasImages => attachments.values.any((a) => a.isImage);
}

class ChatAttachmentOrchestrator {
  Future<List<AiMessageBlock>> prepare(
    String sessionId,
    ChatDraft draft, {
    required String novelId,
    String? root,
  }) async {
    final files = SessionFiles(root: root, novelId: novelId);
    _log.info(
      'prepare started session=$sessionId attachments=${draft.attachments.length}',
    );
    final blocks = <AiMessageBlock>[];
    var imageCount = 0;
    var textCharacters = 0;
    final pendingText = StringBuffer();
    void flushText() {
      if (pendingText.isNotEmpty) {
        blocks.add(
          AiTextBlock(id: buildRandomId('text'), text: pendingText.toString()),
        );
        pendingText.clear();
      }
    }

    try {
      for (final rune in draft.text.runes) {
        final token = String.fromCharCode(rune);
        final attachment = draft.attachments[token];
        if (attachment == null) {
          pendingText.write(token);
          continue;
        }
        flushText();
        final extension = p.extension(attachment.name).toLowerCase();
        if (!chatFileExtensions.contains(extension.replaceFirst('.', ''))) {
          throw const ChatAttachmentException('unsupported');
        }
        final sizeLimit = attachment.isImage ? 32 * 1024 * 1024 : 400003;
        if (await attachment.file.length() > sizeLimit) {
          throw const ChatAttachmentException('too_large');
        }
        var bytes = await attachment.file.readAsBytes();
        if (bytes.length > sizeLimit) {
          throw const ChatAttachmentException('too_large');
        }
        var outputExtension = extension;
        var mime = 'text/plain';
        if (attachment.isImage) {
          if (++imageCount > chatImageMaxCount) {
            throw const ChatAttachmentException('too_many');
          }
          final result = await Isolate.run(
            () => prepareChatImage(bytes, extension),
          );
          bytes = result.bytes;
          outputExtension = '.${result.extension}';
          mime = result.extension == 'jpg' || result.extension == 'jpeg'
              ? 'image/jpeg'
              : 'image/${result.extension}';
          _log.info(result.logLine);
        } else {
          final text = decodeImportedTextBytes(bytes);
          if (text.trim().isEmpty) {
            throw const ChatAttachmentException('empty');
          }
          textCharacters += text.runes.length;
          if (textCharacters > chatTextMaxCharacters) {
            throw const ChatAttachmentException('too_large');
          }
          bytes = Uint8List.fromList(utf8.encode(text));
        }
        final target = await files.allocate(sessionId, outputExtension);
        await target.writeAsBytes(bytes, flush: true);
        blocks.add(
          AiAttachmentBlock(
            id: buildRandomId('attachment'),
            name: attachment.name,
            path: files.reference(target),
            mimeType: mime,
            imageNumber: attachment.isImage
                ? attachment.imageNumber ?? imageCount
                : null,
          ),
        );
      }
      flushText();
      _log.info(
        'prepare completed session=$sessionId images=$imageCount textCharacters=$textCharacters',
      );
      return blocks;
    } catch (error, stack) {
      _log.error(
        'prepare failed session=$sessionId images=$imageCount',
        error: _safeFileError(error),
        stackTrace: stack,
      );
      // Files already owned by the session remain under its normal GC boundary.
      if (error is ChatAttachmentException) {
        rethrow;
      }
      throw const ChatAttachmentException('read_failed');
    }
  }
}

/// Fixed pipeline for vision input: cap the long edge, flatten any alpha onto
/// white, then encode once as JPEG at a fixed quality.
ImageReferenceCompressionResult prepareChatImage(
  Uint8List bytes,
  String extension,
) {
  img.Decoder? decoder;
  img.Image? decoded;
  try {
    decoder = img.findDecoderForData(bytes);
    if (decoder is! img.PngDecoder &&
        decoder is! img.JpegDecoder &&
        decoder is! img.WebPDecoder) {
      throw const ChatAttachmentException('invalid_image');
    }
    final info = decoder?.startDecode(bytes);
    if (info == null) {
      throw const ChatAttachmentException('invalid_image');
    }
    if (info.width * info.height > 64000000) {
      throw const ChatAttachmentException('too_large');
    }
    decoded = decoder!.decodeFrame(0);
    if (decoded == null) {
      throw const ChatAttachmentException('invalid_image');
    }
  } on ChatAttachmentException {
    rethrow;
  } catch (_) {
    throw const ChatAttachmentException('invalid_image');
  }
  var working = img.bakeOrientation(decoded);
  if (working.width > chatImageMaxDimension ||
      working.height > chatImageMaxDimension) {
    final landscape = working.width >= working.height;
    working = img.copyResize(
      working,
      width: landscape ? chatImageMaxDimension : null,
      height: landscape ? null : chatImageMaxDimension,
    );
  }
  if (working.hasAlpha) {
    // JPEG drops alpha as-is, which turns transparent pixels black.
    final background = img.Image(width: working.width, height: working.height)
      ..clear(img.ColorRgb8(255, 255, 255));
    working = img.compositeImage(background, working);
  }
  final encoded = img.encodeJpg(working, quality: chatImageJpegQuality);
  if (encoded.length > chatImageMaxBytes) {
    throw const ChatAttachmentException('too_large');
  }
  return ImageReferenceCompressionResult(
    bytes: encoded,
    extension: 'jpg',
    logLine:
        'chat_image_encoded bytes=${encoded.length} '
        'dimensions=${working.width}x${working.height}',
  );
}

String chatBlocksText(Iterable<AiMessageBlock> blocks) => blocks
    .map(
      (b) => b is AiTextBlock
          ? b.text
          : b is AiAttachmentBlock
          ? b.isImage && b.imageNumber != null
                ? 'Image #${b.imageNumber}'
                : '[${b.name}]'
          : '',
    )
    .join();

String _attribute(String value) =>
    const HtmlEscape(HtmlEscapeMode.attribute).convert(value);

Future<List<MessageBlock>> hydrateChatBlocks(
  Iterable<AiMessageBlock> blocks, {
  String? root,
  bool strict = false,
}) async {
  final result = <MessageBlock>[];
  final files = SessionFiles(root: root);
  for (final block in blocks) {
    if (block is AiTextBlock) {
      result.add(TextBlock(block.text));
    } else if (block is AiAttachmentBlock) {
      final tag = block.isImage ? 'image' : 'file';
      final label = block.isImage && block.imageNumber != null
          ? 'Image #${block.imageNumber}'
          : block.name;
      final filename = label == block.name
          ? ''
          : ' filename="${_attribute(block.name)}"';
      result.add(
        TextBlock(
          '<$tag name="${_attribute(label)}"$filename path="${_attribute(block.path)}">',
        ),
      );
      try {
        if (!SessionFiles.isSessionPath(block.path)) {
          throw const FormatException('Attachment is outside session storage');
        }
        final file = await files.resolve(block.path);
        final limit = block.isImage ? chatImageMaxBytes : 400003;
        if (await file.length() > limit) {
          throw const FormatException('Attachment exceeds limit');
        }
        final bytes = await file.readAsBytes();
        if (bytes.length > limit) {
          throw const FormatException('Attachment exceeds limit');
        }
        result.add(
          block.isImage
              ? ImageBlock(data: base64Encode(bytes), mimeType: block.mimeType)
              : TextBlock(utf8.decode(bytes)),
        );
      } catch (error, stack) {
        _log.error(
          'attachment unavailable id=${block.id}',
          error: _safeFileError(error),
          stackTrace: stack,
        );
        if (strict) {
          throw const ChatAttachmentException('read_failed');
        }
        result.add(TextBlock('File unavailable: ${block.path}'));
      }
      result.add(TextBlock('</$tag>'));
    }
  }
  return result;
}
