// 职责: 验证公开画布包只包含选定的有效会话和可展示的归档文件。
// 关联文件:
//   lib/shared/services/production/canvas_package.dart
//   lib/shared/services/production/canvas_package_conversations.dart
//   lib/shared/services/ai/session_persistence.dart

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/user_message_presentation.dart';
import 'package:reveric/shared/services/ai/files/session_files.dart';
import 'package:reveric/shared/services/ai/session_persistence.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/production/canvas_package.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/production/share_asset_orchestrator.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late AppDatabase app;
  late NovelContentDatabase db;
  late ProductionCanvasService canvas;
  late AiSessionPersistenceService persistence;
  late SessionFiles files;
  late String canvasId;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('canvas-chats-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? support.path
              : null,
        );
    await RevericPaths.initialize(fileWorkspaceParent: support.path);
    app = AppDatabase.forTest(NativeDatabase.memory());
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    await ScreenplayService(db).createCanvasStructure();
    final library = MediaLibraryService(
      app,
      MediaService(FfmpegRunner()),
      support,
    );
    canvas = ProductionCanvasService(
      StoryboardService(db, contentKind: contentKindCanvas),
      library,
      'work',
    );
    canvasId = (await db.select(db.canvases).get()).single.id;
    await canvas.addText(canvasId, title: 'Board', content: 'Notes');
    persistence = AiSessionPersistenceService(app, 'work');
    files = SessionFiles(novelId: 'work');
    await persistence.upsertSession(
      id: 'selected',
      title: '创作会话',
      model: 'visible-model',
      agentSlug: 'visible-agent',
      provider: 'private-provider',
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await db.close();
    await app.close();
    await support.delete(recursive: true);
  });

  Future<ProductionCanvasPackageFile> export(List<String> ids) async {
    final packaged = await const ProductionCanvasPackageOrchestrator()
        .exportToFile(
          canvas: canvas,
          canvasId: canvasId,
          title: 'Board',
          sessionPersistence: persistence,
          conversationIds: ids,
        );
    addTearDown(packaged.delete);
    return packaged;
  }

  test(
    'archives selected visible messages and resolves shared files into preview',
    () async {
      await persistence.upsertSession(
        id: 'unselected',
        title: 'Other conversation',
      );
      await persistence.upsertSession(
        id: 'child',
        title: 'Child',
        parentId: 'selected',
      );
      await persistence.upsertSession(
        id: 'mode',
        title: 'Special',
        mode: 'research',
      );
      await persistence.upsertSession(id: 'deleted', title: 'Deleted');
      await app.aiChatSessionDao.softDelete('deleted', novelId: 'work');
      final file = await files.allocate('selected', '.txt');
      await file.writeAsString('Shared text');
      final attachment = AiAttachmentBlock(
        id: 'a',
        name: '附注.txt',
        path: files.reference(file),
        mimeType: 'text/plain',
      );
      await persistence.saveMessages(
        sessionId: 'selected',
        novelDatabase: db,
        messages: [
          AiMessage.system(id: 'system', content: 'private-system'),
          AiMessage.user(
            id: 'reminder',
            content: 'private-reminder',
            type: AiMessageType.system_remind,
          ),
          AiMessage.user(
            id: 'user',
            content: 'First',
            blocks: [attachment, attachment.withPath(files.reference(file))],
          ),
          AiMessage.assistant(
            id: 'assistant',
            content: 'private-assistant-content',
            metadata: const {'runtime': 'private-metadata'},
            blocks: const [
              AiTextBlock(id: 'text', text: 'Second'),
              AiThinkingBlock(
                id: 'thinking',
                text: 'Reasoning',
                signature: 'private-signature',
              ),
              AiToolCallBlock(
                id: 'tool',
                callId: 'call',
                toolName: 'Read',
                status: AiToolCallStatus.success,
                arguments: {'path': 'private-argument'},
                result: {'path': 'private-result'},
              ),
            ],
          ),
        ],
      );
      final candidates = await listProductionCanvasPackageConversations(
        sessionPersistence: persistence,
        novelDatabase: db,
      );
      expect(
        candidates.map((item) => item.summary.id),
        unorderedEquals(['selected', 'unselected']),
      );
      final result = await export(['selected']);
      expect(result.conversationCount, 1);
      expect(result.conversationFileCount, 1);
      expect(result.conversationFileNames, ['附注.txt']);
      final zip = ZipDecoder().decodeBytes(await result.file.readAsBytes());
      final manifest = utf8.decode(zip.findFile('manifest.json')!.readBytes()!);
      final transcript = utf8.decode(
        zip.findFile('chats/1.json')!.readBytes()!,
      );
      expect(manifest, isNot(contains('private-provider')));
      expect(manifest, isNot(contains('unselected')));
      expect(transcript, isNot(contains('private-')));
      expect(transcript, isNot(contains('file_workspaces/')));

      final preview = await readProductionCanvasPackagePreview(result.file);
      addTearDown(preview.delete);
      final conversation = preview.conversations.single;
      expect(conversation.summary.model, 'visible-model');
      expect(conversation.summary.agentSlug, 'visible-agent');
      expect(conversation.messages.map((message) => message.content), [
        'First',
        'Second',
      ]);
      final attachments = conversation.messages.first.blocks
          .cast<AiAttachmentBlock>();
      expect(attachments.first.path, attachments.last.path);
      expect(await File(attachments.first.path).readAsString(), 'Shared text');
      expect(
        conversation.messages.last.blocks
            .whereType<AiToolCallBlock>()
            .single
            .arguments,
        isEmpty,
      );
    },
  );

  test(
    'shares only visible user text, chip labels and ordered attachments',
    () async {
      final source = await files.allocate('selected', '.txt');
      await source.writeAsString('visible file');
      await persistence.saveMessages(
        sessionId: 'selected',
        novelDatabase: db,
        messages: [
          AiMessage.user(
            id: 'explicit-handoff',
            content: '''
<session-handoff source-session-id="private-session-id" from-session-id="private-session-id" source-title="Earlier &amp; draft"/>
<user-remind type="session" path="ai-session:private-session-id" work-id="private-work-id" label="Earlier draft">private original history</user-remind>
<user-remind type="file" path="/Users/example/private-file" label="Notes &amp; images"><file-content>private original file</file-content></user-remind>
<user-remind type="docs" path="/Users/example/private-reference">private absent-label reference</user-remind>
Keep this comment.

## Summary
private model-only summary
''',
            metadata: const {
              'skill_names': ['Visible skill'],
              'subagent_names': ['Visible helper'],
              'runtime': 'private runtime',
            },
            blocks: [
              const AiTextBlock(
                id: 'before',
                text: '''
<user-remind type="selection" label="Excerpt"><selection-content>private selected text</selection-content></user-remind>
Keep this comment.
''',
              ),
              AiAttachmentBlock(
                id: 'file',
                name: 'Shared.txt',
                path: files.reference(source),
                mimeType: 'text/plain',
              ),
              const AiTextBlock(
                id: 'after',
                text: '''
Then add the notes.

## Next steps
private next steps
''',
              ),
            ],
          ),
          AiMessage.user(
            id: 'untitled-continuation',
            content: '''
<user-remind type="session" path="ai-session:private-session-id-two" work-id="private-work-id" label="private-session-id-two">private model-only continuation</user-remind>
Continue writing.
''',
          ),
          AiMessage.user(
            id: 'manual',
            content: '## Summary\nThe path example is /tmp/public-example.',
          ),
        ],
      );

      final result = await export(['selected']);
      final zip = ZipDecoder().decodeBytes(await result.file.readAsBytes());
      final json = utf8.decode(zip.findFile('chats/1.json')!.readBytes()!);
      expect(json, isNot(contains('private')));
      expect(json, isNot(contains('/Users/')));
      expect(json, contains('Visible skill'));
      expect(json, contains('Earlier &amp; draft'));
      expect(json, contains('Notes &amp; images'));

      final preview = await readProductionCanvasPackagePreview(result.file);
      addTearDown(preview.delete);
      final messages = preview.conversations.single.messages;
      final visible = parseUserMessagePresentation(messages.first.content);
      expect(visible.text, 'Keep this comment.');
      expect(visible.handoff?.sourceTitle, 'Earlier & draft');
      expect(visible.handoff?.sourceSessionId, isNull);
      expect(visible.references.single.label, 'Notes & images');
      expect(visible.references.single.path, isEmpty);
      expect(messages.first.metadata, {
        'skill_names': ['Visible skill'],
        'subagent_names': ['Visible helper'],
      });
      final blocks = messages.first.blocks;
      expect((blocks[0] as AiTextBlock).text, 'Keep this comment.');
      expect(
        await File((blocks[1] as AiAttachmentBlock).path).readAsString(),
        'visible file',
      );
      expect((blocks[2] as AiTextBlock).text, 'Then add the notes.');
      expect(messages[1].content, 'Continue writing.');
      expect(
        messages.last.content,
        '## Summary\nThe path example is /tmp/public-example.',
      );

      final candidates = await listProductionCanvasPackageConversations(
        sessionPersistence: persistence,
        novelDatabase: db,
      );
      expect(candidates.single.messages.first.content, 'Keep this comment.');
    },
  );

  test('reports an unavailable attachment with its session title', () async {
    await persistence.saveMessages(
      sessionId: 'selected',
      novelDatabase: db,
      messages: [
        AiMessage.user(
          id: 'missing',
          content: 'Missing file',
          blocks: const [
            AiAttachmentBlock(
              id: 'file',
              name: 'missing.txt',
              path: 'file_workspaces/work/sessions/selected/missing.txt',
              mimeType: 'text/plain',
            ),
          ],
        ),
      ],
    );
    await expectLater(
      export(['selected']),
      throwsA(
        isA<ProductionCanvasPackageException>()
            .having((error) => error.code, 'code', 'missing_conversation_file')
            .having((error) => error.subject, 'subject', '创作会话'),
      ),
    );
  });

  test('rechecks ownership and soft deletion when exporting', () async {
    final other = AiSessionPersistenceService(app, 'other');
    await other.upsertSession(id: 'another-work', title: 'Private');
    await app.aiChatSessionDao.softDelete('selected', novelId: 'work');
    for (final id in ['selected', 'another-work']) {
      await expectLater(
        export([id]),
        throwsA(
          isA<ProductionCanvasPackageException>().having(
            (error) => error.code,
            'code',
            'invalid_conversation',
          ),
        ),
      );
    }
  });

  test(
    'mounts an ephemeral read-only canvas when MediaService is provided',
    () async {
      final imageNode = await canvas.addImage(canvasId);
      final clipId = imageNode.clipId!;
      final clip = (await canvas.shots.getShot(clipId))!;
      final values = canvas.shots.snapshot(clip)
        ..['title'] = 'Hero shot'
        ..['prompt'] = 'Warm morning light over misty lake'
        ..['provider_id'] = 'prov-1'
        ..['model_id'] = 'imagen-4'
        ..['ratio'] = '16:9';
      await canvas.shots.apply(clipId, values);

      final result = await const ProductionCanvasPackageOrchestrator()
          .exportToFile(
            canvas: canvas,
            canvasId: canvasId,
            title: 'Board',
            publicGallery: true,
            sessionPersistence: persistence,
          );
      addTearDown(result.delete);
      final preview = await readProductionCanvasPackagePreview(
        result.file,
        media: MediaService(FfmpegRunner()),
      );
      try {
        expect(preview.canvas, isNotNull);
        expect(preview.canvasId, isNotNull);
        final content = await preview.canvas!.content(preview.canvasId!);
        expect(content.nodes.length, 2);
        final mountedImage = content.nodes.firstWhere(
          (node) => node.type == canvasNodeTypeImage,
        );
        final generation = preview.generationsByNodeId[mountedImage.id];
        expect(generation, isNotNull);
        expect(generation!.model, 'imagen-4');
        expect(generation.parameters['ratio'], '16:9');
      } finally {
        await preview.delete();
      }
    },
  );

  test(
    'exports shared references once and imports directly from cache',
    () async {
      await app.novelDao.create(
        id: 'other',
        title: 'Other work',
        description: '',
      );
      final png = File(p.join(support.path, 'sample.png'));
      await png.writeAsBytes(img.encodePng(img.Image(width: 8, height: 6)));
      final imported = await canvas.library.importFile(
        png,
        name: 'sample.png',
        novelId: 'other',
        purpose: AssetPurpose.production_upload,
        cancellation: MediaCancellation(),
        addToLibrary: true,
      );
      await persistence.saveMessages(
        sessionId: 'selected',
        novelDatabase: db,
        messages: [
          AiMessage.assistant(
            id: 'img-msg',
            content: 'Generated',
            blocks: [
              AiImageBlock(
                id: 'img-1',
                prompt: 'A landscape',
                toolName: 'GeneratePhoto',
                status: AiImageStatus.success,
                assetId: imported.id,
              ),
            ],
          ),
        ],
      );

      await expectLater(
        export(['selected']),
        throwsA(
          isA<ProductionCanvasPackageException>().having(
            (error) => error.code,
            'code',
            'missing_conversation_file',
          ),
        ),
      );
      final shared = await ShareAssetOrchestrator().run(
        library: canvas.library,
        assetId: imported.id,
        sourceNovelId: 'other',
      );
      await canvas.addMedia(canvasId, shared.id);
      final packaged = await export(['selected']);
      final cacheDir = Directory(p.join(support.path, 'persistent_cache'));
      final media = MediaService(FfmpegRunner());
      await prepareProductionCanvasPackageCache(
        packaged.file,
        cacheDir,
        media: media,
      );
      // 删掉原始 zip，验证后续打开和导入完全不依赖压缩包。
      await packaged.delete();

      // 原始 media/ 已清理，磁盘只留 workspace/file_workspaces 中的一份。
      expect(await Directory(p.join(cacheDir.path, 'media')).exists(), isFalse);
      expect(
        await File(
          p.join(cacheDir.path, canvasGalleryCacheReadyMarker),
        ).exists(),
        isTrue,
      );

      final preview = await openProductionCanvasPackageCache(
        cacheDir,
        media: media,
      );
      try {
        expect(preview.canvas, isNotNull);
        final content = await preview.canvas!.content(preview.canvasId!);
        expect(content.nodes.length, 2);
        final imageBlock =
            preview.conversations.single.messages.single.blocks.single
                as AiImageBlock;
        expect(imageBlock.localFilePath, isNotNull);
        expect(await File(imageBlock.localFilePath!).exists(), isTrue);
      } finally {
        await preview.close();
      }
      expect(await cacheDir.exists(), isTrue);

      final actions = NovelActionsService(app);
      final result = await const ProductionCanvasPackageOrchestrator()
          .importFromCacheDirectory(
            cacheDirectory: cacheDir,
            actions: actions,
            library: canvas.library,
            fallbackTitle: 'Fallback',
            openContent: NovelContentDatabase.new,
            releaseContent: (database) => database.close(),
          );
      expect(result.novelId, isNotEmpty);
      final createdNovel = await actions.getNovel(result.novelId);
      expect(createdNovel?.contentDatabasePath, isNotNull);
      final openedDb = NovelContentDatabase(createdNovel!.contentDatabasePath!);
      addTearDown(openedDb.close);
      final importedContent = await ProductionCanvasService(
        StoryboardService(openedDb, contentKind: contentKindCanvas),
        canvas.library,
        result.novelId,
      ).content((await openedDb.select(openedDb.canvases).get()).single.id);
      expect(importedContent.nodes.length, 2);
    },
  );
}
