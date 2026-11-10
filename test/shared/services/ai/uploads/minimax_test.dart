// 职责: 验证秘塔上传协议、原始文件 ID、持久化复用和生成提交顺序。
// 关联文件:
//   lib/shared/services/ai/uploads/minimax.dart
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
import 'package:reveric/shared/services/ai/uploads/minimax.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/ai/video/task_service.dart';
import 'package:reveric/shared/services/object_storage/service.dart';

void main() {
  late Directory dir;
  late File file;
  late AppDatabase db;
  final provider = aiProviderBuiltinById(
    'metaso',
  )!.copyWith(apiKey: 'key', enabled: true, videoModels: ['MiniMax-H3']);
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
    dir = await Directory.systemTemp.createTemp('metaso-upload-');
    file = await File('${dir.path}/reference.png').writeAsBytes([1, 2, 3]);
    db = AppDatabase.forTest(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  for (final (body, expected) in <(String, String?)>[
    ('{"file":{"file_id":9007199254740993}}', 'mm_file://9007199254740993'),
    (
      '{"file":{"file_id":"AbC_123","download_url":"https://example.com/a"},"base_resp":{"status_code":0}}',
      'mm_file://AbC_123',
    ),
    (
      '{"file":{"file_id":"","download_url":"https://example.com/a"}}',
      'https://example.com/a',
    ),
    ('{"file":{"file_id":1.5}}', null),
    ('{"file":{"download_url":"file:///tmp/a"}}', null),
    ('{"base_resp":{"status_code":1004},"file":{"file_id":"x"}}', null),
    ('{"file":{}}', null),
    ('not json', null),
  ]) {
    test('upload receipt $body', () async {
      final client = MockClient((r) async {
        expect(r.method, 'POST');
        expect(
          r.url.toString(),
          'https://metaso.cn/api/minimax/v1/files/upload',
        );
        expect(r.headers['Authorization'], 'Bearer key');
        expect(r.followRedirects, isFalse);
        expect(r.headers['content-type'], startsWith('multipart/form-data;'));
        expect(r.body, contains('name="purpose"'));
        expect(r.body, contains('video_generation_input'));
        expect(r.body, contains('filename="reference.png"'));
        expect(r.body, contains('application/octet-stream'));
        expect(r.body, contains(String.fromCharCodes([1, 2, 3])));
        return http.Response(body, 200);
      });
      final result = MinimaxUploadOrchestrator().run(
        provider: provider,
        file: file,
        mimeType: 'image/png',
        client: client,
      );
      if (expected == null) {
        await expectLater(result, throwsA(isA<VideoException>()));
      } else {
        expect((await result).url, expected);
      }
      client.close();
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
                  ? '{"base_resp":{"status_code":1004}}'
                  : '{"file":{"file_id":"AbC_123"}}',
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
            expect(row.remoteId, 'AbC_123');
            expect(row.remoteUrl, isNull);
            expect(r.body, contains('mm_file://AbC_123'));
            return http.Response('{"task_id":"task"}', 200);
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
            modelId: 'MiniMax-H3',
            prompt: 'Bird',
            mode: VideoMode.reference,
            resolution: '768P',
            ratio: '16:9',
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
            'mm_file://AbC_123',
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
}
