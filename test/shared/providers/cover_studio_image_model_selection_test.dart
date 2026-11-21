// 职责: 验证封面和地图工作台使用用户默认图片模型，无需账号。
// 关联文件:
//   lib/shared/providers/ai_providers.dart
//   lib/shared/models/ai_provider.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/testing.md

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/map_studio_providers.dart';
import 'package:reveric/shared/providers/cover_studio_providers.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';

void main() {
  test('cover and map use the configured image default without an account', () {
    final container = ProviderContainer(
      overrides: [aiSettingsProvider.overrideWithValue(_settings)],
    );
    addTearDown(container.dispose);

    final selection = container.read(coverStudioImageModelSelectionProvider);

    expect(selection?.config.id, 'external');
    expect(selection?.model, 'external-image');
    final mapSelection = container.read(mapStudioImageModelSelectionProvider);
    expect(mapSelection?.config.id, 'external');
    expect(mapSelection?.model, 'external-image');
  });
  test(
    'draft selection switches provider, resets, and never saves defaults',
    () {
      final first = _externalImageProvider.copyWith(
        imageModels: ['gpt-image-2'],
      );
      final second = first.copyWith(
        id: 'second',
        imageModels: ['gpt-image-2.5-flare'],
      );
      final settings = AiSettings(
        providers: [first, second],
        defaultImageModelId: 'external::gpt-image-2',
      );
      final container = ProviderContainer(
        overrides: [aiSettingsProvider.overrideWithValue(settings)],
      );
      addTearDown(container.dispose);
      final provider = coverStudioControllerProvider('novel');
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      final controller = container.read(provider.notifier);
      controller.setModel('second::gpt-image-2.5-flare');
      expect(container.read(provider).modelId, 'second::gpt-image-2.5-flare');
      final choices = container.read(coverDraftImageChoicesProvider('novel'))!;
      expect(choices.provider.id, 'second');
      expect(choices.model, 'gpt-image-2.5-flare');
      final map = container.read(
        mapDraftImageModelSelectionProvider('second::gpt-image-2.5-flare'),
      )!;
      expect(map.config.id, 'second');
      expect(map.model, 'gpt-image-2.5-flare');
      controller.setModel('second::removed');
      expect(container.read(provider).modelId, 'second::gpt-image-2.5-flare');
      expect(
        container.read(studioImageModelSelectionProvider('second::removed')),
        isNull,
      );
      controller.startNewDraft();
      expect(container.read(provider).modelId, isNull);
      expect(
        container.read(coverDraftImageChoicesProvider('novel'))!.provider.id,
        'external',
      );
      expect(
        container.read(aiSettingsProvider).defaultImageModelId,
        'external::gpt-image-2',
      );
    },
  );

  test('explicit unavailable models never fall back to the default', () {
    final settings = AiSettings(
      providers: [
        _externalImageProvider,
        _externalImageProvider.copyWith(id: 'disabled', enabled: false),
      ],
      defaultImageModelId: 'external::external-image',
    );
    final container = ProviderContainer(
      overrides: [aiSettingsProvider.overrideWithValue(settings)],
    );
    addTearDown(container.dispose);
    for (final id in [
      'disabled::external-image',
      'external::removed',
      'missing::external-image',
    ]) {
      expect(container.read(studioImageModelSelectionProvider(id)), isNull);
      expect(container.read(mapDraftImageModelSelectionProvider(id)), isNull);
    }
  });
}

final _settings = AiSettings(
  providers: [_externalImageProvider],
  defaultImageModelId: 'external::external-image',
);

final _externalImageProvider = AiProvider(
  asrModels: const [],
  audioModels: const [],
  videoModels: const [],
  id: 'external',
  name: 'External image provider',
  builtin: false,
  type: 'openai',
  enabled: true,
  apiKey: 'test-api-key',
  baseUrl: 'https://example.invalid/v1',
  models: const [],
  imageModels: const ['external-image'],
  embeddingModels: const [],
  temperature: 0.7,
  maxTurns: 8,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026, 1, 1),
  deletedAt: notDeletedSentinel,
);
