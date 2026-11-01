// 职责: 验证聊天附件有序归档、跨重启恢复、缺件反馈与图片大小限制。
// 关联文件:
//   lib/shared/services/ai/chat_attachments.dart
//   lib/shared/services/ai/agent_message_mapping.dart
//   lib/shared/services/ai/files/command_paths.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/services/ai/chat_attachments.dart';
import 'package:reveric/shared/services/ai/agent_message_mapping.dart';
import 'package:reveric/shared/services/ai/files/command_paths.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';

void main() {
  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('chat_attachments_'),
  );
  tearDown(() => root.delete(recursive: true));

  test(
    'text/image/text/file/text survives serialization and source removal',
    () async {
      final image = File('${root.path}/source.png');
      await image.writeAsBytes(img.encodePng(img.Image(width: 12, height: 8)));
      final text = File('${root.path}/说明.md');
      await text.writeAsString('文件正文');
      final draft = ChatDraft('前\ue000中\ue001后', {
        '\ue000': ChatDraftAttachment(XFile(image.path), imageNumber: 7),
        '\ue001': ChatDraftAttachment(XFile(text.path)),
      });
      final blocks = await ChatAttachmentOrchestrator().prepare(
        'session',
        draft,
        novelId: 'work',
        root: root.path,
      );
      expect(blocks.map((b) => b.runtimeType), [
        AiTextBlock,
        AiAttachmentBlock,
        AiTextBlock,
        AiAttachmentBlock,
        AiTextBlock,
      ]);
      final json = jsonEncode(blocks.map((b) => b.toJson()).toList());
      expect(json, isNot(contains('base64')));
      expect(json, isNot(contains(root.path)));
      final stored = (jsonDecode(json) as List)
          .map((b) => AiMessageBlock.fromJson(Map<String, dynamic>.from(b)))
          .toList();
      await image.delete();
      await text.delete();
      final message = AiMessage.user(
        id: 'user',
        content: chatBlocksText(stored),
        blocks: stored,
      );
      final savedImage = stored.whereType<AiAttachmentBlock>().first;
      expect(savedImage.imageNumber, 7);
      expect(
        savedImage
            .withPath('file_workspaces/work/sessions/copy/image.png')
            .imageNumber,
        7,
      );
      final live = await hydrateChatBlocks(
        blocks,
        root: root.path,
        strict: true,
      );
      final restored = (await restoreAgentMessages([
        message,
      ], root: root.path)).single;
      expect(
        restored.content,
        isEmpty,
        reason: 'Display labels must not be prepended to the model input',
      );
      String describe(MessageBlock b) =>
          b is TextBlock ? b.text : (b as ImageBlock).data;
      expect(restored.blocks.map(describe), live.map(describe));
      // The exact path advertised to the model must work as a file-command
      // input, both on the first send and after restoring persisted attachments.
      final files = SessionFiles(root: root.path, novelId: 'work');
      for (final hydrated in [live, restored.blocks]) {
        final paths = hydrated
            .whereType<TextBlock>()
            .expand(
              (block) => RegExp(r' path="([^"]+)"').allMatches(block.text),
            )
            .map((match) => match.group(1)!)
            .toList();
        expect(paths, hasLength(2));
        for (var i = 0; i < paths.length; i++) {
          final saved = stored.whereType<AiAttachmentBlock>().elementAt(i);
          expect(
            (await CommandPaths(files).resolve(paths[i])).path,
            (await files.resolve(saved.path)).path,
          );
        }
      }
      expect(live.map((b) => b.runtimeType), [
        TextBlock,
        TextBlock,
        ImageBlock,
        TextBlock,
        TextBlock,
        TextBlock,
        TextBlock,
        TextBlock,
        TextBlock,
      ]);
      expect((live[1] as TextBlock).text, contains('name="Image #7"'));
      expect((live[1] as TextBlock).text, contains('filename="source.png"'));
      expect((live[0] as TextBlock).text, '前');
      expect((live[3] as TextBlock).text, '</image>');
      expect((live[4] as TextBlock).text, '中');
      expect((live[6] as TextBlock).text, '文件正文');
      expect((live[8] as TextBlock).text, '后');
    },
  );

  test(
    'new sends reject missing files; historical replay keeps explicit path',
    () async {
      const blocks = [
        AiAttachmentBlock(
          id: 'file',
          name: 'gone.png',
          path: 'file_workspaces/work/sessions/s/gone.png',
          mimeType: 'image/png',
        ),
      ];
      await expectLater(
        hydrateChatBlocks(blocks, root: root.path, strict: true),
        throwsA(isA<ChatAttachmentException>()),
      );
      final history = await hydrateChatBlocks(blocks, root: root.path);
      expect(history.whereType<ImageBlock>(), isEmpty);
      expect(
        history.whereType<TextBlock>().map((b) => b.text).join(),
        contains('File unavailable: file_workspaces/work/sessions/s/gone.png'),
      );
    },
  );

  test(
    'limits apply to the whole message, including repeated images',
    () async {
      final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 8, height: 8)),
      );
      final draft = ChatDraft('\ue000' * 5, {
        '\ue000': ChatDraftAttachment(
          NamedChatFile.data(bytes, name: 'pic.png'),
        ),
      });
      await expectLater(
        ChatAttachmentOrchestrator().prepare(
          's',
          draft,
          novelId: 'work',
          root: root.path,
        ),
        throwsA(isA<ChatAttachmentException>()),
      );
      final texts = ChatDraft('\ue000\ue001', {
        '\ue000': ChatDraftAttachment(
          NamedChatFile.data(
            Uint8List.fromList(utf8.encode('中' * 60000)),
            name: 'one.txt',
          ),
        ),
        '\ue001': ChatDraftAttachment(
          NamedChatFile.data(
            Uint8List.fromList(utf8.encode('文' * 60000)),
            name: 'two.md',
          ),
        ),
      });
      await expectLater(
        ChatAttachmentOrchestrator().prepare(
          's',
          texts,
          novelId: 'work',
          root: root.path,
        ),
        throwsA(isA<ChatAttachmentException>()),
      );
    },
  );

  test(
    'transparent images flatten onto white JPEG and invalid images fail',
    () {
      final image = img.Image(width: 16, height: 16, numChannels: 4);
      image.setPixelRgba(0, 0, 255, 0, 0, 100);
      final bytes = Uint8List.fromList(img.encodePng(image));
      final result = prepareChatImage(bytes, '.png');
      expect(result.extension, 'jpg');
      final corner = img.decodeJpg(result.bytes)!.getPixel(15, 15);
      expect(corner.r, greaterThan(240));
      expect(corner.g, greaterThan(240));
      expect(corner.b, greaterThan(240));
      expect(
        () => prepareChatImage(Uint8List.fromList([1, 2, 3]), '.png'),
        throwsA(isA<ChatAttachmentException>()),
      );
    },
  );

  test('opaque images are capped to the max edge and encoded as JPEG', () {
    final image = img.Image(width: 3000, height: 1500);
    final bytes = Uint8List.fromList(img.encodePng(image));
    final result = prepareChatImage(bytes, '.png');
    expect(result.extension, 'jpg');
    final decoded = img.decodeJpg(result.bytes)!;
    expect(decoded.width, chatImageMaxDimension);
    expect(decoded.height, 1024);
  });

  test('images over the byte ceiling after encoding are rejected', () {
    final image = img.Image(width: 1600, height: 1200, numChannels: 4);
    final random = Random(42);
    for (final pixel in image) {
      pixel.setRgba(
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
        128,
      );
    }
    final bytes = Uint8List.fromList(img.encodePng(image));
    expect(
      () => prepareChatImage(bytes, '.png'),
      throwsA(isA<ChatAttachmentException>()),
    );
  });
}
