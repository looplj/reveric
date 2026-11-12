// 职责: 验证安装包下载在 GitHub 失败后改用 R2 镜像，取消则不再尝试镜像。
// 关联文件:
//   lib/shared/services/update/update_service.dart
//   lib/shared/services/update/models.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/update.dart';

class _UnusedSource implements UpdateSource {
  @override
  Future<UpdateCheckResult> checkForUpdate(String currentVersion) {
    throw UnimplementedError();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;

  setUp(() async {
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    directory = await Directory.systemTemp.createTemp('update_mirror_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
  });

  tearDown(() async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  });

  test('failed GitHub download retries the R2 mirror', () async {
    final hits = <String>[];
    final primary = await _server(hits, 'primary', statusCode: 502);
    final mirror = await _server(hits, 'mirror', body: 'package');
    addTearDown(() => primary.close(force: true));
    addTearDown(() => mirror.close(force: true));

    final service = UpdateService(source: _UnusedSource());
    await service.init('1.0.0');
    final downloaded = await service.downloadUpdate(
      UpdateInfo(
        version: '2.0.0',
        downloadUrl: 'http://127.0.0.1:${primary.port}/app.zip',
        fallbackDownloadUrl: 'http://127.0.0.1:${mirror.port}/app.zip',
      ),
    );

    expect(downloaded, isTrue);
    expect(hits, ['primary', 'mirror']);
    final extension = Platform.isAndroid ? 'apk' : 'zip';
    expect(
      await File(
        '${directory.path}/reveric_update_2.0.0.$extension',
      ).readAsString(),
      'package',
    );
    expect(service.progress.state, UpdateDownloadState.downloaded);
  });

  test('cancelling the GitHub download does not request the mirror', () async {
    final hits = <String>[];
    final started = Completer<HttpRequest>();
    final primary = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => primary.close(force: true));
    primary.listen((request) {
      hits.add('primary');
      if (!started.isCompleted) {
        started.complete(request);
      }
    });
    final mirror = await _server(hits, 'mirror', body: 'package');
    addTearDown(() => mirror.close(force: true));

    final service = UpdateService(source: _UnusedSource());
    await service.init('1.0.0');
    final download = service.downloadUpdate(
      UpdateInfo(
        version: '2.0.0',
        downloadUrl: 'http://127.0.0.1:${primary.port}/app.zip',
        fallbackDownloadUrl: 'http://127.0.0.1:${mirror.port}/app.zip',
      ),
    );
    final request = await started.future;
    service.cancelDownload();
    await request.response.close();

    expect(await download, isFalse);
    expect(hits, ['primary']);
    expect(service.progress.state, UpdateDownloadState.idle);
  });
}

Future<HttpServer> _server(
  List<String> hits,
  String name, {
  int statusCode = 200,
  String body = '',
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    hits.add(name);
    request.response.statusCode = statusCode;
    request.response.write(body);
    await request.response.close();
  });
  return server;
}
