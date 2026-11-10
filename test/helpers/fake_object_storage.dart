// 职责: 用可注入的上传函数替身对象存储，供参考素材上传测试计数和控制结果。
// 关联文件:
//   lib/shared/services/object_storage/service.dart
//   lib/shared/services/ai/video/reference_storage_service.dart
import 'dart:io';

import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/object_storage_config.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/object_storage/service.dart';

/// [upload] 为 null 时表现为未配置；否则每次上传都交给它处理。
class FakeObjectStorage extends ObjectStorageService {
  FakeObjectStorage(AppDatabase database, this._upload)
    : super(database: database);

  final ReferenceUploader? _upload;
  var loads = 0;

  @override
  Future<ObjectStorageConfig> load() async {
    loads++;
    return _upload == null
        ? const ObjectStorageConfig()
        : const ObjectStorageConfig(
            endpoint: 'https://s3.example.com',
            bucket: 'media',
            accessKeyId: 'ak',
            secretAccessKey: 'sk',
          );
  }

  @override
  Future<StoredObject> upload(
    ObjectStorageConfig config, {
    required File file,
    required String sha256,
    required String mimeType,
    required int fileSize,
  }) async {
    final result = await _upload!(
      file: file,
      sha256: sha256,
      mimeType: mimeType,
      fileSize: fileSize,
    );
    return (url: Uri.parse(result.url), expiresAt: result.expiresAt);
  }
}
