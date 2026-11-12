// 职责: 图片库服务 — 经媒体导入登记图片与生成结果、保存地图出图并解析应用内路径。
// 关联文件:
//   lib/shared/services/production/library_service.dart
//   lib/shared/database/daos/image_asset_dao.dart
//   lib/shared/database/app_database.dart
//   lib/shared/services/ai/image.dart
//   lib/shared/utils/storage_paths.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/data-deletion.md

import 'dart:io';
import '../models/production/asset_content.dart';
import '../models/asset_purpose.dart';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../database/app_database.dart';
import '../logger/app_logger.dart';
import '../models/map_place_recognition.dart';
import '../utils/random_id.dart';
import '../utils/storage_paths.dart';
import 'ai/image.dart';
import 'production/ffmpeg_runner.dart';
import 'production/library_service.dart';
import 'production/media_service.dart';

final _log = AppLogger.forModule('ImageLibraryService');

class ImageLibraryService {
  ImageLibraryService(this._database, this._library);

  final AppDatabase _database;

  /// 导入时才取媒体库：只读路径、识别快照的调用方不必先初始化资料目录。
  final MediaLibraryService Function() _library;

  /// 有效图片资产；不存在、已软删除或不是图片时为 null。
  Future<AssetRow?> getAsset(String assetId) =>
      _database.imageAssetDao.getAsset(assetId);

  /// 图片资产的相对路径；不存在、已软删除或不是图片时为 null。
  Future<String?> assetPath(String assetId) async =>
      (await getAsset(assetId))?.path;

  /// 文件入库统一走媒体导入；同一作品内按内容去重。
  /// [name] 为空时用文件名作资产名。
  Future<AssetRow> importFile(
    String sourcePath, {
    required String novelId,
    required AssetPurpose purpose,
    String? name,
    String? prompt,
    String? model,
    String? batchId,
    String source = 'uploaded',
  }) async {
    final asset = await _library().importFile(
      File(sourcePath),
      name: name ?? p.basename(sourcePath),
      novelId: novelId,
      purpose: purpose,
      cancellation: MediaCancellation(),
      source: source,
      batchId: batchId,
      prompt: prompt,
      model: model,
    );
    if (asset.type != 'image') {
      throw StateError('Imported file is not an image: ${asset.id}');
    }
    return asset;
  }

  /// 内存里的图片（如内置资源）经临时文件走统一导入，临时文件随即清理。
  Future<AssetRow> importBytes(
    Uint8List bytes, {
    required String name,
    required String novelId,
    required AssetPurpose purpose,
    String source = 'uploaded',
  }) async {
    final temporary = await Directory.systemTemp.createTemp(
      'reveric_image_bytes_',
    );
    try {
      final file = File(p.join(temporary.path, name));
      await file.writeAsBytes(bytes, flush: true);
      return await importFile(
        file.path,
        novelId: novelId,
        purpose: purpose,
        source: source,
      );
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<AssetRow> importGenerated(
    AiImageGenerationResult result, {
    required String novelId,
    required AssetPurpose purpose,
    String? name,
    String? prompt,
    String? model,
    String? batchId,
  }) async {
    final localPath = result.localFilePath;
    if (localPath == null || localPath.isEmpty) {
      throw const AiImageGenerationException('生成结果没有可保存的图片。');
    }
    try {
      for (final candidate in result.additionalImages) {
        await importGenerated(
          candidate,
          novelId: novelId,
          purpose: purpose,
          prompt: prompt,
          model: model,
          batchId: batchId,
        );
      }
      return await importFile(
        localPath,
        novelId: novelId,
        purpose: purpose,
        name:
            name ??
            (localPath.endsWith('.part')
                ? p.basenameWithoutExtension(localPath)
                : p.basename(localPath)),
        prompt: prompt,
        model: model,
        batchId: batchId,
        source: 'generated',
      );
    } finally {
      await result.disposeTemporary();
    }
  }

  /// 将内存中的地图出图保存为一条独立资产。
  ///
  /// 地图每次出图都有成本，因此这里不按 sha256 折叠；即使模型返回相同字节，
  /// 也保留本次生成记录。metadata 保存展示信息及地图地名识别快照。
  Future<AssetRow> importMapImage(
    Uint8List bytes, {
    required String novelId,
    String? prompt,
    String? model,
    String mimeSubtype = 'png',
    Map<String, dynamic>? metadata,
  }) async {
    if (bytes.isEmpty) {
      throw const AiImageGenerationException('生成结果没有可保存的图片。');
    }
    final directory = Directory(
      p.join(
        RevericPaths.fileWorkspaceParent,
        RevericPaths.mediaDirectory(novelId, 'image'),
      ),
    );
    await directory.create(recursive: true);
    final extension = _extensionForMimeSubtype(mimeSubtype);
    final target = File(
      p.join(
        directory.path,
        'img_${DateTime.now().microsecondsSinceEpoch}_${buildRandomId('asset', length: 6)}.$extension',
      ),
    );
    await target.writeAsBytes(bytes, flush: true);
    final relative = RevericPaths.toRelative(target.path) ?? target.path;
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      // 尺寸探测失败不影响资产留存；调用方可继续使用已知尺寸。
    }
    final id = buildRandomId('ast');
    await _database.imageAssetDao.insertAsset(
      AssetsCompanion.insert(
        type: 'image',
        id: id,
        novelId: Value(novelId),
        purpose: AssetPurpose.map.value,
        source: const Value('generated'),
        path: Value(relative),
        content: Value(
          ImageAssetContent(
            mimeType: _mimeType(extension),
            width: decoded?.width,
            height: decoded?.height,
            bytes: bytes.length,
            generation: AssetGeneration(prompt: prompt, model: model),
          ),
        ),
        sha256: Value(sha256.convert(bytes).toString()),
        metadataJson: Value(metadata),
      ),
    );
    return (await _database.imageAssetDao.getAsset(id))!;
  }

  Future<MapPlaceRecognition?> mapRecognition(String assetId) async {
    final asset = await _database.imageAssetDao.getAsset(assetId);
    if (asset == null) {
      throw StateError('Map image asset does not exist: $assetId');
    }
    final saved = asset.metadataJson?['recognition'];
    if (saved == null) {
      return null;
    }
    try {
      return MapPlaceRecognition.fromJson(saved as Map<String, dynamic>);
    } on TypeError catch (error) {
      // 快照只是识别缓存；无法解析时按未识别处理，采用时重新识别并覆盖。
      _log.warning(
        'map recognition snapshot is unreadable; ignoring '
        'assetId=$assetId error=$error',
      );
      return null;
    }
  }

  Future<void> saveMapRecognition(
    String assetId,
    MapPlaceRecognition recognition,
  ) async {
    await _database.transaction(() async {
      final asset = await _database.imageAssetDao.getAsset(assetId);
      if (asset == null) {
        throw StateError('Map image asset does not exist: $assetId');
      }
      await _database.imageAssetDao.updateMetadata(assetId, {
        ...?asset.metadataJson,
        'recognition': recognition.toJson(),
      });
    });
  }

  String? resolve(String? storedPath) => RevericPaths.resolveStored(storedPath);

  static String _mimeType(String extension) {
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      default:
        return 'image/png';
    }
  }

  static String _extensionForMimeSubtype(String value) {
    final normalized = value.toLowerCase().replaceFirst('image/', '');
    return switch (normalized) {
      'jpeg' || 'jpg' => 'jpg',
      'webp' => 'webp',
      _ => 'png',
    };
  }
}

/// 初始化任务等没有 ProviderScope 的入口，按应用资料目录装配图片库。
ImageLibraryService buildImageLibraryService(AppDatabase database) =>
    ImageLibraryService(
      database,
      () => MediaLibraryService(
        database,
        MediaService(FfmpegRunner()),
        Directory(RevericPaths.fileWorkspaceParent),
      ),
    );
