// 职责: 验证插件市场索引解析、兼容版本筛选、缓存保护、CDN 下载回退与完整性校验。
// 关联文件:
//   lib/shared/models/plugin/marketplace_plugin.dart
//   lib/shared/services/plugins/marketplace_service.dart
//   lib/shared/providers/plugin_marketplace_providers.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:reveric/shared/models/plugin/marketplace_plugin.dart';
import 'package:reveric/shared/providers/plugin_marketplace_providers.dart';
import 'package:reveric/shared/services/plugins/marketplace_service.dart';
import 'package:reveric/shared/services/plugins/package_archive.dart';

Uint8List _buildPluginZip({
  required String id,
  required String version,
  String pluginApiVersion = '^1',
  List<String> platforms = const ['windows', 'macos', 'android'],
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'plugin.json',
        jsonEncode({
          'id': id,
          'name': {'en': 'Sample Plugin', 'zh-CN': '示例插件'},
          'version': version,
          'pluginApiVersion': pluginApiVersion,
          'main': 'dist/index.js',
          'platforms': platforms,
        }),
      ),
    )
    ..addFile(ArchiveFile.string('dist/index.js', 'export const ok = true;'));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

class _FakeHttpAdapter implements HttpClientAdapter {
  _FakeHttpAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _bytesBody(
  List<int> bytes, {
  int statusCode = 200,
  String? advertisedContentLength,
}) => ResponseBody.fromBytes(
  bytes,
  statusCode,
  headers: {
    Headers.contentLengthHeader: [advertisedContentLength ?? '${bytes.length}'],
  },
);

void main() {
  test('parses schemaVersion 1 index and selects highest compatible version', () {
    final index = MarketplacePluginIndex.fromJson({
      'schemaVersion': 1,
      'plugins': [
        {
          'id': 'reveric.xiaoyunque',
          'name': {'en': 'Xiaoyunque', 'zh-CN': '小云雀'},
          'description': '',
          'author': 'Reveric',
          'repository': 'https://github.com/looplj/reveric-plugins',
          'versions': [
            {
              'version': '1.0.9',
              'pluginApiVersion': '^1',
              'platforms': ['macos', 'windows', 'android'],
              'url':
                  'https://downloads.reveric.app/plugins/xiaoyunque/v1.0.9/reveric.xiaoyunque-1.0.9.zip',
              'fallbackUrl':
                  'https://github.com/looplj/reveric-plugins/releases/download/xiaoyunque%2Fv1.0.9/reveric.xiaoyunque-1.0.9.zip',
              'size': 1024,
              'sha256': 'a' * 64,
              'releaseUrl':
                  'https://github.com/looplj/reveric-plugins/releases/tag/xiaoyunque%2Fv1.0.9',
            },
            {
              'version': '2.0.0',
              'pluginApiVersion': '^2',
              'platforms': ['macos', 'windows', 'android'],
              'url':
                  'https://downloads.reveric.app/plugins/xiaoyunque/v2.0.0/reveric.xiaoyunque-2.0.0.zip',
              'size': 1024,
              'sha256': 'b' * 64,
            },
            {
              'version': '1.0.10',
              'pluginApiVersion': '>=1.0.0 <2.0.0',
              'platforms': ['macos', 'windows'],
              'url':
                  'https://downloads.reveric.app/plugins/xiaoyunque/v1.0.10/reveric.xiaoyunque-1.0.10.zip',
              'size': 2048,
              'sha256': 'c' * 64,
            },
          ],
        },
      ],
    }, maxPackageBytes: PluginPackageArchive.maxZipBytes);

    final entry = index.plugins.single;
    expect(entry.description, isNull);
    expect(entry.versions.map((v) => v.version), ['2.0.0', '1.0.10', '1.0.9']);

    final macosTarget = entry.resolveCompatibleVersion(platform: 'macos');
    expect(macosTarget?.version, '1.0.10');

    final androidTarget = entry.resolveCompatibleVersion(platform: 'android');
    expect(androidTarget?.version, '1.0.9');
    expect(androidTarget?.downloadUrls, [
      'https://downloads.reveric.app/plugins/xiaoyunque/v1.0.9/reveric.xiaoyunque-1.0.9.zip',
      'https://github.com/looplj/reveric-plugins/releases/download/xiaoyunque%2Fv1.0.9/reveric.xiaoyunque-1.0.9.zip',
    ]);

    expect(entry.matches('小云雀', const Locale('en')), isTrue);
    expect(entry.matches('xiaoyunque', const Locale('zh', 'CN')), isTrue);
    expect(entry.matches('missing', const Locale('en')), isFalse);
    expect(
      isPluginApiVersionCompatible('^1', hostApiVersion: Version(1, 0, 0)),
      isTrue,
    );
  });

  test(
    'rejects invalid schemaVersion, non-HTTPS URLs, invalid hashes, and oversized packages',
    () {
      Map<String, Object?> validIndex({
        Object? schemaVersion = 1,
        Object? url = 'https://downloads.reveric.app/a.zip',
        Object? size = 100,
        Object? digest,
      }) => {
        'schemaVersion': schemaVersion,
        'plugins': [
          {
            'id': 'reveric.sample',
            'name': 'Sample',
            'versions': [
              {
                'version': '1.0.0',
                'pluginApiVersion': '^1',
                'platforms': ['macos'],
                'url': url,
                'size': size,
                'sha256': digest ?? 'd' * 64,
              },
            ],
          },
        ],
      };

      expect(
        () => MarketplacePluginIndex.fromJson(
          validIndex(schemaVersion: 2),
          maxPackageBytes: PluginPackageArchive.maxZipBytes,
        ),
        throwsFormatException,
      );
      expect(
        () => MarketplacePluginIndex.fromJson(
          validIndex(url: 'http://downloads.reveric.app/a.zip'),
          maxPackageBytes: PluginPackageArchive.maxZipBytes,
        ),
        throwsFormatException,
      );
      expect(
        () => MarketplacePluginIndex.fromJson(
          validIndex(digest: 'not-hex'),
          maxPackageBytes: PluginPackageArchive.maxZipBytes,
        ),
        throwsFormatException,
      );
      expect(
        () => MarketplacePluginIndex.fromJson(
          validIndex(size: PluginPackageArchive.maxZipBytes + 1),
          maxPackageBytes: PluginPackageArchive.maxZipBytes,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'fetchCatalog writes cache and preserves good cache when remote fails or returns corrupt JSON',
    () async {
      final dir = await Directory.systemTemp.createTemp('plugin-mkt-cache-');
      addTearDown(() => dir.delete(recursive: true));
      final cacheFile = File('${dir.path}/index.json');

      var mode = 'valid';
      final service = PluginMarketplaceService(
        cacheFile: cacheFile,
        createClient: () => Dio()
          ..httpClientAdapter = _FakeHttpAdapter((options) async {
            if (mode == 'valid') {
              return _bytesBody(
                utf8.encode(
                  jsonEncode({
                    'schemaVersion': 1,
                    'plugins': [
                      {
                        'id': 'reveric.sample',
                        'name': 'Sample',
                        'versions': [
                          {
                            'version': '1.0.0',
                            'pluginApiVersion': '^1',
                            'platforms': ['macos'],
                            'url': 'https://downloads.reveric.app/sample.zip',
                            'size': 42,
                            'sha256': 'a' * 64,
                          },
                        ],
                      },
                    ],
                  }),
                ),
              );
            }
            if (mode == 'corrupt') {
              return _bytesBody(utf8.encode('{bad json'));
            }
            throw DioException.connectionError(
              requestOptions: options,
              reason: 'offline',
            );
          }),
      );

      final first = await service.fetchCatalog();
      expect(first.plugins.single.id, 'reveric.sample');

      mode = 'corrupt';
      await expectLater(
        service.fetchCatalog(),
        throwsA(
          isA<PluginMarketplaceException>().having(
            (e) => e.kind,
            'kind',
            PluginMarketplaceErrorKind.invalidCatalog,
          ),
        ),
      );
      expect(
        (await service.readCatalogCache())?.plugins.single.id,
        'reveric.sample',
      );

      mode = 'offline';
      await expectLater(
        service.fetchCatalog(),
        throwsA(
          isA<PluginMarketplaceException>().having(
            (e) => e.kind,
            'kind',
            PluginMarketplaceErrorKind.network,
          ),
        ),
      );
      expect(
        (await service.readCatalogCache())?.plugins.single.id,
        'reveric.sample',
      );
    },
  );

  test(
    'downloadPackage falls back from CDN failure or corrupt bytes to GitHub Release URL and verifies manifest',
    () async {
      final zipBytes = _buildPluginZip(id: 'reveric.sample', version: '1.2.0');
      final digest = sha256.convert(zipBytes).toString();
      const cdnUrl =
          'https://downloads.reveric.app/plugins/sample/v1.2.0/reveric.sample-1.2.0.zip';
      const githubUrl =
          'https://github.com/looplj/reveric-plugins/releases/download/sample%2Fv1.2.0/reveric.sample-1.2.0.zip';

      final version = MarketplacePluginVersion.fromJson({
        'version': '1.2.0',
        'pluginApiVersion': '^1',
        'platforms': ['macos'],
        'url': cdnUrl,
        'fallbackUrl': githubUrl,
        'size': zipBytes.length,
        'sha256': digest,
      }, maxPackageBytes: PluginPackageArchive.maxZipBytes);

      final requests = <String>[];
      final service = PluginMarketplaceService(
        createClient: () =>
            Dio()
              ..httpClientAdapter = _FakeHttpAdapter((options) async {
                final uri = options.uri.toString();
                requests.add(uri);
                if (uri == cdnUrl) {
                  // 模拟 CDN 节点返回损坏字节。
                  return _bytesBody(List<int>.filled(zipBytes.length, 0));
                }
                if (uri == githubUrl) {
                  return _bytesBody(zipBytes);
                }
                throw StateError('Unexpected url $uri');
              }),
      );

      final downloaded = await service.downloadPackage(
        pluginId: 'reveric.sample',
        version: version,
      );
      expect(requests, [cdnUrl, githubUrl]);
      expect(downloaded.manifest.id, 'reveric.sample');
      expect(downloaded.manifest.version, '1.2.0');

      // 包内清单与目录声明的 ID 不一致时拒绝安装。
      final mismatchedService = PluginMarketplaceService(
        createClient: () => Dio()
          ..httpClientAdapter = _FakeHttpAdapter(
            (_) async => _bytesBody(zipBytes),
          ),
      );
      await expectLater(
        mismatchedService.downloadPackage(
          pluginId: 'reveric.other',
          version: version,
        ),
        throwsA(
          isA<PluginMarketplaceException>().having(
            (e) => e.kind,
            'kind',
            PluginMarketplaceErrorKind.integrityMismatch,
          ),
        ),
      );

      // 响应体超过声明大小时在流阶段拒绝。
      final oversizedService = PluginMarketplaceService(
        createClient: () => Dio()
          ..httpClientAdapter = _FakeHttpAdapter(
            (_) async => _bytesBody(
              zipBytes,
              advertisedContentLength: '${zipBytes.length + 100}',
            ),
          ),
      );
      await expectLater(
        oversizedService.downloadPackage(
          pluginId: 'reveric.sample',
          version: version,
        ),
        throwsA(
          isA<PluginMarketplaceException>().having(
            (e) => e.kind,
            'kind',
            PluginMarketplaceErrorKind.packageTooLarge,
          ),
        ),
      );
    },
  );

  test(
    'pluginMarketplaceProvider loads cache, single-flights refresh, and preserves stale items on failure',
    () async {
      final dir = await Directory.systemTemp.createTemp('plugin-mkt-provider-');
      addTearDown(() => dir.delete(recursive: true));
      final cacheFile = File('${dir.path}/index.json');
      await cacheFile.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'plugins': [
            {
              'id': 'reveric.cached',
              'name': {'en': 'Cached Plugin', 'zh-CN': '缓存插件'},
              'versions': [
                {
                  'version': '1.0.0',
                  'pluginApiVersion': '^1',
                  'platforms': ['macos'],
                  'url': 'https://downloads.reveric.app/cached.zip',
                  'size': 10,
                  'sha256': 'a' * 64,
                },
              ],
            },
          ],
        }),
      );

      var remoteCalls = 0;
      final remoteStarted = Completer<void>();
      final gate = Completer<void>();
      var failRemote = false;
      final service = PluginMarketplaceService(
        cacheFile: cacheFile,
        createClient: () =>
            Dio()
              ..httpClientAdapter = _FakeHttpAdapter((options) async {
                remoteCalls += 1;
                if (!remoteStarted.isCompleted) {
                  remoteStarted.complete();
                }
                await gate.future;
                if (failRemote) {
                  throw DioException.connectionError(
                    requestOptions: options,
                    reason: 'offline',
                  );
                }
                return _bytesBody(
                  utf8.encode(
                    jsonEncode({
                      'schemaVersion': 1,
                      'plugins': [
                        {
                          'id': 'reveric.remote',
                          'name': 'Remote Plugin',
                          'versions': [
                            {
                              'version': '1.1.0',
                              'pluginApiVersion': '^1',
                              'platforms': ['macos'],
                              'url': 'https://downloads.reveric.app/remote.zip',
                              'size': 10,
                              'sha256': 'b' * 64,
                            },
                          ],
                        },
                      ],
                    }),
                  ),
                );
              }),
      );

      final container = ProviderContainer(
        overrides: [
          pluginMarketplaceServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);

      container.read(pluginMarketplaceProvider);
      await remoteStarted.future;

      expect(
        container.read(pluginMarketplaceProvider).plugins.single.id,
        'reveric.cached',
      );
      expect(remoteCalls, 1);

      // 并发刷新复用进行中的请求。
      final pendingA = container
          .read(pluginMarketplaceProvider.notifier)
          .refresh();
      final pendingB = container
          .read(pluginMarketplaceProvider.notifier)
          .refresh();
      expect(remoteCalls, 1);
      gate.complete();
      await Future.wait([pendingA, pendingB]);

      expect(
        container.read(pluginMarketplaceProvider).plugins.single.id,
        'reveric.remote',
      );
      expect(container.read(pluginMarketplaceProvider).errorKind, isNull);

      // 远端失败时保留已有列表并标示 errorKind。
      failRemote = true;
      await container.read(pluginMarketplaceProvider.notifier).refresh();
      final afterFailure = container.read(pluginMarketplaceProvider);
      expect(afterFailure.plugins.single.id, 'reveric.remote');
      expect(afterFailure.errorKind, PluginMarketplaceErrorKind.network);
    },
  );
}
