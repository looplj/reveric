// 职责: 验证 AtlasCloud 上传协议、临时链接复用和生成提交顺序。
// 关联文件:
//   lib/shared/services/ai/uploads/atlascloud.dart
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/services/ai/video/task_service.dart
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/provider_asset.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/uploads/atlascloud.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/ai/video/task_service.dart';
import 'package:reveric/shared/services/object_storage/service.dart';

import '../../../../helpers/fake_object_storage.dart';

void main() {
  late Directory dir;
  late File file;
  late AppDatabase db;
  final provider = aiProviderBuiltinById('openai')!.copyWith(
    type: 'atlascloud',
    apiKey: 'key',
    enabled: true,
    videoModels: ['bytedance/seedance-2.0'],
  );
  const input = VideoInput(
    role: VideoInputRole.reference_image,
    assetId: 'a',
    mimeType: 'image/png',
  );
  const media = MediaInfo(
    duration: Duration.zero,
    width: 1280,
    height: 720,
    hasVideo: true,
    hasAudio: false,
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('atlascloud-upload-');
    file = await File('${dir.path}/reference.png').writeAsBytes([1, 2, 3]);
    db = AppDatabase.forTest(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  for (final (body, expected) in <(String, String?)>[
    (
      '{"code":200,"data":{"download_url":"https://media.example/a"}}',
      'https://media.example/a',
    ),
    (
      '{"data":{"download_url":"https://media.example/a"}}',
      'https://media.example/a',
    ),
    ('{"code":400,"data":{"download_url":"https://media.example/a"}}', null),
    ('{"data":{"download_url":"file:///tmp/a"}}', null),
    ('{"data":{"download_url":"https://user:pass@example.com/a"}}', null),
    ('{"data":{}}', null),
    ('not json', null),
  ]) {
    test('upload receipt $body', () async {
      final client = MockClient((r) async {
        expect(r.method, 'POST');
        expect(
          r.url.toString(),
          'https://api.atlascloud.ai/api/v1/model/uploadMedia',
        );
        expect(r.headers['Authorization'], 'Bearer key');
        expect(r.followRedirects, isFalse);
        expect(r.headers['content-type'], startsWith('multipart/form-data;'));
        expect(r.body, contains('name="file"'));
        expect(r.body, contains('filename="reference.png"'));
        expect(r.body, contains(String.fromCharCodes([1, 2, 3])));
        return http.Response(body, 200);
      });
      addTearDown(client.close);
      final result = AtlasCloudUploadOrchestrator().run(
        provider: provider,
        file: file,
        mimeType: 'image/png',
        client: client,
      );
      if (expected == null) {
        await expectLater(result, throwsA(isA<VideoException>()));
      } else {
        final uploaded = await result;
        expect(uploaded.url, expected);
        expect(uploaded.expiresAt, isNull);
      }
    });
  }

  for (final fail in [false, true]) {
    test(
      'persists before generation and reuses records, failure=$fail',
      () async {
        var uploads = 0;
        var generations = 0;
        ReferenceStorageService references() => ReferenceStorageService(
          database: db,
          storage: ObjectStorageService(database: db),
          probe: (_) async => media,
          uploadClient: (_) => MockClient((r) async {
            if (r.method == 'HEAD') {
              expect(r.headers['Authorization'], isNull);
              return http.Response('', 200);
            }
            uploads++;
            final row = (await db.providerAssetDao.find(
              'a',
              provider.id,
              kind: ProviderAssetKind.upload,
            ))!;
            expect(row.status, ProviderAssetStatus.processing);
            expect(row.remoteId, isNull);
            expect(row.remoteUrl, isNull);
            return http.Response(
              fail
                  ? '{"code":400}'
                  : '{"code":200,"data":{"download_url":"https://media.example/a"}}',
              200,
            );
          }),
        );
        final storage = references();
        await db.aiProviderDao.upsert(provider);
        await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                id: 'a',
                type: 'image',
                purpose: 'production_output',
                path: const Value('reference.png'),
              ),
            );
        final tasks = VideoTaskService(
          database: db,
          rootDirectory: dir,
          references: storage,
          probeResult: (_) async => media,
          providerTransport: (_) => MockClient((r) async {
            generations++;
            final row = (await db.providerAssetDao.find(
              'a',
              provider.id,
              kind: ProviderAssetKind.upload,
            ))!;
            expect(row.status, ProviderAssetStatus.active);
            expect(row.remoteId, isNull);
            expect(row.remoteUrl, 'https://media.example/a');
            expect(row.expiresAt, isNull);
            expect(r.body, contains('https://media.example/a'));
            return http.Response('{"data":{"id":"task"}}', 200);
          }),
        );
        addTearDown(tasks.dispose);
        addTearDown(storage.dispose);
        final id = await tasks.create(
          providerId: provider.id,
          novelId: 'work',
          sourceType: 'production_clip',
          sourceId: 'clip',
          request: const VideoRequest(
            modelId: 'bytedance/seedance-2.0',
            prompt: 'Bird',
            mode: VideoMode.reference,
            resolution: '720p',
            ratio: '16:9',
            audio: true,
          ),
          inputs: [
            VideoSourceInput(
              file: file,
              assetId: 'a',
              role: input.role,
              mimeType: input.mimeType,
            ),
          ],
        );
        final submitted = tasks.submit(id, acknowledgeReferenceUpload: true);
        if (fail) {
          await expectLater(submitted, throwsA(isA<VideoException>()));
          expect(generations, 0);
          expect(
            (await db.providerAssetDao.find(
              'a',
              provider.id,
              kind: ProviderAssetKind.upload,
            ))!.status,
            ProviderAssetStatus.failed,
          );
        } else {
          await submitted;
          expect(generations, 1);
          expect(
            (await references().ensure(input, file, provider: provider)).url,
            'https://media.example/a',
          );
          expect(uploads, 1);
          expect(await db.providerAssetDao.watchByAssets(['a']).first, isEmpty);
          await references().ensure(
            input,
            file,
            provider: provider.copyWith(apiKey: 'new-key'),
          );
          expect(uploads, 2);
        }
      },
    );
  }

  for (final status in [200, 404, 410, 403, 500, -1]) {
    test('cached URL is checked before reuse: $status', () async {
      var uploads = 0;
      var headStatus = 200;
      final storage = ReferenceStorageService(
        database: db,
        storage: ObjectStorageService(database: db),
        probe: (_) async => media,
        uploadClient: (_) => MockClient((request) async {
          if (request.method == 'HEAD') {
            expect(request.headers['Authorization'], isNull);
            expect(request.followRedirects, isFalse);
            if (headStatus == -1) {
              throw http.ClientException('disconnected');
            }
            return http.Response('', headStatus);
          }
          uploads++;
          return http.Response(
            '{"data":{"download_url":"https://media.example/$uploads"}}',
            200,
          );
        }),
      );
      addTearDown(storage.dispose);
      await storage.ensure(input, file, provider: provider);
      headStatus = status;
      final pending = storage.ensure(input, file, provider: provider);
      if ([403, 500, -1].contains(status)) {
        await expectLater(pending, throwsA(isA<VideoException>()));
        expect(uploads, 1);
      } else {
        final expected = status == 200 ? 1 : 2;
        expect((await pending).url, 'https://media.example/$expected');
        expect(uploads, expected);
      }
    });
  }

  test(
    'configured OSS takes priority for a new AtlasCloud reference',
    () async {
      final storage = ReferenceStorageService(
        database: db,
        probe: (_) async => media,
        storage: FakeObjectStorage(
          db,
          ({
            required file,
            required sha256,
            required mimeType,
            required fileSize,
          }) async => (url: 'https://oss.example/a', expiresAt: null),
        ),
        uploadClient: (_) => throw StateError('unexpected channel upload'),
      );
      addTearDown(storage.dispose);
      expect(
        (await storage.ensure(input, file, provider: provider)).url,
        'https://oss.example/a',
      );
      expect(
        await db.providerAssetDao.find(
          'a',
          provider.id,
          kind: ProviderAssetKind.upload,
        ),
        isNull,
      );
    },
  );
}
