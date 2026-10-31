// 职责: 用真实 fjs 验证任务注册、五分钟总预算与两秒连续 JS 预算分离。
// 关联文件:
//   lib/shared/services/plugins/runtime.dart
//   third/fjs/libfjs/src/runtime/driver.rs
import 'dart:async';
import 'dart:io';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

final manifest = PluginManifest.fromJson({
  'id': 'test.task',
  'name': 'Task',
  'version': '1.0.0',
  'pluginApiVersion': '^1',
  'tasks': {
    'organize': {'title': 'Organize', 'intervalMinutes': 60},
  },
  'main': 'index.js',
});
String source(String body) =>
    "var __revericPlugin={apply(setup){setup.tasks.register('organize',async(context)=>{$body});}};";
const run = {'runId': 'run1', 'trigger': 'manual', 'scheduledAt': 0};
void main() {
  setUpAll(() async {
    final path = Platform.environment['FJS_PROBE_LIBRARY'];
    if (path == null) {
      throw StateError('Set FJS_PROBE_LIBRARY');
    }
    await LibFjs.init(externalLibrary: ExternalLibrary.open(path));
  });
  test('direct budget baseline before and after a Dart bridge await', () async {
    for (final script in [
      'while(true){}',
      "await fjs.bridge_call('wait');while(true){}",
    ]) {
      final engine = await JsEngine.create();
      await engine.init(bridge: (_) async => JsResult.ok(JsValue.string('ok')));
      await engine.setExecutionTimeLimit(limitMillis: 40);
      final clock = Stopwatch()..start();
      try {
        await expectLater(
          engine
              .eval(source: JsCode.code(script))
              .timeout(const Duration(seconds: 2)),
          throwsA(isA<JsError_Timeout>()),
        );
        expect(clock.elapsedMilliseconds, lessThan(1000), reason: script);
      } finally {
        try {
          await engine.close();
        } catch (error) {
          expect(error.toString(), contains('interrupted'));
        }
      }
    }
  });
  test(
    'task Host waits may exceed two seconds under the five-minute total budget',
    () async {
      final runtime = PluginRuntime(
        hostCall: (method, args) async {
          await Future<void>.delayed(const Duration(milliseconds: 2200));
          return {'text': 'finished'};
        },
      );
      expect(runtime.taskTimeout, const Duration(minutes: 5));
      final code = source(
        "const response=await context.ai.generateText({system:'test',prompt:'test'});return {summary:context.runId+':'+response.text};",
      );
      final definitions = await runtime.activate(manifest, code);
      expect(definitions.single['kind'], 'task');
      expect(
        await runtime.runTask(
          manifest,
          code,
          definitions,
          'organize',
          run,
          AgentCancellationController().token,
        ),
        'run1:finished',
      );
    },
  );
  test(
    'continuous CPU is interrupted by native budget before total task timeout',
    () async {
      final runtime = PluginRuntime(hostCall: (_, _) async => null);
      final code = source('while(true){}');
      final definitions = await runtime.activate(manifest, code);
      final cancellation = AgentCancellationController();
      final clock = Stopwatch()..start();
      await expectLater(
        runtime
            .runTask(
              manifest,
              code,
              definitions,
              'organize',
              run,
              cancellation.token,
            )
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () {
                cancellation.cancel();
                throw TimeoutException('Native task budget did not interrupt');
              },
            ),
        throwsA(
          isA<PluginExecutionError>().having(
            (e) => e.code,
            'code',
            'plugin_timeout',
          ),
        ),
      );
      expect(clock.elapsedMilliseconds, lessThan(4000));
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(1800));
    },
  );
  test(
    'total timeout aborts a pending Host wait and definition mismatch is rejected',
    () async {
      final pending = Completer<Object?>();
      final runtime = PluginRuntime(
        hostCall: (_, _) => pending.future,
        onStop: () {
          if (!pending.isCompleted) {
            pending.complete(null);
          }
        },
        taskTimeout: const Duration(milliseconds: 60),
      );
      final code = source("await context.http.fetch('https://example.com');");
      final definitions = await PluginRuntime(
        hostCall: (_, _) async => null,
      ).activate(manifest, code);
      await expectLater(
        runtime.runTask(
          manifest,
          code,
          definitions,
          'organize',
          run,
          AgentCancellationController().token,
        ),
        throwsA(
          isA<PluginExecutionError>().having(
            (e) => e.code,
            'code',
            'plugin_timeout',
          ),
        ),
      );
      final regular = PluginRuntime(hostCall: (_, _) async => null);
      await expectLater(
        regular.activate(
          manifest,
          source('return {};').replaceFirst("'organize'", "'unknown'"),
        ),
        throwsA(isA<PluginExecutionError>()),
      );
      await expectLater(
        regular.runTask(
          manifest,
          code.replaceFirst("'organize'", "'changed'"),
          definitions,
          'organize',
          run,
          AgentCancellationController().token,
        ),
        throwsA(
          isA<PluginExecutionError>().having(
            (e) => e.code,
            'code',
            'plugin_registration_mismatch',
          ),
        ),
      );
    },
  );
}
