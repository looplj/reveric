// 职责: 测试 Run 工具子命令的注册、路由、会话范围与旧专用工具下线行为。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_run.dart
//   lib/shared/services/bundled_control_skills.dart
//   lib/shared/services/ai/subagents_run_command_handler.dart

import 'dart:async';
import 'dart:convert';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/async_read.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/image_library_service.dart';
import 'package:reveric/shared/models/tool_permission.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/agent/tool_result.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/agent/tool_approval.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/tool_permission_gate.dart';
import 'package:reveric/shared/services/tool_permissions.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/map_agent.dart';
import 'package:reveric/shared/services/ai/image.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/ai/ffmpeg/filters.dart';
import 'package:reveric/shared/services/bundled_control_skills.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Run commands', () {
    late NovelContentDatabase db;
    late AppDatabase appDb;
    late AiToolManager toolManager;
    late List<String> prompts;
    late List<Map<String, dynamic>> agentSkillCommands;
    late List<Map<String, dynamic>> subagentCommands;
    late List<MapDesignDraft> mapDrafts;

    Future<void> initializeFileRoot(Directory root) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(channel, (_) async => root.path);
      await RevericPaths.initialize();
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    test(
      'ffmpeg frames validates input and obeys files.read permission',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'frames-permission-',
        );
        await initializeFileRoot(root);
        addTearDown(() => root.delete(recursive: true));
        final source = File('${root.path}/input.mp4');
        await source.writeAsBytes([1]);
        final broker = AiToolApprovalController();
        addTearDown(broker.dispose);
        final permissions = ToolPermissionService(
          appDb,
          episodeExists: (_, _) async => false,
        );
        await permissions.setRule(
          'files.read',
          const ToolPermissionScope.global(),
          ToolPermissionDecision.deny,
        );
        final registry = ToolOperationRegistry();
        addTearDown(registry.dispose);
        final manager = ToolOperationManager(
          ownerSessionId: 'owner',
          registry: registry,
          gate: () => ToolPermissionGate(permissions, broker, enabled: true),
          onChanged: (_) {},
          onRecord: (_) {},
        );
        addTearDown(manager.dispose);
        await appDb
            .into(appDb.novels)
            .insert(
              NovelsCompanion.insert(
                id: 'work',
                title: 'Work',
                description: '',
              ),
            );
        await appDb
            .into(appDb.aiChatSessions)
            .insert(
              AiChatSessionsCompanion.insert(id: 'owner', novelId: 'work'),
            );
        toolManager = AiToolManager(
          NovelContentService(db),
          workingOverlayService: toolManager.workingOverlayService,
          workId: 'work',
          sessionId: 'owner',
          operationHost: ToolOperationHost(manager),
        )..registerAllTools();
        final context = ToolExecutionContext(
          sessionId: 'owner',
          sourceTurnId: 'turn',
        );
        Future<Map<String, dynamic>> frames(Map<String, dynamic> options) =>
            toolManager.executeTool(
              name: 'Run',
              context: context,
              callId: 'frames',
              input: {
                'command': 'ffmpeg',
                'subcommand': 'frames',
                'options': options,
              },
            );
        final options = {
          'path': source.path,
          'timestamps_ms': [0, 100],
        };
        for (final invalid in [
          {...options, 'timestamps_ms': []},
          {
            ...options,
            'timestamps_ms': [0.1],
          },
          {...options, 'path': 'https://example.com/video.mp4'},
          {...options, 'args': []},
        ]) {
          expect((await frames(invalid))['ok'], false);
        }
        final denied = await frames(options);
        expect(denied['error_code'], 'permission_denied', reason: '$denied');
        expect(denied['kind'], 'ffmpeg.frames');
        final subtitle = File('${root.path}/caption.srt');
        await subtitle.writeAsString(
          '1\n00:00:00,000 --> 00:00:01,000\nCaption\n',
        );
        final deniedProcessing = await _settled(
          manager,
          context,
          toolManager.executeTool(
            name: 'Run',
            context: context,
            callId: 'process',
            input: {
              'command': 'ffmpeg',
              'subcommand': 'execute',
              'options': {
                'args': [
                  '-i',
                  source.path,
                  '-vf',
                  'subtitles=${subtitle.path}',
                  'videos/out.mp4',
                ],
              },
            },
          ),
        );
        expect(deniedProcessing['error_code'], 'permission_denied');
        expect(deniedProcessing['kind'], 'ffmpeg.execute');
        final next = await frames(options);
        expect(next['error_code'], 'permission_denied');
        expect(next['run_id'], isNot(denied['run_id']));
        await source.delete();
        expect((await frames(options))['ok'], false);
        const missing = 'videos/video_asset_generation_missing.mp4';
        for (final subcommand in ['frames', 'execute']) {
          final failure = await _settled(
            manager,
            context,
            toolManager.executeTool(
              name: 'Run',
              context: context,
              callId: 'missing-$subcommand',
              input: {
                'command': 'ffmpeg',
                'subcommand': subcommand,
                'options': {
                  if (subcommand == 'frames') ...{
                    'path': missing,
                    'timestamps_ms': [0],
                  } else
                    'args': [
                      '-i',
                      missing,
                      '-af',
                      'volumedetect',
                      '-f',
                      'null',
                      '-',
                    ],
                },
              },
            ),
          );
          expect(failure['ok'], false);
          expect(failure['error_code'], 'file_unavailable');
          expect(failure['error'], contains(missing));
          expect(failure['error'], contains('File is unavailable'));
          expect(failure['hint'], contains('Run files list'));
          final saved = manager.read(failure['run_id'] as String, context);
          expect(saved['result']['error'], failure['error']);
          expect(saved['result']['hint'], contains('Run files list'));
        }
      },
    );

    for (final changedDependency in ['sequence', 'concat']) {
      test(
        'ffmpeg approval stays compact and verifies hidden $changedDependency files',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'ffmpeg-approval-',
          );
          await initializeFileRoot(root);
          addTearDown(() => root.delete(recursive: true));
          final frames = await Directory('${root.path}/frames').create();
          for (var i = 1; i <= 128; i++) {
            await File('${frames.path}/frame-$i.png').writeAsBytes([1]);
          }
          final clips = <File>[];
          for (var i = 0; i < 10; i++) {
            final directory = await Directory('${root.path}/clip-$i').create();
            clips.add(
              await File('${directory.path}/input.mp4').writeAsBytes([1]),
            );
          }
          final list = await File('${root.path}/list.txt').writeAsString(
            [
              for (var i = 0; i < 10; i++) "file 'clip-$i/input.mp4'",
            ].join('\n'),
          );
          final font = await File('${root.path}/font.ttf').writeAsBytes([1]);
          final subtitle = await File('${root.path}/sub.srt').writeAsBytes([1]);
          final attachment = await File(
            '${root.path}/${List.filled(180, 'x').join()}.bin',
          ).writeAsBytes([1]);
          final pattern = '${frames.path}/frame-%d.png';
          final broker = AiToolApprovalController();
          addTearDown(broker.dispose);
          final registry = ToolOperationRegistry();
          addTearDown(registry.dispose);
          final operations = ToolOperationManager(
            ownerSessionId: 'owner',
            registry: registry,
            gate: () => ToolPermissionGate(
              ToolPermissionService(
                appDb,
                episodeExists: (_, _) async => false,
              ),
              broker,
              enabled: true,
            ),
            onChanged: (_) {},
            onRecord: (_) {},
          );
          addTearDown(operations.dispose);
          await appDb
              .into(appDb.novels)
              .insert(
                NovelsCompanion.insert(
                  id: 'work',
                  title: 'Work',
                  description: '',
                ),
              );
          await appDb
              .into(appDb.aiChatSessions)
              .insert(
                AiChatSessionsCompanion.insert(id: 'owner', novelId: 'work'),
              );
          toolManager = AiToolManager(
            NovelContentService(db),
            workingOverlayService: toolManager.workingOverlayService,
            workId: 'work',
            sessionId: 'owner',
            operationHost: ToolOperationHost(operations),
          )..registerAllTools();
          final args = [
            '-i',
            pattern,
            '-f',
            'concat',
            '-i',
            list.path,
            '-vf',
            'drawtext=fontfile=${ffmpegFilterValue(font.path)},subtitles=${ffmpegFilterValue(subtitle.path)}',
            '-attach',
            attachment.path,
            'videos/out.mkv',
          ];
          final waiting = broker.stream.firstWhere(
            (requests) => requests.isNotEmpty,
          );
          final processContext = ToolExecutionContext(
            sessionId: 'owner',
            sourceTurnId: 'turn',
          );
          final pending = _settled(
            operations,
            processContext,
            toolManager.executeTool(
              name: 'Run',
              callId: 'process',
              context: processContext,
              input: {
                'command': 'ffmpeg',
                'subcommand': 'execute',
                'options': {'args': args},
              },
            ),
          );
          final request = (await Future.any([
            waiting,
            pending.then(
              (result) => throw StateError('Exited before approval: $result'),
            ),
          ]).timeout(const Duration(seconds: 10))).single;
          expect(
            request.arguments['inputs'],
            unorderedEquals([
              pattern,
              list.path,
              font.path,
              subtitle.path,
              attachment.path,
            ]),
          );
          expect(request.arguments['input_count'], 5);
          expect(request.arguments['args'], args);
          expect(request.targetLabel, contains('frame-%d.png'));
          expect(request.targetLabel, isNot(contains('frame-128.png')));
          final nextApproval = broker.stream.firstWhere(
            (requests) =>
                requests.isNotEmpty && !identical(requests.single, request),
          );
          await broker.resolve(request, allow: true);
          final childrenRequest = (await nextApproval).single;
          expect(
            childrenRequest.arguments['inputs'],
            unorderedEquals(
              await Future.wait(
                clips.map((file) => file.resolveSymbolicLinks()),
              ),
            ),
          );
          expect(childrenRequest.arguments['input_count'], 10);
          final changed = changedDependency == 'sequence'
              ? File('${frames.path}/frame-128.png')
              : clips.last;
          await changed.writeAsBytes([1, 2]);
          await broker.resolve(childrenRequest, allow: true);
          final result = await pending;
          expect(result['error_code'], 'conflict', reason: '$result');
        },
      );
    }

    for (final subcommand in ['execute', 'probe', 'frames']) {
      test('Run ffmpeg $subcommand rejects removed request_id', () async {
        final manager = ToolOperationManager(
          ownerSessionId: 'owner',
          registry: ToolOperationRegistry(),
          gate: () => throw StateError('No execution expected'),
          onChanged: (_) {},
          onRecord: (_) {},
        );
        addTearDown(manager.dispose);
        addTearDown(manager.registry.dispose);
        toolManager.operationHost = ToolOperationHost(manager);
        final result = await toolManager.executeTool(
          name: 'Run',
          callId: 'removed-option',
          context: ToolExecutionContext(
            sessionId: 'owner',
            sourceTurnId: 'turn',
          ),
          input: {
            'command': 'ffmpeg',
            'subcommand': subcommand,
            'options': {'request_id': 'old-request'},
          },
        );
        expect(result['ok'], false);
        expect(result.toString(), contains('Unsupported FFmpeg option'));
        expect(manager.state.runs, isEmpty);
      });
    }

    test(
      'Run operations validates options and controls the registered run',
      () async {
        final broker = AiToolApprovalController();
        final operations = ToolOperationManager(
          ownerSessionId: 'owner',
          registry: ToolOperationRegistry(),
          gate: () => ToolPermissionGate(
            ToolPermissionService(appDb, episodeExists: (_, _) async => false),
            broker,
            enabled: true,
          ),
          onChanged: (_) {},
          onRecord: (_) {},
        );
        toolManager.operationHost = ToolOperationHost(operations);
        final context = ToolExecutionContext(
          sessionId: 'owner',
          sourceTurnId: 'turn',
        );
        final finish = Completer<Map<String, dynamic>>();
        final receipt = await operations.start(
          context: context,
          callId: 'operation',
          workId: 'work',
          kind: 'editing.preview',
          targetPath: '/editings/one',
          toolName: 'Run',
          background: true,
          execute: (_) => finish.future,
          verifyTarget: () async {},
        );
        final id = receipt['run_id'];
        Future<Map<String, dynamic>> run(
          String action,
          Map<String, dynamic> options, {
          ToolExecutionContext? caller,
        }) => toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'operations',
            'subcommand': action,
            'options': options,
          },
          context: caller ?? context,
        );
        expect((await run('list', {}))['entries'], hasLength(1));
        expect(
          (await run('wait', {'run_id': id, 'timeout_ms': 1}))['timed_out'],
          true,
        );
        expect((await run('read', {'run_id': id}))['status'], 'running');
        expect(
          (await run('list', {'limit': 201}))['error_code'],
          'invalid_argument',
        );
        expect(
          (await run('list', {'status': 'invented'}))['error_code'],
          'invalid_argument',
        );
        expect(
          (await run(
            'read',
            {'run_id': id},
            caller: ToolExecutionContext(
              sessionId: 'other',
              sourceSessionId: 'owner',
            ),
          ))['error_code'],
          'permission_denied',
        );
        expect((await run('cancel', {'run_id': id}))['status'], 'cancelling');
        finish.complete({'ok': false, 'cancelled': true});
        expect((await run('wait', {'run_id': id}))['status'], 'cancelled');
        expect((await run('cancel', {'run_id': id}))['accepted'], false);
        operations.dispose();
        broker.dispose();
      },
    );

    test(
      'Run themes preserves structured color patches and revisions',
      () async {
        final result = await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'themes',
            'subcommand': 'update',
            'options': {
              'id': 'theme-1',
              'revision': 2,
              'lightOverrides': {'accent': '#245C42', 'border': null},
            },
          },
        );
        expect(result['ok'], isTrue);
        expect(result['received'], {
          'action': 'update',
          'id': 'theme-1',
          'revision': 2,
          'lightOverrides': {'accent': '#245C42', 'border': null},
        });
      },
    );

    setUp(() {
      db = NovelContentDatabase.forTest(NativeDatabase.memory());
      appDb = AppDatabase.forTest(NativeDatabase.memory());
      final contentService = NovelContentService(db);
      prompts = <String>[];
      agentSkillCommands = <Map<String, dynamic>>[];
      subagentCommands = <Map<String, dynamic>>[];
      mapDrafts = <MapDesignDraft>[];
      toolManager =
          AiToolManager(
              contentService,
              workingOverlayService: WorkingOverlayService(
                db,
                contentService,
                novelActionsService: NovelActionsService(appDb),
              ),
              imageGenerationCallback: (prompt, {model, size, quality}) async {
                prompts.add('$size:$prompt');
                return AiImageGenerationResult(
                  localFilePath: '/tmp/${size ?? 'unknown'}.png',
                );
              },
              agentSkillsCommandCallback: (command) async {
                agentSkillCommands.add(command);
                return {'ok': true, 'received': command};
              },
              themesCommandCallback: (command) async => {
                'ok': true,
                'received': command,
              },
              subagentsCommandCallback: (command) async {
                subagentCommands.add(command);
                if (command['action'] == 'delete' &&
                    !command.containsKey('confirm')) {
                  return {
                    'ok': false,
                    'error': 'subagents delete requires confirmation',
                    'error_code': 'confirmation_required',
                  };
                }
                return {'ok': true, 'received': command};
              },

              novelDraftClearer: () async {
                throw const NovelTitleConflictException('同名作品');
              },
            )
            ..mapDraftCommandCallback = (draft) async {
              mapDrafts.add(draft);
              return {
                'ok': true,
                'output': 'Map design draft is ready for review.',
              };
            }
            ..registerAllTools();
    });

    tearDown(() async {
      await db.close();
      await appDb.close();
    });

    test(
      'Run files waits for approval and returns a persistent text snapshot',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'files_dispatch_',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => directory.path,
        );
        await RevericPaths.initialize();
        addTearDown(() async {
          messenger.setMockMethodCallHandler(channel, null);
          await directory.delete(recursive: true);
        });
        await appDb
            .into(appDb.novels)
            .insert(
              NovelsCompanion.insert(
                id: 'work',
                title: 'Work',
                description: '',
              ),
            );
        await appDb
            .into(appDb.aiChatSessions)
            .insert(
              AiChatSessionsCompanion.insert(id: 'owner', novelId: 'work'),
            );
        final broker = AiToolApprovalController();
        final operations = ToolOperationManager(
          ownerSessionId: 'owner',
          registry: ToolOperationRegistry(),
          gate: () => ToolPermissionGate(
            ToolPermissionService(appDb, episodeExists: (_, _) async => false),
            broker,
            enabled: true,
          ),
          onChanged: (_) {},
          onRecord: (_) {},
        );
        addTearDown(() {
          operations.dispose();
          broker.dispose();
        });
        final manager = AiToolManager(
          NovelContentService(db),
          workingOverlayService: toolManager.workingOverlayService,
          workId: 'work',
          sessionId: 'owner',
          operationHost: ToolOperationHost(operations),
        )..registerAllTools();
        final source = File('${directory.path}/source.txt');
        await source.writeAsString('saved original');
        final approval = broker.stream.firstWhere((rows) => rows.isNotEmpty);
        final pending = manager.executeTool(
          name: 'Run',
          callId: 'read-call',
          context: ToolExecutionContext(
            sessionId: 'owner',
            sourceSessionId: 'owner',
            sourceTurnId: 'turn',
          ),
          input: {
            'command': 'files',
            'subcommand': 'read-text',
            'options': {'path': source.path},
          },
        );
        final requests = await approval;
        expect(
          await Directory(
            '${directory.path}/file_workspaces/work/sessions',
          ).exists(),
          isFalse,
        );
        expect(requests.single.callId, 'read-call');
        await broker.resolve(requests.single, allow: true);
        final result = await pending;
        expect(result['status'], 'completed');
        expect(result, isA<StructuredToolResult>());
        expect(
          (result as StructuredToolResult).content
              .whereType<TextBlock>()
              .last
              .text,
          contains('saved original'),
        );
        final path = (result['result'] as Map)['snapshot_path'] as String;
        expect(
          (result['result'] as Map)['file_path'],
          startsWith('sessions/owner/'),
        );
        await source.delete();
        expect(
          await File('${directory.path}/$path').readAsString(),
          'saved original',
        );
      },
    );

    for (final decision in ['allow', 'deny', 'changed']) {
      test(
        'Run files list and remove keep read permission separate: $decision',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'files-management-route-',
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          const channel = MethodChannel('plugins.flutter.io/path_provider');
          messenger.setMockMethodCallHandler(channel, (_) async => root.path);
          await RevericPaths.initialize();
          addTearDown(() async {
            messenger.setMockMethodCallHandler(channel, null);
            await root.delete(recursive: true);
          });
          await appDb
              .into(appDb.novels)
              .insert(
                NovelsCompanion.insert(
                  id: 'work',
                  title: 'Work',
                  description: '',
                ),
              );
          await appDb
              .into(appDb.aiChatSessions)
              .insert(
                AiChatSessionsCompanion.insert(id: 'owner', novelId: 'work'),
              );
          final permissions = ToolPermissionService(
            appDb,
            episodeExists: (_, _) async => false,
          );
          await permissions.setRule(
            'files.read',
            const ToolPermissionScope.global(),
            ToolPermissionDecision.deny,
          );
          final broker = AiToolApprovalController();
          final operations = ToolOperationManager(
            ownerSessionId: 'owner',
            registry: ToolOperationRegistry(),
            gate: () => ToolPermissionGate(permissions, broker, enabled: true),
            onChanged: (_) {},
            onRecord: (_) {},
          );
          addTearDown(() {
            operations.dispose();
            broker.dispose();
          });
          final manager = AiToolManager(
            NovelContentService(db),
            workingOverlayService: toolManager.workingOverlayService,
            workId: 'work',
            sessionId: 'owner',
            operationHost: ToolOperationHost(operations, media: false),
          )..registerAllTools();
          await Directory(
            '${root.path}/file_workspaces/work/media',
          ).create(recursive: true);
          final selected = await File(
            '${root.path}/file_workspaces/work/media/failed-1.mp4',
          ).writeAsString('partial');
          final kept = await File(
            '${root.path}/file_workspaces/work/media/keep.mp4',
          ).writeAsString('keep');
          Future<Map<String, dynamic>> run(
            String action, {
            String path = 'media/failed-*.mp4',
          }) => manager.executeTool(
            name: 'Run',
            callId: 'files-$action',
            context: ToolExecutionContext(
              sessionId: 'owner',
              sourceSessionId: 'owner',
              sourceTurnId: 'turn',
            ),
            input: {
              'command': 'files',
              'subcommand': action,
              'options': {'path': path},
            },
          );
          final nothing = await manager.executeTool(
            name: 'Run',
            callId: 'files-none',
            context: ToolExecutionContext(
              sessionId: 'owner',
              sourceSessionId: 'owner',
              sourceTurnId: 'turn',
            ),
            input: {
              'command': 'files',
              'subcommand': 'remove',
              'options': {'path': 'media/missing-*.mp4'},
            },
          );
          expect(nothing['matched_count'], 0);
          expect(nothing['removed'], isEmpty);
          expect(broker.pending, isEmpty);
          final listed = await run('list');
          expect(listed['status'], 'completed');
          expect(listed['result']['entries'][0]['path'], 'media/failed-1.mp4');
          expect(broker.pending, isEmpty);
          await File(
            '${root.path}/file_workspaces/work/media/note.txt',
          ).writeAsString('local read');
          final localRead = await run('read-text', path: 'media/note.txt');
          expect(localRead['status'], 'completed');
          expect(localRead['result']['text'], 'local read');
          final absoluteRead = await run('read-text', path: kept.path);
          expect(absoluteRead['error_code'], 'permission_denied');
          final absoluteList = await run('list', path: kept.parent.path);
          expect(absoluteList['error_code'], 'permission_denied');
          expect(broker.pending, isEmpty);
          final approval = broker.stream.firstWhere((rows) => rows.isNotEmpty);
          final pending = run('remove');
          final request = (await approval).single;
          expect(request.action, 'files.remove');
          expect(request.arguments['matched_count'], 1);
          expect(request.arguments['folders'], [
            {'path': 'media/', 'count': 1},
          ]);
          expect(request.arguments.containsKey('paths'), false);
          expect(await selected.exists(), true);
          if (decision == 'changed') {
            await File(
              '${root.path}/file_workspaces/work/media/failed-2.mp4',
            ).writeAsString('new');
          }
          await broker.resolve(request, allow: decision != 'deny');
          final result = await pending;
          if (decision == 'allow') {
            expect(result['result']['removed'], ['media/failed-1.mp4']);
            expect(await selected.exists(), false);
          } else {
            expect(
              result['result']['error_code'],
              decision == 'deny' ? 'permission_denied' : 'conflict',
            );
            expect(await selected.exists(), true);
          }
          expect(await kept.exists(), true);
        },
      );
    }

    test('registers Run but not legacy top-level tools', () async {
      expect(toolManager.allToolNames(), contains('Run'));
      expect(toolManager.allToolNames(), isNot(contains('CreateTip')));
      expect(
        toolManager.allToolDefs().map((tool) => tool.name),
        contains('Run'),
      );
      expect(
        toolManager.allToolDefs().map((tool) => tool.name),
        isNot(contains('CreateTip')),
      );

      final oldTipResult = await toolManager.executeTool(
        name: 'CreateTip',
        input: {'tip_name': 'old top-level tool', 'tip_description': 'old'},
        callId: 'call_old_create_tip',
      );

      expect(oldTipResult['ok'], isFalse);
      expect(oldTipResult['error'], 'Unknown tool: CreateTip');
      expect(oldTipResult['error_code'], 'not_found');
    });

    test(
      'returns a title conflict when adding a duplicate draft to library',
      () async {
        final result = await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'novel',
            'subcommand': 'add-to-library',
            'options': const <String, dynamic>{},
          },
          callId: 'call_run_novel_title_conflict',
        );

        expect(result['ok'], isFalse);
        expect(result['exit_code'], 1);
        expect(result['error_code'], 'already_exists');
        expect(result['output'], contains('同名作品'));
      },
    );

    Future<AiToolApprovalController> useSubjectImageHost({
      required bool approval,
      AiImageEditCallback? edit,
      AiImageGenerationCallback? generate,
    }) async {
      final imageRoot = await Directory.systemTemp.createTemp('subject-image-');
      const imageChannel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(imageChannel, (_) async => imageRoot.path);
      await RevericPaths.initialize();
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(imageChannel, null);
        await imageRoot.delete(recursive: true);
      });
      await db
          .into(db.characterProfiles)
          .insert(CharacterProfilesCompanion.insert(id: 'c_1', name: '法师'));
      await db
          .into(db.items)
          .insert(
            ItemsCompanion.insert(id: 'item_1', type: 'item', title: '古剑'),
          );
      final broker = AiToolApprovalController();
      final operations = ToolOperationManager(
        ownerSessionId: 'owner',
        registry: ToolOperationRegistry(),
        gate: () => ToolPermissionGate(
          ToolPermissionService(appDb, episodeExists: (_, _) async => false),
          broker,
          enabled: approval,
        ),
        onChanged: (_) {},
        onRecord: (_) {},
      );
      addTearDown(() {
        operations.dispose();
        broker.dispose();
      });
      await appDb
          .into(appDb.novels)
          .insert(
            NovelsCompanion.insert(id: 'work', title: 'Work', description: ''),
          );
      await appDb
          .into(appDb.aiChatSessions)
          .insert(AiChatSessionsCompanion.insert(id: 'owner', novelId: 'work'));
      toolManager = AiToolManager(
        NovelContentService(
          db,
          imageLibraryService: buildImageLibraryService(appDb),
        ),
        workingOverlayService: toolManager.workingOverlayService,
        workId: 'work',
        sessionId: 'owner',
        operationHost: ToolOperationHost(operations, media: false),
        imageEditCallback: edit,
        imageGenerationCallback:
            generate ??
            (prompt, {model, size, quality}) async {
              prompts.add('$size:$prompt');
              final file = await File('${imageRoot.path}/$size.png').writeAsBytes(
                base64Decode(
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                ),
              );
              final library = buildImageLibraryService(appDb);
              final asset = await library.importGenerated(
                AiImageGenerationResult(localFilePath: file.path),
                novelId: 'work',
                purpose: AssetPurpose.ai_chat_generated,
                prompt: prompt,
                model: model,
              );
              return AiImageGenerationResult(
                localFilePath: library.resolve(asset.path),
                assetId: asset.id,
              );
            },
      )..registerAllTools();
      return broker;
    }

    Future<Map<String, dynamic>> runSubjectImage(
      String command,
      String subcommand,
      Map<String, dynamic> options,
    ) => toolManager.executeTool(
      name: 'Run',
      input: {'command': command, 'subcommand': subcommand, 'options': options},
      callId: 'call_$command$subcommand',
      context: ToolExecutionContext(
        sessionId: 'owner',
        sourceSessionId: 'owner',
        sourceTurnId: 'turn',
      ),
    );

    test(
      'real image callbacks commit once and handlers consume durable generated and edited files',
      () async {
        HttpOverrides.global = null;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        var calls = 0;
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        );
        server.listen((request) async {
          await request.drain<void>();
          calls++;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'data': [
                {
                  'b64_json': base64Encode([...bytes, calls]),
                  'revised_prompt': 'revised',
                },
              ],
            }),
          );
          await request.response.close();
        });
        final config = AiProvider(
          id: 'image-fixture',
          name: 'Fixture',
          builtin: false,
          type: 'openai_compatible',
          enabled: true,
          apiKey: 'fixture',
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          models: const [],
          imageModels: const ['image-advance'],
          audioModels: const [],
          videoModels: const [],
          embeddingModels: const [],
          temperature: .7,
          maxTurns: 8,
          proxyUrl: '',
          proxyUsername: '',
          proxyPassword: '',
          updatedAt: DateTime(2026),
          deletedAt: notDeletedSentinel,
        );
        final library = buildImageLibraryService(appDb);
        final container = ProviderContainer(
          overrides: [
            imageGenerationConfigProvider.overrideWithValue(config),
            resolvedAiModelOptionForKindProvider(
              kind: AiModelKind.image,
            ).overrideWithValue(
              const AiModelOption(
                providerId: 'image-fixture',
                providerDisplayName: 'Fixture',
                model: 'image-advance',
                kind: AiModelKind.image,
              ),
            ),
            imageLibraryServiceProvider.overrideWithValue(library),
          ],
        );
        addTearDown(container.dispose);
        // 没有页面订阅或全局作品上下文，调用期间才持有生图依赖。
        await useSubjectImageHost(
          approval: false,
          generate: (prompt, {model, size, quality}) => container.withProvider(
            imageGenerationCallbackProvider('work'),
            (callback) =>
                callback!(prompt, model: model, size: size, quality: quality),
          ),
          edit: (prompt, {required imageData, model}) => container.withProvider(
            imageEditCallbackProvider('work'),
            (callback) => callback!(prompt, imageData: imageData, model: model),
          ),
        );
        final first = await runSubjectImage('character', 'generate-avatar', {
          'character': 'c_1',
          'prompt': 'first prompt',
        });
        expect(first['ok'], true, reason: '$first');
        await container.pump();
        expect(
          container.exists(imageGenerationCallbackProvider('work')),
          isFalse,
        );
        // 模拟桌面切到另一作品，已有会话的照片仍归属发起作品。
        final contextSubscription = container.listen(
          aiSessionContextNotifierProvider,
          (_, _) {},
        );
        addTearDown(contextSubscription.close);
        container
            .read(aiSessionContextNotifierProvider.notifier)
            .updateContext(const AiSessionContext(workId: 'other-work'));
        final setAvatar = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': 'characters/c_1/avatar_asset_id',
            'value': first['asset_id'],
          },
        );
        expect(setAvatar['updated'], isTrue, reason: '$setAvatar');
        final avatar = await toolManager.executeTool(
          name: 'Read',
          input: {'path': 'characters/c_1/avatar_asset_id'},
        );
        final second = await runSubjectImage('character', 'generate-photo', {
          'character': 'c_1',
          'prompt': 'edit prompt',
          'asset_id': avatar['value'],
        });
        expect(second['ok'], true, reason: '$second');
        await container.pump();
        expect(container.exists(imageEditCallbackProvider('work')), isFalse);
        final subscription = container.listen(
          aiChatSessionProvider('image-result'),
          (_, _) {},
        );
        addTearDown(subscription.close);
        final session = container.read(
          aiChatSessionProvider('image-result').notifier,
        );
        session.startStreamingMessage();
        for (final result in [first, second]) {
          session.upsertImageBlock(
            const AiImageBlock(id: 'result', prompt: 'portrait'),
          );
          session.patchImageBlock(
            'result',
            status: AiImageStatus.success,
            assetId: result['asset_id'] as String?,
            localFilePath: result['local_path'] as String?,
          );
          final block = container
              .read(aiChatSessionProvider('image-result'))
              .messages
              .expand((message) => message.blocks)
              .whereType<AiImageBlock>()
              .single;
          expect(block.assetId, isNotNull);
          final restored =
              AiMessageBlock.fromJson(block.toJson()) as AiImageBlock;
          expect(restored.assetId, result['asset_id']);
          expect(result['local_path'], startsWith('images/'));
          expect(
            await appDb.imageAssetDao.getAsset(result['asset_id'] as String),
            isNotNull,
          );
          expect(
            await File(
              '${RevericPaths.supportRoot}/file_workspaces/work/${result['local_path']}',
            ).exists(),
            true,
          );
        }
        final assets = await appDb.select(appDb.assets).get();
        expect(assets, hasLength(2));
        expect(assets.map((asset) => asset.novelId), everyElement('work'));
        expect(
          assets.map((a) => a.purpose),
          everyElement(AssetPurpose.ai_chat_generated.value),
        );
        expect(assets.map((a) => a.prompt).toSet(), {
          'first prompt',
          'edit prompt',
        });
        expect(assets.map((a) => a.model), everyElement('image-advance'));
        expect(
          Directory('${RevericPaths.supportRoot}/file_workspaces')
              .listSync(recursive: true)
              .where((entry) => entry.path.endsWith('.part')),
          isEmpty,
        );
      },
    );

    test(
      'routes character avatar and character photo through image handlers',
      () async {
        await useSubjectImageHost(approval: false);
        final avatar = await runSubjectImage('character', 'generate-avatar', {
          'character': 'c_1',
          'prompt': 'stern mage',
        });
        final photo = await runSubjectImage('character', 'generate-photo', {
          'character': 'c_1',
          'prompt': 'full body',
        });

        expect(avatar['command'], 'character generate-avatar');
        expect(avatar['local_path'], startsWith('images/'));
        expect(avatar['asset_id'], isA<String>());
        expect(avatar['character_id'], 'c_1');
        expect(photo['command'], 'character generate-photo');
        expect(photo['local_path'], startsWith('images/'));
        expect(photo['asset_id'], isA<String>());
        expect(photo['character_id'], 'c_1');
        final write = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': 'characters/c_1/avatar_asset_id',
            'value': avatar['asset_id'],
          },
        );
        expect(write['updated'], isTrue, reason: '$write');
        final read = await toolManager.executeTool(
          name: 'Read',
          input: {'path': 'characters/c_1/avatar_asset_id'},
        );
        expect(read['value'], avatar['asset_id']);
        final photos = await toolManager.executeTool(
          name: 'Write',
          input: {
            'path': 'characters/c_1/photos',
            'value': [
              {'asset_id': photo['asset_id'], 'name': '全身'},
            ],
          },
        );
        expect(photos['updated'], isTrue, reason: '$photos');
        expect(await appDb.select(appDb.assets).get(), hasLength(1));
        expect(prompts, ['1024x1024:stern mage', '864x1536:full body']);
      },
    );

    test('routes item photo command through item-only subcommand', () async {
      await useSubjectImageHost(approval: false);
      final photo = await runSubjectImage('item', 'generate-photo', {
        'item': 'item_1',
        'prompt': 'ancient sword',
      });

      expect(photo['ok'], isTrue);
      expect(photo['success'], isTrue);
      expect(photo['command'], 'item generate-photo');
      expect(photo['local_path'], startsWith('images/'));
      expect(photo['item_id'], 'item_1');
      expect(photo['_metadata'], containsPair('item_id', 'item_1'));
      expect(prompts, ['864x1536:ancient sword']);
    });

    for (final (command, subcommand, subject) in [
      ('character', 'generate-avatar', 'c_1'),
      ('character', 'generate-photo', 'c_1'),
      ('item', 'generate-photo', 'item_1'),
    ]) {
      test(
        '$command $subcommand references only valid images in this work',
        () async {
          final edited = <String>[];
          late AssetRow reference;
          await useSubjectImageHost(
            approval: false,
            edit: (prompt, {required imageData, model}) async {
              edited.add(imageData);
              return AiImageGenerationResult(
                localFilePath: imageData,
                assetId: reference.id,
              );
            },
          );
          final source = await File('${RevericPaths.supportRoot}/参考图.png')
              .writeAsBytes(
                base64Decode(
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                ),
              );
          final library = buildImageLibraryService(appDb);
          reference = await library.importFile(
            source.path,
            novelId: 'work',
            purpose: AssetPurpose.avatar,
          );
          final options = {command: subject, 'prompt': 'Keep the character'};
          final result = await runSubjectImage(command, subcommand, {
            ...options,
            'asset_id': reference.id,
          });
          expect(result['ok'], isTrue, reason: '$result');
          expect(
            edited.single,
            await File(
              RevericPaths.resolveStored(reference.path)!,
            ).resolveSymbolicLinks(),
          );
          expect(
            await File(edited.single).readAsBytes(),
            await source.readAsBytes(),
          );

          for (final invalid in [
            'missing',
            source.path,
            'https://example.com/reference.png',
            '',
            42,
            null,
          ]) {
            final rejected = await runSubjectImage(command, subcommand, {
              ...options,
              'asset_id': invalid,
            });
            expect(rejected['ok'], isFalse, reason: '$rejected');
          }
          for (final invalidState in [
            const AssetsCompanion(novelId: Value('other-work')),
            const AssetsCompanion(novelId: Value(null)),
            AssetsCompanion(deletedAt: Value(DateTime(2026))),
            const AssetsCompanion(type: Value('video')),
            const AssetsCompanion(path: Value(null)),
            const AssetsCompanion(
              path: Value('file_workspaces/work/images/missing.png'),
            ),
          ]) {
            await (appDb.update(
              appDb.assets,
            )..where((row) => row.id.equals(reference.id))).write(invalidState);
            final rejected = await runSubjectImage(command, subcommand, {
              ...options,
              'asset_id': reference.id,
            });
            expect(rejected['ok'], isFalse, reason: '$rejected');
            await (appDb.update(
              appDb.assets,
            )..where((row) => row.id.equals(reference.id))).write(
              AssetsCompanion(
                novelId: const Value('work'),
                deletedAt: Value(notDeletedSentinel),
                type: const Value('image'),
                path: Value(reference.path),
              ),
            );
          }
          expect(edited, hasLength(1));
          expect(prompts, isEmpty);
        },
      );
    }

    test('reference asset is checked again after approval', () async {
      var edits = 0;
      final broker = await useSubjectImageHost(
        approval: true,
        edit: (prompt, {required imageData, model}) async {
          edits++;
          throw StateError(
            'Deleted reference must not reach the image service',
          );
        },
      );
      final source = await File('${RevericPaths.supportRoot}/reference.png')
          .writeAsBytes(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            ),
          );
      final reference = await buildImageLibraryService(
        appDb,
      ).importFile(source.path, novelId: 'work', purpose: AssetPurpose.avatar);
      final waiting = broker.stream.firstWhere((rows) => rows.isNotEmpty);
      final pending = runSubjectImage('character', 'generate-photo', {
        'character': 'c_1',
        'prompt': 'Portrait',
        'asset_id': reference.id,
      });
      final request = (await waiting).single;
      await (appDb.update(appDb.assets)
            ..where((row) => row.id.equals(reference.id)))
          .write(AssetsCompanion(deletedAt: Value(DateTime(2026))));
      await broker.resolve(request, allow: true);
      final result = await pending;
      expect(result['ok'], isFalse, reason: '$result');
      expect(edits, 0);
      expect(prompts, isEmpty);
    });

    test(
      'character image waits for approval and denial never generates',
      () async {
        final broker = await useSubjectImageHost(approval: true);
        final waiting = broker.stream.firstWhere((rows) => rows.isNotEmpty);
        final pending = runSubjectImage('character', 'generate-avatar', {
          'character': 'c_1',
          'prompt': 'stern mage',
        });
        final request = (await waiting).single;
        expect(request.action, 'generation.image');
        expect(request.targetLabel, '法师');
        expect(prompts, isEmpty);
        await broker.resolve(request, allow: false);
        final result = await pending;
        expect(result['ok'], isFalse);
        expect(result['error_code'], 'permission_denied');
        expect(prompts, isEmpty);
      },
    );

    test('rejects unknown subjects and removed image command', () async {
      await useSubjectImageHost(approval: false);
      final missing = await runSubjectImage('character', 'generate-avatar', {
        'character': 'missing',
        'prompt': 'stern mage',
      });
      expect(missing['error_code'], 'not_found');
      final itemAsCharacter = await runSubjectImage(
        'character',
        'generate-photo',
        {'character': 'item_1', 'prompt': 'sword'},
      );
      expect(itemAsCharacter['error_code'], 'not_found');
      final removed = await runSubjectImage('image', 'character-avatar', {
        'character': 'c_1',
        'prompt': 'stern mage',
      });
      expect(removed['exit_code'], 127);
      expect(prompts, isEmpty);
    });

    test('rejects unsupported mixed photo command', () async {
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'item',
          'subcommand': 'photo',
          'options': {'item': 'item_1', 'prompt': 'ancient sword'},
        },
        callId: 'call_run_unsupported_photo',
      );

      expect(result['ok'], isFalse);
      expect(result['exit_code'], 1);
      expect(result['output'], contains('item requires generate-photo'));
      expect(result['output'], contains('Item commands:'));
      expect(prompts, isEmpty);
    });

    test(
      'Run help lists all base commands and points to skill-owned contracts',
      () async {
        final baseSkillCommands = Map.of(bundledControlRunCommandToCallName)
          ..removeWhere(
            (command, _) => const {
              'stagings',
              'styles',
              'production',
              'editing',
              'ffmpeg',
              'files',
              'operations',
              'settings',
            }.contains(command),
          );
        final help = await toolManager.executeTool(
          name: 'Run',
          input: {'command': 'help'},
          callId: 'call_run_help',
        );

        expect(help['ok'], isTrue);
        expect(help['output'], contains('Available commands:'));
        final listed = RegExp(
          r'^  ([a-z-]+) +',
          multiLine: true,
        ).allMatches(help['output'] as String).map((match) => match.group(1)!);
        expect(
          listed,
          unorderedEquals([
            'providers',
            'novel',
            'sessions',
            'map',
            'notify',
            'character',
            'item',
            ...baseSkillCommands.keys,
          ]),
        );
        for (final entry in baseSkillCommands.entries) {
          expect(
            help['output'],
            matches(
              RegExp(
                '^  ${entry.key} +[^\\n]*Load AgentSkill "${entry.value}"',
                multiLine: true,
              ),
            ),
            reason: entry.key,
          );
          expect(
            help['output'],
            isNot(contains('"command":"${entry.key}"')),
            reason: entry.key,
          );

          final directedHelp = await toolManager.executeTool(
            name: 'Run',
            input: {'command': 'help', 'subcommand': entry.key},
            callId: 'call_run_skill_help_${entry.key}',
          );
          expect(directedHelp['ok'], isTrue);
          expect(directedHelp['output'], contains(entry.value));
          expect(directedHelp['output'], isNot(contains('options={')));

          final missingSubcommand = await toolManager.executeTool(
            name: 'Run',
            input: {'command': entry.key},
            callId: 'call_run_skill_empty_${entry.key}',
          );
          expect(missingSubcommand['ok'], isFalse);
          expect(missingSubcommand['output'], contains(entry.value));
          expect(missingSubcommand['output'], isNot(contains('options={')));
        }
        expect(help['output'], isNot(contains('account')));
        expect(help['output'], isNot(contains('tips')));
        expect(help['output'], contains('sessions'));
        expect(help['output'], contains('map'));
        expect(help['output'], contains('notify'));
      },
    );

    test(
      'media commands require a host with media enabled for execution and help',
      () async {
        Future<Map<String, dynamic>> run(Map<String, dynamic> input) =>
            toolManager.executeTool(name: 'Run', input: input);
        const commands = [
          'assets',
          'stagings',
          'styles',
          'editing',
          'production',
          'ffmpeg',
          'files',
          'operations',
          'settings',
        ];
        final operations = ToolOperationManager(
          ownerSessionId: 'owner',
          registry: ToolOperationRegistry(),
          gate: () => throw StateError('No permission check expected'),
          onChanged: (_) {},
          onRecord: (_) {},
        );
        addTearDown(operations.dispose);
        for (final host in [
          null,
          ToolOperationHost(operations, media: false),
        ]) {
          toolManager.operationHost = host;
          final hidden = await run({'command': 'help'});
          for (final command in commands) {
            if (host != null &&
                {'files', 'operations', 'settings'}.contains(command)) {
              expect(hidden['output'], contains('\n  $command '));
              final directed = await run({
                'command': 'help',
                'subcommand': command,
              });
              expect(directed['output'], isNot(contains('unknown command:')));
              continue;
            }
            expect(hidden['output'], isNot(contains('\n  $command ')));
            final unknown = await run({
              'command': command,
              'subcommand': 'list',
            });
            expect(unknown['ok'], isFalse);
            expect(unknown['output'], contains('unknown command: $command'));
            final directed = await run({
              'command': 'help',
              'subcommand': command,
            });
            expect(directed['output'], contains('unknown command: $command'));
          }
        }
        toolManager.operationHost = ToolOperationHost(operations);
        final listed = await run({'command': 'help'});
        for (final command in commands) {
          expect(listed['output'], contains('\n  $command '));
          final directed = await run({
            'command': 'help',
            'subcommand': command,
          });
          expect(directed['output'], isNot(contains('unknown command:')));
          final skill = bundledControlRunCommandToCallName[command];
          if (skill != null) {
            expect(
              (directed['output'] as String).split('\n').first,
              'Command "$command" is documented by bundled AgentSkill '
              '"$skill". Load that skill for supported calls.',
            );
            expect(
              listed['output'],
              matches(
                RegExp(
                  '^  $command +[^\\n]*Load AgentSkill "$skill"',
                  multiLine: true,
                ),
              ),
            );
            for (final subcommand in [null, '--help', 'unknown-action']) {
              final result = await run({
                'command': command,
                'subcommand': ?subcommand,
              });
              expect(result['ok'], isFalse);
              expect(result['error_code'], 'invalid_argument');
              expect(result['output'], contains(skill));
              expect(result['output'], isNot(contains('options={')));
            }
          }
        }
      },
    );

    test('returns an error for unsupported commands', () async {
      final help = await toolManager.executeTool(
        name: 'Run',
        input: {'command': 'help'},
        callId: 'call_run_help',
      );
      final unknown = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'web',
          'subcommand': 'search',
          'options': {'query': 'riverpod'},
        },
        callId: 'call_run_unknown',
      );

      expect(help['ok'], isTrue);
      expect(unknown['ok'], isFalse);
      expect(unknown['exit_code'], 127);
      expect(
        unknown['output'],
        contains('Use: command=help to list available commands.'),
      );
    });

    test('submits a complete map draft without generating an image', () async {
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'map',
          'subcommand': 'draft',
          'options': {
            'location': 'world_1',
            'prompt': 'A complete illustrated world map',
            'style': 'atlas',
            'resolution': '4k',
            'quality': 'high',
            'include_locations': false,
            'reference_current_image': true,
          },
        },
        callId: 'call_run_map_draft',
      );

      expect(result['ok'], isTrue);
      expect(result['command'], 'map draft');
      expect(mapDrafts, hasLength(1));
      final draft = mapDrafts.single;
      expect(draft.worldId, 'world_1');
      expect(draft.prompt, 'A complete illustrated world map');
      expect(draft.styleId, 'atlas');
      expect(draft.resolutionId, '4k');
      expect(draft.qualityId, 'high');
      expect(draft.includeLocations, isFalse);
      expect(draft.referenceCurrentImage, isTrue);
      expect(prompts, isEmpty);
    });

    test(
      'map help asks for Chinese prompts without rejecting other text',
      () async {
        final help = await toolManager.executeTool(
          name: 'Run',
          input: const {'command': 'help', 'subcommand': 'map'},
          callId: 'call_run_help_map',
        );

        expect(help['ok'], isTrue);
        expect(help['output'], contains('written in Chinese'));
        expect(help['output'], contains('must not include the visual style'));
        expect(help['output'], contains('custom_style'));
      },
    );

    test('map draft defaults match the Cartographer contract', () async {
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'map',
          'subcommand': 'draft',
          'options': {'location': 'world_1', 'prompt': 'Map prompt'},
        },
        callId: 'call_run_map_draft_defaults',
      );

      expect(result['ok'], isTrue);
      final draft = mapDrafts.single;
      expect(draft.styleId, mapDesignDefaultStyleId);
      expect(draft.resolutionId, mapDesignDefaultResolutionId);
      expect(draft.qualityId, mapDesignDefaultQualityId);
      expect(draft.includeLocations, isTrue);
      expect(draft.referenceCurrentImage, isFalse);
    });

    test('map draft accepts a custom style as a separate option', () async {
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'map',
          'subcommand': 'draft',
          'options': {
            'location': 'world_1',
            'prompt': '地图内容提示词',
            'style': 'custom',
            'custom_style': '低多边形复古航海图',
          },
        },
        callId: 'call_run_map_draft_custom_style',
      );

      expect(result['ok'], isTrue);
      final draft = mapDrafts.single;
      expect(draft.prompt, '地图内容提示词');
      expect(draft.styleId, mapCustomStyleId);
      expect(draft.customStyleWord, '低多边形复古航海图');
    });

    test('map draft rejects options outside the contract', () async {
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'map',
          'subcommand': 'draft',
          'options': {
            'location': 'world_1',
            'prompt': '地图内容提示词',
            'reference_parent_image': true,
          },
        },
        callId: 'call_run_map_draft_unknown_option',
      );

      expect(result['ok'], isFalse);
      expect(
        result['output'],
        contains('unsupported map option: reference_parent_image'),
      );
      expect(mapDrafts, isEmpty);
    });

    test('map draft rejects an empty custom style', () async {
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'map',
          'subcommand': 'draft',
          'options': {
            'location': 'world_1',
            'prompt': '地图内容提示词',
            'style': 'custom',
          },
        },
        callId: 'call_run_map_draft_empty_custom_style',
      );

      expect(result['ok'], isFalse);
      expect(result['output'], contains('custom_style'));
      expect(mapDrafts, isEmpty);
    });

    test('rejects unsupported map options before submitting', () async {
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'map',
          'subcommand': 'draft',
          'options': {
            'location': 'world_1',
            'prompt': 'Map prompt',
            'style': 'oil-painting',
          },
        },
        callId: 'call_run_map_draft_invalid',
      );

      expect(result['ok'], isFalse);
      expect(result['output'], contains('invalid map style'));
      expect(mapDrafts, isEmpty);
      expect(prompts, isEmpty);
    });

    test(
      'hoists command/subcommand mistakenly nested inside options',
      () async {
        // 实测模型误发过 {"options":{"command":...,"subcommand":...}}，顶层 command
        // 为空会被误判「Run requires command」。防呆应从 options 回捞并正常分发。
        final result = await toolManager.executeTool(
          name: 'Run',
          input: {
            'options': {'command': 'help', 'subcommand': 'character'},
          },
          callId: 'call_run_nested',
        );

        expect(result['ok'], isTrue);
        expect(result['exit_code'], 0);
        expect(result['output'], contains('Character commands:'));
        expect(result['output'], contains('generate-avatar'));
        expect(result['output'], isNot(contains('Run requires command')));
      },
    );

    test('routes agent skill management through Run subcommand', () async {
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'agent-skills',
          'subcommand': 'create',
          'options': {'name': '正文写作', 'prompt': '按本书规则写正文', 'scope': 'novel'},
        },
        callId: 'call_run_agent_skills',
      );

      expect(result['ok'], isTrue);
      expect(result['command'], 'agent-skills create');
      expect(agentSkillCommands, hasLength(1));
      expect(agentSkillCommands.single, {
        'action': 'create',
        'name': '正文写作',
        'prompt': '按本书规则写正文',
      });
    });

    test('routes agent skill Reference CRUD through Run subcommands', () async {
      final create = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'agent-skills',
          'subcommand': 'create',
          'options': {
            'name': '章节审稿',
            'prompt': '审查章节',
            'references': [
              {'path': 'references/rubric.md', 'content': '# 量表'},
            ],
          },
        },
        callId: 'call_run_agent_skills_create_with_references',
      );
      expect(create['ok'], isTrue);
      expect(agentSkillCommands.last, {
        'action': 'create',
        'name': '章节审稿',
        'prompt': '审查章节',
        'references': [
          {'path': 'references/rubric.md', 'content': '# 量表'},
        ],
      });

      final move = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'agent-skills',
          'subcommand': 'reference-move',
          'options': {
            'name': '章节审稿',
            'path': 'references/rubric.md',
            'new_path': 'references/review/rubric.md',
          },
        },
        callId: 'call_run_agent_skills_reference_move',
      );
      expect(move['ok'], isTrue);
      expect(agentSkillCommands.last, {
        'action': 'reference-move',
        'name': '章节审稿',
        'path': 'references/rubric.md',
        'new_path': 'references/review/rubric.md',
      });
    });

    test('routes subagent CRUD commands through Run subcommand', () async {
      final create = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'subagents',
          'subcommand': 'create',
          'options': {
            'slug': 'continuity_auditor',
            'name': '连续性审查',
            'description': '检查连续性',
            'prompt': '审查上下文并报告问题',
            'mode': 'council',
            'enabled': false,
          },
        },
        callId: 'call_run_subagents_create',
      );
      expect(create['ok'], isTrue);
      expect(create['command'], 'subagents create');
      expect(subagentCommands.single, {
        'action': 'create',
        'slug': 'continuity_auditor',
        'name': '连续性审查',
        'description': '检查连续性',
        'prompt': '审查上下文并报告问题',
        'mode': 'council',
        'enabled': 'false',
      });

      subagentCommands.clear();
      await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'subagents',
          'subcommand': 'update',
          'options': {'id': 'subagent_1', 'enabled': true},
        },
        callId: 'call_run_subagents_update',
      );
      expect(subagentCommands.single, {
        'action': 'update',
        'id': 'subagent_1',
        'enabled': 'true',
      });

      subagentCommands.clear();
      await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'subagents',
          'subcommand': 'delete',
          'options': {'id': 'subagent_1', 'confirm': true},
        },
        callId: 'call_run_subagents_delete',
      );
      expect(subagentCommands.single, {
        'action': 'delete',
        'id': 'subagent_1',
        'confirm': 'true',
      });

      subagentCommands.clear();
      final unconfirmedDelete = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'subagents',
          'subcommand': 'delete',
          'options': {'id': 'subagent_1'},
        },
        callId: 'call_run_subagents_delete_unconfirmed',
      );
      expect(unconfirmedDelete['ok'], isFalse);
      expect(unconfirmedDelete['error_code'], 'confirmation_required');
      expect(subagentCommands.single, {'action': 'delete', 'id': 'subagent_1'});
    });

    test('subagents help redirects to its bundled skill', () async {
      final help = await toolManager.executeTool(
        name: 'Run',
        input: {'command': 'help', 'subcommand': 'subagents'},
        callId: 'call_run_subagents_help',
      );
      final unknown = await toolManager.executeTool(
        name: 'Run',
        input: {'command': 'subagents', 'subcommand': 'install', 'options': {}},
        callId: 'call_run_subagents_unknown',
      );

      expect(help['ok'], isTrue);
      expect(help['output'], contains('系统管理'));
      expect(help['output'], isNot(contains('options={')));
      expect(unknown['ok'], isFalse);
      expect(unknown['exit_code'], 127);
      expect(unknown['output'], contains('系统管理'));
      expect(unknown['output'], isNot(contains('Available:')));
      expect(subagentCommands, isEmpty);
    });

    test('rejects the removed account command', () async {
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {'command': 'account', 'subcommand': 'login'},
      );
      expect(result['ok'], isFalse);
      expect(result['exit_code'], 127);
    });

    test(
      'agent-skills search routes with query only when source omitted',
      () async {
        agentSkillCommands.clear();
        final result = await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'search',
            'options': {'query': '伏笔'},
          },
          callId: 'call_run_agent_skills_search_default',
        );

        expect(result['ok'], isTrue);
        expect(result['command'], 'agent-skills search');
        expect(agentSkillCommands, hasLength(1));
        expect(agentSkillCommands.single, {'action': 'search', 'query': '伏笔'});
      },
    );

    test(
      'agent-skills search routes with source=official and source=marketplace',
      () async {
        agentSkillCommands.clear();
        await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'search',
            'options': {'query': 'q', 'source': 'official'},
          },
          callId: 'call_run_agent_skills_search_official',
        );
        expect(agentSkillCommands.single, {
          'action': 'search',
          'query': 'q',
          'source': 'official',
        });

        agentSkillCommands.clear();
        await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'search',
            'options': {'query': 'q', 'source': 'marketplace'},
          },
          callId: 'call_run_agent_skills_search_marketplace',
        );
        expect(agentSkillCommands.single, {
          'action': 'search',
          'query': 'q',
          'source': 'marketplace',
        });
      },
    );

    test('agent-skills search allows missing query', () async {
      agentSkillCommands.clear();
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'agent-skills',
          'subcommand': 'search',
          'options': {'source': 'official'},
        },
        callId: 'call_run_agent_skills_search_missing_query',
      );

      expect(result['ok'], isTrue);
      expect(result['command'], 'agent-skills search');
      expect(agentSkillCommands.single, {
        'action': 'search',
        'source': 'official',
      });
    });

    test(
      'agent-skills get routes for official and marketplace sources',
      () async {
        agentSkillCommands.clear();
        await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'get',
            'options': {'source': 'official', 'source_id': 'off_1'},
          },
          callId: 'call_run_agent_skills_get_official',
        );
        expect(agentSkillCommands.single, {
          'action': 'get',
          'source': 'official',
          'source_id': 'off_1',
        });

        agentSkillCommands.clear();
        await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'get',
            'options': {'source': 'marketplace', 'source_id': 'mkt_1'},
          },
          callId: 'call_run_agent_skills_get_marketplace',
        );
        expect(agentSkillCommands.single, {
          'action': 'get',
          'source': 'marketplace',
          'source_id': 'mkt_1',
        });
      },
    );

    test(
      'agent-skills get rejects missing source or source_id with usage hint',
      () async {
        agentSkillCommands.clear();
        final missingSource = await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'get',
            'options': {'source_id': 'lib_1'},
          },
          callId: 'call_run_agent_skills_get_missing_source',
        );
        expect(missingSource['ok'], isFalse);
        expect(
          missingSource['output'],
          contains('Run command requires option "source"'),
        );
        expect(
          missingSource['output'],
          contains(
            'Usage: command=agent-skills subcommand=get options={source, source_id}',
          ),
        );
        expect(agentSkillCommands, isEmpty);

        final missingSourceId = await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'get',
            'options': {'source': 'official'},
          },
          callId: 'call_run_agent_skills_get_missing_source_id',
        );
        expect(missingSourceId['ok'], isFalse);
        expect(
          missingSourceId['output'],
          contains('Run command requires option "source_id"'),
        );
      },
    );

    test(
      'agent-skills install routes source/source_id and optional call_name/conflict_resolution',
      () async {
        agentSkillCommands.clear();
        await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'install',
            'options': {
              'source': 'official',
              'source_id': 'off_1',
              'call_name': 'expand_scene',
              'conflict_resolution': 'overwrite',
            },
          },
          callId: 'call_run_agent_skills_install_overwrite',
        );
        expect(agentSkillCommands.single, {
          'action': 'install',
          'source': 'official',
          'source_id': 'off_1',
          'call_name': 'expand_scene',
          'conflict_resolution': 'overwrite',
        });

        agentSkillCommands.clear();
        await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'install',
            'options': {
              'source': 'marketplace',
              'source_id': 'mkt_1',
              'conflict_resolution': 'rename',
            },
          },
          callId: 'call_run_agent_skills_install_rename',
        );
        expect(agentSkillCommands.single, {
          'action': 'install',
          'source': 'marketplace',
          'source_id': 'mkt_1',
          'conflict_resolution': 'rename',
        });
      },
    );

    test(
      'agent-skills install rejects missing source or source_id with usage hint',
      () async {
        agentSkillCommands.clear();
        final missingSource = await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'install',
            'options': {'source_id': 'lib_1'},
          },
          callId: 'call_run_agent_skills_install_missing_source',
        );
        expect(missingSource['ok'], isFalse);
        expect(
          missingSource['output'],
          contains('Run command requires option "source"'),
        );
        expect(
          missingSource['output'],
          contains(
            'Usage: command=agent-skills subcommand=install options={source, source_id, call_name?, conflict_resolution?}',
          ),
        );
        expect(agentSkillCommands, isEmpty);

        final missingSourceId = await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'install',
            'options': {'source': 'official'},
          },
          callId: 'call_run_agent_skills_install_missing_source_id',
        );
        expect(missingSourceId['ok'], isFalse);
        expect(
          missingSourceId['output'],
          contains('Run command requires option "source_id"'),
        );
      },
    );

    test(
      'agent-skills rejects the removed library source before invoking handlers',
      () async {
        for (final input in [
          {
            'command': 'agent-skills',
            'subcommand': 'search',
            'options': {'source': 'library'},
          },
          {
            'command': 'agent-skills',
            'subcommand': 'get',
            'options': {'source': 'library', 'source_id': 'lib_1'},
          },
          {
            'command': 'agent-skills',
            'subcommand': 'install',
            'options': {'source': 'library', 'source_id': 'lib_1'},
          },
        ]) {
          agentSkillCommands.clear();
          final result = await toolManager.executeTool(
            name: 'Run',
            input: input,
            callId: 'call_run_agent_skills_invalid_source',
          );

          expect(result['ok'], isFalse);
          expect(
            result['output'],
            contains('invalid agent skill source: library'),
          );
          expect(
            result['output'],
            contains('Supported: official, marketplace'),
          );
          expect(agentSkillCommands, isEmpty);
        }
      },
    );

    test(
      'agent-skills unknown subcommand redirects to its bundled skill',
      () async {
        agentSkillCommands.clear();
        final result = await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-skills',
            'subcommand': 'frobnicate',
            'options': {},
          },
          callId: 'call_run_agent_skills_unknown',
        );

        expect(result['ok'], isFalse);
        expect(result['exit_code'], 127);
        expect(
          result['output'],
          contains('unknown agent-skills command: frobnicate'),
        );
        expect(result['output'], contains('系统管理'));
        expect(result['output'], isNot(contains('Available:')));
        expect(agentSkillCommands, isEmpty);
      },
    );

    test('agent-skills help redirects to its bundled skill', () async {
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {'command': 'help', 'subcommand': 'agent-skills'},
        callId: 'call_run_agent_skills_help',
      );

      expect(result['ok'], isTrue);
      expect(result['output'], contains('系统管理'));
      expect(result['output'], isNot(contains('options={')));
    });

    test('routes agent-rules create through Run subcommand', () async {
      final result = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'agent-rules',
          'subcommand': 'create',
          'options': {'name': '章节字数', 'content': '4000-5000 字'},
        },
        callId: 'call_run_agent_rules',
      );

      expect(result['ok'], isTrue);
      expect(result['command'], 'agent-rules create');
      expect(result['name'], '章节字数');
      expect(result['created'], isTrue);
      expect(result, isNot(contains('path')));
      expect(result['read_command'], {
        'tool': 'Run',
        'input': {
          'command': 'agent-rules',
          'subcommand': 'read',
          'options': {'name': '章节字数'},
        },
      });

      final rules = await db.agentRuleDao.getAll();
      expect(rules, hasLength(1));
      expect(rules.single.name, '章节字数');
      expect(rules.single.content, '4000-5000 字');
    });

    test('routes agent-rules read through Run subcommand', () async {
      await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'agent-rules',
          'subcommand': 'create',
          'options': {'name': '章节字数', 'content': '4000-5000 字'},
        },
        callId: 'call_run_agent_rules_create_for_read',
      );

      final result = await toolManager.executeTool(
        name: 'Run',
        input: {
          'command': 'agent-rules',
          'subcommand': 'read',
          'options': {'name': '章节字数'},
        },
        callId: 'call_run_agent_rules_read',
      );

      expect(result['ok'], isTrue);
      expect(result['command'], 'agent-rules read');
      expect(result['name'], '章节字数');
      expect(result['content'], '4000-5000 字');
      expect(result['enabled'], isTrue);
      expect(result, isNot(contains('path')));
      expect(result['hint'], contains('Run command=agent-rules'));
      expect(result['hint'], contains('subcommand=read'));
    });

    test(
      'agent rules reject Remove and remain deletable through Run',
      () async {
        for (final name in ['目标规则', '保留规则']) {
          await toolManager.executeTool(
            name: 'Run',
            input: {
              'command': 'agent-rules',
              'subcommand': 'create',
              'options': {'name': name, 'content': '规则内容'},
            },
          );
        }
        final before = (await db.select(db.agentRules).get())
            .map((rule) => rule.toJson())
            .toList();
        final rejected = await toolManager.executeTool(
          name: 'Remove',
          input: {'path': '.agents/rules/目标规则', 'force': true},
        );
        expect(rejected['error_code'], 'invalid_argument');
        expect(
          (await db.select(db.agentRules).get())
              .map((rule) => rule.toJson())
              .toList(),
          before,
        );
        expect(await db.select(db.workingChanges).get(), isEmpty);

        final deleted = await toolManager.executeTool(
          name: 'Run',
          input: {
            'command': 'agent-rules',
            'subcommand': 'delete',
            'options': {'name': '目标规则'},
          },
        );
        expect(deleted['ok'], isTrue);
        expect(deleted['deleted'], isTrue);
        expect(deleted['name'], '目标规则');
        expect((await db.agentRuleDao.getAll()).map((rule) => rule.name), [
          '保留规则',
        ]);
        expect(await db.select(db.workingChanges).get(), isEmpty);
      },
    );

    test('sessions forwards fresh execution context on every call', () async {
      final service = NovelContentService(db);
      final calls = <Map<String, dynamic>>[];
      final manager = AiToolManager(
        service,
        workingOverlayService: WorkingOverlayService(
          db,
          service,
          novelActionsService: NovelActionsService(appDb),
        ),
        sessionId: 'parent',
        sourceSessionId: 'old-source',
        sessionsCommandCallback:
            (action, options, {currentSessionId, sourceSessionId}) async {
              calls.add({
                'action': action,
                'options': options,
                'current': currentSessionId,
                'source': sourceSessionId,
              });
              return {
                'ok': true,
                'output': 'Returned 0 messages.',
                'data': {'items': []},
              };
            },
      )..registerAllTools();
      addTearDown(manager.dispose);
      for (final child in ['child-1', 'child-2']) {
        final result = await manager.executeTool(
          name: 'Run',
          input: {
            'command': 'sessions',
            'subcommand': 'read',
            'options': {'scope': 'current'},
          },
          context: ToolExecutionContext(
            sessionId: child,
            sourceSessionId: 'parent',
          ),
        );
        expect(result['ok'], true);
        expect(result['data'], {'items': []});
      }
      expect(calls.map((c) => c['current']), ['child-1', 'child-2']);
      expect(calls.map((c) => c['source']), ['parent', 'parent']);
      expect(calls.first['options'], {'scope': 'current'});
    });
    test(
      'sessions unavailable is explicit and history is an ordinary unknown command',
      () async {
        final missing = await toolManager.executeTool(
          name: 'Run',
          input: {'command': 'sessions', 'subcommand': 'list'},
        );
        expect(missing['error_code'], 'unavailable');
        final old = await toolManager.executeTool(
          name: 'Run',
          input: {'command': 'history', 'subcommand': 'search'},
        );
        expect(old['exit_code'], 127);
        expect(old['error'], 'unknown command: history');
      },
    );
    test(
      'sessions help publishes four commands and complete filtering contract',
      () async {
        final help = await toolManager.executeTool(
          name: 'Run',
          input: {'command': 'help', 'subcommand': 'sessions'},
        );
        expect(help['ok'], true);
        for (final token in [
          'list',
          'read',
          'search',
          'get',
          'source (default)',
          'current',
          'scope=work',
          'kinds',
          'max_chars',
          'next_cursor',
          'tool_status',
        ]) {
          expect(help['output'], contains(token));
        }
        expect(help['output'], isNot(contains('include-tool-results')));
      },
    );

    test('Run input schema keeps command fields at the top level', () {
      final runDef = toolManager.allToolDefs().singleWhere(
        (tool) => tool.name == 'Run',
      );

      expect(
        runDef.inputSchema['properties'],
        allOf(contains('command'), contains('subcommand'), contains('options')),
      );
    });
  });
}

/// ffmpeg execute 固定后台执行；拿到回执后等待同一 run 结束，同步命令原样返回。
Future<Map<String, dynamic>> _settled(
  ToolOperationManager operations,
  ToolExecutionContext context,
  Future<Map<String, dynamic>> response,
) async {
  final receipt = await response;
  final runId = receipt['run_id'];
  if (runId is! String || receipt['background'] != true) {
    return receipt;
  }
  return operations.wait(runId, context);
}
