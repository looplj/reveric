// 职责: 地图工作台 AI 接线 — 默认图片模型选择、出图/改图 callback 与地名回读服务
// 关联文件:
//   lib/shared/providers/ai_providers.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/services/map_place_name_reader.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/ai-calling.md
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import '../models/image/choices.dart';

import '../models/ai_provider.dart';
import '../services/ai/image.dart';
import '../services/ai/tools.dart'
    show AiImageGenerationCallback, AiMultiImageEditCallback;

import 'settings_providers.dart';
import 'plugin_providers.dart';
import 'video_tasks.dart';
import '../services/map_place_name_reader.dart' show MapPlaceNameReader;

export 'map_studio_controller.dart' show mapStudioControllerProvider;

part 'map_studio_providers.g.dart';

final mapImageChoicesProvider = Provider<ImageModelChoices?>((ref) {
  final selection = ref.watch(mapStudioImageModelSelectionProvider);
  return selection == null
      ? null
      : ImageModelChoices(selection.config, selection.model);
});

class MapStudioImageModelSelection {
  const MapStudioImageModelSelection({
    required this.config,
    required this.model,
  });

  final AiProvider config;
  final String model;
}

@riverpod
MapStudioImageModelSelection? mapStudioImageModelSelection(Ref ref) {
  final option = ref.watch(
    resolvedAiModelOptionForKindProvider(kind: AiModelKind.image),
  );
  if (option == null) {
    return null;
  }
  final config = ref
      .watch(aiSettingsProvider)
      .findConfigById(option.providerId);
  if (config == null) {
    return null;
  }
  return MapStudioImageModelSelection(config: config, model: option.model);
}

/// 地图出图 / 改图使用默认图片模型。
@riverpod
AiMultiImageEditCallback? mapImageEditCallback(Ref ref) {
  final selection = ref.watch(mapStudioImageModelSelectionProvider);
  if (selection == null) return null;
  final host = ref.watch(pluginHostServiceProvider);
  final references = ref.watch(referenceStorageServiceProvider);
  return (
    String prompt, {
    required List<String> imageData,
    String? model,
    ImageInvocationOptions? options,
    String? size,
    String? quality,
    String? complexity,
  }) async {
    final service = await resolveDirectImageService(
      selection.config,
      model ?? selection.model,
      host: host,
      references: references,
    );
    return service.editImages(
      prompt,
      imageData: imageData,
      model: model,
      options: options,
      size: size,
      quality: quality,
      complexity: complexity,
    );
  };
}

/// 文生图 callback：地图首次生成（无参考图）时使用。
@riverpod
AiImageGenerationCallback? mapImageGenerateCallback(Ref ref) {
  final selection = ref.watch(mapStudioImageModelSelectionProvider);
  if (selection == null) return null;
  final host = ref.watch(pluginHostServiceProvider);
  final references = ref.watch(referenceStorageServiceProvider);
  return (
    String prompt, {
    String? model,
    ImageInvocationOptions? options,
    String? size,
    String? quality,
    String? complexity,
  }) async {
    final service = await resolveDirectImageService(
      selection.config,
      model ?? selection.model,
      host: host,
      references: references,
    );
    return service.generateImage(
      prompt,
      model: model,
      options: options,
      size: size,
      quality: quality,
      complexity: complexity,
    );
  };
}

@riverpod
MapPlaceNameReader? mapPlaceNameReader(Ref ref) {
  final option = ref.watch(
    resolvedAiModelOptionForKindProvider(kind: AiModelKind.chat),
  );
  if (option == null) {
    return null;
  }
  final config = ref
      .watch(aiSettingsProvider)
      .findConfigById(option.providerId);
  if (config == null) {
    return null;
  }
  return MapPlaceNameReader(config: config, model: option.model);
}
