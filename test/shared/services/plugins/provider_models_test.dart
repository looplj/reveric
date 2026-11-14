// 职责: 用真实插件与本地平台验证模型发现、原子选择、刷新竞态、冷启动和更新下架。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/provider_models.dart
//   lib/shared/models/plugin/provider_registry.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/providers/plugin_providers.dart';
import 'package:reveric/shared/services/plugins/provider_models.dart';
import 'package:reveric/shared/database/app_database.dart' as db;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/models/plugin/provider_registry.dart';
import 'package:reveric/shared/models/provider_model.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

Map<String, dynamic> model(String id, {String resolution = '1K'}) => {
  'kind': 'image',
  'id': id,
  'capabilities': {
    'ratios': ['7:5'],
    'resolutions': [resolution],
    'minReferences': 0,
    'maxReferences': 1,
    'unlimitedReferences': false,
    'referenceTransport': 'file',
  },
  'requestDefaults': {'workflow': id},
};

class _GatedHost extends PluginHostService {
  _GatedHost({
    required super.dao,
    required super.registry,
    required super.packages,
    super.platform,
  });
  Completer<void>? entered, release;
  @override
  Future<AiProvider> saveProviderModels(
    PluginProviderDiscovery discovery,
    Set<(AiModelKind, String)> selected, {
    required Future<void> Function(AiProvider) saveProvider,
  }) async {
    final gate = release;
    final started = entered;
    release = null;
    if (gate != null) {
      started!.complete();
      await gate.future;
    }
    return super.saveProviderModels(
      discovery,
      selected,
      saveProvider: saveProvider,
    );
  }
}

void main() {
  setUpAll(() async {
    final path = Platform.environment['FJS_PROBE_LIBRARY'];
    if (path == null) {
      throw StateError('FJS_PROBE_LIBRARY is required');
    }
    await LibFjs.init(externalLibrary: ExternalLibrary.open(path));
  });
  late db.AppDatabase database;
  late HttpServer server;
  late PluginHostService host;
  late AiProvider provider;
  late PluginPackage package;
  late List<Map<String, dynamic>> payload;
  late int requests;
  Future<void> Function(HttpRequest request, int index)? response;
  final hosts = <PluginHostService>[];
  PluginHostService createHost(PluginPackage package) {
    final value = _GatedHost(
      dao: database.pluginDao,
      registry: PluginRegistry(hostToolNames: {}),
      packages: () async => [package],
      platform: 'macos',
    );
    hosts.add(value);
    return value;
  }

  Future<void> reply(
    HttpRequest request,
    List<Map<String, dynamic>> values,
  ) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(values));
    await request.response.close();
  }

  setUp(() async {
    database = db.AppDatabase.forTest(NativeDatabase.memory());
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = 0;
    response = null;
    payload = [model('one'), model('two')];
    server.listen((request) async {
      final index = ++requests;
      if (response case final handle?) {
        await handle(request, index);
      } else {
        await reply(request, payload);
      }
    });
    final manifest = PluginManifest.fromJson({
      'id': 'test.models',
      'name': 'Models',
      'version': '1.0.0',
      'pluginApiVersion': '^1',
      'main': 'index.js',
      'provider': {
        'name': 'Images',
        'settings': {
          'fields': {
            'region': {
              'type': 'string',
              'title': 'Region',
              'default': 'original',
            },
          },
        },
      },
    });
    package = PluginPackage(
      'memory',
      manifest,
      "let checks=0; var __revericPlugin={apply(setup){setup.provider.register({async checkConnection(){return {count:++checks};},async listModels(context){const response=await context.http.fetch('http://127.0.0.1:${server.port}/models');return JSON.parse(response.body);},image:{async submit(input,context){if(input.hold)await context.http.fetch('http://127.0.0.1:${server.port}/hold');return {status:'succeeded',outputs:[]};}}});}};",
    );
    host = createHost(package);
    await host.start();
    await host.setEnabled(manifest.id, true);
    provider = aiProviderBuiltinById('openai')!.copyWith(
      id: 'instance',
      type: 'plugin:test.models',
      builtin: false,
      enabled: false,
      apiKey: '',
      baseUrl: '',
      models: [],
      imageModels: [],
      videoModels: [],
    );
    await database.aiProviderDao.upsert(provider);
  });
  tearDown(() async {
    for (final value in hosts) {
      await value.dispose();
    }
    hosts.clear();
    await server.close(force: true);
    await database.close();
  });
  test(
    'provider queries reuse state while submissions occupy their own lane',
    () async {
      provider = provider.copyWith(enabled: true);
      await database.aiProviderDao.upsert(provider);
      final entered = Completer<void>();
      final release = Completer<void>();
      var held = 0;
      response = (request, index) async {
        if (request.uri.path == '/hold') {
          if (++held == 4) {
            entered.complete();
          }
          await release.future;
        }
        await reply(request, payload);
      };
      final submissions = List.generate(
        4,
        (_) =>
            host.callProvider(provider, 'image.submit', input: {'hold': true}),
      );
      try {
        await entered.future.timeout(const Duration(seconds: 5));
        expect(
          await host
              .callProvider(provider, 'checkConnection')
              .timeout(const Duration(seconds: 5)),
          {'count': 1},
        );
        expect(
          await host
              .callProvider(provider, 'checkConnection')
              .timeout(const Duration(seconds: 5)),
          {'count': 2},
        );
        expect(
          (await host.discoverProviderModels(provider)).models,
          hasLength(2),
        );
      } finally {
        release.complete();
        await Future.wait(submissions);
      }
    },
  );
  for (final configuration in [false, true]) {
    test(
      'notifier rebases overlapping ${configuration ? 'configuration/metadata' : 'instance selections'}',
      () async {
        final peer = provider.copyWith(id: 'peer', imageModels: []);
        await database.aiProviderDao.upsert(peer);
        final first = await host.discoverProviderModels(provider);
        final second = configuration
            ? null
            : await host.discoverProviderModels(peer);
        final container = ProviderContainer(
          overrides: [
            appSettingsDatabaseProvider.overrideWithValue(database),
            pluginHostServiceProvider.overrideWithValue(host),
          ],
        );
        addTearDown(container.dispose);
        await container.read(appSettingsProvider.future);
        final notifier = container.read(appSettingsProvider.notifier);
        final gate = Completer<void>(), entered = Completer<void>();
        (host as _GatedHost)
          ..release = gate
          ..entered = entered;
        final saveA = notifier.selectPluginProviderModels(first, {
          (AiModelKind.image, 'one'),
        });
        await entered.future;
        final saveB = configuration
            ? notifier.savePluginProviderConfiguration(
                provider.id,
                settings: {'region': 'updated'},
                secrets: {},
              )
            : notifier.selectPluginProviderModels(second!, {
                (AiModelKind.image, 'two'),
              });
        final metadata = configuration
            ? notifier.setAiProviderConfig(provider.copyWith(name: 'Renamed'))
            : Future<void>.value();
        await notifier.setUiTextScale(1.3);
        gate.complete();
        await Future.wait([saveA, saveB, metadata]);
        final state = container.read(appSettingsProvider).requireValue;
        expect(state.uiTextScale, 1.3);
        final saved = (await database.aiProviderDao.getById(provider.id))!;
        expect(saved.imageModels, ['one']);
        expect(state.aiSettings.findConfigById(provider.id)!.imageModels, [
          'one',
        ]);
        expect(resolveImageModel(saved, 'one'), isNotNull);
        if (configuration) {
          expect(saved.name, 'Renamed');
          expect(
            (await host.loadProviderConfig(saved)).values['region'],
            'updated',
          );
        } else {
          expect((await database.aiProviderDao.getById(peer.id))!.imageModels, [
            'two',
          ]);
          expect(state.aiSettings.findConfigById(peer.id)!.imageModels, [
            'two',
          ]);
          expect(resolveImageModel(peer, 'two'), isNotNull);
        }
        await host.dispose();
        host = createHost(package);
        await host.start();
        expect(resolveImageModel(saved, 'one'), isNotNull);
        if (!configuration) {
          expect(resolveImageModel(peer, 'two'), isNotNull);
        }
        container.invalidate(appSettingsProvider);
        final restored = await container.read(appSettingsProvider.future);
        expect(restored.aiSettings.findConfigById(provider.id)!.imageModels, [
          'one',
        ]);
      },
    );
  }
  test(
    'selected declarations commit atomically and restore without listModels',
    () async {
      expect(requests, 0);
      final found = await host.discoverProviderModels(provider);
      provider = await host.saveProviderModels(found, {
        (AiModelKind.image, 'one'),
      }, saveProvider: database.aiProviderDao.upsert);
      expect(provider.imageModels, ['one']);
      expect(resolveImageModel(provider, 'one')!.capabilities.ratios, {'7:5'});
      expect(resolveImageModel(provider, 'two'), isNull);
      final before = await database.pluginDao.getStorage(
        'test.models',
        'provider.instance.__models',
      );
      payload = [
        model('one', resolution: '2K'),
        model('two', resolution: '2K'),
      ];
      final next = await host.discoverProviderModels(provider);
      await expectLater(
        host.saveProviderModels(
          next,
          {(AiModelKind.image, 'one'), (AiModelKind.image, 'two')},
          saveProvider: (_) async {
            throw StateError('write failed');
          },
        ),
        throwsStateError,
      );
      expect(
        await database.pluginDao.getStorage(
          'test.models',
          'provider.instance.__models',
        ),
        before,
      );
      expect((await database.aiProviderDao.getById(provider.id))!.imageModels, [
        'one',
      ]);
      expect(resolveImageModel(provider, 'one')!.capabilities.resolutions, {
        '1K',
      });
      provider = await host.saveProviderModels(next, {
        (AiModelKind.image, 'one'),
        (AiModelKind.image, 'two'),
      }, saveProvider: database.aiProviderDao.upsert);
      final count = requests;
      await host.dispose();
      expect(resolveImageModel(provider, 'one'), isNull);
      host = createHost(package);
      await host.start();
      expect(requests, count);
      expect(resolveImageModel(provider, 'one')!.capabilities.resolutions, {
        '2K',
      });
      expect(resolveImageModel(provider, 'two')!.rawDefaults, {
        'workflow': 'two',
      });
    },
  );
  test(
    'model removal works offline, retains other selections and rejects stale discovery',
    () async {
      final found = await host.discoverProviderModels(provider);
      provider = await host.saveProviderModels(found, {
        (AiModelKind.image, 'one'),
        (AiModelKind.image, 'two'),
      }, saveProvider: database.aiProviderDao.upsert);
      final stale = await host.discoverProviderModels(provider);
      final count = requests;
      provider = provider.copyWith(videoModels: ['unavailable-video']);
      await database.aiProviderDao.upsert(provider);
      final container = ProviderContainer(
        overrides: [
          appSettingsDatabaseProvider.overrideWithValue(database),
          pluginHostServiceProvider.overrideWithValue(host),
        ],
      );
      try {
        await container.read(appSettingsProvider.future);
        await container
            .read(appSettingsProvider.notifier)
            .removePluginProviderModel(provider.id, AiModelKind.image, 'one');
        provider = (await database.aiProviderDao.getById(provider.id))!;
        expect(provider.imageModels, ['two']);
        expect(provider.videoModels, ['unavailable-video']);
        expect(
          container
              .read(appSettingsProvider)
              .requireValue
              .aiSettings
              .findConfigById(provider.id)!
              .imageModels,
          ['two'],
        );
        expect(
          pluginProviderModels.find(provider, AiModelKind.image, 'one'),
          isNull,
        );
        await expectLater(
          host.saveProviderModels(stale, {
            (AiModelKind.image, 'one'),
          }, saveProvider: database.aiProviderDao.upsert),
          throwsA(isA<PluginHostError>()),
        );
        await host.setEnabled('test.models', false);
        await container
            .read(appSettingsProvider.notifier)
            .removePluginProviderModel(
              provider.id,
              AiModelKind.video,
              'unavailable-video',
            );
        provider = (await database.aiProviderDao.getById(provider.id))!;
        expect(provider.videoModels, isEmpty);
        expect(provider.imageModels, ['two']);
        expect(requests, count);
      } finally {
        container.dispose();
      }
      await host.dispose();
      host = createHost(package);
      await host.start();
      expect((await database.aiProviderDao.getById(provider.id))!.imageModels, [
        'two',
      ]);
      expect(requests, count);
    },
  );

  test('only latest concurrent discovery is accepted', () async {
    final firstSeen = Completer<void>(), release = Completer<void>();
    response = (request, index) async {
      if (index == 1) {
        firstSeen.complete();
        await release.future;
      }
      await reply(request, [
        model('one', resolution: index == 1 ? 'old' : 'latest'),
      ]);
    };
    final first = host.discoverProviderModels(provider);
    final rejected = expectLater(
      first,
      throwsA(
        isA<PluginHostError>().having((e) => e.code, 'code', 'stale_result'),
      ),
    );
    await firstSeen.future;
    final latest = await host.discoverProviderModels(provider);
    release.complete();
    await rejected;
    provider = await host.saveProviderModels(latest, {
      (AiModelKind.image, 'one'),
    }, saveProvider: database.aiProviderDao.upsert);
    expect(resolveImageModel(provider, 'one')!.capabilities.resolutions, {
      'latest',
    });
  });
  test(
    'configuration change discards a refresh and cached declarations survive failures',
    () async {
      final found = await host.discoverProviderModels(provider);
      await host.saveProviderConfig(
        provider,
        settings: {'region': 'changed'},
        secrets: {},
      );
      await expectLater(
        host.saveProviderModels(found, {
          (AiModelKind.image, 'one'),
        }, saveProvider: database.aiProviderDao.upsert),
        throwsA(
          isA<PluginHostError>().having((e) => e.code, 'code', 'stale_result'),
        ),
      );
      expect(
        (await database.aiProviderDao.getById(provider.id))!.imageModels,
        isEmpty,
      );
      final fresh = await host.discoverProviderModels(provider);
      provider = await host.saveProviderModels(fresh, {
        (AiModelKind.image, 'one'),
      }, saveProvider: database.aiProviderDao.upsert);
      payload = [
        {'kind': 'image', 'id': 'broken', 'capabilities': {}},
      ];
      await expectLater(
        host.discoverProviderModels(provider),
        throwsA(
          isA<PluginHostError>().having(
            (e) => e.code,
            'code',
            'invalid_models',
          ),
        ),
      );
      expect(resolveImageModel(provider, 'one'), isNotNull);
    },
  );
  test(
    'cold corrupt cache retains IDs and requests explicit discovery',
    () async {
      final found = await host.discoverProviderModels(provider);
      provider = await host.saveProviderModels(found, {
        (AiModelKind.image, 'one'),
      }, saveProvider: database.aiProviderDao.upsert);
      await database.pluginDao.setStorage(
        'test.models',
        'provider.instance.__models',
        '{"version":99,"models":[]}',
      );
      final count = requests;
      await host.dispose();
      host = createHost(package);
      await host.start();
      expect(requests, count);
      expect(resolveImageModel(provider, 'one'), isNull);
      expect(pluginProviderModels.errorFor(provider), isNotNull);
      expect((await database.aiProviderDao.getById(provider.id))!.imageModels, [
        'one',
      ]);
    },
  );
  test('identical model IDs in two instances resolve independently', () async {
    final a = await host.discoverProviderModels(provider);
    provider = await host.saveProviderModels(a, {
      (AiModelKind.image, 'one'),
    }, saveProvider: database.aiProviderDao.upsert);
    var second = provider.copyWith(id: 'second', imageModels: []);
    await database.aiProviderDao.upsert(second);
    payload = [model('one', resolution: '2K')];
    final b = await host.discoverProviderModels(second);
    second = await host.saveProviderModels(b, {
      (AiModelKind.image, 'one'),
    }, saveProvider: database.aiProviderDao.upsert);
    expect(resolveImageModel(provider, 'one')!.capabilities.resolutions, {
      '1K',
    });
    expect(resolveImageModel(second, 'one')!.capabilities.resolutions, {'2K'});
  });
  test(
    'configuration change during discovery rejects the arriving response',
    () async {
      final arrived = Completer<void>(), release = Completer<void>();
      response = (request, index) async {
        arrived.complete();
        await release.future;
        await reply(request, payload);
      };
      final waiting = host.discoverProviderModels(provider);
      final rejected = expectLater(
        waiting,
        throwsA(
          isA<PluginHostError>().having((e) => e.code, 'code', 'stale_result'),
        ),
      );
      await arrived.future;
      await host.saveProviderConfig(
        provider,
        settings: {'region': 'changed'},
        secrets: {},
      );
      release.complete();
      await rejected;
      expect(
        (await database.aiProviderDao.getById(provider.id))!.imageModels,
        isEmpty,
      );
    },
  );
  test(
    'superseded refresh failure cannot replace a newer successful state',
    () async {
      final found = await host.discoverProviderModels(provider);
      provider = await host.saveProviderModels(found, {
        (AiModelKind.image, 'one'),
      }, saveProvider: database.aiProviderDao.upsert);
      final firstSeen = Completer<void>(), release = Completer<void>();
      response = (request, index) async {
        if (index == 2) {
          firstSeen.complete();
          await release.future;
          request.response.statusCode = 503;
          request.response.write('not json');
          await request.response.close();
        } else {
          await reply(request, [model('one', resolution: 'latest')]);
        }
      };
      final old = host.refreshProviderModels(provider);
      final rejected = expectLater(
        old,
        throwsA(
          isA<PluginHostError>().having((e) => e.code, 'code', 'stale_result'),
        ),
      );
      await firstSeen.future;
      await host.refreshProviderModels(provider);
      release.complete();
      await rejected;
      expect(pluginProviderModels.refreshErrorFor(provider), isNull);
      expect(resolveImageModel(provider, 'one')!.capabilities.resolutions, {
        'latest',
      });
    },
  );
  test(
    'failed update refresh retains usable models and exposes a clearable failure',
    () async {
      final found = await host.discoverProviderModels(provider);
      provider = await host.saveProviderModels(found, {
        (AiModelKind.image, 'one'),
      }, saveProvider: database.aiProviderDao.upsert);
      provider = provider.copyWith(enabled: true);
      await database.aiProviderDao.upsert(provider);
      expect(
        AiSettings(
          providers: [provider],
        ).availableModelOptionsForKind(AiModelKind.image),
        hasLength(1),
      );
      final cached = await database.pluginDao.getStorage(
        'test.models',
        'provider.instance.__models',
      );
      payload = [
        {'kind': 'image', 'id': 'broken', 'capabilities': {}},
      ];
      final failed = Completer<void>();
      void observe() {
        if (pluginProviderModels.refreshErrorFor(provider) != null &&
            !failed.isCompleted) {
          failed.complete();
        }
      }

      pluginProviderModels.addListener(observe);
      addTearDown(() => pluginProviderModels.removeListener(observe));
      await host.loadInstalled(
        PluginPackage(
          'memory',
          PluginManifest.fromJson({
            ...package.manifest.json,
            'version': '2.0.0',
          }),
          package.code,
        ),
      );
      await failed.future.timeout(const Duration(seconds: 2));
      expect(
        AiSettings(
          providers: [provider],
        ).availableModelOptionsForKind(AiModelKind.image),
        hasLength(1),
      );
      expect(pluginProviderModels.errorFor(provider), isNull);
      expect(
        pluginProviderModels.refreshErrorFor(provider)!.code,
        'invalid_models',
      );
      expect(resolveImageModel(provider, 'one')!.capabilities.resolutions, {
        '1K',
      });
      expect((await database.aiProviderDao.getById(provider.id))!.imageModels, [
        'one',
      ]);
      expect(
        await database.pluginDao.getStorage(
          'test.models',
          'provider.instance.__models',
        ),
        cached,
      );
      payload = [model('one', resolution: 'recovered')];
      final recovered = Completer<void>();
      void restored() {
        if (pluginProviderModels.refreshErrorFor(provider) == null &&
            resolveImageModel(
                  provider,
                  'one',
                )?.capabilities.resolutions.contains('recovered') ==
                true &&
            !recovered.isCompleted) {
          recovered.complete();
        }
      }

      pluginProviderModels.addListener(restored);
      addTearDown(() => pluginProviderModels.removeListener(restored));
      await host.refreshProviderModels(provider);
      await recovered.future.timeout(const Duration(seconds: 2));
      expect(pluginProviderModels.refreshErrorFor(provider), isNull);
    },
  );
  test(
    'plugin update refreshes selected declarations and keeps delisted IDs',
    () async {
      final found = await host.discoverProviderModels(provider);
      provider = await host.saveProviderModels(found, {
        (AiModelKind.image, 'one'),
        (AiModelKind.image, 'two'),
      }, saveProvider: database.aiProviderDao.upsert);
      payload = [model('one', resolution: 'updated'), model('new')];
      final updated = Completer<void>();
      void observe() {
        if (resolveImageModel(
                  provider,
                  'one',
                )?.capabilities.resolutions.contains('updated') ==
                true &&
            !updated.isCompleted) {
          updated.complete();
        }
      }

      pluginProviderModels.addListener(observe);
      addTearDown(() => pluginProviderModels.removeListener(observe));
      final next = PluginPackage(
        'memory',
        PluginManifest.fromJson({...package.manifest.json, 'version': '2.0.0'}),
        package.code,
      );
      await host.loadInstalled(next);
      await updated.future.timeout(const Duration(seconds: 5));
      expect((await database.aiProviderDao.getById(provider.id))!.imageModels, [
        'one',
        'two',
      ]);
      expect(resolveImageModel(provider, 'two'), isNull);
      expect(resolveImageModel(provider, 'new'), isNull);
    },
  );
}
