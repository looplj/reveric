// 职责: 准备本地参考素材的元数据，通过存储上传接口取得可访问地址并合并重复上传。
// 关联文件:
//   lib/shared/providers/video_tasks.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart
//   lib/shared/models/production/media.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json

import 'dart:io';
import 'package:crypto/crypto.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/production/media.dart';
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';

typedef ReferenceUploadResult = ({Uri url, DateTime? expiresAt});
typedef ReferenceUploader =
    Future<ReferenceUploadResult> Function({
      required File file,
      required String sha256,
      required String mimeType,
      required int fileSize,
    });

class ReferenceStorageService {
  ReferenceStorageService({required this.probe, this.resolveUpload});

  final Future<MediaInfo> Function(String path) probe;

  /// 每次上传前按当前存储配置取上传函数；返回 null 表示未配置，此时不上传，也不产生占位 URL。
  final Future<ReferenceUploader?> Function()? resolveUpload;
  final _preparing = <String, Future<ReferenceUploadResult>>{};

  Future<bool> isConfigured() async => await resolveUpload?.call() != null;

  Future<VideoReference> ensure(VideoInput input, File file) async {
    final uploader = await resolveUpload?.call();
    if (uploader == null) {
      throw const VideoException(
        VideoErrorCode.configuration_required,
        field: 'reference_storage',
        messageKey: LocaleKeys.productionReferenceStorageNotConnected,
        detail:
            'Application object storage is not configured for reference uploads.',
      );
    }
    final info = await probe(file.path);
    final size = await file.length();
    final hash = (await sha256.bind(file.openRead()).first).toString();
    final key = '${input.mimeType}/$hash';
    final pending = _preparing[key] ??= uploader(
      file: file,
      sha256: hash,
      mimeType: input.mimeType,
      fileSize: size,
    );
    final ReferenceUploadResult result;
    try {
      result = await pending;
    } finally {
      if (identical(_preparing[key], pending)) {
        _preparing.remove(key);
      }
    }
    final url = result.url;
    final expires = result.expiresAt;
    if (!{'http', 'https'}.contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        (expires != null && !expires.isAfter(DateTime.now().toUtc()))) {
      throw const VideoException(VideoErrorCode.invalid_response);
    }
    return VideoReference(
      role: input.role,
      url: url,
      mimeType: input.mimeType,
      fileSize: size,
      mediaInfo: VideoMediaInfo(
        width: info.width,
        height: info.height,
        durationMs: info.duration.inMilliseconds,
        frameRate: info.frameRate,
      ),
    );
  }
}
