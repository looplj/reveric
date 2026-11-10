// 职责: 验证 Purefox 预签名上传、凭据隔离、key 落库和到期复用。
// 关联文件:
//   lib/shared/services/ai/uploads/purefox.dart
//   lib/shared/services/ai/video/reference_storage_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/provider_asset.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/uploads/purefox.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/object_storage/service.dart';

void main() {
  late AppDatabase db;
  late Directory dir;
  late File file;
  final provider = aiProviderBuiltinById(
    'purefox_media',
  )!.copyWith(apiKey: 'key');
  const input = VideoInput(
    role: VideoInputRole.reference_image,
    assetId: 'a',
    mimeType: 'image/png',
  );
  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('purefox-upload-');
    file = await File('${dir.path}/a.png').writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  for (final mode in [
    'success',
    'apply_error',
    'missing_key',
    'bad_url',
    'put_error',
    'disconnect',
  ]) {
    test(mode, () async {
      final methods = <String>[];
      final storage = ReferenceStorageService(
        database: db,
        storage: ObjectStorageService(database: db),
        probe: (_) async => const MediaInfo(
          duration: Duration.zero,
          hasAudio: false,
          hasVideo: true,
          width: 1280,
          height: 720,
        ),
        uploadClient: (_) => MockClient((r) async {
          methods.add(r.method);
          final row = (await db.providerAssetDao.find(
            'a',
            provider.id,
            kind: ProviderAssetKind.upload,
          ))!;
          expect(row.status, ProviderAssetStatus.processing);
          expect(row.remoteId, isNull);
          expect(row.remoteUrl, isNull);
          expect(r.followRedirects, isFalse);
          if (r.method == 'POST') {
            expect(r.url.toString(), 'https://img.purefox.org/v1/uploads');
            expect(r.headers['Authorization'], 'Bearer key');
            expect(jsonDecode(r.body), {'kind': 'image', 'mime': 'image/png'});
            return http.Response(
              jsonEncode({
                if (mode != 'missing_key') 'key': 'uploads/AbC.png',
                'url': mode == 'bad_url'
                    ? 'file:///a'
                    : 'https://storage.example/put?signature=secret',
              }),
              mode == 'apply_error' ? 401 : 200,
            );
          }
          expect(r.method, 'PUT');
          expect(r.url.host, 'storage.example');
          expect(r.headers['Authorization'], isNull);
          expect(r.headers['Content-Type'], 'image/png');
          expect(r.contentLength, 3);
          expect(r.bodyBytes, [1, 2, 3]);
          if (mode == 'disconnect') {
            throw http.ClientException('disconnected');
          }
          return http.Response('', mode == 'put_error' ? 403 : 204);
        }),
      );
      final start = DateTime.now();
      final pending = storage.ensure(input, file, provider: provider);
      if (mode == 'success') {
        expect((await pending).url, 'uploads/AbC.png');
        final row = (await db.providerAssetDao.find(
          'a',
          provider.id,
          kind: ProviderAssetKind.upload,
        ))!;
        expect(row.remoteId, 'uploads/AbC.png');
        expect(row.remoteUrl, isNull);
        expect(row.status, ProviderAssetStatus.active);
        expect(
          row.expiresAt!.difference(start).inMinutes,
          inInclusiveRange(29, 30),
        );
        await storage.ensure(input, file, provider: provider);
        expect(methods, ['POST', 'PUT']);
        expect(await db.providerAssetDao.watchByAssets(['a']).first, isEmpty);
        await db.providerAssetDao.write(
          row.id,
          ProviderAssetsCompanion(expiresAt: Value(DateTime.utc(2000))),
        );
        await storage.ensure(input, file, provider: provider);
        expect(methods, ['POST', 'PUT', 'POST', 'PUT']);
      } else {
        await expectLater(pending, throwsA(isA<VideoException>()));
        final row = (await db.providerAssetDao.find(
          'a',
          provider.id,
          kind: ProviderAssetKind.upload,
        ))!;
        expect(row.status, ProviderAssetStatus.failed);
        expect(row.remoteId, isNull);
        expect(row.remoteUrl, isNull);
        expect(methods, [
          'POST',
          if (['put_error', 'disconnect'].contains(mode)) 'PUT',
        ]);
      }
      storage.dispose();
    });
  }
  test('media limits and channel capability are explicit', () {
    expect(aiProviderBuiltinById('purefox')!.typeConfig.uploadProtocol, isNull);
    for (final (mime, size) in [
      ('image/png', 20 * 1024 * 1024 + 1),
      ('audio/mpeg', 25 * 1024 * 1024 + 1),
      ('video/mp4', 64 * 1024 * 1024 + 1),
      ('image/gif', 1),
      ('image/png', 0),
    ]) {
      expect(
        () => PurefoxUploadOrchestrator.validate(provider, mime, size),
        throwsA(isA<VideoException>()),
      );
    }
  });
}
