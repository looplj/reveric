// 职责: 在桌面宿主以两次隔离容器启动验收视频参考、持久回执与自动恢复下载。
// 关联文件:
//   lib/shared/providers/video_tasks.dart
//   lib/shared/services/ai/video/task_service.dart
//   lib/shared/database/app_database.dart

import 'package:reveric/shared/models/production/media.dart';
import 'dart:convert';
import 'dart:io';
import '../test/fixtures/video_media.dart';
import '../test/helpers/fake_object_storage.dart';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/services/canvas_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/video_tasks.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/ai/video/task_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'two containers recover one paid task and download a fixed result',
    (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'reveric-video-integration-',
        );
        final dbFile = File('${root.path}/app.sqlite');
        final input = await File(
          '${root.path}/source.png',
        ).writeAsBytes(base64Decode(videoReferencePngBase64));
        var creates = 0;
        var uploads = 0;
        var queries = 0;
        ProviderContainer containerFor(
          AppDatabase db, {
          bool resumed = false,
        }) => ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            videoTaskServiceProvider.overrideWith((ref) async {
              final references = ReferenceStorageService(
                database: db,
                storage: FakeObjectStorage(
                  db,
                  ({
                    required file,
                    required sha256,
                    required mimeType,
                    required fileSize,
                  }) async {
                    uploads++;
                    return (
                      url: 'https://reference.test/input',
                      expiresAt: null,
                    );
                  },
                ),
                probe: (_) async => const MediaInfo(
                  duration: Duration.zero,
                  hasAudio: false,
                  hasVideo: true,
                  width: 320,
                  height: 320,
                ),
              );
              final service = VideoTaskService(
                probeResult: (_) async => const MediaInfo(
                  duration: Duration(seconds: 5),
                  hasAudio: true,
                  hasVideo: true,
                  width: 1280,
                  height: 720,
                ),

                database: db,
                rootDirectory: root,
                references: references,
                now: () =>
                    DateTime.now().add(Duration(seconds: resumed ? 11 : 0)),
                providerTransport: (_) => MockClient((r) async {
                  if (r.method == 'POST') {
                    creates++;
                    expect(
                      jsonDecode(r.body)['content'][1]['role'],
                      'reference_image',
                    );
                    return http.Response('{"id":"original-task"}', 200);
                  }
                  queries++;
                  expect(r.url.path, endsWith('/original-task'));
                  return http.Response(
                    '{"status":"succeeded","content":{"video_url":"https://result.test/video.mp4"}}',
                    200,
                  );
                }),
                downloadTransport: (_) => MockClient(
                  (_) async => http.Response.bytes(
                    base64Decode(videoResultMp4Base64),
                    200,
                  ),
                ),
              );
              ref.onDispose(service.dispose);
              await service.start();
              return service;
            }),
          ],
        );
        AppDatabase? database;
        ProviderContainer? container;
        NovelContentDatabase? content;
        try {
          database = AppDatabase.forTest(NativeDatabase(dbFile));
          final contentPath = '${root.path}/novel.sqlite';
          content = NovelContentDatabase.forTest(
            NativeDatabase(File(contentPath)),
          );
          await database
              .into(database.novels)
              .insert(
                NovelsCompanion.insert(
                  id: 'test-novel',
                  title: 'Fixture work',
                  description: '',
                  contentDatabasePath: Value(contentPath),
                ),
              );
          final canvas = CanvasService(content);
          final canvasId = await canvas.createCanvas(name: 'Fixture canvas');
          final sourceId = await canvas.addNode(
            canvasId: canvasId,
            type: canvasNodeTypeSticky,
            content: 'Source fixture',
            x: 0,
            y: 0,
          );
          // E1 exercises the generic source contract with an existing object;
          // B owns validating a production node or shot at its actual UI entry.
          expect(
            (await database.novelDao.get('test-novel'))!.contentDatabasePath,
            contentPath,
          );
          expect(
            (await content.canvasDao.getNodeById(sourceId))!.canvasId,
            canvasId,
          );
          final provider = aiProviderBuiltinById('doubao')!.copyWith(
            enabled: true,
            apiKey: 'mock-key',
            videoModels: ['doubao-seedance-2-5-260628'],
          );
          await database.aiProviderDao.upsert(provider);
          container = containerFor(database);
          final service = await container.read(videoTaskServiceProvider.future);
          expect(
            await container.read(videoTaskServiceProvider.future),
            same(service),
          );
          await database.assetDao.insertAsset(
            AssetsCompanion.insert(
              id: 'reference',
              type: 'image',
              purpose: 'upload',
              path: Value(input.path),
              content: const Value(ImageAssetContent(mimeType: 'image/png')),
            ),
          );
          final id = await service.create(
            novelId: 'test-novel',
            sourceType: 'canvas_node',
            sourceId: sourceId,
            id: 'container-restart',
            providerId: provider.id,
            request: const VideoRequest(
              modelId: 'doubao-seedance-2-5-260628',
              prompt: 'a bird',
              mode: VideoMode.reference,
              resolution: '720p',
              ratio: '16:9',
              audio: true,
            ),
            inputs: [
              VideoSourceInput(
                assetId: 'reference',
                file: input,
                role: VideoInputRole.reference_image,
                mimeType: 'image/png',
              ),
            ],
          );
          await service.submit(id, acknowledgeReferenceUpload: true);
          expect(
            (await service.getTask(id))!.status,
            GenerationTaskStatus.running,
          );
          await (content.update(content.canvasNodes)
                ..where((t) => t.id.equals(sourceId)))
              .write(CanvasNodesCompanion(deletedAt: Value(DateTime.now())));
          expect(await content.canvasDao.getNodeById(sourceId), isNull);
          await content.close();
          content = null;
          container.dispose();
          container = null;
          await database.close();
          database = null;
          database = AppDatabase.forTest(NativeDatabase(dbFile));
          container = containerFor(database, resumed: true);
          final restored = await container.read(
            videoTaskServiceProvider.future,
          );
          final task = (await restored.getTask(id))!;
          expect(task.status, GenerationTaskStatus.completed);
          expect(task.providerTaskId, 'original-task');
          expect(task.novelId, 'test-novel');
          expect(task.sourceType, 'canvas_node');
          expect(task.sourceId, sourceId);
          final asset = (await database.assetDao.getAsset(
            task.resultAssetId!,
          ))!;
          expect(asset.novelId, 'test-novel');
          expect(asset.path, task.path);
          expect(asset.type, 'video');
          expect(
            (await restored
                    .watchSource(
                      novelId: 'test-novel',
                      sourceType: 'canvas_node',
                      sourceId: sourceId,
                    )
                    .first)
                .single
                .id,
            id,
          );
          expect(creates, 1);
          expect(uploads, 1);
          expect(queries, 1);
          expect(
            await File('${root.path}/${task.path}').length(),
            base64Decode(videoResultMp4Base64).length,
          );
          expect(
            jsonEncode(task.requestJson.toJson()),
            isNot(contains('mock-key')),
          );
        } finally {
          container?.dispose();
          await database?.close();
          await content?.close();
          await root.delete(recursive: true);
        }
      });
    },
  );
}
