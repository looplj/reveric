// 职责: 验证 88API 上传协议、凭据隔离、回执确认与失败边界。
// 关联文件:
//   lib/shared/services/ai/uploads/api88.dart
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/uploads/api88.dart';

void main() {
  late Directory dir;
  late File file;
  final provider = aiProviderBuiltinById('api88')!.copyWith(apiKey: 'secret');
  final expiry =
      DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/
      1000;
  Map<String, dynamic> permit() => {
    'url': 'https://read.example/input',
    'upload_url': 'https://write.example/put',
    'method': 'PUT',
    'headers': {'Content-Type': 'image/png', 'X-Media-Upload-Token': 'token'},
    'expires_at': expiry - 1000,
  };
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('api88-test');
    file = await File('${dir.path}/input').writeAsBytes([1, 2, 3]);
  });
  tearDown(() => dir.delete(recursive: true));
  for (final mode in [
    'success',
    'conflict',
    'lost_body',
    'bad_head',
    'head_disconnect',
    'bad_permit',
    'unauthorized',
  ]) {
    test(mode, () async {
      final methods = <String>[];
      final client = MockClient((request) async {
        methods.add(request.method);
        if (request.method == 'POST') {
          expect(request.url.path, '/v1/media/uploads');
          expect(request.headers['Authorization'], 'Bearer secret');
          expect(jsonDecode(request.body), {
            'size': 3,
            'mime_type': 'image/png',
            'sha256': base64Url
                .encode(sha256.convert([1, 2, 3]).bytes)
                .replaceAll('=', ''),
          });
          if (mode == 'unauthorized') {
            return http.Response('{}', 401);
          }
          final data = permit();
          if (mode == 'bad_permit') {
            data.remove('url');
          }
          return http.Response(jsonEncode(data), 200);
        }
        expect(request.headers['Authorization'], isNull);
        if (request.method == 'PUT') {
          expect(request.url.host, 'write.example');
          expect(request.bodyBytes, [1, 2, 3]);
          expect(request.contentLength, 3);
          expect(request.headers['X-Media-Upload-Token'], 'token');
          if (mode == 'lost_body') {
            return http.Response('', 201);
          }
          if (mode == 'conflict' ||
              mode == 'bad_head' ||
              mode == 'head_disconnect') {
            return http.Response('{}', 409);
          }
          return http.Response(
            jsonEncode({
              'url': 'https://read.example/done',
              'size': 3,
              'mime_type': 'image/png',
              'expires_at': expiry,
            }),
            201,
          );
        }
        expect(request.url.host, 'read.example');
        expect(request.headers['X-Media-Upload-Token'], isNull);
        if (mode == 'head_disconnect') {
          throw http.ClientException('offline');
        }
        return http.Response(
          '',
          200,
          headers: {
            'content-length': mode == 'bad_head' ? '4' : '3',
            'content-type': 'image/png',
            'x-media-expires-at': '$expiry',
          },
        );
      });
      final result = Api88UploadOrchestrator().run(
        provider: provider,
        file: file,
        mimeType: 'image/png',
        client: client,
      );
      if ([
        'bad_head',
        'head_disconnect',
        'bad_permit',
        'unauthorized',
      ].contains(mode)) {
        await expectLater(result, throwsA(isA<VideoException>()));
      } else {
        expect(
          (await result).expiresAt!.millisecondsSinceEpoch ~/ 1000,
          expiry,
        );
      }
      expect(methods, [
        'POST',
        if (!['bad_permit', 'unauthorized'].contains(mode)) 'PUT',
        if ([
          'conflict',
          'lost_body',
          'bad_head',
          'head_disconnect',
        ].contains(mode))
          'HEAD',
      ]);
    });
  }
}
