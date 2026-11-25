// 职责: 管理混排聊天草稿、剪贴板快照及草稿消费前的提交防重入。
// 关联文件:
//   lib/shared/services/ai/chat_attachments.dart
//   lib/shared/models/ai_message_block.dart
//   lib/shared/widgets/ai/chat/attachment_input.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:cross_file/cross_file.dart';
import 'package:path/path.dart' as p;

import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/ai_message_block.dart';
import '../../../services/ai/chat_attachments.dart';
import '../../../theme/theme.dart';
import '../../../utils/storage_paths.dart';

ChatComposerController useChatComposerController() {
  final controller = useMemoized(ChatComposerController.new);
  useEffect(() => controller.dispose, [controller]);
  return controller;
}

class ComposerFileDrag {
  const ComposerFileDrag(this.controller, this.offset);
  final ChatComposerController controller;
  final int offset;
}

/// Each attachment occupies one UTF-16 unit, so native selection, IME and
/// deletion keep their standard offsets. Private-use characters never go on wire.
class ChatComposerController extends TextEditingController {
  final _attachments = <String, ChatDraftAttachment>{};
  int _nextToken = 0xe000;
  int _nextImageNumber = 1;

  Object? _submission;

  /// 同一份草稿只提交一次；编辑或消费草稿后即可提交下一条，无需等待模型回复。
  /// 初始化失败保留草稿，并在本次调用结束后允许重试。
  Future<void> submit(Future<void> Function() send) async {
    if (_submission != null) {
      return;
    }
    final submission = Object();
    _submission = submission;
    try {
      await send();
    } finally {
      // 上一轮完成时，不能释放下一份草稿正在使用的提交锁。
      if (identical(_submission, submission)) {
        _submission = null;
      }
    }
  }

  @override
  set value(TextEditingValue next) {
    // 光标、选区或 IME composing 变化不是新草稿；实际改字后才释放旧提交。
    if (next.text != text) {
      _submission = null;
    }
    super.value = next;
  }

  @override
  void clear() {
    _submission = null;
    _attachments.clear();
    _nextImageNumber = 1;
    super.clear();
  }

  ChatDraft snapshot([String? source]) {
    final body = source ?? text;
    return ChatDraft(body, {
      for (final entry in _attachments.entries)
        if (body.contains(entry.key)) entry.key: entry.value,
    });
  }

  String encodeBlocks(List<AiMessageBlock> blocks) {
    for (final block in blocks.whereType<AiAttachmentBlock>()) {
      final number = block.imageNumber;
      if (block.isImage && number != null && number >= _nextImageNumber) {
        _nextImageNumber = number + 1;
      }
    }
    final buffer = StringBuffer();
    for (final block in blocks) {
      if (block is AiTextBlock) {
        buffer.write(block.text);
      } else if (block is AiAttachmentBlock) {
        final path = RevericPaths.resolveStored(block.path);
        if (path == null) {
          // A missing file cannot be re-attached; keep its reference as text.
          buffer.write('[${block.name}](${block.path})');
          continue;
        }
        buffer.write(
          register(
            ChatDraftAttachment(
              NamedChatFile.path(path, name: block.name),
              imageNumber: block.imageNumber,
            ),
            preserveImageNumber: true,
          ),
        );
      }
    }
    return buffer.toString();
  }

  String register(
    ChatDraftAttachment attachment, {
    bool preserveImageNumber = false,
  }) {
    if (_nextToken > 0xf8ff) {
      throw const ChatAttachmentException(
        ChatAttachmentFailure.too_many_attachments,
      );
    }
    if (attachment.isImage) {
      final number = preserveImageNumber && (attachment.imageNumber ?? 0) > 0
          ? attachment.imageNumber!
          : _nextImageNumber++;
      if (number >= _nextImageNumber) {
        _nextImageNumber = number + 1;
      }
      attachment = attachment.withImageNumber(number);
    }
    final token = String.fromCharCode(_nextToken++);
    _attachments[token] = attachment;
    return token;
  }

  void insertFiles(Iterable<XFile> files, {bool allowPathReferences = false}) {
    final selected = files.map((file) {
      final extension = p.extension(file.name).toLowerCase();
      return (
        attachment: ChatDraftAttachment(file),
        inline:
            extension.isNotEmpty &&
            chatFileExtensions.contains(extension.substring(1)),
      );
    }).toList();
    if (selected.isEmpty) {
      return;
    }
    for (final item in selected) {
      if (!item.inline &&
          (!allowPathReferences || !p.isAbsolute(item.attachment.file.path))) {
        throw const ChatAttachmentException(ChatAttachmentFailure.unsupported);
      }
    }
    final existingCount = snapshot().attachments.values
        .where((a) => a.isImage)
        .length;
    if (existingCount +
            selected.where((item) => item.attachment.isImage).length >
        chatImageMaxCount) {
      throw const ChatAttachmentException(
        ChatAttachmentFailure.too_many_images,
      );
    }
    final parts = [
      for (final item in selected)
        item.inline ? register(item.attachment) : item.attachment.file.path,
    ];
    if (selected.every((item) => item.inline)) {
      insertText(parts.join());
      return;
    }
    final range = selection.isValid
        ? selection
        : TextSelection.collapsed(offset: text.length);
    insertText(
      [
        if (range.start > 0 && text[range.start - 1] != '\n') '',
        ...parts,
        if (range.end == text.length || text[range.end] != '\n') '',
      ].join('\n'),
    );
  }

  void insertDraft(ChatDraft draft) {
    final buffer = StringBuffer();
    for (final rune in draft.text.runes) {
      final char = String.fromCharCode(rune);
      final attachment = draft.attachments[char];
      // A cut/paste within this draft moves the original atom. Copying an
      // atom still present in the draft creates a new independently numbered one.
      final canMove =
          attachment != null &&
          identical(_attachments[char], attachment) &&
          !text.contains(char);
      buffer.write(attachment == null || canMove ? char : register(attachment));
    }
    insertText(buffer.toString());
  }

  void insertText(String inserted) {
    final range = selection.isValid
        ? selection
        : TextSelection.collapsed(offset: text.length);
    value = TextEditingValue(
      text: text.replaceRange(range.start, range.end, inserted),
      selection: TextSelection.collapsed(offset: range.start + inserted.length),
    );
  }

  void moveFile(int from, int to) {
    if (from < 0 ||
        from >= text.length ||
        !_attachments.containsKey(text[from])) {
      return;
    }
    to = to.clamp(0, text.length);
    if (to == from || to == from + 1) {
      return;
    }
    final token = text[from];
    final rest = text.replaceRange(from, from + 1, '');
    final target = to > from ? to - 1 : to;
    value = TextEditingValue(
      text: rest.replaceRange(target, target, token),
      selection: TextSelection.collapsed(offset: target + 1),
    );
  }

  String readableText(ChatDraft draft, {String Function(int)? imageLabel}) {
    var result = draft.text;
    for (final entry in draft.attachments.entries) {
      final attachment = entry.value;
      final number = attachment.imageNumber;
      final label = attachment.isImage && number != null
          ? imageLabel?.call(number) ?? 'Image #$number'
          : '[${attachment.name}]';
      result = result.replaceAll(entry.key, label);
    }
    return result;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (snapshot().attachments.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final colors = RevericTheme.colorsOf(context);
    final children = <InlineSpan>[];
    var start = 0;
    void addText(int end) {
      if (end <= start) {
        return;
      }
      final composing = value.composing;
      final a = composing.start.clamp(start, end);
      final b = composing.end.clamp(start, end);
      if (withComposing && composing.isValid && a < b) {
        children.add(TextSpan(text: text.substring(start, a)));
        children.add(
          TextSpan(
            text: text.substring(a, b),
            style: const TextStyle(decoration: TextDecoration.underline),
          ),
        );
        children.add(TextSpan(text: text.substring(b, end)));
      } else {
        children.add(TextSpan(text: text.substring(start, end)));
      }
    }

    for (var i = 0; i < text.length; i++) {
      final attachment = _attachments[text[i]];
      if (attachment == null) {
        continue;
      }
      addText(i);
      final label = Text(
        attachment.isImage && attachment.imageNumber != null
            ? context.t(
                LocaleKeys.aiImageAttachmentLabel,
                namedArgs: {'number': '${attachment.imageNumber}'},
              )
            : '[${attachment.name}]',
        style: style?.copyWith(
          color: colors.accent,
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
      final content = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: label,
      );
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: _fileDrag(context, i, content, colors),
        ),
      );
      start = i + 1;
    }
    addText(text.length);
    return TextSpan(style: style, children: children);
  }

  Widget _fileDrag(
    BuildContext context,
    int offset,
    Widget content,
    RevericColors colors,
  ) {
    final name = _attachments[text[offset]]!.name;
    final child = GestureDetector(
      onTap: () => selection = TextSelection(
        baseOffset: offset,
        extentOffset: offset + 1,
      ),
      child: Semantics(
        label: name,
        child: Tooltip(message: name, child: content),
      ),
    );
    final feedback = Material(color: colors.surface, child: content);
    final drag = ComposerFileDrag(this, offset);
    if ({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }.contains(defaultTargetPlatform)) {
      return Draggable<ComposerFileDrag>(
        data: drag,
        feedback: feedback,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        child: child,
      );
    }
    return LongPressDraggable<ComposerFileDrag>(
      data: drag,
      feedback: feedback,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      child: child,
    );
  }
}
