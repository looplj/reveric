// 职责: 验证 Host 结果下载的逐项鉴权与每次重定向剥离规则。
// 关联文件:
//   lib/shared/services/ai/image/output.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/generation/provider_result.dart';
import 'package:reveric/shared/services/ai/image/output.dart';

void main() {
  test(
    'download sends output headers only on the original URL including same-origin redirect',
    () async {
      final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String?>[];
      first.listen((request) async {
        seen.add(request.headers.value('x-download-token'));
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          request.uri.path == '/original'
              ? '/same'
              : 'http://127.0.0.1:${second.port}/final',
        );
        await request.response.close();
      });
      second.listen((request) async {
        seen.add(request.headers.value('x-download-token'));
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      final outputs = ImageOutputContext(aiProviderBuiltinById('openai')!);
      addTearDown(() async {
        outputs.cancel();
        await first.close(force: true);
        await second.close(force: true);
      });
      final data = await outputs.download(
        ProviderUrlOutput(
          'http://127.0.0.1:${first.port}/original',
          headers: {'X-Download-Token': 'private'},
        ),
      );
      expect(data, [1, 2, 3]);
      expect(seen, ['private', null, null]);
    },
  );
}
