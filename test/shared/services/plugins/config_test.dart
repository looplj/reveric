// 职责: 验证插件配置的校验、事务保存、凭据隔离和按声明读取。
// 关联文件:
//   lib/shared/services/plugins/config.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/models/plugin/manifest.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/agent_tool_dispatcher.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/services/plugins/config.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';
import 'host_test.dart' show FakeExecutor;

PluginManifest configManifest(String id) => PluginManifest.fromJson({
  'id': id,
  'name': 'Config',
  'version': '1.0.0',
  'pluginApiVersion': '^1',
  'main': 'dist/index.js',
  'settings': {
    'fields': {
      'count': {
        'type': 'integer',
        'title': 'Count',
        'min': 1,
        'max': 50,
        'default': 10,
      },
      'apiKey': {'type': 'secret', 'title': 'API Key', 'required': true},
      'optionalKey': {'type': 'secret', 'title': 'Optional'},
    },
  },
});

class _Reader extends FakeExecutor {
  _Reader(this.call);
  final PluginHostCall call;
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
  }) async => {
    'value': await call(input['method'] as String, {'key': input['key']}),
  };
}

void main() {
  late AppDatabase db;
  late PluginHostService host;
  setUp(() async {
    db = AppDatabase.forTest(NativeDatabase.memory());
    host = PluginHostService(
      dao: db.pluginDao,
      registry: PluginRegistry(hostToolNames: {}),
      packages: () async => [
        for (final id in ['test.one', 'test.two'])
          PluginPackage('assets/$id', configManifest(id), ''),
      ],
      executorFactory: (call, stop) => _Reader(call),
      platform: 'macos',
    );
    await host.start();
  });
  tearDown(() async {
    await host.dispose();
    await db.close();
  });

  test(
    'saving persists settings and secrets without exposing secret values to UI',
    () async {
      expect((await host.loadConfig('test.one')).values, {'count': 10});
      await expectLater(host.setEnabled('test.one', true), throwsStateError);
      await host.saveConfig(
        'test.one',
        settings: {'count': 12},
        secrets: {'apiKey': 'key-one', 'optionalKey': 'optional'},
      );
      final config = await host.loadConfig('test.one');
      expect(config.values, {'count': 12});
      expect(config.savedSecrets, {'apiKey', 'optionalKey'});
      expect((await host.loadConfig('test.two')).savedSecrets, isEmpty);
      await host.setEnabled('test.one', true);
      expect(
        (await host.execute('WebSearch', {
          'method': 'secrets.get',
          'key': 'apiKey',
        }))['value'],
        'key-one',
      );
      expect(
        (await host.execute('WebSearch', {
          'method': 'settings.get',
          'key': 'count',
        }))['value'],
        12,
      );
      await host.saveConfig(
        'test.one',
        settings: {'count': 13},
        secrets: {'optionalKey': null},
      );
      expect((await host.loadConfig('test.one')).savedSecrets, {'apiKey'});
      expect(
        await readPluginSecret(db.pluginDao, 'test.one', 'optionalKey'),
        null,
      );
      expect(await db.pluginDao.getSecret('test.one', 'optionalKey'), '');
      await host.setEnabled('test.one', false);
      expect((await host.loadConfig('test.one')).savedSecrets, {'apiKey'});
    },
  );
  test(
    'invalid submission cannot partially overwrite existing config',
    () async {
      await host.saveConfig(
        'test.one',
        settings: {'count': 12},
        secrets: {'apiKey': 'original'},
      );
      for (final settings in [
        {'count': 51},
        {'count': 1, 'unknown': 'x'},
        {'apiKey': 'leak'},
      ]) {
        await expectLater(
          host.saveConfig(
            'test.one',
            settings: settings,
            secrets: {'apiKey': 'new'},
          ),
          throwsFormatException,
        );
      }
      expect((await host.loadConfig('test.one')).values, {'count': 12});
      expect(await db.pluginDao.getSecret('test.one', 'apiKey'), 'original');
    },
  );
  test(
    'clearing a required secret saves and turns off the enabled plugin',
    () async {
      PluginStatus status() =>
          host.statuses.firstWhere((status) => status.id == 'test.one');
      expect(status().needsConfig, true);
      await host.saveConfig(
        'test.one',
        settings: {},
        secrets: {'apiKey': 'key-one'},
      );
      expect(status().needsConfig, false);
      await host.setEnabled('test.one', true);
      expect(status().state, 'available');

      await host.saveConfig(
        'test.one',
        settings: {'count': 4},
        secrets: {'apiKey': null},
      );

      expect((await host.loadConfig('test.one')).savedSecrets, isEmpty);
      expect((await host.loadConfig('test.one')).values, {'count': 4});
      expect(status().needsConfig, true);
      expect((await db.pluginDao.getPlugin('test.one'))!.enabled, false);
      expect(status().enabled, false);
      expect(status().state, 'disabled');
      expect(host.registry.toolsFor('test.one'), isEmpty);
      await expectLater(host.setEnabled('test.one', true), throwsStateError);

      // 插件未开启时清空不改变启停状态。
      await host.saveConfig(
        'test.two',
        settings: {},
        secrets: {'apiKey': 'key-two', 'optionalKey': 'o'},
      );
      await host.saveConfig(
        'test.two',
        settings: {},
        secrets: {'optionalKey': null},
      );
      expect((await db.pluginDao.getPlugin('test.two'))!.enabled, false);
    },
  );
  test(
    'runtime rejects undeclared keys and access through the wrong namespace',
    () async {
      await host.saveConfig(
        'test.one',
        settings: {},
        secrets: {'apiKey': 'key-one'},
      );
      await host.setEnabled('test.one', true);
      for (final input in [
        {'method': 'secrets.get', 'key': 'count'},
        {'method': 'settings.get', 'key': 'apiKey'},
        {'method': 'secrets.get', 'key': 'unknown'},
        {'method': 'secrets.get', 'key': 5},
      ]) {
        final result = await host.execute('WebSearch', input);
        expect(result['ok'], false);
        expect(result['error'], contains('Undeclared'));
      }
    },
  );
  test('manifest validates the complete setting declaration on discovery', () {
    expect(
      () => PluginManifest.fromJson({
        ...configManifest('test.one').json,
        'settings': {
          'fields': {
            'apiKey': {
              'type': 'secret',
              'title': 'API Key',
              'default': 'secret',
            },
          },
        },
      }),
      throwsFormatException,
    );
  });
}
