// 职责: 在真实应用 target 验证 FJS 桥接、模块边界和中断，不访问业务数据。
// 关联文件:
//   third/fjs/lib/fjs.dart
//   third/fjs/libfjs/src/api/runtime.rs
//   third/fjs/libfjs/src/tests/runtime_architecture_tests.rs
import 'dart:convert';
import 'dart:io';

import 'package:fjs/fjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;

void main({bool initializeLibrary = true}) {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('patched native engine bridge, modules and cancellation', (
    tester,
  ) async {
    await tester.runAsync(() async {
      if (initializeLibrary) {
        await LibFjs.init();
      }
      final fixture = await Directory.systemTemp.createTemp('codemode-native-');
      try {
        final file = File(path.join(fixture.path, 'secret.js'));
        await file.writeAsString('export const secret = 73;');
        await Directory(path.join(fixture.path, 'child')).create();
        final engine = await JsEngine.create(
          builtins: JsBuiltinOptions.none(),
          modules: [
            JsModule.code(
              module: 'memory-fixture',
              code: 'export const answer = 42;',
            ),
          ],
        );
        var bridgeCalls = 0;
        await engine.init(
          bridge: (value) async {
            bridgeCalls++;
            await Future<void>.delayed(const Duration(milliseconds: 10));
            expect(value, const JsValue.string('中文 😀'));
            return const JsResult.ok(JsValue.string('Dart Promise 中文 😀'));
          },
        );
        expect(
          await engine.eval(
            source: JsCode.code("await fjs.bridge_call('中文 😀')"),
          ),
          const JsValue.string('Dart Promise 中文 😀'),
        );
        expect(bridgeCalls, 1);
        for (final specifier in [
          file.path,
          path.relative(file.path),
          '${fixture.path}/child/../secret.js',
          '/usr/lib/libSystem.B.dylib',
          'libc.so.6',
        ]) {
          final encoded = jsonEncode(specifier);
          expect(
            await engine.eval(
              source: JsCode.code(
                "await import($encoded.split('').join(''))"
                '.then(() => false, () => true)',
              ),
            ),
            const JsValue.boolean(true),
            reason: 'external module must be denied: $specifier',
          );
        }
        expect(
          await engine.eval(
            source: JsCode.code("(await import('memory-fixture')).answer"),
          ),
          const JsValue.integer(42),
        );
        await engine.close();

        for (final source in [
          'while (true) {}',
          'await (async () => { while (true) { await Promise.resolve(); } })()',
          'await new Promise(() => {})',
        ]) {
          await _cancelEngines([source]);
        }
        await _cancelEngines(['while (true) {}', 'while (true) {}']);

        final healthy = await JsEngine.create(
          builtins: JsBuiltinOptions.none(),
        );
        await healthy.initWithoutBridge();
        expect(
          await healthy.eval(source: JsCode.code('21 * 2')),
          const JsValue.integer(42),
        );
        await healthy.close();
      } finally {
        await fixture.delete(recursive: true);
      }
    });
  });
  testWidgets('shared native runtime isolates plugin contexts and local close', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final group = await JsEngineGroup.create();
      final a = await group.createEngine();
      final b = await group.createEngine();
      try {
        await a.init(
          bridge: (_) async => const JsResult.ok(JsValue.string('A')),
        );
        await b.init(
          bridge: (_) async => const JsResult.ok(JsValue.string('B')),
        );
        await a.eval(
          source: JsCode.code(
            "globalThis.privateValue=1; Object.prototype.poison=1; JSON.stringify=()=> 'poison';",
          ),
        );
        expect(
          await b.eval(
            source: JsCode.code(
              "JSON.stringify([typeof privateValue,typeof ({}).poison,await fjs.bridge_call('same-token')])",
            ),
          ),
          const JsValue.string('["undefined","undefined","B"]'),
        );
        await a.close();
        expect(
          await b.eval(source: JsCode.code("await fjs.bridge_call('alive')")),
          const JsValue.string('B'),
        );
      } finally {
        await a.close();
        await b.close();
        await group.close();
      }
    });
  });
}

Future<void> _cancelEngines(List<String> sources) async {
  final engines = <JsEngine>[];
  final results = <Future<Object>>[];
  for (final _ in sources) {
    final engine = await JsEngine.create(builtins: JsBuiltinOptions.none());
    await engine.initWithoutBridge();
    engines.add(engine);
  }
  for (var i = 0; i < sources.length; i++) {
    // Install an error handler immediately so cancellation cannot escape the test.
    results.add(
      engines[i]
          .eval(source: JsCode.code(sources[i]))
          .then<Object>((value) => value, onError: (Object error) => error),
    );
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
  final watch = Stopwatch()..start();
  await Future.wait(
    engines.map((engine) => engine.close()),
  ).timeout(const Duration(seconds: 1));
  for (final result in results) {
    expect(
      await result.timeout(const Duration(seconds: 1)),
      isA<JsError_Cancelled>(),
    );
  }
  expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
}
