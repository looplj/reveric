// 职责: 将系统文件选择、剪贴板和拖放接入聊天输入框的附件与文件路径。
// 关联文件:
//   lib/shared/widgets/ai/chat/composer_controller.dart
//   lib/shared/services/ai/chat_attachments.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:super_clipboard/super_clipboard.dart' as clip;
import 'package:super_drag_and_drop/super_drag_and_drop.dart' as drop;

import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../../../services/ai/chat_attachments.dart';
import '../../../utils/random_id.dart';
import 'composer_controller.dart';

final _log = AppLogger.forModule('ChatAttachmentInput');
ChatDraft? _copiedDraft;
String? _copyId;
Future<String?> _decodeClipboardId(
  clip.PlatformDataProvider provider,
  String format,
) async {
  final value = await provider.getData(format);
  return value is String
      ? value
      : value is Uint8List
      ? utf8.decode(value)
      : null;
}

const _draftFormat = clip.SimpleValueFormat<String>(
  fallback: clip.SimplePlatformCodec(
    formats: ['application/x-reveric-chat-draft'],
    onDecode: _decodeClipboardId,
  ),
);

bool get _isDesktop => switch (defaultTargetPlatform) {
  TargetPlatform.macOS ||
  TargetPlatform.windows ||
  TargetPlatform.linux => true,
  _ => false,
};

Future<void> pickChatAttachments(
  BuildContext context,
  ChatComposerController controller,
) async {
  try {
    final platform = defaultTargetPlatform;
    final desktop = _isDesktop;
    _log.info('select started platform=$platform');
    final files = await openFiles(
      acceptedTypeGroups: [
        if (!desktop)
          XTypeGroup(
            label: context.t(LocaleKeys.aiAttachFile),
            extensions: chatFileExtensions,
            mimeTypes: [
              'image/png',
              'image/jpeg',
              'image/webp',
              'text/plain',
              'text/markdown',
              'text/csv',
            ],
            uniformTypeIdentifiers: [
              'public.png',
              'public.jpeg',
              'org.webmproject.webp',
              'public.text',
            ],
          ),
      ],
    );
    _log.info('select completed files=${files.length}');
    if (context.mounted) {
      controller.insertFiles(files, allowPathReferences: desktop);
    }
  } catch (error, stack) {
    if (context.mounted) {
      _report(context, error, stack);
    }
  }
}

void _report(BuildContext context, Object error, StackTrace stack) {
  _log.error(
    'attachment input failed type=${error.runtimeType}',
    error: error is ChatAttachmentException ? error : null,
    stackTrace: stack,
  );
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t(LocaleKeys.aiAttachmentFailed))),
    );
  }
}

@visibleForTesting
Future<XFile?> readChatAttachmentData(
  clip.DataReader reader, {
  bool allowTextFile = true,
  bool useLocalFilePath = false,
}) async {
  final hasFileUri = reader.canProvide(clip.Formats.fileUri);
  if (useLocalFilePath && hasFileUri) {
    final uriResult = Completer<Uri?>();
    final progress = reader.getValue(
      clip.Formats.fileUri,
      uriResult.complete,
      onError: uriResult.completeError,
    );
    if (progress != null) {
      final uri = await uriResult.future;
      if (uri != null && uri.scheme == 'file') {
        final path = uri.toFilePath();
        if (await FileSystemEntity.type(path) != FileSystemEntityType.file) {
          throw const ChatAttachmentException('read_failed');
        }
        return XFile(path);
      }
    }
  }

  final readFileUri = hasFileUri && !useLocalFilePath;
  final format = readFileUri
      ? null
      : reader.canProvide(clip.Formats.png)
      ? clip.Formats.png
      : reader.canProvide(clip.Formats.jpeg)
      ? clip.Formats.jpeg
      : reader.canProvide(clip.Formats.webp)
      ? clip.Formats.webp
      : allowTextFile && reader.canProvide(clip.Formats.plainTextFile)
      ? clip.Formats.plainTextFile
      : null;
  if (format == null && !readFileUri) {
    return null;
  }
  final completer = Completer<XFile?>();
  final progress = reader.getFile(format, (file) async {
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.getStream()) {
        if (builder.length + chunk.length > 32 * 1024 * 1024) {
          throw const ChatAttachmentException('too_large');
        }
        builder.add(chunk);
      }
      final fallback = format == clip.Formats.jpeg
          ? 'clipboard.jpg'
          : format == clip.Formats.webp
          ? 'clipboard.webp'
          : format == clip.Formats.plainTextFile
          ? 'clipboard.txt'
          : 'clipboard.png';
      var name = file.fileName ?? fallback;
      if (format != null &&
          format != clip.Formats.plainTextFile &&
          !const [
            '.png',
            '.jpg',
            '.jpeg',
            '.webp',
          ].contains(p.extension(name).toLowerCase())) {
        name = '${p.basenameWithoutExtension(name)}${p.extension(fallback)}';
      }
      completer.complete(NamedChatFile.data(builder.takeBytes(), name: name));
    } catch (error, stack) {
      completer.completeError(error, stack);
    }
  }, onError: (error) => completer.completeError(error));
  if (progress == null) {
    completer.complete(null);
  }
  return completer.future;
}

class ChatAttachmentInput extends HookWidget {
  const ChatAttachmentInput({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.child,
    this.enabled = true,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final editor = controller;
    if (editor is! ChatComposerController) {
      return child;
    }
    final key = useMemoized(GlobalKey.new);
    final importing = useRef(false);
    final desktop = _isDesktop;

    int offsetAt(Offset position) {
      RenderEditable? editable;
      void visit(RenderObject object) {
        if (object is RenderEditable) {
          editable = object;
        } else {
          object.visitChildren(visit);
        }
      }

      final object = key.currentContext?.findRenderObject();
      if (object != null) {
        visit(object);
      }
      return editable?.getPositionForPoint(position).offset ??
          editor.text.length;
    }

    Future<void> paste() async {
      if (!enabled || importing.value) {
        return;
      }
      importing.value = true;
      try {
        final clipboard = clip.SystemClipboard.instance;
        if (clipboard == null) {
          throw const ChatAttachmentException('clipboard_unavailable');
        }
        final reader = await clipboard.read();
        final id = await reader.readValue(_draftFormat);
        if (!context.mounted) {
          return;
        }
        if (id != null && id == _copyId && _copiedDraft != null) {
          editor.insertDraft(_copiedDraft!);
          return;
        }
        if (reader.items.length > 16) {
          throw const ChatAttachmentException('too_many');
        }
        final files = await Future.wait(
          reader.items.map(
            (item) => readChatAttachmentData(item, allowTextFile: false),
          ),
        );
        if (!context.mounted) {
          return;
        }
        final found = files.whereType<XFile>().toList();
        if (found.isNotEmpty) {
          editor.insertFiles(found);
        } else {
          final text = await reader.readValue(clip.Formats.plainText);
          if (context.mounted && text != null) {
            editor.insertText(text);
          }
        }
      } catch (error, stack) {
        if (context.mounted) {
          _report(context, error, stack);
        }
      } finally {
        importing.value = false;
      }
    }

    Future<void> copy(bool cut) async {
      final selection = editor.selection;
      if (!selection.isValid || selection.isCollapsed) {
        return;
      }
      final capturedValue = editor.value;
      final draft = editor.snapshot(selection.textInside(editor.text));
      try {
        final clipboard = clip.SystemClipboard.instance;
        if (clipboard == null) {
          throw const ChatAttachmentException('clipboard_unavailable');
        }
        final id = buildRandomId('clipboard');
        final item = clip.DataWriterItem()
          ..add(
            clip.Formats.plainText(
              editor.readableText(
                draft,
                imageLabel: (number) => context.t(
                  LocaleKeys.aiImageAttachmentLabel,
                  namedArgs: {'number': '$number'},
                ),
              ),
            ),
          )
          ..add(_draftFormat(id));
        await clipboard.write([item]);
        _copyId = id;
        _copiedDraft = draft;
        if (cut && context.mounted && editor.value == capturedValue) {
          editor.insertText('');
        }
      } catch (error, stack) {
        if (context.mounted) {
          _report(context, error, stack);
        }
      }
    }

    Widget input = _AttachmentActions(
      paste: paste,
      copy: copy,
      child: Actions(
        actions: {
          PasteTextIntent: CallbackAction<PasteTextIntent>(
            onInvoke: (_) {
              unawaited(paste());
              return null;
            },
          ),
          CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
            onInvoke: (intent) {
              unawaited(copy(intent.collapseSelection));
              return null;
            },
          ),
        },
        child: KeyedSubtree(key: key, child: child),
      ),
    );
    final field = input;
    input = DragTarget<ComposerFileDrag>(
      onWillAcceptWithDetails: (details) =>
          enabled && identical(details.data.controller, editor),
      onAcceptWithDetails: (details) {
        editor.moveFile(details.data.offset, offsetAt(details.offset));
        focusNode.requestFocus();
      },
      builder: (_, _, _) => field,
    );
    if (!desktop) {
      return input;
    }
    return drop.DropRegion(
      formats: const [
        clip.Formats.fileUri,
        clip.Formats.png,
        clip.Formats.jpeg,
        clip.Formats.webp,
        clip.Formats.plainTextFile,
      ],
      onDropOver: (event) =>
          enabled &&
              !importing.value &&
              event.session.allowedOperations.contains(drop.DropOperation.copy)
          ? drop.DropOperation.copy
          : drop.DropOperation.none,
      onPerformDrop: (event) async {
        if (!enabled || importing.value) {
          return;
        }
        importing.value = true;
        try {
          if (event.session.items.length > 16) {
            throw const ChatAttachmentException('too_many');
          }
          editor.selection = TextSelection.collapsed(
            offset: offsetAt(event.position.global),
          );
          final files = await Future.wait(
            event.session.items.map(
              (item) => readChatAttachmentData(
                item.dataReader!,
                useLocalFilePath: true,
              ),
            ),
          );
          if (context.mounted) {
            editor.insertFiles(
              files.whereType<XFile>(),
              allowPathReferences: true,
            );
            focusNode.requestFocus();
          }
        } catch (error, stack) {
          if (context.mounted) {
            _report(context, error, stack);
          }
        } finally {
          importing.value = false;
        }
      },
      child: input,
    );
  }
}

class _AttachmentActions extends InheritedWidget {
  const _AttachmentActions({
    required this.paste,
    required this.copy,
    required super.child,
  });
  final Future<void> Function() paste;
  final Future<void> Function(bool) copy;
  @override
  bool updateShouldNotify(_AttachmentActions oldWidget) => true;
}

Widget chatAttachmentContextMenu(
  BuildContext context,
  EditableTextState state,
) {
  final actions = context
      .dependOnInheritedWidgetOfExactType<_AttachmentActions>();
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: [
      if (actions != null &&
          !state.widget.readOnly &&
          !state.contextMenuButtonItems.any(
            (i) => i.type == ContextMenuButtonType.paste,
          ))
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: () {
            ContextMenuController.removeAny();
            unawaited(actions.paste());
          },
        ),
      for (final item in state.contextMenuButtonItems)
        if (actions == null)
          item
        else
          ContextMenuButtonItem(
            type: item.type,
            label: item.label,
            onPressed: () {
              ContextMenuController.removeAny();
              switch (item.type) {
                case ContextMenuButtonType.paste:
                  unawaited(actions.paste());
                case ContextMenuButtonType.copy:
                  unawaited(actions.copy(false));
                case ContextMenuButtonType.cut:
                  unawaited(actions.copy(true));
                default:
                  item.onPressed?.call();
              }
            },
          ),
    ],
  );
}
