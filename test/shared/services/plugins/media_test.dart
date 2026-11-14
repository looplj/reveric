// 职责: 用文件夹具验证媒体字节绑定、图片提取、错误正文及输出归属。
// 关联文件:
//   lib/shared/services/plugins/media.dart
//   lib/shared/services/plugins/media_files.dart
import 'dart:convert';
import 'package:reveric/shared/models/video/request.dart'
    show videoInlineRequestMaxBytes;
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/services/plugins/files.dart';
import 'package:reveric/shared/services/plugins/media.dart';
import 'package:reveric/shared/services/plugins/media_files.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late PluginFileScope scope;
  late PluginMediaFiles outputs;
  late PluginMediaApi api;
  late String handle;
  final png = img.encodePng(img.Image(width: 2, height: 3));
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plugin-media-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    scope = PluginFileScope(
      pluginId: 'p',
      providerId: 'instance',
      taskId: 'task',
    );
    final info = await scope.register(
      await File('${directory.path}/input').writeAsBytes(png),
      name: 'input.png',
      mimeType: 'image/png',
    );
    handle = info['handle'] as String;
    scope.claim(pluginId: 'p', providerId: 'instance', taskId: 'task');
    outputs = PluginMediaFiles(
      directory: Directory('${directory.path}/outputs'),
      scope: scope,
    );
    api = PluginMediaApi(
      scope: scope,
      outputs: outputs,
      clientFactory: HttpClient.new,
      remainingBudget: () => const Duration(seconds: 2),
    );
  });
  tearDown(() async {
    api.cancel();
    scope.revoke();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  Map<String, dynamic> request({
    Object? body,
    Object? response,
    int? timeoutMs,
  }) => {
    'url': 'http://127.0.0.1:${server.port}/generate',
    'request': {
      'method': 'POST',
      'timeoutMs': ?timeoutMs,
      'body': body ?? {'kind': 'json', 'value': <String, dynamic>{}},
      'response': response ?? {'kind': 'json'},
    },
  };
  for (final grewAfterRegistration in [false, true]) {
    test(
      'video rejects encoded JSON beyond limit before HTTP, grew=$grewAfterRegistration',
      () async {
        final file = File('${directory.path}/boundary.bin');
        final rawSize = videoInlineRequestMaxBytes ~/ 4 * 3;
        var writer = await file.open(mode: FileMode.write);
        await writer.truncate(grewAfterRegistration ? 1 : rawSize);
        await writer.close();
        final boundaryScope = PluginFileScope(
          pluginId: 'p',
          providerId: 'instance',
          taskId: 'boundary',
        );
        final info = await boundaryScope.register(
          file,
          name: 'boundary.png',
          mimeType: 'image/png',
        );
        expect(
          ((info['size'] as int) + 2) ~/ 3 * 4,
          lessThanOrEqualTo(videoInlineRequestMaxBytes),
        );
        if (grewAfterRegistration) {
          writer = await file.open(mode: FileMode.append);
          await writer.truncate(rawSize);
          await writer.close();
        }
        boundaryScope.claim(
          pluginId: 'p',
          providerId: 'instance',
          taskId: 'boundary',
        );
        final video = PluginMediaApi(
          scope: boundaryScope,
          video: true,
          clientFactory: HttpClient.new,
          remainingBudget: () => const Duration(seconds: 60),
        );
        addTearDown(() {
          video.cancel();
          boundaryScope.revoke();
        });
        var requests = 0;
        server.listen((r) async {
          requests++;
          await r.drain<void>();
          r.response.write('{}');
          await r.response.close();
        });
        final outcome = await video
            .request(
              request(
                body: {
                  'kind': 'json',
                  'value': {'reference': null, 'extra': '中文'},
                  'files': [
                    {
                      'pointer': '/reference',
                      'handle': info['handle'],
                      'encoding': 'data_uri',
                    },
                  ],
                },
              ),
            )
            .then<Object?>((value) => value, onError: (Object error) => error);
        expect(
          requests,
          0,
          reason:
              'JSON syntax, data URI and extra fields exceed the full request limit',
        );
        expect(
          outcome,
          isA<PluginHostError>().having(
            (e) => e.code,
            'code',
            'invalid_request',
          ),
        );
      },
    );
  }
  test(
    'video requests bind files but reject image extraction and long timeout',
    () async {
      final video = PluginMediaApi(
        scope: scope,
        video: true,
        clientFactory: HttpClient.new,
        remainingBudget: () => const Duration(seconds: 2),
      );
      addTearDown(video.cancel);
      var requests = 0;
      server.listen((r) async {
        requests++;
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        expect(body['reference'], 'data:image/png;base64,${base64Encode(png)}');
        r.response.write('{"id":"video"}');
        await r.response.close();
      });
      for (final response in [
        {'kind': 'file'},
        {'kind': 'json', 'images': []},
      ]) {
        await expectLater(
          video.request(request(response: response)),
          throwsA(isA<PluginHostError>()),
        );
      }
      final tooLong = request();
      (tooLong['request'] as Map)['timeoutMs'] = 300001;
      await expectLater(
        video.request(tooLong),
        throwsA(isA<PluginHostError>()),
      );
      expect(requests, 0);
      final result = await video.request(
        request(
          timeoutMs: 300000,
          body: {
            'kind': 'json',
            'value': {'reference': null},
            'files': [
              {
                'pointer': '/reference',
                'handle': handle,
                'encoding': 'data_uri',
              },
            ],
          },
        ),
      );
      expect(result['body'], {'id': 'video'});
      expect(requests, 1);
    },
  );
  test(
    'JSON binding stays in Host and output has persisted ownership',
    () async {
      server.listen((r) async {
        final input = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        expect(input['image'], 'data:image/png;base64,${base64Encode(png)}');
        r.response.write(
          jsonEncode({
            'data': [
              {'b64': base64Encode(png)},
            ],
            'metadata': 'kept',
          }),
        );
        await r.response.close();
      });
      final result = await api.request(
        request(
          body: {
            'kind': 'json',
            'value': {'image': null},
            'files': [
              {'pointer': '/image', 'handle': handle, 'encoding': 'data_uri'},
            ],
          },
          response: {
            'kind': 'json',
            'images': [
              {'pointer': '/data/0/b64', 'encoding': 'base64'},
            ],
          },
        ),
      );
      final body = result['body'] as Map;
      expect(body['metadata'], 'kept');
      final output = body['data'][0]['b64'] as Map;
      expect(output['kind'], 'file');
      expect(await outputs.output(output['handle']).readAsBytes(), png);
      final record = jsonDecode(
        await File(
          '${outputs.directory.path}/${output['handle']}.json',
        ).readAsString(),
      );
      expect(record['taskId'], 'task');
      expect(record['providerId'], 'instance');
      expect(record['confirmed'], false);
      expect(() => outputs.output(handle), throwsA(isA<PluginHostError>()));
    },
  );
  test(
    'multipart keeps repeated field order and binary result becomes a file',
    () async {
      server.listen((r) async {
        final body = latin1.decode(
          await r.fold<List<int>>([], (a, b) => a..addAll(b)),
        );
        expect(
          body.indexOf('filename="first.png"'),
          lessThan(body.indexOf('filename="second.png"')),
        );
        expect('name="image[]"'.allMatches(body), hasLength(2));
        r.response.add(png);
        await r.response.close();
      });
      final result = await api.request(
        request(
          body: {
            'kind': 'multipart',
            'fields': {'prompt': 'hello'},
            'files': [
              {'field': 'image[]', 'handle': handle, 'name': 'first.png'},
              {'field': 'image[]', 'handle': handle, 'name': 'second.png'},
            ],
          },
          response: {'kind': 'file'},
        ),
      );
      expect(
        await outputs.output((result['body'] as Map)['handle']).readAsBytes(),
        png,
      );
    },
  );
  test(
    'non-success returns diagnostic text without interpreting image selectors',
    () async {
      server.listen((r) async {
        await r.drain<void>();
        r.response.statusCode = 400;
        r.response.write('<html>failed</html>');
        await r.response.close();
      });
      final result = await api.request(
        request(
          response: {
            'kind': 'json',
            'images': [
              {'pointer': '/missing', 'encoding': 'base64'},
            ],
          },
        ),
      );
      expect(result['body'], '<html>failed</html>');
      expect(await outputs.directory.exists(), false);
    },
  );
  test(
    'invalid pointers fail before sending and malformed images never stage',
    () async {
      var sent = 0;
      server.listen((r) async {
        sent++;
        await r.drain<void>();
        r.response.write('not an image');
        await r.response.close();
      });
      await expectLater(
        api.request(
          request(
            body: {
              'kind': 'json',
              'value': {'image': null},
              'files': [
                {'pointer': '/missing', 'handle': handle, 'encoding': 'base64'},
              ],
            },
          ),
        ),
        throwsA(
          isA<PluginHostError>().having(
            (e) => e.code,
            'code',
            'invalid_request',
          ),
        ),
      );
      expect(sent, 0);
      await expectLater(
        api.request(request(response: {'kind': 'file'})),
        throwsA(
          isA<PluginHostError>().having(
            (e) => e.code,
            'code',
            'invalid_response',
          ),
        ),
      );
      expect(await outputs.directory.exists(), false);
    },
  );
  test(
    'response deadline and cancellation never mint an output handle',
    () async {
      final received = Completer<void>();
      server.listen((r) async {
        await r.drain<void>();
        if (!received.isCompleted) {
          received.complete();
        }
      });
      final arguments = request(response: {'kind': 'file'});
      (arguments['request'] as Map)['timeoutMs'] = 30;
      await expectLater(
        api.request(arguments),
        throwsA(
          isA<PluginHostError>().having((e) => e.code, 'code', 'timeout'),
        ),
      );
      await received.future;
      expect(await outputs.directory.exists(), false);
      final waiting = api.request(request(response: {'kind': 'file'}));
      final assertion = expectLater(
        waiting,
        throwsA(
          isA<PluginHostError>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      api.cancel();
      await assertion;
      expect(await outputs.directory.exists(), false);
    },
  );
}
