// 职责: 流式暂存并校验导入媒体，按作品去重后原子登记受控文件与统一资产。
// 关联文件:
//   lib/shared/services/production/library_service.dart
//   lib/shared/services/production/media_service.dart
//   lib/shared/database/daos/asset_dao.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md
//   .agents/rules/service-naming.md

import 'dart:io';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/asset_purpose.dart';
import '../../models/production/media.dart';
import '../../utils/random_id.dart';
import '../../utils/storage_paths.dart';
import 'ffmpeg_runner.dart';
import 'media_service.dart';
import 'media_file.dart';

final _log = AppLogger.forModule('MediaImport');

class MediaImportOrchestrator {
  Future<AssetRow> run({
    required AppDatabase database,
    required Directory root,
    required MediaService media,
    required File file,
    required String name,
    required String novelId,
    required AssetPurpose purpose,
    required MediaCancellation cancellation,
    bool addToLibrary = false,
    String source = 'uploaded',
    String? batchId,
    String? prompt,
    String? model,
    void Function(double progress)? onProgress,
  }) async {
    RevericPaths.mediaDirectory(novelId, 'file');
    final extension = p.extension(name).toLowerCase();
    final format = productionMediaFormats[extension];
    if (format == null) {
      throw const MediaException(MediaFailure.invalid_media);
    }
    _log.info(
      'started type=${format.$1} purpose=${purpose.value} novel=$novelId',
    );
    final imagePart =
        format.$1 == 'image' &&
        source == 'generated' &&
        RevericPaths.isImageResultPart(root, file.path);
    final temporary = imagePart
        ? null
        : await Directory.systemTemp.createTemp('reveric_media_import_');
    File? ownedFile;
    var ownedCreated = false;
    var committed = false;
    try {
      // 客户端已完成写入的受控 .part 直接校验，不再复制到第二个临时目录。
      final staged = imagePart
          ? file
          : File(p.join(temporary!.path, 'input$extension'));
      var size = 0;
      if (imagePart) {
        size = await staged.length();
      } else {
        final expected = await file.length();
        final sink = staged.openWrite();
        try {
          await for (final chunk in file.openRead()) {
            if (cancellation.cancelled) {
              throw const MediaException(MediaFailure.cancelled);
            }
            size += chunk.length;
            if (size > 2 * 1024 * 1024 * 1024) {
              throw const MediaException(MediaFailure.invalid_media);
            }
            sink.add(chunk);
            await sink.flush();
            if (expected > 0) {
              onProgress?.call((size / expected).clamp(0.0, 1.0));
            }
          }
        } finally {
          await sink.close();
        }
      }
      if (size == 0 || size > 2 * 1024 * 1024 * 1024) {
        throw const MediaException(MediaFailure.invalid_media);
      }
      // 图片只读文件头，不依赖 ffprobe：移动端没有 ffmpeg，图片入库仍要可用。
      final MediaInfo? info;
      final int? width;
      final int? height;
      if (format.$1 == 'image') {
        final dimensions = await _imageDimensions(staged, extension);
        if (dimensions == null) {
          throw const MediaException(MediaFailure.invalid_media);
        }
        info = null;
        (width, height) = dimensions;
      } else {
        final probed = info = await media.probe(
          staged.path,
          cancellation: cancellation,
        );
        final containers = probed.formatName?.split(',') ?? const <String>[];
        final expectedContainers = switch (extension) {
          '.mp4' || '.mov' || '.m4a' => {'mov', 'mp4', 'm4a'},
          '.mkv' || '.webm' => {'matroska', 'webm'},
          '.mp3' => {'mp3'},
          '.wav' => {'wav'},
          '.aac' => {'aac'},
          '.flac' => {'flac'},
          '.ogg' => {'ogg'},
          _ => <String>{},
        };
        if (!containers.any(expectedContainers.contains)) {
          throw const MediaException(MediaFailure.invalid_media);
        }
        if ((format.$1 == 'video' &&
                (!probed.hasVideo || probed.duration <= Duration.zero)) ||
            (format.$1 == 'audio' &&
                (!probed.hasAudio ||
                    probed.hasVideo ||
                    probed.duration <= Duration.zero))) {
          throw const MediaException(MediaFailure.invalid_media);
        }
        width = probed.width;
        height = probed.height;
        if (format.$1 == 'video' && ((width ?? 0) <= 0 || (height ?? 0) <= 0)) {
          throw const MediaException(MediaFailure.invalid_media);
        }
      }
      final digest = (await sha256.bind(staged.openRead()).first).toString();
      if (cancellation.cancelled) {
        throw const MediaException(MediaFailure.cancelled);
      }
      return await database
          .transaction(() async {
            // 同作品同场景复用记录；同作品其他场景已有的文件只复用文件。
            final existing = await database.assetDao.findByHash(
              digest,
              format.$1,
              novelId,
              purpose: purpose.value,
            );
            if (existing != null &&
                existing.path != null &&
                await RevericPaths.ownsMediaFile(
                  root,
                  novelId,
                  format.$1,
                  File(p.join(root.path, existing.path!)),
                )) {
              if (addToLibrary && !existing.inLibrary) {
                await database.assetDao.setInLibrary(existing.id, true);
              }
              if (batchId != null && existing.batchId != batchId) {
                try {
                  await (database.update(database.assets)
                        ..where((table) => table.id.equals(existing.id)))
                      .write(AssetsCompanion(batchId: Value(batchId)));
                } catch (error, stack) {
                  _log.error(
                    '[DB] assets UPDATE batch id=${existing.id}',
                    error: error,
                    stackTrace: stack,
                  );
                  rethrow;
                }
              }
              _log.info('reused id=${existing.id}');
              return (await database.assetDao.getAsset(existing.id))!;
            }
            final id = existing?.id ?? buildRandomId('ast', length: 12);
            final sibling = await database.assetDao.findByHash(
              digest,
              format.$1,
              novelId,
            );
            final siblingOwned =
                sibling?.path != null &&
                await RevericPaths.ownsMediaFile(
                  root,
                  novelId,
                  format.$1,
                  File(p.join(root.path, sibling!.path!)),
                );
            final managed = await RevericPaths.ownsMediaFile(
              root,
              novelId,
              format.$1,
              file,
            );
            final relative = siblingOwned
                ? sibling.path!
                : managed
                ? p.posix.joinAll(
                    p.split(p.relative(file.path, from: root.path)),
                  )
                : RevericPaths.mediaPath(
                    novelId,
                    format.$1,
                    '${buildRandomId('asset')}$extension',
                  );
            if (!siblingOwned && !managed) {
              ownedFile = File(p.join(root.path, relative));
              await ownedFile!.parent.create(recursive: true);
              await ownedFile!.create(exclusive: true);
              ownedCreated = true;
              if (imagePart) {
                await staged.rename(ownedFile!.path);
              } else {
                await staged.openRead().pipe(ownedFile!.openWrite());
              }
            }
            if (existing != null) {
              try {
                await (database.update(
                  database.assets,
                )..where((t) => t.id.equals(id))).write(
                  AssetsCompanion(
                    path: Value(relative),
                    inLibrary: Value(addToLibrary || existing.inLibrary),
                    batchId: batchId == null
                        ? const Value.absent()
                        : Value(batchId),
                  ),
                );
              } catch (error, stack) {
                _log.error(
                  '[DB] assets UPDATE path id=$id',
                  error: error,
                  stackTrace: stack,
                );
                rethrow;
              }
              return (await database.assetDao.getAsset(id))!;
            }
            if (cancellation.cancelled) {
              throw const MediaException(MediaFailure.cancelled);
            }
            await database.assetDao.insertAsset(
              AssetsCompanion.insert(
                id: id,
                type: format.$1,
                novelId: Value(novelId),
                batchId: Value(batchId),
                purpose: purpose.value,
                source: Value(source),
                inLibrary: Value(addToLibrary),
                name: Value(
                  await database.assetDao.uniqueName(
                    novelId,
                    format.$1,
                    p.basename(name),
                  ),
                ),
                path: Value(relative),
                content: Value(switch (format.$1) {
                  'image' => ImageAssetContent(
                    mimeType: format.$2,
                    width: width,
                    height: height,
                    bytes: size,
                    generation: AssetGeneration(prompt: prompt, model: model),
                  ),
                  'video' => VideoAssetContent(
                    mimeType: format.$2,
                    width: width,
                    height: height,
                    durationMs: info!.duration.inMilliseconds,
                    bytes: size,
                  ),
                  'audio' => AudioAssetContent(
                    mimeType: format.$2,
                    durationMs: info!.duration.inMilliseconds,
                    bytes: size,
                  ),
                  _ => throw StateError('Unsupported media type'),
                }),
                sha256: Value(digest),
              ),
            );
            return (await database.assetDao.getAsset(id))!;
          })
          .then((asset) {
            committed = true;
            _log.info('committed id=${asset.id} type=${asset.type}');
            return asset;
          });
    } catch (error, stack) {
      _log.error('failed', error: error, stackTrace: stack);
      rethrow;
    } finally {
      // Only this uncommitted operation's newly allocated copy is rolled back.
      if (!committed &&
          ownedCreated &&
          ownedFile != null &&
          await ownedFile!.exists()) {
        await ownedFile!.delete();
      }
      await temporary?.delete(recursive: true);
    }
  }

  /// 扩展名对应的解码器能识别文件头时返回宽高；否则视为无效图片。
  Future<(int, int)?> _imageDimensions(File file, String extension) async {
    final img.Decoder? decoder = switch (extension) {
      '.png' => img.PngDecoder(),
      '.jpg' || '.jpeg' => img.JpegDecoder(),
      '.webp' => img.WebPDecoder(),
      _ => null,
    };
    if (decoder == null) {
      return null;
    }
    final bytes = await file.readAsBytes();
    final img.DecodeInfo? info;
    try {
      // 解码器遇到截断的文件头会直接抛越界异常，而不是返回 null。
      info = decoder.isValidFile(bytes) ? decoder.startDecode(bytes) : null;
    } catch (error, stack) {
      _log.error(
        'image header unreadable extension=$extension',
        error: error,
        stackTrace: stack,
      );
      return null;
    }
    if (info == null || info.width <= 0 || info.height <= 0) {
      return null;
    }
    return (info.width, info.height);
  }
}
