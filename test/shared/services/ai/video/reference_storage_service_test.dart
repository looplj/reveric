// 职责: 验证参考素材存储未配置提示、内容哈希、并发上传合并及失败重试边界。
// 关联文件:
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart
import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';

void main() {
  late Directory directory;
  late File file;
  final input = VideoInput(
    role: VideoInputRole.reference_image,
    assetId: 'input',
    mimeType: 'image/png',
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('reference-storage-');
    file = await File('${directory.path}/input.png').writeAsBytes([1, 2, 3]);
  });
  tearDown(() async => directory.delete(recursive: true));
  ReferenceStorageService service(ReferenceUploader? upload) =>
      ReferenceStorageService(
        resolveUpload: () async => upload,
        probe: (_) async => const MediaInfo(
          duration: Duration.zero,
          hasAudio: false,
          hasVideo: true,
          width: 320,
          height: 240,
        ),
      );
  test(
    'unconfigured storage fails before probing or sending local bytes',
    () async {
      final storage = ReferenceStorageService(
        probe: (_) async => throw StateError('must not probe'),
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
        return (
          url: Uri.parse('https://storage.example/input'),
          expiresAt: null,
        );
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
          url: Uri.parse('https://storage.example/input'),
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        );
      });
      await expectLater(
        storage.ensure(input, file),
        throwsA(isA<SocketException>()),
      );
      await file.writeAsBytes([4, 5, 6]);
      expect((await storage.ensure(input, file)).url.host, 'storage.example');
    },
  );
  for (final result in <ReferenceUploadResult>[
    (url: Uri.parse('file:///private/input'), expiresAt: null),
    (
      url: Uri.parse('https://user:secret@storage.example/input'),
      expiresAt: null,
    ),
    (
      url: Uri.parse('https://storage.example/input'),
      expiresAt: DateTime.utc(2000),
    ),
  ]) {
    test(
      'rejects invalid or expired storage result ${result.url.scheme} ${result.expiresAt}',
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
}
