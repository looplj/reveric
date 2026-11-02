// 职责: 验证日志上传保留原始内容、正确打包崩溃记录，并报告失败。
// 关联文件:
//   lib/shared/services/diagnostics_upload_orchestrator.dart
//   lib/shared/services/anonymous_file_service.dart
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/services/anonymous_file_service.dart';
import 'package:reveric/shared/services/diagnostics_upload_orchestrator.dart';

void main() {
  late Directory directory;
  late File log;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('diagnostics_upload_');
    Directory('${directory.path}/logs').createSync();
    log = File('${directory.path}/logs/latest.log')..writeAsStringSync('原始日志');
  });
  tearDown(() => directory.deleteSync(recursive: true));
  for (final withDump in [false, true]) {
    test('uploads original log with dump=$withDump', () async {
      if (withDump) {
        Directory('${directory.path}/crashes').createSync();
        File(
          '${directory.path}/crashes/crash_test.dmp',
        ).writeAsBytesSync([1, 2, 3]);
      }
      final client = MockClient((request) async {
        if (withDump) {
          expect(request.headers['Content-Type'], 'application/zip');
          final archive = ZipDecoder().decodeBytes(request.bodyBytes);
          expect(archive.files.map((f) => f.name), [
            'latest.log',
            'latest.dump',
          ]);
          expect(archive.findFile('latest.dump')!.content, [1, 2, 3]);
          expect(
            archive.findFile('latest.log')!.content,
            log.readAsBytesSync(),
          );
        } else {
          expect(request.headers['Content-Type'], 'text/plain');
          expect(request.bodyBytes, log.readAsBytesSync());
        }
        return http.Response('{"upload_id":"test-report"}', 201);
      });
      addTearDown(client.close);
      final result = await DiagnosticsUploadOrchestrator().upload(
        logPath: log.path,
        uploadService: AnonymousFileService(
          createClient: () => client,
          baseUrl: 'https://example.com',
        ),
      );
      expect(result.success, true);
      expect(log.existsSync(), true);
    });
  }
  test('rate limit failure is reported and preserves local log', () async {
    final client = MockClient(
      (_) async => http.Response('{"error":"rate_limited"}', 429),
    );
    addTearDown(client.close);
    final result = await DiagnosticsUploadOrchestrator().upload(
      logPath: log.path,
      uploadService: AnonymousFileService(
        createClient: () => client,
        baseUrl: 'https://example.com',
      ),
    );
    expect(result.success, false);
    expect(log.existsSync(), true);
  });
}
