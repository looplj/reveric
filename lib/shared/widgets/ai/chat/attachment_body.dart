// 职责: 按消息原顺序展示文字与本地附件，并提供图片和文本文件预览。
// 关联文件:
//   lib/shared/models/ai_message_block.dart
//   lib/shared/services/ai/files/session_files.dart
//   lib/shared/widgets/ai/chat/chat_message_view.dart
//   lib/shared/widgets/ai/chat/published_chat_image.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'dart:io';
import 'package:flutter/material.dart';

import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../models/ai_message_block.dart';
import '../../../services/ai/files/session_files.dart';
import '../../../theme/theme.dart';
import '../../../utils/storage_paths.dart';
import 'chat_message_parts.dart';
import 'published_chat_image.dart';

final _log = AppLogger.forModule('ChatAttachment');

class ChatAttachmentBody extends StatelessWidget {
  const ChatAttachmentBody({
    super.key,
    required this.blocks,
    this.readOnly = false,
  });
  final List<AiMessageBlock> blocks;
  final bool readOnly;

  static const _publicTextPreviewLimit = 4 * 1024 * 1024;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Text.rich(
      TextSpan(
        style: typo.ui.copyWith(color: colors.textPrimary),
        children: [
          for (final block in blocks)
            if (block is AiTextBlock)
              TextSpan(text: parseUserMessagePresentation(block.text).text)
            else if (block is AiAttachmentBlock)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Tooltip(
                  message: block.name,
                  child: InkWell(
                    onTap: () => _preview(context, block),
                    child: Padding(
                      padding: const EdgeInsets.all(RevericSpacing.xxs),
                      child: block.isImage
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    RevericRadius.small,
                                  ),
                                  child: _thumbnail(
                                    block,
                                    unavailable: Text(
                                      context.t(
                                        LocaleKeys.aiAttachmentUnavailable,
                                      ),
                                      style: typo.uiSmall.copyWith(
                                        color: colors.textMuted,
                                      ),
                                    ),
                                  ),
                                ),
                                if (block.imageNumber != null)
                                  Text(
                                    context.t(
                                      LocaleKeys.aiImageAttachmentLabel,
                                      namedArgs: {
                                        'number': '${block.imageNumber}',
                                      },
                                    ),
                                    style: typo.uiTiny.copyWith(
                                      color: colors.textMuted,
                                    ),
                                  ),
                              ],
                            )
                          : Text(
                              '[${block.name}]',
                              style: typo.ui.copyWith(color: colors.accent),
                            ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _thumbnail(AiAttachmentBlock block, {required Widget unavailable}) {
    // Restored backups or cleared session folders can leave the reference dangling.
    final path = RevericPaths.resolveStored(block.path);
    if (path == null) {
      return unavailable;
    }
    return Image(
      image: readOnly
          ? PublishedChatImage(path, previewSide: 192)
          : ResizeImage(FileImage(File(path)), width: 192),
      width: 96,
      height: 72,
      fit: BoxFit.cover,
      semanticLabel: block.name,
      errorBuilder: (_, _, _) => unavailable,
    );
  }

  Future<void> _preview(BuildContext context, AiAttachmentBlock block) async {
    try {
      final file = await SessionFiles().resolve(block.path);
      if (readOnly &&
          !block.isImage &&
          await file.length() > _publicTextPreviewLimit) {
        throw const FormatException(
          'Published attachment exceeds the preview limit',
        );
      }
      final text = block.isImage ? null : await file.readAsString();
      if (!context.mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(block.name),
          content: SizedBox(
            width: 640,
            height: 480,
            child: block.isImage
                ? InteractiveViewer(
                    child: readOnly
                        ? Image(
                            image: PublishedChatImage(file.path),
                            fit: BoxFit.contain,
                            errorBuilder: (context, _, _) => Center(
                              child: Text(
                                context.t(LocaleKeys.aiAttachmentUnavailable),
                              ),
                            ),
                          )
                        : Image.file(file, fit: BoxFit.contain),
                  )
                : SingleChildScrollView(child: SelectableText(text!)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.t(LocaleKeys.commonClose)),
            ),
          ],
        ),
      );
    } catch (error, stack) {
      _log.error(
        'chat attachment preview failed id=${block.id}',
        error: error,
        stackTrace: stack,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.aiAttachmentUnavailable)),
          ),
        );
      }
    }
  }
}
