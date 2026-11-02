// 职责: 验证诊断上传遵循当前代理、保留原始内容并正确释放客户端与处理响应。
// 关联文件:
//   lib/shared/services/anonymous_file_service.dart
//   lib/shared/providers/upload_providers.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/models/network_proxy.dart
import 'dart:convert';
import 'dart:io';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/network_proxy.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/upload_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/services/anonymous_file_service.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'en',
    aiSettings: AiSettings.defaults(),
  );
  void changeProxy(NetworkProxy proxy) {
    state = AsyncData(state.requireValue.copyWith(networkProxy: proxy));
  }
}

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test(
    'retained uploader follows changed proxies, authentication and direct mode',
    () async {
      final servers = <HttpServer>[];
      final routes = <int>[];
      final auth = <String?>[];
      for (var i = 0; i < 3; i++) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        servers.add(server);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          routes.add(i);
          auth.add(request.headers.value(HttpHeaders.proxyAuthorizationHeader));
          expect(await utf8.decoder.bind(request).join(), '原始日志');
          request.response.statusCode = 201;
          request.response.write(jsonEncode({'upload_id': 'route-$i'}));
          await request.response.close();
        });
      }
      final container = ProviderContainer(
        overrides: [appSettingsProvider.overrideWith(_Settings.new)],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      final settings =
          container.read(appSettingsProvider.notifier) as _Settings;
      final production = container.read(anonymousUploadServiceProvider);
      final service = AnonymousFileService(
        createClient: production.createClient,
        baseUrl: 'http://127.0.0.1:${servers[2].port}',
      );
      for (var i = 0; i < 3; i++) {
        settings.changeProxy(
          i == 2
              ? const NetworkProxy(mode: NetworkProxyMode.direct)
              : NetworkProxy(
                  mode: NetworkProxyMode.custom,
                  url: 'http://127.0.0.1:${servers[i].port}',
                  username: 'test',
                  password: 'pass$i',
                ),
        );
        final result = await service.upload(
          namespace: 'diagnostics',
          fileBytes: utf8.encode('原始日志'),
          contentType: 'text/plain',
        );
        expect(result.uploadId, 'route-$i');
      }
      expect(routes, [0, 1, 2]);
      expect(auth, [
        'Basic ${base64Encode(utf8.encode('test:pass0'))}',
        'Basic ${base64Encode(utf8.encode('test:pass1'))}',
        null,
      ]);
    },
  );

  for (final fails in [false, true]) {
    test('closes each operation client when transport fails=$fails', () async {
      final clients = <_TrackedClient>[];
      final service = AnonymousFileService(
        baseUrl: 'https://diagnostics.example',
        createClient: () {
          final client = _TrackedClient((_) async {
            if (fails) {
              throw const SocketException('test connection failure');
            }
            return http.Response('{"upload_id":"report"}', 201);
          });
          clients.add(client);
          return client;
        },
      );
      for (var i = 0; i < 2; i++) {
        final upload = service.upload(
          namespace: 'diagnostics',
          fileBytes: [1],
          contentType: 'text/plain',
        );
        if (fails) {
          await expectLater(upload, throwsException);
        } else {
          await upload;
        }
      }
      expect(clients, hasLength(2));
      expect(clients.every((client) => client.closed), true);
    });
  }

  test('uploads original session JSON and returns the server ID', () async {
    final bytes = utf8.encode('{"messages":[{"content":"原始对话"}]}');
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://diagnostics.example/v1/diagnostics',
      );
      expect(request.bodyBytes, bytes);
      expect(request.headers['Content-Type'], 'application/json');
      return http.Response('{"upload_id":"report-1"}', 201);
    });
    final service = AnonymousFileService(
      createClient: () => client,
      baseUrl: 'https://diagnostics.example',
    );
    final result = await service.upload(
      namespace: 'diagnostics',
      fileBytes: bytes,
      contentType: 'application/json',
    );
    expect(result.uploadId, 'report-1');
    expect(result.success, true);
    client.close();
  });
  for (final status in [429, 500]) {
    test('HTTP $status is not reported as success', () async {
      final client = MockClient(
        (_) async => http.Response('{"error":"failed"}', status),
      );
      final service = AnonymousFileService(
        createClient: () => client,
        baseUrl: 'https://diagnostics.example',
      );
      await expectLater(
        service.upload(
          namespace: 'diagnostics',
          fileBytes: [1],
          contentType: 'text/plain',
        ),
        throwsException,
      );
      client.close();
    });
  }
  test('invalid success response fails', () async {
    final client = MockClient((_) async => http.Response('{}', 201));
    final service = AnonymousFileService(
      createClient: () => client,
      baseUrl: 'https://diagnostics.example',
    );
    await expectLater(
      service.upload(
        namespace: 'diagnostics',
        fileBytes: [1],
        contentType: 'text/plain',
      ),
      throwsFormatException,
    );
    client.close();
  });
}
