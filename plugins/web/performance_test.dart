// 职责: 用真实网页快照测量正式 WebFetch 在原生 fjs 中的转换耗时和进程内存。
// 关联文件:
//   plugins/web/src/fetch.ts
//   lib/shared/services/plugins/runtime.dart
import 'dart:convert';
import 'dart:io';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

void main() {
  test('large real HTML conversion baseline', () async {
    final library = Platform.environment['FJS_PROBE_LIBRARY'];
    final path = Platform.environment['WEB_PERF_HTML'];
    if (library == null || path == null) {
      throw StateError('Set FJS_PROBE_LIBRARY and WEB_PERF_HTML');
    }
    await LibFjs.init(externalLibrary: ExternalLibrary.open(library));
    final html = await File(path).readAsString();
    final htmlBytes = utf8.encode(html).length;
    expect(htmlBytes, lessThanOrEqualTo(5 * 1024 * 1024));
    final samples = int.parse(Platform.environment['WEB_PERF_SAMPLES'] ?? '5');
    expect(samples, inInclusiveRange(1, 10));
    final url =
        Platform.environment['WEB_PERF_URL'] ??
        'https://en.wikipedia.org/wiki/2020_United_States_presidential_election';
    final manifest = PluginManifest.fromJson(
      jsonDecode(
            await File('assets/plugins/reveric.web/plugin.json').readAsString(),
          )
          as Map<String, dynamic>,
    );
    final code = await File(
      'assets/plugins/reveric.web/dist/index.js',
    ).readAsString();
    PluginRuntime runtime() => PluginRuntime(
      hostCall: (method, args) async {
        if (method.startsWith('log.')) {
          return null;
        }
        if (method != 'http.fetch') {
          throw StateError('Unexpected $method');
        }
        return {
          'status': 200,
          'url': url,
          'headers': {'content-type': 'text/html'},
          'body': html,
        };
      },
    );
    final activation = Stopwatch()..start();
    final definitions = await runtime().activate(manifest, code);
    final activationUs = activation.elapsedMicroseconds;
    final times = <int>[], rss = <int>[];
    for (var i = 0; i < samples; i++) {
      final watch = Stopwatch()..start();
      final result = await runtime().invoke(
        manifest,
        code,
        definitions,
        'WebFetch',
        {'url': url},
        'perf-$i',
        null,
      );
      times.add(watch.elapsedMicroseconds);
      rss.add(ProcessInfo.currentRss);
      expect(result['ok'], true, reason: result.toString());
      expect(result['format'], 'markdown');
      expect((result['content'] as String).length, greaterThan(1000));
    }
    times.sort();
    stdout.writeln(
      'WEB_NATIVE_PERF ${jsonEncode({'url': url, 'html_bytes': htmlBytes, 'bundle_bytes': utf8.encode(code).length, 'activation_us': activationUs, 'samples': times.length, 'p50_us': times[times.length ~/ 2], 'p95_us': times.last, 'max_us': times.last, 'rss_bytes': rss, 'max_rss_bytes': ProcessInfo.maxRss})}',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
