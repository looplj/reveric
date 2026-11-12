// 职责: 定义生成任务类型、公共状态与图片/视频的不可变请求快照。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/type_converters.dart
//   lib/shared/models/production/image_request.dart
//   lib/shared/models/video/request.dart
import '../production/image_request.dart';
import '../audio/request.dart';
import '../video/request.dart';

enum GenerationKind { image, video, audio }

enum GenerationTaskStatus {
  prepared,
  uploading,
  submitting,
  submission_unknown,
  running,
  saving,
  action_required,
  reconciliation_required,
  completed,
  failed,
  cancelled,
  expired;

  bool get isTerminal =>
      const {completed, failed, cancelled, expired}.contains(this);
}

sealed class GenerationRequest {
  const GenerationRequest();
  GenerationKind get kind;
  String get modelId;
  Map<String, dynamic> toJson();

  factory GenerationRequest.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported generation request');
    }
    final request = json['request'] as Map<String, dynamic>;
    return switch (GenerationKind.values.byName(json['kind'] as String)) {
      GenerationKind.audio => AudioGenerationRequest(
        AudioRequest.fromJson(request),
      ),
      GenerationKind.image => ImageGenerationRequest(
        ProductionImageRequest.fromJson(request),
      ),
      GenerationKind.video => VideoGenerationRequest(
        VideoRequest.fromJson(request),
        inputs: (json['inputs'] as List)
            .map((value) => VideoInput.fromJson(value as Map<String, dynamic>))
            .toList(),
      ),
    };
  }
}

final class ImageGenerationRequest extends GenerationRequest {
  const ImageGenerationRequest(this.request);
  final ProductionImageRequest request;
  @override
  GenerationKind get kind => GenerationKind.image;
  @override
  String get modelId => request.modelId;
  @override
  Map<String, dynamic> toJson() => {
    'version': 1,
    'kind': kind.name,
    'request': request.toJson(),
  };
}

final class VideoGenerationRequest extends GenerationRequest {
  VideoGenerationRequest(this.request, {List<VideoInput> inputs = const []})
    : inputs = List.unmodifiable(inputs);
  final VideoRequest request;
  final List<VideoInput> inputs;
  @override
  GenerationKind get kind => GenerationKind.video;
  @override
  String get modelId => request.modelId;
  @override
  Map<String, dynamic> toJson() => {
    'version': 1,
    'kind': kind.name,
    'request': request.toJson(),
    'inputs': inputs.map((input) => input.toJson()).toList(),
  };
}

final class AudioGenerationRequest extends GenerationRequest {
  const AudioGenerationRequest(this.request);
  final AudioRequest request;
  @override
  GenerationKind get kind => GenerationKind.audio;
  @override
  String get modelId => request.modelId;
  @override
  Map<String, dynamic> toJson() => {
    'version': 1,
    'kind': kind.name,
    'request': request.toJson(),
  };
}

/// 一张候选图当前的保存阶段；入库后只保留资产身份。
class ImageTaskOutput {
  const ImageTaskOutput({this.url, this.path, this.hash, this.assetId});
  final String? url;
  final String? path;
  final String? hash;
  final String? assetId;
  Map<String, dynamic> toJson() => {
    if (url != null) 'url': url,
    if (path != null) 'path': path,
    if (hash != null) 'hash': hash,
    if (assetId != null) 'asset_id': assetId,
  };
  factory ImageTaskOutput.fromJson(Map<String, dynamic> json) {
    final output = ImageTaskOutput(
      url: json['url'] as String?,
      path: json['path'] as String?,
      hash: json['hash'] as String?,
      assetId: json['asset_id'] as String?,
    );
    final stages = [
      output.assetId,
      output.path,
      output.url,
    ].where((value) => value != null).length;
    if (stages != 1 ||
        (output.path == null) != (output.hash == null) ||
        [
          output.assetId,
          output.path,
          output.hash,
          output.url,
        ].whereType<String>().any((value) => value.trim().isEmpty)) {
      throw const FormatException('Invalid image output');
    }
    return output;
  }
}

class ImageTaskOutputs {
  ImageTaskOutputs(Iterable<ImageTaskOutput> items)
    : items = List.unmodifiable(items) {
    if (this.items.isEmpty) {
      throw const FormatException('Empty image outputs');
    }
  }
  final List<ImageTaskOutput> items;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'items': items.map((item) => item.toJson()).toList(),
  };
  factory ImageTaskOutputs.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported image outputs');
    }
    return ImageTaskOutputs(
      (json['items'] as List).map(
        (item) => ImageTaskOutput.fromJson(item as Map<String, dynamic>),
      ),
    );
  }
}
