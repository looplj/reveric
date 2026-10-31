// 职责: 在原生 Flutter profile 构建采集插件更新、桥接、首帧和百次开关内存基线。
// 关联文件:
//   plugins/sdk/fixtures/performance.tsx
//   lib/shared/services/plugins/ui_session.dart
//   lib/shared/widgets/plugin_view/surface.dart
import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline, Service;
import 'dart:isolate';
import 'dart:io';
import 'dart:ui' show FrameTiming, FramePhase;
import 'package:easy_localization/easy_localization.dart';
import 'package:fjs/fjs.dart' as fjs;
import 'package:reveric/shared/services/javascript.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/models/plugin/ui_tree.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import 'package:reveric/shared/services/plugins/ui_session.dart';
import 'package:reveric/shared/widgets/plugin_view/surface.dart';
import '../test/shared/widgets/plugin_view/input_test.dart' show wrap;

Future<void> ready(PluginUiSession page, bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!predicate()) {
    if (page.error.value != null) {
      throw StateError(page.error.value!);
    }
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Performance fixture');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Map<String, Object> stats(List<int> values) {
  final v = [...values]..sort();
  return v.isEmpty
      ? {'samples': 0}
      : {
          'samples': v.length,
          'p50_us': v[(v.length * .5).floor()],
          'p95_us': v[((v.length - 1) * .95).ceil()],
          'max_us': v.last,
        };
}

Future<Map<String, dynamic>> collectHeap() async {
  final info = await Service.getInfo();
  final uri = info.serverUri;
  final isolateId = Service.getIsolateId(Isolate.current);
  if (uri == null || isolateId == null) {
    throw StateError('Profile VM service is required for heap measurement');
  }
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      uri
          .resolve('getAllocationProfile')
          .replace(queryParameters: {'isolateId': isolateId, 'gc': 'true'}),
    );
    final response = await request.close();
    final payload =
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
    if (payload['error'] != null) {
      throw StateError('VM heap collection failed: ${payload['error']}');
    }
    return Map<String, dynamic>.from(
      (payload['result'] as Map)['memoryUsage'] as Map,
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => rootBundle.clear());
  testWidgets(
    'plugin runtime performance and repeated disposal',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await EasyLocalization.ensureInitialized();
      await tester.runAsync(initializeJavascript);
      expect(
        fjs.UiSession.resourceCounts().values.every((n) => n == BigInt.zero),
        true,
      );
      final source = await rootBundle.loadString(
        'assets/plugin_preview/performance.js',
      );
      final counter = await rootBundle.loadString(
        'assets/plugin_preview/counter.js',
      );
      var serial = 0;
      Future<PluginUiSession> start(String code) async {
        final session = PluginUiSession(
          tree: PluginUiTree(surface: 'bench-${serial++}', generation: 1),
          hostCall: (method, args) async {
            final key = args['key'];
            if (key is String && key.startsWith('search.')) {
              final n = int.parse(key.substring(7));
              await Future<void>.delayed(
                Duration(milliseconds: n.isEven ? 5 : 60),
              );
            }
            return null;
          },
        );
        await session.start(
          source: code,
          scope: {
            'plugin': {'id': 'test.performance', 'version': '1'},
            'request': {'workId': null},
          },
          environment: {
            'visible': true,
            'width': 500,
            'height': 600,
            'platform': 'macos',
            'theme': 'light',
            'locale': 'en',
          },
        );
        await ready(session, () => session.ready.value);
        return session;
      }

      final frames = <FrameTiming>[];
      void timings(List<FrameTiming> v) => frames.addAll(v);
      binding.addTimingsCallback(timings);
      final cold = Stopwatch()..start();
      final page = (await tester.runAsync(() => start(source)))!;
      final mountUs = cold.elapsedMicroseconds;
      final bridge = <int>[], visible = <int>[];
      final nativeJs = <int>[],
          nativeBatch = <int>[],
          bridgeRemainder = <int>[];
      final events = <({int event, int batch})>[];
      final extra = <PluginUiSession>[];
      final rss = <int>[];
      try {
        await tester.pumpWidget(wrap(PluginUiSurface(session: page)));
        await tester.pumpAndSettle();
        final firstFrameUs = cold.elapsedMicroseconds;
        frames.clear();
        final schedule = Stopwatch()..start();
        final warmStart = Timeline.now;
        for (var i = 1; i <= 60; i++) {
          final button = page.tree.nodes.values.firstWhere(
            (n) => n.props['label'] == 'Update forty',
          );
          final nativeBefore = fjs.UiSession.resourceCounts();
          final eventStamp = Timeline.now;
          int? batchStamp;
          void changed() {
            if (batchStamp == null &&
                page.tree.nodes.values.any(
                  (n) => n.props['text'] == 'Counter $i',
                )) {
              batchStamp = Timeline.now;
            }
          }

          final counterNode = page.tree.nodes.values.firstWhere(
            (n) => n.props['testId'] == 'counter',
          );
          final counterChanges = page.tree.watch(counterNode.id);
          counterChanges.addListener(changed);
          page.dispatch(button, 'onPress', {});
          await tester.runAsync(() => ready(page, () => batchStamp != null));
          counterChanges.removeListener(changed);
          final nativeAfter = fjs.UiSession.resourceCounts();
          final jsUs =
              (nativeAfter['js_reactive_us']! - nativeBefore['js_reactive_us']!)
                  .toInt();
          final flushUs =
              (nativeAfter['native_batch_us']! -
                      nativeBefore['native_batch_us']!)
                  .toInt();
          nativeJs.add(jsUs);
          nativeBatch.add(flushUs);
          bridgeRemainder.add(
            (batchStamp! - eventStamp - jsUs - flushUs).clamp(0, 1000000),
          );
          bridge.add(batchStamp! - eventStamp);
          events.add((event: eventStamp, batch: batchStamp!));
          await tester.pump();
          final waitUs = (i * 1000000 ~/ 30) - schedule.elapsedMicroseconds;
          if (waitUs > 0) {
            await tester.runAsync(
              () => Future<void>.delayed(Duration(microseconds: waitUs)),
            );
          }
        }
        final warmEnd = Timeline.now;
        final searchTimer = Stopwatch()..start();
        for (var i = 0; i < 6; i++) {
          final search = page.tree.nodes.values.firstWhere(
            (n) => n.props['label'] == 'Search next',
          );
          page.dispatch(search, 'onPress', {});
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
        }
        await tester.runAsync(
          () => ready(
            page,
            () => page.tree.nodes.values.any(
              (n) => n.props['text'] == 'Search 6',
            ),
          ),
        );
        final searchUs = searchTimer.elapsedMicroseconds;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        expect(
          page.tree.nodes.values.any((n) => n.props['text'] == 'Search 6'),
          true,
        );
        final reverse = page.tree.nodes.values.firstWhere(
          (n) => n.props['label'] == 'Reverse',
        );
        page.dispatch(reverse, 'onPress', {});
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        // Scroll the fixed-height virtual list into view before exercising its viewport.
        final list = page.tree.nodes.values.firstWhere(
          (n) => n.component == 'List',
        );
        expect(list.props['height'], 180);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -650));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (var i = 0; i < 3; i++) {
          extra.add((await tester.runAsync(() => start(counter)))!);
        }
        final manifest = PluginManifest.fromJson({
          'id': 'test.performance',
          'name': 'Perf',
          'version': '1.0.0',
          'pluginApiVersion': '^1',
          'main': 'index.js',
          'defaultEnabled': true,
        });
        const toolCode =
            "var __revericPlugin={apply(c){c.tools.register({name:'Bench',description:'Fixture',inputSchema:{type:'object'},handler:async()=>({ok:true})});}};";
        final runtime = PluginRuntime(hostCall: (m, a) async => null);
        final definitions = (await tester.runAsync(
          () => runtime.activate(manifest, toolCode),
        ))!;
        final toolTimes = <int>[];
        for (var i = 0; i < 20; i++) {
          final watch = Stopwatch()..start();
          final result = await tester.runAsync(
            () => runtime.invoke(
              manifest,
              toolCode,
              definitions,
              'Bench',
              {},
              'bench-$i',
              null,
            ),
          );
          expect(result!['ok'], true);
          toolTimes.add(watch.elapsedMicroseconds);
        }
        final fourPageRss = ProcessInfo.currentRss;
        await tester.runAsync(runtime.business.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await page.close();
          page.dispose();
          for (final p in extra) {
            await p.close();
            p.dispose();
          }
        });
        final beforeHeap = (await tester.runAsync(collectHeap))!;
        final weakSessions = <WeakReference<PluginUiSession>>[];
        final openings = <int>[];
        for (var i = 0; i < 500; i++) {
          final watch = Stopwatch()..start();
          final session = (await tester.runAsync(() => start(counter)))!;
          weakSessions.add(WeakReference(session));
          await tester.runAsync(session.close);
          session.dispose();
          openings.add(watch.elapsedMicroseconds);
          expect(
            fjs.UiSession.resourceCounts().values.every(
              (n) => n == BigInt.zero,
            ),
            true,
          );
          expect(session.closed, true);
          expect(session.tree.nodes, isEmpty);
          if (i % 50 == 49) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            rss.add(ProcessInfo.currentRss);
          }
        }
        final afterHeap = (await tester.runAsync(collectHeap))!;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        final retainedSessions = weakSessions
            .where((ref) => ref.target != null)
            .length;
        expect(retainedSessions, lessThanOrEqualTo(1));
        final stableFrames = frames
            .where(
              (f) =>
                  f.timestampInMicroseconds(FramePhase.buildStart) >=
                      warmStart &&
                  f.timestampInMicroseconds(FramePhase.buildStart) <= warmEnd,
            )
            .toList();
        final orderedFrames = [...frames]
          ..sort(
            (a, b) => a
                .timestampInMicroseconds(FramePhase.buildStart)
                .compareTo(b.timestampInMicroseconds(FramePhase.buildStart)),
          );
        for (final event in events) {
          final frame = orderedFrames.firstWhere(
            (f) =>
                f.timestampInMicroseconds(FramePhase.buildStart) >= event.batch,
          );
          final latency =
              frame.timestampInMicroseconds(FramePhase.rasterFinish) -
              event.event;
          expect(
            latency,
            inInclusiveRange(0, 1000000),
            reason: 'FrameTiming and Timeline clock alignment',
          );
          visible.add(latency);
        }
        final refreshRate =
            binding.platformDispatcher.views.first.display.refreshRate;
        expect(refreshRate, greaterThan(0));
        final frameBudgetUs = 1000000 / refreshRate;
        final buildStats = stats(
          stableFrames.map((f) => f.buildDuration.inMicroseconds).toList(),
        );
        final rasterStats = stats(
          stableFrames.map((f) => f.rasterDuration.inMicroseconds).toList(),
        );
        binding.reportData = {
          'platform': Platform.operatingSystem,
          'refresh_rate_hz': refreshRate,
          'mode': 'profile',
          'native_mount_us': mountUs,
          'interleaved_search_last_result_us': searchUs,
          'first_frame_us': firstFrameUs,
          'event_to_dart_batch': stats(bridge),
          'native_js_reactive': stats(nativeJs),
          'native_batch_flush': stats(nativeBatch),
          'queue_bridge_dart': stats(bridgeRemainder),
          'event_to_raster_finish': stats(visible),
          'flutter_build': buildStats,
          'flutter_raster': rasterStats,
          'tool_with_four_pages': stats(toolTimes),
          'open_close_500': stats(openings),
          'rss_every_fifty_closes': rss,
          'heap_before_500': beforeHeap,
          'heap_after_500_gc': afterHeap,
          'retained_dart_sessions': retainedSessions,
          'rss_after_gc': ProcessInfo.currentRss,
          'native_resources_after_close': fjs.UiSession.resourceCounts().map(
            (k, v) => MapEntry(k, v.toInt()),
          ),
          'four_pages_rss': fourPageRss,
          'max_rss': ProcessInfo.maxRss,
        };
        stdout.writeln('PLUGIN_PROFILE ${jsonEncode(binding.reportData)}');
        expect(buildStats['p95_us'] as int, lessThanOrEqualTo(frameBudgetUs));
        expect(rasterStats['p95_us'] as int, lessThanOrEqualTo(frameBudgetUs));
        expect(
          stats(visible)['p95_us'] as int,
          lessThanOrEqualTo(frameBudgetUs * 2),
        );
      } finally {
        binding.removeTimingsCallback(timings);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await page.close();
          for (final p in extra) {
            await p.close();
          }
        });
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
