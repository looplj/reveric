// 职责: 验证素材认证的本地校验、火山与 AtlasCloud 素材库调用顺序、鉴权头与状态落库。
// 关联文件:
//   lib/shared/services/ai/assets/certification.dart
//   lib/shared/services/ai/assets/volcengine.dart
//   lib/shared/services/ai/assets/atlascloud.dart
//   lib/shared/database/daos/provider_asset_dao.dart

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/provider_asset.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/services/ai/assets/certification.dart';
import 'package:reveric/shared/services/ai/assets/client.dart';
import 'package:reveric/shared/services/ai/assets/volcengine.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';

class _References implements ReferenceStorageService {
  final ensured = <String>[];
  @override
  Future<VideoReference> ensure(
    VideoInput input,
    File file, {
    AiProvider? provider,
  }) async {
    ensured.add(input.assetId);
    return VideoReference(
      role: input.role,
      url: 'https://cos.example/${input.assetId}.png',
      mimeType: input.mimeType,
      fileSize: await file.length(),
      mediaInfo: const VideoMediaInfo(width: 900, height: 1600),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AiProvider _provider({String type = 'volcengine'}) => AiProvider(
  id: 'volc',
  name: 'Volc',
  builtin: false,
  type: type,
  enabled: true,
  apiKey: 'api-key',
  baseUrl: '',
  models: const [],
  imageModels: const [],
  videoModels: const [],
  audioModels: const [],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  accessKeyId: 'AKTEST',
  secretAccessKey: 'secret',
  assetProjectName: 'films',
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);

void main() {
  late AppDatabase db;
  late Directory dir;
  late File image;
  late _References references;
  late List<http.Request> requests;
  late Map<String, List<Map<String, dynamic>>> responses;

  ProviderAssetService service({int width = 900, int height = 1600}) =>
      ProviderAssetService(
        database: db,
        references: references,
        probe: (_) async => MediaInfo(
          duration: Duration.zero,
          hasAudio: false,
          hasVideo: true,
          width: width,
          height: height,
        ),
        pollDelays: const [Duration.zero],
        transport: (_) => MockClient((request) async {
          requests.add(request);
          final action =
              request.url.queryParameters['Action'] ??
              '${request.method} ${request.url.path}';
          final queue = responses[action]!;
          final body = queue.length > 1 ? queue.removeAt(0) : queue.first;
          return http.Response(jsonEncode(body), 200);
        }),
      );

  Future<ProviderAsset?> record([String provider = 'volc']) =>
      db.providerAssetDao.find('asset', provider);

  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    await db.aiProviderDao.saveAll([_provider()]);
    dir = await Directory.systemTemp.createTemp('provider-asset-');
    image = File('${dir.path}/a.png')..writeAsBytesSync(List.filled(64, 1));
    references = _References();
    requests = [];
    responses = {
      // Name 是模糊匹配：只有同名组才复用。
      'ListAssetGroups': [
        {
          'Result': {
            'Items': [
              {'Id': 'group-other', 'Name': 'reveric-old'},
            ],
          },
        },
      ],
      'CreateAssetGroup': [
        {
          'Result': {'Id': 'group-new'},
        },
      ],
      'CreateAsset': [
        {
          'Result': {'Id': 'asset-remote'},
        },
      ],
      'GetAsset': [
        {
          'Result': {
            'Id': 'asset-remote',
            'GroupId': 'group-new',
            'Status': 'Processing',
          },
        },
        {
          'Result': {
            'Id': 'asset-remote',
            'GroupId': 'group-new',
            'Status': 'Active',
          },
        },
      ],
    };
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  Future<void> certify(
    ProviderAssetService service, [
    String provider = 'volc',
  ]) => service.certify(
    assetId: 'asset',
    providerId: provider,
    file: image,
    mimeType: 'image/png',
    name: 'hero.png',
  );

  Future<void> settle(
    ProviderAssetStatus status, [
    String provider = 'volc',
  ]) async {
    for (var i = 0; i < 50 && (await record(provider))?.status != status; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('uploads, creates the shared group and polls until active', () async {
    await certify(service());
    await settle(ProviderAssetStatus.active);

    final row = (await record())!;
    expect(row.status, ProviderAssetStatus.active);
    expect(row.remoteId, 'asset-remote');
    expect(row.remoteGroupId, 'group-new');
    expect(references.ensured, ['asset']);
    expect(requests.map((r) => r.url.queryParameters['Action']), [
      'ListAssetGroups',
      'CreateAssetGroup',
      'CreateAsset',
      'GetAsset',
      'GetAsset',
    ]);
    final create = requests[2];
    expect(create.url.host, 'open.volcengineapi.com');
    expect(create.url.queryParameters['Version'], '2024-01-01');
    expect(jsonDecode(create.body), {
      'GroupId': 'group-new',
      'URL': 'https://cos.example/asset.png',
      'AssetType': 'Image',
      'Name': 'hero.png',
      'ProjectName': 'films',
    });
    expect(jsonDecode(requests[1].body)['Name'], providerAssetGroupName);
    expect(
      create.headers['Authorization'],
      matches(
        RegExp(
          r'^HMAC-SHA256 Credential=AKTEST/\d{8}/cn-beijing/ark/request, '
          r'SignedHeaders=content-type;host;x-content-sha256;x-date, '
          r'Signature=[0-9a-f]{64}$',
        ),
      ),
    );
    expect(create.headers['X-Date'], matches(RegExp(r'^\d{8}T\d{6}Z$')));
  });

  test(
    'rejects images outside the library limits before any request',
    () async {
      await expectLater(
        certify(service(width: 3000, height: 1000)),
        throwsA(
          isA<ProviderAssetException>().having(
            (e) => e.code,
            'code',
            'invalid_ratio',
          ),
        ),
      );
      expect(await record(), isNull);
      expect(requests, isEmpty);
      expect(references.ensured, isEmpty);
    },
  );

  test('records the provider error code when submission fails', () async {
    responses['CreateAsset'] = [
      {
        'ResponseMetadata': {
          'Error': {'Code': 'QuotaExceeded', 'Message': 'asset quota'},
        },
      },
    ];
    await expectLater(
      certify(service()),
      throwsA(isA<ProviderAssetException>()),
    );
    final row = (await record())!;
    expect(row.status, ProviderAssetStatus.failed);
    expect(row.errorCode, 'QuotaExceeded');
    expect(row.errorMessage, 'asset quota');
  });

  test('requires a Volcengine provider with AK/SK', () async {
    await db.aiProviderDao.saveAll([_provider(type: 'doubao')]);
    await expectLater(
      certify(service()),
      throwsA(
        isA<ProviderAssetException>().having(
          (e) => e.code,
          'code',
          'configuration_required',
        ),
      ),
    );
    expect(await record(), isNull);
  });

  group('AtlasCloud', () {
    const assets = '/api/v1/sd/assets';
    setUp(() async {
      await db.aiProviderDao.saveAll([
        _provider(type: 'atlascloud').copyWith(
          id: 'atlas',
          accessKeyId: const Value(null),
          secretAccessKey: const Value(null),
        ),
      ]);
      responses['POST $assets'] = [
        {
          'code': '200',
          'data': {
            'id': 42,
            'atlas_asset_id': 'asset-20261022-atlas',
            'name': 'hero.png',
            'status': 'Processing',
          },
        },
      ];
      responses['GET $assets/42'] = [
        {
          'code': '200',
          'data': {'id': 42, 'status': 'Processing'},
        },
        {
          'code': '200',
          'data': {'id': 42, 'status': 'Active'},
        },
      ];
    });

    test('registers with the API key and polls by the numeric id', () async {
      await certify(service(), 'atlas');
      await settle(ProviderAssetStatus.active, 'atlas');

      final row = (await record('atlas'))!;
      expect(row.status, ProviderAssetStatus.active);
      expect(row.remoteId, 'asset-20261022-atlas');
      expect(row.remoteTaskId, '42');
      expect(row.remoteGroupId, isNull);
      expect(requests.map((r) => '${r.method} ${r.url}'), [
        'POST https://console.atlascloud.ai$assets',
        'GET https://console.atlascloud.ai$assets/42',
        'GET https://console.atlascloud.ai$assets/42',
      ]);
      expect(requests.map((r) => r.headers['Authorization']).toSet(), {
        'Bearer api-key',
      });
      expect(jsonDecode(requests.first.body), {
        'url': 'https://cos.example/asset.png',
        'name': 'hero.png',
        'asset_type': 'Image',
      });
    });

    test('records the asset error when the library rejects it', () async {
      responses['GET $assets/42'] = [
        {
          'code': '200',
          'data': {
            'id': 42,
            'status': 'Failed',
            'error_code': 'FaceNotDetected',
            'error_message': 'no face detected',
          },
        },
      ];
      await certify(service(), 'atlas');
      await settle(ProviderAssetStatus.failed, 'atlas');

      final row = (await record('atlas'))!;
      expect(row.errorCode, 'FaceNotDetected');
      expect(row.errorMessage, 'no face detected');
    });

    test('maps an error envelope to the provider code', () async {
      responses['POST $assets'] = [
        {'code': 40400, 'data': 'bad request', 'message': 'bad request'},
      ];
      await expectLater(
        certify(service(), 'atlas'),
        throwsA(
          isA<ProviderAssetException>()
              .having((e) => e.code, 'code', '40400')
              .having((e) => e.message, 'message', 'bad request'),
        ),
      );
      expect((await record('atlas'))!.status, ProviderAssetStatus.failed);
    });

    test('needs only the API key', () {
      final atlas = _provider(type: 'atlascloud').copyWith(
        id: 'atlas',
        accessKeyId: const Value(null),
        secretAccessKey: const Value(null),
      );
      expect(providerSupportsAssetCertification(atlas), isTrue);
      expect(
        providerSupportsAssetCertification(atlas.copyWith(apiKey: ' ')),
        isFalse,
      );
    });
  });

  test('signs with the Volcengine V4 HMAC chain', () {
    final client = VolcengineAssetClient(
      httpClient: MockClient((_) async => http.Response('', 200)),
      accessKeyId: 'AK',
      secretAccessKey: 'SK',
      projectName: 'default',
      now: () => DateTime.utc(2026, 3, 18, 3, 57, 10),
    );
    final headers = client.signedHeaders(
      Uri.https('open.volcengineapi.com', '/', {
        'Action': 'GetAsset',
        'Version': '2024-01-01',
      }),
      utf8.encode('{}'),
    );
    expect(headers['X-Date'], '20260318T035710Z');
    expect(
      headers['X-Content-Sha256'],
      '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
    );
    // 期望值由独立的 Python 实现按同一签名流程算出。
    expect(
      headers['Authorization'],
      'HMAC-SHA256 Credential=AK/20260318/cn-beijing/ark/request, '
      'SignedHeaders=content-type;host;x-content-sha256;x-date, '
      'Signature=c626d3b0092c57de62781c3bbab5e04d8a349be0e8cfbac5a5f384973d5b69a9',
    );
  });
}
