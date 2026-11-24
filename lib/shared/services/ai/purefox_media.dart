// 职责: 拉取 PureFox 媒体网关的模型列表，并登记视频模型的规格。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/providers/purefox_media_providers.dart
//   lib/shared/widgets/settings/provider_config_panel.dart
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/ai_provider.dart';
import '../../models/video/catalog.dart';
import '../../models/video/channels.dart';
import '../../models/video/request.dart';
import '../../logger/app_logger.dart';
import 'media_diagnostics.dart';

final _log = AppLogger.forModule('PurefoxMedia');

/// PureFox 视频型号写入共享目录时使用的前缀：站点型号名与各家官方型号同名，不加前缀
/// 会覆盖其它供应商读取的能力。渠道键保持原始型号名，提交时再剥掉前缀。
const purefoxMediaCatalogPrefix = 'purefox_media/';

/// 提交给上游时把目录前缀还原成站点认识的原始型号名。
String purefoxUpstreamModel(String modelId) =>
    modelId.startsWith(purefoxMediaCatalogPrefix)
    ? modelId.substring(purefoxMediaCatalogPrefix.length)
    : modelId;

/// 上游返回非 200 时抛出，携带状态码供界面映射为可读提示。
class PurefoxMediaModelsException implements Exception {
  const PurefoxMediaModelsException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'Failed to fetch PureFox media models ($statusCode)';
}

/// 站点 `/v1/models`（OpenAI 信封）的一个型号。真实字段形如：
/// `{"id":"TTseadanco2.5-720","kind":"video","qualities":["720p"],`
/// ` "ratios":["16:9","9:16"],`
/// ` "duration":{"mode":"options","options":[5,...,30]},`
/// ` "refImages":30,"refVideos":10,"refAudios":10}`
class PurefoxMediaModel {
  const PurefoxMediaModel({
    required this.id,
    required this.kind,
    required this.qualities,
    required this.ratios,
    required this.durations,
    required this.refImages,
    required this.refVideos,
    required this.refAudios,
  });

  final String id;

  /// 媒体大类：image / video / audio。
  final String kind;

  /// 清晰度档位；图片如 1K/2K/4K，视频如 720p/1080p。
  final List<String> qualities;

  /// 站点声明的可用画幅；空表示上游未给出，沿用本地默认。
  final List<String> ratios;

  /// 视频可用时长（秒）；图片为空。
  final List<int> durations;

  /// 参考素材上限，按素材类型分开。
  final int refImages;
  final int refVideos;
  final int refAudios;

  /// 图片只需要模型 ID；视频需要档位和时长才能参与本地参数校验。
  bool get isUsable => switch (kind) {
    'image' => id.trim().isNotEmpty,
    'video' => qualities.isNotEmpty && durations.isNotEmpty,
    'audio' => qualities.isNotEmpty,
    _ => false,
  };

  factory PurefoxMediaModel.fromJson(Map<String, dynamic> json) {
    return PurefoxMediaModel(
      id: json['id'] as String,
      kind: (json['kind'] as String? ?? '').trim(),
      qualities: _readStrings(json['qualities']),
      ratios: _readStrings(json['ratios']),
      durations: _readDurations(json['duration'], json['durations']),
      refImages: (json['refImages'] as num?)?.toInt() ?? 0,
      refVideos: (json['refVideos'] as num?)?.toInt() ?? 0,
      refAudios: (json['refAudios'] as num?)?.toInt() ?? 0,
    );
  }

  static List<String> _readStrings(Object? raw) => [
    for (final value in raw as List? ?? const []) value.toString(),
  ];

  /// 主格式是 `duration: {mode, options}`；兼容旧的 `durations` 数组与
  /// `duration_min`/`duration_max` 区间。
  static List<int> _readDurations(Object? duration, Object? legacy) {
    if (duration is Map) {
      final options = duration['options'];
      if (options is List && options.isNotEmpty) {
        return [for (final value in options) ?int.tryParse(value.toString())];
      }
      final mode = duration['mode'];
      if (mode == 'range') {
        final min = int.tryParse('${duration['min']}');
        final max = int.tryParse('${duration['max']}');
        if (min != null && max != null && max >= min) {
          return [for (var seconds = min; seconds <= max; seconds++) seconds];
        }
      }
    }
    if (legacy is List) {
      return [for (final value in legacy) ?int.tryParse(value.toString())];
    }
    return const [];
  }
}

class PurefoxMediaModelCatalog {
  const PurefoxMediaModelCatalog(this.models);

  final List<PurefoxMediaModel> models;

  /// 只返回能安全登记进渠道目录的型号，避免把缺时长的视频模型放进来崩溃或误提交。
  List<String> idsOfKind(String kind) => [
    for (final model in models)
      if (model.kind == kind && model.isUsable) model.id,
  ];

  /// 用带前缀的目录键登记视频能力，渠道表以站点原始 ID 为键。
  void register() {
    for (final model in models) {
      if (model.kind != 'video' || !model.isUsable) {
        continue;
      }
      final catalogId = '$purefoxMediaCatalogPrefix${model.id}';
      videoModelsCatalog[catalogId] = VideoModelCatalogEntry(
        capabilities: VideoModelCapabilities(
          ratios: model.ratios.isEmpty ? null : model.ratios.toSet(),
          resolutions: model.qualities.toSet(),
          durations: model.durations.toSet(),
          maxReferences: model.refImages + model.refVideos + model.refAudios,
          references: _videoReferences(model),
        ),
      );
      purefoxMediaVideoModels[model.id] = VideoChannelModel(
        catalogId: catalogId,
      );
    }
  }

  /// 线上按素材类型给出参考上限；显式写 null 表示该类型不接受参考素材。
  Map<VideoMediaKind, VideoReferenceLimits?> _videoReferences(
    PurefoxMediaModel model,
  ) => {
    VideoMediaKind.image: model.refImages > 0
        ? VideoReferenceLimits(maxCount: model.refImages)
        : null,
    VideoMediaKind.video: model.refVideos > 0
        ? VideoReferenceLimits(maxCount: model.refVideos)
        : null,
    VideoMediaKind.audio: model.refAudios > 0
        ? VideoReferenceLimits(maxCount: model.refAudios)
        : null,
  };
}

/// 请求 `/v1/models` 并解析；需要有效的 Base URL 与 API Key。
Future<PurefoxMediaModelCatalog> fetchPurefoxMediaModels(
  AiProvider config, {
  http.Client? httpClient,
}) async {
  final endpoint = Uri.parse(config.effectiveBaseUrl.trim());
  final apiKey = config.effectiveApiKey.trim();
  if (!{'http', 'https'}.contains(endpoint.scheme) ||
      endpoint.host.isEmpty ||
      apiKey.isEmpty) {
    throw StateError('PureFox media requires a valid base URL and API key');
  }
  final uri = endpoint.replace(
    path: '${endpoint.path.replaceFirst(RegExp(r'/+$'), '')}/models',
  );
  final transport = httpClient ?? config.createProxyClient() ?? http.Client();
  try {
    final response = await transport
        .get(uri, headers: {'Authorization': 'Bearer $apiKey'})
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw PurefoxMediaModelsException(response.statusCode);
    }
    final decoded = jsonDecode(response.body);
    final list = decoded is List
        ? decoded
        : (decoded as Map<String, dynamic>)['data'] as List;
    return PurefoxMediaModelCatalog([
      for (final item in list)
        PurefoxMediaModel.fromJson(item as Map<String, dynamic>),
    ]);
  } finally {
    if (httpClient == null) {
      transport.close();
    }
  }
}

/// 启动时按已保存配置重新登记内存目录中的视频规格。
///
/// 单个供应商失败只记录诊断日志，不影响其它供应商，也不阻塞启动；用户仍可在
/// 设置页手动“获取模型”重试。
Future<void> ensurePurefoxMediaModelsRegistered(
  Iterable<AiProvider> providers, {
  http.Client? httpClient,
}) async {
  for (final provider in providers) {
    if (!provider.isTypeSupported ||
        provider.typeEnum != AiProviderType.purefox_media) {
      continue;
    }
    // 只要能拉到目录就登记：能力还供设置页展示，不要求供应商已启用。
    if (!provider.hasCredentialConfiguration || !provider.hasBaseUrl) {
      continue;
    }
    try {
      final catalog = await fetchPurefoxMediaModels(
        provider,
        httpClient: httpClient,
      );
      catalog.register();
      _log.info(
        'registered models count=${catalog.models.length} '
        'provider=${provider.id}',
      );
    } catch (error) {
      _log.warning(
        'fetch models failed provider=${provider.id} '
        'type=${error.runtimeType} '
        'detail=${safeMediaDiagnostic(error, provider.effectiveApiKey)}',
      );
    }
  }
}
