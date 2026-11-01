// 职责: 验证文件命令结果不泄露内部路径，并保留续读、回放及备份引用。
// 关联文件:
//   lib/shared/services/ai/files/attachments.dart
//   lib/shared/services/ai/files/command_paths.dart
//   lib/shared/services/ai/agent_message_mapping.dart
//   lib/shared/services/ai/files/reader.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/services/ai/agent_message_mapping.dart';
import 'package:reveric/shared/services/ai/files/attachments.dart';
import 'package:reveric/shared/services/ai/files/command_paths.dart';
import 'package:reveric/shared/services/ai/files/reader.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';

void main() {
  late Directory root;
  late SessionFiles files;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('command-result-');
    files = SessionFiles(root: root.path, novelId: 'work');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'relative image results round-trip without losing their snapshot',
    () async {
      final original = File('${root.path}/input.png');
      await original.writeAsBytes(
        img.encodePng(img.Image(width: 4, height: 4)),
      );
      final stored = await FileReader(
        files,
        FfmpegRunner(),
      ).read('chat', {'path': original.path}, MediaCancellation());
      final result = commandFileResult(stored, files);
      final path = result['file_path'] as String;
      expect(path, startsWith('sessions/chat/'));
      expect(result['snapshot_path'], stored['file_path']);
      expect(stored.containsKey('snapshot_path'), isFalse);
      expect(
        (await CommandPaths(files).resolve(path)).path,
        (await files.resolve(stored['file_path'] as String)).path,
      );
      expect(resultFilePaths(result).toSet(), resultFilePaths(stored).toSet());
      final content = await assembleToolResultContent(result, root: root.path);
      expect(content.whereType<ImageBlock>(), hasLength(1));
      expect(
        jsonDecode(
          content.whereType<TextBlock>().elementAt(1).text,
        )['file_path'],
        path,
      );
      final persisted = prepareSpawnAgentRunMessagesForPersistence([
        const AgentMessage(
          id: 'call',
          role: AgentMessageRole.assistant,
          blocks: [
            ToolCallBlock(
              callId: 'read',
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
            ToolResultBlock(
              toolCallId: 'read',
              toolName: 'Run',
              content: content,
            ),
          ],
        ),
      ]);
      final payload = persisted.first.blocks
          .whereType<AiToolCallBlock>()
          .single
          .result!;
      expect(payload['file_path'], path);
      expect(payload['snapshot_path'], stored['file_path']);
      await original.delete();
      final replayed = await restoreAgentMessages(persisted, root: root.path);
      final replay = replayed
          .expand((message) => message.blocks)
          .whereType<ToolResultBlock>()
          .single
          .content;
      expect(
        replay.whereType<ImageBlock>().single.data,
        content.whereType<ImageBlock>().single.data,
      );
      expect(jsonDecode((replay.first as TextBlock).text)['file_path'], path);
    },
  );

  test(
    'preview paths are reusable and backup paths keep their workspace',
    () async {
      final snapshot = await files.allocate('chat', '.mp4');
      await snapshot.writeAsBytes([1]);
      final stored = files.reference(snapshot);
      final result = commandFileResult({
        'ok': true,
        'result': {
          'ok': true,
          'files': [
            {'delivered': true, 'file_path': stored, 'snapshot_path': stored},
          ],
        },
      }, files);
      final output = result['result']['files'][0] as Map;
      expect(
        (await CommandPaths(files).resolve(output['file_path'] as String)).path,
        snapshot.path,
      );
      expect(output['snapshot_path'], stored);
      expect(resultFilePaths(result), [stored]);
      final shared = commandFileResult({
        'file_path': 'file_workspaces/shared/images/map.png',
      }, files);
      expect(shared['file_path'], 'file_workspaces/shared/images/map.png');
      final legacy = commandFileResult({
        'file_path': 'images/legacy.png',
      }, files);
      expect(legacy['file_path'], 'images/legacy.png');
    },
  );

  test(
    'relative paths stay relative in nested results and model metadata',
    () async {
      for (final path in [
        'images/example.png',
        'file_workspaces/shared/images/example.png',
        'file_workspaces/other/images/example.png',
      ]) {
        final metadata = {
          'kind': 'image',
          'file_path': path,
          'source_file_path': path,
          'result_file_path': path,
        };
        final result = commandFileResult({
          'result': {
            ...metadata,
            'content_format': 'session_files_v1',
            'files': [metadata],
            'content': [
              {'type': 'text', 'text': jsonEncode(metadata)},
            ],
          },
        }, files);
        expect(result['result']['files'].single, metadata);
        final blocks = await assembleToolResultContent(result, root: root.path);
        expect(jsonDecode(blocks.whereType<TextBlock>().last.text), metadata);
        expect(jsonEncode(result), isNot(contains(files.root)));
      }
    },
  );

  test(
    'long-line continuation contains only position and reads updated text',
    () async {
      final original = File('${root.path}/long.txt');
      final prefix = List.filled(65536, 'a').join();
      await original.writeAsString('${prefix}before');
      final reader = FileReader(files, FfmpegRunner());
      final result = commandFileResult(
        await reader.read('chat', {'path': original.path}, MediaCancellation()),
        files,
      );
      final blocks = await assembleToolResultContent(result, root: root.path);
      final metadata = jsonDecode(blocks.whereType<TextBlock>().last.text);
      final cursor = metadata['continuation'] as String;
      expect(jsonDecode(utf8.decode(base64Url.decode(cursor))), {
        'line': 0,
        'skip': 65536,
      });
      expect(metadata['text'], prefix);
      expect(result['continuation'], cursor);
      await original.writeAsString('${prefix}after edit');
      final next = await reader.read('chat', {
        'path': original.path,
        'continuation': cursor,
      }, MediaCancellation());
      expect(next['text'], 'after edit');
      expect(next['has_more'], isFalse);
    },
  );

  for (final kind in ['audio', 'video']) {
    test(
      '$kind metadata omits probe filename and preserves other fields',
      () async {
        final original = File(
          '${root.path}/sample.${kind == 'audio' ? 'wav' : 'mp4'}',
        );
        await original.writeAsBytes([1]);
        final runner = _ProbeRunner(kind);
        final result = commandFileResult(
          await FileReader(
            files,
            runner,
          ).read('chat', {'path': original.path}, MediaCancellation()),
          files,
        );
        expect(runner.output['format']['filename'], isNotEmpty);
        final expected = {
          ...runner.output,
          'format': Map<String, dynamic>.from(runner.output['format'] as Map)
            ..remove('filename'),
        };
        expect(result['specifications'], expected);
        final blocks = await assembleToolResultContent(result, root: root.path);
        for (final block in blocks.whereType<TextBlock>()) {
          expect(jsonDecode(block.text)['specifications'], expected);
        }
        expect(result['file_path'], startsWith('sessions/chat/'));
        expect(
          await (await CommandPaths(
            files,
          ).resolve(result['file_path'] as String)).exists(),
          isTrue,
        );
      },
    );
  }

  test('metadata paths change without rewriting the file text', () async {
    final original = File('${root.path}/notes.txt');
    const text = 'Keep file_workspaces/work/files/example.txt as written.';
    await original.writeAsString(text);
    final stored = await FileReader(
      files,
      FfmpegRunner(),
    ).read('chat', {'path': original.path}, MediaCancellation());
    final result = commandFileResult(stored, files);
    final content = await assembleToolResultContent(result, root: root.path);
    final metadata = jsonDecode(
      content.whereType<TextBlock>().elementAt(1).text,
    );
    expect(metadata['file_path'], result['file_path']);
    expect(metadata['text'], stored['text']);
    expect(jsonEncode(result), contains(text));
  });
}

class _ProbeRunner extends FfmpegRunner {
  _ProbeRunner(this.kind);

  final String kind;
  late Map<String, dynamic> output;

  @override
  Future<String> execute(
    List<String> arguments, {
    required bool probe,
    required MediaCancellation cancellation,
  }) async {
    expect(probe, isTrue);
    output = {
      'format': {
        'filename': kind == 'audio'
            ? arguments.last
            : r'C:\Users\tester\sessions\sample.mp4',
        'duration': '1.25',
        'tags': {'title': 'Sample', 'encoder': 'test encoder'},
      },
      'streams': [
        {
          'codec_type': kind,
          'codec_name': kind == 'audio' ? 'pcm_s16le' : 'h264',
        },
      ],
    };
    return jsonEncode(output);
  }
}
