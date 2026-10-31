// 职责: 验证插件启停持久化、平台分支、覆盖、在途调用边界与设置页操作。
// 关联文件:
//   lib/shared/services/plugins/host.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/models/plugin/text.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

Map<String, dynamic> definition(String name) => {
  'name': name,
  'description': 'Test',
  'inputSchema': {'type': 'object'},
};
PluginPackage package({
  String id = 'test.web',
  String version = '1.0.0',
  List<String>? platforms,
  Map<String, dynamic>? settings,
  Map<String, dynamic>? actions,
}) => PluginPackage(
  'assets/$id',
  PluginManifest.fromJson({
    'id': id,
    'name': 'Test',
    'version': version,
    'main': 'dist/index.js',
    'pluginApiVersion': '^1',
    'defaultEnabled': true,
    'platforms': ?platforms,
    'settings': {'fields': ?settings, 'actions': ?actions},
  }),
  '',
);

class FakeExecutor implements PluginExecutor {
  FakeExecutor({this.pending, this.started});
  final Completer<Map<String, dynamic>>? pending;
  final Completer<void>? started;
  @override
  Future<String?> runTask(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String taskId,
    Map<String, dynamic> run,
    AgentCancellationToken cancellation,
  ) async => throw UnimplementedError('Task runtime fixture required');

  @override
  Future<String?> runPrompt(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String providerId,
    Map<String, dynamic> request,
    Duration budget,
    AgentCancellationToken cancellation,
  ) async => null;

  @override
  Future<List<dynamic>> runViewAction(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String viewId,
    String action,
    Map<String, dynamic> input,
    String callId,
    AgentCancellationToken? cancellation,
  ) async {
    throw UnimplementedError('View actions require a runtime fixture');
  }

  @override
  Future<List<Map<String, dynamic>>> activate(
    PluginManifest manifest,
    String code,
  ) async => [definition('WebSearch'), definition('WebFetch')];
  @override
  Future<Map<String, dynamic>> invoke(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String tool,
    Map<String, dynamic> input,
    String callId,
    AgentCancellationToken? cancellation, {
    Map<String, dynamic> request = const {},
  }) async {
    if (started != null && !started!.isCompleted) {
      started!.complete();
    }
    return pending?.future ?? Future.value({'ok': true});
  }

  @override
  Future<Map<String, dynamic>> runAction(
    PluginManifest manifest,
    String code,
    String action,
    String callId,
    AgentCancellationToken? cancellation,
  ) async => {'ok': true};
}

class _LoggingExecutor extends FakeExecutor {
  _LoggingExecutor(this.call, this.secret);
  final PluginHostCall call;
  final String secret;
  @override
  Future<Map<String, dynamic>> invoke(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String tool,
    Map<String, dynamic> input,
    String callId,
    AgentCancellationToken? cancellation, {
    Map<String, dynamic> request = const {},
  }) async {
    await call('log.info', {
      'message': 'credential=$secret',
      'data': {'credential': secret},
    });
    return {'ok': true};
  }
}

class _GatedExecutor extends FakeExecutor {
  _GatedExecutor(this.gates, this.onActive);
  final Map<String, Completer<Map<String, dynamic>>> gates;
  final void Function(int delta) onActive;
  @override
  Future<Map<String, dynamic>> invoke(
    PluginManifest manifest,
    String code,
    List<Map<String, dynamic>> expected,
    String tool,
    Map<String, dynamic> input,
    String callId,
    AgentCancellationToken? cancellation, {
    Map<String, dynamic> request = const {},
  }) async {
    onActive(1);
    final gate = Completer<Map<String, dynamic>>();
    gates[callId] = gate;
    try {
      return await gate.future;
    } finally {
      onActive(-1);
    }
  }
}

/// 设置页操作读取凭据与配置后按 [result] 返回；[result] 为 null 时抛出超时。
class _ActionExecutor extends FakeExecutor {
  _ActionExecutor(this.call, this.reads, this.result);
  final PluginHostCall call;
  final List<Object?> reads;
  final Map<String, dynamic>? result;
  @override
  Future<Map<String, dynamic>> runAction(
    PluginManifest manifest,
    String code,
    String action,
    String callId,
    AgentCancellationToken? cancellation,
  ) async {
    reads
      ..add(await call('secrets.get', {'key': 'apiKey'}))
      ..add(await call('settings.get', {'key': 'region'}));
    final value = result;
    if (value == null) {
      throw PluginExecutionError('plugin_timeout', 'Action timed out');
    }
    return value;
  }
}

Future<void> _until(bool Function() condition) async {
  await Future<void>(() async {
    while (!condition()) {
      await Future<void>.delayed(Duration.zero);
    }
  }).timeout(const Duration(seconds: 2));
}

void main() {
  test(
    'queued cancellation returns before active calls finish and preserves four slots',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final gates = <String, Completer<Map<String, dynamic>>>{};
      var created = 0, active = 0, peak = 0;
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [package()],
        executorFactory: (call, stop) {
          created++;
          return _GatedExecutor(gates, (delta) {
            active += delta;
            if (active > peak) {
              peak = active;
            }
          });
        },
        platform: 'macos',
      );
      addTearDown(host.dispose);
      addTearDown(() {
        for (final gate in gates.values) {
          if (!gate.isCompleted) {
            gate.complete({'ok': true});
          }
        }
      });
      await host.start();
      final running = [
        for (var i = 0; i < 4; i++)
          host.execute('WebFetch', {}, callId: 'initial$i'),
      ];
      await _until(() => gates.length == 4);
      final cancellation = AgentCancellationController();
      final queued = host.execute(
        'WebFetch',
        {},
        callId: 'cancelled',
        cancellation: cancellation.token,
      );
      cancellation.cancel();
      final result = await queued.timeout(const Duration(milliseconds: 200));
      expect(result['error_code'], 'user_cancelled');
      expect(result['cancelled'], true);
      expect(active, 4);
      expect(created, 5);
      expect(gates.containsKey('cancelled'), false);
      final next = host.execute('WebFetch', {}, callId: 'next');
      gates['initial0']!.complete({'ok': true});
      await running[0];
      await _until(() => gates.containsKey('next'));
      expect(active, 4);
      expect(created, 6);
      final race = AgentCancellationController();
      final raced = host.execute(
        'WebFetch',
        {},
        callId: 'raced',
        cancellation: race.token,
      );
      gates['initial1']!.complete({'ok': true});
      await running[1];
      race.cancel();
      expect(
        (await raced.timeout(const Duration(milliseconds: 200)))['cancelled'],
        true,
      );
      expect(gates.containsKey('raced'), false);
      expect(created, 6);
      final subsequent = host.execute('WebFetch', {}, callId: 'subsequent');
      await _until(() => gates.containsKey('subsequent'));
      expect(active, 4);
      expect(peak, 4);
      for (final gate in gates.values) {
        if (!gate.isCompleted) {
          gate.complete({'ok': true});
        }
      }
      await Future.wait([...running, next, subsequent]);
      expect(active, 0);
    },
  );
  test('plugin logs redact JSON-escaped credentials', () async {
    const secret = 'quoted"line\nvalue';
    final messages = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) {
        messages.add(message);
      }
    };
    addTearDown(() => debugPrint = original);
    final db = AppDatabase.forTest(NativeDatabase.memory());
    addTearDown(db.close);
    await db.pluginDao.setSecret('test.web', 'key', secret);
    final host = PluginHostService(
      dao: db.pluginDao,
      registry: PluginRegistry(hostToolNames: {}),
      packages: () async => [package()],
      executorFactory: (call, stop) => _LoggingExecutor(call, secret),
      platform: 'macos',
    );
    addTearDown(host.dispose);
    await host.start();
    await host.execute('WebFetch', {});
    final message = messages.singleWhere(
      (value) => value.contains('[Plugin] plugin=test.web '),
    );
    final encoded = jsonEncode(secret);
    expect(message, isNot(contains(encoded.substring(1, encoded.length - 1))));
    expect('***'.allMatches(message), hasLength(2));
  });
  test(
    'actions read unsaved form values, run while disabled and map failures',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      await db.pluginDao.setSecret('test.web', 'apiKey', 'saved-key');
      final reads = <Object?>[];
      Map<String, dynamic>? result = {'ok': true};
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [
          package(
            settings: {
              'apiKey': {'type': 'secret', 'title': 'Key'},
              'region': {'type': 'string', 'title': 'Region', 'default': 'cn'},
            },
            actions: {
              'verify': {
                'title': 'Verify',
                'requires': ['apiKey'],
              },
            },
          ),
        ],
        executorFactory: (call, stop) => _ActionExecutor(call, reads, result),
        platform: 'macos',
      );
      addTearDown(host.dispose);
      await host.start();
      await host.setEnabled('test.web', false);

      expect(
        await host.runAction(
          'test.web',
          'verify',
          settings: {'region': 'us'},
          secrets: {'apiKey': 'draft-key'},
        ),
        (ok: true, code: null),
      );
      expect(reads, ['draft-key', 'us']);

      reads.clear();
      await host.runAction('test.web', 'verify');
      expect(reads, ['saved-key', 'cn']);

      // 待清空的凭据与未填的配置按清空后的值读取。
      reads.clear();
      result = {'ok': false, 'code': 'unauthorized', 'message': 'x'};
      expect(
        await host.runAction(
          'test.web',
          'verify',
          settings: {'region': null},
          secrets: {'apiKey': null},
        ),
        (ok: false, code: 'unauthorized'),
      );
      expect(reads, [null, 'cn']);

      result = {'ok': false};
      expect(await host.runAction('test.web', 'verify'), (
        ok: false,
        code: 'failed',
      ));
      result = null;
      expect(await host.runAction('test.web', 'verify'), (
        ok: false,
        code: 'timeout',
      ));
      expect(await host.runAction('test.web', 'undeclared'), (
        ok: false,
        code: 'unavailable',
      ));
      // 草稿只作用于本次操作，不写入已保存配置。
      expect(await db.pluginDao.secretValues('test.web'), ['saved-key']);
    },
  );
  test('manifest parses actions and rejects invalid declarations', () {
    final valid = package().manifest.json;
    final settings = {
      'apiKey': {'type': 'secret', 'title': 'Key'},
    };
    final manifest = PluginManifest.fromJson({
      ...valid,
      'settings': {
        'fields': settings,
        'actions': {
          'verifyApiKey': {
            'title': 'Verify',
            'requires': ['apiKey'],
          },
        },
      },
    });
    expect(manifest.actions.single.name, 'verifyApiKey');
    expect(manifest.actions.single.title.resolve(const Locale('en')), 'Verify');
    expect(manifest.actions.single.requires, ['apiKey']);
    expect(package().manifest.actions, isEmpty);
    for (final actions in [
      [],
      {
        'bad-name': {'title': 'x'},
      },
      {'verify': 'x'},
      {
        'verify': {'title': ' '},
      },
      {
        'verify': {'title': <String, String>{}},
      },
      {
        'verify': {
          'title': 'x',
          'requires': ['missing'],
        },
      },
    ]) {
      expect(
        () => PluginManifest.fromJson({
          ...valid,
          'settings': {'fields': settings, 'actions': actions},
        }),
        throwsFormatException,
      );
    }
  });
  test(
    'manifest validates page locations, protocols, actions and task metadata',
    () {
      final base = package().manifest.json;
      final page = <String, dynamic>{
        'title': 'Report',
        'location': 'home.plugin',
        'protocol': 'reveric-ui-v1',
        'source': 'report.json',
        'actions': ['load'],
        'onMount': 'load',
      };
      final parsed = PluginManifest.fromJson({
        ...base,
        'pages': {'report': page},
        'tasks': {
          'organize': {'title': 'Organize', 'intervalMinutes': 60},
        },
      });
      expect(parsed.pages.single.id, 'report');
      expect(parsed.tasks.single.intervalMinutes, 60);
      for (final change in <Map<String, dynamic>>[
        {'location': null},
        {'location': 'plugin.page'},
        {'protocol': 'unknown'},
        {'source': '../report.json'},
        {'source': 'report.js'},
        {'id': 'other'},
        {
          'actions': ['load', 'load'],
        },
        {'onMount': 'missing'},
        {'protocol': 'reveric-tsx-v1', 'source': 'report.js'},
      ]) {
        expect(
          () => PluginManifest.fromJson({
            ...base,
            'pages': {
              'report': {...page, ...change},
            },
          }),
          throwsFormatException,
        );
      }
      for (final interval in [14, 10081, 60.5, '60']) {
        expect(
          () => PluginManifest.fromJson({
            ...base,
            'tasks': {
              'organize': {'title': 'Organize', 'intervalMinutes': interval},
            },
          }),
          throwsFormatException,
        );
      }
      for (final change in <Map<String, dynamic>>[
        {'pages': []},
        {'tasks': []},
        {
          'pages': {'bad/id': page},
        },
        {
          'settings': {
            'apiKey': {'type': 'secret', 'title': 'Key'},
          },
        },
        {'actions': {}},
        {'views': {}},
      ]) {
        expect(
          () => PluginManifest.fromJson({...base, ...change}),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'custom tool cards declare their own supported protocol and safe source',
    () {
      PluginTool card(Object? view) =>
          PluginTool('test.card', PluginText.plain('Card'), 'bundled', {
            ...definition('Card'),
            'display': {'result': 'json', 'view': view},
          });
      expect(
        card({'protocol': 'reveric-ui-v1', 'source': 'views/card.json'}).name,
        'Card',
      );
      for (final view in [
        'views/card.json',
        null,
        {'source': 'views/card.json'},
        {'protocol': 'reveric-tsx-v1', 'source': 'card.js'},
        {'protocol': 'reveric-ui-v1', 'source': '../card.json'},
      ]) {
        expect(() => card(view), throwsFormatException);
      }
    },
  );
  test('manifest rejects malformed contracts and paths', () {
    final valid = package().manifest.json;
    for (final change in [
      {'id': 'invalid'},
      {'name': 42},
      {'main': '../index.js'},
      {
        'platforms': ['ios'],
      },
      {'pluginApiVersion': '^2'},
      {'defaultEnabled': 'yes'},
      {'settings': []},
      {'uiProtocol': 'reveric-ui-v1'},
      {
        'uiProtocols': ['future'],
      },
      {
        'uiProtocols': ['reveric-ui-v1', 'reveric-ui-v1'],
      },
      {'uiProtocols': 'reveric-ui-v1'},
    ]) {
      expect(
        () => PluginManifest.fromJson({...valid, ...change}),
        throwsA(anything),
      );
    }
    expect(package().manifest.platforms, ['windows', 'macos', 'android']);
  });
  test(
    'registry validates definitions atomically and restores bundled override',
    () {
      final registry = PluginRegistry(hostToolNames: {'Read'});
      PluginTool tool(String id, String source, String name) =>
          PluginTool(id, PluginText.plain(id), source, definition(name));
      registry.register('bundled', [tool('bundled', 'bundled', 'WebFetch')]);
      registry.register('first', [tool('first', 'local', 'WebFetch')]);
      expect(registry.resolve('WebFetch')!.pluginId, 'first');
      expect(
        () => registry.register('second', [
          tool('second', 'local', 'Extra'),
          tool('second', 'local', 'WebFetch'),
        ]),
        throwsStateError,
      );
      expect(registry.resolve('Extra'), null);
      registry.remove('first');
      expect(registry.resolve('WebFetch')!.pluginId, 'bundled');
      expect(
        () => registry.register('bad', [tool('bad', 'local', 'Read')]),
        throwsStateError,
      );
      expect(
        () => PluginTool('bad', PluginText.plain('bad'), 'local', {
          'name': 'Bad',
          'description': 'x',
          'inputSchema': {'type': 'array'},
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'disable refuses new calls while in-flight finishes; upgrade preserves disabled',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(db.close);
      final pending = Completer<Map<String, dynamic>>();
      final started = Completer<void>();
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [package()],
        executorFactory: (call, stop) =>
            FakeExecutor(pending: pending, started: started),
        platform: 'macos',
      );
      addTearDown(host.dispose);
      await host.start();
      expect(host.registry.effectiveTools, hasLength(2));
      final running = host.execute('WebFetch', {});
      await started.future;
      await host.setEnabled('test.web', false);
      expect(
        (await host.execute('WebFetch', {}))['error_code'],
        'plugin_unavailable',
      );
      pending.complete({'ok': true});
      expect(await running, {'ok': true});
      final restarted = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [package(version: '2.0.0')],
        executorFactory: (call, stop) => FakeExecutor(),
        platform: 'macos',
      );
      addTearDown(restarted.dispose);
      await restarted.start();
      expect(restarted.statuses.single.state, 'disabled');
      await restarted.setEnabled('test.web', true);
      expect(restarted.registry.effectiveTools, hasLength(2));
    },
  );
  test('all supported host platforms honor manifest restrictions', () async {
    for (final platform in ['windows', 'macos', 'android']) {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => [
          package(platforms: ['android']),
        ],
        executorFactory: (call, stop) => FakeExecutor(),
        platform: platform,
      );
      await host.start();
      expect(
        host.statuses.single.state,
        platform == 'android' ? 'available' : 'unsupported',
      );
      expect(host.statuses.single.enabled, true);
      await host.dispose();
      await db.close();
    }
  });
}
