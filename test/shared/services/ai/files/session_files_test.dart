// 职责: 验证会话文件所有权、删除边界及多模态历史往返。
// 关联文件:
//   lib/shared/services/ai/files/session_files.dart
//   lib/shared/services/ai/files/reader.dart
//   lib/shared/services/ai/agent_message_mapping.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/services/ai/agent_message_mapping.dart';
import 'package:reveric/shared/services/ai/files/attachments.dart';
import 'package:reveric/shared/services/ai/files/reader.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';

void main() {
  late Directory root;
  late SessionFiles files;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('session_files_test_');
    files = SessionFiles(root: root.path, novelId: 'work');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'copies survive source removal and cross-session garbage collection',
    () async {
      final source = File('${root.path}/original.txt');
      await source.writeAsString('snapshot');
      final first = await files.copy('one', source);
      final reused = await files.copy('one', first);
      expect(reused.path, first.path);
      final second = await files.copy('two', first);
      await source.delete();
      await files.deleteSessions(['one']);
      expect(await first.exists(), isFalse);
      expect(await second.readAsString(), 'snapshot');
      await files.deleteSessions(['one']);
      await expectLater(
        files.deleteSessions(['two', '../escape']),
        throwsFormatException,
      );
      expect(await second.exists(), isTrue);
    },
  );

  test(
    'work copies and GC leave other works and old files untouched',
    () async {
      final old = File('${root.path}/sessions/same/old.txt');
      await old.parent.create(recursive: true);
      await old.writeAsString('old');
      final oldMedia = File('${root.path}/media/work/sessions/same/old.txt');
      await oldMedia.parent.create(recursive: true);
      await oldMedia.writeAsString('old media');
      final own = await files.copy('same', old);
      final otherFiles = SessionFiles(root: root.path, novelId: 'other');
      final other = await otherFiles.copy('same', own);
      expect(
        files.reference(own),
        startsWith('file_workspaces/work/sessions/same/'),
      );
      expect(
        otherFiles.reference(other),
        startsWith('file_workspaces/other/sessions/same/'),
      );
      expect(other.path, isNot(own.path));
      await files.deleteSessions(['same']);
      expect(await own.exists(), isFalse);
      expect(await other.readAsString(), 'old');
      expect(await old.readAsString(), 'old');
      expect(await oldMedia.readAsString(), 'old media');
    },
  );

  test('GC never follows a session directory link', () async {
    final external = await Directory.systemTemp.createTemp('session_external_');
    addTearDown(() => external.delete(recursive: true));
    final original = File('${external.path}/keep.txt');
    await original.writeAsString('keep');
    await Directory(
      '${root.path}/file_workspaces/work/sessions',
    ).create(recursive: true);
    await Link(
      '${root.path}/file_workspaces/work/sessions/bad',
    ).create(external.path);
    await expectLater(files.deleteSessions(['bad']), throwsFormatException);
    expect(await original.readAsString(), 'keep');
  });

  test('photographic images are re-encoded as capped JPEG', () async {
    // 噪点图逼近写实渲染：缩到 2048 后存 PNG 远超 3 MiB。
    final random = Uint8List.fromList(
      List.generate(3000 * 1688 * 3, (i) => (i * 2654435761) >> 7 & 0xff),
    );
    final source = File('${root.path}/render.png');
    await source.writeAsBytes(
      img.encodePng(
        img.Image.fromBytes(
          width: 3000,
          height: 1688,
          bytes: random.buffer,
          numChannels: 3,
        ),
      ),
    );
    final result = await FileReader(
      files,
      FfmpegRunner(),
    ).read('chat', {'path': source.path}, MediaCancellation());
    expect(result['mime_type'], 'image/jpeg');
    final stored = await files.resolve(result['file_path'] as String);
    expect(stored.path, endsWith('.jpg'));
    final bytes = await stored.readAsBytes();
    expect(bytes.length, lessThanOrEqualTo(maxAttachmentBytes));
    final decoded = img.decodeJpg(bytes)!;
    expect((decoded.width, decoded.height), (2048, 1152));
  });

  test(
    'image payload contains no base64 and replays identical bytes after source deletion',
    () async {
      final source = File('${root.path}/original.png');
      await source.writeAsBytes(img.encodePng(img.Image(width: 8, height: 4)));
      final result = await FileReader(
        files,
        FfmpegRunner(),
      ).read('chat', {'path': source.path}, MediaCancellation());
      final live = await assembleToolResultContent(result, root: root.path);
      expect(live.whereType<ImageBlock>(), hasLength(1));
      expect(jsonEncode(result), isNot(contains('base64')));
      await source.delete();
      final messages = prepareSpawnAgentRunMessagesForPersistence([
        const AgentMessage(
          id: 'assistant',
          role: AgentMessageRole.assistant,
          blocks: [
            ToolCallBlock(
              callId: 'call',
              toolName: 'Run',
              arguments: {'command': 'files', 'subcommand': 'view-image'},
            ),
          ],
        ),
        AgentMessage(
          id: 'result',
          role: AgentMessageRole.user,
          type: AgentMessageType.tool_result,
          blocks: [
            ToolResultBlock(toolCallId: 'call', toolName: 'Run', content: live),
          ],
        ),
      ]);
      final saved = messages.first.blocks
          .whereType<AiToolCallBlock>()
          .single
          .result!;
      expect(saved, result);
      final restored = await restoreAgentMessages(messages, root: root.path);
      final content = restored
          .expand((m) => m.blocks)
          .whereType<ToolResultBlock>()
          .single
          .content;
      expect(
        content.whereType<ImageBlock>().single.data,
        live.whereType<ImageBlock>().single.data,
      );
      await files.deleteSessions(['chat']);
      final missing = await restoreAgentMessages(messages, root: root.path);
      final fallback = missing
          .expand((m) => m.blocks)
          .whereType<ToolResultBlock>()
          .single;
      expect(fallback.isError, isFalse);
      expect(fallback.content.whereType<ImageBlock>(), isEmpty);
      expect(
        fallback.content.whereType<TextBlock>().last.text,
        contains(result['file_path']),
      );
    },
  );

  test(
    'text pagination preserves Unicode and completes a long line without loss',
    () async {
      final original = '${List.filled(25000, '你好🙂').join()}\nnext';
      final source = File('${root.path}/long.txt');
      await source.writeAsString(original);
      final result = StringBuffer();
      var options = <String, dynamic>{};
      var attempts = 0;
      while (true) {
        final page = await readTextPage(source, options);
        expect(
          utf8.encode(page['text'] as String).length,
          lessThanOrEqualTo(65536),
        );
        result.write(page['text']);
        if (page['has_more'] != true) {
          break;
        }
        options = page['continuation'] != null
            ? {'continuation': page['continuation']}
            : {'offset': page['next_offset']};
        expect(++attempts, lessThan(20));
      }
      expect(result.toString(), original);
    },
  );

  test(
    'background results restore once whether or not a completion reminder was saved',
    () async {
      final image = await files.allocate('chat', '.png');
      await image.writeAsBytes(img.encodePng(img.Image(width: 2, height: 2)));
      final payload = <String, dynamic>{
        'ok': true,
        'content_format': 'session_files_v1',
        'content': [
          {
            'type': 'image',
            'file_path': files.reference(image),
            'mime_type': 'image/png',
          },
        ],
      };
      final operation = <String, dynamic>{
        'run_id': 'run',
        'call_id': 'call',
        'status': 'completed',
        'result': payload,
      };
      final tool = AiMessage(
        id: 'assistant',
        role: AiMessageRole.assistant,
        content: '',
        timestamp: DateTime.now(),
        blocks: [
          AiToolCallBlock(
            id: 'block',
            callId: 'call',
            toolName: 'Run',
            arguments: {'command': 'files'},
            status: AiToolCallStatus.success,
            result: {'ok': true, 'run_id': 'run', 'status': 'queued'},
            metadata: {
              'operations': [operation],
            },
          ),
        ],
      );
      final reminder = AiMessage(
        id: 'notice',
        role: AiMessageRole.user,
        type: AiMessageType.system_remind,
        content:
            '<system-remind type="operation_completed">\nRun: run\nResult: ${jsonEncode(payload)}\n</system-remind>',
        timestamp: DateTime.now(),
      );
      int images(List<AgentMessage> messages) => messages
          .expand((m) => m.blocks)
          .fold(
            0,
            (count, block) =>
                count +
                (block is ImageBlock
                    ? 1
                    : block is ToolResultBlock
                    ? block.content.whereType<ImageBlock>().length
                    : 0),
          );
      expect(images(await restoreAgentMessages([tool], root: root.path)), 1);
      expect(
        images(await restoreAgentMessages([tool, reminder], root: root.path)),
        1,
      );
    },
  );

  test('strict decoding accepts UTF-16 BOM and rejects malformed binary', () {
    expect(decodeText(Uint8List.fromList([255, 254, 96, 79])), '你');
    expect(
      () => decodeText(Uint8List.fromList([255, 254, 0, 216])),
      throwsFormatException,
    );
    expect(
      () => decodeText(Uint8List.fromList([0, 1, 2])),
      throwsFormatException,
    );
    expect(() => decodeText(Uint8List.fromList([255])), throwsFormatException);
  });
}
