// 职责: 验证供应商模型能力与路由、AI 设置校验边界及默认模型保留和清理。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/models/models_catalog.dart
//   lib/shared/models/production/image_request.dart
//   lib/shared/models/audio/request.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/provider_brand.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/services/production/generate_orchestrator.dart';
import 'package:reveric/shared/models/video/request.dart';

void main() {
  test('Qwen Token Plan persists independently and uses its own channel', () {
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      id: 'token-plan',
      builtin: false,
      type: 'qwen_token_plan',
      baseUrl: 'https://maas.qianwenaiapi.com/compatible-mode/v1',
      apiKey: 'test-key',
      imageModels: ['qwen-image-3.0-pro'],
    );
    final restored = AiProvider.fromJson(provider.toJson());
    expect(customAiProviderTypes, contains(AiProviderType.qwen_token_plan));
    expect(restored.typeEnum, AiProviderType.qwen_token_plan);
    expect(
      restored.effectiveBaseUrl,
      'https://token-plan.maas.qianwenaiapi.com/compatible-mode/v1',
    );
    expect(restored.supportedModelKinds, AiModelKind.values.toSet());
    expect(
      ProductionImageCapabilities(restored, 'qwen-image-3.0-pro').isSupported,
      true,
    );
    expect(providerLogoAsset(restored.type), providerLogoAsset('qwen'));
    expect(
      providerChannelUrls[restored.type],
      'https://www.qianwenai.com/benefits/tokenplan?shareCode=subTask..12980046..10274..,subTask..12980046..10274..',
    );
  });

  test('MiniMax chat uses the Anthropic-compatible entry of its base URL', () {
    expect(
      aiProviderTypeConfigs[AiProviderType.minimax]!.supportedModelKinds,
      containsAll([AiModelKind.chat, AiModelKind.video, AiModelKind.audio]),
    );
    for (final (input, expected) in [
      ('https://api.minimaxi.com', 'https://api.minimaxi.com/anthropic'),
      ('https://api.minimaxi.com/', 'https://api.minimaxi.com/anthropic'),
      ('https://api.minimaxi.com/v1', 'https://api.minimaxi.com/anthropic'),
      (
        'https://api.minimaxi.com/anthropic',
        'https://api.minimaxi.com/anthropic',
      ),
      ('https://relay.test/minimax', 'https://relay.test/minimax/anthropic'),
    ]) {
      expect(minimaxAnthropicBaseUrl(input), expected, reason: input);
    }
  });

  group('AI settings validation boundaries', () {
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      id: 'custom',
      builtin: false,
      enabled: true,
      apiKey: 'test-key',
      models: ['chat', 'keep'],
      imageModels: ['image'],
      embeddingModels: ['embedding'],
    );

    AiSettings settingsFor(AiProvider config) => AiSettings(
      providers: [config],
      defaultChatModelId: 'custom::chat',
      defaultChatReasoningEffort: 'high',
      defaultImageModelId: 'custom::image',
      defaultPlannerModelId: 'custom::chat',
      defaultWriterModelId: 'custom::keep',
    );

    test('loading and copying preserve unsupported provider selections', () {
      final unknown = provider.copyWith(type: 'test_xxx');
      final original = settingsFor(unknown);
      final restored = AiSettings.fromJson(
        original.toJson(),
      ).copyWith(providers: [unknown]);
      expect(restored.toJson(), original.toJson());
      expect(restored.providers.single, unknown);
      expect(
        AiSettings.mergeWithRequiredProviders([
          unknown.copyWith(builtin: true),
        ]).any(
          (config) => config.id == unknown.id && config.type == unknown.type,
        ),
        isTrue,
      );
      expect(restored.availableModelOptions, isEmpty);
      expect(unknown.isValid, isFalse);
      expect(() => unknown.typeEnum, throwsUnsupportedError);
      expect(() => restored.updateConfig(unknown), throwsUnsupportedError);
      expect(
        restored.findConfigForSelection(providerId: unknown.id, model: 'chat'),
        isNull,
      );
    });

    test('temporary unavailability and unrelated edits preserve defaults', () {
      final original = settingsFor(provider);
      for (final unavailable in [
        provider.copyWith(enabled: false),
        provider.copyWith(apiKey: ''),
        provider.copyWith(baseUrl: ''),
      ]) {
        expect(original.updateConfig(unavailable).toJson(), original.toJson());
      }
      final unknown = provider.copyWith(id: 'other', type: 'test_xxx');
      final mixed = original.copyWith(providers: [provider, unknown]);
      expect(
        mixed.updateConfig(provider.copyWith(name: 'Renamed')).toJson(),
        original.toJson(),
      );
    });

    test('removing models clears only their defaults and chat effort', () {
      final original = settingsFor(provider);
      final updated = original.updateConfig(
        provider.copyWith(models: ['keep']),
      );
      expect(updated.defaultChatModelId, isNull);
      expect(updated.defaultChatReasoningEffort, isNull);
      expect(updated.defaultPlannerModelId, isNull);
      expect(updated.defaultWriterModelId, 'custom::keep');
      expect(updated.defaultImageModelId, 'custom::image');
      final mediaRemoved = original.updateConfig(
        provider.copyWith(imageModels: []),
      );
      expect(mediaRemoved.defaultImageModelId, isNull);
      expect(mediaRemoved.defaultChatModelId, 'custom::chat');
      expect(mediaRemoved.defaultChatReasoningEffort, 'high');
    });

    test('deleting an unsupported provider clears only its references', () {
      final original = settingsFor(
        provider.copyWith(type: 'test_xxx'),
      ).copyWith(defaultWriterModelId: 'other::chat');
      final removed = original.removeConfig('custom');
      expect(removed.providers, isEmpty);
      expect(removed.defaultChatModelId, isNull);
      expect(removed.defaultChatReasoningEffort, isNull);
      expect(removed.defaultImageModelId, isNull);
      expect(removed.defaultPlannerModelId, isNull);
      expect(removed.defaultWriterModelId, 'other::chat');
    });

    test('explicit selection validates the requested model', () {
      final settings = settingsFor(provider);
      expect(
        settings
            .setDefaultOptionId(AiModelKind.chat, 'custom::keep')
            .defaultChatModelId,
        'custom::keep',
      );
      expect(
        settings
            .setDefaultOptionId(AiModelKind.chat, null)
            .defaultChatReasoningEffort,
        isNull,
      );
      expect(
        () => settings.setDefaultOptionId(AiModelKind.chat, 'custom::missing'),
        throwsArgumentError,
      );
      expect(
        () => settings.setDefaultOptionIdForRole(
          AiModelRole.writer,
          'custom::missing',
        ),
        throwsArgumentError,
      );
    });
  });

  test(
    'Volcengine keeps domestic routing and all four model lists after round trip',
    () {
      final config = aiProviderBuiltinById('doubao')!.copyWith(
        id: 'volcengine-custom',
        type: 'volcengine',
        baseUrl: 'https://override.example/v1',
        apiKey: 'shared-key',
        enabled: true,
        videoModels: ['doubao-seedance-2-5-260628'],
        audioModels: ['seed-audio-1.0'],
      );
      final settings = const AiSettings(providers: []).addCustomConfig(config);
      final provider = AiProvider.fromJson(
        settings.findConfigById(config.id)!.toJson(),
      );
      expect(customAiProviderTypes, contains(AiProviderType.volcengine));
      expect(provider.hasFixedBaseUrl, isTrue);
      expect(
        provider.effectiveBaseUrl,
        'https://ark.cn-beijing.volces.com/api/v3',
      );
      expect(provider.apiKey, 'shared-key');
      expect(provider.supportedModelKinds, {
        AiModelKind.chat,
        AiModelKind.image,
        AiModelKind.video,
        AiModelKind.audio,
      });
      expect(provider.availableModels, config.models);
      expect(provider.availableImageModels, config.imageModels);
      expect(provider.availableVideoModels, config.videoModels);
      expect(provider.availableAudioModels, config.audioModels);
      expect(provider.isValid, isTrue);
      expect(provider.copyWith(apiKey: '').isValid, isFalse);
      expect(
        AudioCapabilities('seed-audio-1.0').supportsProvider(provider),
        isTrue,
      );
      expect(productionProtocol(provider.type), VideoProtocol.ark_video);
      final image = ProductionImageCapabilities(
        provider,
        config.imageModels.first,
      );
      expect(ProductionImageCapabilities.supports(provider), isTrue);
      expect(image.ratios, contains('16:9'));
      expect(image.resolutions, ['1K', '1.5K', '2K']);
      expect(image.maxReferences, 10);
      image.validate(
        prompt: 'Landscape',
        ratio: '16:9',
        resolution: '2K',
        references: 1,
      );
      expect(
        () => image.validate(
          prompt: 'Landscape',
          ratio: '16:9',
          resolution: '2K',
          references: 11,
        ),
        throwsFormatException,
      );
    },
  );
  test('new Codex providers start with presets that remain editable', () {
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      id: 'local-codex',
      type: AiProviderType.codex.name,
      models: [],
      imageModels: [],
    );
    final settings = const AiSettings(providers: []).addCustomConfig(provider);
    final added = settings.findConfigById(provider.id)!;
    expect(added.builtin, false);
    expect(added.availableModels, codexPresetModels);
    expect(added.availableImageModels, codexPresetImageModels);
    expect(
      settings
          .updateConfig(added.copyWith(models: []))
          .findConfigById(provider.id)!
          .availableModels,
      isEmpty,
    );
  });

  test(
    'Codex presets do not replace supplied models or affect other types',
    () {
      final provider = aiProviderBuiltinById(
        'openai',
      )!.copyWith(id: 'custom', models: []);
      const settings = AiSettings(providers: []);
      expect(
        settings.addCustomConfig(provider).findConfigById(provider.id)!.models,
        isEmpty,
      );
      final codex = provider.copyWith(
        type: AiProviderType.codex.name,
        models: ['chosen-model'],
      );
      expect(settings.addCustomConfig(codex).findConfigById(codex.id)!.models, [
        'chosen-model',
      ]);
    },
  );

  test('Codex uses local credentials and exposes chat and image models', () {
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      id: 'local-codex',
      type: AiProviderType.codex.name,
      apiKey: '',
      baseUrl: '',
      enabled: true,
      models: ['test-model'],
    );
    expect(provider.hasApiKey, false);
    expect(provider.hasCredentialConfiguration, true);
    expect(provider.isValid, true);
    expect(provider.enableValidationMessage, isNull);
    expect(provider.effectiveBaseUrl, 'https://chatgpt.com/backend-api/codex');
    expect(provider.supportsModelKind(AiModelKind.image), true);
  });
  test(
    'removing a preset clears model defaults and edits do not restore it',
    () {
      final preset = aiProviderBuiltinById('deepseek')!.copyWith(
        enabled: true,
        apiKey: 'test-key',
        models: ['chat'],
        imageModels: ['image'],
        embeddingModels: ['embedding'],
      );
      final settings = AiSettings(
        providers: [preset],
        defaultChatModelId: 'deepseek::chat',
        defaultImageModelId: 'deepseek::image',
        defaultPlannerModelId: 'deepseek::chat',
        defaultWriterModelId: 'deepseek::chat',
      );
      final removed = settings.removeConfig('deepseek');
      expect(removed.defaultChatModelId, isNull);
      expect(removed.defaultImageModelId, isNull);
      expect(removed.defaultPlannerModelId, isNull);
      expect(removed.defaultWriterModelId, isNull);
      expect(
        removed
            .updateConfig(aiProviderBuiltinById('openai')!)
            .findConfigById('deepseek'),
        isNull,
      );
    },
  );

  test('default providers exclude removed hosted channels', () {
    expect(aiProviderBuiltinById('reveric'), isNull);
    expect(aiProviderBuiltinById('public_welfare'), isNull);
    expect(AiSettings.defaults().providers, isEmpty);
    expect(
      AiProviderType.values.map((type) => type.name),
      isNot(contains('reveric')),
    );
  });
}
