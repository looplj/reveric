// 职责: 验证对象存储配置的保存校验、按内容哈希去重上传、访问地址形态与连接测试的失败映射。
// 关联文件:
//   lib/shared/services/object_storage/service.dart
//   lib/shared/models/object_storage_config.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/object_storage_config.dart';
import 'package:reveric/shared/services/object_storage/service.dart';

void main() {
  late AppDatabase database;
  late Directory directory;
  late File file;
  final now = DateTime.utc(2026, 1, 1);
  const config = ObjectStorageConfig(
    endpoint: 'https://s3.example.com/',
    region: 'us-east-1',
    bucket: 'media',
    accessKeyId: 'ak',
    secretAccessKey: 'sk',
    keyPrefix: '/refs/',
  );
  const hash =
      '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81';

  setUp(() async {
    database = AppDatabase.forTest(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('object-storage-');
    file = await File('${directory.path}/input.png').writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  ObjectStorageService service(
    Future<http.Response> Function(http.Request) handler,
  ) => ObjectStorageService(
    database: database,
    client: () => MockClient(handler),
    now: () => now,
  );

  test('saves a normalized config and rejects incomplete ones', () async {
    final storage = service((_) async => http.Response('', 200));

    expect(await storage.load(), isA<ObjectStorageConfig>());
    expect((await storage.load()).isConfigured, isFalse);
    await expectLater(
      storage.save(const ObjectStorageConfig(endpoint: 'https://s3.example')),
      throwsArgumentError,
    );

    await storage.save(config);
    final saved = await storage.load();
    expect(saved.isConfigured, isTrue);
    expect(saved.endpoint, 'https://s3.example.com');
    expect(saved.keyPrefix, 'refs');
    expect(saved.secretAccessKey, 'sk');
  });

  test(
    'clearing removes credentials, not files or upload records, and emits empty config',
    () async {
      final storage = service(
        (_) async => throw StateError('must not access network'),
      );
      await storage.save(config);
      final certification = await database.providerAssetDao.start(
        'asset',
        'provider',
      );
      final change = storage.watch().firstWhere((value) => value.isEmpty);
      await storage.clear();
      expect((await change).isConfigured, isFalse);
      expect(
        (await storage.load()).encode(),
        const ObjectStorageConfig().encode(),
      );
      expect(await file.readAsBytes(), [1, 2, 3]);
      expect(
        (await database.providerAssetDao.find('asset', 'provider'))!.id,
        certification.id,
      );
      // Clear also repairs malformed saved settings without trying to decode them.
      await database.appSettingsDao.set(
        key: ObjectStorageConfig.appSettingsKey,
        value: 'broken',
      );
      await storage.clear();
      expect((await storage.load()).isEmpty, isTrue);
    },
  );

  test('skips PUT when the content-addressed object already exists', () async {
    final methods = <String>[];
    final storage = service((request) async {
      methods.add('${request.method} ${request.url.path}');
      return http.Response('', 200);
    });

    final result = await storage.upload(
      config.normalized(),
      file: file,
      sha256: hash,
      mimeType: 'image/png',
      fileSize: 3,
    );

    expect(methods, ['HEAD /refs/$hash.png']);
    expect(result.url.host, 'media.s3.example.com');
    expect(result.url.queryParameters['X-Amz-Expires'], '86400');
    expect(result.expiresAt!.isAfter(now), isTrue);
  });

  test('uploads missing objects and returns the public URL', () async {
    final requests = <http.Request>[];
    final storage = service((request) async {
      requests.add(request);
      return http.Response('', request.method == 'HEAD' ? 404 : 200);
    });

    final result = await storage.upload(
      config
          .copyWithPublicBaseUrl('https://cdn.example.com/assets/')
          .normalized(),
      file: file,
      sha256: hash,
      mimeType: 'image/png',
      fileSize: 3,
    );

    expect(requests.map((r) => r.method), ['HEAD', 'PUT']);
    expect(requests.last.bodyBytes, [1, 2, 3]);
    expect(requests.last.headers['x-amz-content-sha256'], hash);
    expect(requests.last.headers['content-type'], 'image/png');
    expect(
      result.url.toString(),
      'https://cdn.example.com/assets/refs/$hash.png',
    );
    expect(result.expiresAt, isNull);
  });

  test('connection test writes a probe and reads it back', () async {
    final requests = <String>[];
    var body = '';
    final storage = service((request) async {
      requests.add(request.method);
      if (request.method == 'PUT') {
        body = request.body;
        return http.Response('', 200);
      }
      return http.Response(body, 200);
    });

    expect(await storage.test(config), isNull);
    expect(requests, ['PUT', 'GET']);
  });

  for (final (response, failure) in [
    (http.Response('', 403), ObjectStorageFailure.unauthorized),
    (
      http.Response('<Error><Code>NoSuchBucket</Code></Error>', 404),
      ObjectStorageFailure.bucket_not_found,
    ),
    (http.Response('', 500), ObjectStorageFailure.upload_failed),
  ]) {
    test('maps probe write failure to ${failure.name}', () async {
      final storage = service((_) async => response);
      expect(await storage.test(config), failure);
    });
  }

  test('reports read_failed when the access URL is not readable', () async {
    final storage = service(
      (request) async => http.Response('', request.method == 'PUT' ? 200 : 403),
    );
    expect(await storage.test(config), ObjectStorageFailure.read_failed);
  });

  test('maps network errors to connection_failed', () async {
    final storage = service(
      (_) async => throw const SocketException('unreachable'),
    );
    expect(await storage.test(config), ObjectStorageFailure.connection_failed);
  });
}

extension on ObjectStorageConfig {
  ObjectStorageConfig copyWithPublicBaseUrl(String url) => ObjectStorageConfig(
    provider: provider,
    endpoint: endpoint,
    region: region,
    bucket: bucket,
    accessKeyId: accessKeyId,
    secretAccessKey: secretAccessKey,
    keyPrefix: keyPrefix,
    pathStyle: pathStyle,
    publicBaseUrl: url,
  );
}
