// 职责: 验证 Run providers 查询的脱敏、类型筛选、动态配置及聊天与媒体模型可用性。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/providers_run_command_handler.dart
//   lib/shared/services/ai/provider_resources.dart
//   lib/shared/models/production/image_request.dart
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/services/ai/media/production.dart';
import 'package:reveric/shared/services/ai/tool_operations.dart';
import 'package:reveric/shared/services/ai/tools.dart';
import 'package:reveric/shared/services/ai/provider_resources.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_overlay.dart';

AiProvider provider(String type, {String? id, bool enabled = true}) =>
    aiProviderBuiltinById('openai')!.copyWith(
      id: id ?? type,
      type: type,
      name: type,
      enabled: enabled,
      apiKey: 'secret-api-key',
      baseUrl: 'https://secret-user:secret-password@example.com',
      proxyUrl: 'https://secret-proxy.example.com',
      proxyUsername: 'secret-proxy-user',
      proxyPassword: 'secret-proxy-password',
      models: ['custom-chat-model'],
      imageModels: ['openai/gpt-image-2', 'unregistered/vendor/model'],
      videoModels: ['bytedance/seedance-2.5'],
      audioModels: ['bytedance-seed/seed-audio-1-0'],
    );

void main() {
  late NovelContentDatabase contentDb;
  late AppDatabase appDb;
  late AiToolManager manager;
  late ToolOperationManager operations;
  var providers = <AiProvider>[];

  var failRead = false;
  setUp(() {
    contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
    appDb = AppDatabase.forTest(NativeDatabase.memory());
    final content = NovelContentService(contentDb);
    providers = [provider('openrouter'), provider('qwen', enabled: false)];

    failRead = false;
    operations = ToolOperationManager(
      ownerSessionId: 'owner',
      registry: ToolOperationRegistry(),
      gate: () => throw StateError('No permission check expected'),
      onChanged: (_) {},
      onRecord: (_) {},
    );
    manager = AiToolManager(
      content,
      workingOverlayService: WorkingOverlayService(
        contentDb,
        content,
        novelActionsService: NovelActionsService(appDb),
      ),
      providerReader: () async {
        if (failRead) {
          throw StateError('secret database failure');
        }
        return providers;
      },

      contentKind: 'screenplay',
      operationHost: ToolOperationHost(operations),
    )..registerAllTools();
  });
  tearDown(() async {
    manager.dispose();
    operations.dispose();

    await contentDb.close();
    await appDb.close();
  });
  Future<Map<String, dynamic>> read(String path) =>
      manager.executeTool(name: 'Read', input: {'path': path});

  Future<Map<String, dynamic>> run(
    String action, [
    Map<String, dynamic> options = const {},
  ]) => manager.executeTool(
    name: 'Run',
    input: {'command': 'providers', 'subcommand': action, 'options': options},
  );

  test(
    'third-party audio discovery exposes channel output formats and defaults',
    () {
      for (final (type, model, format) in [
        ('qwen', 'qwen-audio-3.1-tts-plus', 'wav'),
        ('qwen', 'qwen-audio-3.1-tts-next', 'wav'),
        ('atlascloud', 'google/gemini-3.1-flash-tts', 'wav'),
        ('atlascloud', 'minimax/speech-2.6-turbo', 'mp3'),
        ('atlascloud', 'bytedance/seed-audio-1.0', 'wav'),
        ('atlascloud', 'minimax/music-3.0', 'mp3'),
      ]) {
        final configured = provider(type).copyWith(audioModels: [model]);
        final resource = providerModelResource(configured, 'audio', model);
        expect(resource['available'], true);
        expect(resource['capabilities_known'], true);
        expect(resource['capabilities']['output_formats'], [format]);
        expect(resource['defaults']['response_format'], format);
      }
    },
  );

  test(
    'Run discovery, live configuration, filtering and credentials redaction',
    () async {
      final help = await manager.executeTool(
        name: 'Run',
        input: {'command': 'help'},
      );
      expect(help['output'], contains('providers'));
      final details = await manager.executeTool(
        name: 'Run',
        input: {'command': 'help', 'subcommand': 'providers'},
      );
      expect(details['output'], contains('capabilities and defaults'));
      expect(details['output'], isNot(contains('providers model:')));
      final before = jsonEncode(
        manager.allToolDefs().map((def) => def.inputSchema).toList(),
      );
      final result = await run('list');
      expect(result['ok'], true, reason: '$result');
      final entries = result['entries'] as List;
      expect(entries, hasLength(1));
      expect(entries.single['id'], 'openrouter');
      expect(entries.single['configured'], true);
      expect(entries.single['asset_certification'], false);
      expect(entries.single, isNot(contains('path')));
      expect(entries.single, isNot(contains('models_paths')));
      expect(jsonEncode(result), isNot(contains('secret')));
      expect((await run('list', {'enabled': true}))['entries'], entries);
      expect((await run('read', {'provider_id': 'qwen'}))['enabled'], false);
      expect(
        (await run('list', {'enabled': false}))['entries'][0]['id'],
        'qwen',
      );
      providers.add(provider('atlascloud'));
      expect(
        ((await run('list', {'sort': '-id'}))['entries'] as List).map(
          (entry) => entry['id'],
        ),
        ['openrouter', 'atlascloud'],
      );
      providers = [provider('qwen', enabled: false)];
      expect((await run('list'))['entries'], isEmpty);
      providers = [provider('atlascloud')];
      expect((await run('list'))['entries'][0]['id'], 'atlascloud');
      expect(
        jsonEncode(
          manager.allToolDefs().map((def) => def.inputSchema).toList(),
        ),
        before,
      );
    },
  );

  test('missing model options return actionable command hints', () async {
    final generalHelp = await manager.executeTool(
      name: 'Run',
      input: {'command': 'help'},
    );
    expect(generalHelp['output'], contains('Available commands:'));

    for (final (options, missing) in <(Map<String, dynamic>, String)>[
      ({'kind': 'video'}, 'provider_id'),
      ({}, 'provider_id'),
    ]) {
      final result = await run('models', options);
      expect(result['ok'], false);
      expect(result['error_code'], 'invalid_argument');
      expect(result['error'], '$missing must be a non-empty string.');
      expect(result['exit_code'], 1);
      final hint = result['hint'];
      expect(hint, isA<String>());
      expect(hint, contains('provider_id required'));
      expect(hint, contains('optional kind=chat|image|video|audio'));
      expect(result['output'], contains(hint));
      expect(result['output'], isNot(contains('Available commands:')));

      // The supplied example must be executable after choosing a listed provider.
      final example = RegExp(
        r'Example: (\{[^\n]+\})',
      ).firstMatch(hint as String);
      expect(example, isNotNull);
      final input = jsonDecode(example!.group(1)!) as Map<String, dynamic>;
      final listed = await run('list');
      (input['options'] as Map)['provider_id'] = listed['entries'][0]['id'];
      final corrected = await manager.executeTool(name: 'Run', input: input);
      expect(corrected['ok'], true, reason: '$corrected');
      expect(corrected['entries'], isNotEmpty);
    }
  });

  test(
    'provider and model IDs remain literal strings and invalid kinds fail',
    () async {
      const id = 'channel/with%slash';
      providers = [
        provider(
          'openrouter',
          id: id,
        ).copyWith(imageModels: ['openai/gpt-image-2', 'literal%2Fmodel']),
      ];
      final listing = await run('models', {'provider_id': id, 'kind': 'image'});
      expect(listing['ok'], true, reason: '$listing');
      final entry = listing['entries'][0];
      expect(entry['id'], 'openai/gpt-image-2');
      expect(entry, isNot(contains('path')));
      expect(entry['provider_id'], id);
      expect(entry['capabilities']['max_references'], 16);
      expect(entry['defaults'], isA<Map>());
      final unknown = listing['entries'][1];
      expect(unknown['id'], 'literal%2Fmodel');
      expect(unknown['capabilities_known'], false);
      expect(unknown.containsKey('capabilities'), true);
      expect(unknown['available'], true);
      expect(unknown['capabilities'], isNull);
      expect(unknown.containsKey('defaults'), true);
      expect(unknown['defaults'], isNull);
      expect(jsonEncode(listing), isNot(contains('secret')));
      expect(
        (await run('models', {
          'provider_id': id,
          'kind': 'image',
          'sort': '-id',
        }))['entries'][0]['id'],
        'openai/gpt-image-2',
      );
      for (final (action, options) in <(String, Map<String, dynamic>)>[
        ('list', {'enabled': 'true'}),
        ('list', {'api_key': 'x'}),
        ('list', {'sort': 1}),
        ('list', {'sort': 'api_key'}),
        ('read', {}),
        ('read', {'provider_id': 1}),
        ('models', {'provider_id': id, 'kind': null}),
        ('models', {'provider_id': id, 'kind': ''}),
        ('models', {'provider_id': id, 'kind': '  '}),
        ('models', {'provider_id': id, 'kind': 1}),
        ('models', {'provider_id': id, 'kind': 'text'}),
        (
          'model',
          {
            'provider_id': id,
            'kind': 'image',
            'model_id': 'openai/gpt-image-2',
          },
        ),
        (
          'models',
          {
            'provider_id': id,
            'kind': 'image',
            'model_id': 'openai/gpt-image-2',
          },
        ),
        ('list', {'work_id': 'other'}),
        ('create', {'name': 'changed'}),
      ]) {
        final result = await run(action, options);
        expect(
          result['error_code'],
          'invalid_argument',
          reason: '$action $options: $result',
        );
        expect(
          result['hint'],
          contains('optional kind=chat|image|video|audio'),
        );
      }
      expect(
        (await run('read', {'provider_id': 'missing'}))['error_code'],
        'not_found',
      );
      expect(
        (await run('models', {
          'provider_id': 'missing',
          'kind': 'image',
        }))['error_code'],
        'not_found',
      );
    },
  );

  test(
    'omitting kind returns all types and filtering preserves details',
    () async {
      providers = [
        provider('openrouter').copyWith(
          models: [' shared-model ', 'shared-model', '', 'custom-chat-model'],
          imageModels: ['shared-model', 'openai/gpt-image-2'],
        ),
      ];
      final all = await run('models', {'provider_id': 'openrouter'});
      expect(all['ok'], true);
      final entries = all['entries'] as List;
      expect(entries, hasLength(6));
      expect(
        entries.where((entry) => entry['id'] == 'shared-model'),
        hasLength(2),
      );
      expect(jsonEncode(all), isNot(contains('secret')));
      for (final kind in ['chat', 'image', 'video', 'audio']) {
        final filtered = await run('models', {
          'provider_id': 'openrouter',
          'kind': kind,
        });
        expect(filtered['ok'], true);
        expect(
          filtered['entries'],
          entries.where((entry) => entry['kind'] == kind),
        );
      }
      final sorted = await run('models', {
        'provider_id': 'openrouter',
        'sort': 'kind',
      });
      expect((sorted['entries'] as List).map((entry) => entry['kind']), [
        'audio',
        'chat',
        'chat',
        'image',
        'image',
        'video',
      ]);
      providers = [
        provider('openrouter').copyWith(
          models: [],
          imageModels: [],
          videoModels: [],
          audioModels: [],
        ),
      ];
      expect(
        (await run('models', {'provider_id': 'openrouter'}))['entries'],
        isEmpty,
      );
    },
  );

  test(
    'chat availability does not require a media capability registry',
    () async {
      final configured = provider('openai_compatible');
      for (final (config, reason) in [
        (configured, null),
        (configured.copyWith(enabled: false), 'provider_disabled'),
        (configured.copyWith(apiKey: ''), 'configuration_required'),
        (configured.copyWith(type: 'agnes'), 'model_disabled_or_unsupported'),
      ]) {
        providers = [config];

        final result = await run('models', {
          'provider_id': config.id,
          'kind': 'chat',
        });
        expect(result['ok'], true);
        final entry = (result['entries'] as List).single;
        expect(entry['id'], 'custom-chat-model');
        expect(entry['available'], reason == null);
        expect(entry['unavailable_reason'], reason);
        expect(entry['capabilities_known'], false);
        expect(entry['capabilities'], isNull);
        expect(entry['defaults'], isNull);
        expect(jsonEncode(result), isNot(contains('secret')));
      }
    },
  );

  test(
    'provider queries and help are available without a media host',
    () async {
      for (final host in [null, ToolOperationHost(operations, media: false)]) {
        manager.operationHost = host;
        final help = await manager.executeTool(
          name: 'Run',
          input: {'command': 'help'},
        );
        expect(help['output'], contains('\n  providers '));
        final directed = await manager.executeTool(
          name: 'Run',
          input: {'command': 'help', 'subcommand': 'providers'},
        );
        expect(
          directed['output'],
          contains('optional kind=chat|image|video|audio'),
        );
        expect((await run('list'))['entries'], isNotEmpty);
        final result = await run('models', {
          'provider_id': 'openrouter',
          'kind': 'chat',
        });
        expect(result['ok'], true);
        expect(result['entries'][0]['available'], true);
        final invalid = await run('models', {'kind': 'chat'});
        expect(invalid['hint'], contains('provider_id required'));
      }
    },
  );

  test(
    'all configured providers and models are returned without pagination',
    () async {
      final ids = List.generate(205, (index) => 'configured-model-$index');
      providers = [
        for (final id in ids)
          provider('openai_compatible', id: id).copyWith(imageModels: ids),
      ];
      for (final (action, options) in <(String, Map<String, dynamic>)>[
        ('list', {}),
        ('models', {'provider_id': ids.first, 'kind': 'image'}),
      ]) {
        final result = await run(action, options);
        expect((result['entries'] as List).map((entry) => entry['id']), ids);
        for (final key in [
          'total',
          'offset',
          'limit',
          'requested_limit',
          'has_more',
          'next_offset',
        ]) {
          expect(result.containsKey(key), false, reason: key);
        }
        for (final key in ['offset', 'limit']) {
          expect(
            (await run(action, {...options, key: 1}))['error_code'],
            'invalid_argument',
          );
        }
      }
    },
  );

  test(
    'provider read failures are explicit and recover on the next query',
    () async {
      failRead = true;
      final failed = await run('list');
      expect(failed['error_code'], 'unavailable');
      expect(jsonEncode(failed), isNot(contains('secret')));
      failRead = false;

      final denied = (await run('models', {
        'provider_id': 'openrouter',
        'kind': 'image',
      }))['entries'][0];
      expect(denied['available'], isTrue);

      expect(
        (await run('models', {
          'provider_id': 'openrouter',
          'kind': 'image',
        }))['entries'][0]['available'],
        true,
      );
      final unavailable = AiToolManager(
        NovelContentService(contentDb),
        workingOverlayService: manager.workingOverlayService,
        operationHost: ToolOperationHost(operations),
      )..registerAllTools();
      addTearDown(unavailable.dispose);
      expect(
        (await unavailable.executeTool(
          name: 'Run',
          input: {'command': 'providers', 'subcommand': 'list'},
        ))['error_code'],
        'unavailable',
      );
    },
  );

  test(
    'effective image capabilities match every channel without brand fallback',
    () {
      for (final type in [
        'agnes',
        'qwen',
        'doubao',
        'volcengine',
        'openrouter',
        'atlascloud',
      ]) {
        for (final entry
            in imageChannelModels[aiProviderTypeConfigFor(type)!.imageProtocol]!
                .entries) {
          final actual = providerModelResource(
            provider(type).copyWith(imageModels: [entry.key]),
            'image',
            entry.key,
          );
          expect(actual['available'], true, reason: '$type/${entry.key}');
          expect(
            actual['capabilities']['max_references'],
            entry.value.capabilities.maxReferences,
          );
          expect(
            actual['capabilities']['sizes'],
            entry.value.capabilities.sizes,
          );
        }
      }
      final unknown = providerModelResource(
        provider('openrouter'),
        'image',
        'unregistered/vendor/model',
      );
      expect(unknown['available'], true);
      expect(unknown['capabilities_known'], false);
      expect(unknown['capabilities'], isNull);
      final custom = providerModelResource(
        provider('openai_compatible'),
        'image',
        'unregistered/vendor/model',
      );
      expect(custom['available'], true);
      expect(custom['unavailable_reason'], isNull);
      expect(custom['capabilities_known'], false);
      final gemini = providerModelResource(
        provider('gemini').copyWith(imageModels: ['gemini-2.5-flash-image']),
        'image',
        'gemini-2.5-flash-image',
      );
      expect(gemini['capabilities_known'], true);
      expect(gemini['capabilities']['modes'], ['text', 'reference']);
      expect(gemini['capabilities']['ratios'], contains('16:9'));
      expect(gemini['capabilities']['max_references'], 3);
    },
  );

  test('video and audio expose adapter limits and consumed defaults', () async {
    final detail = (await run('models', {
      'provider_id': 'openrouter',
      'kind': 'video',
    }))['entries'][0];
    expect(detail['capabilities']['resolutions'], ['480p', '720p']);
    expect(
      detail['capabilities']['reference_roles'],
      isNot(contains('reference_video')),
    );
    final sound = (await run('models', {
      'provider_id': 'openrouter',
      'kind': 'audio',
    }))['entries'][0];
    expect(sound['capabilities']['output_formats'], ['pcm', 'mp3']);
    expect(sound['defaults']['response_format'], 'pcm');
    expect(sound['defaults']['sample_rate'], null);
    expect(
      sound['capabilities']['references']['audio']['mime_types'],
      isNot(contains('audio/pcm')),
    );
    expect(
      sound['capabilities']['requires_all_audio_references_mentioned'],
      true,
    );
  });

  test('disabled providers and missing credentials stay observable', () {
    final configured = provider('openrouter');
    for (final pair in [
      (configured.copyWith(enabled: false), 'provider_disabled'),
      (configured.copyWith(apiKey: ''), 'configuration_required'),
    ]) {
      final model = providerModelResource(
        pair.$1,
        'image',
        'openai/gpt-image-2',
      );
      expect(model['available'], false);
      expect(model['unavailable_reason'], pair.$2);
      expect(model['capabilities_known'], true);
    }
    expect(
      providerModelResource(
        configured,
        'image',
        'openai/gpt-image-2',
      )['unavailable_reason'],
      isNull,
    );
  });

  test(
    'providers are absent from resource discovery and reject resource tools',
    () async {
      for (final path in ['/', '/_schema']) {
        final entries = (await read(path))['entries'] as List;
        expect(entries, isNotEmpty);
        expect(
          entries.where((entry) => entry['collection'] == 'providers'),
          isEmpty,
        );
      }
      for (final path in [
        '/providers',
        '/providers/openrouter',
        '/providers/openrouter/models?kind=image',
        '/_schema/providers',
        '/works/work-current/providers',
      ]) {
        expect((await read(path))['ok'], false, reason: path);
      }
      for (final tool in ['Create', 'Write', 'Edit', 'Remove']) {
        final result = await manager.executeTool(
          name: tool,
          input: {
            'path': '/providers/openrouter',
            'fields': {'name': 'changed'},
            'old_text': 'a',
            'new_text': 'b',
          },
        );
        expect(result['ok'], false, reason: tool);
      }
      expect(providers, hasLength(2));
      expect((await run('list'))['entries'], hasLength(1));
      expect((await run('list', {'enabled': false}))['entries'], hasLength(1));
    },
  );
}
