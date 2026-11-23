// 职责: 验证参考素材存储未配置提示、内容哈希、并发上传合并及失败重试边界。
// 关联文件:
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart
import 'package:reveric/shared/models/ai_provider.dart';
import 'dart:async';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/models/image/config.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/services/plugins/files.dart';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import 'package:reveric/shared/services/production/image_dimensions.dart';

import '../../../../helpers/fake_object_storage.dart';

void main() {
  late AppDatabase db;
  late Directory directory;
  late File file;
  const media = VideoMediaInfo(width: 320, height: 240, durationMs: 0);
  final input = VideoInput(
    role: VideoInputRole.reference_image,
    assetId: 'input',
    mimeType: 'image/png',
  );
  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    directory = await Directory.systemTemp.createTemp('reference-storage-');
    file = await File('${directory.path}/input.png').writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });
  ReferenceStorageService service(ReferenceUploader? upload) =>
      ReferenceStorageService(
        database: db,
        storage: FakeObjectStorage(db, upload),
        probe: (_, {cancellation}) async => const MediaInfo(
          duration: Duration.zero,
          hasAudio: false,
          hasVideo: true,
          width: 320,
          height: 240,
        ),
      );
  test(
    'typed video references enforce aggregate inline budget and refuse video inline',
    () async {
      final provider = aiProviderBuiltinById('openai')!;
      final storage = service(null);
      final scope = PluginFileScope(
        pluginId: 'builtin',
        providerId: provider.id,
        taskId: 'inline',
      );
      final refs = await storage.prepareVideos(
        [(input, file, media)],
        provider: provider,
        supportsCertifiedAssets: false,
        files: scope,
        taskId: 'inline',
      );
      expect(refs.single['source']['kind'], 'file');
      expect(refs.single['assetId'], input.assetId);
      await expectLater(
        storage.prepareVideos(
          [
            (
              const VideoInput(
                role: VideoInputRole.reference_video,
                assetId: 'video',
                mimeType: 'video/mp4',
              ),
              file,
              media,
            ),
          ],
          provider: provider,
          supportsCertifiedAssets: false,
          files: scope,
          taskId: 'inline',
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.code,
            'code',
            VideoErrorCode.configuration_required,
          ),
        ),
      );
      final large = await File(
        '${directory.path}/large.png',
      ).open(mode: FileMode.write);
      await large.truncate(25 * 1024 * 1024);
      await large.close();
      final big = File('${directory.path}/large.png');
      await expectLater(
        storage.prepareVideos(
          [(input, big, media), (input, big, media)],
          provider: provider,
          supportsCertifiedAssets: false,
          files: scope,
          taskId: 'inline',
        ),
        throwsA(
          isA<VideoException>().having((e) => e.field, 'field', 'file_size'),
        ),
      );
      scope.revoke();
      storage.dispose();
    },
  );
  test(
    'unconfigured storage fails before probing or sending local bytes',
    () async {
      final storage = ReferenceStorageService(
        database: db,
        storage: FakeObjectStorage(db, null),
        probe: (_, {cancellation}) async => throw StateError('must not probe'),
      );
      await expectLater(
        storage.ensure(input, file),
        throwsA(
          isA<VideoException>()
              .having(
                (e) => e.code,
                'code',
                VideoErrorCode.configuration_required,
              )
              .having(
                (e) => e.messageKey,
                'message',
                LocaleKeys.productionReferenceStorageNotConnected,
              )
              .having((e) => e.field, 'field', 'reference_storage')
              .having(
                (e) => e.detail,
                'application storage diagnosis',
                'Application object storage is not configured for reference uploads.',
              ),
        ),
      );
    },
  );
  test(
    'concurrent references share one upload and preserve media metadata',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      var uploads = 0;
      final storage = service(({
        required file,
        required sha256,
        required mimeType,
        required fileSize,
      }) async {
        uploads++;
        expect(
          sha256,
          equals(
            '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
          ),
        );
        expect(mimeType, 'image/png');
        expect(fileSize, 3);
        if (!started.isCompleted) {
          started.complete();
        }
        await gate.future;
        return (url: 'https://storage.example/input', expiresAt: null);
      });
      final first = storage.ensure(input, file);
      await started.future;
      final second = storage.ensure(input, file);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      gate.complete();
      final results = await Future.wait([first, second]);
      expect(uploads, 1);
      expect(
        results.every(
          (r) => r.mediaInfo.width == 320 && r.mediaInfo.height == 240,
        ),
        isTrue,
      );
      await storage.ensure(input, file);
      expect(uploads, 2);
    },
  );
  test(
    'failed upload does not poison a retry and hashes current bytes',
    () async {
      var calls = 0;
      final storage = service(({
        required file,
        required sha256,
        required mimeType,
        required fileSize,
      }) async {
        calls++;
        if (calls == 1) {
          throw const SocketException('upload failed');
        }
        expect(sha256, crypto.sha256.convert([4, 5, 6]).toString());
        return (
          url: 'https://storage.example/input',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        );
      });
      await expectLater(
        storage.ensure(input, file),
        throwsA(isA<SocketException>()),
      );
      await file.writeAsBytes([4, 5, 6]);
      expect(
        (await storage.ensure(input, file)).url,
        'https://storage.example/input',
      );
    },
  );
  for (final result in <ReferenceUploadResult>[
    (url: 'file:///private/input', expiresAt: null),
    (url: 'https://user:secret@storage.example/input', expiresAt: null),
    (url: 'https://storage.example/input', expiresAt: DateTime.utc(2000)),
  ]) {
    test(
      'rejects invalid or expired storage result ${result.url} ${result.expiresAt}',
      () async {
        final storage = service(
          ({
            required file,
            required sha256,
            required mimeType,
            required fileSize,
          }) async => result,
        );
        await expectLater(
          storage.ensure(input, file),
          throwsA(
            isA<VideoException>().having(
              (e) => e.code,
              'code',
              VideoErrorCode.invalid_response,
            ),
          ),
        );
      },
    );
  }
  final provider = aiProviderBuiltinById(
    'openai',
  )!.copyWith(type: 'volcengine', apiKey: 'key');
  for (final (role, mime) in [
    (VideoInputRole.reference_image, 'image/png'),
    (VideoInputRole.reference_audio, 'audio/mpeg'),
  ]) {
    test('no OSS or channel upload sends $mime inline', () async {
      await db.aiProviderDao.upsert(provider);
      final storage = service(null);
      final source = VideoInput(role: role, assetId: 'a', mimeType: mime);
      expect(
        await storage.preflight(providerId: provider.id, inputs: [source]),
        isTrue,
      );
      final ref = await storage.ensure(source, file, provider: provider);
      expect(ref.url, 'data:$mime;base64,AQID');
      expect(isVideoInlineReference(ref), isTrue);
      expect(Uri.parse(ref.url).data!.contentAsBytes(), [1, 2, 3]);
      expect(ref.fileSize, 3);
    });
  }
  test(
    'mixed image and video fails before reading or sending any reference',
    () async {
      final storage = ReferenceStorageService(
        database: db,
        storage: FakeObjectStorage(db, null),
        probe: (_, {cancellation}) async => throw StateError('must not probe'),
      );
      const video = VideoInput(
        role: VideoInputRole.reference_video,
        assetId: 'v',
        mimeType: 'video/mp4',
      );
      await db.aiProviderDao.upsert(provider);
      expect(
        await storage.preflight(
          providerId: provider.id,
          inputs: [input, video],
        ),
        isFalse,
      );
      await expectLater(
        storage.prepare([
          (input, file, media),
          (video, file, media),
        ], provider: provider),
        throwsA(
          isA<VideoException>().having(
            (e) => e.code,
            'code',
            VideoErrorCode.configuration_required,
          ),
        ),
      );
    },
  );
  test('OSS failures never switch to inline media', () async {
    final storage = service(({
      required file,
      required sha256,
      required mimeType,
      required fileSize,
    }) async {
      throw const SocketException('offline');
    });
    await expectLater(
      storage.ensure(input, file, provider: provider),
      throwsA(isA<SocketException>()),
    );
  });
  test('batch uses a single OSS configuration snapshot', () async {
    var uploads = 0;
    final oss = FakeObjectStorage(db, ({
      required file,
      required sha256,
      required mimeType,
      required fileSize,
    }) async {
      uploads++;
      return (url: 'https://storage.example/$uploads', expiresAt: null);
    });
    final storage = ReferenceStorageService(
      database: db,
      storage: oss,
      probe: (_, {cancellation}) async => const MediaInfo(
        duration: Duration.zero,
        hasAudio: false,
        hasVideo: true,
      ),
    );
    final refs = await storage.prepare([
      (input, file, media),
      (input, file, media),
    ], provider: provider);
    expect(oss.loads, 1);
    expect(
      refs.every((r) => r.url.startsWith('https://storage.example/')),
      isTrue,
    );
  });
  test(
    'oversized inline batch is rejected before loading files into memory',
    () async {
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(26 * 1024 * 1024);
      await handle.close();
      await expectLater(
        service(null).prepare([
          (input, file, media),
          (input, file, media),
        ], provider: provider),
        throwsA(
          isA<VideoException>().having((e) => e.field, 'field', 'file_size'),
        ),
      );
    },
  );
  group('image preparation without a media runtime', () {
    final provider = aiProviderBuiltinById('openai')!;
    late ReferenceStorageService references;
    late PluginFileScope scope;
    late int uploads;
    late File png;

    setUp(() async {
      uploads = 0;
      references = ReferenceStorageService(
        database: db,
        storage: FakeObjectStorage(db, ({
          required file,
          required sha256,
          required mimeType,
          required fileSize,
        }) async {
          uploads++;
          return (url: 'https://storage.example/image', expiresAt: null);
        }),
        probe: (_, {cancellation}) async =>
            throw UnsupportedError('Desktop media runtime unavailable'),
      );
      scope = PluginFileScope(
        pluginId: provider.type,
        providerId: provider.id,
        taskId: 'image-preparation',
      );
      png = await File(
        '${directory.path}/valid.png',
      ).writeAsBytes(img.encodePng(img.Image(width: 2, height: 3)));
    });

    tearDown(() {
      scope.revoke();
      references.dispose();
    });

    test('prepares PNG and GIF references without probing video', () async {
      final gif = await File(
        '${directory.path}/reference',
      ).writeAsBytes(img.encodeGif(img.Image(width: 4, height: 3)));
      final prepared = await references.prepareImages(
        [
          (const ProductionImageReference(assetId: 'png'), png, 'image/png'),
          (const ProductionImageReference(assetId: 'gif'), gif, 'image/gif'),
        ],
        provider: provider,
        transport: ImageReferenceTransport.file,
        files: scope,
        taskId: scope.taskId,
      );
      expect(prepared.map((image) => image['assetId']), ['png', 'gif']);
      expect(prepared.map((image) => image['source']['kind']), [
        'file',
        'file',
      ]);
    });

    test('rejects an invalid image before uploading any reference', () async {
      await expectLater(
        references.prepareImages(
          [
            (
              const ProductionImageReference(assetId: 'valid'),
              png,
              'image/png',
            ),
            (
              const ProductionImageReference(assetId: 'invalid'),
              file,
              'image/png',
            ),
          ],
          provider: provider,
          transport: ImageReferenceTransport.url,
          files: scope,
          taskId: scope.taskId,
        ),
        throwsA(
          isA<VideoException>().having(
            (error) => error.field,
            'field',
            'reference_image',
          ),
        ),
      );
      expect(uploads, 0);
    });

    test('cancellation during preparation stops before upload', () async {
      final cancellation = AgentCancellationController();
      final pending = references.prepareImages(
        [(const ProductionImageReference(assetId: 'asset'), png, 'image/png')],
        provider: provider,
        transport: ImageReferenceTransport.url,
        files: scope,
        taskId: scope.taskId,
        cancellation: cancellation.token,
      );
      cancellation.cancel();
      await expectLater(
        pending,
        throwsA(
          isA<PluginHostError>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect(uploads, 0);
    });

    test(
      'cancellation while loading unconfigured storage still reports cancelled',
      () async {
        final cancellation = AgentCancellationController();
        final unconfigured = ReferenceStorageService(
          database: db,
          storage: FakeObjectStorage(db, null),
          probe: (_, {cancellation}) async =>
              throw UnsupportedError('Desktop media runtime unavailable'),
        );
        addTearDown(unconfigured.dispose);
        final pending = unconfigured.prepareImages(
          [
            (
              const ProductionImageReference(assetId: 'asset'),
              png,
              'image/png',
            ),
          ],
          provider: provider,
          transport: ImageReferenceTransport.url,
          files: scope,
          taskId: scope.taskId,
          cancellation: cancellation.token,
        );
        cancellation.cancel();
        await expectLater(
          pending,
          throwsA(
            isA<PluginHostError>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
      },
    );

    test(
      'uploaded transport rejects oversized reference before reading image bytes',
      () async {
        final purefox = provider.copyWith(type: 'purefox_media', apiKey: 'key');
        final oversized = File('${directory.path}/oversized.png');
        final handle = await oversized.open(mode: FileMode.write);
        await handle.truncate(21 * 1024 * 1024);
        await handle.close();
        await expectLater(
          references.prepareImages(
            [
              (
                const ProductionImageReference(assetId: 'oversized'),
                oversized,
                'image/png',
              ),
            ],
            provider: purefox,
            transport: ImageReferenceTransport.uploaded,
            files: scope,
            taskId: scope.taskId,
          ),
          throwsA(
            isA<VideoException>()
                .having((e) => e.code, 'code', VideoErrorCode.invalid_request)
                .having((e) => e.field, 'field', 'reference_upload')
                .having((e) => e.detail, 'detail', 'file'),
          ),
        );
      },
    );

    test(
      'readImageDimensions returns null for missing or over-limit files',
      () async {
        expect(await readImageDimensions(png), (2, 3));
        expect(await readImageDimensions(png, maxBytes: 1), isNull);
        expect(
          await readImageDimensions(File('${directory.path}/missing.png')),
          isNull,
        );
      },
    );
  });
}
