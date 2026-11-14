// 职责: 按供应商实例解析图片和视频能力，隔离插件声明与内置渠道目录。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/models/image/channels.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/models/plugin/provider_registry.dart
import 'ai_provider.dart';
import 'image/channels.dart';
import 'video/channels.dart';
import 'video/config.dart';
import 'video/request.dart';
import 'plugin/provider_registry.dart';

typedef ImageModelSpec = ({
  ImageModelCapabilities capabilities,
  ImageRequestDefaults requestDefaults,
  Map<String, dynamic> rawDefaults,
});
typedef VideoModelSpec = ({
  VideoModelCapabilities capabilities,
  VideoRequestDefaults requestDefaults,
  Map<String, dynamic> rawDefaults,
});

ImageModelSpec? resolveImageModel(AiProvider provider, String? modelId) {
  if (modelId == null) {
    return null;
  }
  if (provider.isPluginProvider) {
    final model = pluginProviderModels.find(
      provider,
      AiModelKind.image,
      modelId,
    );
    return model == null
        ? null
        : (
            capabilities: model.image!,
            requestDefaults: model.imageDefaults,
            rawDefaults: model.requestDefaults,
          );
  }
  final channel = lookupImageChannelModel(provider.type, modelId);
  return channel == null
      ? null
      : (
          capabilities: channel.capabilities,
          requestDefaults: channel.requestDefaults,
          rawDefaults: channel.requestDefaults.toJson(),
        );
}

VideoModelSpec? resolveVideoModel(AiProvider provider, String? modelId) {
  if (modelId == null) {
    return null;
  }
  if (provider.isPluginProvider) {
    final model = pluginProviderModels.find(
      provider,
      AiModelKind.video,
      modelId,
    );
    return model == null
        ? null
        : (
            capabilities: model.video!,
            requestDefaults: model.videoDefaults,
            rawDefaults: model.requestDefaults,
          );
  }
  final channel = lookupVideoChannelModel(provider.type, modelId);
  return channel == null
      ? null
      : (
          capabilities: channel.capabilities,
          requestDefaults: channel.requestDefaults,
          rawDefaults: channel.requestDefaults.toJson(),
        );
}

extension VideoModelSpecOptions on VideoModelSpec {
  Set<String> get resolutions => capabilities.resolutions;
  Set<String> get ratios => capabilities.ratios;
  Set<int> get durations => capabilities.durations;
  Set<VideoInputRole> get frameRoles => capabilities.frameRoles;
  bool get requiresAudio => requestDefaults.audio != null;
  bool get requiresPromptExtend => requestDefaults.promptExtend != null;
  bool get supportsAdaptiveTextRatio =>
      capabilities.supportsAdaptiveTextRatio && ratios.contains('adaptive');
  Map<String, int> get maxDurationByResolution =>
      capabilities.maxDurationByResolution;
  Set<int> durationsForResolution(String resolution) {
    final maximum = maxDurationByResolution[resolution];
    return maximum == null
        ? durations
        : durations.where((value) => value <= maximum).toSet();
  }

  int get minDurationSeconds => durations.reduce((a, b) => a < b ? a : b);
  int get maxDurationSeconds => durations.reduce((a, b) => a > b ? a : b);
}
