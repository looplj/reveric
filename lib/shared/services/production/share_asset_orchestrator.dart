// 职责: 将已入库资产的文件移到共享目录，保留资产身份。
// 关联文件:
//   lib/shared/services/production/library_service.dart
//   lib/shared/database/daos/asset_dao.dart
//   lib/shared/utils/storage_paths.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md
//   .agents/rules/db-transactions.md

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../database/app_database.dart';
import '../../logger/app_logger.dart';
import '../../models/production/media.dart';
import '../../utils/random_id.dart';
import '../../utils/storage_paths.dart';
import 'library_service.dart';

final _log = AppLogger.forModule('ShareAsset');

class ShareAssetOrchestrator {
  Future<AssetRow> run({
    required MediaLibraryService library,
    required String assetId,
    required String sourceNovelId,
  }) async {
    final database = library.database;
    final dao = database.assetDao;
    (File, File)? moved;
    try {
      return await database.transaction(() async {
        final asset = await dao.getAsset(assetId);
        if (asset == null ||
            !asset.inLibrary ||
            !{'image', 'video', 'audio'}.contains(asset.type) ||
            (asset.novelId != null && asset.novelId != sourceNovelId) ||
            asset.path == null) {
          throw const MediaException(MediaFailure.invalid_media);
        }
        final sourcePath = asset.path!;
        final source = File(library.resolve(asset));
        await RevericPaths.requireNoLinks(library.root, source.path);
        final stat = await source.stat();
        if (stat.type != FileSystemEntityType.file || stat.size == 0) {
          throw const MediaException(MediaFailure.invalid_media);
        }
        if (asset.novelId == null) {
          return asset;
        }
        final relative = library.relativePath(sourcePath);
        final inSharedDirectory = p.posix.isWithin(
          RevericPaths.mediaDirectory(null, asset.type),
          relative,
        );
        final sharedPath = inSharedDirectory
            ? relative
            : RevericPaths.mediaPath(
                null,
                asset.type,
                '${buildRandomId('shared')}${p.extension(source.path)}',
              );
        if (await database.novelDao.get(sourceNovelId) == null ||
            !await dao.shareInLibrary(
              id: assetId,
              sourceNovelId: sourceNovelId,
              sourcePath: sourcePath,
              sharedPath: sharedPath,
              movedPaths: inSharedDirectory
                  ? const {}
                  : {
                      sourcePath,
                      relative,
                      relative.replaceAll('/', r'\'),
                      source.path,
                      source.path.replaceAll(r'\', '/'),
                    },
            )) {
          throw const MediaException(MediaFailure.invalid_media);
        }
        final shared = (await dao.getAsset(assetId))!;
        if (!inSharedDirectory) {
          final destination = File(library.resolvePath(sharedPath));
          await RevericPaths.requireNoLinks(library.root, destination.path);
          await destination.parent.create(recursive: true);
          if (await FileSystemEntity.type(
                destination.path,
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound) {
            throw const MediaException(MediaFailure.invalid_media);
          }
          moved = (source, await source.rename(destination.path));
        }
        return shared;
      });
    } catch (error, stack) {
      _log.error(
        'operation=share asset=$assetId failed',
        error: error,
        stackTrace: stack,
      );
      final paths = moved;
      if (paths != null) {
        final (source, destination) = paths;
        try {
          if (await FileSystemEntity.type(source.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw const MediaException(MediaFailure.invalid_media);
          }
          await destination.rename(source.path);
        } catch (error, stack) {
          _log.error(
            'operation=share asset=$assetId rollback failed',
            error: error,
            stackTrace: stack,
          );
        }
      }
      rethrow;
    }
  }
}
