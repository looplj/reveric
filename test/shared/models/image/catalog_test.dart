// 职责: 验证图像目录、渠道覆盖、供应商预设与制作规格之间的约束一致。
// 关联文件:
//   lib/shared/models/image/catalog.dart
//   lib/shared/models/production/image_request.dart
//   lib/shared/models/ai_provider.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/services/ai/image/agnes.dart';
import '../../../helpers/media_provider_types.dart';

void main() {
  test(
    'OpenRouter image additions retain channel-specific reference limits',
    () {
      final qwen = lookupImageChannelModel(
        'openrouter',
        'qwen/qwen-image-2.1-turbo',
      )!;
      final krea = lookupImageChannelModel('openrouter', 'krea/k3-edit')!;
      qwen.capabilities.validateReferences(0);
      qwen.capabilities.validateReferences(4);
      expect(
        () => qwen.capabilities.validateReferences(5),
        throwsFormatException,
      );
      expect(qwen.capabilities.size('1:4', '2K'), isNull);
      expect(qwen.requestDefaults.size, isNull);
      expect(
        () => krea.capabilities.validateReferences(0),
        throwsFormatException,
      );
      krea.capabilities.validateReferences(1);
      krea.capabilities.validateReferences(8);
      expect(
        () => krea.capabilities.validateReferences(9),
        throwsFormatException,
      );
    },
  );

  test(
    'configured unknown image models use defaults across provider protocols',
    () {
      for (final type in [
        'openrouter',
        'openai_compatible',
        'qwen',
        'agnes',
        'atlascloud',
        'gemini',
      ]) {
        final provider = aiProviderBuiltinById(
          'openai',
        )!.copyWith(type: type, enabled: true, imageModels: ['custom-image']);
        final caps = ProductionImageCapabilities(provider, 'custom-image');
        caps.validate(
          prompt: 'cover',
          ratio: 'auto',
          resolution: 'auto',
          references: 0,
        );
        expect(caps.size('auto', 'auto'), isNull);
        expect(caps.verifiedCapabilities, isNull);
        expect(caps.ratios.first, 'auto');
        expect(caps.resolutions.first, 'auto');
        for (final ratio in caps.ratios) {
          for (final resolution in caps.resolutions) {
            caps.validate(
              prompt: 'cover',
              ratio: ratio,
              resolution: resolution,
              references: 32,
            );
          }
        }
        expect(caps.allowsReferenceCount(32), isTrue);
        expect(
          caps.size('16:9', '2K'),
          ['openrouter', 'gemini'].contains(type) ? null : '2048x1152',
        );
        expect(
          () => caps.validate(
            prompt: 'cover',
            ratio: 'invalid',
            resolution: '2K',
            references: 1,
          ),
          throwsFormatException,
        );
        expect(
          () =>
              ProductionImageCapabilities(provider, 'not-configured').validate(
                prompt: 'cover',
                ratio: 'auto',
                resolution: 'auto',
                references: 0,
              ),
          throwsFormatException,
        );
        expect(
          () =>
              ProductionImageCapabilities(
                provider.copyWith(enabled: false),
                'custom-image',
              ).validate(
                prompt: 'cover',
                ratio: 'auto',
                resolution: 'auto',
                references: 0,
              ),
          throwsFormatException,
        );
      }
    },
  );

  test('Qwen presets retain only 3.0 and Wan while 2.x stays usable', () {
    const presets = [
      'qwen-image-3.0-pro',
      'qwen-image-3.0',
      'wan2.7-image-pro',
    ];
    expect(imageModelsForProvider('qwen'), presets);
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      id: 'qwen-custom',
      type: 'qwen',
      enabled: true,
      imageModels: [],
    );
    final settings = const AiSettings(providers: []).addCustomConfig(provider);
    expect(settings.findConfigById(provider.id)!.availableImageModels, presets);
    for (final model in [
      'qwen-image-2.0',
      'qwen-image-2.0-pro',
      'qwen-image-2.1-pro',
      'qwen-image-2.1-turbo',
    ]) {
      expect(lookupImageModel(model), isNotNull);
      expect(
        lookupImageChannelModel(
          imageProviderType(ImageProtocol.qwen_image),
          model,
        ),
        isNotNull,
      );
      final custom = provider.copyWith(imageModels: [model]);
      expect(
        const AiSettings(providers: [])
            .addCustomConfig(custom)
            .findConfigById(custom.id)!
            .availableImageModels,
        [model],
      );
      ProductionImageCapabilities(custom, model).validate(
        prompt: 'cover',
        ratio: '1:1',
        resolution: '2K',
        references: 1,
      );
    }
  });

  test('Wan production validates the output budget for each input mode', () {
    final provider = aiProviderBuiltinById(
      'openai',
    )!.copyWith(type: 'qwen', enabled: true, imageModels: ['wan2.7-image-pro']);
    final caps = ProductionImageCapabilities(provider, 'wan2.7-image-pro');
    expect(caps.maxReferences, 9);
    for (final ratio in caps.ratios) {
      caps.validate(
        prompt: 'cover',
        ratio: ratio,
        resolution: '4K',
        references: 0,
      );
      caps.validate(
        prompt: 'cover',
        ratio: ratio,
        resolution: '2K',
        references: 9,
      );
      expect(
        () => caps.validate(
          prompt: 'cover',
          ratio: ratio,
          resolution: '4K',
          references: 1,
        ),
        throwsFormatException,
      );
    }
  });

  test(
    'channel overrides replace individual fields, including empty values',
    () {
      const base = ImageModelCapabilities(
        ratios: {'1:1', '16:9'},
        resolutions: {'1K', '2K'},
        maxReferences: 4,
        maxPixels: ConfigValue(4194304),
        maxEditPixels: ConfigValue(1048576),
      );
      final result = base.merge(
        const ImageModelCapabilities(
          ratios: {},
          maxReferences: 0,
          maxPixels: ConfigValue(null),
          maxEditPixels: ConfigValue(null),
        ),
      );
      expect(result.ratios, isEmpty);
      expect(result.resolutions, {'1K', '2K'});
      expect(result.maxReferences, 0);
      expect(result.maxPixels, isNull);
      expect(result.maxEditPixels, isNull);
      const defaults = ImageRequestDefaults(
        outputFormat: ConfigValue('png'),
        watermark: ConfigValue(false),
      );
      final overridden = defaults.merge(
        const ImageRequestDefaults(outputFormat: ConfigValue(null)),
      );
      expect(overridden.outputFormat, isNull);
      expect(overridden.watermark, false);
    },
  );

  test('model and channel specifications stay distinct', () {
    final seed = lookupImageModel('doubao-seedream-5-0-260128')!;
    final routed = lookupImageChannelModel(
      imageProviderType(ImageProtocol.openrouter_image),
      'bytedance-seed/seedream-5-0-lite',
    )!;
    expect(seed.capabilities.resolutions, {'2K', '3K'});
    expect(routed.capabilities.resolutions, {'2K', '4K'});
    expect(routed.requestDefaults.size, isNull);
    expect(routed.requestDefaults.outputFormat, isNull);
    expect(routed.capabilities.maxPixels, isNull);
    final qwen = lookupImageChannelModel(
      imageProviderType(ImageProtocol.qwen_image),
      'qwen-image-3.0',
    )!;
    final qwenRouted = lookupImageChannelModel(
      imageProviderType(ImageProtocol.openrouter_image),
      'qwen/qwen-image-3',
    )!;
    expect(qwen.capabilities.maxReferences, 3);
    expect(qwenRouted.capabilities.maxReferences, 4);
    expect(
      lookupImageChannelModel(
        imageProviderType(ImageProtocol.qwen_image),
        'qwen-image-2.0-pro-2026-06-22',
      )!.catalogId,
      'qwen-image-2.0-pro',
    );
    expect(lookupImageModel('qwen-image-unknown'), isNull);
    expect(recognizeImageModel('doubao-seedream-5-5-261028'), 'seedream-5.5');
    final seedream55 = lookupImageChannelModel(
      'volcengine',
      'doubao-seedream-5-5-261028',
    )!;
    expect(seedream55.catalogId, 'seedream-5.5');
    expect(seedream55.capabilities.resolutions, {'1K', '1.5K', '2K'});
    expect(seedream55.capabilities.maxReferences, 10);
    expect(seedream55.requestDefaults.outputFormat, 'png');
    expect(seedream55.requestDefaults.promptOptimization, 'standard');
    expect(
      imageModelsForProvider('doubao').first,
      'doubao-seedream-5-5-261028',
    );
  });

  for (final protocol in imageChannelModels.entries) {
    test('${protocol.key} options validate and retain reference bounds', () {
      for (final entry in protocol.value.entries) {
        final caps = entry.value.capabilities;
        for (final ratio in caps.ratios) {
          for (final resolution in caps.resolutions) {
            caps.validateSize(caps.size(ratio, resolution));
          }
        }
        caps.validateReferences(caps.minReferences);
        caps.validateReferences(caps.maxReferences);
        expect(() => caps.validateReferences(-1), throwsFormatException);
        expect(
          () => caps.validateReferences(caps.maxReferences + 1),
          throwsFormatException,
        );
      }
    });
  }

  test('new image providers get only their own presets and preserve edits', () {
    for (final type in ['qwen', 'volcengine', 'openrouter', 'atlascloud']) {
      final provider = aiProviderBuiltinById(
        'openai',
      )!.copyWith(id: 'custom-$type', type: type, imageModels: []);
      final settings = const AiSettings(
        providers: [],
      ).addCustomConfig(provider);
      final added = settings.findConfigById(provider.id)!;
      expect(added.availableImageModels, imageModelsForProvider(type));
      expect(added.availableImageModels, isNotEmpty);
      expect(
        settings
            .updateConfig(added.copyWith(imageModels: []))
            .findConfigById(provider.id)!
            .availableImageModels,
        isEmpty,
      );
    }
    final routed = imageModelsForProvider('openrouter');
    expect(routed, [
      'google/gemini-nano-banana-2.1',
      'black-forest-labs/flux-3-image',
      'openai/gpt-image-2.6-sunburst',
      'openai/gpt-image-2.6-flare',
      'openai/gpt-image-2.5-sunburst',
      'openai/gpt-image-2.5-flare',
      'bytedance-seed/seedream-5-0-pro',
      'qwen/qwen-image-3',
      'openai/gpt-image-2',
    ]);
    expect(routed.where((m) => m.endsWith('-vector')), isEmpty);
  });

  test(
    'new Agnes configurations get image presets once and preserve later edits',
    () {
      final empty = aiProviderBuiltinById('openai')!.copyWith(
        id: 'agnes-custom',
        type: 'agnes',
        imageModels: [],
        videoModels: [],
      );
      final settings = const AiSettings(providers: []).addCustomConfig(empty);
      final added = settings.findConfigById(empty.id)!;
      expect(added.imageModels, imageModelsForProvider('agnes'));
      expect(added.videoModels, isEmpty);
      expect(
        settings
            .updateConfig(added.copyWith(imageModels: []))
            .findConfigById(empty.id)!
            .imageModels,
        isEmpty,
      );
      expect(
        const AiSettings(providers: [])
            .addCustomConfig(
              empty.copyWith(imageModels: ['agnes-image-2.5-flash']),
            )
            .findConfigById(empty.id)!
            .imageModels,
        ['agnes-image-2.5-flash'],
      );
    },
  );
  final provider = aiProviderBuiltinById('openai')!.copyWith(
    type: 'agnes',
    enabled: true,
    baseUrl: '',
    apiKey: 'key',
    imageModels: imageModelsForProvider('agnes'),
    videoModels: ['agnes-video-2.5-flash'],
  );
  test('Agnes is a preset image/video provider with its official endpoint', () {
    expect(customAiProviderTypes, contains(AiProviderType.agnes));
    expect(provider.supportedModelKinds, {
      AiModelKind.image,
      AiModelKind.video,
    });
    expect(provider.effectiveBaseUrl, agnesDefaultBaseUrl);
    expect(provider.hasFixedBaseUrl, true);
    expect(
      provider.copyWith(baseUrl: 'https://proxy.test/v1').effectiveBaseUrl,
      agnesDefaultBaseUrl,
    );
    expect(provider.availableModels, isEmpty);
    expect(provider.availableAudioModels, isEmpty);
    expect(provider.availableVideoModels, ['agnes-video-2.5-flash']);
    expect(provider.isValid, true);
  });

  for (final model in imageModelsForProvider('agnes')) {
    test('$model production sizes round trip to documented API parameters', () {
      final caps = ProductionImageCapabilities(provider, model);
      final entry = lookupImageChannelModel(
        imageProviderType(ImageProtocol.agnes_image),
        model,
      )!;
      for (final resolution in caps.resolutions) {
        for (final ratio in caps.ratios) {
          caps.validate(
            prompt: 'combine',
            ratio: ratio,
            resolution: resolution,
            references: 2,
          );
          final size = caps.size(ratio, resolution)!;
          expect(
            agnesSizeParameters(entry, size),
            (entry.protocolOptions as AgnesImageOptions?)?.sizeTiersWithRatio ??
                    false
                ? {'size': resolution, 'ratio': ratio}
                : {'size': size},
          );
        }
      }
    });
  }

  test('unknown image variants never inherit Agnes capabilities', () {
    expect(lookupImageModel('agnes-image-2.5-pro'), isNull);
    expect(
      () => ProductionImageCapabilities(provider, 'unknown').validate(
        prompt: 'image',
        ratio: 'auto',
        resolution: 'auto',
        references: 0,
      ),
      throwsFormatException,
    );
    expect(
      imageModelsCatalog['agnes-image-2.5-flash']!.capabilities.size(
        '21:9',
        '4K',
      ),
      '6272x2688',
    );
    expect(
      () => imageModelsCatalog['agnes-image-2.0-flash']!.capabilities.size(
        '16:9',
        '4K',
      ),
      throwsFormatException,
    );
  });

  test('gpt image 2.6 complexity comes from the catalog', () {
    for (final id in ['gpt-image-2.6-sunburst', 'gpt-image-2.6-flare']) {
      final entry = lookupImageModel(id)!;
      expect(entry.capabilities.complexityLevels, {'low', 'medium', 'high'});
      expect(entry.requestDefaults.complexity, 'high');
    }
    expect(
      lookupImageModel('gpt-image-2.5-sunburst')!.capabilities.complexityLevels,
      isEmpty,
    );
    expect(
      lookupImageModel('gpt-image-2')!.capabilities.complexityLevels,
      isEmpty,
    );

    const sunburst = 'gpt-image-2.6-sunburst';
    expect(imageComplexityFor('openai', sunburst, null), 'high');
    expect(imageComplexityFor('openai', sunburst, 'low'), 'low');
    expect(imageComplexityFor('openai', sunburst, 'max'), 'high');
    expect(imageComplexityFor('openai', 'gpt-image-2', 'high'), isNull);
    expect(
      imageComplexityLevels('openrouter', 'openai/gpt-image-2.6-sunburst'),
      {'low', 'medium', 'high'},
    );
    const resolutions = {'1K', '2K', '4K'};
    expect(
      lookupImageModel('gpt-image-2.6-sunburst')!.capabilities.resolutions,
      resolutions,
    );
    expect(
      lookupImageModel('gpt-image-2.5-sunburst')!.capabilities.resolutions,
      resolutions,
    );
    expect(
      lookupImageChannelModel(
        'openrouter',
        'openai/gpt-image-2.6-sunburst',
      )!.capabilities.resolutions,
      resolutions,
    );
    expect(
      lookupImageChannelModel(
        'openrouter',
        'openai/gpt-image-2.5-flare',
      )!.capabilities.resolutions,
      resolutions,
    );
    expect(lookupImageModel('gpt-5.4-image-2')!.capabilities.resolutions, {
      'auto',
    });
    expect(
      imageComplexityFor('openrouter', 'openai/gpt-image-2.6-flare', null),
      'high',
    );
    expect(
      imageComplexityLevels(
        'atlascloud',
        'openai/gpt-image-2.6-sunburst/text-to-image',
      ),
      isEmpty,
    );
    expect(
      imageComplexityLevels(
        'atlascloud',
        'openai/gpt-image-2.5-sunburst/text-to-image',
      ),
      isEmpty,
    );
  });
}
