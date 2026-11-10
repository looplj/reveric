// 职责: 验证渠道上传落库、跨服务复用、OSS 选路、并发与中断恢复。
// 关联文件:
//   lib/shared/services/ai/video/reference_storage_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/services/ai/video/task_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/provider_asset.dart';
import 'package:reveric/shared/models/object_storage_config.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/object_storage/service.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';

import '../../../../helpers/fake_object_storage.dart';

void main() {
  late AppDatabase db;
  late Directory dir;
  late File file;
  late int posts;
  final provider = aiProviderBuiltinById('api88')!.copyWith(apiKey: 'secret');
  const input = VideoInput(
    role: VideoInputRole.reference_image,
    assetId: 'a',
    mimeType: 'image/png',
  );
  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    await db.aiProviderDao.upsert(provider);
    dir = await Directory.systemTemp.createTemp('reference-upload');
    file = await File('${dir.path}/a').writeAsBytes([1, 2, 3]);
    posts = 0;
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  ReferenceStorageService service({
    bool fail = false,
    ReferenceUploader? oss,
  }) => ReferenceStorageService(
    database: db,
    storage: oss == null
        ? ObjectStorageService(database: db)
        : FakeObjectStorage(db, oss),
    probe: (_) async => const MediaInfo(
      duration: Duration.zero,
      hasAudio: false,
      hasVideo: true,
      width: 1280,
      height: 720,
    ),
    uploadClient: (_) => MockClient((request) async {
      final row = await db.providerAssetDao.find(
        'a',
        provider.id,
        kind: ProviderAssetKind.upload,
      );
      expect(row!.status, ProviderAssetStatus.processing);
      expect(row.remoteUrl, isNull);
      if (request.method == 'POST') {
        posts++;
        if (fail) {
          return http.Response('{}', 401);
        }
        return http.Response(
          jsonEncode({
            'url': 'https://read.example/a',
            'upload_url': 'https://write.example/a',
            'method': 'PUT',
            'headers': {
              'Content-Type': 'image/png',
              'X-Media-Upload-Token': 't',
            },
            'expires_at':
                DateTime.now()
                    .add(const Duration(minutes: 10))
                    .millisecondsSinceEpoch ~/
                1000,
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'url': 'https://read.example/a',
          'size': 3,
          'mime_type': 'image/png',
          'expires_at':
              DateTime.now()
                  .add(const Duration(days: 30))
                  .millisecondsSinceEpoch ~/
              1000,
        }),
        201,
      );
    }),
  );
  for (final fail in [false, true]) {
    test(
      '88API generation waits for persisted upload, failure=$fail',
      () async {
        const model = 'seedance-2.0';
        await db.aiProviderDao.upsert(
          provider.copyWith(enabled: true, videoModels: [model]),
        );
        await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                id: 'a',
                type: 'image',
                purpose: 'production_output',
                path: const Value('a'),
              ),
            );
        final references = service(fail: fail);
        var generated = 0;
        final tasks = VideoTaskService(
          database: db,
          rootDirectory: dir,
          references: references,
          probeResult: (_) async => const MediaInfo(
            duration: Duration.zero,
            hasAudio: false,
            hasVideo: true,
            width: 1280,
            height: 720,
          ),
          providerTransport: (_) => MockClient((request) async {
            generated++;
            expect(
              (await db.providerAssetDao.find(
                'a',
                provider.id,
                kind: ProviderAssetKind.upload,
              ))!.status,
              ProviderAssetStatus.active,
            );
            expect(request.body, contains('https://read.example/a'));
            return http.Response('{"id":"generated"}', 200);
          }),
        );
        addTearDown(tasks.dispose);
        addTearDown(references.dispose);
        final id = await tasks.create(
          providerId: provider.id,
          novelId: 'work',
          sourceType: 'production_clip',
          sourceId: 'clip',
          request: const VideoRequest(
            modelId: model,
            prompt: 'A bird',
            mode: VideoMode.first_frame,
            resolution: '720p',
            ratio: '16:9',
            audio: true,
          ),
          inputs: [
            VideoSourceInput(
              file: file,
              assetId: 'a',
              role: VideoInputRole.first_frame,
              mimeType: 'image/png',
            ),
          ],
        );
        final submit = tasks.submit(id, acknowledgeReferenceUpload: true);
        if (fail) {
          await expectLater(submit, throwsA(isA<VideoException>()));
        } else {
          await submit;
        }
        expect(generated, fail ? 0 : 1);
        expect(posts, 1);
      },
    );
  }
  test(
    'no storage sends inline references only in generation payload',
    () async {
      final inlineProvider = provider.copyWith(
        type: 'volcengine',
        enabled: true,
        videoModels: ['doubao-seedance-2-0-260128'],
      );
      await db.aiProviderDao.upsert(inlineProvider);
      await db
          .into(db.assets)
          .insert(
            AssetsCompanion.insert(
              id: 'a',
              type: 'image',
              purpose: 'production_output',
              path: const Value('a'),
            ),
          );
      final references = ReferenceStorageService(
        database: db,
        storage: ObjectStorageService(database: db),
        probe: (_) async => const MediaInfo(
          duration: Duration.zero,
          hasAudio: false,
          hasVideo: true,
          width: 1280,
          height: 720,
        ),
        uploadClient: (_) => throw StateError('unexpected upload'),
      );
      var generations = 0;
      final tasks = VideoTaskService(
        database: db,
        rootDirectory: dir,
        references: references,
        probeResult: (_) async => const MediaInfo(
          duration: Duration.zero,
          hasAudio: false,
          hasVideo: true,
          width: 1280,
          height: 720,
        ),
        providerTransport: (_) => MockClient((r) async {
          generations++;
          expect(r.body, contains('data:image/png;base64,AQID'));
          expect(
            await db.providerAssetDao.find(
              'a',
              inlineProvider.id,
              kind: ProviderAssetKind.upload,
            ),
            isNull,
          );
          return http.Response('{"id":"generated"}', 200);
        }),
      );
      addTearDown(tasks.dispose);
      addTearDown(references.dispose);
      final id = await tasks.create(
        providerId: inlineProvider.id,
        novelId: 'work',
        sourceType: 'production_clip',
        sourceId: 'clip',
        request: const VideoRequest(
          modelId: 'doubao-seedance-2-0-260128',
          prompt: 'Bird',
          mode: VideoMode.first_frame,
          resolution: '720p',
          ratio: '16:9',
          audio: true,
        ),
        inputs: [
          VideoSourceInput(
            file: file,
            assetId: 'a',
            role: VideoInputRole.first_frame,
            mimeType: 'image/png',
          ),
        ],
      );
      await tasks.submit(id, acknowledgeReferenceUpload: true);
      expect(generations, 1);
      final task = (await tasks.getTask(id))!;
      expect(jsonEncode(task.videoRequest.toJson()), isNot(contains('base64')));
      expect(
        jsonEncode(task.videoInputs.map((e) => e.toJson()).toList()),
        isNot(contains('base64')),
      );
    },
  );
  test('cleared OSS allows a fresh reference to use 88API', () async {
    final oss = ObjectStorageService(database: db);
    await oss.save(
      const ObjectStorageConfig(
        endpoint: 'https://s3.example.com',
        bucket: 'media',
        accessKeyId: 'ak',
        secretAccessKey: 'sk',
      ),
    );
    await oss.clear();
    final storage = service();
    expect(
      await storage.preflight(providerId: provider.id, inputs: [input]),
      isTrue,
    );
    expect(
      (await storage.ensure(input, file, provider: provider)).url,
      'https://read.example/a',
    );
    expect(posts, 1);
  });

  test(
    'concurrent upload persists once but broken OSS blocks cached references',
    () async {
      final storage = service();
      await Future.wait([
        storage.ensure(input, file, provider: provider),
        storage.ensure(input, file, provider: provider),
      ]);
      expect(posts, 1);
      await db.appSettingsDao.set(
        key: ObjectStorageConfig.appSettingsKey,
        value: 'broken',
      );
      await expectLater(
        service().preflight(providerId: provider.id, inputs: [input]),
        throwsA(isA<VideoException>()),
      );
      await expectLater(
        service().ensure(input, file, provider: provider),
        throwsA(isA<VideoException>()),
      );
      expect(posts, 1);
      expect(await db.providerAssetDao.watchByAssets(['a']).first, isEmpty);
      expect(
        (await db.providerAssetDao.find(
          'a',
          provider.id,
          kind: ProviderAssetKind.upload,
        ))!.status,
        ProviderAssetStatus.active,
      );
    },
  );
  test('OSS takes priority even with a cached channel upload', () async {
    var uploads = 0;
    final storage = service(
      oss:
          ({
            required file,
            required sha256,
            required mimeType,
            required fileSize,
          }) async {
            uploads++;
            return (url: 'https://oss.example/a', expiresAt: null);
          },
    );
    expect(
      (await storage.ensure(input, file, provider: provider)).url,
      'https://oss.example/a',
    );
    expect(posts, 0);
    expect(uploads, 1);
    await service().ensure(input, file, provider: provider);
    expect(
      (await storage.ensure(input, file, provider: provider)).url,
      'https://oss.example/a',
    );
    expect(uploads, 2);
    expect(posts, 1);
  });
  test('failed uploads stay failed and retries use the same row', () async {
    await expectLater(
      service(fail: true).ensure(input, file, provider: provider),
      throwsA(isA<VideoException>()),
    );
    final failed = (await db.providerAssetDao.find(
      'a',
      provider.id,
      kind: ProviderAssetKind.upload,
    ))!;
    expect(failed.status, ProviderAssetStatus.failed);
    expect(failed.remoteUrl, isNull);
    await service().ensure(input, file, provider: provider);
    final active = (await db.providerAssetDao.find(
      'a',
      provider.id,
      kind: ProviderAssetKind.upload,
    ))!;
    expect(active.id, failed.id);
    expect(active.status, ProviderAssetStatus.active);
  });
  test(
    'key changes do not reuse old results, interrupted uploads never recover remotely',
    () async {
      await service().ensure(input, file, provider: provider);
      await service().ensure(
        input,
        file,
        provider: provider.copyWith(apiKey: 'changed'),
      );
      expect(posts, 2);
      final row = await db.providerAssetDao.start(
        'a',
        provider.id,
        kind: ProviderAssetKind.upload,
      );
      await service().resume();
      final stopped = (await db.providerAssetDao.find(
        'a',
        provider.id,
        kind: ProviderAssetKind.upload,
      ))!;
      expect(stopped.id, row.id);
      expect(stopped.errorCode, 'interrupted');
      expect(posts, 2);
    },
  );
  for (final raw in [
    null,
    const ObjectStorageConfig().encode(),
    '{}',
    'broken',
    jsonEncode({'endpoint': 123}),
    const ObjectStorageConfig(bucket: 'partial').encode(),
  ]) {
    test('preflight classifies OSS $raw', () async {
      if (raw != null) {
        await db.appSettingsDao.set(
          key: ObjectStorageConfig.appSettingsKey,
          value: raw,
        );
      }
      final check = service().preflight(
        providerId: provider.id,
        inputs: [input],
      );
      if (raw == null || raw == const ObjectStorageConfig().encode()) {
        expect(await check, isTrue);
      } else {
        await expectLater(check, throwsA(isA<VideoException>()));
      }
      expect(posts, 0);
    });
  }
}
