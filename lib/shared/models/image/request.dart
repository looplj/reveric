// 职责: 定义内置与插件共用的图片提交输入，保留有序参考身份、传输来源及冻结默认参数。
// 关联文件:
//   lib/shared/services/ai/image/client.dart
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/models/image/config.dart
import 'config.dart';

sealed class ImageReferenceSource {
  const ImageReferenceSource();
  Map<String, dynamic> toJson();
  factory ImageReferenceSource.fromJson(Map<String, dynamic> value) =>
      switch (value['kind']) {
        'file' => ImageFileReference(value['handle'] as String),
        'url' => ImageUrlReference(
          value['url'] as String,
          expiresAt: value['expiresAt'] as String?,
        ),
        'uploaded' => ImageUploadedReference(
          value['ref'] as String,
          expiresAt: value['expiresAt'] as String?,
        ),
        _ => throw const FormatException('Invalid image reference source'),
      };
}

final class ImageFileReference extends ImageReferenceSource {
  const ImageFileReference(this.handle);
  final String handle;
  @override
  Map<String, dynamic> toJson() => {'kind': 'file', 'handle': handle};
}

final class ImageUrlReference extends ImageReferenceSource {
  const ImageUrlReference(this.url, {this.expiresAt});
  final String url;
  final String? expiresAt;
  @override
  Map<String, dynamic> toJson() => {
    'kind': 'url',
    'url': url,
    if (expiresAt != null) 'expiresAt': expiresAt,
  };
}

final class ImageUploadedReference extends ImageReferenceSource {
  const ImageUploadedReference(this.ref, {this.expiresAt});
  final String ref;
  final String? expiresAt;
  @override
  Map<String, dynamic> toJson() => {
    'kind': 'uploaded',
    'ref': ref,
    if (expiresAt != null) 'expiresAt': expiresAt,
  };
}

class PreparedImageReference {
  const PreparedImageReference({
    required this.assetId,
    required this.mimeType,
    required this.source,
    this.clipId,
    this.inputId,
  });
  final String assetId, mimeType;
  final String? clipId, inputId;
  final ImageReferenceSource source;
  factory PreparedImageReference.fromJson(Map<String, dynamic> value) =>
      PreparedImageReference(
        assetId: value['assetId'] as String,
        mimeType: value['mimeType'] as String,
        source: ImageReferenceSource.fromJson(
          Map<String, dynamic>.from(value['source'] as Map),
        ),
        clipId: value['clipId'] as String?,
        inputId: value['inputId'] as String?,
      );
  Map<String, dynamic> toJson() => {
    'assetId': assetId,
    'mimeType': mimeType,
    if (clipId != null) 'clipId': clipId,
    if (inputId != null) 'inputId': inputId,
    'source': source.toJson(),
  };
}

class SubmitImageInput {
  const SubmitImageInput({
    required this.prompt,
    required this.modelId,
    this.size,
    this.quality,
    this.complexity,
    this.aspectRatio,
    this.resolution,
    this.references = const [],
    this.defaults = const {},
  });
  final String prompt, modelId;
  String get model => modelId;
  final String? size, quality, complexity, aspectRatio, resolution;
  final List<PreparedImageReference> references;
  final Map<String, dynamic> defaults;
  ImageRequestDefaults get nativeDefaults =>
      ImageRequestDefaults.fromJson(defaults);
  Map<String, dynamic> toJson() => {
    'modelId': modelId,
    'prompt': prompt,
    'parameters': {
      'ratio': aspectRatio ?? 'auto',
      'resolution': resolution ?? 'auto',
      if (size != null) 'size': size,
      if (quality != null) 'quality': quality,
      if (complexity != null) 'complexity': complexity,
      'defaults': defaults,
    },
    'references': references.map((value) => value.toJson()).toList(),
  };
}
