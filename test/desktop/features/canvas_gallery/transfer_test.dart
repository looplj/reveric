// 职责: 验证发布续签只重传缺片，详情中断下载可续传，完整坏包会在校验失败后丢弃。
// 关联文件:
//   lib/shared/services/canvas_gallery/service.dart
//   lib/shared/services/canvas_gallery/orchestrator.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/shared/services/canvas_gallery/orchestrator.dart';
import 'package:reveric/shared/services/canvas_gallery/service.dart';
import 'package:reveric/shared/services/production/canvas_package.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/media_service.dart';

const _apiHost = 'anonymous-api.reveric.app';
const _publicHost = 'gallery.reveric.app';
const _storageHost = 'example.r2.cloudflarestorage.com';
const _time = '2026-03-01T00:00:00Z';

void main() {
  late Directory scratch;

  setUp(
    () async => scratch = await Directory.systemTemp.createTemp('gallery-test'),
  );
  tearDown(() async => scratch.delete(recursive: true));

  test(
    'keeps publish authorization and only puts the missing part on retry',
    () async {
      final archive = File(p.join(scratch.path, 'archive'));
      final handle = await archive.open(mode: FileMode.write);
      await handle.truncate(canvasGalleryPartSize + 4);
      await handle.close();
      final cover = await File(
        p.join(scratch.path, 'cover'),
      ).writeAsString('jpeg');
      final control = <Map<String, Object?>>[];
      final requests = <String>[];
      String? token;
      var fail = true;
      var createCalls = 0;
      final service = _service((request, bytes) async {
        if (request.uri.host == _storageHost) {
          expect(
            request.headers.containsKey(HttpHeaders.authorizationHeader),
            isFalse,
          );
          final size = await bytes!.fold<int>(
            0,
            (size, chunk) => size + chunk.length,
          );
          expect('$size', request.headers[HttpHeaders.contentLengthHeader]);
          requests.add(request.uri.path);
          if (request.uri.path == '/part2' && fail) {
            fail = false;
            throw DioException.connectionError(
              requestOptions: request,
              reason: 'interrupted',
            );
          }
          return ResponseBody.fromString('', 200);
        }

        expect(request.uri.host, _apiHost);
        token ??= request.headers[HttpHeaders.authorizationHeader] as String?;
        expect(token, startsWith('Bearer '));
        expect(request.headers[HttpHeaders.authorizationHeader], token);
        final payload = request.data as Map<String, Object?>;
        if (request.uri.path == '/gallery/canvas/upload') {
          control.add(payload);
          final initial = control.length == 1;
          expect(
            request.headers['Idempotency-Key'],
            initial ? isNotEmpty : isNull,
          );
          return _reply({
            'upload_id': 'upl_synthetic',
            'expires_at': _expires(),
            'urls': {
              'cover': initial ? _target('cover', 4) : null,
              'parts': [
                if (initial) _target('part1', canvasGalleryPartSize, part: 1),
                _target('part2', 4, part: 2),
              ],
            },
          });
        }
        createCalls++;
        expect(payload, {
          'upload_id': 'upl_synthetic',
          'title': 'Fixed title',
          'description': 'Fixed description',
        });
        if (createCalls == 1) {
          return _reply(
            {
              'error': {'code': 'upload_finalizing'},
            },
            status: 409,
            headers: {
              'retry-after': ['1'],
            },
          );
        }
        return _reply({
          'canvas_id': 'c_fixed',
          'published_at': _time,
        }, status: 201);
      });

      final publication = CanvasGalleryPublishOrchestrator();
      final progress = <double>[];
      Future<CanvasGalleryPublicationResult> publish() => publication.publish(
        service: service,
        cover: cover,
        archive: archive,
        title: 'Fixed title',
        description: 'Fixed description',
        onProgress: progress.add,
      );
      await expectLater(publish(), throwsA(isA<CanvasGalleryFailure>()));
      final result = await publish();
      expect(result.id, 'c_fixed');
      expect(control, [
        {
          'cover_size_bytes': 4,
          'content_size_bytes': canvasGalleryPartSize + 4,
        },
        {'upload_id': 'upl_synthetic'},
      ]);
      expect(requests.where((path) => path == '/cover'), hasLength(1));
      expect(requests.where((path) => path == '/part1'), hasLength(1));
      expect(requests.where((path) => path == '/part2'), hasLength(2));
      expect(createCalls, 2);
      expect(progress.last, 1);
    },
  );

  test('validates 206 before appending a public download', () async {
    final file = await File(
      p.join(scratch.path, 'partial'),
    ).writeAsString('abcd');
    final item = CanvasGalleryDetail.fromJson({
      'canvas_id': 'c_fixed',
      'title': 'Fixed title',
      'description': '',
      'cover_url': 'https://$_publicHost/cover.jpg',
      'content_url': 'https://$_publicHost/archive.zip',
      'content_size_bytes': 8,
      'content_version': 1,
      'published_at': _time,
      'node_count': 1,
      'asset_count': 0,
      'conversation_count': 0,
      'conversation_file_count': 0,
      'is_pinned': false,
    });
    var corrupt = true;
    final service = _service((request, _) async {
      expect(request.headers[HttpHeaders.rangeHeader], 'bytes=4-');
      expect(
        request.headers[HttpHeaders.userAgentHeader],
        canvasGalleryUserAgent,
      );
      return ResponseBody.fromString(
        'efgh',
        206,
        headers: {
          HttpHeaders.contentRangeHeader: [
            corrupt ? 'bytes 3-6/8' : 'bytes 4-7/8',
          ],
          HttpHeaders.contentLengthHeader: ['4'],
        },
      );
    });
    await expectLater(
      service.download(item: item, file: file),
      throwsA(isA<CanvasGalleryFailure>()),
    );
    expect(await file.readAsString(), 'abcd');
    corrupt = false;
    await service.download(item: item, file: file);
    expect(await file.readAsString(), 'abcdefgh');
  });

  test(
    'reuses unpacked cache across orchestrator sessions without redownloading',
    () async {
      final cacheDir = Directory(p.join(scratch.path, 'cache'));
      final zipBytes = _minimalCanvasZipBytes('Cached canvas');
      final item = _galleryDetail('c_cached', zipBytes.length);
      var downloads = 0;
      final service = _service((request, _) async {
        downloads++;
        return ResponseBody.fromBytes(
          zipBytes,
          200,
          headers: {
            HttpHeaders.contentLengthHeader: ['${zipBytes.length}'],
          },
        );
      });
      final media = MediaService(FfmpegRunner());

      final first = CanvasGalleryArchiveOrchestrator(
        resolveCacheDirectory: () => cacheDir,
      );
      final preview1 = await first.preview(
        service: service,
        item: item,
        media: media,
      );
      expect(downloads, 1);
      expect(preview1.cacheDirectory, isNotNull);
      expect(preview1.canvas, isNotNull);
      final readyFile = File(
        p.join(preview1.cacheDirectory!.path, canvasGalleryCacheReadyMarker),
      );
      expect(await readyFile.exists(), isTrue);
      // 临时 .part 应在解包完成后删除，磁盘不保留压缩包副本。
      final leftoverParts = await cacheDir
          .list()
          .where((entity) => entity.path.endsWith('.part'))
          .toList();
      expect(leftoverParts, isEmpty);
      await first.close();
      // 关闭详情页仅关闭 SQLite 连接，不删除持久化缓存目录。
      expect(await preview1.cacheDirectory!.exists(), isTrue);
      final secondReady = CanvasGalleryArchiveOrchestrator(
        resolveCacheDirectory: () => cacheDir,
      );
      expect(await secondReady.hasReadyPackage(item), isTrue);
      expect(await secondReady.hasAnyReadyPackage(item.id), isTrue);
      expect(await secondReady.hasAnyReadyPackage('other-canvas'), isFalse);
      await secondReady.close();

      // 二次打开走本地解包缓存，跳过下载与解压。
      final second = CanvasGalleryArchiveOrchestrator(
        resolveCacheDirectory: () => cacheDir,
      );
      final preview2 = await second.preview(
        service: service,
        item: item,
        media: media,
      );
      expect(downloads, 1);
      expect(preview2.cacheDirectory!.path, preview1.cacheDirectory!.path);
      final content = await preview2.canvas!.content(preview2.canvasId!);
      expect(content.nodes.single.content, 'Hello gallery');
      await second.close();

      // 缓存损坏时自动清空并重下一次。
      await File(
        p.join(preview1.cacheDirectory!.path, 'app.db'),
      ).writeAsString('corrupted-sqlite');
      final third = CanvasGalleryArchiveOrchestrator(
        resolveCacheDirectory: () => cacheDir,
      );
      final preview3 = await third.preview(
        service: service,
        item: item,
        media: media,
      );
      expect(downloads, 2);
      expect(preview3.canvas, isNotNull);
      await third.close();
    },
  );

  test(
    'evicts oldest unpacked cache directories while skipping active ones',
    () async {
      final cacheDir = Directory(p.join(scratch.path, 'lru-cache'));
      final zipBytes = _minimalCanvasZipBytes('LRU canvas');
      final service = _service(
        (_, _) async => ResponseBody.fromBytes(
          zipBytes,
          200,
          headers: {
            HttpHeaders.contentLengthHeader: ['${zipBytes.length}'],
          },
        ),
      );
      final media = MediaService(FfmpegRunner());

      // 先打开 first 并保持关闭，模拟已不活跃的最旧缓存。
      final firstOrch = CanvasGalleryArchiveOrchestrator(
        resolveCacheDirectory: () => cacheDir,
        maxCacheEntries: 2,
      );
      final firstPreview = await firstOrch.preview(
        service: service,
        item: _galleryDetail('first', zipBytes.length),
        media: media,
      );
      final firstDir = firstPreview.cacheDirectory!;
      await firstOrch.close();
      await File(
        p.join(firstDir.path, canvasGalleryCacheReadyMarker),
      ).setLastModified(DateTime(2026, 1, 1));

      // second 保持打开状态（活跃租约），即使更旧也不应被淘汰。
      final secondOrch = CanvasGalleryArchiveOrchestrator(
        resolveCacheDirectory: () => cacheDir,
        maxCacheEntries: 2,
      );
      final secondPreview = await secondOrch.preview(
        service: service,
        item: _galleryDetail('second', zipBytes.length),
        media: media,
      );
      final secondDir = secondPreview.cacheDirectory!;
      await File(
        p.join(secondDir.path, canvasGalleryCacheReadyMarker),
      ).setLastModified(DateTime(2026, 1, 2));

      final thirdOrch = CanvasGalleryArchiveOrchestrator(
        resolveCacheDirectory: () => cacheDir,
        maxCacheEntries: 2,
      );
      final thirdPreview = await thirdOrch.preview(
        service: service,
        item: _galleryDetail('third', zipBytes.length),
        media: media,
      );
      final thirdDir = thirdPreview.cacheDirectory!;

      expect(await firstDir.exists(), isFalse);
      expect(await secondDir.exists(), isTrue);
      expect(await thirdDir.exists(), isTrue);

      await thirdOrch.close();
      await secondOrch.close();
    },
  );

  test(
    'discards a full-size corrupt package so retry downloads again',
    () async {
      final cacheDir = Directory(p.join(scratch.path, 'corrupt-part'));
      final zipBytes = _minimalCanvasZipBytes('Recovered canvas');
      final item = _galleryDetail('c_corrupt', zipBytes.length);
      var downloads = 0;
      final service = _service((request, _) async {
        downloads++;
        final body = downloads == 1 ? Uint8List(zipBytes.length) : zipBytes;
        return ResponseBody.fromBytes(
          body,
          200,
          headers: {
            HttpHeaders.contentLengthHeader: ['${zipBytes.length}'],
          },
        );
      });
      final media = MediaService(FfmpegRunner());
      final first = CanvasGalleryArchiveOrchestrator(
        resolveCacheDirectory: () => cacheDir,
      );
      await expectLater(
        first.preview(service: service, item: item, media: media),
        throwsA(
          isA<ProductionCanvasPackageException>().having(
            (error) => error.code,
            'code',
            'invalid_package',
          ),
        ),
      );
      expect(downloads, 1);
      final leftover = await cacheDir
          .list()
          .where((entity) => entity.path.endsWith('.part'))
          .toList();
      expect(leftover, isEmpty);
      await first.close();

      final second = CanvasGalleryArchiveOrchestrator(
        resolveCacheDirectory: () => cacheDir,
      );
      final preview = await second.preview(
        service: service,
        item: item,
        media: media,
      );
      expect(downloads, 2);
      expect(preview.canvas, isNotNull);
      await second.close();
    },
  );

  test('keeps an incomplete download so retry resumes with Range', () async {
    final cacheDir = Directory(p.join(scratch.path, 'partial-part'));
    final zipBytes = _minimalCanvasZipBytes('Resume canvas');
    final item = _galleryDetail('c_resume', zipBytes.length);
    final split = zipBytes.length ~/ 2;
    var downloads = 0;
    final service = _service((request, _) async {
      downloads++;
      if (downloads == 1) {
        return ResponseBody.fromBytes(
          zipBytes.sublist(0, split),
          200,
          headers: {
            HttpHeaders.contentLengthHeader: ['${zipBytes.length}'],
          },
        );
      }
      expect(request.headers[HttpHeaders.rangeHeader], 'bytes=$split-');
      return ResponseBody.fromBytes(
        zipBytes.sublist(split),
        206,
        headers: {
          HttpHeaders.contentRangeHeader: [
            'bytes $split-${zipBytes.length - 1}/${zipBytes.length}',
          ],
          HttpHeaders.contentLengthHeader: ['${zipBytes.length - split}'],
        },
      );
    });
    final media = MediaService(FfmpegRunner());
    final first = CanvasGalleryArchiveOrchestrator(
      resolveCacheDirectory: () => cacheDir,
    );
    await expectLater(
      first.preview(service: service, item: item, media: media),
      throwsA(
        isA<CanvasGalleryFailure>().having(
          (error) => error.code,
          'code',
          'download_failed',
        ),
      ),
    );
    final parts = await cacheDir
        .list()
        .where((entity) => entity.path.endsWith('.part'))
        .toList();
    expect(parts, hasLength(1));
    expect(await File(parts.single.path).length(), split);
    await first.close();

    final second = CanvasGalleryArchiveOrchestrator(
      resolveCacheDirectory: () => cacheDir,
    );
    final preview = await second.preview(
      service: service,
      item: item,
      media: media,
    );
    expect(downloads, 2);
    expect(preview.canvas, isNotNull);
    await second.close();
  });

  test('overlapping opens of one canvas unpack it once', () async {
    final cacheDir = Directory(p.join(scratch.path, 'shared-cache'));
    final zipBytes = _minimalCanvasZipBytes('Shared canvas');
    final item = _galleryDetail('c_shared', zipBytes.length);
    final release = Completer<void>();
    var downloads = 0;
    final service = _service((request, _) async {
      downloads++;
      if (downloads == 1) {
        await release.future;
      }
      return ResponseBody.fromBytes(
        zipBytes,
        200,
        headers: {
          HttpHeaders.contentLengthHeader: ['${zipBytes.length}'],
        },
      );
    });
    final media = MediaService(FfmpegRunner());
    final first = CanvasGalleryArchiveOrchestrator(
      resolveCacheDirectory: () => cacheDir,
    );
    final second = CanvasGalleryArchiveOrchestrator(
      resolveCacheDirectory: () => cacheDir,
    );
    final open1 = first.preview(service: service, item: item, media: media);
    final open2 = second.preview(service: service, item: item, media: media);
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (downloads < 1 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(downloads, 1);
    release.complete();
    final preview1 = await open1;
    final preview2 = await open2;
    expect(downloads, 1);
    expect(preview2.cacheDirectory!.path, preview1.cacheDirectory!.path);
    final content = await preview1.canvas!.content(preview1.canvasId!);
    expect(content.nodes.single.content, 'Hello gallery');
    await first.close();
    await second.close();
  });

  test(
    'a closed open does not replace the cache the next open is using',
    () async {
      final cacheDir = Directory(p.join(scratch.path, 'reopen-cache'));
      final zipBytes = _minimalCanvasZipBytes('Reopened canvas');
      final item = _galleryDetail('c_reopen', zipBytes.length);
      final release = Completer<void>();
      var downloads = 0;
      final service = _service((request, _) async {
        downloads++;
        if (downloads == 1) {
          await release.future;
        }
        return ResponseBody.fromBytes(
          zipBytes,
          200,
          headers: {
            HttpHeaders.contentLengthHeader: ['${zipBytes.length}'],
          },
        );
      });
      final media = MediaService(FfmpegRunner());
      final first = CanvasGalleryArchiveOrchestrator(
        resolveCacheDirectory: () => cacheDir,
      );
      final opening = first.preview(service: service, item: item, media: media);
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (downloads < 1 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final closing = first.close();
      final second = CanvasGalleryArchiveOrchestrator(
        resolveCacheDirectory: () => cacheDir,
      );
      final reopened = second.preview(
        service: service,
        item: item,
        media: media,
      );
      release.complete();
      await expectLater(
        opening,
        throwsA(
          isA<CanvasGalleryFailure>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await closing;
      final preview = await reopened;
      expect(preview.canvas, isNotNull);
      final content = await preview.canvas!.content(preview.canvasId!);
      expect(content.nodes.single.content, 'Hello gallery');
      await second.close();
    },
  );
}

CanvasGalleryDetail _galleryDetail(String id, int size) =>
    CanvasGalleryDetail.fromJson({
      'canvas_id': id,
      'title': id,
      'description': '',
      'cover_url': 'https://$_publicHost/cover.jpg',
      'content_url': 'https://$_publicHost/$id.zip',
      'content_size_bytes': size,
      'content_version': 1,
      'published_at': _time,
      'node_count': 1,
      'asset_count': 0,
      'conversation_count': 0,
      'conversation_file_count': 0,
      'is_pinned': false,
    });

Uint8List _minimalCanvasZipBytes(String title) {
  final manifest = utf8.encode(
    jsonEncode({
      'format': productionCanvasPackageFormat,
      'version': 1,
      'title': title,
      'settings': {'style_id': null, 'ratio': '16:9', 'resolution': '720p'},
      'nodes': [
        {
          'id': 'n1',
          'type': 'text',
          'title': 'Note',
          'content': 'Hello gallery',
          'x': 0,
          'y': 0,
          'width': null,
          'height': null,
          'z': 0,
          'sort': 0,
          'parent_id': null,
          'style': null,
          'clip': null,
          'asset_id': null,
          'staging': null,
          'editing': null,
        },
      ],
      'edges': const <Object>[],
      'assets': const <Object>[],
    }),
  );
  final archive = Archive()
    ..addFile(ArchiveFile('manifest.json', manifest.length, manifest));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _expires() =>
    DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String();

Map<String, Object> _target(String path, int length, {int? part}) => {
  'url': 'https://$_storageHost/$path?signature=opaque',
  'headers': {HttpHeaders.contentLengthHeader: '$length'},
  'expires_at': _expires(),
  'part_number': ?part,
};

ResponseBody _reply(
  Object value, {
  int status = 200,
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  jsonEncode(value),
  status,
  headers: {
    HttpHeaders.contentTypeHeader: ['application/json'],
    ...headers,
  },
);

CanvasGalleryService _service(
  Future<ResponseBody> Function(RequestOptions, Stream<Uint8List>?) responder,
) => CanvasGalleryService(
  apiOrigin: Uri.https(_apiHost),
  publicOrigin: Uri.https(_publicHost),
  createClient: () => Dio()..httpClientAdapter = _Adapter(responder),
);

class _Adapter implements HttpClientAdapter {
  const _Adapter(this.responder);

  final Future<ResponseBody> Function(RequestOptions, Stream<Uint8List>?)
  responder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => responder(options, requestStream);

  @override
  void close({bool force = false}) {}
}
