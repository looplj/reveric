// 职责: 验证实例模型解析、插件显式模式、通用槽位与冻结能力/默认值不受刷新影响。
// 关联文件:
//   lib/shared/models/provider_model.dart
//   lib/shared/models/plugin/provider_registry.dart
//   lib/shared/models/video/capabilities.dart
//   lib/shared/models/production/image_request.dart
//   lib/shared/services/production/generate_orchestrator.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'dart:ui' show Locale;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/generation/task.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/models/plugin/provider.dart';
import 'package:reveric/shared/models/plugin/provider_registry.dart';
import 'package:reveric/shared/models/provider_model.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/production/input.dart';
import 'package:reveric/shared/models/video/config.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/capabilities.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/production/generate_orchestrator.dart';
import 'package:reveric/shared/services/ai/provider_resources.dart';

void main() {
  late AiProvider provider;
  setUp(() {
    aiProviderTypeConfigs['plugin:test.resolution'] =
        const AiProviderTypeConfig(
          displayName: 'Workflows',
          modelIdSource: ModelIdSource.registered,
          providerModelKinds: {AiModelKind.image, AiModelKind.video},
        );
    provider = aiProviderBuiltinById('openai')!.copyWith(
      id: 'workflow-instance',
      type: 'plugin:test.resolution',
      enabled: true,
      apiKey: '',
      baseUrl: '',
      models: [],
      imageModels: ['gpt-image-2'],
      videoModels: ['workflow'],
    );
    pluginProviderModels.replace(
      provider,
      parsePluginProviderModels([
        {
          'kind': 'image',
          'id': 'gpt-image-2',
          'name': {'en': 'Painter', 'zh-CN': '画师'},
          'capabilities': {
            'ratios': ['7:5'],
            'resolutions': ['custom'],
            'sizes': {
              'custom': {'7:5': '1400x1000'},
            },
            'minReferences': 0,
            'maxReferences': 1,
            'unlimitedReferences': false,
            'referenceTransport': 'uploaded',
            'complexityLevels': ['fine'],
            'qualityLevels': ['draft', 'best'],
          },
          'requestDefaults': {
            'complexity': 'fine',
            'workflow': {'node': 'image'},
          },
        },
        {
          'kind': 'video',
          'id': 'workflow',
          'capabilities': {
            'ratios': ['adaptive'],
            'resolutions': ['720p'],
            'durations': [5],
            'modes': ['first_last_frame'],
            'frameRoles': ['first_frame', 'last_frame'],
            'maxMiddleFrames': 0,
            'maxReferences': 2,
            'references': {
              'image': {'maxCount': 2},
            },
            'supportsAudioOnlyReference': false,
            'supportsAdaptiveTextRatio': false,
            'supportsLastFrameOnly': false,
            'framesRequireAdaptiveRatio': true,
            'supportsCertifiedAssets': false,
            'draft': null,
          },
          'requestDefaults': {
            'audio': false,
            'workflow': {'node': 'video'},
          },
        },
      ]),
    );
  });
  tearDown(() {
    pluginProviderModels.removePlugin('test.resolution');
    aiProviderTypeConfigs.remove('plugin:test.resolution');
  });
  test('plugin model labels follow the selected language', () {
    for (final entry in {
      const Locale('en'): 'Painter',
      const Locale('zh', 'CN'): '画师',
    }.entries) {
      final settings = AiSettings(
        providers: [provider],
        modelNameLocale: entry.key,
      );
      expect(
        settings
            .availableModelOptionsForKind(AiModelKind.image)
            .single
            .modelDisplayName,
        entry.value,
      );
    }
  });
  test(
    'image selection uses only instance declarations and custom dimensions',
    () {
      final capabilities = ProductionImageCapabilities(provider, 'gpt-image-2');
      expect(capabilities.isSupported, true);
      expect(capabilities.ratios, ['7:5']);
      expect(capabilities.resolutions, ['custom']);
      expect(capabilities.size('7:5', 'custom'), '1400x1000');
      expect(imageComplexityLevels(provider, 'gpt-image-2'), {'fine'});
      expect(imageComplexityFor(provider, 'gpt-image-2', null), 'fine');
      capabilities.validate(
        prompt: 'scene',
        ratio: '7:5',
        resolution: 'custom',
        references: 1,
      );
      expect(
        () => capabilities.validate(
          prompt: 'scene',
          ratio: '1:1',
          resolution: '1K',
          references: 1,
        ),
        throwsFormatException,
      );
      expect(
        providerModelResource(
          provider,
          'image',
          'gpt-image-2',
        )['capabilities']['ratios'],
        ['7:5'],
      );
      final settings = AiSettings(
        providers: [provider],
        defaultImageModelId: 'workflow-instance::gpt-image-2',
      );
      expect(
        settings.availableModelOptionsForKind(AiModelKind.image),
        hasLength(1),
      );
      pluginProviderModels.replace(provider, []);
      expect(settings.availableModelOptionsForKind(AiModelKind.image), isEmpty);
      expect(settings.defaultImageModelId, 'workflow-instance::gpt-image-2');
      expect(
        ProductionImageCapabilities(provider, 'gpt-image-2').isSupported,
        false,
      );
      expect(
        ProductionImageCapabilities(provider, 'gpt-image-2').ratios,
        isEmpty,
      );
    },
  );
  test(
    'plugin mode stays explicit and generic compilation keeps reference order',
    () {
      final spec = resolveVideoModel(provider, 'workflow')!;
      expect(productionEditingModes(provider, spec), [
        VideoMode.first_last_frame,
      ]);
      expect(
        productionSubmitMode(VideoMode.first_last_frame, [
          VideoInputRole.first_frame,
        ], explicit: true),
        VideoMode.first_last_frame,
      );
      expect(
        productionSubmitMode(VideoMode.first_last_frame, [
          VideoInputRole.first_frame,
        ]),
        VideoMode.first_frame,
      );
      const request = VideoRequest(
        modelId: 'workflow',
        prompt: 'scene',
        mode: VideoMode.first_last_frame,
        resolution: '720p',
        ratio: 'adaptive',
        audio: false,
      );
      final compiled = compileProductionPrompt(provider, request, [
        const ResolvedProductionInput(
          ProductionInput(
            id: 'tail-input',
            refType: ProductionInputType.asset,
            refId: 'tail',
            role: VideoInputRole.last_frame,
          ),
          'tail',
        ),
        const ResolvedProductionInput(
          ProductionInput(
            id: 'first-input',
            refType: ProductionInputType.asset,
            refId: 'first',
            role: VideoInputRole.first_frame,
          ),
          'first',
        ),
      ]);
      expect(compiled.referenceSlots.map((slot) => slot.assetId), [
        'tail',
        'first',
      ]);
      expect(compiled.referenceSlots.map((slot) => slot.inputId), [
        'tail-input',
        'first-input',
      ]);
      expect(compiled.referenceSlots.map((slot) => slot.slot), [
        'last frame',
        'first frame',
      ]);
      VideoCapabilities.forProvider(provider).validateParameters(compiled, [
        VideoInputRole.last_frame,
        VideoInputRole.first_frame,
      ]);
      expect(
        () => VideoCapabilities.forProvider(
          provider,
        ).validateParameters(compiled, [VideoInputRole.first_frame]),
        throwsA(isA<VideoException>()),
      );
      final frozen =
          GenerationRequest.fromJson(
                jsonDecode(
                      jsonEncode(
                        VideoGenerationRequest(
                          compiled,
                          capabilities: spec.capabilities,
                          requestDefaults: spec.rawDefaults,
                        ).toJson(),
                      ),
                    )
                    as Map<String, dynamic>,
              )
              as VideoGenerationRequest;
      pluginProviderModels.replace(provider, []);
      expect(productionSupportsVideoModel(provider, 'workflow'), false);
      VideoCapabilities.forProvider(
        provider,
        capabilities: frozen.capabilities,
        defaults: VideoRequestDefaults.fromJson(frozen.requestDefaults!),
      ).validateParameters(frozen.request, [
        VideoInputRole.last_frame,
        VideoInputRole.first_frame,
      ]);
      expect(frozen.requestDefaults!['workflow'], {'node': 'video'});
    },
  );
  test('image request freezes the full defaults including future fields', () {
    final spec = resolveImageModel(provider, 'gpt-image-2')!;
    final request = ProductionImageRequest(
      providerId: provider.id,
      modelId: 'gpt-image-2',
      originalPrompt: 'scene',
      prompt: 'scene',
      ratio: '7:5',
      resolution: 'custom',
      size: '1400x1000',
    ).withModelSnapshot(spec.capabilities, spec.rawDefaults);
    final restored = ProductionImageRequest.fromJson(
      jsonDecode(jsonEncode(request.toJson())) as Map<String, dynamic>,
    );
    pluginProviderModels.replace(provider, []);
    expect(restored.capabilities!.ratios, {'7:5'});
    expect(restored.requestDefaults, {
      'complexity': 'fine',
      'workflow': {'node': 'image'},
    });
  });
}
